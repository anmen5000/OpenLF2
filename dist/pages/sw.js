// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors
//
// LF2 Online's service worker: the site as an app that opens without the network (package 95).
//
// dist/pages/make-pwa.py writes the site's files and their SHA-256 into FILES below when the site is put together
// (the "pages" job of .github/workflows/web.yml), so this file changes whenever the site does: that is how the
// browser learns there is a new version.
// - "core" files (the pages, the game's program openlf2.js / .wasm / .data, the small scripts, the icons) are stored
//   when this version installs, all of them or none, each checked against its SHA-256: a version only takes over
//   once it has every core file of its own, so the page and the program it runs always come from one version, and
//   the app opens with no network.
// - "lazy" files (Hero Fighter's Ruffle, the licences) are stored the first time they are used.
// - Everything else - the relay, archive.org, the XOI kits, the Windows emulator, this file - comes from the network
//   as before.
// Files are kept by their SHA-256, so a new version reuses whatever did not change (most updates leave the
// 11 MB program as it was) and drops the rest once it takes over. The game data the pages keep themselves (the LF2
// installer, the mods, in IndexedDB) are not this file's business.
// A new version waits until the page lets it in (dist/pages/pwa.js): at once when nobody is playing, else when the
// player says so.

const FILES = {"version": "dev", "core": {}, "lazy": {}}; // @files (dist/pages/make-pwa.py)

const STORE = 'openlf2-files';
const SCOPE = new URL('./', self.location.href);

const key = (digest) => new URL('__sha256/' + digest, SCOPE).href;

function hex(buffer) {
  return Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

// A file of this version from the network, checked and kept. The browser's own copy first (the page may just have
// loaded it), then the server's: right after a new site goes out, a cache may still hold the old file for minutes.
async function fetchAndStore(cache, path, digest) {
  let last = 'not found';
  for (const mode of ['default', 'reload']) {
    const response = await fetch(new URL(path, SCOPE).href, { cache: mode, credentials: 'same-origin' });
    if (!response.ok) {
      last = 'HTTP ' + response.status;
      continue;
    }
    const body = await response.arrayBuffer();
    if (hex(await crypto.subtle.digest('SHA-256', body)) !== digest) {
      last = 'another version';
      continue;
    }
    const headers = new Headers();
    for (const name of ['content-type', 'last-modified', 'etag']) {
      const value = response.headers.get(name);
      if (value) headers.set(name, value);
    }
    if (path.endsWith('.wasm')) headers.set('content-type', 'application/wasm'); // streaming compilation wants it
    headers.set('x-openlf2-sha256', digest);
    const stored = new Response(body, { status: 200, headers });
    await cache.put(key(digest), stored.clone());
    return stored;
  }
  throw new Error(path + ': ' + last);
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(STORE);
    for (const [path, [digest]] of Object.entries(FILES.core)) {
      if (!(await cache.match(key(digest)))) await fetchAndStore(cache, path, digest);
    }
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(STORE);
    const keep = new Set(Object.values(FILES.core).concat(Object.values(FILES.lazy)).map(([digest]) => key(digest)));
    for (const request of await cache.keys()) {
      if (!keep.has(request.url)) await cache.delete(request);
    }
    for (const name of await caches.keys()) {
      if (name !== STORE && name.startsWith('openlf2-')) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});

// The page lets a waiting version in (dist/pages/pwa.js); it reloads once this one controls it.
self.addEventListener('message', (event) => {
  if (event.data === 'skip-waiting') self.skipWaiting();
});

async function serve(request, path, digest) {
  const cache = await caches.open(STORE);
  let response = await cache.match(key(digest));
  if (!response) {
    try {
      response = await fetchAndStore(cache, path, digest);
    } catch (error) {
      // Not this version's file any more (a newer site is out: this page updates soon) or no network: the
      // network's answer as it is, else an error the page reports.
      try {
        return await fetch(request);
      } catch (offline) {
        return new Response('', { status: 504, statusText: 'Offline' });
      }
    }
  }
  if (request.method === 'HEAD') return new Response(null, { status: 200, headers: response.headers });
  return response;
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET' && request.method !== 'HEAD') return;
  const url = new URL(request.url);
  if (url.origin !== SCOPE.origin || !url.pathname.startsWith(SCOPE.pathname)) return;
  let path;
  try {
    path = decodeURIComponent(url.pathname.slice(SCOPE.pathname.length));
  } catch (error) {
    return;
  }
  if (path === '') path = 'index.html';
  const entry = FILES.core[path] || FILES.lazy[path];
  if (!entry) return;
  event.respondWith(serve(request, path, entry[0]));
});
