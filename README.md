# NoteDude Mobile

Android-first companion to [NoteDude](https://notedude2.web.app), focused on the two jobs that the web/Google apps do not handle well:

1. capture a note or task by voice without stopping at pauses, while retaining the original recording; and
2. deliver conspicuous, user-configurable reminders for task notes.

This is intentionally not a general-purpose mobile note editor. See [the product spec](docs/product-spec.md) for scope, platform constraints, and delivery phases.

## Current state

The first local capture slice is in progress. It records AAC audio until the user explicitly stops, stores recordings in app documents, lets the user edit the note text and task list, and persists captures to a local sync outbox. Firebase sync, transcription, playback, and alarm delivery are subsequent slices.

## Run

```sh
flutter pub get
flutter run
```

The app currently targets Android and iOS behavior. Android is the priority platform because it offers the strongest alarm/full-screen notification options.
