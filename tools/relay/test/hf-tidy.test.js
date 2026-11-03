// SPDX-License-Identifier: MIT
//
// dist/pages/hero-fighter.js's patches of Hero Fighter's ActionScript (TIDY, tidyGame): the minimap's camera frame
// drawn on the CPU, the ads hidden, the chat that folds. What each puts in decodes into whole AVM2 instructions whose
// branches land on instructions; a group goes in only when every one of its patches is found, once; the bytes in a
// rewritten method are the methods they are meant to be (names from the movie's constant pool, as the page found them).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'dist', 'pages', 'hero-fighter.js'), 'utf8');
const context = vm.createContext({ window: {}, TextEncoder, Uint8Array, console });
vm.runInContext(source, context);
const { TIDY, tidyGame } = context.window.HeroFighter;
const hex = (text) => Uint8Array.from(text.match(/../g), (pair) => parseInt(pair, 16));

// AVM2 operands, by opcode: u30 (an index or a count), u8, s24 (a branch), or the lookupswitch's own form.
const OPERANDS = {};
const set = (kinds, ...codes) => { for (const code of codes) OPERANDS[code] = kinds; };
set([], 0x02, 0x03, 0x09, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x23, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x30, 0x47, 0x48, 0x57,
  0x64, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x81, 0x82, 0x83, 0x84, 0x85, 0x87, 0x88, 0x89, 0x90, 0x91, 0x93,
  0x95, 0x96, 0x97, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1,
  0xb3, 0xb4, 0xc0, 0xc1, 0xc4, 0xc5, 0xc6, 0xc7, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7);
set(['u30'], 0x04, 0x05, 0x08, 0x25, 0x2c, 0x2d, 0x2e, 0x2f, 0x31, 0x40, 0x41, 0x42, 0x49, 0x53, 0x55, 0x56, 0x58, 0x59, 0x5a,
  0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x66, 0x67, 0x68, 0x6a, 0x6c, 0x6d, 0x6e, 0x6f, 0x80, 0x86, 0x92, 0x94, 0xb2, 0xc2,
  0xc3, 0xf0, 0xf1, 0xf2);
set(['u30', 'u30'], 0x32, 0x43, 0x44, 0x45, 0x46, 0x4a, 0x4c, 0x4e, 0x4f);
set(['u8'], 0x24, 0x65);
set(['s24'], 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a);
set(['u8', 'u30', 'u8', 'u30'], 0xef);

// [{ at, op, operands, targets }] for every instruction of bytes (all of them: none may be cut short).
function decode(bytes) {
  const out = [];
  let at = 0;
  const u30 = () => {
    let value = 0;
    for (let shift = 0; ; shift += 7) {
      const byte = bytes[at++];
      assert.ok(byte !== undefined, 'an instruction runs past the bytes');
      value += (byte & 0x7f) * 2 ** shift;
      if (!(byte & 0x80)) return value;
    }
  };
  const s24 = () => { const value = (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16)) << 8 >> 8; at += 3; return value; };
  while (at < bytes.length) {
    const start = at;
    const op = bytes[at++];
    const operands = [];
    const targets = [];
    if (op === 0x1b) { // lookupswitch: default, case count, cases (from the instruction's start)
      targets.push(start + s24());
      const count = u30();
      for (let k = 0; k <= count; k += 1) targets.push(start + s24());
    } else {
      const kinds = OPERANDS[op];
      assert.ok(kinds, `unknown opcode ${op.toString(16)} at ${start}`);
      for (const kind of kinds) {
        if (kind === 'u8') operands.push(bytes[at++]);
        else if (kind === 's24') { const offset = s24(); targets.push(at + offset); } else operands.push(u30());
      }
    }
    assert.ok(at <= bytes.length, `the instruction at ${start} runs past the bytes`);
    out.push({ at: start, op, operands, targets });
  }
  return out;
}

const patches = Object.entries(TIDY).flatMap(([group, list]) => list.map(([name, find, at, put]) => ({ group, name, find: hex(find), at, put: hex(put) })));
const named = (name) => patches.find((patch) => patch.name === name);

