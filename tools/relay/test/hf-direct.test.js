// SPDX-License-Identifier: MIT
//
// Hero Fighter rooms with direct links between the pages (dist/pages/hf-direct.js and the relay's side in
// hf-room.js): the game gets every other game's frame once and in order, from whichever way brings it
// first, never one of another fight, and player 2's hire number in a form the game reads.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const WebSocket = require('ws');
const { createRelay } = require('../server.js');
const room = require('../hf-room.js');
const direct = require(path.join(__dirname, '../../../dist/pages/hf-direct.js'));
const { fakeWebRtc } = require('./fake-webrtc.js');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('player 2\'s hire number: the relay and the page put it where the game reads it, the same way', () => {
  const samples = [
    ['<f><c>0</c><i>3164</i><s1>@</s1><m2>h</m2><n2>2</n2><i2>0</i2></f>',
      '<f><c>0</c><i>3164</i><s1>@</s1><m2>h</m2><n2>2</n2><i2>0</i2><n1>2</n1></f>'],
    ['<f><c>1</c><i>9</i><s1>^</s1><p2>4</p2><s2>a</s2><s3>^</s3><m2>S</m2><n2></n2><i2>3</i2></f>',
      '<f><c>1</c><i>9</i><s1>^</s1><p2>4</p2><s2>a</s2><s3>^</s3><m2>S</m2><n2></n2><i2>3</i2><n1></n1></f>'],
    // Player 1's and player 3's commands are read right: unchanged.
    ['<f><c>0</c><i>5</i><s1>@</s1><m1>h</m1><n1>1</n1><i1>0</i1></f>', null],
    ['<f><c>0</c><i>5</i><s1>@</s1><m3>h</m3><n3>2</n3><i3>0</i3></f>', null],
    ['<f><c>0</c><i>6</i><p1>0</p1><p2>2</p2><p3>0</p3><s1></s1><s2>d</s2><s3></s3></f>', null],
  ];
  for (const [line, fixed] of samples) {
    assert.equal(room.fixCommandNumber(line), fixed || line);
    assert.equal(direct.fixCommandNumber(line), fixed || line);
  }
});

test('the room\'s stream splits into its elements as they complete, CDATA and all', () => {
  const elements = new direct.Elements();
  assert.deepEqual(elements.push('<chat><c>5</c><m><![CDATA[a <f> b </m> ]]></m></ch'), []);
  assert.deepEqual(elements.push('at>\n<f><c>1</c><i>0</i><s1>r</s1></f><f><c>1</c>'),
    ['<chat><c>5</c><m><![CDATA[a <f> b </m> ]]></m></chat>', '\n<f><c>1</c><i>0</i><s1>r</s1></f>']);
  assert.deepEqual(elements.push('<i>1</i><s1>@</s1></f>\n<allstartedgame></allstartedgame>\n<x/>'),
    ['<f><c>1</c><i>1</i><s1>@</s1></f>', '\n<allstartedgame></allstartedgame>', '\n<x/>']);
  assert.equal(elements.push('stray text'), null);
});

