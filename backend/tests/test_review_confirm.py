"""Confirming a reviewed record.

The bug these cover: the Review screen let a fact's type be switched while
every field of the *old* type was carried across, so an appointment
relabelled as a receipt arrived with no item name and a request relabelled as
an appointment arrived with no time. Both used to be written anyway — as a
nameless follow-up, and as an `appt:None:None` appointment that then showed
up on Today.
"""
from app import graph_ops as g

from conftest import PERSON, confirm

GOOD_RECEIPT = {
    "type": "receipt", "item": "knee_physio_referral", "label": "Knee physio referral",
    "span_id": "R07-P1", "date": "2026-10-12",
}
GOOD_APPOINTMENT = {
    "type": "appointment", "span_id": "R07-P2", "date": "20 October", "time": "10:00 AM",
    "label": "Appointment",
}


# ---------------- the valid path still works ----------------

def test_valid_facts_are_written(client, graph, draft):
    r = confirm(client, [GOOD_RECEIPT, GOOD_APPOINTMENT])
    assert r.status_code == 200, r.text
    assert r.json()["confirmed"] == "R07"

    written = " | ".join(c for _, c, _ in graph.writes)
    assert "DOCUMENTS_RECEIPT" in written
    assert "HAS_APPOINTMENT" in written

    fids = {p["fid"] for _, _, p in graph.writes if "fid" in p}
    assert fids == {"fu:knee_physio_referral"}
    aids = {p["aid"] for _, _, p in graph.writes if "aid" in p}
    assert aids == {"appt:20 October:10:00 AM"}


def test_writes_only_touch_that_persons_graph(client, graph, draft):
    confirm(client, [GOOD_RECEIPT])
    assert {name for name, _, _ in graph.writes} == {f"person_{PERSON['id']}"}


# ---------------- an item-bearing fact with no item name ----------------

def test_receipt_without_an_item_name_is_rejected(client, graph, draft):
    """What an appointment switched to 'receipt' used to look like."""
    r = confirm(client, [{"type": "receipt", "span_id": "R07-P2", "date": "2026-10-12"}])
    assert r.status_code == 400
    assert "item name" in r.json()["detail"]
    assert graph.writes == []


def test_request_with_a_blank_item_name_is_rejected(client, graph, draft):
    r = confirm(client, [{"type": "request", "label": "   ", "span_id": "R07-P1"}])
    assert r.status_code == 400
    assert graph.writes == []


def test_item_name_that_normalizes_to_nothing_is_rejected(client, graph, draft):
    """'the' is only a determiner, so it leaves no key behind."""
    r = confirm(client, [{"type": "request", "label": "the", "span_id": "R07-P1"}])
    assert r.status_code == 400
    assert graph.writes == []


# ---------------- a half-built appointment ----------------

def test_appointment_without_a_time_is_rejected(client, graph, draft):
    """What a receipt switched to 'appointment' used to look like: it kept the
    record date and had no time at all."""
    r = confirm(client, [{"type": "appointment", "span_id": "R07-P1", "date": "2026-10-12"}])
    assert r.status_code == 400
    assert "date and a time" in r.json()["detail"]
    assert graph.writes == []


def test_appointment_without_a_date_is_rejected(client, graph, draft):
    r = confirm(client, [{"type": "appointment", "span_id": "R07-P2", "time": "10:00 AM"}])
    assert r.status_code == 400
    assert graph.writes == []


def test_no_appt_none_none_can_be_written(client, graph, draft):
    """A request switched to 'appointment' carried neither field."""
    confirm(client, [{"type": "appointment", "span_id": "R07-P1", "label": "Appointment"}])
    assert not [p for _, _, p in graph.writes if "None" in str(p.get("aid", ""))]


# ---------------- unknown types ----------------

def test_unknown_fact_type_is_rejected(client, graph, draft):
    r = confirm(client, [{"type": "reciept", "label": "Typo", "span_id": "R07-P1"}])
    assert r.status_code == 400
    assert "Unknown fact type" in r.json()["detail"]
    assert graph.writes == []


def test_one_bad_fact_rejects_the_whole_confirm(client, graph, draft):
    """Validation runs before any write, so a partial record cannot land."""
    r = confirm(client, [GOOD_RECEIPT, {"type": "appointment", "span_id": "R07-P2"}])
    assert r.status_code == 400
    assert graph.writes == []


def test_fact_citing_an_unknown_span_is_still_rejected(client, graph, draft):
    r = confirm(client, [dict(GOOD_RECEIPT, span_id="R07-P9")])
    assert r.status_code == 400
    assert "unknown span" in r.json()["detail"]
    assert graph.writes == []


# ---------------- absence_note stays informational ----------------

def test_absence_note_is_not_tracked(client, graph, draft):
    r = confirm(client, [{
        "type": "absence_note", "span_id": "R07-P1", "items": ["knee_physio_referral"],
        "label": "Receipt not documented: Knee physio referral",
    }])
    assert r.status_code == 200
    assert not [p for _, _, p in graph.writes if "fid" in p]


# ---------------- the graph layer guards itself too ----------------

def test_confirm_document_skips_a_half_appointment(graph, draft):
    """Defence in depth: reached directly, bypassing the endpoint."""
    g.confirm_document(PERSON["id"], "R07", [{"type": "appointment", "span_id": "R07-P1"}])
    assert "HAS_APPOINTMENT" not in " ".join(c for _, c, _ in graph.writes)


def test_confirm_document_skips_an_unnamed_item(graph, draft):
    g.confirm_document(PERSON["id"], "R07", [{"type": "receipt", "span_id": "R07-P1"}])
    assert "DOCUMENTS_RECEIPT" not in " ".join(c for _, c, _ in graph.writes)


# ---------------- the helpers the validator leans on ----------------

def test_item_of_derives_the_key_from_the_confirmed_label():
    assert g.item_of({"label": "The existing lab report"})[0] == "existing_lab_report"
    assert g.item_of({"label": "  Knee physio referral "}) == (
        "knee_physio_referral", "Knee physio referral")


def test_item_of_renaming_merges_two_spellings():
    assert g.item_of({"label": "Home BP log"})[0] == g.item_of({"label": "the home bp log"})[0]


def test_item_of_is_empty_when_there_is_no_name():
    assert g.item_of({})[0] == ""
    assert g.item_of({"label": None})[0] == ""


def test_item_of_falls_back_to_the_extractor_key():
    assert g.item_of({"item": "knee_physio_referral"})[0] == "knee_physio_referral"


def test_appointment_of_requires_both_halves():
    assert g.appointment_of({"date": "20 October", "time": "10:00 AM"}) == (
        "20 October", "10:00 AM")
    assert not all(g.appointment_of({"date": "20 October"}))
    assert not all(g.appointment_of({"time": "10:00 AM"}))
    assert not all(g.appointment_of({"date": "  ", "time": "  "}))
    assert not all(g.appointment_of({}))
