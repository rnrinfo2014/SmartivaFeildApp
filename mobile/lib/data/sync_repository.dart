part of 'field_repository.dart';

const syncTables = [
  'sites',
  'site_contacts',
  'floors',
  'floors_and_zones',
  'assets',
  'network_interfaces',
  'cameras',
  'asset_connections',
  'observations',
  'voice_notes',
];
const syncReferences = {
  'floors_and_zones': {'floor_id': 'floors'},
  'assets': {'zone_id': 'floors_and_zones'},
  'network_interfaces': {'asset_id': 'assets'},
  'cameras': {
    'nvr_id': 'assets',
    'switch_id': 'assets',
    'zone_id': 'floors_and_zones',
  },
  'asset_connections': {
    'from_asset_id': 'assets',
    'to_asset_id': 'assets',
    'from_interface_id': 'network_interfaces',
  },
  'observations': {'asset_id': 'assets'},
};
Json wireRecord(Json row) {
  final result = _syncFields(row);
  for (final key in ['extra', 'payload']) {
    if (result[key] is String) result[key] = jsonDecode(result[key] as String);
  }
  if (result.containsKey('confirmed')) {
    result['confirmed'] =
        result['confirmed'] == 1 || result['confirmed'] == true;
  }
  return result;
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_ordered(a)) == jsonEncode(_ordered(b));
Object? _ordered(Object? value) => value is Map
    ? {
        for (final key in value.keys.map((e) => e.toString()).toList()..sort())
          key: _ordered(value[key]),
      }
    : value is List
    ? value.map(_ordered).toList()
    : value;
Json _contentDiff(Json old, Json current) => {
  for (final e in current.entries)
    if (!{
          'id',
          'site_id',
          'version',
          'created_at',
          'updated_at',
        }.contains(e.key) &&
        !_same(old[e.key], e.value))
      e.key: e.value,
};
Future<bool> _siteConflicted(DatabaseExecutor tx, String site) async =>
    (await tx.query(
      'sync_conflicts',
      where: 'site_id=?',
      whereArgs: [site],
      limit: 1,
    )).isNotEmpty;

Future<void> _enqueueMutation(
  DatabaseExecutor tx,
  String table,
  String id,
  String site,
  Json row,
  int fallbackVersion,
) async {
  final operations = await tx.rawQuery(
    'SELECT * FROM sync_outbox WHERE entity_type=? AND entity_id=? ORDER BY rowid',
    [table, id],
  );
  final payload = jsonEncode(wireRecord(row));
  if (operations.isNotEmpty &&
      operations.last['status'] == 'pending' &&
      operations.last['attempts'] == 0) {
    await tx.update(
      'sync_outbox',
      {'payload': payload},
      where: 'operation_id=?',
      whereArgs: [operations.last['operation_id']],
    );
    return;
  }
  final shadow = await tx.query(
    'sync_shadow',
    where: 'entity_type=? AND entity_id=?',
    whereArgs: [table, id],
  );
  final base = shadow.isEmpty
      ? fallbackVersion
      : shadow.single['version'] as int;
  await tx.insert('sync_outbox', {
    'operation_id': const Uuid().v4(),
    'site_id': site,
    'entity_type': table,
    'entity_id': id,
    'operation': row['deleted_at'] != null
        ? 'delete'
        : base == 0
        ? 'create'
        : 'update',
    'base_version': base,
    'payload': payload,
    'depends_on': operations.isEmpty ? null : operations.last['operation_id'],
    'created_at': DateTime.now().toUtc().toIso8601String(),
  });
}

Future<void> _queueVoiceMetadata(
  DatabaseExecutor tx,
  String voiceId,
  String site,
) async {
  final voice = (await tx.query(
    'voice_notes',
    where: 'id=?',
    whereArgs: [voiceId],
  )).single;
  if (voice['object_key'] != null && voice['transcript'] != null) {
    await _enqueueMutation(
      tx,
      'voice_notes',
      voiceId,
      site,
      voice,
      voice['version'] as int,
    );
  }
}

