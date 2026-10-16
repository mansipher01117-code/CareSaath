# CareSaath — Family Health Companion (Graph Hacks 2026)

Multilingual family health-record companion. Reviewed records are connected in
**FalkorDB**, so the agent can answer *"what do I still need to clarify before the
appointment?"* with a source for every claim — and when a new record arrives,
**only the related item updates** while everything else stays (and says so).

> Synthetic demo · all records are fictional (Arun, caregiver Meera).
> Not a diagnostic tool — it only explains what the records say.

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
First start seeds D01–D03 automatically. Check http://localhost:8000/health and
http://localhost:8000/docs.

No Docker? `pip install falkordblite` and run with `FALKORDB_EMBEDDED=1`
(Linux/macOS).

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

## Demo script (≈90 s)

1. **Today** — appointment 20 Oct 10:00 AM (source D03). Both items *Receipt not documented*.
2. **Ask** → "What should I clarify before the appointment?" → answer + sources + agent trace.
3. **Add record** → *Fill demo record* (D04, 15 Oct front-desk note) → **Extract & review**.
4. Review screen: original paragraph left, suggested fact right → **Confirm**.
5. Dialog + **What changed** card: *Lab report: not documented → documented*, *BP log: unchanged*.
6. **Ask** (हिंदी toggle) → "Latest record se kya badla?"
7. **Graph** tab → live nodes/edges; tap a span to open the original.
8. Restart backend + `docker compose restart` → state is still there.
9. Add D04 again → *already confirmed, no duplicate facts*.

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

| Method | Path | Purpose |
|---|---|---|
| GET | /health | API + graph status |
| GET | /person | profile + appointments |
| GET | /records, /records/{id} | timeline, original source with spans |
| POST | /records/preview | draft + suggested facts (not used in answers) |
| POST | /records/{id}/confirm | write reviewed facts → graph, returns change diff |
| DELETE | /records/{id} | discard a draft |
| GET | /preparation | follow-ups with derived status, sources, graph path |
| GET | /changes/latest | last change (changed / unchanged / added) |
| GET | /graph | subgraph for the graph view |
| POST | /ask | agent answer `{answer, sources, trace}` (lang: en/hi) |
| POST | /demo/reset | wipe + reseed D01–D03 |

## Where to add features next

| Feature | Where |
|---|---|
| LLM answers (Claude/Gemini/etc.) | `agent.py` → swap `route()` for tool-calling, `compose()` for generation; keep `validate_sources()` |
| PDF / image + OCR | new `POST /records/upload` → text → same `extract()` → same review flow |
| Better extraction | replace `extractor.extract()` (keep the returned shape) |
| More languages (bn, mr, ta, te) | add to `T` in `agent.py` + `_langs` in `ask_screen.dart` (or Sarvam translate) |
| Voice | Sarvam STT/TTS in Ask screen |
| MCP | expose `agent.TOOLS` as MCP tools |
| Auth / multiple families | one FalkorDB graph per family (`FALKORDB_GRAPH`) + login |

## Honest limitations (v0.1)

- Extraction is rule-based (keywords for lab report / BP log / appointment). Human review is the safety net.
- Agent routing and answer text are deterministic templates; no LLM yet.
- English + Hindi/Hinglish answers only; UI chrome is English.
- Text entry only; no file upload yet. No auth — local synthetic demo only, don't put real health data in it.
