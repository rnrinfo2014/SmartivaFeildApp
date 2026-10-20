import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../data/field_repository.dart';
import '../domain/briefing.dart';
import 'api_settings.dart';
import 'sync_api.dart';

class InventorySyncWorker {
  InventorySyncWorker(this.repository, this.settings, this.gateway);
  final FieldRepository repository;
  final ApiSettingsStore settings;
  final SyncGateway gateway;
  bool _enabled = false, _disposed = false;
  Future<void>? _active;
  Timer? _timer;
  StreamSubscription<dynamic>? _network;
  Future<void> connect(ApiSettings config) async {
    final identity = await gateway.identity(config);
    await repository.bindSync(config.baseUrl.toString(), identity);
  }

  void start({bool observeNetwork = true, bool processImmediately = true}) {
    _enabled = true;
    if (observeNetwork) {
      _network ??= Connectivity().onConnectivityChanged.listen((_) => kick());
    }
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => kick());
    if (processImmediately) kick();
  }

  void pause() => _enabled = false;
  void kick() => unawaited(runPending());
  Future<void> runPending() {
    if (!_enabled || _disposed) return Future.value();
    return _active ??= _drain().whenComplete(() => _active = null);
  }

  bool get _running => _enabled && !_disposed;
  Future<void> _drain() async {
    try {
      final config = await settings.load();
      if (config == null) return;
      await connect(config);
      await _push(config);
      if (!_running) return;
      while (_running) {
        final work = await repository.claimVoiceUpload();
        if (work == null) break;
        try {
          await repository.acknowledgeVoice(
            work,
            object((await gateway.upload(config, work))['record']),
          );
        } on SyncFailure catch (e) {
          await repository.failVoiceUpload(
            work,
            e.message,
            retryable: e.retryable,
          );
        }
      }
      await _push(config);
      var after = '';
      while (_running) {
        final page = await gateway.sites(config, after);
        for (final site in rows(page, 'sites')) {
          if (!_running) return;
          final id = site['id'] as String;
          final stored = await repository.db.query(
            'sync_cursors',
            where: 'site_id=?',
            whereArgs: [id],
          );
          var cursor = stored.isEmpty
              ? 0
              : int.parse(stored.single['server_cursor'] as String);
          int? through;
          while (_running) {
            final changes = await gateway.changes(config, id, cursor, through);
            if (changes['site_id'] != id ||
                changes['cursor'] is! int ||
                changes['through'] is! int ||
                changes['has_more'] is! bool) {
              throw const SyncFailure('Incompatible change page.');
            }
            if (!await repository.applyPage(id, changes)) break;
            final next = changes['cursor'] as int;
            if (changes['has_more'] == false) break;
            if (next <= cursor) {
              throw const SyncFailure('Server cursor did not advance.');
            }
            cursor = next;
            through = changes['through'] as int;
          }
        }
        if (page['next'] == null) break;
        final next = page['next'] as String;
        if (next.compareTo(after) <= 0) {
          throw const SyncFailure('Server site cursor did not advance.');
        }
        after = next;
      }
      await repository.syncStatus(null, success: true);
    } on SyncFailure catch (e) {
      await repository.syncStatus(e.message);
    } on FormatException catch (e) {
      await repository.syncStatus(e.message);
    } catch (_) {
      await repository.syncStatus(
        'Sync paused. Local data is retained; retry when the connection is available.',
      );
    }
  }

  Future<void> _push(ApiSettings config) async {
    while (_running) {
      final work = await repository.claimMutation();
      if (work == null) return;
      try {
        await repository.acknowledgeMutation(
          work,
          object((await gateway.push(config, work))['record']),
        );
      } on SyncFailure catch (e) {
        await repository.failMutation(
          work,
          e.message,
          retryable: e.retryable,
          conflict: e.conflict,
          remote: e.remote,
        );
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _network?.cancel();
    await _active;
  }
}
