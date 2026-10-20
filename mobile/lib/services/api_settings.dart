import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiSettings {
  ApiSettings(this.baseUrl, this.token);
  final Uri baseUrl;
  final String token;

  factory ApiSettings.parse(String url, String token) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.port <= 0 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Enter only the API origin, e.g. https://fieldops.example.com',
      );
    }
    final ip = InternetAddress.tryParse(uri.host);
    final bytes = ip?.rawAddress;
    final privateHost =
        uri.host == 'localhost' ||
        (ip?.isLoopback ?? false) ||
        (ip?.type == InternetAddressType.IPv4 &&
            bytes != null &&
            (bytes[0] == 10 ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)));
    if (uri.scheme != 'https' &&
        !(kDebugMode && uri.scheme == 'http' && privateHost)) {
      throw const FormatException(
        'Use HTTPS. Debug builds also allow HTTP to a local development host.',
      );
    }
    if (token.trim().length < 32 ||
        RegExp(r'[\x00-\x20\x7F]').hasMatch(token.trim())) {
      throw const FormatException(
        'Enter the administrator-issued device token (32+ characters).',
      );
    }
    return ApiSettings(uri.replace(path: ''), token.trim());
  }
}

class ApiSettingsStore {
  ApiSettingsStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  Future<ApiSettings?> load() async {
    final stored = await _storage.read(key: 'smartiva_api');
    if (stored == null) return null;
    // A single secure entry makes a URL/token update atomic from the app's view.
    final split = stored.indexOf('\n');
    if (split < 0) return null;
    try {
      return ApiSettings.parse(
        stored.substring(0, split),
        stored.substring(split + 1),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> save(ApiSettings value) => _storage.write(
    key: 'smartiva_api',
    value: '${value.baseUrl}\n${value.token}',
  );
  Future<void> clear() => _storage.delete(key: 'smartiva_api');
}
