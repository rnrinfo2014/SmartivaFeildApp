import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartiva_fieldops/data/database.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/domain/briefing.dart';

BriefingResult fixture(String siteId) {
  final json = object(
    jsonDecode(File('test/fixtures/briefing_response.json').readAsStringSync()),
  );
  json['site_id'] = siteId;
  return BriefingResult(json);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late FieldRepository repository;
  late String site;

  setUp(() async {
    repository = FieldRepository(
      await openFieldDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      ),
    );
    site = await repository.createSite('Yogasree Textiles');
  });
  tearDown(() async => repository.close());

  test('offline text and outbox persist atomically without network', () async {
    await repository.queueText(
      site,
      'Ground floor-la 8 port switch irukku',
      'auto',
    );
    final jobs = await repository.jobs(site);
    expect(jobs.single['state'], 'pending');
    expect(
      (await repository.messages(site)).last['text'],
      'Ground floor-la 8 port switch irukku',
    );
    final outbox = await repository.db.query('sync_outbox');
    expect(outbox.single['entity_type'], 'sites');
    expect(outbox.single['base_version'], 0);
  });

  test('same-site FIFO blocks later notes but not other sites', () async {
    await repository.queueText(site, 'first', 'auto');
    await repository.queueText(site, 'second', 'auto');
    final first = (await repository.claim())!;
    final other = await repository.createSite('Another site');
    await repository.queueText(other, 'third', 'auto');
    final concurrent = (await repository.claim())!;
    expect(concurrent.siteId, other);
    expect(await repository.claim(), isNull);
    await repository.complete(first, fixture(site));
    expect((await repository.claim())!.text, 'second');
  });

  test(
    'expired lease recovers and stale completion cannot overwrite context',
    () async {
      await repository.queueText(site, 'first', 'auto');
      final stale = (await repository.claim(nowMs: 1000))!;
      expect(await repository.claim(nowMs: 2000), isNull);
      final recovered = (await repository.claim(nowMs: 181001))!;
      expect(recovered.id, stale.id);
      expect(recovered.lease, isNot(stale.lease));
      await repository.complete(stale, fixture(site));
      expect((await repository.session(site))['proposal'], isNull);
      await repository.complete(recovered, fixture(site));
      expect(
        (await repository.context(site))!['site']['name'],
        'Yogasree Textiles',
      );
    },
  );

  test(
    'retry backoff preserves original and failure blocks later same-site work',
    () async {
      await repository.queueText(site, 'first', 'auto');
      await repository.queueText(site, 'second', 'auto');
      final first = (await repository.claim())!;
      await repository.fail(
        first,
        'API access denied',
        retryable: false,
        delaySeconds: 0,
      );
      expect(await repository.claim(), isNull);
      expect((await repository.jobs(site)).first['state'], 'failed');
      await repository.retry(first.id);
      expect((await repository.claim())!.id, first.id);
    },
  );

  test('skip failed AI processing retains technician message', () async {
    await repository.queueText(site, 'Keep this note', 'auto');
    final job = (await repository.claim())!;
    await repository.fail(job, 'invalid', retryable: false, delaySeconds: 0);
    await repository.skip(job.id);
    expect(await repository.jobs(site), isEmpty);
    expect(
      (await repository.messages(
        site,
      )).any((m) => m['text'] == 'Keep this note'),
      isTrue,
    );
  });

  test('recording draft becomes one queued voice note with checksum', () async {
    await repository.beginRecording(
      'voice-1',
      site,
      '/private/voice-1.m4a',
      'ta',
    );
    expect((await repository.recordingDrafts()).length, 1);
    await repository.finishRecording('voice-1', 'abc123');
    await repository.finishRecording('voice-1', 'abc123');
    expect(await repository.recordingDrafts(), isEmpty);
    expect((await repository.jobs(site)).length, 1);
    final note = (await repository.db.query('voice_notes')).single;
    expect(note['sha256'], 'abc123');
    final work = (await repository.claim())!;
    await repository.complete(work, fixture(site));
    expect(
      (await repository.db.query('voice_notes')).single['processing_status'],
      'complete',
    );
  });

  test(
    'confirmed proposal maps dual NIC topology and cameras to stable UUIDs',
    () async {
      await repository.queueText(site, 'briefing', 'auto');
      await repository.complete((await repository.claim())!, fixture(site));
      final json = (await repository.session(site))['result'] as String;
      await repository.confirm(site, json);
      final assets = await repository.db.query('assets');
      expect(assets.length, 2);
      expect(assets.every((a) => (a['id'] as String).length == 36), isTrue);
      expect((await repository.db.query('network_interfaces')).length, 2);
      expect(
        (await repository.db.query('cameras')).length,
        1,
      ); // not 42 invented rows
      final link = (await repository.db.query('asset_connections')).single;
      final nic = (await repository.db.query(
        'network_interfaces',
        where: 'id=?',
        whereArgs: [link['from_interface_id']],
      )).single;
      expect(nic['name'], 'LAN2');
      expect(nic['asset_id'], link['from_asset_id']);
      final observations = await repository.db.query('observations');
      expect(observations.single['confirmed'], 1);
      final ids = assets.map((a) => a['id']).toSet();
      final outboxCount = (await repository.db.query('sync_outbox')).length;
      await repository.confirm(site, json);
      expect(
        (await repository.db.query('assets')).map((a) => a['id']).toSet(),
        ids,
      );
      expect((await repository.db.query('sync_outbox')).length, outboxCount);
    },
  );

  test(
    'review blocks unresolved warnings and in-progress follow-up notes',
    () async {
      await repository.queueText(site, 'briefing', 'auto');
      await repository.complete((await repository.claim())!, fixture(site));
      final current = (await repository.session(site))['result'] as String;
      await repository.queueText(site, 'follow-up', 'auto');
      await expectLater(
        repository.confirm(site, current),
        throwsFormatException,
      );
      expect(await repository.db.query('assets'), isEmpty);
      final result = fixture(site)..json['warnings'] = ['Counts conflict'];
      await repository.complete((await repository.claim())!, result);
      await expectLater(
        repository.confirm(site, jsonEncode(result.json)),
        throwsFormatException,
      );
    },
  );

  test(
    'failed normalized save rolls back inventory, refs and outbox together',
    () async {
      final broken = fixture(site);
      broken.proposal['zones'][0]['floor_id'] = 'missing';
      await repository.queueText(site, 'bad briefing', 'auto');
      await repository.complete((await repository.claim())!, broken);
      final count = (await repository.db.query('sync_outbox')).length;
      await expectLater(
        repository.confirm(site, jsonEncode(broken.json)),
        throwsFormatException,
      );
      expect(await repository.db.query('floors'), isEmpty);
      expect(await repository.db.query('proposal_refs'), isEmpty);
      expect((await repository.db.query('sync_outbox')).length, count);
    },
  );

  test(
    'SQLite persists pending work across database close and reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('fieldops-test-');
      final path = '${directory.path}/field.db';
      var disk = FieldRepository(
        await openFieldDatabase(factory: databaseFactoryFfi, path: path),
      );
      try {
        final id = await disk.createSite('Basement site');
        await disk.queueText(id, 'Offline basement note', 'auto');
        await disk.close();
        disk = FieldRepository(
          await openFieldDatabase(factory: databaseFactoryFfi, path: path),
        );
        expect((await disk.jobs(id)).single['text'], 'Offline basement note');
        expect((await disk.messages(id)).last['text'], 'Offline basement note');
      } finally {
        await disk.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
