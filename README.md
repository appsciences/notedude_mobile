# NoteDude Mobile

Android-first companion to [NoteDude](https://notedude2.web.app), focused on the two jobs that the web/Google apps do not handle well:

1. capture a note or task by voice without stopping at pauses, while retaining the original recording; and
2. deliver conspicuous, user-configurable reminders for task notes.

This is intentionally not a general-purpose mobile note editor. See [the product spec](docs/product-spec.md) for scope, platform constraints, and delivery phases.

## Current state

Google sign-in (Firebase Auth), local capture, and on-device transcription are in place. The app records AAC audio until the user explicitly stops, stores recordings in app documents, transcribes the finished file on the phone with Whisper (free tier), lets the user edit the note text and task list, and persists captures to a local sync outbox. The first transcription downloads a speech model (about 140 MB) once. Signed-in captures sync to NoteDude through its MCP service; captures made signed out wait in the outbox. The ChatGPT in-app purchase tier, playback, and alarm delivery are subsequent slices.

## Run

```sh
flutter pub get
flutter run
```

The app targets Android 7.0+ (API 24) and iOS 15.6+. Android is the priority platform because it offers the strongest alarm/full-screen notification options.
