import 'package:flutter/material.dart';

import '../data/field_repository.dart';
import '../domain/briefing.dart';
import 'common.dart';
import '../services/briefing_worker.dart';
import '../services/voice_capture.dart';
import 'review_screen.dart';
import 'network_scan_screen.dart';

class BriefingScreen extends StatefulWidget {
  const BriefingScreen({
    super.key,
    required this.repository,
    required this.worker,
    required this.voice,
    required this.siteId,
    required this.name,
  });
  final FieldRepository repository;
  final BriefingWorker worker;
  final VoiceCapture voice;
  final String siteId, name;
  @override
  State<BriefingScreen> createState() => _BriefingScreenState();
}

class _BriefingScreenState extends State<BriefingScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  String _language = 'auto';
  bool _saving = false;

  Future<void> _send() async {
    if (_saving || _input.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.repository.queueText(widget.siteId, _input.text, _language);
      _input.clear();
      widget.worker.kick();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _record() async {
    if (widget.voice.recording) {
      await widget.voice.stop();
      widget.worker.kick();
    } else {
      await widget.voice.start(widget.siteId, _language);
    }
    if (mounted && widget.voice.error != null) {
      showError(context, FormatException(widget.voice.error!));
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.voice,
    builder: (context, _) => PopScope(
      canPop: !widget.voice.recording && !widget.voice.busy,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Stop and save your recording before leaving.'),
            ),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.name),
              const Text(
                'Site briefing',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Review inventory',
              icon: const Icon(Icons.fact_check_outlined),
              onPressed: widget.voice.recording
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ReviewScreen(
                          repository: widget.repository,
                          siteId: widget.siteId,
                        ),
                      ),
                    ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.forum_outlined, size: 18),
                      label: const Text('Guided AI entry'),
                      onPressed: () => _focus.requestFocus(),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.mic_none, size: 18),
                      label: const Text('Continuous voice briefing'),
                      onPressed: widget.voice.busy ? null : _record,
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.wifi_find, size: 18),
                      label: const Text('Auto-scan network'),
                      onPressed: widget.voice.recording || widget.voice.busy
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => NetworkScanScreen(
                                  repository: widget.repository,
                                  siteId: widget.siteId,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<void>(
                  stream: widget.repository.changes,
                  builder: (context, _) => FutureBuilder<List<Object>>(
                    future: Future.wait([
                      widget.repository.messages(widget.siteId),
                      widget.repository.jobs(widget.siteId),
                    ]),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const Center(
                          child: Text('Could not load briefing history.'),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final messages = snapshot.data![0] as List<Json>,
                          jobs = snapshot.data![1] as List<Json>;
                      return Column(
                        children: [
                          if (jobs.isNotEmpty)
                            SizedBox(
                              height: jobs.any((j) => j['state'] == 'failed')
                                  ? 125
                                  : 88,
                              child: ListView(
                                children: [
                                  for (final job in jobs) _jobCard(job),
                                ],
                              ),
                            ),
                          Expanded(
                            child: ListView.builder(
                              reverse: true,
                              padding: const EdgeInsets.all(16),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                final message =
                                        messages[messages.length - index - 1],
                                    mine = message['role'] == 'technician';
                                return Align(
                                  alignment: mine
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      maxWidth: 520,
                                    ),
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: mine ? teal : Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          mine
                                              ? 'YOU'
                                              : message['role'] == 'system'
                                              ? 'SAVED'
                                              : 'SITE ASSISTANT',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 1,
                                            color: mine ? Colors.white70 : teal,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        SelectableText(
                                          message['text'] as String,
                                          style: TextStyle(
                                            color: mine ? Colors.white : ink,
                                            fontSize: 15,
                                            height: 1.4,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (widget.voice.recording)
                Container(
                  color: const Color(0xFFFFEBDF),
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.fiber_manual_record,
                        color: Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Recording ${widget.voice.seconds}s / 120s · stop to save',
                        ),
                      ),
                      TextButton(
                        onPressed: widget.voice.busy ? null : _record,
                        child: const Text('STOP & SAVE'),
                      ),
                    ],
                  ),
                ),
              if (widget.voice.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    widget.voice.error!,
                    style: const TextStyle(color: Colors.deepOrange),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _language,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(
                      value: 'auto',
                      child: Text(
                        'Tamil / Tanglish / English',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(value: 'ta', child: Text('Tamil')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                  ],
                  onChanged: widget.voice.recording
                      ? null
                      : (v) => setState(() => _language = v!),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Record voice note',
                      onPressed: widget.voice.busy ? null : _record,
                      icon: Icon(
                        widget.voice.recording ? Icons.stop : Icons.mic_none,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 30000,
                        decoration: const InputDecoration(
                          hintText: 'Site details sollunga…',
                          counterText: '',
                          filled: true,
                          fillColor: Colors.white,
                        ),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: 'Save and send',
                      onPressed: _saving ? null : _send,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _jobCard(Json job) {
    final failed = job['state'] == 'failed';
    return ListTile(
      dense: true,
      leading: Icon(
        failed ? Icons.error_outline : Icons.schedule,
        color: failed ? Colors.deepOrange : teal,
      ),
      title: Text(
        job['state'] == 'inflight'
            ? 'AI processing…'
            : failed
            ? 'Briefing needs attention'
            : 'Saved locally · waiting for AI',
      ),
      subtitle: job['last_error'] != null
          ? Text(
              job['last_error'] as String,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: Wrap(
        children: [
          if (job['state'] != 'inflight')
            IconButton(
              tooltip: 'Retry now',
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                try {
                  await widget.repository.retry(job['id'] as String);
                  widget.worker.kick();
                } catch (e) {
                  if (mounted) showError(context, e);
                }
              },
            ),
          if (failed)
            IconButton(
              tooltip: 'Skip AI processing; keep original note',
              icon: const Icon(Icons.skip_next),
              onPressed: () async {
                final skip = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Skip this briefing?'),
                    content: const Text(
                      'The original note stays on this device. AI will continue with the next note.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Keep waiting'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Skip processing'),
                      ),
                    ],
                  ),
                );
                if (skip == true) {
                  try {
                    await widget.repository.skip(job['id'] as String);
                    widget.worker.kick();
                  } catch (e) {
                    if (mounted) showError(context, e);
                  }
                }
              },
            ),
        ],
      ),
    );
  }
}
