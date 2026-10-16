"""The profile registry.

Profiles live in one small registry graph; each profile's health records live
in a graph of their own (`db.graph_name`), so one family member's data is
never visible from another's queries.
"""
import re
from datetime import datetime, timezone

from . import db
from . import graph_ops as g

MAX_ID_LEN = 40


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", (name or "").lower()).strip("_")
    return s[:MAX_ID_LEN].strip("_")


def _unique_id(name: str) -> str:
    base = slugify(name) or "person"
    if not base[0].isalnum():
        base = f"p_{base}"
    taken = {r["id"] for r in db.query("MATCH (p:Person) RETURN p.id AS id")}
    if base not in taken:
        return base
    for n in range(2, 1000):
        cand = f"{base}_{n}"
        if cand not in taken:
            return cand
    raise ValueError("Could not allocate a profile id")


def _now():
    return datetime.now(timezone.utc).isoformat()


def create(name: str, relation: str, caregiver: str | None) -> dict:
    pid = _unique_id(name)
    db.query(
        "CREATE (p:Person {id:$id, name:$name, relation:$relation, caregiver:$caregiver, "
        "created_at:$now})",
        {"id": pid, "name": name, "relation": relation, "caregiver": caregiver or "", "now": _now()},
    )
    # Mirror the profile into its own graph so it can anchor that person's records.
    g.ensure_indexes(pid)
    g.ensure_person(pid, name, relation, caregiver or "")
    return get(pid)


def list_all() -> list[dict]:
    rows = db.query(
        "MATCH (p:Person) RETURN p.id AS id, p.name AS name, p.relation AS relation, "
        "p.caregiver AS caregiver, p.created_at AS created_at ORDER BY p.created_at ASC, p.id ASC"
    )
    return [{**r, "records": g.count_records(r["id"])} for r in rows]


def get(person_id: str) -> dict | None:
    rows = db.query(
        "MATCH (p:Person {id:$id}) RETURN p.id AS id, p.name AS name, p.relation AS relation, "
        "p.caregiver AS caregiver, p.created_at AS created_at",
        {"id": person_id},
    )
    if not rows:
        return None
    return {**rows[0], "records": g.count_records(person_id)}


def delete(person_id: str) -> bool:
    if not get(person_id):
        return False
    db.drop_graph(db.graph_name(person_id))
    db.query("MATCH (p:Person {id:$id}) DETACH DELETE p", {"id": person_id})
    return True
