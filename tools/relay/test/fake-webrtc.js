// SPDX-License-Identifier: MIT
//
// An in-memory stand-in for the browser's RTCPeerConnection, for the pages' direct connections in Node
// (dist/web/online.js, dist/pages/hf-direct.js): two pages that set each other up through the relay (offer,
// answer, a route each) get data channels between them whose messages take `delay` ms each way, as on a
// LAN. Channels made once the connection is up reach the other page at once (ondatachannel), as in a
// browser. `blocked`: no route ever works (a proxy, a network that allows no direct connection).
// `loss`: the chance that a network packet is lost (as on Wi-Fi): a datagram channel's message (ordered:
// false, maxRetransmits: 0) is then gone, a reliable channel's comes `stall` ms late and holds up the ones
// after it, as SCTP's sending again does. `seed`: for the same losses each run.
'use strict';

const crypto = require('node:crypto');

function fakeWebRtc({ delay = 0, blocked = false, loss = 0, stall = 300, seed = 1 } = {}) {
  const peers = new Map(); // description token -> peer
  let state = seed >>> 0 || 1;
  const random = () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };

  class FakeChannel {
    constructor(label = '', { ordered = true, maxRetransmits = null } = {}) {
      this.label = label;
      this.ordered = ordered;
      this.maxRetransmits = maxRetransmits;
      this.readyState = 'connecting';
      this.binaryType = 'blob';
      this.bufferedAmount = 0;
      this.onopen = this.onmessage = this.onclose = null;
      this.other = null;
      this.due = 0; // reliable: when the last message sent arrives (none overtakes another)
      this.queue = []; // reliable: messages on the way, in order
    }

    get datagram() { return this.ordered === false && this.maxRetransmits === 0; }

    send(data) {
      if (this.readyState !== 'open') throw new Error('InvalidStateError: the channel is not open');
      const copy = typeof data === 'string' ? data : toArrayBuffer(data);
      const other = this.other;
      const lost = loss > 0 && random() < loss;
      if (this.datagram) {
        if (lost) return;
        setTimeout(() => { if (other.readyState === 'open' && other.onmessage) other.onmessage({ data: copy }); }, delay);
        return;
      }
      // In order: a message never comes before one sent earlier.
      this.due = Math.max(this.due, Date.now() + delay + (lost ? stall : 0));
      this.queue.push({ data: copy, due: this.due });
      if (this.queue.length === 1) this.flush();
    }

    flush() {
      const other = this.other;
      while (this.queue.length && this.queue[0].due <= Date.now()) {
        const { data } = this.queue.shift();
        if (other.readyState === 'open' && other.onmessage) other.onmessage({ data });
      }
      if (this.queue.length) setTimeout(() => this.flush(), Math.max(0, this.queue[0].due - Date.now()));
    }

    close() {
      if (this.readyState === 'closed') return;
      this.readyState = 'closed';
      const other = this.other;
      setTimeout(() => {
        if (this.onclose) this.onclose({});
        if (other && other.readyState !== 'closed') {
          other.readyState = 'closed';
          if (other.onclose) other.onclose({});
        }
      }, delay);
    }

    opened() {
      if (this.readyState !== 'connecting') return;
      this.readyState = 'open';
      if (this.onopen) this.onopen({});
    }
  }

  class FakePeerConnection {
    constructor() {
      this.token = crypto.randomUUID();
      this.connectionState = 'new';
      this.localDescription = null;
      this.remoteDescription = null;
      this.channels = []; // this page's ends: made here or come from the other page
      this.remote = null; // the other page's connection, once up
      this.onicecandidate = this.ondatachannel = this.onconnectionstatechange = null;
      peers.set(this.token, this);
    }

    createDataChannel(label, options) {
      const channel = new FakeChannel(label, options);
      this.channels.push(channel);
      if (this.remote) this.pair(channel);
      return channel;
    }

    // A channel of this page's and its other end on the other page's.
    pair(channel) {
      const remote = this.remote;
      const theirs = new FakeChannel(channel.label, { ordered: channel.ordered, maxRetransmits: channel.maxRetransmits });
      channel.other = theirs;
      theirs.other = channel;
      remote.channels.push(theirs);
      setTimeout(() => {
        if (this.connectionState === 'closed' || remote.connectionState === 'closed') return;
        if (remote.ondatachannel) remote.ondatachannel({ channel: theirs });
        theirs.opened();
        channel.opened();
      }, delay);
    }

    async createOffer() { return { type: 'offer', sdp: `fake ${this.token}` }; }
    async createAnswer() { return { type: 'answer', sdp: `fake ${this.token}` }; }

    async setLocalDescription(description) {
      this.localDescription = description;
      // One route, as a browser finds them while the set-up goes on.
      setTimeout(() => {
        if (this.onicecandidate) this.onicecandidate({ candidate: { candidate: `candidate:fake ${this.token}`, sdpMid: '0', sdpMLineIndex: 0 } });
      }, 0);
    }

    async setRemoteDescription(description) {
      this.remoteDescription = description;
      if (description.type !== 'answer' || blocked) return;
      // The offerer has the answer: the connection is up, its channels open on both sides.
      const answerer = peers.get(String(description.sdp).replace(/^fake /, ''));
      if (!answerer) return;
      this.remote = answerer;
      answerer.remote = this;
      setTimeout(() => {
        if (this.connectionState === 'closed' || answerer.connectionState === 'closed') return;
        this.connectionState = answerer.connectionState = 'connected';
      }, delay);
      for (const channel of [...this.channels]) if (!channel.other) this.pair(channel);
    }

    async addIceCandidate() {}

    close() {
      this.connectionState = 'closed';
      peers.delete(this.token);
      for (const channel of this.channels) channel.close();
    }
  }

  return FakePeerConnection;
}

function toArrayBuffer(data) {
  if (data instanceof ArrayBuffer) return data.slice(0);
  const view = ArrayBuffer.isView(data) ? data : new Uint8Array(data);
  return view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength);
}

module.exports = { fakeWebRtc };
