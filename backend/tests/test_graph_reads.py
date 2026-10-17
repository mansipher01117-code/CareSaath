"""What the read side is allowed to show.

Three separate guarantees live here, and each one was a real hole:

* A fact with no confirmed evidence behind it is invisible. That is what a
  confirm which failed half-way leaves in the graph — the follow-up node is
  written before the document is marked confirmed — and it used to surface as
  a tracked item with no sources.
* A receipt closes the request episode it follows, not every later one. One
  receipt used to mark an item documented forever, so a fresh request for the
  same thing was born already satisfied.
* An appointment keeps the year the record gave it, or says it has none.
  "20 October" was stored bare, which made it unsortable and let a card call
  last year's visit the next one.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import db, graph_ops as g  # noqa: E402

PID = "nilofer"


def span(doc, span_id, date, text="..."):
    """One row of evidence as PREP_CYPHER returns it."""
    return {"span_id": span_id, "doc_id": doc, "doc_title": f"{doc} note",
            "date": date, "text": text}


class Reads:
    """A fake graph that answers reads from canned rows, keyed on the query."""

    def __init__(self, followups=(), appointments=(), change=None, nodes=(), edges=()):
        self.followups, self.appointments = list(followups), list(appointments)
        self.change, self.nodes, self.edges = change, list(nodes), list(edges)
        self.asked: list[tuple[str, dict]] = []

    def query(self, cypher, params=None, *, name=db.REGISTRY_GRAPH):
        c = " ".join(cypher.split())
        self.asked.append((c, dict(params or {})))
        if "RETURN 1 AS ok" in c:
            return [{"ok": 1}]
        if "p.caregiver AS caregiver, count(d) AS records" in c:
            return [{"id": PID, "name": "Nilofer", "relation": "Mother",
                     "caregiver": "Zoya", "records": 2}]
        if "f.label AS label, requested_by" in c:
            return self.followups
        if "a.year AS year" in c:
            return self.appointments
        if "c.changed AS changed" in c:
            return [self.change] if self.change else []
        if "RETURN n" in c:
            return [{"n": n} for n in self.nodes]
        if "type(r) AS type" in c:
            ids = set(params["ids"])
            return [e for e in self.edges if e["source"] in ids and e["target"] in ids]
        return []


@pytest.fixture
def reads(monkeypatch):
    def install(**kwargs):
        fake = Reads(**kwargs)
        monkeypatch.setattr(db, "query", fake.query)
        return fake
    return install


# ---------------- a fact with no confirmed evidence ----------------

def test_an_item_with_no_confirmed_evidence_is_not_tracked(reads):
    """A follow-up written by a confirm that then failed. Nothing points at it."""
    reads(followups=[{
        "id": "fu:knee_physio_referral", "item": "knee_physio_referral",
        "label": "Knee physio referral",
        # The span exists but its document is still a draft, so the query
        # returns a null doc_id.
        "requested_by": [{"span_id": "D01-P1", "doc_id": None, "doc_title": None,
                          "date": None, "text": "..."}],
        "receipts": [{"span_id": None, "doc_id": None, "date": None}],
    }])
    assert g.preparation(PID) == []


def test_an_item_with_confirmed_evidence_is_tracked(reads):
    reads(followups=[{
        "id": "fu:insurance_card", "item": "insurance_card", "label": "Insurance card",
        "requested_by": [span("D02", "D02-P3", "2026-10-15")],
        "receipts": [{"span_id": None, "doc_id": None, "date": None}],
    }])
    items = g.preparation(PID)
    assert [i["label"] for i in items] == ["Insurance card"]
    assert items[0]["status"] == "receipt_not_documented"
    assert items[0]["requested_by"][0]["span_id"] == "D02-P3"


# ---------------- a receipt belongs to one request episode ----------------

def _referral(requested, received):
    return [{
        "id": "fu:knee_physio_referral", "item": "knee_physio_referral",
        "label": "Knee physio referral",
        "requested_by": [span("D0%d" % i, "D0%d-P1" % i, d) for i, d in enumerate(requested, 1)],
        "receipts": [span("R0%d" % i, "R0%d-P1" % i, d) for i, d in enumerate(received, 1)],
    }]


def test_a_receipt_after_the_request_documents_it(reads):
    reads(followups=_referral(requested=["2026-10-12"], received=["2026-10-15"]))
    assert g.preparation(PID)[0]["status"] == "receipt_documented"


def test_an_older_receipt_does_not_close_a_later_request(reads):
    """The item was asked for again after it was last handed in."""
    reads(followups=_referral(requested=["2026-06-01", "2026-10-12"],
                              received=["2026-06-03"]))
    item = g.preparation(PID)[0]
    assert item["status"] == "receipt_not_documented"
    # The newest evidence of each kind is first, so a reader cites the episode
    # that is actually open.
    assert item["requested_by"][0]["date"] == "2026-10-12"
    assert item["receipts"][0]["date"] == "2026-06-03"


def test_a_repeat_request_is_closed_again_by_its_own_receipt(reads):
    reads(followups=_referral(requested=["2026-06-01", "2026-10-12"],
                              received=["2026-06-03", "2026-10-15"]))
    assert g.preparation(PID)[0]["status"] == "receipt_documented"


def test_a_receipt_with_no_request_still_counts(reads):
    """Something handed in that nobody is recorded as having asked for."""
    reads(followups=_referral(requested=[], received=["2026-10-15"]))
    assert g.preparation(PID)[0]["status"] == "receipt_documented"


# ---------------- appointments: year, order, and what is next ----------------

def _appt(date, time, year, doc="D01", span_id="D01-P2", confirmed=True):
    return {"date": date, "time": time, "year": year,
            "sources": [{"span_id": span_id, "doc_id": doc if confirmed else None,
                         "text": "..."}]}


def test_iso_date_needs_a_year():
    assert g.iso_date("20 October", "2026") == "2026-10-20"
    assert g.iso_date("3 March", "2027") == "2027-03-03"
    assert g.iso_date("20 October", "") == ""
    assert g.iso_date("20 October", None) == ""
    assert g.iso_date("not a date", "2026") == ""
    assert g.iso_date("", "2026") == ""


def test_appointments_come_back_soonest_first(reads):
    reads(appointments=[
        _appt("20 November", "9:00 AM", "2026", span_id="D01-P2"),
        _appt("20 October", "10:00 AM", "2026", span_id="D02-P1"),
    ])
    out = g.appointments(PID, today="2026-10-01")
    assert [a["on"] for a in out] == ["2026-10-20", "2026-11-20"]
    assert all(a["upcoming"] for a in out)


def test_a_past_appointment_is_not_upcoming(reads):
    reads(appointments=[_appt("20 October", "10:00 AM", "2026")])
    assert g.appointments(PID, today="2026-10-21")[0]["upcoming"] is False


def test_an_appointment_without_a_year_is_never_called_upcoming(reads):
    """It cannot be placed on a calendar, so it cannot be claimed as next."""
    reads(appointments=[_appt("20 October", "10:00 AM", "")])
    out = g.appointments(PID, today="2026-10-01")
    assert out[0]["year"] == "" and out[0]["on"] == ""
    assert out[0]["upcoming"] is False


def test_an_undated_appointment_sorts_after_dated_ones(reads):
    reads(appointments=[
        _appt("20 October", "10:00 AM", "", span_id="D01-P2"),
        _appt("20 November", "9:00 AM", "2026", span_id="D02-P1"),
    ])
    assert [a["year"] for a in g.appointments(PID, today="2026-10-01")] == ["2026", ""]


def test_an_appointment_with_no_confirmed_source_is_hidden(reads):
    reads(appointments=[_appt("20 October", "10:00 AM", "2026", confirmed=False)])
    assert g.appointments(PID, today="2026-10-01") == []


# ---------------- the change record cites real spans ----------------

def test_change_entries_carry_the_span_that_evidences_them(reads):
    reads(
        followups=_referral(requested=["2026-10-12"], received=["2026-10-15"]),
        change={"doc_id": "R01", "doc_title": "Front desk slip", "doc_date": "2026-10-15",
                "at": "2026-10-15T09:00:00+00:00",
                "changed": '[{"id": "fu:knee_physio_referral", '
                           '"label": "Knee physio referral", '
                           '"from": "receipt_not_documented", "to": "receipt_documented"}]',
                "unchanged": "[]", "added": "[]"},
    )
    change = g.latest_change(PID)
    entry = change["changed"][0]
    # The receipt in the document that caused the change, not a guessed "-P1".
    assert (entry["doc_id"], entry["span_id"]) == ("R01", "R01-P1")


def test_a_change_entry_with_no_evidence_gets_no_span(reads):
    reads(
        followups=[],
        change={"doc_id": "R01", "doc_title": "Slip", "doc_date": "2026-10-15",
                "at": "2026-10-15T09:00:00+00:00", "changed": "[]", "unchanged": "[]",
                "added": '[{"id": "fu:gone", "label": "Gone", "to": "receipt_not_documented"}]'},
    )
    entry = g.latest_change(PID)["added"][0]
    assert "span_id" not in entry and "doc_id" not in entry


def test_change_for_is_scoped_to_the_document_it_was_asked_about(reads):
    """A retried confirm must report its own diff, not the newest one."""
    fake = reads(followups=[], change=None)
    assert g.change_for(PID, "R07") is None

    scoped = [(c, p) for c, p in fake.asked if "c.changed AS changed" in c]
    assert scoped, "change_for must query the Change records"
    cypher, params = scoped[-1]
    assert params == {"id": "R07"}
    assert "Document {id:$id}" in cypher


# ---------------- the graph view ----------------

def node(nid, kind, **props):
    """One node as the graph view query returns it. `kind` is the graph label;
    `label` stays free for the node's own display-name property."""
    return {"id": nid, "labels": [kind], **props}


