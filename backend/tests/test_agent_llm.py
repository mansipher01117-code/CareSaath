"""The LLM agent, with a scripted Gemini client — no network, no API key.

What matters here is not that the model is clever but that nothing it says can
escape the records: a citation the tools never returned is dropped, a draft
document stays unreadable, and every failure lands on the rules engine instead
of on the user.
"""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from google.genai import types  # noqa: E402

from app import agent, graph_ops as g  # noqa: E402

PID = "nilofer"

# My mother's profile: a knee physio referral asked for in one record, received
# in the next, and an appointment confirmed in the first.
DOCS = {
    "D01": {
        "id": "D01", "title": "Physio referral note", "date": "2026-10-12",
        "status": "confirmed",
        "spans": [
            {"id": "D01-P1", "index": 1,
             "text": "Please bring the knee physio referral to the next appointment."},
            {"id": "D01-P2", "index": 2,
             "text": "Appointment confirmed for 20 October at 10:00 AM."},
        ],
    },
    "D02": {
        "id": "D02", "title": "Front desk slip", "date": "2026-10-15",
        "status": "confirmed",
        "spans": [{"id": "D02-P1", "index": 1,
                   "text": "The knee physio referral was received at the front desk."}],
    },
    # A draft: under review, so no answer may ever quote it.
    "D03": {
        "id": "D03", "title": "Unreviewed note", "date": "2026-10-16",
        "status": "draft",
        "spans": [{"id": "D03-P1", "index": 1, "text": "Reduce the evening dose to half."}],
    },
}

FOLLOWUPS = [{
    "id": "fu:knee_physio_referral", "item": "knee_physio_referral",
    "label": "Knee physio referral", "status": "receipt_documented",
    "requested_by": [{"span_id": "D01-P1", "doc_id": "D01", "doc_title": "Physio referral note",
                      "date": "2026-10-12", "text": DOCS["D01"]["spans"][0]["text"]}],
    "receipts": [{"span_id": "D02-P1", "doc_id": "D02", "doc_title": "Front desk slip",
                  "date": "2026-10-15", "text": DOCS["D02"]["spans"][0]["text"]}],
    "path": [],
}]

APPOINTMENTS = [{"date": "20 October", "time": "10:00 AM",
                 "sources": [{"span_id": "D01-P2", "doc_id": "D01",
                              "text": DOCS["D01"]["spans"][1]["text"]}]}]


@pytest.fixture(autouse=True)
def records(monkeypatch):
    """One person's graph, without a graph. Also guarantees no real API call:
    with no key, an un-stubbed client would refuse before reaching the network."""
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_MODEL", raising=False)
    monkeypatch.setattr(g, "person", lambda pid: {
        "id": PID, "name": "Nilofer", "relation": "Mother", "caregiver": "Zoya", "records": 2})
    monkeypatch.setattr(g, "appointments", lambda pid: APPOINTMENTS)
    monkeypatch.setattr(g, "preparation", lambda pid: FOLLOWUPS)
    monkeypatch.setattr(g, "latest_change", lambda pid: {
        "doc_id": "D02", "doc_title": "Front desk slip", "doc_date": "2026-10-15",
        "at": "2026-10-15T09:00:00+00:00",
        "changed": [{"id": "fu:knee_physio_referral", "label": "Knee physio referral",
                     "from": "receipt_not_documented", "to": "receipt_documented"}],
        "unchanged": [], "added": []})
    monkeypatch.setattr(g, "get_document", lambda pid, doc_id: DOCS.get(doc_id))


# ---------------- a scripted Gemini client ----------------

def call(name, **args):
    return SimpleNamespace(name=name, args=args)


def turn(*, text=None, calls=()):
    """One generate_content response: tool calls, or the final text.

    The candidate content is a real ``types.Content``, because what goes back
    to Gemini on the next turn is built from these parts — a fake that cannot
    be put in a ``types.Content`` would hide exactly the bug below.
    """
    parts = [types.Part(function_call=types.FunctionCall(name=c.name, args=c.args))
             for c in calls]
    if text is not None:
        parts.append(types.Part(text=text))
    return SimpleNamespace(
        text=text,
        candidates=[SimpleNamespace(content=types.Content(role="model", parts=parts))],
    )


