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
  });
  const DIRECT = Object.freeze({
    // Public STUN servers: how a direct connection crosses home routers when the players are not on one LAN.
    iceServers: [{ urls: ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478'] }],
    connectMs: 12000, // a direct connection not open by then is given up (the relay keeps the beat)
    pingMs: 2000, // how often both ways are timed, in the lobby and during play
    samples: 5, // round trips kept (their median counts)
    slack: 10, // ms a player's direct connection may be slower than his way through the relay
    input: 16, queue: 64, // the relay's limits (ROOM_LIMITS)
  });
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
      this.beat = null; // the host's page, keeping the beat
      this.incoming = EMPTY; // relay messages not yet complete
      this.outgoing = EMPTY; // game messages not yet complete
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
            if (!link || !link.send(whole.slice())) {
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
          if (message.direct && typeof this.RTCPeerConnection === 'function' && this.id) this.startDirect(message.direct);
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

    // Bytes for the game.
    receive(bytes) {
      this.chunks.push(bytes);
      this.buffered += bytes.length;
    }

    // ---- Direct connections -------------------------------------------------------------------

    // The relay passes on set-ups: time the way to it, and reach the host's page directly.
    startDirect(rules) {
      this.rules = {
        repeat: Number(rules.repeat) || 15, grace: Number(rules.grace) || 5000, buffered: Number(rules.buffered) || 1048576,
      };
      if (this.role !== 'host') this.links.set('host', new Link(this, 'host', true));
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
      const link = this.links.get('host');
      if (link && link.open) link.ping();
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

    // A direct connection's messages: timing (text), and the game's (binary): to the host, the
    // game's INPUT, READY and CHECK; from it, the beat's frames.
    onLinkMessage(link, data) {
      if (typeof data === 'string') {
        let message;
        try { message = JSON.parse(data); } catch (error) { return; }
        if (!message) return;
        if (message.t === 'ping') link.say({ t: 'pong', at: message.at });
        else if (message.t === 'pong' && Number.isFinite(message.at)) {
          addSample(link.times, now() - message.at);
          // What the host's page weighs at START: both ways, from here.
          link.say({ t: 'times', relay: median(this.relayTimes), direct: median(link.times) });
          this.emit();
        }
        else if (message.t === 'times') {
          link.reported = { relay: finiteOrNull(message.relay), direct: finiteOrNull(message.direct) };
          this.emit();
        }
        return;
      }
      const bytes = new Uint8Array(data);
      if (this.role !== 'host') {
        if (this.beatBy === 'host') this.receive(bytes);
        return;
      }
      link.pending = Uint8Array.from(splitPackets(concatBytes(link.pending, bytes), (kind, payload) => {
        if (this.beat) this.beat.receive(link.id, kind, payload.slice());
        else link.early.push([kind, payload.slice()]);
      }));
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
          if (this.beatBy === 'host' && this.role === 'host' && !this.beat) this.beat = new Beat(this, order);
        }
      }));
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

  // A direct connection to another page of the room (WebRTC data channel, ordered and reliable).
  class Link {
    constructor(online, id, offerer) {
      this.online = online;
      this.id = id;
      this.open = false;
      this.closed = false;
      this.times = []; // round trips through it
      this.reported = null; // the player's own times (host's page)
      this.pending = EMPTY; // its messages not yet complete (host's page)
      this.early = []; // its messages that came before the beat began (host's page)
      this.queue = Promise.resolve();
      this.channel = null;
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
        this.queue = this.queue.then(async () => {
          await this.pc.setLocalDescription(await this.pc.createOffer());
          online.signal(id, { description: plain(this.pc.localDescription) });
        }).catch(() => this.close());
      } else {
        this.pc.ondatachannel = (event) => this.attach(event.channel);
      }
    }

    attach(channel) {
      this.channel = channel;
      channel.binaryType = 'arraybuffer';
      channel.onopen = () => {
        if (this.closed) return;
        this.open = true;
        clearTimeout(this.timer);
        this.online.linkChanged(this);
      };
      channel.onclose = () => this.close();
      channel.onmessage = (event) => { if (!this.closed) this.online.onLinkMessage(this, event.data); };
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

    send(bytes) {
      if (!this.open || this.channel.readyState !== 'open') return false;
      try { this.channel.send(bytes); } catch (error) { return false; }
      return true;
    }
    say(message) { if (this.open) this.send(JSON.stringify(message)); }
    ping() { this.say({ t: 'ping', at: now() }); }
    buffered() { return this.channel ? this.channel.bufferedAmount : 0; }

    close() {
      if (this.closed) return;
      this.closed = true;
      const wasOpen = this.open;
      this.open = false;
      clearTimeout(this.timer);
      if (this.channel) {
        this.channel.onopen = this.channel.onclose = this.channel.onmessage = null;
        try { this.channel.close(); } catch (error) { /* closed */ }
      }
      if (this.pc) {
        this.pc.onicecandidate = this.pc.onconnectionstatechange = this.pc.ondatachannel = null;
        try { this.pc.close(); } catch (error) { /* closed */ }
      }
      if (wasOpen || this.online.links.size) this.online.linkChanged(this);
    }
  }

  // The beat kept on the host's page, by the relay's rules (tools/relay/server.js, "Rooms"): every
  // beat, FRAME with each player's input (the inputs since the last beat merged; the newest kept,
  // without its one-shot events, while nothing new comes; nothing after `repeat` beats without news),
  // CHECK passed on as CHECKED, LEFT when a player is gone; the beat begins once every game is READY,
  // or after `grace` ms; a player whose connection falls behind by more than `buffered` bytes is let go.
  class Beat {
    constructor(online, ids) {
      this.online = online;
      this.rules = online.rules;
      this.tickMs = online.tickMs;
      this.members = ids.map((id, index) => ({ id, index, present: true, ready: false, queue: [], last: EMPTY, repeats: 0 }));
      this.frame = 0;
      this.ticking = false;
      this.ticks = 0;
      this.tickStart = 0;
      this.ended = false;
      this.ticker = createTicker(() => this.run());
      this.grace = setTimeout(() => this.startBeat(), this.rules.grace);
      for (const member of this.members) {
        if (member.id === online.id) continue;
        const link = online.links.get(member.id);
        if (!link || !link.open) {
          this.leave(member.id);
          continue;
        }
        const early = link.early;
        link.early = [];
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
      if (member.id === this.online.id) {
        this.online.receive(message.slice());
        return;
      }
      const link = this.online.links.get(member.id);
      if (!link || !link.open) return this.leave(member.id);
      if (link.buffered() > this.rules.buffered) return this.drop(member);
      if (!link.send(message)) this.leave(member.id);
    }

    startBeat() {
      if (this.ticking || this.ended) return;
      clearTimeout(this.grace);
      this.ticking = true;
      this.tickStart = now();
      this.ticks = 0;
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
      if (this.ended || !member || !member.present || id === this.online.id) return;
      member.present = false;
      member.queue = [];
      const message = packet(KIND.left, Uint8Array.of(member.index));
      for (const other of this.members) if (other.present) this.deliver(other, message);
      if (this.ticking === false && this.members.every((other) => other.ready || !other.present)) this.startBeat();
    }

    drop(member) {
      const link = this.online.links.get(member.id);
      if (link) link.close();
      this.leave(member.id);
    }

    stop() {
      this.ended = true;
      clearTimeout(this.grace);
      this.ticker.stop();
    }
  }

  // A timer for the beat. In a browser it runs in a worker: a page's own timers slow down to once a
  // second when its tab is hidden, a worker's do not.
  function createTicker(callback) {
    if (typeof root.Worker === 'function' && typeof root.Blob === 'function' && root.URL && root.URL.createObjectURL) {
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

  const api = { OnlineTransport, STATUS, ROOM_PATTERN, CLOSE_REASONS, DIRECT };
  if (typeof module === 'object' && module.exports) {
    module.exports = api; // tests
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
    const build = () => createPanel(online, root.document);
    if (root.document.readyState === 'loading') root.document.addEventListener('DOMContentLoaded', build);
    else build();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