def test_the_graph_view_drops_a_fact_with_no_surviving_span(reads):
    """D02 is a draft, so its span is dropped — and so is the follow-up that
    nothing else evidences. The appointment keeps its confirmed span."""
    reads(
        nodes=[
            node("D01", "Document", status="confirmed", title="Referral"),
            node("D01-P2", "EvidenceSpan", doc_id="D01"),
            node("appt:2026:20 October:10:00 AM", "Appointment", date="20 October",
                 time="10:00 AM"),
            node("fu:orphan", "FollowUp", label="Orphan"),
        ],
        edges=[
            {"source": "D01", "target": "D01-P2", "type": "HAS_SPAN"},
            {"source": "D01-P2", "target": "appt:2026:20 October:10:00 AM",
             "type": "CONFIRMS"},
            {"source": PID, "target": "fu:orphan", "type": "HAS_FOLLOWUP"},
        ],
    )
    view = g.subgraph(PID)
    kinds = {n["id"]: n["type"] for n in view["nodes"]}
    assert "fu:orphan" not in kinds
    assert kinds["appt:2026:20 October:10:00 AM"] == "Appointment"
    assert all(e["source"] in kinds and e["target"] in kinds for e in view["edges"])


def test_the_graph_view_keeps_a_receipt_chain(reads):
    """span -> Receipt -> FollowUp is two hops from the evidence."""
    reads(
        nodes=[
            node("D02", "Document", status="confirmed", title="Slip"),
            node("D02-P1", "EvidenceSpan", doc_id="D02"),
            node("fu:referral@D02-P1", "Receipt", date="2026-10-15"),
            node("fu:referral", "FollowUp", label="Referral"),
        ],
        edges=[
            {"source": "D02", "target": "D02-P1", "type": "HAS_SPAN"},
            {"source": "D02-P1", "target": "fu:referral@D02-P1", "type": "DOCUMENTS_RECEIPT"},
            {"source": "fu:referral@D02-P1", "target": "fu:referral", "type": "FULFILLS"},
        ],
    )
    kinds = {n["id"]: n["type"] for n in g.subgraph(PID)["nodes"]}
    assert kinds["fu:referral"] == "FollowUp"
    assert kinds["fu:referral@D02-P1"] == "Receipt"



