// SPDX-License-Identifier: MIT
//
// Gemini plays along (gemini.js): the page /gemini's settings, the key kept on the relay (never shown), the players'
// access code, the game page's calls passed to a stand-in for Google's API (the request's forms, the limits, the
// errors), and the cross-origin rules the game page meets.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { createRelay } = require('../server.js');
const { nodeFetch } = require('../gemini.js');

const ADMIN = 'admin-key-for-tests';
const KEY = 'AIzaSyTEST-key_for-the-relay-0123456789';

// A stand-in for generativelanguage.googleapis.com: answers by `reply(request)`, keeps what it was sent.
async function startGoogle(reply) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      const request = { method: req.method, url: req.url, headers: req.headers, body: text ? JSON.parse(text) : null };
      seen.push(request);
      const [status, body] = reply(request, seen.length);
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { seen, base: `http://127.0.0.1:${server.address().port}/v1beta`, close: () => new Promise((resolve) => server.close(resolve)) };
}

const answer = (text) => [200, { candidates: [{ content: { parts: [{ text, thought: false }] }, finishReason: 'STOP' }] }];
const ORDERS = JSON.stringify({ orders: [{ slot: 10, target: 11, mode: 'attack', mp_reserve: 0 }], say: 'Đánh Naruto!' });

async function startRelay(options) {
  const relay = createRelay({ quiet: true, adminKey: ADMIN, geminiGapMs: 0, ...options });
  const address = await relay.listen(0, '127.0.0.1');
  relay.base = `http://127.0.0.1:${address.port}`;
  return relay;
}

const admin = (relay, method, what, body, key = ADMIN) => fetch(`${relay.base}/gemini/api/${what}`, {
  method, headers: { 'x-admin-key': key, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}).then(async (response) => ({ status: response.status, body: await response.json() }));

const plan = (relay, code, body, headers = {}) => fetch(`${relay.base}/gemini/api/plan`, {
  method: 'POST', headers: { 'x-gemini-code': code, 'content-type': 'application/json', ...headers }, body: JSON.stringify(body),
}).then(async (response) => ({ status: response.status, headers: response.headers, body: await response.json() }));

const MATCH = { system: 'You command fighters.', prompt: 'slot 10 Sakura HP 500; slot 11 Naruto HP 500', schema: { type: 'object' } };

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'gemini-test-'));
}

test('the key is kept on the relay, the players use a code, the game page gets Gemini\'s answer', async () => {
  const google = await startGoogle(() => answer(ORDERS));
  const packsDir = tempDir();
  let relay = await startRelay({ packsDir, geminiApiBase: google.base });
  try {
    const page = await fetch(`${relay.base}/gemini`);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /Gemini chơi cùng/);

    assert.equal((await admin(relay, 'GET', 'trang-thai', undefined, 'nope')).status, 401);
    let state = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.equal(state.configured, false);
    assert.equal(state.code, '');
    assert.equal(state.model, 'gemini-3.5-flash-lite');

    // No key yet: the game page is told so.
    assert.equal((await plan(relay, 'whatever', MATCH)).status, 403);

    state = (await admin(relay, 'PUT', 'cai-dat', { apiKey: ` ${KEY} ` })).body;
    assert.equal(state.configured, true);
    assert.equal(state.keyEnd, KEY.slice(-4));
    assert.match(state.code, /^[a-z0-9]{12}$/);
    assert.ok(!JSON.stringify(state).includes(KEY), 'the key is never shown');
    const file = path.join(packsDir, 'gemini', 'gemini.json');
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);

    assert.equal((await plan(relay, 'wrong-code', MATCH)).status, 401);
    const got = await plan(relay, state.code, MATCH);
    assert.equal(got.status, 200);
    assert.equal(got.body.text, ORDERS);
    assert.equal(got.body.model, 'gemini-3.5-flash-lite');
    assert.equal(typeof got.body.ms, 'number');
    assert.equal(got.headers.get('access-control-allow-origin'), '*');

    const sent = google.seen[0];
    assert.equal(sent.method, 'POST');
    assert.equal(sent.url, '/v1beta/models/gemini-3.5-flash-lite:generateContent');
    assert.equal(sent.headers['x-goog-api-key'], KEY);
    assert.deepEqual(sent.body.systemInstruction, { parts: [{ text: MATCH.system }] });
    assert.deepEqual(sent.body.contents, [{ role: 'user', parts: [{ text: MATCH.prompt }] }]);
    assert.equal(sent.body.generationConfig.responseMimeType, 'application/json');
    assert.deepEqual(sent.body.generationConfig.responseJsonSchema, MATCH.schema);
    assert.deepEqual(sent.body.generationConfig.thinkingConfig, { thinkingLevel: 'minimal' });
    assert.ok(!('temperature' in sent.body.generationConfig), 'no temperature: Gemini 3 ignores it');

    state = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.equal(state.calls, 1);
    assert.equal(state.errors, 0);

    // Kept: a relay started again has the key and the code.
    await relay.close();
    relay = await startRelay({ packsDir, geminiApiBase: google.base });
    const again = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.equal(again.configured, true);
    assert.equal(again.code, state.code);
    assert.equal((await plan(relay, state.code, MATCH)).status, 200);

    // A new code: the old one stops working.
    const renewed = (await admin(relay, 'POST', 'doi-ma')).body;
    assert.notEqual(renewed.code, state.code);
    assert.equal((await plan(relay, state.code, MATCH)).status, 401);
    assert.equal((await plan(relay, renewed.code, MATCH)).status, 200);

    // Switched off on the page /gemini.
    await admin(relay, 'PUT', 'cai-dat', { enabled: false });
    assert.equal((await plan(relay, renewed.code, MATCH)).status, 403);
    await admin(relay, 'PUT', 'cai-dat', { enabled: true, clearKey: true });
    assert.equal((await plan(relay, renewed.code, MATCH)).status, 503);
  } finally {
    await relay.close();
    await google.close();
  }
});

