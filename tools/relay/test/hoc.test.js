// SPDX-License-Identifier: MIT
//
// Reinforcement learning on many machines (hoc.js): the job set on the page, the machines' requests as
// may-con.bat sends them (KEY=value answers), the results kept and handed back, and the job kept on disk.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createRelay } = require('../server.js');
const { checkScore } = require('../hoc.js');

const ADMIN = 'admin-key-for-tests';

async function startRelay(packsDir) {
  const relay = createRelay({ quiet: true, packsDir, adminKey: ADMIN });
  const address = await relay.listen(0, '127.0.0.1');
  relay.base = `http://127.0.0.1:${address.port}`;
  return relay;
}

const admin = (relay, method, what, body) => fetch(`${relay.base}/hoc/api/${what}`, {
  method, headers: { 'x-admin-key': ADMIN, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}).then(async (response) => ({ status: response.status, body: await response.json() }));

// What may-con.bat does with curl.exe: the job's key in X-Hoc-Key, KEY=value lines back.
async function machine(relay, key, method, what, body) {
  const response = await fetch(`${relay.base}/hoc/api/${what}`, { method, headers: { 'x-hoc-key': key }, body });
  const text = await response.text();
  const values = {};
  for (const line of text.split('\n')) {
    const at = line.indexOf('=');
    if (at > 0) values[line.slice(0, at)] = line.slice(at + 1);
  }
  return { status: response.status, text, values };
}

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'hoc-test-'));
}

const ACCOUNT = '=== Bat dau luc Tue 11/17/2026  4:41:32.60: nhan vat Stancher (id 16), ban mod C:\\x.zip, 33 tien trinh x 20 tran moi vong\r\n'
  + 'KIEM TRA vong 500, greedy games 360: network 300-60 (draws 0, 83.3%), XOI alone 160-200 (draws 0, 44.4%); network - XOI +38.0 points per 100 games +- 5.6 (95%); HP margin +1.0 +- 2.0 a game; same game 0\r\n';

