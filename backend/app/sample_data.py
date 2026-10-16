"""Synthetic, fictional records for the demo (Arun / caregiver Meera).

D01–D03 are seeded. D04 is the record you add live during the demo to show
the targeted update.
"""

SEED = [
    {
        "title": "Clinic visit note",
        "date": "2026-09-20",
        "text": (
            "Arun attended a follow-up visit at the clinic. Caregiver Meera was present.\n\n"
            "Please bring the existing lab report and the home BP log to the next appointment."
        ),
    },
    {
        "title": "Family folder check",
        "date": "2026-10-01",
        "text": (
            "The family health folder was reviewed by Meera.\n\n"
            "No receipt of the lab report or the BP log is documented in the available folder."
        ),
    },
    {
        "title": "Appointment confirmation",
        "date": "2026-10-08",
        "text": "Appointment confirmed for 20 October at 10:00 AM with the same clinic.",
    },
]

LIVE_D04 = {
    "title": "Clinic front-desk note",
    "date": "2026-10-15",
    "text": "The existing lab report was received at the clinic front desk on 15 October.",
}
