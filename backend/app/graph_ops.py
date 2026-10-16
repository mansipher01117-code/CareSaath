"""All FalkorDB (Cypher) reads and writes live here.

Graph model
-----------
(:Person)-[:HAS_DOCUMENT]->(:Document {status: draft|confirmed})
(:Document)-[:HAS_SPAN]->(:EvidenceSpan)
(:EvidenceSpan)-[:REQUESTS]->(:FollowUp)<-[:HAS_FOLLOWUP]-(:Person)
(:EvidenceSpan)-[:DOCUMENTS_RECEIPT]->(:Receipt)-[:FULFILLS]->(:FollowUp)
(:EvidenceSpan)-[:CONFIRMS]->(:Appointment)<-[:HAS_APPOINTMENT]-(:Person)
(:Document)-[:CAUSED]->(:Change)

A follow-up's status is *derived* by traversing to receipt evidence from a
confirmed document — never stored as a bare true/false flag.
"""
import hashlib
import json
from datetime import datetime, timezone

from .db import query

PERSON_ID = "arun"


def content_hash(title: str, date: str, text: str) -> str:
    norm = " ".join(text.lower().split())
    return hashlib.sha256(f"{date}|{norm}".encode()).hexdigest()[:16]


# ---------- setup ----------

def ensure_indexes():
    for label in ["Person", "Document", "EvidenceSpan", "FollowUp", "Receipt", "Appointment"]:
        try:
            query(f"CREATE INDEX FOR (n:{label}) ON (n.id)")
        except Exception:
            pass  # already exists


def wipe():
    query("MATCH (n) DETACH DELETE n")


def ensure_person():
    query(
        "MERGE (p:Person {id:$id}) "
        "ON CREATE SET p.name='Arun', p.relation='Parent', p.caregiver='Meera', p.synthetic=true",
        {"id": PERSON_ID},
    )


def next_doc_id() -> str:
    rows = query("MATCH (d:Document) RETURN d.id AS id")
    nums = [int(r["id"][1:]) for r in rows if r["id"] and r["id"][1:].isdigit()]
    return f"D{(max(nums) + 1) if nums else 1:02d}"


# ---------- documents ----------

def find_confirmed_duplicate(h: str):
    rows = query(
        "MATCH (d:Document {hash:$h, status:'confirmed'}) RETURN d.id AS id LIMIT 1", {"h": h}
    )
    return rows[0]["id"] if rows else None


def create_draft(doc_id, title, date, text, h, spans, facts, extractor):
    query(
        """
        MATCH (p:Person {id:$pid})
        CREATE (d:Document {id:$id, title:$title, date:$date, text:$text, hash:$h,
                status:'draft', draft_facts:$facts, extractor:$ex,
                created_at:$now})
        CREATE (p)-[:HAS_DOCUMENT]->(d)
        """,
        {"pid": PERSON_ID, "id": doc_id, "title": title, "date": date, "text": text, "h": h,
         "facts": json.dumps(facts), "ex": extractor, "now": _now()},
    )
    for s in spans:
        query(
            "MATCH (d:Document {id:$doc}) "
            "CREATE (d)-[:HAS_SPAN]->(:EvidenceSpan {id:$id, idx:$idx, text:$text, doc_id:$doc})",
            {"doc": doc_id, "id": s["id"], "idx": s["index"], "text": s["text"]},
        )


