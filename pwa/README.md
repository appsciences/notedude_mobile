# NoteDude Voice PWA (React)

The iPhone-focused browser companion lives alongside the existing Flutter application.
Its contract and acceptance criteria are in
[`docs/specs/002-iphone-voice-pwa.md`](../docs/specs/002-iphone-voice-pwa.md).

```sh
npm ci
npm run dev
npm test
npx playwright install chromium
npm run test:e2e
npm run build
```

The dev server proxies `/mcp` and `/oauth` to `https://notedude2-mcp.web.app`.
Use localhost for local capture; a phone accessing a LAN development server needs HTTPS.
OAuth callback validation allows HTTPS and loopback, not insecure LAN URLs.

Install on iPhone using Safari → Share → Add to Home Screen. The app attempts recording on
launch, with a Tap to start fallback for microphone/browser restrictions. Recording stops
explicitly, on backgrounding, after ten minutes, or at the audio size threshold. It checkpoints
locally, then uploads newly stopped recordings if connected. Older recordings require Send.

The existing MCP Firebase function already preserves audio and transcribes/summarizes with
OpenAI. Audio-only requests require a paid NoteDude entitlement. Optional user text, including
keyboard dictation, uses the free text-plus-audio path. No OpenAI key belongs in this project.
The server currently defaults to `gpt-transcribe`; verify deployment model configuration before
live QA. `gpt-4o-mini-transcribe` is a low-cost candidate, subject to API availability.

## Firebase Hosting

Production domain: **ideadude.notedude.dev**. See the
[deployment runbook](docs/firebase-deployment.md) for keyless Google Cloud setup, Porkbun DNS,
and automatic deployment after merges to `main`.

Deploy to a **new dedicated mobile Hosting site in the same Firebase project** as the MCP
function. Do not replace either existing NoteDude Hosting site. This config includes
same-origin rewrites to `notedudeMcp` (`us-central1`) so no backend CORS change is necessary.
OAuth sign-in itself navigates to the canonical MCP origin, and returns to the mobile site.

```sh
npx firebase-tools hosting:sites:create <new-mobile-site> --project <project-id>
npx firebase-tools target:apply hosting mobile <new-mobile-site> --project <project-id>
npm run build
npx firebase-tools deploy --only hosting:mobile --project <project-id>
```

First verify the spec's real iPhone and live backend release gates. Deployment needs Firebase
credentials not configured in this task's environment. The build is static and dependency
assets are bundled locally; no CDN scripts or API secrets. A separate Sites deployment is not
needed because this app relies on Firebase same-origin function rewrites.

## Verification limits

Node tests cover MCP result validation, MIME normalization, PKCE encoding and denied-permission
integration. Playwright exercises the production build in Chromium with generated speech fed
through a real browser MediaRecorder and mocked MCP responses. Fixtures and their regeneration
script are in `test/fixtures` and `scripts/audio-fixtures.sh`. These tests do not prove real
iPhone behavior, live OAuth provider behavior, paid entitlements, OpenAI quality or Firestore
persistence. Complete the spec's manual/live gates before release.

Failed/ambiguous uploads are never retried automatically: the server lacks idempotency keys.
Refreshing this app may restore an interrupted media fragment rather than a fully finalized
recording. Export important audio; browser storage can be evicted. Disconnect revokes the
refresh grant; local deletion does not delete a server note or recording.

For opt-in paid API QA, set `NOTEDUDE_TEST_BASE_URL` and `NOTEDUDE_TEST_ACCESS_TOKEN` for
an authorized **testing account/service**, then run `npm run test:live`. This creates a note
tagged `#qa-fixture` and can incur transcription costs. It skips if either variable is absent.
Do not use a production account. Admin-side source-byte and user-isolation checks remain manual.
