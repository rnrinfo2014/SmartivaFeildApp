import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../domain/discovery.dart';
import 'protocols.dart';

class DiscoveryInterface {
  DiscoveryInterface(this.name, this.address, {this.native});
  final String name;
  final InternetAddress address;
  final NetworkInterface? native;
  String get label => '$name · ${address.address}';
}

abstract class DiscoveryTransport {
  Future<void> open(
    DiscoveryInterface network,
    void Function(Uint8List, String) receive,
    void Function(String) issue,
  );
  void probe(Uint8List dahua, String sadp, String onvif);
  Future<void> close();
}

class UdpDiscoveryTransport implements DiscoveryTransport {
  final List<RawDatagramSocket> _sockets = [];
  final List<StreamSubscription<RawSocketEvent>> _subscriptions = [];
  RawDatagramSocket? _sender;
  bool _locked = false, _closed = false;
  static const _channel = MethodChannel('com.smartiva.fieldops/network');

  @override
  Future<void> open(
    DiscoveryInterface network,
    void Function(Uint8List, String) receive,
    void Function(String) issue,
  ) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('acquireMulticast');
        _locked = true;
      } on PlatformException {
        issue('Wi-Fi multicast lock unavailable. Discovery may be incomplete.');
      }
    }
    if (_closed) {
      await close();
      return;
    }
    void listen(RawDatagramSocket socket) {
      _sockets.add(socket);
      _subscriptions.add(
        socket.listen(
          (event) {
            if (event != RawSocketEvent.read) return;
            Datagram? packet;
            var drained = 0;
            while (drained++ < 64 && (packet = socket.receive()) != null) {
              receive(packet!.data, packet.address.address);
            }
          },
          onError: (Object _) {
            issue('A discovery socket failed. Try the scan again.');
          },
        ),
      );
    }

    _sender = await RawDatagramSocket.bind(network.address, 0);
    if (_closed) {
      _sender!.close();
      return;
    }
    _sender!.broadcastEnabled = true;
    _sender!.multicastHops = 1;
    _sender!.multicastLoopback = false;
    listen(_sender!);
    for (final port in [37810, 37020, 3702]) {
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
          reusePort: true,
        );
        if (_closed) {
          socket.close();
          return;
        }
        listen(socket);
        if (port != 37810) {
          try {
            socket.joinMulticast(
              InternetAddress('239.255.255.250'),
              network.native,
            );
          } on SocketException {
            issue('Multicast replies on port $port could not be enabled.');
          }
        }
      } on SocketException {
        issue('Port $port is busy; listening on the scan source port instead.');
      }
    }
  }

  @override
  void probe(Uint8List dahua, String sadp, String onvif) {
    final socket = _sender;
    if (socket == null || _closed) return;
    final broadcast = InternetAddress('255.255.255.255'),
        multicast = InternetAddress('239.255.255.250');
    socket.send(dahua, broadcast, 37810);
    socket.send(utf8.encode(sadp), multicast, 37020);
    socket.send(utf8.encode(sadp), broadcast, 37020);
    socket.send(utf8.encode(onvif), multicast, 3702);
  }

  @override
  Future<void> close() async {
    _closed = true;
    final sockets = _sockets.toList(), subscriptions = _subscriptions.toList();
    _sockets.clear();
    _subscriptions.clear();
    for (final socket in sockets) {
      socket.close();
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    if (_locked) {
      _locked = false;
      try {
        await _channel.invokeMethod<void>('releaseMulticast');
      } on PlatformException {
        /* native onDestroy also releases */
      }
    }
  }
}

class NetworkDiscovery {
  NetworkDiscovery({DiscoveryTransport Function()? transportFactory})
    : _factory = transportFactory ?? UdpDiscoveryTransport.new;
  final DiscoveryTransport Function() _factory;
  Future<void> Function()? _cancel;
  bool get scanning => _cancel != null;

  static Future<List<DiscoveryInterface>> interfaces() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final result = <DiscoveryInterface>[];
    for (final interface in interfaces) {
      // Exclude common cellular/VPN virtual interfaces. The technician selects
      // the site Wi-Fi interface if a phone has more than one LAN adapter.
      if (RegExp(
        r'^(rmnet|pdp_ip|ccmni|tun|utun|lo|docker)',
        caseSensitive: false,
      ).hasMatch(interface.name)) {
        continue;
      }
      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          result.add(
            DiscoveryInterface(interface.name, address, native: interface),
          );
        }
      }
    }
    result.sort((a, b) {
      int priority(DiscoveryInterface i) =>
          RegExp(r'^(wlan|wifi|en0)', caseSensitive: false).hasMatch(i.name)
          ? 0
          : 1;
      return priority(a).compareTo(priority(b));
    });
    return result;
  }

  Future<DiscoveryReport> scan(
    DiscoveryInterface network, {
    Duration duration = const Duration(seconds: 5),
    void Function(List<NetworkDevice>)? onDevices,
  }) async {
    if (scanning) throw StateError('A scan is already running');
    if (duration <= Duration.zero || duration > const Duration(seconds: 15)) {
      throw ArgumentError('Scan duration must be 0–15 seconds');
    }
    final transport = _factory(), done = Completer<void>();
    final devices = <String, NetworkDevice>{}, issues = <String>{};
    var cancelled = false, packets = 0;
    _cancel = () async {
      cancelled = true;
      if (!done.isCompleted) done.complete();
      await transport.close();
    };
    Timer? repeat, timeout;
    final dahua = dahuaSearch(
      DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
    );
    final uuid = const Uuid().v4();
    void send() {
      try {
        transport.probe(dahua, sadpSearch(uuid), onvifSearch(uuid));
      } on SocketException {
        issues.add('Discovery packets could not be sent on this interface.');
      }
    }

    try {
      await transport
          .open(network, (bytes, source) {
            if (done.isCompleted || ++packets > 2048) return;
            final device = parseDiscovery(bytes, source);
            if (device == null ||
                (!devices.containsKey(source) && devices.length >= 256)) {
              return;
            }
            devices[source] = devices[source]?.merge(device) ?? device;
            onDevices?.call(devices.values.toList());
          }, issues.add)
          .timeout(const Duration(seconds: 5));
      if (!cancelled) {
        send();
        repeat = Timer.periodic(const Duration(seconds: 1), (_) => send());
        timeout = Timer(duration, () => done.complete());
        await done.future;
      }
    } on TimeoutException {
      issues.add('Opening the scan interface timed out.');
    } on SocketException {
      issues.add(
        'Cannot open the selected interface. Connect to site Wi-Fi and retry.',
      );
    } finally {
      repeat?.cancel();
      timeout?.cancel();
      await transport.close();
      _cancel = null;
    }
    return DiscoveryReport(
      devices.values.toList()..sort((a, b) => a.address.compareTo(b.address)),
      issues.toList(),
      cancelled: cancelled,
    );
  }

  Future<void> cancel() async => _cancel?.call();
}
