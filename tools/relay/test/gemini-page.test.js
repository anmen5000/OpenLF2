// SPDX-License-Identifier: MIT
//
// The game page's side of "Gemini plays along": the JavaScript halves of the EM_JS functions in
// src/adapters/luajit/runtime.cpp (read from the source file, with a byte array standing in for WebAssembly memory),
// and dist/pages/gemini.js - the game's reports read, what Gemini is asked, its answers checked, and the whole round
// through the relay (gemini.js) to a stand-in for Google's API and back to the orders the game reads.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { createRelay } = require('../server.js');

const repository = path.join(__dirname, '..', '..', '..');
const page = require(path.join(repository, 'dist', 'pages', 'gemini.js'));

// EM_JS(ret, name, (params), { body }) -> { name: { params, body } } (as emjs-glue.test.js reads transport.cpp).
function extractEmJs(source) {
  const functions = {};
  const pattern = /EM_JS\(\s*[^,]+,\s*(\w+)\s*,\s*\(([^)]*)\)\s*,\s*\{/g;
  let match;
  while ((match = pattern.exec(source))) {
    const open = pattern.lastIndex - 1;
    let depth = 0;
    let close = -1;
    for (let index = open; index < source.length && close < 0; index += 1) {
      const character = source[index];
      if (character === '"') {
        for (index += 1; source[index] !== '"'; index += 1) if (source[index] === '\\') index += 1;
      } else if (character === '{') depth += 1;
      else if (character === '}' && --depth === 0) close = index;
    }
    const params = match[2].split(',').map((part) => part.trim()).filter(Boolean).map((part) => part.match(/(\w+)$/)[1]);
    functions[match[1]] = { params, body: source.slice(open, close + 1).replace(/\/\/[^\n]*/g, '') };
  }
  return functions;
}

function glue(globalObject) {
  const source = fs.readFileSync(path.join(repository, 'src', 'adapters', 'luajit', 'runtime.cpp'), 'utf8');
  const functions = extractEmJs(source);
  const HEAPU8 = new Uint8Array(1 << 16);
  const runtime = {
    globalThis: globalObject,
    UTF8ToString: (pointer) => {
      let end = pointer;
      while (HEAPU8[end]) end += 1;
      return Buffer.from(HEAPU8.subarray(pointer, end)).toString('utf8');
    },
    lengthBytesUTF8: (text) => Buffer.byteLength(text, 'utf8'),
    stringToUTF8: (text, pointer, capacity) => {
      const bytes = Buffer.from(text, 'utf8').subarray(0, capacity - 1);
      HEAPU8.set(bytes, pointer);
      HEAPU8[pointer + bytes.length] = 0;
      return bytes.length;
    },
  };
  const made = {};
  for (const [name, { params, body }] of Object.entries(functions)) {
    made[name] = new Function(...Object.keys(runtime), `return function ${name}(${params.join(', ')}) ${body}`)(...Object.values(runtime));
  }
  // The C++ side (page_plan, page_post) as it calls them.
  made.plan = (known) => {
    const seq = made.page_plan_seq_js();
    if (seq === known) return [seq];
    const length = made.page_plan_length_js();
    if (length < 0 || length > 64 * 1024) return [seq, null];
    made.page_plan_copy_js(1024, length + 1);
    return [seq, runtime.UTF8ToString(1024)];
  };
  made.post = (text) => {
    const bytes = Buffer.from(`${text}\0`, 'utf8');
    HEAPU8.set(bytes, 8192);
    made.page_post_js(8192);
  };
  return made;
}

test('the EM_JS glue: the page\'s orders read by number, the game\'s lines handed to the page', () => {
  const page = {};
  const js = glue(page);
  for (const name of ['page_plan_seq_js', 'page_plan_length_js', 'page_plan_copy_js', 'page_post_js']) {
    assert.equal(typeof js[name], 'function', name);
  }
  // A page without the panel: nothing, and no error.
  assert.deepEqual(js.plan(-1), [0, null]);
  js.post('frame 1 width 800');
  page.OpenLF2AiPlan = 'order 10 11 attack 0\norder 12 -1 kite 150';
  page.OpenLF2AiPlanSeq = 3;
  assert.deepEqual(js.plan(0), [3, 'order 10 11 attack 0\norder 12 -1 kite 150']);
  assert.deepEqual(js.plan(3), [3], 'the same number: not read again');
  page.OpenLF2AiPlan = 'order 10 11 retreat 200 — Sakura';
  page.OpenLF2AiPlanSeq = 4;
  assert.deepEqual(js.plan(3), [4, 'order 10 11 retreat 200 — Sakura'], 'UTF-8 as it is');
  const heard = [];
  page.OpenLF2AiState = (text) => heard.push(text);
  js.post('frame 30 width 1330\nf 10 1 0 1 500 500 209 489 630 0 L walking 0 1 Sakura');
  assert.deepEqual(heard, ['frame 30 width 1330\nf 10 1 0 1 500 500 209 489 630 0 L walking 0 1 Sakura']);
  page.OpenLF2AiState = () => { throw new Error('the page broke'); };
  js.post('frame 60 width 1330'); // the page's trouble stays the page's
  page.OpenLF2AiPlanSeq = Number.NaN;
  assert.equal(js.page_plan_seq_js(), 0);
});

// From the bench (scripts/base/game/smart_ai.lua, smart.page_kit.report): a duel of two computer players.
const REPORT = 'frame 29 width 1330\n'
  + 'f 10 1 0 1 500 500 209 489 630 0 L walking 0 1 Sakura\n'
  + 'f 11 2 0 1 500 500 209 531 629 0 R walking 0 2 Naruto';

test('the game\'s report, the computer players Gemini commands, and what it is asked', () => {
  const report = page.parseReport(REPORT);
  assert.equal(report.frame, 29);
  assert.equal(report.width, 1330);
  assert.deepEqual(report.fighters[0], { slot: 10, team: 1, human: false, commandable: true, hp: 500, maxHp: 500, mp: 209,
    x: 489, z: 630, y: 0, facing: 'L', state: 'walking', weapon: false, id: 1, name: 'Sakura' });
  assert.equal(page.parseReport('nonsense'), null);

  const team = page.parseReport('frame 300 width 1600\n'
    + 'f 0 1 1 0 400 500 100 300 400 0 R standing 0 7 Davis\n' // a human player
    + 'f 10 1 0 1 350 500 50 320 420 0 R walking 0 11 Woody 0 -1 30\n' // his ally (and what the game learned of his moves)
    + 'f 11 2 0 1 200 500 300 900 410 -40 L jumping 1 4 Henry 1 -1 -1\n'
    + 'f 12 2 0 0 0 500 0 950 400 0 L lying 0 8 Freeze\n' // a computer of a mod's own AI, out
    + 'f 13 23 0 1 500 500 500 1200 500 0 L standing 0 1 Deep'); // on no team
  assert.deepEqual(page.chooseSlots(team, 'all'), [10, 11, 13]);
  assert.deepEqual(page.chooseSlots(team, 'allies'), [10]);
  assert.deepEqual(page.chooseSlots(team, 'enemies'), [11, 13]);
  assert.deepEqual(page.chooseSlots(team, 'team2'), [11]);
  assert.deepEqual(page.chooseSlots(team, 'team3'), []);

  const before = page.parseReport('frame 180 width 1600\n'
    + 'f 0 1 1 0 450 500 120 300 400 0 R standing 0 7 Davis\n'
    + 'f 10 1 0 1 380 500 50 320 420 0 R walking 0 11 Woody\n'
    + 'f 11 2 0 1 260 500 280 900 410 0 L walking 0 4 Henry');
  const asked = page.buildPrompt({ report: team, before, lastOrders: new Map([[10, { target: 11, mode: 'attack', reserve: 0 }]]),
    slots: [10, 11], language: 'vi', secondsAgo: 4 });
  assert.match(asked.system, /in Vietnamese/);
  assert.match(asked.prompt, /Time 10 s into the match/);
  assert.match(asked.prompt, /slot 10 "Woody" \(id 11\), team 1, computer - YOU COMMAND IT: HP 350\/500 \(-30 since your last orders\)/);
  assert.match(asked.prompt, /slot 0 "Davis" \(id 7\), team 1, human player: HP 400\/500 \(-50/);
  assert.match(asked.prompt, /slot 11 "Henry".*in the air \(y -40\), jumping, facing left, holding a weapon; moves: a cheap ranged shot\n/);
  assert.match(asked.prompt, /slot 10 "Woody".*facing right; moves: no ranged moves, specials from 30 MP\n/);
  assert.equal(team.fighters[1].specialMp, 30);
  assert.equal(team.fighters[0].shot, undefined, 'a game that does not say');
  assert.match(asked.prompt, /slot 12 "Freeze" \(id 8\), team 2, computer \(its own AI\): out \(HP 0\)/);
  assert.match(asked.prompt, /slot 13 "Deep" \(id 1\), on no team/);
  assert.match(asked.prompt, /- slot 10 to 11: 580 in x, 10 in z; 13: 880 in x, 80 in z/);
  assert.match(asked.prompt, /Your last orders \(4 s ago\): slot 10: target 11, attack, keep 0 MP\./);
  assert.match(asked.prompt, /Give one order for each of these slots: 10, 11\.$/);
  assert.deepEqual(asked.schema.properties.orders.items.properties.mode.enum, ['attack', 'balanced', 'defend', 'kite', 'retreat']);
});

test('Gemini\'s answer is checked: only the slots commanded, real enemies, known modes', () => {
  const report = page.parseReport('frame 300 width 1600\n'
    + 'f 0 1 1 0 400 500 100 300 400 0 R standing 0 7 Davis\n'
    + 'f 10 1 0 1 350 500 50 320 420 0 R walking 0 11 Woody\n'
    + 'f 11 2 0 1 200 500 300 900 410 0 L walking 0 4 Henry\n'
    + 'f 12 2 0 1 0 500 0 950 400 0 L lying 0 8 Freeze');
  const answer = page.parseAnswer('Here you are:\n```json\n' + JSON.stringify({
    orders: [
      { slot: 10, target: 11, mode: 'ATTACK', mp_reserve: 120.4 },
      { slot: 10, target: 0, mode: 'retreat', mp_reserve: 0 }, // twice: the first one counts
      { slot: 11, target: 0, mode: 'kite', mp_reserve: 9000 },
      { slot: 12, target: 10, mode: 'attack', mp_reserve: 0 }, // not commanded
      { slot: 13, target: 0, mode: 'attack', mp_reserve: 0 }, // no such fighter
    ],
    say: '  Dồn   Henry trước!  ',
  }) + '\n```', report, [10, 11]);
  assert.deepEqual([...answer.orders], [[10, { target: 11, mode: 'attack', reserve: 120 }], [11, { target: 0, mode: 'kite', reserve: 500 }]]);
  assert.equal(answer.say, 'Dồn Henry trước!');
  const odd = page.parseAnswer(JSON.stringify({ orders: [
    { slot: 10, target: 0, mode: 'attack', mp_reserve: -5 }, // an ally: XOI chooses
    { slot: 11, target: 12, mode: 'charge', mp_reserve: 0 }, // no such mode
  ], say: 7 }), report, [10, 11]);
  assert.deepEqual([...odd.orders], [[10, { target: -1, mode: 'attack', reserve: 0 }]]);
  assert.equal(odd.say, '');
  assert.equal(page.parseAnswer('no JSON at all', report, [10]), null);
  assert.equal(page.planText(answer.orders), 'order 10 11 attack 120\norder 11 0 kite 500');
});

test('a match\'s result for the tally', () => {
  const end = (lines) => page.parseReport(`frame 900 width 1330\n${lines.join('\n')}`);
  const won = end(['f 10 1 0 1 120 500 0 1 1 0 L standing 0 1 A', 'f 11 2 0 1 0 500 0 1 1 0 L lying 0 2 B']);
  assert.equal(page.outcome(won, new Set([1])), 'won');
  assert.equal(page.outcome(won, new Set([2])), 'lost');
  const going = end(['f 10 1 0 1 120 500 0 1 1 0 L standing 0 1 A', 'f 11 2 0 1 40 500 0 1 1 0 L lying 0 2 B']);
  assert.equal(page.outcome(going, new Set([1])), null);
  assert.equal(page.outcome(going, new Set()), null);
});

async function startGoogle(reply) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || 'null');
      seen.push(body);
      const [status, answer] = reply(body, seen.length);
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(answer));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { seen, base: `http://127.0.0.1:${server.address().port}/v1beta`, close: () => new Promise((resolve) => server.close(resolve)) };
}

