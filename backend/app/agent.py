"""CareSaath agent — a Gemini LLM with function calling over the person's graph.

The model never sees the database. It sees four read-only tools, each already
bound to the one person being asked about (`tools_for`), so a question asked
about one family member cannot reach another's records. It chooses the tools,
reads what they return, and writes the answer as structured *claims* — each
claim carrying the (doc_id, span_id) pairs it rests on.

Grounding is enforced on this side of the wire, not asked for politely:
`validate_sources()` builds the set of (doc_id, span_id) pairs the tools
actually returned and drops every citation that is not in it. A model that
invents a source ends up with a claim that has no evidence behind it, never
with a fabricated chip in the UI.

If the key is missing, the API fails or is rate-limited, or the JSON comes back
malformed, the deterministic rules agent answers instead and the response says
so (`"engine": "rules"`). The rules engine is the original v1 agent and is kept
whole: it is the floor the product never falls below.
"""
from __future__ import annotations

import json
import os
import re
import time

from . import graph_ops as g
from .extractor import tokens

DEFAULT_MODEL = "gemini-flash-latest"
LLM_TIMEOUT_S = 20
MAX_TOOL_TURNS = 6


class LlmUnavailable(Exception):
    """The LLM could not produce a usable grounded answer. Falls back to rules."""


def _model() -> str:
    """Read at call time, so .env and tests both get a say."""
    return (os.getenv("GEMINI_MODEL") or "").strip() or DEFAULT_MODEL


# ---------------- tools (names match the 03 — Tool Contract doc) ----------------

def tools_for(pid: str) -> dict:
    """Bind the graph tools to one person, so no tool can read another's data.

    All four are read-only and take no person argument: `pid` is closed over
    here, before the model is ever asked anything.
    """
    return {
        "retrieve_patient_context": lambda: {
            "person": g.person(pid), "appointments": g.appointments(pid)
        },
        "list_unresolved_followups": lambda: g.preparation(pid),
        "latest_change": lambda: g.latest_change(pid),
        "inspect_source_span": lambda doc_id="", span_id="": inspect_source_span(
            pid, doc_id, span_id
        ),
    }


def inspect_source_span(pid: str, doc_id: str, span_id: str) -> dict:
    """The exact text of one citable paragraph.

    Only from a *confirmed* document of this person: a draft is still under
    review and must never reach an answer, and another person's documents live
    in another graph entirely.
    """
    doc_id, span_id = (doc_id or "").strip(), (span_id or "").strip()
    doc = g.get_document(pid, doc_id) if doc_id else None
    if not doc or doc.get("status") != "confirmed":
        return {"error": f"No confirmed document {doc_id!r} for this person."}
    span = next((s for s in doc.get("spans") or [] if s.get("id") == span_id), None)
    if not span:
        return {"error": f"Document {doc_id} has no span {span_id!r}."}
    return {"doc_id": doc["id"], "span_id": span["id"], "doc_title": doc["title"],
            "date": doc["date"], "text": span["text"]}


TOOL_DECLARATIONS = [
    {
        "name": "retrieve_patient_context",
        "description": (
            "The person (name, relation, caregiver, number of confirmed records) and "
            "every confirmed appointment with the evidence that confirms it. "
            "Start here when the question is about who this is or when they are seen."
        ),
    },
    {
        "name": "list_unresolved_followups",
        "description": (
            "Every follow-up item tracked for this person, with the evidence that "
            "requested it (requested_by) and the evidence that documents it arriving "
            "(receipts). status is receipt_documented when a receipt exists, otherwise "
            "receipt_not_documented. Use this for anything about what is pending, what "
            "to bring, or whether something was received."
        ),
    },
    {
        "name": "latest_change",
        "description": (
            "The last change record: which document caused it, and which follow-ups "
            "changed, stayed the same, or were newly added. Use this for 'what changed'."
        ),
    },
    {
        "name": "inspect_source_span",
        "description": (
            "The exact paragraph text behind one citation, from a confirmed document of "
            "this person only. Use it to check or quote wording before you rely on it."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "doc_id": {"type": "string", "description": "Document id, e.g. D01."},
                "span_id": {"type": "string", "description": "Span id, e.g. D01-P2."},
            },
            "required": ["doc_id", "span_id"],
        },
    },
]

