# Smartiva FieldOps — AI and sync backend

Step 5 PostgreSQL persistence, scoped device access and archival setup: [SYNC.md](SYNC.md).

Python 3.12+. Implements `POST /api/v1/ai/site-briefing` for text or audio and returns a validated inventory **proposal**, deterministic calculations, and prioritized Tamil/Tanglish follow-up questions. No site records are changed by this endpoint.

## Run locally

From repository root:

```sh
.venv/bin/pip install -r backend/requirements.txt
cp backend/.env.example backend/.env
# Edit backend/.env with a random private API token and provider keys.
cd backend
../.venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

`requirements.lock` records the exact installed environment used for verification; to reproduce it, install with `.venv/bin/pip install -r backend/requirements.lock` from the repository root. `.env` is ignored by git and is read relative to the working directory. Deployed environments should inject variables through their secrets manager. Never commit provider credentials or embed the shared API token in a distributed Flutter build.

`GET /healthz` is liveness only. Interactive API docs are at `http://127.0.0.1:8000/docs`. Startup requires a >=32-character API token; missing provider keys yield a clear 503 only for the affected operation.

### Text request

Use your configured private token in `SMARTIVA_API_TOKEN` in the calling shell:

```sh
curl --fail-with-body http://127.0.0.1:8000/api/v1/ai/site-briefing \
  -H "Authorization: Bearer $SMARTIVA_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @examples/briefing.json
```

JSON keys:

- `text`: nonblank Tamil/Tanglish/English transcript, up to 30,000 characters.
- `language`: `auto` (default), `ta` or `en`. Used as a transcription hint for audio; extraction always handles all three language forms.
- `site_id`: optional UUID echoed for client correlation, never used to fetch data.
- `context`: optional complete previous `extracted_data` proposal. Send it with the next technician answer to continue the conversation. The endpoint itself keeps no session state.

### Audio request

```sh
curl --fail-with-body http://127.0.0.1:8000/api/v1/ai/site-briefing \
  -H "Authorization: Bearer $SMARTIVA_API_TOKEN" \
  -F 'audio=@briefing.m4a;type=audio/mp4' \
  -F 'metadata={"language":"auto"}'
```

Audio uses Groq `whisper-large-v3` for transcription, followed by the selected Gemini or Groq extraction provider. Thus audio always needs a Groq key. Supported MIME types: WAV (`audio/wav`, `audio/x-wav`), MP3, M4A/MP4, WebM, Ogg and FLAC. The API validates declared MIME and size; the transcription provider validates the audio content. Default audio limit is 10 MiB and total request limit is 12 MiB, including chunked bodies. Tune limits together. Raw audio exists only for the request and is not saved by this endpoint. The Flutter app now supplies a local recording/AI request queue (see `../mobile/README.md`); durable archival uses the separate Step 5 upload endpoint (SYNC.md).

`metadata` is a JSON string containing optional `language`, `site_id` and `context`; `text` is not allowed in audio metadata. Malformed/duplicate multipart fields are rejected. Set `ta` for predominantly Tamil audio; `auto` is preferable for mixed speech.

## Response and engineering behavior

Response keys are `site_id`, `transcript`, `extracted_data`, `calculations`, `warnings`, `probes`, `next_question_tamil`, `requires_confirmation: true`, and `provider`.

For an explicitly complete 27 Dahua + 15 CP Plus breakdown on a 64-channel NVR:

```json
{
  "nvr_id": "nvr1",
  "capacity": 64,
  "reported_total": 42,
  "reported_active": null,
  "individually_documented": 0,
  "free_channels": 22,
  "poe_minimum_switches": {}
}
```

This is an illustrative calculation, not a live provider result. Reported installed/configured cameras are not assumed online. Camera totals do not create invented camera rows. Partial brand breakdowns are not summed into a site total. Counts are calculated independently per recorder, never pooled across unrelated NVRs. Conflicting reported totals yield warnings and suppress derived free-channel counts. Overcapacity is flagged rather than returning negative free channels.

Only when the technician explicitly states how many cameras require PoE does the engine return conditional minimum switch counts: for 42 PoE cameras, 6 × 8-port, 3 × 16-port, or 2 × 24-port switches. These are alternative theoretical lower bounds assuming every counted port is available for PoE. Shared uplink ports, NVR integrated PoE, power budget, watt draw, cable distance, topology and redundancy must be checked before selecting hardware; these estimates are not a bill of materials.