test('a model without a setting: the relay tries the plainer forms and remembers the one that worked', async () => {
  const google = await startGoogle((request) => {
    const config = request.body.generationConfig || {};
    if (config.thinkingConfig) return [400, { error: { code: 400, message: 'Thinking level is not supported for this model.' } }];
    if (config.responseJsonSchema) return [400, { error: { code: 400, message: 'Unknown name "responseJsonSchema"' } }];
    return answer('```json\n' + ORDERS + '\n```');
  });
  const relay = await startRelay({ geminiApiBase: google.base });
  try {
    const { code } = (await admin(relay, 'PUT', 'cai-dat', { apiKey: KEY, model: 'models/gemini-2.5-flash' })).body;
    const got = await plan(relay, code, MATCH);
    assert.equal(got.status, 200);
    assert.match(got.body.text, /"orders"/);
    assert.equal(google.seen.length, 3);
    assert.equal(google.seen[0].url, '/v1beta/models/gemini-2.5-flash:generateContent');
    assert.deepEqual(google.seen[2].body.generationConfig, { responseMimeType: 'application/json', maxOutputTokens: 1024 });
    // The next call goes straight to the form that worked.
    await plan(relay, code, MATCH);
    assert.equal(google.seen.length, 4);
    assert.deepEqual(google.seen[3].body.generationConfig, google.seen[2].body.generationConfig);
  } finally {
    await relay.close();
    await google.close();
  }
});

test('Gemini\'s errors reach the game page in words, never with the key', async () => {
  let next = [200, {}];
  const google = await startGoogle(() => next);
  const relay = await startRelay({ geminiApiBase: google.base });
  try {
    const { code } = (await admin(relay, 'PUT', 'cai-dat', { apiKey: KEY })).body;
    next = [400, { error: { code: 400, message: `API key not valid. Please pass a valid API key. (${KEY})` } }];
    let got = await plan(relay, code, MATCH);
    assert.equal(got.status, 502);
    assert.match(got.body.error, /Khóa Gemini API không đúng/);
    next = [429, { error: { code: 429, message: `Resource has been exhausted (e.g. check quota). key=${KEY}` } }];
    got = await plan(relay, code, MATCH);
    assert.equal(got.status, 429);
    assert.match(got.body.error, /hết lượt/);
    assert.ok(!got.body.error.includes(KEY));
    assert.equal(got.body.retryMs, 30000);
    next = [404, { error: { code: 404, message: 'models/x is not found' } }];
    got = await plan(relay, code, MATCH);
    assert.match(got.body.error, /không có model gemini-3\.5-flash-lite/);
    next = [200, { promptFeedback: { blockReason: 'SAFETY' } }];
    got = await plan(relay, code, MATCH);
    assert.equal(got.status, 502);
    assert.match(got.body.error, /SAFETY/);
    const state = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.equal(state.calls, 4);
    assert.equal(state.errors, 4);
    assert.ok(!JSON.stringify(state).includes(KEY));
    // Too big, or no match.
    assert.equal((await plan(relay, code, { prompt: 'x'.repeat(30000) })).status, 413);
    assert.equal((await plan(relay, code, { system: 'only' })).status, 400);
  } finally {
    await relay.close();
    await google.close();
  }
});

test('the limits: a pause between calls, calls a minute and a day', async () => {
  const google = await startGoogle(() => answer(ORDERS));
  const relay = await startRelay({ geminiApiBase: google.base, geminiGapMs: 1500 });
  try {
    const { code } = (await admin(relay, 'PUT', 'cai-dat', { apiKey: KEY, perMinute: 2, perDay: 3 })).body;
    assert.equal((await plan(relay, code, MATCH)).status, 200);
    const soon = await plan(relay, code, MATCH);
    assert.equal(soon.status, 429);
    assert.ok(soon.body.retryMs > 0 && soon.body.retryMs <= 1500);
    await new Promise((resolve) => setTimeout(resolve, 1600));
    assert.equal((await plan(relay, code, MATCH)).status, 200);
    await new Promise((resolve) => setTimeout(resolve, 1600));
    const minute = await plan(relay, code, MATCH);
    assert.equal(minute.status, 429);
    assert.match(minute.body.error, /2 lần một phút/);
    await admin(relay, 'PUT', 'cai-dat', { perMinute: 0 });
    assert.equal((await plan(relay, code, MATCH)).status, 200);
    await new Promise((resolve) => setTimeout(resolve, 1600));
    const day = await plan(relay, code, MATCH);
    assert.equal(day.status, 429);
    assert.match(day.body.error, /giới hạn một ngày/);
    assert.equal(google.seen.length, 3);
  } finally {
    await relay.close();
    await google.close();
  }
});

