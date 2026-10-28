import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { toolResult } from "../../core.mjs";
const endpoint = process.env.NOTEDUDE_TEST_BASE_URL;
const token = process.env.NOTEDUDE_TEST_ACCESS_TOKEN;
test(
  "L-01: authorized testing service transcribes AAC fixture and saves an audio source",
  { skip: !endpoint || !token },
  async () => {
    const url = new URL(endpoint);
    assert.equal(url.protocol, "https:");
    const audio = await readFile(
      new URL("../fixtures/idea.m4a", import.meta.url),
    );
    const response = await fetch(new URL("/mcp", url), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: crypto.randomUUID(),
        method: "tools/call",
        params: {
          name: "create_audio_note",
          arguments: {
            audio_base64: audio.toString("base64"),
            mime_type: "audio/mp4",
            filename: "synthetic-qa-idea.m4a",
            tags: ["qa-fixture"],
          },
        },
      }),
      signal: AbortSignal.timeout(180000),
    });
    assert.equal(response.status, 200);
    const result = toolResult(await response.json());
    assert.ok(result.source_uri);
    for (const term of ["sam", "proposal", "tomorrow"])
      assert.ok(
        result.transcript.toLowerCase().includes(term),
        `Transcript missing expected term: ${term}`,
      );
    // Full source-byte verification and cross-user isolation require admin-side testing evidence.
  },
);
