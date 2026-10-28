import { readdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
const files = [];
async function walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = `${dir}/${entry.name}`;
    if (entry.isDirectory()) await walk(path);
    else if (entry.name !== "sw.js") files.push(path.replace(/^dist\//, ""));
  }
}
await walk("dist");
const hash = createHash("sha256");
for (const path of files.sort()) hash.update(await readFile(`dist/${path}`));
const version = hash.digest("hex").slice(0, 16);
await writeFile(
  "dist/sw.js",
  `
const CACHE='notedude-voice-${version}';
const ASSETS=${JSON.stringify(["./", ...files.map((f) => "./" + f)])};
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('notedude-voice-')&&k!==CACHE).map(k=>caches.delete(k))))));
self.addEventListener('fetch',e=>{
 const url=new URL(e.request.url);
 if(e.request.method!=='GET'||url.origin!==location.origin||url.search||!ASSETS.some(p=>new URL(p,self.registration.scope).pathname===url.pathname))return;
 e.respondWith(fetch(e.request).catch(()=>caches.match(e.request,{ignoreVary:true})));
});
`,
);
