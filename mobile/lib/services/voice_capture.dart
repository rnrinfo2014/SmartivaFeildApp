import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../data/field_repository.dart';

class VoiceCapture extends ChangeNotifier {
  VoiceCapture(this.repository);
  final FieldRepository repository;
  AudioRecorder? _instance;
  AudioRecorder get _recorder => _instance ??= AudioRecorder();
  String? _id;
  String? siteId;
  bool busy = false;
  bool get recording => _id != null;
  int seconds = 0;
  String? error;
  Timer? _clock;

  Future<void> recover() async {
    for (final draft in await repository.recordingDrafts()) {
      try {
        final file = File(draft['path'] as String);
        if (await file.exists() && await file.length() > 0) {
          await repository.finishRecording(
            draft['id'] as String,
            (await sha256.bind(file.openRead()).first).toString(),
            recovered: true,
          );
        } else {
          await repository.abandonRecording(draft['id'] as String);
        }
      } on FileSystemException {
        error =
            'An interrupted voice note is unreadable. The saved draft is retained for recovery.';
      }
    }
  }

  Future<void> start(String site, String language) async {
    if (recording || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    String? draftId;
    try {
      if (!await _recorder.hasPermission()) {
        throw const FormatException(
          'Microphone permission is required. Enable it in device settings.',
        );
      }
      if (!await _recorder.isEncoderSupported(AudioEncoder.aacLc)) {
        throw const FormatException(
          'AAC recording is not supported on this device.',
        );
      }
      final directory = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'voice_notes'),
      );
      await directory.create(recursive: true);
      final id = const Uuid().v4(), path = p.join(directory.path, '$id.m4a');
      await repository.beginRecording(id, site, path, language);
      draftId = id;
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: path,
      );
      _id = id;
      siteId = site;
      seconds = 0;
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        seconds++;
        notifyListeners();
        if (seconds >= 120) unawaited(stop());
      });
    } on FormatException catch (e) {
      error = e.message;
    } catch (_) {
      error =
          'Could not start recording. Check microphone access and device storage.';
      if (draftId != null) {
        try {
          await recover();
        } catch (_) {
          /* recover from SQLite at next startup */
        }
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!recording || busy) return;
    busy = true;
    _clock?.cancel();
    notifyListeners();
    final id = _id!;
    try {
      final path = await _recorder.stop();
      if (path == null ||
          !await File(path).exists() ||
          await File(path).length() == 0) {
        await repository.abandonRecording(id);
        error = 'No audio was captured. Please record again.';
      } else {
        final digest = (await sha256.bind(File(path).openRead()).first)
            .toString();
        await repository.finishRecording(id, digest);
      }
    } catch (_) {
      error =
          'Could not finish saving audio. Recovery will retry when the app restarts.';
      // Keep the durable recording draft and file for recovery.
    } finally {
      _id = null;
      siteId = null;
      busy = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    if (recording) await stop();
    _clock?.cancel();
    await _instance?.dispose();
    super.dispose();
  }
}
