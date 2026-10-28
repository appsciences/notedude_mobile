# NoteDude Mobile: iPhone voice PWA

Status: Draft specification; implementation candidate in `pwa/`.

Last updated: 2026-10-27

## Goal

Capture a spoken idea by opening a Home Screen web app, speaking, and pressing Stop.
Preserve the original audio and save it with its transcript in the user's NoteDude account.
Installation must not require an Apple developer account, an App Store purchase, or a native build.

This specification governs the React PWA. It supersedes the Android-first launch and
transcription choices in `docs/product-spec.md` only for this PWA. The Flutter app remains
an independent client. Requirements use MUST for acceptance criteria and SHOULD for preferences.

## Repository evidence and decisions

- `appsciences/notedude_mobile` is Flutter/Dart, not React Native. Create a React browser
  application in `pwa/`; React Native Web would not reuse the Flutter implementation.
- `appsciences/notedude_core` supplies framework-independent note semantics and repository
  ports. It does not own audio capture or transcription. No core change is required.
- `appsciences/notedude2` is the existing NoteDude web application. Preserve its note contract.
- `appsciences/notedude_mcp` already implements `create_audio_note`, Firebase Cloud Storage,
  Firestore persistence, OAuth 2.1, and OpenAI transcription and summarization in the Firebase
  HTTPS Function `notedudeMcp`. Reuse this function; do not create a competing transcription API.
- Current MCP source: `82345ec295cb4586584ea9c76072fa43101ba404`.
  Current mobile baseline: `7ebe84b3b5c82d2c0913a22c5239bfeb87eee70d`.
- The service currently requires `users/{uid}.plan == "paid"` for audio-only uploads.
  Supplying a transcript skips OpenAI calls and works on the free plan. The PWA MUST NOT
  change entitlements, imply server transcription is free, or ship an OpenAI key.
- The current server transcription default is `gpt-transcribe`. Before release, the deployment
  owner MUST verify a valid enabled model identifier; `gpt-4o-mini-transcribe` is the initial
  low-cost candidate. Model availability, current pricing and live deployment parameters
  have not been verified. A ChatGPT subscription is separate from OpenAI API billing.

## User journey

1. Open the HTTPS page in Safari and install through Share → Add to Home Screen.
2. On launch, the app attempts microphone access and begins recording immediately if allowed.
3. If browser policy requires permission or a gesture, show one prominent Tap to start action.
   The product MUST NOT promise silent first-launch microphone access or guaranteed zero-tap
   capture on every iPhone. Opening the Home Screen icon is not guaranteed to supply the
   page with a usable browser gesture.
4. During recording show an unmistakable recording state, elapsed time, and one Stop control.
5. Stop finalizes local audio. If already connected, upload the new recording immediately.
   Otherwise keep it locally and offer Connect and a per-recording Send action.
6. Confirm Saved to NoteDude only after the service confirms a ready note identifier.
   Keep a local exportable recording after success and failure.

## Functional requirements

| ID | Requirement |
| --- | --- |
| CAP-01 | MUST attempt recording on a normal launch, with a single gesture fallback when permission or browser policy prevents it. |
| CAP-02 | MUST capture through pauses using MediaRecorder; silence MUST NOT end recording. Prefer Safari `audio/mp4`, then supported WebM/Opus. |
| CAP-03 | MUST stop explicitly, at 10 minutes, on app backgrounding, or when the capture reaches the 19 MiB client threshold. No background-recording promise. Final oversized chunks may exceed the threshold; preserve/export them and refuse upload above 19 MiB. |
| CAP-04 | MUST show elapsed time and recording state; MUST prevent concurrent record/start, sign-in, and upload actions that can corrupt a capture. |
| LOC-01 | MUST persist audio in IndexedDB before attempting upload; checkpoint at approximately five-second data events. Abrupt termination may lose the latest unsaved chunk, and incomplete media may require external recovery. |
| LOC-02 | MUST restore local recordings after reload, mark interrupted recordings/uploads as requiring review, and never silently resend them. |
| LOC-03 | MUST provide playback, audio export, and confirmation before local deletion. Local deletion MUST NOT imply remote deletion. |
| LOC-04 | MUST show storage failures and offer export of finalized in-memory audio. Browser storage may be evicted; MUST explain this limitation. |
| AUTH-01 | MUST use per-user OAuth authorization code + PKCE S256 with cryptographically random verifier/state and exact callback state validation. MUST NOT supply a caller-selected user ID. |
| AUTH-02 | MUST refresh expiring access tokens, retain rotated refresh tokens, and revoke on disconnect. Tokens MUST NOT appear in URL query strings, logs, analytics, or service-worker caches. The authorization code is a short-lived callback query parameter and MUST be removed from browser history. |
| AUTH-03 | MUST NOT automatically upload the existing backlog after connecting or switching accounts; each backlog capture requires an explicit Send. New captures may upload automatically in the current connected session. |
| MCP-01 | MUST call authenticated `tools/call` → `create_audio_note` with canonical base64, a server-supported MIME type without codec parameters, and a stable capture filename. |
| MCP-02 | MUST accept success only for `result.structuredContent.status == "ready"` with a nonempty `note_id`. JSON-RPC errors, tool errors, HTTP errors and network failures MUST retain the local recording. |
| MCP-03 | MUST NOT automatically retry an ambiguous upload. Existing service has no idempotency key; explicit retries MUST warn of possible duplicates. Server-side idempotency is follow-up work. |
| TRN-01 | MUST use existing server transcription for audio-only uploads. MUST surface paid-plan rejection without discarding audio. |
| TRN-02 | MUST allow an optional user transcript, including keyboard dictation, to use the free text-plus-audio server path. MUST NOT claim Safari SpeechRecognition guarantees on-device transcription. |
| PWA-01 | MUST include a manifest, standalone display, iPhone touch icon and install guidance. |
| PWA-02 | MUST cache only the application shell for offline reopening; MUST exclude OAuth, MCP, tokens, callback query responses and uploaded recordings from Cache Storage. Recordings belong in IndexedDB. |
| PRIV-01 | MUST disclose that audio is sent to NoteDude and OpenAI on the server-transcription path. No analytics collecting audio/transcripts. Use text rendering for transcript/error data. |
| A11Y-01 | MUST support keyboard focus, accessible control labels, live status announcements, reduced-motion preferences and narrow phone layouts. |

