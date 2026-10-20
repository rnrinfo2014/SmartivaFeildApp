import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../domain/discovery.dart';

class NvrFailure implements Exception {
  const NvrFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class DigestChallenge {
  DigestChallenge(this.values) {
    if (realm == null ||
        nonce == null ||
        nonce!.isEmpty ||
        !{'MD5', 'MD5-SESS', 'SHA-256', 'SHA-256-SESS'}.contains(algorithm) ||
        (values['charset'] != null &&
            values['charset']!.toUpperCase() != 'UTF-8') ||
        (values['qop'] != null &&
            !values['qop']!
                .split(',')
                .map((e) => e.trim().toLowerCase())
                .contains('auth'))) {
      throw const NvrFailure(
        'NVR Digest authentication mode is unsupported. Basic authentication is not used.',
      );
    }
  }
  final Map<String, String> values;
  String? get realm => values['realm'];
  String? get nonce => values['nonce'];
  String get algorithm => (values['algorithm'] ?? 'MD5').toUpperCase();
  bool get stale => values['stale']?.toLowerCase() == 'true';
  bool get qop => values['qop'] != null;

  factory DigestChallenge.parse(String header) {
    final start = RegExp(
      r'\bDigest\s+',
      caseSensitive: false,
    ).firstMatch(header);
    if (start == null ||
        header.length > 16384 ||
        header.contains('\r') ||
        header.contains('\n')) {
      throw const NvrFailure(
        'NVR did not offer supported Digest authentication.',
      );
    }
    final values = <String, String>{};
    final rest = header.substring(start.end);
    final pattern = RegExp(
      r'\s*,?\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^,\s]+))',
    );
    var offset = 0;
    while (offset < rest.length) {
      final remaining = rest.substring(offset);
      if (remaining.trim().isEmpty) break;
      final match = pattern.matchAsPrefix(rest, offset);
      if (match == null) {
        // A following Basic/Bearer/etc. challenge is not a Digest parameter.
        if (RegExp(r'^\s*,\s*[A-Za-z][A-Za-z0-9_-]*\s+').hasMatch(remaining)) {
          break;
        }
        throw const NvrFailure('Invalid Digest authentication challenge.');
      }
      final key = match[1]!.toLowerCase();
      final value = (match[2] ?? match[3]!).replaceAllMapped(
        RegExp(r'\\(.)'),
        (m) => m[1]!,
      );
      if (values.containsKey(key) || value.length > 4096) {
        throw const NvrFailure('Invalid Digest authentication challenge.');
      }
      values[key] = value;
      offset = match.end;
    }
    return DigestChallenge(values);
  }

  String authorization({
    required String username,
    required String password,
    required String method,
    required String uri,
    required String cnonce,
    required int count,
  }) {
    String hash(String value) {
      final List<int> bytes;
      try {
        bytes = values['charset']?.toUpperCase() == 'UTF-8'
            ? utf8.encode(value)
            : latin1.encode(value);
      } on FormatException {
        throw const NvrFailure(
          'NVR requires a legacy password encoding. Use compatible credentials or firmware.',
        );
      }
      return (algorithm.startsWith('SHA-256') ? sha256 : md5)
          .convert(bytes)
          .toString();
    }

    String quoted(String value) {
      if (RegExp(r'[\r\n\x00]').hasMatch(value)) {
        throw const NvrFailure('Invalid authentication field.');
      }
      return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    }

    var ha1 = hash('$username:$realm:$password');
    if (algorithm.endsWith('-SESS')) ha1 = hash('$ha1:$nonce:$cnonce');
    final ha2 = hash('$method:$uri'),
        nc = count.toRadixString(16).padLeft(8, '0');
    final response = qop
        ? hash('$ha1:$nonce:$nc:$cnonce:auth:$ha2')
        : hash('$ha1:$nonce:$ha2');
    return [
      'Digest username=${quoted(username)}',
      'realm=${quoted(realm!)}',
      'nonce=${quoted(nonce!)}',
      'uri=${quoted(uri)}',
      'response=${quoted(response)}',
      'algorithm=$algorithm',
      if (values['opaque'] != null) 'opaque=${quoted(values['opaque']!)}',
      if (qop) 'qop=auth',
      if (qop) 'nc=$nc',
      if (qop || algorithm.endsWith('-SESS')) 'cnonce=${quoted(cnonce)}',
    ].join(', ');
  }
}

/// One target, one credential set, bounded retries. No redirects or Basic fallback.
class NvrDigestClient {
  NvrDigestClient(
    this.target,
    this.username,
    this.password, {
    http.Client? client,
    String Function()? cnonce,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _cnonce = cnonce ?? _random;
  final NvrTarget target;
  final String username, password;
  final Duration requestTimeout;
  final http.Client _client;
  final String Function() _cnonce;
  DigestChallenge? _challenge;
  int _count = 0;
  static String _random() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<String> get(String path, Map<String, String> parameters) async {
    if (username.isEmpty ||
        username.length > 160 ||
        password.length > 512 ||
        RegExp(r'[\r\n\x00]').hasMatch(username)) {
      throw const NvrFailure('Enter valid NVR credentials.');
    }
    try {
      return await _get(path, parameters).timeout(requestTimeout);
    } on TimeoutException {
      throw const NvrFailure(
        'NVR request timed out. Check site Wi-Fi and the NVR address.',
      );
    } on HandshakeException {
      throw const NvrFailure(
        'NVR HTTPS certificate is not trusted. Configure a trusted certificate or select local HTTP.',
      );
    } on SocketException {
      throw const NvrFailure(
        'Cannot reach the NVR. Check site Wi-Fi, address and HTTP/HTTPS port.',
      );
    } on http.ClientException {
      throw const NvrFailure(
        'NVR connection failed. Check the address, port and certificate.',
      );
    } on FormatException {
      throw const NvrFailure(
        'NVR response is not a supported text configuration.',
      );
    }
  }

  Future<String> _get(String path, Map<String, String> parameters) async {
    final uri = target.endpoint(path, parameters);
    var staleRetried = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      final authenticated = _challenge != null;
      if (authenticated) {
        request.headers['Authorization'] = _challenge!.authorization(
          username: username,
          password: password,
          method: 'GET',
          uri: uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
          cnonce: _cnonce(),
          count: ++_count,
        );
      }
      final response = await _client.send(request);
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const NvrFailure(
            'NVR response exceeded 2 MiB. No inventory was imported.',
          );
        }
        bytes.addAll(chunk);
      }
      if (response.statusCode == 401) {
        final challenge = DigestChallenge.parse(
          response.headers['www-authenticate'] ?? '',
        );
        if (authenticated && (!challenge.stale || staleRetried)) {
          throw const NvrFailure(
            'NVR login failed. Check credentials or the account lockout state.',
          );
        }
        if (authenticated) staleRetried = true;
        _challenge = challenge;
        _count = 0;
        continue;
      }
      if (response.statusCode == 403) {
        throw const NvrFailure(
          'NVR account cannot read this configuration. Check account permissions.',
        );
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const NvrFailure(
          'NVR redirected the request. Enter the correct HTTP/HTTPS port directly.',
        );
      }
      if (response.statusCode != 200) {
        throw NvrFailure(
          'NVR CGI request failed (${response.statusCode}). Firmware support may differ.',
        );
      }
      return utf8.decode(bytes);
    }
    throw const NvrFailure('NVR authentication could not be completed.');
  }

  void close() => _client.close();
}
