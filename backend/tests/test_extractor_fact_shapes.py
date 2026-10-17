"""The fact shapes the Review screen has to migrate between.

Each type carries only its own fields — a request has no date, an appointment
has no item, an absence_note has `items` and never `item`. That asymmetry is
why switching a fact's type cannot just overwrite `type` and keep the rest.
"""
from app.extractor import extract

NOTE = (
    "Please bring the knee physio referral to the next appointment.\n\n"
    "The knee physio referral was received at the front desk on 12 October.\n\n"
    "Appointment confirmed for 20 October at 10:00 AM with the physiotherapist.\n\n"
    "No receipt of the discharge summary is documented in the folder."
)


def facts_of(text, date="2026-10-12"):
    return extract("R07", text, date)["facts"]


def one(text, type_):
    found = [f for f in facts_of(text) if f["type"] == type_]
    assert len(found) == 1, f"expected one {type_}, got {found}"
    return found[0]


def test_every_paragraph_becomes_a_citable_span():
    ex = extract("R07", NOTE, "2026-10-12")
    assert [s["id"] for s in ex["spans"]] == ["R07-P1", "R07-P2", "R07-P3", "R07-P4"]


def test_request_has_an_item_and_no_date():
    f = one(NOTE, "request")
    assert f["item"] == "knee_physio_referral"
    assert f["label"] == "Knee physio referral"
    assert "date" not in f and "time" not in f


def test_receipt_has_an_item_and_the_record_date():
    f = one(NOTE, "receipt")
    assert f["item"] == "knee_physio_referral"
    assert f["date"] == "2026-10-12"
    assert "time" not in f


def test_appointment_has_a_date_and_time_but_no_item():
    f = one(NOTE, "appointment")
    assert (f["date"], f["time"]) == ("20 October", "10:00 AM")
    assert "item" not in f
    assert f["label"] == "Appointment"


def test_appointment_date_is_not_in_the_records_iso_format():
    """So a receipt's ISO date is not a usable appointment date either."""
    f = one(NOTE, "appointment")
    assert f["date"] != "2026-10-12"


def test_absence_note_carries_items_plural_and_never_item():
    f = one(NOTE, "absence_note")
    assert f["items"] == ["discharge_summary"]
    assert "item" not in f
    assert f["label"].startswith("Receipt not documented")


def test_absence_note_label_is_a_sentence_not_an_item_name():
    """Inheriting it as an item name is exactly the bug — it would become a
    follow-up called 'Receipt not documented: Discharge summary'."""
    f = one(NOTE, "absence_note")
    assert len(f["label"].split()) > 3


# ---------------- one sentence's negation is not the paragraph's ----------------

def types_in(text, date="2026-10-15"):
    return [(f["type"], f.get("label") or f.get("item")) for f in extract("D01", text, date)["facts"]]


def test_a_negative_clause_does_not_erase_a_positive_receipt():
    """Both sentences are in one paragraph, so both are about one span. The
    absence note used to swallow the whole paragraph and the receipt with it."""
    found = types_in(
        "The knee physio referral was received at the front desk. "
        "No receipt of the old X-ray film is on file yet."
    )
    assert ("receipt", "Knee physio referral") in found
    assert any(t == "absence_note" for t, _ in found)


def test_a_request_survives_a_neighbouring_negative_sentence():
    found = types_in(
        "No receipt of the discharge summary has been recorded. "
        "Please bring the insurance card to the appointment."
    )
    assert ("request", "Insurance card") in found


def test_a_negated_sentence_on_its_own_still_produces_no_receipt():
    found = types_in("The lab report was not received.")
    assert not [t for t, _ in found if t == "receipt"]


def test_each_sentence_keeps_the_paragraph_span():
    out = extract("D01", "The referral was received. Please bring the insurance card.",
                  "2026-10-15")
    assert len(out["spans"]) == 1
    assert {f["span_id"] for f in out["facts"]} == {"D01-P1"}


# ---------------- the appointment year ----------------

def appointment_in(text):
    facts = extract("D01", text, "2026-10-15")["facts"]
    return next(f for f in facts if f["type"] == "appointment")


def test_an_appointment_keeps_a_year_the_record_gives():
    f = appointment_in("Appointment confirmed for 20 October 2026 at 10:00 AM.")
    assert (f["date"], f["year"], f["time"]) == ("20 October", "2026", "10:00 AM")


def test_an_appointment_with_a_comma_before_the_year():
    f = appointment_in("Appointment confirmed for 20 October, 2026 at 10:00 AM.")
    assert (f["date"], f["year"]) == ("20 October", "2026")


def test_an_appointment_without_a_year_says_so_instead_of_guessing():
    """A note that never named the year does not get this one assumed for it."""
    f = appointment_in("Appointment confirmed for 20 October at 10:00 AM.")
    assert f["year"] == ""
    assert f["date"] == "20 October" and f["time"] == "10:00 AM"
