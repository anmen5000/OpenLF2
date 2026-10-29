// SPDX-License-Identifier: MIT
//
// Hero Fighter v0.7+ network rooms for the relay: a rewrite of "Room Server v0.7+" (the Java room
// server that Hero Fighter's players run, MangaD's update of the original by Martial Studio) that
// speaks the same protocol, with the same rules and timing, so that the game cannot tell it apart.
// The web page runs the game (a Flash program) in Ruffle, whose sockets reach the relay as
// WebSockets: each WebSocket message carries bytes of what would be the TCP stream.
//
// The protocol: one XML element per line, both ways (UTF-8, "\n" after each). The server greets
// with <ini/>, the game answers <join><ver>700</ver></join>, the server measures the latency with
// ten <ping/>s, sends the random table every game in the room uses (10 x 500 numbers) and asks for
// <info> (computer name, 3 player names, the account's character levels). Then the waiting room:
// chat, the mode buttons with a 3-second countdown everyone sees, the character menu (24 men: 3 per
// computer, then computer players and soldiers), the game settings. In a fight every game sends its
// keys frame by frame (<f>, two frames then <pk/>); the server passes each game the frames of the
// others, in order, as soon as all of them have sent a frame (lockstep).
//
// Names in comments like "Main.al" are the original's (obfuscated) ones, to compare with it.
'use strict';

const VERSION = 700; // Main.f
const MAX_LEVEL = 16; // Main.e: higher levels are a cheat (the game is shut out)
const STEP = 2; // Main.c: frames per packet, the unit of latency
const CLIENTS = 4; // Main.N: computers in a room
const SLOTS = CLIENTS + 2; // Main.P: the room list has two more lines: the room's host and the server
const HOST_SLOT = SLOTS - 2; // Main.R
const SERVER_SLOT = SLOTS - 1; // Main.Q: chat lines from the server
const MEN = CLIENTS * 3 + 12; // Main.aW: 3 players per computer, then computer players and soldiers
const COUNTDOWN = 6; // T.c: half seconds from a click to the page change
const FRAMES_KEPT = 500; // R.r: frames each computer's are kept, by frame number modulo this

const CHARACTERS = ['lucas', 'drew', 'shawn', 'jenny', 'taylor', 'leo', 'legge', 'eason', 'yaga', 'jason', 'gordon',
  'giggs', 'titto', 'sinan', 'iczzy', 'heater', 'raye', 'vivian', 'livermore', 'eason0']; // Main.aH, i.c
const BACKGROUNDS = ['hill_dry', 'forest_mud', 'temple', 'village', 'trees_grass', 'room1', 'rock_dry', 'village2',
  'story01', 'story02a', 'story02c', 'story02b', 'story03a', 'story04b', 'story03b', 'story03b2', 'story04a',
  'story03c', 'story05a', 'story05a_drama', 'story05b_drama', 'story06b2', 'prison_drama', 'prison2', 'story06a',
  'story06c', 'story06d', 'story06d2', 'story07a', 'story07c', 'desert', 'story07b', 'story07d', 'hill_mud',
  'trees_mud', 'hill_grass', 'forest_grass', 'story04c', 'prison', 'story03d', 'story05b', 'story06b', 'trees_dry',
  'hill_dry2', 'floor_dry', 'floor_pillar', 'castle_floor2', 'temple_door', 'temple_end', 'OLD_village2',
  'villageTest', 'desertnight', 'story07b2', 'battle2', 'battle3', 'battle4', 'battle2team', 'battle2old',
  'battle3old']; // Main.ax
const MUSIC = ['01.mp3', '02.mp3', '03.mp3', '04.mp3', '05.mp3', '06.mp3', '07.mp3', '08.mp3', '09.mp3', '10.mp3',
  '11.mp3', '12.mp3', '13.mp3']; // Main.aX

// ---- XML, as much as the game's messages need ----------------------------------------------------
// The original parses each line with a DOM parser and reads values as getElementsByTagName(name)
// .item(k).getChildNodes().item(0).getNodeValue(): the first child node (text or CDATA) of an element.
// Anything it could not parse ended the connection; so does an XmlError here.

class XmlError extends Error {}

const ENTITIES = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };

function decodeEntities(raw) {
  return raw.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);|&/g, (match, entity) => {
    if (!entity) throw new XmlError('bare &');
    if (entity[0] === '#') {
      const code = entity[1] === 'x' ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      if (!(code > 0 && code <= 0x10ffff)) throw new XmlError('bad character reference');
      return String.fromCodePoint(code);
    }
    if (!(entity in ENTITIES)) throw new XmlError(`unknown entity ${entity}`);
    return ENTITIES[entity];
  });
}

const NAME = /[A-Za-z_:][-A-Za-z0-9_:.]*/y;

function parseXml(text) {
  let at = 0;
  const skipMisc = () => {
    for (;;) {
      while (at < text.length && /\s/.test(text[at])) at += 1;
      if (text.startsWith('<?', at)) {
        const end = text.indexOf('?>', at + 2);
        if (end < 0) throw new XmlError('unclosed declaration');
        at = end + 2;
      } else if (text.startsWith('<!--', at)) {
        const end = text.indexOf('-->', at + 4);
        if (end < 0) throw new XmlError('unclosed comment');
        at = end + 3;
      } else return;
    }
  };
  const readName = () => {
    NAME.lastIndex = at;
    const match = NAME.exec(text);
    if (!match) throw new XmlError('name expected');
    at += match[0].length;
    return match[0];
  };
  const element = () => {
    if (text[at] !== '<') throw new XmlError('element expected');
    at += 1;
    const node = { name: readName(), attributes: {}, children: [] };
    for (;;) {
      const before = at;
      while (at < text.length && /\s/.test(text[at])) at += 1;
      if (text.startsWith('/>', at)) { at += 2; return node; }
      if (text[at] === '>') { at += 1; break; }
      if (at === before) throw new XmlError('space expected');
      const name = readName();
      while (/\s/.test(text[at] || '')) at += 1;
      if (text[at] !== '=') throw new XmlError('= expected');
      at += 1;
      while (/\s/.test(text[at] || '')) at += 1;
      const quote = text[at];
      if (quote !== '"' && quote !== "'") throw new XmlError('quote expected');
      const end = text.indexOf(quote, at + 1);
      if (end < 0) throw new XmlError('unclosed attribute');
      node.attributes[name] = decodeEntities(text.slice(at + 1, end));
      at = end + 1;
    }
    let pending = null; // adjacent character data is one text node
    const flush = () => { if (pending !== null) node.children.push({ text: pending }); pending = null; };
    for (;;) {
      if (at >= text.length) throw new XmlError(`unclosed <${node.name}>`);
      if (text.startsWith('</', at)) {
        at += 2;
        if (readName() !== node.name) throw new XmlError(`mismatched </${node.name}>`);
        while (/\s/.test(text[at] || '')) at += 1;
        if (text[at] !== '>') throw new XmlError('> expected');
        at += 1;
        flush();
        return node;
      }
      if (text.startsWith('<![CDATA[', at)) {
        const end = text.indexOf(']]>', at + 9);
        if (end < 0) throw new XmlError('unclosed CDATA');
        flush();
        node.children.push({ text: text.slice(at + 9, end), cdata: true });
        at = end + 3;
      } else if (text.startsWith('<!--', at)) {
        const end = text.indexOf('-->', at + 4);
        if (end < 0) throw new XmlError('unclosed comment');
        flush();
        at = end + 3;
      } else if (text[at] === '<') {
        flush();
        node.children.push(element());
      } else {
        const end = text.indexOf('<', at);
        const raw = text.slice(at, end < 0 ? text.length : end);
        pending = (pending || '') + decodeEntities(raw);
        at += raw.length;
      }
    }
  };
  skipMisc();
  const root = element();
  skipMisc();
  if (at !== text.length) throw new XmlError('content after the root element');
  return root;
}

// getElementsByTagName: the element itself and its descendants, in document order.
function byTag(node, name, found = []) {
  if (node.name === name) found.push(node);
  for (const child of node.children) if (child.name) byTag(child, name, found);
  return found;
}

