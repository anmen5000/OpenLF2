// SPDX-License-Identifier: MIT
//
// Reinforcement learning on many machines (package 90): the relay hands the fighters of a job out to the
// machines that ask for work (the XOI kit's may-con.bat, one fighter to each slot of a machine) and keeps what
// a machine sends back when its fighter is done (tom-tat.txt, xac-nhan.txt, the chosen network), for the
// owner's machine to download (dua-bo-nao-vao-mod.bat). The machines do the learning (hoc-tang-cuong.bat); the
// relay only passes small text files, about 1 MB a fighter, and the mod once to each machine that asks for it.
//
// The job is set on the page /hoc with ADMIN_KEY; the machines use the job's own key (X-Hoc-Key), which the page
// writes into the file may-con-cai-dat.bat it gives out. Kept in HOC_DIR (default <PACKS_DIR>/hoc): viec.json
// (the job and every fighter's state) and nv/<fighter>/ (the files sent back).
//
//   GET    /hoc                           the page
//   GET    /hoc/api/trang-thai            the job and its fighters (JSON; X-Admin-Key)
//   PUT    /hoc/api/cai-dat               the mod and the settings: {"pack","settings"} (X-Admin-Key)
//   POST   /hoc/api/them                  add fighters: {"fighters":"16 25 8"} (X-Admin-Key)
//   POST   /hoc/api/tra-lai/<fighter>     hand it out again (X-Admin-Key)
//   DELETE /hoc/api/nv/<fighter>          take it off the job, with its files (X-Admin-Key)
//   POST   /hoc/api/viec-moi              a new job: every fighter goes, with its files - the key, the mod and the
//                                         settings stay (X-Admin-Key; package 94). The results are kept by fighter
//                                         (an id, or a name), and two mods mostly share ids: the job of a mod done,
//                                         a new one keeps its results from being taken for the next mod's.
//   POST   /hoc/api/doi-ma                a new key for the machines (X-Admin-Key)
// The machines' requests (X-Hoc-Key, or X-Admin-Key; answers as KEY=value lines, which a .bat file reads, and
// LOI=<what went wrong> with an error status):
//   GET    /hoc/api/viec                  the settings, and the mod's PACK_ID and PACK_SHA256 (none: each machine's own)
//   GET    /hoc/api/ban-mod               the job's mod (one of the relay's packs)
//   POST   /hoc/api/nhan?may=<slot>       the fighter that slot holds, else the next waiting one (NV=...), or HET=1
//   POST   /hoc/api/bao/<fighter>?may=<slot>&vong=<n>   a check's lines (the body), as it learns
//   PUT    /hoc/api/nop/<fighter>/<file>?may=<slot>     a file of its results (the body)
//   POST   /hoc/api/xong/<fighter>?may=<slot>           done (tom-tat.txt sent before)
//   POST   /hoc/api/loi/<fighter>?may=<slot>            failed (the body: the end of its account)
//   POST   /hoc/api/tra/<fighter>?may=<slot>            given back: that machine cannot learn (no game, no mod...),
//                                                        another may take it (package 91)
//   GET    /hoc/api/ket-qua               the fighters done: "<fighter> <file> <file>..." lines
//   GET    /hoc/api/tep/<fighter>/<file>  one of their files
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

// A fighter as hoc-tang-cuong.bat takes it (an id, or a name the mod knows) and the folder named after it.
const FIGHTER = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/;
// A machine's slot, as may-con.bat names it: <machine>-o<n>.
const SLOT = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
// The files of a fighter's results that a machine may send.
const RESULT = /^(tom-tat|xac-nhan|tot-nhat|bo-nao-tot-nhat|bo-nao-[0-9]{1,6}|xac-nhan-[0-9]{1,6}|kiem-tra-[0-9]{1,6})\.txt$/;
const PACK_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;
const MIB = 1024 * 1024;
const FILE_LIMIT = 16 * MIB;
const FIGHTER_LIMIT = 64 * MIB;
const TEXT_LIMIT = 64 * 1024;
const MAX_FIGHTERS = 2000;
// The settings a machine learns a fighter with (hoc-tang-cuong.bat's names): default, least, most. MOI_NV is
// how many processes a fighter gets: a machine takes as many fighters at once as it has threads for. DUNG_SOM
// (package 97): a fighter whose checks have not got better for that many rounds stops early (0: never), and its
// slot takes the next one; VONG is then the most it learns.
const SETTINGS = {
  VONG: [500, 1, 100000],
  TRAN: [20, 1, 1000],
  KIEM_TRA_MOI: [50, 0, 100000],
  TRAN_KIEM_TRA: [12, 1, 1000],
  TRAN_XAC_NHAN: [720, 0, 1000000],
  MOI_NV: [33, 1, 1024],
  DUNG_SOM: [400, 0, 100000],
};
const STATES = new Set(['cho', 'dang', 'xong', 'loi']);

function sameKey(given, expected) {
  const a = crypto.createHash('sha256').update(String(given || '')).digest();
  const b = crypto.createHash('sha256').update(String(expected)).digest();
  return crypto.timingSafeEqual(a, b);
}

class Answer extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function cleanSettings(given) {
  const settings = {};
  for (const [name, [fallback, least, most]] of Object.entries(SETTINGS)) {
    const value = Number(given && given[name]);
    settings[name] = Number.isInteger(value) && value >= least && value <= most ? value : fallback;
  }
  return settings;
}

