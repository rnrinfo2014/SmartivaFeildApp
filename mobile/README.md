# Smartiva FieldOps — Flutter field app (Steps 3–6)

Android/iOS source project with offline site capture, a guided chat, two-minute voice briefings, resumable AI processing, UDP discovery and a reviewed NVR inventory bridge. See [STEP4.md](STEP4.md) for device support and hardware validation limits. Tested with Flutter 3.47.7 / Dart 3.13.5. Native targets are Android API 24+ (Android 7.0+) and iOS 15+.

## Run

```sh
cd mobile
flutter pub get
flutter run
```

Install Android Studio/SDK and accept its licenses for Android. For iOS, use macOS/Xcode, select your development team in `ios/Runner.xcworkspace`, and configure signing. Flutter's generated project uses Swift Package Manager; let Flutter/Xcode resolve native packages. Android release signing still needs your company keystore; do not distribute the template's debug-signed release build.

The app works for local capture without provider keys or API settings. To enable AI processing:

1. Start the backend with PostgreSQL, a provisioned device token (see `../backend/SYNC.md`) and Gemini/Groq keys (see `../backend/README.md`). Groq is required for audio transcription even if Gemini structures the result.
2. Open the app's **API connection** settings. Enter the backend origin (no `/api` path) and device access token. Settings are stored together in platform secure storage; no token is compiled into the app or stored in SQLite.
3. Use HTTPS on devices. Android debug builds additionally allow local HTTP, e.g. `http://10.0.2.2:8000` for an emulator. Bind the backend to an interface reachable from your emulator/device. The legacy NVR adapter requires native local-HTTP allowance, but release API settings still enforce HTTPS. See STEP4.md for that device-adapter exception; use trusted HTTPS for the backend.
4. Create a site, type a briefing or tap the microphone. Tap **Continuous voice briefing** to record up to two minutes. Stop saves the voice file and queues the request. The first assistant message starts guided entry; subsequent AI questions use saved context.
5. Review the site with the checklist icon. Expand floors, zones, assets, interfaces, cameras, connectivity and observations. Correct errors through another chat/voice turn, then **Confirm & save on device**. Unresolved server warnings or pending turns block confirmation.

Step 5 uses per-device tokens with technician/site grants. Open **Sync & review** for failures and conflicts; see [STEP5.md](STEP5.md). The shared internal AI token is not a mobile sync credential.

## Offline behavior and crash recovery

- Site creation and text submission use SQLite transactions. Voice files use durable app-support storage, never temporary/cache storage. A recording draft is written before native recording starts; on stop, SHA-256 metadata, a voice job and its chat message are committed together.
- Capture needs no internet or on-device speech recognition. Tamil/Tanglish transcription runs remotely once a connection is available. Microphone permission is requested only when recording starts. The app saves/stops recording when backgrounded; it does not record in the background.
- App startup attempts recovery of interrupted recordings. Nonempty files are queued with a visible warning that audio may be incomplete. A process-killed M4A may be unplayable if the OS did not finalize its container; retaining the bytes cannot guarantee recoverability. Missing/empty files produce a visible request to record again. Unreadable files remain in the draft table for another recovery attempt.
- AI jobs survive restarts. A durable 180-second lease and token prevent stale replies from overwriting a newer claim. The request timeout is 115 seconds. Work is serialized by the foreground worker; same-site FIFO also holds at the database query layer. Later same-site turns wait for the earlier turn's context. Other sites are not blocked by a failed site's oldest note.
- Connectivity events trigger attempts but are not treated as proof of internet. The app also checks pending work every 15 seconds while active and on resume. Transient failures back off with jitter (approximately 5 seconds to 5 minutes); after eight failed attempts the job needs manual retry. Auth/validation/file failures need attention immediately. Retry retains the original note; explicit Skip stops its AI processing while preserving evidence.
- No OS background worker is included. When the app is suspended/terminated it cannot promise immediate upload; pending AI processing resumes when the app is reopened/foregrounded. A request already in flight can finish during a lifecycle transition if the OS allows it.
- AI replies and extracted proposals are saved with their job completion in one transaction. Files are retained after transcription; no automatic recording deletion/retention policy has been applied yet.

## Local database and review

