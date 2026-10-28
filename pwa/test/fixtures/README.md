# Synthetic audio fixtures

These files contain synthetic speech, not personal voice recordings. Generated locally with
FFmpeg's Flite `slt` voice. Run `bash scripts/audio-fixtures.sh` to regenerate; bytes may vary
between FFmpeg/Flite versions.

Expected speech: **Remember to send Sam the project proposal tomorrow morning.**

- `idea.wav`: mono PCM, 16 kHz. Real Chromium fake microphone input.
- `idea.m4a`: AAC version to validate the Safari server-input format during live QA.
- `silence.wav`: two seconds of silence. Must not trigger an automatic silence stop.
- `idea-with-pause.wav`: speech with 500 ms leading silence and three trailing seconds of silence.

Playwright feeds `idea-with-pause.wav` to Chromium's native fake microphone, then the actual
MediaRecorder encodes it. It does not substitute a fake recorder. Mock MCP responses isolate
recording and upload behavior from paid APIs. A separate test-account upload of `idea.m4a`
is required to verify actual OpenAI transcription; verify key terms rather than punctuation.
