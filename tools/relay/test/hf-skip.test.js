// SPDX-License-Identifier: MIT
//
// dist/pages/hero-fighter.js's change to Hero Fighter's frame loop (skipDrawing): the bytes it finds, what it puts
// in their place for each mode, and that the new bytes are the instructions they are meant to be, branches landing
// where the original's did. hero-fighter.js is a browser script; here it runs in a context with a stand-in window.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'dist', 'pages', 'hero-fighter.js'), 'utf8');
const context = vm.createContext({ window: {}, TextEncoder, Uint8Array, console });
vm.runInContext(source, context);
const { skipDrawing } = context.window.HeroFighter;

// Console.UpdateScreen, offsets 629-684 of its code in Hero Fighter v0.7+ (the movie in HFv0.7+.exe).
const ORIGINAL = Uint8Array.from([
  0xd0, 0x66, 0xd2, 0x17, 0xd0, 0x66, 0xa9, 0x0d, 0x10, 0x00, 0x00, 0x00,
  0xa1, 0xd0, 0x66, 0xcd, 0x5c, 0xaf, 0x2a, 0x11, 0x09, 0x00, 0x00,
  0x29, 0xd0, 0x66, 0xb3, 0x11, 0x25, 0xfa, 0x01, 0xaf,
  0x12, 0x0e, 0x00, 0x00,
  0xd0, 0x10, 0x00, 0x00, 0x00, 0x24, 0x00, 0x68, 0xbb, 0x2b,
  0x10, 0x06, 0x00, 0x00,
  0xd0, 0x24, 0x00, 0x68, 0xbb, 0x2b,
]);
// The multinames they use (from the movie's constant pool; World.Run reads Global.lastRunDur the same way).
const NAMES = { 3: 'Global', 1705: 'nextT', 2227: 'fasterF2', 3026: 'T', 3871: 'lastRunDur', 4416: 'lastDrawDur', 5563: 'skipI', 11853: 'fDurSkip' };

// The AVM2 instructions in bytes, as [offset, text]; branches with the offset they go to.
function disassemble(bytes) {
  const out = [];
  let at = 0;
  const u30 = () => {
    let value = 0;
    for (let shift = 0; ; shift += 7) {
      const byte = bytes[at++];
      value |= (byte & 0x7f) << shift;
      if (!(byte & 0x80)) return value;
    }
  };
  const s24 = () => { const value = (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16)) << 8 >> 8; at += 3; return value; };
  const simple = { 0x02: 'nop', 0x29: 'pop', 0x2a: 'dup', 0x96: 'not', 0xa0: 'add', 0xa1: 'subtract', 0xa8: 'bitand', 0xaf: 'greaterthan', 0xd0: 'getlocal0' };
  const named = { 0x60: 'getlex', 0x66: 'getproperty', 0x68: 'initproperty' };
  const branches = { 0x10: 'jump', 0x11: 'iftrue', 0x12: 'iffalse' };
  while (at < bytes.length) {
    const start = at;
    const op = bytes[at++];
    if (simple[op]) out.push([start, simple[op]]);
    else if (named[op]) out.push([start, `${named[op]} ${NAMES[u30()] || '?'}`]);
    else if (branches[op]) { const offset = s24(); out.push([start, `${branches[op]} ${at + offset}`]); }
    else if (op === 0x24) out.push([start, `pushbyte ${bytes[at++]}`]);
    else if (op === 0x25) out.push([start, `pushshort ${u30()}`]);
    else throw new Error(`opcode ${op.toString(16)} at ${start}`);
  }
  return out;
}

function movie(...pieces) {
  const parts = pieces.map((piece) => (typeof piece === 'number' ? new Uint8Array(piece).fill(0xd0) : piece));
  const bytes = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let at = 0;
  for (const part of parts) { bytes.set(part, at); at += part.length; }
  return bytes;
}

test('the original bytes are the frame loop that always draws', () => {
  assert.deepEqual(disassemble(ORIGINAL).map(([, text]) => text), [
    'getlocal0', 'getproperty T', 'getlocal0', 'getproperty nextT', 'jump 12', 'subtract', 'getlocal0', 'getproperty fDurSkip',
    'greaterthan', 'dup', 'iftrue 32', 'pop', 'getlocal0', 'getproperty fasterF2', 'pushshort 250', 'greaterthan', 'iffalse 50',
    'getlocal0', 'jump 41', 'pushbyte 0', 'initproperty skipI', 'jump 56',
    'getlocal0', 'pushbyte 0', 'initproperty skipI',
  ]);
});

test('auto: a computer behind and slow draws every other frame, in as many bytes', () => {
  const bytes = movie(1000, ORIGINAL, 500);
  assert.equal(skipDrawing(bytes, 'auto'), true);
  assert.deepEqual(bytes.subarray(0, 1000), new Uint8Array(1000).fill(0xd0));
  assert.deepEqual(bytes.subarray(1000 + ORIGINAL.length), new Uint8Array(500).fill(0xd0));
  const code = disassemble(bytes.subarray(1000, 1000 + ORIGINAL.length));
  assert.deepEqual(code.map(([, text]) => text), [
    'getlocal0', 'getproperty T', 'getlocal0', 'getproperty nextT', 'subtract', 'getlocal0', 'getproperty fDurSkip', 'greaterthan',
    'getlex Global', 'getproperty lastRunDur', 'getlex Global', 'getproperty lastDrawDur', 'add', 'pushbyte 33', 'greaterthan',
    'bitand', 'nop', 'nop', 'nop', 'iffalse 50',
    'getlocal0', 'getlocal0', 'getproperty skipI', 'not', 'initproperty skipI', 'nop', 'jump 56',
    'getlocal0', 'pushbyte 0', 'initproperty skipI',
  ]);
  // The branches and the code after them where the original's were: the iffalse at 32 to the else branch at 50,
  // the jump at 46 past it to 56, the else branch itself as it was.
  const at = new Map(code.map(([offset, text]) => [offset, text]));
  assert.equal(at.get(32), 'iffalse 50');
  assert.equal(at.get(46), 'jump 56');
  assert.equal(at.get(50), 'getlocal0');
  assert.deepEqual(bytes.subarray(1000 + 32, 1000 + 36), ORIGINAL.subarray(32, 36));
  assert.deepEqual(bytes.subarray(1000 + 46, 1000 + 56), ORIGINAL.subarray(46, 56));
});

test('all: never draws a fight; off, another movie or two such loops: left as it is', () => {
  const all = movie(10, ORIGINAL, 10);
  assert.equal(skipDrawing(all, 'all'), true);
  const code = disassemble(all.subarray(10, 10 + ORIGINAL.length)).map(([, text]) => text);
  assert.deepEqual(code.filter((text) => text.startsWith('pushbyte')), ['pushbyte 1', 'pushbyte 1']);
  for (const [bytes, mode] of [[movie(10, ORIGINAL, 10), 'off'], [movie(300), 'auto'], [movie(10, ORIGINAL, 7, ORIGINAL, 10), 'auto']]) {
    const before = Uint8Array.from(bytes);
    assert.equal(skipDrawing(bytes, mode), false);
    assert.deepEqual(bytes, before);
  }
});