`assets/domain_v1.sql` is the exact Step 1 SQLite initial schema. The app opens it with foreign keys enabled on every connection, WAL and a busy timeout. Device database version 1 added the following local tables; version 3 preserves these, adds the sync tables in STEP5.md, and includes version 2's the discovery tables/context revision fields described in STEP4.md:

| Local table | Purpose |
| --- | --- |
| `field_sessions` | Latest proposal/result and explicit review timestamp per site |
| `chat_messages` | Ordered, durable technician/assistant history |
| `briefing_jobs` | AI processing queue, attempts, retry schedule and leases |
| `proposal_refs` | Stable proposal ref → database UUID mapping |
| `recording_drafts` | Recoverable recording intent and private file path |

A review maps refs to UUIDs and writes site contacts, floors/zones, assets, both NVR NICs, camera/switch links, connectivity and confirmed typed observations. It never synthesizes individual cameras from aggregate counts or deletes records merely because an AI proposal omitted them. Applying a proposal and creating/coalescing untouched local outbox operations are atomic. A repeated confirmation is idempotent. Invalid foreign-key mappings roll back the whole save.

The server returns a full merged proposal each turn. Stable refs are essential: if the model changes an existing entity's ref, the app cannot automatically know it is the same physical device. The review step is mandatory; asset identity reconciliation with discovered serial/MAC data is part of the discovery/sync milestone. Step 5 supports server tombstones and concurrent-edit conflicts; there is no mobile deletion editor. Discovery matching is described in STEP4.md.

`sync_outbox` now dispatches reviewed inventory to PostgreSQL with durable receipts, dependency ordering, shadow versions and conflict review. Voice archival uses its own queue; AI completion and archival completion are separate. See [STEP5.md](STEP5.md).

SQLite and voice files are app-private, not SQLCipher-encrypted. Android app backup is disabled; iOS uses normal OS sandbox/data protection and device-backup policy. Secure storage protects the API token separately. Set company data retention, encrypted-at-rest requirements and managed-device policy before production deployment. UI input is saved when submitted; unsubmitted text in the composer is not a durable draft.

## Structure

```text
lib/
  main.dart                       startup and app lifecycle
  domain/briefing.dart             API result/job types
  data/database.dart               initial schema and local tables
  data/field_repository.dart       transactions, leases, review, outbox writes
  services/api_settings.dart       runtime secure connection settings
  services/briefing_api.dart       bounded text/multipart HTTP requests
  services/briefing_worker.dart    ordered retries and foreground scheduling
  services/voice_capture.dart      permission, AAC recording and recovery
  services/discovery/              UDP protocols, Digest CGI bridge and parsers
  data/discovery_import.dart       reviewed import, identity matching, AI context refresh
  ui/                             site list, chat, review and settings screens
```

`pubspec.lock` is retained for repeatable dependency resolution. For future schema changes, bump the device version and add tested `onUpgrade` migrations; do not recreate or overwrite users' databases. The bundled v1 SQL is a historical initial migration, not a file to update as new server migrations are introduced.

## Verify

```sh
flutter analyze
flutter test
```

Tests exercise real SQLite through `sqflite_common_ffi`: close/reopen persistence, FIFO, stale leases, retry/skip, voice metadata deduplication, atomic review mapping/rollback and stable inventory UUIDs. Mocked HTTP tests cover text/context/auth, multipart audio, errors and response/site validation. Worker tests verify context order and network retry preservation. A phone-size widget test opens a site and renders the guided/voice chat without microphone/network access.

An Android SDK/NDK and full JDK are now installed, and the ARM32/ARM64 internal debug APK has been compiled and signature/integrity/alignment verified. See [ANDROID_TESTING.md](ANDROID_TESTING.md) for installation and phone acceptance checks. There is no attached emulator or physical phone, macOS/Xcode, or live provider key; actual recording interruptions, native secure storage, real Tamil inference and phone-to-backend tests remain pending.

## Next milestones

- Step 4 source implementation is now available: Dahua/CP Plus DHIP, Hikvision SADP, ONVIF discovery, Digest-auth NVR bridge and conservative local inventory matching. Open **Auto-scan network**. Hardware/native build verification remains pending; see STEP4.md.
- Step 5 source implementation is available: authenticated mutations, archival uploads, PostgreSQL push/pull, conflict review and device cursors. OS background execution remains a future enhancement.
- GPS-assisted site selection, photo capture, AMC tracking, admin dashboard and field/device release validation follow their respective milestones.
