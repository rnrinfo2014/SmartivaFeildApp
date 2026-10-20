import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../domain/discovery.dart';

Uint8List dahuaSearch(int requestId) {
  final body = utf8.encode(
    jsonEncode({
      'method': 'DHDiscover.search',
      'params': {'mac': '', 'uni': 1},
      'id': requestId,
    }),
  );
  final bytes = Uint8List(32 + body.length), header = ByteData(32);
  header.setUint32(0, 32, Endian.little);
  bytes.setRange(4, 8, ascii.encode('DHIP'));
  header.setUint32(16, body.length, Endian.little);
  header.setUint32(24, body.length, Endian.little);
  for (final offset in [0, 16, 24]) {
    bytes.setRange(offset, offset + 4, header.buffer.asUint8List(offset, 4));
  }
  bytes.setRange(32, bytes.length, body);
  return bytes;
}

String sadpSearch(String uuid) =>
    '<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>$uuid</Uuid><Types>inquiry</Types></Probe>';
String onvifSearch(String uuid) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
<s:Header><a:MessageID>uuid:$uuid</a:MessageID><a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To><a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action></s:Header>
<s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body></s:Envelope>''';

String? cleanText(Object? value) {
  if (value is! String && value is! num) return null;
  final text = value.toString().trim();
  if (text.isEmpty ||
      text.length > 240 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(text) ||
      text.contains('://') ||
      RegExp(
        r'(password|passwd|username|token)\s*[:=]',
        caseSensitive: false,
      ).hasMatch(text)) {
    return null;
  }
  return text;
}

String? normalizedMac(Object? value) {
  final text = value?.toString().replaceAll(RegExp('[:-]'), '').toUpperCase();
  if (text == null ||
      !RegExp(r'^[0-9A-F]{12}$').hasMatch(text) ||
      (text == '000000000000' || text == 'FFFFFFFFFFFF')) {
    return null;
  }
  return List.generate(6, (i) => text.substring(i * 2, i * 2 + 2)).join(':');
}

int? validPort(Object? value) {
  final port = int.tryParse('$value');
  return port != null && port > 0 && port <= 65535 ? port : null;
}

NetworkDevice? parseDiscovery(Uint8List bytes, String source) {
  if (bytes.isEmpty || bytes.length > 65507) return null;
  try {
    final ip = InternetAddress.tryParse(source);
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        ip.rawAddress[0] == 0 ||
        ip.rawAddress[0] >= 224) {
      return null;
    }
    String payload;
    if (bytes.length >= 32 &&
        ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'DHIP') {
      final length = ByteData.sublistView(bytes).getUint32(16, Endian.little);
      final repeated = ByteData.sublistView(bytes).getUint32(24, Endian.little);
      if (length == 0 || length != repeated || length > bytes.length - 32) {
        return null;
      }
      payload = utf8
          .decode(bytes.sublist(32, 32 + length))
          .replaceAll(RegExp(r'\x00+$'), '');
    } else {
      payload = utf8.decode(bytes).trim();
    }
    if (payload.startsWith('{')) return _dahua(payload, source);
    if (!payload.startsWith('<') ||
        RegExp(
          r'<!\s*(DOCTYPE|ENTITY)',
          caseSensitive: false,
        ).hasMatch(payload)) {
      return null;
    }
    final xml = XmlDocument.parse(payload);
    String? rawField(String name) {
      for (final node in xml.descendants.whereType<XmlElement>()) {
        if (node.name.local == name && node.innerText.length <= 8192) {
          return node.innerText.trim();
        }
      }
      return null;
    }

    String? field(String name) => cleanText(rawField(name));
    if (field('DeviceSN') != null && field('IPv4Address') != null) {
      return NetworkDevice(
        address: source,
        protocols: {'SADP'},
        model: field('DeviceType') ?? field('DeviceDescription'),
        serial: field('DeviceSN'),
        mac: normalizedMac(field('MAC')),
        name: field('DeviceDescription'),
        httpPort: validPort(field('HttpPort')) ?? 80,
      );
    }
    if (!xml.descendants.whereType<XmlElement>().any(
      (e) => e.name.local == 'ProbeMatch',
    )) {
      return null;
    }
    var port = 80, https = false;
    // Only use a service URL if its host is the actual datagram source. Never
    // follow arbitrary advertised XAddrs or store their credentials/path/query.
    for (final address in (rawField('XAddrs') ?? '').split(RegExp(r'\s+'))) {
      final uri = Uri.tryParse(address);
      if (uri != null &&
          uri.host == source &&
          uri.userInfo.isEmpty &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        port = validPort(uri.port) ?? 80;
        https = uri.scheme == 'https';
        break;
      }
    }
    String? scope(String kind) {
      for (final value in (rawField('Scopes') ?? '').split(RegExp(r'\s+'))) {
        final marker = '/$kind/';
        if (value.contains(marker)) {
          return cleanText(Uri.decodeComponent(value.split(marker).last));
        }
      }
      return null;
    }

    return NetworkDevice(
      address: source,
      protocols: {'ONVIF'},
      name: scope('name'),
      model: scope('hardware'),
      deviceClass: field('Types'),
      httpPort: port,
      https: https,
    );
  } on FormatException {
    return null;
  } on XmlException {
    return null;
  }
}

NetworkDevice? _dahua(String payload, String source) {
  final data = jsonDecode(payload);
  if (data is! Map || data['params'] is! Map) return null;
  final info = (data['params'] as Map)['deviceInfo'];
  if (info is! Map) return null;
  return NetworkDevice(
    address: source,
    protocols: {'DHIP'},
    model: cleanText(info['DeviceType']),
    serial: cleanText(info['SerialNo'] ?? info['DeviceID']),
    mac: normalizedMac(info['Mac'] ?? info['MAC'] ?? info['mac']),
    name: cleanText(info['MachineName']),
    deviceClass: cleanText(info['DeviceClass']),
    httpPort: validPort(info['HttpPort']) ?? 80,
  );
}
