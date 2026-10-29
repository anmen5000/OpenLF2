# OpenLF2 relay

Browsers cannot open TCP sockets, so the web build plays network games through this relay over a
WebSocket. The relay runs rooms of 2 to 8 players named by a numeric code and keeps the beat: 30
times a second it sends every player one frame holding the newest input of everyone, and each game
runs exactly the frames it receives, so all stay in step and nobody waits for the slowest
connection. It also serves the original game data and mods (game packs) to game pages. It needs
Node.js 20 or newer and one dependency ([`ws`](https://github.com/websockets/ws)).

```sh
cd tools/relay
npm install
PORT=8787 ALLOWED_ORIGINS=https://you.github.io node server.js
```

The game page connects to `wss://<your relay host>/relay`. Pages served over `https://` may only
use `wss://`, so put the relay behind a TLS reverse proxy ([`Caddyfile.example`](Caddyfile.example))
or a tunnel. A `Dockerfile` is included.

## One command on a Linux server

[`install-vps.sh`](install-vps.sh) sets everything up on a server with systemd, CentOS 7 included:
Node.js (on glibc 2.17 a build from the Node.js project's unofficial builds, else Node.js 16 as a
fallback), the relay as the `lf2-relay` service on `127.0.0.1:8787`, and Caddy as `lf2-caddy` in
front of it with a Let's Encrypt certificate for `<server-ip>.sslip.io`. Downloads are checked
against their published checksums. Run as root:

```sh
curl -fsSL https://raw.githubusercontent.com/<you>/OpenLF2/main/tools/relay/install-vps.sh | bash
```

It prints the relay address (`wss://203-0-113-5.sslip.io/relay`), the address of the mod upload
page and its admin key. Settings go before `bash`: `DOMAIN=relay.example.com` uses your own domain,
`ALLOWED_ORIGINS=https://you.github.io` limits who may use the relay. Running it again updates the
installation and keeps the admin key; `… | bash -s -- --uninstall` removes it. The script embeds
`server.js`, `packs.js`, `hf.js`, `hf-room.js` and `package.json`; after changing any of them, run
`node update-installer.js` (the tests check that it was run).

Ports: with 80 and 443 free, Caddy takes both. When another web server (often Apache, `httpd`)
holds port 80, it is left alone and Caddy listens on 443 only, getting its certificate through the
TLS-ALPN challenge. When 443 is taken too, the script stops before changing anything and names the
sites that server runs, with the two commands to stop it if it is not needed.

### Sharing an Apache website

When Apache already serves an HTTPS site on the server and its owner agrees, the relay can live
under that site instead, with no Caddy and no port of its own:

```sh
curl -fsSL https://raw.githubusercontent.com/<you>/OpenLF2/main/tools/relay/install-vps.sh | APACHE_SITE=example.com bash
```

The relay is then `wss://example.com/lf2-relay/relay`. The script adds one file,
`/etc/httpd/conf.d/lf2-relay.conf`, with two `ProxyPass` lines from `/lf2-relay/` to the relay on
`127.0.0.1` (port 8787, or 8008 when SELinux is enforcing: Apache may connect there by default).
Nothing of the site's own files or configuration changes. Before anything is installed it checks
that Apache serves that name over HTTPS, that `mod_proxy`, `mod_proxy_http` and
`mod_proxy_wstunnel` are loaded, and where public DNS points the name. Then it runs `apachectl
configtest`, reloads Apache gracefully, and plays two short rounds through `wss://` via Apache,
then once more through the address public DNS gives. If any step fails — the site rewrites every
path itself, the name points at another server, Apache rejects the file — the file is removed,
Apache reloaded as before, and the relay stopped.

`disablereuse=On` is needed on Apache 2.4.6 (CentOS 7): without it, Apache keeps a finished
WebSocket's backend connection and sends the next player's handshake down it. A rerun keeps the
site, the port and `ALLOWED_ORIGINS`; `--uninstall` removes the file and reloads Apache.

Game data: the script also keeps a copy of the original LF2 v2.0a installer (freeware by Marti
Wong and Starsky Wong), downloaded from lf2.net, its Internet Archive snapshot or the Internet
Archive item and checked against the size and SHA-256 the game itself expects. The relay serves it
as `/lf2-installer.data`, and the game page downloads it from there before trying archive.org.
Download managers such as IDM take over the `.exe` from archive.org, which made the page fail;
they let this name through. A failed download here is not fatal: the page then uses archive.org.

Mods: `/admin` (beside the relay path, e.g. `https://example.com/lf2-relay/admin`) uploads the ZIP
file of a mod's game folder with the admin key (kept in `/opt/lf2-relay/relay.env`, readable by
root only). The relay keeps only the game folder (the one holding `data/data.txt`, its program and
pictures; not notes, recordings or older copies inside it), lists it at `/lf2-packs.json` and
serves it at `/lf2-packs/<id>.zip`. The game page offers it under **Game**; invite links carry the
choice, and everyone in a room must play the same game. Choosing another game while one runs
reloads the page into it.

The game page learns the relay address from the Online panel, an invite link, or the site's
default: `window.OPENLF2_RELAY` in `dist/pages/index.html`, or the WebAssembly workflow's `relay`
input through [`dist/pages/set-relay.py`](../../dist/pages/set-relay.py).

## How players use it

The Online panel above the game shows a room code, a **Copy invite link** button and the relay
address (the link carries both, and the chosen mod). The host chooses **Network Game > Host**: a
lobby lists the players as they come. Friends open the link and choose **Network Game > Connect**,
leaving the address empty or typing the room code; anyone may be first. The host presses
**START** once everyone is in (2 to 8 players; the 8 player slots are shared out between the
computers). The room waits up to 30 minutes for the start.

Nobody waits for anybody: the relay sends a frame every 33 1/3 ms with whatever input it has, so a
player far from the relay (or on a slow connection) only sees his own keys take effect about his
ping later. A player whose connection cannot keep up with the frames at all is let go, and the
others play on.

When anyone in the room has the hidden characters unlocked (the **Unlock hidden characters**
option, or LF2.NET typed), the whole room gets them; after leaving, each computer has its own
setting again.

## Hero Fighter

The game page also runs Hero Fighter v0.7+ (a Flash game by Marti Wong, free from herofighter.com) in
[Ruffle](https://ruffle.rs), and the relay stands in for the services the game was made for:
herofighter.com's accounts (closed to new players since 2016) and its room servers, which games
reach over TCP. The page points the game's addresses here (Ruffle's URL rewrites and socket proxy);
the game itself is not changed, except for two regular expressions Ruffle reads differently.

- The game file: upload `HFv0.7.zip` (or the `.exe` inside, or a `.swf`) at `/admin` like a mod.
  The relay keeps only the Flash movie inside the projector (`/lf2-packs/<id>.swf`, listed with
  `"kind":"flash","game":"herofighter"`), and the page downloads it from there when a player has
  no copy of his own.
- Accounts (`hf.js`): logging in with an e-mail address not seen before makes a new account (its
  name is the part before `@`); registering from the game works too. Every story is open from the
  start, and every character a player may have is at level 16, the game's highest (accounts made
  before follow this from their next login). The premium characters (Leo, Eason, Iczzy, Heater,
  Raye, Livermore), too strong for players, stay locked for them, and so does Yaga, whom the game
  keeps for itself; computer players may be any character but Yaga, at level 16. The game's offer to
  unlock the premium characters opens a page saying there is nothing to buy. Accounts live in
  `<PACKS_DIR>/hf/accounts.json` (or `HF_DIR`), with a scrypt hash of each password. A client
  address may make 20 accounts an hour and get 30 passwords wrong.
