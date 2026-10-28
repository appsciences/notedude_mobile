import { test } from "node:test";
import assert from "node:assert/strict";
import { IDBFactory } from "fake-indexeddb";

test("integration: denied microphone leaves capture available without sending any private data", async () => {
  globalThis.indexedDB = new IDBFactory();
  globalThis.document = { addEventListener() {} };
  globalThis.window = { MediaRecorder: class {} };
  globalThis.location = {
    origin: "http://localhost",
    pathname: "/",
    search: "",
  };
  const values = new Map();
  globalThis.localStorage = {
    getItem: (k) => values.get(k) || null,
    setItem: (k, v) => values.set(k, v),
    removeItem: (k) => values.delete(k),
  };
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      mediaDevices: {
        getUserMedia: async () => {
          throw new DOMException("Denied", "NotAllowedError");
        },
      },
    },
  });
  let requests = 0;
  globalThis.fetch = async () => {
    requests++;
    throw new Error("Unexpected network request");
  };
  const controller = await import("../controller.js");
  await controller.boot();
  assert.equal(controller.snapshot().button, "Tap to start");
  assert.equal(controller.snapshot().disabled, false);
  assert.match(controller.snapshot().status, /Allow microphone/);
  assert.equal(requests, 0);
  assert.deepEqual(controller.snapshot().captures, []);
});
