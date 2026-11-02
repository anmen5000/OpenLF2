// SPDX-License-Identifier: MIT
//
// Hero Fighter's network rooms with direct links between the players' pages. The game's socket (Ruffle's
// socket proxy opens a WebSocket to the relay's room, tools/relay/hf.js) is this file's object instead: it
// talks to the relay as before, and besides passes the game's frames (its keys, frame by frame) straight to
// the other pages of the room over WebRTC data channels, and gives the game the others' frames from
// whichever way brings each first. The relay stays the room's server and still passes every frame on, so
// a link that never opens (a network that allows none) or breaks only means frames come the usual way.
// On one LAN a frame takes a millisecond or two instead of the trip to the relay and back.
//
//   HfDirect.supported(window)          whether this browser can (WebRTC)
//   HfDirect.install(window, options)   from then on, Ruffle's WebSockets to a Hero Fighter room with direct=1
//                                       in their address are made here; options.status(text) hears how the
//                                       links are, options.log(text) what went wrong, options.iceServers
//
// The relay's side: tools/relay/hf-room.js, "Direct links". The game's frames: <f><c>computer</c><i>frame</i>
// then each player's keys; a game reads another's frame k only after its frame k - 1 (frames say "as
// before"), each once, and none of a fight before <allstartedgame>: the Merger below sees to that.
'use strict';

