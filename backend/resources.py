# backend/resources.py
from pathlib import Path
import json
from pypdf import PdfReader  # pip install pypdf

# Base directory of this file (backend/)
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"

def _require(path: Path):
    if not path.exists():
        raise FileNotFoundError(f"Required file not found: {path}")
    return path

def _read_text(filename: str) -> str:
    path = _require(DATA_DIR / filename)
    return path.read_text(encoding="utf-8")

def _read_json(filename: str):
    path = _require(DATA_DIR / filename)
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)

def _read_pdf_text(filename: str) -> str:
    path = _require(DATA_DIR / filename)
    reader = PdfReader(str(path))
    parts = []
    for page in reader.pages:
        text = page.extract_text() or ""
        parts.append(text)
    return "\n".join(parts).strip()

# ---- Load your resources ----
summary = _read_text("summary.txt")     # text
style   = _read_text("style.txt")       # text (if you have it)
facts   = _read_json("facts.json")      # JSON
linkedin = _read_pdf_text("linkedin_profile.pdf")  # PDF → text