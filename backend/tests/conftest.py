"""Test rig: a fake graph, so the suite needs no FalkorDB server.

Every Cypher string is classified as a read or a write and the writes are
kept, which is what the confirm tests assert on — a fact that should never
reach the graph must leave no write behind.
"""
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import db, graph_ops as g, main  # noqa: E402

WRITE_WORDS = ("MERGE", "CREATE", "DETACH DELETE", "SET ")

# One profile of my own, unrelated to any seeded demo: a mother with a knee
# physiotherapy referral.
PERSON = {
    "id": "nilofer",
    "name": "Nilofer",
    "relation": "Mother",
    "caregiver": "Zoya",
    "created_at": "2026-10-01T00:00:00+00:00",
}


class FakeGraph:
    def __init__(self):
        self.writes: list[tuple[str, str, dict]] = []
        self.reads: list[tuple[str, str, dict]] = []

    def query(self, cypher, params=None, *, name=db.REGISTRY_GRAPH):
        params = dict(params or {})
        c = " ".join(cypher.split())
        if "RETURN 1 AS ok" in c:
            return [{"ok": 1}]
        if any(w in c for w in WRITE_WORDS):
            self.writes.append((name, c, params))
            return []
        self.reads.append((name, c, params))
        if "count(d) AS n" in c:
            return [{"n": 0}]
        if "MATCH (p:Person {id:$id}) RETURN p.id AS id" in c:
            return [dict(PERSON, id=params.get("id"))] if params.get("id") == PERSON["id"] else []
        return []

    def merged(self, label: str) -> list[dict]:
        """Params of every write that MERGEs the given node label."""
        return [p for _, c, p in self.writes if f"MERGE ({label[0].lower()}" in c or f":{label} " in c]


@pytest.fixture
def graph(monkeypatch):
    fake = FakeGraph()
    monkeypatch.setattr(db, "query", fake.query)
    return fake


@pytest.fixture
def client(graph):
    return TestClient(main.app)


@pytest.fixture
def draft(monkeypatch):
    """An unconfirmed draft with two citable paragraphs of my own text."""
    d = {
        "id": "R07",
        "title": "Physio referral note",
        "date": "2026-10-12",
        "status": "draft",
        "extractor": "rule-based-v1",
        "draft_facts": [],
        "text": "Please bring the knee physio referral to the next appointment.\n\n"
                "Appointment confirmed for 20 October at 10:00 AM.",
        "spans": [
            {"id": "R07-P1", "index": 1,
             "text": "Please bring the knee physio referral to the next appointment."},
            {"id": "R07-P2", "index": 2,
             "text": "Appointment confirmed for 20 October at 10:00 AM."},
        ],
    }
    monkeypatch.setattr(g, "get_document", lambda pid, doc_id: d if doc_id == d["id"] else None)
    return d


def confirm(client, facts, pid=PERSON["id"], doc_id="R07"):
    return client.post(
        f"/records/{doc_id}/confirm", params={"person_id": pid}, json={"facts": facts}
    )
