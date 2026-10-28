// SPDX-License-Identifier: MIT
//
// install-vps.sh: its syntax, that the relay files embedded in it are current, and its helper
// functions (run in bash, sourced without running the installation).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync, execFile } = require('node:child_process');
const { render } = require('../update-installer.js');

const relayDir = path.join(__dirname, '..');
const installer = path.join(relayDir, 'install-vps.sh');

// Runs `script` in bash with the installer's functions loaded (LF2_INSTALLER_LIB=1 skips main).
function bash(script, env = {}) {
  return new Promise((resolve, reject) => {
    execFile('bash', ['-c', `set -euo pipefail; LF2_INSTALLER_LIB=1 source "${installer}"; ${script}`],
      { env: { ...process.env, ...env }, encoding: 'utf8' }, (error, stdout, stderr) => {
        if (error) reject(new Error(`${error.message}\n${stderr}`));
        else resolve(stdout);
      });
  });
}

test('the installer parses as bash', () => {
  execFileSync('bash', ['-n', installer]);
});

test('the relay files embedded in the installer are the current ones', async () => {
  const current = fs.readFileSync(installer, 'utf8');
  assert.equal(render(current), current, 'run: node update-installer.js');
  const decoded = await bash('dir=$(mktemp -d); write_server_js "$dir/s"; write_package_json "$dir/p"; cat "$dir/s"; echo "<<split>>"; cat "$dir/p"; rm -rf "$dir"');
  const [server, pkg] = decoded.split('<<split>>\n');
  assert.equal(server, fs.readFileSync(path.join(relayDir, 'server.js'), 'utf8'));
  assert.equal(pkg, fs.readFileSync(path.join(relayDir, 'package.json'), 'utf8'));
});

test('version comparison', async () => {
  const out = await bash(`for pair in "2.17 2.28" "2.28 2.28" "2.31 2.28" "2.9 2.28" "2.100 2.28"; do
    set -- $pair; if version_ge "$1" "$2"; then echo "$1 yes"; else echo "$1 no"; fi; done`);
  assert.equal(out, '2.17 no\n2.28 yes\n2.31 yes\n2.9 no\n2.100 yes\n');
});

test('the newest Node.js 22 build for glibc 2.17 is picked from the index', async () => {
  const index = [
    '[{"version":"v24.11.0","date":"2026-10-01","files":["headers","linux-x64-glibc-217","linux-x64-musl"],"npm":"11.6.1"},',
    '{"version":"v22.21.1","date":"2026-09-20","files":["headers","linux-x64-musl"],"npm":"10.9.4"},',
    '{"version":"v22.21.0","date":"2026-09-10","files":["headers","linux-x64-glibc-217","linux-x64-musl"],"npm":"10.9.4"},',
    '{"version":"v22.20.0","date":"2026-08-01","files":["linux-x64-glibc-217"],"npm":"10.9.3"},',
    '{"version":"v20.19.5","date":"2026-07-01","files":["linux-x64-glibc-217"],"npm":"10.8.2"}]',
  ].join('\n');
  fs.writeFileSync(path.join(__dirname, '.index.tmp.json'), index);
  try {
    const out = await bash(`latest_glibc217 22 < "${path.join(__dirname, '.index.tmp.json')}"`);
    assert.equal(out, 'v22.21.0\n');
    const none = await bash(`latest_glibc217 18 < "${path.join(__dirname, '.index.tmp.json')}"`);
    assert.equal(none, '');
  } finally {
    fs.rmSync(path.join(__dirname, '.index.tmp.json'), { force: true });
  }
});

