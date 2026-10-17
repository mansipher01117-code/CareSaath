"""CareSaath API — FastAPI + FalkorDB.

Every record endpoint takes a `person_id` and only ever touches that person's
graph (`person_<id>`), so one family member's records are invisible to another.

Run:  uvicorn app.main:app --reload --port 8000
"""
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, TypeAdapter, ValidationError

from . import agent, db, graph_ops as g, people
from .extractor import extract

app = FastAPI(title="CareSaath API", version="0.2.0")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)


class PersonIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    relation: str = Field(min_length=1, max_length=40)
    caregiver: str | None = Field(default=None, max_length=80)


class RecordIn(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    text: str = Field(min_length=3, max_length=20000)


# ---------------- reviewed facts ----------------
# Each fact type carries its own required fields, so a fact that arrived with
# the wrong shape — an appointment relabelled as a receipt, a request with a
# time but no item — is rejected by name before anything is written.

class FactIn(BaseModel):
    model_config = {"extra": "forbid"}
    span_id: str = Field(min_length=1, max_length=64)


class RequestFact(FactIn):
    type: Literal["request"]
    label: str = Field(min_length=1, max_length=120)
    item: str = ""


class ReceiptFact(FactIn):
    type: Literal["receipt"]
    label: str = Field(min_length=1, max_length=120)
    item: str = ""
    date: str = Field(default="", pattern=r"^(\d{4}-\d{2}-\d{2})?$")


class AppointmentFact(FactIn):
    type: Literal["appointment"]
    date: str = Field(min_length=1, max_length=40)
    time: str = Field(min_length=1, max_length=20)
    # A record that never gave a year leaves this empty rather than guessing.
    year: str = Field(default="", pattern=r"^(\d{4})?$")
    label: str = Field(default="Appointment", max_length=120)


class AbsenceFact(FactIn):
    type: Literal["absence_note"]
    label: str = Field(default="", max_length=240)
    items: list[str] = []


Fact = Annotated[
    RequestFact | ReceiptFact | AppointmentFact | AbsenceFact,
    Field(discriminator="type"),
]
FACT_ADAPTER = TypeAdapter(list[Fact])


class ConfirmIn(BaseModel):
    # Parsed into the typed union by `_typed_facts`, which reports a 400
    # naming the offending field instead of FastAPI's 422 body dump.
    facts: list[dict]


class AskIn(BaseModel):
    question: str = Field(min_length=1, max_length=500)
    lang: str = "en"


def _require_db():
    if not db.ping():
        raise HTTPException(503, detail="Graph database unavailable. No answer was generated.")


def person_id(person_id: str = Query(min_length=1, max_length=64)) -> str:
    """Resolve + authorize the profile every request works on."""
    _require_db()
    if not people.get(person_id):
        raise HTTPException(404, f"No profile {person_id!r}. Create one with POST /people.")
    return person_id


Pid = Depends(person_id)


@app.on_event("startup")
def startup():
    """Prepare the registry graph only. No data is ever seeded."""
    if db.ping():
        try:
            db.query("CREATE INDEX FOR (n:Person) ON (n.id)")
        except Exception:
            pass  # already exists


# ---------------- health ----------------

@app.get("/health")
def health():
    ok = db.ping()
    return {"api": "ok", "graph": "ok" if ok else "unavailable", "registry": db.REGISTRY_GRAPH}


# ---------------- people ----------------

@app.post("/people", status_code=201)
def create_person(body: PersonIn):
    _require_db()
    return people.create(body.name.strip(), body.relation.strip(),
                         (body.caregiver or "").strip() or None)


@app.get("/people")
def list_people():
    _require_db()
    return people.list_all()


@app.get("/people/{pid}")
def get_person(pid: str):
    _require_db()
    p = people.get(pid)
    if not p:
        raise HTTPException(404, "Profile not found")
    return {**p, "appointments": g.appointments(pid)}


@app.delete("/people/{pid}")
def delete_person(pid: str):
    _require_db()
    if not people.delete(pid):
        raise HTTPException(404, "Profile not found")
    return {"deleted": pid}


# ---------------- records ----------------

@app.get("/records")
def list_records(pid: str = Pid):
    return g.list_documents(pid)


@app.get("/records/{doc_id}")
def get_record(doc_id: str, pid: str = Pid):
    d = g.get_document(pid, doc_id)
    if not d:
        raise HTTPException(404, "Record not found")
    return d


def _preview(pid: str, rec: RecordIn):
    h = g.content_hash(rec.title, rec.date, rec.text)
    dup = g.find_confirmed_duplicate(pid, h)
    if dup:
        return {"duplicate_of": dup, "id": None, "facts": [], "spans": []}
    doc_id = g.next_doc_id(pid)
    ex = extract(doc_id, rec.text, rec.date)
    g.create_draft(pid, doc_id, rec.title, rec.date, rec.text, h,
                   ex["spans"], ex["facts"], ex["extractor"])
    return {"id": doc_id, "duplicate_of": None, "title": rec.title, "date": rec.date, **ex}


@app.post("/records/preview")
def preview(rec: RecordIn, pid: str = Pid):
    """Create an UNCONFIRMED draft + suggested facts. Nothing is used in answers yet."""
    return _preview(pid, rec)


FACT_TYPES = ("request", "receipt", "appointment", "absence_note")


def _fact_error(e: ValidationError) -> str:
    """A schema error, phrased as the reviewer's problem rather than pydantic's."""
    first = e.errors()[0]
    loc = [str(p) for p in first["loc"]]
    if first["type"] in ("union_tag_invalid", "union_tag_not_found"):
        given = first.get("input")
        return f"Unknown fact type {(given.get('type') if isinstance(given, dict) else None)!r}"
    fact_type, field = (loc[1] if len(loc) > 2 else ""), loc[-1]
    if field == "label" and fact_type in ("request", "receipt"):
        return f"A {fact_type} fact needs an item name"
    if field in ("date", "time") and fact_type == "appointment":
        return "An appointment fact needs both a date and a time"
    return f"Invalid fact at {'.'.join(loc) or '?'}: {first['msg']}"


def _typed_facts(raw: list[dict], span_ids: set[str]) -> list[dict]:
    """Validate reviewed facts against their own schema, before any write.

    Changing a fact's type on the Review screen used to leave the previous
    type's fields behind — an appointment relabelled as a receipt arrived with
    no item name, a request relabelled as an appointment with no time — and
    each of those wrote a nameless follow-up or an empty appointment into the
    graph. The client rebuilds the fact on every type change; this is the
    guarantee that nothing else can.
    """
    try:
        facts = FACT_ADAPTER.validate_python(raw)
    except ValidationError as e:
        raise HTTPException(400, _fact_error(e)) from e

    out = []
    for f in facts:
        d = f.model_dump()
        if d["span_id"] not in span_ids:
            raise HTTPException(400, f"Fact cites unknown span {d['span_id']}")
        # A label of only spaces passes a length check but names nothing.
        if d["type"] in ("request", "receipt") and not g.item_of(d)[0]:
            raise HTTPException(400, f"A {d['type']} fact needs an item name")
        if d["type"] == "appointment" and not all(g.appointment_of(d)):
            raise HTTPException(400, "An appointment fact needs both a date and a time")
        out.append(d)
    return out


@app.post("/records/{doc_id}/confirm")
def confirm(doc_id: str, body: ConfirmIn, pid: str = Pid):
    d = g.get_document(pid, doc_id)
    if not d:
        raise HTTPException(404, "Record not found")
    if d["status"] == "confirmed":
        # Answer for this document, not for whatever was confirmed last.
        return {"already_confirmed": True, "change": g.change_for(pid, doc_id) or {}}
    facts = _typed_facts(body.facts, {s["id"] for s in d["spans"]})
    # Re-check for a duplicate here too: the same record can have been
    # confirmed from another tab between this draft's preview and its confirm.
    dup = g.find_confirmed_duplicate(pid, g.content_hash(d["title"], d["date"], d.get("text") or ""))
    if dup:
        g.discard_draft(pid, doc_id)
        return {"duplicate_of": dup, "change": g.change_for(pid, dup) or {}}
    change = g.confirm_document(pid, doc_id, facts)
    return {"confirmed": doc_id, "change": change}


@app.delete("/records/{doc_id}")
def discard(doc_id: str, pid: str = Pid):
    g.discard_draft(pid, doc_id)
    return {"discarded": doc_id}


# ---------------- preparation / changes / graph ----------------

@app.get("/preparation")
def preparation(pid: str = Pid):
    return {"items": g.preparation(pid), "appointments": g.appointments(pid),
            "cypher": g.PREP_CYPHER.strip()}


@app.get("/changes/latest")
def changes_latest(pid: str = Pid):
    return g.latest_change(pid) or {}


@app.get("/graph")
def graph_view(pid: str = Pid):
    return g.subgraph(pid)


# ---------------- agent ----------------

@app.post("/ask")
def ask(body: AskIn, pid: str = Pid):
    return agent.ask(pid, body.question, body.lang)