SYSTEM = """You are CareSaath, a family health-record companion. You explain what one
person's own confirmed health records say. You are not a clinician.

Read that person's records with the tools. Every tool is already scoped to the one
person being asked about, so there is nothing to look up about anybody else.

Rules you must follow:

1. Answer ONLY from what the tools returned this turn. No outside knowledge, no
   guessing, no filling in a likely detail. If the tools do not show it, say it is not
   documented in the confirmed records.
2. "Receipt documented" means the record says the item was received. It does NOT mean a
   doctor looked at it or reviewed it. Never say or imply that it was reviewed.
3. An instruction in an older record is described as what that record said, on its date
   — never as advice for now. Say "the 12 October note asked for the lab report", not
   "you should bring the lab report".
4. Never give a diagnosis, a dosage, a medication change, or any medical advice, and
   never say whether a result is good, bad, normal or worrying. If that is what was
   asked, set "refused": true and reply with one polite sentence: CareSaath only
   explains what the records say, so that is a question for their doctor.
5. Answer in the requested language. "en" = plain English. "hi" = Hindi/Hinglish in
   Latin script. Keep document ids, span ids, dates and item names exactly as the tools
   returned them — never translate, reformat or tidy those.
6. Cite the evidence. inspect_source_span gives you the exact paragraph if you need to
   check or quote the wording.

Reply with ONE JSON object and nothing else — no prose around it, no code fence:

{"intent": "preparation|appointment|changes|item|source|refusal|other",
 "refused": false,
 "claims": [{"text": "one sentence",
             "sources": [{"doc_id": "D01", "span_id": "D01-P2"}]}]}

- One claim per thing you state, one sentence each, in the requested language.
- Every claim that states something from the records lists the (doc_id, span_id) pairs
  it rests on, exactly as the tools returned them. A pair the tools did not return is
  dropped on arrival, leaving that claim with no evidence behind it — so never invent,
  guess or adjust one.
- A claim with no sources is right only for a refusal, or for saying that something is
  not documented in the confirmed records.
"""


# ---------------- routing (rules engine) ----------------

CHANGE_WORDS = ["change", "changed", "badla", "बदला", "latest", "new record", "naya"]
APPT_WORDS = ["appointment", "kab", "कब", "अपॉइंटमेंट", "visit"]
PREP_WORDS = ["clarify", "prepare", "pending", "bring", "lana"]

# Words that say what kind of question this is, not which item it is about.
STOPWORDS = {
    "what", "when", "where", "which", "who", "whom", "how", "why", "should",
    "could", "would", "will", "shall", "do", "does", "did", "is", "are", "was",
    "were", "be", "been", "am", "the", "an", "and", "or", "but", "to", "for",
    "of", "at", "in", "on", "by", "with", "from", "about", "before", "after",
    "my", "our", "your", "his", "her", "their", "its", "me", "you", "we", "us",
    "it", "they", "them", "him", "she", "he", "need", "needs", "needed", "get",
    "got", "have", "has", "had", "any", "all", "still", "yet", "now", "already",
    "receive", "received", "receipt", "receipts", "documented", "document",
    "bring", "carry", "pending", "clarify", "prepare", "preparation", "ready",
    "appointment", "visit", "doctor", "clinic", "record", "records", "latest",
    "new", "change", "changed", "status", "update", "tell", "show", "know",
    # Hinglish / Hindi
    "kya", "hai", "hain", "ka", "ki", "ke", "ko", "se", "mein", "hua", "hui",
    "nahi", "kab", "kaise", "kaun", "kahan", "mujhe", "humein", "hume", "apna",
    "apne", "liye", "kar", "karna", "karni", "kiya", "laana", "lana", "chahiye",
    "batao", "bataiye", "wala", "sab", "kuch", "koi", "mila", "mil",
    "क्या", "है", "हैं", "का", "की", "के", "को", "से", "में", "नहीं", "कब",
    "कैसे", "कौन", "कहाँ", "मुझे", "हमें", "लिए", "चाहिए", "सब",
}


