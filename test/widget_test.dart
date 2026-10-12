import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notedude_mobile/capture.dart';
import 'package:notedude_mobile/main.dart';
import 'package:notedude_mobile/transcription.dart';

import 'fake_auth.dart';

class FakeRecorder implements VoiceRecorder {
  @override
  Future<void> dispose() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<String> start() async => '/tmp/capture.m4a';
  @override
  Future<String?> stop() async => '/tmp/capture.m4a';
}

class FakeTranscriber implements TranscriptionProvider {
  @override
  Future<void> dispose() async {}
  @override
  Future<String> transcribe(
    String audioPath, {
    void Function(TranscriptionProgress progress)? onProgress,
  }) async => '';
}

class MemoryStore implements CaptureStore {
  final captures = <VoiceCapture>[];
  @override
  Future<List<VoiceCapture>> load() async => List.of(captures);
  @override
  Future<void> save(VoiceCapture capture) async => captures.insert(0, capture);
}

void main() {
  test('task captures use NoteDude task tags', () {
    final capture = VoiceCapture(
      id: 'capture-1',
      createdAt: DateTime.utc(2026, 8, 25),
      audioPath: '/audio.m4a',
      duration: const Duration(seconds: 3),
      text: 'Buy coffee',
      kind: CaptureKind.task,
    );
    expect(capture.noteContent, 'Buy coffee #tasks-inbox');
  });

  testWidgets('records, reviews, and saves a local capture', (tester) async {
    final store = MemoryStore();
    await tester.pumpWidget(
      NoteDudeApp(
        recorder: FakeRecorder(),
        store: store,
        transcriber: FakeTranscriber(),
        auth: FakeAuth(user: FakeAuth.person),
      ),
    );
    await tester.pump();

    expect(find.text('CAPTURE A THOUGHT'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();
    expect(find.text('RECORDING'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    expect(find.text('REVIEW CAPTURE'), findsOneWidget);

    await tester.tap(find.text('Save locally'));
    await tester.pump();
    expect(store.captures, hasLength(1));
    expect(find.text('1 OUTBOX'), findsOneWidget);
  });

  testWidgets('the logo reads note_dude in Fira Code', (tester) async {
    await tester.pumpWidget(
      NoteDudeApp(
        recorder: FakeRecorder(),
        store: MemoryStore(),
        transcriber: FakeTranscriber(),
        auth: FakeAuth(user: FakeAuth.person),
      ),
    );
    await tester.pump();

    final logo = tester.widget<Text>(find.text('note_dude'));
    expect(logo.style?.fontFamily, 'FiraCode');
    expect(logo.style?.fontFamilyFallback, contains('ui-monospace'));
    expect(find.text('NOTEDUDE'), findsNothing);
  });
}
