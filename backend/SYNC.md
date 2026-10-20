# Step 5 — PostgreSQL sync and voice archive

## Configure and initialize

Install `backend/requirements.lock` in a Python 3.12 virtual environment. Copy `backend/.env.example` to `backend/.env`, configure a dedicated PostgreSQL role/database, a random internal `SMARTIVA_API_TOKEN`, and provider keys for AI. Use PostgreSQL 16+ and the `postgresql+psycopg://` driver URL. From `backend/`:

```sh
../.venv/bin/python -m app.manage init-db
../.venv/bin/python -m app.manage issue-device --technician "Field Engineer" --label "Company phone"
../.venv/bin/uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000
```

`init-db` creates missing tables and backfills change history for preexisting sites without a sync head; it never resets inventory. The v1 domain schema is unchanged. For a deployment using SQL migrations, apply `database/migrations/002_device_access.sql` once after `database/postgresql.sql`, then run `init-db` to backfill history. `create_all` cannot alter existing column definitions: future changes require explicit versioned migrations.

The provisioning command displays the new device token once; save it in the phone's secure connection settings. Only its SHA-256 hash is stored on the server. A new operator-created technician can create sites; site creation grants that technician write access. Other technicians see a site only after a grant:

```sh
../.venv/bin/python -m app.manage grant --technician "Other Engineer" --site-id SITE_UUID
../.venv/bin/python -m app.manage grant --technician "Viewer" --site-id SITE_UUID --read-only
../.venv/bin/python -m app.manage revoke-device --device-id DEVICE_UUID
```

The original shared service token authorizes only internal AI requests, never sync. Device tokens authorize AI only for granted sites; the mobile worker pushes site creation before dispatching its briefing. Operator provisioning has no public HTTP endpoint. User login/SSO and permission administration UI remain future work.

Use TLS at your reverse proxy; keep PostgreSQL private. Mount `SMARTIVA_AUDIO_STORAGE_PATH` on persistent private storage shared by API replicas, owned by the API service account. It must support POSIX atomic rename/fsync. Back up the volume and PostgreSQL together and verify restores. Never serve the storage directory directly through the proxy. Apply proxy request/body/concurrency limits and infrastructure rate limits; the application caps request sizes but is not a complete edge security layer. `.env` and device tokens must not enter source control or access logs.

## API contract

All routes require `Authorization: Bearer DEVICE_TOKEN`.

| Route | Behavior |
|---|---|
| `GET /api/v1/sync/me` | Validate active device and technician |
| `POST /api/v1/sync/push` | One atomic optimistic-version mutation |
| `GET /api/v1/sync/sites?after=UUID&limit=100` | Granted site IDs; `next` for paging, includes tombstones |
| `GET /api/v1/sites/{id}/changes?after=0&through=N&limit=100` | Ordered change snapshots, bounded page and fixed watermark |
| `PUT /api/v1/sites/{id}/voice/{voice_id}` | Immutable binary upload by UUID and SHA-256 |
| `GET /api/v1/sites/{id}/voice/{voice_id}` | Authorized binary download; no-store and checksum header |

Push JSON:

```json
{
  "operation_id": "00000000-0000-4000-8000-000000000001",
  "site_id": "00000000-0000-4000-8000-000000000002",
  "entity_type": "sites",
  "entity_id": "00000000-0000-4000-8000-000000000002",
  "operation": "create",
  "base_version": 0,
  "payload": {"name": "Yogasree Textiles", "extra": {}}
}
```

Use `create`, `update`, or `delete`; entity types are the ten canonical domain tables. JSON metadata is an object, observations `confirmed` is boolean, references are UUIDs. Server timestamps, versions and deletion timestamps are authoritative. Credentials and device file paths are rejected. Proposals use refs; Flutter maps those refs to UUIDs during review before enqueueing mutations.

A successful push returns `record`, `entity_type`, `revision`. Stale versions return HTTP 409 with `code: version_conflict` and `current` (possibly null); tombstones return `record_deleted`. The same operation ID + device + exact normalized request returns the original saved result, including conflicts. Changing that request returns 409 `operation_id_reused`. All server/admin writes must go through the transaction service; direct SQL/ORM inventory writes bypass history and are unsupported during normal operation.

A PostgreSQL transaction advisory lock serializes each site's mutations, including first creation. Record update, CAS version, change log, revision head and receipt commit together. Parent deletion tombstones descendants; referenced deleted parents cannot accept new children. Histories/receipts/tombstones currently have **no automatic pruning**. Do not delete them without introducing an explicit device reset/snapshot protocol.

A pull page returns `site_id`, `changes`, `cursor`, `through`, `has_more`. Preserve its `through` while fetching subsequent pages. `through` is a fixed high watermark, not a timestamp. The client commits records/conflicts/cursor in one SQLite transaction. A lost acknowledgement is replayed before pulling over uncertain local writes. Unreviewed AI proposals defer that site's pull; other sites continue.

Voice uploads use raw body bytes, `Content-Type: audio/mp4` (or supported WAV/MP3/WebM/Ogg/FLAC), `X-Audio-SHA256` (lowercase hex), and `X-Audio-Language: auto|ta|en`. Limits default to 10 MiB. Files are checksum verified, written mode 0600, fsynced and atomically renamed before database commit. A crash can leave an unreferenced file, never a deliberately deleted local recording. Repeated upload repairs a missing/corrupt object. Immutable object identity is separate from later transcript updates through sync. File content decoding is left to the transcription provider. AI processing is independent of archival availability; neither completion implies the other completed.

## Verify against a disposable database

**These tests create data. Supply a dedicated disposable database, never production.**

```sh
export SMARTIVA_TEST_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:55432/smartiva_test
.venv/bin/python -m unittest discover -s tests -v
FLUTTER_BIN=/path/to/flutter .venv/bin/python tests/run_mobile_sync.py
```

Run from repository root with Flutter dependencies already installed. The second command starts a loopback API with a temporary archive and a test-only device identity, then verifies actual Flutter SQLite/HTTP/PostgreSQL interchange. It makes no AI-provider requests and uses synthetic audio bytes solely to test transport/integrity. Native recording, NVR hardware, device permissions and APK/IPA builds require separate field testing.
