import {
  MAX_BYTES,
  audioType,
  extension,
  toolResult,
  base64url,
} from "./core.mjs";
let view = {
  status: "Getting your microphone ready…",
  timer: "00:00",
  button: "Starting…",
  disabled: true,
  recording: false,
  connected: false,
  busy: false,
  captures: [],
};
const listeners = new Set();
function update(patch) {
  view = { ...view, ...patch };
  listeners.forEach((fn) => fn());
}
export const subscribe = (fn) => {
  listeners.add(fn);
  return () => listeners.delete(fn);
};
export const snapshot = () => view;
const MCP_ORIGIN = "https://notedude2-mcp.web.app";
let db,
  recorder,
  stream,
  current,
  chunks = [],
  bytes = 0,
  started = 0,
  clock,
  saving = Promise.resolve(),
  busy = false,
  starting = false,
  finalizing = false;
function status(text) {
  update({ status: text });
}
const request = (path, options = {}) =>
  fetch(path, {
    ...options,
    cache: "no-store",
    signal: AbortSignal.timeout(180000),
  });
async function json(path, options) {
  const r = await request(path, options);
  const data = await r.json();
  if (!r.ok)
    throw new Error(
      data.error_description || `NoteDude answered HTTP ${r.status}.`,
    );
  return data;
}
async function database() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open("notedude-voice", 1);
    r.onupgradeneeded = () =>
      r.result.createObjectStore("captures", { keyPath: "id" });
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
function store(mode, fn) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction("captures", mode);
    const result = fn(tx.objectStore("captures"));
    tx.oncomplete = () => resolve(result.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}
const put = (capture) => store("readwrite", (s) => s.put(capture));
const all = () => store("readonly", (s) => s.getAll());
function session() {
  try {
    return JSON.parse(localStorage.getItem("notedude-session") || "null");
  } catch {
    return null;
  }
}
function saveSession(value) {
  localStorage.setItem("notedude-session", JSON.stringify(value));
  accountLabel();
}
function accountLabel() {
  update({ connected: !!session() });
}
async function connect() {
  const redirect = location.origin + location.pathname;
  const client = await json("/oauth/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_name: "NoteDude Voice PWA",
      redirect_uris: [redirect],
    }),
  });
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32))),
    state = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const challenge = base64url(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)),
    ),
  );
  sessionStorage.setItem(
    "notedude-pkce",
    JSON.stringify({ verifier, state, redirect, client: client.client_id }),
  );
  const url = new URL("/oauth/authorize", MCP_ORIGIN);
  url.search = new URLSearchParams({
    response_type: "code",
    client_id: client.client_id,
    redirect_uri: redirect,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    resource: MCP_ORIGIN + "/mcp",
    scope: "notes",
  });
  location.assign(url);
}
async function callback() {
  const query = new URLSearchParams(location.search);
  if (!query.has("code") && !query.has("error")) return false;
  const pending = JSON.parse(sessionStorage.getItem("notedude-pkce") || "null");
  history.replaceState({}, "", location.pathname);
  sessionStorage.removeItem("notedude-pkce");
  if (!pending || pending.state !== query.get("state"))
    throw new Error("Sign-in state did not match. Connect again.");
  if (query.has("error")) throw new Error("Sign-in was cancelled.");
  const tokens = await json("/oauth/token", {
    method: "POST",
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: pending.client,
      code: query.get("code"),
      redirect_uri: pending.redirect,
      code_verifier: pending.verifier,
      resource: MCP_ORIGIN + "/mcp",
    }),
  });
  saveSession({
    ...tokens,
    client: pending.client,
    expires: Date.now() + tokens.expires_in * 1000,
  });
  status("Connected. Saved recordings stay here until you choose Send.");
  return true;
}
async function token() {
  let s = session();
  if (!s) throw new Error("Connect to NoteDude first.");
  if (s.expires < Date.now() + 60000) {
    const tokens = await json("/oauth/token", {
      method: "POST",
      body: new URLSearchParams({
        grant_type: "refresh_token",
        client_id: s.client,
        refresh_token: s.refresh_token,
      }),
    });
    s = { ...s, ...tokens, expires: Date.now() + tokens.expires_in * 1000 };
    saveSession(s);
  }
  return s.access_token;
}
function encoded(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result.split(",")[1]);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}
async function send(capture) {
  if (busy || recorder?.state === "recording") return;
  busy = true;
  update({ busy: true });
  try {
    if (!capture.audio?.size) throw new Error("No audio was recovered.");
    if (capture.audio.size > MAX_BYTES)
      throw new Error("Recording exceeds the upload limit. Export it instead.");
    const bearer = await token();
    capture.state = "sending";
    capture.error = "";
    await put(capture);
    await render();
    const args = {
      audio_base64: await encoded(capture.audio),
      mime_type: audioType(capture.audio.type),
      filename: `${capture.id}.${extension(capture.audio.type)}`,
    };
    if (capture.text?.trim()) args.transcript = capture.text.trim();
    const result = toolResult(
      await json("/mcp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json, text/event-stream",
          Authorization: `Bearer ${bearer}`,
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: crypto.randomUUID(),
          method: "tools/call",
          params: { name: "create_audio_note", arguments: args },
        }),
      }),
    );
    capture.state = "synced";
    capture.noteId = result.note_id;
    capture.transcript = result.transcript;
    await put(capture);
    status("Saved to NoteDude.");
  } catch (error) {
    capture.state = "failed";
    capture.error = error.message;
    await put(capture);
    status(error.message);
  } finally {
    busy = false;
    await render();
  }
}
async function render() {
  update({
    captures: (await all()).sort((a, b) => b.created - a.created),
    busy,
  });
}
function idle() {
  update({ recording: false, disabled: false, button: "Record another idea" });
}
async function start() {
  if (starting || finalizing || busy || recorder?.state === "recording") return;
  starting = true;
  update({ disabled: true });
  try {
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder)
      throw new Error("Open in Safari over HTTPS to record.");
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true },
      video: false,
    });
    const type = ["audio/mp4", "audio/webm;codecs=opus", "audio/webm"].find(
      (t) => MediaRecorder.isTypeSupported(t),
    );
    if (!type)
      throw new Error("This browser cannot record a supported audio format.");
    recorder = new MediaRecorder(stream, {
      mimeType: type,
      audioBitsPerSecond: 64000,
    });
    chunks = [];
    bytes = 0;
    current = {
      id: crypto.randomUUID(),
      created: Date.now(),
      state: "recording",
      text: "",
    };
    await put(current);
    started = Date.now();
    update({ timer: "00:00" });
    recorder.ondataavailable = (event) => {
      if (!event.data.size) return;
      chunks.push(event.data);
      bytes += event.data.size;
      const snapshot = {
        ...current,
        audio: new Blob(chunks, { type: recorder.mimeType }),
      };
      saving = saving
        .catch(() => {})
        .then(() => put(snapshot))
        .catch(() => {
          status(
            "Device storage is full. Keep this page open and export your audio.",
          );
          stop();
        });
      if (bytes >= MAX_BYTES) stop();
    };
    recorder.onstop = async () => {
      clearInterval(clock);
      stream?.getTracks().forEach((t) => t.stop());
      await saving;
      const finished = {
        ...current,
        audio: new Blob(chunks, { type: recorder.mimeType }),
        state: "local",
      };
      update({ recording: false });
      try {
        await put(finished);
        await render();
        status("Saved on this device.");
        if (session()) await send(finished);
      } catch {
        status("Could not save locally. Export this recording before closing.");
        update({
          captures: [
            { ...finished, state: "unsaved" },
            ...view.captures.filter((c) => c.id !== finished.id),
          ],
        });
      } finally {
        finalizing = false;
        idle();
      }
    };
    recorder.onerror = () => {
      status("Recording interrupted. Recovering the audio…");
      stop();
    };
    recorder.start(5000);
    update({ recording: true, button: "Stop & send", disabled: false });
    status("Listening. Take your time.");
    clock = setInterval(() => {
      const elapsed = Math.floor((Date.now() - started) / 1000);
      update({
        timer: `${String(Math.floor(elapsed / 60)).padStart(2, "0")}:${String(elapsed % 60).padStart(2, "0")}`,
      });
      if (elapsed >= 600) stop();
    }, 500);
  } catch (error) {
    stream?.getTracks().forEach((t) => t.stop());
    idle();
    update({ button: "Tap to start" });
    status(
      error.name === "NotAllowedError"
        ? "Allow microphone access, then tap to start."
        : error.message,
    );
  } finally {
    starting = false;
  }
}
function stop() {
  if (recorder?.state === "recording") {
    finalizing = true;
    recorder.stop();
    update({ disabled: true });
    status("Saving your recording…");
  }
}
export const toggleRecording = () =>
  recorder?.state === "recording" ? stop() : start();
