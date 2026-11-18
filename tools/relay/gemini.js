// SPDX-License-Identifier: MIT
//
// Gemini plays along (package 96): the game page's Gemini panel (dist/pages/gemini.js) sends what a match looks like
// every few seconds, the relay asks Google's Gemini with the owner's API key, and hands the answer back; the game's
// XOI plays every frame by the orders the page makes of it (scripts/base/game/smart_ai.lua, smart.page_kit). The key
// stays on the relay, in a file only the relay's user reads: the page and its players never see it. Players use the
// access code the page /gemini shows instead, and the relay keeps to the limits set there (calls a minute, a day),
// so that a code that went round cannot use up the key.
//
// The page writes what Gemini is asked (its instruction, the match, the answer's JSON schema), so that it can get
// better with the site; the relay only passes it on, within the sizes below, and gives back Gemini's text.
//
//   GET    /gemini                  the page (Vietnamese; ADMIN_KEY)
//   GET    /gemini/api/trang-thai   the settings (the key's last 4 characters only) and today's calls (X-Admin-Key)
//   PUT    /gemini/api/cai-dat      {"apiKey","clearKey","model","thinking","perMinute","perDay","enabled"} (X-Admin-Key)
//   POST   /gemini/api/doi-ma       a new access code for the players (X-Admin-Key)
//   GET    /gemini/api/models       the models the key may use (X-Admin-Key)
//   POST   /gemini/api/thu          one call to Gemini, to see that the key and the model work (X-Admin-Key)
//   POST   /gemini/api/plan         the game page's: {"system","prompt","schema"} (X-Gemini-Code; any origin the relay
//                                   allows, with OPTIONS first) -> {"text","ms","model"}, or {"error"} with a status
// Kept in GEMINI_DIR (default <PACKS_DIR>/gemini): gemini.json (mode 0600).
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const MODEL = /^[a-z0-9][a-z0-9._-]{0,79}$/;
const THINKING = ['', 'minimal', 'low', 'medium', 'high'];
const DEFAULTS = { model: 'gemini-3.5-flash-lite', thinking: 'minimal', perMinute: 15, perDay: 1000, enabled: true };
const SUGGESTED = ['gemini-3.5-flash-lite', 'gemini-3.6-flash', 'gemini-3.1-flash-lite', 'gemini-2.5-flash-lite', 'gemini-2.5-flash'];
const KEY = /^[\x21-\x7e]{20,300}$/; // printable, no spaces: it goes in a header
const CODE = /^[a-z0-9]{8,40}$/;
const REQUEST_LIMIT = 40 * 1024;
const SYSTEM_LIMIT = 12 * 1024;
const PROMPT_LIMIT = 24 * 1024;
const SCHEMA_LIMIT = 4 * 1024;
const OUTPUT_TOKENS = 1024;
const TIMEOUT_MS = 20000;
const GAP_MS = 1500; // between two of one address's calls
const API = 'https://generativelanguage.googleapis.com/v1beta';

function sameKey(given, expected) {
  const a = crypto.createHash('sha256').update(String(given || '')).digest();
  const b = crypto.createHash('sha256').update(String(expected)).digest();
  return crypto.timingSafeEqual(a, b);
}

class Answer extends Error {
  constructor(status, message, extra = {}) {
    super(message);
    this.status = status;
    this.extra = extra;
  }
}

