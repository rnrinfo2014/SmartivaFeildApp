import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartiva_fieldops/domain/discovery.dart';
import 'package:smartiva_fieldops/services/discovery/digest_client.dart';
import 'package:smartiva_fieldops/services/discovery/cgi_parser.dart';
import 'package:smartiva_fieldops/services/discovery/nvr_bridge.dart';

const system =
    'deviceType=NVR-TEST\nserialNumber=NVR-SN1\nvideoInputChannels=64\n';
const config = '''table.RemoteDevice[0].Address=10.1.1.10
table.RemoteDevice[0].Enable=true
table.RemoteDevice[0].LocalChannel=0
table.RemoteDevice[0].SerialNo=CAM-1
table.RemoteDevice[0].MacAddress=aa:bb:cc:dd:ee:01
table.RemoteDevice[0].Manufacturer=Dahua
table.RemoteDevice[0].UserName=PRIVATE-USERNAME
table.RemoteDevice[0].Password=PRIVATE-PASSWORD
table.RemoteDevice[3].Address=10.1.1.11
table.RemoteDevice[3].Enable=true
table.RemoteDevice[3].SerialNo=CAM-2
table.RemoteDevice[4].Address=10.1.1.12
table.RemoteDevice[4].Enable=false
''';
const challenge =
    'Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"';
