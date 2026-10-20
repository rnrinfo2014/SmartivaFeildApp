import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartiva_fieldops/services/api_settings.dart';
import 'package:smartiva_fieldops/services/sync_api.dart';

void main() {
  final config = ApiSettings.parse('https://example.com', 'a' * 32);
  test(
    'push normalizes historical SQLite JSON and bools and disables redirects',
    () async {
      final gateway = HttpSyncGateway(
        clientFactory: () => MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer ${config.token}');
          final payload = (jsonDecode(request.body) as Map)['payload'] as Map;
          expect(payload['extra'], {'count': 42});
          expect(payload['confirmed'], true);
          expect(payload, isNot(contains('local_file_ref')));
          return http.Response('{"record":{}}', 200);
        }),
      );
      await gateway.push(config, {
        'operation_id': 'op',
        'site_id': 'site',
        'entity_type': 'observations',
        'entity_id': 'id',
        'operation': 'create',
        'base_version': 0,
        'payload': jsonEncode({
          'extra': '{"count":42}',
          'confirmed': 1,
          'local_file_ref': 'private',
        }),
      });
    },
  );
  test('version conflict carries server snapshot for durable review', () async {
    final gateway = HttpSyncGateway(
      clientFactory: () => MockClient(
        (_) async => http.Response(
          '{"code":"version_conflict","current":{"id":"a","version":2}}',
          409,
        ),
      ),
    );
    try {
      await gateway.push(config, {'payload': '{}'});
      fail('Expected conflict');
    } on SyncFailure catch (e) {
      expect(e.conflict, isTrue);
      expect(e.retryable, isFalse);
      expect(e.remote!['version'], 2);
    }
  });
  test('auth is permanent and server unavailable is retryable', () async {
    for (final code in [401, 403, 503]) {
      final gateway = HttpSyncGateway(
        clientFactory: () => MockClient((_) async => http.Response('{}', code)),
      );
      try {
        await gateway.identity(config);
        fail('Expected failure');
      } on SyncFailure catch (e) {
        expect(e.retryable, code == 503);
      }
    }
  });
}
