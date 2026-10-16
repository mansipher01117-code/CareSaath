# CareSaath — Family Health Companion (Graph Hacks 2026)

Multilingual family health-record companion. Reviewed records are connected in
**FalkorDB**, so the agent can answer *"what do I still need to clarify before the
appointment?"* with a source on every claim that has one — and when a new record arrives,
**only the related item updates** while everything else stays (and says so).

One app, many family members: each profile keeps its own records, follow-ups and
graph.

> Not a diagnostic tool — it only explains what the records say.
> There is no sign-in: anyone who can reach the API can read every profile in it.

Track: **01 — Agents That Act on Connected Data** (graph queries as agent tools,
explainable results). Restart persistence also covers Track 02.

---

## Stack

| Part | Tech |
|---|---|
| App (web + Android) | Flutter / Dart (`frontend/`) |
| API + agent | Python, FastAPI (`backend/`) |
| Context graph | FalkorDB + Cypher (`docker-compose.yml`) |

## Run it (3 terminals)

**1. FalkorDB** (with persistent volume + browser on :3000)
```bash
docker compose up -d
```

**2. Backend**
```bash
cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```
Nothing is seeded — the app starts empty and you create the first profile in the
UI. Check http://localhost:8000/health and http://localhost:8000/docs.

No Docker? `pip install falkordblite` and run with `FALKORDB_EMBEDDED=1`
(Linux/macOS only — `redislite` does not build on Windows).

**3. Flutter app**
```bash
cd frontend
flutter create . --project-name caresaath --platforms web,android   # generates web/ and android/ folders (once)
flutter pub get
flutter run -d chrome
```
Android emulator:
```bash
flutter run -d emulator-5554 --dart-define=API_URL=http://10.0.2.2:8000
```
and add `android:usesCleartextTraffic="true"` to the `<application>` tag in
`android/app/src/main/AndroidManifest.xml` (local http only).

## Using it

1. **Add the first family member** — name, relation, optional caregiver. The
   selected profile is remembered in browser/device storage, and the switcher in
   the shell moves between profiles.
2. **Add record** — paste a visit note, a front-desk slip, anything. Leave a
   blank line between paragraphs; each paragraph becomes a citable source.
3. **Review** — the extractor suggests facts. Rename an item, point it at a
   different paragraph, or uncheck it. Only what you confirm reaches the graph.
4. **Today** — the appointment and every follow-up, each with the evidence
   behind its status and the graph path that derived it.
5. **Ask** — questions in English or Hindi/Hinglish, answered only from that
   person's confirmed records. The answer is a list of claims and each one
   carries its own evidence, so a quote sits under the sentence it backs. A
   claim that rests on the *absence* of a record ("receipt is not documented")
   shows no source, because none exists. The agent's tool trace is below it.
6. **Graph** — that person's live subgraph; tap a document or span for the
   original text.

## Profiles and isolation

Each profile gets **its own FalkorDB graph**, `person_<id>`, and a small registry
graph (`caresaath_people`) holds just the list of profiles. Every record endpoint
requires a `person_id` and only ever opens that person's graph, so a query
written for one family member cannot reach another's records — including the
agent's tools, which are bound to one person before they run.

## Follow-up items

Items are not a fixed list. The extractor reads any *"please bring / bring /
carry X"* request and any *"X was received"* receipt out of the text and
normalizes X into a key (`existing lab report` → `existing_lab_report`). The
review step is where that guess gets corrected: the item name is a free-text
field, and two items whose names normalize to the same key are the same
follow-up — so renaming is also how you merge.

## Graph model

```
(:Person)-[:HAS_DOCUMENT]->(:Document {status: draft|confirmed})
(:Document)-[:HAS_SPAN]->(:EvidenceSpan)                 # citable paragraph
(:EvidenceSpan)-[:REQUESTS]->(:FollowUp)<-[:HAS_FOLLOWUP]-(:Person)
(:EvidenceSpan)-[:DOCUMENTS_RECEIPT]->(:Receipt)-[:FULFILLS]->(:FollowUp)
(:EvidenceSpan)-[:CONFIRMS]->(:Appointment)<-[:HAS_APPOINTMENT]-(:Person)
(:Document)-[:CAUSED]->(:Change)                         # what moved / what stayed
```
Status is **derived by traversal** (FollowUp ← Receipt ← Span ← confirmed Document),
never stored as a bare flag. The main query is `PREP_CYPHER` in
`backend/app/graph_ops.py`, also returned by `GET /preparation`.

## API

Every path below except `/health` and `/people` takes a `person_id` query
parameter, and returns 404 if no such profile exists.

| Method | Path | Purpose |
|---|---|---|
| GET | /health | API + graph status |
| POST | /people | create a profile `{name, relation, caregiver?}` |
| GET | /people | all profiles with their record counts |
| GET | /people/{id} | one profile + appointments |
| DELETE | /people/{id} | delete the profile and drop its graph |
| GET | /records, /records/{id} | timeline, original source with spans |
| POST | /records/preview | draft + suggested facts (not used in answers) |
| POST | /records/{id}/confirm | write reviewed facts → graph, returns change diff |
| DELETE | /records/{id} | discard a draft |
| GET | /preparation | follow-ups with derived status, sources, graph path |
| GET | /changes/latest | last change (changed / unchanged / added) |
| GET | /graph | subgraph for the graph view |
| POST | /ask | agent answer `{answer: [{text, sources}], sources, trace}` (lang: en/hi) |

## Where to add features next

| Feature | Where |
|---|---|
| LLM answers (Claude/Gemini/etc.) | `agent.py` → swap `route()` for tool-calling, `compose()` for generation; keep `validate_sources()` |
| PDF / image + OCR | new `POST /records/upload` → text → same `extract()` → same review flow |
| Better extraction | replace `extractor.extract()` (keep the returned shape) |
| More languages (bn, mr, ta, te) | add to `T` in `agent.py` + `_langs` in `ask_screen.dart` (or Sarvam translate) |
| Voice | Sarvam STT/TTS in Ask screen |
| MCP | expose `agent.tools_for(pid)` as MCP tools |
| Auth | a login in front of the profile picker; the per-person graph split is already there |

## Honest limitations (v0.2)

- Extraction is rule-based: it reads request/receipt phrasings out of the text,
  so it will over- and under-match. Human review is the safety net.
- Agent routing and answer text are deterministic templates; no LLM yet.
- English + Hindi/Hinglish answers only; UI chrome is English.
- Text entry only; no file upload yet.
- **No auth.** Every profile on the server is visible to anyone who can reach
  the API — run it locally, and think before putting real health data in it.