# ---------------- the receipt's event date, as the graph shows it ----------------

def test_pretty_date_reads_as_a_date_a_person_would_say():
    assert g.pretty_date("2026-11-20") == "20 Nov 2026"
    assert g.pretty_date("2026-01-03") == "3 Jan 2026"


def test_pretty_date_leaves_anything_that_is_not_an_iso_date_alone():
    assert g.pretty_date("") == ""
    assert g.pretty_date(None) == ""
    assert g.pretty_date("last Tuesday") == "last Tuesday"
    assert g.pretty_date("2026-13-20") == "2026-13-20"


def test_a_receipt_node_is_labelled_with_its_event_date(reads):
    reads(
        nodes=[
            node("D02", "Document", status="confirmed", title="Clinic front-desk note"),
            node("D02-P1", "EvidenceSpan", doc_id="D02"),
            node("fu:vitamin_d_report@D02-P1", "Receipt", date="2026-11-20",
                 date_source="sentence"),
            node("fu:vitamin_d_report", "FollowUp", label="Vitamin D report"),
        ],
        edges=[
            {"source": "D02", "target": "D02-P1", "type": "HAS_SPAN"},
            {"source": "D02-P1", "target": "fu:vitamin_d_report@D02-P1",
             "type": "DOCUMENTS_RECEIPT"},
            {"source": "fu:vitamin_d_report@D02-P1", "target": "fu:vitamin_d_report",
             "type": "FULFILLS"},
        ],
    )
    labels = {n["id"]: n["label"] for n in g.subgraph(PID)["nodes"]}
    assert labels["fu:vitamin_d_report@D02-P1"] == "Receipt 20 Nov 2026"

