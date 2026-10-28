import React, { useEffect, useState, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import {
  subscribe,
  snapshot,
  boot,
  toggleRecording,
  account,
  refresh,
  sendCapture,
  removeCapture,
  saveText,
} from "./controller.js";
import { extension } from "./core.mjs";
import "./style.css";

function Capture({ capture, busy }) {
  const [url, setUrl] = useState("");
  const [text, setText] = useState(capture.text || "");
  useEffect(() => {
    if (!capture.audio?.size) return;
    const value = URL.createObjectURL(capture.audio);
    setUrl(value);
    return () => URL.revokeObjectURL(value);
  }, [capture.audio]);
  return (
    <article>
      <small>
        {new Date(capture.created).toLocaleString()} · {capture.state}
      </small>
      {url && (
        <>
          <audio controls src={url} />
          <a
            href={url}
            download={`${capture.id}.${extension(capture.audio.type)}`}
          >
            Export audio
          </a>
        </>
      )}
      {capture.transcript && <p>{capture.transcript}</p>}
      {!["synced", "recording", "unsaved"].includes(capture.state) && (
        <>
          <textarea
            aria-label="Optional transcript"
            placeholder="Optional transcript — type or use keyboard dictation"
            value={text}
            disabled={busy}
            onChange={(e) => setText(e.target.value)}
            onBlur={() => saveText(capture, text)}
          />
          <button disabled={busy} onClick={() => sendCapture(capture, text)}>
            {capture.state === "sending" ? "Sending…" : "Send to NoteDude"}
          </button>
        </>
      )}
      {capture.error && <p>{capture.error}</p>}
      <button
        disabled={busy || capture.state === "recording"}
        onClick={() => removeCapture(capture)}
      >
        Delete local copy
      </button>
    </article>
  );
}
function App() {
  const state = useSyncExternalStore(subscribe, snapshot);
  useEffect(() => {
    boot();
  }, []);
  return (
    <div className={state.recording ? "recording" : ""}>
      <header>
        <a href="./">
          NoteDude<span>VOICE NOTES</span>
        </a>
        <button onClick={account}>
          {state.connected ? "Disconnect" : "Connect"}
        </button>
      </header>
      <main>
        <p className="eyebrow">A LITTLE SPACE FOR YOUR NEXT BIG IDEA</p>
        <h1>Think out loud.</h1>
        <p id="status" role="status" aria-live="polite">
          {state.status}
        </p>
        <div id="pulse" aria-hidden="true">
          {Array.from({ length: 7 }, (_, i) => (
            <span key={i} />
          ))}
        </div>
        <p id="timer">{state.timer}</p>
        <button
          className="primary"
          disabled={state.disabled || state.busy}
          onClick={toggleRecording}
        >
          {state.button}
        </button>
        <p className="hint">Open. Speak. Stop. Your idea goes to NoteDude.</p>
        <section>
          <div className="row">
            <h2>Your recordings</h2>
            <button disabled={state.busy || state.recording} onClick={refresh}>
              Refresh
            </button>
          </div>
          {!state.captures.length && (
            <p id="empty">Your next idea starts here.</p>
          )}
          {state.captures.map((c) => (
            <Capture
              key={c.id}
              capture={c}
              busy={state.busy || state.recording}
            />
          ))}
        </section>
        <details>
          <summary>Install & privacy</summary>
          <p>
            On iPhone, open this page in Safari, tap Share, then Add to Home
            Screen. No App Store account needed.
          </p>
          <p>
            Recording starts automatically when your browser permits it. First
            use requires microphone permission; Safari may also require a tap.
            Recording ends when you press Stop, leave the app, reach 10 minutes,
            or reach 19 MiB.
          </p>
          <p>
            Audio is saved in this browser before upload. Connected recordings
            are sent to your private NoteDude account for OpenAI transcription
            and summarization. Server transcription requires a paid NoteDude
            plan. Browser storage can be cleared by iOS: export important
            recordings.
          </p>
          <p>
            Phone dictation can fill a recording’s optional transcript field.
            Supplying text skips server transcription. Browser speech
            recognition cannot reliably guarantee on-device processing across
            iPhones.
          </p>
        </details>
      </main>
    </div>
  );
}
createRoot(document.getElementById("root")).render(<App />);
