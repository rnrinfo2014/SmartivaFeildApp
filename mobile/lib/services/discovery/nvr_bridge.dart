import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../domain/discovery.dart';
import 'cgi_parser.dart';
import 'digest_client.dart';

class NvrBridge {
  NvrDigestClient? _active;
  void cancel() => _active?.close();
  Future<NvrSnapshot> fetch(
    NvrTarget target,
    String username,
    String password, {
    http.Client? client,
  }) async {
    if (_active != null) {
      throw const NvrFailure('An NVR request is already running.');
    }
    final session = NvrDigestClient(target, username, password, client: client);
    _active = session;
    try {
      final system = await session.get('/cgi-bin/magicBox.cgi', {
        'action': 'getSystemInfo',
      });
      final config = await session.get('/cgi-bin/configManager.cgi', {
        'action': 'getConfig',
        'name': 'RemoteDevice',
      });
      final parsed = parseCgiInventory(system, config);
      return NvrSnapshot(
        target: target,
        model: parsed.model,
        serial: parsed.serial,
        channelCapacity: parsed.capacity,
        cameras: parsed.cameras,
        warnings: parsed.warnings,
      );
    } finally {
      session.close();
      _active = null;
    }
  }
}

class NvrCredentials {
  NvrCredentials(this.username, this.password);
  final String username, password;
}

class NvrCredentialStore {
  NvrCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  String reference(String siteId, NvrTarget target) =>
      'nvr_${sha256.convert(utf8.encode('$siteId|${target.origin}'))}';
  Future<String> save(
    String siteId,
    NvrTarget target,
    String username,
    String password,
  ) async {
    final key = reference(siteId, target);
    await _storage.write(
      key: key,
      value: jsonEncode({'username': username, 'password': password}),
    );
    return key;
  }

  Future<NvrCredentials?> load(String siteId, NvrTarget target) async {
    final value = await _storage.read(key: reference(siteId, target));
    if (value == null) return null;
    try {
      final data = jsonDecode(value);
      if (data is! Map ||
          data['username'] is! String ||
          data['password'] is! String) {
        return null;
      }
      return NvrCredentials(
        data['username'] as String,
        data['password'] as String,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> forget(String siteId, NvrTarget target) =>
      _storage.delete(key: reference(siteId, target));
}
