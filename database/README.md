# Smartiva FieldOps — schema v1

Apply `postgresql.sql` once to an empty PostgreSQL database. Apply `sqlite.sql` once when creating a device database. Later releases must use versioned migrations (Alembic on the server, drift/sqflite migrations on devices); these scripts are not upgrades. PostgreSQL SQL is compiled for PostgreSQL; SQLite SQL is executed in the tests. PostgreSQL runtime validation requires a provisioned database.

## Data model

`sites → floors → floors_and_zones → assets / cameras` stores the physical hierarchy. `site_contacts` belongs to a site. A site’s `building_floors` is obtained from `floors`; duplicating that array would cause drift. Missing floor/location details remain nullable where possible rather than being guessed.

Assets use numeric `channel_capacity`, `port_capacity`, and `poe_port_capacity` instead of ambiguous strings such as “64-ch”. Multiple `network_interfaces` store each NVR NIC's IP, MAC and purpose independently. `asset_connections` maps asset uplinks and UPS power feeds; `cameras.switch_id` maps camera attachment. Camera ports and vendor-specific UPS runtime/battery data may be stored in `extra` until a dedicated typed model is required. ISP circuits use asset_type `ISP` and JSON metadata (provider, circuit ID, plan).

Example: a 64-channel NVR has two interfaces, LAN1 (internet/uplink) and LAN2 (isolated cameras). Two ethernet connection rows connect it to the respective switches using `from_interface_id`. A site observation can contain `{"brand_counts":{"Dahua":27,"CP Plus":15},"reported_total":42}`. The probing engine computes 22 free channels from the reported total; it must label this as reported, not verified. It must not create 42 invented camera records. Discovery adds only identifiable cameras. Never assume a discovery failure means a camera was removed.

`observations` retains confirmed/reported aggregate facts and sanitized discovery or AI evidence, with provenance (`source`: manual, ai, discovery) and timestamps. JSON is JSONB on PostgreSQL and JSON text on SQLite. No JSON mutable tracking is configured: replace entire dictionaries in SQLAlchemy, or explicitly flag modifications.

## Offline sync contract (implemented in Step 5)

- Generate UUIDv4 strings on devices before inserting. Raw SQL/Flutter must supply IDs and UTC timestamps; Python defaults apply only to ORM inserts. Normalize timestamps to UTC on every boundary; SQLite has no native timezone enforcement. Normalize vendor channel numbers to one-based numbers.
- In one local transaction, save the record plus an outbox mutation with a stable `operation_id`, the last acknowledged `base_version` (0 for create), entity ID/type and a whitelisted payload. Keep only one inflight mutation per entity; subsequent edits wait or are coalesced before dispatch. Derive `sync_status` from the outbox; it is device-specific, not a shared site property.
- The server authenticates and authorizes every site request; UUIDs are not authorization. Process related creates in dependency order (site, floor, zone, asset, interface, camera, connection). Record-type allowlists prevent arbitrary table writes. Reject references to deleted parents and enforce asset roles (NVR/DVR versus switch), IP/MAC formats, channel <= recorder capacity, UUID format, and JSON schemas in API validation. Composite foreign keys enforce same-site ownership, not these business rules.
- Within one PostgreSQL transaction, take a transaction advisory lock for that site (including before initial site creation), check the idempotency receipt, compare `base_version`, apply the write, increment the entity version, update `updated_at`, increment the site revision, append a complete canonical snapshot/tombstone to `site_changes`, and save `sync_receipts`. All mutation paths including admin edits must use this transaction service. Version fields do not increment automatically. A duplicate operation returns its saved response only if device ID and request SHA-256 match. Changed payload under an existing operation ID is rejected. Site-level locking prevents commit-order gaps in pull cursors.
- A stale version returns a conflict and the current record; preserve both versions for technician resolution. Do not silently overwrite topology with stale scan/AI results. Mark the outbox row `conflict`; edits must produce a new operation ID after resolution.
- Pull `site_changes` ordered by per-site revision after the saved cursor, with a bounded page. Apply records and advance the cursor in one SQLite transaction. Pending local edits require conflict handling before replacing their local row. Tombstones use `deleted_at`; do not physically delete records during normal sync. Site/parent deletion must tombstone descendants within the same server transaction. Retain tombstones/change history until devices are acknowledged or require a full snapshot resync after a documented retention window.
- Claim outbox work with a lease and recover expired leases after crashes. Retry transient failures using exponential backoff with jitter. Permanent validation failures stop as `failed`; intermittent connectivity never discards evidence. Connectivity signals are hints; actual request success determines reachability.
- Audio upload uses a separate idempotent outbox operation, SHA-256 integrity verification, and a durable app-private file. Archival and transcription have independent queues; upload before syncing object identity/transcript metadata. Never delete the local audio until upload acknowledgement is committed. `local_file_ref` stays local and must be omitted from server payloads. Store no raw audio in JSON or SQLite blobs.

## Credentials and privacy

`credential_ref` points to Android Keystore/iOS Keychain-backed secure storage on-device or a backend secrets vault. References are environment-specific and must be excluded from generic sync payloads. If server-managed credentials are needed, use a separately authorized encrypted secret API. No plaintext username/password columns or credentials in scan evidence, logs, chat transcripts, URLs or sync payloads. Voice transcripts/contact information require access controls and a retention policy. Standard SQLite is not encryption; use OS data protection or a vetted SQLCipher integration when encrypted offline data is required.

## Generate and verify

From repository root:

```sh
python -m venv .venv
.venv/bin/pip install -r requirements-schema.txt
.venv/bin/python database/generate.py
.venv/bin/python -m unittest discover -s tests -v
```

SQLite must enable `PRAGMA foreign_keys=ON` on **every** connection (including Flutter); WAL is configured in the initial script. Configure a busy timeout in the application. PostgreSQL JSONB supports later query-specific GIN indexes; add these based on measured query patterns. Site-scoped indexes cover normal inventory lookup.

The v1 artifacts remain historical initial migrations. Step 5 adds `migrations/002_device_access.sql`; operational setup, real PostgreSQL tests and sync behavior are documented in [backend/SYNC.md](../backend/SYNC.md). Flutter applies its additive v3 migration on open.
