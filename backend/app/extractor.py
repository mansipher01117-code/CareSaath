"""Rule-based extractor (v1).

Turns a record's text into *draft* facts for human review. Nothing here is
written to the graph — the user reviews/edits on the Review screen and only
confirmed facts are stored.

Later you can swap `extract()` for an LLM/OCR-based extractor that returns
the same shape.
"""
import re

# item_key -> (display label, keywords)
ITEMS = {
    "lab_report": ("Existing lab report", ["lab report", "lab-report", "लैब रिपोर्ट"]),
    "bp_log": ("Home BP log", ["bp log", "blood pressure log", "bp-log", "बीपी लॉग"]),
}

REQUEST_WORDS = ["bring", "carry", "please share", "lana", "laana", "लाएं", "लाना", "request"]
RECEIPT_WORDS = ["received", "was received", "submitted", "mil gaya", "मिल गई", "प्राप्त"]
NEGATION_WORDS = ["no ", "not ", "nahi", "नहीं", "without"]

MONTHS = "January|February|March|April|May|June|July|August|September|October|November|December"
APPT_RE = re.compile(
    rf"(\d{{1,2}})\s+({MONTHS})[^.\n]*?(\d{{1,2}}(?::\d{{2}})?\s*(?:AM|PM|am|pm))", re.I
)


def split_paragraphs(text: str) -> list[str]:
    parts = [p.strip() for p in re.split(r"\n\s*\n|\r\n\s*\r\n", text.strip()) if p.strip()]
    return parts or [text.strip()]


def _items_in(p: str) -> list[str]:
    low = p.lower()
    return [k for k, (_, kws) in ITEMS.items() if any(kw in low for kw in kws)]


def extract(doc_id: str, text: str, record_date: str) -> dict:
    paragraphs = split_paragraphs(text)
    spans = []
    facts = []
    for i, p in enumerate(paragraphs, start=1):
        span_id = f"{doc_id}-P{i}"
        spans.append({"id": span_id, "index": i, "text": p})
        low = p.lower()
        items = _items_in(p)
        negated = any(w in f" {low} " for w in NEGATION_WORDS)

        if items and any(w in low for w in REQUEST_WORDS) and not negated:
            for it in items:
                facts.append({"type": "request", "item": it, "label": ITEMS[it][0], "span_id": span_id})
        elif items and any(w in low for w in RECEIPT_WORDS) and not negated:
            for it in items:
                facts.append({
                    "type": "receipt", "item": it, "label": ITEMS[it][0],
                    "span_id": span_id, "date": record_date,
                })
        elif items and negated:
            # e.g. "No receipt of the lab report is documented" -> informational only
            facts.append({
                "type": "absence_note", "items": items, "span_id": span_id,
                "label": "Receipt not documented in this record",
            })

        m = APPT_RE.search(p)
        if m and ("appointment" in low or "अपॉइंटमेंट" in p):
            facts.append({
                "type": "appointment", "span_id": span_id,
                "date": f"{m.group(1)} {m.group(2).title()}", "time": m.group(3).upper(),
                "label": "Appointment",
            })
    return {"spans": spans, "facts": facts, "extractor": "rule-based-v1"}
