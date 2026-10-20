part of 'field_repository.dart';

extension DiscoveryInventory on FieldRepository {
  Future<void> saveDiscovery(String siteId, DiscoveryReport report) async {
    await db.insert('network_scans', {
      'id': _id(),
      'site_id': siteId,
      'observed_at': _now(),
      'payload': jsonEncode(report.toJson()),
    });
    changed();
  }

  Future<String> saveSnapshot(
    String siteId,
    NvrSnapshot snapshot, {
    String? credentialRef,
  }) async {
    final id = _id();
    await db.insert('nvr_snapshots', {
      'id': id,
      'site_id': siteId,
      'observed_at': _now(),
      'payload': jsonEncode(snapshot.toJson()),
      'credential_ref': credentialRef,
    });
    changed();
    return id;
  }

  Future<void> attachSnapshotCredential(String id, String ref) async {
    await db.update(
      'nvr_snapshots',
      {'credential_ref': ref},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<List<Json>> snapshots(String siteId) => db.query(
    'nvr_snapshots',
    where: 'site_id=?',
    whereArgs: [siteId],
    orderBy: 'observed_at DESC',
  );
  Future<List<Json>> localRecorders(String siteId) => db.query(
    'assets',
    where: "site_id=? AND asset_type IN ('NVR','DVR') AND deleted_at IS NULL",
    whereArgs: [siteId],
  );
  Future<void> forgetCredentialRef(String siteId, String ref) async {
    await db.transaction((tx) async {
      await tx.update(
        'assets',
        {'credential_ref': null},
        where: 'site_id=? AND credential_ref=?',
        whereArgs: [siteId, ref],
      );
      await tx.update(
        'nvr_snapshots',
        {'credential_ref': null},
        where: 'site_id=? AND credential_ref=?',
        whereArgs: [siteId, ref],
      );
    });
    changed();
  }

  Future<String> importSnapshot(
    String snapshotId, {
    String? existingNvrId,
    bool useSlotChannels = false,
    String? brand,
    String? zoneId,
  }) async {
    final nvrId = await db.transaction((tx) async {
      final stored = (await tx.query(
        'nvr_snapshots',
        where: 'id=?',
        whereArgs: [snapshotId],
      )).single;
      if (stored['imported_asset_id'] != null) {
        return stored['imported_asset_id'] as String;
      }
      final siteId = stored['site_id'] as String;
      if (await _siteConflicted(tx, siteId)) {
        throw const FormatException(
          'Resolve site sync conflicts before importing inventory.',
        );
      }
      final snapshot = NvrSnapshot.fromJson(
        object(jsonDecode(stored['payload'] as String)),
      );
      final session = (await tx.query(
        'field_sessions',
        where: 'site_id=?',
        whereArgs: [siteId],
      )).single;
      if (session['result'] != null && session['reviewed_at'] == null) {
        throw const FormatException(
          'Review and save the current AI proposal first. This scan is retained for import afterwards.',
        );
      }
      final matches = snapshot.serial == null
          ? <Json>[]
          : await tx.query(
              'assets',
              where: "site_id=? AND serial_number=? AND deleted_at IS NULL",
              whereArgs: [siteId, snapshot.serial],
            );
      if (matches.length > 1) {
        throw const FormatException(
          'This recorder serial matches multiple assets. Resolve duplicate inventory before import.',
        );
      }
      if (existingNvrId != null &&
          matches.isNotEmpty &&
          matches.single['id'] != existingNvrId) {
        throw const FormatException(
          'This serial belongs to another asset. Select that recorder instead.',
        );
      }
      Json? existing;
      final selectedId =
          existingNvrId ??
          (matches.isEmpty ? null : matches.single['id'] as String);
      if (selectedId != null) {
        final found = await tx.query(
          'assets',
          where: "id=? AND site_id=? AND deleted_at IS NULL",
          whereArgs: [selectedId, siteId],
        );
        if (found.length != 1 ||
            !['NVR', 'DVR'].contains(found.single['asset_type'])) {
          throw const FormatException(
            'Select an active recorder from this site.',
          );
        }
        existing = found.single;
        if (_different(existing['serial_number'], snapshot.serial)) {
          throw const FormatException(
            'Recorder serial does not match the selected asset. Import it as a different recorder.',
          );
        }
      } else if (snapshot.serial == null) {
        final sameAddress = await tx.rawQuery(
          '''SELECT a.id FROM assets a JOIN network_interfaces n ON n.asset_id=a.id AND n.site_id=a.site_id
          WHERE a.site_id=? AND n.ip_address=? AND a.asset_type IN ('NVR','DVR') AND a.deleted_at IS NULL''',
          [siteId, snapshot.target.address],
        );
        if (sameAddress.isNotEmpty) {
          throw const FormatException(
            'An existing recorder uses this address. Select it explicitly; IP addresses alone do not prove identity.',
          );
        }
      }
      final id = existing?['id'] as String? ?? _id(), now = _now();
      final capacity =
          snapshot.channelCapacity ?? existing?['channel_capacity'] as int?;
      final seenChannels = <int>{};
      for (final camera in snapshot.cameras) {
        final channel =
            camera.localChannel ?? (useSlotChannels ? camera.slot + 1 : null);
        if (channel != null &&
            (!seenChannels.add(channel) ||
                (capacity != null && channel > capacity))) {
          throw const FormatException(
            'Camera channel mapping conflicts with this recorder. Verify channels before import.',
          );
        }
      }
      await _save(tx, 'assets', id, siteId, {
        'asset_type': existing?['asset_type'] ?? 'NVR',
        'source': 'discovery',
        if (snapshot.model != null) 'model': snapshot.model,
        if (snapshot.serial != null) 'serial_number': snapshot.serial,
        if (snapshot.channelCapacity != null)
          'channel_capacity': snapshot.channelCapacity,
        if (brand != null && brand.trim().isNotEmpty) 'brand': brand.trim(),
        'zone_id': ?zoneId,
        if (stored['credential_ref'] != null)
          'credential_ref': stored['credential_ref'],
      }, now);
      var management = await tx.query(
        'network_interfaces',
        where:
            'site_id=? AND asset_id=? AND ip_address=? AND deleted_at IS NULL',
        whereArgs: [siteId, id, snapshot.target.address],
      );
      if (management.length > 1) {
        throw const FormatException(
          'Management address matches multiple NIC records. Resolve that mapping before import.',
        );
      }
      if (management.isEmpty) {
        management = await tx.query(
          'network_interfaces',
          where: 'site_id=? AND asset_id=? AND name=? AND deleted_at IS NULL',
          whereArgs: [siteId, id, 'discovery-management'],
        );
      }
      final knownInterface = management.isEmpty ? null : management.single;
      await _save(
        tx,
        'network_interfaces',
        knownInterface?['id'] as String? ?? _id(),
        siteId,
        {
          'asset_id': id,
          'name': knownInterface?['name'] ?? 'discovery-management',
          'ip_address': snapshot.target.address,
          'purpose':
              knownInterface?['purpose'] ??
              'Management address observed via CGI; physical NIC label unverified',
          'source': 'discovery',
        },
        now,
      );

      for (final camera in snapshot.cameras) {
        final channel =
            camera.localChannel ?? (useSlotChannels ? camera.slot + 1 : null);
        final bindings = await tx.query(
          'discovery_bindings',
          where: 'site_id=? AND nvr_id=? AND remote_slot=?',
          whereArgs: [siteId, id, camera.slot],
        );
        var found = <Json>[];
        if (camera.serial != null || camera.mac != null) {
          found = await tx.query(
            'cameras',
            where:
                "site_id=? AND deleted_at IS NULL AND (${[if (camera.serial != null) 'serial_number=?', if (camera.mac != null) 'upper(mac_address)=?'].join(' OR ')})",
            whereArgs: [
              siteId,
              if (camera.serial != null) camera.serial!,
              if (camera.mac != null) camera.mac!,
            ],
          );
          if (found.length > 1) {
            throw const FormatException(
              'Camera serial/MAC identifies different records. Resolve the identity conflict before import.',
            );
          }
        }
        if (found.isEmpty && bindings.isNotEmpty) {
          found = await tx.query(
            'cameras',
            where: 'site_id=? AND id=? AND deleted_at IS NULL',
            whereArgs: [siteId, bindings.single['camera_id']],
          );
          if (found.isEmpty) {
            throw const FormatException(
              'This remote slot previously belonged to a retired camera. Resolve the replacement before import.',
            );
          }
        }
        if (found.isEmpty && channel != null) {
          found = await tx.query(
            'cameras',
            where:
                'site_id=? AND nvr_id=? AND channel_no=? AND deleted_at IS NULL',
            whereArgs: [siteId, id, channel],
          );
        }
        final old = found.isEmpty ? null : found.single;
        if (old != null) {
          if (_different(old['serial_number'], camera.serial) ||
              _different(old['mac_address'], camera.mac)) {
            throw const FormatException(
              'A camera identity changed at an existing slot/channel. Resolve the replacement before import.',
            );
          }
          if (old['nvr_id'] != null && old['nvr_id'] != id) {
            throw const FormatException(
              'A matching camera belongs to another recorder. Automatic moves are disabled.',
            );
          }
          final strongMatch =
              (camera.serial != null &&
                  old['serial_number'] == camera.serial) ||
              (camera.mac != null &&
                  (old['mac_address'] as String?)?.toUpperCase() == camera.mac);
          if (!strongMatch && _different(old['ip_address'], camera.ip)) {
            throw const FormatException(
              'A camera address changed without a serial/MAC match. Verify its identity before import.',
            );
          }
          if (bindings.isNotEmpty &&
              bindings.single['camera_id'] != old['id']) {
            throw const FormatException(
              'Remote-slot identity conflicts with existing inventory.',
            );
          }
        }
        final cameraId = old?['id'] as String? ?? _id();
        await _save(tx, 'cameras', cameraId, siteId, {
          'nvr_id': id,
          'camera_type': old?['camera_type'] ?? 'IP',
          'source': 'discovery',
          if (old == null) 'status': 'unknown',
          if (camera.serial != null) 'serial_number': camera.serial,
          if (camera.mac != null) 'mac_address': camera.mac,
          if (camera.ip != null) 'ip_address': camera.ip,
          if (camera.brand != null) 'brand': camera.brand,
          'channel_no': ?channel,
        }, now);
        if (bindings.isEmpty) {
          await tx.insert('discovery_bindings', {
            'site_id': siteId,
            'nvr_id': id,
            'remote_slot': camera.slot,
            'camera_id': cameraId,
          });
        }
      }
      await _save(tx, 'observations', snapshotId, siteId, {
        'asset_id': id,
        'kind': 'nvr_remote_inventory',
        'payload': jsonEncode(snapshot.toJson()),
        'confirmed': 1,
        'observed_at': stored['observed_at'],
        'source': 'discovery',
      }, now);
      await tx.update(
        'nvr_snapshots',
        {'imported_asset_id': id},
        where: 'id=?',
        whereArgs: [snapshotId],
      );
      await tx.update(
        'field_sessions',
        {
          'proposal': jsonEncode(await _canonicalContext(tx, siteId)),
          'result': null,
          'reviewed_at': now,
          'updated_at': now,
          'context_revision': (session['context_revision'] as int) + 1,
        },
        where: 'site_id=?',
        whereArgs: [siteId],
      );
      await _message(
        tx,
        siteId,
        'system',
        'Imported ${snapshot.cameras.length} configured camera records from the NVR. Unseen cameras were retained; live health was not checked.',
        null,
      );
      return id;
    });
    changed();
    return nvrId;
  }
}

bool _different(Object? old, Object? current) =>
    old != null &&
    current != null &&
    old.toString().toUpperCase() != current.toString().toUpperCase();

Future<Json> _canonicalContext(DatabaseExecutor tx, String siteId) async {
  final site = (await tx.query(
    'sites',
    where: 'id=?',
    whereArgs: [siteId],
  )).single;
  final data = <String, dynamic>{
    'site': {
      for (final key in ['name', 'gps_lat', 'gps_lng', 'address', 'landmarks'])
        key: site[key],
    },
  };
  final groups = <String, List<Json>>{}, refs = <String, String>{};
  for (final entry in entityTables.entries) {
    final records = await tx.query(
      entry.value,
      where: 'site_id=? AND deleted_at IS NULL',
      whereArgs: [siteId],
    );
    groups[entry.key] = records;
    for (final row in records) {
      final stored = await tx.query(
        'proposal_refs',
        where: 'site_id=? AND entity_table=? AND entity_id=?',
        whereArgs: [siteId, entry.value, row['id']],
      );
      final ref = stored.isEmpty
          ? row['id'] as String
          : stored.single['ref'] as String;
      refs[row['id'] as String] = ref;
      if (stored.isEmpty) {
        await tx.insert('proposal_refs', {
          'site_id': siteId,
          'ref': ref,
          'entity_table': entry.value,
          'entity_id': row['id'],
        });
      }
    }
  }
  for (final entry in entityTables.entries) {
    data[entry.key] = groups[entry.key]!
        .map(
          (row) => {
            'ref': refs[row['id']],
            for (final field in _fields[entry.value]!)
              if (row.containsKey(field))
                field: field.endsWith('_id') && row[field] != null
                    ? refs[row[field]]
                    : row[field],
          },
        )
        .toList();
  }
  for (final entry in {
    'inventory_reports': 'nvr_id',
    'switch_reports': 'switch_id',
    'ups_reports': 'ups_id',
  }.entries) {
    final reports = await tx.query(
      'observations',
      where: 'site_id=? AND kind=? AND deleted_at IS NULL AND confirmed=1',
      whereArgs: [siteId, entry.key],
    );
    data[entry.key] = reports
        .map(
          (row) => {
            ...object(jsonDecode(row['payload'] as String)),
            entry.value: refs[row['asset_id']],
          },
        )
        .where((row) => row[entry.value] != null)
        .toList();
  }
  return data;
}
