import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:smartiva_fieldops/data/database.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tekartik.sqflite');

  test('Android query-only contract permits startup and offline reopen', () async {
    ffi.sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'fieldops-android-',
    );
    final path = '${directory.path}/fieldops.db';
    Database? native;
    Database? app;
    // A real SQLite database behind sqflite's platform channel. Android execSQL
    // rejects statements that return rows; desktop FFI execute does not. Enforce
    // that platform contract so desktop tests catch Android startup failures.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'openDatabase':
          native = await ffi.databaseFactoryFfi.openDatabase(path);
          return {'id': 1};
        case 'closeDatabase':
          await native?.close();
          native = null;
          return null;
        case 'execute':
          final rows = await native!.rawQuery(
            args['sql'] as String,
            args['arguments'] as List<Object?>?,
          );
          if (rows.isNotEmpty) {
            throw PlatformException(
              code: 'sqlite_error',
              message:
                  'Queries can be performed using SQLiteDatabase query or rawQuery methods only.',
            );
          }
          return null;
        case 'query':
          final rows = await native!.rawQuery(
            args['sql'] as String,
            args['arguments'] as List<Object?>?,
          );
          return {
            'columns': rows.isEmpty ? <String>[] : rows.first.keys.toList(),
            'rows': rows.map((row) => row.values.toList()).toList(),
          };
        case 'insert':
          return native!.rawInsert(
            args['sql'] as String,
            args['arguments'] as List<Object?>?,
          );
        case 'update':
          return native!.rawUpdate(
            args['sql'] as String,
            args['arguments'] as List<Object?>?,
          );
        default:
          throw UnsupportedError('Unexpected sqflite method: ${call.method}');
      }
    });
    try {
      app = await openFieldDatabase(
        factory: databaseFactorySqflitePlugin,
        path: path,
      );
      expect(
        (await app.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
      );
      expect(
        (await app.rawQuery('PRAGMA busy_timeout')).single.values.single,
        5000,
      );
      expect(
        (await app.rawQuery('PRAGMA journal_mode')).single.values.single,
        'wal',
      );
      final repository = FieldRepository(app);
      final site = await repository.createSite('Yogasree Textiles');
      await repository.queueText(site, 'Ground floor 8 port switch', 'auto');
      await app.close();
      app = await openFieldDatabase(
        factory: databaseFactorySqflitePlugin,
        path: path,
      );
      final reopened = FieldRepository(app);
      expect((await reopened.sites()).single['id'], site);
      expect(
        (await reopened.messages(site)).last['text'],
        'Ground floor 8 port switch',
      );
      expect((await reopened.jobs(site)).single['state'], 'pending');
    } finally {
      await app?.close();
      await native?.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
