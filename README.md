# Smartiva FieldOps

Offline field operations and site knowledge memory for Smartiva Technologies LLP.

## Implemented foundations

1. **Database:** PostgreSQL + SQLite schemas, SQLAlchemy models, dual-NIC inventory/topology, local outbox and sync transaction design. See [database/README.md](database/README.md).
2. **AI briefing API:** FastAPI text/audio endpoint, Gemini/Groq adapters, Tamil/Tanglish prompt, validated proposals and deterministic engineering probes. See [backend/README.md](backend/README.md).
3. **Flutter field app:** site list, guided/continuous voice chat, durable SQLite/audio capture, ordered foreground AI retries, inventory review and atomic local/outbox saves. See [mobile/README.md](mobile/README.md).

4. **Network discovery/NVR bridge:** DHIP/SADP/ONVIF discovery, bounded Digest-auth CGI reads, persisted snapshots and reviewed camera imports. See [mobile/STEP4.md](mobile/STEP4.md) for supported formats and unverified hardware behavior.

5. **PostgreSQL offline sync:** scoped device tokens, atomic push/pull, conflict review, immutable retry receipts and durable audio archival. See [backend/SYNC.md](backend/SYNC.md) and [mobile/STEP5.md](mobile/STEP5.md).

6. **Android test APK:** signed internal debug APK for ARM32/ARM64, minimum Android 7.0, with verified packaging and a phone-test checklist. See [mobile/ANDROID_TESTING.md](mobile/ANDROID_TESTING.md).

## Pending milestones

Production Android signing/release, iOS builds and physical-device validation, user login/SSO and permission administration UI, admin/AMC dashboard, GPS/photo features, and hardware/field release validation. Background sync runs while the app is foregrounded. An internal Android test APK is available under `mobile/dist/`; physical-device acceptance is pending.

Pilot deployment: [deploy/README.md](deploy/README.md) contains the non-root Docker
image, PostgreSQL/audio volumes, HTTPS proxy, device provisioning and phone AI/sync
acceptance steps. Hosting and live provider credentials are configured separately.
