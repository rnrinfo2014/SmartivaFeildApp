import 'dart:convert';
import 'dart:io';

import '../../domain/discovery.dart';
import 'protocols.dart';

class CgiInventory {
  CgiInventory(
    this.model,
    this.serial,
    this.capacity,
    this.cameras,
    this.warnings,
  );
  final String? model, serial;
  final int? capacity;
  final List<RemoteCamera> cameras;
  final List<String> warnings;
}

CgiInventory parseCgiInventory(String systemInfo, String remoteConfig) {
  if (systemInfo.length > 1024 * 1024 ||
      remoteConfig.length > 2 * 1024 * 1024) {
    throw const FormatException('NVR response exceeded the supported size.');
  }
  final system = <String, String>{};
  for (final line in const LineSplitter().convert(systemInfo)) {
    final separator = line.indexOf('=');
    if (separator < 1) continue;
    system[line.substring(0, separator).trim().toLowerCase()] = line
        .substring(separator + 1)
        .trim();
  }
  if ([
    'IPC',
    'CAMERA',
    'IPCAMERA',
  ].contains(system['deviceclass']?.toUpperCase())) {
    throw const FormatException(
      'This device identifies itself as a camera, not an NVR/DVR.',
    );
  }
  final model = cleanText(system['devicetype'] ?? system['model']),
      serial = cleanText(system['serialnumber'] ?? system['serialno']);
  if (model == null && serial == null) {
    throw const FormatException(
      'System info is not a supported Dahua/CP Plus CGI response.',
    );
  }
  int? capacity;
  for (final key in [
    'videoinputchannels',
    'videoinchannels',
    'channelcapacity',
  ]) {
    final count = int.tryParse(system[key] ?? '');
    if (count != null && count >= 0 && count <= 100000) {
      capacity = count;
      break;
    }
  }
  final entries = <int, Map<String, String>>{};
  final pattern = RegExp(
    r'^(?:table\.)?RemoteDevice\[(\d+)\]\.([A-Za-z0-9_]+)\s*=\s*(.*)$',
  );
  var recognized = false, disabled = 0, blank = 0;
  for (final line in const LineSplitter().convert(remoteConfig)) {
    final match = pattern.firstMatch(line.trim());
    if (match == null) continue;
    final slot = int.tryParse(match[1]!);
    if (slot == null || slot > 4095) {
      throw const FormatException(
        'NVR remote-device index exceeds supported limits.',
      );
    }
    final key = match[2]!.toLowerCase();
    // Passwords, usernames, RTSP URLs and arbitrary vendor fields are discarded.
    if (!const {
      'address',
      'enable',
      'localchannel',
      'serialno',
      'serialnumber',
      'mac',
      'macaddress',
      'manufacturer',
      'devicetype',
      'model',
      'videoinputchannels',
    }.contains(key)) {
      continue;
    }
    recognized = true;
    final fields = entries.putIfAbsent(slot, () => {});
    final value = match[3]!.trim();
    if (fields.containsKey(key) && fields[key] != value) {
      throw const FormatException(
        'NVR returned conflicting remote-device fields.',
      );
    }
    fields[key] = value;
  }
  final explicitlyEmpty = RegExp(
    r'^(?:table\.)?RemoteDevice\s*=\s*(?:\[\]|\{\})\s*$',
    multiLine: true,
  ).hasMatch(remoteConfig.trim());
  if (!recognized && !explicitlyEmpty) {
    throw const FormatException(
      'RemoteDevice CGI is unsupported or access was denied. No camera records were changed.',
    );
  }
  final cameras = <RemoteCamera>[], warnings = <String>[];
  final channels = <int>{}, serials = <String>{}, macs = <String>{};
  for (final slot in entries.keys.toList()..sort()) {
    final item = entries[slot]!;
    if (item['enable']?.toLowerCase() == 'false' || item['enable'] == '0') {
      disabled++;
      continue;
    }
    if (item['videoinputchannels'] != null &&
        int.tryParse(item['videoinputchannels']!) != 1) {
      throw const FormatException(
        'Multi-input remote devices require manual camera mapping.',
      );
    }
    final address = cleanText(item['address']);
    final parsed = address == null ? null : InternetAddress.tryParse(address);
    final serial = cleanText(item['serialnumber'] ?? item['serialno']);
    final mac = normalizedMac(item['macaddress'] ?? item['mac']);
    if (address == null && serial == null && mac == null) {
      blank++;
      continue;
    }
    int? channel;
    if (item['localchannel'] != null) {
      final raw = int.tryParse(item['localchannel']!);
      if (raw == null || raw < 0 || raw >= 100000) {
        throw const FormatException('NVR returned an invalid LocalChannel.');
      }
      channel = raw + 1;
      if (!channels.add(channel)) {
        throw const FormatException(
          'NVR returned duplicate local camera channels.',
        );
      }
    }
    if ((serial != null && !serials.add(serial)) ||
        (mac != null && !macs.add(mac))) {
      throw const FormatException(
        'A remote device appears more than once. Multi-channel remote sources require manual mapping.',
      );
    }
    cameras.add(
      RemoteCamera(
        slot: slot,
        localChannel: channel,
        ip: parsed?.address,
        hostname: parsed == null ? address : null,
        serial: serial,
        mac: mac,
        brand: cleanText(item['manufacturer']),
        model: cleanText(item['devicetype'] ?? item['model']),
      ),
    );
  }
  if (disabled > 0) {
    warnings.add(
      '$disabled disabled remote entries excluded. Existing cameras are retained.',
    );
  }
  if (blank > 0) {
    warnings.add('$blank empty or unidentified remote slots excluded.');
  }
  if (cameras.any((c) => c.localChannel == null)) {
    warnings.add(
      'Some channel mappings are unknown. Remote table index is not assumed to be the NVR channel.',
    );
  }
  warnings.add(
    'RemoteDevice is configured inventory, not live camera health. Status remains unknown unless already documented.',
  );
  return CgiInventory(model, serial, capacity, cameras, warnings);
}