# ---------------- why did this item change? ----------------
# The Today card can now open both ends of the story, so each entry carries the
# request that started the item and the newest receipt that settled it, plus
# the graph path between them. It used to carry one span and no way to tell
# which of the two it was.

def test_a_changed_entry_carries_both_ends_of_the_story(reads):
    reads(
        followups=_referral(requested=["2026-10-12"], received=["2026-10-15"]),
        change={"doc_id": "R01", "doc_title": "Front desk slip", "doc_date": "2026-10-15",
                "at": "2026-10-15T09:00:00+00:00",
                "changed": '[{"id": "fu:knee_physio_referral", '
                           '"label": "Knee physio referral", '
                           '"from": "receipt_not_documented", "to": "receipt_documented"}]',
                "unchanged": "[]", "added": "[]"},
    )
    entry = g.latest_change(PID)["changed"][0]

    assert entry["requested_by"]["span_id"] == "D01-P1"
    assert entry["requested_by"]["doc_id"] == "D01"
    assert entry["receipt"]["span_id"] == "R01-P1"
    assert entry["receipt"]["date"] == "2026-10-15"
    # The path runs from the person through the request to the receipt.
    assert entry["path"][0].startswith("Person:")
    assert "FollowUp:Knee physio referral" in entry["path"]
    assert entry["path"][-1] == "Document:R01"


def test_the_newest_receipt_is_the_one_that_settled_it(reads):
    """An older receipt is not what changed the status."""
    reads(
        followups=_referral(requested=["2026-10-12"], received=["2026-10-13", "2026-10-15"]),
        change={"doc_id": "R02", "doc_title": "Slip", "doc_date": "2026-10-15",
                "at": "2026-10-15T09:00:00+00:00",
                "changed": '[{"id": "fu:knee_physio_referral", "label": "Knee physio referral",'
                           ' "from": "receipt_not_documented", "to": "receipt_documented"}]',
                "unchanged": "[]", "added": "[]"},
    )
    entry = g.latest_change(PID)["changed"][0]
    assert entry["receipt"]["span_id"] == "R02-P1"


def test_an_item_with_no_receipt_yet_says_so_rather_than_inventing_one(reads):
    reads(
        followups=_referral(requested=["2026-10-12"], received=[]),
        change={"doc_id": "D01", "doc_title": "Referral note", "doc_date": "2026-10-12",
                "at": "2026-10-12T09:00:00+00:00", "changed": "[]",
                "added": '[{"id": "fu:knee_physio_referral", "label": "Knee physio referral",'
                         ' "to": "receipt_not_documented"}]',
                "unchanged": "[]"},
    )
    entry = g.latest_change(PID)["added"][0]
    assert entry["receipt"] is None
    assert entry["requested_by"]["span_id"] == "D01-P1"


def test_an_entry_the_graph_no_longer_tracks_gains_no_sides(reads):
    reads(
        followups=[],
        change={"doc_id": "R01", "doc_title": "Slip", "doc_date": "2026-10-15",
                "at": "2026-10-15T09:00:00+00:00", "changed": "[]", "unchanged": "[]",
                "added": '[{"id": "fu:gone", "label": "Gone", "to": "receipt_not_documented"}]'},
    )
    entry = g.latest_change(PID)["added"][0]
    assert "requested_by" not in entry and "receipt" not in entry and "path" not in entry

