import { test, expect } from "@playwright/test";
const fakeSession = {
  access_token: "test-access",
  refresh_token: "test-refresh",
  client: "test-client",
  expires: Date.now() + 3600000,
};
async function signedIn(page, extra = {}) {
  await page.addInitScript(
    (s) => localStorage.setItem("notedude-session", JSON.stringify(s)),
    { ...fakeSession, ...extra },
  );
}
async function recording(page) {
  await page.goto("/");
  await expect(page.getByRole("status")).toHaveText(
    "Listening. Take your time.",
  );
}
async function stop(page) {
  await page.getByRole("button", { name: "Stop & send" }).click();
}
async function readCaptures(page) {
  return page.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const r = indexedDB.open("notedude-voice", 1);
        r.onsuccess = () => {
          const db = r.result,
            tx = db.transaction("captures");
          const get = tx.objectStore("captures").getAll();
          get.onsuccess = () => {
            resolve(
              get.result.map((c) => ({
                id: c.id,
                state: c.state,
                size: c.audio?.size,
                type: c.audio?.type,
              })),
            );
            db.close();
          };
        };
        r.onerror = () => reject(r.error);
      }),
  );
}
test("E-01: auto-start records synthetic speech through a pause, then retains playable local audio", async ({
  page,
}) => {
  await recording(page);
  await page.waitForTimeout(10000);
  await expect(page.getByRole("button", { name: "Stop & send" })).toBeEnabled();
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved on this device.");
  await expect(page.locator("audio")).toHaveAttribute("src", /^blob:/);
  await expect(page.getByRole("link", { name: "Export audio" })).toBeVisible();
  expect((await readCaptures(page))[0].size).toBeGreaterThan(1000);
  await page.locator("audio").evaluate(async (audio) => {
    await audio.play();
  });
  await expect
    .poll(() => page.locator("audio").evaluate((a) => a.currentTime))
    .toBeGreaterThan(0);
});
test("E-02: finalized and interrupted captures survive reload without automatic upload", async ({
  page,
}) => {
  let uploads = 0;
  await page.route("**/mcp", (route) => {
    uploads++;
    return route.abort();
  });
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved on this device.");
  await page.reload();
  await expect(page.getByRole("status")).toHaveText(
    "Listening. Take your time.",
  );
  await expect(page.locator("audio")).toHaveCount(1);
  await page.waitForTimeout(5500);
  await page.reload();
  await expect(
    page.getByText(
      "Interrupted. Review recovered audio before sending; a previous upload may have succeeded.",
    ),
  ).toBeVisible();
  expect(uploads).toBe(0);
  await stop(page);
});
test("E-03: connected Stop uploads original audio through MCP and acknowledges ready", async ({
  page,
}) => {
  await signedIn(page);
  let args;
  await page.route("**/mcp", async (route) => {
    const body = route.request().postDataJSON();
    expect(body.method).toBe("tools/call");
    expect(body.params.name).toBe("create_audio_note");
    expect(route.request().headers().authorization).toBe("Bearer test-access");
    args = body.params.arguments;
    await route.fulfill({
      json: {
        jsonrpc: "2.0",
        id: body.id,
        result: {
          structuredContent: {
            note_id: "note-test",
            status: "ready",
            transcript:
              "Remember to send Sam the project proposal tomorrow morning.",
          },
        },
      },
    });
  });
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved to NoteDude.");
  expect(args.audio_base64.length).toBeGreaterThan(100);
  expect(["audio/webm", "audio/mp4"]).toContain(args.mime_type);
  expect(args.transcript).toBeUndefined();
  await expect(
    page.getByText(
      "Remember to send Sam the project proposal tomorrow morning.",
    ),
  ).toBeVisible();
  expect((await readCaptures(page))[0].state).toBe("synced");
});
test("E-04: paid-plan rejection preserves source and error for explicit retry", async ({
  page,
}) => {
  await signedIn(page);
  await page.route("**/mcp", (route) =>
    route.fulfill({
      json: {
        result: {
          isError: true,
          content: [
            {
              type: "text",
              text: "Server transcription requires a paid plan.",
            },
          ],
        },
      },
    }),
  );
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText(
    "Server transcription requires a paid plan.",
  );
  await expect(page.getByRole("link", { name: "Export audio" })).toBeVisible();
  expect((await readCaptures(page))[0].state).toBe("failed");
});
test("E-05: optional transcript is sent with the audio", async ({ page }) => {
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved on this device.");
  await page.evaluate(
    (s) => localStorage.setItem("notedude-session", JSON.stringify(s)),
    fakeSession,
  );
  let args;
  await page.route("**/mcp", (route) => {
    args = route.request().postDataJSON().params.arguments;
    return route.fulfill({
      json: {
        result: {
          structuredContent: {
            note_id: "text-note",
            status: "ready",
            transcript: args.transcript,
          },
        },
      },
    });
  });
  await page
    .getByRole("textbox", { name: "Optional transcript" })
    .fill("Call Sam tomorrow");
  await page.getByRole("button", { name: "Send to NoteDude" }).click();
  await expect(page.getByRole("status")).toHaveText("Saved to NoteDude.");
  expect(args.transcript).toBe("Call Sam tomorrow");
  expect(args.audio_base64).toBeTruthy();
});
test("E-06: microphone rejection offers one explicit start fallback", async ({
  page,
}) => {
  await page.addInitScript(() => {
    navigator.mediaDevices.getUserMedia = async () => {
      throw new DOMException("Denied", "NotAllowedError");
    };
  });
  await page.goto("/");
  await expect(
    page.getByRole("button", { name: "Tap to start" }),
  ).toBeEnabled();
  await expect(page.getByRole("status")).toHaveText(
    "Allow microphone access, then tap to start.",
  );
});
test("E-07a: OAuth state mismatch is rejected without token exchange or upload", async ({
  page,
}) => {
  let calls = 0;
  await page.route("**/oauth/token", (route) => {
    calls++;
    return route.abort();
  });
  await page.goto("/?code=untrusted&state=wrong");
  await expect(page.getByRole("status")).toHaveText(
    "Sign-in state did not match. Connect again.",
  );
  expect(calls).toBe(0);
  expect(page.url()).not.toContain("code=");
});
test("E-07b: expired access token refreshes and persists rotated token", async ({
  page,
}) => {
  await signedIn(page, { expires: 0 });
  await page.route("**/oauth/token", (route) => {
    expect(route.request().postData()).toContain("grant_type=refresh_token");
    return route.fulfill({
      json: {
        access_token: "new-access",
        refresh_token: "rotated-refresh",
        expires_in: 3600,
      },
    });
  });
  await page.route("**/mcp", (route) => {
    expect(route.request().headers().authorization).toBe("Bearer new-access");
    return route.fulfill({
      json: {
        result: {
          structuredContent: {
            note_id: "refreshed",
            status: "ready",
            transcript: "Idea",
          },
        },
      },
    });
  });
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved to NoteDude.");
  expect(
    await page.evaluate(
      () => JSON.parse(localStorage.getItem("notedude-session")).refresh_token,
    ),
  ).toBe("rotated-refresh");
});
test("E-08: production shell reopens offline and cache excludes private endpoints", async ({
  page,
  context,
}) => {
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved on this device.");
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload();
  await expect(page.getByRole("status")).toHaveText(
    "Listening. Take your time.",
  );
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved on this device.");
  await context.setOffline(true);
  await page.reload();
  await expect(
    page.getByRole("heading", { name: "Think out loud." }),
  ).toBeVisible();
  await expect(page.locator("audio")).toHaveCount(2);
  const keys = await page.evaluate(async () => {
    const paths = [];
    for (const name of await caches.keys())
      for (const request of await (await caches.open(name)).keys())
        paths.push(new URL(request.url).pathname);
    return paths;
  });
  expect(keys.some((k) => k.includes("/oauth") || k.includes("/mcp"))).toBe(
    false,
  );
  await stop(page);
});
test("E-07c: successful OAuth callback connects without uploading the existing backlog", async ({
  page,
}) => {
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText("Saved on this device.");
  await page.evaluate(() =>
    sessionStorage.setItem(
      "notedude-pkce",
      JSON.stringify({
        state: "expected-state",
        verifier: "test-verifier",
        client: "test-client",
        redirect: location.origin + "/",
      }),
    ),
  );
  let uploads = 0;
  await page.route("**/mcp", (route) => {
    uploads++;
    return route.abort();
  });
  await page.route("**/oauth/token", (route) => {
    expect(route.request().postData()).toContain("code_verifier=test-verifier");
    return route.fulfill({
      json: {
        access_token: "callback-access",
        refresh_token: "callback-refresh",
        expires_in: 3600,
      },
    });
  });
  await page.goto("/?code=test-code&state=expected-state");
  await expect(page.getByRole("button", { name: "Disconnect" })).toBeVisible();
  await expect(page.getByRole("status")).toHaveText(
    "Connected. Saved recordings stay here until you choose Send.",
  );
  expect(uploads).toBe(0);
  await expect(page.locator("audio")).toHaveCount(1);
});
test("MCP transport failure retains audio and asks before retrying an ambiguous upload", async ({
  page,
}) => {
  await signedIn(page);
  let uploads = 0;
  await page.route("**/mcp", (route) => {
    uploads++;
    return route.fulfill({ status: 503, json: { error: "unavailable" } });
  });
  await recording(page);
  await page.waitForTimeout(1000);
  await stop(page);
  await expect(page.getByRole("status")).toHaveText(
    "NoteDude answered HTTP 503.",
  );
  expect((await readCaptures(page))[0].size).toBeGreaterThan(100);
  page.once("dialog", async (dialog) => {
    expect(dialog.message()).toContain("duplicate");
    await dialog.dismiss();
  });
  await page.getByRole("button", { name: "Send to NoteDude" }).click();
  expect(uploads).toBe(1);
});