test('every patch puts as many bytes, inside what it finds, in whole instructions whose branches land on instructions', () => {
  assert.deepEqual(Object.keys(TIDY), ['minimap', 'ads', 'chat']);
  for (const { name, find, at, put } of patches) {
    assert.ok(at + put.length <= find.length, name);
    if (name === 'World.Run locals') continue; // a byte of a method's header (below)
    if (name === 'MapGadget.ClearMap0') continue; // the end of its header, then its code (below)
    const instructions = decode(put);
    const starts = new Set(instructions.map((item) => item.at));
    for (const { at: from, targets } of instructions) {
      for (const target of targets) assert.ok(starts.has(target) || target === put.length, `${name}: the branch at ${from} lands inside an instruction (${target})`);
    }
  }
});

test('the minimap: its camera frame in four fillRects from 4 more locals; ClearMap0 in copyPixels, never a draw', () => {
  const locals = named('World.Run locals');
  assert.equal(locals.find[locals.at], 8); // local_count of World.Run's header
  assert.deepEqual([...locals.put], [12]);
  const block = named('World.Run minimap frame');
  assert.equal(block.at, 0);
  assert.equal(block.put.length, block.find.length);
  const ops = decode(block.put);
  const fills = ops.filter((item) => item.op === 0x4f); // callpropvoid fillRect 2
  assert.equal(fills.length, 4);
  for (const fill of fills) assert.equal(fill.operands[1], 2);
  assert.equal(ops.filter((item) => item.op === 0x4a && item.operands[1] === 4).length, 4); // constructprop Rectangle 4
  const registers = new Set(ops.filter((item) => item.op === 0x62 || item.op === 0x63).map((item) => item.operands[0]));
  assert.deepEqual([...registers].sort(), [10, 11, 8, 9]);
  // No vector drawing any more: the old code's draw (a callpropvoid with 1 argument) and its Shape are gone.
  assert.equal(ops.some((item) => item.op === 0x4f && item.operands[1] === 1), false);
  const jump = ops.find((item) => item.op === 0x10);
  assert.deepEqual(jump.targets, [block.put.length]);
  assert.ok(ops.filter((item) => item.at > jump.at).every((item) => item.op === 0x02));
  // ClearMap0: two fillRects (callpropvoid ... 2) and two copyPixels (... 3) from a Rectangle and a Point kept in
  // locals 1 and 2 (local_count 1 -> 3), and no draw (callpropvoid ... 1) any more.
  // (The patch puts the header's last bytes, from local_count on, and then the code: 109 bytes, as before.)
  const clearMap = named('MapGadget.ClearMap0');
  const codeLength = 109;
  assert.equal(clearMap.find[clearMap.at], 1); // local_count
  assert.equal(clearMap.put[0], 3);
  assert.equal(clearMap.at + clearMap.put.length, clearMap.find.length);
  assert.deepEqual([...clearMap.put.subarray(1, clearMap.put.length - codeLength)],
    [...clearMap.find.subarray(clearMap.at + 1, clearMap.find.length - codeLength)]);
  const clear = decode(clearMap.put.subarray(clearMap.put.length - codeLength)).filter((item) => item.op !== 0x02);
  const calls = clear.filter((item) => item.op === 0x4f).map((item) => item.operands[1]);
  assert.deepEqual(calls, [2, 3, 2, 3]);
  assert.deepEqual(clear.filter((item) => item.op === 0x4a).map((item) => item.operands[1]), [4, 2]); // new Rectangle, new Point
  assert.deepEqual(clear.filter((item) => item.op === 0xd5 || item.op === 0xd6).map((item) => item.op), [0xd5, 0xd6]);
  assert.equal(clear.at(-1).op, 0x47);
});

