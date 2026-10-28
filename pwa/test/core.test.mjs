import { test } from "node:test";
import assert from "node:assert/strict";
import {
  audioType,
  extension,
  toolResult,
  base64url,
  MAX_BYTES,
} from "../core.mjs";
test("Safari MP4 and Chromium Opus MIME parameters are stripped for the exact server allowlist", () => {
  assert.equal(audioType("audio/mp4;codecs=mp4a.40.2"), "audio/mp4");
  assert.equal(audioType("audio/webm;codecs=opus"), "audio/webm");
  assert.equal(extension("audio/mp4"), "m4a");
  assert.ok(MAX_BYTES < 20 * 1024 * 1024);
});
test("paid-plan denial and JSON-RPC errors never acknowledge an upload", () => {
  assert.throws(
    () =>
      toolResult({
        result: {
          isError: true,
          content: [{ type: "text", text: "Paid plan required" }],
        },
      }),
    /Paid plan/,
  );
  assert.throws(
    () => toolResult({ error: { message: "Unauthorized" } }),
    /Unauthorized/,
  );
  assert.throws(
    () => toolResult({ result: { structuredContent: { note_id: "123" } } }),
    /did not confirm/,
  );
});
test("only a confirmed ready note succeeds", () => {
  const result = { note_id: "123", status: "ready", transcript: "Idea" };
  assert.deepEqual(
    toolResult({ result: { structuredContent: result } }),
    result,
  );
});
test("PKCE encoding is URL-safe and unpadded", () => {
  assert.equal(base64url(new Uint8Array([255, 254, 253])), "__79");
  assert.equal(base64url(new Uint8Array([0])), "AA");
});
