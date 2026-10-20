import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/field_repository.dart';
import '../domain/briefing.dart';
import '../domain/discovery.dart';
import 'common.dart';

class NvrReviewScreen extends StatefulWidget {
  const NvrReviewScreen({
    super.key,
    required this.repository,
    required this.snapshotId,
  });
  final FieldRepository repository;
  final String snapshotId;
  @override
  State<NvrReviewScreen> createState() => _NvrReviewScreenState();
}

class _NvrReviewScreenState extends State<NvrReviewScreen> {
  NvrSnapshot? _snapshot;
  List<Json> _recorders = [], _zones = [];
  String? _existingId, _brand, _zone;
  bool _indexChannels = false, _busy = false, _imported = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stored = (await widget.repository.db.query(
        'nvr_snapshots',
        where: 'id=?',
        whereArgs: [widget.snapshotId],
      )).single;
      final snapshot = NvrSnapshot.fromJson(
        object(jsonDecode(stored['payload'] as String)),
      );
      final recorders = await widget.repository.localRecorders(
        stored['site_id'] as String,
      );
      final zones = await widget.repository.db.rawQuery(
        '''SELECT z.id,z.zone_name,f.name AS floor_name FROM floors_and_zones z
        JOIN floors f ON f.id=z.floor_id AND f.site_id=z.site_id WHERE z.site_id=? AND z.deleted_at IS NULL AND f.deleted_at IS NULL''',
        [stored['site_id']],
      );
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _recorders = recorders;
          _zones = zones;
          _imported = stored['imported_asset_id'] != null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load this saved inventory.');
      }
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.importSnapshot(
        widget.snapshotId,
        existingNvrId: _existingId,
        useSlotChannels: _indexChannels,
        brand: _brand,
        zoneId: _zone,
      );
      if (mounted) setState(() => _imported = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(title: const Text('Review NVR inventory')),
      body: snapshot == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  snapshot.model ?? 'Recorder',
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${snapshot.target.origin}\nSerial: ${snapshot.serial ?? 'not provided'}\n${snapshot.cameras.length} configured remote cameras',
                ),
                const SizedBox(height: 14),
                for (final warning in snapshot.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(warning, style: const TextStyle(fontSize: 13)),
                  ),
                const Text(
                  'Missing cameras will not be deleted. Camera switch/floor assignments and existing live status are preserved.',
                ),
                const SizedBox(height: 18),
                if (_recorders.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: _existingId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Match recorder',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text(
                          'Match by serial, otherwise create new',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final recorder in _recorders)
                        DropdownMenuItem(
                          value: recorder['id'] as String,
                          child: Text(
                            '${recorder['brand'] ?? ''} ${recorder['model'] ?? 'Recorder'} · ${recorder['serial_number'] ?? 'no serial'}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _imported || _busy
                        ? null
                        : (v) => setState(() => _existingId = v),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _brand,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Recorder brand (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Keep existing / not specified'),
                    ),
                    for (final brand in ['Dahua', 'CP Plus'])
                      DropdownMenuItem(value: brand, child: Text(brand)),
                  ],
                  onChanged: _imported || _busy
                      ? null
                      : (v) => setState(() => _brand = v),
                ),
                if (_zones.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _zone,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Recorder location (optional)',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('Keep existing / unknown'),
                      ),
                      for (final zone in _zones)
                        DropdownMenuItem(
                          value: zone['id'] as String,
                          child: Text(
                            '${zone['floor_name']} / ${zone['zone_name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _imported || _busy
                        ? null
                        : (v) => setState(() => _zone = v),
                  ),
                ],
                if (snapshot.cameras.any((c) => c.localChannel == null))
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _indexChannels,
                    onChanged: _imported || _busy
                        ? null
                        : (v) => setState(() => _indexChannels = v!),
                    title: const Text(
                      'Use remote slot + 1 for missing channel numbers',
                    ),
                    subtitle: const Text(
                      'Enable only after verifying this mapping on the recorder. Otherwise channels stay unknown.',
                    ),
                  ),
                const SizedBox(height: 16),
                for (final camera in snapshot.cameras)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.videocam_outlined),
                      title: Text(
                        'Channel ${camera.localChannel ?? (_indexChannels ? camera.slot + 1 : 'unknown')} · remote slot ${camera.slot}',
                      ),
                      subtitle: Text(
                        [
                          camera.ip ?? camera.hostname ?? 'Address unknown',
                          if (camera.brand != null) camera.brand!,
                          if (camera.model != null) camera.model!,
                          if (camera.serial != null) 'Serial: ${camera.serial}',
                          if (camera.mac != null) 'MAC: ${camera.mac}',
                        ].join('\n'),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy || _imported ? null : _import,
                  icon: const Icon(Icons.offline_pin_outlined),
                  label: Text(
                    _imported
                        ? 'Imported on this device'
                        : _busy
                        ? 'Saving…'
                        : 'Confirm & import on device',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This works offline. PostgreSQL inventory sync is a later milestone.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
    );
  }
}