test('which Node.js builds are tried on CentOS 7 and on newer systems', async () => {
  const index = '[{"version":"v22.21.0","files":["linux-x64-glibc-217"]}]';
  const server = http.createServer((req, res) => {
    if (req.url === '/index.json') { res.end(index); return; }
    res.writeHead(404); res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const old = await bash('node_candidates 2.17 x64', { NODE_UNOFFICIAL: base, NODE_DIST: 'https://nodejs.org/dist' });
    assert.equal(old, `${base}/v22.21.0 node-v22.21.0-linux-x64-glibc-217\nhttps://nodejs.org/dist/v16.20.2 node-v16.20.2-linux-x64\n`);
    const unreachable = await bash('node_candidates 2.17 x64', { NODE_UNOFFICIAL: 'http://127.0.0.1:9', NODE_DIST: 'https://nodejs.org/dist' });
    assert.equal(unreachable, 'https://nodejs.org/dist/v16.20.2 node-v16.20.2-linux-x64\n', 'falls back when the index cannot be read');
    const modern = await bash('node_candidates 2.35 x64', { NODE_DIST: 'https://nodejs.org/dist' });
    assert.equal(modern, 'https://nodejs.org/dist/latest-v22.x LATEST\n');
  } finally {
    server.close();
  }
});

test('the sslip.io name for an address', async () => {
  assert.equal(await bash('sslip_name 203.0.113.5'), '203-0-113-5.sslip.io\n');
  assert.equal(await bash('is_ipv4 203.0.113.5 && echo yes; is_ipv4 "<html>" || echo no'), 'yes\nno\n');
});

// ss output (CentOS 7 format) with the given owners of ports 80 and 443; '' = free.
function ssOutput(owner80, owner443) {
  const lines = ['State      Recv-Q Send-Q Local Address:Port               Peer Address:Port',
    'LISTEN     0      128          *:22                       *:*                   users:(("sshd",pid=1012,fd=3))'];
  if (owner80) lines.push(`LISTEN     0      511       :::80                    :::*                   users:(("${owner80}",pid=3001,fd=4),("${owner80}",pid=3002,fd=4))`);
  if (owner443) lines.push(`LISTEN     0      511       :::443                   :::*                   users:(("${owner443}",pid=3001,fd=6))`);
  return lines.join('\n') + '\n';
}

// Runs check_ports against that ss output; `ours` = whether lf2-caddy is active.
async function portPlan(owner80, owner443, ours = false) {
  const file = path.join(__dirname, `.ss-plan-${process.pid}-${Math.random().toString(36).slice(2)}.txt`);
  fs.writeFileSync(file, ssOutput(owner80, owner443));
  try {
    return await bash(`ss() { cat "${file}"; }; check_ports; echo "mode=$CADDY_MODE"`,
      { LF2_SYSTEMCTL: ours ? 'true' : 'false' });
  } catch (error) {
    return `exit: ${error.message}`;
  } finally {
    fs.rmSync(file, { force: true });
  }
}

test('which ports Caddy takes, next to another web server', async () => {
  assert.equal(await portPlan('', ''), 'mode=full\n');
  const apache80 = await portPlan('httpd', '');
  assert.match(apache80, /Cong 80 dang do "httpd" dung/);
  assert.match(apache80, /mode=tls-only\n$/);
  assert.equal(await portPlan('caddy', 'caddy', true), 'mode=full\n', 'our own Caddy from an earlier run');
  assert.match(await portPlan('httpd', 'caddy', true), /mode=tls-only\n$/, 'rerun after a tls-only install');
  const both = await portPlan('httpd', 'httpd');
  assert.match(both, /^exit: /);
  assert.match(both, /Cong 443 \(HTTPS\) dang duoc chuong trinh "httpd" dung/);
  assert.match(both, /systemctl stop httpd\n\s+systemctl disable httpd/);
  assert.doesNotMatch(both, /--now/, 'CentOS 7 systemd has no --now');
  const other = await portPlan('', 'java');
  assert.match(other, /"java"/);
  assert.doesNotMatch(other, /systemctl stop/, 'no stop command for programs we do not know');
  assert.match(await portPlan('caddy', ''), /mode=tls-only/, 'someone else\'s Caddy on 80 is not ours');
});

test('the Caddy configuration for each mode', async () => {
  const caddyfile = (mode, extra = '') => bash(`CADDY_MODE=${mode}; DOMAIN=203-0-113-5.sslip.io; ${extra} f=$(mktemp); write_caddyfile "$f"; cat "$f"; rm -f "$f"`);
  assert.equal(await caddyfile('full'), [
    '# Written by install-vps.sh (full). HTTPS for the OpenLF2 relay; the certificate renews by itself.',
    '{', '\tadmin off', '}', '', '203-0-113-5.sslip.io {', '\ttls {', '\t\tissuer acme {', '\t\t}', '\t}',
    '\treverse_proxy 127.0.0.1:8787', '}', ''].join('\n'));
  assert.equal(await caddyfile('tls-only'), [
    '# Written by install-vps.sh (tls-only). HTTPS for the OpenLF2 relay; the certificate renews by itself.',
    '{', '\tadmin off', '\tauto_https disable_redirects', '}', '', '203-0-113-5.sslip.io {', '\ttls {', '\t\tissuer acme {',
    '\t\t\tdisable_http_challenge', '\t\t}', '\t}', '\treverse_proxy 127.0.0.1:8787', '}', ''].join('\n'));
  const withTestCa = await caddyfile('tls-only', 'LF2_ACME_DIR=https://localhost:14000/dir LF2_ACME_ROOT=/ca.pem');
  assert.match(withTestCa, /\t\t\tdir https:\/\/localhost:14000\/dir\n\t\t\ttrusted_roots \/ca.pem\n\t\t\tdisable_http_challenge\n/);
});

test('the game data is fetched once, checked, and never fatal', async () => {
  const os = require('node:os');
  const good = crypto.randomBytes(200000);
  const sha = crypto.createHash('sha256').update(good).digest('hex');
  let requests = 0;
  const server = http.createServer((req, res) => {
    requests += 1;
    if (req.url === '/good.exe') { res.end(good); return; }
    if (req.url === '/bad.exe') { res.end(crypto.randomBytes(200000)); return; }
    res.writeHead(404); res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const prefix = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-data-'));
  const env = { LF2_PREFIX: prefix, LF2_DATA_SIZE: String(good.length), LF2_DATA_SHA256: sha, no_proxy: '127.0.0.1', NO_PROXY: '127.0.0.1' };
  try {
    // The first sources fail (missing, wrong bytes); the third is right.
    const first = await bash('install_game_data; echo "have=$HAVE_DATA"',
      { ...env, LF2_DATA_URLS: `${base}/missing.exe ${base}/bad.exe ${base}/good.exe` });
    assert.match(first, /have=1\n$/);
    assert.ok(fs.readFileSync(path.join(prefix, 'data', 'lf2-installer.data')).equals(good));
    const before = requests;
    const again = await bash('install_game_data; echo "have=$HAVE_DATA"', { ...env, LF2_DATA_URLS: `${base}/good.exe` });
    assert.match(again, /Du lieu game da co san/);
    assert.equal(requests, before, 'a good copy is not downloaded again');
    fs.rmSync(path.join(prefix, 'data'), { recursive: true });
    const none = await bash('install_game_data; echo "have=$HAVE_DATA"', { ...env, LF2_DATA_URLS: `${base}/bad.exe` });
    assert.match(none, /trang game se tai tu archive.org/);
    assert.match(none, /have=0\n$/);
    assert.ok(!fs.existsSync(path.join(prefix, 'data', 'lf2-installer.data')), 'wrong bytes are never kept');
  } finally {
    server.close();
    fs.rmSync(prefix, { recursive: true, force: true });
  }
});

test('who holds ports 80 and 443, from ss output', async () => {
  const ss = [
    'State      Recv-Q Send-Q Local Address:Port               Peer Address:Port',
    'LISTEN     0      128          *:22                       *:*                   users:(("sshd",pid=1012,fd=3))',
    'LISTEN     0      128          *:8080                     *:*                   users:(("java",pid=2001,fd=40))',
    'LISTEN     0      511       [::]:80                    [::]:*                   users:(("httpd",pid=3001,fd=4),("httpd",pid=3002,fd=4))',
    'LISTEN     0      100    127.0.0.1:25                     *:*                   users:(("master",pid=1200,fd=13))',
  ].join('\n');
  fs.writeFileSync(path.join(__dirname, '.ss.tmp.txt'), ss + '\n');
  try {
    const file = path.join(__dirname, '.ss.tmp.txt');
    assert.equal(await bash(`port_owner 80 < "${file}"`), 'httpd\n');
    assert.equal(await bash(`port_owner 443 < "${file}"`), '');
    assert.equal(await bash(`port_owner 22 < "${file}"`), 'sshd\n');
    assert.equal(await bash(`port_owner 8 < "${file}"`), '');
  } finally {
    fs.rmSync(path.join(__dirname, '.ss.tmp.txt'), { force: true });
  }
});
