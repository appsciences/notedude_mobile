import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notedude_mobile/auth.dart';
import 'package:notedude_mobile/capture.dart';
import 'package:notedude_mobile/main.dart';
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
  @override
  Future<List<VoiceCapture>> load() async => [];
  @override
  Future<void> save(VoiceCapture capture) async {}
}

class _Transcriber implements TranscriptionProvider {
  @override
  Future<void> dispose() async {}
  @override
  Future<String> transcribe(
    String audioPath, {
    void Function(TranscriptionProgress progress)? onProgress,
  }) async => '';
}

Future<void> _pump(WidgetTester tester, FakeAuth auth) async {
  await tester.pumpWidget(
    NoteDudeApp(
      recorder: _Recorder(),
      store: _Store(),
      transcriber: _Transcriber(),
      auth: auth,
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('signed out users see sign-in, not the capture screen', (
    tester,
  ) async {
    await _pump(tester, FakeAuth());

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
  });

  testWidgets('already signed in users go straight to capture', (tester) async {
    await _pump(tester, FakeAuth(user: FakeAuth.person));

    expect(find.text('Continue with Google'), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });

  testWidgets('signing in with Google reveals the capture screen', (
    tester,
  ) async {
    final auth = FakeAuth();
    await _pump(tester, auth);

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.pump();

    expect(auth.signInCalls, 1);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });

  testWidgets('cancelling the Google prompt is not shown as an error', (
    tester,
  ) async {
    final auth = FakeAuth()..signInError = const AuthException.cancelled();
    await _pump(tester, auth);

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.textContaining('failed'), findsNothing);
  });

  testWidgets('a sign-in failure is explained and can be retried', (
    tester,
  ) async {
    final auth = FakeAuth()..signInError = const AuthException('No network.');
    await _pump(tester, auth);

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Sign-in failed'), findsOneWidget);
    expect(find.textContaining('No network.'), findsOneWidget);

    auth.signInError = null;
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });

  testWidgets('the sign-in button is disabled while a sign-in is running', (
    tester,
  ) async {
    final auth = _SlowAuth();
    await _pump(tester, auth);

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.tap(find.text('Continue with Google'), warnIfMissed: false);
    await tester.pump();

    expect(auth.signInCalls, 1);
    auth.finish();
    await tester.pump();
  });

  testWidgets('signing out returns to the sign-in screen', (tester) async {
    final auth = FakeAuth(user: FakeAuth.person);
    await _pump(tester, auth);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('leo@example.com'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.text('Continue with Google'), findsOneWidget);
  });
}

class _SlowAuth extends FakeAuth {
  final _gate = Completer<void>();

  void finish() => _gate.complete();

  @override
  Future<void> signInWithGoogle() async {
    signInCalls++;
    await _gate.future;
  }
}