test('a job handed out to machines, its results kept and fetched', async () => {
  const packsDir = tempDir();
  const relay = await startRelay(packsDir);
  try {
    // The page: the machines' requests fail until there is a job.
    assert.equal((await machine(relay, 'x', 'GET', 'viec')).status, 403);
    assert.equal((await admin(relay, 'GET', 'trang-thai')).body.key, '');
    const wrong = await fetch(`${relay.base}/hoc/api/trang-thai`, { headers: { 'x-admin-key': 'nope' } });
    assert.equal(wrong.status, 401);

    let answer = await admin(relay, 'PUT', 'cai-dat', { pack: '', settings: { VONG: 300, MOI_NV: 30, TRAN: 0 } });
    assert.equal(answer.status, 200);
    assert.match(answer.body.key, /^[a-f0-9]{32}$/);
    assert.equal(answer.body.settings.VONG, 300);
    assert.equal(answer.body.settings.TRAN, 20, 'out of range: the default');
    const key = answer.body.key;
    answer = await admin(relay, 'POST', 'them', { fighters: '16, 25 8 16' });
    assert.deepEqual(answer.body.added, ['16', '25', '8']);
    assert.deepEqual(answer.body.skipped, [], 'a name twice in one list is not one the job had');
    assert.equal((await admin(relay, 'POST', 'them', { fighters: '../x' })).status, 400);

    // The machines.
    assert.equal((await machine(relay, 'wrong', 'GET', 'viec')).status, 401);
    let reply = await machine(relay, key, 'GET', 'viec');
    assert.equal(reply.status, 200);
    assert.equal(reply.values.VONG, '300');
    assert.equal(reply.values.MOI_NV, '30');
    assert.equal(reply.values.PACK_ID, undefined, 'each machine its own mod');
    assert.equal((await machine(relay, key, 'GET', 'ban-mod')).status, 404);

    reply = await machine(relay, key, 'POST', 'nhan?may=PC1-o1');
    assert.equal(reply.values.NV, '16');
    assert.equal(reply.values.VONG, '300');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o1')).values.NV, '16', 'a slot asking again gets its own fighter back');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o2')).values.NV, '25');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC2-o1')).values.NV, '8');
    reply = await machine(relay, key, 'POST', 'nhan?may=PC2-o2');
    assert.equal(reply.values.HET, '1');
    assert.equal(reply.values.NV, undefined);
    assert.equal((await machine(relay, key, 'POST', 'nhan')).status, 400, 'no slot');

    // Progress, from the check lines hoc-tang-cuong.bat writes.
    reply = await machine(relay, key, 'POST', 'bao/16?may=PC1-o1&vong=500', 'greedy games 360: network 1-1 (draws 0, 50.0%), XOI alone 1-1 (draws 0, 50.0%); network - XOI +38.0 points per 100 games +- 5.6 (95%)\r\nsample games 360: x; network - XOI -2.0 points per 100 games');
    assert.equal(reply.values.OK, '1');
    assert.equal((await machine(relay, key, 'POST', 'bao/16?may=PC2-o1&vong=1', 'x')).status, 409, 'another slot');
    let status = (await admin(relay, 'GET', 'trang-thai')).body;
    const stancher = status.fighters.find((one) => one.id === '16');
    assert.equal(stancher.state, 'dang');
    assert.equal(stancher.may, 'PC1-o1');
    assert.equal(stancher.vong, 500);
    assert.equal(stancher.kiem, 38);

    // Results.
    const brain = 'RLW_HEAD 105 64 23 12504\r\nRLW 1 0.5\r\n';
    assert.equal((await machine(relay, key, 'POST', 'xong/16?may=PC1-o1')).status, 400, 'tom-tat.txt first');
    assert.equal((await machine(relay, key, 'PUT', 'nop/16/tom-tat.txt?may=PC1-o1', ACCOUNT)).values.OK, '1');
    assert.equal((await machine(relay, key, 'PUT', 'nop/16/xac-nhan.txt?may=PC1-o1', '500 381\r\n')).values.OK, '1');
    assert.equal((await machine(relay, key, 'PUT', 'nop/16/bo-nao-500.txt?may=PC1-o1', brain)).values.OK, '1');
    assert.equal((await machine(relay, key, 'PUT', 'nop/16/relay.env?may=PC1-o1', 'x')).status, 400);
    assert.equal((await machine(relay, key, 'PUT', 'nop/16/..%2Fviec.json?may=PC1-o1', 'x')).status, 400);
    assert.equal((await machine(relay, key, 'PUT', 'nop/25/tom-tat.txt?may=PC1-o1', 'x')).status, 409, 'not its fighter');
    assert.equal((await machine(relay, key, 'POST', 'xong/16?may=PC1-o1')).values.OK, '1');
    status = (await admin(relay, 'GET', 'trang-thai')).body;
    const done = status.fighters.find((one) => one.id === '16');
    assert.equal(done.state, 'xong');
    assert.equal(done.ten, 'Stancher');
    assert.equal(done.chon, 500);
    assert.equal(done.diem, 38.1);
    assert.deepEqual(done.files, ['bo-nao-500.txt', 'tom-tat.txt', 'xac-nhan.txt']);

    // The slot takes the next one: none waiting.
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o1')).values.HET, '1');

    // A failure, then handed out again from the page.
    reply = await machine(relay, key, 'POST', 'loi/8?may=PC2-o1', '[LOI] Khong tim thay nhan vat "8"');
    assert.equal(reply.values.OK, '1');
    status = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.equal(status.fighters.find((one) => one.id === '8').state, 'loi');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC2-o1')).values.HET, '1', 'a failed one waits for the page');
    assert.equal((await admin(relay, 'POST', 'tra-lai/8')).status, 200);
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC3-o1')).values.NV, '8');

    // A machine that cannot learn gives its fighter back; another slot takes it (package 91).
    assert.equal((await machine(relay, key, 'POST', 'tra/8?may=PC9-o1')).status, 409, 'not its fighter');
    assert.equal((await machine(relay, key, 'POST', 'tra/8?may=PC3-o1')).values.OK, '1');
    status = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.equal(status.fighters.find((one) => one.id === '8').state, 'cho');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC4-o1')).values.NV, '8');

    // What the owner's machine downloads (dua-bo-nao-vao-mod.bat).
    reply = await machine(relay, key, 'GET', 'ket-qua');
    assert.equal(reply.text, '16 bo-nao-500.txt tom-tat.txt xac-nhan.txt\n');
    const file = await fetch(`${relay.base}/hoc/api/tep/16/bo-nao-500.txt`, { headers: { 'x-hoc-key': key } });
    assert.equal(await file.text(), brain);
    const byAdmin = await fetch(`${relay.base}/hoc/api/tep/16/tom-tat.txt`, { headers: { 'x-admin-key': ADMIN } });
    assert.equal(await byAdmin.text(), ACCOUNT);
    assert.equal((await fetch(`${relay.base}/hoc/api/tep/16/viec.json`, { headers: { 'x-hoc-key': key } })).status, 404);

    // A new key shuts the old one out.
    const renewed = (await admin(relay, 'POST', 'doi-ma')).body.key;
    assert.notEqual(renewed, key);
    assert.equal((await machine(relay, key, 'GET', 'viec')).status, 401);
    assert.equal((await machine(relay, renewed, 'GET', 'viec')).status, 200);

    // Taken off the job with its files.
    assert.equal((await admin(relay, 'DELETE', 'nv/16')).status, 200);
    assert.equal(fs.existsSync(path.join(packsDir, 'hoc', 'nv', '16')), false);
    assert.equal((await machine(relay, renewed, 'GET', 'ket-qua')).text, '');
  } finally {
    await relay.close();
  }

  // Kept on disk: a restarted relay knows the job.
  const again = await startRelay(packsDir);
  try {
    const status = (await admin(again, 'GET', 'trang-thai')).body;
    assert.deepEqual(status.fighters.map((one) => [one.id, one.state, one.may]), [['25', 'dang', 'PC1-o2'], ['8', 'dang', 'PC4-o1']]);
    assert.equal(status.settings.VONG, 300);
    const reply = await machine(again, status.key, 'POST', 'nhan?may=PC1-o2');
    assert.equal(reply.values.NV, '25', 'the slot gets its fighter back after a restart');
  } finally {
    await again.close();
  }
});

