import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'auth.dart';
import 'capture.dart';

/// The production NoteDude MCP service.
final defaultNoteDudeBaseUrl = Uri.parse('https://notedude2-mcp.web.app');

/// The server rejects audio larger than this.
const maxAudioBytes = 20 * 1024 * 1024;

class SyncException implements Exception {
  const SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NoteRequest {
  const NoteRequest({
    required this.transcript,
    this.tags = const [],
    this.filename,
    this.audio,
  });

  /// Text transcribed on the device. The server uses it as written, which is
  /// what keeps the free tier free of server transcription.
  final String transcript;
  final List<String> tags;
  final String? filename;

  /// The original recording, kept alongside the note when it fits.
  final File? audio;
}

class CreatedNote {
  const CreatedNote({required this.noteId});

  final String noteId;
}

abstract interface class NoteDudeApi {
  Future<CreatedNote> createNote(NoteRequest request);
}

class SyncReport {
  const SyncReport({this.synced = 0, this.failed = 0, this.error});

  final int synced;
  final int failed;
  final String? error;
}

/// Uploads outbox captures. A capture is only marked synced after the server
/// confirms it, and a failure keeps it in the outbox for the next run.
class SyncService {
  SyncService({required this.store, required this.api, required this.auth});

  final CaptureStore store;
  final NoteDudeApi api;
  final AuthService auth;
  Future<SyncReport>? _running;

  /// Captures still waiting to reach NoteDude.
  Future<int> pendingCount() async => (await store.load())
      .where((capture) => capture.syncState != SyncState.synced)
      .length;

  /// Runs one pass. A second call while one is running joins it, so a capture
  /// is never uploaded twice by overlapping triggers.
  Future<SyncReport> syncPending() => _running ??= _run().whenComplete(() {
    _running = null;
  });

  Future<SyncReport> _run() async {
    if (auth.currentUser == null) return const SyncReport();
    final pending =
        (await store.load())
            .where((capture) => capture.syncState != SyncState.synced)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    var synced = 0;
    for (final capture in pending) {
      try {
        final created = await api.createNote(
          NoteRequest(
            transcript: capture.syncText,
            tags: capture.syncTags,
            filename: capture.audioPath.split(Platform.pathSeparator).last,
            audio: File(capture.audioPath),
          ),
        );
        await store.save(
          capture.copyWith(
            syncState: SyncState.synced,
            noteId: created.noteId,
            syncedAt: DateTime.now(),
            clearSyncError: true,
          ),
        );
        synced++;
      } catch (error) {
        final message = error is SyncException ? error.message : '$error';
        await store.save(
          capture.copyWith(syncState: SyncState.failed, syncError: message),
        );
        // Stop instead of hammering a broken connection or a spent quota.
        return SyncReport(synced: synced, failed: 1, error: message);
      }
    }
    return SyncReport(synced: synced);
  }
}

/// Talks to the NoteDude MCP service as the signed-in user.
///
/// The app registers itself once as an OAuth client, then trades its Firebase
/// ID token for a short-lived access token. Refresh tokens are deliberately
/// not stored: Firebase already holds the session, so a new exchange is cheap
/// and nothing long-lived sits on the device.
class HttpNoteDudeApi implements NoteDudeApi {
  HttpNoteDudeApi({required this.auth, Uri? baseUrl, File? clientFile})
    : baseUrl = baseUrl ?? defaultNoteDudeBaseUrl,
      _clientFile = clientFile;

  final AuthService auth;
  final Uri baseUrl;
  final File? _clientFile;
  String? _accessToken;
  DateTime? _accessExpiresAt;

