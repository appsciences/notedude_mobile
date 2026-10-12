import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notedude_mobile/auth.dart';
import 'package:notedude_mobile/capture.dart';
import 'package:notedude_mobile/sync.dart';

import 'fake_auth.dart';

VoiceCapture _capture(
  String id, {
  String text = 'Buy coffee',
  CaptureKind kind = CaptureKind.note,
  String? audioPath,
  SyncState state = SyncState.savedLocally,
}) => VoiceCapture(
  id: id,
  createdAt: DateTime.utc(2026, 10, 12, 9),
  audioPath: audioPath ?? '/nonexistent/$id.m4a',
  duration: const Duration(seconds: 4),
  text: text,
  kind: kind,
  syncState: state,
);

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

class _Api implements NoteDudeApi {
  final sent = <String>[];
  final requests = <NoteRequest>[];
  Object? failWith;
  Completer<void>? gate;
  int _next = 0;

  @override
  Future<CreatedNote> createNote(NoteRequest request) async {
    await gate?.future;
    final error = failWith;
    if (error != null) throw error;
    requests.add(request);
    sent.add(request.transcript);
    return CreatedNote(noteId: 'note-${++_next}');
  }
}

void main() {
  group('VoiceCapture sync fields', () {
    test('round-trips sync state and tolerates old outbox entries', () {
      final synced = _capture(
        'a',
        state: SyncState.synced,
      ).copyWith(noteId: 'n1', syncedAt: DateTime.utc(2026, 10, 12, 10));
      final restored = VoiceCapture.fromJson(synced.toJson());
      expect(restored.syncState, SyncState.synced);
      expect(restored.noteId, 'n1');
      expect(restored.syncedAt, DateTime.utc(2026, 10, 12, 10));

      final legacy = VoiceCapture.fromJson({
        'id': 'old',
        'createdAt': '2026-08-25T00:00:00.000Z',
        'audioPath': '/a.m4a',
        'durationMs': 1000,
        'text': 'hi',
        'kind': 'note',
        'syncState': 'savedLocally',
      });
      expect(legacy.syncState, SyncState.savedLocally);
      expect(legacy.noteId, isNull);
    });

    test('uses a placeholder for empty text and tags tasks', () {
      expect(_capture('a', text: '  ').syncText, startsWith('Voice note'));
      expect(_capture('a', text: ' Hi ').syncText, 'Hi');
      final task = _capture('a', kind: CaptureKind.task);
      expect(task.syncTags, ['#tasks-inbox']);
      expect(_capture('a').syncTags, isEmpty);
    });
  });

  group('SyncService', () {
    late _Store store;
    late _Api api;
    late FakeAuth auth;
    late SyncService service;

    setUp(() {
      store = _Store();
      api = _Api();
      auth = FakeAuth(user: FakeAuth.person);
      service = SyncService(store: store, api: api, auth: auth);
    });

    test(
      'uploads pending captures oldest first and marks them synced',
      () async {
        store.captures
          ..add(_capture('new', text: 'second'))
          ..add(_capture('old', text: 'first'));
        store.captures[0] = store.captures[0].copyWith(
          createdAt: DateTime.utc(2026, 10, 12, 10),
        );

        final report = await service.syncPending();

        expect(api.sent, ['first', 'second']);
        expect(report.synced, 2);
        expect(report.failed, 0);
        final saved = {for (final c in store.captures) c.id: c};
        expect(saved['old']!.syncState, SyncState.synced);
        expect(saved['old']!.noteId, 'note-1');
        expect(saved['old']!.syncedAt, isNotNull);
      },
    );

    test('does nothing while signed out', () async {
      store.captures.add(_capture('a'));
      final signedOut = SyncService(store: store, api: api, auth: FakeAuth());

      final report = await signedOut.syncPending();

      expect(api.sent, isEmpty);
      expect(report.synced, 0);
      expect(store.captures.single.syncState, SyncState.savedLocally);
    });

    test('skips captures that are already synced', () async {
      store.captures.add(_capture('done', state: SyncState.synced));

      await service.syncPending();

      expect(api.sent, isEmpty);
    });

    test('a failure is recorded, kept for retry, and stops the run', () async {
      store.captures
        ..add(_capture('b', text: 'two'))
        ..add(_capture('a', text: 'one'));
      store.captures[1] = store.captures[1].copyWith(
        createdAt: DateTime.utc(2026, 10, 12, 8),
      );
      api.failWith = const SyncException('No network.');

      final report = await service.syncPending();

      expect(report.failed, 1);
      expect(report.synced, 0);
      final saved = {for (final c in store.captures) c.id: c};
      expect(saved['a']!.syncState, SyncState.failed);
      expect(saved['a']!.syncError, 'No network.');
      // The run stops rather than hammering a broken connection.
      expect(saved['b']!.syncState, SyncState.savedLocally);

      api.failWith = null;
      final retry = await service.syncPending();
      expect(retry.synced, 2);
    });

    test('a failed capture is retried on the next run', () async {
      store.captures.add(
        _capture('a', state: SyncState.failed).copyWith(syncError: 'boom'),
      );

      await service.syncPending();

      expect(store.captures.single.syncState, SyncState.synced);
      expect(store.captures.single.syncError, isNull);
    });

    test('concurrent runs do not upload a capture twice', () async {
      store.captures.add(_capture('a'));
      api.gate = Completer<void>();

      final first = service.syncPending();
      final second = service.syncPending();
      api.gate!.complete();
      await Future.wait([first, second]);

      expect(api.sent, hasLength(1));
    });

    test('sends the task tag and the on-device transcript', () async {
      store.captures.add(
        _capture('t', text: 'Call Sam', kind: CaptureKind.task),
      );

      await service.syncPending();

      final request = api.requests.single;
      expect(request.transcript, 'Call Sam');
      expect(request.tags, ['#tasks-inbox']);
      expect(request.filename, 't.m4a');
    });
  });

  group('HttpNoteDudeApi', () {
    late Directory dir;
    late HttpServer server;
    late List<Map<String, Object?>> exchanges;
    late List<Map<String, Object?>> toolCalls;
    var registerCalls = 0;
    var mcpStatus = 200;
    Map<String, Object?>? mcpBody;
    var rejectFirstToken = false;
    var tokensIssued = 0;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mcp_api');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      exchanges = [];
      toolCalls = [];
      registerCalls = 0;
      mcpStatus = 200;
      mcpBody = null;
      rejectFirstToken = false;
      tokensIssued = 0;
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        final response = request.response;
        Future<void> json(int status, Object value) async {
          response
            ..statusCode = status
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(value));
          await response.close();
        }

        switch (request.uri.path) {
          case '/oauth/register':
            registerCalls++;
            await json(201, {'client_id': 'c' * 43});
          case '/oauth/token':
            exchanges.add(Uri.splitQueryString(body));
            tokensIssued++;
            await json(200, {
              'access_token': 'access-$tokensIssued',
              'token_type': 'Bearer',
              'expires_in': 3600,
            });
          case '/mcp':
            final decoded = jsonDecode(body) as Map<String, Object?>;
            toolCalls.add({
              'authorization': request.headers.value('authorization'),
              ...decoded,
            });
            if (rejectFirstToken && toolCalls.length == 1) {
              await json(401, {'error': 'unauthorized'});
              return;
            }
            await json(
              mcpStatus,
              mcpBody ??
                  {
                    'jsonrpc': '2.0',
                    'id': 1,
                    'result': {
                      'structuredContent': {
                        'note_id': 'n-42',
                        'status': 'ready',
                        'source_uri': 'gs://bucket/x',
                        'transcript': 'hi',
                        'summary': null,
                        'tags': <String>[],
                      },
                    },
                  },
            );
          default:
            await json(404, {});
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    HttpNoteDudeApi api({AuthService? auth}) => HttpNoteDudeApi(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      auth: auth ?? _TokenAuth(),
      clientFile: File('${dir.path}/mcp_client.json'),
    );

    NoteRequest request({File? audio}) => NoteRequest(
      transcript: 'Buy coffee',
      tags: const ['#tasks-today'],
      filename: 'cap-1.m4a',
      audio: audio,
    );

    test(
      'registers once, exchanges the Firebase token, and creates the note',
      () async {
        final created = await api().createNote(request());

        expect(created.noteId, 'n-42');
        expect(registerCalls, 1);
        expect(exchanges.single, {
          'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
          'client_id': 'c' * 43,
          'subject_token': 'firebase-id-token',
          'subject_token_type': 'urn:ietf:params:oauth:token-type:id_token',
        });
        final call = toolCalls.single;
        expect(call['authorization'], 'Bearer access-1');
        expect(call['method'], 'tools/call');
        final params = call['params'] as Map<String, Object?>;
        expect(params['name'], 'create_audio_note');
        expect(params['arguments'], {
          'transcript': 'Buy coffee',
          'tags': ['#tasks-today'],
          'filename': 'cap-1.m4a',
        });
      },
    );

    test('remembers the registered client across instances', () async {
      await api().createNote(request());
      await api().createNote(request());

      expect(registerCalls, 1);
    });

    test('reuses the access token instead of exchanging every note', () async {
      final client = api();
      await client.createNote(request());
      await client.createNote(request());

      expect(exchanges, hasLength(1));
      expect(toolCalls, hasLength(2));
    });

    test('attaches the original audio as base64 with its MIME type', () async {
      final audio = File('${dir.path}/a.m4a')..writeAsBytesSync([1, 2, 3, 4]);

      await api().createNote(request(audio: audio));

      final args =
          (toolCalls.single['params'] as Map)['arguments']
              as Map<String, Object?>;
      expect(args['audio_base64'], base64Encode([1, 2, 3, 4]));
      expect(args['mime_type'], 'audio/mp4');
    });

    test(
      'sends the text alone when the audio is over the 20 MiB limit',
      () async {
        final big = File('${dir.path}/big.m4a')
          ..writeAsBytesSync(List.filled(20 * 1024 * 1024 + 1, 0));

        await api().createNote(request(audio: big));

        final args =
            (toolCalls.single['params'] as Map)['arguments']
                as Map<String, Object?>;
        expect(args.containsKey('audio_base64'), isFalse);
        expect(args['transcript'], 'Buy coffee');
      },
    );

    test('sends the text alone when the audio file is missing', () async {
      await api().createNote(request(audio: File('${dir.path}/gone.m4a')));

      final args =
          (toolCalls.single['params'] as Map)['arguments']
              as Map<String, Object?>;
      expect(args.containsKey('audio_base64'), isFalse);
    });

    test('exchanges again once when the access token is rejected', () async {
      rejectFirstToken = true;

      final created = await api().createNote(request());

      expect(created.noteId, 'n-42');
      expect(exchanges, hasLength(2));
      expect(toolCalls.last['authorization'], 'Bearer access-2');
    });

    test('surfaces a tool error message', () async {
      mcpBody = {
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'isError': true,
          'content': [
            {'type': 'text', 'text': 'Daily audio note limit reached.'},
          ],
        },
      };

      await expectLater(
        api().createNote(request()),
        throwsA(
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            'Daily audio note limit reached.',
          ),
        ),
      );
    });

    test('reports a rate limit as a retryable failure', () async {
      mcpStatus = 429;
      mcpBody = {'error': 'rate_limited'};

      await expectLater(
        api().createNote(request()),
        throwsA(isA<SyncException>()),
      );
    });

    test('fails clearly when not signed in', () async {
      await expectLater(
        api(auth: FakeAuth()).createNote(request()),
        throwsA(
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            contains('Sign in'),
          ),
        ),
      );
      expect(registerCalls, 0);
    });
  });
}

class _TokenAuth extends FakeAuth {
  _TokenAuth() : super(user: FakeAuth.person);

  @override
  Future<String?> idToken({bool forceRefresh = false}) async =>
      'firebase-id-token';
}