test('merging: each frame once, in order, from whichever way first; none before its fight or of another', () => {
  const given = [];
  const merger = new direct.Merger((text) => given.push(text));
  const ended = [];
  merger.onEnd = (counts) => ended.push({ ...counts });
  const frames = () => given.join('').match(/<f>.*?<\/f>/g) || [];
  const frame = (cid, k, keys = '<s1>@</s1>') => `<f><c>${cid}</c><i>${k}</i>${keys}</f>`;

  merger.fromRelay('<status><mode>VSMODE</mode><page>FIGHTING</page><prepage>GAMESETTINGMENU</prepage><storyi>0</storyi></status>\n');
  merger.announce(1, true);
  // A frame of the coming fight from a page that began it sooner: kept until the fight begins here.
  merger.fromPeer(1, 1, [frame(1, 0, '<s1>r</s1>')]);
  assert.deepEqual(frames(), []);
  merger.fromRelay('<allstartedgame></allstartedgame>\n');
  assert.match(given.join(''), /<allstartedgame><\/allstartedgame>\n?<f><c>1<\/c><i>0<\/i>/);
  // The relay's copies of frames that came directly are dropped; the next one is taken from the relay.
  merger.fromRelay(frame(1, 0, '<s1>r</s1>') + frame(1, 1) + '\n');
  merger.fromPeer(1, 1, [frame(1, 1), frame(1, 2)]);
  // A frame after a missing one waits for it.
  merger.fromPeer(1, 1, [frame(1, 4)]);
  assert.deepEqual(frames().map((f) => /<i>(\d+)/.exec(f)[1]), ['0', '1', '2']);
  merger.fromRelay(frame(1, 3));
  assert.deepEqual(frames().map((f) => /<i>(\d+)/.exec(f)[1]), ['0', '1', '2', '3', '4']);
  // Frames of another fight, or that say they are another computer's than their link's, are not taken.
  merger.fromPeer(1, 0, [frame(1, 5)]);
  merger.fromPeer(2, 1, [frame(1, 5)]);
  merger.fromPeer(1, 2, [frame(1, 5)]);
  assert.equal(frames().length, 5);
  // Player 2's hire number, both ways.
  merger.fromPeer(1, 1, [frame(1, 5, '<s1>@</s1><m2>h</m2><n2>2</n2><i2>0</i2>')]);
  merger.fromRelay(frame(0, 0, '<s1>@</s1><m2>h</m2><n2>1</n2><i2>0</i2>'));
  assert.match(frames()[5], /<n1>2<\/n1>/);
  assert.match(frames()[6], /<n1>1<\/n1>/);
  assert.deepEqual(merger.counts, { direct: 4, relay: 3 });
  // Back to the menus: the fight is over (and its counts told); its late frames are not taken.
  merger.fromRelay('<status><mode>VSMODE</mode><page>CHARMENU</page><prepage>FIGHTING</prepage><storyi>0</storyi></status>\n');
  assert.deepEqual(ended, [{ direct: 4, relay: 3 }]);
  merger.fromPeer(1, 1, [frame(1, 6)]);
  assert.equal(frames().length, 7);
  // The next fight: the frame of fight 2 that came early follows its <allstartedgame>; numbers start again.
  merger.announce(2, true);
  merger.fromRelay('<allstartedgame></allstartedgame>');
  assert.match(given.join(''), /<allstartedgame><\/allstartedgame>\n?<f><c>1<\/c><i>5<\/i>/.source ? /<allstartedgame><\/allstartedgame>$/ : /x/);
  merger.fromPeer(1, 2, [frame(1, 0, '<s1>l</s1>')]);
  assert.match(frames().at(-1), /<i>0<\/i><s1>l<\/s1>/);
  // A page that is not in the fight takes no frames directly.
  const watcher = new direct.Merger(() => {});
  watcher.announce(3, false);
  watcher.fromRelay('<allstartedgame></allstartedgame>');
  watcher.fromPeer(1, 3, [frame(1, 0)]);
  assert.equal(watcher.fight, null);
});

