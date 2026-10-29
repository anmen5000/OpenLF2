// SPDX-License-Identifier: MIT
//
// Hero Fighter through the relay: the stand-ins for herofighter.com's services (the login answer
// passes the game's own check), and rooms like Room Server v0.7+'s played over the relay's WebSocket.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const WebSocket = require('ws');
const { createRelay } = require('../server.js');
const { parseXml, byTag, valueOf } = require('../hf-room.js');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function startRelay(overrides = {}) {
  const relay = createRelay({ quiet: true, ...overrides });
  const address = await relay.listen(0, '127.0.0.1');
  relay.http = `http://127.0.0.1:${address.port}`;
  relay.url = `ws://127.0.0.1:${address.port}/relay`;
  return relay;
}

async function get(relay, pathname) {
  const response = await fetch(relay.http + pathname, { method: 'POST' });
  return { status: response.status, text: await response.text(), headers: response.headers };
}

const field = (doc, name) => valueOf(byTag(doc, name)[0]);

// Global.LoginStatusMessage: whether the game takes the answer as a logged-in account.
function gameAccepts(xml) {
  const doc = parseXml(xml);
  const c = Array.from({ length: 30 }, (_, k) => Number(field(doc, `c${k + 1}`)));
  const id = Number(field(doc, 'i'));
  const session = Number(field(doc, 's'));
  const sum = (c.reduce((a, b) => a + b, 0) + id + Number(field(doc, 'acctype')) + Number(field(doc, 'stage')) + session % 1000000)
    % 1000000 + 1000000;
  const v = field(doc, 'v');
  const n = Number(v.substr(8, 1));
  const m = Number(v.substr(9 + n * 2, 7));
  const x = Number(v.substr(16 + n * 2, 7));
  const accountSum = Math.trunc((9999998 - x - m) / 3) - sum;
  return { ok: accountSum === 0 || accountSum === id % 13 + id % 61 + id % 107, premium: accountSum !== 0, c, id, name: field(doc, 'n') };
}

test('version check, login, experience, registration and the room list', async () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'hf-'));
  const relay = await startRelay({ packsDir: folder });
  try {
    const ver = await get(relay, '/hf/ver.txt');
    assert.equal(ver.status, 200);
    assert.equal(parseXml(ver.text).children[0].attributes.version, '700');
    assert.equal(ver.headers.get('access-control-allow-origin'), '*');

    // A new e-mail address is a new account, every character open; the same password logs in again.
    const first = await get(relay, '/hf/s/v0.7/login.php?em=An.Men%40Test.vn&pw=secret1');
    const account = gameAccepts(first.text);
    assert.ok(account.ok, first.text);
    assert.ok(account.premium);
    assert.equal(account.name, 'an.men');
    assert.ok(account.id > 20);
    assert.deepEqual(account.c.slice(0, 19), new Array(19).fill(1000));
    assert.ok(gameAccepts((await get(relay, '/hf/s/v0.7/login.php?em=an.men%40test.vn&pw=secret1')).text).ok);
    const wrong = await get(relay, '/hf/s/v0.7/login.php?em=an.men%40test.vn&pw=nope');
    assert.equal(field(parseXml(wrong.text), 'error'), 'pw');

    // Experience after a match: the new values, and the answer is a login answer again.
    const session = field(parseXml(first.text), 's');
    const lu = await get(relay, `/hf/s/v0.7/lu.php?id=${account.id}&em=an.men%40test.vn&s=${session}&i1=1&i2=4&i3=0`
      + '&fr1=1000&fr2=1000&fr3=0&to1=2350&to2=1200&to3=0&uli=0&ulc=0&stg=3&clk=0&cstg=0&v=1');
    const after = gameAccepts(lu.text);
    assert.ok(after.ok, lu.text);
    assert.equal(after.c[0], 2350);
    assert.equal(after.c[3], 1200);
    assert.equal(field(parseXml((await get(relay, '/hf/s/v0.7/lu.php?id=1&em=x%40y.zz&s=1')).text), 'error'), 'sa');

    // Registration: the captcha's code is what the game shows (decoded as it does), then the account.
    const cap = parseXml((await get(relay, '/hf/s/cap.php')).text);
    const c2 = field(cap, 'c2');
    const n = Number(c2.substr(8, 1));
    const code = ((9999998 - Number(c2.substr(16 + n * 2, 7)) - Number(c2.substr(9 + n * 2, 7))) / 3) % 1000000;
    assert.ok(code >= 1000 && code <= 9999);
    const bad = await get(relay, `/hf/s/reg.php?em=b%40test.vn&pw=secret2&nm=Banbe&cc=VN&c=${field(cap, 'c1')}&s=${code + 1}`);
    assert.equal(field(parseXml(bad.text), 'error'), 'code');
    const cap2 = parseXml((await get(relay, '/hf/s/cap.php')).text);
    const c22 = field(cap2, 'c2');
    const n2 = Number(c22.substr(8, 1));
    const code2 = ((9999998 - Number(c22.substr(16 + n2 * 2, 7)) - Number(c22.substr(9 + n2 * 2, 7))) / 3) % 1000000;
    const reg = await get(relay, `/hf/s/reg.php?em=b%40test.vn&pw=secret2&nm=Banbe&cc=VN&c=${field(cap2, 'c1')}&s=${code2}`);
    const registered = gameAccepts(reg.text);
    assert.ok(registered.ok, reg.text);
    assert.equal(registered.name, 'Banbe');

    const list = parseXml((await get(relay, '/hf/hf/rlg.php?ver=700&cc=VN&s=1')).text);
    assert.equal(byTag(list, 'room').length, 4);
    assert.equal(field(list, 'rn'), 'Phong 1');
    const rooms = JSON.parse((await get(relay, '/hf/rooms.json')).text);
    assert.equal(rooms.rooms.length, 4);
    assert.equal(rooms.rooms[1].port, 8889);
  } finally {
    await relay.close();
  }
  // The accounts stay for the next start.
  const saved = JSON.parse(fs.readFileSync(path.join(folder, 'hf', 'accounts.json'), 'utf8'));
  assert.equal(Object.keys(saved.accounts).length, 2);
  assert.equal(saved.accounts['an.men@test.vn'].values[0], 2350);
  const again = await startRelay({ packsDir: folder });
  try {
    assert.ok(gameAccepts((await get(relay === again ? relay : again, '/hf/s/v0.7/login.php?em=b%40test.vn&pw=secret2')).text).ok);
  } finally {
    await again.close();
    fs.rmSync(folder, { recursive: true, force: true });
  }
});

