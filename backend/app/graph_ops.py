"""All FalkorDB (Cypher) reads and writes live here.

Every person has their own graph (``person_<id>``), so a query written for one
family member can never reach another profile's records. Each function
therefore takes the person id it operates on.

Graph model (inside one person's graph)
---------------------------------------
(:Person)-[:HAS_DOCUMENT]->(:Document {status: draft|confirmed})
(:Document)-[:HAS_SPAN]->(:EvidenceSpan)
(:EvidenceSpan)-[:REQUESTS]->(:FollowUp)<-[:HAS_FOLLOWUP]-(:Person)
(:EvidenceSpan)-[:DOCUMENTS_RECEIPT]->(:Receipt)-[:FULFILLS]->(:FollowUp)
(:EvidenceSpan)-[:CONFIRMS]->(:Appointment)<-[:HAS_APPOINTMENT]-(:Person)
(:Document)-[:CAUSED]->(:Change)

A follow-up status is *derived* by traversing to receipt evidence from a
confirmed document — never stored as a bare true/false flag.
"""
import hashlib
import json
from datetime import datetime, timezone

from . import db
from .extractor import normalize_key


def q(pid: str, cypher: str, params: dict | None = None):
    """Run Cypher inside one person's graph."""
    return db.query(cypher, params, name=db.graph_name(pid))


def content_hash(title: str, date: str, text: str) -> str:
    norm = " ".join(text.lower().split())
    return hashlib.sha256(f"{date}|{norm}".encode()).hexdigest()[:16]


# ---------- setup ----------

def ensure_indexes(pid: str):
    for label in ["Person", "Document", "EvidenceSpan", "FollowUp", "Receipt", "Appointment"]:
        try:
            q(pid, f"CREATE INDEX FOR (n:{label}) ON (n.id)")
        except Exception:
            pass  # already exists


def ensure_person(pid: str, name: str, relation: str, caregiver: str):
    q(
        pid,
        "MERGE (p:Person {id:$id}) SET p.name=$name, p.relation=$relation, p.caregiver=$caregiver",
        {"id": pid, "name": name, "relation": relation, "caregiver": caregiver},
    )


def count_records(pid: str) -> int:
    try:
        rows = q(pid, "MATCH (d:Document {status:'confirmed'}) RETURN count(d) AS n")
    except Exception:
        return 0
    return rows[0]["n"] if rows else 0


def next_doc_id(pid: str) -> str:
    rows = q(pid, "MATCH (d:Document) RETURN d.id AS id")
    nums = [int(r["id"][1:]) for r in rows if r["id"] and r["id"][1:].isdigit()]
    return f"D{(max(nums) + 1) if nums else 1:02d}"


# ---------- documents ----------

def find_confirmed_duplicate(pid: str, h: str):
    rows = q(
        pid,
        "MATCH (d:Document {hash:$h, status:'confirmed'}) RETURN d.id AS id LIMIT 1",
        {"h": h},
    )
    return rows[0]["id"] if rows else None


def create_draft(pid, doc_id, title, date, text, h, spans, facts, extractor):
    q(
        pid,
        """
        MATCH (p:Person {id:$pid})
        CREATE (d:Document {id:$id, title:$title, date:$date, text:$text, hash:$h,
                status:'draft', draft_facts:$facts, extractor:$ex,
                created_at:$now})
        CREATE (p)-[:HAS_DOCUMENT]->(d)
        """,
        {"pid": pid, "id": doc_id, "title": title, "date": date, "text": text, "h": h,
         "facts": json.dumps(facts), "ex": extractor, "now": _now()},
    )
    for s in spans:
        q(
            pid,
            "MATCH (d:Document {id:$doc}) "
            "CREATE (d)-[:HAS_SPAN]->(:EvidenceSpan {id:$id, idx:$idx, text:$text, doc_id:$doc})",
            {"doc": doc_id, "id": s["id"], "idx": s["index"], "text": s["text"]},
        )