def get_document(doc_id):
    rows = query(
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


def list_documents():
    return query(
        """
        MATCH (:Person {id:$pid})-[:HAS_DOCUMENT]->(d:Document {status:'confirmed'})
        OPTIONAL MATCH (d)-[:HAS_SPAN]->(s)-[r]->(x)
        WHERE type(r) IN ['REQUESTS','DOCUMENTS_RECEIPT','CONFIRMS']
        RETURN d.id AS id, d.title AS title, d.date AS date, d.text AS text,
               collect(DISTINCT type(r)) AS kinds
        ORDER BY d.date ASC, d.id ASC
        """,
        {"pid": PERSON_ID},
    )


def discard_draft(doc_id):
    query(
        "MATCH (d:Document {id:$id, status:'draft'}) OPTIONAL MATCH (d)-[:HAS_SPAN]->(s) "
        "DETACH DELETE s, d",
        {"id": doc_id},
    )


# ---------- confirm (the only place facts enter the graph) ----------

def confirm_document(doc_id, facts):
    from .extractor import ITEMS

    before = preparation_snapshot()
    for f in facts:
        t = f.get("type")
        if t == "request":
            fid = f"{PERSON_ID}:{f['item']}"
            label = f.get("label") or ITEMS.get(f["item"], (f["item"],))[0]
            query(
                """
                MATCH (p:Person {id:$pid}), (s:EvidenceSpan {id:$sid})
                MERGE (fu:FollowUp {id:$fid})
                ON CREATE SET fu.item=$item, fu.label=$label
                MERGE (p)-[:HAS_FOLLOWUP]->(fu)
                MERGE (s)-[:REQUESTS]->(fu)
                """,
                {"pid": PERSON_ID, "sid": f["span_id"], "fid": fid, "item": f["item"], "label": label},
            )
        elif t == "receipt":
            fid = f"{PERSON_ID}:{f['item']}"
            label = f.get("label") or ITEMS.get(f["item"], (f["item"],))[0]
            query(
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
                {"pid": PERSON_ID, "sid": f["span_id"], "fid": fid, "item": f["item"],
                 "label": label, "rid": f"{fid}@{f['span_id']}", "date": f.get("date", "")},
            )
        elif t == "appointment":
            aid = f"{PERSON_ID}:{f.get('date')}:{f.get('time')}"
            query(
                """
                MATCH (p:Person {id:$pid}), (s:EvidenceSpan {id:$sid})
                MERGE (a:Appointment {id:$aid})
                ON CREATE SET a.date=$date, a.time=$time
                MERGE (p)-[:HAS_APPOINTMENT]->(a)
                MERGE (s)-[:CONFIRMS]->(a)
                """,
                {"pid": PERSON_ID, "sid": f["span_id"], "aid": aid,
                 "date": f.get("date", ""), "time": f.get("time", "")},
            )
        # absence_note: informational, stays only in the source text

    query(
        "MATCH (d:Document {id:$id}) SET d.status='confirmed', d.confirmed_at=$now, "
        "d.confirmed_facts=$facts",
        {"id": doc_id, "now": _now(), "facts": json.dumps(facts)},
    )

    after = preparation_snapshot()
    change = diff(before, after)
    query(
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


def preparation():
    rows = query(PREP_CYPHER, {"pid": PERSON_ID})
    out = []
    for r in rows:
        receipts = [x for x in r["receipts"] if x.get("span_id")]
        requested = [x for x in r["requested_by"] if x.get("span_id")]
        status = "receipt_documented" if receipts else "receipt_not_documented"
        path = ["Person:Arun"]
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


def preparation_snapshot():
    return {p["id"]: {"label": p["label"], "status": p["status"]} for p in preparation()}


def appointments():
    return query(
        """
        MATCH (p:Person {id:$pid})-[:HAS_APPOINTMENT]->(a:Appointment)
        OPTIONAL MATCH (s:EvidenceSpan)-[:CONFIRMS]->(a)
        OPTIONAL MATCH (d:Document {status:'confirmed'})-[:HAS_SPAN]->(s)
        RETURN a.date AS date, a.time AS time,
               collect(DISTINCT {span_id:s.id, doc_id:d.id, text:s.text}) AS sources
        """,
        {"pid": PERSON_ID},
    )


def latest_change():
    rows = query(
        """
        MATCH (d:Document)-[:CAUSED]->(c:Change)
        RETURN c.doc_id AS doc_id, d.title AS doc_title, d.date AS doc_date, c.at AS at,
               c.changed AS changed, c.unchanged AS unchanged, c.added AS added
        ORDER BY c.at DESC LIMIT 1
        """
    )
    if not rows:
        return None
    r = rows[0]
    for k in ("changed", "unchanged", "added"):
        r[k] = json.loads(r[k] or "[]")
    return r


def person():
    rows = query(
        "MATCH (p:Person {id:$pid}) "
        "OPTIONAL MATCH (p)-[:HAS_DOCUMENT]->(d:Document {status:'confirmed'}) "
        "RETURN p.id AS id, p.name AS name, p.relation AS relation, "
        "p.caregiver AS caregiver, count(d) AS records",
        {"pid": PERSON_ID},
    )
    return rows[0] if rows else None


def subgraph():
    """Nodes/edges around the person, for the graph view."""
    rows = query(
        """
        MATCH (p:Person {id:$pid})-[*1..4]-(n)
        WITH DISTINCT n
        WHERE NOT n:Document OR n.status = 'confirmed'
        RETURN n
        """,
        {"pid": PERSON_ID},
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
    p = person()
    nodes[PERSON_ID] = {"id": PERSON_ID, "type": "Person", "label": p["name"] if p else "Arun"}
    ids = list(nodes)
    edges = query(
        "MATCH (a)-[r]->(b) WHERE a.id IN $ids AND b.id IN $ids "
        "RETURN a.id AS source, b.id AS target, type(r) AS type",
        {"ids": ids},
    )
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
