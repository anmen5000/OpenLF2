// SPDX-License-Identifier: MIT
//
// Remote play for Hero Fighter ("chơi nhờ"): a computer too slow for a crowded fight plays through a faster one.
// The faster computer (the host) runs the game as always and sends its picture and sound to the other (the guest)
// over WebRTC; the guest's keys come back and play one of the host's own players (player 1, 2 or 3, on that
// player's default keys), and its clicks and taps on the picture click in the host's game. Network rooms see one
// computer, the host, so they play at the host's pace; the guest sees and hears it a little later (the network's
// time and the video's: about 0.1 s at home, more over the Internet).
//
// The two pages find each other through the relay's two-player rooms (protocol 1 of tools/relay/server.js, a code
// of digits): the host waits in a room with a random 6-digit code, the guest joins it with the code typed, and the
// relay passes their WebRTC set-up messages (JSON, as binary frames: the relay forwards only those). The picture,
// the sound and the keys then go directly between the two browsers (STUN only: no relay carries a video).
//
//   HfRemote.tapAudio()        before Ruffle starts: lets the host send the game's sound too
//   HfRemote.host(options)     options: player (Ruffle's element), relay (ws(s)://… of the relay), slot (1-3),
//                              onState(state), log(text); returns { stop(), setSlot(n), code }
//   HfRemote.guest(options)    options: stage (element), relay, code, onState(state), log(text); returns { stop(), video }
//   state: { phase: 'waiting' | 'connecting' | 'playing' | 'ended' | 'error', code, ping?, fps?, reason?, note?, muted? }
'use strict';

