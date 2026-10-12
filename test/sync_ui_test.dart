import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notedude_mobile/capture.dart';
import 'package:notedude_mobile/main.dart';
import 'package:notedude_mobile/sync.dart';
import 'package:notedude_mobile/transcription.dart';

import 'fake_auth.dart';

class _Recorder implements VoiceRecorder {
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

class _Store implements CaptureStore {
  final captures = <VoiceCapture>[];
  @override
  Future<List<VoiceCapture>> load() async => List.of(captures);
  @override
  Future<void> save(VoiceCapture capture) async {
    final index = captures.indexWhere((item) => item.id == capture.id);
    if (index == -1) {
      captures.insert(0, capture);
    } else {
      captures[index] = capture;
    }
  }
}

class _Transcriber implements TranscriptionProvider {
  @override
  Future<void> dispose() async {}
  @override
  Future<String> transcribe(
    String audioPath, {
    void Function(TranscriptionProgress progress)? onProgress,
  }) async => 'Buy coffee';
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeAuth auth,
  required FakeNoteApi api,
  required _Store store,
}) async {
  await tester.pumpWidget(
    NoteDudeApp(
      recorder: _Recorder(),
      store: store,
      transcriber: _Transcriber(),
      auth: auth,
      api: api,
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String button) async {
  await tester.tap(find.byIcon(Icons.mic_rounded));
  await tester.pump();
  await tester.tap(find.byIcon(Icons.stop_rounded));
  await tester.pump();
  await tester.pump();
  await tester.tap(find.text(button));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

VoiceCapture _pending(String id) => VoiceCapture(
  id: id,
  createdAt: DateTime.utc(2026, 10, 12),
  audioPath: '/tmp/$id.m4a',
  duration: const Duration(seconds: 3),
  text: 'queued $id',
  kind: CaptureKind.note,
);

void main() {
  testWidgets('signed in: the button says Save & sync and uploads', (
    tester,
  ) async {
    final api = FakeNoteApi();
    final store = _Store();
    await _pump(
      tester,
      auth: FakeAuth(user: FakeAuth.person),
      api: api,
      store: store,
    );

    expect(find.text('Save locally'), findsNothing);
    await _capture(tester, 'Save & sync');

    expect(api.requests.single.transcript, 'Buy coffee');
    expect(store.captures.single.syncState, SyncState.synced);
    expect(find.textContaining('Synced to NoteDude'), findsOneWidget);
    expect(find.text('0 OUTBOX'), findsOneWidget);
  });

  testWidgets('signed out: saves locally and never uploads', (tester) async {
    final api = FakeNoteApi();
    final store = _Store();
    await _pump(tester, auth: FakeAuth(), api: api, store: store);

    await _capture(tester, 'Save locally');

    expect(api.requests, isEmpty);
    expect(store.captures.single.syncState, SyncState.savedLocally);
    expect(find.text('1 OUTBOX'), findsOneWidget);
  });

  testWidgets('a failed upload keeps the capture and says why', (tester) async {
    final api = FakeNoteApi()..failWith = const SyncException('No network.');
    final store = _Store();
    await _pump(
      tester,
      auth: FakeAuth(user: FakeAuth.person),
      api: api,
      store: store,
    );

    await _capture(tester, 'Save & sync');

    expect(store.captures.single.syncState, SyncState.failed);
    expect(find.textContaining('No network.'), findsOneWidget);
    expect(find.text('1 OUTBOX'), findsOneWidget);
  });

  testWidgets('signing in with a backlog asks before uploading it', (
    tester,
  ) async {
    final api = FakeNoteApi();
    final store = _Store()..captures.add(_pending('a'));
    final auth = FakeAuth();
    await _pump(tester, auth: auth, api: api, store: store);
    expect(find.text('1 OUTBOX'), findsOneWidget);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();

    expect(find.textContaining('leo@example.com'), findsWidgets);
    expect(find.text('Sync'), findsOneWidget);
    expect(api.requests, isEmpty);

    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    expect(api.requests.single.transcript, 'queued a');
    expect(find.text('0 OUTBOX'), findsOneWidget);
  });

  testWidgets('Not now leaves the backlog; Sync now uploads it later', (
    tester,
  ) async {
    final api = FakeNoteApi();
    final store = _Store()..captures.add(_pending('a'));
    final auth = FakeAuth();
    await _pump(tester, auth: auth, api: api, store: store);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(api.requests, isEmpty);
    expect(find.text('1 OUTBOX'), findsOneWidget);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();

    expect(api.requests, hasLength(1));
    expect(find.text('0 OUTBOX'), findsOneWidget);
  });

  testWidgets(
    'already signed in with a backlog syncs on start without asking',
    (tester) async {
      final api = FakeNoteApi();
      final store = _Store()..captures.add(_pending('a'));
      await _pump(
        tester,
        auth: FakeAuth(user: FakeAuth.person),
        api: api,
        store: store,
      );
      await tester.pumpAndSettle();

      expect(api.requests, hasLength(1));
      expect(find.text('Sync'), findsNothing);
    },
  );
}
