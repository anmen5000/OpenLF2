// SPDX-License-Identifier: MIT
//
// Shared by the end-to-end tests: a relay on a free port, and a line-by-line port of
// scripts/base/game/network.lua (handshake, random table, lockstep 22-byte packets) that drives
// a network transport the way the game does.
'use strict';

const crypto = require('node:crypto');
const path = require('node:path');
const { createRelay } = require('../server.js');

// tools/relay/test -> the repository root
const repository = path.join(__dirname, '..', '..', '..');
const onlinePath = process.env.OPENLF2_ONLINE_JS || path.join(repository, 'dist', 'web', 'online.js');
const transportPath = process.env.OPENLF2_TRANSPORT_CPP
  || path.join(repository, 'src', 'adapters', 'web', 'transport.cpp');
const { OnlineTransport, STATUS } = require(onlinePath);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function startRelay(overrides = {}) {
  const relay = createRelay({ quiet: true, ...overrides });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}/relay`;
  return relay;
}

// What src/adapters/web/transport.cpp does with online.js, as seen by the Lua scripts.
function engineNetwork(online) {
  return {
    host: () => (online.start(true, '0.0.0.0') ? null : online.error()),
    join: (address) => (online.start(false, address) ? null : online.error()),
    send: (bytes) => (online.send(bytes) ? null : online.error()),
    poll: () => {
      const available = online.available();
      if (available < 0) {
        const message = online.error();
        online.close();
        return { error: message };
      }
      return { bytes: Buffer.from(online.take(Math.min(available, 8192))) };
    },
    status: () => ['idle', 'listening', 'connecting', 'connected'][online.status()],
    close: () => online.close(),
  };
}

// scripts/base/game/network.lua, ported with the same byte layout and checks.
const FUNCTION_BITS = [[10, 2], [10, 64], [12, 2], [10, 4], [10, 8], [10, 16], [10, 32], [12, 4], [10, 128]];
class LuaNetwork {
  constructor(engine, { profile, version, names, randomTable, checksum }) {
    this.engine = engine;
    this.phase = 'idle';
    this.received = Buffer.alloc(0);
    this.sequence = 0;
    this.frames = 0;
    this.version = version;
    this.profile = Buffer.from('OpenLF2 TCP 1\n' + profile, 'latin1');
    this.ownNames = names;
    this.randomTable = randomTable;
    this.dataChecksum = checksum;
  }
  failed(message) {
    this.engine.close();
    this.phase = 'failed';
    this.error = message;
    return { error: message };
  }
  send(bytes) {
    const problem = this.engine.send(bytes);
    if (problem) { this.failed(problem); return false; }
    return true;
  }
  take(count) {
    if (this.received.length < count) return null;
    const bytes = Buffer.from(this.received.subarray(0, count));
    this.received = this.received.subarray(count);
    return bytes;
  }
  namesPacket(host) {
    const fields = [host ? '11110000' : '00001111', '0'.repeat(24)];
    for (const name of this.ownNames) fields.push(name.slice(0, 10) + '_'.repeat(11 - Math.min(10, name.length)));
    return Buffer.from(fields.join('') + '\0', 'latin1');
  }
  readNames(bytes) {
    const expected = this.host ? '00001111' : '11110000';
    if (bytes.subarray(0, 8).toString('latin1') !== expected || bytes[76] !== 0) {
      return this.failed('Invalid network player assignment');
    }
    this.peerNames = [];
    for (let index = 0; index < 4; index += 1) {
      const field = bytes.subarray(32 + index * 11, 43 + index * 11).toString('latin1');
      this.peerNames.push(field.match(/^[^_\0]*/)[0]);
    }
    return true;
  }
  start(host, address) {
    this.engine.close();
    this.host = host;
    this.error = undefined;
    this.received = Buffer.alloc(0);
    this.pending = null;
    this.sequence = 0;
    this.frames = 0;
    const problem = host ? this.engine.host() : this.engine.join(address);
    if (problem) return this.failed(problem);
    this.phase = 'connecting';
    this.deadline = Date.now() + 30000;
    return true;
  }
  poll() {
    if (this.phase === 'failed') return { error: this.error };
    const result = this.engine.poll();
    if (result.error) return this.failed(result.error);
    this.received = Buffer.concat([this.received, result.bytes]);
    if (this.received.length > 8192) return this.failed('Network receive buffer exceeded');
    if (this.phase !== 'ready' && Date.now() > this.deadline) return this.failed('Network connection timed out');
    if (this.phase === 'connecting' && this.engine.status() === 'connected') {
      if (!this.send(this.profile)) return { error: this.error };
      this.phase = 'profile';
    }
    if (this.phase === 'profile') {
      const profile = this.take(this.profile.length);
      if (!profile) return false;
      if (!profile.equals(this.profile)) return this.failed('Network engine/scripts/mod profile mismatch');
      this.checksum = this.dataChecksum % 65536;
      if (this.host) {
        if (!this.send(Buffer.from('u can connect\0', 'latin1'))) return { error: this.error };
        this.phase = 'players';
      } else this.phase = 'greeting';
    }
    if (this.phase === 'greeting') {
      const greeting = this.take(14);
      if (!greeting) return false;
      if (greeting.toString('latin1') !== 'u can connect\0') return this.failed('Invalid network greeting');
      if (!this.send(this.namesPacket(false))) return { error: this.error };
      this.phase = 'players';
    }
    if (this.phase === 'players') {
      const players = this.take(77);
      if (!players) return false;
      const read = this.readNames(players);
      if (read !== true) return read;
      if (this.host) {
        if (!this.send(Buffer.concat([this.namesPacket(true), this.randomTable, Buffer.from([0])]))) return { error: this.error };
        this.sharedRandom = this.randomTable;
        this.phase = 'ready';
      } else this.phase = 'random';
    }
    if (this.phase === 'random') {
      const table = this.take(3001);
      if (!table) return false;
      if (table[3000] !== 0 || table.subarray(0, 3000).includes(0)) return this.failed('Invalid network random table');
      this.sharedRandom = Buffer.from(table.subarray(0, 3000));
      this.phase = 'ready';
    }
    return this.phase === 'ready';
  }
  packet(input, hp) {
    const bytes = new Array(22).fill(1);
    bytes[20] = 0;
    bytes[21] = 0;
    for (let index = 0; index < 4; index += 1) bytes[(this.host ? 0 : 4) + index] = input.keys[index] + 1;
    bytes[9] = this.sequence;
    bytes[11] = this.version;
    bytes[13] = (hp % 100) + 1;
    bytes[14] = this.checksum % 256;
    bytes[15] = Math.floor(this.checksum / 256);
    FUNCTION_BITS.forEach(([field, bit], index) => {
      if (input.functions.includes(String(index + 1))) bytes[field] += bit;
    });
    return Buffer.from(bytes);
  }
  // Returns the combined input of all eight slots, null while waiting, or { error }.
  exchange(input, hp) {
    if (!this.pending) {
      this.sequence = (this.sequence + 1) % 50;
      this.pending = this.packet(input, hp);
      this.deadline = Date.now() + 30000;
      if (!this.send(this.pending)) return { error: this.error };
    }
    const ok = this.poll();
    if (ok && ok.error) return ok;
    if (!ok) return null;
    const remote = this.take(22);
    if (!remote) {
      if (Date.now() > this.deadline) return this.failed('Network input timed out');
      return null;
    }
    const own = this.pending;
    for (const [index, what] of [[9, 'sequence'], [11, 'version'], [13, 'HP synchronization'], [14, 'data'], [15, 'data']]) {
      if (remote[index] !== own[index]) return this.failed(`Network ${what} mismatch`);
    }
    for (let index = 0; index < 8; index += 1) {
      const peerSlot = this.host ? index >= 4 : index < 4;
      if (remote[index] % 2 !== 1 || (!peerSlot && remote[index] !== 1)) return this.failed('Invalid network input slot');
    }
    if (remote[10] % 2 !== 1 || remote[12] % 2 !== 1 || remote[12] > 31 || remote[8] !== 1
      || !remote.subarray(16).equals(Buffer.from([1, 1, 1, 1, 0, 0]))) {
      return this.failed('Invalid network packet padding');
    }
    const combined = { slots: [], functions: '' };
    for (let slot = 0; slot < 8; slot += 1) {
      const localSlot = this.host ? slot < 4 : slot >= 4;
      combined.slots.push((localSlot ? own : remote)[slot]);
    }
    FUNCTION_BITS.forEach(([field, bit], index) => {
      if (Math.floor(own[field] / bit) % 2 === 1 || Math.floor(remote[field] / bit) % 2 === 1) combined.functions += String(index + 1);
    });
    this.pending = null;
    this.frames += 1;
    return combined;
  }
}

// One player: an online.js instance (one per browser page) and the game's network script over it.
// `makeEngine` turns the online.js instance into what the scripts call (engine.network).
function peer(relayUrl, room, names, { makeEngine = engineNetwork, online } = {}) {
  const transport = online || new OnlineTransport({ relay: relayUrl, room, WebSocket: globalThis.WebSocket });
  const random = crypto.randomBytes(3000).map((value) => value || 1); // the table never holds a 0 byte
  const network = new LuaNetwork(makeEngine(transport), {
    profile: 'a'.repeat(64), version: 7, names, randomTable: Buffer.from(random), checksum: 0xbeef,
  });
  return { online: transport, network };
}

async function until(fn, timeout = 10000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const result = fn();
    if (result) return result;
    if (Date.now() > deadline) throw new Error('timed out');
    await sleep(1); // as emscripten_sleep(1) in the game loop: lets socket events in
  }
}

function randomInput() {
  const keys = Array.from({ length: 4 }, () => crypto.randomInt(128) * 2); // pack_keys values are even
  const functions = [...'123456789'].filter(() => crypto.randomInt(20) === 0).join('');
  return { keys, functions };
}

async function playFrames(side, frames, log) {
  for (let frame = 0; frame < frames; frame += 1) {
    const input = randomInput();
    const combined = await until(() => {
      const result = side.network.exchange(input, 42);
      if (result && result.error) throw new Error(result.error);
      return result;
    });
    log.push(JSON.stringify(combined));
  }
}

module.exports = {
  OnlineTransport, STATUS, transportPath, sleep, startRelay, engineNetwork, LuaNetwork, peer, until, randomInput, playFrames,
};
