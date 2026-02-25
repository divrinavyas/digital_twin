# backend/deploy.py
import os
import sys
import subprocess
import tempfile
import zipfile
from pathlib import Path

INCLUDE_EXTS = {".py"}  # include all Python source files from backend

def add_dir_to_zip(zf: zipfile.ZipFile, src_dir: Path, prefix: str = ""):
    base = src_dir
    for root, _, files in os.walk(src_dir):
        for f in files:
            full = Path(root) / f
            rel = full.relative_to(base)
            arc = Path(prefix) / rel if prefix else rel
            zf.write(full, arcname=str(arc))

def add_backend_sources(zf: zipfile.ZipFile, backend_dir: Path):
    # add all .py files from backend recursively, excluding common junk dirs
    exclude_dirs = {"__pycache__", ".venv", "venv", ".pytest_cache", ".mypy_cache", "package"}
    for root, dirs, files in os.walk(backend_dir):
        dirs[:] = [d for d in dirs if d not in exclude_dirs]
        for f in files:
            p = Path(root) / f
            if p.suffix in INCLUDE_EXTS:
                rel = p.relative_to(backend_dir)
                zf.write(p, arcname=str(rel))

def main():
    backend_dir = Path(__file__).resolve().parent
    req = backend_dir / "requirements.txt"
    output_zip = backend_dir / "lambda-deployment.zip"

    print("Creating Lambda deployment package...")

    if output_zip.exists():
        try:
            output_zip.unlink()
        except Exception:
            pass

    # Build in a temp dir (Windows/OneDrive safe)
    with tempfile.TemporaryDirectory(prefix="lambda_build_") as tmp:
        build_dir = Path(tmp) / "package"
        build_dir.mkdir(parents=True, exist_ok=True)

        if req.exists():
            print("Installing dependencies...")
            subprocess.check_call([
                sys.executable, "-m", "pip", "install",
                "-r", str(req), "-t", str(build_dir),
                "--no-cache-dir", "--upgrade"
            ])
        else:
            print("No requirements.txt found; skipping dependency install.")

        print(f"Zipping to {output_zip} ...")
        with zipfile.ZipFile(output_zip, "w", compression=zipfile.ZIP_DEFLATED) as z:
            # 1) include installed packages
            add_dir_to_zip(z, build_dir)
            # 2) include all backend python sources
            add_backend_sources(z, backend_dir)

    assert output_zip.exists() and output_zip.stat().st_size > 0, "Lambda zip not created or empty."
    print(f"Lambda package created: {output_zip.resolve()}")

if __name__ == "__main__":
    main()