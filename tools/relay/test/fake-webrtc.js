// SPDX-License-Identifier: MIT
//
// An in-memory stand-in for the browser's RTCPeerConnection, for dist/web/online.js's direct
// connections in Node: two pages that set each other up through the relay (offer, answer, a route
// each) get a data channel between them whose messages take `delay` ms each way, as on a LAN.
// `blocked`: no route ever works (a proxy, a network that allows no direct connection).
'use strict';

const crypto = require('node:crypto');

function fakeWebRtc({ delay = 0, blocked = false } = {}) {
  const peers = new Map(); // description token -> peer

  class FakeChannel {
    constructor() {
      this.readyState = 'connecting';
      this.binaryType = 'blob';
      this.bufferedAmount = 0;
      this.onopen = this.onmessage = this.onclose = null;
      this.other = null;
    }

    send(data) {
      if (this.readyState !== 'open') throw new Error('InvalidStateError: the channel is not open');
      const copy = typeof data === 'string' ? data : toArrayBuffer(data);
      const other = this.other;
      setTimeout(() => { if (other.readyState === 'open' && other.onmessage) other.onmessage({ data: copy }); }, delay);
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
      this.channel = null;
      this.onicecandidate = this.ondatachannel = this.onconnectionstatechange = null;
      peers.set(this.token, this);
    }

    createDataChannel() {
      this.channel = new FakeChannel();
      return this.channel;
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
      // The offerer has the answer: the channel opens on both sides.
      const answerer = peers.get(String(description.sdp).replace(/^fake /, ''));
      if (!answerer || !this.channel) return;
      const theirs = new FakeChannel();
      this.channel.other = theirs;
      theirs.other = this.channel;
      answerer.channel = theirs;
      setTimeout(() => {
        if (this.connectionState === 'closed' || answerer.connectionState === 'closed') return;
        this.connectionState = answerer.connectionState = 'connected';
        if (answerer.ondatachannel) answerer.ondatachannel({ channel: theirs });
        theirs.opened();
        this.channel.opened();
      }, delay);
    }

    async addIceCandidate() {}

    close() {
      this.connectionState = 'closed';
      peers.delete(this.token);
      if (this.channel) this.channel.close();
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
