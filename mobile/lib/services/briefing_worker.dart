import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../data/field_repository.dart';
import 'api_settings.dart';
import 'briefing_api.dart';

class BriefingWorker {
  BriefingWorker(
    this.repository,
    this.settings,
    this.gateway, {
    this.beforeDrain,
  });
  final Future<void> Function()? beforeDrain;
  final FieldRepository repository;
  final ApiSettingsStore settings;
  final BriefingGateway gateway;
  StreamSubscription<dynamic>? _network;
  StreamSubscription<void>? _local;
  Timer? _timer;
  bool _enabled = false, _disposed = false;
  Future<void>? _active;

  void start({bool observeNetwork = true, bool processImmediately = true}) {
    _enabled = true;
    if (observeNetwork) {
      _network ??= Connectivity().onConnectivityChanged.listen((_) => kick());
    }
    _local ??= repository.changes.listen((_) => kick());
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => kick());
    if (processImmediately) {
      kick();
    }
  }

  void pause() {
    _enabled = false;
  }

  Future<void> runPending() {
    if (!_enabled || _disposed) return Future<void>.value();
    return _active ??= _drain().whenComplete(() => _active = null);
  }

  void kick() {
    unawaited(runPending());
  }

  Future<void> _drain() async {
    try {
      await beforeDrain?.call();
      while (_enabled && !_disposed) {
        final config = await settings.load();
        if (config == null) {
          return; // Local capture works before API configuration.
        }
        final work = await repository.claim();
        if (work == null) return;
        repository.changed();
        try {
          final result = await gateway.send(
            config,
            work,
            await repository.context(work.siteId),
          );
          await repository.complete(work, result);
        } on WorkFailure catch (error) {
          final delay =
              min(300, 5 * pow(2, min(work.attempts, 6)).toInt()) +
              Random().nextInt(5);
          await repository.fail(
            work,
            error.code,
            retryable: error.retryable,
            delaySeconds: delay,
          );
        } catch (_) {
          // Database/secure-storage errors are retried at the worker boundary.
          // Retain the leased job for recovery; never log private request payloads.
          return;
        }
      }
    } catch (_) {
      // Preserve pending work if secure storage or SQLite is temporarily unavailable.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _network?.cancel();
    await _local?.cancel();
    await _active;
  }
}
