#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# Installs the OpenLF2 online relay on a Linux server with systemd (CentOS 7 and newer, Rocky,
# Alma, Ubuntu, Debian): Node.js, the relay as a service, and Caddy in front of it for HTTPS with
# a free certificate for <your-ip>.sslip.io (or your own domain). Run it as root:
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/OpenLF2/main/tools/relay/install-vps.sh | bash
#
# Optional settings, put before "bash":   ... | DOMAIN=relay.example.com bash
#   DOMAIN            your own domain, already pointing at this server (default: <ip>.sslip.io)
#   ALLOWED_ORIGINS   only these game pages may use the relay, e.g. https://you.github.io
# Remove it again:   ... | bash -s -- --uninstall
#
# A web server that already runs on the machine is left alone: when another program (often
# Apache, "httpd") holds port 80, Caddy listens on port 443 only and gets its certificate through
# the TLS-ALPN challenge there. When port 443 is taken too, the script stops and explains.
#
# Sharing an existing Apache (httpd) website instead, when its owner agrees:
#   curl -fsSL .../install-vps.sh | APACHE_SITE=example.com bash
# puts the relay behind that site at https://example.com/lf2-relay/ (WebSocket: .../lf2-relay/relay).
# No Caddy then: one file, /etc/httpd/conf.d/lf2-relay.conf, with ProxyPass lines to 127.0.0.1; it is
# checked with "apachectl configtest", applied with a graceful reload, verified through Apache (HTTP,
# and two short games over the WebSocket) and at the address public DNS gives for the site, and
# removed again, with Apache reloaded as before and the relay stopped, if any step fails.
#
# It also keeps a copy of the original LF2 v2.0a installer (freeware, by Marti Wong and Starsky
# Wong; checked by SHA-256 as the game does), which the relay serves to the game page as
# /lf2-installer.data: players then need no download manager workaround, and the page falls back to
# archive.org when the copy is missing.
#
# Mods (game packs: a mod's whole game folder as a ZIP file) are uploaded on the relay's page
# /admin with the admin key this script makes (kept in /opt/lf2-relay/relay.env, shown at the end),
# and kept in /opt/lf2-relay/data/packs. With the same key, the page /hoc sets the XOI kit's
# reinforcement learning on many machines (hoc.js): the relay hands fighters out to the machines and
# keeps the small files they send back (in /opt/lf2-relay/data/packs/hoc); the machines do the learning.
# And the page /gemini keeps the owner's Gemini API key (in /opt/lf2-relay/data/packs/gemini, readable by the
# relay alone) for the game page's "Gemini plays along" (gemini.js): players use the access code it shows.
#
# Everything lives in /opt/lf2-relay plus two services, lf2-relay and lf2-caddy. The relay's own
# files are embedded below (update-installer.js writes them), so this file is all a server needs.
# Messages are Vietnamese without diacritics, so that every terminal shows them.
set -euo pipefail

INSTALLER_VERSION=18
CADDY_MODE=full # check_ports decides: full, tls-only, or apache (no Caddy)
HAVE_DATA=0     # install_game_data decides
PREFIX=${LF2_PREFIX:-/opt/lf2-relay}
APACHE_SITE=${APACHE_SITE:-}
APACHE_PATH=/lf2-relay
APACHE_CONF=${LF2_APACHE_CONF:-/etc/httpd/conf.d/lf2-relay.conf}
APACHE_SERVICE=${LF2_APACHE_SERVICE:-httpd}
HTTPD=${LF2_HTTPD:-httpd}
APACHECTL=${LF2_APACHECTL:-apachectl}
APACHE_ADDRESS=127.0.0.1 # apache_preflight decides, as the next three
SERVER_IP=""
SITE_ADDRESSES=""
SITE_HERE=0
SAVED_RELAY_PORT=""
SYSTEMD_DIR=${LF2_SYSTEMD_DIR:-/etc/systemd/system}
SYSTEMCTL=${LF2_SYSTEMCTL:-systemctl}
RELAY_PORT=${RELAY_PORT:-8787}
NODE_MAJOR=22
NODE_FALLBACK=v16.20.2 # the last official Node.js build that runs on glibc 2.17 (CentOS 7)
CADDY_VERSION=2.11.7
NODE_DIST=${NODE_DIST:-https://nodejs.org/dist}
NODE_UNOFFICIAL=${NODE_UNOFFICIAL:-https://unofficial-builds.nodejs.org/download/release}
CADDY_RELEASES=${CADDY_RELEASES:-https://github.com/caddyserver/caddy/releases/download}
# The LF2 v2.0a installer: the game's own checks (installer-store.js, the Flatpak manifest) use this size
# and SHA-256. Sources in order: lf2.net, its Internet Archive snapshot, the Internet Archive item.
LF2_DATA_SIZE=${LF2_DATA_SIZE:-29586263}
LF2_DATA_SHA256=${LF2_DATA_SHA256:-540c485547e234b0d09595f54d067aafd7176092c308aca61868f3cbc03030e1}
LF2_DATA_URLS=${LF2_DATA_URLS:-https://lf2.net/LF2_v2.0a.exe https://web.archive.org/web/20260921121026id_/https://lf2.net/LF2_v2.0a.exe https://archive.org/download/little-fighter-2_202404/Little%20Fighter%202.rar/Little%20Fighter%202%2FLF2Setup.exe}

say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() {
	printf '\n[LOI] %s\n' "$*" >&2
	exit 1
}

fetch() { # url file
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 -o "$2" "$1"
}

# True when version $1 >= version $2 (dotted numbers).
version_ge() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

glibc_version() {
	if [ -n "${GLIBC_VERSION:-}" ]; then
		printf '%s\n' "$GLIBC_VERSION"
		return
	fi
	ldd --version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | tail -n 1 || true
}

# Reads the unofficial builds' index.json on stdin; prints the newest vMAJOR.x.y with a
# linux-x64-glibc-217 build (the index lists newest first, one object per release).
latest_glibc217() {
	tr -d '\n' | grep -oE "\"version\":\"v$1\.[0-9]+\.[0-9]+\"[^}]*\"linux-x64-glibc-217\"" |
		head -n 1 | grep -oE "v$1\.[0-9]+\.[0-9]+" | head -n 1 || true
}

# 203.0.113.5 -> 203-0-113-5.sslip.io (a public DNS name for that address, with no sign-up).
sslip_name() {
	printf '%s.sslip.io\n' "$(printf '%s' "$1" | tr . -)"
}

is_ipv4() {
	[[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

public_ip() {
	if [ -n "${PUBLIC_IP:-}" ]; then
		printf '%s\n' "$PUBLIC_IP"
		return
	fi
	local url ip
	for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
		ip=$(curl -4 -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
		if is_ipv4 "$ip"; then
			printf '%s\n' "$ip"
			return 0
		fi
	done
	return 0 # nothing printed: the caller explains
}

# Reads `ss -ltnp` on stdin; prints the process listening on TCP port $1 (empty when free).
port_owner() {
	awk -v port=":$1" '
		NR > 1 && substr($4, length($4) - length(port) + 1) == port {
			match($0, /users:\(\("[^"]*"/)
			owner = RSTART ? substr($0, RSTART + 9, RLENGTH - 10) : "unknown"
			print owner
			exit
		}'
}

# Picks "<base url> <file name>" of the Node.js build to install, newest first.
node_candidates() {
	local glibc=$1 arch=$2 version
	if [ "$arch" = x64 ] && [ -n "$glibc" ] && ! version_ge "$glibc" 2.28; then
		# Official Node.js 18+ needs glibc 2.28; CentOS 7 has 2.17. The Node.js project's
		# unofficial builds include ones made for glibc 2.17.
		version=$(curl -fsSL --max-time 60 "$NODE_UNOFFICIAL/index.json" 2>/dev/null | latest_glibc217 "$NODE_MAJOR" || true)
		if [ -n "$version" ]; then
			printf '%s %s\n' "$NODE_UNOFFICIAL/$version" "node-$version-linux-x64-glibc-217"
		fi
		printf '%s %s\n' "$NODE_DIST/$NODE_FALLBACK" "node-$NODE_FALLBACK-linux-x64"
	else
		printf '%s %s\n' "$NODE_DIST/latest-v$NODE_MAJOR.x" "LATEST"
	fi
}

# Downloads, checks (SHA-256) and unpacks one Node.js build into $PREFIX/node.
install_node_from() { # base name
	local base=$1 name=$2 work archive unpack
	work=$(mktemp -d)
	fetch "$base/SHASUMS256.txt" "$work/SHASUMS256.txt" || return 1
	if [ "$name" = LATEST ]; then
		name=$(grep -oE "node-v$NODE_MAJOR\.[0-9]+\.[0-9]+-linux-$NODE_ARCH\.tar\.gz" "$work/SHASUMS256.txt" | head -n 1 || true)
		name=${name%.tar.gz}
		[ -n "$name" ] || return 1
	fi
	# .tar.gz where there is one; .tar.xz needs the xz tool.
	if grep -q " $name.tar.gz\$" "$work/SHASUMS256.txt"; then
		archive="$name.tar.gz" unpack=-xzf
	elif grep -q " $name.tar.xz\$" "$work/SHASUMS256.txt" && command -v xz >/dev/null 2>&1; then
		archive="$name.tar.xz" unpack=-xJf
	else
		return 1
	fi
	info "Tai $archive"
	fetch "$base/$archive" "$work/$archive" || return 1
	(cd "$work" && grep " $archive\$" SHASUMS256.txt | sha256sum -c - >/dev/null) || return 1
	rm -rf "$PREFIX/node.new"
	mkdir -p "$PREFIX/node.new"
	tar "$unpack" "$work/$archive" -C "$PREFIX/node.new" --strip-components=1 || return 1
	rm -rf "$work"
	"$PREFIX/node.new/bin/node" --version >/dev/null 2>&1 || return 1
	rm -rf "$PREFIX/node"
	mv "$PREFIX/node.new" "$PREFIX/node"
}

install_node() {
	local glibc line
	glibc=$(glibc_version)
	info "glibc ${glibc:-(khong ro)}, kien truc $NODE_ARCH"
	while read -r line; do
		[ -n "$line" ] || continue
		# shellcheck disable=SC2086 # two words: base and name
		if install_node_from $line; then
			info "Node.js $("$PREFIX/node/bin/node" --version) da san sang"
			return 0
		fi
		info "Ban nay khong dung duoc, thu ban khac..."
	done < <(node_candidates "$glibc" "$NODE_ARCH")
	fail "Khong cai duoc Node.js. Gui thong bao nay cho nguoi huong dan ban."
}

install_app() {
	mkdir -p "$PREFIX/app"
	write_server_js "$PREFIX/app/server.js"
	write_packs_js "$PREFIX/app/packs.js"
	write_hf_js "$PREFIX/app/hf.js"
	write_hf_room_js "$PREFIX/app/hf-room.js"
	write_hoc_js "$PREFIX/app/hoc.js"
	write_gemini_js "$PREFIX/app/gemini.js"
	write_package_json "$PREFIX/app/package.json"
	if [ -n "${LF2_NODE_MODULES_FROM:-}" ]; then
		rm -rf "$PREFIX/app/node_modules"
		cp -r "$LF2_NODE_MODULES_FROM" "$PREFIX/app/node_modules"
	else
		(cd "$PREFIX/app" && PATH="$PREFIX/node/bin:$PATH" npm install --omit=dev --no-audit --no-fund --loglevel=error </dev/null) ||
			fail "npm install loi. Kiem tra VPS co vao duoc Internet khong."
	fi
	chmod -R a+rX "$PREFIX/app"
}

data_ok() { # file
	[ -f "$1" ] && [ "$(stat -c %s "$1")" = "$LF2_DATA_SIZE" ] &&
		[ "$(sha256sum "$1" | cut -d ' ' -f 1)" = "$LF2_DATA_SHA256" ]
}

# Keeps the LF2 installer in $PREFIX/data for the relay to serve; HAVE_DATA=1 when it is there.
# Never fatal: without it the game page downloads from archive.org as before.
install_game_data() {
	local target=$PREFIX/data/lf2-installer.data url work
	HAVE_DATA=0
	mkdir -p "$PREFIX/data"
	if data_ok "$target"; then
		HAVE_DATA=1
		info "Du lieu game da co san"
		return 0
	fi
	work=$(mktemp -d)
	for url in $LF2_DATA_URLS; do
		info "Tai tu $(printf '%s' "$url" | cut -d / -f 3) ..."
		if fetch "$url" "$work/lf2" 2>/dev/null && data_ok "$work/lf2"; then
			install -m 0644 "$work/lf2" "$target"
			HAVE_DATA=1
			break
		fi
		info "  khong duoc, thu nguon khac"
		rm -f "$work/lf2"
	done
	rm -rf "$work"
	if [ "$HAVE_DATA" = 1 ]; then
		info "Du lieu game da luu tren VPS"
	else
		info "Chua tai duoc du lieu game; trang game se tai tu archive.org nhu truoc."
	fi
	chmod a+rx "$PREFIX/data"
}

install_caddy() {
	local work archive
	work=$(mktemp -d)
	archive="caddy_${CADDY_VERSION}_linux_${CADDY_ARCH}.tar.gz"
	info "Tai $archive"
	fetch "$CADDY_RELEASES/v$CADDY_VERSION/$archive" "$work/$archive" || fail "Khong tai duoc Caddy."
	fetch "$CADDY_RELEASES/v$CADDY_VERSION/caddy_${CADDY_VERSION}_checksums.txt" "$work/checksums.txt" ||
		fail "Khong tai duoc checksum cua Caddy."
	(cd "$work" && grep " $archive\$" checksums.txt | sha512sum -c - >/dev/null) || fail "Caddy tai ve bi loi (checksum sai)."
	tar -xzf "$work/$archive" -C "$work" caddy
	mkdir -p "$PREFIX/bin"
	install -m 0755 "$work/caddy" "$PREFIX/bin/caddy"
	rm -rf "$work"
	CADDY_USER=lf2caddy
	if ! command -v setcap >/dev/null 2>&1 || ! setcap 'cap_net_bind_service=+ep' "$PREFIX/bin/caddy" 2>/dev/null; then
		CADDY_USER=root # without setcap, only root may listen on ports 80 and 443
	fi
	mkdir -p "$PREFIX/caddy-data" "$PREFIX/caddy-config"
	[ "$CADDY_USER" = root ] || chown -R lf2caddy: "$PREFIX/caddy-data" "$PREFIX/caddy-config"
	write_caddyfile "$PREFIX/Caddyfile"
	info "Caddy $CADDY_VERSION da san sang (chay bang tai khoan $CADDY_USER)"
}

# Caddy's configuration for $DOMAIN in $CADDY_MODE. "full": ports 80 (redirects, HTTP challenge)
# and 443. "tls-only": port 443 alone, the certificate through the TLS-ALPN challenge, so another
# web server keeps port 80. Certificates come from Let's Encrypt; the tests set LF2_ACME_DIR and
# LF2_ACME_ROOT to use a local test CA instead.
write_caddyfile() { # file
	{
		printf '# Written by install-vps.sh (%s). HTTPS for the OpenLF2 relay; the certificate renews by itself.\n' "$CADDY_MODE"
		printf '{\n\tadmin off\n'
		[ "$CADDY_MODE" != tls-only ] || printf '\tauto_https disable_redirects\n'
		printf '}\n\n%s {\n\ttls {\n\t\tissuer acme {\n' "$DOMAIN"
		[ -z "${LF2_ACME_DIR:-}" ] || printf '\t\t\tdir %s\n' "$LF2_ACME_DIR"
		[ -z "${LF2_ACME_ROOT:-}" ] || printf '\t\t\ttrusted_roots %s\n' "$LF2_ACME_ROOT"
		[ "$CADDY_MODE" != tls-only ] || printf '\t\t\tdisable_http_challenge\n'
		printf '\t\t}\n\t}\n\treverse_proxy 127.0.0.1:%s\n}\n' "$RELAY_PORT"
	} >"$1"
}

ensure_user() { # name home
	if ! id -u "$1" >/dev/null 2>&1; then
		useradd --system --no-create-home --home-dir "$2" --shell /sbin/nologin "$1"
	fi
}

write_units() {
	write_relay_unit
	[ "$CADDY_MODE" = apache ] || write_caddy_unit
}

# The key for uploading mods at /admin: the one an earlier run made (or ADMIN_KEY=...), else a new one.
# It lives in $PREFIX/relay.env, readable by root only (the service reads it before dropping to lf2relay).
keep_admin_key() {
	if [ -z "${ADMIN_KEY:-}" ] && [ -f "$PREFIX/relay.env" ]; then
		ADMIN_KEY=$(sed -n 's/^ADMIN_KEY=//p' "$PREFIX/relay.env" | head -n 1 || true)
	fi
	if [ -z "${ADMIN_KEY:-}" ]; then
		ADMIN_KEY=$(od -An -N 12 -tx1 /dev/urandom | tr -d ' \n')
	fi
	case "$ADMIN_KEY" in
	*[!A-Za-z0-9._-]* | ?????? | ????? | ???? | ??? | ?? | ?) fail "ADMIN_KEY chi gom chu, so, dau . _ - va dai it nhat 7 ky tu." ;;
	esac
}

write_relay_env() {
	(umask 077 && printf 'ADMIN_KEY=%s\n' "$ADMIN_KEY" >"$PREFIX/relay.env")
	install -d -m 755 "$PREFIX/data"
	install -d -m 755 -o lf2relay -g lf2relay "$PREFIX/data/packs" 2>/dev/null || install -d -m 755 "$PREFIX/data/packs"
	chown lf2relay "$PREFIX/data/packs" 2>/dev/null || true
}

# A rerun keeps the game pages an earlier run allowed, unless it says otherwise (ALLOWED_ORIGINS= clears).
keep_allowed_origins() {
	[ -z "${ALLOWED_ORIGINS+set}" ] || return 0
	ALLOWED_ORIGINS=$(sed -n 's/^Environment="ALLOWED_ORIGINS=\(.*\)"$/\1/p' "$SYSTEMD_DIR/lf2-relay.service" 2>/dev/null | head -n 1 || true)
}

write_relay_unit() {
	cat >"$SYSTEMD_DIR/lf2-relay.service" <<EOF
# Written by install-vps.sh
[Unit]
Description=OpenLF2 online relay
After=network-online.target
Wants=network-online.target

[Service]
User=lf2relay
WorkingDirectory=$PREFIX/app
Environment="PORT=$RELAY_PORT"
Environment="HOST=127.0.0.1"
Environment="TRUST_PROXY=1"
Environment="ALLOWED_ORIGINS=${ALLOWED_ORIGINS:-}"
Environment="INSTALLER_FILE=$PREFIX/data/lf2-installer.data"
Environment="PACKS_DIR=$PREFIX/data/packs"
EnvironmentFile=-$PREFIX/relay.env
ExecStart=$PREFIX/node/bin/node $PREFIX/app/server.js
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_caddy_unit() {
	cat >"$SYSTEMD_DIR/lf2-caddy.service" <<EOF
# Written by install-vps.sh
[Unit]
Description=HTTPS for the OpenLF2 relay (Caddy)
After=network-online.target lf2-relay.service
Wants=network-online.target

[Service]
User=$CADDY_USER
Environment="HOME=$PREFIX/caddy-data"
Environment="XDG_DATA_HOME=$PREFIX/caddy-data"
Environment="XDG_CONFIG_HOME=$PREFIX/caddy-config"
ExecStart=$PREFIX/bin/caddy run --config $PREFIX/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# The ports Caddy needs in $CADDY_MODE, as words for messages.
caddy_ports() {
	if [ "$CADDY_MODE" = tls-only ]; then printf 'cong 443'; else printf 'cong 80 va 443'; fi
}

open_firewall() {
	if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		if [ "$CADDY_MODE" = tls-only ]; then
			firewall-cmd --quiet --permanent --add-service=https
		else
			firewall-cmd --quiet --permanent --add-service=http --add-service=https
		fi
		firewall-cmd --quiet --reload
		info "Da mo $(caddy_ports) tren firewalld"
	elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		[ "$CADDY_MODE" = tls-only ] || ufw allow 80/tcp >/dev/null
		ufw allow 443/tcp >/dev/null
		info "Da mo $(caddy_ports) tren ufw"
	else
		info "Khong thay firewalld/ufw dang chay, bo qua"
	fi
}

wait_for() { # url seconds [extra curl options]
	local url=$1 seconds=$2 waited=0
	shift 2
	while [ "$waited" -lt "$seconds" ]; do
		if curl -fsS --max-time 5 "$@" -o /dev/null "$url" 2>/dev/null; then
			return 0
		fi
		sleep 3
		waited=$((waited + 3))
	done
	return 1
}

# The program holding TCP port $2 in the `ss -ltnp` output $1, unless it is this relay's own Caddy
# from an earlier run. Empty when the port is free.
other_owner() { # ss-output port
	local owner
	owner=$(printf '%s\n' "$1" | port_owner "$2" || true)
	if [ "$owner" = caddy ] && "$SYSTEMCTL" is-active --quiet lf2-caddy.service 2>/dev/null; then
		owner=""
	fi
	printf '%s' "$owner"
}

# Sets CADDY_MODE: "apache" with APACHE_SITE (behind that Apache website, no Caddy); otherwise "full"
# when ports 80 and 443 are free, "tls-only" when another program keeps port 80 (it is left alone).
# Stops with an explanation when port 443 is taken.
check_ports() {
	local listening="" owner80="" owner443=""
	CADDY_MODE=full
	if command -v ss >/dev/null 2>&1; then
		listening=$(ss -ltnp 2>/dev/null || true)
		owner80=$(other_owner "$listening" 80)
		owner443=$(other_owner "$listening" 443)
	fi
	if [ -n "$APACHE_SITE" ]; then
		APACHE_SITE=$(normalize_site "$APACHE_SITE")
		if ! [[ $APACHE_SITE =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || is_ipv4 "$APACHE_SITE"; then
			fail "APACHE_SITE=\"$APACHE_SITE\" khong phai ten mien (vi du dung: APACHE_SITE=example.com). Chua co gi bi thay doi."
		fi
		if [ -n "$listening" ] && [ "$owner443" != httpd ]; then
			fail "APACHE_SITE chi dung khi Apache (httpd) dang chay website o cong 443; o day cong 443 ${owner443:-chua co ai dung}. Chua co gi bi thay doi."
		fi
		CADDY_MODE=apache
		info "Di chung website https://$APACHE_SITE cua Apache (httpd), khong dong toi cac file cua website"
		return 0
	fi
	[ -z "$owner443" ] || port_443_taken "$owner443"
	if [ -n "$owner80" ]; then
		CADDY_MODE=tls-only
		info "Cong 80 dang do \"$owner80\" dung: giu nguyen, khong dong cham toi."
		info "Relay se chi dung cong 443."
	fi
}

port_443_taken() { # owner
	local example=""
	{
		printf '\n[LOI] Cong 443 (HTTPS) dang duoc chuong trinh "%s" dung.\n' "$1"
		printf '      Relay can rieng cong 443, nen chua cai duoc. Chua co gi bi thay doi.\n'
		if [ "$1" = httpd ] && command -v "$HTTPD" >/dev/null 2>&1; then
			printf '      Website ma httpd dang chay:\n'
			"$HTTPD" -S 2>/dev/null | grep -oE '(namevhost|default server) [^ ]+' | awk '{print "         " $NF}' | sort -u || true
			example=$("$HTTPD" -S 2>/dev/null | apache_https_names | grep -vE '^[0-9.]+$' | head -n 1 || true)
			printf '      - Neu chu website dong y cho relay di chung website (qua Apache, khong sua\n'
			printf '        file nao cua website): chay lai lenh cai dat voi APACHE_SITE=<ten website>\n'
			printf '        dat truoc chu bash, vi du:  ... | APACHE_SITE=%s bash\n' "${example:-ten-website.com}"
		fi
		case "$1" in
		httpd | nginx | apache2)
			printf '      - Neu ban KHONG dung website nay, tat no bang 2 lenh:\n'
			printf '            systemctl stop %s\n' "$1"
			printf '            systemctl disable %s\n' "$1"
			printf '        roi chay lai lenh cai dat.\n'
			printf '      - Neu ban CO dung: gui toan bo thong bao nay cho nguoi huong dan ban.\n'
			;;
		*) printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n' ;;
		esac
	} >&2
	exit 1
}

# --- Behind an existing Apache website (CADDY_MODE=apache) -------------------------------------------

# True when Apache serves HTTPS for $1, reading `httpd -S` on stdin (names, aliases, default servers).
apache_serves_https() { # site
	awk -v site="$1" '
		$1 ~ /:443$/ { in443 = 1; if ($2 == site) found = 1; next }
		$1 ~ /:[0-9]+$/ { in443 = 0; next }
		in443 && $1 == "port" && $2 == "443" && $3 == "namevhost" && $4 == site { found = 1 }
		in443 && $1 == "default" && $2 == "server" && $3 == site { found = 1 }
		in443 && $1 == "alias" && $2 == site { found = 1 }
		END { exit found ? 0 : 1 }'
}

# The names Apache serves over HTTPS, from `httpd -S` on stdin.
apache_https_names() {
	awk '
		$1 ~ /:443$/ { in443 = 1; if ($2 != "is") print $2; next }
		$1 ~ /:[0-9]+$/ { in443 = 0; next }
		in443 && $1 == "port" && $3 == "namevhost" { print $4 }
		in443 && $1 == "alias" { print $2 }' | sort -u
}

# True when `httpd -M` on stdin lists module $1.
apache_has_module() { # module
	grep -qE "^[[:space:]]*$1[[:space:]]"
}

# Where to reach Apache's port 443 from this machine, from `ss -ltn(p)` output: 127.0.0.1 when it
# listens on every address (the usual "Listen 443"), else the first IPv4 address it listens on.
apache_listen_address() { # ss-output
	printf '%s\n' "$1" | awk '
		NR > 1 && $4 ~ /:443$/ {
			address = substr($4, 1, length($4) - 4)
			if (address == "*" || address == "0.0.0.0" || address == "::" || address == ":::" || address == "[::]") { wildcard = 1 }
			else if (first == "" && address ~ /^[0-9.]+$/) { first = address }
		}
		END { print (wildcard || first == "") ? "127.0.0.1" : first }'
}

# A free local port for the relay behind Apache, from `ss -ltnp` output. With SELinux enforcing,
# Apache may connect only to ports labelled http_port_t; 8008 and 8009 are, and are rarely used.
pick_relay_port() { # ss-output
	local candidates="8787 8008 8009 18787" port
	[ "$(getenforce 2>/dev/null || true)" != Enforcing ] || candidates="8008 8009"
	for port in $candidates; do
		if [ -z "$(printf '%s\n' "$1" | port_owner "$port" || true)" ]; then
			printf '%s' "$port"
			return 0
		fi
	done
	return 1
}

# "https://Example.com/x" -> "example.com": the site name as Apache knows it, however it was pasted.
normalize_site() { # site
	local site=${1#*://}
	site=${site%%/*}
	site=${site%%:*}
	printf '%s' "$site" | tr 'A-Z' 'a-z'
}

# The IPv4 addresses that players' browsers get for name $1, one per line (none when it has none):
# from public DNS over HTTPS (Google, then Cloudflare), else dig, else this machine's resolver.
site_addresses() { # name
	local answer address
	if [ -n "${LF2_SITE_ADDRESSES+set}" ]; then # tests
		for address in $LF2_SITE_ADDRESSES; do printf '%s\n' "$address"; done
		return 0
	fi
	answer=$(curl -fsS --max-time 10 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null ||
		curl -fsS --max-time 10 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null ||
		true)
	case "$answer" in
	*'"Status"'*)
		printf '%s' "$answer" | grep -oE '"data": *"[0-9]+(\.[0-9]+){3}"' | grep -oE '[0-9]+(\.[0-9]+){3}' | sort -u || true
		return 0
		;;
	esac
	if command -v dig >/dev/null 2>&1; then
		dig +short A "$1" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true
		return 0
	fi
	getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true
}

# This machine's IPv4 addresses, one per line: its public one ($1) and its network interfaces'.
own_addresses() { # public-ip
	{
		[ -z "$1" ] || printf '%s\n' "$1"
		if command -v ip >/dev/null 2>&1; then
			ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d / -f 1
		else
			hostname -I 2>/dev/null | tr ' ' '\n'
		fi
	} | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true
}

# Reads the site and port a previous installation in Apache mode used, so a rerun keeps them.
load_apache_state() {
	local key value
	[ -f "$PREFIX/apache-site" ] || return 0
	while IFS='=' read -r key value; do
		case "$key" in
		APACHE_SITE) [ -n "$APACHE_SITE" ] || APACHE_SITE=$value ;;
		RELAY_PORT) SAVED_RELAY_PORT=$value ;;
		esac
	done <"$PREFIX/apache-site"
}

save_apache_state() {
	printf 'APACHE_SITE=%s\nRELAY_PORT=%s\n' "$APACHE_SITE" "$RELAY_PORT" >"$PREFIX/apache-site"
}

# Checks everything before anything is installed: the site, Apache's modules, our file, a port.
apache_preflight() {
	local vhosts modules module listening owner own address
	command -v "$HTTPD" >/dev/null 2>&1 || fail "Khong tim thay Apache (lenh $HTTPD) tren may nay. Chua co gi bi thay doi."
	[ -d "$(dirname "$APACHE_CONF")" ] || fail "Khong thay thu muc cau hinh $(dirname "$APACHE_CONF") cua Apache. Chua co gi bi thay doi."
	vhosts=$("$HTTPD" -S 2>/dev/null || true)
	if ! printf '%s\n' "$vhosts" | apache_serves_https "$APACHE_SITE"; then
		{
			printf '\n[LOI] Apache khong co website HTTPS ten "%s". Chua co gi bi thay doi.\n' "$APACHE_SITE"
			printf '      Cac website HTTPS cua Apache:\n'
			printf '%s\n' "$vhosts" | apache_https_names | sed 's/^/         /'
			printf '      Chay lai lenh voi APACHE_SITE= mot ten o tren (ten mien, khong phai so IP).\n'
		} >&2
		exit 1
	fi
	modules=$("$HTTPD" -M 2>/dev/null || true)
	for module in proxy_module proxy_http_module proxy_wstunnel_module; do
		printf '%s\n' "$modules" | apache_has_module "$module" ||
			fail "Apache chua bat module $module, ma relay can. Chua co gi bi thay doi. Gui thong bao nay cho nguoi huong dan ban."
	done
	if [ -f "$APACHE_CONF" ] && ! grep -q 'Written by install-vps.sh' "$APACHE_CONF"; then
		fail "Da co file $APACHE_CONF khong do trinh cai dat nay tao; khong ghi de. Chua co gi bi thay doi."
	fi
	listening=$(ss -ltnp 2>/dev/null || true)
	if [ -n "$SAVED_RELAY_PORT" ]; then
		owner=$(printf '%s\n' "$listening" | port_owner "$SAVED_RELAY_PORT" || true)
		case "$owner" in "" | node) RELAY_PORT=$SAVED_RELAY_PORT ;; *) SAVED_RELAY_PORT="" ;; esac
	fi
	if [ -z "$SAVED_RELAY_PORT" ]; then
		RELAY_PORT=$(pick_relay_port "$listening") ||
			fail "Khong con cong trong cho relay (8008, 8009...). Chua co gi bi thay doi. Gui thong bao nay cho nguoi huong dan ban."
	fi
	APACHE_ADDRESS=$(apache_listen_address "$listening")
	# Where players' browsers will go for the site: this server, or (through a CDN) maybe not.
	SERVER_IP=$(public_ip || true)
	SITE_ADDRESSES=$(site_addresses "$APACHE_SITE" | tr '\n' ' ' | sed 's/ *$//')
	[ -n "$SITE_ADDRESSES" ] ||
		fail "Ten mien $APACHE_SITE chua tro ve dia chi IP nao (khong tim thay ban ghi DNS). Chua co gi bi thay doi."
	own=$(own_addresses "$SERVER_IP")
	SITE_HERE=0
	for address in $SITE_ADDRESSES; do
		if printf '%s\n' "$own" | grep -qxF "$address"; then SITE_HERE=1; fi
	done
	if [ "$SITE_HERE" = 1 ]; then
		info "Ten mien $APACHE_SITE tro ve VPS nay ($SITE_ADDRESSES)"
	else
		info "Ten mien $APACHE_SITE tro toi $SITE_ADDRESSES, khong phai IP cua VPS nay (${SERVER_IP:-khong ro});"
		info "co the qua CDN (vi du Cloudflare): se kiem tra lai sau khi noi relay."
	fi
	info "Relay se o 127.0.0.1:$RELAY_PORT, Apache chuyen https://$APACHE_SITE$APACHE_PATH/ toi do"
}

apache_conf_text() {
	cat <<EOF
# Written by install-vps.sh for the OpenLF2 relay (service lf2-relay).
# https://$APACHE_SITE$APACHE_PATH/ (the same path on this server's other sites too) goes to the relay on
# 127.0.0.1:$RELAY_PORT; its WebSocket is $APACHE_PATH/relay. Nothing else of the sites changes.
# To undo: delete this file and run "systemctl reload $APACHE_SERVICE", or run the installer with --uninstall.
# disablereuse: Apache 2.4.6 (CentOS 7) would otherwise keep a finished WebSocket's connection open and
# send the next player's handshake down it.
<IfModule mod_proxy.c>
	ProxyPass "$APACHE_PATH/relay" "ws://127.0.0.1:$RELAY_PORT/relay" retry=0 disablereuse=On
	ProxyPass "$APACHE_PATH/" "http://127.0.0.1:$RELAY_PORT/" retry=0 disablereuse=On
	ProxyPassReverse "$APACHE_PATH/" "http://127.0.0.1:$RELAY_PORT/"
</IfModule>
EOF
}

# Plays two short rounds through the relay's WebSocket at $1 (wss://site/path/relay), reached at
# address $2 (the TLS name stays the URL's), as a page from origin $3 (may be empty), in rooms $4 and
# $4+1: a host and a guest pair, bytes pass both ways, the guest leaves and the host is told. Two rounds,
# because a web server that reuses a finished WebSocket's connection fails only the second. Prints what
# went wrong, if anything.
ws_check() { # url address origin room
	NODE_PATH="$PREFIX/app/node_modules" "$PREFIX/node/bin/node" -e '
		const WebSocket = require("ws");
		const [base, address, origin, firstRoom] = process.argv.slice(1);
		const family = address.includes(":") ? 6 : 4;
		const lookup = (host, options, callback) =>
			options && options.all ? callback(null, [{ address, family }]) : callback(null, address, family);
		const options = { lookup, rejectUnauthorized: false, handshakeTimeout: 10000 };
		if (origin) options.origin = origin;
		const fail = (problem) => { console.log(problem); process.exit(1); };
		setTimeout(() => fail("timeout"), 40000);
		function open(role, room) {
			const ws = new WebSocket(base + "?role=" + role + "&room=" + room, options);
			const got = { texts: [], bytes: 0, close: "" };
			ws.on("message", (data, binary) => {
				if (binary) { got.bytes += data.length; return; }
				let message = {};
				try { message = JSON.parse(String(data)); } catch (error) { message.t = "? " + String(data).slice(0, 60); }
				got.texts.push(message.t);
			});
			ws.on("unexpected-response", (request, response) => fail(role + ": HTTP " + response.statusCode));
			ws.on("close", (code, reason) => { got.close = code + " " + String(reason || ""); });
			ws.on("error", (error) => fail(role + ": " + error.message));
			return { ws, got };
		}
		const until = (problem, test) => new Promise((resolve) => {
			const started = Date.now();
			const tick = () => (test() ? resolve() : Date.now() - started > 8000 ? fail(problem) : setTimeout(tick, 20));
			tick();
		});
		async function round(room) {
			const host = open("host", room);
			await until("host: no answer", () => host.got.texts.length || host.got.close);
			if (host.got.texts[0] !== "waiting") fail("host: " + (host.got.close ? "closed " + host.got.close : host.got.texts[0]));
			const guest = open("join", room);
			await until("no pairing", () => host.got.texts.includes("paired") && guest.got.texts.includes("paired"));
			host.ws.send(Buffer.from([1, 2, 3, 4]));
			guest.ws.send(Buffer.from([5, 6, 7]));
			await until("bytes did not pass", () => guest.got.bytes === 4 && host.got.bytes === 3);
			guest.ws.close();
			await until("host not told that the guest left", () => host.got.close);
			if (host.got.close.indexOf("4006") !== 0) fail("host closed " + host.got.close);
		}
		(async () => {
			await round(firstRoom);
			await round(String(Number(firstRoom) + 1));
			process.exit(0);
		})();
	' "$1" "$2" "${3:-}" "$4"
}

# Checks the relay through Apache (HTTP, then WebSocket). Prints what went wrong, if anything.
apache_verify() {
	local base="https://$APACHE_SITE$APACHE_PATH" body="" waited=0 room reason origin
	# -k: the check is about the route through Apache; the site's own certificate is not our business,
	# and an old CA bundle on this machine may not know its issuer.
	while [ "$waited" -lt 20 ]; do
		body=$(curl -sS --max-time 5 -k --noproxy '*' --resolve "$APACHE_SITE:443:$APACHE_ADDRESS" "$base/healthz" 2>&1 || true)
		case "$body" in *'"ok":true'*) break ;; esac
		sleep 2
		waited=$((waited + 2))
	done
	case "$body" in
	*'"ok":true'*) ;;
	*)
		printf '%s/healthz tra ve: %s' "$base" "$(printf '%s' "$body" | head -c 200 | tr '\n' ' ')"
		return 1
		;;
	esac
	room=$(printf '9%011d' "$((RANDOM * 32768 + RANDOM))")
	# With ALLOWED_ORIGINS the relay only answers those pages, so the check comes as the first of them.
	origin=$(printf '%s' "${ALLOWED_ORIGINS:-}" | cut -d , -f 1 | tr -d '[:space:]')
	if ! reason=$(ws_check "wss://$APACHE_SITE$APACHE_PATH/relay" "$APACHE_ADDRESS" "$origin" "$room"); then
		printf 'WebSocket qua Apache khong chay (%s)' "$reason"
		return 1
	fi
}

# Checks the relay the way players reach it: $APACHE_SITE at each address public DNS gives for it.
# Prints what went wrong, if anything.
apache_public_check() {
	local address work status server port=${LF2_PUBLIC_PORT:-443}
	work=$(mktemp -d)
	for address in $SITE_ADDRESSES; do
		status=$(curl -sS --connect-timeout 5 --max-time 10 -k --noproxy '*' --resolve "$APACHE_SITE:$port:$address" \
			-D "$work/headers" -o "$work/body" -w '%{http_code}' "https://$APACHE_SITE:$port$APACHE_PATH/healthz" 2>"$work/error" || true)
		if grep -q '"ok":true' "$work/body" 2>/dev/null; then continue; fi
		server=$(grep -i '^server:' "$work/headers" 2>/dev/null | head -n 1 | cut -d : -f 2- | tr -d '\r' | sed 's/^ *//' || true)
		if [ "${status:-000}" = 000 ]; then
			printf '%s: %s' "$address" "$(head -c 160 "$work/error" | tr '\n' ' ')"
		else
			printf '%s tra ve HTTP %s%s' "$address" "$status" "${server:+, may chu: $server}"
		fi
		rm -rf "$work"
		return 1
	done
	rm -rf "$work"
}

apache_reload() {
	"$SYSTEMCTL" reload "$APACHE_SERVICE"
}

# Puts the relay behind Apache: writes $APACHE_CONF, checks Apache's whole configuration, reloads it
# gracefully, and checks the relay through it. On any failure the file is removed (or the previous one
# restored) and Apache reloaded as it was, so the websites keep running as before.
apache_apply() {
	local previous="" log problem=""
	log=$(mktemp)
	if [ -f "$APACHE_CONF" ]; then
		previous=$(mktemp)
		cp "$APACHE_CONF" "$previous"
	fi
	apache_conf_text >"$APACHE_CONF"
	chmod 0644 "$APACHE_CONF"
	if ! "$APACHECTL" configtest >"$log" 2>&1; then
		apache_undo "$previous" 0
		{
			printf '\n[LOI] Apache bao loi cau hinh; da go file vua them, website khong bi anh huong.\n'
			sed 's/^/      /' "$log"
			printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
		} >&2
		rm -f "$log"
		exit 1
	fi
	if ! apache_reload >"$log" 2>&1; then
		apache_undo "$previous" 1
		{
			printf '\n[LOI] Apache khong nap lai duoc; da go file vua them.\n'
			sed 's/^/      /' "$log"
			printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
		} >&2
		rm -f "$log"
		exit 1
	fi
	rm -f "$log"
	info "Apache da nap them file $APACHE_CONF (nap lai nhe, website van chay)"
	problem=$(apache_verify) || true
	if [ -n "$problem" ]; then
		apache_undo "$previous" 1
		{
			printf '\n[LOI] Relay chua di qua Apache duoc: %s\n' "$problem"
			printf '      Da go file vua them va nap lai cau hinh cu; website khong bi anh huong.\n'
			if [ "$(getenforce 2>/dev/null || true)" = Enforcing ]; then
				printf '      (SELinux dang bat.)\n'
			fi
			printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
		} >&2
		exit 1
	fi
	info "Da kiem tra: https://$APACHE_SITE$APACHE_PATH/ chuyen toi relay (ca HTTP va WebSocket)"
	if ! problem=$(apache_public_check); then
		if [ "$SITE_HERE" = 1 ]; then
			# The name leads here; this machine may just not reach itself by its public address.
			info "Ghi chu: tu VPS chua mo duoc relay qua dia chi cong khai ($problem);"
			info "hay mo https://$APACHE_SITE$APACHE_PATH/healthz tren trinh duyet cua ban de kiem tra."
		else
			apache_undo "$previous" 1
			{
				printf '\n[LOI] Ten mien %s dang tro toi may chu khac (%s), khong phai VPS nay (%s).\n' \
					"$APACHE_SITE" "$SITE_ADDRESSES" "${SERVER_IP:-khong ro IP}"
				printf '      Nguoi choi mo %s se vao may chu kia, khong toi duoc relay tren VPS nay.\n' "$APACHE_SITE"
				printf '      (%s)\n' "$problem"
				printf '      Da go file vua them va nap lai cau hinh cu; website khong bi anh huong.\n'
				printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
			} >&2
			exit 1
		fi
	elif [ "$SITE_HERE" = 0 ]; then
		info "Da kiem tra qua dia chi cong khai cua $APACHE_SITE ($SITE_ADDRESSES): relay tra loi dung"
	fi
	rm -f "${previous:-/nonexistent}"
}

# Undoes apache_apply after a failure: the previous file back (or ours removed), Apache reloaded when it
# had loaded ours, and on a first installation the relay stopped again, so the server is as it was.
apache_undo() { # previous-copy reloaded(0/1)
	apache_restore "$1"
	[ "$2" = 0 ] || apache_reload >/dev/null 2>&1 || true
	if [ -z "$1" ]; then
		"$SYSTEMCTL" stop lf2-relay.service >/dev/null 2>&1 || true
		"$SYSTEMCTL" disable lf2-relay.service >/dev/null 2>&1 || true
	fi
}

apache_restore() { # copy of the previous file, or empty when there was none
	if [ -n "$1" ]; then
		cp "$1" "$APACHE_CONF"
		rm -f "$1"
	else
		rm -f "$APACHE_CONF"
	fi
}

# Removes the relay's Apache file, if this installer wrote one, and reloads Apache.
apache_unconfigure() {
	[ -f "$APACHE_CONF" ] && grep -q 'Written by install-vps.sh' "$APACHE_CONF" || return 0
	rm -f "$APACHE_CONF"
	if "$APACHECTL" configtest >/dev/null 2>&1 && apache_reload >/dev/null 2>&1; then
		info "Da go $APACHE_CONF khoi Apache va nap lai"
	else
		info "Da xoa $APACHE_CONF; hay chay: systemctl reload $APACHE_SERVICE"
	fi
}

uninstall() {
	say "Go relay"
	apache_unconfigure
	"$SYSTEMCTL" stop lf2-caddy.service lf2-relay.service 2>/dev/null || true
	"$SYSTEMCTL" disable lf2-caddy.service lf2-relay.service >/dev/null 2>&1 || true
	rm -f "$SYSTEMD_DIR/lf2-caddy.service" "$SYSTEMD_DIR/lf2-relay.service"
	"$SYSTEMCTL" daemon-reload || true
	rm -rf "$PREFIX"
	userdel lf2relay 2>/dev/null || true
	userdel lf2caddy 2>/dev/null || true
	info "Xong. (Cong 80 va 443 tren tuong lua van mo; dong lai neu ban muon.)"
}

main() {
	if [ "${1:-}" = --uninstall ]; then
		[ "$(id -u)" -eq 0 ] || fail "Hay chay bang tai khoan root."
		uninstall
		return
	fi

	say "Kiem tra may chu (trinh cai dat phien ban $INSTALLER_VERSION)"
	[ "$(id -u)" -eq 0 ] || fail "Hay chay bang tai khoan root (dang nhap root, hoac: ... | sudo bash)."
	[ -d /run/systemd/system ] || [ -n "${LF2_TEST_MODE:-}" ] || fail "May chu nay khong dung systemd."
	local os="Linux"
	if [ -r /etc/os-release ]; then
		os=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")
	fi
	info "He dieu hanh: $os"
	case "$(uname -m)" in
	x86_64 | amd64) NODE_ARCH=x64 CADDY_ARCH=amd64 ;;
	aarch64 | arm64) NODE_ARCH=arm64 CADDY_ARCH=arm64 ;;
	*) fail "Kien truc $(uname -m) chua duoc ho tro." ;;
	esac
	load_apache_state
	check_ports
	keep_allowed_origins
	[ -z "$ALLOWED_ORIGINS" ] || info "Chi trang game o $ALLOWED_ORIGINS duoc dung relay"
	keep_admin_key

	if [ "$CADDY_MODE" = apache ]; then
		apache_preflight
	elif [ -z "${DOMAIN:-}" ]; then
		local ip
		ip=$(public_ip || true)
		[ -n "$ip" ] || fail "Khong tim duoc dia chi IP cong khai cua VPS. Thu lai, hoac chay voi DOMAIN=ten-mien-cua-ban."
		DOMAIN=$(sslip_name "$ip")
		info "IP cong khai: $ip  ->  ten mien: $DOMAIN"
	else
		info "Ten mien: $DOMAIN"
	fi

	say "Cai Node.js"
	mkdir -p "$PREFIX"
	install_node

	say "Cai relay"
	ensure_user lf2relay "$PREFIX/app"
	[ "$CADDY_MODE" = apache ] || ensure_user lf2caddy "$PREFIX/caddy-data"
	install_app
	write_relay_env
	info "Relay da cai vao $PREFIX/app"

	say "Luu du lieu game LF2 tren VPS (khoang 30 MB)"
	install_game_data

	if [ "$CADDY_MODE" != apache ]; then
		say "Cai Caddy (HTTPS)"
		install_caddy

		say "Mo $(caddy_ports)"
		open_firewall
	fi

	say "Khoi dong dich vu"
	write_units
	"$SYSTEMCTL" daemon-reload
	if [ "$CADDY_MODE" = apache ]; then
		"$SYSTEMCTL" enable lf2-relay.service >/dev/null 2>&1 ||
			fail "Khong bat duoc dich vu. Gui thong bao nay cho nguoi huong dan ban."
	else
		"$SYSTEMCTL" enable lf2-relay.service lf2-caddy.service >/dev/null 2>&1 ||
			fail "Khong bat duoc dich vu. Gui thong bao nay cho nguoi huong dan ban."
	fi
	"$SYSTEMCTL" restart lf2-relay.service
	wait_for "http://127.0.0.1:$RELAY_PORT/healthz" 30 --noproxy '*' ||
		fail "Relay khong chay. Xem loi bang lenh: journalctl -u lf2-relay -n 30 --no-pager"
	info "Relay dang chay"

	if [ "$CADDY_MODE" = apache ]; then
		say "Noi relay vao website $APACHE_SITE (Apache)"
		apache_apply
		save_apache_state
		finish_apache
		return 0
	fi
	"$SYSTEMCTL" restart lf2-caddy.service
	info "Dang lay chung chi HTTPS cho $DOMAIN (co the mat 1-2 phut)..."
	# (bash 4.2 on CentOS 7 treats an empty array as unset under set -u, so no array here)
	local strict=--fail
	[ -z "${LF2_TEST_MODE:-}" ] || strict=-k
	if ! wait_for "https://$DOMAIN/healthz" 150 "$strict"; then
		if wait_for "https://$DOMAIN/healthz" 6 -k; then
			info "HTTPS da chay, nhung may chu nay (he dieu hanh cu) chua tin chung chi moi."
			info "Hay mo https://$DOMAIN/healthz tren trinh duyet cua ban de kiem tra."
		else
			{
				printf '\n[LOI] Chua lay duoc chung chi HTTPS cho %s.\n' "$DOMAIN"
				printf '      Thuong la do tuong lua cua nha cung cap VPS chan %s:\n' "$(caddy_ports)"
				printf '      vao trang quan ly VPS, mo %s (TCP), roi chay lai lenh cai dat.\n' "$(caddy_ports)"
				printf '      Neu van loi, gui toan bo thong bao nay cho nguoi huong dan ban.\n'
				caddy_errors
			} >&2
			exit 1
		fi
	fi

	cat <<EOF

============================================================
  XONG! Dia chi relay cua ban:

      wss://$DOMAIN/relay

  Dan dia chi nay vao o "Relay" trong khung "Online play"
  tren trang game. Kiem tra nhanh: mo https://$DOMAIN/healthz
  tren trinh duyet, thay {"ok":true,...} la dung.

  Tai ban mod len relay:  https://$DOMAIN/admin
  Hoc tang cuong nhieu may: https://$DOMAIN/hoc
  Gemini choi cung:        https://$DOMAIN/gemini
  Ma quan tri (ADMIN_KEY): $ADMIN_KEY
  (xem lai ma: cat $PREFIX/relay.env)
============================================================
EOF
	if [ "$CADDY_MODE" = tls-only ]; then
		info "Ghi chu: website dang chay o cong 80 van giu nguyen; relay chi dung cong 443."
	fi
	if [ "$HAVE_DATA" = 1 ]; then
		info "Du lieu game: trang game tai tu VPS nay, khong can IDM hay chon file."
	fi
}

finish_apache() {
	cat <<EOF

============================================================
  XONG! Dia chi relay cua ban:

      wss://$APACHE_SITE$APACHE_PATH/relay

  Dan dia chi nay vao o "Relay" trong khung "Online play"
  (hoac o "Relay address" khi build trang game).
  Kiem tra nhanh: mo https://$APACHE_SITE$APACHE_PATH/healthz
  tren trinh duyet, thay {"ok":true,...} la dung.

  Tai ban mod len relay:  https://$APACHE_SITE$APACHE_PATH/admin
  Hoc tang cuong nhieu may: https://$APACHE_SITE$APACHE_PATH/hoc
  Gemini choi cung:        https://$APACHE_SITE$APACHE_PATH/gemini
  Ma quan tri (ADMIN_KEY): $ADMIN_KEY
  (xem lai ma: cat $PREFIX/relay.env)
============================================================
EOF
	info "Website $APACHE_SITE van chay nhu cu; relay chi dung duong dan $APACHE_PATH/."
	info "Da them file $APACHE_CONF (go bo: chay lai lenh voi --uninstall)."
	if [ "$HAVE_DATA" = 1 ]; then
		info "Du lieu game: trang game tai tu VPS nay, khong can IDM hay chon file."
	fi
}

# The last errors Caddy logged, to send along with a failure message.
caddy_errors() {
	command -v journalctl >/dev/null 2>&1 || return 0
	local lines
	lines=$(journalctl -u lf2-caddy.service -n 200 --no-pager 2>/dev/null | grep -E '"level":"error"' | tail -n 3 | cut -c 1-400 || true)
	[ -z "$lines" ] || printf '      Loi gan nhat cua Caddy:\n%s\n' "$lines"
}

# >>> generated by update-installer.js: the relay's files, base64 (do not edit by hand)
write_server_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
IyEvdXNyL2Jpbi9lbnYgbm9kZQovLyBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogTUlUCi8vCi8v
IE9wZW5MRjIgb25saW5lIHJlbGF5LgovLwovLyBCcm93c2VycyBjYW5ub3Qgb3BlbiByYXcgVENQ
IHNvY2tldHMsIHNvIE9wZW5MRjIncyB3ZWIgYnVpbGQgcGxheXMgb3ZlciBhIFdlYlNvY2tldCB0
byB0aGlzIHJlbGF5Ci8vIGluc3RlYWQuIFBsYXllcnMgbWVldCBpbiBhIHJvb20gbmFtZWQgYnkg
YSBudW1lcmljIGNvZGUuIFRoZSByZWxheSBzcGVha3MgdHdvIHByb3RvY29sczoKLy8KLy8gUHJv
dG9jb2wgMiwgcm9vbXMgb2YgdXAgdG8gOCBwbGF5ZXJzICh0aGUgd2ViIGJ1aWxkJ3Mgb3duOyBz
ZWUgIlJvb21zIiBiZWxvdyk6Ci8vICAgd3Mocyk6Ly88c2VydmVyPi9yZWxheT92PTImcm9sZT1o
b3N0JnJvb209NDgyOTEzICAgTmV0d29yayBHYW1lID4gSG9zdAovLyAgIHdzKHMpOi8vPHNlcnZl
cj4vcmVsYXk/dj0yJnJvbGU9am9pbiZyb29tPTQ4MjkxMyAgIE5ldHdvcmsgR2FtZSA+IENvbm5l
Y3QsIHJvb20gY29kZSBhcyB0aGUgYWRkcmVzcwovLyBUaGUgcmVsYXkga2VlcHMgdGhlIGJlYXQ6
IGV2ZXJ5IDMzIDEvMyBtcyAoMzAgcGVyIHNlY29uZCkgaXQgc2VuZHMgZWFjaCBwbGF5ZXIgb25l
IGZyYW1lIGhvbGRpbmcgdGhlIG5ld2VzdCBpbnB1dCBvZgovLyBldmVyeSBwbGF5ZXIsIHNvIG5v
Ym9keSB3YWl0cyBmb3IgdGhlIHNsb3dlc3QgY29ubmVjdGlvbi4KLy8KLy8gUHJvdG9jb2wgMSwg
dHdvIHBsYXllcnMgKG9sZGVyIGdhbWUgcGFnZXMpOiB0aGUgcmVsYXkgcGFpcnMgaG9zdCBhbmQg
Z3Vlc3QgYW5kIGNvcGllcyBiaW5hcnkgZnJhbWVzCi8vIGZyb20gb25lIHRvIHRoZSBvdGhlciB1
bmNoYW5nZWQuIFRoZSBnYW1lJ3Mgb3duIGxvY2tzdGVwIHByb3RvY29sIChoYW5kc2hha2UsIHJh
bmRvbSB0YWJsZSwgb25lCi8vIDIyLWJ5dGUgaW5wdXQgcGFja2V0IHBlciBmcmFtZSkgcnVucyBv
biB0b3A7IHRoZSByZWxheSBuZXZlciBwYXJzZXMgb3Igc3RvcmVzIGl0LgovLyAgIHdzKHMpOi8v
PHNlcnZlcj4vcmVsYXk/cm9sZT1ob3N0JnJvb209NDgyOTEzCi8vICAgd3Mocyk6Ly88c2VydmVy
Pi9yZWxheT9yb2xlPWpvaW4mcm9vbT00ODI5MTMKLy8gRWl0aGVyIHNpZGUgbWF5IGFycml2ZSBm
aXJzdC4gU2VydmVyLXRvLWNsaWVudCBjb250cm9sIG1lc3NhZ2VzIGFyZSBKU09OIHRleHQgZnJh
bWVzOgovLyAgIHsidCI6IndhaXRpbmciLCJyb29tIjoiNDgyOTEzIn0gICByZWdpc3RlcmVkLCB3
YWl0aW5nIGZvciB0aGUgb3RoZXIgcGxheWVyCi8vICAgeyJ0IjoicGFpcmVkIn0gICAgICAgICAg
ICAgICAgICAgIGJvdGggcGxheWVycyBhcmUgcHJlc2VudDsgYmluYXJ5IGZyYW1lcyBub3cgZmxv
dwovLwovLyBQcm9ibGVtcyBjbG9zZSB0aGUgc29ja2V0IHdpdGggYSA0eHh4IGNvZGUgYW5kIGEg
c2hvcnQgQVNDSUkgcmVhc29uLCB3aGljaCB0aGUgZ2FtZSBzaG93cy4KLy8KLy8gV2l0aCBJTlNU
QUxMRVJfRklMRSBzZXQgKGluc3RhbGwtdnBzLnNoIGRvZXMpLCB0aGUgcmVsYXkgYWxzbyBzZXJ2
ZXMgaXRzIGNvcHkgb2YgdGhlIG9yaWdpbmFsIExGMgovLyB2Mi4wYSBpbnN0YWxsZXIgYXQgL2xm
Mi1pbnN0YWxsZXIuZGF0YSwgd2hpY2ggdGhlIGdhbWUgcGFnZSBkb3dubG9hZHMgYmVmb3JlIHRy
eWluZyBhcmNoaXZlLm9yZzoKLy8gZG93bmxvYWQgbWFuYWdlcnMgc3VjaCBhcyBJRE0gbGV0IHRo
YXQgbmFtZSB0aHJvdWdoLCB3aGlsZSB0aGV5IHRha2Ugb3ZlciB0aGUgLmV4ZSBmcm9tIGFyY2hp
dmUub3JnLgovLyBXaXRoIFBBQ0tTX0RJUiBzZXQsIGl0IGFsc28ga2VlcHMgZ2FtZSBwYWNrcyAo
bW9kcyBwbGF5ZWQgaW5zdGVhZCBvZiB0aGUgb3JpZ2luYWwgZ2FtZSwgc2VlCi8vIHBhY2tzLmpz
KSwgd2hpY2ggd2hvZXZlciBob2xkcyBBRE1JTl9LRVkgdXBsb2FkcyBhdCAvYWRtaW4uCi8vCi8v
IEhlcm8gRmlnaHRlciB2MC43KyAodGhlIHBhZ2UgcnVucyBpdCBpbiBSdWZmbGUpIHBsYXlzIGhl
cmUgdG9vOiBpdHMgcm9vbXMgb24gdGhlIHNhbWUgV2ViU29ja2V0IHBhdGgsCi8vICAgd3Mocyk6
Ly88c2VydmVyPi9yZWxheT9nYW1lPWhmJnJvb209MQovLyBhbmQgc3RhbmQtaW5zIGZvciBoZXJv
ZmlnaHRlci5jb20ncyB3ZWIgc2VydmljZXMgKGFjY291bnRzLCByb29tIGxpc3QpIHVuZGVyIC9o
Zi8gKHNlZSBoZi5qcykuCi8vCi8vIFRoZSBYT0kga2l0J3MgcmVpbmZvcmNlbWVudCBsZWFybmlu
ZyBvbiBtYW55IG1hY2hpbmVzIG1lZXRzIGhlcmUgYXMgd2VsbCAoaG9jLmpzLCBwYWdlIC9ob2Mp
OiB0aGUgcmVsYXkgaGFuZHMKLy8gdGhlIGZpZ2h0ZXJzIG9mIGEgam9iIG91dCB0byB0aGUgbWFj
aGluZXMgdGhhdCBhc2sgYW5kIGtlZXBzIHRoZSBzbWFsbCBmaWxlcyB0aGV5IHNlbmQgYmFjazsg
aXQgbGVhcm5zIG5vdGhpbmcuCi8vCi8vIEFuZCBHZW1pbmkgcGxheXMgYWxvbmcgKGdlbWluaS5q
cywgcGFnZSAvZ2VtaW5pKTogdGhlIGdhbWUgcGFnZSBzZW5kcyB3aGF0IGEgbWF0Y2ggbG9va3Mg
bGlrZSwgdGhlIHJlbGF5IGFza3MKLy8gR29vZ2xlJ3MgR2VtaW5pIHdpdGggdGhlIG93bmVyJ3Mg
QVBJIGtleSAoa2VwdCBoZXJlLCBuZXZlciBzZW50IHRvIHRoZSBwYWdlKSBhbmQgaGFuZHMgdGhl
IGFuc3dlciBiYWNrLgondXNlIHN0cmljdCc7Cgpjb25zdCBmcyA9IHJlcXVpcmUoJ25vZGU6ZnMn
KTsKY29uc3QgaHR0cCA9IHJlcXVpcmUoJ25vZGU6aHR0cCcpOwpjb25zdCB7IFdlYlNvY2tldFNl
cnZlciwgV2ViU29ja2V0IH0gPSByZXF1aXJlKCd3cycpOwpjb25zdCB7IGNyZWF0ZVBhY2tzIH0g
PSByZXF1aXJlKCcuL3BhY2tzLmpzJyk7CmNvbnN0IHsgY3JlYXRlSGYgfSA9IHJlcXVpcmUoJy4v
aGYuanMnKTsKY29uc3QgeyBjcmVhdGVIb2MgfSA9IHJlcXVpcmUoJy4vaG9jLmpzJyk7CmNvbnN0
IHsgY3JlYXRlR2VtaW5pIH0gPSByZXF1aXJlKCcuL2dlbWluaS5qcycpOwoKY29uc3QgSU5TVEFM
TEVSX1BBVEggPSAnL2xmMi1pbnN0YWxsZXIuZGF0YSc7Cgpjb25zdCBST09NX1BBVFRFUk4gPSAv
XlxkezQsMTJ9JC87CgovLyBDbG9zZSBjb2RlcyBhcmUgcGFydCBvZiB0aGUgY29udHJhY3Qgd2l0
aCBvbmxpbmUuanMgKGl0IG1hcHMgdGhlbSB0byBtZXNzYWdlcyB0b28pLgpjb25zdCBDTE9TRSA9
IE9iamVjdC5mcmVlemUoewogIGJhZFJlcXVlc3Q6IFs0MDAwLCAnUmVsYXk6IGJhZCByZXF1ZXN0
J10sCiAgb3JpZ2luRGVuaWVkOiBbNDAwMSwgJ1JlbGF5OiB0aGlzIHdlYnNpdGUgbWF5IG5vdCB1
c2UgdGhlIHJlbGF5J10sCiAgdG9vTWFueUNvbm5lY3Rpb25zOiBbNDAwMiwgJ1JlbGF5OiB0b28g
bWFueSBjb25uZWN0aW9ucyBmcm9tIHlvdXIgbmV0d29yayddLAogIHNlcnZlckZ1bGw6IFs0MDAz
LCAnUmVsYXk6IHNlcnZlciBpcyBmdWxsJ10sCiAgaG9zdFRha2VuOiBbNDAwNCwgJ1JlbGF5OiBy
b29tIGFscmVhZHkgaGFzIGEgaG9zdCddLAogIGd1ZXN0VGFrZW46IFs0MDA0LCAnUmVsYXk6IHJv
b20gYWxyZWFkeSBoYXMgYSBndWVzdCddLAogIHRpbWVvdXQ6IFs0MDA1LCAnUmVsYXk6IG5vYm9k
eSBqb2luZWQgaW4gdGltZSddLAogIHBlZXJMZWZ0OiBbNDAwNiwgJ1JlbGF5OiB0aGUgb3RoZXIg
cGxheWVyIGxlZnQnXSwKICByYXRlTGltaXRlZDogWzQwMDcsICdSZWxheTogdG9vIG11Y2ggdHJh
ZmZpYyddLAogIHNsb3dQZWVyOiBbNDAwOCwgJ1JlbGF5OiB0aGUgb3RoZXIgcGxheWVyIHN0b3Bw
ZWQgcmVhZGluZyddLAogIGVhcmx5RGF0YTogWzQwMDksICdSZWxheTogZGF0YSBzZW50IGJlZm9y
ZSBwYWlyaW5nJ10sCiAgLy8gUHJvdG9jb2wgMiByb29tcy4KICByb29tRnVsbDogWzQwMTAsICdS
ZWxheTogdGhlIHJvb20gaXMgZnVsbCddLAogIHN0YXJ0ZWQ6IFs0MDExLCAnUmVsYXk6IHRoZSBn
YW1lIGluIHRoaXMgcm9vbSBoYXMgYWxyZWFkeSBzdGFydGVkJ10sCiAgbWlzbWF0Y2g6IFs0MDEy
LCAnUmVsYXk6IHRoaXMgcm9vbSBwbGF5cyBhbm90aGVyIGdhbWUgdmVyc2lvbiBvciBtb2QnXSwK
ICBob3N0TGVmdDogWzQwMTMsICdSZWxheTogdGhlIGhvc3QgbGVmdCB0aGUgcm9vbSddLAogIG5v
dFN0YXJ0ZWQ6IFs0MDE0LCAnUmVsYXk6IHRoZSBob3N0IGRpZCBub3Qgc3RhcnQgdGhlIGdhbWUg
aW4gdGltZSddLAogIHByb3RvY29sOiBbNDAxNSwgJ1JlbGF5OiB1bmV4cGVjdGVkIG1lc3NhZ2Ug
ZnJvbSB0aGUgZ2FtZSddLAogIHNsb3dDbGllbnQ6IFs0MDE2LCAnUmVsYXk6IHlvdXIgY29ubmVj
dGlvbiBpcyB0b28gc2xvdyBmb3IgdGhlIGdhbWUnXSwKICBjb2RlSW5Vc2U6IFs0MDE3LCAnUmVs
YXk6IHRoaXMgcm9vbSBjb2RlIGlzIGluIHVzZSBieSBhbiBvbGRlciBnYW1lIHBhZ2UnXSwKICBu
ZXdlclJvb206IFs0MDE3LCAnUmVsYXk6IHRoaXMgcm9vbSBpcyBmb3IgYSBuZXdlciBnYW1lIHBh
Z2UgKHJlbG9hZCB0aGUgcGFnZSknXSwKICBzaHV0ZG93bjogWzEwMDEsICdSZWxheTogc2VydmVy
IGlzIHJlc3RhcnRpbmcnXSwKfSk7CgovLyBQcm90b2NvbCAyIG1lc3NhZ2Uga2luZHMgKHNlZSAi
Um9vbXMiIGJlbG93KS4KY29uc3QgS0lORCA9IE9iamVjdC5mcmVlemUoewogIGhlbGxvOiAweDAx
LCBzdGFydDogMHgwMiwgaW5wdXQ6IDB4MDMsIHJlYWR5OiAweDA0LCBjaGVjazogMHgwNSwKICB3
ZWxjb21lOiAweDgxLCBsb2JieTogMHg4Miwgc3RhcnRlZDogMHg4MywgZnJhbWU6IDB4ODQsIGNo
ZWNrZWQ6IDB4ODUsIGxlZnQ6IDB4ODYsCn0pOwpjb25zdCBST09NX0xJTUlUUyA9IE9iamVjdC5m
cmVlemUoeyBwbGF5ZXJzOiA4LCBwcm9maWxlOiAyMDAsIGluZm86IDY0LCBpbnB1dDogMTYsIHNl
dHVwOiA4MTkyLCBxdWV1ZTogNjQgfSk7Ci8vIFRoZSBsYXJnZXN0IHRleHQgbWVzc2FnZSBhIHBh
Z2UgbWF5IHNlbmQgKGEgZGlyZWN0IGNvbm5lY3Rpb24ncyBvZmZlciBvciBhbnN3ZXIpLgpjb25z
dCBTSUdOQUxfTElNSVQgPSAxNjM4NDsKCmZ1bmN0aW9uIHJlYWRDb25maWcoZW52ID0gcHJvY2Vz
cy5lbnYpIHsKICBjb25zdCBudW1iZXIgPSAobmFtZSwgZmFsbGJhY2spID0+IHsKICAgIGNvbnN0
IHJhdyA9IGVudltuYW1lXTsKICAgIGNvbnN0IHZhbHVlID0gcmF3ID09PSB1bmRlZmluZWQgfHwg
cmF3ID09PSAnJyA/IGZhbGxiYWNrIDogTnVtYmVyKHJhdyk7CiAgICBpZiAoIU51bWJlci5pc0Zp
bml0ZSh2YWx1ZSkgfHwgdmFsdWUgPCAwKSB0aHJvdyBuZXcgRXJyb3IoYCR7bmFtZX0gbXVzdCBi
ZSBhIG5vbi1uZWdhdGl2ZSBudW1iZXJgKTsKICAgIHJldHVybiB2YWx1ZTsKICB9OwogIHJldHVy
biB7CiAgICBwb3J0OiBudW1iZXIoJ1BPUlQnLCA4Nzg3KSwKICAgIGhvc3Q6IGVudi5IT1NUIHx8
ICcwLjAuMC4wJywKICAgIHBhdGg6IGVudi5SRUxBWV9QQVRIIHx8ICcvcmVsYXknLAogICAgLy8g
Q29tbWEtc2VwYXJhdGVkIHBhZ2Ugb3JpZ2lucyBhbGxvd2VkIHRvIGNvbm5lY3QsIGUuZy4gImh0
dHBzOi8veW91LmdpdGh1Yi5pbyIuIEVtcHR5IGFsbG93cyBhbnkuCiAgICBhbGxvd2VkT3JpZ2lu
czogKGVudi5BTExPV0VEX09SSUdJTlMgfHwgJycpLnNwbGl0KCcsJykubWFwKG5vcm1hbGl6ZU9y
aWdpbikuZmlsdGVyKEJvb2xlYW4pLAogICAgLy8gQmVoaW5kIGEgcmV2ZXJzZSBwcm94eSAoQ2Fk
ZHksIG5naW54LCBDbG91ZGZsYXJlKSwgdGFrZSB0aGUgY2xpZW50IGFkZHJlc3MgZnJvbSBYLUZv
cndhcmRlZC1Gb3IuCiAgICB0cnVzdFByb3h5OiBlbnYuVFJVU1RfUFJPWFkgPT09ICcxJyB8fCBl
bnYuVFJVU1RfUFJPWFkgPT09ICd0cnVlJywKICAgIG1heFJvb21zOiBudW1iZXIoJ01BWF9ST09N
UycsIDUwMCksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIG1heENvbm5lY3Rpb25zUGVySXA6IG51bWJl
cignTUFYX0NPTk5FQ1RJT05TX1BFUl9JUCcsIDgpLCAvLyAwID0gdW5saW1pdGVkCiAgICByb29t
V2FpdE1zOiBudW1iZXIoJ1JPT01fV0FJVF9NUycsIDEyMDAwMCksCiAgICBwaW5nSW50ZXJ2YWxN
czogbnVtYmVyKCdQSU5HX0lOVEVSVkFMX01TJywgMTUwMDApLAogICAgbWF4TWVzc2FnZUJ5dGVz
OiBudW1iZXIoJ01BWF9NRVNTQUdFX0JZVEVTJywgNjU1MzYpLCAvLyB0aGUgZ2FtZSBxdWV1ZXMg
YXQgbW9zdCA2NCBLaUIKICAgIG1lc3NhZ2VzUGVyU2Vjb25kOiBudW1iZXIoJ01FU1NBR0VTX1BF
Ul9TRUNPTkQnLCAyNDApLCAvLyB0aGUgZ2FtZSBzZW5kcyB+MzAgcGVyIHNlY29uZDsgMCA9IHVu
bGltaXRlZAogICAgYnl0ZXNQZXJTZWNvbmQ6IG51bWJlcignQllURVNfUEVSX1NFQ09ORCcsIDEz
MTA3MiksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIG1heEJ1ZmZlcmVkQnl0ZXM6IG51bWJlcignTUFY
X0JVRkZFUkVEX0JZVEVTJywgMTA0ODU3NiksCiAgICAvLyBUZXN0aW5nIGFpZDogaG9sZCBldmVy
eSBmb3J3YXJkZWQgZnJhbWUgdGhpcyBsb25nLCB0byBmZWVsIGhvdyBhIGRpc3RhbnQgcmVsYXkg
d291bGQgcGxheS4KICAgIGZvcndhcmREZWxheU1zOiBudW1iZXIoJ0ZPUldBUkRfREVMQVlfTVMn
LCAwKSwKICAgIC8vIFByb3RvY29sIDIgcm9vbXM6IG1vc3QgcGxheWVycyBpbiBhIHJvb20gKGF0
IG1vc3QgOCwgdGhlIGdhbWUncyBwbGF5ZXIgc2xvdHMpLCB0aGUgYmVhdCwgaG93CiAgICAvLyBs
b25nIGEgcm9vbSBtYXkgd2FpdCBmb3IgaXRzIGhvc3QgdG8gcHJlc3Mgc3RhcnQsIGhvdyBsb25n
IHRoZSByZWxheSB3YWl0cyBmb3IgZXZlcnkgZ2FtZSB0bwogICAgLy8gYmUgcmVhZHkgYWZ0ZXIg
dGhlIHN0YXJ0LCBhbmQgYWZ0ZXIgaG93IG1hbnkgYmVhdHMgd2l0aG91dCBuZXdzIGEgcGxheWVy
J3Mga2V5cyBjb3VudCBhcyByZWxlYXNlZC4KICAgIHJvb21QbGF5ZXJzOiBNYXRoLm1pbihST09N
X0xJTUlUUy5wbGF5ZXJzLCBNYXRoLm1heCgyLCBudW1iZXIoJ1JPT01fUExBWUVSUycsIFJPT01f
TElNSVRTLnBsYXllcnMpKSksCiAgICAvLyAzMyAxLzMgbXM6IDMwIGJlYXRzIHBlciBzZWNvbmQs
IHR3byByZWZyZXNoZXMgb2YgYSA2MCBIeiBkaXNwbGF5IGVhY2ggKHdob2xlIHRoaXJkcyBvZiBh
IG1zIG9ubHkpLgogICAgdGlja01zOiBNYXRoLm1heCgxLCBNYXRoLnJvdW5kKG51bWJlcignVElD
S19NUycsIDEwMCAvIDMpICogMykgLyAzKSwKICAgIGxvYmJ5V2FpdE1zOiBudW1iZXIoJ0xPQkJZ
X1dBSVRfTVMnLCAxODAwMDAwKSwKICAgIHN0YXJ0R3JhY2VNczogbnVtYmVyKCdTVEFSVF9HUkFD
RV9NUycsIDUwMDApLAogICAgcmVwZWF0TGltaXQ6IG51bWJlcignUkVQRUFUX0xJTUlUJywgMTUp
LAogICAgLy8gVGhlIExGMiBpbnN0YWxsZXIgc2VydmVkIGF0IC9sZjItaW5zdGFsbGVyLmRhdGEg
KGVtcHR5OiBub3Qgc2VydmVkKSwgYW5kIGhvdyBvZnRlbiBvbmUgY2xpZW50CiAgICAvLyBhZGRy
ZXNzIG1heSBkb3dubG9hZCBpdCAoYWJvdXQgMzAgTUIgZWFjaCB0aW1lOyBicm93c2VycyBrZWVw
IGl0IGFmdGVyIHRoZSBmaXJzdCB0aW1lKS4KICAgIGluc3RhbGxlckZpbGU6IGVudi5JTlNUQUxM
RVJfRklMRSB8fCAnJywKICAgIGluc3RhbGxlckRvd25sb2Fkc1BlckhvdXI6IG51bWJlcignSU5T
VEFMTEVSX0RPV05MT0FEU19QRVJfSE9VUicsIDIwKSwgLy8gMCA9IHVubGltaXRlZAogICAgLy8g
R2FtZSBwYWNrcyAocGFja3MuanMpOiB3aGVyZSB0aGV5IGFyZSBrZXB0IChlbXB0eTogbm9uZSks
IHRoZSBrZXkgZm9yIHVwbG9hZGluZyB0aGVtIGF0IC9hZG1pbgogICAgLy8gKGVtcHR5OiBubyB1
cGxvYWRzKSwgdGhlaXIgbGFyZ2VzdCBzaXplLCBhbmQgaG93IG9mdGVuIG9uZSBjbGllbnQgYWRk
cmVzcyBtYXkgZG93bmxvYWQgb25lLgogICAgcGFja3NEaXI6IGVudi5QQUNLU19ESVIgfHwgJycs
CiAgICBhZG1pbktleTogZW52LkFETUlOX0tFWSB8fCAnJywKICAgIG1heFBhY2tCeXRlczogbnVt
YmVyKCdNQVhfUEFDS19CWVRFUycsIDEwMjQgKiAxMDI0ICogMTAyNCksCiAgICBwYWNrRG93bmxv
YWRzUGVySG91cjogbnVtYmVyKCdQQUNLX0RPV05MT0FEU19QRVJfSE9VUicsIDIwKSwgLy8gMCA9
IHVubGltaXRlZAogICAgLy8gSGVybyBGaWdodGVyIChoZi5qcyk6IGhvdyBtYW55IHJvb21zLCB0
aGVpciBkZXNjcmlwdGlvbiBpbiB0aGUgZ2FtZSdzIHJvb20gbGlzdCwgYW5kIHdoZXJlIHRoZQog
ICAgLy8gYWNjb3VudHMgYXJlIGtlcHQgKGVtcHR5OiBpbiA8UEFDS1NfRElSPi9oZiwgb3Igb25s
eSBpbiBtZW1vcnkgd2l0aG91dCBQQUNLU19ESVIpLgogICAgaGZSb29tczogbnVtYmVyKCdIRl9S
T09NUycsIDQpLAogICAgaGZSb29tRGVzY3JpcHRpb246IGVudi5IRl9ST09NX0RFU0NSSVBUSU9O
IHx8ICdPcGVuTEYyIHJlbGF5JywKICAgIGhmRGlyOiBlbnYuSEZfRElSIHx8ICcnLAogICAgLy8g
UmVpbmZvcmNlbWVudCBsZWFybmluZyBvbiBtYW55IG1hY2hpbmVzIChob2MuanMpOiB3aGVyZSB0
aGUgam9iIGFuZCB0aGUgbWFjaGluZXMnIHJlc3VsdHMgYXJlIGtlcHQKICAgIC8vIChlbXB0eTog
aW4gPFBBQ0tTX0RJUj4vaG9jLCBvciBub3doZXJlIHdpdGhvdXQgUEFDS1NfRElSKS4KICAgIGhv
Y0RpcjogZW52LkhPQ19ESVIgfHwgJycsCiAgICAvLyBHZW1pbmkgcGxheXMgYWxvbmcgKGdlbWlu
aS5qcyk6IHdoZXJlIHRoZSBvd25lcidzIEdlbWluaSBBUEkga2V5IGFuZCB0aGUgc2V0dGluZ3Mg
b2YgdGhlIHBhZ2UgL2dlbWluaSBhcmUga2VwdAogICAgLy8gKGVtcHR5OiBpbiA8UEFDS1NfRElS
Pi9nZW1pbmksIG9yIG9ubHkgaW4gbWVtb3J5IHdpdGhvdXQgUEFDS1NfRElSKTsgR0VNSU5JX0FQ
SV9CQVNFIGZvciB0ZXN0cy4KICAgIGdlbWluaURpcjogZW52LkdFTUlOSV9ESVIgfHwgJycsCiAg
ICBnZW1pbmlBcGlCYXNlOiBlbnYuR0VNSU5JX0FQSV9CQVNFIHx8ICcnLAogICAgcXVpZXQ6IGVu
di5RVUlFVCA9PT0gJzEnIHx8IGVudi5RVUlFVCA9PT0gJ3RydWUnLAogIH07Cn0KCmZ1bmN0aW9u
IG5vcm1hbGl6ZU9yaWdpbih2YWx1ZSkgewogIHJldHVybiBTdHJpbmcodmFsdWUgfHwgJycpLnRy
aW0oKS5yZXBsYWNlKC9cLyskLywgJycpLnRvTG93ZXJDYXNlKCk7Cn0KCi8vIFRva2VuIGJ1Y2tl
dDogYHJhdGVgIHVuaXRzIHBlciBzZWNvbmQsIGJ1cnN0cyB1cCB0byBgY2FwYWNpdHlgLiBBIHJh
dGUgb2YgMCBkaXNhYmxlcyB0aGUgbGltaXQuCmNsYXNzIEJ1Y2tldCB7CiAgY29uc3RydWN0b3Io
cmF0ZSwgY2FwYWNpdHkpIHsKICAgIHRoaXMucmF0ZSA9IHJhdGU7CiAgICB0aGlzLmNhcGFjaXR5
ID0gTWF0aC5tYXgoY2FwYWNpdHksIHJhdGUpOwogICAgdGhpcy50b2tlbnMgPSB0aGlzLmNhcGFj
aXR5OwogICAgdGhpcy5sYXN0ID0gRGF0ZS5ub3coKTsKICB9CiAgdGFrZShhbW91bnQpIHsKICAg
IGlmICh0aGlzLnJhdGUgPT09IDApIHJldHVybiB0cnVlOwogICAgY29uc3Qgbm93ID0gRGF0ZS5u
b3coKTsKICAgIHRoaXMudG9rZW5zID0gTWF0aC5taW4odGhpcy5jYXBhY2l0eSwgdGhpcy50b2tl
bnMgKyAoKG5vdyAtIHRoaXMubGFzdCkgKiB0aGlzLnJhdGUpIC8gMTAwMCk7CiAgICB0aGlzLmxh
c3QgPSBub3c7CiAgICBpZiAodGhpcy50b2tlbnMgPCBhbW91bnQpIHJldHVybiBmYWxzZTsKICAg
IHRoaXMudG9rZW5zIC09IGFtb3VudDsKICAgIHJldHVybiB0cnVlOwogIH0KfQoKZnVuY3Rpb24g
Y3JlYXRlUmVsYXkob3ZlcnJpZGVzID0ge30pIHsKICBjb25zdCBjb25maWcgPSB7IC4uLnJlYWRD
b25maWcoe30pLCAuLi5vdmVycmlkZXMgfTsKICBjb25zdCByb29tcyA9IG5ldyBNYXAoKTsgLy8g
cHJvdG9jb2wgMTogY29kZSAtPiB7IGNvZGUsIGhvc3QsIGpvaW4sIHRpbWVyIH0KICBjb25zdCBn
cm91cHMgPSBuZXcgTWFwKCk7IC8vIHByb3RvY29sIDI6IGNvZGUgLT4gcm9vbSAoc2VlICJSb29t
cyIgYmVsb3cpCiAgY29uc3QgY29ubmVjdGlvbnNQZXJJcCA9IG5ldyBNYXAoKTsKICBjb25zdCBs
b2cgPSAoLi4ucGFydHMpID0+IHsgaWYgKCFjb25maWcucXVpZXQpIGNvbnNvbGUubG9nKG5ldyBE
YXRlKCkudG9JU09TdHJpbmcoKSwgLi4ucGFydHMpOyB9OwoKICBjb25zdCBpbnN0YWxsZXJEb3du
bG9hZHMgPSBuZXcgTWFwKCk7IC8vIGNsaWVudCBhZGRyZXNzIC0+IHsgY291bnQsIHVudGlsIH0K
ICBjb25zdCBpbnN0YWxsZXJQYXRocyA9IG5ldyBTZXQoW0lOU1RBTExFUl9QQVRILCBjb25maWcu
cGF0aC5yZXBsYWNlKC9bXi9dKiQvLCBJTlNUQUxMRVJfUEFUSC5zbGljZSgxKSldKTsKICAvLyBC
ZXNpZGUgdGhlIFdlYlNvY2tldCBwYXRoLCBhcyB0aGUgaW5zdGFsbGVyIGNvcHk6IC94L3JlbGF5
IC0+IC94L2xmMi1wYWNrcy5qc29uIGFuZCAveC9hZG1pbi4KICBjb25zdCByZWxheUZvbGRlciA9
IGNvbmZpZy5wYXRoLnJlcGxhY2UoL1teL10qJC8sICcnKTsKICBjb25zdCBwYWNrcyA9IGNyZWF0
ZVBhY2tzKGNvbmZpZywgeyBsb2csIGNsaWVudEFkZHJlc3M6IChyZXEpID0+IGNsaWVudEFkZHJl
c3MocmVxKSwgYWxsb3dPcmlnaW46IChyZXEpID0+IGFsbG93T3JpZ2luKHJlcSksCiAgICBoZkpv
dXJuYWw6ICgpID0+IGhmLmpvdXJuYWwoKSwKICAgIGhmQWNjb3VudHM6IHsgbGlzdDogKCkgPT4g
aGYuYWNjb3VudHMubGlzdCgpLCBzZXRQcmVtaXVtOiAoaWQsIG9uKSA9PiBoZi5hY2NvdW50cy5z
ZXRQcmVtaXVtKGlkLCBvbikgfSB9KTsKICBjb25zdCBoZiA9IGNyZWF0ZUhmKGNvbmZpZywgewog
ICAgbG9nLCBjbGllbnRBZGRyZXNzOiAocmVxKSA9PiBjbGllbnRBZGRyZXNzKHJlcSksIGFsbG93
T3JpZ2luOiAocmVxKSA9PiBhbGxvd09yaWdpbihyZXEpLAogICAgYnVkZ2V0OiAod3MsIGJ5dGVz
KSA9PiB3cy5tZXNzYWdlQnVkZ2V0LnRha2UoMSkgJiYgd3MuYnl0ZUJ1ZGdldC50YWtlKGJ5dGVz
KSwKICB9KTsKICBjb25zdCBob2MgPSBjcmVhdGVIb2MoY29uZmlnLCB7IGxvZywgY2xpZW50QWRk
cmVzczogKHJlcSkgPT4gY2xpZW50QWRkcmVzcyhyZXEpIH0pOwogIGNvbnN0IGdlbWluaSA9IGNy
ZWF0ZUdlbWluaShjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzOiAocmVxKSA9PiBjbGllbnRB
ZGRyZXNzKHJlcSksIGFsbG93T3JpZ2luOiAocmVxKSA9PiBhbGxvd09yaWdpbihyZXEpIH0pOwoK
ICBjb25zdCBzZXJ2ZXIgPSBodHRwLmNyZWF0ZVNlcnZlcigocmVxLCByZXMpID0+IHsKICAgIGNv
bnN0IHsgcGF0aG5hbWUgfSA9IG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9yZWxheS5pbnZhbGlk
Jyk7CiAgICBpZiAocGF0aG5hbWUgPT09ICcvaGVhbHRoeicpIHsKICAgICAgLy8gUmVhZGFibGUg
ZnJvbSB0aGUgZ2FtZSBwYWdlIChhbm90aGVyIG9yaWdpbikgc28gaXRzIE9ubGluZSBwYW5lbCBj
YW4gc2hvdyAicmVsYXkgT0siLgogICAgICByZXMud3JpdGVIZWFkKDIwMCwgewogICAgICAgICdj
b250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vanNvbicsCiAgICAgICAgJ2NhY2hlLWNvbnRyb2wn
OiAnbm8tc3RvcmUnLAogICAgICAgICdhY2Nlc3MtY29udHJvbC1hbGxvdy1vcmlnaW4nOiAnKics
CiAgICAgIH0pOwogICAgICByZXMuZW5kKEpTT04uc3RyaW5naWZ5KHsKICAgICAgICBvazogdHJ1
ZSwgcm9vbXM6IHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSwgY2xpZW50czogd3NzLmNsaWVudHMu
c2l6ZSwgaW5zdGFsbGVyOiBpbnN0YWxsZXJTaXplKCkgPiAwLAogICAgICAgIHByb3RvY29sczog
WzEsIDJdLCBwbGF5ZXJzOiBjb25maWcucm9vbVBsYXllcnMsIHBhY2tzOiBCb29sZWFuKGNvbmZp
Zy5wYWNrc0RpciksIGhmOiBoZi5kZXNjcmliZSgpLCBkaXJlY3Q6IHRydWUsCiAgICAgIH0pKTsK
ICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGluc3RhbGxlclBhdGhzLmhhcyhwYXRobmFtZSkp
IHsKICAgICAgc2VydmVJbnN0YWxsZXIocmVxLCByZXMpOwogICAgICByZXR1cm47CiAgICB9CiAg
ICBjb25zdCBsb2NhbCA9IHJlbGF5Rm9sZGVyICE9PSAnLycgJiYgcGF0aG5hbWUuc3RhcnRzV2l0
aChyZWxheUZvbGRlcikgPyBwYXRobmFtZS5zbGljZShyZWxheUZvbGRlci5sZW5ndGggLSAxKSA6
IHBhdGhuYW1lOwogICAgaWYgKHBhY2tzLmhhbmRsZShyZXEsIHJlcywgbG9jYWwpKSByZXR1cm47
CiAgICBpZiAoaGYuaGFuZGxlKHJlcSwgcmVzLCBsb2NhbCkpIHJldHVybjsKICAgIGlmIChob2Mu
aGFuZGxlKHJlcSwgcmVzLCBsb2NhbCkpIHJldHVybjsKICAgIGlmIChnZW1pbmkuaGFuZGxlKHJl
cSwgcmVzLCBsb2NhbCkpIHJldHVybjsKICAgIGlmIChwYXRobmFtZSA9PT0gJy8nIHx8IHBhdGhu
YW1lID09PSBjb25maWcucGF0aCkgewogICAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAnY29udGVu
dC10eXBlJzogJ3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgICByZXMuZW5kKGBP
cGVuTEYyIHJlbGF5IGlzIHJ1bm5pbmcuIENvbm5lY3Qgd2l0aCBhIFdlYlNvY2tldCB0byAke2Nv
bmZpZy5wYXRofVxuYCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHJlcy53cml0ZUhlYWQoNDA0
LCB7ICdjb250ZW50LXR5cGUnOiAndGV4dC9wbGFpbjsgY2hhcnNldD11dGYtOCcgfSk7CiAgICBy
ZXMuZW5kKCdOb3QgZm91bmRcbicpOwogIH0pOwoKICAvLyBVcGxvYWRpbmcgYSBnYW1lIHBhY2sg
ZnJvbSBhIHNsb3cgbGluZSBtYXkgdGFrZSBhIHdoaWxlIChOb2RlJ3MgZGVmYXVsdCBnaXZlcyB1
cCBhZnRlciA1IG1pbnV0ZXMpLgogIHNlcnZlci5yZXF1ZXN0VGltZW91dCA9IDIgKiAzNjAwICog
MTAwMDsKCiAgY29uc3Qgd3NzID0gbmV3IFdlYlNvY2tldFNlcnZlcih7CiAgICBub1NlcnZlcjog
dHJ1ZSwKICAgIG1heFBheWxvYWQ6IGNvbmZpZy5tYXhNZXNzYWdlQnl0ZXMsCiAgICBwZXJNZXNz
YWdlRGVmbGF0ZTogZmFsc2UsIC8vIDIyLWJ5dGUgcGFja2V0czogY29tcHJlc3Npb24gb25seSBh
ZGRzIGxhdGVuY3kKICB9KTsKCiAgc2VydmVyLm9uKCd1cGdyYWRlJywgKHJlcSwgc29ja2V0LCBo
ZWFkKSA9PiB7CiAgICBjb25zdCB1cmwgPSBuZXcgVVJMKHJlcS51cmwsICdodHRwOi8vcmVsYXku
aW52YWxpZCcpOwogICAgaWYgKHVybC5wYXRobmFtZSAhPT0gY29uZmlnLnBhdGggJiYgdXJsLnBh
dGhuYW1lICE9PSAnLycpIHsKICAgICAgc29ja2V0LmVuZCgnSFRUUC8xLjEgNDA0IE5vdCBGb3Vu
ZFxyXG5Db25uZWN0aW9uOiBjbG9zZVxyXG5cclxuJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAg
IC8vIFJlcXVlc3RzIGFyZSB2YWxpZGF0ZWQgYWZ0ZXIgdGhlIHVwZ3JhZGUsIHNvIHRoZSBicm93
c2VyIHJlY2VpdmVzIGEgY2xvc2UgY29kZSBhbmQgcmVhc29uCiAgICAvLyBpbnN0ZWFkIG9mIGFu
IGFub255bW91cyBjb25uZWN0aW9uIGVycm9yLgogICAgd3NzLmhhbmRsZVVwZ3JhZGUocmVxLCBz
b2NrZXQsIGhlYWQsICh3cykgPT4gd3NzLmVtaXQoJ2Nvbm5lY3Rpb24nLCB3cywgcmVxLCB1cmwp
KTsKICB9KTsKCiAgd3NzLm9uKCdjb25uZWN0aW9uJywgKHdzLCByZXEsIHVybCkgPT4gewogICAg
d3MuaXNBbGl2ZSA9IHRydWU7CiAgICB3cy5vbigncG9uZycsICgpID0+IHsgd3MuaXNBbGl2ZSA9
IHRydWU7IH0pOwogICAgd3Mub24oJ2Vycm9yJywgKCkgPT4ge30pOyAvLyBhICdjbG9zZScgZXZl
bnQgYWx3YXlzIGZvbGxvd3MKCiAgICBpZiAoY29uZmlnLmFsbG93ZWRPcmlnaW5zLmxlbmd0aCAm
JiAhY29uZmlnLmFsbG93ZWRPcmlnaW5zLmluY2x1ZGVzKG5vcm1hbGl6ZU9yaWdpbihyZXEuaGVh
ZGVycy5vcmlnaW4pKSkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5vcmlnaW5E
ZW5pZWQpOwogICAgfQogICAgY29uc3Qgcm9sZSA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdyb2xl
Jyk7CiAgICBjb25zdCBjb2RlID0gdXJsLnNlYXJjaFBhcmFtcy5nZXQoJ3Jvb20nKSB8fCAnJzsK
ICAgIGNvbnN0IGhlcm9GaWdodGVyID0gdXJsLnNlYXJjaFBhcmFtcy5nZXQoJ2dhbWUnKSA9PT0g
J2hmJzsgLy8gYSBIZXJvIEZpZ2h0ZXIgcm9vbSAoaGYuanMpCiAgICBpZiAoIWhlcm9GaWdodGVy
ICYmICgocm9sZSAhPT0gJ2hvc3QnICYmIHJvbGUgIT09ICdqb2luJykgfHwgIVJPT01fUEFUVEVS
Ti50ZXN0KGNvZGUpKSkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5iYWRSZXF1
ZXN0KTsKICAgIH0KCiAgICBjb25zdCBhZGRyZXNzID0gY2xpZW50QWRkcmVzcyhyZXEpOwogICAg
Y29uc3QgY291bnQgPSBjb25uZWN0aW9uc1BlcklwLmdldChhZGRyZXNzKSB8fCAwOwogICAgaWYg
KGNvbmZpZy5tYXhDb25uZWN0aW9uc1BlcklwICYmIGNvdW50ID49IGNvbmZpZy5tYXhDb25uZWN0
aW9uc1BlcklwKSB7CiAgICAgIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnRvb01hbnlDb25u
ZWN0aW9ucyk7CiAgICB9CiAgICBjb25uZWN0aW9uc1BlcklwLnNldChhZGRyZXNzLCBjb3VudCAr
IDEpOwogICAgd3Mub25jZSgnY2xvc2UnLCAoKSA9PiB7CiAgICAgIGNvbnN0IGxlZnQgPSAoY29u
bmVjdGlvbnNQZXJJcC5nZXQoYWRkcmVzcykgfHwgMSkgLSAxOwogICAgICBpZiAobGVmdCA+IDAp
IGNvbm5lY3Rpb25zUGVySXAuc2V0KGFkZHJlc3MsIGxlZnQpOwogICAgICBlbHNlIGNvbm5lY3Rp
b25zUGVySXAuZGVsZXRlKGFkZHJlc3MpOwogICAgfSk7CiAgICB3cy5tZXNzYWdlQnVkZ2V0ID0g
bmV3IEJ1Y2tldChjb25maWcubWVzc2FnZXNQZXJTZWNvbmQsIGNvbmZpZy5tZXNzYWdlc1BlclNl
Y29uZCAqIDIpOwogICAgd3MuYnl0ZUJ1ZGdldCA9IG5ldyBCdWNrZXQoY29uZmlnLmJ5dGVzUGVy
U2Vjb25kLCBNYXRoLm1heChjb25maWcuYnl0ZXNQZXJTZWNvbmQsIGNvbmZpZy5tYXhNZXNzYWdl
Qnl0ZXMpICogMik7CiAgICBpZiAoaGVyb0ZpZ2h0ZXIpIHJldHVybiBoZi5jb25uZWN0KHdzLCBy
ZXEsIHVybCk7CgogICAgY29uc3QgdmVyc2lvbiA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCd2Jyk7
CiAgICBpZiAodmVyc2lvbiA9PT0gJzInKSByZXR1cm4gam9pbkdyb3VwKHdzLCByb2xlLCBjb2Rl
KTsKICAgIGlmICh2ZXJzaW9uICE9PSBudWxsICYmIHZlcnNpb24gIT09ICcxJykgcmV0dXJuIGNs
b3NlV2l0aCh3cywgQ0xPU0UuYmFkUmVxdWVzdCk7CiAgICBpZiAoZ3JvdXBzLmhhcyhjb2RlKSkg
cmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UubmV3ZXJSb29tKTsKCiAgICBsZXQgcm9vbSA9IHJv
b21zLmdldChjb2RlKTsKICAgIGlmICghcm9vbSkgewogICAgICBpZiAoY29uZmlnLm1heFJvb21z
ICYmIHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSA+PSBjb25maWcubWF4Um9vbXMpIHJldHVybiBj
bG9zZVdpdGgod3MsIENMT1NFLnNlcnZlckZ1bGwpOwogICAgICByb29tID0geyBjb2RlLCBob3N0
OiBudWxsLCBqb2luOiBudWxsLCB0aW1lcjogbnVsbCB9OwogICAgICByb29tcy5zZXQoY29kZSwg
cm9vbSk7CiAgICB9CiAgICBpZiAocm9vbVtyb2xlXSkgcmV0dXJuIGNsb3NlV2l0aCh3cywgcm9s
ZSA9PT0gJ2hvc3QnID8gQ0xPU0UuaG9zdFRha2VuIDogQ0xPU0UuZ3Vlc3RUYWtlbik7CgogICAg
cm9vbVtyb2xlXSA9IHdzOwogICAgd3Mucm9vbSA9IHJvb207CiAgICB3cy5yb2xlID0gcm9sZTsK
ICAgIHdzLnBlZXIgPSBudWxsOwogICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSwgaXNCaW5hcnkp
ID0+IG9uTWVzc2FnZSh3cywgZGF0YSwgaXNCaW5hcnkpKTsKICAgIHdzLm9uKCdjbG9zZScsICgp
ID0+IG9uQ2xvc2Uod3MpKTsKCiAgICBjb25zdCBvdGhlciA9IHJvb21bcm9sZSA9PT0gJ2hvc3Qn
ID8gJ2pvaW4nIDogJ2hvc3QnXTsKICAgIGlmIChvdGhlcikgewogICAgICBjbGVhclRpbWVvdXQo
cm9vbS50aW1lcik7CiAgICAgIHJvb20udGltZXIgPSBudWxsOwogICAgICB3cy5wZWVyID0gb3Ro
ZXI7CiAgICAgIG90aGVyLnBlZXIgPSB3czsKICAgICAgLy8gQm90aCBwZWVycyBhcmUgbGlua2Vk
IGJlZm9yZSBlaXRoZXIgbGVhcm5zIGFib3V0IGl0LCBzbyBhbnkgZGF0YSB0aGF0IGZvbGxvd3Mg
aGFzIGEgZGVzdGluYXRpb24uCiAgICAgIHNlbmRDb250cm9sKG90aGVyLCB7IHQ6ICdwYWlyZWQn
IH0pOwogICAgICBzZW5kQ29udHJvbCh3cywgeyB0OiAncGFpcmVkJyB9KTsKICAgICAgbG9nKGBy
b29tICR7Y29kZX06IHBhaXJlZGApOwogICAgfSBlbHNlIHsKICAgICAgc2VuZENvbnRyb2wod3Ms
IHsgdDogJ3dhaXRpbmcnLCByb29tOiBjb2RlIH0pOwogICAgICByb29tLnRpbWVyID0gc2V0VGlt
ZW91dCgoKSA9PiB7CiAgICAgICAgaWYgKHJvb21bcm9sZV0gPT09IHdzICYmICF3cy5wZWVyKSBj
bG9zZVdpdGgod3MsIENMT1NFLnRpbWVvdXQpOwogICAgICB9LCBjb25maWcucm9vbVdhaXRNcyk7
CiAgICAgIGxvZyhgcm9vbSAke2NvZGV9OiAke3JvbGV9IHdhaXRpbmdgKTsKICAgIH0KICB9KTsK
CiAgZnVuY3Rpb24gb25NZXNzYWdlKHdzLCBkYXRhLCBpc0JpbmFyeSkgewogICAgaWYgKCFpc0Jp
bmFyeSkgcmV0dXJuOyAvLyBvbmx5IHRoZSByZWxheSBzcGVha3MgdGV4dDsgY2xpZW50cyBzZW5k
IGdhbWUgYnl0ZXMgYXMgYmluYXJ5IGZyYW1lcwogICAgaWYgKCF3cy5wZWVyKSByZXR1cm4gY2xv
c2VXaXRoKHdzLCBDTE9TRS5lYXJseURhdGEpOwogICAgaWYgKCF3cy5tZXNzYWdlQnVkZ2V0LnRh
a2UoMSkgfHwgIXdzLmJ5dGVCdWRnZXQudGFrZShkYXRhLmxlbmd0aCkpIHsKICAgICAgbG9nKGBy
b29tICR7d3Mucm9vbS5jb2RlfTogcmF0ZSBsaW1pdGApOwogICAgICBjbG9zZVdpdGgod3MucGVl
ciwgQ0xPU0UucmF0ZUxpbWl0ZWQpOwogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5y
YXRlTGltaXRlZCk7CiAgICB9CiAgICBjb25zdCBwZWVyID0gd3MucGVlcjsKICAgIGlmIChwZWVy
LnJlYWR5U3RhdGUgIT09IFdlYlNvY2tldC5PUEVOKSByZXR1cm47CiAgICBpZiAocGVlci5idWZm
ZXJlZEFtb3VudCA+IGNvbmZpZy5tYXhCdWZmZXJlZEJ5dGVzKSB7CiAgICAgIGNsb3NlV2l0aCh3
cywgQ0xPU0Uuc2xvd1BlZXIpOwogICAgICByZXR1cm4gY2xvc2VXaXRoKHBlZXIsIENMT1NFLnNs
b3dQZWVyKTsKICAgIH0KICAgIGlmIChjb25maWcuZm9yd2FyZERlbGF5TXMgPiAwKSB7CiAgICAg
IC8vIFRpbWVycyB3aXRoIHRoZSBzYW1lIGRlbGF5IGZpcmUgaW4gdGhlIG9yZGVyIHRoZXkgd2Vy
ZSBzZXQsIHNvIHRoZSBzdHJlYW0gc3RheXMgaW4gb3JkZXIuCiAgICAgIHNldFRpbWVvdXQoKCkg
PT4geyBpZiAocGVlci5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQuT1BFTikgcGVlci5zZW5kKGRh
dGEsIHsgYmluYXJ5OiB0cnVlIH0pOyB9LCBjb25maWcuZm9yd2FyZERlbGF5TXMpOwogICAgICBy
ZXR1cm47CiAgICB9CiAgICBwZWVyLnNlbmQoZGF0YSwgeyBiaW5hcnk6IHRydWUgfSk7CiAgfQoK
ICBmdW5jdGlvbiBvbkNsb3NlKHdzKSB7CiAgICBjb25zdCByb29tID0gd3Mucm9vbTsKICAgIGlm
ICghcm9vbSkgcmV0dXJuOwogICAgaWYgKHJvb21bd3Mucm9sZV0gPT09IHdzKSByb29tW3dzLnJv
bGVdID0gbnVsbDsKICAgIGNvbnN0IHBlZXIgPSB3cy5wZWVyOwogICAgd3MucGVlciA9IG51bGw7
CiAgICBpZiAocGVlcikgewogICAgICAvLyBBIGxvY2tzdGVwIG1hdGNoIGNhbm5vdCBjb250aW51
ZSB3aXRoIG9uZSBwbGF5ZXIsIHNvIHRoZSByb29tIGVuZHMgd2l0aCB0aGUgcGFpciBhbmQgaXRz
CiAgICAgIC8vIGNvZGUgaXMgZnJlZSBhZ2FpbiBhdCBvbmNlICh0aGUgaG9zdCBjYW4gcHJlc3Mg
SG9zdCBhZ2FpbiB3aXRoIHRoZSBzYW1lIGNvZGUpLgogICAgICBwZWVyLnBlZXIgPSBudWxsOwog
ICAgICByb29tLmhvc3QgPSByb29tLmpvaW4gPSBudWxsOwogICAgICBjbG9zZVdpdGgocGVlciwg
Q0xPU0UucGVlckxlZnQpOwogICAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBlbmRlZGApOwog
ICAgfQogICAgaWYgKCFyb29tLmhvc3QgJiYgIXJvb20uam9pbikgewogICAgICBjbGVhclRpbWVv
dXQocm9vbS50aW1lcik7CiAgICAgIGlmIChyb29tcy5nZXQocm9vbS5jb2RlKSA9PT0gcm9vbSkg
cm9vbXMuZGVsZXRlKHJvb20uY29kZSk7CiAgICB9CiAgfQoKICAvLyAtLS0tIFJvb21zIChwcm90
b2NvbCAyKSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIC8vCiAgLy8gVXAgdG8gY29uZmlnLnJvb21QbGF5ZXJz
IGdhbWVzIHNoYXJlIGEgcm9vbS4gRWFjaCBzYXlzIEhFTExPIHdpdGggaXRzIHByb2ZpbGUgKGVu
Z2luZSwgc2NyaXB0cywKICAvLyBtb2RzIGFuZCBnYW1lIGRhdGE6IHRoZSBmaXJzdCBIRUxMTyBz
ZXRzIHRoZSByb29tJ3MsIGFuZCBhIGdhbWUgd2l0aCBhbm90aGVyIG9uZSBpcyB0dXJuZWQgYXdh
eSkKICAvLyBhbmQgaXRzIHBsYXllciBuYW1lczsgTE9CQlkgbGlzdHMgdGhlIHBsYXllcnMgdG8g
ZXZlcnlvbmUuIFRoZSBob3N0IHNlbmRzIFNUQVJUIHdpdGggdGhlIHNldHVwCiAgLy8gZXZlcnkg
Z2FtZSBuZWVkcyAodGhlIHJhbmRvbSB0YWJsZSk7IFNUQVJURUQgZ2l2ZXMgZXZlcnkgZ2FtZSB0
aGUgZmluYWwgbGlzdCBvZiBwbGF5ZXJzLCB3aG9zZQogIC8vIHBvc2l0aW9uIGlzIHRoZSBwbGF5
ZXIncyBpbmRleCwgYW5kIG9uY2UgZXZlcnkgZ2FtZSBpcyBSRUFEWSAob3IgYWZ0ZXIgc3RhcnRH
cmFjZU1zKSB0aGUgYmVhdAogIC8vIGJlZ2luczogZXZlcnkgdGlja01zLCBGUkFNRSB3aXRoIHRo
ZSBpbnB1dCBvZiBlYWNoIHBsYXllci4gVGhlIGlucHV0cyBhIHBsYXllciBzZW50IHNpbmNlIHRo
ZQogIC8vIGxhc3QgYmVhdCBhcmUgbWVyZ2VkIChPUjogYSBrZXkgaGVsZCBpbiBhbnkgb2YgdGhl
bSBpcyBoZWxkLCBzbyBhIHF1aWNrIHRhcCBpcyBuZXZlciBsb3N0KSwgYW5kCiAgLy8gdGhlIG5l
d2VzdCBvZiB0aGVtIHN0YXlzIGhpcyBpbnB1dCBvbiB0aGUgZm9sbG93aW5nIGJlYXRzIHdoaWxl
IG5vIG5ld3MgY29tZXMsIHdpdGhvdXQgaXRzCiAgLy8gb25lLXNob3QgZXZlbnRzIChieXRlIDAp
OyBhZnRlciByZXBlYXRMaW1pdCBiZWF0cyB3aXRob3V0IG5ld3MgdGhlIHBsYXllciBjb3VudHMg
YXMgaGF2aW5nCiAgLy8gcmVsZWFzZWQgZXZlcnkga2V5LiBHYW1lcyBzZW5kIHRoZWlyIGlucHV0
IGFzIHNvb24gYXMgaXQgY2hhbmdlcy4gRXZlcnkgZ2FtZSBydW5zIGV4YWN0bHkgdGhlCiAgLy8g
ZnJhbWVzIGl0IHJlY2VpdmVzLCBpbiBvcmRlciwgc28gYWxsIHN0YXkgaW4gc3RlcCB3aGF0ZXZl
ciB0aGVpciBvd24gY29ubmVjdGlvbiBkb2VzOiBhIGRpc3RhbnQKICAvLyBwbGF5ZXIncyBrZXlz
IHRha2UgZWZmZWN0IGEgbGl0dGxlIGxhdGVyIGFuZCBoZSBzZWVzIHRoZSBnYW1lIGEgbGl0dGxl
IGxhdGVyLCBidXQgbm9ib2R5IHdhaXRzCiAgLy8gZm9yIGhpbS4gQSBnYW1lIHRoYXQgY2Fubm90
IGtlZXAgdXAgd2l0aCB0aGUgZnJhbWVzIGlzIGRyb3BwZWQsIGFuZCB0aGUgb3RoZXJzIGdvIG9u
LgogIC8vCiAgLy8gQmluYXJ5IG1lc3NhZ2VzLCBib3RoIHdheXM6IGtpbmQgKDEgYnl0ZSksIHBh
eWxvYWQgbGVuZ3RoICgyIGJ5dGVzLCBsaXR0bGUgZW5kaWFuKSwgcGF5bG9hZC4KICAvLyBBIFdl
YlNvY2tldCBtZXNzYWdlIG1heSBjYXJyeSBzZXZlcmFsLiBHYW1lIHRvIHJlbGF5OgogIC8vICAg
SEVMTE8gICAweDAxICBwcm9maWxlIGxlbmd0aCAoMSksIHByb2ZpbGUsIGluZm8gKG5hbWVzOyBh
dCBtb3N0IDY0IGJ5dGVzKQogIC8vICAgU1RBUlQgICAweDAyICBzZXR1cCAoYXQgbW9zdCA4IEtp
Qik6IHRoZSBob3N0LCBvbmNlIHR3byBwbGF5ZXJzIG9yIG1vcmUgc2FpZCBoZWxsbwogIC8vICAg
SU5QVVQgICAweDAzICBpbnB1dCAoYXQgbW9zdCAxNiBieXRlczsgYnl0ZSAwIGhvbGRzIG9uZS1z
aG90IGV2ZW50cyksIGFmdGVyIFNUQVJURUQKICAvLyAgIFJFQURZICAgMHgwNCAgZW1wdHk6IFNU
QVJURUQgaXMgYXBwbGllZAogIC8vICAgQ0hFQ0sgICAweDA1ICBmcmFtZSAoNCksIGhhc2ggKDIp
OiBwYXNzZWQgb24gdG8gdGhlIG90aGVycywgd2hpY2ggY29tcGFyZSBpdCB3aXRoIHRoZWlyIG93
bgogIC8vIFJlbGF5IHRvIGdhbWU6CiAgLy8gICBXRUxDT01FIDB4ODEgIGlkICgxKSwgZmxhZ3Mg
KDE7IGJpdCAwOiBob3N0KSwgbW9zdCBwbGF5ZXJzICgxKSwgYmVhdCBpbiBtcyAoMSksCiAgLy8g
ICAgICAgICAgICAgICAgIHJvb20gY29kZSBsZW5ndGggKDEpLCByb29tIGNvZGUKICAvLyAgIExP
QkJZICAgMHg4MiAgY291bnQgKDEpOyBwZXIgcGxheWVyOiBpZCAoMSksIGZsYWdzICgxKSwgaW5m
byBsZW5ndGggKDEpLCBpbmZvCiAgLy8gICBTVEFSVEVEIDB4ODMgIHRoZSBwbGF5ZXJzIGFzIGlu
IExPQkJZLCB0aGVuIHNldHVwIGxlbmd0aCAoMiksIHNldHVwCiAgLy8gICBGUkFNRSAgIDB4ODQg
IGZyYW1lICg0KSwgY291bnQgKDEpLCBmcmVzaCBtYXNrICgxKSwgcHJlc2VudCBtYXNrICgxKTsK
ICAvLyAgICAgICAgICAgICAgICAgcGVyIHBsYXllcjogaW5wdXQgbGVuZ3RoICgxKSwgaW5wdXQK
ICAvLyAgIENIRUNLRUQgMHg4NSAgaW5kZXggKDEpLCBmcmFtZSAoNCksIGhhc2ggKDIpCiAgLy8g
ICBMRUZUICAgIDB4ODYgIGluZGV4ICgxKTogdGhhdCBwbGF5ZXIgaXMgZ29uZTsgaGlzIGlucHV0
IHN0YXlzIGVtcHR5CiAgLy8gVGV4dCAoSlNPTikgbWVzc2FnZXMgYXJlIGZvciB0aGUgcGFnZSBh
cm91bmQgdGhlIGdhbWU6IHsidCI6IndlbGNvbWUiLCJ2IjoyLCJyb29tIjoi4oCmIiwiaG9zdCI6
dHJ1ZSwKICAvLyAiaWQiOjIsImRpcmVjdCI6e+KApn19IGFuZCB7InQiOiJyb29tIiwicGxheWVy
cyI6Mywic3RhcnRlZCI6ZmFsc2V9LgogIC8vCiAgLy8gRGlyZWN0IGNvbm5lY3Rpb25zIChkaXN0
L3dlYi9vbmxpbmUuanMpOiB0aGUgcGFnZXMgb2YgYSByb29tIG1heSBjb25uZWN0IHRvIHRoZSBo
b3N0J3MgcGFnZQogIC8vIGRpcmVjdGx5IChXZWJSVEMpLCB0aGUgcmVsYXkgcGFzc2luZyBvbiB3
aGF0IHRoZXkgc2F5IHRvIHNldCBpdCB1cCwgYW5kIHRoZSBob3N0J3MgcGFnZSBtYXkga2VlcAog
IC8vIHRoZSBiZWF0IGl0c2VsZiDigJQgb24gYSBMQU4sIG9yIHdoZXJldmVyIGV2ZXJ5IHBsYXll
ciByZWFjaGVzIHRoZSBob3N0IHNvb25lciB0aGFuIHRoZSByZWxheS4gUGFnZQogIC8vIHRvIHJl
bGF5LCB0ZXh0OiB7InQiOiJzaWduYWwiLCJ0byI6Imhvc3QifDxpZD4sImRhdGEiOnvigKZ9fSAo
cGFzc2VkIG9uIGFzIHsidCI6InNpZ25hbCIsImZyb20iOjxpZD4sCiAgLy8gImRhdGEiOnvigKZ9
fSwgYmV0d2VlbiB0aGUgaG9zdCBhbmQgYW5vdGhlciBwbGF5ZXIgb25seSksIHsidCI6InBpbmci
LCJuIjo8bnVtYmVyPn0gKGFuc3dlcmVkIHdpdGgKICAvLyB7InQiOiJwb25nIiwibiI64oCmfSks
IGFuZCBmcm9tIHRoZSBob3N0IGJlZm9yZSBTVEFSVCB7InQiOiJiZWF0IiwiYnkiOiJob3N0Inwi
cmVsYXkifS4gV2hlbiB0aGUKICAvLyBob3N0IGtlZXBzIHRoZSBiZWF0LCBTVEFSVCBpcyBmb2xs
b3dlZCBieSB7InQiOiJiZWF0IiwiYnkiOiJob3N0IiwiaG9zdCI6PGlkPn0gdG8gZXZlcnkgcGFn
ZSBiZWZvcmUKICAvLyBTVEFSVEVEOyB0aGUgcmVsYXkgdGhlbiBzZW5kcyBubyBmcmFtZXMsIHRh
a2VzIG5vIElOUFVULCBSRUFEWSBvciBDSEVDSywgdGVsbHMgdGhlIGhvc3QncyBwYWdlCiAgLy8g
eyJ0IjoibGVmdCIsImlkIjo8aWQ+fSB3aGVuIGEgcGxheWVyJ3MgY29ubmVjdGlvbiB0byBpdCBj
bG9zZXMgKHRoZSBob3N0J3MgcGFnZSBzZW5kcyBMRUZUIGFtb25nIGl0cwogIC8vIGZyYW1lcyks
IGFuZCBlbmRzIHRoZSByb29tIHdoZW4gdGhlIGhvc3QgbGVhdmVzLgoKICBmdW5jdGlvbiBqb2lu
R3JvdXAod3MsIHJvbGUsIGNvZGUpIHsKICAgIGlmIChyb29tcy5oYXMoY29kZSkpIHJldHVybiBj
bG9zZVdpdGgod3MsIENMT1NFLmNvZGVJblVzZSk7CiAgICBsZXQgcm9vbSA9IGdyb3Vwcy5nZXQo
Y29kZSk7CiAgICBpZiAoIXJvb20pIHsKICAgICAgaWYgKGNvbmZpZy5tYXhSb29tcyAmJiByb29t
cy5zaXplICsgZ3JvdXBzLnNpemUgPj0gY29uZmlnLm1heFJvb21zKSByZXR1cm4gY2xvc2VXaXRo
KHdzLCBDTE9TRS5zZXJ2ZXJGdWxsKTsKICAgICAgcm9vbSA9IHsKICAgICAgICBjb2RlLCBtZW1i
ZXJzOiBbXSwgaG9zdDogbnVsbCwgbmV4dElkOiAxLCBwcm9maWxlOiBudWxsLCBzdGFydGVkOiBm
YWxzZSwgb3JkZXI6IFtdLCBmcmFtZTogMCwKICAgICAgICB0aWNraW5nOiBmYWxzZSwgdGlja3M6
IDAsIHRpY2tTdGFydDogMCwgbG9iYnlUaW1lcjogbnVsbCwgZ3JhY2VUaW1lcjogbnVsbCwgdGlj
a1RpbWVyOiBudWxsLCBlbmRlZDogZmFsc2UsCiAgICAgICAgYmVhdEJ5OiAncmVsYXknLCAvLyBv
ciAnaG9zdCc6IHRoZSBob3N0J3MgcGFnZSBrZWVwcyB0aGUgYmVhdCAoZGlyZWN0IGNvbm5lY3Rp
b25zKQogICAgICB9OwogICAgICBncm91cHMuc2V0KGNvZGUsIHJvb20pOwogICAgICByb29tLmxv
YmJ5VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IGVuZEdyb3VwKHJvb20sIENMT1NFLm5vdFN0YXJ0
ZWQpLCBjb25maWcubG9iYnlXYWl0TXMpOwogICAgICBsb2coYHJvb20gJHtjb2RlfTogb3BlbmVk
YCk7CiAgICB9CiAgICBpZiAocm9vbS5zdGFydGVkKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9T
RS5zdGFydGVkKTsKICAgIGlmIChyb2xlID09PSAnaG9zdCcgJiYgcm9vbS5ob3N0KSByZXR1cm4g
Y2xvc2VXaXRoKHdzLCBDTE9TRS5ob3N0VGFrZW4pOwogICAgaWYgKHJvb20ubWVtYmVycy5sZW5n
dGggPj0gY29uZmlnLnJvb21QbGF5ZXJzKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5yb29t
RnVsbCk7CiAgICB3aGlsZSAocm9vbS5tZW1iZXJzLnNvbWUoKG90aGVyKSA9PiBvdGhlci5pZCA9
PT0gcm9vbS5uZXh0SWQpKSByb29tLm5leHRJZCA9IChyb29tLm5leHRJZCAlIDI1NSkgKyAxOwog
ICAgY29uc3QgbWVtYmVyID0gewogICAgICB3cywgcm9vbSwgaWQ6IHJvb20ubmV4dElkLCBob3N0
OiByb2xlID09PSAnaG9zdCcsIGluZm86IG51bGwsIHJlYWR5OiBmYWxzZSwKICAgICAgcXVldWU6
IFtdLCBsYXN0OiBFTVBUWSwgcmVwZWF0czogMCwgcHJlc2VudDogdHJ1ZSwgaW5kZXg6IC0xLAog
ICAgfTsKICAgIHJvb20ubmV4dElkID0gKHJvb20ubmV4dElkICUgMjU1KSArIDE7CiAgICByb29t
Lm1lbWJlcnMucHVzaChtZW1iZXIpOwogICAgaWYgKG1lbWJlci5ob3N0KSByb29tLmhvc3QgPSBt
ZW1iZXI7CiAgICB3cy5vbignbWVzc2FnZScsIChkYXRhLCBpc0JpbmFyeSkgPT4gb25Hcm91cE1l
c3NhZ2UobWVtYmVyLCBkYXRhLCBpc0JpbmFyeSkpOwogICAgd3Mub24oJ2Nsb3NlJywgKCkgPT4g
bGVhdmVHcm91cChtZW1iZXIpKTsKICAgIC8vIChgZGlyZWN0YDogdGhpcyByZWxheSBwYXNzZXMg
b24gZGlyZWN0IGNvbm5lY3Rpb24gc2V0LXVwcywgYW5kIHRoZSBob3N0J3MgcGFnZSBrZWVwcyB0
aGUgYmVhdCBieQogICAgLy8gdGhlc2UgcnVsZXMgd2hlbiBpdCB0YWtlcyBpdCBvdmVyLikKICAg
IHNlbmRDb250cm9sKHdzLCB7CiAgICAgIHQ6ICd3ZWxjb21lJywgdjogMiwgcm9vbTogY29kZSwg
aG9zdDogbWVtYmVyLmhvc3QsIGlkOiBtZW1iZXIuaWQsCiAgICAgIGRpcmVjdDogeyByZXBlYXQ6
IGNvbmZpZy5yZXBlYXRMaW1pdCwgZ3JhY2U6IGNvbmZpZy5zdGFydEdyYWNlTXMsIGJ1ZmZlcmVk
OiBjb25maWcubWF4QnVmZmVyZWRCeXRlcyB9LAogICAgfSk7CiAgICBjb25zdCB3ZWxjb21lID0g
QnVmZmVyLmFsbG9jKDUgKyBjb2RlLmxlbmd0aCk7CiAgICB3ZWxjb21lWzBdID0gbWVtYmVyLmlk
OwogICAgLy8gRmxhZ3M6IGJpdCAwIHRoZSBob3N0OyBiaXRzIDEtMiB0aGUgYmVhdCdzIHRoaXJk
cyBvZiBhIG1pbGxpc2Vjb25kIGJleW9uZCB3ZWxjb21lWzNdLgogICAgY29uc3QgdGhpcmRzID0g
TWF0aC5yb3VuZChjb25maWcudGlja01zICogMyk7CiAgICB3ZWxjb21lWzFdID0gKG1lbWJlci5o
b3N0ID8gMSA6IDApIHwgKCh0aGlyZHMgJSAzKSA8PCAxKTsKICAgIHdlbGNvbWVbMl0gPSBjb25m
aWcucm9vbVBsYXllcnM7CiAgICB3ZWxjb21lWzNdID0gTWF0aC5taW4oMjU1LCBNYXRoLmZsb29y
KHRoaXJkcyAvIDMpKTsKICAgIHdlbGNvbWVbNF0gPSBjb2RlLmxlbmd0aDsKICAgIHdlbGNvbWUu
d3JpdGUoY29kZSwgNSwgJ2xhdGluMScpOwogICAgc2VuZEJpbmFyeSh3cywgcGFja2V0KEtJTkQu
d2VsY29tZSwgd2VsY29tZSkpOwogICAgc2VuZExvYmJ5KHJvb20sIG1lbWJlcik7CiAgICBsb2co
YHJvb20gJHtjb2RlfTogJHtyb2xlfSBhcnJpdmVkICgke3Jvb20ubWVtYmVycy5sZW5ndGh9IGlu
IHRoZSByb29tKWApOwogIH0KCiAgLy8gVGhlIHBsYXllcnMgd2hvIHNhaWQgaGVsbG8sIHRoZSBo
b3N0IGZpcnN0LCB0aGVuIGluIHRoZSBvcmRlciB0aGV5IGNhbWUuCiAgZnVuY3Rpb24gbGlzdGVk
KHJvb20pIHsKICAgIGNvbnN0IGtub3duID0gcm9vbS5tZW1iZXJzLmZpbHRlcigobWVtYmVyKSA9
PiBtZW1iZXIuaW5mbyk7CiAgICByZXR1cm4ga25vd24uZmlsdGVyKChtZW1iZXIpID0+IG1lbWJl
ci5ob3N0KS5jb25jYXQoa25vd24uZmlsdGVyKChtZW1iZXIpID0+ICFtZW1iZXIuaG9zdCkpOwog
IH0KCiAgZnVuY3Rpb24gZGVzY3JpYmVQbGF5ZXJzKGxpc3QpIHsKICAgIGNvbnN0IHBhcnRzID0g
W0J1ZmZlci5mcm9tKFtsaXN0Lmxlbmd0aF0pXTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIGxp
c3QpIHBhcnRzLnB1c2goQnVmZmVyLmZyb20oW21lbWJlci5pZCwgbWVtYmVyLmhvc3QgPyAxIDog
MCwgbWVtYmVyLmluZm8ubGVuZ3RoXSksIG1lbWJlci5pbmZvKTsKICAgIHJldHVybiBCdWZmZXIu
Y29uY2F0KHBhcnRzKTsKICB9CgogIGZ1bmN0aW9uIHNlbmRMb2JieShyb29tLCBvbmx5KSB7CiAg
ICBjb25zdCBsaXN0ID0gbGlzdGVkKHJvb20pOwogICAgY29uc3QgbWVzc2FnZSA9IHBhY2tldChL
SU5ELmxvYmJ5LCBkZXNjcmliZVBsYXllcnMobGlzdCkpOwogICAgZm9yIChjb25zdCBtZW1iZXIg
b2Ygb25seSA/IFtvbmx5XSA6IHJvb20ubWVtYmVycykgewogICAgICBzZW5kQmluYXJ5KG1lbWJl
ci53cywgbWVzc2FnZSk7CiAgICAgIHNlbmRDb250cm9sKG1lbWJlci53cywgeyB0OiAncm9vbScs
IHBsYXllcnM6IGxpc3QubGVuZ3RoLCBzdGFydGVkOiBmYWxzZSB9KTsKICAgIH0KICB9CgogIGZ1
bmN0aW9uIG9uR3JvdXBNZXNzYWdlKG1lbWJlciwgZGF0YSwgaXNCaW5hcnkpIHsKICAgIGNvbnN0
IHsgd3MsIHJvb20gfSA9IG1lbWJlcjsKICAgIGlmIChyb29tLmVuZGVkIHx8ICFyb29tLm1lbWJl
cnMuaW5jbHVkZXMobWVtYmVyKSkgcmV0dXJuOwogICAgaWYgKCF3cy5tZXNzYWdlQnVkZ2V0LnRh
a2UoMSkgfHwgIXdzLmJ5dGVCdWRnZXQudGFrZShkYXRhLmxlbmd0aCkpIHsKICAgICAgbG9nKGBy
b29tICR7cm9vbS5jb2RlfTogcmF0ZSBsaW1pdGApOwogICAgICByZXR1cm4gY2xvc2VXaXRoKHdz
LCBDTE9TRS5yYXRlTGltaXRlZCk7CiAgICB9CiAgICBpZiAoIWlzQmluYXJ5KSByZXR1cm4gaGFu
ZGxlR3JvdXBUZXh0KG1lbWJlciwgZGF0YSk7CiAgICBsZXQgYXQgPSAwOwogICAgd2hpbGUgKGF0
IDwgZGF0YS5sZW5ndGgpIHsKICAgICAgaWYgKGRhdGEubGVuZ3RoIC0gYXQgPCAzKSByZXR1cm4g
Y2xvc2VXaXRoKHdzLCBDTE9TRS5wcm90b2NvbCk7CiAgICAgIGNvbnN0IGtpbmQgPSBkYXRhW2F0
XTsKICAgICAgY29uc3QgbGVuZ3RoID0gZGF0YS5yZWFkVUludDE2TEUoYXQgKyAxKTsKICAgICAg
aWYgKGRhdGEubGVuZ3RoIC0gYXQgLSAzIDwgbGVuZ3RoKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBD
TE9TRS5wcm90b2NvbCk7CiAgICAgIGNvbnN0IHByb2JsZW0gPSBoYW5kbGVHcm91cE1lc3NhZ2Uo
bWVtYmVyLCBraW5kLCBkYXRhLnN1YmFycmF5KGF0ICsgMywgYXQgKyAzICsgbGVuZ3RoKSk7CiAg
ICAgIGlmIChwcm9ibGVtKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBwcm9ibGVtKTsKICAgICAgaWYg
KHJvb20uZW5kZWQgfHwgIXJvb20ubWVtYmVycy5pbmNsdWRlcyhtZW1iZXIpKSByZXR1cm47CiAg
ICAgIGF0ICs9IDMgKyBsZW5ndGg7CiAgICB9CiAgfQoKICAvLyBBIHBhZ2UncyB0ZXh0IG1lc3Nh
Z2UgKGRpcmVjdCBjb25uZWN0aW9ucywgc2VlIGFib3ZlKTsgYW55dGhpbmcgZWxzZSBpcyBpZ25v
cmVkLgogIGZ1bmN0aW9uIGhhbmRsZUdyb3VwVGV4dChtZW1iZXIsIGRhdGEpIHsKICAgIGNvbnN0
IHJvb20gPSBtZW1iZXIucm9vbTsKICAgIGlmIChkYXRhLmxlbmd0aCA+IFNJR05BTF9MSU1JVCkg
cmV0dXJuIG51bGw7CiAgICBsZXQgbWVzc2FnZTsKICAgIHRyeSB7IG1lc3NhZ2UgPSBKU09OLnBh
cnNlKGRhdGEudG9TdHJpbmcoJ3V0ZjgnKSk7IH0gY2F0Y2ggKGVycm9yKSB7IHJldHVybiBudWxs
OyB9CiAgICBpZiAoIW1lc3NhZ2UgfHwgdHlwZW9mIG1lc3NhZ2UgIT09ICdvYmplY3QnKSByZXR1
cm4gbnVsbDsKICAgIGlmIChtZXNzYWdlLnQgPT09ICdwaW5nJykgewogICAgICBpZiAoTnVtYmVy
LmlzRmluaXRlKG1lc3NhZ2UubikpIHNlbmRDb250cm9sKG1lbWJlci53cywgeyB0OiAncG9uZycs
IG46IG1lc3NhZ2UubiB9KTsKICAgIH0gZWxzZSBpZiAobWVzc2FnZS50ID09PSAnc2lnbmFsJykg
ewogICAgICBpZiAoIW1lc3NhZ2UuZGF0YSB8fCB0eXBlb2YgbWVzc2FnZS5kYXRhICE9PSAnb2Jq
ZWN0JykgcmV0dXJuIG51bGw7CiAgICAgIC8vIEJldHdlZW4gdGhlIGhvc3QgYW5kIGFub3RoZXIg
cGxheWVyIG9ubHkuCiAgICAgIGNvbnN0IHRhcmdldCA9IG1lc3NhZ2UudG8gPT09ICdob3N0JyA/
IHJvb20uaG9zdCA6IHJvb20ubWVtYmVycy5maW5kKChvdGhlcikgPT4gb3RoZXIuaWQgPT09IG1l
c3NhZ2UudG8pOwogICAgICBpZiAoIXRhcmdldCB8fCB0YXJnZXQgPT09IG1lbWJlciB8fCAoIW1l
bWJlci5ob3N0ICYmICF0YXJnZXQuaG9zdCkpIHJldHVybiBudWxsOwogICAgICBzZW5kQ29udHJv
bCh0YXJnZXQud3MsIHsgdDogJ3NpZ25hbCcsIGZyb206IG1lbWJlci5pZCwgZGF0YTogbWVzc2Fn
ZS5kYXRhIH0pOwogICAgfSBlbHNlIGlmIChtZXNzYWdlLnQgPT09ICdiZWF0JykgewogICAgICBp
ZiAobWVtYmVyLmhvc3QgJiYgIXJvb20uc3RhcnRlZCkgcm9vbS5iZWF0QnkgPSBtZXNzYWdlLmJ5
ID09PSAnaG9zdCcgPyAnaG9zdCcgOiAncmVsYXknOwogICAgfQogICAgcmV0dXJuIG51bGw7CiAg
fQoKICAvLyBSZXR1cm5zIHRoZSBjbG9zZSBjb2RlIGFuZCByZWFzb24gZm9yIGEgbWVzc2FnZSB0
aGUgZ2FtZSBzaG91bGQgbm90IGhhdmUgc2VudC4KICBmdW5jdGlvbiBoYW5kbGVHcm91cE1lc3Nh
Z2UobWVtYmVyLCBraW5kLCBwYXlsb2FkKSB7CiAgICBjb25zdCByb29tID0gbWVtYmVyLnJvb207
CiAgICAvLyBUaGUgaG9zdCdzIHBhZ2Uga2VlcHMgdGhlIGJlYXQ6IHRoZSBnYW1lcycgSU5QVVQs
IFJFQURZIGFuZCBDSEVDSyBnbyB0byBpdCwgbm90IGhlcmUuCiAgICBpZiAocm9vbS5zdGFydGVk
ICYmIHJvb20uYmVhdEJ5ID09PSAnaG9zdCcgJiYgKGtpbmQgPT09IEtJTkQuaW5wdXQgfHwga2lu
ZCA9PT0gS0lORC5yZWFkeSB8fCBraW5kID09PSBLSU5ELmNoZWNrKSkgcmV0dXJuIG51bGw7CiAg
ICBpZiAoa2luZCA9PT0gS0lORC5oZWxsbykgewogICAgICBpZiAobWVtYmVyLmluZm8gfHwgcm9v
bS5zdGFydGVkIHx8IHBheWxvYWQubGVuZ3RoIDwgMSkgcmV0dXJuIENMT1NFLnByb3RvY29sOwog
ICAgICBjb25zdCBsZW5ndGggPSBwYXlsb2FkWzBdOwogICAgICBpZiAoIWxlbmd0aCB8fCBsZW5n
dGggPiBST09NX0xJTUlUUy5wcm9maWxlIHx8IHBheWxvYWQubGVuZ3RoIDwgMSArIGxlbmd0aCkg
cmV0dXJuIENMT1NFLnByb3RvY29sOwogICAgICBjb25zdCBwcm9maWxlID0gQnVmZmVyLmZyb20o
cGF5bG9hZC5zdWJhcnJheSgxLCAxICsgbGVuZ3RoKSk7CiAgICAgIGNvbnN0IGluZm8gPSBCdWZm
ZXIuZnJvbShwYXlsb2FkLnN1YmFycmF5KDEgKyBsZW5ndGgpKTsKICAgICAgaWYgKGluZm8ubGVu
Z3RoID4gUk9PTV9MSU1JVFMuaW5mbykgcmV0dXJuIENMT1NFLnByb3RvY29sOwogICAgICBpZiAo
cm9vbS5wcm9maWxlICYmICFyb29tLnByb2ZpbGUuZXF1YWxzKHByb2ZpbGUpKSByZXR1cm4gQ0xP
U0UubWlzbWF0Y2g7CiAgICAgIHJvb20ucHJvZmlsZSA9IHJvb20ucHJvZmlsZSB8fCBwcm9maWxl
OwogICAgICBtZW1iZXIuaW5mbyA9IGluZm87CiAgICAgIHNlbmRMb2JieShyb29tKTsKICAgICAg
cmV0dXJuIG51bGw7CiAgICB9CiAgICBpZiAoa2luZCA9PT0gS0lORC5zdGFydCkgewogICAgICBp
ZiAoIW1lbWJlci5ob3N0IHx8ICFtZW1iZXIuaW5mbyB8fCByb29tLnN0YXJ0ZWQgfHwgcGF5bG9h
ZC5sZW5ndGggPiBST09NX0xJTUlUUy5zZXR1cCkgcmV0dXJuIENMT1NFLnByb3RvY29sOwogICAg
ICAvLyBTb21lYm9keSBsZWZ0IGp1c3QgYmVmb3JlOiB0aGUgaG9zdCBzZWVzIHRoZSBsaXN0IGFn
YWluIGluc3RlYWQuCiAgICAgIGlmIChsaXN0ZWQocm9vbSkubGVuZ3RoIDwgMikgc2VuZExvYmJ5
KHJvb20sIG1lbWJlcik7CiAgICAgIGVsc2Ugc3RhcnRHcm91cChyb29tLCBCdWZmZXIuZnJvbShw
YXlsb2FkKSk7CiAgICAgIHJldHVybiBudWxsOwogICAgfQogICAgaWYgKGtpbmQgPT09IEtJTkQu
aW5wdXQpIHsKICAgICAgaWYgKCFyb29tLnN0YXJ0ZWQgfHwgbWVtYmVyLmluZGV4IDwgMCB8fCBw
YXlsb2FkLmxlbmd0aCA+IFJPT01fTElNSVRTLmlucHV0KSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7
CiAgICAgIG1lbWJlci5xdWV1ZS5wdXNoKEJ1ZmZlci5mcm9tKHBheWxvYWQpKTsKICAgICAgLy8g
RmFyIG1vcmUgdGhhbiBhIGJlYXQncyB3b3J0aCAodGhlIHJhdGUgbGltaXQgYWxsb3dzIGJ1cnN0
cyk6IGZvbGQgdGhlbSwga2VlcGluZyB0aGUgbmV3ZXN0IGxhc3QuCiAgICAgIGlmIChtZW1iZXIu
cXVldWUubGVuZ3RoID4gUk9PTV9MSU1JVFMucXVldWUpIG1lbWJlci5xdWV1ZSA9IFttZXJnZUlu
cHV0cyhtZW1iZXIucXVldWUuc2xpY2UoMCwgLTEpKSwgbWVtYmVyLnF1ZXVlLmF0KC0xKV07CiAg
ICAgIHJldHVybiBudWxsOwogICAgfQogICAgaWYgKGtpbmQgPT09IEtJTkQucmVhZHkpIHsKICAg
ICAgaWYgKCFyb29tLnN0YXJ0ZWQgfHwgbWVtYmVyLmluZGV4IDwgMCB8fCBwYXlsb2FkLmxlbmd0
aCkgcmV0dXJuIENMT1NFLnByb3RvY29sOwogICAgICBtZW1iZXIucmVhZHkgPSB0cnVlOwogICAg
ICBpZiAocm9vbS5vcmRlci5ldmVyeSgob3RoZXIpID0+IG90aGVyLnJlYWR5IHx8ICFvdGhlci5w
cmVzZW50KSkgc3RhcnRCZWF0KHJvb20pOwogICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAgIGlm
IChraW5kID09PSBLSU5ELmNoZWNrKSB7CiAgICAgIGlmICghcm9vbS5zdGFydGVkIHx8IG1lbWJl
ci5pbmRleCA8IDAgfHwgcGF5bG9hZC5sZW5ndGggIT09IDYpIHJldHVybiBDTE9TRS5wcm90b2Nv
bDsKICAgICAgY29uc3QgbWVzc2FnZSA9IHBhY2tldChLSU5ELmNoZWNrZWQsIEJ1ZmZlci5jb25j
YXQoW0J1ZmZlci5mcm9tKFttZW1iZXIuaW5kZXhdKSwgcGF5bG9hZF0pKTsKICAgICAgZm9yIChj
b25zdCBvdGhlciBvZiByb29tLm9yZGVyKSBpZiAob3RoZXIgIT09IG1lbWJlciAmJiBvdGhlci5w
cmVzZW50KSBzZW5kQmluYXJ5KG90aGVyLndzLCBtZXNzYWdlKTsKICAgICAgcmV0dXJuIG51bGw7
CiAgICB9CiAgICByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgfQoKICBmdW5jdGlvbiBzdGFydEdy
b3VwKHJvb20sIHNldHVwKSB7CiAgICBjbGVhclRpbWVvdXQocm9vbS5sb2JieVRpbWVyKTsKICAg
IHJvb20uc3RhcnRlZCA9IHRydWU7CiAgICByb29tLm9yZGVyID0gbGlzdGVkKHJvb20pOwogICAg
cm9vbS5vcmRlci5mb3JFYWNoKChtZW1iZXIsIGluZGV4KSA9PiB7IG1lbWJlci5pbmRleCA9IGlu
ZGV4OyB9KTsKICAgIC8vIEEgZ2FtZSBzdGlsbCBjb25uZWN0aW5nIGhhcyBtaXNzZWQgdGhlIHN0
YXJ0LgogICAgZm9yIChjb25zdCBtZW1iZXIgb2Ygcm9vbS5tZW1iZXJzKSBpZiAoIW1lbWJlci5p
bmZvKSBjbG9zZVdpdGgobWVtYmVyLndzLCBDTE9TRS5zdGFydGVkKTsKICAgIGNvbnN0IGxlbmd0
aCA9IEJ1ZmZlci5hbGxvYygyKTsKICAgIGxlbmd0aC53cml0ZVVJbnQxNkxFKHNldHVwLmxlbmd0
aCwgMCk7CiAgICBjb25zdCBtZXNzYWdlID0gcGFja2V0KEtJTkQuc3RhcnRlZCwgQnVmZmVyLmNv
bmNhdChbZGVzY3JpYmVQbGF5ZXJzKHJvb20ub3JkZXIpLCBsZW5ndGgsIHNldHVwXSkpOwogICAg
Y29uc3QgaG9zdEJlYXQgPSByb29tLmJlYXRCeSA9PT0gJ2hvc3QnICYmIHJvb20uaG9zdCAmJiBy
b29tLmhvc3QuaW5kZXggPj0gMDsKICAgIGlmICghaG9zdEJlYXQpIHJvb20uYmVhdEJ5ID0gJ3Jl
bGF5JzsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ub3JkZXIpIHsKICAgICAgLy8gKEJl
Zm9yZSBTVEFSVEVELCBzbyB0aGF0IHRoZSBwYWdlIHNlbmRzIHRoZSBnYW1lJ3MgUkVBRFkgYW5k
IGlucHV0IHRoZSByaWdodCB3YXkuKQogICAgICBpZiAoaG9zdEJlYXQpIHNlbmRDb250cm9sKG1l
bWJlci53cywgeyB0OiAnYmVhdCcsIGJ5OiAnaG9zdCcsIGhvc3Q6IHJvb20uaG9zdC5pZCB9KTsK
ICAgICAgc2VuZEJpbmFyeShtZW1iZXIud3MsIG1lc3NhZ2UpOwogICAgICBzZW5kQ29udHJvbCht
ZW1iZXIud3MsIHsgdDogJ3Jvb20nLCBwbGF5ZXJzOiByb29tLm9yZGVyLmxlbmd0aCwgc3RhcnRl
ZDogdHJ1ZSB9KTsKICAgIH0KICAgIGlmICghaG9zdEJlYXQpIHJvb20uZ3JhY2VUaW1lciA9IHNl
dFRpbWVvdXQoKCkgPT4gc3RhcnRCZWF0KHJvb20pLCBjb25maWcuc3RhcnRHcmFjZU1zKTsKICAg
IGxvZyhgcm9vbSAke3Jvb20uY29kZX06IHN0YXJ0ZWQgd2l0aCAke3Jvb20ub3JkZXIubGVuZ3Ro
fSBwbGF5ZXJzJHtob3N0QmVhdCA/ICcsIHRoZSBiZWF0IGtlcHQgYnkgdGhlIGhvc3QnIDogJyd9
YCk7CiAgfQoKICBmdW5jdGlvbiBzdGFydEJlYXQocm9vbSkgewogICAgaWYgKHJvb20udGlja2lu
ZyB8fCByb29tLmVuZGVkKSByZXR1cm47CiAgICBjbGVhclRpbWVvdXQocm9vbS5ncmFjZVRpbWVy
KTsKICAgIHJvb20udGlja2luZyA9IHRydWU7CiAgICByb29tLnRpY2tTdGFydCA9IHBlcmZvcm1h
bmNlLm5vdygpOwogICAgcm9vbS50aWNrcyA9IDA7CiAgICBzY2hlZHVsZUJlYXQocm9vbSk7CiAg
fQoKICBmdW5jdGlvbiBzY2hlZHVsZUJlYXQocm9vbSkgewogICAgY29uc3QgZHVlID0gcm9vbS50
aWNrU3RhcnQgKyAocm9vbS50aWNrcyArIDEpICogY29uZmlnLnRpY2tNczsKICAgIHJvb20udGlj
a1RpbWVyID0gc2V0VGltZW91dCgoKSA9PiBydW5CZWF0cyhyb29tKSwgTWF0aC5tYXgoMCwgZHVl
IC0gcGVyZm9ybWFuY2Uubm93KCkpKTsKICB9CgogIC8vIEJlYXRzIGFyZSBjb3VudGVkIGZyb20g
dGhlIHN0YXJ0LCBzbyB0aW1lciBkZWxheXMgZG8gbm90IGFkZCB1cDsgYWZ0ZXIgYSBzdGFsbCBv
ZiB0aGUgd2hvbGUKICAvLyBwcm9jZXNzIGEgZmV3IG1pc3NlZCBiZWF0cyBhcmUgc2VudCBhdCBv
bmNlLCBhbmQgYSBsb25nZXIgb25lIHJlc3RhcnRzIHRoZSBjb3VudC4KICBmdW5jdGlvbiBydW5C
ZWF0cyhyb29tKSB7CiAgICBpZiAocm9vbS5lbmRlZCkgcmV0dXJuOwogICAgY29uc3Qgbm93ID0g
cGVyZm9ybWFuY2Uubm93KCk7CiAgICBjb25zdCBkdWUgPSBNYXRoLmZsb29yKChub3cgLSByb29t
LnRpY2tTdGFydCkgLyBjb25maWcudGlja01zKSAtIHJvb20udGlja3M7CiAgICBmb3IgKGxldCBj
b3VudCA9IDA7IGNvdW50IDwgTWF0aC5taW4oZHVlLCA0KSAmJiAhcm9vbS5lbmRlZDsgY291bnQg
Kz0gMSkgewogICAgICByb29tLnRpY2tzICs9IDE7CiAgICAgIGJlYXQocm9vbSk7CiAgICB9CiAg
ICBpZiAocm9vbS5lbmRlZCkgcmV0dXJuOwogICAgaWYgKGR1ZSA+IDQpIHJvb20udGlja1N0YXJ0
ID0gbm93IC0gcm9vbS50aWNrcyAqIGNvbmZpZy50aWNrTXM7CiAgICBzY2hlZHVsZUJlYXQocm9v
bSk7CiAgfQoKICBmdW5jdGlvbiBiZWF0KHJvb20pIHsKICAgIGxldCBmcmVzaCA9IDA7CiAgICBs
ZXQgcHJlc2VudCA9IDA7CiAgICBjb25zdCBwYXJ0cyA9IFtdOwogICAgZm9yIChjb25zdCBtZW1i
ZXIgb2Ygcm9vbS5vcmRlcikgewogICAgICBsZXQgaW5wdXQgPSBFTVBUWTsKICAgICAgaWYgKG1l
bWJlci5wcmVzZW50KSB7CiAgICAgICAgcHJlc2VudCB8PSAxIDw8IG1lbWJlci5pbmRleDsKICAg
ICAgICBjb25zdCB3YWl0aW5nID0gbWVtYmVyLnF1ZXVlLmxlbmd0aDsKICAgICAgICBpZiAod2Fp
dGluZykgewogICAgICAgICAgZnJlc2ggfD0gMSA8PCBtZW1iZXIuaW5kZXg7CiAgICAgICAgICBp
bnB1dCA9IHdhaXRpbmcgPT09IDEgPyBtZW1iZXIucXVldWVbMF0gOiBtZXJnZUlucHV0cyhtZW1i
ZXIucXVldWUpOwogICAgICAgICAgbWVtYmVyLmxhc3QgPSBtZW1iZXIucXVldWVbd2FpdGluZyAt
IDFdOwogICAgICAgICAgbWVtYmVyLnF1ZXVlID0gW107CiAgICAgICAgICBtZW1iZXIucmVwZWF0
cyA9IDA7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgIG1lbWJlci5yZXBlYXRzICs9IDE7CiAg
ICAgICAgICBpbnB1dCA9IG1lbWJlci5yZXBlYXRzID4gY29uZmlnLnJlcGVhdExpbWl0ID8gRU1Q
VFkgOiB3aXRob3V0RXZlbnRzKG1lbWJlci5sYXN0KTsKICAgICAgICB9CiAgICAgIH0KICAgICAg
cGFydHMucHVzaChCdWZmZXIuZnJvbShbaW5wdXQubGVuZ3RoXSksIGlucHV0KTsKICAgIH0KICAg
IGNvbnN0IGhlYWRlciA9IEJ1ZmZlci5hbGxvYyg3KTsKICAgIGhlYWRlci53cml0ZVVJbnQzMkxF
KHJvb20uZnJhbWUgJSA0Mjk0OTY3Mjk2LCAwKTsKICAgIGhlYWRlcls0XSA9IHJvb20ub3JkZXIu
bGVuZ3RoOwogICAgaGVhZGVyWzVdID0gZnJlc2g7CiAgICBoZWFkZXJbNl0gPSBwcmVzZW50Owog
ICAgcm9vbS5mcmFtZSArPSAxOwogICAgY29uc3QgbWVzc2FnZSA9IHBhY2tldChLSU5ELmZyYW1l
LCBCdWZmZXIuY29uY2F0KFtoZWFkZXIsIC4uLnBhcnRzXSkpOwogICAgZm9yIChjb25zdCBtZW1i
ZXIgb2Ygcm9vbS5vcmRlcikgewogICAgICBpZiAoIW1lbWJlci5wcmVzZW50KSBjb250aW51ZTsK
ICAgICAgaWYgKG1lbWJlci53cy5idWZmZXJlZEFtb3VudCA+IGNvbmZpZy5tYXhCdWZmZXJlZEJ5
dGVzKSB7CiAgICAgICAgY2xvc2VXaXRoKG1lbWJlci53cywgQ0xPU0Uuc2xvd0NsaWVudCk7CiAg
ICAgICAgY29udGludWU7CiAgICAgIH0KICAgICAgc2VuZEJpbmFyeShtZW1iZXIud3MsIG1lc3Nh
Z2UpOwogICAgfQogIH0KCiAgZnVuY3Rpb24gbGVhdmVHcm91cChtZW1iZXIpIHsKICAgIGNvbnN0
IHJvb20gPSBtZW1iZXIucm9vbTsKICAgIGNvbnN0IHBvc2l0aW9uID0gcm9vbS5tZW1iZXJzLmlu
ZGV4T2YobWVtYmVyKTsKICAgIGlmIChwb3NpdGlvbiA+PSAwKSByb29tLm1lbWJlcnMuc3BsaWNl
KHBvc2l0aW9uLCAxKTsKICAgIGlmIChyb29tLmVuZGVkKSByZXR1cm47CiAgICBpZiAoIXJvb20u
c3RhcnRlZCkgewogICAgICBpZiAobWVtYmVyLmhvc3QpIHsKICAgICAgICByb29tLmhvc3QgPSBu
dWxsOwogICAgICAgIGVuZEdyb3VwKHJvb20sIENMT1NFLmhvc3RMZWZ0KTsKICAgICAgfSBlbHNl
IGlmICghcm9vbS5tZW1iZXJzLmxlbmd0aCkgewogICAgICAgIGVuZEdyb3VwKHJvb20pOwogICAg
ICB9IGVsc2UgaWYgKG1lbWJlci5pbmZvKSB7CiAgICAgICAgc2VuZExvYmJ5KHJvb20pOwogICAg
ICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChyb29tLmJlYXRCeSA9PT0gJ2hvc3QnKSB7
CiAgICAgIC8vIFRoZSBiZWF0IGxlYXZlcyB3aXRoIHRoZSBob3N0LiBBbm90aGVyIHBsYXllcjog
dGhlIGhvc3QncyBwYWdlIHNlbmRzIExFRlQgYW1vbmcgaXRzIGZyYW1lcy4KICAgICAgaWYgKG1l
bWJlci5ob3N0KSByZXR1cm4gZW5kR3JvdXAocm9vbSwgQ0xPU0UuaG9zdExlZnQpOwogICAgICBp
ZiAobWVtYmVyLmluZGV4ID49IDAgJiYgbWVtYmVyLnByZXNlbnQpIHsKICAgICAgICBtZW1iZXIu
cHJlc2VudCA9IGZhbHNlOwogICAgICAgIGNvbnN0IHBsYXllcnMgPSByb29tLm9yZGVyLmZpbHRl
cigob3RoZXIpID0+IG90aGVyLnByZXNlbnQpLmxlbmd0aDsKICAgICAgICBpZiAocm9vbS5ob3N0
KSBzZW5kQ29udHJvbChyb29tLmhvc3Qud3MsIHsgdDogJ2xlZnQnLCBpZDogbWVtYmVyLmlkIH0p
OwogICAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5vcmRlcikgaWYgKG90aGVyLnByZXNl
bnQpIHNlbmRDb250cm9sKG90aGVyLndzLCB7IHQ6ICdyb29tJywgcGxheWVycywgc3RhcnRlZDog
dHJ1ZSB9KTsKICAgICAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBwbGF5ZXIgJHttZW1iZXIu
aW5kZXggKyAxfSBsZWZ0YCk7CiAgICAgIH0KICAgICAgaWYgKCFyb29tLm9yZGVyLnNvbWUoKG90
aGVyKSA9PiBvdGhlci5wcmVzZW50KSkgZW5kR3JvdXAocm9vbSk7CiAgICAgIHJldHVybjsKICAg
IH0KICAgIGlmIChtZW1iZXIuaW5kZXggPj0gMCAmJiBtZW1iZXIucHJlc2VudCkgewogICAgICBt
ZW1iZXIucHJlc2VudCA9IGZhbHNlOwogICAgICBtZW1iZXIucXVldWUgPSBbXTsKICAgICAgY29u
c3QgbWVzc2FnZSA9IHBhY2tldChLSU5ELmxlZnQsIEJ1ZmZlci5mcm9tKFttZW1iZXIuaW5kZXhd
KSk7CiAgICAgIGNvbnN0IHBsYXllcnMgPSByb29tLm9yZGVyLmZpbHRlcigob3RoZXIpID0+IG90
aGVyLnByZXNlbnQpLmxlbmd0aDsKICAgICAgZm9yIChjb25zdCBvdGhlciBvZiByb29tLm9yZGVy
KSB7CiAgICAgICAgaWYgKCFvdGhlci5wcmVzZW50KSBjb250aW51ZTsKICAgICAgICBzZW5kQmlu
YXJ5KG90aGVyLndzLCBtZXNzYWdlKTsKICAgICAgICBzZW5kQ29udHJvbChvdGhlci53cywgeyB0
OiAncm9vbScsIHBsYXllcnMsIHN0YXJ0ZWQ6IHRydWUgfSk7CiAgICAgIH0KICAgICAgbG9nKGBy
b29tICR7cm9vbS5jb2RlfTogcGxheWVyICR7bWVtYmVyLmluZGV4ICsgMX0gbGVmdGApOwogICAg
fQogICAgaWYgKCFyb29tLm9yZGVyLnNvbWUoKG90aGVyKSA9PiBvdGhlci5wcmVzZW50KSkgZW5k
R3JvdXAocm9vbSk7CiAgICBlbHNlIGlmIChyb29tLm9yZGVyLmV2ZXJ5KChvdGhlcikgPT4gb3Ro
ZXIucmVhZHkgfHwgIW90aGVyLnByZXNlbnQpKSBzdGFydEJlYXQocm9vbSk7CiAgfQoKICBmdW5j
dGlvbiBlbmRHcm91cChyb29tLCByZWFzb24pIHsKICAgIGlmIChyb29tLmVuZGVkKSByZXR1cm47
CiAgICByb29tLmVuZGVkID0gdHJ1ZTsKICAgIGNsZWFyVGltZW91dChyb29tLmxvYmJ5VGltZXIp
OwogICAgY2xlYXJUaW1lb3V0KHJvb20uZ3JhY2VUaW1lcik7CiAgICBjbGVhclRpbWVvdXQocm9v
bS50aWNrVGltZXIpOwogICAgaWYgKGdyb3Vwcy5nZXQocm9vbS5jb2RlKSA9PT0gcm9vbSkgZ3Jv
dXBzLmRlbGV0ZShyb29tLmNvZGUpOwogICAgZm9yIChjb25zdCBtZW1iZXIgb2Ygcm9vbS5tZW1i
ZXJzLnNsaWNlKCkpIGNsb3NlV2l0aChtZW1iZXIud3MsIHJlYXNvbiB8fCBDTE9TRS5zaHV0ZG93
bik7CiAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBlbmRlZGApOwogIH0KCiAgLy8gU2l6ZSBv
ZiB0aGUgaW5zdGFsbGVyIGZpbGUsIG9yIDAgd2hlbiBub25lIGlzIGNvbmZpZ3VyZWQgb3IgcmVh
ZGFibGUuCiAgZnVuY3Rpb24gaW5zdGFsbGVyU2l6ZSgpIHsKICAgIGlmICghY29uZmlnLmluc3Rh
bGxlckZpbGUpIHJldHVybiAwOwogICAgdHJ5IHsKICAgICAgY29uc3Qgc3RhdCA9IGZzLnN0YXRT
eW5jKGNvbmZpZy5pbnN0YWxsZXJGaWxlKTsKICAgICAgcmV0dXJuIHN0YXQuaXNGaWxlKCkgPyBz
dGF0LnNpemUgOiAwOwogICAgfSBjYXRjaCB7CiAgICAgIHJldHVybiAwOwogICAgfQogIH0KCiAg
ZnVuY3Rpb24gc2VydmVJbnN0YWxsZXIocmVxLCByZXMpIHsKICAgIGNvbnN0IGhlYWRlcnMgPSB7
ICdjYWNoZS1jb250cm9sJzogJ3B1YmxpYywgbWF4LWFnZT04NjQwMCcsICd4LWNvbnRlbnQtdHlw
ZS1vcHRpb25zJzogJ25vc25pZmYnLCAuLi5hbGxvd09yaWdpbihyZXEpIH07CiAgICBpZiAocmVx
Lm1ldGhvZCAhPT0gJ0dFVCcgJiYgcmVxLm1ldGhvZCAhPT0gJ0hFQUQnKSB7CiAgICAgIHJlcy53
cml0ZUhlYWQoNDA1LCB7IC4uLmhlYWRlcnMsIGFsbG93OiAnR0VULCBIRUFEJyB9KTsKICAgICAg
cmVzLmVuZCgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzaXplID0gaW5zdGFsbGVy
U2l6ZSgpOwogICAgaWYgKCFzaXplKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoNDA0LCBoZWFkZXJz
KTsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAocmVxLm1ldGhv
ZCA9PT0gJ0dFVCcgJiYgY29uZmlnLmluc3RhbGxlckRvd25sb2Fkc1BlckhvdXIpIHsKICAgICAg
Y29uc3QgYWRkcmVzcyA9IGNsaWVudEFkZHJlc3MocmVxKTsKICAgICAgY29uc3Qgbm93ID0gRGF0
ZS5ub3coKTsKICAgICAgbGV0IGVudHJ5ID0gaW5zdGFsbGVyRG93bmxvYWRzLmdldChhZGRyZXNz
KTsKICAgICAgaWYgKCFlbnRyeSB8fCBlbnRyeS51bnRpbCA8PSBub3cpIHsKICAgICAgICBlbnRy
eSA9IHsgY291bnQ6IDAsIHVudGlsOiBub3cgKyAzNjAwMDAwIH07CiAgICAgICAgaW5zdGFsbGVy
RG93bmxvYWRzLnNldChhZGRyZXNzLCBlbnRyeSk7CiAgICAgIH0KICAgICAgaWYgKGVudHJ5LmNv
dW50ID49IGNvbmZpZy5pbnN0YWxsZXJEb3dubG9hZHNQZXJIb3VyKSB7CiAgICAgICAgcmVzLndy
aXRlSGVhZCg0MjksIHsgLi4uaGVhZGVycywgJ3JldHJ5LWFmdGVyJzogU3RyaW5nKE1hdGguY2Vp
bCgoZW50cnkudW50aWwgLSBub3cpIC8gMTAwMCkpIH0pOwogICAgICAgIHJlcy5lbmQoKTsKICAg
ICAgICByZXR1cm47CiAgICAgIH0KICAgICAgZW50cnkuY291bnQgKz0gMTsKICAgIH0KICAgIHJl
cy53cml0ZUhlYWQoMjAwLCB7IC4uLmhlYWRlcnMsICdjb250ZW50LXR5cGUnOiAnYXBwbGljYXRp
b24vb2N0ZXQtc3RyZWFtJywgJ2NvbnRlbnQtbGVuZ3RoJzogU3RyaW5nKHNpemUpIH0pOwogICAg
aWYgKHJlcS5tZXRob2QgPT09ICdIRUFEJykgewogICAgICByZXMuZW5kKCk7CiAgICAgIHJldHVy
bjsKICAgIH0KICAgIGNvbnN0IHN0cmVhbSA9IGZzLmNyZWF0ZVJlYWRTdHJlYW0oY29uZmlnLmlu
c3RhbGxlckZpbGUpOwogICAgc3RyZWFtLm9uKCdlcnJvcicsICgpID0+IHJlcy5kZXN0cm95KCkp
OwogICAgc3RyZWFtLnBpcGUocmVzKTsKICB9CgogIC8vIENyb3NzLW9yaWdpbjogdGhlIGdhbWUg
cGFnZSBsaXZlcyBlbHNld2hlcmUgKEdpdEh1YiBQYWdlcykuIFdpdGggYW4gYWxsb3ctbGlzdCwg
b25seSBpdHMgcGFnZXMgbWF5IHJlYWQuCiAgZnVuY3Rpb24gYWxsb3dPcmlnaW4ocmVxKSB7CiAg
ICBpZiAoIWNvbmZpZy5hbGxvd2VkT3JpZ2lucy5sZW5ndGgpIHJldHVybiB7ICdhY2Nlc3MtY29u
dHJvbC1hbGxvdy1vcmlnaW4nOiAnKicgfTsKICAgIGNvbnN0IG9yaWdpbiA9IG5vcm1hbGl6ZU9y
aWdpbihyZXEuaGVhZGVycy5vcmlnaW4pOwogICAgaWYgKG9yaWdpbiAmJiBjb25maWcuYWxsb3dl
ZE9yaWdpbnMuaW5jbHVkZXMob3JpZ2luKSkgcmV0dXJuIHsgJ2FjY2Vzcy1jb250cm9sLWFsbG93
LW9yaWdpbic6IHJlcS5oZWFkZXJzLm9yaWdpbiwgdmFyeTogJ09yaWdpbicgfTsKICAgIHJldHVy
biB7fTsKICB9CgogIGZ1bmN0aW9uIGNsaWVudEFkZHJlc3MocmVxKSB7CiAgICBpZiAoY29uZmln
LnRydXN0UHJveHkpIHsKICAgICAgLy8gVGhlIGxhc3QgZW50cnkgaXMgdGhlIG9uZSBvdXIgb3du
IHByb3h5IGFkZGVkIChBcGFjaGUgYXBwZW5kcywgQ2FkZHkgcmVwbGFjZXMpOyBlbnRyaWVzIGJl
Zm9yZQogICAgICAvLyBpdCBjb21lIGZyb20gdGhlIGNsaWVudCBhbmQgY291bGQgYmUgbWFkZSB1
cCB0byBzbGlwIHBhc3QgdGhlIHBlci1hZGRyZXNzIGxpbWl0cy4KICAgICAgY29uc3QgZm9yd2Fy
ZGVkID0gU3RyaW5nKHJlcS5oZWFkZXJzWyd4LWZvcndhcmRlZC1mb3InXSB8fCAnJykuc3BsaXQo
JywnKS5tYXAoKHBhcnQpID0+IHBhcnQudHJpbSgpKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgIGlm
IChmb3J3YXJkZWQubGVuZ3RoKSByZXR1cm4gZm9yd2FyZGVkW2ZvcndhcmRlZC5sZW5ndGggLSAx
XTsKICAgIH0KICAgIHJldHVybiByZXEuc29ja2V0LnJlbW90ZUFkZHJlc3MgfHwgJ3Vua25vd24n
OwogIH0KCiAgY29uc3QgaGVhcnRiZWF0ID0gc2V0SW50ZXJ2YWwoKCkgPT4gewogICAgZm9yIChj
b25zdCB3cyBvZiB3c3MuY2xpZW50cykgewogICAgICBpZiAoIXdzLmlzQWxpdmUpIHsgd3MudGVy
bWluYXRlKCk7IGNvbnRpbnVlOyB9CiAgICAgIHdzLmlzQWxpdmUgPSBmYWxzZTsKICAgICAgdHJ5
IHsgd3MucGluZygpOyB9IGNhdGNoIHsgLyogY2xvc2luZyAqLyB9CiAgICB9CiAgICBjb25zdCBu
b3cgPSBEYXRlLm5vdygpOwogICAgZm9yIChjb25zdCBbYWRkcmVzcywgZW50cnldIG9mIGluc3Rh
bGxlckRvd25sb2FkcykgaWYgKGVudHJ5LnVudGlsIDw9IG5vdykgaW5zdGFsbGVyRG93bmxvYWRz
LmRlbGV0ZShhZGRyZXNzKTsKICAgIHBhY2tzLmNsZWFudXAoKTsKICAgIGhvYy5jbGVhbnVwKCk7
CiAgICBnZW1pbmkuY2xlYW51cCgpOwogIH0sIGNvbmZpZy5waW5nSW50ZXJ2YWxNcyk7CiAgaGVh
cnRiZWF0LnVucmVmKCk7CgogIHJldHVybiB7CiAgICBjb25maWcsCiAgICBzZXJ2ZXIsCiAgICB3
c3MsCiAgICByb29tcywKICAgIGxpc3Rlbihwb3J0ID0gY29uZmlnLnBvcnQsIGhvc3QgPSBjb25m
aWcuaG9zdCkgewogICAgICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4g
ewogICAgICAgIHNlcnZlci5vbmNlKCdlcnJvcicsIHJlamVjdCk7CiAgICAgICAgc2VydmVyLmxp
c3Rlbihwb3J0LCBob3N0LCAoKSA9PiB7CiAgICAgICAgICBzZXJ2ZXIub2ZmKCdlcnJvcicsIHJl
amVjdCk7CiAgICAgICAgICByZXNvbHZlKHNlcnZlci5hZGRyZXNzKCkpOwogICAgICAgIH0pOwog
ICAgICB9KTsKICAgIH0sCiAgICBncm91cHMsCiAgICBoZiwKICAgIGNsb3NlKCkgewogICAgICBj
bGVhckludGVydmFsKGhlYXJ0YmVhdCk7CiAgICAgIGhmLmNsb3NlKCk7CiAgICAgIGZvciAoY29u
c3Qgcm9vbSBvZiByb29tcy52YWx1ZXMoKSkgY2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAg
ICBmb3IgKGNvbnN0IHJvb20gb2YgWy4uLmdyb3Vwcy52YWx1ZXMoKV0pIGVuZEdyb3VwKHJvb20s
IENMT1NFLnNodXRkb3duKTsKICAgICAgZm9yIChjb25zdCB3cyBvZiB3c3MuY2xpZW50cykgY2xv
c2VXaXRoKHdzLCBDTE9TRS5zaHV0ZG93bik7CiAgICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVz
b2x2ZSkgPT4gewogICAgICAgIHdzcy5jbG9zZSgoKSA9PiBzZXJ2ZXIuY2xvc2UoKCkgPT4gcmVz
b2x2ZSgpKSk7CiAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7IGZvciAoY29uc3Qgd3Mgb2Ygd3Nz
LmNsaWVudHMpIHdzLnRlcm1pbmF0ZSgpOyB9LCAxMDAwKS51bnJlZigpOwogICAgICB9KTsKICAg
IH0sCiAgfTsKfQoKZnVuY3Rpb24gc2VuZENvbnRyb2wod3MsIG1lc3NhZ2UpIHsKICBpZiAod3Mu
cmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4pIHdzLnNlbmQoSlNPTi5zdHJpbmdpZnkobWVz
c2FnZSkpOwp9CgpmdW5jdGlvbiBzZW5kQmluYXJ5KHdzLCBkYXRhKSB7CiAgaWYgKHdzLnJlYWR5
U3RhdGUgPT09IFdlYlNvY2tldC5PUEVOKSB3cy5zZW5kKGRhdGEsIHsgYmluYXJ5OiB0cnVlIH0p
Owp9Cgpjb25zdCBFTVBUWSA9IEJ1ZmZlci5hbGxvYygwKTsKCi8vIEEgcHJvdG9jb2wgMiBtZXNz
YWdlOiBraW5kLCBwYXlsb2FkIGxlbmd0aCAoMiBieXRlcywgbGl0dGxlIGVuZGlhbiksIHBheWxv
YWQuCmZ1bmN0aW9uIHBhY2tldChraW5kLCBwYXlsb2FkKSB7CiAgY29uc3QgbWVzc2FnZSA9IEJ1
ZmZlci5hbGxvY1Vuc2FmZSgzICsgcGF5bG9hZC5sZW5ndGgpOwogIG1lc3NhZ2VbMF0gPSBraW5k
OwogIG1lc3NhZ2Uud3JpdGVVSW50MTZMRShwYXlsb2FkLmxlbmd0aCwgMSk7CiAgcGF5bG9hZC5j
b3B5KG1lc3NhZ2UsIDMpOwogIHJldHVybiBtZXNzYWdlOwp9CgovLyBJbnB1dHMgYXJlIGJpdCBz
ZXRzIChrZXlzIGhlbGQsIGV2ZW50cyk6IG1lcmdlZCwgZXZlcnkgYml0IHNldCBpbiBhbnkgb2Yg
dGhlbSBpcyBzZXQuCmZ1bmN0aW9uIG1lcmdlSW5wdXRzKGlucHV0cykgewogIGNvbnN0IG1lcmdl
ZCA9IEJ1ZmZlci5hbGxvYyhNYXRoLm1heCgwLCAuLi5pbnB1dHMubWFwKChpbnB1dCkgPT4gaW5w
dXQubGVuZ3RoKSkpOwogIGZvciAoY29uc3QgaW5wdXQgb2YgaW5wdXRzKSBmb3IgKGxldCBpbmRl
eCA9IDA7IGluZGV4IDwgaW5wdXQubGVuZ3RoOyBpbmRleCArPSAxKSBtZXJnZWRbaW5kZXhdIHw9
IGlucHV0W2luZGV4XTsKICByZXR1cm4gbWVyZ2VkOwp9CgovLyBBIHJlcGVhdGVkIGlucHV0IGtl
ZXBzIGl0cyBoZWxkIGtleXMgYnV0IG5vdCBpdHMgb25lLXNob3QgZXZlbnRzIChieXRlIDApLgpm
dW5jdGlvbiB3aXRob3V0RXZlbnRzKGlucHV0KSB7CiAgaWYgKCFpbnB1dC5sZW5ndGggfHwgaW5w
dXRbMF0gPT09IDApIHJldHVybiBpbnB1dDsKICBjb25zdCBjb3B5ID0gQnVmZmVyLmZyb20oaW5w
dXQpOwogIGNvcHlbMF0gPSAwOwogIHJldHVybiBjb3B5Owp9CgpmdW5jdGlvbiBjbG9zZVdpdGgo
d3MsIFtjb2RlLCByZWFzb25dKSB7CiAgaWYgKHdzLnJlYWR5U3RhdGUgPT09IFdlYlNvY2tldC5P
UEVOIHx8IHdzLnJlYWR5U3RhdGUgPT09IFdlYlNvY2tldC5DT05ORUNUSU5HKSB7CiAgICB3cy5j
bG9zZShjb2RlLCByZWFzb24pOwogICAgLy8gRG8gbm90IHdhaXQgZm9yZXZlciBmb3IgYSBjbGll
bnQgdGhhdCBuZXZlciBhbnN3ZXJzIHRoZSBjbG9zZSBoYW5kc2hha2UuCiAgICBzZXRUaW1lb3V0
KCgpID0+IHsgaWYgKHdzLnJlYWR5U3RhdGUgIT09IFdlYlNvY2tldC5DTE9TRUQpIHdzLnRlcm1p
bmF0ZSgpOyB9LCAzMDAwKS51bnJlZigpOwogIH0KfQoKbW9kdWxlLmV4cG9ydHMgPSB7IGNyZWF0
ZVJlbGF5LCByZWFkQ29uZmlnLCBDTE9TRSwgUk9PTV9QQVRURVJOLCBLSU5ELCBST09NX0xJTUlU
UywgcGFja2V0LCBtZXJnZUlucHV0cyB9OwoKaWYgKHJlcXVpcmUubWFpbiA9PT0gbW9kdWxlKSB7
CiAgY29uc3QgcmVsYXkgPSBjcmVhdGVSZWxheShyZWFkQ29uZmlnKCkpOwogIHJlbGF5Lmxpc3Rl
bigpLnRoZW4oKGFkZHJlc3MpID0+IHsKICAgIGNvbnN0IHdoZXJlID0gdHlwZW9mIGFkZHJlc3Mg
PT09ICdzdHJpbmcnID8gYWRkcmVzcyA6IGAke2FkZHJlc3MuYWRkcmVzc306JHthZGRyZXNzLnBv
cnR9YDsKICAgIGNvbnNvbGUubG9nKGBPcGVuTEYyIHJlbGF5IGxpc3RlbmluZyBvbiAke3doZXJl
fSwgV2ViU29ja2V0IHBhdGggJHtyZWxheS5jb25maWcucGF0aH1gKTsKICAgIGlmICghcmVsYXku
Y29uZmlnLmFsbG93ZWRPcmlnaW5zLmxlbmd0aCkgewogICAgICBjb25zb2xlLmxvZygnQUxMT1dF
RF9PUklHSU5TIGlzIGVtcHR5OiBhbnkgd2Vic2l0ZSBtYXkgdXNlIHRoaXMgcmVsYXkuIFNldCBp
dCB0byB5b3VyIGdhbWUgcGFnZSBvcmlnaW4uJyk7CiAgICB9CiAgfSkuY2F0Y2goKGVycm9yKSA9
PiB7CiAgICBjb25zb2xlLmVycm9yKGVycm9yLm1lc3NhZ2UpOwogICAgcHJvY2Vzcy5leGl0KDEp
OwogIH0pOwogIGNvbnN0IHN0b3AgPSAoKSA9PiByZWxheS5jbG9zZSgpLnRoZW4oKCkgPT4gcHJv
Y2Vzcy5leGl0KDApKTsKICBwcm9jZXNzLm9uKCdTSUdJTlQnLCBzdG9wKTsKICBwcm9jZXNzLm9u
KCdTSUdURVJNJywgc3RvcCk7Cn0K
LF2_PAYLOAD
}
write_packs_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IE1JVAovLwovLyBHYW1lIHBhY2tzIGZvciB0aGUg
T3BlbkxGMiByZWxheTogd2hvbGUgTEYyIGdhbWUgZm9sZGVycyBhcyBaSVAgZmlsZXMgKG1vZHMg
dGhhdCBjb21lIHdpdGggdGhlaXIKLy8gb3duIGxmMi5leGUsIGRhdGEsIHNwcml0ZSwgYmdtIGFu
ZCBiZyBmb2xkZXJzKSwgd2hpY2ggdGhlIHdlYiBnYW1lIHBsYXlzIGluc3RlYWQgb2YgdGhlIG9y
aWdpbmFsCi8vIExGMiBpbnN0YWxsZXIgKHRoZSBnYW1lJ3MgLS1wYWNrIG9wdGlvbikuIFRoZSBy
ZWxheSBrZWVwcyB0aGVtIGluIFBBQ0tTX0RJUiBhbmQgaGFuZHMgdGhlbSB0byB0aGUKLy8gZ2Ft
ZSBwYWdlczsgd2hvZXZlciBob2xkcyBBRE1JTl9LRVkgYWRkcyBhbmQgcmVtb3ZlcyB0aGVtIG9u
IHRoZSBwYWdlIGF0IC9hZG1pbi4gQW4gdXBsb2FkIGtlZXBzCi8vIG9ubHkgdGhlIGdhbWUgZm9s
ZGVyICh0aGUgb25lIGhvbGRpbmcgZGF0YS9kYXRhLnR4dCBuZWFyZXN0IHRoZSB0b3ApIHdpdGhv
dXQgdGhlIGNvcGllcyBvZiB0aGUKLy8gZ2FtZSwgcmVjb3JkaW5ncyBhbmQgbm90ZXMgdGhhdCBt
b2RzIG9mdGVuIGNhcnJ5LCBzbyB0aGF0IHBsYXllcnMgZG93bmxvYWQgbGVzcy4KLy8KLy8gQSBG
bGFzaCBnYW1lIChIZXJvIEZpZ2h0ZXIsIHdoaWNoIHRoZSBwYWdlIHJ1bnMgaW4gUnVmZmxlKSBj
YW4gYmUgdXBsb2FkZWQgdGhlIHNhbWUgd2F5OiBpdHMgWklQIGZpbGUsCi8vIGl0cyBXaW5kb3dz
IHByb2dyYW0gKGEgRmxhc2ggcHJvamVjdG9yOiB0aGUgbW92aWUgaXMgaW5zaWRlKSBvciB0aGUg
bW92aWUgaXRzZWxmLiBUaGUgcmVsYXkga2VlcHMgdGhlCi8vIG1vdmllICguc3dmKSBvbmx5OyBz
dWNoIGEgcGFjayBpcyBsaXN0ZWQgd2l0aCAia2luZCI6ImZsYXNoIiAoYW5kICJnYW1lIjoiaGVy
b2ZpZ2h0ZXIiIGZvciB0aGF0IG9uZSkuCi8vCi8vICAgR0VUICAvbGYyLXBhY2tzLmpzb24gICAg
ICAgICAgICAgdGhlIHBhY2tzOiB7InBhY2tzIjpbeyJpZCIsInRpdGxlIiwic2l6ZSIsInNoYTI1
NiIsImtpbmQiLCJnYW1lIn1dfQovLyAgIEdFVCAgL2xmMi1wYWNrcy88aWQ+LnppcCAgICAgICAg
IGEgcGFjayAoYW4gTEYyIGdhbWUgZm9sZGVyKQovLyAgIEdFVCAgL2xmMi1wYWNrcy88aWQ+LnN3
ZiAgICAgICAgIGEgRmxhc2ggZ2FtZSdzIG1vdmllCi8vICAgR0VUICAvYWRtaW4gICAgICAgICAg
ICAgICAgICAgICAgdGhlIHBhZ2UgdG8gbWFuYWdlIHRoZW0KLy8gICBHRVQgIC9hZG1pbi9hcGkv
cGFja3MgICAgICAgICAgICB0aGUgc2FtZSBsaXN0LCB3aXRoIGRldGFpbHMgKFgtQWRtaW4tS2V5
KQovLyAgIFBVVCAgL2FkbWluL2FwaS9wYWNrcy88aWQ+P3RpdGxlPTx0aXRsZT4gICB1cGxvYWQg
YSBaSVAgZmlsZSBhcyB0aGUgYm9keSAoWC1BZG1pbi1LZXkpCi8vICAgREVMRVRFIC9hZG1pbi9h
cGkvcGFja3MvPGlkPiAgICAgcmVtb3ZlIG9uZSAoWC1BZG1pbi1LZXkpCi8vICAgR0VUICAvYWRt
aW4vYXBpL2hmLWpvdXJuYWwgICAgICAgdGhlIEhlcm8gRmlnaHRlciByb29tcycgam91cm5hbCwg
YXMgdGV4dCAoWC1BZG1pbi1LZXkpCi8vICAgR0VUICAvYWRtaW4vYXBpL2hmLWFjY291bnRzICAg
ICAgdGhlIEhlcm8gRmlnaHRlciBhY2NvdW50cyAoaGYuanMpLCB3aXRoIHdoZXRoZXIgZWFjaCBo
YXMgdGhlIHByZW1pdW0gY2hhcmFjdGVycwovLyAgIFBPU1QgL2FkbWluL2FwaS9oZi1hY2NvdW50
cy88aWQ+P3ByZW1pdW09MXwwICAgb3BlbiB0aGUgcHJlbWl1bSBjaGFyYWN0ZXJzIHRvIHRoYXQg
YWNjb3VudCwgb3IgbG9jayB0aGVtIGFnYWluCi8vICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgKFgtQWRtaW4tS2V5OyBmcm9tIHRoZSBhY2NvdW50J3MgbmV4dCBsb2dpbikKJ3Vz
ZSBzdHJpY3QnOwoKY29uc3QgY3J5cHRvID0gcmVxdWlyZSgnbm9kZTpjcnlwdG8nKTsKY29uc3Qg
ZnMgPSByZXF1aXJlKCdub2RlOmZzJyk7CmNvbnN0IGZzcCA9IHJlcXVpcmUoJ25vZGU6ZnMvcHJv
bWlzZXMnKTsKY29uc3QgcGF0aCA9IHJlcXVpcmUoJ25vZGU6cGF0aCcpOwpjb25zdCB7IHBpcGVs
aW5lIH0gPSByZXF1aXJlKCdub2RlOnN0cmVhbS9wcm9taXNlcycpOwpjb25zdCB7IFRyYW5zZm9y
bSB9ID0gcmVxdWlyZSgnbm9kZTpzdHJlYW0nKTsKY29uc3QgemxpYiA9IHJlcXVpcmUoJ25vZGU6
emxpYicpOwoKY29uc3QgUEFDS19JRCA9IC9eW2EtejAtOV1bYS16MC05LV17MCwzOX0kLzsKY29u
c3QgTUlCID0gMTAyNCAqIDEwMjQ7Ci8vIEZpbGVzIGJlc2lkZSB0aGUgZ2FtZSB0aGF0IG5vIGdh
bWUgcmVhZHM6IG5vdGVzLCBhcmNoaXZlcywgdmlkZW9zLCBzaG9ydGN1dHMuCmNvbnN0IE5PVEVT
ID0gL1wuKHR4dHxuZm98ZG9jfGRvY3h8cGRmfHJ0ZnxodG18aHRtbHx1cmx8bG5rfHN3ZnxyYXJ8
emlwfDd6fGxmcnxtcDR8YXZpfHdtdnxqcGd8anBlZ3xnaWYpJC9pOwoKY2xhc3MgUGFja0Vycm9y
IGV4dGVuZHMgRXJyb3Ige30KCi8vIFRoZSBjZW50cmFsIGRpcmVjdG9yeSBvZiBhIFpJUCBmaWxl
OiBpdHMgZW50cmllcyB3aXRoIHRoZWlyIHJhdyByZWNvcmRzLgphc3luYyBmdW5jdGlvbiByZWFk
WmlwKGZpbGUpIHsKICBjb25zdCBoYW5kbGUgPSBhd2FpdCBmc3Aub3BlbihmaWxlLCAncicpOwog
IHRyeSB7CiAgICBjb25zdCB7IHNpemUgfSA9IGF3YWl0IGhhbmRsZS5zdGF0KCk7CiAgICBpZiAo
c2l6ZSA8IDIyKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGlzIGlzIG5vdCBhIFpJUCBmaWxlJyk7
CiAgICBpZiAoc2l6ZSA+IDB4ZmZmZmZmZmYpIHRocm93IG5ldyBQYWNrRXJyb3IoJ1pJUCBmaWxl
cyBvdmVyIDQgR2lCIGFyZSBub3Qgc3VwcG9ydGVkJyk7CiAgICBjb25zdCB0YWlsU2l6ZSA9IE1h
dGgubWluKHNpemUsIDIyICsgNjU1MzUpOwogICAgY29uc3QgdGFpbCA9IEJ1ZmZlci5hbGxvYyh0
YWlsU2l6ZSk7CiAgICBhd2FpdCBoYW5kbGUucmVhZCh0YWlsLCAwLCB0YWlsU2l6ZSwgc2l6ZSAt
IHRhaWxTaXplKTsKICAgIGxldCBlbmQgPSAtMTsKICAgIGZvciAobGV0IGF0ID0gdGFpbFNpemUg
LSAyMjsgYXQgPj0gMDsgYXQgLT0gMSkgewogICAgICBpZiAodGFpbC5yZWFkVUludDMyTEUoYXQp
ID09PSAweDA2MDU0YjUwICYmIGF0ICsgMjIgKyB0YWlsLnJlYWRVSW50MTZMRShhdCArIDIwKSA9
PT0gdGFpbFNpemUpIHsKICAgICAgICBlbmQgPSBhdDsKICAgICAgICBicmVhazsKICAgICAgfQog
ICAgfQogICAgaWYgKGVuZCA8IDApIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoaXMgaXMgbm90IGEg
WklQIGZpbGUnKTsKICAgIGNvbnN0IGNvdW50ID0gdGFpbC5yZWFkVUludDE2TEUoZW5kICsgMTAp
OwogICAgY29uc3QgZGlyZWN0b3J5U2l6ZSA9IHRhaWwucmVhZFVJbnQzMkxFKGVuZCArIDEyKTsK
ICAgIGNvbnN0IGRpcmVjdG9yeU9mZnNldCA9IHRhaWwucmVhZFVJbnQzMkxFKGVuZCArIDE2KTsK
ICAgIGlmICh0YWlsLnJlYWRVSW50MTZMRShlbmQgKyA0KSAhPT0gMCB8fCB0YWlsLnJlYWRVSW50
MTZMRShlbmQgKyA4KSAhPT0gY291bnQpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3NwbGl0IFpJUCBm
aWxlcyBhcmUgbm90IHN1cHBvcnRlZCcpOwogICAgaWYgKGNvdW50ID09PSAweGZmZmYgfHwgZGly
ZWN0b3J5U2l6ZSA9PT0gMHhmZmZmZmZmZiB8fCBkaXJlY3RvcnlPZmZzZXQgPT09IDB4ZmZmZmZm
ZmYpIHsKICAgICAgdGhyb3cgbmV3IFBhY2tFcnJvcignWklQNjQgZmlsZXMgYXJlIG5vdCBzdXBw
b3J0ZWQnKTsKICAgIH0KICAgIGlmIChkaXJlY3RvcnlPZmZzZXQgKyBkaXJlY3RvcnlTaXplID4g
c2l6ZSkgdGhyb3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAg
IGNvbnN0IGRpcmVjdG9yeSA9IEJ1ZmZlci5hbGxvYyhkaXJlY3RvcnlTaXplKTsKICAgIGF3YWl0
IGhhbmRsZS5yZWFkKGRpcmVjdG9yeSwgMCwgZGlyZWN0b3J5U2l6ZSwgZGlyZWN0b3J5T2Zmc2V0
KTsKICAgIGNvbnN0IGVudHJpZXMgPSBbXTsKICAgIGZvciAobGV0IGF0ID0gMCwgaW5kZXggPSAw
OyBpbmRleCA8IGNvdW50OyBpbmRleCArPSAxKSB7CiAgICAgIGlmIChhdCArIDQ2ID4gZGlyZWN0
b3J5Lmxlbmd0aCB8fCBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0KSAhPT0gMHgwMjAxNGI1MCkg
dGhyb3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgICAgY29u
c3QgbmFtZUxlbmd0aCA9IGRpcmVjdG9yeS5yZWFkVUludDE2TEUoYXQgKyAyOCk7CiAgICAgIGNv
bnN0IGxlbmd0aCA9IDQ2ICsgbmFtZUxlbmd0aCArIGRpcmVjdG9yeS5yZWFkVUludDE2TEUoYXQg
KyAzMCkgKyBkaXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgMzIpOwogICAgICBpZiAoYXQgKyBs
ZW5ndGggPiBkaXJlY3RvcnkubGVuZ3RoKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGUgWklQIGZp
bGUgaXMgZGFtYWdlZCcpOwogICAgICBjb25zdCBmbGFncyA9IGRpcmVjdG9yeS5yZWFkVUludDE2
TEUoYXQgKyA4KTsKICAgICAgY29uc3QgbmFtZSA9IGRpcmVjdG9yeS50b1N0cmluZyhmbGFncyAm
IDB4ODAwID8gJ3V0ZjgnIDogJ2xhdGluMScsIGF0ICsgNDYsIGF0ICsgNDYgKyBuYW1lTGVuZ3Ro
KTsKICAgICAgZW50cmllcy5wdXNoKHsKICAgICAgICBuYW1lLCBmbGFncywgbWV0aG9kOiBkaXJl
Y3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgMTApLAogICAgICAgIGNvbXByZXNzZWRTaXplOiBkaXJl
Y3RvcnkucmVhZFVJbnQzMkxFKGF0ICsgMjApLCBzaXplOiBkaXJlY3RvcnkucmVhZFVJbnQzMkxF
KGF0ICsgMjQpLAogICAgICAgIGxvY2FsT2Zmc2V0OiBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0
ICsgNDIpLCByZWNvcmQ6IEJ1ZmZlci5mcm9tKGRpcmVjdG9yeS5zdWJhcnJheShhdCwgYXQgKyBs
ZW5ndGgpKSwKICAgICAgfSk7CiAgICAgIGF0ICs9IGxlbmd0aDsKICAgIH0KICAgIHJldHVybiB7
IGVudHJpZXMsIHNpemUgfTsKICB9IGZpbmFsbHkgewogICAgYXdhaXQgaGFuZGxlLmNsb3NlKCk7
CiAgfQp9CgovLyBXaGF0IG9mIGEgWklQIGZpbGUgdGhlIGdhbWUgbmVlZHM6IHRoZSBnYW1lIGZv
bGRlciAodGhlIG9uZSBob2xkaW5nIGRhdGEvZGF0YS50eHQgbmVhcmVzdCB0aGUKLy8gdG9wKSB3
aXRob3V0IG90aGVyIGNvcGllcyBvZiB0aGUgZ2FtZSBpbnNpZGUgaXQsIHJlY29yZGluZ3MsIG5v
dGVzIGFuZCBvdGhlciBwcm9ncmFtcy4KZnVuY3Rpb24gYW5hbHl6ZVppcChlbnRyaWVzKSB7CiAg
Y29uc3QgbG93ZXIgPSAobmFtZSkgPT4gbmFtZS5yZXBsYWNlKC9cXC9nLCAnLycpLnRvTG93ZXJD
YXNlKCk7CiAgbGV0IHJvb3QgPSBudWxsOwogIGZvciAoY29uc3QgZW50cnkgb2YgZW50cmllcykg
ewogICAgY29uc3QgbmFtZSA9IGxvd2VyKGVudHJ5Lm5hbWUpOwogICAgaWYgKG5hbWUgPT09ICdk
YXRhL2RhdGEudHh0JyB8fCBuYW1lLmVuZHNXaXRoKCcvZGF0YS9kYXRhLnR4dCcpKSB7CiAgICAg
IGNvbnN0IGZvbGRlciA9IG5hbWUuc2xpY2UoMCwgbmFtZS5sZW5ndGggLSAnZGF0YS9kYXRhLnR4
dCcubGVuZ3RoKTsKICAgICAgaWYgKHJvb3QgPT09IG51bGwgfHwgZm9sZGVyLmxlbmd0aCA8IHJv
b3QubGVuZ3RoKSByb290ID0gZm9sZGVyOwogICAgfQogIH0KICBpZiAocm9vdCA9PT0gbnVsbCkg
dGhyb3cgbmV3IFBhY2tFcnJvcignbm8gZGF0YS9kYXRhLnR4dCBpbnNpZGU6IHRoaXMgaXMgbm90
IGFuIExGMiBnYW1lIGZvbGRlcicpOwogIGNvbnN0IGluc2lkZSA9IFtdOwogIGZvciAoY29uc3Qg
ZW50cnkgb2YgZW50cmllcykgewogICAgY29uc3QgbmFtZSA9IGxvd2VyKGVudHJ5Lm5hbWUpOwog
ICAgaWYgKCFuYW1lLnN0YXJ0c1dpdGgocm9vdCkgfHwgbmFtZS5lbmRzV2l0aCgnLycpIHx8IG5h
bWUubGVuZ3RoID09PSByb290Lmxlbmd0aCkgY29udGludWU7CiAgICBpbnNpZGUucHVzaCh7IGVu
dHJ5LCBwYXRoOiBuYW1lLnNsaWNlKHJvb3QubGVuZ3RoKSB9KTsKICB9CiAgLy8gQW5vdGhlciBj
b3B5IG9mIGEgZ2FtZSBpbnNpZGUgdGhpcyBvbmUgKGEgc3ViZm9sZGVyIHdpdGggaXRzIG93biBk
YXRhL2RhdGEudHh0KS4KICBjb25zdCBjb3BpZXMgPSBpbnNpZGUuZmlsdGVyKCh7IHBhdGg6IG5h
bWUgfSkgPT4gbmFtZSAhPT0gJ2RhdGEvZGF0YS50eHQnICYmIG5hbWUuZW5kc1dpdGgoJy9kYXRh
L2RhdGEudHh0JykpCiAgICAubWFwKCh7IHBhdGg6IG5hbWUgfSkgPT4gbmFtZS5zbGljZSgwLCBu
YW1lLmxlbmd0aCAtICdkYXRhL2RhdGEudHh0Jy5sZW5ndGgpKTsKICBjb25zdCBleGVjdXRhYmxl
cyA9IGluc2lkZS5maWx0ZXIoKHsgcGF0aDogbmFtZSB9KSA9PiAhbmFtZS5pbmNsdWRlcygnLycp
ICYmIG5hbWUuZW5kc1dpdGgoJy5leGUnKSk7CiAgaWYgKCFleGVjdXRhYmxlcy5sZW5ndGgpIHRo
cm93IG5ldyBQYWNrRXJyb3IoJ25vIGdhbWUgcHJvZ3JhbSAoLmV4ZSkgYmVzaWRlIGl0cyBkYXRh
IGZvbGRlcicpOwogIGNvbnN0IG1haW4gPSBleGVjdXRhYmxlcy5maW5kKCh7IHBhdGg6IG5hbWUg
fSkgPT4gbmFtZSA9PT0gJ2xmMi5leGUnKQogICAgfHwgZXhlY3V0YWJsZXMucmVkdWNlKChsYXJn
ZXN0LCBpdGVtKSA9PiAoaXRlbS5lbnRyeS5zaXplID4gbGFyZ2VzdC5lbnRyeS5zaXplID8gaXRl
bSA6IGxhcmdlc3QpKTsKICBjb25zdCBrZWVwID0gW107CiAgZm9yIChjb25zdCBpdGVtIG9mIGlu
c2lkZSkgewogICAgY29uc3QgbmFtZSA9IGl0ZW0ucGF0aDsKICAgIGNvbnN0IHRvcExldmVsID0g
IW5hbWUuaW5jbHVkZXMoJy8nKTsKICAgIGlmIChjb3BpZXMuc29tZSgoY29weSkgPT4gbmFtZS5z
dGFydHNXaXRoKGNvcHkpKSkgY29udGludWU7CiAgICBpZiAobmFtZS5zdGFydHNXaXRoKCdyZWNv
cmRpbmcvJykpIGNvbnRpbnVlOwogICAgaWYgKHRvcExldmVsICYmIG5hbWUuZW5kc1dpdGgoJy5l
eGUnKSAmJiBpdGVtICE9PSBtYWluKSBjb250aW51ZTsKICAgIGlmICh0b3BMZXZlbCAmJiBOT1RF
Uy50ZXN0KG5hbWUpKSBjb250aW51ZTsKICAgIGlmIChpdGVtLmVudHJ5LmZsYWdzICYgMSkgdGhy
b3cgbmV3IFBhY2tFcnJvcihgJHtpdGVtLmVudHJ5Lm5hbWV9IGlzIGVuY3J5cHRlZGApOwogICAg
aWYgKGl0ZW0uZW50cnkubWV0aG9kICE9PSAwICYmIGl0ZW0uZW50cnkubWV0aG9kICE9PSA4KSB7
CiAgICAgIHRocm93IG5ldyBQYWNrRXJyb3IoYCR7aXRlbS5lbnRyeS5uYW1lfSB1c2VzIGEgY29t
cHJlc3Npb24gdGhlIGdhbWUgY2Fubm90IHJlYWQgKHppcCBpdCBhZ2FpbiB3aXRoIERlZmxhdGUp
YCk7CiAgICB9CiAgICAvLyBUaGUgZ2FtZSByZWFkcyBmaWxlcyB1cCB0byAyNTYgTWlCIGZyb20g
YSBwYWNrIChzcmMvcmVzb3VyY2VzL3BhY2suY3BwKS4KICAgIGlmIChpdGVtLmVudHJ5LnNpemUg
PiAyNTYgKiBNSUIpIHRocm93IG5ldyBQYWNrRXJyb3IoYCR7aXRlbS5lbnRyeS5uYW1lfSBpcyBs
YXJnZXIgdGhhbiAyNTYgTUJgKTsKICAgIGtlZXAucHVzaChpdGVtLmVudHJ5KTsKICB9CiAgcmV0
dXJuIHsgcm9vdCwgZXhlY3V0YWJsZTogbWFpbi5wYXRoLCBrZWVwLCBkcm9wcGVkOiBlbnRyaWVz
Lmxlbmd0aCAtIGtlZXAubGVuZ3RoIH07Cn0KCi8vIC0tLS0gRmxhc2ggZ2FtZXMgLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLQovLyBBIEZsYXNoIHByb2plY3RvciAoRmxhc2ggUGxheWVyIGZvciBX
aW5kb3dzIHdpdGggYSBtb3ZpZSBpbnNpZGUpIGVuZHMgd2l0aCAweEZBMTIzNDU2IGFuZCB0aGUg
bW92aWUncwovLyBsZW5ndGggKGJvdGggNCBieXRlcywgbGl0dGxlIGVuZGlhbiksIHRoZSBtb3Zp
ZSBqdXN0IGJlZm9yZS4KY29uc3QgUFJPSkVDVE9SX01BR0lDID0gMHhmYTEyMzQ1NjsKLy8gSGVy
byBGaWdodGVyJ3MgbW92aWVzOiB0aGUgb25lIGluICJIRnYwLjcrLmV4ZSIgKEhlcm8gRmlnaHRl
ciB2MC43KywgMjAyMS0xMC0xMSkuCmNvbnN0IEhFUk9fRklHSFRFUiA9IG5ldyBTZXQoWyc0MmFl
YzVlNjgzYmRjYWJkNWNhZjYxODFiZTVmZTc0NjE4YWZlNTM2ZWM2MjAzMDczNGQ5NTM2ZmFiMTg1
MmE4J10pOwpjb25zdCBIRVJPX0ZJR0hURVJfTUFSSyA9IEJ1ZmZlci5mcm9tKCdodHRwOi8vd3d3
Lmhlcm9maWdodGVyLmNvbS92ZXIudHh0JywgJ2xhdGluMScpOwoKZnVuY3Rpb24gaXNTd2YoYnl0
ZXMpIHsKICByZXR1cm4gYnl0ZXMubGVuZ3RoID4gOCAmJiBbJ0ZXUycsICdDV1MnLCAnWldTJ10u
aW5jbHVkZXMoYnl0ZXMudG9TdHJpbmcoJ2xhdGluMScsIDAsIDMpKTsKfQoKLy8gVGhlIG1vdmll
IG9mIGEgcHJvamVjdG9yIG9yIG9mIGEgbW92aWUgZmlsZTsgbnVsbCBmb3IgYW55dGhpbmcgZWxz
ZS4KZnVuY3Rpb24gbW92aWVPZihieXRlcykgewogIGlmIChpc1N3ZihieXRlcykpIHJldHVybiBi
eXRlczsKICBpZiAoYnl0ZXMubGVuZ3RoIDwgMTYgfHwgYnl0ZXMudG9TdHJpbmcoJ2xhdGluMScs
IDAsIDIpICE9PSAnTVonKSByZXR1cm4gbnVsbDsKICBpZiAoYnl0ZXMucmVhZFVJbnQzMkxFKGJ5
dGVzLmxlbmd0aCAtIDgpICE9PSBQUk9KRUNUT1JfTUFHSUMpIHJldHVybiBudWxsOwogIGNvbnN0
IGxlbmd0aCA9IGJ5dGVzLnJlYWRVSW50MzJMRShieXRlcy5sZW5ndGggLSA0KTsKICBpZiAobGVu
Z3RoIDwgOSB8fCBsZW5ndGggPiBieXRlcy5sZW5ndGggLSA4KSByZXR1cm4gbnVsbDsKICBjb25z
dCBtb3ZpZSA9IGJ5dGVzLnN1YmFycmF5KGJ5dGVzLmxlbmd0aCAtIDggLSBsZW5ndGgsIGJ5dGVz
Lmxlbmd0aCAtIDgpOwogIHJldHVybiBpc1N3Zihtb3ZpZSkgPyBtb3ZpZSA6IG51bGw7Cn0KCi8v
IFdoaWNoIGdhbWUgYSBtb3ZpZSBpczogImhlcm9maWdodGVyIiwgb3IgIiIgZm9yIG9uZSB0aGlz
IHJlbGF5IGRvZXMgbm90IGtub3cuCmZ1bmN0aW9uIGZsYXNoR2FtZShtb3ZpZSkgewogIGNvbnN0
IHNoYTI1NiA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYnKS51cGRhdGUobW92aWUpLmRpZ2Vz
dCgnaGV4Jyk7CiAgaWYgKEhFUk9fRklHSFRFUi5oYXMoc2hhMjU2KSkgcmV0dXJuICdoZXJvZmln
aHRlcic7CiAgLy8gQW4gdW5jb21wcmVzc2VkIG1vdmllIGNhbiBiZSBzZWFyY2hlZCBhcyBpdCBp
cyAoSGVybyBGaWdodGVyJ3MgcHJvamVjdG9yIG1vdmllcyBhcmUpLgogIGlmIChtb3ZpZS50b1N0
cmluZygnbGF0aW4xJywgMCwgMykgPT09ICdGV1MnICYmIG1vdmllLmluY2x1ZGVzKEhFUk9fRklH
SFRFUl9NQVJLKSkgcmV0dXJuICdoZXJvZmlnaHRlcic7CiAgcmV0dXJuICcnOwp9CgovLyBBbiBl
bnRyeSdzIGJ5dGVzIChzdG9yZWQgb3IgRGVmbGF0ZSkuCmFzeW5jIGZ1bmN0aW9uIHJlYWRFbnRy
eShmaWxlLCBlbnRyeSkgewogIGNvbnN0IGhhbmRsZSA9IGF3YWl0IGZzcC5vcGVuKGZpbGUsICdy
Jyk7CiAgdHJ5IHsKICAgIGNvbnN0IGhlYWRlciA9IEJ1ZmZlci5hbGxvYygzMCk7CiAgICBhd2Fp
dCBoYW5kbGUucmVhZChoZWFkZXIsIDAsIDMwLCBlbnRyeS5sb2NhbE9mZnNldCk7CiAgICBpZiAo
aGVhZGVyLnJlYWRVSW50MzJMRSgwKSAhPT0gMHgwNDAzNGI1MCkgdGhyb3cgbmV3IFBhY2tFcnJv
cigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgIGNvbnN0IHN0YXJ0ID0gZW50cnkubG9j
YWxPZmZzZXQgKyAzMCArIGhlYWRlci5yZWFkVUludDE2TEUoMjYpICsgaGVhZGVyLnJlYWRVSW50
MTZMRSgyOCk7CiAgICBjb25zdCBwYWNrZWQgPSBCdWZmZXIuYWxsb2MoZW50cnkuY29tcHJlc3Nl
ZFNpemUpOwogICAgYXdhaXQgaGFuZGxlLnJlYWQocGFja2VkLCAwLCBwYWNrZWQubGVuZ3RoLCBz
dGFydCk7CiAgICBpZiAoZW50cnkubWV0aG9kID09PSAwKSByZXR1cm4gcGFja2VkOwogICAgaWYg
KGVudHJ5Lm1ldGhvZCA9PT0gOCkgcmV0dXJuIHpsaWIuaW5mbGF0ZVJhd1N5bmMocGFja2VkLCB7
IG1heE91dHB1dExlbmd0aDogNTEyICogTUlCIH0pOwogICAgdGhyb3cgbmV3IFBhY2tFcnJvcihg
JHtlbnRyeS5uYW1lfSB1c2VzIGEgY29tcHJlc3Npb24gdGhlIHJlbGF5IGNhbm5vdCByZWFkICh6
aXAgaXQgYWdhaW4gd2l0aCBEZWZsYXRlKWApOwogIH0gZmluYWxseSB7CiAgICBhd2FpdCBoYW5k
bGUuY2xvc2UoKTsKICB9Cn0KCi8vIFRoZSBGbGFzaCBtb3ZpZSBhbiB1cGxvYWQgaG9sZHMgKGEg
bW92aWUgb3IgcHJvamVjdG9yIGZpbGUsIG9yIGEgWklQIGZpbGUgd2l0aCBvbmUpLCBvciBudWxs
Lgphc3luYyBmdW5jdGlvbiBmaW5kTW92aWUoZmlsZSwgemlwKSB7CiAgaWYgKCF6aXApIHsKICAg
IGNvbnN0IHsgc2l6ZSB9ID0gYXdhaXQgZnNwLnN0YXQoZmlsZSk7CiAgICBpZiAoc2l6ZSA+IDUx
MiAqIE1JQikgcmV0dXJuIG51bGw7CiAgICByZXR1cm4gbW92aWVPZihhd2FpdCBmc3AucmVhZEZp
bGUoZmlsZSkpOwogIH0KICBjb25zdCBjYW5kaWRhdGVzID0gemlwLmVudHJpZXMKICAgIC5maWx0
ZXIoKGVudHJ5KSA9PiAvXC4oc3dmfGV4ZSkkL2kudGVzdChlbnRyeS5uYW1lKSAmJiAhKGVudHJ5
LmZsYWdzICYgMSkgJiYgZW50cnkuc2l6ZSA8PSA1MTIgKiBNSUIpCiAgICAuc29ydCgoYSwgYikg
PT4gYi5zaXplIC0gYS5zaXplKTsKICBmb3IgKGNvbnN0IGVudHJ5IG9mIGNhbmRpZGF0ZXMpIHsK
ICAgIGNvbnN0IG1vdmllID0gbW92aWVPZihhd2FpdCByZWFkRW50cnkoZmlsZSwgZW50cnkpKTsK
ICAgIGlmIChtb3ZpZSkgcmV0dXJuIG1vdmllOwogIH0KICByZXR1cm4gbnVsbDsKfQoKLy8gV3Jp
dGVzIHRoZSBrZXB0IGVudHJpZXMgb2YgYHNvdXJjZWAgYXMgYSBuZXcgWklQIGZpbGUsIGNvcHlp
bmcgdGhlaXIgY29tcHJlc3NlZCBieXRlcyBhcyB0aGV5IGFyZS4KYXN5bmMgZnVuY3Rpb24gd3Jp
dGVaaXAoc291cmNlLCB0YXJnZXQsIGtlZXApIHsKICBjb25zdCBpbnB1dCA9IGF3YWl0IGZzcC5v
cGVuKHNvdXJjZSwgJ3InKTsKICBjb25zdCBvdXRwdXQgPSBhd2FpdCBmc3Aub3Blbih0YXJnZXQs
ICd3Jyk7CiAgY29uc3QgaGFzaCA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYnKTsKICBsZXQg
b2Zmc2V0ID0gMDsKICBjb25zdCB3cml0ZSA9IGFzeW5jIChidWZmZXIpID0+IHsKICAgIGxldCBk
b25lID0gMDsKICAgIHdoaWxlIChkb25lIDwgYnVmZmVyLmxlbmd0aCkgewogICAgICBjb25zdCB7
IGJ5dGVzV3JpdHRlbiB9ID0gYXdhaXQgb3V0cHV0LndyaXRlKGJ1ZmZlciwgZG9uZSwgYnVmZmVy
Lmxlbmd0aCAtIGRvbmUsIG9mZnNldCArIGRvbmUpOwogICAgICBkb25lICs9IGJ5dGVzV3JpdHRl
bjsKICAgIH0KICAgIGhhc2gudXBkYXRlKGJ1ZmZlcik7CiAgICBvZmZzZXQgKz0gYnVmZmVyLmxl
bmd0aDsKICB9OwogIHRyeSB7CiAgICBjb25zdCByZWNvcmRzID0gW107CiAgICBmb3IgKGNvbnN0
IGVudHJ5IG9mIGtlZXApIHsKICAgICAgY29uc3QgaGVhZGVyID0gQnVmZmVyLmFsbG9jKDMwKTsK
ICAgICAgYXdhaXQgaW5wdXQucmVhZChoZWFkZXIsIDAsIDMwLCBlbnRyeS5sb2NhbE9mZnNldCk7
CiAgICAgIGlmIChoZWFkZXIucmVhZFVJbnQzMkxFKDApICE9PSAweDA0MDM0YjUwKSB0aHJvdyBu
ZXcgUGFja0Vycm9yKCd0aGUgWklQIGZpbGUgaXMgZGFtYWdlZCcpOwogICAgICBsZXQgbGVuZ3Ro
ID0gMzAgKyBoZWFkZXIucmVhZFVJbnQxNkxFKDI2KSArIGhlYWRlci5yZWFkVUludDE2TEUoMjgp
ICsgZW50cnkuY29tcHJlc3NlZFNpemU7CiAgICAgIGlmIChlbnRyeS5mbGFncyAmIDgpIHsgLy8g
YSBkYXRhIGRlc2NyaXB0b3IgZm9sbG93cyB0aGUgZGF0YQogICAgICAgIGNvbnN0IHByb2JlID0g
QnVmZmVyLmFsbG9jKDQpOwogICAgICAgIGF3YWl0IGlucHV0LnJlYWQocHJvYmUsIDAsIDQsIGVu
dHJ5LmxvY2FsT2Zmc2V0ICsgbGVuZ3RoKTsKICAgICAgICBsZW5ndGggKz0gcHJvYmUucmVhZFVJ
bnQzMkxFKDApID09PSAweDA4MDc0YjUwID8gMTYgOiAxMjsKICAgICAgfQogICAgICBjb25zdCBy
ZWNvcmQgPSBCdWZmZXIuZnJvbShlbnRyeS5yZWNvcmQpOwogICAgICByZWNvcmQud3JpdGVVSW50
MzJMRShvZmZzZXQsIDQyKTsKICAgICAgcmVjb3Jkcy5wdXNoKHJlY29yZCk7CiAgICAgIGZvciAo
bGV0IGNvcGllZCA9IDA7IGNvcGllZCA8IGxlbmd0aDspIHsKICAgICAgICBjb25zdCBjaHVuayA9
IEJ1ZmZlci5hbGxvYyhNYXRoLm1pbig0ICogTUlCLCBsZW5ndGggLSBjb3BpZWQpKTsKICAgICAg
ICBjb25zdCB7IGJ5dGVzUmVhZCB9ID0gYXdhaXQgaW5wdXQucmVhZChjaHVuaywgMCwgY2h1bmsu
bGVuZ3RoLCBlbnRyeS5sb2NhbE9mZnNldCArIGNvcGllZCk7CiAgICAgICAgaWYgKCFieXRlc1Jl
YWQpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAgZmlsZSBpcyBkYW1hZ2VkJyk7CiAgICAg
ICAgYXdhaXQgd3JpdGUoY2h1bmsuc3ViYXJyYXkoMCwgYnl0ZXNSZWFkKSk7CiAgICAgICAgY29w
aWVkICs9IGJ5dGVzUmVhZDsKICAgICAgfQogICAgfQogICAgY29uc3QgZGlyZWN0b3J5T2Zmc2V0
ID0gb2Zmc2V0OwogICAgZm9yIChjb25zdCByZWNvcmQgb2YgcmVjb3JkcykgYXdhaXQgd3JpdGUo
cmVjb3JkKTsKICAgIGNvbnN0IGVuZCA9IEJ1ZmZlci5hbGxvYygyMik7CiAgICBlbmQud3JpdGVV
SW50MzJMRSgweDA2MDU0YjUwLCAwKTsKICAgIGVuZC53cml0ZVVJbnQxNkxFKHJlY29yZHMubGVu
Z3RoLCA4KTsKICAgIGVuZC53cml0ZVVJbnQxNkxFKHJlY29yZHMubGVuZ3RoLCAxMCk7CiAgICBl
bmQud3JpdGVVSW50MzJMRShvZmZzZXQgLSBkaXJlY3RvcnlPZmZzZXQsIDEyKTsKICAgIGVuZC53
cml0ZVVJbnQzMkxFKGRpcmVjdG9yeU9mZnNldCwgMTYpOwogICAgYXdhaXQgd3JpdGUoZW5kKTsK
ICAgIHJldHVybiB7IHNpemU6IG9mZnNldCwgc2hhMjU2OiBoYXNoLmRpZ2VzdCgnaGV4JyksIGZp
bGVzOiByZWNvcmRzLmxlbmd0aCB9OwogIH0gZmluYWxseSB7CiAgICBhd2FpdCBpbnB1dC5jbG9z
ZSgpOwogICAgYXdhaXQgb3V0cHV0LmNsb3NlKCk7CiAgfQp9CgpmdW5jdGlvbiBzYW1lS2V5KGdp
dmVuLCBleHBlY3RlZCkgewogIGNvbnN0IGEgPSBjcnlwdG8uY3JlYXRlSGFzaCgnc2hhMjU2Jyku
dXBkYXRlKFN0cmluZyhnaXZlbiB8fCAnJykpLmRpZ2VzdCgpOwogIGNvbnN0IGIgPSBjcnlwdG8u
Y3JlYXRlSGFzaCgnc2hhMjU2JykudXBkYXRlKFN0cmluZyhleHBlY3RlZCkpLmRpZ2VzdCgpOwog
IHJldHVybiBjcnlwdG8udGltaW5nU2FmZUVxdWFsKGEsIGIpOwp9CgpmdW5jdGlvbiBjcmVhdGVQ
YWNrcyhjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzLCBhbGxvd09yaWdpbiwgaGZKb3VybmFs
ID0gbnVsbCwgaGZBY2NvdW50cyA9IG51bGwgfSkgewogIGNvbnN0IGRpcmVjdG9yeSA9IGNvbmZp
Zy5wYWNrc0RpcjsKICBjb25zdCBkb3dubG9hZHMgPSBuZXcgTWFwKCk7IC8vIGNsaWVudCBhZGRy
ZXNzIC0+IHsgY291bnQsIHVudGlsIH0KICBjb25zdCBmYWlsdXJlcyA9IG5ldyBNYXAoKTsgLy8g
Y2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwgfQogIGxldCB1cGxvYWRpbmcgPSBmYWxz
ZTsKCiAgY29uc3QganNvbiA9IChyZXMsIHN0YXR1cywgYm9keSwgaGVhZGVycyA9IHt9KSA9PiB7
CiAgICByZXMud3JpdGVIZWFkKHN0YXR1cywgeyAnY29udGVudC10eXBlJzogJ2FwcGxpY2F0aW9u
L2pzb247IGNoYXJzZXQ9dXRmLTgnLCAnY2FjaGUtY29udHJvbCc6ICduby1zdG9yZScsIC4uLmhl
YWRlcnMgfSk7CiAgICByZXMuZW5kKEpTT04uc3RyaW5naWZ5KGJvZHkpKTsKICB9OwogIGNvbnN0
IGNvdW50ZWQgPSAobWFwLCBhZGRyZXNzLCBsaW1pdCkgPT4gewogICAgY29uc3Qgbm93ID0gRGF0
ZS5ub3coKTsKICAgIGxldCBlbnRyeSA9IG1hcC5nZXQoYWRkcmVzcyk7CiAgICBpZiAoIWVudHJ5
IHx8IGVudHJ5LnVudGlsIDw9IG5vdykgewogICAgICBlbnRyeSA9IHsgY291bnQ6IDAsIHVudGls
OiBub3cgKyAzNjAwMDAwIH07CiAgICAgIG1hcC5zZXQoYWRkcmVzcywgZW50cnkpOwogICAgfQog
ICAgcmV0dXJuIHsgb3ZlcjogbGltaXQgPiAwICYmIGVudHJ5LmNvdW50ID49IGxpbWl0LCBhZGQ6
ICgpID0+IHsgZW50cnkuY291bnQgKz0gMTsgfSwgcmV0cnk6IE1hdGguY2VpbCgoZW50cnkudW50
aWwgLSBub3cpIC8gMTAwMCkgfTsKICB9OwoKICBhc3luYyBmdW5jdGlvbiBsaXN0KCkgewogICAg
aWYgKCFkaXJlY3RvcnkpIHJldHVybiBbXTsKICAgIGxldCBuYW1lczsKICAgIHRyeSB7IG5hbWVz
ID0gYXdhaXQgZnNwLnJlYWRkaXIoZGlyZWN0b3J5KTsgfSBjYXRjaCB7IHJldHVybiBbXTsgfQog
ICAgY29uc3QgcGFja3MgPSBbXTsKICAgIGZvciAoY29uc3QgbmFtZSBvZiBuYW1lcykgewogICAg
ICBpZiAoIW5hbWUuZW5kc1dpdGgoJy5qc29uJykpIGNvbnRpbnVlOwogICAgICBjb25zdCBpZCA9
IG5hbWUuc2xpY2UoMCwgLTUpOwogICAgICBpZiAoIVBBQ0tfSUQudGVzdChpZCkpIGNvbnRpbnVl
OwogICAgICB0cnkgewogICAgICAgIGNvbnN0IGluZm8gPSBKU09OLnBhcnNlKGF3YWl0IGZzcC5y
ZWFkRmlsZShwYXRoLmpvaW4oZGlyZWN0b3J5LCBuYW1lKSwgJ3V0ZjgnKSk7CiAgICAgICAgY29u
c3Qga2luZCA9IGluZm8ua2luZCA9PT0gJ2ZsYXNoJyA/ICdmbGFzaCcgOiAnbGYyJzsKICAgICAg
ICBjb25zdCBzdGF0ID0gYXdhaXQgZnNwLnN0YXQocGF0aC5qb2luKGRpcmVjdG9yeSwgYCR7aWR9
LiR7a2luZCA9PT0gJ2ZsYXNoJyA/ICdzd2YnIDogJ3ppcCd9YCkpOwogICAgICAgIHBhY2tzLnB1
c2goeyBpZCwgdGl0bGU6IFN0cmluZyhpbmZvLnRpdGxlIHx8IGlkKSwgc2l6ZTogc3RhdC5zaXpl
LCBzaGEyNTY6IFN0cmluZyhpbmZvLnNoYTI1NiB8fCAnJyksCiAgICAgICAgICBraW5kLCBnYW1l
OiBTdHJpbmcoaW5mby5nYW1lIHx8ICcnKSwgZmlsZXM6IGluZm8uZmlsZXMsIHVwbG9hZGVkOiBp
bmZvLnVwbG9hZGVkLCBvcmlnaW5hbDogaW5mby5vcmlnaW5hbCB9KTsKICAgICAgfSBjYXRjaCB7
IC8qIGEgaGFsZi13cml0dGVuIG9yIHJlbW92ZWQgcGFjayAqLyB9CiAgICB9CiAgICByZXR1cm4g
cGFja3Muc29ydCgoYSwgYikgPT4gYS50aXRsZS5sb2NhbGVDb21wYXJlKGIudGl0bGUpKTsKICB9
CgogIGZ1bmN0aW9uIGF1dGhvcml6ZWQocmVxLCByZXMpIHsKICAgIGlmICghY29uZmlnLmFkbWlu
S2V5KSB7CiAgICAgIGpzb24ocmVzLCA0MDMsIHsgZXJyb3I6ICdDaMawYSDEkeG6t3QgQURNSU5f
S0VZIGNobyByZWxheSAoY2jhuqF5IGzhuqFpIGluc3RhbGwtdnBzLnNoKS4nIH0pOwogICAgICBy
ZXR1cm4gZmFsc2U7CiAgICB9CiAgICBjb25zdCBhZGRyZXNzID0gY2xpZW50QWRkcmVzcyhyZXEp
OwogICAgY29uc3QgdHJpZXMgPSBjb3VudGVkKGZhaWx1cmVzLCBhZGRyZXNzLCAyMCk7CiAgICBp
ZiAodHJpZXMub3ZlcikgewogICAgICBqc29uKHJlcywgNDI5LCB7IGVycm9yOiAnU2FpIG3DoyBx
dcOhIG5oaeG7gXUgbOG6p24sIHRo4butIGzhuqFpIHNhdSBt4buZdCBnaeG7nS4nIH0sIHsgJ3Jl
dHJ5LWFmdGVyJzogU3RyaW5nKHRyaWVzLnJldHJ5KSB9KTsKICAgICAgcmV0dXJuIGZhbHNlOwog
ICAgfQogICAgaWYgKCFzYW1lS2V5KHJlcS5oZWFkZXJzWyd4LWFkbWluLWtleSddLCBjb25maWcu
YWRtaW5LZXkpKSB7CiAgICAgIHRyaWVzLmFkZCgpOwogICAgICBqc29uKHJlcywgNDAxLCB7IGVy
cm9yOiAnU2FpIG3DoyBxdeG6o24gdHLhu4sgKEFETUlOX0tFWSkuJyB9KTsKICAgICAgcmV0dXJu
IGZhbHNlOwogICAgfQogICAgcmV0dXJuIHRydWU7CiAgfQoKICBhc3luYyBmdW5jdGlvbiB1cGxv
YWQocmVxLCByZXMsIGlkLCB0aXRsZSkgewogICAgaWYgKCFkaXJlY3RvcnkpIHJldHVybiBqc29u
KHJlcywgNTAzLCB7IGVycm9yOiAnUmVsYXkgbsOgeSBraMO0bmcgZ2nhu68gYuG6o24gbW9kIChj
aMawYSDEkeG6t3QgUEFDS1NfRElSKS4nIH0pOwogICAgaWYgKHVwbG9hZGluZykgcmV0dXJuIGpz
b24ocmVzLCA0MDksIHsgZXJyb3I6ICfEkGFuZyBjw7MgbeG7mXQgbOG6p24gdOG6o2kgbMOqbiBr
aMOhYywgY2jhu50geG9uZyBy4buTaSB0aOG7rSBs4bqhaS4nIH0pOwogICAgY29uc3QgZGVjbGFy
ZWQgPSBOdW1iZXIocmVxLmhlYWRlcnNbJ2NvbnRlbnQtbGVuZ3RoJ10gfHwgMCk7CiAgICBpZiAo
ZGVjbGFyZWQgPiBjb25maWcubWF4UGFja0J5dGVzKSB7CiAgICAgIHJldHVybiBqc29uKHJlcywg
NDEzLCB7IGVycm9yOiBgRmlsZSBxdcOhIGzhu5tuICh04buRaSDEkWEgJHtNYXRoLnJvdW5kKGNv
bmZpZy5tYXhQYWNrQnl0ZXMgLyBNSUIpfSBNQikuYCB9KTsKICAgIH0KICAgIGF3YWl0IGZzcC5t
a2RpcihkaXJlY3RvcnksIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwogICAgdHJ5IHsKICAgICAgY29u
c3Qgc3BhY2UgPSBhd2FpdCBmc3Auc3RhdGZzKGRpcmVjdG9yeSk7CiAgICAgIGNvbnN0IGZyZWUg
PSBzcGFjZS5iYXZhaWwgKiBzcGFjZS5ic2l6ZTsKICAgICAgaWYgKGZyZWUgPCAyICogZGVjbGFy
ZWQgKyAyNTYgKiBNSUIpIHsKICAgICAgICByZXR1cm4ganNvbihyZXMsIDUwNywgeyBlcnJvcjog
YFZQUyBraMO0bmcgxJHhu6cgY2jhu5cgdHLhu5FuZyAoY8OybiAke01hdGgucm91bmQoZnJlZSAv
IE1JQil9IE1CKS5gIH0pOwogICAgICB9CiAgICB9IGNhdGNoIHsgLyogc3RhdGZzIHVuYXZhaWxh
YmxlOiB0cnkgYW55d2F5ICovIH0KICAgIHVwbG9hZGluZyA9IHRydWU7CiAgICBjb25zdCBub25j
ZSA9IGNyeXB0by5yYW5kb21CeXRlcyg2KS50b1N0cmluZygnaGV4Jyk7CiAgICBjb25zdCByZWNl
aXZlZCA9IHBhdGguam9pbihkaXJlY3RvcnksIGAudXBsb2FkLSR7bm9uY2V9LnppcGApOwogICAg
Y29uc3Qgc2xpbSA9IHBhdGguam9pbihkaXJlY3RvcnksIGAucGFjay0ke25vbmNlfS56aXBgKTsK
ICAgIHRyeSB7CiAgICAgIGxldCBieXRlcyA9IDA7CiAgICAgIGNvbnN0IGNvdW50ZXIgPSBuZXcg
VHJhbnNmb3JtKHsKICAgICAgICB0cmFuc2Zvcm0oY2h1bmssIGVuY29kaW5nLCBkb25lKSB7CiAg
ICAgICAgICBieXRlcyArPSBjaHVuay5sZW5ndGg7CiAgICAgICAgICBpZiAoYnl0ZXMgPiBjb25m
aWcubWF4UGFja0J5dGVzKSBkb25lKG5ldyBQYWNrRXJyb3IoYEZpbGUgcXXDoSBs4bubbiAodOG7
kWkgxJFhICR7TWF0aC5yb3VuZChjb25maWcubWF4UGFja0J5dGVzIC8gTUlCKX0gTUIpLmApKTsK
ICAgICAgICAgIGVsc2UgZG9uZShudWxsLCBjaHVuayk7CiAgICAgICAgfSwKICAgICAgfSk7CiAg
ICAgIGF3YWl0IHBpcGVsaW5lKHJlcSwgY291bnRlciwgZnMuY3JlYXRlV3JpdGVTdHJlYW0ocmVj
ZWl2ZWQpKTsKICAgICAgaWYgKGRlY2xhcmVkICYmIGJ5dGVzICE9PSBkZWNsYXJlZCkgdGhyb3cg
bmV3IFBhY2tFcnJvcignVOG6o2kgbMOqbiBi4buLIG5n4bqvdCBnaeG7r2EgY2jhu6tuZy4nKTsK
ICAgICAgbGV0IHppcCA9IG51bGw7CiAgICAgIHRyeSB7IHppcCA9IGF3YWl0IHJlYWRaaXAocmVj
ZWl2ZWQpOyB9IGNhdGNoIChlcnJvcikgeyBpZiAoIShlcnJvciBpbnN0YW5jZW9mIFBhY2tFcnJv
cikpIHRocm93IGVycm9yOyB9CiAgICAgIGNvbnN0IGxmMiA9IHppcCAmJiB6aXAuZW50cmllcy5z
b21lKCh7IG5hbWUgfSkgPT4gLyhefFtcXC9dKWRhdGFbXFwvXWRhdGFcLnR4dCQvaS50ZXN0KG5h
bWUpKTsKICAgICAgaWYgKCFsZjIpIHsKICAgICAgICAvLyBBIEZsYXNoIGdhbWUsIG9yIHdoYXQg
cmVhZFppcC9hbmFseXplWmlwIHNheSB0aGlzIGlzIG5vdC4KICAgICAgICBjb25zdCBtb3ZpZSA9
IGF3YWl0IGZpbmRNb3ZpZShyZWNlaXZlZCwgemlwKTsKICAgICAgICBpZiAoIW1vdmllKSB7CiAg
ICAgICAgICBpZiAoIXppcCkgdGhyb3cgbmV3IFBhY2tFcnJvcignxJDDonkga2jDtG5nIHBo4bqj
aSBmaWxlIC56aXAsIGPFqW5nIGtow7RuZyBwaOG6o2kgZ2FtZSBGbGFzaCAoLnN3ZiBob+G6t2Mg
LmV4ZSBjw7MgZ2FtZSBGbGFzaCBiw6puIHRyb25nKS4nKTsKICAgICAgICAgIGFuYWx5emVaaXAo
emlwLmVudHJpZXMpOyAvLyB0aHJvd3Mgd2h5IHRoaXMgaXMgbm8gTEYyIGdhbWUgZm9sZGVyCiAg
ICAgICAgfQogICAgICAgIGNvbnN0IHNoYTI1NiA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYn
KS51cGRhdGUobW92aWUpLmRpZ2VzdCgnaGV4Jyk7CiAgICAgICAgY29uc3QgZ2FtZSA9IGZsYXNo
R2FtZShtb3ZpZSk7CiAgICAgICAgYXdhaXQgZnNwLndyaXRlRmlsZShzbGltLCBtb3ZpZSk7CiAg
ICAgICAgZm9yIChjb25zdCBvbGQgb2YgW2Ake2lkfS56aXBgLCBgJHtpZH0uc3dmYF0pIGF3YWl0
IGZzcC5ybShwYXRoLmpvaW4oZGlyZWN0b3J5LCBvbGQpLCB7IGZvcmNlOiB0cnVlIH0pOwogICAg
ICAgIGF3YWl0IGZzcC5yZW5hbWUoc2xpbSwgcGF0aC5qb2luKGRpcmVjdG9yeSwgYCR7aWR9LnN3
ZmApKTsKICAgICAgICBjb25zdCBpbmZvID0geyB0aXRsZSwgc2hhMjU2LCBmaWxlczogMSwga2lu
ZDogJ2ZsYXNoJywgZ2FtZSwgdXBsb2FkZWQ6IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKSwKICAg
ICAgICAgIG9yaWdpbmFsOiB7IHNpemU6IGJ5dGVzLCBmaWxlczogemlwID8gemlwLmVudHJpZXMu
bGVuZ3RoIDogMSB9IH07CiAgICAgICAgYXdhaXQgZnNwLndyaXRlRmlsZShwYXRoLmpvaW4oZGly
ZWN0b3J5LCBgJHtpZH0uanNvbmApLCBKU09OLnN0cmluZ2lmeShpbmZvLCBudWxsLCAyKSk7CiAg
ICAgICAgYXdhaXQgZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVlIH0pOwogICAgICAgIGxv
ZyhgcGFjayAke2lkfTogJHtieXRlc30gYnl0ZXMgdXBsb2FkZWQsIGEgRmxhc2ggbW92aWUgb2Yg
JHttb3ZpZS5sZW5ndGh9IGtlcHQke2dhbWUgPyBgICgke2dhbWV9KWAgOiAnJ31gKTsKICAgICAg
ICBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlLCBpZCwgdGl0bGUsIHNpemU6IG1vdmllLmxlbmd0
aCwgc2hhMjU2LCBmaWxlczogMSwgZHJvcHBlZDogaW5mby5vcmlnaW5hbC5maWxlcyAtIDEsCiAg
ICAgICAgICBraW5kOiAnZmxhc2gnLCBnYW1lLCBvcmlnaW5hbDogaW5mby5vcmlnaW5hbCB9KTsK
ICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgY29uc3QgYW5hbHlzaXMgPSBhbmFseXplWmlw
KHppcC5lbnRyaWVzKTsKICAgICAgY29uc3Qgd3JpdHRlbiA9IGF3YWl0IHdyaXRlWmlwKHJlY2Vp
dmVkLCBzbGltLCBhbmFseXNpcy5rZWVwKTsKICAgICAgYXdhaXQgZnNwLnJtKHBhdGguam9pbihk
aXJlY3RvcnksIGAke2lkfS5zd2ZgKSwgeyBmb3JjZTogdHJ1ZSB9KTsKICAgICAgYXdhaXQgZnNw
LnJlbmFtZShzbGltLCBwYXRoLmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uemlwYCkpOwogICAgICBj
b25zdCBpbmZvID0geyB0aXRsZSwgc2hhMjU2OiB3cml0dGVuLnNoYTI1NiwgZmlsZXM6IHdyaXR0
ZW4uZmlsZXMsIGV4ZWN1dGFibGU6IGFuYWx5c2lzLmV4ZWN1dGFibGUsCiAgICAgICAgdXBsb2Fk
ZWQ6IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKSwgb3JpZ2luYWw6IHsgc2l6ZTogYnl0ZXMsIGZp
bGVzOiB6aXAuZW50cmllcy5sZW5ndGggfSB9OwogICAgICBhd2FpdCBmc3Aud3JpdGVGaWxlKHBh
dGguam9pbihkaXJlY3RvcnksIGAke2lkfS5qc29uYCksIEpTT04uc3RyaW5naWZ5KGluZm8sIG51
bGwsIDIpKTsKICAgICAgYXdhaXQgZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVlIH0pOwog
ICAgICBsb2coYHBhY2sgJHtpZH06ICR7Ynl0ZXN9IGJ5dGVzIHVwbG9hZGVkLCAke3dyaXR0ZW4u
c2l6ZX0ga2VwdCAoJHt3cml0dGVuLmZpbGVzfSBmaWxlcylgKTsKICAgICAganNvbihyZXMsIDIw
MCwgeyBvazogdHJ1ZSwgaWQsIHRpdGxlLCBzaXplOiB3cml0dGVuLnNpemUsIHNoYTI1Njogd3Jp
dHRlbi5zaGEyNTYsIGZpbGVzOiB3cml0dGVuLmZpbGVzLAogICAgICAgIGRyb3BwZWQ6IGFuYWx5
c2lzLmRyb3BwZWQsIGV4ZWN1dGFibGU6IGFuYWx5c2lzLmV4ZWN1dGFibGUsIG9yaWdpbmFsOiBp
bmZvLm9yaWdpbmFsIH0pOwogICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgYXdhaXQgZnNwLnJt
KHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVlIH0pOwogICAgICBhd2FpdCBmc3Aucm0oc2xpbSwgeyBm
b3JjZTogdHJ1ZSB9KTsKICAgICAgY29uc3QgbWVzc2FnZSA9IGVycm9yIGluc3RhbmNlb2YgUGFj
a0Vycm9yID8gZXJyb3IubWVzc2FnZSA6ICdLaMO0bmcgbMawdSDEkcaw4bujYyBmaWxlOiAnICsg
KGVycm9yLm1lc3NhZ2UgfHwgZXJyb3IpOwogICAgICBpZiAoIXJlcy5oZWFkZXJzU2VudCkganNv
bihyZXMsIGVycm9yIGluc3RhbmNlb2YgUGFja0Vycm9yID8gNDAwIDogNTAwLCB7IGVycm9yOiBt
ZXNzYWdlIH0pOwogICAgfSBmaW5hbGx5IHsKICAgICAgdXBsb2FkaW5nID0gZmFsc2U7CiAgICB9
CiAgfQoKICBhc3luYyBmdW5jdGlvbiBzZXJ2ZVBhY2socmVxLCByZXMsIGlkLCBleHRlbnNpb24g
PSAnemlwJykgewogICAgY29uc3QgaGVhZGVycyA9IHsgJ3gtY29udGVudC10eXBlLW9wdGlvbnMn
OiAnbm9zbmlmZicsIC4uLmFsbG93T3JpZ2luKHJlcSkgfTsKICAgIGlmIChyZXEubWV0aG9kICE9
PSAnR0VUJyAmJiByZXEubWV0aG9kICE9PSAnSEVBRCcpIHsKICAgICAgcmVzLndyaXRlSGVhZCg0
MDUsIHsgLi4uaGVhZGVycywgYWxsb3c6ICdHRVQsIEhFQUQnIH0pOwogICAgICByZXMuZW5kKCk7
CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGZpbGUgPSBwYXRoLmpvaW4oZGlyZWN0b3J5
IHx8ICcvbm9uZXhpc3RlbnQnLCBgJHtpZH0uJHtleHRlbnNpb259YCk7CiAgICBsZXQgc3RhdDsK
ICAgIHRyeSB7IHN0YXQgPSBhd2FpdCBmc3Auc3RhdChmaWxlKTsgfSBjYXRjaCB7IHN0YXQgPSBu
dWxsOyB9CiAgICBpZiAoIWRpcmVjdG9yeSB8fCAhc3RhdCB8fCAhc3RhdC5pc0ZpbGUoKSkgewog
ICAgICByZXMud3JpdGVIZWFkKDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAg
cmV0dXJuOwogICAgfQogICAgaWYgKHJlcS5tZXRob2QgPT09ICdHRVQnKSB7CiAgICAgIGNvbnN0
IHF1b3RhID0gY291bnRlZChkb3dubG9hZHMsIGNsaWVudEFkZHJlc3MocmVxKSwgY29uZmlnLnBh
Y2tEb3dubG9hZHNQZXJIb3VyKTsKICAgICAgaWYgKHF1b3RhLm92ZXIpIHsKICAgICAgICByZXMu
d3JpdGVIZWFkKDQyOSwgeyAuLi5oZWFkZXJzLCAncmV0cnktYWZ0ZXInOiBTdHJpbmcocXVvdGEu
cmV0cnkpIH0pOwogICAgICAgIHJlcy5lbmQoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAg
ICAgcXVvdGEuYWRkKCk7CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAuLi5oZWFkZXJz
LCAnY29udGVudC10eXBlJzogZXh0ZW5zaW9uID09PSAnc3dmJyA/ICdhcHBsaWNhdGlvbi94LXNo
b2Nrd2F2ZS1mbGFzaCcgOiAnYXBwbGljYXRpb24vemlwJywKICAgICAgJ2NvbnRlbnQtbGVuZ3Ro
JzogU3RyaW5nKHN0YXQuc2l6ZSksCiAgICAgICdjYWNoZS1jb250cm9sJzogJ25vLWNhY2hlJyB9
KTsKICAgIGlmIChyZXEubWV0aG9kID09PSAnSEVBRCcpIHsKICAgICAgcmVzLmVuZCgpOwogICAg
ICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFkU3RyZWFtKGZp
bGUpOwogICAgc3RyZWFtLm9uKCdlcnJvcicsICgpID0+IHJlcy5kZXN0cm95KCkpOwogICAgc3Ry
ZWFtLnBpcGUocmVzKTsKICB9CgogIC8vIFJldHVybnMgdHJ1ZSB3aGVuIHRoZSByZXF1ZXN0IHdh
cyBvbmUgb2YgdGhlIHBhY2tzJyBhbmQgaGFzIGJlZW4gYW5zd2VyZWQgKG9yIGlzIGJlaW5nIGFu
c3dlcmVkKS4KICBmdW5jdGlvbiBoYW5kbGUocmVxLCByZXMsIHBhdGhuYW1lKSB7CiAgICBpZiAo
cGF0aG5hbWUgPT09ICcvbGYyLXBhY2tzLmpzb24nKSB7CiAgICAgIGxpc3QoKS50aGVuKChwYWNr
cykgPT4ganNvbihyZXMsIDIwMCwgeyBwYWNrczogcGFja3MubWFwKCh7IGlkLCB0aXRsZSwgc2l6
ZSwgc2hhMjU2LCBraW5kLCBnYW1lIH0pID0+ICh7IGlkLCB0aXRsZSwgc2l6ZSwgc2hhMjU2LCBr
aW5kLCBnYW1lIH0pKSB9LAogICAgICAgIHsgJ2FjY2Vzcy1jb250cm9sLWFsbG93LW9yaWdpbic6
ICcqJyB9KSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgY29uc3QgcGFjayA9IHBhdGhu
YW1lLm1hdGNoKC9eXC9sZjItcGFja3NcLyhbYS16MC05XVthLXowLTktXXswLDM5fSlcLih6aXB8
c3dmKSQvKTsKICAgIGlmIChwYWNrKSB7CiAgICAgIHNlcnZlUGFjayhyZXEsIHJlcywgcGFja1sx
XSwgcGFja1syXSkuY2F0Y2goKCkgPT4gcmVzLmRlc3Ryb3koKSk7CiAgICAgIHJldHVybiB0cnVl
OwogICAgfQogICAgaWYgKHBhdGhuYW1lID09PSAnL2FkbWluJyB8fCBwYXRobmFtZSA9PT0gJy9h
ZG1pbi8nKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdjb250ZW50LXR5cGUnOiAndGV4
dC9odG1sOyBjaGFyc2V0PXV0Zi04JywgJ2NhY2hlLWNvbnRyb2wnOiAnbm8tc3RvcmUnLAogICAg
ICAgICd4LWZyYW1lLW9wdGlvbnMnOiAnREVOWScsICdyZWZlcnJlci1wb2xpY3knOiAnbm8tcmVm
ZXJyZXInIH0pOwogICAgICByZXMuZW5kKEFETUlOX1BBR0UpOwogICAgICByZXR1cm4gdHJ1ZTsK
ICAgIH0KICAgIGlmIChwYXRobmFtZSA9PT0gJy9hZG1pbi9hcGkvcGFja3MnICYmIHJlcS5tZXRo
b2QgPT09ICdHRVQnKSB7CiAgICAgIGlmIChhdXRob3JpemVkKHJlcSwgcmVzKSkgbGlzdCgpLnRo
ZW4oKHBhY2tzKSA9PiBqc29uKHJlcywgMjAwLCB7IHBhY2tzLCBtYXhCeXRlczogY29uZmlnLm1h
eFBhY2tCeXRlcyB9KSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYgKHBhdGhuYW1l
ID09PSAnL2FkbWluL2FwaS9oZi1qb3VybmFsJyAmJiByZXEubWV0aG9kID09PSAnR0VUJykgewog
ICAgICAvLyBUaGUgSGVybyBGaWdodGVyIHJvb21zJyBqb3VybmFsIChoZi1yb29tLmpzKTogd2hh
dCBoYXBwZW5lZCBpbiB0aGVtIGxhdGVseSwgd2l0aCB0aGUgZGV0YWlscyBvZiBldmVyeQogICAg
ICAvLyBmaWdodCB0aGF0IHdlbnQgb3V0IG9mIHN0ZXAsIGZvciBmaW5kaW5nIHRoZSBjYXVzZS4K
ICAgICAgaWYgKGF1dGhvcml6ZWQocmVxLCByZXMpKSB7CiAgICAgICAgcmVzLndyaXRlSGVhZCgy
MDAsIHsgJ2NvbnRlbnQtdHlwZSc6ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JywgJ2NhY2hl
LWNvbnRyb2wnOiAnbm8tc3RvcmUnIH0pOwogICAgICAgIHJlcy5lbmQoaGZKb3VybmFsID8gaGZK
b3VybmFsKCkgOiAnbm8gSGVybyBGaWdodGVyIHJvb21zXG4nKTsKICAgICAgfQogICAgICByZXR1
cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChwYXRobmFtZSA9PT0gJy9hZG1pbi9hcGkvaGYtYWNjb3Vu
dHMnICYmIHJlcS5tZXRob2QgPT09ICdHRVQnKSB7CiAgICAgIGlmIChhdXRob3JpemVkKHJlcSwg
cmVzKSkganNvbihyZXMsIDIwMCwgeyBhY2NvdW50czogaGZBY2NvdW50cyA/IGhmQWNjb3VudHMu
bGlzdCgpIDogW10gfSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgY29uc3QgaGZBY2Nv
dW50ID0gcGF0aG5hbWUubWF0Y2goL15cL2FkbWluXC9hcGlcL2hmLWFjY291bnRzXC8oWzAtOV17
MSwxMn0pJC8pOwogICAgaWYgKGhmQWNjb3VudCkgewogICAgICByZXEucmVzdW1lKCk7CiAgICAg
IGlmIChyZXEubWV0aG9kICE9PSAnUE9TVCcpIHsKICAgICAgICBqc29uKHJlcywgNDA1LCB7IGVy
cm9yOiAnbWV0aG9kIG5vdCBhbGxvd2VkJyB9LCB7IGFsbG93OiAnUE9TVCcgfSk7CiAgICAgICAg
cmV0dXJuIHRydWU7CiAgICAgIH0KICAgICAgaWYgKCFhdXRob3JpemVkKHJlcSwgcmVzKSkgcmV0
dXJuIHRydWU7CiAgICAgIGNvbnN0IG9uID0gbmV3IFVSTChyZXEudXJsLCAnaHR0cDovL3JlbGF5
LmludmFsaWQnKS5zZWFyY2hQYXJhbXMuZ2V0KCdwcmVtaXVtJykgPT09ICcxJzsKICAgICAgY29u
c3QgYWNjb3VudCA9IGhmQWNjb3VudHMgPyBoZkFjY291bnRzLnNldFByZW1pdW0oaGZBY2NvdW50
WzFdLCBvbikgOiBudWxsOwogICAgICBpZiAoIWFjY291bnQpIHsKICAgICAgICBqc29uKHJlcywg
NDA0LCB7IGVycm9yOiAnS2jDtG5nIGPDsyB0w6BpIGtob+G6o24gSGVybyBGaWdodGVyIG7DoHku
JyB9KTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgfQogICAgICBsb2coYGhmOiBhY2NvdW50
ICR7YWNjb3VudC5pZH0gIiR7YWNjb3VudC5uYW1lfSI6IHByZW1pdW0gY2hhcmFjdGVycyAke29u
ID8gJ29wZW4nIDogJ2xvY2tlZCd9YCk7CiAgICAgIGpzb24ocmVzLCAyMDAsIHsgb2s6IHRydWUs
IGFjY291bnQgfSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgY29uc3QgbWFuYWdlZCA9
IHBhdGhuYW1lLm1hdGNoKC9eXC9hZG1pblwvYXBpXC9wYWNrc1wvKFteL10qKSQvKTsKICAgIGlm
IChtYW5hZ2VkKSB7CiAgICAgIGNvbnN0IGlkID0gbWFuYWdlZFsxXTsKICAgICAgaWYgKCFQQUNL
X0lELnRlc3QoaWQpKSB7CiAgICAgICAganNvbihyZXMsIDQwMCwgeyBlcnJvcjogJ03DoyBuZ+G6
r24gY2jhu4kgZ+G7k20gY2jhu68gdGjGsOG7nW5nIGEteiwgc+G7kSB2w6AgZOG6pXUgZ+G6oWNo
IG5nYW5nICh04buRaSDEkWEgNDAga8O9IHThu7EpLicgfSk7CiAgICAgICAgcmV0dXJuIHRydWU7
CiAgICAgIH0KICAgICAgaWYgKHJlcS5tZXRob2QgPT09ICdQVVQnKSB7CiAgICAgICAgaWYgKCFh
dXRob3JpemVkKHJlcSwgcmVzKSkgeyByZXEucmVzdW1lKCk7IHJldHVybiB0cnVlOyB9CiAgICAg
ICAgY29uc3QgdGl0bGUgPSBTdHJpbmcobmV3IFVSTChyZXEudXJsLCAnaHR0cDovL3JlbGF5Lmlu
dmFsaWQnKS5zZWFyY2hQYXJhbXMuZ2V0KCd0aXRsZScpIHx8IGlkKS50cmltKCkuc2xpY2UoMCwg
NjApIHx8IGlkOwogICAgICAgIHVwbG9hZChyZXEsIHJlcywgaWQsIHRpdGxlKS5jYXRjaCgoKSA9
PiByZXMuZGVzdHJveSgpKTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgfQogICAgICBpZiAo
cmVxLm1ldGhvZCA9PT0gJ0RFTEVURScpIHsKICAgICAgICBpZiAoIWF1dGhvcml6ZWQocmVxLCBy
ZXMpKSByZXR1cm4gdHJ1ZTsKICAgICAgICBQcm9taXNlLmFsbChbYCR7aWR9LnppcGAsIGAke2lk
fS5zd2ZgLCBgJHtpZH0uanNvbmBdLm1hcCgobmFtZSkgPT4gZnNwLnJtKHBhdGguam9pbihkaXJl
Y3RvcnkgfHwgJy9ub25leGlzdGVudCcsIG5hbWUpLCB7IGZvcmNlOiB0cnVlIH0pKSkKICAgICAg
ICAgIC50aGVuKCgpID0+IHsgbG9nKGBwYWNrICR7aWR9OiByZW1vdmVkYCk7IGpzb24ocmVzLCAy
MDAsIHsgb2s6IHRydWUgfSk7IH0pCiAgICAgICAgICAuY2F0Y2goKGVycm9yKSA9PiBqc29uKHJl
cywgNTAwLCB7IGVycm9yOiBTdHJpbmcoZXJyb3IubWVzc2FnZSB8fCBlcnJvcikgfSkpOwogICAg
ICAgIHJldHVybiB0cnVlOwogICAgICB9CiAgICAgIGpzb24ocmVzLCA0MDUsIHsgZXJyb3I6ICdt
ZXRob2Qgbm90IGFsbG93ZWQnIH0sIHsgYWxsb3c6ICdQVVQsIERFTEVURScgfSk7CiAgICAgIHJl
dHVybiB0cnVlOwogICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KCiAgcmV0dXJuIHsgaGFuZGxl
LCBsaXN0LCBjbGVhbnVwOiAoKSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAg
Zm9yIChjb25zdCBtYXAgb2YgW2Rvd25sb2FkcywgZmFpbHVyZXNdKSBmb3IgKGNvbnN0IFtrZXks
IGVudHJ5XSBvZiBtYXApIGlmIChlbnRyeS51bnRpbCA8PSBub3cpIG1hcC5kZWxldGUoa2V5KTsK
ICB9IH07Cn0KCi8vIFRoZSBwYWdlIGF0IC9hZG1pbiAoVmlldG5hbWVzZTogdGhlIHJlbGF5J3Mg
b3duZXIgcmVhZHMgaXQpLgpjb25zdCBBRE1JTl9QQUdFID0gYDwhZG9jdHlwZSBodG1sPgo8aHRt
bCBsYW5nPSJ2aSI+PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPjxtZXRhIG5hbWU9InZpZXdw
b3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+Cjx0aXRs
ZT5PcGVuTEYyIHJlbGF5OiBi4bqjbiBtb2Q8L3RpdGxlPgo8c3R5bGU+CiAgYm9keSB7IG1hcmdp
bjogMDsgcGFkZGluZzogMS41cmVtOyBiYWNrZ3JvdW5kOiAjMTExODI3OyBjb2xvcjogI2YzZjRm
NjsgZm9udDogMTZweC8xLjUgc3lzdGVtLXVpLCBzYW5zLXNlcmlmOyB9CiAgbWFpbiB7IG1heC13
aWR0aDogNzYwcHg7IG1hcmdpbjogYXV0bzsgfQogIGgxIHsgZm9udC1zaXplOiAxLjVyZW07IG1h
cmdpbjogMCAwIC4yNXJlbTsgfQogIC5jYXJkIHsgYmFja2dyb3VuZDogIzFmMjkzNzsgYm9yZGVy
OiAxcHggc29saWQgIzM3NDE1MTsgYm9yZGVyLXJhZGl1czogMTJweDsgcGFkZGluZzogMXJlbSAx
LjJyZW07IG1hcmdpbjogMXJlbSAwOyB9CiAgbGFiZWwgeyBkaXNwbGF5OiBibG9jazsgbWFyZ2lu
OiAuNnJlbSAwIC4ycmVtOyBmb250LXdlaWdodDogNjAwOyB9CiAgaW5wdXRbdHlwZT10ZXh0XSwg
aW5wdXRbdHlwZT1wYXNzd29yZF0geyB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJv
eDsgcGFkZGluZzogLjVyZW0gLjZyZW07IGZvbnQ6IGluaGVyaXQ7CiAgICBib3JkZXItcmFkaXVz
OiA4cHg7IGJvcmRlcjogMXB4IHNvbGlkICM0YjU1NjM7IGJhY2tncm91bmQ6ICMwYjEyMjA7IGNv
bG9yOiBpbmhlcml0OyB9CiAgYnV0dG9uIHsgcGFkZGluZzogLjU1cmVtIDEuMXJlbTsgZm9udDog
aW5oZXJpdDsgYm9yZGVyLXJhZGl1czogOHB4OyBib3JkZXI6IDA7IGN1cnNvcjogcG9pbnRlcjsg
YmFja2dyb3VuZDogI2Y1OWUwYjsgY29sb3I6ICMxZjEzMDA7IGZvbnQtd2VpZ2h0OiA3MDA7IH0K
ICBidXR0b24uc2Vjb25kYXJ5IHsgYmFja2dyb3VuZDogIzM3NDE1MTsgY29sb3I6ICNmM2Y0ZjY7
IGZvbnQtd2VpZ2h0OiA1MDA7IH0KICBidXR0b246ZGlzYWJsZWQgeyBvcGFjaXR5OiAuNTsgY3Vy
c29yOiBkZWZhdWx0OyB9CiAgcHJvZ3Jlc3MgeyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAuOHJlbTsg
bWFyZ2luLXRvcDogLjhyZW07IH0KICAubm90ZSB7IGNvbG9yOiAjOWNhM2FmOyBmb250LXNpemU6
IC45cmVtOyB9CiAgLm9rIHsgY29sb3I6ICM2ZWU3Yjc7IH0gLmJhZCB7IGNvbG9yOiAjZmNhNWE1
OyB9CiAgdGFibGUgeyB3aWR0aDogMTAwJTsgYm9yZGVyLWNvbGxhcHNlOiBjb2xsYXBzZTsgfSB0
ZCwgdGggeyB0ZXh0LWFsaWduOiBsZWZ0OyBwYWRkaW5nOiAuNHJlbSAuM3JlbTsgYm9yZGVyLWJv
dHRvbTogMXB4IHNvbGlkICMzNzQxNTE7IHZlcnRpY2FsLWFsaWduOiB0b3A7IH0KICBjb2RlIHsg
YmFja2dyb3VuZDogIzBiMTIyMDsgcGFkZGluZzogLjA1cmVtIC4zcmVtOyBib3JkZXItcmFkaXVz
OiA0cHg7IH0KPC9zdHlsZT48L2hlYWQ+Cjxib2R5PjxtYWluPgogIDxoMT5C4bqjbiBtb2QgY2hv
IE9wZW5MRjI8L2gxPgogIDxwIGNsYXNzPSJub3RlIj5U4bqjaSBsw6puIG3hu5l0IGZpbGUgLnpp
cCBjaOG7qWEgY+G6oyB0aMawIG3hu6VjIGdhbWUgY+G7p2EgYuG6o24gbW9kIChjw7MgZmlsZSAu
ZXhlIHbDoCB0aMawIG3hu6VjIGRhdGEsIHNwcml0ZSwgYmdtLCBiZykuCiAgICBSZWxheSBjaOG7
iSBnaeG7ryBs4bqhaSBwaOG6p24gZ2FtZSBj4bqnbiwgcuG7k2kgcGjDoXQgY2hvIHRyw6xuaCBk
dXnhu4d0IGPhu6dhIG5nxrDhu51pIGNoxqFpLiBBaSBjxaluZyBjaOG7jW4gY8O5bmcgbeG7mXQg
YuG6o24gbW9kIG3hu5tpIHbDoG8gY2h1bmcgcGjDsm5nIMSRxrDhu6NjLjwvcD4KICA8cCBjbGFz
cz0ibm90ZSI+R2FtZSBIZXJvIEZpZ2h0ZXIgY8WpbmcgdOG6o2kgbMOqbiDhu58gxJHDonk6IGZp
bGUgPGNvZGU+SEZ2MC43LnppcDwvY29kZT4gKGhv4bq3YyA8Y29kZT5IRnYwLjcrLmV4ZTwvY29k
ZT4pLiBSZWxheSBnaeG7ryBwaOG6p24gZ2FtZSBGbGFzaCBiw6puIHRyb25nOwogICAgdHLDqm4g
dHJhbmcgZ2FtZSwgY2jhu41uIDxiPkhlcm8gRmlnaHRlcjwvYj4g4bufIG3hu6VjIEdhbWUuPC9w
PgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGxhYmVsIGZvcj0ia2V5Ij5Nw6MgcXXhuqNuIHRy
4buLIChBRE1JTl9LRVkpPC9sYWJlbD4KICAgIDxpbnB1dCBpZD0ia2V5IiB0eXBlPSJwYXNzd29y
ZCIgYXV0b2NvbXBsZXRlPSJjdXJyZW50LXBhc3N3b3JkIiBwbGFjZWhvbGRlcj0iaW4gcmEga2hp
IGNo4bqheSBpbnN0YWxsLXZwcy5zaCI+CiAgICA8bGFiZWwgZm9yPSJmaWxlIj5GaWxlIC56aXAg
Y+G7p2EgYuG6o24gbW9kPC9sYWJlbD4KICAgIDxpbnB1dCBpZD0iZmlsZSIgdHlwZT0iZmlsZSIg
YWNjZXB0PSIuemlwLC5leGUsLnN3ZixhcHBsaWNhdGlvbi96aXAiPgogICAgPGxhYmVsIGZvcj0i
dGl0bGUiPlTDqm4gaGnhu4NuIHRo4buLIHRyw6puIHRyYW5nIGdhbWU8L2xhYmVsPgogICAgPGlu
cHV0IGlkPSJ0aXRsZSIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI2MCIgcGxhY2Vob2xkZXI9InbD
rSBk4bulOiBPbmUgUGllY2UgR3JhbmRXb3JsZCI+CiAgICA8bGFiZWwgZm9yPSJpZCI+TcOjIG5n
4bqvbiAoZMO5bmcgdHJvbmcgbGluayBt4budaSk8L2xhYmVsPgogICAgPGlucHV0IGlkPSJpZCIg
dHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI0MCIgcGxhY2Vob2xkZXI9InbDrSBk4bulOiBvbmVwaWVj
ZSIgcGF0dGVybj0iW2EtejAtOV1bYS16MC05LV0qIj4KICAgIDxwPjxidXR0b24gaWQ9InVwbG9h
ZCI+VOG6o2kgbMOqbjwvYnV0dG9uPjwvcD4KICAgIDxwcm9ncmVzcyBpZD0icHJvZ3Jlc3MiIGhp
ZGRlbj48L3Byb2dyZXNzPgogICAgPHAgaWQ9InN0YXR1cyIgcm9sZT0ic3RhdHVzIiBjbGFzcz0i
bm90ZSI+PC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGgyIHN0eWxlPSJm
b250LXNpemU6MS4xNXJlbTttYXJnaW46MCAwIC41cmVtIj5Dw6FjIGLhuqNuIG1vZCB0csOqbiBy
ZWxheTwvaDI+CiAgICA8cD48YnV0dG9uIGlkPSJyZWZyZXNoIiBjbGFzcz0ic2Vjb25kYXJ5Ij5Y
ZW0gZGFuaCBzw6FjaDwvYnV0dG9uPjwvcD4KICAgIDx0YWJsZT48dGJvZHkgaWQ9Imxpc3QiPjwv
dGJvZHk+PC90YWJsZT4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgIDxoMiBzdHls
ZT0iZm9udC1zaXplOjEuMTVyZW07bWFyZ2luOjAgMCAuNXJlbSI+UXXDom4gbGltaXQgdHJvbmcg
SGVybyBGaWdodGVyPC9oMj4KICAgIDxwIGNsYXNzPSJub3RlIj5MZW8sIEVhc29uLCBJY3p6eSwg
SGVhdGVyLCBSYXllIHbDoCBMaXZlcm1vcmUgYuG7iyBraMOzYSB24bubaSBuZ8aw4budaSBjaMah
aSAobcOheSB24bqrbiBkw7luZyDEkcaw4bujYykuIE3hu58gY2hvIHTDoGkga2hv4bqjbiBuw6Bv
IHRow6wKICAgICAgdMOgaSBraG/huqNuIOG6pXkgY2jhu41uIMSRxrDhu6NjIGPDoWMgcXXDom4g
bsOgeSwg4bufIGxldmVsIDE2LCBr4buDIGPhuqMgdHJvbmcgcGjDsm5nIGNoxqFpIG3huqFuZyDi
gJQgdOG7qyBs4bqnbiDEkcSDbmcgbmjhuq1wIHNhdSAodOG6o2kgbOG6oWkgdHJhbmcgZ2FtZSBy
4buTaQogICAgICDEkcSDbmcgbmjhuq1wKS4gTeG6uW86IGzDoG0gbeG7mXQgdMOgaSBraG/huqNu
IHJpw6puZyDEkeG7gyBjaMahaSBxdcOibiBsaW1pdDsgdMOgaSBraG/huqNuIHRoxrDhu51uZyBj
4bunYSBi4bqhbiB24bqrbiBuaMawIG3hu41pIG5nxrDhu51pLjwvcD4KICAgIDxwPjxidXR0b24g
aWQ9ImhmYWNjb3VudHMiIGNsYXNzPSJzZWNvbmRhcnkiPlhlbSB0w6BpIGtob+G6o248L2J1dHRv
bj48L3A+CiAgICA8aW5wdXQgaWQ9ImhmZmlsdGVyIiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i
VMOsbSB0aGVvIHTDqm4gaG/hurdjIGUtbWFpbCIgaGlkZGVuPgogICAgPHAgaWQ9Imhmc3RhdHVz
IiByb2xlPSJzdGF0dXMiIGNsYXNzPSJub3RlIj48L3A+CiAgICA8dGFibGU+PHRib2R5IGlkPSJo
Zmxpc3QiPjwvdGJvZHk+PC90YWJsZT4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAg
IDxoMiBzdHlsZT0iZm9udC1zaXplOjEuMTVyZW07bWFyZ2luOjAgMCAuNXJlbSI+Tmjhuq10IGvD
vSBwaMOybmcgSGVybyBGaWdodGVyPC9oMj4KICAgIDxwIGNsYXNzPSJub3RlIj5BaSB2w6BvL3Jh
IHBow7JuZywgdHLhuq1uIG7DoG8gYuG6r3QgxJHhuqd1IHbDoCBr4bq/dCB0aMO6YywgYWkgdOG6
oW0gZOG7q25nLCB2w6Aga2hpIGhhaSBtw6F5IGzhu4djaCBuaGF1IChkZXN5bmMpIHRow6wgbeG7
jWkgdGjhu6kgaGFpIGdhbWUKICAgICAgxJHDoyBiw6FvIHF1YW5oIGtodW5nIGjDrG5oIMSRw7Mu
IEtoaSBn4bq3cCBs4buXaSBkZXN5bmMsIGLhuqVtIHhlbSBy4buTaSBjaMOpcCB0b8OgbiBi4buZ
IG7hu5lpIGR1bmcgZ+G7rWkgY2hvIG5nxrDhu51pIGzDoG0gd2ViLjwvcD4KICAgIDxwPjxidXR0
b24gaWQ9ImpvdXJuYWwiIGNsYXNzPSJzZWNvbmRhcnkiPlhlbSBuaOG6rXQga8O9PC9idXR0b24+
IDxidXR0b24gaWQ9ImNvcHlqb3VybmFsIiBjbGFzcz0ic2Vjb25kYXJ5IiBoaWRkZW4+Q2jDqXAg
buG7mWkgZHVuZzwvYnV0dG9uPjwvcD4KICAgIDxwcmUgaWQ9ImpvdXJuYWx0ZXh0IiBzdHlsZT0i
d2hpdGUtc3BhY2U6cHJlLXdyYXA7Zm9udC1zaXplOi44cmVtO21heC1oZWlnaHQ6NjB2aDtvdmVy
ZmxvdzphdXRvO2JhY2tncm91bmQ6IzBiMTIyMDtwYWRkaW5nOi42cmVtO2JvcmRlci1yYWRpdXM6
OHB4IiBoaWRkZW4+PC9wcmU+CiAgPC9kaXY+CjwvbWFpbj4KPHNjcmlwdD4KICBjb25zdCAkID0g
KGlkKSA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgY29uc3QgYXBpID0gbG9jYXRp
b24ucGF0aG5hbWUucmVwbGFjZSgvXFwvPyQvLCAnLycpICsgJ2FwaS9wYWNrcyc7CiAgdHJ5IHsg
JCgna2V5JykudmFsdWUgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnbGYyLWFkbWluLWtleScpIHx8
ICcnOyB9IGNhdGNoIChlcnJvcikge30KICBjb25zdCByZW1lbWJlciA9ICgpID0+IHsgdHJ5IHsg
bG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2xmMi1hZG1pbi1rZXknLCAkKCdrZXknKS52YWx1ZSk7IH0g
Y2F0Y2ggKGVycm9yKSB7fSB9OwogIGNvbnN0IHNsdWcgPSAodGV4dCkgPT4gdGV4dC50b0xvd2Vy
Q2FzZSgpLm5vcm1hbGl6ZSgnTkZEJykucmVwbGFjZSgvW1xcdTAzMDAtXFx1MDM2Zl0vZywgJycp
LnJlcGxhY2UoL8SRL2csICdkJykKICAgIC5yZXBsYWNlKC9bXmEtejAtOV0rL2csICctJykucmVw
bGFjZSgvXi0rfC0rJC9nLCAnJykuc2xpY2UoMCwgNDApIHx8ICdtb2QnOwogICQoJ2ZpbGUnKS5h
ZGRFdmVudExpc3RlbmVyKCdjaGFuZ2UnLCAoKSA9PiB7CiAgICBjb25zdCBmaWxlID0gJCgnZmls
ZScpLmZpbGVzWzBdOwogICAgaWYgKCFmaWxlKSByZXR1cm47CiAgICBsZXQgbmFtZSA9IGZpbGUu
bmFtZS5yZXBsYWNlKC9cXC4oemlwfGV4ZXxzd2YpJC9pLCAnJykucmVwbGFjZSgvW19dKy9nLCAn
ICcpLnRyaW0oKTsKICAgIGlmICgvXmhmID92PzBcXC43L2kudGVzdChuYW1lKSkgbmFtZSA9ICdI
ZXJvIEZpZ2h0ZXIgdjAuNysnOwogICAgaWYgKCEkKCd0aXRsZScpLnZhbHVlKSAkKCd0aXRsZScp
LnZhbHVlID0gbmFtZTsKICAgIGlmICghJCgnaWQnKS52YWx1ZSkgJCgnaWQnKS52YWx1ZSA9IHNs
dWcobmFtZSk7CiAgfSk7CiAgJCgndGl0bGUnKS5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgp
ID0+IHsgaWYgKCEkKCdpZCcpLmRhdGFzZXQudG91Y2hlZCkgJCgnaWQnKS52YWx1ZSA9IHNsdWco
JCgndGl0bGUnKS52YWx1ZSk7IH0pOwogICQoJ2lkJykuYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQn
LCAoKSA9PiB7ICQoJ2lkJykuZGF0YXNldC50b3VjaGVkID0gJzEnOyB9KTsKICBjb25zdCBtYiA9
IChieXRlcykgPT4gKGJ5dGVzIC8gMWU2KS50b0ZpeGVkKDEpICsgJyBNQic7CiAgZnVuY3Rpb24g
c3RhdHVzKHRleHQsIGtpbmQpIHsgJCgnc3RhdHVzJykudGV4dENvbnRlbnQgPSB0ZXh0OyAkKCdz
dGF0dXMnKS5jbGFzc05hbWUgPSBraW5kIHx8ICdub3RlJzsgfQogICQoJ3VwbG9hZCcpLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gewogICAgY29uc3QgZmlsZSA9ICQoJ2ZpbGUnKS5m
aWxlc1swXTsKICAgIGNvbnN0IGlkID0gJCgnaWQnKS52YWx1ZS50cmltKCk7CiAgICBpZiAoISQo
J2tleScpLnZhbHVlKSByZXR1cm4gc3RhdHVzKCdOaOG6rXAgbcOjIHF14bqjbiB0cuG7iyB0csaw
4bubYy4nLCAnYmFkJyk7CiAgICBpZiAoIWZpbGUpIHJldHVybiBzdGF0dXMoJ0No4buNbiBmaWxl
IC56aXAgdHLGsOG7m2MuJywgJ2JhZCcpOwogICAgaWYgKCEvXlthLXowLTldW2EtejAtOS1dezAs
Mzl9JC8udGVzdChpZCkpIHJldHVybiBzdGF0dXMoJ03DoyBuZ+G6r24gY2jhu4kgZ+G7k20gY2jh
u68gdGjGsOG7nW5nIGEteiwgc+G7kSB2w6AgZOG6pXUgZ+G6oWNoIG5nYW5nLicsICdiYWQnKTsK
ICAgIHJlbWVtYmVyKCk7CiAgICBjb25zdCByZXF1ZXN0ID0gbmV3IFhNTEh0dHBSZXF1ZXN0KCk7
CiAgICByZXF1ZXN0Lm9wZW4oJ1BVVCcsIGFwaSArICcvJyArIGlkICsgJz90aXRsZT0nICsgZW5j
b2RlVVJJQ29tcG9uZW50KCQoJ3RpdGxlJykudmFsdWUudHJpbSgpIHx8IGlkKSk7CiAgICByZXF1
ZXN0LnNldFJlcXVlc3RIZWFkZXIoJ3gtYWRtaW4ta2V5JywgJCgna2V5JykudmFsdWUpOwogICAg
cmVxdWVzdC5zZXRSZXF1ZXN0SGVhZGVyKCdjb250ZW50LXR5cGUnLCAnYXBwbGljYXRpb24vemlw
Jyk7CiAgICAkKCdwcm9ncmVzcycpLmhpZGRlbiA9IGZhbHNlOwogICAgJCgndXBsb2FkJykuZGlz
YWJsZWQgPSB0cnVlOwogICAgcmVxdWVzdC51cGxvYWQub25wcm9ncmVzcyA9IChldmVudCkgPT4g
ewogICAgICBpZiAoIWV2ZW50Lmxlbmd0aENvbXB1dGFibGUpIHJldHVybjsKICAgICAgJCgncHJv
Z3Jlc3MnKS5tYXggPSBldmVudC50b3RhbDsKICAgICAgJCgncHJvZ3Jlc3MnKS52YWx1ZSA9IGV2
ZW50LmxvYWRlZDsKICAgICAgc3RhdHVzKCfEkGFuZyB04bqjaSBsw6puOiAnICsgbWIoZXZlbnQu
bG9hZGVkKSArICcgLyAnICsgbWIoZXZlbnQudG90YWwpICsgKGV2ZW50LmxvYWRlZCA9PT0gZXZl
bnQudG90YWwgPyAnIChyZWxheSDEkWFuZyB44butIGzDvS4uLiknIDogJycpKTsKICAgIH07CiAg
ICByZXF1ZXN0Lm9ubG9hZCA9ICgpID0+IHsKICAgICAgJCgndXBsb2FkJykuZGlzYWJsZWQgPSBm
YWxzZTsKICAgICAgJCgncHJvZ3Jlc3MnKS5oaWRkZW4gPSB0cnVlOwogICAgICBsZXQgYm9keSA9
IHt9OwogICAgICB0cnkgeyBib2R5ID0gSlNPTi5wYXJzZShyZXF1ZXN0LnJlc3BvbnNlVGV4dCk7
IH0gY2F0Y2ggKGVycm9yKSB7fQogICAgICBpZiAocmVxdWVzdC5zdGF0dXMgPT09IDIwMCkgewog
ICAgICAgIGlmIChib2R5LmtpbmQgPT09ICdmbGFzaCcpIHsKICAgICAgICAgIHN0YXR1cygnWG9u
ZzogIicgKyBib2R5LnRpdGxlICsgJyIgKGdhbWUgRmxhc2gsICcgKyBtYihib2R5LnNpemUpICsg
JykuICcKICAgICAgICAgICAgKyAoYm9keS5nYW1lID09PSAnaGVyb2ZpZ2h0ZXInID8gJ1Ryw6pu
IHRyYW5nIGdhbWUsIGNo4buNbiBIZXJvIEZpZ2h0ZXIg4bufIG3hu6VjIEdhbWUuJyA6ICfEkMOi
eSBraMO0bmcgcGjhuqNpIEhlcm8gRmlnaHRlcjogdHJhbmcgZ2FtZSBjaMawYSBjaMahaSDEkcaw
4bujYyBnYW1lIG7DoHkuJyksIGJvZHkuZ2FtZSA/ICdvaycgOiAnYmFkJyk7CiAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgIHN0YXR1cygnWG9uZzogIicgKyBib2R5LnRpdGxlICsgJyIgKCcgKyBt
Yihib2R5LnNpemUpICsgJywgJyArIGJvZHkuZmlsZXMgKyAnIGZpbGUsIGLhu48gYuG7m3QgJyAr
IGJvZHkuZHJvcHBlZCArICcgZmlsZSBraMO0bmcgY+G6p24pLiAnCiAgICAgICAgICAgICsgJ1Ry
w6puIHRyYW5nIGdhbWUsIGNo4buNbiBuw7Mg4bufIG3hu6VjIEdhbWUsIGhv4bq3YyBn4butaSBs
aW5rIG3hu51pIGPDsyB0aMOqbSAmcGFjaz0nICsgYm9keS5pZCArICcuJywgJ29rJyk7CiAgICAg
ICAgfQogICAgICAgIHJlZnJlc2goKTsKICAgICAgfSBlbHNlIHN0YXR1cygnS2jDtG5nIMSRxrDh
u6NjOiAnICsgKGJvZHkuZXJyb3IgfHwgKCds4buXaSAnICsgcmVxdWVzdC5zdGF0dXMpKSwgJ2Jh
ZCcpOwogICAgfTsKICAgIHJlcXVlc3Qub25lcnJvciA9ICgpID0+IHsgJCgndXBsb2FkJykuZGlz
YWJsZWQgPSBmYWxzZTsgJCgncHJvZ3Jlc3MnKS5oaWRkZW4gPSB0cnVlOyBzdGF0dXMoJ03huqV0
IGvhur90IG7hu5FpIGtoaSB04bqjaSBsw6puLicsICdiYWQnKTsgfTsKICAgIHJlcXVlc3Quc2Vu
ZChmaWxlKTsKICB9KTsKICBhc3luYyBmdW5jdGlvbiByZWZyZXNoKCkgewogICAgaWYgKCEkKCdr
ZXknKS52YWx1ZSkgcmV0dXJuIHN0YXR1cygnTmjhuq1wIG3DoyBxdeG6o24gdHLhu4sgxJHhu4Mg
eGVtIGRhbmggc8OhY2guJywgJ2JhZCcpOwogICAgcmVtZW1iZXIoKTsKICAgIGNvbnN0IHJlc3Bv
bnNlID0gYXdhaXQgZmV0Y2goYXBpLCB7IGhlYWRlcnM6IHsgJ3gtYWRtaW4ta2V5JzogJCgna2V5
JykudmFsdWUgfSB9KTsKICAgIGNvbnN0IGJvZHkgPSBhd2FpdCByZXNwb25zZS5qc29uKCkuY2F0
Y2goKCkgPT4gKHt9KSk7CiAgICBpZiAoIXJlc3BvbnNlLm9rKSByZXR1cm4gc3RhdHVzKGJvZHku
ZXJyb3IgfHwgKCds4buXaSAnICsgcmVzcG9uc2Uuc3RhdHVzKSwgJ2JhZCcpOwogICAgY29uc3Qg
bGlzdCA9ICQoJ2xpc3QnKTsKICAgIGxpc3QudGV4dENvbnRlbnQgPSAnJzsKICAgIGlmICghYm9k
eS5wYWNrcy5sZW5ndGgpIGxpc3QuaW5uZXJIVE1MID0gJzx0cj48dGQgY2xhc3M9Im5vdGUiPkNo
xrBhIGPDsyBi4bqjbiBtb2QgbsOgby48L3RkPjwvdHI+JzsKICAgIGZvciAoY29uc3QgcGFjayBv
ZiBib2R5LnBhY2tzKSB7CiAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J3RyJyk7CiAgICAgIGNvbnN0IGluZm8gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd0ZCcpOwog
ICAgICBpbmZvLmlubmVySFRNTCA9ICc8Yj48L2I+PGJyPjxzcGFuIGNsYXNzPSJub3RlIj48L3Nw
YW4+JzsKICAgICAgaW5mby5xdWVyeVNlbGVjdG9yKCdiJykudGV4dENvbnRlbnQgPSBwYWNrLnRp
dGxlOwogICAgICBpbmZvLnF1ZXJ5U2VsZWN0b3IoJ3NwYW4nKS50ZXh0Q29udGVudCA9ICdtw6M6
ICcgKyBwYWNrLmlkICsgJyDCtyAnICsgbWIocGFjay5zaXplKSArICcgwrcgdOG6o2kgbMOqbiAn
ICsgbmV3IERhdGUocGFjay51cGxvYWRlZCkudG9Mb2NhbGVTdHJpbmcoKTsKICAgICAgY29uc3Qg
YWN0aW9ucyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3RkJyk7CiAgICAgIGNvbnN0IHJlbW92
ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICByZW1vdmUuY2xhc3NO
YW1lID0gJ3NlY29uZGFyeSc7CiAgICAgIHJlbW92ZS50ZXh0Q29udGVudCA9ICdYw7NhJzsKICAg
ICAgcmVtb3ZlLm9uY2xpY2sgPSBhc3luYyAoKSA9PiB7CiAgICAgICAgaWYgKCFjb25maXJtKCdY
w7NhICInICsgcGFjay50aXRsZSArICciIGto4buPaSByZWxheT8nKSkgcmV0dXJuOwogICAgICAg
IGNvbnN0IHJlc3VsdCA9IGF3YWl0IGZldGNoKGFwaSArICcvJyArIHBhY2suaWQsIHsgbWV0aG9k
OiAnREVMRVRFJywgaGVhZGVyczogeyAneC1hZG1pbi1rZXknOiAkKCdrZXknKS52YWx1ZSB9IH0p
OwogICAgICAgIGlmIChyZXN1bHQub2spIHJlZnJlc2goKTsgZWxzZSBzdGF0dXMoJ0tow7RuZyB4
w7NhIMSRxrDhu6NjIChs4buXaSAnICsgcmVzdWx0LnN0YXR1cyArICcpLicsICdiYWQnKTsKICAg
ICAgfTsKICAgICAgYWN0aW9ucy5hcHBlbmRDaGlsZChyZW1vdmUpOwogICAgICByb3cuYXBwZW5k
KGluZm8sIGFjdGlvbnMpOwogICAgICBsaXN0LmFwcGVuZENoaWxkKHJvdyk7CiAgICB9CiAgfQog
ICQoJ3JlZnJlc2gnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIHJlZnJlc2gpOwogICQoJ2pv
dXJuYWwnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGFzeW5jICgpID0+IHsKICAgIGlmICgh
JCgna2V5JykudmFsdWUpIHJldHVybiBzdGF0dXMoJ05o4bqtcCBtw6MgcXXhuqNuIHRy4buLIMSR
4buDIHhlbSBuaOG6rXQga8O9LicsICdiYWQnKTsKICAgIHJlbWVtYmVyKCk7CiAgICBjb25zdCBy
ZXNwb25zZSA9IGF3YWl0IGZldGNoKGxvY2F0aW9uLnBhdGhuYW1lLnJlcGxhY2UoL1xcLz8kLywg
Jy8nKSArICdhcGkvaGYtam91cm5hbCcsIHsgaGVhZGVyczogeyAneC1hZG1pbi1rZXknOiAkKCdr
ZXknKS52YWx1ZSB9IH0pOwogICAgY29uc3QgdGV4dCA9IGF3YWl0IHJlc3BvbnNlLnRleHQoKTsK
ICAgIGlmICghcmVzcG9uc2Uub2spIHJldHVybiBzdGF0dXMoJ0tow7RuZyB4ZW0gxJHGsOG7o2Mg
bmjhuq10IGvDvSAobOG7l2kgJyArIHJlc3BvbnNlLnN0YXR1cyArICcpLicsICdiYWQnKTsKICAg
ICQoJ2pvdXJuYWx0ZXh0JykudGV4dENvbnRlbnQgPSB0ZXh0OwogICAgJCgnam91cm5hbHRleHQn
KS5oaWRkZW4gPSBmYWxzZTsKICAgICQoJ2NvcHlqb3VybmFsJykuaGlkZGVuID0gZmFsc2U7CiAg
fSk7CiAgY29uc3QgaGZBcGkgPSBsb2NhdGlvbi5wYXRobmFtZS5yZXBsYWNlKC9cXC8/JC8sICcv
JykgKyAnYXBpL2hmLWFjY291bnRzJzsKICBsZXQgaGZBY2NvdW50cyA9IFtdOwogIGZ1bmN0aW9u
IGhmU3RhdHVzKHRleHQsIGtpbmQpIHsgJCgnaGZzdGF0dXMnKS50ZXh0Q29udGVudCA9IHRleHQ7
ICQoJ2hmc3RhdHVzJykuY2xhc3NOYW1lID0ga2luZCB8fCAnbm90ZSc7IH0KICBmdW5jdGlvbiBk
cmF3QWNjb3VudHMoKSB7CiAgICBjb25zdCBmaWx0ZXIgPSAkKCdoZmZpbHRlcicpLnZhbHVlLnRy
aW0oKS50b0xvd2VyQ2FzZSgpOwogICAgY29uc3Qgc2hvd24gPSBoZkFjY291bnRzLmZpbHRlcigo
YWNjb3VudCkgPT4gIWZpbHRlciB8fCBhY2NvdW50Lm5hbWUudG9Mb3dlckNhc2UoKS5pbmNsdWRl
cyhmaWx0ZXIpIHx8IGFjY291bnQuZW1haWwuaW5jbHVkZXMoZmlsdGVyKSk7CiAgICBjb25zdCBs
aXN0ID0gJCgnaGZsaXN0Jyk7CiAgICBsaXN0LnRleHRDb250ZW50ID0gJyc7CiAgICBpZiAoIXNo
b3duLmxlbmd0aCkgewogICAgICBsaXN0LmlubmVySFRNTCA9ICc8dHI+PHRkIGNsYXNzPSJub3Rl
Ij48L3RkPjwvdHI+JzsKICAgICAgbGlzdC5xdWVyeVNlbGVjdG9yKCd0ZCcpLnRleHRDb250ZW50
ID0gaGZBY2NvdW50cy5sZW5ndGggPyAnS2jDtG5nIGPDsyB0w6BpIGtob+G6o24gbsOgbyBraOG7
m3AuJyA6ICdDaMawYSBjw7MgdMOgaSBraG/huqNuIEhlcm8gRmlnaHRlciBuw6BvLic7CiAgICB9
CiAgICBmb3IgKGNvbnN0IGFjY291bnQgb2Ygc2hvd24uc2xpY2UoMCwgMTAwKSkgewogICAgICBj
b25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd0cicpOwogICAgICBjb25zdCBpbmZv
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgndGQnKTsKICAgICAgaW5mby5pbm5lckhUTUwgPSAn
PGI+PC9iPjxicj48c3BhbiBjbGFzcz0ibm90ZSI+PC9zcGFuPic7CiAgICAgIGluZm8ucXVlcnlT
ZWxlY3RvcignYicpLnRleHRDb250ZW50ID0gYWNjb3VudC5uYW1lOwogICAgICBpbmZvLnF1ZXJ5
U2VsZWN0b3IoJ3NwYW4nKS50ZXh0Q29udGVudCA9IGFjY291bnQuZW1haWwgKyAnIMK3IG3DoyAn
ICsgYWNjb3VudC5pZAogICAgICAgICsgKGFjY291bnQuc2VlbiA/ICcgwrcgxJHEg25nIG5o4bqt
cCAnICsgbmV3IERhdGUoYWNjb3VudC5zZWVuKS50b0xvY2FsZVN0cmluZygpIDogJycpOwogICAg
ICBjb25zdCBzdGF0ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3RkJyk7CiAgICAgIHN0YXRl
LnRleHRDb250ZW50ID0gYWNjb3VudC5wcmVtaXVtID8gJ1F1w6JuIGxpbWl0OiBt4bufJyA6ICdR
dcOibiBsaW1pdDoga2jDs2EnOwogICAgICBzdGF0ZS5jbGFzc05hbWUgPSBhY2NvdW50LnByZW1p
dW0gPyAnb2snIDogJ25vdGUnOwogICAgICBjb25zdCBhY3Rpb25zID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgndGQnKTsKICAgICAgY29uc3QgdG9nZ2xlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnYnV0dG9uJyk7CiAgICAgIHRvZ2dsZS5jbGFzc05hbWUgPSBhY2NvdW50LnByZW1pdW0gPyAn
c2Vjb25kYXJ5JyA6ICcnOwogICAgICB0b2dnbGUudGV4dENvbnRlbnQgPSBhY2NvdW50LnByZW1p
dW0gPyAnS2jDs2EgbOG6oWknIDogJ03hu58gcXXDom4gbGltaXQnOwogICAgICB0b2dnbGUub25j
bGljayA9IGFzeW5jICgpID0+IHsKICAgICAgICB0b2dnbGUuZGlzYWJsZWQgPSB0cnVlOwogICAg
ICAgIGNvbnN0IHJlc3VsdCA9IGF3YWl0IGZldGNoKGhmQXBpICsgJy8nICsgYWNjb3VudC5pZCAr
ICc/cHJlbWl1bT0nICsgKGFjY291bnQucHJlbWl1bSA/ICcwJyA6ICcxJyksCiAgICAgICAgICB7
IG1ldGhvZDogJ1BPU1QnLCBoZWFkZXJzOiB7ICd4LWFkbWluLWtleSc6ICQoJ2tleScpLnZhbHVl
IH0gfSk7CiAgICAgICAgY29uc3QgYm9keSA9IGF3YWl0IHJlc3VsdC5qc29uKCkuY2F0Y2goKCkg
PT4gKHt9KSk7CiAgICAgICAgdG9nZ2xlLmRpc2FibGVkID0gZmFsc2U7CiAgICAgICAgaWYgKCFy
ZXN1bHQub2spIHJldHVybiBoZlN0YXR1cyhib2R5LmVycm9yIHx8ICgnbOG7l2kgJyArIHJlc3Vs
dC5zdGF0dXMpLCAnYmFkJyk7CiAgICAgICAgYWNjb3VudC5wcmVtaXVtID0gYm9keS5hY2NvdW50
LnByZW1pdW07CiAgICAgICAgaGZTdGF0dXMoKGFjY291bnQucHJlbWl1bSA/ICfEkMOjIG3hu58g
cXXDom4gbGltaXQgY2hvICInIDogJ8SQw6Mga2jDs2EgcXXDom4gbGltaXQgY+G7p2EgIicpICsg
YWNjb3VudC5uYW1lCiAgICAgICAgICArICciOiBjw7MgdMOhYyBk4bulbmcgdOG7qyBs4bqnbiDE
kcSDbmcgbmjhuq1wIHNhdSAodOG6o2kgbOG6oWkgdHJhbmcgZ2FtZSBy4buTaSDEkcSDbmcgbmjh
uq1wKS4nLCAnb2snKTsKICAgICAgICBkcmF3QWNjb3VudHMoKTsKICAgICAgfTsKICAgICAgYWN0
aW9ucy5hcHBlbmRDaGlsZCh0b2dnbGUpOwogICAgICByb3cuYXBwZW5kKGluZm8sIHN0YXRlLCBh
Y3Rpb25zKTsKICAgICAgbGlzdC5hcHBlbmRDaGlsZChyb3cpOwogICAgfQogICAgaWYgKHNob3du
Lmxlbmd0aCA+IDEwMCkgewogICAgICBjb25zdCBtb3JlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgndHInKTsKICAgICAgbW9yZS5pbm5lckhUTUwgPSAnPHRkIGNsYXNzPSJub3RlIiBjb2xzcGFu
PSIzIj48L3RkPic7CiAgICAgIG1vcmUucXVlcnlTZWxlY3RvcigndGQnKS50ZXh0Q29udGVudCA9
ICdWw6AgJyArIChzaG93bi5sZW5ndGggLSAxMDApICsgJyB0w6BpIGtob+G6o24gbuG7r2E6IGfD
tSB0w6puIGhheSBlLW1haWwgdsOgbyDDtCB0w6xtLic7CiAgICAgIGxpc3QuYXBwZW5kQ2hpbGQo
bW9yZSk7CiAgICB9CiAgfQogICQoJ2hmYWNjb3VudHMnKS5hZGRFdmVudExpc3RlbmVyKCdjbGlj
aycsIGFzeW5jICgpID0+IHsKICAgIGlmICghJCgna2V5JykudmFsdWUpIHJldHVybiBoZlN0YXR1
cygnTmjhuq1wIG3DoyBxdeG6o24gdHLhu4sgKMO0IHRyw6puIGPDuW5nKSDEkeG7gyB4ZW0gdMOg
aSBraG/huqNuLicsICdiYWQnKTsKICAgIHJlbWVtYmVyKCk7CiAgICBjb25zdCByZXNwb25zZSA9
IGF3YWl0IGZldGNoKGhmQXBpLCB7IGhlYWRlcnM6IHsgJ3gtYWRtaW4ta2V5JzogJCgna2V5Jyku
dmFsdWUgfSB9KTsKICAgIGNvbnN0IGJvZHkgPSBhd2FpdCByZXNwb25zZS5qc29uKCkuY2F0Y2go
KCkgPT4gKHt9KSk7CiAgICBpZiAoIXJlc3BvbnNlLm9rKSByZXR1cm4gaGZTdGF0dXMoYm9keS5l
cnJvciB8fCAoJ2zhu5dpICcgKyByZXNwb25zZS5zdGF0dXMpLCAnYmFkJyk7CiAgICBoZlN0YXR1
cygnJyk7CiAgICBoZkFjY291bnRzID0gYm9keS5hY2NvdW50cyB8fCBbXTsKICAgICQoJ2hmZmls
dGVyJykuaGlkZGVuID0gZmFsc2U7CiAgICBkcmF3QWNjb3VudHMoKTsKICB9KTsKICAkKCdoZmZp
bHRlcicpLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgZHJhd0FjY291bnRzKTsKICAkKCdjb3B5
am91cm5hbCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5bmMgKCkgPT4gewogICAgdHJ5
IHsgYXdhaXQgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQoJCgnam91cm5hbHRleHQnKS50
ZXh0Q29udGVudCk7IHN0YXR1cygnxJDDoyBjaMOpcCBuaOG6rXQga8O9IHbDoG8gYuG7mSBuaOG7
myB04bqhbS4nLCAnb2snKTsgfQogICAgY2F0Y2ggKGVycm9yKSB7IHN0YXR1cygnS2jDtG5nIGNo
w6lwIMSRxrDhu6NjOiBjaOG7jW4gbuG7mWkgZHVuZyBi4bqxbmcgY2h14buZdCBy4buTaSBDdHJs
K0MuJywgJ2JhZCcpOyB9CiAgfSk7Cjwvc2NyaXB0Pgo8L2JvZHk+PC9odG1sPgpgOwoKbW9kdWxl
LmV4cG9ydHMgPSB7IGNyZWF0ZVBhY2tzLCByZWFkWmlwLCBhbmFseXplWmlwLCB3cml0ZVppcCwg
bW92aWVPZiwgZmxhc2hHYW1lLCBQYWNrRXJyb3IsIFBBQ0tfSUQgfTsK
LF2_PAYLOAD
}
write_hf_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IE1JVAovLwovLyBIZXJvIEZpZ2h0ZXIgdjAuNysg
b25saW5lLCBmb3IgdGhlIGdhbWUgcGFnZSB0aGF0IHJ1bnMgaXQgaW4gUnVmZmxlIChhIEZsYXNo
IHBsYXllcikuIFRoZSBnYW1lIHdhcwovLyBtYWRlIGZvciBoZXJvZmlnaHRlci5jb20ncyBzbWFs
bCB3ZWIgc2VydmljZXMgKGFjY291bnRzOyBjbG9zZWQgdG8gbmV3IHBsYXllcnMgc2luY2UgMjAx
NikgYW5kIGZvcgovLyByb29tIHNlcnZlcnMgaXQgcmVhY2hlcyBvdmVyIFRDUC4gVGhlIHBhZ2Ug
cG9pbnRzIHRoZSBnYW1lJ3MgYWRkcmVzc2VzIGhlcmUgaW5zdGVhZCAoUnVmZmxlJ3MgVVJMCi8v
IHJld3JpdGVzIGFuZCBzb2NrZXQgcHJveHkpLCBzbyB0aGF0IGl0IHBsYXlzIHdpdGggdGhpcyBy
ZWxheSBhcyBpdCBkaWQgd2l0aCB0aG9zZToKLy8gICBHRVQgIDxyZWxheSBmb2xkZXI+L2hmL3Zl
ci50eHQgICAgICAgICAgICAgICAgICAgIHRoZSB2ZXJzaW9uIGNoZWNrICh0aGlzIHZlcnNpb24g
aXMgdGhlIG5ld2VzdCkKLy8gICBHRVQgIDxyZWxheSBmb2xkZXI+L2hmL3MvdjAuNy9sb2dpbi5w
aHA/ZW09JnB3PSAgIGxvZyBpbjsgYW4gZS1tYWlsIGFkZHJlc3Mgbm90IHNlZW4gYmVmb3JlIGlz
IGEgbmV3IGFjY291bnQKLy8gICBHRVQgIDxyZWxheSBmb2xkZXI+L2hmL3MvdjAuNy9sdS5waHA/
Li4uICAgICAgICAgIHRoZSBleHBlcmllbmNlIHRoZSBhY2NvdW50J3MgY2hhcmFjdGVycyBnYWlu
ZWQKLy8gICBHRVQgIDxyZWxheSBmb2xkZXI+L2hmL3MvY2FwLnBocCwgcmVnLnBocCwgbmFtZWNo
Z19sZWZ0LnBocCwgbmFtZWNoZy5waHAsIHB3ZGNoZy5waHAsIHB3ZHJldC5waHAKLy8gICBHRVQg
IDxyZWxheSBmb2xkZXI+L2hmL3MvcHJlbWl1bT8uLi4gICAgICAgICAgICAgIHRoZSBnYW1lJ3Mg
InVubG9jayB0aGUgcHJlbWl1bSBjaGFyYWN0ZXJzIiBsaW5rOiBhIHBhZ2UKLy8gICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc2F5aW5nIHRoZXJlIGlz
IG5vdGhpbmcgdG8gYnV5IGhlcmUKLy8gICBHRVQgIDxyZWxheSBmb2xkZXI+L2hmL2hmL3JsZy5w
aHAgICAgICAgICAgICAgICAgIHRoZSByb29tIGxpc3Q6IHRoaXMgcmVsYXkncyByb29tcwovLyAg
IEdFVCAgPHJlbGF5IGZvbGRlcj4vaGYvcm9vbXMuanNvbiAgICAgICAgICAgICAgICAgdGhlIHJv
b21zIGZvciB0aGUgcGFnZSAoaXRzIHNvY2tldCBwcm94eSBzZXR0aW5ncykKLy8gICBXZWJTb2Nr
ZXQgPHJlbGF5IHBhdGg+P2dhbWU9aGYmcm9vbT08bj4mYnVpbGQ9PGI+IHJvb20gbiAoaGYtcm9v
bS5qcyk7IGI6IHRoZSBwYWdlJ3MgbW92aWUgYW5kIFJ1ZmZsZSwgd2hpY2gKLy8gICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgbXVzdCBiZSB0aGUgc2Ft
ZSBmb3IgZXZlcnkgZ2FtZSBpbiBhIHJvb207ICZkaXJlY3Q9MTogdGhlCi8vICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBhZ2UgYWxzbyBwYXNzZXMg
ZnJhbWVzIHRvIHRoZSBvdGhlcnMgZGlyZWN0bHkgKFdlYlJUQywKLy8gICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZGlzdC9wYWdlcy9oZi1kaXJlY3Qu
anMpLCBzZXQgdXAgd2l0aCB0ZXh0IG1lc3NhZ2VzIGhlcmUKLy8gQWNjb3VudHMgKG5hbWUsIGEg
aGFzaCBvZiB0aGUgcGFzc3dvcmQsIGVhY2ggY2hhcmFjdGVyJ3MgbGV2ZWwgYW5kIGV4cGVyaWVu
Y2UsIHN0b3J5IHByb2dyZXNzKQovLyBhcmUga2VwdCBpbiA8UEFDS1NfRElSPi9oZi9hY2NvdW50
cy5qc29uIChvciBIRl9ESVIpLiBFdmVyeSBzdG9yeSBpcyBvcGVuLCBhbmQgZXZlcnkgY2hhcmFj
dGVyIGEgcGxheWVyCi8vIG1heSBoYXZlIGlzIGF0IGxldmVsIDE2IGZyb20gdGhlIHN0YXJ0OyB0
aGUgcHJlbWl1bSBjaGFyYWN0ZXJzIChhbmQgWWFnYSwgd2hvbSB0aGUgZ2FtZSBrZWVwcyBmb3IK
Ly8gaXRzZWxmKSBzdGF5IGxvY2tlZCBmb3IgcGxheWVycywgYnV0IGZvciB0aGUgYWNjb3VudHMg
dGhlIHJlbGF5J3Mgb3duZXIgb3BlbnMgdGhlbSB0byAocHJlbWl1bTogdHJ1ZSwKLy8gc2V0IG9u
IHRoZSBwYWdlIGF0IC9hZG1pbiwgcGFja3MuanMpOiB0aG9zZSBnZXQgdGhlbSBhdCBsZXZlbCAx
NiB0b28uIENvbXB1dGVyIHBsYXllcnMgZ2V0IGFueSBvZiB0aGVtCi8vIChoZi1yb29tLmpzKS4K
J3VzZSBzdHJpY3QnOwoKY29uc3QgY3J5cHRvID0gcmVxdWlyZSgnbm9kZTpjcnlwdG8nKTsKY29u
c3QgZnMgPSByZXF1aXJlKCdub2RlOmZzJyk7CmNvbnN0IHBhdGggPSByZXF1aXJlKCdub2RlOnBh
dGgnKTsKY29uc3QgeyBIZlJvb20sIEhmQ29ubmVjdGlvbiwgQ0hBUkFDVEVSUyB9ID0gcmVxdWly
ZSgnLi9oZi1yb29tLmpzJyk7Cgpjb25zdCBTVE9SSUVTID0gNjsgLy8gR2xvYmFsLnN0b3J5Q2hv
c2VuX21heDogdGhlIGxhc3Qgc3RvcnkgZXBpc29kZQpjb25zdCBNQVhfRVhQRVJJRU5DRSA9IDE2
OTk5OyAvLyBsZXZlbCAxNiAodGhlIGdhbWUncyBoaWdoZXN0OyBtb3JlIGlzIHRha2VuIGZvciBh
IGNoZWF0KSwgOTk5IGV4cGVyaWVuY2UKY29uc3QgU1RBUlRfRVhQRVJJRU5DRSA9IDE2MDAwOyAv
LyBsZXZlbCAxNjogbm9ib2R5IGhhcyB0byBwbGF5IGZvciBsZXZlbHMKLy8gVGhlIGFjY291bnQn
cyB2YWx1ZXMgKGMxLi5jMzAsIG9uZSBwZXIgY2hhcmFjdGVyLCBDSEFSQUNURVJTJyBvcmRlcikg
dGhlIGdhbWUgZ2V0cyBubyBjaGFyYWN0ZXIgZm9yOgovLyB0aGUgcHJlbWl1bSBvbmVzIChsZW8s
IGVhc29uIGFuZCB3aXRoIGl0IGVhc29uMCwgaWN6enksIGhlYXRlciwgcmF5ZSwgbGl2ZXJtb3Jl
KSwgd2hpY2ggYXJlIHRvbyBzdHJvbmcKLy8gZm9yIHBsYXllcnMsIGFuZCB5YWdhICgidW5hdmFp
bGFibGUiKS4gQSB2YWx1ZSBvZiAwIGtlZXBzIGEgY2hhcmFjdGVyIGxvY2tlZDsgYSBub24tcHJl
bWl1bSBhY2NvdW50Ci8vIChzdGF0dXNDb2RlIGJlbG93KSBrZWVwcyB0aGUgcHJlbWl1bSBvbmVz
IGxvY2tlZCB3aGF0ZXZlciB0aGVpciB2YWx1ZS4KY29uc3QgTE9DS0VEID0gbmV3IFNldChbNSwg
NywgOCwgMTQsIDE1LCAxNiwgMThdKTsKY29uc3QgWUFHQSA9IDg7IC8vIGxvY2tlZCBmb3IgZXZl
cnkgYWNjb3VudDogdGhlIGdhbWUgaXRzZWxmIGxldHMgbm9ib2R5IHBsYXkgaGltIChpdHMgc3Rh
dGUgImYiKQpjb25zdCBQTEFZQUJMRSA9IDE5OyAvLyBjMS4uYzE5IGFyZSBjaGFyYWN0ZXJzOyBj
MjAuLmMzMCBhcmUgbm90IHVzZWQKLy8gVGhlIHZhbHVlcyBhbiBhY2NvdW50IGhhczogdGhlIHBs
YXlhYmxlIGNoYXJhY3RlcnMgYXQgbGV2ZWwgMTYgYXQgbGVhc3QsIHRoZSBsb2NrZWQgb25lcyBh
dCAwIC0gZm9yIGFuIGFjY291bnQKLy8gb3BlbmVkIHRvIHRoZSBwcmVtaXVtIGNoYXJhY3RlcnMg
KHByZW1pdW0pLCB0aG9zZSBhdCBsZXZlbCAxNiBhdCBsZWFzdCBhcyB3ZWxsLCBZYWdhIHN0aWxs
IGF0IDAuCmZ1bmN0aW9uIHNldHRsZWRWYWx1ZXModmFsdWVzLCBwcmVtaXVtID0gZmFsc2UpIHsK
ICByZXR1cm4gQXJyYXkuZnJvbSh7IGxlbmd0aDogMzAgfSwgKF8sIGspID0+IHsKICAgIGlmIChr
ID49IFBMQVlBQkxFKSByZXR1cm4gTnVtYmVyKHZhbHVlcyAmJiB2YWx1ZXNba10pIHx8IDA7CiAg
ICBpZiAoTE9DS0VELmhhcyhrKSAmJiAoIXByZW1pdW0gfHwgayA9PT0gWUFHQSkpIHJldHVybiAw
OwogICAgcmV0dXJuIE1hdGgubWluKE1BWF9FWFBFUklFTkNFLCBNYXRoLm1heChTVEFSVF9FWFBF
UklFTkNFLCBOdW1iZXIodmFsdWVzICYmIHZhbHVlc1trXSkgfHwgMCkpOwogIH0pOwp9CgovLyBU
aGUgZ2FtZSBjaGVja3MgbG9naW4gYW5zd2VycyB3aXRoIGEgY29kZSBvdmVyIHRoZSBudW1iZXJz
IGluIHRoZW0gKEdsb2JhbC5Mb2dpblN0YXR1c01lc3NhZ2UpOgovLyB3aXRoIG4gPSB2WzhdLCBt
ID0gdls5KzJuLi4rN10gYW5kIHggPSB2WzE2KzJuLi4rN10sICg5OTk5OTk4IC0geCAtIG0pIC8g
MyBtdXN0IGJlIHRoZSBzdW0gYmVsb3cKLy8gKG9yIHRoYXQgcGx1cyBpZCUxMyArIGlkJTYxICsg
aWQlMTA3LCBmb3IgYSBwcmVtaXVtIGFjY291bnQ6IGV2ZXJ5IGNoYXJhY3RlciwgYWxzbyB0aGUg
cHJlbWl1bSBvbmVzKS4KZnVuY3Rpb24gc3RhdHVzQ29kZSh2YWx1ZXMsIGlkLCBhY2N0eXBlLCBz
dGFnZSwgc2Vzc2lvbiwgcHJlbWl1bSkgewogIGNvbnN0IHN1bSA9ICh2YWx1ZXMucmVkdWNlKChh
LCBiKSA9PiBhICsgYiwgMCkgKyBpZCArIGFjY3R5cGUgKyBzdGFnZSArIHNlc3Npb24gJSAxMDAw
MDAwKSAlIDEwMDAwMDAgKyAxMDAwMDAwOwogIHJldHVybiBlbmNvZGVOdW1iZXIoc3VtICsgKHBy
ZW1pdW0gPyBpZCAlIDEzICsgaWQgJSA2MSArIGlkICUgMTA3IDogMCkpOwp9CgovLyBBIG51bWJl
ciB0aGUgZ2FtZSByZWFkcyBiYWNrIGFzICg5OTk5OTk4IC0geCAtIG0pIC8gMyBmcm9tIHRoZSAy
NS1kaWdpdCBmb3JtIGFib3ZlIChhbmQgY2FwdGNoYQovLyBjb2RlcyBhcyB0aGF0IG1vZHVsbyAx
MDAwMDAwKTogcmFuZG9tIGRpZ2l0cyBhcm91bmQgaXQsIGFzIGhlcm9maWdodGVyLmNvbSBzZW50
LgpmdW5jdGlvbiBlbmNvZGVOdW1iZXIobnVtYmVyKSB7CiAgY29uc3QgZGlnaXQgPSAoKSA9PiBT
dHJpbmcoY3J5cHRvLnJhbmRvbUludCgxMCkpOwogIGNvbnN0IG4gPSBjcnlwdG8ucmFuZG9tSW50
KDEwKTsKICBjb25zdCBtID0gY3J5cHRvLnJhbmRvbUludCgxMDAwMDAwLCAyMDAwMDAwKTsKICBj
b25zdCB4ID0gOTk5OTk5OCAtIDMgKiBudW1iZXIgLSBtOwogIGxldCB0ZXh0ID0gJyc7CiAgZm9y
IChsZXQgayA9IDA7IGsgPCA4OyBrICs9IDEpIHRleHQgKz0gZGlnaXQoKTsKICB0ZXh0ICs9IFN0
cmluZyhuKTsKICBmb3IgKGxldCBrID0gMDsgayA8IG4gKiAyOyBrICs9IDEpIHRleHQgKz0gZGln
aXQoKTsKICB0ZXh0ICs9IFN0cmluZyhtKS5wYWRTdGFydCg3LCAnMCcpICsgU3RyaW5nKHgpLnBh
ZFN0YXJ0KDcsICcwJyk7CiAgZm9yIChsZXQgayA9IDA7IGsgPCAxOCAtIG4gKiAyOyBrICs9IDEp
IHRleHQgKz0gZGlnaXQoKTsKICByZXR1cm4gdGV4dDsKfQoKLy8gV2hhdCB0aGUgZ2FtZSdzIHBy
ZW1pdW0gb2ZmZXIgKGl0IHNob3dzIG9uZSBieSB0aGUgbG9ja2VkIGNoYXJhY3RlcnMpIG9wZW5z
IGluIGEgbmV3IHRhYi4KY29uc3QgUFJFTUlVTV9QQUdFID0gYDwhZG9jdHlwZSBodG1sPgo8aHRt
bCBsYW5nPSJ2aSI+PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPjxtZXRhIG5hbWU9InZpZXdw
b3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+Cjx0aXRs
ZT5IZXJvIEZpZ2h0ZXI6IFByZW1pdW08L3RpdGxlPgo8c3R5bGU+Ym9keXtmb250OjE3cHgvMS41
NSBzeXN0ZW0tdWksc2Fucy1zZXJpZjttYXgtd2lkdGg6MzZyZW07bWFyZ2luOjNyZW0gYXV0bztw
YWRkaW5nOjAgMTZweDtjb2xvcjojMWQxZDFkO2JhY2tncm91bmQ6I2Y3ZjdmNX0KaDF7Zm9udC1z
aXplOjEuMzVyZW19LmVue2NvbG9yOiM2YTZhNmE7Zm9udC1zaXplOi45NXJlbX0KQG1lZGlhIChw
cmVmZXJzLWNvbG9yLXNjaGVtZTpkYXJrKXtib2R5e2NvbG9yOiNlY2VjZWM7YmFja2dyb3VuZDoj
MWExYTFhfS5lbntjb2xvcjojYTBhMGEwfX08L3N0eWxlPjwvaGVhZD4KPGJvZHk+PGgxPktow7Ru
ZyBj4bqnbiBtdWEgZ8OsIGPhuqM8L2gxPgo8cD5UcsOqbiBtw6F5IGNo4bunIG7DoHksIGPDoWMg
bmjDom4gduG6rXQgUHJlbWl1bSAoTGVvLCBFYXNvbiwgSWN6enksIEhlYXRlciwgUmF5ZSwgTGl2
ZXJtb3JlKSBi4buLIGtow7NhIHbhu5tpIG5nxrDhu51pIGNoxqFpIHbDrCBxdcOhCm3huqFuaDsg
bcOheSAoQ29tIFBsYXllcikgduG6q24gZMO5bmcgxJHGsOG7o2MuIE3hu41pIG5ow6JuIHbhuq10
IGtow6FjIMSR4buBdSDEkcOjIOG7nyBMZXZlbCAxNi48L3A+CjxwPsSQw7NuZyB0cmFuZyBuw6B5
IHbDoCBxdWF5IGzhuqFpIGdhbWUuPC9wPgo8cCBjbGFzcz0iZW4iIGxhbmc9ImVuIj5Ob3RoaW5n
IHRvIGJ1eSBoZXJlOiBvbiB0aGlzIHNlcnZlciB0aGUgcHJlbWl1bSBjaGFyYWN0ZXJzIGFyZSBs
b2NrZWQgZm9yIHBsYXllcnMgKHRoZXkgYXJlIHRvbwpzdHJvbmcpLCBhbmQgY29tcHV0ZXIgcGxh
eWVycyBtYXkgc3RpbGwgaGF2ZSB0aGVtLiBFdmVyeSBvdGhlciBjaGFyYWN0ZXIgaXMgYXQgbGV2
ZWwgMTYuIENsb3NlIHRoaXMgcGFnZSBhbmQgZ28gYmFjawp0byB0aGUgZ2FtZS48L3A+CjwvYm9k
eT48L2h0bWw+CmA7CgpmdW5jdGlvbiB4bWxUZXh0KHZhbHVlKSB7CiAgcmV0dXJuIFN0cmluZyh2
YWx1ZSkucmVwbGFjZSgvWzw+Jl0vZywgKGMpID0+ICh7ICc8JzogJyZsdDsnLCAnPic6ICcmZ3Q7
JywgJyYnOiAnJmFtcDsnIH1bY10pKTsKfQoKLy8gQSBkaXNwbGF5IG5hbWU6IHdoYXQgdGhlIGdh
bWUgYWxsb3dzIGluIG9uZSAobm8gWyBvciBdLCB3aGljaCBpdCB1c2VzIGl0c2VsZiksIGF0IG1v
c3QgMjAgY2hhcmFjdGVycy4KZnVuY3Rpb24gY2xlYW5OYW1lKHZhbHVlKSB7CiAgcmV0dXJuIFN0
cmluZyh2YWx1ZSB8fCAnJykucmVwbGFjZSgvW1tcXTw+JiJcdTAwMDAtXHUwMDFmXS9nLCAnJyku
dHJpbSgpLnNsaWNlKDAsIDIwKTsKfQoKZnVuY3Rpb24gaGFzaFBhc3N3b3JkKHBhc3N3b3JkLCBz
YWx0KSB7CiAgcmV0dXJuIGNyeXB0by5zY3J5cHRTeW5jKFN0cmluZyhwYXNzd29yZCksIHNhbHQs
IDMyKS50b1N0cmluZygnaGV4Jyk7Cn0KCmZ1bmN0aW9uIGNyZWF0ZUFjY291bnRzKGZpbGUsIGxv
ZykgewogIGxldCBhY2NvdW50cyA9IHt9OwogIGxldCBuZXh0SWQgPSAxMDAxOyAvLyBpZHMgdXAg
dG8gMjAgb3BlbiB0aGUgZ2FtZSdzIGRldmVsb3BlciBrZXlzCiAgbGV0IHNhdmVUaW1lciA9IG51
bGw7CiAgaWYgKGZpbGUpIHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHNhdmVkID0gSlNPTi5wYXJz
ZShmcy5yZWFkRmlsZVN5bmMoZmlsZSwgJ3V0ZjgnKSk7CiAgICAgIGFjY291bnRzID0gc2F2ZWQu
YWNjb3VudHMgfHwge307CiAgICAgIG5leHRJZCA9IE1hdGgubWF4KG5leHRJZCwgTnVtYmVyKHNh
dmVkLm5leHRJZCkgfHwgMCk7CiAgICB9IGNhdGNoIChlcnJvcikgewogICAgICBpZiAoZXJyb3Iu
Y29kZSAhPT0gJ0VOT0VOVCcpIGxvZyhgaGYgYWNjb3VudHM6IGNvdWxkIG5vdCByZWFkICR7Zmls
ZX06ICR7ZXJyb3IubWVzc2FnZX1gKTsKICAgIH0KICB9CiAgY29uc3Qgc2F2ZSA9ICgpID0+IHsK
ICAgIGlmICghZmlsZSB8fCBzYXZlVGltZXIpIHJldHVybjsKICAgIHNhdmVUaW1lciA9IHNldFRp
bWVvdXQoKCkgPT4gewogICAgICBzYXZlVGltZXIgPSBudWxsOwogICAgICB0cnkgewogICAgICAg
IGZzLm1rZGlyU3luYyhwYXRoLmRpcm5hbWUoZmlsZSksIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwog
ICAgICAgIGNvbnN0IHRlbXBvcmFyeSA9IGAke2ZpbGV9LiR7cHJvY2Vzcy5waWR9LnRtcGA7CiAg
ICAgICAgZnMud3JpdGVGaWxlU3luYyh0ZW1wb3JhcnksIEpTT04uc3RyaW5naWZ5KHsgdmVyc2lv
bjogMSwgbmV4dElkLCBhY2NvdW50cyB9LCBudWxsLCAxKSk7CiAgICAgICAgZnMucmVuYW1lU3lu
Yyh0ZW1wb3JhcnksIGZpbGUpOwogICAgICB9IGNhdGNoIChlcnJvcikgewogICAgICAgIGxvZyhg
aGYgYWNjb3VudHM6IGNvdWxkIG5vdCBzYXZlOiAke2Vycm9yLm1lc3NhZ2V9YCk7CiAgICAgIH0K
ICAgIH0sIDUwMCk7CiAgICBpZiAoc2F2ZVRpbWVyLnVucmVmKSBzYXZlVGltZXIudW5yZWYoKTsK
ICB9OwogIHJldHVybiB7CiAgICBnZXQoZW1haWwpIHsgcmV0dXJuIGFjY291bnRzW2VtYWlsXSB8
fCBudWxsOyB9LAogICAgYnlJZChpZCkgeyByZXR1cm4gT2JqZWN0LnZhbHVlcyhhY2NvdW50cyku
ZmluZCgoYWNjb3VudCkgPT4gU3RyaW5nKGFjY291bnQuaWQpID09PSBTdHJpbmcoaWQpKSB8fCBu
dWxsOyB9LAogICAgYnlOYW1lKG5hbWUpIHsgcmV0dXJuIE9iamVjdC52YWx1ZXMoYWNjb3VudHMp
LmZpbmQoKGFjY291bnQpID0+IGFjY291bnQubmFtZS50b0xvd2VyQ2FzZSgpID09PSBuYW1lLnRv
TG93ZXJDYXNlKCkpIHx8IG51bGw7IH0sCiAgICBjcmVhdGUoZW1haWwsIHBhc3N3b3JkLCBuYW1l
LCBjYykgewogICAgICBjb25zdCBzYWx0ID0gY3J5cHRvLnJhbmRvbUJ5dGVzKDEyKS50b1N0cmlu
ZygnaGV4Jyk7CiAgICAgIGxldCB1bmlxdWUgPSBuYW1lIHx8ICdQbGF5ZXInOwogICAgICBmb3Ig
KGxldCBrID0gMjsgdGhpcy5ieU5hbWUodW5pcXVlKTsgayArPSAxKSB1bmlxdWUgPSBgJHtuYW1l
LnNsaWNlKDAsIDE3KX0ke2t9YDsKICAgICAgY29uc3QgYWNjb3VudCA9IHsKICAgICAgICBpZDog
bmV4dElkKyssIG5hbWU6IHVuaXF1ZSwgY2M6IGNjIHx8ICdWTicsIHNhbHQsIGhhc2g6IGhhc2hQ
YXNzd29yZChwYXNzd29yZCwgc2FsdCksCiAgICAgICAgc2Vzc2lvbjogY3J5cHRvLnJhbmRvbUlu
dCgxMDAwMDAsIDEwMDAwMDAwMDApLCB2YWx1ZXM6IHNldHRsZWRWYWx1ZXMobnVsbCksCiAgICAg
ICAgc3RhZ2U6IFNUT1JJRVMsIG5hbWVDaGFuZ2VzOiA5LCBjcmVhdGVkOiBuZXcgRGF0ZSgpLnRv
SVNPU3RyaW5nKCksIC8vIChuYW1lIGNoYW5nZXMgYXJlIG5vdCBjb3VudGVkIGRvd24pCiAgICAg
IH07CiAgICAgIGFjY291bnRzW2VtYWlsXSA9IGFjY291bnQ7CiAgICAgIHNhdmUoKTsKICAgICAg
cmV0dXJuIGFjY291bnQ7CiAgICB9LAogICAgLy8gRm9yIHRoZSBwYWdlIGF0IC9hZG1pbjogZXZl
cnkgYWNjb3VudCAoaXRzIGUtbWFpbCBhZGRyZXNzLCBuYW1lLCBpZCwgd2hldGhlciBpdCBoYXMg
dGhlIHByZW1pdW0gY2hhcmFjdGVycykuCiAgICBsaXN0KCkgewogICAgICByZXR1cm4gT2JqZWN0
LmVudHJpZXMoYWNjb3VudHMpLm1hcCgoW2VtYWlsLCBhY2NvdW50XSkgPT4gKHsKICAgICAgICBp
ZDogYWNjb3VudC5pZCwgbmFtZTogYWNjb3VudC5uYW1lLCBlbWFpbCwgcHJlbWl1bTogYWNjb3Vu
dC5wcmVtaXVtID09PSB0cnVlLAogICAgICAgIGNyZWF0ZWQ6IGFjY291bnQuY3JlYXRlZCB8fCAn
Jywgc2VlbjogYWNjb3VudC5zZWVuIHx8ICcnLAogICAgICB9KSkuc29ydCgoYSwgYikgPT4gYS5u
YW1lLmxvY2FsZUNvbXBhcmUoYi5uYW1lKSk7CiAgICB9LAogICAgLy8gT3BlbnMgdGhlIHByZW1p
dW0gY2hhcmFjdGVycyB0byBhbiBhY2NvdW50IChvciBsb2NrcyB0aGVtIGFnYWluKSwgZnJvbSBp
dHMgbmV4dCBsb2dpbi4KICAgIHNldFByZW1pdW0oaWQsIG9uKSB7CiAgICAgIGNvbnN0IGZvdW5k
ID0gT2JqZWN0LmVudHJpZXMoYWNjb3VudHMpLmZpbmQoKFssIGFjY291bnRdKSA9PiBTdHJpbmco
YWNjb3VudC5pZCkgPT09IFN0cmluZyhpZCkpOwogICAgICBpZiAoIWZvdW5kKSByZXR1cm4gbnVs
bDsKICAgICAgY29uc3QgW2VtYWlsLCBhY2NvdW50XSA9IGZvdW5kOwogICAgICBpZiAob24pIGFj
Y291bnQucHJlbWl1bSA9IHRydWU7CiAgICAgIGVsc2UgZGVsZXRlIGFjY291bnQucHJlbWl1bTsK
ICAgICAgYWNjb3VudC52YWx1ZXMgPSBzZXR0bGVkVmFsdWVzKGFjY291bnQudmFsdWVzLCBvbik7
CiAgICAgIHNhdmUoKTsKICAgICAgcmV0dXJuIHsgaWQ6IGFjY291bnQuaWQsIG5hbWU6IGFjY291
bnQubmFtZSwgZW1haWwsIHByZW1pdW06IG9uIH07CiAgICB9LAogICAgY2hlY2tQYXNzd29yZChh
Y2NvdW50LCBwYXNzd29yZCkgewogICAgICBjb25zdCBleHBlY3RlZCA9IEJ1ZmZlci5mcm9tKGFj
Y291bnQuaGFzaCwgJ2hleCcpOwogICAgICBjb25zdCBnaXZlbiA9IEJ1ZmZlci5mcm9tKGhhc2hQ
YXNzd29yZChwYXNzd29yZCwgYWNjb3VudC5zYWx0KSwgJ2hleCcpOwogICAgICByZXR1cm4gZXhw
ZWN0ZWQubGVuZ3RoID09PSBnaXZlbi5sZW5ndGggJiYgY3J5cHRvLnRpbWluZ1NhZmVFcXVhbChl
eHBlY3RlZCwgZ2l2ZW4pOwogICAgfSwKICAgIHNldFBhc3N3b3JkKGFjY291bnQsIHBhc3N3b3Jk
KSB7CiAgICAgIGFjY291bnQuc2FsdCA9IGNyeXB0by5yYW5kb21CeXRlcygxMikudG9TdHJpbmco
J2hleCcpOwogICAgICBhY2NvdW50Lmhhc2ggPSBoYXNoUGFzc3dvcmQocGFzc3dvcmQsIGFjY291
bnQuc2FsdCk7CiAgICAgIHNhdmUoKTsKICAgIH0sCiAgICBzYXZlLAogICAgZmx1c2goKSB7CiAg
ICAgIGlmICghc2F2ZVRpbWVyKSByZXR1cm47CiAgICAgIGNsZWFyVGltZW91dChzYXZlVGltZXIp
OwogICAgICBzYXZlVGltZXIgPSBudWxsOwogICAgICB0cnkgewogICAgICAgIGZzLm1rZGlyU3lu
YyhwYXRoLmRpcm5hbWUoZmlsZSksIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwogICAgICAgIGZzLndy
aXRlRmlsZVN5bmMoZmlsZSwgSlNPTi5zdHJpbmdpZnkoeyB2ZXJzaW9uOiAxLCBuZXh0SWQsIGFj
Y291bnRzIH0sIG51bGwsIDEpKTsKICAgICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgICBsb2co
YGhmIGFjY291bnRzOiBjb3VsZCBub3Qgc2F2ZTogJHtlcnJvci5tZXNzYWdlfWApOwogICAgICB9
CiAgICB9LAogIH07Cn0KCmZ1bmN0aW9uIGNyZWF0ZUhmKGNvbmZpZywgeyBsb2csIGNsaWVudEFk
ZHJlc3MsIGFsbG93T3JpZ2luLCBidWRnZXQgfSkgewogIGNvbnN0IGZvbGRlciA9IGNvbmZpZy5o
ZkRpciB8fCAoY29uZmlnLnBhY2tzRGlyID8gcGF0aC5qb2luKGNvbmZpZy5wYWNrc0RpciwgJ2hm
JykgOiAnJyk7CiAgY29uc3QgYWNjb3VudHMgPSBjcmVhdGVBY2NvdW50cyhmb2xkZXIgJiYgcGF0
aC5qb2luKGZvbGRlciwgJ2FjY291bnRzLmpzb24nKSwgbG9nKTsKICBjb25zdCByb29tQ291bnQg
PSBNYXRoLm1heCgxLCBNYXRoLm1pbigyMCwgTWF0aC5yb3VuZChjb25maWcuaGZSb29tcyB8fCA0
KSkpOwogIGNvbnN0IHJvb21zID0gW107CiAgZm9yIChsZXQgbnVtYmVyID0gMTsgbnVtYmVyIDw9
IHJvb21Db3VudDsgbnVtYmVyICs9IDEpIHsKICAgIHJvb21zLnB1c2gobmV3IEhmUm9vbSh7IG51
bWJlciwgbmFtZTogYFBob25nICR7bnVtYmVyfWAsIGRlc2NyaXB0aW9uOiBjb25maWcuaGZSb29t
RGVzY3JpcHRpb24gfHwgJ09wZW5MRjIgcmVsYXknLCBsb2cgfSkpOwogIH0KICBjb25zdCBjYXB0
Y2hhcyA9IG5ldyBNYXAoKTsgLy8gY2xpZW50IGtleSAtPiB7IGNvZGUsIHVudGlsIH0KICBjb25z
dCB0cmllcyA9IG5ldyBNYXAoKTsgLy8gY2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwg
fTogZmFpbGVkIHBhc3N3b3JkcyBhbmQgY29kZXMKICBjb25zdCBjcmVhdGlvbnMgPSBuZXcgTWFw
KCk7IC8vIGNsaWVudCBhZGRyZXNzIC0+IHsgY291bnQsIHVudGlsIH06IG5ldyBhY2NvdW50cwog
IGNvbnN0IG1heUNyZWF0ZSA9IChhZGRyZXNzKSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5v
dygpOwogICAgbGV0IGVudHJ5ID0gY3JlYXRpb25zLmdldChhZGRyZXNzKTsKICAgIGlmICghZW50
cnkgfHwgZW50cnkudW50aWwgPD0gbm93KSB7CiAgICAgIGVudHJ5ID0geyBjb3VudDogMCwgdW50
aWw6IG5vdyArIDM2MDAwMDAgfTsKICAgICAgY3JlYXRpb25zLnNldChhZGRyZXNzLCBlbnRyeSk7
CiAgICB9CiAgICBpZiAoZW50cnkuY291bnQgPj0gMjApIHJldHVybiBmYWxzZTsKICAgIGVudHJ5
LmNvdW50ICs9IDE7CiAgICByZXR1cm4gdHJ1ZTsKICB9OwogIGNvbnN0IExJTUlUID0gJzxlbj5U
b28gbWFueSBuZXcgYWNjb3VudHMgZnJvbSB5b3VyIG5ldHdvcms6IHRyeSBhZ2FpbiBpbiBhbiBo
b3VyLjwvZW4+PGI1PlRvbyBtYW55IG5ldyBhY2NvdW50cyBmcm9tIHlvdXIgbmV0d29yazogdHJ5
IGFnYWluIGluIGFuIGhvdXIuPC9iNT4nOwoKICBmdW5jdGlvbiBsb2dpblhtbChhY2NvdW50LCBy
b290ID0gJ2xvZ2luJykgewogICAgY29uc3QgdmFsdWVzID0gYWNjb3VudC52YWx1ZXM7CiAgICBj
b25zdCBmaWVsZHMgPSB2YWx1ZXMubWFwKCh2YWx1ZSwgaW5kZXgpID0+IGA8YyR7aW5kZXggKyAx
fT4ke3ZhbHVlfTwvYyR7aW5kZXggKyAxfT5gKS5qb2luKCcnKTsKICAgIGNvbnN0IGNvZGUgPSBz
dGF0dXNDb2RlKHZhbHVlcywgYWNjb3VudC5pZCwgMCwgYWNjb3VudC5zdGFnZSwgYWNjb3VudC5z
ZXNzaW9uLCBhY2NvdW50LnByZW1pdW0gPT09IHRydWUpOwogICAgcmV0dXJuIGA8JHtyb290fT4k
e2ZpZWxkc308aT4ke2FjY291bnQuaWR9PC9pPjxuPiR7eG1sVGV4dChhY2NvdW50Lm5hbWUpfTwv
bj48Y2M+JHt4bWxUZXh0KGFjY291bnQuY2MpfTwvY2M+YAogICAgICArIGA8cz4ke2FjY291bnQu
c2Vzc2lvbn08L3M+PGFjY3R5cGU+MDwvYWNjdHlwZT48c3RhZ2U+JHthY2NvdW50LnN0YWdlfTwv
c3RhZ2U+PHY+JHtjb2RlfTwvdj48LyR7cm9vdH0+YDsKICB9CgogIGNvbnN0IHBydW5lID0gKCkg
PT4gewogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAoY29uc3QgbWFwIG9mIFt0
cmllcywgY3JlYXRpb25zXSkgZm9yIChjb25zdCBba2V5LCBlbnRyeV0gb2YgbWFwKSBpZiAoZW50
cnkudW50aWwgPD0gbm93KSBtYXAuZGVsZXRlKGtleSk7CiAgICBmb3IgKGNvbnN0IFtrZXksIGVu
dHJ5XSBvZiBjYXB0Y2hhcykgaWYgKGVudHJ5LnVudGlsIDw9IG5vdykgY2FwdGNoYXMuZGVsZXRl
KGtleSk7CiAgfTsKICBjb25zdCBwcnVuZVRpbWVyID0gc2V0SW50ZXJ2YWwocHJ1bmUsIDYwMDAw
MCk7CiAgaWYgKHBydW5lVGltZXIudW5yZWYpIHBydW5lVGltZXIudW5yZWYoKTsKCiAgZnVuY3Rp
b24gdG9vTWFueVRyaWVzKGFkZHJlc3MpIHsKICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAg
ICBjb25zdCBlbnRyeSA9IHRyaWVzLmdldChhZGRyZXNzKTsKICAgIHJldHVybiBCb29sZWFuKGVu
dHJ5ICYmIGVudHJ5LnVudGlsID4gbm93ICYmIGVudHJ5LmNvdW50ID49IDMwKTsKICB9CiAgZnVu
Y3Rpb24gZmFpbGVkVHJ5KGFkZHJlc3MpIHsKICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAg
ICBsZXQgZW50cnkgPSB0cmllcy5nZXQoYWRkcmVzcyk7CiAgICBpZiAoIWVudHJ5IHx8IGVudHJ5
LnVudGlsIDw9IG5vdykgewogICAgICBlbnRyeSA9IHsgY291bnQ6IDAsIHVudGlsOiBub3cgKyAz
NjAwMDAwIH07CiAgICAgIHRyaWVzLnNldChhZGRyZXNzLCBlbnRyeSk7CiAgICB9CiAgICBlbnRy
eS5jb3VudCArPSAxOwogIH0KCiAgZnVuY3Rpb24gY2hlY2tDYXB0Y2hhKGtleSwgY29kZSkgewog
ICAgY29uc3QgZW50cnkgPSBjYXB0Y2hhcy5nZXQoU3RyaW5nKGtleSB8fCAnJykpOwogICAgY2Fw
dGNoYXMuZGVsZXRlKFN0cmluZyhrZXkgfHwgJycpKTsKICAgIHJldHVybiBCb29sZWFuKGVudHJ5
ICYmIGVudHJ5LnVudGlsID4gRGF0ZS5ub3coKSAmJiBTdHJpbmcoZW50cnkuY29kZSkgPT09IFN0
cmluZyhjb2RlIHx8ICcnKS50cmltKCkpOwogIH0KCiAgY29uc3QgZW1haWwgPSAodmFsdWUpID0+
IFN0cmluZyh2YWx1ZSB8fCAnJykudHJpbSgpLnRvTG93ZXJDYXNlKCkuc2xpY2UoMCwgMTAwKTsK
CiAgLy8gVGhlIGFuc3dlciB0byBvbmUgb2YgdGhlIGFjY291bnQgc2VydmljZXMsIGZyb20gdGhl
IHF1ZXJ5IChhbmQgYSBmb3JtIGJvZHksIGlmIGFueSkuCiAgZnVuY3Rpb24gYW5zd2VyKHNlcnZp
Y2UsIHBhcmFtcywgYWRkcmVzcykgewogICAgY29uc3QgZ2V0ID0gKG5hbWUpID0+IHBhcmFtcy5n
ZXQobmFtZSkgfHwgJyc7CiAgICBpZiAoc2VydmljZSA9PT0gJ3YwLjcvbG9naW4ucGhwJykgewog
ICAgICBjb25zdCBlbSA9IGVtYWlsKGdldCgnZW0nKSk7CiAgICAgIGlmICghZW0pIHJldHVybiAn
PGxvZ2luPjxlcnJvcj5lbTwvZXJyb3I+PC9sb2dpbj4nOwogICAgICBpZiAodG9vTWFueVRyaWVz
KGFkZHJlc3MpKSByZXR1cm4gJzxsb2dpbj48ZXJyb3I+cmVhc29uPC9lcnJvcj48ZW4+VG9vIG1h
bnkgd3JvbmcgcGFzc3dvcmRzOiB0cnkgYWdhaW4gaW4gYW4gaG91ci48L2VuPjxiNT5Ub28gbWFu
eSB3cm9uZyBwYXNzd29yZHM6IHRyeSBhZ2FpbiBpbiBhbiBob3VyLjwvYjU+PC9sb2dpbj4nOwog
ICAgICBsZXQgYWNjb3VudCA9IGFjY291bnRzLmdldChlbSk7CiAgICAgIGlmICghYWNjb3VudCkg
ewogICAgICAgIGlmICghbWF5Q3JlYXRlKGFkZHJlc3MpKSByZXR1cm4gYDxsb2dpbj48ZXJyb3I+
cmVhc29uPC9lcnJvcj4ke0xJTUlUfTwvbG9naW4+YDsKICAgICAgICBhY2NvdW50ID0gYWNjb3Vu
dHMuY3JlYXRlKGVtLCBnZXQoJ3B3JyksIGNsZWFuTmFtZShlbS5zcGxpdCgnQCcpWzBdKSwgJ1ZO
Jyk7CiAgICAgICAgbG9nKGBoZjogbmV3IGFjY291bnQgJHthY2NvdW50LmlkfSAiJHthY2NvdW50
Lm5hbWV9ImApOwogICAgICB9IGVsc2UgaWYgKCFhY2NvdW50cy5jaGVja1Bhc3N3b3JkKGFjY291
bnQsIGdldCgncHcnKSkpIHsKICAgICAgICBmYWlsZWRUcnkoYWRkcmVzcyk7CiAgICAgICAgcmV0
dXJuICc8bG9naW4+PGVycm9yPnB3PC9lcnJvcj48L2xvZ2luPic7CiAgICAgIH0KICAgICAgLy8g
QWNjb3VudHMgbWFkZSBiZWZvcmUgdGhlIGNoYXJhY3RlcnMnIHJ1bGVzIHdlcmUgd2hhdCB0aGV5
IGFyZSBub3cgZm9sbG93IHRoZW0gZnJvbSB0aGVpciBuZXh0IGxvZ2luLCBhcwogICAgICAvLyBk
b2VzIGFuIGFjY291bnQgdGhlIHJlbGF5J3Mgb3duZXIgb3BlbmVkIHRoZSBwcmVtaXVtIGNoYXJh
Y3RlcnMgdG8sIG9yIGxvY2tlZCB0aGVtIGFnYWluIGZvci4KICAgICAgY29uc3Qgc2V0dGxlZCA9
IHNldHRsZWRWYWx1ZXMoYWNjb3VudC52YWx1ZXMsIGFjY291bnQucHJlbWl1bSA9PT0gdHJ1ZSk7
CiAgICAgIGlmIChzZXR0bGVkLnNvbWUoKHZhbHVlLCBrKSA9PiB2YWx1ZSAhPT0gYWNjb3VudC52
YWx1ZXNba10pKSBhY2NvdW50LnZhbHVlcyA9IHNldHRsZWQ7CiAgICAgIGFjY291bnQuc2VlbiA9
IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKTsKICAgICAgYWNjb3VudHMuc2F2ZSgpOwogICAgICBy
ZXR1cm4gbG9naW5YbWwoYWNjb3VudCk7CiAgICB9CiAgICBpZiAoc2VydmljZSA9PT0gJ3YwLjcv
bHUucGhwJykgewogICAgICBjb25zdCBhY2NvdW50ID0gYWNjb3VudHMuZ2V0KGVtYWlsKGdldCgn
ZW0nKSkpOwogICAgICBpZiAoIWFjY291bnQgfHwgU3RyaW5nKGFjY291bnQuaWQpICE9PSBnZXQo
J2lkJykgfHwgU3RyaW5nKGFjY291bnQuc2Vzc2lvbikgIT09IGdldCgncycpKSByZXR1cm4gJzxs
dT48ZXJyb3I+c2E8L2Vycm9yPjwvbHU+JzsKICAgICAgZm9yIChsZXQgayA9IDE7IGsgPD0gMzsg
ayArPSAxKSB7CiAgICAgICAgY29uc3QgaW5kZXggPSBOdW1iZXIoZ2V0KGBpJHtrfWApKTsKICAg
ICAgICBjb25zdCB0byA9IE51bWJlcihnZXQoYHRvJHtrfWApKTsKICAgICAgICBpZiAoIU51bWJl
ci5pc0ludGVnZXIoaW5kZXgpIHx8IGluZGV4IDwgMSB8fCBpbmRleCA+IENIQVJBQ1RFUlMubGVu
Z3RoIC0gMSB8fCAhTnVtYmVyLmlzRmluaXRlKHRvKSkgY29udGludWU7CiAgICAgICAgYWNjb3Vu
dC52YWx1ZXNbaW5kZXggLSAxXSA9IE1hdGgubWF4KGFjY291bnQudmFsdWVzW2luZGV4IC0gMV0s
IE1hdGgubWluKE1BWF9FWFBFUklFTkNFLCBNYXRoLmZsb29yKHRvKSkpOwogICAgICB9CiAgICAg
IC8vICh1bGksIGEgY2hhcmFjdGVyIGEgc3RvcnkgdW5sb2NrczogZXZlcnkgY2hhcmFjdGVyIGEg
cGxheWVyIG1heSBoYXZlIGlzIHVubG9ja2VkIGFscmVhZHkuKQogICAgICBhY2NvdW50LnZhbHVl
cyA9IHNldHRsZWRWYWx1ZXMoYWNjb3VudC52YWx1ZXMsIGFjY291bnQucHJlbWl1bSA9PT0gdHJ1
ZSk7CiAgICAgIGNvbnN0IHN0YWdlID0gTnVtYmVyKGdldCgnc3RnJykpOwogICAgICBpZiAoTnVt
YmVyLmlzSW50ZWdlcihzdGFnZSkpIGFjY291bnQuc3RhZ2UgPSBNYXRoLm1heChhY2NvdW50LnN0
YWdlLCBNYXRoLm1pbihTVE9SSUVTLCBzdGFnZSkpOwogICAgICBhY2NvdW50cy5zYXZlKCk7CiAg
ICAgIHJldHVybiBsb2dpblhtbChhY2NvdW50LCAnbHUnKTsKICAgIH0KICAgIGlmIChzZXJ2aWNl
ID09PSAnY2FwLnBocCcpIHsKICAgICAgY29uc3Qga2V5ID0gY3J5cHRvLnJhbmRvbUJ5dGVzKDgp
LnRvU3RyaW5nKCdoZXgnKTsKICAgICAgY29uc3QgY29kZSA9IGNyeXB0by5yYW5kb21JbnQoMTAw
MCwgMTAwMDApOwogICAgICBjYXB0Y2hhcy5zZXQoa2V5LCB7IGNvZGUsIHVudGlsOiBEYXRlLm5v
dygpICsgNjAwMDAwIH0pOwogICAgICBpZiAoY2FwdGNoYXMuc2l6ZSA+IDIwMDApIGNhcHRjaGFz
LmRlbGV0ZShjYXB0Y2hhcy5rZXlzKCkubmV4dCgpLnZhbHVlKTsKICAgICAgcmV0dXJuIGA8Y2Fw
PjxjMT4ke2tleX08L2MxPjxjMj4ke2VuY29kZU51bWJlcihjb2RlKX08L2MyPjwvY2FwPmA7CiAg
ICB9CiAgICBpZiAoc2VydmljZSA9PT0gJ3JlZy5waHAnKSB7CiAgICAgIGlmICghY2hlY2tDYXB0
Y2hhKGdldCgnYycpLCBnZXQoJ3MnKSkpIHJldHVybiAnPHJlZz48ZXJyb3I+Y29kZTwvZXJyb3I+
PC9yZWc+JzsKICAgICAgY29uc3QgZW0gPSBlbWFpbChnZXQoJ2VtJykpOwogICAgICBpZiAoIWVt
IHx8IGFjY291bnRzLmdldChlbSkpIHJldHVybiAnPHJlZz48ZXJyb3I+c2FtZWVtYWlsPC9lcnJv
cj48L3JlZz4nOwogICAgICBjb25zdCBuYW1lID0gY2xlYW5OYW1lKGdldCgnbm0nKSk7CiAgICAg
IGlmICghbmFtZSkgcmV0dXJuICc8cmVnPjxlcnJvcj5uYW1lPC9lcnJvcj48L3JlZz4nOwogICAg
ICBpZiAoYWNjb3VudHMuYnlOYW1lKG5hbWUpKSByZXR1cm4gJzxyZWc+PGVycm9yPnNhbWVuYW1l
PC9lcnJvcj48L3JlZz4nOwogICAgICBpZiAoIW1heUNyZWF0ZShhZGRyZXNzKSkgcmV0dXJuIGA8
cmVnPjxlcnJvcj5saW1pdDwvZXJyb3I+JHtMSU1JVH08L3JlZz5gOwogICAgICBjb25zdCBhY2Nv
dW50ID0gYWNjb3VudHMuY3JlYXRlKGVtLCBnZXQoJ3B3JyksIG5hbWUsIFN0cmluZyhnZXQoJ2Nj
JykpLnJlcGxhY2UoL1teQS1aXS9nLCAnJykuc2xpY2UoMCwgMikgfHwgJ1ZOJyk7CiAgICAgIGxv
ZyhgaGY6IG5ldyBhY2NvdW50ICR7YWNjb3VudC5pZH0gIiR7YWNjb3VudC5uYW1lfSIgKHJlZ2lz
dGVyZWQpYCk7CiAgICAgIHJldHVybiBsb2dpblhtbChhY2NvdW50LCAncmVnJyk7CiAgICB9CiAg
ICBjb25zdCBieUlkID0gKCkgPT4gewogICAgICBjb25zdCBhY2NvdW50ID0gYWNjb3VudHMuZ2V0
KGVtYWlsKGdldCgnZW0nKSkpOwogICAgICByZXR1cm4gYWNjb3VudCAmJiBTdHJpbmcoYWNjb3Vu
dC5pZCkgPT09IGdldCgnaWQnKSAmJiBTdHJpbmcoYWNjb3VudC5zZXNzaW9uKSA9PT0gZ2V0KCdz
cycpID8gYWNjb3VudCA6IG51bGw7CiAgICB9OwogICAgaWYgKHNlcnZpY2UgPT09ICduYW1lY2hn
X2xlZnQucGhwJykgewogICAgICBjb25zdCBhY2NvdW50ID0gYWNjb3VudHMuYnlJZChnZXQoJ2lk
JykpOwogICAgICByZXR1cm4gYDxuYW1lY2hnPjxuPiR7YWNjb3VudCA/IGFjY291bnQubmFtZUNo
YW5nZXMgOiAwfTwvbj48L25hbWVjaGc+YDsKICAgIH0KICAgIGlmIChzZXJ2aWNlID09PSAnbmFt
ZWNoZy5waHAnKSB7CiAgICAgIGlmICghY2hlY2tDYXB0Y2hhKGdldCgnYycpLCBnZXQoJ3MnKSkp
IHJldHVybiAnPG5hbWVjaGc+PGVycm9yPmNvZGU8L2Vycm9yPjwvbmFtZWNoZz4nOwogICAgICBj
b25zdCBhY2NvdW50ID0gYnlJZCgpOwogICAgICBpZiAoIWFjY291bnQpIHJldHVybiAnPG5hbWVj
aGc+PGVycm9yPnNhPC9lcnJvcj48L25hbWVjaGc+JzsKICAgICAgaWYgKCFhY2NvdW50cy5jaGVj
a1Bhc3N3b3JkKGFjY291bnQsIGdldCgncHcnKSkpIHsgZmFpbGVkVHJ5KGFkZHJlc3MpOyByZXR1
cm4gJzxuYW1lY2hnPjxlcnJvcj5wd2Q8L2Vycm9yPjwvbmFtZWNoZz4nOyB9CiAgICAgIGNvbnN0
IG5hbWUgPSBjbGVhbk5hbWUoZ2V0KCdubicpKTsKICAgICAgaWYgKCFuYW1lKSByZXR1cm4gJzxu
YW1lY2hnPjxlcnJvcj5uYW1lPC9lcnJvcj48L25hbWVjaGc+JzsKICAgICAgY29uc3Qgb3RoZXIg
PSBhY2NvdW50cy5ieU5hbWUobmFtZSk7CiAgICAgIGlmIChvdGhlciAmJiBvdGhlciAhPT0gYWNj
b3VudCkgcmV0dXJuICc8bmFtZWNoZz48ZXJyb3I+c2FtZW5hbWU8L2Vycm9yPjwvbmFtZWNoZz4n
OwogICAgICBhY2NvdW50Lm5hbWUgPSBuYW1lOwogICAgICBhY2NvdW50cy5zYXZlKCk7CiAgICAg
IHJldHVybiBgPG5hbWVjaGc+PG0+JHthY2NvdW50Lm5hbWVDaGFuZ2VzfTwvbT48L25hbWVjaGc+
YDsKICAgIH0KICAgIGlmIChzZXJ2aWNlID09PSAncHdkY2hnLnBocCcpIHsKICAgICAgaWYgKCFj
aGVja0NhcHRjaGEoZ2V0KCdjJyksIGdldCgncycpKSkgcmV0dXJuICc8cHdkY2hnPjxlcnJvcj5j
b2RlPC9lcnJvcj48L3B3ZGNoZz4nOwogICAgICBjb25zdCBhY2NvdW50ID0gYnlJZCgpOwogICAg
ICBpZiAoIWFjY291bnQpIHJldHVybiAnPHB3ZGNoZz48ZXJyb3I+c2E8L2Vycm9yPjwvcHdkY2hn
Pic7CiAgICAgIGlmICghYWNjb3VudHMuY2hlY2tQYXNzd29yZChhY2NvdW50LCBnZXQoJ3B3Jykp
KSB7IGZhaWxlZFRyeShhZGRyZXNzKTsgcmV0dXJuICc8cHdkY2hnPjxlcnJvcj5wd2Q8L2Vycm9y
PjwvcHdkY2hnPic7IH0KICAgICAgYWNjb3VudHMuc2V0UGFzc3dvcmQoYWNjb3VudCwgZ2V0KCdu
cHcnKSk7CiAgICAgIHJldHVybiAnPHB3ZGNoZz48b2s+MTwvb2s+PC9wd2RjaGc+JzsKICAgIH0K
ICAgIGlmIChzZXJ2aWNlID09PSAncHdkcmV0LnBocCcpIHsKICAgICAgLy8gTm8gZS1tYWlsIGdv
ZXMgb3V0IGZyb20gaGVyZTogd2hvZXZlciBydW5zIHRoZSByZWxheSBjYW4gcmVtb3ZlIHRoZSBh
Y2NvdW50IGluc3RlYWQuCiAgICAgIHJldHVybiAnPHB3ZHJldD48ZXJyb3I+bWFpbDwvZXJyb3I+
PC9wd2RyZXQ+JzsKICAgIH0KICAgIHJldHVybiBudWxsOwogIH0KCiAgZnVuY3Rpb24gcm9vbUxp
c3RYbWwoKSB7CiAgICBsZXQgdGV4dCA9ICc8cm9vbWxpc3Q+JzsKICAgIGZvciAoY29uc3Qgcm9v
bSBvZiByb29tcykgewogICAgICB0ZXh0ICs9IGA8cm9vbT48dD4xPC90Pjxybj4ke3htbFRleHQo
cm9vbS5uYW1lKX08L3JuPjxkYz4ke3htbFRleHQocm9vbS5kZXNjcmlwdGlvbil9PC9kYz48Y2M+
JHtyb29tLmNjfTwvY2M+YAogICAgICAgICsgYDxuPiR7cm9vbS5jb25uZWN0ZWR9PC9uPjxubD4k
e3Jvb20ubGltaXR9PC9ubD48cHBsPiR7eG1sVGV4dChyb29tLnBlb3BsZSgpKX08L3BwbD5gCiAg
ICAgICAgKyBgPGlwPiR7SE9TVH08L2lwPjxwdD4ke1BPUlQgKyByb29tLm51bWJlciAtIDF9PC9w
dD48L3Jvb20+YDsKICAgIH0KICAgIHJldHVybiB0ZXh0ICsgJzwvcm9vbWxpc3Q+JzsKICB9Cgog
IC8vIFJldHVybnMgdHJ1ZSB3aGVuIHRoZSByZXF1ZXN0IHdhcyBvbmUgb2YgdGhlc2UgYW5kIGhh
cyBiZWVuIGFuc3dlcmVkIChvciBpcyBiZWluZyBhbnN3ZXJlZCkuCiAgZnVuY3Rpb24gaGFuZGxl
KHJlcSwgcmVzLCBwYXRobmFtZSkgewogICAgaWYgKCFwYXRobmFtZS5zdGFydHNXaXRoKCcvaGYv
JykpIHJldHVybiBmYWxzZTsKICAgIGNvbnN0IGhlYWRlcnMgPSB7ICdjYWNoZS1jb250cm9sJzog
J25vLXN0b3JlJywgJ3gtY29udGVudC10eXBlLW9wdGlvbnMnOiAnbm9zbmlmZicsIC4uLmFsbG93
T3JpZ2luKHJlcSkgfTsKICAgIGlmIChyZXEubWV0aG9kID09PSAnT1BUSU9OUycpIHsKICAgICAg
cmVzLndyaXRlSGVhZCgyMDQsIHsgLi4uaGVhZGVycywgJ2FjY2Vzcy1jb250cm9sLWFsbG93LW1l
dGhvZHMnOiAnR0VULCBQT1NULCBPUFRJT05TJywgJ2FjY2Vzcy1jb250cm9sLWFsbG93LWhlYWRl
cnMnOiAnY29udGVudC10eXBlJyB9KTsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm4gdHJ1
ZTsKICAgIH0KICAgIGNvbnN0IHNlbmQgPSAoc3RhdHVzLCB0eXBlLCBib2R5KSA9PiB7CiAgICAg
IHJlcy53cml0ZUhlYWQoc3RhdHVzLCB7IC4uLmhlYWRlcnMsICdjb250ZW50LXR5cGUnOiB0eXBl
IH0pOwogICAgICByZXMuZW5kKGJvZHkpOwogICAgfTsKICAgIGlmIChyZXEubWV0aG9kICE9PSAn
R0VUJyAmJiByZXEubWV0aG9kICE9PSAnUE9TVCcpIHsKICAgICAgc2VuZCg0MDUsICd0ZXh0L3Bs
YWluOyBjaGFyc2V0PXV0Zi04JywgJ21ldGhvZCBub3QgYWxsb3dlZFxuJyk7CiAgICAgIHJldHVy
biB0cnVlOwogICAgfQogICAgY29uc3QgdXJsID0gbmV3IFVSTChyZXEudXJsLCAnaHR0cDovL3Jl
bGF5LmludmFsaWQnKTsKICAgIGNvbnN0IGxvY2FsID0gcGF0aG5hbWUuc2xpY2UoJy9oZi8nLmxl
bmd0aCk7CiAgICBpZiAobG9jYWwgPT09ICd2ZXIudHh0JykgewogICAgICBzZW5kKDIwMCwgJ3Rl
eHQveG1sOyBjaGFyc2V0PXV0Zi04JywgJzx2ZXI+PHJlcyB2ZXJzaW9uPSI3MDAiIGxvY2FsPSIw
IiAvPjwvdmVyPicpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChsb2NhbCA9PT0g
J3Jvb21zLmpzb24nKSB7CiAgICAgIHNlbmQoMjAwLCAnYXBwbGljYXRpb24vanNvbjsgY2hhcnNl
dD11dGYtOCcsIEpTT04uc3RyaW5naWZ5KHsKICAgICAgICBob3N0OiBIT1NULCByb29tczogcm9v
bXMubWFwKChyb29tKSA9PiAoeyByb29tOiByb29tLm51bWJlciwgcG9ydDogUE9SVCArIHJvb20u
bnVtYmVyIC0gMSwgbmFtZTogcm9vbS5uYW1lLCBwbGF5ZXJzOiByb29tLmNvbm5lY3RlZCwgbGlt
aXQ6IHJvb20ubGltaXQgfSkpLAogICAgICB9KSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQog
ICAgaWYgKGxvY2FsID09PSAnaGYvcmxnLnBocCcpIHsKICAgICAgc2VuZCgyMDAsICd0ZXh0L3ht
bDsgY2hhcnNldD11dGYtOCcsIHJvb21MaXN0WG1sKCkpOwogICAgICByZXR1cm4gdHJ1ZTsKICAg
IH0KICAgIGlmIChsb2NhbCA9PT0gJ3MvcHJlbWl1bScpIHsKICAgICAgcmVzLnNldEhlYWRlcign
Y29udGVudC1zZWN1cml0eS1wb2xpY3knLCAiZGVmYXVsdC1zcmMgJ25vbmUnOyBzdHlsZS1zcmMg
J3Vuc2FmZS1pbmxpbmUnIik7CiAgICAgIHNlbmQoMjAwLCAndGV4dC9odG1sOyBjaGFyc2V0PXV0
Zi04JywgUFJFTUlVTV9QQUdFKTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBpZiAobG9j
YWwuc3RhcnRzV2l0aCgncy8nKSkgewogICAgICAvLyBUaGUgZ2FtZSBwb3N0cyBpdHMgZm9ybXMg
d2l0aCB0aGUgdmFsdWVzIGluIHRoZSBhZGRyZXNzOyBhIGJvZHksIGlmIGFueSwgaXMgcmVhZCBh
cyBhIGZvcm0gdG9vLgogICAgICBsZXQgYm9keSA9ICcnOwogICAgICByZXEuc2V0RW5jb2Rpbmco
J3V0ZjgnKTsKICAgICAgcmVxLm9uKCdkYXRhJywgKGNodW5rKSA9PiB7IGlmIChib2R5Lmxlbmd0
aCA8IDgxOTIpIGJvZHkgKz0gY2h1bms7IH0pOwogICAgICByZXEub24oJ2VuZCcsICgpID0+IHsK
ICAgICAgICBjb25zdCBwYXJhbXMgPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHVybC5zZWFyY2gpOwog
ICAgICAgIGlmIChib2R5ICYmIC9eW1x3JS4rPSYtXSokLy50ZXN0KGJvZHkpKSBmb3IgKGNvbnN0
IFtrZXksIHZhbHVlXSBvZiBuZXcgVVJMU2VhcmNoUGFyYW1zKGJvZHkpKSBpZiAoIXBhcmFtcy5o
YXMoa2V5KSkgcGFyYW1zLnNldChrZXksIHZhbHVlKTsKICAgICAgICBsZXQgcmVwbHk7CiAgICAg
ICAgdHJ5IHsKICAgICAgICAgIHJlcGx5ID0gYW5zd2VyKGxvY2FsLnNsaWNlKDIpLCBwYXJhbXMs
IGNsaWVudEFkZHJlc3MocmVxKSk7CiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgICAg
IGxvZyhgaGY6ICR7bG9jYWx9OiAke2Vycm9yLnN0YWNrIHx8IGVycm9yfWApOwogICAgICAgICAg
cmVwbHkgPSAnPGVycm9yPjxlcnJvcj5zZXJ2ZXI8L2Vycm9yPjwvZXJyb3I+JzsKICAgICAgICB9
CiAgICAgICAgaWYgKHJlcGx5ID09PSBudWxsKSBzZW5kKDQwNCwgJ3RleHQvcGxhaW47IGNoYXJz
ZXQ9dXRmLTgnLCAnbm90IGZvdW5kXG4nKTsKICAgICAgICBlbHNlIHNlbmQoMjAwLCAndGV4dC94
bWw7IGNoYXJzZXQ9dXRmLTgnLCByZXBseSk7CiAgICAgIH0pOwogICAgICByZXR1cm4gdHJ1ZTsK
ICAgIH0KICAgIHNlbmQoNDA0LCAndGV4dC9wbGFpbjsgY2hhcnNldD11dGYtOCcsICdub3QgZm91
bmRcbicpOwogICAgcmV0dXJuIHRydWU7CiAgfQoKICAvLyBBIGdhbWUncyBzb2NrZXQgdG8gcm9v
bSBuLCB0aHJvdWdoIHRoZSBwYWdlJ3MgV2ViU29ja2V0OiBpdHMgYnl0ZXMgYXMgYmluYXJ5IG1l
c3NhZ2VzIGJvdGggd2F5cy4gQSBwYWdlCiAgLy8gd2l0aCBkaXJlY3Q9MSAoZGlzdC9wYWdlcy9o
Zi1kaXJlY3QuanMpIGFsc28gcGFzc2VzIHRoZSBnYW1lJ3MgZnJhbWVzIHRvIHRoZSBvdGhlciBw
YWdlcyBvZiB0aGUgcm9vbQogIC8vIGRpcmVjdGx5OyBpdHMgb3duIG1lc3NhZ2VzIGZvciB0aGF0
IGFyZSB0ZXh0IChKU09OKSwgYm90aCB3YXlzLgogIGZ1bmN0aW9uIGNvbm5lY3Qod3MsIHJlcSwg
dXJsKSB7CiAgICBjb25zdCBudW1iZXIgPSBOdW1iZXIodXJsLnNlYXJjaFBhcmFtcy5nZXQoJ3Jv
b20nKSk7CiAgICBjb25zdCByb29tID0gcm9vbXNbbnVtYmVyIC0gMV07CiAgICBpZiAoIU51bWJl
ci5pc0ludGVnZXIobnVtYmVyKSB8fCAhcm9vbSkgewogICAgICB3cy5jbG9zZSg0MDAwLCAnUmVs
YXk6IG5vIHN1Y2ggSGVybyBGaWdodGVyIHJvb20nKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
Y29uc3QgZGlyZWN0ID0gdXJsLnNlYXJjaFBhcmFtcy5nZXQoJ2RpcmVjdCcpID09PSAnMSc7CiAg
ICBjb25zdCBpZCA9IGRpcmVjdCA/IGNyeXB0by5yYW5kb21CeXRlcyg2KS50b1N0cmluZygnaGV4
JykgOiAnJzsKICAgIGNvbnN0IGNvbm5lY3Rpb24gPSBuZXcgSGZDb25uZWN0aW9uKHJvb20sIHsK
ICAgICAgd3JpdGUodGV4dCkgewogICAgICAgIGlmICh3cy5yZWFkeVN0YXRlICE9PSAxKSByZXR1
cm47CiAgICAgICAgaWYgKHdzLmJ1ZmZlcmVkQW1vdW50ID4gY29uZmlnLm1heEJ1ZmZlcmVkQnl0
ZXMpIHsKICAgICAgICAgIHdzLmNsb3NlKDQwMTYsICdSZWxheTogeW91ciBjb25uZWN0aW9uIGlz
IHRvbyBzbG93IGZvciB0aGUgZ2FtZScpOwogICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAg
ICAgICB3cy5zZW5kKEJ1ZmZlci5mcm9tKHRleHQsICd1dGY4JyksIHsgYmluYXJ5OiB0cnVlIH0p
OwogICAgICB9LAogICAgICBzYXkobWVzc2FnZSkgeyBpZiAod3MucmVhZHlTdGF0ZSA9PT0gMSkg
d3Muc2VuZChKU09OLnN0cmluZ2lmeShtZXNzYWdlKSk7IH0sCiAgICAgIGNsb3NlKCkgeyBpZiAo
d3MucmVhZHlTdGF0ZSA9PT0gMCB8fCB3cy5yZWFkeVN0YXRlID09PSAxKSB3cy5jbG9zZSgxMDAw
LCAnUmVsYXk6IHJvb20gbGVmdCcpOyB9LAogICAgfSwgeyBhZGRyZXNzOiBjbGllbnRBZGRyZXNz
KHJlcSksIGJ1aWxkOiBTdHJpbmcodXJsLnNlYXJjaFBhcmFtcy5nZXQoJ2J1aWxkJykgfHwgJycp
LnJlcGxhY2UoL1teXHcuKy1dL2csICcnKS5zbGljZSgwLCA4MCksIGlkLCBkaXJlY3QgfSk7CiAg
ICBpZiAoZGlyZWN0KSB3cy5zZW5kKEpTT04uc3RyaW5naWZ5KHsgdDogJ2hlbGxvJywgdjogMSwg
aWQgfSkpOwogICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSwgaXNCaW5hcnkpID0+IHsKICAgICAg
aWYgKGJ1ZGdldCAmJiAhYnVkZ2V0KHdzLCBkYXRhLmxlbmd0aCkpIHsKICAgICAgICB3cy5jbG9z
ZSg0MDA3LCAnUmVsYXk6IHRvbyBtdWNoIHRyYWZmaWMnKTsKICAgICAgICByZXR1cm47CiAgICAg
IH0KICAgICAgY29uc3QgYnl0ZXMgPSBCdWZmZXIuaXNCdWZmZXIoZGF0YSkgPyBkYXRhIDogQnVm
ZmVyLmZyb20oZGF0YSk7CiAgICAgIGlmIChkaXJlY3QgJiYgaXNCaW5hcnkgPT09IGZhbHNlKSBj
b25uZWN0aW9uLmNvbnRyb2woYnl0ZXMudG9TdHJpbmcoJ3V0ZjgnKSk7CiAgICAgIGVsc2UgY29u
bmVjdGlvbi5yZWNlaXZlKGJ5dGVzKTsKICAgIH0pOwogICAgd3Mub24oJ2Nsb3NlJywgKCkgPT4g
Y29ubmVjdGlvbi5jbG9zZWQoKSk7CiAgfQoKICByZXR1cm4gewogICAgaGFuZGxlLAogICAgY29u
bmVjdCwKICAgIHJvb21zLAogICAgYWNjb3VudHMsCiAgICBkZXNjcmliZTogKCkgPT4gKHsgcm9v
bXM6IHJvb21zLmxlbmd0aCwgcGxheWVyczogcm9vbXMucmVkdWNlKChzdW0sIHJvb20pID0+IHN1
bSArIHJvb20uY29ubmVjdGVkLCAwKSB9KSwKICAgIC8vIFRoZSByb29tcycgam91cm5hbHMgKGpv
aW5zLCBmaWdodHMsIHBhdXNlcywgb3V0LW9mLXN0ZXAgZHVtcHMpLCBuZXdlc3Qgcm9vbSBlbnRy
aWVzIGxhc3QsIGFzIHRleHQuCiAgICBqb3VybmFsOiAoKSA9PiByb29tcy5tYXAoKHJvb20pID0+
IGA9PSAke3Jvb20ubmFtZX0gKCR7cm9vbS5jb25uZWN0ZWR9IHBsYXlpbmcpXG4ke3Jvb20uam91
cm5hbC5qb2luKCdcbicpIHx8ICcobm90aGluZyB5ZXQpJ31gKS5qb2luKCdcblxuJykgKyAnXG4n
LAogICAgY2xvc2UoKSB7CiAgICAgIGNsZWFySW50ZXJ2YWwocHJ1bmVUaW1lcik7CiAgICAgIGZv
ciAoY29uc3Qgcm9vbSBvZiByb29tcykgcm9vbS5jbG9zZSgpOwogICAgICBhY2NvdW50cy5mbHVz
aCgpOwogICAgfSwKICB9Owp9CgovLyBUaGUgYWRkcmVzcyB0aGUgZ2FtZSBpcyBnaXZlbiBmb3Ig
dGhlIHJvb21zOiBhbnkgbmFtZSB3b3JrcywgdGhlIHBhZ2UncyBzb2NrZXQgcHJveHkgbWFwcyBp
dCAod2l0aAovLyB0aGUgcG9ydCwgb25lIHBlciByb29tKSB0byB0aGUgcmVsYXkncyBXZWJTb2Nr
ZXQuCmNvbnN0IEhPU1QgPSAnaGYub3BlbmxmMic7CmNvbnN0IFBPUlQgPSA4ODg4OwoKbW9kdWxl
LmV4cG9ydHMgPSB7IGNyZWF0ZUhmLCBzdGF0dXNDb2RlLCBlbmNvZGVOdW1iZXIsIHNldHRsZWRW
YWx1ZXMsIExPQ0tFRCwgWUFHQSwgSE9TVCwgUE9SVCB9Owo=
LF2_PAYLOAD
}
write_hf_room_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IE1JVAovLwovLyBIZXJvIEZpZ2h0ZXIgdjAuNysg
bmV0d29yayByb29tcyBmb3IgdGhlIHJlbGF5OiBhIHJld3JpdGUgb2YgIlJvb20gU2VydmVyIHYw
LjcrIiAodGhlIEphdmEgcm9vbQovLyBzZXJ2ZXIgdGhhdCBIZXJvIEZpZ2h0ZXIncyBwbGF5ZXJz
IHJ1biwgTWFuZ2FEJ3MgdXBkYXRlIG9mIHRoZSBvcmlnaW5hbCBieSBNYXJ0aWFsIFN0dWRpbykg
dGhhdAovLyBzcGVha3MgdGhlIHNhbWUgcHJvdG9jb2wsIHdpdGggdGhlIHNhbWUgcnVsZXMgYW5k
IHRpbWluZywgc28gdGhhdCB0aGUgZ2FtZSBjYW5ub3QgdGVsbCBpdCBhcGFydC4KLy8gVGhlIHdl
YiBwYWdlIHJ1bnMgdGhlIGdhbWUgKGEgRmxhc2ggcHJvZ3JhbSkgaW4gUnVmZmxlLCB3aG9zZSBz
b2NrZXRzIHJlYWNoIHRoZSByZWxheSBhcwovLyBXZWJTb2NrZXRzOiBlYWNoIFdlYlNvY2tldCBt
ZXNzYWdlIGNhcnJpZXMgYnl0ZXMgb2Ygd2hhdCB3b3VsZCBiZSB0aGUgVENQIHN0cmVhbS4KLy8K
Ly8gVGhlIHByb3RvY29sOiBvbmUgWE1MIGVsZW1lbnQgcGVyIGxpbmUsIGJvdGggd2F5cyAoVVRG
LTgsICJcbiIgYWZ0ZXIgZWFjaCkuIFRoZSBzZXJ2ZXIgZ3JlZXRzCi8vIHdpdGggPGluaS8+LCB0
aGUgZ2FtZSBhbnN3ZXJzIDxqb2luPjx2ZXI+NzAwPC92ZXI+PC9qb2luPiwgdGhlIHNlcnZlciBt
ZWFzdXJlcyB0aGUgbGF0ZW5jeSB3aXRoCi8vIHRlbiA8cGluZy8+cywgc2VuZHMgdGhlIHJhbmRv
bSB0YWJsZSBldmVyeSBnYW1lIGluIHRoZSByb29tIHVzZXMgKDEwIHggNTAwIG51bWJlcnMpIGFu
ZCBhc2tzIGZvcgovLyA8aW5mbz4gKGNvbXB1dGVyIG5hbWUsIDMgcGxheWVyIG5hbWVzLCB0aGUg
YWNjb3VudCdzIGNoYXJhY3RlciBsZXZlbHMpLiBUaGVuIHRoZSB3YWl0aW5nIHJvb206Ci8vIGNo
YXQsIHRoZSBtb2RlIGJ1dHRvbnMgd2l0aCBhIDMtc2Vjb25kIGNvdW50ZG93biBldmVyeW9uZSBz
ZWVzLCB0aGUgY2hhcmFjdGVyIG1lbnUgKDI0IG1lbjogMyBwZXIKLy8gY29tcHV0ZXIsIHRoZW4g
Y29tcHV0ZXIgcGxheWVycyBhbmQgc29sZGllcnMpLCB0aGUgZ2FtZSBzZXR0aW5ncy4gSW4gYSBm
aWdodCBldmVyeSBnYW1lIHNlbmRzIGl0cwovLyBrZXlzIGZyYW1lIGJ5IGZyYW1lICg8Zj4sIHR3
byBmcmFtZXMgdGhlbiA8cGsvPik7IHRoZSBzZXJ2ZXIgcGFzc2VzIGVhY2ggZ2FtZSB0aGUgZnJh
bWVzIG9mIHRoZQovLyBvdGhlcnMsIGluIG9yZGVyLCBhcyBzb29uIGFzIGFsbCBvZiB0aGVtIGhh
dmUgc2VudCBhIGZyYW1lIChsb2Nrc3RlcCkuCi8vCi8vIE5hbWVzIGluIGNvbW1lbnRzIGxpa2Ug
Ik1haW4uYWwiIGFyZSB0aGUgb3JpZ2luYWwncyAob2JmdXNjYXRlZCkgb25lcywgdG8gY29tcGFy
ZSB3aXRoIGl0LgondXNlIHN0cmljdCc7Cgpjb25zdCBWRVJTSU9OID0gNzAwOyAvLyBNYWluLmYK
Y29uc3QgTUFYX0xFVkVMID0gMTY7IC8vIE1haW4uZTogaGlnaGVyIGxldmVscyBhcmUgYSBjaGVh
dCAodGhlIGdhbWUgaXMgc2h1dCBvdXQpCmNvbnN0IFNURVAgPSAyOyAvLyBNYWluLmM6IGZyYW1l
cyBwZXIgcGFja2V0LCB0aGUgdW5pdCBvZiBsYXRlbmN5CmNvbnN0IENMSUVOVFMgPSA0OyAvLyBN
YWluLk46IGNvbXB1dGVycyBpbiBhIHJvb20KY29uc3QgU0xPVFMgPSBDTElFTlRTICsgMjsgLy8g
TWFpbi5QOiB0aGUgcm9vbSBsaXN0IGhhcyB0d28gbW9yZSBsaW5lczogdGhlIHJvb20ncyBob3N0
IGFuZCB0aGUgc2VydmVyCmNvbnN0IEhPU1RfU0xPVCA9IFNMT1RTIC0gMjsgLy8gTWFpbi5SCmNv
bnN0IFNFUlZFUl9TTE9UID0gU0xPVFMgLSAxOyAvLyBNYWluLlE6IGNoYXQgbGluZXMgZnJvbSB0
aGUgc2VydmVyCmNvbnN0IE1FTiA9IENMSUVOVFMgKiAzICsgMTI7IC8vIE1haW4uYVc6IDMgcGxh
eWVycyBwZXIgY29tcHV0ZXIsIHRoZW4gY29tcHV0ZXIgcGxheWVycyBhbmQgc29sZGllcnMKY29u
c3QgQ09VTlRET1dOID0gNjsgLy8gVC5jOiBoYWxmIHNlY29uZHMgZnJvbSBhIGNsaWNrIHRvIHRo
ZSBwYWdlIGNoYW5nZQpjb25zdCBGUkFNRVNfS0VQVCA9IDUwMDsgLy8gUi5yOiBmcmFtZXMgZWFj
aCBjb21wdXRlcidzIGFyZSBrZXB0LCBieSBmcmFtZSBudW1iZXIgbW9kdWxvIHRoaXMKCmNvbnN0
IENIQVJBQ1RFUlMgPSBbJ2x1Y2FzJywgJ2RyZXcnLCAnc2hhd24nLCAnamVubnknLCAndGF5bG9y
JywgJ2xlbycsICdsZWdnZScsICdlYXNvbicsICd5YWdhJywgJ2phc29uJywgJ2dvcmRvbicsCiAg
J2dpZ2dzJywgJ3RpdHRvJywgJ3NpbmFuJywgJ2ljenp5JywgJ2hlYXRlcicsICdyYXllJywgJ3Zp
dmlhbicsICdsaXZlcm1vcmUnLCAnZWFzb24wJ107IC8vIE1haW4uYUgsIGkuYwpjb25zdCBCQUNL
R1JPVU5EUyA9IFsnaGlsbF9kcnknLCAnZm9yZXN0X211ZCcsICd0ZW1wbGUnLCAndmlsbGFnZScs
ICd0cmVlc19ncmFzcycsICdyb29tMScsICdyb2NrX2RyeScsICd2aWxsYWdlMicsCiAgJ3N0b3J5
MDEnLCAnc3RvcnkwMmEnLCAnc3RvcnkwMmMnLCAnc3RvcnkwMmInLCAnc3RvcnkwM2EnLCAnc3Rv
cnkwNGInLCAnc3RvcnkwM2InLCAnc3RvcnkwM2IyJywgJ3N0b3J5MDRhJywKICAnc3RvcnkwM2Mn
LCAnc3RvcnkwNWEnLCAnc3RvcnkwNWFfZHJhbWEnLCAnc3RvcnkwNWJfZHJhbWEnLCAnc3Rvcnkw
NmIyJywgJ3ByaXNvbl9kcmFtYScsICdwcmlzb24yJywgJ3N0b3J5MDZhJywKICAnc3RvcnkwNmMn
LCAnc3RvcnkwNmQnLCAnc3RvcnkwNmQyJywgJ3N0b3J5MDdhJywgJ3N0b3J5MDdjJywgJ2Rlc2Vy
dCcsICdzdG9yeTA3YicsICdzdG9yeTA3ZCcsICdoaWxsX211ZCcsCiAgJ3RyZWVzX211ZCcsICdo
aWxsX2dyYXNzJywgJ2ZvcmVzdF9ncmFzcycsICdzdG9yeTA0YycsICdwcmlzb24nLCAnc3Rvcnkw
M2QnLCAnc3RvcnkwNWInLCAnc3RvcnkwNmInLCAndHJlZXNfZHJ5JywKICAnaGlsbF9kcnkyJywg
J2Zsb29yX2RyeScsICdmbG9vcl9waWxsYXInLCAnY2FzdGxlX2Zsb29yMicsICd0ZW1wbGVfZG9v
cicsICd0ZW1wbGVfZW5kJywgJ09MRF92aWxsYWdlMicsCiAgJ3ZpbGxhZ2VUZXN0JywgJ2Rlc2Vy
dG5pZ2h0JywgJ3N0b3J5MDdiMicsICdiYXR0bGUyJywgJ2JhdHRsZTMnLCAnYmF0dGxlNCcsICdi
YXR0bGUydGVhbScsICdiYXR0bGUyb2xkJywKICAnYmF0dGxlM29sZCddOyAvLyBNYWluLmF4CmNv
bnN0IE1VU0lDID0gWycwMS5tcDMnLCAnMDIubXAzJywgJzAzLm1wMycsICcwNC5tcDMnLCAnMDUu
bXAzJywgJzA2Lm1wMycsICcwNy5tcDMnLCAnMDgubXAzJywgJzA5Lm1wMycsICcxMC5tcDMnLAog
ICcxMS5tcDMnLCAnMTIubXAzJywgJzEzLm1wMyddOyAvLyBNYWluLmFYCgovLyAtLS0tIFhNTCwg
YXMgbXVjaCBhcyB0aGUgZ2FtZSdzIG1lc3NhZ2VzIG5lZWQgLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQovLyBUaGUgb3JpZ2luYWwgcGFyc2VzIGVh
Y2ggbGluZSB3aXRoIGEgRE9NIHBhcnNlciBhbmQgcmVhZHMgdmFsdWVzIGFzIGdldEVsZW1lbnRz
QnlUYWdOYW1lKG5hbWUpCi8vIC5pdGVtKGspLmdldENoaWxkTm9kZXMoKS5pdGVtKDApLmdldE5v
ZGVWYWx1ZSgpOiB0aGUgZmlyc3QgY2hpbGQgbm9kZSAodGV4dCBvciBDREFUQSkgb2YgYW4gZWxl
bWVudC4KLy8gQW55dGhpbmcgaXQgY291bGQgbm90IHBhcnNlIGVuZGVkIHRoZSBjb25uZWN0aW9u
OyBzbyBkb2VzIGFuIFhtbEVycm9yIGhlcmUuCgpjbGFzcyBYbWxFcnJvciBleHRlbmRzIEVycm9y
IHt9Cgpjb25zdCBFTlRJVElFUyA9IHsgbHQ6ICc8JywgZ3Q6ICc+JywgYW1wOiAnJicsIHF1b3Q6
ICciJywgYXBvczogIiciIH07CgpmdW5jdGlvbiBkZWNvZGVFbnRpdGllcyhyYXcpIHsKICByZXR1
cm4gcmF3LnJlcGxhY2UoLyYoI3hbMC05YS1mQS1GXSt8I1swLTldK3xbQS1aYS16XSspO3wmL2cs
IChtYXRjaCwgZW50aXR5KSA9PiB7CiAgICBpZiAoIWVudGl0eSkgdGhyb3cgbmV3IFhtbEVycm9y
KCdiYXJlICYnKTsKICAgIGlmIChlbnRpdHlbMF0gPT09ICcjJykgewogICAgICBjb25zdCBjb2Rl
ID0gZW50aXR5WzFdID09PSAneCcgPyBwYXJzZUludChlbnRpdHkuc2xpY2UoMiksIDE2KSA6IHBh
cnNlSW50KGVudGl0eS5zbGljZSgxKSwgMTApOwogICAgICBpZiAoIShjb2RlID4gMCAmJiBjb2Rl
IDw9IDB4MTBmZmZmKSkgdGhyb3cgbmV3IFhtbEVycm9yKCdiYWQgY2hhcmFjdGVyIHJlZmVyZW5j
ZScpOwogICAgICByZXR1cm4gU3RyaW5nLmZyb21Db2RlUG9pbnQoY29kZSk7CiAgICB9CiAgICBp
ZiAoIShlbnRpdHkgaW4gRU5USVRJRVMpKSB0aHJvdyBuZXcgWG1sRXJyb3IoYHVua25vd24gZW50
aXR5ICR7ZW50aXR5fWApOwogICAgcmV0dXJuIEVOVElUSUVTW2VudGl0eV07CiAgfSk7Cn0KCmNv
bnN0IE5BTUUgPSAvW0EtWmEtel86XVstQS1aYS16MC05XzouXSoveTsKCmZ1bmN0aW9uIHBhcnNl
WG1sKHRleHQpIHsKICBsZXQgYXQgPSAwOwogIGNvbnN0IHNraXBNaXNjID0gKCkgPT4gewogICAg
Zm9yICg7OykgewogICAgICB3aGlsZSAoYXQgPCB0ZXh0Lmxlbmd0aCAmJiAvXHMvLnRlc3QodGV4
dFthdF0pKSBhdCArPSAxOwogICAgICBpZiAodGV4dC5zdGFydHNXaXRoKCc8PycsIGF0KSkgewog
ICAgICAgIGNvbnN0IGVuZCA9IHRleHQuaW5kZXhPZignPz4nLCBhdCArIDIpOwogICAgICAgIGlm
IChlbmQgPCAwKSB0aHJvdyBuZXcgWG1sRXJyb3IoJ3VuY2xvc2VkIGRlY2xhcmF0aW9uJyk7CiAg
ICAgICAgYXQgPSBlbmQgKyAyOwogICAgICB9IGVsc2UgaWYgKHRleHQuc3RhcnRzV2l0aCgnPCEt
LScsIGF0KSkgewogICAgICAgIGNvbnN0IGVuZCA9IHRleHQuaW5kZXhPZignLS0+JywgYXQgKyA0
KTsKICAgICAgICBpZiAoZW5kIDwgMCkgdGhyb3cgbmV3IFhtbEVycm9yKCd1bmNsb3NlZCBjb21t
ZW50Jyk7CiAgICAgICAgYXQgPSBlbmQgKyAzOwogICAgICB9IGVsc2UgcmV0dXJuOwogICAgfQog
IH07CiAgY29uc3QgcmVhZE5hbWUgPSAoKSA9PiB7CiAgICBOQU1FLmxhc3RJbmRleCA9IGF0Owog
ICAgY29uc3QgbWF0Y2ggPSBOQU1FLmV4ZWModGV4dCk7CiAgICBpZiAoIW1hdGNoKSB0aHJvdyBu
ZXcgWG1sRXJyb3IoJ25hbWUgZXhwZWN0ZWQnKTsKICAgIGF0ICs9IG1hdGNoWzBdLmxlbmd0aDsK
ICAgIHJldHVybiBtYXRjaFswXTsKICB9OwogIGNvbnN0IGVsZW1lbnQgPSAoKSA9PiB7CiAgICBp
ZiAodGV4dFthdF0gIT09ICc8JykgdGhyb3cgbmV3IFhtbEVycm9yKCdlbGVtZW50IGV4cGVjdGVk
Jyk7CiAgICBhdCArPSAxOwogICAgY29uc3Qgbm9kZSA9IHsgbmFtZTogcmVhZE5hbWUoKSwgYXR0
cmlidXRlczoge30sIGNoaWxkcmVuOiBbXSB9OwogICAgZm9yICg7OykgewogICAgICBjb25zdCBi
ZWZvcmUgPSBhdDsKICAgICAgd2hpbGUgKGF0IDwgdGV4dC5sZW5ndGggJiYgL1xzLy50ZXN0KHRl
eHRbYXRdKSkgYXQgKz0gMTsKICAgICAgaWYgKHRleHQuc3RhcnRzV2l0aCgnLz4nLCBhdCkpIHsg
YXQgKz0gMjsgcmV0dXJuIG5vZGU7IH0KICAgICAgaWYgKHRleHRbYXRdID09PSAnPicpIHsgYXQg
Kz0gMTsgYnJlYWs7IH0KICAgICAgaWYgKGF0ID09PSBiZWZvcmUpIHRocm93IG5ldyBYbWxFcnJv
cignc3BhY2UgZXhwZWN0ZWQnKTsKICAgICAgY29uc3QgbmFtZSA9IHJlYWROYW1lKCk7CiAgICAg
IHdoaWxlICgvXHMvLnRlc3QodGV4dFthdF0gfHwgJycpKSBhdCArPSAxOwogICAgICBpZiAodGV4
dFthdF0gIT09ICc9JykgdGhyb3cgbmV3IFhtbEVycm9yKCc9IGV4cGVjdGVkJyk7CiAgICAgIGF0
ICs9IDE7CiAgICAgIHdoaWxlICgvXHMvLnRlc3QodGV4dFthdF0gfHwgJycpKSBhdCArPSAxOwog
ICAgICBjb25zdCBxdW90ZSA9IHRleHRbYXRdOwogICAgICBpZiAocXVvdGUgIT09ICciJyAmJiBx
dW90ZSAhPT0gIiciKSB0aHJvdyBuZXcgWG1sRXJyb3IoJ3F1b3RlIGV4cGVjdGVkJyk7CiAgICAg
IGNvbnN0IGVuZCA9IHRleHQuaW5kZXhPZihxdW90ZSwgYXQgKyAxKTsKICAgICAgaWYgKGVuZCA8
IDApIHRocm93IG5ldyBYbWxFcnJvcigndW5jbG9zZWQgYXR0cmlidXRlJyk7CiAgICAgIG5vZGUu
YXR0cmlidXRlc1tuYW1lXSA9IGRlY29kZUVudGl0aWVzKHRleHQuc2xpY2UoYXQgKyAxLCBlbmQp
KTsKICAgICAgYXQgPSBlbmQgKyAxOwogICAgfQogICAgbGV0IHBlbmRpbmcgPSBudWxsOyAvLyBh
ZGphY2VudCBjaGFyYWN0ZXIgZGF0YSBpcyBvbmUgdGV4dCBub2RlCiAgICBjb25zdCBmbHVzaCA9
ICgpID0+IHsgaWYgKHBlbmRpbmcgIT09IG51bGwpIG5vZGUuY2hpbGRyZW4ucHVzaCh7IHRleHQ6
IHBlbmRpbmcgfSk7IHBlbmRpbmcgPSBudWxsOyB9OwogICAgZm9yICg7OykgewogICAgICBpZiAo
YXQgPj0gdGV4dC5sZW5ndGgpIHRocm93IG5ldyBYbWxFcnJvcihgdW5jbG9zZWQgPCR7bm9kZS5u
YW1lfT5gKTsKICAgICAgaWYgKHRleHQuc3RhcnRzV2l0aCgnPC8nLCBhdCkpIHsKICAgICAgICBh
dCArPSAyOwogICAgICAgIGlmIChyZWFkTmFtZSgpICE9PSBub2RlLm5hbWUpIHRocm93IG5ldyBY
bWxFcnJvcihgbWlzbWF0Y2hlZCA8LyR7bm9kZS5uYW1lfT5gKTsKICAgICAgICB3aGlsZSAoL1xz
Ly50ZXN0KHRleHRbYXRdIHx8ICcnKSkgYXQgKz0gMTsKICAgICAgICBpZiAodGV4dFthdF0gIT09
ICc+JykgdGhyb3cgbmV3IFhtbEVycm9yKCc+IGV4cGVjdGVkJyk7CiAgICAgICAgYXQgKz0gMTsK
ICAgICAgICBmbHVzaCgpOwogICAgICAgIHJldHVybiBub2RlOwogICAgICB9CiAgICAgIGlmICh0
ZXh0LnN0YXJ0c1dpdGgoJzwhW0NEQVRBWycsIGF0KSkgewogICAgICAgIGNvbnN0IGVuZCA9IHRl
eHQuaW5kZXhPZignXV0+JywgYXQgKyA5KTsKICAgICAgICBpZiAoZW5kIDwgMCkgdGhyb3cgbmV3
IFhtbEVycm9yKCd1bmNsb3NlZCBDREFUQScpOwogICAgICAgIGZsdXNoKCk7CiAgICAgICAgbm9k
ZS5jaGlsZHJlbi5wdXNoKHsgdGV4dDogdGV4dC5zbGljZShhdCArIDksIGVuZCksIGNkYXRhOiB0
cnVlIH0pOwogICAgICAgIGF0ID0gZW5kICsgMzsKICAgICAgfSBlbHNlIGlmICh0ZXh0LnN0YXJ0
c1dpdGgoJzwhLS0nLCBhdCkpIHsKICAgICAgICBjb25zdCBlbmQgPSB0ZXh0LmluZGV4T2YoJy0t
PicsIGF0ICsgNCk7CiAgICAgICAgaWYgKGVuZCA8IDApIHRocm93IG5ldyBYbWxFcnJvcigndW5j
bG9zZWQgY29tbWVudCcpOwogICAgICAgIGZsdXNoKCk7CiAgICAgICAgYXQgPSBlbmQgKyAzOwog
ICAgICB9IGVsc2UgaWYgKHRleHRbYXRdID09PSAnPCcpIHsKICAgICAgICBmbHVzaCgpOwogICAg
ICAgIG5vZGUuY2hpbGRyZW4ucHVzaChlbGVtZW50KCkpOwogICAgICB9IGVsc2UgewogICAgICAg
IGNvbnN0IGVuZCA9IHRleHQuaW5kZXhPZignPCcsIGF0KTsKICAgICAgICBjb25zdCByYXcgPSB0
ZXh0LnNsaWNlKGF0LCBlbmQgPCAwID8gdGV4dC5sZW5ndGggOiBlbmQpOwogICAgICAgIHBlbmRp
bmcgPSAocGVuZGluZyB8fCAnJykgKyBkZWNvZGVFbnRpdGllcyhyYXcpOwogICAgICAgIGF0ICs9
IHJhdy5sZW5ndGg7CiAgICAgIH0KICAgIH0KICB9OwogIHNraXBNaXNjKCk7CiAgY29uc3Qgcm9v
dCA9IGVsZW1lbnQoKTsKICBza2lwTWlzYygpOwogIGlmIChhdCAhPT0gdGV4dC5sZW5ndGgpIHRo
cm93IG5ldyBYbWxFcnJvcignY29udGVudCBhZnRlciB0aGUgcm9vdCBlbGVtZW50Jyk7CiAgcmV0
dXJuIHJvb3Q7Cn0KCi8vIGdldEVsZW1lbnRzQnlUYWdOYW1lOiB0aGUgZWxlbWVudCBpdHNlbGYg
YW5kIGl0cyBkZXNjZW5kYW50cywgaW4gZG9jdW1lbnQgb3JkZXIuCmZ1bmN0aW9uIGJ5VGFnKG5v
ZGUsIG5hbWUsIGZvdW5kID0gW10pIHsKICBpZiAobm9kZS5uYW1lID09PSBuYW1lKSBmb3VuZC5w
dXNoKG5vZGUpOwogIGZvciAoY29uc3QgY2hpbGQgb2Ygbm9kZS5jaGlsZHJlbikgaWYgKGNoaWxk
Lm5hbWUpIGJ5VGFnKGNoaWxkLCBuYW1lLCBmb3VuZCk7CiAgcmV0dXJuIGZvdW5kOwp9CgovLyBU
aGUgdmFsdWUgb2YgYW4gZWxlbWVudCdzIGZpcnN0IGNoaWxkIG5vZGUgKG51bGwgZm9yIGFuIGVs
ZW1lbnQgY2hpbGQsIGFzIGluIHRoZSBET00pLgpmdW5jdGlvbiB2YWx1ZU9mKG5vZGUpIHsKICBp
ZiAoIW5vZGUpIHRocm93IG5ldyBYbWxFcnJvcignZWxlbWVudCBtaXNzaW5nJyk7CiAgY29uc3Qg
Zmlyc3QgPSBub2RlLmNoaWxkcmVuWzBdOwogIGlmICghZmlyc3QpIHRocm93IG5ldyBYbWxFcnJv
cihgPCR7bm9kZS5uYW1lfT4gaXMgZW1wdHlgKTsKICByZXR1cm4gZmlyc3QubmFtZSA/IG51bGwg
OiBmaXJzdC50ZXh0Owp9CgovLyBJbnRlZ2VyLnBhcnNlSW50LgpmdW5jdGlvbiBpbnQodGV4dCkg
ewogIGlmICh0eXBlb2YgdGV4dCAhPT0gJ3N0cmluZycgfHwgIS9eWy0rXT9cZCskLy50ZXN0KHRl
eHQpKSB0aHJvdyBuZXcgWG1sRXJyb3IoYG5vdCBhIG51bWJlcjogJHt0ZXh0fWApOwogIGNvbnN0
IHZhbHVlID0gTnVtYmVyKHRleHQpOwogIGlmICh2YWx1ZSA+IDIxNDc0ODM2NDcgfHwgdmFsdWUg
PCAtMjE0NzQ4MzY0OCkgdGhyb3cgbmV3IFhtbEVycm9yKCdudW1iZXIgb3V0IG9mIHJhbmdlJyk7
CiAgcmV0dXJuIHZhbHVlOwp9CgpmdW5jdGlvbiB0YWdWYWx1ZShkb2MsIG5hbWUsIGluZGV4ID0g
MCkgewogIHJldHVybiB2YWx1ZU9mKGJ5VGFnKGRvYywgbmFtZSlbaW5kZXhdKTsKfQoKLy8gLS0t
LSBGcmFtZXMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCi8vIEEgZnJhbWUgb2Yg
YSBnYW1lJ3Mga2V5czogPGY+PGM+Y29tcHV0ZXI8L2M+PGk+ZnJhbWU8L2k+IGFuZCwgcGVyIHBs
YXllciBuICgxIHRvIDMpLCBpdHMga2V5cyAoPHBuPiwgPHNuPikKLy8gYW5kIGEgdHJvb3AgY29t
bWFuZCAoPG1uPiB3aGF0LCA8bm4+IHdoaWNoIGhlcm8gdG8gaGlyZSwgPGluPiB3aGljaCB0cm9v
cCkuIFRoZSBnYW1lIHJlYWRzIHRoZSBmcmFtZXMgb2YKLy8gdGhlIG90aGVycyB3aXRoIGEgc2xp
cCAoQ29uc29sZS5yZWNlaXZlRGF0YSk6IHBsYXllciAyJ3MgaGlyZSBudW1iZXIgZnJvbSA8bjE+
LCBub3QgPG4yPi4gQSBjb21wdXRlcidzCi8vIHRyb29wIHBhbmVsIGNvbW1hbmRzIGZvciBpdHMg
Zmlyc3QgcGxheWVyIG9ubHksIHNvIGEgZnJhbWUgaGFzIG9uZSBjb21tYW5kIGF0IG1vc3Q7IGJ1
dCB3aGVuIHRoYXQKLy8gcGxheWVyIGlzIHBsYXllciAyIChhIGNvbXB1dGVyIHdpdGggbm8gcGxh
eWVyIDEsIGFzIHdpdGggVyBBIFMgRCksIGV2ZXJ5IG90aGVyIGdhbWUgaGlyZWQgdGhlIGZpcnN0
Ci8vIGhlcm8gb24gdGhlIGxpc3QgaW5zdGVhZCBvZiB0aGUgb25lIGNob3NlbiwgYW5kIHRoZSBm
aWdodCB3ZW50IG91dCBvZiBzdGVwICgiQmF0dGxlIiwgT1VUIE9GIFNURVAgaW4KLy8gdGhlIGpv
dXJuYWwpLiBTbyBwbGF5ZXIgMidzIG51bWJlciBnb2VzIGluIDxuMT4gdG9vLCB3aGljaCB0aGUg
Z2FtZSB0aGVuIHJlYWRzLiAoZGlzdC9wYWdlcy9oZi1kaXJlY3QuanMKLy8gZG9lcyB0aGUgc2Ft
ZSBmb3IgdGhlIGZyYW1lcyB0aGUgcGFnZXMgcGFzcyBlYWNoIG90aGVyIGRpcmVjdGx5LikKZnVu
Y3Rpb24gZml4Q29tbWFuZE51bWJlcihsaW5lKSB7CiAgaWYgKGxpbmUuaW5kZXhPZignPG0yPicp
IDwgMCB8fCBsaW5lLmluZGV4T2YoJzxuMT4nKSA+PSAwKSByZXR1cm4gbGluZTsKICBjb25zdCBu
dW1iZXIgPSAvPG4yPihbXjxdKik8XC9uMj4vLmV4ZWMobGluZSk7CiAgY29uc3QgZW5kID0gbGlu
ZS5sYXN0SW5kZXhPZignPC9mPicpOwogIGlmICghbnVtYmVyIHx8IGVuZCA8IDApIHJldHVybiBs
aW5lOwogIHJldHVybiBgJHtsaW5lLnNsaWNlKDAsIGVuZCl9PG4xPiR7bnVtYmVyWzFdfTwvbjE+
JHtsaW5lLnNsaWNlKGVuZCl9YDsKfQoKLy8gLS0tLSBBIHJvb20gLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tCgpmdW5jdGlvbiBuZXdNYW4oKSB7IC8vIGFzCiAgcmV0dXJuIHsgY2xp
ZW50OiAtMSwgY29udHJvbGxlcjogLTEsIHRlYW06IDAsIGxldmVsOiAxLCBjaGFyOiAnJywgcmFu
ZG9tOiB0cnVlLCBleGlzdHM6IGZhbHNlLCBjb21tYW5kZXI6IC0xIH07Cn0KCmZ1bmN0aW9uIG5l
d1Nsb3QoKSB7IC8vIFIKICBjb25zdCBsZXZlbHMgPSBuZXcgQXJyYXkoMzApLmZpbGwoMCk7CiAg
bGV2ZWxzWzBdID0gbGV2ZWxzWzFdID0gbGV2ZWxzWzJdID0gMTsKICByZXR1cm4gewogICAgbmFt
ZTogJycsIHBsYXllcnM6IFsnJywgJycsICcnXSwgbGV2ZWxzLCBjYzogJycsIGNvdW50cnk6ICcn
LCBvbmxpbmU6IGZhbHNlLCBoYXNQbGF5ZXI6IGZhbHNlLCBwYXVzZWQ6IGZhbHNlLAogICAgY29u
bmVjdGlvbjogbnVsbCwgcGFnZTogJ1dBSVRST09NJywgZmlnaHRpbmc6IGZhbHNlLCBsYXRlbmN5
OiAwLCBsYXRlbmN5U2hvd246IDAsIGxhdGVuY3lUYXJnZXQ6IDAsCiAgICBzdGFydGVkOiBmYWxz
ZSwgbGFzdFBhY2tldDogLTEsIGxlZnRGcmFtZTogLTEsIGZyYW1lczogbmV3IEFycmF5KEZSQU1F
U19LRVBUKSwgbGFzdE1lc3NhZ2U6IDAsIGxhc3RBY3RpdmU6IDAsCiAgICBzdGVwczogW10sIHRp
bWVzOiBbXSwgLy8gd2hhdCB0aGlzIGdhbWUgcmVwb3J0ZWQgbGF0ZWx5OiBbZnJhbWUsIHJhbmRv
bSBudW1iZXJzIHVzZWRdIGV2ZXJ5IDIwIGZyYW1lcywgYW5kIGl0cyA8dD4gdmFsdWVzCiAgICBh
ZG1pbjogZmFsc2UsIGZsdXNoZXM6IDAsCiAgfTsKfQoKY29uc3Qgc2xlZXAgPSAobXMpID0+IG5l
dyBQcm9taXNlKChyZXNvbHZlKSA9PiBzZXRUaW1lb3V0KHJlc29sdmUsIG1zKSk7CgpjbGFzcyBI
ZlJvb20gewogIGNvbnN0cnVjdG9yKHsgbnVtYmVyLCBuYW1lLCBkZXNjcmlwdGlvbiA9ICcnLCBj
YyA9ICdWTicsIGxpbWl0ID0gQ0xJRU5UUywgcmFuZG9tID0gTWF0aC5yYW5kb20sIGxvZyA9ICgp
ID0+IHt9IH0pIHsKICAgIHRoaXMubnVtYmVyID0gbnVtYmVyOwogICAgdGhpcy5uYW1lID0gbmFt
ZTsgLy8gTWFpbi56CiAgICB0aGlzLmRlc2NyaXB0aW9uID0gZGVzY3JpcHRpb247IC8vIE1haW4u
QQogICAgdGhpcy5jYyA9IGNjOyAvLyBNYWluLkUKICAgIHRoaXMubGltaXQgPSBNYXRoLm1pbihD
TElFTlRTLCBNYXRoLm1heCgyLCBsaW1pdCkpOyAvLyBNYWluLk8KICAgIHRoaXMucGFzc3dvcmQg
PSAnJzsgLy8gTWFpbi5DIC8gTWFpbi5EIChyb29tcyBoZXJlIGhhdmUgbm9uZSkKICAgIHRoaXMu
bGF0ZW5jeUxpbWl0ID0gLTE7IC8vIE1haW4uYUoKICAgIHRoaXMuYWZrTWludXRlcyA9IC0xOyAv
LyBNYWluLmFMCiAgICB0aGlzLnJhbmRvbSA9IHJhbmRvbTsKICAgIHRoaXMubG9nID0gbG9nOwog
ICAgdGhpcy5zbG90cyA9IEFycmF5LmZyb20oeyBsZW5ndGg6IFNMT1RTIH0sIG5ld1Nsb3QpOyAv
LyBNYWluLmFwCiAgICB0aGlzLnNsb3RzW0hPU1RfU0xPVF0ubmFtZSA9ICc8Zm9udCBjb2xvcj0i
I0NDRkZGRiI+Um9vbSBIb3N0PC9mb250Pic7CiAgICB0aGlzLm1lbiA9IFtdOyAvLyBNYWluLmFx
CiAgICB0aGlzLmNvbm5lY3RlZCA9IDA7IC8vIE1haW4uTQogICAgdGhpcy5jb25uZWN0aW9ucyA9
IG5ldyBTZXQoKTsKICAgIC8vIGguYSwgaC5iOiB0aGUgcmFuZG9tIHRhYmxlIGFuZCBpdHMgc3Rh
cnRpbmcgcG9pbnQsIHRoZSBzYW1lIGZvciBldmVyeSBnYW1lIGluIHRoZSByb29tLgogICAgdGhp
cy50YWJsZSA9IEFycmF5LmZyb20oeyBsZW5ndGg6IDUwMDAgfSwgKCkgPT4gdGhpcy5uZXh0SW50
KDEwMDAwKSk7CiAgICB0aGlzLnNlZWQgPSB0aGlzLm5leHRJbnQoNTAwMCk7CiAgICAvLyBUaGUg
am91cm5hbDogd2hhdCBoYXBwZW5lZCBpbiB0aGlzIHJvb20gbGF0ZWx5LCBmb3IgdGhlIGFkbWlu
IHBhZ2UgKGhmLmpzIC9hZG1pbi9hcGkvaGYtam91cm5hbCkuIEpvaW5zLAogICAgLy8gbGVhdmVz
LCBmaWdodHMsIHBhdXNlcywgYW5kIHdoZW4gYSBmaWdodCBnb2VzIG91dCBvZiBzdGVwLCBldmVy
eXRoaW5nIHRoZSB0d28gZ2FtZXMgcmVwb3J0ZWQgYXJvdW5kIHRoYXQKICAgIC8vIGZyYW1lLCBz
byB0aGF0IHRoZSBjYXVzZSBjYW4gYmUgbG9va2VkIGZvciBhZnRlcndhcmRzLgogICAgdGhpcy5q
b3VybmFsID0gW107CiAgICB0aGlzLndpblJlcG9ydGVkID0gZmFsc2U7IC8vIGguYwogICAgdGhp
cy5maWdodHMgPSAwOyAvLyBmaWdodHMgYmVndW4sIG51bWJlcmVkIGZvciB0aGUgcGFnZXMgdGhh
dCBwYXNzIGZyYW1lcyBkaXJlY3RseSAoYW5ub3VuY2VGaWdodCkKICAgIHRoaXMuYnVpbGQgPSBu
dWxsOyAvLyB0aGUgYnVpbGQgb2YgdGhlIGdhbWVzIGluIHRoZSByb29tIChhY2NlcHRzQnVpbGQp
CiAgICB0aGlzLnN0ZXBzID0gbmV3IE1hcCgpOyAvLyBmcmFtZSAtPiB0aGUgcmFuZG9tIG51bWJl
cnMgdXNlZCBieSB0aGVuLCBhcyB0aGUgZmlyc3QgZ2FtZSByZXBvcnRlZCBpdAogICAgdGhpcy5v
dXRPZlN0ZXAgPSBmYWxzZTsKICAgIHRoaXMuc3RhcnRpbmcgPSBmYWxzZTsgLy8gTWFpbi5yOiBh
IGZpZ2h0IGlzIHN0YXJ0aW5nOyBmcmFtZXMgd2FpdCB1bnRpbCBldmVyeSBnYW1lIGhhcyBzdGFy
dGVkCiAgICB0aGlzLmNvdW50ZG93biA9IHsgb246IGZhbHNlLCBjb3VudDogQ09VTlRET1dOLCBh
Y3Rpb246ICcnIH07IC8vIFQuYSwgVC5iLCBULmQKICAgIHRoaXMuZmlnaHRpbmdOb3cgPSBmYWxz
ZTsgLy8gTWFpbi5hbQogICAgdGhpcy5tb2RlID0gJ1dBSVRST09NJzsgLy8gTWFpbi5hawogICAg
dGhpcy5wYWdlID0gJ1dBSVRST09NJzsgLy8gTWFpbi5hbAogICAgdGhpcy5wcmV2aW91c1BhZ2Ug
PSAnJzsgLy8gTWFpbi5hbgogICAgdGhpcy5zdG9yeSA9IDA7IC8vIE1haW4uYW8KICAgIHRoaXMu
YmF0dGxlVHlwZSA9IDExMTE7IC8vIE1haW4uYUMKICAgIHRoaXMucHJlc2V0ID0gLTE7IC8vIE1h
aW4uYUQKICAgIHRoaXMudGVhbXMgPSA0OyAvLyBNYWluLmFFCiAgICB0aGlzLnRlYW1NYXAgPSBb
MCwgMSwgMiwgM107IC8vIE1haW4uYUYKICAgIHRoaXMucmVzZXQoKTsKICAgIHRoaXMuY2xvc2Vk
ID0gZmFsc2U7CiAgICB0aGlzLnRpbWVycyA9IFtdOwogICAgLy8gVGhlIG9yaWdpbmFsJ3MgdGhy
ZWFkczogdGhlIGNvdW50ZG93biAoVCwgZXZlcnkgMTAwIG1zKSwgZnJhbWUgc2VuZGluZyAoYXYs
IGV2ZXJ5IDEwIG1zKSBhbmQKICAgIC8vIHRoZSB3YXRjaGRvZyB0aGF0IHBpbmdzIGFuZCB0aW1l
cyBvdXQgZ2FtZXMgKGFBLCBldmVyeSAyIHMgYWZ0ZXIgMTAgcykuCiAgICB0aGlzLmNvdW50ZG93
blRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB0aGlzLmNvdW50ZG93blRpY2soKSwgMTAwKTsKICAg
IHRoaXMudGltZXJzLnB1c2goc2V0SW50ZXJ2YWwoKCkgPT4gdGhpcy5mbHVzaFRpY2soKSwgMTAp
KTsKICAgIHRoaXMud2F0Y2hkb2dTdGFydCA9IHNldFRpbWVvdXQoKCkgPT4geyB0aGlzLnRpbWVy
cy5wdXNoKHNldEludGVydmFsKCgpID0+IHRoaXMud2F0Y2hkb2coKSwgMjAwMCkpOyB9LCAxMDAw
MCk7CiAgICBmb3IgKGNvbnN0IHRpbWVyIG9mIHRoaXMudGltZXJzKSBpZiAodGltZXIudW5yZWYp
IHRpbWVyLnVucmVmKCk7CiAgfQoKICBuZXh0SW50KGJvdW5kKSB7IHJldHVybiBNYXRoLmZsb29y
KHRoaXMucmFuZG9tKCkgKiBib3VuZCk7IH0KCiAgY2xvc2UoKSB7CiAgICB0aGlzLmNsb3NlZCA9
IHRydWU7CiAgICBjbGVhclRpbWVvdXQodGhpcy5jb3VudGRvd25UaW1lcik7CiAgICBjbGVhclRp
bWVvdXQodGhpcy53YXRjaGRvZ1N0YXJ0KTsKICAgIGZvciAoY29uc3QgdGltZXIgb2YgdGhpcy50
aW1lcnMpIGNsZWFySW50ZXJ2YWwodGltZXIpOwogICAgZm9yIChjb25zdCBjb25uZWN0aW9uIG9m
IFsuLi50aGlzLmNvbm5lY3Rpb25zXSkgY29ubmVjdGlvbi5jbG9zZSgpOwogIH0KCiAgLy8gTWFp
bi5rOiB0aGUgc2V0dGluZ3MgYW5kIHRoZSBtZW4gYSByb29tIHN0YXJ0cyB3aXRoLgogIHJlc2V0
KCkgewogICAgdGhpcy5hbGxvd0pvaW5XaGVuRmlnaHRpbmcgPSB0cnVlOyAvLyBNYWluLlYKICAg
IHRoaXMucGlja011c2ljKCk7CiAgICB0aGlzLm11c2ljUmFuZG9tID0gdHJ1ZTsgLy8gTWFpbi5Y
CiAgICB0aGlzLm11bHRpcGxhbmUgPSB0cnVlOyAvLyBNYWluLmFiCiAgICB0aGlzLmJhY2tncm91
bmQgPSAncm9vbTEnOyAvLyBNYWluLlkKICAgIHRoaXMuYmFja2dyb3VuZENob3NlbiA9ICdyb29t
MSc7IC8vIE1haW4uWgogICAgdGhpcy5iYWNrZ3JvdW5kUmFuZG9tID0gZmFsc2U7IC8vIE1haW4u
VwogICAgdGhpcy5ob3JzZXMgPSAwOyAvLyBNYWluLmFjCiAgICB0aGlzLmdpYW50T2JqZWN0cyA9
IDA7IC8vIE1haW4uYWQKICAgIHRoaXMuZGlmZmljdWx0eSA9IDA7IC8vIE1haW4uYWUKICAgIHRo
aXMubm9ybWFsaXplTGV2ZWwgPSAxOyAvLyBNYWluLmFpCiAgICB0aGlzLmRpbm9zYXVycyA9IDA7
IC8vIE1haW4uYWoKICAgIHRoaXMudGVzdFRyb29wcyA9IDA7IC8vIE1haW4uYWYKICAgIHRoaXMu
c29sZGllck51bWJlciA9IDE7IC8vIE1haW4uYWcKICAgIHRoaXMuc29sZGllclJlc2VydmVkID0g
MTsgLy8gTWFpbi5haAogICAgdGhpcy5zdG9yeSA9IDA7CiAgICB0aGlzLm1vZGUgPSAnV0FJVFJP
T00nOwogICAgdGhpcy5wYWdlID0gJ1dBSVRST09NJzsKICAgIHRoaXMucHJldmlvdXNQYWdlID0g
Jyc7CiAgICB0aGlzLm1lbiA9IEFycmF5LmZyb20oeyBsZW5ndGg6IE1FTiB9LCBuZXdNYW4pOwog
IH0KCiAgLy8gQSBjb21wdXRlciBwbGF5ZXIncyBsZXZlbCB3aXRoIGEgY2hhcmFjdGVyOiB0aGUg
YmVzdCBhIHBsYXllciBpbiB0aGUgcm9vbSBoYXMsIGVsc2UgdGhlIGdhbWUncyBoaWdoZXN0Lgog
IGNvbXB1dGVyTGV2ZWwoY2hhcmFjdGVyKSB7CiAgICBsZXQgbGV2ZWwgPSAwOwogICAgZm9yIChj
b25zdCBzbG90IG9mIHRoaXMub25saW5lKCkpIGlmIChzbG90LmxldmVsc1tjaGFyYWN0ZXJdID4g
bGV2ZWwpIGxldmVsID0gc2xvdC5sZXZlbHNbY2hhcmFjdGVyXTsKICAgIHJldHVybiBsZXZlbCA+
IDAgPyBsZXZlbCA6IE1BWF9MRVZFTDsKICB9CgogIC8vIFdoZXRoZXIgYSBnYW1lIG9mIHRoaXMg
YnVpbGQgKGl0cyBtb3ZpZSBhbmQgUnVmZmxlLCBhcyB0aGUgcGFnZSByZXBvcnRzIHRoZW0pIG1h
eSBqb2luOiB0aGUgc2FtZSBhcwogIC8vIHRoZSBnYW1lcyBpbiB0aGUgcm9vbSwgd2hvc2Ugc2lt
dWxhdGlvbnMgbXVzdCBtYXRjaCBzdGVwIGZvciBzdGVwLgogIGFjY2VwdHNCdWlsZChidWlsZCkg
ewogICAgaWYgKCF0aGlzLm9ubGluZSgpLmxlbmd0aCkgdGhpcy5idWlsZCA9IGJ1aWxkOwogICAg
cmV0dXJuIHRoaXMuYnVpbGQgPT09IGJ1aWxkOwogIH0KCiAgLy8gRXZlcnkgZ2FtZSByZXBvcnRz
LCBldmVyeSAyMCBmcmFtZXMsIGhvdyBtYW55IHJhbmRvbSBudW1iZXJzIGl0IGhhcyB1c2VkIHNv
IGZhciAoPHJwYz4pOyBnYW1lcyB0aGF0CiAgLy8gZGlmZmVyIG5vIGxvbmdlciBzaG93IHRoZSBz
YW1lIGZpZ2h0LiBUaGUgb3JpZ2luYWwgcGFzc2VkIHRoZXNlIG9uIGFuZCB0aGUgZ2FtZXMgdGhl
bXNlbHZlcyBjbG9zZWQKICAvLyB0aGUgY29ubmVjdGlvbiBvbiBhIGRpZmZlcmVuY2UgKCJTeW5j
aHJvbml6YXRpb24gZXJyb3IiKSwgd2hpY2ggdGhyZXcgZXZlcnlvbmUgb3V0IG9mIHRoZSByb29t
OyBoZXJlCiAgLy8gdGhlIHNlcnZlciBjb21wYXJlcyB0aGVtIGFuZCBlbmRzIHRoZSBmaWdodCBp
bnN0ZWFkLCBiYWNrIHRvIHRoZSBtZW51cywgd2l0aCBldmVyeW9uZSBzdGlsbCBpbi4KICBjaGVj
a1N0ZXAoaW5kZXgsIGZyYW1lLCB1c2VkKSB7CiAgICBpZiAoIXRoaXMuZmlnaHRpbmdOb3cgfHwg
dGhpcy5vdXRPZlN0ZXApIHJldHVybjsKICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3RzW2luZGV4
XTsKICAgIHNsb3Quc3RlcHMucHVzaChbZnJhbWUsIHVzZWRdKTsKICAgIGlmIChzbG90LnN0ZXBz
Lmxlbmd0aCA+IDYwKSBzbG90LnN0ZXBzLnNoaWZ0KCk7CiAgICBjb25zdCBzZWVuID0gdGhpcy5z
dGVwcy5nZXQoZnJhbWUpOwogICAgaWYgKCFzZWVuKSB7CiAgICAgIHRoaXMuc3RlcHMuc2V0KGZy
YW1lLCB7IHVzZWQsIGZyb206IGluZGV4IH0pOwogICAgICBpZiAodGhpcy5zdGVwcy5zaXplID4g
NjQpIHRoaXMuc3RlcHMuZGVsZXRlKHRoaXMuc3RlcHMua2V5cygpLm5leHQoKS52YWx1ZSk7CiAg
ICAgIHJldHVybjsKICAgIH0KICAgIGlmIChzZWVuLnVzZWQgPT09IHVzZWQpIHJldHVybjsKICAg
IHRoaXMub3V0T2ZTdGVwID0gdHJ1ZTsKICAgIHRoaXMubG9nKGBoZiByb29tICR7dGhpcy5udW1i
ZXJ9OiBnYW1lcyAke3NlZW4uZnJvbX0gYW5kICR7aW5kZXh9IG91dCBvZiBzdGVwIGF0IGZyYW1l
ICR7ZnJhbWV9OiBlbmRpbmcgdGhlIGZpZ2h0YCk7CiAgICB0aGlzLmpvdE91dE9mU3RlcChzZWVu
LmZyb20sIGluZGV4LCBmcmFtZSk7CiAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5vbmxpbmUo
KSkgewogICAgICBzbG90LmNvbm5lY3Rpb24ubm90aWNlKCdIYWkgbWF5IGtob25nIGNvbiBraG9w
IG5oYXUgKGRlc3luYyk6IHRyYW4gZGF1IGR1bmcgbGFpLiBCYW0gTmV4dCByb2kgU3RhcnQgRmln
aHQhIGRlIGRhbmggbGFpLicpOwogICAgfQogICAgY29uc3QgY291bnRkb3duID0gdGhpcy5jb3Vu
dGRvd247CiAgICBjb3VudGRvd24ub24gPSB0cnVlOwogICAgY291bnRkb3duLmFjdGlvbiA9ICdx
dWl0Z2FtZSc7CiAgICBjb3VudGRvd24uY291bnQgPSAxOwogIH0KCiAgLy8gLS0tLSBEaXJlY3Qg
bGlua3MgKGRpc3QvcGFnZXMvaGYtZGlyZWN0LmpzKTogcGFnZXMgdGhhdCBzYXkgc28gKGRpcmVj
dD0xKSBhbHNvIHBhc3MgdGhlaXIgZ2FtZSdzIGZyYW1lcwogIC8vIHN0cmFpZ2h0IHRvIHRoZSBv
dGhlciBwYWdlcyBvZiB0aGUgcm9vbSBvdmVyIFdlYlJUQywgYW5kIGVhY2ggZ2FtZSB0YWtlcyB3
aGljaGV2ZXIgY29weSBvZiBhIGZyYW1lCiAgLy8gY29tZXMgZmlyc3Q7IGV2ZXJ5dGhpbmcgZWxz
ZSwgYW5kIGV2ZXJ5IGZyYW1lIHRvbywgc3RpbGwgZ29lcyB0aHJvdWdoIGhlcmUgYXMgYmVmb3Jl
LiBUaGUgcm9vbSB0ZWxscwogIC8vIHRoZXNlIHBhZ2VzIHdobyBlbHNlIGlzIGluIGl0LCBwYXNz
ZXMgb24gd2hhdCB0aGV5IG5lZWQgdG8gc2V0IHVwIGEgbGluaywgYW5kIG51bWJlcnMgdGhlIGZp
Z2h0cywgc28KICAvLyB0aGF0IGEgcGFnZSBuZXZlciB0YWtlcyBhIGZyYW1lIG9mIGFub3RoZXIg
ZmlnaHQuCgogIC8vIFRoZSBnYW1lIHdpdGggdGhpcyBjb25uZWN0aW9uIGlkIGFtb25nIHRob3Nl
IGluIHRoZSByb29tIHRoYXQgcGFzcyBmcmFtZXMgZGlyZWN0bHkuCiAgZGlyZWN0UGVlcihpZCkg
ewogICAgZm9yIChjb25zdCBzbG90IG9mIHRoaXMub25saW5lKCkpIGlmIChzbG90LmNvbm5lY3Rp
b24uZGlyZWN0ICYmIHNsb3QuY29ubmVjdGlvbi5pZCA9PT0gaWQpIHJldHVybiBzbG90LmNvbm5l
Y3Rpb247CiAgICByZXR1cm4gbnVsbDsKICB9CgogIC8vIEVhY2ggc3VjaCBwYWdlIGxlYXJucyB0
aGUgb3RoZXJzICh3aGVuIHRoZSBnYW1lcyBpbiB0aGUgcm9vbSBjaGFuZ2UpLCB0byBsaW5rIHdp
dGggdGhlbS4KICBhbm5vdW5jZVBlZXJzKCkgewogICAgY29uc3QgZ2FtZXMgPSB0aGlzLm9ubGlu
ZSgpLm1hcCgoc2xvdCkgPT4gc2xvdC5jb25uZWN0aW9uKS5maWx0ZXIoKGNvbm5lY3Rpb24pID0+
IGNvbm5lY3Rpb24uZGlyZWN0KTsKICAgIGZvciAoY29uc3QgY29ubmVjdGlvbiBvZiBnYW1lcykg
ewogICAgICBjb25uZWN0aW9uLnNheSh7IHQ6ICdwZWVycycsIGNpZDogY29ubmVjdGlvbi5pbmRl
eCwgcGVlcnM6IGdhbWVzLmZpbHRlcigob3RoZXIpID0+IG90aGVyICE9PSBjb25uZWN0aW9uKQog
ICAgICAgIC5tYXAoKG90aGVyKSA9PiAoeyBpZDogb3RoZXIuaWQsIGNpZDogb3RoZXIuaW5kZXgs
IG5hbWU6IG90aGVyLm5hbWUgfSkpIH0pOwogICAgfQogIH0KCiAgLy8gQSBmaWdodCBiZWdpbnMg
KGp1c3QgYmVmb3JlIDxhbGxzdGFydGVkZ2FtZT4pOiBpdHMgbnVtYmVyIGFuZCB0aGUgcGFnZXMg
ZmlnaHRpbmcgaW4gaXQ7IGluIHRoZSBqb3VybmFsLAogIC8vIHRoZSBkaXJlY3QgbGlua3MgaXQg
bWF5IHVzZS4KICBhbm5vdW5jZUZpZ2h0KCkgewogICAgdGhpcy5maWdodHMgKz0gMTsKICAgIGNv
bnN0IGZpZ2h0aW5nID0gdGhpcy5vbmxpbmUoKS5maWx0ZXIoKHNsb3QpID0+IHNsb3QucGFnZSAh
PT0gJ1dBSVRST09NJykubWFwKChzbG90KSA9PiBzbG90LmNvbm5lY3Rpb24pOwogICAgY29uc3Qg
aWRzID0gZmlnaHRpbmcuZmlsdGVyKChjb25uZWN0aW9uKSA9PiBjb25uZWN0aW9uLmRpcmVjdCku
bWFwKChjb25uZWN0aW9uKSA9PiBjb25uZWN0aW9uLmlkKTsKICAgIGZvciAoY29uc3Qgc2xvdCBv
ZiB0aGlzLm9ubGluZSgpKSBzbG90LmNvbm5lY3Rpb24uc2F5KHsgdDogJ2ZpZ2h0JywgbjogdGhp
cy5maWdodHMsIGlkcyB9KTsKICAgIGlmIChmaWdodGluZy5sZW5ndGggPCAyKSByZXR1cm47CiAg
ICBjb25zdCBsaW5rcyA9IFtdOwogICAgZm9yIChjb25zdCBhIG9mIGZpZ2h0aW5nKSB7CiAgICAg
IGZvciAoY29uc3QgYiBvZiBmaWdodGluZykgewogICAgICAgIGlmIChhLmluZGV4ID49IGIuaW5k
ZXggfHwgIShhLmxpbmtzLmhhcyhiLmlkKSB8fCBiLmxpbmtzLmhhcyhhLmlkKSkpIGNvbnRpbnVl
OwogICAgICAgIGNvbnN0IG1zID0gW2EubGlua3MuZ2V0KGIuaWQpLCBiLmxpbmtzLmdldChhLmlk
KV0uZmlsdGVyKE51bWJlci5pc0Zpbml0ZSk7CiAgICAgICAgbGlua3MucHVzaChgJHthLm5hbWV9
LSR7Yi5uYW1lfSR7bXMubGVuZ3RoID8gYCAke01hdGgubWluKC4uLm1zKX0gbXNgIDogJyd9YCk7
CiAgICAgIH0KICAgIH0KICAgIHRoaXMuam90KGBmaWdodCAke3RoaXMuZmlnaHRzfTogZGlyZWN0
IGxpbmtzICR7bGlua3Muam9pbignLCAnKSB8fCAnbm9uZSd9YCk7CiAgfQoKICAvLyBBIGxpbmUg
aW4gdGhlIHJvb20ncyBqb3VybmFsIChrZXB0OiB0aGUgbGFzdCA0MDApLgogIGpvdCh0ZXh0KSB7
CiAgICBjb25zdCBzdGFtcCA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLCAxOSku
cmVwbGFjZSgnVCcsICcgJyk7CiAgICB0aGlzLmpvdXJuYWwucHVzaChgJHtzdGFtcH0gJHt0ZXh0
fWApOwogICAgaWYgKHRoaXMuam91cm5hbC5sZW5ndGggPiA0MDApIHRoaXMuam91cm5hbC5zcGxp
Y2UoMCwgdGhpcy5qb3VybmFsLmxlbmd0aCAtIDQwMCk7CiAgfQoKICAvLyBUaGUgZmlnaHQgYXMg
aXQgd2FzIHNldCB1cCwgZm9yIHRoZSBqb3VybmFsLgogIGRlc2NyaWJlRmlnaHQoKSB7CiAgICBj
b25zdCBtZW4gPSB0aGlzLm1lbi5maWx0ZXIoKG1hbikgPT4gbWFuLmV4aXN0cykubWFwKChtYW4s
IGspID0+IHsKICAgICAgY29uc3Qgd2hvID0gbWFuLmNsaWVudCA+PSAwID8gYCR7dGhpcy5zbG90
c1ttYW4uY2xpZW50XS5uYW1lfS9QJHttYW4uY29udHJvbGxlciArIDF9YCA6IChtYW4uY29tbWFu
ZGVyID49IDAgPyBgc29sZGllciBvZiAke21hbi5jb21tYW5kZXJ9YCA6ICdjb21wdXRlcicpOwog
ICAgICByZXR1cm4gYCR7bWFuLmNoYXIgfHwgJz8nfSBsdiR7bWFuLmxldmVsfSB0ZWFtJHttYW4u
dGVhbX0gKCR7d2hvfSlgOwogICAgfSk7CiAgICByZXR1cm4gYCR7dGhpcy5tb2RlfSR7dGhpcy5t
b2RlID09PSAnQkFUVExFTU9ERScgPyAnICcgKyB0aGlzLmJhdHRsZVR5cGUgOiAnJ30gZGlmZmlj
dWx0eSAke3RoaXMuZGlmZmljdWx0eX0gbm9ybWFsaXplICR7dGhpcy5ub3JtYWxpemVMZXZlbH1g
CiAgICAgICsgYCBkaW5vc2F1cnMgJHt0aGlzLmRpbm9zYXVyc30gYmFja2dyb3VuZCAke3RoaXMu
YmFja2dyb3VuZH07IG1lbjogJHttZW4uam9pbignLCAnKX07IGxhdGVuY2llczogJHt0aGlzLnBl
b3BsZSgpfWA7CiAgfQoKICAvLyBXaGF0IGJvdGggZ2FtZXMgcmVwb3J0ZWQgYXJvdW5kIHRoZSBm
cmFtZSB0aGV5IHdlbnQgb3V0IG9mIHN0ZXA6IHRoZWlyIHJhbmRvbSBjb3VudHMgKGV2ZXJ5IDIw
IGZyYW1lcyksCiAgLy8gdGhlaXIgPHQ+IHRpbWluZyByZXBvcnRzICg1OTQwID0gZnVsbCBzcGVl
ZCksIGFuZCB0aGUga2V5IGZyYW1lcyB0aGV5IHNlbnQganVzdCBiZWZvcmUuCiAgam90T3V0T2ZT
dGVwKGEsIGIsIGZyYW1lKSB7CiAgICB0aGlzLmpvdChgT1VUIE9GIFNURVAgYXQgZnJhbWUgJHtm
cmFtZX06ICR7dGhpcy5zbG90c1thXS5uYW1lfSAoZ2FtZSAke2F9KSBhbmQgJHt0aGlzLnNsb3Rz
W2JdLm5hbWV9IChnYW1lICR7Yn0pOyAke3RoaXMuZGVzY3JpYmVGaWdodCgpfWApOwogICAgZm9y
IChjb25zdCBpbmRleCBvZiBbYSwgYl0pIHsKICAgICAgY29uc3Qgc2xvdCA9IHRoaXMuc2xvdHNb
aW5kZXhdOwogICAgICBjb25zdCBzdGVwcyA9IHNsb3Quc3RlcHMuc2xpY2UoLTEyKS5tYXAoKFtm
LCB1c2VkXSkgPT4gYCR7Zn06JHt1c2VkfWApLmpvaW4oJyAnKTsKICAgICAgdGhpcy5qb3QoYCAg
Z2FtZSAke2luZGV4fSAke3Nsb3QubmFtZX06IGxhdGVuY3kgJHtzbG90LmxhdGVuY3l9IGxhc3Qg
cGFja2V0ICR7c2xvdC5sYXN0UGFja2V0fSBwYXVzZWQgJHtzbG90LnBhdXNlZH07IHJhbmRvbSBj
b3VudHMgJHtzdGVwc307IHQgJHtzbG90LnRpbWVzLnNsaWNlKC04KS5qb2luKCcgJyl9YCk7CiAg
ICAgIGNvbnN0IGxpbmVzID0gW107CiAgICAgIGZvciAobGV0IGYgPSBNYXRoLm1heCgwLCBmcmFt
ZSAtIDQ0KTsgZiA8PSBNYXRoLm1pbihzbG90Lmxhc3RQYWNrZXQsIGZyYW1lICsgNCk7IGYgKz0g
MSkgewogICAgICAgIGNvbnN0IGxpbmUgPSBzbG90LmZyYW1lc1tmICUgRlJBTUVTX0tFUFRdOwog
ICAgICAgIGlmICghbGluZSkgY29udGludWU7CiAgICAgICAgY29uc3QgYm9keSA9IGxpbmUucmVw
bGFjZSgvXjxmPjxjPlxkKzxcL2M+PGk+KFxkKyk8XC9pPi8sICckMSAnKS5yZXBsYWNlKC88XC9m
PiQvLCAnJyk7CiAgICAgICAgaWYgKCEvXlxkKyAoPHMxPltAXl08XC9zMT4pPyQvLnRlc3QoYm9k
eSkgfHwgLzxtXGQ+Ly50ZXN0KGJvZHkpKSBsaW5lcy5wdXNoKGJvZHkpOwogICAgICB9CiAgICAg
IHRoaXMuam90KGAgIGdhbWUgJHtpbmRleH0ga2V5IGZyYW1lcyAke2ZyYW1lIC0gNDR9Li4ke2Zy
YW1lICsgNH0gKG9ubHkgdGhvc2Ugd2l0aCBjaGFuZ2VzKTogJHtsaW5lcy5qb2luKCcgfCAnKSB8
fCAnbm9uZSd9YCk7CiAgICB9CiAgfQoKICBwaWNrQmFja2dyb3VuZCgpIHsgdGhpcy5iYWNrZ3Jv
dW5kID0gQkFDS0dST1VORFNbdGhpcy5uZXh0SW50KEJBQ0tHUk9VTkRTLmxlbmd0aCldOyB9IC8v
IE1haW4uYQogIHBpY2tNdXNpYygpIHsgdGhpcy5tdXNpYyA9IE1VU0lDW3RoaXMubmV4dEludChN
VVNJQy5sZW5ndGgpXTsgfSAvLyBNYWluLmIKCiAgLy8gTWFpbi5mOiBjb3VudHMgdGhlIGNvbXB1
dGVyczsgYSByb29tIG5vYm9keSBwbGF5cyBpbiBhbnkgbW9yZSBzdGFydHMgb3Zlci4KICByZWNv
dW50KCkgewogICAgbGV0IGVtcHR5ID0gdHJ1ZTsKICAgIHRoaXMuY29ubmVjdGVkID0gMDsKICAg
IGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAg
IGNvbnN0IHNsb3QgPSB0aGlzLnNsb3RzW2luZGV4XTsKICAgICAgaWYgKHNsb3Qub25saW5lKSB0
aGlzLmNvbm5lY3RlZCArPSAxOwogICAgICBpZiAodGhpcy5wYWdlID09PSAnV0FJVFJPT00nKSB7
CiAgICAgICAgaWYgKHNsb3Qub25saW5lKSBlbXB0eSA9IGZhbHNlOwogICAgICB9IGVsc2UgaWYg
KHNsb3Qub25saW5lICYmIHNsb3QucGFnZSAhPT0gJ1dBSVRST09NJykgewogICAgICAgIGVtcHR5
ID0gZmFsc2U7CiAgICAgIH0KICAgIH0KICAgIGlmIChlbXB0eSkgewogICAgICB0aGlzLnJlc2V0
KCk7CiAgICAgIHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwogICAgICB0aGlzLmJyb2Fk
Y2FzdFNldHRpbmcoLTEpOwogICAgICB0aGlzLmJyb2FkY2FzdFN0YXR1cygpOwogICAgICB0aGlz
LmJyb2FkY2FzdE1lbigxKTsKICAgIH0KICB9CgogIG9ubGluZSgpIHsKICAgIGNvbnN0IGxpc3Qg
PSBbXTsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAx
KSBpZiAodGhpcy5zbG90c1tpbmRleF0ub25saW5lKSBsaXN0LnB1c2godGhpcy5zbG90c1tpbmRl
eF0pOwogICAgcmV0dXJuIGxpc3Q7CiAgfQoKICBicm9hZGNhc3QodGV4dCkgeyBmb3IgKGNvbnN0
IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkgc2xvdC5jb25uZWN0aW9uLnNlbmQodGV4dCk7IH0gLy8g
aC5hKFN0cmluZykKICBicm9hZGNhc3RMaXN0KGpvaW5lZCwgcXVpdCkgeyBmb3IgKGNvbnN0IHNs
b3Qgb2YgdGhpcy5vbmxpbmUoKSkgc2xvdC5jb25uZWN0aW9uLnNlbmRMaXN0KGpvaW5lZCwgcXVp
dCk7IH0gLy8gaC5hKGludCwgaW50KQogIGJyb2FkY2FzdFNldHRpbmcoY2lkKSB7IGZvciAoY29u
c3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSBzbG90LmNvbm5lY3Rpb24uc2VuZFNldHRpbmcoY2lk
KTsgfSAvLyBoLmIoaW50KQogIGJyb2FkY2FzdEdhbWVTZXR0aW5nKGNpZCkgeyBmb3IgKGNvbnN0
IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkgc2xvdC5jb25uZWN0aW9uLnNlbmRHYW1lU2V0dGluZyhj
aWQpOyB9IC8vIGguYyhpbnQpCiAgYnJvYWRjYXN0U3RhdHVzKCkgeyAvLyBoLmUKICAgIGZvciAo
Y29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSB7CiAgICAgIHNsb3QuY29ubmVjdGlvbi5zZW5k
KGA8c3RhdHVzPjxtb2RlPiR7dGhpcy5tb2RlfTwvbW9kZT48cGFnZT4ke3RoaXMucGFnZX08L3Bh
Z2U+PHByZXBhZ2U+JHt0aGlzLnByZXZpb3VzUGFnZX08L3ByZXBhZ2U+YAogICAgICAgICsgYDxz
dG9yeWk+JHt0aGlzLnN0b3J5fTwvc3RvcnlpPjwvc3RhdHVzPmApOwogICAgfQogIH0KICAvLyBo
LmEoaW50KTogc29sZGllcnMgd2hvc2UgY29tbWFuZGVyJ3MgY29tcHV0ZXIgbGVmdCBnbyB0b287
IHRoZW4gZXZlcnlvbmUgZ2V0cyB0aGUgbWVuLgogIGJyb2FkY2FzdE1lbihjaGFuZ2VkKSB7CiAg
ICBmb3IgKGNvbnN0IG1hbiBvZiB0aGlzLm1lbikgewogICAgICBpZiAoIW1hbi5leGlzdHMgfHwg
bWFuLmNvbW1hbmRlciA9PT0gLTEpIGNvbnRpbnVlOwogICAgICBjb25zdCBjb21tYW5kZXIgPSB0
aGlzLm1lblttYW4uY29tbWFuZGVyXTsKICAgICAgaWYgKGNvbW1hbmRlci5jbGllbnQgIT09IC0x
ICYmICF0aGlzLnNsb3RzW2NvbW1hbmRlci5jbGllbnRdLm9ubGluZSkgbWFuLmV4aXN0cyA9IGZh
bHNlOwogICAgfQogICAgZm9yIChjb25zdCBzbG90IG9mIHRoaXMub25saW5lKCkpIHNsb3QuY29u
bmVjdGlvbi5zZW5kTWVuKGNoYW5nZWQpOwogIH0KICBicm9hZGNhc3RDb3VudCgpIHsgLy8gaC5j
KCkKICAgIHRoaXMuYnJvYWRjYXN0KGA8c3RhcnRjb3VudD48YWN0aW9uPiR7dGhpcy5jb3VudGRv
d24uYWN0aW9ufTwvYWN0aW9uPjxjb3VudD4ke3RoaXMuY291bnRkb3duLmNvdW50fTwvY291bnQ+
YAogICAgICArIGA8cGFnZT4ke3RoaXMucGFnZX08L3BhZ2U+PC9zdGFydGNvdW50PmApOwogIH0K
ICBicm9hZGNhc3RDbGljayhjaWQsIHdoYXQpIHsgdGhpcy5icm9hZGNhc3QoYDxjaGF0Mj48Yz4k
e2NpZH08L2M+PG0+JHt3aGF0fTwvbT48L2NoYXQyPmApOyB9IC8vIGguYShpbnQsIFN0cmluZykK
ICBuZXdTZWVkKCkgeyAvLyBoLmYKICAgIHRoaXMuc2VlZCA9IHRoaXMubmV4dEludCg1MDAwKTsK
ICAgIHRoaXMuYnJvYWRjYXN0KGA8cnA+PHJwPiR7dGhpcy5zZWVkfTwvcnA+PC9ycD5gKTsKICB9
CgogIC8vIGguYSgpOiB0aGUgZnJhbWVzIG9mIHRoZSBmaWdodCBzdGFydCBvdmVyLgogIHJlc2V0
RnJhbWVzKCkgewogICAgdGhpcy5zdGVwcy5jbGVhcigpOwogICAgdGhpcy5vdXRPZlN0ZXAgPSBm
YWxzZTsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAx
KSB7CiAgICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3RzW2luZGV4XTsKICAgICAgc2xvdC5mbHVz
aGVzID0gMDsKICAgICAgc2xvdC5wYXVzZWQgPSBmYWxzZTsKICAgICAgc2xvdC5maWdodGluZyA9
IGZhbHNlOwogICAgICBzbG90Lmxhc3RQYWNrZXQgPSAtMTsKICAgICAgc2xvdC5sZWZ0RnJhbWUg
PSAtMTsKICAgICAgaWYgKHNsb3QuY29ubmVjdGlvbikgc2xvdC5jb25uZWN0aW9uLnJlc2V0RnJh
bWVzKCk7CiAgICB9CiAgfQoKICAvLyBoLmIoKTogbGF0ZW5jaWVzIGVhc2UgdG93YXJkcyB0aGVp
ciB0YXJnZXRzLgogIGVhc2VMYXRlbmNpZXMoKSB7CiAgICBmb3IgKGxldCBpbmRleCA9IDA7IGlu
ZGV4IDwgQ0xJRU5UUzsgaW5kZXggKz0gMSkgewogICAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90
c1tpbmRleF07CiAgICAgIGlmIChzbG90Lm9ubGluZSkgc2xvdC5sYXRlbmN5ID0gTWF0aC50cnVu
Yygoc2xvdC5sYXRlbmN5VGFyZ2V0ICsgc2xvdC5sYXRlbmN5ICogMykgLyA0KTsKICAgIH0KICAg
IHRoaXMuYnJvYWRjYXN0TGlzdCgtMSwgLTEpOwogIH0KCiAgLy8gVC5hKCk6IGEgZmlnaHQgc3Rh
cnRzOyBmcmFtZXMgd2FpdCBmb3IgZXZlcnkgZ2FtZS4KICBzdGFydEZpZ2h0KCkgewogICAgZm9y
IChjb25zdCBzbG90IG9mIHRoaXMuc2xvdHMpIHNsb3Quc3RhcnRlZCA9IGZhbHNlOwogICAgdGhp
cy5zdGFydGluZyA9IHRydWU7CiAgfQoKICAvLyBUaGUgY291bnRkb3duIHRocmVhZCAoVCk6IGV2
ZXJ5IDEwMCBtcywgYW5kIDQwMCBtcyBtb3JlIGFmdGVyIGEgc3RlcCBvZiBhIGNvdW50ZG93bi4K
ICBjb3VudGRvd25UaWNrKCkgewogICAgaWYgKHRoaXMuY2xvc2VkKSByZXR1cm47CiAgICBsZXQg
ZGVsYXkgPSAxMDA7CiAgICB0cnkgewogICAgICBpZiAodGhpcy5zdGFydGluZykgewogICAgICAg
IHRoaXMuc3RhcnRpbmcgPSBmYWxzZTsKICAgICAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5z
bG90cykgewogICAgICAgICAgaWYgKHNsb3Qub25saW5lICYmICFzbG90LnN0YXJ0ZWQgJiYgc2xv
dC5wYWdlICE9PSAnV0FJVFJPT00nKSB0aGlzLnN0YXJ0aW5nID0gdHJ1ZTsKICAgICAgICB9CiAg
ICAgICAgaWYgKCF0aGlzLnN0YXJ0aW5nKSB7CiAgICAgICAgICBmb3IgKGNvbnN0IHNsb3Qgb2Yg
dGhpcy5zbG90cykgaWYgKHNsb3QuY29ubmVjdGlvbikgc2xvdC5jb25uZWN0aW9uLnJlc2V0RnJh
bWVzKCk7CiAgICAgICAgICB0aGlzLnN0ZXBzLmNsZWFyKCk7CiAgICAgICAgICB0aGlzLm91dE9m
U3RlcCA9IGZhbHNlOwogICAgICAgICAgLy8gRWFjaCBnYW1lIHJlcG9ydHMgaXRzIGV4cGVyaWVu
Y2UgYWZ0ZXIgYSBmaWdodCBhbmQgd2FpdHMgZm9yIHRoZSBhbnN3ZXIgYmVmb3JlIGl0IHN0YXJ0
cyB0aGUKICAgICAgICAgIC8vIG5leHQsIHNlbmRpbmcgaXRzIGNoYXJhY3RlcnMnIGxldmVscyAo
PGluZm8+KSBvbiB0aGUgd2F5OyBhIHJlc3RhcnQgc2VuZHMgdGhlIG1lbiBiZWZvcmUKICAgICAg
ICAgIC8vIHRob3NlIGNvbWUuIFNvIGV2ZXJ5IGdhbWUgZ2V0cyB0aGUgbWVuIGFnYWluIG5vdywg
d2l0aCB0aGUgc2FtZSBsZXZlbHMgZm9yIGV2ZXJ5b25lIChlYWNoCiAgICAgICAgICAvLyBnYW1l
IGJ1aWxkcyB0aGUgZmlnaHQgZnJvbSB0aGlzIGxpc3Qgb25jZSA8YWxsc3RhcnRlZGdhbWU+IGNv
bWVzKS4KICAgICAgICAgIHRoaXMuYnJvYWRjYXN0TWVuKDApOwogICAgICAgICAgdGhpcy5uZXdT
ZWVkKCk7CiAgICAgICAgICB0aGlzLmFubm91bmNlRmlnaHQoKTsKICAgICAgICAgIHRoaXMuYnJv
YWRjYXN0KCc8YWxsc3RhcnRlZGdhbWU+PC9hbGxzdGFydGVkZ2FtZT4nKTsKICAgICAgICB9CiAg
ICAgIH0KICAgICAgY29uc3QgY291bnRkb3duID0gdGhpcy5jb3VudGRvd247CiAgICAgIGlmIChj
b3VudGRvd24ub24pIHsKICAgICAgICBjb3VudGRvd24uY291bnQgLT0gMTsKICAgICAgICBpZiAo
Y291bnRkb3duLmNvdW50IDw9IDApIHsKICAgICAgICAgIHRoaXMuY291bnRkb3duRG9uZShjb3Vu
dGRvd24uYWN0aW9uKTsKICAgICAgICAgIHRoaXMuYnJvYWRjYXN0Q291bnQoKTsKICAgICAgICAg
IGNvdW50ZG93bi5jb3VudCA9IENPVU5URE9XTjsKICAgICAgICAgIGNvdW50ZG93bi5vbiA9IGZh
bHNlOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICB0aGlzLmJyb2FkY2FzdENvdW50KCk7CiAg
ICAgICAgfQogICAgICAgIGRlbGF5ICs9IDQwMDsKICAgICAgfQogICAgfSBjYXRjaCAoZXJyb3Ip
IHsKICAgICAgdGhpcy5sb2coYGhmIHJvb20gJHt0aGlzLm51bWJlcn06IGNvdW50ZG93bjogJHtl
cnJvci5zdGFjayB8fCBlcnJvcn1gKTsKICAgIH0KICAgIHRoaXMuY291bnRkb3duVGltZXIgPSBz
ZXRUaW1lb3V0KCgpID0+IHRoaXMuY291bnRkb3duVGljaygpLCBkZWxheSk7CiAgfQoKICBlbnRl
clBhZ2UocGFnZSwgcHJldmlvdXMpIHsKICAgIHRoaXMucGFnZSA9IHBhZ2U7CiAgICB0aGlzLmZp
Z2h0aW5nTm93ID0gZmFsc2U7CiAgICB0aGlzLnByZXZpb3VzUGFnZSA9IHByZXZpb3VzOwogIH0K
CiAgY291bnRkb3duRG9uZShhY3Rpb24pIHsKICAgIGNvbnN0IHBhZ2UgPSB0aGlzLnBhZ2U7CiAg
ICBjb25zdCBtb2RlID0gdGhpcy5tb2RlOwogICAgaWYgKGFjdGlvbiA9PT0gJ2NsaWNrdnMnICYm
IHBhZ2UgPT09ICdXQUlUUk9PTScpIHsKICAgICAgdGhpcy5tb2RlID0gJ1ZTTU9ERSc7CiAgICAg
IHRoaXMuZW50ZXJQYWdlKCdDSEFSTUVOVScsICdXQUlUUk9PTScpOwogICAgICB0aGlzLmJhdHRs
ZVR5cGUgPSAxMTExOwogICAgICB0aGlzLnByZXNldCA9IC0xOwogICAgICBpZiAodGhpcy5iYWNr
Z3JvdW5kQ2hvc2VuID09PSAncmFuZG9tJykgewogICAgICAgIHRoaXMuYmFja2dyb3VuZCA9IEJB
Q0tHUk9VTkRTW3RoaXMubmV4dEludChCQUNLR1JPVU5EUy5sZW5ndGgpXTsKICAgICAgICB0aGlz
LmJhY2tncm91bmRSYW5kb20gPSB0cnVlOwogICAgICB9IGVsc2UgewogICAgICAgIHRoaXMuYmFj
a2dyb3VuZCA9IHRoaXMuYmFja2dyb3VuZENob3NlbjsKICAgICAgICB0aGlzLmJhY2tncm91bmRS
YW5kb20gPSBmYWxzZTsKICAgICAgfQogICAgICB0aGlzLmFmdGVyUGFnZUNoYW5nZSgpOwogICAg
fSBlbHNlIGlmIChhY3Rpb24gPT09ICdjbGlja3N0b3J5JyAmJiBwYWdlID09PSAnV0FJVFJPT00n
KSB7CiAgICAgIHRoaXMubW9kZSA9ICdTVE9SWU1PREUnOwogICAgICB0aGlzLmVudGVyUGFnZSgn
U1RPUllNRU5VJywgJ1dBSVRST09NJyk7CiAgICAgIHRoaXMuYWZ0ZXJQYWdlQ2hhbmdlKCk7CiAg
ICB9IGVsc2UgaWYgKGFjdGlvbiA9PT0gJ2NsaWNrYmF0dGxlJyAmJiBwYWdlID09PSAnV0FJVFJP
T00nKSB7CiAgICAgIHRoaXMubW9kZSA9ICdCQVRUTEVNT0RFJzsKICAgICAgdGhpcy5lbnRlclBh
Z2UoJ0JBVFRMRVNFVFRJTkdNRU5VJywgJ1dBSVRST09NJyk7CiAgICAgIHRoaXMuYmF0dGxlVHlw
ZSA9IDExMTE7CiAgICAgIHRoaXMucHJlc2V0ID0gLTE7CiAgICAgIHRoaXMudGVhbXMgPSA0Owog
ICAgICB0aGlzLmJhY2tncm91bmQgPSAnYmF0dGxlNCc7CiAgICAgIHRoaXMuYmFja2dyb3VuZFJh
bmRvbSA9IGZhbHNlOwogICAgICB0aGlzLmFmdGVyUGFnZUNoYW5nZSgpOwogICAgfSBlbHNlIGlm
IChhY3Rpb24gPT09ICdjbGlja25leHQnICYmIHBhZ2UgPT09ICdCQVRUTEVTRVRUSU5HTUVOVScp
IHsKICAgICAgdGhpcy5lbnRlclBhZ2UoJ0NIQVJNRU5VJywgJ0JBVFRMRVNFVFRJTkdNRU5VJyk7
CiAgICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBNRU47IGluZGV4ICs9IDEpIHsKICAg
ICAgICBjb25zdCBtYW4gPSB0aGlzLm1lbltpbmRleF07CiAgICAgICAgaWYgKG1hbi5leGlzdHMg
JiYgbWFuLnRlYW0gPj0gdGhpcy50ZWFtcykgbWFuLnRlYW0gJT0gdGhpcy50ZWFtczsKICAgICAg
ICBpZiAoaW5kZXggPCBNRU4gLSAxICYmIG1hbi5jb250cm9sbGVyID49IDApIHsKICAgICAgICAg
IGZvciAobGV0IG90aGVyID0gaW5kZXggKyAxOyBvdGhlciA8IE1FTjsgb3RoZXIgKz0gMSkgewog
ICAgICAgICAgICBjb25zdCBuZXh0ID0gdGhpcy5tZW5bb3RoZXJdOwogICAgICAgICAgICBpZiAo
bmV4dC5leGlzdHMgJiYgbmV4dC5jb250cm9sbGVyID49IDAgJiYgbmV4dC5jbGllbnQgPT09IG1h
bi5jbGllbnQpIG5leHQudGVhbSA9IG1hbi50ZWFtOwogICAgICAgICAgfQogICAgICAgIH0KICAg
ICAgfQogICAgICB0aGlzLmFmdGVyUGFnZUNoYW5nZSgpOwogICAgfSBlbHNlIGlmIChhY3Rpb24g
PT09ICdjbGlja25leHQnICYmIHBhZ2UgPT09ICdTVE9SWU1FTlUnKSB7CiAgICAgIHRoaXMuZW50
ZXJQYWdlKCdDSEFSTUVOVScsICdTVE9SWU1FTlUnKTsKICAgICAgdGhpcy5hZnRlclBhZ2VDaGFu
Z2UoKTsKICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAnY2xpY2tuZXh0JyAmJiBwYWdlID09PSAn
Q0hBUk1FTlUnICYmIG1vZGUgPT09ICdWU01PREUnKSB7CiAgICAgIHRoaXMuZW50ZXJQYWdlKCdH
QU1FU0VUVElOR01FTlUnLCAnQ0hBUk1FTlUnKTsKICAgICAgdGhpcy5icm9hZGNhc3RMaXN0KC0x
LCAtMSk7CiAgICAgIHRoaXMuYnJvYWRjYXN0TWVuKDEpOwogICAgICBpZiAodGhpcy5iYWNrZ3Jv
dW5kUmFuZG9tKSB0aGlzLnBpY2tCYWNrZ3JvdW5kKCk7CiAgICAgIGlmICh0aGlzLm11c2ljUmFu
ZG9tKSB0aGlzLnBpY2tNdXNpYygpOwogICAgICB0aGlzLmJyb2FkY2FzdEdhbWVTZXR0aW5nKC0x
KTsKICAgICAgdGhpcy5icm9hZGNhc3RTdGF0dXMoKTsKICAgIH0gZWxzZSBpZiAoYWN0aW9uID09
PSAnY2xpY2tuZXh0JyAmJiBwYWdlID09PSAnQ0hBUk1FTlUnICYmIChtb2RlID09PSAnU1RPUllN
T0RFJyB8fCBtb2RlID09PSAnQkFUVExFTU9ERScpKSB7CiAgICAgIHRoaXMuZmlnaHQoJ0NIQVJN
RU5VJyk7CiAgICB9IGVsc2UgaWYgKGFjdGlvbiA9PT0gJ2NsaWNrZmlnaHQnICYmIHBhZ2UgPT09
ICdHQU1FU0VUVElOR01FTlUnKSB7CiAgICAgIHRoaXMuZmlnaHQoJ0dBTUVTRVRUSU5HTUVOVScp
OwogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICdxdWl0Z2FtZScgJiYgdGhpcy5maWdodGluZ05v
dykgewogICAgICB0aGlzLnF1aXRUb01lbnUoKTsKICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAn
cmVzdGFydGdhbWUnICYmIHRoaXMuZmlnaHRpbmdOb3cpIHsKICAgICAgaWYgKHRoaXMub25saW5l
KCkuc29tZSgoc2xvdCkgPT4gc2xvdC5wYWdlID09PSAnV0FJVFJPT00nKSkgewogICAgICAgIHRo
aXMucXVpdFRvTWVudSgpOwogICAgICB9IGVsc2UgewogICAgICAgIHRoaXMuc3RhcnRGaWdodCgp
OwogICAgICAgIHRoaXMucmVzZXRGcmFtZXMoKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdCgnPHJl
c3RhcnRnYW1lPjwvcmVzdGFydGdhbWU+Jyk7CiAgICAgICAgdGhpcy5icm9hZGNhc3RMaXN0KC0x
LCAtMSk7CiAgICAgICAgdGhpcy5icm9hZGNhc3RNZW4oMSk7CiAgICAgICAgdGhpcy5yZXNldEZy
YW1lcygpOwogICAgICAgIHRoaXMuZWFzZUxhdGVuY2llcygpOwogICAgICAgIHRoaXMuYnJvYWRj
YXN0R2FtZVNldHRpbmcoLTEpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0KCc8cmVzdGFydGdhbWU+
PC9yZXN0YXJ0Z2FtZT4nKTsKICAgICAgfQogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICduZXh0
c3RhZ2UnICYmIHRoaXMuZmlnaHRpbmdOb3cpIHsKICAgICAgaWYgKHRoaXMub25saW5lKCkuc29t
ZSgoc2xvdCkgPT4gc2xvdC5wYWdlID09PSAnV0FJVFJPT00nKSkgewogICAgICAgIHRoaXMucGFn
ZSA9ICdTVE9SWU1FTlUnOwogICAgICAgIHRoaXMuZmlnaHRpbmdOb3cgPSBmYWxzZTsKICAgICAg
ICB0aGlzLnByZXZpb3VzUGFnZSA9ICdGSUdIVElORyc7CiAgICAgICAgdGhpcy5xdWl0QnJvYWRj
YXN0cygpOwogICAgICB9IGVsc2UgewogICAgICAgIHRoaXMuc3RhcnRGaWdodCgpOwogICAgICAg
IGlmICh0aGlzLnN0b3J5IDwgNikgdGhpcy5zdG9yeSArPSAxOwogICAgICAgIHRoaXMuYnJvYWRj
YXN0TGlzdCgtMSwgLTEpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0TWVuKDEpOwogICAgICAgIHRo
aXMucmVzZXRGcmFtZXMoKTsKICAgICAgICB0aGlzLmVhc2VMYXRlbmNpZXMoKTsKICAgICAgICB0
aGlzLmJyb2FkY2FzdEdhbWVTZXR0aW5nKC0xKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdCgnPG5l
eHRzdGFnZT48L25leHRzdGFnZT4nKTsKICAgICAgfQogICAgfQogIH0KCiAgYWZ0ZXJQYWdlQ2hh
bmdlKCkgewogICAgdGhpcy5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICB0aGlzLmJyb2FkY2Fz
dE1lbigxKTsKICAgIHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwogICAgdGhpcy5icm9h
ZGNhc3RTdGF0dXMoKTsKICB9CgogIGZpZ2h0KHByZXZpb3VzKSB7CiAgICB0aGlzLnN0YXJ0Rmln
aHQoKTsKICAgIHRoaXMucGFnZSA9ICdGSUdIVElORyc7CiAgICB0aGlzLmZpZ2h0aW5nTm93ID0g
dHJ1ZTsKICAgIHRoaXMucHJldmlvdXNQYWdlID0gcHJldmlvdXM7CiAgICBmb3IgKGNvbnN0IHNs
b3Qgb2YgdGhpcy5zbG90cykgeyBzbG90LnN0ZXBzID0gW107IHNsb3QudGltZXMgPSBbXTsgfQog
ICAgdGhpcy5qb3QoYGZpZ2h0IHN0YXJ0czogJHt0aGlzLmRlc2NyaWJlRmlnaHQoKX1gKTsKICAg
IHRoaXMuYnJvYWRjYXN0TGlzdCgtMSwgLTEpOwogICAgdGhpcy5icm9hZGNhc3RNZW4oMSk7CiAg
ICB0aGlzLnJlc2V0RnJhbWVzKCk7CiAgICB0aGlzLmVhc2VMYXRlbmNpZXMoKTsKICAgIHRoaXMu
YnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwogICAgdGhpcy5icm9hZGNhc3RTdGF0dXMoKTsKICB9
CgogIHF1aXRUb01lbnUoKSB7CiAgICB0aGlzLmpvdChgZmlnaHQgZW5kcyAoYmFjayB0byB0aGUg
bWVudXMpJHt0aGlzLm91dE9mU3RlcCA/ICcgYWZ0ZXIgZ29pbmcgb3V0IG9mIHN0ZXAnIDogJyd9
OyBsYXN0IHBhY2tldHMgJHt0aGlzLm9ubGluZSgpLm1hcCgoc2xvdCkgPT4gYCR7c2xvdC5uYW1l
fSAke3Nsb3QubGFzdFBhY2tldH1gKS5qb2luKCcsICcpfWApOwogICAgaWYgKHRoaXMubW9kZSA9
PT0gJ1ZTTU9ERScpIHRoaXMuZW50ZXJQYWdlKCdDSEFSTUVOVScsICdGSUdIVElORycpOwogICAg
ZWxzZSBpZiAodGhpcy5tb2RlID09PSAnU1RPUllNT0RFJykgdGhpcy5lbnRlclBhZ2UoJ1NUT1JZ
TUVOVScsICdGSUdIVElORycpOwogICAgZWxzZSBpZiAodGhpcy5tb2RlID09PSAnQkFUVExFTU9E
RScpIHRoaXMuZW50ZXJQYWdlKCdCQVRUTEVTRVRUSU5HTUVOVScsICdGSUdIVElORycpOwogICAg
dGhpcy5xdWl0QnJvYWRjYXN0cygpOwogIH0KCiAgcXVpdEJyb2FkY2FzdHMoKSB7CiAgICB0aGlz
LnJlc2V0RnJhbWVzKCk7CiAgICB0aGlzLmJyb2FkY2FzdFN0YXR1cygpOwogICAgdGhpcy5icm9h
ZGNhc3RMaXN0KC0xLCAtMSk7CiAgICB0aGlzLmJyb2FkY2FzdE1lbigxKTsKICAgIHRoaXMucmVz
ZXRGcmFtZXMoKTsKICAgIHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwogICAgdGhpcy5i
cm9hZGNhc3RTdGF0dXMoKTsKICB9CgogIC8vIFRoZSBmcmFtZSBzZW5kZXJzIChhdiwgb25lIHBl
ciBjb21wdXRlcik6IGV2ZXJ5IDEwIG1zOyBhIHNlbmQgaXMgZHVlIGFmdGVyIGFub3RoZXIgZ2Ft
ZSdzIHBhY2tldAogIC8vIGFuZCwgYmVzaWRlcywgZXZlcnkgMTAwIHRvIDIwMCBtcy4KICBmbHVz
aFRpY2soKSB7CiAgICBpZiAodGhpcy5zdGFydGluZykgcmV0dXJuOwogICAgZm9yIChsZXQgaW5k
ZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgY29uc3Qgc2xvdCA9
IHRoaXMuc2xvdHNbaW5kZXhdOwogICAgICBzbG90LnRpY2tDb3VudCA9IChzbG90LnRpY2tDb3Vu
dCB8fCAwKSArIDE7CiAgICAgIGlmIChzbG90LnRpY2tDb3VudCA9PT0gMjApIHsKICAgICAgICBz
bG90LnRpY2tDb3VudCA9IHRoaXMubmV4dEludCgxMCk7CiAgICAgICAgc2xvdC5mbHVzaGVzICs9
IDE7CiAgICAgIH0KICAgICAgaWYgKHNsb3QuZmx1c2hlcyA8PSAwKSBjb250aW51ZTsKICAgICAg
aWYgKHNsb3QuZmlnaHRpbmcgJiYgc2xvdC5jb25uZWN0aW9uKSBzbG90LmNvbm5lY3Rpb24uc2Vu
ZEZyYW1lcygpOwogICAgICBzbG90LmZsdXNoZXMgLT0gMTsKICAgIH0KICB9CgogIC8vIFRoZSB3
YXRjaGRvZyAoYUEpOiBwaW5ncyBxdWlldCBnYW1lcywgYW5kIHRha2VzIG91dCBnYW1lcyBzaWxl
bnQgZm9yIDM1IHMgKG9yIGlkbGUgdG9vIGxvbmcpLgogIHdhdGNoZG9nKCkgewogICAgY29uc3Qg
bm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRT
OyBpbmRleCArPSAxKSB7CiAgICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3RzW2luZGV4XTsKICAg
ICAgaWYgKCFzbG90Lm9ubGluZSkgY29udGludWU7CiAgICAgIGNvbnN0IGFmayA9IHRoaXMuYWZr
TWludXRlcyAqIDYwMDAwOwogICAgICBpZiAoc2xvdC5sYXN0TWVzc2FnZSA8IG5vdyAtIDM1MDAw
IHx8IChhZmsgPiA2MDAwMCAmJiBzbG90Lmxhc3RBY3RpdmUgPCBub3cgLSBhZmspKSB7CiAgICAg
ICAgdGhpcy5sb2coYGhmIHJvb20gJHt0aGlzLm51bWJlcn06ICR7c2xvdC5uYW1lfSAke3Nsb3Qu
bGFzdE1lc3NhZ2UgPCBub3cgLSAzNTAwMCA/ICd0aW1lZCBvdXQnIDogJ3dhcyBpZGxlJ31gKTsK
ICAgICAgICB0aGlzLmpvdChgJHtzbG90Lm5hbWV9ICR7c2xvdC5sYXN0TWVzc2FnZSA8IG5vdyAt
IDM1MDAwID8gYHRpbWVkIG91dCAoc2lsZW50IGZvciAke01hdGgucm91bmQoKG5vdyAtIHNsb3Qu
bGFzdE1lc3NhZ2UpIC8gMTAwMCl9IHMpYCA6ICd3YXMgaWRsZSB0b28gbG9uZyd9JHt0aGlzLmZp
Z2h0aW5nTm93ID8gYCBkdXJpbmcgYSBmaWdodCwgbGFzdCBwYWNrZXQgJHtzbG90Lmxhc3RQYWNr
ZXR9YCA6ICcnfWApOwogICAgICAgIGNvbnN0IGNvbm5lY3Rpb24gPSBzbG90LmNvbm5lY3Rpb247
CiAgICAgICAgY29ubmVjdGlvbi5sZWF2ZSgpOwogICAgICAgIGNvbm5lY3Rpb24ua2lja2VkID0g
dHJ1ZTsKICAgICAgICBjb25uZWN0aW9uLmNsb3NlKCk7CiAgICAgICAgY29udGludWU7CiAgICAg
IH0KICAgICAgaWYgKHNsb3QubGFzdE1lc3NhZ2UgPCBub3cgLSAyMDAwMCkgc2xvdC5jb25uZWN0
aW9uLnNlbmQoJzxwaW5nPjwvcGluZz4nKTsKICAgIH0KICB9CgogIC8vIFRoZSBsaW5lIHRoZSBy
b29tIGxpc3Qgc2hvd3MgZm9yIHRoaXMgcm9vbS4KICBwZW9wbGUoKSB7CiAgICByZXR1cm4gdGhp
cy5vbmxpbmUoKS5tYXAoKHNsb3QpID0+IGAke3Nsb3QubmFtZX0oJHtzbG90LmxhdGVuY3lTaG93
biAtIDF9KWApLmpvaW4oJywgJyk7CiAgfQp9CgovLyAtLS0tIE9uZSBjb21wdXRlciBpbiBhIHJv
b20gKHRoZSBvcmlnaW5hbCdzIHRocmVhZCAiaSIpIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0KCmNvbnN0IE1FU1NBR0VfTElNSVQgPSAxNjM4NDsgLy8gYSBwYWdl
J3Mgb3duIG1lc3NhZ2UgKGNvbnRyb2wpLCBpbiBjaGFyYWN0ZXJzCgpjbGFzcyBIZkNvbm5lY3Rp
b24gewogIC8vIHNvY2tldDogeyB3cml0ZSh0ZXh0KSwgY2xvc2UoKSwgc2F5KG1lc3NhZ2UpPyB9
OyBmZWVkIGl0IHRoZSByZWNlaXZlZCBieXRlcyB3aXRoIHJlY2VpdmUoKSwgdGhlIHBhZ2UncyBv
d24KICAvLyBtZXNzYWdlcyAodGV4dCwgd2l0aCBkaXJlY3QpIHdpdGggY29udHJvbCgpLCBhbmQg
Y2xvc2VkKCkgYXQgdGhlIGVuZC4KICBjb25zdHJ1Y3Rvcihyb29tLCBzb2NrZXQsIHsgYWRkcmVz
cyA9ICcnLCBidWlsZCA9ICcnLCBpZCA9ICcnLCBkaXJlY3QgPSBmYWxzZSB9ID0ge30pIHsKICAg
IHRoaXMucm9vbSA9IHJvb207CiAgICB0aGlzLnNvY2tldCA9IHNvY2tldDsKICAgIHRoaXMuYWRk
cmVzcyA9IGFkZHJlc3M7CiAgICB0aGlzLmJ1aWxkID0gYnVpbGQ7IC8vIHRoZSBwYWdlJ3MgbW92
aWUgYW5kIFJ1ZmZsZSAoYWNjZXB0c0J1aWxkKQogICAgdGhpcy5pZCA9IGlkOyAvLyB0aGUgcm9v
bSdzIG5hbWUgZm9yIHRoaXMgY29ubmVjdGlvbiwgZm9yIHRoZSBwYWdlcycgZGlyZWN0IGxpbmtz
CiAgICB0aGlzLmRpcmVjdCA9IEJvb2xlYW4oZGlyZWN0ICYmIGlkKTsgLy8gdGhlIHBhZ2UgcGFz
c2VzIGZyYW1lcyBkaXJlY3RseSB0b28gKFJvb20gIkRpcmVjdCBsaW5rcyIpCiAgICB0aGlzLmxp
bmtzID0gbmV3IE1hcCgpOyAvLyBpZCBvZiBhbm90aGVyIGdhbWUgLT4gcm91bmQgdHJpcCBpbiBt
cyAob3IgbnVsbCksIHRoZSBkaXJlY3QgbGlua3MgdGhpcyBwYWdlIHJlcG9ydGVkCiAgICB0aGlz
LmluZGV4ID0gLTE7IC8vIG4KICAgIHRoaXMubmFtZSA9ICcnOyAvLyBvCiAgICB0aGlzLmNjID0g
Jyc7IC8vIHAKICAgIHRoaXMucGxheWVycyA9IFsnJywgJycsICcnXTsgLy8gcgogICAgdGhpcy5s
YXN0RnJhbWUgPSAtMTsgLy8gczogdGhlIGxhc3QgZnJhbWUgb2YgdGhpcyBnYW1lJ3MsIGluIG9y
ZGVyCiAgICB0aGlzLm5leHRGcmFtZSA9IDA7IC8vIHQ6IHRoZSBuZXh0IGZyYW1lIHRvIHNlbmQg
dGhpcyBnYW1lCiAgICB0aGlzLnF1ZXVlZCA9ICcnOyAvLyB2OiA8cnBjPiBsaW5lcyBmcm9tIHRo
ZSBvdGhlcnMsIHNlbnQgd2l0aCB0aGUgbmV4dCBmcmFtZXMgKG5vbmUgbm93OiBSb29tLmNoZWNr
U3RlcCkKICAgIHRoaXMuY2hlYXQgPSAwOyAvLyB4CiAgICB0aGlzLmtpY2tlZCA9IGZhbHNlOyAv
LyBiCiAgICB0aGlzLmVuZGVkID0gZmFsc2U7CiAgICB0aGlzLmxpbmVzID0gW107CiAgICB0aGlz
LndhaXRpbmcgPSBudWxsOwogICAgdGhpcy5idWZmZXIgPSBCdWZmZXIuYWxsb2MoMCk7CiAgICBy
b29tLmNvbm5lY3Rpb25zLmFkZCh0aGlzKTsKICAgIHRoaXMuZG9uZSA9IHRoaXMucnVuKCk7CiAg
fQoKICAvLyAtLS0tIGJ5dGVzIGluIGFuZCBvdXQKICByZWNlaXZlKGNodW5rKSB7CiAgICBpZiAo
dGhpcy5lbmRlZCkgcmV0dXJuOwogICAgdGhpcy5idWZmZXIgPSB0aGlzLmJ1ZmZlci5sZW5ndGgg
PyBCdWZmZXIuY29uY2F0KFt0aGlzLmJ1ZmZlciwgY2h1bmtdKSA6IEJ1ZmZlci5mcm9tKGNodW5r
KTsKICAgIGxldCBzdGFydCA9IDA7CiAgICBmb3IgKGxldCBhdCA9IHRoaXMuYnVmZmVyLmluZGV4
T2YoMTApOyBhdCA+PSAwOyBhdCA9IHRoaXMuYnVmZmVyLmluZGV4T2YoMTAsIHN0YXJ0KSkgewog
ICAgICBsZXQgbGluZSA9IHRoaXMuYnVmZmVyLnRvU3RyaW5nKCd1dGY4Jywgc3RhcnQsIGF0KTsK
ICAgICAgaWYgKGxpbmUuZW5kc1dpdGgoJ1xyJykpIGxpbmUgPSBsaW5lLnNsaWNlKDAsIC0xKTsK
ICAgICAgc3RhcnQgPSBhdCArIDE7CiAgICAgIHRoaXMucHVzaExpbmUobGluZSk7CiAgICB9CiAg
ICB0aGlzLmJ1ZmZlciA9IHRoaXMuYnVmZmVyLnN1YmFycmF5KHN0YXJ0KTsKICAgIGlmICh0aGlz
LmJ1ZmZlci5sZW5ndGggPiAyNjIxNDQpIHRoaXMuY2xvc2UoKTsgLy8gbm8gbGluZSBpcyB0aGF0
IGxvbmcKICB9CgogIGNsb3NlZCgpIHsKICAgIGlmICh0aGlzLmVuZGVkKSByZXR1cm47CiAgICB0
aGlzLmVuZGVkID0gdHJ1ZTsKICAgIHRoaXMucHVzaExpbmUobnVsbCk7CiAgfQoKICBwdXNoTGlu
ZShsaW5lKSB7CiAgICBpZiAodGhpcy53YWl0aW5nKSB7CiAgICAgIGNvbnN0IHJlc29sdmUgPSB0
aGlzLndhaXRpbmc7CiAgICAgIHRoaXMud2FpdGluZyA9IG51bGw7CiAgICAgIHJlc29sdmUobGlu
ZSk7CiAgICB9IGVsc2UgewogICAgICB0aGlzLmxpbmVzLnB1c2gobGluZSk7CiAgICB9CiAgfQoK
ICByZWFkTGluZSgpIHsgLy8gQnVmZmVyZWRSZWFkZXIucmVhZExpbmU6IG51bGwgYXQgdGhlIGVu
ZAogICAgaWYgKHRoaXMubGluZXMubGVuZ3RoKSByZXR1cm4gUHJvbWlzZS5yZXNvbHZlKHRoaXMu
bGluZXMuc2hpZnQoKSk7CiAgICBpZiAodGhpcy5lbmRlZCkgcmV0dXJuIFByb21pc2UucmVzb2x2
ZShudWxsKTsKICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVzb2x2ZSkgPT4geyB0aGlzLndhaXRp
bmcgPSByZXNvbHZlOyB9KTsKICB9CgogIHNlbmQodGV4dCkgeyAvLyBpLmEoU3RyaW5nKQogICAg
aWYgKHRoaXMuZW5kZWQpIHJldHVybjsKICAgIHRyeSB7IHRoaXMuc29ja2V0LndyaXRlKHRleHQg
KyAnXG4nKTsgfSBjYXRjaCB7IC8qIHRoZSBjbG9zaW5nIGZvbGxvd3MgKi8gfQogIH0KCiAgLy8g
QSBtZXNzYWdlIHRvIHRoZSBwYWdlIGl0c2VsZiAobm90IHRvIHRoZSBnYW1lKSwgZm9yIGl0cyBk
aXJlY3QgbGlua3MuCiAgc2F5KG1lc3NhZ2UpIHsKICAgIGlmICghdGhpcy5kaXJlY3QgfHwgdGhp
cy5lbmRlZCB8fCB0eXBlb2YgdGhpcy5zb2NrZXQuc2F5ICE9PSAnZnVuY3Rpb24nKSByZXR1cm47
CiAgICB0cnkgeyB0aGlzLnNvY2tldC5zYXkobWVzc2FnZSk7IH0gY2F0Y2ggeyAvKiB0aGUgY2xv
c2luZyBmb2xsb3dzICovIH0KICB9CgogIC8vIEEgbWVzc2FnZSBvZiB0aGUgcGFnZSdzIG93bjog
d2hhdCBhbm90aGVyIHBhZ2UgbmVlZHMgdG8gc2V0IHVwIGEgZGlyZWN0IGxpbmsgd2l0aCBpdCAo
cGFzc2VkIG9uKSwgb3IKICAvLyBob3cgaXRzIGxpbmtzIHdlbnQgKGZvciB0aGUgam91cm5hbCku
CiAgY29udHJvbCh0ZXh0KSB7CiAgICBpZiAoIXRoaXMuZGlyZWN0IHx8IHRoaXMuZW5kZWQgfHwg
dGhpcy5pbmRleCA8IDAgfHwgdGV4dC5sZW5ndGggPiBNRVNTQUdFX0xJTUlUKSByZXR1cm47CiAg
ICBsZXQgbWVzc2FnZTsKICAgIHRyeSB7IG1lc3NhZ2UgPSBKU09OLnBhcnNlKHRleHQpOyB9IGNh
dGNoIHsgcmV0dXJuOyB9CiAgICBpZiAoIW1lc3NhZ2UgfHwgdHlwZW9mIG1lc3NhZ2UgIT09ICdv
YmplY3QnKSByZXR1cm47CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKG1lc3Nh
Z2UudCA9PT0gJ3BpbmcnKSB7IC8vIHRoZSBwYWdlIHRpbWVzIGl0cyB3YXkgaGVyZSAoZm9yIGl0
cyBjb3JuZXIgb2YgdGhlIGdhbWUpCiAgICAgIHRoaXMuc2F5KHsgdDogJ3BvbmcnLCBhdDogTnVt
YmVyLmlzRmluaXRlKG1lc3NhZ2UuYXQpID8gbWVzc2FnZS5hdCA6IDAgfSk7CiAgICAgIHJldHVy
bjsKICAgIH0KICAgIGlmIChtZXNzYWdlLnQgPT09ICdmcmFtZXMnKSB7IC8vIGFmdGVyIGEgZmln
aHQ6IGhvdyBtYW55IG9mIHRoZSBvdGhlcnMnIGZyYW1lcyBjYW1lIGRpcmVjdGx5CiAgICAgIGNv
bnN0IGRpcmVjdCA9IE1hdGgubWF4KDAsIE1hdGgudHJ1bmMoTnVtYmVyKG1lc3NhZ2UuZGlyZWN0
KSB8fCAwKSk7CiAgICAgIGNvbnN0IHJlbGF5ZWQgPSBNYXRoLm1heCgwLCBNYXRoLnRydW5jKE51
bWJlcihtZXNzYWdlLnJlbGF5KSB8fCAwKSk7CiAgICAgIGlmIChkaXJlY3QgKyByZWxheWVkID4g
MCkgcm9vbS5qb3QoYCR7dGhpcy5uYW1lfTogJHtkaXJlY3R9IG9mIHRoZSBvdGhlcnMnIGZyYW1l
cyBjYW1lIGRpcmVjdGx5LCAke3JlbGF5ZWR9IHRocm91Z2ggdGhlIHJlbGF5YCk7CiAgICAgIHJl
dHVybjsKICAgIH0KICAgIGNvbnN0IG90aGVyID0gcm9vbS5kaXJlY3RQZWVyKFN0cmluZyhtZXNz
YWdlLnRvIHx8IG1lc3NhZ2Uud2l0aCB8fCAnJykpOwogICAgaWYgKCFvdGhlciB8fCBvdGhlciA9
PT0gdGhpcykgcmV0dXJuOwogICAgaWYgKG1lc3NhZ2UudCA9PT0gJ3NpZ25hbCcpIHsKICAgICAg
b3RoZXIuc2F5KHsgdDogJ3NpZ25hbCcsIGZyb206IHRoaXMuaWQsIGRhdGE6IG1lc3NhZ2UuZGF0
YSB9KTsKICAgIH0gZWxzZSBpZiAobWVzc2FnZS50ID09PSAnbGluaycpIHsKICAgICAgY29uc3Qg
bXMgPSBOdW1iZXIobWVzc2FnZS5tcyk7CiAgICAgIGlmIChtZXNzYWdlLm9wZW4pIHsKICAgICAg
ICBjb25zdCBrbm93biA9IHRoaXMubGlua3MuaGFzKG90aGVyLmlkKTsKICAgICAgICB0aGlzLmxp
bmtzLnNldChvdGhlci5pZCwgTnVtYmVyLmlzRmluaXRlKG1zKSAmJiBtcyA+PSAwID8gTWF0aC5y
b3VuZChtcykgOiBudWxsKTsKICAgICAgICBpZiAoIWtub3duKSByb29tLmpvdChgJHt0aGlzLm5h
bWV9OiBkaXJlY3QgbGluayB0byAke290aGVyLm5hbWV9JHtOdW1iZXIuaXNGaW5pdGUobXMpICYm
IG1zID49IDAgPyBgICgke01hdGgucm91bmQobXMpfSBtcylgIDogJyd9YCk7CiAgICAgIH0gZWxz
ZSBpZiAodGhpcy5saW5rcy5kZWxldGUob3RoZXIuaWQpKSB7CiAgICAgICAgcm9vbS5qb3QoYCR7
dGhpcy5uYW1lfTogZGlyZWN0IGxpbmsgdG8gJHtvdGhlci5uYW1lfSBjbG9zZWRgKTsKICAgICAg
fQogICAgfQogIH0KCiAgY2xvc2UoKSB7CiAgICBpZiAoIXRoaXMuc29ja2V0Q2xvc2VkKSB7CiAg
ICAgIHRoaXMuc29ja2V0Q2xvc2VkID0gdHJ1ZTsKICAgICAgdHJ5IHsgdGhpcy5zb2NrZXQuY2xv
c2UoKTsgfSBjYXRjaCB7IC8qIGFscmVhZHkgY2xvc2VkICovIH0KICAgIH0KICAgIHRoaXMuY2xv
c2VkKCk7CiAgfQoKICBnZXQgc2xvdCgpIHsgcmV0dXJuIHRoaXMucm9vbS5zbG90c1t0aGlzLmlu
ZGV4XTsgfQoKICAvLyAtLS0tIHRoZSBjb252ZXJzYXRpb24KICBhc3luYyBydW4oKSB7CiAgICB0
cnkgewogICAgICBhd2FpdCB0aGlzLmNvbnZlcnNhdGlvbigpOwogICAgfSBjYXRjaCAoZXJyb3Ip
IHsKICAgICAgaWYgKCEoZXJyb3IgaW5zdGFuY2VvZiBYbWxFcnJvcikpIHRoaXMucm9vbS5sb2co
YGhmIHJvb20gJHt0aGlzLnJvb20ubnVtYmVyfTogJHtlcnJvci5zdGFjayB8fCBlcnJvcn1gKTsK
ICAgIH0gZmluYWxseSB7CiAgICAgIHRoaXMubGVhdmUoKTsgLy8gaS5oCiAgICAgIHRoaXMucm9v
bS5jb25uZWN0aW9ucy5kZWxldGUodGhpcyk7CiAgICAgIHRoaXMuY2xvc2UoKTsKICAgIH0KICB9
CgogIGFzeW5jIGNvbnZlcnNhdGlvbigpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAg
ICBhd2FpdCBzbGVlcCgyNTApOwogICAgdGhpcy5zZW5kKCc8aW5pPjwvaW5pPicpOwogICAgYXdh
aXQgc2xlZXAoMjUwKTsKICAgIGlmIChyb29tLmNsb3NlZCkgcmV0dXJuOwogICAgbGV0IGxpbmUg
PSBhd2FpdCB0aGlzLnJlYWRMaW5lKCk7CiAgICBpZiAobGluZSA9PT0gbnVsbCkgcmV0dXJuOwog
ICAgY29uc3Qgam9pbiA9IHBhcnNlWG1sKGxpbmUpOwogICAgY29uc3QgdmVyc2lvbnMgPSBieVRh
Zyhqb2luLCAndmVyJyk7CiAgICBpZiAoIXZlcnNpb25zLmxlbmd0aCkgcmV0dXJuOwogICAgaWYg
KGludCh2YWx1ZU9mKHZlcnNpb25zWzBdKSkgIT09IFZFUlNJT04pIHJldHVybiB0aGlzLnJlZnVz
ZSgndicpOwogICAgaWYgKCFyb29tLmFjY2VwdHNCdWlsZCh0aGlzLmJ1aWxkKSkgewogICAgICBy
b29tLmxvZyhgaGYgcm9vbSAke3Jvb20ubnVtYmVyfTogYSBnYW1lIG9mIGFub3RoZXIgYnVpbGQg
KCR7dGhpcy5idWlsZCB8fCAnbm9uZSd9LCB0aGUgcm9vbSBoYXMgJHtyb29tLmJ1aWxkfSkgdHVy
bmVkIGF3YXlgKTsKICAgICAgcmV0dXJuIHRoaXMucmVmdXNlKCd2Jyk7CiAgICB9CiAgICBpZiAo
cm9vbS5jb25uZWN0ZWQgPj0gcm9vbS5saW1pdCkgcmV0dXJuIHRoaXMucmVmdXNlKCdmJyk7CiAg
ICBpZiAoIXJvb20uYWxsb3dKb2luV2hlbkZpZ2h0aW5nICYmIHJvb20uZmlnaHRpbmdOb3cpIHJl
dHVybiB0aGlzLnJlZnVzZSgncCcpOwogICAgaWYgKHJvb20ucGFzc3dvcmQpIHsKICAgICAgdGhp
cy5zZW5kKCc8cmVxX3B3PjwvcmVxX3B3PicpOwogICAgICBsaW5lID0gYXdhaXQgdGhpcy5yZWFk
TGluZSgpOwogICAgICBpZiAobGluZSA9PT0gbnVsbCkgcmV0dXJuOwogICAgICBpZiAocm9vbS5w
YXNzd29yZCAhPT0gdGFnVmFsdWUocGFyc2VYbWwobGluZSksICdwd2QnKSkgcmV0dXJuIHRoaXMu
cmVmdXNlKCdwd2QnKTsKICAgIH0KICAgIGNvbnN0IGxhdGVuY3kgPSBhd2FpdCB0aGlzLm1lYXN1
cmUoKTsKICAgIGlmIChsYXRlbmN5ID09PSBudWxsKSByZXR1cm47CiAgICBpZiAocm9vbS5sYXRl
bmN5TGltaXQgIT09IC0xICYmIGxhdGVuY3kgPiByb29tLmxhdGVuY3lMaW1pdCkgcmV0dXJuIHRo
aXMucmVmdXNlKCdsJyk7CiAgICB0aGlzLnNlbmQoYDxtYXhjbGllbnRzPjxtYXhjbGllbnRzPiR7
cm9vbS5saW1pdH08L21heGNsaWVudHM+PC9tYXhjbGllbnRzPmApOwogICAgdGhpcy5zZW5kKGA8
cnA+PHJwPiR7cm9vbS5zZWVkfTwvcnA+PC9ycD5gKTsKICAgIGZvciAobGV0IHBhcnQgPSAwOyBw
YXJ0IDwgMTA7IHBhcnQgKz0gMSkgewogICAgICBsZXQgdGV4dCA9IGA8cmFuZD48aT4ke3BhcnQg
KiA1MDB9PC9pPmA7CiAgICAgIGZvciAobGV0IGsgPSAwOyBrIDwgNTAwOyBrICs9IDEpIHRleHQg
Kz0gYDxuPiR7cm9vbS50YWJsZVtrICsgcGFydCAqIDUwMF19PC9uPmA7CiAgICAgIHRoaXMuc2Vu
ZCh0ZXh0ICsgJzwvcmFuZD4nKTsKICAgIH0KICAgIHRoaXMuc2VuZCgnPHJlcV9pbmZvPjwvcmVx
X2luZm8+Jyk7CiAgICBsaW5lID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpOwogICAgaWYgKGxpbmUg
PT09IG51bGwgfHwgcm9vbS5jbG9zZWQpIHJldHVybjsKICAgIHJvb20ucmVjb3VudCgpOwogICAg
aWYgKHJvb20uY29ubmVjdGVkID49IHJvb20ubGltaXQpIHJldHVybiB0aGlzLnJlZnVzZSgnZicp
OwogICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsK
ICAgICAgaWYgKCFyb29tLnNsb3RzW2luZGV4XS5vbmxpbmUpIHsgdGhpcy5pbmRleCA9IGluZGV4
OyBicmVhazsgfQogICAgfQogICAgaWYgKHRoaXMuaW5kZXggPCAwKSByZXR1cm4gdGhpcy5yZWZ1
c2UoJ2YnKTsKICAgIGNvbnN0IGluZm8gPSBwYXJzZVhtbChsaW5lKTsKICAgIHRoaXMubmFtZSA9
IHRhZ1ZhbHVlKGluZm8sICduYW1lJyk7CiAgICBjb25zdCBjY3MgPSBieVRhZyhpbmZvLCAnY2Mn
KTsKICAgIHRoaXMuY2MgPSBjY3MubGVuZ3RoID8gdmFsdWVPZihjY3NbMF0pIDogJyc7CiAgICBj
b25zdCBzbG90ID0gdGhpcy5zbG90OwogICAgZm9yIChsZXQgayA9IDA7IGsgPCAzOyBrICs9IDEp
IHRoaXMucGxheWVyc1trXSA9IHRhZ1ZhbHVlKGluZm8sICdwJywgayk7CiAgICBmb3IgKGxldCBr
ID0gMDsgayA8IDMwOyBrICs9IDEpIHsKICAgICAgc2xvdC5sZXZlbHNba10gPSBpbnQodGFnVmFs
dWUoaW5mbywgJ2wnLCBrKSk7CiAgICAgIGlmIChzbG90LmxldmVsc1trXSA+IE1BWF9MRVZFTCkg
dGhpcy5jaGVhdCA9IDE7CiAgICB9CiAgICBzbG90LmxldmVsc1syMF0gPSBzbG90LmxldmVsc1s4
XTsKICAgIHNsb3QubmFtZSA9IHRoaXMubmFtZTsKICAgIHNsb3QuY2MgPSB0aGlzLmNjOwogICAg
c2xvdC5jb3VudHJ5ID0gdGhpcy5jYyB8fCAndW5rbm93bic7CiAgICBzbG90LnBsYXllcnMgPSBb
Li4udGhpcy5wbGF5ZXJzXTsKICAgIHNsb3QubGFzdE1lc3NhZ2UgPSBzbG90Lmxhc3RBY3RpdmUg
PSBEYXRlLm5vdygpOwogICAgc2xvdC5jb25uZWN0aW9uID0gdGhpczsKICAgIHNsb3Qub25saW5l
ID0gdHJ1ZTsKICAgIHNsb3QucGF1c2VkID0gZmFsc2U7CiAgICBzbG90Lmhhc1BsYXllciA9IGZh
bHNlOwogICAgc2xvdC5sYXRlbmN5ID0gc2xvdC5sYXRlbmN5VGFyZ2V0ID0gc2xvdC5sYXRlbmN5
U2hvd24gPSBsYXRlbmN5OwogICAgc2xvdC5wYWdlID0gJ1dBSVRST09NJzsKICAgIHNsb3QuYWRt
aW4gPSBmYWxzZTsKICAgIHJvb20ucmVjb3VudCgpOwogICAgdGhpcy5zZW5kU2V0dGluZygtMSk7
CiAgICB0aGlzLnNlbmRHYW1lU2V0dGluZygtMSk7CiAgICB0aGlzLnNlbmRMaXN0KC0xLCAtMSk7
CiAgICB0aGlzLnNlbmRNZW4oMSk7CiAgICBpZiAoIXJvb20uZmlnaHRpbmdOb3cpIHsKICAgICAg
aWYgKHJvb20ucGFnZSAhPT0gJ1dBSVRST09NJykgewogICAgICAgIGlmIChyb29tLm1vZGUgPT09
ICdWU01PREUnKSByb29tLnBhZ2UgPSAnQ0hBUk1FTlUnOwogICAgICB9IGVsc2UgewogICAgICAg
IHJvb20ucGFnZSA9ICdXQUlUUk9PTSc7CiAgICAgICAgcm9vbS5tb2RlID0gJ1dBSVRST09NJzsK
ICAgICAgfQogICAgfQogICAgcm9vbS5icm9hZGNhc3RTdGF0dXMoKTsKICAgIHJvb20ubG9nKGBo
ZiByb29tICR7cm9vbS5udW1iZXJ9OiAke3RoaXMubmFtZX0gKGxhdGVuY3kgJHtsYXRlbmN5IC0g
MX0pIGpvaW5zYCk7CiAgICByb29tLmpvdChgJHt0aGlzLm5hbWV9IGpvaW5zIChsYXRlbmN5ICR7
bGF0ZW5jeSAtIDF9LCBidWlsZCAke3RoaXMuYnVpbGQgfHwgJ3Vua25vd24nfSwgZnJvbSAke3Ro
aXMuYWRkcmVzcyB8fCAnPyd9JHt0aGlzLmRpcmVjdCA/ICcsIGRpcmVjdCBsaW5rcycgOiAnJ30p
JHtyb29tLmZpZ2h0aW5nTm93ID8gJyBkdXJpbmcgYSBmaWdodCcgOiAnJ31gKTsKICAgIHJvb20u
YnJvYWRjYXN0TGlzdCh0aGlzLmluZGV4LCAtMSk7CiAgICByb29tLmFubm91bmNlUGVlcnMoKTsK
ICAgIGlmIChyb29tLmNvbm5lY3RlZCA9PT0gMiAmJiByb29tLmZpZ2h0aW5nTm93KSB7CiAgICAg
IHJvb20uY291bnRkb3duLm9uID0gdHJ1ZTsKICAgICAgcm9vbS5jb3VudGRvd24uYWN0aW9uID0g
J3F1aXRnYW1lJzsKICAgICAgcm9vbS5jb3VudGRvd24uY291bnQgPSAxOwogICAgfQogICAgdGhp
cy5ub3RpY2UoJ1Jvb20gU2VydmVyIHYwLjcrLjxiciAvPlR5cGUgL2hlbHAgZm9yIGNvbW1hbmRz
LicpOwogICAgaWYgKHJvb20uZmlnaHRpbmdOb3cgJiYgcm9vbS5jb25uZWN0ZWQgPiAyKSB7CiAg
ICAgIGlmIChyb29tLm1vZGUgPT09ICdWU01PREUnKSB0aGlzLm5vdGljZSgnUGxheWVycyBhcmUg
aW4gVlMgTW9kZS4nKTsKICAgICAgZWxzZSBpZiAocm9vbS5tb2RlID09PSAnQkFUVExFTU9ERScp
IHRoaXMubm90aWNlKCdQbGF5ZXJzIGFyZSBpbiBCYXR0bGUgTW9kZS4nKTsKICAgICAgZWxzZSBp
ZiAocm9vbS5tb2RlID09PSAnU1RPUllNT0RFJykgdGhpcy5ub3RpY2UoYFBsYXllcnMgYXJlIGlu
IFN0b3J5ICR7cm9vbS5zdG9yeSArIDF9YCk7CiAgICB9CiAgICBpZiAodGhpcy5jaGVhdCA9PT0g
MSkgcmV0dXJuOyAvLyBsZXZlbHMgYWJvdmUgdGhlIGdhbWUncyBoaWdoZXN0OiBvdXQgKHRoZSBm
aW5hbGx5IGxlYXZlcykKICAgIGZvciAobGluZSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKTsgbGlu
ZSAhPT0gbnVsbDsgbGluZSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKSkgewogICAgICBpZiAodGhp
cy5pbmRleCA8IDApIHJldHVybjsKICAgICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgICAg
c2xvdC5sYXN0TWVzc2FnZSA9IG5vdzsKICAgICAgaWYgKGxpbmUgIT09ICc8cGluZ29rPjwvcGlu
Z29rPicpIHNsb3QubGFzdEFjdGl2ZSA9IG5vdzsKICAgICAgaWYgKHRoaXMua2lja2VkIHx8IHRo
aXMuY2hlYXQgPT09IDEpIHJldHVybjsKICAgICAgYXdhaXQgdGhpcy5oYW5kbGUobGluZSk7CiAg
ICAgIGlmICh0aGlzLmtpY2tlZCkgcmV0dXJuOwogICAgfQogIH0KCiAgcmVmdXNlKHJlYXNvbikg
ewogICAgdGhpcy5zZW5kKGA8ZXJyb3I+PHJlYXNvbj4ke3JlYXNvbn08L3JlYXNvbj48L2Vycm9y
PmApOwogICAgcmV0dXJuIHRoaXMucmVhZExpbmUoKTsKICB9CgogIC8vIFRlbiBwaW5nczogdGhl
IGxhdGVuY3kgaXMgdGhlIHNob3J0ZXN0IHJvdW5kIHRyaXAsIGluIGZyYW1lcyAoYSBtdWx0aXBs
ZSBvZiBTVEVQKSwgd2l0aCBhIG1hcmdpbi4KICBhc3luYyBtZWFzdXJlKCkgewogICAgbGV0IGJl
c3QgPSA1MDAwOwogICAgZm9yIChsZXQgayA9IDA7IGsgPCAxMDsgayArPSAxKSB7CiAgICAgIGNv
bnN0IHNlbnQgPSBEYXRlLm5vdygpOwogICAgICB0aGlzLnNlbmQoJzxwaW5nPjwvcGluZz4nKTsK
ICAgICAgaWYgKGF3YWl0IHRoaXMucmVhZExpbmUoKSA9PT0gbnVsbCkgcmV0dXJuIG51bGw7CiAg
ICAgIGNvbnN0IHRvb2sgPSBEYXRlLm5vdygpIC0gc2VudDsKICAgICAgaWYgKHRvb2sgPCBiZXN0
KSBiZXN0ID0gdG9vazsKICAgICAgYXdhaXQgc2xlZXAodG9vayA8IDUwMCA/IHRvb2sgOiA1MDAp
OwogICAgfQogICAgaWYgKGJlc3QgPD0gMCkgYmVzdCA9IDE7CiAgICBiZXN0ICs9IDE1OwogICAg
cmV0dXJuIFNURVAgKyBNYXRoLmNlaWwoKGJlc3QgKiAxLjcgKyAwLjE2KSAvIDMzIC8gU1RFUCkg
KiBTVEVQOwogIH0KCiAgYXN5bmMgaGFuZGxlKGxpbmUpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlz
LnJvb207CiAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90OwogICAgY29uc3QgZG9jID0gcGFyc2VY
bWwobGluZSk7CiAgICBjb25zdCBraW5kID0gZG9jLm5hbWU7CiAgICBpZiAoa2luZCA9PT0gJ2Yn
KSB7IC8vIGEgZnJhbWUgb2YgdGhpcyBnYW1lJ3Mga2V5cwogICAgICBjb25zdCBmcmFtZSA9IGlu
dCh0YWdWYWx1ZShkb2MsICdpJykpOwogICAgICBpZiAoZnJhbWUgPT09IDEpIHJvb20ud2luUmVw
b3J0ZWQgPSBmYWxzZTsKICAgICAgaWYgKHRoaXMubGFzdEZyYW1lICsgMSA9PT0gZnJhbWUpIHsK
ICAgICAgICBzbG90LmZyYW1lc1tmcmFtZSAlIEZSQU1FU19LRVBUXSA9IGZpeENvbW1hbmROdW1i
ZXIobGluZSk7CiAgICAgICAgdGhpcy5sYXN0RnJhbWUgPSBmcmFtZTsKICAgICAgfQogICAgICBy
ZXR1cm47CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ3BrJykgeyAvLyB0aGUgZW5kIG9mIGEgcGFj
a2V0OiB0aGUgb3RoZXJzIG1heSBnZXQgdGhpcyBnYW1lJ3MgZnJhbWVzCiAgICAgIHNsb3QubGFz
dFBhY2tldCA9IHRoaXMubGFzdEZyYW1lOwogICAgICB0aGlzLnJlcXVlc3RGbHVzaGVzKHRydWUp
OwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ3QnKSB7CiAgICAgIHNsb3Qu
dGltZXMucHVzaChpbnQodGFnVmFsdWUoZG9jLCAnZCcpKSk7CiAgICAgIGlmIChzbG90LnRpbWVz
Lmxlbmd0aCA+IDIwKSBzbG90LnRpbWVzLnNoaWZ0KCk7CiAgICAgIHJldHVybjsKICAgIH0KICAg
IGlmIChraW5kID09PSAncnBjJykgewogICAgICByb29tLmNoZWNrU3RlcCh0aGlzLmluZGV4LCBp
bnQodGFnVmFsdWUoZG9jLCAnY2wnKSksIGludCh0YWdWYWx1ZShkb2MsICdycCcpKSk7CiAgICAg
IHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnY2hhdCcpIHsKICAgICAgY29uc3QgZnJv
bSA9IGludCh0YWdWYWx1ZShkb2MsICdjJykpOwogICAgICBpZiAoZnJvbSA8IDAgfHwgZnJvbSA+
PSBTTE9UUykgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBzdWNoIGNvbXB1dGVyJyk7CiAgICAgIGlm
ICh0aGlzLmNvbW1hbmQodGFnVmFsdWUoZG9jLCAnbScpKSkgcm9vbS5icm9hZGNhc3QobGluZSk7
CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAncGF1c2VnYW1lJyB8fCBraW5k
ID09PSAncmVzdW1lZ2FtZScpIHsKICAgICAgc2xvdC5wYXVzZWQgPSBraW5kID09PSAncGF1c2Vn
YW1lJzsKICAgICAgaWYgKHJvb20uZmlnaHRpbmdOb3cpIHJvb20uam90KGAke3Nsb3QubmFtZX0g
JHtraW5kID09PSAncGF1c2VnYW1lJyA/ICdwYXVzZXMnIDogJ3Jlc3VtZXMnfSBhdCBmcmFtZSAk
e3Nsb3QubGFzdFBhY2tldH1gKTsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAg
ICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnc3RhcnRjb3VudCcpIHJldHVybiB0
aGlzLnN0YXJ0Q291bnQoZG9jKTsKICAgIGlmIChraW5kID09PSAnY2FuY2VsY291bnQnKSB7CiAg
ICAgIGNvbnN0IGNvdW50ZG93biA9IHJvb20uY291bnRkb3duOwogICAgICBpZiAoY291bnRkb3du
Lm9uICYmIChjb3VudGRvd24uYWN0aW9uID09PSAnY2xpY2tmaWdodCcgfHwgY291bnRkb3duLmFj
dGlvbiA9PT0gdGFnVmFsdWUoZG9jLCAnYWN0aW9uJykpKSB7CiAgICAgICAgY291bnRkb3duLm9u
ID0gZmFsc2U7CiAgICAgICAgY291bnRkb3duLmFjdGlvbiA9ICcnOwogICAgICAgIGNvdW50ZG93
bi5jb3VudCA9IENPVU5URE9XTjsKICAgICAgICByb29tLmJyb2FkY2FzdENsaWNrKHRoaXMuaW5k
ZXgsICdjbGlja2NhbmNlbCcpOwogICAgICAgIHJvb20uYnJvYWRjYXN0KCc8Y2FuY2VsY291bnQ+
PC9jYW5jZWxjb3VudD4nKTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoa2lu
ZCA9PT0gJ3NldHRpbmcnKSB7CiAgICAgIGlmIChyb29tLnBhZ2UgPT09ICdXQUlUUk9PTScpIHsK
ICAgICAgICBjb25zdCBhbGxvdyA9IGJ5VGFnKGRvYywgJ3dhaXR3aGVuZmlnaHQnKTsKICAgICAg
ICBpZiAoYWxsb3cubGVuZ3RoKSByb29tLmFsbG93Sm9pbldoZW5GaWdodGluZyA9IHZhbHVlT2Yo
YWxsb3dbMF0pID09PSAnMSc7CiAgICAgICAgcm9vbS5icm9hZGNhc3RTZXR0aW5nKHRoaXMuaW5k
ZXgpOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnZ2FtZXNl
dHRpbmcnKSByZXR1cm4gdGhpcy5nYW1lU2V0dGluZyhkb2MpOwogICAgaWYgKGtpbmQgPT09ICdj
bGlja2JhY2snKSByZXR1cm4gdGhpcy5jbGlja0JhY2soZG9jKTsKICAgIGlmIChraW5kID09PSAn
cGFnZScpIHsKICAgICAgc2xvdC5wYWdlID0gdmFsdWVPZihkb2MpOwogICAgICBzbG90LmZpZ2h0
aW5nID0gc2xvdC5wYWdlID09PSAnRklHSFRJTkcnOwogICAgICByb29tLmJyb2FkY2FzdExpc3Qo
LTEsIC0xKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdpbmZvJykgcmV0
dXJuIHRoaXMudXBkYXRlSW5mbyhkb2MpOwogICAgaWYgKGtpbmQgPT09ICdhZGRwbGF5ZXInKSBy
ZXR1cm4gdGhpcy5hZGRQbGF5ZXIoZG9jKTsKICAgIGlmIChraW5kID09PSAnZGVsbWFuJykgewog
ICAgICBpZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47CiAgICAgIGNvbnN0IGlu
ZGV4ID0gaW50KHZhbHVlT2YoZG9jKSk7CiAgICAgIGNvbnN0IG1hbiA9IHJvb20ubWVuW2luZGV4
XTsKICAgICAgaWYgKCFtYW4pIHRocm93IG5ldyBYbWxFcnJvcignbm8gc3VjaCBtYW4nKTsKICAg
ICAgaWYgKG1hbi5leGlzdHMgJiYgKChtYW4uY29udHJvbGxlciA9PT0gLTEgJiYgIXJvb20uY291
bnRkb3duLm9uKSB8fCBtYW4uY2xpZW50ID09PSB0aGlzLmluZGV4KSkgewogICAgICAgIG1hbi5l
eGlzdHMgPSBmYWxzZTsKICAgICAgICBmb3IgKGNvbnN0IG90aGVyIG9mIHJvb20ubWVuKSBpZiAo
b3RoZXIuZXhpc3RzICYmIG90aGVyLmNvbW1hbmRlciA9PT0gaW5kZXgpIG90aGVyLmV4aXN0cyA9
IGZhbHNlOwogICAgICAgIHJvb20uYnJvYWRjYXN0TWVuKDEpOwogICAgICB9CiAgICAgIHJldHVy
bjsKICAgIH0KICAgIGlmIChraW5kID09PSAnYWRkY29tJykgewogICAgICBpZiAocm9vbS5wYWdl
ICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47CiAgICAgIGlmICghcm9vbS5jb3VudGRvd24ub24gJiYg
dGhpcy5hZGRDb21wdXRlcigpKSB7CiAgICAgICAgdGhpcy5saW1pdE1lbigpOwogICAgICAgIHJv
b20uYnJvYWRjYXN0TWVuKDEpOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChr
aW5kID09PSAnYWRkc29sZGllcicpIHJldHVybiB0aGlzLmFkZFNvbGRpZXIoZG9jKTsKICAgIGlm
IChraW5kID09PSAncmVkb3JhbmRvbScpIHsKICAgICAgaWYgKHJvb20ucGFnZSAhPT0gJ0NIQVJN
RU5VJykgcmV0dXJuOwogICAgICBpZiAoIXJvb20uY291bnRkb3duLm9uKSB7CiAgICAgICAgZm9y
IChsZXQgaW5kZXggPSAwOyBpbmRleCA8IE1FTjsgaW5kZXggKz0gMSkgaWYgKHJvb20ubWVuW2lu
ZGV4XS5leGlzdHMgJiYgcm9vbS5tZW5baW5kZXhdLnJhbmRvbSkgdGhpcy5waWNrQ2hhcmFjdGVy
KGluZGV4KTsKICAgICAgICByb29tLmJyb2FkY2FzdE1lbigwKTsKICAgICAgfQogICAgICByZXR1
cm47CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ21hbnRlYW0nKSB7CiAgICAgIGlmIChyb29tLnBh
Z2UgIT09ICdDSEFSTUVOVScpIHJldHVybjsKICAgICAgY29uc3QgaW5kZXggPSBpbnQodGFnVmFs
dWUoZG9jLCAnaScpKTsKICAgICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhdOwogICAgICBp
ZiAoIW1hbikgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBzdWNoIG1hbicpOwogICAgICBpZiAobWFu
LmV4aXN0cyAmJiAobWFuLmNvbnRyb2xsZXIgPT09IC0xIHx8IG1hbi5jbGllbnQgPT09IHRoaXMu
aW5kZXgpKSB7CiAgICAgICAgY29uc3QgdGVhbSA9IGludCh0YWdWYWx1ZShkb2MsICd0ZWFtJykp
OwogICAgICAgIG1hbi50ZWFtID0gdGVhbTsKICAgICAgICBmb3IgKGNvbnN0IG90aGVyIG9mIHJv
b20ubWVuKSBpZiAob3RoZXIuZXhpc3RzICYmIG90aGVyLmNvbW1hbmRlciA9PT0gaW5kZXgpIG90
aGVyLnRlYW0gPSB0ZWFtOwogICAgICAgIGlmIChyb29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJyAm
JiBtYW4uY29udHJvbGxlciA+PSAwKSB7CiAgICAgICAgICByb29tLm1lbi5mb3JFYWNoKChvdGhl
ciwgaykgPT4geyBpZiAoayAhPT0gaW5kZXggJiYgb3RoZXIuZXhpc3RzICYmIG90aGVyLmNsaWVu
dCA9PT0gbWFuLmNsaWVudCkgb3RoZXIudGVhbSA9IHRlYW07IH0pOwogICAgICAgIH0KICAgICAg
ICByb29tLmJyb2FkY2FzdE1lbigwKTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBp
ZiAoa2luZCA9PT0gJ21hbmNoYXInKSByZXR1cm4gdGhpcy5jaG9vc2VDaGFyYWN0ZXIoZG9jKTsK
ICAgIGlmIChraW5kID09PSAnaW5jcmVhc2VsYXRlbmN5JykgewogICAgICBzbG90LmxhdGVuY3kg
Kz0gMjsKICAgICAgc2xvdC5sYXRlbmN5VGFyZ2V0ICs9IDI7CiAgICAgIHJvb20uYnJvYWRjYXN0
TGlzdCgtMSwgLTEpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ3JlbWVh
c3VyZScpIHsKICAgICAgbGV0IGJlc3QgPSA1MDAwOwogICAgICBmb3IgKGxldCBrID0gMDsgayA8
IDEwOyBrICs9IDEpIHsKICAgICAgICBjb25zdCBzZW50ID0gRGF0ZS5ub3coKTsKICAgICAgICB0
aGlzLnNlbmQoJzxwaW5nPjwvcGluZz4nKTsKICAgICAgICBmb3IgKGxldCByZXBseSA9IGF3YWl0
IHRoaXMucmVhZExpbmUoKTsgcmVwbHkgIT09ICc8cGluZ29rPjwvcGluZ29rPic7IHJlcGx5ID0g
YXdhaXQgdGhpcy5yZWFkTGluZSgpKSB7CiAgICAgICAgICBpZiAocmVwbHkgPT09IG51bGwpIHRo
cm93IG5ldyBYbWxFcnJvcignY2xvc2VkJyk7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHRvb2sg
PSBEYXRlLm5vdygpIC0gc2VudDsKICAgICAgICBpZiAodG9vayA8IGJlc3QpIGJlc3QgPSB0b29r
OwogICAgICAgIGF3YWl0IHNsZWVwKHRvb2sgPCA1MDAgPyB0b29rIDogNTAwKTsKICAgICAgfQog
ICAgICBpZiAoYmVzdCA8PSAwKSBiZXN0ID0gMTsKICAgICAgYmVzdCArPSAxNTsKICAgICAgc2xv
dC5sYXRlbmN5ID0gU1RFUCArIE1hdGguY2VpbCgoYmVzdCAqIDEuNyArIDAuMTYpIC8gMzMgLyBT
VEVQKSAqIFNURVA7CiAgICAgIHNsb3QubGF0ZW5jeVRhcmdldCA9IHNsb3QubGF0ZW5jeTsKICAg
ICAgc2xvdC5sYXRlbmN5U2hvd24gPSBzbG90LmxhdGVuY3k7CiAgICAgIHJvb20uYnJvYWRjYXN0
TGlzdCgtMSwgLTEpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ3N0YXJ0
ZWRnYW1lJykgewogICAgICBzbG90LmZpZ2h0aW5nID0gdHJ1ZTsKICAgICAgc2xvdC5oYXNQbGF5
ZXIgPSBmYWxzZTsKICAgICAgdGhpcy5yZXNldEZyYW1lcygpOwogICAgICBmb3IgKGxldCBrID0g
MDsgayA8IDM7IGsgKz0gMSkgewogICAgICAgIGlmICghcm9vbS5tZW5bdGhpcy5pbmRleCAqIDMg
KyBrXS5leGlzdHMpIHsgc2xvdC5oYXNQbGF5ZXIgPSB0cnVlOyBicmVhazsgfQogICAgICB9CiAg
ICAgIHNsb3Quc3RhcnRlZCA9IHRydWU7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5k
ID09PSAnd2ludGVhbScpIHsKICAgICAgY29uc3QgdGVhbSA9IGludCh0YWdWYWx1ZShkb2MsICd3
aW50ZWFtJykpOwogICAgICBpZiAoIXJvb20ud2luUmVwb3J0ZWQpIHsKICAgICAgICByb29tLndp
blJlcG9ydGVkID0gdHJ1ZTsKICAgICAgICByb29tLmxvZyhgaGYgcm9vbSAke3Jvb20ubnVtYmVy
fTogJHtyb29tLm1vZGV9IHdvbiBieSAke3RlYW19YCk7CiAgICAgICAgcm9vbS5qb3QoYCR7cm9v
bS5tb2RlfSB3b24gYnkgdGVhbSAke3RlYW19IChyZXBvcnRlZCBieSAke3Nsb3QubmFtZX0gYXQg
ZnJhbWUgJHtzbG90Lmxhc3RQYWNrZXR9KWApOwogICAgICB9CiAgICB9CiAgfQoKICAvLyBpLmko
KTogdGhpcyBnYW1lJ3MgcGFja2V0IGNhbWUgKG5vdzogdHJ1ZSkgb3IgaXQgbGVmdDsgZWFjaCBv
dGhlciBmaWdodGluZyBnYW1lIGdldHMgYSBzZW5kLiBUaGUKICAvLyBvcmlnaW5hbCdzIGZyYW1l
IHNlbmRlcnMgbG9va2VkIGV2ZXJ5IDEwIG1zOyBhIHBhY2tldCdzIGZyYW1lcyBnbyBvbiBhdCBv
bmNlIGhlcmUsIHVwIHRvIDEwIG1zIHNvb25lci4KICByZXF1ZXN0Rmx1c2hlcyhub3cgPSBmYWxz
ZSkgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGlmICghcm9vbS5maWdodGluZ05v
dykgcmV0dXJuOwogICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4
ICs9IDEpIHsKICAgICAgY29uc3Qgb3RoZXIgPSByb29tLnNsb3RzW2luZGV4XTsKICAgICAgaWYg
KGluZGV4ID09PSB0aGlzLmluZGV4IHx8ICFvdGhlci5maWdodGluZykgY29udGludWU7CiAgICAg
IGlmIChub3cgJiYgIXJvb20uc3RhcnRpbmcgJiYgb3RoZXIuY29ubmVjdGlvbikgb3RoZXIuY29u
bmVjdGlvbi5zZW5kRnJhbWVzKCk7CiAgICAgIGVsc2Ugb3RoZXIuZmx1c2hlcyArPSAxOwogICAg
fQogIH0KCiAgLy8gaS5iKCk6IHRoZSBmcmFtZXMgb2YgdGhlIG90aGVycyB0aGlzIGdhbWUgaGFz
IG5vdCBoYWQsIGFzIGxvbmcgYXMgZXZlcnkgb3RoZXIgZ2FtZSBzZW50IHRoZW0uCiAgc2VuZEZy
YW1lcygpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBsZXQgdGV4dCA9ICcnOwog
ICAgZm9yICg7OykgewogICAgICBjb25zdCB0ID0gdGhpcy5uZXh0RnJhbWU7CiAgICAgIGxldCBj
b21wbGV0ZSA9IHRydWU7CiAgICAgIGxldCBhbnkgPSBmYWxzZTsKICAgICAgZm9yIChsZXQgaW5k
ZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgICBpZiAoaW5kZXgg
PT09IHRoaXMuaW5kZXgpIGNvbnRpbnVlOwogICAgICAgIGNvbnN0IG90aGVyID0gcm9vbS5zbG90
c1tpbmRleF07CiAgICAgICAgaWYgKCFvdGhlci5maWdodGluZyAmJiBvdGhlci5sZWZ0RnJhbWUg
PCB0KSBjb250aW51ZTsKICAgICAgICBhbnkgPSB0cnVlOwogICAgICAgIGlmIChvdGhlci5sYXN0
UGFja2V0IDwgdCkgeyBjb21wbGV0ZSA9IGZhbHNlOyBicmVhazsgfQogICAgICB9CiAgICAgIGlm
ICghY29tcGxldGUgfHwgIWFueSkgYnJlYWs7CiAgICAgIGxldCBwYXJ0ID0gJyc7CiAgICAgIGZv
ciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgICAg
aWYgKGluZGV4ID09PSB0aGlzLmluZGV4KSBjb250aW51ZTsKICAgICAgICBjb25zdCBvdGhlciA9
IHJvb20uc2xvdHNbaW5kZXhdOwogICAgICAgIGlmICgob3RoZXIuZmlnaHRpbmcgfHwgb3RoZXIu
bGVmdEZyYW1lID49IHQpICYmIG90aGVyLmxhc3RQYWNrZXQgPj0gdCkgcGFydCArPSBvdGhlci5m
cmFtZXNbdCAlIEZSQU1FU19LRVBUXSB8fCAnJzsKICAgICAgfQogICAgICBpZiAoIXBhcnQpIGJy
ZWFrOwogICAgICB0ZXh0ICs9IHBhcnQ7CiAgICAgIHRoaXMubmV4dEZyYW1lICs9IDE7CiAgICB9
CiAgICBpZiAoIXRleHQpIHJldHVybjsKICAgIGlmICh0aGlzLnF1ZXVlZCkgewogICAgICB0ZXh0
ICs9IHRoaXMucXVldWVkOwogICAgICB0aGlzLnF1ZXVlZCA9ICcnOwogICAgfQogICAgdGhpcy5z
ZW5kKHRleHQpOwogIH0KCiAgcmVzZXRGcmFtZXMoKSB7IC8vIGkuYygpCiAgICB0aGlzLmxhc3RG
cmFtZSA9IC0xOwogICAgdGhpcy5uZXh0RnJhbWUgPSAwOwogICAgdGhpcy5xdWV1ZWQgPSAnJzsK
ICB9CgogIC8vIGkuYSgpOiB0aGlzIGNvbXB1dGVyIGxlYXZlcyB0aGUgcm9vbS4KICBsZWF2ZSgp
IHsKICAgIGlmICh0aGlzLmluZGV4ID09PSAtMSkgcmV0dXJuOwogICAgY29uc3Qgcm9vbSA9IHRo
aXMucm9vbTsKICAgIGNvbnN0IGluZGV4ID0gdGhpcy5pbmRleDsKICAgIHRoaXMucmVxdWVzdEZs
dXNoZXMoKTsKICAgIGNvbnN0IHNsb3QgPSByb29tLnNsb3RzW2luZGV4XTsKICAgIGlmIChzbG90
Lm9ubGluZSAmJiBzbG90LmNvbm5lY3Rpb24gPT09IHRoaXMpIHsKICAgICAgZm9yIChjb25zdCBt
YW4gb2Ygcm9vbS5tZW4pIHsKICAgICAgICBpZiAobWFuLmNsaWVudCAhPT0gaW5kZXggJiYgKG1h
bi5jb21tYW5kZXIgPCBpbmRleCAqIDMgfHwgbWFuLmNvbW1hbmRlciA+IGluZGV4ICogMyArIDIp
KSBjb250aW51ZTsKICAgICAgICBPYmplY3QuYXNzaWduKG1hbiwgbmV3TWFuKCksIHsgcmFuZG9t
OiB0cnVlIH0pOwogICAgICAgIG1hbi5jaGFyID0gJyc7CiAgICAgIH0KICAgICAgc2xvdC5hZG1p
biA9IGZhbHNlOwogICAgICBzbG90Lm9ubGluZSA9IGZhbHNlOwogICAgICBpZiAoc2xvdC5sYXN0
UGFja2V0ID4gMCkgc2xvdC5sZWZ0RnJhbWUgPSBzbG90Lmxhc3RQYWNrZXQ7CiAgICAgIHNsb3Qu
ZmlnaHRpbmcgPSBmYWxzZTsKICAgICAgc2xvdC5oYXNQbGF5ZXIgPSBmYWxzZTsKICAgICAgc2xv
dC5jb25uZWN0aW9uID0gbnVsbDsKICAgICAgaWYgKCFyb29tLmZpZ2h0aW5nTm93KSByb29tLmJy
b2FkY2FzdE1lbigxKTsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCBpbmRleCk7CiAgICAg
IHRoaXMuaW5kZXggPSAtMTsKICAgICAgcm9vbS5sb2coYGhmIHJvb20gJHtyb29tLm51bWJlcn06
ICR7dGhpcy5uYW1lfSBsZWF2ZXNgKTsKICAgICAgcm9vbS5qb3QoYCR7dGhpcy5uYW1lfSBsZWF2
ZXMke3RoaXMua2lja2VkID8gJyAodGFrZW4gb3V0KScgOiAnJ30ke3Jvb20uZmlnaHRpbmdOb3cg
PyBgIGR1cmluZyBhIGZpZ2h0LCBhdCBmcmFtZSAke3Nsb3QubGVmdEZyYW1lfWAgOiAnJ31gKTsK
ICAgICAgcm9vbS5yZWNvdW50KCk7CiAgICAgIHJvb20uYW5ub3VuY2VQZWVycygpOwogICAgfQog
ICAgdGhpcy5pbmRleCA9IC0xOwogIH0KCiAgLy8gLS0tLSB3aGF0IHRoZSBzZXJ2ZXIgc2VuZHMg
b25lIGdhbWUKICBzZW5kU2V0dGluZyhjaWQpIHsgLy8gaS5hKGludCkKICAgIHRoaXMuc2VuZChg
PHNldHRpbmc+JHtjaWQgIT09IC0xID8gYDxjPiR7Y2lkfTwvYz5gIDogJyd9PHdhaXR3aGVuZmln
aHQ+JHt0aGlzLnJvb20uYWxsb3dKb2luV2hlbkZpZ2h0aW5nID8gMSA6IDB9PC93YWl0d2hlbmZp
Z2h0Pjwvc2V0dGluZz5gKTsKICB9CgogIHNlbmRHYW1lU2V0dGluZyhjaWQpIHsgLy8gaS5iKGlu
dCkKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICB0aGlzLnNlbmQoYDxnYW1lc2V0dGlu
Zz4ke2NpZCAhPT0gLTEgPyBgPGM+JHtjaWR9PC9jPmAgOiAnJ308YmdpZD4ke3Jvb20uYmFja2dy
b3VuZH08L2JnaWQ+PG11c2ljaWQ+JHtyb29tLm11c2ljfTwvbXVzaWNpZD5gCiAgICAgICsgYDxt
cD4ke3Jvb20ubXVsdGlwbGFuZSA/IDEgOiAwfTwvbXA+PGJncmFuZG9tPiR7cm9vbS5iYWNrZ3Jv
dW5kUmFuZG9tID8gMSA6IDB9PC9iZ3JhbmRvbT5gCiAgICAgICsgYDxtdXNpY3JhbmRvbT4ke3Jv
b20ubXVzaWNSYW5kb20gPyAxIDogMH08L211c2ljcmFuZG9tPjxob3JzZT4ke3Jvb20uaG9yc2Vz
fTwvaG9yc2U+YAogICAgICArIGA8Z2lhbnRvYmo+JHtyb29tLmdpYW50T2JqZWN0c308L2dpYW50
b2JqPjxkaWZmPiR7cm9vbS5kaWZmaWN1bHR5fTwvZGlmZj48bm9ybGV2PiR7cm9vbS5ub3JtYWxp
emVMZXZlbH08L25vcmxldj5gCiAgICAgICsgYDxkaW5vPiR7cm9vbS5kaW5vc2F1cnN9PC9kaW5v
Pjx0ZXN0dHJvb3A+JHtyb29tLnRlc3RUcm9vcHN9PC90ZXN0dHJvb3A+PHNvbGRpZXJudW1iZXI+
JHtyb29tLnNvbGRpZXJOdW1iZXJ9PC9zb2xkaWVybnVtYmVyPmAKICAgICAgKyBgPHNvbGRpZXJy
ZXNlcnZlZD4ke3Jvb20uc29sZGllclJlc2VydmVkfTwvc29sZGllcnJlc2VydmVkPjxzdG9yeWk+
JHtyb29tLnN0b3J5fTwvc3RvcnlpPmAKICAgICAgKyBgPGJhdHRsZXR5cGU+JHtyb29tLmJhdHRs
ZVR5cGV9PC9iYXR0bGV0eXBlPjxwcmVzZXR0eXBlPiR7cm9vbS5wcmVzZXR9PC9wcmVzZXR0eXBl
PjwvZ2FtZXNldHRpbmc+YCk7CiAgfQoKICBzZW5kTGlzdChqb2luZWQsIHF1aXQpIHsgLy8gaS5h
KGludCwgaW50KQogICAgbGV0IHRleHQgPSBgPGxpc3Q+PGNpZD4ke3RoaXMuaW5kZXh9PC9jaWQ+
YDsKICAgIGlmIChqb2luZWQgIT09IC0xKSB0ZXh0ICs9IGA8am9pbl9jaWQ+JHtqb2luZWR9PC9q
b2luX2NpZD5gOwogICAgaWYgKHF1aXQgIT09IC0xKSB0ZXh0ICs9IGA8cXVpdF9jaWQ+JHtxdWl0
fTwvcXVpdF9jaWQ+YDsKICAgIGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLnJvb20uc2xvdHMpIHsK
ICAgICAgdGV4dCArPSBgPGluZm8+PG5hbWU+PCFbQ0RBVEFbJHtzbG90Lm5hbWV9XV0+PC9uYW1l
PjxvbmxpbmU+JHtzbG90Lm9ubGluZSA/IDEgOiAwfTwvb25saW5lPmAKICAgICAgICArIGA8aGFz
cGxheWVyPiR7c2xvdC5oYXNQbGF5ZXIgPyAxIDogMH08L2hhc3BsYXllcj48Y2M+JHtzbG90LmNj
fTwvY2M+PHBhdXNlZ2FtZT4ke3Nsb3QucGF1c2VkID8gMSA6IDB9PC9wYXVzZWdhbWU+YAogICAg
ICAgICsgYDxsYXRlbmN5PiR7c2xvdC5sYXRlbmN5fTwvbGF0ZW5jeT48cGFnZT4ke3Nsb3QucGFn
ZX08L3BhZ2U+YDsKICAgICAgZm9yIChsZXQgayA9IDA7IGsgPCAzOyBrICs9IDEpIHRleHQgKz0g
YDxwPjwhW0NEQVRBWyR7c2xvdC5wbGF5ZXJzW2tdfV1dPjwvcD5gOwogICAgICB0ZXh0ICs9IGA8
bGVhdmVfZj4ke3Nsb3QubGVmdEZyYW1lfTwvbGVhdmVfZj48L2luZm8+YDsKICAgIH0KICAgIHRo
aXMuc2VuZCh0ZXh0ICsgJzwvbGlzdD4nKTsKICB9CgogIHNlbmRNZW4oY2hhbmdlZCkgeyAvLyBp
LmMoaW50KQogICAgbGV0IHRleHQgPSBgPG1hbmxpc3Q+PG51bWNoYW5nZWQ+JHtjaGFuZ2VkfTwv
bnVtY2hhbmdlZD5gOwogICAgZm9yIChjb25zdCBtYW4gb2YgdGhpcy5yb29tLm1lbikgewogICAg
ICB0ZXh0ICs9IGA8bWFuPjxjaWQ+JHttYW4uY2xpZW50fTwvY2lkPjxjb24+JHttYW4uY29udHJv
bGxlcn08L2Nvbj48dGVhbT4ke21hbi50ZWFtfTwvdGVhbT48Y2hhcj4ke21hbi5jaGFyfTwvY2hh
cj5gCiAgICAgICAgKyBgPGx2PiR7bWFuLmxldmVsfTwvbHY+PGNvbW0+JHttYW4uY29tbWFuZGVy
fTwvY29tbT48cmFuZD4ke21hbi5yYW5kb20gPyAxIDogMH08L3JhbmQ+PGV4aXN0PiR7bWFuLmV4
aXN0cyA/IDEgOiAwfTwvZXhpc3Q+PC9tYW4+YDsKICAgIH0KICAgIHRoaXMuc2VuZCh0ZXh0ICsg
JzwvbWFubGlzdD4nKTsKICB9CgogIG5vdGljZSh0ZXh0KSB7IC8vIGkuYihTdHJpbmcpOiBhIGxp
bmUgZnJvbSB0aGUgc2VydmVyIHRvIHRoaXMgZ2FtZSBvbmx5CiAgICB0aGlzLnNlbmQoYDxjaGF0
PjxjPiR7U0VSVkVSX1NMT1R9PC9jPjxtPjwhW0NEQVRBWzxmb250IGNvbG9yPSIjRkZGRkFBIj4k
e3RleHR9PC9mb250Pl1dPjwvbT48L2NoYXQ+YCk7CiAgfQoKICBhbm5vdW5jZSh0ZXh0KSB7IC8v
IGkuZShTdHJpbmcpOiBhIGxpbmUgZnJvbSB0aGUgc2VydmVyIHRvIGV2ZXJ5b25lCiAgICB0aGlz
LnJvb20uYnJvYWRjYXN0KGA8Y2hhdD48Yz4ke1NFUlZFUl9TTE9UfTwvYz48bT48IVtDREFUQVs8
Zm9udCBjb2xvcj0iI0ZGQ0NGRiI+JHt0ZXh0fTwvZm9udD5dXT48L20+PC9jaGF0PmApOwogIH0K
CiAgLy8gLS0tLSB0aGUgd2FpdGluZyByb29tIGFuZCB0aGUgbWVudXMKICBzdGFydENvdW50KGRv
YykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGNvbnN0IGNvdW50ZG93biA9IHJv
b20uY291bnRkb3duOwogICAgaWYgKGNvdW50ZG93bi5vbikgcmV0dXJuOwogICAgY29uc3QgYWN0
aW9uID0gdGFnVmFsdWUoZG9jLCAnYWN0aW9uJyk7CiAgICBjb25zdCBwYWdlID0gdGFnVmFsdWUo
ZG9jLCAncGFnZScpOwogICAgbGV0IHRvZ2V0aGVyID0gdHJ1ZTsKICAgIGZvciAoY29uc3Qgc2xv
dCBvZiByb29tLm9ubGluZSgpKSB7CiAgICAgIGlmIChwYWdlID09PSAnRklHSFRJTkcnID8gc2xv
dC5wYWdlICE9PSAnRklHSFRJTkcnICYmIHNsb3QucGFnZSAhPT0gJ1dBSVRST09NJyA6IHNsb3Qu
cGFnZSAhPT0gcGFnZSkgeyB0b2dldGhlciA9IGZhbHNlOyBicmVhazsgfQogICAgfQogICAgaWYg
KHJvb20ucGFnZSAhPT0gcGFnZSB8fCAhdG9nZXRoZXIpIHJldHVybjsKICAgIGNvbnN0IHN0YXJ0
ID0gKHdoYXQsIGNvdW50ID0gQ09VTlRET1dOLCBzaG93biA9IHdoYXQpID0+IHsKICAgICAgY291
bnRkb3duLm9uID0gdHJ1ZTsKICAgICAgY291bnRkb3duLmFjdGlvbiA9IHdoYXQ7CiAgICAgIGNv
dW50ZG93bi5jb3VudCA9IGNvdW50OwogICAgICByb29tLmJyb2FkY2FzdENsaWNrKHRoaXMuaW5k
ZXgsIHNob3duKTsKICAgIH07CiAgICBjb25zdCB6ZXJvID0gKCkgPT4gYnlUYWcoZG9jLCAnemVy
bycpLmxlbmd0aCAmJiB2YWx1ZU9mKGJ5VGFnKGRvYywgJ3plcm8nKVswXSkgPT09ICd0cnVlJzsK
ICAgIGlmIChyb29tLnBhZ2UgPT09ICdXQUlUUk9PTScgJiYgKGFjdGlvbiA9PT0gJ2NsaWNrdnMn
IHx8IGFjdGlvbiA9PT0gJ2NsaWNrc3RvcnknIHx8IGFjdGlvbiA9PT0gJ2NsaWNrYmF0dGxlJykp
IHsKICAgICAgc3RhcnQoYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAocm9vbS5wYWdlID09PSAnQ0hB
Uk1FTlUnICYmIGFjdGlvbiA9PT0gJ2NsaWNrbmV4dCcpIHsKICAgICAgaWYgKHRoaXMuY2FuU3Rh
cnQoKSkgc3RhcnQoYWN0aW9uLCBDT1VOVERPV04sIHJvb20ubW9kZSA9PT0gJ0JBVFRMRU1PREUn
IHx8IHJvb20ubW9kZSA9PT0gJ1NUT1JZTU9ERScgPyAnY2xpY2tmaWdodCcgOiBhY3Rpb24pOwog
ICAgfSBlbHNlIGlmICgocm9vbS5wYWdlID09PSAnU1RPUllNRU5VJyB8fCByb29tLnBhZ2UgPT09
ICdCQVRUTEVTRVRUSU5HTUVOVScpICYmIGFjdGlvbiA9PT0gJ2NsaWNrbmV4dCcpIHsKICAgICAg
c3RhcnQoYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAocm9vbS5wYWdlID09PSAnR0FNRVNFVFRJTkdN
RU5VJyAmJiBhY3Rpb24gPT09ICdjbGlja2ZpZ2h0JykgewogICAgICBzdGFydChhY3Rpb24pOwog
ICAgfSBlbHNlIGlmIChyb29tLmZpZ2h0aW5nTm93ICYmIGFjdGlvbiA9PT0gJ3F1aXRnYW1lJykg
ewogICAgICBjb25zdCBpc1plcm8gPSB6ZXJvKCk7CiAgICAgIHN0YXJ0KGFjdGlvbiwgaXNaZXJv
ID8gMSA6IENPVU5URE9XTiAqIDIpOwogICAgfSBlbHNlIGlmIChyb29tLmZpZ2h0aW5nTm93ICYm
IGFjdGlvbiA9PT0gJ3Jlc3RhcnRnYW1lJykgewogICAgICBpZiAocm9vbS5iYWNrZ3JvdW5kUmFu
ZG9tKSByb29tLnBpY2tCYWNrZ3JvdW5kKCk7CiAgICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5k
ZXggPCBNRU47IGluZGV4ICs9IDEpIGlmIChyb29tLm1lbltpbmRleF0uZXhpc3RzICYmIHJvb20u
bWVuW2luZGV4XS5yYW5kb20pIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7CiAgICAgIGlmIChy
b29tLm11c2ljUmFuZG9tKSByb29tLnBpY2tNdXNpYygpOwogICAgICBzdGFydChhY3Rpb24sIENP
VU5URE9XTiAqIDIpOwogICAgICBpZiAoemVybygpKSBjb3VudGRvd24uY291bnQgPSAxOwogICAg
fSBlbHNlIGlmIChyb29tLmZpZ2h0aW5nTm93ICYmIGFjdGlvbiA9PT0gJ25leHRzdGFnZScpIHsK
ICAgICAgc3RhcnQoYWN0aW9uLCBDT1VOVERPV04gKiAyKTsKICAgICAgaWYgKHplcm8oKSkgY291
bnRkb3duLmNvdW50ID0gMTsKICAgIH0KICB9CgogIC8vIGkuZCgpOiB3aGV0aGVyIHRoZSBjaGFy
YWN0ZXIgbWVudSBtYXkgZ28gb24uCiAgY2FuU3RhcnQoKSB7CiAgICBjb25zdCByb29tID0gdGhp
cy5yb29tOwogICAgY29uc3QgcGVyVGVhbSA9IFswLCAwLCAwLCAwLCAwXTsKICAgIGxldCBtZW4g
PSAwOwogICAgbGV0IGh1bWFucyA9IDA7CiAgICBmb3IgKGNvbnN0IG1hbiBvZiByb29tLm1lbikg
ewogICAgICBpZiAoIW1hbi5leGlzdHMpIGNvbnRpbnVlOwogICAgICBpZiAobWFuLmNvbnRyb2xs
ZXIgIT09IC0xICYmIHJvb20uc2xvdHNbbWFuLmNsaWVudF0gJiYgcm9vbS5zbG90c1ttYW4uY2xp
ZW50XS5vbmxpbmUpIGh1bWFucyArPSAxOwogICAgICBtZW4gKz0gMTsKICAgICAgcGVyVGVhbVtt
YW4udGVhbSArIDFdICs9IDE7CiAgICB9CiAgICBsZXQgdGVhbXMgPSBwZXJUZWFtWzBdOwogICAg
bGV0IGNyb3dkZWQgPSBmYWxzZTsKICAgIGZvciAobGV0IGsgPSAxOyBrIDwgNTsgayArPSAxKSB7
CiAgICAgIGlmIChwZXJUZWFtW2tdID4gMCkgdGVhbXMgKz0gMTsKICAgICAgaWYgKHBlclRlYW1b
a10gPiA1KSBjcm93ZGVkID0gdHJ1ZTsKICAgIH0KICAgIGNvbnN0IHJlZnVzZSA9IChib2R5KSA9
PiB7IHRoaXMuc2VuZChgPGNoYXJtZW51bmV4dGVycm9yPiR7Ym9keX08L2NoYXJtZW51bmV4dGVy
cm9yPmApOyByZXR1cm4gZmFsc2U7IH07CiAgICBpZiAobWVuID09PSAwKSByZXR1cm4gcmVmdXNl
KCc8bT5Ob1BsYXllcjwvbT4nKTsKICAgIGlmIChodW1hbnMgPT09IDApIHJldHVybiByZWZ1c2Uo
JzxtPk5vSHVtYW5QbGF5ZXI8L20+Jyk7CiAgICBpZiAobWVuID09PSAxICYmIHJvb20ubW9kZSA9
PT0gJ1ZTTU9ERScpIHJldHVybiByZWZ1c2UoJzxtPk9uZVBsYXllck9ubHk8L20+Jyk7CiAgICBp
ZiAodGVhbXMgPD0gMSAmJiByb29tLm1vZGUgPT09ICdWU01PREUnKSByZXR1cm4gcmVmdXNlKCc8
bT5PbmVUZWFtT25seTwvbT4nKTsKICAgIGlmIChyb29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJykg
ewogICAgICBpZiAodGVhbXMgPCByb29tLnRlYW1zKSByZXR1cm4gcmVmdXNlKGA8bT5iYXR0bGVO
b0Vub3VnaFRlYW08L20+PGE+JHtyb29tLmJhdHRsZVR5cGV9PC9hPjxiPiR7cm9vbS50ZWFtc308
L2I+PGM+JHt0ZWFtc308L2M+YCk7CiAgICAgIGlmIChjcm93ZGVkKSByZXR1cm4gcmVmdXNlKCc8
bT5iYXR0bGVOb3RBbGxvd01vcmVUaGFuNTwvbT4nKTsKICAgIH0KICAgIHJldHVybiB0cnVlOwog
IH0KCiAgY2xpY2tCYWNrKGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGlm
IChyb29tLmNvdW50ZG93bi5vbiB8fCByb29tLnBhZ2UgIT09IHRhZ1ZhbHVlKGRvYywgJ3BhZ2Un
KSkgcmV0dXJuOwogICAgY29uc3QgYmFjayA9IChtb2RlLCBwYWdlKSA9PiB7CiAgICAgIHJvb20u
cHJldmlvdXNQYWdlID0gcm9vbS5wYWdlOwogICAgICBpZiAobW9kZSkgcm9vbS5tb2RlID0gbW9k
ZTsKICAgICAgcm9vbS5wYWdlID0gcGFnZTsKICAgICAgcm9vbS5icm9hZGNhc3RTdGF0dXMoKTsK
ICAgICAgcm9vbS5icm9hZGNhc3RDbGljayh0aGlzLmluZGV4LCAnY2xpY2tiYWNrJyk7CiAgICB9
OwogICAgaWYgKHJvb20ucGFnZSA9PT0gJ0NIQVJNRU5VJyAmJiByb29tLm1vZGUgPT09ICdWU01P
REUnKSBiYWNrKCdXQUlUUk9PTScsICdXQUlUUk9PTScpOwogICAgZWxzZSBpZiAocm9vbS5wYWdl
ID09PSAnQ0hBUk1FTlUnICYmIHJvb20ubW9kZSA9PT0gJ1NUT1JZTU9ERScpIGJhY2soJ1NUT1JZ
TU9ERScsICdTVE9SWU1FTlUnKTsKICAgIGVsc2UgaWYgKHJvb20ucGFnZSA9PT0gJ0NIQVJNRU5V
JyAmJiByb29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJykgYmFjaygnQkFUVExFTU9ERScsICdCQVRU
TEVTRVRUSU5HTUVOVScpOwogICAgZWxzZSBpZiAocm9vbS5wYWdlID09PSAnU1RPUllNRU5VJyB8
fCByb29tLnBhZ2UgPT09ICdCQVRUTEVTRVRUSU5HTUVOVScpIGJhY2soJ1dBSVRST09NJywgJ1dB
SVRST09NJyk7CiAgICBlbHNlIGlmIChyb29tLnBhZ2UgPT09ICdHQU1FU0VUVElOR01FTlUnKSBi
YWNrKG51bGwsICdDSEFSTUVOVScpOwogIH0KCiAgZ2FtZVNldHRpbmcoZG9jKSB7CiAgICBjb25z
dCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKCFbJ0dBTUVTRVRUSU5HTUVOVScsICdDSEFSTUVO
VScsICdTVE9SWU1FTlUnLCAnQkFUVExFU0VUVElOR01FTlUnXS5pbmNsdWRlcyhyb29tLnBhZ2Up
KSByZXR1cm47CiAgICBjb25zdCB2YWx1ZSA9IChuYW1lKSA9PiB7IGNvbnN0IGZvdW5kID0gYnlU
YWcoZG9jLCBuYW1lKTsgcmV0dXJuIGZvdW5kLmxlbmd0aCA/IHZhbHVlT2YoZm91bmRbMF0pIDog
dW5kZWZpbmVkOyB9OwogICAgY29uc3QgYmFja2dyb3VuZCA9IHZhbHVlKCdiZ2lkJyk7CiAgICBp
ZiAoYmFja2dyb3VuZCAhPT0gdW5kZWZpbmVkICYmIChyb29tLmJhY2tncm91bmRSYW5kb20gfHwg
cm9vbS5iYWNrZ3JvdW5kICE9PSBiYWNrZ3JvdW5kKSkgewogICAgICByb29tLmJhY2tncm91bmQg
PSByb29tLmJhY2tncm91bmRDaG9zZW4gPSBiYWNrZ3JvdW5kOwogICAgICBpZiAoYmFja2dyb3Vu
ZCA9PT0gJ3JhbmRvbScpIHsKICAgICAgICByb29tLmJhY2tncm91bmRSYW5kb20gPSB0cnVlOwog
ICAgICAgIHJvb20ucGlja0JhY2tncm91bmQoKTsKICAgICAgfSBlbHNlIHsKICAgICAgICByb29t
LmJhY2tncm91bmRSYW5kb20gPSBmYWxzZTsKICAgICAgfQogICAgfQogICAgY29uc3QgbXVzaWMg
PSB2YWx1ZSgnbXVzaWNpZCcpOwogICAgaWYgKG11c2ljICE9PSB1bmRlZmluZWQgJiYgKHJvb20u
bXVzaWNSYW5kb20gfHwgcm9vbS5tdXNpYyAhPT0gbXVzaWMpKSB7CiAgICAgIHJvb20ubXVzaWMg
PSBtdXNpYzsKICAgICAgaWYgKG11c2ljID09PSAncmFuZG9tJykgewogICAgICAgIHJvb20ubXVz
aWNSYW5kb20gPSB0cnVlOwogICAgICAgIHJvb20ucGlja011c2ljKCk7CiAgICAgIH0gZWxzZSB7
CiAgICAgICAgcm9vbS5tdXNpY1JhbmRvbSA9IGZhbHNlOwogICAgICB9CiAgICB9CiAgICBjb25z
dCBtdWx0aXBsYW5lID0gdmFsdWUoJ21wJyk7CiAgICBpZiAobXVsdGlwbGFuZSAhPT0gdW5kZWZp
bmVkKSByb29tLm11bHRpcGxhbmUgPSBtdWx0aXBsYW5lID09PSAnMSc7CiAgICBjb25zdCBudW1i
ZXJzID0gW1snaG9yc2UnLCAnaG9yc2VzJ10sIFsnZ2lhbnRvYmonLCAnZ2lhbnRPYmplY3RzJ10s
IFsnZGlmZicsICdkaWZmaWN1bHR5J10sIFsnbm9ybGV2JywgJ25vcm1hbGl6ZUxldmVsJ10sCiAg
ICAgIFsnZGlubycsICdkaW5vc2F1cnMnXSwgWyd0ZXN0dHJvb3AnLCAndGVzdFRyb29wcyddLCBb
J3NvbGRpZXJudW1iZXInLCAnc29sZGllck51bWJlciddLAogICAgICBbJ3NvbGRpZXJyZXNlcnZl
ZCcsICdzb2xkaWVyUmVzZXJ2ZWQnXSwgWydzdG9yeWknLCAnc3RvcnknXV07CiAgICBmb3IgKGNv
bnN0IFt0YWcsIGZpZWxkXSBvZiBudW1iZXJzKSB7CiAgICAgIGNvbnN0IHJhdyA9IHZhbHVlKHRh
Zyk7CiAgICAgIGlmIChyYXcgIT09IHVuZGVmaW5lZCkgcm9vbVtmaWVsZF0gPSBpbnQocmF3KTsK
ICAgIH0KICAgIGNvbnN0IHJhdyA9IHZhbHVlKCdidCcpOwogICAgaWYgKHJhdyAhPT0gdW5kZWZp
bmVkICYmIHJvb20ucHJlc2V0ICE9PSAtaW50KHJhdykgLSAxICYmIChyb29tLnByZXNldCAhPT0g
LTEgfHwgcm9vbS5iYXR0bGVUeXBlICE9PSBpbnQocmF3KSkpIHsKICAgICAgbGV0IHR5cGUgPSBp
bnQocmF3KTsKICAgICAgaWYgKHR5cGUgPCAwKSB7CiAgICAgICAgZm9yIChsZXQgaW5kZXggPSAw
OyBpbmRleCA8IE1FTjsgaW5kZXggKz0gMSkgewogICAgICAgICAgcm9vbS5tZW5baW5kZXhdLmV4
aXN0cyA9IGZhbHNlOwogICAgICAgICAgaWYgKGluZGV4ID49IDEyKSByb29tLm1lbltpbmRleF0u
cmFuZG9tID0gZmFsc2U7CiAgICAgICAgICByb29tLm1lbltpbmRleF0uY29tbWFuZGVyID0gLTE7
CiAgICAgICAgfQogICAgICAgIHJvb20ucHJlc2V0ID0gLXR5cGUgLSAxOwogICAgICAgIGNvbnN0
IHByZXNldCA9IChsZXZlbCwgbGlzdCkgPT4gbGlzdC5mb3JFYWNoKChbaW5kZXgsIGNoYXIsIHRl
YW1dKSA9PiBPYmplY3QuYXNzaWduKHJvb20ubWVuW2luZGV4XSwgeyBsZXZlbCwgY2hhciwgZXhp
c3RzOiB0cnVlLCB0ZWFtIH0pKTsKICAgICAgICBpZiAodHlwZSA9PT0gLTEpIHsKICAgICAgICAg
IHR5cGUgPSAxMTsKICAgICAgICAgIHByZXNldCgxMCwgW1sxOSwgJ2xlbycsIDFdLCBbMjAsICdp
Y3p6eScsIDFdLCBbMjEsICdoZWF0ZXInLCAxXSwgWzIyLCAncmF5ZScsIDFdLCBbMjMsICdzaW5h
bicsIDFdXSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAtMikgewogICAgICAgICAgdHlw
ZSA9IDExMTE7CiAgICAgICAgICBwcmVzZXQoMTEsIFtbMTUsICd0YXlsb3InLCAxXSwgWzE2LCAn
bGVvJywgMV0sIFsxNywgJ2plbm55JywgMV0sIFsxOCwgJ3JheWUnLCAyXSwgWzE5LCAnaWN6enkn
LCAyXSwgWzIwLCAnaGVhdGVyJywgMl0sCiAgICAgICAgICAgIFsyMSwgJ2dvcmRvbicsIDNdLCBb
MjIsICdqYXNvbicsIDNdLCBbMjMsICd0aXR0bycsIDNdXSk7CiAgICAgICAgfSBlbHNlIGlmICh0
eXBlID09PSAtMykgewogICAgICAgICAgdHlwZSA9IDExMTsKICAgICAgICAgIHByZXNldCgxMiwg
W1sxNSwgJ2hlYXRlcicsIDFdLCBbMTYsICdpY3p6eScsIDFdLCBbMTcsICdyYXllJywgMV0sIFsx
OCwgJ3NpbmFuJywgMV0sIFsxOSwgJ3RpdHRvJywgMV0sIFsyMCwgJ2xlbycsIDJdLAogICAgICAg
ICAgICBbMjEsICdnb3Jkb24nLCAyXSwgWzIyLCAnamVubnknLCAyXSwgWzIzLCAnamFzb24nLCAy
XV0pOwogICAgICAgIH0gZWxzZSBpZiAodHlwZSA9PT0gLTQpIHsKICAgICAgICAgIHR5cGUgPSAx
MTI7CiAgICAgICAgICBwcmVzZXQoMTQsIFtbMTUsICdsZW8nLCAwXSwgWzE2LCAnc2luYW4nLCAw
XSwgWzE3LCAnZ29yZG9uJywgMF0sIFsxOCwgJ2ljenp5JywgMV0sIFsxOSwgJ2hlYXRlcicsIDFd
LCBbMjAsICdyYXllJywgMV0sCiAgICAgICAgICAgIFsyMSwgJ2phc29uJywgM10sIFsyMiwgJ3Rp
dHRvJywgM10sIFsyMywgJ2dpZ2dzJywgM11dKTsKICAgICAgICB9CiAgICAgIH0gZWxzZSB7CiAg
ICAgICAgcm9vbS5wcmVzZXQgPSAtMTsKICAgICAgfQogICAgICByb29tLmJhdHRsZVR5cGUgPSB0
eXBlOwogICAgICBpZiAodHlwZSA9PT0gMTEpIHJvb20udGVhbXMgPSAyOwogICAgICBlbHNlIGlm
ICh0eXBlID09PSAxMiB8fCB0eXBlID09PSAxMTEpIHJvb20udGVhbXMgPSAzOwogICAgICBlbHNl
IGlmICh0eXBlID09PSAyMiB8fCB0eXBlID09PSAxMyB8fCB0eXBlID09PSAxMTExIHx8IHR5cGUg
PT09IDExMikgcm9vbS50ZWFtcyA9IDQ7CiAgICAgIGlmIChyb29tLnRlYW1zID09PSAyKSByb29t
LmJhY2tncm91bmQgPSAnYmF0dGxlMic7CiAgICAgIGVsc2UgaWYgKHJvb20udGVhbXMgPT09IDMp
IHJvb20uYmFja2dyb3VuZCA9ICdiYXR0bGUzJzsKICAgICAgZWxzZSBpZiAocm9vbS50ZWFtcyA9
PT0gNCkgcm9vbS5iYWNrZ3JvdW5kID0gJ2JhdHRsZTQnOwogICAgICBjb25zdCBtYXBzID0geyAx
MTogWzAsIDEsIC0xLCAtMV0sIDIyOiBbMCwgMSwgMCwgMV0sIDExMTogWzAsIDEsIDIsIC0xXSwg
MTExMTogWzAsIDEsIDIsIDNdLCAxMjogWzEsIDAsIDEsIC0xXSwKICAgICAgICAxMzogWzAsIDEs
IDEsIDFdLCAxMTI6IFsxLCAxLCAwLCAyXSB9OwogICAgICBpZiAobWFwc1t0eXBlXSkgcm9vbS50
ZWFtTWFwID0gbWFwc1t0eXBlXTsKICAgIH0KICAgIHJvb20uYnJvYWRjYXN0R2FtZVNldHRpbmco
dGhpcy5pbmRleCk7CiAgfQoKICB1cGRhdGVJbmZvKGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRo
aXMucm9vbTsKICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3Q7CiAgICBzbG90Lm5hbWUgPSB0YWdW
YWx1ZShkb2MsICduYW1lJyk7IC8vICh0aGUgb3JpZ2luYWwga2VlcHMgdGhlIG5hbWUgaXQgam9p
bmVkIHdpdGggZm9yIGl0cyBsb2cgYW5kIC9tZSkKICAgIGZvciAobGV0IGsgPSAwOyBrIDwgMzsg
ayArPSAxKSBzbG90LnBsYXllcnNba10gPSB0aGlzLnBsYXllcnNba10gPSB0YWdWYWx1ZShkb2Ms
ICdwJywgayk7CiAgICBmb3IgKGxldCBrID0gMDsgayA8IDMwOyBrICs9IDEpIHsKICAgICAgc2xv
dC5sZXZlbHNba10gPSBpbnQodGFnVmFsdWUoZG9jLCAnbCcsIGspKTsKICAgICAgaWYgKHNsb3Qu
bGV2ZWxzW2tdID4gTUFYX0xFVkVMKSB0aGlzLmNoZWF0ID0gMTsKICAgIH0KICAgIGZvciAobGV0
IGsgPSAwOyBrIDwgMzsgayArPSAxKSB7CiAgICAgIGNvbnN0IG1hbiA9IHJvb20ubWVuW3RoaXMu
aW5kZXggKiAzICsga107CiAgICAgIGlmICghbWFuLmV4aXN0cykgY29udGludWU7CiAgICAgIGNv
bnN0IGNoYXJhY3RlciA9IENIQVJBQ1RFUlMuaW5kZXhPZihtYW4uY2hhcik7CiAgICAgIGlmIChj
aGFyYWN0ZXIgPj0gMCAmJiBzbG90LmxldmVsc1tjaGFyYWN0ZXJdID4gMCkgewogICAgICAgIG1h
bi5sZXZlbCA9IHNsb3QubGV2ZWxzW2NoYXJhY3Rlcl07CiAgICAgICAgZm9yIChjb25zdCBvdGhl
ciBvZiByb29tLm1lbikgaWYgKG90aGVyLmV4aXN0cyAmJiBvdGhlci5jb21tYW5kZXIgPT09IHRo
aXMuaW5kZXggKiAzICsgaykgb3RoZXIubGV2ZWwgPSBtYW4ubGV2ZWw7CiAgICAgIH0KICAgIH0K
ICAgIGlmICghcm9vbS5maWdodGluZ05vdykgewogICAgICByb29tLmJyb2FkY2FzdExpc3QoLTEs
IC0xKTsKICAgICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAgICB9CiAgfQoKICBhZGRQbGF5ZXIo
ZG9jKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20ucGFnZSAhPT0g
J0NIQVJNRU5VJykgcmV0dXJuOwogICAgY29uc3QgY29udHJvbGxlciA9IGludCh2YWx1ZU9mKGRv
YykpOwogICAgY29uc3QgaW5kZXggPSB0aGlzLmluZGV4ICogMyArIGNvbnRyb2xsZXI7CiAgICBj
b25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICBpZiAoIW1hbiB8fCBjb250cm9sbGVyIDwg
MCB8fCBjb250cm9sbGVyID4gMikgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBzdWNoIHBsYXllcicp
OwogICAgaWYgKG1hbi5leGlzdHMpIHJldHVybjsKICAgIG1hbi5leGlzdHMgPSB0cnVlOwogICAg
bWFuLmNsaWVudCA9IHRoaXMuaW5kZXg7CiAgICBtYW4uY29udHJvbGxlciA9IGNvbnRyb2xsZXI7
CiAgICBtYW4udGVhbSA9IC0xOwogICAgcm9vbS5tZW4uZm9yRWFjaCgob3RoZXIsIGspID0+IHsg
aWYgKGsgIT09IGluZGV4ICYmIG90aGVyLmV4aXN0cyAmJiBvdGhlci5jbGllbnQgPT09IHRoaXMu
aW5kZXgpIG1hbi50ZWFtID0gb3RoZXIudGVhbTsgfSk7CiAgICBpZiAobWFuLnRlYW0gPT09IC0x
KSBtYW4udGVhbSA9IHRoaXMubGVhc3RUZWFtKGluZGV4KTsKICAgIGlmIChtYW4ucmFuZG9tIHx8
ICFtYW4uY2hhcikgewogICAgICBtYW4ucmFuZG9tID0gdHJ1ZTsKICAgICAgdGhpcy5waWNrQ2hh
cmFjdGVyKGluZGV4KTsKICAgIH0gZWxzZSB7CiAgICAgIGNvbnN0IGNoYXJhY3RlciA9IENIQVJB
Q1RFUlMuaW5kZXhPZihtYW4uY2hhcik7CiAgICAgIGlmIChjaGFyYWN0ZXIgPj0gMCAmJiAodGhp
cy5zbG90LmxldmVsc1tjaGFyYWN0ZXJdIDw9IDAgfHwgdGhpcy5zbG90LmxldmVsc1tjaGFyYWN0
ZXJdICE9PSBtYW4ubGV2ZWwpKSB7CiAgICAgICAgbWFuLnJhbmRvbSA9IHRydWU7CiAgICAgICAg
dGhpcy5waWNrQ2hhcmFjdGVyKGluZGV4KTsKICAgICAgfQogICAgfQogICAgdGhpcy5saW1pdE1l
bigpOwogICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAgfQoKICAvLyBUaGUgdGVhbSB3aXRoIHRo
ZSBmZXdlc3QgbWVuIChub3QgY291bnRpbmcgc29sZGllcnMpLCBmb3IgYSBuZXcgbWFuLgogIGxl
YXN0VGVhbShleGNlcHQpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBjb25zdCBj
b3VudHMgPSBbMCwgMCwgMCwgMF07CiAgICByb29tLm1lbi5mb3JFYWNoKChvdGhlciwgaykgPT4g
eyBpZiAoayAhPT0gZXhjZXB0ICYmIG90aGVyLmV4aXN0cyAmJiBvdGhlci5jb21tYW5kZXIgPT09
IC0xKSBjb3VudHNbb3RoZXIudGVhbV0gKz0gMTsgfSk7CiAgICBpZiAocm9vbS5tb2RlICE9PSAn
QkFUVExFTU9ERScpIHJvb20udGVhbXMgPSA0OwogICAgbGV0IGZld2VzdCA9IDk5OTsKICAgIGxl
dCB0ZWFtID0gMDsKICAgIGZvciAobGV0IGsgPSAwOyBrIDwgcm9vbS50ZWFtczsgayArPSAxKSB7
CiAgICAgIGlmIChjb3VudHNba10gPCBmZXdlc3QpIHsKICAgICAgICBmZXdlc3QgPSBjb3VudHNb
a107CiAgICAgICAgdGVhbSA9IGs7CiAgICAgIH0KICAgIH0KICAgIHJldHVybiB0ZWFtOwogIH0K
CiAgLy8gaS5lKCk6IGEgY29tcHV0ZXIgcGxheWVyLCBpbiB0aGUgZmlyc3QgZnJlZSBwbGFjZSBh
ZnRlciB0aGUgMTIgaHVtYW4gb25lcy4KICBhZGRDb21wdXRlcigpIHsKICAgIGNvbnN0IHJvb20g
PSB0aGlzLnJvb207CiAgICBpZiAocm9vbS5tZW4uZmlsdGVyKChtYW4pID0+IG1hbi5leGlzdHMp
Lmxlbmd0aCA+PSAxMikgcmV0dXJuIGZhbHNlOwogICAgZm9yIChsZXQgaW5kZXggPSBNRU4gLSAx
OyBpbmRleCA+PSAxMjsgaW5kZXggLT0gMSkgewogICAgICBpZiAocm9vbS5tZW5baW5kZXhdLmV4
aXN0cyB8fCAoaW5kZXggIT09IDEyICYmICFyb29tLm1lbltpbmRleCAtIDFdLmV4aXN0cykpIGNv
bnRpbnVlOwogICAgICBjb25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICAgIG1hbi5leGlz
dHMgPSB0cnVlOwogICAgICBtYW4udGVhbSA9IHJvb20ubW9kZSA9PT0gJ0JBVFRMRU1PREUnIHx8
IHJvb20ubW9kZSA9PT0gJ1ZTTU9ERScgPyB0aGlzLmxlYXN0VGVhbShpbmRleCkgOiAzOwogICAg
ICBtYW4uY2xpZW50ID0gLTE7CiAgICAgIG1hbi5jb250cm9sbGVyID0gLTE7CiAgICAgIG1hbi5y
YW5kb20gPSB0cnVlOwogICAgICBtYW4uY29tbWFuZGVyID0gLTE7CiAgICAgIHRoaXMucGlja0No
YXJhY3RlcihpbmRleCk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgcmV0dXJuIGZhbHNl
OwogIH0KCiAgYWRkU29sZGllcihkb2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAg
ICBpZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnIHx8IHJvb20uY291bnRkb3duLm9uKSByZXR1
cm47CiAgICBjb25zdCBpbmRleCA9IGludCh0YWdWYWx1ZShkb2MsICdpJykpOwogICAgbGV0IHNv
bGRpZXIgPSB0YWdWYWx1ZShkb2MsICdjaGFyJyk7CiAgICBjb25zdCBjb21tYW5kZXIgPSByb29t
Lm1lbltpbmRleF07CiAgICBpZiAoIWNvbW1hbmRlcikgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBz
dWNoIG1hbicpOwogICAgY29uc3Qgcm9sbCA9IHRoaXMucm9vbS5yYW5kb20oKTsKICAgIHN3aXRj
aCAoY29tbWFuZGVyLmNoYXIpIHsKICAgICAgY2FzZSAnbHVjYXMnOiBjYXNlICdkcmV3JzogY2Fz
ZSAnc2hhd24nOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9pbmZhbnRyeTAxJyAmJiByb2xs
IDwgMC4zKSBzb2xkaWVyID0gJ3pfdmlsbGFnZXIwMSc7CiAgICAgICAgZWxzZSBpZiAoc29sZGll
ciA9PT0gJ3pfYXJjaGVyMDEnICYmIHJvbGwgPCAwLjMpIHNvbGRpZXIgPSAnel93b21hbjAxJzsK
ICAgICAgICBicmVhazsKICAgICAgY2FzZSAndml2aWFuJzoKICAgICAgICBpZiAoc29sZGllciA9
PT0gJ3pfaW5mYW50cnkwMScpIHNvbGRpZXIgPSAnel92aWxsYWdlcjAxJzsKICAgICAgICBlbHNl
IGlmIChzb2xkaWVyID09PSAnel9hcmNoZXIwMScpIHNvbGRpZXIgPSAnel93b21hbjAxJzsKICAg
ICAgICBicmVhazsKICAgICAgY2FzZSAnamVubnknOiBjYXNlICdzaW5hbic6CiAgICAgICAgaWYg
KHNvbGRpZXIgPT09ICd6X2FyY2hlcjAxJykgc29sZGllciA9ICd6X3dvbWFuMDEnOwogICAgICAg
IGJyZWFrOwogICAgICBjYXNlICdqYXNvbic6CiAgICAgICAgaWYgKHNvbGRpZXIgPT09ICd6X2lu
ZmFudHJ5MDEnKSBzb2xkaWVyID0gJ3pfYmFuZGl0MDEnOwogICAgICAgIGVsc2UgaWYgKHNvbGRp
ZXIgPT09ICd6X2FyY2hlcjAxJykgc29sZGllciA9ICd6X2RhZ2dlcjAxJzsKICAgICAgICBlbHNl
IHNvbGRpZXIgPSAnel9zaWNrbGUwMSc7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2UgJ2dpZ2dz
JzogY2FzZSAndGl0dG8nOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9pbmZhbnRyeTAxJykg
c29sZGllciA9ICd6X2JhbmRpdDAxJzsKICAgICAgICBlbHNlIGlmIChzb2xkaWVyID09PSAnel9h
cmNoZXIwMScpIHNvbGRpZXIgPSAnel9kYWdnZXIwMSc7CiAgICAgICAgYnJlYWs7CiAgICAgIGNh
c2UgJ2ljenp5JzoKICAgICAgICBpZiAoc29sZGllciA9PT0gJ3pfY2F2YWxyeTAxJykgc29sZGll
ciA9ICd6X2ljZW1hbic7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2UgJ2hlYXRlcic6CiAgICAg
ICAgaWYgKHNvbGRpZXIgPT09ICd6X2NhdmFscnkwMScpIHNvbGRpZXIgPSAnel9za3VsbCc7CiAg
ICAgICAgYnJlYWs7CiAgICAgIGRlZmF1bHQ6CiAgICAgICAgYnJlYWs7CiAgICB9CiAgICBpZiAo
Y29tbWFuZGVyLmV4aXN0cyAmJiBjb21tYW5kZXIuY29tbWFuZGVyID09PSAtMSAmJiB0aGlzLnBs
YWNlU29sZGllcihpbmRleCwgc29sZGllcikpIHsKICAgICAgdGhpcy5saW1pdE1lbigpOwogICAg
ICByb29tLmJyb2FkY2FzdE1lbigxKTsKICAgIH0KICB9CgogIC8vIGkuYShpbnQsIFN0cmluZykK
ICBwbGFjZVNvbGRpZXIoY29tbWFuZGVySW5kZXgsIHNvbGRpZXIpIHsKICAgIGNvbnN0IHJvb20g
PSB0aGlzLnJvb207CiAgICBpZiAocm9vbS5tZW4uZmlsdGVyKChtYW4pID0+IG1hbi5leGlzdHMp
Lmxlbmd0aCA+PSAxMikgcmV0dXJuIGZhbHNlOwogICAgZm9yIChsZXQgaW5kZXggPSAxMjsgaW5k
ZXggPCBNRU47IGluZGV4ICs9IDEpIHsKICAgICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhd
OwogICAgICBpZiAobWFuLmV4aXN0cykgY29udGludWU7CiAgICAgIGNvbnN0IGNvbW1hbmRlciA9
IHJvb20ubWVuW2NvbW1hbmRlckluZGV4XTsKICAgICAgT2JqZWN0LmFzc2lnbihtYW4sIHsgZXhp
c3RzOiB0cnVlLCBjbGllbnQ6IC0xLCBjb250cm9sbGVyOiAtMSwgdGVhbTogY29tbWFuZGVyLnRl
YW0sIHJhbmRvbTogZmFsc2UsCiAgICAgICAgY29tbWFuZGVyOiBjb21tYW5kZXJJbmRleCwgY2hh
cjogc29sZGllciwgbGV2ZWw6IGNvbW1hbmRlci5sZXZlbCB9KTsKICAgICAgcmV0dXJuIHRydWU7
CiAgICB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQoKICAvLyBpLmYoKTogYXQgbW9zdCAxMiBtZW47
IHRoZSBsYXRlciBvbmVzIGdvLgogIGxpbWl0TWVuKCkgewogICAgbGV0IGNvdW50ID0gMDsKICAg
IGZvciAoY29uc3QgbWFuIG9mIHRoaXMucm9vbS5tZW4pIHsKICAgICAgaWYgKCFtYW4uZXhpc3Rz
KSBjb250aW51ZTsKICAgICAgaWYgKGNvdW50IDwgMTIpIGNvdW50ICs9IDE7CiAgICAgIGVsc2Ug
bWFuLmV4aXN0cyA9IGZhbHNlOwogICAgfQogIH0KCiAgY2hvb3NlQ2hhcmFjdGVyKGRvYykgewog
ICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGlmIChyb29tLnBhZ2UgIT09ICdDSEFSTUVO
VScpIHJldHVybjsKICAgIGNvbnN0IGluZGV4ID0gaW50KHRhZ1ZhbHVlKGRvYywgJ2knKSk7CiAg
ICBjb25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICBpZiAoIW1hbikgdGhyb3cgbmV3IFht
bEVycm9yKCdubyBzdWNoIG1hbicpOwogICAgaWYgKCFtYW4uZXhpc3RzIHx8IChtYW4uY29udHJv
bGxlciAhPT0gLTEgJiYgbWFuLmNsaWVudCAhPT0gdGhpcy5pbmRleCkpIHJldHVybjsKICAgIG1h
bi5jaGFyID0gdGFnVmFsdWUoZG9jLCAnY2hhcicpOwogICAgaWYgKG1hbi5jaGFyID09PSBudWxs
KSB0aHJvdyBuZXcgWG1sRXJyb3IoJ25vIGNoYXJhY3RlcicpOwogICAgaWYgKG1hbi5jaGFyID09
PSAncmFuZG9tJykgewogICAgICBtYW4ucmFuZG9tID0gdHJ1ZTsKICAgICAgdGhpcy5waWNrQ2hh
cmFjdGVyKGluZGV4KTsKICAgIH0gZWxzZSB7CiAgICAgIG1hbi5yYW5kb20gPSBmYWxzZTsKICAg
IH0KICAgIG1hbi5sZXZlbCA9IDE7CiAgICBjb25zdCBjaGFyYWN0ZXIgPSBDSEFSQUNURVJTLmlu
ZGV4T2YobWFuLmNoYXIpOwogICAgaWYgKGNoYXJhY3RlciA+PSAwKSB7CiAgICAgIGNvbnN0IGxl
dmVsID0gbWFuLmNvbnRyb2xsZXIgPT09IC0xID8gcm9vbS5jb21wdXRlckxldmVsKGNoYXJhY3Rl
cikgOiB0aGlzLnNsb3QubGV2ZWxzW2NoYXJhY3Rlcl07CiAgICAgIGlmIChsZXZlbCA+IDApIHsK
ICAgICAgICBtYW4ubGV2ZWwgPSBsZXZlbDsKICAgICAgICBmb3IgKGNvbnN0IG90aGVyIG9mIHJv
b20ubWVuKSBpZiAob3RoZXIuZXhpc3RzICYmIG90aGVyLmNvbW1hbmRlciA9PT0gaW5kZXgpIG90
aGVyLmxldmVsID0gbGV2ZWw7CiAgICAgIH0KICAgICAgaWYgKGxldmVsIDw9IDAgJiYgbWFuLmNv
bnRyb2xsZXIgPj0gMCAmJiBtYW4uY2xpZW50ID09PSB0aGlzLmluZGV4KSB7CiAgICAgICAgLy8g
QSBjaGFyYWN0ZXIgdGhpcyBhY2NvdW50IGhhcyBub3QgdW5sb2NrZWQ6IHRoZSBvcmlnaW5hbCBz
aHV0cyB0aGUgZ2FtZSBvdXQuCiAgICAgICAgdGhpcy5raWNrZWQgPSB0cnVlOwogICAgICAgIHRo
aXMubGVhdmUoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgIH0KICAgIHJvb20uYnJvYWRj
YXN0TWVuKDApOwogIH0KCiAgLy8gaS5kKGludCk6IGEgcmFuZG9tIGNoYXJhY3RlciBmb3IgYSBt
YW46IG9uZSB0aGUgY29tcHV0ZXIgaGFzLCBub3QgdGFrZW4gYnkgYW5vdGhlciBtYW4gYmVmb3Jl
IGl0CiAgLy8gb3Igbm90IHJhbmRvbTsgdGhlIGxldmVsIHRvIG1hdGNoLiAoVGhlIG9yaWdpbmFs
IGdhdmUgYSBjb21wdXRlciBwbGF5ZXIgb25lIG9mIHRoZSBjaGFyYWN0ZXJzIHNvbWUKICAvLyBj
b21wdXRlciBpbiB0aGUgcm9vbSBoYXM7IGhlcmUgaXQgbWF5IGJlIGFueSwgdGhlIHByZW1pdW0g
b25lcyB0b28sIHdoaWNoIHBsYXllcnMnIGFjY291bnRzIGRvIG5vdAogIC8vIGhhdmU6IHNlZSBo
Zi5qcy4gTm90IFlhZ2EsIHdob20gdGhlIGdhbWUgZG9lcyBub3QgbGV0IGFueW9uZSBwbGF5LikK
ICBwaWNrQ2hhcmFjdGVyKGluZGV4KSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAg
Y29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhdOwogICAgY29uc3QgaHVtYW4gPSBtYW4uY2xpZW50
ICE9PSAtMTsKICAgIGxldCBvd25lciA9IG1hbi5jbGllbnQ7CiAgICBpZiAob3duZXIgPT09IC0x
IHx8ICFyb29tLnNsb3RzW293bmVyXS5vbmxpbmUpIG93bmVyID0gdGhpcy5pbmRleDsKICAgIGNv
bnN0IHNsb3QgPSByb29tLnNsb3RzW293bmVyXTsKICAgIGNvbnN0IGF2YWlsYWJsZSA9ICgpID0+
IHsKICAgICAgY29uc3QgbGlzdCA9IFtdOwogICAgICBmb3IgKGNvbnN0IG5hbWUgb2YgQ0hBUkFD
VEVSUykgewogICAgICAgIGNvbnN0IGNoYXJhY3RlciA9IENIQVJBQ1RFUlMuaW5kZXhPZihuYW1l
KTsKICAgICAgICBpZiAoaHVtYW4gPyBzbG90LmxldmVsc1tjaGFyYWN0ZXJdID4gMCA6IG5hbWUg
IT09ICd5YWdhJykgbGlzdC5wdXNoKG5hbWUpOwogICAgICB9CiAgICAgIHJldHVybiBsaXN0Owog
ICAgfTsKICAgIGxldCBsaXN0ID0gYXZhaWxhYmxlKCk7CiAgICByb29tLm1lbi5mb3JFYWNoKChv
dGhlciwgaykgPT4gewogICAgICBpZiAoIW90aGVyLmV4aXN0cyB8fCAob3RoZXIucmFuZG9tICYm
IGsgPj0gaW5kZXgpKSByZXR1cm47CiAgICAgIGZvciAobGV0IG4gPSAwOyBuIDwgbGlzdC5sZW5n
dGg7IG4gKz0gMSkgaWYgKGxpc3Rbbl0gPT09IG90aGVyLmNoYXIpIGxpc3Quc3BsaWNlKG4sIDEp
OwogICAgfSk7CiAgICBpZiAoIWxpc3QubGVuZ3RoKSBsaXN0ID0gYXZhaWxhYmxlKCk7CiAgICBp
ZiAoIWxpc3QubGVuZ3RoKSB0aHJvdyBuZXcgWG1sRXJyb3IoJ25vIGNoYXJhY3RlcnMnKTsKICAg
IG1hbi5jaGFyID0gbGlzdFt0aGlzLnJvb20ubmV4dEludChsaXN0Lmxlbmd0aCldOwogICAgY29u
c3QgY2hhcmFjdGVyID0gQ0hBUkFDVEVSUy5pbmRleE9mKG1hbi5jaGFyKTsKICAgIG1hbi5sZXZl
bCA9IDE7CiAgICBpZiAoaHVtYW4pIHsKICAgICAgaWYgKHNsb3QubGV2ZWxzW2NoYXJhY3Rlcl0g
PiAwKSBtYW4ubGV2ZWwgPSBzbG90LmxldmVsc1tjaGFyYWN0ZXJdOwogICAgfSBlbHNlIHsKICAg
ICAgbWFuLmxldmVsID0gcm9vbS5jb21wdXRlckxldmVsKGNoYXJhY3Rlcik7CiAgICB9CiAgICBm
b3IgKGNvbnN0IG90aGVyIG9mIHJvb20ubWVuKSBpZiAob3RoZXIuZXhpc3RzICYmIG90aGVyLmNv
bW1hbmRlciA9PT0gaW5kZXgpIG90aGVyLmxldmVsID0gbWFuLmxldmVsOwogIH0KCiAgLy8gaS5n
KFN0cmluZyk6IGNoYXQgdGhhdCBzdGFydHMgd2l0aCAiLyIgaXMgYSBjb21tYW5kLiBSZXR1cm5z
IHdoZXRoZXIgdGhlIGxpbmUgZ29lcyB0byBldmVyeW9uZS4KICBjb21tYW5kKHRleHQpIHsKICAg
IGlmICh0ZXh0ID09PSBudWxsKSByZXR1cm4gdHJ1ZTsKICAgIGNvbnN0IG1lc3NhZ2UgPSB0ZXh0
LnRyaW0oKTsKICAgIGlmICghbWVzc2FnZSB8fCBtZXNzYWdlWzBdICE9PSAnLycpIHJldHVybiB0
cnVlOwogICAgY29uc3Qgd29yZHMgPSBtZXNzYWdlLnNwbGl0KC9ccysvKTsKICAgIGNvbnN0IG5h
bWUgPSB3b3Jkc1swXS50b0xvd2VyQ2FzZSgpOwogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsK
ICAgIGlmIChuYW1lID09PSAnL2hlbHAnKSB7CiAgICAgIGlmICh3b3Jkcy5sZW5ndGggPiAxKSBy
ZXR1cm4gdHJ1ZTsKICAgICAgdGhpcy5ub3RpY2UoJzxiPkNvbW1hbmRzIGF2YWlsYWJsZTwvYj46
ICAvcXVpdCwgL2NsZWFyLCAvbWUsIC9sYXQuIDxiciAvPlR5cGUgPyBhZnRlciBhIGNvbW1hbmQg
dG8gbGVhcm4gYWJvdXQgaXQuIEUuZy46IC9xdWl0ID8gJyk7CiAgICAgIHJldHVybiB0cnVlOwog
ICAgfQogICAgaWYgKG5hbWUgPT09ICcvcXVpdCcgfHwgbmFtZSA9PT0gJy9leGl0JykgewogICAg
ICBpZiAod29yZHMubGVuZ3RoID4gMSAmJiB3b3Jkc1sxXSA9PT0gJz8nKSB7CiAgICAgICAgdGhp
cy5ub3RpY2UoJzxiPlF1aXQ8L2I+OiBZb3Ugd2lsbCBleGl0IHRoZSByb29tLjxiciAvPklucHV0
czogL3F1aXQsIC9leGl0LicpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAgICAgIHRo
aXMua2lja2VkID0gdHJ1ZTsKICAgICAgdGhpcy5sZWF2ZSgpOwogICAgICB0aGlzLmNsb3NlKCk7
CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYgKG5hbWUgPT09ICcvY2xlYXInIHx8IG5h
bWUgPT09ICcvY2xlYW4nKSB7CiAgICAgIGlmICh3b3Jkcy5sZW5ndGggPiAxKSB7CiAgICAgICAg
aWYgKHdvcmRzWzFdID09PSAnPycpIHRoaXMubm90aWNlKCc8Yj5DbGVhcjwvYj46IFdpbGwgY2xl
YXIgYWxsIHRoZSBjaGF0IG9uIHlvdXIgc2NyZWVuLjxiciAvPklucHV0czogL2NsZWFyLCAvY2xl
YW4uJyk7CiAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgIH0KICAgICAgZm9yIChsZXQgayA9IDA7
IGsgPCA1MDsgayArPSAxKSB0aGlzLm5vdGljZSgnPGJyIC8+Jyk7CiAgICAgIGZvciAoY29uc3Qg
c2xvdCBvZiByb29tLm9ubGluZSgpKSB7CiAgICAgICAgaWYgKHNsb3QuY29ubmVjdGlvbiAhPT0g
dGhpcykgc2xvdC5jb25uZWN0aW9uLnNlbmQoYDxjaGF0PjxjPiR7dGhpcy5pbmRleH08L2M+PG0+
PCFbQ0RBVEFbJHt3b3Jkc1swXX1dXT48L20+PC9jaGF0PmApOwogICAgICB9CiAgICAgIHJldHVy
biBmYWxzZTsKICAgIH0KICAgIGlmIChuYW1lID09PSAnL21lJykgewogICAgICBpZiAod29yZHMu
bGVuZ3RoID4gMSAmJiB3b3Jkc1sxXSAhPT0gJz8nKSB7CiAgICAgICAgdGhpcy5hbm5vdW5jZShg
PGZvbnQgY29sb3I9IiNDQ0NDRkYiPjxpPio8Yj4gJHt0aGlzLm5hbWV9PC9iPiAke3dvcmRzLnNs
aWNlKDEpLmpvaW4oJyAnKX0gPC9pPjwvZm9udD5gKTsKICAgICAgICByZXR1cm4gZmFsc2U7CiAg
ICAgIH0KICAgICAgdGhpcy5ub3RpY2UoJzxiPk1FPC9iPjogU2VuZHMgdGhlIGFjdGlvbiB0byB0
aGUgY2hhdCAoYWN0aW9ucyBhcmUgd3JpdHRlbiBpbiB0aGUgM3JkIHBlcnNvbiwgbGlrZSAvbWUg
anVtcHMpLicpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChuYW1lID09PSAnL2xh
dCcgfHwgbmFtZSA9PT0gJy9sYXRlbmN5JykgewogICAgICBjb25zdCBoZWxwID0gJ0l0IHdpbGwg
bmVlZCBhIGxhdGVuY3kgbnVtYmVyIGJldHdlZW4gMSBhbmQgOTkgYWZ0ZXIgdGhlIGNvbW1hbmQu
IEUuZy46IC9sYXQgNyc7CiAgICAgIGlmICh3b3Jkcy5sZW5ndGggPD0gMSkgdGhpcy5ub3RpY2Uo
YDxiPkxhdGVuY3k8L2I+OiAke2hlbHB9YCk7CiAgICAgIGVsc2UgaWYgKHdvcmRzWzFdID09PSAn
PycpIHRoaXMubm90aWNlKGA8Yj5MYXRlbmN5PC9iPjogQ2hhbmdlcyB5b3VyIGxhdGVuY3kuICR7
aGVscH08YnIgLz5JbnB1dHM6IC9sYXQsIC9sYXRlbmN5LmApOwogICAgICBlbHNlIGlmICghL15b
LStdP1xkKyQvLnRlc3Qod29yZHNbMV0pKSB0aGlzLm5vdGljZShgPGI+TGF0ZW5jeTwvYj46ICR7
aGVscH1gKTsKICAgICAgZWxzZSB7CiAgICAgICAgY29uc3QgdmFsdWUgPSBOdW1iZXIod29yZHNb
MV0pOwogICAgICAgIGlmICh2YWx1ZSA8PSAwKSB0aGlzLm5vdGljZSgnPGI+TGF0ZW5jeTwvYj46
IFlvdXIgbGF0ZW5jeSBtdXN0IGJlIGJldHdlZW4gMSBhbmQgOTkuJyk7CiAgICAgICAgZWxzZSBp
ZiAodmFsdWUgPiA5OSkgdGhpcy5ub3RpY2UoJ1JlYWxseT8nKTsKICAgICAgICBlbHNlIHsKICAg
ICAgICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3Q7CiAgICAgICAgICBzbG90LmxhdGVuY3kgPSB2
YWx1ZSArIDE7CiAgICAgICAgICBzbG90LmxhdGVuY3lUYXJnZXQgPSBzbG90LmxhdGVuY3k7CiAg
ICAgICAgICB0aGlzLm5vdGljZShgPGI+TGF0ZW5jeTwvYj46IFlvdXIgbGF0ZW5jeSBoYXMgYmVl
biBjaGFuZ2VkIHRvICR7c2xvdC5sYXRlbmN5IC0gMX0uYCk7CiAgICAgICAgICByb29tLmJyb2Fk
Y2FzdExpc3QoLTEsIC0xKTsKICAgICAgICB9CiAgICAgIH0KICAgICAgcmV0dXJuIHRydWU7CiAg
ICB9CiAgICB0aGlzLm5vdGljZSgnVW5yZWNvZ25pemVkIGNvbW1hbmQuJyk7CiAgICByZXR1cm4g
dHJ1ZTsKICB9Cn0KCm1vZHVsZS5leHBvcnRzID0geyBIZlJvb20sIEhmQ29ubmVjdGlvbiwgcGFy
c2VYbWwsIGJ5VGFnLCB2YWx1ZU9mLCBYbWxFcnJvciwgZml4Q29tbWFuZE51bWJlciwgVkVSU0lP
TiwgQ0xJRU5UUywgQ0hBUkFDVEVSUyB9Owo=
LF2_PAYLOAD
}
write_hoc_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IE1JVAovLwovLyBSZWluZm9yY2VtZW50IGxlYXJu
aW5nIG9uIG1hbnkgbWFjaGluZXMgKHBhY2thZ2UgOTApOiB0aGUgcmVsYXkgaGFuZHMgdGhlIGZp
Z2h0ZXJzIG9mIGEgam9iIG91dCB0byB0aGUKLy8gbWFjaGluZXMgdGhhdCBhc2sgZm9yIHdvcmsg
KHRoZSBYT0kga2l0J3MgbWF5LWNvbi5iYXQsIG9uZSBmaWdodGVyIHRvIGVhY2ggc2xvdCBvZiBh
IG1hY2hpbmUpIGFuZCBrZWVwcyB3aGF0Ci8vIGEgbWFjaGluZSBzZW5kcyBiYWNrIHdoZW4gaXRz
IGZpZ2h0ZXIgaXMgZG9uZSAodG9tLXRhdC50eHQsIHhhYy1uaGFuLnR4dCwgdGhlIGNob3NlbiBu
ZXR3b3JrKSwgZm9yIHRoZQovLyBvd25lcidzIG1hY2hpbmUgdG8gZG93bmxvYWQgKGR1YS1iby1u
YW8tdmFvLW1vZC5iYXQpLiBUaGUgbWFjaGluZXMgZG8gdGhlIGxlYXJuaW5nIChob2MtdGFuZy1j
dW9uZy5iYXQpOyB0aGUKLy8gcmVsYXkgb25seSBwYXNzZXMgc21hbGwgdGV4dCBmaWxlcywgYWJv
dXQgMSBNQiBhIGZpZ2h0ZXIsIGFuZCB0aGUgbW9kIG9uY2UgdG8gZWFjaCBtYWNoaW5lIHRoYXQg
YXNrcyBmb3IgaXQuCi8vCi8vIFRoZSBqb2IgaXMgc2V0IG9uIHRoZSBwYWdlIC9ob2Mgd2l0aCBB
RE1JTl9LRVk7IHRoZSBtYWNoaW5lcyB1c2UgdGhlIGpvYidzIG93biBrZXkgKFgtSG9jLUtleSks
IHdoaWNoIHRoZSBwYWdlCi8vIHdyaXRlcyBpbnRvIHRoZSBmaWxlIG1heS1jb24tY2FpLWRhdC5i
YXQgaXQgZ2l2ZXMgb3V0LiBLZXB0IGluIEhPQ19ESVIgKGRlZmF1bHQgPFBBQ0tTX0RJUj4vaG9j
KTogdmllYy5qc29uCi8vICh0aGUgam9iIGFuZCBldmVyeSBmaWdodGVyJ3Mgc3RhdGUpIGFuZCBu
di88ZmlnaHRlcj4vICh0aGUgZmlsZXMgc2VudCBiYWNrKS4KLy8KLy8gICBHRVQgICAgL2hvYyAg
ICAgICAgICAgICAgICAgICAgICAgICAgIHRoZSBwYWdlCi8vICAgR0VUICAgIC9ob2MvYXBpL3Ry
YW5nLXRoYWkgICAgICAgICAgICB0aGUgam9iIGFuZCBpdHMgZmlnaHRlcnMgKEpTT047IFgtQWRt
aW4tS2V5KQovLyAgIFBVVCAgICAvaG9jL2FwaS9jYWktZGF0ICAgICAgICAgICAgICAgdGhlIG1v
ZCBhbmQgdGhlIHNldHRpbmdzOiB7InBhY2siLCJzZXR0aW5ncyJ9IChYLUFkbWluLUtleSkKLy8g
ICBQT1NUICAgL2hvYy9hcGkvdGhlbSAgICAgICAgICAgICAgICAgIGFkZCBmaWdodGVyczogeyJm
aWdodGVycyI6IjE2IDI1IDgifSAoWC1BZG1pbi1LZXkpCi8vICAgUE9TVCAgIC9ob2MvYXBpL3Ry
YS1sYWkvPGZpZ2h0ZXI+ICAgICBoYW5kIGl0IG91dCBhZ2FpbiAoWC1BZG1pbi1LZXkpCi8vICAg
REVMRVRFIC9ob2MvYXBpL252LzxmaWdodGVyPiAgICAgICAgICB0YWtlIGl0IG9mZiB0aGUgam9i
LCB3aXRoIGl0cyBmaWxlcyAoWC1BZG1pbi1LZXkpCi8vICAgUE9TVCAgIC9ob2MvYXBpL3ZpZWMt
bW9pICAgICAgICAgICAgICBhIG5ldyBqb2I6IGV2ZXJ5IGZpZ2h0ZXIgZ29lcywgd2l0aCBpdHMg
ZmlsZXMgLSB0aGUga2V5LCB0aGUgbW9kIGFuZCB0aGUKLy8gICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIHNldHRpbmdzIHN0YXkgKFgtQWRtaW4tS2V5OyBwYWNrYWdlIDk0
KS4gVGhlIHJlc3VsdHMgYXJlIGtlcHQgYnkgZmlnaHRlcgovLyAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgKGFuIGlkLCBvciBhIG5hbWUpLCBhbmQgdHdvIG1vZHMgbW9z
dGx5IHNoYXJlIGlkczogdGhlIGpvYiBvZiBhIG1vZCBkb25lLAovLyAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgYSBuZXcgb25lIGtlZXBzIGl0cyByZXN1bHRzIGZyb20g
YmVpbmcgdGFrZW4gZm9yIHRoZSBuZXh0IG1vZCdzLgovLyAgIFBPU1QgICAvaG9jL2FwaS9kb2kt
bWEgICAgICAgICAgICAgICAgYSBuZXcga2V5IGZvciB0aGUgbWFjaGluZXMgKFgtQWRtaW4tS2V5
KQovLyBUaGUgbWFjaGluZXMnIHJlcXVlc3RzIChYLUhvYy1LZXksIG9yIFgtQWRtaW4tS2V5OyBh
bnN3ZXJzIGFzIEtFWT12YWx1ZSBsaW5lcywgd2hpY2ggYSAuYmF0IGZpbGUgcmVhZHMsIGFuZAov
LyBMT0k9PHdoYXQgd2VudCB3cm9uZz4gd2l0aCBhbiBlcnJvciBzdGF0dXMpOgovLyAgIEdFVCAg
ICAvaG9jL2FwaS92aWVjICAgICAgICAgICAgICAgICAgdGhlIHNldHRpbmdzLCBhbmQgdGhlIG1v
ZCdzIFBBQ0tfSUQgYW5kIFBBQ0tfU0hBMjU2IChub25lOiBlYWNoIG1hY2hpbmUncyBvd24pCi8v
ICAgR0VUICAgIC9ob2MvYXBpL2Jhbi1tb2QgICAgICAgICAgICAgICB0aGUgam9iJ3MgbW9kIChv
bmUgb2YgdGhlIHJlbGF5J3MgcGFja3MpCi8vICAgUE9TVCAgIC9ob2MvYXBpL25oYW4/bWF5PTxz
bG90PiAgICAgICB0aGUgZmlnaHRlciB0aGF0IHNsb3QgaG9sZHMsIGVsc2UgdGhlIG5leHQgd2Fp
dGluZyBvbmUgKE5WPS4uLiksIG9yIEhFVD0xCi8vICAgUE9TVCAgIC9ob2MvYXBpL2Jhby88Zmln
aHRlcj4/bWF5PTxzbG90PiZ2b25nPTxuPiAgIGEgY2hlY2sncyBsaW5lcyAodGhlIGJvZHkpLCBh
cyBpdCBsZWFybnMKLy8gICBQVVQgICAgL2hvYy9hcGkvbm9wLzxmaWdodGVyPi88ZmlsZT4/bWF5
PTxzbG90PiAgICAgYSBmaWxlIG9mIGl0cyByZXN1bHRzICh0aGUgYm9keSkKLy8gICBQT1NUICAg
L2hvYy9hcGkveG9uZy88ZmlnaHRlcj4/bWF5PTxzbG90PiAgICAgICAgICAgZG9uZSAodG9tLXRh
dC50eHQgc2VudCBiZWZvcmUpCi8vICAgUE9TVCAgIC9ob2MvYXBpL2xvaS88ZmlnaHRlcj4/bWF5
PTxzbG90PiAgICAgICAgICAgIGZhaWxlZCAodGhlIGJvZHk6IHRoZSBlbmQgb2YgaXRzIGFjY291
bnQpCi8vICAgUE9TVCAgIC9ob2MvYXBpL3RyYS88ZmlnaHRlcj4/bWF5PTxzbG90PiAgICAgICAg
ICAgIGdpdmVuIGJhY2s6IHRoYXQgbWFjaGluZSBjYW5ub3QgbGVhcm4gKG5vIGdhbWUsIG5vIG1v
ZC4uLiksCi8vICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICBhbm90aGVyIG1heSB0YWtlIGl0IChwYWNrYWdlIDkxKQovLyAgIEdFVCAgICAvaG9j
L2FwaS9rZXQtcXVhICAgICAgICAgICAgICAgdGhlIGZpZ2h0ZXJzIGRvbmU6ICI8ZmlnaHRlcj4g
PGZpbGU+IDxmaWxlPi4uLiIgbGluZXMKLy8gICBHRVQgICAgL2hvYy9hcGkvdGVwLzxmaWdodGVy
Pi88ZmlsZT4gIG9uZSBvZiB0aGVpciBmaWxlcwondXNlIHN0cmljdCc7Cgpjb25zdCBjcnlwdG8g
PSByZXF1aXJlKCdub2RlOmNyeXB0bycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ25vZGU6ZnMnKTsK
Y29uc3QgZnNwID0gcmVxdWlyZSgnbm9kZTpmcy9wcm9taXNlcycpOwpjb25zdCBwYXRoID0gcmVx
dWlyZSgnbm9kZTpwYXRoJyk7CgovLyBBIGZpZ2h0ZXIgYXMgaG9jLXRhbmctY3VvbmcuYmF0IHRh
a2VzIGl0IChhbiBpZCwgb3IgYSBuYW1lIHRoZSBtb2Qga25vd3MpIGFuZCB0aGUgZm9sZGVyIG5h
bWVkIGFmdGVyIGl0Lgpjb25zdCBGSUdIVEVSID0gL15bQS1aYS16MC05XVtBLVphLXowLTlfLi1d
ezAsMzl9JC87Ci8vIEEgbWFjaGluZSdzIHNsb3QsIGFzIG1heS1jb24uYmF0IG5hbWVzIGl0OiA8
bWFjaGluZT4tbzxuPi4KY29uc3QgU0xPVCA9IC9eW0EtWmEtejAtOV1bQS1aYS16MC05Xy4tXXsw
LDYzfSQvOwovLyBUaGUgZmlsZXMgb2YgYSBmaWdodGVyJ3MgcmVzdWx0cyB0aGF0IGEgbWFjaGlu
ZSBtYXkgc2VuZC4KY29uc3QgUkVTVUxUID0gL14odG9tLXRhdHx4YWMtbmhhbnx0b3QtbmhhdHxi
by1uYW8tdG90LW5oYXR8Ym8tbmFvLVswLTldezEsNn18eGFjLW5oYW4tWzAtOV17MSw2fXxraWVt
LXRyYS1bMC05XXsxLDZ9KVwudHh0JC87CmNvbnN0IFBBQ0tfSUQgPSAvXlthLXowLTldW2EtejAt
OS1dezAsMzl9JC87CmNvbnN0IE1JQiA9IDEwMjQgKiAxMDI0Owpjb25zdCBGSUxFX0xJTUlUID0g
MTYgKiBNSUI7CmNvbnN0IEZJR0hURVJfTElNSVQgPSA2NCAqIE1JQjsKY29uc3QgVEVYVF9MSU1J
VCA9IDY0ICogMTAyNDsKY29uc3QgTUFYX0ZJR0hURVJTID0gMjAwMDsKLy8gVGhlIHNldHRpbmdz
IGEgbWFjaGluZSBsZWFybnMgYSBmaWdodGVyIHdpdGggKGhvYy10YW5nLWN1b25nLmJhdCdzIG5h
bWVzKTogZGVmYXVsdCwgbGVhc3QsIG1vc3QuIE1PSV9OViBpcwovLyBob3cgbWFueSBwcm9jZXNz
ZXMgYSBmaWdodGVyIGdldHM6IGEgbWFjaGluZSB0YWtlcyBhcyBtYW55IGZpZ2h0ZXJzIGF0IG9u
Y2UgYXMgaXQgaGFzIHRocmVhZHMgZm9yLiBEVU5HX1NPTQovLyAocGFja2FnZSA5Nyk6IGEgZmln
aHRlciB3aG9zZSBjaGVja3MgaGF2ZSBub3QgZ290IGJldHRlciBmb3IgdGhhdCBtYW55IHJvdW5k
cyBzdG9wcyBlYXJseSAoMDogbmV2ZXIpLCBhbmQgaXRzCi8vIHNsb3QgdGFrZXMgdGhlIG5leHQg
b25lOyBWT05HIGlzIHRoZW4gdGhlIG1vc3QgaXQgbGVhcm5zLgpjb25zdCBTRVRUSU5HUyA9IHsK
ICBWT05HOiBbNTAwLCAxLCAxMDAwMDBdLAogIFRSQU46IFsyMCwgMSwgMTAwMF0sCiAgS0lFTV9U
UkFfTU9JOiBbNTAsIDAsIDEwMDAwMF0sCiAgVFJBTl9LSUVNX1RSQTogWzEyLCAxLCAxMDAwXSwK
ICBUUkFOX1hBQ19OSEFOOiBbNzIwLCAwLCAxMDAwMDAwXSwKICBNT0lfTlY6IFszMywgMSwgMTAy
NF0sCiAgRFVOR19TT006IFs0MDAsIDAsIDEwMDAwMF0sCn07CmNvbnN0IFNUQVRFUyA9IG5ldyBT
ZXQoWydjaG8nLCAnZGFuZycsICd4b25nJywgJ2xvaSddKTsKCmZ1bmN0aW9uIHNhbWVLZXkoZ2l2
ZW4sIGV4cGVjdGVkKSB7CiAgY29uc3QgYSA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYnKS51
cGRhdGUoU3RyaW5nKGdpdmVuIHx8ICcnKSkuZGlnZXN0KCk7CiAgY29uc3QgYiA9IGNyeXB0by5j
cmVhdGVIYXNoKCdzaGEyNTYnKS51cGRhdGUoU3RyaW5nKGV4cGVjdGVkKSkuZGlnZXN0KCk7CiAg
cmV0dXJuIGNyeXB0by50aW1pbmdTYWZlRXF1YWwoYSwgYik7Cn0KCmNsYXNzIEFuc3dlciBleHRl
bmRzIEVycm9yIHsKICBjb25zdHJ1Y3RvcihzdGF0dXMsIG1lc3NhZ2UpIHsKICAgIHN1cGVyKG1l
c3NhZ2UpOwogICAgdGhpcy5zdGF0dXMgPSBzdGF0dXM7CiAgfQp9CgpmdW5jdGlvbiBjbGVhblNl
dHRpbmdzKGdpdmVuKSB7CiAgY29uc3Qgc2V0dGluZ3MgPSB7fTsKICBmb3IgKGNvbnN0IFtuYW1l
LCBbZmFsbGJhY2ssIGxlYXN0LCBtb3N0XV0gb2YgT2JqZWN0LmVudHJpZXMoU0VUVElOR1MpKSB7
CiAgICBjb25zdCB2YWx1ZSA9IE51bWJlcihnaXZlbiAmJiBnaXZlbltuYW1lXSk7CiAgICBzZXR0
aW5nc1tuYW1lXSA9IE51bWJlci5pc0ludGVnZXIodmFsdWUpICYmIHZhbHVlID49IGxlYXN0ICYm
IHZhbHVlIDw9IG1vc3QgPyB2YWx1ZSA6IGZhbGxiYWNrOwogIH0KICByZXR1cm4gc2V0dGluZ3M7
Cn0KCmZ1bmN0aW9uIGNsZWFuRmlnaHRlcihnaXZlbikgewogIGNvbnN0IHRleHQgPSAodmFsdWUs
IGxpbWl0ID0gMjAwKSA9PiAodHlwZW9mIHZhbHVlID09PSAnc3RyaW5nJyA/IHZhbHVlLnNsaWNl
KDAsIGxpbWl0KSA6ICcnKTsKICBjb25zdCBudW1iZXIgPSAodmFsdWUpID0+ICh0eXBlb2YgdmFs
dWUgPT09ICdudW1iZXInICYmIE51bWJlci5pc0Zpbml0ZSh2YWx1ZSkgPyB2YWx1ZSA6IG51bGwp
OwogIHJldHVybiB7CiAgICBzdGF0ZTogU1RBVEVTLmhhcyhnaXZlbi5zdGF0ZSkgPyBnaXZlbi5z
dGF0ZSA6ICdjaG8nLAogICAgbWF5OiBTTE9ULnRlc3QoZ2l2ZW4ubWF5IHx8ICcnKSA/IGdpdmVu
Lm1heSA6ICcnLAogICAgc2luY2U6IHRleHQoZ2l2ZW4uc2luY2UsIDQwKSwKICAgIHVwZGF0ZWQ6
IHRleHQoZ2l2ZW4udXBkYXRlZCwgNDApLAogICAgdm9uZzogTnVtYmVyLmlzSW50ZWdlcihnaXZl
bi52b25nKSA/IGdpdmVuLnZvbmcgOiAwLAogICAga2llbTogbnVtYmVyKGdpdmVuLmtpZW0pLCAv
LyB0aGUgbGFzdCBjaGVjaydzICJuZXR3b3JrIC0gWE9JIiwgcG9pbnRzIHBlciAxMDAgZ2FtZXMK
ICAgIHRlbjogdGV4dChnaXZlbi50ZW4sIDYwKSwgLy8gdGhlIGZpZ2h0ZXIncyBuYW1lIGluIHRo
ZSBtb2QsIGZyb20gdG9tLXRhdC50eHQKICAgIGNob246IE51bWJlci5pc0ludGVnZXIoZ2l2ZW4u
Y2hvbikgPyBnaXZlbi5jaG9uIDogMCwgLy8gdGhlIHJvdW5kIG9mIHRoZSBuZXR3b3JrIGNob3Nl
biAoeGFjLW5oYW4udHh0KQogICAgZGllbTogbnVtYmVyKGdpdmVuLmRpZW0pLCAvLyBpdHMgc2Nv
cmUgb24gbmV3IGdhbWVzLCBwb2ludHMgcGVyIDEwMCBnYW1lcwogICAgY3VvaTogTnVtYmVyLmlz
SW50ZWdlcihnaXZlbi5jdW9pKSA/IGdpdmVuLmN1b2kgOiAwLCAvLyB0aGUgcm91bmRzIGl0IGxl
YXJuZWQgKHRvbS10YXQudHh0J3MgbGFzdCBLRVQgVEhVQyBsaW5lKQogICAgZHVuZzogZ2l2ZW4u
ZHVuZyA9PT0gdHJ1ZSwgLy8gaXQgc3RvcHBlZCBlYXJseTogbm8gYmV0dGVyIGZvciBEVU5HX1NP
TSByb3VuZHMKICAgIGZpbGVzOiBBcnJheS5pc0FycmF5KGdpdmVuLmZpbGVzKSA/IGdpdmVuLmZp
bGVzLmZpbHRlcigobmFtZSkgPT4gUkVTVUxULnRlc3QobmFtZSkpIDogW10sCiAgICBsb2k6IHRl
eHQoZ2l2ZW4ubG9pLCAyMDAwKSwKICAgIHhvbmc6IHRleHQoZ2l2ZW4ueG9uZywgNDApLAogIH07
Cn0KCi8vICJuZXR3b3JrIC0gWE9JICszOC4wIHBvaW50cyIgb2YgYSBjaGVjaydzIGdyZWVkeSBs
aW5lLgpmdW5jdGlvbiBjaGVja1Njb3JlKHRleHQpIHsKICBjb25zdCBsaW5lID0gU3RyaW5nKHRl
eHQpLnNwbGl0KC9ccj9cbi8pLmZpbmQoKG9uZSkgPT4gL2dyZWVkeS8udGVzdChvbmUpKSB8fCBT
dHJpbmcodGV4dCk7CiAgY29uc3QgZm91bmQgPSBsaW5lLm1hdGNoKC9uZXR3b3JrIC0gWE9JIChb
Ky1dP1swLTkuXSspIHBvaW50cy8pOwogIHJldHVybiBmb3VuZCA/IE51bWJlcihmb3VuZFsxXSkg
OiBudWxsOwp9CgpmdW5jdGlvbiBjcmVhdGVIb2MoY29uZmlnLCB7IGxvZyA9ICgpID0+IHt9LCBj
bGllbnRBZGRyZXNzID0gKHJlcSkgPT4gcmVxLnNvY2tldC5yZW1vdGVBZGRyZXNzIHx8ICd1bmtu
b3duJyB9ID0ge30pIHsKICBjb25zdCBkaXJlY3RvcnkgPSBjb25maWcuaG9jRGlyIHx8IChjb25m
aWcucGFja3NEaXIgPyBwYXRoLmpvaW4oY29uZmlnLnBhY2tzRGlyLCAnaG9jJykgOiAnJyk7CiAg
Y29uc3QgZmFpbHVyZXMgPSBuZXcgTWFwKCk7IC8vIGNsaWVudCBhZGRyZXNzIC0+IHsgY291bnQs
IHVudGlsIH06IHdyb25nIGtleXMKICBjb25zdCBqb2IgPSBsb2FkKCk7CgogIGZ1bmN0aW9uIGJs
YW5rKCkgewogICAgcmV0dXJuIHsga2V5OiAnJywgcGFjazogJycsIHNldHRpbmdzOiBjbGVhblNl
dHRpbmdzKHt9KSwgb3JkZXI6IFtdLCBmaWdodGVyczoge30gfTsKICB9CgogIGZ1bmN0aW9uIGxv
YWQoKSB7CiAgICBjb25zdCBmcmVzaCA9IGJsYW5rKCk7CiAgICBpZiAoIWRpcmVjdG9yeSkgcmV0
dXJuIGZyZXNoOwogICAgbGV0IGRhdGE7CiAgICB0cnkgeyBkYXRhID0gSlNPTi5wYXJzZShmcy5y
ZWFkRmlsZVN5bmMocGF0aC5qb2luKGRpcmVjdG9yeSwgJ3ZpZWMuanNvbicpLCAndXRmOCcpKTsg
fSBjYXRjaCB7IHJldHVybiBmcmVzaDsgfQogICAgaWYgKHR5cGVvZiBkYXRhLmtleSA9PT0gJ3N0
cmluZycgJiYgL15bYS1mMC05XXsyNCw2NH0kLy50ZXN0KGRhdGEua2V5KSkgZnJlc2gua2V5ID0g
ZGF0YS5rZXk7CiAgICBpZiAodHlwZW9mIGRhdGEucGFjayA9PT0gJ3N0cmluZycgJiYgUEFDS19J
RC50ZXN0KGRhdGEucGFjaykpIGZyZXNoLnBhY2sgPSBkYXRhLnBhY2s7CiAgICBmcmVzaC5zZXR0
aW5ncyA9IGNsZWFuU2V0dGluZ3MoZGF0YS5zZXR0aW5ncyk7CiAgICBmb3IgKGNvbnN0IGlkIG9m
IEFycmF5LmlzQXJyYXkoZGF0YS5vcmRlcikgPyBkYXRhLm9yZGVyIDogW10pIHsKICAgICAgaWYg
KHR5cGVvZiBpZCAhPT0gJ3N0cmluZycgfHwgIUZJR0hURVIudGVzdChpZCkgfHwgZnJlc2guZmln
aHRlcnNbaWRdKSBjb250aW51ZTsKICAgICAgZnJlc2gub3JkZXIucHVzaChpZCk7CiAgICAgIGZy
ZXNoLmZpZ2h0ZXJzW2lkXSA9IGNsZWFuRmlnaHRlcigoZGF0YS5maWdodGVycyAmJiBkYXRhLmZp
Z2h0ZXJzW2lkXSkgfHwge30pOwogICAgfQogICAgcmV0dXJuIGZyZXNoOwogIH0KCiAgZnVuY3Rp
b24gc2F2ZSgpIHsKICAgIGlmICghZGlyZWN0b3J5KSByZXR1cm47CiAgICBmcy5ta2RpclN5bmMo
ZGlyZWN0b3J5LCB7IHJlY3Vyc2l2ZTogdHJ1ZSB9KTsKICAgIGNvbnN0IGZpbGUgPSBwYXRoLmpv
aW4oZGlyZWN0b3J5LCAndmllYy5qc29uJyk7CiAgICBmcy53cml0ZUZpbGVTeW5jKGAke2ZpbGV9
LnRtcGAsIEpTT04uc3RyaW5naWZ5KGpvYiwgbnVsbCwgMSkpOwogICAgZnMucmVuYW1lU3luYyhg
JHtmaWxlfS50bXBgLCBmaWxlKTsKICB9CgogIGNvbnN0IGZvbGRlciA9IChpZCkgPT4gcGF0aC5q
b2luKGRpcmVjdG9yeSwgJ252JywgaWQpOwogIGNvbnN0IG5vdyA9ICgpID0+IG5ldyBEYXRlKCku
dG9JU09TdHJpbmcoKTsKCiAgZnVuY3Rpb24gY291bnRlZChhZGRyZXNzKSB7CiAgICBjb25zdCB0
aW1lID0gRGF0ZS5ub3coKTsKICAgIGxldCBlbnRyeSA9IGZhaWx1cmVzLmdldChhZGRyZXNzKTsK
ICAgIGlmICghZW50cnkgfHwgZW50cnkudW50aWwgPD0gdGltZSkgewogICAgICBlbnRyeSA9IHsg
Y291bnQ6IDAsIHVudGlsOiB0aW1lICsgMzYwMDAwMCB9OwogICAgICBmYWlsdXJlcy5zZXQoYWRk
cmVzcywgZW50cnkpOwogICAgfQogICAgcmV0dXJuIGVudHJ5OwogIH0KCiAgLy8gQURNSU5fS0VZ
LCBvciAobWFjaGluZSA9IHRydWUpIHRoZSBqb2IncyBrZXkgYXMgd2VsbC4KICBmdW5jdGlvbiBh
dXRob3JpemUocmVxLCBtYWNoaW5lKSB7CiAgICBjb25zdCB0cmllcyA9IGNvdW50ZWQoY2xpZW50
QWRkcmVzcyhyZXEpKTsKICAgIGlmICh0cmllcy5jb3VudCA+PSAzMCkgdGhyb3cgbmV3IEFuc3dl
cig0MjksICdTYWkgbWEgcXVhIG5oaWV1IGxhbiwgdGh1IGxhaSBzYXUgbW90IGdpby4nKTsKICAg
IGNvbnN0IGFkbWluID0gY29uZmlnLmFkbWluS2V5ICYmIHNhbWVLZXkocmVxLmhlYWRlcnNbJ3gt
YWRtaW4ta2V5J10sIGNvbmZpZy5hZG1pbktleSk7CiAgICBjb25zdCB3b3JrZXIgPSBtYWNoaW5l
ICYmIGpvYi5rZXkgJiYgc2FtZUtleShyZXEuaGVhZGVyc1sneC1ob2Mta2V5J10sIGpvYi5rZXkp
OwogICAgaWYgKGFkbWluIHx8IHdvcmtlcikgcmV0dXJuOwogICAgdHJpZXMuY291bnQgKz0gMTsK
ICAgIGlmICghY29uZmlnLmFkbWluS2V5KSB0aHJvdyBuZXcgQW5zd2VyKDQwMywgJ0NodWEgZGF0
IEFETUlOX0tFWSBjaG8gcmVsYXkgKGNoYXkgbGFpIGluc3RhbGwtdnBzLnNoKS4nKTsKICAgIGlm
IChtYWNoaW5lICYmICFqb2Iua2V5KSB0aHJvdyBuZXcgQW5zd2VyKDQwMywgJ0NodWEgY28gdmll
YzogZGF0IHZpZWMgbyB0cmFuZyAvaG9jIHRydW9jLicpOwogICAgdGhyb3cgbmV3IEFuc3dlcig0
MDEsIG1hY2hpbmUgPyAnU2FpIG1hIG1heSBjb24gKEhPQ19LRVkpOiBsYXkgbGFpIGZpbGUgbWF5
LWNvbi1jYWktZGF0LmJhdCBvIHRyYW5nIC9ob2MuJwogICAgICA6ICdTYWkgbWEgcXVhbiB0cmkg
KEFETUlOX0tFWSkuJyk7CiAgfQoKICBmdW5jdGlvbiByZWFkQm9keShyZXEsIGxpbWl0KSB7CiAg
ICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gewogICAgICBjb25zdCBk
ZWNsYXJlZCA9IE51bWJlcihyZXEuaGVhZGVyc1snY29udGVudC1sZW5ndGgnXSB8fCAwKTsKICAg
ICAgaWYgKGRlY2xhcmVkID4gbGltaXQpIHsKICAgICAgICByZXEucmVzdW1lKCk7CiAgICAgICAg
cmVqZWN0KG5ldyBBbnN3ZXIoNDEzLCBgUXVhIGxvbiAodG9pIGRhICR7TWF0aC5yb3VuZChsaW1p
dCAvIDEwMjQpfSBLQikuYCkpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBjb25zdCBj
aHVua3MgPSBbXTsKICAgICAgbGV0IHNpemUgPSAwOwogICAgICBsZXQgb3ZlciA9IGZhbHNlOwog
ICAgICByZXEub24oJ2RhdGEnLCAoY2h1bmspID0+IHsKICAgICAgICBzaXplICs9IGNodW5rLmxl
bmd0aDsKICAgICAgICBpZiAoc2l6ZSA+IGxpbWl0KSBvdmVyID0gdHJ1ZTsKICAgICAgICBpZiAo
IW92ZXIpIGNodW5rcy5wdXNoKGNodW5rKTsKICAgICAgfSk7CiAgICAgIHJlcS5vbignZW5kJywg
KCkgPT4gKG92ZXIgPyByZWplY3QobmV3IEFuc3dlcig0MTMsIGBRdWEgbG9uICh0b2kgZGEgJHtN
YXRoLnJvdW5kKGxpbWl0IC8gMTAyNCl9IEtCKS5gKSkKICAgICAgICA6IHJlc29sdmUoQnVmZmVy
LmNvbmNhdChjaHVua3MpKSkpOwogICAgICByZXEub24oJ2Vycm9yJywgcmVqZWN0KTsKICAgIH0p
OwogIH0KCiAgLy8gT25lIGxpbmUgZWFjaCwgTEYgb25seTogY21kJ3MgZm9yIC9mIHJlYWRzIHRo
ZW0gYXMgdGhleSBhcmUuCiAgZnVuY3Rpb24gbGluZXMocmVzLCBzdGF0dXMsIGxpc3QpIHsKICAg
IHJlcy53cml0ZUhlYWQoc3RhdHVzLCB7ICdjb250ZW50LXR5cGUnOiAndGV4dC9wbGFpbjsgY2hh
cnNldD11dGYtOCcsICdjYWNoZS1jb250cm9sJzogJ25vLXN0b3JlJyB9KTsKICAgIHJlcy5lbmQo
bGlzdC5tYXAoKGxpbmUpID0+IGAke2xpbmV9XG5gKS5qb2luKCcnKSk7CiAgfQoKICBmdW5jdGlv
biBqc29uKHJlcywgc3RhdHVzLCBib2R5KSB7CiAgICByZXMud3JpdGVIZWFkKHN0YXR1cywgeyAn
Y29udGVudC10eXBlJzogJ2FwcGxpY2F0aW9uL2pzb247IGNoYXJzZXQ9dXRmLTgnLCAnY2FjaGUt
Y29udHJvbCc6ICduby1zdG9yZScgfSk7CiAgICByZXMuZW5kKEpTT04uc3RyaW5naWZ5KGJvZHkp
KTsKICB9CgogIGZ1bmN0aW9uIHNldHRpbmdzTGluZXMoKSB7CiAgICBjb25zdCBsaXN0ID0gT2Jq
ZWN0LmVudHJpZXMoam9iLnNldHRpbmdzKS5tYXAoKFtuYW1lLCB2YWx1ZV0pID0+IGAke25hbWV9
PSR7dmFsdWV9YCk7CiAgICBjb25zdCBwYWNrID0gcGFja0luZm8oKTsKICAgIGlmIChwYWNrKSBs
aXN0LnB1c2goYFBBQ0tfSUQ9JHtwYWNrLmlkfWAsIGBQQUNLX1NIQTI1Nj0ke3BhY2suc2hhMjU2
fWApOwogICAgcmV0dXJuIGxpc3Q7CiAgfQoKICAvLyBUaGUgam9iJ3MgbW9kLCB3aGVuIGl0IGlz
IG9uZSBvZiB0aGUgcmVsYXkncyBwYWNrczogaXRzIGZpbGUgYW5kIFNIQS0yNTYgKHBhY2tzLmpz
IGtlZXBzIDxpZD4uanNvbiBiZXNpZGUgaXQpLgogIGZ1bmN0aW9uIHBhY2tJbmZvKCkgewogICAg
aWYgKCFqb2IucGFjayB8fCAhY29uZmlnLnBhY2tzRGlyKSByZXR1cm4gbnVsbDsKICAgIHRyeSB7
CiAgICAgIGNvbnN0IGluZm8gPSBKU09OLnBhcnNlKGZzLnJlYWRGaWxlU3luYyhwYXRoLmpvaW4o
Y29uZmlnLnBhY2tzRGlyLCBgJHtqb2IucGFja30uanNvbmApLCAndXRmOCcpKTsKICAgICAgY29u
c3QgZmlsZSA9IHBhdGguam9pbihjb25maWcucGFja3NEaXIsIGAke2pvYi5wYWNrfS56aXBgKTsK
ICAgICAgaWYgKCEvXlthLWYwLTldezY0fSQvLnRlc3QoU3RyaW5nKGluZm8uc2hhMjU2IHx8ICcn
KSkgfHwgIWZzLnN0YXRTeW5jKGZpbGUpLmlzRmlsZSgpKSByZXR1cm4gbnVsbDsKICAgICAgcmV0
dXJuIHsgaWQ6IGpvYi5wYWNrLCBzaGEyNTY6IGluZm8uc2hhMjU2LCBmaWxlIH07CiAgICB9IGNh
dGNoIHsKICAgICAgcmV0dXJuIG51bGw7CiAgICB9CiAgfQoKICBmdW5jdGlvbiBmaWdodGVyT2Yo
aWQpIHsKICAgIGlmICghRklHSFRFUi50ZXN0KGlkIHx8ICcnKSB8fCAham9iLmZpZ2h0ZXJzW2lk
XSkgdGhyb3cgbmV3IEFuc3dlcig0MDQsIGBLaG9uZyBjbyBuaGFuIHZhdCAke1N0cmluZyhpZCku
c2xpY2UoMCwgNDApfSB0cm9uZyB2aWVjLmApOwogICAgcmV0dXJuIGpvYi5maWdodGVyc1tpZF07
CiAgfQoKICAvLyBBIG1hY2hpbmUncyByZXF1ZXN0IGFib3V0IGEgZmlnaHRlciBpdCBob2xkcy4K
ICBmdW5jdGlvbiBoZWxkKGlkLCBzbG90KSB7CiAgICBjb25zdCBmaWdodGVyID0gZmlnaHRlck9m
KGlkKTsKICAgIGlmIChmaWdodGVyLnN0YXRlICE9PSAnZGFuZycgfHwgZmlnaHRlci5tYXkgIT09
IHNsb3QpIHsKICAgICAgdGhyb3cgbmV3IEFuc3dlcig0MDksIGBOaGFuIHZhdCAke2lkfSBraG9u
ZyBjb24gZ2lhbyBjaG8gJHtzbG90fSAoZGEgdHJhIGxhaSBoYW5nIGRvaSBvIHRyYW5nIC9ob2M/
KS5gKTsKICAgIH0KICAgIHJldHVybiBmaWdodGVyOwogIH0KCiAgZnVuY3Rpb24gc2xvdE9mKHBh
cmFtcykgewogICAgY29uc3Qgc2xvdCA9IHBhcmFtcy5nZXQoJ21heScpIHx8ICcnOwogICAgaWYg
KCFTTE9ULnRlc3Qoc2xvdCkpIHRocm93IG5ldyBBbnN3ZXIoNDAwLCAnVGhpZXUgdGVuIG1heSAo
bWF5PS4uLikuJyk7CiAgICByZXR1cm4gc2xvdDsKICB9CgogIGFzeW5jIGZ1bmN0aW9uIHNpemVP
ZihkaXIpIHsKICAgIGxldCB0b3RhbCA9IDA7CiAgICBsZXQgbmFtZXMgPSBbXTsKICAgIHRyeSB7
IG5hbWVzID0gYXdhaXQgZnNwLnJlYWRkaXIoZGlyKTsgfSBjYXRjaCB7IHJldHVybiAwOyB9CiAg
ICBmb3IgKGNvbnN0IG5hbWUgb2YgbmFtZXMpIHsKICAgICAgdHJ5IHsgdG90YWwgKz0gKGF3YWl0
IGZzcC5zdGF0KHBhdGguam9pbihkaXIsIG5hbWUpKSkuc2l6ZTsgfSBjYXRjaCB7IC8qIGdvbmUg
Ki8gfQogICAgfQogICAgcmV0dXJuIHRvdGFsOwogIH0KCiAgYXN5bmMgZnVuY3Rpb24gcm91dGUo
cmVxLCByZXMsIHBhcnRzLCBwYXJhbXMpIHsKICAgIGNvbnN0IFt3aGF0LCBpZCwgZmlsZV0gPSBw
YXJ0czsKICAgIGNvbnN0IG1ldGhvZCA9IHJlcS5tZXRob2Q7CiAgICAvLyAtLS0gdGhlIHBhZ2Un
cyAoQURNSU5fS0VZKSAtLS0KICAgIGlmICh3aGF0ID09PSAndHJhbmctdGhhaScgJiYgcGFydHMu
bGVuZ3RoID09PSAxICYmIG1ldGhvZCA9PT0gJ0dFVCcpIHsKICAgICAgYXV0aG9yaXplKHJlcSwg
ZmFsc2UpOwogICAgICBjb25zdCBmaWdodGVycyA9IGpvYi5vcmRlci5tYXAoKG9uZSkgPT4gKHsg
aWQ6IG9uZSwgLi4uam9iLmZpZ2h0ZXJzW29uZV0gfSkpOwogICAgICBsZXQgYnl0ZXMgPSAwOwog
ICAgICBpZiAoZGlyZWN0b3J5KSBmb3IgKGNvbnN0IG9uZSBvZiBqb2Iub3JkZXIpIGJ5dGVzICs9
IGF3YWl0IHNpemVPZihmb2xkZXIob25lKSk7CiAgICAgIGpzb24ocmVzLCAyMDAsIHsga2V5OiBq
b2Iua2V5LCBwYWNrOiBqb2IucGFjaywgc2V0dGluZ3M6IGpvYi5zZXR0aW5ncywgZmlnaHRlcnMs
IHN0b3JlZDogQm9vbGVhbihkaXJlY3RvcnkpLCBieXRlcyB9KTsKICAgICAgcmV0dXJuOwogICAg
fQogICAgaWYgKHdoYXQgPT09ICdjYWktZGF0JyAmJiBwYXJ0cy5sZW5ndGggPT09IDEgJiYgbWV0
aG9kID09PSAnUFVUJykgewogICAgICBhdXRob3JpemUocmVxLCBmYWxzZSk7CiAgICAgIGNvbnN0
IGJvZHkgPSBKU09OLnBhcnNlKChhd2FpdCByZWFkQm9keShyZXEsIFRFWFRfTElNSVQpKS50b1N0
cmluZygndXRmOCcpIHx8ICd7fScpOwogICAgICBpZiAoYm9keS5wYWNrICE9PSB1bmRlZmluZWQp
IHsKICAgICAgICBpZiAoYm9keS5wYWNrICE9PSAnJyAmJiAhUEFDS19JRC50ZXN0KFN0cmluZyhi
b2R5LnBhY2spKSkgdGhyb3cgbmV3IEFuc3dlcig0MDAsICdNYSBiYW4gbW9kIGtob25nIGhvcCBs
ZS4nKTsKICAgICAgICBqb2IucGFjayA9IFN0cmluZyhib2R5LnBhY2spOwogICAgICB9CiAgICAg
IGlmIChib2R5LnNldHRpbmdzKSBqb2Iuc2V0dGluZ3MgPSBjbGVhblNldHRpbmdzKHsgLi4uam9i
LnNldHRpbmdzLCAuLi5ib2R5LnNldHRpbmdzIH0pOwogICAgICBpZiAoIWpvYi5rZXkpIGpvYi5r
ZXkgPSBjcnlwdG8ucmFuZG9tQnl0ZXMoMTYpLnRvU3RyaW5nKCdoZXgnKTsKICAgICAgc2F2ZSgp
OwogICAgICBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlLCBwYWNrOiBqb2IucGFjaywgc2V0dGlu
Z3M6IGpvYi5zZXR0aW5ncywga2V5OiBqb2Iua2V5IH0pOwogICAgICByZXR1cm47CiAgICB9CiAg
ICBpZiAod2hhdCA9PT0gJ3RoZW0nICYmIHBhcnRzLmxlbmd0aCA9PT0gMSAmJiBtZXRob2QgPT09
ICdQT1NUJykgewogICAgICBhdXRob3JpemUocmVxLCBmYWxzZSk7CiAgICAgIGNvbnN0IGJvZHkg
PSBKU09OLnBhcnNlKChhd2FpdCByZWFkQm9keShyZXEsIFRFWFRfTElNSVQpKS50b1N0cmluZygn
dXRmOCcpIHx8ICd7fScpOwogICAgICBjb25zdCBuYW1lcyA9IFN0cmluZyhib2R5LmZpZ2h0ZXJz
IHx8ICcnKS5zcGxpdCgvW1xzLDtdKy8pLmZpbHRlcihCb29sZWFuKTsKICAgICAgY29uc3QgYmFk
ID0gbmFtZXMuZmlsdGVyKChuYW1lKSA9PiAhRklHSFRFUi50ZXN0KG5hbWUpKTsKICAgICAgaWYg
KGJhZC5sZW5ndGgpIHRocm93IG5ldyBBbnN3ZXIoNDAwLCBgVGVuIGtob25nIGhvcCBsZTogJHti
YWQuc2xpY2UoMCwgNSkuam9pbignICcpfWApOwogICAgICBjb25zdCBhZGRlZCA9IFtdOwogICAg
ICBjb25zdCBza2lwcGVkID0gW107IC8vIGluIHRoZSBqb2IgYmVmb3JlOiBub3QgYWRkZWQgYWdh
aW4gKGEgbmFtZSB0d2ljZSBpbiB0aGUgbGlzdCBpcyBvbmx5IGFkZGVkIG9uY2UpCiAgICAgIGNv
bnN0IGJlZm9yZSA9IG5ldyBTZXQoam9iLm9yZGVyKTsKICAgICAgZm9yIChjb25zdCBuYW1lIG9m
IG5hbWVzKSB7CiAgICAgICAgaWYgKGpvYi5maWdodGVyc1tuYW1lXSkgewogICAgICAgICAgaWYg
KGJlZm9yZS5oYXMobmFtZSkgJiYgIXNraXBwZWQuaW5jbHVkZXMobmFtZSkpIHNraXBwZWQucHVz
aChuYW1lKTsKICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgIH0KICAgICAgICBpZiAoam9iLm9y
ZGVyLmxlbmd0aCA+PSBNQVhfRklHSFRFUlMpIHRocm93IG5ldyBBbnN3ZXIoNDAwLCBgVG9pIGRh
ICR7TUFYX0ZJR0hURVJTfSBuaGFuIHZhdC5gKTsKICAgICAgICBqb2Iub3JkZXIucHVzaChuYW1l
KTsKICAgICAgICBqb2IuZmlnaHRlcnNbbmFtZV0gPSBjbGVhbkZpZ2h0ZXIoe30pOwogICAgICAg
IGFkZGVkLnB1c2gobmFtZSk7CiAgICAgIH0KICAgICAgaWYgKCFqb2Iua2V5KSBqb2Iua2V5ID0g
Y3J5cHRvLnJhbmRvbUJ5dGVzKDE2KS50b1N0cmluZygnaGV4Jyk7CiAgICAgIHNhdmUoKTsKICAg
ICAganNvbihyZXMsIDIwMCwgeyBvazogdHJ1ZSwgYWRkZWQsIHNraXBwZWQgfSk7CiAgICAgIHJl
dHVybjsKICAgIH0KICAgIGlmICh3aGF0ID09PSAndHJhLWxhaScgJiYgcGFydHMubGVuZ3RoID09
PSAyICYmIG1ldGhvZCA9PT0gJ1BPU1QnKSB7CiAgICAgIGF1dGhvcml6ZShyZXEsIGZhbHNlKTsK
ICAgICAgY29uc3QgZmlnaHRlciA9IGZpZ2h0ZXJPZihpZCk7CiAgICAgIE9iamVjdC5hc3NpZ24o
ZmlnaHRlciwgY2xlYW5GaWdodGVyKHsgdGVuOiBmaWdodGVyLnRlbiB9KSk7CiAgICAgIHNhdmUo
KTsKICAgICAgLy8gRnJvbSB0aGUgc3RhcnQgb24gd2hpY2hldmVyIG1hY2hpbmUgdGFrZXMgaXQ6
IHdoYXQgYW4gZWFybGllciBvbmUgc2VudCBnb2VzLgogICAgICBpZiAoZGlyZWN0b3J5KSBhd2Fp
dCBmc3Aucm0oZm9sZGVyKGlkKSwgeyByZWN1cnNpdmU6IHRydWUsIGZvcmNlOiB0cnVlIH0pOwog
ICAgICBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlIH0pOwogICAgICByZXR1cm47CiAgICB9CiAg
ICBpZiAod2hhdCA9PT0gJ252JyAmJiBwYXJ0cy5sZW5ndGggPT09IDIgJiYgbWV0aG9kID09PSAn
REVMRVRFJykgewogICAgICBhdXRob3JpemUocmVxLCBmYWxzZSk7CiAgICAgIGZpZ2h0ZXJPZihp
ZCk7CiAgICAgIGRlbGV0ZSBqb2IuZmlnaHRlcnNbaWRdOwogICAgICBqb2Iub3JkZXIgPSBqb2Iu
b3JkZXIuZmlsdGVyKChvbmUpID0+IG9uZSAhPT0gaWQpOwogICAgICBzYXZlKCk7CiAgICAgIGlm
IChkaXJlY3RvcnkpIGF3YWl0IGZzcC5ybShmb2xkZXIoaWQpLCB7IHJlY3Vyc2l2ZTogdHJ1ZSwg
Zm9yY2U6IHRydWUgfSk7CiAgICAgIGpzb24ocmVzLCAyMDAsIHsgb2s6IHRydWUgfSk7CiAgICAg
IHJldHVybjsKICAgIH0KICAgIGlmICh3aGF0ID09PSAndmllYy1tb2knICYmIHBhcnRzLmxlbmd0
aCA9PT0gMSAmJiBtZXRob2QgPT09ICdQT1NUJykgewogICAgICBhdXRob3JpemUocmVxLCBmYWxz
ZSk7CiAgICAgIGNvbnN0IHJlbW92ZWQgPSBqb2Iub3JkZXIubGVuZ3RoOwogICAgICBqb2Iub3Jk
ZXIgPSBbXTsKICAgICAgam9iLmZpZ2h0ZXJzID0ge307CiAgICAgIHNhdmUoKTsKICAgICAgLy8g
QSBtYWNoaW5lIHN0aWxsIGxlYXJuaW5nIG9uZSBvZiB0aGVtIGlzIHRvbGQgaXQgaXMgbm90IHRo
ZSBqb2IncyBhbnkgbW9yZSB3aGVuIGl0IHNlbmRzIGl0cyByZXN1bHRzLCBhbmQKICAgICAgLy8g
dGFrZXMgdGhlIG5leHQgZmlnaHRlci4KICAgICAgaWYgKGRpcmVjdG9yeSkgYXdhaXQgZnNwLnJt
KHBhdGguam9pbihkaXJlY3RvcnksICdudicpLCB7IHJlY3Vyc2l2ZTogdHJ1ZSwgZm9yY2U6IHRy
dWUgfSk7CiAgICAgIGxvZyhgaG9jOiBhIG5ldyBqb2IgKCR7cmVtb3ZlZH0gZmlnaHRlcnMgdGFr
ZW4gb2ZmKWApOwogICAgICBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlLCByZW1vdmVkIH0pOwog
ICAgICByZXR1cm47CiAgICB9CiAgICBpZiAod2hhdCA9PT0gJ2RvaS1tYScgJiYgcGFydHMubGVu
Z3RoID09PSAxICYmIG1ldGhvZCA9PT0gJ1BPU1QnKSB7CiAgICAgIGF1dGhvcml6ZShyZXEsIGZh
bHNlKTsKICAgICAgam9iLmtleSA9IGNyeXB0by5yYW5kb21CeXRlcygxNikudG9TdHJpbmcoJ2hl
eCcpOwogICAgICBzYXZlKCk7CiAgICAgIGpzb24ocmVzLCAyMDAsIHsgb2s6IHRydWUsIGtleTog
am9iLmtleSB9KTsKICAgICAgcmV0dXJuOwogICAgfQogICAgLy8gLS0tIHRoZSBtYWNoaW5lcycg
KFgtSG9jLUtleSkgLS0tCiAgICBpZiAod2hhdCA9PT0gJ3ZpZWMnICYmIHBhcnRzLmxlbmd0aCA9
PT0gMSAmJiBtZXRob2QgPT09ICdHRVQnKSB7CiAgICAgIGF1dGhvcml6ZShyZXEsIHRydWUpOwog
ICAgICBsaW5lcyhyZXMsIDIwMCwgc2V0dGluZ3NMaW5lcygpKTsKICAgICAgcmV0dXJuOwogICAg
fQogICAgaWYgKHdoYXQgPT09ICdiYW4tbW9kJyAmJiBwYXJ0cy5sZW5ndGggPT09IDEgJiYgKG1l
dGhvZCA9PT0gJ0dFVCcgfHwgbWV0aG9kID09PSAnSEVBRCcpKSB7CiAgICAgIGF1dGhvcml6ZShy
ZXEsIHRydWUpOwogICAgICBjb25zdCBwYWNrID0gcGFja0luZm8oKTsKICAgICAgaWYgKCFwYWNr
KSB0aHJvdyBuZXcgQW5zd2VyKDQwNCwgJ1ZpZWMgbmF5IGtob25nIGR1bmcgYmFuIG1vZCBjdWEg
cmVsYXk6IG1vaSBtYXkgZGF0IGZpbGUgemlwIGJhbiBtb2QgY2FuaCBtYXktY29uLmJhdC4nKTsK
ICAgICAgY29uc3Qgc3RhdCA9IGF3YWl0IGZzcC5zdGF0KHBhY2suZmlsZSk7CiAgICAgIHJlcy53
cml0ZUhlYWQoMjAwLCB7ICdjb250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vemlwJywgJ2NvbnRl
bnQtbGVuZ3RoJzogU3RyaW5nKHN0YXQuc2l6ZSksICdjYWNoZS1jb250cm9sJzogJ25vLXN0b3Jl
JyB9KTsKICAgICAgaWYgKG1ldGhvZCA9PT0gJ0hFQUQnKSB7CiAgICAgICAgcmVzLmVuZCgpOwog
ICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBjb25zdCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFk
U3RyZWFtKHBhY2suZmlsZSk7CiAgICAgIHN0cmVhbS5vbignZXJyb3InLCAoKSA9PiByZXMuZGVz
dHJveSgpKTsKICAgICAgc3RyZWFtLnBpcGUocmVzKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
aWYgKHdoYXQgPT09ICduaGFuJyAmJiBwYXJ0cy5sZW5ndGggPT09IDEgJiYgbWV0aG9kID09PSAn
UE9TVCcpIHsKICAgICAgYXV0aG9yaXplKHJlcSwgdHJ1ZSk7CiAgICAgIGNvbnN0IHNsb3QgPSBz
bG90T2YocGFyYW1zKTsKICAgICAgbGV0IGlkID0gam9iLm9yZGVyLmZpbmQoKG9uZSkgPT4gam9i
LmZpZ2h0ZXJzW29uZV0uc3RhdGUgPT09ICdkYW5nJyAmJiBqb2IuZmlnaHRlcnNbb25lXS5tYXkg
PT09IHNsb3QpOwogICAgICBpZiAoIWlkKSB7CiAgICAgICAgaWQgPSBqb2Iub3JkZXIuZmluZCgo
b25lKSA9PiBqb2IuZmlnaHRlcnNbb25lXS5zdGF0ZSA9PT0gJ2NobycpOwogICAgICAgIGlmICgh
aWQpIHsKICAgICAgICAgIGxpbmVzKHJlcywgMjAwLCBbJ0hFVD0xJ10pOwogICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBjb25zdCBmaWdodGVyID0gam9iLmZpZ2h0ZXJzW2lkXTsK
ICAgICAgICBPYmplY3QuYXNzaWduKGZpZ2h0ZXIsIGNsZWFuRmlnaHRlcih7IHRlbjogZmlnaHRl
ci50ZW4gfSksIHsgc3RhdGU6ICdkYW5nJywgbWF5OiBzbG90LCBzaW5jZTogbm93KCksIHVwZGF0
ZWQ6IG5vdygpIH0pOwogICAgICAgIHNhdmUoKTsKICAgICAgICBsb2coYGhvYzogJHtpZH0gLT4g
JHtzbG90fWApOwogICAgICB9CiAgICAgIGxpbmVzKHJlcywgMjAwLCBbYE5WPSR7aWR9YCwgLi4u
c2V0dGluZ3NMaW5lcygpXSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmICh3aGF0ID09PSAn
YmFvJyAmJiBwYXJ0cy5sZW5ndGggPT09IDIgJiYgbWV0aG9kID09PSAnUE9TVCcpIHsKICAgICAg
YXV0aG9yaXplKHJlcSwgdHJ1ZSk7CiAgICAgIGNvbnN0IGZpZ2h0ZXIgPSBoZWxkKGlkLCBzbG90
T2YocGFyYW1zKSk7CiAgICAgIGNvbnN0IHRleHQgPSAoYXdhaXQgcmVhZEJvZHkocmVxLCBURVhU
X0xJTUlUKSkudG9TdHJpbmcoJ3V0ZjgnKTsKICAgICAgY29uc3Qgcm91bmQgPSBOdW1iZXIocGFy
YW1zLmdldCgndm9uZycpKTsKICAgICAgaWYgKE51bWJlci5pc0ludGVnZXIocm91bmQpICYmIHJv
dW5kID49IDApIGZpZ2h0ZXIudm9uZyA9IHJvdW5kOwogICAgICBjb25zdCBzY29yZSA9IGNoZWNr
U2NvcmUodGV4dCk7CiAgICAgIGlmIChzY29yZSAhPT0gbnVsbCkgZmlnaHRlci5raWVtID0gc2Nv
cmU7CiAgICAgIGZpZ2h0ZXIudXBkYXRlZCA9IG5vdygpOwogICAgICBzYXZlKCk7CiAgICAgIGxp
bmVzKHJlcywgMjAwLCBbJ09LPTEnXSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmICh3aGF0
ID09PSAnbm9wJyAmJiBwYXJ0cy5sZW5ndGggPT09IDMgJiYgbWV0aG9kID09PSAnUFVUJykgewog
ICAgICBhdXRob3JpemUocmVxLCB0cnVlKTsKICAgICAgaGVsZChpZCwgc2xvdE9mKHBhcmFtcykp
OwogICAgICBpZiAoIVJFU1VMVC50ZXN0KGZpbGUgfHwgJycpKSB0aHJvdyBuZXcgQW5zd2VyKDQw
MCwgYEtob25nIG5oYW4gZmlsZSAke1N0cmluZyhmaWxlKS5zbGljZSgwLCA2MCl9LmApOwogICAg
ICBpZiAoIWRpcmVjdG9yeSkgdGhyb3cgbmV3IEFuc3dlcig1MDMsICdSZWxheSBuYXkga2hvbmcg
Z2l1IGZpbGUgKGNodWEgZGF0IFBBQ0tTX0RJUiBoYXkgSE9DX0RJUikuJyk7CiAgICAgIGNvbnN0
IGJvZHkgPSBhd2FpdCByZWFkQm9keShyZXEsIEZJTEVfTElNSVQpOwogICAgICBjb25zdCBkaXIg
PSBmb2xkZXIoaWQpOwogICAgICBhd2FpdCBmc3AubWtkaXIoZGlyLCB7IHJlY3Vyc2l2ZTogdHJ1
ZSB9KTsKICAgICAgbGV0IGV4aXN0aW5nID0gMDsKICAgICAgdHJ5IHsgZXhpc3RpbmcgPSAoYXdh
aXQgZnNwLnN0YXQocGF0aC5qb2luKGRpciwgZmlsZSkpKS5zaXplOyB9IGNhdGNoIHsgLyogbmV3
ICovIH0KICAgICAgaWYgKChhd2FpdCBzaXplT2YoZGlyKSkgLSBleGlzdGluZyArIGJvZHkubGVu
Z3RoID4gRklHSFRFUl9MSU1JVCkgdGhyb3cgbmV3IEFuc3dlcig0MTMsICdRdWEgbmhpZXUgZmls
ZSBjaG8gbW90IG5oYW4gdmF0LicpOwogICAgICBjb25zdCB0ZW1wb3JhcnkgPSBwYXRoLmpvaW4o
ZGlyLCBgLiR7ZmlsZX0udG1wYCk7CiAgICAgIGF3YWl0IGZzcC53cml0ZUZpbGUodGVtcG9yYXJ5
LCBib2R5KTsKICAgICAgYXdhaXQgZnNwLnJlbmFtZSh0ZW1wb3JhcnksIHBhdGguam9pbihkaXIs
IGZpbGUpKTsKICAgICAgbGluZXMocmVzLCAyMDAsIFsnT0s9MSddKTsKICAgICAgcmV0dXJuOwog
ICAgfQogICAgaWYgKHdoYXQgPT09ICd4b25nJyAmJiBwYXJ0cy5sZW5ndGggPT09IDIgJiYgbWV0
aG9kID09PSAnUE9TVCcpIHsKICAgICAgYXV0aG9yaXplKHJlcSwgdHJ1ZSk7CiAgICAgIGNvbnN0
IHNsb3QgPSBzbG90T2YocGFyYW1zKTsKICAgICAgY29uc3QgZmlnaHRlciA9IGhlbGQoaWQsIHNs
b3QpOwogICAgICBjb25zdCBkaXIgPSBmb2xkZXIoaWQpOwogICAgICBsZXQgYWNjb3VudDsKICAg
ICAgdHJ5IHsgYWNjb3VudCA9IGF3YWl0IGZzcC5yZWFkRmlsZShwYXRoLmpvaW4oZGlyLCAndG9t
LXRhdC50eHQnKSwgJ3V0ZjgnKTsgfSBjYXRjaCB7CiAgICAgICAgdGhyb3cgbmV3IEFuc3dlcig0
MDAsICdDaHVhIGd1aSB0b20tdGF0LnR4dC4nKTsKICAgICAgfQogICAgICBjb25zdCBuYW1lID0g
YWNjb3VudC5tYXRjaCgvbmhhbiB2YXQgKC4rPykgXChpZCAoLT9cZCspXCkvKTsKICAgICAgZmln
aHRlci50ZW4gPSBuYW1lID8gbmFtZVsxXS5zbGljZSgwLCA2MCkgOiBmaWdodGVyLnRlbjsKICAg
ICAgZmlnaHRlci5jaG9uID0gMDsKICAgICAgZmlnaHRlci5kaWVtID0gbnVsbDsKICAgICAgLy8g
VGhlIHJvdW5kcyBsZWFybmVkIGFuZCB3aGV0aGVyIGl0IHN0b3BwZWQgZWFybHk6IHRoZSBsYXN0
IEtFVCBUSFVDIGxpbmUgKHBhY2thZ2UgOTc7IG5vbmUgYmVmb3JlKS4KICAgICAgY29uc3QgZW5k
cyA9IFsuLi5hY2NvdW50Lm1hdGNoQWxsKC9eS0VUIFRIVUM6IChcZCspIHZvbmcoIC0gZHVuZyBz
b20pPy9nbSldOwogICAgICBjb25zdCBlbmQgPSBlbmRzLmxlbmd0aCA/IGVuZHNbZW5kcy5sZW5n
dGggLSAxXSA6IG51bGw7CiAgICAgIGZpZ2h0ZXIuY3VvaSA9IGVuZCA/IE51bWJlcihlbmRbMV0p
IDogMDsKICAgICAgZmlnaHRlci5kdW5nID0gQm9vbGVhbihlbmQgJiYgZW5kWzJdKTsKICAgICAg
dHJ5IHsKICAgICAgICBjb25zdCBbcm91bmQsIHRlbnRoc10gPSAoYXdhaXQgZnNwLnJlYWRGaWxl
KHBhdGguam9pbihkaXIsICd4YWMtbmhhbi50eHQnKSwgJ3V0ZjgnKSkudHJpbSgpLnNwbGl0KC9c
cysvKS5tYXAoTnVtYmVyKTsKICAgICAgICBpZiAoTnVtYmVyLmlzSW50ZWdlcihyb3VuZCkgJiYg
TnVtYmVyLmlzRmluaXRlKHRlbnRocykpIHsKICAgICAgICAgIGZpZ2h0ZXIuY2hvbiA9IHJvdW5k
OwogICAgICAgICAgZmlnaHRlci5kaWVtID0gdGVudGhzIC8gMTA7CiAgICAgICAgfQogICAgICB9
IGNhdGNoIHsgLyogbm90IGNvbmZpcm1lZCAqLyB9CiAgICAgIGZpZ2h0ZXIuZmlsZXMgPSAoYXdh
aXQgZnNwLnJlYWRkaXIoZGlyKSkuZmlsdGVyKChvbmUpID0+IFJFU1VMVC50ZXN0KG9uZSkpLnNv
cnQoKTsKICAgICAgT2JqZWN0LmFzc2lnbihmaWdodGVyLCB7IHN0YXRlOiAneG9uZycsIHhvbmc6
IG5vdygpLCB1cGRhdGVkOiBub3coKSwgbG9pOiAnJyB9KTsKICAgICAgc2F2ZSgpOwogICAgICBs
b2coYGhvYzogJHtpZH0gZG9uZSBvbiAke3Nsb3R9YCk7CiAgICAgIGxpbmVzKHJlcywgMjAwLCBb
J09LPTEnXSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmICh3aGF0ID09PSAnbG9pJyAmJiBw
YXJ0cy5sZW5ndGggPT09IDIgJiYgbWV0aG9kID09PSAnUE9TVCcpIHsKICAgICAgYXV0aG9yaXpl
KHJlcSwgdHJ1ZSk7CiAgICAgIGNvbnN0IGZpZ2h0ZXIgPSBoZWxkKGlkLCBzbG90T2YocGFyYW1z
KSk7CiAgICAgIGNvbnN0IHRleHQgPSAoYXdhaXQgcmVhZEJvZHkocmVxLCBURVhUX0xJTUlUKSku
dG9TdHJpbmcoJ3V0ZjgnKTsKICAgICAgT2JqZWN0LmFzc2lnbihmaWdodGVyLCB7IHN0YXRlOiAn
bG9pJywgbG9pOiB0ZXh0LnNsaWNlKC0yMDAwKSwgdXBkYXRlZDogbm93KCkgfSk7CiAgICAgIHNh
dmUoKTsKICAgICAgbG9nKGBob2M6ICR7aWR9IGZhaWxlZCBvbiAke2ZpZ2h0ZXIubWF5fWApOwog
ICAgICBsaW5lcyhyZXMsIDIwMCwgWydPSz0xJ10pOwogICAgICByZXR1cm47CiAgICB9CiAgICBp
ZiAod2hhdCA9PT0gJ3RyYScgJiYgcGFydHMubGVuZ3RoID09PSAyICYmIG1ldGhvZCA9PT0gJ1BP
U1QnKSB7CiAgICAgIGF1dGhvcml6ZShyZXEsIHRydWUpOwogICAgICBjb25zdCBzbG90ID0gc2xv
dE9mKHBhcmFtcyk7CiAgICAgIGNvbnN0IGZpZ2h0ZXIgPSBoZWxkKGlkLCBzbG90KTsKICAgICAg
T2JqZWN0LmFzc2lnbihmaWdodGVyLCBjbGVhbkZpZ2h0ZXIoeyB0ZW46IGZpZ2h0ZXIudGVuIH0p
KTsKICAgICAgc2F2ZSgpOwogICAgICBpZiAoZGlyZWN0b3J5KSBhd2FpdCBmc3Aucm0oZm9sZGVy
KGlkKSwgeyByZWN1cnNpdmU6IHRydWUsIGZvcmNlOiB0cnVlIH0pOwogICAgICBsb2coYGhvYzog
JHtpZH0gZ2l2ZW4gYmFjayBieSAke3Nsb3R9YCk7CiAgICAgIGxpbmVzKHJlcywgMjAwLCBbJ09L
PTEnXSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmICh3aGF0ID09PSAna2V0LXF1YScgJiYg
cGFydHMubGVuZ3RoID09PSAxICYmIG1ldGhvZCA9PT0gJ0dFVCcpIHsKICAgICAgYXV0aG9yaXpl
KHJlcSwgdHJ1ZSk7CiAgICAgIGxpbmVzKHJlcywgMjAwLCBqb2Iub3JkZXIuZmlsdGVyKChvbmUp
ID0+IGpvYi5maWdodGVyc1tvbmVdLnN0YXRlID09PSAneG9uZycgJiYgam9iLmZpZ2h0ZXJzW29u
ZV0uZmlsZXMubGVuZ3RoKQogICAgICAgIC5tYXAoKG9uZSkgPT4gW29uZSwgLi4uam9iLmZpZ2h0
ZXJzW29uZV0uZmlsZXNdLmpvaW4oJyAnKSkpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAo
d2hhdCA9PT0gJ3RlcCcgJiYgcGFydHMubGVuZ3RoID09PSAzICYmIG1ldGhvZCA9PT0gJ0dFVCcp
IHsKICAgICAgYXV0aG9yaXplKHJlcSwgdHJ1ZSk7CiAgICAgIGZpZ2h0ZXJPZihpZCk7CiAgICAg
IGlmICghUkVTVUxULnRlc3QoZmlsZSB8fCAnJykgfHwgIWRpcmVjdG9yeSkgdGhyb3cgbmV3IEFu
c3dlcig0MDQsICdLaG9uZyBjbyBmaWxlIG5heS4nKTsKICAgICAgbGV0IGJvZHk7CiAgICAgIHRy
eSB7IGJvZHkgPSBhd2FpdCBmc3AucmVhZEZpbGUocGF0aC5qb2luKGZvbGRlcihpZCksIGZpbGUp
KTsgfSBjYXRjaCB7IHRocm93IG5ldyBBbnN3ZXIoNDA0LCAnS2hvbmcgY28gZmlsZSBuYXkuJyk7
IH0KICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ2NvbnRlbnQtdHlwZSc6ICd0ZXh0L3BsYWlu
OyBjaGFyc2V0PXV0Zi04JywgJ2NvbnRlbnQtbGVuZ3RoJzogU3RyaW5nKGJvZHkubGVuZ3RoKSwg
J2NhY2hlLWNvbnRyb2wnOiAnbm8tc3RvcmUnIH0pOwogICAgICByZXMuZW5kKGJvZHkpOwogICAg
ICByZXR1cm47CiAgICB9CiAgICB0aHJvdyBuZXcgQW5zd2VyKDQwNCwgJ0tob25nIGNvIHlldSBj
YXUgbmF5LicpOwogIH0KCiAgLy8gUmV0dXJucyB0cnVlIHdoZW4gdGhlIHJlcXVlc3Qgd2FzIHRo
ZSBqb2IncyBhbmQgaGFzIGJlZW4gYW5zd2VyZWQgKG9yIGlzIGJlaW5nIGFuc3dlcmVkKS4KICBm
dW5jdGlvbiBoYW5kbGUocmVxLCByZXMsIHBhdGhuYW1lKSB7CiAgICBpZiAocGF0aG5hbWUgPT09
ICcvaG9jJyB8fCBwYXRobmFtZSA9PT0gJy9ob2MvJykgewogICAgICByZXMud3JpdGVIZWFkKDIw
MCwgeyAnY29udGVudC10eXBlJzogJ3RleHQvaHRtbDsgY2hhcnNldD11dGYtOCcsICdjYWNoZS1j
b250cm9sJzogJ25vLXN0b3JlJywKICAgICAgICAneC1mcmFtZS1vcHRpb25zJzogJ0RFTlknLCAn
cmVmZXJyZXItcG9saWN5JzogJ25vLXJlZmVycmVyJyB9KTsKICAgICAgcmVzLmVuZChQQUdFKTsK
ICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBpZiAoIXBhdGhuYW1lLnN0YXJ0c1dpdGgoJy9o
b2MvYXBpLycpKSByZXR1cm4gZmFsc2U7CiAgICBjb25zdCBwYXJhbXMgPSBuZXcgVVJMKHJlcS51
cmwsICdodHRwOi8vcmVsYXkuaW52YWxpZCcpLnNlYXJjaFBhcmFtczsKICAgIGNvbnN0IHBhcnRz
ID0gcGF0aG5hbWUuc2xpY2UoJy9ob2MvYXBpLycubGVuZ3RoKS5zcGxpdCgnLycpLm1hcCgocGFy
dCkgPT4gewogICAgICB0cnkgeyByZXR1cm4gZGVjb2RlVVJJQ29tcG9uZW50KHBhcnQpOyB9IGNh
dGNoIHsgcmV0dXJuICdcdTAwMDAnOyB9CiAgICB9KTsKICAgIHJvdXRlKHJlcSwgcmVzLCBwYXJ0
cywgcGFyYW1zKS5jYXRjaCgoZXJyb3IpID0+IHsKICAgICAgY29uc3Qgc3RhdHVzID0gZXJyb3Ig
aW5zdGFuY2VvZiBBbnN3ZXIgPyBlcnJvci5zdGF0dXMgOiAoZXJyb3IgaW5zdGFuY2VvZiBTeW50
YXhFcnJvciA/IDQwMCA6IDUwMCk7CiAgICAgIGlmIChzdGF0dXMgPT09IDUwMCkgbG9nKCdob2M6
JywgZXJyb3IgJiYgZXJyb3Iuc3RhY2sgPyBlcnJvci5zdGFjayA6IGVycm9yKTsKICAgICAgaWYg
KHJlcy5oZWFkZXJzU2VudCkgewogICAgICAgIHJlcy5kZXN0cm95KCk7CiAgICAgICAgcmV0dXJu
OwogICAgICB9CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBlcnJvciBpbnN0YW5jZW9mIEFuc3dlciA/
IGVycm9yLm1lc3NhZ2UgOiAoc3RhdHVzID09PSA0MDAgPyAnWWV1IGNhdSBob25nLicgOiAnTG9p
IHRyZW4gcmVsYXkuJyk7CiAgICAgIGlmIChwYXRobmFtZS5zdGFydHNXaXRoKCcvaG9jL2FwaS90
cmFuZy10aGFpJykgfHwgcGF0aG5hbWUuc3RhcnRzV2l0aCgnL2hvYy9hcGkvY2FpLWRhdCcpIHx8
IHBhdGhuYW1lLnN0YXJ0c1dpdGgoJy9ob2MvYXBpL3RoZW0nKQogICAgICAgIHx8IHBhdGhuYW1l
LnN0YXJ0c1dpdGgoJy9ob2MvYXBpL3RyYS1sYWknKSB8fCBwYXRobmFtZS5zdGFydHNXaXRoKCcv
aG9jL2FwaS9udicpIHx8IHBhdGhuYW1lLnN0YXJ0c1dpdGgoJy9ob2MvYXBpL2RvaS1tYScpCiAg
ICAgICAgfHwgcGF0aG5hbWUuc3RhcnRzV2l0aCgnL2hvYy9hcGkvdmllYy1tb2knKSkgewogICAg
ICAgIGpzb24ocmVzLCBzdGF0dXMsIHsgZXJyb3I6IG1lc3NhZ2UgfSk7CiAgICAgIH0gZWxzZSB7
CiAgICAgICAgbGluZXMocmVzLCBzdGF0dXMsIFtgTE9JPSR7bWVzc2FnZX1gXSk7CiAgICAgIH0K
ICAgIH0pOwogICAgcmV0dXJuIHRydWU7CiAgfQoKICByZXR1cm4gewogICAgaGFuZGxlLAogICAg
Y2xlYW51cDogKCkgPT4gewogICAgICBjb25zdCB0aW1lID0gRGF0ZS5ub3coKTsKICAgICAgZm9y
IChjb25zdCBbYWRkcmVzcywgZW50cnldIG9mIGZhaWx1cmVzKSBpZiAoZW50cnkudW50aWwgPD0g
dGltZSkgZmFpbHVyZXMuZGVsZXRlKGFkZHJlc3MpOwogICAgfSwKICAgIHN0YXRlOiAoKSA9PiBq
b2IsCiAgfTsKfQoKLy8gVGhlIHBhZ2UgYXQgL2hvYyAoVmlldG5hbWVzZTogdGhlIHJlbGF5J3Mg
b3duZXIgcmVhZHMgaXQpLiBUaGUgYWRtaW4ga2V5IGlzIHRoZSBvbmUgL2FkbWluIHJlbWVtYmVy
cy4KY29uc3QgUEFHRSA9IGA8IWRvY3R5cGUgaHRtbD4KPGh0bWwgbGFuZz0idmkiPjxoZWFkPjxt
ZXRhIGNoYXJzZXQ9InV0Zi04Ij48bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9
ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+T3BlbkxGMiByZWxheTogaOG7
jWMgdMSDbmcgY8aw4budbmcgbmhp4buBdSBtw6F5PC90aXRsZT4KPHN0eWxlPgogIGJvZHkgeyBt
YXJnaW46IDA7IHBhZGRpbmc6IDEuNXJlbTsgYmFja2dyb3VuZDogIzExMTgyNzsgY29sb3I6ICNm
M2Y0ZjY7IGZvbnQ6IDE2cHgvMS41IHN5c3RlbS11aSwgc2Fucy1zZXJpZjsgfQogIG1haW4geyBt
YXgtd2lkdGg6IDkwMHB4OyBtYXJnaW46IGF1dG87IH0KICBoMSB7IGZvbnQtc2l6ZTogMS41cmVt
OyBtYXJnaW46IDAgMCAuMjVyZW07IH0KICBoMiB7IGZvbnQtc2l6ZTogMS4xNXJlbTsgbWFyZ2lu
OiAwIDAgLjVyZW07IH0KICAuY2FyZCB7IGJhY2tncm91bmQ6ICMxZjI5Mzc7IGJvcmRlcjogMXB4
IHNvbGlkICMzNzQxNTE7IGJvcmRlci1yYWRpdXM6IDEycHg7IHBhZGRpbmc6IDFyZW0gMS4ycmVt
OyBtYXJnaW46IDFyZW0gMDsgfQogIGxhYmVsIHsgZGlzcGxheTogYmxvY2s7IG1hcmdpbjogLjZy
ZW0gMCAuMnJlbTsgZm9udC13ZWlnaHQ6IDYwMDsgfQogIGlucHV0W3R5cGU9dGV4dF0sIGlucHV0
W3R5cGU9cGFzc3dvcmRdLCBpbnB1dFt0eXBlPW51bWJlcl0sIHNlbGVjdCwgdGV4dGFyZWEgeyB3
aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgcGFkZGluZzogLjVyZW0gLjZyZW07
CiAgICBmb250OiBpbmhlcml0OyBib3JkZXItcmFkaXVzOiA4cHg7IGJvcmRlcjogMXB4IHNvbGlk
ICM0YjU1NjM7IGJhY2tncm91bmQ6ICMwYjEyMjA7IGNvbG9yOiBpbmhlcml0OyB9CiAgLmdyaWQg
eyBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHJlcGVhdChhdXRvLWZpdCwg
bWlubWF4KDE1MHB4LCAxZnIpKTsgZ2FwOiAwIC44cmVtOyB9CiAgYnV0dG9uIHsgcGFkZGluZzog
LjU1cmVtIDEuMXJlbTsgZm9udDogaW5oZXJpdDsgYm9yZGVyLXJhZGl1czogOHB4OyBib3JkZXI6
IDA7IGN1cnNvcjogcG9pbnRlcjsgYmFja2dyb3VuZDogI2Y1OWUwYjsgY29sb3I6ICMxZjEzMDA7
IGZvbnQtd2VpZ2h0OiA3MDA7IH0KICBidXR0b24uc2Vjb25kYXJ5IHsgYmFja2dyb3VuZDogIzM3
NDE1MTsgY29sb3I6ICNmM2Y0ZjY7IGZvbnQtd2VpZ2h0OiA1MDA7IH0KICBidXR0b24uc21hbGwg
eyBwYWRkaW5nOiAuMnJlbSAuNnJlbTsgZm9udC1zaXplOiAuODVyZW07IH0KICAubm90ZSB7IGNv
bG9yOiAjOWNhM2FmOyBmb250LXNpemU6IC45cmVtOyB9CiAgLm9rIHsgY29sb3I6ICM2ZWU3Yjc7
IH0gLmJhZCB7IGNvbG9yOiAjZmNhNWE1OyB9IC5ydW4geyBjb2xvcjogI2ZjZDM0ZDsgfQogIHRh
YmxlIHsgd2lkdGg6IDEwMCU7IGJvcmRlci1jb2xsYXBzZTogY29sbGFwc2U7IH0gdGQsIHRoIHsg
dGV4dC1hbGlnbjogbGVmdDsgcGFkZGluZzogLjRyZW0gLjNyZW07IGJvcmRlci1ib3R0b206IDFw
eCBzb2xpZCAjMzc0MTUxOyB2ZXJ0aWNhbC1hbGlnbjogdG9wOyB9CiAgY29kZSB7IGJhY2tncm91
bmQ6ICMwYjEyMjA7IHBhZGRpbmc6IC4wNXJlbSAuM3JlbTsgYm9yZGVyLXJhZGl1czogNHB4OyB3
b3JkLWJyZWFrOiBicmVhay1hbGw7IH0KICAud3JhcCB7IG92ZXJmbG93LXg6IGF1dG87IH0KPC9z
dHlsZT48L2hlYWQ+Cjxib2R5PjxtYWluPgogIDxoMT5I4buNYyB0xINuZyBjxrDhu51uZyB0csOq
biBuaGnhu4F1IG3DoXk8L2gxPgogIDxwIGNsYXNzPSJub3RlIj5SZWxheSBnaeG7ryBkYW5oIHPD
oWNoIG5ow6JuIHbhuq10IGPhuqduIGjhu41jIHbDoCBjaGlhIGNobyBjw6FjIG3DoXkgY29uIChm
aWxlIDxjb2RlPm1heS1jb24uYmF0PC9jb2RlPiBj4bunYSBi4buZIFhPSSk6IG3hu5dpIG3DoXkK
ICAgIGjhu41jIHbDoGkgbmjDom4gduG6rXQgbeG7mXQgbMO6YyBi4bqxbmcgPGNvZGU+aG9jLXRh
bmctY3VvbmcuYmF0PC9jb2RlPiwgeG9uZyB0aMOsIGfhu61pIGvhur90IHF14bqjIGzDqm4gxJHD
onkgcuG7k2kgbOG6pXkgbmjDom4gduG6rXQgdGnhur9wIHRoZW8uIFJlbGF5CiAgICBraMO0bmcg
aOG7jWMgZ8OsLCBjaOG7iSBjaHV54buDbiBjw6FjIGZpbGUgbmjhu48uIFRyw6puIG3DoXkgY2jD
rW5oLCA8Y29kZT5kdWEtYm8tbmFvLXZhby1tb2QuYmF0PC9jb2RlPiB04bqjaSBr4bq/dCBxdeG6
oyB24buBIHLhu5NpIMSRxrBhIGLhu5kgbsOjbyB2w6BvIGLhuqNuIG1vZC48L3A+CiAgPGRpdiBj
bGFzcz0iY2FyZCI+CiAgICA8bGFiZWwgZm9yPSJrZXkiPk3DoyBxdeG6o24gdHLhu4sgKEFETUlO
X0tFWSk8L2xhYmVsPgogICAgPGlucHV0IGlkPSJrZXkiIHR5cGU9InBhc3N3b3JkIiBhdXRvY29t
cGxldGU9ImN1cnJlbnQtcGFzc3dvcmQiIHBsYWNlaG9sZGVyPSJpbiByYSBraGkgY2jhuqF5IGlu
c3RhbGwtdnBzLnNoIj4KICAgIDxwPjxidXR0b24gaWQ9ImxvYWQiIGNsYXNzPSJzZWNvbmRhcnki
PlhlbSB2aeG7h2M8L2J1dHRvbj48L3A+CiAgICA8cCBpZD0ic3RhdHVzIiByb2xlPSJzdGF0dXMi
IGNsYXNzPSJub3RlIj48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0iY2FyZCIgaWQ9InNldHVw
IiBoaWRkZW4+CiAgICA8aDI+Vmnhu4djPC9oMj4KICAgIDxsYWJlbCBmb3I9InBhY2siPkLhuqNu
IG1vZCBjw6FjIG3DoXkgY29uIGjhu41jIHRyw6puPC9sYWJlbD4KICAgIDxzZWxlY3QgaWQ9InBh
Y2siPjxvcHRpb24gdmFsdWU9IiI+TeG7l2kgbcOheSB04buxIGPDsyBmaWxlIHppcCBi4bqjbiBt
b2QgKMSR4bq3dCBj4bqhbmggbWF5LWNvbi5iYXQpPC9vcHRpb24+PC9zZWxlY3Q+CiAgICA8cCBj
bGFzcz0ibm90ZSI+Q2jhu41uIG3hu5l0IGLhuqNuIG1vZCDEkcOjIHThuqNpIGzDqm4g4bufIHRy
YW5nIDxhIGhyZWY9ImFkbWluIiBpZD0iYWRtaW5saW5rIiBzdHlsZT0iY29sb3I6IzkzYzVmZCI+
L2FkbWluPC9hPiB0aMOsIG3DoXkgY29uIHThu7EgdOG6o2kgduG7gQogICAgICAobeG7mXQgbOG6
p24pLiBIw6N5IGNo4buNbiDEkcO6bmcgYuG6o24gbW9kIGTDuW5nIMSR4buDIGNoxqFpLCBjw7Mg
YuG7mSBuaOG7myB2w6AgYuG7mSBz4buRIFhPSSAoPGNvZGU+Jmx0O3TDqm4mZ3Q7LXhvaS56aXA8
L2NvZGU+KS48L3A+CiAgICA8ZGl2IGNsYXNzPSJncmlkIj4KICAgICAgPGRpdj48bGFiZWwgZm9y
PSJWT05HIj5T4buRIHbDsm5nIChWT05HKTwvbGFiZWw+PGlucHV0IGlkPSJWT05HIiB0eXBlPSJu
dW1iZXIiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxkaXY+PGxhYmVsIGZvcj0iVFJBTiI+VHLhuq1u
IG3hu5dpIHRp4bq/biB0csOsbmggKFRSQU4pPC9sYWJlbD48aW5wdXQgaWQ9IlRSQU4iIHR5cGU9
Im51bWJlciIgbWluPSIxIj48L2Rpdj4KICAgICAgPGRpdj48bGFiZWwgZm9yPSJNT0lfTlYiPlRp
4bq/biB0csOsbmggbeG7l2kgbmjDom4gduG6rXQ8L2xhYmVsPjxpbnB1dCBpZD0iTU9JX05WIiB0
eXBlPSJudW1iZXIiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxkaXY+PGxhYmVsIGZvcj0iS0lFTV9U
UkFfTU9JIj5LaeG7g20gdHJhIG3hu5dpICh2w7JuZyk8L2xhYmVsPjxpbnB1dCBpZD0iS0lFTV9U
UkFfTU9JIiB0eXBlPSJudW1iZXIiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxkaXY+PGxhYmVsIGZv
cj0iVFJBTl9LSUVNX1RSQSI+VHLhuq1uIGtp4buDbSB0cmE8L2xhYmVsPjxpbnB1dCBpZD0iVFJB
Tl9LSUVNX1RSQSIgdHlwZT0ibnVtYmVyIiBtaW49IjEiPjwvZGl2PgogICAgICA8ZGl2PjxsYWJl
bCBmb3I9IlRSQU5fWEFDX05IQU4iPlRy4bqtbiB4w6FjIG5o4bqtbjwvbGFiZWw+PGlucHV0IGlk
PSJUUkFOX1hBQ19OSEFOIiB0eXBlPSJudW1iZXIiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxkaXY+
PGxhYmVsIGZvcj0iRFVOR19TT00iPkThu6tuZyBz4bubbSBzYXUgKHbDsm5nKTwvbGFiZWw+PGlu
cHV0IGlkPSJEVU5HX1NPTSIgdHlwZT0ibnVtYmVyIiBtaW49IjAiPjwvZGl2PgogICAgPC9kaXY+
CiAgICA8cCBjbGFzcz0ibm90ZSI+TeG7l2kgbcOheSBjb24gaOG7jWMgY8O5bmcgbMO6YyAoc+G7
kSBsdeG7k25nIENQVSDDtyB0aeG6v24gdHLDrG5oIG3hu5dpIG5ow6JuIHbhuq10KSBuaMOibiB2
4bqtdDogbcOheSAxMDAgbHXhu5NuZyB24bubaSAzMyBsw6AgMyBuaMOibiB24bqtdC48L3A+CiAg
ICA8cCBjbGFzcz0ibm90ZSI+ROG7q25nIHPhu5ttOiBuaMOibiB24bqtdCBuw6BvIHF1YSBuZ+G6
p24g4bqleSB2w7JuZyBtw6AgxJFp4buDbSBraeG7g20gdHJhIGtow7RuZyBjYW8gdGjDqm0gKMSR
w6MgdOG7m2kgZ2nhu5tpIGjhuqFuKSB0aMOsIHRow7RpIGjhu41jLCBtw6F5CiAgICAgIGNvbiBs
4bqleSBuZ2F5IG5ow6JuIHbhuq10IGvhur87IG5ow6JuIHbhuq10IGPDsm4gbMOqbiB0aMOsIGjh
u41jIHThu5tpIFPhu5EgdsOybmcg4oCUIG7Dqm4gxJHhurd0IFPhu5EgdsOybmcgY2FvICh2w60g
ZOG7pSAxNTAwKS4gMCA9IGtow7RuZyBk4burbmcgc+G7m20uCiAgICAgIEPhuqduIGtp4buDbSB0
cmEgKEtp4buDbSB0cmEgbeG7l2kgdHLDqm4gMCk7IMOtdCB0aeG6v24gdHLDrG5oIHRow6wgdMSD
bmcgVHLhuq1uIGtp4buDbSB0cmEgKG3hu5dpIGzhuqduIGtp4buDbSB0cmEgbsOqbiBjw7MgdOG7
qyAzMDAgdHLhuq1uOgogICAgICB0aeG6v24gdHLDrG5oIMOXIHRy4bqtbiBraeG7g20gdHJhKS48
L3A+CiAgICA8cD48YnV0dG9uIGlkPSJzYXZlIj5MxrB1IGPDoGkgxJHhurd0PC9idXR0b24+PC9w
PgogICAgPGxhYmVsIGZvcj0iYWRkIj5UaMOqbSBuaMOibiB24bqtdCAoc+G7kSBpZCBob+G6t2Mg
dMOqbiwgY8OhY2ggbmhhdSBi4bqxbmcgZOG6pXUgY8OhY2gpPC9sYWJlbD4KICAgIDxpbnB1dCBp
ZD0iYWRkIiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0idsOtIGThu6U6IDEgMyA0IDUgNiA3IDkg
MTAiPgogICAgPHA+PGJ1dHRvbiBpZD0iYWRkYnRuIj5UaMOqbSB2w6BvIGjDoG5nIMSR4bujaTwv
YnV0dG9uPjwvcD4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJjYXJkIiBpZD0ibWFjaGluZXMiIGhp
ZGRlbj4KICAgIDxoMj5Nw6F5IGNvbjwvaDI+CiAgICA8cCBjbGFzcz0ibm90ZSI+QuG6pW0gbsO6
dCBkxrDhu5tpIMSR4buDIGzhuqV5IGZpbGUgPGNvZGU+bWF5LWNvbi1jYWktZGF0LmJhdDwvY29k
ZT4gKMSR4buLYSBjaOG7iSByZWxheSB2w6AgbcOjIG3DoXkgY29uKS4gQ2jDqXAgZmlsZSDhuqV5
IHbDoG8gdGjGsCBt4bulYwogICAgICA8Y29kZT5MRjItWE9JLWtpdDwvY29kZT4gY+G7p2EgbeG7
l2kgbcOheSBjb24sIGPhuqFuaCA8Y29kZT5tYXktY29uLmJhdDwvY29kZT4sIHbDoCBj4bqjIG3D
oXkgY2jDrW5oIChj4bqhbmggPGNvZGU+ZHVhLWJvLW5hby12YW8tbW9kLmJhdDwvY29kZT4pLAog
ICAgICBy4buTaSBuaMOheSDEkcO6cCA8Y29kZT5tYXktY29uLmJhdDwvY29kZT4gdHLDqm4gbeG7
l2kgbcOheSBjb24uPC9wPgogICAgPHA+PGJ1dHRvbiBpZD0iZG93bmxvYWQiPlThuqNpIGZpbGUg
bWF5LWNvbi1jYWktZGF0LmJhdDwvYnV0dG9uPiA8YnV0dG9uIGlkPSJuZXdrZXkiIGNsYXNzPSJz
ZWNvbmRhcnkiPsSQ4buVaSBtw6MgbcOheSBjb248L2J1dHRvbj48L3A+CiAgPC9kaXY+CiAgPGRp
diBjbGFzcz0iY2FyZCIgaWQ9InF1ZXVlIiBoaWRkZW4+CiAgICA8aDI+Q8OhYyBuaMOibiB24bqt
dDwvaDI+CiAgICA8cCBpZD0ic3VtbWFyeSIgY2xhc3M9Im5vdGUiPjwvcD4KICAgIDxwPjxidXR0
b24gaWQ9InJldHJ5YWxsIiBjbGFzcz0ic2Vjb25kYXJ5IiBoaWRkZW4+R2lhbyBs4bqhaSBjw6Fj
IG5ow6JuIHbhuq10IGzhu5dpPC9idXR0b24+PC9wPgogICAgPGRpdiBjbGFzcz0id3JhcCI+PHRh
YmxlPjx0aGVhZD48dHI+PHRoPk5ow6JuIHbhuq10PC90aD48dGg+VHLhuqFuZyB0aMOhaTwvdGg+
PHRoPjwvdGg+PC90cj48L3RoZWFkPjx0Ym9keSBpZD0ibGlzdCI+PC90Ym9keT48L3RhYmxlPjwv
ZGl2PgogICAgPGRpdiBpZD0ibmV3am9iIiBoaWRkZW4+CiAgICAgIDxwIGNsYXNzPSJub3RlIj5Y
b25nIG3hu5l0IGLhuqNuIG1vZDogY2jhuqF5IDxjb2RlPmR1YS1iby1uYW8tdmFvLW1vZC5iYXQ8
L2NvZGU+IHRyw6puIG3DoXkgY2jDrW5oICh04bqjaSBr4bq/dCBxdeG6oyB24buBLCDEkcawYSBi
4buZIG7Do28gdsOgbyBi4bqjbgogICAgICAgIG1vZCksIHLhu5NpIGLhuqVtIG7DunQgZMaw4bub
aSB0csaw4bubYyBraGkgdGjDqm0gbmjDom4gduG6rXQgY+G7p2EgYuG6o24gbW9kIGtow6FjLiBL
4bq/dCBxdeG6oyDEkcaw4bujYyBnaGkgdGhlbyBz4buRIGlkIChoYXkgdMOqbikgbmjDom4gduG6
rXQsIG3DoCBoYWkKICAgICAgICBi4bqjbiBtb2QgdGjGsOG7nW5nIGTDuW5nIGNodW5nIHPhu5Eg
aWQuIE3DoyBtw6F5IGNvbiwgYuG6o24gbW9kIHbDoCBjw6BpIMSR4bq3dCBnaeG7ryBuZ3V5w6pu
LjwvcD4KICAgICAgPHA+PGJ1dHRvbiBpZD0ibmV3am9iYnRuIiBjbGFzcz0ic2Vjb25kYXJ5Ij5C
4bqvdCDEkeG6p3Ugdmnhu4djIG3hu5tpIChi4buPIGjhur90IG5ow6JuIHbhuq10IHbDoCBr4bq/
dCBxdeG6oyB0csOqbiByZWxheSk8L2J1dHRvbj48L3A+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9t
YWluPgo8c2NyaXB0PgogIGNvbnN0ICQgPSAoaWQpID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KGlkKTsKICBjb25zdCBiYXNlID0gbG9jYXRpb24ucGF0aG5hbWUucmVwbGFjZSgvXFwvKyQvLCAn
Jyk7CiAgY29uc3QgYXBpID0gYmFzZSArICcvYXBpLyc7CiAgY29uc3Qgcm9vdCA9IGJhc2UucmVw
bGFjZSgvXFwvaG9jJC8sICcnKTsKICAkKCdhZG1pbmxpbmsnKS5ocmVmID0gcm9vdCArICcvYWRt
aW4nOwogIGNvbnN0IE5BTUVTID0gWydWT05HJywgJ1RSQU4nLCAnTU9JX05WJywgJ0tJRU1fVFJB
X01PSScsICdUUkFOX0tJRU1fVFJBJywgJ1RSQU5fWEFDX05IQU4nLCAnRFVOR19TT00nXTsKICBs
ZXQgc3RhdGUgPSBudWxsOwogIGxldCB0aW1lciA9IDA7CiAgdHJ5IHsgJCgna2V5JykudmFsdWUg
PSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnbGYyLWFkbWluLWtleScpIHx8ICcnOyB9IGNhdGNoIChl
cnJvcikge30KICBjb25zdCByZW1lbWJlciA9ICgpID0+IHsgdHJ5IHsgbG9jYWxTdG9yYWdlLnNl
dEl0ZW0oJ2xmMi1hZG1pbi1rZXknLCAkKCdrZXknKS52YWx1ZSk7IH0gY2F0Y2ggKGVycm9yKSB7
fSB9OwogIGZ1bmN0aW9uIHN0YXR1cyh0ZXh0LCBraW5kKSB7ICQoJ3N0YXR1cycpLnRleHRDb250
ZW50ID0gdGV4dDsgJCgnc3RhdHVzJykuY2xhc3NOYW1lID0ga2luZCB8fCAnbm90ZSc7IH0KICBh
c3luYyBmdW5jdGlvbiBjYWxsKG1ldGhvZCwgd2hhdCwgYm9keSkgewogICAgY29uc3QgcmVzcG9u
c2UgPSBhd2FpdCBmZXRjaChhcGkgKyB3aGF0LCB7IG1ldGhvZCwgaGVhZGVyczogeyAneC1hZG1p
bi1rZXknOiAkKCdrZXknKS52YWx1ZSwgJ2NvbnRlbnQtdHlwZSc6ICdhcHBsaWNhdGlvbi9qc29u
JyB9LAogICAgICBib2R5OiBib2R5ID09PSB1bmRlZmluZWQgPyB1bmRlZmluZWQgOiBKU09OLnN0
cmluZ2lmeShib2R5KSB9KTsKICAgIGNvbnN0IHRleHQgPSBhd2FpdCByZXNwb25zZS50ZXh0KCk7
CiAgICBsZXQgZGF0YTsKICAgIHRyeSB7IGRhdGEgPSBKU09OLnBhcnNlKHRleHQpOyB9IGNhdGNo
IChlcnJvcikgeyBkYXRhID0geyBlcnJvcjogdGV4dCB9OyB9CiAgICBpZiAoIXJlc3BvbnNlLm9r
KSB0aHJvdyBuZXcgRXJyb3IoZGF0YS5lcnJvciB8fCAoJ0hUVFAgJyArIHJlc3BvbnNlLnN0YXR1
cykpOwogICAgcmV0dXJuIGRhdGE7CiAgfQogIGNvbnN0IHRpbWUgPSAoaXNvKSA9PiB7IGlmICgh
aXNvKSByZXR1cm4gJyc7IGNvbnN0IGQgPSBuZXcgRGF0ZShpc28pOyByZXR1cm4gZC50b0xvY2Fs
ZVN0cmluZygndmktVk4nLCB7IGhvdXI6ICcyLWRpZ2l0JywgbWludXRlOiAnMi1kaWdpdCcsIGRh
eTogJzItZGlnaXQnLCBtb250aDogJzItZGlnaXQnIH0pOyB9OwogIGNvbnN0IHBvaW50cyA9ICh2
YWx1ZSkgPT4gKHZhbHVlID09PSBudWxsIHx8IHZhbHVlID09PSB1bmRlZmluZWQpID8gJycgOiAo
KHZhbHVlID4gMCA/ICcrJyA6ICcnKSArIHZhbHVlLnRvRml4ZWQoMSkucmVwbGFjZSgnLicsICcs
JykpOwogIGNvbnN0IG1lZ2FieXRlcyA9IChieXRlcykgPT4gKGJ5dGVzIC8gMWU2KS50b0ZpeGVk
KGJ5dGVzIDwgMWU3ID8gMSA6IDApLnJlcGxhY2UoJy4nLCAnLCcpICsgJyBNQic7CiAgZnVuY3Rp
b24gZGVzY3JpYmUoZikgewogICAgaWYgKGYuc3RhdGUgPT09ICdjaG8nKSByZXR1cm4gWydDaOG7
nSBtw6F5JywgJ25vdGUnXTsKICAgIGlmIChmLnN0YXRlID09PSAnZGFuZycpIHsKICAgICAgbGV0
IHRleHQgPSAnxJBhbmcgaOG7jWMgdHLDqm4gJyArIGYubWF5ICsgJyAodOG7qyAnICsgdGltZShm
LnNpbmNlKSArICcpJzsKICAgICAgaWYgKGYudm9uZykgdGV4dCArPSAnLCB2w7JuZyAnICsgZi52
b25nOwogICAgICBpZiAoZi5raWVtICE9PSBudWxsKSB0ZXh0ICs9ICcsIGtp4buDbSB0cmEgJyAr
IHBvaW50cyhmLmtpZW0pICsgJyDEkWnhu4NtLzEwMCB0cuG6rW4nOwogICAgICBpZiAoZi51cGRh
dGVkKSB0ZXh0ICs9ICcg4oCUIGLDoW8gbMO6YyAnICsgdGltZShmLnVwZGF0ZWQpOwogICAgICBy
ZXR1cm4gW3RleHQsICdydW4nXTsKICAgIH0KICAgIGlmIChmLnN0YXRlID09PSAneG9uZycpIHsK
ICAgICAgY29uc3QgdGV4dCA9ICdYb25nIHRyw6puICcgKyBmLm1heSArICcgbMO6YyAnICsgdGlt
ZShmLnhvbmcpICsgJzogJyArIChmLmNob24gPyAoJ2Lhu5kgbsOjbyB2w7JuZyAnICsgZi5jaG9u
ICsgJywgdHLDqm4gdHLhuq1uIG3hu5tpICcgKyBwb2ludHMoZi5kaWVtKSArICcgxJFp4buDbS8x
MDAgdHLhuq1uJwogICAgICAgICsgKGYuZGllbSA+IDAgPyAnIOKAlCBz4bq9IHbDoG8gYuG6o24g
bW9kJyA6ICcg4oCUIGtow7RuZyBoxqFuIFhPSSwga2jDtG5nIHbDoG8gYuG6o24gbW9kJykpIDog
J2NoxrBhIHjDoWMgbmjhuq1uJykKICAgICAgICArIChmLmR1bmcgPyAnIChk4burbmcgc+G7m20g
4bufIHbDsm5nICcgKyBmLmN1b2kgKyAnOiBraMO0bmcgY8OybiB0aeG6v24gYuG7mSknIDogKGYu
Y3VvaSA/ICcgKGjhu41jICcgKyBmLmN1b2kgKyAnIHbDsm5nKScgOiAnJykpOwogICAgICByZXR1
cm4gW3RleHQsIGYuZGllbSA+IDAgPyAnb2snIDogJ25vdGUnXTsKICAgIH0KICAgIHJldHVybiBb
J0zhu5dpIHRyw6puICcgKyBmLm1heSArICc6ICcgKyBmLmxvaS5zcGxpdCgvXFxyP1xcbi8pLmZp
bHRlcihCb29sZWFuKS5zbGljZSgtMykuam9pbignIC8gJyksICdiYWQnXTsKICB9CiAgZnVuY3Rp
b24gcmVuZGVyKCkgewogICAgZm9yIChjb25zdCBpZCBvZiBbJ3NldHVwJywgJ21hY2hpbmVzJywg
J3F1ZXVlJ10pICQoaWQpLmhpZGRlbiA9IGZhbHNlOwogICAgZm9yIChjb25zdCBuYW1lIG9mIE5B
TUVTKSBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCAhPT0gJChuYW1lKSkgJChuYW1lKS52YWx1
ZSA9IHN0YXRlLnNldHRpbmdzW25hbWVdOwogICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQg
IT09ICQoJ3BhY2snKSkgJCgncGFjaycpLnZhbHVlID0gc3RhdGUucGFjazsKICAgIGNvbnN0IGNv
dW50cyA9IHsgY2hvOiAwLCBkYW5nOiAwLCB4b25nOiAwLCBsb2k6IDAgfTsKICAgIGNvbnN0IHJv
d3MgPSBbXTsKICAgIGZvciAoY29uc3QgZiBvZiBzdGF0ZS5maWdodGVycykgewogICAgICBjb3Vu
dHNbZi5zdGF0ZV0gKz0gMTsKICAgICAgY29uc3QgW3RleHQsIGtpbmRdID0gZGVzY3JpYmUoZik7
CiAgICAgIGNvbnN0IGFjdGlvbnMgPSBbXTsKICAgICAgaWYgKGYuc3RhdGUgIT09ICdjaG8nKSBh
Y3Rpb25zLnB1c2goJzxidXR0b24gY2xhc3M9InNtYWxsIHNlY29uZGFyeSIgZGF0YS1hY3Q9InRy
YS1sYWkiIGRhdGEtaWQ9IicgKyBmLmlkICsgJyI+R2lhbyBs4bqhaTwvYnV0dG9uPicpOwogICAg
ICBhY3Rpb25zLnB1c2goJzxidXR0b24gY2xhc3M9InNtYWxsIHNlY29uZGFyeSIgZGF0YS1hY3Q9
InhvYSIgZGF0YS1pZD0iJyArIGYuaWQgKyAnIj5C4buPPC9idXR0b24+Jyk7CiAgICAgIHJvd3Mu
cHVzaCgnPHRyPjx0ZD4nICsgZi5pZCArIChmLnRlbiA/ICcg4oCUICcgKyBmLnRlbi5yZXBsYWNl
KC9bPCZdL2csICcnKSA6ICcnKSArICc8L3RkPjx0ZCBjbGFzcz0iJyArIGtpbmQgKyAnIj4nCiAg
ICAgICAgKyB0ZXh0LnJlcGxhY2UoL1s8Jl0vZywgJycpICsgJzwvdGQ+PHRkPicgKyBhY3Rpb25z
LmpvaW4oJyAnKSArICc8L3RkPjwvdHI+Jyk7CiAgICB9CiAgICAkKCdsaXN0JykuaW5uZXJIVE1M
ID0gcm93cy5qb2luKCcnKSB8fCAnPHRyPjx0ZCBjb2xzcGFuPSIzIiBjbGFzcz0ibm90ZSI+Q2jG
sGEgY8OzIG5ow6JuIHbhuq10IG7DoG86IHRow6ptIOG7nyB0csOqbi48L3RkPjwvdHI+JzsKICAg
ICQoJ3JldHJ5YWxsJykuaGlkZGVuID0gY291bnRzLmxvaSA9PT0gMDsKICAgICQoJ25ld2pvYicp
LmhpZGRlbiA9IHN0YXRlLmZpZ2h0ZXJzLmxlbmd0aCA9PT0gMDsKICAgICQoJ3N1bW1hcnknKS50
ZXh0Q29udGVudCA9IHN0YXRlLmZpZ2h0ZXJzLmxlbmd0aCArICcgbmjDom4gduG6rXQ6ICcgKyBj
b3VudHMueG9uZyArICcgeG9uZywgJyArIGNvdW50cy5kYW5nICsgJyDEkWFuZyBo4buNYywgJwog
ICAgICArIGNvdW50cy5jaG8gKyAnIGNo4budLCAnICsgY291bnRzLmxvaSArICcgbOG7l2kuJyAr
IChzdGF0ZS5ieXRlcyA/ICcgS+G6v3QgcXXhuqMgdHLDqm4gcmVsYXk6ICcgKyBtZWdhYnl0ZXMo
c3RhdGUuYnl0ZXMpICsgJy4nIDogJycpOwogIH0KICBhc3luYyBmdW5jdGlvbiBwYWNrcygpIHsK
ICAgIHRyeSB7CiAgICAgIGNvbnN0IGRhdGEgPSBhd2FpdCAoYXdhaXQgZmV0Y2gocm9vdCArICcv
bGYyLXBhY2tzLmpzb24nLCB7IGNhY2hlOiAnbm8tc3RvcmUnIH0pKS5qc29uKCk7CiAgICAgIGZv
ciAoY29uc3QgcGFjayBvZiBkYXRhLnBhY2tzIHx8IFtdKSB7CiAgICAgICAgaWYgKHBhY2sua2lu
ZCA9PT0gJ2ZsYXNoJykgY29udGludWU7CiAgICAgICAgY29uc3Qgb3B0aW9uID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnb3B0aW9uJyk7CiAgICAgICAgb3B0aW9uLnZhbHVlID0gcGFjay5pZDsK
ICAgICAgICBvcHRpb24udGV4dENvbnRlbnQgPSBwYWNrLnRpdGxlICsgJyAoJyArIHBhY2suaWQg
KyAnLCAnICsgKHBhY2suc2l6ZSAvIDFlNikudG9GaXhlZCgwKSArICcgTUIpJzsKICAgICAgICAk
KCdwYWNrJykuYXBwZW5kQ2hpbGQob3B0aW9uKTsKICAgICAgfQogICAgfSBjYXRjaCAoZXJyb3Ip
IHt9CiAgfQogIGFzeW5jIGZ1bmN0aW9uIGxvYWQocXVpZXQpIHsKICAgIGlmICghJCgna2V5Jyku
dmFsdWUpIHJldHVybiBzdGF0dXMoJ05o4bqtcCBtw6MgcXXhuqNuIHRy4buLIHRyxrDhu5tjLics
ICdiYWQnKTsKICAgIHJlbWVtYmVyKCk7CiAgICB0cnkgewogICAgICBzdGF0ZSA9IGF3YWl0IGNh
bGwoJ0dFVCcsICd0cmFuZy10aGFpJyk7CiAgICAgIHJlbmRlcigpOwogICAgICBpZiAoIXF1aWV0
KSBzdGF0dXMoc3RhdGUuc3RvcmVkID8gJ8SQw6MgdOG6o2kgdmnhu4djLicgOiAnUmVsYXkgbsOg
eSBraMO0bmcgY8OzIHRoxrAgbeG7pWMgbMawdSAoUEFDS1NfRElSKTogY2jhuqF5IGzhuqFpIGlu
c3RhbGwtdnBzLnNoLicsIHN0YXRlLnN0b3JlZCA/ICdvaycgOiAnYmFkJyk7CiAgICAgIGNsZWFy
VGltZW91dCh0aW1lcik7CiAgICAgIHRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBsb2FkKHRydWUp
LCAyMDAwMCk7CiAgICB9IGNhdGNoIChlcnJvcikgeyBzdGF0dXMoZXJyb3IubWVzc2FnZSwgJ2Jh
ZCcpOyB9CiAgfQogICQoJ2xvYWQnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IGxv
YWQoZmFsc2UpKTsKICAkKCdzYXZlJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBhc3luYyAo
KSA9PiB7CiAgICBjb25zdCBzZXR0aW5ncyA9IHt9OwogICAgZm9yIChjb25zdCBuYW1lIG9mIE5B
TUVTKSBzZXR0aW5nc1tuYW1lXSA9IE51bWJlcigkKG5hbWUpLnZhbHVlKTsKICAgIHRyeSB7IGF3
YWl0IGNhbGwoJ1BVVCcsICdjYWktZGF0JywgeyBwYWNrOiAkKCdwYWNrJykudmFsdWUsIHNldHRp
bmdzIH0pOyBzdGF0dXMoJ8SQw6MgbMawdS4gTcOheSBjb24gZMO5bmcgY8OgaSDEkeG6t3QgbeG7
m2kgY2hvIGPDoWMgbmjDom4gduG6rXQgbmjhuq1uIHNhdS4nLCAnb2snKTsgbG9hZCh0cnVlKTsg
fQogICAgY2F0Y2ggKGVycm9yKSB7IHN0YXR1cyhlcnJvci5tZXNzYWdlLCAnYmFkJyk7IH0KICB9
KTsKICAkKCdhZGRidG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGFzeW5jICgpID0+IHsK
ICAgIHRyeSB7IGNvbnN0IGRhdGEgPSBhd2FpdCBjYWxsKCdQT1NUJywgJ3RoZW0nLCB7IGZpZ2h0
ZXJzOiAkKCdhZGQnKS52YWx1ZSB9KTsgJCgnYWRkJykudmFsdWUgPSAnJzsKICAgICAgY29uc3Qg
aGFkID0gKGRhdGEuc2tpcHBlZCB8fCBbXSkubGVuZ3RoID8gJyDEkMOjIGPDsyB0cm9uZyB2aeG7
h2MgKGtow7RuZyB0aMOqbSBs4bqhaSk6ICcgKyBkYXRhLnNraXBwZWQuam9pbignICcpCiAgICAg
ICAgKyAnIOKAlCBuaMOibiB24bqtdCBj4bunYSBi4bqjbiBtb2Qga2jDoWMgY8O5bmcgc+G7kSBp
ZCB0aMOsIGLhuqVtICJC4bqvdCDEkeG6p3Ugdmnhu4djIG3hu5tpIiB0csaw4bubYy4nIDogJyc7
CiAgICAgIHN0YXR1cygoZGF0YS5hZGRlZC5sZW5ndGggPyAnxJDDoyB0aMOqbTogJyArIGRhdGEu
YWRkZWQuam9pbignICcpICsgJy4nIDogJ0tow7RuZyBjw7MgbmjDom4gduG6rXQgbeG7m2kuJykg
KyBoYWQsIGRhdGEuYWRkZWQubGVuZ3RoID8gJ29rJyA6ICdub3RlJyk7CiAgICAgIGxvYWQodHJ1
ZSk7IH0KICAgIGNhdGNoIChlcnJvcikgeyBzdGF0dXMoZXJyb3IubWVzc2FnZSwgJ2JhZCcpOyB9
CiAgfSk7CiAgJCgnbGlzdCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5bmMgKGV2ZW50
KSA9PiB7CiAgICBjb25zdCBidXR0b24gPSBldmVudC50YXJnZXQuY2xvc2VzdCgnYnV0dG9uJyk7
CiAgICBpZiAoIWJ1dHRvbikgcmV0dXJuOwogICAgY29uc3QgaWQgPSBidXR0b24uZGF0YXNldC5p
ZDsKICAgIGlmIChidXR0b24uZGF0YXNldC5hY3QgPT09ICd4b2EnICYmICFjb25maXJtKCdC4buP
IG5ow6JuIHbhuq10ICcgKyBpZCArICcga2jhu49pIHZp4buHYyAoY+G6oyBr4bq/dCBxdeG6oyBj
4bunYSBuw7MgdHLDqm4gcmVsYXkpPycpKSByZXR1cm47CiAgICBpZiAoYnV0dG9uLmRhdGFzZXQu
YWN0ID09PSAndHJhLWxhaScgJiYgIWNvbmZpcm0oJ8SQxrBhIG5ow6JuIHbhuq10ICcgKyBpZCAr
ICcgduG7gSBow6BuZyDEkeG7o2k/IEvhur90IHF14bqjIGPhu6dhIG7DsyB0csOqbiByZWxheSBi
4buLIHjDs2E7IG3DoXkgbsOgbyBuaOG6rW4gc+G6vSBo4buNYyB0aeG6v3AgJwogICAgICArICd0
4burIHRoxrAgbeG7pWMgaG9jLXRhbmctY3VvbmcgY+G7p2EgbcOheSDhuqV5IG7hur91IMSRw6Mg
Y8OzLCBraMO0bmcgdGjDrCBo4buNYyB04burIMSR4bqndS4nKSkgcmV0dXJuOwogICAgdHJ5IHsK
ICAgICAgaWYgKGJ1dHRvbi5kYXRhc2V0LmFjdCA9PT0gJ3hvYScpIGF3YWl0IGNhbGwoJ0RFTEVU
RScsICdudi8nICsgZW5jb2RlVVJJQ29tcG9uZW50KGlkKSk7CiAgICAgIGVsc2UgYXdhaXQgY2Fs
bCgnUE9TVCcsICd0cmEtbGFpLycgKyBlbmNvZGVVUklDb21wb25lbnQoaWQpKTsKICAgICAgbG9h
ZCh0cnVlKTsKICAgIH0gY2F0Y2ggKGVycm9yKSB7IHN0YXR1cyhlcnJvci5tZXNzYWdlLCAnYmFk
Jyk7IH0KICB9KTsKICAkKCdyZXRyeWFsbCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5
bmMgKCkgPT4gewogICAgY29uc3QgZmFpbGVkID0gc3RhdGUuZmlnaHRlcnMuZmlsdGVyKChmKSA9
PiBmLnN0YXRlID09PSAnbG9pJyk7CiAgICBpZiAoIWZhaWxlZC5sZW5ndGggfHwgIWNvbmZpcm0o
J8SQxrBhICcgKyBmYWlsZWQubGVuZ3RoICsgJyBuaMOibiB24bqtdCBs4buXaSB24buBIGjDoG5n
IMSR4bujaSAoa2hpIMSRw6Mgc+G7rWEgbOG7l2kgdHLDqm4gbcOheSBjb24pPycpKSByZXR1cm47
CiAgICB0cnkgewogICAgICBmb3IgKGNvbnN0IGYgb2YgZmFpbGVkKSBhd2FpdCBjYWxsKCdQT1NU
JywgJ3RyYS1sYWkvJyArIGVuY29kZVVSSUNvbXBvbmVudChmLmlkKSk7CiAgICAgIHN0YXR1cygn
xJDDoyDEkcawYSAnICsgZmFpbGVkLmxlbmd0aCArICcgbmjDom4gduG6rXQgduG7gSBow6BuZyDE
keG7o2kuJywgJ29rJyk7CiAgICB9IGNhdGNoIChlcnJvcikgeyBzdGF0dXMoZXJyb3IubWVzc2Fn
ZSwgJ2JhZCcpOyB9CiAgICBsb2FkKHRydWUpOwogIH0pOwogICQoJ25ld2pvYmJ0bicpLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5bmMgKCkgPT4gewogICAgY29uc3QgbGVhcm5pbmcgPSBz
dGF0ZS5maWdodGVycy5maWx0ZXIoKGYpID0+IGYuc3RhdGUgPT09ICdkYW5nJykubGVuZ3RoOwog
ICAgaWYgKCFjb25maXJtKCdC4bqvdCDEkeG6p3Ugdmnhu4djIG3hu5tpOiBi4buPIGjhur90ICcg
KyBzdGF0ZS5maWdodGVycy5sZW5ndGggKyAnIG5ow6JuIHbhuq10IHbDoCBr4bq/dCBxdeG6oyBj
4bunYSBjaMO6bmcgdHLDqm4gcmVsYXk/IENo4bqheSAnCiAgICAgICsgJ2R1YS1iby1uYW8tdmFv
LW1vZC5iYXQgdHLDqm4gbcOheSBjaMOtbmggdHLGsOG7m2MgxJHhu4MgdOG6o2kga+G6v3QgcXXh
uqMgduG7gS4nCiAgICAgICsgKGxlYXJuaW5nID8gJyAnICsgbGVhcm5pbmcgKyAnIG5ow6JuIHbh
uq10IMSRYW5nIGjhu41jIHRyw6puIG3DoXkgY29uOiBr4bq/dCBxdeG6oyBj4bunYSBjaMO6bmcg
c+G6vSBraMO0bmcgxJHGsOG7o2Mgbmjhuq1uLicgOiAnJykpKSByZXR1cm47CiAgICB0cnkgewog
ICAgICBjb25zdCBkYXRhID0gYXdhaXQgY2FsbCgnUE9TVCcsICd2aWVjLW1vaScpOwogICAgICBz
dGF0dXMoJ8SQw6MgYuG6r3QgxJHhuqd1IHZp4buHYyBt4bubaSAoYuG7jyAnICsgZGF0YS5yZW1v
dmVkICsgJyBuaMOibiB24bqtdCkuIENo4buNbiBi4bqjbiBtb2QgbeG7m2kg4bufIHRyw6puIG7h
ur91IGPhuqduLCBy4buTaSB0aMOqbSBuaMOibiB24bqtdC4nLCAnb2snKTsKICAgIH0gY2F0Y2gg
KGVycm9yKSB7IHN0YXR1cyhlcnJvci5tZXNzYWdlLCAnYmFkJyk7IH0KICAgIGxvYWQodHJ1ZSk7
CiAgfSk7CiAgJCgnbmV3a2V5JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBhc3luYyAoKSA9
PiB7CiAgICBpZiAoIWNvbmZpcm0oJ8SQ4buVaSBtw6MgbcOheSBjb24/IEPDoWMgbcOheSDEkWFu
ZyBjaOG6oXkgc+G6vSBwaOG6o2kgbOG6pXkgbOG6oWkgZmlsZSBtYXktY29uLWNhaS1kYXQuYmF0
LicpKSByZXR1cm47CiAgICB0cnkgeyBhd2FpdCBjYWxsKCdQT1NUJywgJ2RvaS1tYScpOyBsb2Fk
KHRydWUpOyBzdGF0dXMoJ8SQw6MgxJHhu5VpIG3DozogdOG6o2kgbOG6oWkgZmlsZSBjw6BpIMSR
4bq3dCBjaG8gY8OhYyBtw6F5IGNvbi4nLCAnb2snKTsgfQogICAgY2F0Y2ggKGVycm9yKSB7IHN0
YXR1cyhlcnJvci5tZXNzYWdlLCAnYmFkJyk7IH0KICB9KTsKICAkKCdkb3dubG9hZCcpLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5bmMgKCkgPT4gewogICAgaWYgKCFzdGF0ZSB8fCAhc3Rh
dGUua2V5KSB7CiAgICAgIHRyeSB7IGF3YWl0IGNhbGwoJ1BVVCcsICdjYWktZGF0Jywge30pOyBh
d2FpdCBsb2FkKHRydWUpOyB9IGNhdGNoIChlcnJvcikgeyByZXR1cm4gc3RhdHVzKGVycm9yLm1l
c3NhZ2UsICdiYWQnKTsgfQogICAgfQogICAgY29uc3QgdGV4dCA9IFsnQGVjaG8gb2ZmJywgJ3Jl
bSBDYWkgZGF0IG1heSBjb24gaG9jIHRhbmcgY3VvbmcgKHRyYW5nIC9ob2MgY3VhIHJlbGF5KS4g
RGF0IGZpbGUgbmF5IGNhbmggbWF5LWNvbi5iYXQgdmEgZHVhLWJvLW5hby12YW8tbW9kLmJhdC4n
LAogICAgICAnc2V0ICJIT0NfSFVCPScgKyBsb2NhdGlvbi5vcmlnaW4gKyBiYXNlICsgJyInLCAn
c2V0ICJIT0NfS0VZPScgKyBzdGF0ZS5rZXkgKyAnIicsICcnXS5qb2luKCdcXHJcXG4nKTsKICAg
IGNvbnN0IGxpbmsgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdhJyk7CiAgICBsaW5rLmhyZWYg
PSBVUkwuY3JlYXRlT2JqZWN0VVJMKG5ldyBCbG9iKFt0ZXh0XSwgeyB0eXBlOiAnYXBwbGljYXRp
b24vb2N0ZXQtc3RyZWFtJyB9KSk7CiAgICBsaW5rLmRvd25sb2FkID0gJ21heS1jb24tY2FpLWRh
dC5iYXQnOwogICAgZG9jdW1lbnQuYm9keS5hcHBlbmRDaGlsZChsaW5rKTsKICAgIGxpbmsuY2xp
Y2soKTsKICAgIGxpbmsucmVtb3ZlKCk7CiAgfSk7CiAgcGFja3MoKS50aGVuKCgpID0+IHsgaWYg
KCQoJ2tleScpLnZhbHVlKSBsb2FkKHRydWUpOyB9KTsKPC9zY3JpcHQ+CjwvYm9keT48L2h0bWw+
CmA7Cgptb2R1bGUuZXhwb3J0cyA9IHsgY3JlYXRlSG9jLCBjaGVja1Njb3JlLCBTRVRUSU5HUywg
UkVTVUxULCBGSUdIVEVSLCBTTE9UIH07Cg==
LF2_PAYLOAD
}
write_gemini_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IE1JVAovLwovLyBHZW1pbmkgcGxheXMgYWxvbmcg
KHBhY2thZ2UgOTYpOiB0aGUgZ2FtZSBwYWdlJ3MgR2VtaW5pIHBhbmVsIChkaXN0L3BhZ2VzL2dl
bWluaS5qcykgc2VuZHMgd2hhdCBhIG1hdGNoIGxvb2tzIGxpa2UKLy8gZXZlcnkgZmV3IHNlY29u
ZHMsIHRoZSByZWxheSBhc2tzIEdvb2dsZSdzIEdlbWluaSB3aXRoIHRoZSBvd25lcidzIEFQSSBr
ZXksIGFuZCBoYW5kcyB0aGUgYW5zd2VyIGJhY2s7IHRoZSBnYW1lJ3MKLy8gWE9JIHBsYXlzIGV2
ZXJ5IGZyYW1lIGJ5IHRoZSBvcmRlcnMgdGhlIHBhZ2UgbWFrZXMgb2YgaXQgKHNjcmlwdHMvYmFz
ZS9nYW1lL3NtYXJ0X2FpLmx1YSwgc21hcnQucGFnZV9raXQpLiBUaGUga2V5Ci8vIHN0YXlzIG9u
IHRoZSByZWxheSwgaW4gYSBmaWxlIG9ubHkgdGhlIHJlbGF5J3MgdXNlciByZWFkczogdGhlIHBh
Z2UgYW5kIGl0cyBwbGF5ZXJzIG5ldmVyIHNlZSBpdC4gUGxheWVycyB1c2UgdGhlCi8vIGFjY2Vz
cyBjb2RlIHRoZSBwYWdlIC9nZW1pbmkgc2hvd3MgaW5zdGVhZCwgYW5kIHRoZSByZWxheSBrZWVw
cyB0byB0aGUgbGltaXRzIHNldCB0aGVyZSAoY2FsbHMgYSBtaW51dGUsIGEgZGF5KSwKLy8gc28g
dGhhdCBhIGNvZGUgdGhhdCB3ZW50IHJvdW5kIGNhbm5vdCB1c2UgdXAgdGhlIGtleS4KLy8KLy8g
VGhlIHBhZ2Ugd3JpdGVzIHdoYXQgR2VtaW5pIGlzIGFza2VkIChpdHMgaW5zdHJ1Y3Rpb24sIHRo
ZSBtYXRjaCwgdGhlIGFuc3dlcidzIEpTT04gc2NoZW1hKSwgc28gdGhhdCBpdCBjYW4gZ2V0Ci8v
IGJldHRlciB3aXRoIHRoZSBzaXRlOyB0aGUgcmVsYXkgb25seSBwYXNzZXMgaXQgb24sIHdpdGhp
biB0aGUgc2l6ZXMgYmVsb3csIGFuZCBnaXZlcyBiYWNrIEdlbWluaSdzIHRleHQuCi8vCi8vICAg
R0VUICAgIC9nZW1pbmkgICAgICAgICAgICAgICAgICB0aGUgcGFnZSAoVmlldG5hbWVzZTsgQURN
SU5fS0VZKQovLyAgIEdFVCAgICAvZ2VtaW5pL2FwaS90cmFuZy10aGFpICAgdGhlIHNldHRpbmdz
ICh0aGUga2V5J3MgbGFzdCA0IGNoYXJhY3RlcnMgb25seSkgYW5kIHRvZGF5J3MgY2FsbHMgKFgt
QWRtaW4tS2V5KQovLyAgIFBVVCAgICAvZ2VtaW5pL2FwaS9jYWktZGF0ICAgICAgeyJhcGlLZXki
LCJjbGVhcktleSIsIm1vZGVsIiwidGhpbmtpbmciLCJwZXJNaW51dGUiLCJwZXJEYXkiLCJlbmFi
bGVkIn0gKFgtQWRtaW4tS2V5KQovLyAgIFBPU1QgICAvZ2VtaW5pL2FwaS9kb2ktbWEgICAgICAg
YSBuZXcgYWNjZXNzIGNvZGUgZm9yIHRoZSBwbGF5ZXJzIChYLUFkbWluLUtleSkKLy8gICBHRVQg
ICAgL2dlbWluaS9hcGkvbW9kZWxzICAgICAgIHRoZSBtb2RlbHMgdGhlIGtleSBtYXkgdXNlIChY
LUFkbWluLUtleSkKLy8gICBQT1NUICAgL2dlbWluaS9hcGkvdGh1ICAgICAgICAgIG9uZSBjYWxs
IHRvIEdlbWluaSwgdG8gc2VlIHRoYXQgdGhlIGtleSBhbmQgdGhlIG1vZGVsIHdvcmsgKFgtQWRt
aW4tS2V5KQovLyAgIFBPU1QgICAvZ2VtaW5pL2FwaS9wbGFuICAgICAgICAgdGhlIGdhbWUgcGFn
ZSdzOiB7InN5c3RlbSIsInByb21wdCIsInNjaGVtYSJ9IChYLUdlbWluaS1Db2RlOyBhbnkgb3Jp
Z2luIHRoZSByZWxheQovLyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYWxsb3dz
LCB3aXRoIE9QVElPTlMgZmlyc3QpIC0+IHsidGV4dCIsIm1zIiwibW9kZWwifSwgb3IgeyJlcnJv
ciJ9IHdpdGggYSBzdGF0dXMKLy8gS2VwdCBpbiBHRU1JTklfRElSIChkZWZhdWx0IDxQQUNLU19E
SVI+L2dlbWluaSk6IGdlbWluaS5qc29uIChtb2RlIDA2MDApLgondXNlIHN0cmljdCc7Cgpjb25z
dCBjcnlwdG8gPSByZXF1aXJlKCdub2RlOmNyeXB0bycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ25v
ZGU6ZnMnKTsKY29uc3QgaHR0cCA9IHJlcXVpcmUoJ25vZGU6aHR0cCcpOwpjb25zdCBodHRwcyA9
IHJlcXVpcmUoJ25vZGU6aHR0cHMnKTsKY29uc3QgcGF0aCA9IHJlcXVpcmUoJ25vZGU6cGF0aCcp
OwoKY29uc3QgTU9ERUwgPSAvXlthLXowLTldW2EtejAtOS5fLV17MCw3OX0kLzsKY29uc3QgVEhJ
TktJTkcgPSBbJycsICdtaW5pbWFsJywgJ2xvdycsICdtZWRpdW0nLCAnaGlnaCddOwpjb25zdCBE
RUZBVUxUUyA9IHsgbW9kZWw6ICdnZW1pbmktMy41LWZsYXNoLWxpdGUnLCB0aGlua2luZzogJ21p
bmltYWwnLCBwZXJNaW51dGU6IDE1LCBwZXJEYXk6IDEwMDAsIGVuYWJsZWQ6IHRydWUgfTsKY29u
c3QgU1VHR0VTVEVEID0gWydnZW1pbmktMy41LWZsYXNoLWxpdGUnLCAnZ2VtaW5pLTMuNi1mbGFz
aCcsICdnZW1pbmktMy4xLWZsYXNoLWxpdGUnLCAnZ2VtaW5pLTIuNS1mbGFzaC1saXRlJywgJ2dl
bWluaS0yLjUtZmxhc2gnXTsKY29uc3QgS0VZID0gL15bXHgyMS1ceDdlXXsyMCwzMDB9JC87IC8v
IHByaW50YWJsZSwgbm8gc3BhY2VzOiBpdCBnb2VzIGluIGEgaGVhZGVyCmNvbnN0IENPREUgPSAv
XlthLXowLTldezgsNDB9JC87CmNvbnN0IFJFUVVFU1RfTElNSVQgPSA0MCAqIDEwMjQ7CmNvbnN0
IFNZU1RFTV9MSU1JVCA9IDEyICogMTAyNDsKY29uc3QgUFJPTVBUX0xJTUlUID0gMjQgKiAxMDI0
Owpjb25zdCBTQ0hFTUFfTElNSVQgPSA0ICogMTAyNDsKY29uc3QgT1VUUFVUX1RPS0VOUyA9IDEw
MjQ7CmNvbnN0IFRJTUVPVVRfTVMgPSAyMDAwMDsKY29uc3QgR0FQX01TID0gMTUwMDsgLy8gYmV0
d2VlbiB0d28gb2Ygb25lIGFkZHJlc3MncyBjYWxscwpjb25zdCBBUEkgPSAnaHR0cHM6Ly9nZW5l
cmF0aXZlbGFuZ3VhZ2UuZ29vZ2xlYXBpcy5jb20vdjFiZXRhJzsKCmZ1bmN0aW9uIHNhbWVLZXko
Z2l2ZW4sIGV4cGVjdGVkKSB7CiAgY29uc3QgYSA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYn
KS51cGRhdGUoU3RyaW5nKGdpdmVuIHx8ICcnKSkuZGlnZXN0KCk7CiAgY29uc3QgYiA9IGNyeXB0
by5jcmVhdGVIYXNoKCdzaGEyNTYnKS51cGRhdGUoU3RyaW5nKGV4cGVjdGVkKSkuZGlnZXN0KCk7
CiAgcmV0dXJuIGNyeXB0by50aW1pbmdTYWZlRXF1YWwoYSwgYik7Cn0KCmNsYXNzIEFuc3dlciBl
eHRlbmRzIEVycm9yIHsKICBjb25zdHJ1Y3RvcihzdGF0dXMsIG1lc3NhZ2UsIGV4dHJhID0ge30p
IHsKICAgIHN1cGVyKG1lc3NhZ2UpOwogICAgdGhpcy5zdGF0dXMgPSBzdGF0dXM7CiAgICB0aGlz
LmV4dHJhID0gZXh0cmE7CiAgfQp9CgpmdW5jdGlvbiBuZXdDb2RlKCkgewogIC8vIDEyIGxldHRl
cnMgYW5kIGRpZ2l0cywgbm9uZSB0aGF0IGxvb2sgYWxpa2UgKDAvbywgMS9sL2kpLgogIGNvbnN0
IGFscGhhYmV0ID0gJ2FiY2RlZmdoamttbnBxcnN0dXZ3eHl6MjM0NTY3ODknOwogIGNvbnN0IGJ5
dGVzID0gY3J5cHRvLnJhbmRvbUJ5dGVzKDEyKTsKICByZXR1cm4gQXJyYXkuZnJvbShieXRlcywg
KGJ5dGUpID0+IGFscGhhYmV0W2J5dGUgJSBhbHBoYWJldC5sZW5ndGhdKS5qb2luKCcnKTsKfQoK
ZnVuY3Rpb24gd2hvbGUodmFsdWUsIGxlYXN0LCBtb3N0LCBmYWxsYmFjaykgewogIGNvbnN0IG51
bWJlciA9IE51bWJlcih2YWx1ZSk7CiAgcmV0dXJuIE51bWJlci5pc0ludGVnZXIobnVtYmVyKSAm
JiBudW1iZXIgPj0gbGVhc3QgJiYgbnVtYmVyIDw9IG1vc3QgPyBudW1iZXIgOiBmYWxsYmFjazsK
fQoKZnVuY3Rpb24gdG9kYXkoKSB7CiAgcmV0dXJuIG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5z
bGljZSgwLCAxMCk7Cn0KCi8vIFdoYXQgZmV0Y2ggZG9lcyBoZXJlLCBmb3IgYSBOb2RlLmpzIHdp
dGhvdXQgaXQgKGluc3RhbGwtdnBzLnNoIGZhbGxzIGJhY2sgdG8gTm9kZS5qcyAxNiBvbiBDZW50
T1MgNyB3aGVuIG5vIG5ld2VyCi8vIGJ1aWxkIHJ1bnMgdGhlcmUpOiBvbmUgcmVxdWVzdCwgdGhl
IGFuc3dlcidzIHN0YXR1cyBhbmQgdGV4dC4KZnVuY3Rpb24gbm9kZUZldGNoKHVybCwgeyBtZXRo
b2QgPSAnR0VUJywgaGVhZGVycyA9IHt9LCBib2R5LCBzaWduYWwgfSA9IHt9KSB7CiAgcmV0dXJu
IG5ldyBQcm9taXNlKChyZXNvbHZlLCByZWplY3QpID0+IHsKICAgIGNvbnN0IHRhcmdldCA9IG5l
dyBVUkwodXJsKTsKICAgIGNvbnN0IGNsaWVudCA9IHRhcmdldC5wcm90b2NvbCA9PT0gJ2h0dHA6
JyA/IGh0dHAgOiBodHRwczsKICAgIGNvbnN0IHNlbnQgPSBib2R5ID09PSB1bmRlZmluZWQgPyB1
bmRlZmluZWQgOiBCdWZmZXIuZnJvbShTdHJpbmcoYm9keSksICd1dGY4Jyk7CiAgICBjb25zdCBy
ZXF1ZXN0ID0gY2xpZW50LnJlcXVlc3QodGFyZ2V0LCB7CiAgICAgIG1ldGhvZCwKICAgICAgaGVh
ZGVyczogeyAuLi5oZWFkZXJzLCAuLi4oc2VudCA/IHsgJ2NvbnRlbnQtbGVuZ3RoJzogU3RyaW5n
KHNlbnQubGVuZ3RoKSB9IDoge30pIH0sCiAgICB9LCAocmVzcG9uc2UpID0+IHsKICAgICAgY29u
c3QgY2h1bmtzID0gW107CiAgICAgIGxldCBzaXplID0gMDsKICAgICAgcmVzcG9uc2Uub24oJ2Rh
dGEnLCAoY2h1bmspID0+IHsKICAgICAgICBzaXplICs9IGNodW5rLmxlbmd0aDsKICAgICAgICBp
ZiAoc2l6ZSA+IDggKiAxMDI0ICogMTAyNCkgcmVxdWVzdC5kZXN0cm95KG5ldyBFcnJvcignYW5z
d2VyIHRvbyBsYXJnZScpKTsKICAgICAgICBlbHNlIGNodW5rcy5wdXNoKGNodW5rKTsKICAgICAg
fSk7CiAgICAgIHJlc3BvbnNlLm9uKCdlbmQnLCAoKSA9PiB7CiAgICAgICAgY29uc3QgdGV4dCA9
IEJ1ZmZlci5jb25jYXQoY2h1bmtzKS50b1N0cmluZygndXRmOCcpOwogICAgICAgIGNvbnN0IHN0
YXR1cyA9IHJlc3BvbnNlLnN0YXR1c0NvZGUgfHwgMDsKICAgICAgICByZXNvbHZlKHsgb2s6IHN0
YXR1cyA+PSAyMDAgJiYgc3RhdHVzIDwgMzAwLCBzdGF0dXMsIHRleHQ6IGFzeW5jICgpID0+IHRl
eHQgfSk7CiAgICAgIH0pOwogICAgICByZXNwb25zZS5vbignZXJyb3InLCByZWplY3QpOwogICAg
fSk7CiAgICByZXF1ZXN0Lm9uKCdlcnJvcicsIHJlamVjdCk7CiAgICBpZiAoc2lnbmFsKSB7CiAg
ICAgIGNvbnN0IGFib3J0ID0gKCkgPT4gcmVxdWVzdC5kZXN0cm95KE9iamVjdC5hc3NpZ24obmV3
IEVycm9yKCdhYm9ydGVkJyksIHsgbmFtZTogJ0Fib3J0RXJyb3InIH0pKTsKICAgICAgaWYgKHNp
Z25hbC5hYm9ydGVkKSBhYm9ydCgpOwogICAgICBlbHNlIHNpZ25hbC5hZGRFdmVudExpc3RlbmVy
KCdhYm9ydCcsIGFib3J0LCB7IG9uY2U6IHRydWUgfSk7CiAgICB9CiAgICBpZiAoc2VudCkgcmVx
dWVzdC53cml0ZShzZW50KTsKICAgIHJlcXVlc3QuZW5kKCk7CiAgfSk7Cn0KCmZ1bmN0aW9uIGNy
ZWF0ZUdlbWluaShjb25maWcsIHsKICBsb2cgPSAoKSA9PiB7fSwKICBjbGllbnRBZGRyZXNzID0g
KHJlcSkgPT4gcmVxLnNvY2tldC5yZW1vdGVBZGRyZXNzIHx8ICd1bmtub3duJywKICBhbGxvd09y
aWdpbiA9ICgpID0+ICh7ICdhY2Nlc3MtY29udHJvbC1hbGxvdy1vcmlnaW4nOiAnKicgfSksCiAg
ZmV0Y2hJbXBsID0gdHlwZW9mIGdsb2JhbFRoaXMuZmV0Y2ggPT09ICdmdW5jdGlvbicgPyAoLi4u
YXJncykgPT4gZ2xvYmFsVGhpcy5mZXRjaCguLi5hcmdzKSA6IG5vZGVGZXRjaCwKfSA9IHt9KSB7
CiAgY29uc3QgZGlyZWN0b3J5ID0gY29uZmlnLmdlbWluaURpciB8fCAoY29uZmlnLnBhY2tzRGly
ID8gcGF0aC5qb2luKGNvbmZpZy5wYWNrc0RpciwgJ2dlbWluaScpIDogJycpOwogIGNvbnN0IGZp
bGUgPSBkaXJlY3RvcnkgPyBwYXRoLmpvaW4oZGlyZWN0b3J5LCAnZ2VtaW5pLmpzb24nKSA6ICcn
OwogIGNvbnN0IGJhc2UgPSBTdHJpbmcoY29uZmlnLmdlbWluaUFwaUJhc2UgfHwgQVBJKS5yZXBs
YWNlKC9cLyskLywgJycpOwogIGNvbnN0IGdhcCA9IE51bWJlci5pc0Zpbml0ZShjb25maWcuZ2Vt
aW5pR2FwTXMpID8gY29uZmlnLmdlbWluaUdhcE1zIDogR0FQX01TOyAvLyAodGVzdHM6IDApCiAg
Y29uc3QgZmFpbHVyZXMgPSBuZXcgTWFwKCk7IC8vIGNsaWVudCBhZGRyZXNzIC0+IHsgY291bnQs
IHVudGlsIH06IHdyb25nIGNvZGVzIGFuZCBrZXlzCiAgY29uc3QgbGFzdENhbGwgPSBuZXcgTWFw
KCk7IC8vIGNsaWVudCBhZGRyZXNzIC0+IHRpbWUgb2YgaXRzIGxhc3QgY2FsbCAoYW5kIHdoZXRo
ZXIgb25lIGlzIG9uIGl0cyB3YXkpCiAgY29uc3QgYnVzeSA9IG5ldyBTZXQoKTsKICBsZXQgbWlu
dXRlID0gW107IC8vIHRpbWVzIG9mIHRoZSBjYWxscyBpbiB0aGUgbGFzdCBtaW51dGUKICBjb25z
dCB3b3JraW5nID0gbmV3IE1hcCgpOyAvLyBtb2RlbCAtPiB0aGUgZmlyc3Qgb2YgdGhlIHJlcXVl
c3QncyBmb3JtcyBpdCB0b29rIChzZWUgYXNrKQogIGNvbnN0IHNldHRpbmdzID0gbG9hZCgpOwoK
ICBmdW5jdGlvbiBsb2FkKCkgewogICAgY29uc3QgZnJlc2ggPSB7IGFwaUtleTogJycsIGNvZGU6
ICcnLCAuLi5ERUZBVUxUUywgZGF5OiB0b2RheSgpLCBjYWxsczogMCwgZXJyb3JzOiAwLCBsYXN0
OiBudWxsIH07CiAgICBpZiAoIWZpbGUpIHJldHVybiBmcmVzaDsKICAgIGxldCBkYXRhOwogICAg
dHJ5IHsgZGF0YSA9IEpTT04ucGFyc2UoZnMucmVhZEZpbGVTeW5jKGZpbGUsICd1dGY4JykpOyB9
IGNhdGNoIHsgcmV0dXJuIGZyZXNoOyB9CiAgICBpZiAodHlwZW9mIGRhdGEuYXBpS2V5ID09PSAn
c3RyaW5nJyAmJiBLRVkudGVzdChkYXRhLmFwaUtleSkpIGZyZXNoLmFwaUtleSA9IGRhdGEuYXBp
S2V5OwogICAgaWYgKHR5cGVvZiBkYXRhLmNvZGUgPT09ICdzdHJpbmcnICYmIENPREUudGVzdChk
YXRhLmNvZGUpKSBmcmVzaC5jb2RlID0gZGF0YS5jb2RlOwogICAgaWYgKHR5cGVvZiBkYXRhLm1v
ZGVsID09PSAnc3RyaW5nJyAmJiBNT0RFTC50ZXN0KGRhdGEubW9kZWwpKSBmcmVzaC5tb2RlbCA9
IGRhdGEubW9kZWw7CiAgICBpZiAoVEhJTktJTkcuaW5jbHVkZXMoZGF0YS50aGlua2luZykpIGZy
ZXNoLnRoaW5raW5nID0gZGF0YS50aGlua2luZzsKICAgIGZyZXNoLnBlck1pbnV0ZSA9IHdob2xl
KGRhdGEucGVyTWludXRlLCAwLCAxMDAwLCBERUZBVUxUUy5wZXJNaW51dGUpOwogICAgZnJlc2gu
cGVyRGF5ID0gd2hvbGUoZGF0YS5wZXJEYXksIDAsIDEwMDAwMDAsIERFRkFVTFRTLnBlckRheSk7
CiAgICBmcmVzaC5lbmFibGVkID0gZGF0YS5lbmFibGVkICE9PSBmYWxzZTsKICAgIGlmIChkYXRh
LmRheSA9PT0gZnJlc2guZGF5KSB7CiAgICAgIGZyZXNoLmNhbGxzID0gd2hvbGUoZGF0YS5jYWxs
cywgMCwgMWU5LCAwKTsKICAgICAgZnJlc2guZXJyb3JzID0gd2hvbGUoZGF0YS5lcnJvcnMsIDAs
IDFlOSwgMCk7CiAgICB9CiAgICBpZiAoZGF0YS5sYXN0ICYmIHR5cGVvZiBkYXRhLmxhc3QgPT09
ICdvYmplY3QnKSB7CiAgICAgIGZyZXNoLmxhc3QgPSB7IGF0OiBTdHJpbmcoZGF0YS5sYXN0LmF0
IHx8ICcnKS5zbGljZSgwLCA0MCksIG1zOiB3aG9sZShkYXRhLmxhc3QubXMsIDAsIDFlNywgMCks
CiAgICAgICAgZXJyb3I6IFN0cmluZyhkYXRhLmxhc3QuZXJyb3IgfHwgJycpLnNsaWNlKDAsIDMw
MCkgfTsKICAgIH0KICAgIHJldHVybiBmcmVzaDsKICB9CgogIGZ1bmN0aW9uIHNhdmUoKSB7CiAg
ICBpZiAoIWZpbGUpIHJldHVybjsKICAgIGZzLm1rZGlyU3luYyhkaXJlY3RvcnksIHsgcmVjdXJz
aXZlOiB0cnVlLCBtb2RlOiAwbzcwMCB9KTsKICAgIHRyeSB7IGZzLmNobW9kU3luYyhkaXJlY3Rv
cnksIDBvNzAwKTsgfSBjYXRjaCB7IC8qIG5vdCBvdXJzIHRvIGNoYW5nZSAqLyB9CiAgICBjb25z
dCB0ZW1wb3JhcnkgPSBgJHtmaWxlfS50bXBgOwogICAgZnMud3JpdGVGaWxlU3luYyh0ZW1wb3Jh
cnksIEpTT04uc3RyaW5naWZ5KHNldHRpbmdzLCBudWxsLCAxKSwgeyBtb2RlOiAwbzYwMCB9KTsK
ICAgIGZzLmNobW9kU3luYyh0ZW1wb3JhcnksIDBvNjAwKTsKICAgIGZzLnJlbmFtZVN5bmModGVt
cG9yYXJ5LCBmaWxlKTsKICB9CgogIC8vIENhbGxzIGFyZSBjb3VudGVkIGJ5IHRoZSBkYXkgKHRo
ZSBzZXJ2ZXIncyBVVEMgZGF5OyBHb29nbGUncyBvd24gZGF5IG1heSBlbmQgYXQgYW5vdGhlciBo
b3VyKS4KICBmdW5jdGlvbiByb2xsRGF5KCkgewogICAgY29uc3QgZGF5ID0gdG9kYXkoKTsKICAg
IGlmIChzZXR0aW5ncy5kYXkgIT09IGRheSkgewogICAgICBzZXR0aW5ncy5kYXkgPSBkYXk7CiAg
ICAgIHNldHRpbmdzLmNhbGxzID0gMDsKICAgICAgc2V0dGluZ3MuZXJyb3JzID0gMDsKICAgIH0K
ICB9CgogIGZ1bmN0aW9uIGNvdW50ZWQoYWRkcmVzcykgewogICAgY29uc3QgdGltZSA9IERhdGUu
bm93KCk7CiAgICBsZXQgZW50cnkgPSBmYWlsdXJlcy5nZXQoYWRkcmVzcyk7CiAgICBpZiAoIWVu
dHJ5IHx8IGVudHJ5LnVudGlsIDw9IHRpbWUpIHsKICAgICAgZW50cnkgPSB7IGNvdW50OiAwLCB1
bnRpbDogdGltZSArIDM2MDAwMDAgfTsKICAgICAgZmFpbHVyZXMuc2V0KGFkZHJlc3MsIGVudHJ5
KTsKICAgIH0KICAgIHJldHVybiBlbnRyeTsKICB9CgogIGZ1bmN0aW9uIGF1dGhvcml6ZUFkbWlu
KHJlcSkgewogICAgY29uc3QgdHJpZXMgPSBjb3VudGVkKGNsaWVudEFkZHJlc3MocmVxKSk7CiAg
ICBpZiAodHJpZXMuY291bnQgPj0gMzApIHRocm93IG5ldyBBbnN3ZXIoNDI5LCAnU2FpIG3DoyBx
dcOhIG5oaeG7gXUgbOG6p24sIHRo4butIGzhuqFpIHNhdSBt4buZdCBnaeG7nS4nKTsKICAgIGlm
IChjb25maWcuYWRtaW5LZXkgJiYgc2FtZUtleShyZXEuaGVhZGVyc1sneC1hZG1pbi1rZXknXSwg
Y29uZmlnLmFkbWluS2V5KSkgcmV0dXJuOwogICAgdHJpZXMuY291bnQgKz0gMTsKICAgIGlmICgh
Y29uZmlnLmFkbWluS2V5KSB0aHJvdyBuZXcgQW5zd2VyKDQwMywgJ1JlbGF5IGNoxrBhIGPDsyBB
RE1JTl9LRVkgKGNo4bqheSBs4bqhaSBpbnN0YWxsLXZwcy5zaCkuJyk7CiAgICB0aHJvdyBuZXcg
QW5zd2VyKDQwMSwgJ1NhaSBtw6MgcXXhuqNuIHRy4buLIChBRE1JTl9LRVkpLicpOwogIH0KCiAg
ZnVuY3Rpb24gYXV0aG9yaXplUGxheWVyKHJlcSkgewogICAgY29uc3QgdHJpZXMgPSBjb3VudGVk
KGNsaWVudEFkZHJlc3MocmVxKSk7CiAgICBpZiAodHJpZXMuY291bnQgPj0gMzApIHRocm93IG5l
dyBBbnN3ZXIoNDI5LCAnU2FpIG3DoyBHZW1pbmkgcXXDoSBuaGnhu4F1IGzhuqduLCB0aOG7rSBs
4bqhaSBzYXUgbeG7mXQgZ2nhu50uJyk7CiAgICBpZiAoc2V0dGluZ3MuY29kZSAmJiBzYW1lS2V5
KHJlcS5oZWFkZXJzWyd4LWdlbWluaS1jb2RlJ10sIHNldHRpbmdzLmNvZGUpKSByZXR1cm47CiAg
ICBpZiAoY29uZmlnLmFkbWluS2V5ICYmIHNhbWVLZXkocmVxLmhlYWRlcnNbJ3gtYWRtaW4ta2V5
J10sIGNvbmZpZy5hZG1pbktleSkpIHJldHVybjsKICAgIHRyaWVzLmNvdW50ICs9IDE7CiAgICBp
ZiAoIXNldHRpbmdzLmNvZGUpIHRocm93IG5ldyBBbnN3ZXIoNDAzLCAnUmVsYXkgY2jGsGEgYuG6
rXQgR2VtaW5pOiBjaOG7pyByZWxheSDEkeG6t3Qga2jDs2Eg4bufIHRyYW5nIC9nZW1pbmkuJyk7
CiAgICB0aHJvdyBuZXcgQW5zd2VyKDQwMSwgJ1NhaSBtw6MgR2VtaW5pOiBs4bqleSBtw6Mg4buf
IHRyYW5nIC9nZW1pbmkgY+G7p2EgcmVsYXkuJyk7CiAgfQoKICBmdW5jdGlvbiByZWFkQm9keShy
ZXEsIGxpbWl0KSB7CiAgICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4g
ewogICAgICBjb25zdCBkZWNsYXJlZCA9IE51bWJlcihyZXEuaGVhZGVyc1snY29udGVudC1sZW5n
dGgnXSB8fCAwKTsKICAgICAgaWYgKGRlY2xhcmVkID4gbGltaXQpIHsKICAgICAgICByZXEucmVz
dW1lKCk7CiAgICAgICAgcmVqZWN0KG5ldyBBbnN3ZXIoNDEzLCBgUXXDoSBs4bubbiAodOG7kWkg
xJFhICR7TWF0aC5yb3VuZChsaW1pdCAvIDEwMjQpfSBLQikuYCkpOwogICAgICAgIHJldHVybjsK
ICAgICAgfQogICAgICBjb25zdCBjaHVua3MgPSBbXTsKICAgICAgbGV0IHNpemUgPSAwOwogICAg
ICBsZXQgb3ZlciA9IGZhbHNlOwogICAgICByZXEub24oJ2RhdGEnLCAoY2h1bmspID0+IHsKICAg
ICAgICBzaXplICs9IGNodW5rLmxlbmd0aDsKICAgICAgICBpZiAoc2l6ZSA+IGxpbWl0KSBvdmVy
ID0gdHJ1ZTsKICAgICAgICBpZiAoIW92ZXIpIGNodW5rcy5wdXNoKGNodW5rKTsKICAgICAgfSk7
CiAgICAgIHJlcS5vbignZW5kJywgKCkgPT4gKG92ZXIgPyByZWplY3QobmV3IEFuc3dlcig0MTMs
IGBRdcOhIGzhu5tuICh04buRaSDEkWEgJHtNYXRoLnJvdW5kKGxpbWl0IC8gMTAyNCl9IEtCKS5g
KSkKICAgICAgICA6IHJlc29sdmUoQnVmZmVyLmNvbmNhdChjaHVua3MpKSkpOwogICAgICByZXEu
b24oJ2Vycm9yJywgcmVqZWN0KTsKICAgIH0pOwogIH0KCiAgYXN5bmMgZnVuY3Rpb24gcmVhZEpz
b24ocmVxLCBsaW1pdCkgewogICAgY29uc3QgdGV4dCA9IChhd2FpdCByZWFkQm9keShyZXEsIGxp
bWl0KSkudG9TdHJpbmcoJ3V0ZjgnKTsKICAgIGlmICghdGV4dCkgcmV0dXJuIHt9OwogICAgY29u
c3QgYm9keSA9IEpTT04ucGFyc2UodGV4dCk7CiAgICBpZiAoIWJvZHkgfHwgdHlwZW9mIGJvZHkg
IT09ICdvYmplY3QnIHx8IEFycmF5LmlzQXJyYXkoYm9keSkpIHRocm93IG5ldyBBbnN3ZXIoNDAw
LCAnWcOqdSBj4bqndSBo4buPbmcuJyk7CiAgICByZXR1cm4gYm9keTsKICB9CgogIGZ1bmN0aW9u
IGpzb24ocmVzLCBzdGF0dXMsIGJvZHksIGhlYWRlcnMgPSB7fSkgewogICAgcmVzLndyaXRlSGVh
ZChzdGF0dXMsIHsgJ2NvbnRlbnQtdHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uOyBjaGFyc2V0PXV0
Zi04JywgJ2NhY2hlLWNvbnRyb2wnOiAnbm8tc3RvcmUnLCAuLi5oZWFkZXJzIH0pOwogICAgcmVz
LmVuZChKU09OLnN0cmluZ2lmeShib2R5KSk7CiAgfQoKICAvLyBOZXZlciB0aGUga2V5IGluIHdo
YXQgaXMgc2hvd24gb3IgbG9nZ2VkLgogIGZ1bmN0aW9uIHNjcnViKHRleHQpIHsKICAgIGxldCBj
bGVhbiA9IFN0cmluZyh0ZXh0IHx8ICcnKTsKICAgIGlmIChzZXR0aW5ncy5hcGlLZXkpIGNsZWFu
ID0gY2xlYW4uc3BsaXQoc2V0dGluZ3MuYXBpS2V5KS5qb2luKCfigKYnKTsKICAgIHJldHVybiBj
bGVhbi5yZXBsYWNlKC9rZXk9W0EtWmEtejAtOV8tXXsxMCx9L2csICdrZXk94oCmJykuc2xpY2Uo
MCwgMzAwKTsKICB9CgogIGZ1bmN0aW9uIGRlc2NyaWJlKCkgewogICAgcm9sbERheSgpOwogICAg
cmV0dXJuIHsKICAgICAgY29uZmlndXJlZDogQm9vbGVhbihzZXR0aW5ncy5hcGlLZXkpLAogICAg
ICBrZXlFbmQ6IHNldHRpbmdzLmFwaUtleSA/IHNldHRpbmdzLmFwaUtleS5zbGljZSgtNCkgOiAn
JywKICAgICAgbW9kZWw6IHNldHRpbmdzLm1vZGVsLAogICAgICB0aGlua2luZzogc2V0dGluZ3Mu
dGhpbmtpbmcsCiAgICAgIHBlck1pbnV0ZTogc2V0dGluZ3MucGVyTWludXRlLAogICAgICBwZXJE
YXk6IHNldHRpbmdzLnBlckRheSwKICAgICAgZW5hYmxlZDogc2V0dGluZ3MuZW5hYmxlZCwKICAg
ICAgY29kZTogc2V0dGluZ3MuY29kZSwKICAgICAgY2FsbHM6IHNldHRpbmdzLmNhbGxzLAogICAg
ICBlcnJvcnM6IHNldHRpbmdzLmVycm9ycywKICAgICAgbGFzdDogc2V0dGluZ3MubGFzdCwKICAg
ICAgc3RvcmVkOiBCb29sZWFuKGZpbGUpLAogICAgICBzdWdnZXN0ZWQ6IFNVR0dFU1RFRCwKICAg
IH07CiAgfQoKICBhc3luYyBmdW5jdGlvbiB3aXRoVGltZW91dCh1cmwsIG9wdGlvbnMpIHsKICAg
IGNvbnN0IGNvbnRyb2xsZXIgPSBuZXcgQWJvcnRDb250cm9sbGVyKCk7CiAgICBjb25zdCB0aW1l
ciA9IHNldFRpbWVvdXQoKCkgPT4gY29udHJvbGxlci5hYm9ydCgpLCBUSU1FT1VUX01TKTsKICAg
IHRyeSB7CiAgICAgIHJldHVybiBhd2FpdCBmZXRjaEltcGwodXJsLCB7IC4uLm9wdGlvbnMsIHNp
Z25hbDogY29udHJvbGxlci5zaWduYWwgfSk7CiAgICB9IGNhdGNoIChlcnJvcikgewogICAgICBp
ZiAoY29udHJvbGxlci5zaWduYWwuYWJvcnRlZCkgdGhyb3cgbmV3IEFuc3dlcig1MDQsIGBHZW1p
bmkga2jDtG5nIHRy4bqjIGzhu51pIHNhdSAke1RJTUVPVVRfTVMgLyAxMDAwfSBnacOieS5gKTsK
ICAgICAgdGhyb3cgbmV3IEFuc3dlcig1MDIsIGBLaMO0bmcgZ+G7jWkgxJHGsOG7o2MgR2VtaW5p
OiAke3NjcnViKGVycm9yICYmIGVycm9yLm1lc3NhZ2UpfWApOwogICAgfSBmaW5hbGx5IHsKICAg
ICAgY2xlYXJUaW1lb3V0KHRpbWVyKTsKICAgIH0KICB9CgogIGZ1bmN0aW9uIHVwc3RyZWFtRXJy
b3Ioc3RhdHVzLCBkYXRhLCBtb2RlbCkgewogICAgY29uc3QgbWVzc2FnZSA9IHNjcnViKChkYXRh
ICYmIGRhdGEuZXJyb3IgJiYgZGF0YS5lcnJvci5tZXNzYWdlKSB8fCAnJyk7CiAgICBpZiAoc3Rh
dHVzID09PSA0MDAgJiYgL2FwaSBrZXkvaS50ZXN0KG1lc3NhZ2UpKSByZXR1cm4gbmV3IEFuc3dl
cig1MDIsICdLaMOzYSBHZW1pbmkgQVBJIGtow7RuZyDEkcO6bmcgKMSR4bq3dCBs4bqhaSDhu58g
dHJhbmcgL2dlbWluaSkuJyk7CiAgICBpZiAoc3RhdHVzID09PSA0MDEgfHwgc3RhdHVzID09PSA0
MDMpIHsKICAgICAgcmV0dXJuIG5ldyBBbnN3ZXIoNTAyLCBgS2jDs2EgR2VtaW5pIEFQSSBraMO0
bmcgZMO5bmcgxJHGsOG7o2MgKEhUVFAgJHtzdGF0dXN9JHttZXNzYWdlID8gYDogJHttZXNzYWdl
fWAgOiAnJ30pLiBLaeG7g20gdHJhIGtow7NhIOG7nyB0cmFuZyAvZ2VtaW5pLmApOwogICAgfQog
ICAgaWYgKHN0YXR1cyA9PT0gNDA0KSByZXR1cm4gbmV3IEFuc3dlcig1MDIsIGBHZW1pbmkga2jD
tG5nIGPDsyBtb2RlbCAke21vZGVsfSAoxJHhu5VpIG1vZGVsIOG7nyB0cmFuZyAvZ2VtaW5pKS5g
KTsKICAgIGlmIChzdGF0dXMgPT09IDQyOSkgewogICAgICByZXR1cm4gbmV3IEFuc3dlcig0Mjks
IGBHZW1pbmkgYsOhbyBo4bq/dCBsxrDhu6N0IGPhu6dhIGtow7NhIChIVFRQIDQyOSR7bWVzc2Fn
ZSA/IGA6ICR7bWVzc2FnZX1gIDogJyd9KS4gxJDhu6NpIG3hu5l0IGzDoXQgaGF5IMSR4buVaSBt
b2RlbC5gLCB7IHJldHJ5TXM6IDMwMDAwIH0pOwogICAgfQogICAgaWYgKHN0YXR1cyA9PT0gNDAw
KSByZXR1cm4gbmV3IEFuc3dlcig1MDIsIGBHZW1pbmkga2jDtG5nIG5o4bqtbiB5w6p1IGPhuqd1
IChIVFRQIDQwMCR7bWVzc2FnZSA/IGA6ICR7bWVzc2FnZX1gIDogJyd9KS5gKTsKICAgIHJldHVy
biBuZXcgQW5zd2VyKDUwMiwgYEdlbWluaSDEkWFuZyBs4buXaSAoSFRUUCAke3N0YXR1c30ke21l
c3NhZ2UgPyBgOiAke21lc3NhZ2V9YCA6ICcnfSksIHRo4butIGzhuqFpIHNhdS5gKTsKICB9Cgog
IC8vIFRoZSByZXF1ZXN0J3MgZm9ybXMsIHRyaWVkIGluIHR1cm4gd2hpbGUgR2VtaW5pIGFuc3dl
cnMgNDAwIChhIG1vZGVsIHdpdGhvdXQgdGhhdCBzZXR0aW5nKTogdGhlIEpTT04gc2NoZW1hIGFu
ZAogIC8vIHRoZSB0aGlua2luZyBsZXZlbCwgdGhlbiBKU09OIGFsb25lLCB0aGVuIHBsYWluIHRl
eHQgKHRoZSBwYWdlIHJlYWRzIEpTT04gb3V0IG9mIGl0KS4gVGhlIGZvcm0gYSBtb2RlbCB0b29r
IGlzCiAgLy8gcmVtZW1iZXJlZC4KICBmdW5jdGlvbiBmb3JtcyhzY2hlbWEpIHsKICAgIGNvbnN0
IGxpc3QgPSBbXTsKICAgIGNvbnN0IHRoaW5raW5nID0gc2V0dGluZ3MudGhpbmtpbmcgPyB7IHRo
aW5raW5nQ29uZmlnOiB7IHRoaW5raW5nTGV2ZWw6IHNldHRpbmdzLnRoaW5raW5nIH0gfSA6IHt9
OwogICAgaWYgKHNjaGVtYSkgbGlzdC5wdXNoKHsgcmVzcG9uc2VNaW1lVHlwZTogJ2FwcGxpY2F0
aW9uL2pzb24nLCByZXNwb25zZUpzb25TY2hlbWE6IHNjaGVtYSwgbWF4T3V0cHV0VG9rZW5zOiBP
VVRQVVRfVE9LRU5TLCAuLi50aGlua2luZyB9KTsKICAgIGxpc3QucHVzaCh7IHJlc3BvbnNlTWlt
ZVR5cGU6ICdhcHBsaWNhdGlvbi9qc29uJywgbWF4T3V0cHV0VG9rZW5zOiBPVVRQVVRfVE9LRU5T
LCAuLi50aGlua2luZyB9KTsKICAgIGlmIChzZXR0aW5ncy50aGlua2luZykgbGlzdC5wdXNoKHsg
cmVzcG9uc2VNaW1lVHlwZTogJ2FwcGxpY2F0aW9uL2pzb24nLCBtYXhPdXRwdXRUb2tlbnM6IE9V
VFBVVF9UT0tFTlMgfSk7CiAgICBsaXN0LnB1c2goeyBtYXhPdXRwdXRUb2tlbnM6IE9VVFBVVF9U
T0tFTlMgfSk7CiAgICByZXR1cm4gbGlzdDsKICB9CgogIGFzeW5jIGZ1bmN0aW9uIGFzayh7IHN5
c3RlbSwgcHJvbXB0LCBzY2hlbWEgfSkgewogICAgaWYgKCFzZXR0aW5ncy5hcGlLZXkpIHRocm93
IG5ldyBBbnN3ZXIoNTAzLCAnUmVsYXkgY2jGsGEgY8OzIGtow7NhIEdlbWluaSBBUEk6IGNo4bun
IHJlbGF5IMSR4bq3dCDhu58gdHJhbmcgL2dlbWluaS4nKTsKICAgIGNvbnN0IG1vZGVsID0gc2V0
dGluZ3MubW9kZWw7CiAgICBjb25zdCB1cmwgPSBgJHtiYXNlfS9tb2RlbHMvJHtlbmNvZGVVUklD
b21wb25lbnQobW9kZWwpfTpnZW5lcmF0ZUNvbnRlbnRgOwogICAgY29uc3QgbGlzdCA9IGZvcm1z
KHNjaGVtYSk7CiAgICBjb25zdCBrZXkgPSBgJHttb2RlbH0gJHtzZXR0aW5ncy50aGlua2luZ30g
JHtzY2hlbWEgPyAxIDogMH1gOwogICAgY29uc3Qgc3RhcnRlZCA9IERhdGUubm93KCk7CiAgICBs
ZXQgZGF0YSA9IG51bGw7CiAgICBmb3IgKGxldCBhdCA9IHdvcmtpbmcuZ2V0KGtleSkgfHwgMDsg
YXQgPCBsaXN0Lmxlbmd0aDsgYXQgKz0gMSkgewogICAgICBjb25zdCBib2R5ID0geyBjb250ZW50
czogW3sgcm9sZTogJ3VzZXInLCBwYXJ0czogW3sgdGV4dDogcHJvbXB0IH1dIH1dLCBnZW5lcmF0
aW9uQ29uZmlnOiBsaXN0W2F0XSB9OwogICAgICBpZiAoc3lzdGVtKSBib2R5LnN5c3RlbUluc3Ry
dWN0aW9uID0geyBwYXJ0czogW3sgdGV4dDogc3lzdGVtIH1dIH07CiAgICAgIGNvbnN0IHJlc3Bv
bnNlID0gYXdhaXQgd2l0aFRpbWVvdXQodXJsLCB7CiAgICAgICAgbWV0aG9kOiAnUE9TVCcsCiAg
ICAgICAgaGVhZGVyczogeyAnY29udGVudC10eXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nLCAneC1n
b29nLWFwaS1rZXknOiBzZXR0aW5ncy5hcGlLZXkgfSwKICAgICAgICBib2R5OiBKU09OLnN0cmlu
Z2lmeShib2R5KSwKICAgICAgfSk7CiAgICAgIGNvbnN0IHRleHQgPSBhd2FpdCByZXNwb25zZS50
ZXh0KCk7CiAgICAgIHRyeSB7IGRhdGEgPSBKU09OLnBhcnNlKHRleHQpOyB9IGNhdGNoIHsgZGF0
YSA9IG51bGw7IH0KICAgICAgaWYgKHJlc3BvbnNlLm9rKSB7CiAgICAgICAgd29ya2luZy5zZXQo
a2V5LCBhdCk7CiAgICAgICAgYnJlYWs7CiAgICAgIH0KICAgICAgY29uc3QgbWVzc2FnZSA9IChk
YXRhICYmIGRhdGEuZXJyb3IgJiYgZGF0YS5lcnJvci5tZXNzYWdlKSB8fCAnJzsKICAgICAgaWYg
KHJlc3BvbnNlLnN0YXR1cyA9PT0gNDAwICYmIGF0ICsgMSA8IGxpc3QubGVuZ3RoICYmICEvYXBp
IGtleS9pLnRlc3QobWVzc2FnZSkpIGNvbnRpbnVlOwogICAgICB0aHJvdyB1cHN0cmVhbUVycm9y
KHJlc3BvbnNlLnN0YXR1cywgZGF0YSwgbW9kZWwpOwogICAgfQogICAgY29uc3QgY2FuZGlkYXRl
ID0gZGF0YSAmJiBBcnJheS5pc0FycmF5KGRhdGEuY2FuZGlkYXRlcykgPyBkYXRhLmNhbmRpZGF0
ZXNbMF0gOiBudWxsOwogICAgY29uc3QgcGFydHMgPSBjYW5kaWRhdGUgJiYgY2FuZGlkYXRlLmNv
bnRlbnQgJiYgQXJyYXkuaXNBcnJheShjYW5kaWRhdGUuY29udGVudC5wYXJ0cykgPyBjYW5kaWRh
dGUuY29udGVudC5wYXJ0cyA6IFtdOwogICAgY29uc3QgYW5zd2VyID0gcGFydHMuZmlsdGVyKChw
YXJ0KSA9PiBwYXJ0ICYmIHR5cGVvZiBwYXJ0LnRleHQgPT09ICdzdHJpbmcnICYmICFwYXJ0LnRo
b3VnaHQpLm1hcCgocGFydCkgPT4gcGFydC50ZXh0KS5qb2luKCcnKTsKICAgIGlmICghYW5zd2Vy
KSB7CiAgICAgIGNvbnN0IGJsb2NrZWQgPSBkYXRhICYmIGRhdGEucHJvbXB0RmVlZGJhY2sgJiYg
ZGF0YS5wcm9tcHRGZWVkYmFjay5ibG9ja1JlYXNvbjsKICAgICAgY29uc3QgcmVhc29uID0gYmxv
Y2tlZCB8fCAoY2FuZGlkYXRlICYmIGNhbmRpZGF0ZS5maW5pc2hSZWFzb24pIHx8ICdraMO0bmcg
Y8OzIGNo4buvJzsKICAgICAgdGhyb3cgbmV3IEFuc3dlcig1MDIsIGBHZW1pbmkga2jDtG5nIHRy
4bqjIGzhu51pICgke3NjcnViKHJlYXNvbil9KS5gKTsKICAgIH0KICAgIHJldHVybiB7IHRleHQ6
IGFuc3dlci5zbGljZSgwLCAxNjAwMCksIG1zOiBEYXRlLm5vdygpIC0gc3RhcnRlZCwgbW9kZWwg
fTsKICB9CgogIGZ1bmN0aW9uIG5vdGUocmVzdWx0LCBlcnJvcikgewogICAgcm9sbERheSgpOwog
ICAgc2V0dGluZ3MuY2FsbHMgKz0gMTsKICAgIGlmIChlcnJvcikgc2V0dGluZ3MuZXJyb3JzICs9
IDE7CiAgICBzZXR0aW5ncy5sYXN0ID0geyBhdDogbmV3IERhdGUoKS50b0lTT1N0cmluZygpLCBt
czogcmVzdWx0ID8gcmVzdWx0Lm1zIDogMCwgZXJyb3I6IGVycm9yID8gc2NydWIoZXJyb3IubWVz
c2FnZSkgOiAnJyB9OwogICAgdHJ5IHsgc2F2ZSgpOyB9IGNhdGNoIChwcm9ibGVtKSB7IGxvZygn
Z2VtaW5pOiBjYW5ub3Qgc2F2ZScsIHByb2JsZW0gJiYgcHJvYmxlbS5tZXNzYWdlKTsgfQogIH0K
CiAgLy8gVGhlIGxpbWl0czogb25lIGNhbGwgYXQgYSB0aW1lIGFuZCBhIHBhdXNlIGJldHdlZW4g
dHdvIGZyb20gb25lIGFkZHJlc3MsIHRoZSBjYWxscyBhIG1pbnV0ZSBhbmQgYSBkYXkuCiAgZnVu
Y3Rpb24gYWRtaXQoYWRkcmVzcykgewogICAgcm9sbERheSgpOwogICAgY29uc3QgdGltZSA9IERh
dGUubm93KCk7CiAgICBpZiAoYnVzeS5oYXMoYWRkcmVzcykpIHRocm93IG5ldyBBbnN3ZXIoNDI5
LCAnxJBhbmcgY2jhu50gR2VtaW5pIHRy4bqjIGzhu51pIGPDonUgdHLGsOG7m2MuJywgeyByZXRy
eU1zOiAxMDAwIH0pOwogICAgY29uc3QgcHJldmlvdXMgPSBsYXN0Q2FsbC5nZXQoYWRkcmVzcykg
fHwgMDsKICAgIGlmICh0aW1lIC0gcHJldmlvdXMgPCBnYXApIHRocm93IG5ldyBBbnN3ZXIoNDI5
LCAnSOG7j2kgR2VtaW5pIGNo4bqtbSBs4bqhaSBt4buZdCBjaMO6dC4nLCB7IHJldHJ5TXM6IGdh
cCAtICh0aW1lIC0gcHJldmlvdXMpIH0pOwogICAgbWludXRlID0gbWludXRlLmZpbHRlcigoYXQp
ID0+IHRpbWUgLSBhdCA8IDYwMDAwKTsKICAgIGlmIChzZXR0aW5ncy5wZXJNaW51dGUgJiYgbWlu
dXRlLmxlbmd0aCA+PSBzZXR0aW5ncy5wZXJNaW51dGUpIHsKICAgICAgdGhyb3cgbmV3IEFuc3dl
cig0MjksIGDEkMOjIHThu5tpIGdp4bubaSBo4bqhbiAke3NldHRpbmdzLnBlck1pbnV0ZX0gbOG6
p24gbeG7mXQgcGjDunQgKHRyYW5nIC9nZW1pbmkpLmAsIHsgcmV0cnlNczogNjAwMDAgLSAodGlt
ZSAtIG1pbnV0ZVswXSkgfSk7CiAgICB9CiAgICBpZiAoc2V0dGluZ3MucGVyRGF5ICYmIHNldHRp
bmdzLmNhbGxzID49IHNldHRpbmdzLnBlckRheSkgewogICAgICB0aHJvdyBuZXcgQW5zd2VyKDQy
OSwgYEjDtG0gbmF5IMSRw6MgaOG7j2kgR2VtaW5pICR7c2V0dGluZ3MuY2FsbHN9IGzhuqduLCB0
4bubaSBnaeG7m2kgaOG6oW4gbeG7mXQgbmfDoHkgKHRyYW5nIC9nZW1pbmkpLmAsIHsgcmV0cnlN
czogMzYwMDAwMCB9KTsKICAgIH0KICAgIG1pbnV0ZS5wdXNoKHRpbWUpOwogICAgbGFzdENhbGwu
c2V0KGFkZHJlc3MsIHRpbWUpOwogICAgYnVzeS5hZGQoYWRkcmVzcyk7CiAgfQoKICBhc3luYyBm
dW5jdGlvbiByb3V0ZShyZXEsIHJlcywgd2hhdCkgewogICAgY29uc3QgbWV0aG9kID0gcmVxLm1l
dGhvZDsKICAgIGlmICh3aGF0ID09PSAncGxhbicpIHsKICAgICAgY29uc3QgY29ycyA9IGFsbG93
T3JpZ2luKHJlcSk7CiAgICAgIGlmIChtZXRob2QgPT09ICdPUFRJT05TJykgewogICAgICAgIHJl
cy53cml0ZUhlYWQoMjA0LCB7IC4uLmNvcnMsICdhY2Nlc3MtY29udHJvbC1hbGxvdy1tZXRob2Rz
JzogJ1BPU1QsIE9QVElPTlMnLAogICAgICAgICAgJ2FjY2Vzcy1jb250cm9sLWFsbG93LWhlYWRl
cnMnOiAnY29udGVudC10eXBlLCB4LWdlbWluaS1jb2RlJywgJ2FjY2Vzcy1jb250cm9sLW1heC1h
Z2UnOiAnNjAwJyB9KTsKICAgICAgICByZXMuZW5kKCk7CiAgICAgICAgcmV0dXJuOwogICAgICB9
CiAgICAgIGlmIChtZXRob2QgIT09ICdQT1NUJykgdGhyb3cgbmV3IEFuc3dlcig0MDUsICdDaOG7
iSBuaOG6rW4gUE9TVC4nKTsKICAgICAgYXV0aG9yaXplUGxheWVyKHJlcSk7CiAgICAgIGlmICgh
c2V0dGluZ3MuZW5hYmxlZCkgdGhyb3cgbmV3IEFuc3dlcig0MDMsICdDaOG7pyByZWxheSDEkWFu
ZyB04bqvdCBHZW1pbmkgKHRyYW5nIC9nZW1pbmkpLicpOwogICAgICBpZiAoIXNldHRpbmdzLmFw
aUtleSkgdGhyb3cgbmV3IEFuc3dlcig1MDMsICdSZWxheSBjaMawYSBjw7Mga2jDs2EgR2VtaW5p
IEFQSTogY2jhu6cgcmVsYXkgxJHhurd0IOG7nyB0cmFuZyAvZ2VtaW5pLicpOwogICAgICBjb25z
dCBib2R5ID0gYXdhaXQgcmVhZEpzb24ocmVxLCBSRVFVRVNUX0xJTUlUKTsKICAgICAgY29uc3Qg
c3lzdGVtID0gdHlwZW9mIGJvZHkuc3lzdGVtID09PSAnc3RyaW5nJyA/IGJvZHkuc3lzdGVtIDog
Jyc7CiAgICAgIGNvbnN0IHByb21wdCA9IHR5cGVvZiBib2R5LnByb21wdCA9PT0gJ3N0cmluZycg
PyBib2R5LnByb21wdCA6ICcnOwogICAgICBpZiAoIXByb21wdCkgdGhyb3cgbmV3IEFuc3dlcig0
MDAsICdUaGnhur91IHTDrG5oIGjDrG5oIHRy4bqtbiDEkeG6pXUgKHByb21wdCkuJyk7CiAgICAg
IGlmIChzeXN0ZW0ubGVuZ3RoID4gU1lTVEVNX0xJTUlUIHx8IHByb21wdC5sZW5ndGggPiBQUk9N
UFRfTElNSVQpIHRocm93IG5ldyBBbnN3ZXIoNDEzLCAnVMOsbmggaMOsbmggdHLhuq1uIMSR4bql
dSBxdcOhIGTDoGkuJyk7CiAgICAgIGxldCBzY2hlbWEgPSBudWxsOwogICAgICBpZiAoYm9keS5z
Y2hlbWEgJiYgdHlwZW9mIGJvZHkuc2NoZW1hID09PSAnb2JqZWN0JyAmJiAhQXJyYXkuaXNBcnJh
eShib2R5LnNjaGVtYSkpIHsKICAgICAgICBpZiAoSlNPTi5zdHJpbmdpZnkoYm9keS5zY2hlbWEp
Lmxlbmd0aCA+IFNDSEVNQV9MSU1JVCkgdGhyb3cgbmV3IEFuc3dlcig0MTMsICdTY2hlbWEgcXXD
oSBkw6BpLicpOwogICAgICAgIHNjaGVtYSA9IGJvZHkuc2NoZW1hOwogICAgICB9CiAgICAgIGNv
bnN0IGFkZHJlc3MgPSBjbGllbnRBZGRyZXNzKHJlcSk7CiAgICAgIGFkbWl0KGFkZHJlc3MpOwog
ICAgICBsZXQgcmVzdWx0OwogICAgICB0cnkgewogICAgICAgIHJlc3VsdCA9IGF3YWl0IGFzayh7
IHN5c3RlbSwgcHJvbXB0LCBzY2hlbWEgfSk7CiAgICAgICAgbm90ZShyZXN1bHQsIG51bGwpOwog
ICAgICB9IGNhdGNoIChlcnJvcikgewogICAgICAgIG5vdGUobnVsbCwgZXJyb3IpOwogICAgICAg
IHRocm93IGVycm9yOwogICAgICB9IGZpbmFsbHkgewogICAgICAgIGJ1c3kuZGVsZXRlKGFkZHJl
c3MpOwogICAgICB9CiAgICAgIGpzb24ocmVzLCAyMDAsIHJlc3VsdCwgY29ycyk7CiAgICAgIHJl
dHVybjsKICAgIH0KICAgIGF1dGhvcml6ZUFkbWluKHJlcSk7CiAgICBpZiAod2hhdCA9PT0gJ3Ry
YW5nLXRoYWknICYmIG1ldGhvZCA9PT0gJ0dFVCcpIHsKICAgICAganNvbihyZXMsIDIwMCwgZGVz
Y3JpYmUoKSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmICh3aGF0ID09PSAnY2FpLWRhdCcg
JiYgbWV0aG9kID09PSAnUFVUJykgewogICAgICBjb25zdCBib2R5ID0gYXdhaXQgcmVhZEpzb24o
cmVxLCA4ICogMTAyNCk7CiAgICAgIGlmICh0eXBlb2YgYm9keS5hcGlLZXkgPT09ICdzdHJpbmcn
ICYmIGJvZHkuYXBpS2V5LnRyaW0oKSkgewogICAgICAgIGNvbnN0IGtleSA9IGJvZHkuYXBpS2V5
LnRyaW0oKTsKICAgICAgICBpZiAoIUtFWS50ZXN0KGtleSkpIHRocm93IG5ldyBBbnN3ZXIoNDAw
LCAnS2jDs2EgR2VtaW5pIEFQSSBraMO0bmcgZ2nhu5FuZyBraMOzYSB0aOG6rXQgKGTDoW4gbOG6
oWksIGtow7RuZyBjw7MgZOG6pXUgY8OhY2gpLicpOwogICAgICAgIHNldHRpbmdzLmFwaUtleSA9
IGtleTsKICAgICAgICB3b3JraW5nLmNsZWFyKCk7CiAgICAgIH0KICAgICAgaWYgKGJvZHkuY2xl
YXJLZXkgPT09IHRydWUpIHNldHRpbmdzLmFwaUtleSA9ICcnOwogICAgICBpZiAoYm9keS5tb2Rl
bCAhPT0gdW5kZWZpbmVkKSB7CiAgICAgICAgY29uc3QgbW9kZWwgPSBTdHJpbmcoYm9keS5tb2Rl
bCkudHJpbSgpLnJlcGxhY2UoL15tb2RlbHNcLy8sICcnKTsKICAgICAgICBpZiAoIU1PREVMLnRl
c3QobW9kZWwpKSB0aHJvdyBuZXcgQW5zd2VyKDQwMCwgJ1TDqm4gbW9kZWwga2jDtG5nIGjhu6Nw
IGzhu4cgKHbDrSBk4bulIGdlbWluaS0zLjUtZmxhc2gtbGl0ZSkuJyk7CiAgICAgICAgc2V0dGlu
Z3MubW9kZWwgPSBtb2RlbDsKICAgICAgfQogICAgICBpZiAoYm9keS50aGlua2luZyAhPT0gdW5k
ZWZpbmVkKSB7CiAgICAgICAgaWYgKCFUSElOS0lORy5pbmNsdWRlcyhib2R5LnRoaW5raW5nKSkg
dGhyb3cgbmV3IEFuc3dlcig0MDAsICdN4bupYyBzdXkgbmdoxKkga2jDtG5nIGjhu6NwIGzhu4cu
Jyk7CiAgICAgICAgc2V0dGluZ3MudGhpbmtpbmcgPSBib2R5LnRoaW5raW5nOwogICAgICB9CiAg
ICAgIGlmIChib2R5LnBlck1pbnV0ZSAhPT0gdW5kZWZpbmVkKSBzZXR0aW5ncy5wZXJNaW51dGUg
PSB3aG9sZShib2R5LnBlck1pbnV0ZSwgMCwgMTAwMCwgc2V0dGluZ3MucGVyTWludXRlKTsKICAg
ICAgaWYgKGJvZHkucGVyRGF5ICE9PSB1bmRlZmluZWQpIHNldHRpbmdzLnBlckRheSA9IHdob2xl
KGJvZHkucGVyRGF5LCAwLCAxMDAwMDAwLCBzZXR0aW5ncy5wZXJEYXkpOwogICAgICBpZiAoYm9k
eS5lbmFibGVkICE9PSB1bmRlZmluZWQpIHNldHRpbmdzLmVuYWJsZWQgPSBCb29sZWFuKGJvZHku
ZW5hYmxlZCk7CiAgICAgIGlmICghc2V0dGluZ3MuY29kZSkgc2V0dGluZ3MuY29kZSA9IG5ld0Nv
ZGUoKTsKICAgICAgc2F2ZSgpOwogICAgICBsb2coYGdlbWluaTogc2V0dGluZ3MgKG1vZGVsICR7
c2V0dGluZ3MubW9kZWx9LCBrZXkgJHtzZXR0aW5ncy5hcGlLZXkgPyAnc2V0JyA6ICdub25lJ30p
YCk7CiAgICAgIGpzb24ocmVzLCAyMDAsIGRlc2NyaWJlKCkpOwogICAgICByZXR1cm47CiAgICB9
CiAgICBpZiAod2hhdCA9PT0gJ2RvaS1tYScgJiYgbWV0aG9kID09PSAnUE9TVCcpIHsKICAgICAg
c2V0dGluZ3MuY29kZSA9IG5ld0NvZGUoKTsKICAgICAgc2F2ZSgpOwogICAgICBqc29uKHJlcywg
MjAwLCBkZXNjcmliZSgpKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHdoYXQgPT09ICdt
b2RlbHMnICYmIG1ldGhvZCA9PT0gJ0dFVCcpIHsKICAgICAgaWYgKCFzZXR0aW5ncy5hcGlLZXkp
IHRocm93IG5ldyBBbnN3ZXIoNDAwLCAnQ2jGsGEgY8OzIGtow7NhIEdlbWluaSBBUEkuJyk7CiAg
ICAgIGNvbnN0IG5hbWVzID0gW107CiAgICAgIGxldCB0b2tlbiA9ICcnOwogICAgICBmb3IgKGxl
dCBwYWdlID0gMDsgcGFnZSA8IDU7IHBhZ2UgKz0gMSkgewogICAgICAgIGNvbnN0IHVybCA9IGAk
e2Jhc2V9L21vZGVscz9wYWdlU2l6ZT0yMDAke3Rva2VuID8gYCZwYWdlVG9rZW49JHtlbmNvZGVV
UklDb21wb25lbnQodG9rZW4pfWAgOiAnJ31gOwogICAgICAgIGNvbnN0IHJlc3BvbnNlID0gYXdh
aXQgd2l0aFRpbWVvdXQodXJsLCB7IGhlYWRlcnM6IHsgJ3gtZ29vZy1hcGkta2V5Jzogc2V0dGlu
Z3MuYXBpS2V5IH0gfSk7CiAgICAgICAgbGV0IGRhdGEgPSBudWxsOwogICAgICAgIHRyeSB7IGRh
dGEgPSBKU09OLnBhcnNlKGF3YWl0IHJlc3BvbnNlLnRleHQoKSk7IH0gY2F0Y2ggeyBkYXRhID0g
bnVsbDsgfQogICAgICAgIGlmICghcmVzcG9uc2Uub2spIHRocm93IHVwc3RyZWFtRXJyb3IocmVz
cG9uc2Uuc3RhdHVzLCBkYXRhLCBzZXR0aW5ncy5tb2RlbCk7CiAgICAgICAgZm9yIChjb25zdCBt
b2RlbCBvZiAoZGF0YSAmJiBkYXRhLm1vZGVscykgfHwgW10pIHsKICAgICAgICAgIGNvbnN0IG1l
dGhvZHMgPSBtb2RlbC5zdXBwb3J0ZWRHZW5lcmF0aW9uTWV0aG9kcyB8fCBbXTsKICAgICAgICAg
IGNvbnN0IG5hbWUgPSBTdHJpbmcobW9kZWwubmFtZSB8fCAnJykucmVwbGFjZSgvXm1vZGVsc1wv
LywgJycpOwogICAgICAgICAgaWYgKG1ldGhvZHMuaW5jbHVkZXMoJ2dlbmVyYXRlQ29udGVudCcp
ICYmIE1PREVMLnRlc3QobmFtZSkpIG5hbWVzLnB1c2gobmFtZSk7CiAgICAgICAgfQogICAgICAg
IHRva2VuID0gZGF0YSAmJiBkYXRhLm5leHRQYWdlVG9rZW47CiAgICAgICAgaWYgKCF0b2tlbikg
YnJlYWs7CiAgICAgIH0KICAgICAganNvbihyZXMsIDIwMCwgeyBtb2RlbHM6IG5hbWVzIH0pOwog
ICAgICByZXR1cm47CiAgICB9CiAgICBpZiAod2hhdCA9PT0gJ3RodScgJiYgbWV0aG9kID09PSAn
UE9TVCcpIHsKICAgICAgY29uc3Qgc2NoZW1hID0geyB0eXBlOiAnb2JqZWN0JywgcHJvcGVydGll
czogeyBvazogeyB0eXBlOiAnYm9vbGVhbicgfSwgc2F5OiB7IHR5cGU6ICdzdHJpbmcnIH0gfSwg
cmVxdWlyZWQ6IFsnb2snLCAnc2F5J10gfTsKICAgICAgbGV0IHJlc3VsdDsKICAgICAgdHJ5IHsK
ICAgICAgICByZXN1bHQgPSBhd2FpdCBhc2soewogICAgICAgICAgc3lzdGVtOiAnWW91IGNoZWNr
IHRoYXQgYSBjb25uZWN0aW9uIHdvcmtzLiBBbnN3ZXIgb25seSBKU09OLicsCiAgICAgICAgICBw
cm9tcHQ6ICdSZXBseSB7Im9rIjogdHJ1ZSwgInNheSI6ICI8b25lIHNob3J0IGZyaWVuZGx5IHNl
bnRlbmNlIGluIFZpZXRuYW1lc2Ugc2F5aW5nIHlvdSBhcmUgcmVhZHkgdG8gY29tbWFuZCB0aGUg
ZmlnaHRlcnM+In0nLAogICAgICAgICAgc2NoZW1hLAogICAgICAgIH0pOwogICAgICAgIG5vdGUo
cmVzdWx0LCBudWxsKTsKICAgICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgICBub3RlKG51bGws
IGVycm9yKTsKICAgICAgICB0aHJvdyBlcnJvcjsKICAgICAgfQogICAgICBqc29uKHJlcywgMjAw
LCByZXN1bHQpOwogICAgICByZXR1cm47CiAgICB9CiAgICB0aHJvdyBuZXcgQW5zd2VyKDQwNCwg
J0tow7RuZyBjw7MgecOqdSBj4bqndSBuw6B5LicpOwogIH0KCiAgLy8gUmV0dXJucyB0cnVlIHdo
ZW4gdGhlIHJlcXVlc3Qgd2FzIEdlbWluaSdzIGFuZCBoYXMgYmVlbiBhbnN3ZXJlZCAob3IgaXMg
YmVpbmcgYW5zd2VyZWQpLgogIGZ1bmN0aW9uIGhhbmRsZShyZXEsIHJlcywgcGF0aG5hbWUpIHsK
ICAgIGlmIChwYXRobmFtZSA9PT0gJy9nZW1pbmknIHx8IHBhdGhuYW1lID09PSAnL2dlbWluaS8n
KSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdjb250ZW50LXR5cGUnOiAndGV4dC9odG1s
OyBjaGFyc2V0PXV0Zi04JywgJ2NhY2hlLWNvbnRyb2wnOiAnbm8tc3RvcmUnLAogICAgICAgICd4
LWZyYW1lLW9wdGlvbnMnOiAnREVOWScsICdyZWZlcnJlci1wb2xpY3knOiAnbm8tcmVmZXJyZXIn
IH0pOwogICAgICByZXMuZW5kKFBBR0UpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlm
ICghcGF0aG5hbWUuc3RhcnRzV2l0aCgnL2dlbWluaS9hcGkvJykpIHJldHVybiBmYWxzZTsKICAg
IGNvbnN0IHdoYXQgPSBwYXRobmFtZS5zbGljZSgnL2dlbWluaS9hcGkvJy5sZW5ndGgpOwogICAg
cm91dGUocmVxLCByZXMsIHdoYXQpLmNhdGNoKChlcnJvcikgPT4gewogICAgICBjb25zdCBzdGF0
dXMgPSBlcnJvciBpbnN0YW5jZW9mIEFuc3dlciA/IGVycm9yLnN0YXR1cyA6IChlcnJvciBpbnN0
YW5jZW9mIFN5bnRheEVycm9yID8gNDAwIDogNTAwKTsKICAgICAgaWYgKHN0YXR1cyA9PT0gNTAw
KSBsb2coJ2dlbWluaTonLCBlcnJvciAmJiBlcnJvci5zdGFjayA/IGVycm9yLnN0YWNrIDogZXJy
b3IpOwogICAgICBpZiAocmVzLmhlYWRlcnNTZW50KSB7CiAgICAgICAgcmVzLmRlc3Ryb3koKTsK
ICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgY29uc3QgbWVzc2FnZSA9IGVycm9yIGluc3Rh
bmNlb2YgQW5zd2VyID8gZXJyb3IubWVzc2FnZSA6IChzdGF0dXMgPT09IDQwMCA/ICdZw6p1IGPh
uqd1IGjhu49uZy4nIDogJ0zhu5dpIHRyw6puIHJlbGF5LicpOwogICAgICBjb25zdCBleHRyYSA9
IGVycm9yIGluc3RhbmNlb2YgQW5zd2VyID8gZXJyb3IuZXh0cmEgOiB7fTsKICAgICAganNvbihy
ZXMsIHN0YXR1cywgeyBlcnJvcjogbWVzc2FnZSwgLi4uZXh0cmEgfSwgd2hhdCA9PT0gJ3BsYW4n
ID8gYWxsb3dPcmlnaW4ocmVxKSA6IHt9KTsKICAgIH0pOwogICAgcmV0dXJuIHRydWU7CiAgfQoK
ICByZXR1cm4gewogICAgaGFuZGxlLAogICAgY2xlYW51cDogKCkgPT4gewogICAgICBjb25zdCB0
aW1lID0gRGF0ZS5ub3coKTsKICAgICAgZm9yIChjb25zdCBbYWRkcmVzcywgZW50cnldIG9mIGZh
aWx1cmVzKSBpZiAoZW50cnkudW50aWwgPD0gdGltZSkgZmFpbHVyZXMuZGVsZXRlKGFkZHJlc3Mp
OwogICAgICBmb3IgKGNvbnN0IFthZGRyZXNzLCBhdF0gb2YgbGFzdENhbGwpIGlmICh0aW1lIC0g
YXQgPiA2MDAwMCAmJiAhYnVzeS5oYXMoYWRkcmVzcykpIGxhc3RDYWxsLmRlbGV0ZShhZGRyZXNz
KTsKICAgIH0sCiAgICBzZXR0aW5nczogKCkgPT4gc2V0dGluZ3MsCiAgfTsKfQoKLy8gVGhlIHBh
Z2UgYXQgL2dlbWluaSAoVmlldG5hbWVzZTogdGhlIHJlbGF5J3Mgb3duZXIgcmVhZHMgaXQpLiBU
aGUgYWRtaW4ga2V5IGlzIHRoZSBvbmUgL2FkbWluIGFuZCAvaG9jIHJlbWVtYmVyLgpjb25zdCBQ
QUdFID0gYDwhZG9jdHlwZSBodG1sPgo8aHRtbCBsYW5nPSJ2aSI+PGhlYWQ+PG1ldGEgY2hhcnNl
dD0idXRmLTgiPjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lk
dGgsIGluaXRpYWwtc2NhbGU9MSI+Cjx0aXRsZT5PcGVuTEYyIHJlbGF5OiBHZW1pbmkgY2jGoWkg
Y8O5bmc8L3RpdGxlPgo8c3R5bGU+CiAgYm9keSB7IG1hcmdpbjogMDsgcGFkZGluZzogMS41cmVt
OyBiYWNrZ3JvdW5kOiAjMTExODI3OyBjb2xvcjogI2YzZjRmNjsgZm9udDogMTZweC8xLjUgc3lz
dGVtLXVpLCBzYW5zLXNlcmlmOyB9CiAgbWFpbiB7IG1heC13aWR0aDogODIwcHg7IG1hcmdpbjog
YXV0bzsgfQogIGgxIHsgZm9udC1zaXplOiAxLjVyZW07IG1hcmdpbjogMCAwIC4yNXJlbTsgfQog
IGgyIHsgZm9udC1zaXplOiAxLjE1cmVtOyBtYXJnaW46IDAgMCAuNXJlbTsgfQogIC5jYXJkIHsg
YmFja2dyb3VuZDogIzFmMjkzNzsgYm9yZGVyOiAxcHggc29saWQgIzM3NDE1MTsgYm9yZGVyLXJh
ZGl1czogMTJweDsgcGFkZGluZzogMXJlbSAxLjJyZW07IG1hcmdpbjogMXJlbSAwOyB9CiAgbGFi
ZWwgeyBkaXNwbGF5OiBibG9jazsgbWFyZ2luOiAuNnJlbSAwIC4ycmVtOyBmb250LXdlaWdodDog
NjAwOyB9CiAgbGFiZWwuaW5saW5lIHsgZGlzcGxheTogZmxleDsgZ2FwOiAuNXJlbTsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsgZm9udC13ZWlnaHQ6IDUwMDsgfQogIGlucHV0W3R5cGU9dGV4dF0sIGlu
cHV0W3R5cGU9cGFzc3dvcmRdLCBpbnB1dFt0eXBlPW51bWJlcl0sIHNlbGVjdCB7IHdpZHRoOiAx
MDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBwYWRkaW5nOiAuNXJlbSAuNnJlbTsKICAgIGZv
bnQ6IGluaGVyaXQ7IGJvcmRlci1yYWRpdXM6IDhweDsgYm9yZGVyOiAxcHggc29saWQgIzRiNTU2
MzsgYmFja2dyb3VuZDogIzBiMTIyMDsgY29sb3I6IGluaGVyaXQ7IH0KICAuZ3JpZCB7IGRpc3Bs
YXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogcmVwZWF0KGF1dG8tZml0LCBtaW5tYXgo
MTcwcHgsIDFmcikpOyBnYXA6IDAgLjhyZW07IH0KICBidXR0b24geyBwYWRkaW5nOiAuNTVyZW0g
MS4xcmVtOyBmb250OiBpbmhlcml0OyBib3JkZXItcmFkaXVzOiA4cHg7IGJvcmRlcjogMDsgY3Vy
c29yOiBwb2ludGVyOyBiYWNrZ3JvdW5kOiAjZjU5ZTBiOyBjb2xvcjogIzFmMTMwMDsgZm9udC13
ZWlnaHQ6IDcwMDsgfQogIGJ1dHRvbi5zZWNvbmRhcnkgeyBiYWNrZ3JvdW5kOiAjMzc0MTUxOyBj
b2xvcjogI2YzZjRmNjsgZm9udC13ZWlnaHQ6IDUwMDsgfQogIC5ub3RlIHsgY29sb3I6ICM5Y2Ez
YWY7IGZvbnQtc2l6ZTogLjlyZW07IH0KICAub2sgeyBjb2xvcjogIzZlZTdiNzsgfSAuYmFkIHsg
Y29sb3I6ICNmY2E1YTU7IH0KICBjb2RlIHsgYmFja2dyb3VuZDogIzBiMTIyMDsgcGFkZGluZzog
LjA1cmVtIC4zcmVtOyBib3JkZXItcmFkaXVzOiA0cHg7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsg
fQogIC5jb2RlIHsgZm9udDogNjAwIDEuNHJlbS8xLjIgdWktbW9ub3NwYWNlLCBtb25vc3BhY2U7
IGxldHRlci1zcGFjaW5nOiAuMDhlbTsgY29sb3I6ICNmY2QzNGQ7IH0KICBhIHsgY29sb3I6ICM5
M2M1ZmQ7IH0KPC9zdHlsZT48L2hlYWQ+Cjxib2R5PjxtYWluPgogIDxoMT5HZW1pbmkgY2jGoWkg
Y8O5bmc8L2gxPgogIDxwIGNsYXNzPSJub3RlIj5HZW1pbmkgY2jhu4kgaHV5IGPDoWMgbcOheSBY
T0kgdHJvbmcgdHJhbmcgZ2FtZTogbeG7l2kgdsOgaSBnacOieSB0cmFuZyBnYW1lIGfhu61pIHTD
rG5oIGjDrG5oIHRy4bqtbiDEkeG6pXUgdOG7m2kgcmVsYXksIHJlbGF5IGjhu49pCiAgICBHZW1p
bmkgYuG6sW5nIGtow7NhIEFQSSBj4bunYSBi4bqhbiAoa2jDs2EgY2jhu4kgbuG6sW0gdHLDqm4g
VlBTIG7DoHksIHRyYW5nIGdhbWUga2jDtG5nIHRo4bqleSksIHLhu5NpIGfhu61pIGzhuqFpIGzh
u4duaCBjaG8gdOG7q25nIG3DoXk6IMSRw6FuaCBhaSwgxJHDoW5oIG3huqFuaAogICAgaGF5IHRo
4bunLCDEkeG7qW5nIGfhuqduIGhheSB4YSwgZ2nhu68gYmFvIG5oacOqdSBNUC4gWE9JIHbhuqtu
IMSRaeG7gXUga2hp4buDbiB04burbmcga2h1bmcgaMOsbmggdGhlbyBs4buHbmgg4bqleS48L3A+
CiAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICA8bGFiZWwgZm9yPSJrZXkiPk3DoyBxdeG6o24gdHLh
u4sgKEFETUlOX0tFWSk8L2xhYmVsPgogICAgPGlucHV0IGlkPSJrZXkiIHR5cGU9InBhc3N3b3Jk
IiBhdXRvY29tcGxldGU9ImN1cnJlbnQtcGFzc3dvcmQiIHBsYWNlaG9sZGVyPSJpbiByYSBraGkg
Y2jhuqF5IGluc3RhbGwtdnBzLnNoIj4KICAgIDxwPjxidXR0b24gaWQ9ImxvYWQiIGNsYXNzPSJz
ZWNvbmRhcnkiPlhlbTwvYnV0dG9uPjwvcD4KICAgIDxwIGlkPSJzdGF0dXMiIHJvbGU9InN0YXR1
cyIgY2xhc3M9Im5vdGUiPjwvcD4KICA8L2Rpdj4KICA8ZGl2IGlkPSJwYW5lcyIgaGlkZGVuPgog
IDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGgyPktow7NhIEdlbWluaSBBUEk8L2gyPgogICAgPHAg
aWQ9ImtleXN0YXRlIiBjbGFzcz0ibm90ZSI+PC9wPgogICAgPHAgY2xhc3M9Im5vdGUiPkzhuqV5
IGtow7NhIG1p4buFbiBwaMOtIOG7nyA8YSBocmVmPSJodHRwczovL2Fpc3R1ZGlvLmdvb2dsZS5j
b20vYXBpa2V5IiB0YXJnZXQ9Il9ibGFuayIgcmVsPSJub29wZW5lciI+R29vZ2xlIEFJIFN0dWRp
bzwvYT46CiAgICAgIMSRxINuZyBuaOG6rXAgdMOgaSBraG/huqNuIEdvb2dsZSwgYuG6pW0gPGI+
Q3JlYXRlIEFQSSBrZXk8L2I+LCBjaMOpcCBraMOzYSBy4buTaSBkw6FuIHbDoG8gxJHDonkuIE7D
qm4gZMO5bmcga2jDs2EgY+G7p2EgZOG7sSDDoW4gY2jGsGEgYuG6rXQgdGhhbmggdG/DoW4KICAg
ICAgKGfDs2kgbWnhu4VuIHBow60pOiBo4bq/dCBsxrDhu6N0IHRow6wgR2VtaW5pIGNo4buJIGLD
oW8gbOG7l2ksIGtow7RuZyBt4bqldCB0aeG7gW4uIOG7niBnw7NpIG1p4buFbiBwaMOtIEdvb2ds
ZSBjw7MgdGjhu4MgZMO5bmcgbuG7mWkgZHVuZyBn4butaSDEkWkgKOG7nyDEkcOieSBjaOG7iSBs
w6AKICAgICAgdMOsbmggaMOsbmggdHLhuq1uIMSR4bqldSkgxJHhu4MgY+G6o2kgdGhp4buHbiBz
4bqjbiBwaOG6qW0gY+G7p2EgaOG7jS48L3A+CiAgICA8bGFiZWwgZm9yPSJhcGlrZXkiPktow7Nh
IG3hu5tpPC9sYWJlbD4KICAgIDxpbnB1dCBpZD0iYXBpa2V5IiB0eXBlPSJwYXNzd29yZCIgYXV0
b2NvbXBsZXRlPSJvZmYiIHBsYWNlaG9sZGVyPSJkw6FuIGtow7NhIEdlbWluaSBBUEkgKGtow7Ru
ZyBoaeG7h24gbOG6oWkgc2F1IGtoaSBsxrB1KSI+CiAgICA8cD48YnV0dG9uIGlkPSJzYXZla2V5
Ij5MxrB1IGtow7NhPC9idXR0b24+IDxidXR0b24gaWQ9ImNsZWFya2V5IiBjbGFzcz0ic2Vjb25k
YXJ5Ij5Yw7NhIGtow7NhPC9idXR0b24+PC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9ImNhcmQi
PgogICAgPGgyPk1vZGVsIHbDoCBnaeG7m2kgaOG6oW48L2gyPgogICAgPGRpdiBjbGFzcz0iZ3Jp
ZCI+CiAgICAgIDxkaXY+PGxhYmVsIGZvcj0ibW9kZWwiPk1vZGVsPC9sYWJlbD48aW5wdXQgaWQ9
Im1vZGVsIiB0eXBlPSJ0ZXh0IiBsaXN0PSJtb2RlbHMiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVs
bGNoZWNrPSJmYWxzZSI+PGRhdGFsaXN0IGlkPSJtb2RlbHMiPjwvZGF0YWxpc3Q+PC9kaXY+CiAg
ICAgIDxkaXY+PGxhYmVsIGZvcj0idGhpbmtpbmciPk3hu6ljIHN1eSBuZ2jEqTwvbGFiZWw+PHNl
bGVjdCBpZD0idGhpbmtpbmciPgogICAgICAgIDxvcHRpb24gdmFsdWU9IiI+TeG6t2MgxJHhu4tu
aCBj4bunYSBtb2RlbDwvb3B0aW9uPjxvcHRpb24gdmFsdWU9Im1pbmltYWwiPm1pbmltYWwgKG5o
YW5oIG5o4bqldCk8L29wdGlvbj48b3B0aW9uIHZhbHVlPSJsb3ciPmxvdzwvb3B0aW9uPgogICAg
ICAgIDxvcHRpb24gdmFsdWU9Im1lZGl1bSI+bWVkaXVtPC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0i
aGlnaCI+aGlnaCAoY2jhuq1tKTwvb3B0aW9uPjwvc2VsZWN0PjwvZGl2PgogICAgICA8ZGl2Pjxs
YWJlbCBmb3I9InBlck1pbnV0ZSI+VOG7kWkgxJFhIG3hu5dpIHBow7p0PC9sYWJlbD48aW5wdXQg
aWQ9InBlck1pbnV0ZSIgdHlwZT0ibnVtYmVyIiBtaW49IjAiPjwvZGl2PgogICAgICA8ZGl2Pjxs
YWJlbCBmb3I9InBlckRheSI+VOG7kWkgxJFhIG3hu5dpIG5nw6B5PC9sYWJlbD48aW5wdXQgaWQ9
InBlckRheSIgdHlwZT0ibnVtYmVyIiBtaW49IjAiPjwvZGl2PgogICAgPC9kaXY+CiAgICA8bGFi
ZWwgY2xhc3M9ImlubGluZSI+PGlucHV0IGlkPSJlbmFibGVkIiB0eXBlPSJjaGVja2JveCI+IENo
byB0cmFuZyBnYW1lIGTDuW5nIEdlbWluaTwvbGFiZWw+CiAgICA8cCBjbGFzcz0ibm90ZSI+TW9k
ZWwgbmhhbmgsIHLhursgaOG7o3AgaMahbiBjaG8gdHLhuq1uIMSR4bqldSAodHLhuqMgbOG7nWkg
ZMaw4bubaSAx4oCTMiBnacOieSk6IDxjb2RlPmdlbWluaS0zLjUtZmxhc2gtbGl0ZTwvY29kZT47
IDxjb2RlPmdlbWluaS0zLjYtZmxhc2g8L2NvZGU+CiAgICAgIGtow7RuIGjGoW4gbmjGsG5nIGNo
4bqtbSBoxqFuLiBHaeG7m2kgaOG6oW4gY+G7p2Ega2jDs2EgbWnhu4VuIHBow60gdMO5eSBtb2Rl
bCB2w6AgdMO5eSB0w6BpIGtob+G6o246IHhlbSDhu58KICAgICAgPGEgaHJlZj0iaHR0cHM6Ly9h
aXN0dWRpby5nb29nbGUuY29tL3JhdGUtbGltaXQiIHRhcmdldD0iX2JsYW5rIiByZWw9Im5vb3Bl
bmVyIj50cmFuZyBnaeG7m2kgaOG6oW4gY+G7p2EgQUkgU3R1ZGlvPC9hPi4gTeG7mXQgbmfGsOG7
nWkgY2jGoWkgaOG7j2kgbeG7l2kKICAgICAgNCBnacOieSBsw6AgMTUgbOG6p24gbeG7mXQgcGjD
unQ7IDAgbMOgIGtow7RuZyBnaeG7m2kgaOG6oW4uPC9wPgogICAgPHA+PGJ1dHRvbiBpZD0ic2F2
ZSI+TMawdTwvYnV0dG9uPiA8YnV0dG9uIGlkPSJsaXN0IiBjbGFzcz0ic2Vjb25kYXJ5Ij5YZW0g
Y8OhYyBtb2RlbCBj4bunYSBraMOzYSBuw6B5PC9idXR0b24+PC9wPgogIDwvZGl2PgogIDxkaXYg
Y2xhc3M9ImNhcmQiPgogICAgPGgyPk3DoyBjaG8gbmfGsOG7nWkgY2jGoWk8L2gyPgogICAgPHAg
Y2xhc3M9ImNvZGUiIGlkPSJjb2RlIj7igJQ8L3A+CiAgICA8cCBjbGFzcz0ibm90ZSI+VHJvbmcg
dHJhbmcgZ2FtZSwgbeG7nyBwaOG6p24gPGI+R2VtaW5pIGNoxqFpIGPDuW5nPC9iPiAobmdheSB0
csOqbiBraHVuZyBnYW1lKSBy4buTaSBkw6FuIG3DoyBuw6B5IHbDoG8gw7QgPGI+TcOjIEdlbWlu
aTwvYj4uIEFpIGPDswogICAgICBtw6MgbeG7m2kgZMO5bmcgxJHGsOG7o2MgR2VtaW5pIHF1YSBy
ZWxheSBuw6B5OyDEkeG7lWkgbcOjIHRow6wgbcOjIGPFqSBo4bq/dCBkw7luZy48L3A+CiAgICA8
cD48YnV0dG9uIGlkPSJjb3B5IiBjbGFzcz0ic2Vjb25kYXJ5Ij5DaMOpcCBtw6M8L2J1dHRvbj4g
PGJ1dHRvbiBpZD0ibmV3Y29kZSIgY2xhc3M9InNlY29uZGFyeSI+xJDhu5VpIG3DozwvYnV0dG9u
PjwvcD4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgIDxoMj5UaOG7rSB2w6AgaMO0
bSBuYXk8L2gyPgogICAgPHA+PGJ1dHRvbiBpZD0idGVzdCI+VGjhu60gZ+G7jWkgR2VtaW5pPC9i
dXR0b24+PC9wPgogICAgPHAgaWQ9InRlc3RyZXN1bHQiIGNsYXNzPSJub3RlIj48L3A+CiAgICA8
cCBpZD0idXNhZ2UiIGNsYXNzPSJub3RlIj48L3A+CiAgPC9kaXY+CiAgPC9kaXY+CjwvbWFpbj4K
PHNjcmlwdD4KICBjb25zdCAkID0gKGlkKSA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7
CiAgY29uc3QgYmFzZSA9IGxvY2F0aW9uLnBhdGhuYW1lLnJlcGxhY2UoL1xcLyskLywgJycpOwog
IGNvbnN0IGFwaSA9IGJhc2UgKyAnL2FwaS8nOwogIGxldCBzdGF0ZSA9IG51bGw7CiAgdHJ5IHsg
JCgna2V5JykudmFsdWUgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnbGYyLWFkbWluLWtleScpIHx8
ICcnOyB9IGNhdGNoIChlcnJvcikge30KICBjb25zdCByZW1lbWJlciA9ICgpID0+IHsgdHJ5IHsg
bG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2xmMi1hZG1pbi1rZXknLCAkKCdrZXknKS52YWx1ZSk7IH0g
Y2F0Y2ggKGVycm9yKSB7fSB9OwogIGZ1bmN0aW9uIHN0YXR1cyh0ZXh0LCBraW5kKSB7ICQoJ3N0
YXR1cycpLnRleHRDb250ZW50ID0gdGV4dDsgJCgnc3RhdHVzJykuY2xhc3NOYW1lID0ga2luZCB8
fCAnbm90ZSc7IH0KICBhc3luYyBmdW5jdGlvbiBjYWxsKG1ldGhvZCwgd2hhdCwgYm9keSkgewog
ICAgY29uc3QgcmVzcG9uc2UgPSBhd2FpdCBmZXRjaChhcGkgKyB3aGF0LCB7IG1ldGhvZCwgaGVh
ZGVyczogeyAneC1hZG1pbi1rZXknOiAkKCdrZXknKS52YWx1ZSwgJ2NvbnRlbnQtdHlwZSc6ICdh
cHBsaWNhdGlvbi9qc29uJyB9LAogICAgICBib2R5OiBib2R5ID09PSB1bmRlZmluZWQgPyB1bmRl
ZmluZWQgOiBKU09OLnN0cmluZ2lmeShib2R5KSB9KTsKICAgIGNvbnN0IHRleHQgPSBhd2FpdCBy
ZXNwb25zZS50ZXh0KCk7CiAgICBsZXQgZGF0YTsKICAgIHRyeSB7IGRhdGEgPSBKU09OLnBhcnNl
KHRleHQpOyB9IGNhdGNoIChlcnJvcikgeyBkYXRhID0geyBlcnJvcjogdGV4dCB9OyB9CiAgICBp
ZiAoIXJlc3BvbnNlLm9rKSB0aHJvdyBuZXcgRXJyb3IoZGF0YS5lcnJvciB8fCAoJ0hUVFAgJyAr
IHJlc3BvbnNlLnN0YXR1cykpOwogICAgcmV0dXJuIGRhdGE7CiAgfQogIGNvbnN0IHRpbWUgPSAo
aXNvKSA9PiB7IGlmICghaXNvKSByZXR1cm4gJyc7IGNvbnN0IGQgPSBuZXcgRGF0ZShpc28pOyBy
ZXR1cm4gZC50b0xvY2FsZVN0cmluZygndmktVk4nLCB7IGhvdXI6ICcyLWRpZ2l0JywgbWludXRl
OiAnMi1kaWdpdCcsIHNlY29uZDogJzItZGlnaXQnLCBkYXk6ICcyLWRpZ2l0JywgbW9udGg6ICcy
LWRpZ2l0JyB9KTsgfTsKICBmdW5jdGlvbiByZW5kZXIoKSB7CiAgICAkKCdwYW5lcycpLmhpZGRl
biA9IGZhbHNlOwogICAgJCgna2V5c3RhdGUnKS50ZXh0Q29udGVudCA9IHN0YXRlLmNvbmZpZ3Vy
ZWQgPyAnxJDDoyBjw7Mga2jDs2EgKOKApicgKyBzdGF0ZS5rZXlFbmQgKyAnKS4nIDogJ0NoxrBh
IGPDsyBraMOzYTogZMOhbiBraMOzYSDhu58gZMaw4bubaS4nOwogICAgJCgna2V5c3RhdGUnKS5j
bGFzc05hbWUgPSBzdGF0ZS5jb25maWd1cmVkID8gJ29rJyA6ICdiYWQnOwogICAgZm9yIChjb25z
dCBuYW1lIG9mIFsnbW9kZWwnLCAndGhpbmtpbmcnLCAncGVyTWludXRlJywgJ3BlckRheSddKSBp
ZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCAhPT0gJChuYW1lKSkgJChuYW1lKS52YWx1ZSA9IHN0
YXRlW25hbWVdOwogICAgJCgnZW5hYmxlZCcpLmNoZWNrZWQgPSBzdGF0ZS5lbmFibGVkOwogICAg
aWYgKCEkKCdtb2RlbHMnKS5jaGlsZHJlbi5sZW5ndGgpIGZvciAoY29uc3QgbmFtZSBvZiBzdGF0
ZS5zdWdnZXN0ZWQgfHwgW10pIHsgY29uc3QgbyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ29w
dGlvbicpOyBvLnZhbHVlID0gbmFtZTsgJCgnbW9kZWxzJykuYXBwZW5kQ2hpbGQobyk7IH0KICAg
ICQoJ2NvZGUnKS50ZXh0Q29udGVudCA9IHN0YXRlLmNvZGUgfHwgJ+KAlCAobMawdSBraMOzYSDE
keG7gyBjw7MgbcOjKSc7CiAgICBsZXQgdXNhZ2UgPSAnSMO0bSBuYXkgxJHDoyBo4buPaSBHZW1p
bmkgJyArIHN0YXRlLmNhbGxzICsgJyBs4bqnbicgKyAoc3RhdGUucGVyRGF5ID8gJyAvICcgKyBz
dGF0ZS5wZXJEYXkgOiAnJykgKyAnLCBs4buXaSAnICsgc3RhdGUuZXJyb3JzICsgJyBs4bqnbi4n
OwogICAgaWYgKHN0YXRlLmxhc3QpIHVzYWdlICs9ICcgTOG6p24gY3Xhu5FpIGzDumMgJyArIHRp
bWUoc3RhdGUubGFzdC5hdCkgKyAoc3RhdGUubGFzdC5lcnJvciA/ICc6IGzhu5dpIOKAlCAnICsg
c3RhdGUubGFzdC5lcnJvciA6ICc6IHRy4bqjIGzhu51pIHNhdSAnICsgKHN0YXRlLmxhc3QubXMg
LyAxMDAwKS50b0ZpeGVkKDEpLnJlcGxhY2UoJy4nLCAnLCcpICsgJyBnacOieS4nKTsKICAgIGlm
ICghc3RhdGUuc3RvcmVkKSB1c2FnZSArPSAnIFJlbGF5IG7DoHkga2jDtG5nIGPDsyB0aMawIG3h
u6VjIGzGsHUgKFBBQ0tTX0RJUik6IGPDoGkgxJHhurd0IG3huqV0IGtoaSByZWxheSBraOG7n2kg
xJHhu5luZyBs4bqhaS4nOwogICAgJCgndXNhZ2UnKS50ZXh0Q29udGVudCA9IHVzYWdlOwogIH0K
ICBhc3luYyBmdW5jdGlvbiBsb2FkKHF1aWV0KSB7CiAgICBpZiAoISQoJ2tleScpLnZhbHVlKSBy
ZXR1cm4gc3RhdHVzKCdOaOG6rXAgbcOjIHF14bqjbiB0cuG7iyB0csaw4bubYy4nLCAnYmFkJyk7
CiAgICByZW1lbWJlcigpOwogICAgdHJ5IHsgc3RhdGUgPSBhd2FpdCBjYWxsKCdHRVQnLCAndHJh
bmctdGhhaScpOyByZW5kZXIoKTsgaWYgKCFxdWlldCkgc3RhdHVzKCfEkMOjIHThuqNpLicsICdv
aycpOyB9CiAgICBjYXRjaCAoZXJyb3IpIHsgc3RhdHVzKGVycm9yLm1lc3NhZ2UsICdiYWQnKTsg
fQogIH0KICAkKCdsb2FkJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiBsb2FkKGZh
bHNlKSk7CiAgJCgnc2F2ZWtleScpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5bmMgKCkg
PT4gewogICAgY29uc3QgYXBpS2V5ID0gJCgnYXBpa2V5JykudmFsdWUudHJpbSgpOwogICAgaWYg
KCFhcGlLZXkpIHJldHVybiBzdGF0dXMoJ0TDoW4ga2jDs2EgR2VtaW5pIEFQSSB2w6BvIMO0IHRy
xrDhu5tjLicsICdiYWQnKTsKICAgIHRyeSB7IHN0YXRlID0gYXdhaXQgY2FsbCgnUFVUJywgJ2Nh
aS1kYXQnLCB7IGFwaUtleSB9KTsgJCgnYXBpa2V5JykudmFsdWUgPSAnJzsgcmVuZGVyKCk7IHN0
YXR1cygnxJDDoyBsxrB1IGtow7NhLiBC4bqlbSAiVGjhu60gZ+G7jWkgR2VtaW5pIiDEkeG7gyB4
ZW0ga2jDs2EgZMO5bmcgxJHGsOG7o2Mga2jDtG5nLicsICdvaycpOyB9CiAgICBjYXRjaCAoZXJy
b3IpIHsgc3RhdHVzKGVycm9yLm1lc3NhZ2UsICdiYWQnKTsgfQogIH0pOwogICQoJ2NsZWFya2V5
JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBhc3luYyAoKSA9PiB7CiAgICBpZiAoIWNvbmZp
cm0oJ1jDs2Ega2jDs2EgR2VtaW5pIEFQSSBraOG7j2kgcmVsYXk/IFRyYW5nIGdhbWUgc+G6vSBr
aMO0bmcgZMO5bmcgxJHGsOG7o2MgR2VtaW5pIHThu5tpIGtoaSBi4bqhbiBkw6FuIGtow7NhIG3h
u5tpLicpKSByZXR1cm47CiAgICB0cnkgeyBzdGF0ZSA9IGF3YWl0IGNhbGwoJ1BVVCcsICdjYWkt
ZGF0JywgeyBjbGVhcktleTogdHJ1ZSB9KTsgcmVuZGVyKCk7IHN0YXR1cygnxJDDoyB4w7NhIGto
w7NhLicsICdvaycpOyB9CiAgICBjYXRjaCAoZXJyb3IpIHsgc3RhdHVzKGVycm9yLm1lc3NhZ2Us
ICdiYWQnKTsgfQogIH0pOwogICQoJ3NhdmUnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGFz
eW5jICgpID0+IHsKICAgIHRyeSB7CiAgICAgIHN0YXRlID0gYXdhaXQgY2FsbCgnUFVUJywgJ2Nh
aS1kYXQnLCB7IG1vZGVsOiAkKCdtb2RlbCcpLnZhbHVlLCB0aGlua2luZzogJCgndGhpbmtpbmcn
KS52YWx1ZSwgcGVyTWludXRlOiBOdW1iZXIoJCgncGVyTWludXRlJykudmFsdWUpLAogICAgICAg
IHBlckRheTogTnVtYmVyKCQoJ3BlckRheScpLnZhbHVlKSwgZW5hYmxlZDogJCgnZW5hYmxlZCcp
LmNoZWNrZWQgfSk7CiAgICAgIHJlbmRlcigpOyBzdGF0dXMoJ8SQw6MgbMawdS4nLCAnb2snKTsK
ICAgIH0gY2F0Y2ggKGVycm9yKSB7IHN0YXR1cyhlcnJvci5tZXNzYWdlLCAnYmFkJyk7IH0KICB9
KTsKICAkKCdsaXN0JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBhc3luYyAoKSA9PiB7CiAg
ICB0cnkgewogICAgICBjb25zdCBkYXRhID0gYXdhaXQgY2FsbCgnR0VUJywgJ21vZGVscycpOwog
ICAgICAkKCdtb2RlbHMnKS5pbm5lckhUTUwgPSAnJzsKICAgICAgZm9yIChjb25zdCBuYW1lIG9m
IGRhdGEubW9kZWxzKSB7IGNvbnN0IG8gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdvcHRpb24n
KTsgby52YWx1ZSA9IG5hbWU7ICQoJ21vZGVscycpLmFwcGVuZENoaWxkKG8pOyB9CiAgICAgIHN0
YXR1cygnS2jDs2EgbsOgeSBkw7luZyDEkcaw4bujYyAnICsgZGF0YS5tb2RlbHMubGVuZ3RoICsg
JyBtb2RlbCAoYuG6pW0gdsOgbyDDtCBNb2RlbCDEkeG7gyBjaOG7jW4pOiAnICsgZGF0YS5tb2Rl
bHMuZmlsdGVyKChuKSA9PiAvZmxhc2gvLnRlc3QobikpLnNsaWNlKDAsIDEyKS5qb2luKCcsICcp
LCAnb2snKTsKICAgIH0gY2F0Y2ggKGVycm9yKSB7IHN0YXR1cyhlcnJvci5tZXNzYWdlLCAnYmFk
Jyk7IH0KICB9KTsKICAkKCdjb3B5JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBhc3luYyAo
KSA9PiB7CiAgICBpZiAoIXN0YXRlIHx8ICFzdGF0ZS5jb2RlKSByZXR1cm47CiAgICB0cnkgeyBh
d2FpdCBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dChzdGF0ZS5jb2RlKTsgc3RhdHVzKCfE
kMOjIGNow6lwIG3Doy4nLCAnb2snKTsgfSBjYXRjaCAoZXJyb3IpIHsgc3RhdHVzKCdLaMO0bmcg
Y2jDqXAgxJHGsOG7o2M6IGNo4buNbiBtw6MgcuG7k2kgY2jDqXAgdGF5LicsICdiYWQnKTsgfQog
IH0pOwogICQoJ25ld2NvZGUnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGFzeW5jICgpID0+
IHsKICAgIGlmICghY29uZmlybSgnxJDhu5VpIG3DoyBjaG8gbmfGsOG7nWkgY2jGoWk/IEFpIMSR
YW5nIGTDuW5nIG3DoyBjxakgcGjhuqNpIGTDoW4gbcOjIG3hu5tpLicpKSByZXR1cm47CiAgICB0
cnkgeyBzdGF0ZSA9IGF3YWl0IGNhbGwoJ1BPU1QnLCAnZG9pLW1hJyk7IHJlbmRlcigpOyBzdGF0
dXMoJ8SQw6MgxJHhu5VpIG3Doy4nLCAnb2snKTsgfQogICAgY2F0Y2ggKGVycm9yKSB7IHN0YXR1
cyhlcnJvci5tZXNzYWdlLCAnYmFkJyk7IH0KICB9KTsKICAkKCd0ZXN0JykuYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCBhc3luYyAoKSA9PiB7CiAgICAkKCd0ZXN0cmVzdWx0JykudGV4dENvbnRl
bnQgPSAnxJBhbmcgaOG7j2kgR2VtaW5p4oCmJzsKICAgICQoJ3Rlc3RyZXN1bHQnKS5jbGFzc05h
bWUgPSAnbm90ZSc7CiAgICB0cnkgewogICAgICBjb25zdCBkYXRhID0gYXdhaXQgY2FsbCgnUE9T
VCcsICd0aHUnKTsKICAgICAgbGV0IHNheSA9IGRhdGEudGV4dDsKICAgICAgdHJ5IHsgc2F5ID0g
SlNPTi5wYXJzZShkYXRhLnRleHQpLnNheSB8fCBkYXRhLnRleHQ7IH0gY2F0Y2ggKGVycm9yKSB7
fQogICAgICAkKCd0ZXN0cmVzdWx0JykudGV4dENvbnRlbnQgPSAnR2VtaW5pICgnICsgZGF0YS5t
b2RlbCArICcpIHRy4bqjIGzhu51pIHNhdSAnICsgKGRhdGEubXMgLyAxMDAwKS50b0ZpeGVkKDEp
LnJlcGxhY2UoJy4nLCAnLCcpICsgJyBnacOieTogJyArIHNheTsKICAgICAgJCgndGVzdHJlc3Vs
dCcpLmNsYXNzTmFtZSA9ICdvayc7CiAgICB9IGNhdGNoIChlcnJvcikgeyAkKCd0ZXN0cmVzdWx0
JykudGV4dENvbnRlbnQgPSBlcnJvci5tZXNzYWdlOyAkKCd0ZXN0cmVzdWx0JykuY2xhc3NOYW1l
ID0gJ2JhZCc7IH0KICAgIGxvYWQodHJ1ZSk7CiAgfSk7CiAgaWYgKCQoJ2tleScpLnZhbHVlKSBs
b2FkKHRydWUpOwo8L3NjcmlwdD4KPC9ib2R5PjwvaHRtbD4KYDsKCm1vZHVsZS5leHBvcnRzID0g
eyBjcmVhdGVHZW1pbmksIG5ld0NvZGUsIG5vZGVGZXRjaCwgU1VHR0VTVEVELCBERUZBVUxUUyB9
Owo=
LF2_PAYLOAD
}

write_package_json() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
ewogICJuYW1lIjogIm9wZW5sZjItb25saW5lLXJlbGF5IiwKICAidmVyc2lvbiI6ICIxLjAuMCIs
CiAgInByaXZhdGUiOiB0cnVlLAogICJkZXNjcmlwdGlvbiI6ICJXZWJTb2NrZXQgcmVsYXkgZm9y
IE9wZW5MRjIgd2ViIHBsYXllcnM6IHJvb21zIG9mIHVwIHRvIDggcGxheWVycyBieSByb29tIGNv
ZGUsIGtlcHQgaW4gc3RlcCBieSB0aGUgcmVsYXksIGFuZCB0aGUgZ2FtZSBmaWxlcyBpdCBzZXJ2
ZXMiLAogICJsaWNlbnNlIjogIk1JVCIsCiAgIm1haW4iOiAic2VydmVyLmpzIiwKICAiYmluIjog
ewogICAgIm9wZW5sZjItcmVsYXkiOiAic2VydmVyLmpzIgogIH0sCiAgInNjcmlwdHMiOiB7CiAg
ICAic3RhcnQiOiAibm9kZSBzZXJ2ZXIuanMiLAogICAgInRlc3QiOiAibm9kZSAtLXRlc3QgXCJ0
ZXN0LyoudGVzdC5qc1wiIgogIH0sCiAgImVuZ2luZXMiOiB7CiAgICAibm9kZSI6ICI+PTIwIgog
IH0sCiAgImRlcGVuZGVuY2llcyI6IHsKICAgICJ3cyI6ICJeOC4xOC4wIgogIH0KfQo=
LF2_PAYLOAD
}
# <<< generated

# Last line on purpose: bash reads the whole script before running anything, so a cut-off
# download does nothing, and commands cannot swallow the script through stdin.
[ "${LF2_INSTALLER_LIB:-}" = 1 ] || main "$@"