# Questions the rules engine must not answer out of the records. The LLM is
# told to refuse these in its system prompt; the rules engine has no judgement
# to apply mid-answer, so it declines up front instead of replying with
# whatever the router happened to match — which is how "should I halve her
# evening dose?" used to come back as appointment details.
# Deliberately narrow, in two parts. A clinical judgement word refuses on its
# own; asking-for-advice phrasing only refuses when it is asked *about*
# something clinical. "What should I clarify before the appointment?" is
# advice-seeking phrasing about nothing clinical, and must still be answered;
# "was the medicine list received?" names a medicine but asks what the record
# says, and must still be answered too.
CLINICAL_RE = re.compile(r"\b(?:dose|dosage|diagnos\w*)\b|\bis\s+it\s+(?:safe|serious|dangerous)\b",
                         re.I)
ADVICE_FRAME_RE = re.compile(
    r"\b(?:should|shall|can|could|may)\s+(?:i|we|she|he|they)\b"
    r"|\bis\s+it\s+(?:normal|ok|okay|fine)\b"
    r"|\bhow\s+(?:much|many)\b"
    r"|\bkya\s+karna\s+chahiye\b"
    r"|\bkitn[aiī]\b",
    re.I,
)
ADVICE_SUBJECT_RE = re.compile(
    r"\b(?:medicine|medicines|medication|tablet|tablets|pill|pills|painkiller|antibiotic"
    r"|insulin|injection|syrup|drug|drugs|dawa|dawai|goli|khurak)\b"
    r"|\b(?:halve|double|skip|reduce|increase|stop|badha|band)\b",
    re.I,
)

REFUSAL = {
    "en": ("CareSaath only explains what the records say, so it can't advise on "
           "medicines, doses or a diagnosis — please ask the doctor."),
    "hi": ("CareSaath sirf yeh batata hai ki records mein kya likha hai — dawa, "
           "khurak ya diagnosis par salah nahi de sakta. Doctor se poochhein."),
}


def needs_refusal(question: str) -> bool:
    q = question or ""
    if CLINICAL_RE.search(q):
        return True
    return bool(ADVICE_FRAME_RE.search(q) and ADVICE_SUBJECT_RE.search(q))


def route(q: str) -> tuple[str, list[str]]:
    low = q.lower()
    if any(w in low for w in CHANGE_WORDS):
        return "changes", ["latest_change", "list_unresolved_followups"]
    if any(w in low for w in APPT_WORDS) and not any(w in low for w in PREP_WORDS):
        return "appointment", ["retrieve_patient_context"]
    return "preparation", ["retrieve_patient_context", "list_unresolved_followups"]


def match_items(question: str, items: list[dict]) -> list[dict]:
    """Follow-ups this question names, by overlap with their own words."""
    asked = tokens(question) - STOPWORDS
    if not asked:
        return []
    return [i for i in items if (tokens(i.get("label") or "") | tokens(i.get("item") or "")) & asked]


# ---------------- answer text (rules engine) ----------------

T = {
    "en": {
        "documented": "{label}: receipt is documented ({date}, {doc}).",
        "not_documented": "{label}: receipt is not documented in the available records.",
        "requested": "{label} was requested in {doc} ({date}).",
        "appt": "Appointment confirmed for {date} at {time} ({doc}).",
        "no_appt": "No confirmed appointment found in the records.",
        "clarify": "You may want to clarify before the appointment: {items}.",
        "all_done": "All requested items have documented receipts.",
        "no_items": "No follow-up items are being tracked yet.",
        "no_change": "No record has been confirmed yet.",
        "changed_hdr": "After {doc} ({date}) was confirmed:",
        "changed": "{label} changed: {frm} → {to}.",
        "unchanged": "{label} stayed the same: {st}.",
        "added": "New item tracked: {label} ({to}).",
        "nothing": "I couldn't find that in the confirmed records.",
        "receipt_documented": "receipt documented",
        "receipt_not_documented": "receipt not documented",
        "note": "Note: 'received' means the record says it was received — not that a doctor reviewed it.",
    },
    "hi": {
        "documented": "{label}: receipt documented hai ({date}, {doc}).",
        "not_documented": "{label}: available records mein receipt ka documentation nahi mila.",
        "requested": "{label} ki request {doc} ({date}) mein ki gayi thi.",
        "appt": "Appointment {date}, {time} ke liye confirmed hai ({doc}).",
        "no_appt": "Records mein koi confirmed appointment nahi mila.",
        "clarify": "Appointment se pehle ye clarify kar sakte hain: {items}.",
        "all_done": "Saare requested items ki receipt documented hai.",
        "no_items": "Abhi koi follow-up item track nahi ho raha.",
        "no_change": "Abhi tak koi record confirm nahi hua.",
        "changed_hdr": "{doc} ({date}) confirm hone ke baad:",
        "changed": "{label} badla: {frm} → {to}.",
        "unchanged": "{label} same raha: {st}.",
        "added": "Naya item track ho raha hai: {label} ({to}).",
        "nothing": "Confirmed records mein ye information nahi mili.",
        "receipt_documented": "receipt documented",
        "receipt_not_documented": "receipt documented nahi",
        "note": "Dhyan dein: 'received' ka matlab record mein receive likha hai — doctor ne review kiya, ye nahi.",
    },
}


