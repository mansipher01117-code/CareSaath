"""Rule-based extractor (v1).

Turns a record's text into *draft* facts for human review. Nothing here is
written to the graph — the user reviews/edits/renames on the Review screen and
only confirmed facts are stored.

Nothing is hardcoded to a particular item: any "please bring / bring / carry X"
request and any "X was received" receipt produces a follow-up whose key is
normalized from X itself.

Later you can swap `extract()` for an LLM/OCR-based extractor that returns
the same shape.
"""
import re
import unicodedata

MAX_KEY_LEN = 60
MAX_OBJECT_LEN = 90

# "bring / carry / collect X" — the verb carries the request on its own.
REQUEST_RE = re.compile(
    r"\b(?:bring|carry|collect|fetch)\b\s+(?:along\s+)?(?P<obj>[^.;!?\n]+)", re.I
)
# "please share / send / submit X" — only a request when asked politely, so
# ordinary narration ("the clinic sent a reminder") isn't mistaken for one.
POLITE_REQUEST_RE = re.compile(
    r"\bplease\s+(?:also\s+)?(?:share|send|submit|provide|attach|upload|keep)\b\s+(?P<obj>[^.;!?\n]+)",
    re.I,
)
# Hindi / Hinglish puts the object before the verb. Devanagari verbs end in a
# combining mark, which is not a word character, so they take no trailing \b.
HI_REQUEST_RE = re.compile(
    r"(?P<obj>[^.;!?\n।]{2,90}?)\s*(?:लेकर\s+आएं|साथ\s+लाएं|लेकर\s+आना|लाएं|लाना)"
)
HINGLISH_REQUEST_RE = re.compile(
    r"(?P<obj>[^.;!?\n]{2,90}?)\s+(?:laakar\s+aayein|laana|lana)\b", re.I
)

# "X was received / submitted / handed over"
RECEIPT_RE = re.compile(
    r"(?P<obj>[^.;!?\n]{2,90}?)\s+(?:was|were|has\s+been|have\s+been|is|are)\s+"
    r"(?:received|submitted|collected|handed\s+over|handed\s+in|dropped\s+off|delivered)\b",
    re.I,
)
# "we received X" / "the clinic received X"
ACTIVE_RECEIPT_RE = re.compile(
    r"\b(?:received|collected|accepted)\b\s+(?P<obj>[^.;!?\n]+)", re.I
)
HI_RECEIPT_RE = re.compile(
    r"(?P<obj>[^.;!?\n।]{2,90}?)\s*(?:मिल\s+(?:गई|गया|गये|गयी)|प्राप्त\s+(?:हुआ|हुई|हुए))"
)
HINGLISH_RECEIPT_RE = re.compile(
    r"(?P<obj>[^.;!?\n]{2,90}?)\s+(?:mil\s+(?:gaya|gayi|gai|gaye)|receive\s+ho\s+gay\w+)\b", re.I
)

# "No receipt of X is documented" — informational, never a status change.
ABSENCE_RE = re.compile(
    r"\bno\s+(?:documented\s+)?(?:receipts?|record|acknowledg\w*)\s+(?:of|for)\s+"
    r"(?P<obj>[^.;!?\n]+?)(?:\s+(?:is|are|was|were|has|have)\b|[.;!?\n]|$)",
    re.I,
)

NEGATION_RE = re.compile(r"\b(?:no|not|never|nahi|without)\b|नहीं", re.I)

# Where an object ends: "bring the lab report >to the next appointment<".
TRAIL_RE = re.compile(
    r"\s+(?:to|at|for|with|when|before|after|during|on|in|by|next|so|if|from"
    r"|today|yesterday|tomorrow|now|already|recently|again|also|please)\b.*$",
    re.I,
)
# Leading scene-setting: "On 15 October, the lab report was received".
LEAD_RE = re.compile(r"^(?:on|at|in|during|per|as\s+per|according\s+to)\b[^,]*,\s*", re.I)
SPLIT_RE = re.compile(r"\s*(?:,|;|&|\band\b|\bor\b|\bplus\b|और|तथा|या)\s*", re.I)
DETERMINERS = {
    "the", "a", "an", "his", "her", "their", "your", "my", "our", "its",
    "any", "all", "both", "that", "this", "these", "those", "same",
}
# A phrase made only of these is not an item worth tracking.
NOT_AN_ITEM = {
    "it", "them", "him", "he", "she", "they", "we", "you", "i", "us", "me",
    "one", "ones", "thing", "things", "something", "anything", "everything",
    "patient", "report", "reports",
}

