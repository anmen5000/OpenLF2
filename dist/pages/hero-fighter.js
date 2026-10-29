// SPDX-License-Identifier: MIT
//
// Hero Fighter v0.7+ on the game page: the game (a Flash movie, inside the Windows program of its ZIP
// file) runs in Ruffle, a Flash player in WebAssembly the site keeps in ruffle/. What it needs online
// goes to the relay (tools/relay/hf.js): its accounts, room list and rooms. The movie comes from the
// relay (its admin uploads it once) or from a file the player selects; the browser keeps it.
//
//   HeroFighter.movieFrom(blob)       the movie (Uint8Array) in a .swf, a projector .exe or a ZIP of one; or null
//   HeroFighter.start(options)        runs a movie on the page (see start below)
'use strict';

window.HeroFighter = (() => {
  const PROJECTOR_MAGIC = 0xfa123456;
  // Keys of the game's first player (its defaults: the numeric keypad), for the touch controls.
  const KEYS = {
    up: { code: 'Numpad8', key: '8', keyCode: 104 },
    down: { code: 'Numpad2', key: '2', keyCode: 98 },
    left: { code: 'Numpad4', key: '4', keyCode: 100 },
    right: { code: 'Numpad6', key: '6', keyCode: 102 },
    attack: { code: 'Numpad5', key: '5', keyCode: 101 },
    jump: { code: 'Numpad0', key: '0', keyCode: 96 },
    guard: { code: 'NumpadAdd', key: '+', keyCode: 107 },
    command: { code: 'NumpadSubtract', key: '-', keyCode: 109 },
  };

  const isSwf = (bytes) => bytes.length > 8 && [0x46, 0x43, 0x5a].includes(bytes[0]) && bytes[1] === 0x57 && bytes[2] === 0x53;

  // ---- The movie in a file -------------------------------------------------------------------------
  async function readBytes(blob, start, end) {
    return new Uint8Array(await blob.slice(start, end).arrayBuffer());
  }

  // The entries of a ZIP file (its central directory).
  async function zipEntries(blob) {
    const tailSize = Math.min(blob.size, 22 + 65535);
    const tail = await readBytes(blob, blob.size - tailSize, blob.size);
    const view = new DataView(tail.buffer);
    let end = -1;
    for (let at = tail.length - 22; at >= 0; at -= 1) {
      if (view.getUint32(at, true) === 0x06054b50) { end = at; break; }
    }
    if (end < 0) return [];
    const count = view.getUint16(end + 10, true);
    const size = view.getUint32(end + 12, true);
    const offset = view.getUint32(end + 16, true);
    const directory = await readBytes(blob, offset, offset + size);
    const dir = new DataView(directory.buffer);
    const entries = [];
    for (let at = 0, index = 0; index < count && at + 46 <= directory.length; index += 1) {
      if (dir.getUint32(at, true) !== 0x02014b50) break;
      const nameLength = dir.getUint16(at + 28, true);
      entries.push({
        name: new TextDecoder('latin1').decode(directory.subarray(at + 46, at + 46 + nameLength)),
        flags: dir.getUint16(at + 8, true), method: dir.getUint16(at + 10, true),
        compressedSize: dir.getUint32(at + 20, true), size: dir.getUint32(at + 24, true), localOffset: dir.getUint32(at + 42, true),
      });
      at += 46 + nameLength + dir.getUint16(at + 30, true) + dir.getUint16(at + 32, true);
    }
    return entries;
  }

  async function zipEntryBlob(blob, entry) {
    const header = await readBytes(blob, entry.localOffset, entry.localOffset + 30);
    const view = new DataView(header.buffer);
    const start = entry.localOffset + 30 + view.getUint16(26, true) + view.getUint16(28, true);
    const packed = blob.slice(start, start + entry.compressedSize);
    if (entry.method === 0) return packed;
    if (entry.method !== 8) throw new Error(entry.name + ' is compressed in a way the browser cannot read');
    if (typeof DecompressionStream !== 'function') throw new Error('this browser cannot unpack ZIP files: select the .exe inside it instead');
    return new Response(packed.stream().pipeThrough(new DecompressionStream('deflate-raw'))).blob();
  }

  // The Flash movie a file holds (a movie, a projector, or a ZIP file of either), or null.
  async function movieFrom(blob, depth = 0) {
    if (!blob || blob.size < 16) return null;
    const head = await readBytes(blob, 0, 4);
    if (isSwf(head)) return new Uint8Array(await blob.arrayBuffer());
    if (head[0] === 0x4d && head[1] === 0x5a) { // "MZ": a Windows program, maybe a projector
      const footer = new DataView((await readBytes(blob, blob.size - 8, blob.size)).buffer);
      if (footer.getUint32(0, true) !== PROJECTOR_MAGIC) return null;
      const length = footer.getUint32(4, true);
      if (length < 9 || length > blob.size - 8) return null;
      const movie = await readBytes(blob, blob.size - 8 - length, blob.size - 8);
      return isSwf(movie) ? movie : null;
    }
    if (head[0] === 0x50 && head[1] === 0x4b && depth === 0) { // "PK": a ZIP file
      const entries = (await zipEntries(blob))
        .filter((entry) => /\.(swf|exe)$/i.test(entry.name) && !(entry.flags & 1))
        .sort((a, b) => b.size - a.size);
      for (const entry of entries) {
        const movie = await movieFrom(await zipEntryBlob(blob, entry), depth + 1);
        if (movie) return movie;
      }
    }
    return null;
  }

  // Whether a file the player selected is (or holds) Hero Fighter rather than LF2's installer or a mod:
  // a .swf, a projector, or a ZIP file with a program but no LF2 game folder.
  async function looksLikeHeroFighter(file) {
    if (/\.swf$/i.test(file.name)) return true;
    if (/\.exe$/i.test(file.name)) {
      if ([29586263, 31904750].includes(file.size)) return false; // LF2 v2.0a's installers
      const footer = new DataView((await readBytes(file, file.size - 8, file.size)).buffer);
      return file.size > 16 && footer.getUint32(0, true) === PROJECTOR_MAGIC;
    }
    if (/\.zip$/i.test(file.name)) {
      const entries = await zipEntries(file);
      if (entries.some((entry) => /(^|[\\/])data[\\/]data\.txt$/i.test(entry.name))) return false;
      return entries.some((entry) => /\.swf$/i.test(entry.name) || (/\.exe$/i.test(entry.name) && /hf|hero/i.test(entry.name)));
    }
    return false;
  }

  // ---- What Ruffle needs changed in the movie ---------------------------------------------------------
  // The game checks e-mail addresses and passwords with regular expressions ending in \z, which Flash
  // reads as "end of the text" and Ruffle (like JavaScript) as a plain "z": no address would pass. $$
  // (end of the text, twice) is what they mean, in as many bytes.
  const FIXES = [
    ['^(\\w|[_.\\-])+@((\\w|-)+\\.)+\\w{2,4}\\z', '^(\\w|[_.\\-])+@((\\w|-)+\\.)+\\w{2,4}$$'],
    ['^(\\w|[,.!?:;%$#@~]){6,12}\\z', '^(\\w|[,.!?:;%$#@~]){6,12}$$'],
  ];

  function indexOfBytes(haystack, needle, from = 0) {
    const first = needle[0];
    for (let at = haystack.indexOf(first, from); at >= 0 && at <= haystack.length - needle.length; at = haystack.indexOf(first, at + 1)) {
      let k = 1;
      while (k < needle.length && haystack[at + k] === needle[k]) k += 1;
      if (k === needle.length) return at;
    }
    return -1;
  }

  async function patchMovie(movie) {
    let bytes = movie;
    if (bytes[0] === 0x43) { // "CWS": zlib after the 8-byte header; patched as an uncompressed movie
      if (typeof DecompressionStream !== 'function') return { bytes, fixed: 0 };
      const body = await new Response(new Blob([bytes.subarray(8)]).stream().pipeThrough(new DecompressionStream('deflate'))).arrayBuffer();
      const whole = new Uint8Array(8 + body.byteLength);
      whole.set(bytes.subarray(0, 8));
      whole.set(new Uint8Array(body), 8);
      whole[0] = 0x46;
      bytes = whole;
    } else if (bytes[0] !== 0x46) {
      return { bytes, fixed: 0 }; // LZMA ("ZWS"): left as it is
    } else {
      bytes = new Uint8Array(bytes); // a copy: the stored movie stays the original
    }
    const encoder = new TextEncoder();
    let fixed = 0;
    for (const [from, to] of FIXES) {
      const needle = encoder.encode(from);
      const replacement = encoder.encode(to);
      for (let at = indexOfBytes(bytes, needle); at >= 0; at = indexOfBytes(bytes, needle, at + needle.length)) {
        bytes.set(replacement, at);
        fixed += 1;
      }
    }
    return { bytes, fixed };
  }

  // ---- Ruffle ------------------------------------------------------------------------------------------
  let rufflePromise = null;
  function loadRuffle(folder) {
    if (rufflePromise) return rufflePromise;
    rufflePromise = new Promise((resolve, reject) => {
      window.RufflePlayer = window.RufflePlayer || {};
      // Its files are beside ruffle.js; it should not look for other Flash content on the page.
      window.RufflePlayer.config = Object.assign({}, window.RufflePlayer.config || {}, { publicPath: folder, polyfills: false });
      const script = document.createElement('script');
      script.src = folder + 'ruffle.js';
      script.onload = () => {
        // ruffle.js installs window.RufflePlayer as it runs; a build that loads in parts may take a moment.
        const until = Date.now() + 15000;
        const check = () => {
          if (window.RufflePlayer && typeof window.RufflePlayer.newest === 'function') resolve(window.RufflePlayer);
          else if (Date.now() > until) reject(new Error('Ruffle did not start'));
          else setTimeout(check, 50);
        };
        check();
      };
      script.onerror = () => { rufflePromise = null; reject(new Error('could not load ' + script.src)); };
      document.head.appendChild(script);
    });
    return rufflePromise;
  }

  // ---- Touch controls ------------------------------------------------------------------------------
  // A stick (up, down, left, right, and the diagonals) and four buttons over the game, sending the first
  // player's keys. They take no focus, so the game keeps the keyboard focus it needs.
  function addTouchControls(stage, player) {
    const pad = document.createElement('div');
    pad.className = 'hf-touch';
    pad.hidden = true;
    pad.innerHTML = '<div class="hf-stick"><div class="hf-knob"></div></div>'
      + '<div class="hf-buttons"><button data-key="guard" aria-label="Guard">G</button><button data-key="command" aria-label="Command">C</button>'
      + '<button data-key="jump" aria-label="Jump">J</button><button data-key="attack" aria-label="Attack">A</button></div>';
    stage.appendChild(pad);
    // The stage's height, for the sizes of the stick and buttons (a phone held upright has a short game).
    const fit = () => pad.style.setProperty('--hf-height', stage.clientHeight + 'px');
    if (window.ResizeObserver) new ResizeObserver(fit).observe(stage);
    fit();
    const held = new Set();
    const send = (name, down) => {
      if (down === held.has(name)) return;
      if (down) held.add(name); else held.delete(name);
      const key = KEYS[name];
      window.dispatchEvent(new KeyboardEvent(down ? 'keydown' : 'keyup', { ...key, which: key.keyCode, location: 3, bubbles: true }));
    };
    const keepFocus = () => { if (document.activeElement !== player) player.focus({ preventScroll: true }); };
    // The stick: directions from where the finger is, past a dead zone in the middle.
    const stick = pad.querySelector('.hf-stick');
    const knob = pad.querySelector('.hf-knob');
    let stickPointer = null;
    const directions = new Set();
    const aim = (event) => {
      const box = stick.getBoundingClientRect();
      const dx = event.clientX - (box.left + box.width / 2);
      const dy = event.clientY - (box.top + box.height / 2);
      const radius = box.width / 2;
      const length = Math.hypot(dx, dy);
      const scale = length > radius ? radius / length : 1;
      knob.style.transform = `translate(${dx * scale}px, ${dy * scale}px)`;
      const wanted = new Set();
      if (length > radius * 0.3) {
        const angle = Math.atan2(dy, dx) * 180 / Math.PI; // 0 right, 90 down
        if (angle > -67.5 && angle < 67.5) wanted.add('right');
        if (angle > 112.5 || angle < -112.5) wanted.add('left');
        if (angle > 22.5 && angle < 157.5) wanted.add('down');
        if (angle < -22.5 && angle > -157.5) wanted.add('up');
      }
      for (const name of ['up', 'down', 'left', 'right']) {
        if (wanted.has(name) !== directions.has(name)) {
          if (wanted.has(name)) directions.add(name); else directions.delete(name);
          send(name, wanted.has(name));
        }
      }
    };
    const release = () => {
      stickPointer = null;
      knob.style.transform = '';
      for (const name of [...directions]) { directions.delete(name); send(name, false); }
    };
    stick.addEventListener('pointerdown', (event) => {
      event.preventDefault();
      keepFocus();
      stickPointer = event.pointerId;
      stick.setPointerCapture(event.pointerId);
      aim(event);
    });
    stick.addEventListener('pointermove', (event) => { if (event.pointerId === stickPointer) { event.preventDefault(); aim(event); } });
    for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
      stick.addEventListener(type, (event) => { if (event.pointerId === stickPointer) release(); });
    }
    for (const button of pad.querySelectorAll('button')) {
      button.tabIndex = -1;
      const name = button.dataset.key;
      button.addEventListener('pointerdown', (event) => {
        event.preventDefault();
        keepFocus();
        button.setPointerCapture(event.pointerId);
        button.classList.add('down');
        send(name, true);
      });
      for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
        button.addEventListener(type, () => { button.classList.remove('down'); send(name, false); });
      }
      button.addEventListener('contextmenu', (event) => event.preventDefault());
    }
    // Shown once the player touches the screen; hidden again by a mouse or a key press.
    const show = (event) => { if (event.pointerType === 'touch') pad.hidden = false; };
    stage.addEventListener('pointerdown', show, true);
    window.addEventListener('keydown', (event) => { if (event.isTrusted && !pad.hidden && !/^Numpad/.test(event.code)) pad.hidden = true; });
    if (window.matchMedia && window.matchMedia('(pointer: coarse)').matches) pad.hidden = false;
    return pad;
  }

  // ---- Running the game ----------------------------------------------------------------------------
  // options: stage (element), movie (Uint8Array), site (the page's folder URL), relay (wss://… or ''),
  //          status(text), log(text). Returns the Ruffle player element.
  async function start(options) {
    const { stage, site, status, log } = options;
    status('Starting Ruffle (the Flash player)…');
    // The site's Ruffle (ruffle/: built with OpenLF2's change when that build worked), or with ruffle=stock in the
    // page's address the stock one beside it (ruffle-stock/), if the site has it.
    let folder = new URL('ruffle/', site).href;
    let ruffle = null;
    if (/[?&]ruffle=stock(&|$)/.test(location.search)) {
      try {
        ruffle = await loadRuffle(new URL('ruffle-stock/', site).href);
        folder = new URL('ruffle-stock/', site).href;
      } catch (error) {
        log('Hero Fighter: no stock Ruffle on this site (' + error.message + '): the usual one then');
      }
    }
    if (!ruffle) ruffle = await loadRuffle(folder);
    // This page's own Ruffle, even when the browser has the Ruffle extension (another version): every game in a
    // network room must run the same Flash player, else their fights drift apart ("Synchronization error").
    const source = (ruffle.sources && ruffle.sources.local) || (typeof ruffle.local === 'function' && ruffle.local()) || ruffle.newest();
    // For the log: which Ruffle this is (the site's own build, dist/ruffle-hf's CPU drawing, comes with OPENLF2.txt).
    fetch(new URL('OPENLF2.txt', folder).href, { method: 'HEAD', cache: 'no-store' })
      .then((response) => log('Hero Fighter: Ruffle ' + (source.version || '?') + (response.ok ? ", with OpenLF2's CPU drawing" : '')))
      .catch(() => { /* only for the log */ });
    const { bytes, fixed } = await patchMovie(options.movie);
    if (fixed < 2) log('Hero Fighter: ' + fixed + ' of the 2 e-mail/password checks fixed for Ruffle (another version of the game?)');
    // The build the relay's rooms compare: this movie and this Ruffle.
    let build = 'ruffle' + (source.version || '?');
    try {
      const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
      build = Array.from(digest.subarray(0, 8), (byte) => byte.toString(16).padStart(2, '0')).join('') + '-' + build;
    } catch (error) { /* no crypto.subtle (not https): the Ruffle version alone */ }

    // The relay: rooms and accounts, when it has them (relays installed before Hero Fighter do not).
    const rewrites = [
      [/^https?:\/\/www\.herofighter\.com\/ver\.txt$/, new URL('hf-ver.txt', site).href],
    ];
    const sockets = [];
    const relay = options.relay || '';
    let relayHttp = '';
    try {
      const url = new URL(relay);
      if (url.protocol === 'wss:' || url.protocol === 'ws:') {
        url.protocol = url.protocol === 'ws:' ? 'http:' : 'https:';
        url.pathname = url.pathname.replace(/[^/]*$/, '');
        url.search = '';
        relayHttp = url.href;
      }
    } catch (error) { /* no relay */ }
    if (relayHttp) {
      try {
        const response = await fetch(relayHttp + 'hf/rooms.json', { cache: 'no-store' });
        if (!response.ok) throw new Error('HTTP ' + response.status);
        const info = await response.json();
        for (const room of info.rooms || []) {
          sockets.push({ host: info.host, port: room.port,
            proxyUrl: relay + (relay.includes('?') ? '&' : '?') + 'game=hf&room=' + room.room + '&build=' + encodeURIComponent(build) });
        }
        rewrites.push([/^https?:\/\/s\.herofighter\.com\//, relayHttp + 'hf/s/']);
        rewrites.push([/^https?:\/\/(www\.)?herofighter\.com\/hf\//, relayHttp + 'hf/hf/']);
        log('Hero Fighter: ' + sockets.length + ' rooms on the relay');
      } catch (error) {
        log('Hero Fighter: the relay has no Hero Fighter rooms (' + error.message + '): only "Try the game" works');
      }
    }

    stage.classList.add('hf');
    const player = source.createPlayer();
    player.className = 'hf-player';
    player.tabIndex = 0;
    stage.appendChild(player);
    addTouchControls(stage, player);
    status('Loading Hero Fighter…');
    await player.ruffle().load({
      data: bytes,
      swfFileName: 'HeroFighter.swf',
      base: new URL('hf/', site).href,
      autoplay: 'on',
      unmuteOverlay: 'hidden',
      letterbox: 'on',
      backgroundColor: '#000000',
      splashScreen: true,
      // Loading the game's pictures takes a while on slow phones: more than Ruffle's 15 s for one script.
      maxExecutionDuration: 60,
      // No anti-aliasing: the game is drawn from pictures (pixel art), and what Ruffle draws for it on the GPU
      // (turned or flipped pictures, shadows) costs much less without it.
      quality: 'low',
      socketProxy: sockets,
      urlRewriteRules: rewrites,
      logLevel: 'warn',
    });
    player.focus({ preventScroll: true });
    return player;
  }

  return { movieFrom, looksLikeHeroFighter, patchMovie, start, KEYS };
})();