def _src(span_id, doc_id):
    return {"span_id": span_id, "doc_id": doc_id}


def _claim(text, sources=()):
    return {"text": text, "sources": list(sources)}


def _change_src(item: dict | None, doc_id: str) -> list[dict]:
    """The span behind one changed follow-up, preferring the document that moved it."""
    pool = [x for x in (item or {}).get("receipts", []) + (item or {}).get("requested_by", [])
            if x.get("span_id") and x.get("doc_id")]
    hit = next((x for x in pool if x["doc_id"] == doc_id), None) or (pool[0] if pool else None)
    return [_src(hit["span_id"], hit["doc_id"])] if hit else []


def compose(intent, results, lang, items=None) -> list[dict]:
    """The rules answer, as claims that each carry their own sources."""
    t = T.get(lang, T["en"])
    claims: list[dict] = []

    if intent == "changes":
        ch = results["latest_change"]
        if not ch:
            return [_claim(t["no_change"])]
        by_id = {i["id"]: i for i in results.get("list_unresolved_followups") or []}
        claims.append(_claim(t["changed_hdr"].format(doc=ch["doc_id"], date=ch["doc_date"])))
        for c in ch["changed"]:
            claims.append(_claim(
                t["changed"].format(label=c["label"], frm=t[c["from"]], to=t[c["to"]]),
                _change_src(by_id.get(c["id"]), ch["doc_id"])))
        for c in ch["added"]:
            claims.append(_claim(t["added"].format(label=c["label"], to=t[c["to"]]),
                                 _change_src(by_id.get(c["id"]), ch["doc_id"])))
        for c in ch["unchanged"]:
            claims.append(_claim(t["unchanged"].format(label=c["label"], st=t[c["status"]]),
                                 _change_src(by_id.get(c["id"]), ch["doc_id"])))
        return claims

    if intent == "appointment":
        appts = results["retrieve_patient_context"]["appointments"]
        if not appts:
            return [_claim(t["no_appt"])]
        for a in appts:
            s = next((x for x in a["sources"] if x.get("span_id")), None)
            claims.append(_claim(
                t["appt"].format(date=a["date"], time=a["time"], doc=s["doc_id"] if s else "?"),
                [_src(s["span_id"], s["doc_id"])] if s else []))
        return claims

    if items is None:
        items = results["list_unresolved_followups"]
    if not items:
        return [_claim(t["nothing"] if intent == "item" else t["no_items"])]

    pending = []
    for i in items:
        for rq in i["requested_by"][:1]:
            claims.append(_claim(
                t["requested"].format(label=i["label"], doc=rq["doc_id"], date=rq["date"]),
                [_src(rq["span_id"], rq["doc_id"])]))
        if i["receipts"]:
            r = i["receipts"][0]
            claims.append(_claim(
                t["documented"].format(label=i["label"], date=r["date"], doc=r["doc_id"]),
                [_src(r["span_id"], r["doc_id"])]))
        else:
            claims.append(_claim(t["not_documented"].format(label=i["label"])))
            pending.append(i["label"])

    if intent == "preparation":
        ctx = results["retrieve_patient_context"]
        for a in ctx["appointments"][:1]:
            s = next((x for x in a["sources"] if x.get("span_id")), None)
            claims.insert(0, _claim(
                t["appt"].format(date=a["date"], time=a["time"], doc=s["doc_id"] if s else "?"),
                [_src(s["span_id"], s["doc_id"])] if s else []))
        claims.append(_claim(
            t["clarify"].format(items=", ".join(pending)) if pending else t["all_done"]))
    if any(i["receipts"] for i in items):
        claims.append(_claim(t["note"]))
    return claims


# ---------------- grounding ----------------