  @override
  Future<CreatedNote> createNote(NoteRequest request) async {
    if (auth.currentUser == null) {
      throw const SyncException('Sign in to sync with NoteDude.');
    }
    final arguments = await _arguments(request);
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final token = await _accessTokenValue(forceNew: attempt > 0);
        final response = await _post(
          '/mcp',
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {'name': 'create_audio_note', 'arguments': arguments},
          }),
          contentType: 'application/json',
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json, text/event-stream',
          },
        );
        if (response.status == 401 && attempt == 0) {
          _accessToken = null;
          continue;
        }
        return _parseCreated(response);
      }
      throw const SyncException('NoteDude rejected the sign-in.');
    } on SocketException catch (error) {
      throw SyncException('Could not reach NoteDude: ${error.message}');
    } on TimeoutException {
      throw const SyncException('NoteDude took too long to answer.');
    } on HttpException catch (error) {
      throw SyncException('Could not reach NoteDude: ${error.message}');
    }
  }

  Future<Map<String, Object?>> _arguments(NoteRequest request) async {
    final arguments = <String, Object?>{
      'transcript': request.transcript,
      if (request.tags.isNotEmpty) 'tags': request.tags,
      if (request.filename != null) 'filename': request.filename,
    };
    final audio = request.audio;
    if (audio != null &&
        await audio.exists() &&
        await audio.length() <= maxAudioBytes) {
      arguments['audio_base64'] = base64Encode(await audio.readAsBytes());
      arguments['mime_type'] = _mimeType(audio.path);
    }
    return arguments;
  }

  static String _mimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.aac')) return 'audio/aac';
    return 'audio/mp4';
  }

  CreatedNote _parseCreated(_Response response) {
    if (response.status == 429) {
      throw const SyncException(
        'NoteDude is limiting requests right now. It will retry later.',
      );
    }
    if (response.status != 200) {
      throw SyncException('NoteDude answered HTTP ${response.status}.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const SyncException('NoteDude sent an unreadable answer.');
    }
    final result = decoded is Map ? decoded['result'] : null;
    if (result is! Map) {
      throw const SyncException('NoteDude sent an unexpected answer.');
    }
    if (result['isError'] == true) {
      final content = result['content'];
      final text = content is List && content.isNotEmpty && content.first is Map
          ? (content.first as Map)['text']
          : null;
      throw SyncException(
        text is String ? text : 'NoteDude could not create the note.',
      );
    }
    final structured = result['structuredContent'];
    final noteId = structured is Map ? structured['note_id'] : null;
    if (noteId is! String) {
      throw const SyncException('NoteDude did not confirm the note.');
    }
    return CreatedNote(noteId: noteId);
  }

  Future<String> _accessTokenValue({bool forceNew = false}) async {
    final expires = _accessExpiresAt;
    final cached = _accessToken;
    if (!forceNew &&
        cached != null &&
        expires != null &&
        DateTime.now().isBefore(expires)) {
      return cached;
    }
    final idToken = await auth.idToken(forceRefresh: forceNew);
    if (idToken == null) {
      throw const SyncException('Sign in to sync with NoteDude.');
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      final clientId = await _clientId(forceNew: attempt > 0);
      final response = await _post(
        '/oauth/token',
        Uri(
          queryParameters: {
            'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
            'client_id': clientId,
            'subject_token': idToken,
            'subject_token_type': 'urn:ietf:params:oauth:token-type:id_token',
          },
        ).query,
        contentType: 'application/x-www-form-urlencoded',
      );
      final body = _tryJson(response.body);
      if (response.status == 200 && body['access_token'] is String) {
        final lifetime = (body['expires_in'] as num?)?.toInt() ?? 3600;
        _accessToken = body['access_token'] as String;
        // Renew a minute early so a request never races the expiry.
        _accessExpiresAt = DateTime.now().add(
          Duration(seconds: lifetime > 120 ? lifetime - 60 : lifetime ~/ 2),
        );
        return _accessToken!;
      }
      // The server forgot this client (for example a reset); register again.
      if (body['error'] == 'invalid_client' && attempt == 0) continue;
      throw SyncException(
        'NoteDude sign-in failed (${body['error'] ?? 'HTTP ${response.status}'}).',
      );
    }
    throw const SyncException('NoteDude sign-in failed.');
  }

  Future<File> _file() async {
    final configured = _clientFile;
    if (configured != null) return configured;
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/mcp_client.json');
  }

  Future<String> _clientId({bool forceNew = false}) async {
    final file = await _file();
    if (!forceNew && await file.exists()) {
      final saved = _tryJson(await file.readAsString());
      final id = saved['client_id'];
      if (id is String && id.isNotEmpty) return id;
    }
    final response = await _post(
      '/oauth/register',
      jsonEncode({
        'client_name': 'NoteDude Mobile',
        // The service only accepts https or loopback redirects. The app never
        // uses the browser flow, so this address is never visited.
        'redirect_uris': ['http://127.0.0.1/notedude-mobile'],
      }),
      contentType: 'application/json',
    );
    final body = _tryJson(response.body);
    final id = body['client_id'];
    if (response.status != 201 || id is! String) {
      throw SyncException(
        'Could not register with NoteDude (HTTP ${response.status}).',
      );
    }
    await file.writeAsString(jsonEncode({'client_id': id}), flush: true);
    return id;
  }

  static Map<String, Object?> _tryJson(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } on FormatException {
      return const {};
    }
  }

  Future<_Response> _post(
    String path,
    String body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = baseUrl.replace(path: path);
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.parse(contentType);
      headers.forEach(request.headers.set);
      request.add(utf8.encode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 120),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 120));
      return _Response(response.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }
}

class _Response {
  const _Response(this.status, this.body);

  final int status;
  final String body;
}
