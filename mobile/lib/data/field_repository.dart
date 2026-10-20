import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/briefing.dart';
import '../domain/discovery.dart';

part 'discovery_import.dart';
part 'sync_repository.dart';

class FieldRepository {
  FieldRepository(this.db);
  final Database db;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void changed() => _changes.add(null);
  String _id() => const Uuid().v4();
  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<List<Json>> sites() => db.rawQuery('''SELECT s.*, f.reviewed_at,
    (SELECT count(*) FROM briefing_jobs j WHERE j.site_id=s.id AND j.state IN ('pending','inflight')) AS pending
    FROM sites s JOIN field_sessions f ON f.site_id=s.id
    WHERE s.deleted_at IS NULL ORDER BY f.updated_at DESC''');

  Future<String> createSite(String name) async {
    name = name.trim();
    if (name.isEmpty || name.length > 160) {
      throw const FormatException('Enter a site name (1–160 characters).');
    }
    final id = _id(), now = _now();
    await db.transaction((tx) async {
      await _save(tx, 'sites', id, id, {'name': name}, now);
      await tx.insert('field_sessions', {'site_id': id, 'updated_at': now});
      await _message(
        tx,
        id,
        'assistant',
        'Vanakkam! Floor-wise NVR, cameras, switches details sollunga. Type pannalaam, illa voice record pannalaam.',
        null,
      );
    });
    changed();
    return id;
  }

  Future<Json> session(String siteId) async => (await db.query(
    'field_sessions',
    where: 'site_id=?',
    whereArgs: [siteId],
  )).single;
  Future<List<Json>> messages(String siteId) => db.query(
    'chat_messages',
    where: 'site_id=?',
    whereArgs: [siteId],
    orderBy: 'sequence',
  );
  Future<List<Json>> jobs(String siteId) => db.query(
    'briefing_jobs',
    where: 'site_id=? AND state<>?',
    whereArgs: [siteId, 'done'],
    orderBy: 'sequence',
  );
  Future<Json?> context(String siteId) async {
    final row = await session(siteId);
    if (row['proposal'] != null) {
      return object(jsonDecode(row['proposal'] as String));
    }
    final site = (await db.query(
      'sites',
      where: 'id=?',
      whereArgs: [siteId],
    )).single;
    return {
      'site': {'name': site['name']},
    };
  }

  Future<void> _message(
    DatabaseExecutor tx,
    String site,
    String role,
    String text,
    String? job,
  ) => tx.insert('chat_messages', {
    'id': _id(),
    'site_id': site,
    'role': role,
    'text': text,
    'job_id': job,
    'created_at': _now(),
  });

  Future<void> queueText(String siteId, String text, String language) async {
    text = text.trim();
    if (text.isEmpty || text.length > 30000) {
      throw const FormatException('Enter 1–30,000 characters.');
    }
    final id = _id(), now = _now();
    await db.transaction((tx) async {
      await tx.insert('briefing_jobs', {
        'id': id,
        'site_id': siteId,
        'text': text,
        'language': language,
        'created_at': now,
      });
      await _message(tx, siteId, 'technician', text, id);
      await tx.update(
        'field_sessions',
        {'updated_at': now},
        where: 'site_id=?',
        whereArgs: [siteId],
      );
    });
    changed();
  }

  Future<void> beginRecording(
    String id,
    String siteId,
    String path,
    String language,
  ) async {
    final now = _now();
    await db.transaction((tx) async {
      await tx.insert('voice_notes', {
        'id': id,
        'site_id': siteId,
        'local_file_ref': path,
        'language': language,
        'created_at': now,
        'updated_at': now,
      });
      await tx.insert('recording_drafts', {
        'id': id,
        'site_id': siteId,
        'path': path,
        'language': language,
        'started_at': now,
      });
    });
    changed();
  }

  Future<List<Json>> recordingDrafts() => db.query('recording_drafts');

