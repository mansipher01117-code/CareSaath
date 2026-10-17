"""Vercel entrypoint.

Vercel's FastAPI preset looks for an ASGI app in `index.py` at the project
root (the backend/ directory here). The app itself lives in `app/main.py`.

Local equivalent of the deployed server:  uvicorn index:app --port 8000
"""
from app.main import app  # noqa: F401
