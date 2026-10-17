"""CareSaath backend package.

`backend/.env` is loaded here, before any submodule reads its configuration:
`db` picks up the graph settings and `agent` the Gemini key at import time, so
the file has to be in the environment first. Values already set in the real
environment win — a shell `GEMINI_MODEL=... uvicorn ...` overrides the file.
"""
from pathlib import Path

try:
    from dotenv import load_dotenv

    load_dotenv(Path(__file__).resolve().parents[1] / ".env", override=False)
except ImportError:  # python-dotenv not installed: rely on the real environment
    pass