// A page: its DirectSocket (as Ruffle would use it) and a stand-in for the game behind it.
class Page {
  constructor(relay, name, RTCPeerConnection, roomNumber = 1) {
    this.name = name;
    this.lines = [];
    this.frames = new Map(); // computer -> frames the game got, in order
    this.status = '';
    this.elements = new direct.Elements();
    const win = { RTCPeerConnection, TextEncoder, TextDecoder, Event, MessageEvent, Blob, EventTarget };
    this.socket = new direct.DirectSocket(`${relay.url}?game=hf&room=${roomNumber}&build=t&direct=1`, win, {
      NativeWebSocket: WebSocket, status: (text) => { this.status = text; } });
    this.socket.binaryType = 'arraybuffer';
    this.opened = new Promise((resolve) => this.socket.addEventListener('open', resolve, { once: true }));
    this.closed = new Promise((resolve) => this.socket.addEventListener('close', resolve, { once: true }));
    const decoder = new TextDecoder();
    this.socket.addEventListener('message', (event) => {
      assert.ok(event.data instanceof ArrayBuffer);
      for (const element of this.elements.push(decoder.decode(new Uint8Array(event.data), { stream: true }))) {
        const body = element.trim();
        const id = /^<f><c>(\d+)<\/c><i>(\d+)<\/i>/.exec(body);
        if (id) {
          if (!this.frames.has(Number(id[1]))) this.frames.set(Number(id[1]), []);
          this.frames.get(Number(id[1])).push({ k: Number(id[2]), body });
          continue;
        }
        this.lines.push(body);
        if (body === '<ping></ping>') this.send('<pingok></pingok>');
        else if (body === '<ini></ini>') this.send('<join><ver>700</ver></join>');
        else if (body === '<req_info></req_info>') {
          let info = `<info><name><![CDATA[${name}]]></name><cc>VN</cc>`;
          for (let k = 1; k <= 3; k += 1) info += `<p><![CDATA[${name} P${k}]]></p>`;
          for (let k = 0; k < 30; k += 1) info += `<l>${k < 20 ? 16 : 0}</l>`;
          this.send(info + '</info>');
        }
      }
    });
  }
  // As Ruffle does: a Blob of the bytes.
  send(text) { this.socket.send(new Blob([text + '\n'])); }
  async waitFor(test, what, ms = 15000) {
    const until = Date.now() + ms;
    for (let from = this.mark || 0; Date.now() < until; await sleep(10)) {
      const index = this.lines.findIndex((line, k) => k >= from && test(line));
      if (index >= 0) { this.mark = index + 1; return this.lines[index]; }
    }
    throw new Error(`${this.name}: no ${what}`);
  }
}

async function intoFight(a, b) {
  a.send('<startcount><action>clickvs</action><page>WAITROOM</page><zero>false</zero></startcount>');
  for (const page of [a, b]) await page.waitFor((line) => line.includes('<page>CHARMENU</page><prepage>WAITROOM'), 'character menu');
  for (const page of [a, b]) page.send('<page>CHARMENU</page>');
  a.send('<addplayer>1</addplayer>'); // player 2, as with W A S D
  b.send('<addplayer>0</addplayer>');
  await sleep(200);
  a.send('<startcount><action>clicknext</action><page>CHARMENU</page><zero>false</zero></startcount>');
  for (const page of [a, b]) await page.waitFor((line) => line.includes('<page>GAMESETTINGMENU</page><prepage>CHARMENU'), 'game settings');
  for (const page of [a, b]) page.send('<page>GAMESETTINGMENU</page>');
  await sleep(100);
  b.send('<startcount><action>clickfight</action><page>GAMESETTINGMENU</page><zero>false</zero></startcount>');
  for (const page of [a, b]) await page.waitFor((line) => line.includes('<page>FIGHTING</page><prepage>GAMESETTINGMENU'), 'fight');
  for (const page of [a, b]) page.send('<page>FIGHTING</page>');
  for (const page of [a, b]) page.send('<startedgame>FIGHTING</startedgame>');
  for (const page of [a, b]) await page.waitFor((line) => line === '<allstartedgame></allstartedgame>', 'all started');
}

// Both games play `count` frames, two a packet, a packet every `every` ms; a's player 2 hires a hero at 51.
async function play(a, b, count, every = 5) {
  for (let k = 0; k < count; k += 2) {
    for (const [page, cid] of [[a, 0], [b, 1]]) {
      const keys = (frame) => (cid === 0 && frame === 51 ? '<s1>@</s1><m2>h</m2><n2>2</n2><i2>0</i2>' : `<p1>${frame % 7}</p1><s1></s1>`);
      page.send(`<f><c>${cid}</c><i>${k}</i>${keys(k)}</f>\n<f><c>${cid}</c><i>${k + 1}</i>${keys(k + 1)}</f>\n<pk></pk>`);
    }
    await sleep(every);
  }
}

async function gotAll(page, cid, count) {
  const until = Date.now() + 10000;
  while (Date.now() < until && (page.frames.get(cid) || []).length < count) await sleep(20);
  const got = page.frames.get(cid) || [];
  assert.deepEqual(got.map((frame) => frame.k), Array.from({ length: count }, (_, k) => k), `${page.name}: frames of ${cid}`);
  return got;
}

