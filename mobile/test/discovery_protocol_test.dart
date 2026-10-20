import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartiva_fieldops/services/discovery/protocols.dart';
import 'package:smartiva_fieldops/domain/discovery.dart';
import 'package:smartiva_fieldops/services/discovery/network_discovery.dart';

Uint8List dhipReply({String serial = 'NVR-SERIAL'}) {
  final body = utf8.encode(
    jsonEncode({
      'params': {
        'deviceInfo': {
          'DeviceType': 'NVR-TEST',
          'SerialNo': serial,
          'DeviceClass': 'NVR',
          'HttpPort': 8080,
          'mac': 'aa-bb-cc-dd-ee-ff',
          'IPv4Address': {'IPAddress': '203.0.113.10'},
        },
      },
    }),
  );
  final bytes = Uint8List(32 + body.length);
  bytes.setRange(4, 8, ascii.encode('DHIP'));
  ByteData.sublistView(bytes).setUint32(16, body.length, Endian.little);
  ByteData.sublistView(bytes).setUint32(24, body.length, Endian.little);
  bytes.setRange(32, bytes.length, body);
  return bytes;
}

class FakeDiscoveryTransport implements DiscoveryTransport {
  FakeDiscoveryTransport({this.gate, this.fail = false, this.flood = false});
  final Completer<void>? gate;
  final bool fail, flood;
  late void Function(Uint8List, String) receive;
  bool closed = false;
  @override
  Future<void> open(
    DiscoveryInterface network,
    void Function(Uint8List, String) receive,
    void Function(String) issue,
  ) async {
    this.receive = receive;
    if (fail) throw const SocketException('test failure');
    await gate?.future;
  }

