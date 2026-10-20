import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:smartiva_fieldops/main.dart';

class StartupDatabaseException extends Fake implements DatabaseException {
  @override
  int? getResultCode() => 1;
  @override
  String toString() => 'private SQL and site data';
}

void main() {
  testWidgets('startup reports safe diagnostics and allows retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      FieldOpsBootstrap(
        openDatabase: () async {
          attempts++;
          if (attempts == 1) throw StartupDatabaseException();
          throw StateError('private SQL and site data');
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Step: Local database · SQLite 1'), findsOneWidget);
    expect(find.textContaining('private SQL'), findsNothing);
    expect(find.textContaining('free space'), findsNothing);
    expect(
      find.textContaining('Your saved data has not been cleared'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Step: Local database · StateError'), findsOneWidget);
    expect(find.textContaining('private SQL'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
