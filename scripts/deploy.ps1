param(
    [ValidateSet("dev","test","prod")]
    [string]$Environment = "dev",
    [string]$ProjectName = "twin"
)
$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# --- Preflight checks (optional but helpful) ---
function Assert-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required command '$name' is not available on PATH."
    }
}
Assert-Command python
Assert-Command terraform
Assert-Command aws
Assert-Command npm

# 1) Build Lambda package (Windows-safe Python script)
Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location (Split-Path $PSScriptRoot -Parent)  # repo root

Push-Location backend
try {
    python .\deploy.py
} finally {
    Pop-Location
}

# Verify the zip exists & is non-empty
$lambdaZip = Join-Path -Path (Resolve-Path ".\backend").Path -ChildPath "lambda-deployment.zip"
if (-not (Test-Path $lambdaZip)) {
    throw "Lambda package not found at $lambdaZip"
}
if ((Get-Item $lambdaZip).Length -le 0) {
    throw "Lambda package at $lambdaZip is empty"
}

# 2) Terraform init / workspace / apply (folder = 'terraform' at repo root)
Write-Host "Running Terraform..." -ForegroundColor Yellow
terraform -chdir=terraform init -input=false

# Select or create workspace ($Environment)
$wsList = terraform -chdir=terraform workspace list
if ($wsList -notmatch "^\s*\*?\s*$Environment\s*$") {
    Write-Host "Creating workspace '$Environment'..."
    terraform -chdir=terraform workspace new $Environment
} else {
    Write-Host "Selecting workspace '$Environment'..."
    terraform -chdir=terraform workspace select $Environment
}

# Apply with variables
if ($Environment -eq "prod") {
    terraform -chdir=terraform apply `
      -var-file=prod.tfvars `
      -var="project_name=$ProjectName" `
      -var="environment=$Environment" `
      -auto-approve
} else {
    terraform -chdir=terraform apply `
      -var="project_name=$ProjectName" `
      -var="environment=$Environment" `
      -auto-approve
}

# 2b) Read outputs safely
function Get-TfRawOutput($name) {
    try {
        $val = terraform -chdir=terraform output -raw $name 2>$null
        if ([string]::IsNullOrWhiteSpace($val)) { return $null }
        return $val.Trim()
    } catch {
        return $null
    }
}

# NOTE: These names must exist in terraform/outputs.tf
$ApiUrl         = Get-TfRawOutput "api_gateway_url"
$FrontendBucket = Get-TfRawOutput "s3_frontend_bucket"
$CustomUrl      = Get-TfRawOutput "custom_domain_url"
$CfUrl          = Get-TfRawOutput "cloudfront_url"

if (-not $ApiUrl)         { throw "Terraform output 'api_gateway_url' is missing or empty." }
if (-not $FrontendBucket) { throw "Terraform output 's3_frontend_bucket' is missing or empty." }
if ($FrontendBucket -notmatch '^[a-z0-9.\-]{3,63}$') {
    throw "Invalid S3 bucket name from outputs: '$FrontendBucket'"
}

Write-Host "Terraform outputs OK:"
Write-Host "  API URL         : $ApiUrl"
Write-Host "  Frontend bucket : $FrontendBucket"
if ($CfUrl)     { Write-Host "  CloudFront URL  : $CfUrl" }
if ($CustomUrl) { Write-Host "  Custom domain   : $CustomUrl" }

# 3) Build + deploy frontend
Push-Location .\frontend
try {
    # Set API URL for production build
    Write-Host "Setting API URL for production..." -ForegroundColor Yellow
    "NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

    # Fix TLS fetch for Google Fonts / Turbopack on corp network
    $env:NEXT_TURBOPACK_EXPERIMENTAL_USE_SYSTEM_TLS_CERTS = "1"

    npm install
    npm run build

    # The guide expects Next static export to 'out/'
    if (-not (Test-Path ".\out")) {
        Write-Warning "No '.\out' folder after build. If you are not using static export, change the sync path."
    }

    aws s3 sync .\out "s3://$FrontendBucket/" --delete
} finally {
    Pop-Location
}

# 4) Final summary (re-read CF in case of update)
$CfUrl = Get-TfRawOutput "cloudfront_url"

Write-Host ""
Write-Host "Deployment complete!" -ForegroundColor Green
if ($CfUrl) {
    Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
}
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan