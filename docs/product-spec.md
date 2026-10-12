# NoteDude Mobile product spec

Status: working draft, 2026-08-25

## Product decision

NoteDude Mobile is a capture and alert companion, not a second full NoteDude client. Google Keep and Google Tasks may remain useful views/integration endpoints, but they are not the mobile system of record. NoteDude's existing Firestore note collection remains the canonical store.

The mobile app has exactly two primary responsibilities:

1. **Voice capture:** make it faster and safer to create a NoteDude note or task by speaking.
2. **Unmissable reminders:** alert as strongly as the operating system and user permissions allow when a task is due.

Anything that does not improve one of those jobs is out of scope for the MVP.

## Existing NoteDude contract

The desktop/web app stores notes at `users/{uid}/notes/{noteId}` with these fields:

- `content: string`
- `pinned: boolean`
- `tagPinned: boolean`
- `createdAt: number`
- `updatedAt: server timestamp`

A task is a normal note containing exactly one `#tasks-*` tag. Existing lists are:

- `#tasks-inbox`
- `#tasks-today`
- `#tasks-nearterm`
- `#tasks-longterm`
- `#tasks-done`

Mobile-created tasks default to `#tasks-inbox`. The mobile client must write the same document shape so notes appear without a migration or a parallel task model.

Audio cannot be added directly to those documents without changing the current Firestore field whitelist. The proposed compatible extension is optional capture metadata (`captureId` / `audioPath` or a related capture document) plus an object in Firebase Storage. That schema and its security rules must be implemented in the NoteDude repository alongside sync.

## Voice-capture experience

### Happy path

1. Launching the app opens directly to a large **Hold to talk / Tap to record** surface. A home-screen shortcut and Quick Settings tile are later accelerators to the same flow.
2. Recording continues through silence and ends only when the user taps Stop (or a generous safety limit is reached). No silence timeout.
3. The raw recording is durably stored before transcription begins.
4. Transcription fills an editable text field. Failure never discards the audio; it leaves a recoverable capture in the outbox.
5. The user chooses Note or Task. Task defaults to Inbox and may choose another `#tasks-*` list.
6. Save is immediate and offline-first. The app shows `Saved locally` and later `Synced`, rather than blocking capture on the network.

### Requirements

- AAC/M4A mono recording, suitable for speech and modest storage use.
- Explicit stop; pause/resume supported.
- Recording duration and clear live state are always visible.
- Audio retained by default and linked to the created note/capture.
- Editable transcription; never pretend transcription is certain.
- Empty transcript is valid if audio exists, but sync requires either text or a deterministic placeholder.
- Interrupted/crashed captures are recovered when possible.
- Local captures queue idempotently using a client-generated ID.

### Transcription decision

Do not use silence-driven live dictation as the source recording. Record first, then transcribe the finished file. This preserves the source and avoids Google Keep's premature cutoff failure mode.

The transcription provider is deliberately behind a `TranscriptionProvider` interface (`lib/transcription.dart`).

**Decision (free release):** transcription runs on the device with whisper.cpp (`whisper_ggml`), fed the finished recording. Because the file is transcribed after the fact, pauses in speech cannot end it early, which is the failure mode of the OS dictation APIs. Live OS dictation (`speech_to_text`) is explicitly rejected as the capture path.

**Paid tier:** ChatGPT transcription is sold as an in-app purchase and implements the same interface server-side. It needs an authenticated upload endpoint, entitlement verification, explicit privacy messaging, retry behavior, and a deletion/retention policy. API secrets must never ship in the mobile binary.

On-device details:

- Default model is Whisper `base` (multilingual, language auto-detected, roughly 140 MB). It is downloaded once on first use rather than bundled, with visible progress.
- The download streams to a `.part` file and is renamed into place only after an HTTP 200 and the full declared length arrives, so an error page or interrupted download can never be used as a model.
- Failure never discards audio: the capture stays reviewable and saveable, and the user can type the note.
- A transcript never overwrites text the user already typed, and a late result for a capture that was saved or restarted is dropped.
- AAC input is converted by the bundled FFmpeg, which adds to the app size.
- Requires Android API 24+ and iOS 15.6+.

## Task and reminder model

Task content remains a NoteDude note with one `#tasks-*` tag. Reminder data is additional structured metadata associated by note ID:

- due instant and original time zone
- reminder enabled
- alert profile (`normal`, `loud`, `alarm`)
- completion/dismissal state
- scheduling version, for idempotent rescheduling

The first reminder editor should offer common presets plus a date/time picker. Natural-language due-date extraction is an enhancement, not a blocker.

## Alert behavior and honest platform limits

### Android (primary)

- Use a high-importance notification channel with a bundled, intentionally loud sound, vibration, lock-screen visibility, and action buttons (Done, Snooze).
- The user owns channel behavior after creation; Android does not let an app silently change a channel's sound later. Provide a one-tap route to the channel settings and a **Test alert** action.
- Exact timing may require the special Alarms & reminders permission on modern Android. Detect it, explain why it matters, request it in context, and degrade to an inexact alert if denied.
- Full-screen intents are reserved for calling/alarm use cases on Android 14+ and may be revoked by Play policy. The `alarm` profile may request this only if NoteDude legitimately qualifies and the user explicitly enables it. Otherwise use a heads-up notification and a dedicated ringing activity where permitted.
- Reschedule active reminders after reboot, time-zone change, app update, and permission changes.