  Future<void> finishRecording(
    String id,
    String digest, {
    bool recovered = false,
  }) async {
    await db.transaction((tx) async {
      final drafts = await tx.query(
        'recording_drafts',
        where: 'id=?',
        whereArgs: [id],
      );
      if (drafts.isEmpty) return;
      final draft = drafts.single, job = _id(), now = _now();
      await tx.update(
        'voice_notes',
        {'sha256': digest, 'updated_at': now},
        where: 'id=?',
        whereArgs: [id],
      );
      await tx.insert('briefing_jobs', {
        'id': job,
        'site_id': draft['site_id'],
        'audio_path': draft['path'],
        'voice_id': id,
        'language': draft['language'],
        'created_at': now,
      });
      await _message(
        tx,
        draft['site_id'] as String,
        'technician',
        recovered
            ? 'Recovered interrupted voice note — audio may be incomplete.'
            : 'Voice briefing saved on this device.',
        job,
      );
      await tx.insert('voice_upload_jobs', {
        'voice_id': id,
        'site_id': draft['site_id'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.delete('recording_drafts', where: 'id=?', whereArgs: [id]);
      await tx.update(
        'field_sessions',
        {'updated_at': now},
        where: 'site_id=?',
        whereArgs: [draft['site_id']],
      );
    });
    changed();
  }

  Future<void> abandonRecording(String id) async {
    await db.transaction((tx) async {
      final drafts = await tx.query(
        'recording_drafts',
        where: 'id=?',
        whereArgs: [id],
      );
      if (drafts.isEmpty) return;
      await _message(
        tx,
        drafts.single['site_id'] as String,
        'system',
        'Recording could not be recovered. Please record it again.',
        null,
      );
      await tx.delete('recording_drafts', where: 'id=?', whereArgs: [id]);
      await tx.update(
        'voice_notes',
        {'processing_status': 'failed', 'updated_at': _now()},
        where: 'id=?',
        whereArgs: [id],
      );
    });
    changed();
  }

  Future<WorkItem?> claim({int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return db.transaction((tx) async {
      await tx.rawUpdate(
        "UPDATE briefing_jobs SET state='pending',lease_token=NULL WHERE state='inflight' AND lease_until_ms<=?",
        [now],
      );
      final candidates = await tx.rawQuery(
        '''SELECT j.* FROM briefing_jobs j
        WHERE j.state='pending' AND j.next_attempt_ms<=?
        AND NOT EXISTS (SELECT 1 FROM briefing_jobs older WHERE older.site_id=j.site_id
          AND older.sequence<j.sequence AND older.state<>'done')
        AND NOT EXISTS(SELECT 1 FROM sync_conflicts c WHERE c.site_id=j.site_id)
        AND (NOT EXISTS(SELECT 1 FROM sync_connection) OR EXISTS(SELECT 1 FROM sync_shadow s WHERE s.entity_type='sites' AND s.entity_id=j.site_id))
        ORDER BY j.sequence LIMIT 1''',
        [now],
      );
      if (candidates.isEmpty) return null;
      final session = (await tx.query(
        'field_sessions',
        where: 'site_id=?',
        whereArgs: [candidates.single['site_id']],
      )).single;
      final row = {
        ...candidates.single,
        'lease_token': _id(),
        'context_revision': session['context_revision'],
      };
      await tx.update(
        'briefing_jobs',
        {
          'state': 'inflight',
          'lease_token': row['lease_token'],
          'lease_until_ms': now + 180000,
          'context_revision': row['context_revision'],
        },
        where: 'id=?',
        whereArgs: [row['id']],
      );
      return WorkItem.fromRow(row);
    });
  }

  Future<void> complete(WorkItem work, BriefingResult result) async {
    await db.transaction((tx) async {
      final session = (await tx.query(
        'field_sessions',
        where: 'site_id=?',
        whereArgs: [work.siteId],
      )).single;
      if (session['context_revision'] != work.contextRevision) {
        await tx.update(
          'briefing_jobs',
          {
            'state': 'pending',
            'lease_token': null,
            'lease_until_ms': null,
            'next_attempt_ms': 0,
            'last_error':
                'Site inventory changed. Retrying with the latest details.',
          },
          where: "id=? AND state='inflight' AND lease_token=?",
          whereArgs: [work.id, work.lease],
        );
        return;
      }

      final count = await tx.update(
        'briefing_jobs',
        {
          'state': 'done',
          'lease_token': null,
          'lease_until_ms': null,
          'last_error': null,
        },
        where: "id=? AND state='inflight' AND lease_token=?",
        whereArgs: [work.id, work.lease],
      );
      if (count == 0) {
        return; // Another worker owns the lease: ignore stale replies.
      }
      await tx.update(
        'field_sessions',
        {
          'proposal': jsonEncode(result.proposal),
          'context_revision': work.contextRevision + 1,
          'result': jsonEncode(result.json),
          'reviewed_at': null,
          'updated_at': _now(),
        },
        where: 'site_id=?',
        whereArgs: [work.siteId],
      );
      if (work.voiceId != null) {
        await tx.update(
          'voice_notes',
          {
            'transcript': result.transcript,
            'processing_status': 'complete',
            'updated_at': _now(),
          },
          where: 'id=?',
          whereArgs: [work.voiceId],
        );
        await _queueVoiceMetadata(tx, work.voiceId!, work.siteId);
        await _message(
          tx,
          work.siteId,
          'technician',
          'Transcript: ${result.transcript}',
          work.id,
        );
      }
      await _message(tx, work.siteId, 'assistant', result.question, work.id);
    });
    changed();
  }

  Future<void> fail(
    WorkItem work,
    String code, {
    required bool retryable,
    required int delaySeconds,
  }) async {
    final failed = !retryable || work.attempts + 1 >= 8;
    await db.update(
      'briefing_jobs',
      {
        'state': failed ? 'failed' : 'pending',
        'attempts': work.attempts + 1,
        'next_attempt_ms':
            DateTime.now().millisecondsSinceEpoch + delaySeconds * 1000,
        'lease_token': null,
        'lease_until_ms': null,
        'last_error': code,
      },
      where: "id=? AND state='inflight' AND lease_token=?",
      whereArgs: [work.id, work.lease],
    );
    changed();
  }

  Future<void> retry(String id) async {
    await db.update(
      'briefing_jobs',
      {
        'state': 'pending',
        'attempts': 0,
        'next_attempt_ms': 0,
        'last_error': null,
      },
      where: "id=? AND state<>'inflight' AND state<>'done'",
      whereArgs: [id],
    );
    changed();
  }

  Future<void> skip(String id) async {
    await db.transaction((tx) async {
      final items = await tx.query(
        'briefing_jobs',
        where: "id=? AND state='failed'",
        whereArgs: [id],
      );
      if (items.isEmpty) return;
      await tx.update(
        'briefing_jobs',
        {'state': 'done', 'last_error': 'skipped_by_technician'},
        where: 'id=?',
        whereArgs: [id],
      );
      await _message(
        tx,
        items.single['site_id'] as String,
        'system',
        'Skipped AI processing for an earlier note. Original note is retained.',
        id,
      );
    });
    changed();
  }

  /// Apply only reviewed rows, never infer removals from a missing proposal row.
  Future<void> confirm(String siteId, String expectedResult) async {
    final result = BriefingResult.decode(expectedResult);
    if (result.warnings.isNotEmpty) {
      throw const FormatException(
        'Resolve the inventory warnings before saving.',
      );
    }
    await db.transaction((tx) async {
      if (await _siteConflicted(tx, siteId)) {
        throw const FormatException(
          'Resolve sync conflicts before confirming inventory.',
        );
      }
      final current = (await tx.query(
        'field_sessions',
        where: 'site_id=?',
        whereArgs: [siteId],
      )).single;
      if (current['reviewed_at'] != null &&
          current['result'] == expectedResult) {
        return;
      }
      final outstanding = await tx.query(
        'briefing_jobs',
        where: "site_id=? AND state<>'done'",
        whereArgs: [siteId],
        limit: 1,
      );
      if (current['result'] != expectedResult || outstanding.isNotEmpty) {
        throw const FormatException(
          'Finish pending briefings, then review the latest result.',
        );
      }
      final data = result.proposal, now = _now();
      final refs = <String, String>{};
      for (final entry in entityTables.entries) {
        for (final row in rows(data, entry.key)) {
          final ref = row['ref'] as String;
          final existing = await tx.query(
            'proposal_refs',
            where: 'site_id=? AND ref=?',
            whereArgs: [siteId, ref],
          );
          if (existing.isNotEmpty &&
              existing.single['entity_table'] != entry.value) {
            throw const FormatException(
              'An inventory reference changed type. Please correct the briefing.',
            );
          }
          refs[ref] = existing.isEmpty
              ? _id()
              : existing.single['entity_id'] as String;
          if (existing.isEmpty) {
            await tx.insert('proposal_refs', {
              'site_id': siteId,
              'ref': ref,
              'entity_table': entry.value,
              'entity_id': refs[ref],
            });
          }
        }
      }
      final site = object(data['site']);
      await _save(tx, 'sites', siteId, siteId, {
        for (final key in [
          'name',
          'gps_lat',
          'gps_lng',
          'address',
          'landmarks',
        ])
          if (site[key] != null) key: site[key],
      }, now);
      for (final entry in entityTables.entries) {
        for (final row in rows(data, entry.key)) {
          final values = <String, Object?>{};
          for (final key in _fields[entry.value]!) {
            if (!row.containsKey(key)) continue;
            final value = row[key];
            if (key.endsWith('_id') && value != null) {
              if (!refs.containsKey(value)) {
                throw const FormatException('Missing linked device or floor.');
              }
              values[key] = refs[value];
            } else {
              values[key] = value as Object?;
            }
          }
          await _save(tx, entry.value, refs[row['ref']]!, siteId, values, now);
        }
      }
      for (final entry in {
        'inventory_reports': 'nvr_id',
        'switch_reports': 'switch_id',
        'ups_reports': 'ups_id',
      }.entries) {
        for (final report in rows(data, entry.key)) {
          final assetId = refs[report[entry.value]];
          if (assetId == null) {
            throw const FormatException('Missing report asset.');
          }
          final observationRef = '${entry.key}:${report[entry.value]}';
          final previous = await tx.query(
            'proposal_refs',
            where: 'site_id=? AND ref=?',
            whereArgs: [siteId, observationRef],
          );
          final id = previous.isEmpty
              ? _id()
              : previous.single['entity_id'] as String;
          if (previous.isEmpty) {
            await tx.insert('proposal_refs', {
              'site_id': siteId,
              'ref': observationRef,
              'entity_table': 'observations',
              'entity_id': id,
            });
          }
          await _save(tx, 'observations', id, siteId, {
            'asset_id': assetId,
            'kind': entry.key,
            'payload': jsonEncode(report),
            'confirmed': 1,
            'observed_at': now,
          }, now);
        }
      }
      await tx.update(
        'field_sessions',
        {'reviewed_at': now},
        where: 'site_id=?',
        whereArgs: [siteId],
      );
      await _message(
        tx,
        siteId,
        'system',
        'Reviewed inventory saved on this device. Inventory sync is queued and will resume when connected.',
        null,
      );
    });
    changed();
  }

  Future<void> _save(
    DatabaseExecutor tx,
    String table,
    String id,
    String siteId,
    Json fields,
    String now,
  ) async {
    final existing = await tx.query(table, where: 'id=?', whereArgs: [id]);
    final old = existing.isEmpty ? null : existing.single;
    if ((fields['source'] ?? (table == 'sites' ? 'manual' : 'ai')) == 'ai') {
      // An unknown AI field is not an instruction to erase documented facts.
      fields = {
        for (final entry in fields.entries)
          if (entry.value != null) entry.key: entry.value,
      };
      if (fields['status'] == 'unknown' &&
          old?['status'] != null &&
          old?['status'] != 'unknown') {
        fields.remove('status');
      }
    }
    final row = <String, Object?>{
      ...?old,
      'id': id,
      if (table != 'sites') 'site_id': siteId,
      'created_at': old?['created_at'] ?? now,
      'updated_at': now,
      'version': old?['version'] ?? 1,
      'source': table == 'sites' ? 'manual' : 'ai',
      ...fields,
    };
    if (old == null) {
      await tx.insert(table, row);
    } else {
      await tx.update(table, row, where: 'id=?', whereArgs: [id]);
    }
    await _enqueueMutation(
      tx,
      table,
      id,
      siteId,
      row,
      old == null ? 0 : old['version'] as int,
    );
  }

  Future<void> close() async {
    await _changes.close();
    await db.close();
  }
}

const _fields = {
  'site_contacts': ['name', 'role', 'phone'],
  'floors': ['name', 'level'],
  'floors_and_zones': ['floor_id', 'zone_name'],
  'assets': [
    'zone_id',
    'asset_type',
    'brand',
    'model',
    'channel_capacity',
    'port_capacity',
    'poe_port_capacity',
    'serial_number',
    'installed_date',
    'notes',
  ],
  'network_interfaces': [
    'asset_id',
    'name',
    'purpose',
    'ip_address',
    'prefix_length',
    'mac_address',
  ],
  'cameras': [
    'nvr_id',
    'switch_id',
    'zone_id',
    'brand',
    'megapixel',
    'camera_type',
    'ip_address',
    'mac_address',
    'serial_number',
    'channel_no',
    'install_year',
    'status',
  ],
  'asset_connections': [
    'from_asset_id',
    'to_asset_id',
    'from_interface_id',
    'from_port',
    'to_port',
    'connection_type',
    'notes',
  ],
};

Json _syncFields(Json row) => {...row}
  ..remove('credential_ref')
  ..remove('local_file_ref');
