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
      api: FakeNoteApi(),
    ),
  );
  await tester.pump();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Account'));
  await tester.pumpAndSettle();
}

void main() {
  _avatarTests();
  testWidgets('signed out users can capture without signing in', (
    tester,
  ) async {
    await _pump(tester, FakeAuth());

    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.text('Continue with Google'), findsNothing);
  });

  testWidgets('a capture saved while signed out says sign in to sync', (
    tester,
  ) async {
    await _pump(tester, FakeAuth());

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    await tester.tap(find.text('Save locally'));
    await tester.pump();

    expect(find.textContaining('sign in to sync'), findsOneWidget);
  });

  testWidgets('the account menu offers Google sign-in when signed out', (
    tester,
  ) async {
    final auth = FakeAuth();
    await _pump(tester, auth);

    await _openMenu(tester);
    expect(find.text('Sign in with Google'), findsOneWidget);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();

    expect(auth.signInCalls, 1);
    await _openMenu(tester);
    expect(find.text('leo@example.com'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('already signed in users see their account', (tester) async {
    await _pump(tester, FakeAuth(user: FakeAuth.person));

    await _openMenu(tester);
    expect(find.text('leo@example.com'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsNothing);
  });

  testWidgets('cancelling the Google prompt is not shown as an error', (
    tester,
  ) async {
    final auth = FakeAuth()..signInError = const AuthException.cancelled();
    await _pump(tester, auth);

    await _openMenu(tester);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();

    expect(find.textContaining('failed'), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });

  testWidgets('a sign-in failure is explained and can be retried', (
    tester,
  ) async {
    final auth = FakeAuth()..signInError = const AuthException('No network.');
    await _pump(tester, auth);

    await _openMenu(tester);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sign-in failed'), findsOneWidget);
    expect(find.textContaining('No network.'), findsOneWidget);

    auth.signInError = null;
    await _openMenu(tester);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();
    expect(auth.currentUser, isNotNull);
  });

  testWidgets('sign-in cannot be started twice while one is running', (
    tester,
  ) async {
    final auth = _SlowAuth();
    await _pump(tester, auth);

    await _openMenu(tester);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pump();
    await _openMenu(tester);
    final item = find.text('Signing in…');
    expect(item, findsOneWidget);
    await tester.tap(item, warnIfMissed: false);
    await tester.pump();

    expect(auth.signInCalls, 1);
    auth.finish();
    await tester.pumpAndSettle();
  });

  testWidgets('signing out keeps the capture screen and local data', (
    tester,
  ) async {
    final auth = FakeAuth(user: FakeAuth.person);
    await _pump(tester, auth);

    await _openMenu(tester);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    await _openMenu(tester);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}

void _avatarTests() {
  group('account avatar', () {
    test('initials: first and last name, else first letter of the email', () {
      String initials({String? name, String? email}) =>
          initialsFor(AuthUser(uid: 'u', displayName: name, email: email));

      expect(initials(name: 'Leo Pelekh'), 'LP');
      expect(initials(name: 'leo   van der pelekh'), 'LP');
      expect(initials(name: 'Leo'), 'L');
      expect(initials(name: '  ', email: 'zed@example.com'), 'Z');
      expect(initials(email: 'zed@example.com'), 'Z');
      expect(initials(), '?');
    });

    testWidgets('signed out shows the neutral account icon, no initials', (
      tester,
    ) async {
      await _pump(tester, FakeAuth());

      expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
      expect(find.byKey(const Key('account-avatar')), findsNothing);
    });

    testWidgets('signed in without a photo shows initials', (tester) async {
      final auth = FakeAuth(
        user: const AuthUser(
          uid: 'u1',
          email: 'leo@example.com',
          displayName: 'Leo Pelekh',
        ),
      );
      await _pump(tester, auth);

      expect(find.byKey(const Key('account-avatar')), findsOneWidget);
      expect(find.text('LP'), findsOneWidget);
      expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
    });

    testWidgets('signed in with a photo shows it, with initials behind it', (
      tester,
    ) async {
      final auth = FakeAuth(
        user: const AuthUser(
          uid: 'u1',
          email: 'leo@example.com',
          displayName: 'Leo Pelekh',
          photoUrl: 'https://example.com/leo.png',
        ),
      );
      await _pump(tester, auth);

      expect(find.byType(Image), findsOneWidget);
      // Offline or a failed load must still say who is signed in.
      expect(find.text('LP'), findsOneWidget);
    });

    testWidgets('the avatar opens the account menu', (tester) async {
      await _pump(tester, FakeAuth(user: FakeAuth.person));

      await tester.tap(find.byKey(const Key('account-avatar')));
      await tester.pumpAndSettle();

      expect(find.text('leo@example.com'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('signing in swaps the icon for the avatar', (tester) async {
      final auth = FakeAuth();
      await _pump(tester, auth);
      expect(find.byKey(const Key('account-avatar')), findsNothing);

      await _openMenu(tester);
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account-avatar')), findsOneWidget);
    });
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