test('two pages in a room pass each other\'s frames directly; the game gets each once, in order', { timeout: 60000 }, async () => {
  const relay = createRelay({ quiet: true, adminKey: 'k' });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}/relay`;
  const http = `http://127.0.0.1:${address.port}`;
  const rtc = fakeWebRtc();
  const pages = [];
  try {
    const a = new Page(relay, 'anmen', rtc);
    pages.push(a);
    await a.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    const b = new Page(relay, 'banbe', rtc);
    pages.push(b);
    await b.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    // The pages link up as soon as both are in the room.
    for (let k = 0; k < 100 && !(/banbe \d+ ms/.test(a.status) && /anmen \d+ ms/.test(b.status)); k += 1) await sleep(20);
    assert.match(a.status, /^direct links: banbe \d+ ms$/);
    assert.match(b.status, /^direct links: anmen \d+ ms$/);

    await intoFight(a, b);
    await play(a, b, 200);
    const fromA = await gotAll(b, 0, 200);
    await gotAll(a, 1, 200);
    assert.match(fromA[51].body, /<m2>h<\/m2><n2>2<\/n2><i2>0<\/i2><n1>2<\/n1><\/f>$/);
    assert.ok(a.socket.merger.counts.direct > 0 && b.socket.merger.counts.direct > 0, JSON.stringify([a.socket.merger.counts, b.socket.merger.counts]));
    assert.equal(a.socket.merger.counts.direct + a.socket.merger.counts.relay, 200);

    // Back to the menus: each page tells how its frames came, and says so to its player.
    a.send('<startcount><action>quitgame</action><page>FIGHTING</page><zero>true</zero></startcount>');
    for (const page of [a, b]) await page.waitFor((line) => line.includes('<page>CHARMENU</page><prepage>FIGHTING'), 'menus');
    await sleep(300);
    assert.match(a.status, /last fight: \d+% of frames came directly/);
    const journal = await (await fetch(http + '/admin/api/hf-journal', { headers: { 'x-admin-key': 'k' } })).text();
    assert.match(journal, /anmen joins \(latency \d+, build t, from 127\.0\.0\.1, direct links\)/);
    assert.match(journal, /(anmen: direct link to banbe|banbe: direct link to anmen) \(\d+ ms\)/);
    assert.match(journal, /fight 1: direct links anmen-banbe \d+ ms/);
    assert.match(journal, /anmen: \d+ of the others' frames came directly, \d+ through the relay/);

    // The next fight starts its frames from 0 again, and they still come.
    for (const page of [a, b]) page.send('<page>CHARMENU</page>');
    await sleep(100);
    b.send('<startcount><action>clicknext</action><page>CHARMENU</page><zero>false</zero></startcount>');
    for (const page of [a, b]) await page.waitFor((line) => line.includes('<page>GAMESETTINGMENU</page>'), 'game settings again');
    for (const page of [a, b]) page.send('<page>GAMESETTINGMENU</page>');
    await sleep(100);
    a.send('<startcount><action>clickfight</action><page>GAMESETTINGMENU</page><zero>false</zero></startcount>');
    for (const page of [a, b]) await page.waitFor((line) => line.includes('<page>FIGHTING</page><prepage>GAMESETTINGMENU'), 'second fight');
    for (const page of [a, b]) page.send('<page>FIGHTING</page>');
    for (const page of [a, b]) page.send('<startedgame>FIGHTING</startedgame>');
    for (const page of [a, b]) await page.waitFor((line) => line === '<allstartedgame></allstartedgame>', 'all started again');
    for (const page of [a, b]) page.frames.clear();
    await play(a, b, 40);
    await gotAll(b, 0, 40);
    await gotAll(a, 1, 40);
    assert.equal(a.socket.merger.fight.n, 2);
  } finally {
    for (const page of pages) page.socket.close();
    await relay.close();
  }
});

