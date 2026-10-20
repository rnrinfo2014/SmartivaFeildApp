import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartiva_fieldops/data/database.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/domain/briefing.dart';
import 'package:smartiva_fieldops/domain/discovery.dart';

NvrSnapshot snapshot({
  String? serial = 'NVR-SN1',
  String? cameraSerial = 'CAM-1',
  String ip = '10.1.1.10',
  int? channel = 1,
  int slot = 0,
  bool empty = false,
}) => NvrSnapshot(
  target: NvrTarget('192.168.1.10'),
  model: 'NVR-TEST',
  serial: serial,
  channelCapacity: 64,
  cameras: empty
      ? []
      : [
          RemoteCamera(
            slot: slot,
            localChannel: channel,
            ip: ip,
            serial: cameraSerial,
          ),
        ],
  warnings: ['Configured inventory is not a live status check.'],
);
BriefingResult aiFixture(String site) {
  final data = object(
    jsonDecode(File('test/fixtures/briefing_response.json').readAsStringSync()),
  );
  data['site_id'] = site;
  return BriefingResult(data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late FieldRepository repo;
  late String site;
  setUp(() async {
    repo = FieldRepository(
      await openFieldDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      ),
    );
    site = await repo.createSite('Yogasree Textiles');
  });
  tearDown(() async => repo.close());

  test(
    'import is offline, idempotent and never puts secure references in outbox/context',
    () async {
      final id = await repo.saveSnapshot(
        site,
        snapshot(),
        credentialRef: 'LOCAL-SECURE-REF',
      );
      final nvr = await repo.importSnapshot(id);
      expect(await repo.importSnapshot(id), nvr);
      final assets = await repo.db.query('assets');
      expect(assets.length, 1);
      expect(assets.single['credential_ref'], 'LOCAL-SECURE-REF');
      final cameras = await repo.db.query('cameras');
      expect(cameras.length, 1);
      expect(cameras.single['ip_address'], '10.1.1.10');
      expect(cameras.single['status'], 'unknown');
      final outbox = await repo.db.query('sync_outbox');
      expect(jsonEncode(outbox), isNot(contains('LOCAL-SECURE-REF')));
      final context = await repo.context(site);
      expect(jsonEncode(context), isNot(contains('credential_ref')));
      expect(context!['cameras'][0]['nvr_id'], context['assets'][0]['ref']);
    },
  );

  test(
    'repeated scans reuse serial identities and retain unseen cameras',
    () async {
      final nvr = await repo.importSnapshot(
        await repo.saveSnapshot(site, snapshot()),
      );
      final camera = (await repo.db.query('cameras')).single['id'];
      await repo.importSnapshot(
        await repo.saveSnapshot(site, snapshot(ip: '10.1.1.22')),
      );
      expect((await repo.db.query('assets')).length, 1);
      expect((await repo.db.query('cameras')).single['id'], camera);
      expect(
        (await repo.db.query('cameras')).single['ip_address'],
        '10.1.1.22',
      );
      await repo.importSnapshot(
        await repo.saveSnapshot(site, snapshot(empty: true)),
      );
      expect((await repo.db.query('cameras')).single['nvr_id'], nvr);
    },
  );

  test(
    'reviewed AI camera is enriched without erasing topology or known status',
    () async {
      await repo.queueText(site, 'briefing', 'auto');
      await repo.complete((await repo.claim())!, aiFixture(site));
      await repo.confirm(site, (await repo.session(site))['result'] as String);
      final old = (await repo.db.query('cameras')).single;
      await repo.db.update(
        'cameras',
        {'status': 'online'},
        where: 'id=?',
        whereArgs: [old['id']],
      );
      final nvr = old['nvr_id'] as String;
      await repo.importSnapshot(
        await repo.saveSnapshot(site, snapshot()),
        existingNvrId: nvr,
      );
      final camera = (await repo.db.query('cameras')).single;
      expect(camera['id'], old['id']);
      expect(camera['switch_id'], old['switch_id']);
      expect(camera['zone_id'], old['zone_id']);
      expect(camera['serial_number'], 'CAM-1');
      expect(camera['status'], 'online');
      expect(
        (await repo.db.query(
          'network_interfaces',
          where: 'asset_id=?',
          whereArgs: [nvr],
        )).length,
        2,
      ); // Reuse known LAN1; do not invent a third physical NIC
    },
  );

  test(
    'unknown AI fields cannot erase imported identity or documented camera status',
    () async {
      await repo.importSnapshot(await repo.saveSnapshot(site, snapshot()));
      await repo.db.update('cameras', {'status': 'online'});
      final context = await repo.context(site);
      final result = aiFixture(site);
      result.json['extracted_data'] = context;
      result.json['calculations'] = [];
      result.proposal['cameras'][0]['serial_number'] = null;
      result.proposal['cameras'][0]['status'] = 'unknown';
      await repo.queueText(site, 'Unknown camera details', 'auto');
      await repo.complete((await repo.claim())!, result);
      await repo.confirm(site, (await repo.session(site))['result'] as String);
      final camera = (await repo.db.query('cameras')).single;
      expect(camera['serial_number'], 'CAM-1');
      expect(camera['status'], 'online');
    },
  );

  test(
    'snapshot import invalidates in-flight AI response without losing its note',
    () async {
      await repo.queueText(site, 'Earlier offline briefing', 'auto');
      final work = (await repo.claim())!;
      await repo.importSnapshot(await repo.saveSnapshot(site, snapshot()));
      await repo.complete(work, aiFixture(site));
      expect((await repo.jobs(site)).single['state'], 'pending');
      expect((await repo.session(site))['result'], isNull);
      expect(
        (await repo.context(site))!['assets'][0]['serial_number'],
        'NVR-SN1',
      );
      expect(
        (await repo.claim())!.contextRevision,
        greaterThan(work.contextRevision),
      );
    },
  );

  test(
    'unreviewed AI story is retained and blocks import until reviewed',
    () async {
      await repo.queueText(site, 'AI story', 'auto');
      await repo.complete((await repo.claim())!, aiFixture(site));
      final id = await repo.saveSnapshot(site, snapshot());
      await expectLater(repo.importSnapshot(id), throwsFormatException);
      expect((await repo.snapshots(site)).single['imported_asset_id'], isNull);
      expect((await repo.session(site))['result'], isNotNull);
      expect(await repo.db.query('assets'), isEmpty);
    },
  );

  test(
    'serial mismatch and camera replacement roll back the entire import',
    () async {
      final nvr = await repo.importSnapshot(
        await repo.saveSnapshot(site, snapshot()),
      );
      final outboxCount = (await repo.db.query('sync_outbox')).length;
      await expectLater(
        repo.importSnapshot(
          await repo.saveSnapshot(site, snapshot(serial: 'DIFFERENT')),
          existingNvrId: nvr,
        ),
        throwsFormatException,
      );
      final replacement = await repo.saveSnapshot(
        site,
        snapshot(cameraSerial: 'DIFFERENT-CAMERA'),
      );
      await expectLater(
        repo.importSnapshot(replacement),
        throwsFormatException,
      );
      expect((await repo.db.query('cameras')).single['serial_number'], 'CAM-1');
      expect((await repo.db.query('sync_outbox')).length, outboxCount);
      expect(
        (await repo.db.query(
          'nvr_snapshots',
          where: 'id=?',
          whereArgs: [replacement],
        )).single['imported_asset_id'],
        isNull,
      );
    },
  );

  test(
    'weak identity changes are not silently merged and missing channel remains nullable',
    () async {
      await repo.importSnapshot(
        await repo.saveSnapshot(
          site,
          snapshot(serial: null, cameraSerial: null, channel: null),
        ),
      );
      final nvr = (await repo.db.query('assets')).single['id'] as String;
      expect((await repo.db.query('cameras')).single['channel_no'], isNull);
      final next = await repo.saveSnapshot(
        site,
        snapshot(
          serial: null,
          cameraSerial: null,
          channel: null,
          ip: '10.1.1.99',
        ),
      );
      await expectLater(
        repo.importSnapshot(next),
        throwsFormatException,
      ); // recorder requires explicit selection
      await expectLater(
        repo.importSnapshot(next, existingNvrId: nvr),
        throwsFormatException,
      ); // changed camera lacks strong ID
    },
  );

  test(
    'table-index channel convention is only applied with explicit review selection',
    () async {
      await repo.importSnapshot(
        await repo.saveSnapshot(site, snapshot(channel: null, slot: 3)),
        useSlotChannels: true,
      );
      expect((await repo.db.query('cameras')).single['channel_no'], 4);
    },
  );

  test('historical v1 database migrates without losing queued notes', () async {
    final directory = await Directory.systemTemp.createTemp(
          'discovery-upgrade-',
        ),
        path = '${directory.path}/field.db';
    var legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          for (final file in [
            'assets/domain_v1.sql',
            'test/fixtures/local_v1.sql',
          ]) {
            final text = File(file).readAsStringSync().replaceAll(
              RegExp(r'^--.*$', multiLine: true),
              '',
            );
            for (final sql in text.split(';')) {
              if (sql.trim().isNotEmpty && !sql.trim().startsWith('PRAGMA')) {
                await db.execute(sql.trim());
              }
            }
          }
        },
      ),
    );
    const oldSite = '00000000-0000-4000-8000-000000000001';
    final now = DateTime.now().toUtc().toIso8601String();
    await legacy.insert('sites', {
      'id': oldSite,
      'name': 'Legacy site',
      'created_at': now,
      'updated_at': now,
    });
    await legacy.insert('field_sessions', {
      'site_id': oldSite,
      'updated_at': now,
    });
    await legacy.insert('briefing_jobs', {
      'id': '00000000-0000-4000-8000-000000000002',
      'site_id': oldSite,
      'text': 'Retain this offline note',
      'language': 'ta',
      'created_at': now,
    });
    await legacy.insert('voice_notes', {
      'id': '00000000-0000-4000-8000-000000000003',
      'site_id': oldSite,
      'sha256': 'a' * 64,
      'local_file_ref': '/private/legacy.m4a',
      'created_at': now,
      'updated_at': now,
    });
    await legacy.close();
    final migrated = FieldRepository(
      await openFieldDatabase(factory: databaseFactoryFfi, path: path),
    );
    try {
      expect(await migrated.db.getVersion(), 3);
      expect(
        (await migrated.db.query('voice_upload_jobs')).single['state'],
        'pending',
      );
      expect(
        (await migrated.db.query('voice_notes')).single['local_file_ref'],
        '/private/legacy.m4a',
      );
      expect(
        (await migrated.jobs(oldSite)).single['text'],
        'Retain this offline note',
      );
      expect((await migrated.claim())!.contextRevision, 0);
      await migrated.saveSnapshot(oldSite, snapshot());
      expect((await migrated.snapshots(oldSite)).length, 1);
    } finally {
      await migrated.close();
      await directory.delete(recursive: true);
    }
  });
}
