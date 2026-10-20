import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:smartiva_fieldops/data/field_repository.dart';
import 'package:smartiva_fieldops/domain/briefing.dart';
import 'package:smartiva_fieldops/services/api_settings.dart';
import 'package:smartiva_fieldops/services/briefing_api.dart';
import 'package:smartiva_fieldops/services/briefing_worker.dart';
import 'package:smartiva_fieldops/services/voice_capture.dart';
import 'package:smartiva_fieldops/ui/screens.dart';

class UnusedDatabase extends Fake implements Database {}

class ScreenRepository extends FieldRepository {
  ScreenRepository() : super(UnusedDatabase());
  @override
  Future<List<Json>> sites() async => [
    {
      'id': 'site',
      'name': 'Yogasree Textiles',
      'pending': 1,
      'reviewed_at': null,
    },
  ];
  @override
  Future<List<Json>> messages(String siteId) async => [
    {'role': 'assistant', 'text': 'NVR ethana channels support pannum?'},
    {'role': 'technician', 'text': '64 channel Dahua NVR irukku.'},
  ];
  @override
  Future<List<Json>> jobs(String siteId) async => [];
}

void main() {
  testWidgets(
    'site list opens guided chat without network or microphone access',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = ScreenRepository(), settings = ApiSettingsStore();
      final worker = BriefingWorker(
        repository,
        settings,
        HttpBriefingGateway(),
      );
      final voice = VoiceCapture(repository);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: HomeScreen(
            repository: repository,
            worker: worker,
            voice: voice,
            settings: settings,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Yogasree Textiles'), findsOneWidget);
      expect(find.text('1 briefings pending'), findsOneWidget);
      await tester.tap(find.text('Yogasree Textiles'));
      await tester.pumpAndSettle();
      expect(find.text('Guided AI entry'), findsOneWidget);
      expect(find.text('Continuous voice briefing'), findsOneWidget);
      expect(find.text('Auto-scan network'), findsOneWidget);
      expect(find.text('64 channel Dahua NVR irukku.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await voice.close();
      await worker.dispose();
    },
  );
}
