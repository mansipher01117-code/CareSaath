"""Every claim in an answer carries its own evidence.

The bug these cover: an answer was a list of plain strings with one pooled
list of sources underneath, so no line could be traced to the span behind it.
A reader could not tell which quote backed which sentence, claims that rest on
the *absence* of a record looked as cited as the rest, and "what changed?"
pooled every receipt span of the latest record regardless of which item the
line was about.

Fixtures here are mine (Nilofer's knee physio referral), not seeded demo data.
"""
import pytest

from app import agent, graph_ops as g

from conftest import PERSON

PID = PERSON["id"]

DOCS = {
    "R07": {
        "id": "R07", "title": "Physio referral note", "date": "2026-10-12",
        "spans": [
            {"id": "R07-P1", "index": 1,
             "text": "Please bring the knee physio referral to the next appointment."},
            {"id": "R07-P2", "index": 2, "text": "Please bring the blood sugar report."},
            {"id": "R07-P3", "index": 3, "text": "Appointment confirmed for 20 October at 10:00 AM."},
        ],
    },
    "R09": {
        "id": "R09", "title": "Front desk slip", "date": "2026-10-15",
        "spans": [
            {"id": "R09-P1", "index": 1, "text": "Knee physio referral was received at the front desk."},
            {"id": "R09-P2", "index": 2,
             "text": "Please bring the discharge summary from the previous hospital."},
        ],
    },
}

KNEE = {
    "id": "fu:knee_physio_referral", "item": "knee_physio_referral",
    "label": "Knee physio referral", "status": "receipt_documented",
    "requested_by": [{"span_id": "R07-P1", "doc_id": "R07", "doc_title": "Physio referral note",
                      "date": "2026-10-12", "text": DOCS["R07"]["spans"][0]["text"]}],
    "receipts": [{"span_id": "R09-P1", "doc_id": "R09", "doc_title": "Front desk slip",
                  "date": "2026-10-15", "text": DOCS["R09"]["spans"][0]["text"]}],
    "path": [],
}
SUGAR = {
    "id": "fu:blood_sugar_report", "item": "blood_sugar_report",
    "label": "Blood sugar report", "status": "receipt_not_documented",
    "requested_by": [{"span_id": "R07-P2", "doc_id": "R07", "doc_title": "Physio referral note",
                      "date": "2026-10-12", "text": DOCS["R07"]["spans"][1]["text"]}],
    "receipts": [], "path": [],
}
DISCHARGE = {
    "id": "fu:discharge_summary", "item": "discharge_summary",
    "label": "Discharge summary", "status": "receipt_not_documented",
    "requested_by": [{"span_id": "R09-P2", "doc_id": "R09", "doc_title": "Front desk slip",
                      "date": "2026-10-15", "text": DOCS["R09"]["spans"][1]["text"]}],
    "receipts": [], "path": [],
}
APPOINTMENT = {
    "date": "20 October", "time": "10:00 AM",
    "sources": [{"span_id": "R07-P3", "doc_id": "R07", "text": DOCS["R07"]["spans"][2]["text"]}],
}
# What the front-desk slip moved: the referral became documented, the discharge
# summary started being tracked, the blood sugar report stayed outstanding.
CHANGE = {
    "doc_id": "R09", "doc_title": "Front desk slip", "doc_date": "2026-10-15",
    "at": "2026-10-15T09:00:00+00:00",
    "changed": [{"id": KNEE["id"], "label": KNEE["label"],
                 "from": "receipt_not_documented", "to": "receipt_documented"}],
    "added": [{"id": DISCHARGE["id"], "label": DISCHARGE["label"], "to": "receipt_not_documented"}],
    "unchanged": [{"id": SUGAR["id"], "label": SUGAR["label"], "status": "receipt_not_documented"}],
}


@pytest.fixture
def records(monkeypatch):
    """Nilofer's confirmed records, as the graph tools would return them."""
    monkeypatch.setattr(g, "person", lambda pid: {"id": pid, "name": PERSON["name"], "records": 2})
    monkeypatch.setattr(g, "appointments", lambda pid: [APPOINTMENT])
    monkeypatch.setattr(g, "preparation", lambda pid: [SUGAR, DISCHARGE, KNEE])
    monkeypatch.setattr(g, "latest_change", lambda pid: CHANGE)
    monkeypatch.setattr(g, "get_document", lambda pid, doc_id: DOCS.get(doc_id))
    return DOCS


def claim(res, needle):
    """The one claim whose text contains `needle`."""
    hits = [l for l in res["answer"] if needle in l["text"]]
    assert len(hits) == 1, f"{needle!r} matched {len(hits)} claims: {res['answer']}"
    return hits[0]


def spans(line):
    return [s["span_id"] for s in line["sources"]]


# ---------------- preparation: each claim cites its own span ----------------

def test_a_request_claim_cites_the_span_that_requested_it(records):
    res = agent.ask(PID, "What should I clarify before the appointment?")
    assert spans(claim(res, "Knee physio referral was requested")) == ["R07-P1"]
    assert spans(claim(res, "Blood sugar report was requested")) == ["R07-P2"]


def test_a_receipt_claim_cites_the_span_that_documents_it(records):
    res = agent.ask(PID, "What should I clarify before the appointment?")
    assert spans(claim(res, "Knee physio referral: receipt is documented")) == ["R09-P1"]