test('the ads: each stops its method where it begins hiding or making the ad', () => {
  const banner = decode(named('BannerGadget.PageChanged').put).map((item) => item.op);
  assert.deepEqual(banner, [0x47, 0x02, 0x02, 0x02, 0x02]);
  const premium = decode(named('AdPremiumGadget.PageChanged').put).map((item) => item.op);
  assert.deepEqual(premium.filter((op) => op !== 0x02), [0xd0, 0x27, 0x61, 0x47]); // this.visible = false; return
  assert.deepEqual(decode(named('Console.InitClickAwayAdLink').put).map((item) => item.op), [0x47, 0x02]);
  assert.deepEqual(decode(named('Console.__AddClickAwayAd').put).map((item) => item.op), new Array(7).fill(0x02));
  // That one falls through to the returnvoid after its old inKong test.
  const add = named('Console.__AddClickAwayAd');
  assert.equal(add.find[add.at + add.put.length], 0x47);
  // The premium ad that pages show themselves: alpha 0, mouseChildren and mouseEnabled false, from its start.
  const load = decode(named('AdPremiumGadget.OnLoad').put).filter((item) => item.op !== 0x02).map((item) => item.op);
  assert.deepEqual(load, [0xd0, 0x30, 0xd0, 0x24, 0x61, 0xd0, 0x27, 0x61, 0xd0, 0x27, 0x61, 0x47]);
  // "more games...": hidden (this, the link, false, setproperty) and on to where the old branch went.
  const title = named('TitleScreen.OnLoad');
  const hide = decode(title.put);
  assert.deepEqual(hide.slice(0, 5).map((item) => item.op), [0xd0, 0x66, 0x27, 0x61, 0x10]);
  assert.deepEqual(hide[4].targets, [title.put.length]);
  assert.equal(title.find[title.at + title.put.length], 0x4f); // callpropvoid RefreshLang, as before
});

test('the chat: the arrow\'s else folds or opens it, the bubble calls the arrow; both methods end in returnvoid', () => {
  const go = decode(named('ChatGadget.OnClickChatGo').put);
  const code = go.filter((item) => item.op !== 0x02);
  assert.equal(code.at(-1).op, 0x47);
  // The toggle: three setproperty visible after a not, a dup and a dup, each of them through swap.
  const not = code.findIndex((item, k) => item.op === 0x96 && code[k + 1].op === 0x2a && code[k + 2].op === 0x2a);
  assert.ok(not > 0);
  const toggle = code.slice(not, not + 15).map((item) => item.op);
  assert.deepEqual(toggle, [0x96, 0x2a, 0x2a, 0xd0, 0x66, 0x2b, 0x61, 0xd0, 0x66, 0x2b, 0x61, 0xd0, 0x66, 0x2b, 0x61]);
  // Every branch of the method lands on one of its instructions, the else on the toggle.
  const starts = new Set(go.map((item) => item.at));
  for (const item of go) for (const target of item.targets) assert.ok(starts.has(target));
  const load = decode(named('ChatGadget.OnLoad').put).filter((item) => item.op !== 0x02);
  assert.equal(load.at(-1).op, 0x47);
  const listen = load.at(-2);
  assert.equal(listen.op, 0x4f); // callpropvoid addEventListener 2
  assert.equal(listen.operands[1], 2);
  assert.equal(load.at(-5).op, 0x2c); // pushstring 'click'
});

test('a group goes in when every patch of it is found once, else it is left as it is', () => {
  const filler = (n) => new Uint8Array(n).fill(0xd0);
  const pieces = [filler(100)];
  for (const patch of patches) pieces.push(patch.find, filler(37));
  const total = pieces.reduce((sum, piece) => sum + piece.length, 0);
  const whole = (list) => {
    const bytes = new Uint8Array(list.reduce((sum, piece) => sum + piece.length, 0));
    let at = 0;
    for (const piece of list) { bytes.set(piece, at); at += piece.length; }
    return bytes;
  };
  const bytes = whole(pieces);
  assert.equal(bytes.length, total);
  assert.deepEqual([...tidyGame(bytes)], ['minimap', 'ads', 'chat']);
  let at = 100;
  for (const patch of patches) {
    assert.deepEqual([...bytes.subarray(at + patch.at, at + patch.at + patch.put.length)], [...patch.put], patch.name);
    at += patch.find.length + 37;
  }
  // Without the chat's second method: the chat stays as it is, the others go in.
  const noChat = whole(pieces.filter((piece) => piece !== named('ChatGadget.OnLoad').find));
  assert.deepEqual([...tidyGame(noChat)], ['minimap', 'ads']);
  // A patch found twice (another movie): its group stays as it is.
  const twice = whole([...pieces, named('BannerGadget.PageChanged').find]);
  assert.deepEqual([...tidyGame(twice)], ['minimap', 'chat']);
});
