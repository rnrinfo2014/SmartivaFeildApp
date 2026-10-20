import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_settings.dart';
import '../services/briefing_worker.dart';
import 'common.dart';
import '../services/sync_worker.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.worker,
    this.sync,
  });
  final ApiSettingsStore settings;
  final BriefingWorker worker;
  final InventorySyncWorker? sync;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController(), _token = TextEditingController();
  bool _busy = true;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await widget.settings.load();
      if (!mounted) return;
      _url.text = value?.baseUrl.toString() ?? '';
      _token.text = value?.token ?? '';
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('API connection')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Connect for AI and site sync',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        const Text(
          'Site notes work without a connection. Your administrator supplies the API address and device access token.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _url,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'API address',
            hintText: 'https://fieldops.example.com',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _token,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Access token'),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    final config = ApiSettings.parse(_url.text, _token.text);
                    await widget.sync?.connect(config);
                    await widget.settings.save(config);
                    widget.sync?.kick();
                    widget.worker.kick();
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: const Text('Save connection'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  try {
                    await widget.settings.clear();
                    _url.clear();
                    _token.clear();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
          child: const Text('Disconnect · keep local notes'),
        ),
      ],
    ),
  );
}