## State and persistence

`starting → recording → local → sending → synced`

Permission failure returns to `ready` with a Tap to start action. Processing/upload failures
transition to `failed`; storage failure may leave an `unsaved` capture exportable in memory.
Interrupted `recording` or `sending` states become `failed` on next launch.

Local capture: `id`, `created`, `state`, `audio` Blob, optional user `text`, `error`, and,
after success, `noteId` and `transcript`. The capture UUID stays in the uploaded filename;
it is diagnostic only and MUST NOT be represented as a server idempotency key.

The current implementation stores OAuth credentials in origin-local storage for persistent
sessions. This is accessible to same-origin script: deploy no third-party scripts, enforce
CSP, render untrusted text safely, and do not share this hosting origin with untrusted apps.
A backend-for-frontend with HttpOnly session cookies is a possible future hardening step.

## Server handoff contract

POST `/mcp` with `Authorization: Bearer <access token>`, Content-Type `application/json`,
and Accept `application/json, text/event-stream`. The existing service uses stateless JSON responses.

```json
{
  "jsonrpc": "2.0",
  "id": "<request UUID>",
  "method": "tools/call",
  "params": {
    "name": "create_audio_note",
    "arguments": {
      "audio_base64": "<original recording bytes>",
      "mime_type": "audio/mp4",
      "filename": "<capture UUID>.m4a"
    }
  }
}
```

Add `transcript` only when nonempty user-supplied text exists. The server derives user identity
from verified OAuth credentials, preserves original bytes in Cloud Storage and writes compatible
notes plus audio metadata in Firestore. No direct browser database writes are needed.

Deploy on a dedicated Firebase Hosting site in the existing project, with same-origin `/mcp`
and `/oauth/**` rewrites to `notedudeMcp` in `us-central1`. This avoids opening backend CORS.
Navigate sign-in to the canonical `https://notedude2-mcp.web.app/oauth/authorize`, because its
Firebase consent-page origin checks depend on the canonical server origin. Use the dedicated
mobile origin as the registered redirect URI. Do not overwrite NoteDude web or MCP Hosting targets.

## Spec-driven verification and audio fixtures

Unit and integration tests MUST run without production credentials. Playwright MUST exercise
the built React app with deterministic fake microphone input and a mocked NoteDude boundary.
Mocked success MUST NOT be described as a live OpenAI or Firestore integration test.