def get_document(pid, doc_id):
    rows = q(
        pid,
        """
        MATCH (d:Document {id:$id})
        OPTIONAL MATCH (d)-[:HAS_SPAN]->(s:EvidenceSpan)
        WITH d, s ORDER BY s.idx
        RETURN d.id AS id, d.title AS title, d.date AS date, d.text AS text,
               d.status AS status, d.draft_facts AS draft_facts, d.extractor AS extractor,
               collect({id:s.id, index:s.idx, text:s.text}) AS spans
        """,
        {"id": doc_id},
    )
    if not rows:
        return None
    r = rows[0]
    r["draft_facts"] = json.loads(r["draft_facts"] or "[]")
    r["spans"] = [s for s in r["spans"] if s.get("id")]
    return r


def list_documents(pid):
    return q(
        pid,
        """
        MATCH (:Person {id:$pid})-[:HAS_DOCUMENT]->(d:Document {status:'confirmed'})
        OPTIONAL MATCH (d)-[:HAS_SPAN]->(s)-[r]->(x)
        WHERE type(r) IN ['REQUESTS','DOCUMENTS_RECEIPT','CONFIRMS']
        RETURN d.id AS id, d.title AS title, d.date AS date, d.text AS text,
               collect(DISTINCT type(r)) AS kinds
        ORDER BY d.date ASC, d.id ASC
        """,
        {"pid": pid},
    )


def discard_draft(pid, doc_id):
    q(
        pid,
        "MATCH (d:Document {id:$id, status:'draft'}) OPTIONAL MATCH (d)-[:HAS_SPAN]->(s) "
        "DETACH DELETE s, d",
        {"id": doc_id},
    )


# ---------- confirm (the only place facts enter the graph) ----------

def item_of(fact: dict) -> tuple[str, str]:
    """(key, label) for a reviewed fact.

    The key is always derived from the label the reviewer confirmed, so editing
    an item name on the Review screen renames the follow-up — and two names that
    normalize to the same key are the same follow-up.
    """
    label = (fact.get("label") or "").strip()
    key = normalize_key(label) or (fact.get("item") or "").strip()
    return key, (label or key)


def appointment_of(fact: dict) -> tuple[str, str]:
    """(date, time) for a reviewed appointment fact.

    Both are required: the extractor only ever reads them together, so a fact
    carrying one of them arrived by some other route (an older client, or a
    fact whose type was changed on the Review screen) and is not an
    appointment.
    """
    return (fact.get("date") or "").strip(), (fact.get("time") or "").strip()


