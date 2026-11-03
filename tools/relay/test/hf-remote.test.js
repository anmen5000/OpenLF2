// SPDX-License-Identifier: MIT
//
// Hero Fighter's remote play (dist/pages/hf-remote.js): the keys a guest's actions become on the host are the
// game's own default keys (Global.defaultKeys of HFv0.7+), every guest key means one action, and the guest's
// answer gets the video bitrates Chrome starts the picture with.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const remote = require(path.join(__dirname, '../../../dist/pages/hf-remote.js'));

// Global.defaultKeys in Hero Fighter v0.7+ (Data/Global.as): up, down, left, right, attack, jump, guard, command.
const DEFAULT_KEYS = [[104, 98, 100, 102, 101, 96, 107, 109], [87, 88, 65, 68, 83, 32, 70, 82], [73, 188, 74, 76, 75, 190, 186, 80]];

test('each player\'s keys on the host are the game\'s default keys, in its order of actions', () => {
  assert.deepEqual(remote.ACTIONS, ['up', 'down', 'left', 'right', 'attack', 'jump', 'guard', 'command']);
  for (const slot of [1, 2, 3]) {
    assert.deepEqual(remote.SLOT_KEYS[slot].map(([, , keyCode]) => keyCode), DEFAULT_KEYS[slot - 1]);
    for (const [code, key, keyCode] of remote.SLOT_KEYS[slot]) {
      assert.ok(/^(Numpad|Key|Space|Comma|Period|Semicolon)/.test(code), code);
      assert.equal(key.length, 1, code);
      assert.ok(keyCode > 0);
    }
  }
});

test('on the guest, any player\'s keys and the arrows are actions, each one only', () => {
  assert.equal(remote.GUEST_KEYS.size, 3 * 8 + 4);
  for (const slot of [1, 2, 3]) {
    remote.SLOT_KEYS[slot].forEach(([code], k) => assert.equal(remote.GUEST_KEYS.get(code), remote.ACTIONS[k], code));
  }
  assert.equal(remote.GUEST_KEYS.get('ArrowLeft'), 'left');
  assert.equal(remote.GUEST_KEYS.get('ArrowUp'), 'up');
  assert.equal(remote.GUEST_KEYS.get('KeyQ'), undefined);
});

test('the guest\'s answer gets the start, floor and top bitrates on its video codecs only, once', () => {
  const answer = ['v=0', 'm=audio 9 UDP/TLS/RTP/SAVPF 111', 'a=rtpmap:111 opus/48000/2', 'a=fmtp:111 minptime=10;useinbandfec=1',
    'm=video 9 UDP/TLS/RTP/SAVPF 102 96 97', 'a=rtpmap:102 H264/90000',
    'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f', 'a=rtpmap:96 VP8/90000',
    'a=rtpmap:97 rtx/90000', 'a=fmtp:97 apt=96', ''].join('\r\n');
  const extra = 'x-google-start-bitrate=2000;x-google-min-bitrate=600;x-google-max-bitrate=3000';
  const lines = remote.withBitrates(answer).split('\r\n');
  assert.ok(lines.includes('a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f;' + extra));
  assert.equal(lines[lines.indexOf('a=rtpmap:96 VP8/90000') + 1], 'a=fmtp:96 ' + extra);
  assert.ok(lines.includes('a=fmtp:111 minptime=10;useinbandfec=1'), 'the sound is left as it is');
  assert.ok(lines.includes('a=fmtp:97 apt=96'), 'retransmissions are left as they are');
  assert.equal(remote.withBitrates(remote.withBitrates(answer)), remote.withBitrates(answer));
  assert.ok(remote.withBitrates(answer).endsWith('\r\n'));
});