test('one network makes at most 20 new accounts an hour; its accounts still log in', async () => {
  const relay = await startRelay();
  try {
    for (let k = 1; k <= 20; k += 1) {
      assert.ok(gameAccepts((await get(relay, `/hf/s/v0.7/login.php?em=p${k}%40test.vn&pw=secret${k}`)).text).ok);
    }
    const refused = parseXml((await get(relay, '/hf/s/v0.7/login.php?em=p21%40test.vn&pw=secret21')).text);
    assert.equal(field(refused, 'error'), 'reason');
    assert.match(field(refused, 'en'), /Too many new accounts/);
    assert.ok(gameAccepts((await get(relay, '/hf/s/v0.7/login.php?em=p7%40test.vn&pw=secret7')).text).ok);
  } finally {
    await relay.close();
  }
});

// A Hero Fighter game's socket, as the game uses it through Ruffle's socket proxy.
class Game {
  constructor(relay, name, room = 1) {
    this.name = name;
    this.lines = [];
    this.text = '';
    this.ws = new WebSocket(`${relay.url}?game=hf&room=${room}`);
    this.ws.binaryType = 'nodebuffer';
    this.opened = new Promise((resolve, reject) => { this.ws.once('open', resolve); this.ws.once('error', reject); });
    this.ws.on('message', (data) => {
      this.text += data.toString('utf8');
      let at;
      while ((at = this.text.indexOf('\n')) >= 0) {
        const line = this.text.slice(0, at);
        this.text = this.text.slice(at + 1);
        this.lines.push(line);
        if (line === '<ping></ping>') this.send('<pingok></pingok>');
        else if (line === '<ini></ini>') this.send('<join><ver>700</ver></join>');
        else if (line === '<req_info></req_info>') {
          let info = `<info><name><![CDATA[${name}]]></name><cc>VN</cc>`;
          for (let k = 1; k <= 3; k += 1) info += `<p><![CDATA[${name} P${k}]]></p>`;
          for (let k = 0; k < 30; k += 1) info += `<l>${k < 20 ? 1 : 0}</l>`;
          this.send(info + '</info>');
        }
      }
    });
    this.closed = new Promise((resolve) => this.ws.once('close', resolve));
  }
  send(line) { this.ws.send(Buffer.from(line + '\n'), { binary: true }); }
  async waitFor(test, what, ms = 15000) {
    const until = Date.now() + ms;
    for (let from = this.mark || 0; Date.now() < until; await sleep(10)) {
      const index = this.lines.findIndex((line, k) => k >= from && test(line));
      if (index >= 0) { this.mark = index + 1; return this.lines[index]; }
    }
    throw new Error(`${this.name}: no ${what}`);
  }
}

