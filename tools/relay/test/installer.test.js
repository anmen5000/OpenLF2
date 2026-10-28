// SPDX-License-Identifier: MIT
//
// install-vps.sh: its syntax, that the relay files embedded in it are current, and its helper
// functions (run in bash, sourced without running the installation).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
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
