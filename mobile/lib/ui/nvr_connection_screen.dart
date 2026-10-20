import 'package:flutter/material.dart';

import '../data/field_repository.dart';
import '../domain/discovery.dart';
import '../services/discovery/digest_client.dart';
import '../services/discovery/nvr_bridge.dart';
import 'common.dart';
import 'nvr_review_screen.dart';

class NvrConnectionScreen extends StatefulWidget {
  const NvrConnectionScreen({
    super.key,
    required this.repository,
    required this.siteId,
    this.device,
  });
  final FieldRepository repository;
  final String siteId;
  final NetworkDevice? device;
  @override
  State<NvrConnectionScreen> createState() => _NvrConnectionScreenState();
}

class _NvrConnectionScreenState extends State<NvrConnectionScreen> {
  final _ip = TextEditingController(),
      _port = TextEditingController(),
      _username = TextEditingController(),
      _password = TextEditingController();
  final _bridge = NvrBridge(), _credentials = NvrCredentialStore();
  bool _https = false, _remember = false, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _ip.text = widget.device?.address ?? '';
    _https = widget.device?.https ?? false;
    _port.text = '${widget.device?.httpPort ?? 80}';
  }

  NvrTarget _target() =>
      NvrTarget(_ip.text, port: int.tryParse(_port.text) ?? 0, https: _https);
  void _targetChanged() {
    _password.clear();
  }

  Future<void> _loadLogin() async {
    try {
      final target = _target();
      final value = await _credentials.load(widget.siteId, target);
      if (!mounted || _target().origin != target.origin) return;
      if (value == null) {
        setState(() => _error = 'No saved login for this site and address.');
        return;
      }
      _username.text = value.username;
      _password.text = value.password;
      setState(() {
        _remember = true;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not read saved login. Check the NVR address or enter credentials manually.',
        );
      }
    }
  }

  Future<void> _fetch() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final target = _target();
      final snapshot = await _bridge.fetch(
        target,
        _username.text.trim(),
        _password.text,
      );
      // Preserve successful inventory independently of optional secure-storage writes.
      final id = await widget.repository.saveSnapshot(widget.siteId, snapshot);
      if (_remember) {
        try {
          final ref = await _credentials.save(
            widget.siteId,
            target,
            _username.text.trim(),
            _password.text,
          );
          await widget.repository.attachSnapshotCredential(id, ref);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Inventory saved. Login could not be remembered on this device.',
                ),
              ),
            );
          }
        }
      }
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                NvrReviewScreen(repository: widget.repository, snapshotId: id),
          ),
        );
      }
    } on NvrFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save NVR inventory. Check device storage and retry.',
        );
      }
    } finally {
      if (mounted) {
        _password.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _bridge.cancel();
    _ip.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Connect to recorder')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Dahua / CP Plus NVR bridge',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        const Text(
          'Read system identity and configured cameras through the recorder. Cameras on an isolated second LAN can be listed without reaching their IPs from this phone.',
        ),
        if (widget.device?.protocols.contains('SADP') ?? false)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'This device replied using Hikvision SADP. Discovery is supported; the Dahua CGI bridge may not be supported by this device.',
            ),
          ),
        const SizedBox(height: 20),
        TextField(
          controller: _ip,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => _targetChanged(),
          decoration: const InputDecoration(labelText: 'NVR IPv4 address'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _port,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          onChanged: (_) => _targetChanged(),
          decoration: const InputDecoration(
            labelText: 'Web port (not the device TCP/service port)',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use HTTPS'),
          value: _https,
          onChanged: _busy
              ? null
              : (value) => setState(() {
                  _https = value;
                  _port.text = value ? '443' : '80';
                  _targetChanged();
                }),
        ),
        if (!_https)
          const Text(
            'Local HTTP does not encrypt inventory or authentication exchanges. Use trusted site Wi-Fi, or HTTPS with a trusted NVR certificate.',
            style: TextStyle(fontSize: 12),
          ),
        const SizedBox(height: 14),
        TextField(
          controller: _username,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'NVR username'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'NVR password'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _remember,
          onChanged: _busy ? null : (v) => setState(() => _remember = v!),
          title: const Text('Remember login on this device'),
          subtitle: const Text(
            'Stored in platform secure storage, never in the inventory or scan evidence.',
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: _busy ? null : _loadLogin,
              child: const Text('Load saved login'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      try {
                        final target = _target(),
                            ref = _credentials.reference(
                              widget.siteId,
                              _target(),
                            );
                        await _credentials.forget(widget.siteId, target);
                        await widget.repository.forgetCredentialRef(
                          widget.siteId,
                          ref,
                        );
                        if (mounted) {
                          _password.clear();
                          setState(() => _remember = false);
                        }
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
              child: const Text('Forget saved login'),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.deepOrange),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _fetch,
          icon: const Icon(Icons.download_outlined),
          label: Text(_busy ? 'Reading recorder…' : 'Fetch camera inventory'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
      ],
    ),
  );
}
