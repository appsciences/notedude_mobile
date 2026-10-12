import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  final captures = <VoiceCapture>[];
  @override
  Future<List<VoiceCapture>> load() async => List.of(captures);
  @override
  Future<void> save(VoiceCapture capture) async => captures.insert(0, capture);
}

class _Transcriber implements TranscriptionProvider {
  _Transcriber(this.onTranscribe);

  final Future<String> Function(String path) onTranscribe;
  final paths = <String>[];

  @override
  Future<String> transcribe(
    String audioPath, {
    void Function(TranscriptionProgress progress)? onProgress,
  }) {
    paths.add(audioPath);
    return onTranscribe(audioPath);
  }

  @override
  Future<void> dispose() async {}
}

Future<void> _recordAndStop(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.mic_rounded));
  await tester.pump();
  await tester.tap(find.byIcon(Icons.stop_rounded));
  await tester.pump();
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required _Store store,
  required TranscriptionProvider transcriber,
}) async {
  await tester.pumpWidget(
    NoteDudeApp(
      recorder: _Recorder(),
      store: store,
      transcriber: transcriber,
      auth: FakeAuth(user: FakeAuth.person),
    ),
  );
  await tester.pump();
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('transcript fills the note text after recording stops', (
    tester,
  ) async {
    final transcriber = _Transcriber((_) async => 'buy coffee beans');
    await _pumpApp(tester, store: _Store(), transcriber: transcriber);

    await _recordAndStop(tester);
    await tester.pump();

    expect(transcriber.paths, ['/tmp/capture.m4a']);
    expect(_fieldText(tester), 'buy coffee beans');
  });

  testWidgets('failed transcription keeps the audio and stays saveable', (
    tester,
  ) async {
    final store = _Store();
    final transcriber = _Transcriber((_) async => throw Exception('no model'));
    await _pumpApp(tester, store: store, transcriber: transcriber);

    await _recordAndStop(tester);
    await tester.pump();

    expect(find.textContaining('Transcription failed'), findsOneWidget);
    expect(find.textContaining('Audio retained'), findsOneWidget);
    expect(_fieldText(tester), isEmpty);

    await tester.tap(find.text('Save locally'));
    await tester.pump();
    expect(store.captures, hasLength(1));
    expect(store.captures.single.audioPath, '/tmp/capture.m4a');
  });

  testWidgets('transcript never overwrites text the user already typed', (
    tester,
  ) async {
    final pending = Completer<String>();
    final transcriber = _Transcriber((_) => pending.future);
    await _pumpApp(tester, store: _Store(), transcriber: transcriber);

    await _recordAndStop(tester);
    await tester.enterText(find.byType(TextField), 'my own words');
    pending.complete('machine words');
    await tester.pump();

    expect(_fieldText(tester), 'my own words');
  });

  testWidgets('late transcript is dropped after the capture was saved', (
    tester,
  ) async {
    final pending = Completer<String>();
    final store = _Store();
    var calls = 0;
    // Only the first capture waits on the slow result; the next one is empty.
    final transcriber = _Transcriber(
      (_) => ++calls == 1 ? pending.future : Future.value(''),
    );
    await _pumpApp(tester, store: store, transcriber: transcriber);

    await _recordAndStop(tester);
    await tester.tap(find.text('Save locally'));
    await tester.pump();
    pending.complete('stale words');
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    expect(store.captures.single.text, isEmpty);

    // The next capture starts clean and is not polluted by the stale result.
    await _recordAndStop(tester);
    expect(_fieldText(tester), isEmpty);
  });

  group('downloadModelFile', () {
    late Directory dir;
    late HttpServer server;

    setUp(() async {
      // The widget test binding stubs every HttpClient to answer 400.
      HttpOverrides.global = null;
      dir = await Directory.systemTemp.createTemp('model_dl');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('writes the complete file atomically and reports progress', () async {
      final body = List<int>.filled(4096, 7);
      server.listen((request) {
        request.response
          ..contentLength = body.length
          ..add(body);
        request.response.close();
      });
      final target = File('${dir.path}/ggml-base.bin');
      final fractions = <double>[];

      await downloadModelFile(url('/m'), target, onProgress: fractions.add);

      expect(await target.length(), body.length);
      expect(File('${target.path}.part').existsSync(), isFalse);
      expect(fractions.last, 1.0);
    });

    test('an HTTP error never leaves a model file behind', () async {
      server.listen((request) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        request.response.close();
      });
      final target = File('${dir.path}/ggml-base.bin');

      await expectLater(
        downloadModelFile(url('/missing'), target),
        throwsA(isA<TranscriptionException>()),
      );

      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('a truncated body is rejected and the partial is removed', () async {
      server.listen((request) async {
        // Promise 10000 bytes, deliver 100, then drop the connection.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.add(
          'HTTP/1.1 200 OK\r\nContent-Length: 10000\r\n\r\n'.codeUnits,
        );
        socket.add(List<int>.filled(100, 1));
        await socket.flush();
        socket.destroy();
      });
      final target = File('${dir.path}/ggml-base.bin');

      await expectLater(
        downloadModelFile(url('/short'), target),
        throwsA(anything),
      );

      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });
  });
}