MONTHS = "January|February|March|April|May|June|July|August|September|October|November|December"
MONTH_NUMBERS = {m.lower(): i for i, m in enumerate(MONTHS.split("|"), start=1)}

# A calendar date written inside a sentence: "on 20 November 2026",
# "November 20", "2026-11-20". The year is optional, because a clinic note
# routinely says only the day and the month.
SENTENCE_DATE_RE = re.compile(
    rf"\b(?:(?P<iso>\d{{4}}-\d{{2}}-\d{{2}})"
    rf"|(?P<day>\d{{1,2}})(?:st|nd|rd|th)?\s+(?P<month>{MONTHS})"
    rf"|(?P<month2>{MONTHS})\s+(?P<day2>\d{{1,2}})(?:st|nd|rd|th)?)"
    rf"\s*,?\s*(?P<year>\d{{4}})?\b",
    re.I,
)
# The year is captured when the text gives one. A note that says "20 October"
# and nothing else genuinely does not say which year, so the year is returned
# empty rather than assumed to be this one — "20 October" in a December note
# usually means next year, and guessing silently is how an appointment card
# ends up confidently wrong.
APPT_RE = re.compile(
    rf"(\d{{1,2}})\s+({MONTHS})\s*,?\s*(\d{{4}})?[^.\n]*?"
    rf"(\d{{1,2}}(?::\d{{2}})?\s*(?:AM|PM|am|pm))",
    re.I,
)

# Sentence end, including the Devanagari danda. Negation and absence are read
# per sentence, not per paragraph: one paragraph often carries a receipt and a
# separate "no receipt of X" clause, and judging the whole paragraph by its
# negative clause threw the positive one away.
SENTENCE_RE = re.compile(r"(?<=[.!?।])\s+")

STRIP_CHARS = " \t\"'“”‘’()[]:-–—"


def normalize_key(phrase: str) -> str:
    """'The existing lab report ' -> 'existing_lab_report'. This is also the
    rename key: two labels that normalize the same are the same follow-up."""
    # Keep combining marks, or Devanagari words would shatter into fragments.
    kept = "".join(
        ch if (ch.isalnum() or unicodedata.category(ch) in ("Mn", "Mc")) else " "
        for ch in (phrase or "").lower()
    )
    words = kept.split()
    while words and words[0] in DETERMINERS:
        words.pop(0)
    return "_".join(words)[:MAX_KEY_LEN].strip("_")


def tokens(phrase: str) -> set[str]:
    """Content words of a phrase, for matching a question against item names."""
    return {w for w in normalize_key(phrase).split("_") if len(w) > 1}


def clean_phrase(phrase: str) -> str:
    """Trim an extracted object down to the item itself, keeping its own words."""
    p = LEAD_RE.sub("", (phrase or "").strip())
    p = TRAIL_RE.sub("", p).strip(STRIP_CHARS)
    words = p.split()
    while words and words[0].lower() in DETERMINERS:
        words.pop(0)
    return " ".join(words)[:MAX_OBJECT_LEN].strip()


def label_for(phrase: str) -> str:
    p = clean_phrase(phrase)
    return p[:1].upper() + p[1:] if p else p


def items_from(obj: str) -> list[tuple[str, str]]:
    """Split a captured object into (key, label) pairs."""
    out, seen = [], set()
    for part in SPLIT_RE.split(obj or ""):
        label = label_for(part)
        key = normalize_key(label)
        if not key or key in seen or key in NOT_AN_ITEM or len(key) < 2:
            continue
        seen.add(key)
        out.append((key, label))
    return out