extension InventorySync on FieldRepository {
  Future<void> bindSync(String origin, Json identity) async {
    await db.transaction((tx) async {
      final stored = await tx.query('sync_connection');
      final row = {
        'id': 1,
        'origin': origin,
        'device_id': identity['device_id'],
        'technician_id': identity['technician_id'],
      };
      if (stored.isNotEmpty &&
          (stored.single['origin'] != origin ||
              stored.single['device_id'] != identity['device_id'] ||
              stored.single['technician_id'] != identity['technician_id'])) {
        throw const FormatException(
          'This local database belongs to another server/device account. Use its original connection; switching profiles requires a separate installation.',
        );
      }
      if (stored.isEmpty) await tx.insert('sync_connection', row);
    });
  }

  Future<void> syncStatus(String? error, {bool success = false}) async {
    await db.update('sync_connection', {
      'last_error': error,
      if (success) 'last_success_at': _now(),
    }, where: 'id=1');
    changed();
  }

  Future<List<Json>> conflicts() => db.query('sync_conflicts');
  Future<List<Json>> pendingInventory() =>
      db.rawQuery('SELECT * FROM sync_outbox ORDER BY rowid');

  Future<Json?> claimMutation() async {
    final now = _now();
    return db.transaction((tx) async {
      await tx.rawUpdate(
        "UPDATE sync_outbox SET status='pending',lease_token=NULL WHERE status='inflight' AND julianday(lease_until)<=julianday(?)",
        [now],
      );
      final candidates = await tx.rawQuery(
        '''SELECT o.* FROM sync_outbox o WHERE o.status='pending'
        AND (o.next_attempt_at IS NULL OR julianday(o.next_attempt_at)<=julianday(?))
        AND NOT EXISTS(SELECT 1 FROM sync_outbox p WHERE p.operation_id=o.depends_on)
        AND NOT EXISTS(SELECT 1 FROM sync_conflicts c WHERE c.site_id=o.site_id)
        ORDER BY CASE o.entity_type WHEN 'sites' THEN 0 WHEN 'site_contacts' THEN 1 WHEN 'floors' THEN 2
        WHEN 'floors_and_zones' THEN 3 WHEN 'assets' THEN 4 WHEN 'network_interfaces' THEN 5 WHEN 'cameras' THEN 6
        WHEN 'asset_connections' THEN 7 WHEN 'observations' THEN 8 ELSE 9 END,o.rowid''',
        [now],
      );
      for (final row in candidates) {
        final table = row['entity_type'] as String,
            site = row['site_id'] as String;
        final payload = wireRecord(
          object(jsonDecode(row['payload'] as String)),
        );
        var blocked = false;
        final parents = {'site_id': 'sites', ...?syncReferences[table]};
        for (final e in parents.entries) {
          final parent = e.key == 'site_id' ? site : payload[e.key];
          if (parent == null || (table == 'sites' && e.key == 'site_id')) {
            continue;
          }
          if ((await tx.query(
            'sync_outbox',
            where: "entity_type=? AND entity_id=? AND operation='create'",
            whereArgs: [e.value, parent],
          )).isNotEmpty) {
            blocked = true;
            break;
          }
        }
        if (blocked) continue;
        final claimed = {
          ...row,
          'lease_token': _id(),
          'attempts': (row['attempts'] as int) + 1,
        };
        await tx.update(
          'sync_outbox',
          {
            'status': 'inflight',
            'attempts': claimed['attempts'],
            'lease_token': claimed['lease_token'],
            'lease_until': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 3))
                .toIso8601String(),
          },
          where: 'operation_id=?',
          whereArgs: [row['operation_id']],
        );
        return claimed;
      }
      return null;
    });
  }

  Future<void> acknowledgeMutation(Json work, Json remote) async {
    await db.transaction((tx) async {
      final held = await tx.query(
        'sync_outbox',
        where: "operation_id=? AND lease_token=? AND status='inflight'",
        whereArgs: [work['operation_id'], work['lease_token']],
      );
      if (held.isEmpty) return;
      final table = work['entity_type'] as String,
          id = work['entity_id'] as String;
      _checkRecord(table, id, work['site_id'] as String, remote);
      await _shadow(tx, table, remote);
      final next = await tx.rawQuery(
        'SELECT * FROM sync_outbox WHERE entity_type=? AND entity_id=? AND operation_id<>? ORDER BY rowid',
        [table, id, work['operation_id']],
      );
      Json display = remote;
      if (next.isNotEmpty) {
        if (remote['deleted_at'] != null) {
          await _conflict(
            tx,
            table,
            id,
            work['site_id'] as String,
            remote,
            'Server removed an item with local edits.',
          );
          return;
        }
        final local = wireRecord(
          object(jsonDecode(next.last['payload'] as String)),
        );
        display = {
          ...remote,
          ..._contentDiff(
            wireRecord(object(jsonDecode(work['payload'] as String))),
            local,
          ),
        };
        for (final pending in next) {
          if (pending['attempts'] != 0) {
            throw const FormatException(
              'An unacknowledged edit must be resolved first.',
            );
          }
          await tx.delete(
            'sync_outbox',
            where: 'operation_id=?',
            whereArgs: [pending['operation_id']],
          );
        }
        await tx.insert('sync_outbox', {
          'operation_id': _id(),
          'site_id': work['site_id'],
          'entity_type': table,
          'entity_id': id,
          'operation': display['deleted_at'] == null ? 'update' : 'delete',
          'base_version': remote['version'],
          'payload': jsonEncode(display),
          'created_at': _now(),
        });
      }
      await _applyRecord(tx, table, display);
      await tx.delete(
        'sync_outbox',
        where: 'operation_id=?',
        whereArgs: [work['operation_id']],
      );
    });
    changed();
  }

  Future<void> failMutation(
    Json work,
    String reason, {
    bool retryable = true,
    Json? remote,
    bool conflict = false,
  }) async {
    await db.transaction((tx) async {
      final held = await tx.query(
        'sync_outbox',
        where: 'operation_id=? AND lease_token=?',
        whereArgs: [work['operation_id'], work['lease_token']],
      );
      if (held.isEmpty) return;
      if (conflict) {
        await _conflict(
          tx,
          work['entity_type'] as String,
          work['entity_id'] as String,
          work['site_id'] as String,
          remote,
          reason,
        );
        return;
      }
      await tx.update(
        'sync_outbox',
        {
          'status': retryable && (work['attempts'] as int) < 8
              ? 'pending'
              : 'failed',
          'lease_token': null,
          'lease_until': null,
          'last_error': reason,
          'next_attempt_at': DateTime.now()
              .toUtc()
              .add(Duration(seconds: _delay(work['attempts'] as int)))
              .toIso8601String(),
        },
        where: 'operation_id=?',
        whereArgs: [work['operation_id']],
      );
    });
    changed();
  }

  Future<bool> applyPage(String site, Json page) async {
    final result = await db.transaction((tx) async {
      final changes = rows(page, 'changes');
      final sessionRows = await tx.query(
        'field_sessions',
        where: 'site_id=?',
        whereArgs: [site],
      );
      // Never replace a technician's unreviewed AI proposal during a pull.
      if (sessionRows.isNotEmpty &&
          sessionRows.single['result'] != null &&
          sessionRows.single['reviewed_at'] == null) {
        return false;
      }
      for (final change in changes) {
        final table = change['entity_type'] as String,
            record = object(change['record']);
        _checkRecord(table, record['id'] as String, site, record);
        final shadow = await tx.query(
          'sync_shadow',
          where: 'entity_type=? AND entity_id=?',
          whereArgs: [table, record['id']],
        );
        if (shadow.isNotEmpty &&
            (shadow.single['version'] as int) >= (record['version'] as int)) {
          continue;
        }
        final pending = await tx.query(
          'sync_outbox',
          where: 'entity_type=? AND entity_id=?',
          whereArgs: [table, record['id']],
        );
        if (pending.any(
          (p) =>
              p['attempts'] != 0 &&
              ['pending', 'inflight'].contains(p['status']),
        )) {
          return false;
        }
      }
      var touched = false;
      for (final change in changes) {
        final table = change['entity_type'] as String,
            record = object(change['record']),
            id = record['id'] as String;
        final shadow = await tx.query(
          'sync_shadow',
          where: 'entity_type=? AND entity_id=?',
          whereArgs: [table, id],
        );
        if (shadow.isNotEmpty &&
            (shadow.single['version'] as int) >= (record['version'] as int)) {
          continue;
        }
        final pending = await tx.query(
          'sync_outbox',
          where: 'entity_type=? AND entity_id=?',
          whereArgs: [table, id],
        );
        final descendantRisk =
            record['deleted_at'] != null &&
            ['sites', 'floors', 'floors_and_zones', 'assets'].contains(table) &&
            (await tx.query(
              'sync_outbox',
              where: 'site_id=?',
              whereArgs: [site],
              limit: 1,
            )).isNotEmpty;
        if (pending.isNotEmpty ||
            descendantRisk ||
            (await tx.query(
              'sync_conflicts',
              where: 'entity_type=? AND entity_id=?',
              whereArgs: [table, id],
            )).isNotEmpty) {
          await _conflict(
            tx,
            table,
            id,
            site,
            record,
            'Server and device both changed this inventory.',
          );
        } else {
          await _applyRecord(tx, table, record);
          await _shadow(tx, table, record);
          touched = true;
        }
      }
      final existing = await tx.query(
        'sync_cursors',
        where: 'site_id=?',
        whereArgs: [site],
      );
      final cursor = {
        'site_id': site,
        'server_cursor': '${page['cursor']}',
        'last_synced_at': _now(),
      };
      if (existing.isEmpty) {
        await tx.insert('sync_cursors', cursor);
      } else {
        await tx.update(
          'sync_cursors',
          cursor,
          where: 'site_id=?',
          whereArgs: [site],
        );
      }
      if (touched && !await _siteConflicted(tx, site)) {
        await _refreshContext(tx, site);
      }
      return true;
    });
    changed();
    return result;
  }

  Future<void> resolveConflict(
    String table,
    String id, {
    required bool keepLocal,
  }) async {
    await db.transaction((tx) async {
      final conflict = (await tx.query(
        'sync_conflicts',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [table, id],
      )).single;
      final remote = conflict['remote_payload'] == null
          ? null
          : object(jsonDecode(conflict['remote_payload'] as String));
      final site = conflict['site_id'] as String;
      if ((await tx.query(
        'sync_outbox',
        where: "entity_type=? AND entity_id=? AND status='inflight'",
        whereArgs: [table, id],
      )).isNotEmpty) {
        throw const FormatException('Wait for the current upload to finish.');
      }
      if (keepLocal && remote?['deleted_at'] != null) {
        throw const FormatException(
          'Removed server records cannot be restored automatically. Keep a local audit copy and create a replacement explicitly.',
        );
      }
      await _audit(tx, conflict, keepLocal ? 'keep_local' : 'use_server');
      await tx.delete(
        'sync_outbox',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [table, id],
      );
      await tx.delete(
        'sync_conflicts',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [table, id],
      );
      if (keepLocal) {
        final local = object(jsonDecode(conflict['local_payload'] as String));
        if (remote != null) await _shadow(tx, table, remote);
        await tx.insert('sync_outbox', {
          'operation_id': _id(),
          'site_id': site,
          'entity_type': table,
          'entity_id': id,
          'operation': remote == null
              ? 'create'
              : local['deleted_at'] == null
              ? 'update'
              : 'delete',
          'base_version': remote?['version'] ?? 0,
          'payload': jsonEncode({...local, 'version': remote?['version'] ?? 1}),
          'created_at': _now(),
        });
      } else if (remote == null || remote['deleted_at'] != null) {
        await _retireLocalTree(tx, site, table, id);
        if (remote != null) {
          await _applyRecord(tx, table, remote);
          await _shadow(tx, table, remote);
        }
      } else {
        await _applyRecord(tx, table, remote);
        await _shadow(tx, table, remote);
      }
      if (!await _siteConflicted(tx, site)) await _refreshContext(tx, site);
    });
    changed();
  }

  Future<void> retryLatest(String table, String id) async {
    await db.transaction((tx) async {
      if (!syncTables.contains(table)) {
        throw const FormatException('Unsupported entity.');
      }
      final pending = await tx.query(
        'sync_outbox',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [table, id],
      );
      if (pending.isEmpty) return;
      if (pending.any((p) => p['status'] == 'inflight')) {
        throw const FormatException('Wait for the current upload to finish.');
      }
      if (await _siteConflicted(tx, pending.first['site_id'] as String)) {
        throw const FormatException('Resolve conflicts before retrying.');
      }
      // Replay the original immutable request: a lost acknowledgement may already
      // have committed on the server. Never mint a replacement operation here.
      await tx.update(
        'sync_outbox',
        {
          'status': 'pending',
          'attempts': 1,
          'next_attempt_at': null,
          'lease_token': null,
          'lease_until': null,
          'last_error': null,
        },
        where: 'operation_id=?',
        whereArgs: [pending.first['operation_id']],
      );
    });
    changed();
  }

  Future<Json?> claimVoiceUpload() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((tx) async {
      await tx.rawUpdate(
        "UPDATE voice_upload_jobs SET state='pending',lease_token=NULL WHERE state='inflight' AND lease_until_ms<=?",
        [now],
      );
      final work = await tx.rawQuery(
        '''SELECT j.*,v.local_file_ref,v.sha256,v.language FROM voice_upload_jobs j JOIN voice_notes v ON v.id=j.voice_id
        JOIN sync_shadow s ON s.entity_type='sites' AND s.entity_id=j.site_id
        WHERE j.state='pending' AND j.next_attempt_ms<=? AND v.deleted_at IS NULL
        ORDER BY j.rowid LIMIT 1''',
        [now],
      );
      if (work.isEmpty) return null;
      final row = {
        ...work.single,
        'lease_token': _id(),
        'attempts': (work.single['attempts'] as int) + 1,
      };
      await tx.update(
        'voice_upload_jobs',
        {
          'state': 'inflight',
          'lease_token': row['lease_token'],
          'attempts': row['attempts'],
          'lease_until_ms': now + 180000,
        },
        where: 'voice_id=?',
        whereArgs: [row['voice_id']],
      );
      return row;
    });
  }

  Future<void> acknowledgeVoice(Json work, Json remote) async {
    await db.transaction((tx) async {
      final held = await tx.query(
        'voice_upload_jobs',
        where: 'voice_id=? AND lease_token=?',
        whereArgs: [work['voice_id'], work['lease_token']],
      );
      if (held.isEmpty) return;
      _checkRecord(
        'voice_notes',
        work['voice_id'] as String,
        work['site_id'] as String,
        remote,
      );
      final local = (await tx.query(
        'voice_notes',
        where: 'id=?',
        whereArgs: [work['voice_id']],
      )).single;
      await _shadow(tx, 'voice_notes', remote);
      await _applyRecord(tx, 'voice_notes', {
        ...remote,
        if (local['transcript'] != null) 'transcript': local['transcript'],
        if (local['transcript'] != null) 'processing_status': 'complete',
      });
      await tx.update(
        'voice_upload_jobs',
        {'state': 'done', 'lease_token': null, 'last_error': null},
        where: 'voice_id=?',
        whereArgs: [work['voice_id']],
      );
      await _queueVoiceMetadata(
        tx,
        work['voice_id'] as String,
        work['site_id'] as String,
      );
    });
    changed();
  }

  Future<void> failVoiceUpload(
    Json work,
    String error, {
    bool retryable = true,
  }) async {
    await db.update(
      'voice_upload_jobs',
      {
        'state': retryable && (work['attempts'] as int) < 8
            ? 'pending'
            : 'failed',
        'lease_token': null,
        'next_attempt_ms':
            DateTime.now().millisecondsSinceEpoch +
            _delay(work['attempts'] as int) * 1000,
        'last_error': error,
      },
      where: 'voice_id=? AND lease_token=?',
      whereArgs: [work['voice_id'], work['lease_token']],
    );
    changed();
  }
}

