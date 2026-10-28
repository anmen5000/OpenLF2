// SPDX-License-Identifier: MIT
//
// End-to-end check of the browser side (dist/web/online.js) through the relay, driven exactly the
// way OpenLF2 drives a network transport: the C++ adapter's poll/send/status semantics and a line
// by line port of scripts/base/game/network.lua (handshake, random table, lockstep 22-byte packets).
// Uses Node's built-in WebSocket client, the same API browsers have.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  OnlineTransport, STATUS, sleep, startRelay, engineNetwork, peer, until, randomInput, playFrames,
} = require('./helpers.js');

test('two browsers complete the OpenLF2 handshake and stay in lockstep through the relay', async (t) => {
  const relay = await startRelay();
  try {
    const host = peer(relay.url, '482913', ['Alice', 'Bob', 'Carol', 'Dan']);
    const guest = peer(relay.url, '999999', ['Linh', 'Minh', 'Nam', 'Quan']);
    assert.equal(host.network.start(true, '0.0.0.0'), true);
    assert.equal(host.online.status(), STATUS.listening);
    // The guest types the host's room code into the address field.
    assert.equal(guest.network.start(false, '482913'), true);
    assert.equal(guest.online.status(), STATUS.connecting);

    await until(() => {
      for (const side of [host, guest]) {
        const result = side.network.poll();
        if (result && result.error) throw new Error(result.error);
      }
      return host.network.phase === 'ready' && guest.network.phase === 'ready';
    });
    assert.ok(host.network.sharedRandom.equals(guest.network.sharedRandom), 'random tables match');
    assert.deepEqual(host.network.peerNames, ['Linh', 'Minh', 'Nam', 'Quan']);
    assert.deepEqual(guest.network.peerNames, ['Alice', 'Bob', 'Carol', 'Dan']);

    const hostLog = [];
    const guestLog = [];
    const started = Date.now();
    await Promise.all([playFrames(host, 300, hostLog), playFrames(guest, 300, guestLog)]);
    const elapsed = Date.now() - started;
    assert.equal(host.network.frames, 300);
    assert.deepEqual(hostLog, guestLog, 'both players see identical inputs every frame');
    t.diagnostic(`300 lockstep frames over the local relay in ${elapsed} ms`);

    // The guest leaves: the host's next frame reports it, in the game's message font's ASCII.
    guest.network.engine.close();
    const outcome = await until(() => host.network.exchange(randomInput(), 42));
    assert.deepEqual(outcome, { error: 'Relay: the other player left' });
    assert.equal(host.online.status(), STATUS.idle);
  } finally { await relay.close(); }
});

// The game advances one frame per 33 ms and, in network play, only once the other player's
// packet for that frame has arrived. So the speed drops once the time a packet needs from one
// player to the other (both legs through the relay) exceeds 33 ms.
test('frame rate against the one-way delay between the players', async (t) => {
  const results = [];
  for (const delay of [0, 20, 50, 80]) {
    const relay = await startRelay({ forwardDelayMs: delay });
    try {
      const host = peer(relay.url, '246810', ['A', '', '', '']);
      const guest = peer(relay.url, '246810', ['B', '', '', '']);
      host.network.start(true, '0.0.0.0');
      guest.network.start(false, '');
      await until(() => {
        host.network.poll();
        guest.network.poll();
        return host.network.phase === 'ready' && guest.network.phase === 'ready';
      });
      const frames = 45;
      const started = Date.now();
      const paced = async (side) => {
        for (let frame = 0; frame < frames; frame += 1) {
          while (Date.now() < started + (frame * 1000) / 30) await sleep(1); // the 33 ms frame clock
          const input = randomInput();
          await until(() => {
            const result = side.network.exchange(input, 7);
            if (result && result.error) throw new Error(result.error);
            return result;
          });
        }
      };
      await Promise.all([paced(host), paced(guest)]);
      const fps = ((frames - 1) * 1000) / (Date.now() - started); // frame 0 starts at once
      results.push([delay, fps]);
      t.diagnostic(`one-way delay ${delay} ms -> ${fps.toFixed(1)} frames per second (game speed ${Math.round((fps / 30) * 100)}%)`);
      host.online.close();
      guest.online.close();
    } finally { await relay.close(); }
  }
  assert.ok(results[0][1] > 25, 'no delay plays at full speed');
  assert.ok(results[1][1] > 25, '20 ms is still full speed');
  assert.ok(results[3][1] < 15, '80 ms slows the game down');
});

test('Connect with an empty address joins the room from the invite link', async () => {
  const relay = await startRelay();
  try {
    const host = peer(relay.url, '135790', ['A', '', '', '']);
    const guest = peer(relay.url, '135790', ['B', '', '', '']); // opened the invite link
    host.network.start(true, '0.0.0.0');
    guest.network.start(false, '');
    await until(() => {
      host.network.poll();
      guest.network.poll();
      return host.network.phase === 'ready' && guest.network.phase === 'ready';
    });
    host.online.close();
    guest.online.close();
  } finally { await relay.close(); }
});

