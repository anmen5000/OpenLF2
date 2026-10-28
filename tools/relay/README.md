# OpenLF2 relay

Browsers cannot open TCP sockets, so the web build sends its network byte stream over a WebSocket
to this relay. The relay pairs two players by a numeric room code and copies binary frames from
one to the other unchanged; the game's lockstep protocol runs on top. It needs Node.js 20 or newer
and one dependency ([`ws`](https://github.com/websockets/ws)).

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

It prints the relay address (`wss://203-0-113-5.sslip.io/relay`). Settings go before `bash`:
`DOMAIN=relay.example.com` uses your own domain, `ALLOWED_ORIGINS=https://you.github.io` limits who
may use the relay. Running it again updates the installation; `… | bash -s -- --uninstall` removes
it. The script embeds `server.js` and `package.json`; after changing either, run
`node update-installer.js` (the tests check that it was run).

Ports: with 80 and 443 free, Caddy takes both. When another web server (often Apache, `httpd`)
holds port 80, it is left alone and Caddy listens on 443 only, getting its certificate through the
TLS-ALPN challenge. When 443 is taken too, the script stops before changing anything and names the
sites that server runs, with the two commands to stop it if it is not needed.

Game data: the script also keeps a copy of the original LF2 v2.0a installer (freeware by Marti
Wong and Starsky Wong), downloaded from lf2.net, its Internet Archive snapshot or the Internet
Archive item and checked against the size and SHA-256 the game itself expects. The relay serves it
as `/lf2-installer.data`, and the game page downloads it from there before trying archive.org.
Download managers such as IDM take over the `.exe` from archive.org, which made the page fail;
they let this name through. A failed download here is not fatal: the page then uses archive.org.

The game page learns the relay address from the Online panel, an invite link, or the site's
default, which the WebAssembly workflow sets from its `relay` input (or the repository variable
`OPENLF2_RELAY`) through [`dist/pages/set-relay.py`](../../dist/pages/set-relay.py).

## How players use it

The Online panel above the game shows a room code, a **Copy invite link** button and the relay
address (the link carries both). The host chooses **Network Game > Host**. The friend opens the
link and chooses **Network Game > Connect**, leaving the address empty or typing the room code.
Either may be first; the game waits 30 seconds for the other.

Each frame waits for the other player's input, so the game slows down when a packet needs more
than one 33 ms frame to get from one player to the other: that is about half of each player's ping
to the relay, added together. Measured with the tests' simulated delay: 20 ms one way still plays
at full speed, 50 ms at about 63 %, 80 ms at about 40 %. Choose a relay close to both players.

## Settings (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT`, `HOST` | `8787`, `0.0.0.0` | Where to listen |
| `RELAY_PATH` | `/relay` | WebSocket path (`/` also works) |
| `ALLOWED_ORIGINS` | empty (any) | Comma-separated game page origins allowed to connect |
| `TRUST_PROXY` | off | Take the client address from `X-Forwarded-For` (behind a proxy) |
| `MAX_ROOMS` | `500` | Rooms open at once (0 = no limit) |
| `MAX_CONNECTIONS_PER_IP` | `8` | Connections per client address (0 = no limit) |
| `ROOM_WAIT_MS` | `120000` | How long one player may wait for the other |
| `MESSAGES_PER_SECOND`, `BYTES_PER_SECOND` | `240`, `131072` | Per-connection traffic limits (the game sends ~30 small packets a second) |
| `FORWARD_DELAY_MS` | `0` | Testing aid: delay every forwarded frame to feel a distant relay |
| `INSTALLER_FILE` | empty | The LF2 installer served at `/lf2-installer.data` (install-vps.sh sets it) |
| `INSTALLER_DOWNLOADS_PER_HOUR` | `20` | Downloads of that file per client address and hour (0 = no limit) |
| `QUIET` | off | No log lines |

`GET /healthz` answers `{"ok":true,"rooms":N,"clients":N,"installer":true|false}`; the Online
panel uses it to show whether the relay is reachable, its ping, and whether it keeps the game data.

## Protocol

`ws(s)://host/relay?role=host|join&room=<4-12 digits>`. The relay answers with JSON text frames
`{"t":"waiting","room":"…"}` and then `{"t":"paired"}`; after that, binary frames are forwarded
to the other player. Problems close the socket with a 4xxx code and an ASCII reason that the game
shows: 4000 bad request, 4001 origin not allowed, 4002 too many connections, 4003 server full,
4004 room taken, 4005 nobody joined in time, 4006 the other player left, 4007 too much traffic,
4008 the other player stopped reading, 4009 data before pairing.

## Tests

```sh
npm test   # Node.js 22 or newer
```

They cover the relay itself, `dist/web/online.js` driven through a port of
`scripts/base/game/network.lua` (handshake, random table and lockstep frames between two
simulated browsers), the JavaScript halves of the `EM_JS` functions in
`src/adapters/web/transport.cpp`, the frame rate against simulated delay, the game data copy
(served by the relay, preferred by `dist/web/installer-store.js`, set as a site default by
`set-relay.py`), and the functions of `install-vps.sh` (Node.js build choice, port modes, Caddy
configuration, game data download, embedded files).
