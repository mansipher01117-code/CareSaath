"""Uploading a PDF or a photo as a record.

The upload is a way into the *existing* draft flow, not a way around it: a
file that is read, however it is read, lands on the Review screen as an
unconfirmed draft like pasted text does. So the guarantees here are about
reading the file and refusing it clearly — everything after that is already
covered by the review/confirm tests.

A PDF with a text layer is read with pypdf and never reaches Gemini. One
without, and any photo, needs Gemini, and without a key the upload is refused
with a message rather than left to guess.
"""
import io

import pytest
from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

from app import ocr

from conftest import PERSON

UPLOAD = f"/people/{PERSON['id']}/records/upload"
FORM = {"title": "Clinic note", "date": "2026-10-15"}

HELVETICA = {
    NameObject("/Type"): NameObject("/Font"),
    NameObject("/Subtype"): NameObject("/Type1"),
    NameObject("/BaseFont"): NameObject("/Helvetica"),
}


def pdf_bytes(*pages: str) -> bytes:
    """A real PDF carrying a text layer, built here rather than committed: a
    sample record checked into the repo would be demo data.

    pypdf writes PDFs but does not draw text, so each page's content stream is
    written out by hand — one `Tj` per line, which is all a text layer is.
    """
    writer = PdfWriter()
    for text in pages:
        page = writer.add_blank_page(width=595, height=842)
        body = "BT /F1 12 Tf 60 780 Td 16 TL\n" + "".join(
            f"({line.replace('(', '').replace(')', '')}) Tj T*\n"
            for line in text.split("\n")
        ) + "ET"
        stream = DecodedStreamObject()
        stream.set_data(body.encode("latin-1"))
        page[NameObject("/Contents")] = writer._add_object(stream)

        font = DictionaryObject()
        font.update(HELVETICA)
        fonts = DictionaryObject()
        fonts[NameObject("/F1")] = writer._add_object(font)
        resources = DictionaryObject()
        resources[NameObject("/Font")] = fonts
        page[NameObject("/Resources")] = resources
    buf = io.BytesIO()
    writer.write(buf)
    return buf.getvalue()


def blank_pdf() -> bytes:
    """A scanned page, as far as pypdf can tell: no text layer at all."""
    writer = PdfWriter()
    writer.add_blank_page(width=595, height=842)
    buf = io.BytesIO()
    writer.write(buf)
    return buf.getvalue()


def post(client, data: bytes, filename="note.pdf", ctype="application/pdf", **form):
    return client.post(
        UPLOAD, data={**FORM, **form},
        files={"file": (filename, io.BytesIO(data), ctype)},
    )


# ---------------- laying text out the way the extractor reads it ----------------

def test_a_blank_line_stays_a_paragraph_break():
    assert ocr.paragraphs("First para.\n\nSecond para.") == "First para.\n\nSecond para."


def test_lines_inside_a_paragraph_are_joined_back_into_running_text():
    """A PDF wraps mid-sentence; a paragraph per line would make each wrapped
    fragment its own citable span."""
    assert ocr.paragraphs(
        "Please bring the knee\nphysio referral to the\nnext appointment."
    ) == "Please bring the knee physio referral to the next appointment."


def test_runs_of_blank_lines_and_stray_whitespace_collapse():
    assert ocr.paragraphs("  A.  \n\n\n\n  B.  \n ") == "A.\n\nB."
    assert ocr.paragraphs("") == ""
    assert ocr.paragraphs(None) == ""


def test_windows_line_endings_are_read_as_line_endings():
    assert ocr.paragraphs("A.\r\n\r\nB.") == "A.\n\nB."


# ---------------- what the file is ----------------

def test_the_content_type_names_the_kind():
    assert ocr.kind_of("", "application/pdf") == "pdf"
    assert ocr.kind_of("", "image/png") == "image"
    assert ocr.kind_of("", "image/jpeg; charset=binary") == "image"


def test_the_suffix_names_it_when_the_browser_does_not():
    """A web upload routinely arrives as application/octet-stream."""
    assert ocr.kind_of("scan.PDF", "application/octet-stream") == "pdf"
    assert ocr.kind_of("photo.HEIC", "") == "image"


