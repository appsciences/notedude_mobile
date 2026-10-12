import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'auth.dart';
import 'capture.dart';
import 'transcription.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (error) {
    runApp(StartupErrorApp(error: error));
    return;
  }
  runApp(const NoteDudeApp());
}

class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('NoteDude could not start: $error'),
          ),
        ),
      ),
    );
  }
}

class NoteDudeApp extends StatelessWidget {
  const NoteDudeApp({
    super.key,
    this.recorder,
    this.store,
    this.transcriber,
    this.auth,
  });

  final VoiceRecorder? recorder;
  final CaptureStore? store;
  final TranscriptionProvider? transcriber;
  final AuthService? auth;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoteDude',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xfff2d45c),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff11130f),
        useMaterial3: true,
      ),
      home: _AppRoot(
        auth: auth ?? FirebaseAuthService(),
        recorder: recorder ?? DeviceVoiceRecorder(),
        store: store ?? LocalCaptureStore(),
        transcriber: transcriber ?? WhisperTranscriptionProvider(),
      ),
    );
  }
}

/// Capture never waits on an account: sign-in only matters for syncing, so
/// the screen is always shown and just learns who (if anyone) is signed in.
class _AppRoot extends StatelessWidget {
  const _AppRoot({
    required this.auth,
    required this.recorder,
    required this.store,
    required this.transcriber,
  });

  final AuthService auth;
  final VoiceRecorder recorder;
  final CaptureStore store;
  final TranscriptionProvider transcriber;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthUser?>(
      stream: auth.userChanges,
      initialData: auth.currentUser,
      builder: (context, snapshot) => CaptureScreen(
        recorder: recorder,
        store: store,
        transcriber: transcriber,
        account: snapshot.data,
        onSignIn: auth.signInWithGoogle,
        onSignOut: auth.signOut,
      ),
    );
  }
}

/// The wordmark, in the web app's font stack (Fira Code first, then the
/// platform monospace fonts).
const _logoStyle = TextStyle(
  fontFamily: 'FiraCode',
  fontFamilyFallback: [
    'ui-monospace',
    'SFMono-Regular',
    'Menlo',
    'Monaco',
    'Consolas',
    'monospace',
  ],
  fontWeight: FontWeight.w700,
  fontSize: 20,
);