def test_a_claim_about_a_missing_receipt_cites_nothing(records):
    """Absence is not in the graph: the claim goes out with no source at all."""
    res = agent.ask(PID, "What should I clarify before the appointment?")
    assert claim(res, "Blood sugar report: receipt is not documented")["sources"] == []


def test_the_appointment_claim_cites_the_span_that_confirms_it(records):
    res = agent.ask(PID, "What should I clarify before the appointment?")
    assert spans(claim(res, "Appointment confirmed for")) == ["R07-P3"]


def test_summary_and_caveat_claims_carry_no_sources(records):
    res = agent.ask(PID, "What should I clarify before the appointment?")
    assert claim(res, "You may want to clarify")["sources"] == []
    assert claim(res, "Note: 'received' means")["sources"] == []


def test_no_claim_cites_a_span_from_another_item(records):
    """The whole point: a source never drifts onto a neighbouring line."""
    res = agent.ask(PID, "What should I clarify before the appointment?")
    item_spans = {"knee": {"R07-P1", "R09-P1"}, "sugar": {"R07-P2"}, "discharge": {"R09-P2"}}
    for line in res["answer"]:
        for key, allowed in item_spans.items():
            other = set().union(*(v for k, v in item_spans.items() if k != key))
            label = {"knee": "Knee physio referral", "sugar": "Blood sugar report",
                     "discharge": "Discharge summary"}[key]
            if line["text"].startswith(label):
                assert set(spans(line)) <= allowed
                assert not set(spans(line)) & other


# ---------------- the answer and its sources stay in step ----------------

def test_top_level_sources_are_the_union_of_the_claims(records):
    res = agent.ask(PID, "What should I clarify before the appointment?")
    from_claims = []
    for line in res["answer"]:
        for s in line["sources"]:
            if (s["span_id"], s["doc_id"]) not in [(x["span_id"], x["doc_id"]) for x in from_claims]:
                from_claims.append(s)
    assert [(s["span_id"], s["doc_id"]) for s in res["sources"]] == \
           [(s["span_id"], s["doc_id"]) for s in from_claims]


def test_a_claims_source_carries_the_span_text_for_the_ui(records):
    res = agent.ask(PID, "What should I clarify before the appointment?")
    s = claim(res, "Knee physio referral: receipt is documented")["sources"][0]
    assert s["text"] == DOCS["R09"]["spans"][0]["text"]
    assert s["doc_title"] == "Front desk slip"
    assert s["date"] == "2026-10-15"


def test_a_repeated_source_is_hydrated_everywhere_it_is_cited(records):
    """The claims share the deduped source dicts, so none is left without text."""
    res = agent.ask(PID, "What should I clarify before the appointment?")
    for line in res["answer"]:
        for s in line["sources"]:
            assert s["text"], f"{s['span_id']} cited by {line['text']!r} has no text"


def test_a_source_the_tools_never_returned_is_dropped_from_its_claim():
    lines = [{"text": "invented", "sources": [{"span_id": "R99-P9", "doc_id": "R99"}]},
             {"text": "real", "sources": [{"span_id": "R07-P1", "doc_id": "R07"}]}]
    flat = agent.validate_sources(lines, {"list_unresolved_followups": [KNEE]})
    assert lines[0]["sources"] == []
    assert spans(lines[1]) == ["R07-P1"]
    assert [s["span_id"] for s in flat] == ["R07-P1"]


# ---------------- one item, and "what changed?" ----------------

def test_an_item_question_answers_about_that_item_with_its_own_sources(records):
    res = agent.ask(PID, "Did they receive the blood sugar report?")
    assert res["intent"] == "item"
    assert res["matched_items"] == [SUGAR["id"]]
    assert spans(claim(res, "Blood sugar report was requested")) == ["R07-P2"]
    assert claim(res, "receipt is not documented")["sources"] == []


def test_a_change_claim_cites_the_span_behind_that_item(records):
    res = agent.ask(PID, "What changed after the latest record?")
    assert res["intent"] == "changes"
    assert spans(claim(res, "Knee physio referral changed")) == ["R09-P1"]


def test_a_newly_tracked_item_cites_the_request_that_started_it(records):
    res = agent.ask(PID, "What changed after the latest record?")
    assert spans(claim(res, "New item tracked: Discharge summary")) == ["R09-P2"]


def test_an_unchanged_item_with_no_receipt_cites_nothing(records):
    res = agent.ask(PID, "What changed after the latest record?")
    assert claim(res, "Blood sugar report stayed the same")["sources"] == []


def test_the_change_header_is_not_given_someone_elses_span(records):
    res = agent.ask(PID, "What changed after the latest record?")
    assert claim(res, "was confirmed:")["sources"] == []


# ---------------- the shape the app receives ----------------

def test_ask_endpoint_returns_claims_with_their_own_sources(client, records):
    r = client.post("/ask", params={"person_id": PID},
                    json={"question": "When is the appointment?", "lang": "en"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["intent"] == "appointment"
    assert [l["text"] for l in body["answer"]] == \
           ["Appointment confirmed for 20 October at 10:00 AM (R07)."]
    assert body["answer"][0]["sources"][0]["span_id"] == "R07-P3"
    assert body["sources"][0]["text"] == DOCS["R07"]["spans"][2]["text"]


def test_hindi_claims_carry_the_same_sources(records):
    en = agent.ask(PID, "What should I clarify before the appointment?")
    hi = agent.ask(PID, "Appointment se pehle kya clarify karna hai?", lang="hi")
    assert [spans(l) for l in hi["answer"]] == [spans(l) for l in en["answer"]]