def roles_sent(client) -> list[list[str]]:
    """The role of every Content sent, per request."""
    out = []
    for req in client.models.seen:
        out.append([c["role"] if isinstance(c, dict) else c.role for c in req["contents"]])
    return out


class FakeModels:
    def __init__(self, script):
        self.script, self.seen = list(script), []

    def generate_content(self, *, model, contents, config):
        # A copy: `contents` is the live list the agent keeps appending to, and
        # the real SDK serializes it at call time, so each request has to be
        # recorded as it was sent.
        self.seen.append({"model": model, "contents": list(contents), "config": config})
        step = self.script.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


class FakeClient:
    def __init__(self, script):
        self.models = FakeModels(script)


@pytest.fixture
def gemini(monkeypatch):
    """Script the model's turns; returns the client so the request can be read back."""
    holder = {}

    def script(*turns):
        holder["client"] = FakeClient(turns)
        monkeypatch.setattr(agent, "_client", lambda: holder["client"])
        return holder["client"]

    return script


def answer_json(claims, intent="preparation", refused=False):
    return json.dumps({"intent": intent, "refused": refused, "claims": claims})


# ---------------- a grounded answer ----------------

def test_grounded_answer_keeps_its_citations(gemini):
    client = gemini(
        turn(calls=[call("list_unresolved_followups")]),
        turn(calls=[call("inspect_source_span", doc_id="D02", span_id="D02-P1")]),
        turn(text=answer_json([
            {"text": "The 12 October note asked for the Knee physio referral.",
             "sources": [{"doc_id": "D01", "span_id": "D01-P1"}]},
            {"text": "D02 (2026-10-15) documents that it was received.",
             "sources": [{"doc_id": "D02", "span_id": "D02-P1"}]},
        ], intent="item")),
    )

    res = agent.ask(PID, "Is the knee physio referral sorted?", "en")

    assert res["engine"] == "llm"
    assert res["intent"] == "item"
    assert res["answer"] == [c["text"] for c in res["claims"]]
    # Each claim carries its own evidence, enriched with the paragraph text.
    assert [[s["span_id"] for s in c["sources"]] for c in res["claims"]] == [["D01-P1"], ["D02-P1"]]
    assert res["claims"][0]["sources"][0]["text"] == DOCS["D01"]["spans"][0]["text"]
    assert res["claims"][0]["sources"][0]["doc_title"] == "Physio referral note"
    # Top-level sources are the union, de-duplicated.
    assert [(s["doc_id"], s["span_id"]) for s in res["sources"]] == [("D01", "D01-P1"),
                                                                     ("D02", "D02-P1")]
    # Every tool call is in the trace, with its arguments and a short summary.
    assert [t["tool"] for t in res["trace"]] == ["list_unresolved_followups",
                                                 "inspect_source_span"]
    assert res["trace"][0]["args"] == {}
    assert res["trace"][0]["returned"] == "1 item(s)"
    assert res["trace"][1]["args"] == {"doc_id": "D02", "span_id": "D02-P1"}
    assert "D02-P1" in res["trace"][1]["returned"]
    # The rules live in the system instruction the model was actually sent.
    system = client.models.seen[0]["config"]["system_instruction"]
    assert "reviewed" in system and "not documented in the confirmed records" in system


def test_tool_declarations_cover_the_four_tools(gemini):
    gemini(turn(text=answer_json([{"text": "No follow-up items are being tracked yet.",
                                   "sources": []}])))
    agent.ask(PID, "anything pending?", "en")
    client_cfg = agent.TOOL_DECLARATIONS
    assert [d["name"] for d in client_cfg] == [
        "retrieve_patient_context", "list_unresolved_followups", "latest_change",
        "inspect_source_span"]
    assert set(agent.tools_for(PID)) == {d["name"] for d in client_cfg}


# ---------------- a hallucinated citation ----------------