(function factory(root) {
  const ICE_SERVERS = [{ urls: 'stun:stun.l.google.com:19302' }, { urls: 'stun:stun.cloudflare.com:3478' }];
  const CONNECT_MS = 12000; // a link not open by then is given up
  const PING_MS = 2000;
  const HELD_LIMIT = 600; // frames from a link kept while an earlier one is missing
  const EARLY_LIMIT = 300; // frame messages kept for a fight this page has not begun yet
  const CHANNEL_LIMIT = 65536; // bytes waiting on a link beyond which frames go by the relay only
  // Besides the reliable channel, a datagram channel (never sends again what was lost): each message on it
  // holds the newest frames sent, so a frame lost on the way comes with the next message, 67 ms later,
  // where the reliable channel would hold up everything after it until it is sent again (a quarter of a
  // second or more on Wi-Fi).
  const FAST_LABEL = 'hf-fast';
  const DATAGRAM = 1100; // characters a datagram holds at most (one network packet)
  const RECENT = 16; // frames kept for the datagrams
  const FRAME = /^<f><c>(\d+)<\/c><i>(\d+)<\/i>/;
  const now = () => (root.performance && typeof root.performance.now === 'function' ? root.performance.now() : Date.now());

  // The game reads player 2's hire number from <n1> (see tools/relay/hf-room.js, fixCommandNumber, which the
  // relay applies to the frames it passes on): the same for frames that come directly.
  function fixCommandNumber(line) {
    if (line.indexOf('<m2>') < 0 || line.indexOf('<n1>') >= 0) return line;
    const number = /<n2>([^<]*)<\/n2>/.exec(line);
    const end = line.lastIndexOf('</f>');
    if (!number || end < 0) return line;
    return `${line.slice(0, end)}<n1>${number[1]}</n1>${line.slice(end)}`;
  }

  // Where the element that starts at `start` ends (the index after it), -1 when it has not all come yet,
  // -2 for text that is no element. The room's messages: elements, CDATA in some, no attributes to speak of.
  function elementEnd(text, start) {
    if (text[start] !== '<') return -2;
    const length = text.length;
    let depth = 0;
    let at = start;
    while (at < length) {
      const open = text.indexOf('<', at);
      if (open < 0) return -1;
      if (depth === 0 && open !== start) return -2;
      if (text.startsWith('<![CDATA[', open)) {
        const close = text.indexOf(']]>', open + 9);
        if (close < 0) return -1;
        at = close + 3;
        if (depth === 0) return -2;
        continue;
      }
      if (text.startsWith('<!--', open) || text.startsWith('<?', open)) {
        const close = text.indexOf(text[open + 1] === '?' ? '?>' : '-->', open + 2);
        if (close < 0) return -1;
        at = close + (text[open + 1] === '?' ? 2 : 3);
        if (depth === 0) return at;
        continue;
      }
      let k = open + 1;
      let quote = 0;
      for (; k < length; k += 1) {
        const c = text.charCodeAt(k);
        if (quote) { if (c === quote) quote = 0; } else if (c === 34 || c === 39) quote = c; else if (c === 62) break;
      }
      if (k >= length) return -1;
      if (text.charCodeAt(open + 1) === 47) depth -= 1; // </name>
      else if (text.charCodeAt(k - 1) !== 47) depth += 1; // <name>, not <name/>
      at = k + 1;
      if (depth <= 0) return at;
    }
    return -1;
  }

  // A stream of elements, split as they complete. push(text) returns them (each with the white space before
  // it) or null when the stream holds something else (then nothing more is split).
  class Elements {
    constructor() { this.text = ''; }
    push(text) {
      this.text += text;
      const elements = [];
      let at = 0;
      for (;;) {
        let start = at;
        while (start < this.text.length && /\s/.test(this.text[start])) start += 1;
        if (start >= this.text.length) break;
        const end = elementEnd(this.text, start);
        if (end === -2) return null;
        if (end < 0) break;
        elements.push(this.text.slice(at, end));
        at = end;
      }
      this.text = this.text.slice(at);
      return elements;
    }
  }

  // What the game is given, from the relay and from the links: the relay's messages in their order, and
  // each other game's frames once and in order, from whichever way brings them first, only during a fight
  // this page has begun (a fight's number, from the relay's {t: 'fight'}, takes effect at its
  // <allstartedgame>). deliver(text): to the game.
  class Merger {
    constructor(deliver) {
      this.deliver = deliver;
      this.elements = new Elements();
      this.raw = false; // the relay's stream could not be split: passed on as it comes, no direct frames
      this.next = new Map(); // computer -> the number of its next frame for the game (in the fight)
      this.fight = null; // the fight being played: its number (frames of others are taken while it lasts)
      this.coming = null; // { n, fighting }: the fight the relay announced, until its <allstartedgame>
      this.ended = 0; // the number of the last fight seen (frames of it or before are thrown away)
      this.held = new Map(); // computer -> frame number -> frame: came directly before the one before it
      this.early = []; // { n, cid, lines }: direct frames of the announced fight, before it begins here
      this.counts = { direct: 0, relay: 0 };
    }

    // The next fight: its number, and whether this page's game is in it.
    announce(n, fighting) {
      this.coming = { n, fighting };
    }

    // From the relay: its text, as it comes.
    fromRelay(text) {
      if (this.raw) { this.deliver(text); return; }
      const elements = this.elements.push(text);
      if (!elements) {
        this.raw = true;
        this.fight = null;
        const rest = this.elements.text;
        this.elements.text = '';
        this.deliver(rest);
        return;
      }
      let out = '';
      for (const element of elements) {
        const body = element.trimStart();
        if (body.startsWith('<f>')) {
          out += this.relayFrame(body);
          continue;
        }
        out += element;
        if (body.startsWith('<allstartedgame')) out += this.begin();
        else if (body.startsWith('<status>') && !/<page>FIGHTING<\/page>/.test(body)) this.end();
      }
      if (out) this.deliver(out);
    }

    relayFrame(body) {
      const id = FRAME.exec(body);
      if (!this.fight || !id) return fixCommandNumber(body) + '\n';
      const cid = Number(id[1]);
      const frame = Number(id[2]);
      const next = this.nextOf(cid);
      if (frame < next) return ''; // it came directly
      this.counts.relay += 1;
      // (A frame after one not given yet: the relay skips none, so the count was wrong; the relay is right.)
      this.next.set(cid, frame + 1);
      return fixCommandNumber(body) + '\n' + this.drain(cid);
    }

    // From a link: frames of the game `cid` in fight `n`.
    fromPeer(cid, n, lines) {
      if (this.raw || !Array.isArray(lines)) return;
      if (!this.fight || n !== this.fight.n) {
        if (n > this.ended && (!this.fight || n > this.fight.n) && this.early.length < EARLY_LIMIT) this.early.push({ n, cid, lines });
        return;
      }
      const out = this.take(cid, lines);
      if (out) this.deliver(out);
    }

    take(cid, lines) {
      let out = '';
      for (const line of lines) {
        if (typeof line !== 'string') continue;
        const id = FRAME.exec(line);
        if (!id || Number(id[1]) !== cid) continue;
        const frame = Number(id[2]);
        const next = this.nextOf(cid);
        if (frame < next) continue;
        if (frame > next) {
          let held = this.held.get(cid);
          if (!held) this.held.set(cid, held = new Map());
          if (held.size < HELD_LIMIT) held.set(frame, line);
          continue;
        }
        this.counts.direct += 1;
        this.next.set(cid, frame + 1);
        out += fixCommandNumber(line) + '\n' + this.drain(cid);
      }
      return out;
    }

    nextOf(cid) { return this.next.get(cid) || 0; }

    drain(cid) {
      const held = this.held.get(cid);
      if (!held) return '';
      let out = '';
      for (let frame = this.nextOf(cid); held.has(frame); frame += 1) {
        out += fixCommandNumber(held.get(frame)) + '\n';
        held.delete(frame);
        this.counts.direct += 1;
        this.next.set(cid, frame + 1);
      }
      for (const frame of held.keys()) if (frame < this.nextOf(cid)) held.delete(frame);
      return out;
    }

    // <allstartedgame>: the announced fight begins here; the direct frames that came for it already follow.
    begin() {
      const coming = this.coming;
      this.coming = null;
      this.held.clear();
      this.next = new Map();
      this.counts = { direct: 0, relay: 0 };
      this.fight = coming && coming.fighting ? { n: coming.n } : null;
      if (coming) this.ended = Math.max(this.ended, coming.n - 1);
      const early = this.early;
      this.early = [];
      if (!this.fight) return '';
      let out = '';
      for (const message of early) {
        if (message.n === this.fight.n) out += this.take(message.cid, message.lines);
        else if (message.n > this.fight.n) this.early.push(message);
      }
      return out;
    }

    // Back to the menus: no more frames of that fight.
    end() {
      if (!this.fight) return;
      this.ended = Math.max(this.ended, this.fight.n);
      this.fight = null;
      this.held.clear();
      if (this.onEnd) this.onEnd(this.counts);
    }
  }

  // A direct link to another page of the room (a WebRTC data channel, ordered and reliable).
  class Link {
    constructor(owner, peer, offerer) {
      owner.failed.delete(peer.id);
      this.owner = owner;
      this.peer = peer; // { id, cid, name }
      this.open = false;
      this.closed = false;
      this.times = [];
      this.reported = false;
      this.queue = Promise.resolve();
      this.channel = null;
      this.fast = null;
      try {
        this.pc = new owner.win.RTCPeerConnection({ iceServers: owner.options.iceServers || ICE_SERVERS });
      } catch (error) {
        this.pc = null;
        this.closed = true;
        return;
      }
      this.pc.onicecandidate = (event) => {
        if (event.candidate) owner.signal(peer.id, { candidate: plain(event.candidate) });
      };
      this.pc.onconnectionstatechange = () => {
        const state = this.pc.connectionState;
        if (state === 'failed' || state === 'closed') this.close();
      };
      this.timer = setTimeout(() => { if (!this.open) this.close(); }, CONNECT_MS);
      if (offerer) {
        this.attach(this.pc.createDataChannel('hf', { ordered: true }));
        this.attach(this.pc.createDataChannel(FAST_LABEL, { ordered: false, maxRetransmits: 0 }));
        this.queue = this.queue.then(async () => {
          await this.pc.setLocalDescription(await this.pc.createOffer());
          owner.signal(peer.id, { description: plain(this.pc.localDescription) });
        }).catch(() => this.close());
      } else {
        this.pc.ondatachannel = (event) => this.attach(event.channel);
      }
    }

    attach(channel) {
      if (channel.label === FAST_LABEL) {
        this.fast = channel;
        channel.onclose = () => { if (this.fast === channel) this.fast = null; };
        channel.onmessage = (event) => this.onMessage(event);
        return;
      }
      this.channel = channel;
      channel.onopen = () => {
        if (this.closed) return;
        this.open = true;
        clearTimeout(this.timer);
        this.ping();
        this.pinger = setInterval(() => this.ping(), PING_MS);
        this.owner.linkChanged(this);
      };
      channel.onclose = () => this.close();
      channel.onmessage = (event) => this.onMessage(event);
    }

    onMessage(event) {
      if (this.closed || typeof event.data !== 'string') return;
      let message;
      try { message = JSON.parse(event.data); } catch (error) { return; }
      if (message && typeof message === 'object') this.receive(message);
    }

    receive(message) {
      if (message.t === 'f') this.owner.merger.fromPeer(this.peer.cid, Number(message.e), message.f);
      else if (message.t === 'ping') this.say({ t: 'pong', at: message.at });
      else if (message.t === 'pong' && Number.isFinite(message.at)) {
        this.times.push(Math.max(0, now() - message.at));
        if (this.times.length > 5) this.times.shift();
        if (!this.reported) {
          this.reported = true;
          this.owner.linkChanged(this);
        } else {
          this.owner.showStatus();
        }
      }
    }

    // The other page's offer, answer or route (in order: a route may not come before its offer).
    signal(data) {
      if (this.closed || !data || typeof data !== 'object') return;
      this.queue = this.queue.then(async () => {
        if (this.closed) return;
        if (data.description) {
          await this.pc.setRemoteDescription(data.description);
          if (data.description.type === 'offer') {
            await this.pc.setLocalDescription(await this.pc.createAnswer());
            this.owner.signal(this.peer.id, { description: plain(this.pc.localDescription) });
          }
        } else if (data.candidate) {
          await this.pc.addIceCandidate(data.candidate);
        }
      }).catch(() => { /* a route that does not work: others may */ });
    }

    say(message) { return this.sendText(JSON.stringify(message)); }

    sendText(text) {
      if (!this.open || !this.channel || this.channel.readyState !== 'open') return false;
      if (this.channel.bufferedAmount > CHANNEL_LIMIT) return false;
      try { this.channel.send(text); } catch (error) { return false; }
      return true;
    }

    // A datagram: lost or not, nothing waits for it.
    sendFast(text) {
      const fast = this.fast;
      if (!this.open || !fast || fast.readyState !== 'open' || fast.bufferedAmount > CHANNEL_LIMIT / 4) return;
      try { fast.send(text); } catch (error) { /* the reliable copy */ }
    }

    ping() { this.say({ t: 'ping', at: now() }); }

    time() {
      if (!this.times.length) return null;
      const sorted = [...this.times].sort((a, b) => a - b);
      return sorted[Math.floor(sorted.length / 2)];
    }

    close() {
      if (this.closed) return;
      this.closed = true;
      const wasOpen = this.open;
      this.open = false;
      clearTimeout(this.timer);
      clearInterval(this.pinger);
      for (const channel of [this.channel, this.fast]) {
        if (!channel) continue;
        channel.onopen = channel.onclose = channel.onmessage = null;
        try { channel.close(); } catch (error) { /* closed */ }
      }
      this.fast = null;
      if (this.pc) {
        this.pc.onicecandidate = this.pc.onconnectionstatechange = this.pc.ondatachannel = null;
        try { this.pc.close(); } catch (error) { /* closed */ }
      }
      this.owner.linkChanged(this, wasOpen);
    }
  }

  // The game's socket: what Ruffle takes for a WebSocket to the relay's room (the events and calls it uses).
  const Base = typeof root.EventTarget === 'function' ? root.EventTarget : class {};
  class DirectSocket extends Base {
    constructor(url, win, options) {
      super();
      this.win = win;
      this.options = options;
      this.url = url;
      this.readyState = 0;
      this.protocol = '';
      this.extensions = '';
      this.bufferedAmount = 0;
      this.onopen = this.onmessage = this.onerror = this.onclose = null;
      this.kind = 'blob';
      this.id = '';
      this.cid = -1;
      this.peers = new Map(); // id -> { id, cid, name, since }
      this.failed = new Set(); // ids of the pages whose link closed (frames through the relay)
      this.links = new Map(); // id -> Link
      this.fighting = new Set(); // ids of the pages in this fight
      this.spoken = false; // the relay knows direct links (it greeted with {t: 'hello'})
      this.out = new Elements(); // the game's own messages, for its frames
      this.reading = Promise.resolve(); // the game's Blobs, read in order
      this.encoder = new win.TextEncoder();
      this.fromRelay = new win.TextDecoder();
      this.fromGame = new win.TextDecoder();
      this.merger = new Merger((text) => this.toGame(text));
      this.merger.onEnd = (counts) => this.fightEnded(counts);
      const ws = new options.NativeWebSocket(url);
      ws.binaryType = 'arraybuffer';
      this.ws = ws;
      ws.onopen = () => {
        this.readyState = 1;
        this.fire(new win.Event('open'));
      };
      this.relayTimes = []; // round trips to the relay (its pong)
      this.pinger = setInterval(() => { if (this.spoken) this.say({ t: 'ping', at: now() }); }, PING_MS);
      ws.onmessage = (event) => {
        if (typeof event.data === 'string') { this.control(event.data); return; }
        const bytes = event.data instanceof ArrayBuffer ? new Uint8Array(event.data) : new Uint8Array(event.data.buffer || event.data);
        this.merger.fromRelay(this.fromRelay.decode(bytes, { stream: true }));
      };
      ws.onerror = () => this.fire(new win.Event('error'));
      ws.onclose = (event) => {
        this.readyState = 3;
        this.closeLinks();
        if (typeof options.status === 'function') {
          try { options.status('', null); } catch (error) { /* only shown */ }
        }
        this.fire(closeEvent(win, event));
      };
    }

    get binaryType() { return this.kind; }
    set binaryType(value) { this.kind = value === 'arraybuffer' ? 'arraybuffer' : 'blob'; }

    // The game's bytes: to the relay as they are; its frames to the other pages of the fight too. (Ruffle
    // sends a Blob: the relay gets it at once, its frames are read from it as soon as it can be read.)
    send(data) {
      if (data && typeof data.arrayBuffer === 'function' && typeof data.size === 'number' && !ArrayBuffer.isView(data)) {
        this.ws.send(data);
        this.reading = this.reading.then(() => data.arrayBuffer())
          .then((buffer) => this.outgoing(new Uint8Array(buffer)), () => { /* not read: those frames come through the relay */ });
        return;
      }
      const bytes = toBytes(data, this.encoder);
      this.ws.send(bytes);
      this.outgoing(bytes);
    }

    outgoing(bytes) {
      const elements = this.out.push(this.fromGame.decode(bytes, { stream: true }));
      if (!elements) { this.out = new Elements(); return; }
      const fight = this.merger.fight;
      if (!fight || !this.spoken) return;
      const frames = [];
      for (const element of elements) {
        const body = element.trim();
        if (body.startsWith('<f>') && FRAME.test(body)) frames.push(body);
      }
      if (!frames.length) return;
      // The reliable channel: these frames; a datagram: as many of the newest as it holds.
      if (this.recentFight !== fight.n) {
        this.recentFight = fight.n;
        this.recent = [];
      }
      this.recent.push(...frames);
      if (this.recent.length > RECENT) this.recent.splice(0, this.recent.length - RECENT);
      const message = JSON.stringify({ t: 'f', e: fight.n, f: frames });
      const newest = [];
      let size = 24;
      for (let k = this.recent.length - 1; k >= 0; k -= 1) {
        size += this.recent[k].length + 3;
        if (size > DATAGRAM && newest.length >= frames.length) break;
        newest.unshift(this.recent[k]);
      }
      const datagram = JSON.stringify({ t: 'f', e: fight.n, f: newest });
      for (const link of this.links.values()) {
        if (!link.open || !this.fighting.has(link.peer.id)) continue;
        link.sendText(message);
        link.sendFast(datagram);
      }
    }

    close(code, reason) {
      if (this.readyState >= 2) return;
      this.readyState = 2;
      this.closeLinks();
      try { this.ws.close(code === undefined ? 1000 : code, reason === undefined ? '' : reason); } catch (error) { this.ws.close(); }
    }

    toGame(text) {
      if (!text || this.readyState !== 1) return;
      const buffer = this.encoder.encode(text).buffer;
      const data = this.kind === 'arraybuffer' ? buffer : new this.win.Blob([buffer]);
      this.fire(messageEvent(this.win, data));
    }

    fire(event) {
      const handler = this['on' + event.type];
      if (typeof handler === 'function') {
        try { handler.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
      }
      if (typeof this.dispatchEvent === 'function') this.dispatchEvent(event);
    }

    // The relay's own messages (text).
    control(text) {
      let message;
      try { message = JSON.parse(text); } catch (error) { return; }
      if (!message || typeof message !== 'object') return;
      if (message.t === 'hello') {
        this.spoken = true;
        this.id = String(message.id || '');
        this.say({ t: 'ping', at: now() });
      } else if (message.t === 'pong' && Number.isFinite(message.at) && message.at > 0) {
        this.relayTimes.push(Math.max(0, now() - message.at));
        if (this.relayTimes.length > 5) this.relayTimes.shift();
        this.showStatus();
      } else if (message.t === 'peers' && Array.isArray(message.peers)) {
        this.cid = Number(message.cid);
        const before = this.peers;
        this.peers = new Map(message.peers.filter((peer) => peer && peer.id).map((peer) => [String(peer.id), {
          id: String(peer.id), cid: Number(peer.cid), name: String(peer.name || '').slice(0, 40),
          since: before.has(String(peer.id)) ? before.get(String(peer.id)).since : now() }]));
        // (The status says "connecting" for a while, then what came of it.)
        clearTimeout(this.statusTimer);
        this.statusTimer = setTimeout(() => this.showStatus(), CONNECT_MS + 200);
        for (const [id, link] of this.links) if (!this.peers.has(id) || this.peers.get(id).cid !== link.peer.cid) link.close();
        for (const peer of this.peers.values()) {
          if (!this.links.has(peer.id) && this.id < peer.id) this.links.set(peer.id, new Link(this, peer, true));
        }
        this.showStatus();
      } else if (message.t === 'signal') {
        const from = String(message.from || '');
        const peer = this.peers.get(from);
        if (!peer) return;
        let link = this.links.get(from);
        if (!link && this.id > from) this.links.set(from, link = new Link(this, peer, false));
        if (link) link.signal(message.data);
      } else if (message.t === 'fight') {
        const ids = Array.isArray(message.ids) ? message.ids.map(String) : [];
        this.fighting = new Set(ids.filter((id) => id !== this.id));
        this.merger.announce(Number(message.n), this.spoken && ids.includes(this.id));
        // A link that failed before is tried again for each fight.
        for (const id of this.fighting) {
          const peer = this.peers.get(id);
          if (peer && !this.links.has(id) && this.id < id) this.links.set(id, new Link(this, peer, true));
        }
      }
    }

    say(message) {
      if (this.ws.readyState === 1) {
        try { this.ws.send(JSON.stringify(message)); } catch (error) { /* closing */ }
      }
    }

    signal(to, data) { this.say({ t: 'signal', to, data }); }

    linkChanged(link, wasOpen) {
      if (link.closed) {
        if (this.links.get(link.peer.id) === link) this.links.delete(link.peer.id);
        this.failed.add(link.peer.id);
        if (wasOpen) this.say({ t: 'link', with: link.peer.id, open: false });
      } else if (link.open && link.reported) {
        const ms = link.time();
        this.say({ t: 'link', with: link.peer.id, open: true, ms: ms === null ? null : Math.round(ms) });
      }
      this.showStatus();
    }

    fightEnded(counts) {
      const total = counts.direct + counts.relay;
      if (total) {
        this.say({ t: 'frames', direct: counts.direct, relay: counts.relay });
        this.lastFight = { ...counts };
      }
      this.showStatus();
    }

    showStatus() {
      const counts = this.lastFight;
      if (typeof this.options.status !== 'function' || this.readyState > 1) return;
      const parts = [];
      for (const peer of this.peers.values()) {
        const link = this.links.get(peer.id);
        const name = peer.name || 'player';
        if (link && link.open) {
          const ms = link.time();
          parts.push(`${name} ${ms === null ? '' : `${Math.round(ms)} ms`}`.trim());
        } else if ((link && !link.closed) || (!link && !this.failed.has(peer.id) && now() - peer.since < CONNECT_MS)) {
          parts.push(`${name} connecting…`);
        } else {
          parts.push(`${name} through the relay`);
        }
      }
      let text = parts.length ? `direct links: ${parts.join(', ')}` : '';
      if (counts && counts.direct + counts.relay) {
        text += `${text ? '; ' : ''}last fight: ${Math.round(100 * counts.direct / (counts.direct + counts.relay))}% of frames came directly`;
      }
      // For the corner of the game: the round trip the frames take, directly when every other page of the room
      // has an open link (the slowest of them), else through the relay.
      const links = [...this.peers.values()].map((peer) => this.links.get(peer.id)).filter(Boolean);
      const direct = this.peers.size > 0 && links.length === this.peers.size && links.every((link) => link.open);
      const times = direct ? links.map((link) => link.time()).filter((ms) => ms !== null) : [];
      const relayMs = middle(this.relayTimes);
      const figures = { way: direct ? 'direct' : 'relay', ping: direct ? (times.length ? Math.max(...times) : null) : relayMs, relay: relayMs };
      try { this.options.status(text, figures); } catch (error) { /* only shown */ }
    }

    closeLinks() {
      clearTimeout(this.statusTimer);
      clearInterval(this.pinger);
      for (const link of [...this.links.values()]) link.close();
      this.links.clear();
    }
  }

  // The bytes Ruffle sends, copied: they are a view of its memory, which may be shared between threads (a
  // SharedArrayBuffer, which neither a WebSocket nor a TextDecoder takes) and is reused at once.
  function toBytes(data, encoder) {
    if (typeof data === 'string') return encoder.encode(data);
    let view;
    if (ArrayBuffer.isView(data)) view = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    else if (data && typeof data.byteLength === 'number') view = new Uint8Array(data);
    else return new Uint8Array(0);
    const copy = new Uint8Array(view.length);
    copy.set(view);
    return copy;
  }

  function messageEvent(win, data) {
    if (typeof win.MessageEvent === 'function') return new win.MessageEvent('message', { data });
    return Object.assign(new win.Event('message'), { data });
  }

  function closeEvent(win, event) {
    const init = { code: event.code, reason: event.reason || '', wasClean: Boolean(event.wasClean) };
    if (typeof win.CloseEvent === 'function') return new win.CloseEvent('close', init);
    return Object.assign(new win.Event('close'), init);
  }

  function middle(values) {
    if (!values.length) return null;
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)];
  }

  function plain(value) {
    return value && typeof value.toJSON === 'function' ? value.toJSON() : JSON.parse(JSON.stringify(value));
  }

  function supported(win) {
    return Boolean(win && typeof win.RTCPeerConnection === 'function' && typeof win.WebSocket === 'function'
      && typeof win.EventTarget === 'function' && typeof win.TextDecoder === 'function' && typeof win.TextEncoder === 'function');
  }

  // From now on, a WebSocket to a Hero Fighter room with direct=1 in its address is a DirectSocket.
  function install(win, options = {}) {
    if (!supported(win)) return false;
    if (win.WebSocket.hfDirect) return true;
    const NativeWebSocket = win.WebSocket;
    const settings = Object.assign({}, options, { NativeWebSocket });
    function WebSocket(url, protocols) {
      const address = String(url);
      if (/[?&]game=hf(&|$)/.test(address) && /[?&]direct=1(&|$)/.test(address)) {
        const socket = new DirectSocket(address, win, settings);
        api.sockets.add(socket); // (for a look from the browser's console: HfDirect.sockets)
        socket.addEventListener('close', () => api.sockets.delete(socket));
        return socket;
      }
      return protocols === undefined ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
    }
    WebSocket.prototype = NativeWebSocket.prototype;
    for (const name of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) WebSocket[name] = NativeWebSocket[name];
    WebSocket.hfDirect = true;
    win.WebSocket = WebSocket;
    return true;
  }

  const api = { supported, install, fixCommandNumber, elementEnd, Elements, Merger, DirectSocket, sockets: new Set() };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.HfDirect = api;
})(typeof window !== 'undefined' ? window : globalThis);
