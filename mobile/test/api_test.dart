import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartiva_fieldops/domain/briefing.dart';
import 'package:smartiva_fieldops/services/api_settings.dart';
import 'package:smartiva_fieldops/services/briefing_api.dart';

const site = '00000000-0000-4000-8000-000000000001';
const token = 'private-test-token-32-characters-minimum';
WorkItem work({String? audioPath}) => WorkItem.fromRow({
  'id': 'job',
  'site_id': site,
  'text': audioPath == null ? 'Tamil site briefing' : null,
  'audio_path': audioPath,
  'voice_id': null,
  'language': 'auto',
  'attempts': 0,
  'lease_token': 'lease',
});
String fixture() =>
    File('test/fixtures/briefing_response.json').readAsStringSync();

void main() {
  test(
    'settings require origin, secure transport and private debug IP hosts',
    () {
      expect(
        ApiSettings.parse('https://api.example.com', token).baseUrl.host,
        'api.example.com',
      );
      expect(
        ApiSettings.parse('http://10.0.2.2:8000', token).baseUrl.port,
        8000,
      );
      for (final url in [
        'https://',
        'https://api.example.com:99999',
        'http://public.example.com',
        'http://10.evil.com',
        'https://user:pass@example.com',
        'https://api.example.com/path',
        'https://api.example.com?token=x',
      ]) {
        expect(() => ApiSettings.parse(url, token), throwsFormatException);
      }
      expect(
        () => ApiSettings.parse('https://api.example.com', 'short'),
        throwsFormatException,
      );
    },
  );

  test('text sends token, site, context and disables redirects', () async {
    final gateway = HttpBriefingGateway(
      clientFactory: () => MockClient((request) async {
        expect(request.url.path, '/api/v1/ai/site-briefing');
        expect(request.headers['Authorization'], 'Bearer $token');
        expect(request.followRedirects, isFalse);
        final body = object(jsonDecode(request.body));
        expect(body['site_id'], site);
        expect(body['context']['site']['name'], 'Yogasree');
        return http.Response(fixture(), 200);
      }),
    );
    final response = await gateway.send(
      ApiSettings.parse('https://api.example.com', token),
      work(),
      {
        'site': {'name': 'Yogasree'},
      },
    );
    expect(response.calculations.single['free_channels'], 22);
  });

  test(
    'audio uses multipart with metadata and never JSON-encodes audio',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice-api-test-',
      );
      try {
        final file = await File(
          '${directory.path}/note.m4a',
        ).writeAsBytes([1, 2, 3]);
        final gateway = HttpBriefingGateway(
          clientFactory: () => MockClient((request) async {
            expect(
              request.headers['content-type'],
              startsWith('multipart/form-data'),
            );
            expect(request.body, contains('name="audio"'));
            expect(request.body, contains('audio/mp4'));
            expect(request.body, contains('name="metadata"'));
            return http.Response(fixture(), 200);
          }),
        );
        await gateway.send(
          ApiSettings.parse('https://api.example.com', token),
          work(audioPath: file.path),
          null,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'auth failures stop automatic retries; 503 preserves retryable work',
    () async {
      for (final status in [401, 503]) {
        final gateway = HttpBriefingGateway(
          clientFactory: () => MockClient(
            (_) async => http.Response('private upstream body', status),
          ),
        );
        try {
          await gateway.send(
            ApiSettings.parse('https://api.example.com', token),
            work(),
            null,
          );
          fail('Expected WorkFailure');
        } on WorkFailure catch (error) {
          expect(error.retryable, status == 503);
          expect(error.code, isNot(contains('private upstream body')));
        }
      }
    },
  );

  test('wrong-site or malformed response is rejected', () async {
    for (final body in ['not json', fixture().replaceAll(site, 'wrong-site')]) {
      final gateway = HttpBriefingGateway(
        clientFactory: () => MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        gateway.send(
          ApiSettings.parse('https://api.example.com', token),
          work(),
          null,
        ),
        throwsA(isA<WorkFailure>()),
      );
    }
  });
}