void main() {
  test('Digest matches RFC 2617 known response vector', () {
    final header = DigestChallenge.parse(challenge).authorization(
      username: 'Mufasa',
      password: 'Circle Of Life',
      method: 'GET',
      uri: '/dir/index.html',
      cnonce: '0a4f113b',
      count: 1,
    );
    expect(header, contains('response="6629fae49393a05397450978507c4ef1"'));
    expect(header, contains('nc=00000001'));
    expect(header, contains('qop=auth'));
    expect(header, isNot(contains('Circle Of Life')));
  });
  test('Digest challenge can precede a Basic alternative', () {
    final parsed = DigestChallenge.parse('$challenge, Basic realm="other"');
    expect(parsed.realm, 'testrealm@host.com');
  });
  test('Digest nonce count advances across both CGI endpoints', () async {
    var calls = 0;
    final client = NvrDigestClient(
      NvrTarget('192.168.1.10'),
      'admin',
      'PRIVATE',
      client: MockClient((request) async {
        calls++;
        expect(request.followRedirects, isFalse);
        if (calls == 1) {
          expect(request.headers['authorization'], isNull);
          return http.Response(
            '',
            401,
            headers: {'www-authenticate': challenge},
          );
        }
        expect(
          request.headers['authorization'],
          contains(calls == 2 ? 'nc=00000001' : 'nc=00000002'),
        );
        return http.Response('ok', 200);
      }),
      cnonce: () => 'cnonce',
    );
    try {
      await client.get('/one', {'action': 'one'});
      await client.get('/two', {'action': 'two'});
    } finally {
      client.close();
    }
    expect(calls, 3);
  });
  test(
    'bad credentials stop after one authenticated attempt; Basic is refused',
    () async {
      for (final offered in [challenge, 'Basic realm="NVR"']) {
        var calls = 0;
        final client = NvrDigestClient(
          NvrTarget('192.168.1.10'),
          'admin',
          'PRIVATE',
          client: MockClient((_) async {
            calls++;
            return http.Response(
              '',
              401,
              headers: {'www-authenticate': offered},
            );
          }),
        );
        try {
          await expectLater(client.get('/cgi', {}), throwsA(isA<NvrFailure>()));
        } finally {
          client.close();
        }
        expect(calls, offered == challenge ? 2 : 1);
      }
    },
  );
  test('stale nonce can refresh once and resets nonce count', () async {
    var calls = 0;
    final client = NvrDigestClient(
      NvrTarget('192.168.1.10'),
      'admin',
      'PRIVATE',
      client: MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            401,
            headers: {'www-authenticate': challenge},
          );
        }
        if (calls == 2) {
          return http.Response(
            '',
            401,
            headers: {
              'www-authenticate':
                  'Digest realm="testrealm@host.com",nonce="new",qop="auth",stale=true',
            },
          );
        }
        expect(request.headers['authorization'], contains('nonce="new"'));
        expect(request.headers['authorization'], contains('nc=00000001'));
        return http.Response('ok', 200);
      }),
    );
    try {
      expect(await client.get('/cgi', {}), 'ok');
    } finally {
      client.close();
    }
    expect(calls, 3);
  });
  test('Digest supports SHA-256 but rejects unsupported qop', () {
    final header =
        DigestChallenge.parse(
          'Digest realm="r",nonce="n",algorithm=SHA-256,qop="auth"',
        ).authorization(
          username: 'u',
          password: 'p',
          method: 'GET',
          uri: '/cgi',
          cnonce: 'c',
          count: 1,
        );
    expect(header, contains('algorithm=SHA-256'));
    expect(RegExp(r'response="[a-f0-9]{64}"').hasMatch(header), isTrue);
    expect(
      () => DigestChallenge.parse('Digest realm="r",nonce="n",qop="auth-int"'),
      throwsA(isA<NvrFailure>()),
    );
  });
  test(
    'redirects, bounded responses and request deadlines fail safely',
    () async {
      for (final status in [302, 403, 500]) {
        final client = NvrDigestClient(
          NvrTarget('192.168.1.10'),
          'admin',
          'PRIVATE',
          client: MockClient(
            (_) async => http.Response(
              '',
              status,
              headers: {'location': 'http://elsewhere/'},
            ),
          ),
        );
        try {
          await expectLater(client.get('/cgi', {}), throwsA(isA<NvrFailure>()));
        } finally {
          client.close();
        }
      }
      final large = NvrDigestClient(
        NvrTarget('192.168.1.10'),
        'admin',
        'PRIVATE',
        client: MockClient(
          (_) async => http.Response('x' * (2 * 1024 * 1024 + 1), 200),
        ),
      );
      try {
        await expectLater(large.get('/cgi', {}), throwsA(isA<NvrFailure>()));
      } finally {
        large.close();
      }
      final slow = NvrDigestClient(
        NvrTarget('192.168.1.10'),
        'admin',
        'PRIVATE',
        requestTimeout: const Duration(milliseconds: 10),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response('ok', 200);
        }),
      );
      try {
        await expectLater(slow.get('/cgi', {}), throwsA(isA<NvrFailure>()));
      } finally {
        slow.close();
      }
    },
  );
  test(
    'CGI inventory includes isolated NIC cameras without leaking secrets or guessing channels',
    () {
      final parsed = parseCgiInventory(system, config);
      expect(parsed.cameras.length, 2);
      expect(parsed.capacity, 64);
      expect(parsed.cameras.first.ip, '10.1.1.10');
      expect(parsed.cameras.first.localChannel, 1);
      expect(parsed.cameras.last.slot, 3);
      expect(parsed.cameras.last.localChannel, isNull);
      final json = jsonEncode(parsed.cameras.map((c) => c.toJson()).toList());
      expect(json, isNot(contains('PRIVATE')));
      expect(json, isNot(contains('Password')));
    },
  );
  test(
    'unsupported, duplicate and ambiguous multi-channel responses are rejected',
    () {
      for (final data in [
        'Error: access denied',
        '$config\ntable.RemoteDevice[0].VideoInputChannels=2',
        'table.RemoteDevice[0].Password=PRIVATE',
        '$config\ntable.RemoteDevice[3].LocalChannel=0',
        config.replaceAll('CAM-2', 'CAM-1'),
      ]) {
        expect(() => parseCgiInventory(system, data), throwsFormatException);
      }
      expect(
        parseCgiInventory(system, 'table.RemoteDevice=[]').cameras,
        isEmpty,
      );
    },
  );
  test(
    'bridge only queries the NVR host, even when cameras use another subnet',
    () async {
      final calls = <Uri>[];
      final result = await NvrBridge().fetch(
        NvrTarget('192.168.1.10'),
        'admin',
        'PRIVATE',
        client: MockClient((request) async {
          calls.add(request.url);
          return http.Response(
            request.url.path.endsWith('magicBox.cgi') ? system : config,
            200,
          );
        }),
      );
      expect(calls.length, 2);
      expect(calls.every((uri) => uri.host == '192.168.1.10'), isTrue);
      expect(calls.last.queryParameters, {
        'action': 'getConfig',
        'name': 'RemoteDevice',
      });
      expect(jsonEncode(result.toJson()), isNot(contains('PRIVATE')));
    },
  );
}
