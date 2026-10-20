import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'data/database.dart';
import 'data/field_repository.dart';
import 'services/api_settings.dart';
import 'services/briefing_api.dart';
import 'services/briefing_worker.dart';
import 'services/voice_capture.dart';
import 'services/sync_api.dart';
import 'services/sync_worker.dart';
import 'ui/screens.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FieldOpsBootstrap());
}

class FieldOpsBootstrap extends StatefulWidget {
  const FieldOpsBootstrap({super.key, this.openDatabase});
  final Future<Database> Function()? openDatabase;
  @override
  State<FieldOpsBootstrap> createState() => _FieldOpsBootstrapState();
}

class _FieldOpsBootstrapState extends State<FieldOpsBootstrap>
    with WidgetsBindingObserver {
  FieldRepository? _repository;
  late final ApiSettingsStore _settings = ApiSettingsStore();
  BriefingWorker? _worker;
  InventorySyncWorker? _sync;
  VoiceCapture? _voice;
  bool _failed = false;
  String _openingStep = 'Local database';
  String? _failureCode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open());
  }

  Future<void> _open() async {
    FieldRepository? repository;
    VoiceCapture? voice;
    try {
      _openingStep = 'Local database';
      repository = FieldRepository(
        await (widget.openDatabase ?? openFieldDatabase)(),
      );
      _openingStep = 'Voice note recovery';
      voice = VoiceCapture(repository);
      await voice.recover();
      _openingStep = 'Background services';
      final sync = InventorySyncWorker(
        repository,
        _settings,
        HttpSyncGateway(),
      );
      final worker = BriefingWorker(
        repository,
        _settings,
        HttpBriefingGateway(),
        beforeDrain: sync.runPending,
      );
      if (!mounted) {
        await voice.close();
        await repository.close();
        return;
      }
      setState(() {
        _repository = repository;
        _voice = voice;
        _worker = worker;
        _sync = sync;
      });
      sync.start();
      worker.start();
    } catch (error) {
      // Retrying must not leak a database handle or recording controller.
      try {
        await voice?.close();
      } catch (_) {
        // Keep the original startup failure for the support code below.
      }
      try {
        await repository?.close();
      } catch (_) {
        // No saved data is deleted during recovery or retry.
      }
      if (mounted) {
        setState(() {
          _failed = true;
          // Do not put exception messages (SQL, paths or site data) on screen.
          _failureCode = error is DatabaseException
              ? 'SQLite ${error.getResultCode() ?? "error"}'
              : error.runtimeType.toString();
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sync?.start();
      _worker?.start();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Stop rather than continuing microphone capture in the background.
      unawaited(_voice?.stop());
      _worker?.pause();
      _sync?.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_worker?.dispose());
    unawaited(_sync?.dispose());
    unawaited(_voice?.close());
    // OS owns database teardown at app termination; keep it open for finishing work.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Smartiva FieldOps',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF3F6F4),
      colorScheme: ColorScheme.fromSeed(seedColor: teal),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF3F6F4),
        foregroundColor: ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    home: _repository != null
        ? HomeScreen(
            repository: _repository!,
            worker: _worker!,
            voice: _voice!,
            settings: _settings,
            sync: _sync,
          )
        : Scaffold(
            body: Center(
              child: _failed
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Could not start the app. Your saved data has not been cleared. Please retry.',
                          ),
                          const SizedBox(height: 12),
                          SelectableText('Step: $_openingStep · $_failureCode'),
                          TextButton(
                            onPressed: () {
                              setState(() => _failed = false);
                              unawaited(_open());
                            },
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
  );
}
