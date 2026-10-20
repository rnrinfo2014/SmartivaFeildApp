import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../domain/briefing.dart';
import 'api_settings.dart';

class WorkFailure implements Exception {
  const WorkFailure(this.code, {this.retryable = false});
  final String code;
  final bool retryable;
}

abstract class BriefingGateway {
  Future<BriefingResult> send(
    ApiSettings settings,
    WorkItem work,
    Json? context,
  );
}

class HttpBriefingGateway implements BriefingGateway {
  HttpBriefingGateway({http.Client Function()? clientFactory})
    : _newClient = clientFactory ?? http.Client.new;
  final http.Client Function() _newClient;
  @override
  Future<BriefingResult> send(
    ApiSettings settings,
    WorkItem work,
    Json? context,
  ) async {
    final client = _newClient();
    try {
      return await _send(
        client,
        settings,
        work,
        context,
      ).timeout(const Duration(seconds: 115));
    } on TimeoutException {
      throw const WorkFailure(
        'Connection timed out. Note is saved; retry scheduled.',
        retryable: true,
      );
    } on SocketException {
      throw const WorkFailure(
        'Network unavailable. Note is saved; retry scheduled.',
        retryable: true,
      );
    } on http.ClientException {
      throw const WorkFailure(
        'Could not reach the API. Check connection and settings.',
        retryable: true,
      );
    } on FileSystemException {
      throw const WorkFailure(
        'Voice file is missing or unreadable. Record a new note.',
      );
    } on TypeError {
      throw const WorkFailure(
        'API response was incompatible. Check the backend version.',
      );
    } on FormatException {
      throw const WorkFailure(
        'API response was incompatible. Check the backend version.',
      );
    } finally {
      client.close(); // Also aborts a timed-out request.
    }
  }

  Future<BriefingResult> _send(
    http.Client client,
    ApiSettings settings,
    WorkItem work,
    Json? context,
  ) async {
    final uri = settings.baseUrl.resolve('/api/v1/ai/site-briefing');
    final metadata = {
      'site_id': work.siteId,
      'language': work.language,
      'context': ?context,
    };
    final http.BaseRequest request;
    if (work.audioPath != null) {
      final file = File(work.audioPath!);
      final size = await file.length();
      if (size == 0 || size > 10 * 1024 * 1024) {
        throw const WorkFailure(
          'Voice note must be nonempty and smaller than 10 MiB.',
        );
      }
      final multipart = http.MultipartRequest('POST', uri);
      multipart.fields['metadata'] = jsonEncode(metadata);
      multipart.files.add(
        await http.MultipartFile.fromPath(
          'audio',
          file.path,
          contentType: MediaType('audio', 'mp4'),
        ),
      );
      request = multipart;
    } else {
      request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({...metadata, 'text': work.text});
    }
    request.headers['Authorization'] = 'Bearer ${settings.token}';
    request.followRedirects =
        false; // Never forward auth to a redirected origin.
    final response = await client.send(request);
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const WorkFailure('API response exceeded the supported size.');
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode != 200) {
      final status = response.statusCode;
      final retryable = status == 408 || status == 429 || status >= 500;
      final message = switch (status) {
        401 || 403 =>
          'API access denied. Update your connection settings, then retry.',
        413 =>
          'Note exceeds the server upload limit. Split it into shorter notes.',
        422 => 'Briefing was rejected. Check the note and backend version.',
        503 =>
          'AI service unavailable or not configured. Note is saved for retry.',
        _ => 'API request failed ($status). Note is saved.',
      };
      throw WorkFailure(message, retryable: retryable);
    }
    final result = BriefingResult.decode(utf8.decode(bytes));
    if (result.json['site_id'] != work.siteId) {
      throw const FormatException('Wrong site response');
    }
    return result;
  }
}