def confirm_document(pid, doc_id, facts):
    before = preparation_snapshot(pid)
    for f in facts:
        t = f.get("type")
        if t in ("request", "receipt"):
            key, label = item_of(f)
            if not key:
                continue
            fid = f"fu:{key}"
        if t == "request":
            q(
                pid,
                """
                MATCH (p:Person {id:$pid}), (s:EvidenceSpan {id:$sid})
                MERGE (fu:FollowUp {id:$fid})
                ON CREATE SET fu.item=$item, fu.label=$label
                MERGE (p)-[:HAS_FOLLOWUP]->(fu)
                MERGE (s)-[:REQUESTS]->(fu)
                """,
                {"pid": pid, "sid": f["span_id"], "fid": fid, "item": key, "label": label},
            )
        elif t == "receipt":
            q(
                pid,
                """
                MATCH (p:Person {id:$pid}), (s:EvidenceSpan {id:$sid})
                MERGE (fu:FollowUp {id:$fid})
                ON CREATE SET fu.item=$item, fu.label=$label
                MERGE (p)-[:HAS_FOLLOWUP]->(fu)
                MERGE (r:Receipt {id:$rid})
                ON CREATE SET r.date=$date
                MERGE (s)-[:DOCUMENTS_RECEIPT]->(r)
                MERGE (r)-[:FULFILLS]->(fu)
                """,
                {"pid": pid, "sid": f["span_id"], "fid": fid, "item": key, "label": label,
                 "rid": f"{fid}@{f['span_id']}", "date": f.get("date", "")},
            )
        elif t == "appointment":
            date, time = appointment_of(f)
            if not (date and time):
                continue  # half an appointment is not an appointment
            # The year is part of the identity: "20 October" in two different
            # years is two appointments, and merging them would silently move
            # one of them.
            year = (f.get("year") or "").strip()
            aid = f"appt:{year or 'year_unknown'}:{date}:{time}"
            q(
                pid,
                """
                MATCH (p:Person {id:$pid}), (s:EvidenceSpan {id:$sid})
                MERGE (a:Appointment {id:$aid})
                ON CREATE SET a.date=$date, a.time=$time, a.year=$year
                MERGE (p)-[:HAS_APPOINTMENT]->(a)
                MERGE (s)-[:CONFIRMS]->(a)
                """,
                {"pid": pid, "sid": f["span_id"], "aid": aid, "date": date, "time": time,
                 "year": year},
            )
        # absence_note: informational, stays only in the source text

    q(
        pid,
        "MATCH (d:Document {id:$id}) SET d.status='confirmed', d.confirmed_at=$now, "
        "d.confirmed_facts=$facts",
        {"id": doc_id, "now": _now(), "facts": json.dumps(facts)},
    )

    after = preparation_snapshot(pid)
    change = diff(before, after)
    q(
        pid,
        "MATCH (d:Document {id:$id}) CREATE (d)-[:CAUSED]->(:Change {doc_id:$id, at:$now, "
        "changed:$c, unchanged:$u, added:$a})",
        {"id": doc_id, "now": _now(), "c": json.dumps(change["changed"]),
         "u": json.dumps(change["unchanged"]), "a": json.dumps(change["added"])},
    )
    return change


def diff(before, after):
    changed, unchanged, added = [], [], []
    for fid, a in after.items():
        b = before.get(fid)
        if b is None:
            added.append({"id": fid, "label": a["label"], "to": a["status"]})
        elif b["status"] != a["status"]:
            changed.append({"id": fid, "label": a["label"], "from": b["status"], "to": a["status"]})
        else:
            unchanged.append({"id": fid, "label": a["label"], "status": a["status"]})
    return {"changed": changed, "unchanged": unchanged, "added": added}


# ---------- preparation (multi-hop read) ----------

PREP_CYPHER = """
MATCH (p:Person {id:$pid})-[:HAS_FOLLOWUP]->(f:FollowUp)
OPTIONAL MATCH (rs:EvidenceSpan)-[:REQUESTS]->(f)
OPTIONAL MATCH (rd:Document {status:'confirmed'})-[:HAS_SPAN]->(rs)
WITH p, f, collect(DISTINCT {span_id:rs.id, doc_id:rd.id, doc_title:rd.title,
                             date:rd.date, text:rs.text}) AS requested_by
OPTIONAL MATCH (f)<-[:FULFILLS]-(r:Receipt)<-[:DOCUMENTS_RECEIPT]-(es:EvidenceSpan)
               <-[:HAS_SPAN]-(ed:Document {status:'confirmed'})
RETURN f.id AS id, f.item AS item, f.label AS label, requested_by,
       collect(DISTINCT {span_id:es.id, doc_id:ed.id, doc_title:ed.title,
                         date:r.date, text:es.text}) AS receipts
ORDER BY f.label
"""


def _evidenced(rows: list[dict]) -> list[dict]:
    """Evidence rows that name both a span and a *confirmed* document.

    The query leaves doc_id null when the span belongs to a draft, so a row
    with a span but no document is evidence nobody has confirmed yet. Newest
    first, so the first row of each list is the one worth citing.
    """
    kept = [x for x in rows if x.get("span_id") and x.get("doc_id")]
    return sorted(kept, key=lambda x: x.get("date") or "", reverse=True)