| Test | Requirements | Expected evidence |
| --- | --- | --- |
| U-01 MIME and size validation | CAP-02, MCP-01 | Safari MP4 and WebM codec suffixes normalize; client threshold below server limit. |
| U-02 MCP acknowledgement parser | MCP-02, TRN-01 | Ready success accepted; malformed, JSON-RPC and paid-plan errors rejected. |
| U-03 PKCE encoding | AUTH-01 | URL-safe unpadded encoding. |
| E-01 Auto-start and stop | CAP-01, CAP-02, CAP-04, LOC-01 | Fake microphone records fixture, keeps recording through silence, Stop creates playable local audio. |
| E-02 Reload recovery | LOC-01, LOC-02 | Saved local recording survives reload; interrupted capture is reviewable. |
| E-03 Authenticated upload | MCP-01, MCP-02, TRN-01 | Stop sends audio-only tool call, service acknowledgement marks synced and displays transcript. |
| E-04 Plan/upload failure | LOC-02, MCP-02, MCP-03, TRN-01 | Service error retains playable/exportable audio and shows the reason. |
| E-05 Transcript path | TRN-02 | User transcript is included with original audio. |
| E-06 Permission fallback | CAP-01 | Denied microphone shows Tap to start and explicit permission guidance. |
| E-07 OAuth and refresh | AUTH-01, AUTH-02, AUTH-03 | State mismatch rejected; refresh rotates token; backlog not sent on connect. |
| E-08 Offline shell and recovery | PWA-02, LOC-02 | Production service worker permits offline reopen without caching private API responses. |
| M-01 Real iPhone | CAP-01–04, PWA-01, A11Y-01 | Safari installation, first grant, Home Screen relaunch, Stop, interruption, export and playback on a physical iPhone. |
| L-01 Live server transcription | MCP-01–02, TRN-01, PRIV-01 | Test account uploads spoken fixture; verify original bytes, transcript meaning, compatible note and user isolation. |

Synthetic fixtures live under `pwa/test/fixtures/`:

- `idea.wav`: mono 16 kHz PCM synthetic speech: “Remember to send Sam the project proposal tomorrow morning.”
- `idea.m4a`: AAC derivative to cover the Safari upload format.
- `silence.wav`: two seconds of silence, for capture behavior; no transcript assertion.
- `idea-with-pause.wav`: the same speech with leading silence and a trailing pause.

Fixtures contain no personal recordings. Generate them with FFmpeg's local Flite synthesizer;
record generation commands and expected text. Transcription checks MUST compare meaning/key
terms, not exact punctuation or capitalization. A mocked response does not prove speech quality.

## Release gates and current limitations

1. Unit and browser E2E tests pass against the production build; record exact results.
2. Physical iPhone QA M-01 passes. Desktop Chromium is not evidence of Safari behavior.
3. Verify deployed MCP version, OAuth callback behavior, model availability, test-account
   paid entitlement, API spend limits and L-01 against a testing environment.
4. Confirm dedicated Firebase Hosting target, required deployment credentials and project;
   current cloud environment provides no Firebase deployment identity or OpenAI secret.
5. Deploy only after backend and iPhone gates pass. No production data or entitlement changes
   are authorized by this spec. Do not create a new paid subscription as part of implementation.

Out of scope: native reminders/alarms, App Store release, React Native migration, hands-free
background recording, guaranteed on-device speech recognition, editing the whole note library,
changing subscription policy, and automatic retries without backend idempotency.

## Implementation checklist

- [x] React PWA candidate with browser recorder, local outbox and existing MCP handoff.
- [x] Reuse existing Firebase transcription function; document entitlement/model constraints.
- [x] Synthetic speech, silence and AAC audio fixtures.
- [x] Complete and run automated cases E-01 through E-08 (11 Playwright cases including OAuth variants and transport failure).
- [ ] Physical iPhone QA.
- [ ] Authenticated live-server and OpenAI verification.
- [ ] Testing deployment and release approval.

## Recorded validation

Candidate validation on 2026-10-27: production Vite build passed; 5 Node unit/integration
tests passed; 11 Playwright Chromium E2E tests passed. The opt-in live transcription test
was skipped because testing-service credentials are not configured. No physical iPhone
QA or Firebase deployment has been performed. CI runs the same local and browser checks.

## Deployment specification: IdeaDude

The user has selected `ideadude.notedude.dev` and authorized Firebase deployment. The
selected dedicated Hosting site is `notedude2-ideadude` in project `notedude2`.

- DEP-01: Every push/merge to `main` MUST run unit and production-browser tests. A successful
  run MUST deploy the exact tested static artifact to the dedicated site. Pull requests
  MUST NOT deploy or receive the Google Cloud deployment identity.
- DEP-02: Deployment MUST use keyless GitHub OIDC restricted to this repository and `main`,
  and MUST fail visibly if its identity variables are missing. Concurrent releases MUST
  serialize. Publishing this PWA MUST NOT redeploy the MCP function.
- DEP-03: Firebase MUST manage TLS for `ideadude.notedude.dev`; use only DNS records supplied
  for this site, and preserve all other domain records. The current parking record must
  be replaced for this subdomain.
- DEP-04: A release MUST smoke-test the live manifest, assets, service worker, security headers,
  authenticated MCP challenge and OAuth routing before being reported successful.

Implementation and one-time setup are in `pwa/docs/firebase-deployment.md`. The user's
Firebase deployment instruction supersedes the earlier conversational hold on publication;
missing cloud credentials and live iPhone/transcription verification remain explicit limits.