const text = (value) => [200, { candidates: [{ content: { parts: [{ text: value }] } }] }];

test('the whole round: the game\'s report, the relay, Gemini, and orders back for the game to read', async () => {
  let reply = () => text(JSON.stringify({ orders: [{ slot: 10, target: 11, mode: 'attack', mp_reserve: 0 },
    { slot: 11, target: 10, mode: 'defend', mp_reserve: 200 }], say: 'Sakura dồn lên, Naruto giữ MP.' }));
  const google = await startGoogle((body, count) => reply(body, count));
  const relay = createRelay({ quiet: true, adminKey: 'admin', geminiGapMs: 0, geminiApiBase: google.base });
  const address = await relay.listen(0, '127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  try {
    const settings = await (await fetch(`${base}/gemini/api/cai-dat`, { method: 'PUT',
      headers: { 'x-admin-key': 'admin', 'content-type': 'application/json' },
      body: JSON.stringify({ apiKey: 'AIzaSyTEST-key_for-the-relay-0123456789' }) })).json();
    let clock = 1000000;
    const published = [];
    const commander = new page.Commander({
      fetch: (...args) => fetch(...args), now: () => clock, url: () => `${base}/gemini/api/plan`,
      publish: (plan) => published.push(plan),
    });
    commander.setOptions({ on: true, code: 'wrong', who: 'all', every: 4, language: 'vi' });
    assert.equal(commander.status().kind, 'wait', 'no match yet');
    commander.state(REPORT);
    await commander.tick();
    assert.match(commander.error, /Sai mã Gemini/);
    assert.equal(commander.stats.failed, 1);
    assert.equal(google.seen.length, 0);

    commander.setOptions({ code: settings.code });
    clock += 6000;
    commander.state(REPORT.replace('frame 29', 'frame 209'));
    await commander.tick();
    assert.equal(commander.error, '');
    assert.equal(published.at(-1), 'order 10 11 attack 0\norder 11 10 defend 200');
    assert.equal(commander.say, 'Sakura dồn lên, Naruto giữ MP.');
    assert.deepEqual(commander.describeOrders(), ['Sakura (10): tấn công, đánh Naruto (11)', 'Naruto (11): phòng thủ, đánh Sakura (10), giữ 200 MP']);
    assert.equal(google.seen.length, 1);
    assert.match(google.seen[0].contents[0].parts[0].text, /Give one order for each of these slots: 10, 11\./);
    assert.match(google.seen[0].systemInstruction.parts[0].text, /battle commander/);
    assert.equal(commander.status().kind, 'ok');

    // Not before the interval; then again, told what changed.
    await commander.tick();
    assert.equal(google.seen.length, 1);
    clock += 4000;
    commander.state('frame 329 width 1330\nf 10 1 0 1 440 500 150 600 630 0 L walking 0 1 Sakura\nf 11 2 0 1 300 500 250 640 629 0 R injured 0 2 Naruto');
    reply = () => text(JSON.stringify({ orders: [{ slot: 10, target: 11, mode: 'attack', mp_reserve: 0 }], say: 'Naruto đang choáng!' }));
    await commander.tick();
    assert.equal(google.seen.length, 2);
    const second = google.seen[1].contents[0].parts[0].text;
    assert.match(second, /HP 300\/500 \(-200 since your last orders\)/);
    assert.match(second, /Your last orders \(4 s ago\): slot 10: target 11, attack, keep 0 MP; slot 11: target 10, defend, keep 200 MP\./);
    // An order Gemini did not renew stays (slot 11 still commanded).
    assert.equal(published.at(-1), 'order 10 11 attack 0\norder 11 10 defend 200');

    // The match ends: Naruto out, the reports stop; Gemini commanded both teams, so no result for the tally.
    commander.state('frame 600 width 1330\nf 10 1 0 1 300 500 150 600 630 0 L standing 0 1 Sakura\nf 11 2 0 1 0 500 0 640 629 0 R lying 0 2 Naruto');
    clock += 5000;
    await commander.tick();
    assert.equal(published.at(-1), '', 'orders dropped when the match is over');
    assert.deepEqual(commander.tally, { won: 0, lost: 0 });

    // A new match, Gemini on team 1 only: it wins.
    commander.setOptions({ who: 'team1' });
    commander.state(REPORT);
    assert.equal(commander.orders.size, 0);
    reply = () => text(JSON.stringify({ orders: [{ slot: 10, target: 11, mode: 'kite', mp_reserve: 100 }], say: 'Giữ xa.' }));
    await commander.tick();
    assert.equal(published.at(-1), 'order 10 11 kite 100');
    assert.match(google.seen.at(-1).contents[0].parts[0].text, /Give one order for each of these slots: 10\./);
    commander.state('frame 900 width 1330\nf 10 1 0 1 50 500 150 600 630 0 L standing 0 1 Sakura\nf 11 2 0 1 0 500 0 640 629 0 R lying 0 2 Naruto');
    commander.state(REPORT); // the next match
    assert.deepEqual(commander.tally, { won: 1, lost: 0 });

    // Gemini's quota: the relay says so, the page waits.
    reply = () => [429, { error: { code: 429, message: 'Resource exhausted' } }];
    clock += 10000;
    commander.state(REPORT.replace('frame 29', 'frame 59'));
    await commander.tick();
    assert.match(commander.error, /hết lượt/);
    assert.equal(commander.nextAt - clock, 30000, 'the relay\'s retryMs');

    // Orders not renewed lapse.
    commander.setPlan(new Map([[10, { target: 11, mode: 'attack', reserve: 0 }]]));
    commander.okAt = clock;
    clock += 16000;
    await commander.tick();
    assert.equal(published.at(-1), '');

    // Off: no orders, no questions.
    const asked = google.seen.length;
    commander.setOptions({ on: false });
    clock += 60000;
    commander.state(REPORT.replace('frame 29', 'frame 89'));
    await commander.tick();
    assert.equal(google.seen.length, asked);
    assert.equal(commander.status().kind, 'off');
  } finally {
    await relay.close();
    await google.close();
  }
});
