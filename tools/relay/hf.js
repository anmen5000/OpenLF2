// SPDX-License-Identifier: MIT
//
// Hero Fighter v0.7+ online, for the game page that runs it in Ruffle (a Flash player). The game was
// made for herofighter.com's small web services (accounts; closed to new players since 2016) and for
// room servers it reaches over TCP. The page points the game's addresses here instead (Ruffle's URL
// rewrites and socket proxy), so that it plays with this relay as it did with those:
//   GET  <relay folder>/hf/ver.txt                    the version check (this version is the newest)
//   GET  <relay folder>/hf/s/v0.7/login.php?em=&pw=   log in; an e-mail address not seen before is a new account
//   GET  <relay folder>/hf/s/v0.7/lu.php?...          the experience the account's characters gained
//   GET  <relay folder>/hf/s/cap.php, reg.php, namechg_left.php, namechg.php, pwdchg.php, pwdret.php
//   GET  <relay folder>/hf/hf/rlg.php                 the room list: this relay's rooms
//   GET  <relay folder>/hf/rooms.json                 the rooms for the page (its socket proxy settings)
//   WebSocket <relay path>?game=hf&room=<n>          room n (hf-room.js)
// Accounts (name, a hash of the password, each character's level and experience, story progress)
// are kept in <PACKS_DIR>/hf/accounts.json (or HF_DIR); every character and story is open from the start.
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { HfRoom, HfConnection, CHARACTERS } = require('./hf-room.js');

const STORIES = 6; // Global.storyChosen_max: the last story episode
const MAX_EXPERIENCE = 16999; // level 16 (the game's highest; more is taken for a cheat), 999 experience
const START_EXPERIENCE = 1000; // level 1, all characters open

// The game checks login answers with a code over the numbers in them (Global.LoginStatusMessage):
// with n = v[8], m = v[9+2n..+7] and x = v[16+2n..+7], (9999998 - x - m) / 3 must be the sum below
// (or that plus id%13 + id%61 + id%107, for a premium account: every character, also the premium ones).
function statusCode(values, id, acctype, stage, session, premium) {
  const sum = (values.reduce((a, b) => a + b, 0) + id + acctype + stage + session % 1000000) % 1000000 + 1000000;
  return encodeNumber(sum + (premium ? id % 13 + id % 61 + id % 107 : 0));
}

// A number the game reads back as (9999998 - x - m) / 3 from the 25-digit form above (and captcha
// codes as that modulo 1000000): random digits around it, as herofighter.com sent.
function encodeNumber(number) {
  const digit = () => String(crypto.randomInt(10));
  const n = crypto.randomInt(10);
  const m = crypto.randomInt(1000000, 2000000);
  const x = 9999998 - 3 * number - m;
  let text = '';
  for (let k = 0; k < 8; k += 1) text += digit();
  text += String(n);
  for (let k = 0; k < n * 2; k += 1) text += digit();
  text += String(m).padStart(7, '0') + String(x).padStart(7, '0');
  for (let k = 0; k < 18 - n * 2; k += 1) text += digit();
  return text;
}

function xmlText(value) {
  return String(value).replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]));
}

// A display name: what the game allows in one (no [ or ], which it uses itself), at most 20 characters.
function cleanName(value) {
  return String(value || '').replace(/[[\]<>&"\u0000-\u001f]/g, '').trim().slice(0, 20);
}

function hashPassword(password, salt) {
  return crypto.scryptSync(String(password), salt, 32).toString('hex');
}

function createAccounts(file, log) {
  let accounts = {};
  let nextId = 1001; // ids up to 20 open the game's developer keys
  let saveTimer = null;
  if (file) {
    try {
      const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
      accounts = saved.accounts || {};
      nextId = Math.max(nextId, Number(saved.nextId) || 0);
    } catch (error) {
      if (error.code !== 'ENOENT') log(`hf accounts: could not read ${file}: ${error.message}`);
    }
  }
  const save = () => {
    if (!file || saveTimer) return;
    saveTimer = setTimeout(() => {
      saveTimer = null;
      try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const temporary = `${file}.${process.pid}.tmp`;
        fs.writeFileSync(temporary, JSON.stringify({ version: 1, nextId, accounts }, null, 1));
        fs.renameSync(temporary, file);
      } catch (error) {
        log(`hf accounts: could not save: ${error.message}`);
      }
    }, 500);
    if (saveTimer.unref) saveTimer.unref();
  };
  return {
    get(email) { return accounts[email] || null; },
    byId(id) { return Object.values(accounts).find((account) => String(account.id) === String(id)) || null; },
    byName(name) { return Object.values(accounts).find((account) => account.name.toLowerCase() === name.toLowerCase()) || null; },
    create(email, password, name, cc) {
      const salt = crypto.randomBytes(12).toString('hex');
      let unique = name || 'Player';
      for (let k = 2; this.byName(unique); k += 1) unique = `${name.slice(0, 17)}${k}`;
      const account = {
        id: nextId++, name: unique, cc: cc || 'VN', salt, hash: hashPassword(password, salt),
        session: crypto.randomInt(100000, 1000000000), values: Array.from({ length: 30 }, (_, k) => (k < 19 ? START_EXPERIENCE : 0)),
        stage: STORIES, nameChanges: 9, created: new Date().toISOString(), // (name changes are not counted down)
      };
      accounts[email] = account;
      save();
      return account;
    },
    checkPassword(account, password) {
      const expected = Buffer.from(account.hash, 'hex');
      const given = Buffer.from(hashPassword(password, account.salt), 'hex');
      return expected.length === given.length && crypto.timingSafeEqual(expected, given);
    },
    setPassword(account, password) {
      account.salt = crypto.randomBytes(12).toString('hex');
      account.hash = hashPassword(password, account.salt);
      save();
    },
    save,
    flush() {
      if (!saveTimer) return;
      clearTimeout(saveTimer);
      saveTimer = null;
      try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ version: 1, nextId, accounts }, null, 1));
      } catch (error) {
        log(`hf accounts: could not save: ${error.message}`);
      }
    },
  };
}