def evidence_pairs(obj, out: set | None = None) -> set:
    """Every (doc_id, span_id) pair the tools actually returned.

    Walks the raw tool results, so it does not matter which tool produced a
    citation or how deeply nested it was. A tool's *error* message carries no
    doc_id/span_id keys, so quoting an id back in an error can never make that
    id citable.
    """
    if out is None:
        out = set()
    if isinstance(obj, dict):
        d, s = obj.get("doc_id"), obj.get("span_id")
        if isinstance(d, str) and isinstance(s, str) and d and s:
            out.add((d, s))
        for v in obj.values():
            evidence_pairs(v, out)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            evidence_pairs(v, out)
    return out


def validate_sources(sources, results):
    """Keep only citations the tools returned — the guard on the LLM's output."""
    allowed = evidence_pairs(results)
    seen, out = set(), []
    for s in sources or []:
        if not isinstance(s, dict):
            continue
        key = (str(s.get("doc_id") or ""), str(s.get("span_id") or ""))
        if key in allowed and key not in seen:
            seen.add(key)
            out.append({"span_id": key[1], "doc_id": key[0]})
    return out


def _enrich(pid, s, cache):
    """Attach the paragraph text and document title the UI shows on a chip."""
    doc_id = s["doc_id"]
    if doc_id not in cache:
        cache[doc_id] = g.get_document(pid, doc_id)
    doc = cache[doc_id] or {}
    span = next((x for x in doc.get("spans") or [] if x.get("id") == s["span_id"]), None)
    return {**s, "text": span["text"] if span else "",
            "doc_title": doc.get("title") or "", "date": doc.get("date") or ""}


def _respond(pid, question, lang, intent, engine, claims, results, trace, matched_items=()):
    """The one place the response contract is built, for both engines."""
    cache: dict = {}
    out_claims, top, seen = [], [], set()
    for c in claims:
        srcs = [_enrich(pid, s, cache) for s in validate_sources(c.get("sources"), results)]
        out_claims.append({"text": c["text"], "sources": srcs})
        for s in srcs:
            key = (s["doc_id"], s["span_id"])
            if key not in seen:
                seen.add(key)
                top.append(s)
    return {"question": question, "lang": lang, "intent": intent, "engine": engine,
            "answer": [c["text"] for c in out_claims], "claims": out_claims,
            "sources": top, "trace": trace, "matched_items": list(matched_items)}


# ---------------- rules engine ----------------

def rules_ask(pid: str, question: str, lang: str = "en", note: dict | None = None):
    tools = tools_for(pid)
    trace = [note] if note else []
    if needs_refusal(question):
        # No tools are read: there is nothing in the records that answers this.
        return _respond(pid, question, lang, "refusal", "rules",
                        [_claim(REFUSAL.get(lang, REFUSAL["en"]))], {}, trace)

    intent, tool_names = route(question)
    results: dict = {}
    for name in tool_names:
        results[name] = tools[name]()
        trace.append({"tool": name, "args": {}, "returned": _summarize(results[name])})

    items = None
    if intent == "preparation":
        matched = match_items(question, results["list_unresolved_followups"])
        if matched:
            intent, items = "item", matched

    claims = compose(intent, results, lang, items)
    return _respond(pid, question, lang, intent, "rules", claims, results, trace,
                    [i["id"] for i in items] if items else [])


# ---------------- LLM engine ----------------

def _client():
    """A Gemini client, or LlmUnavailable. The SDK is imported lazily, so the
    rules engine still answers on a machine where it was never installed."""
    key = (os.getenv("GEMINI_API_KEY") or "").strip()
    if not key:
        raise LlmUnavailable("GEMINI_API_KEY is not set")
    try:
        from google import genai
    except ImportError as e:  # pragma: no cover - depends on the install
        raise LlmUnavailable(f"google-genai is not installed ({e})") from e
    return genai.Client(api_key=key, http_options={"timeout": LLM_TIMEOUT_S * 1000})


def _function_calls(resp) -> list:
    out = []
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None):
                out.append(fc)
    return out


def _response_text(resp) -> str:
    text = getattr(resp, "text", None)
    if text:
        return text
    chunks = []
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        for part in getattr(content, "parts", None) or []:
            if getattr(part, "text", None):
                chunks.append(part.text)
    return "\n".join(chunks)


