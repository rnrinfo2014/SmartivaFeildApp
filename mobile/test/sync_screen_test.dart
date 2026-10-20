import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/services/api_settings.dart';
import 'package:smartiva_fieldops/services/sync_api.dart';
import 'package:smartiva_fieldops/services/sync_worker.dart';
import 'package:smartiva_fieldops/ui/sync_screen.dart';

class StatusDatabase extends Fake implements Database {
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async => table == 'sync_conflicts'
      ? [
          {
            'entity_type': 'sites',
            'entity_id': 'site',
            'site_id': 'site',
            'reason': 'Review concurrent edits',
            'local_payload': jsonEncode({'name': 'Device copy'}),
            'remote_payload': jsonEncode({'name': 'Server copy', 'version': 2}),
          },
        ]
      : [];
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async => [];
}

void main() {
  testWidgets(
    'conflict review presents both snapshots and explicit resolution choices',
    (tester) async {
      final repository = FieldRepository(StatusDatabase());
      final worker = InventorySyncWorker(
        repository,
        ApiSettingsStore(),
        HttpSyncGateway(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SyncScreen(repository: repository, worker: worker),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('ON THIS DEVICE'), findsOneWidget);
      expect(find.text('ON THE SERVER'), findsOneWidget);
      expect(find.textContaining('Device copy'), findsOneWidget);
      expect(find.textContaining('Server copy'), findsOneWidget);
      expect(find.text('Use server copy'), findsOneWidget);
      expect(find.text('Keep device edits'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('Review'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await worker.dispose();
    },
  );
}