test('a new job takes every fighter off, with its files (package 94)', async () => {
  const packsDir = tempDir();
  const relay = await startRelay(packsDir);
  try {
    const key = (await admin(relay, 'PUT', 'cai-dat', { pack: '', settings: { VONG: 200 } })).body.key;
    await admin(relay, 'POST', 'them', { fighters: '16 25' });
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o1')).values.NV, '16');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o2')).values.NV, '25');
    const brain = 'RLW_HEAD 105 64 23 12504\r\nRLW 1 0.5\r\n';
    await machine(relay, key, 'PUT', 'nop/16/tom-tat.txt?may=PC1-o1', ACCOUNT);
    await machine(relay, key, 'PUT', 'nop/16/xac-nhan.txt?may=PC1-o1', '200 381\r\n');
    await machine(relay, key, 'PUT', 'nop/16/bo-nao-200.txt?may=PC1-o1', brain);
    assert.equal((await machine(relay, key, 'POST', 'xong/16?may=PC1-o1')).values.OK, '1');
    let status = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.equal(status.bytes, Buffer.byteLength(ACCOUNT) + Buffer.byteLength('200 381\r\n') + Buffer.byteLength(brain),
      'the size of the results kept');

    // Fighters the job has already are not added again, and the page is told which.
    const answer = (await admin(relay, 'POST', 'them', { fighters: '16 30 16' })).body;
    assert.deepEqual(answer.added, ['30']);
    assert.deepEqual(answer.skipped, ['16']);

    // Only the page may start a new job.
    const byMachine = await fetch(`${relay.base}/hoc/api/viec-moi`, { method: 'POST', headers: { 'x-hoc-key': key } });
    assert.equal(byMachine.status, 401);
    assert.match((await byMachine.json()).error, /ADMIN_KEY|quan tri/i);
    const fresh = await admin(relay, 'POST', 'viec-moi');
    assert.equal(fresh.status, 200);
    assert.equal(fresh.body.removed, 3);
    status = (await admin(relay, 'GET', 'trang-thai')).body;
    assert.deepEqual(status.fighters, []);
    assert.equal(status.bytes, 0);
    assert.equal(status.key, key, 'the machines keep their key');
    assert.equal(status.settings.VONG, 200, 'and the settings stay');
    assert.equal(fs.existsSync(path.join(packsDir, 'hoc', 'nv')), false);
    assert.equal((await machine(relay, key, 'GET', 'ket-qua')).text, '');

    // A slot still learning a fighter of the old job: its results are refused, it takes the next fighter.
    const late = await machine(relay, key, 'PUT', 'nop/25/tom-tat.txt?may=PC1-o2', ACCOUNT);
    assert.equal(late.status, 404);
    assert.match(late.values.LOI, /Khong co nhan vat 25/);
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o2')).values.HET, '1');
    assert.deepEqual((await admin(relay, 'POST', 'them', { fighters: '16' })).body.added, ['16'], 'the next mod\'s 16');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o2')).values.NV, '16');
  } finally {
    await relay.close();
  }
  const again = await startRelay(packsDir);
  try {
    const status = (await admin(again, 'GET', 'trang-thai')).body;
    assert.deepEqual(status.fighters.map((one) => [one.id, one.state, one.may]), [['16', 'dang', 'PC1-o2']], 'kept on disk');
  } finally {
    await again.close();
  }
});