def test_hallucinated_citation_is_dropped(gemini):
    gemini(
        turn(calls=[call("list_unresolved_followups")]),
        turn(text=answer_json([
            # One real pair, one span the tools never returned, and one real span
            # paired with the wrong document.
            {"text": "The referral was received on 15 October.",
             "sources": [{"doc_id": "D02", "span_id": "D02-P1"},
                         {"doc_id": "D09", "span_id": "D09-P1"},
                         {"doc_id": "D02", "span_id": "D01-P1"}]},
            {"text": "An MRI was also requested.",
             "sources": [{"doc_id": "D07", "span_id": "D07-P3"}]},
        ], intent="item")),
    )

    res = agent.ask(PID, "What was received?", "en")

    assert res["engine"] == "llm"
    assert [s["span_id"] for s in res["claims"][0]["sources"]] == ["D02-P1"]
    # The invented claim keeps its text but is left with no evidence behind it.
    assert res["claims"][1]["sources"] == []
    assert [s["span_id"] for s in res["sources"]] == ["D02-P1"]
    blob = json.dumps(res)
    for invented in ("D09-P1", "D07-P3"):
        assert invented not in blob


def test_a_draft_document_is_not_readable():
    """inspect_source_span is scoped to confirmed documents of this person."""
    ok = agent.inspect_source_span(PID, "D01", "D01-P1")
    assert ok["text"] == DOCS["D01"]["spans"][0]["text"]

    draft = agent.inspect_source_span(PID, "D03", "D03-P1")
    assert "error" in draft and "Reduce the evening dose" not in str(draft)
    # An id echoed back inside an error message must not become citable.
    assert agent.validate_sources([{"doc_id": "D03", "span_id": "D03-P1"}],
                                  [{"tool": "inspect_source_span", "result": draft}]) == []

    assert "error" in agent.inspect_source_span(PID, "D01", "D01-P9")
    assert "error" in agent.inspect_source_span(PID, "D99", "D99-P1")


# ---------------- a medical-advice question ----------------

def test_medical_advice_is_refused_with_no_sources(gemini):
    client = gemini(turn(text=answer_json(
        [{"text": "I can't advise on a dose — CareSaath only explains what your records "
                  "say, so please ask the doctor.", "sources": []}],
        intent="refusal", refused=True)))

    res = agent.ask(PID, "Should I halve her evening dose?", "en")

    assert res["engine"] == "llm"
    assert res["intent"] == "refusal"
    assert res["sources"] == []
    assert res["claims"][0]["sources"] == []
    assert "ask the doctor" in res["answer"][0]
    # The refusal is instructed, not hoped for: the rule is in the system prompt.
    system = client.models.seen[0]["config"]["system_instruction"]
    for rule in ("diagnosis", "dosage", "medication change", "medical advice"):
        assert rule in system


def test_refusal_cannot_smuggle_in_a_citation(gemini):
    """A refused answer that cites a draft still gets the draft dropped."""
    gemini(turn(text=answer_json(
        [{"text": "That is a question for the doctor.",
          "sources": [{"doc_id": "D03", "span_id": "D03-P1"}]}],
        intent="refusal", refused=True)))
    res = agent.ask(PID, "Is half a dose right?", "en")
    assert res["sources"] == [] and res["claims"][0]["sources"] == []


# ---------------- the fallbacks ----------------

def _assert_rules_fallback(res, reason):
    assert res["engine"] == "rules"
    assert res["answer"], "the rules engine must still answer"
    note = res["trace"][0]
    assert note["tool"] == "gemini"
    assert "answered with rules instead" in note["returned"]
    assert reason in note["returned"]
    # The rules answer is grounded the same way.
    assert [t["tool"] for t in res["trace"][1:]] == ["retrieve_patient_context",
                                                     "list_unresolved_followups"]
    assert all(s["span_id"] in {"D01-P1", "D01-P2", "D02-P1"} for s in res["sources"])


def test_missing_key_falls_back_to_rules(monkeypatch):
    """No key at all: no client is built, so nothing can reach the network."""
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    res = agent.ask(PID, "What should I clarify before the appointment?", "en")
    _assert_rules_fallback(res, "GEMINI_API_KEY is not set")
    assert any("Knee physio referral" in line for line in res["answer"])


def test_blank_key_falls_back_to_rules(monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "   ")
    res = agent.ask(PID, "What should I clarify before the appointment?", "en")
    _assert_rules_fallback(res, "GEMINI_API_KEY is not set")


