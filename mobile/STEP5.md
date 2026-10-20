# Step 5 — Offline sync

Source implementation adds authenticated PostgreSQL push/pull sync, durable raw voice archival, and manual conflict resolution. Server setup and API details: [backend/SYNC.md](../backend/SYNC.md).

Open **API connection**, enter an HTTPS backend origin and the administrator-issued **device token**, then save while online. The app validates `/sync/me` before saving. Local capture still works without a connection. Once bound, a local database belongs to that server/device/technician; changing identity is refused to prevent mixing site data. Token rotation for the same device identity is compatible; provisioning a different device ID requires a separate installation/profile after pending data is handled. Disconnect clears the secure token but preserves the database binding and local work.

Open **Sync & review** from the home screen's sync icon. It shows inventory operations, audio uploads, failures and conflicts. **Sync now** attempts eligible work. Fix permissions/settings before retrying failed work. Retry preserves the original operation and payload because its first acknowledgement may have been lost. Successors wait for that receipt. Automatic transient retries stop after eight attempts with exponential backoff and jitter.

For a conflict, compare device and server snapshots. **Keep device edits** creates a new operation using the reviewed server version; a further concurrent edit can conflict again. **Use server copy** accepts the server state. Both snapshots and the decision are retained in `sync_resolutions`. Server deletions cannot be resurrected automatically; accepting a parent removal retires dependent local inventory and pending mutations, with audit copies. Audio files are retained. A site's unresolved conflicts block new inventory confirmation/import and queued AI turns until review.

Database v3 is an additive migration from v1/v2. It adds `sync_shadow`, `sync_conflicts`, `sync_resolutions`, `sync_connection`, `voice_upload_jobs`, and dependency/lease fields on the existing outbox. Recording completion atomically queues independent AI and archive jobs. Existing complete local recordings are backfilled for archival. Secrets (`credential_ref`) and file paths (`local_file_ref`) never leave the device in generic sync JSON. Credentials stay in secure storage; standard SQLite itself is not encrypted.

The worker pushes in dependency order, archives audio, pushes completed transcripts, then pulls granted sites using per-site cursors. Edits made during a request become immutable successors and rebase after acknowledgement. Unsent edits can coalesce. Lost replies preserve the request ID for safe replay. Pulls defer uncertain in-flight writes and unreviewed AI proposals; local edits become conflicts rather than being overwritten. Applying a pull refreshes the assistant's canonical site context and invalidates older AI responses.

Sync starts at launch/resume, on connectivity events, and every 15 seconds while foregrounded. This release has no OS background scheduler; keep/open the app online to finish syncing. Site creation must sync before device-authorized AI can run. Voice archival does not depend on Gemini/Groq availability. A pulled voice note contains its server object identity and transcript; automatic audio download/playback is not included (authorized download API is available).

Current limitations: no app deletion editor, user login/SSO, account switching, GPS/photo capture, admin/AMC dashboard, SQLCipher, automatic retention/pruning, or native background delivery. Server deletion API/pull behavior is supported. Raw discovery scans and CGI review snapshots stay device-local; imported canonical inventory and sanitized observations sync. Chat histories and pending/unreviewed AI proposals are device-local. The later Android test APK is documented in ANDROID_TESTING.md. iOS builds and physical network/microphone tests remain required.

## Validation in this workspace

- 42 Python tests passed, including eight integration tests against real PostgreSQL 16.
- 61 Flutter unit/widget tests passed across the full regression suite and added sync API/review checks; static analysis reports no issues.
- The separate live integration passed: two independent SQLite databases exchanged reviewed inventory, both NVR interfaces and a voice archive through a real loopback FastAPI/PostgreSQL server. It also replayed a committed request after a simulated lost acknowledgement.
- Historical PostgreSQL/SQLite v1 schema artifacts regenerate unchanged, the bundled SQLite asset matches, and migration recovery retains queued notes and backfills existing local audio for archival.
- Test PostgreSQL and API instances were temporary and removed after validation. At completion of Step 5, no production deployment, live inference, APK/IPA build or physical-device validation had been performed. The subsequent Android build is documented in ANDROID_TESTING.md.