def preparation(pid):
    rows = q(pid, PREP_CYPHER, {"pid": pid})
    name = (person(pid) or {}).get("name") or pid
    out = []
    for r in rows:
        receipts = _evidenced(r["receipts"])
        requested = _evidenced(r["requested_by"])
        # An item nothing confirmed asks for or records is not being tracked.
        # It is also what a confirm that failed half-way leaves behind, so
        # skipping it keeps a partial write out of every reader's view.
        if not (requested or receipts):
            continue
        # A receipt settles the request episode it follows, not every future
        # one: when the newest request is more recent than the newest receipt,
        # the item is being asked for again and an older receipt does not
        # close it.
        status = ("receipt_documented"
                  if receipts and (receipts[0].get("date") or "")
                  >= (requested[0].get("date") or "" if requested else "")
                  else "receipt_not_documented")
        path = [f"Person:{name}"]
        if requested:
            path += [f"Document:{requested[0]['doc_id']}", f"Span:{requested[0]['span_id']}"]
        path.append(f"FollowUp:{r['label']}")
        if receipts:
            path += [f"Receipt:{receipts[0]['date']}", f"Span:{receipts[0]['span_id']}",
                     f"Document:{receipts[0]['doc_id']}"]
        out.append({
            "id": r["id"], "item": r["item"], "label": r["label"], "status": status,
            "requested_by": requested, "receipts": receipts, "path": path,
        })
    return out


def preparation_snapshot(pid):
    return {p["id"]: {"label": p["label"], "status": p["status"]} for p in preparation(pid)}


MONTH_NUMBERS = {m: i for i, m in enumerate(
    ["january", "february", "march", "april", "may", "june", "july", "august",
     "september", "october", "november", "december"], start=1)}


def iso_date(day_month: str, year: str) -> str:
    """'20 October' + '2026' -> '2026-10-20'. Empty when the year is unknown,
    because a date without a year cannot be placed on a calendar."""
    parts = (day_month or "").replace(",", " ").split()
    if len(parts) < 2 or not (year or "").strip().isdigit():
        return ""
    day, month = parts[0], MONTH_NUMBERS.get(parts[1].lower())
    if not (day.isdigit() and month):
        return ""
    return f"{int(year):04d}-{month:02d}-{int(day):02d}"


def appointments(pid, today: str | None = None):
    """Confirmed appointments, soonest first.

    `on` is the resolvable calendar date and `upcoming` says whether it is
    still ahead; both are empty/False when the record never gave a year, so a
    caller can say "year unknown" instead of inventing one.
    """
    rows = q(
        pid,
        """
        MATCH (p:Person {id:$pid})-[:HAS_APPOINTMENT]->(a:Appointment)
        OPTIONAL MATCH (s:EvidenceSpan)-[:CONFIRMS]->(a)
        OPTIONAL MATCH (d:Document {status:'confirmed'})-[:HAS_SPAN]->(s)
        RETURN a.date AS date, a.time AS time, a.year AS year,
               collect(DISTINCT {span_id:s.id, doc_id:d.id, text:s.text}) AS sources
        """,
        {"pid": pid},
    )
    today = today or datetime.now(timezone.utc).date().isoformat()
    out = []
    for r in rows:
        sources = [x for x in r["sources"] if x.get("span_id") and x.get("doc_id")]
        if not sources:
            continue  # nothing confirmed confirms it (or a confirm failed part-way)
        r["year"] = (r.get("year") or "").strip()
        r["sources"] = sources
        r["on"] = iso_date(r["date"], r["year"])
        r["upcoming"] = bool(r["on"]) and r["on"] >= today
        out.append(r)
    # Undated appointments sort last: they cannot be placed against today.
    out.sort(key=lambda a: (a["on"] or "9999-12-31", a["time"] or ""))
    return out


CHANGE_RETURN = """
RETURN c.doc_id AS doc_id, d.title AS doc_title, d.date AS doc_date, c.at AS at,
       c.changed AS changed, c.unchanged AS unchanged, c.added AS added
ORDER BY c.at DESC LIMIT 1
"""


def latest_change(pid):
    return _change_row(pid, q(pid, f"MATCH (d:Document)-[:CAUSED]->(c:Change) {CHANGE_RETURN}"))


