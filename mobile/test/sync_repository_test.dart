import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartiva_fieldops/data/database.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/domain/briefing.dart';
import 'repository_test.dart' show fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late FieldRepository r;
  late String site;
  setUp(() async {
    r = FieldRepository(
      await openFieldDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      ),
    );
    site = await r.createSite('Yogasree');
  });
  tearDown(() async => r.close());
  Future<Json> serverSite({
    int version = 1,
    String name = 'Yogasree',
    String? deleted,
  }) async => {
    ...wireRecord((await r.db.query('sites')).single),
    'version': version,
    'name': name,
    'deleted_at': deleted,
    'extra': <String, dynamic>{},
  };
  Future<void> ackSite() async {
    final w = (await r.claimMutation())!;
    await r.acknowledgeMutation(w, await serverSite());
  }

  Future<void> review() async {
    await r.queueText(site, '64 channel NVR', 'auto');
    final w = (await r.claim())!;
    await r.complete(w, fixture(site));
    await r.confirm(site, jsonEncode(fixture(site).json));
  }

  test(
    'lost acknowledgement replays identical operation and stale lease cannot finish',
    () async {
      final first = (await r.claimMutation())!;
      await r.failMutation(first, 'offline', retryable: false);
      await r.retryLatest('sites', site);
      final retry = (await r.claimMutation())!;
      expect(retry['operation_id'], first['operation_id']);
      expect(retry['payload'], first['payload']);
      expect(retry['base_version'], 0);
      await r.acknowledgeMutation(first, await serverSite());
      expect(await r.pendingInventory(), hasLength(1));
      await r.acknowledgeMutation(retry, await serverSite());
      expect(await r.pendingInventory(), isEmpty);
    },
  );
  test(
    'edit during upload creates successor then rebases against acknowledged version',
    () async {
      final first = (await r.claimMutation())!;
      await review();
      final siteOps = (await r.pendingInventory())
          .where((x) => x['entity_type'] == 'sites')
          .toList();
      expect(siteOps, hasLength(2));
      expect(siteOps.last['depends_on'], first['operation_id']);
      expect(siteOps.first['payload'], first['payload']);
      await r.acknowledgeMutation(
        first,
        await serverSite(name: 'Server supplied'),
      );
      final successor = (await r.pendingInventory()).singleWhere(
        (x) => x['entity_type'] == 'sites',
      );
      expect(successor['base_version'], 1);
      expect(successor['depends_on'], isNull);
      expect((await r.db.query('sites')).single['name'], 'Yogasree Textiles');
      final work = (await r.claimMutation())!;
      expect(work['entity_type'], 'sites');
      await r.acknowledgeMutation(
        work,
        await serverSite(version: 2, name: 'Yogasree Textiles'),
      );
      expect((await r.claimMutation())!['entity_type'], 'floors');
    },
  );
  test(
    'server pull preserves local edits, persists conflict and audits resolution',
    () async {
      await ackSite();
      await review();
      final remote = await serverSite(version: 2, name: 'Other technician');
      expect(
        await r.applyPage(site, {
          'changes': [
            {'entity_type': 'sites', 'record': remote},
          ],
          'cursor': 2,
        }),
        isTrue,
      );
      expect((await r.db.query('sites')).single['name'], 'Yogasree Textiles');
      expect(await r.conflicts(), hasLength(1));
      expect(await r.claimMutation(), isNull);
      await r.resolveConflict('sites', site, keepLocal: true);
      expect(await r.conflicts(), isEmpty);
      expect(await r.db.query('sync_resolutions'), hasLength(1));
      final work = (await r.claimMutation())!;
      expect(work['base_version'], 2);
      expect(work['operation'], 'update');
    },
  );
  test(
    'unacknowledged own write defers page without advancing cursor',
    () async {
      await r.claimMutation();
      expect(
        await r.applyPage(site, {
          'changes': [
            {'entity_type': 'sites', 'record': await serverSite()},
          ],
          'cursor': 1,
        }),
        isFalse,
      );
      expect(await r.db.query('sync_cursors'), isEmpty);
    },
  );
  test(
    'accepting parent tombstone retires pending descendants and retains audit',
    () async {
      await ackSite();
      await review();
      const voice = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab';
      await r.beginRecording(voice, site, '/private/retained.m4a', 'auto');
      await r.finishRecording(voice, 'b' * 64);
      final remote = await serverSite(
        version: 2,
        deleted: '2026-10-20T00:00:00Z',
      );
      await r.applyPage(site, {
        'changes': [
          {'entity_type': 'sites', 'record': remote},
        ],
        'cursor': 2,
      });
      await expectLater(
        r.resolveConflict('sites', site, keepLocal: true),
        throwsFormatException,
      );
      await r.resolveConflict('sites', site, keepLocal: false);
      expect(
        (await r.db.query('voice_upload_jobs')).single['state'],
        'retired',
      );
      expect(
        (await r.db.query('voice_notes')).single['local_file_ref'],
        '/private/retained.m4a',
      );
      expect(await r.pendingInventory(), isEmpty);
      expect(await r.sites(), isEmpty);
      expect(
        (await r.db.query('assets')).every((a) => a['deleted_at'] != null),
        isTrue,
      );
      expect((await r.db.query('sync_resolutions')).length, greaterThan(1));
    },
  );
  test(
    'voice archive independent queue preserves private path and later transcript',
    () async {
      const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      await r.beginRecording(id, site, '/private/note.m4a', 'auto');
      await r.finishRecording(id, 'a' * 64);
      expect(await r.claimVoiceUpload(), isNull);
      await ackSite();
      final work = (await r.claimVoiceUpload())!;
      final local = (await r.db.query('voice_notes')).single;
      await r.db.update(
        'voice_notes',
        {'transcript': 'Tamil note', 'processing_status': 'complete'},
        where: 'id=?',
        whereArgs: [id],
      );
      final remote = {
        ...wireRecord(local),
        'version': 1,
        'object_key': '$site/archive.audio',
        'processing_status': 'uploaded',
        'extra': {'mime': 'audio/mp4'},
      };
      await r.acknowledgeVoice(work, remote);
      final saved = (await r.db.query('voice_notes')).single;
      expect(saved['local_file_ref'], '/private/note.m4a');
      expect(saved['transcript'], 'Tamil note');
      final op = (await r.pendingInventory()).single;
      expect(op['entity_type'], 'voice_notes');
      expect(
        jsonDecode(op['payload'] as String),
        isNot(contains('local_file_ref')),
      );
    },
  );
  test('database binding rejects switching device or server', () async {
    final identity = {'device_id': 'device-a', 'technician_id': 'tech-a'};
    await r.bindSync('https://example.com', identity);
    await r.bindSync('https://example.com', identity);
    await expectLater(
      r.bindSync('https://other.com', identity),
      throwsFormatException,
    );
    await r.queueText(site, 'note', 'auto');
    expect(await r.claim(), isNull);
    await ackSite();
    expect(await r.claim(), isNotNull);
  });
  test(
    'pull into second device creates canonical inventory and chat context',
    () async {
      final remote = await serverSite();
      await r.db.delete('sync_outbox');
      await r.db.delete('chat_messages');
      await r.db.delete('field_sessions');
      await r.db.delete('sites');
      await r.applyPage(site, {
        'changes': [
          {'entity_type': 'sites', 'record': remote},
        ],
        'cursor': 1,
      });
      expect((await r.sites()).single['name'], 'Yogasree');
      expect((await r.context(site))!['site']['name'], 'Yogasree');
    },
  );
}
