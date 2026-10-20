import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/domain/discovery.dart';
import 'package:smartiva_fieldops/ui/nvr_connection_screen.dart';
import 'package:smartiva_fieldops/ui/nvr_review_screen.dart';

class SnapshotDatabase extends Fake implements Database {
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
  }) async {
    if (table == 'assets') return [];
    if (table == 'nvr_snapshots') {
      return [
        {
          'id': 'scan',
          'site_id': 'site',
          'imported_asset_id': null,
          'payload': jsonEncode(
            NvrSnapshot(
              target: NvrTarget('192.168.1.10'),
              model: 'Test NVR',
              serial: 'NVR-SN',
              cameras: [
                RemoteCamera(slot: 3, ip: '10.1.1.10', serial: 'CAM-1'),
              ],
              warnings: ['Channel mapping needs verification.'],
            ).toJson(),
          ),
        },
      ];
    }
    return [];
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async => [];
}

void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'saved NVR review works offline and channel assumption is opt-in',
    (tester) async {
      phoneSize(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: NvrReviewScreen(
            repository: FieldRepository(SnapshotDatabase()),
            snapshotId: 'scan',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test NVR'), findsOneWidget);
      expect(find.text('Channel unknown · remote slot 3'), findsOneWidget);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(find.text('Channel 4 · remote slot 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('NVR password stays obscured and clears when target changes', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: NvrConnectionScreen(
          repository: FieldRepository(SnapshotDatabase()),
          siteId: 'site',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final password = find.byType(TextField).at(3);
    await tester.ensureVisible(password);
    await tester.enterText(password, 'private-test-password');
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    final ip = find.byType(TextField).first;
    await tester.ensureVisible(ip);
    await tester.enterText(ip, '192.168.1.99');
    expect(tester.widget<TextField>(password).controller!.text, isEmpty);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
