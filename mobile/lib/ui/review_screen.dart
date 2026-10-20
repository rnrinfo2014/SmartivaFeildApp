import 'package:flutter/material.dart';

import '../data/field_repository.dart';
import '../domain/briefing.dart';
import 'common.dart';

class ReviewScreen extends StatelessWidget {
  const ReviewScreen({
    super.key,
    required this.repository,
    required this.siteId,
  });
  final FieldRepository repository;
  final String siteId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Review site inventory')),
    body: StreamBuilder<void>(
      stream: repository.changes,
      builder: (context, _) => FutureBuilder<Json>(
        future: repository.session(siteId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Could not load inventory.'));
          }
          final session = snapshot.data;
          if (session == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (session['result'] == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'AI review appears after a briefing is processed. Imported NVR inventory is available in Auto-scan network → saved inventories. Notes stay on this device while offline.',
                ),
              ),
            );
          }
          final result = BriefingResult.decode(session['result'] as String),
              data = result.proposal;
          final labels = <String, String>{};
          for (final group in entityTables.keys) {
            for (final row in rows(data, group)) {
              labels[row['ref'] as String] = _title(row);
            }
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Check before you save',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Correct missing or wrong details in the chat. Saving updates this device; server inventory sync will follow in a later release.',
              ),
              for (final warning in result.warnings)
                Card(
                  color: const Color(0xFFFFEBDF),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(warning),
                  ),
                ),
              for (final calc in result.calculations)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          labels[calc['nvr_id']] ?? 'Recorder',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${calc['capacity'] ?? '?'} channels · ${calc['reported_total'] ?? '?'} reported cameras · ${calc['free_channels'] ?? '?'} free',
                        ),
                        Text(
                          'Online reported: ${calc['reported_active'] ?? 'unknown'} · Individually documented: ${calc['individually_documented']}',
                        ),
                        if (object(
                          calc['poe_minimum_switches'],
                        ).isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'PoE switch lower bounds: ${object(calc['poe_minimum_switches']).entries.map((e) => '${e.value} × ${e.key}-port').join(', ')}',
                          ),
                          const Text(
                            'Assumes all ports available for PoE. Check uplinks and power budget before planning hardware.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              Card(
                child: ListTile(
                  title: const Text('Site'),
                  subtitle: Text(_details(object(data['site']), labels)),
                ),
              ),
              for (final group in {
                ...entityTables.keys,
                'inventory_reports',
                'switch_reports',
                'ups_reports',
              })
                if (rows(data, group).isNotEmpty)
                  Card(
                    child: ExpansionTile(
                      title: Text(
                        '${_label(group)} (${rows(data, group).length})',
                      ),
                      children: [
                        for (final row in rows(data, group))
                          ListTile(
                            title: Text(_title(row)),
                            subtitle: Text(_details(row, labels)),
                          ),
                      ],
                    ),
                  ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.check_circle_outline),
                label: Text(
                  session['reviewed_at'] != null
                      ? 'Saved on this device'
                      : 'Confirm & save on device',
                ),
                onPressed:
                    session['reviewed_at'] != null || result.warnings.isNotEmpty
                    ? null
                    : () async {
                        try {
                          await repository.confirm(
                            siteId,
                            session['result'] as String,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Reviewed inventory saved on this device.',
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
              ),
            ],
          );
        },
      ),
    ),
  );
}

String _label(String key) => key
    .replaceAll('_', ' ')
    .split(' ')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');
String _title(Json row) => [
  row['name'] ??
      row['zone_name'] ??
      row['asset_type'] ??
      row['camera_type'] ??
      row['brand'] ??
      'Details',
  if (row['model'] != null) row['model'],
  if (row['channel_no'] != null) 'Channel ${row['channel_no']}',
].join(' · ');
String _details(Json row, Map<String, String> labels) => row.entries
    .where((e) => e.key != 'ref' && e.value != null)
    .map(
      (e) =>
          '${_label(e.key)}: ${e.key.endsWith('_id')
              ? labels[e.value] ?? e.value
              : e.value is Map
              ? (e.value as Map).entries.map((p) => '${p.key}: ${p.value}').join(', ')
              : e.value}',
    )
    .join('\n');
