// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors
//
// Gemini plays along (package 96): Google's Gemini commands the computer players of an LF2 match.
//
// The game tells the page what the match looks like about once a second (scripts/base/game/smart_ai.lua,
// smart.page_kit.report, through globalThis.OpenLF2AiState: a line a fighter with its slot, team, HP, MP, place and
// state). Every few seconds this page sends that, with an instruction, to the relay (tools/relay/gemini.js), which
// asks Gemini with its owner's API key and hands the answer back; the page makes orders of it for the fighters it
// commands - whom to go for, a mode (attack, balanced, defend, kite, retreat), how much MP to keep - and leaves them in
// globalThis.OpenLF2AiPlan ("order <slot> <target> <mode> <MP>" lines) with a number, OpenLF2AiPlanSeq, that changes
// with them; the game reads them a few times a second (src/adapters/luajit/runtime.cpp) and XOI plays every frame by
// them. Orders that are not renewed lapse, and the game drops them at a new match: XOI then plays as ever.
// Only at the INSANE! and XOI levels, never in a network room nor in a replay (the game ignores them there).
//
// The panel "Gemini chơi cùng" goes above the game: on or off, whom Gemini commands (every computer, the players'
// allies or their opponents, or one team: Gemini's team against plain XOI's is the way to see what it adds), the
// access code of the relay's page /gemini, how often to ask, the language Gemini explains itself in, and a tally of
// the matches won and lost by the side Gemini commanded.
(function (root) {
  'use strict';

  const MODES = ['attack', 'balanced', 'defend', 'kite', 'retreat'];
  const MODE_WORDS = {
    vi: { attack: 'tấn công', balanced: 'cân bằng', defend: 'phòng thủ', kite: 'giữ xa', retreat: 'rút lui' },
    en: { attack: 'attack', balanced: 'balanced', defend: 'defend', kite: 'kite', retreat: 'retreat' },
  };
  const LANGUAGES = { vi: 'Vietnamese', en: 'English' };
  const WHO = ['all', 'allies', 'enemies', 'team1', 'team2', 'team3', 'team4'];
  const STORAGE = {
    on: 'openlf2-gemini-on', code: 'openlf2-gemini-code', who: 'openlf2-gemini-who', every: 'openlf2-gemini-every',
    lang: 'openlf2-gemini-lang', tally: 'openlf2-gemini-tally',
  };
  const FRESH_MS = 2500; // a report older than this: no match going on
  const OVER_MS = 4000; // no report for this long: the match is over
  const TIMEOUT_MS = 25000;
  const MAX_FIGHTERS = 40; // in what Gemini is told
  const TEAM_ENEMIES = 5; // a stage's enemies (base/game/constants teams)
  const TEAM_ALONE = 10; // and from 10, a fighter on no team (its slot + 10)

  // The answer's form (JSON schema; the relay hands it to Gemini when the model takes one).
  const SCHEMA = {
    type: 'object',
    properties: {
      orders: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            slot: { type: 'integer' },
            target: { type: 'integer' },
            mode: { type: 'string', enum: MODES },
            mp_reserve: { type: 'integer', minimum: 0, maximum: 500 },
          },
          required: ['slot', 'target', 'mode', 'mp_reserve'],
        },
      },
      say: { type: 'string' },
    },
    required: ['orders', 'say'],
  };

  function system(language) {
    return [
      'You are the battle commander of computer-controlled fighters in Little Fighter 2 (LF2), a 2.5D fighting game',
      '(it may be a mod, with other fighters). A frame-by-frame AI called XOI plays each fighter (its moves, combos,',
      'blocks and dodges); every few seconds you give each fighter you command a plan, and XOI plays by it until the next.',
      '',
      'For each fighter you command, choose:',
      '- "target": the slot of the enemy to go for, or -1 to let XOI choose (it takes the nearest or most open enemy).',
      '- "mode": "attack" (presses in and starts moves sooner; takes risks), "balanced" (XOI\'s own play), "defend" (waits',
      '  for openings, keeps a little further, starts only safe moves), "kite" (keeps far away: for fighters with ranged',
      '  moves, or to wait out a strong enemy), "retreat" (stays away and avoids fighting: to win time, regain MP, or',
      '  survive when nearly beaten).',
      '- "mp_reserve": MP (0-500) to keep: no special move that would leave less. 0 lets XOI spend MP freely; keep some',
      '  (for example 150-300) to save it for a strong move, or to rebuild it while kiting or retreating.',
      '',
      'Facts: HP and MP go up to 500 (max HP can be lower); MP refills slowly by itself. x is left-right (0 to the stage',
      'width) and z is depth: blows land only when two fighters are close in z (about 15 apart) as well as in x. y below 0',
      'is in the air. States such as injured, falling, lying, dizzy, frozen, broken_defend or caught mean a fighter is',
      'open or down; defending blocks blows from the front. Fighters with the same team are allies; HP 0 is out.',
      '',
      'Think about the whole fight: several allies on one enemy (the weakest, or the most dangerous); no weak ally alone',
      'against several; pull back a fighter that is losing badly; press an enemy low on HP or out of MP; kite with archers',
      'and energy-ball users against close fighters. Change plans when the fight changes, not every time for no reason.',
      '',
      'Answer with JSON only: {"orders":[{"slot":<slot>,"target":<slot or -1>,"mode":"<mode>","mp_reserve":<0-500>}],',
      `"say":"<one short sentence, under 100 characters, in ${LANGUAGES[language] || 'English'}, about your plan>"},`,
      'with one order for each fighter you command.',
    ].join('\n');
  }

  // The game's lines (smart.page_kit.report): "frame <n> width <w>", then
  // "f <slot> <team> <human> <commandable> <hp> <max hp> <mp> <x> <z> <y> <L|R> <state> <weapon> <id> <name>
  // <a cheap shot 0|1> <least MP of a far-reaching move, -1: none> <least MP of a special, -1: none>".
  function parseReport(text) {
    if (typeof text !== 'string') return null;
    const lines = text.split('\n');
    const head = /^frame (-?\d+) width (\d+)/.exec(lines[0] || '');
    if (!head) return null;
    const report = { frame: Number(head[1]), width: Number(head[2]), fighters: [] };
    for (const line of lines.slice(1)) {
      const found = new RegExp('^f (\\d+) (-?\\d+) ([01]) ([01]) (-?\\d+) (-?\\d+) (-?\\d+) (-?\\d+) (-?\\d+) (-?\\d+) ([LR]) (\\S+) ([01]) '
        + '(-?\\d+) (\\S+)(?: ([01]) (-?\\d+) (-?\\d+))?').exec(line);
      if (!found) continue;
      const number = (at) => Number(found[at]);
      const fighter = {
        slot: number(1), team: number(2), human: found[3] === '1', commandable: found[4] === '1',
        hp: number(5), maxHp: number(6), mp: number(7), x: number(8), z: number(9), y: number(10),
        facing: found[11], state: found[12].slice(0, 30), weapon: found[13] === '1', id: number(14),
        name: found[15].replace(/[^\p{L}\p{N}_.\-+]/gu, '').slice(0, 30) || '?',
      };
      if (found[16] !== undefined) Object.assign(fighter, { shot: found[16] === '1', rangedMp: number(17), specialMp: number(18) });
      report.fighters.push(fighter);
    }
    return report;
  }

  const hostile = (a, b) => a.team !== b.team;

  // The computer players Gemini commands, by the panel's choice.
  function chooseSlots(report, who) {
    if (!report) return [];
    const humanTeams = new Set(report.fighters.filter((f) => f.human).map((f) => f.team));
    return report.fighters.filter((f) => {
      if (!f.commandable || f.human) return false;
      if (who === 'allies') return f.team < TEAM_ALONE && humanTeams.has(f.team);
      if (who === 'enemies') return !humanTeams.has(f.team);
      const team = /^team([1-4])$/.exec(who || '');
      if (team) return f.team === Number(team[1]);
      return true;
    }).map((f) => f.slot);
  }

  function teamWords(team) {
    if (team >= TEAM_ALONE) return 'on no team';
    if (team === TEAM_ENEMIES) return 'stage enemies';
    return `team ${team}`;
  }

  function signed(value) {
    return value > 0 ? `+${value}` : String(value);
  }

  // A fighter's moves as the game learned them (nothing said when the game did not tell).
  function movesWords(f) {
    if (f.shot === undefined) return '';
    const parts = [];
    if (f.shot) parts.push('a cheap ranged shot');
    if (f.rangedMp >= 0) parts.push(f.rangedMp > 0 ? `ranged moves from ${f.rangedMp} MP` : 'ranged moves that cost no MP');
    else if (!f.shot) parts.push('no ranged moves');
    if (f.specialMp > 0) parts.push(`specials from ${f.specialMp} MP`);
    return `; moves: ${parts.join(', ')}`;
  }

  // What Gemini is asked: the instruction, and the match as it is (with what changed since the last orders).
  function buildPrompt({ report, before, lastOrders, slots, language, secondsAgo }) {
    const mine = new Set(slots);
    const earlier = new Map(((before && before.fighters) || []).map((f) => [f.slot, f]));
    const fighters = report.fighters.slice().sort((a, b) => (mine.has(b.slot) - mine.has(a.slot)) || ((b.hp > 0) - (a.hp > 0)))
      .slice(0, MAX_FIGHTERS).sort((a, b) => a.slot - b.slot);
    const lines = [`Time ${Math.round(report.frame / 30)} s into the match (frame ${report.frame}); stage width ${report.width}.`, 'Fighters:'];
    for (const f of fighters) {
      const who = f.human ? 'human player' : (f.commandable ? 'computer' : 'computer (its own AI)');
      const head = `- slot ${f.slot} "${f.name}" (id ${f.id}), ${teamWords(f.team)}, ${who}${mine.has(f.slot) ? ' - YOU COMMAND IT' : ''}`;
      if (f.hp <= 0) {
        lines.push(`${head}: out (HP 0)`);
        continue;
      }
      const old = earlier.get(f.slot);
      const hp = `HP ${f.hp}/${f.maxHp}${old && old.hp !== f.hp ? ` (${signed(f.hp - old.hp)} since your last orders)` : ''}`;
      const mp = `MP ${f.mp}${old && old.mp !== f.mp ? ` (${signed(f.mp - old.mp)})` : ''}`;
      const where = `x ${f.x}, z ${f.z}, ${f.y < 0 ? `in the air (y ${f.y})` : 'on the ground'}`;
      lines.push(`${head}: ${hp}, ${mp}, ${where}, ${f.state.replace(/_/g, ' ')}, facing ${f.facing === 'R' ? 'right' : 'left'}`
        + `${f.weapon ? ', holding a weapon' : ''}${movesWords(f)}`);
    }
    const bySlot = new Map(report.fighters.map((f) => [f.slot, f]));
    const distances = [];
    for (const slot of slots) {
      const self = bySlot.get(slot);
      if (!self || self.hp <= 0) continue;
      const enemies = report.fighters.filter((f) => f.hp > 0 && hostile(self, f))
        .map((f) => ({ slot: f.slot, dx: Math.abs(f.x - self.x), dz: Math.abs(f.z - self.z) }))
        .sort((a, b) => (a.dx + 2 * a.dz) - (b.dx + 2 * b.dz)).slice(0, 6);
      if (enemies.length) distances.push(`slot ${slot} to ${enemies.map((e) => `${e.slot}: ${e.dx} in x, ${e.dz} in z`).join('; ')}`);
    }
    if (distances.length) lines.push('Distances to the enemies:', ...distances.map((line) => `- ${line}`));
    if (lastOrders && lastOrders.size) {
      const given = [...lastOrders].map(([slot, order]) => `slot ${slot}: target ${order.target}, ${order.mode}, keep ${order.reserve} MP`);
      lines.push(`Your last orders (${secondsAgo} s ago): ${given.join('; ')}.`);
    }
    lines.push(`Give one order for each of these slots: ${slots.join(', ')}.`);
    return { system: system(language), prompt: lines.join('\n'), schema: SCHEMA };
  }

  // Gemini's text: JSON (perhaps in a ``` block), orders for the slots commanded only, each checked.
  function parseAnswer(text, report, slots) {
    let data = null;
    const raw = String(text || '');
    try { data = JSON.parse(raw); } catch (error) {
      const start = raw.indexOf('{');
      const end = raw.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try { data = JSON.parse(raw.slice(start, end + 1)); } catch (again) { data = null; }
      }
    }
    if (!data || typeof data !== 'object') return null;
    const bySlot = new Map(report.fighters.map((f) => [f.slot, f]));
    const mine = new Set(slots);
    const orders = new Map();
    for (const order of Array.isArray(data.orders) ? data.orders : []) {
      if (!order || typeof order !== 'object') continue;
      const slot = Number(order.slot);
      const mode = String(order.mode || '').toLowerCase();
      if (!mine.has(slot) || orders.has(slot) || !MODES.includes(mode)) continue;
      let target = Number(order.target);
      const enemy = bySlot.get(target);
      if (!Number.isInteger(target) || !enemy || enemy.hp <= 0 || !hostile(bySlot.get(slot), enemy)) target = -1;
      const reserve = Math.max(0, Math.min(500, Math.round(Number(order.mp_reserve)) || 0));
      orders.set(slot, { target, mode, reserve });
    }
    const say = typeof data.say === 'string' ? data.say.replace(/\s+/g, ' ').trim().slice(0, 160) : '';
    return { orders, say };
  }

  // The orders as the game reads them (smart.page_kit.parse).
  function planText(orders) {
    return [...orders].map(([slot, order]) => `order ${slot} ${order.target} ${order.mode} ${order.reserve}`).join('\n');
  }

  // Who won a match, by its last report: 'won' when only teams Gemini commanded in are standing, 'lost' when none
  // of them is, null when it is not clear (both standing: left before the end, a stage).
  function outcome(report, geminiTeams) {
    if (!report || !geminiTeams || !geminiTeams.size) return null;
    const teams = new Set(report.fighters.map((f) => f.team));
    const standing = new Set(report.fighters.filter((f) => f.hp > 0).map((f) => f.team));
    if (!standing.size) return null;
    const ours = [...standing].filter((team) => geminiTeams.has(team)).length;
    const others = [...teams].some((team) => !geminiTeams.has(team));
    if (ours === standing.size && others) return 'won';
    if (ours === 0) return 'lost';
    return null;
  }

  // The page's side, without the panel: options in, the game's reports in, questions to the relay out, orders out.
  class Commander {
    constructor({ fetch, now = () => Date.now(), url = () => '', publish = () => {}, onChange = () => {}, tally } = {}) {
      this.fetch = fetch;
      this.now = now;
      this.url = url;
      this.publish = publish;
      this.onChange = onChange;
      this.options = { on: false, code: '', who: 'all', every: 4, language: 'vi' };
      this.tally = tally || { won: 0, lost: 0 };
      this.stats = { asked: 0, ok: 0, failed: 0, totalMs: 0, lastMs: 0 };
      this.say = '';
      this.error = '';
      this.report = null; // the newest
      this.reportAt = 0;
      this.askedAt = 0;
      this.matchStart();
    }

    matchStart() {
      this.history = []; // [time, report] of this match
      this.orders = new Map(); // in force: slot -> {target, mode, reserve}
      this.ordered = null; // the report the orders were given on, and when
      this.orderedAt = 0;
      this.okAt = 0;
      this.nextAt = 0;
      this.teams = new Set(); // the teams of the fighters Gemini commanded this match
      this.scored = false;
      this.answered = false; // Gemini gave this match orders
      this.setPlan(new Map());
    }

    setOptions(options) {
      const before = this.options;
      this.options = { ...before, ...options };
      this.options.every = Math.max(2, Math.min(30, Number(this.options.every) || 4));
      if (!WHO.includes(this.options.who)) this.options.who = 'all';
      if (!LANGUAGES[this.options.language]) this.options.language = 'vi';
      if (!this.options.on && before.on) this.setPlan(new Map());
      if (this.options.who !== before.who) {
        this.setPlan(new Map());
        this.nextAt = this.askedAt + 1600; // at once, but not sooner than the relay takes a call from one page
      }
      this.onChange();
    }

    setPlan(orders) {
      this.orders = orders;
      this.publish(planText(orders));
    }

    // A report from the game (OpenLF2AiState).
    state(text) {
      const report = parseReport(text);
      if (!report) return;
      const time = this.now();
      // A new match counts its frames from 0 again. (A pause, a hidden tab, only stops the reports for a while.)
      if (this.report && report.frame < this.report.frame) {
        this.score(true);
        this.matchStart();
      }
      this.report = report;
      this.reportAt = time;
      this.history.push([time, report]);
      while (this.history.length > 40) this.history.shift();
    }

    // The match's result for the tally, once: at its end (`final`), or when the reports stop on a clear result.
    score(final) {
      if (this.scored || !this.answered) return;
      const result = outcome(this.report, this.teams);
      if (!result && !final) return;
      this.scored = true;
      if (result === 'won') this.tally.won += 1;
      if (result === 'lost') this.tally.lost += 1;
      if (result) this.onChange('tally');
    }

    active() {
      return Boolean(this.report) && this.now() - this.reportAt <= FRESH_MS;
    }

    slots() {
      return chooseSlots(this.report, this.options.who);
    }

    // What the panel says.
    status() {
      const o = this.options;
      if (!o.on) return { kind: 'off', text: 'Đang tắt.' };
      if (!this.url()) return { kind: 'bad', text: 'Chưa có relay: điền ô Relay ở khung Online play.' };
      if (!o.code) return { kind: 'bad', text: 'Dán mã Gemini (trang /gemini của relay) vào ô Mã Gemini.' };
      if (!this.active()) {
        return { kind: 'wait', text: 'Chờ trận đấu… (máy phải ở mức INSANE! hoặc XOI; Gemini không chơi trong phòng mạng hay khi xem lại trận).' };
      }
      const slots = this.slots();
      if (!slots.length) return { kind: 'wait', text: 'Trận này không có máy XOI nào để Gemini chỉ huy theo lựa chọn ở trên.' };
      if (this.inflight) return { kind: 'run', text: `Đang hỏi Gemini cho ${slots.length} máy…` };
      if (this.error) return { kind: 'bad', text: this.error };
      const wait = Math.max(0, Math.ceil((this.nextAt - this.now()) / 1000));
      return { kind: 'ok', text: `Gemini chỉ huy ${this.orders.size} máy${wait ? `, hỏi lại sau ${wait} giây` : ''}.` };
    }

    // Every quarter of a second.
    async tick() {
      const time = this.now();
      if (this.report && time - this.reportAt > OVER_MS) {
        this.score(false);
        if (this.orders.size) this.setPlan(new Map());
      }
      // Orders that were not renewed lapse: XOI plays as ever.
      if (this.orders.size && time - this.okAt > Math.max(15000, 3 * this.options.every * 1000)) this.setPlan(new Map());
      if (!this.options.on || !this.options.code || this.inflight || time < this.nextAt || !this.active()) return;
      const url = this.url();
      const slots = this.slots();
      if (!url || !slots.length) return;
      await this.ask(url, slots);
    }

    async ask(url, slots) {
      const report = this.report;
      const started = this.now();
      const before = this.ordered;
      const request = buildPrompt({ report, before, lastOrders: this.orders, slots, language: this.options.language,
        secondsAgo: Math.round((started - this.orderedAt) / 1000) });
      this.inflight = true;
      this.askedAt = started;
      this.stats.asked += 1;
      this.onChange();
      const match = this.history;
      let delay = this.options.every * 1000;
      let retry = 0; // the relay's word on when to ask again
      try {
        const controller = typeof AbortController === 'function' ? new AbortController() : null;
        const timer = controller ? setTimeout(() => controller.abort(), TIMEOUT_MS) : 0;
        let response;
        try {
          response = await this.fetch(url, {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'x-gemini-code': this.options.code },
            body: JSON.stringify(request),
            signal: controller ? controller.signal : undefined,
          });
        } finally {
          clearTimeout(timer);
        }
        let data = {};
        try { data = await response.json(); } catch (error) { data = {}; }
        if (!response.ok) {
          retry = Math.min(Number(data.retryMs) || 0, 120000);
          throw new Error(data.error || `Relay trả lời HTTP ${response.status}.`);
        }
        const answer = parseAnswer(data.text, report, slots);
        if (!answer) throw new Error('Gemini trả lời không đúng dạng JSON.');
        if (match !== this.history) return; // a new match began meanwhile
        const orders = new Map(this.orders);
        for (const [slot, order] of answer.orders) orders.set(slot, order);
        for (const slot of [...orders.keys()]) if (!slots.includes(slot)) orders.delete(slot);
        this.setPlan(orders);
        const bySlot = new Map(report.fighters.map((f) => [f.slot, f]));
        for (const slot of answer.orders.keys()) if (bySlot.has(slot)) this.teams.add(bySlot.get(slot).team);
        if (answer.orders.size) this.answered = true;
        this.say = answer.say;
        this.ordered = report;
        this.orderedAt = started;
        this.okAt = this.now();
        this.error = '';
        this.stats.ok += 1;
        this.stats.lastMs = Number(data.ms) || (this.now() - started);
        this.stats.totalMs += this.stats.lastMs;
      } catch (error) {
        this.stats.failed += 1;
        this.error = error && error.name === 'AbortError' ? 'Relay không trả lời sau 25 giây.'
          : `Lỗi: ${(error && error.message) || error}`;
        delay = retry > 0 ? Math.max(1000, retry) : Math.max(delay, 5000);
      } finally {
        this.inflight = false;
        this.nextAt = started + delay;
        this.onChange();
      }
    }

    // The orders in force, in words.
    describeOrders() {
      const words = MODE_WORDS[this.options.language] || MODE_WORDS.en;
      const names = new Map(((this.report && this.report.fighters) || []).map((f) => [f.slot, f.name]));
      const name = (slot) => `${names.get(slot) || '?'} (${slot})`;
      const vi = this.options.language === 'vi';
      return [...this.orders].map(([slot, order]) => {
        const target = order.target >= 0 ? (vi ? `đánh ${name(order.target)}` : `on ${name(order.target)}`) : (vi ? 'XOI tự chọn' : 'XOI picks');
        const keep = order.reserve ? (vi ? `, giữ ${order.reserve} MP` : `, keep ${order.reserve} MP`) : '';
        return `${name(slot)}: ${words[order.mode]}, ${target}${keep}`;
      });
    }
  }

  const api = { Commander, parseReport, chooseSlots, buildPrompt, parseAnswer, planText, outcome, system, SCHEMA, MODES, WHO };
  if (typeof module === 'object' && module.exports) {
    module.exports = api; // tests
    return;
  }

  // ---- The page --------------------------------------------------------------------------------------------------

  const storage = {
    get(name) { try { return root.localStorage.getItem(name); } catch (error) { return null; } },
    set(name, value) { try { if (value === null) root.localStorage.removeItem(name); else root.localStorage.setItem(name, value); } catch (error) { /* private */ } },
  };
  let tally = { won: 0, lost: 0 };
  try {
    const kept = JSON.parse(storage.get(STORAGE.tally) || 'null');
    if (kept && Number.isInteger(kept.won) && Number.isInteger(kept.lost)) tally = { won: kept.won, lost: kept.lost };
  } catch (error) { /* none */ }

  root.OpenLF2AiPlan = '';
  root.OpenLF2AiPlanSeq = 0;
  let panel = null;
  let render = () => {};
  const commander = new Commander({
    fetch: (...args) => root.fetch(...args),
    url: () => (root.OpenLF2Online && typeof root.OpenLF2Online.relayFile === 'function' ? root.OpenLF2Online.relayFile('gemini/api/plan') : ''),
    publish: (text) => {
      if (text === root.OpenLF2AiPlan) return;
      root.OpenLF2AiPlan = text;
      root.OpenLF2AiPlanSeq = (root.OpenLF2AiPlanSeq + 1) % 1000000000;
    },
    onChange: (what) => {
      if (what === 'tally') storage.set(STORAGE.tally, JSON.stringify(commander.tally));
      render();
    },
    tally,
  });
  commander.setOptions({
    on: storage.get(STORAGE.on) === '1',
    code: storage.get(STORAGE.code) || '',
    who: storage.get(STORAGE.who) || 'all',
    every: Number(storage.get(STORAGE.every)) || 4,
    language: storage.get(STORAGE.lang) || 'vi',
  });
  root.OpenLF2AiState = (text) => commander.state(text);
  root.OpenLF2Gemini = commander;

  function build() {
    const document = root.document;
    const stage = document.getElementById('stage') || document.getElementById('canvas');
    if (!stage || !stage.parentNode || document.getElementById('gemini')) return;
    panel = document.createElement('details');
    panel.id = 'gemini';
    panel.innerHTML = `
      <style>
        #gemini { box-sizing: border-box; margin: .75rem 0; padding: .55rem .8rem; border: 1px solid rgba(127, 127, 127, .4);
          border-radius: 8px; font-size: .9rem; }
        #gemini[hidden], #gemini [hidden] { display: none !important; }
        #gemini summary { cursor: pointer; font-weight: 600; color: inherit; font-size: .95rem; }
        #gemini .row { display: flex; flex-wrap: wrap; align-items: center; gap: .45rem .9rem; margin: .45rem 0; }
        #gemini label { display: flex; align-items: center; gap: .4rem; min-width: 0; }
        #gemini input, #gemini select { font: inherit; padding: .3rem .45rem; min-width: 0; box-sizing: border-box; }
        #gemini-code { width: 11rem; letter-spacing: .05em; }
        #gemini-every { width: 4.5rem; }
        #gemini .help { margin: .35rem 0 0; opacity: .8; font-size: .85rem; }
        #gemini-status[data-kind="ok"] { color: #5fd38d; }
        #gemini-status[data-kind="bad"] { color: #ff8a80; }
        #gemini-status[data-kind="run"] { color: #ffd166; }
        #gemini-say { font-style: italic; }
        #gemini-orders { margin: .2rem 0 0; padding-left: 1.2rem; }
        #gemini button { padding: .25rem .6rem; cursor: pointer; font: inherit; }
      </style>
      <summary>Gemini chơi cùng <span style="font-weight:400;opacity:.75">— Gemini commands the computer players (thử nghiệm)</span></summary>
      <div class="row">
        <label><input type="checkbox" id="gemini-on"> Bật: Gemini chỉ huy máy</label>
        <label>Chỉ huy <select id="gemini-who">
          <option value="all">mọi máy XOI</option>
          <option value="allies">máy cùng đội với người chơi</option>
          <option value="enemies">máy đối thủ của người chơi</option>
          <option value="team1">máy đội 1</option><option value="team2">máy đội 2</option>
          <option value="team3">máy đội 3</option><option value="team4">máy đội 4</option>
        </select></label>
      </div>
      <div class="row">
        <label>Mã Gemini <input id="gemini-code" type="password" autocomplete="off" spellcheck="false" placeholder="từ trang /gemini"></label>
        <label>Hỏi mỗi <input id="gemini-every" type="number" min="2" max="30" step="1"> giây</label>
        <label>Gemini nói <select id="gemini-lang"><option value="vi">tiếng Việt</option><option value="en">English</option></select></label>
      </div>
      <div class="row"><span id="gemini-status" role="status"></span></div>
      <div class="row" id="gemini-say-row" hidden><span>Gemini: <span id="gemini-say"></span></span></div>
      <ul id="gemini-orders" hidden></ul>
      <div class="row"><span id="gemini-stats"></span> <button type="button" id="gemini-reset" hidden>Đếm lại</button></div>
      <p class="help">Mỗi vài giây trang gửi tình hình trận đấu (máu, mana, vị trí, trạng thái từng nhân vật) qua relay cho Gemini;
        Gemini chọn cho mỗi máy: đánh ai, chế độ (tấn công, cân bằng, phòng thủ, giữ xa, rút lui) và giữ bao nhiêu MP; XOI vẫn điều
        khiển từng khung hình theo lệnh đó. Muốn xem Gemini có giúp nhiều không: chọn <b>máy đội 1</b>, cho máy đội 1 đấu máy đội 2
        (VS mode, Computer Level XOI) rồi xem phe Gemini thắng bao nhiêu trận. Chủ relay lấy mã ở trang <b>/gemini</b> của relay.
        Chỉ ở mức INSANE! và XOI; không có trong phòng mạng và khi xem lại trận.</p>`;
    stage.parentNode.insertBefore(panel, stage);
    const canvas = document.getElementById('canvas');
    const widest = canvas && root.getComputedStyle ? root.getComputedStyle(canvas).maxWidth : 'none';
    if (widest && widest !== 'none') panel.style.maxWidth = widest;
    // SDL listens for keys on the window; keep typing in these fields out of the game.
    for (const type of ['keydown', 'keyup', 'keypress']) panel.addEventListener(type, (event) => event.stopPropagation());

    const $ = (id) => panel.querySelector('#' + id);
    const on = $('gemini-on');
    const who = $('gemini-who');
    const code = $('gemini-code');
    const every = $('gemini-every');
    const lang = $('gemini-lang');
    on.checked = commander.options.on;
    who.value = commander.options.who;
    code.value = commander.options.code;
    every.value = String(commander.options.every);
    lang.value = commander.options.language;
    if (commander.options.on) panel.open = true;
    on.addEventListener('change', () => {
      storage.set(STORAGE.on, on.checked ? '1' : null);
      commander.setOptions({ on: on.checked });
    });
    who.addEventListener('change', () => {
      storage.set(STORAGE.who, who.value);
      commander.setOptions({ who: who.value });
    });
    code.addEventListener('change', () => {
      const value = code.value.trim();
      storage.set(STORAGE.code, value || null);
      commander.setOptions({ code: value });
    });
    every.addEventListener('change', () => {
      commander.setOptions({ every: Number(every.value) });
      every.value = String(commander.options.every);
      storage.set(STORAGE.every, every.value);
    });
    lang.addEventListener('change', () => {
      storage.set(STORAGE.lang, lang.value);
      commander.setOptions({ language: lang.value });
    });
    $('gemini-reset').addEventListener('click', () => {
      commander.tally.won = 0;
      commander.tally.lost = 0;
      storage.set(STORAGE.tally, null);
      render();
    });

    render = () => {
      const status = commander.status();
      const line = $('gemini-status');
      line.textContent = status.text;
      line.dataset.kind = status.kind;
      $('gemini-say').textContent = commander.say;
      $('gemini-say-row').hidden = !commander.say || !commander.options.on;
      const list = $('gemini-orders');
      const orders = commander.options.on ? commander.describeOrders() : [];
      list.replaceChildren(...orders.map((text) => {
        const item = document.createElement('li');
        item.textContent = text;
        return item;
      }));
      list.hidden = !orders.length;
      const s = commander.stats;
      const parts = [];
      if (s.asked) {
        parts.push(`Đã hỏi ${s.asked} lần${s.failed ? ` (${s.failed} lỗi)` : ''}`
          + `${s.ok ? `, trả lời trung bình ${(s.totalMs / s.ok / 1000).toFixed(1).replace('.', ',')} giây` : ''}.`);
      }
      const t = commander.tally;
      if (t.won || t.lost) parts.push(`Phe Gemini chỉ huy: thắng ${t.won}, thua ${t.lost} trận.`);
      $('gemini-stats').textContent = parts.join(' ');
      $('gemini-reset').hidden = !(t.won || t.lost);
    };
    render();
  }

  // Hero Fighter (the page's other game) has no XOI: the panel steps aside.
  function gameIsHeroFighter() {
    const select = root.document && root.document.getElementById('game');
    return Boolean(select && select.value === 'hf');
  }

  let shown = 0;
  setInterval(() => {
    commander.tick().catch(() => {});
    if (panel) panel.hidden = gameIsHeroFighter();
    // The status line counts down and notices the end of a match: a light refresh twice a second.
    shown = (shown + 1) % 2;
    if (!shown) render();
  }, 250);

  if (root.document) {
    if (root.document.readyState === 'loading') root.document.addEventListener('DOMContentLoaded', build);
    else build();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
