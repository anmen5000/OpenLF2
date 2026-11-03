// SPDX-License-Identifier: MIT
//
// Hero Fighter v0.7+ on the game page: the game (a Flash movie, inside the Windows program of its ZIP
// file) runs in Ruffle, a Flash player in WebAssembly the site keeps in ruffle/. What it needs online
// goes to the relay (tools/relay/hf.js): its accounts, room list and rooms; in a room, the pages also pass
// the game's frames to each other directly when they can (hf-direct.js). The movie comes from the
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

  // ---- Fewer pictures on a computer that cannot keep up -------------------------------------------------
  // Console.UpdateScreen, the game's frame loop, runs a frame of the fight (World.Run) and then draws it
  // (World.Draw) every 33 ms. The games of a room run every frame together, so the slowest computer sets
  // the pace for all: in a Battle with many soldiers a slower one that needs 45 ms for both slows every
  // game down to 22 frames a second. The loop can leave out the drawing (skipI) when the game is more than
  // fDurSkip (100 ms) behind, but the game sets skipI to 0 in both branches, so it always draws. These bytes
  // of the loop (offsets 629-684 of its code: "if (T - nextT > fDurSkip || fasterF2 > 250) skipI = 0; else
  // skipI = 0;") become "if (T - nextT > fDurSkip & Global.lastRunDur + Global.lastDrawDur > 33) skipI =
  // !skipI; else skipI = 0;" in as many bytes: when this computer is behind AND its own frames take longer
  // than 33 ms (the game's timings of its last frame and last drawing), it draws every other frame, so it
  // still shows at least half of them and its frames cost less until it catches up. A computer that is
  // only behind because it waits for a slower one (its own frames fast) draws every frame, as before. The
  // fight itself (World.Run, the random numbers, what every game sends) is the same whether or not a game
  // draws: World.Draw and what it calls only change pictures and their caches (the one call into a game
  // object, a background item's Run, runs a decoration in a world of its own), so games that draw different
  // frames stay in step. Tried on two Chromium pages in a network Battle (4 kingdoms, Crazy): one never
  // drawing (hfskip=all), the other this way, 1,880 frames and every 20 frames the same count of random
  // numbers on both (87,319 at the end), as the relay checks; and two pages alone in their rooms, too slow
  // to keep up, ran their fights at 5.0 frames a second this way against 2.5-2.9 drawing every frame (and
  // the same with the pages swapped). hfskip=0 in the page's address leaves the game as it is; hfskip=all
  // (for measuring what the fight costs without its pictures) never draws a frame of a fight.
  const DRAW_SKIP_FROM = [
    0xd0, 0x66, 0xd2, 0x17, 0xd0, 0x66, 0xa9, 0x0d, 0x10, 0x00, 0x00, 0x00, // getlocal0 .T, getlocal0 .nextT, jump +0
    0xa1, 0xd0, 0x66, 0xcd, 0x5c, 0xaf, 0x2a, 0x11, 0x09, 0x00, 0x00, // subtract, .fDurSkip, greaterthan, dup, iftrue
    0x29, 0xd0, 0x66, 0xb3, 0x11, 0x25, 0xfa, 0x01, 0xaf, // pop, getlocal0 .fasterF2, pushshort 250, greaterthan
    0x12, 0x0e, 0x00, 0x00, // iffalse (to the else branch)
    0xd0, 0x10, 0x00, 0x00, 0x00, 0x24, 0x00, 0x68, 0xbb, 0x2b, // getlocal0, jump +0, pushbyte 0, initproperty skipI
    0x10, 0x06, 0x00, 0x00, // jump (past the else branch)
    0xd0, 0x24, 0x00, 0x68, 0xbb, 0x2b, // else: getlocal0, pushbyte 0, initproperty skipI
  ];
  const DRAW_SKIP_AUTO = [
    0xd0, 0x66, 0xd2, 0x17, 0xd0, 0x66, 0xa9, 0x0d, 0xa1, // getlocal0 .T, getlocal0 .nextT, subtract
    0xd0, 0x66, 0xcd, 0x5c, 0xaf, // getlocal0 .fDurSkip, greaterthan
    0x60, 0x03, 0x66, 0x9f, 0x1e, 0x60, 0x03, 0x66, 0xc0, 0x22, 0xa0, // Global.lastRunDur + Global.lastDrawDur
    0x24, 0x21, 0xaf, 0xa8, 0x02, 0x02, 0x02, // pushbyte 33, greaterthan, bitand, nop nop nop
    0x12, 0x0e, 0x00, 0x00, // iffalse (to the else branch)
    0xd0, 0xd0, 0x66, 0xbb, 0x2b, 0x96, 0x68, 0xbb, 0x2b, 0x02, // getlocal0, getlocal0 .skipI, not, initproperty skipI, nop
    0x10, 0x06, 0x00, 0x00,
    0xd0, 0x24, 0x00, 0x68, 0xbb, 0x2b,
  ];
  // Never draws in a fight: both branches set skipI to 1.
  const DRAW_SKIP_ALL = DRAW_SKIP_FROM.map((byte, index) => (index === 42 || index === 52 ? 1 : byte));

  // Changes the loop in bytes (an uncompressed movie, patchMovie's copy) for this mode ('auto', 'all' or
  // 'off'); returns whether it found the loop (another version of the game has other bytes: left as it is).
  function skipDrawing(bytes, mode) {
    if (mode === 'off') return false;
    const at = indexOfBytes(bytes, DRAW_SKIP_FROM);
    if (at < 0 || indexOfBytes(bytes, DRAW_SKIP_FROM, at + 1) >= 0) return false;
    bytes.set(mode === 'all' ? DRAW_SKIP_ALL : DRAW_SKIP_AUTO, at);
    return true;
  }

  // ---- No ads, a chat that folds, a minimap that never waits for the graphics card ------------------------
  // Byte patches of the game's ActionScript, each a method's header and code found once in the uncompressed movie
  // (patchMovie's copy) and as many bytes put in it; another version of the game (other bytes) keeps that group as
  // it is. None changes the fight (World.Run's numbers, the random numbers, what the games send): like the drawing
  // ones, they come after the room's build is reckoned. hftidy=0 in the page's address leaves them all out. Built
  // and checked (every branch lands on an instruction, none from outside into what changes) with an AVM2 reader
  // over the decompiled game (Hero Fighter v0.7+).
  //  - minimap: Ruffle keeps a BitmapData's pixels on the CPU while only CPU operations touch it (fillRect,
  //    copyPixels, a draw() of a bitmap whose pixels are on the CPU too); anything else is drawn on the GPU, and the
  //    next CPU operation on that bitmap waits for the GPU to finish all it was given and copies the pixels back: the
  //    whole page stalls. The minimap did that twice every 10 frames in a fight: World.Run draws its camera frame as a
  //    vector Shape into it (four fillRects now, from the frame's corners in 4 more local registers, local_count 8 ->
  //    12), and MapGadget.ClearMap0 draws its background bitmap (bm0, made from vector shapes at the fight's start,
  //    so on the GPU) into it (copyPixels now, which brings bm0's pixels back once; the same pixels, as each target
  //    was just cleared to 0; a Rectangle and a Point in 2 more locals, local_count 1 -> 3).
  //  - ads: BannerGadget.PageChanged (the banners of the title screen and the main menu, and the one sliding in
  //    during a fight) hides them all and stops there; the premium ad is hidden (AdPremiumGadget.PageChanged) and,
  //    as the character menu, the character list and the fights' summary show it themselves, see-through and
  //    click-through from its start (AdPremiumGadget.OnLoad: alpha 0, no mouse); the 300x250 "click away" ad of the
  //    character menu (Console.InitClickAwayAdLink, __AddClickAwayAd) is never made; the main menu's "more
  //    games..." link is hidden (TitleScreen.OnLoad).
  //  - chat: its speech bubble (top left of the chat) and its arrow with nothing typed (ChatGadget.OnClickChatGo's
  //    else, which did nothing) fold the chat to the bubble alone, the log, the box and the arrow hidden (nothing
  //    left over the game to click through), and open it again; the bubble calls the arrow's click (OnLoad).
  const TIDY = {
    minimap: [
      ['World.Run locals', 'b63740080405a18902d03020809b16d7240063046003669702', 3,
        '0c'],
      ['World.Run minimap frame', 'd0100000005d95024a950200689919d066991966e60124012d0227120a0000240529292929100400004fe30902d066991966e6016019d066d502d0664da1d0665bd0664da1a325a001a2469f01016019d0669103d066f40da32428a2469f010127120a0000240529292929100400004f840b02d066991966e6016019d066bd06d0664da1d0665bd0664da1a325a001a2469f0101100000006019d010000000669103d066f40da32428a2469f010127120a0000240529292929100400004f910702d066991966e601100000006019d066bd06d0664da1d0665bd0664d10000000a1a325a00110000000a2469f0101601910000000d066bb07d066f40da3100000002428a2469f010127120a0000240529292929100400004f910702d066991966e601601910000000d066d502d0664da1d0665b10000000d0664da110000000a325a001a210000000469f01016019d01000000066bb0710000000d01000000066f40da32428a2469f010127120a0000240529292929100400004f910702d066991966e6016019d066d502d010000000664da1d0665bd0664d10000000a1a325a001a2469f0101601910000000d0669103d066f40da32428a2469f010127120a0000240529292929100400004f910702d0668112d06699194fc20101', 0,
        '6019d066d502d0664da1d0665bd0664da1a325a001a2469f010163086019d066bd06d0664da1d0665bd0664da1a325a001a2469f010163096019d0669103d066f40da32428a2469f0101630a6019d066bb07d066f40da32428a2469f0101630bd06681125d2c6208620a62096208a12401a024014a2c042f194fdb0102d06681125d2c6208620b62096208a12401a024014a2c042f194fdb0102d06681125d2c6208620a2401620b620aa12401a04a2c042f194fdb0102d06681125d2c6209620a2401620b620aa12401a04a2c042f194fdb01021003010002020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202'],
      ['MapGadget.ClearMap0', 'df2d38010b0c6dd030d06685035d2c24002ad06620d066234a2c04240027120a0000240529292929100400004fdb0102d0668503d066e91d4fc20101d066e91d5d2c24002ad06620d066234a2c0424001000000027120a0000240529292929100400004fdb0102d066e91dd066b81a4fc2010147', 3,
        '030b0c6dd0305d2c24002ad06620d066234a2c04d55d1e24002a4a1e02d6d0668503d124004fdb0102d0668503d066e91dd1d24fdf0803d066e91dd124004fdb0102d066e91dd066b81ad1d24fdf0803470202020202020202020202020202020202020202020202020202020202020202'],
    ],
    ads: [
      ['BannerGadget.PageChanged', '8c2436040d0ed106d01000000030d027100000006118d0271000000068e40cd066ce43276118d066cf43276118d066d1431000000027100000006118d01000000066cd43276118d066d04310000000276118d0668132276118d0100000006681328038d5d01000000066ae112408a4100000002400ab', 89,
        '4702020202'],
      ['AdPremiumGadget.PageChanged', 'd12a34020d0e9f03d0302080ea1e10000000d56013669d022cfb03ab2a110a0000296013669d022cfc03', 10,
        'd027611847020202'],
      ['AdPremiumGadget.OnLoad', 'ce2a33010d0e15d030d0271208000024052929100400004f8c020047', 7,
        'd030d024006143d02761900cd02761ba0647020202'],
      ['Console.InitClickAwayAdLink', 'a01436030f14f714d030572ad53065012080af036d01d0669105100000002400d0668935', 10,
        '4702'],
      ['Console.__AddClickAwayAd', 'b61437010e0f8c02d03060951e1201000047d066b4032013120000d027120800002405292910040000', 10,
        '02020202020202'],
      ['TitleScreen.OnLoad', 'f63536010e0f3ad030d05dea01d066d85e242146ea01021000000068bb4ed0271208000024052929100400004f8c0200601366961e12000000d066a71b27611847', 31,
        'd066e869276118100200000202'],
    ],
    chat: [
      ['ChatGadget.OnClickChatGo', 'a62335010d0eda01d030d066dd0866412c05ab962a121a000029d066dd086641240010000000468203012ceb01ab9610000000121e0000d0271208000024052929100400004fc84c006013d066dd0866414fca6a01d066dd082f056143d066dd0860032cb007100000004639016141601366bf0b1000000020131a0000601366bf0b271208000024052929100400004fbf0400104a0000601366e2062010000000131a0000601366e206271208000024052929100400004fbf040010220000601366b20720131800006013662966e809271208000024052929100400004fbf040047', 8,
        'd030d066dd0866412c05ab962a1212000029d066dd0866412400468203012ceb01ab9612150000d04fc84c006013d066dd0866414fca6a01101e0000d06683146618962a2ad06683142b6118d066dd082b6118d066eb0e2b6118d066dd082f056143d066dd0860032cb0074639016141601366bf0b20130d0000601366bf0b4fbf0400102c0000601366e20620130d0000601366e2064fbf040010150000601366b20720130b00006013662966e8094fbf0400470202020202020202020202020202020202020202020202020202020202020202020202020202'],
      ['ChatGadget.OnLoad', 'a22336010d0e40d030d0271208000024052929100400004f8c0200d066dd081000000060032cb0074639016141d0100000005dea0110000000d066b25d246446ea010268b75d47', 7,
        'd030d04f8c0200d066dd0860032cb0074639016141d05dea01d066b25d246446ea010268b75dd066a2682c14d066e2674f2e0247020202020202020202020202'],
    ],
  };
  const hexBytes = (hex) => Uint8Array.from(hex.match(/../g), (pair) => parseInt(pair, 16));

  // Puts in each group whose every patch it finds once; returns the groups put in.
  function tidyGame(bytes) {
    const done = [];
    for (const [group, patches] of Object.entries(TIDY)) {
      const places = patches.map(([, find]) => {
        const needle = hexBytes(find);
        const at = indexOfBytes(bytes, needle);
        return at >= 0 && indexOfBytes(bytes, needle, at + 1) < 0 ? at : -1;
      });
      if (places.some((at) => at < 0)) continue;
      patches.forEach(([, , offset, put], k) => bytes.set(hexBytes(put), places[k] + offset));
      done.push(group);
    }
    return done;
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

  // ---- How fast this computer runs the game -----------------------------------------------------------
  // For finding out what makes a crowded fight slow on a player's computer: how long Ruffle's frames take (the
  // page's animation frames, where Ruffle runs the game and draws it) and how much of that is waiting for the
  // graphics card to hand pictures back (WebGL's getBufferSubData, readPixels, clientWaitSync, finish: Ruffle's
  // GPU-to-CPU copies of a BitmapData). Every 30 s in which the frames took 25 ms or more on average, a line in
  // the log (Diagnostic output). Only those rare calls and the animation frames are timed, which costs nothing
  // a player would notice.
  function watchSpeed(log) {
    const totals = { frames: 0, ms: 0, worst: 0, waits: 0, waitMs: 0 };
    const waiting = ['getBufferSubData', 'readPixels', 'clientWaitSync', 'finish'];
    for (const Context of [window.WebGL2RenderingContext, window.WebGLRenderingContext]) {
      if (!Context) continue;
      for (const name of waiting) {
        const original = Context.prototype[name];
        if (typeof original !== 'function' || original.hfTimed) continue;
        const timed = function (...args) {
          const begin = performance.now();
          try { return original.apply(this, args); } finally { totals.waits += 1; totals.waitMs += performance.now() - begin; }
        };
        timed.hfTimed = true;
        Context.prototype[name] = timed;
      }
    }
    const raf = window.requestAnimationFrame;
    window.requestAnimationFrame = (callback) => raf.call(window, (time) => {
      const begin = performance.now();
      try { callback(time); } finally {
        const spent = performance.now() - begin;
        totals.frames += 1;
        totals.ms += spent;
        if (spent > totals.worst) totals.worst = spent;
      }
    });
    let last = { ...totals };
    let lastTime = performance.now();
    setInterval(() => {
      const now = performance.now();
      const frames = totals.frames - last.frames;
      const seconds = (now - lastTime) / 1000;
      const each = frames ? (totals.ms - last.ms) / frames : 0;
      if (frames && each >= 25) {
        log(`Hero Fighter speed (last ${Math.round(seconds)} s): ${(frames / seconds).toFixed(1)} frames/s, Ruffle ${each.toFixed(1)} ms a frame `
          + `(of it ${((totals.waitMs - last.waitMs) / frames).toFixed(1)} ms waiting for the graphics card, ${((totals.waits - last.waits) / frames).toFixed(2)} times), `
          + `slowest ${totals.worst.toFixed(0)} ms`);
      }
      totals.worst = 0;
      last = { ...totals };
      lastTime = now;
    }, 30000);
  }

  // ---- Running the game ----------------------------------------------------------------------------
  // options: stage (element), movie (Uint8Array), site (the page's folder URL), relay (wss://… or ''),
  //          status(text), log(text), net(text): how the room's direct links are ('' for nothing to say),
  //          directEnabled(): whether direct links are wanted now (the page's switch; HfDirect.refresh() after
  //          it changed). Returns the Ruffle player element.
  async function start(options) {
    const { stage, site, status, log } = options;
    // Direct links between the pages of a room (hf-direct.js), when this browser makes them; hfdirect=0 in the
    // page's address plays through the relay only.
    // In a room, the ping at the bottom of the game (as for LF2: online.js), from the same figures: in the middle,
    // as the game's own panels take its corners (the troops and the language on the left, the map on the right).
    const corner = document.createElement('div');
    corner.className = 'hf-corner';
    corner.hidden = true;
    corner.setAttribute('aria-hidden', 'true');
    corner.style.cssText = 'position:absolute;left:50%;transform:translateX(-50%);bottom:4px;z-index:5;pointer-events:none;padding:2px 7px;'
      + 'border-radius:5px;background:rgba(0,0,0,.5);color:#fff;font:600 12px/1.45 system-ui,sans-serif;white-space:nowrap;'
      + 'text-shadow:0 1px 1px #000';
    const direct = !/[?&]hfdirect=0(&|$)/.test(location.search) && Boolean(window.HfDirect && window.HfDirect.install(window, {
      status: (text, figures) => {
        if (typeof options.net === 'function') options.net(text);
        if (!figures) {
          corner.hidden = true;
          return;
        }
        const parts = [`Ping ${figures.ping === null ? '…' : `${Math.round(figures.ping)} ms`}`, figures.way];
        // This computer busy (Ruffle's frames taking that long): the game itself runs slow, whatever the network.
        if (figures.busy >= 40) parts.push(`busy ${Math.round(figures.busy)} ms`);
        if (figures.peerBusy !== null && figures.peerBusy >= 40) parts.push(`other busy ${Math.round(figures.peerBusy)} ms`);
        corner.textContent = parts.join(' · ');
        corner.style.color = figures.busy >= 100 || (figures.peerBusy !== null && figures.peerBusy >= 100) ? '#ffb74d' : '#fff';
        corner.hidden = false;
      },
      log,
      enabled: typeof options.directEnabled === 'function' ? options.directEnabled : undefined,
    }));
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
    // After the build: games that draw fewer frames play the same fights, so they may share a room.
    const skipMode = (/[?&]hfskip=(0|off|all)(&|$)/.exec(location.search) || [])[1];
    const skipping = skipDrawing(bytes, skipMode === 'all' ? 'all' : skipMode ? 'off' : 'auto');
    if (!/[?&]hftidy=0(&|$)/.test(location.search)) {
      const tidied = tidyGame(bytes);
      log('Hero Fighter: ' + (tidied.length ? 'changed for this page: ' + tidied.join(', ') : 'no ads, chat or minimap change (another version of the game?)'));
    }
    if (skipMode !== '0' && skipMode !== 'off') {
      log('Hero Fighter: ' + (skipping ? (skipMode === 'all' ? 'never draws a fight (hfskip=all)' : 'draws every other frame when this computer falls behind')
        : 'frame loop not found (another version of the game?): it draws every frame'));
    }

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
            proxyUrl: relay + (relay.includes('?') ? '&' : '?') + 'game=hf&room=' + room.room + '&build=' + encodeURIComponent(build)
              + (direct ? '&direct=1' : '') });
        }
        rewrites.push([/^https?:\/\/s\.herofighter\.com\//, relayHttp + 'hf/s/']);
        rewrites.push([/^https?:\/\/(www\.)?herofighter\.com\/hf\//, relayHttp + 'hf/hf/']);
        log('Hero Fighter: ' + sockets.length + ' rooms on the relay');
      } catch (error) {
        log('Hero Fighter: the relay has no Hero Fighter rooms (' + error.message + '): only "Try the game" works');
      }
    }

    stage.classList.add('hf');
    // Before Ruffle makes its WebGL context and its AudioContext: the speed log, and the sound for remote play
    // (hf-remote.js), whose host sends it with the picture.
    if (!/[?&]hfspeed=0(&|$)/.test(location.search)) watchSpeed(log);
    if (window.HfRemote) window.HfRemote.tapAudio();
    const player = source.createPlayer();
    player.className = 'hf-player';
    player.tabIndex = 0;
    stage.appendChild(player);
    stage.appendChild(corner);
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

  return { movieFrom, looksLikeHeroFighter, patchMovie, skipDrawing, tidyGame, TIDY, start, addTouchControls, KEYS };
})();