- Rooms (`hf-room.js`): a port of Room Server v0.7+, checked against the original (Java) by sending
  both the same messages: same lobby, same frames, same timing rules (lockstep, at most 4 computers
  and 6 fighters a room; a computer may have up to 3 players). `HF_ROOMS` rooms (4) show in the
  game's room list as "Phong 1", "Phong 2"… Each is a WebSocket on the relay path:
  `wss://<relay host>/relay?game=hf&room=<n>&build=<b>`, carrying the game's TCP stream as binary
  messages; `b` is the page's build (a hash of the movie and the Ruffle version), and a room takes
  only games of the build its first game had, since others would not play the same fight.
- Out of step: every 20 frames each game reports where it is in the random numbers all of them share
  (`<rpc>`). The original server passes these on and a game that finds another's different closes
  its connection ("Synchronization error"), which ends the match for everyone; the relay compares
  them itself and, when two differ, ends that fight only (the games go back to the room's menu,
  with a notice) so that the players can start another.

| Path | What |
| --- | --- |
| `/hf/ver.txt` | The version check (this version is the newest) |
| `/hf/s/v0.7/login.php`, `/hf/s/v0.7/lu.php` | Log in; save experience and story progress |
| `/hf/s/cap.php`, `reg.php`, `namechg_left.php`, `namechg.php`, `pwdchg.php`, `pwdret.php` | Registration code, register, change name or password, forgotten password (not by mail) |
| `/hf/s/premium` | The page the game's premium offer opens (nothing to buy) |
| `/hf/hf/rlg.php` | The room list, as the game reads it |
| `/hf/rooms.json` | The rooms for the page: `{"host":"hf.openlf2","rooms":[{"room":1,"port":8888,…}]}` |

Under Apache (`APACHE_SITE`) nothing changes: these are paths below `/lf2-relay/` like the others,
and the rooms use the relay's WebSocket path.

