# Smartiva FieldOps — VPS handover

## Start here

Continue this project; do not recreate it. The source archive contains the Flutter
mobile app, FastAPI backend, portable domain schemas, tests and Docker deployment.
It contains no live provider keys, device tokens, signing keys, recordings or
customer databases. Existing phone data stays on the phone. No production VPS
has been accessed or deployed from the original cloud task.

Read this file, then `deploy/README.md` and `deploy/VALIDATION.md`.
The user's next goal is to deploy the backend on an existing Azure/AWS/OVH VPS,
configure Gemini/Groq securely, connect the working phone and test AI plus sync.
They have Gemini and Groq keys. They have Codex machines named `SmartivaDevVm` and
`vps-9523d095`; which is the intended deployment target must be established by
inspecting the attached machine. Do not assume those names are SSH hostnames or
that another task's cloud workspace grants access to them.

## What exists

- `backend/app/`: authenticated FastAPI AI and PostgreSQL sync API.
- `backend/app/ai/`: Gemini/Groq structured extraction, Groq voice transcription,
  Tamil/Tanglish questions, deterministic channel/PoE calculations. Do not invent
  installed/online camera counts from channel capacity.
- `backend/app/sync/`: device auth, per-site grants, optimistic versioning,
  idempotent writes, change feeds, private audio archival.
- `backend/app/manage.py`: trusted operator schema/device/grant CLI.
- `database/`: initial PostgreSQL/SQLite schema and device-access migration.
- `mobile/lib/`: SQLite offline queues, voice capture, chat/review screens,
  Dahua/CP Plus CGI Digest bridge, DHIP/SADP/ONVIF discovery, inventory sync.
- `deploy/`: Dockerfile, Compose, Caddy, private environment generator and runbook.
- `tests/`, `mobile/test/`: backend/schema/PostgreSQL and Flutter regression tests.
- A React admin dashboard has not been implemented in this source package.

## Accepted phone build and important fixes

Mobile 0.5.1+3, displayed `0.5.1-test`, package
`com.smartiva.smartiva_fieldops.test`, Android 7.0/API 24 minimum, target API 36,
ARMv7/ARM64. User's Moto Edge 60 Fusion / Android 17 successfully opens the app,
creates the Rajrelax site and retains text/voice after reopening. Real NVR/network
hardware and connected AI/sync phone acceptance remain pending.

Android startup was fixed by changing result-returning
`PRAGMA busy_timeout=5000` to `rawQuery`, because Android execSQL rejects it.
`test/android_database_test.dart` reproduces the old platform contract failure.
Bootstrap now reports safe step/error codes rather than incorrectly blaming disk
space. Do not revert this or reset the phone database.

A second backend bug was fixed: the briefing function's AI provider local variable
shadowed the PostgreSQL engine during device-token site authorization. It is now
named `ai`; authorized text and audio device requests have PostgreSQL regressions.

Current APK SHA256:
`365c314b04bda6efebe83e6e6442a6fbacd2e711d54c3c399735ea83b528b223`.
Signing certificate SHA256:
`a016d6414e064f87b9688ed85312b2f60bce8da751a6ab32b4c29efa9bf87142`.
The original Android debug signing key is not in this archive. Transfer that key
separately through a private channel before building updates for the existing
phone. A new machine's generated debug key will not update the installed app.
Do not work around signing errors by uninstalling/clearing unsynced phone data.
The existing 0.5.1 APK already supports the backend connection settings; deployment
does not require a mobile rebuild.

## Validation already completed

- Flutter analysis clean; 63 regular Flutter tests passed (live integration excluded).
- 44 backend/schema/integration tests passed using disposable PostgreSQL.
- A separate real Flutter two-device SQLite/HTTP/PostgreSQL integration passed.
- Docker image built from the pinned Python requirements.
- Compose started API, schema initializer and PostgreSQL with persistent volumes.
- HTTP device provisioning/authentication, site creation and voice archive passed.
- After API + PostgreSQL restart, identity/site/audio checks passed.
- Non-root API runtime and absence of embedded .env verified.
- Caddy config validated; public TLS/DNS has NOT been tested or configured.
- Provider output was stubbed/synthetic during tests. No successful live Gemini/
  Groq call or Tamil transcription quality is claimed.

See `deploy/VALIDATION.md`. The disposable test databases/containers are not part
of the transfer and must not be treated as production/customer data.

## First actions on the VPS

1. Inspect OS, CPU/RAM/free disk, user/permissions, Docker/Compose availability,
   existing containers/processes and listeners on 80/443/8000/5432. Read local
   AGENTS.md rules outside this project. Do not stop existing apps or modify the
   firewall/reverse proxy before determining the correct target and integration.
2. Extract into a NEW user-owned folder. Do not overwrite an existing deployment.
3. Verify `sha256sum -c TRANSFER_CHECKSUMS.sha256` from the project folder.
4. Ask for/establish the intended API hostname and securely available provider
   keys. Do not request secret values in chat. Reuse an existing reverse proxy
   if 80/443 are in use; the supplied Caddy profile is for available ports.
5. Follow `deploy/README.md`. `setup_env.py` creates mode-0600 `deploy/.env` once;
   do not overwrite an existing database password. Never print expanded Compose
   configuration containing secrets; use `docker compose config --quiet`.
6. Initialize server schema, provision a device token, enter HTTPS origin/token
   into the phone's API connection settings. Provider keys stay on the server.
7. Sync local site creation before AI requests. Review AI proposals before applying
   extracted inventory. Check Tamil audio/transcript, next questions and queues.
8. Verify backup/restore before treating pilot data as business-critical.

The user prefers practical Tamil/Tanglish instructions, action without repeated
confirmation for routine reversible work, and a check-in before a new major stage.

## Development dependencies and tests

Backend Python 3.12:

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.lock
.venv/bin/python -m unittest discover -s tests -v
```

The PostgreSQL tests intentionally skip without `SMARTIVA_TEST_DATABASE_URL`.
For full validation, supply a dedicated disposable database through that variable
and rerun. Never point it at a production/customer database. See `backend/SYNC.md`.
For the live two-device test, Flutter must be installed, then run
`.venv/bin/python tests/run_mobile_sync.py` with the disposable database setting.

Mobile toolchain last verified: Flutter 3.47.7 / Dart 3.13.5, FULL JDK 21 (including
javac), Android SDK platform/build tools 36, NDK 28.2.13676358 and CMake 3.22.1.
These SDKs and caches are not in the archive. Android local.properties, generated
plugin paths and iOS generated environment files must be recreated locally.
Use `flutter pub get`, `flutter analyze`, `flutter test`, then
`mobile/scripts/build_android_test.sh`. Linux can build Android; iOS needs macOS
and Xcode. The current native ARM filtering in app/build.gradle.kts deliberately
avoids advertising x86 JNI libraries without an x86 Flutter engine.

## Data and operational boundaries

Never delete/replace database volumes, clear the phone's storage, rotate device
identity behind unsynced data, log provider request bodies or publish customer
recordings. Chat messages/raw scans/unreviewed proposals remain local; canonical
reviewed inventory and sanitized voice metadata/archive sync. A public HTTPS
origin is not authentication: use per-device tokens and site grants.