def test_anything_else_is_refused_by_name():
    with pytest.raises(ocr.UploadProblem) as e:
        ocr.kind_of("notes.docx", "application/vnd.openxmlformats-officedocument")
    assert "notes.docx" in str(e.value)
    assert "paste the text" in str(e.value)


# ---------------- a PDF that carries its own text ----------------

def test_a_text_pdf_is_read_without_gemini(client, graph, monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setattr(ocr, "transcribe",
                        lambda *a, **k: pytest.fail("a text PDF must not reach Gemini"))

    r = post(client, pdf_bytes("Please bring the knee physio referral."))

    assert r.status_code == 200, r.text
    body = r.json()
    assert body["read_by"] == "pdf-text"
    assert body["filename"] == "note.pdf"
    # It went through the ordinary draft flow: spans to cite, facts to review.
    assert body["id"]
    assert body["spans"]
    assert "knee physio referral" in body["spans"][0]["text"]
    assert [f["item"] for f in body["facts"] if f["type"] == "request"] == \
        ["knee_physio_referral"]


def test_each_page_of_a_pdf_becomes_its_own_citable_span(client, graph, monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    r = post(client, pdf_bytes("Page one text.", "Page two text."))

    assert r.status_code == 200, r.text
    spans = r.json()["spans"]
    assert len(spans) == 2
    assert "Page one" in spans[0]["text"] and "Page two" in spans[1]["text"]


def test_an_uploaded_record_is_still_only_a_draft(client, graph, monkeypatch):
    """The upload must not confirm anything: no fact may reach the graph."""
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    post(client, pdf_bytes("Please bring the insurance card."))

    written = " ".join(c for _, c, _ in graph.writes)
    assert "status:'draft'" in written
    assert "REQUESTS" not in written and "DOCUMENTS_RECEIPT" not in written


# ---------------- a photo, or a scan with no text layer ----------------

def test_a_photo_is_transcribed_by_gemini(client, graph, monkeypatch):
    seen = {}

    def fake(data, mime):
        seen["mime"] = mime
        seen["bytes"] = len(data)
        return "Please bring the insurance card.\n\nAppointment confirmed for 20 October."

    monkeypatch.setattr(ocr, "transcribe", fake)

    r = post(client, b"\xff\xd8\xff\xe0 not really a jpeg", filename="desk.jpg",
             ctype="image/jpeg")

    assert r.status_code == 200, r.text
    body = r.json()
    assert body["read_by"] == "gemini"
    assert seen["mime"] == "image/jpeg"
    assert len(body["spans"]) == 2, "blank lines in the transcript became paragraphs"


def test_a_scanned_pdf_falls_through_to_gemini_as_a_pdf(client, graph, monkeypatch):
    seen = {}

    def fake(data, mime):
        seen["mime"] = mime
        return "Front desk slip. The insurance card was received."

    monkeypatch.setattr(ocr, "transcribe", fake)

    r = post(client, blank_pdf(), filename="scan.pdf")

    assert r.status_code == 200, r.text
    assert r.json()["read_by"] == "gemini"
    assert seen["mime"] == "application/pdf", "Gemini has to be told it is a PDF"


def test_an_octet_stream_photo_is_still_sent_as_an_image(client, graph, monkeypatch):
    seen = {}

    def fake(data, mime):
        seen["mime"] = mime
        return "Please bring the old X-ray film."

    monkeypatch.setattr(ocr, "transcribe", fake)

    r = post(client, b"\x89PNG not really", filename="photo.png",
             ctype="application/octet-stream")

    assert r.status_code == 200, r.text
    assert seen["mime"] == "image/png"


# ---------------- the refusals ----------------

def test_an_empty_file_is_refused(client, graph):
    r = post(client, b"")
    assert r.status_code == 400
    assert "empty" in r.json()["detail"].lower()
    assert graph.writes == []


def test_a_file_over_the_limit_is_refused_with_its_size(client, graph):
    r = post(client, b"%PDF-" + b"\0" * (ocr.MAX_BYTES + 1))
    assert r.status_code == 400
    detail = r.json()["detail"]
    assert "10 MB" in detail and "MB" in detail
    assert graph.writes == []


def test_an_unsupported_file_is_refused(client, graph):
    r = post(client, b"PK\x03\x04 docx", filename="note.docx",
             ctype="application/vnd.openxmlformats-officedocument")
    assert r.status_code == 400
    assert "PDF" in r.json()["detail"]
    assert graph.writes == []


def test_a_photo_with_no_gemini_key_says_so_plainly(client, graph, monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)

    r = post(client, b"\xff\xd8\xff\xe0 photo", filename="desk.jpg", ctype="image/jpeg")

    assert r.status_code == 400
    detail = r.json()["detail"]
    assert "Gemini" in detail and "unavailable" in detail
    assert "Paste the text instead" in detail
    assert graph.writes == []


def test_a_gemini_failure_is_reported_short_not_as_raw_json(client, graph, monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "AIzaSyFAKEKEYFORTESTS000000")

    class Boom:
        class models:
            @staticmethod
            def generate_content(**kwargs):
                raise RuntimeError(
                    "429 RESOURCE_EXHAUSTED. {'error': {'code': 429, 'message': 'quota'}}")

    monkeypatch.setattr("app.agent._client", lambda: Boom())

    r = post(client, b"\xff\xd8\xff\xe0 photo", filename="desk.jpg", ctype="image/jpeg")

    assert r.status_code == 400
    detail = r.json()["detail"]
    assert "429 RESOURCE_EXHAUSTED" in detail
    assert "{" not in detail
    assert "AIzaSyFAKEKEYFORTESTS000000" not in detail


def test_a_transcript_with_no_text_in_it_is_refused(client, graph, monkeypatch):
    monkeypatch.setattr(ocr, "transcribe", lambda data, mime: "")

    r = post(client, b"\xff\xd8\xff\xe0 blur", filename="blur.jpg", ctype="image/jpeg")

    assert r.status_code == 400
    assert "No readable text" in r.json()["detail"]
    assert graph.writes == []


class FakeTypes:
    """Just enough of google-genai's content types to build one request."""

    class Content:
        def __init__(self, **kw):
            self.kw = kw

    class Part:
        def __init__(self, **kw):
            self.kw = kw

        @staticmethod
        def from_bytes(**kw):
            return kw


class FakeClient:
    class models:
        @staticmethod
        def generate_content(**kwargs):
            return object()


def _fake_gemini(monkeypatch, transcript: str):
    monkeypatch.setenv("GEMINI_API_KEY", "AIzaSyFAKEKEYFORTESTS000000")
    monkeypatch.setattr("app.agent._client", lambda: FakeClient())
    monkeypatch.setattr("app.agent._genai_types", lambda: FakeTypes())
    monkeypatch.setattr("app.agent._response_text", lambda resp: transcript)


def test_no_text_is_an_empty_transcript_not_the_words_NO_TEXT(monkeypatch):
    """The prompt's own escape hatch must not end up as the record's text."""
    _fake_gemini(monkeypatch, "NO_TEXT")
    assert ocr.transcribe(b"x", "image/jpeg") == ""


def test_a_transcript_is_laid_out_in_paragraphs(monkeypatch):
    """Blank lines are what the extractor splits citable spans on, so the
    transcript's own layout is what it is read back as."""
    _fake_gemini(monkeypatch, "Please bring the\ncard.\n\nSecond paragraph.")
    assert ocr.transcribe(b"x", "image/jpeg") == "Please bring the card.\n\nSecond paragraph."


def test_a_bad_date_is_refused_before_anything_is_read(client, graph):
    r = post(client, pdf_bytes("Please bring the insurance card."), date="15/10/2026")
    assert r.status_code == 422
    assert graph.writes == []


def test_the_upload_only_touches_that_persons_graph(client, graph, monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    post(client, pdf_bytes("Please bring the insurance card."))
    assert {name for name, _, _ in graph.writes} == {f"person_{PERSON['id']}"}


def test_an_unknown_profile_is_a_404(client, graph):
    r = client.post(
        "/people/nobody/records/upload", data=FORM,
        files={"file": ("note.pdf", io.BytesIO(pdf_bytes("Text.")), "application/pdf")},
    )
    assert r.status_code == 404
    assert graph.writes == []
