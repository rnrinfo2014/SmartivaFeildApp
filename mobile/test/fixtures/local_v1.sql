-- Historical Step 3 local tables; retained to verify the v1 -> v2 upgrade.
CREATE TABLE field_sessions (
 site_id TEXT PRIMARY KEY REFERENCES sites(id), proposal TEXT, result TEXT,
 reviewed_at TEXT, updated_at TEXT NOT NULL
);
CREATE TABLE chat_messages (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
 site_id TEXT NOT NULL REFERENCES sites(id),
 role TEXT NOT NULL CHECK(role IN ('technician','assistant','system')),
 text TEXT NOT NULL, job_id TEXT, created_at TEXT NOT NULL
);
CREATE TABLE briefing_jobs (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
 site_id TEXT NOT NULL REFERENCES sites(id), text TEXT, audio_path TEXT,
 voice_id TEXT REFERENCES voice_notes(id), language TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','inflight','failed','done')),
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt_ms INTEGER NOT NULL DEFAULT 0,
 lease_until_ms INTEGER, lease_token TEXT, last_error TEXT, created_at TEXT NOT NULL,
 CHECK((text IS NULL) <> (audio_path IS NULL))
);
CREATE INDEX ix_briefing_work ON briefing_jobs(state,next_attempt_ms,sequence);
CREATE TABLE proposal_refs (
 site_id TEXT NOT NULL REFERENCES sites(id), ref TEXT NOT NULL,
 entity_table TEXT NOT NULL, entity_id TEXT NOT NULL, PRIMARY KEY(site_id,ref)
);
CREATE TABLE recording_drafts (
 id TEXT PRIMARY KEY REFERENCES voice_notes(id), site_id TEXT NOT NULL,
 path TEXT NOT NULL, language TEXT NOT NULL, started_at TEXT NOT NULL
);