function cleanFighter(given) {
  const text = (value, limit = 200) => (typeof value === 'string' ? value.slice(0, limit) : '');
  const number = (value) => (typeof value === 'number' && Number.isFinite(value) ? value : null);
  return {
    state: STATES.has(given.state) ? given.state : 'cho',
    may: SLOT.test(given.may || '') ? given.may : '',
    since: text(given.since, 40),
    updated: text(given.updated, 40),
    vong: Number.isInteger(given.vong) ? given.vong : 0,
    kiem: number(given.kiem), // the last check's "network - XOI", points per 100 games
    ten: text(given.ten, 60), // the fighter's name in the mod, from tom-tat.txt
    chon: Number.isInteger(given.chon) ? given.chon : 0, // the round of the network chosen (xac-nhan.txt)
    diem: number(given.diem), // its score on new games, points per 100 games
    cuoi: Number.isInteger(given.cuoi) ? given.cuoi : 0, // the rounds it learned (tom-tat.txt's last KET THUC line)
    dung: given.dung === true, // it stopped early: no better for DUNG_SOM rounds
    files: Array.isArray(given.files) ? given.files.filter((name) => RESULT.test(name)) : [],
    loi: text(given.loi, 2000),
    xong: text(given.xong, 40),
  };
}

// "network - XOI +38.0 points" of a check's greedy line.
function checkScore(text) {
  const line = String(text).split(/\r?\n/).find((one) => /greedy/.test(one)) || String(text);
  const found = line.match(/network - XOI ([+-]?[0-9.]+) points/);
  return found ? Number(found[1]) : null;
}

