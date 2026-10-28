#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// OpenLF2 online relay.
//
// Browsers cannot open raw TCP sockets, so OpenLF2's web build sends its network byte stream over
// a WebSocket to this relay instead. The relay pairs two players by a numeric room code and copies
// binary frames from one to the other unchanged. The game's own lockstep protocol (handshake,
// random table, one 22-byte input packet per frame) runs on top; the relay never parses or stores it.
//
//   ws(s)://<server>/relay?role=host&room=482913   Network Game > Host
//   ws(s)://<server>/relay?role=join&room=482913   Network Game > Connect, room code as the address
//
// Either side may arrive first. Server-to-client control messages are JSON text frames:
//   {"t":"waiting","room":"482913"}   registered, waiting for the other player
//   {"t":"paired"}                    both players are present; binary frames now flow
// Problems close the socket with a 4xxx code and a short ASCII reason, which the game shows.
//
// With INSTALLER_FILE set (install-vps.sh does), the relay also serves its copy of the original LF2
// v2.0a installer at /lf2-installer.data, which the game page downloads before trying archive.org:
// download managers such as IDM let that name through, while they take over the .exe from archive.org.
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const { WebSocketServer, WebSocket } = require('ws');

const INSTALLER_PATH = '/lf2-installer.data';

const ROOM_PATTERN = /^\d{4,12}$/;

// Close codes are part of the contract with online.js (it maps them to messages too).
const CLOSE = Object.freeze({
  badRequest: [4000, 'Relay: bad request'],
  originDenied: [4001, 'Relay: this website may not use the relay'],
  tooManyConnections: [4002, 'Relay: too many connections from your network'],
  serverFull: [4003, 'Relay: server is full'],
  hostTaken: [4004, 'Relay: room already has a host'],
  guestTaken: [4004, 'Relay: room already has a guest'],
  timeout: [4005, 'Relay: nobody joined in time'],
  peerLeft: [4006, 'Relay: the other player left'],
  rateLimited: [4007, 'Relay: too much traffic'],
  slowPeer: [4008, 'Relay: the other player stopped reading'],
  earlyData: [4009, 'Relay: data sent before pairing'],
  shutdown: [1001, 'Relay: server is restarting'],
});

