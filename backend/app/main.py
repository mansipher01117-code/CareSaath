"""CareSaath API — FastAPI + FalkorDB.

Run:  uvicorn app.main:app --reload --port 8000
"""
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import agent, db, graph_ops as g
from .extractor import extract
from .sample_data import LIVE_D04, SEED

app = FastAPI(title="CareSaath API", version="0.1.0")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)


class RecordIn(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    text: str = Field(min_length=3, max_length=20000)


class ConfirmIn(BaseModel):
    facts: list[dict]


class AskIn(BaseModel):
    question: str = Field(min_length=1, max_length=500)
    lang: str = "en"


def _require_db():
    if not db.ping():
        raise HTTPException(503, detail="Graph database unavailable. No answer was generated.")


@app.on_event("startup")
def startup():
    if db.ping():
        g.ensure_indexes()
        g.ensure_person()
        if not g.list_documents():
            _seed()


def _seed():
    for rec in SEED:
        draft = _preview(RecordIn(**rec))
        g.confirm_document(draft["id"], draft["facts"])


# ---------------- health / demo ----------------

@app.get("/health")
def health():
    ok = db.ping()
    return {"api": "ok", "graph": "ok" if ok else "unavailable", "graph_name": db.GRAPH_NAME}


@app.post("/demo/reset")
def demo_reset():
    _require_db()
    g.wipe()
    g.ensure_indexes()
    g.ensure_person()
    _seed()
    return {"ok": True, "records": len(g.list_documents())}


@app.get("/demo/next-record")
def demo_next_record():
    """Returns the fictional D04 text so the demo can prefill the Add form."""
    return LIVE_D04


# ---------------- person / records ----------------

@app.get("/person")
def get_person():
    _require_db()
    return {**(g.person() or {}), "appointments": g.appointments(), "synthetic": True}


@app.get("/records")
def list_records():
    _require_db()
    return g.list_documents()


@app.get("/records/{doc_id}")
def get_record(doc_id: str):
    _require_db()
    d = g.get_document(doc_id)
    if not d:
        raise HTTPException(404, "Record not found")
    return d


def _preview(rec: RecordIn):
    h = g.content_hash(rec.title, rec.date, rec.text)
    dup = g.find_confirmed_duplicate(h)
    if dup:
        return {"duplicate_of": dup, "id": None, "facts": [], "spans": []}
    doc_id = g.next_doc_id()
    ex = extract(doc_id, rec.text, rec.date)
    g.create_draft(doc_id, rec.title, rec.date, rec.text, h, ex["spans"], ex["facts"], ex["extractor"])
    return {"id": doc_id, "duplicate_of": None, "title": rec.title, "date": rec.date, **ex}


@app.post("/records/preview")
def preview(rec: RecordIn):
    """Create an UNCONFIRMED draft + suggested facts. Nothing is used in answers yet."""
    _require_db()
    return _preview(rec)


@app.post("/records/{doc_id}/confirm")
def confirm(doc_id: str, body: ConfirmIn):
    _require_db()
    d = g.get_document(doc_id)
    if not d:
        raise HTTPException(404, "Record not found")
    if d["status"] == "confirmed":
        return {"already_confirmed": True, "change": g.latest_change()}
    span_ids = {s["id"] for s in d["spans"]}
    for f in body.facts:
        if f.get("span_id") not in span_ids:
            raise HTTPException(400, f"Fact cites unknown span {f.get('span_id')}")
    change = g.confirm_document(doc_id, body.facts)
    return {"confirmed": doc_id, "change": change}


@app.delete("/records/{doc_id}")
def discard(doc_id: str):
    _require_db()
    g.discard_draft(doc_id)
    return {"discarded": doc_id}


# ---------------- preparation / changes / graph ----------------

@app.get("/preparation")
def preparation():
    _require_db()
    return {"items": g.preparation(), "appointments": g.appointments(), "cypher": g.PREP_CYPHER.strip()}


@app.get("/changes/latest")
def changes_latest():
    _require_db()
    return g.latest_change() or {}


@app.get("/graph")
def graph_view():
    _require_db()
    return g.subgraph()


# ---------------- agent ----------------

@app.post("/ask")
def ask(body: AskIn):
    _require_db()
    return agent.ask(body.question, body.lang)
