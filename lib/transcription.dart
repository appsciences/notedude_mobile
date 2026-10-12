import 'dart:io';

import 'package:whisper_ggml/whisper_ggml.dart';

enum TranscriptionPhase { downloadingModel, transcribing }

class TranscriptionProgress {
  const TranscriptionProgress(this.phase, [this.fraction]);

  final TranscriptionPhase phase;

  /// 0..1, or null when the amount of work is unknown.
  final double? fraction;
}

class TranscriptionException implements Exception {
  const TranscriptionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns a finished recording into text. Implementations must never delete or
/// modify the audio file; a failure leaves the capture recoverable.
abstract interface class TranscriptionProvider {
  Future<String> transcribe(
    String audioPath, {
    void Function(TranscriptionProgress progress)? onProgress,
  });

  Future<void> dispose();
}

/// Free-tier provider: whisper.cpp running on the device, fed the finished
/// recording, so pauses in speech cannot end the transcription early.
class WhisperTranscriptionProvider implements TranscriptionProvider {
  WhisperTranscriptionProvider({
    this.model = WhisperModel.base,
    WhisperController? controller,
  }) : _controller = controller ?? WhisperController();

  final WhisperModel model;
  final WhisperController _controller;

  @override
  Future<String> transcribe(
    String audioPath, {
    void Function(TranscriptionProgress progress)? onProgress,
  }) async {
    if (!await File(audioPath).exists()) {
      throw const TranscriptionException('The recording file is missing.');
    }

    final modelFile = File(await _controller.getPath(model));
    if (!await modelFile.exists()) {
      await modelFile.parent.create(recursive: true);
      await downloadModelFile(
        model.modelUri,
        modelFile,
        onProgress: (fraction) => onProgress?.call(
          TranscriptionProgress(TranscriptionPhase.downloadingModel, fraction),
        ),
      );
    }

    onProgress?.call(
      const TranscriptionProgress(TranscriptionPhase.transcribing),
    );
    // The package reports failures by returning null, not by throwing.
    final result = await _controller.transcribe(
      model: model,
      audioPath: audioPath,
      lang: 'auto',
      onProgress: (percent) => onProgress?.call(
        TranscriptionProgress(TranscriptionPhase.transcribing, percent / 100),
      ),
    );
    if (result == null) {
      throw const TranscriptionException('The speech model could not run.');
    }
    return result.transcription.text.trim();
  }

  @override
  Future<void> dispose() async {}
}

/// Streams [url] to [target] without ever exposing a partial file there.
///
/// The body goes to `<target>.part` and is renamed into place only after the
/// status is 200 and the declared length (if any) has fully arrived, so a
/// dropped connection or an error page can never be mistaken for a model.
Future<void> downloadModelFile(
  Uri url,
  File target, {
  void Function(double fraction)? onProgress,
}) async {
  final partial = File('${target.path}.part');
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw TranscriptionException(
        'Model download failed (HTTP ${response.statusCode}).',
      );
    }

    final total = response.contentLength;
    var received = 0;
    final sink = partial.openWrite();
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (total >= 0 && received != total) {
      throw TranscriptionException(
        'Model download was incomplete ($received of $total bytes).',
      );
    }
    await partial.rename(target.path);
    onProgress?.call(1);
  } catch (_) {
    if (await partial.exists()) await partial.delete();
    rethrow;
  } finally {
    client.close(force: true);
  }
}