  @override
  void probe(Uint8List dahua, String sadp, String onvif) {
    expect(dahua.sublist(4, 8), ascii.encode('DHIP'));
    expect(sadp, contains('<Types>inquiry</Types>'));
    expect(onvif, contains('NetworkVideoTransmitter'));
    receive(dhipReply(), '192.168.1.10');
    receive(dhipReply(), '192.168.1.10');
    if (flood) {
      for (var i = 0; i < 300; i++) {
        receive(
          dhipReply(serial: 'S$i'),
          '192.168.${i ~/ 250 + 1}.${i % 250 + 1}',
        );
      }
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test(
    'DHIP frame has the expected binary header and duplicated body lengths',
    () {
      final bytes = dahuaSearch(7), header = ByteData.sublistView(bytes);
      expect(header.getUint32(0, Endian.little), 32);
      expect(ascii.decode(bytes.sublist(4, 8)), 'DHIP');
      expect(header.getUint32(16, Endian.little), bytes.length - 32);
      expect(header.getUint32(24, Endian.little), bytes.length - 32);
      final json = jsonDecode(utf8.decode(bytes.sublist(32))) as Map;
      expect(json['method'], 'DHDiscover.search');
      expect(json['id'], 7);
    },
  );
  test(
    'DHIP metadata is parsed but advertised address cannot replace datagram source',
    () {
      final device = parseDiscovery(dhipReply(), '192.168.1.10')!;
      expect(device.address, '192.168.1.10');
      expect(device.httpPort, 8080);
      expect(device.serial, 'NVR-SERIAL');
      expect(device.mac, 'AA:BB:CC:DD:EE:FF');
    },
  );
  test('merged HTTPS metadata keeps its matching port', () {
    final first = NetworkDevice(
      address: '192.168.1.10',
      protocols: {'DHIP'},
      httpPort: 8080,
    );
    final second = NetworkDevice(
      address: '192.168.1.10',
      protocols: {'ONVIF'},
      httpPort: 8443,
      https: true,
    );
    final merged = first.merge(second);
    expect(merged.https, isTrue);
    expect(merged.httpPort, 8443);
  });
  test('SADP discovery response does not require credentials', () {
    final device = parseDiscovery(
      Uint8List.fromList(
        utf8.encode('''<?xml version="1.0"?><ProbeMatch>
      <DeviceType>DS-NVR</DeviceType><DeviceSN>HIK-SN</DeviceSN><IPv4Address>192.168.0.99</IPv4Address>
      <MAC>aa-bb-cc-dd-ee-ff</MAC><HttpPort>81</HttpPort></ProbeMatch>'''),
      ),
      '192.168.1.11',
    )!;
    expect(device.protocols, {'SADP'});
    expect(device.serial, 'HIK-SN');
    expect(device.httpPort, 81);
    expect(device.address, '192.168.1.11');
  });
  test(
    'ONVIF parses namespaced matches and only trusts source-host web metadata',
    () {
      final packet =
          '''<e:Envelope xmlns:e="urn:soap" xmlns:d="urn:discovery"><e:Body><d:ProbeMatches><d:ProbeMatch>
      <d:Types>dn:NetworkVideoTransmitter</d:Types><d:XAddrs>https://192.168.1.12:8443/onvif/device_service</d:XAddrs>
      <d:Scopes>onvif://www.onvif.org/name/Office%20NVR onvif://www.onvif.org/hardware/ModelA</d:Scopes>
      </d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>''';
      final device = parseDiscovery(
        Uint8List.fromList(utf8.encode(packet)),
        '192.168.1.12',
      )!;
      expect(device.name, 'Office NVR');
      expect(device.model, 'ModelA');
      expect(device.https, isTrue);
      expect(device.httpPort, 8443);
      final poisoned = packet.replaceAll(
        '192.168.1.12:8443',
        'user:password@203.0.113.5:9999',
      );
      final safe = parseDiscovery(
        Uint8List.fromList(utf8.encode(poisoned)),
        '192.168.1.12',
      )!;
      expect(safe.address, '192.168.1.12');
      expect(safe.httpPort, 80);
      expect(safe.toJson().toString(), isNot(contains('password')));
    },
  );
  test('malformed, oversize and entity-bearing packets fail closed', () {
    final invalid = dhipReply();
    ByteData.sublistView(invalid).setUint32(16, 999999, Endian.little);
    for (final packet in [
      invalid,
      Uint8List.fromList([255, 254]),
      Uint8List(65508),
      Uint8List.fromList(
        utf8.encode(
          '<!DOCTYPE foo [<!ENTITY x SYSTEM "file:///etc/passwd">]><foo>&x;</foo>',
        ),
      ),
    ]) {
      expect(parseDiscovery(packet, '192.168.1.10'), isNull);
    }
  });
  test('scan deduplicates replies and closes transport', () async {
    final transport = FakeDiscoveryTransport(),
        engine = NetworkDiscovery(transportFactory: () => transport);
    final report = await engine.scan(
      DiscoveryInterface('wifi', InternetAddress('192.168.1.2')),
      duration: const Duration(milliseconds: 20),
    );
    expect(report.devices.length, 1);
    expect(transport.closed, isTrue);
    expect(engine.scanning, isFalse);
  });
  test(
    'scan bounds device count and reports an unavailable interface',
    () async {
      final engine = NetworkDiscovery(
        transportFactory: () => FakeDiscoveryTransport(flood: true),
      );
      final report = await engine.scan(
        DiscoveryInterface('wifi', InternetAddress('192.168.1.2')),
        duration: const Duration(milliseconds: 20),
      );
      expect(report.devices.length, 256);
      final failed = await NetworkDiscovery(
        transportFactory: () => FakeDiscoveryTransport(fail: true),
      ).scan(DiscoveryInterface('wifi', InternetAddress('192.168.1.2')));
      expect(failed.issues, isNotEmpty);
    },
  );
  test(
    'cancellation while opening closes sockets and returns a partial report',
    () async {
      final gate = Completer<void>(),
          transport = FakeDiscoveryTransport(gate: gate);
      final engine = NetworkDiscovery(transportFactory: () => transport);
      final running = engine.scan(
        DiscoveryInterface('wifi', InternetAddress('192.168.1.2')),
      );
      await engine.cancel();
      gate.complete();
      final report = await running;
      expect(report.cancelled, isTrue);
      expect(transport.closed, isTrue);
    },
  );
}