test('problems the player can fix are reported before anything is sent', () => {
  const online = new OnlineTransport({ relay: 'ws://127.0.0.1:9/relay', room: '123456', WebSocket: globalThis.WebSocket });
  assert.equal(online.start(false, '192.168.1.20'), false);
  assert.equal(online.error(), 'Network: type the room code, not an IP address');
  assert.equal(online.start(false, '12'), false);
  assert.equal(online.error(), 'Network: type the room code (4-12 digits)');
  assert.equal(online.send(new Uint8Array([1])), false);
  assert.equal(online.error(), 'Network: type the room code (4-12 digits)'); // the earlier failure stays first
  online.close();
  assert.equal(online.send(new Uint8Array([1])), false);
  assert.equal(online.error(), 'Network peer is not connected');

  const noRelay = new OnlineTransport({ room: '123456', WebSocket: globalThis.WebSocket });
  assert.equal(noRelay.start(true), false);
  assert.equal(noRelay.error(), 'Network: set the relay address above the game');

  const insecure = new OnlineTransport({ relay: 'ws://relay.example.com/relay', room: '123456', pageProtocol: 'https:', WebSocket: globalThis.WebSocket });
  assert.equal(insecure.start(true), false);
  assert.equal(insecure.error(), 'Network: this https page needs a wss:// relay address');

  const noRoom = new OnlineTransport({ relay: 'wss://relay.example.com/relay', WebSocket: globalThis.WebSocket });
  assert.equal(noRoom.start(true), false);
  assert.equal(noRoom.error(), 'Network: set a room code (4-12 digits) above the game');
});

test('relay addresses are accepted the way people paste them', () => {
  const online = new OnlineTransport({ WebSocket: globalThis.WebSocket });
  const cases = [
    ['wss://203-0-113-5.sslip.io/relay', 'wss://203-0-113-5.sslip.io/relay'],
    ['  https://203-0-113-5.sslip.io  ', 'wss://203-0-113-5.sslip.io'],
    ['HTTPS://relay.example.com/relay', 'wss://relay.example.com/relay'],
    ['http://192.168.1.10:8787/relay', 'ws://192.168.1.10:8787/relay'],
    ['203-0-113-5.sslip.io', 'wss://203-0-113-5.sslip.io'],
    ['ws://localhost:8787/relay', 'ws://localhost:8787/relay'],
    ['', ''],
  ];
  for (const [typed, expected] of cases) {
    online.setRelay(typed);
    assert.equal(online.relay, expected, typed);
  }
});

test('an https relay address pasted into the panel reaches the relay', async () => {
  const relay = await startRelay();
  try {
    const port = new URL(relay.url).port;
    // The relay serves WebSockets on "/" too, so an address without /relay works.
    const host = peer(`http://127.0.0.1:${port}`, '555123', ['A', '', '', '']);
    const guest = peer(`http://127.0.0.1:${port}/relay`, '555123', ['B', '', '', '']);
    assert.equal(host.online.relay, `ws://127.0.0.1:${port}`);
    host.network.start(true, '0.0.0.0');
    guest.network.start(false, '');
    await until(() => {
      host.network.poll();
      guest.network.poll();
      return host.network.phase === 'ready' && guest.network.phase === 'ready';
    });
    host.online.close();
    guest.online.close();
  } finally { await relay.close(); }
});

test('an unreachable relay is reported through poll', async () => {
  const online = new OnlineTransport({ relay: 'ws://127.0.0.1:9/relay', room: '123456', WebSocket: globalThis.WebSocket });
  const engine = engineNetwork(online);
  assert.equal(engine.host(), null);
  const result = await until(() => {
    const polled = engine.poll();
    return polled.error ? polled : null;
  });
  assert.equal(result.error, 'Network: cannot reach the relay');
  assert.equal(online.status(), STATUS.idle);
});

test('received bytes are handed out in order across chunk boundaries and capacity limits', () => {
  const online = new OnlineTransport({});
  const socket = {};
  online.socket = socket;
  online.state = STATUS.connected;
  const parts = [Buffer.from([1, 2, 3]), Buffer.from([4]), Buffer.from([5, 6, 7, 8, 9])];
  for (const part of parts) online.onMessage(socket, { data: part.buffer.slice(part.byteOffset, part.byteOffset + part.length) });
  assert.equal(online.available(), 9);
  assert.deepEqual([...online.take(2)], [1, 2]);
  assert.deepEqual([...online.take(3)], [3, 4, 5]);
  online.onClose(socket, { code: 4006, reason: '' });
  assert.equal(online.available(), 4, 'bytes that arrived before the close are still delivered');
  assert.deepEqual([...online.take(100)], [6, 7, 8, 9]);
  assert.equal(online.available(), -1);
  assert.equal(online.error(), 'Relay: the other player left');
});