enum _CaptureStage { ready, recording, paused, review, saving }

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.recorder,
    required this.store,
    required this.transcriber,
    this.account,
    this.onSignIn,
    this.onSignOut,
  });

  final VoiceRecorder recorder;
  final CaptureStore store;
  final TranscriptionProvider transcriber;
  final AuthUser? account;
  final Future<void> Function()? onSignIn;
  final Future<void> Function()? onSignOut;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  static const taskTags = <String>[
    '#tasks-inbox',
    '#tasks-today',
    '#tasks-nearterm',
    '#tasks-longterm',
  ];

  final _text = TextEditingController();
  _CaptureStage _stage = _CaptureStage.ready;
  CaptureKind _kind = CaptureKind.note;
  String _taskTag = taskTags.first;
  String? _audioPath;
  DateTime? _startedAt;
  Duration _duration = Duration.zero;
  Timer? _timer;
  int _savedCount = 0;
  String? _message;
  // Bumped whenever a capture ends or restarts so a slow transcription of an
  // earlier recording can never write into a different capture.
  int _transcriptionToken = 0;
  bool _transcribing = false;
  bool _signingIn = false;
  TranscriptionProgress? _progress;

  @override
  void initState() {
    super.initState();
    widget.store.load().then((captures) {
      if (mounted) setState(() => _savedCount = captures.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    widget.recorder.dispose();
    widget.transcriber.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final path = await widget.recorder.start();
      _transcriptionToken++;
      _startedAt = DateTime.now();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _stage == _CaptureStage.recording) {
          setState(() => _duration = DateTime.now().difference(_startedAt!));
        }
      });
      setState(() {
        _audioPath = path;
        _duration = Duration.zero;
        _message = null;
        _stage = _CaptureStage.recording;
      });
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  Future<void> _togglePause() async {
    if (_stage == _CaptureStage.recording) {
      await widget.recorder.pause();
      setState(() => _stage = _CaptureStage.paused);
    } else {
      await widget.recorder.resume();
      setState(() => _stage = _CaptureStage.recording);
    }
  }

  Future<void> _stop() async {
    final path = await widget.recorder.stop();
    _timer?.cancel();
    setState(() {
      _audioPath = path ?? _audioPath;
      _stage = _CaptureStage.review;
      _message = 'Recording retained. Add or correct the text before saving.';
    });
    final recording = _audioPath;
    if (recording != null) unawaited(_transcribe(recording));
  }

  Future<void> _signIn() async {
    final signIn = widget.onSignIn;
    if (signIn == null || _signingIn) return;
    setState(() => _signingIn = true);
    String? failure;
    try {
      await signIn();
    } on AuthException catch (error) {
      if (!error.cancelled) failure = error.message;
    } catch (error) {
      failure = '$error';
    }
    if (!mounted) return;
    setState(() => _signingIn = false);
    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sign-in failed: $failure')));
    }
  }

  Future<void> _transcribe(String audioPath) async {
    final token = ++_transcriptionToken;
    bool current() => mounted && token == _transcriptionToken;

    setState(() {
      _transcribing = true;
      _progress = null;
    });
    try {
      final transcript = await widget.transcriber.transcribe(
        audioPath,
        onProgress: (progress) {
          if (current()) setState(() => _progress = progress);
        },
      );
      if (!current()) return;
      setState(() {
        _transcribing = false;
        _progress = null;
        // Never clobber text the user typed while we were working.
        if (_text.text.trim().isEmpty && transcript.isNotEmpty) {
          _text.text = transcript;
          _message =
              'Transcribed on this device. Check the text before saving.';
        }
      });
    } catch (error) {
      if (!current()) return;
      setState(() {
        _transcribing = false;
        _progress = null;
        _message =
            'Transcription failed: $error. Type the note, or save the recording as is.';
      });
    }
  }

  Future<void> _save() async {
    if (_audioPath == null) return;
    setState(() => _stage = _CaptureStage.saving);
    final now = DateTime.now();
    final capture = VoiceCapture(
      id: now.microsecondsSinceEpoch.toString(),
      createdAt: now,
      audioPath: _audioPath!,
      duration: _duration,
      text: _text.text,
      kind: _kind,
      taskTag: _taskTag,
    );
    try {
      await widget.store.save(capture);
      final captures = await widget.store.load();
      _transcriptionToken++;
      setState(() {
        _transcribing = false;
        _progress = null;
        _savedCount = captures.length;
        _stage = _CaptureStage.ready;
        _message = widget.account == null
            ? 'Saved locally · sign in to sync to NoteDude'
            : 'Saved locally · waiting for NoteDude sync';
        _audioPath = null;
        _duration = Duration.zero;
        _kind = CaptureKind.note;
        _taskTag = taskTags.first;
        _text.clear();
      });
    } catch (error) {
      setState(() {
        _stage = _CaptureStage.review;
        _message = 'Could not save locally: $error';
      });
    }
  }

  String get _transcriptionStatus {
    final progress = _progress;
    final percent = progress?.fraction == null
        ? ''
        : ' ${(progress!.fraction! * 100).round()}%';
    return progress?.phase == TranscriptionPhase.downloadingModel
        ? 'Downloading the speech model (one time)…$percent'
        : 'Transcribing on this device…$percent';
  }

  String get _clock {
    final minutes = _duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (_duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final active =
        _stage == _CaptureStage.recording || _stage == _CaptureStage.paused;
    final review =
        _stage == _CaptureStage.review || _stage == _CaptureStage.saving;
    return Scaffold(
      appBar: AppBar(
        title: const Text('note_dude', style: _logoStyle),
        actions: [
          if (widget.onSignIn != null || widget.onSignOut != null)
            PopupMenuButton<String>(
              tooltip: 'Account',
              icon: Icon(
                widget.account == null
                    ? Icons.account_circle_outlined
                    : Icons.account_circle,
              ),
              onSelected: (value) {
                if (value == 'signin') _signIn();
                if (value == 'signout') widget.onSignOut?.call();
              },
              itemBuilder: (context) => widget.account == null
                  ? [
                      PopupMenuItem<String>(
                        value: 'signin',
                        enabled: !_signingIn,
                        child: Text(
                          _signingIn ? 'Signing in…' : 'Sign in with Google',
                        ),
                      ),
                    ]
                  : [
                      PopupMenuItem<String>(
                        enabled: false,
                        child: Text(widget.account!.label),
                      ),
                      const PopupMenuItem<String>(
                        value: 'signout',
                        child: Text('Sign out'),
                      ),
                    ],
            ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '$_savedCount OUTBOX',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                active
                    ? (_stage == _CaptureStage.paused ? 'PAUSED' : 'RECORDING')
                    : review
                    ? 'REVIEW CAPTURE'
                    : 'CAPTURE A THOUGHT',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(letterSpacing: 1.5),
              ),
              const SizedBox(height: 12),
              if (!review)
                Expanded(child: _recordSurface(active))
              else
                Expanded(child: _reviewSurface()),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _recordSurface(bool active) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _clock,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 54,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 32),
        Semantics(
          button: true,
          label: active ? 'Stop recording' : 'Start recording',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: active ? _stop : _start,
            child: Ink(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? const Color(0xffe35d4f)
                    : Theme.of(context).colorScheme.primary,
                boxShadow: [
                  BoxShadow(
                    color:
                        (active
                                ? const Color(0xffe35d4f)
                                : Theme.of(context).colorScheme.primary)
                            .withValues(alpha: .24),
                    blurRadius: 0,
                    spreadRadius: 18,
                  ),
                ],
              ),
              child: Icon(
                active ? Icons.stop_rounded : Icons.mic_rounded,
                size: 82,
                color: const Color(0xff171810),
              ),
            ),
          ),
        ),
        const SizedBox(height: 34),
        Text(
          active ? 'Tap to stop · silence is okay' : 'Tap to record',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (active) ...[
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _togglePause,
            icon: Icon(
              _stage == _CaptureStage.paused ? Icons.play_arrow : Icons.pause,
            ),
            label: Text(_stage == _CaptureStage.paused ? 'Resume' : 'Pause'),
          ),
        ],
      ],
    );
  }

  Widget _reviewSurface() {
    return ListView(
      children: [
        Row(
          children: [
            const Icon(Icons.graphic_eq),
            const SizedBox(width: 10),
            Text(
              'Audio retained · $_clock',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
        if (_transcribing) ...[
          const SizedBox(height: 14),
          LinearProgressIndicator(value: _progress?.fraction),
          const SizedBox(height: 8),
          Text(_transcriptionStatus, style: const TextStyle(fontSize: 13)),
        ],
        const SizedBox(height: 18),
        TextField(
          controller: _text,
          autofocus: true,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Note text',
            hintText:
                'Transcription appears here when ready. You can also type.',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 18),
        SegmentedButton<CaptureKind>(
          segments: const [
            ButtonSegment(
              value: CaptureKind.note,
              icon: Icon(Icons.notes),
              label: Text('Note'),
            ),
            ButtonSegment(
              value: CaptureKind.task,
              icon: Icon(Icons.check_circle_outline),
              label: Text('Task'),
            ),
          ],
          selected: {_kind},
          onSelectionChanged: (value) => setState(() => _kind = value.first),
        ),
        if (_kind == CaptureKind.task) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _taskTag,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'NoteDude task list',
            ),
            items: taskTags
                .map((tag) => DropdownMenuItem(value: tag, child: Text(tag)))
                .toList(),
            onChanged: (value) =>
                setState(() => _taskTag = value ?? taskTags.first),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _stage == _CaptureStage.saving ? null : _save,
          icon: _stage == _CaptureStage.saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('Save locally'),
          ),
        ),
      ],
    );
  }
}