def test_invalid_json_falls_back_to_rules(gemini):
    gemini(
        turn(calls=[call("list_unresolved_followups")]),
        turn(text="Sure! The referral was received. Hope that helps."),
    )
    res = agent.ask(PID, "What should I clarify before the appointment?", "en")
    _assert_rules_fallback(res, "did not return a JSON object")


def test_truncated_json_falls_back_to_rules(gemini):
    gemini(turn(text='{"intent": "item", "claims": [{"text": "half a sentence"}'))
    res = agent.ask(PID, "What should I clarify before the appointment?", "en")
    _assert_rules_fallback(res, "invalid JSON from model")


def test_json_without_claims_falls_back_to_rules(gemini):
    gemini(turn(text='{"intent": "item", "answer": "the referral arrived"}'))
    res = agent.ask(PID, "What should I clarify before the appointment?", "en")
    _assert_rules_fallback(res, "no claims")


def test_api_error_falls_back_to_rules(gemini):
    gemini(RuntimeError("429 RESOURCE_EXHAUSTED: free tier quota exceeded"))
    res = agent.ask(PID, "What should I clarify before the appointment?", "en")
    _assert_rules_fallback(res, "RESOURCE_EXHAUSTED")


def test_the_key_never_reaches_the_trace(gemini, monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "AIzaSyFAKEKEYFORTESTS000000")
    gemini(RuntimeError("401 from endpoint?key=AIzaSyFAKEKEYFORTESTS000000"))
    res = agent.ask(PID, "What changed?", "en")
    assert res["engine"] == "rules"
    assert "AIzaSyFAKEKEYFORTESTS000000" not in json.dumps(res)
    assert "***" in res["trace"][0]["returned"]


def test_endless_tool_calling_falls_back_to_rules(gemini):
    gemini(*[turn(calls=[call("latest_change")]) for _ in range(agent.MAX_TOOL_TURNS)])
    res = agent.ask(PID, "What changed?", "en")
    assert res["engine"] == "rules"
    assert "tool turns" in res["trace"][0]["returned"]


# ---------------- the rules engine still holds up its end ----------------

