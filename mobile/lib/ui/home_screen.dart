import 'package:flutter/material.dart';

import '../data/field_repository.dart';
import '../domain/briefing.dart';
import 'common.dart';
import '../services/api_settings.dart';
import '../services/briefing_worker.dart';
import '../services/voice_capture.dart';
import 'briefing_screen.dart';
import 'settings_screen.dart';
import 'sync_screen.dart';
import '../services/sync_worker.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.worker,
    required this.voice,
    required this.settings,
    this.sync,
  });
  final FieldRepository repository;
  final BriefingWorker worker;
  final VoiceCapture voice;
  final ApiSettingsStore settings;
  final InventorySyncWorker? sync;

  Future<void> _newSite(BuildContext context) async {
    final input = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New site'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 160,
          decoration: const InputDecoration(
            labelText: 'Site name',
            hintText: 'Yogasree Textiles',
          ),
        ),
        actions: [
          if (sync != null)
            IconButton(
              tooltip: 'Sync & review',
              icon: const Icon(Icons.sync),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SyncScreen(repository: repository, worker: sync!),
                ),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text),
            child: const Text('Create site'),
          ),
        ],
      ),
    );
    // Dialog route disposal completes after its transition.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (name == null || !context.mounted) return;
    try {
      final id = await repository.createSite(name);
      if (context.mounted) _open(context, id, name.trim());
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  void _open(BuildContext context, String id, String name) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BriefingScreen(
            repository: repository,
            worker: worker,
            voice: voice,
            siteId: id,
            name: name,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('SMARTIVA  /  FieldOps'),
      actions: [
        if (sync != null)
          IconButton(
            tooltip: 'Sync & review',
            icon: const Icon(Icons.sync),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    SyncScreen(repository: repository, worker: sync!),
              ),
            ),
          ),
        IconButton(
          tooltip: 'API connection',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(
                settings: settings,
                worker: worker,
                sync: sync,
              ),
            ),
          ),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _newSite(context),
      icon: const Icon(Icons.add),
      label: const Text('New site'),
    ),
    body: StreamBuilder<void>(
      stream: repository.changes,
      builder: (context, _) => FutureBuilder<List<Json>>(
        future: repository.sites(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text('Could not load sites. Restart the app to retry.'),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final sites = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
            children: [
              const Text(
                'Site knowledge,\nwithout the paperwork.',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: ink,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tap, talk and keep every detail. Notes save on your device before AI processing.',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 22),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.offline_pin_outlined, color: teal),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Offline capture ready\nOpen the app online to process pending briefings.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'YOUR SITES  ·  ${sites.length}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              if (sites.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    'Create your first site to start a guided briefing.',
                  ),
                ),
              for (final site in sites)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(14),
                    leading: const CircleAvatar(child: Icon(Icons.apartment)),
                    title: Text(
                      site['name'] as String,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      (site['pending'] as int) > 0
                          ? '${site['pending']} briefings pending'
                          : site['reviewed_at'] != null
                          ? 'Reviewed · saved on device'
                          : 'Saved on device',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(
                      context,
                      site['id'] as String,
                      site['name'] as String,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