function newCode() {
  // 12 letters and digits, none that look alike (0/o, 1/l/i).
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  const bytes = crypto.randomBytes(12);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

function whole(value, least, most, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number >= least && number <= most ? number : fallback;
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

function createGemini(config, {
  log = () => {},
  clientAddress = (req) => req.socket.remoteAddress || 'unknown',
  allowOrigin = () => ({ 'access-control-allow-origin': '*' }),
  fetchImpl = (...args) => globalThis.fetch(...args),
} = {}) {
  const directory = config.geminiDir || (config.packsDir ? path.join(config.packsDir, 'gemini') : '');
  const file = directory ? path.join(directory, 'gemini.json') : '';
  const base = String(config.geminiApiBase || API).replace(/\/+$/, '');
  const gap = Number.isFinite(config.geminiGapMs) ? config.geminiGapMs : GAP_MS; // (tests: 0)
  const failures = new Map(); // client address -> { count, until }: wrong codes and keys
  const lastCall = new Map(); // client address -> time of its last call (and whether one is on its way)
  const busy = new Set();
  let minute = []; // times of the calls in the last minute
  const working = new Map(); // model -> the first of the request's forms it took (see ask)
  const settings = load();

  function load() {
    const fresh = { apiKey: '', code: '', ...DEFAULTS, day: today(), calls: 0, errors: 0, last: null };
    if (!file) return fresh;
    let data;
    try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fresh; }
    if (typeof data.apiKey === 'string' && KEY.test(data.apiKey)) fresh.apiKey = data.apiKey;
    if (typeof data.code === 'string' && CODE.test(data.code)) fresh.code = data.code;
    if (typeof data.model === 'string' && MODEL.test(data.model)) fresh.model = data.model;
    if (THINKING.includes(data.thinking)) fresh.thinking = data.thinking;
    fresh.perMinute = whole(data.perMinute, 0, 1000, DEFAULTS.perMinute);
    fresh.perDay = whole(data.perDay, 0, 1000000, DEFAULTS.perDay);
    fresh.enabled = data.enabled !== false;
    if (data.day === fresh.day) {
      fresh.calls = whole(data.calls, 0, 1e9, 0);
      fresh.errors = whole(data.errors, 0, 1e9, 0);
    }
    if (data.last && typeof data.last === 'object') {
      fresh.last = { at: String(data.last.at || '').slice(0, 40), ms: whole(data.last.ms, 0, 1e7, 0),
        error: String(data.last.error || '').slice(0, 300) };
    }
    return fresh;
  }

  function save() {
    if (!file) return;
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    try { fs.chmodSync(directory, 0o700); } catch { /* not ours to change */ }
    const temporary = `${file}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(settings, null, 1), { mode: 0o600 });
    fs.chmodSync(temporary, 0o600);
    fs.renameSync(temporary, file);
  }

  // Calls are counted by the day (the server's UTC day; Google's own day may end at another hour).
  function rollDay() {
    const day = today();
    if (settings.day !== day) {
      settings.day = day;
      settings.calls = 0;
      settings.errors = 0;
    }
  }

  function counted(address) {
    const time = Date.now();
    let entry = failures.get(address);
    if (!entry || entry.until <= time) {
      entry = { count: 0, until: time + 3600000 };
      failures.set(address, entry);
    }
    return entry;
  }

  function authorizeAdmin(req) {
    const tries = counted(clientAddress(req));
    if (tries.count >= 30) throw new Answer(429, 'Sai mã quá nhiều lần, thử lại sau một giờ.');
    if (config.adminKey && sameKey(req.headers['x-admin-key'], config.adminKey)) return;
    tries.count += 1;
    if (!config.adminKey) throw new Answer(403, 'Relay chưa có ADMIN_KEY (chạy lại install-vps.sh).');
    throw new Answer(401, 'Sai mã quản trị (ADMIN_KEY).');
  }

  function authorizePlayer(req) {
    const tries = counted(clientAddress(req));
    if (tries.count >= 30) throw new Answer(429, 'Sai mã Gemini quá nhiều lần, thử lại sau một giờ.');
    if (settings.code && sameKey(req.headers['x-gemini-code'], settings.code)) return;
    if (config.adminKey && sameKey(req.headers['x-admin-key'], config.adminKey)) return;
    tries.count += 1;
    if (!settings.code) throw new Answer(403, 'Relay chưa bật Gemini: chủ relay đặt khóa ở trang /gemini.');
    throw new Answer(401, 'Sai mã Gemini: lấy mã ở trang /gemini của relay.');
  }

  function readBody(req, limit) {
    return new Promise((resolve, reject) => {
      const declared = Number(req.headers['content-length'] || 0);
      if (declared > limit) {
        req.resume();
        reject(new Answer(413, `Quá lớn (tối đa ${Math.round(limit / 1024)} KB).`));
        return;
      }
      const chunks = [];
      let size = 0;
      let over = false;
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > limit) over = true;
        if (!over) chunks.push(chunk);
      });
      req.on('end', () => (over ? reject(new Answer(413, `Quá lớn (tối đa ${Math.round(limit / 1024)} KB).`))
        : resolve(Buffer.concat(chunks))));
      req.on('error', reject);
    });
  }

  async function readJson(req, limit) {
    const text = (await readBody(req, limit)).toString('utf8');
    if (!text) return {};
    const body = JSON.parse(text);
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Answer(400, 'Yêu cầu hỏng.');
    return body;
  }

  function json(res, status, body, headers = {}) {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers });
    res.end(JSON.stringify(body));
  }

  // Never the key in what is shown or logged.
  function scrub(text) {
    let clean = String(text || '');
    if (settings.apiKey) clean = clean.split(settings.apiKey).join('…');
    return clean.replace(/key=[A-Za-z0-9_-]{10,}/g, 'key=…').slice(0, 300);
  }

  function describe() {
    rollDay();
    return {
      configured: Boolean(settings.apiKey),
      keyEnd: settings.apiKey ? settings.apiKey.slice(-4) : '',
      model: settings.model,
      thinking: settings.thinking,
      perMinute: settings.perMinute,
      perDay: settings.perDay,
      enabled: settings.enabled,
      code: settings.code,
      calls: settings.calls,
      errors: settings.errors,
      last: settings.last,
      stored: Boolean(file),
      suggested: SUGGESTED,
    };
  }

  async function withTimeout(url, options) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
    try {
      return await fetchImpl(url, { ...options, signal: controller.signal });
    } catch (error) {
      if (controller.signal.aborted) throw new Answer(504, `Gemini không trả lời sau ${TIMEOUT_MS / 1000} giây.`);
      throw new Answer(502, `Không gọi được Gemini: ${scrub(error && error.message)}`);
    } finally {
      clearTimeout(timer);
    }
  }

  function upstreamError(status, data, model) {
    const message = scrub((data && data.error && data.error.message) || '');
    if (status === 400 && /api key/i.test(message)) return new Answer(502, 'Khóa Gemini API không đúng (đặt lại ở trang /gemini).');
    if (status === 401 || status === 403) {
      return new Answer(502, `Khóa Gemini API không dùng được (HTTP ${status}${message ? `: ${message}` : ''}). Kiểm tra khóa ở trang /gemini.`);
    }
    if (status === 404) return new Answer(502, `Gemini không có model ${model} (đổi model ở trang /gemini).`);
    if (status === 429) {
      return new Answer(429, `Gemini báo hết lượt của khóa (HTTP 429${message ? `: ${message}` : ''}). Đợi một lát hay đổi model.`, { retryMs: 30000 });
    }
    if (status === 400) return new Answer(502, `Gemini không nhận yêu cầu (HTTP 400${message ? `: ${message}` : ''}).`);
    return new Answer(502, `Gemini đang lỗi (HTTP ${status}${message ? `: ${message}` : ''}), thử lại sau.`);
  }

  // The request's forms, tried in turn while Gemini answers 400 (a model without that setting): the JSON schema and
  // the thinking level, then JSON alone, then plain text (the page reads JSON out of it). The form a model took is
  // remembered.
  function forms(schema) {
    const list = [];
    const thinking = settings.thinking ? { thinkingConfig: { thinkingLevel: settings.thinking } } : {};
    if (schema) list.push({ responseMimeType: 'application/json', responseJsonSchema: schema, maxOutputTokens: OUTPUT_TOKENS, ...thinking });
    list.push({ responseMimeType: 'application/json', maxOutputTokens: OUTPUT_TOKENS, ...thinking });
    if (settings.thinking) list.push({ responseMimeType: 'application/json', maxOutputTokens: OUTPUT_TOKENS });
    list.push({ maxOutputTokens: OUTPUT_TOKENS });
    return list;
  }

  async function ask({ system, prompt, schema }) {
    if (!settings.apiKey) throw new Answer(503, 'Relay chưa có khóa Gemini API: chủ relay đặt ở trang /gemini.');
    const model = settings.model;
    const url = `${base}/models/${encodeURIComponent(model)}:generateContent`;
    const list = forms(schema);
    const key = `${model} ${settings.thinking} ${schema ? 1 : 0}`;
    const started = Date.now();
    let data = null;
    for (let at = working.get(key) || 0; at < list.length; at += 1) {
      const body = { contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig: list[at] };
      if (system) body.systemInstruction = { parts: [{ text: system }] };
      const response = await withTimeout(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': settings.apiKey },
        body: JSON.stringify(body),
      });
      const text = await response.text();
      try { data = JSON.parse(text); } catch { data = null; }
      if (response.ok) {
        working.set(key, at);
        break;
      }
      const message = (data && data.error && data.error.message) || '';
      if (response.status === 400 && at + 1 < list.length && !/api key/i.test(message)) continue;
      throw upstreamError(response.status, data, model);
    }
    const candidate = data && Array.isArray(data.candidates) ? data.candidates[0] : null;
    const parts = candidate && candidate.content && Array.isArray(candidate.content.parts) ? candidate.content.parts : [];
    const answer = parts.filter((part) => part && typeof part.text === 'string' && !part.thought).map((part) => part.text).join('');
    if (!answer) {
      const blocked = data && data.promptFeedback && data.promptFeedback.blockReason;
      const reason = blocked || (candidate && candidate.finishReason) || 'không có chữ';
      throw new Answer(502, `Gemini không trả lời (${scrub(reason)}).`);
    }
    return { text: answer.slice(0, 16000), ms: Date.now() - started, model };
  }

  function note(result, error) {
    rollDay();
    settings.calls += 1;
    if (error) settings.errors += 1;
    settings.last = { at: new Date().toISOString(), ms: result ? result.ms : 0, error: error ? scrub(error.message) : '' };
    try { save(); } catch (problem) { log('gemini: cannot save', problem && problem.message); }
  }

  // The limits: one call at a time and a pause between two from one address, the calls a minute and a day.
  function admit(address) {
    rollDay();
    const time = Date.now();
    if (busy.has(address)) throw new Answer(429, 'Đang chờ Gemini trả lời câu trước.', { retryMs: 1000 });
    const previous = lastCall.get(address) || 0;
    if (time - previous < gap) throw new Answer(429, 'Hỏi Gemini chậm lại một chút.', { retryMs: gap - (time - previous) });
    minute = minute.filter((at) => time - at < 60000);
    if (settings.perMinute && minute.length >= settings.perMinute) {
      throw new Answer(429, `Đã tới giới hạn ${settings.perMinute} lần một phút (trang /gemini).`, { retryMs: 60000 - (time - minute[0]) });
    }
    if (settings.perDay && settings.calls >= settings.perDay) {
      throw new Answer(429, `Hôm nay đã hỏi Gemini ${settings.calls} lần, tới giới hạn một ngày (trang /gemini).`, { retryMs: 3600000 });
    }
    minute.push(time);
    lastCall.set(address, time);
    busy.add(address);
  }

  async function route(req, res, what) {
    const method = req.method;
    if (what === 'plan') {
      const cors = allowOrigin(req);
      if (method === 'OPTIONS') {
        res.writeHead(204, { ...cors, 'access-control-allow-methods': 'POST, OPTIONS',
          'access-control-allow-headers': 'content-type, x-gemini-code', 'access-control-max-age': '600' });
        res.end();
        return;
      }
      if (method !== 'POST') throw new Answer(405, 'Chỉ nhận POST.');
      authorizePlayer(req);
      if (!settings.enabled) throw new Answer(403, 'Chủ relay đang tắt Gemini (trang /gemini).');
      if (!settings.apiKey) throw new Answer(503, 'Relay chưa có khóa Gemini API: chủ relay đặt ở trang /gemini.');
      const body = await readJson(req, REQUEST_LIMIT);
      const system = typeof body.system === 'string' ? body.system : '';
      const prompt = typeof body.prompt === 'string' ? body.prompt : '';
      if (!prompt) throw new Answer(400, 'Thiếu tình hình trận đấu (prompt).');
      if (system.length > SYSTEM_LIMIT || prompt.length > PROMPT_LIMIT) throw new Answer(413, 'Tình hình trận đấu quá dài.');
      let schema = null;
      if (body.schema && typeof body.schema === 'object' && !Array.isArray(body.schema)) {
        if (JSON.stringify(body.schema).length > SCHEMA_LIMIT) throw new Answer(413, 'Schema quá dài.');
        schema = body.schema;
      }
      const address = clientAddress(req);
      admit(address);
      let result;
      try {
        result = await ask({ system, prompt, schema });
        note(result, null);
      } catch (error) {
        note(null, error);
        throw error;
      } finally {
        busy.delete(address);
      }
      json(res, 200, result, cors);
      return;
    }
    authorizeAdmin(req);
    if (what === 'trang-thai' && method === 'GET') {
      json(res, 200, describe());
      return;
    }
    if (what === 'cai-dat' && method === 'PUT') {
      const body = await readJson(req, 8 * 1024);
      if (typeof body.apiKey === 'string' && body.apiKey.trim()) {
        const key = body.apiKey.trim();
        if (!KEY.test(key)) throw new Answer(400, 'Khóa Gemini API không giống khóa thật (dán lại, không có dấu cách).');
        settings.apiKey = key;
        working.clear();
      }
      if (body.clearKey === true) settings.apiKey = '';
      if (body.model !== undefined) {
        const model = String(body.model).trim().replace(/^models\//, '');
        if (!MODEL.test(model)) throw new Answer(400, 'Tên model không hợp lệ (ví dụ gemini-3.5-flash-lite).');
        settings.model = model;
      }
      if (body.thinking !== undefined) {
        if (!THINKING.includes(body.thinking)) throw new Answer(400, 'Mức suy nghĩ không hợp lệ.');
        settings.thinking = body.thinking;
      }
      if (body.perMinute !== undefined) settings.perMinute = whole(body.perMinute, 0, 1000, settings.perMinute);
      if (body.perDay !== undefined) settings.perDay = whole(body.perDay, 0, 1000000, settings.perDay);
      if (body.enabled !== undefined) settings.enabled = Boolean(body.enabled);
      if (!settings.code) settings.code = newCode();
      save();
      log(`gemini: settings (model ${settings.model}, key ${settings.apiKey ? 'set' : 'none'})`);
      json(res, 200, describe());
      return;
    }
    if (what === 'doi-ma' && method === 'POST') {
      settings.code = newCode();
      save();
      json(res, 200, describe());
      return;
    }
    if (what === 'models' && method === 'GET') {
      if (!settings.apiKey) throw new Answer(400, 'Chưa có khóa Gemini API.');
      const names = [];
      let token = '';
      for (let page = 0; page < 5; page += 1) {
        const url = `${base}/models?pageSize=200${token ? `&pageToken=${encodeURIComponent(token)}` : ''}`;
        const response = await withTimeout(url, { headers: { 'x-goog-api-key': settings.apiKey } });
        let data = null;
        try { data = JSON.parse(await response.text()); } catch { data = null; }
        if (!response.ok) throw upstreamError(response.status, data, settings.model);
        for (const model of (data && data.models) || []) {
          const methods = model.supportedGenerationMethods || [];
          const name = String(model.name || '').replace(/^models\//, '');
          if (methods.includes('generateContent') && MODEL.test(name)) names.push(name);
        }
        token = data && data.nextPageToken;
        if (!token) break;
      }
      json(res, 200, { models: names });
      return;
    }
    if (what === 'thu' && method === 'POST') {
      const schema = { type: 'object', properties: { ok: { type: 'boolean' }, say: { type: 'string' } }, required: ['ok', 'say'] };
      let result;
      try {
        result = await ask({
          system: 'You check that a connection works. Answer only JSON.',
          prompt: 'Reply {"ok": true, "say": "<one short friendly sentence in Vietnamese saying you are ready to command the fighters>"}',
          schema,
        });
        note(result, null);
      } catch (error) {
        note(null, error);
        throw error;
      }
      json(res, 200, result);
      return;
    }
    throw new Answer(404, 'Không có yêu cầu này.');
  }

  // Returns true when the request was Gemini's and has been answered (or is being answered).
  function handle(req, res, pathname) {
    if (pathname === '/gemini' || pathname === '/gemini/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
        'x-frame-options': 'DENY', 'referrer-policy': 'no-referrer' });
      res.end(PAGE);
      return true;
    }
    if (!pathname.startsWith('/gemini/api/')) return false;
    const what = pathname.slice('/gemini/api/'.length);
    route(req, res, what).catch((error) => {
      const status = error instanceof Answer ? error.status : (error instanceof SyntaxError ? 400 : 500);
      if (status === 500) log('gemini:', error && error.stack ? error.stack : error);
      if (res.headersSent) {
        res.destroy();
        return;
      }
      const message = error instanceof Answer ? error.message : (status === 400 ? 'Yêu cầu hỏng.' : 'Lỗi trên relay.');
      const extra = error instanceof Answer ? error.extra : {};
      json(res, status, { error: message, ...extra }, what === 'plan' ? allowOrigin(req) : {});
    });
    return true;
  }

  return {
    handle,
    cleanup: () => {
      const time = Date.now();
      for (const [address, entry] of failures) if (entry.until <= time) failures.delete(address);
      for (const [address, at] of lastCall) if (time - at > 60000 && !busy.has(address)) lastCall.delete(address);
    },
    settings: () => settings,
  };
}

// The page at /gemini (Vietnamese: the relay's owner reads it). The admin key is the one /admin and /hoc remember.
const PAGE = `<!doctype html>
<html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenLF2 relay: Gemini chơi cùng</title>
<style>
  body { margin: 0; padding: 1.5rem; background: #111827; color: #f3f4f6; font: 16px/1.5 system-ui, sans-serif; }
  main { max-width: 820px; margin: auto; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
  h2 { font-size: 1.15rem; margin: 0 0 .5rem; }
  .card { background: #1f2937; border: 1px solid #374151; border-radius: 12px; padding: 1rem 1.2rem; margin: 1rem 0; }
  label { display: block; margin: .6rem 0 .2rem; font-weight: 600; }
  label.inline { display: flex; gap: .5rem; align-items: center; font-weight: 500; }
  input[type=text], input[type=password], input[type=number], select { width: 100%; box-sizing: border-box; padding: .5rem .6rem;
    font: inherit; border-radius: 8px; border: 1px solid #4b5563; background: #0b1220; color: inherit; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 0 .8rem; }
  button { padding: .55rem 1.1rem; font: inherit; border-radius: 8px; border: 0; cursor: pointer; background: #f59e0b; color: #1f1300; font-weight: 700; }
  button.secondary { background: #374151; color: #f3f4f6; font-weight: 500; }
  .note { color: #9ca3af; font-size: .9rem; }
  .ok { color: #6ee7b7; } .bad { color: #fca5a5; }
  code { background: #0b1220; padding: .05rem .3rem; border-radius: 4px; word-break: break-all; }
  .code { font: 600 1.4rem/1.2 ui-monospace, monospace; letter-spacing: .08em; color: #fcd34d; }
  a { color: #93c5fd; }
</style></head>
<body><main>
  <h1>Gemini chơi cùng</h1>
  <p class="note">Gemini chỉ huy các máy XOI trong trang game: mỗi vài giây trang game gửi tình hình trận đấu tới relay, relay hỏi
    Gemini bằng khóa API của bạn (khóa chỉ nằm trên VPS này, trang game không thấy), rồi gửi lại lệnh cho từng máy: đánh ai, đánh mạnh
    hay thủ, đứng gần hay xa, giữ bao nhiêu MP. XOI vẫn điều khiển từng khung hình theo lệnh ấy.</p>
  <div class="card">
    <label for="key">Mã quản trị (ADMIN_KEY)</label>
    <input id="key" type="password" autocomplete="current-password" placeholder="in ra khi chạy install-vps.sh">
    <p><button id="load" class="secondary">Xem</button></p>
    <p id="status" role="status" class="note"></p>
  </div>
  <div id="panes" hidden>
  <div class="card">
    <h2>Khóa Gemini API</h2>
    <p id="keystate" class="note"></p>
    <p class="note">Lấy khóa miễn phí ở <a href="https://aistudio.google.com/apikey" target="_blank" rel="noopener">Google AI Studio</a>:
      đăng nhập tài khoản Google, bấm <b>Create API key</b>, chép khóa rồi dán vào đây. Nên dùng khóa của dự án chưa bật thanh toán
      (gói miễn phí): hết lượt thì Gemini chỉ báo lỗi, không mất tiền. Ở gói miễn phí Google có thể dùng nội dung gửi đi (ở đây chỉ là
      tình hình trận đấu) để cải thiện sản phẩm của họ.</p>
    <label for="apikey">Khóa mới</label>
    <input id="apikey" type="password" autocomplete="off" placeholder="dán khóa Gemini API (không hiện lại sau khi lưu)">
    <p><button id="savekey">Lưu khóa</button> <button id="clearkey" class="secondary">Xóa khóa</button></p>
  </div>
  <div class="card">
    <h2>Model và giới hạn</h2>
    <div class="grid">
      <div><label for="model">Model</label><input id="model" type="text" list="models" autocomplete="off" spellcheck="false"><datalist id="models"></datalist></div>
      <div><label for="thinking">Mức suy nghĩ</label><select id="thinking">
        <option value="">Mặc định của model</option><option value="minimal">minimal (nhanh nhất)</option><option value="low">low</option>
        <option value="medium">medium</option><option value="high">high (chậm)</option></select></div>
      <div><label for="perMinute">Tối đa mỗi phút</label><input id="perMinute" type="number" min="0"></div>
      <div><label for="perDay">Tối đa mỗi ngày</label><input id="perDay" type="number" min="0"></div>
    </div>
    <label class="inline"><input id="enabled" type="checkbox"> Cho trang game dùng Gemini</label>
    <p class="note">Model nhanh, rẻ hợp hơn cho trận đấu (trả lời dưới 1–2 giây): <code>gemini-3.5-flash-lite</code>; <code>gemini-3.6-flash</code>
      khôn hơn nhưng chậm hơn. Giới hạn của khóa miễn phí tùy model và tùy tài khoản: xem ở
      <a href="https://aistudio.google.com/rate-limit" target="_blank" rel="noopener">trang giới hạn của AI Studio</a>. Một người chơi hỏi mỗi
      4 giây là 15 lần một phút; 0 là không giới hạn.</p>
    <p><button id="save">Lưu</button> <button id="list" class="secondary">Xem các model của khóa này</button></p>
  </div>
  <div class="card">
    <h2>Mã cho người chơi</h2>
    <p class="code" id="code">—</p>
    <p class="note">Trong trang game, mở phần <b>Gemini chơi cùng</b> (ngay trên khung game) rồi dán mã này vào ô <b>Mã Gemini</b>. Ai có
      mã mới dùng được Gemini qua relay này; đổi mã thì mã cũ hết dùng.</p>
    <p><button id="copy" class="secondary">Chép mã</button> <button id="newcode" class="secondary">Đổi mã</button></p>
  </div>
  <div class="card">
    <h2>Thử và hôm nay</h2>
    <p><button id="test">Thử gọi Gemini</button></p>
    <p id="testresult" class="note"></p>
    <p id="usage" class="note"></p>
  </div>
  </div>
</main>
<script>
  const $ = (id) => document.getElementById(id);
  const base = location.pathname.replace(/\\/+$/, '');
  const api = base + '/api/';
  let state = null;
  try { $('key').value = localStorage.getItem('lf2-admin-key') || ''; } catch (error) {}
  const remember = () => { try { localStorage.setItem('lf2-admin-key', $('key').value); } catch (error) {} };
  function status(text, kind) { $('status').textContent = text; $('status').className = kind || 'note'; }
  async function call(method, what, body) {
    const response = await fetch(api + what, { method, headers: { 'x-admin-key': $('key').value, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body) });
    const text = await response.text();
    let data;
    try { data = JSON.parse(text); } catch (error) { data = { error: text }; }
    if (!response.ok) throw new Error(data.error || ('HTTP ' + response.status));
    return data;
  }
  const time = (iso) => { if (!iso) return ''; const d = new Date(iso); return d.toLocaleString('vi-VN', { hour: '2-digit', minute: '2-digit', second: '2-digit', day: '2-digit', month: '2-digit' }); };
  function render() {
    $('panes').hidden = false;
    $('keystate').textContent = state.configured ? 'Đã có khóa (…' + state.keyEnd + ').' : 'Chưa có khóa: dán khóa ở dưới.';
    $('keystate').className = state.configured ? 'ok' : 'bad';
    for (const name of ['model', 'thinking', 'perMinute', 'perDay']) if (document.activeElement !== $(name)) $(name).value = state[name];
    $('enabled').checked = state.enabled;
    if (!$('models').children.length) for (const name of state.suggested || []) { const o = document.createElement('option'); o.value = name; $('models').appendChild(o); }
    $('code').textContent = state.code || '— (lưu khóa để có mã)';
    let usage = 'Hôm nay đã hỏi Gemini ' + state.calls + ' lần' + (state.perDay ? ' / ' + state.perDay : '') + ', lỗi ' + state.errors + ' lần.';
    if (state.last) usage += ' Lần cuối lúc ' + time(state.last.at) + (state.last.error ? ': lỗi — ' + state.last.error : ': trả lời sau ' + (state.last.ms / 1000).toFixed(1).replace('.', ',') + ' giây.');
    if (!state.stored) usage += ' Relay này không có thư mục lưu (PACKS_DIR): cài đặt mất khi relay khởi động lại.';
    $('usage').textContent = usage;
  }
  async function load(quiet) {
    if (!$('key').value) return status('Nhập mã quản trị trước.', 'bad');
    remember();
    try { state = await call('GET', 'trang-thai'); render(); if (!quiet) status('Đã tải.', 'ok'); }
    catch (error) { status(error.message, 'bad'); }
  }
  $('load').addEventListener('click', () => load(false));
  $('savekey').addEventListener('click', async () => {
    const apiKey = $('apikey').value.trim();
    if (!apiKey) return status('Dán khóa Gemini API vào ô trước.', 'bad');
    try { state = await call('PUT', 'cai-dat', { apiKey }); $('apikey').value = ''; render(); status('Đã lưu khóa. Bấm "Thử gọi Gemini" để xem khóa dùng được không.', 'ok'); }
    catch (error) { status(error.message, 'bad'); }
  });
  $('clearkey').addEventListener('click', async () => {
    if (!confirm('Xóa khóa Gemini API khỏi relay? Trang game sẽ không dùng được Gemini tới khi bạn dán khóa mới.')) return;
    try { state = await call('PUT', 'cai-dat', { clearKey: true }); render(); status('Đã xóa khóa.', 'ok'); }
    catch (error) { status(error.message, 'bad'); }
  });
  $('save').addEventListener('click', async () => {
    try {
      state = await call('PUT', 'cai-dat', { model: $('model').value, thinking: $('thinking').value, perMinute: Number($('perMinute').value),
        perDay: Number($('perDay').value), enabled: $('enabled').checked });
      render(); status('Đã lưu.', 'ok');
    } catch (error) { status(error.message, 'bad'); }
  });
  $('list').addEventListener('click', async () => {
    try {
      const data = await call('GET', 'models');
      $('models').innerHTML = '';
      for (const name of data.models) { const o = document.createElement('option'); o.value = name; $('models').appendChild(o); }
      status('Khóa này dùng được ' + data.models.length + ' model (bấm vào ô Model để chọn): ' + data.models.filter((n) => /flash/.test(n)).slice(0, 12).join(', '), 'ok');
    } catch (error) { status(error.message, 'bad'); }
  });
  $('copy').addEventListener('click', async () => {
    if (!state || !state.code) return;
    try { await navigator.clipboard.writeText(state.code); status('Đã chép mã.', 'ok'); } catch (error) { status('Không chép được: chọn mã rồi chép tay.', 'bad'); }
  });
  $('newcode').addEventListener('click', async () => {
    if (!confirm('Đổi mã cho người chơi? Ai đang dùng mã cũ phải dán mã mới.')) return;
    try { state = await call('POST', 'doi-ma'); render(); status('Đã đổi mã.', 'ok'); }
    catch (error) { status(error.message, 'bad'); }
  });
  $('test').addEventListener('click', async () => {
    $('testresult').textContent = 'Đang hỏi Gemini…';
    $('testresult').className = 'note';
    try {
      const data = await call('POST', 'thu');
      let say = data.text;
      try { say = JSON.parse(data.text).say || data.text; } catch (error) {}
      $('testresult').textContent = 'Gemini (' + data.model + ') trả lời sau ' + (data.ms / 1000).toFixed(1).replace('.', ',') + ' giây: ' + say;
      $('testresult').className = 'ok';
    } catch (error) { $('testresult').textContent = error.message; $('testresult').className = 'bad'; }
    load(true);
  });
  if ($('key').value) load(true);
</script>
</body></html>
`;

module.exports = { createGemini, newCode, SUGGESTED, DEFAULTS };
