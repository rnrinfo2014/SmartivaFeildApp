import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/field_repository.dart';
import '../domain/briefing.dart';
import '../services/sync_worker.dart';
import 'common.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.repository, required this.worker});
  final FieldRepository repository;
  final InventorySyncWorker worker;
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<List<Json>>> _load() async => [
    await widget.repository.db.query('sync_connection'),
    await widget.repository.pendingInventory(),
    await widget.repository.conflicts(),
    await widget.repository.db.query(
      'voice_upload_jobs',
      where: "state NOT IN ('done','retired')",
    ),
  ];
  Future<void> _review(Json conflict) async {
    final remote = conflict['remote_payload'] == null
        ? null
        : object(jsonDecode(conflict['remote_payload'] as String));
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Review ${conflict['entity_type']}'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(conflict['reason'] as String),
                const SizedBox(height: 12),
                const Text(
                  'ON THIS DEVICE',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(jsonDecode(conflict['local_payload'] as String)),
                ),
                const SizedBox(height: 16),
                const Text(
                  'ON THE SERVER',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(remote),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Both snapshots stay in the local review history. Accepting a removal also retires dependent local inventory. Audio files are retained.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Use server copy'),
          ),
          if (remote?['deleted_at'] == null)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Keep device edits'),
            ),
        ],
      ),
    );
    if (choice != null) {
      await _run(() async {
        await widget.repository.resolveConflict(
          conflict['entity_type'] as String,
          conflict['entity_id'] as String,
          keepLocal: choice,
        );
        await widget.worker.runPending();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Sync & review'),
      actions: [
        IconButton(
          tooltip: 'Sync now',
          onPressed: _busy ? null : () => _run(widget.worker.runPending),
          icon: const Icon(Icons.sync),
        ),
      ],
    ),
    body: StreamBuilder<void>(
      stream: widget.repository.changes,
      builder: (context, _) => FutureBuilder<List<List<Json>>>(
        future: _load(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Could not load sync status.'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!,
              connection = data[0].isEmpty ? null : data[0].single;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_busy) const LinearProgressIndicator(),
              Text(
                connection == null
                    ? 'Configure your device connection to sync.'
                    : 'Last sync: ${connection['last_success_at'] ?? 'Waiting'}',
              ),
              if (connection?['last_error'] != null)
                Text(connection!['last_error'] as String),
              const Text(
                'Sync runs while this app is open. Pending edits stay on this device. Review AI proposals before pulling newer inventory.',
              ),
              const SizedBox(height: 16),
              Text(
                '${data[1].length} inventory operations · ${data[3].length} voice uploads · ${data[2].length} conflicts',
              ),
              for (final c in data[2])
                Card(
                  child: ListTile(
                    title: Text('${c['entity_type']} · ${c['entity_id']}'),
                    subtitle: Text(c['reason'] as String),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _review(c),
                      child: const Text('Review'),
                    ),
                  ),
                ),
              for (final p in data[1])
                ListTile(
                  title: Text('${p['entity_type']} · ${p['status']}'),
                  subtitle: Text(
                    p['last_error'] as String? ??
                        'Waiting for connection or dependent inventory.',
                  ),
                  trailing: p['status'] == 'failed'
                      ? TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await widget.repository.retryLatest(
                                    p['entity_type'] as String,
                                    p['entity_id'] as String,
                                  );
                                  await widget.worker.runPending();
                                }),
                          child: const Text('Retry'),
                        )
                      : null,
                ),
              for (final v in data[3])
                ListTile(
                  title: Text('Voice archive · ${v['state']}'),
                  subtitle: Text(
                    v['last_error'] as String? ?? 'Saved on this device.',
                  ),
                  trailing: v['state'] == 'failed'
                      ? TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await widget.repository.db.update(
                                    'voice_upload_jobs',
                                    {
                                      'state': 'pending',
                                      'attempts': 0,
                                      'next_attempt_ms': 0,
                                    },
                                    where: 'voice_id=?',
                                    whereArgs: [v['voice_id']],
                                  );
                                  await widget.worker.runPending();
                                }),
                          child: const Text('Retry'),
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    ),
  );
}
