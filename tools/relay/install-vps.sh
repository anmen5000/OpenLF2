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
# and kept in /opt/lf2-relay/data/packs.
#
# Everything lives in /opt/lf2-relay plus two services, lf2-relay and lf2-caddy. The relay's own
# files are embedded below (update-installer.js writes them), so this file is all a server needs.
# Messages are Vietnamese without diacritics, so that every terminal shows them.
set -euo pipefail

INSTALLER_VERSION=9
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
Zi8gKHNlZSBoZi5qcykuCid1c2Ugc3RyaWN0JzsKCmNvbnN0IGZzID0gcmVxdWlyZSgnbm9kZTpm
cycpOwpjb25zdCBodHRwID0gcmVxdWlyZSgnbm9kZTpodHRwJyk7CmNvbnN0IHsgV2ViU29ja2V0
U2VydmVyLCBXZWJTb2NrZXQgfSA9IHJlcXVpcmUoJ3dzJyk7CmNvbnN0IHsgY3JlYXRlUGFja3Mg
fSA9IHJlcXVpcmUoJy4vcGFja3MuanMnKTsKY29uc3QgeyBjcmVhdGVIZiB9ID0gcmVxdWlyZSgn
Li9oZi5qcycpOwoKY29uc3QgSU5TVEFMTEVSX1BBVEggPSAnL2xmMi1pbnN0YWxsZXIuZGF0YSc7
Cgpjb25zdCBST09NX1BBVFRFUk4gPSAvXlxkezQsMTJ9JC87CgovLyBDbG9zZSBjb2RlcyBhcmUg
cGFydCBvZiB0aGUgY29udHJhY3Qgd2l0aCBvbmxpbmUuanMgKGl0IG1hcHMgdGhlbSB0byBtZXNz
YWdlcyB0b28pLgpjb25zdCBDTE9TRSA9IE9iamVjdC5mcmVlemUoewogIGJhZFJlcXVlc3Q6IFs0
MDAwLCAnUmVsYXk6IGJhZCByZXF1ZXN0J10sCiAgb3JpZ2luRGVuaWVkOiBbNDAwMSwgJ1JlbGF5
OiB0aGlzIHdlYnNpdGUgbWF5IG5vdCB1c2UgdGhlIHJlbGF5J10sCiAgdG9vTWFueUNvbm5lY3Rp
b25zOiBbNDAwMiwgJ1JlbGF5OiB0b28gbWFueSBjb25uZWN0aW9ucyBmcm9tIHlvdXIgbmV0d29y
ayddLAogIHNlcnZlckZ1bGw6IFs0MDAzLCAnUmVsYXk6IHNlcnZlciBpcyBmdWxsJ10sCiAgaG9z
dFRha2VuOiBbNDAwNCwgJ1JlbGF5OiByb29tIGFscmVhZHkgaGFzIGEgaG9zdCddLAogIGd1ZXN0
VGFrZW46IFs0MDA0LCAnUmVsYXk6IHJvb20gYWxyZWFkeSBoYXMgYSBndWVzdCddLAogIHRpbWVv
dXQ6IFs0MDA1LCAnUmVsYXk6IG5vYm9keSBqb2luZWQgaW4gdGltZSddLAogIHBlZXJMZWZ0OiBb
NDAwNiwgJ1JlbGF5OiB0aGUgb3RoZXIgcGxheWVyIGxlZnQnXSwKICByYXRlTGltaXRlZDogWzQw
MDcsICdSZWxheTogdG9vIG11Y2ggdHJhZmZpYyddLAogIHNsb3dQZWVyOiBbNDAwOCwgJ1JlbGF5
OiB0aGUgb3RoZXIgcGxheWVyIHN0b3BwZWQgcmVhZGluZyddLAogIGVhcmx5RGF0YTogWzQwMDks
ICdSZWxheTogZGF0YSBzZW50IGJlZm9yZSBwYWlyaW5nJ10sCiAgLy8gUHJvdG9jb2wgMiByb29t
cy4KICByb29tRnVsbDogWzQwMTAsICdSZWxheTogdGhlIHJvb20gaXMgZnVsbCddLAogIHN0YXJ0
ZWQ6IFs0MDExLCAnUmVsYXk6IHRoZSBnYW1lIGluIHRoaXMgcm9vbSBoYXMgYWxyZWFkeSBzdGFy
dGVkJ10sCiAgbWlzbWF0Y2g6IFs0MDEyLCAnUmVsYXk6IHRoaXMgcm9vbSBwbGF5cyBhbm90aGVy
IGdhbWUgdmVyc2lvbiBvciBtb2QnXSwKICBob3N0TGVmdDogWzQwMTMsICdSZWxheTogdGhlIGhv
c3QgbGVmdCB0aGUgcm9vbSddLAogIG5vdFN0YXJ0ZWQ6IFs0MDE0LCAnUmVsYXk6IHRoZSBob3N0
IGRpZCBub3Qgc3RhcnQgdGhlIGdhbWUgaW4gdGltZSddLAogIHByb3RvY29sOiBbNDAxNSwgJ1Jl
bGF5OiB1bmV4cGVjdGVkIG1lc3NhZ2UgZnJvbSB0aGUgZ2FtZSddLAogIHNsb3dDbGllbnQ6IFs0
MDE2LCAnUmVsYXk6IHlvdXIgY29ubmVjdGlvbiBpcyB0b28gc2xvdyBmb3IgdGhlIGdhbWUnXSwK
ICBjb2RlSW5Vc2U6IFs0MDE3LCAnUmVsYXk6IHRoaXMgcm9vbSBjb2RlIGlzIGluIHVzZSBieSBh
biBvbGRlciBnYW1lIHBhZ2UnXSwKICBuZXdlclJvb206IFs0MDE3LCAnUmVsYXk6IHRoaXMgcm9v
bSBpcyBmb3IgYSBuZXdlciBnYW1lIHBhZ2UgKHJlbG9hZCB0aGUgcGFnZSknXSwKICBzaHV0ZG93
bjogWzEwMDEsICdSZWxheTogc2VydmVyIGlzIHJlc3RhcnRpbmcnXSwKfSk7CgovLyBQcm90b2Nv
bCAyIG1lc3NhZ2Uga2luZHMgKHNlZSAiUm9vbXMiIGJlbG93KS4KY29uc3QgS0lORCA9IE9iamVj
dC5mcmVlemUoewogIGhlbGxvOiAweDAxLCBzdGFydDogMHgwMiwgaW5wdXQ6IDB4MDMsIHJlYWR5
OiAweDA0LCBjaGVjazogMHgwNSwKICB3ZWxjb21lOiAweDgxLCBsb2JieTogMHg4Miwgc3RhcnRl
ZDogMHg4MywgZnJhbWU6IDB4ODQsIGNoZWNrZWQ6IDB4ODUsIGxlZnQ6IDB4ODYsCn0pOwpjb25z
dCBST09NX0xJTUlUUyA9IE9iamVjdC5mcmVlemUoeyBwbGF5ZXJzOiA4LCBwcm9maWxlOiAyMDAs
IGluZm86IDY0LCBpbnB1dDogMTYsIHNldHVwOiA4MTkyLCBxdWV1ZTogNjQgfSk7CgpmdW5jdGlv
biByZWFkQ29uZmlnKGVudiA9IHByb2Nlc3MuZW52KSB7CiAgY29uc3QgbnVtYmVyID0gKG5hbWUs
IGZhbGxiYWNrKSA9PiB7CiAgICBjb25zdCByYXcgPSBlbnZbbmFtZV07CiAgICBjb25zdCB2YWx1
ZSA9IHJhdyA9PT0gdW5kZWZpbmVkIHx8IHJhdyA9PT0gJycgPyBmYWxsYmFjayA6IE51bWJlcihy
YXcpOwogICAgaWYgKCFOdW1iZXIuaXNGaW5pdGUodmFsdWUpIHx8IHZhbHVlIDwgMCkgdGhyb3cg
bmV3IEVycm9yKGAke25hbWV9IG11c3QgYmUgYSBub24tbmVnYXRpdmUgbnVtYmVyYCk7CiAgICBy
ZXR1cm4gdmFsdWU7CiAgfTsKICByZXR1cm4gewogICAgcG9ydDogbnVtYmVyKCdQT1JUJywgODc4
NyksCiAgICBob3N0OiBlbnYuSE9TVCB8fCAnMC4wLjAuMCcsCiAgICBwYXRoOiBlbnYuUkVMQVlf
UEFUSCB8fCAnL3JlbGF5JywKICAgIC8vIENvbW1hLXNlcGFyYXRlZCBwYWdlIG9yaWdpbnMgYWxs
b3dlZCB0byBjb25uZWN0LCBlLmcuICJodHRwczovL3lvdS5naXRodWIuaW8iLiBFbXB0eSBhbGxv
d3MgYW55LgogICAgYWxsb3dlZE9yaWdpbnM6IChlbnYuQUxMT1dFRF9PUklHSU5TIHx8ICcnKS5z
cGxpdCgnLCcpLm1hcChub3JtYWxpemVPcmlnaW4pLmZpbHRlcihCb29sZWFuKSwKICAgIC8vIEJl
aGluZCBhIHJldmVyc2UgcHJveHkgKENhZGR5LCBuZ2lueCwgQ2xvdWRmbGFyZSksIHRha2UgdGhl
IGNsaWVudCBhZGRyZXNzIGZyb20gWC1Gb3J3YXJkZWQtRm9yLgogICAgdHJ1c3RQcm94eTogZW52
LlRSVVNUX1BST1hZID09PSAnMScgfHwgZW52LlRSVVNUX1BST1hZID09PSAndHJ1ZScsCiAgICBt
YXhSb29tczogbnVtYmVyKCdNQVhfUk9PTVMnLCA1MDApLCAvLyAwID0gdW5saW1pdGVkCiAgICBt
YXhDb25uZWN0aW9uc1BlcklwOiBudW1iZXIoJ01BWF9DT05ORUNUSU9OU19QRVJfSVAnLCA4KSwg
Ly8gMCA9IHVubGltaXRlZAogICAgcm9vbVdhaXRNczogbnVtYmVyKCdST09NX1dBSVRfTVMnLCAx
MjAwMDApLAogICAgcGluZ0ludGVydmFsTXM6IG51bWJlcignUElOR19JTlRFUlZBTF9NUycsIDE1
MDAwKSwKICAgIG1heE1lc3NhZ2VCeXRlczogbnVtYmVyKCdNQVhfTUVTU0FHRV9CWVRFUycsIDY1
NTM2KSwgLy8gdGhlIGdhbWUgcXVldWVzIGF0IG1vc3QgNjQgS2lCCiAgICBtZXNzYWdlc1BlclNl
Y29uZDogbnVtYmVyKCdNRVNTQUdFU19QRVJfU0VDT05EJywgMjQwKSwgLy8gdGhlIGdhbWUgc2Vu
ZHMgfjMwIHBlciBzZWNvbmQ7IDAgPSB1bmxpbWl0ZWQKICAgIGJ5dGVzUGVyU2Vjb25kOiBudW1i
ZXIoJ0JZVEVTX1BFUl9TRUNPTkQnLCAxMzEwNzIpLCAvLyAwID0gdW5saW1pdGVkCiAgICBtYXhC
dWZmZXJlZEJ5dGVzOiBudW1iZXIoJ01BWF9CVUZGRVJFRF9CWVRFUycsIDEwNDg1NzYpLAogICAg
Ly8gVGVzdGluZyBhaWQ6IGhvbGQgZXZlcnkgZm9yd2FyZGVkIGZyYW1lIHRoaXMgbG9uZywgdG8g
ZmVlbCBob3cgYSBkaXN0YW50IHJlbGF5IHdvdWxkIHBsYXkuCiAgICBmb3J3YXJkRGVsYXlNczog
bnVtYmVyKCdGT1JXQVJEX0RFTEFZX01TJywgMCksCiAgICAvLyBQcm90b2NvbCAyIHJvb21zOiBt
b3N0IHBsYXllcnMgaW4gYSByb29tIChhdCBtb3N0IDgsIHRoZSBnYW1lJ3MgcGxheWVyIHNsb3Rz
KSwgdGhlIGJlYXQsIGhvdwogICAgLy8gbG9uZyBhIHJvb20gbWF5IHdhaXQgZm9yIGl0cyBob3N0
IHRvIHByZXNzIHN0YXJ0LCBob3cgbG9uZyB0aGUgcmVsYXkgd2FpdHMgZm9yIGV2ZXJ5IGdhbWUg
dG8KICAgIC8vIGJlIHJlYWR5IGFmdGVyIHRoZSBzdGFydCwgYW5kIGFmdGVyIGhvdyBtYW55IGJl
YXRzIHdpdGhvdXQgbmV3cyBhIHBsYXllcidzIGtleXMgY291bnQgYXMgcmVsZWFzZWQuCiAgICBy
b29tUGxheWVyczogTWF0aC5taW4oUk9PTV9MSU1JVFMucGxheWVycywgTWF0aC5tYXgoMiwgbnVt
YmVyKCdST09NX1BMQVlFUlMnLCBST09NX0xJTUlUUy5wbGF5ZXJzKSkpLAogICAgLy8gMzMgMS8z
IG1zOiAzMCBiZWF0cyBwZXIgc2Vjb25kLCB0d28gcmVmcmVzaGVzIG9mIGEgNjAgSHogZGlzcGxh
eSBlYWNoICh3aG9sZSB0aGlyZHMgb2YgYSBtcyBvbmx5KS4KICAgIHRpY2tNczogTWF0aC5tYXgo
MSwgTWF0aC5yb3VuZChudW1iZXIoJ1RJQ0tfTVMnLCAxMDAgLyAzKSAqIDMpIC8gMyksCiAgICBs
b2JieVdhaXRNczogbnVtYmVyKCdMT0JCWV9XQUlUX01TJywgMTgwMDAwMCksCiAgICBzdGFydEdy
YWNlTXM6IG51bWJlcignU1RBUlRfR1JBQ0VfTVMnLCA1MDAwKSwKICAgIHJlcGVhdExpbWl0OiBu
dW1iZXIoJ1JFUEVBVF9MSU1JVCcsIDE1KSwKICAgIC8vIFRoZSBMRjIgaW5zdGFsbGVyIHNlcnZl
ZCBhdCAvbGYyLWluc3RhbGxlci5kYXRhIChlbXB0eTogbm90IHNlcnZlZCksIGFuZCBob3cgb2Z0
ZW4gb25lIGNsaWVudAogICAgLy8gYWRkcmVzcyBtYXkgZG93bmxvYWQgaXQgKGFib3V0IDMwIE1C
IGVhY2ggdGltZTsgYnJvd3NlcnMga2VlcCBpdCBhZnRlciB0aGUgZmlyc3QgdGltZSkuCiAgICBp
bnN0YWxsZXJGaWxlOiBlbnYuSU5TVEFMTEVSX0ZJTEUgfHwgJycsCiAgICBpbnN0YWxsZXJEb3du
bG9hZHNQZXJIb3VyOiBudW1iZXIoJ0lOU1RBTExFUl9ET1dOTE9BRFNfUEVSX0hPVVInLCAyMCks
IC8vIDAgPSB1bmxpbWl0ZWQKICAgIC8vIEdhbWUgcGFja3MgKHBhY2tzLmpzKTogd2hlcmUgdGhl
eSBhcmUga2VwdCAoZW1wdHk6IG5vbmUpLCB0aGUga2V5IGZvciB1cGxvYWRpbmcgdGhlbSBhdCAv
YWRtaW4KICAgIC8vIChlbXB0eTogbm8gdXBsb2FkcyksIHRoZWlyIGxhcmdlc3Qgc2l6ZSwgYW5k
IGhvdyBvZnRlbiBvbmUgY2xpZW50IGFkZHJlc3MgbWF5IGRvd25sb2FkIG9uZS4KICAgIHBhY2tz
RGlyOiBlbnYuUEFDS1NfRElSIHx8ICcnLAogICAgYWRtaW5LZXk6IGVudi5BRE1JTl9LRVkgfHwg
JycsCiAgICBtYXhQYWNrQnl0ZXM6IG51bWJlcignTUFYX1BBQ0tfQllURVMnLCAxMDI0ICogMTAy
NCAqIDEwMjQpLAogICAgcGFja0Rvd25sb2Fkc1BlckhvdXI6IG51bWJlcignUEFDS19ET1dOTE9B
RFNfUEVSX0hPVVInLCAyMCksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIC8vIEhlcm8gRmlnaHRlciAo
aGYuanMpOiBob3cgbWFueSByb29tcywgdGhlaXIgZGVzY3JpcHRpb24gaW4gdGhlIGdhbWUncyBy
b29tIGxpc3QsIGFuZCB3aGVyZSB0aGUKICAgIC8vIGFjY291bnRzIGFyZSBrZXB0IChlbXB0eTog
aW4gPFBBQ0tTX0RJUj4vaGYsIG9yIG9ubHkgaW4gbWVtb3J5IHdpdGhvdXQgUEFDS1NfRElSKS4K
ICAgIGhmUm9vbXM6IG51bWJlcignSEZfUk9PTVMnLCA0KSwKICAgIGhmUm9vbURlc2NyaXB0aW9u
OiBlbnYuSEZfUk9PTV9ERVNDUklQVElPTiB8fCAnT3BlbkxGMiByZWxheScsCiAgICBoZkRpcjog
ZW52LkhGX0RJUiB8fCAnJywKICAgIHF1aWV0OiBlbnYuUVVJRVQgPT09ICcxJyB8fCBlbnYuUVVJ
RVQgPT09ICd0cnVlJywKICB9Owp9CgpmdW5jdGlvbiBub3JtYWxpemVPcmlnaW4odmFsdWUpIHsK
ICByZXR1cm4gU3RyaW5nKHZhbHVlIHx8ICcnKS50cmltKCkucmVwbGFjZSgvXC8rJC8sICcnKS50
b0xvd2VyQ2FzZSgpOwp9CgovLyBUb2tlbiBidWNrZXQ6IGByYXRlYCB1bml0cyBwZXIgc2Vjb25k
LCBidXJzdHMgdXAgdG8gYGNhcGFjaXR5YC4gQSByYXRlIG9mIDAgZGlzYWJsZXMgdGhlIGxpbWl0
LgpjbGFzcyBCdWNrZXQgewogIGNvbnN0cnVjdG9yKHJhdGUsIGNhcGFjaXR5KSB7CiAgICB0aGlz
LnJhdGUgPSByYXRlOwogICAgdGhpcy5jYXBhY2l0eSA9IE1hdGgubWF4KGNhcGFjaXR5LCByYXRl
KTsKICAgIHRoaXMudG9rZW5zID0gdGhpcy5jYXBhY2l0eTsKICAgIHRoaXMubGFzdCA9IERhdGUu
bm93KCk7CiAgfQogIHRha2UoYW1vdW50KSB7CiAgICBpZiAodGhpcy5yYXRlID09PSAwKSByZXR1
cm4gdHJ1ZTsKICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgICB0aGlzLnRva2VucyA9IE1h
dGgubWluKHRoaXMuY2FwYWNpdHksIHRoaXMudG9rZW5zICsgKChub3cgLSB0aGlzLmxhc3QpICog
dGhpcy5yYXRlKSAvIDEwMDApOwogICAgdGhpcy5sYXN0ID0gbm93OwogICAgaWYgKHRoaXMudG9r
ZW5zIDwgYW1vdW50KSByZXR1cm4gZmFsc2U7CiAgICB0aGlzLnRva2VucyAtPSBhbW91bnQ7CiAg
ICByZXR1cm4gdHJ1ZTsKICB9Cn0KCmZ1bmN0aW9uIGNyZWF0ZVJlbGF5KG92ZXJyaWRlcyA9IHt9
KSB7CiAgY29uc3QgY29uZmlnID0geyAuLi5yZWFkQ29uZmlnKHt9KSwgLi4ub3ZlcnJpZGVzIH07
CiAgY29uc3Qgcm9vbXMgPSBuZXcgTWFwKCk7IC8vIHByb3RvY29sIDE6IGNvZGUgLT4geyBjb2Rl
LCBob3N0LCBqb2luLCB0aW1lciB9CiAgY29uc3QgZ3JvdXBzID0gbmV3IE1hcCgpOyAvLyBwcm90
b2NvbCAyOiBjb2RlIC0+IHJvb20gKHNlZSAiUm9vbXMiIGJlbG93KQogIGNvbnN0IGNvbm5lY3Rp
b25zUGVySXAgPSBuZXcgTWFwKCk7CiAgY29uc3QgbG9nID0gKC4uLnBhcnRzKSA9PiB7IGlmICgh
Y29uZmlnLnF1aWV0KSBjb25zb2xlLmxvZyhuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCksIC4uLnBh
cnRzKTsgfTsKCiAgY29uc3QgaW5zdGFsbGVyRG93bmxvYWRzID0gbmV3IE1hcCgpOyAvLyBjbGll
bnQgYWRkcmVzcyAtPiB7IGNvdW50LCB1bnRpbCB9CiAgY29uc3QgaW5zdGFsbGVyUGF0aHMgPSBu
ZXcgU2V0KFtJTlNUQUxMRVJfUEFUSCwgY29uZmlnLnBhdGgucmVwbGFjZSgvW14vXSokLywgSU5T
VEFMTEVSX1BBVEguc2xpY2UoMSkpXSk7CiAgLy8gQmVzaWRlIHRoZSBXZWJTb2NrZXQgcGF0aCwg
YXMgdGhlIGluc3RhbGxlciBjb3B5OiAveC9yZWxheSAtPiAveC9sZjItcGFja3MuanNvbiBhbmQg
L3gvYWRtaW4uCiAgY29uc3QgcmVsYXlGb2xkZXIgPSBjb25maWcucGF0aC5yZXBsYWNlKC9bXi9d
KiQvLCAnJyk7CiAgY29uc3QgcGFja3MgPSBjcmVhdGVQYWNrcyhjb25maWcsIHsgbG9nLCBjbGll
bnRBZGRyZXNzOiAocmVxKSA9PiBjbGllbnRBZGRyZXNzKHJlcSksIGFsbG93T3JpZ2luOiAocmVx
KSA9PiBhbGxvd09yaWdpbihyZXEpIH0pOwogIGNvbnN0IGhmID0gY3JlYXRlSGYoY29uZmlnLCB7
CiAgICBsb2csIGNsaWVudEFkZHJlc3M6IChyZXEpID0+IGNsaWVudEFkZHJlc3MocmVxKSwgYWxs
b3dPcmlnaW46IChyZXEpID0+IGFsbG93T3JpZ2luKHJlcSksCiAgICBidWRnZXQ6ICh3cywgYnl0
ZXMpID0+IHdzLm1lc3NhZ2VCdWRnZXQudGFrZSgxKSAmJiB3cy5ieXRlQnVkZ2V0LnRha2UoYnl0
ZXMpLAogIH0pOwoKICBjb25zdCBzZXJ2ZXIgPSBodHRwLmNyZWF0ZVNlcnZlcigocmVxLCByZXMp
ID0+IHsKICAgIGNvbnN0IHsgcGF0aG5hbWUgfSA9IG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9y
ZWxheS5pbnZhbGlkJyk7CiAgICBpZiAocGF0aG5hbWUgPT09ICcvaGVhbHRoeicpIHsKICAgICAg
Ly8gUmVhZGFibGUgZnJvbSB0aGUgZ2FtZSBwYWdlIChhbm90aGVyIG9yaWdpbikgc28gaXRzIE9u
bGluZSBwYW5lbCBjYW4gc2hvdyAicmVsYXkgT0siLgogICAgICByZXMud3JpdGVIZWFkKDIwMCwg
ewogICAgICAgICdjb250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vanNvbicsCiAgICAgICAgJ2Nh
Y2hlLWNvbnRyb2wnOiAnbm8tc3RvcmUnLAogICAgICAgICdhY2Nlc3MtY29udHJvbC1hbGxvdy1v
cmlnaW4nOiAnKicsCiAgICAgIH0pOwogICAgICByZXMuZW5kKEpTT04uc3RyaW5naWZ5KHsKICAg
ICAgICBvazogdHJ1ZSwgcm9vbXM6IHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSwgY2xpZW50czog
d3NzLmNsaWVudHMuc2l6ZSwgaW5zdGFsbGVyOiBpbnN0YWxsZXJTaXplKCkgPiAwLAogICAgICAg
IHByb3RvY29sczogWzEsIDJdLCBwbGF5ZXJzOiBjb25maWcucm9vbVBsYXllcnMsIHBhY2tzOiBC
b29sZWFuKGNvbmZpZy5wYWNrc0RpciksIGhmOiBoZi5kZXNjcmliZSgpLAogICAgICB9KSk7CiAg
ICAgIHJldHVybjsKICAgIH0KICAgIGlmIChpbnN0YWxsZXJQYXRocy5oYXMocGF0aG5hbWUpKSB7
CiAgICAgIHNlcnZlSW5zdGFsbGVyKHJlcSwgcmVzKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
Y29uc3QgbG9jYWwgPSByZWxheUZvbGRlciAhPT0gJy8nICYmIHBhdGhuYW1lLnN0YXJ0c1dpdGgo
cmVsYXlGb2xkZXIpID8gcGF0aG5hbWUuc2xpY2UocmVsYXlGb2xkZXIubGVuZ3RoIC0gMSkgOiBw
YXRobmFtZTsKICAgIGlmIChwYWNrcy5oYW5kbGUocmVxLCByZXMsIGxvY2FsKSkgcmV0dXJuOwog
ICAgaWYgKGhmLmhhbmRsZShyZXEsIHJlcywgbG9jYWwpKSByZXR1cm47CiAgICBpZiAocGF0aG5h
bWUgPT09ICcvJyB8fCBwYXRobmFtZSA9PT0gY29uZmlnLnBhdGgpIHsKICAgICAgcmVzLndyaXRl
SGVhZCgyMDAsIHsgJ2NvbnRlbnQtdHlwZSc6ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JyB9
KTsKICAgICAgcmVzLmVuZChgT3BlbkxGMiByZWxheSBpcyBydW5uaW5nLiBDb25uZWN0IHdpdGgg
YSBXZWJTb2NrZXQgdG8gJHtjb25maWcucGF0aH1cbmApOwogICAgICByZXR1cm47CiAgICB9CiAg
ICByZXMud3JpdGVIZWFkKDQwNCwgeyAnY29udGVudC10eXBlJzogJ3RleHQvcGxhaW47IGNoYXJz
ZXQ9dXRmLTgnIH0pOwogICAgcmVzLmVuZCgnTm90IGZvdW5kXG4nKTsKICB9KTsKCiAgLy8gVXBs
b2FkaW5nIGEgZ2FtZSBwYWNrIGZyb20gYSBzbG93IGxpbmUgbWF5IHRha2UgYSB3aGlsZSAoTm9k
ZSdzIGRlZmF1bHQgZ2l2ZXMgdXAgYWZ0ZXIgNSBtaW51dGVzKS4KICBzZXJ2ZXIucmVxdWVzdFRp
bWVvdXQgPSAyICogMzYwMCAqIDEwMDA7CgogIGNvbnN0IHdzcyA9IG5ldyBXZWJTb2NrZXRTZXJ2
ZXIoewogICAgbm9TZXJ2ZXI6IHRydWUsCiAgICBtYXhQYXlsb2FkOiBjb25maWcubWF4TWVzc2Fn
ZUJ5dGVzLAogICAgcGVyTWVzc2FnZURlZmxhdGU6IGZhbHNlLCAvLyAyMi1ieXRlIHBhY2tldHM6
IGNvbXByZXNzaW9uIG9ubHkgYWRkcyBsYXRlbmN5CiAgfSk7CgogIHNlcnZlci5vbigndXBncmFk
ZScsIChyZXEsIHNvY2tldCwgaGVhZCkgPT4gewogICAgY29uc3QgdXJsID0gbmV3IFVSTChyZXEu
dXJsLCAnaHR0cDovL3JlbGF5LmludmFsaWQnKTsKICAgIGlmICh1cmwucGF0aG5hbWUgIT09IGNv
bmZpZy5wYXRoICYmIHVybC5wYXRobmFtZSAhPT0gJy8nKSB7CiAgICAgIHNvY2tldC5lbmQoJ0hU
VFAvMS4xIDQwNCBOb3QgRm91bmRcclxuQ29ubmVjdGlvbjogY2xvc2VcclxuXHJcbicpOwogICAg
ICByZXR1cm47CiAgICB9CiAgICAvLyBSZXF1ZXN0cyBhcmUgdmFsaWRhdGVkIGFmdGVyIHRoZSB1
cGdyYWRlLCBzbyB0aGUgYnJvd3NlciByZWNlaXZlcyBhIGNsb3NlIGNvZGUgYW5kIHJlYXNvbgog
ICAgLy8gaW5zdGVhZCBvZiBhbiBhbm9ueW1vdXMgY29ubmVjdGlvbiBlcnJvci4KICAgIHdzcy5o
YW5kbGVVcGdyYWRlKHJlcSwgc29ja2V0LCBoZWFkLCAod3MpID0+IHdzcy5lbWl0KCdjb25uZWN0
aW9uJywgd3MsIHJlcSwgdXJsKSk7CiAgfSk7CgogIHdzcy5vbignY29ubmVjdGlvbicsICh3cywg
cmVxLCB1cmwpID0+IHsKICAgIHdzLmlzQWxpdmUgPSB0cnVlOwogICAgd3Mub24oJ3BvbmcnLCAo
KSA9PiB7IHdzLmlzQWxpdmUgPSB0cnVlOyB9KTsKICAgIHdzLm9uKCdlcnJvcicsICgpID0+IHt9
KTsgLy8gYSAnY2xvc2UnIGV2ZW50IGFsd2F5cyBmb2xsb3dzCgogICAgaWYgKGNvbmZpZy5hbGxv
d2VkT3JpZ2lucy5sZW5ndGggJiYgIWNvbmZpZy5hbGxvd2VkT3JpZ2lucy5pbmNsdWRlcyhub3Jt
YWxpemVPcmlnaW4ocmVxLmhlYWRlcnMub3JpZ2luKSkpIHsKICAgICAgcmV0dXJuIGNsb3NlV2l0
aCh3cywgQ0xPU0Uub3JpZ2luRGVuaWVkKTsKICAgIH0KICAgIGNvbnN0IHJvbGUgPSB1cmwuc2Vh
cmNoUGFyYW1zLmdldCgncm9sZScpOwogICAgY29uc3QgY29kZSA9IHVybC5zZWFyY2hQYXJhbXMu
Z2V0KCdyb29tJykgfHwgJyc7CiAgICBjb25zdCBoZXJvRmlnaHRlciA9IHVybC5zZWFyY2hQYXJh
bXMuZ2V0KCdnYW1lJykgPT09ICdoZic7IC8vIGEgSGVybyBGaWdodGVyIHJvb20gKGhmLmpzKQog
ICAgaWYgKCFoZXJvRmlnaHRlciAmJiAoKHJvbGUgIT09ICdob3N0JyAmJiByb2xlICE9PSAnam9p
bicpIHx8ICFST09NX1BBVFRFUk4udGVzdChjb2RlKSkpIHsKICAgICAgcmV0dXJuIGNsb3NlV2l0
aCh3cywgQ0xPU0UuYmFkUmVxdWVzdCk7CiAgICB9CgogICAgY29uc3QgYWRkcmVzcyA9IGNsaWVu
dEFkZHJlc3MocmVxKTsKICAgIGNvbnN0IGNvdW50ID0gY29ubmVjdGlvbnNQZXJJcC5nZXQoYWRk
cmVzcykgfHwgMDsKICAgIGlmIChjb25maWcubWF4Q29ubmVjdGlvbnNQZXJJcCAmJiBjb3VudCA+
PSBjb25maWcubWF4Q29ubmVjdGlvbnNQZXJJcCkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdz
LCBDTE9TRS50b29NYW55Q29ubmVjdGlvbnMpOwogICAgfQogICAgY29ubmVjdGlvbnNQZXJJcC5z
ZXQoYWRkcmVzcywgY291bnQgKyAxKTsKICAgIHdzLm9uY2UoJ2Nsb3NlJywgKCkgPT4gewogICAg
ICBjb25zdCBsZWZ0ID0gKGNvbm5lY3Rpb25zUGVySXAuZ2V0KGFkZHJlc3MpIHx8IDEpIC0gMTsK
ICAgICAgaWYgKGxlZnQgPiAwKSBjb25uZWN0aW9uc1BlcklwLnNldChhZGRyZXNzLCBsZWZ0KTsK
ICAgICAgZWxzZSBjb25uZWN0aW9uc1BlcklwLmRlbGV0ZShhZGRyZXNzKTsKICAgIH0pOwogICAg
d3MubWVzc2FnZUJ1ZGdldCA9IG5ldyBCdWNrZXQoY29uZmlnLm1lc3NhZ2VzUGVyU2Vjb25kLCBj
b25maWcubWVzc2FnZXNQZXJTZWNvbmQgKiAyKTsKICAgIHdzLmJ5dGVCdWRnZXQgPSBuZXcgQnVj
a2V0KGNvbmZpZy5ieXRlc1BlclNlY29uZCwgTWF0aC5tYXgoY29uZmlnLmJ5dGVzUGVyU2Vjb25k
LCBjb25maWcubWF4TWVzc2FnZUJ5dGVzKSAqIDIpOwogICAgaWYgKGhlcm9GaWdodGVyKSByZXR1
cm4gaGYuY29ubmVjdCh3cywgcmVxLCB1cmwpOwoKICAgIGNvbnN0IHZlcnNpb24gPSB1cmwuc2Vh
cmNoUGFyYW1zLmdldCgndicpOwogICAgaWYgKHZlcnNpb24gPT09ICcyJykgcmV0dXJuIGpvaW5H
cm91cCh3cywgcm9sZSwgY29kZSk7CiAgICBpZiAodmVyc2lvbiAhPT0gbnVsbCAmJiB2ZXJzaW9u
ICE9PSAnMScpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLmJhZFJlcXVlc3QpOwogICAgaWYg
KGdyb3Vwcy5oYXMoY29kZSkpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLm5ld2VyUm9vbSk7
CgogICAgbGV0IHJvb20gPSByb29tcy5nZXQoY29kZSk7CiAgICBpZiAoIXJvb20pIHsKICAgICAg
aWYgKGNvbmZpZy5tYXhSb29tcyAmJiByb29tcy5zaXplICsgZ3JvdXBzLnNpemUgPj0gY29uZmln
Lm1heFJvb21zKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5zZXJ2ZXJGdWxsKTsKICAgICAg
cm9vbSA9IHsgY29kZSwgaG9zdDogbnVsbCwgam9pbjogbnVsbCwgdGltZXI6IG51bGwgfTsKICAg
ICAgcm9vbXMuc2V0KGNvZGUsIHJvb20pOwogICAgfQogICAgaWYgKHJvb21bcm9sZV0pIHJldHVy
biBjbG9zZVdpdGgod3MsIHJvbGUgPT09ICdob3N0JyA/IENMT1NFLmhvc3RUYWtlbiA6IENMT1NF
Lmd1ZXN0VGFrZW4pOwoKICAgIHJvb21bcm9sZV0gPSB3czsKICAgIHdzLnJvb20gPSByb29tOwog
ICAgd3Mucm9sZSA9IHJvbGU7CiAgICB3cy5wZWVyID0gbnVsbDsKICAgIHdzLm9uKCdtZXNzYWdl
JywgKGRhdGEsIGlzQmluYXJ5KSA9PiBvbk1lc3NhZ2Uod3MsIGRhdGEsIGlzQmluYXJ5KSk7CiAg
ICB3cy5vbignY2xvc2UnLCAoKSA9PiBvbkNsb3NlKHdzKSk7CgogICAgY29uc3Qgb3RoZXIgPSBy
b29tW3JvbGUgPT09ICdob3N0JyA/ICdqb2luJyA6ICdob3N0J107CiAgICBpZiAob3RoZXIpIHsK
ICAgICAgY2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICByb29tLnRpbWVyID0gbnVsbDsK
ICAgICAgd3MucGVlciA9IG90aGVyOwogICAgICBvdGhlci5wZWVyID0gd3M7CiAgICAgIC8vIEJv
dGggcGVlcnMgYXJlIGxpbmtlZCBiZWZvcmUgZWl0aGVyIGxlYXJucyBhYm91dCBpdCwgc28gYW55
IGRhdGEgdGhhdCBmb2xsb3dzIGhhcyBhIGRlc3RpbmF0aW9uLgogICAgICBzZW5kQ29udHJvbChv
dGhlciwgeyB0OiAncGFpcmVkJyB9KTsKICAgICAgc2VuZENvbnRyb2wod3MsIHsgdDogJ3BhaXJl
ZCcgfSk7CiAgICAgIGxvZyhgcm9vbSAke2NvZGV9OiBwYWlyZWRgKTsKICAgIH0gZWxzZSB7CiAg
ICAgIHNlbmRDb250cm9sKHdzLCB7IHQ6ICd3YWl0aW5nJywgcm9vbTogY29kZSB9KTsKICAgICAg
cm9vbS50aW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgIGlmIChyb29tW3JvbGVdID09
PSB3cyAmJiAhd3MucGVlcikgY2xvc2VXaXRoKHdzLCBDTE9TRS50aW1lb3V0KTsKICAgICAgfSwg
Y29uZmlnLnJvb21XYWl0TXMpOwogICAgICBsb2coYHJvb20gJHtjb2RlfTogJHtyb2xlfSB3YWl0
aW5nYCk7CiAgICB9CiAgfSk7CgogIGZ1bmN0aW9uIG9uTWVzc2FnZSh3cywgZGF0YSwgaXNCaW5h
cnkpIHsKICAgIGlmICghaXNCaW5hcnkpIHJldHVybjsgLy8gb25seSB0aGUgcmVsYXkgc3BlYWtz
IHRleHQ7IGNsaWVudHMgc2VuZCBnYW1lIGJ5dGVzIGFzIGJpbmFyeSBmcmFtZXMKICAgIGlmICgh
d3MucGVlcikgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuZWFybHlEYXRhKTsKICAgIGlmICgh
d3MubWVzc2FnZUJ1ZGdldC50YWtlKDEpIHx8ICF3cy5ieXRlQnVkZ2V0LnRha2UoZGF0YS5sZW5n
dGgpKSB7CiAgICAgIGxvZyhgcm9vbSAke3dzLnJvb20uY29kZX06IHJhdGUgbGltaXRgKTsKICAg
ICAgY2xvc2VXaXRoKHdzLnBlZXIsIENMT1NFLnJhdGVMaW1pdGVkKTsKICAgICAgcmV0dXJuIGNs
b3NlV2l0aCh3cywgQ0xPU0UucmF0ZUxpbWl0ZWQpOwogICAgfQogICAgY29uc3QgcGVlciA9IHdz
LnBlZXI7CiAgICBpZiAocGVlci5yZWFkeVN0YXRlICE9PSBXZWJTb2NrZXQuT1BFTikgcmV0dXJu
OwogICAgaWYgKHBlZXIuYnVmZmVyZWRBbW91bnQgPiBjb25maWcubWF4QnVmZmVyZWRCeXRlcykg
ewogICAgICBjbG9zZVdpdGgod3MsIENMT1NFLnNsb3dQZWVyKTsKICAgICAgcmV0dXJuIGNsb3Nl
V2l0aChwZWVyLCBDTE9TRS5zbG93UGVlcik7CiAgICB9CiAgICBpZiAoY29uZmlnLmZvcndhcmRE
ZWxheU1zID4gMCkgewogICAgICAvLyBUaW1lcnMgd2l0aCB0aGUgc2FtZSBkZWxheSBmaXJlIGlu
IHRoZSBvcmRlciB0aGV5IHdlcmUgc2V0LCBzbyB0aGUgc3RyZWFtIHN0YXlzIGluIG9yZGVyLgog
ICAgICBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKHBlZXIucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0
Lk9QRU4pIHBlZXIuc2VuZChkYXRhLCB7IGJpbmFyeTogdHJ1ZSB9KTsgfSwgY29uZmlnLmZvcndh
cmREZWxheU1zKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgcGVlci5zZW5kKGRhdGEsIHsgYmlu
YXJ5OiB0cnVlIH0pOwogIH0KCiAgZnVuY3Rpb24gb25DbG9zZSh3cykgewogICAgY29uc3Qgcm9v
bSA9IHdzLnJvb207CiAgICBpZiAoIXJvb20pIHJldHVybjsKICAgIGlmIChyb29tW3dzLnJvbGVd
ID09PSB3cykgcm9vbVt3cy5yb2xlXSA9IG51bGw7CiAgICBjb25zdCBwZWVyID0gd3MucGVlcjsK
ICAgIHdzLnBlZXIgPSBudWxsOwogICAgaWYgKHBlZXIpIHsKICAgICAgLy8gQSBsb2Nrc3RlcCBt
YXRjaCBjYW5ub3QgY29udGludWUgd2l0aCBvbmUgcGxheWVyLCBzbyB0aGUgcm9vbSBlbmRzIHdp
dGggdGhlIHBhaXIgYW5kIGl0cwogICAgICAvLyBjb2RlIGlzIGZyZWUgYWdhaW4gYXQgb25jZSAo
dGhlIGhvc3QgY2FuIHByZXNzIEhvc3QgYWdhaW4gd2l0aCB0aGUgc2FtZSBjb2RlKS4KICAgICAg
cGVlci5wZWVyID0gbnVsbDsKICAgICAgcm9vbS5ob3N0ID0gcm9vbS5qb2luID0gbnVsbDsKICAg
ICAgY2xvc2VXaXRoKHBlZXIsIENMT1NFLnBlZXJMZWZ0KTsKICAgICAgbG9nKGByb29tICR7cm9v
bS5jb2RlfTogZW5kZWRgKTsKICAgIH0KICAgIGlmICghcm9vbS5ob3N0ICYmICFyb29tLmpvaW4p
IHsKICAgICAgY2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICBpZiAocm9vbXMuZ2V0KHJv
b20uY29kZSkgPT09IHJvb20pIHJvb21zLmRlbGV0ZShyb29tLmNvZGUpOwogICAgfQogIH0KCiAg
Ly8gLS0tLSBSb29tcyAocHJvdG9jb2wgMikgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAvLwogIC8vIFVwIHRv
IGNvbmZpZy5yb29tUGxheWVycyBnYW1lcyBzaGFyZSBhIHJvb20uIEVhY2ggc2F5cyBIRUxMTyB3
aXRoIGl0cyBwcm9maWxlIChlbmdpbmUsIHNjcmlwdHMsCiAgLy8gbW9kcyBhbmQgZ2FtZSBkYXRh
OiB0aGUgZmlyc3QgSEVMTE8gc2V0cyB0aGUgcm9vbSdzLCBhbmQgYSBnYW1lIHdpdGggYW5vdGhl
ciBvbmUgaXMgdHVybmVkIGF3YXkpCiAgLy8gYW5kIGl0cyBwbGF5ZXIgbmFtZXM7IExPQkJZIGxp
c3RzIHRoZSBwbGF5ZXJzIHRvIGV2ZXJ5b25lLiBUaGUgaG9zdCBzZW5kcyBTVEFSVCB3aXRoIHRo
ZSBzZXR1cAogIC8vIGV2ZXJ5IGdhbWUgbmVlZHMgKHRoZSByYW5kb20gdGFibGUpOyBTVEFSVEVE
IGdpdmVzIGV2ZXJ5IGdhbWUgdGhlIGZpbmFsIGxpc3Qgb2YgcGxheWVycywgd2hvc2UKICAvLyBw
b3NpdGlvbiBpcyB0aGUgcGxheWVyJ3MgaW5kZXgsIGFuZCBvbmNlIGV2ZXJ5IGdhbWUgaXMgUkVB
RFkgKG9yIGFmdGVyIHN0YXJ0R3JhY2VNcykgdGhlIGJlYXQKICAvLyBiZWdpbnM6IGV2ZXJ5IHRp
Y2tNcywgRlJBTUUgd2l0aCB0aGUgaW5wdXQgb2YgZWFjaCBwbGF5ZXIuIFRoZSBpbnB1dHMgYSBw
bGF5ZXIgc2VudCBzaW5jZSB0aGUKICAvLyBsYXN0IGJlYXQgYXJlIG1lcmdlZCAoT1I6IGEga2V5
IGhlbGQgaW4gYW55IG9mIHRoZW0gaXMgaGVsZCwgc28gYSBxdWljayB0YXAgaXMgbmV2ZXIgbG9z
dCksIGFuZAogIC8vIHRoZSBuZXdlc3Qgb2YgdGhlbSBzdGF5cyBoaXMgaW5wdXQgb24gdGhlIGZv
bGxvd2luZyBiZWF0cyB3aGlsZSBubyBuZXdzIGNvbWVzLCB3aXRob3V0IGl0cwogIC8vIG9uZS1z
aG90IGV2ZW50cyAoYnl0ZSAwKTsgYWZ0ZXIgcmVwZWF0TGltaXQgYmVhdHMgd2l0aG91dCBuZXdz
IHRoZSBwbGF5ZXIgY291bnRzIGFzIGhhdmluZwogIC8vIHJlbGVhc2VkIGV2ZXJ5IGtleS4gR2Ft
ZXMgc2VuZCB0aGVpciBpbnB1dCBhcyBzb29uIGFzIGl0IGNoYW5nZXMuIEV2ZXJ5IGdhbWUgcnVu
cyBleGFjdGx5IHRoZQogIC8vIGZyYW1lcyBpdCByZWNlaXZlcywgaW4gb3JkZXIsIHNvIGFsbCBz
dGF5IGluIHN0ZXAgd2hhdGV2ZXIgdGhlaXIgb3duIGNvbm5lY3Rpb24gZG9lczogYSBkaXN0YW50
CiAgLy8gcGxheWVyJ3Mga2V5cyB0YWtlIGVmZmVjdCBhIGxpdHRsZSBsYXRlciBhbmQgaGUgc2Vl
cyB0aGUgZ2FtZSBhIGxpdHRsZSBsYXRlciwgYnV0IG5vYm9keSB3YWl0cwogIC8vIGZvciBoaW0u
IEEgZ2FtZSB0aGF0IGNhbm5vdCBrZWVwIHVwIHdpdGggdGhlIGZyYW1lcyBpcyBkcm9wcGVkLCBh
bmQgdGhlIG90aGVycyBnbyBvbi4KICAvLwogIC8vIEJpbmFyeSBtZXNzYWdlcywgYm90aCB3YXlz
OiBraW5kICgxIGJ5dGUpLCBwYXlsb2FkIGxlbmd0aCAoMiBieXRlcywgbGl0dGxlIGVuZGlhbiks
IHBheWxvYWQuCiAgLy8gQSBXZWJTb2NrZXQgbWVzc2FnZSBtYXkgY2Fycnkgc2V2ZXJhbC4gR2Ft
ZSB0byByZWxheToKICAvLyAgIEhFTExPICAgMHgwMSAgcHJvZmlsZSBsZW5ndGggKDEpLCBwcm9m
aWxlLCBpbmZvIChuYW1lczsgYXQgbW9zdCA2NCBieXRlcykKICAvLyAgIFNUQVJUICAgMHgwMiAg
c2V0dXAgKGF0IG1vc3QgOCBLaUIpOiB0aGUgaG9zdCwgb25jZSB0d28gcGxheWVycyBvciBtb3Jl
IHNhaWQgaGVsbG8KICAvLyAgIElOUFVUICAgMHgwMyAgaW5wdXQgKGF0IG1vc3QgMTYgYnl0ZXM7
IGJ5dGUgMCBob2xkcyBvbmUtc2hvdCBldmVudHMpLCBhZnRlciBTVEFSVEVECiAgLy8gICBSRUFE
WSAgIDB4MDQgIGVtcHR5OiBTVEFSVEVEIGlzIGFwcGxpZWQKICAvLyAgIENIRUNLICAgMHgwNSAg
ZnJhbWUgKDQpLCBoYXNoICgyKTogcGFzc2VkIG9uIHRvIHRoZSBvdGhlcnMsIHdoaWNoIGNvbXBh
cmUgaXQgd2l0aCB0aGVpciBvd24KICAvLyBSZWxheSB0byBnYW1lOgogIC8vICAgV0VMQ09NRSAw
eDgxICBpZCAoMSksIGZsYWdzICgxOyBiaXQgMDogaG9zdCksIG1vc3QgcGxheWVycyAoMSksIGJl
YXQgaW4gbXMgKDEpLAogIC8vICAgICAgICAgICAgICAgICByb29tIGNvZGUgbGVuZ3RoICgxKSwg
cm9vbSBjb2RlCiAgLy8gICBMT0JCWSAgIDB4ODIgIGNvdW50ICgxKTsgcGVyIHBsYXllcjogaWQg
KDEpLCBmbGFncyAoMSksIGluZm8gbGVuZ3RoICgxKSwgaW5mbwogIC8vICAgU1RBUlRFRCAweDgz
ICB0aGUgcGxheWVycyBhcyBpbiBMT0JCWSwgdGhlbiBzZXR1cCBsZW5ndGggKDIpLCBzZXR1cAog
IC8vICAgRlJBTUUgICAweDg0ICBmcmFtZSAoNCksIGNvdW50ICgxKSwgZnJlc2ggbWFzayAoMSks
IHByZXNlbnQgbWFzayAoMSk7CiAgLy8gICAgICAgICAgICAgICAgIHBlciBwbGF5ZXI6IGlucHV0
IGxlbmd0aCAoMSksIGlucHV0CiAgLy8gICBDSEVDS0VEIDB4ODUgIGluZGV4ICgxKSwgZnJhbWUg
KDQpLCBoYXNoICgyKQogIC8vICAgTEVGVCAgICAweDg2ICBpbmRleCAoMSk6IHRoYXQgcGxheWVy
IGlzIGdvbmU7IGhpcyBpbnB1dCBzdGF5cyBlbXB0eQogIC8vIFRleHQgKEpTT04pIG1lc3NhZ2Vz
IGFyZSBmb3IgdGhlIHBhZ2UgYXJvdW5kIHRoZSBnYW1lOiB7InQiOiJ3ZWxjb21lIiwidiI6Miwi
cm9vbSI6IuKApiIsImhvc3QiOnRydWV9CiAgLy8gYW5kIHsidCI6InJvb20iLCJwbGF5ZXJzIjoz
LCJzdGFydGVkIjpmYWxzZX0uCgogIGZ1bmN0aW9uIGpvaW5Hcm91cCh3cywgcm9sZSwgY29kZSkg
ewogICAgaWYgKHJvb21zLmhhcyhjb2RlKSkgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuY29k
ZUluVXNlKTsKICAgIGxldCByb29tID0gZ3JvdXBzLmdldChjb2RlKTsKICAgIGlmICghcm9vbSkg
ewogICAgICBpZiAoY29uZmlnLm1heFJvb21zICYmIHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSA+
PSBjb25maWcubWF4Um9vbXMpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnNlcnZlckZ1bGwp
OwogICAgICByb29tID0gewogICAgICAgIGNvZGUsIG1lbWJlcnM6IFtdLCBob3N0OiBudWxsLCBu
ZXh0SWQ6IDEsIHByb2ZpbGU6IG51bGwsIHN0YXJ0ZWQ6IGZhbHNlLCBvcmRlcjogW10sIGZyYW1l
OiAwLAogICAgICAgIHRpY2tpbmc6IGZhbHNlLCB0aWNrczogMCwgdGlja1N0YXJ0OiAwLCBsb2Ji
eVRpbWVyOiBudWxsLCBncmFjZVRpbWVyOiBudWxsLCB0aWNrVGltZXI6IG51bGwsIGVuZGVkOiBm
YWxzZSwKICAgICAgfTsKICAgICAgZ3JvdXBzLnNldChjb2RlLCByb29tKTsKICAgICAgcm9vbS5s
b2JieVRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBlbmRHcm91cChyb29tLCBDTE9TRS5ub3RTdGFy
dGVkKSwgY29uZmlnLmxvYmJ5V2FpdE1zKTsKICAgICAgbG9nKGByb29tICR7Y29kZX06IG9wZW5l
ZGApOwogICAgfQogICAgaWYgKHJvb20uc3RhcnRlZCkgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xP
U0Uuc3RhcnRlZCk7CiAgICBpZiAocm9sZSA9PT0gJ2hvc3QnICYmIHJvb20uaG9zdCkgcmV0dXJu
IGNsb3NlV2l0aCh3cywgQ0xPU0UuaG9zdFRha2VuKTsKICAgIGlmIChyb29tLm1lbWJlcnMubGVu
Z3RoID49IGNvbmZpZy5yb29tUGxheWVycykgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0Uucm9v
bUZ1bGwpOwogICAgd2hpbGUgKHJvb20ubWVtYmVycy5zb21lKChvdGhlcikgPT4gb3RoZXIuaWQg
PT09IHJvb20ubmV4dElkKSkgcm9vbS5uZXh0SWQgPSAocm9vbS5uZXh0SWQgJSAyNTUpICsgMTsK
ICAgIGNvbnN0IG1lbWJlciA9IHsKICAgICAgd3MsIHJvb20sIGlkOiByb29tLm5leHRJZCwgaG9z
dDogcm9sZSA9PT0gJ2hvc3QnLCBpbmZvOiBudWxsLCByZWFkeTogZmFsc2UsCiAgICAgIHF1ZXVl
OiBbXSwgbGFzdDogRU1QVFksIHJlcGVhdHM6IDAsIHByZXNlbnQ6IHRydWUsIGluZGV4OiAtMSwK
ICAgIH07CiAgICByb29tLm5leHRJZCA9IChyb29tLm5leHRJZCAlIDI1NSkgKyAxOwogICAgcm9v
bS5tZW1iZXJzLnB1c2gobWVtYmVyKTsKICAgIGlmIChtZW1iZXIuaG9zdCkgcm9vbS5ob3N0ID0g
bWVtYmVyOwogICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSwgaXNCaW5hcnkpID0+IG9uR3JvdXBN
ZXNzYWdlKG1lbWJlciwgZGF0YSwgaXNCaW5hcnkpKTsKICAgIHdzLm9uKCdjbG9zZScsICgpID0+
IGxlYXZlR3JvdXAobWVtYmVyKSk7CiAgICBzZW5kQ29udHJvbCh3cywgeyB0OiAnd2VsY29tZScs
IHY6IDIsIHJvb206IGNvZGUsIGhvc3Q6IG1lbWJlci5ob3N0IH0pOwogICAgY29uc3Qgd2VsY29t
ZSA9IEJ1ZmZlci5hbGxvYyg1ICsgY29kZS5sZW5ndGgpOwogICAgd2VsY29tZVswXSA9IG1lbWJl
ci5pZDsKICAgIC8vIEZsYWdzOiBiaXQgMCB0aGUgaG9zdDsgYml0cyAxLTIgdGhlIGJlYXQncyB0
aGlyZHMgb2YgYSBtaWxsaXNlY29uZCBiZXlvbmQgd2VsY29tZVszXS4KICAgIGNvbnN0IHRoaXJk
cyA9IE1hdGgucm91bmQoY29uZmlnLnRpY2tNcyAqIDMpOwogICAgd2VsY29tZVsxXSA9IChtZW1i
ZXIuaG9zdCA/IDEgOiAwKSB8ICgodGhpcmRzICUgMykgPDwgMSk7CiAgICB3ZWxjb21lWzJdID0g
Y29uZmlnLnJvb21QbGF5ZXJzOwogICAgd2VsY29tZVszXSA9IE1hdGgubWluKDI1NSwgTWF0aC5m
bG9vcih0aGlyZHMgLyAzKSk7CiAgICB3ZWxjb21lWzRdID0gY29kZS5sZW5ndGg7CiAgICB3ZWxj
b21lLndyaXRlKGNvZGUsIDUsICdsYXRpbjEnKTsKICAgIHNlbmRCaW5hcnkod3MsIHBhY2tldChL
SU5ELndlbGNvbWUsIHdlbGNvbWUpKTsKICAgIHNlbmRMb2JieShyb29tLCBtZW1iZXIpOwogICAg
bG9nKGByb29tICR7Y29kZX06ICR7cm9sZX0gYXJyaXZlZCAoJHtyb29tLm1lbWJlcnMubGVuZ3Ro
fSBpbiB0aGUgcm9vbSlgKTsKICB9CgogIC8vIFRoZSBwbGF5ZXJzIHdobyBzYWlkIGhlbGxvLCB0
aGUgaG9zdCBmaXJzdCwgdGhlbiBpbiB0aGUgb3JkZXIgdGhleSBjYW1lLgogIGZ1bmN0aW9uIGxp
c3RlZChyb29tKSB7CiAgICBjb25zdCBrbm93biA9IHJvb20ubWVtYmVycy5maWx0ZXIoKG1lbWJl
cikgPT4gbWVtYmVyLmluZm8pOwogICAgcmV0dXJuIGtub3duLmZpbHRlcigobWVtYmVyKSA9PiBt
ZW1iZXIuaG9zdCkuY29uY2F0KGtub3duLmZpbHRlcigobWVtYmVyKSA9PiAhbWVtYmVyLmhvc3Qp
KTsKICB9CgogIGZ1bmN0aW9uIGRlc2NyaWJlUGxheWVycyhsaXN0KSB7CiAgICBjb25zdCBwYXJ0
cyA9IFtCdWZmZXIuZnJvbShbbGlzdC5sZW5ndGhdKV07CiAgICBmb3IgKGNvbnN0IG1lbWJlciBv
ZiBsaXN0KSBwYXJ0cy5wdXNoKEJ1ZmZlci5mcm9tKFttZW1iZXIuaWQsIG1lbWJlci5ob3N0ID8g
MSA6IDAsIG1lbWJlci5pbmZvLmxlbmd0aF0pLCBtZW1iZXIuaW5mbyk7CiAgICByZXR1cm4gQnVm
ZmVyLmNvbmNhdChwYXJ0cyk7CiAgfQoKICBmdW5jdGlvbiBzZW5kTG9iYnkocm9vbSwgb25seSkg
ewogICAgY29uc3QgbGlzdCA9IGxpc3RlZChyb29tKTsKICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNr
ZXQoS0lORC5sb2JieSwgZGVzY3JpYmVQbGF5ZXJzKGxpc3QpKTsKICAgIGZvciAoY29uc3QgbWVt
YmVyIG9mIG9ubHkgPyBbb25seV0gOiByb29tLm1lbWJlcnMpIHsKICAgICAgc2VuZEJpbmFyeSht
ZW1iZXIud3MsIG1lc3NhZ2UpOwogICAgICBzZW5kQ29udHJvbChtZW1iZXIud3MsIHsgdDogJ3Jv
b20nLCBwbGF5ZXJzOiBsaXN0Lmxlbmd0aCwgc3RhcnRlZDogZmFsc2UgfSk7CiAgICB9CiAgfQoK
ICBmdW5jdGlvbiBvbkdyb3VwTWVzc2FnZShtZW1iZXIsIGRhdGEsIGlzQmluYXJ5KSB7CiAgICBj
b25zdCB7IHdzLCByb29tIH0gPSBtZW1iZXI7CiAgICBpZiAoIWlzQmluYXJ5IHx8IHJvb20uZW5k
ZWQgfHwgIXJvb20ubWVtYmVycy5pbmNsdWRlcyhtZW1iZXIpKSByZXR1cm47CiAgICBpZiAoIXdz
Lm1lc3NhZ2VCdWRnZXQudGFrZSgxKSB8fCAhd3MuYnl0ZUJ1ZGdldC50YWtlKGRhdGEubGVuZ3Ro
KSkgewogICAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiByYXRlIGxpbWl0YCk7CiAgICAgIHJl
dHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnJhdGVMaW1pdGVkKTsKICAgIH0KICAgIGxldCBhdCA9
IDA7CiAgICB3aGlsZSAoYXQgPCBkYXRhLmxlbmd0aCkgewogICAgICBpZiAoZGF0YS5sZW5ndGgg
LSBhdCA8IDMpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnByb3RvY29sKTsKICAgICAgY29u
c3Qga2luZCA9IGRhdGFbYXRdOwogICAgICBjb25zdCBsZW5ndGggPSBkYXRhLnJlYWRVSW50MTZM
RShhdCArIDEpOwogICAgICBpZiAoZGF0YS5sZW5ndGggLSBhdCAtIDMgPCBsZW5ndGgpIHJldHVy
biBjbG9zZVdpdGgod3MsIENMT1NFLnByb3RvY29sKTsKICAgICAgY29uc3QgcHJvYmxlbSA9IGhh
bmRsZUdyb3VwTWVzc2FnZShtZW1iZXIsIGtpbmQsIGRhdGEuc3ViYXJyYXkoYXQgKyAzLCBhdCAr
IDMgKyBsZW5ndGgpKTsKICAgICAgaWYgKHByb2JsZW0pIHJldHVybiBjbG9zZVdpdGgod3MsIHBy
b2JsZW0pOwogICAgICBpZiAocm9vbS5lbmRlZCB8fCAhcm9vbS5tZW1iZXJzLmluY2x1ZGVzKG1l
bWJlcikpIHJldHVybjsKICAgICAgYXQgKz0gMyArIGxlbmd0aDsKICAgIH0KICB9CgogIC8vIFJl
dHVybnMgdGhlIGNsb3NlIGNvZGUgYW5kIHJlYXNvbiBmb3IgYSBtZXNzYWdlIHRoZSBnYW1lIHNo
b3VsZCBub3QgaGF2ZSBzZW50LgogIGZ1bmN0aW9uIGhhbmRsZUdyb3VwTWVzc2FnZShtZW1iZXIs
IGtpbmQsIHBheWxvYWQpIHsKICAgIGNvbnN0IHJvb20gPSBtZW1iZXIucm9vbTsKICAgIGlmIChr
aW5kID09PSBLSU5ELmhlbGxvKSB7CiAgICAgIGlmIChtZW1iZXIuaW5mbyB8fCByb29tLnN0YXJ0
ZWQgfHwgcGF5bG9hZC5sZW5ndGggPCAxKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIGNv
bnN0IGxlbmd0aCA9IHBheWxvYWRbMF07CiAgICAgIGlmICghbGVuZ3RoIHx8IGxlbmd0aCA+IFJP
T01fTElNSVRTLnByb2ZpbGUgfHwgcGF5bG9hZC5sZW5ndGggPCAxICsgbGVuZ3RoKSByZXR1cm4g
Q0xPU0UucHJvdG9jb2w7CiAgICAgIGNvbnN0IHByb2ZpbGUgPSBCdWZmZXIuZnJvbShwYXlsb2Fk
LnN1YmFycmF5KDEsIDEgKyBsZW5ndGgpKTsKICAgICAgY29uc3QgaW5mbyA9IEJ1ZmZlci5mcm9t
KHBheWxvYWQuc3ViYXJyYXkoMSArIGxlbmd0aCkpOwogICAgICBpZiAoaW5mby5sZW5ndGggPiBS
T09NX0xJTUlUUy5pbmZvKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIGlmIChyb29tLnBy
b2ZpbGUgJiYgIXJvb20ucHJvZmlsZS5lcXVhbHMocHJvZmlsZSkpIHJldHVybiBDTE9TRS5taXNt
YXRjaDsKICAgICAgcm9vbS5wcm9maWxlID0gcm9vbS5wcm9maWxlIHx8IHByb2ZpbGU7CiAgICAg
IG1lbWJlci5pbmZvID0gaW5mbzsKICAgICAgc2VuZExvYmJ5KHJvb20pOwogICAgICByZXR1cm4g
bnVsbDsKICAgIH0KICAgIGlmIChraW5kID09PSBLSU5ELnN0YXJ0KSB7CiAgICAgIGlmICghbWVt
YmVyLmhvc3QgfHwgIW1lbWJlci5pbmZvIHx8IHJvb20uc3RhcnRlZCB8fCBwYXlsb2FkLmxlbmd0
aCA+IFJPT01fTElNSVRTLnNldHVwKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIC8vIFNv
bWVib2R5IGxlZnQganVzdCBiZWZvcmU6IHRoZSBob3N0IHNlZXMgdGhlIGxpc3QgYWdhaW4gaW5z
dGVhZC4KICAgICAgaWYgKGxpc3RlZChyb29tKS5sZW5ndGggPCAyKSBzZW5kTG9iYnkocm9vbSwg
bWVtYmVyKTsKICAgICAgZWxzZSBzdGFydEdyb3VwKHJvb20sIEJ1ZmZlci5mcm9tKHBheWxvYWQp
KTsKICAgICAgcmV0dXJuIG51bGw7CiAgICB9CiAgICBpZiAoa2luZCA9PT0gS0lORC5pbnB1dCkg
ewogICAgICBpZiAoIXJvb20uc3RhcnRlZCB8fCBtZW1iZXIuaW5kZXggPCAwIHx8IHBheWxvYWQu
bGVuZ3RoID4gUk9PTV9MSU1JVFMuaW5wdXQpIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAg
bWVtYmVyLnF1ZXVlLnB1c2goQnVmZmVyLmZyb20ocGF5bG9hZCkpOwogICAgICAvLyBGYXIgbW9y
ZSB0aGFuIGEgYmVhdCdzIHdvcnRoICh0aGUgcmF0ZSBsaW1pdCBhbGxvd3MgYnVyc3RzKTogZm9s
ZCB0aGVtLCBrZWVwaW5nIHRoZSBuZXdlc3QgbGFzdC4KICAgICAgaWYgKG1lbWJlci5xdWV1ZS5s
ZW5ndGggPiBST09NX0xJTUlUUy5xdWV1ZSkgbWVtYmVyLnF1ZXVlID0gW21lcmdlSW5wdXRzKG1l
bWJlci5xdWV1ZS5zbGljZSgwLCAtMSkpLCBtZW1iZXIucXVldWUuYXQoLTEpXTsKICAgICAgcmV0
dXJuIG51bGw7CiAgICB9CiAgICBpZiAoa2luZCA9PT0gS0lORC5yZWFkeSkgewogICAgICBpZiAo
IXJvb20uc3RhcnRlZCB8fCBtZW1iZXIuaW5kZXggPCAwIHx8IHBheWxvYWQubGVuZ3RoKSByZXR1
cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIG1lbWJlci5yZWFkeSA9IHRydWU7CiAgICAgIGlmIChy
b29tLm9yZGVyLmV2ZXJ5KChvdGhlcikgPT4gb3RoZXIucmVhZHkgfHwgIW90aGVyLnByZXNlbnQp
KSBzdGFydEJlYXQocm9vbSk7CiAgICAgIHJldHVybiBudWxsOwogICAgfQogICAgaWYgKGtpbmQg
PT09IEtJTkQuY2hlY2spIHsKICAgICAgaWYgKCFyb29tLnN0YXJ0ZWQgfHwgbWVtYmVyLmluZGV4
IDwgMCB8fCBwYXlsb2FkLmxlbmd0aCAhPT0gNikgcmV0dXJuIENMT1NFLnByb3RvY29sOwogICAg
ICBjb25zdCBtZXNzYWdlID0gcGFja2V0KEtJTkQuY2hlY2tlZCwgQnVmZmVyLmNvbmNhdChbQnVm
ZmVyLmZyb20oW21lbWJlci5pbmRleF0pLCBwYXlsb2FkXSkpOwogICAgICBmb3IgKGNvbnN0IG90
aGVyIG9mIHJvb20ub3JkZXIpIGlmIChvdGhlciAhPT0gbWVtYmVyICYmIG90aGVyLnByZXNlbnQp
IHNlbmRCaW5hcnkob3RoZXIud3MsIG1lc3NhZ2UpOwogICAgICByZXR1cm4gbnVsbDsKICAgIH0K
ICAgIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICB9CgogIGZ1bmN0aW9uIHN0YXJ0R3JvdXAocm9v
bSwgc2V0dXApIHsKICAgIGNsZWFyVGltZW91dChyb29tLmxvYmJ5VGltZXIpOwogICAgcm9vbS5z
dGFydGVkID0gdHJ1ZTsKICAgIHJvb20ub3JkZXIgPSBsaXN0ZWQocm9vbSk7CiAgICByb29tLm9y
ZGVyLmZvckVhY2goKG1lbWJlciwgaW5kZXgpID0+IHsgbWVtYmVyLmluZGV4ID0gaW5kZXg7IH0p
OwogICAgLy8gQSBnYW1lIHN0aWxsIGNvbm5lY3RpbmcgaGFzIG1pc3NlZCB0aGUgc3RhcnQuCiAg
ICBmb3IgKGNvbnN0IG1lbWJlciBvZiByb29tLm1lbWJlcnMpIGlmICghbWVtYmVyLmluZm8pIGNs
b3NlV2l0aChtZW1iZXIud3MsIENMT1NFLnN0YXJ0ZWQpOwogICAgY29uc3QgbGVuZ3RoID0gQnVm
ZmVyLmFsbG9jKDIpOwogICAgbGVuZ3RoLndyaXRlVUludDE2TEUoc2V0dXAubGVuZ3RoLCAwKTsK
ICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lORC5zdGFydGVkLCBCdWZmZXIuY29uY2F0KFtk
ZXNjcmliZVBsYXllcnMocm9vbS5vcmRlciksIGxlbmd0aCwgc2V0dXBdKSk7CiAgICBmb3IgKGNv
bnN0IG1lbWJlciBvZiByb29tLm9yZGVyKSB7CiAgICAgIHNlbmRCaW5hcnkobWVtYmVyLndzLCBt
ZXNzYWdlKTsKICAgICAgc2VuZENvbnRyb2wobWVtYmVyLndzLCB7IHQ6ICdyb29tJywgcGxheWVy
czogcm9vbS5vcmRlci5sZW5ndGgsIHN0YXJ0ZWQ6IHRydWUgfSk7CiAgICB9CiAgICByb29tLmdy
YWNlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHN0YXJ0QmVhdChyb29tKSwgY29uZmlnLnN0YXJ0
R3JhY2VNcyk7CiAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBzdGFydGVkIHdpdGggJHtyb29t
Lm9yZGVyLmxlbmd0aH0gcGxheWVyc2ApOwogIH0KCiAgZnVuY3Rpb24gc3RhcnRCZWF0KHJvb20p
IHsKICAgIGlmIChyb29tLnRpY2tpbmcgfHwgcm9vbS5lbmRlZCkgcmV0dXJuOwogICAgY2xlYXJU
aW1lb3V0KHJvb20uZ3JhY2VUaW1lcik7CiAgICByb29tLnRpY2tpbmcgPSB0cnVlOwogICAgcm9v
bS50aWNrU3RhcnQgPSBwZXJmb3JtYW5jZS5ub3coKTsKICAgIHJvb20udGlja3MgPSAwOwogICAg
c2NoZWR1bGVCZWF0KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gc2NoZWR1bGVCZWF0KHJvb20pIHsK
ICAgIGNvbnN0IGR1ZSA9IHJvb20udGlja1N0YXJ0ICsgKHJvb20udGlja3MgKyAxKSAqIGNvbmZp
Zy50aWNrTXM7CiAgICByb29tLnRpY2tUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gcnVuQmVhdHMo
cm9vbSksIE1hdGgubWF4KDAsIGR1ZSAtIHBlcmZvcm1hbmNlLm5vdygpKSk7CiAgfQoKICAvLyBC
ZWF0cyBhcmUgY291bnRlZCBmcm9tIHRoZSBzdGFydCwgc28gdGltZXIgZGVsYXlzIGRvIG5vdCBh
ZGQgdXA7IGFmdGVyIGEgc3RhbGwgb2YgdGhlIHdob2xlCiAgLy8gcHJvY2VzcyBhIGZldyBtaXNz
ZWQgYmVhdHMgYXJlIHNlbnQgYXQgb25jZSwgYW5kIGEgbG9uZ2VyIG9uZSByZXN0YXJ0cyB0aGUg
Y291bnQuCiAgZnVuY3Rpb24gcnVuQmVhdHMocm9vbSkgewogICAgaWYgKHJvb20uZW5kZWQpIHJl
dHVybjsKICAgIGNvbnN0IG5vdyA9IHBlcmZvcm1hbmNlLm5vdygpOwogICAgY29uc3QgZHVlID0g
TWF0aC5mbG9vcigobm93IC0gcm9vbS50aWNrU3RhcnQpIC8gY29uZmlnLnRpY2tNcykgLSByb29t
LnRpY2tzOwogICAgZm9yIChsZXQgY291bnQgPSAwOyBjb3VudCA8IE1hdGgubWluKGR1ZSwgNCkg
JiYgIXJvb20uZW5kZWQ7IGNvdW50ICs9IDEpIHsKICAgICAgcm9vbS50aWNrcyArPSAxOwogICAg
ICBiZWF0KHJvb20pOwogICAgfQogICAgaWYgKHJvb20uZW5kZWQpIHJldHVybjsKICAgIGlmIChk
dWUgPiA0KSByb29tLnRpY2tTdGFydCA9IG5vdyAtIHJvb20udGlja3MgKiBjb25maWcudGlja01z
OwogICAgc2NoZWR1bGVCZWF0KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gYmVhdChyb29tKSB7CiAg
ICBsZXQgZnJlc2ggPSAwOwogICAgbGV0IHByZXNlbnQgPSAwOwogICAgY29uc3QgcGFydHMgPSBb
XTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ub3JkZXIpIHsKICAgICAgbGV0IGlucHV0
ID0gRU1QVFk7CiAgICAgIGlmIChtZW1iZXIucHJlc2VudCkgewogICAgICAgIHByZXNlbnQgfD0g
MSA8PCBtZW1iZXIuaW5kZXg7CiAgICAgICAgY29uc3Qgd2FpdGluZyA9IG1lbWJlci5xdWV1ZS5s
ZW5ndGg7CiAgICAgICAgaWYgKHdhaXRpbmcpIHsKICAgICAgICAgIGZyZXNoIHw9IDEgPDwgbWVt
YmVyLmluZGV4OwogICAgICAgICAgaW5wdXQgPSB3YWl0aW5nID09PSAxID8gbWVtYmVyLnF1ZXVl
WzBdIDogbWVyZ2VJbnB1dHMobWVtYmVyLnF1ZXVlKTsKICAgICAgICAgIG1lbWJlci5sYXN0ID0g
bWVtYmVyLnF1ZXVlW3dhaXRpbmcgLSAxXTsKICAgICAgICAgIG1lbWJlci5xdWV1ZSA9IFtdOwog
ICAgICAgICAgbWVtYmVyLnJlcGVhdHMgPSAwOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBt
ZW1iZXIucmVwZWF0cyArPSAxOwogICAgICAgICAgaW5wdXQgPSBtZW1iZXIucmVwZWF0cyA+IGNv
bmZpZy5yZXBlYXRMaW1pdCA/IEVNUFRZIDogd2l0aG91dEV2ZW50cyhtZW1iZXIubGFzdCk7CiAg
ICAgICAgfQogICAgICB9CiAgICAgIHBhcnRzLnB1c2goQnVmZmVyLmZyb20oW2lucHV0Lmxlbmd0
aF0pLCBpbnB1dCk7CiAgICB9CiAgICBjb25zdCBoZWFkZXIgPSBCdWZmZXIuYWxsb2MoNyk7CiAg
ICBoZWFkZXIud3JpdGVVSW50MzJMRShyb29tLmZyYW1lICUgNDI5NDk2NzI5NiwgMCk7CiAgICBo
ZWFkZXJbNF0gPSByb29tLm9yZGVyLmxlbmd0aDsKICAgIGhlYWRlcls1XSA9IGZyZXNoOwogICAg
aGVhZGVyWzZdID0gcHJlc2VudDsKICAgIHJvb20uZnJhbWUgKz0gMTsKICAgIGNvbnN0IG1lc3Nh
Z2UgPSBwYWNrZXQoS0lORC5mcmFtZSwgQnVmZmVyLmNvbmNhdChbaGVhZGVyLCAuLi5wYXJ0c10p
KTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ub3JkZXIpIHsKICAgICAgaWYgKCFtZW1i
ZXIucHJlc2VudCkgY29udGludWU7CiAgICAgIGlmIChtZW1iZXIud3MuYnVmZmVyZWRBbW91bnQg
PiBjb25maWcubWF4QnVmZmVyZWRCeXRlcykgewogICAgICAgIGNsb3NlV2l0aChtZW1iZXIud3Ms
IENMT1NFLnNsb3dDbGllbnQpOwogICAgICAgIGNvbnRpbnVlOwogICAgICB9CiAgICAgIHNlbmRC
aW5hcnkobWVtYmVyLndzLCBtZXNzYWdlKTsKICAgIH0KICB9CgogIGZ1bmN0aW9uIGxlYXZlR3Jv
dXAobWVtYmVyKSB7CiAgICBjb25zdCByb29tID0gbWVtYmVyLnJvb207CiAgICBjb25zdCBwb3Np
dGlvbiA9IHJvb20ubWVtYmVycy5pbmRleE9mKG1lbWJlcik7CiAgICBpZiAocG9zaXRpb24gPj0g
MCkgcm9vbS5tZW1iZXJzLnNwbGljZShwb3NpdGlvbiwgMSk7CiAgICBpZiAocm9vbS5lbmRlZCkg
cmV0dXJuOwogICAgaWYgKCFyb29tLnN0YXJ0ZWQpIHsKICAgICAgaWYgKG1lbWJlci5ob3N0KSB7
CiAgICAgICAgcm9vbS5ob3N0ID0gbnVsbDsKICAgICAgICBlbmRHcm91cChyb29tLCBDTE9TRS5o
b3N0TGVmdCk7CiAgICAgIH0gZWxzZSBpZiAoIXJvb20ubWVtYmVycy5sZW5ndGgpIHsKICAgICAg
ICBlbmRHcm91cChyb29tKTsKICAgICAgfSBlbHNlIGlmIChtZW1iZXIuaW5mbykgewogICAgICAg
IHNlbmRMb2JieShyb29tKTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAobWVt
YmVyLmluZGV4ID49IDAgJiYgbWVtYmVyLnByZXNlbnQpIHsKICAgICAgbWVtYmVyLnByZXNlbnQg
PSBmYWxzZTsKICAgICAgbWVtYmVyLnF1ZXVlID0gW107CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBw
YWNrZXQoS0lORC5sZWZ0LCBCdWZmZXIuZnJvbShbbWVtYmVyLmluZGV4XSkpOwogICAgICBjb25z
dCBwbGF5ZXJzID0gcm9vbS5vcmRlci5maWx0ZXIoKG90aGVyKSA9PiBvdGhlci5wcmVzZW50KS5s
ZW5ndGg7CiAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5vcmRlcikgewogICAgICAgIGlm
ICghb3RoZXIucHJlc2VudCkgY29udGludWU7CiAgICAgICAgc2VuZEJpbmFyeShvdGhlci53cywg
bWVzc2FnZSk7CiAgICAgICAgc2VuZENvbnRyb2wob3RoZXIud3MsIHsgdDogJ3Jvb20nLCBwbGF5
ZXJzLCBzdGFydGVkOiB0cnVlIH0pOwogICAgICB9CiAgICAgIGxvZyhgcm9vbSAke3Jvb20uY29k
ZX06IHBsYXllciAke21lbWJlci5pbmRleCArIDF9IGxlZnRgKTsKICAgIH0KICAgIGlmICghcm9v
bS5vcmRlci5zb21lKChvdGhlcikgPT4gb3RoZXIucHJlc2VudCkpIGVuZEdyb3VwKHJvb20pOwog
ICAgZWxzZSBpZiAocm9vbS5vcmRlci5ldmVyeSgob3RoZXIpID0+IG90aGVyLnJlYWR5IHx8ICFv
dGhlci5wcmVzZW50KSkgc3RhcnRCZWF0KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gZW5kR3JvdXAo
cm9vbSwgcmVhc29uKSB7CiAgICBpZiAocm9vbS5lbmRlZCkgcmV0dXJuOwogICAgcm9vbS5lbmRl
ZCA9IHRydWU7CiAgICBjbGVhclRpbWVvdXQocm9vbS5sb2JieVRpbWVyKTsKICAgIGNsZWFyVGlt
ZW91dChyb29tLmdyYWNlVGltZXIpOwogICAgY2xlYXJUaW1lb3V0KHJvb20udGlja1RpbWVyKTsK
ICAgIGlmIChncm91cHMuZ2V0KHJvb20uY29kZSkgPT09IHJvb20pIGdyb3Vwcy5kZWxldGUocm9v
bS5jb2RlKTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ubWVtYmVycy5zbGljZSgpKSBj
bG9zZVdpdGgobWVtYmVyLndzLCByZWFzb24gfHwgQ0xPU0Uuc2h1dGRvd24pOwogICAgbG9nKGBy
b29tICR7cm9vbS5jb2RlfTogZW5kZWRgKTsKICB9CgogIC8vIFNpemUgb2YgdGhlIGluc3RhbGxl
ciBmaWxlLCBvciAwIHdoZW4gbm9uZSBpcyBjb25maWd1cmVkIG9yIHJlYWRhYmxlLgogIGZ1bmN0
aW9uIGluc3RhbGxlclNpemUoKSB7CiAgICBpZiAoIWNvbmZpZy5pbnN0YWxsZXJGaWxlKSByZXR1
cm4gMDsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHN0YXQgPSBmcy5zdGF0U3luYyhjb25maWcuaW5z
dGFsbGVyRmlsZSk7CiAgICAgIHJldHVybiBzdGF0LmlzRmlsZSgpID8gc3RhdC5zaXplIDogMDsK
ICAgIH0gY2F0Y2ggewogICAgICByZXR1cm4gMDsKICAgIH0KICB9CgogIGZ1bmN0aW9uIHNlcnZl
SW5zdGFsbGVyKHJlcSwgcmVzKSB7CiAgICBjb25zdCBoZWFkZXJzID0geyAnY2FjaGUtY29udHJv
bCc6ICdwdWJsaWMsIG1heC1hZ2U9ODY0MDAnLCAneC1jb250ZW50LXR5cGUtb3B0aW9ucyc6ICdu
b3NuaWZmJywgLi4uYWxsb3dPcmlnaW4ocmVxKSB9OwogICAgaWYgKHJlcS5tZXRob2QgIT09ICdH
RVQnICYmIHJlcS5tZXRob2QgIT09ICdIRUFEJykgewogICAgICByZXMud3JpdGVIZWFkKDQwNSwg
eyAuLi5oZWFkZXJzLCBhbGxvdzogJ0dFVCwgSEVBRCcgfSk7CiAgICAgIHJlcy5lbmQoKTsKICAg
ICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qgc2l6ZSA9IGluc3RhbGxlclNpemUoKTsKICAgIGlm
ICghc2l6ZSkgewogICAgICByZXMud3JpdGVIZWFkKDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5l
bmQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHJlcS5tZXRob2QgPT09ICdHRVQnICYm
IGNvbmZpZy5pbnN0YWxsZXJEb3dubG9hZHNQZXJIb3VyKSB7CiAgICAgIGNvbnN0IGFkZHJlc3Mg
PSBjbGllbnRBZGRyZXNzKHJlcSk7CiAgICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgICAg
IGxldCBlbnRyeSA9IGluc3RhbGxlckRvd25sb2Fkcy5nZXQoYWRkcmVzcyk7CiAgICAgIGlmICgh
ZW50cnkgfHwgZW50cnkudW50aWwgPD0gbm93KSB7CiAgICAgICAgZW50cnkgPSB7IGNvdW50OiAw
LCB1bnRpbDogbm93ICsgMzYwMDAwMCB9OwogICAgICAgIGluc3RhbGxlckRvd25sb2Fkcy5zZXQo
YWRkcmVzcywgZW50cnkpOwogICAgICB9CiAgICAgIGlmIChlbnRyeS5jb3VudCA+PSBjb25maWcu
aW5zdGFsbGVyRG93bmxvYWRzUGVySG91cikgewogICAgICAgIHJlcy53cml0ZUhlYWQoNDI5LCB7
IC4uLmhlYWRlcnMsICdyZXRyeS1hZnRlcic6IFN0cmluZyhNYXRoLmNlaWwoKGVudHJ5LnVudGls
IC0gbm93KSAvIDEwMDApKSB9KTsKICAgICAgICByZXMuZW5kKCk7CiAgICAgICAgcmV0dXJuOwog
ICAgICB9CiAgICAgIGVudHJ5LmNvdW50ICs9IDE7CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIw
MCwgeyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBlJzogJ2FwcGxpY2F0aW9uL29jdGV0LXN0cmVh
bScsICdjb250ZW50LWxlbmd0aCc6IFN0cmluZyhzaXplKSB9KTsKICAgIGlmIChyZXEubWV0aG9k
ID09PSAnSEVBRCcpIHsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBj
b25zdCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFkU3RyZWFtKGNvbmZpZy5pbnN0YWxsZXJGaWxlKTsK
ICAgIHN0cmVhbS5vbignZXJyb3InLCAoKSA9PiByZXMuZGVzdHJveSgpKTsKICAgIHN0cmVhbS5w
aXBlKHJlcyk7CiAgfQoKICAvLyBDcm9zcy1vcmlnaW46IHRoZSBnYW1lIHBhZ2UgbGl2ZXMgZWxz
ZXdoZXJlIChHaXRIdWIgUGFnZXMpLiBXaXRoIGFuIGFsbG93LWxpc3QsIG9ubHkgaXRzIHBhZ2Vz
IG1heSByZWFkLgogIGZ1bmN0aW9uIGFsbG93T3JpZ2luKHJlcSkgewogICAgaWYgKCFjb25maWcu
YWxsb3dlZE9yaWdpbnMubGVuZ3RoKSByZXR1cm4geyAnYWNjZXNzLWNvbnRyb2wtYWxsb3ctb3Jp
Z2luJzogJyonIH07CiAgICBjb25zdCBvcmlnaW4gPSBub3JtYWxpemVPcmlnaW4ocmVxLmhlYWRl
cnMub3JpZ2luKTsKICAgIGlmIChvcmlnaW4gJiYgY29uZmlnLmFsbG93ZWRPcmlnaW5zLmluY2x1
ZGVzKG9yaWdpbikpIHJldHVybiB7ICdhY2Nlc3MtY29udHJvbC1hbGxvdy1vcmlnaW4nOiByZXEu
aGVhZGVycy5vcmlnaW4sIHZhcnk6ICdPcmlnaW4nIH07CiAgICByZXR1cm4ge307CiAgfQoKICBm
dW5jdGlvbiBjbGllbnRBZGRyZXNzKHJlcSkgewogICAgaWYgKGNvbmZpZy50cnVzdFByb3h5KSB7
CiAgICAgIC8vIFRoZSBsYXN0IGVudHJ5IGlzIHRoZSBvbmUgb3VyIG93biBwcm94eSBhZGRlZCAo
QXBhY2hlIGFwcGVuZHMsIENhZGR5IHJlcGxhY2VzKTsgZW50cmllcyBiZWZvcmUKICAgICAgLy8g
aXQgY29tZSBmcm9tIHRoZSBjbGllbnQgYW5kIGNvdWxkIGJlIG1hZGUgdXAgdG8gc2xpcCBwYXN0
IHRoZSBwZXItYWRkcmVzcyBsaW1pdHMuCiAgICAgIGNvbnN0IGZvcndhcmRlZCA9IFN0cmluZyhy
ZXEuaGVhZGVyc1sneC1mb3J3YXJkZWQtZm9yJ10gfHwgJycpLnNwbGl0KCcsJykubWFwKChwYXJ0
KSA9PiBwYXJ0LnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pOwogICAgICBpZiAoZm9yd2FyZGVkLmxl
bmd0aCkgcmV0dXJuIGZvcndhcmRlZFtmb3J3YXJkZWQubGVuZ3RoIC0gMV07CiAgICB9CiAgICBy
ZXR1cm4gcmVxLnNvY2tldC5yZW1vdGVBZGRyZXNzIHx8ICd1bmtub3duJzsKICB9CgogIGNvbnN0
IGhlYXJ0YmVhdCA9IHNldEludGVydmFsKCgpID0+IHsKICAgIGZvciAoY29uc3Qgd3Mgb2Ygd3Nz
LmNsaWVudHMpIHsKICAgICAgaWYgKCF3cy5pc0FsaXZlKSB7IHdzLnRlcm1pbmF0ZSgpOyBjb250
aW51ZTsgfQogICAgICB3cy5pc0FsaXZlID0gZmFsc2U7CiAgICAgIHRyeSB7IHdzLnBpbmcoKTsg
fSBjYXRjaCB7IC8qIGNsb3NpbmcgKi8gfQogICAgfQogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3co
KTsKICAgIGZvciAoY29uc3QgW2FkZHJlc3MsIGVudHJ5XSBvZiBpbnN0YWxsZXJEb3dubG9hZHMp
IGlmIChlbnRyeS51bnRpbCA8PSBub3cpIGluc3RhbGxlckRvd25sb2Fkcy5kZWxldGUoYWRkcmVz
cyk7CiAgICBwYWNrcy5jbGVhbnVwKCk7CiAgfSwgY29uZmlnLnBpbmdJbnRlcnZhbE1zKTsKICBo
ZWFydGJlYXQudW5yZWYoKTsKCiAgcmV0dXJuIHsKICAgIGNvbmZpZywKICAgIHNlcnZlciwKICAg
IHdzcywKICAgIHJvb21zLAogICAgbGlzdGVuKHBvcnQgPSBjb25maWcucG9ydCwgaG9zdCA9IGNv
bmZpZy5ob3N0KSB7CiAgICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVzb2x2ZSwgcmVqZWN0KSA9
PiB7CiAgICAgICAgc2VydmVyLm9uY2UoJ2Vycm9yJywgcmVqZWN0KTsKICAgICAgICBzZXJ2ZXIu
bGlzdGVuKHBvcnQsIGhvc3QsICgpID0+IHsKICAgICAgICAgIHNlcnZlci5vZmYoJ2Vycm9yJywg
cmVqZWN0KTsKICAgICAgICAgIHJlc29sdmUoc2VydmVyLmFkZHJlc3MoKSk7CiAgICAgICAgfSk7
CiAgICAgIH0pOwogICAgfSwKICAgIGdyb3VwcywKICAgIGhmLAogICAgY2xvc2UoKSB7CiAgICAg
IGNsZWFySW50ZXJ2YWwoaGVhcnRiZWF0KTsKICAgICAgaGYuY2xvc2UoKTsKICAgICAgZm9yIChj
b25zdCByb29tIG9mIHJvb21zLnZhbHVlcygpKSBjbGVhclRpbWVvdXQocm9vbS50aW1lcik7CiAg
ICAgIGZvciAoY29uc3Qgcm9vbSBvZiBbLi4uZ3JvdXBzLnZhbHVlcygpXSkgZW5kR3JvdXAocm9v
bSwgQ0xPU0Uuc2h1dGRvd24pOwogICAgICBmb3IgKGNvbnN0IHdzIG9mIHdzcy5jbGllbnRzKSBj
bG9zZVdpdGgod3MsIENMT1NFLnNodXRkb3duKTsKICAgICAgcmV0dXJuIG5ldyBQcm9taXNlKChy
ZXNvbHZlKSA9PiB7CiAgICAgICAgd3NzLmNsb3NlKCgpID0+IHNlcnZlci5jbG9zZSgoKSA9PiBy
ZXNvbHZlKCkpKTsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsgZm9yIChjb25zdCB3cyBvZiB3
c3MuY2xpZW50cykgd3MudGVybWluYXRlKCk7IH0sIDEwMDApLnVucmVmKCk7CiAgICAgIH0pOwog
ICAgfSwKICB9Owp9CgpmdW5jdGlvbiBzZW5kQ29udHJvbCh3cywgbWVzc2FnZSkgewogIGlmICh3
cy5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQuT1BFTikgd3Muc2VuZChKU09OLnN0cmluZ2lmeSht
ZXNzYWdlKSk7Cn0KCmZ1bmN0aW9uIHNlbmRCaW5hcnkod3MsIGRhdGEpIHsKICBpZiAod3MucmVh
ZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4pIHdzLnNlbmQoZGF0YSwgeyBiaW5hcnk6IHRydWUg
fSk7Cn0KCmNvbnN0IEVNUFRZID0gQnVmZmVyLmFsbG9jKDApOwoKLy8gQSBwcm90b2NvbCAyIG1l
c3NhZ2U6IGtpbmQsIHBheWxvYWQgbGVuZ3RoICgyIGJ5dGVzLCBsaXR0bGUgZW5kaWFuKSwgcGF5
bG9hZC4KZnVuY3Rpb24gcGFja2V0KGtpbmQsIHBheWxvYWQpIHsKICBjb25zdCBtZXNzYWdlID0g
QnVmZmVyLmFsbG9jVW5zYWZlKDMgKyBwYXlsb2FkLmxlbmd0aCk7CiAgbWVzc2FnZVswXSA9IGtp
bmQ7CiAgbWVzc2FnZS53cml0ZVVJbnQxNkxFKHBheWxvYWQubGVuZ3RoLCAxKTsKICBwYXlsb2Fk
LmNvcHkobWVzc2FnZSwgMyk7CiAgcmV0dXJuIG1lc3NhZ2U7Cn0KCi8vIElucHV0cyBhcmUgYml0
IHNldHMgKGtleXMgaGVsZCwgZXZlbnRzKTogbWVyZ2VkLCBldmVyeSBiaXQgc2V0IGluIGFueSBv
ZiB0aGVtIGlzIHNldC4KZnVuY3Rpb24gbWVyZ2VJbnB1dHMoaW5wdXRzKSB7CiAgY29uc3QgbWVy
Z2VkID0gQnVmZmVyLmFsbG9jKE1hdGgubWF4KDAsIC4uLmlucHV0cy5tYXAoKGlucHV0KSA9PiBp
bnB1dC5sZW5ndGgpKSk7CiAgZm9yIChjb25zdCBpbnB1dCBvZiBpbnB1dHMpIGZvciAobGV0IGlu
ZGV4ID0gMDsgaW5kZXggPCBpbnB1dC5sZW5ndGg7IGluZGV4ICs9IDEpIG1lcmdlZFtpbmRleF0g
fD0gaW5wdXRbaW5kZXhdOwogIHJldHVybiBtZXJnZWQ7Cn0KCi8vIEEgcmVwZWF0ZWQgaW5wdXQg
a2VlcHMgaXRzIGhlbGQga2V5cyBidXQgbm90IGl0cyBvbmUtc2hvdCBldmVudHMgKGJ5dGUgMCku
CmZ1bmN0aW9uIHdpdGhvdXRFdmVudHMoaW5wdXQpIHsKICBpZiAoIWlucHV0Lmxlbmd0aCB8fCBp
bnB1dFswXSA9PT0gMCkgcmV0dXJuIGlucHV0OwogIGNvbnN0IGNvcHkgPSBCdWZmZXIuZnJvbShp
bnB1dCk7CiAgY29weVswXSA9IDA7CiAgcmV0dXJuIGNvcHk7Cn0KCmZ1bmN0aW9uIGNsb3NlV2l0
aCh3cywgW2NvZGUsIHJlYXNvbl0pIHsKICBpZiAod3MucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0
Lk9QRU4gfHwgd3MucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0LkNPTk5FQ1RJTkcpIHsKICAgIHdz
LmNsb3NlKGNvZGUsIHJlYXNvbik7CiAgICAvLyBEbyBub3Qgd2FpdCBmb3JldmVyIGZvciBhIGNs
aWVudCB0aGF0IG5ldmVyIGFuc3dlcnMgdGhlIGNsb3NlIGhhbmRzaGFrZS4KICAgIHNldFRpbWVv
dXQoKCkgPT4geyBpZiAod3MucmVhZHlTdGF0ZSAhPT0gV2ViU29ja2V0LkNMT1NFRCkgd3MudGVy
bWluYXRlKCk7IH0sIDMwMDApLnVucmVmKCk7CiAgfQp9Cgptb2R1bGUuZXhwb3J0cyA9IHsgY3Jl
YXRlUmVsYXksIHJlYWRDb25maWcsIENMT1NFLCBST09NX1BBVFRFUk4sIEtJTkQsIFJPT01fTElN
SVRTLCBwYWNrZXQsIG1lcmdlSW5wdXRzIH07CgppZiAocmVxdWlyZS5tYWluID09PSBtb2R1bGUp
IHsKICBjb25zdCByZWxheSA9IGNyZWF0ZVJlbGF5KHJlYWRDb25maWcoKSk7CiAgcmVsYXkubGlz
dGVuKCkudGhlbigoYWRkcmVzcykgPT4gewogICAgY29uc3Qgd2hlcmUgPSB0eXBlb2YgYWRkcmVz
cyA9PT0gJ3N0cmluZycgPyBhZGRyZXNzIDogYCR7YWRkcmVzcy5hZGRyZXNzfToke2FkZHJlc3Mu
cG9ydH1gOwogICAgY29uc29sZS5sb2coYE9wZW5MRjIgcmVsYXkgbGlzdGVuaW5nIG9uICR7d2hl
cmV9LCBXZWJTb2NrZXQgcGF0aCAke3JlbGF5LmNvbmZpZy5wYXRofWApOwogICAgaWYgKCFyZWxh
eS5jb25maWcuYWxsb3dlZE9yaWdpbnMubGVuZ3RoKSB7CiAgICAgIGNvbnNvbGUubG9nKCdBTExP
V0VEX09SSUdJTlMgaXMgZW1wdHk6IGFueSB3ZWJzaXRlIG1heSB1c2UgdGhpcyByZWxheS4gU2V0
IGl0IHRvIHlvdXIgZ2FtZSBwYWdlIG9yaWdpbi4nKTsKICAgIH0KICB9KS5jYXRjaCgoZXJyb3Ip
ID0+IHsKICAgIGNvbnNvbGUuZXJyb3IoZXJyb3IubWVzc2FnZSk7CiAgICBwcm9jZXNzLmV4aXQo
MSk7CiAgfSk7CiAgY29uc3Qgc3RvcCA9ICgpID0+IHJlbGF5LmNsb3NlKCkudGhlbigoKSA9PiBw
cm9jZXNzLmV4aXQoMCkpOwogIHByb2Nlc3Mub24oJ1NJR0lOVCcsIHN0b3ApOwogIHByb2Nlc3Mu
b24oJ1NJR1RFUk0nLCBzdG9wKTsKfQo=
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
cGkvcGFja3MvPGlkPiAgICAgcmVtb3ZlIG9uZSAoWC1BZG1pbi1LZXkpCid1c2Ugc3RyaWN0JzsK
CmNvbnN0IGNyeXB0byA9IHJlcXVpcmUoJ25vZGU6Y3J5cHRvJyk7CmNvbnN0IGZzID0gcmVxdWly
ZSgnbm9kZTpmcycpOwpjb25zdCBmc3AgPSByZXF1aXJlKCdub2RlOmZzL3Byb21pc2VzJyk7CmNv
bnN0IHBhdGggPSByZXF1aXJlKCdub2RlOnBhdGgnKTsKY29uc3QgeyBwaXBlbGluZSB9ID0gcmVx
dWlyZSgnbm9kZTpzdHJlYW0vcHJvbWlzZXMnKTsKY29uc3QgeyBUcmFuc2Zvcm0gfSA9IHJlcXVp
cmUoJ25vZGU6c3RyZWFtJyk7CmNvbnN0IHpsaWIgPSByZXF1aXJlKCdub2RlOnpsaWInKTsKCmNv
bnN0IFBBQ0tfSUQgPSAvXlthLXowLTldW2EtejAtOS1dezAsMzl9JC87CmNvbnN0IE1JQiA9IDEw
MjQgKiAxMDI0OwovLyBGaWxlcyBiZXNpZGUgdGhlIGdhbWUgdGhhdCBubyBnYW1lIHJlYWRzOiBu
b3RlcywgYXJjaGl2ZXMsIHZpZGVvcywgc2hvcnRjdXRzLgpjb25zdCBOT1RFUyA9IC9cLih0eHR8
bmZvfGRvY3xkb2N4fHBkZnxydGZ8aHRtfGh0bWx8dXJsfGxua3xzd2Z8cmFyfHppcHw3enxsZnJ8
bXA0fGF2aXx3bXZ8anBnfGpwZWd8Z2lmKSQvaTsKCmNsYXNzIFBhY2tFcnJvciBleHRlbmRzIEVy
cm9yIHt9CgovLyBUaGUgY2VudHJhbCBkaXJlY3Rvcnkgb2YgYSBaSVAgZmlsZTogaXRzIGVudHJp
ZXMgd2l0aCB0aGVpciByYXcgcmVjb3Jkcy4KYXN5bmMgZnVuY3Rpb24gcmVhZFppcChmaWxlKSB7
CiAgY29uc3QgaGFuZGxlID0gYXdhaXQgZnNwLm9wZW4oZmlsZSwgJ3InKTsKICB0cnkgewogICAg
Y29uc3QgeyBzaXplIH0gPSBhd2FpdCBoYW5kbGUuc3RhdCgpOwogICAgaWYgKHNpemUgPCAyMikg
dGhyb3cgbmV3IFBhY2tFcnJvcigndGhpcyBpcyBub3QgYSBaSVAgZmlsZScpOwogICAgaWYgKHNp
emUgPiAweGZmZmZmZmZmKSB0aHJvdyBuZXcgUGFja0Vycm9yKCdaSVAgZmlsZXMgb3ZlciA0IEdp
QiBhcmUgbm90IHN1cHBvcnRlZCcpOwogICAgY29uc3QgdGFpbFNpemUgPSBNYXRoLm1pbihzaXpl
LCAyMiArIDY1NTM1KTsKICAgIGNvbnN0IHRhaWwgPSBCdWZmZXIuYWxsb2ModGFpbFNpemUpOwog
ICAgYXdhaXQgaGFuZGxlLnJlYWQodGFpbCwgMCwgdGFpbFNpemUsIHNpemUgLSB0YWlsU2l6ZSk7
CiAgICBsZXQgZW5kID0gLTE7CiAgICBmb3IgKGxldCBhdCA9IHRhaWxTaXplIC0gMjI7IGF0ID49
IDA7IGF0IC09IDEpIHsKICAgICAgaWYgKHRhaWwucmVhZFVJbnQzMkxFKGF0KSA9PT0gMHgwNjA1
NGI1MCAmJiBhdCArIDIyICsgdGFpbC5yZWFkVUludDE2TEUoYXQgKyAyMCkgPT09IHRhaWxTaXpl
KSB7CiAgICAgICAgZW5kID0gYXQ7CiAgICAgICAgYnJlYWs7CiAgICAgIH0KICAgIH0KICAgIGlm
IChlbmQgPCAwKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGlzIGlzIG5vdCBhIFpJUCBmaWxlJyk7
CiAgICBjb25zdCBjb3VudCA9IHRhaWwucmVhZFVJbnQxNkxFKGVuZCArIDEwKTsKICAgIGNvbnN0
IGRpcmVjdG9yeVNpemUgPSB0YWlsLnJlYWRVSW50MzJMRShlbmQgKyAxMik7CiAgICBjb25zdCBk
aXJlY3RvcnlPZmZzZXQgPSB0YWlsLnJlYWRVSW50MzJMRShlbmQgKyAxNik7CiAgICBpZiAodGFp
bC5yZWFkVUludDE2TEUoZW5kICsgNCkgIT09IDAgfHwgdGFpbC5yZWFkVUludDE2TEUoZW5kICsg
OCkgIT09IGNvdW50KSB0aHJvdyBuZXcgUGFja0Vycm9yKCdzcGxpdCBaSVAgZmlsZXMgYXJlIG5v
dCBzdXBwb3J0ZWQnKTsKICAgIGlmIChjb3VudCA9PT0gMHhmZmZmIHx8IGRpcmVjdG9yeVNpemUg
PT09IDB4ZmZmZmZmZmYgfHwgZGlyZWN0b3J5T2Zmc2V0ID09PSAweGZmZmZmZmZmKSB7CiAgICAg
IHRocm93IG5ldyBQYWNrRXJyb3IoJ1pJUDY0IGZpbGVzIGFyZSBub3Qgc3VwcG9ydGVkJyk7CiAg
ICB9CiAgICBpZiAoZGlyZWN0b3J5T2Zmc2V0ICsgZGlyZWN0b3J5U2l6ZSA+IHNpemUpIHRocm93
IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAgZmlsZSBpcyBkYW1hZ2VkJyk7CiAgICBjb25zdCBkaXJl
Y3RvcnkgPSBCdWZmZXIuYWxsb2MoZGlyZWN0b3J5U2l6ZSk7CiAgICBhd2FpdCBoYW5kbGUucmVh
ZChkaXJlY3RvcnksIDAsIGRpcmVjdG9yeVNpemUsIGRpcmVjdG9yeU9mZnNldCk7CiAgICBjb25z
dCBlbnRyaWVzID0gW107CiAgICBmb3IgKGxldCBhdCA9IDAsIGluZGV4ID0gMDsgaW5kZXggPCBj
b3VudDsgaW5kZXggKz0gMSkgewogICAgICBpZiAoYXQgKyA0NiA+IGRpcmVjdG9yeS5sZW5ndGgg
fHwgZGlyZWN0b3J5LnJlYWRVSW50MzJMRShhdCkgIT09IDB4MDIwMTRiNTApIHRocm93IG5ldyBQ
YWNrRXJyb3IoJ3RoZSBaSVAgZmlsZSBpcyBkYW1hZ2VkJyk7CiAgICAgIGNvbnN0IG5hbWVMZW5n
dGggPSBkaXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgMjgpOwogICAgICBjb25zdCBsZW5ndGgg
PSA0NiArIG5hbWVMZW5ndGggKyBkaXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgMzApICsgZGly
ZWN0b3J5LnJlYWRVSW50MTZMRShhdCArIDMyKTsKICAgICAgaWYgKGF0ICsgbGVuZ3RoID4gZGly
ZWN0b3J5Lmxlbmd0aCkgdGhyb3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFn
ZWQnKTsKICAgICAgY29uc3QgZmxhZ3MgPSBkaXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgOCk7
CiAgICAgIGNvbnN0IG5hbWUgPSBkaXJlY3RvcnkudG9TdHJpbmcoZmxhZ3MgJiAweDgwMCA/ICd1
dGY4JyA6ICdsYXRpbjEnLCBhdCArIDQ2LCBhdCArIDQ2ICsgbmFtZUxlbmd0aCk7CiAgICAgIGVu
dHJpZXMucHVzaCh7CiAgICAgICAgbmFtZSwgZmxhZ3MsIG1ldGhvZDogZGlyZWN0b3J5LnJlYWRV
SW50MTZMRShhdCArIDEwKSwKICAgICAgICBjb21wcmVzc2VkU2l6ZTogZGlyZWN0b3J5LnJlYWRV
SW50MzJMRShhdCArIDIwKSwgc2l6ZTogZGlyZWN0b3J5LnJlYWRVSW50MzJMRShhdCArIDI0KSwK
ICAgICAgICBsb2NhbE9mZnNldDogZGlyZWN0b3J5LnJlYWRVSW50MzJMRShhdCArIDQyKSwgcmVj
b3JkOiBCdWZmZXIuZnJvbShkaXJlY3Rvcnkuc3ViYXJyYXkoYXQsIGF0ICsgbGVuZ3RoKSksCiAg
ICAgIH0pOwogICAgICBhdCArPSBsZW5ndGg7CiAgICB9CiAgICByZXR1cm4geyBlbnRyaWVzLCBz
aXplIH07CiAgfSBmaW5hbGx5IHsKICAgIGF3YWl0IGhhbmRsZS5jbG9zZSgpOwogIH0KfQoKLy8g
V2hhdCBvZiBhIFpJUCBmaWxlIHRoZSBnYW1lIG5lZWRzOiB0aGUgZ2FtZSBmb2xkZXIgKHRoZSBv
bmUgaG9sZGluZyBkYXRhL2RhdGEudHh0IG5lYXJlc3QgdGhlCi8vIHRvcCkgd2l0aG91dCBvdGhl
ciBjb3BpZXMgb2YgdGhlIGdhbWUgaW5zaWRlIGl0LCByZWNvcmRpbmdzLCBub3RlcyBhbmQgb3Ro
ZXIgcHJvZ3JhbXMuCmZ1bmN0aW9uIGFuYWx5emVaaXAoZW50cmllcykgewogIGNvbnN0IGxvd2Vy
ID0gKG5hbWUpID0+IG5hbWUucmVwbGFjZSgvXFwvZywgJy8nKS50b0xvd2VyQ2FzZSgpOwogIGxl
dCByb290ID0gbnVsbDsKICBmb3IgKGNvbnN0IGVudHJ5IG9mIGVudHJpZXMpIHsKICAgIGNvbnN0
IG5hbWUgPSBsb3dlcihlbnRyeS5uYW1lKTsKICAgIGlmIChuYW1lID09PSAnZGF0YS9kYXRhLnR4
dCcgfHwgbmFtZS5lbmRzV2l0aCgnL2RhdGEvZGF0YS50eHQnKSkgewogICAgICBjb25zdCBmb2xk
ZXIgPSBuYW1lLnNsaWNlKDAsIG5hbWUubGVuZ3RoIC0gJ2RhdGEvZGF0YS50eHQnLmxlbmd0aCk7
CiAgICAgIGlmIChyb290ID09PSBudWxsIHx8IGZvbGRlci5sZW5ndGggPCByb290Lmxlbmd0aCkg
cm9vdCA9IGZvbGRlcjsKICAgIH0KICB9CiAgaWYgKHJvb3QgPT09IG51bGwpIHRocm93IG5ldyBQ
YWNrRXJyb3IoJ25vIGRhdGEvZGF0YS50eHQgaW5zaWRlOiB0aGlzIGlzIG5vdCBhbiBMRjIgZ2Ft
ZSBmb2xkZXInKTsKICBjb25zdCBpbnNpZGUgPSBbXTsKICBmb3IgKGNvbnN0IGVudHJ5IG9mIGVu
dHJpZXMpIHsKICAgIGNvbnN0IG5hbWUgPSBsb3dlcihlbnRyeS5uYW1lKTsKICAgIGlmICghbmFt
ZS5zdGFydHNXaXRoKHJvb3QpIHx8IG5hbWUuZW5kc1dpdGgoJy8nKSB8fCBuYW1lLmxlbmd0aCA9
PT0gcm9vdC5sZW5ndGgpIGNvbnRpbnVlOwogICAgaW5zaWRlLnB1c2goeyBlbnRyeSwgcGF0aDog
bmFtZS5zbGljZShyb290Lmxlbmd0aCkgfSk7CiAgfQogIC8vIEFub3RoZXIgY29weSBvZiBhIGdh
bWUgaW5zaWRlIHRoaXMgb25lIChhIHN1YmZvbGRlciB3aXRoIGl0cyBvd24gZGF0YS9kYXRhLnR4
dCkuCiAgY29uc3QgY29waWVzID0gaW5zaWRlLmZpbHRlcigoeyBwYXRoOiBuYW1lIH0pID0+IG5h
bWUgIT09ICdkYXRhL2RhdGEudHh0JyAmJiBuYW1lLmVuZHNXaXRoKCcvZGF0YS9kYXRhLnR4dCcp
KQogICAgLm1hcCgoeyBwYXRoOiBuYW1lIH0pID0+IG5hbWUuc2xpY2UoMCwgbmFtZS5sZW5ndGgg
LSAnZGF0YS9kYXRhLnR4dCcubGVuZ3RoKSk7CiAgY29uc3QgZXhlY3V0YWJsZXMgPSBpbnNpZGUu
ZmlsdGVyKCh7IHBhdGg6IG5hbWUgfSkgPT4gIW5hbWUuaW5jbHVkZXMoJy8nKSAmJiBuYW1lLmVu
ZHNXaXRoKCcuZXhlJykpOwogIGlmICghZXhlY3V0YWJsZXMubGVuZ3RoKSB0aHJvdyBuZXcgUGFj
a0Vycm9yKCdubyBnYW1lIHByb2dyYW0gKC5leGUpIGJlc2lkZSBpdHMgZGF0YSBmb2xkZXInKTsK
ICBjb25zdCBtYWluID0gZXhlY3V0YWJsZXMuZmluZCgoeyBwYXRoOiBuYW1lIH0pID0+IG5hbWUg
PT09ICdsZjIuZXhlJykKICAgIHx8IGV4ZWN1dGFibGVzLnJlZHVjZSgobGFyZ2VzdCwgaXRlbSkg
PT4gKGl0ZW0uZW50cnkuc2l6ZSA+IGxhcmdlc3QuZW50cnkuc2l6ZSA/IGl0ZW0gOiBsYXJnZXN0
KSk7CiAgY29uc3Qga2VlcCA9IFtdOwogIGZvciAoY29uc3QgaXRlbSBvZiBpbnNpZGUpIHsKICAg
IGNvbnN0IG5hbWUgPSBpdGVtLnBhdGg7CiAgICBjb25zdCB0b3BMZXZlbCA9ICFuYW1lLmluY2x1
ZGVzKCcvJyk7CiAgICBpZiAoY29waWVzLnNvbWUoKGNvcHkpID0+IG5hbWUuc3RhcnRzV2l0aChj
b3B5KSkpIGNvbnRpbnVlOwogICAgaWYgKG5hbWUuc3RhcnRzV2l0aCgncmVjb3JkaW5nLycpKSBj
b250aW51ZTsKICAgIGlmICh0b3BMZXZlbCAmJiBuYW1lLmVuZHNXaXRoKCcuZXhlJykgJiYgaXRl
bSAhPT0gbWFpbikgY29udGludWU7CiAgICBpZiAodG9wTGV2ZWwgJiYgTk9URVMudGVzdChuYW1l
KSkgY29udGludWU7CiAgICBpZiAoaXRlbS5lbnRyeS5mbGFncyAmIDEpIHRocm93IG5ldyBQYWNr
RXJyb3IoYCR7aXRlbS5lbnRyeS5uYW1lfSBpcyBlbmNyeXB0ZWRgKTsKICAgIGlmIChpdGVtLmVu
dHJ5Lm1ldGhvZCAhPT0gMCAmJiBpdGVtLmVudHJ5Lm1ldGhvZCAhPT0gOCkgewogICAgICB0aHJv
dyBuZXcgUGFja0Vycm9yKGAke2l0ZW0uZW50cnkubmFtZX0gdXNlcyBhIGNvbXByZXNzaW9uIHRo
ZSBnYW1lIGNhbm5vdCByZWFkICh6aXAgaXQgYWdhaW4gd2l0aCBEZWZsYXRlKWApOwogICAgfQog
ICAgLy8gVGhlIGdhbWUgcmVhZHMgZmlsZXMgdXAgdG8gMjU2IE1pQiBmcm9tIGEgcGFjayAoc3Jj
L3Jlc291cmNlcy9wYWNrLmNwcCkuCiAgICBpZiAoaXRlbS5lbnRyeS5zaXplID4gMjU2ICogTUlC
KSB0aHJvdyBuZXcgUGFja0Vycm9yKGAke2l0ZW0uZW50cnkubmFtZX0gaXMgbGFyZ2VyIHRoYW4g
MjU2IE1CYCk7CiAgICBrZWVwLnB1c2goaXRlbS5lbnRyeSk7CiAgfQogIHJldHVybiB7IHJvb3Qs
IGV4ZWN1dGFibGU6IG1haW4ucGF0aCwga2VlcCwgZHJvcHBlZDogZW50cmllcy5sZW5ndGggLSBr
ZWVwLmxlbmd0aCB9Owp9CgovLyAtLS0tIEZsYXNoIGdhbWVzIC0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0KLy8gQSBGbGFzaCBwcm9qZWN0b3IgKEZsYXNoIFBsYXllciBmb3IgV2luZG93cyB3aXRo
IGEgbW92aWUgaW5zaWRlKSBlbmRzIHdpdGggMHhGQTEyMzQ1NiBhbmQgdGhlIG1vdmllJ3MKLy8g
bGVuZ3RoIChib3RoIDQgYnl0ZXMsIGxpdHRsZSBlbmRpYW4pLCB0aGUgbW92aWUganVzdCBiZWZv
cmUuCmNvbnN0IFBST0pFQ1RPUl9NQUdJQyA9IDB4ZmExMjM0NTY7Ci8vIEhlcm8gRmlnaHRlcidz
IG1vdmllczogdGhlIG9uZSBpbiAiSEZ2MC43Ky5leGUiIChIZXJvIEZpZ2h0ZXIgdjAuNyssIDIw
MjEtMTAtMTEpLgpjb25zdCBIRVJPX0ZJR0hURVIgPSBuZXcgU2V0KFsnNDJhZWM1ZTY4M2JkY2Fi
ZDVjYWY2MTgxYmU1ZmU3NDYxOGFmZTUzNmVjNjIwMzA3MzRkOTUzNmZhYjE4NTJhOCddKTsKY29u
c3QgSEVST19GSUdIVEVSX01BUksgPSBCdWZmZXIuZnJvbSgnaHR0cDovL3d3dy5oZXJvZmlnaHRl
ci5jb20vdmVyLnR4dCcsICdsYXRpbjEnKTsKCmZ1bmN0aW9uIGlzU3dmKGJ5dGVzKSB7CiAgcmV0
dXJuIGJ5dGVzLmxlbmd0aCA+IDggJiYgWydGV1MnLCAnQ1dTJywgJ1pXUyddLmluY2x1ZGVzKGJ5
dGVzLnRvU3RyaW5nKCdsYXRpbjEnLCAwLCAzKSk7Cn0KCi8vIFRoZSBtb3ZpZSBvZiBhIHByb2pl
Y3RvciBvciBvZiBhIG1vdmllIGZpbGU7IG51bGwgZm9yIGFueXRoaW5nIGVsc2UuCmZ1bmN0aW9u
IG1vdmllT2YoYnl0ZXMpIHsKICBpZiAoaXNTd2YoYnl0ZXMpKSByZXR1cm4gYnl0ZXM7CiAgaWYg
KGJ5dGVzLmxlbmd0aCA8IDE2IHx8IGJ5dGVzLnRvU3RyaW5nKCdsYXRpbjEnLCAwLCAyKSAhPT0g
J01aJykgcmV0dXJuIG51bGw7CiAgaWYgKGJ5dGVzLnJlYWRVSW50MzJMRShieXRlcy5sZW5ndGgg
LSA4KSAhPT0gUFJPSkVDVE9SX01BR0lDKSByZXR1cm4gbnVsbDsKICBjb25zdCBsZW5ndGggPSBi
eXRlcy5yZWFkVUludDMyTEUoYnl0ZXMubGVuZ3RoIC0gNCk7CiAgaWYgKGxlbmd0aCA8IDkgfHwg
bGVuZ3RoID4gYnl0ZXMubGVuZ3RoIC0gOCkgcmV0dXJuIG51bGw7CiAgY29uc3QgbW92aWUgPSBi
eXRlcy5zdWJhcnJheShieXRlcy5sZW5ndGggLSA4IC0gbGVuZ3RoLCBieXRlcy5sZW5ndGggLSA4
KTsKICByZXR1cm4gaXNTd2YobW92aWUpID8gbW92aWUgOiBudWxsOwp9CgovLyBXaGljaCBnYW1l
IGEgbW92aWUgaXM6ICJoZXJvZmlnaHRlciIsIG9yICIiIGZvciBvbmUgdGhpcyByZWxheSBkb2Vz
IG5vdCBrbm93LgpmdW5jdGlvbiBmbGFzaEdhbWUobW92aWUpIHsKICBjb25zdCBzaGEyNTYgPSBj
cnlwdG8uY3JlYXRlSGFzaCgnc2hhMjU2JykudXBkYXRlKG1vdmllKS5kaWdlc3QoJ2hleCcpOwog
IGlmIChIRVJPX0ZJR0hURVIuaGFzKHNoYTI1NikpIHJldHVybiAnaGVyb2ZpZ2h0ZXInOwogIC8v
IEFuIHVuY29tcHJlc3NlZCBtb3ZpZSBjYW4gYmUgc2VhcmNoZWQgYXMgaXQgaXMgKEhlcm8gRmln
aHRlcidzIHByb2plY3RvciBtb3ZpZXMgYXJlKS4KICBpZiAobW92aWUudG9TdHJpbmcoJ2xhdGlu
MScsIDAsIDMpID09PSAnRldTJyAmJiBtb3ZpZS5pbmNsdWRlcyhIRVJPX0ZJR0hURVJfTUFSSykp
IHJldHVybiAnaGVyb2ZpZ2h0ZXInOwogIHJldHVybiAnJzsKfQoKLy8gQW4gZW50cnkncyBieXRl
cyAoc3RvcmVkIG9yIERlZmxhdGUpLgphc3luYyBmdW5jdGlvbiByZWFkRW50cnkoZmlsZSwgZW50
cnkpIHsKICBjb25zdCBoYW5kbGUgPSBhd2FpdCBmc3Aub3BlbihmaWxlLCAncicpOwogIHRyeSB7
CiAgICBjb25zdCBoZWFkZXIgPSBCdWZmZXIuYWxsb2MoMzApOwogICAgYXdhaXQgaGFuZGxlLnJl
YWQoaGVhZGVyLCAwLCAzMCwgZW50cnkubG9jYWxPZmZzZXQpOwogICAgaWYgKGhlYWRlci5yZWFk
VUludDMyTEUoMCkgIT09IDB4MDQwMzRiNTApIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAg
ZmlsZSBpcyBkYW1hZ2VkJyk7CiAgICBjb25zdCBzdGFydCA9IGVudHJ5LmxvY2FsT2Zmc2V0ICsg
MzAgKyBoZWFkZXIucmVhZFVJbnQxNkxFKDI2KSArIGhlYWRlci5yZWFkVUludDE2TEUoMjgpOwog
ICAgY29uc3QgcGFja2VkID0gQnVmZmVyLmFsbG9jKGVudHJ5LmNvbXByZXNzZWRTaXplKTsKICAg
IGF3YWl0IGhhbmRsZS5yZWFkKHBhY2tlZCwgMCwgcGFja2VkLmxlbmd0aCwgc3RhcnQpOwogICAg
aWYgKGVudHJ5Lm1ldGhvZCA9PT0gMCkgcmV0dXJuIHBhY2tlZDsKICAgIGlmIChlbnRyeS5tZXRo
b2QgPT09IDgpIHJldHVybiB6bGliLmluZmxhdGVSYXdTeW5jKHBhY2tlZCwgeyBtYXhPdXRwdXRM
ZW5ndGg6IDUxMiAqIE1JQiB9KTsKICAgIHRocm93IG5ldyBQYWNrRXJyb3IoYCR7ZW50cnkubmFt
ZX0gdXNlcyBhIGNvbXByZXNzaW9uIHRoZSByZWxheSBjYW5ub3QgcmVhZCAoemlwIGl0IGFnYWlu
IHdpdGggRGVmbGF0ZSlgKTsKICB9IGZpbmFsbHkgewogICAgYXdhaXQgaGFuZGxlLmNsb3NlKCk7
CiAgfQp9CgovLyBUaGUgRmxhc2ggbW92aWUgYW4gdXBsb2FkIGhvbGRzIChhIG1vdmllIG9yIHBy
b2plY3RvciBmaWxlLCBvciBhIFpJUCBmaWxlIHdpdGggb25lKSwgb3IgbnVsbC4KYXN5bmMgZnVu
Y3Rpb24gZmluZE1vdmllKGZpbGUsIHppcCkgewogIGlmICghemlwKSB7CiAgICBjb25zdCB7IHNp
emUgfSA9IGF3YWl0IGZzcC5zdGF0KGZpbGUpOwogICAgaWYgKHNpemUgPiA1MTIgKiBNSUIpIHJl
dHVybiBudWxsOwogICAgcmV0dXJuIG1vdmllT2YoYXdhaXQgZnNwLnJlYWRGaWxlKGZpbGUpKTsK
ICB9CiAgY29uc3QgY2FuZGlkYXRlcyA9IHppcC5lbnRyaWVzCiAgICAuZmlsdGVyKChlbnRyeSkg
PT4gL1wuKHN3ZnxleGUpJC9pLnRlc3QoZW50cnkubmFtZSkgJiYgIShlbnRyeS5mbGFncyAmIDEp
ICYmIGVudHJ5LnNpemUgPD0gNTEyICogTUlCKQogICAgLnNvcnQoKGEsIGIpID0+IGIuc2l6ZSAt
IGEuc2l6ZSk7CiAgZm9yIChjb25zdCBlbnRyeSBvZiBjYW5kaWRhdGVzKSB7CiAgICBjb25zdCBt
b3ZpZSA9IG1vdmllT2YoYXdhaXQgcmVhZEVudHJ5KGZpbGUsIGVudHJ5KSk7CiAgICBpZiAobW92
aWUpIHJldHVybiBtb3ZpZTsKICB9CiAgcmV0dXJuIG51bGw7Cn0KCi8vIFdyaXRlcyB0aGUga2Vw
dCBlbnRyaWVzIG9mIGBzb3VyY2VgIGFzIGEgbmV3IFpJUCBmaWxlLCBjb3B5aW5nIHRoZWlyIGNv
bXByZXNzZWQgYnl0ZXMgYXMgdGhleSBhcmUuCmFzeW5jIGZ1bmN0aW9uIHdyaXRlWmlwKHNvdXJj
ZSwgdGFyZ2V0LCBrZWVwKSB7CiAgY29uc3QgaW5wdXQgPSBhd2FpdCBmc3Aub3Blbihzb3VyY2Us
ICdyJyk7CiAgY29uc3Qgb3V0cHV0ID0gYXdhaXQgZnNwLm9wZW4odGFyZ2V0LCAndycpOwogIGNv
bnN0IGhhc2ggPSBjcnlwdG8uY3JlYXRlSGFzaCgnc2hhMjU2Jyk7CiAgbGV0IG9mZnNldCA9IDA7
CiAgY29uc3Qgd3JpdGUgPSBhc3luYyAoYnVmZmVyKSA9PiB7CiAgICBsZXQgZG9uZSA9IDA7CiAg
ICB3aGlsZSAoZG9uZSA8IGJ1ZmZlci5sZW5ndGgpIHsKICAgICAgY29uc3QgeyBieXRlc1dyaXR0
ZW4gfSA9IGF3YWl0IG91dHB1dC53cml0ZShidWZmZXIsIGRvbmUsIGJ1ZmZlci5sZW5ndGggLSBk
b25lLCBvZmZzZXQgKyBkb25lKTsKICAgICAgZG9uZSArPSBieXRlc1dyaXR0ZW47CiAgICB9CiAg
ICBoYXNoLnVwZGF0ZShidWZmZXIpOwogICAgb2Zmc2V0ICs9IGJ1ZmZlci5sZW5ndGg7CiAgfTsK
ICB0cnkgewogICAgY29uc3QgcmVjb3JkcyA9IFtdOwogICAgZm9yIChjb25zdCBlbnRyeSBvZiBr
ZWVwKSB7CiAgICAgIGNvbnN0IGhlYWRlciA9IEJ1ZmZlci5hbGxvYygzMCk7CiAgICAgIGF3YWl0
IGlucHV0LnJlYWQoaGVhZGVyLCAwLCAzMCwgZW50cnkubG9jYWxPZmZzZXQpOwogICAgICBpZiAo
aGVhZGVyLnJlYWRVSW50MzJMRSgwKSAhPT0gMHgwNDAzNGI1MCkgdGhyb3cgbmV3IFBhY2tFcnJv
cigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgICAgbGV0IGxlbmd0aCA9IDMwICsgaGVh
ZGVyLnJlYWRVSW50MTZMRSgyNikgKyBoZWFkZXIucmVhZFVJbnQxNkxFKDI4KSArIGVudHJ5LmNv
bXByZXNzZWRTaXplOwogICAgICBpZiAoZW50cnkuZmxhZ3MgJiA4KSB7IC8vIGEgZGF0YSBkZXNj
cmlwdG9yIGZvbGxvd3MgdGhlIGRhdGEKICAgICAgICBjb25zdCBwcm9iZSA9IEJ1ZmZlci5hbGxv
Yyg0KTsKICAgICAgICBhd2FpdCBpbnB1dC5yZWFkKHByb2JlLCAwLCA0LCBlbnRyeS5sb2NhbE9m
ZnNldCArIGxlbmd0aCk7CiAgICAgICAgbGVuZ3RoICs9IHByb2JlLnJlYWRVSW50MzJMRSgwKSA9
PT0gMHgwODA3NGI1MCA/IDE2IDogMTI7CiAgICAgIH0KICAgICAgY29uc3QgcmVjb3JkID0gQnVm
ZmVyLmZyb20oZW50cnkucmVjb3JkKTsKICAgICAgcmVjb3JkLndyaXRlVUludDMyTEUob2Zmc2V0
LCA0Mik7CiAgICAgIHJlY29yZHMucHVzaChyZWNvcmQpOwogICAgICBmb3IgKGxldCBjb3BpZWQg
PSAwOyBjb3BpZWQgPCBsZW5ndGg7KSB7CiAgICAgICAgY29uc3QgY2h1bmsgPSBCdWZmZXIuYWxs
b2MoTWF0aC5taW4oNCAqIE1JQiwgbGVuZ3RoIC0gY29waWVkKSk7CiAgICAgICAgY29uc3QgeyBi
eXRlc1JlYWQgfSA9IGF3YWl0IGlucHV0LnJlYWQoY2h1bmssIDAsIGNodW5rLmxlbmd0aCwgZW50
cnkubG9jYWxPZmZzZXQgKyBjb3BpZWQpOwogICAgICAgIGlmICghYnl0ZXNSZWFkKSB0aHJvdyBu
ZXcgUGFja0Vycm9yKCd0aGUgWklQIGZpbGUgaXMgZGFtYWdlZCcpOwogICAgICAgIGF3YWl0IHdy
aXRlKGNodW5rLnN1YmFycmF5KDAsIGJ5dGVzUmVhZCkpOwogICAgICAgIGNvcGllZCArPSBieXRl
c1JlYWQ7CiAgICAgIH0KICAgIH0KICAgIGNvbnN0IGRpcmVjdG9yeU9mZnNldCA9IG9mZnNldDsK
ICAgIGZvciAoY29uc3QgcmVjb3JkIG9mIHJlY29yZHMpIGF3YWl0IHdyaXRlKHJlY29yZCk7CiAg
ICBjb25zdCBlbmQgPSBCdWZmZXIuYWxsb2MoMjIpOwogICAgZW5kLndyaXRlVUludDMyTEUoMHgw
NjA1NGI1MCwgMCk7CiAgICBlbmQud3JpdGVVSW50MTZMRShyZWNvcmRzLmxlbmd0aCwgOCk7CiAg
ICBlbmQud3JpdGVVSW50MTZMRShyZWNvcmRzLmxlbmd0aCwgMTApOwogICAgZW5kLndyaXRlVUlu
dDMyTEUob2Zmc2V0IC0gZGlyZWN0b3J5T2Zmc2V0LCAxMik7CiAgICBlbmQud3JpdGVVSW50MzJM
RShkaXJlY3RvcnlPZmZzZXQsIDE2KTsKICAgIGF3YWl0IHdyaXRlKGVuZCk7CiAgICByZXR1cm4g
eyBzaXplOiBvZmZzZXQsIHNoYTI1NjogaGFzaC5kaWdlc3QoJ2hleCcpLCBmaWxlczogcmVjb3Jk
cy5sZW5ndGggfTsKICB9IGZpbmFsbHkgewogICAgYXdhaXQgaW5wdXQuY2xvc2UoKTsKICAgIGF3
YWl0IG91dHB1dC5jbG9zZSgpOwogIH0KfQoKZnVuY3Rpb24gc2FtZUtleShnaXZlbiwgZXhwZWN0
ZWQpIHsKICBjb25zdCBhID0gY3J5cHRvLmNyZWF0ZUhhc2goJ3NoYTI1NicpLnVwZGF0ZShTdHJp
bmcoZ2l2ZW4gfHwgJycpKS5kaWdlc3QoKTsKICBjb25zdCBiID0gY3J5cHRvLmNyZWF0ZUhhc2go
J3NoYTI1NicpLnVwZGF0ZShTdHJpbmcoZXhwZWN0ZWQpKS5kaWdlc3QoKTsKICByZXR1cm4gY3J5
cHRvLnRpbWluZ1NhZmVFcXVhbChhLCBiKTsKfQoKZnVuY3Rpb24gY3JlYXRlUGFja3MoY29uZmln
LCB7IGxvZywgY2xpZW50QWRkcmVzcywgYWxsb3dPcmlnaW4gfSkgewogIGNvbnN0IGRpcmVjdG9y
eSA9IGNvbmZpZy5wYWNrc0RpcjsKICBjb25zdCBkb3dubG9hZHMgPSBuZXcgTWFwKCk7IC8vIGNs
aWVudCBhZGRyZXNzIC0+IHsgY291bnQsIHVudGlsIH0KICBjb25zdCBmYWlsdXJlcyA9IG5ldyBN
YXAoKTsgLy8gY2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwgfQogIGxldCB1cGxvYWRp
bmcgPSBmYWxzZTsKCiAgY29uc3QganNvbiA9IChyZXMsIHN0YXR1cywgYm9keSwgaGVhZGVycyA9
IHt9KSA9PiB7CiAgICByZXMud3JpdGVIZWFkKHN0YXR1cywgeyAnY29udGVudC10eXBlJzogJ2Fw
cGxpY2F0aW9uL2pzb247IGNoYXJzZXQ9dXRmLTgnLCAnY2FjaGUtY29udHJvbCc6ICduby1zdG9y
ZScsIC4uLmhlYWRlcnMgfSk7CiAgICByZXMuZW5kKEpTT04uc3RyaW5naWZ5KGJvZHkpKTsKICB9
OwogIGNvbnN0IGNvdW50ZWQgPSAobWFwLCBhZGRyZXNzLCBsaW1pdCkgPT4gewogICAgY29uc3Qg
bm93ID0gRGF0ZS5ub3coKTsKICAgIGxldCBlbnRyeSA9IG1hcC5nZXQoYWRkcmVzcyk7CiAgICBp
ZiAoIWVudHJ5IHx8IGVudHJ5LnVudGlsIDw9IG5vdykgewogICAgICBlbnRyeSA9IHsgY291bnQ6
IDAsIHVudGlsOiBub3cgKyAzNjAwMDAwIH07CiAgICAgIG1hcC5zZXQoYWRkcmVzcywgZW50cnkp
OwogICAgfQogICAgcmV0dXJuIHsgb3ZlcjogbGltaXQgPiAwICYmIGVudHJ5LmNvdW50ID49IGxp
bWl0LCBhZGQ6ICgpID0+IHsgZW50cnkuY291bnQgKz0gMTsgfSwgcmV0cnk6IE1hdGguY2VpbCgo
ZW50cnkudW50aWwgLSBub3cpIC8gMTAwMCkgfTsKICB9OwoKICBhc3luYyBmdW5jdGlvbiBsaXN0
KCkgewogICAgaWYgKCFkaXJlY3RvcnkpIHJldHVybiBbXTsKICAgIGxldCBuYW1lczsKICAgIHRy
eSB7IG5hbWVzID0gYXdhaXQgZnNwLnJlYWRkaXIoZGlyZWN0b3J5KTsgfSBjYXRjaCB7IHJldHVy
biBbXTsgfQogICAgY29uc3QgcGFja3MgPSBbXTsKICAgIGZvciAoY29uc3QgbmFtZSBvZiBuYW1l
cykgewogICAgICBpZiAoIW5hbWUuZW5kc1dpdGgoJy5qc29uJykpIGNvbnRpbnVlOwogICAgICBj
b25zdCBpZCA9IG5hbWUuc2xpY2UoMCwgLTUpOwogICAgICBpZiAoIVBBQ0tfSUQudGVzdChpZCkp
IGNvbnRpbnVlOwogICAgICB0cnkgewogICAgICAgIGNvbnN0IGluZm8gPSBKU09OLnBhcnNlKGF3
YWl0IGZzcC5yZWFkRmlsZShwYXRoLmpvaW4oZGlyZWN0b3J5LCBuYW1lKSwgJ3V0ZjgnKSk7CiAg
ICAgICAgY29uc3Qga2luZCA9IGluZm8ua2luZCA9PT0gJ2ZsYXNoJyA/ICdmbGFzaCcgOiAnbGYy
JzsKICAgICAgICBjb25zdCBzdGF0ID0gYXdhaXQgZnNwLnN0YXQocGF0aC5qb2luKGRpcmVjdG9y
eSwgYCR7aWR9LiR7a2luZCA9PT0gJ2ZsYXNoJyA/ICdzd2YnIDogJ3ppcCd9YCkpOwogICAgICAg
IHBhY2tzLnB1c2goeyBpZCwgdGl0bGU6IFN0cmluZyhpbmZvLnRpdGxlIHx8IGlkKSwgc2l6ZTog
c3RhdC5zaXplLCBzaGEyNTY6IFN0cmluZyhpbmZvLnNoYTI1NiB8fCAnJyksCiAgICAgICAgICBr
aW5kLCBnYW1lOiBTdHJpbmcoaW5mby5nYW1lIHx8ICcnKSwgZmlsZXM6IGluZm8uZmlsZXMsIHVw
bG9hZGVkOiBpbmZvLnVwbG9hZGVkLCBvcmlnaW5hbDogaW5mby5vcmlnaW5hbCB9KTsKICAgICAg
fSBjYXRjaCB7IC8qIGEgaGFsZi13cml0dGVuIG9yIHJlbW92ZWQgcGFjayAqLyB9CiAgICB9CiAg
ICByZXR1cm4gcGFja3Muc29ydCgoYSwgYikgPT4gYS50aXRsZS5sb2NhbGVDb21wYXJlKGIudGl0
bGUpKTsKICB9CgogIGZ1bmN0aW9uIGF1dGhvcml6ZWQocmVxLCByZXMpIHsKICAgIGlmICghY29u
ZmlnLmFkbWluS2V5KSB7CiAgICAgIGpzb24ocmVzLCA0MDMsIHsgZXJyb3I6ICdDaMawYSDEkeG6
t3QgQURNSU5fS0VZIGNobyByZWxheSAoY2jhuqF5IGzhuqFpIGluc3RhbGwtdnBzLnNoKS4nIH0p
OwogICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgICBjb25zdCBhZGRyZXNzID0gY2xpZW50QWRk
cmVzcyhyZXEpOwogICAgY29uc3QgdHJpZXMgPSBjb3VudGVkKGZhaWx1cmVzLCBhZGRyZXNzLCAy
MCk7CiAgICBpZiAodHJpZXMub3ZlcikgewogICAgICBqc29uKHJlcywgNDI5LCB7IGVycm9yOiAn
U2FpIG3DoyBxdcOhIG5oaeG7gXUgbOG6p24sIHRo4butIGzhuqFpIHNhdSBt4buZdCBnaeG7nS4n
IH0sIHsgJ3JldHJ5LWFmdGVyJzogU3RyaW5nKHRyaWVzLnJldHJ5KSB9KTsKICAgICAgcmV0dXJu
IGZhbHNlOwogICAgfQogICAgaWYgKCFzYW1lS2V5KHJlcS5oZWFkZXJzWyd4LWFkbWluLWtleSdd
LCBjb25maWcuYWRtaW5LZXkpKSB7CiAgICAgIHRyaWVzLmFkZCgpOwogICAgICBqc29uKHJlcywg
NDAxLCB7IGVycm9yOiAnU2FpIG3DoyBxdeG6o24gdHLhu4sgKEFETUlOX0tFWSkuJyB9KTsKICAg
ICAgcmV0dXJuIGZhbHNlOwogICAgfQogICAgcmV0dXJuIHRydWU7CiAgfQoKICBhc3luYyBmdW5j
dGlvbiB1cGxvYWQocmVxLCByZXMsIGlkLCB0aXRsZSkgewogICAgaWYgKCFkaXJlY3RvcnkpIHJl
dHVybiBqc29uKHJlcywgNTAzLCB7IGVycm9yOiAnUmVsYXkgbsOgeSBraMO0bmcgZ2nhu68gYuG6
o24gbW9kIChjaMawYSDEkeG6t3QgUEFDS1NfRElSKS4nIH0pOwogICAgaWYgKHVwbG9hZGluZykg
cmV0dXJuIGpzb24ocmVzLCA0MDksIHsgZXJyb3I6ICfEkGFuZyBjw7MgbeG7mXQgbOG6p24gdOG6
o2kgbMOqbiBraMOhYywgY2jhu50geG9uZyBy4buTaSB0aOG7rSBs4bqhaS4nIH0pOwogICAgY29u
c3QgZGVjbGFyZWQgPSBOdW1iZXIocmVxLmhlYWRlcnNbJ2NvbnRlbnQtbGVuZ3RoJ10gfHwgMCk7
CiAgICBpZiAoZGVjbGFyZWQgPiBjb25maWcubWF4UGFja0J5dGVzKSB7CiAgICAgIHJldHVybiBq
c29uKHJlcywgNDEzLCB7IGVycm9yOiBgRmlsZSBxdcOhIGzhu5tuICh04buRaSDEkWEgJHtNYXRo
LnJvdW5kKGNvbmZpZy5tYXhQYWNrQnl0ZXMgLyBNSUIpfSBNQikuYCB9KTsKICAgIH0KICAgIGF3
YWl0IGZzcC5ta2RpcihkaXJlY3RvcnksIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwogICAgdHJ5IHsK
ICAgICAgY29uc3Qgc3BhY2UgPSBhd2FpdCBmc3Auc3RhdGZzKGRpcmVjdG9yeSk7CiAgICAgIGNv
bnN0IGZyZWUgPSBzcGFjZS5iYXZhaWwgKiBzcGFjZS5ic2l6ZTsKICAgICAgaWYgKGZyZWUgPCAy
ICogZGVjbGFyZWQgKyAyNTYgKiBNSUIpIHsKICAgICAgICByZXR1cm4ganNvbihyZXMsIDUwNywg
eyBlcnJvcjogYFZQUyBraMO0bmcgxJHhu6cgY2jhu5cgdHLhu5FuZyAoY8OybiAke01hdGgucm91
bmQoZnJlZSAvIE1JQil9IE1CKS5gIH0pOwogICAgICB9CiAgICB9IGNhdGNoIHsgLyogc3RhdGZz
IHVuYXZhaWxhYmxlOiB0cnkgYW55d2F5ICovIH0KICAgIHVwbG9hZGluZyA9IHRydWU7CiAgICBj
b25zdCBub25jZSA9IGNyeXB0by5yYW5kb21CeXRlcyg2KS50b1N0cmluZygnaGV4Jyk7CiAgICBj
b25zdCByZWNlaXZlZCA9IHBhdGguam9pbihkaXJlY3RvcnksIGAudXBsb2FkLSR7bm9uY2V9Lnpp
cGApOwogICAgY29uc3Qgc2xpbSA9IHBhdGguam9pbihkaXJlY3RvcnksIGAucGFjay0ke25vbmNl
fS56aXBgKTsKICAgIHRyeSB7CiAgICAgIGxldCBieXRlcyA9IDA7CiAgICAgIGNvbnN0IGNvdW50
ZXIgPSBuZXcgVHJhbnNmb3JtKHsKICAgICAgICB0cmFuc2Zvcm0oY2h1bmssIGVuY29kaW5nLCBk
b25lKSB7CiAgICAgICAgICBieXRlcyArPSBjaHVuay5sZW5ndGg7CiAgICAgICAgICBpZiAoYnl0
ZXMgPiBjb25maWcubWF4UGFja0J5dGVzKSBkb25lKG5ldyBQYWNrRXJyb3IoYEZpbGUgcXXDoSBs
4bubbiAodOG7kWkgxJFhICR7TWF0aC5yb3VuZChjb25maWcubWF4UGFja0J5dGVzIC8gTUlCKX0g
TUIpLmApKTsKICAgICAgICAgIGVsc2UgZG9uZShudWxsLCBjaHVuayk7CiAgICAgICAgfSwKICAg
ICAgfSk7CiAgICAgIGF3YWl0IHBpcGVsaW5lKHJlcSwgY291bnRlciwgZnMuY3JlYXRlV3JpdGVT
dHJlYW0ocmVjZWl2ZWQpKTsKICAgICAgaWYgKGRlY2xhcmVkICYmIGJ5dGVzICE9PSBkZWNsYXJl
ZCkgdGhyb3cgbmV3IFBhY2tFcnJvcignVOG6o2kgbMOqbiBi4buLIG5n4bqvdCBnaeG7r2EgY2jh
u6tuZy4nKTsKICAgICAgbGV0IHppcCA9IG51bGw7CiAgICAgIHRyeSB7IHppcCA9IGF3YWl0IHJl
YWRaaXAocmVjZWl2ZWQpOyB9IGNhdGNoIChlcnJvcikgeyBpZiAoIShlcnJvciBpbnN0YW5jZW9m
IFBhY2tFcnJvcikpIHRocm93IGVycm9yOyB9CiAgICAgIGNvbnN0IGxmMiA9IHppcCAmJiB6aXAu
ZW50cmllcy5zb21lKCh7IG5hbWUgfSkgPT4gLyhefFtcXC9dKWRhdGFbXFwvXWRhdGFcLnR4dCQv
aS50ZXN0KG5hbWUpKTsKICAgICAgaWYgKCFsZjIpIHsKICAgICAgICAvLyBBIEZsYXNoIGdhbWUs
IG9yIHdoYXQgcmVhZFppcC9hbmFseXplWmlwIHNheSB0aGlzIGlzIG5vdC4KICAgICAgICBjb25z
dCBtb3ZpZSA9IGF3YWl0IGZpbmRNb3ZpZShyZWNlaXZlZCwgemlwKTsKICAgICAgICBpZiAoIW1v
dmllKSB7CiAgICAgICAgICBpZiAoIXppcCkgdGhyb3cgbmV3IFBhY2tFcnJvcignxJDDonkga2jD
tG5nIHBo4bqjaSBmaWxlIC56aXAsIGPFqW5nIGtow7RuZyBwaOG6o2kgZ2FtZSBGbGFzaCAoLnN3
ZiBob+G6t2MgLmV4ZSBjw7MgZ2FtZSBGbGFzaCBiw6puIHRyb25nKS4nKTsKICAgICAgICAgIGFu
YWx5emVaaXAoemlwLmVudHJpZXMpOyAvLyB0aHJvd3Mgd2h5IHRoaXMgaXMgbm8gTEYyIGdhbWUg
Zm9sZGVyCiAgICAgICAgfQogICAgICAgIGNvbnN0IHNoYTI1NiA9IGNyeXB0by5jcmVhdGVIYXNo
KCdzaGEyNTYnKS51cGRhdGUobW92aWUpLmRpZ2VzdCgnaGV4Jyk7CiAgICAgICAgY29uc3QgZ2Ft
ZSA9IGZsYXNoR2FtZShtb3ZpZSk7CiAgICAgICAgYXdhaXQgZnNwLndyaXRlRmlsZShzbGltLCBt
b3ZpZSk7CiAgICAgICAgZm9yIChjb25zdCBvbGQgb2YgW2Ake2lkfS56aXBgLCBgJHtpZH0uc3dm
YF0pIGF3YWl0IGZzcC5ybShwYXRoLmpvaW4oZGlyZWN0b3J5LCBvbGQpLCB7IGZvcmNlOiB0cnVl
IH0pOwogICAgICAgIGF3YWl0IGZzcC5yZW5hbWUoc2xpbSwgcGF0aC5qb2luKGRpcmVjdG9yeSwg
YCR7aWR9LnN3ZmApKTsKICAgICAgICBjb25zdCBpbmZvID0geyB0aXRsZSwgc2hhMjU2LCBmaWxl
czogMSwga2luZDogJ2ZsYXNoJywgZ2FtZSwgdXBsb2FkZWQ6IG5ldyBEYXRlKCkudG9JU09TdHJp
bmcoKSwKICAgICAgICAgIG9yaWdpbmFsOiB7IHNpemU6IGJ5dGVzLCBmaWxlczogemlwID8gemlw
LmVudHJpZXMubGVuZ3RoIDogMSB9IH07CiAgICAgICAgYXdhaXQgZnNwLndyaXRlRmlsZShwYXRo
LmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uanNvbmApLCBKU09OLnN0cmluZ2lmeShpbmZvLCBudWxs
LCAyKSk7CiAgICAgICAgYXdhaXQgZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVlIH0pOwog
ICAgICAgIGxvZyhgcGFjayAke2lkfTogJHtieXRlc30gYnl0ZXMgdXBsb2FkZWQsIGEgRmxhc2gg
bW92aWUgb2YgJHttb3ZpZS5sZW5ndGh9IGtlcHQke2dhbWUgPyBgICgke2dhbWV9KWAgOiAnJ31g
KTsKICAgICAgICBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlLCBpZCwgdGl0bGUsIHNpemU6IG1v
dmllLmxlbmd0aCwgc2hhMjU2LCBmaWxlczogMSwgZHJvcHBlZDogaW5mby5vcmlnaW5hbC5maWxl
cyAtIDEsCiAgICAgICAgICBraW5kOiAnZmxhc2gnLCBnYW1lLCBvcmlnaW5hbDogaW5mby5vcmln
aW5hbCB9KTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgY29uc3QgYW5hbHlzaXMgPSBh
bmFseXplWmlwKHppcC5lbnRyaWVzKTsKICAgICAgY29uc3Qgd3JpdHRlbiA9IGF3YWl0IHdyaXRl
WmlwKHJlY2VpdmVkLCBzbGltLCBhbmFseXNpcy5rZWVwKTsKICAgICAgYXdhaXQgZnNwLnJtKHBh
dGguam9pbihkaXJlY3RvcnksIGAke2lkfS5zd2ZgKSwgeyBmb3JjZTogdHJ1ZSB9KTsKICAgICAg
YXdhaXQgZnNwLnJlbmFtZShzbGltLCBwYXRoLmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uemlwYCkp
OwogICAgICBjb25zdCBpbmZvID0geyB0aXRsZSwgc2hhMjU2OiB3cml0dGVuLnNoYTI1NiwgZmls
ZXM6IHdyaXR0ZW4uZmlsZXMsIGV4ZWN1dGFibGU6IGFuYWx5c2lzLmV4ZWN1dGFibGUsCiAgICAg
ICAgdXBsb2FkZWQ6IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKSwgb3JpZ2luYWw6IHsgc2l6ZTog
Ynl0ZXMsIGZpbGVzOiB6aXAuZW50cmllcy5sZW5ndGggfSB9OwogICAgICBhd2FpdCBmc3Aud3Jp
dGVGaWxlKHBhdGguam9pbihkaXJlY3RvcnksIGAke2lkfS5qc29uYCksIEpTT04uc3RyaW5naWZ5
KGluZm8sIG51bGwsIDIpKTsKICAgICAgYXdhaXQgZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0
cnVlIH0pOwogICAgICBsb2coYHBhY2sgJHtpZH06ICR7Ynl0ZXN9IGJ5dGVzIHVwbG9hZGVkLCAk
e3dyaXR0ZW4uc2l6ZX0ga2VwdCAoJHt3cml0dGVuLmZpbGVzfSBmaWxlcylgKTsKICAgICAganNv
bihyZXMsIDIwMCwgeyBvazogdHJ1ZSwgaWQsIHRpdGxlLCBzaXplOiB3cml0dGVuLnNpemUsIHNo
YTI1Njogd3JpdHRlbi5zaGEyNTYsIGZpbGVzOiB3cml0dGVuLmZpbGVzLAogICAgICAgIGRyb3Bw
ZWQ6IGFuYWx5c2lzLmRyb3BwZWQsIGV4ZWN1dGFibGU6IGFuYWx5c2lzLmV4ZWN1dGFibGUsIG9y
aWdpbmFsOiBpbmZvLm9yaWdpbmFsIH0pOwogICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgYXdh
aXQgZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVlIH0pOwogICAgICBhd2FpdCBmc3Aucm0o
c2xpbSwgeyBmb3JjZTogdHJ1ZSB9KTsKICAgICAgY29uc3QgbWVzc2FnZSA9IGVycm9yIGluc3Rh
bmNlb2YgUGFja0Vycm9yID8gZXJyb3IubWVzc2FnZSA6ICdLaMO0bmcgbMawdSDEkcaw4bujYyBm
aWxlOiAnICsgKGVycm9yLm1lc3NhZ2UgfHwgZXJyb3IpOwogICAgICBpZiAoIXJlcy5oZWFkZXJz
U2VudCkganNvbihyZXMsIGVycm9yIGluc3RhbmNlb2YgUGFja0Vycm9yID8gNDAwIDogNTAwLCB7
IGVycm9yOiBtZXNzYWdlIH0pOwogICAgfSBmaW5hbGx5IHsKICAgICAgdXBsb2FkaW5nID0gZmFs
c2U7CiAgICB9CiAgfQoKICBhc3luYyBmdW5jdGlvbiBzZXJ2ZVBhY2socmVxLCByZXMsIGlkLCBl
eHRlbnNpb24gPSAnemlwJykgewogICAgY29uc3QgaGVhZGVycyA9IHsgJ3gtY29udGVudC10eXBl
LW9wdGlvbnMnOiAnbm9zbmlmZicsIC4uLmFsbG93T3JpZ2luKHJlcSkgfTsKICAgIGlmIChyZXEu
bWV0aG9kICE9PSAnR0VUJyAmJiByZXEubWV0aG9kICE9PSAnSEVBRCcpIHsKICAgICAgcmVzLndy
aXRlSGVhZCg0MDUsIHsgLi4uaGVhZGVycywgYWxsb3c6ICdHRVQsIEhFQUQnIH0pOwogICAgICBy
ZXMuZW5kKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGZpbGUgPSBwYXRoLmpvaW4o
ZGlyZWN0b3J5IHx8ICcvbm9uZXhpc3RlbnQnLCBgJHtpZH0uJHtleHRlbnNpb259YCk7CiAgICBs
ZXQgc3RhdDsKICAgIHRyeSB7IHN0YXQgPSBhd2FpdCBmc3Auc3RhdChmaWxlKTsgfSBjYXRjaCB7
IHN0YXQgPSBudWxsOyB9CiAgICBpZiAoIWRpcmVjdG9yeSB8fCAhc3RhdCB8fCAhc3RhdC5pc0Zp
bGUoKSkgewogICAgICByZXMud3JpdGVIZWFkKDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQo
KTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHJlcS5tZXRob2QgPT09ICdHRVQnKSB7CiAg
ICAgIGNvbnN0IHF1b3RhID0gY291bnRlZChkb3dubG9hZHMsIGNsaWVudEFkZHJlc3MocmVxKSwg
Y29uZmlnLnBhY2tEb3dubG9hZHNQZXJIb3VyKTsKICAgICAgaWYgKHF1b3RhLm92ZXIpIHsKICAg
ICAgICByZXMud3JpdGVIZWFkKDQyOSwgeyAuLi5oZWFkZXJzLCAncmV0cnktYWZ0ZXInOiBTdHJp
bmcocXVvdGEucmV0cnkpIH0pOwogICAgICAgIHJlcy5lbmQoKTsKICAgICAgICByZXR1cm47CiAg
ICAgIH0KICAgICAgcXVvdGEuYWRkKCk7CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAu
Li5oZWFkZXJzLCAnY29udGVudC10eXBlJzogZXh0ZW5zaW9uID09PSAnc3dmJyA/ICdhcHBsaWNh
dGlvbi94LXNob2Nrd2F2ZS1mbGFzaCcgOiAnYXBwbGljYXRpb24vemlwJywKICAgICAgJ2NvbnRl
bnQtbGVuZ3RoJzogU3RyaW5nKHN0YXQuc2l6ZSksCiAgICAgICdjYWNoZS1jb250cm9sJzogJ25v
LWNhY2hlJyB9KTsKICAgIGlmIChyZXEubWV0aG9kID09PSAnSEVBRCcpIHsKICAgICAgcmVzLmVu
ZCgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFk
U3RyZWFtKGZpbGUpOwogICAgc3RyZWFtLm9uKCdlcnJvcicsICgpID0+IHJlcy5kZXN0cm95KCkp
OwogICAgc3RyZWFtLnBpcGUocmVzKTsKICB9CgogIC8vIFJldHVybnMgdHJ1ZSB3aGVuIHRoZSBy
ZXF1ZXN0IHdhcyBvbmUgb2YgdGhlIHBhY2tzJyBhbmQgaGFzIGJlZW4gYW5zd2VyZWQgKG9yIGlz
IGJlaW5nIGFuc3dlcmVkKS4KICBmdW5jdGlvbiBoYW5kbGUocmVxLCByZXMsIHBhdGhuYW1lKSB7
CiAgICBpZiAocGF0aG5hbWUgPT09ICcvbGYyLXBhY2tzLmpzb24nKSB7CiAgICAgIGxpc3QoKS50
aGVuKChwYWNrcykgPT4ganNvbihyZXMsIDIwMCwgeyBwYWNrczogcGFja3MubWFwKCh7IGlkLCB0
aXRsZSwgc2l6ZSwgc2hhMjU2LCBraW5kLCBnYW1lIH0pID0+ICh7IGlkLCB0aXRsZSwgc2l6ZSwg
c2hhMjU2LCBraW5kLCBnYW1lIH0pKSB9LAogICAgICAgIHsgJ2FjY2Vzcy1jb250cm9sLWFsbG93
LW9yaWdpbic6ICcqJyB9KSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgY29uc3QgcGFj
ayA9IHBhdGhuYW1lLm1hdGNoKC9eXC9sZjItcGFja3NcLyhbYS16MC05XVthLXowLTktXXswLDM5
fSlcLih6aXB8c3dmKSQvKTsKICAgIGlmIChwYWNrKSB7CiAgICAgIHNlcnZlUGFjayhyZXEsIHJl
cywgcGFja1sxXSwgcGFja1syXSkuY2F0Y2goKCkgPT4gcmVzLmRlc3Ryb3koKSk7CiAgICAgIHJl
dHVybiB0cnVlOwogICAgfQogICAgaWYgKHBhdGhuYW1lID09PSAnL2FkbWluJyB8fCBwYXRobmFt
ZSA9PT0gJy9hZG1pbi8nKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdjb250ZW50LXR5
cGUnOiAndGV4dC9odG1sOyBjaGFyc2V0PXV0Zi04JywgJ2NhY2hlLWNvbnRyb2wnOiAnbm8tc3Rv
cmUnLAogICAgICAgICd4LWZyYW1lLW9wdGlvbnMnOiAnREVOWScsICdyZWZlcnJlci1wb2xpY3kn
OiAnbm8tcmVmZXJyZXInIH0pOwogICAgICByZXMuZW5kKEFETUlOX1BBR0UpOwogICAgICByZXR1
cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChwYXRobmFtZSA9PT0gJy9hZG1pbi9hcGkvcGFja3MnICYm
IHJlcS5tZXRob2QgPT09ICdHRVQnKSB7CiAgICAgIGlmIChhdXRob3JpemVkKHJlcSwgcmVzKSkg
bGlzdCgpLnRoZW4oKHBhY2tzKSA9PiBqc29uKHJlcywgMjAwLCB7IHBhY2tzLCBtYXhCeXRlczog
Y29uZmlnLm1heFBhY2tCeXRlcyB9KSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgY29u
c3QgbWFuYWdlZCA9IHBhdGhuYW1lLm1hdGNoKC9eXC9hZG1pblwvYXBpXC9wYWNrc1wvKFteL10q
KSQvKTsKICAgIGlmIChtYW5hZ2VkKSB7CiAgICAgIGNvbnN0IGlkID0gbWFuYWdlZFsxXTsKICAg
ICAgaWYgKCFQQUNLX0lELnRlc3QoaWQpKSB7CiAgICAgICAganNvbihyZXMsIDQwMCwgeyBlcnJv
cjogJ03DoyBuZ+G6r24gY2jhu4kgZ+G7k20gY2jhu68gdGjGsOG7nW5nIGEteiwgc+G7kSB2w6Ag
ZOG6pXUgZ+G6oWNoIG5nYW5nICh04buRaSDEkWEgNDAga8O9IHThu7EpLicgfSk7CiAgICAgICAg
cmV0dXJuIHRydWU7CiAgICAgIH0KICAgICAgaWYgKHJlcS5tZXRob2QgPT09ICdQVVQnKSB7CiAg
ICAgICAgaWYgKCFhdXRob3JpemVkKHJlcSwgcmVzKSkgeyByZXEucmVzdW1lKCk7IHJldHVybiB0
cnVlOyB9CiAgICAgICAgY29uc3QgdGl0bGUgPSBTdHJpbmcobmV3IFVSTChyZXEudXJsLCAnaHR0
cDovL3JlbGF5LmludmFsaWQnKS5zZWFyY2hQYXJhbXMuZ2V0KCd0aXRsZScpIHx8IGlkKS50cmlt
KCkuc2xpY2UoMCwgNjApIHx8IGlkOwogICAgICAgIHVwbG9hZChyZXEsIHJlcywgaWQsIHRpdGxl
KS5jYXRjaCgoKSA9PiByZXMuZGVzdHJveSgpKTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAg
fQogICAgICBpZiAocmVxLm1ldGhvZCA9PT0gJ0RFTEVURScpIHsKICAgICAgICBpZiAoIWF1dGhv
cml6ZWQocmVxLCByZXMpKSByZXR1cm4gdHJ1ZTsKICAgICAgICBQcm9taXNlLmFsbChbYCR7aWR9
LnppcGAsIGAke2lkfS5zd2ZgLCBgJHtpZH0uanNvbmBdLm1hcCgobmFtZSkgPT4gZnNwLnJtKHBh
dGguam9pbihkaXJlY3RvcnkgfHwgJy9ub25leGlzdGVudCcsIG5hbWUpLCB7IGZvcmNlOiB0cnVl
IH0pKSkKICAgICAgICAgIC50aGVuKCgpID0+IHsgbG9nKGBwYWNrICR7aWR9OiByZW1vdmVkYCk7
IGpzb24ocmVzLCAyMDAsIHsgb2s6IHRydWUgfSk7IH0pCiAgICAgICAgICAuY2F0Y2goKGVycm9y
KSA9PiBqc29uKHJlcywgNTAwLCB7IGVycm9yOiBTdHJpbmcoZXJyb3IubWVzc2FnZSB8fCBlcnJv
cikgfSkpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAgICAgIGpzb24ocmVzLCA0MDUs
IHsgZXJyb3I6ICdtZXRob2Qgbm90IGFsbG93ZWQnIH0sIHsgYWxsb3c6ICdQVVQsIERFTEVURScg
fSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KCiAgcmV0
dXJuIHsgaGFuZGxlLCBsaXN0LCBjbGVhbnVwOiAoKSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRl
Lm5vdygpOwogICAgZm9yIChjb25zdCBtYXAgb2YgW2Rvd25sb2FkcywgZmFpbHVyZXNdKSBmb3Ig
KGNvbnN0IFtrZXksIGVudHJ5XSBvZiBtYXApIGlmIChlbnRyeS51bnRpbCA8PSBub3cpIG1hcC5k
ZWxldGUoa2V5KTsKICB9IH07Cn0KCi8vIFRoZSBwYWdlIGF0IC9hZG1pbiAoVmlldG5hbWVzZTog
dGhlIHJlbGF5J3Mgb3duZXIgcmVhZHMgaXQpLgpjb25zdCBBRE1JTl9QQUdFID0gYDwhZG9jdHlw
ZSBodG1sPgo8aHRtbCBsYW5nPSJ2aSI+PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPjxtZXRh
IG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2Nh
bGU9MSI+Cjx0aXRsZT5PcGVuTEYyIHJlbGF5OiBi4bqjbiBtb2Q8L3RpdGxlPgo8c3R5bGU+CiAg
Ym9keSB7IG1hcmdpbjogMDsgcGFkZGluZzogMS41cmVtOyBiYWNrZ3JvdW5kOiAjMTExODI3OyBj
b2xvcjogI2YzZjRmNjsgZm9udDogMTZweC8xLjUgc3lzdGVtLXVpLCBzYW5zLXNlcmlmOyB9CiAg
bWFpbiB7IG1heC13aWR0aDogNzYwcHg7IG1hcmdpbjogYXV0bzsgfQogIGgxIHsgZm9udC1zaXpl
OiAxLjVyZW07IG1hcmdpbjogMCAwIC4yNXJlbTsgfQogIC5jYXJkIHsgYmFja2dyb3VuZDogIzFm
MjkzNzsgYm9yZGVyOiAxcHggc29saWQgIzM3NDE1MTsgYm9yZGVyLXJhZGl1czogMTJweDsgcGFk
ZGluZzogMXJlbSAxLjJyZW07IG1hcmdpbjogMXJlbSAwOyB9CiAgbGFiZWwgeyBkaXNwbGF5OiBi
bG9jazsgbWFyZ2luOiAuNnJlbSAwIC4ycmVtOyBmb250LXdlaWdodDogNjAwOyB9CiAgaW5wdXRb
dHlwZT10ZXh0XSwgaW5wdXRbdHlwZT1wYXNzd29yZF0geyB3aWR0aDogMTAwJTsgYm94LXNpemlu
ZzogYm9yZGVyLWJveDsgcGFkZGluZzogLjVyZW0gLjZyZW07IGZvbnQ6IGluaGVyaXQ7CiAgICBi
b3JkZXItcmFkaXVzOiA4cHg7IGJvcmRlcjogMXB4IHNvbGlkICM0YjU1NjM7IGJhY2tncm91bmQ6
ICMwYjEyMjA7IGNvbG9yOiBpbmhlcml0OyB9CiAgYnV0dG9uIHsgcGFkZGluZzogLjU1cmVtIDEu
MXJlbTsgZm9udDogaW5oZXJpdDsgYm9yZGVyLXJhZGl1czogOHB4OyBib3JkZXI6IDA7IGN1cnNv
cjogcG9pbnRlcjsgYmFja2dyb3VuZDogI2Y1OWUwYjsgY29sb3I6ICMxZjEzMDA7IGZvbnQtd2Vp
Z2h0OiA3MDA7IH0KICBidXR0b24uc2Vjb25kYXJ5IHsgYmFja2dyb3VuZDogIzM3NDE1MTsgY29s
b3I6ICNmM2Y0ZjY7IGZvbnQtd2VpZ2h0OiA1MDA7IH0KICBidXR0b246ZGlzYWJsZWQgeyBvcGFj
aXR5OiAuNTsgY3Vyc29yOiBkZWZhdWx0OyB9CiAgcHJvZ3Jlc3MgeyB3aWR0aDogMTAwJTsgaGVp
Z2h0OiAuOHJlbTsgbWFyZ2luLXRvcDogLjhyZW07IH0KICAubm90ZSB7IGNvbG9yOiAjOWNhM2Fm
OyBmb250LXNpemU6IC45cmVtOyB9CiAgLm9rIHsgY29sb3I6ICM2ZWU3Yjc7IH0gLmJhZCB7IGNv
bG9yOiAjZmNhNWE1OyB9CiAgdGFibGUgeyB3aWR0aDogMTAwJTsgYm9yZGVyLWNvbGxhcHNlOiBj
b2xsYXBzZTsgfSB0ZCwgdGggeyB0ZXh0LWFsaWduOiBsZWZ0OyBwYWRkaW5nOiAuNHJlbSAuM3Jl
bTsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkICMzNzQxNTE7IHZlcnRpY2FsLWFsaWduOiB0b3A7
IH0KICBjb2RlIHsgYmFja2dyb3VuZDogIzBiMTIyMDsgcGFkZGluZzogLjA1cmVtIC4zcmVtOyBi
b3JkZXItcmFkaXVzOiA0cHg7IH0KPC9zdHlsZT48L2hlYWQ+Cjxib2R5PjxtYWluPgogIDxoMT5C
4bqjbiBtb2QgY2hvIE9wZW5MRjI8L2gxPgogIDxwIGNsYXNzPSJub3RlIj5U4bqjaSBsw6puIG3h
u5l0IGZpbGUgLnppcCBjaOG7qWEgY+G6oyB0aMawIG3hu6VjIGdhbWUgY+G7p2EgYuG6o24gbW9k
IChjw7MgZmlsZSAuZXhlIHbDoCB0aMawIG3hu6VjIGRhdGEsIHNwcml0ZSwgYmdtLCBiZykuCiAg
ICBSZWxheSBjaOG7iSBnaeG7ryBs4bqhaSBwaOG6p24gZ2FtZSBj4bqnbiwgcuG7k2kgcGjDoXQg
Y2hvIHRyw6xuaCBkdXnhu4d0IGPhu6dhIG5nxrDhu51pIGNoxqFpLiBBaSBjxaluZyBjaOG7jW4g
Y8O5bmcgbeG7mXQgYuG6o24gbW9kIG3hu5tpIHbDoG8gY2h1bmcgcGjDsm5nIMSRxrDhu6NjLjwv
cD4KICA8cCBjbGFzcz0ibm90ZSI+R2FtZSBIZXJvIEZpZ2h0ZXIgY8WpbmcgdOG6o2kgbMOqbiDh
u58gxJHDonk6IGZpbGUgPGNvZGU+SEZ2MC43LnppcDwvY29kZT4gKGhv4bq3YyA8Y29kZT5IRnYw
LjcrLmV4ZTwvY29kZT4pLiBSZWxheSBnaeG7ryBwaOG6p24gZ2FtZSBGbGFzaCBiw6puIHRyb25n
OwogICAgdHLDqm4gdHJhbmcgZ2FtZSwgY2jhu41uIDxiPkhlcm8gRmlnaHRlcjwvYj4g4bufIG3h
u6VjIEdhbWUuPC9wPgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGxhYmVsIGZvcj0ia2V5Ij5N
w6MgcXXhuqNuIHRy4buLIChBRE1JTl9LRVkpPC9sYWJlbD4KICAgIDxpbnB1dCBpZD0ia2V5IiB0
eXBlPSJwYXNzd29yZCIgYXV0b2NvbXBsZXRlPSJjdXJyZW50LXBhc3N3b3JkIiBwbGFjZWhvbGRl
cj0iaW4gcmEga2hpIGNo4bqheSBpbnN0YWxsLXZwcy5zaCI+CiAgICA8bGFiZWwgZm9yPSJmaWxl
Ij5GaWxlIC56aXAgY+G7p2EgYuG6o24gbW9kPC9sYWJlbD4KICAgIDxpbnB1dCBpZD0iZmlsZSIg
dHlwZT0iZmlsZSIgYWNjZXB0PSIuemlwLC5leGUsLnN3ZixhcHBsaWNhdGlvbi96aXAiPgogICAg
PGxhYmVsIGZvcj0idGl0bGUiPlTDqm4gaGnhu4NuIHRo4buLIHRyw6puIHRyYW5nIGdhbWU8L2xh
YmVsPgogICAgPGlucHV0IGlkPSJ0aXRsZSIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI2MCIgcGxh
Y2Vob2xkZXI9InbDrSBk4bulOiBPbmUgUGllY2UgR3JhbmRXb3JsZCI+CiAgICA8bGFiZWwgZm9y
PSJpZCI+TcOjIG5n4bqvbiAoZMO5bmcgdHJvbmcgbGluayBt4budaSk8L2xhYmVsPgogICAgPGlu
cHV0IGlkPSJpZCIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI0MCIgcGxhY2Vob2xkZXI9InbDrSBk
4bulOiBvbmVwaWVjZSIgcGF0dGVybj0iW2EtejAtOV1bYS16MC05LV0qIj4KICAgIDxwPjxidXR0
b24gaWQ9InVwbG9hZCI+VOG6o2kgbMOqbjwvYnV0dG9uPjwvcD4KICAgIDxwcm9ncmVzcyBpZD0i
cHJvZ3Jlc3MiIGhpZGRlbj48L3Byb2dyZXNzPgogICAgPHAgaWQ9InN0YXR1cyIgcm9sZT0ic3Rh
dHVzIiBjbGFzcz0ibm90ZSI+PC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAg
PGgyIHN0eWxlPSJmb250LXNpemU6MS4xNXJlbTttYXJnaW46MCAwIC41cmVtIj5Dw6FjIGLhuqNu
IG1vZCB0csOqbiByZWxheTwvaDI+CiAgICA8cD48YnV0dG9uIGlkPSJyZWZyZXNoIiBjbGFzcz0i
c2Vjb25kYXJ5Ij5YZW0gZGFuaCBzw6FjaDwvYnV0dG9uPjwvcD4KICAgIDx0YWJsZT48dGJvZHkg
aWQ9Imxpc3QiPjwvdGJvZHk+PC90YWJsZT4KICA8L2Rpdj4KPC9tYWluPgo8c2NyaXB0PgogIGNv
bnN0ICQgPSAoaWQpID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBjb25zdCBhcGkg
PSBsb2NhdGlvbi5wYXRobmFtZS5yZXBsYWNlKC9cXC8/JC8sICcvJykgKyAnYXBpL3BhY2tzJzsK
ICB0cnkgeyAkKCdrZXknKS52YWx1ZSA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKCdsZjItYWRtaW4t
a2V5JykgfHwgJyc7IH0gY2F0Y2ggKGVycm9yKSB7fQogIGNvbnN0IHJlbWVtYmVyID0gKCkgPT4g
eyB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnbGYyLWFkbWluLWtleScsICQoJ2tleScpLnZh
bHVlKTsgfSBjYXRjaCAoZXJyb3IpIHt9IH07CiAgY29uc3Qgc2x1ZyA9ICh0ZXh0KSA9PiB0ZXh0
LnRvTG93ZXJDYXNlKCkubm9ybWFsaXplKCdORkQnKS5yZXBsYWNlKC9bXFx1MDMwMC1cXHUwMzZm
XS9nLCAnJykucmVwbGFjZSgvxJEvZywgJ2QnKQogICAgLnJlcGxhY2UoL1teYS16MC05XSsvZywg
Jy0nKS5yZXBsYWNlKC9eLSt8LSskL2csICcnKS5zbGljZSgwLCA0MCkgfHwgJ21vZCc7CiAgJCgn
ZmlsZScpLmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsICgpID0+IHsKICAgIGNvbnN0IGZpbGUg
PSAkKCdmaWxlJykuZmlsZXNbMF07CiAgICBpZiAoIWZpbGUpIHJldHVybjsKICAgIGxldCBuYW1l
ID0gZmlsZS5uYW1lLnJlcGxhY2UoL1xcLih6aXB8ZXhlfHN3ZikkL2ksICcnKS5yZXBsYWNlKC9b
X10rL2csICcgJykudHJpbSgpOwogICAgaWYgKC9eaGYgP3Y/MFxcLjcvaS50ZXN0KG5hbWUpKSBu
YW1lID0gJ0hlcm8gRmlnaHRlciB2MC43Kyc7CiAgICBpZiAoISQoJ3RpdGxlJykudmFsdWUpICQo
J3RpdGxlJykudmFsdWUgPSBuYW1lOwogICAgaWYgKCEkKCdpZCcpLnZhbHVlKSAkKCdpZCcpLnZh
bHVlID0gc2x1ZyhuYW1lKTsKICB9KTsKICAkKCd0aXRsZScpLmFkZEV2ZW50TGlzdGVuZXIoJ2lu
cHV0JywgKCkgPT4geyBpZiAoISQoJ2lkJykuZGF0YXNldC50b3VjaGVkKSAkKCdpZCcpLnZhbHVl
ID0gc2x1ZygkKCd0aXRsZScpLnZhbHVlKTsgfSk7CiAgJCgnaWQnKS5hZGRFdmVudExpc3RlbmVy
KCdpbnB1dCcsICgpID0+IHsgJCgnaWQnKS5kYXRhc2V0LnRvdWNoZWQgPSAnMSc7IH0pOwogIGNv
bnN0IG1iID0gKGJ5dGVzKSA9PiAoYnl0ZXMgLyAxZTYpLnRvRml4ZWQoMSkgKyAnIE1CJzsKICBm
dW5jdGlvbiBzdGF0dXModGV4dCwga2luZCkgeyAkKCdzdGF0dXMnKS50ZXh0Q29udGVudCA9IHRl
eHQ7ICQoJ3N0YXR1cycpLmNsYXNzTmFtZSA9IGtpbmQgfHwgJ25vdGUnOyB9CiAgJCgndXBsb2Fk
JykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgICBjb25zdCBmaWxlID0gJCgn
ZmlsZScpLmZpbGVzWzBdOwogICAgY29uc3QgaWQgPSAkKCdpZCcpLnZhbHVlLnRyaW0oKTsKICAg
IGlmICghJCgna2V5JykudmFsdWUpIHJldHVybiBzdGF0dXMoJ05o4bqtcCBtw6MgcXXhuqNuIHRy
4buLIHRyxrDhu5tjLicsICdiYWQnKTsKICAgIGlmICghZmlsZSkgcmV0dXJuIHN0YXR1cygnQ2jh
u41uIGZpbGUgLnppcCB0csaw4bubYy4nLCAnYmFkJyk7CiAgICBpZiAoIS9eW2EtejAtOV1bYS16
MC05LV17MCwzOX0kLy50ZXN0KGlkKSkgcmV0dXJuIHN0YXR1cygnTcOjIG5n4bqvbiBjaOG7iSBn
4buTbSBjaOG7ryB0aMaw4budbmcgYS16LCBz4buRIHbDoCBk4bqldSBn4bqhY2ggbmdhbmcuJywg
J2JhZCcpOwogICAgcmVtZW1iZXIoKTsKICAgIGNvbnN0IHJlcXVlc3QgPSBuZXcgWE1MSHR0cFJl
cXVlc3QoKTsKICAgIHJlcXVlc3Qub3BlbignUFVUJywgYXBpICsgJy8nICsgaWQgKyAnP3RpdGxl
PScgKyBlbmNvZGVVUklDb21wb25lbnQoJCgndGl0bGUnKS52YWx1ZS50cmltKCkgfHwgaWQpKTsK
ICAgIHJlcXVlc3Quc2V0UmVxdWVzdEhlYWRlcigneC1hZG1pbi1rZXknLCAkKCdrZXknKS52YWx1
ZSk7CiAgICByZXF1ZXN0LnNldFJlcXVlc3RIZWFkZXIoJ2NvbnRlbnQtdHlwZScsICdhcHBsaWNh
dGlvbi96aXAnKTsKICAgICQoJ3Byb2dyZXNzJykuaGlkZGVuID0gZmFsc2U7CiAgICAkKCd1cGxv
YWQnKS5kaXNhYmxlZCA9IHRydWU7CiAgICByZXF1ZXN0LnVwbG9hZC5vbnByb2dyZXNzID0gKGV2
ZW50KSA9PiB7CiAgICAgIGlmICghZXZlbnQubGVuZ3RoQ29tcHV0YWJsZSkgcmV0dXJuOwogICAg
ICAkKCdwcm9ncmVzcycpLm1heCA9IGV2ZW50LnRvdGFsOwogICAgICAkKCdwcm9ncmVzcycpLnZh
bHVlID0gZXZlbnQubG9hZGVkOwogICAgICBzdGF0dXMoJ8SQYW5nIHThuqNpIGzDqm46ICcgKyBt
YihldmVudC5sb2FkZWQpICsgJyAvICcgKyBtYihldmVudC50b3RhbCkgKyAoZXZlbnQubG9hZGVk
ID09PSBldmVudC50b3RhbCA/ICcgKHJlbGF5IMSRYW5nIHjhu60gbMO9Li4uKScgOiAnJykpOwog
ICAgfTsKICAgIHJlcXVlc3Qub25sb2FkID0gKCkgPT4gewogICAgICAkKCd1cGxvYWQnKS5kaXNh
YmxlZCA9IGZhbHNlOwogICAgICAkKCdwcm9ncmVzcycpLmhpZGRlbiA9IHRydWU7CiAgICAgIGxl
dCBib2R5ID0ge307CiAgICAgIHRyeSB7IGJvZHkgPSBKU09OLnBhcnNlKHJlcXVlc3QucmVzcG9u
c2VUZXh0KTsgfSBjYXRjaCAoZXJyb3IpIHt9CiAgICAgIGlmIChyZXF1ZXN0LnN0YXR1cyA9PT0g
MjAwKSB7CiAgICAgICAgaWYgKGJvZHkua2luZCA9PT0gJ2ZsYXNoJykgewogICAgICAgICAgc3Rh
dHVzKCdYb25nOiAiJyArIGJvZHkudGl0bGUgKyAnIiAoZ2FtZSBGbGFzaCwgJyArIG1iKGJvZHku
c2l6ZSkgKyAnKS4gJwogICAgICAgICAgICArIChib2R5LmdhbWUgPT09ICdoZXJvZmlnaHRlcicg
PyAnVHLDqm4gdHJhbmcgZ2FtZSwgY2jhu41uIEhlcm8gRmlnaHRlciDhu58gbeG7pWMgR2FtZS4n
IDogJ8SQw6J5IGtow7RuZyBwaOG6o2kgSGVybyBGaWdodGVyOiB0cmFuZyBnYW1lIGNoxrBhIGNo
xqFpIMSRxrDhu6NjIGdhbWUgbsOgeS4nKSwgYm9keS5nYW1lID8gJ29rJyA6ICdiYWQnKTsKICAg
ICAgICB9IGVsc2UgewogICAgICAgICAgc3RhdHVzKCdYb25nOiAiJyArIGJvZHkudGl0bGUgKyAn
IiAoJyArIG1iKGJvZHkuc2l6ZSkgKyAnLCAnICsgYm9keS5maWxlcyArICcgZmlsZSwgYuG7jyBi
4bubdCAnICsgYm9keS5kcm9wcGVkICsgJyBmaWxlIGtow7RuZyBj4bqnbikuICcKICAgICAgICAg
ICAgKyAnVHLDqm4gdHJhbmcgZ2FtZSwgY2jhu41uIG7DsyDhu58gbeG7pWMgR2FtZSwgaG/hurdj
IGfhu61pIGxpbmsgbeG7nWkgY8OzIHRow6ptICZwYWNrPScgKyBib2R5LmlkICsgJy4nLCAnb2sn
KTsKICAgICAgICB9CiAgICAgICAgcmVmcmVzaCgpOwogICAgICB9IGVsc2Ugc3RhdHVzKCdLaMO0
bmcgxJHGsOG7o2M6ICcgKyAoYm9keS5lcnJvciB8fCAoJ2zhu5dpICcgKyByZXF1ZXN0LnN0YXR1
cykpLCAnYmFkJyk7CiAgICB9OwogICAgcmVxdWVzdC5vbmVycm9yID0gKCkgPT4geyAkKCd1cGxv
YWQnKS5kaXNhYmxlZCA9IGZhbHNlOyAkKCdwcm9ncmVzcycpLmhpZGRlbiA9IHRydWU7IHN0YXR1
cygnTeG6pXQga+G6v3QgbuG7kWkga2hpIHThuqNpIGzDqm4uJywgJ2JhZCcpOyB9OwogICAgcmVx
dWVzdC5zZW5kKGZpbGUpOwogIH0pOwogIGFzeW5jIGZ1bmN0aW9uIHJlZnJlc2goKSB7CiAgICBp
ZiAoISQoJ2tleScpLnZhbHVlKSByZXR1cm4gc3RhdHVzKCdOaOG6rXAgbcOjIHF14bqjbiB0cuG7
iyDEkeG7gyB4ZW0gZGFuaCBzw6FjaC4nLCAnYmFkJyk7CiAgICByZW1lbWJlcigpOwogICAgY29u
c3QgcmVzcG9uc2UgPSBhd2FpdCBmZXRjaChhcGksIHsgaGVhZGVyczogeyAneC1hZG1pbi1rZXkn
OiAkKCdrZXknKS52YWx1ZSB9IH0pOwogICAgY29uc3QgYm9keSA9IGF3YWl0IHJlc3BvbnNlLmpz
b24oKS5jYXRjaCgoKSA9PiAoe30pKTsKICAgIGlmICghcmVzcG9uc2Uub2spIHJldHVybiBzdGF0
dXMoYm9keS5lcnJvciB8fCAoJ2zhu5dpICcgKyByZXNwb25zZS5zdGF0dXMpLCAnYmFkJyk7CiAg
ICBjb25zdCBsaXN0ID0gJCgnbGlzdCcpOwogICAgbGlzdC50ZXh0Q29udGVudCA9ICcnOwogICAg
aWYgKCFib2R5LnBhY2tzLmxlbmd0aCkgbGlzdC5pbm5lckhUTUwgPSAnPHRyPjx0ZCBjbGFzcz0i
bm90ZSI+Q2jGsGEgY8OzIGLhuqNuIG1vZCBuw6BvLjwvdGQ+PC90cj4nOwogICAgZm9yIChjb25z
dCBwYWNrIG9mIGJvZHkucGFja3MpIHsKICAgICAgY29uc3Qgcm93ID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgndHInKTsKICAgICAgY29uc3QgaW5mbyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J3RkJyk7CiAgICAgIGluZm8uaW5uZXJIVE1MID0gJzxiPjwvYj48YnI+PHNwYW4gY2xhc3M9Im5v
dGUiPjwvc3Bhbj4nOwogICAgICBpbmZvLnF1ZXJ5U2VsZWN0b3IoJ2InKS50ZXh0Q29udGVudCA9
IHBhY2sudGl0bGU7CiAgICAgIGluZm8ucXVlcnlTZWxlY3Rvcignc3BhbicpLnRleHRDb250ZW50
ID0gJ23DozogJyArIHBhY2suaWQgKyAnIMK3ICcgKyBtYihwYWNrLnNpemUpICsgJyDCtyB04bqj
aSBsw6puICcgKyBuZXcgRGF0ZShwYWNrLnVwbG9hZGVkKS50b0xvY2FsZVN0cmluZygpOwogICAg
ICBjb25zdCBhY3Rpb25zID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgndGQnKTsKICAgICAgY29u
c3QgcmVtb3ZlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgIHJlbW92
ZS5jbGFzc05hbWUgPSAnc2Vjb25kYXJ5JzsKICAgICAgcmVtb3ZlLnRleHRDb250ZW50ID0gJ1jD
s2EnOwogICAgICByZW1vdmUub25jbGljayA9IGFzeW5jICgpID0+IHsKICAgICAgICBpZiAoIWNv
bmZpcm0oJ1jDs2EgIicgKyBwYWNrLnRpdGxlICsgJyIga2jhu49pIHJlbGF5PycpKSByZXR1cm47
CiAgICAgICAgY29uc3QgcmVzdWx0ID0gYXdhaXQgZmV0Y2goYXBpICsgJy8nICsgcGFjay5pZCwg
eyBtZXRob2Q6ICdERUxFVEUnLCBoZWFkZXJzOiB7ICd4LWFkbWluLWtleSc6ICQoJ2tleScpLnZh
bHVlIH0gfSk7CiAgICAgICAgaWYgKHJlc3VsdC5vaykgcmVmcmVzaCgpOyBlbHNlIHN0YXR1cygn
S2jDtG5nIHjDs2EgxJHGsOG7o2MgKGzhu5dpICcgKyByZXN1bHQuc3RhdHVzICsgJykuJywgJ2Jh
ZCcpOwogICAgICB9OwogICAgICBhY3Rpb25zLmFwcGVuZENoaWxkKHJlbW92ZSk7CiAgICAgIHJv
dy5hcHBlbmQoaW5mbywgYWN0aW9ucyk7CiAgICAgIGxpc3QuYXBwZW5kQ2hpbGQocm93KTsKICAg
IH0KICB9CiAgJCgncmVmcmVzaCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgcmVmcmVzaCk7
Cjwvc2NyaXB0Pgo8L2JvZHk+PC9odG1sPgpgOwoKbW9kdWxlLmV4cG9ydHMgPSB7IGNyZWF0ZVBh
Y2tzLCByZWFkWmlwLCBhbmFseXplWmlwLCB3cml0ZVppcCwgbW92aWVPZiwgZmxhc2hHYW1lLCBQ
YWNrRXJyb3IsIFBBQ0tfSUQgfTsK
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
ZSBmb3IgZXZlcnkgZ2FtZSBpbiBhIHJvb20KLy8gQWNjb3VudHMgKG5hbWUsIGEgaGFzaCBvZiB0
aGUgcGFzc3dvcmQsIGVhY2ggY2hhcmFjdGVyJ3MgbGV2ZWwgYW5kIGV4cGVyaWVuY2UsIHN0b3J5
IHByb2dyZXNzKQovLyBhcmUga2VwdCBpbiA8UEFDS1NfRElSPi9oZi9hY2NvdW50cy5qc29uIChv
ciBIRl9ESVIpLiBFdmVyeSBzdG9yeSBpcyBvcGVuLCBhbmQgZXZlcnkgY2hhcmFjdGVyIGEgcGxh
eWVyCi8vIG1heSBoYXZlIGlzIGF0IGxldmVsIDE2IGZyb20gdGhlIHN0YXJ0OyB0aGUgcHJlbWl1
bSBjaGFyYWN0ZXJzIChhbmQgWWFnYSwgd2hvbSB0aGUgZ2FtZSBrZWVwcyBmb3IKLy8gaXRzZWxm
KSBzdGF5IGxvY2tlZCBmb3IgcGxheWVycy4gQ29tcHV0ZXIgcGxheWVycyBnZXQgYW55IG9mIHRo
ZW0gKGhmLXJvb20uanMpLgondXNlIHN0cmljdCc7Cgpjb25zdCBjcnlwdG8gPSByZXF1aXJlKCdu
b2RlOmNyeXB0bycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ25vZGU6ZnMnKTsKY29uc3QgcGF0aCA9
IHJlcXVpcmUoJ25vZGU6cGF0aCcpOwpjb25zdCB7IEhmUm9vbSwgSGZDb25uZWN0aW9uLCBDSEFS
QUNURVJTIH0gPSByZXF1aXJlKCcuL2hmLXJvb20uanMnKTsKCmNvbnN0IFNUT1JJRVMgPSA2OyAv
LyBHbG9iYWwuc3RvcnlDaG9zZW5fbWF4OiB0aGUgbGFzdCBzdG9yeSBlcGlzb2RlCmNvbnN0IE1B
WF9FWFBFUklFTkNFID0gMTY5OTk7IC8vIGxldmVsIDE2ICh0aGUgZ2FtZSdzIGhpZ2hlc3Q7IG1v
cmUgaXMgdGFrZW4gZm9yIGEgY2hlYXQpLCA5OTkgZXhwZXJpZW5jZQpjb25zdCBTVEFSVF9FWFBF
UklFTkNFID0gMTYwMDA7IC8vIGxldmVsIDE2OiBub2JvZHkgaGFzIHRvIHBsYXkgZm9yIGxldmVs
cwovLyBUaGUgYWNjb3VudCdzIHZhbHVlcyAoYzEuLmMzMCwgb25lIHBlciBjaGFyYWN0ZXIsIENI
QVJBQ1RFUlMnIG9yZGVyKSB0aGUgZ2FtZSBnZXRzIG5vIGNoYXJhY3RlciBmb3I6Ci8vIHRoZSBw
cmVtaXVtIG9uZXMgKGxlbywgZWFzb24gYW5kIHdpdGggaXQgZWFzb24wLCBpY3p6eSwgaGVhdGVy
LCByYXllLCBsaXZlcm1vcmUpLCB3aGljaCBhcmUgdG9vIHN0cm9uZwovLyBmb3IgcGxheWVycywg
YW5kIHlhZ2EgKCJ1bmF2YWlsYWJsZSIpLiBBIHZhbHVlIG9mIDAga2VlcHMgYSBjaGFyYWN0ZXIg
bG9ja2VkOyBhIG5vbi1wcmVtaXVtIGFjY291bnQKLy8gKHN0YXR1c0NvZGUgYmVsb3cpIGtlZXBz
IHRoZSBwcmVtaXVtIG9uZXMgbG9ja2VkIHdoYXRldmVyIHRoZWlyIHZhbHVlLgpjb25zdCBMT0NL
RUQgPSBuZXcgU2V0KFs1LCA3LCA4LCAxNCwgMTUsIDE2LCAxOF0pOwpjb25zdCBQTEFZQUJMRSA9
IDE5OyAvLyBjMS4uYzE5IGFyZSBjaGFyYWN0ZXJzOyBjMjAuLmMzMCBhcmUgbm90IHVzZWQKLy8g
VGhlIHZhbHVlcyBhbiBhY2NvdW50IGhhczogdGhlIHBsYXlhYmxlIGNoYXJhY3RlcnMgYXQgbGV2
ZWwgMTYgYXQgbGVhc3QsIHRoZSBsb2NrZWQgb25lcyBhdCAwLgpmdW5jdGlvbiBzZXR0bGVkVmFs
dWVzKHZhbHVlcykgewogIHJldHVybiBBcnJheS5mcm9tKHsgbGVuZ3RoOiAzMCB9LCAoXywgaykg
PT4gewogICAgaWYgKGsgPj0gUExBWUFCTEUpIHJldHVybiBOdW1iZXIodmFsdWVzICYmIHZhbHVl
c1trXSkgfHwgMDsKICAgIGlmIChMT0NLRUQuaGFzKGspKSByZXR1cm4gMDsKICAgIHJldHVybiBN
YXRoLm1pbihNQVhfRVhQRVJJRU5DRSwgTWF0aC5tYXgoU1RBUlRfRVhQRVJJRU5DRSwgTnVtYmVy
KHZhbHVlcyAmJiB2YWx1ZXNba10pIHx8IDApKTsKICB9KTsKfQoKLy8gVGhlIGdhbWUgY2hlY2tz
IGxvZ2luIGFuc3dlcnMgd2l0aCBhIGNvZGUgb3ZlciB0aGUgbnVtYmVycyBpbiB0aGVtIChHbG9i
YWwuTG9naW5TdGF0dXNNZXNzYWdlKToKLy8gd2l0aCBuID0gdls4XSwgbSA9IHZbOSsybi4uKzdd
IGFuZCB4ID0gdlsxNisybi4uKzddLCAoOTk5OTk5OCAtIHggLSBtKSAvIDMgbXVzdCBiZSB0aGUg
c3VtIGJlbG93Ci8vIChvciB0aGF0IHBsdXMgaWQlMTMgKyBpZCU2MSArIGlkJTEwNywgZm9yIGEg
cHJlbWl1bSBhY2NvdW50OiBldmVyeSBjaGFyYWN0ZXIsIGFsc28gdGhlIHByZW1pdW0gb25lcyku
CmZ1bmN0aW9uIHN0YXR1c0NvZGUodmFsdWVzLCBpZCwgYWNjdHlwZSwgc3RhZ2UsIHNlc3Npb24s
IHByZW1pdW0pIHsKICBjb25zdCBzdW0gPSAodmFsdWVzLnJlZHVjZSgoYSwgYikgPT4gYSArIGIs
IDApICsgaWQgKyBhY2N0eXBlICsgc3RhZ2UgKyBzZXNzaW9uICUgMTAwMDAwMCkgJSAxMDAwMDAw
ICsgMTAwMDAwMDsKICByZXR1cm4gZW5jb2RlTnVtYmVyKHN1bSArIChwcmVtaXVtID8gaWQgJSAx
MyArIGlkICUgNjEgKyBpZCAlIDEwNyA6IDApKTsKfQoKLy8gQSBudW1iZXIgdGhlIGdhbWUgcmVh
ZHMgYmFjayBhcyAoOTk5OTk5OCAtIHggLSBtKSAvIDMgZnJvbSB0aGUgMjUtZGlnaXQgZm9ybSBh
Ym92ZSAoYW5kIGNhcHRjaGEKLy8gY29kZXMgYXMgdGhhdCBtb2R1bG8gMTAwMDAwMCk6IHJhbmRv
bSBkaWdpdHMgYXJvdW5kIGl0LCBhcyBoZXJvZmlnaHRlci5jb20gc2VudC4KZnVuY3Rpb24gZW5j
b2RlTnVtYmVyKG51bWJlcikgewogIGNvbnN0IGRpZ2l0ID0gKCkgPT4gU3RyaW5nKGNyeXB0by5y
YW5kb21JbnQoMTApKTsKICBjb25zdCBuID0gY3J5cHRvLnJhbmRvbUludCgxMCk7CiAgY29uc3Qg
bSA9IGNyeXB0by5yYW5kb21JbnQoMTAwMDAwMCwgMjAwMDAwMCk7CiAgY29uc3QgeCA9IDk5OTk5
OTggLSAzICogbnVtYmVyIC0gbTsKICBsZXQgdGV4dCA9ICcnOwogIGZvciAobGV0IGsgPSAwOyBr
IDwgODsgayArPSAxKSB0ZXh0ICs9IGRpZ2l0KCk7CiAgdGV4dCArPSBTdHJpbmcobik7CiAgZm9y
IChsZXQgayA9IDA7IGsgPCBuICogMjsgayArPSAxKSB0ZXh0ICs9IGRpZ2l0KCk7CiAgdGV4dCAr
PSBTdHJpbmcobSkucGFkU3RhcnQoNywgJzAnKSArIFN0cmluZyh4KS5wYWRTdGFydCg3LCAnMCcp
OwogIGZvciAobGV0IGsgPSAwOyBrIDwgMTggLSBuICogMjsgayArPSAxKSB0ZXh0ICs9IGRpZ2l0
KCk7CiAgcmV0dXJuIHRleHQ7Cn0KCi8vIFdoYXQgdGhlIGdhbWUncyBwcmVtaXVtIG9mZmVyIChp
dCBzaG93cyBvbmUgYnkgdGhlIGxvY2tlZCBjaGFyYWN0ZXJzKSBvcGVucyBpbiBhIG5ldyB0YWIu
CmNvbnN0IFBSRU1JVU1fUEFHRSA9IGA8IWRvY3R5cGUgaHRtbD4KPGh0bWwgbGFuZz0idmkiPjxo
ZWFkPjxtZXRhIGNoYXJzZXQ9InV0Zi04Ij48bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0i
d2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+SGVybyBGaWdodGVy
OiBQcmVtaXVtPC90aXRsZT4KPHN0eWxlPmJvZHl7Zm9udDoxN3B4LzEuNTUgc3lzdGVtLXVpLHNh
bnMtc2VyaWY7bWF4LXdpZHRoOjM2cmVtO21hcmdpbjozcmVtIGF1dG87cGFkZGluZzowIDE2cHg7
Y29sb3I6IzFkMWQxZDtiYWNrZ3JvdW5kOiNmN2Y3ZjV9Cmgxe2ZvbnQtc2l6ZToxLjM1cmVtfS5l
bntjb2xvcjojNmE2YTZhO2ZvbnQtc2l6ZTouOTVyZW19CkBtZWRpYSAocHJlZmVycy1jb2xvci1z
Y2hlbWU6ZGFyayl7Ym9keXtjb2xvcjojZWNlY2VjO2JhY2tncm91bmQ6IzFhMWExYX0uZW57Y29s
b3I6I2EwYTBhMH19PC9zdHlsZT48L2hlYWQ+Cjxib2R5PjxoMT5LaMO0bmcgY+G6p24gbXVhIGfD
rCBj4bqjPC9oMT4KPHA+VHLDqm4gbcOheSBjaOG7pyBuw6B5LCBjw6FjIG5ow6JuIHbhuq10IFBy
ZW1pdW0gKExlbywgRWFzb24sIEljenp5LCBIZWF0ZXIsIFJheWUsIExpdmVybW9yZSkgYuG7iyBr
aMOzYSB24bubaSBuZ8aw4budaSBjaMahaSB2w6wgcXXDoQpt4bqhbmg7IG3DoXkgKENvbSBQbGF5
ZXIpIHbhuqtuIGTDuW5nIMSRxrDhu6NjLiBN4buNaSBuaMOibiB24bqtdCBraMOhYyDEkeG7gXUg
xJHDoyDhu58gTGV2ZWwgMTYuPC9wPgo8cD7EkMOzbmcgdHJhbmcgbsOgeSB2w6AgcXVheSBs4bqh
aSBnYW1lLjwvcD4KPHAgY2xhc3M9ImVuIiBsYW5nPSJlbiI+Tm90aGluZyB0byBidXkgaGVyZTog
b24gdGhpcyBzZXJ2ZXIgdGhlIHByZW1pdW0gY2hhcmFjdGVycyBhcmUgbG9ja2VkIGZvciBwbGF5
ZXJzICh0aGV5IGFyZSB0b28Kc3Ryb25nKSwgYW5kIGNvbXB1dGVyIHBsYXllcnMgbWF5IHN0aWxs
IGhhdmUgdGhlbS4gRXZlcnkgb3RoZXIgY2hhcmFjdGVyIGlzIGF0IGxldmVsIDE2LiBDbG9zZSB0
aGlzIHBhZ2UgYW5kIGdvIGJhY2sKdG8gdGhlIGdhbWUuPC9wPgo8L2JvZHk+PC9odG1sPgpgOwoK
ZnVuY3Rpb24geG1sVGV4dCh2YWx1ZSkgewogIHJldHVybiBTdHJpbmcodmFsdWUpLnJlcGxhY2Uo
L1s8PiZdL2csIChjKSA9PiAoeyAnPCc6ICcmbHQ7JywgJz4nOiAnJmd0OycsICcmJzogJyZhbXA7
JyB9W2NdKSk7Cn0KCi8vIEEgZGlzcGxheSBuYW1lOiB3aGF0IHRoZSBnYW1lIGFsbG93cyBpbiBv
bmUgKG5vIFsgb3IgXSwgd2hpY2ggaXQgdXNlcyBpdHNlbGYpLCBhdCBtb3N0IDIwIGNoYXJhY3Rl
cnMuCmZ1bmN0aW9uIGNsZWFuTmFtZSh2YWx1ZSkgewogIHJldHVybiBTdHJpbmcodmFsdWUgfHwg
JycpLnJlcGxhY2UoL1tbXF08PiYiXHUwMDAwLVx1MDAxZl0vZywgJycpLnRyaW0oKS5zbGljZSgw
LCAyMCk7Cn0KCmZ1bmN0aW9uIGhhc2hQYXNzd29yZChwYXNzd29yZCwgc2FsdCkgewogIHJldHVy
biBjcnlwdG8uc2NyeXB0U3luYyhTdHJpbmcocGFzc3dvcmQpLCBzYWx0LCAzMikudG9TdHJpbmco
J2hleCcpOwp9CgpmdW5jdGlvbiBjcmVhdGVBY2NvdW50cyhmaWxlLCBsb2cpIHsKICBsZXQgYWNj
b3VudHMgPSB7fTsKICBsZXQgbmV4dElkID0gMTAwMTsgLy8gaWRzIHVwIHRvIDIwIG9wZW4gdGhl
IGdhbWUncyBkZXZlbG9wZXIga2V5cwogIGxldCBzYXZlVGltZXIgPSBudWxsOwogIGlmIChmaWxl
KSB7CiAgICB0cnkgewogICAgICBjb25zdCBzYXZlZCA9IEpTT04ucGFyc2UoZnMucmVhZEZpbGVT
eW5jKGZpbGUsICd1dGY4JykpOwogICAgICBhY2NvdW50cyA9IHNhdmVkLmFjY291bnRzIHx8IHt9
OwogICAgICBuZXh0SWQgPSBNYXRoLm1heChuZXh0SWQsIE51bWJlcihzYXZlZC5uZXh0SWQpIHx8
IDApOwogICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgaWYgKGVycm9yLmNvZGUgIT09ICdFTk9F
TlQnKSBsb2coYGhmIGFjY291bnRzOiBjb3VsZCBub3QgcmVhZCAke2ZpbGV9OiAke2Vycm9yLm1l
c3NhZ2V9YCk7CiAgICB9CiAgfQogIGNvbnN0IHNhdmUgPSAoKSA9PiB7CiAgICBpZiAoIWZpbGUg
fHwgc2F2ZVRpbWVyKSByZXR1cm47CiAgICBzYXZlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsK
ICAgICAgc2F2ZVRpbWVyID0gbnVsbDsKICAgICAgdHJ5IHsKICAgICAgICBmcy5ta2RpclN5bmMo
cGF0aC5kaXJuYW1lKGZpbGUpLCB7IHJlY3Vyc2l2ZTogdHJ1ZSB9KTsKICAgICAgICBjb25zdCB0
ZW1wb3JhcnkgPSBgJHtmaWxlfS4ke3Byb2Nlc3MucGlkfS50bXBgOwogICAgICAgIGZzLndyaXRl
RmlsZVN5bmModGVtcG9yYXJ5LCBKU09OLnN0cmluZ2lmeSh7IHZlcnNpb246IDEsIG5leHRJZCwg
YWNjb3VudHMgfSwgbnVsbCwgMSkpOwogICAgICAgIGZzLnJlbmFtZVN5bmModGVtcG9yYXJ5LCBm
aWxlKTsKICAgICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgICBsb2coYGhmIGFjY291bnRzOiBj
b3VsZCBub3Qgc2F2ZTogJHtlcnJvci5tZXNzYWdlfWApOwogICAgICB9CiAgICB9LCA1MDApOwog
ICAgaWYgKHNhdmVUaW1lci51bnJlZikgc2F2ZVRpbWVyLnVucmVmKCk7CiAgfTsKICByZXR1cm4g
ewogICAgZ2V0KGVtYWlsKSB7IHJldHVybiBhY2NvdW50c1tlbWFpbF0gfHwgbnVsbDsgfSwKICAg
IGJ5SWQoaWQpIHsgcmV0dXJuIE9iamVjdC52YWx1ZXMoYWNjb3VudHMpLmZpbmQoKGFjY291bnQp
ID0+IFN0cmluZyhhY2NvdW50LmlkKSA9PT0gU3RyaW5nKGlkKSkgfHwgbnVsbDsgfSwKICAgIGJ5
TmFtZShuYW1lKSB7IHJldHVybiBPYmplY3QudmFsdWVzKGFjY291bnRzKS5maW5kKChhY2NvdW50
KSA9PiBhY2NvdW50Lm5hbWUudG9Mb3dlckNhc2UoKSA9PT0gbmFtZS50b0xvd2VyQ2FzZSgpKSB8
fCBudWxsOyB9LAogICAgY3JlYXRlKGVtYWlsLCBwYXNzd29yZCwgbmFtZSwgY2MpIHsKICAgICAg
Y29uc3Qgc2FsdCA9IGNyeXB0by5yYW5kb21CeXRlcygxMikudG9TdHJpbmcoJ2hleCcpOwogICAg
ICBsZXQgdW5pcXVlID0gbmFtZSB8fCAnUGxheWVyJzsKICAgICAgZm9yIChsZXQgayA9IDI7IHRo
aXMuYnlOYW1lKHVuaXF1ZSk7IGsgKz0gMSkgdW5pcXVlID0gYCR7bmFtZS5zbGljZSgwLCAxNyl9
JHtrfWA7CiAgICAgIGNvbnN0IGFjY291bnQgPSB7CiAgICAgICAgaWQ6IG5leHRJZCsrLCBuYW1l
OiB1bmlxdWUsIGNjOiBjYyB8fCAnVk4nLCBzYWx0LCBoYXNoOiBoYXNoUGFzc3dvcmQocGFzc3dv
cmQsIHNhbHQpLAogICAgICAgIHNlc3Npb246IGNyeXB0by5yYW5kb21JbnQoMTAwMDAwLCAxMDAw
MDAwMDAwKSwgdmFsdWVzOiBzZXR0bGVkVmFsdWVzKG51bGwpLAogICAgICAgIHN0YWdlOiBTVE9S
SUVTLCBuYW1lQ2hhbmdlczogOSwgY3JlYXRlZDogbmV3IERhdGUoKS50b0lTT1N0cmluZygpLCAv
LyAobmFtZSBjaGFuZ2VzIGFyZSBub3QgY291bnRlZCBkb3duKQogICAgICB9OwogICAgICBhY2Nv
dW50c1tlbWFpbF0gPSBhY2NvdW50OwogICAgICBzYXZlKCk7CiAgICAgIHJldHVybiBhY2NvdW50
OwogICAgfSwKICAgIGNoZWNrUGFzc3dvcmQoYWNjb3VudCwgcGFzc3dvcmQpIHsKICAgICAgY29u
c3QgZXhwZWN0ZWQgPSBCdWZmZXIuZnJvbShhY2NvdW50Lmhhc2gsICdoZXgnKTsKICAgICAgY29u
c3QgZ2l2ZW4gPSBCdWZmZXIuZnJvbShoYXNoUGFzc3dvcmQocGFzc3dvcmQsIGFjY291bnQuc2Fs
dCksICdoZXgnKTsKICAgICAgcmV0dXJuIGV4cGVjdGVkLmxlbmd0aCA9PT0gZ2l2ZW4ubGVuZ3Ro
ICYmIGNyeXB0by50aW1pbmdTYWZlRXF1YWwoZXhwZWN0ZWQsIGdpdmVuKTsKICAgIH0sCiAgICBz
ZXRQYXNzd29yZChhY2NvdW50LCBwYXNzd29yZCkgewogICAgICBhY2NvdW50LnNhbHQgPSBjcnlw
dG8ucmFuZG9tQnl0ZXMoMTIpLnRvU3RyaW5nKCdoZXgnKTsKICAgICAgYWNjb3VudC5oYXNoID0g
aGFzaFBhc3N3b3JkKHBhc3N3b3JkLCBhY2NvdW50LnNhbHQpOwogICAgICBzYXZlKCk7CiAgICB9
LAogICAgc2F2ZSwKICAgIGZsdXNoKCkgewogICAgICBpZiAoIXNhdmVUaW1lcikgcmV0dXJuOwog
ICAgICBjbGVhclRpbWVvdXQoc2F2ZVRpbWVyKTsKICAgICAgc2F2ZVRpbWVyID0gbnVsbDsKICAg
ICAgdHJ5IHsKICAgICAgICBmcy5ta2RpclN5bmMocGF0aC5kaXJuYW1lKGZpbGUpLCB7IHJlY3Vy
c2l2ZTogdHJ1ZSB9KTsKICAgICAgICBmcy53cml0ZUZpbGVTeW5jKGZpbGUsIEpTT04uc3RyaW5n
aWZ5KHsgdmVyc2lvbjogMSwgbmV4dElkLCBhY2NvdW50cyB9LCBudWxsLCAxKSk7CiAgICAgIH0g
Y2F0Y2ggKGVycm9yKSB7CiAgICAgICAgbG9nKGBoZiBhY2NvdW50czogY291bGQgbm90IHNhdmU6
ICR7ZXJyb3IubWVzc2FnZX1gKTsKICAgICAgfQogICAgfSwKICB9Owp9CgpmdW5jdGlvbiBjcmVh
dGVIZihjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzLCBhbGxvd09yaWdpbiwgYnVkZ2V0IH0p
IHsKICBjb25zdCBmb2xkZXIgPSBjb25maWcuaGZEaXIgfHwgKGNvbmZpZy5wYWNrc0RpciA/IHBh
dGguam9pbihjb25maWcucGFja3NEaXIsICdoZicpIDogJycpOwogIGNvbnN0IGFjY291bnRzID0g
Y3JlYXRlQWNjb3VudHMoZm9sZGVyICYmIHBhdGguam9pbihmb2xkZXIsICdhY2NvdW50cy5qc29u
JyksIGxvZyk7CiAgY29uc3Qgcm9vbUNvdW50ID0gTWF0aC5tYXgoMSwgTWF0aC5taW4oMjAsIE1h
dGgucm91bmQoY29uZmlnLmhmUm9vbXMgfHwgNCkpKTsKICBjb25zdCByb29tcyA9IFtdOwogIGZv
ciAobGV0IG51bWJlciA9IDE7IG51bWJlciA8PSByb29tQ291bnQ7IG51bWJlciArPSAxKSB7CiAg
ICByb29tcy5wdXNoKG5ldyBIZlJvb20oeyBudW1iZXIsIG5hbWU6IGBQaG9uZyAke251bWJlcn1g
LCBkZXNjcmlwdGlvbjogY29uZmlnLmhmUm9vbURlc2NyaXB0aW9uIHx8ICdPcGVuTEYyIHJlbGF5
JywgbG9nIH0pKTsKICB9CiAgY29uc3QgY2FwdGNoYXMgPSBuZXcgTWFwKCk7IC8vIGNsaWVudCBr
ZXkgLT4geyBjb2RlLCB1bnRpbCB9CiAgY29uc3QgdHJpZXMgPSBuZXcgTWFwKCk7IC8vIGNsaWVu
dCBhZGRyZXNzIC0+IHsgY291bnQsIHVudGlsIH06IGZhaWxlZCBwYXNzd29yZHMgYW5kIGNvZGVz
CiAgY29uc3QgY3JlYXRpb25zID0gbmV3IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVzcyAtPiB7IGNv
dW50LCB1bnRpbCB9OiBuZXcgYWNjb3VudHMKICBjb25zdCBtYXlDcmVhdGUgPSAoYWRkcmVzcykg
PT4gewogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGxldCBlbnRyeSA9IGNyZWF0aW9u
cy5nZXQoYWRkcmVzcyk7CiAgICBpZiAoIWVudHJ5IHx8IGVudHJ5LnVudGlsIDw9IG5vdykgewog
ICAgICBlbnRyeSA9IHsgY291bnQ6IDAsIHVudGlsOiBub3cgKyAzNjAwMDAwIH07CiAgICAgIGNy
ZWF0aW9ucy5zZXQoYWRkcmVzcywgZW50cnkpOwogICAgfQogICAgaWYgKGVudHJ5LmNvdW50ID49
IDIwKSByZXR1cm4gZmFsc2U7CiAgICBlbnRyeS5jb3VudCArPSAxOwogICAgcmV0dXJuIHRydWU7
CiAgfTsKICBjb25zdCBMSU1JVCA9ICc8ZW4+VG9vIG1hbnkgbmV3IGFjY291bnRzIGZyb20geW91
ciBuZXR3b3JrOiB0cnkgYWdhaW4gaW4gYW4gaG91ci48L2VuPjxiNT5Ub28gbWFueSBuZXcgYWNj
b3VudHMgZnJvbSB5b3VyIG5ldHdvcms6IHRyeSBhZ2FpbiBpbiBhbiBob3VyLjwvYjU+JzsKCiAg
ZnVuY3Rpb24gbG9naW5YbWwoYWNjb3VudCwgcm9vdCA9ICdsb2dpbicpIHsKICAgIGNvbnN0IHZh
bHVlcyA9IGFjY291bnQudmFsdWVzOwogICAgY29uc3QgZmllbGRzID0gdmFsdWVzLm1hcCgodmFs
dWUsIGluZGV4KSA9PiBgPGMke2luZGV4ICsgMX0+JHt2YWx1ZX08L2Mke2luZGV4ICsgMX0+YCku
am9pbignJyk7CiAgICBjb25zdCBjb2RlID0gc3RhdHVzQ29kZSh2YWx1ZXMsIGFjY291bnQuaWQs
IDAsIGFjY291bnQuc3RhZ2UsIGFjY291bnQuc2Vzc2lvbiwgZmFsc2UpOwogICAgcmV0dXJuIGA8
JHtyb290fT4ke2ZpZWxkc308aT4ke2FjY291bnQuaWR9PC9pPjxuPiR7eG1sVGV4dChhY2NvdW50
Lm5hbWUpfTwvbj48Y2M+JHt4bWxUZXh0KGFjY291bnQuY2MpfTwvY2M+YAogICAgICArIGA8cz4k
e2FjY291bnQuc2Vzc2lvbn08L3M+PGFjY3R5cGU+MDwvYWNjdHlwZT48c3RhZ2U+JHthY2NvdW50
LnN0YWdlfTwvc3RhZ2U+PHY+JHtjb2RlfTwvdj48LyR7cm9vdH0+YDsKICB9CgogIGNvbnN0IHBy
dW5lID0gKCkgPT4gewogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAoY29uc3Qg
bWFwIG9mIFt0cmllcywgY3JlYXRpb25zXSkgZm9yIChjb25zdCBba2V5LCBlbnRyeV0gb2YgbWFw
KSBpZiAoZW50cnkudW50aWwgPD0gbm93KSBtYXAuZGVsZXRlKGtleSk7CiAgICBmb3IgKGNvbnN0
IFtrZXksIGVudHJ5XSBvZiBjYXB0Y2hhcykgaWYgKGVudHJ5LnVudGlsIDw9IG5vdykgY2FwdGNo
YXMuZGVsZXRlKGtleSk7CiAgfTsKICBjb25zdCBwcnVuZVRpbWVyID0gc2V0SW50ZXJ2YWwocHJ1
bmUsIDYwMDAwMCk7CiAgaWYgKHBydW5lVGltZXIudW5yZWYpIHBydW5lVGltZXIudW5yZWYoKTsK
CiAgZnVuY3Rpb24gdG9vTWFueVRyaWVzKGFkZHJlc3MpIHsKICAgIGNvbnN0IG5vdyA9IERhdGUu
bm93KCk7CiAgICBjb25zdCBlbnRyeSA9IHRyaWVzLmdldChhZGRyZXNzKTsKICAgIHJldHVybiBC
b29sZWFuKGVudHJ5ICYmIGVudHJ5LnVudGlsID4gbm93ICYmIGVudHJ5LmNvdW50ID49IDMwKTsK
ICB9CiAgZnVuY3Rpb24gZmFpbGVkVHJ5KGFkZHJlc3MpIHsKICAgIGNvbnN0IG5vdyA9IERhdGUu
bm93KCk7CiAgICBsZXQgZW50cnkgPSB0cmllcy5nZXQoYWRkcmVzcyk7CiAgICBpZiAoIWVudHJ5
IHx8IGVudHJ5LnVudGlsIDw9IG5vdykgewogICAgICBlbnRyeSA9IHsgY291bnQ6IDAsIHVudGls
OiBub3cgKyAzNjAwMDAwIH07CiAgICAgIHRyaWVzLnNldChhZGRyZXNzLCBlbnRyeSk7CiAgICB9
CiAgICBlbnRyeS5jb3VudCArPSAxOwogIH0KCiAgZnVuY3Rpb24gY2hlY2tDYXB0Y2hhKGtleSwg
Y29kZSkgewogICAgY29uc3QgZW50cnkgPSBjYXB0Y2hhcy5nZXQoU3RyaW5nKGtleSB8fCAnJykp
OwogICAgY2FwdGNoYXMuZGVsZXRlKFN0cmluZyhrZXkgfHwgJycpKTsKICAgIHJldHVybiBCb29s
ZWFuKGVudHJ5ICYmIGVudHJ5LnVudGlsID4gRGF0ZS5ub3coKSAmJiBTdHJpbmcoZW50cnkuY29k
ZSkgPT09IFN0cmluZyhjb2RlIHx8ICcnKS50cmltKCkpOwogIH0KCiAgY29uc3QgZW1haWwgPSAo
dmFsdWUpID0+IFN0cmluZyh2YWx1ZSB8fCAnJykudHJpbSgpLnRvTG93ZXJDYXNlKCkuc2xpY2Uo
MCwgMTAwKTsKCiAgLy8gVGhlIGFuc3dlciB0byBvbmUgb2YgdGhlIGFjY291bnQgc2VydmljZXMs
IGZyb20gdGhlIHF1ZXJ5IChhbmQgYSBmb3JtIGJvZHksIGlmIGFueSkuCiAgZnVuY3Rpb24gYW5z
d2VyKHNlcnZpY2UsIHBhcmFtcywgYWRkcmVzcykgewogICAgY29uc3QgZ2V0ID0gKG5hbWUpID0+
IHBhcmFtcy5nZXQobmFtZSkgfHwgJyc7CiAgICBpZiAoc2VydmljZSA9PT0gJ3YwLjcvbG9naW4u
cGhwJykgewogICAgICBjb25zdCBlbSA9IGVtYWlsKGdldCgnZW0nKSk7CiAgICAgIGlmICghZW0p
IHJldHVybiAnPGxvZ2luPjxlcnJvcj5lbTwvZXJyb3I+PC9sb2dpbj4nOwogICAgICBpZiAodG9v
TWFueVRyaWVzKGFkZHJlc3MpKSByZXR1cm4gJzxsb2dpbj48ZXJyb3I+cmVhc29uPC9lcnJvcj48
ZW4+VG9vIG1hbnkgd3JvbmcgcGFzc3dvcmRzOiB0cnkgYWdhaW4gaW4gYW4gaG91ci48L2VuPjxi
NT5Ub28gbWFueSB3cm9uZyBwYXNzd29yZHM6IHRyeSBhZ2FpbiBpbiBhbiBob3VyLjwvYjU+PC9s
b2dpbj4nOwogICAgICBsZXQgYWNjb3VudCA9IGFjY291bnRzLmdldChlbSk7CiAgICAgIGlmICgh
YWNjb3VudCkgewogICAgICAgIGlmICghbWF5Q3JlYXRlKGFkZHJlc3MpKSByZXR1cm4gYDxsb2dp
bj48ZXJyb3I+cmVhc29uPC9lcnJvcj4ke0xJTUlUfTwvbG9naW4+YDsKICAgICAgICBhY2NvdW50
ID0gYWNjb3VudHMuY3JlYXRlKGVtLCBnZXQoJ3B3JyksIGNsZWFuTmFtZShlbS5zcGxpdCgnQCcp
WzBdKSwgJ1ZOJyk7CiAgICAgICAgbG9nKGBoZjogbmV3IGFjY291bnQgJHthY2NvdW50LmlkfSAi
JHthY2NvdW50Lm5hbWV9ImApOwogICAgICB9IGVsc2UgaWYgKCFhY2NvdW50cy5jaGVja1Bhc3N3
b3JkKGFjY291bnQsIGdldCgncHcnKSkpIHsKICAgICAgICBmYWlsZWRUcnkoYWRkcmVzcyk7CiAg
ICAgICAgcmV0dXJuICc8bG9naW4+PGVycm9yPnB3PC9lcnJvcj48L2xvZ2luPic7CiAgICAgIH0K
ICAgICAgLy8gQWNjb3VudHMgbWFkZSBiZWZvcmUgdGhlIGNoYXJhY3RlcnMnIHJ1bGVzIHdlcmUg
d2hhdCB0aGV5IGFyZSBub3cgZm9sbG93IHRoZW0gZnJvbSB0aGVpciBuZXh0IGxvZ2luLgogICAg
ICBjb25zdCBzZXR0bGVkID0gc2V0dGxlZFZhbHVlcyhhY2NvdW50LnZhbHVlcyk7CiAgICAgIGlm
IChzZXR0bGVkLnNvbWUoKHZhbHVlLCBrKSA9PiB2YWx1ZSAhPT0gYWNjb3VudC52YWx1ZXNba10p
KSB7CiAgICAgICAgYWNjb3VudC52YWx1ZXMgPSBzZXR0bGVkOwogICAgICAgIGFjY291bnRzLnNh
dmUoKTsKICAgICAgfQogICAgICByZXR1cm4gbG9naW5YbWwoYWNjb3VudCk7CiAgICB9CiAgICBp
ZiAoc2VydmljZSA9PT0gJ3YwLjcvbHUucGhwJykgewogICAgICBjb25zdCBhY2NvdW50ID0gYWNj
b3VudHMuZ2V0KGVtYWlsKGdldCgnZW0nKSkpOwogICAgICBpZiAoIWFjY291bnQgfHwgU3RyaW5n
KGFjY291bnQuaWQpICE9PSBnZXQoJ2lkJykgfHwgU3RyaW5nKGFjY291bnQuc2Vzc2lvbikgIT09
IGdldCgncycpKSByZXR1cm4gJzxsdT48ZXJyb3I+c2E8L2Vycm9yPjwvbHU+JzsKICAgICAgZm9y
IChsZXQgayA9IDE7IGsgPD0gMzsgayArPSAxKSB7CiAgICAgICAgY29uc3QgaW5kZXggPSBOdW1i
ZXIoZ2V0KGBpJHtrfWApKTsKICAgICAgICBjb25zdCB0byA9IE51bWJlcihnZXQoYHRvJHtrfWAp
KTsKICAgICAgICBpZiAoIU51bWJlci5pc0ludGVnZXIoaW5kZXgpIHx8IGluZGV4IDwgMSB8fCBp
bmRleCA+IENIQVJBQ1RFUlMubGVuZ3RoIC0gMSB8fCAhTnVtYmVyLmlzRmluaXRlKHRvKSkgY29u
dGludWU7CiAgICAgICAgYWNjb3VudC52YWx1ZXNbaW5kZXggLSAxXSA9IE1hdGgubWF4KGFjY291
bnQudmFsdWVzW2luZGV4IC0gMV0sIE1hdGgubWluKE1BWF9FWFBFUklFTkNFLCBNYXRoLmZsb29y
KHRvKSkpOwogICAgICB9CiAgICAgIC8vICh1bGksIGEgY2hhcmFjdGVyIGEgc3RvcnkgdW5sb2Nr
czogZXZlcnkgY2hhcmFjdGVyIGEgcGxheWVyIG1heSBoYXZlIGlzIHVubG9ja2VkIGFscmVhZHku
KQogICAgICBhY2NvdW50LnZhbHVlcyA9IHNldHRsZWRWYWx1ZXMoYWNjb3VudC52YWx1ZXMpOwog
ICAgICBjb25zdCBzdGFnZSA9IE51bWJlcihnZXQoJ3N0ZycpKTsKICAgICAgaWYgKE51bWJlci5p
c0ludGVnZXIoc3RhZ2UpKSBhY2NvdW50LnN0YWdlID0gTWF0aC5tYXgoYWNjb3VudC5zdGFnZSwg
TWF0aC5taW4oU1RPUklFUywgc3RhZ2UpKTsKICAgICAgYWNjb3VudHMuc2F2ZSgpOwogICAgICBy
ZXR1cm4gbG9naW5YbWwoYWNjb3VudCwgJ2x1Jyk7CiAgICB9CiAgICBpZiAoc2VydmljZSA9PT0g
J2NhcC5waHAnKSB7CiAgICAgIGNvbnN0IGtleSA9IGNyeXB0by5yYW5kb21CeXRlcyg4KS50b1N0
cmluZygnaGV4Jyk7CiAgICAgIGNvbnN0IGNvZGUgPSBjcnlwdG8ucmFuZG9tSW50KDEwMDAsIDEw
MDAwKTsKICAgICAgY2FwdGNoYXMuc2V0KGtleSwgeyBjb2RlLCB1bnRpbDogRGF0ZS5ub3coKSAr
IDYwMDAwMCB9KTsKICAgICAgaWYgKGNhcHRjaGFzLnNpemUgPiAyMDAwKSBjYXB0Y2hhcy5kZWxl
dGUoY2FwdGNoYXMua2V5cygpLm5leHQoKS52YWx1ZSk7CiAgICAgIHJldHVybiBgPGNhcD48YzE+
JHtrZXl9PC9jMT48YzI+JHtlbmNvZGVOdW1iZXIoY29kZSl9PC9jMj48L2NhcD5gOwogICAgfQog
ICAgaWYgKHNlcnZpY2UgPT09ICdyZWcucGhwJykgewogICAgICBpZiAoIWNoZWNrQ2FwdGNoYShn
ZXQoJ2MnKSwgZ2V0KCdzJykpKSByZXR1cm4gJzxyZWc+PGVycm9yPmNvZGU8L2Vycm9yPjwvcmVn
Pic7CiAgICAgIGNvbnN0IGVtID0gZW1haWwoZ2V0KCdlbScpKTsKICAgICAgaWYgKCFlbSB8fCBh
Y2NvdW50cy5nZXQoZW0pKSByZXR1cm4gJzxyZWc+PGVycm9yPnNhbWVlbWFpbDwvZXJyb3I+PC9y
ZWc+JzsKICAgICAgY29uc3QgbmFtZSA9IGNsZWFuTmFtZShnZXQoJ25tJykpOwogICAgICBpZiAo
IW5hbWUpIHJldHVybiAnPHJlZz48ZXJyb3I+bmFtZTwvZXJyb3I+PC9yZWc+JzsKICAgICAgaWYg
KGFjY291bnRzLmJ5TmFtZShuYW1lKSkgcmV0dXJuICc8cmVnPjxlcnJvcj5zYW1lbmFtZTwvZXJy
b3I+PC9yZWc+JzsKICAgICAgaWYgKCFtYXlDcmVhdGUoYWRkcmVzcykpIHJldHVybiBgPHJlZz48
ZXJyb3I+bGltaXQ8L2Vycm9yPiR7TElNSVR9PC9yZWc+YDsKICAgICAgY29uc3QgYWNjb3VudCA9
IGFjY291bnRzLmNyZWF0ZShlbSwgZ2V0KCdwdycpLCBuYW1lLCBTdHJpbmcoZ2V0KCdjYycpKS5y
ZXBsYWNlKC9bXkEtWl0vZywgJycpLnNsaWNlKDAsIDIpIHx8ICdWTicpOwogICAgICBsb2coYGhm
OiBuZXcgYWNjb3VudCAke2FjY291bnQuaWR9ICIke2FjY291bnQubmFtZX0iIChyZWdpc3RlcmVk
KWApOwogICAgICByZXR1cm4gbG9naW5YbWwoYWNjb3VudCwgJ3JlZycpOwogICAgfQogICAgY29u
c3QgYnlJZCA9ICgpID0+IHsKICAgICAgY29uc3QgYWNjb3VudCA9IGFjY291bnRzLmdldChlbWFp
bChnZXQoJ2VtJykpKTsKICAgICAgcmV0dXJuIGFjY291bnQgJiYgU3RyaW5nKGFjY291bnQuaWQp
ID09PSBnZXQoJ2lkJykgJiYgU3RyaW5nKGFjY291bnQuc2Vzc2lvbikgPT09IGdldCgnc3MnKSA/
IGFjY291bnQgOiBudWxsOwogICAgfTsKICAgIGlmIChzZXJ2aWNlID09PSAnbmFtZWNoZ19sZWZ0
LnBocCcpIHsKICAgICAgY29uc3QgYWNjb3VudCA9IGFjY291bnRzLmJ5SWQoZ2V0KCdpZCcpKTsK
ICAgICAgcmV0dXJuIGA8bmFtZWNoZz48bj4ke2FjY291bnQgPyBhY2NvdW50Lm5hbWVDaGFuZ2Vz
IDogMH08L24+PC9uYW1lY2hnPmA7CiAgICB9CiAgICBpZiAoc2VydmljZSA9PT0gJ25hbWVjaGcu
cGhwJykgewogICAgICBpZiAoIWNoZWNrQ2FwdGNoYShnZXQoJ2MnKSwgZ2V0KCdzJykpKSByZXR1
cm4gJzxuYW1lY2hnPjxlcnJvcj5jb2RlPC9lcnJvcj48L25hbWVjaGc+JzsKICAgICAgY29uc3Qg
YWNjb3VudCA9IGJ5SWQoKTsKICAgICAgaWYgKCFhY2NvdW50KSByZXR1cm4gJzxuYW1lY2hnPjxl
cnJvcj5zYTwvZXJyb3I+PC9uYW1lY2hnPic7CiAgICAgIGlmICghYWNjb3VudHMuY2hlY2tQYXNz
d29yZChhY2NvdW50LCBnZXQoJ3B3JykpKSB7IGZhaWxlZFRyeShhZGRyZXNzKTsgcmV0dXJuICc8
bmFtZWNoZz48ZXJyb3I+cHdkPC9lcnJvcj48L25hbWVjaGc+JzsgfQogICAgICBjb25zdCBuYW1l
ID0gY2xlYW5OYW1lKGdldCgnbm4nKSk7CiAgICAgIGlmICghbmFtZSkgcmV0dXJuICc8bmFtZWNo
Zz48ZXJyb3I+bmFtZTwvZXJyb3I+PC9uYW1lY2hnPic7CiAgICAgIGNvbnN0IG90aGVyID0gYWNj
b3VudHMuYnlOYW1lKG5hbWUpOwogICAgICBpZiAob3RoZXIgJiYgb3RoZXIgIT09IGFjY291bnQp
IHJldHVybiAnPG5hbWVjaGc+PGVycm9yPnNhbWVuYW1lPC9lcnJvcj48L25hbWVjaGc+JzsKICAg
ICAgYWNjb3VudC5uYW1lID0gbmFtZTsKICAgICAgYWNjb3VudHMuc2F2ZSgpOwogICAgICByZXR1
cm4gYDxuYW1lY2hnPjxtPiR7YWNjb3VudC5uYW1lQ2hhbmdlc308L20+PC9uYW1lY2hnPmA7CiAg
ICB9CiAgICBpZiAoc2VydmljZSA9PT0gJ3B3ZGNoZy5waHAnKSB7CiAgICAgIGlmICghY2hlY2tD
YXB0Y2hhKGdldCgnYycpLCBnZXQoJ3MnKSkpIHJldHVybiAnPHB3ZGNoZz48ZXJyb3I+Y29kZTwv
ZXJyb3I+PC9wd2RjaGc+JzsKICAgICAgY29uc3QgYWNjb3VudCA9IGJ5SWQoKTsKICAgICAgaWYg
KCFhY2NvdW50KSByZXR1cm4gJzxwd2RjaGc+PGVycm9yPnNhPC9lcnJvcj48L3B3ZGNoZz4nOwog
ICAgICBpZiAoIWFjY291bnRzLmNoZWNrUGFzc3dvcmQoYWNjb3VudCwgZ2V0KCdwdycpKSkgeyBm
YWlsZWRUcnkoYWRkcmVzcyk7IHJldHVybiAnPHB3ZGNoZz48ZXJyb3I+cHdkPC9lcnJvcj48L3B3
ZGNoZz4nOyB9CiAgICAgIGFjY291bnRzLnNldFBhc3N3b3JkKGFjY291bnQsIGdldCgnbnB3Jykp
OwogICAgICByZXR1cm4gJzxwd2RjaGc+PG9rPjE8L29rPjwvcHdkY2hnPic7CiAgICB9CiAgICBp
ZiAoc2VydmljZSA9PT0gJ3B3ZHJldC5waHAnKSB7CiAgICAgIC8vIE5vIGUtbWFpbCBnb2VzIG91
dCBmcm9tIGhlcmU6IHdob2V2ZXIgcnVucyB0aGUgcmVsYXkgY2FuIHJlbW92ZSB0aGUgYWNjb3Vu
dCBpbnN0ZWFkLgogICAgICByZXR1cm4gJzxwd2RyZXQ+PGVycm9yPm1haWw8L2Vycm9yPjwvcHdk
cmV0Pic7CiAgICB9CiAgICByZXR1cm4gbnVsbDsKICB9CgogIGZ1bmN0aW9uIHJvb21MaXN0WG1s
KCkgewogICAgbGV0IHRleHQgPSAnPHJvb21saXN0Pic7CiAgICBmb3IgKGNvbnN0IHJvb20gb2Yg
cm9vbXMpIHsKICAgICAgdGV4dCArPSBgPHJvb20+PHQ+MTwvdD48cm4+JHt4bWxUZXh0KHJvb20u
bmFtZSl9PC9ybj48ZGM+JHt4bWxUZXh0KHJvb20uZGVzY3JpcHRpb24pfTwvZGM+PGNjPiR7cm9v
bS5jY308L2NjPmAKICAgICAgICArIGA8bj4ke3Jvb20uY29ubmVjdGVkfTwvbj48bmw+JHtyb29t
LmxpbWl0fTwvbmw+PHBwbD4ke3htbFRleHQocm9vbS5wZW9wbGUoKSl9PC9wcGw+YAogICAgICAg
ICsgYDxpcD4ke0hPU1R9PC9pcD48cHQ+JHtQT1JUICsgcm9vbS5udW1iZXIgLSAxfTwvcHQ+PC9y
b29tPmA7CiAgICB9CiAgICByZXR1cm4gdGV4dCArICc8L3Jvb21saXN0Pic7CiAgfQoKICAvLyBS
ZXR1cm5zIHRydWUgd2hlbiB0aGUgcmVxdWVzdCB3YXMgb25lIG9mIHRoZXNlIGFuZCBoYXMgYmVl
biBhbnN3ZXJlZCAob3IgaXMgYmVpbmcgYW5zd2VyZWQpLgogIGZ1bmN0aW9uIGhhbmRsZShyZXEs
IHJlcywgcGF0aG5hbWUpIHsKICAgIGlmICghcGF0aG5hbWUuc3RhcnRzV2l0aCgnL2hmLycpKSBy
ZXR1cm4gZmFsc2U7CiAgICBjb25zdCBoZWFkZXJzID0geyAnY2FjaGUtY29udHJvbCc6ICduby1z
dG9yZScsICd4LWNvbnRlbnQtdHlwZS1vcHRpb25zJzogJ25vc25pZmYnLCAuLi5hbGxvd09yaWdp
bihyZXEpIH07CiAgICBpZiAocmVxLm1ldGhvZCA9PT0gJ09QVElPTlMnKSB7CiAgICAgIHJlcy53
cml0ZUhlYWQoMjA0LCB7IC4uLmhlYWRlcnMsICdhY2Nlc3MtY29udHJvbC1hbGxvdy1tZXRob2Rz
JzogJ0dFVCwgUE9TVCwgT1BUSU9OUycsICdhY2Nlc3MtY29udHJvbC1hbGxvdy1oZWFkZXJzJzog
J2NvbnRlbnQtdHlwZScgfSk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuIHRydWU7CiAg
ICB9CiAgICBjb25zdCBzZW5kID0gKHN0YXR1cywgdHlwZSwgYm9keSkgPT4gewogICAgICByZXMu
d3JpdGVIZWFkKHN0YXR1cywgeyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBlJzogdHlwZSB9KTsK
ICAgICAgcmVzLmVuZChib2R5KTsKICAgIH07CiAgICBpZiAocmVxLm1ldGhvZCAhPT0gJ0dFVCcg
JiYgcmVxLm1ldGhvZCAhPT0gJ1BPU1QnKSB7CiAgICAgIHNlbmQoNDA1LCAndGV4dC9wbGFpbjsg
Y2hhcnNldD11dGYtOCcsICdtZXRob2Qgbm90IGFsbG93ZWRcbicpOwogICAgICByZXR1cm4gdHJ1
ZTsKICAgIH0KICAgIGNvbnN0IHVybCA9IG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9yZWxheS5p
bnZhbGlkJyk7CiAgICBjb25zdCBsb2NhbCA9IHBhdGhuYW1lLnNsaWNlKCcvaGYvJy5sZW5ndGgp
OwogICAgaWYgKGxvY2FsID09PSAndmVyLnR4dCcpIHsKICAgICAgc2VuZCgyMDAsICd0ZXh0L3ht
bDsgY2hhcnNldD11dGYtOCcsICc8dmVyPjxyZXMgdmVyc2lvbj0iNzAwIiBsb2NhbD0iMCIgLz48
L3Zlcj4nKTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBpZiAobG9jYWwgPT09ICdyb29t
cy5qc29uJykgewogICAgICBzZW5kKDIwMCwgJ2FwcGxpY2F0aW9uL2pzb247IGNoYXJzZXQ9dXRm
LTgnLCBKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgaG9zdDogSE9TVCwgcm9vbXM6IHJvb21zLm1h
cCgocm9vbSkgPT4gKHsgcm9vbTogcm9vbS5udW1iZXIsIHBvcnQ6IFBPUlQgKyByb29tLm51bWJl
ciAtIDEsIG5hbWU6IHJvb20ubmFtZSwgcGxheWVyczogcm9vbS5jb25uZWN0ZWQsIGxpbWl0OiBy
b29tLmxpbWl0IH0pKSwKICAgICAgfSkpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlm
IChsb2NhbCA9PT0gJ2hmL3JsZy5waHAnKSB7CiAgICAgIHNlbmQoMjAwLCAndGV4dC94bWw7IGNo
YXJzZXQ9dXRmLTgnLCByb29tTGlzdFhtbCgpKTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAg
ICBpZiAobG9jYWwgPT09ICdzL3ByZW1pdW0nKSB7CiAgICAgIHJlcy5zZXRIZWFkZXIoJ2NvbnRl
bnQtc2VjdXJpdHktcG9saWN5JywgImRlZmF1bHQtc3JjICdub25lJzsgc3R5bGUtc3JjICd1bnNh
ZmUtaW5saW5lJyIpOwogICAgICBzZW5kKDIwMCwgJ3RleHQvaHRtbDsgY2hhcnNldD11dGYtOCcs
IFBSRU1JVU1fUEFHRSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYgKGxvY2FsLnN0
YXJ0c1dpdGgoJ3MvJykpIHsKICAgICAgLy8gVGhlIGdhbWUgcG9zdHMgaXRzIGZvcm1zIHdpdGgg
dGhlIHZhbHVlcyBpbiB0aGUgYWRkcmVzczsgYSBib2R5LCBpZiBhbnksIGlzIHJlYWQgYXMgYSBm
b3JtIHRvby4KICAgICAgbGV0IGJvZHkgPSAnJzsKICAgICAgcmVxLnNldEVuY29kaW5nKCd1dGY4
Jyk7CiAgICAgIHJlcS5vbignZGF0YScsIChjaHVuaykgPT4geyBpZiAoYm9keS5sZW5ndGggPCA4
MTkyKSBib2R5ICs9IGNodW5rOyB9KTsKICAgICAgcmVxLm9uKCdlbmQnLCAoKSA9PiB7CiAgICAg
ICAgY29uc3QgcGFyYW1zID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh1cmwuc2VhcmNoKTsKICAgICAg
ICBpZiAoYm9keSAmJiAvXltcdyUuKz0mLV0qJC8udGVzdChib2R5KSkgZm9yIChjb25zdCBba2V5
LCB2YWx1ZV0gb2YgbmV3IFVSTFNlYXJjaFBhcmFtcyhib2R5KSkgaWYgKCFwYXJhbXMuaGFzKGtl
eSkpIHBhcmFtcy5zZXQoa2V5LCB2YWx1ZSk7CiAgICAgICAgbGV0IHJlcGx5OwogICAgICAgIHRy
eSB7CiAgICAgICAgICByZXBseSA9IGFuc3dlcihsb2NhbC5zbGljZSgyKSwgcGFyYW1zLCBjbGll
bnRBZGRyZXNzKHJlcSkpOwogICAgICAgIH0gY2F0Y2ggKGVycm9yKSB7CiAgICAgICAgICBsb2co
YGhmOiAke2xvY2FsfTogJHtlcnJvci5zdGFjayB8fCBlcnJvcn1gKTsKICAgICAgICAgIHJlcGx5
ID0gJzxlcnJvcj48ZXJyb3I+c2VydmVyPC9lcnJvcj48L2Vycm9yPic7CiAgICAgICAgfQogICAg
ICAgIGlmIChyZXBseSA9PT0gbnVsbCkgc2VuZCg0MDQsICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0
Zi04JywgJ25vdCBmb3VuZFxuJyk7CiAgICAgICAgZWxzZSBzZW5kKDIwMCwgJ3RleHQveG1sOyBj
aGFyc2V0PXV0Zi04JywgcmVwbHkpOwogICAgICB9KTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9
CiAgICBzZW5kKDQwNCwgJ3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnLCAnbm90IGZvdW5kXG4n
KTsKICAgIHJldHVybiB0cnVlOwogIH0KCiAgLy8gQSBnYW1lJ3Mgc29ja2V0IHRvIHJvb20gbiwg
dGhyb3VnaCB0aGUgcGFnZSdzIFdlYlNvY2tldC4KICBmdW5jdGlvbiBjb25uZWN0KHdzLCByZXEs
IHVybCkgewogICAgY29uc3QgbnVtYmVyID0gTnVtYmVyKHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdy
b29tJykpOwogICAgY29uc3Qgcm9vbSA9IHJvb21zW251bWJlciAtIDFdOwogICAgaWYgKCFOdW1i
ZXIuaXNJbnRlZ2VyKG51bWJlcikgfHwgIXJvb20pIHsKICAgICAgd3MuY2xvc2UoNDAwMCwgJ1Jl
bGF5OiBubyBzdWNoIEhlcm8gRmlnaHRlciByb29tJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAg
IGNvbnN0IGNvbm5lY3Rpb24gPSBuZXcgSGZDb25uZWN0aW9uKHJvb20sIHsKICAgICAgd3JpdGUo
dGV4dCkgewogICAgICAgIGlmICh3cy5yZWFkeVN0YXRlICE9PSAxKSByZXR1cm47CiAgICAgICAg
aWYgKHdzLmJ1ZmZlcmVkQW1vdW50ID4gY29uZmlnLm1heEJ1ZmZlcmVkQnl0ZXMpIHsKICAgICAg
ICAgIHdzLmNsb3NlKDQwMTYsICdSZWxheTogeW91ciBjb25uZWN0aW9uIGlzIHRvbyBzbG93IGZv
ciB0aGUgZ2FtZScpOwogICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3cy5zZW5k
KEJ1ZmZlci5mcm9tKHRleHQsICd1dGY4JyksIHsgYmluYXJ5OiB0cnVlIH0pOwogICAgICB9LAog
ICAgICBjbG9zZSgpIHsgaWYgKHdzLnJlYWR5U3RhdGUgPT09IDAgfHwgd3MucmVhZHlTdGF0ZSA9
PT0gMSkgd3MuY2xvc2UoMTAwMCwgJ1JlbGF5OiByb29tIGxlZnQnKTsgfSwKICAgIH0sIHsgYWRk
cmVzczogY2xpZW50QWRkcmVzcyhyZXEpLCBidWlsZDogU3RyaW5nKHVybC5zZWFyY2hQYXJhbXMu
Z2V0KCdidWlsZCcpIHx8ICcnKS5yZXBsYWNlKC9bXlx3ListXS9nLCAnJykuc2xpY2UoMCwgODAp
IH0pOwogICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSkgPT4gewogICAgICBpZiAoYnVkZ2V0ICYm
ICFidWRnZXQod3MsIGRhdGEubGVuZ3RoKSkgewogICAgICAgIHdzLmNsb3NlKDQwMDcsICdSZWxh
eTogdG9vIG11Y2ggdHJhZmZpYycpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBjb25u
ZWN0aW9uLnJlY2VpdmUoQnVmZmVyLmlzQnVmZmVyKGRhdGEpID8gZGF0YSA6IEJ1ZmZlci5mcm9t
KGRhdGEpKTsKICAgIH0pOwogICAgd3Mub24oJ2Nsb3NlJywgKCkgPT4gY29ubmVjdGlvbi5jbG9z
ZWQoKSk7CiAgfQoKICByZXR1cm4gewogICAgaGFuZGxlLAogICAgY29ubmVjdCwKICAgIHJvb21z
LAogICAgYWNjb3VudHMsCiAgICBkZXNjcmliZTogKCkgPT4gKHsgcm9vbXM6IHJvb21zLmxlbmd0
aCwgcGxheWVyczogcm9vbXMucmVkdWNlKChzdW0sIHJvb20pID0+IHN1bSArIHJvb20uY29ubmVj
dGVkLCAwKSB9KSwKICAgIGNsb3NlKCkgewogICAgICBjbGVhckludGVydmFsKHBydW5lVGltZXIp
OwogICAgICBmb3IgKGNvbnN0IHJvb20gb2Ygcm9vbXMpIHJvb20uY2xvc2UoKTsKICAgICAgYWNj
b3VudHMuZmx1c2goKTsKICAgIH0sCiAgfTsKfQoKLy8gVGhlIGFkZHJlc3MgdGhlIGdhbWUgaXMg
Z2l2ZW4gZm9yIHRoZSByb29tczogYW55IG5hbWUgd29ya3MsIHRoZSBwYWdlJ3Mgc29ja2V0IHBy
b3h5IG1hcHMgaXQgKHdpdGgKLy8gdGhlIHBvcnQsIG9uZSBwZXIgcm9vbSkgdG8gdGhlIHJlbGF5
J3MgV2ViU29ja2V0Lgpjb25zdCBIT1NUID0gJ2hmLm9wZW5sZjInOwpjb25zdCBQT1JUID0gODg4
ODsKCm1vZHVsZS5leHBvcnRzID0geyBjcmVhdGVIZiwgc3RhdHVzQ29kZSwgZW5jb2RlTnVtYmVy
LCBzZXR0bGVkVmFsdWVzLCBMT0NLRUQsIEhPU1QsIFBPUlQgfTsK
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
LSBBIHJvb20gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpmdW5jdGlvbiBuZXdN
YW4oKSB7IC8vIGFzCiAgcmV0dXJuIHsgY2xpZW50OiAtMSwgY29udHJvbGxlcjogLTEsIHRlYW06
IDAsIGxldmVsOiAxLCBjaGFyOiAnJywgcmFuZG9tOiB0cnVlLCBleGlzdHM6IGZhbHNlLCBjb21t
YW5kZXI6IC0xIH07Cn0KCmZ1bmN0aW9uIG5ld1Nsb3QoKSB7IC8vIFIKICBjb25zdCBsZXZlbHMg
PSBuZXcgQXJyYXkoMzApLmZpbGwoMCk7CiAgbGV2ZWxzWzBdID0gbGV2ZWxzWzFdID0gbGV2ZWxz
WzJdID0gMTsKICByZXR1cm4gewogICAgbmFtZTogJycsIHBsYXllcnM6IFsnJywgJycsICcnXSwg
bGV2ZWxzLCBjYzogJycsIGNvdW50cnk6ICcnLCBvbmxpbmU6IGZhbHNlLCBoYXNQbGF5ZXI6IGZh
bHNlLCBwYXVzZWQ6IGZhbHNlLAogICAgY29ubmVjdGlvbjogbnVsbCwgcGFnZTogJ1dBSVRST09N
JywgZmlnaHRpbmc6IGZhbHNlLCBsYXRlbmN5OiAwLCBsYXRlbmN5U2hvd246IDAsIGxhdGVuY3lU
YXJnZXQ6IDAsCiAgICBzdGFydGVkOiBmYWxzZSwgbGFzdFBhY2tldDogLTEsIGxlZnRGcmFtZTog
LTEsIGZyYW1lczogbmV3IEFycmF5KEZSQU1FU19LRVBUKSwgbGFzdE1lc3NhZ2U6IDAsIGxhc3RB
Y3RpdmU6IDAsCiAgICBhZG1pbjogZmFsc2UsIGZsdXNoZXM6IDAsCiAgfTsKfQoKY29uc3Qgc2xl
ZXAgPSAobXMpID0+IG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiBzZXRUaW1lb3V0KHJlc29sdmUs
IG1zKSk7CgpjbGFzcyBIZlJvb20gewogIGNvbnN0cnVjdG9yKHsgbnVtYmVyLCBuYW1lLCBkZXNj
cmlwdGlvbiA9ICcnLCBjYyA9ICdWTicsIGxpbWl0ID0gQ0xJRU5UUywgcmFuZG9tID0gTWF0aC5y
YW5kb20sIGxvZyA9ICgpID0+IHt9IH0pIHsKICAgIHRoaXMubnVtYmVyID0gbnVtYmVyOwogICAg
dGhpcy5uYW1lID0gbmFtZTsgLy8gTWFpbi56CiAgICB0aGlzLmRlc2NyaXB0aW9uID0gZGVzY3Jp
cHRpb247IC8vIE1haW4uQQogICAgdGhpcy5jYyA9IGNjOyAvLyBNYWluLkUKICAgIHRoaXMubGlt
aXQgPSBNYXRoLm1pbihDTElFTlRTLCBNYXRoLm1heCgyLCBsaW1pdCkpOyAvLyBNYWluLk8KICAg
IHRoaXMucGFzc3dvcmQgPSAnJzsgLy8gTWFpbi5DIC8gTWFpbi5EIChyb29tcyBoZXJlIGhhdmUg
bm9uZSkKICAgIHRoaXMubGF0ZW5jeUxpbWl0ID0gLTE7IC8vIE1haW4uYUoKICAgIHRoaXMuYWZr
TWludXRlcyA9IC0xOyAvLyBNYWluLmFMCiAgICB0aGlzLnJhbmRvbSA9IHJhbmRvbTsKICAgIHRo
aXMubG9nID0gbG9nOwogICAgdGhpcy5zbG90cyA9IEFycmF5LmZyb20oeyBsZW5ndGg6IFNMT1RT
IH0sIG5ld1Nsb3QpOyAvLyBNYWluLmFwCiAgICB0aGlzLnNsb3RzW0hPU1RfU0xPVF0ubmFtZSA9
ICc8Zm9udCBjb2xvcj0iI0NDRkZGRiI+Um9vbSBIb3N0PC9mb250Pic7CiAgICB0aGlzLm1lbiA9
IFtdOyAvLyBNYWluLmFxCiAgICB0aGlzLmNvbm5lY3RlZCA9IDA7IC8vIE1haW4uTQogICAgdGhp
cy5jb25uZWN0aW9ucyA9IG5ldyBTZXQoKTsKICAgIC8vIGguYSwgaC5iOiB0aGUgcmFuZG9tIHRh
YmxlIGFuZCBpdHMgc3RhcnRpbmcgcG9pbnQsIHRoZSBzYW1lIGZvciBldmVyeSBnYW1lIGluIHRo
ZSByb29tLgogICAgdGhpcy50YWJsZSA9IEFycmF5LmZyb20oeyBsZW5ndGg6IDUwMDAgfSwgKCkg
PT4gdGhpcy5uZXh0SW50KDEwMDAwKSk7CiAgICB0aGlzLnNlZWQgPSB0aGlzLm5leHRJbnQoNTAw
MCk7CiAgICB0aGlzLndpblJlcG9ydGVkID0gZmFsc2U7IC8vIGguYwogICAgdGhpcy5idWlsZCA9
IG51bGw7IC8vIHRoZSBidWlsZCBvZiB0aGUgZ2FtZXMgaW4gdGhlIHJvb20gKGFjY2VwdHNCdWls
ZCkKICAgIHRoaXMuc3RlcHMgPSBuZXcgTWFwKCk7IC8vIGZyYW1lIC0+IHRoZSByYW5kb20gbnVt
YmVycyB1c2VkIGJ5IHRoZW4sIGFzIHRoZSBmaXJzdCBnYW1lIHJlcG9ydGVkIGl0CiAgICB0aGlz
Lm91dE9mU3RlcCA9IGZhbHNlOwogICAgdGhpcy5zdGFydGluZyA9IGZhbHNlOyAvLyBNYWluLnI6
IGEgZmlnaHQgaXMgc3RhcnRpbmc7IGZyYW1lcyB3YWl0IHVudGlsIGV2ZXJ5IGdhbWUgaGFzIHN0
YXJ0ZWQKICAgIHRoaXMuY291bnRkb3duID0geyBvbjogZmFsc2UsIGNvdW50OiBDT1VOVERPV04s
IGFjdGlvbjogJycgfTsgLy8gVC5hLCBULmIsIFQuZAogICAgdGhpcy5maWdodGluZ05vdyA9IGZh
bHNlOyAvLyBNYWluLmFtCiAgICB0aGlzLm1vZGUgPSAnV0FJVFJPT00nOyAvLyBNYWluLmFrCiAg
ICB0aGlzLnBhZ2UgPSAnV0FJVFJPT00nOyAvLyBNYWluLmFsCiAgICB0aGlzLnByZXZpb3VzUGFn
ZSA9ICcnOyAvLyBNYWluLmFuCiAgICB0aGlzLnN0b3J5ID0gMDsgLy8gTWFpbi5hbwogICAgdGhp
cy5iYXR0bGVUeXBlID0gMTExMTsgLy8gTWFpbi5hQwogICAgdGhpcy5wcmVzZXQgPSAtMTsgLy8g
TWFpbi5hRAogICAgdGhpcy50ZWFtcyA9IDQ7IC8vIE1haW4uYUUKICAgIHRoaXMudGVhbU1hcCA9
IFswLCAxLCAyLCAzXTsgLy8gTWFpbi5hRgogICAgdGhpcy5yZXNldCgpOwogICAgdGhpcy5jbG9z
ZWQgPSBmYWxzZTsKICAgIHRoaXMudGltZXJzID0gW107CiAgICAvLyBUaGUgb3JpZ2luYWwncyB0
aHJlYWRzOiB0aGUgY291bnRkb3duIChULCBldmVyeSAxMDAgbXMpLCBmcmFtZSBzZW5kaW5nIChh
diwgZXZlcnkgMTAgbXMpIGFuZAogICAgLy8gdGhlIHdhdGNoZG9nIHRoYXQgcGluZ3MgYW5kIHRp
bWVzIG91dCBnYW1lcyAoYUEsIGV2ZXJ5IDIgcyBhZnRlciAxMCBzKS4KICAgIHRoaXMuY291bnRk
b3duVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHRoaXMuY291bnRkb3duVGljaygpLCAxMDApOwog
ICAgdGhpcy50aW1lcnMucHVzaChzZXRJbnRlcnZhbCgoKSA9PiB0aGlzLmZsdXNoVGljaygpLCAx
MCkpOwogICAgdGhpcy53YXRjaGRvZ1N0YXJ0ID0gc2V0VGltZW91dCgoKSA9PiB7IHRoaXMudGlt
ZXJzLnB1c2goc2V0SW50ZXJ2YWwoKCkgPT4gdGhpcy53YXRjaGRvZygpLCAyMDAwKSk7IH0sIDEw
MDAwKTsKICAgIGZvciAoY29uc3QgdGltZXIgb2YgdGhpcy50aW1lcnMpIGlmICh0aW1lci51bnJl
ZikgdGltZXIudW5yZWYoKTsKICB9CgogIG5leHRJbnQoYm91bmQpIHsgcmV0dXJuIE1hdGguZmxv
b3IodGhpcy5yYW5kb20oKSAqIGJvdW5kKTsgfQoKICBjbG9zZSgpIHsKICAgIHRoaXMuY2xvc2Vk
ID0gdHJ1ZTsKICAgIGNsZWFyVGltZW91dCh0aGlzLmNvdW50ZG93blRpbWVyKTsKICAgIGNsZWFy
VGltZW91dCh0aGlzLndhdGNoZG9nU3RhcnQpOwogICAgZm9yIChjb25zdCB0aW1lciBvZiB0aGlz
LnRpbWVycykgY2xlYXJJbnRlcnZhbCh0aW1lcik7CiAgICBmb3IgKGNvbnN0IGNvbm5lY3Rpb24g
b2YgWy4uLnRoaXMuY29ubmVjdGlvbnNdKSBjb25uZWN0aW9uLmNsb3NlKCk7CiAgfQoKICAvLyBN
YWluLms6IHRoZSBzZXR0aW5ncyBhbmQgdGhlIG1lbiBhIHJvb20gc3RhcnRzIHdpdGguCiAgcmVz
ZXQoKSB7CiAgICB0aGlzLmFsbG93Sm9pbldoZW5GaWdodGluZyA9IHRydWU7IC8vIE1haW4uVgog
ICAgdGhpcy5waWNrTXVzaWMoKTsKICAgIHRoaXMubXVzaWNSYW5kb20gPSB0cnVlOyAvLyBNYWlu
LlgKICAgIHRoaXMubXVsdGlwbGFuZSA9IHRydWU7IC8vIE1haW4uYWIKICAgIHRoaXMuYmFja2dy
b3VuZCA9ICdyb29tMSc7IC8vIE1haW4uWQogICAgdGhpcy5iYWNrZ3JvdW5kQ2hvc2VuID0gJ3Jv
b20xJzsgLy8gTWFpbi5aCiAgICB0aGlzLmJhY2tncm91bmRSYW5kb20gPSBmYWxzZTsgLy8gTWFp
bi5XCiAgICB0aGlzLmhvcnNlcyA9IDA7IC8vIE1haW4uYWMKICAgIHRoaXMuZ2lhbnRPYmplY3Rz
ID0gMDsgLy8gTWFpbi5hZAogICAgdGhpcy5kaWZmaWN1bHR5ID0gMDsgLy8gTWFpbi5hZQogICAg
dGhpcy5ub3JtYWxpemVMZXZlbCA9IDE7IC8vIE1haW4uYWkKICAgIHRoaXMuZGlub3NhdXJzID0g
MDsgLy8gTWFpbi5hagogICAgdGhpcy50ZXN0VHJvb3BzID0gMDsgLy8gTWFpbi5hZgogICAgdGhp
cy5zb2xkaWVyTnVtYmVyID0gMTsgLy8gTWFpbi5hZwogICAgdGhpcy5zb2xkaWVyUmVzZXJ2ZWQg
PSAxOyAvLyBNYWluLmFoCiAgICB0aGlzLnN0b3J5ID0gMDsKICAgIHRoaXMubW9kZSA9ICdXQUlU
Uk9PTSc7CiAgICB0aGlzLnBhZ2UgPSAnV0FJVFJPT00nOwogICAgdGhpcy5wcmV2aW91c1BhZ2Ug
PSAnJzsKICAgIHRoaXMubWVuID0gQXJyYXkuZnJvbSh7IGxlbmd0aDogTUVOIH0sIG5ld01hbik7
CiAgfQoKICAvLyBBIGNvbXB1dGVyIHBsYXllcidzIGxldmVsIHdpdGggYSBjaGFyYWN0ZXI6IHRo
ZSBiZXN0IGEgcGxheWVyIGluIHRoZSByb29tIGhhcywgZWxzZSB0aGUgZ2FtZSdzIGhpZ2hlc3Qu
CiAgY29tcHV0ZXJMZXZlbChjaGFyYWN0ZXIpIHsKICAgIGxldCBsZXZlbCA9IDA7CiAgICBmb3Ig
KGNvbnN0IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkgaWYgKHNsb3QubGV2ZWxzW2NoYXJhY3Rlcl0g
PiBsZXZlbCkgbGV2ZWwgPSBzbG90LmxldmVsc1tjaGFyYWN0ZXJdOwogICAgcmV0dXJuIGxldmVs
ID4gMCA/IGxldmVsIDogTUFYX0xFVkVMOwogIH0KCiAgLy8gV2hldGhlciBhIGdhbWUgb2YgdGhp
cyBidWlsZCAoaXRzIG1vdmllIGFuZCBSdWZmbGUsIGFzIHRoZSBwYWdlIHJlcG9ydHMgdGhlbSkg
bWF5IGpvaW46IHRoZSBzYW1lIGFzCiAgLy8gdGhlIGdhbWVzIGluIHRoZSByb29tLCB3aG9zZSBz
aW11bGF0aW9ucyBtdXN0IG1hdGNoIHN0ZXAgZm9yIHN0ZXAuCiAgYWNjZXB0c0J1aWxkKGJ1aWxk
KSB7CiAgICBpZiAoIXRoaXMub25saW5lKCkubGVuZ3RoKSB0aGlzLmJ1aWxkID0gYnVpbGQ7CiAg
ICByZXR1cm4gdGhpcy5idWlsZCA9PT0gYnVpbGQ7CiAgfQoKICAvLyBFdmVyeSBnYW1lIHJlcG9y
dHMsIGV2ZXJ5IDIwIGZyYW1lcywgaG93IG1hbnkgcmFuZG9tIG51bWJlcnMgaXQgaGFzIHVzZWQg
c28gZmFyICg8cnBjPik7IGdhbWVzIHRoYXQKICAvLyBkaWZmZXIgbm8gbG9uZ2VyIHNob3cgdGhl
IHNhbWUgZmlnaHQuIFRoZSBvcmlnaW5hbCBwYXNzZWQgdGhlc2Ugb24gYW5kIHRoZSBnYW1lcyB0
aGVtc2VsdmVzIGNsb3NlZAogIC8vIHRoZSBjb25uZWN0aW9uIG9uIGEgZGlmZmVyZW5jZSAoIlN5
bmNocm9uaXphdGlvbiBlcnJvciIpLCB3aGljaCB0aHJldyBldmVyeW9uZSBvdXQgb2YgdGhlIHJv
b207IGhlcmUKICAvLyB0aGUgc2VydmVyIGNvbXBhcmVzIHRoZW0gYW5kIGVuZHMgdGhlIGZpZ2h0
IGluc3RlYWQsIGJhY2sgdG8gdGhlIG1lbnVzLCB3aXRoIGV2ZXJ5b25lIHN0aWxsIGluLgogIGNo
ZWNrU3RlcChpbmRleCwgZnJhbWUsIHVzZWQpIHsKICAgIGlmICghdGhpcy5maWdodGluZ05vdyB8
fCB0aGlzLm91dE9mU3RlcCkgcmV0dXJuOwogICAgY29uc3Qgc2VlbiA9IHRoaXMuc3RlcHMuZ2V0
KGZyYW1lKTsKICAgIGlmICghc2VlbikgewogICAgICB0aGlzLnN0ZXBzLnNldChmcmFtZSwgeyB1
c2VkLCBmcm9tOiBpbmRleCB9KTsKICAgICAgaWYgKHRoaXMuc3RlcHMuc2l6ZSA+IDY0KSB0aGlz
LnN0ZXBzLmRlbGV0ZSh0aGlzLnN0ZXBzLmtleXMoKS5uZXh0KCkudmFsdWUpOwogICAgICByZXR1
cm47CiAgICB9CiAgICBpZiAoc2Vlbi51c2VkID09PSB1c2VkKSByZXR1cm47CiAgICB0aGlzLm91
dE9mU3RlcCA9IHRydWU7CiAgICB0aGlzLmxvZyhgaGYgcm9vbSAke3RoaXMubnVtYmVyfTogZ2Ft
ZXMgJHtzZWVuLmZyb219IGFuZCAke2luZGV4fSBvdXQgb2Ygc3RlcCBhdCBmcmFtZSAke2ZyYW1l
fTogZW5kaW5nIHRoZSBmaWdodGApOwogICAgZm9yIChjb25zdCBzbG90IG9mIHRoaXMub25saW5l
KCkpIHsKICAgICAgc2xvdC5jb25uZWN0aW9uLm5vdGljZSgnSGFpIG1heSBraG9uZyBjb24ga2hv
cCBuaGF1IChkZXN5bmMpOiB0cmFuIGRhdSBkdW5nIGxhaS4gQmFtIE5leHQgcm9pIFN0YXJ0IEZp
Z2h0ISBkZSBkYW5oIGxhaS4nKTsKICAgIH0KICAgIGNvbnN0IGNvdW50ZG93biA9IHRoaXMuY291
bnRkb3duOwogICAgY291bnRkb3duLm9uID0gdHJ1ZTsKICAgIGNvdW50ZG93bi5hY3Rpb24gPSAn
cXVpdGdhbWUnOwogICAgY291bnRkb3duLmNvdW50ID0gMTsKICB9CgogIHBpY2tCYWNrZ3JvdW5k
KCkgeyB0aGlzLmJhY2tncm91bmQgPSBCQUNLR1JPVU5EU1t0aGlzLm5leHRJbnQoQkFDS0dST1VO
RFMubGVuZ3RoKV07IH0gLy8gTWFpbi5hCiAgcGlja011c2ljKCkgeyB0aGlzLm11c2ljID0gTVVT
SUNbdGhpcy5uZXh0SW50KE1VU0lDLmxlbmd0aCldOyB9IC8vIE1haW4uYgoKICAvLyBNYWluLmY6
IGNvdW50cyB0aGUgY29tcHV0ZXJzOyBhIHJvb20gbm9ib2R5IHBsYXlzIGluIGFueSBtb3JlIHN0
YXJ0cyBvdmVyLgogIHJlY291bnQoKSB7CiAgICBsZXQgZW1wdHkgPSB0cnVlOwogICAgdGhpcy5j
b25uZWN0ZWQgPSAwOwogICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGlu
ZGV4ICs9IDEpIHsKICAgICAgY29uc3Qgc2xvdCA9IHRoaXMuc2xvdHNbaW5kZXhdOwogICAgICBp
ZiAoc2xvdC5vbmxpbmUpIHRoaXMuY29ubmVjdGVkICs9IDE7CiAgICAgIGlmICh0aGlzLnBhZ2Ug
PT09ICdXQUlUUk9PTScpIHsKICAgICAgICBpZiAoc2xvdC5vbmxpbmUpIGVtcHR5ID0gZmFsc2U7
CiAgICAgIH0gZWxzZSBpZiAoc2xvdC5vbmxpbmUgJiYgc2xvdC5wYWdlICE9PSAnV0FJVFJPT00n
KSB7CiAgICAgICAgZW1wdHkgPSBmYWxzZTsKICAgICAgfQogICAgfQogICAgaWYgKGVtcHR5KSB7
CiAgICAgIHRoaXMucmVzZXQoKTsKICAgICAgdGhpcy5icm9hZGNhc3RHYW1lU2V0dGluZygtMSk7
CiAgICAgIHRoaXMuYnJvYWRjYXN0U2V0dGluZygtMSk7CiAgICAgIHRoaXMuYnJvYWRjYXN0U3Rh
dHVzKCk7CiAgICAgIHRoaXMuYnJvYWRjYXN0TWVuKDEpOwogICAgfQogIH0KCiAgb25saW5lKCkg
ewogICAgY29uc3QgbGlzdCA9IFtdOwogICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENM
SUVOVFM7IGluZGV4ICs9IDEpIGlmICh0aGlzLnNsb3RzW2luZGV4XS5vbmxpbmUpIGxpc3QucHVz
aCh0aGlzLnNsb3RzW2luZGV4XSk7CiAgICByZXR1cm4gbGlzdDsKICB9CgogIGJyb2FkY2FzdCh0
ZXh0KSB7IGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSBzbG90LmNvbm5lY3Rpb24u
c2VuZCh0ZXh0KTsgfSAvLyBoLmEoU3RyaW5nKQogIGJyb2FkY2FzdExpc3Qoam9pbmVkLCBxdWl0
KSB7IGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSBzbG90LmNvbm5lY3Rpb24uc2Vu
ZExpc3Qoam9pbmVkLCBxdWl0KTsgfSAvLyBoLmEoaW50LCBpbnQpCiAgYnJvYWRjYXN0U2V0dGlu
ZyhjaWQpIHsgZm9yIChjb25zdCBzbG90IG9mIHRoaXMub25saW5lKCkpIHNsb3QuY29ubmVjdGlv
bi5zZW5kU2V0dGluZyhjaWQpOyB9IC8vIGguYihpbnQpCiAgYnJvYWRjYXN0R2FtZVNldHRpbmco
Y2lkKSB7IGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSBzbG90LmNvbm5lY3Rpb24u
c2VuZEdhbWVTZXR0aW5nKGNpZCk7IH0gLy8gaC5jKGludCkKICBicm9hZGNhc3RTdGF0dXMoKSB7
IC8vIGguZQogICAgZm9yIChjb25zdCBzbG90IG9mIHRoaXMub25saW5lKCkpIHsKICAgICAgc2xv
dC5jb25uZWN0aW9uLnNlbmQoYDxzdGF0dXM+PG1vZGU+JHt0aGlzLm1vZGV9PC9tb2RlPjxwYWdl
PiR7dGhpcy5wYWdlfTwvcGFnZT48cHJlcGFnZT4ke3RoaXMucHJldmlvdXNQYWdlfTwvcHJlcGFn
ZT5gCiAgICAgICAgKyBgPHN0b3J5aT4ke3RoaXMuc3Rvcnl9PC9zdG9yeWk+PC9zdGF0dXM+YCk7
CiAgICB9CiAgfQogIC8vIGguYShpbnQpOiBzb2xkaWVycyB3aG9zZSBjb21tYW5kZXIncyBjb21w
dXRlciBsZWZ0IGdvIHRvbzsgdGhlbiBldmVyeW9uZSBnZXRzIHRoZSBtZW4uCiAgYnJvYWRjYXN0
TWVuKGNoYW5nZWQpIHsKICAgIGZvciAoY29uc3QgbWFuIG9mIHRoaXMubWVuKSB7CiAgICAgIGlm
ICghbWFuLmV4aXN0cyB8fCBtYW4uY29tbWFuZGVyID09PSAtMSkgY29udGludWU7CiAgICAgIGNv
bnN0IGNvbW1hbmRlciA9IHRoaXMubWVuW21hbi5jb21tYW5kZXJdOwogICAgICBpZiAoY29tbWFu
ZGVyLmNsaWVudCAhPT0gLTEgJiYgIXRoaXMuc2xvdHNbY29tbWFuZGVyLmNsaWVudF0ub25saW5l
KSBtYW4uZXhpc3RzID0gZmFsc2U7CiAgICB9CiAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5v
bmxpbmUoKSkgc2xvdC5jb25uZWN0aW9uLnNlbmRNZW4oY2hhbmdlZCk7CiAgfQogIGJyb2FkY2Fz
dENvdW50KCkgeyAvLyBoLmMoKQogICAgdGhpcy5icm9hZGNhc3QoYDxzdGFydGNvdW50PjxhY3Rp
b24+JHt0aGlzLmNvdW50ZG93bi5hY3Rpb259PC9hY3Rpb24+PGNvdW50PiR7dGhpcy5jb3VudGRv
d24uY291bnR9PC9jb3VudD5gCiAgICAgICsgYDxwYWdlPiR7dGhpcy5wYWdlfTwvcGFnZT48L3N0
YXJ0Y291bnQ+YCk7CiAgfQogIGJyb2FkY2FzdENsaWNrKGNpZCwgd2hhdCkgeyB0aGlzLmJyb2Fk
Y2FzdChgPGNoYXQyPjxjPiR7Y2lkfTwvYz48bT4ke3doYXR9PC9tPjwvY2hhdDI+YCk7IH0gLy8g
aC5hKGludCwgU3RyaW5nKQogIG5ld1NlZWQoKSB7IC8vIGguZgogICAgdGhpcy5zZWVkID0gdGhp
cy5uZXh0SW50KDUwMDApOwogICAgdGhpcy5icm9hZGNhc3QoYDxycD48cnA+JHt0aGlzLnNlZWR9
PC9ycD48L3JwPmApOwogIH0KCiAgLy8gaC5hKCk6IHRoZSBmcmFtZXMgb2YgdGhlIGZpZ2h0IHN0
YXJ0IG92ZXIuCiAgcmVzZXRGcmFtZXMoKSB7CiAgICB0aGlzLnN0ZXBzLmNsZWFyKCk7CiAgICB0
aGlzLm91dE9mU3RlcCA9IGZhbHNlOwogICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENM
SUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgY29uc3Qgc2xvdCA9IHRoaXMuc2xvdHNbaW5kZXhd
OwogICAgICBzbG90LmZsdXNoZXMgPSAwOwogICAgICBzbG90LnBhdXNlZCA9IGZhbHNlOwogICAg
ICBzbG90LmZpZ2h0aW5nID0gZmFsc2U7CiAgICAgIHNsb3QubGFzdFBhY2tldCA9IC0xOwogICAg
ICBzbG90LmxlZnRGcmFtZSA9IC0xOwogICAgICBpZiAoc2xvdC5jb25uZWN0aW9uKSBzbG90LmNv
bm5lY3Rpb24ucmVzZXRGcmFtZXMoKTsKICAgIH0KICB9CgogIC8vIGguYigpOiBsYXRlbmNpZXMg
ZWFzZSB0b3dhcmRzIHRoZWlyIHRhcmdldHMuCiAgZWFzZUxhdGVuY2llcygpIHsKICAgIGZvciAo
bGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgIGNvbnN0
IHNsb3QgPSB0aGlzLnNsb3RzW2luZGV4XTsKICAgICAgaWYgKHNsb3Qub25saW5lKSBzbG90Lmxh
dGVuY3kgPSBNYXRoLnRydW5jKChzbG90LmxhdGVuY3lUYXJnZXQgKyBzbG90LmxhdGVuY3kgKiAz
KSAvIDQpOwogICAgfQogICAgdGhpcy5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgfQoKICAvLyBU
LmEoKTogYSBmaWdodCBzdGFydHM7IGZyYW1lcyB3YWl0IGZvciBldmVyeSBnYW1lLgogIHN0YXJ0
RmlnaHQoKSB7CiAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5zbG90cykgc2xvdC5zdGFydGVk
ID0gZmFsc2U7CiAgICB0aGlzLnN0YXJ0aW5nID0gdHJ1ZTsKICB9CgogIC8vIFRoZSBjb3VudGRv
d24gdGhyZWFkIChUKTogZXZlcnkgMTAwIG1zLCBhbmQgNDAwIG1zIG1vcmUgYWZ0ZXIgYSBzdGVw
IG9mIGEgY291bnRkb3duLgogIGNvdW50ZG93blRpY2soKSB7CiAgICBpZiAodGhpcy5jbG9zZWQp
IHJldHVybjsKICAgIGxldCBkZWxheSA9IDEwMDsKICAgIHRyeSB7CiAgICAgIGlmICh0aGlzLnN0
YXJ0aW5nKSB7CiAgICAgICAgdGhpcy5zdGFydGluZyA9IGZhbHNlOwogICAgICAgIGZvciAoY29u
c3Qgc2xvdCBvZiB0aGlzLnNsb3RzKSB7CiAgICAgICAgICBpZiAoc2xvdC5vbmxpbmUgJiYgIXNs
b3Quc3RhcnRlZCAmJiBzbG90LnBhZ2UgIT09ICdXQUlUUk9PTScpIHRoaXMuc3RhcnRpbmcgPSB0
cnVlOwogICAgICAgIH0KICAgICAgICBpZiAoIXRoaXMuc3RhcnRpbmcpIHsKICAgICAgICAgIGZv
ciAoY29uc3Qgc2xvdCBvZiB0aGlzLnNsb3RzKSBpZiAoc2xvdC5jb25uZWN0aW9uKSBzbG90LmNv
bm5lY3Rpb24ucmVzZXRGcmFtZXMoKTsKICAgICAgICAgIHRoaXMuc3RlcHMuY2xlYXIoKTsKICAg
ICAgICAgIHRoaXMub3V0T2ZTdGVwID0gZmFsc2U7CiAgICAgICAgICAvLyBFYWNoIGdhbWUgcmVw
b3J0cyBpdHMgZXhwZXJpZW5jZSBhZnRlciBhIGZpZ2h0IGFuZCB3YWl0cyBmb3IgdGhlIGFuc3dl
ciBiZWZvcmUgaXQgc3RhcnRzIHRoZQogICAgICAgICAgLy8gbmV4dCwgc2VuZGluZyBpdHMgY2hh
cmFjdGVycycgbGV2ZWxzICg8aW5mbz4pIG9uIHRoZSB3YXk7IGEgcmVzdGFydCBzZW5kcyB0aGUg
bWVuIGJlZm9yZQogICAgICAgICAgLy8gdGhvc2UgY29tZS4gU28gZXZlcnkgZ2FtZSBnZXRzIHRo
ZSBtZW4gYWdhaW4gbm93LCB3aXRoIHRoZSBzYW1lIGxldmVscyBmb3IgZXZlcnlvbmUgKGVhY2gK
ICAgICAgICAgIC8vIGdhbWUgYnVpbGRzIHRoZSBmaWdodCBmcm9tIHRoaXMgbGlzdCBvbmNlIDxh
bGxzdGFydGVkZ2FtZT4gY29tZXMpLgogICAgICAgICAgdGhpcy5icm9hZGNhc3RNZW4oMCk7CiAg
ICAgICAgICB0aGlzLm5ld1NlZWQoKTsKICAgICAgICAgIHRoaXMuYnJvYWRjYXN0KCc8YWxsc3Rh
cnRlZGdhbWU+PC9hbGxzdGFydGVkZ2FtZT4nKTsKICAgICAgICB9CiAgICAgIH0KICAgICAgY29u
c3QgY291bnRkb3duID0gdGhpcy5jb3VudGRvd247CiAgICAgIGlmIChjb3VudGRvd24ub24pIHsK
ICAgICAgICBjb3VudGRvd24uY291bnQgLT0gMTsKICAgICAgICBpZiAoY291bnRkb3duLmNvdW50
IDw9IDApIHsKICAgICAgICAgIHRoaXMuY291bnRkb3duRG9uZShjb3VudGRvd24uYWN0aW9uKTsK
ICAgICAgICAgIHRoaXMuYnJvYWRjYXN0Q291bnQoKTsKICAgICAgICAgIGNvdW50ZG93bi5jb3Vu
dCA9IENPVU5URE9XTjsKICAgICAgICAgIGNvdW50ZG93bi5vbiA9IGZhbHNlOwogICAgICAgIH0g
ZWxzZSB7CiAgICAgICAgICB0aGlzLmJyb2FkY2FzdENvdW50KCk7CiAgICAgICAgfQogICAgICAg
IGRlbGF5ICs9IDQwMDsKICAgICAgfQogICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgdGhpcy5s
b2coYGhmIHJvb20gJHt0aGlzLm51bWJlcn06IGNvdW50ZG93bjogJHtlcnJvci5zdGFjayB8fCBl
cnJvcn1gKTsKICAgIH0KICAgIHRoaXMuY291bnRkb3duVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+
IHRoaXMuY291bnRkb3duVGljaygpLCBkZWxheSk7CiAgfQoKICBlbnRlclBhZ2UocGFnZSwgcHJl
dmlvdXMpIHsKICAgIHRoaXMucGFnZSA9IHBhZ2U7CiAgICB0aGlzLmZpZ2h0aW5nTm93ID0gZmFs
c2U7CiAgICB0aGlzLnByZXZpb3VzUGFnZSA9IHByZXZpb3VzOwogIH0KCiAgY291bnRkb3duRG9u
ZShhY3Rpb24pIHsKICAgIGNvbnN0IHBhZ2UgPSB0aGlzLnBhZ2U7CiAgICBjb25zdCBtb2RlID0g
dGhpcy5tb2RlOwogICAgaWYgKGFjdGlvbiA9PT0gJ2NsaWNrdnMnICYmIHBhZ2UgPT09ICdXQUlU
Uk9PTScpIHsKICAgICAgdGhpcy5tb2RlID0gJ1ZTTU9ERSc7CiAgICAgIHRoaXMuZW50ZXJQYWdl
KCdDSEFSTUVOVScsICdXQUlUUk9PTScpOwogICAgICB0aGlzLmJhdHRsZVR5cGUgPSAxMTExOwog
ICAgICB0aGlzLnByZXNldCA9IC0xOwogICAgICBpZiAodGhpcy5iYWNrZ3JvdW5kQ2hvc2VuID09
PSAncmFuZG9tJykgewogICAgICAgIHRoaXMuYmFja2dyb3VuZCA9IEJBQ0tHUk9VTkRTW3RoaXMu
bmV4dEludChCQUNLR1JPVU5EUy5sZW5ndGgpXTsKICAgICAgICB0aGlzLmJhY2tncm91bmRSYW5k
b20gPSB0cnVlOwogICAgICB9IGVsc2UgewogICAgICAgIHRoaXMuYmFja2dyb3VuZCA9IHRoaXMu
YmFja2dyb3VuZENob3NlbjsKICAgICAgICB0aGlzLmJhY2tncm91bmRSYW5kb20gPSBmYWxzZTsK
ICAgICAgfQogICAgICB0aGlzLmFmdGVyUGFnZUNoYW5nZSgpOwogICAgfSBlbHNlIGlmIChhY3Rp
b24gPT09ICdjbGlja3N0b3J5JyAmJiBwYWdlID09PSAnV0FJVFJPT00nKSB7CiAgICAgIHRoaXMu
bW9kZSA9ICdTVE9SWU1PREUnOwogICAgICB0aGlzLmVudGVyUGFnZSgnU1RPUllNRU5VJywgJ1dB
SVRST09NJyk7CiAgICAgIHRoaXMuYWZ0ZXJQYWdlQ2hhbmdlKCk7CiAgICB9IGVsc2UgaWYgKGFj
dGlvbiA9PT0gJ2NsaWNrYmF0dGxlJyAmJiBwYWdlID09PSAnV0FJVFJPT00nKSB7CiAgICAgIHRo
aXMubW9kZSA9ICdCQVRUTEVNT0RFJzsKICAgICAgdGhpcy5lbnRlclBhZ2UoJ0JBVFRMRVNFVFRJ
TkdNRU5VJywgJ1dBSVRST09NJyk7CiAgICAgIHRoaXMuYmF0dGxlVHlwZSA9IDExMTE7CiAgICAg
IHRoaXMucHJlc2V0ID0gLTE7CiAgICAgIHRoaXMudGVhbXMgPSA0OwogICAgICB0aGlzLmJhY2tn
cm91bmQgPSAnYmF0dGxlNCc7CiAgICAgIHRoaXMuYmFja2dyb3VuZFJhbmRvbSA9IGZhbHNlOwog
ICAgICB0aGlzLmFmdGVyUGFnZUNoYW5nZSgpOwogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICdj
bGlja25leHQnICYmIHBhZ2UgPT09ICdCQVRUTEVTRVRUSU5HTUVOVScpIHsKICAgICAgdGhpcy5l
bnRlclBhZ2UoJ0NIQVJNRU5VJywgJ0JBVFRMRVNFVFRJTkdNRU5VJyk7CiAgICAgIGZvciAobGV0
IGluZGV4ID0gMDsgaW5kZXggPCBNRU47IGluZGV4ICs9IDEpIHsKICAgICAgICBjb25zdCBtYW4g
PSB0aGlzLm1lbltpbmRleF07CiAgICAgICAgaWYgKG1hbi5leGlzdHMgJiYgbWFuLnRlYW0gPj0g
dGhpcy50ZWFtcykgbWFuLnRlYW0gJT0gdGhpcy50ZWFtczsKICAgICAgICBpZiAoaW5kZXggPCBN
RU4gLSAxICYmIG1hbi5jb250cm9sbGVyID49IDApIHsKICAgICAgICAgIGZvciAobGV0IG90aGVy
ID0gaW5kZXggKyAxOyBvdGhlciA8IE1FTjsgb3RoZXIgKz0gMSkgewogICAgICAgICAgICBjb25z
dCBuZXh0ID0gdGhpcy5tZW5bb3RoZXJdOwogICAgICAgICAgICBpZiAobmV4dC5leGlzdHMgJiYg
bmV4dC5jb250cm9sbGVyID49IDAgJiYgbmV4dC5jbGllbnQgPT09IG1hbi5jbGllbnQpIG5leHQu
dGVhbSA9IG1hbi50ZWFtOwogICAgICAgICAgfQogICAgICAgIH0KICAgICAgfQogICAgICB0aGlz
LmFmdGVyUGFnZUNoYW5nZSgpOwogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICdjbGlja25leHQn
ICYmIHBhZ2UgPT09ICdTVE9SWU1FTlUnKSB7CiAgICAgIHRoaXMuZW50ZXJQYWdlKCdDSEFSTUVO
VScsICdTVE9SWU1FTlUnKTsKICAgICAgdGhpcy5hZnRlclBhZ2VDaGFuZ2UoKTsKICAgIH0gZWxz
ZSBpZiAoYWN0aW9uID09PSAnY2xpY2tuZXh0JyAmJiBwYWdlID09PSAnQ0hBUk1FTlUnICYmIG1v
ZGUgPT09ICdWU01PREUnKSB7CiAgICAgIHRoaXMuZW50ZXJQYWdlKCdHQU1FU0VUVElOR01FTlUn
LCAnQ0hBUk1FTlUnKTsKICAgICAgdGhpcy5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgIHRo
aXMuYnJvYWRjYXN0TWVuKDEpOwogICAgICBpZiAodGhpcy5iYWNrZ3JvdW5kUmFuZG9tKSB0aGlz
LnBpY2tCYWNrZ3JvdW5kKCk7CiAgICAgIGlmICh0aGlzLm11c2ljUmFuZG9tKSB0aGlzLnBpY2tN
dXNpYygpOwogICAgICB0aGlzLmJyb2FkY2FzdEdhbWVTZXR0aW5nKC0xKTsKICAgICAgdGhpcy5i
cm9hZGNhc3RTdGF0dXMoKTsKICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAnY2xpY2tuZXh0JyAm
JiBwYWdlID09PSAnQ0hBUk1FTlUnICYmIChtb2RlID09PSAnU1RPUllNT0RFJyB8fCBtb2RlID09
PSAnQkFUVExFTU9ERScpKSB7CiAgICAgIHRoaXMuZmlnaHQoJ0NIQVJNRU5VJyk7CiAgICB9IGVs
c2UgaWYgKGFjdGlvbiA9PT0gJ2NsaWNrZmlnaHQnICYmIHBhZ2UgPT09ICdHQU1FU0VUVElOR01F
TlUnKSB7CiAgICAgIHRoaXMuZmlnaHQoJ0dBTUVTRVRUSU5HTUVOVScpOwogICAgfSBlbHNlIGlm
IChhY3Rpb24gPT09ICdxdWl0Z2FtZScgJiYgdGhpcy5maWdodGluZ05vdykgewogICAgICB0aGlz
LnF1aXRUb01lbnUoKTsKICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAncmVzdGFydGdhbWUnICYm
IHRoaXMuZmlnaHRpbmdOb3cpIHsKICAgICAgaWYgKHRoaXMub25saW5lKCkuc29tZSgoc2xvdCkg
PT4gc2xvdC5wYWdlID09PSAnV0FJVFJPT00nKSkgewogICAgICAgIHRoaXMucXVpdFRvTWVudSgp
OwogICAgICB9IGVsc2UgewogICAgICAgIHRoaXMuc3RhcnRGaWdodCgpOwogICAgICAgIHRoaXMu
cmVzZXRGcmFtZXMoKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdCgnPHJlc3RhcnRnYW1lPjwvcmVz
dGFydGdhbWU+Jyk7CiAgICAgICAgdGhpcy5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgICAg
dGhpcy5icm9hZGNhc3RNZW4oMSk7CiAgICAgICAgdGhpcy5yZXNldEZyYW1lcygpOwogICAgICAg
IHRoaXMuZWFzZUxhdGVuY2llcygpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmco
LTEpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0KCc8cmVzdGFydGdhbWU+PC9yZXN0YXJ0Z2FtZT4n
KTsKICAgICAgfQogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICduZXh0c3RhZ2UnICYmIHRoaXMu
ZmlnaHRpbmdOb3cpIHsKICAgICAgaWYgKHRoaXMub25saW5lKCkuc29tZSgoc2xvdCkgPT4gc2xv
dC5wYWdlID09PSAnV0FJVFJPT00nKSkgewogICAgICAgIHRoaXMucGFnZSA9ICdTVE9SWU1FTlUn
OwogICAgICAgIHRoaXMuZmlnaHRpbmdOb3cgPSBmYWxzZTsKICAgICAgICB0aGlzLnByZXZpb3Vz
UGFnZSA9ICdGSUdIVElORyc7CiAgICAgICAgdGhpcy5xdWl0QnJvYWRjYXN0cygpOwogICAgICB9
IGVsc2UgewogICAgICAgIHRoaXMuc3RhcnRGaWdodCgpOwogICAgICAgIGlmICh0aGlzLnN0b3J5
IDwgNikgdGhpcy5zdG9yeSArPSAxOwogICAgICAgIHRoaXMuYnJvYWRjYXN0TGlzdCgtMSwgLTEp
OwogICAgICAgIHRoaXMuYnJvYWRjYXN0TWVuKDEpOwogICAgICAgIHRoaXMucmVzZXRGcmFtZXMo
KTsKICAgICAgICB0aGlzLmVhc2VMYXRlbmNpZXMoKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdEdh
bWVTZXR0aW5nKC0xKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdCgnPG5leHRzdGFnZT48L25leHRz
dGFnZT4nKTsKICAgICAgfQogICAgfQogIH0KCiAgYWZ0ZXJQYWdlQ2hhbmdlKCkgewogICAgdGhp
cy5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICB0aGlzLmJyb2FkY2FzdE1lbigxKTsKICAgIHRo
aXMuYnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwogICAgdGhpcy5icm9hZGNhc3RTdGF0dXMoKTsK
ICB9CgogIGZpZ2h0KHByZXZpb3VzKSB7CiAgICB0aGlzLnN0YXJ0RmlnaHQoKTsKICAgIHRoaXMu
cGFnZSA9ICdGSUdIVElORyc7CiAgICB0aGlzLmZpZ2h0aW5nTm93ID0gdHJ1ZTsKICAgIHRoaXMu
cHJldmlvdXNQYWdlID0gcHJldmlvdXM7CiAgICB0aGlzLmJyb2FkY2FzdExpc3QoLTEsIC0xKTsK
ICAgIHRoaXMuYnJvYWRjYXN0TWVuKDEpOwogICAgdGhpcy5yZXNldEZyYW1lcygpOwogICAgdGhp
cy5lYXNlTGF0ZW5jaWVzKCk7CiAgICB0aGlzLmJyb2FkY2FzdEdhbWVTZXR0aW5nKC0xKTsKICAg
IHRoaXMuYnJvYWRjYXN0U3RhdHVzKCk7CiAgfQoKICBxdWl0VG9NZW51KCkgewogICAgaWYgKHRo
aXMubW9kZSA9PT0gJ1ZTTU9ERScpIHRoaXMuZW50ZXJQYWdlKCdDSEFSTUVOVScsICdGSUdIVElO
RycpOwogICAgZWxzZSBpZiAodGhpcy5tb2RlID09PSAnU1RPUllNT0RFJykgdGhpcy5lbnRlclBh
Z2UoJ1NUT1JZTUVOVScsICdGSUdIVElORycpOwogICAgZWxzZSBpZiAodGhpcy5tb2RlID09PSAn
QkFUVExFTU9ERScpIHRoaXMuZW50ZXJQYWdlKCdCQVRUTEVTRVRUSU5HTUVOVScsICdGSUdIVElO
RycpOwogICAgdGhpcy5xdWl0QnJvYWRjYXN0cygpOwogIH0KCiAgcXVpdEJyb2FkY2FzdHMoKSB7
CiAgICB0aGlzLnJlc2V0RnJhbWVzKCk7CiAgICB0aGlzLmJyb2FkY2FzdFN0YXR1cygpOwogICAg
dGhpcy5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICB0aGlzLmJyb2FkY2FzdE1lbigxKTsKICAg
IHRoaXMucmVzZXRGcmFtZXMoKTsKICAgIHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwog
ICAgdGhpcy5icm9hZGNhc3RTdGF0dXMoKTsKICB9CgogIC8vIFRoZSBmcmFtZSBzZW5kZXJzIChh
diwgb25lIHBlciBjb21wdXRlcik6IGV2ZXJ5IDEwIG1zOyBhIHNlbmQgaXMgZHVlIGFmdGVyIGFu
b3RoZXIgZ2FtZSdzIHBhY2tldAogIC8vIGFuZCwgYmVzaWRlcywgZXZlcnkgMTAwIHRvIDIwMCBt
cy4KICBmbHVzaFRpY2soKSB7CiAgICBpZiAodGhpcy5zdGFydGluZykgcmV0dXJuOwogICAgZm9y
IChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgY29u
c3Qgc2xvdCA9IHRoaXMuc2xvdHNbaW5kZXhdOwogICAgICBzbG90LnRpY2tDb3VudCA9IChzbG90
LnRpY2tDb3VudCB8fCAwKSArIDE7CiAgICAgIGlmIChzbG90LnRpY2tDb3VudCA9PT0gMjApIHsK
ICAgICAgICBzbG90LnRpY2tDb3VudCA9IHRoaXMubmV4dEludCgxMCk7CiAgICAgICAgc2xvdC5m
bHVzaGVzICs9IDE7CiAgICAgIH0KICAgICAgaWYgKHNsb3QuZmx1c2hlcyA8PSAwKSBjb250aW51
ZTsKICAgICAgaWYgKHNsb3QuZmlnaHRpbmcgJiYgc2xvdC5jb25uZWN0aW9uKSBzbG90LmNvbm5l
Y3Rpb24uc2VuZEZyYW1lcygpOwogICAgICBzbG90LmZsdXNoZXMgLT0gMTsKICAgIH0KICB9Cgog
IC8vIFRoZSB3YXRjaGRvZyAoYUEpOiBwaW5ncyBxdWlldCBnYW1lcywgYW5kIHRha2VzIG91dCBn
YW1lcyBzaWxlbnQgZm9yIDM1IHMgKG9yIGlkbGUgdG9vIGxvbmcpLgogIHdhdGNoZG9nKCkgewog
ICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXgg
PCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3RzW2lu
ZGV4XTsKICAgICAgaWYgKCFzbG90Lm9ubGluZSkgY29udGludWU7CiAgICAgIGNvbnN0IGFmayA9
IHRoaXMuYWZrTWludXRlcyAqIDYwMDAwOwogICAgICBpZiAoc2xvdC5sYXN0TWVzc2FnZSA8IG5v
dyAtIDM1MDAwIHx8IChhZmsgPiA2MDAwMCAmJiBzbG90Lmxhc3RBY3RpdmUgPCBub3cgLSBhZmsp
KSB7CiAgICAgICAgdGhpcy5sb2coYGhmIHJvb20gJHt0aGlzLm51bWJlcn06ICR7c2xvdC5uYW1l
fSAke3Nsb3QubGFzdE1lc3NhZ2UgPCBub3cgLSAzNTAwMCA/ICd0aW1lZCBvdXQnIDogJ3dhcyBp
ZGxlJ31gKTsKICAgICAgICBjb25zdCBjb25uZWN0aW9uID0gc2xvdC5jb25uZWN0aW9uOwogICAg
ICAgIGNvbm5lY3Rpb24ubGVhdmUoKTsKICAgICAgICBjb25uZWN0aW9uLmtpY2tlZCA9IHRydWU7
CiAgICAgICAgY29ubmVjdGlvbi5jbG9zZSgpOwogICAgICAgIGNvbnRpbnVlOwogICAgICB9CiAg
ICAgIGlmIChzbG90Lmxhc3RNZXNzYWdlIDwgbm93IC0gMjAwMDApIHNsb3QuY29ubmVjdGlvbi5z
ZW5kKCc8cGluZz48L3Bpbmc+Jyk7CiAgICB9CiAgfQoKICAvLyBUaGUgbGluZSB0aGUgcm9vbSBs
aXN0IHNob3dzIGZvciB0aGlzIHJvb20uCiAgcGVvcGxlKCkgewogICAgcmV0dXJuIHRoaXMub25s
aW5lKCkubWFwKChzbG90KSA9PiBgJHtzbG90Lm5hbWV9KCR7c2xvdC5sYXRlbmN5U2hvd24gLSAx
fSlgKS5qb2luKCcsICcpOwogIH0KfQoKLy8gLS0tLSBPbmUgY29tcHV0ZXIgaW4gYSByb29tICh0
aGUgb3JpZ2luYWwncyB0aHJlYWQgImkiKSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tCgpjbGFzcyBIZkNvbm5lY3Rpb24gewogIC8vIHNvY2tldDogeyB3cml0ZSh0
ZXh0KSwgY2xvc2UoKSB9OyBmZWVkIGl0IHRoZSByZWNlaXZlZCBieXRlcyB3aXRoIHJlY2VpdmUo
KSwgYW5kIGNsb3NlZCgpIGF0IHRoZSBlbmQuCiAgY29uc3RydWN0b3Iocm9vbSwgc29ja2V0LCB7
IGFkZHJlc3MgPSAnJywgYnVpbGQgPSAnJyB9ID0ge30pIHsKICAgIHRoaXMucm9vbSA9IHJvb207
CiAgICB0aGlzLnNvY2tldCA9IHNvY2tldDsKICAgIHRoaXMuYWRkcmVzcyA9IGFkZHJlc3M7CiAg
ICB0aGlzLmJ1aWxkID0gYnVpbGQ7IC8vIHRoZSBwYWdlJ3MgbW92aWUgYW5kIFJ1ZmZsZSAoYWNj
ZXB0c0J1aWxkKQogICAgdGhpcy5pbmRleCA9IC0xOyAvLyBuCiAgICB0aGlzLm5hbWUgPSAnJzsg
Ly8gbwogICAgdGhpcy5jYyA9ICcnOyAvLyBwCiAgICB0aGlzLnBsYXllcnMgPSBbJycsICcnLCAn
J107IC8vIHIKICAgIHRoaXMubGFzdEZyYW1lID0gLTE7IC8vIHM6IHRoZSBsYXN0IGZyYW1lIG9m
IHRoaXMgZ2FtZSdzLCBpbiBvcmRlcgogICAgdGhpcy5uZXh0RnJhbWUgPSAwOyAvLyB0OiB0aGUg
bmV4dCBmcmFtZSB0byBzZW5kIHRoaXMgZ2FtZQogICAgdGhpcy5xdWV1ZWQgPSAnJzsgLy8gdjog
PHJwYz4gbGluZXMgZnJvbSB0aGUgb3RoZXJzLCBzZW50IHdpdGggdGhlIG5leHQgZnJhbWVzIChu
b25lIG5vdzogUm9vbS5jaGVja1N0ZXApCiAgICB0aGlzLmNoZWF0ID0gMDsgLy8geAogICAgdGhp
cy5raWNrZWQgPSBmYWxzZTsgLy8gYgogICAgdGhpcy5lbmRlZCA9IGZhbHNlOwogICAgdGhpcy5s
aW5lcyA9IFtdOwogICAgdGhpcy53YWl0aW5nID0gbnVsbDsKICAgIHRoaXMuYnVmZmVyID0gQnVm
ZmVyLmFsbG9jKDApOwogICAgcm9vbS5jb25uZWN0aW9ucy5hZGQodGhpcyk7CiAgICB0aGlzLmRv
bmUgPSB0aGlzLnJ1bigpOwogIH0KCiAgLy8gLS0tLSBieXRlcyBpbiBhbmQgb3V0CiAgcmVjZWl2
ZShjaHVuaykgewogICAgaWYgKHRoaXMuZW5kZWQpIHJldHVybjsKICAgIHRoaXMuYnVmZmVyID0g
dGhpcy5idWZmZXIubGVuZ3RoID8gQnVmZmVyLmNvbmNhdChbdGhpcy5idWZmZXIsIGNodW5rXSkg
OiBCdWZmZXIuZnJvbShjaHVuayk7CiAgICBsZXQgc3RhcnQgPSAwOwogICAgZm9yIChsZXQgYXQg
PSB0aGlzLmJ1ZmZlci5pbmRleE9mKDEwKTsgYXQgPj0gMDsgYXQgPSB0aGlzLmJ1ZmZlci5pbmRl
eE9mKDEwLCBzdGFydCkpIHsKICAgICAgbGV0IGxpbmUgPSB0aGlzLmJ1ZmZlci50b1N0cmluZygn
dXRmOCcsIHN0YXJ0LCBhdCk7CiAgICAgIGlmIChsaW5lLmVuZHNXaXRoKCdccicpKSBsaW5lID0g
bGluZS5zbGljZSgwLCAtMSk7CiAgICAgIHN0YXJ0ID0gYXQgKyAxOwogICAgICB0aGlzLnB1c2hM
aW5lKGxpbmUpOwogICAgfQogICAgdGhpcy5idWZmZXIgPSB0aGlzLmJ1ZmZlci5zdWJhcnJheShz
dGFydCk7CiAgICBpZiAodGhpcy5idWZmZXIubGVuZ3RoID4gMjYyMTQ0KSB0aGlzLmNsb3NlKCk7
IC8vIG5vIGxpbmUgaXMgdGhhdCBsb25nCiAgfQoKICBjbG9zZWQoKSB7CiAgICBpZiAodGhpcy5l
bmRlZCkgcmV0dXJuOwogICAgdGhpcy5lbmRlZCA9IHRydWU7CiAgICB0aGlzLnB1c2hMaW5lKG51
bGwpOwogIH0KCiAgcHVzaExpbmUobGluZSkgewogICAgaWYgKHRoaXMud2FpdGluZykgewogICAg
ICBjb25zdCByZXNvbHZlID0gdGhpcy53YWl0aW5nOwogICAgICB0aGlzLndhaXRpbmcgPSBudWxs
OwogICAgICByZXNvbHZlKGxpbmUpOwogICAgfSBlbHNlIHsKICAgICAgdGhpcy5saW5lcy5wdXNo
KGxpbmUpOwogICAgfQogIH0KCiAgcmVhZExpbmUoKSB7IC8vIEJ1ZmZlcmVkUmVhZGVyLnJlYWRM
aW5lOiBudWxsIGF0IHRoZSBlbmQKICAgIGlmICh0aGlzLmxpbmVzLmxlbmd0aCkgcmV0dXJuIFBy
b21pc2UucmVzb2x2ZSh0aGlzLmxpbmVzLnNoaWZ0KCkpOwogICAgaWYgKHRoaXMuZW5kZWQpIHJl
dHVybiBQcm9taXNlLnJlc29sdmUobnVsbCk7CiAgICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29s
dmUpID0+IHsgdGhpcy53YWl0aW5nID0gcmVzb2x2ZTsgfSk7CiAgfQoKICBzZW5kKHRleHQpIHsg
Ly8gaS5hKFN0cmluZykKICAgIGlmICh0aGlzLmVuZGVkKSByZXR1cm47CiAgICB0cnkgeyB0aGlz
LnNvY2tldC53cml0ZSh0ZXh0ICsgJ1xuJyk7IH0gY2F0Y2ggeyAvKiB0aGUgY2xvc2luZyBmb2xs
b3dzICovIH0KICB9CgogIGNsb3NlKCkgewogICAgaWYgKCF0aGlzLnNvY2tldENsb3NlZCkgewog
ICAgICB0aGlzLnNvY2tldENsb3NlZCA9IHRydWU7CiAgICAgIHRyeSB7IHRoaXMuc29ja2V0LmNs
b3NlKCk7IH0gY2F0Y2ggeyAvKiBhbHJlYWR5IGNsb3NlZCAqLyB9CiAgICB9CiAgICB0aGlzLmNs
b3NlZCgpOwogIH0KCiAgZ2V0IHNsb3QoKSB7IHJldHVybiB0aGlzLnJvb20uc2xvdHNbdGhpcy5p
bmRleF07IH0KCiAgLy8gLS0tLSB0aGUgY29udmVyc2F0aW9uCiAgYXN5bmMgcnVuKCkgewogICAg
dHJ5IHsKICAgICAgYXdhaXQgdGhpcy5jb252ZXJzYXRpb24oKTsKICAgIH0gY2F0Y2ggKGVycm9y
KSB7CiAgICAgIGlmICghKGVycm9yIGluc3RhbmNlb2YgWG1sRXJyb3IpKSB0aGlzLnJvb20ubG9n
KGBoZiByb29tICR7dGhpcy5yb29tLm51bWJlcn06ICR7ZXJyb3Iuc3RhY2sgfHwgZXJyb3J9YCk7
CiAgICB9IGZpbmFsbHkgewogICAgICB0aGlzLmxlYXZlKCk7IC8vIGkuaAogICAgICB0aGlzLnJv
b20uY29ubmVjdGlvbnMuZGVsZXRlKHRoaXMpOwogICAgICB0aGlzLmNsb3NlKCk7CiAgICB9CiAg
fQoKICBhc3luYyBjb252ZXJzYXRpb24oKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwog
ICAgYXdhaXQgc2xlZXAoMjUwKTsKICAgIHRoaXMuc2VuZCgnPGluaT48L2luaT4nKTsKICAgIGF3
YWl0IHNsZWVwKDI1MCk7CiAgICBpZiAocm9vbS5jbG9zZWQpIHJldHVybjsKICAgIGxldCBsaW5l
ID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpOwogICAgaWYgKGxpbmUgPT09IG51bGwpIHJldHVybjsK
ICAgIGNvbnN0IGpvaW4gPSBwYXJzZVhtbChsaW5lKTsKICAgIGNvbnN0IHZlcnNpb25zID0gYnlU
YWcoam9pbiwgJ3ZlcicpOwogICAgaWYgKCF2ZXJzaW9ucy5sZW5ndGgpIHJldHVybjsKICAgIGlm
IChpbnQodmFsdWVPZih2ZXJzaW9uc1swXSkpICE9PSBWRVJTSU9OKSByZXR1cm4gdGhpcy5yZWZ1
c2UoJ3YnKTsKICAgIGlmICghcm9vbS5hY2NlcHRzQnVpbGQodGhpcy5idWlsZCkpIHsKICAgICAg
cm9vbS5sb2coYGhmIHJvb20gJHtyb29tLm51bWJlcn06IGEgZ2FtZSBvZiBhbm90aGVyIGJ1aWxk
ICgke3RoaXMuYnVpbGQgfHwgJ25vbmUnfSwgdGhlIHJvb20gaGFzICR7cm9vbS5idWlsZH0pIHR1
cm5lZCBhd2F5YCk7CiAgICAgIHJldHVybiB0aGlzLnJlZnVzZSgndicpOwogICAgfQogICAgaWYg
KHJvb20uY29ubmVjdGVkID49IHJvb20ubGltaXQpIHJldHVybiB0aGlzLnJlZnVzZSgnZicpOwog
ICAgaWYgKCFyb29tLmFsbG93Sm9pbldoZW5GaWdodGluZyAmJiByb29tLmZpZ2h0aW5nTm93KSBy
ZXR1cm4gdGhpcy5yZWZ1c2UoJ3AnKTsKICAgIGlmIChyb29tLnBhc3N3b3JkKSB7CiAgICAgIHRo
aXMuc2VuZCgnPHJlcV9wdz48L3JlcV9wdz4nKTsKICAgICAgbGluZSA9IGF3YWl0IHRoaXMucmVh
ZExpbmUoKTsKICAgICAgaWYgKGxpbmUgPT09IG51bGwpIHJldHVybjsKICAgICAgaWYgKHJvb20u
cGFzc3dvcmQgIT09IHRhZ1ZhbHVlKHBhcnNlWG1sKGxpbmUpLCAncHdkJykpIHJldHVybiB0aGlz
LnJlZnVzZSgncHdkJyk7CiAgICB9CiAgICBjb25zdCBsYXRlbmN5ID0gYXdhaXQgdGhpcy5tZWFz
dXJlKCk7CiAgICBpZiAobGF0ZW5jeSA9PT0gbnVsbCkgcmV0dXJuOwogICAgaWYgKHJvb20ubGF0
ZW5jeUxpbWl0ICE9PSAtMSAmJiBsYXRlbmN5ID4gcm9vbS5sYXRlbmN5TGltaXQpIHJldHVybiB0
aGlzLnJlZnVzZSgnbCcpOwogICAgdGhpcy5zZW5kKGA8bWF4Y2xpZW50cz48bWF4Y2xpZW50cz4k
e3Jvb20ubGltaXR9PC9tYXhjbGllbnRzPjwvbWF4Y2xpZW50cz5gKTsKICAgIHRoaXMuc2VuZChg
PHJwPjxycD4ke3Jvb20uc2VlZH08L3JwPjwvcnA+YCk7CiAgICBmb3IgKGxldCBwYXJ0ID0gMDsg
cGFydCA8IDEwOyBwYXJ0ICs9IDEpIHsKICAgICAgbGV0IHRleHQgPSBgPHJhbmQ+PGk+JHtwYXJ0
ICogNTAwfTwvaT5gOwogICAgICBmb3IgKGxldCBrID0gMDsgayA8IDUwMDsgayArPSAxKSB0ZXh0
ICs9IGA8bj4ke3Jvb20udGFibGVbayArIHBhcnQgKiA1MDBdfTwvbj5gOwogICAgICB0aGlzLnNl
bmQodGV4dCArICc8L3JhbmQ+Jyk7CiAgICB9CiAgICB0aGlzLnNlbmQoJzxyZXFfaW5mbz48L3Jl
cV9pbmZvPicpOwogICAgbGluZSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKTsKICAgIGlmIChsaW5l
ID09PSBudWxsIHx8IHJvb20uY2xvc2VkKSByZXR1cm47CiAgICByb29tLnJlY291bnQoKTsKICAg
IGlmIChyb29tLmNvbm5lY3RlZCA+PSByb29tLmxpbWl0KSByZXR1cm4gdGhpcy5yZWZ1c2UoJ2Yn
KTsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7
CiAgICAgIGlmICghcm9vbS5zbG90c1tpbmRleF0ub25saW5lKSB7IHRoaXMuaW5kZXggPSBpbmRl
eDsgYnJlYWs7IH0KICAgIH0KICAgIGlmICh0aGlzLmluZGV4IDwgMCkgcmV0dXJuIHRoaXMucmVm
dXNlKCdmJyk7CiAgICBjb25zdCBpbmZvID0gcGFyc2VYbWwobGluZSk7CiAgICB0aGlzLm5hbWUg
PSB0YWdWYWx1ZShpbmZvLCAnbmFtZScpOwogICAgY29uc3QgY2NzID0gYnlUYWcoaW5mbywgJ2Nj
Jyk7CiAgICB0aGlzLmNjID0gY2NzLmxlbmd0aCA/IHZhbHVlT2YoY2NzWzBdKSA6ICcnOwogICAg
Y29uc3Qgc2xvdCA9IHRoaXMuc2xvdDsKICAgIGZvciAobGV0IGsgPSAwOyBrIDwgMzsgayArPSAx
KSB0aGlzLnBsYXllcnNba10gPSB0YWdWYWx1ZShpbmZvLCAncCcsIGspOwogICAgZm9yIChsZXQg
ayA9IDA7IGsgPCAzMDsgayArPSAxKSB7CiAgICAgIHNsb3QubGV2ZWxzW2tdID0gaW50KHRhZ1Zh
bHVlKGluZm8sICdsJywgaykpOwogICAgICBpZiAoc2xvdC5sZXZlbHNba10gPiBNQVhfTEVWRUwp
IHRoaXMuY2hlYXQgPSAxOwogICAgfQogICAgc2xvdC5sZXZlbHNbMjBdID0gc2xvdC5sZXZlbHNb
OF07CiAgICBzbG90Lm5hbWUgPSB0aGlzLm5hbWU7CiAgICBzbG90LmNjID0gdGhpcy5jYzsKICAg
IHNsb3QuY291bnRyeSA9IHRoaXMuY2MgfHwgJ3Vua25vd24nOwogICAgc2xvdC5wbGF5ZXJzID0g
Wy4uLnRoaXMucGxheWVyc107CiAgICBzbG90Lmxhc3RNZXNzYWdlID0gc2xvdC5sYXN0QWN0aXZl
ID0gRGF0ZS5ub3coKTsKICAgIHNsb3QuY29ubmVjdGlvbiA9IHRoaXM7CiAgICBzbG90Lm9ubGlu
ZSA9IHRydWU7CiAgICBzbG90LnBhdXNlZCA9IGZhbHNlOwogICAgc2xvdC5oYXNQbGF5ZXIgPSBm
YWxzZTsKICAgIHNsb3QubGF0ZW5jeSA9IHNsb3QubGF0ZW5jeVRhcmdldCA9IHNsb3QubGF0ZW5j
eVNob3duID0gbGF0ZW5jeTsKICAgIHNsb3QucGFnZSA9ICdXQUlUUk9PTSc7CiAgICBzbG90LmFk
bWluID0gZmFsc2U7CiAgICByb29tLnJlY291bnQoKTsKICAgIHRoaXMuc2VuZFNldHRpbmcoLTEp
OwogICAgdGhpcy5zZW5kR2FtZVNldHRpbmcoLTEpOwogICAgdGhpcy5zZW5kTGlzdCgtMSwgLTEp
OwogICAgdGhpcy5zZW5kTWVuKDEpOwogICAgaWYgKCFyb29tLmZpZ2h0aW5nTm93KSB7CiAgICAg
IGlmIChyb29tLnBhZ2UgIT09ICdXQUlUUk9PTScpIHsKICAgICAgICBpZiAocm9vbS5tb2RlID09
PSAnVlNNT0RFJykgcm9vbS5wYWdlID0gJ0NIQVJNRU5VJzsKICAgICAgfSBlbHNlIHsKICAgICAg
ICByb29tLnBhZ2UgPSAnV0FJVFJPT00nOwogICAgICAgIHJvb20ubW9kZSA9ICdXQUlUUk9PTSc7
CiAgICAgIH0KICAgIH0KICAgIHJvb20uYnJvYWRjYXN0U3RhdHVzKCk7CiAgICByb29tLmxvZyhg
aGYgcm9vbSAke3Jvb20ubnVtYmVyfTogJHt0aGlzLm5hbWV9IChsYXRlbmN5ICR7bGF0ZW5jeSAt
IDF9KSBqb2luc2ApOwogICAgcm9vbS5icm9hZGNhc3RMaXN0KHRoaXMuaW5kZXgsIC0xKTsKICAg
IGlmIChyb29tLmNvbm5lY3RlZCA9PT0gMiAmJiByb29tLmZpZ2h0aW5nTm93KSB7CiAgICAgIHJv
b20uY291bnRkb3duLm9uID0gdHJ1ZTsKICAgICAgcm9vbS5jb3VudGRvd24uYWN0aW9uID0gJ3F1
aXRnYW1lJzsKICAgICAgcm9vbS5jb3VudGRvd24uY291bnQgPSAxOwogICAgfQogICAgdGhpcy5u
b3RpY2UoJ1Jvb20gU2VydmVyIHYwLjcrLjxiciAvPlR5cGUgL2hlbHAgZm9yIGNvbW1hbmRzLicp
OwogICAgaWYgKHJvb20uZmlnaHRpbmdOb3cgJiYgcm9vbS5jb25uZWN0ZWQgPiAyKSB7CiAgICAg
IGlmIChyb29tLm1vZGUgPT09ICdWU01PREUnKSB0aGlzLm5vdGljZSgnUGxheWVycyBhcmUgaW4g
VlMgTW9kZS4nKTsKICAgICAgZWxzZSBpZiAocm9vbS5tb2RlID09PSAnQkFUVExFTU9ERScpIHRo
aXMubm90aWNlKCdQbGF5ZXJzIGFyZSBpbiBCYXR0bGUgTW9kZS4nKTsKICAgICAgZWxzZSBpZiAo
cm9vbS5tb2RlID09PSAnU1RPUllNT0RFJykgdGhpcy5ub3RpY2UoYFBsYXllcnMgYXJlIGluIFN0
b3J5ICR7cm9vbS5zdG9yeSArIDF9YCk7CiAgICB9CiAgICBpZiAodGhpcy5jaGVhdCA9PT0gMSkg
cmV0dXJuOyAvLyBsZXZlbHMgYWJvdmUgdGhlIGdhbWUncyBoaWdoZXN0OiBvdXQgKHRoZSBmaW5h
bGx5IGxlYXZlcykKICAgIGZvciAobGluZSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKTsgbGluZSAh
PT0gbnVsbDsgbGluZSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKSkgewogICAgICBpZiAodGhpcy5p
bmRleCA8IDApIHJldHVybjsKICAgICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgICAgc2xv
dC5sYXN0TWVzc2FnZSA9IG5vdzsKICAgICAgaWYgKGxpbmUgIT09ICc8cGluZ29rPjwvcGluZ29r
PicpIHNsb3QubGFzdEFjdGl2ZSA9IG5vdzsKICAgICAgaWYgKHRoaXMua2lja2VkIHx8IHRoaXMu
Y2hlYXQgPT09IDEpIHJldHVybjsKICAgICAgYXdhaXQgdGhpcy5oYW5kbGUobGluZSk7CiAgICAg
IGlmICh0aGlzLmtpY2tlZCkgcmV0dXJuOwogICAgfQogIH0KCiAgcmVmdXNlKHJlYXNvbikgewog
ICAgdGhpcy5zZW5kKGA8ZXJyb3I+PHJlYXNvbj4ke3JlYXNvbn08L3JlYXNvbj48L2Vycm9yPmAp
OwogICAgcmV0dXJuIHRoaXMucmVhZExpbmUoKTsKICB9CgogIC8vIFRlbiBwaW5nczogdGhlIGxh
dGVuY3kgaXMgdGhlIHNob3J0ZXN0IHJvdW5kIHRyaXAsIGluIGZyYW1lcyAoYSBtdWx0aXBsZSBv
ZiBTVEVQKSwgd2l0aCBhIG1hcmdpbi4KICBhc3luYyBtZWFzdXJlKCkgewogICAgbGV0IGJlc3Qg
PSA1MDAwOwogICAgZm9yIChsZXQgayA9IDA7IGsgPCAxMDsgayArPSAxKSB7CiAgICAgIGNvbnN0
IHNlbnQgPSBEYXRlLm5vdygpOwogICAgICB0aGlzLnNlbmQoJzxwaW5nPjwvcGluZz4nKTsKICAg
ICAgaWYgKGF3YWl0IHRoaXMucmVhZExpbmUoKSA9PT0gbnVsbCkgcmV0dXJuIG51bGw7CiAgICAg
IGNvbnN0IHRvb2sgPSBEYXRlLm5vdygpIC0gc2VudDsKICAgICAgaWYgKHRvb2sgPCBiZXN0KSBi
ZXN0ID0gdG9vazsKICAgICAgYXdhaXQgc2xlZXAodG9vayA8IDUwMCA/IHRvb2sgOiA1MDApOwog
ICAgfQogICAgaWYgKGJlc3QgPD0gMCkgYmVzdCA9IDE7CiAgICBiZXN0ICs9IDE1OwogICAgcmV0
dXJuIFNURVAgKyBNYXRoLmNlaWwoKGJlc3QgKiAxLjcgKyAwLjE2KSAvIDMzIC8gU1RFUCkgKiBT
VEVQOwogIH0KCiAgYXN5bmMgaGFuZGxlKGxpbmUpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJv
b207CiAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90OwogICAgY29uc3QgZG9jID0gcGFyc2VYbWwo
bGluZSk7CiAgICBjb25zdCBraW5kID0gZG9jLm5hbWU7CiAgICBpZiAoa2luZCA9PT0gJ2YnKSB7
IC8vIGEgZnJhbWUgb2YgdGhpcyBnYW1lJ3Mga2V5cwogICAgICBjb25zdCBmcmFtZSA9IGludCh0
YWdWYWx1ZShkb2MsICdpJykpOwogICAgICBpZiAoZnJhbWUgPT09IDEpIHJvb20ud2luUmVwb3J0
ZWQgPSBmYWxzZTsKICAgICAgaWYgKHRoaXMubGFzdEZyYW1lICsgMSA9PT0gZnJhbWUpIHsKICAg
ICAgICBzbG90LmZyYW1lc1tmcmFtZSAlIEZSQU1FU19LRVBUXSA9IGxpbmU7CiAgICAgICAgdGhp
cy5sYXN0RnJhbWUgPSBmcmFtZTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAo
a2luZCA9PT0gJ3BrJykgeyAvLyB0aGUgZW5kIG9mIGEgcGFja2V0OiB0aGUgb3RoZXJzIG1heSBn
ZXQgdGhpcyBnYW1lJ3MgZnJhbWVzCiAgICAgIHNsb3QubGFzdFBhY2tldCA9IHRoaXMubGFzdEZy
YW1lOwogICAgICB0aGlzLnJlcXVlc3RGbHVzaGVzKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAg
IGlmIChraW5kID09PSAndCcpIHsgaW50KHRhZ1ZhbHVlKGRvYywgJ2QnKSk7IHJldHVybjsgfQog
ICAgaWYgKGtpbmQgPT09ICdycGMnKSB7CiAgICAgIHJvb20uY2hlY2tTdGVwKHRoaXMuaW5kZXgs
IGludCh0YWdWYWx1ZShkb2MsICdjbCcpKSwgaW50KHRhZ1ZhbHVlKGRvYywgJ3JwJykpKTsKICAg
ICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdjaGF0JykgewogICAgICBjb25zdCBm
cm9tID0gaW50KHRhZ1ZhbHVlKGRvYywgJ2MnKSk7CiAgICAgIGlmIChmcm9tIDwgMCB8fCBmcm9t
ID49IFNMT1RTKSB0aHJvdyBuZXcgWG1sRXJyb3IoJ25vIHN1Y2ggY29tcHV0ZXInKTsKICAgICAg
aWYgKHRoaXMuY29tbWFuZCh0YWdWYWx1ZShkb2MsICdtJykpKSByb29tLmJyb2FkY2FzdChsaW5l
KTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdwYXVzZWdhbWUnIHx8IGtp
bmQgPT09ICdyZXN1bWVnYW1lJykgewogICAgICBzbG90LnBhdXNlZCA9IGtpbmQgPT09ICdwYXVz
ZWdhbWUnOwogICAgICByb29tLmJyb2FkY2FzdExpc3QoLTEsIC0xKTsKICAgICAgcmV0dXJuOwog
ICAgfQogICAgaWYgKGtpbmQgPT09ICdzdGFydGNvdW50JykgcmV0dXJuIHRoaXMuc3RhcnRDb3Vu
dChkb2MpOwogICAgaWYgKGtpbmQgPT09ICdjYW5jZWxjb3VudCcpIHsKICAgICAgY29uc3QgY291
bnRkb3duID0gcm9vbS5jb3VudGRvd247CiAgICAgIGlmIChjb3VudGRvd24ub24gJiYgKGNvdW50
ZG93bi5hY3Rpb24gPT09ICdjbGlja2ZpZ2h0JyB8fCBjb3VudGRvd24uYWN0aW9uID09PSB0YWdW
YWx1ZShkb2MsICdhY3Rpb24nKSkpIHsKICAgICAgICBjb3VudGRvd24ub24gPSBmYWxzZTsKICAg
ICAgICBjb3VudGRvd24uYWN0aW9uID0gJyc7CiAgICAgICAgY291bnRkb3duLmNvdW50ID0gQ09V
TlRET1dOOwogICAgICAgIHJvb20uYnJvYWRjYXN0Q2xpY2sodGhpcy5pbmRleCwgJ2NsaWNrY2Fu
Y2VsJyk7CiAgICAgICAgcm9vbS5icm9hZGNhc3QoJzxjYW5jZWxjb3VudD48L2NhbmNlbGNvdW50
PicpOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnc2V0dGlu
ZycpIHsKICAgICAgaWYgKHJvb20ucGFnZSA9PT0gJ1dBSVRST09NJykgewogICAgICAgIGNvbnN0
IGFsbG93ID0gYnlUYWcoZG9jLCAnd2FpdHdoZW5maWdodCcpOwogICAgICAgIGlmIChhbGxvdy5s
ZW5ndGgpIHJvb20uYWxsb3dKb2luV2hlbkZpZ2h0aW5nID0gdmFsdWVPZihhbGxvd1swXSkgPT09
ICcxJzsKICAgICAgICByb29tLmJyb2FkY2FzdFNldHRpbmcodGhpcy5pbmRleCk7CiAgICAgIH0K
ICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdnYW1lc2V0dGluZycpIHJldHVy
biB0aGlzLmdhbWVTZXR0aW5nKGRvYyk7CiAgICBpZiAoa2luZCA9PT0gJ2NsaWNrYmFjaycpIHJl
dHVybiB0aGlzLmNsaWNrQmFjayhkb2MpOwogICAgaWYgKGtpbmQgPT09ICdwYWdlJykgewogICAg
ICBzbG90LnBhZ2UgPSB2YWx1ZU9mKGRvYyk7CiAgICAgIHNsb3QuZmlnaHRpbmcgPSBzbG90LnBh
Z2UgPT09ICdGSUdIVElORyc7CiAgICAgIHJvb20uYnJvYWRjYXN0TGlzdCgtMSwgLTEpOwogICAg
ICByZXR1cm47CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ2luZm8nKSByZXR1cm4gdGhpcy51cGRh
dGVJbmZvKGRvYyk7CiAgICBpZiAoa2luZCA9PT0gJ2FkZHBsYXllcicpIHJldHVybiB0aGlzLmFk
ZFBsYXllcihkb2MpOwogICAgaWYgKGtpbmQgPT09ICdkZWxtYW4nKSB7CiAgICAgIGlmIChyb29t
LnBhZ2UgIT09ICdDSEFSTUVOVScpIHJldHVybjsKICAgICAgY29uc3QgaW5kZXggPSBpbnQodmFs
dWVPZihkb2MpKTsKICAgICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhdOwogICAgICBpZiAo
IW1hbikgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBzdWNoIG1hbicpOwogICAgICBpZiAobWFuLmV4
aXN0cyAmJiAoKG1hbi5jb250cm9sbGVyID09PSAtMSAmJiAhcm9vbS5jb3VudGRvd24ub24pIHx8
IG1hbi5jbGllbnQgPT09IHRoaXMuaW5kZXgpKSB7CiAgICAgICAgbWFuLmV4aXN0cyA9IGZhbHNl
OwogICAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5tZW4pIGlmIChvdGhlci5leGlzdHMg
JiYgb3RoZXIuY29tbWFuZGVyID09PSBpbmRleCkgb3RoZXIuZXhpc3RzID0gZmFsc2U7CiAgICAg
ICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAgICAgIH0KICAgICAgcmV0dXJuOwogICAgfQogICAg
aWYgKGtpbmQgPT09ICdhZGRjb20nKSB7CiAgICAgIGlmIChyb29tLnBhZ2UgIT09ICdDSEFSTUVO
VScpIHJldHVybjsKICAgICAgaWYgKCFyb29tLmNvdW50ZG93bi5vbiAmJiB0aGlzLmFkZENvbXB1
dGVyKCkpIHsKICAgICAgICB0aGlzLmxpbWl0TWVuKCk7CiAgICAgICAgcm9vbS5icm9hZGNhc3RN
ZW4oMSk7CiAgICAgIH0KICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdhZGRz
b2xkaWVyJykgcmV0dXJuIHRoaXMuYWRkU29sZGllcihkb2MpOwogICAgaWYgKGtpbmQgPT09ICdy
ZWRvcmFuZG9tJykgewogICAgICBpZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47
CiAgICAgIGlmICghcm9vbS5jb3VudGRvd24ub24pIHsKICAgICAgICBmb3IgKGxldCBpbmRleCA9
IDA7IGluZGV4IDwgTUVOOyBpbmRleCArPSAxKSBpZiAocm9vbS5tZW5baW5kZXhdLmV4aXN0cyAm
JiByb29tLm1lbltpbmRleF0ucmFuZG9tKSB0aGlzLnBpY2tDaGFyYWN0ZXIoaW5kZXgpOwogICAg
ICAgIHJvb20uYnJvYWRjYXN0TWVuKDApOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAg
IGlmIChraW5kID09PSAnbWFudGVhbScpIHsKICAgICAgaWYgKHJvb20ucGFnZSAhPT0gJ0NIQVJN
RU5VJykgcmV0dXJuOwogICAgICBjb25zdCBpbmRleCA9IGludCh0YWdWYWx1ZShkb2MsICdpJykp
OwogICAgICBjb25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICAgIGlmICghbWFuKSB0aHJv
dyBuZXcgWG1sRXJyb3IoJ25vIHN1Y2ggbWFuJyk7CiAgICAgIGlmIChtYW4uZXhpc3RzICYmICht
YW4uY29udHJvbGxlciA9PT0gLTEgfHwgbWFuLmNsaWVudCA9PT0gdGhpcy5pbmRleCkpIHsKICAg
ICAgICBjb25zdCB0ZWFtID0gaW50KHRhZ1ZhbHVlKGRvYywgJ3RlYW0nKSk7CiAgICAgICAgbWFu
LnRlYW0gPSB0ZWFtOwogICAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5tZW4pIGlmIChv
dGhlci5leGlzdHMgJiYgb3RoZXIuY29tbWFuZGVyID09PSBpbmRleCkgb3RoZXIudGVhbSA9IHRl
YW07CiAgICAgICAgaWYgKHJvb20ubW9kZSA9PT0gJ0JBVFRMRU1PREUnICYmIG1hbi5jb250cm9s
bGVyID49IDApIHsKICAgICAgICAgIHJvb20ubWVuLmZvckVhY2goKG90aGVyLCBrKSA9PiB7IGlm
IChrICE9PSBpbmRleCAmJiBvdGhlci5leGlzdHMgJiYgb3RoZXIuY2xpZW50ID09PSBtYW4uY2xp
ZW50KSBvdGhlci50ZWFtID0gdGVhbTsgfSk7CiAgICAgICAgfQogICAgICAgIHJvb20uYnJvYWRj
YXN0TWVuKDApOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAn
bWFuY2hhcicpIHJldHVybiB0aGlzLmNob29zZUNoYXJhY3Rlcihkb2MpOwogICAgaWYgKGtpbmQg
PT09ICdpbmNyZWFzZWxhdGVuY3knKSB7CiAgICAgIHNsb3QubGF0ZW5jeSArPSAyOwogICAgICBz
bG90LmxhdGVuY3lUYXJnZXQgKz0gMjsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7
CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAncmVtZWFzdXJlJykgewogICAg
ICBsZXQgYmVzdCA9IDUwMDA7CiAgICAgIGZvciAobGV0IGsgPSAwOyBrIDwgMTA7IGsgKz0gMSkg
ewogICAgICAgIGNvbnN0IHNlbnQgPSBEYXRlLm5vdygpOwogICAgICAgIHRoaXMuc2VuZCgnPHBp
bmc+PC9waW5nPicpOwogICAgICAgIGZvciAobGV0IHJlcGx5ID0gYXdhaXQgdGhpcy5yZWFkTGlu
ZSgpOyByZXBseSAhPT0gJzxwaW5nb2s+PC9waW5nb2s+JzsgcmVwbHkgPSBhd2FpdCB0aGlzLnJl
YWRMaW5lKCkpIHsKICAgICAgICAgIGlmIChyZXBseSA9PT0gbnVsbCkgdGhyb3cgbmV3IFhtbEVy
cm9yKCdjbG9zZWQnKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgdG9vayA9IERhdGUubm93KCkg
LSBzZW50OwogICAgICAgIGlmICh0b29rIDwgYmVzdCkgYmVzdCA9IHRvb2s7CiAgICAgICAgYXdh
aXQgc2xlZXAodG9vayA8IDUwMCA/IHRvb2sgOiA1MDApOwogICAgICB9CiAgICAgIGlmIChiZXN0
IDw9IDApIGJlc3QgPSAxOwogICAgICBiZXN0ICs9IDE1OwogICAgICBzbG90LmxhdGVuY3kgPSBT
VEVQICsgTWF0aC5jZWlsKChiZXN0ICogMS43ICsgMC4xNikgLyAzMyAvIFNURVApICogU1RFUDsK
ICAgICAgc2xvdC5sYXRlbmN5VGFyZ2V0ID0gc2xvdC5sYXRlbmN5OwogICAgICBzbG90LmxhdGVu
Y3lTaG93biA9IHNsb3QubGF0ZW5jeTsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7
CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnc3RhcnRlZGdhbWUnKSB7CiAg
ICAgIHNsb3QuZmlnaHRpbmcgPSB0cnVlOwogICAgICBzbG90Lmhhc1BsYXllciA9IGZhbHNlOwog
ICAgICB0aGlzLnJlc2V0RnJhbWVzKCk7CiAgICAgIGZvciAobGV0IGsgPSAwOyBrIDwgMzsgayAr
PSAxKSB7CiAgICAgICAgaWYgKCFyb29tLm1lblt0aGlzLmluZGV4ICogMyArIGtdLmV4aXN0cykg
eyBzbG90Lmhhc1BsYXllciA9IHRydWU7IGJyZWFrOyB9CiAgICAgIH0KICAgICAgc2xvdC5zdGFy
dGVkID0gdHJ1ZTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICd3aW50ZWFt
JykgewogICAgICBjb25zdCB0ZWFtID0gaW50KHRhZ1ZhbHVlKGRvYywgJ3dpbnRlYW0nKSk7CiAg
ICAgIGlmICghcm9vbS53aW5SZXBvcnRlZCkgewogICAgICAgIHJvb20ud2luUmVwb3J0ZWQgPSB0
cnVlOwogICAgICAgIHJvb20ubG9nKGBoZiByb29tICR7cm9vbS5udW1iZXJ9OiAke3Jvb20ubW9k
ZX0gd29uIGJ5ICR7dGVhbX1gKTsKICAgICAgfQogICAgfQogIH0KCiAgLy8gaS5pKCk6IHRoaXMg
Z2FtZSdzIHBhY2tldCBjYW1lOyBlYWNoIG90aGVyIGZpZ2h0aW5nIGdhbWUgZ2V0cyBhIHNlbmQu
CiAgcmVxdWVzdEZsdXNoZXMoKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYg
KCFyb29tLmZpZ2h0aW5nTm93KSByZXR1cm47CiAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4
IDwgQ0xJRU5UUzsgaW5kZXggKz0gMSkgewogICAgICBpZiAoaW5kZXggIT09IHRoaXMuaW5kZXgg
JiYgcm9vbS5zbG90c1tpbmRleF0uZmlnaHRpbmcpIHJvb20uc2xvdHNbaW5kZXhdLmZsdXNoZXMg
Kz0gMTsKICAgIH0KICB9CgogIC8vIGkuYigpOiB0aGUgZnJhbWVzIG9mIHRoZSBvdGhlcnMgdGhp
cyBnYW1lIGhhcyBub3QgaGFkLCBhcyBsb25nIGFzIGV2ZXJ5IG90aGVyIGdhbWUgc2VudCB0aGVt
LgogIHNlbmRGcmFtZXMoKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgbGV0IHRl
eHQgPSAnJzsKICAgIGZvciAoOzspIHsKICAgICAgY29uc3QgdCA9IHRoaXMubmV4dEZyYW1lOwog
ICAgICBsZXQgY29tcGxldGUgPSB0cnVlOwogICAgICBsZXQgYW55ID0gZmFsc2U7CiAgICAgIGZv
ciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgICAg
aWYgKGluZGV4ID09PSB0aGlzLmluZGV4KSBjb250aW51ZTsKICAgICAgICBjb25zdCBvdGhlciA9
IHJvb20uc2xvdHNbaW5kZXhdOwogICAgICAgIGlmICghb3RoZXIuZmlnaHRpbmcgJiYgb3RoZXIu
bGVmdEZyYW1lIDwgdCkgY29udGludWU7CiAgICAgICAgYW55ID0gdHJ1ZTsKICAgICAgICBpZiAo
b3RoZXIubGFzdFBhY2tldCA8IHQpIHsgY29tcGxldGUgPSBmYWxzZTsgYnJlYWs7IH0KICAgICAg
fQogICAgICBpZiAoIWNvbXBsZXRlIHx8ICFhbnkpIGJyZWFrOwogICAgICBsZXQgcGFydCA9ICcn
OwogICAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgQ0xJRU5UUzsgaW5kZXggKz0gMSkg
ewogICAgICAgIGlmIChpbmRleCA9PT0gdGhpcy5pbmRleCkgY29udGludWU7CiAgICAgICAgY29u
c3Qgb3RoZXIgPSByb29tLnNsb3RzW2luZGV4XTsKICAgICAgICBpZiAoKG90aGVyLmZpZ2h0aW5n
IHx8IG90aGVyLmxlZnRGcmFtZSA+PSB0KSAmJiBvdGhlci5sYXN0UGFja2V0ID49IHQpIHBhcnQg
Kz0gb3RoZXIuZnJhbWVzW3QgJSBGUkFNRVNfS0VQVF0gfHwgJyc7CiAgICAgIH0KICAgICAgaWYg
KCFwYXJ0KSBicmVhazsKICAgICAgdGV4dCArPSBwYXJ0OwogICAgICB0aGlzLm5leHRGcmFtZSAr
PSAxOwogICAgfQogICAgaWYgKCF0ZXh0KSByZXR1cm47CiAgICBpZiAodGhpcy5xdWV1ZWQpIHsK
ICAgICAgdGV4dCArPSB0aGlzLnF1ZXVlZDsKICAgICAgdGhpcy5xdWV1ZWQgPSAnJzsKICAgIH0K
ICAgIHRoaXMuc2VuZCh0ZXh0KTsKICB9CgogIHJlc2V0RnJhbWVzKCkgeyAvLyBpLmMoKQogICAg
dGhpcy5sYXN0RnJhbWUgPSAtMTsKICAgIHRoaXMubmV4dEZyYW1lID0gMDsKICAgIHRoaXMucXVl
dWVkID0gJyc7CiAgfQoKICAvLyBpLmEoKTogdGhpcyBjb21wdXRlciBsZWF2ZXMgdGhlIHJvb20u
CiAgbGVhdmUoKSB7CiAgICBpZiAodGhpcy5pbmRleCA9PT0gLTEpIHJldHVybjsKICAgIGNvbnN0
IHJvb20gPSB0aGlzLnJvb207CiAgICBjb25zdCBpbmRleCA9IHRoaXMuaW5kZXg7CiAgICB0aGlz
LnJlcXVlc3RGbHVzaGVzKCk7CiAgICBjb25zdCBzbG90ID0gcm9vbS5zbG90c1tpbmRleF07CiAg
ICBpZiAoc2xvdC5vbmxpbmUgJiYgc2xvdC5jb25uZWN0aW9uID09PSB0aGlzKSB7CiAgICAgIGZv
ciAoY29uc3QgbWFuIG9mIHJvb20ubWVuKSB7CiAgICAgICAgaWYgKG1hbi5jbGllbnQgIT09IGlu
ZGV4ICYmIChtYW4uY29tbWFuZGVyIDwgaW5kZXggKiAzIHx8IG1hbi5jb21tYW5kZXIgPiBpbmRl
eCAqIDMgKyAyKSkgY29udGludWU7CiAgICAgICAgT2JqZWN0LmFzc2lnbihtYW4sIG5ld01hbigp
LCB7IHJhbmRvbTogdHJ1ZSB9KTsKICAgICAgICBtYW4uY2hhciA9ICcnOwogICAgICB9CiAgICAg
IHNsb3QuYWRtaW4gPSBmYWxzZTsKICAgICAgc2xvdC5vbmxpbmUgPSBmYWxzZTsKICAgICAgaWYg
KHNsb3QubGFzdFBhY2tldCA+IDApIHNsb3QubGVmdEZyYW1lID0gc2xvdC5sYXN0UGFja2V0Owog
ICAgICBzbG90LmZpZ2h0aW5nID0gZmFsc2U7CiAgICAgIHNsb3QuaGFzUGxheWVyID0gZmFsc2U7
CiAgICAgIHNsb3QuY29ubmVjdGlvbiA9IG51bGw7CiAgICAgIGlmICghcm9vbS5maWdodGluZ05v
dykgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAgICAgIHJvb20uYnJvYWRjYXN0TGlzdCgtMSwgaW5k
ZXgpOwogICAgICB0aGlzLmluZGV4ID0gLTE7CiAgICAgIHJvb20ubG9nKGBoZiByb29tICR7cm9v
bS5udW1iZXJ9OiAke3RoaXMubmFtZX0gbGVhdmVzYCk7CiAgICAgIHJvb20ucmVjb3VudCgpOwog
ICAgfQogICAgdGhpcy5pbmRleCA9IC0xOwogIH0KCiAgLy8gLS0tLSB3aGF0IHRoZSBzZXJ2ZXIg
c2VuZHMgb25lIGdhbWUKICBzZW5kU2V0dGluZyhjaWQpIHsgLy8gaS5hKGludCkKICAgIHRoaXMu
c2VuZChgPHNldHRpbmc+JHtjaWQgIT09IC0xID8gYDxjPiR7Y2lkfTwvYz5gIDogJyd9PHdhaXR3
aGVuZmlnaHQ+JHt0aGlzLnJvb20uYWxsb3dKb2luV2hlbkZpZ2h0aW5nID8gMSA6IDB9PC93YWl0
d2hlbmZpZ2h0Pjwvc2V0dGluZz5gKTsKICB9CgogIHNlbmRHYW1lU2V0dGluZyhjaWQpIHsgLy8g
aS5iKGludCkKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICB0aGlzLnNlbmQoYDxnYW1l
c2V0dGluZz4ke2NpZCAhPT0gLTEgPyBgPGM+JHtjaWR9PC9jPmAgOiAnJ308YmdpZD4ke3Jvb20u
YmFja2dyb3VuZH08L2JnaWQ+PG11c2ljaWQ+JHtyb29tLm11c2ljfTwvbXVzaWNpZD5gCiAgICAg
ICsgYDxtcD4ke3Jvb20ubXVsdGlwbGFuZSA/IDEgOiAwfTwvbXA+PGJncmFuZG9tPiR7cm9vbS5i
YWNrZ3JvdW5kUmFuZG9tID8gMSA6IDB9PC9iZ3JhbmRvbT5gCiAgICAgICsgYDxtdXNpY3JhbmRv
bT4ke3Jvb20ubXVzaWNSYW5kb20gPyAxIDogMH08L211c2ljcmFuZG9tPjxob3JzZT4ke3Jvb20u
aG9yc2VzfTwvaG9yc2U+YAogICAgICArIGA8Z2lhbnRvYmo+JHtyb29tLmdpYW50T2JqZWN0c308
L2dpYW50b2JqPjxkaWZmPiR7cm9vbS5kaWZmaWN1bHR5fTwvZGlmZj48bm9ybGV2PiR7cm9vbS5u
b3JtYWxpemVMZXZlbH08L25vcmxldj5gCiAgICAgICsgYDxkaW5vPiR7cm9vbS5kaW5vc2F1cnN9
PC9kaW5vPjx0ZXN0dHJvb3A+JHtyb29tLnRlc3RUcm9vcHN9PC90ZXN0dHJvb3A+PHNvbGRpZXJu
dW1iZXI+JHtyb29tLnNvbGRpZXJOdW1iZXJ9PC9zb2xkaWVybnVtYmVyPmAKICAgICAgKyBgPHNv
bGRpZXJyZXNlcnZlZD4ke3Jvb20uc29sZGllclJlc2VydmVkfTwvc29sZGllcnJlc2VydmVkPjxz
dG9yeWk+JHtyb29tLnN0b3J5fTwvc3RvcnlpPmAKICAgICAgKyBgPGJhdHRsZXR5cGU+JHtyb29t
LmJhdHRsZVR5cGV9PC9iYXR0bGV0eXBlPjxwcmVzZXR0eXBlPiR7cm9vbS5wcmVzZXR9PC9wcmVz
ZXR0eXBlPjwvZ2FtZXNldHRpbmc+YCk7CiAgfQoKICBzZW5kTGlzdChqb2luZWQsIHF1aXQpIHsg
Ly8gaS5hKGludCwgaW50KQogICAgbGV0IHRleHQgPSBgPGxpc3Q+PGNpZD4ke3RoaXMuaW5kZXh9
PC9jaWQ+YDsKICAgIGlmIChqb2luZWQgIT09IC0xKSB0ZXh0ICs9IGA8am9pbl9jaWQ+JHtqb2lu
ZWR9PC9qb2luX2NpZD5gOwogICAgaWYgKHF1aXQgIT09IC0xKSB0ZXh0ICs9IGA8cXVpdF9jaWQ+
JHtxdWl0fTwvcXVpdF9jaWQ+YDsKICAgIGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLnJvb20uc2xv
dHMpIHsKICAgICAgdGV4dCArPSBgPGluZm8+PG5hbWU+PCFbQ0RBVEFbJHtzbG90Lm5hbWV9XV0+
PC9uYW1lPjxvbmxpbmU+JHtzbG90Lm9ubGluZSA/IDEgOiAwfTwvb25saW5lPmAKICAgICAgICAr
IGA8aGFzcGxheWVyPiR7c2xvdC5oYXNQbGF5ZXIgPyAxIDogMH08L2hhc3BsYXllcj48Y2M+JHtz
bG90LmNjfTwvY2M+PHBhdXNlZ2FtZT4ke3Nsb3QucGF1c2VkID8gMSA6IDB9PC9wYXVzZWdhbWU+
YAogICAgICAgICsgYDxsYXRlbmN5PiR7c2xvdC5sYXRlbmN5fTwvbGF0ZW5jeT48cGFnZT4ke3Ns
b3QucGFnZX08L3BhZ2U+YDsKICAgICAgZm9yIChsZXQgayA9IDA7IGsgPCAzOyBrICs9IDEpIHRl
eHQgKz0gYDxwPjwhW0NEQVRBWyR7c2xvdC5wbGF5ZXJzW2tdfV1dPjwvcD5gOwogICAgICB0ZXh0
ICs9IGA8bGVhdmVfZj4ke3Nsb3QubGVmdEZyYW1lfTwvbGVhdmVfZj48L2luZm8+YDsKICAgIH0K
ICAgIHRoaXMuc2VuZCh0ZXh0ICsgJzwvbGlzdD4nKTsKICB9CgogIHNlbmRNZW4oY2hhbmdlZCkg
eyAvLyBpLmMoaW50KQogICAgbGV0IHRleHQgPSBgPG1hbmxpc3Q+PG51bWNoYW5nZWQ+JHtjaGFu
Z2VkfTwvbnVtY2hhbmdlZD5gOwogICAgZm9yIChjb25zdCBtYW4gb2YgdGhpcy5yb29tLm1lbikg
ewogICAgICB0ZXh0ICs9IGA8bWFuPjxjaWQ+JHttYW4uY2xpZW50fTwvY2lkPjxjb24+JHttYW4u
Y29udHJvbGxlcn08L2Nvbj48dGVhbT4ke21hbi50ZWFtfTwvdGVhbT48Y2hhcj4ke21hbi5jaGFy
fTwvY2hhcj5gCiAgICAgICAgKyBgPGx2PiR7bWFuLmxldmVsfTwvbHY+PGNvbW0+JHttYW4uY29t
bWFuZGVyfTwvY29tbT48cmFuZD4ke21hbi5yYW5kb20gPyAxIDogMH08L3JhbmQ+PGV4aXN0PiR7
bWFuLmV4aXN0cyA/IDEgOiAwfTwvZXhpc3Q+PC9tYW4+YDsKICAgIH0KICAgIHRoaXMuc2VuZCh0
ZXh0ICsgJzwvbWFubGlzdD4nKTsKICB9CgogIG5vdGljZSh0ZXh0KSB7IC8vIGkuYihTdHJpbmcp
OiBhIGxpbmUgZnJvbSB0aGUgc2VydmVyIHRvIHRoaXMgZ2FtZSBvbmx5CiAgICB0aGlzLnNlbmQo
YDxjaGF0PjxjPiR7U0VSVkVSX1NMT1R9PC9jPjxtPjwhW0NEQVRBWzxmb250IGNvbG9yPSIjRkZG
RkFBIj4ke3RleHR9PC9mb250Pl1dPjwvbT48L2NoYXQ+YCk7CiAgfQoKICBhbm5vdW5jZSh0ZXh0
KSB7IC8vIGkuZShTdHJpbmcpOiBhIGxpbmUgZnJvbSB0aGUgc2VydmVyIHRvIGV2ZXJ5b25lCiAg
ICB0aGlzLnJvb20uYnJvYWRjYXN0KGA8Y2hhdD48Yz4ke1NFUlZFUl9TTE9UfTwvYz48bT48IVtD
REFUQVs8Zm9udCBjb2xvcj0iI0ZGQ0NGRiI+JHt0ZXh0fTwvZm9udD5dXT48L20+PC9jaGF0PmAp
OwogIH0KCiAgLy8gLS0tLSB0aGUgd2FpdGluZyByb29tIGFuZCB0aGUgbWVudXMKICBzdGFydENv
dW50KGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGNvbnN0IGNvdW50ZG93
biA9IHJvb20uY291bnRkb3duOwogICAgaWYgKGNvdW50ZG93bi5vbikgcmV0dXJuOwogICAgY29u
c3QgYWN0aW9uID0gdGFnVmFsdWUoZG9jLCAnYWN0aW9uJyk7CiAgICBjb25zdCBwYWdlID0gdGFn
VmFsdWUoZG9jLCAncGFnZScpOwogICAgbGV0IHRvZ2V0aGVyID0gdHJ1ZTsKICAgIGZvciAoY29u
c3Qgc2xvdCBvZiByb29tLm9ubGluZSgpKSB7CiAgICAgIGlmIChwYWdlID09PSAnRklHSFRJTkcn
ID8gc2xvdC5wYWdlICE9PSAnRklHSFRJTkcnICYmIHNsb3QucGFnZSAhPT0gJ1dBSVRST09NJyA6
IHNsb3QucGFnZSAhPT0gcGFnZSkgeyB0b2dldGhlciA9IGZhbHNlOyBicmVhazsgfQogICAgfQog
ICAgaWYgKHJvb20ucGFnZSAhPT0gcGFnZSB8fCAhdG9nZXRoZXIpIHJldHVybjsKICAgIGNvbnN0
IHN0YXJ0ID0gKHdoYXQsIGNvdW50ID0gQ09VTlRET1dOLCBzaG93biA9IHdoYXQpID0+IHsKICAg
ICAgY291bnRkb3duLm9uID0gdHJ1ZTsKICAgICAgY291bnRkb3duLmFjdGlvbiA9IHdoYXQ7CiAg
ICAgIGNvdW50ZG93bi5jb3VudCA9IGNvdW50OwogICAgICByb29tLmJyb2FkY2FzdENsaWNrKHRo
aXMuaW5kZXgsIHNob3duKTsKICAgIH07CiAgICBjb25zdCB6ZXJvID0gKCkgPT4gYnlUYWcoZG9j
LCAnemVybycpLmxlbmd0aCAmJiB2YWx1ZU9mKGJ5VGFnKGRvYywgJ3plcm8nKVswXSkgPT09ICd0
cnVlJzsKICAgIGlmIChyb29tLnBhZ2UgPT09ICdXQUlUUk9PTScgJiYgKGFjdGlvbiA9PT0gJ2Ns
aWNrdnMnIHx8IGFjdGlvbiA9PT0gJ2NsaWNrc3RvcnknIHx8IGFjdGlvbiA9PT0gJ2NsaWNrYmF0
dGxlJykpIHsKICAgICAgc3RhcnQoYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAocm9vbS5wYWdlID09
PSAnQ0hBUk1FTlUnICYmIGFjdGlvbiA9PT0gJ2NsaWNrbmV4dCcpIHsKICAgICAgaWYgKHRoaXMu
Y2FuU3RhcnQoKSkgc3RhcnQoYWN0aW9uLCBDT1VOVERPV04sIHJvb20ubW9kZSA9PT0gJ0JBVFRM
RU1PREUnIHx8IHJvb20ubW9kZSA9PT0gJ1NUT1JZTU9ERScgPyAnY2xpY2tmaWdodCcgOiBhY3Rp
b24pOwogICAgfSBlbHNlIGlmICgocm9vbS5wYWdlID09PSAnU1RPUllNRU5VJyB8fCByb29tLnBh
Z2UgPT09ICdCQVRUTEVTRVRUSU5HTUVOVScpICYmIGFjdGlvbiA9PT0gJ2NsaWNrbmV4dCcpIHsK
ICAgICAgc3RhcnQoYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAocm9vbS5wYWdlID09PSAnR0FNRVNF
VFRJTkdNRU5VJyAmJiBhY3Rpb24gPT09ICdjbGlja2ZpZ2h0JykgewogICAgICBzdGFydChhY3Rp
b24pOwogICAgfSBlbHNlIGlmIChyb29tLmZpZ2h0aW5nTm93ICYmIGFjdGlvbiA9PT0gJ3F1aXRn
YW1lJykgewogICAgICBjb25zdCBpc1plcm8gPSB6ZXJvKCk7CiAgICAgIHN0YXJ0KGFjdGlvbiwg
aXNaZXJvID8gMSA6IENPVU5URE9XTiAqIDIpOwogICAgfSBlbHNlIGlmIChyb29tLmZpZ2h0aW5n
Tm93ICYmIGFjdGlvbiA9PT0gJ3Jlc3RhcnRnYW1lJykgewogICAgICBpZiAocm9vbS5iYWNrZ3Jv
dW5kUmFuZG9tKSByb29tLnBpY2tCYWNrZ3JvdW5kKCk7CiAgICAgIGZvciAobGV0IGluZGV4ID0g
MDsgaW5kZXggPCBNRU47IGluZGV4ICs9IDEpIGlmIChyb29tLm1lbltpbmRleF0uZXhpc3RzICYm
IHJvb20ubWVuW2luZGV4XS5yYW5kb20pIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7CiAgICAg
IGlmIChyb29tLm11c2ljUmFuZG9tKSByb29tLnBpY2tNdXNpYygpOwogICAgICBzdGFydChhY3Rp
b24sIENPVU5URE9XTiAqIDIpOwogICAgICBpZiAoemVybygpKSBjb3VudGRvd24uY291bnQgPSAx
OwogICAgfSBlbHNlIGlmIChyb29tLmZpZ2h0aW5nTm93ICYmIGFjdGlvbiA9PT0gJ25leHRzdGFn
ZScpIHsKICAgICAgc3RhcnQoYWN0aW9uLCBDT1VOVERPV04gKiAyKTsKICAgICAgaWYgKHplcm8o
KSkgY291bnRkb3duLmNvdW50ID0gMTsKICAgIH0KICB9CgogIC8vIGkuZCgpOiB3aGV0aGVyIHRo
ZSBjaGFyYWN0ZXIgbWVudSBtYXkgZ28gb24uCiAgY2FuU3RhcnQoKSB7CiAgICBjb25zdCByb29t
ID0gdGhpcy5yb29tOwogICAgY29uc3QgcGVyVGVhbSA9IFswLCAwLCAwLCAwLCAwXTsKICAgIGxl
dCBtZW4gPSAwOwogICAgbGV0IGh1bWFucyA9IDA7CiAgICBmb3IgKGNvbnN0IG1hbiBvZiByb29t
Lm1lbikgewogICAgICBpZiAoIW1hbi5leGlzdHMpIGNvbnRpbnVlOwogICAgICBpZiAobWFuLmNv
bnRyb2xsZXIgIT09IC0xICYmIHJvb20uc2xvdHNbbWFuLmNsaWVudF0gJiYgcm9vbS5zbG90c1tt
YW4uY2xpZW50XS5vbmxpbmUpIGh1bWFucyArPSAxOwogICAgICBtZW4gKz0gMTsKICAgICAgcGVy
VGVhbVttYW4udGVhbSArIDFdICs9IDE7CiAgICB9CiAgICBsZXQgdGVhbXMgPSBwZXJUZWFtWzBd
OwogICAgbGV0IGNyb3dkZWQgPSBmYWxzZTsKICAgIGZvciAobGV0IGsgPSAxOyBrIDwgNTsgayAr
PSAxKSB7CiAgICAgIGlmIChwZXJUZWFtW2tdID4gMCkgdGVhbXMgKz0gMTsKICAgICAgaWYgKHBl
clRlYW1ba10gPiA1KSBjcm93ZGVkID0gdHJ1ZTsKICAgIH0KICAgIGNvbnN0IHJlZnVzZSA9IChi
b2R5KSA9PiB7IHRoaXMuc2VuZChgPGNoYXJtZW51bmV4dGVycm9yPiR7Ym9keX08L2NoYXJtZW51
bmV4dGVycm9yPmApOyByZXR1cm4gZmFsc2U7IH07CiAgICBpZiAobWVuID09PSAwKSByZXR1cm4g
cmVmdXNlKCc8bT5Ob1BsYXllcjwvbT4nKTsKICAgIGlmIChodW1hbnMgPT09IDApIHJldHVybiBy
ZWZ1c2UoJzxtPk5vSHVtYW5QbGF5ZXI8L20+Jyk7CiAgICBpZiAobWVuID09PSAxICYmIHJvb20u
bW9kZSA9PT0gJ1ZTTU9ERScpIHJldHVybiByZWZ1c2UoJzxtPk9uZVBsYXllck9ubHk8L20+Jyk7
CiAgICBpZiAodGVhbXMgPD0gMSAmJiByb29tLm1vZGUgPT09ICdWU01PREUnKSByZXR1cm4gcmVm
dXNlKCc8bT5PbmVUZWFtT25seTwvbT4nKTsKICAgIGlmIChyb29tLm1vZGUgPT09ICdCQVRUTEVN
T0RFJykgewogICAgICBpZiAodGVhbXMgPCByb29tLnRlYW1zKSByZXR1cm4gcmVmdXNlKGA8bT5i
YXR0bGVOb0Vub3VnaFRlYW08L20+PGE+JHtyb29tLmJhdHRsZVR5cGV9PC9hPjxiPiR7cm9vbS50
ZWFtc308L2I+PGM+JHt0ZWFtc308L2M+YCk7CiAgICAgIGlmIChjcm93ZGVkKSByZXR1cm4gcmVm
dXNlKCc8bT5iYXR0bGVOb3RBbGxvd01vcmVUaGFuNTwvbT4nKTsKICAgIH0KICAgIHJldHVybiB0
cnVlOwogIH0KCiAgY2xpY2tCYWNrKGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsK
ICAgIGlmIChyb29tLmNvdW50ZG93bi5vbiB8fCByb29tLnBhZ2UgIT09IHRhZ1ZhbHVlKGRvYywg
J3BhZ2UnKSkgcmV0dXJuOwogICAgY29uc3QgYmFjayA9IChtb2RlLCBwYWdlKSA9PiB7CiAgICAg
IHJvb20ucHJldmlvdXNQYWdlID0gcm9vbS5wYWdlOwogICAgICBpZiAobW9kZSkgcm9vbS5tb2Rl
ID0gbW9kZTsKICAgICAgcm9vbS5wYWdlID0gcGFnZTsKICAgICAgcm9vbS5icm9hZGNhc3RTdGF0
dXMoKTsKICAgICAgcm9vbS5icm9hZGNhc3RDbGljayh0aGlzLmluZGV4LCAnY2xpY2tiYWNrJyk7
CiAgICB9OwogICAgaWYgKHJvb20ucGFnZSA9PT0gJ0NIQVJNRU5VJyAmJiByb29tLm1vZGUgPT09
ICdWU01PREUnKSBiYWNrKCdXQUlUUk9PTScsICdXQUlUUk9PTScpOwogICAgZWxzZSBpZiAocm9v
bS5wYWdlID09PSAnQ0hBUk1FTlUnICYmIHJvb20ubW9kZSA9PT0gJ1NUT1JZTU9ERScpIGJhY2so
J1NUT1JZTU9ERScsICdTVE9SWU1FTlUnKTsKICAgIGVsc2UgaWYgKHJvb20ucGFnZSA9PT0gJ0NI
QVJNRU5VJyAmJiByb29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJykgYmFjaygnQkFUVExFTU9ERScs
ICdCQVRUTEVTRVRUSU5HTUVOVScpOwogICAgZWxzZSBpZiAocm9vbS5wYWdlID09PSAnU1RPUllN
RU5VJyB8fCByb29tLnBhZ2UgPT09ICdCQVRUTEVTRVRUSU5HTUVOVScpIGJhY2soJ1dBSVRST09N
JywgJ1dBSVRST09NJyk7CiAgICBlbHNlIGlmIChyb29tLnBhZ2UgPT09ICdHQU1FU0VUVElOR01F
TlUnKSBiYWNrKG51bGwsICdDSEFSTUVOVScpOwogIH0KCiAgZ2FtZVNldHRpbmcoZG9jKSB7CiAg
ICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKCFbJ0dBTUVTRVRUSU5HTUVOVScsICdD
SEFSTUVOVScsICdTVE9SWU1FTlUnLCAnQkFUVExFU0VUVElOR01FTlUnXS5pbmNsdWRlcyhyb29t
LnBhZ2UpKSByZXR1cm47CiAgICBjb25zdCB2YWx1ZSA9IChuYW1lKSA9PiB7IGNvbnN0IGZvdW5k
ID0gYnlUYWcoZG9jLCBuYW1lKTsgcmV0dXJuIGZvdW5kLmxlbmd0aCA/IHZhbHVlT2YoZm91bmRb
MF0pIDogdW5kZWZpbmVkOyB9OwogICAgY29uc3QgYmFja2dyb3VuZCA9IHZhbHVlKCdiZ2lkJyk7
CiAgICBpZiAoYmFja2dyb3VuZCAhPT0gdW5kZWZpbmVkICYmIChyb29tLmJhY2tncm91bmRSYW5k
b20gfHwgcm9vbS5iYWNrZ3JvdW5kICE9PSBiYWNrZ3JvdW5kKSkgewogICAgICByb29tLmJhY2tn
cm91bmQgPSByb29tLmJhY2tncm91bmRDaG9zZW4gPSBiYWNrZ3JvdW5kOwogICAgICBpZiAoYmFj
a2dyb3VuZCA9PT0gJ3JhbmRvbScpIHsKICAgICAgICByb29tLmJhY2tncm91bmRSYW5kb20gPSB0
cnVlOwogICAgICAgIHJvb20ucGlja0JhY2tncm91bmQoKTsKICAgICAgfSBlbHNlIHsKICAgICAg
ICByb29tLmJhY2tncm91bmRSYW5kb20gPSBmYWxzZTsKICAgICAgfQogICAgfQogICAgY29uc3Qg
bXVzaWMgPSB2YWx1ZSgnbXVzaWNpZCcpOwogICAgaWYgKG11c2ljICE9PSB1bmRlZmluZWQgJiYg
KHJvb20ubXVzaWNSYW5kb20gfHwgcm9vbS5tdXNpYyAhPT0gbXVzaWMpKSB7CiAgICAgIHJvb20u
bXVzaWMgPSBtdXNpYzsKICAgICAgaWYgKG11c2ljID09PSAncmFuZG9tJykgewogICAgICAgIHJv
b20ubXVzaWNSYW5kb20gPSB0cnVlOwogICAgICAgIHJvb20ucGlja011c2ljKCk7CiAgICAgIH0g
ZWxzZSB7CiAgICAgICAgcm9vbS5tdXNpY1JhbmRvbSA9IGZhbHNlOwogICAgICB9CiAgICB9CiAg
ICBjb25zdCBtdWx0aXBsYW5lID0gdmFsdWUoJ21wJyk7CiAgICBpZiAobXVsdGlwbGFuZSAhPT0g
dW5kZWZpbmVkKSByb29tLm11bHRpcGxhbmUgPSBtdWx0aXBsYW5lID09PSAnMSc7CiAgICBjb25z
dCBudW1iZXJzID0gW1snaG9yc2UnLCAnaG9yc2VzJ10sIFsnZ2lhbnRvYmonLCAnZ2lhbnRPYmpl
Y3RzJ10sIFsnZGlmZicsICdkaWZmaWN1bHR5J10sIFsnbm9ybGV2JywgJ25vcm1hbGl6ZUxldmVs
J10sCiAgICAgIFsnZGlubycsICdkaW5vc2F1cnMnXSwgWyd0ZXN0dHJvb3AnLCAndGVzdFRyb29w
cyddLCBbJ3NvbGRpZXJudW1iZXInLCAnc29sZGllck51bWJlciddLAogICAgICBbJ3NvbGRpZXJy
ZXNlcnZlZCcsICdzb2xkaWVyUmVzZXJ2ZWQnXSwgWydzdG9yeWknLCAnc3RvcnknXV07CiAgICBm
b3IgKGNvbnN0IFt0YWcsIGZpZWxkXSBvZiBudW1iZXJzKSB7CiAgICAgIGNvbnN0IHJhdyA9IHZh
bHVlKHRhZyk7CiAgICAgIGlmIChyYXcgIT09IHVuZGVmaW5lZCkgcm9vbVtmaWVsZF0gPSBpbnQo
cmF3KTsKICAgIH0KICAgIGNvbnN0IHJhdyA9IHZhbHVlKCdidCcpOwogICAgaWYgKHJhdyAhPT0g
dW5kZWZpbmVkICYmIHJvb20ucHJlc2V0ICE9PSAtaW50KHJhdykgLSAxICYmIChyb29tLnByZXNl
dCAhPT0gLTEgfHwgcm9vbS5iYXR0bGVUeXBlICE9PSBpbnQocmF3KSkpIHsKICAgICAgbGV0IHR5
cGUgPSBpbnQocmF3KTsKICAgICAgaWYgKHR5cGUgPCAwKSB7CiAgICAgICAgZm9yIChsZXQgaW5k
ZXggPSAwOyBpbmRleCA8IE1FTjsgaW5kZXggKz0gMSkgewogICAgICAgICAgcm9vbS5tZW5baW5k
ZXhdLmV4aXN0cyA9IGZhbHNlOwogICAgICAgICAgaWYgKGluZGV4ID49IDEyKSByb29tLm1lbltp
bmRleF0ucmFuZG9tID0gZmFsc2U7CiAgICAgICAgICByb29tLm1lbltpbmRleF0uY29tbWFuZGVy
ID0gLTE7CiAgICAgICAgfQogICAgICAgIHJvb20ucHJlc2V0ID0gLXR5cGUgLSAxOwogICAgICAg
IGNvbnN0IHByZXNldCA9IChsZXZlbCwgbGlzdCkgPT4gbGlzdC5mb3JFYWNoKChbaW5kZXgsIGNo
YXIsIHRlYW1dKSA9PiBPYmplY3QuYXNzaWduKHJvb20ubWVuW2luZGV4XSwgeyBsZXZlbCwgY2hh
ciwgZXhpc3RzOiB0cnVlLCB0ZWFtIH0pKTsKICAgICAgICBpZiAodHlwZSA9PT0gLTEpIHsKICAg
ICAgICAgIHR5cGUgPSAxMTsKICAgICAgICAgIHByZXNldCgxMCwgW1sxOSwgJ2xlbycsIDFdLCBb
MjAsICdpY3p6eScsIDFdLCBbMjEsICdoZWF0ZXInLCAxXSwgWzIyLCAncmF5ZScsIDFdLCBbMjMs
ICdzaW5hbicsIDFdXSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAtMikgewogICAgICAg
ICAgdHlwZSA9IDExMTE7CiAgICAgICAgICBwcmVzZXQoMTEsIFtbMTUsICd0YXlsb3InLCAxXSwg
WzE2LCAnbGVvJywgMV0sIFsxNywgJ2plbm55JywgMV0sIFsxOCwgJ3JheWUnLCAyXSwgWzE5LCAn
aWN6enknLCAyXSwgWzIwLCAnaGVhdGVyJywgMl0sCiAgICAgICAgICAgIFsyMSwgJ2dvcmRvbics
IDNdLCBbMjIsICdqYXNvbicsIDNdLCBbMjMsICd0aXR0bycsIDNdXSk7CiAgICAgICAgfSBlbHNl
IGlmICh0eXBlID09PSAtMykgewogICAgICAgICAgdHlwZSA9IDExMTsKICAgICAgICAgIHByZXNl
dCgxMiwgW1sxNSwgJ2hlYXRlcicsIDFdLCBbMTYsICdpY3p6eScsIDFdLCBbMTcsICdyYXllJywg
MV0sIFsxOCwgJ3NpbmFuJywgMV0sIFsxOSwgJ3RpdHRvJywgMV0sIFsyMCwgJ2xlbycsIDJdLAog
ICAgICAgICAgICBbMjEsICdnb3Jkb24nLCAyXSwgWzIyLCAnamVubnknLCAyXSwgWzIzLCAnamFz
b24nLCAyXV0pOwogICAgICAgIH0gZWxzZSBpZiAodHlwZSA9PT0gLTQpIHsKICAgICAgICAgIHR5
cGUgPSAxMTI7CiAgICAgICAgICBwcmVzZXQoMTQsIFtbMTUsICdsZW8nLCAwXSwgWzE2LCAnc2lu
YW4nLCAwXSwgWzE3LCAnZ29yZG9uJywgMF0sIFsxOCwgJ2ljenp5JywgMV0sIFsxOSwgJ2hlYXRl
cicsIDFdLCBbMjAsICdyYXllJywgMV0sCiAgICAgICAgICAgIFsyMSwgJ2phc29uJywgM10sIFsy
MiwgJ3RpdHRvJywgM10sIFsyMywgJ2dpZ2dzJywgM11dKTsKICAgICAgICB9CiAgICAgIH0gZWxz
ZSB7CiAgICAgICAgcm9vbS5wcmVzZXQgPSAtMTsKICAgICAgfQogICAgICByb29tLmJhdHRsZVR5
cGUgPSB0eXBlOwogICAgICBpZiAodHlwZSA9PT0gMTEpIHJvb20udGVhbXMgPSAyOwogICAgICBl
bHNlIGlmICh0eXBlID09PSAxMiB8fCB0eXBlID09PSAxMTEpIHJvb20udGVhbXMgPSAzOwogICAg
ICBlbHNlIGlmICh0eXBlID09PSAyMiB8fCB0eXBlID09PSAxMyB8fCB0eXBlID09PSAxMTExIHx8
IHR5cGUgPT09IDExMikgcm9vbS50ZWFtcyA9IDQ7CiAgICAgIGlmIChyb29tLnRlYW1zID09PSAy
KSByb29tLmJhY2tncm91bmQgPSAnYmF0dGxlMic7CiAgICAgIGVsc2UgaWYgKHJvb20udGVhbXMg
PT09IDMpIHJvb20uYmFja2dyb3VuZCA9ICdiYXR0bGUzJzsKICAgICAgZWxzZSBpZiAocm9vbS50
ZWFtcyA9PT0gNCkgcm9vbS5iYWNrZ3JvdW5kID0gJ2JhdHRsZTQnOwogICAgICBjb25zdCBtYXBz
ID0geyAxMTogWzAsIDEsIC0xLCAtMV0sIDIyOiBbMCwgMSwgMCwgMV0sIDExMTogWzAsIDEsIDIs
IC0xXSwgMTExMTogWzAsIDEsIDIsIDNdLCAxMjogWzEsIDAsIDEsIC0xXSwKICAgICAgICAxMzog
WzAsIDEsIDEsIDFdLCAxMTI6IFsxLCAxLCAwLCAyXSB9OwogICAgICBpZiAobWFwc1t0eXBlXSkg
cm9vbS50ZWFtTWFwID0gbWFwc1t0eXBlXTsKICAgIH0KICAgIHJvb20uYnJvYWRjYXN0R2FtZVNl
dHRpbmcodGhpcy5pbmRleCk7CiAgfQoKICB1cGRhdGVJbmZvKGRvYykgewogICAgY29uc3Qgcm9v
bSA9IHRoaXMucm9vbTsKICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3Q7CiAgICBzbG90Lm5hbWUg
PSB0YWdWYWx1ZShkb2MsICduYW1lJyk7IC8vICh0aGUgb3JpZ2luYWwga2VlcHMgdGhlIG5hbWUg
aXQgam9pbmVkIHdpdGggZm9yIGl0cyBsb2cgYW5kIC9tZSkKICAgIGZvciAobGV0IGsgPSAwOyBr
IDwgMzsgayArPSAxKSBzbG90LnBsYXllcnNba10gPSB0aGlzLnBsYXllcnNba10gPSB0YWdWYWx1
ZShkb2MsICdwJywgayk7CiAgICBmb3IgKGxldCBrID0gMDsgayA8IDMwOyBrICs9IDEpIHsKICAg
ICAgc2xvdC5sZXZlbHNba10gPSBpbnQodGFnVmFsdWUoZG9jLCAnbCcsIGspKTsKICAgICAgaWYg
KHNsb3QubGV2ZWxzW2tdID4gTUFYX0xFVkVMKSB0aGlzLmNoZWF0ID0gMTsKICAgIH0KICAgIGZv
ciAobGV0IGsgPSAwOyBrIDwgMzsgayArPSAxKSB7CiAgICAgIGNvbnN0IG1hbiA9IHJvb20ubWVu
W3RoaXMuaW5kZXggKiAzICsga107CiAgICAgIGlmICghbWFuLmV4aXN0cykgY29udGludWU7CiAg
ICAgIGNvbnN0IGNoYXJhY3RlciA9IENIQVJBQ1RFUlMuaW5kZXhPZihtYW4uY2hhcik7CiAgICAg
IGlmIChjaGFyYWN0ZXIgPj0gMCAmJiBzbG90LmxldmVsc1tjaGFyYWN0ZXJdID4gMCkgewogICAg
ICAgIG1hbi5sZXZlbCA9IHNsb3QubGV2ZWxzW2NoYXJhY3Rlcl07CiAgICAgICAgZm9yIChjb25z
dCBvdGhlciBvZiByb29tLm1lbikgaWYgKG90aGVyLmV4aXN0cyAmJiBvdGhlci5jb21tYW5kZXIg
PT09IHRoaXMuaW5kZXggKiAzICsgaykgb3RoZXIubGV2ZWwgPSBtYW4ubGV2ZWw7CiAgICAgIH0K
ICAgIH0KICAgIGlmICghcm9vbS5maWdodGluZ05vdykgewogICAgICByb29tLmJyb2FkY2FzdExp
c3QoLTEsIC0xKTsKICAgICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAgICB9CiAgfQoKICBhZGRQ
bGF5ZXIoZG9jKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20ucGFn
ZSAhPT0gJ0NIQVJNRU5VJykgcmV0dXJuOwogICAgY29uc3QgY29udHJvbGxlciA9IGludCh2YWx1
ZU9mKGRvYykpOwogICAgY29uc3QgaW5kZXggPSB0aGlzLmluZGV4ICogMyArIGNvbnRyb2xsZXI7
CiAgICBjb25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICBpZiAoIW1hbiB8fCBjb250cm9s
bGVyIDwgMCB8fCBjb250cm9sbGVyID4gMikgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBzdWNoIHBs
YXllcicpOwogICAgaWYgKG1hbi5leGlzdHMpIHJldHVybjsKICAgIG1hbi5leGlzdHMgPSB0cnVl
OwogICAgbWFuLmNsaWVudCA9IHRoaXMuaW5kZXg7CiAgICBtYW4uY29udHJvbGxlciA9IGNvbnRy
b2xsZXI7CiAgICBtYW4udGVhbSA9IC0xOwogICAgcm9vbS5tZW4uZm9yRWFjaCgob3RoZXIsIGsp
ID0+IHsgaWYgKGsgIT09IGluZGV4ICYmIG90aGVyLmV4aXN0cyAmJiBvdGhlci5jbGllbnQgPT09
IHRoaXMuaW5kZXgpIG1hbi50ZWFtID0gb3RoZXIudGVhbTsgfSk7CiAgICBpZiAobWFuLnRlYW0g
PT09IC0xKSBtYW4udGVhbSA9IHRoaXMubGVhc3RUZWFtKGluZGV4KTsKICAgIGlmIChtYW4ucmFu
ZG9tIHx8ICFtYW4uY2hhcikgewogICAgICBtYW4ucmFuZG9tID0gdHJ1ZTsKICAgICAgdGhpcy5w
aWNrQ2hhcmFjdGVyKGluZGV4KTsKICAgIH0gZWxzZSB7CiAgICAgIGNvbnN0IGNoYXJhY3RlciA9
IENIQVJBQ1RFUlMuaW5kZXhPZihtYW4uY2hhcik7CiAgICAgIGlmIChjaGFyYWN0ZXIgPj0gMCAm
JiAodGhpcy5zbG90LmxldmVsc1tjaGFyYWN0ZXJdIDw9IDAgfHwgdGhpcy5zbG90LmxldmVsc1tj
aGFyYWN0ZXJdICE9PSBtYW4ubGV2ZWwpKSB7CiAgICAgICAgbWFuLnJhbmRvbSA9IHRydWU7CiAg
ICAgICAgdGhpcy5waWNrQ2hhcmFjdGVyKGluZGV4KTsKICAgICAgfQogICAgfQogICAgdGhpcy5s
aW1pdE1lbigpOwogICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAgfQoKICAvLyBUaGUgdGVhbSB3
aXRoIHRoZSBmZXdlc3QgbWVuIChub3QgY291bnRpbmcgc29sZGllcnMpLCBmb3IgYSBuZXcgbWFu
LgogIGxlYXN0VGVhbShleGNlcHQpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBj
b25zdCBjb3VudHMgPSBbMCwgMCwgMCwgMF07CiAgICByb29tLm1lbi5mb3JFYWNoKChvdGhlciwg
aykgPT4geyBpZiAoayAhPT0gZXhjZXB0ICYmIG90aGVyLmV4aXN0cyAmJiBvdGhlci5jb21tYW5k
ZXIgPT09IC0xKSBjb3VudHNbb3RoZXIudGVhbV0gKz0gMTsgfSk7CiAgICBpZiAocm9vbS5tb2Rl
ICE9PSAnQkFUVExFTU9ERScpIHJvb20udGVhbXMgPSA0OwogICAgbGV0IGZld2VzdCA9IDk5OTsK
ICAgIGxldCB0ZWFtID0gMDsKICAgIGZvciAobGV0IGsgPSAwOyBrIDwgcm9vbS50ZWFtczsgayAr
PSAxKSB7CiAgICAgIGlmIChjb3VudHNba10gPCBmZXdlc3QpIHsKICAgICAgICBmZXdlc3QgPSBj
b3VudHNba107CiAgICAgICAgdGVhbSA9IGs7CiAgICAgIH0KICAgIH0KICAgIHJldHVybiB0ZWFt
OwogIH0KCiAgLy8gaS5lKCk6IGEgY29tcHV0ZXIgcGxheWVyLCBpbiB0aGUgZmlyc3QgZnJlZSBw
bGFjZSBhZnRlciB0aGUgMTIgaHVtYW4gb25lcy4KICBhZGRDb21wdXRlcigpIHsKICAgIGNvbnN0
IHJvb20gPSB0aGlzLnJvb207CiAgICBpZiAocm9vbS5tZW4uZmlsdGVyKChtYW4pID0+IG1hbi5l
eGlzdHMpLmxlbmd0aCA+PSAxMikgcmV0dXJuIGZhbHNlOwogICAgZm9yIChsZXQgaW5kZXggPSBN
RU4gLSAxOyBpbmRleCA+PSAxMjsgaW5kZXggLT0gMSkgewogICAgICBpZiAocm9vbS5tZW5baW5k
ZXhdLmV4aXN0cyB8fCAoaW5kZXggIT09IDEyICYmICFyb29tLm1lbltpbmRleCAtIDFdLmV4aXN0
cykpIGNvbnRpbnVlOwogICAgICBjb25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICAgIG1h
bi5leGlzdHMgPSB0cnVlOwogICAgICBtYW4udGVhbSA9IHJvb20ubW9kZSA9PT0gJ0JBVFRMRU1P
REUnIHx8IHJvb20ubW9kZSA9PT0gJ1ZTTU9ERScgPyB0aGlzLmxlYXN0VGVhbShpbmRleCkgOiAz
OwogICAgICBtYW4uY2xpZW50ID0gLTE7CiAgICAgIG1hbi5jb250cm9sbGVyID0gLTE7CiAgICAg
IG1hbi5yYW5kb20gPSB0cnVlOwogICAgICBtYW4uY29tbWFuZGVyID0gLTE7CiAgICAgIHRoaXMu
cGlja0NoYXJhY3RlcihpbmRleCk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgcmV0dXJu
IGZhbHNlOwogIH0KCiAgYWRkU29sZGllcihkb2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJv
b207CiAgICBpZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnIHx8IHJvb20uY291bnRkb3duLm9u
KSByZXR1cm47CiAgICBjb25zdCBpbmRleCA9IGludCh0YWdWYWx1ZShkb2MsICdpJykpOwogICAg
bGV0IHNvbGRpZXIgPSB0YWdWYWx1ZShkb2MsICdjaGFyJyk7CiAgICBjb25zdCBjb21tYW5kZXIg
PSByb29tLm1lbltpbmRleF07CiAgICBpZiAoIWNvbW1hbmRlcikgdGhyb3cgbmV3IFhtbEVycm9y
KCdubyBzdWNoIG1hbicpOwogICAgY29uc3Qgcm9sbCA9IHRoaXMucm9vbS5yYW5kb20oKTsKICAg
IHN3aXRjaCAoY29tbWFuZGVyLmNoYXIpIHsKICAgICAgY2FzZSAnbHVjYXMnOiBjYXNlICdkcmV3
JzogY2FzZSAnc2hhd24nOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9pbmZhbnRyeTAxJyAm
JiByb2xsIDwgMC4zKSBzb2xkaWVyID0gJ3pfdmlsbGFnZXIwMSc7CiAgICAgICAgZWxzZSBpZiAo
c29sZGllciA9PT0gJ3pfYXJjaGVyMDEnICYmIHJvbGwgPCAwLjMpIHNvbGRpZXIgPSAnel93b21h
bjAxJzsKICAgICAgICBicmVhazsKICAgICAgY2FzZSAndml2aWFuJzoKICAgICAgICBpZiAoc29s
ZGllciA9PT0gJ3pfaW5mYW50cnkwMScpIHNvbGRpZXIgPSAnel92aWxsYWdlcjAxJzsKICAgICAg
ICBlbHNlIGlmIChzb2xkaWVyID09PSAnel9hcmNoZXIwMScpIHNvbGRpZXIgPSAnel93b21hbjAx
JzsKICAgICAgICBicmVhazsKICAgICAgY2FzZSAnamVubnknOiBjYXNlICdzaW5hbic6CiAgICAg
ICAgaWYgKHNvbGRpZXIgPT09ICd6X2FyY2hlcjAxJykgc29sZGllciA9ICd6X3dvbWFuMDEnOwog
ICAgICAgIGJyZWFrOwogICAgICBjYXNlICdqYXNvbic6CiAgICAgICAgaWYgKHNvbGRpZXIgPT09
ICd6X2luZmFudHJ5MDEnKSBzb2xkaWVyID0gJ3pfYmFuZGl0MDEnOwogICAgICAgIGVsc2UgaWYg
KHNvbGRpZXIgPT09ICd6X2FyY2hlcjAxJykgc29sZGllciA9ICd6X2RhZ2dlcjAxJzsKICAgICAg
ICBlbHNlIHNvbGRpZXIgPSAnel9zaWNrbGUwMSc7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2Ug
J2dpZ2dzJzogY2FzZSAndGl0dG8nOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9pbmZhbnRy
eTAxJykgc29sZGllciA9ICd6X2JhbmRpdDAxJzsKICAgICAgICBlbHNlIGlmIChzb2xkaWVyID09
PSAnel9hcmNoZXIwMScpIHNvbGRpZXIgPSAnel9kYWdnZXIwMSc7CiAgICAgICAgYnJlYWs7CiAg
ICAgIGNhc2UgJ2ljenp5JzoKICAgICAgICBpZiAoc29sZGllciA9PT0gJ3pfY2F2YWxyeTAxJykg
c29sZGllciA9ICd6X2ljZW1hbic7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2UgJ2hlYXRlcic6
CiAgICAgICAgaWYgKHNvbGRpZXIgPT09ICd6X2NhdmFscnkwMScpIHNvbGRpZXIgPSAnel9za3Vs
bCc7CiAgICAgICAgYnJlYWs7CiAgICAgIGRlZmF1bHQ6CiAgICAgICAgYnJlYWs7CiAgICB9CiAg
ICBpZiAoY29tbWFuZGVyLmV4aXN0cyAmJiBjb21tYW5kZXIuY29tbWFuZGVyID09PSAtMSAmJiB0
aGlzLnBsYWNlU29sZGllcihpbmRleCwgc29sZGllcikpIHsKICAgICAgdGhpcy5saW1pdE1lbigp
OwogICAgICByb29tLmJyb2FkY2FzdE1lbigxKTsKICAgIH0KICB9CgogIC8vIGkuYShpbnQsIFN0
cmluZykKICBwbGFjZVNvbGRpZXIoY29tbWFuZGVySW5kZXgsIHNvbGRpZXIpIHsKICAgIGNvbnN0
IHJvb20gPSB0aGlzLnJvb207CiAgICBpZiAocm9vbS5tZW4uZmlsdGVyKChtYW4pID0+IG1hbi5l
eGlzdHMpLmxlbmd0aCA+PSAxMikgcmV0dXJuIGZhbHNlOwogICAgZm9yIChsZXQgaW5kZXggPSAx
MjsgaW5kZXggPCBNRU47IGluZGV4ICs9IDEpIHsKICAgICAgY29uc3QgbWFuID0gcm9vbS5tZW5b
aW5kZXhdOwogICAgICBpZiAobWFuLmV4aXN0cykgY29udGludWU7CiAgICAgIGNvbnN0IGNvbW1h
bmRlciA9IHJvb20ubWVuW2NvbW1hbmRlckluZGV4XTsKICAgICAgT2JqZWN0LmFzc2lnbihtYW4s
IHsgZXhpc3RzOiB0cnVlLCBjbGllbnQ6IC0xLCBjb250cm9sbGVyOiAtMSwgdGVhbTogY29tbWFu
ZGVyLnRlYW0sIHJhbmRvbTogZmFsc2UsCiAgICAgICAgY29tbWFuZGVyOiBjb21tYW5kZXJJbmRl
eCwgY2hhcjogc29sZGllciwgbGV2ZWw6IGNvbW1hbmRlci5sZXZlbCB9KTsKICAgICAgcmV0dXJu
IHRydWU7CiAgICB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQoKICAvLyBpLmYoKTogYXQgbW9zdCAx
MiBtZW47IHRoZSBsYXRlciBvbmVzIGdvLgogIGxpbWl0TWVuKCkgewogICAgbGV0IGNvdW50ID0g
MDsKICAgIGZvciAoY29uc3QgbWFuIG9mIHRoaXMucm9vbS5tZW4pIHsKICAgICAgaWYgKCFtYW4u
ZXhpc3RzKSBjb250aW51ZTsKICAgICAgaWYgKGNvdW50IDwgMTIpIGNvdW50ICs9IDE7CiAgICAg
IGVsc2UgbWFuLmV4aXN0cyA9IGZhbHNlOwogICAgfQogIH0KCiAgY2hvb3NlQ2hhcmFjdGVyKGRv
YykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGlmIChyb29tLnBhZ2UgIT09ICdD
SEFSTUVOVScpIHJldHVybjsKICAgIGNvbnN0IGluZGV4ID0gaW50KHRhZ1ZhbHVlKGRvYywgJ2kn
KSk7CiAgICBjb25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICBpZiAoIW1hbikgdGhyb3cg
bmV3IFhtbEVycm9yKCdubyBzdWNoIG1hbicpOwogICAgaWYgKCFtYW4uZXhpc3RzIHx8IChtYW4u
Y29udHJvbGxlciAhPT0gLTEgJiYgbWFuLmNsaWVudCAhPT0gdGhpcy5pbmRleCkpIHJldHVybjsK
ICAgIG1hbi5jaGFyID0gdGFnVmFsdWUoZG9jLCAnY2hhcicpOwogICAgaWYgKG1hbi5jaGFyID09
PSBudWxsKSB0aHJvdyBuZXcgWG1sRXJyb3IoJ25vIGNoYXJhY3RlcicpOwogICAgaWYgKG1hbi5j
aGFyID09PSAncmFuZG9tJykgewogICAgICBtYW4ucmFuZG9tID0gdHJ1ZTsKICAgICAgdGhpcy5w
aWNrQ2hhcmFjdGVyKGluZGV4KTsKICAgIH0gZWxzZSB7CiAgICAgIG1hbi5yYW5kb20gPSBmYWxz
ZTsKICAgIH0KICAgIG1hbi5sZXZlbCA9IDE7CiAgICBjb25zdCBjaGFyYWN0ZXIgPSBDSEFSQUNU
RVJTLmluZGV4T2YobWFuLmNoYXIpOwogICAgaWYgKGNoYXJhY3RlciA+PSAwKSB7CiAgICAgIGNv
bnN0IGxldmVsID0gbWFuLmNvbnRyb2xsZXIgPT09IC0xID8gcm9vbS5jb21wdXRlckxldmVsKGNo
YXJhY3RlcikgOiB0aGlzLnNsb3QubGV2ZWxzW2NoYXJhY3Rlcl07CiAgICAgIGlmIChsZXZlbCA+
IDApIHsKICAgICAgICBtYW4ubGV2ZWwgPSBsZXZlbDsKICAgICAgICBmb3IgKGNvbnN0IG90aGVy
IG9mIHJvb20ubWVuKSBpZiAob3RoZXIuZXhpc3RzICYmIG90aGVyLmNvbW1hbmRlciA9PT0gaW5k
ZXgpIG90aGVyLmxldmVsID0gbGV2ZWw7CiAgICAgIH0KICAgICAgaWYgKGxldmVsIDw9IDAgJiYg
bWFuLmNvbnRyb2xsZXIgPj0gMCAmJiBtYW4uY2xpZW50ID09PSB0aGlzLmluZGV4KSB7CiAgICAg
ICAgLy8gQSBjaGFyYWN0ZXIgdGhpcyBhY2NvdW50IGhhcyBub3QgdW5sb2NrZWQ6IHRoZSBvcmln
aW5hbCBzaHV0cyB0aGUgZ2FtZSBvdXQuCiAgICAgICAgdGhpcy5raWNrZWQgPSB0cnVlOwogICAg
ICAgIHRoaXMubGVhdmUoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgIH0KICAgIHJvb20u
YnJvYWRjYXN0TWVuKDApOwogIH0KCiAgLy8gaS5kKGludCk6IGEgcmFuZG9tIGNoYXJhY3RlciBm
b3IgYSBtYW46IG9uZSB0aGUgY29tcHV0ZXIgaGFzLCBub3QgdGFrZW4gYnkgYW5vdGhlciBtYW4g
YmVmb3JlIGl0CiAgLy8gb3Igbm90IHJhbmRvbTsgdGhlIGxldmVsIHRvIG1hdGNoLiAoVGhlIG9y
aWdpbmFsIGdhdmUgYSBjb21wdXRlciBwbGF5ZXIgb25lIG9mIHRoZSBjaGFyYWN0ZXJzIHNvbWUK
ICAvLyBjb21wdXRlciBpbiB0aGUgcm9vbSBoYXM7IGhlcmUgaXQgbWF5IGJlIGFueSwgdGhlIHBy
ZW1pdW0gb25lcyB0b28sIHdoaWNoIHBsYXllcnMnIGFjY291bnRzIGRvIG5vdAogIC8vIGhhdmU6
IHNlZSBoZi5qcy4gTm90IFlhZ2EsIHdob20gdGhlIGdhbWUgZG9lcyBub3QgbGV0IGFueW9uZSBw
bGF5LikKICBwaWNrQ2hhcmFjdGVyKGluZGV4KSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29t
OwogICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhdOwogICAgY29uc3QgaHVtYW4gPSBtYW4u
Y2xpZW50ICE9PSAtMTsKICAgIGxldCBvd25lciA9IG1hbi5jbGllbnQ7CiAgICBpZiAob3duZXIg
PT09IC0xIHx8ICFyb29tLnNsb3RzW293bmVyXS5vbmxpbmUpIG93bmVyID0gdGhpcy5pbmRleDsK
ICAgIGNvbnN0IHNsb3QgPSByb29tLnNsb3RzW293bmVyXTsKICAgIGNvbnN0IGF2YWlsYWJsZSA9
ICgpID0+IHsKICAgICAgY29uc3QgbGlzdCA9IFtdOwogICAgICBmb3IgKGNvbnN0IG5hbWUgb2Yg
Q0hBUkFDVEVSUykgewogICAgICAgIGNvbnN0IGNoYXJhY3RlciA9IENIQVJBQ1RFUlMuaW5kZXhP
ZihuYW1lKTsKICAgICAgICBpZiAoaHVtYW4gPyBzbG90LmxldmVsc1tjaGFyYWN0ZXJdID4gMCA6
IG5hbWUgIT09ICd5YWdhJykgbGlzdC5wdXNoKG5hbWUpOwogICAgICB9CiAgICAgIHJldHVybiBs
aXN0OwogICAgfTsKICAgIGxldCBsaXN0ID0gYXZhaWxhYmxlKCk7CiAgICByb29tLm1lbi5mb3JF
YWNoKChvdGhlciwgaykgPT4gewogICAgICBpZiAoIW90aGVyLmV4aXN0cyB8fCAob3RoZXIucmFu
ZG9tICYmIGsgPj0gaW5kZXgpKSByZXR1cm47CiAgICAgIGZvciAobGV0IG4gPSAwOyBuIDwgbGlz
dC5sZW5ndGg7IG4gKz0gMSkgaWYgKGxpc3Rbbl0gPT09IG90aGVyLmNoYXIpIGxpc3Quc3BsaWNl
KG4sIDEpOwogICAgfSk7CiAgICBpZiAoIWxpc3QubGVuZ3RoKSBsaXN0ID0gYXZhaWxhYmxlKCk7
CiAgICBpZiAoIWxpc3QubGVuZ3RoKSB0aHJvdyBuZXcgWG1sRXJyb3IoJ25vIGNoYXJhY3RlcnMn
KTsKICAgIG1hbi5jaGFyID0gbGlzdFt0aGlzLnJvb20ubmV4dEludChsaXN0Lmxlbmd0aCldOwog
ICAgY29uc3QgY2hhcmFjdGVyID0gQ0hBUkFDVEVSUy5pbmRleE9mKG1hbi5jaGFyKTsKICAgIG1h
bi5sZXZlbCA9IDE7CiAgICBpZiAoaHVtYW4pIHsKICAgICAgaWYgKHNsb3QubGV2ZWxzW2NoYXJh
Y3Rlcl0gPiAwKSBtYW4ubGV2ZWwgPSBzbG90LmxldmVsc1tjaGFyYWN0ZXJdOwogICAgfSBlbHNl
IHsKICAgICAgbWFuLmxldmVsID0gcm9vbS5jb21wdXRlckxldmVsKGNoYXJhY3Rlcik7CiAgICB9
CiAgICBmb3IgKGNvbnN0IG90aGVyIG9mIHJvb20ubWVuKSBpZiAob3RoZXIuZXhpc3RzICYmIG90
aGVyLmNvbW1hbmRlciA9PT0gaW5kZXgpIG90aGVyLmxldmVsID0gbWFuLmxldmVsOwogIH0KCiAg
Ly8gaS5nKFN0cmluZyk6IGNoYXQgdGhhdCBzdGFydHMgd2l0aCAiLyIgaXMgYSBjb21tYW5kLiBS
ZXR1cm5zIHdoZXRoZXIgdGhlIGxpbmUgZ29lcyB0byBldmVyeW9uZS4KICBjb21tYW5kKHRleHQp
IHsKICAgIGlmICh0ZXh0ID09PSBudWxsKSByZXR1cm4gdHJ1ZTsKICAgIGNvbnN0IG1lc3NhZ2Ug
PSB0ZXh0LnRyaW0oKTsKICAgIGlmICghbWVzc2FnZSB8fCBtZXNzYWdlWzBdICE9PSAnLycpIHJl
dHVybiB0cnVlOwogICAgY29uc3Qgd29yZHMgPSBtZXNzYWdlLnNwbGl0KC9ccysvKTsKICAgIGNv
bnN0IG5hbWUgPSB3b3Jkc1swXS50b0xvd2VyQ2FzZSgpOwogICAgY29uc3Qgcm9vbSA9IHRoaXMu
cm9vbTsKICAgIGlmIChuYW1lID09PSAnL2hlbHAnKSB7CiAgICAgIGlmICh3b3Jkcy5sZW5ndGgg
PiAxKSByZXR1cm4gdHJ1ZTsKICAgICAgdGhpcy5ub3RpY2UoJzxiPkNvbW1hbmRzIGF2YWlsYWJs
ZTwvYj46ICAvcXVpdCwgL2NsZWFyLCAvbWUsIC9sYXQuIDxiciAvPlR5cGUgPyBhZnRlciBhIGNv
bW1hbmQgdG8gbGVhcm4gYWJvdXQgaXQuIEUuZy46IC9xdWl0ID8gJyk7CiAgICAgIHJldHVybiB0
cnVlOwogICAgfQogICAgaWYgKG5hbWUgPT09ICcvcXVpdCcgfHwgbmFtZSA9PT0gJy9leGl0Jykg
ewogICAgICBpZiAod29yZHMubGVuZ3RoID4gMSAmJiB3b3Jkc1sxXSA9PT0gJz8nKSB7CiAgICAg
ICAgdGhpcy5ub3RpY2UoJzxiPlF1aXQ8L2I+OiBZb3Ugd2lsbCBleGl0IHRoZSByb29tLjxiciAv
PklucHV0czogL3F1aXQsIC9leGl0LicpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAg
ICAgIHRoaXMua2lja2VkID0gdHJ1ZTsKICAgICAgdGhpcy5sZWF2ZSgpOwogICAgICB0aGlzLmNs
b3NlKCk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYgKG5hbWUgPT09ICcvY2xlYXIn
IHx8IG5hbWUgPT09ICcvY2xlYW4nKSB7CiAgICAgIGlmICh3b3Jkcy5sZW5ndGggPiAxKSB7CiAg
ICAgICAgaWYgKHdvcmRzWzFdID09PSAnPycpIHRoaXMubm90aWNlKCc8Yj5DbGVhcjwvYj46IFdp
bGwgY2xlYXIgYWxsIHRoZSBjaGF0IG9uIHlvdXIgc2NyZWVuLjxiciAvPklucHV0czogL2NsZWFy
LCAvY2xlYW4uJyk7CiAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgIH0KICAgICAgZm9yIChsZXQg
ayA9IDA7IGsgPCA1MDsgayArPSAxKSB0aGlzLm5vdGljZSgnPGJyIC8+Jyk7CiAgICAgIGZvciAo
Y29uc3Qgc2xvdCBvZiByb29tLm9ubGluZSgpKSB7CiAgICAgICAgaWYgKHNsb3QuY29ubmVjdGlv
biAhPT0gdGhpcykgc2xvdC5jb25uZWN0aW9uLnNlbmQoYDxjaGF0PjxjPiR7dGhpcy5pbmRleH08
L2M+PG0+PCFbQ0RBVEFbJHt3b3Jkc1swXX1dXT48L20+PC9jaGF0PmApOwogICAgICB9CiAgICAg
IHJldHVybiBmYWxzZTsKICAgIH0KICAgIGlmIChuYW1lID09PSAnL21lJykgewogICAgICBpZiAo
d29yZHMubGVuZ3RoID4gMSAmJiB3b3Jkc1sxXSAhPT0gJz8nKSB7CiAgICAgICAgdGhpcy5hbm5v
dW5jZShgPGZvbnQgY29sb3I9IiNDQ0NDRkYiPjxpPio8Yj4gJHt0aGlzLm5hbWV9PC9iPiAke3dv
cmRzLnNsaWNlKDEpLmpvaW4oJyAnKX0gPC9pPjwvZm9udD5gKTsKICAgICAgICByZXR1cm4gZmFs
c2U7CiAgICAgIH0KICAgICAgdGhpcy5ub3RpY2UoJzxiPk1FPC9iPjogU2VuZHMgdGhlIGFjdGlv
biB0byB0aGUgY2hhdCAoYWN0aW9ucyBhcmUgd3JpdHRlbiBpbiB0aGUgM3JkIHBlcnNvbiwgbGlr
ZSAvbWUganVtcHMpLicpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChuYW1lID09
PSAnL2xhdCcgfHwgbmFtZSA9PT0gJy9sYXRlbmN5JykgewogICAgICBjb25zdCBoZWxwID0gJ0l0
IHdpbGwgbmVlZCBhIGxhdGVuY3kgbnVtYmVyIGJldHdlZW4gMSBhbmQgOTkgYWZ0ZXIgdGhlIGNv
bW1hbmQuIEUuZy46IC9sYXQgNyc7CiAgICAgIGlmICh3b3Jkcy5sZW5ndGggPD0gMSkgdGhpcy5u
b3RpY2UoYDxiPkxhdGVuY3k8L2I+OiAke2hlbHB9YCk7CiAgICAgIGVsc2UgaWYgKHdvcmRzWzFd
ID09PSAnPycpIHRoaXMubm90aWNlKGA8Yj5MYXRlbmN5PC9iPjogQ2hhbmdlcyB5b3VyIGxhdGVu
Y3kuICR7aGVscH08YnIgLz5JbnB1dHM6IC9sYXQsIC9sYXRlbmN5LmApOwogICAgICBlbHNlIGlm
ICghL15bLStdP1xkKyQvLnRlc3Qod29yZHNbMV0pKSB0aGlzLm5vdGljZShgPGI+TGF0ZW5jeTwv
Yj46ICR7aGVscH1gKTsKICAgICAgZWxzZSB7CiAgICAgICAgY29uc3QgdmFsdWUgPSBOdW1iZXIo
d29yZHNbMV0pOwogICAgICAgIGlmICh2YWx1ZSA8PSAwKSB0aGlzLm5vdGljZSgnPGI+TGF0ZW5j
eTwvYj46IFlvdXIgbGF0ZW5jeSBtdXN0IGJlIGJldHdlZW4gMSBhbmQgOTkuJyk7CiAgICAgICAg
ZWxzZSBpZiAodmFsdWUgPiA5OSkgdGhpcy5ub3RpY2UoJ1JlYWxseT8nKTsKICAgICAgICBlbHNl
IHsKICAgICAgICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3Q7CiAgICAgICAgICBzbG90LmxhdGVu
Y3kgPSB2YWx1ZSArIDE7CiAgICAgICAgICBzbG90LmxhdGVuY3lUYXJnZXQgPSBzbG90LmxhdGVu
Y3k7CiAgICAgICAgICB0aGlzLm5vdGljZShgPGI+TGF0ZW5jeTwvYj46IFlvdXIgbGF0ZW5jeSBo
YXMgYmVlbiBjaGFuZ2VkIHRvICR7c2xvdC5sYXRlbmN5IC0gMX0uYCk7CiAgICAgICAgICByb29t
LmJyb2FkY2FzdExpc3QoLTEsIC0xKTsKICAgICAgICB9CiAgICAgIH0KICAgICAgcmV0dXJuIHRy
dWU7CiAgICB9CiAgICB0aGlzLm5vdGljZSgnVW5yZWNvZ25pemVkIGNvbW1hbmQuJyk7CiAgICBy
ZXR1cm4gdHJ1ZTsKICB9Cn0KCm1vZHVsZS5leHBvcnRzID0geyBIZlJvb20sIEhmQ29ubmVjdGlv
biwgcGFyc2VYbWwsIGJ5VGFnLCB2YWx1ZU9mLCBYbWxFcnJvciwgVkVSU0lPTiwgQ0xJRU5UUywg
Q0hBUkFDVEVSUyB9Owo=
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