(typeof window !== 'undefined' ? window : globalThis).HfRemote = (() => {
  const ICE_SERVERS = [{ urls: 'stun:stun.l.google.com:19302' }, { urls: 'stun:stun.cloudflare.com:3478' }];
  const ACTIONS = ['up', 'down', 'left', 'right', 'attack', 'jump', 'guard', 'command'];
  // The game's default keys (Global.defaultKeys), in ACTIONS' order: player 1 the number pad, player 2
  // W X A D S Space F R, player 3 I , J L K . ; P. [code, key, keyCode]
  const SLOT_KEYS = {
    1: [['Numpad8', '8', 104], ['Numpad2', '2', 98], ['Numpad4', '4', 100], ['Numpad6', '6', 102], ['Numpad5', '5', 101],
      ['Numpad0', '0', 96], ['NumpadAdd', '+', 107], ['NumpadSubtract', '-', 109]],
    2: [['KeyW', 'w', 87], ['KeyX', 'x', 88], ['KeyA', 'a', 65], ['KeyD', 'd', 68], ['KeyS', 's', 83], ['Space', ' ', 32],
      ['KeyF', 'f', 70], ['KeyR', 'r', 82]],
    3: [['KeyI', 'i', 73], ['Comma', ',', 188], ['KeyJ', 'j', 74], ['KeyL', 'l', 76], ['KeyK', 'k', 75], ['Period', '.', 190],
      ['Semicolon', ';', 186], ['KeyP', 'p', 80]],
  };
  // On the guest, the keys that are actions: any player's default keys (they do not overlap) and the arrows.
  const GUEST_KEYS = new Map([['ArrowUp', 'up'], ['ArrowDown', 'down'], ['ArrowLeft', 'left'], ['ArrowRight', 'right']]);
  for (const slot of [1, 2, 3]) SLOT_KEYS[slot].forEach(([code], k) => GUEST_KEYS.set(code, ACTIONS[k]));

  const roomUrl = (relay, role, code) => relay + (relay.includes('?') ? '&' : '?') + 'role=' + role + '&room=' + code;
  const randomCode = () => {
    const bytes = new Uint32Array(1);
    crypto.getRandomValues(bytes);
    return String(100000 + bytes[0] % 900000);
  };
  // The relay's two-player rooms forward binary frames only; its own messages ({t: 'waiting'}, {t: 'paired'}) are text.
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const sendJson = (ws, message) => { if (ws && ws.readyState === 1) ws.send(encoder.encode(JSON.stringify(message))); };
  const readJson = (data) => {
    try { return JSON.parse(typeof data === 'string' ? data : decoder.decode(data)); } catch (error) { return null; }
  };
  // Typing on the page (an address, a code): its keys are not the game's.
  const typingIn = (element) => Boolean(element && (element.isContentEditable || element.tagName === 'TEXTAREA'
    || (element.tagName === 'INPUT' && /^(text|search|email|url|tel|password|number)$/i.test(element.type))));

  // ---- The sound: Ruffle plays through Web Audio; every node it connects to the speakers is also connected to a
  // stream, which the host sends. (Installed before Ruffle makes its AudioContext; nothing changes for what is heard.)
  let tapped = false;
  const taps = new Set();
  function tapAudio() {
    if (tapped || typeof AudioNode !== 'function' || typeof AudioDestinationNode !== 'function') return;
    tapped = true;
    const connect = AudioNode.prototype.connect;
    AudioNode.prototype.connect = function (target, ...rest) {
      const result = connect.call(this, target, ...rest);
      try {
        if (target instanceof AudioDestinationNode && typeof target.context.createMediaStreamDestination === 'function') {
          const context = target.context;
          if (!context.hfRemoteTap) {
            context.hfRemoteTap = context.createMediaStreamDestination();
            taps.add(context);
          }
          connect.call(this, context.hfRemoteTap, ...rest);
        }
      } catch (error) { /* the sound only */ }
      return result;
    };
  }
  function audioTrack() {
    for (const context of taps) {
      const track = context.hfRemoteTap.stream.getAudioTracks()[0];
      if (track && track.readyState === 'live') return track;
    }
    return null;
  }

  // H.264 first when the browser has it (graphics cards encode it, which leaves the processor to the game), else
  // the browser's order.
  function preferH264(transceiver) {
    try {
      if (!transceiver || typeof transceiver.setCodecPreferences !== 'function' || !window.RTCRtpSender || !RTCRtpSender.getCapabilities) return;
      const codecs = (RTCRtpSender.getCapabilities('video') || {}).codecs || [];
      const h264 = codecs.filter((codec) => /h264/i.test(codec.mimeType));
      if (h264.length) transceiver.setCodecPreferences([...h264, ...codecs.filter((codec) => !/h264/i.test(codec.mimeType))]);
    } catch (error) { /* the browser's order */ }
  }

  // Chrome starts a call's video at the bitrate of a slow network and raises it only as more is sent, which a game's
  // still menus (and a slow game's few frames) never do: the picture would stay small and blurred (320x180) for a
  // long while. A start and a floor suited to a home network or a good connection, as the video codecs' parameters
  // in the guest's answer (Chrome's own; other browsers ignore them).
  function withBitrates(sdp) {
    const lines = String(sdp).split('\r\n');
    const payloads = new Set();
    let video = false;
    for (const line of lines) {
      if (line.startsWith('m=')) video = line.startsWith('m=video');
      const map = video && /^a=rtpmap:(\d+) (H264|VP8|VP9|AV1)\//i.exec(line);
      if (map) payloads.add(map[1]);
    }
    const extra = 'x-google-start-bitrate=2000;x-google-min-bitrate=600;x-google-max-bitrate=3000';
    const withFmtp = new Set();
    const out = lines.map((line) => {
      const fmtp = /^a=fmtp:(\d+) /.exec(line);
      if (!fmtp || !payloads.has(fmtp[1])) return line;
      withFmtp.add(fmtp[1]);
      return line.includes('x-google-') ? line : line + ';' + extra;
    });
    for (let k = out.length - 1; k >= 0; k--) {
      const map = /^a=rtpmap:(\d+) /.exec(out[k]);
      if (map && payloads.has(map[1]) && !withFmtp.has(map[1])) out.splice(k + 1, 0, 'a=fmtp:' + map[1] + ' ' + extra);
    }
    return out.join('\r\n');
  }

  // ---- The host --------------------------------------------------------------------------------------
  function host({ player, relay, slot = 3, onState = () => {}, log = () => {} }) {
    let code = randomCode();
    let ws = null;
    let pc = null;
    let channel = null;
    let stopped = false;
    let retryTimer = null;
    let playing = false;
    let relayDown = false; // the last connection to the relay never opened
    let failed = false; // the last guest could not connect directly
    const held = new Set();
    let mouseDown = false;
    const say = (state) => {
      const note = relayDown ? 'the relay does not answer (trying again)'
        : failed ? 'the last try could not connect the two computers directly (a network that blocks it)' : '';
      if (!stopped || state.phase === 'ended') onState({ code, slot, note, ...state });
    };
    const canvasOf = () => player && player.shadowRoot && player.shadowRoot.querySelector('canvas');
    // Ruffle takes keys only while its player has the focus (a focusin it saw last): the game gets it back unless
    // someone types elsewhere on this page, and in a window behind another one (no focus at all) Ruffle is told so.
    function focusGame() {
      const active = document.activeElement;
      if (active !== player && typingIn(active)) return;
      if (active !== player) player.focus({ preventScroll: true });
      if (!document.hasFocus()) player.dispatchEvent(new FocusEvent('focusin'));
    }
    const keyEvent = (action, down) => {
      const [keyCode, key, which] = SLOT_KEYS[slot][ACTIONS.indexOf(action)];
      if (down) focusGame();
      window.dispatchEvent(new KeyboardEvent(down ? 'keydown' : 'keyup',
        { code: keyCode, key, keyCode: which, which, location: keyCode.startsWith('Numpad') ? 3 : 0, bubbles: true }));
    };
    const releaseAll = () => {
      for (const action of [...held]) { held.delete(action); keyEvent(action, false); }
      if (mouseDown) pointer('u', NaN, NaN);
    };
    // A click or a tap on the guest's picture, at x and y from 0 to 1 across it: the same place on Ruffle's canvas,
    // whose pictures the guest sees.
    let lastX = 0.5;
    let lastY = 0.5;
    function pointer(kind, x, y) {
      const canvas = canvasOf();
      if (!canvas) return;
      if (Number.isFinite(x) && Number.isFinite(y)) { lastX = Math.min(1, Math.max(0, x)); lastY = Math.min(1, Math.max(0, y)); }
      const box = canvas.getBoundingClientRect();
      const init = { clientX: box.left + lastX * box.width, clientY: box.top + lastY * box.height, pointerId: 41, pointerType: 'mouse',
        isPrimary: true, bubbles: true, composed: true, cancelable: true };
      if (kind === 'd') {
        focusGame();
        mouseDown = true;
        canvas.dispatchEvent(new PointerEvent('pointerenter', { ...init, bubbles: false, button: -1, buttons: 0 }));
        canvas.dispatchEvent(new PointerEvent('pointermove', { ...init, button: -1, buttons: 0 }));
        canvas.dispatchEvent(new PointerEvent('pointerdown', { ...init, button: 0, buttons: 1 }));
      } else if (kind === 'm') {
        canvas.dispatchEvent(new PointerEvent('pointermove', { ...init, button: -1, buttons: mouseDown ? 1 : 0 }));
      } else if (kind === 'u' && mouseDown) {
        mouseDown = false;
        canvas.dispatchEvent(new PointerEvent('pointerup', { ...init, button: 0, buttons: 0 }));
      }
    }
    let fitTimer = null;
    function endCall() {
      releaseAll();
      clearInterval(fitTimer);
      fitTimer = null;
      if (channel) { channel.onmessage = channel.onclose = null; try { channel.close(); } catch (error) { /* closed */ } }
      if (pc) { pc.onicecandidate = pc.onconnectionstatechange = null; try { pc.close(); } catch (error) { /* closed */ } }
      channel = pc = null;
      playing = false;
    }
    function onMessage(text) {
      const [kind, value, x, y] = String(text).split(' ');
      if (kind === 'p') { if (channel && channel.readyState === 'open') channel.send('q ' + value); return; }
      if (kind === 'm') { pointer(value, Number(x), Number(y)); return; }
      if ((kind !== 'd' && kind !== 'u') || !ACTIONS.includes(value)) return;
      const down = kind === 'd';
      if (down === held.has(value)) return;
      if (down) held.add(value); else held.delete(value);
      keyEvent(value, down);
    }
    async function call() {
      endCall();
      const canvas = canvasOf();
      if (!canvas || typeof canvas.captureStream !== 'function') {
        say({ phase: 'error', reason: 'this browser cannot send the game\'s picture' });
        return;
      }
      pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
      const stream = canvas.captureStream(30);
      for (const track of stream.getVideoTracks()) {
        track.contentHint = 'motion';
        preferH264(pc.addTransceiver(track, { direction: 'sendonly', streams: [stream] }));
      }
      const sound = audioTrack();
      if (sound) pc.addTransceiver(sound, { direction: 'sendonly', streams: [stream] });
      channel = pc.createDataChannel('keys', { ordered: true });
      channel.onmessage = (event) => onMessage(event.data);
      // The guest stopped or its page closed: its keys up, and this computer waits for the next one.
      channel.onclose = () => {
        endCall();
        if (!stopped) say({ phase: 'waiting' });
      };
      pc.onicecandidate = (event) => { if (event.candidate) sendJson(ws, { t: 'ice', candidate: event.candidate }); };
      pc.onconnectionstatechange = () => {
        if (!pc) return;
        if (pc.connectionState === 'connected') {
          playing = true;
          failed = false;
          say({ phase: 'playing' });
        } else if (pc.connectionState === 'disconnected') {
          releaseAll(); // no keys held down while the guest cannot let them go
        } else if (pc.connectionState === 'failed') {
          log('Hero Fighter remote play: the direct connection failed');
          failed = true;
          endCall();
          say({ phase: 'waiting' });
        }
      };
      // Frames over resolution (a fight needs its 30 frames a second), at most about 960 pixels wide whatever the
      // canvas's size (fullscreen, large view): a smaller picture costs this computer less to encode.
      const sender = pc.getSenders().find((item) => item.track && item.track.kind === 'video');
      let applied = 0;
      const fit = async () => {
        if (!sender || !pc || canvas.width === applied) return;
        applied = canvas.width;
        try {
          const parameters = sender.getParameters();
          parameters.degradationPreference = 'maintain-framerate';
          parameters.encodings = parameters.encodings && parameters.encodings.length ? parameters.encodings : [{}];
          Object.assign(parameters.encodings[0], { maxBitrate: 3000000, maxFramerate: 30,
            scaleResolutionDownBy: Math.max(1, canvas.width / 960) });
          await sender.setParameters(parameters);
        } catch (error) { /* the browser's defaults */ }
      };
      await fit();
      clearInterval(fitTimer);
      fitTimer = setInterval(fit, 2000);
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      sendJson(ws, { t: 'offer', sdp: pc.localDescription });
      say({ phase: 'connecting' });
    }
    function wait() {
      if (stopped) return;
      const socket = new WebSocket(roomUrl(relay, 'host', code));
      ws = socket;
      socket.binaryType = 'arraybuffer';
      let opened = false;
      socket.onopen = () => { opened = true; relayDown = false; };
      socket.onmessage = async (event) => {
        const message = readJson(event.data);
        if (!message || ws !== socket) return;
        try {
          if (message.t === 'waiting') { if (!playing) say({ phase: 'waiting' }); }
          else if (message.t === 'paired') await call();
          else if (message.t === 'answer' && pc && message.sdp) {
            await pc.setRemoteDescription({ type: 'answer', sdp: withBitrates(message.sdp.sdp) });
          }
          else if (message.t === 'ice' && pc && message.candidate) await pc.addIceCandidate(message.candidate);
        } catch (error) {
          log('Hero Fighter remote play: ' + error.message);
        }
      };
      socket.onclose = (event) => {
        if (ws !== socket) return;
        ws = null;
        if (stopped) return;
        // The relay's close codes (CLOSE in tools/relay/server.js): 4005, nobody came within its two minutes, and
        // 4006, the guest's page left: the same code again at once. 4004 and 4017, the code is someone else's
        // room: another code. 4001-4003: the relay refuses (another site, too many connections, full). A call
        // already connected goes on without the relay.
        if (event.code === 4004 || event.code === 4017) code = randomCode();
        if (event.code === 4001 || event.code === 4002 || event.code === 4003) {
          say({ phase: 'error', reason: event.reason || 'the relay refused remote play' });
          return;
        }
        if (event.code === 4006 && !(pc && pc.connectionState === 'connected')) endCall();
        relayDown = !opened;
        if (!playing) say({ phase: 'waiting' });
        const again = event.code === 4005 || event.code === 4006 || event.code === 4004 || event.code === 4017;
        retryTimer = setTimeout(wait, again ? 100 : 3000);
      };
    }
    wait();
    return {
      get code() { return code; },
      setSlot(next) {
        next = Number(next);
        if (!SLOT_KEYS[next] || next === slot) return;
        releaseAll();
        slot = next;
      },
      stop() {
        if (stopped) return;
        stopped = true;
        clearTimeout(retryTimer);
        endCall();
        if (ws) { ws.onclose = null; ws.close(1000); ws = null; }
        say({ phase: 'ended' });
      },
    };
  }

  // ---- The guest -------------------------------------------------------------------------------------
  function guest({ stage, relay, code, onState = () => {}, log = () => {} }) {
    let ws = null;
    let pc = null;
    let channel = null;
    let stopped = false;
    let finished = false;
    let pingTimer = null;
    let ping = null;
    let fps = null;
    let muted = false;
    const held = new Set();
    const pending = [];
    const say = (state) => { if (!stopped || state.phase === 'ended') onState({ code, ping, fps, muted, ...state }); };
    const video = document.createElement('video');
    video.className = 'hf-remote-video';
    video.autoplay = true;
    video.playsInline = true;
    video.tabIndex = 0;
    stage.appendChild(video);
    const send = (text) => { if (channel && channel.readyState === 'open') channel.send(text); };
    const onKey = (event) => {
      const action = GUEST_KEYS.get(event.code);
      if (!action || event.ctrlKey || event.altKey || event.metaKey || typingIn(event.target)) return;
      event.preventDefault();
      event.stopPropagation();
      const down = event.type === 'keydown';
      if (down === held.has(action)) return;
      if (down) held.add(action); else held.delete(action);
      send((down ? 'd ' : 'u ') + action);
    };
    // Clicks and taps on the picture: where in the game's picture (the video keeps its shape inside the element).
    let pointerId = null;
    let lastMove = 0;
    const place = (event) => {
      const box = video.getBoundingClientRect();
      const width = video.videoWidth || 960;
      const height = video.videoHeight || 540;
      const scale = Math.min(box.width / width, box.height / height);
      if (!(scale > 0)) return null;
      const x = (event.clientX - (box.left + (box.width - width * scale) / 2)) / (width * scale);
      const y = (event.clientY - (box.top + (box.height - height * scale) / 2)) / (height * scale);
      return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? x.toFixed(4) + ' ' + y.toFixed(4) : null;
    };
    video.addEventListener('pointerdown', (event) => {
      if (muted) { // the sound, which the browser held back until a click
        video.muted = muted = false;
        video.play().catch(() => {});
        say({ phase: 'playing' });
      }
      if (event.button !== 0 || pointerId !== null) return;
      const at = place(event);
      if (!at) return;
      event.preventDefault();
      video.focus({ preventScroll: true });
      pointerId = event.pointerId;
      try { video.setPointerCapture(event.pointerId); } catch (error) { /* no capture */ }
      send('m d ' + at);
    });
    video.addEventListener('pointermove', (event) => {
      if (event.pointerId !== pointerId || performance.now() - lastMove < 16) return;
      const at = place(event);
      if (!at) return;
      lastMove = performance.now();
      send('m m ' + at);
    });
    for (const type of ['pointerup', 'pointercancel']) {
      video.addEventListener(type, (event) => {
        if (event.pointerId !== pointerId) return;
        pointerId = null;
        send('m u ' + (place(event) || 'x x'));
      });
    }
    video.addEventListener('contextmenu', (event) => event.preventDefault());
    const releaseAll = () => {
      for (const action of [...held]) { held.delete(action); send('u ' + action); }
      if (pointerId !== null) { pointerId = null; send('m u x x'); }
    };
    window.addEventListener('keydown', onKey, true);
    window.addEventListener('keyup', onKey, true);
    window.addEventListener('blur', releaseAll);
    // The end of the call; reason: what to say (once), '' for nothing.
    function close(reason) {
      clearInterval(pingTimer);
      clearTimeout(late);
      pingTimer = null;
      releaseAll();
      if (channel) { channel.onmessage = channel.onclose = null; try { channel.close(); } catch (error) { /* closed */ } }
      if (pc) { pc.ontrack = pc.onicecandidate = pc.onconnectionstatechange = pc.ondatachannel = null; try { pc.close(); } catch (error) { /* closed */ } }
      channel = pc = null;
      if (ws) { ws.onclose = null; ws.close(1000); ws = null; }
      if (reason && !finished) {
        finished = true;
        say({ phase: 'error', reason });
      }
    }
    async function answer(offer) {
      pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
      pc.ontrack = (event) => {
        // As soon as frames come: no waiting to smooth the network out, a fight wants its picture now.
        try { event.receiver.jitterBufferTarget = 0; } catch (error) { /* older browsers */ }
        try { if ('playoutDelayHint' in event.receiver) event.receiver.playoutDelayHint = 0; } catch (error) { /* older browsers */ }
        const stream = event.streams[0] || new MediaStream([event.track]);
        if (video.srcObject !== stream) video.srcObject = stream;
        video.play().catch(() => {
          // The browser plays sound only after a click on the page: muted until the picture is clicked.
          video.muted = muted = true;
          video.play().catch(() => {});
          say({ phase: channel && channel.readyState === 'open' ? 'playing' : 'connecting' });
        });
      };
      pc.ondatachannel = (event) => {
        channel = event.channel;
        channel.onmessage = (message) => {
          const [kind, value] = String(message.data).split(' ');
          if (kind === 'q') ping = performance.now() - Number(value);
        };
        channel.onopen = () => {
          clearInterval(pingTimer);
          pingTimer = setInterval(async () => {
            send('p ' + performance.now().toFixed(1));
            try {
              const stats = await pc.getStats();
              stats.forEach((report) => { if (report.type === 'inbound-rtp' && report.kind === 'video' && report.framesPerSecond) fps = report.framesPerSecond; });
            } catch (error) { /* no figures */ }
            say({ phase: 'playing' });
          }, 2000);
          send('p ' + performance.now().toFixed(1));
          say({ phase: 'playing' });
          video.focus({ preventScroll: true });
        };
        // The host stopped remote play or its page closed.
        channel.onclose = () => close('the other computer stopped remote play');
      };
      pc.onicecandidate = (event) => { if (event.candidate) sendJson(ws, { t: 'ice', candidate: event.candidate }); };
      pc.onconnectionstatechange = () => {
        if (!pc) return;
        if (pc.connectionState === 'failed') close('the two computers could not connect directly (a network that blocks it; on the same home network it works)');
        else if (pc.connectionState === 'disconnected') { releaseAll(); say({ phase: 'connecting' }); }
        else if (pc.connectionState === 'connected' && channel && channel.readyState === 'open') say({ phase: 'playing' });
      };
      await pc.setRemoteDescription(offer);
      await pc.setLocalDescription(await pc.createAnswer());
      sendJson(ws, { t: 'answer', sdp: pc.localDescription });
      while (pending.length) await pc.addIceCandidate(pending.shift()).catch(() => {});
    }
    const socket = new WebSocket(roomUrl(relay, 'join', code));
    ws = socket;
    socket.binaryType = 'arraybuffer';
    say({ phase: 'connecting' });
    let alone = null;
    let late = null;
    let reached = false;
    socket.onopen = () => { reached = true; };
    socket.onmessage = async (event) => {
      const message = readJson(event.data);
      if (!message) return;
      try {
        if (message.t === 'waiting') {
          // Nobody hosts this code right now: the relay keeps this page waiting. A host page between two of its waits
          // comes back within a moment; else it is not the right code.
          clearTimeout(alone);
          alone = setTimeout(() => close('no computer offers remote play with code ' + code + ' (check the code on the other computer)'), 6000);
        } else if (message.t === 'paired') {
          clearTimeout(alone);
          // Paired, the host sends its picture within a moment, else its game cannot (the page's message says why).
          late = setTimeout(() => { if (!(channel && channel.readyState === 'open')) close('the other computer did not send its game'); }, 20000);
        } else if (message.t === 'offer') await answer(message.sdp);
        else if (message.t === 'ice' && message.candidate) {
          if (pc && pc.remoteDescription) await pc.addIceCandidate(message.candidate);
          else pending.push(message.candidate);
        }
      } catch (error) {
        log('Hero Fighter remote play: ' + error.message);
      }
    };
    socket.onclose = (event) => {
      if (ws !== socket) return;
      ws = null;
      clearTimeout(alone);
      if (!(channel && channel.readyState === 'open')) clearTimeout(late);
      // The relay's room ends with the host's page (or its refusal); a call already made goes on without it.
      if (stopped || (pc && pc.connectionState === 'connected')) return;
      if (!reached) close('the relay does not answer');
      else if (event.code === 4004) close('another computer already plays through code ' + code);
      else if (event.code >= 4001 && event.code <= 4003) close(event.reason || 'the relay refused remote play');
      else close('the other computer is gone');
    };
    return {
      stop() {
        if (stopped) return;
        close('');
        stopped = true;
        clearTimeout(alone);
        window.removeEventListener('keydown', onKey, true);
        window.removeEventListener('keyup', onKey, true);
        window.removeEventListener('blur', releaseAll);
        video.srcObject = null;
        video.remove();
        say({ phase: 'ended' });
      },
      video,
    };
  }

  const api = { tapAudio, host, guest, withBitrates, SLOT_KEYS, GUEST_KEYS, ACTIONS };
  if (typeof module === 'object' && module.exports) module.exports = api; // tests
  return api;
})();