// The value of an element's first child node (null for an element child, as in the DOM).
function valueOf(node) {
  if (!node) throw new XmlError('element missing');
  const first = node.children[0];
  if (!first) throw new XmlError(`<${node.name}> is empty`);
  return first.name ? null : first.text;
}

// Integer.parseInt.
function int(text) {
  if (typeof text !== 'string' || !/^[-+]?\d+$/.test(text)) throw new XmlError(`not a number: ${text}`);
  const value = Number(text);
  if (value > 2147483647 || value < -2147483648) throw new XmlError('number out of range');
  return value;
}

function tagValue(doc, name, index = 0) {
  return valueOf(byTag(doc, name)[index]);
}

// ---- A room ------------------------------------------------------------------------------------------

function newMan() { // as
  return { client: -1, controller: -1, team: 0, level: 1, char: '', random: true, exists: false, commander: -1 };
}

function newSlot() { // R
  const levels = new Array(30).fill(0);
  levels[0] = levels[1] = levels[2] = 1;
  return {
    name: '', players: ['', '', ''], levels, cc: '', country: '', online: false, hasPlayer: false, paused: false,
    connection: null, page: 'WAITROOM', fighting: false, latency: 0, latencyShown: 0, latencyTarget: 0,
    started: false, lastPacket: -1, leftFrame: -1, frames: new Array(FRAMES_KEPT), lastMessage: 0, lastActive: 0,
    admin: false, flushes: 0,
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class HfRoom {
  constructor({ number, name, description = '', cc = 'VN', limit = CLIENTS, random = Math.random, log = () => {} }) {
    this.number = number;
    this.name = name; // Main.z
    this.description = description; // Main.A
    this.cc = cc; // Main.E
    this.limit = Math.min(CLIENTS, Math.max(2, limit)); // Main.O
    this.password = ''; // Main.C / Main.D (rooms here have none)
    this.latencyLimit = -1; // Main.aJ
    this.afkMinutes = -1; // Main.aL
    this.random = random;
    this.log = log;
    this.slots = Array.from({ length: SLOTS }, newSlot); // Main.ap
    this.slots[HOST_SLOT].name = '<font color="#CCFFFF">Room Host</font>';
    this.men = []; // Main.aq
    this.connected = 0; // Main.M
    this.connections = new Set();
    // h.a, h.b: the random table and its starting point, the same for every game in the room.
    this.table = Array.from({ length: 5000 }, () => this.nextInt(10000));
    this.seed = this.nextInt(5000);
    this.winReported = false; // h.c
    this.build = null; // the build of the games in the room (acceptsBuild)
    this.steps = new Map(); // frame -> the random numbers used by then, as the first game reported it
    this.outOfStep = false;
    this.starting = false; // Main.r: a fight is starting; frames wait until every game has started
    this.countdown = { on: false, count: COUNTDOWN, action: '' }; // T.a, T.b, T.d
    this.fightingNow = false; // Main.am
    this.mode = 'WAITROOM'; // Main.ak
    this.page = 'WAITROOM'; // Main.al
    this.previousPage = ''; // Main.an
    this.story = 0; // Main.ao
    this.battleType = 1111; // Main.aC
    this.preset = -1; // Main.aD
    this.teams = 4; // Main.aE
    this.teamMap = [0, 1, 2, 3]; // Main.aF
    this.reset();
    this.closed = false;
    this.timers = [];
    // The original's threads: the countdown (T, every 100 ms), frame sending (av, every 10 ms) and
    // the watchdog that pings and times out games (aA, every 2 s after 10 s).
    this.countdownTimer = setTimeout(() => this.countdownTick(), 100);
    this.timers.push(setInterval(() => this.flushTick(), 10));
    this.watchdogStart = setTimeout(() => { this.timers.push(setInterval(() => this.watchdog(), 2000)); }, 10000);
    for (const timer of this.timers) if (timer.unref) timer.unref();
  }

  nextInt(bound) { return Math.floor(this.random() * bound); }

  close() {
    this.closed = true;
    clearTimeout(this.countdownTimer);
    clearTimeout(this.watchdogStart);
    for (const timer of this.timers) clearInterval(timer);
    for (const connection of [...this.connections]) connection.close();
  }

  // Main.k: the settings and the men a room starts with.
  reset() {
    this.allowJoinWhenFighting = true; // Main.V
    this.pickMusic();
    this.musicRandom = true; // Main.X
    this.multiplane = true; // Main.ab
    this.background = 'room1'; // Main.Y
    this.backgroundChosen = 'room1'; // Main.Z
    this.backgroundRandom = false; // Main.W
    this.horses = 0; // Main.ac
    this.giantObjects = 0; // Main.ad
    this.difficulty = 0; // Main.ae
    this.normalizeLevel = 1; // Main.ai
    this.dinosaurs = 0; // Main.aj
    this.testTroops = 0; // Main.af
    this.soldierNumber = 1; // Main.ag
    this.soldierReserved = 1; // Main.ah
    this.story = 0;
    this.mode = 'WAITROOM';
    this.page = 'WAITROOM';
    this.previousPage = '';
    this.men = Array.from({ length: MEN }, newMan);
  }

  // A computer player's level with a character: the best a player in the room has, else the game's highest.
  computerLevel(character) {
    let level = 0;
    for (const slot of this.online()) if (slot.levels[character] > level) level = slot.levels[character];
    return level > 0 ? level : MAX_LEVEL;
  }

  // Whether a game of this build (its movie and Ruffle, as the page reports them) may join: the same as
  // the games in the room, whose simulations must match step for step.
  acceptsBuild(build) {
    if (!this.online().length) this.build = build;
    return this.build === build;
  }

  // Every game reports, every 20 frames, how many random numbers it has used so far (<rpc>); games that
  // differ no longer show the same fight. The original passed these on and the games themselves closed
  // the connection on a difference ("Synchronization error"), which threw everyone out of the room; here
  // the server compares them and ends the fight instead, back to the menus, with everyone still in.
  checkStep(index, frame, used) {
    if (!this.fightingNow || this.outOfStep) return;
    const seen = this.steps.get(frame);
    if (!seen) {
      this.steps.set(frame, { used, from: index });
      if (this.steps.size > 64) this.steps.delete(this.steps.keys().next().value);
      return;
    }
    if (seen.used === used) return;
    this.outOfStep = true;
    this.log(`hf room ${this.number}: games ${seen.from} and ${index} out of step at frame ${frame}: ending the fight`);
    for (const slot of this.online()) {
      slot.connection.notice('Hai may khong con khop nhau (desync): tran dau dung lai. Bam Next roi Start Fight! de danh lai.');
    }
    const countdown = this.countdown;
    countdown.on = true;
    countdown.action = 'quitgame';
    countdown.count = 1;
  }

  pickBackground() { this.background = BACKGROUNDS[this.nextInt(BACKGROUNDS.length)]; } // Main.a
  pickMusic() { this.music = MUSIC[this.nextInt(MUSIC.length)]; } // Main.b

  // Main.f: counts the computers; a room nobody plays in any more starts over.
  recount() {
    let empty = true;
    this.connected = 0;
    for (let index = 0; index < CLIENTS; index += 1) {
      const slot = this.slots[index];
      if (slot.online) this.connected += 1;
      if (this.page === 'WAITROOM') {
        if (slot.online) empty = false;
      } else if (slot.online && slot.page !== 'WAITROOM') {
        empty = false;
      }
    }
    if (empty) {
      this.reset();
      this.broadcastGameSetting(-1);
      this.broadcastSetting(-1);
      this.broadcastStatus();
      this.broadcastMen(1);
    }
  }

  online() {
    const list = [];
    for (let index = 0; index < CLIENTS; index += 1) if (this.slots[index].online) list.push(this.slots[index]);
    return list;
  }

  broadcast(text) { for (const slot of this.online()) slot.connection.send(text); } // h.a(String)
  broadcastList(joined, quit) { for (const slot of this.online()) slot.connection.sendList(joined, quit); } // h.a(int, int)
  broadcastSetting(cid) { for (const slot of this.online()) slot.connection.sendSetting(cid); } // h.b(int)
  broadcastGameSetting(cid) { for (const slot of this.online()) slot.connection.sendGameSetting(cid); } // h.c(int)
  broadcastStatus() { // h.e
    for (const slot of this.online()) {
      slot.connection.send(`<status><mode>${this.mode}</mode><page>${this.page}</page><prepage>${this.previousPage}</prepage>`
        + `<storyi>${this.story}</storyi></status>`);
    }
  }
  // h.a(int): soldiers whose commander's computer left go too; then everyone gets the men.
  broadcastMen(changed) {
    for (const man of this.men) {
      if (!man.exists || man.commander === -1) continue;
      const commander = this.men[man.commander];
      if (commander.client !== -1 && !this.slots[commander.client].online) man.exists = false;
    }
    for (const slot of this.online()) slot.connection.sendMen(changed);
  }
  broadcastCount() { // h.c()
    this.broadcast(`<startcount><action>${this.countdown.action}</action><count>${this.countdown.count}</count>`
      + `<page>${this.page}</page></startcount>`);
  }
  broadcastClick(cid, what) { this.broadcast(`<chat2><c>${cid}</c><m>${what}</m></chat2>`); } // h.a(int, String)
  newSeed() { // h.f
    this.seed = this.nextInt(5000);
    this.broadcast(`<rp><rp>${this.seed}</rp></rp>`);
  }

  // h.a(): the frames of the fight start over.
  resetFrames() {
    this.steps.clear();
    this.outOfStep = false;
    for (let index = 0; index < CLIENTS; index += 1) {
      const slot = this.slots[index];
      slot.flushes = 0;
      slot.paused = false;
      slot.fighting = false;
      slot.lastPacket = -1;
      slot.leftFrame = -1;
      if (slot.connection) slot.connection.resetFrames();
    }
  }

  // h.b(): latencies ease towards their targets.
  easeLatencies() {
    for (let index = 0; index < CLIENTS; index += 1) {
      const slot = this.slots[index];
      if (slot.online) slot.latency = Math.trunc((slot.latencyTarget + slot.latency * 3) / 4);
    }
    this.broadcastList(-1, -1);
  }

  // T.a(): a fight starts; frames wait for every game.
  startFight() {
    for (const slot of this.slots) slot.started = false;
    this.starting = true;
  }

  // The countdown thread (T): every 100 ms, and 400 ms more after a step of a countdown.
  countdownTick() {
    if (this.closed) return;
    let delay = 100;
    try {
      if (this.starting) {
        this.starting = false;
        for (const slot of this.slots) {
          if (slot.online && !slot.started && slot.page !== 'WAITROOM') this.starting = true;
        }
        if (!this.starting) {
          for (const slot of this.slots) if (slot.connection) slot.connection.resetFrames();
          this.steps.clear();
          this.outOfStep = false;
          // Each game reports its experience after a fight and waits for the answer before it starts the
          // next, sending its characters' levels (<info>) on the way; a restart sends the men before
          // those come. So every game gets the men again now, with the same levels for everyone (each
          // game builds the fight from this list once <allstartedgame> comes).
          this.broadcastMen(0);
          this.newSeed();
          this.broadcast('<allstartedgame></allstartedgame>');
        }
      }
      const countdown = this.countdown;
      if (countdown.on) {
        countdown.count -= 1;
        if (countdown.count <= 0) {
          this.countdownDone(countdown.action);
          this.broadcastCount();
          countdown.count = COUNTDOWN;
          countdown.on = false;
        } else {
          this.broadcastCount();
        }
        delay += 400;
      }
    } catch (error) {
      this.log(`hf room ${this.number}: countdown: ${error.stack || error}`);
    }
    this.countdownTimer = setTimeout(() => this.countdownTick(), delay);
  }

  enterPage(page, previous) {
    this.page = page;
    this.fightingNow = false;
    this.previousPage = previous;
  }

  countdownDone(action) {
    const page = this.page;
    const mode = this.mode;
    if (action === 'clickvs' && page === 'WAITROOM') {
      this.mode = 'VSMODE';
      this.enterPage('CHARMENU', 'WAITROOM');
      this.battleType = 1111;
      this.preset = -1;
      if (this.backgroundChosen === 'random') {
        this.background = BACKGROUNDS[this.nextInt(BACKGROUNDS.length)];
        this.backgroundRandom = true;
      } else {
        this.background = this.backgroundChosen;
        this.backgroundRandom = false;
      }
      this.afterPageChange();
    } else if (action === 'clickstory' && page === 'WAITROOM') {
      this.mode = 'STORYMODE';
      this.enterPage('STORYMENU', 'WAITROOM');
      this.afterPageChange();
    } else if (action === 'clickbattle' && page === 'WAITROOM') {
      this.mode = 'BATTLEMODE';
      this.enterPage('BATTLESETTINGMENU', 'WAITROOM');
      this.battleType = 1111;
      this.preset = -1;
      this.teams = 4;
      this.background = 'battle4';
      this.backgroundRandom = false;
      this.afterPageChange();
    } else if (action === 'clicknext' && page === 'BATTLESETTINGMENU') {
      this.enterPage('CHARMENU', 'BATTLESETTINGMENU');
      for (let index = 0; index < MEN; index += 1) {
        const man = this.men[index];
        if (man.exists && man.team >= this.teams) man.team %= this.teams;
        if (index < MEN - 1 && man.controller >= 0) {
          for (let other = index + 1; other < MEN; other += 1) {
            const next = this.men[other];
            if (next.exists && next.controller >= 0 && next.client === man.client) next.team = man.team;
          }
        }
      }
      this.afterPageChange();
    } else if (action === 'clicknext' && page === 'STORYMENU') {
      this.enterPage('CHARMENU', 'STORYMENU');
      this.afterPageChange();
    } else if (action === 'clicknext' && page === 'CHARMENU' && mode === 'VSMODE') {
      this.enterPage('GAMESETTINGMENU', 'CHARMENU');
      this.broadcastList(-1, -1);
      this.broadcastMen(1);
      if (this.backgroundRandom) this.pickBackground();
      if (this.musicRandom) this.pickMusic();
      this.broadcastGameSetting(-1);
      this.broadcastStatus();
    } else if (action === 'clicknext' && page === 'CHARMENU' && (mode === 'STORYMODE' || mode === 'BATTLEMODE')) {
      this.fight('CHARMENU');
    } else if (action === 'clickfight' && page === 'GAMESETTINGMENU') {
      this.fight('GAMESETTINGMENU');
    } else if (action === 'quitgame' && this.fightingNow) {
      this.quitToMenu();
    } else if (action === 'restartgame' && this.fightingNow) {
      if (this.online().some((slot) => slot.page === 'WAITROOM')) {
        this.quitToMenu();
      } else {
        this.startFight();
        this.resetFrames();
        this.broadcast('<restartgame></restartgame>');
        this.broadcastList(-1, -1);
        this.broadcastMen(1);
        this.resetFrames();
        this.easeLatencies();
        this.broadcastGameSetting(-1);
        this.broadcast('<restartgame></restartgame>');
      }
    } else if (action === 'nextstage' && this.fightingNow) {
      if (this.online().some((slot) => slot.page === 'WAITROOM')) {
        this.page = 'STORYMENU';
        this.fightingNow = false;
        this.previousPage = 'FIGHTING';
        this.quitBroadcasts();
      } else {
        this.startFight();
        if (this.story < 6) this.story += 1;
        this.broadcastList(-1, -1);
        this.broadcastMen(1);
        this.resetFrames();
        this.easeLatencies();
        this.broadcastGameSetting(-1);
        this.broadcast('<nextstage></nextstage>');
      }
    }
  }

  afterPageChange() {
    this.broadcastList(-1, -1);
    this.broadcastMen(1);
    this.broadcastGameSetting(-1);
    this.broadcastStatus();
  }

  fight(previous) {
    this.startFight();
    this.page = 'FIGHTING';
    this.fightingNow = true;
    this.previousPage = previous;
    this.broadcastList(-1, -1);
    this.broadcastMen(1);
    this.resetFrames();
    this.easeLatencies();
    this.broadcastGameSetting(-1);
    this.broadcastStatus();
  }

  quitToMenu() {
    if (this.mode === 'VSMODE') this.enterPage('CHARMENU', 'FIGHTING');
    else if (this.mode === 'STORYMODE') this.enterPage('STORYMENU', 'FIGHTING');
    else if (this.mode === 'BATTLEMODE') this.enterPage('BATTLESETTINGMENU', 'FIGHTING');
    this.quitBroadcasts();
  }

  quitBroadcasts() {
    this.resetFrames();
    this.broadcastStatus();
    this.broadcastList(-1, -1);
    this.broadcastMen(1);
    this.resetFrames();
    this.broadcastGameSetting(-1);
    this.broadcastStatus();
  }

  // The frame senders (av, one per computer): every 10 ms; a send is due after another game's packet
  // and, besides, every 100 to 200 ms.
  flushTick() {
    if (this.starting) return;
    for (let index = 0; index < CLIENTS; index += 1) {
      const slot = this.slots[index];
      slot.tickCount = (slot.tickCount || 0) + 1;
      if (slot.tickCount === 20) {
        slot.tickCount = this.nextInt(10);
        slot.flushes += 1;
      }
      if (slot.flushes <= 0) continue;
      if (slot.fighting && slot.connection) slot.connection.sendFrames();
      slot.flushes -= 1;
    }
  }

  // The watchdog (aA): pings quiet games, and takes out games silent for 35 s (or idle too long).
  watchdog() {
    const now = Date.now();
    for (let index = 0; index < CLIENTS; index += 1) {
      const slot = this.slots[index];
      if (!slot.online) continue;
      const afk = this.afkMinutes * 60000;
      if (slot.lastMessage < now - 35000 || (afk > 60000 && slot.lastActive < now - afk)) {
        this.log(`hf room ${this.number}: ${slot.name} ${slot.lastMessage < now - 35000 ? 'timed out' : 'was idle'}`);
        const connection = slot.connection;
        connection.leave();
        connection.kicked = true;
        connection.close();
        continue;
      }
      if (slot.lastMessage < now - 20000) slot.connection.send('<ping></ping>');
    }
  }

  // The line the room list shows for this room.
  people() {
    return this.online().map((slot) => `${slot.name}(${slot.latencyShown - 1})`).join(', ');
  }
}

// ---- One computer in a room (the original's thread "i") -------------------------------------------

class HfConnection {
  // socket: { write(text), close() }; feed it the received bytes with receive(), and closed() at the end.
  constructor(room, socket, { address = '', build = '' } = {}) {
    this.room = room;
    this.socket = socket;
    this.address = address;
    this.build = build; // the page's movie and Ruffle (acceptsBuild)
    this.index = -1; // n
    this.name = ''; // o
    this.cc = ''; // p
    this.players = ['', '', '']; // r
    this.lastFrame = -1; // s: the last frame of this game's, in order
    this.nextFrame = 0; // t: the next frame to send this game
    this.queued = ''; // v: <rpc> lines from the others, sent with the next frames (none now: Room.checkStep)
    this.cheat = 0; // x
    this.kicked = false; // b
    this.ended = false;
    this.lines = [];
    this.waiting = null;
    this.buffer = Buffer.alloc(0);
    room.connections.add(this);
    this.done = this.run();
  }

  // ---- bytes in and out
  receive(chunk) {
    if (this.ended) return;
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : Buffer.from(chunk);
    let start = 0;
    for (let at = this.buffer.indexOf(10); at >= 0; at = this.buffer.indexOf(10, start)) {
      let line = this.buffer.toString('utf8', start, at);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      start = at + 1;
      this.pushLine(line);
    }
    this.buffer = this.buffer.subarray(start);
    if (this.buffer.length > 262144) this.close(); // no line is that long
  }

  closed() {
    if (this.ended) return;
    this.ended = true;
    this.pushLine(null);
  }

  pushLine(line) {
    if (this.waiting) {
      const resolve = this.waiting;
      this.waiting = null;
      resolve(line);
    } else {
      this.lines.push(line);
    }
  }

  readLine() { // BufferedReader.readLine: null at the end
    if (this.lines.length) return Promise.resolve(this.lines.shift());
    if (this.ended) return Promise.resolve(null);
    return new Promise((resolve) => { this.waiting = resolve; });
  }

  send(text) { // i.a(String)
    if (this.ended) return;
    try { this.socket.write(text + '\n'); } catch { /* the closing follows */ }
  }

  close() {
    if (!this.socketClosed) {
      this.socketClosed = true;
      try { this.socket.close(); } catch { /* already closed */ }
    }
    this.closed();
  }

  get slot() { return this.room.slots[this.index]; }

  // ---- the conversation
  async run() {
    try {
      await this.conversation();
    } catch (error) {
      if (!(error instanceof XmlError)) this.room.log(`hf room ${this.room.number}: ${error.stack || error}`);
    } finally {
      this.leave(); // i.h
      this.room.connections.delete(this);
      this.close();
    }
  }

  async conversation() {
    const room = this.room;
    await sleep(250);
    this.send('<ini></ini>');
    await sleep(250);
    if (room.closed) return;
    let line = await this.readLine();
    if (line === null) return;
    const join = parseXml(line);
    const versions = byTag(join, 'ver');
    if (!versions.length) return;
    if (int(valueOf(versions[0])) !== VERSION) return this.refuse('v');
    if (!room.acceptsBuild(this.build)) {
      room.log(`hf room ${room.number}: a game of another build (${this.build || 'none'}, the room has ${room.build}) turned away`);
      return this.refuse('v');
    }
    if (room.connected >= room.limit) return this.refuse('f');
    if (!room.allowJoinWhenFighting && room.fightingNow) return this.refuse('p');
    if (room.password) {
      this.send('<req_pw></req_pw>');
      line = await this.readLine();
      if (line === null) return;
      if (room.password !== tagValue(parseXml(line), 'pwd')) return this.refuse('pwd');
    }
    const latency = await this.measure();
    if (latency === null) return;
    if (room.latencyLimit !== -1 && latency > room.latencyLimit) return this.refuse('l');
    this.send(`<maxclients><maxclients>${room.limit}</maxclients></maxclients>`);
    this.send(`<rp><rp>${room.seed}</rp></rp>`);
    for (let part = 0; part < 10; part += 1) {
      let text = `<rand><i>${part * 500}</i>`;
      for (let k = 0; k < 500; k += 1) text += `<n>${room.table[k + part * 500]}</n>`;
      this.send(text + '</rand>');
    }
    this.send('<req_info></req_info>');
    line = await this.readLine();
    if (line === null || room.closed) return;
    room.recount();
    if (room.connected >= room.limit) return this.refuse('f');
    for (let index = 0; index < CLIENTS; index += 1) {
      if (!room.slots[index].online) { this.index = index; break; }
    }
    if (this.index < 0) return this.refuse('f');
    const info = parseXml(line);
    this.name = tagValue(info, 'name');
    const ccs = byTag(info, 'cc');
    this.cc = ccs.length ? valueOf(ccs[0]) : '';
    const slot = this.slot;
    for (let k = 0; k < 3; k += 1) this.players[k] = tagValue(info, 'p', k);
    for (let k = 0; k < 30; k += 1) {
      slot.levels[k] = int(tagValue(info, 'l', k));
      if (slot.levels[k] > MAX_LEVEL) this.cheat = 1;
    }
    slot.levels[20] = slot.levels[8];
    slot.name = this.name;
    slot.cc = this.cc;
    slot.country = this.cc || 'unknown';
    slot.players = [...this.players];
    slot.lastMessage = slot.lastActive = Date.now();
    slot.connection = this;
    slot.online = true;
    slot.paused = false;
    slot.hasPlayer = false;
    slot.latency = slot.latencyTarget = slot.latencyShown = latency;
    slot.page = 'WAITROOM';
    slot.admin = false;
    room.recount();
    this.sendSetting(-1);
    this.sendGameSetting(-1);
    this.sendList(-1, -1);
    this.sendMen(1);
    if (!room.fightingNow) {
      if (room.page !== 'WAITROOM') {
        if (room.mode === 'VSMODE') room.page = 'CHARMENU';
      } else {
        room.page = 'WAITROOM';
        room.mode = 'WAITROOM';
      }
    }
    room.broadcastStatus();
    room.log(`hf room ${room.number}: ${this.name} (latency ${latency - 1}) joins`);
    room.broadcastList(this.index, -1);
    if (room.connected === 2 && room.fightingNow) {
      room.countdown.on = true;
      room.countdown.action = 'quitgame';
      room.countdown.count = 1;
    }
    this.notice('Room Server v0.7+.<br />Type /help for commands.');
    if (room.fightingNow && room.connected > 2) {
      if (room.mode === 'VSMODE') this.notice('Players are in VS Mode.');
      else if (room.mode === 'BATTLEMODE') this.notice('Players are in Battle Mode.');
      else if (room.mode === 'STORYMODE') this.notice(`Players are in Story ${room.story + 1}`);
    }
    if (this.cheat === 1) return; // levels above the game's highest: out (the finally leaves)
    for (line = await this.readLine(); line !== null; line = await this.readLine()) {
      if (this.index < 0) return;
      const now = Date.now();
      slot.lastMessage = now;
      if (line !== '<pingok></pingok>') slot.lastActive = now;
      if (this.kicked || this.cheat === 1) return;
      await this.handle(line);
      if (this.kicked) return;
    }
  }

  refuse(reason) {
    this.send(`<error><reason>${reason}</reason></error>`);
    return this.readLine();
  }

  // Ten pings: the latency is the shortest round trip, in frames (a multiple of STEP), with a margin.
  async measure() {
    let best = 5000;
    for (let k = 0; k < 10; k += 1) {
      const sent = Date.now();
      this.send('<ping></ping>');
      if (await this.readLine() === null) return null;
      const took = Date.now() - sent;
      if (took < best) best = took;
      await sleep(took < 500 ? took : 500);
    }
    if (best <= 0) best = 1;
    best += 15;
    return STEP + Math.ceil((best * 1.7 + 0.16) / 33 / STEP) * STEP;
  }

  async handle(line) {
    const room = this.room;
    const slot = this.slot;
    const doc = parseXml(line);
    const kind = doc.name;
    if (kind === 'f') { // a frame of this game's keys
      const frame = int(tagValue(doc, 'i'));
      if (frame === 1) room.winReported = false;
      if (this.lastFrame + 1 === frame) {
        slot.frames[frame % FRAMES_KEPT] = line;
        this.lastFrame = frame;
      }
      return;
    }
    if (kind === 'pk') { // the end of a packet: the others may get this game's frames
      slot.lastPacket = this.lastFrame;
      this.requestFlushes();
      return;
    }
    if (kind === 't') { int(tagValue(doc, 'd')); return; }
    if (kind === 'rpc') {
      room.checkStep(this.index, int(tagValue(doc, 'cl')), int(tagValue(doc, 'rp')));
      return;
    }
    if (kind === 'chat') {
      const from = int(tagValue(doc, 'c'));
      if (from < 0 || from >= SLOTS) throw new XmlError('no such computer');
      if (this.command(tagValue(doc, 'm'))) room.broadcast(line);
      return;
    }
    if (kind === 'pausegame' || kind === 'resumegame') {
      slot.paused = kind === 'pausegame';
      room.broadcastList(-1, -1);
      return;
    }
    if (kind === 'startcount') return this.startCount(doc);
    if (kind === 'cancelcount') {
      const countdown = room.countdown;
      if (countdown.on && (countdown.action === 'clickfight' || countdown.action === tagValue(doc, 'action'))) {
        countdown.on = false;
        countdown.action = '';
        countdown.count = COUNTDOWN;
        room.broadcastClick(this.index, 'clickcancel');
        room.broadcast('<cancelcount></cancelcount>');
      }
      return;
    }
    if (kind === 'setting') {
      if (room.page === 'WAITROOM') {
        const allow = byTag(doc, 'waitwhenfight');
        if (allow.length) room.allowJoinWhenFighting = valueOf(allow[0]) === '1';
        room.broadcastSetting(this.index);
      }
      return;
    }
    if (kind === 'gamesetting') return this.gameSetting(doc);
    if (kind === 'clickback') return this.clickBack(doc);
    if (kind === 'page') {
      slot.page = valueOf(doc);
      slot.fighting = slot.page === 'FIGHTING';
      room.broadcastList(-1, -1);
      return;
    }
    if (kind === 'info') return this.updateInfo(doc);
    if (kind === 'addplayer') return this.addPlayer(doc);
    if (kind === 'delman') {
      if (room.page !== 'CHARMENU') return;
      const index = int(valueOf(doc));
      const man = room.men[index];
      if (!man) throw new XmlError('no such man');
      if (man.exists && ((man.controller === -1 && !room.countdown.on) || man.client === this.index)) {
        man.exists = false;
        for (const other of room.men) if (other.exists && other.commander === index) other.exists = false;
        room.broadcastMen(1);
      }
      return;
    }
    if (kind === 'addcom') {
      if (room.page !== 'CHARMENU') return;
      if (!room.countdown.on && this.addComputer()) {
        this.limitMen();
        room.broadcastMen(1);
      }
      return;
    }
    if (kind === 'addsoldier') return this.addSoldier(doc);
    if (kind === 'redorandom') {
      if (room.page !== 'CHARMENU') return;
      if (!room.countdown.on) {
        for (let index = 0; index < MEN; index += 1) if (room.men[index].exists && room.men[index].random) this.pickCharacter(index);
        room.broadcastMen(0);
      }
      return;
    }
    if (kind === 'manteam') {
      if (room.page !== 'CHARMENU') return;
      const index = int(tagValue(doc, 'i'));
      const man = room.men[index];
      if (!man) throw new XmlError('no such man');
      if (man.exists && (man.controller === -1 || man.client === this.index)) {
        const team = int(tagValue(doc, 'team'));
        man.team = team;
        for (const other of room.men) if (other.exists && other.commander === index) other.team = team;
        if (room.mode === 'BATTLEMODE' && man.controller >= 0) {
          room.men.forEach((other, k) => { if (k !== index && other.exists && other.client === man.client) other.team = team; });
        }
        room.broadcastMen(0);
      }
      return;
    }
    if (kind === 'manchar') return this.chooseCharacter(doc);
    if (kind === 'increaselatency') {
      slot.latency += 2;
      slot.latencyTarget += 2;
      room.broadcastList(-1, -1);
      return;
    }
    if (kind === 'remeasure') {
      let best = 5000;
      for (let k = 0; k < 10; k += 1) {
        const sent = Date.now();
        this.send('<ping></ping>');
        for (let reply = await this.readLine(); reply !== '<pingok></pingok>'; reply = await this.readLine()) {
          if (reply === null) throw new XmlError('closed');
        }
        const took = Date.now() - sent;
        if (took < best) best = took;
        await sleep(took < 500 ? took : 500);
      }
      if (best <= 0) best = 1;
      best += 15;
      slot.latency = STEP + Math.ceil((best * 1.7 + 0.16) / 33 / STEP) * STEP;
      slot.latencyTarget = slot.latency;
      slot.latencyShown = slot.latency;
      room.broadcastList(-1, -1);
      return;
    }
    if (kind === 'startedgame') {
      slot.fighting = true;
      slot.hasPlayer = false;
      this.resetFrames();
      for (let k = 0; k < 3; k += 1) {
        if (!room.men[this.index * 3 + k].exists) { slot.hasPlayer = true; break; }
      }
      slot.started = true;
      return;
    }
    if (kind === 'winteam') {
      const team = int(tagValue(doc, 'winteam'));
      if (!room.winReported) {
        room.winReported = true;
        room.log(`hf room ${room.number}: ${room.mode} won by ${team}`);
      }
    }
  }

  // i.i(): this game's packet came; each other fighting game gets a send.
  requestFlushes() {
    const room = this.room;
    if (!room.fightingNow) return;
    for (let index = 0; index < CLIENTS; index += 1) {
      if (index !== this.index && room.slots[index].fighting) room.slots[index].flushes += 1;
    }
  }

  // i.b(): the frames of the others this game has not had, as long as every other game sent them.
  sendFrames() {
    const room = this.room;
    let text = '';
    for (;;) {
      const t = this.nextFrame;
      let complete = true;
      let any = false;
      for (let index = 0; index < CLIENTS; index += 1) {
        if (index === this.index) continue;
        const other = room.slots[index];
        if (!other.fighting && other.leftFrame < t) continue;
        any = true;
        if (other.lastPacket < t) { complete = false; break; }
      }
      if (!complete || !any) break;
      let part = '';
      for (let index = 0; index < CLIENTS; index += 1) {
        if (index === this.index) continue;
        const other = room.slots[index];
        if ((other.fighting || other.leftFrame >= t) && other.lastPacket >= t) part += other.frames[t % FRAMES_KEPT] || '';
      }
      if (!part) break;
      text += part;
      this.nextFrame += 1;
    }
    if (!text) return;
    if (this.queued) {
      text += this.queued;
      this.queued = '';
    }
    this.send(text);
  }

  resetFrames() { // i.c()
    this.lastFrame = -1;
    this.nextFrame = 0;
    this.queued = '';
  }

  // i.a(): this computer leaves the room.
  leave() {
    if (this.index === -1) return;
    const room = this.room;
    const index = this.index;
    this.requestFlushes();
    const slot = room.slots[index];
    if (slot.online && slot.connection === this) {
      for (const man of room.men) {
        if (man.client !== index && (man.commander < index * 3 || man.commander > index * 3 + 2)) continue;
        Object.assign(man, newMan(), { random: true });
        man.char = '';
      }
      slot.admin = false;
      slot.online = false;
      if (slot.lastPacket > 0) slot.leftFrame = slot.lastPacket;
      slot.fighting = false;
      slot.hasPlayer = false;
      slot.connection = null;
      if (!room.fightingNow) room.broadcastMen(1);
      room.broadcastList(-1, index);
      this.index = -1;
      room.log(`hf room ${room.number}: ${this.name} leaves`);
      room.recount();
    }
    this.index = -1;
  }

  // ---- what the server sends one game
  sendSetting(cid) { // i.a(int)
    this.send(`<setting>${cid !== -1 ? `<c>${cid}</c>` : ''}<waitwhenfight>${this.room.allowJoinWhenFighting ? 1 : 0}</waitwhenfight></setting>`);
  }

  sendGameSetting(cid) { // i.b(int)
    const room = this.room;
    this.send(`<gamesetting>${cid !== -1 ? `<c>${cid}</c>` : ''}<bgid>${room.background}</bgid><musicid>${room.music}</musicid>`
      + `<mp>${room.multiplane ? 1 : 0}</mp><bgrandom>${room.backgroundRandom ? 1 : 0}</bgrandom>`
      + `<musicrandom>${room.musicRandom ? 1 : 0}</musicrandom><horse>${room.horses}</horse>`
      + `<giantobj>${room.giantObjects}</giantobj><diff>${room.difficulty}</diff><norlev>${room.normalizeLevel}</norlev>`
      + `<dino>${room.dinosaurs}</dino><testtroop>${room.testTroops}</testtroop><soldiernumber>${room.soldierNumber}</soldiernumber>`
      + `<soldierreserved>${room.soldierReserved}</soldierreserved><storyi>${room.story}</storyi>`
      + `<battletype>${room.battleType}</battletype><presettype>${room.preset}</presettype></gamesetting>`);
  }

  sendList(joined, quit) { // i.a(int, int)
    let text = `<list><cid>${this.index}</cid>`;
    if (joined !== -1) text += `<join_cid>${joined}</join_cid>`;
    if (quit !== -1) text += `<quit_cid>${quit}</quit_cid>`;
    for (const slot of this.room.slots) {
      text += `<info><name><![CDATA[${slot.name}]]></name><online>${slot.online ? 1 : 0}</online>`
        + `<hasplayer>${slot.hasPlayer ? 1 : 0}</hasplayer><cc>${slot.cc}</cc><pausegame>${slot.paused ? 1 : 0}</pausegame>`
        + `<latency>${slot.latency}</latency><page>${slot.page}</page>`;
      for (let k = 0; k < 3; k += 1) text += `<p><![CDATA[${slot.players[k]}]]></p>`;
      text += `<leave_f>${slot.leftFrame}</leave_f></info>`;
    }
    this.send(text + '</list>');
  }

  sendMen(changed) { // i.c(int)
    let text = `<manlist><numchanged>${changed}</numchanged>`;
    for (const man of this.room.men) {
      text += `<man><cid>${man.client}</cid><con>${man.controller}</con><team>${man.team}</team><char>${man.char}</char>`
        + `<lv>${man.level}</lv><comm>${man.commander}</comm><rand>${man.random ? 1 : 0}</rand><exist>${man.exists ? 1 : 0}</exist></man>`;
    }
    this.send(text + '</manlist>');
  }

  notice(text) { // i.b(String): a line from the server to this game only
    this.send(`<chat><c>${SERVER_SLOT}</c><m><![CDATA[<font color="#FFFFAA">${text}</font>]]></m></chat>`);
  }

  announce(text) { // i.e(String): a line from the server to everyone
    this.room.broadcast(`<chat><c>${SERVER_SLOT}</c><m><![CDATA[<font color="#FFCCFF">${text}</font>]]></m></chat>`);
  }

  // ---- the waiting room and the menus
  startCount(doc) {
    const room = this.room;
    const countdown = room.countdown;
    if (countdown.on) return;
    const action = tagValue(doc, 'action');
    const page = tagValue(doc, 'page');
    let together = true;
    for (const slot of room.online()) {
      if (page === 'FIGHTING' ? slot.page !== 'FIGHTING' && slot.page !== 'WAITROOM' : slot.page !== page) { together = false; break; }
    }
    if (room.page !== page || !together) return;
    const start = (what, count = COUNTDOWN, shown = what) => {
      countdown.on = true;
      countdown.action = what;
      countdown.count = count;
      room.broadcastClick(this.index, shown);
    };
    const zero = () => byTag(doc, 'zero').length && valueOf(byTag(doc, 'zero')[0]) === 'true';
    if (room.page === 'WAITROOM' && (action === 'clickvs' || action === 'clickstory' || action === 'clickbattle')) {
      start(action);
    } else if (room.page === 'CHARMENU' && action === 'clicknext') {
      if (this.canStart()) start(action, COUNTDOWN, room.mode === 'BATTLEMODE' || room.mode === 'STORYMODE' ? 'clickfight' : action);
    } else if ((room.page === 'STORYMENU' || room.page === 'BATTLESETTINGMENU') && action === 'clicknext') {
      start(action);
    } else if (room.page === 'GAMESETTINGMENU' && action === 'clickfight') {
      start(action);
    } else if (room.fightingNow && action === 'quitgame') {
      const isZero = zero();
      start(action, isZero ? 1 : COUNTDOWN * 2);
    } else if (room.fightingNow && action === 'restartgame') {
      if (room.backgroundRandom) room.pickBackground();
      for (let index = 0; index < MEN; index += 1) if (room.men[index].exists && room.men[index].random) this.pickCharacter(index);
      if (room.musicRandom) room.pickMusic();
      start(action, COUNTDOWN * 2);
      if (zero()) countdown.count = 1;
    } else if (room.fightingNow && action === 'nextstage') {
      start(action, COUNTDOWN * 2);
      if (zero()) countdown.count = 1;
    }
  }

  // i.d(): whether the character menu may go on.
  canStart() {
    const room = this.room;
    const perTeam = [0, 0, 0, 0, 0];
    let men = 0;
    let humans = 0;
    for (const man of room.men) {
      if (!man.exists) continue;
      if (man.controller !== -1 && room.slots[man.client] && room.slots[man.client].online) humans += 1;
      men += 1;
      perTeam[man.team + 1] += 1;
    }
    let teams = perTeam[0];
    let crowded = false;
    for (let k = 1; k < 5; k += 1) {
      if (perTeam[k] > 0) teams += 1;
      if (perTeam[k] > 5) crowded = true;
    }
    const refuse = (body) => { this.send(`<charmenunexterror>${body}</charmenunexterror>`); return false; };
    if (men === 0) return refuse('<m>NoPlayer</m>');
    if (humans === 0) return refuse('<m>NoHumanPlayer</m>');
    if (men === 1 && room.mode === 'VSMODE') return refuse('<m>OnePlayerOnly</m>');
    if (teams <= 1 && room.mode === 'VSMODE') return refuse('<m>OneTeamOnly</m>');
    if (room.mode === 'BATTLEMODE') {
      if (teams < room.teams) return refuse(`<m>battleNoEnoughTeam</m><a>${room.battleType}</a><b>${room.teams}</b><c>${teams}</c>`);
      if (crowded) return refuse('<m>battleNotAllowMoreThan5</m>');
    }
    return true;
  }

  clickBack(doc) {
    const room = this.room;
    if (room.countdown.on || room.page !== tagValue(doc, 'page')) return;
    const back = (mode, page) => {
      room.previousPage = room.page;
      if (mode) room.mode = mode;
      room.page = page;
      room.broadcastStatus();
      room.broadcastClick(this.index, 'clickback');
    };
    if (room.page === 'CHARMENU' && room.mode === 'VSMODE') back('WAITROOM', 'WAITROOM');
    else if (room.page === 'CHARMENU' && room.mode === 'STORYMODE') back('STORYMODE', 'STORYMENU');
    else if (room.page === 'CHARMENU' && room.mode === 'BATTLEMODE') back('BATTLEMODE', 'BATTLESETTINGMENU');
    else if (room.page === 'STORYMENU' || room.page === 'BATTLESETTINGMENU') back('WAITROOM', 'WAITROOM');
    else if (room.page === 'GAMESETTINGMENU') back(null, 'CHARMENU');
  }

  gameSetting(doc) {
    const room = this.room;
    if (!['GAMESETTINGMENU', 'CHARMENU', 'STORYMENU', 'BATTLESETTINGMENU'].includes(room.page)) return;
    const value = (name) => { const found = byTag(doc, name); return found.length ? valueOf(found[0]) : undefined; };
    const background = value('bgid');
    if (background !== undefined && (room.backgroundRandom || room.background !== background)) {
      room.background = room.backgroundChosen = background;
      if (background === 'random') {
        room.backgroundRandom = true;
        room.pickBackground();
      } else {
        room.backgroundRandom = false;
      }
    }
    const music = value('musicid');
    if (music !== undefined && (room.musicRandom || room.music !== music)) {
      room.music = music;
      if (music === 'random') {
        room.musicRandom = true;
        room.pickMusic();
      } else {
        room.musicRandom = false;
      }
    }
    const multiplane = value('mp');
    if (multiplane !== undefined) room.multiplane = multiplane === '1';
    const numbers = [['horse', 'horses'], ['giantobj', 'giantObjects'], ['diff', 'difficulty'], ['norlev', 'normalizeLevel'],
      ['dino', 'dinosaurs'], ['testtroop', 'testTroops'], ['soldiernumber', 'soldierNumber'],
      ['soldierreserved', 'soldierReserved'], ['storyi', 'story']];
    for (const [tag, field] of numbers) {
      const raw = value(tag);
      if (raw !== undefined) room[field] = int(raw);
    }
    const raw = value('bt');
    if (raw !== undefined && room.preset !== -int(raw) - 1 && (room.preset !== -1 || room.battleType !== int(raw))) {
      let type = int(raw);
      if (type < 0) {
        for (let index = 0; index < MEN; index += 1) {
          room.men[index].exists = false;
          if (index >= 12) room.men[index].random = false;
          room.men[index].commander = -1;
        }
        room.preset = -type - 1;
        const preset = (level, list) => list.forEach(([index, char, team]) => Object.assign(room.men[index], { level, char, exists: true, team }));
        if (type === -1) {
          type = 11;
          preset(10, [[19, 'leo', 1], [20, 'iczzy', 1], [21, 'heater', 1], [22, 'raye', 1], [23, 'sinan', 1]]);
        } else if (type === -2) {
          type = 1111;
          preset(11, [[15, 'taylor', 1], [16, 'leo', 1], [17, 'jenny', 1], [18, 'raye', 2], [19, 'iczzy', 2], [20, 'heater', 2],
            [21, 'gordon', 3], [22, 'jason', 3], [23, 'titto', 3]]);
        } else if (type === -3) {
          type = 111;
          preset(12, [[15, 'heater', 1], [16, 'iczzy', 1], [17, 'raye', 1], [18, 'sinan', 1], [19, 'titto', 1], [20, 'leo', 2],
            [21, 'gordon', 2], [22, 'jenny', 2], [23, 'jason', 2]]);
        } else if (type === -4) {
          type = 112;
          preset(14, [[15, 'leo', 0], [16, 'sinan', 0], [17, 'gordon', 0], [18, 'iczzy', 1], [19, 'heater', 1], [20, 'raye', 1],
            [21, 'jason', 3], [22, 'titto', 3], [23, 'giggs', 3]]);
        }
      } else {
        room.preset = -1;
      }
      room.battleType = type;
      if (type === 11) room.teams = 2;
      else if (type === 12 || type === 111) room.teams = 3;
      else if (type === 22 || type === 13 || type === 1111 || type === 112) room.teams = 4;
      if (room.teams === 2) room.background = 'battle2';
      else if (room.teams === 3) room.background = 'battle3';
      else if (room.teams === 4) room.background = 'battle4';
      const maps = { 11: [0, 1, -1, -1], 22: [0, 1, 0, 1], 111: [0, 1, 2, -1], 1111: [0, 1, 2, 3], 12: [1, 0, 1, -1],
        13: [0, 1, 1, 1], 112: [1, 1, 0, 2] };
      if (maps[type]) room.teamMap = maps[type];
    }
    room.broadcastGameSetting(this.index);
  }

  updateInfo(doc) {
    const room = this.room;
    const slot = this.slot;
    slot.name = tagValue(doc, 'name'); // (the original keeps the name it joined with for its log and /me)
    for (let k = 0; k < 3; k += 1) slot.players[k] = this.players[k] = tagValue(doc, 'p', k);
    for (let k = 0; k < 30; k += 1) {
      slot.levels[k] = int(tagValue(doc, 'l', k));
      if (slot.levels[k] > MAX_LEVEL) this.cheat = 1;
    }
    for (let k = 0; k < 3; k += 1) {
      const man = room.men[this.index * 3 + k];
      if (!man.exists) continue;
      const character = CHARACTERS.indexOf(man.char);
      if (character >= 0 && slot.levels[character] > 0) {
        man.level = slot.levels[character];
        for (const other of room.men) if (other.exists && other.commander === this.index * 3 + k) other.level = man.level;
      }
    }
    if (!room.fightingNow) {
      room.broadcastList(-1, -1);
      room.broadcastMen(1);
    }
  }

  addPlayer(doc) {
    const room = this.room;
    if (room.page !== 'CHARMENU') return;
    const controller = int(valueOf(doc));
    const index = this.index * 3 + controller;
    const man = room.men[index];
    if (!man || controller < 0 || controller > 2) throw new XmlError('no such player');
    if (man.exists) return;
    man.exists = true;
    man.client = this.index;
    man.controller = controller;
    man.team = -1;
    room.men.forEach((other, k) => { if (k !== index && other.exists && other.client === this.index) man.team = other.team; });
    if (man.team === -1) man.team = this.leastTeam(index);
    if (man.random || !man.char) {
      man.random = true;
      this.pickCharacter(index);
    } else {
      const character = CHARACTERS.indexOf(man.char);
      if (character >= 0 && (this.slot.levels[character] <= 0 || this.slot.levels[character] !== man.level)) {
        man.random = true;
        this.pickCharacter(index);
      }
    }
    this.limitMen();
    room.broadcastMen(1);
  }

  // The team with the fewest men (not counting soldiers), for a new man.
  leastTeam(except) {
    const room = this.room;
    const counts = [0, 0, 0, 0];
    room.men.forEach((other, k) => { if (k !== except && other.exists && other.commander === -1) counts[other.team] += 1; });
    if (room.mode !== 'BATTLEMODE') room.teams = 4;
    let fewest = 999;
    let team = 0;
    for (let k = 0; k < room.teams; k += 1) {
      if (counts[k] < fewest) {
        fewest = counts[k];
        team = k;
      }
    }
    return team;
  }

  // i.e(): a computer player, in the first free place after the 12 human ones.
  addComputer() {
    const room = this.room;
    if (room.men.filter((man) => man.exists).length >= 12) return false;
    for (let index = MEN - 1; index >= 12; index -= 1) {
      if (room.men[index].exists || (index !== 12 && !room.men[index - 1].exists)) continue;
      const man = room.men[index];
      man.exists = true;
      man.team = room.mode === 'BATTLEMODE' || room.mode === 'VSMODE' ? this.leastTeam(index) : 3;
      man.client = -1;
      man.controller = -1;
      man.random = true;
      man.commander = -1;
      this.pickCharacter(index);
      return true;
    }
    return false;
  }

  addSoldier(doc) {
    const room = this.room;
    if (room.page !== 'CHARMENU' || room.countdown.on) return;
    const index = int(tagValue(doc, 'i'));
    let soldier = tagValue(doc, 'char');
    const commander = room.men[index];
    if (!commander) throw new XmlError('no such man');
    const roll = this.room.random();
    switch (commander.char) {
      case 'lucas': case 'drew': case 'shawn':
        if (soldier === 'z_infantry01' && roll < 0.3) soldier = 'z_villager01';
        else if (soldier === 'z_archer01' && roll < 0.3) soldier = 'z_woman01';
        break;
      case 'vivian':
        if (soldier === 'z_infantry01') soldier = 'z_villager01';
        else if (soldier === 'z_archer01') soldier = 'z_woman01';
        break;
      case 'jenny': case 'sinan':
        if (soldier === 'z_archer01') soldier = 'z_woman01';
        break;
      case 'jason':
        if (soldier === 'z_infantry01') soldier = 'z_bandit01';
        else if (soldier === 'z_archer01') soldier = 'z_dagger01';
        else soldier = 'z_sickle01';
        break;
      case 'giggs': case 'titto':
        if (soldier === 'z_infantry01') soldier = 'z_bandit01';
        else if (soldier === 'z_archer01') soldier = 'z_dagger01';
        break;
      case 'iczzy':
        if (soldier === 'z_cavalry01') soldier = 'z_iceman';
        break;
      case 'heater':
        if (soldier === 'z_cavalry01') soldier = 'z_skull';
        break;
      default:
        break;
    }
    if (commander.exists && commander.commander === -1 && this.placeSoldier(index, soldier)) {
      this.limitMen();
      room.broadcastMen(1);
    }
  }

  // i.a(int, String)
  placeSoldier(commanderIndex, soldier) {
    const room = this.room;
    if (room.men.filter((man) => man.exists).length >= 12) return false;
    for (let index = 12; index < MEN; index += 1) {
      const man = room.men[index];
      if (man.exists) continue;
      const commander = room.men[commanderIndex];
      Object.assign(man, { exists: true, client: -1, controller: -1, team: commander.team, random: false,
        commander: commanderIndex, char: soldier, level: commander.level });
      return true;
    }
    return false;
  }

  // i.f(): at most 12 men; the later ones go.
  limitMen() {
    let count = 0;
    for (const man of this.room.men) {
      if (!man.exists) continue;
      if (count < 12) count += 1;
      else man.exists = false;
    }
  }

  chooseCharacter(doc) {
    const room = this.room;
    if (room.page !== 'CHARMENU') return;
    const index = int(tagValue(doc, 'i'));
    const man = room.men[index];
    if (!man) throw new XmlError('no such man');
    if (!man.exists || (man.controller !== -1 && man.client !== this.index)) return;
    man.char = tagValue(doc, 'char');
    if (man.char === null) throw new XmlError('no character');
    if (man.char === 'random') {
      man.random = true;
      this.pickCharacter(index);
    } else {
      man.random = false;
    }
    man.level = 1;
    const character = CHARACTERS.indexOf(man.char);
    if (character >= 0) {
      const level = man.controller === -1 ? room.computerLevel(character) : this.slot.levels[character];
      if (level > 0) {
        man.level = level;
        for (const other of room.men) if (other.exists && other.commander === index) other.level = level;
      }
      if (level <= 0 && man.controller >= 0 && man.client === this.index) {
        // A character this account has not unlocked: the original shuts the game out.
        this.kicked = true;
        this.leave();
        return;
      }
    }
    room.broadcastMen(0);
  }

  // i.d(int): a random character for a man: one the computer has, not taken by another man before it
  // or not random; the level to match. (The original gave a computer player one of the characters some
  // computer in the room has; here it may be any, the premium ones too, which players' accounts do not
  // have: see hf.js. Not Yaga, whom the game does not let anyone play.)
  pickCharacter(index) {
    const room = this.room;
    const man = room.men[index];
    const human = man.client !== -1;
    let owner = man.client;
    if (owner === -1 || !room.slots[owner].online) owner = this.index;
    const slot = room.slots[owner];
    const available = () => {
      const list = [];
      for (const name of CHARACTERS) {
        const character = CHARACTERS.indexOf(name);
        if (human ? slot.levels[character] > 0 : name !== 'yaga') list.push(name);
      }
      return list;
    };
    let list = available();
    room.men.forEach((other, k) => {
      if (!other.exists || (other.random && k >= index)) return;
      for (let n = 0; n < list.length; n += 1) if (list[n] === other.char) list.splice(n, 1);
    });
    if (!list.length) list = available();
    if (!list.length) throw new XmlError('no characters');
    man.char = list[this.room.nextInt(list.length)];
    const character = CHARACTERS.indexOf(man.char);
    man.level = 1;
    if (human) {
      if (slot.levels[character] > 0) man.level = slot.levels[character];
    } else {
      man.level = room.computerLevel(character);
    }
    for (const other of room.men) if (other.exists && other.commander === index) other.level = man.level;
  }

  // i.g(String): chat that starts with "/" is a command. Returns whether the line goes to everyone.
  command(text) {
    if (text === null) return true;
    const message = text.trim();
    if (!message || message[0] !== '/') return true;
    const words = message.split(/\s+/);
    const name = words[0].toLowerCase();
    const room = this.room;
    if (name === '/help') {
      if (words.length > 1) return true;
      this.notice('<b>Commands available</b>:  /quit, /clear, /me, /lat. <br />Type ? after a command to learn about it. E.g.: /quit ? ');
      return true;
    }
    if (name === '/quit' || name === '/exit') {
      if (words.length > 1 && words[1] === '?') {
        this.notice('<b>Quit</b>: You will exit the room.<br />Inputs: /quit, /exit.');
        return true;
      }
      this.kicked = true;
      this.leave();
      this.close();
      return true;
    }
    if (name === '/clear' || name === '/clean') {
      if (words.length > 1) {
        if (words[1] === '?') this.notice('<b>Clear</b>: Will clear all the chat on your screen.<br />Inputs: /clear, /clean.');
        return true;
      }
      for (let k = 0; k < 50; k += 1) this.notice('<br />');
      for (const slot of room.online()) {
        if (slot.connection !== this) slot.connection.send(`<chat><c>${this.index}</c><m><![CDATA[${words[0]}]]></m></chat>`);
      }
      return false;
    }
    if (name === '/me') {
      if (words.length > 1 && words[1] !== '?') {
        this.announce(`<font color="#CCCCFF"><i>*<b> ${this.name}</b> ${words.slice(1).join(' ')} </i></font>`);
        return false;
      }
      this.notice('<b>ME</b>: Sends the action to the chat (actions are written in the 3rd person, like /me jumps).');
      return true;
    }
    if (name === '/lat' || name === '/latency') {
      const help = 'It will need a latency number between 1 and 99 after the command. E.g.: /lat 7';
      if (words.length <= 1) this.notice(`<b>Latency</b>: ${help}`);
      else if (words[1] === '?') this.notice(`<b>Latency</b>: Changes your latency. ${help}<br />Inputs: /lat, /latency.`);
      else if (!/^[-+]?\d+$/.test(words[1])) this.notice(`<b>Latency</b>: ${help}`);
      else {
        const value = Number(words[1]);
        if (value <= 0) this.notice('<b>Latency</b>: Your latency must be between 1 and 99.');
        else if (value > 99) this.notice('Really?');
        else {
          const slot = this.slot;
          slot.latency = value + 1;
          slot.latencyTarget = slot.latency;
          this.notice(`<b>Latency</b>: Your latency has been changed to ${slot.latency - 1}.`);
          room.broadcastList(-1, -1);
        }
      }
      return true;
    }
    this.notice('Unrecognized command.');
    return true;
  }
}

module.exports = { HfRoom, HfConnection, parseXml, byTag, valueOf, XmlError, VERSION, CLIENTS, CHARACTERS };
