import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartiva_fieldops/data/database.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/domain/briefing.dart';
import 'package:smartiva_fieldops/services/api_settings.dart';
import 'package:smartiva_fieldops/services/briefing_api.dart';
import 'package:smartiva_fieldops/services/briefing_worker.dart';

class MemorySettings extends ApiSettingsStore {
  @override
  Future<ApiSettings?> load() async => ApiSettings.parse(
    'https://api.example.com',
    'private-test-token-at-least-32-characters',
  );
}

class FakeGateway implements BriefingGateway {
  final contexts = <Json?>[];
  final texts = <String?>[];
  bool unavailable = false;
  @override
  Future<BriefingResult> send(
    ApiSettings settings,
    WorkItem work,
    Json? context,
  ) async {
    contexts.add(context);
    texts.add(work.text);
    if (unavailable) throw const WorkFailure('Offline', retryable: true);
    final result = object(
      jsonDecode(
        File('test/fixtures/briefing_response.json').readAsStringSync(),
      ),
    );
    result['site_id'] = work.siteId;
    return BriefingResult(result);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'worker drains in order and reads latest context for each turn',
    () async {
      final repo = FieldRepository(
        await openFieldDatabase(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        ),
      );
      final gateway = FakeGateway();
      final processing = BriefingWorker(repo, MemorySettings(), gateway);
      try {
        final site = await repo.createSite('Yogasree Textiles');
        await repo.queueText(site, 'first', 'auto');
        await repo.queueText(site, 'second', 'auto');
        processing.start(observeNetwork: false, processImmediately: false);
        await processing.runPending();
        expect(gateway.texts, ['first', 'second']);
        expect(gateway.contexts.first!['site']['name'], 'Yogasree Textiles');
        expect(gateway.contexts.last!['assets'].length, 2);
        expect(await repo.jobs(site), isEmpty);
      } finally {
        await processing.dispose();
        await repo.close();
      }
    },
  );
  test(
    'network failure keeps voice/text evidence and schedules bounded retry',
    () async {
      final repo = FieldRepository(
        await openFieldDatabase(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        ),
      );
      final gateway = FakeGateway()..unavailable = true;
      final worker = BriefingWorker(repo, MemorySettings(), gateway);
      try {
        final site = await repo.createSite('Offline site');
        await repo.queueText(site, 'Basement switch details', 'auto');
        worker.start(observeNetwork: false, processImmediately: false);
        await worker.runPending();
        final job = (await repo.jobs(site)).single;
        expect(job['state'], 'pending');
        expect(job['attempts'], 1);
        expect(
          job['next_attempt_ms'] as int,
          greaterThan(DateTime.now().millisecondsSinceEpoch),
        );
        expect(
          (await repo.messages(site)).last['text'],
          'Basement switch details',
        );
      } finally {
        await worker.dispose();
        await repo.close();
      }
    },
  );
}
