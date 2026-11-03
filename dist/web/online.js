// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors
//
// Network play in the browser.
//
// Browsers cannot open TCP sockets, so the web build's network transport
// (src/adapters/web/transport.cpp) hands the game's byte stream to this script, which carries it
// over a WebSocket to a relay server where up to 8 players meet in a room named by a numeric code
// (tools/relay, protocol 2: the relay keeps the beat, see scripts/base/game/room.lua).
//
// In the game, Network Game > Host opens this page's room. Network Game > Connect joins the room
// typed into the address field, or this page's room when the field is left empty (an invite link
// sets it). The host starts the game once everyone is in. All players need the same relay and the
// same OpenLF2 build.
//
// Direct connections: a page may also reach the host's page directly (WebRTC), set up through the
// relay. When every player reaches the host directly and no later than through the relay, the host's
// page keeps the beat itself at START (the relay's rules, see Beat below): players on one LAN then play
// with no relay in between. Otherwise the relay keeps the beat as before. The game sees the same
// messages either way.
//
// Messages returned to the game are short ASCII English: the game draws them with its bitmap font.
(function (root) {
  'use strict';

  // This script runs on the game page and, for the host of a direct room, again as a worker (workerMain).
  const IN_WORKER = typeof WorkerGlobalScope !== 'undefined' && typeof self !== 'undefined' && self instanceof WorkerGlobalScope;
  const SCRIPT_URL = !IN_WORKER && root.document && root.document.currentScript && root.document.currentScript.src
    ? root.document.currentScript.src : '';
  const LOAD_STEP = 20; // ms between the ticks that measure how busy the page is (watchLoad)

  const STATUS = Object.freeze({ idle: 0, listening: 1, connecting: 2, connected: 3 });
  const ROOM_PATTERN = /^\d{4,12}$/;
  const SEND_LIMIT = 65536; // the TCP transport's send queue limit
  const OPEN = 1; // WebSocket.OPEN
  const STORAGE = Object.freeze({ relay: 'openlf2-relay', room: 'openlf2-room' });
  // The relay's close codes (tools/relay/server.js), for proxies that drop the close reason.
  const CLOSE_REASONS = Object.freeze({
    4000: 'Relay: bad request',
    4001: 'Relay: this website may not use the relay',
    4002: 'Relay: too many connections from your network',
    4003: 'Relay: server is full',
    4004: 'Relay: room is taken',
    4005: 'Relay: nobody joined in time',
    4006: 'Relay: the other player left',
    4007: 'Relay: too much traffic',
    4008: 'Relay: the other player stopped reading',
    4009: 'Relay: data sent before pairing',
    4010: 'Relay: the room is full',
    4011: 'Relay: the game in this room has already started',
    4012: 'Relay: this room plays another game version or mod',
    4013: 'Relay: the host left the room',
    4014: 'Relay: the host did not start the game in time',
    4015: 'Relay: unexpected message from the game',
    4016: 'Relay: your connection is too slow for the game',
    4017: 'Relay: this room code is in use by another game page',
  });
  // A relay that only pairs two players (protocol 1) answers with these instead of a welcome.
  const OUTDATED_RELAY = 'Relay: this relay is too old for this game page; update it (install-vps.sh)';
  const LOST_HOST = 'Network: lost the direct connection to the host';

  // Protocol 2 message kinds (tools/relay/server.js): what the page reads to set up direct play.
  const KIND = Object.freeze({
    hello: 0x01, start: 0x02, input: 0x03, ready: 0x04, check: 0x05,
    welcome: 0x81, lobby: 0x82, started: 0x83, frame: 0x84, checked: 0x85, left: 0x86,
    // This page's own, before each FRAME it gives the game: when the frame arrived here (performance.now(),
    // whole milliseconds u32 and thousandths u16), for the game's pacing (room.lua; older games skip it).
    stamp: 0x90,
  });
  const DIRECT = Object.freeze({
    // Public STUN servers: how a direct connection crosses home routers when the players are not on one LAN.
    iceServers: [{ urls: ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478'] }],
    connectMs: 12000, // a direct connection not open by then is given up (the relay keeps the beat)
    pingMs: 2000, // how often both ways are timed, in the lobby and during play
    samples: 5, // round trips kept (their median counts)
    slack: 10, // ms a player's direct connection may be slower than his way through the relay
    input: 16, queue: 64, // the relay's limits (ROOM_LIMITS)
    // Version 2 links (both pages say so on the link): the game's messages numbered, each on the reliable
    // channel once and on a second channel that never sends again what was lost (a datagram), together
    // with the few before it. A lost packet on the reliable channel holds up everything after it until it
    // is sent again (a quarter of a second or more, worse on Wi-Fi); the next datagram brings it 33 ms later.
    version: 2,
    fastLabel: 'lf2-fast',
    again: 8, // messages each datagram repeats (the newest last)
    datagram: 1100, // bytes a datagram holds at most (one network packet)
    held: 512, // messages kept that came after a missing one
  });
  const NUMBERED = 0xf0; // first byte of a numbered message (protocol 2 kinds are below 0x87)
  const EMPTY = new Uint8Array(0);

  class OnlineTransport {
    constructor(options = {}) {
      this.WebSocket = options.WebSocket || root.WebSocket;
      // (null: no direct connections; tests pass a stand-in.)
      this.RTCPeerConnection = options.RTCPeerConnection === undefined ? root.RTCPeerConnection : options.RTCPeerConnection;
      this.iceServers = options.iceServers || DIRECT.iceServers;
      this.pageProtocol = options.pageProtocol || (root.location && root.location.protocol) || '';
      this.relay = '';
      this.room = '';
      this.pack = ''; // the game pack (mod) this page plays, for invite links; set by the page
      this.setRelay(options.relay);
      this.setRoom(options.room);
      this.listeners = new Set();
      this.lastFailure = ''; // kept for the panel after the game has closed the failed connection
      this.loadTimer = 0; // watchLoad: how busy this page is, measured while in a room
      this.stalls = null;
      this.reset();
    }

    reset() {
      this.socket = null;
      this.state = STATUS.idle;
      this.failure = ''; // why the connection ended; reported after the bytes received before it
      this.sendError = '';
      this.chunks = [];
      this.offset = 0; // read position inside chunks[0]
      this.buffered = 0;
      this.activeRoom = '';
      this.role = '';
      this.opened = false;
      this.players = 0; // in the room, from the relay's notes for this panel
      this.started = false;
      // Direct connections (see above).
      this.id = 0; // this game's id in the room
      this.rules = null; // the relay's beat rules, when it passes on direct connection set-ups
      this.links = new Map(); // host: player id -> Link; another player: 'host' -> Link
      this.relayTimes = []; // round trips to the relay
      this.relayPings = new Map();
      this.pings = 0;
      this.pingTimer = 0;
      this.tickMs = 100 / 3;
      this.lobbyIds = [];
      this.beatBy = 'relay'; // who keeps the beat once started: 'relay' or 'host'
      this.beat = null; // the host's side keeping the beat: Beat on this page, or WorkerBeat for the worker
      this.worker = null; // the host's worker (startWorker), when the browser hands channels to one
      this.workerReady = false;
      this.workerBeating = false;
      this.incoming = EMPTY; // relay messages not yet complete
      this.outgoing = EMPTY; // game messages not yet complete
      // For the corner of the game (netStats): frames as they came, and the last one the game ran and checked.
      this.arrivals = []; // [frame number, ms]
      this.lastRun = -1;
    }

    // Ends direct connections and the beat (before reset()).
    stopDirect() {
      clearInterval(this.pingTimer);
      this.pingTimer = 0;
      if (this.beat) this.beat.stop();
      this.beat = null;
      const links = [...this.links.values()];
      this.links = new Map();
      for (const link of links) link.close();
      this.giveUpWorker();
      this.workerBeating = false;
      clearInterval(this.loadTimer);
      this.loadTimer = 0;
    }

    // Accepts what people paste: wss://host/relay as printed by the installer, but also the
    // https:// address of the relay or a bare host name, which become wss://.
    setRelay(value) {
      let relay = String(value || '').trim();
      if (relay && !/^[a-z][a-z0-9+.-]*:\/\//i.test(relay)) relay = 'wss://' + relay;
      this.relay = relay.replace(/^https:\/\//i, 'wss://').replace(/^http:\/\//i, 'ws://');
    }
    setRoom(value) { this.room = String(value || '').replace(/\D/g, '').slice(0, 12); }

    // Where the relay keeps its copy of the LF2 installer (installer-store.js tries it before archive.org):
    // wss://host/relay -> https://host/lf2-installer.data. Empty without a relay.
    installerUrl() { return this.relayFile('lf2-installer.data'); }
    // The relay's game packs (mods, tools/relay/packs.js): the list, and one pack by id.
    packsUrl() { return this.relayFile('lf2-packs.json'); }
    packUrl(id) { return this.relayFile('lf2-packs/' + encodeURIComponent(id) + '.zip'); }

    // A file beside the relay's WebSocket path, over HTTP(S). Empty without a relay.
    relayFile(name) {
      let url;
      try { url = new URL(this.relay); } catch (error) { return ''; }
      if (url.protocol !== 'wss:' && url.protocol !== 'ws:') return '';
      url.protocol = url.protocol === 'ws:' ? 'http:' : 'https:';
      url.pathname = url.pathname.replace(/[^/]*$/, '') + name;
      url.search = '';
      url.hash = '';
      return url.href;
    }

    // ---- The game's side (src/adapters/web/transport.cpp) ---------------------------------------

    // Starts hosting (host = true) or joining. Returns false with error() set when it cannot start.
    start(host, address) {
      this.close();
      this.lastFailure = '';
      const typed = String(address || '').trim();
      if (!host && typed.includes('.')) return this.fail('Network: type the room code, not an IP address');
      const room = host ? this.room : typed || this.room;
      if (!ROOM_PATTERN.test(room)) {
        return this.fail(host ? 'Network: set a room code (4-12 digits) above the game'
          : 'Network: type the room code (4-12 digits)');
      }
      let url;
      try { url = new URL(this.relay); } catch (error) { return this.fail('Network: set the relay address above the game'); }
      if (url.protocol !== 'wss:' && url.protocol !== 'ws:') return this.fail('Network: the relay address must start with wss://');
      if (url.protocol === 'ws:' && this.pageProtocol === 'https:' && !isLoopback(url.hostname)) {
        return this.fail('Network: this https page needs a wss:// relay address');
      }
      if (typeof this.WebSocket !== 'function') return this.fail('Network: this browser has no WebSocket support');
      url.searchParams.set('v', '2');
      url.searchParams.set('role', host ? 'host' : 'join');
      url.searchParams.set('room', room);
      let socket;
      try {
        socket = new this.WebSocket(url.href);
      } catch (error) {
        return this.fail('Network: cannot open the relay address');
      }
      socket.binaryType = 'arraybuffer';
      this.socket = socket;
      this.state = host ? STATUS.listening : STATUS.connecting;
      this.activeRoom = room;
      this.role = host ? 'host' : 'join';
      socket.onopen = () => { if (socket === this.socket) this.opened = true; };
      socket.onmessage = (event) => this.onMessage(socket, event);
      socket.onclose = (event) => this.onClose(socket, event);
      // Browsers follow an error with a close event that carries the details. Some WebSocket
      // implementations (Node's) never send that close after a failed connection, so an error
      // that is not followed by a close soon counts as one.
      socket.onerror = () => {
        setTimeout(() => {
          if (socket !== this.socket) return;
          try { socket.close(); } catch (error) { /* not open */ }
          this.onClose(socket, { code: 1006, reason: '' });
        }, 250);
      };
      this.emit();
      return true;
    }

    // Queues bytes for the relay. Returns false with error() set when it cannot.
    send(bytes) {
      this.sendError = '';
      eachPacket(bytes, (kind, payload) => {
        if (kind === KIND.check && payload.length >= 4) this.lastRun = readU32(payload, 0);
      });
      const socket = this.socket;
      if (!socket || this.state !== STATUS.connected || socket.readyState !== OPEN) {
        this.sendError = 'Network peer is not connected';
        return false;
      }
      if (socket.bufferedAmount + bytes.length > SEND_LIMIT) {
        this.sendError = 'Network send queue exceeds 64 KiB';
        return false;
      }
      if (!this.rules) {
        socket.send(bytes);
        return true;
      }
      // Whole messages, by kind: START decides who keeps the beat; with the host keeping it, the game's
      // INPUT, READY and CHECK go to the host's page (or, on it, to the beat) instead of the relay.
      let ok = true;
      this.outgoing = Uint8Array.from(splitPackets(concatBytes(this.outgoing, bytes), (kind, payload, whole) => {
        if (!ok) return;
        if (kind === KIND.start && this.role === 'host' && !this.started) {
          // (The relay confirms the choice to every page, this one too, just before STARTED.)
          socket.send(JSON.stringify({ t: 'beat', by: this.chooseBeat() }));
          socket.send(whole.slice());
        } else if (this.beatBy === 'host' && (kind === KIND.input || kind === KIND.ready || kind === KIND.check)) {
          if (this.role === 'host') {
            if (this.beat) this.beat.receive(this.id, kind, payload.slice());
          } else {
            const link = this.links.get('host');
            if (!link || !link.sendGame(whole.slice())) {
              ok = false;
              this.lostHost();
            }
          }
        } else {
          socket.send(whole.slice());
        }
      }));
      if (!ok) this.sendError = LOST_HOST;
      return ok;
    }

    // Received bytes waiting to be taken; -1 once the connection has failed and nothing is left.
    available() {
      if (this.buffered > 0) return this.buffered;
      return this.failure ? -1 : 0;
    }

    // Moves up to `capacity` received bytes into `target` at `offset`; returns how many.
    takeInto(target, offset, capacity) {
      const size = Math.min(capacity, this.buffered);
      let written = 0;
      while (written < size) {
        const chunk = this.chunks[0];
        const count = Math.min(chunk.length - this.offset, size - written);
        target.set(chunk.subarray(this.offset, this.offset + count), offset + written);
        written += count;
        this.offset += count;
        if (this.offset === chunk.length) {
          this.chunks.shift();
          this.offset = 0;
        }
      }
      this.buffered -= size;
      return size;
    }

    take(capacity) {
      const bytes = new Uint8Array(Math.min(capacity, this.buffered));
      this.takeInto(bytes, 0, bytes.length);
      return bytes;
    }

    status() { return this.state; }
    error() { return this.failure || this.sendError; }

    close() {
      this.stopDirect();
      const socket = this.socket;
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
        try { socket.close(1000, 'closed'); } catch (error) { /* already closing */ }
      }
      const changed = this.state !== STATUS.idle || this.failure;
      this.reset();
      if (changed) this.emit();
    }

    // ---- Socket events ------------------------------------------------------------------------

    onMessage(socket, event) {
      if (socket !== this.socket) return;
      if (typeof event.data === 'string') {
        let message;
        try { message = JSON.parse(event.data); } catch (error) { return; }
        if (!message) return;
        if (message.t === 'welcome' && message.v === 2 && this.state !== STATUS.connected) {
          this.state = STATUS.connected;
          this.id = Number(message.id) || 0;
          if (message.direct && this.id) this.startDirect(message.direct);
          this.emit();
        } else if (message.t === 'room') {
          this.players = Number(message.players) || 0;
          this.started = message.started === true;
          this.emit();
        } else if (message.t === 'waiting' || message.t === 'paired') {
          this.fail(OUTDATED_RELAY);
        } else if (message.t === 'signal' && message.data && typeof message.data === 'object') {
          this.onSignal(Number(message.from), message.data);
        } else if (message.t === 'pong') {
          const sent = this.relayPings.get(message.n);
          this.relayPings.delete(message.n);
          if (sent !== undefined) addSample(this.relayTimes, now() - sent);
        } else if (message.t === 'beat') {
          this.onBeat(message);
        } else if (message.t === 'left') {
          if (this.beat) this.beat.leave(Number(message.id));
        }
        return;
      }
      const bytes = new Uint8Array(event.data);
      if (!bytes.length) return;
      if (this.rules) this.watch(bytes);
      this.receive(bytes);
    }

    // Bytes for the game, each FRAME with a note of when it came (KIND.stamp), for the game's pacing.
    receive(bytes) {
      const at = now();
      const stamped = stampFrames(bytes, at, (frame) => {
        this.arrivals.push([frame, at]);
        if (this.arrivals.length > 2400) this.arrivals.splice(0, this.arrivals.length - 1800);
      });
      this.chunks.push(stamped);
      this.buffered += stamped.length;
    }

    // How the network is, for the corner of the game: the round trip (ms) to whoever keeps the beat (the
    // relay or the host's page; on the host's page, to its slowest player), which way, how unevenly the
    // frames of the last 5 seconds came (ms between the earliest and the latest, beat for beat), and how
    // far behind the newest frame the game runs (ms, when it is more than the frames' usual wait).
    netStats() {
      if (this.state !== STATUS.connected) return null;
      const direct = this.beatBy === 'host' && this.started;
      let ping = null;
      if (direct && this.role === 'host') {
        const times = [...this.links.values()].filter((link) => link.open).map((link) => median(link.times)).filter(Number.isFinite);
        ping = times.length ? Math.max(...times) : 0;
      } else if (direct || (!this.started && this.role !== 'host' && this.links.get('host') && this.links.get('host').open)) {
        ping = median(this.links.get('host') ? this.links.get('host').times : []);
      } else {
        ping = median(this.relayTimes);
      }
      const way = direct || (!this.started && ping !== null && this.links.get('host') && this.links.get('host').open) ? 'direct' : 'relay';
      const at = now();
      const recent = this.arrivals.filter(([, time]) => at - time < 5000);
      let jitter = null;
      if (this.started && recent.length >= 10) {
        const offsets = recent.map(([frame, time]) => time - frame * this.tickMs);
        jitter = Math.max(...offsets) - Math.min(...offsets);
      }
      let behind = null;
      if (this.started && this.lastRun >= 0 && recent.length) {
        // CHECKs come every 8 frames: the game is somewhere in the 8 after the last one.
        behind = Math.max(0, recent[recent.length - 1][0] - this.lastRun - 8) * this.tickMs;
      }
      // How busy this page was lately, and the other side (the host for a player; for the host, its busiest player).
      const busy = this.stall();
      let peerBusy = null;
      for (const link of this.links.values()) {
        if (link.open && Number.isFinite(link.peerStall)) peerBusy = Math.max(peerBusy === null ? 0 : peerBusy, link.peerStall);
      }
      return { ping, way, jitter, behind, busy, peerBusy, host: this.role === 'host' };
    }

    // ---- Direct connections -------------------------------------------------------------------

    // The relay passes on set-ups: time the way to it, and reach the host's page directly. On the host's
    // page, when the browser can hand data channels to a worker, the channels and the beat live in one
    // (startWorker): the game's own work on the page then never delays a beat or a pong.
    startDirect(rules) {
      this.rules = {
        repeat: Number(rules.repeat) || 15, grace: Number(rules.grace) || 5000, buffered: Number(rules.buffered) || 1048576,
      };
      this.watchLoad();
      if (typeof this.RTCPeerConnection === 'function') {
        // (Without WebRTC, no links: the relay keeps the beat; the round trips to it still show in the corner.)
        if (this.role === 'host') this.startWorker();
        else this.links.set('host', new Link(this, 'host', true));
      }
      this.pingTimer = setInterval(() => this.ping(), DIRECT.pingMs);
      this.ping();
    }

    ping() {
      const socket = this.socket;
      if (!socket || socket.readyState !== OPEN) return;
      this.pings += 1;
      this.relayPings.set(this.pings, now());
      if (this.relayPings.size > 8) this.relayPings.delete(this.relayPings.keys().next().value);
      socket.send(JSON.stringify({ t: 'ping', n: this.pings }));
      const stall = this.stall();
      if (this.worker) {
        this.worker.postMessage({ t: 'load', stall });
        return;
      }
      for (const link of this.links.values()) if (link.open) link.ping(stall);
    }

    signal(to, data) {
      const socket = this.socket;
      if (socket && socket.readyState === OPEN) socket.send(JSON.stringify({ t: 'signal', to, data }));
    }

    onSignal(from, data) {
      let link;
      if (this.role === 'host') {
        link = this.links.get(from);
        if (!link && data.description && data.description.type === 'offer' && !this.started) {
          link = new Link(this, from, false);
          this.links.set(from, link);
        }
      } else {
        link = this.links.get('host');
      }
      if (link) link.signal(data);
    }

    // A direct connection's messages on this page: timing (text), and the game's (binary): to the host,
    // the game's INPUT, READY and CHECK; from it, the beat's frames.
    onLinkMessage(link, data, fast) {
      if (typeof data === 'string') {
        let message;
        try { message = JSON.parse(data); } catch (error) { return; }
        if (!message) return;
        if (message.t === 'ping') {
          link.answer(message, fast);
          if (Number.isFinite(message.stall)) link.peerStall = message.stall;
        } else if (message.t === 'hello') {
          link.greeted(Number(message.v) || 0);
        } else if (message.t === 'pong' && Number.isFinite(message.at)) {
          addSample(link.times, now() - message.at);
          // What the host's page weighs at START: both ways, from here; and how busy this page is.
          if (this.role !== 'host') link.say({ t: 'times', relay: median(this.relayTimes), direct: median(link.times), stall: this.stall() });
          this.emit();
        } else if (message.t === 'times') {
          link.reported = { relay: finiteOrNull(message.relay), direct: finiteOrNull(message.direct) };
          if (Number.isFinite(message.stall)) link.peerStall = message.stall;
          this.emit();
        }
        return;
      }
      const bytes = new Uint8Array(data);
      // A numbered message (version 2 links): the game's messages in it not had yet, in order; the rest as it is.
      const parts = bytes[0] === NUMBERED ? link.unwrap(bytes) : [bytes];
      for (const part of parts) {
        if (this.role !== 'host') {
          if (this.beatBy === 'host') this.receive(part.slice());
          continue;
        }
        link.pending = Uint8Array.from(splitPackets(concatBytes(link.pending, part), (kind, payload) => {
          if (this.beat) this.beat.receive(link.id, kind, payload.slice());
          else link.early.push([kind, payload.slice()]);
        }));
      }
    }

    linkChanged(link) {
      if (link.open && link.id === 'host') this.ping();
      if (!link.open && this.links.get(link.id) === link) {
        if (this.role === 'host') {
          if (this.beat) this.beat.leave(link.id);
        } else if (this.beatBy === 'host') {
          this.lostHost();
          return;
        }
      }
      this.emit();
    }

    // The host's page at START: it keeps the beat when every player reaches it directly, none of them
    // sooner through the relay (DIRECT.slack), and the players' round trips add up to less so.
    chooseBeat() {
      const own = median(this.relayTimes);
      if (!this.rules || own === null || this.lobbyIds.length < 2) return 'relay';
      let viaRelay = own;
      let viaHost = 0;
      for (const id of this.lobbyIds) {
        if (id === this.id) continue;
        const link = this.links.get(id);
        const times = link && link.open && link.reported;
        if (!times || times.relay === null || times.direct === null) return 'relay';
        if (times.direct > times.relay + DIRECT.slack) return 'relay';
        viaRelay += times.relay;
        viaHost += times.direct;
      }
      return viaHost < viaRelay ? 'host' : 'relay';
    }

    // The relay's word on who keeps the beat (just before STARTED).
    onBeat(message) {
      this.beatBy = message.by === 'host' ? 'host' : 'relay';
      if (this.beatBy === 'host' && this.role !== 'host') {
        const link = this.links.get('host');
        if (!link || !link.open) {
          this.lostHost();
          return;
        }
      }
      this.emit();
    }

    // The relay's messages to the game, read along: this game's id and the beat (WELCOME), the
    // players in the lobby (LOBBY) and, with the host keeping the beat, their order (STARTED).
    watch(bytes) {
      this.incoming = Uint8Array.from(splitPackets(concatBytes(this.incoming, bytes), (kind, payload) => {
        if (kind === KIND.welcome && payload.length >= 4) {
          const thirds = payload[3] * 3 + ((payload[1] >> 1) & 3);
          if (thirds > 0) this.tickMs = thirds / 3;
        } else if (kind === KIND.lobby) {
          this.lobbyIds = readPlayers(payload);
        } else if (kind === KIND.started) {
          const order = readPlayers(payload);
          if (this.beatBy === 'host' && this.role === 'host' && !this.beat) {
            this.beat = this.worker ? new WorkerBeat(this, order) : new Beat(this, order);
          }
        }
      }));
    }

    // Beat's host interface, when the beat is kept on this page.
    wire(id) { return this.links.get(id); }
    toGame(bytes) { this.receive(bytes); }
    ticker(callback) { return createTicker(callback); }

    // ---- The host's worker ---------------------------------------------------------------------
    // This script again, as a worker (workerMain below): it is given the data channels of the players'
    // links as they come (transferred, so the page no longer holds them) and keeps the beat on them. The
    // page keeps the signalling (RTCPeerConnection) and mirrors what the worker tells it about each link.

    startWorker() {
      if (!SCRIPT_URL || typeof root.Worker !== 'function') return;
      let worker;
      try {
        worker = new root.Worker(SCRIPT_URL);
      } catch (error) {
        return;
      }
      this.worker = worker;
      this.workerReady = false;
      worker.onerror = () => { if (this.worker === worker) this.giveUpWorker(); };
      worker.onmessage = (event) => { if (this.worker === worker) this.onWorkerMessage(event.data); };
      worker.postMessage({ t: 'setup', id: this.id, rules: this.rules, tickMs: this.tickMs });
      // Whether this browser hands data channels over to a worker (Chromium does): tried on a throwaway one,
      // so that no link is caught halfway.
      try {
        const probe = new this.RTCPeerConnection({ iceServers: [] });
        const channel = probe.createDataChannel('probe');
        worker.postMessage({ t: 'probe', channel }, [channel]);
        setTimeout(() => { try { probe.close(); } catch (error) { /* closed */ } }, 1000);
      } catch (error) {
        this.giveUpWorker();
      }
    }

    // Back to keeping the beat on the page (an older browser, or the worker could not be loaded).
    giveUpWorker() {
      const worker = this.worker;
      this.worker = null;
      this.workerReady = false;
      if (worker) {
        try { worker.terminate(); } catch (error) { /* gone */ }
      }
    }

    onWorkerMessage(message) {
      if (!message || typeof message !== 'object') return;
      if (message.t === 'ready') {
        this.workerReady = true;
      } else if (message.t === 'link') {
        const link = this.links.get(message.id);
        if (!link) return;
        if (Array.isArray(message.times)) link.times = message.times;
        if (message.reported !== undefined) link.reported = message.reported;
        if (Number.isFinite(message.peerStall)) link.peerStall = message.peerStall;
        if (message.version) link.version = message.version;
        if (message.closed) {
          link.close();
          return;
        }
        if (message.open && !link.open) {
          link.open = true;
          clearTimeout(link.timer);
          this.linkChanged(link);
          return;
        }
        this.emit();
      } else if (message.t === 'frame') {
        this.receive(new Uint8Array(message.bytes));
      } else if (message.t === 'beat') {
        if (message.started) this.workerBeating = true;
        if (this.beat && Number.isFinite(message.late)) this.beat.late = message.late;
      }
    }

    // ---- The page's own load --------------------------------------------------------------------
    // A timer every few milliseconds: the time it comes late is how long the page was busy (the game's frame,
    // a garbage collection, another tab's work on this thread). The longest such stall of the last 5 seconds
    // is shown in the corner and told to the other side: a busy host delays the beat for everyone when the
    // beat runs on its page, a busy player delays only its own game.

    watchLoad() {
      if (this.loadTimer) return;
      this.loadLast = now();
      this.stalls = [];
      this.loadTimer = setInterval(() => {
        const at = now();
        const late = at - this.loadLast - LOAD_STEP;
        this.loadLast = at;
        if (late >= 4) {
          this.stalls.push([at, late]);
          if (this.stalls.length > 2000) this.stalls.splice(0, 1000);
        }
      }, LOAD_STEP);
    }

    // The longest stall of the last 5 seconds, ms.
    stall() {
      if (!this.stalls) return 0;
      const since = now() - 5000;
      let worst = 0;
      for (const [at, late] of this.stalls) if (at >= since && late > worst) worst = late;
      return worst;
    }

    // For the panel: how this game plays with the others.
    directText() {
      if (!this.rules) return '';
      if (this.started) {
        if (this.beatBy !== 'host') return 'through the relay';
        return this.role === 'host' ? 'direct: your computer keeps the beat' : 'direct: the host keeps the beat';
      }
      if (this.role === 'host') {
        const others = this.lobbyIds.filter((id) => id !== this.id);
        if (!others.length) return '';
        const direct = others.filter((id) => this.links.get(id) && this.links.get(id).open).length;
        return `direct links: ${direct} of ${others.length}`;
      }
      const link = this.links.get('host');
      const relay = median(this.relayTimes);
      if (!link || !link.open) return link && !link.closed ? 'connecting directly to the host...' : 'no direct link to the host: through the relay';
      const direct = median(link.times);
      return `direct link to the host${direct === null ? '' : `: ${Math.round(direct)} ms`}${relay === null ? '' : ` (relay ${Math.round(relay)} ms)`}`;
    }

    // A text of the network's last minute, for a report: what each number in the corner was, over time.
    report() {
      const lines = [];
      const stats = this.netStats();
      lines.push(`OpenLF2 network report, ${new Date().toISOString()}`);
      lines.push(`role ${this.role || '-'}, room ${this.activeRoom || '-'}, started ${this.started}, beat by ${this.beatBy}, `
        + `beat in a worker: ${this.role === 'host' ? Boolean(this.worker && this.workerBeating) : '-'}, tick ${this.tickMs.toFixed(2)} ms, `
        + `relay ${this.relay}`);
      if (stats) {
        lines.push(`ping ${stats.ping === null ? '-' : Math.round(stats.ping)} ms (${stats.way}), jitter 5 s ${stats.jitter === null ? '-' : Math.round(stats.jitter)} ms, `
          + `behind ${stats.behind === null ? '-' : Math.round(stats.behind)} ms, busy ${Math.round(stats.busy)} ms, other side busy ${stats.peerBusy === null ? '-' : Math.round(stats.peerBusy)} ms`);
      }
      if (this.beat && typeof this.beat.worstLate === 'function') lines.push(`the beat here: worst lateness of a beat in the last 5 s ${Math.round(this.beat.worstLate())} ms`);
      lines.push(`relay round trips ${this.relayTimes.map((ms) => Math.round(ms)).join(' ') || '-'}`);
      for (const [id, link] of this.links) {
        lines.push(`link ${id}: ${link.closed ? 'closed' : link.open ? 'open' : 'connecting'}, version ${link.version}, datagrams ${link.fast ? 'yes' : (this.worker ? '(worker)' : 'no')}, `
          + `round trips ${link.times.map((ms) => Math.round(ms)).join(' ') || '-'}, reported ${JSON.stringify(link.reported)}, other side busy ${link.peerStall === null ? '-' : Math.round(link.peerStall)} ms`);
      }
      // The frames of the last minute: how late each came after the earliest, by seconds.
      const at = now();
      const recent = this.arrivals.filter(([, time]) => at - time < 60000);
      if (recent.length > 10) {
        const offsets = recent.map(([frame, time]) => time - frame * this.tickMs);
        const base = Math.min(...offsets);
        const buckets = new Map();
        for (const [index, [, time]] of recent.entries()) {
          const second = Math.floor((at - time) / 1000);
          const late = offsets[index] - base;
          const bucket = buckets.get(second) || { count: 0, worst: 0, sum: 0 };
          bucket.count += 1;
          bucket.sum += late;
          bucket.worst = Math.max(bucket.worst, late);
          buckets.set(second, bucket);
        }
        const seconds = [...buckets.keys()].sort((a, b) => a - b);
        lines.push(`frames of the last minute, per second ago (count, mean lateness, worst lateness ms): `
          + seconds.map((second) => { const b = buckets.get(second); return `${second}s: ${b.count}/${Math.round(b.sum / b.count)}/${Math.round(b.worst)}`; }).join('  '));
      }
      const stalls = (this.stalls || []).filter(([time]) => at - time < 60000).map(([time, late]) => `${Math.round((at - time) / 1000)}s:${Math.round(late)}`);
      lines.push(`this page's stalls of the last minute (seconds ago:ms, over 4 ms): ${stalls.slice(-80).join(' ') || 'none'}`);
      lines.push(`browser ${root.navigator ? root.navigator.userAgent : '-'}`);
      return lines.join('\n');
    }

    onClose(socket, event) {
      if (socket !== this.socket) return;
      this.stopDirect();
      this.socket = null;
      this.state = STATUS.idle;
      this.failure = event.reason || CLOSE_REASONS[event.code]
        || (this.opened ? 'Network: lost the connection to the relay' : 'Network: cannot reach the relay');
      this.lastFailure = this.failure;
      this.emit();
    }

    // The host's page is gone while it kept the beat: as a closed relay connection, the frames already
    // received are still played before the game hears of it.
    lostHost() {
      const socket = this.socket;
      this.stopDirect();
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
        try { socket.close(1000, 'closed'); } catch (error) { /* already closing */ }
      }
      this.socket = null;
      this.state = STATUS.idle;
      this.failure = this.lastFailure = LOST_HOST;
      this.emit();
    }

    fail(message) {
      this.stopDirect();
      const socket = this.socket;
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
        try { socket.close(1000, 'closed'); } catch (error) { /* already closing */ }
      }
      this.reset();
      this.failure = this.lastFailure = message;
      this.emit();
      return false;
    }

    // ---- Page side ----------------------------------------------------------------------------

    onChange(listener) {
      this.listeners.add(listener);
      return () => this.listeners.delete(listener);
    }

    emit() {
      for (const listener of this.listeners) {
        try { listener(this); } catch (error) { /* a broken panel must not break the game */ }
      }
    }
  }

  // A direct connection's channels, as used on a page or in the host's worker: the reliable channel, from
  // version 2 the datagram channel beside it, the game's messages numbered on both (sendGame, unwrap), and
  // the timing messages (ping, answer). `owner`: { wireOpened(wire), wireClosed(wire), wireMessage(wire, data,
  // fast), wireOpenFast(wire) }.
  class Wire {
    constructor(owner, id) {
      this.owner = owner;
      this.id = id;
      this.open = false;
      this.closed = false;
      this.times = []; // round trips through it
      this.reported = null; // the other side's own times (on the host's side)
      this.peerStall = null; // how busy the other side's page said it was lately, ms
      this.pending = EMPTY; // its game messages not yet complete (host's side)
      this.early = []; // its game messages that came before the beat began (host's side)
      this.channel = null;
      this.fast = null; // version 2: the datagram channel
      this.version = 1; // the other page's (its hello on the link; pages before version 2 say nothing)
      this.sent = { number: 0, recent: [] }; // the game's messages out: the last number, the newest few
      this.got = { number: 0, held: new Map() }; // and in: the last taken, those after a missing one
    }

    attach(channel) {
      if (channel.label === DIRECT.fastLabel) return this.attachFast(channel);
      this.channel = channel;
      channel.binaryType = 'arraybuffer';
      channel.onopen = () => {
        if (this.closed || this.open) return;
        this.open = true;
        this.say({ t: 'hello', v: DIRECT.version });
        this.owner.wireOpened(this);
      };
      channel.onclose = () => this.close();
      channel.onmessage = (event) => { if (!this.closed) this.owner.wireMessage(this, event.data, false); };
      if (channel.readyState === 'open') channel.onopen();
      return undefined;
    }

    // The datagram channel (version 2): the game's numbered messages and pings; losing one loses nothing.
    attachFast(channel) {
      if (this.fast || this.closed) {
        try { channel.close(); } catch (error) { /* closed */ }
        return;
      }
      this.fast = channel;
      channel.binaryType = 'arraybuffer';
      channel.onclose = () => { if (this.fast === channel) this.fast = null; };
      channel.onmessage = (event) => { if (!this.closed) this.owner.wireMessage(this, event.data, true); };
    }

    // The other page's hello: from version 2 on, numbered messages, and the page that offered the link
    // opens the datagram channel (on the link as it is: no new set-up through the relay).
    greeted(version) {
      if (this.closed || version <= this.version) return;
      this.version = version;
      if (version >= 2 && !this.fast) this.owner.wireOpenFast(this);
    }

    send(bytes) {
      if (!this.open || !this.channel || this.channel.readyState !== 'open') return false;
      try { this.channel.send(bytes); } catch (error) { return false; }
      return true;
    }

    // One of the game's messages (protocol 2, whole): with a version 2 page numbered, on the reliable channel
    // and in a datagram with the few before it; else as it is.
    sendGame(bytes) {
      if (this.version < 2) return this.send(bytes);
      const sent = this.sent;
      sent.number = (sent.number + 1) >>> 0;
      sent.recent.push(bytes);
      if (sent.recent.length > DIRECT.again) sent.recent.shift();
      const ok = this.send(numbered(sent.number, [bytes]));
      const fast = this.fast;
      if (ok && fast && fast.readyState === 'open' && fast.bufferedAmount < DIRECT.datagram * 16) {
        let size = 6;
        let from = sent.recent.length;
        while (from > 0 && size + 2 + sent.recent[from - 1].length <= DIRECT.datagram) {
          from -= 1;
          size += 2 + sent.recent[from].length;
        }
        if (from < sent.recent.length) {
          try { fast.send(numbered(sent.number, sent.recent.slice(from))); } catch (error) { /* the reliable copy */ }
        }
      }
      return ok;
    }

    // A numbered message: the game's messages in it that come next (in order, each once), keeping those
    // after one that has not come yet.
    unwrap(bytes) {
      if (bytes.length < 6) return [];
      const last = (bytes[1] | (bytes[2] << 8) | (bytes[3] << 16) | (bytes[4] << 24)) >>> 0;
      const count = bytes[5];
      const items = [];
      for (let at = 6; items.length < count && at + 2 <= bytes.length;) {
        const length = bytes[at] | (bytes[at + 1] << 8);
        if (at + 2 + length > bytes.length) return [];
        items.push(bytes.subarray(at + 2, at + 2 + length));
        at += 2 + length;
      }
      const got = this.got;
      const out = [];
      items.forEach((item, k) => {
        const number = last - (items.length - 1 - k);
        if (number <= got.number || got.held.has(number)) return;
        if (number !== got.number + 1) {
          if (got.held.size < DIRECT.held) got.held.set(number, item.slice());
          return;
        }
        out.push(item);
        got.number = number;
        for (let next = got.held.get(got.number + 1); next; next = got.held.get(got.number + 1)) {
          got.held.delete(got.number + 1);
          out.push(next);
          got.number += 1;
        }
      });
      return out;
    }

    say(message, fast) {
      if (!this.open) return false;
      const text = JSON.stringify(message);
      if (fast && this.fast && this.fast.readyState === 'open') {
        try { this.fast.send(text); return true; } catch (error) { /* the reliable channel then */ }
      }
      return this.send(text);
    }

    // A round trip timed on the datagram channel when there is one: a lost packet on the reliable channel
    // would hold a ping up with everything else. `stall`: how busy this page was lately, for the other side.
    ping(stall) { this.say({ t: 'ping', at: now(), stall: Number.isFinite(stall) ? Math.round(stall) : undefined }, true); }
    answer(ping, fast) { this.say({ t: 'pong', at: ping.at }, fast); }
    buffered() { return this.channel ? this.channel.bufferedAmount : 0; }

    close() {
      if (this.closed) return;
      this.closed = true;
      this.open = false;
      for (const channel of [this.channel, this.fast]) {
        if (!channel) continue;
        channel.onopen = channel.onclose = channel.onmessage = null;
        try { channel.close(); } catch (error) { /* closed */ }
      }
      this.fast = null;
      this.owner.wireClosed(this);
    }
  }

  // A direct connection to another page of the room, on the page: the set-up through the relay (an
  // RTCPeerConnection) and, unless the host's worker holds them, its channels (Wire).
  class Link extends Wire {
    constructor(online, id, offerer) {
      super(null, id);
      this.owner = this;
      this.online = online;
      this.offerer = offerer;
      this.handedOver = false; // the channels went to the host's worker
      try {
        this.pc = new online.RTCPeerConnection({ iceServers: online.iceServers });
      } catch (error) {
        this.pc = null;
        this.closed = true;
        return;
      }
      this.pc.onicecandidate = (event) => {
        if (event.candidate) online.signal(id, { candidate: plain(event.candidate) });
      };
      this.pc.onconnectionstatechange = () => {
        const state = this.pc.connectionState;
        if (state === 'failed' || state === 'closed') this.close();
      };
      this.timer = setTimeout(() => { if (!this.open) this.close(); }, DIRECT.connectMs);
      if (offerer) {
        this.attach(this.pc.createDataChannel('lf2', { ordered: true }));
        this.queue = Promise.resolve().then(async () => {
          await this.pc.setLocalDescription(await this.pc.createOffer());
          online.signal(id, { description: plain(this.pc.localDescription) });
        }).catch(() => this.close());
      } else {
        this.queue = Promise.resolve();
        this.pc.ondatachannel = (event) => this.attach(event.channel);
      }
    }

    // A channel of this link: to the host's worker when there is one, else kept here.
    attach(channel) {
      const online = this.online;
      if (online.worker && online.role === 'host') {
        if (online.workerReady) {
          try {
            online.worker.postMessage({ t: 'channel', id: this.id, channel }, [channel]);
            this.handedOver = true;
            return undefined;
          } catch (error) { /* this browser keeps channels on the page */ }
        }
        online.giveUpWorker();
      }
      return super.attach(channel);
    }

    // Wire's owner, on the page.
    wireOpened() {
      clearTimeout(this.timer);
      this.online.linkChanged(this);
    }
    wireClosed() {
      clearTimeout(this.timer);
      if (this.pc) {
        this.pc.onicecandidate = this.pc.onconnectionstatechange = this.pc.ondatachannel = null;
        try { this.pc.close(); } catch (error) { /* closed */ }
      }
      if (this.handedOver && this.online.worker) this.online.worker.postMessage({ t: 'close', id: this.id });
      this.online.linkChanged(this);
    }
    wireMessage(wire, data, fast) { this.online.onLinkMessage(this, data, fast); }
    wireOpenFast() {
      if (!this.offerer || !this.pc) return;
      try {
        this.attach(this.pc.createDataChannel(DIRECT.fastLabel, { ordered: false, maxRetransmits: 0 }));
      } catch (error) { /* the reliable channel alone */ }
    }

    // The other page's offer, answer or route (in order: a route may not come before its offer).
    signal(data) {
      if (this.closed) return;
      this.queue = this.queue.then(async () => {
        if (this.closed) return;
        if (data.description) {
          await this.pc.setRemoteDescription(data.description);
          if (data.description.type === 'offer') {
            await this.pc.setLocalDescription(await this.pc.createAnswer());
            this.online.signal(this.id, { description: plain(this.pc.localDescription) });
          }
        } else if (data.candidate) {
          await this.pc.addIceCandidate(data.candidate);
        }
      }).catch(() => { /* a route that does not work: others may */ });
    }
  }

  // The beat kept on the host's side (on its page, or in its worker), by the relay's rules
  // (tools/relay/server.js, "Rooms"): every beat, FRAME with each player's input (the inputs since the
  // last beat merged; the newest kept, without its one-shot events, while nothing new comes; nothing after
  // `repeat` beats without news), CHECK passed on as CHECKED, LEFT when a player is gone; the beat begins
  // once every game is READY, or after `grace` ms; a player whose connection falls behind by more than
  // `buffered` bytes is let go. `host`: { id, rules, tickMs, wire(id), toGame(bytes), ticker(callback) }.
  class Beat {
    constructor(host, ids) {
      this.host = host;
      this.rules = host.rules;
      this.tickMs = host.tickMs;
      this.members = ids.map((id, index) => ({ id, index, present: true, ready: false, queue: [], last: EMPTY, repeats: 0 }));
      this.frame = 0;
      this.ticking = false;
      this.ticks = 0;
      this.tickStart = 0;
      this.ended = false;
      this.lateness = []; // [at, ms]: how late each run of the beat came after its time (the last 5 s kept)
      this.ticker = host.ticker(() => this.run());
      this.grace = setTimeout(() => this.startBeat(), this.rules.grace);
      for (const member of this.members) {
        if (member.id === host.id) continue;
        const wire = host.wire(member.id);
        if (!wire || !wire.open) {
          this.leave(member.id);
          continue;
        }
        const early = wire.early;
        wire.early = [];
        for (const [kind, payload] of early) this.receive(member.id, kind, payload);
      }
    }

    member(id) { return this.members.find((member) => member.id === id); }

    receive(id, kind, payload) {
      const member = this.member(id);
      if (this.ended || !member || !member.present) return;
      if (kind === KIND.input) {
        if (payload.length > DIRECT.input) return this.drop(member);
        member.queue.push(payload);
        if (member.queue.length > DIRECT.queue) member.queue = [mergeInputs(member.queue.slice(0, -1)), member.queue[member.queue.length - 1]];
      } else if (kind === KIND.ready) {
        member.ready = true;
        if (this.members.every((other) => other.ready || !other.present)) this.startBeat();
      } else if (kind === KIND.check) {
        if (payload.length !== 6) return this.drop(member);
        const message = packet(KIND.checked, concatBytes(Uint8Array.of(member.index), payload));
        for (const other of this.members) if (other !== member && other.present) this.deliver(other, message);
      } else {
        this.drop(member);
      }
    }

    deliver(member, message) {
      if (member.id === this.host.id) {
        this.host.toGame(message.slice());
        return;
      }
      const wire = this.host.wire(member.id);
      if (!wire || !wire.open) return this.leave(member.id);
      if (wire.buffered() > this.rules.buffered) return this.drop(member);
      if (!wire.sendGame(message)) this.leave(member.id);
    }

    startBeat() {
      if (this.ticking || this.ended) return;
      clearTimeout(this.grace);
      this.ticking = true;
      this.tickStart = now();
      this.ticks = 0;
      if (typeof this.host.onBeatStart === 'function') this.host.onBeatStart();
      this.schedule();
    }

    schedule() {
      const due = this.tickStart + (this.ticks + 1) * this.tickMs;
      this.ticker.schedule(Math.max(0, due - now()));
    }

    // As the relay: counted from the start, a few missed beats sent at once, a longer stall restarts the count.
    run() {
      if (this.ended) return;
      const at = now();
      const late = at - (this.tickStart + (this.ticks + 1) * this.tickMs);
      if (late >= 2) {
        this.lateness.push([at, late]);
        if (this.lateness.length > 400) this.lateness.splice(0, 200);
      }
      const due = Math.floor((at - this.tickStart) / this.tickMs) - this.ticks;
      for (let count = 0; count < Math.min(due, 4) && !this.ended; count += 1) {
        this.ticks += 1;
        this.tick();
      }
      if (this.ended) return;
      if (due > 4) this.tickStart = at - this.ticks * this.tickMs;
      this.schedule();
    }

    tick() {
      let fresh = 0;
      let present = 0;
      const parts = [];
      for (const member of this.members) {
        let input = EMPTY;
        if (member.present) {
          present |= 1 << member.index;
          const waiting = member.queue.length;
          if (waiting) {
            fresh |= 1 << member.index;
            input = waiting === 1 ? member.queue[0] : mergeInputs(member.queue);
            member.last = member.queue[waiting - 1];
            member.queue = [];
            member.repeats = 0;
          } else {
            member.repeats += 1;
            input = member.repeats > this.rules.repeat ? EMPTY : withoutEvents(member.last);
          }
        }
        parts.push(Uint8Array.of(input.length), input);
      }
      const header = new Uint8Array(7);
      const frame = this.frame % 4294967296;
      header[0] = frame & 255;
      header[1] = (frame >>> 8) & 255;
      header[2] = (frame >>> 16) & 255;
      header[3] = (frame >>> 24) & 255;
      header[4] = this.members.length;
      header[5] = fresh;
      header[6] = present;
      this.frame += 1;
      const message = packet(KIND.frame, concatBytes(header, ...parts));
      for (const member of this.members) if (member.present) this.deliver(member, message);
    }

    // A player gone: LEFT among the frames to the others.
    leave(id) {
      const member = this.member(id);
      if (this.ended || !member || !member.present || id === this.host.id) return;
      member.present = false;
      member.queue = [];
      const message = packet(KIND.left, Uint8Array.of(member.index));
      for (const other of this.members) if (other.present) this.deliver(other, message);
      if (this.ticking === false && this.members.every((other) => other.ready || !other.present)) this.startBeat();
    }

    drop(member) {
      const wire = this.host.wire(member.id);
      if (wire) wire.close();
      this.leave(member.id);
    }

    // The worst lateness of a beat in the last 5 seconds, ms.
    worstLate() {
      const since = now() - 5000;
      let worst = 0;
      for (const [at, late] of this.lateness) if (at >= since && late > worst) worst = late;
      return worst;
    }

    stop() {
      this.ended = true;
      clearTimeout(this.grace);
      this.ticker.stop();
    }
  }

  // The page's side of a beat kept in the host's worker: the same calls, passed on.
  class WorkerBeat {
    constructor(online, ids) {
      this.online = online;
      this.late = 0; // the worker's word on its beat's worst lateness lately
      online.worker.postMessage({ t: 'beat', ids });
    }
    worstLate() { return this.late; }
    receive(id, kind, payload) {
      if (this.online.worker) this.online.worker.postMessage({ t: 'game', kind, payload }, [payload.buffer]);
    }
    leave(id) { if (this.online.worker) this.online.worker.postMessage({ t: 'leave', id }); }
    stop() { if (this.online.worker) this.online.worker.postMessage({ t: 'stop' }); }
  }

  // The worker (startWorker): the host's links' channels and the beat on them, away from the page's work.
  function workerMain() {
    const wires = new Map(); // player id -> Wire
    let setup = null;
    let beat = null;
    let stall = 0; // the page's, told to the players with each ping
    let pinger = 0;
    const post = (message, transfer) => root.postMessage(message, transfer || []);
    const tell = (wire, more) => post({ t: 'link', id: wire.id, open: wire.open, closed: wire.closed, version: wire.version,
      times: wire.times.slice(), reported: wire.reported, peerStall: wire.peerStall, ...more });
    const owner = {
      wireOpened(wire) { tell(wire); },
      wireClosed(wire) {
        if (wires.get(wire.id) === wire) wires.delete(wire.id);
        if (beat) beat.leave(wire.id);
        tell(wire);
      },
      wireOpenFast() { /* the players offer the links and open the datagram channels */ },
      wireMessage(wire, data, fast) {
        if (typeof data === 'string') {
          let message;
          try { message = JSON.parse(data); } catch (error) { return; }
          if (!message) return;
          if (message.t === 'ping') {
            wire.answer(message, fast);
            if (Number.isFinite(message.stall)) wire.peerStall = message.stall;
          } else if (message.t === 'hello') {
            wire.greeted(Number(message.v) || 0);
            tell(wire);
          } else if (message.t === 'pong' && Number.isFinite(message.at)) {
            addSample(wire.times, now() - message.at);
            tell(wire);
          } else if (message.t === 'times') {
            wire.reported = { relay: finiteOrNull(message.relay), direct: finiteOrNull(message.direct) };
            if (Number.isFinite(message.stall)) wire.peerStall = message.stall;
            tell(wire);
          }
          return;
        }
        const bytes = new Uint8Array(data);
        const parts = bytes[0] === NUMBERED ? wire.unwrap(bytes) : [bytes];
        for (const part of parts) {
          wire.pending = Uint8Array.from(splitPackets(concatBytes(wire.pending, part), (kind, payload) => {
            if (beat) beat.receive(wire.id, kind, payload.slice());
            else wire.early.push([kind, payload.slice()]);
          }));
        }
      },
    };
    const host = {
      get id() { return setup ? setup.id : 0; },
      get rules() { return setup ? setup.rules : null; },
      get tickMs() { return setup ? setup.tickMs : 100 / 3; },
      wire: (id) => wires.get(id),
      toGame: (bytes) => post({ t: 'frame', bytes: bytes.buffer }, [bytes.buffer]),
      ticker: timeoutTicker,
      onBeatStart: () => post({ t: 'beat', started: true }),
    };
    root.onmessage = (event) => {
      const message = event.data;
      if (!message || typeof message !== 'object') return;
      if (message.t === 'setup') {
        setup = { id: Number(message.id) || 0, rules: message.rules, tickMs: Number(message.tickMs) || 100 / 3 };
        clearInterval(pinger);
        pinger = setInterval(() => {
          for (const wire of wires.values()) if (wire.open) wire.ping(stall);
          if (beat) post({ t: 'beat', late: beat.worstLate() });
        }, DIRECT.pingMs);
        post({ t: 'ready' });
      } else if (message.t === 'probe') {
        try { message.channel.close(); } catch (error) { /* a throwaway */ }
      } else if (message.t === 'channel') {
        let wire = wires.get(message.id);
        if (!wire || wire.closed) {
          wire = new Wire(owner, message.id);
          wires.set(message.id, wire);
        }
        wire.attach(message.channel);
      } else if (message.t === 'beat') {
        if (!beat && setup) beat = new Beat(host, Array.isArray(message.ids) ? message.ids : []);
      } else if (message.t === 'game') {
        if (beat) beat.receive(setup ? setup.id : 0, message.kind, new Uint8Array(message.payload));
      } else if (message.t === 'leave') {
        if (beat) beat.leave(message.id);
      } else if (message.t === 'close') {
        const wire = wires.get(message.id);
        if (wire) wire.close();
      } else if (message.t === 'load') {
        stall = Number(message.stall) || 0;
      } else if (message.t === 'stop') {
        if (beat) beat.stop();
        beat = null;
        clearInterval(pinger);
        for (const wire of [...wires.values()]) wire.close();
        root.close();
      }
    };
  }

  // A timer for the beat on a page: in a worker, since a page's own timers slow down to once a second when
  // its tab is hidden, a worker's do not. (In the host's worker the beat uses plain timers.)
  function createTicker(callback) {
    if (!IN_WORKER && typeof root.Worker === 'function' && typeof root.Blob === 'function' && root.URL && root.URL.createObjectURL) {
      try {
        const source = 'let t=0;onmessage=(e)=>{clearTimeout(t);if(e.data>=0)t=setTimeout(()=>postMessage(0),e.data)};';
        const url = root.URL.createObjectURL(new root.Blob([source], { type: 'text/javascript' }));
        const worker = new root.Worker(url);
        let fallback = null;
        worker.onmessage = () => callback();
        worker.onerror = () => { fallback = timeoutTicker(callback); fallback.schedule(0); };
        return {
          schedule(ms) { if (fallback) fallback.schedule(ms); else worker.postMessage(ms); },
          stop() { if (fallback) fallback.stop(); worker.terminate(); root.URL.revokeObjectURL(url); },
        };
      } catch (error) { /* no workers here (or not from a blob): the page's own timers */ }
    }
    return timeoutTicker(callback);
  }
  function timeoutTicker(callback) {
    let timer = 0;
    return {
      schedule(ms) { clearTimeout(timer); timer = setTimeout(callback, ms); },
      stop() { clearTimeout(timer); },
    };
  }

  const now = () => (root.performance && root.performance.now ? root.performance.now() : Date.now());

  // Each whole protocol 2 message in `bytes` (a part message at the end is left).
  function eachPacket(bytes, each) {
    for (let at = 0; at + 3 <= bytes.length;) {
      const length = bytes[at + 1] | (bytes[at + 2] << 8);
      if (at + 3 + length > bytes.length) return;
      each(bytes[at], bytes.subarray(at + 3, at + 3 + length));
      at += 3 + length;
    }
  }
  function readU32(bytes, at) {
    return (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24)) >>> 0;
  }
  // `bytes` with a KIND.stamp message (the time `at`) before each whole FRAME in it; `each(frame number)`.
  function stampFrames(bytes, at, each) {
    let frames = 0;
    eachPacket(bytes, (kind, payload) => { if (kind === KIND.frame && payload.length >= 4) frames += 1; });
    if (!frames) return bytes;
    const out = new Uint8Array(bytes.length + frames * 9);
    const whole = Math.floor(at);
    const thousandths = Math.max(0, Math.min(999, Math.round((at - whole) * 1000)));
    let to = 0;
    let from = 0;
    eachPacket(bytes, (kind, payload) => {
      const start = payload.byteOffset - bytes.byteOffset - 3;
      if (kind === KIND.frame && payload.length >= 4) {
        out.set(bytes.subarray(from, start), to);
        to += start - from;
        out.set([KIND.stamp, 6, 0, whole & 255, (whole >>> 8) & 255, (whole >>> 16) & 255, (whole >>> 24) & 255, thousandths & 255, thousandths >> 8], to);
        to += 9;
        from = start;
        each(readU32(payload, 0));
      }
    });
    out.set(bytes.subarray(from), to);
    return out;
  }

  // A numbered message (version 2 links): NUMBERED, the number of the last message in it (4 bytes, little
  // endian), how many, then each (2 bytes of length, the message), the oldest first.
  function numbered(last, messages) {
    let size = 6;
    for (const message of messages) size += 2 + message.length;
    const bytes = new Uint8Array(size);
    bytes[0] = NUMBERED;
    bytes[1] = last & 255;
    bytes[2] = (last >>> 8) & 255;
    bytes[3] = (last >>> 16) & 255;
    bytes[4] = (last >>> 24) & 255;
    bytes[5] = messages.length;
    let at = 6;
    for (const message of messages) {
      bytes[at] = message.length & 255;
      bytes[at + 1] = message.length >> 8;
      bytes.set(message, at + 2);
      at += 2 + message.length;
    }
    return bytes;
  }

  // A protocol 2 message: kind, payload length (2 bytes, little endian), payload.
  function packet(kind, payload) {
    const message = new Uint8Array(3 + payload.length);
    message[0] = kind;
    message[1] = payload.length & 255;
    message[2] = payload.length >> 8;
    message.set(payload, 3);
    return message;
  }
  // Calls each(kind, payload, whole) for every complete message in `bytes`; returns what is left.
  function splitPackets(bytes, each) {
    let at = 0;
    while (bytes.length - at >= 3) {
      const length = bytes[at + 1] | (bytes[at + 2] << 8);
      if (bytes.length - at - 3 < length) break;
      each(bytes[at], bytes.subarray(at + 3, at + 3 + length), bytes.subarray(at, at + 3 + length));
      at += 3 + length;
    }
    return bytes.subarray(at);
  }
  function concatBytes(...parts) {
    const filled = parts.filter((part) => part.length);
    if (filled.length === 1) return filled[0];
    const total = filled.reduce((sum, part) => sum + part.length, 0);
    const joined = new Uint8Array(total);
    let at = 0;
    for (const part of filled) {
      joined.set(part, at);
      at += part.length;
    }
    return joined;
  }
  // LOBBY's and STARTED's players: count (1); per player: id (1), flags (1), info length (1), info.
  function readPlayers(payload) {
    const ids = [];
    let at = 1;
    for (let index = 0; index < payload[0] && at + 3 <= payload.length; index += 1) {
      ids.push(payload[at]);
      at += 3 + payload[at + 2];
    }
    return ids;
  }
  // Inputs are bit sets: merged, every bit set in any of them is set (as the relay).
  function mergeInputs(inputs) {
    const merged = new Uint8Array(Math.max(0, ...inputs.map((input) => input.length)));
    for (const input of inputs) for (let index = 0; index < input.length; index += 1) merged[index] |= input[index];
    return merged;
  }
  // A repeated input keeps its held keys but not its one-shot events (byte 0).
  function withoutEvents(input) {
    if (!input.length || input[0] === 0) return input;
    const copy = input.slice();
    copy[0] = 0;
    return copy;
  }
  function addSample(samples, value) {
    samples.push(value);
    if (samples.length > DIRECT.samples) samples.shift();
  }
  function median(samples) {
    if (!samples.length) return null;
    const sorted = samples.slice().sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)];
  }
  function finiteOrNull(value) { return Number.isFinite(value) ? value : null; }
  // An RTCSessionDescription or RTCIceCandidate as plain JSON for the relay.
  function plain(value) {
    if (value && typeof value.toJSON === 'function') return value.toJSON();
    return JSON.parse(JSON.stringify(value));
  }

  function isLoopback(hostname) {
    return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname.endsWith('.localhost');
  }

  function randomRoom() {
    const value = new Uint32Array(1);
    root.crypto.getRandomValues(value);
    return String(100000 + (value[0] % 900000));
  }

  function storageGet(key) {
    try { return root.localStorage.getItem(key); } catch (error) { return null; }
  }
  function storageSet(key, value) {
    try {
      if (value) root.localStorage.setItem(key, value);
      else root.localStorage.removeItem(key);
    } catch (error) { /* private mode: settings last for this visit only */ }
  }

  // The panel above the game: room code, invite link, relay address and connection status.
  // The network in a corner of the game, while in a room: the ping, which way the frames come (direct or
  // through the relay), how unevenly they came lately ("jitter"; much of it means the game waits now and
  // then) and, when it does, how far behind the others the game runs.
  function createCorner(online, document) {
    const stage = document.getElementById('stage');
    if (!stage) return;
    const corner = document.createElement('div');
    corner.id = 'online-corner';
    corner.hidden = true;
    corner.setAttribute('aria-hidden', 'true');
    corner.style.cssText = 'position:absolute;left:8px;bottom:6px;z-index:5;pointer-events:none;padding:2px 7px;'
      + 'border-radius:5px;background:rgba(0,0,0,.5);color:#fff;font:600 12px/1.45 system-ui,sans-serif;'
      + 'letter-spacing:.01em;white-space:nowrap;text-shadow:0 1px 1px #000';
    stage.appendChild(corner);
    const ms = (value) => `${Math.round(value)} ms`;
    const show = () => {
      const stats = online.netStats();
      if (!stats || stage.classList.contains('hf')) {
        corner.hidden = true;
        return;
      }
      const parts = [`Ping ${stats.ping === null ? '…' : ms(stats.ping)}`, stats.way === 'direct' ? 'direct' : 'relay'];
      let trouble = false;
      if (stats.jitter !== null) {
        parts.push(`jitter ${ms(stats.jitter)}`);
        trouble = stats.jitter >= 100;
      }
      if (stats.behind !== null && stats.behind >= 500) {
        parts.push(`behind ${(stats.behind / 1000).toFixed(1)} s`);
        trouble = true;
      }
      // This computer busy (its page stalled that long lately): its own game waits; the host's computer busy:
      // with the beat on the host's page, everyone's frames come late.
      if (stats.busy >= 40) parts.push(`busy ${ms(stats.busy)}`);
      if (stats.peerBusy !== null && stats.peerBusy >= 40) parts.push(`${stats.host ? 'player' : 'host'} busy ${ms(stats.peerBusy)}`);
      corner.textContent = parts.join(' · ');
      corner.style.color = trouble ? '#ffb74d' : '#fff';
      corner.hidden = false;
    };
    setInterval(show, 500);
    online.onChange(show);
  }

  function createPanel(online, document) {
    const stage = document.getElementById('stage') || document.getElementById('canvas');
    if (!stage || !stage.parentNode) return;
    const panel = document.createElement('section');
    panel.id = 'online';
    panel.setAttribute('aria-label', 'Online play');
    panel.innerHTML = `
      <style>
        #online { box-sizing: border-box; margin: .75rem 0; padding: .65rem .8rem;
          border: 1px solid rgba(127, 127, 127, .4); border-radius: 8px; font-size: .9rem; }
        #online .row { display: flex; flex-wrap: wrap; align-items: center; gap: .45rem .6rem; margin: .3rem 0; }
        #online label { display: flex; align-items: center; gap: .4rem; min-width: 0; }
        #online input { font: inherit; padding: .3rem .45rem; min-width: 0; box-sizing: border-box; }
        #online-room { width: 8.5rem; letter-spacing: .08em; }
        #online .relay { flex: 1 1 18rem; }
        #online-relay { flex: 1 1 auto; width: 100%; }
        #online button { padding: .35rem .7rem; cursor: pointer; }
        #online .help { margin: .35rem 0 0; opacity: .8; font-size: .85rem; }
        #online-status[data-state="connected"] { color: #5fd38d; }
        #online-status[data-state="failed"] { color: #ff8a80; }
      </style>
      <div class="row"><strong>Online play</strong><span id="online-status" role="status"></span></div>
      <div class="row">
        <label>Room <input id="online-room" inputmode="numeric" pattern="[0-9]*" maxlength="12" autocomplete="off"></label>
        <button type="button" id="online-new">New room</button>
        <button type="button" id="online-copy">Copy invite link</button>
        <button type="button" id="online-report" title="The network's last minute, as text, for a bug report">Copy network report</button>
      </div>
      <div class="row">
        <label class="relay">Relay <input id="online-relay" type="url" placeholder="wss://relay.example.com/relay" autocomplete="off" spellcheck="false"></label>
        <span id="online-relay-check"></span>
      </div>
      <p class="help">Host: <b>Network Game &rarr; Host</b>, then <b>START</b> once everyone is in (2 to 8 players).
        Friends: open your invite link, then <b>Network Game &rarr; Connect</b> with the address left empty (or type the room code).
        Everyone needs the same game version. Players who reach the host directly (on one network, often across the
        Internet too) play without the relay in between; the host then keeps the game's beat: keep the host's tab open.</p>`;
    stage.parentNode.insertBefore(panel, stage);
    // As wide as the game: the bundle page caps the canvas width, the project site does not.
    const canvas = document.getElementById('canvas');
    const widest = canvas && root.getComputedStyle ? root.getComputedStyle(canvas).maxWidth : 'none';
    if (widest && widest !== 'none') panel.style.maxWidth = widest;

    // SDL listens for keys on the window; keep typing in these fields out of the game.
    for (const type of ['keydown', 'keyup', 'keypress']) panel.addEventListener(type, (event) => event.stopPropagation());

    const $ = (id) => panel.querySelector('#' + id);
    const status = $('online-status');
    const roomInput = $('online-room');
    const relayInput = $('online-relay');
    const relayCheck = $('online-relay-check');
    roomInput.value = online.room;
    relayInput.value = online.relay;

    const render = () => {
      const room = online.activeRoom || online.room;
      let text;
      let state = 'idle';
      const players = online.players === 1 ? '1 player' : `${online.players} players`;
      const direct = online.directText();
      const how = direct ? ` (${direct})` : '';
      if (online.state === STATUS.connected && online.started) {
        text = `Playing in room ${room} (${players}${direct ? `, ${direct}` : ''}).`;
        state = 'connected';
      } else if (online.state === STATUS.connected && online.role === 'host') {
        text = `Hosting room ${room}: ${players} in${how}. Press START in the game when everyone is here.`;
        state = 'connected';
      } else if (online.state === STATUS.connected) {
        text = `In room ${room} (${players}): waiting for the host to start${how}.`;
        state = 'connected';
      } else if (online.state === STATUS.listening) text = `Opening room ${room}...`;
      else if (online.state === STATUS.connecting) text = `Joining room ${room}...`;
      else if (online.lastFailure) { text = online.lastFailure; state = 'failed'; }
      else text = online.relay ? `Not connected. Your room: ${online.room}` : 'Set a relay address to play online.';
      status.textContent = text;
      status.dataset.state = state;
    };
    online.onChange(render);

    roomInput.addEventListener('input', () => {
      online.setRoom(roomInput.value);
      if (roomInput.value !== online.room) roomInput.value = online.room;
      storageSet(STORAGE.room, online.room);
      render();
    });
    $('online-new').addEventListener('click', () => {
      online.setRoom(randomRoom());
      roomInput.value = online.room;
      storageSet(STORAGE.room, online.room);
      render();
    });
    $('online-copy').addEventListener('click', async () => {
      const link = new URL(root.location.href);
      link.searchParams.set('room', online.room);
      if (online.relay) link.searchParams.set('relay', online.relay);
      // Friends play the same game: the original, or the same mod.
      if (online.pack) link.searchParams.set('pack', online.pack);
      else link.searchParams.delete('pack');
      // The project site shows the game further down the page, in its "play" section.
      link.hash = document.getElementById('play') ? 'play' : '';
      const button = $('online-copy');
      try {
        await root.navigator.clipboard.writeText(link.href);
        button.textContent = 'Link copied';
      } catch (error) {
        root.prompt('Send this link to your friend:', link.href);
      }
      setTimeout(() => { button.textContent = 'Copy invite link'; }, 2000);
    });

    $('online-report').addEventListener('click', async () => {
      const button = $('online-report');
      const text = online.report();
      try {
        await root.navigator.clipboard.writeText(text);
        button.textContent = 'Report copied';
      } catch (error) {
        root.prompt('The network report:', text);
      }
      setTimeout(() => { button.textContent = 'Copy network report'; }, 2000);
    });

    let checkTimer = 0;
    const checkRelay = async () => {
      relayCheck.textContent = '';
      if (!online.relay) return;
      let health;
      try {
        health = new URL(online.relay);
        health.protocol = health.protocol === 'ws:' ? 'http:' : 'https:';
        health.pathname = health.pathname.replace(/[^/]*$/, 'healthz'); // /relay -> /healthz
        health.search = '';
      } catch (error) {
        relayCheck.textContent = 'invalid address';
        return;
      }
      const checked = online.relay;
      const request = () => fetch(health.href, {
        cache: 'no-store',
        signal: typeof AbortSignal !== 'undefined' && AbortSignal.timeout ? AbortSignal.timeout(5000) : undefined,
      });
      try {
        const first = await request();
        if (!first.ok) throw new Error('status ' + first.status);
        let info = {};
        try { info = await first.json(); } catch (error) { /* an older relay: no details */ }
        // Later requests reuse the connection, so the quickest of them is close to the ping.
        let ping = Infinity;
        for (let attempt = 0; attempt < 3; attempt += 1) {
          const started = performance.now();
          await request();
          ping = Math.min(ping, Math.round(performance.now() - started));
        }
        if (checked === online.relay) {
          const current = info && Array.isArray(info.protocols) && info.protocols.includes(2);
          relayCheck.textContent = current ? `relay OK, ${ping} ms${info.installer ? ', game data ready' : ''}`
            : 'relay too old: update it (install-vps.sh)';
          relayCheck.title = 'Your own keys take effect about one ping (plus up to 33 ms) after you press them; '
            + 'a player far from the relay never slows the others down.';
        }
      } catch (error) {
        if (checked === online.relay) relayCheck.textContent = 'relay unreachable';
      }
    };
    relayInput.addEventListener('input', () => {
      online.setRelay(relayInput.value);
      storageSet(STORAGE.relay, online.relay);
      render();
      clearTimeout(checkTimer);
      checkTimer = setTimeout(checkRelay, 700);
    });
    render();
    checkRelay();
  }

  const api = { OnlineTransport, STATUS, ROOM_PATTERN, CLOSE_REASONS, DIRECT, stampFrames, KIND };
  if (typeof module === 'object' && module.exports) {
    module.exports = api; // tests
    return;
  }
  if (IN_WORKER) {
    workerMain();
    return;
  }

  // Page start: an invite link's ?room= and ?relay= win, then this browser's saved choices,
  // then a relay the site sets with  <script>window.OPENLF2_RELAY = 'wss://...'</script>.
  let params;
  try { params = new URLSearchParams(root.location.search); } catch (error) { params = new URLSearchParams(); }
  const linkedRoom = (params.get('room') || '').replace(/\D/g, '').slice(0, 12);
  const linkedRelay = (params.get('relay') || '').trim();
  if (linkedRoom) storageSet(STORAGE.room, linkedRoom);
  if (linkedRelay) storageSet(STORAGE.relay, linkedRelay);
  const online = new OnlineTransport({
    room: linkedRoom || storageGet(STORAGE.room) || randomRoom(),
    relay: linkedRelay || storageGet(STORAGE.relay) || root.OPENLF2_RELAY || '',
  });
  if (!storageGet(STORAGE.room)) storageSet(STORAGE.room, online.room);
  root.OpenLF2Online = online;
  if (root.document) {
    const build = () => {
      createPanel(online, root.document);
      createCorner(online, root.document);
    };
    if (root.document.readyState === 'loading') root.document.addEventListener('DOMContentLoaded', build);
    else build();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