def change_for(pid, doc_id):
    """The change *this* document caused.

    A retried confirm has to answer for the document it was given, not for
    whichever document happened to be confirmed most recently — otherwise a
    retry reports somebody else's diff as its own result.
    """
    return _change_row(pid, q(
        pid, f"MATCH (d:Document {{id:$id}})-[:CAUSED]->(c:Change) {CHANGE_RETURN}",
        {"id": doc_id}))


def _change_row(pid, rows):
    if not rows:
        return None
    r = rows[0]
    for k in ("changed", "unchanged", "added"):
        r[k] = json.loads(r[k] or "[]")
    # Give every entry the real span that evidences it, so a reader cites
    # actual evidence instead of guessing at a span id.
    evidence = {}
    for item in preparation(pid):
        for x in item["receipts"] + item["requested_by"]:
            evidence.setdefault((item["id"], x["doc_id"]), x)
            evidence.setdefault((item["id"], None), x)
    for key in ("changed", "unchanged", "added"):
        for entry in r[key]:
            hit = (evidence.get((entry.get("id"), r["doc_id"]))
                   or evidence.get((entry.get("id"), None)))
            if hit:
                entry["doc_id"] = hit["doc_id"]
                entry["span_id"] = hit["span_id"]
    return r


def person(pid):
    rows = q(
        pid,
        "MATCH (p:Person {id:$pid}) "
        "OPTIONAL MATCH (p)-[:HAS_DOCUMENT]->(d:Document {status:'confirmed'}) "
        "RETURN p.id AS id, p.name AS name, p.relation AS relation, "
        "p.caregiver AS caregiver, count(d) AS records",
        {"pid": pid},
    )
    return rows[0] if rows else None


def subgraph(pid):
    """Nodes/edges around the person, for the graph view."""
    rows = q(
        pid,
        """
        MATCH (p:Person {id:$pid})-[*1..4]-(n)
        WITH DISTINCT n
        WHERE NOT n:Document OR n.status = 'confirmed'
        RETURN n
        """,
        {"pid": pid},
    )
    nodes = {}
    for r in rows:
        n = r["n"]
        if "Change" in n["labels"]:
            continue
        nodes[n["id"]] = {"id": n["id"], "type": n["labels"][0], "label": _node_label(n),
                          "doc_id": n.get("doc_id")}
    # drop spans belonging to unconfirmed drafts
    nodes = {k: v for k, v in nodes.items()
             if v["type"] != "EvidenceSpan" or v["doc_id"] in nodes}
    p = person(pid)
    nodes[pid] = {"id": pid, "type": "Person", "label": (p or {}).get("name") or pid}
    ids = list(nodes)
    edges = q(
        pid,
        "MATCH (a)-[r]->(b) WHERE a.id IN $ids AND b.id IN $ids "
        "RETURN a.id AS source, b.id AS target, type(r) AS type",
        {"ids": ids},
    )
    # A fact with no surviving evidence span is one a confirm wrote before
    # failing part-way: it is not in the records, so it is not in the picture.
    # Reachable from a surviving span: span -> Receipt -> FollowUp is the
    # longest chain, so three passes close it.
    evidenced = {k for k, v in nodes.items() if v["type"] == "EvidenceSpan"}
    for _ in range(3):
        evidenced |= {e["target"] for e in edges if e["source"] in evidenced}
    nodes = {k: v for k, v in nodes.items()
             if v["type"] not in ("FollowUp", "Receipt", "Appointment") or k in evidenced}
    edges = [e for e in edges if e["source"] in nodes and e["target"] in nodes]
    return {"nodes": list(nodes.values()), "edges": edges}


def _node_label(n):
    t = n["labels"][0]
    if t == "Document":
        return f"{n['id']} · {n.get('title', '')}"
    if t == "FollowUp":
        return n.get("label", n["id"])
    if t == "Receipt":
        return f"Receipt {n.get('date', '')}"
    if t == "Appointment":
        return f"{n.get('date', '')} {n.get('time', '')}"
    if t == "EvidenceSpan":
        return n["id"]
    return n.get("name", n["id"])


def _now():
    return datetime.now(timezone.utc).isoformat()
