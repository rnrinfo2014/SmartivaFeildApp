import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../domain/briefing.dart';
import '../data/field_repository.dart' show wireRecord;
import 'api_settings.dart';

class SyncFailure implements Exception {
  const SyncFailure(
    this.message, {
    this.retryable = false,
    this.conflict = false,
    this.remote,
  });
  final String message;
  final bool retryable, conflict;
  final Json? remote;
  @override
  String toString() => message;
}

abstract class SyncGateway {
  Future<Json> identity(ApiSettings settings);
  Future<Json> push(ApiSettings settings, Json work);
  Future<Json> sites(ApiSettings settings, String after);
  Future<Json> changes(
    ApiSettings settings,
    String site,
    int after,
    int? through,
  );
  Future<Json> upload(ApiSettings settings, Json work);
}

class HttpSyncGateway implements SyncGateway {
  HttpSyncGateway({http.Client Function()? clientFactory})
    : _newClient = clientFactory ?? http.Client.new;
  final http.Client Function() _newClient;
  Future<Json> _request(
    ApiSettings settings,
    String method,
    String path, {
    Json? body,
    List<int>? audio,
    Map<String, String>? headers,
  }) async {
    final client = _newClient();
    try {
      return await (() async {
        final request = http.Request(method, settings.baseUrl.resolve(path))
          ..followRedirects = false;
        request.headers['Authorization'] = 'Bearer ${settings.token}';
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode(body);
        }
        if (audio != null) request.bodyBytes = audio;
        if (headers != null) request.headers.addAll(headers);
        final response = await client.send(request), bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024) {
            throw const SyncFailure(
              'Server response exceeds the supported size.',
            );
          }
          bytes.addAll(chunk);
        }
        Json data = {};
        try {
          data = object(jsonDecode(utf8.decode(bytes)));
        } on FormatException {
          if (response.statusCode == 200) rethrow;
        }
        if (response.statusCode != 200) {
          final code = response.statusCode;
          final conflict =
              code == 409 &&
              ['version_conflict', 'record_deleted'].contains(data['code']);
          throw SyncFailure(
            conflict
                ? 'Both copies changed. Review this conflict.'
                : code == 401 || code == 403
                ? 'Device access denied. Check the connection and site permissions.'
                : 'Sync request failed ($code). Local data is retained.',
            retryable: code == 408 || code == 429 || code >= 500,
            conflict: conflict,
            remote: data['current'] is Map ? object(data['current']) : null,
          );
        }
        return data;
      })().timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw const SyncFailure(
        'Connection timed out. Retry is scheduled.',
        retryable: true,
      );
    } on SocketException {
      throw const SyncFailure(
        'Network unavailable. Retry is scheduled.',
        retryable: true,
      );
    } on http.ClientException {
      throw const SyncFailure('Could not reach the server.', retryable: true);
    } on FormatException {
      throw const SyncFailure(
        'Incompatible sync response. Check the backend version.',
      );
    } on TypeError {
      throw const SyncFailure(
        'Incompatible sync response. Check the backend version.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<Json> identity(ApiSettings settings) =>
      _request(settings, 'GET', '/api/v1/sync/me');
  @override
  Future<Json> push(ApiSettings settings, Json work) => _request(
    settings,
    'POST',
    '/api/v1/sync/push',
    body: {
      for (final key in [
        'operation_id',
        'site_id',
        'entity_type',
        'entity_id',
        'operation',
        'base_version',
      ])
        key: work[key],
      'payload': wireRecord(object(jsonDecode(work['payload'] as String))),
    },
  );
  @override
  Future<Json> sites(ApiSettings settings, String after) => _request(
    settings,
    'GET',
    '/api/v1/sync/sites?after=${Uri.encodeQueryComponent(after)}',
  );
  @override
  Future<Json> changes(
    ApiSettings settings,
    String site,
    int after,
    int? through,
  ) => _request(
    settings,
    'GET',
    '/api/v1/sites/$site/changes?after=$after${through == null ? '' : '&through=$through'}',
  );
  @override
  Future<Json> upload(ApiSettings settings, Json work) async {
    try {
      final file = File(work['local_file_ref'] as String);
      final size = await file.length();
      if (size == 0 || size > 10 * 1024 * 1024) {
        throw const SyncFailure(
          'Voice file must be nonempty and at most 10 MiB.',
        );
      }
      return await _request(
        settings,
        'PUT',
        '/api/v1/sites/${work['site_id']}/voice/${work['voice_id']}',
        audio: await file.readAsBytes(),
        headers: {
          'Content-Type': 'audio/mp4',
          'X-Audio-SHA256': work['sha256'] as String,
          'X-Audio-Language': work['language'] as String,
        },
      );
    } on FileSystemException {
      throw const SyncFailure(
        'Voice file is missing. Its metadata is retained.',
      );
    }
  }
}