test('two games meet in a room, start a VS match and get each other\'s frames', { timeout: 60000 }, async () => {
  const relay = await startRelay();
  const games = [];
  try {
    const a = new Game(relay, 'anmen');
    games.push(a);
    await a.opened;
    await a.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    const b = new Game(relay, 'banbe');
    games.push(b);
    await b.waitFor((line) => line.startsWith('<chat><c>5</c>'), 'welcome');
    const list = await a.waitFor((line) => line.includes('<join_cid>1</join_cid>'), 'b joining');
    assert.match(list, /<name><!\[CDATA\[banbe\]\]><\/name><online>1<\/online>/);
    const rooms = JSON.parse(await (await fetch(relay.http + '/hf/rooms.json')).text());
    assert.equal(rooms.rooms[0].players, 2);
    assert.match(await (await fetch(relay.http + '/hf/hf/rlg.php')).text(), /<ppl>anmen\(\d+\), banbe\(\d+\)<\/ppl>/);

    a.send('<chat><c>0</c><m><![CDATA[xin chào]]></m></chat>');
    assert.equal(await b.waitFor((line) => line.startsWith('<chat><c>0</c>'), 'chat'), '<chat><c>0</c><m><![CDATA[xin chào]]></m></chat>');

    a.send('<startcount><action>clickvs</action><page>WAITROOM</page><zero>false</zero></startcount>');
    assert.equal(await b.waitFor((line) => line.startsWith('<chat2>'), 'click'), '<chat2><c>0</c><m>clickvs</m></chat2>');
    for (const game of [a, b]) await game.waitFor((line) => line.includes('<page>CHARMENU</page><prepage>WAITROOM'), 'character menu');
    await sleep(100);
    a.send('<page>CHARMENU</page>');
    b.send('<page>CHARMENU</page>');
    a.send('<addplayer>0</addplayer>');
    b.send('<addplayer>0</addplayer>');
    await sleep(200);
    a.send('<startcount><action>clicknext</action><page>CHARMENU</page><zero>false</zero></startcount>');
    for (const game of [a, b]) await game.waitFor((line) => line.includes('<page>GAMESETTINGMENU</page><prepage>CHARMENU'), 'game settings');
    a.send('<page>GAMESETTINGMENU</page>');
    b.send('<page>GAMESETTINGMENU</page>');
    await sleep(100);
    b.send('<startcount><action>clickfight</action><page>GAMESETTINGMENU</page><zero>false</zero></startcount>');
    for (const game of [a, b]) await game.waitFor((line) => line.includes('<page>FIGHTING</page><prepage>GAMESETTINGMENU'), 'fight');
    for (const game of [a, b]) game.send('<page>FIGHTING</page>');
    for (const game of [a, b]) game.send('<startedgame>FIGHTING</startedgame>');
    for (const game of [a, b]) await game.waitFor((line) => line === '<allstartedgame></allstartedgame>', 'all started');

    // Lockstep: a game gets the other's frames once that one sent them (two frames, then <pk>).
    a.send('<f><c>0</c><i>0</i><s1>r</s1></f>');
    a.send('<f><c>0</c><i>1</i><s1>@</s1></f>');
    a.send('<pk></pk>');
    assert.equal(await b.waitFor((line) => line.startsWith('<f>'), 'frames from a'),
      '<f><c>0</c><i>0</i><s1>r</s1></f><f><c>0</c><i>1</i><s1>@</s1></f>');
    assert.ok(!a.lines.some((line) => line.startsWith('<f>')));
    b.send('<f><c>1</c><i>0</i><s1>@</s1></f>\n<f><c>1</c><i>1</i><s1>l</s1></f>\n<pk></pk>');
    assert.equal(await a.waitFor((line) => line.startsWith('<f>'), 'frames from b'),
      '<f><c>1</c><i>0</i><s1>@</s1></f><f><c>1</c><i>1</i><s1>l</s1></f>');

    // One leaves: the other sees it go.
    b.ws.close();
    await a.waitFor((line) => line.includes('<quit_cid>1</quit_cid>'), 'b leaving');
  } finally {
    for (const game of games) game.ws.close();
    await relay.close();
  }
});

test('a game of another version is turned away, and rooms that do not exist too', async () => {
  const relay = await startRelay({ hfRooms: 2 });
  try {
    const ws = new WebSocket(`${relay.url}?game=hf&room=3`);
    const [code] = await new Promise((resolve) => ws.once('close', (...args) => resolve(args)));
    assert.equal(code, 4000);
    const old = new Game(relay, 'old', 2);
    old.send = function send(line) { this.ws.send(Buffer.from(line.replace('<ver>700</ver>', '<ver>699</ver>') + '\n')); };
    assert.equal(await old.waitFor((line) => line.startsWith('<error>'), 'refusal'), '<error><reason>v</reason></error>');
    old.send('<x></x>');
    await old.closed;
  } finally {
    await relay.close();
  }
});