function createHoc(config, { log = () => {}, clientAddress = (req) => req.socket.remoteAddress || 'unknown' } = {}) {
  const directory = config.hocDir || (config.packsDir ? path.join(config.packsDir, 'hoc') : '');
  const failures = new Map(); // client address -> { count, until }: wrong keys
  const job = load();

  function blank() {
    return { key: '', pack: '', settings: cleanSettings({}), order: [], fighters: {} };
  }

  function load() {
    const fresh = blank();
    if (!directory) return fresh;
    let data;
    try { data = JSON.parse(fs.readFileSync(path.join(directory, 'viec.json'), 'utf8')); } catch { return fresh; }
    if (typeof data.key === 'string' && /^[a-f0-9]{24,64}$/.test(data.key)) fresh.key = data.key;
    if (typeof data.pack === 'string' && PACK_ID.test(data.pack)) fresh.pack = data.pack;
    fresh.settings = cleanSettings(data.settings);
    for (const id of Array.isArray(data.order) ? data.order : []) {
      if (typeof id !== 'string' || !FIGHTER.test(id) || fresh.fighters[id]) continue;
      fresh.order.push(id);
      fresh.fighters[id] = cleanFighter((data.fighters && data.fighters[id]) || {});
    }
    return fresh;
  }

  function save() {
    if (!directory) return;
    fs.mkdirSync(directory, { recursive: true });
    const file = path.join(directory, 'viec.json');
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(job, null, 1));
    fs.renameSync(`${file}.tmp`, file);
  }

  const folder = (id) => path.join(directory, 'nv', id);
  const now = () => new Date().toISOString();

  function counted(address) {
    const time = Date.now();
    let entry = failures.get(address);
    if (!entry || entry.until <= time) {
      entry = { count: 0, until: time + 3600000 };
      failures.set(address, entry);
    }
    return entry;
  }

  // ADMIN_KEY, or (machine = true) the job's key as well.
  function authorize(req, machine) {
    const tries = counted(clientAddress(req));
    if (tries.count >= 30) throw new Answer(429, 'Sai ma qua nhieu lan, thu lai sau mot gio.');
    const admin = config.adminKey && sameKey(req.headers['x-admin-key'], config.adminKey);
    const worker = machine && job.key && sameKey(req.headers['x-hoc-key'], job.key);
    if (admin || worker) return;
    tries.count += 1;
    if (!config.adminKey) throw new Answer(403, 'Chua dat ADMIN_KEY cho relay (chay lai install-vps.sh).');
    if (machine && !job.key) throw new Answer(403, 'Chua co viec: dat viec o trang /hoc truoc.');
    throw new Answer(401, machine ? 'Sai ma may con (HOC_KEY): lay lai file may-con-cai-dat.bat o trang /hoc.'
      : 'Sai ma quan tri (ADMIN_KEY).');
  }

  function readBody(req, limit) {
    return new Promise((resolve, reject) => {
      const declared = Number(req.headers['content-length'] || 0);
      if (declared > limit) {
        req.resume();
        reject(new Answer(413, `Qua lon (toi da ${Math.round(limit / 1024)} KB).`));
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
      req.on('end', () => (over ? reject(new Answer(413, `Qua lon (toi da ${Math.round(limit / 1024)} KB).`))
        : resolve(Buffer.concat(chunks))));
      req.on('error', reject);
    });
  }

  // One line each, LF only: cmd's for /f reads them as they are.
  function lines(res, status, list) {
    res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
    res.end(list.map((line) => `${line}\n`).join(''));
  }

  function json(res, status, body) {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify(body));
  }

  function settingsLines() {
    const list = Object.entries(job.settings).map(([name, value]) => `${name}=${value}`);
    const pack = packInfo();
    if (pack) list.push(`PACK_ID=${pack.id}`, `PACK_SHA256=${pack.sha256}`);
    return list;
  }

  // The job's mod, when it is one of the relay's packs: its file and SHA-256 (packs.js keeps <id>.json beside it).
  function packInfo() {
    if (!job.pack || !config.packsDir) return null;
    try {
      const info = JSON.parse(fs.readFileSync(path.join(config.packsDir, `${job.pack}.json`), 'utf8'));
      const file = path.join(config.packsDir, `${job.pack}.zip`);
      if (!/^[a-f0-9]{64}$/.test(String(info.sha256 || '')) || !fs.statSync(file).isFile()) return null;
      return { id: job.pack, sha256: info.sha256, file };
    } catch {
      return null;
    }
  }

  function fighterOf(id) {
    if (!FIGHTER.test(id || '') || !job.fighters[id]) throw new Answer(404, `Khong co nhan vat ${String(id).slice(0, 40)} trong viec.`);
    return job.fighters[id];
  }

  // A machine's request about a fighter it holds.
  function held(id, slot) {
    const fighter = fighterOf(id);
    if (fighter.state !== 'dang' || fighter.may !== slot) {
      throw new Answer(409, `Nhan vat ${id} khong con giao cho ${slot} (da tra lai hang doi o trang /hoc?).`);
    }
    return fighter;
  }

  function slotOf(params) {
    const slot = params.get('may') || '';
    if (!SLOT.test(slot)) throw new Answer(400, 'Thieu ten may (may=...).');
    return slot;
  }

  async function sizeOf(dir) {
    let total = 0;
    let names = [];
    try { names = await fsp.readdir(dir); } catch { return 0; }
    for (const name of names) {
      try { total += (await fsp.stat(path.join(dir, name))).size; } catch { /* gone */ }
    }
    return total;
  }

  async function route(req, res, parts, params) {
    const [what, id, file] = parts;
    const method = req.method;
    // --- the page's (ADMIN_KEY) ---
    if (what === 'trang-thai' && parts.length === 1 && method === 'GET') {
      authorize(req, false);
      const fighters = job.order.map((one) => ({ id: one, ...job.fighters[one] }));
      let bytes = 0;
      if (directory) for (const one of job.order) bytes += await sizeOf(folder(one));
      json(res, 200, { key: job.key, pack: job.pack, settings: job.settings, fighters, stored: Boolean(directory), bytes });
      return;
    }
    if (what === 'cai-dat' && parts.length === 1 && method === 'PUT') {
      authorize(req, false);
      const body = JSON.parse((await readBody(req, TEXT_LIMIT)).toString('utf8') || '{}');
      if (body.pack !== undefined) {
        if (body.pack !== '' && !PACK_ID.test(String(body.pack))) throw new Answer(400, 'Ma ban mod khong hop le.');
        job.pack = String(body.pack);
      }
      if (body.settings) job.settings = cleanSettings({ ...job.settings, ...body.settings });
      if (!job.key) job.key = crypto.randomBytes(16).toString('hex');
      save();
      json(res, 200, { ok: true, pack: job.pack, settings: job.settings, key: job.key });
      return;
    }
    if (what === 'them' && parts.length === 1 && method === 'POST') {
      authorize(req, false);
      const body = JSON.parse((await readBody(req, TEXT_LIMIT)).toString('utf8') || '{}');
      const names = String(body.fighters || '').split(/[\s,;]+/).filter(Boolean);
      const bad = names.filter((name) => !FIGHTER.test(name));
      if (bad.length) throw new Answer(400, `Ten khong hop le: ${bad.slice(0, 5).join(' ')}`);
      const added = [];
      const skipped = []; // in the job before: not added again (a name twice in the list is only added once)
      const before = new Set(job.order);
      for (const name of names) {
        if (job.fighters[name]) {
          if (before.has(name) && !skipped.includes(name)) skipped.push(name);
          continue;
        }
        if (job.order.length >= MAX_FIGHTERS) throw new Answer(400, `Toi da ${MAX_FIGHTERS} nhan vat.`);
        job.order.push(name);
        job.fighters[name] = cleanFighter({});
        added.push(name);
      }
      if (!job.key) job.key = crypto.randomBytes(16).toString('hex');
      save();
      json(res, 200, { ok: true, added, skipped });
      return;
    }
    if (what === 'tra-lai' && parts.length === 2 && method === 'POST') {
      authorize(req, false);
      const fighter = fighterOf(id);
      Object.assign(fighter, cleanFighter({ ten: fighter.ten }));
      save();
      // From the start on whichever machine takes it: what an earlier one sent goes.
      if (directory) await fsp.rm(folder(id), { recursive: true, force: true });
      json(res, 200, { ok: true });
      return;
    }
    if (what === 'nv' && parts.length === 2 && method === 'DELETE') {
      authorize(req, false);
      fighterOf(id);
      delete job.fighters[id];
      job.order = job.order.filter((one) => one !== id);
      save();
      if (directory) await fsp.rm(folder(id), { recursive: true, force: true });
      json(res, 200, { ok: true });
      return;
    }
    if (what === 'viec-moi' && parts.length === 1 && method === 'POST') {
      authorize(req, false);
      const removed = job.order.length;
      job.order = [];
      job.fighters = {};
      save();
      // A machine still learning one of them is told it is not the job's any more when it sends its results, and
      // takes the next fighter.
      if (directory) await fsp.rm(path.join(directory, 'nv'), { recursive: true, force: true });
      log(`hoc: a new job (${removed} fighters taken off)`);
      json(res, 200, { ok: true, removed });
      return;
    }
    if (what === 'doi-ma' && parts.length === 1 && method === 'POST') {
      authorize(req, false);
      job.key = crypto.randomBytes(16).toString('hex');
      save();
      json(res, 200, { ok: true, key: job.key });
      return;
    }
    // --- the machines' (X-Hoc-Key) ---
    if (what === 'viec' && parts.length === 1 && method === 'GET') {
      authorize(req, true);
      lines(res, 200, settingsLines());
      return;
    }
    if (what === 'ban-mod' && parts.length === 1 && (method === 'GET' || method === 'HEAD')) {
      authorize(req, true);
      const pack = packInfo();
      if (!pack) throw new Answer(404, 'Viec nay khong dung ban mod cua relay: moi may dat file zip ban mod canh may-con.bat.');
      const stat = await fsp.stat(pack.file);
      res.writeHead(200, { 'content-type': 'application/zip', 'content-length': String(stat.size), 'cache-control': 'no-store' });
      if (method === 'HEAD') {
        res.end();
        return;
      }
      const stream = fs.createReadStream(pack.file);
      stream.on('error', () => res.destroy());
      stream.pipe(res);
      return;
    }
    if (what === 'nhan' && parts.length === 1 && method === 'POST') {
      authorize(req, true);
      const slot = slotOf(params);
      let id = job.order.find((one) => job.fighters[one].state === 'dang' && job.fighters[one].may === slot);
      if (!id) {
        id = job.order.find((one) => job.fighters[one].state === 'cho');
        if (!id) {
          lines(res, 200, ['HET=1']);
          return;
        }
        const fighter = job.fighters[id];
        Object.assign(fighter, cleanFighter({ ten: fighter.ten }), { state: 'dang', may: slot, since: now(), updated: now() });
        save();
        log(`hoc: ${id} -> ${slot}`);
      }
      lines(res, 200, [`NV=${id}`, ...settingsLines()]);
      return;
    }
    if (what === 'bao' && parts.length === 2 && method === 'POST') {
      authorize(req, true);
      const fighter = held(id, slotOf(params));
      const text = (await readBody(req, TEXT_LIMIT)).toString('utf8');
      const round = Number(params.get('vong'));
      if (Number.isInteger(round) && round >= 0) fighter.vong = round;
      const score = checkScore(text);
      if (score !== null) fighter.kiem = score;
      fighter.updated = now();
      save();
      lines(res, 200, ['OK=1']);
      return;
    }
    if (what === 'nop' && parts.length === 3 && method === 'PUT') {
      authorize(req, true);
      held(id, slotOf(params));
      if (!RESULT.test(file || '')) throw new Answer(400, `Khong nhan file ${String(file).slice(0, 60)}.`);
      if (!directory) throw new Answer(503, 'Relay nay khong giu file (chua dat PACKS_DIR hay HOC_DIR).');
      const body = await readBody(req, FILE_LIMIT);
      const dir = folder(id);
      await fsp.mkdir(dir, { recursive: true });
      let existing = 0;
      try { existing = (await fsp.stat(path.join(dir, file))).size; } catch { /* new */ }
      if ((await sizeOf(dir)) - existing + body.length > FIGHTER_LIMIT) throw new Answer(413, 'Qua nhieu file cho mot nhan vat.');
      const temporary = path.join(dir, `.${file}.tmp`);
      await fsp.writeFile(temporary, body);
      await fsp.rename(temporary, path.join(dir, file));
      lines(res, 200, ['OK=1']);
      return;
    }
    if (what === 'xong' && parts.length === 2 && method === 'POST') {
      authorize(req, true);
      const slot = slotOf(params);
      const fighter = held(id, slot);
      const dir = folder(id);
      let account;
      try { account = await fsp.readFile(path.join(dir, 'tom-tat.txt'), 'utf8'); } catch {
        throw new Answer(400, 'Chua gui tom-tat.txt.');
      }
      const name = account.match(/nhan vat (.+?) \(id (-?\d+)\)/);
      fighter.ten = name ? name[1].slice(0, 60) : fighter.ten;
      fighter.chon = 0;
      fighter.diem = null;
      // The rounds learned and whether it stopped early: the last KET THUC line (package 97; none before).
      const ends = [...account.matchAll(/^KET THUC: (\d+) vong( - dung som)?/gm)];
      const end = ends.length ? ends[ends.length - 1] : null;
      fighter.cuoi = end ? Number(end[1]) : 0;
      fighter.dung = Boolean(end && end[2]);
      try {
        const [round, tenths] = (await fsp.readFile(path.join(dir, 'xac-nhan.txt'), 'utf8')).trim().split(/\s+/).map(Number);
        if (Number.isInteger(round) && Number.isFinite(tenths)) {
          fighter.chon = round;
          fighter.diem = tenths / 10;
        }
      } catch { /* not confirmed */ }
      fighter.files = (await fsp.readdir(dir)).filter((one) => RESULT.test(one)).sort();
      Object.assign(fighter, { state: 'xong', xong: now(), updated: now(), loi: '' });
      save();
      log(`hoc: ${id} done on ${slot}`);
      lines(res, 200, ['OK=1']);
      return;
    }
    if (what === 'loi' && parts.length === 2 && method === 'POST') {
      authorize(req, true);
      const fighter = held(id, slotOf(params));
      const text = (await readBody(req, TEXT_LIMIT)).toString('utf8');
      Object.assign(fighter, { state: 'loi', loi: text.slice(-2000), updated: now() });
      save();
      log(`hoc: ${id} failed on ${fighter.may}`);
      lines(res, 200, ['OK=1']);
      return;
    }
    if (what === 'tra' && parts.length === 2 && method === 'POST') {
      authorize(req, true);
      const slot = slotOf(params);
      const fighter = held(id, slot);
      Object.assign(fighter, cleanFighter({ ten: fighter.ten }));
      save();
      if (directory) await fsp.rm(folder(id), { recursive: true, force: true });
      log(`hoc: ${id} given back by ${slot}`);
      lines(res, 200, ['OK=1']);
      return;
    }
    if (what === 'ket-qua' && parts.length === 1 && method === 'GET') {
      authorize(req, true);
      lines(res, 200, job.order.filter((one) => job.fighters[one].state === 'xong' && job.fighters[one].files.length)
        .map((one) => [one, ...job.fighters[one].files].join(' ')));
      return;
    }
    if (what === 'tep' && parts.length === 3 && method === 'GET') {
      authorize(req, true);
      fighterOf(id);
      if (!RESULT.test(file || '') || !directory) throw new Answer(404, 'Khong co file nay.');
      let body;
      try { body = await fsp.readFile(path.join(folder(id), file)); } catch { throw new Answer(404, 'Khong co file nay.'); }
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'content-length': String(body.length), 'cache-control': 'no-store' });
      res.end(body);
      return;
    }
    throw new Answer(404, 'Khong co yeu cau nay.');
  }

  // Returns true when the request was the job's and has been answered (or is being answered).
  function handle(req, res, pathname) {
    if (pathname === '/hoc' || pathname === '/hoc/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
        'x-frame-options': 'DENY', 'referrer-policy': 'no-referrer' });
      res.end(PAGE);
      return true;
    }
    if (!pathname.startsWith('/hoc/api/')) return false;
    const params = new URL(req.url, 'http://relay.invalid').searchParams;
    const parts = pathname.slice('/hoc/api/'.length).split('/').map((part) => {
      try { return decodeURIComponent(part); } catch { return '\u0000'; }
    });
    route(req, res, parts, params).catch((error) => {
      const status = error instanceof Answer ? error.status : (error instanceof SyntaxError ? 400 : 500);
      if (status === 500) log('hoc:', error && error.stack ? error.stack : error);
      if (res.headersSent) {
        res.destroy();
        return;
      }
      const message = error instanceof Answer ? error.message : (status === 400 ? 'Yeu cau hong.' : 'Loi tren relay.');
      if (pathname.startsWith('/hoc/api/trang-thai') || pathname.startsWith('/hoc/api/cai-dat') || pathname.startsWith('/hoc/api/them')
        || pathname.startsWith('/hoc/api/tra-lai') || pathname.startsWith('/hoc/api/nv') || pathname.startsWith('/hoc/api/doi-ma')
        || pathname.startsWith('/hoc/api/viec-moi')) {
        json(res, status, { error: message });
      } else {
        lines(res, status, [`LOI=${message}`]);
      }
    });
    return true;
  }

  return {
    handle,
    cleanup: () => {
      const time = Date.now();
      for (const [address, entry] of failures) if (entry.until <= time) failures.delete(address);
    },
    state: () => job,
  };
}

