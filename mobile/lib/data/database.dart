import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<Database> openFieldDatabase({
  DatabaseFactory? factory,
  String? path,
}) async {
  final driver = factory ?? databaseFactory;
  final target =
      path ?? p.join(await driver.getDatabasesPath(), 'smartiva_fieldops.db');
  final domainSql = await rootBundle.loadString('assets/domain_v1.sql');
  return driver.openDatabase(
    target,
    options: OpenDatabaseOptions(
      version: 3,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
        // This assignment returns a row. Android's SQLiteDatabase.execSQL
        // (used by execute) rejects it; FFI SQLite silently accepts it.
        await db.rawQuery('PRAGMA busy_timeout=5000');
        await db.rawQuery('PRAGMA journal_mode=WAL');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _discoveryMigration(db);
        if (oldVersion < 3) await _syncMigration(db);
      },
      onCreate: (db, version) async {
        // The generated domain schema has no semicolons inside SQL literals.
        for (final sql
            in domainSql
                .replaceAll(RegExp(r'^--.*$', multiLine: true), '')
                .split(';')) {
          if (sql.trim().isEmpty || sql.trim().startsWith('PRAGMA')) continue;
          // Strip the generated comment before checking PRAGMA in the first block.
          final clean = sql
              .replaceAll(RegExp(r'^--.*$', multiLine: true), '')
              .trim();
          if (clean.isNotEmpty && !clean.startsWith('PRAGMA')) {
            await db.execute(clean);
          }
        }
        await db.execute('''CREATE TABLE field_sessions (
        site_id TEXT PRIMARY KEY REFERENCES sites(id),
        proposal TEXT, result TEXT, reviewed_at TEXT, updated_at TEXT NOT NULL
      )''');
        await db.execute('''CREATE TABLE chat_messages (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE, site_id TEXT NOT NULL REFERENCES sites(id),
        role TEXT NOT NULL CHECK(role IN ('technician','assistant','system')),
        text TEXT NOT NULL, job_id TEXT, created_at TEXT NOT NULL
      )''');
        await db.execute('''CREATE TABLE briefing_jobs (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
        site_id TEXT NOT NULL REFERENCES sites(id), text TEXT, audio_path TEXT,
        voice_id TEXT REFERENCES voice_notes(id), language TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending'
          CHECK(state IN ('pending','inflight','failed','done')),
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_ms INTEGER NOT NULL DEFAULT 0, lease_until_ms INTEGER,
        lease_token TEXT, last_error TEXT, created_at TEXT NOT NULL,
        CHECK((text IS NULL) <> (audio_path IS NULL))
      )''');
        await db.execute(
          'CREATE INDEX ix_briefing_work ON briefing_jobs(state,next_attempt_ms,sequence)',
        );
        await db.execute('''CREATE TABLE proposal_refs (
        site_id TEXT NOT NULL REFERENCES sites(id), ref TEXT NOT NULL,
        entity_table TEXT NOT NULL, entity_id TEXT NOT NULL,
        PRIMARY KEY(site_id,ref)
      )''');
        await db.execute('''CREATE TABLE recording_drafts (
        id TEXT PRIMARY KEY REFERENCES voice_notes(id), site_id TEXT NOT NULL,
        path TEXT NOT NULL, language TEXT NOT NULL, started_at TEXT NOT NULL
      )''');
        await _discoveryMigration(db);
        await _syncMigration(db);
      },
    ),
  );
}

Future<void> _discoveryMigration(DatabaseExecutor db) async {
  await db.execute(
    'ALTER TABLE field_sessions ADD COLUMN context_revision INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute(
    'ALTER TABLE briefing_jobs ADD COLUMN context_revision INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute("""CREATE TABLE network_scans (
    id TEXT PRIMARY KEY, site_id TEXT NOT NULL REFERENCES sites(id),
    observed_at TEXT NOT NULL, payload TEXT NOT NULL)""");
  await db.execute("""CREATE TABLE nvr_snapshots (
    id TEXT PRIMARY KEY, site_id TEXT NOT NULL REFERENCES sites(id),
    observed_at TEXT NOT NULL, payload TEXT NOT NULL, credential_ref TEXT,
    imported_asset_id TEXT,
    FOREIGN KEY(site_id,imported_asset_id) REFERENCES assets(site_id,id))""");
  await db.execute("""CREATE TABLE discovery_bindings (
    site_id TEXT NOT NULL, nvr_id TEXT NOT NULL, remote_slot INTEGER NOT NULL,
    camera_id TEXT NOT NULL, PRIMARY KEY(site_id,nvr_id,remote_slot),
    FOREIGN KEY(site_id,nvr_id) REFERENCES assets(site_id,id),
    FOREIGN KEY(site_id,camera_id) REFERENCES cameras(site_id,id))""");
}

Future<void> _syncMigration(DatabaseExecutor db) async {
  await db.execute('ALTER TABLE sync_outbox ADD COLUMN depends_on TEXT');
  await db.execute('ALTER TABLE sync_outbox ADD COLUMN lease_token TEXT');
  await db.execute("""CREATE TABLE sync_shadow (
    entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, version INTEGER NOT NULL,
    payload TEXT NOT NULL, PRIMARY KEY(entity_type,entity_id))""");
  await db.execute("""CREATE TABLE sync_conflicts (
    entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, site_id TEXT NOT NULL,
    local_payload TEXT NOT NULL, remote_payload TEXT, reason TEXT NOT NULL,
    PRIMARY KEY(entity_type,entity_id))""");
  await db.execute(
    """CREATE TABLE sync_resolutions (
    id TEXT PRIMARY KEY, site_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
    local_payload TEXT NOT NULL, remote_payload TEXT, decision TEXT NOT NULL, created_at TEXT NOT NULL)""",
  );
  await db.execute("""CREATE TABLE sync_connection (
    id INTEGER PRIMARY KEY CHECK(id=1), origin TEXT NOT NULL, device_id TEXT NOT NULL,
    technician_id TEXT NOT NULL, last_error TEXT, last_success_at TEXT)""");
  await db.execute("""CREATE TABLE voice_upload_jobs (
    voice_id TEXT PRIMARY KEY REFERENCES voice_notes(id), site_id TEXT NOT NULL REFERENCES sites(id),
    state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_ms INTEGER NOT NULL DEFAULT 0, lease_until_ms INTEGER, lease_token TEXT,
    last_error TEXT)""");
  await db.execute(
    """INSERT INTO voice_upload_jobs(voice_id,site_id)
    SELECT id,site_id FROM voice_notes WHERE deleted_at IS NULL AND sha256 IS NOT NULL AND local_file_ref IS NOT NULL""",
  );
}