test('the game page on another origin: the preflight, and only the origins the relay allows', async () => {
  const google = await startGoogle(() => answer(ORDERS));
  const relay = await startRelay({ geminiApiBase: google.base, allowedOrigins: ['https://anmen5000.github.io'] });
  try {
    const { code } = (await admin(relay, 'PUT', 'cai-dat', { apiKey: KEY })).body;
    const preflight = await fetch(`${relay.base}/gemini/api/plan`, { method: 'OPTIONS', headers: { origin: 'https://anmen5000.github.io',
      'access-control-request-method': 'POST', 'access-control-request-headers': 'content-type, x-gemini-code' } });
    assert.equal(preflight.status, 204);
    assert.equal(preflight.headers.get('access-control-allow-origin'), 'https://anmen5000.github.io');
    assert.match(preflight.headers.get('access-control-allow-headers'), /x-gemini-code/);
    const ok = await plan(relay, code, MATCH, { origin: 'https://anmen5000.github.io' });
    assert.equal(ok.headers.get('access-control-allow-origin'), 'https://anmen5000.github.io');
    const refused = await plan(relay, 'wrong', MATCH, { origin: 'https://anmen5000.github.io' });
    assert.equal(refused.status, 401);
    assert.equal(refused.headers.get('access-control-allow-origin'), 'https://anmen5000.github.io', 'the page can read why');
    const other = await plan(relay, code, MATCH, { origin: 'https://elsewhere.example' });
    assert.equal(other.headers.get('access-control-allow-origin'), null);
  } finally {
    await relay.close();
    await google.close();
  }
});

test('the models the key may use, and the test call of the page /gemini', async () => {
  const google = await startGoogle((request) => {
    if (request.method === 'GET') {
      return [200, { models: [
        { name: 'models/gemini-3.5-flash-lite', supportedGenerationMethods: ['generateContent', 'countTokens'] },
        { name: 'models/text-embedding-004', supportedGenerationMethods: ['embedContent'] },
        { name: 'models/gemini-3.6-flash', supportedGenerationMethods: ['generateContent'] },
      ] }];
    }
    return answer('{"ok": true, "say": "Sẵn sàng!"}');
  });
  const relay = await startRelay({ geminiApiBase: google.base });
  try {
    assert.equal((await admin(relay, 'GET', 'models')).status, 400);
    await admin(relay, 'PUT', 'cai-dat', { apiKey: KEY });
    const models = await admin(relay, 'GET', 'models');
    assert.deepEqual(models.body.models, ['gemini-3.5-flash-lite', 'gemini-3.6-flash']);
    assert.equal(google.seen[0].headers['x-goog-api-key'], KEY);
    const tried = await admin(relay, 'POST', 'thu');
    assert.equal(tried.status, 200);
    assert.equal(JSON.parse(tried.body.text).say, 'Sẵn sàng!');
    assert.equal((await admin(relay, 'PUT', 'cai-dat', { model: 'bad model!' })).status, 400);
    assert.equal((await admin(relay, 'PUT', 'cai-dat', { thinking: 'huge' })).status, 400);
    assert.equal((await admin(relay, 'PUT', 'cai-dat', { apiKey: 'short' })).status, 400);
  } finally {
    await relay.close();
    await google.close();
  }
});

test('without fetch (Node.js 16): the relay\'s own request does the same', async () => {
  const google = await startGoogle((request) => (request.method === 'GET' ? [200, { models: [] }]
    : request.body.contents ? answer(ORDERS) : [400, { error: { code: 400, message: 'no' } }]));
  try {
    const listed = await nodeFetch(`${google.base}/models?pageSize=200`, { headers: { 'x-goog-api-key': KEY } });
    assert.equal(listed.ok, true);
    assert.deepEqual(JSON.parse(await listed.text()), { models: [] });
    const asked = await nodeFetch(`${google.base}/models/m:generateContent`, { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': KEY }, body: JSON.stringify({ contents: [{ parts: [{ text: 'Đánh' }] }] }) });
    assert.equal(asked.status, 200);
    assert.equal(JSON.parse(await asked.text()).candidates[0].content.parts[0].text, ORDERS);
    assert.equal(google.seen[1].body.contents[0].parts[0].text, 'Đánh', 'UTF-8 and its length');
    assert.equal(google.seen[1].headers['x-goog-api-key'], KEY);
    const refused = await nodeFetch(`${google.base}/x`, { method: 'POST', body: '{}' });
    assert.equal(refused.ok, false);
    assert.equal(refused.status, 400);
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(nodeFetch(`${google.base}/models`, { signal: controller.signal }), { name: 'AbortError' });
  } finally {
    await google.close();
  }
});