// The page at /hoc (Vietnamese: the relay's owner reads it). The admin key is the one /admin remembers.
const PAGE = `<!doctype html>
<html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenLF2 relay: học tăng cường nhiều máy</title>
<style>
  body { margin: 0; padding: 1.5rem; background: #111827; color: #f3f4f6; font: 16px/1.5 system-ui, sans-serif; }
  main { max-width: 900px; margin: auto; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
  h2 { font-size: 1.15rem; margin: 0 0 .5rem; }
  .card { background: #1f2937; border: 1px solid #374151; border-radius: 12px; padding: 1rem 1.2rem; margin: 1rem 0; }
  label { display: block; margin: .6rem 0 .2rem; font-weight: 600; }
  input[type=text], input[type=password], input[type=number], select, textarea { width: 100%; box-sizing: border-box; padding: .5rem .6rem;
    font: inherit; border-radius: 8px; border: 1px solid #4b5563; background: #0b1220; color: inherit; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 0 .8rem; }
  button { padding: .55rem 1.1rem; font: inherit; border-radius: 8px; border: 0; cursor: pointer; background: #f59e0b; color: #1f1300; font-weight: 700; }
  button.secondary { background: #374151; color: #f3f4f6; font-weight: 500; }
  button.small { padding: .2rem .6rem; font-size: .85rem; }
  .note { color: #9ca3af; font-size: .9rem; }
  .ok { color: #6ee7b7; } .bad { color: #fca5a5; } .run { color: #fcd34d; }
  table { width: 100%; border-collapse: collapse; } td, th { text-align: left; padding: .4rem .3rem; border-bottom: 1px solid #374151; vertical-align: top; }
  code { background: #0b1220; padding: .05rem .3rem; border-radius: 4px; word-break: break-all; }
  .wrap { overflow-x: auto; }
</style></head>
<body><main>
  <h1>Học tăng cường trên nhiều máy</h1>
  <p class="note">Relay giữ danh sách nhân vật cần học và chia cho các máy con (file <code>may-con.bat</code> của bộ XOI): mỗi máy
    học vài nhân vật một lúc bằng <code>hoc-tang-cuong.bat</code>, xong thì gửi kết quả lên đây rồi lấy nhân vật tiếp theo. Relay
    không học gì, chỉ chuyển các file nhỏ. Trên máy chính, <code>dua-bo-nao-vao-mod.bat</code> tải kết quả về rồi đưa bộ não vào bản mod.</p>
  <div class="card">
    <label for="key">Mã quản trị (ADMIN_KEY)</label>
    <input id="key" type="password" autocomplete="current-password" placeholder="in ra khi chạy install-vps.sh">
    <p><button id="load" class="secondary">Xem việc</button></p>
    <p id="status" role="status" class="note"></p>
  </div>
  <div class="card" id="setup" hidden>
    <h2>Việc</h2>
    <label for="pack">Bản mod các máy con học trên</label>
    <select id="pack"><option value="">Mỗi máy tự có file zip bản mod (đặt cạnh may-con.bat)</option></select>
    <p class="note">Chọn một bản mod đã tải lên ở trang <a href="admin" id="adminlink" style="color:#93c5fd">/admin</a> thì máy con tự tải về
      (một lần). Hãy chọn đúng bản mod dùng để chơi, có bộ nhớ và bộ số XOI (<code>&lt;tên&gt;-xoi.zip</code>).</p>
    <div class="grid">
      <div><label for="VONG">Số vòng (VONG)</label><input id="VONG" type="number" min="1"></div>
      <div><label for="TRAN">Trận mỗi tiến trình (TRAN)</label><input id="TRAN" type="number" min="1"></div>
      <div><label for="MOI_NV">Tiến trình mỗi nhân vật</label><input id="MOI_NV" type="number" min="1"></div>
      <div><label for="KIEM_TRA_MOI">Kiểm tra mỗi (vòng)</label><input id="KIEM_TRA_MOI" type="number" min="0"></div>
      <div><label for="TRAN_KIEM_TRA">Trận kiểm tra</label><input id="TRAN_KIEM_TRA" type="number" min="1"></div>
      <div><label for="TRAN_XAC_NHAN">Trận xác nhận</label><input id="TRAN_XAC_NHAN" type="number" min="0"></div>
      <div><label for="DUNG_SOM">Dừng sớm sau (vòng)</label><input id="DUNG_SOM" type="number" min="0"></div>
    </div>
    <p class="note">Mỗi máy con học cùng lúc (số luồng CPU ÷ tiến trình mỗi nhân vật) nhân vật: máy 100 luồng với 33 là 3 nhân vật.</p>
    <p class="note">Dừng sớm: nhân vật nào qua ngần ấy vòng mà điểm kiểm tra không cao thêm (đã tới giới hạn) thì thôi học, máy
      con lấy ngay nhân vật kế; nhân vật còn lên thì học tới Số vòng — nên đặt Số vòng cao (ví dụ 1500). 0 = không dừng sớm.
      Cần kiểm tra (Kiểm tra mỗi trên 0); ít tiến trình thì tăng Trận kiểm tra (mỗi lần kiểm tra nên có từ 300 trận:
      tiến trình × trận kiểm tra).</p>
    <p><button id="save">Lưu cài đặt</button></p>
    <label for="add">Thêm nhân vật (số id hoặc tên, cách nhau bằng dấu cách)</label>
    <input id="add" type="text" placeholder="ví dụ: 1 3 4 5 6 7 9 10">
    <p><button id="addbtn">Thêm vào hàng đợi</button></p>
  </div>
  <div class="card" id="machines" hidden>
    <h2>Máy con</h2>
    <p class="note">Bấm nút dưới để lấy file <code>may-con-cai-dat.bat</code> (địa chỉ relay và mã máy con). Chép file ấy vào thư mục
      <code>LF2-XOI-kit</code> của mỗi máy con, cạnh <code>may-con.bat</code>, và cả máy chính (cạnh <code>dua-bo-nao-vao-mod.bat</code>),
      rồi nháy đúp <code>may-con.bat</code> trên mỗi máy con.</p>
    <p><button id="download">Tải file may-con-cai-dat.bat</button> <button id="newkey" class="secondary">Đổi mã máy con</button></p>
  </div>
  <div class="card" id="queue" hidden>
    <h2>Các nhân vật</h2>
    <p id="summary" class="note"></p>
    <p><button id="retryall" class="secondary" hidden>Giao lại các nhân vật lỗi</button></p>
    <div class="wrap"><table><thead><tr><th>Nhân vật</th><th>Trạng thái</th><th></th></tr></thead><tbody id="list"></tbody></table></div>
    <div id="newjob" hidden>
      <p class="note">Xong một bản mod: chạy <code>dua-bo-nao-vao-mod.bat</code> trên máy chính (tải kết quả về, đưa bộ não vào bản
        mod), rồi bấm nút dưới trước khi thêm nhân vật của bản mod khác. Kết quả được ghi theo số id (hay tên) nhân vật, mà hai
        bản mod thường dùng chung số id. Mã máy con, bản mod và cài đặt giữ nguyên.</p>
      <p><button id="newjobbtn" class="secondary">Bắt đầu việc mới (bỏ hết nhân vật và kết quả trên relay)</button></p>
    </div>
  </div>
</main>
<script>
  const $ = (id) => document.getElementById(id);
  const base = location.pathname.replace(/\\/+$/, '');
  const api = base + '/api/';
  const root = base.replace(/\\/hoc$/, '');
  $('adminlink').href = root + '/admin';
  const NAMES = ['VONG', 'TRAN', 'MOI_NV', 'KIEM_TRA_MOI', 'TRAN_KIEM_TRA', 'TRAN_XAC_NHAN', 'DUNG_SOM'];
  let state = null;
  let timer = 0;
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
  const time = (iso) => { if (!iso) return ''; const d = new Date(iso); return d.toLocaleString('vi-VN', { hour: '2-digit', minute: '2-digit', day: '2-digit', month: '2-digit' }); };
  const points = (value) => (value === null || value === undefined) ? '' : ((value > 0 ? '+' : '') + value.toFixed(1).replace('.', ','));
  const megabytes = (bytes) => (bytes / 1e6).toFixed(bytes < 1e7 ? 1 : 0).replace('.', ',') + ' MB';
  function describe(f) {
    if (f.state === 'cho') return ['Chờ máy', 'note'];
    if (f.state === 'dang') {
      let text = 'Đang học trên ' + f.may + ' (từ ' + time(f.since) + ')';
      if (f.vong) text += ', vòng ' + f.vong;
      if (f.kiem !== null) text += ', kiểm tra ' + points(f.kiem) + ' điểm/100 trận';
      if (f.updated) text += ' — báo lúc ' + time(f.updated);
      return [text, 'run'];
    }
    if (f.state === 'xong') {
      const text = 'Xong trên ' + f.may + ' lúc ' + time(f.xong) + ': ' + (f.chon ? ('bộ não vòng ' + f.chon + ', trên trận mới ' + points(f.diem) + ' điểm/100 trận'
        + (f.diem > 0 ? ' — sẽ vào bản mod' : ' — không hơn XOI, không vào bản mod')) : 'chưa xác nhận')
        + (f.dung ? ' (dừng sớm ở vòng ' + f.cuoi + ': không còn tiến bộ)' : (f.cuoi ? ' (học ' + f.cuoi + ' vòng)' : ''));
      return [text, f.diem > 0 ? 'ok' : 'note'];
    }
    return ['Lỗi trên ' + f.may + ': ' + f.loi.split(/\\r?\\n/).filter(Boolean).slice(-3).join(' / '), 'bad'];
  }
  function render() {
    for (const id of ['setup', 'machines', 'queue']) $(id).hidden = false;
    for (const name of NAMES) if (document.activeElement !== $(name)) $(name).value = state.settings[name];
    if (document.activeElement !== $('pack')) $('pack').value = state.pack;
    const counts = { cho: 0, dang: 0, xong: 0, loi: 0 };
    const rows = [];
    for (const f of state.fighters) {
      counts[f.state] += 1;
      const [text, kind] = describe(f);
      const actions = [];
      if (f.state !== 'cho') actions.push('<button class="small secondary" data-act="tra-lai" data-id="' + f.id + '">Giao lại</button>');
      actions.push('<button class="small secondary" data-act="xoa" data-id="' + f.id + '">Bỏ</button>');
      rows.push('<tr><td>' + f.id + (f.ten ? ' — ' + f.ten.replace(/[<&]/g, '') : '') + '</td><td class="' + kind + '">'
        + text.replace(/[<&]/g, '') + '</td><td>' + actions.join(' ') + '</td></tr>');
    }
    $('list').innerHTML = rows.join('') || '<tr><td colspan="3" class="note">Chưa có nhân vật nào: thêm ở trên.</td></tr>';
    $('retryall').hidden = counts.loi === 0;
    $('newjob').hidden = state.fighters.length === 0;
    $('summary').textContent = state.fighters.length + ' nhân vật: ' + counts.xong + ' xong, ' + counts.dang + ' đang học, '
      + counts.cho + ' chờ, ' + counts.loi + ' lỗi.' + (state.bytes ? ' Kết quả trên relay: ' + megabytes(state.bytes) + '.' : '');
  }
  async function packs() {
    try {
      const data = await (await fetch(root + '/lf2-packs.json', { cache: 'no-store' })).json();
      for (const pack of data.packs || []) {
        if (pack.kind === 'flash') continue;
        const option = document.createElement('option');
        option.value = pack.id;
        option.textContent = pack.title + ' (' + pack.id + ', ' + (pack.size / 1e6).toFixed(0) + ' MB)';
        $('pack').appendChild(option);
      }
    } catch (error) {}
  }
  async function load(quiet) {
    if (!$('key').value) return status('Nhập mã quản trị trước.', 'bad');
    remember();
    try {
      state = await call('GET', 'trang-thai');
      render();
      if (!quiet) status(state.stored ? 'Đã tải việc.' : 'Relay này không có thư mục lưu (PACKS_DIR): chạy lại install-vps.sh.', state.stored ? 'ok' : 'bad');
      clearTimeout(timer);
      timer = setTimeout(() => load(true), 20000);
    } catch (error) { status(error.message, 'bad'); }
  }
  $('load').addEventListener('click', () => load(false));
  $('save').addEventListener('click', async () => {
    const settings = {};
    for (const name of NAMES) settings[name] = Number($(name).value);
    try { await call('PUT', 'cai-dat', { pack: $('pack').value, settings }); status('Đã lưu. Máy con dùng cài đặt mới cho các nhân vật nhận sau.', 'ok'); load(true); }
    catch (error) { status(error.message, 'bad'); }
  });
  $('addbtn').addEventListener('click', async () => {
    try { const data = await call('POST', 'them', { fighters: $('add').value }); $('add').value = '';
      const had = (data.skipped || []).length ? ' Đã có trong việc (không thêm lại): ' + data.skipped.join(' ')
        + ' — nhân vật của bản mod khác cùng số id thì bấm "Bắt đầu việc mới" trước.' : '';
      status((data.added.length ? 'Đã thêm: ' + data.added.join(' ') + '.' : 'Không có nhân vật mới.') + had, data.added.length ? 'ok' : 'note');
      load(true); }
    catch (error) { status(error.message, 'bad'); }
  });
  $('list').addEventListener('click', async (event) => {
    const button = event.target.closest('button');
    if (!button) return;
    const id = button.dataset.id;
    if (button.dataset.act === 'xoa' && !confirm('Bỏ nhân vật ' + id + ' khỏi việc (cả kết quả của nó trên relay)?')) return;
    if (button.dataset.act === 'tra-lai' && !confirm('Đưa nhân vật ' + id + ' về hàng đợi? Kết quả của nó trên relay bị xóa; máy nào nhận sẽ học tiếp '
      + 'từ thư mục hoc-tang-cuong của máy ấy nếu đã có, không thì học từ đầu.')) return;
    try {
      if (button.dataset.act === 'xoa') await call('DELETE', 'nv/' + encodeURIComponent(id));
      else await call('POST', 'tra-lai/' + encodeURIComponent(id));
      load(true);
    } catch (error) { status(error.message, 'bad'); }
  });
  $('retryall').addEventListener('click', async () => {
    const failed = state.fighters.filter((f) => f.state === 'loi');
    if (!failed.length || !confirm('Đưa ' + failed.length + ' nhân vật lỗi về hàng đợi (khi đã sửa lỗi trên máy con)?')) return;
    try {
      for (const f of failed) await call('POST', 'tra-lai/' + encodeURIComponent(f.id));
      status('Đã đưa ' + failed.length + ' nhân vật về hàng đợi.', 'ok');
    } catch (error) { status(error.message, 'bad'); }
    load(true);
  });
  $('newjobbtn').addEventListener('click', async () => {
    const learning = state.fighters.filter((f) => f.state === 'dang').length;
    if (!confirm('Bắt đầu việc mới: bỏ hết ' + state.fighters.length + ' nhân vật và kết quả của chúng trên relay? Chạy '
      + 'dua-bo-nao-vao-mod.bat trên máy chính trước để tải kết quả về.'
      + (learning ? ' ' + learning + ' nhân vật đang học trên máy con: kết quả của chúng sẽ không được nhận.' : ''))) return;
    try {
      const data = await call('POST', 'viec-moi');
      status('Đã bắt đầu việc mới (bỏ ' + data.removed + ' nhân vật). Chọn bản mod mới ở trên nếu cần, rồi thêm nhân vật.', 'ok');
    } catch (error) { status(error.message, 'bad'); }
    load(true);
  });
  $('newkey').addEventListener('click', async () => {
    if (!confirm('Đổi mã máy con? Các máy đang chạy sẽ phải lấy lại file may-con-cai-dat.bat.')) return;
    try { await call('POST', 'doi-ma'); load(true); status('Đã đổi mã: tải lại file cài đặt cho các máy con.', 'ok'); }
    catch (error) { status(error.message, 'bad'); }
  });
  $('download').addEventListener('click', async () => {
    if (!state || !state.key) {
      try { await call('PUT', 'cai-dat', {}); await load(true); } catch (error) { return status(error.message, 'bad'); }
    }
    const text = ['@echo off', 'rem Cai dat may con hoc tang cuong (trang /hoc cua relay). Dat file nay canh may-con.bat va dua-bo-nao-vao-mod.bat.',
      'set "HOC_HUB=' + location.origin + base + '"', 'set "HOC_KEY=' + state.key + '"', ''].join('\\r\\n');
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([text], { type: 'application/octet-stream' }));
    link.download = 'may-con-cai-dat.bat';
    document.body.appendChild(link);
    link.click();
    link.remove();
  });
  packs().then(() => { if ($('key').value) load(true); });
</script>
</body></html>
`;

module.exports = { createHoc, checkScore, SETTINGS, RESULT, FIGHTER, SLOT };
