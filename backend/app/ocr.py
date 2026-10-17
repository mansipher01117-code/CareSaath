"""Turn an uploaded PDF or photo into the text a record is made of.

A PDF that already carries a text layer is read with pypdf: no model, no
network, nothing to be wrong about. A photo — or a PDF that is only scanned
images, which has no text to read — is transcribed by Gemini, and only
transcribed: the prompt forbids summarising, translating and correcting,
because a record that has been tidied up is no longer the record.

Either way the result is the *draft* text that `/records/preview` extracts
from, so a person still reviews every fact on the Review screen before any of
it becomes evidence. Nothing here writes to the graph.
"""
import re

from . import agent

MAX_BYTES = 10 * 1024 * 1024
MIN_CHARS = 10

PDF_TYPES = {"application/pdf", "application/x-pdf"}
IMAGE_TYPES = {
    "image/jpeg", "image/jpg", "image/png", "image/webp", "image/heic", "image/heif",
}
PDF_SUFFIXES = (".pdf",)
IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif")
# What Gemini is told the bytes are, for a file whose own content type arrived
# empty or as a generic octet-stream (which is what a browser upload often
# sends).
SUFFIX_MIME = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".webp": "image/webp", ".heic": "image/heic", ".heif": "image/heif",
    ".pdf": "application/pdf",
}

TRANSCRIBE_PROMPT = (
    "Transcribe every word of this medical record exactly as it is written. "
    "Do not summarise, translate, correct, reorder or add anything, and do not "
    "describe the image. Keep dates, names and numbers exactly as they appear. "
    "Separate paragraphs with a blank line. "
    "If there is no legible text at all, reply with exactly NO_TEXT."
)


class UploadProblem(Exception):
    """Something about the file itself, phrased for whoever uploaded it."""


def _suffix(filename: str) -> str:
    m = re.search(r"(\.[A-Za-z0-9]{1,5})$", (filename or "").strip())
    return m.group(1).lower() if m else ""


def kind_of(filename: str, content_type: str) -> str:
    """'pdf' or 'image', from whichever of the two the browser got right.

    A content type is the better answer when there is one, but a web upload
    frequently sends `application/octet-stream`, so the file name's own suffix
    is just as valid a source.
    """
    ctype = (content_type or "").split(";")[0].strip().lower()
    suffix = _suffix(filename)
    if ctype in PDF_TYPES or suffix in PDF_SUFFIXES:
        return "pdf"
    if ctype in IMAGE_TYPES or suffix in IMAGE_SUFFIXES:
        return "image"
    raise UploadProblem(
        f"{filename or 'This file'} is not a PDF or a photo. Upload a PDF, JPG, PNG, "
        "WEBP or HEIC file, or paste the text instead."
    )


def paragraphs(text: str) -> str:
    """Lay text out the way the extractor reads it: one blank line per paragraph.

    Every citable span is a paragraph, so the layout is what decides how finely
    an answer can cite this record. A blank line in the source is kept as a
    paragraph break and the lines inside a paragraph are joined back into
    running text — a PDF that wraps mid-sentence would otherwise become a
    paragraph per line.
    """
    blocks, current = [], []
    for raw in (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = raw.strip()
        if line:
            current.append(line)
        elif current:
            blocks.append(" ".join(current))
            current = []
    if current:
        blocks.append(" ".join(current))
    return "\n\n".join(b for b in blocks if b)


def pdf_text(data: bytes) -> str:
    """The text layer of a PDF, page by page. Empty when it has none."""
    try:
        from pypdf import PdfReader
    except ImportError as e:  # pragma: no cover - depends on the install
        raise UploadProblem(f"PDF reading is not installed on the server ({e}).") from e
    import io

    try:
        reader = PdfReader(io.BytesIO(data))
        # Each page is laid out on its own, so a paragraph never runs across a
        # page break and pick up the next page's header.
        pages = [paragraphs(page.extract_text() or "") for page in reader.pages]
    except UploadProblem:
        raise
    except Exception as e:
        raise UploadProblem(f"This PDF could not be opened: {' '.join(str(e).split())[:120]}") from e
    return "\n\n".join(p for p in pages if p)


def transcribe(data: bytes, mime: str) -> str:
    """Read the words off a photo or a scanned page with Gemini.

    Built on the agent's own client helpers, so an upload uses the same key,
    model and timeout as an answer does, and reports an unavailable Gemini the
    same way.
    """
    try:
        client = agent._client()
        types = agent._genai_types()
    except agent.LlmUnavailable as e:
        raise UploadProblem(
            f"This file has no text to read, so it has to be transcribed by Gemini, "
            f"which is unavailable: {e}. Paste the text instead."
        ) from e
    try:
        resp = client.models.generate_content(
            model=agent._model(),
            contents=[types.Content(role="user", parts=[
                types.Part.from_bytes(data=data, mime_type=mime),
                types.Part(text=TRANSCRIBE_PROMPT),
            ])],
            config={"temperature": 0},
        )
    except Exception as e:
        raise UploadProblem(
            f"Gemini could not read this file: {agent._scrub(e)}. Paste the text instead."
        ) from e
    text = paragraphs(agent._response_text(resp))
    if text.strip().upper().startswith("NO_TEXT"):
        return ""
    return text


def text_from(filename: str, content_type: str, data: bytes) -> tuple[str, str]:
    """(record text, how it was read) for one uploaded file.

    `how` is 'pdf-text' when the PDF carried its own words and 'gemini' when
    they had to be transcribed — worth keeping, because one of the two is a
    machine reading and the other is a model's best effort.
    """
    if not data:
        raise UploadProblem("That file is empty.")
    if len(data) > MAX_BYTES:
        mb = len(data) / (1024 * 1024)
        raise UploadProblem(
            f"That file is {mb:.1f} MB. The limit is {MAX_BYTES // (1024 * 1024)} MB — "
            "upload a smaller scan, or split it."
        )
    kind = kind_of(filename, content_type)
    how = "pdf-text"
    text = pdf_text(data) if kind == "pdf" else ""
    if len(text) < MIN_CHARS:
        # A photo, or a PDF that is only scanned images: there is no text layer
        # to read, so the words have to come off the picture.
        mime = SUFFIX_MIME.get(_suffix(filename)) or (content_type or "").split(";")[0].strip()
        if kind == "pdf":
            mime = "application/pdf"
        elif mime not in IMAGE_TYPES:
            mime = "image/jpeg"
        text, how = transcribe(data, mime), "gemini"
    if len(text) < MIN_CHARS:
        raise UploadProblem(
            "No readable text could be found in that file. If it is a photo, try a "
            "sharper one, or paste the text instead."
        )
    return text, how
