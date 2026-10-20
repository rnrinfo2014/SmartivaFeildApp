import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/field_repository.dart';
import '../domain/briefing.dart';
import '../domain/discovery.dart';
import '../services/discovery/network_discovery.dart';
import 'common.dart';
import 'nvr_connection_screen.dart';
import 'nvr_review_screen.dart';

class NetworkScanScreen extends StatefulWidget {
  const NetworkScanScreen({
    super.key,
    required this.repository,
    required this.siteId,
  });
  final FieldRepository repository;
  final String siteId;
  @override
  State<NetworkScanScreen> createState() => _NetworkScanScreenState();
}

class _NetworkScanScreenState extends State<NetworkScanScreen>
    with WidgetsBindingObserver {
  final _scanner = NetworkDiscovery();
  List<DiscoveryInterface> _interfaces = [];
  DiscoveryInterface? _selected;
  List<NetworkDevice> _devices = [];
  List<Json> _snapshots = [];
  List<String> _issues = [];
  bool _loading = true, _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      List<DiscoveryInterface> networks = [];
      final interfaceIssues = <String>[];
      try {
        networks = await NetworkDiscovery.interfaces();
      } catch (_) {
        interfaceIssues.add(
          'Interface access is unavailable. Saved inventories and manual NVR access remain available.',
        );
      }
      final snapshots = await widget.repository.snapshots(widget.siteId);
      final scans = await widget.repository.db.query(
        'network_scans',
        where: 'site_id=?',
        whereArgs: [widget.siteId],
        orderBy: 'observed_at DESC',
        limit: 1,
      );
      final devices = <NetworkDevice>[];
      if (scans.isNotEmpty) {
        for (final row in rows(
          object(jsonDecode(scans.single['payload'] as String)),
          'devices',
        )) {
          devices.add(
            NetworkDevice(
              address: row['address'] as String,
              protocols: (row['protocols'] as List).cast<String>().toSet(),
              model: row['model'] as String?,
              serial: row['serial'] as String?,
              mac: row['mac'] as String?,
              name: row['name'] as String?,
              deviceClass: row['device_class'] as String?,
              httpPort: row['http_port'] as int,
              https: row['https'] as bool,
            ),
          );
        }
      }
      if (mounted) {
        setState(() {
          _interfaces = networks;
          _selected =
              networks.where((n) => n.label == _selected?.label).firstOrNull ??
              networks.firstOrNull;
          _issues = interfaceIssues;
          _snapshots = snapshots;
          _devices = devices;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  Future<void> _scan() async {
    if (_selected == null || _scanning) return;
    setState(() {
      _scanning = true;
      _devices = [];
      _issues = [];
    });
    try {
      final report = await _scanner.scan(
        _selected!,
        onDevices: (devices) {
          if (mounted) setState(() => _devices = devices);
        },
      );
      await widget.repository.saveDiscovery(widget.siteId, report);
      if (mounted) {
        setState(() {
          _devices = report.devices;
          _issues = report.issues;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect([NetworkDevice? device]) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => NvrConnectionScreen(
          repository: widget.repository,
          siteId: widget.siteId,
          device: device,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_scanner.cancel());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_scanner.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Site network')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Discover. Review. Remember.',
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Connect to the site Wi-Fi. Discovery needs no device password or internet. Saved results stay available offline.',
              ),
              const SizedBox(height: 20),
              if (_interfaces.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(_selected?.label),
                  initialValue: _selected?.label,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Site Wi-Fi interface',
                  ),
                  items: [
                    for (final network in _interfaces)
                      DropdownMenuItem(
                        value: network.label,
                        child: Text(
                          network.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _scanning
                      ? null
                      : (value) => setState(
                          () => _selected = _interfaces.firstWhere(
                            (n) => n.label == value,
                          ),
                        ),
                ),
              if (_interfaces.isEmpty)
                const Text(
                  'No LAN interface found. Connect to site Wi-Fi, then refresh. You can also enter an NVR address manually.',
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _scanning
                        ? () => _scanner.cancel()
                        : _selected == null
                        ? null
                        : _scan,
                    icon: Icon(_scanning ? Icons.stop : Icons.wifi_find),
                    label: Text(_scanning ? 'Stop scan' : 'Auto-scan network'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _scanning ? null : () => _connect(),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Enter NVR IP'),
                  ),
                  IconButton(
                    tooltip: 'Refresh interfaces',
                    onPressed: _scanning ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (_scanning)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              for (final issue in _issues)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    issue,
                    style: const TextStyle(color: Colors.deepOrange),
                  ),
                ),
              const SizedBox(height: 20),
              Text(
                'DEVICES  ·  ${_devices.length}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text(
                'Results are observations, not proof of device identity. Open a recorder to verify its serial and camera configuration.',
                style: TextStyle(fontSize: 12),
              ),
              if (!_scanning && _devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No discovery replies yet. Wi-Fi client isolation, local-network permission or firmware settings may prevent replies. Try a manual NVR address.',
                  ),
                ),
              for (final device in _devices)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.router_outlined),
                    title: Text(device.name ?? device.model ?? device.address),
                    subtitle: Text(
                      '${device.address} · ${device.protocols.join(' / ')}\n${device.serial ?? device.deviceClass ?? 'Identity not yet verified'}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _scanning ? null : () => _connect(device),
                  ),
                ),
              const SizedBox(height: 22),
              const Text(
                'SAVED NVR INVENTORIES',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final row in _snapshots)
                Card(
                  child: ListTile(
                    leading: Icon(
                      row['imported_asset_id'] == null
                          ? Icons.pending_actions
                          : Icons.offline_pin_outlined,
                    ),
                    title: Text(
                      object(jsonDecode(row['payload'] as String))['model']
                              as String? ??
                          'NVR inventory',
                    ),
                    subtitle: Text(
                      '${row['observed_at']}\n${row['imported_asset_id'] == null ? 'Ready for offline review' : 'Imported on this device'}',
                    ),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => NvrReviewScreen(
                            repository: widget.repository,
                            snapshotId: row['id'] as String,
                          ),
                        ),
                      );
                      if (mounted) await _load();
                    },
                  ),
                ),
            ],
          ),
  );
}