### iOS (secondary)

- Time Sensitive notifications can be requested, but users remain in control.
- Sounds that override mute/Focus require Apple's Critical Alerts entitlement, which is restricted and must not be assumed. Without it, NoteDude cannot promise Samsung-Calendar-style behavior.

The product promise is therefore **the loudest reliable alert allowed by the current device settings**, accompanied by an in-app readiness check—not an unconditional bypass of system controls.

## Offline data and sync

Each local capture moves through:

`recording → draft → saved locally → transcribing → ready → syncing → synced`

Failures retain the capture with a human-readable retry action. Sync uses the capture ID as the Firestore note ID so retries cannot create duplicates. Audio upload completes before the note is marked fully synced; the text note may sync earlier if the audio link can be added safely without overwriting concurrent edits.

Conflicts follow NoteDude's existing field-level-write principle: mobile should not overwrite content changed elsewhere from a stale snapshot. New captures are simple creates; later mobile editing is outside MVP.

## Privacy and retention

- Microphone permission is requested only when recording starts, with a plain-language reason.
- Audio remains private to the authenticated user under Firebase Storage rules.
- The UI distinguishes `On device`, `Uploading`, and `Synced` states.
- Users can delete a recording without deleting note text.
- Default long-term retention is **keep until user deletes** because the recording is the accuracy fallback. Add a configurable auto-delete-after-sync policy later.
- No analytics may collect transcript or audio content.

## MVP acceptance criteria

- A user can record for at least ten minutes with multiple silent pauses; recording stops only by explicit action or documented safety handling.
- Stopping creates a durable local capture whose audio survives process restart.
- A user can edit text, choose Note or a NoteDude task list, and save offline.
- Repeated sync attempts create one Firestore note, not duplicates.
- The source audio is uploaded and remains associated with its capture/note.
- A task can receive a due time and a testable loud local alert.
- Android setup reports notification permission, channel sound/importance, exact-alarm access, full-screen access, and battery restrictions where detectable.
- Denied permissions produce a clear degraded state, never silent success.

## Identity and authentication

- Identity is Firebase Auth in the existing `notedude2` project, so mobile users are the same accounts as the web app. Sign-in is Google only (`google_sign_in` + `firebase_auth`).
- Sign-in is optional for capture. Recording, on-device transcription, and the local outbox work signed out, on a fresh install, and offline. Sign-in is offered from the account menu and is required only to sync; captures made signed out stay in the outbox and sync after sign-in. Firebase persists the session across launches.
- The NoteDude API is secured by Firebase Auth. Callers send the user's Firebase ID token (`AuthService.idToken`) as `Authorization: Bearer`, refreshing with `forceRefresh` after a rejection.
- Application ID / bundle ID is `com.notedude.app`. Android and iOS apps are registered in `notedude2`. Each developer machine's debug keystore SHA-1, and the release/Play App Signing SHA-1s, must be added to the Android app in Firebase or Google sign-in fails with a configuration error.
- `google-services.json` and `GoogleService-Info.plist` are client identifiers, not secrets, and are committed.

## Delivery slices

1. **Local capture foundation (current):** recorder, explicit stop/pause, editable note/task draft, durable local outbox.
2. **Identity and NoteDude sync (sign-in done, sync pending):** FlutterFire setup, Google sign-in, Firestore-compatible create, Storage upload, retries and sync status. This requires registering Android/iOS apps in Firebase and updating NoteDude security rules.
3. **Transcription:** 
   - **3a. On-device Whisper (free release, in progress):** provider interface, one-time model download with progress, editable result, failure keeps audio.
   - **3b. ChatGPT in-app purchase (paid tier):** purchase and entitlement, authenticated server endpoint, progress and retry, audio playback and deletion.
4. **Reminder foundation:** due-time editor, local scheduling, loud notification channel, notification permission/readiness and Test alert.
5. **Alarm-grade Android UX:** exact-alarm permission, reboot/time-zone rescheduling, full-screen capability check and ringing activity where policy permits.
6. **Capture accelerators:** launcher shortcut, share target, Quick Settings tile, optional lock-screen/widget entry.

## Explicit non-goals for MVP

- Browsing or fully editing the NoteDude library.
- Replacing Google Keep or Google Tasks as general-purpose apps.
- Two-way Google Tasks/Keep synchronization.
- Background always-listening capture or wake words.
- Shipping a transcription service API key in the app.
- Claiming to bypass mute, Do Not Disturb, OEM battery management, or platform policy without the required user setting/entitlement.

## Open product decisions

- Whether Google Keep/Tasks integration remains in NoteDude after direct mobile capture proves reliable.
- Audio-region/retention settings for the paid ChatGPT tier, and the in-app purchase product model (subscription vs. one-time vs. credits).
- Whether to offer a Wi-Fi-only or confirm-before-download prompt for the on-device model, and whether a smaller `tiny` model should be the fallback on low-end devices.
- Whether mobile reminder metadata lives in the note document (requiring schema/rules changes) or a sibling collection.
- Whether `#tasks-today` should imply a default due time or remain only an organizational tag.
- Display name capitalization (the application ID is settled as `com.notedude.app`).