function readConfig(env = process.env) {
  const number = (name, fallback) => {
    const raw = env[name];
    const value = raw === undefined || raw === '' ? fallback : Number(raw);
    if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number`);
    return value;
  };
  return {
    port: number('PORT', 8787),
    host: env.HOST || '0.0.0.0',
    path: env.RELAY_PATH || '/relay',
    // Comma-separated page origins allowed to connect, e.g. "https://you.github.io". Empty allows any.
    allowedOrigins: (env.ALLOWED_ORIGINS || '').split(',').map(normalizeOrigin).filter(Boolean),
    // Behind a reverse proxy (Caddy, nginx, Cloudflare), take the client address from X-Forwarded-For.
    trustProxy: env.TRUST_PROXY === '1' || env.TRUST_PROXY === 'true',
    maxRooms: number('MAX_ROOMS', 500), // 0 = unlimited
    maxConnectionsPerIp: number('MAX_CONNECTIONS_PER_IP', 8), // 0 = unlimited
    roomWaitMs: number('ROOM_WAIT_MS', 120000),
    pingIntervalMs: number('PING_INTERVAL_MS', 15000),
    maxMessageBytes: number('MAX_MESSAGE_BYTES', 65536), // the game queues at most 64 KiB
    messagesPerSecond: number('MESSAGES_PER_SECOND', 240), // the game sends ~30 per second; 0 = unlimited
    bytesPerSecond: number('BYTES_PER_SECOND', 131072), // 0 = unlimited
    maxBufferedBytes: number('MAX_BUFFERED_BYTES', 1048576),
    // Testing aid: hold every forwarded frame this long, to feel how a distant relay would play.
    forwardDelayMs: number('FORWARD_DELAY_MS', 0),
    // The LF2 installer served at /lf2-installer.data (empty: not served), and how often one client
    // address may download it (about 30 MB each time; browsers keep it after the first time).
    installerFile: env.INSTALLER_FILE || '',
    installerDownloadsPerHour: number('INSTALLER_DOWNLOADS_PER_HOUR', 20), // 0 = unlimited
    quiet: env.QUIET === '1' || env.QUIET === 'true',
  };
}

function normalizeOrigin(value) {
  return String(value || '').trim().replace(/\/+$/, '').toLowerCase();
}

// Token bucket: `rate` units per second, bursts up to `capacity`. A rate of 0 disables the limit.
class Bucket {
  constructor(rate, capacity) {
    this.rate = rate;
    this.capacity = Math.max(capacity, rate);
    this.tokens = this.capacity;
    this.last = Date.now();
  }
  take(amount) {
    if (this.rate === 0) return true;
    const now = Date.now();
    this.tokens = Math.min(this.capacity, this.tokens + ((now - this.last) * this.rate) / 1000);
    this.last = now;
    if (this.tokens < amount) return false;
    this.tokens -= amount;
    return true;
  }
}

function createRelay(overrides = {}) {
  const config = { ...readConfig({}), ...overrides };
  const rooms = new Map(); // code -> { code, host, join, timer }
  const connectionsPerIp = new Map();
  const log = (...parts) => { if (!config.quiet) console.log(new Date().toISOString(), ...parts); };

  const installerDownloads = new Map(); // client address -> { count, until }
  const installerPaths = new Set([INSTALLER_PATH, config.path.replace(/[^/]*$/, INSTALLER_PATH.slice(1))]);

  const server = http.createServer((req, res) => {
    const { pathname } = new URL(req.url, 'http://relay.invalid');
    if (pathname === '/healthz') {
      // Readable from the game page (another origin) so its Online panel can show "relay OK".
      res.writeHead(200, {
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'access-control-allow-origin': '*',
      });
      res.end(JSON.stringify({ ok: true, rooms: rooms.size, clients: wss.clients.size, installer: installerSize() > 0 }));
      return;
    }
    if (installerPaths.has(pathname)) {
      serveInstaller(req, res);
      return;
    }
    if (pathname === '/' || pathname === config.path) {
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      res.end(`OpenLF2 relay is running. Connect with a WebSocket to ${config.path}\n`);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('Not found\n');
  });

  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: config.maxMessageBytes,
    perMessageDeflate: false, // 22-byte packets: compression only adds latency
  });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://relay.invalid');
    if (url.pathname !== config.path && url.pathname !== '/') {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return;
    }
    // Requests are validated after the upgrade, so the browser receives a close code and reason
    // instead of an anonymous connection error.
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req, url));
  });

  wss.on('connection', (ws, req, url) => {
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('error', () => {}); // a 'close' event always follows

    if (config.allowedOrigins.length && !config.allowedOrigins.includes(normalizeOrigin(req.headers.origin))) {
      return closeWith(ws, CLOSE.originDenied);
    }
    const role = url.searchParams.get('role');
    const code = url.searchParams.get('room') || '';
    if ((role !== 'host' && role !== 'join') || !ROOM_PATTERN.test(code)) {
      return closeWith(ws, CLOSE.badRequest);
    }

    const address = clientAddress(req);
    const count = connectionsPerIp.get(address) || 0;
    if (config.maxConnectionsPerIp && count >= config.maxConnectionsPerIp) {
      return closeWith(ws, CLOSE.tooManyConnections);
    }
    connectionsPerIp.set(address, count + 1);
    ws.once('close', () => {
      const left = (connectionsPerIp.get(address) || 1) - 1;
      if (left > 0) connectionsPerIp.set(address, left);
      else connectionsPerIp.delete(address);
    });

    let room = rooms.get(code);
    if (!room) {
      if (config.maxRooms && rooms.size >= config.maxRooms) return closeWith(ws, CLOSE.serverFull);
      room = { code, host: null, join: null, timer: null };
      rooms.set(code, room);
    }
    if (room[role]) return closeWith(ws, role === 'host' ? CLOSE.hostTaken : CLOSE.guestTaken);

    room[role] = ws;
    ws.room = room;
    ws.role = role;
    ws.peer = null;
    ws.messageBudget = new Bucket(config.messagesPerSecond, config.messagesPerSecond * 2);
    ws.byteBudget = new Bucket(config.bytesPerSecond, Math.max(config.bytesPerSecond, config.maxMessageBytes) * 2);
    ws.on('message', (data, isBinary) => onMessage(ws, data, isBinary));
    ws.on('close', () => onClose(ws));

    const other = room[role === 'host' ? 'join' : 'host'];
    if (other) {
      clearTimeout(room.timer);
      room.timer = null;
      ws.peer = other;
      other.peer = ws;
      // Both peers are linked before either learns about it, so any data that follows has a destination.
      sendControl(other, { t: 'paired' });
      sendControl(ws, { t: 'paired' });
      log(`room ${code}: paired`);
    } else {
      sendControl(ws, { t: 'waiting', room: code });
      room.timer = setTimeout(() => {
        if (room[role] === ws && !ws.peer) closeWith(ws, CLOSE.timeout);
      }, config.roomWaitMs);
      log(`room ${code}: ${role} waiting`);
    }
  });

  function onMessage(ws, data, isBinary) {
    if (!isBinary) return; // only the relay speaks text; clients send game bytes as binary frames
    if (!ws.peer) return closeWith(ws, CLOSE.earlyData);
    if (!ws.messageBudget.take(1) || !ws.byteBudget.take(data.length)) {
      log(`room ${ws.room.code}: rate limit`);
      closeWith(ws.peer, CLOSE.rateLimited);
      return closeWith(ws, CLOSE.rateLimited);
    }
    const peer = ws.peer;
    if (peer.readyState !== WebSocket.OPEN) return;
    if (peer.bufferedAmount > config.maxBufferedBytes) {
      closeWith(ws, CLOSE.slowPeer);
      return closeWith(peer, CLOSE.slowPeer);
    }
    if (config.forwardDelayMs > 0) {
      // Timers with the same delay fire in the order they were set, so the stream stays in order.
      setTimeout(() => { if (peer.readyState === WebSocket.OPEN) peer.send(data, { binary: true }); }, config.forwardDelayMs);
      return;
    }
    peer.send(data, { binary: true });
  }

  function onClose(ws) {
    const room = ws.room;
    if (!room) return;
    if (room[ws.role] === ws) room[ws.role] = null;
    const peer = ws.peer;
    ws.peer = null;
    if (peer) {
      // A lockstep match cannot continue with one player, so the room ends with the pair and its
      // code is free again at once (the host can press Host again with the same code).
      peer.peer = null;
      room.host = room.join = null;
      closeWith(peer, CLOSE.peerLeft);
      log(`room ${room.code}: ended`);
    }
    if (!room.host && !room.join) {
      clearTimeout(room.timer);
      if (rooms.get(room.code) === room) rooms.delete(room.code);
    }
  }

  // Size of the installer file, or 0 when none is configured or readable.
  function installerSize() {
    if (!config.installerFile) return 0;
    try {
      const stat = fs.statSync(config.installerFile);
      return stat.isFile() ? stat.size : 0;
    } catch {
      return 0;
    }
  }

  function serveInstaller(req, res) {
    const headers = { 'cache-control': 'public, max-age=86400', 'x-content-type-options': 'nosniff' };
    // Cross-origin: the game page lives elsewhere (GitHub Pages). With an allow-list, only its pages may read it.
    const origin = normalizeOrigin(req.headers.origin);
    if (!config.allowedOrigins.length) headers['access-control-allow-origin'] = '*';
    else if (origin && config.allowedOrigins.includes(origin)) {
      headers['access-control-allow-origin'] = req.headers.origin;
      headers.vary = 'Origin';
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { ...headers, allow: 'GET, HEAD' });
      res.end();
      return;
    }
    const size = installerSize();
    if (!size) {
      res.writeHead(404, headers);
      res.end();
      return;
    }
    if (req.method === 'GET' && config.installerDownloadsPerHour) {
      const address = clientAddress(req);
      const now = Date.now();
      let entry = installerDownloads.get(address);
      if (!entry || entry.until <= now) {
        entry = { count: 0, until: now + 3600000 };
        installerDownloads.set(address, entry);
      }
      if (entry.count >= config.installerDownloadsPerHour) {
        res.writeHead(429, { ...headers, 'retry-after': String(Math.ceil((entry.until - now) / 1000)) });
        res.end();
        return;
      }
      entry.count += 1;
    }
    res.writeHead(200, { ...headers, 'content-type': 'application/octet-stream', 'content-length': String(size) });
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    const stream = fs.createReadStream(config.installerFile);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }

  function clientAddress(req) {
    if (config.trustProxy) {
      const forwarded = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
      if (forwarded) return forwarded;
    }
    return req.socket.remoteAddress || 'unknown';
  }

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) { ws.terminate(); continue; }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* closing */ }
    }
    const now = Date.now();
    for (const [address, entry] of installerDownloads) if (entry.until <= now) installerDownloads.delete(address);
  }, config.pingIntervalMs);
  heartbeat.unref();

  return {
    config,
    server,
    wss,
    rooms,
    listen(port = config.port, host = config.host) {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => {
          server.off('error', reject);
          resolve(server.address());
        });
      });
    },
    close() {
      clearInterval(heartbeat);
      for (const room of rooms.values()) clearTimeout(room.timer);
      for (const ws of wss.clients) closeWith(ws, CLOSE.shutdown);
      return new Promise((resolve) => {
        wss.close(() => server.close(() => resolve()));
        setTimeout(() => { for (const ws of wss.clients) ws.terminate(); }, 1000).unref();
      });
    },
  };
}

function sendControl(ws, message) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
}

function closeWith(ws, [code, reason]) {
  if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
    ws.close(code, reason);
    // Do not wait forever for a client that never answers the close handshake.
    setTimeout(() => { if (ws.readyState !== WebSocket.CLOSED) ws.terminate(); }, 3000).unref();
  }
}

module.exports = { createRelay, readConfig, CLOSE, ROOM_PATTERN };

if (require.main === module) {
  const relay = createRelay(readConfig());
  relay.listen().then((address) => {
    const where = typeof address === 'string' ? address : `${address.address}:${address.port}`;
    console.log(`OpenLF2 relay listening on ${where}, WebSocket path ${relay.config.path}`);
    if (!relay.config.allowedOrigins.length) {
      console.log('ALLOWED_ORIGINS is empty: any website may use this relay. Set it to your game page origin.');
    }
  }).catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
  const stop = () => relay.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
