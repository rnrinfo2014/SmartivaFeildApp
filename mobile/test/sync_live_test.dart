// Opt-in real HTTP + PostgreSQL integration. Run through tests/run_mobile_sync.py.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartiva_fieldops/data/database.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/services/api_settings.dart';
import 'package:smartiva_fieldops/services/sync_api.dart';
import 'package:smartiva_fieldops/services/sync_worker.dart';
import 'repository_test.dart' show fixture;

class MemorySettings extends ApiSettingsStore {
  MemorySettings(this.config);
  final ApiSettings config;
  @override
  Future<ApiSettings?> load() async => config;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  HttpOverrides.global =
      null; // Explicit opt-in integration test uses real loopback HTTP.
  test(
    'two SQLite devices exchange reviewed inventory and archived voice through PostgreSQL',
    () async {
      final config = ApiSettings.parse(
        Platform.environment['SMARTIVA_LIVE_URL']!,
        Platform.environment['SMARTIVA_LIVE_TOKEN']!,
      );
      final directory = await Directory.systemTemp.createTemp('smartiva-live-');
      final a = FieldRepository(
        await openFieldDatabase(
          factory: databaseFactoryFfi,
          path: '${directory.path}/a.db',
        ),
      );
      final b = FieldRepository(
        await openFieldDatabase(
          factory: databaseFactoryFfi,
          path: '${directory.path}/b.db',
        ),
      );
      final gateway = HttpSyncGateway(), settings = MemorySettings(config);
      final wa = InventorySyncWorker(a, settings, gateway),
          wb = InventorySyncWorker(b, settings, gateway);
      wa.start(observeNetwork: false, processImmediately: false);
      wb.start(observeNetwork: false, processImmediately: false);
      try {
        final site = await a.createSite('Yogasree');
        await a.queueText(site, '64 channel NVR; 42 cameras', 'auto');
        await a.complete((await a.claim())!, fixture(site));
        await a.confirm(site, jsonEncode(fixture(site).json));
        final audio = File('${directory.path}/voice.m4a');
        await audio.writeAsBytes([1, 2, 3, 4, 5]);
        const voice = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
        await a.beginRecording(voice, site, audio.path, 'auto');
        await a.finishRecording(
          voice,
          sha256.convert(await audio.readAsBytes()).toString(),
        );
        await wa.runPending();
        expect(
          await a.pendingInventory(),
          isEmpty,
          reason:
              '${(await a.pendingInventory()).map((r) => [r['entity_type'], r['status'], r['last_error']]).toList()}',
        );
        expect((await a.db.query('voice_upload_jobs')).single['state'], 'done');
        await wb.runPending();
        expect((await b.sites()).single['name'], 'Yogasree Textiles');
        expect(
          (await b.db.query('assets')).length,
          (await a.db.query('assets')).length,
        );
        expect(
          (await b.db.query('cameras')).single['id'],
          (await a.db.query('cameras')).single['id'],
        );
        expect((await b.db.query('network_interfaces')).length, 2);
        expect(
          (await b.db.query('voice_notes')).single['object_key'],
          isNotNull,
        );
        expect(
          (await b.db.query('voice_notes')).single['local_file_ref'],
          isNull,
        );
        expect((await b.context(site))!['assets'], isNotEmpty);
        // Simulate a successful commit with a lost mobile acknowledgement.
        final request = {
          ...(await a.db.query('sites')).single,
          'name': 'Updated office name',
        };
        final id = 'aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff';
        final work = {
          'operation_id': id,
          'site_id': site,
          'entity_type': 'sites',
          'entity_id': site,
          'operation': 'update',
          'base_version': request['version'],
          'payload': jsonEncode(wireRecord(request)),
        };
        final first = await gateway.push(config, work),
            replay = await gateway.push(config, work);
        expect(replay, first);
        await wb.runPending();
        expect((await b.sites()).single['name'], 'Updated office name');
        expect(await b.conflicts(), isEmpty);
      } finally {
        await wa.dispose();
        await wb.dispose();
        await a.close();
        await b.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['SMARTIVA_LIVE_URL'] == null
        ? 'Run tests/run_mobile_sync.py with a disposable PostgreSQL database'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