int _delay(int attempts) =>
    (5 * (1 << (attempts > 6 ? 6 : attempts))).clamp(5, 300) +
    DateTime.now().millisecond % 5;
void _checkRecord(String table, String id, String site, Json row) {
  if (!syncTables.contains(table) ||
      row['id'] != id ||
      (table == 'sites' ? row['id'] : row['site_id']) != site ||
      row['version'] is! int) {
    throw const FormatException('Incompatible server inventory response.');
  }
}

Future<void> _shadow(DatabaseExecutor tx, String table, Json row) =>
    tx.insert('sync_shadow', {
      'entity_type': table,
      'entity_id': row['id'],
      'version': row['version'],
      'payload': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
Future<void> _applyRecord(DatabaseExecutor tx, String table, Json wire) async {
  final old = await tx.query(table, where: 'id=?', whereArgs: [wire['id']]);
  final row = <String, dynamic>{...wire};
  for (final key in ['extra', 'payload']) {
    if (row[key] is Map || row[key] is List) row[key] = jsonEncode(row[key]);
  }
  if (row['confirmed'] is bool) {
    row['confirmed'] = row['confirmed'] == true ? 1 : 0;
  }
  for (final key in ['credential_ref', 'local_file_ref']) {
    if (old.isNotEmpty && old.single.containsKey(key)) {
      row[key] = old.single[key];
    }
  }
  if (old.isEmpty) {
    await tx.insert(table, row);
  } else {
    await tx.update(table, row, where: 'id=?', whereArgs: [row['id']]);
  }
  if (table == 'voice_notes' && row['deleted_at'] != null) {
    await tx.update(
      'voice_upload_jobs',
      {
        'state': 'retired',
        'lease_token': null,
        'last_error': 'Server removed this voice record; local file retained.',
      },
      where: 'voice_id=?',
      whereArgs: [row['id']],
    );
  }
  if (table == 'sites' &&
      (await tx.query(
        'field_sessions',
        where: 'site_id=?',
        whereArgs: [row['id']],
      )).isEmpty) {
    await tx.insert('field_sessions', {
      'site_id': row['id'],
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}

Future<void> _conflict(
  DatabaseExecutor tx,
  String table,
  String id,
  String site,
  Json? remote,
  String reason,
) async {
  final local = await tx.query(table, where: 'id=?', whereArgs: [id]);
  if (local.isEmpty) {
    throw const FormatException('Conflicting local record is missing.');
  }
  await tx.insert('sync_conflicts', {
    'entity_type': table,
    'entity_id': id,
    'site_id': site,
    'local_payload': jsonEncode(wireRecord(local.single)),
    'remote_payload': remote == null ? null : jsonEncode(remote),
    'reason': reason,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await tx.update(
    'sync_outbox',
    {'status': 'conflict', 'lease_token': null, 'last_error': reason},
    where: 'entity_type=? AND entity_id=?',
    whereArgs: [table, id],
  );
}

Future<void> _refreshContext(DatabaseExecutor tx, String site) async {
  final session = (await tx.query(
    'field_sessions',
    where: 'site_id=?',
    whereArgs: [site],
  )).single;
  if (session['result'] != null && session['reviewed_at'] == null) return;
  await tx.update(
    'field_sessions',
    {
      'proposal': jsonEncode(await _canonicalContext(tx, site)),
      'result': null,
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
      'context_revision': (session['context_revision'] as int) + 1,
    },
    where: 'site_id=?',
    whereArgs: [site],
  );
}

Future<void> _audit(DatabaseExecutor tx, Json conflict, String decision) =>
    tx.insert('sync_resolutions', {
      'id': const Uuid().v4(),
      'site_id': conflict['site_id'],
      'entity_type': conflict['entity_type'],
      'entity_id': conflict['entity_id'],
      'local_payload': conflict['local_payload'],
      'remote_payload': conflict['remote_payload'],
      'decision': decision,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
Future<void> _retireLocalTree(
  DatabaseExecutor tx,
  String site,
  String table,
  String id,
) async {
  final records = <String, List<Json>>{},
      dead = {for (final name in syncTables) name: <String>{}};
  dead[table]!.add(id);
  for (final name in syncTables) {
    records[name] = await tx.query(
      name,
      where: name == 'sites' ? 'id=?' : 'site_id=?',
      whereArgs: [site],
    );
    if (table == 'sites') {
      dead[name]!.addAll(records[name]!.map((r) => r['id'] as String));
    }
  }
  var progress = true;
  while (progress) {
    progress = false;
    for (final name in syncTables) {
      for (final row in records[name]!) {
        if (!dead[name]!.contains(row['id']) &&
            (syncReferences[name]?.entries.any(
                  (e) => dead[e.value]!.contains(row[e.key]),
                ) ??
                false)) {
          dead[name]!.add(row['id'] as String);
          progress = true;
        }
      }
    }
  }
  for (final name in syncTables) {
    for (final row in records[name]!.where(
      (r) => dead[name]!.contains(r['id']),
    )) {
      await _audit(tx, {
        'site_id': site,
        'entity_type': name,
        'entity_id': row['id'],
        'local_payload': jsonEncode(wireRecord(row)),
        'remote_payload': null,
      }, 'retired_with_server_parent');
      await tx.update(
        name,
        {'deleted_at': DateTime.now().toUtc().toIso8601String()},
        where: 'id=?',
        whereArgs: [row['id']],
      );
      if (name == 'voice_notes') {
        await tx.update(
          'voice_upload_jobs',
          {
            'state': 'retired',
            'lease_token': null,
            'last_error': 'Parent inventory removed; local file retained.',
          },
          where: 'voice_id=?',
          whereArgs: [row['id']],
        );
      }
      await tx.delete(
        'sync_outbox',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [name, row['id']],
      );
      await tx.delete(
        'sync_conflicts',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [name, row['id']],
      );
    }
  }
}