test('a link that loses packets: each frame still once and in order (datagrams, the reliable channel and the relay)', { timeout: 60000 }, async () => {
  const relay = createRelay({ quiet: true });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}/relay`;
  const rtc = fakeWebRtc({ delay: 1, loss: 0.1, stall: 300, seed: 11 });
  const pages = [];
  try {
    const a = new Page(relay, 'anmen', rtc);
    pages.push(a);
    await a.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    const b = new Page(relay, 'banbe', rtc);
    pages.push(b);
    await b.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    for (let k = 0; k < 100 && !(/banbe \d+ ms/.test(a.status) && /anmen \d+ ms/.test(b.status)); k += 1) await sleep(20);
    await intoFight(a, b);
    await play(a, b, 300, 3);
    const fromA = await gotAll(b, 0, 300);
    await gotAll(a, 1, 300);
    assert.match(fromA[51].body, /<n1>2<\/n1><\/f>$/);
    for (const page of [a, b]) {
      const { direct, relay: relayed } = page.socket.merger.counts;
      assert.equal(direct + relayed, 300);
      assert.ok(direct > 0, `${page.name}: ${direct} frames directly`);
    }
  } finally {
    for (const page of pages) page.socket.close();
    await relay.close();
  }
});

test('when no direct link opens, the frames come through the relay as before', { timeout: 60000 }, async () => {
  const relay = createRelay({ quiet: true });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}/relay`;
  const rtc = fakeWebRtc({ blocked: true });
  const pages = [];
  try {
    const a = new Page(relay, 'anmen', rtc);
    pages.push(a);
    await a.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    const b = new Page(relay, 'banbe', rtc);
    pages.push(b);
    await b.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    await sleep(300);
    assert.match(a.status, /banbe connecting…/);
    await intoFight(a, b);
    await play(a, b, 100, 2);
    const fromA = await gotAll(b, 0, 100);
    await gotAll(a, 1, 100);
    assert.match(fromA[51].body, /<n1>2<\/n1><\/f>$/);
    assert.deepEqual(b.socket.merger.counts, { direct: 0, relay: 100 });
  } finally {
    for (const page of pages) page.socket.close();
    await relay.close();
  }
});

test('a page that cannot make direct links plays with one that can, through the relay', { timeout: 60000 }, async () => {
  const relay = createRelay({ quiet: true });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}/relay`;
  const pages = [];
  const plain = [];
  try {
    const a = new Page(relay, 'anmen', fakeWebRtc());
    pages.push(a);
    await a.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    // b: an older page (no direct=1) on the plain WebSocket.
    const ws = new WebSocket(`${relay.url}?game=hf&room=1&build=t`);
    plain.push(ws);
    const b = { name: 'banbe', lines: [], frames: new Map(), elements: new direct.Elements(), mark: 0 };
    b.send = (text) => ws.send(Buffer.from(text + '\n'), { binary: true });
    b.waitFor = Page.prototype.waitFor;
    ws.on('message', (data, isBinary) => {
      assert.equal(isBinary, true); // the relay says nothing of its own to an older page
      for (const element of b.elements.push(data.toString('utf8'))) {
        const body = element.trim();
        const id = /^<f><c>(\d+)<\/c><i>(\d+)<\/i>/.exec(body);
        if (id) {
          if (!b.frames.has(Number(id[1]))) b.frames.set(Number(id[1]), []);
          b.frames.get(Number(id[1])).push({ k: Number(id[2]), body });
          continue;
        }
        b.lines.push(body);
        if (body === '<ping></ping>') b.send('<pingok></pingok>');
        else if (body === '<ini></ini>') b.send('<join><ver>700</ver></join>');
        else if (body === '<req_info></req_info>') {
          let info = '<info><name><![CDATA[banbe]]></name><cc>VN</cc>';
          for (let k = 1; k <= 3; k += 1) info += `<p><![CDATA[banbe P${k}]]></p>`;
          for (let k = 0; k < 30; k += 1) info += `<l>${k < 20 ? 16 : 0}</l>`;
          b.send(info + '</info>');
        }
      }
    });
    await b.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    await sleep(200);
    assert.equal(a.status, ''); // nobody to link with
    await intoFight(a, b);
    await play(a, b, 60, 2);
    const fromA = await gotAll(b, 0, 60);
    await gotAll(a, 1, 60);
    assert.match(fromA[51].body, /<n1>2<\/n1><\/f>$/);
    assert.deepEqual(a.socket.merger.counts, { direct: 0, relay: 60 });
  } finally {
    for (const page of pages) page.socket.close();
    for (const ws of plain) ws.close();
    await relay.close();
  }
});