## Settings (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT`, `HOST` | `8787`, `0.0.0.0` | Where to listen |
| `RELAY_PATH` | `/relay` | WebSocket path (`/` also works) |
| `ALLOWED_ORIGINS` | empty (any) | Comma-separated game page origins allowed to connect |
| `TRUST_PROXY` | off | Take the client address from `X-Forwarded-For` (behind a proxy) |
| `MAX_ROOMS` | `500` | Rooms open at once (0 = no limit) |
| `MAX_CONNECTIONS_PER_IP` | `8` | Connections per client address (0 = no limit) |
| `ROOM_PLAYERS` | `8` | Most players in a room (2 to 8) |
| `TICK_MS` | `33.333` | The beat, in whole thirds of a millisecond |
| `LOBBY_WAIT_MS` | `1800000` | How long a room waits for its host to start |
| `ROOM_WAIT_MS` | `120000` | Protocol 1: how long one player may wait for the other |
| `MESSAGES_PER_SECOND`, `BYTES_PER_SECOND` | `240`, `131072` | Per-connection traffic limits (a game sends about 40 small packets a second) |
| `FORWARD_DELAY_MS` | `0` | Testing aid: delay every forwarded frame to feel a distant relay |
| `INSTALLER_FILE` | empty | The LF2 installer served at `/lf2-installer.data` (install-vps.sh sets it) |
| `INSTALLER_DOWNLOADS_PER_HOUR` | `20` | Downloads of that file per client address and hour (0 = no limit) |
| `PACKS_DIR` | empty | Where mods are kept (empty: no mods) |
| `ADMIN_KEY` | empty | The key for uploading mods at `/admin` (empty: no uploads) |
| `MAX_PACK_BYTES` | 1 GiB | Largest mod upload |
| `PACK_DOWNLOADS_PER_HOUR` | `20` | Mod downloads per client address and hour (0 = no limit) |
| `HF_ROOMS` | `4` | Hero Fighter rooms (1 to 20) |
| `HF_ROOM_DESCRIPTION` | `OpenLF2 relay` | The description of those rooms in the game's room list |
| `HF_DIR` | `<PACKS_DIR>/hf` | Where Hero Fighter accounts are kept (empty with no `PACKS_DIR`: in memory only) |
| `QUIET` | off | No log lines |

`GET /healthz` answers `{"ok":true,"rooms":N,"clients":N,"installer":…,"protocols":[1,2],"players":8,"packs":…,"hf":{"rooms":4,"players":N}}`;
the Online panel uses it to show whether the relay is reachable, its ping, whether it keeps the
game data, and whether it is new enough for the page.

## Protocol

Protocol 2, rooms: `ws(s)://host/relay?v=2&role=host|join&room=<4-12 digits>`. Binary messages are
`[kind u8][length u16 LE][payload]`: the game says hello (its version and mod, which must match the
room's, and its players' names), the host asks to start, every game answers ready, and then the
relay sends a frame every beat with each player's input; each game sends its input when it changes.
The welcome message gives the beat: whole milliseconds in its fourth byte, thirds of one in bits 1
and 2 of its flags. See `server.js` and `scripts/base/game/room.lua`.

Protocol 1, two players (older game pages): `ws(s)://host/relay?role=host|join&room=<code>`. The
relay answers with JSON text frames `{"t":"waiting","room":"…"}` and then `{"t":"paired"}`; after
that, binary frames are forwarded to the other player.

Problems close the socket with a 4xxx code and an ASCII reason that the game shows: 4000 bad
request, 4001 origin not allowed, 4002 too many connections, 4003 server full, 4004 room taken,
4005 nobody joined in time, 4006 the other player left, 4007 too much traffic, 4008 the other
player stopped reading, 4009 data before pairing, 4010 room full, 4011 game already started, 4012
another game version or mod, 4013 the host left, 4014 not started in time, 4015 unexpected message,
4016 connection too slow, 4017 room code in use by the other protocol.

## Tests

```sh
npm test   # Node.js 22 or newer; LUA=/path/to/lua5.2 for the room tests
```

They cover the relay itself and its rooms, `scripts/base/game/room.lua` run by a Lua interpreter
against the relay through `dist/web/online.js` (several games in one room, a distant player, a
stalled tab, a desync, a player leaving, frames started on display refreshes, hidden characters
one player came with), the older
two-player protocol through a port of `scripts/base/game/network.lua`, the JavaScript halves of
the `EM_JS` functions in `src/adapters/web/transport.cpp`, mods (what an upload keeps, the admin
API, serving them, Hero Fighter's movie taken from its projector), Hero Fighter's services (login
answers the game accepts, levels and locked characters, experience, registration, accounts kept
across restarts) and rooms (two games meet, start a VS match and get each other's frames; other
versions and builds are turned away; computer players' characters; a fight out of step), the game
data copy (served by the relay, preferred by
`dist/web/installer-store.js`, set as a site default by `set-relay.py`), and the functions of
`install-vps.sh` (Node.js build choice, port modes, Caddy configuration, game data download,
embedded files, the admin key, and for Apache mode: reading `httpd -S` and `httpd -M`, the port
choice under SELinux, public DNS answers, the Apache file, reruns).