The engine probes recorder capacity, active cameras, PoE count, network uplinks, switch location and camera mapping, used/free/faulty ports, UPS mapping/runtime, floors and contact details. Existing typed switch/UPS reports suppress answered questions. Port-state counts are treated as mutually exclusive: `used` means occupied working ports; `faulty` ports are counted separately. The first probe supplies `next_question_tamil`; the client can show remaining probes as a checklist. Questions use conversational Romanized Tamil/Tanglish. Parsing and Tamil transcription quality still require field evaluation with actual accents, noise and vendor names.

## Proposal-to-database mapping

`extracted_data` is a strict typed DTO designed around Step 1's domain tables. It intentionally has no credential, sync/version, confirmed, or arbitrary metadata write fields. Refs are proposal-local identifiers (`nvr1`, `ground`, etc.), not database-generated UUIDs. Related `*_id` fields point to these refs. This enables consistent references without asking a language model to invent persistent identifiers.

On later technician confirmation, the persistence service must authorize the site, map new refs to UUIDs (preserving known refs/IDs from context), add site IDs/timestamps/source/version, and save in the transaction service defined in `database/README.md`. `site`, `contacts`, `floors`, `zones`, `assets`, `network_interfaces`, `cameras` and `connectivity` map to their corresponding tables. Each `inventory_reports`, `switch_reports` and `ups_reports` item maps to an `observations` row with its recorder/switch/UPS `asset_id`, a typed `kind`, payload and explicit review state. Flutter performs reviewed ref-to-UUID mapping; Step 5 sync endpoints persist those canonical mutations (SYNC.md).

Reference validation rejects dangling links, duplicate refs/channels, wrong recorder/switch types, interface ownership mismatches, malformed IP/MAC addresses and invalid capacities. Conflicting evidence that is useful for follow-up (such as cameras exceeding recorder capacity) returns warnings. Context is merged by the model and revalidated; it is not a durable audit log and the technician must review the result. Send canonical reviewed context rather than trusting old model output as authoritative.

## Providers and failures

- Gemini REST: `gemini-2.5-flash`, JSON output mode, temperature 0 and local Pydantic validation; thinking disabled for this extraction task.
- Groq REST: `llama-3.3-70b-versatile`, JSON object mode, temperature 0 and the same validation.
- Schema supplied in the system prompt; native provider schema subsets cannot weaken local validation. Extra keys, truncated JSON or broken references fail closed with 502. No unvalidated text is returned as structured inventory.
- Upstream timeouts return 504; rate limits/unreachable provider return 503; other upstream errors return 502 with fixed codes and no upstream body. No silent provider fallback, fabricated extraction or automatic paid retries. Offline clients should retain their request and retry transient failures with backoff.
- Per-call and whole-briefing deadlines and per-process concurrency limits bound work. Capacity exhaustion returns 503 with `Retry-After: 5`. Request body limiting bounds each upload, including before multipart parsing. Set gateway connection/rate limits and slow-upload/read timeouts before exposure.

## Access and data handling

The token protects a stateless internal service. Before technician deployment, place it behind your authenticated gateway or replace the dependency with per-user JWT/OIDC and site authorization; a shared service token alone is not multi-user access control. Terminate HTTPS, restrict docs as needed, configure provider quotas, and apply retention/access policies to transcripts and contact data. Do not expose this development service directly to the internet.

Common typed credential patterns and URLs are redacted from text/context before extraction and from the returned transcript/proposal. This is best-effort, not comprehensive secret detection. Raw uploaded audio is necessarily sent to Groq before transcription redaction. Technicians must not speak passwords or credentials. No transcript, audio, prompt, credential or provider error body is logged by application code; avoid enabling HTTP wire logging. Provider processing/retention follows the configured provider account's policy.

## Verification

From repository root:

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Tests use stub/mocked providers, exercising both provider wire formats, Whisper multipart, schema/reference failures, calculations, count conflicts, multiple recorders, answered probes, auth, bounded uploads, malformed input, deadlines, safe provider errors and OpenAPI references. No provider keys were configured in this workspace, so real Gemini/Groq calls and real Tamil recordings have not been tested. PostgreSQL persistence and device/site authorization are implemented in Step 5; user login/SSO remains a future milestone. Flutter local capture and review are implemented separately; see `../mobile/README.md`.
