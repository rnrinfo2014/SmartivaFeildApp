import 'dart:io';

class NetworkDevice {
  NetworkDevice({
    required this.address,
    required this.protocols,
    this.model,
    this.serial,
    this.mac,
    this.name,
    this.deviceClass,
    this.httpPort = 80,
    this.https = false,
  });
  final String address;
  final Set<String> protocols;
  final String? model, serial, mac, name, deviceClass;
  final int httpPort;
  final bool https;

  NetworkDevice merge(NetworkDevice other) {
    final useOther = !https && (other.https || httpPort == 80);
    return NetworkDevice(
      address: address,
      protocols: {...protocols, ...other.protocols},
      model: model ?? other.model,
      serial: serial ?? other.serial,
      mac: mac ?? other.mac,
      name: name ?? other.name,
      deviceClass: deviceClass ?? other.deviceClass,
      httpPort: useOther ? other.httpPort : httpPort,
      https: useOther ? other.https : https,
    );
  }

  Map<String, Object?> toJson() => {
    'address': address,
    'protocols': protocols.toList()..sort(),
    if (model != null) 'model': model,
    if (serial != null) 'serial': serial,
    if (mac != null) 'mac': mac,
    if (name != null) 'name': name,
    if (deviceClass != null) 'device_class': deviceClass,
    'http_port': httpPort,
    'https': https,
  };
}

class DiscoveryReport {
  DiscoveryReport(this.devices, this.issues, {this.cancelled = false});
  final List<NetworkDevice> devices;
  final List<String> issues;
  final bool cancelled;
  Map<String, Object?> toJson() => {
    'devices': devices.map((d) => d.toJson()).toList(),
    'issues': issues,
    'cancelled': cancelled,
  };
}

class NvrTarget {
  NvrTarget(String address, {this.port = 80, this.https = false})
    : address = _validate(address) {
    if (port < 1 || port > 65535) {
      throw const FormatException('Enter a valid port (1–65535).');
    }
  }
  final String address;
  final int port;
  final bool https;
  static String _validate(String value) {
    final ip = InternetAddress.tryParse(value.trim());
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        ip.rawAddress[0] == 0 ||
        ip.rawAddress[0] >= 224 ||
        ip.address == '255.255.255.255') {
      throw const FormatException(
        'Enter a numeric unicast IPv4 address for the NVR.',
      );
    }
    return ip.address;
  }

  Uri endpoint(String path, Map<String, String> query) => Uri(
    scheme: https ? 'https' : 'http',
    host: address,
    port: port,
    path: path,
    queryParameters: query,
  );
  String get origin => '${https ? 'https' : 'http'}://$address:$port';
}

class RemoteCamera {
  RemoteCamera({
    required this.slot,
    this.localChannel,
    this.ip,
    this.hostname,
    this.serial,
    this.mac,
    this.brand,
    this.model,
  });
  final int slot;
  // Explicit LocalChannel from vendor configuration, normalized from 0-based.
  final int? localChannel;
  final String? ip, hostname, serial, mac, brand, model;
  Map<String, Object?> toJson() => {
    'slot': slot,
    'channel_no': localChannel,
    'ip_address': ip,
    'hostname': hostname,
    'serial_number': serial,
    'mac_address': mac,
    'brand': brand,
    'model': model,
  };
}

class NvrSnapshot {
  NvrSnapshot({
    required this.target,
    required this.model,
    required this.serial,
    required this.cameras,
    required this.warnings,
    this.channelCapacity,
    this.credentialRef,
  });
  factory NvrSnapshot.fromJson(Map<String, dynamic> data) {
    final uri = Uri.parse(data['origin'] as String);
    return NvrSnapshot(
      target: NvrTarget(uri.host, port: uri.port, https: uri.scheme == 'https'),
      model: data['model'] as String?,
      serial: data['serial'] as String?,
      channelCapacity: data['channel_capacity'] as int?,
      cameras: (data['cameras'] as List).map((value) {
        final row = value as Map<String, dynamic>;
        return RemoteCamera(
          slot: row['slot'] as int,
          localChannel: row['channel_no'] as int?,
          ip: row['ip_address'] as String?,
          hostname: row['hostname'] as String?,
          serial: row['serial_number'] as String?,
          mac: row['mac_address'] as String?,
          brand: row['brand'] as String?,
          model: row['model'] as String?,
        );
      }).toList(),
      warnings: (data['warnings'] as List).cast<String>(),
    );
  }
  final NvrTarget target;
  final String? model, serial, credentialRef;
  final int? channelCapacity;
  final List<RemoteCamera> cameras;
  final List<String> warnings;
  Map<String, Object?> toJson() => {
    'origin': target.origin,
    'model': model,
    'serial': serial,
    'channel_capacity': channelCapacity,
    'cameras': cameras.map((c) => c.toJson()).toList(),
    'warnings': warnings,
  }; // Credentials and credential references never enter evidence.
}
