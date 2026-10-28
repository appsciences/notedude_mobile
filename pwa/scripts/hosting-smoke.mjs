import assert from "node:assert/strict";
const base = new URL(process.argv[2]);
assert.equal(base.protocol, "https:", "Live Hosting must use HTTPS.");
async function get(path) {
  const response = await fetch(new URL(path, base), {
    redirect: "error",
    signal: AbortSignal.timeout(30000),
  });
  return response;
}
const page = await get("/");
assert.equal(page.status, 200, "PWA root must be served.");
assert.match(
  page.headers.get("permissions-policy") || "",
  /microphone=\(self\)/,
);
assert.match(
  page.headers.get("content-security-policy") || "",
  /script-src 'self'/,
);
const html = await page.text();
assert.match(html, /NoteDude/);
assert.match(html, /id="root"/);
const assets = [...html.matchAll(/(?:src|href)="([^"?#]+\.(?:js|css))"/g)].map(
  (match) => match[1],
);
assert.ok(assets.length >= 2, "Built JavaScript and CSS must be referenced.");
for (const asset of assets)
  assert.equal((await get(asset)).status, 200, `Missing asset: ${asset}`);
const worker = await get("/sw.js");
assert.equal(worker.status, 200);
assert.match(worker.headers.get("cache-control") || "", /no-cache/);
assert.match(await worker.text(), /notedude-voice-/);
const manifest = await get("/manifest.webmanifest");
assert.equal(manifest.status, 200);
assert.equal((await manifest.json()).display, "standalone");
const mcp = await get("/mcp");
assert.equal(
  mcp.status,
  401,
  "MCP rewrite must reach the authenticated service.",
);
assert.match(mcp.headers.get("www-authenticate") || "", /resource_metadata/);
const oauth = await get("/oauth/authorize");
assert.equal(
  oauth.status,
  400,
  "OAuth rewrite must reject a request missing OAuth parameters.",
);
console.log(
  `Verified PWA assets, headers, service worker, manifest, MCP and OAuth routing at ${base.origin}`,
);