def test_rules_claims_carry_their_own_sources(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    res = agent.ask(PID, "What changed after the latest record?", "hi")
    assert res["engine"] == "rules"
    assert res["intent"] == "changes"
    assert res["lang"] == "hi"
    cited = [c for c in res["claims"] if c["sources"]]
    assert cited, "the changed item must cite the evidence that moved it"
    assert cited[0]["sources"][0]["span_id"] == "D02-P1"


def test_an_unknown_language_is_answered_in_english(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    res = agent.ask(PID, "When is the appointment?", "fr")
    assert res["lang"] == "en"
    assert res["answer"] == ["Appointment confirmed for 20 October at 10:00 AM (D01)."]
    assert res["claims"][0]["sources"][0]["span_id"] == "D01-P2"


# ---------------- the rules engine refuses what it must not answer ----------------

def test_the_rules_engine_refuses_medical_advice(monkeypatch):
    """Without a key there is no model to apply the refusal rule, and the
    router used to answer a dosage question with appointment details."""
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    res = agent.ask(PID, "Should I reduce her painkiller dose before the visit?", "en")

    assert res["engine"] == "rules"
    assert res["intent"] == "refusal"
    assert res["sources"] == [] and res["claims"][0]["sources"] == []
    assert "ask the doctor" in res["answer"][0].lower()
    # Nothing was read: a refusal is not an answer about the records.
    assert [t["tool"] for t in res["trace"] if t["tool"] != "gemini"] == []
    assert "20 October" not in json.dumps(res)


def test_the_rules_refusal_speaks_the_requested_language(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    res = agent.ask(PID, "Kitni dawa deni chahiye?", "hi")
    assert res["intent"] == "refusal"
    assert "doctor se poochhein" in res["answer"][0].lower()


def test_records_questions_that_mention_a_medicine_are_still_answered(monkeypatch):
    """The guard must not swallow a legitimate question about the records."""
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    for question in ["What should I clarify before the appointment?",
                     "Was the medicine list received?",
                     "When is the appointment?"]:
        res = agent.ask(PID, question, "en")
        assert res["intent"] != "refusal", question


def test_needs_refusal_boundaries():
    for q in ["Should I halve her evening dose?", "Is it safe to skip the tablet?",
              "What is her diagnosis?", "Can I give her the painkiller?"]:
        assert agent.needs_refusal(q), q
    for q in ["What should I clarify before the appointment?",
              "What should I bring to the appointment?",
              "Was the medicine list received?",
              "Appointment se pehle kya clarify karna hai?"]:
        assert not agent.needs_refusal(q), q


# ---------------- the roles Gemini actually accepts ----------------
# Production trace: 400 INVALID_ARGUMENT "Role 'tool' is not supported. Please
# use a valid role: SYSTEM, USER, MODEL". Function results used to go back as a
# Content with role "tool", so every tool-calling question fell through to the
# rules engine.

VALID_ROLES = {"user", "model"}


def test_no_tool_role_is_ever_sent_and_the_llm_answers(gemini):
    client = gemini(
        turn(calls=[call("list_unresolved_followups")]),
        turn(calls=[call("inspect_source_span", doc_id="D02", span_id="D02-P1")]),
        turn(text=answer_json([{"text": "The referral was received on 15 October.",
                                "sources": [{"doc_id": "D02", "span_id": "D02-P1"}]}],
                              intent="item")),
    )

    res = agent.ask(PID, "Is the knee physio referral sorted?", "en")

    # The whole point: the tool-calling conversation now completes.
    assert res["engine"] == "llm"
    assert res["intent"] == "item"
    assert [s["span_id"] for s in res["sources"]] == ["D02-P1"]

    sent = roles_sent(client)
    assert sent, "the model was never called"
    for roles in sent:
        assert "tool" not in roles
        assert "function" not in roles
        assert set(roles) <= VALID_ROLES, roles
    # Three requests: the question, then after one tool turn, then after two.
    assert sent == [["user"], ["user", "model", "user"],
                    ["user", "model", "user", "model", "user"]]


def test_the_function_call_turn_goes_back_as_the_model(gemini):
    client = gemini(
        turn(calls=[call("latest_change")]),
        turn(text=answer_json([{"text": "D02 documented the receipt.",
                                "sources": [{"doc_id": "D02", "span_id": "D02-P1"}]}],
                              intent="changes")),
    )
    agent.ask(PID, "What changed?", "en")

    second = client.models.seen[1]["contents"]
    assert second[1].role == "model"
    assert second[1].parts[0].function_call.name == "latest_change"


def test_the_tool_result_goes_back_as_a_user_function_response(gemini):
    client = gemini(
        turn(calls=[call("inspect_source_span", doc_id="D02", span_id="D02-P1")]),
        turn(text=answer_json([{"text": "D02-P1 records the receipt.",
                                "sources": [{"doc_id": "D02", "span_id": "D02-P1"}]}],
                              intent="item")),
    )
    agent.ask(PID, "What does D02-P1 say?", "en")

    reply = client.models.seen[1]["contents"][2]
    assert reply.role == "user"
    fr = reply.parts[0].function_response
    assert fr.name == "inspect_source_span"
    assert "D02-P1" in str(fr.response)


def test_an_invalid_argument_error_is_traced_short_not_as_raw_json(gemini):
    """What the production trace used to dump into the UI."""
    gemini(RuntimeError(
        "400 INVALID_ARGUMENT. {'error': {'code': 400, 'message': \"Role 'tool' is not "
        "supported. Please use a valid role: SYSTEM, USER, MODEL, FUNCTION.\", "
        "'status': 'INVALID_ARGUMENT'}}"))

    res = agent.ask(PID, "What changed?", "en")

    assert res["engine"] == "rules"
    returned = res["trace"][0]["returned"]
    assert returned == "Gemini unavailable: 400 INVALID_ARGUMENT — answered with rules instead"
    assert "{" not in returned and "'message'" not in returned


def test_a_plain_error_is_still_readable_in_the_trace(gemini):
    gemini(RuntimeError("connection reset by peer"))
    res = agent.ask(PID, "What changed?", "en")
    assert "connection reset by peer" in res["trace"][0]["returned"]