test('the job\'s mod handed to the machines from the relay\'s packs', async () => {
  const packsDir = tempDir();
  const zip = Buffer.from('PK pretend zip of a mod');
  const sha256 = crypto.createHash('sha256').update(zip).digest('hex');
  fs.writeFileSync(path.join(packsDir, 'convergence.zip'), zip);
  fs.writeFileSync(path.join(packsDir, 'convergence.json'), JSON.stringify({ title: 'Convergence', sha256, files: 1 }));
  const relay = await startRelay(packsDir);
  try {
    const key = (await admin(relay, 'PUT', 'cai-dat', { pack: 'convergence' })).body.key;
    assert.equal((await admin(relay, 'PUT', 'cai-dat', { pack: 'Bad Id' })).status, 400);
    const reply = await machine(relay, key, 'GET', 'viec');
    assert.equal(reply.values.PACK_ID, 'convergence');
    assert.equal(reply.values.PACK_SHA256, sha256);
    const response = await fetch(`${relay.base}/hoc/api/ban-mod`, { headers: { 'x-hoc-key': key } });
    assert.equal(response.status, 200);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), zip);
    assert.equal((await fetch(`${relay.base}/hoc/api/ban-mod`, { headers: { 'x-hoc-key': 'nope' } })).status, 401);
  } finally {
    await relay.close();
  }
});

test('the page is served, and the hub is off the other paths', async () => {
  const relay = await startRelay(tempDir());
  try {
    const page = await fetch(`${relay.base}/hoc`);
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.match(html, /may-con-cai-dat\.bat/);
    assert.match(html, /Bắt đầu việc mới/);
    assert.equal((await fetch(`${relay.base}/hocx`)).status, 404);
    assert.equal((await fetch(`${relay.base}/hoc/api/nothing`, { headers: { 'x-admin-key': ADMIN } })).status, 404);
  } finally {
    await relay.close();
  }
});

test('a check line read for the page', () => {
  assert.equal(checkScore('greedy games 360: network 1-1; network - XOI +38.0 points per 100 games +- 5.6 (95%)'), 38);
  assert.equal(checkScore('sample games 1: network - XOI -2.5 points\r\ngreedy games 1: network - XOI -6.4 points per 100 games'), -6.4);
  assert.equal(checkScore('nothing'), null);
});