def _parse_json(text: str) -> dict:
    s = re.sub(r"^```(?:json)?|```$", "", (text or "").strip(), flags=re.I).strip()
    i, j = s.find("{"), s.rfind("}")
    if i < 0 or j <= i:
        raise LlmUnavailable("model did not return a JSON object")
    try:
        data = json.loads(s[i:j + 1])
    except json.JSONDecodeError as e:
        raise LlmUnavailable(f"invalid JSON from model: {e}") from e
    if not isinstance(data, dict):
        raise LlmUnavailable("model returned JSON that is not an object")
    return data


def _claims_from(data: dict) -> tuple[list[dict], str]:
    raw = data.get("claims")
    if not isinstance(raw, list) or not raw:
        raise LlmUnavailable("model returned no claims")
    claims = []
    for c in raw:
        if not isinstance(c, dict):
            raise LlmUnavailable("model returned a malformed claim")
        text = str(c.get("text") or "").strip()
        if not text:
            continue
        srcs = c.get("sources")
        claims.append({"text": text, "sources": srcs if isinstance(srcs, list) else []})
    if not claims:
        raise LlmUnavailable("model returned claims with no text")
    intent = data.get("intent")
    intent = intent.strip() if isinstance(intent, str) and intent.strip() else "other"
    return claims, ("refusal" if data.get("refused") else intent)


def llm_ask(pid: str, question: str, lang: str):
    """One tool-calling conversation, bounded in turns and wall-clock time."""
    client = _client()
    tools = tools_for(pid)
    deadline = time.monotonic() + LLM_TIMEOUT_S
    contents: list = [{"role": "user", "parts": [{"text": f"lang: {lang}\nquestion: {question}"}]}]
    config = {
        "system_instruction": SYSTEM,
        "tools": [{"function_declarations": TOOL_DECLARATIONS}],
        "automatic_function_calling": {"disable": True},
        "temperature": 0,
    }
    evidence: list = []   # every tool result, verbatim — what citations are checked against
    trace: list = []

    for _ in range(MAX_TOOL_TURNS):
        if time.monotonic() > deadline:
            raise LlmUnavailable(f"gave up after {LLM_TIMEOUT_S}s")
        resp = client.models.generate_content(model=_model(), contents=contents, config=config)
        calls = _function_calls(resp)
        if not calls:
            claims, intent = _claims_from(_parse_json(_response_text(resp)))
            return _respond(pid, question, lang, intent, "llm", claims, evidence, trace)

        contents.append(resp.candidates[0].content)
        parts = []
        for call in calls:
            name = getattr(call, "name", "") or ""
            args = dict(getattr(call, "args", None) or {})
            if name not in tools:
                result = {"error": f"Unknown tool {name!r}."}
            else:
                try:
                    result = tools[name](**args)
                except TypeError as e:
                    result = {"error": f"Bad arguments for {name}: {e}"}
            evidence.append({"tool": name, "args": args, "result": result})
            trace.append({"tool": name, "args": args, "returned": _summarize(result)})
            parts.append({"function_response": {"name": name, "response": {"result": result}}})
        contents.append({"role": "tool", "parts": parts})

    raise LlmUnavailable(f"no answer after {MAX_TOOL_TURNS} tool turns")


# ---------------- entry point ----------------

def ask(pid: str, question: str, lang: str = "en"):
    """Answer with the LLM; fall back to the rules engine and say which answered."""
    lang = lang if lang in T else "en"
    try:
        return llm_ask(pid, question, lang)
    except Exception as e:  # any LLM failure is a fallback, never a failed request
        note = {"tool": "gemini", "args": {"model": _model()},
                "returned": f"unavailable, answered with rules instead ({_scrub(e)})"}
        return rules_ask(pid, question, lang, note)


def _scrub(err) -> str:
    """An error message for the trace, with the API key never in it."""
    msg = " ".join(str(err).split())[:300] or err.__class__.__name__
    key = (os.getenv("GEMINI_API_KEY") or "").strip()
    return msg.replace(key, "***") if len(key) > 8 else msg


def _summarize(v):
    if isinstance(v, list):
        return f"{len(v)} item(s)"
    if isinstance(v, dict):
        if v.get("error"):
            return f"error: {v['error']}"
        if v.get("span_id"):
            return f"{v['span_id']}, {len(v.get('text') or '')} chars"
        return ", ".join(v.keys())
    return "none" if v is None else str(v)[:60]
