import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

enum CaptureKind { note, task }

/// `failed` keeps the capture in the outbox; it is retried on the next run.
enum SyncState { savedLocally, synced, failed }

class VoiceCapture {
  const VoiceCapture({
    required this.id,
    required this.createdAt,
    required this.audioPath,
    required this.duration,
    required this.text,
    required this.kind,
    this.taskTag = '#tasks-inbox',
    this.syncState = SyncState.savedLocally,
    this.noteId,
    this.syncError,
    this.syncedAt,
  });

  final String id;
  final DateTime createdAt;
  final String audioPath;
  final Duration duration;
  final String text;
  final CaptureKind kind;
  final String taskTag;
  final SyncState syncState;

  /// The NoteDude note this capture became, once synced.
  final String? noteId;
  final String? syncError;
  final DateTime? syncedAt;

  VoiceCapture copyWith({
    DateTime? createdAt,
    String? text,
    SyncState? syncState,
    String? noteId,
    String? syncError,
    bool clearSyncError = false,
    DateTime? syncedAt,
  }) => VoiceCapture(
    id: id,
    createdAt: createdAt ?? this.createdAt,
    audioPath: audioPath,
    duration: duration,
    text: text ?? this.text,
    kind: kind,
    taskTag: taskTag,
    syncState: syncState ?? this.syncState,
    noteId: noteId ?? this.noteId,
    syncError: clearSyncError ? null : (syncError ?? this.syncError),
    syncedAt: syncedAt ?? this.syncedAt,
  );

  /// The note text to sync: what the user wrote, or a placeholder so a
  /// capture with only audio still becomes a findable note.
  String get syncText {
    final trimmed = text.trim();
    return trimmed.isEmpty ? 'Voice note ${createdAt.toLocal()}' : trimmed;
  }

  /// Tags sent alongside the text; the server does not repeat one that is
  /// already in the text.
  List<String> get syncTags => kind == CaptureKind.task ? [taskTag] : const [];

  String get noteContent {
    final trimmed = text.trim();
    final body = trimmed.isEmpty
        ? 'Voice note ${createdAt.toLocal()}'
        : trimmed;
    return kind == CaptureKind.task ? '$body $taskTag' : body;
  }

  Map<String, Object> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'audioPath': audioPath,
    'durationMs': duration.inMilliseconds,
    'text': text,
    'kind': kind.name,
    'taskTag': taskTag,
    'syncState': syncState.name,
    'noteId': ?noteId,
    'syncError': ?syncError,
    if (syncedAt != null) 'syncedAt': syncedAt!.toUtc().toIso8601String(),
  };

  factory VoiceCapture.fromJson(Map<String, dynamic> json) => VoiceCapture(
    id: json['id'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    audioPath: json['audioPath'] as String,
    duration: Duration(milliseconds: json['durationMs'] as int),
    text: json['text'] as String? ?? '',
    kind: CaptureKind.values.byName(json['kind'] as String? ?? 'note'),
    taskTag: json['taskTag'] as String? ?? '#tasks-inbox',
    syncState:
        SyncState.values.asNameMap()[json['syncState']] ??
        SyncState.savedLocally,
    noteId: json['noteId'] as String?,
    syncError: json['syncError'] as String?,
    syncedAt: json['syncedAt'] == null
        ? null
        : DateTime.parse(json['syncedAt'] as String),
  );
}

abstract interface class CaptureStore {
  Future<List<VoiceCapture>> load();
  Future<void> save(VoiceCapture capture);
}

class LocalCaptureStore implements CaptureStore {
  Future<File> _outboxFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/capture_outbox.json');
  }

  @override
  Future<List<VoiceCapture>> load() async {
    final file = await _outboxFile();
    if (!await file.exists()) return [];
    try {
      final values = jsonDecode(await file.readAsString()) as List<dynamic>;
      return values
          .map((value) => VoiceCapture.fromJson(value as Map<String, dynamic>))
          .toList();
    } on FormatException {
      // Preserve a corrupt outbox for recovery instead of overwriting it.
      await file.rename(
        '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
      return [];
    }
  }

  @override
  Future<void> save(VoiceCapture capture) async {
    final captures = await load();
    final index = captures.indexWhere((item) => item.id == capture.id);
    if (index == -1) {
      captures.insert(0, capture);
    } else {
      captures[index] = capture;
    }

    final file = await _outboxFile();
    final pending = File('${file.path}.pending');
    await pending.writeAsString(
      jsonEncode(captures.map((item) => item.toJson()).toList()),
      flush: true,
    );
    await pending.rename(file.path);
  }
}

abstract interface class VoiceRecorder {
  Future<String> start();
  Future<String?> stop();
  Future<void> pause();
  Future<void> resume();
  Future<void> dispose();
}

class DeviceVoiceRecorder implements VoiceRecorder {
  DeviceVoiceRecorder() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<String> start() async {
    if (!await _recorder.hasPermission()) {
      throw const FileSystemException('Microphone permission was not granted.');
    }
    final root = await getApplicationDocumentsDirectory();
    final recordings = Directory('${root.path}/recordings');
    await recordings.create(recursive: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final path = '${recordings.path}/$id.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
        autoGain: true,
        noiseSuppress: true,
      ),
      path: path,
    );
    return path;
  }

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> pause() => _recorder.pause();

  @override
  Future<void> resume() => _recorder.resume();

  @override
  Future<void> dispose() => _recorder.dispose();
}
