"""CareSaath agent (v1: deterministic router over graph tools).

The agent picks graph tools based on the question, runs them against the
selected person's graph in FalkorDB, and composes an answer ONLY from what the
tools returned. Every answer carries its sources and a trace of tool calls, so
the path behind the answer is visible.

Nothing here knows the name of any particular follow-up item: a question is
matched against the items that actually exist in that person's graph.

Upgrade path: replace `route()` with an LLM that chooses tools (function
calling / MCP) and replace `compose()` with an LLM that writes the answer
from the returned evidence. Keep `validate_sources()` so the model can never
cite something the graph didn't return.
"""
from . import graph_ops as g
from .extractor import tokens

# ---------------- tools (names match the 03 — Tool Contract doc) ----------------

def tools_for(pid: str) -> dict:
    """Bind the graph tools to one person, so no tool can read another's data."""
    return {
        "retrieve_patient_context": lambda: {
            "person": g.person(pid), "appointments": g.appointments(pid)
        },
        "list_unresolved_followups": lambda: g.preparation(pid),
        "latest_change": lambda: g.latest_change(pid),
    }


# ---------------- routing ----------------

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


# ---------------- answer text ----------------

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


def compose(intent, results, lang, items=None):
    t = T.get(lang, T["en"])
    lines, sources = [], []

    if intent == "changes":
        ch = results["latest_change"]
        if not ch:
            return [t["no_change"]], []
        lines.append(t["changed_hdr"].format(doc=ch["doc_id"], date=ch["doc_date"]))
        for c in ch["changed"]:
            lines.append(t["changed"].format(label=c["label"], frm=t[c["from"]], to=t[c["to"]]))
        for c in ch["added"]:
            lines.append(t["added"].format(label=c["label"], to=t[c["to"]]))
        for c in ch["unchanged"]:
            lines.append(t["unchanged"].format(label=c["label"], st=t[c["status"]]))
        for item in results["list_unresolved_followups"]:
            for r in item["receipts"]:
                if r["doc_id"] == ch["doc_id"]:
                    sources.append(_src(r["span_id"], r["doc_id"]))
        return lines, sources

    if intent == "appointment":
        appts = results["retrieve_patient_context"]["appointments"]
        if not appts:
            return [t["no_appt"]], []
        for a in appts:
            s = next((x for x in a["sources"] if x.get("span_id")), None)
            lines.append(t["appt"].format(date=a["date"], time=a["time"], doc=s["doc_id"] if s else "?"))
            if s:
                sources.append(_src(s["span_id"], s["doc_id"]))
        return lines, sources

    if items is None:
        items = results["list_unresolved_followups"]
    if not items:
        return [t["nothing"] if intent == "item" else t["no_items"]], []

    pending = []
    for i in items:
        for rq in i["requested_by"][:1]:
            lines.append(t["requested"].format(label=i["label"], doc=rq["doc_id"], date=rq["date"]))
            sources.append(_src(rq["span_id"], rq["doc_id"]))
        if i["receipts"]:
            r = i["receipts"][0]
            lines.append(t["documented"].format(label=i["label"], date=r["date"], doc=r["doc_id"]))
            sources.append(_src(r["span_id"], r["doc_id"]))
        else:
            lines.append(t["not_documented"].format(label=i["label"]))
            pending.append(i["label"])

    if intent == "preparation":
        ctx = results["retrieve_patient_context"]
        for a in ctx["appointments"][:1]:
            s = next((x for x in a["sources"] if x.get("span_id")), None)
            lines.insert(0, t["appt"].format(date=a["date"], time=a["time"], doc=s["doc_id"] if s else "?"))
            if s:
                sources.append(_src(s["span_id"], s["doc_id"]))
        lines.append(t["clarify"].format(items=", ".join(pending)) if pending else t["all_done"])
    if any(i["receipts"] for i in items):
        lines.append(t["note"])
    return lines, sources


def validate_sources(sources, results):
    """Keep only sources that came out of tool results (guards future LLM output)."""
    blob = str(results)
    seen, out = set(), []
    for s in sources:
        key = (s["span_id"], s["doc_id"])
        if s["span_id"] in blob and key not in seen:
            seen.add(key)
            out.append(s)
    return out


def ask(pid: str, question: str, lang: str = "en"):
    tools = tools_for(pid)
    intent, tool_names = route(question)
    results, trace = {}, []
    for name in tool_names:
        results[name] = tools[name]()
        trace.append({"tool": name, "returned": _summarize(results[name])})

    items = None
    if intent == "preparation":
        matched = match_items(question, results["list_unresolved_followups"])
        if matched:
            intent, items = "item", matched

    lines, sources = compose(intent, results, lang, items)
    sources = validate_sources(sources, results)
    # attach source text for the UI
    for s in sources:
        doc = g.get_document(pid, s["doc_id"])
        span = next((x for x in (doc or {}).get("spans", []) if x["id"] == s["span_id"]), None)
        s["text"] = span["text"] if span else ""
        s["doc_title"] = doc["title"] if doc else ""
        s["date"] = doc["date"] if doc else ""
    return {"question": question, "lang": lang, "intent": intent, "answer": lines,
            "sources": sources, "trace": trace,
            "matched_items": [i["id"] for i in items] if items else []}


def _summarize(v):
    if isinstance(v, list):
        return f"{len(v)} item(s)"
    if isinstance(v, dict):
        return ", ".join(v.keys())
    return "none" if v is None else str(v)[:60]