test('the opponent (package 112): XOI by default, the mod\'s own AI when set, passed to the machines', async () => {
  const relay = await startRelay(tempDir());
  try {
    let answer = await admin(relay, 'PUT', 'cai-dat', { pack: '', settings: { VONG: 1500 } });
    assert.equal(answer.body.settings.DOI_THU, 0, 'XOI without a network by default');
    answer = await admin(relay, 'PUT', 'cai-dat', { pack: '', settings: { VONG: 1500, DOI_THU: 1 } });
    const key = answer.body.key;
    assert.equal(answer.body.settings.DOI_THU, 1);
    await admin(relay, 'POST', 'them', { fighters: '11' });
    assert.equal((await machine(relay, key, 'GET', 'viec')).values.DOI_THU, '1');
    const reply = await machine(relay, key, 'POST', 'nhan?may=PC1-o1');
    assert.equal(reply.values.NV, '11');
    assert.equal(reply.values.DOI_THU, '1');
    answer = await admin(relay, 'PUT', 'cai-dat', { pack: '', settings: { VONG: 1500, DOI_THU: 7 } });
    assert.equal(answer.body.settings.DOI_THU, 0, 'out of range: the default');
    const page = await (await fetch(`${relay.base}/hoc`)).text();
    assert.match(page, /<select id="DOI_THU">/);
    assert.match(page, /AI riêng của bản mod \(như AI của Sauce\)/);
  } finally {
    await relay.close();
  }
});

test('early stop (package 97): the setting goes to the machines, the page shows where a fighter stopped', async () => {
  const relay = await startRelay(tempDir());
  try {
    let answer = await admin(relay, 'PUT', 'cai-dat', { pack: '', settings: { VONG: 1500 } });
    assert.equal(answer.body.settings.DUNG_SOM, 400, 'on by default');
    answer = await admin(relay, 'PUT', 'cai-dat', { pack: '', settings: { VONG: 1500, DUNG_SOM: 300 } });
    const key = answer.body.key;
    assert.equal(answer.body.settings.DUNG_SOM, 300);
    await admin(relay, 'POST', 'them', { fighters: '16 25' });
    let reply = await machine(relay, key, 'GET', 'viec');
    assert.equal(reply.values.DUNG_SOM, '300');
    reply = await machine(relay, key, 'POST', 'nhan?may=PC1-o1');
    assert.equal(reply.values.NV, '16');
    assert.equal(reply.values.DUNG_SOM, '300');
    assert.equal((await machine(relay, key, 'POST', 'nhan?may=PC1-o2')).values.NV, '25');

    // Stopped early in a first run (a KET THUC line of a run before stays in tom-tat.txt: the last one counts).
    const early = ACCOUNT
      + 'DUNG SOM o vong 650: 300 vong khong tien bo - diem kiem tra greedy (trung binh hai lan lien nhau) cao nhat +12.5 diem moi 100 tran, o vong 350\r\n'
      + 'XAC NHAN: chon bo nao vong 350 - dua-bo-nao-vao-mod.bat dua no vao neu network - XOI tren tran moi duong.\r\n'
      + 'KET THUC: 650 vong - dung som (khong con tien bo), toi da 1500\r\n';
    await machine(relay, key, 'PUT', 'nop/16/tom-tat.txt?may=PC1-o1', early);
    await machine(relay, key, 'PUT', 'nop/16/xac-nhan.txt?may=PC1-o1', '350 118\r\n');
    assert.equal((await machine(relay, key, 'POST', 'xong/16?may=PC1-o1')).values.OK, '1');
    // Learned to the end after the early stop was taken back (dung-som.txt deleted, run again).
    const full = early + '=== Bat dau luc Wed 11/18/2026: nhan vat Davis (id 25), ban mod C:\\x.zip, 10 tien trinh x 20 tran moi vong\r\n'
      + 'KET THUC: 1500 vong\r\n';
    await machine(relay, key, 'PUT', 'nop/25/tom-tat.txt?may=PC1-o2', full);
    await machine(relay, key, 'PUT', 'nop/25/xac-nhan.txt?may=PC1-o2', '1500 90\r\n');
    assert.equal((await machine(relay, key, 'POST', 'xong/25?may=PC1-o2')).values.OK, '1');
    const status = (await admin(relay, 'GET', 'trang-thai')).body;
    const stopped = status.fighters.find((one) => one.id === '16');
    assert.equal(stopped.cuoi, 650);
    assert.equal(stopped.dung, true);
    assert.equal(stopped.chon, 350);
    const whole = status.fighters.find((one) => one.id === '25');
    assert.equal(whole.cuoi, 1500);
    assert.equal(whole.dung, false);
    const page = await (await fetch(`${relay.base}/hoc`)).text();
    assert.match(page, /id="DUNG_SOM"/);
    assert.match(page, /dừng sớm ở vòng/);
  } finally {
    await relay.close();
  }
});