def split_paragraphs(text: str) -> list[str]:
    parts = [p.strip() for p in re.split(r"\n\s*\n|\r\n\s*\r\n", text.strip()) if p.strip()]
    return parts or [text.strip()]


def split_sentences(paragraph: str) -> list[str]:
    parts = [s.strip() for s in SENTENCE_RE.split(paragraph) if s.strip()]
    return parts or [paragraph.strip()]


def sentence_date(sentence: str, record_date: str) -> str:
    """The calendar date a sentence names, as ``YYYY-MM-DD``, or "" for none.

    A sentence that gives a day and month but no year is read against the
    record's own year: "received on 20 November" in a 2026 note is 20 November
    2026. The record date is never a *substitute* for a date the sentence does
    give — that is what put a document's date on an event that happened on a
    different day.
    """
    m = SENTENCE_DATE_RE.search(sentence or "")
    if not m:
        return ""
    if m.group("iso"):
        return m.group("iso")
    day = int(m.group("day") or m.group("day2"))
    month = MONTH_NUMBERS.get((m.group("month") or m.group("month2")).lower())
    year = m.group("year") or (record_date or "")[:4]
    if not (month and 1 <= day <= 31 and year.isdigit()):
        return ""
    return f"{int(year):04d}-{month:02d}-{day:02d}"


def _first_match(paragraph: str, *regexes) -> str | None:
    for rx in regexes:
        m = rx.search(paragraph)
        if m:
            return m.group("obj")
    return None


def extract(doc_id: str, text: str, record_date: str) -> dict:
    paragraphs = split_paragraphs(text)
    spans, facts = [], []
    for i, p in enumerate(paragraphs, start=1):
        span_id = f"{doc_id}-P{i}"
        spans.append({"id": span_id, "index": i, "text": p})

        # One sentence's negation says nothing about the next one's.
        for sentence in split_sentences(p):
            absence = ABSENCE_RE.search(sentence)
            if absence:
                found = items_from(absence.group("obj"))
                if found:
                    facts.append({
                        "type": "absence_note", "span_id": span_id,
                        "items": [k for k, _ in found],
                        "label": "Receipt not documented: " + ", ".join(l for _, l in found),
                    })
                continue
            negated = bool(NEGATION_RE.search(sentence))
            receipt_obj = _first_match(
                sentence, RECEIPT_RE, HI_RECEIPT_RE, HINGLISH_RECEIPT_RE, ACTIVE_RECEIPT_RE
            )
            if receipt_obj and not negated:
                # When the sentence says when the item was received, that is
                # the receipt's event date; the document's own date only
                # stands in when the sentence names no date at all, and says
                # so rather than passing itself off as the event date.
                on = sentence_date(sentence, record_date)
                for key, label in items_from(receipt_obj):
                    facts.append({
                        "type": "receipt", "item": key, "label": label,
                        "span_id": span_id, "date": on or record_date,
                        "date_source": "sentence" if on else "document",
                    })
            request_obj = _first_match(
                sentence, POLITE_REQUEST_RE, REQUEST_RE, HI_REQUEST_RE, HINGLISH_REQUEST_RE
            )
            if request_obj and not negated:
                for key, label in items_from(request_obj):
                    facts.append({
                        "type": "request", "item": key, "label": label, "span_id": span_id,
                    })

        m = APPT_RE.search(p)
        if m and ("appointment" in p.lower() or "अपॉइंटमेंट" in p):
            facts.append({
                "type": "appointment", "span_id": span_id,
                "date": f"{m.group(1)} {m.group(2).title()}", "year": m.group(3) or "",
                "time": m.group(4).upper(), "label": "Appointment",
            })

    seen, unique = set(), []
    for f in facts:
        k = (f["type"], f.get("item"), f["span_id"])
        if k in seen:
            continue
        seen.add(k)
        unique.append(f)
    return {"spans": spans, "facts": unique, "extractor": "rule-based-v1"}