function createHf(config, { log, clientAddress, allowOrigin, budget }) {
  const folder = config.hfDir || (config.packsDir ? path.join(config.packsDir, 'hf') : '');
  const accounts = createAccounts(folder && path.join(folder, 'accounts.json'), log);
  const roomCount = Math.max(1, Math.min(20, Math.round(config.hfRooms || 4)));
  const rooms = [];
  for (let number = 1; number <= roomCount; number += 1) {
    rooms.push(new HfRoom({ number, name: `Phong ${number}`, description: config.hfRoomDescription || 'OpenLF2 relay', log }));
  }
  const captchas = new Map(); // client key -> { code, until }
  const tries = new Map(); // client address -> { count, until }: failed passwords and codes
  const creations = new Map(); // client address -> { count, until }: new accounts
  const mayCreate = (address) => {
    const now = Date.now();
    let entry = creations.get(address);
    if (!entry || entry.until <= now) {
      entry = { count: 0, until: now + 3600000 };
      creations.set(address, entry);
    }
    if (entry.count >= 20) return false;
    entry.count += 1;
    return true;
  };
  const LIMIT = '<en>Too many new accounts from your network: try again in an hour.</en><b5>Too many new accounts from your network: try again in an hour.</b5>';

  function loginXml(account, root = 'login') {
    const values = account.values;
    const fields = values.map((value, index) => `<c${index + 1}>${value}</c${index + 1}>`).join('');
    const code = statusCode(values, account.id, 0, account.stage, account.session, true);
    return `<${root}>${fields}<i>${account.id}</i><n>${xmlText(account.name)}</n><cc>${xmlText(account.cc)}</cc>`
      + `<s>${account.session}</s><acctype>0</acctype><stage>${account.stage}</stage><v>${code}</v></${root}>`;
  }

  const prune = () => {
    const now = Date.now();
    for (const map of [tries, creations]) for (const [key, entry] of map) if (entry.until <= now) map.delete(key);
    for (const [key, entry] of captchas) if (entry.until <= now) captchas.delete(key);
  };
  const pruneTimer = setInterval(prune, 600000);
  if (pruneTimer.unref) pruneTimer.unref();

  function tooManyTries(address) {
    const now = Date.now();
    const entry = tries.get(address);
    return Boolean(entry && entry.until > now && entry.count >= 30);
  }
  function failedTry(address) {
    const now = Date.now();
    let entry = tries.get(address);
    if (!entry || entry.until <= now) {
      entry = { count: 0, until: now + 3600000 };
      tries.set(address, entry);
    }
    entry.count += 1;
  }

  function checkCaptcha(key, code) {
    const entry = captchas.get(String(key || ''));
    captchas.delete(String(key || ''));
    return Boolean(entry && entry.until > Date.now() && String(entry.code) === String(code || '').trim());
  }

  const email = (value) => String(value || '').trim().toLowerCase().slice(0, 100);

  // The answer to one of the account services, from the query (and a form body, if any).
  function answer(service, params, address) {
    const get = (name) => params.get(name) || '';
    if (service === 'v0.7/login.php') {
      const em = email(get('em'));
      if (!em) return '<login><error>em</error></login>';
      if (tooManyTries(address)) return '<login><error>reason</error><en>Too many wrong passwords: try again in an hour.</en><b5>Too many wrong passwords: try again in an hour.</b5></login>';
      let account = accounts.get(em);
      if (!account) {
        if (!mayCreate(address)) return `<login><error>reason</error>${LIMIT}</login>`;
        account = accounts.create(em, get('pw'), cleanName(em.split('@')[0]), 'VN');
        log(`hf: new account ${account.id} "${account.name}"`);
      } else if (!accounts.checkPassword(account, get('pw'))) {
        failedTry(address);
        return '<login><error>pw</error></login>';
      }
      return loginXml(account);
    }
    if (service === 'v0.7/lu.php') {
      const account = accounts.get(email(get('em')));
      if (!account || String(account.id) !== get('id') || String(account.session) !== get('s')) return '<lu><error>sa</error></lu>';
      for (let k = 1; k <= 3; k += 1) {
        const index = Number(get(`i${k}`));
        const to = Number(get(`to${k}`));
        if (!Number.isInteger(index) || index < 1 || index > CHARACTERS.length - 1 || !Number.isFinite(to)) continue;
        account.values[index - 1] = Math.max(account.values[index - 1], Math.min(MAX_EXPERIENCE, Math.floor(to)));
      }
      const unlocked = Number(get('uli'));
      if (Number.isInteger(unlocked) && unlocked >= 1 && unlocked <= 30) {
        account.values[unlocked - 1] = Math.max(account.values[unlocked - 1], START_EXPERIENCE);
      }
      const stage = Number(get('stg'));
      if (Number.isInteger(stage)) account.stage = Math.max(account.stage, Math.min(STORIES, stage));
      accounts.save();
      return loginXml(account, 'lu');
    }
    if (service === 'cap.php') {
      const key = crypto.randomBytes(8).toString('hex');
      const code = crypto.randomInt(1000, 10000);
      captchas.set(key, { code, until: Date.now() + 600000 });
      if (captchas.size > 2000) captchas.delete(captchas.keys().next().value);
      return `<cap><c1>${key}</c1><c2>${encodeNumber(code)}</c2></cap>`;
    }
    if (service === 'reg.php') {
      if (!checkCaptcha(get('c'), get('s'))) return '<reg><error>code</error></reg>';
      const em = email(get('em'));
      if (!em || accounts.get(em)) return '<reg><error>sameemail</error></reg>';
      const name = cleanName(get('nm'));
      if (!name) return '<reg><error>name</error></reg>';
      if (accounts.byName(name)) return '<reg><error>samename</error></reg>';
      if (!mayCreate(address)) return `<reg><error>limit</error>${LIMIT}</reg>`;
      const account = accounts.create(em, get('pw'), name, String(get('cc')).replace(/[^A-Z]/g, '').slice(0, 2) || 'VN');
      log(`hf: new account ${account.id} "${account.name}" (registered)`);
      return loginXml(account, 'reg');
    }
    const byId = () => {
      const account = accounts.get(email(get('em')));
      return account && String(account.id) === get('id') && String(account.session) === get('ss') ? account : null;
    };
    if (service === 'namechg_left.php') {
      const account = accounts.byId(get('id'));
      return `<namechg><n>${account ? account.nameChanges : 0}</n></namechg>`;
    }
    if (service === 'namechg.php') {
      if (!checkCaptcha(get('c'), get('s'))) return '<namechg><error>code</error></namechg>';
      const account = byId();
      if (!account) return '<namechg><error>sa</error></namechg>';
      if (!accounts.checkPassword(account, get('pw'))) { failedTry(address); return '<namechg><error>pwd</error></namechg>'; }
      const name = cleanName(get('nn'));
      if (!name) return '<namechg><error>name</error></namechg>';
      const other = accounts.byName(name);
      if (other && other !== account) return '<namechg><error>samename</error></namechg>';
      account.name = name;
      accounts.save();
      return `<namechg><m>${account.nameChanges}</m></namechg>`;
    }
    if (service === 'pwdchg.php') {
      if (!checkCaptcha(get('c'), get('s'))) return '<pwdchg><error>code</error></pwdchg>';
      const account = byId();
      if (!account) return '<pwdchg><error>sa</error></pwdchg>';
      if (!accounts.checkPassword(account, get('pw'))) { failedTry(address); return '<pwdchg><error>pwd</error></pwdchg>'; }
      accounts.setPassword(account, get('npw'));
      return '<pwdchg><ok>1</ok></pwdchg>';
    }
    if (service === 'pwdret.php') {
      // No e-mail goes out from here: whoever runs the relay can remove the account instead.
      return '<pwdret><error>mail</error></pwdret>';
    }
    return null;
  }

  function roomListXml() {
    let text = '<roomlist>';
    for (const room of rooms) {
      text += `<room><t>1</t><rn>${xmlText(room.name)}</rn><dc>${xmlText(room.description)}</dc><cc>${room.cc}</cc>`
        + `<n>${room.connected}</n><nl>${room.limit}</nl><ppl>${xmlText(room.people())}</ppl>`
        + `<ip>${HOST}</ip><pt>${PORT + room.number - 1}</pt></room>`;
    }
    return text + '</roomlist>';
  }

  // Returns true when the request was one of these and has been answered (or is being answered).
  function handle(req, res, pathname) {
    if (!pathname.startsWith('/hf/')) return false;
    const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...allowOrigin(req) };
    if (req.method === 'OPTIONS') {
      res.writeHead(204, { ...headers, 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-allow-headers': 'content-type' });
      res.end();
      return true;
    }
    const send = (status, type, body) => {
      res.writeHead(status, { ...headers, 'content-type': type });
      res.end(body);
    };
    if (req.method !== 'GET' && req.method !== 'POST') {
      send(405, 'text/plain; charset=utf-8', 'method not allowed\n');
      return true;
    }
    const url = new URL(req.url, 'http://relay.invalid');
    const local = pathname.slice('/hf/'.length);
    if (local === 'ver.txt') {
      send(200, 'text/xml; charset=utf-8', '<ver><res version="700" local="0" /></ver>');
      return true;
    }
    if (local === 'rooms.json') {
      send(200, 'application/json; charset=utf-8', JSON.stringify({
        host: HOST, rooms: rooms.map((room) => ({ room: room.number, port: PORT + room.number - 1, name: room.name, players: room.connected, limit: room.limit })),
      }));
      return true;
    }
    if (local === 'hf/rlg.php') {
      send(200, 'text/xml; charset=utf-8', roomListXml());
      return true;
    }
    if (local.startsWith('s/')) {
      // The game posts its forms with the values in the address; a body, if any, is read as a form too.
      let body = '';
      req.setEncoding('utf8');
      req.on('data', (chunk) => { if (body.length < 8192) body += chunk; });
      req.on('end', () => {
        const params = new URLSearchParams(url.search);
        if (body && /^[\w%.+=&-]*$/.test(body)) for (const [key, value] of new URLSearchParams(body)) if (!params.has(key)) params.set(key, value);
        let reply;
        try {
          reply = answer(local.slice(2), params, clientAddress(req));
        } catch (error) {
          log(`hf: ${local}: ${error.stack || error}`);
          reply = '<error><error>server</error></error>';
        }
        if (reply === null) send(404, 'text/plain; charset=utf-8', 'not found\n');
        else send(200, 'text/xml; charset=utf-8', reply);
      });
      return true;
    }
    send(404, 'text/plain; charset=utf-8', 'not found\n');
    return true;
  }

  // A game's socket to room n, through the page's WebSocket.
  function connect(ws, req, url) {
    const number = Number(url.searchParams.get('room'));
    const room = rooms[number - 1];
    if (!Number.isInteger(number) || !room) {
      ws.close(4000, 'Relay: no such Hero Fighter room');
      return;
    }
    const connection = new HfConnection(room, {
      write(text) {
        if (ws.readyState !== 1) return;
        if (ws.bufferedAmount > config.maxBufferedBytes) {
          ws.close(4016, 'Relay: your connection is too slow for the game');
          return;
        }
        ws.send(Buffer.from(text, 'utf8'), { binary: true });
      },
      close() { if (ws.readyState === 0 || ws.readyState === 1) ws.close(1000, 'Relay: room left'); },
    }, { address: clientAddress(req) });
    ws.on('message', (data) => {
      if (budget && !budget(ws, data.length)) {
        ws.close(4007, 'Relay: too much traffic');
        return;
      }
      connection.receive(Buffer.isBuffer(data) ? data : Buffer.from(data));
    });
    ws.on('close', () => connection.closed());
  }

  return {
    handle,
    connect,
    rooms,
    accounts,
    describe: () => ({ rooms: rooms.length, players: rooms.reduce((sum, room) => sum + room.connected, 0) }),
    close() {
      clearInterval(pruneTimer);
      for (const room of rooms) room.close();
      accounts.flush();
    },
  };
}

// The address the game is given for the rooms: any name works, the page's socket proxy maps it (with
// the port, one per room) to the relay's WebSocket.
const HOST = 'hf.openlf2';
const PORT = 8888;

module.exports = { createHf, statusCode, encodeNumber, HOST, PORT };