export const refresh = () => render().catch((e) => status(e.message));
export async function sendCapture(capture, text) {
  if (busy) return;
  if (
    ["failed", "sending"].includes(capture.state) &&
    !confirm(
      "A previous upload may have succeeded. Sending again could create a duplicate. Continue?",
    )
  )
    return;
  await send({ ...capture, text });
}
export async function removeCapture(capture) {
  if (busy || recorder?.state === "recording") return;
  if (
    confirm(
      "Delete this device’s recording? This does not delete any uploaded note.",
    )
  ) {
    await store("readwrite", (s) => s.delete(capture.id));
    await render();
  }
}
export async function saveText(capture, text) {
  if (busy) return;
  const latest = await store("readonly", (s) => s.get(capture.id));
  if (latest && latest.state !== "synced") await put({ ...latest, text });
}
export async function account() {
  if (starting || finalizing || recorder?.state === "recording" || busy) {
    status("Finish your recording or upload first.");
    return;
  }
  try {
    if (session()) {
      const s = session();
      await json("/oauth/revoke", {
        method: "POST",
        body: new URLSearchParams({ token: s.refresh_token }),
      });
      localStorage.removeItem("notedude-session");
      accountLabel();
      status("Disconnected. Your local recordings remain here.");
    } else await connect();
  } catch (e) {
    status(e.message);
  }
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden) stop();
});
export async function boot() {
  try {
    db = await database();
    for (const capture of await all()) {
      if (["recording", "sending"].includes(capture.state)) {
        capture.state = "failed";
        capture.error =
          "Interrupted. Review recovered audio before sending; a previous upload may have succeeded.";
        await put(capture);
      }
    }
    await render();
    accountLabel();
    const returned = await callback();
    if (!returned) await start();
    else idle();
    navigator.storage?.persist?.().catch(() => {});
  } catch (e) {
    status(e.message);
    if (db) {
      idle();
    } else update({ disabled: true });
  }
  if ("serviceWorker" in navigator)
    navigator.serviceWorker.register("./sw.js").catch(() => {});
}
