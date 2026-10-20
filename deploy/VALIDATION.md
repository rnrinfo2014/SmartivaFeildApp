# Stage 7 validation

Completed in the development workspace:

- Reproduced the device-authenticated AI authorization failure: the AI provider
  variable shadowed the PostgreSQL engine before site permission checks.
- Fixed that name collision. 44 backend/schema/integration tests passed against
  disposable PostgreSQL, including authorized text/audio AI requests, forbidden
  sites, required site IDs and readiness/storage checks. AI output in these tests
  is stubbed; audio bytes test transport only.
- Real Flutter two-device SQLite/HTTP/PostgreSQL integration test passed.
- Built the locked Python API image; Docker Compose configuration validated.
- Started isolated database, initialization and API containers; health/readiness
  returned HTTP 200 using synthetic provider-key configuration.
- Device provisioning/authentication, site creation and voice upload/download
  passed over real HTTP against that deployment.
- Restarted API and PostgreSQL; device identity, site and voice bytes remained.
- Confirmed API UID 10001 and absence of an embedded .env file.
- Caddy configuration validated. No public certificate was issued.
- Environment generator rejects invalid hostnames, creates mode-0600 settings,
  and refuses to overwrite an existing deployment's credentials.

Pending external setup and acceptance:

- User-provisioned VPS, hostname/DNS, trusted public HTTPS and backups/restore drill.
- Securely configured real Gemini/Groq credentials and successful provider calls.
- Phone connection, Tamil transcription quality, structured extraction/probing,
  reviewed inventory sync and offline-to-online queue draining against that host.

The current mobile 0.5.1 APK is compatible; no APK rebuild was required for this
backend change. The user's local phone startup/persistence checks already passed.
