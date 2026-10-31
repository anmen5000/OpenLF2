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

INSTALLER_VERSION=10
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
KSA9PiBhbGxvd09yaWdpbihyZXEpLAogICAgaGZKb3VybmFsOiAoKSA9PiBoZi5qb3VybmFsKCkg
fSk7CiAgY29uc3QgaGYgPSBjcmVhdGVIZihjb25maWcsIHsKICAgIGxvZywgY2xpZW50QWRkcmVz
czogKHJlcSkgPT4gY2xpZW50QWRkcmVzcyhyZXEpLCBhbGxvd09yaWdpbjogKHJlcSkgPT4gYWxs
b3dPcmlnaW4ocmVxKSwKICAgIGJ1ZGdldDogKHdzLCBieXRlcykgPT4gd3MubWVzc2FnZUJ1ZGdl
dC50YWtlKDEpICYmIHdzLmJ5dGVCdWRnZXQudGFrZShieXRlcyksCiAgfSk7CgogIGNvbnN0IHNl
cnZlciA9IGh0dHAuY3JlYXRlU2VydmVyKChyZXEsIHJlcykgPT4gewogICAgY29uc3QgeyBwYXRo
bmFtZSB9ID0gbmV3IFVSTChyZXEudXJsLCAnaHR0cDovL3JlbGF5LmludmFsaWQnKTsKICAgIGlm
IChwYXRobmFtZSA9PT0gJy9oZWFsdGh6JykgewogICAgICAvLyBSZWFkYWJsZSBmcm9tIHRoZSBn
YW1lIHBhZ2UgKGFub3RoZXIgb3JpZ2luKSBzbyBpdHMgT25saW5lIHBhbmVsIGNhbiBzaG93ICJy
ZWxheSBPSyIuCiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7CiAgICAgICAgJ2NvbnRlbnQtdHlw
ZSc6ICdhcHBsaWNhdGlvbi9qc29uJywKICAgICAgICAnY2FjaGUtY29udHJvbCc6ICduby1zdG9y
ZScsCiAgICAgICAgJ2FjY2Vzcy1jb250cm9sLWFsbG93LW9yaWdpbic6ICcqJywKICAgICAgfSk7
CiAgICAgIHJlcy5lbmQoSlNPTi5zdHJpbmdpZnkoewogICAgICAgIG9rOiB0cnVlLCByb29tczog
cm9vbXMuc2l6ZSArIGdyb3Vwcy5zaXplLCBjbGllbnRzOiB3c3MuY2xpZW50cy5zaXplLCBpbnN0
YWxsZXI6IGluc3RhbGxlclNpemUoKSA+IDAsCiAgICAgICAgcHJvdG9jb2xzOiBbMSwgMl0sIHBs
YXllcnM6IGNvbmZpZy5yb29tUGxheWVycywgcGFja3M6IEJvb2xlYW4oY29uZmlnLnBhY2tzRGly
KSwgaGY6IGhmLmRlc2NyaWJlKCksCiAgICAgIH0pKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
aWYgKGluc3RhbGxlclBhdGhzLmhhcyhwYXRobmFtZSkpIHsKICAgICAgc2VydmVJbnN0YWxsZXIo
cmVxLCByZXMpOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBsb2NhbCA9IHJlbGF5Rm9s
ZGVyICE9PSAnLycgJiYgcGF0aG5hbWUuc3RhcnRzV2l0aChyZWxheUZvbGRlcikgPyBwYXRobmFt
ZS5zbGljZShyZWxheUZvbGRlci5sZW5ndGggLSAxKSA6IHBhdGhuYW1lOwogICAgaWYgKHBhY2tz
LmhhbmRsZShyZXEsIHJlcywgbG9jYWwpKSByZXR1cm47CiAgICBpZiAoaGYuaGFuZGxlKHJlcSwg
cmVzLCBsb2NhbCkpIHJldHVybjsKICAgIGlmIChwYXRobmFtZSA9PT0gJy8nIHx8IHBhdGhuYW1l
ID09PSBjb25maWcucGF0aCkgewogICAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAnY29udGVudC10
eXBlJzogJ3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgICByZXMuZW5kKGBPcGVu
TEYyIHJlbGF5IGlzIHJ1bm5pbmcuIENvbm5lY3Qgd2l0aCBhIFdlYlNvY2tldCB0byAke2NvbmZp
Zy5wYXRofVxuYCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHJlcy53cml0ZUhlYWQoNDA0LCB7
ICdjb250ZW50LXR5cGUnOiAndGV4dC9wbGFpbjsgY2hhcnNldD11dGYtOCcgfSk7CiAgICByZXMu
ZW5kKCdOb3QgZm91bmRcbicpOwogIH0pOwoKICAvLyBVcGxvYWRpbmcgYSBnYW1lIHBhY2sgZnJv
bSBhIHNsb3cgbGluZSBtYXkgdGFrZSBhIHdoaWxlIChOb2RlJ3MgZGVmYXVsdCBnaXZlcyB1cCBh
ZnRlciA1IG1pbnV0ZXMpLgogIHNlcnZlci5yZXF1ZXN0VGltZW91dCA9IDIgKiAzNjAwICogMTAw
MDsKCiAgY29uc3Qgd3NzID0gbmV3IFdlYlNvY2tldFNlcnZlcih7CiAgICBub1NlcnZlcjogdHJ1
ZSwKICAgIG1heFBheWxvYWQ6IGNvbmZpZy5tYXhNZXNzYWdlQnl0ZXMsCiAgICBwZXJNZXNzYWdl
RGVmbGF0ZTogZmFsc2UsIC8vIDIyLWJ5dGUgcGFja2V0czogY29tcHJlc3Npb24gb25seSBhZGRz
IGxhdGVuY3kKICB9KTsKCiAgc2VydmVyLm9uKCd1cGdyYWRlJywgKHJlcSwgc29ja2V0LCBoZWFk
KSA9PiB7CiAgICBjb25zdCB1cmwgPSBuZXcgVVJMKHJlcS51cmwsICdodHRwOi8vcmVsYXkuaW52
YWxpZCcpOwogICAgaWYgKHVybC5wYXRobmFtZSAhPT0gY29uZmlnLnBhdGggJiYgdXJsLnBhdGhu
YW1lICE9PSAnLycpIHsKICAgICAgc29ja2V0LmVuZCgnSFRUUC8xLjEgNDA0IE5vdCBGb3VuZFxy
XG5Db25uZWN0aW9uOiBjbG9zZVxyXG5cclxuJyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIC8v
IFJlcXVlc3RzIGFyZSB2YWxpZGF0ZWQgYWZ0ZXIgdGhlIHVwZ3JhZGUsIHNvIHRoZSBicm93c2Vy
IHJlY2VpdmVzIGEgY2xvc2UgY29kZSBhbmQgcmVhc29uCiAgICAvLyBpbnN0ZWFkIG9mIGFuIGFu
b255bW91cyBjb25uZWN0aW9uIGVycm9yLgogICAgd3NzLmhhbmRsZVVwZ3JhZGUocmVxLCBzb2Nr
ZXQsIGhlYWQsICh3cykgPT4gd3NzLmVtaXQoJ2Nvbm5lY3Rpb24nLCB3cywgcmVxLCB1cmwpKTsK
ICB9KTsKCiAgd3NzLm9uKCdjb25uZWN0aW9uJywgKHdzLCByZXEsIHVybCkgPT4gewogICAgd3Mu
aXNBbGl2ZSA9IHRydWU7CiAgICB3cy5vbigncG9uZycsICgpID0+IHsgd3MuaXNBbGl2ZSA9IHRy
dWU7IH0pOwogICAgd3Mub24oJ2Vycm9yJywgKCkgPT4ge30pOyAvLyBhICdjbG9zZScgZXZlbnQg
YWx3YXlzIGZvbGxvd3MKCiAgICBpZiAoY29uZmlnLmFsbG93ZWRPcmlnaW5zLmxlbmd0aCAmJiAh
Y29uZmlnLmFsbG93ZWRPcmlnaW5zLmluY2x1ZGVzKG5vcm1hbGl6ZU9yaWdpbihyZXEuaGVhZGVy
cy5vcmlnaW4pKSkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5vcmlnaW5EZW5p
ZWQpOwogICAgfQogICAgY29uc3Qgcm9sZSA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdyb2xlJyk7
CiAgICBjb25zdCBjb2RlID0gdXJsLnNlYXJjaFBhcmFtcy5nZXQoJ3Jvb20nKSB8fCAnJzsKICAg
IGNvbnN0IGhlcm9GaWdodGVyID0gdXJsLnNlYXJjaFBhcmFtcy5nZXQoJ2dhbWUnKSA9PT0gJ2hm
JzsgLy8gYSBIZXJvIEZpZ2h0ZXIgcm9vbSAoaGYuanMpCiAgICBpZiAoIWhlcm9GaWdodGVyICYm
ICgocm9sZSAhPT0gJ2hvc3QnICYmIHJvbGUgIT09ICdqb2luJykgfHwgIVJPT01fUEFUVEVSTi50
ZXN0KGNvZGUpKSkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5iYWRSZXF1ZXN0
KTsKICAgIH0KCiAgICBjb25zdCBhZGRyZXNzID0gY2xpZW50QWRkcmVzcyhyZXEpOwogICAgY29u
c3QgY291bnQgPSBjb25uZWN0aW9uc1BlcklwLmdldChhZGRyZXNzKSB8fCAwOwogICAgaWYgKGNv
bmZpZy5tYXhDb25uZWN0aW9uc1BlcklwICYmIGNvdW50ID49IGNvbmZpZy5tYXhDb25uZWN0aW9u
c1BlcklwKSB7CiAgICAgIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnRvb01hbnlDb25uZWN0
aW9ucyk7CiAgICB9CiAgICBjb25uZWN0aW9uc1BlcklwLnNldChhZGRyZXNzLCBjb3VudCArIDEp
OwogICAgd3Mub25jZSgnY2xvc2UnLCAoKSA9PiB7CiAgICAgIGNvbnN0IGxlZnQgPSAoY29ubmVj
dGlvbnNQZXJJcC5nZXQoYWRkcmVzcykgfHwgMSkgLSAxOwogICAgICBpZiAobGVmdCA+IDApIGNv
bm5lY3Rpb25zUGVySXAuc2V0KGFkZHJlc3MsIGxlZnQpOwogICAgICBlbHNlIGNvbm5lY3Rpb25z
UGVySXAuZGVsZXRlKGFkZHJlc3MpOwogICAgfSk7CiAgICB3cy5tZXNzYWdlQnVkZ2V0ID0gbmV3
IEJ1Y2tldChjb25maWcubWVzc2FnZXNQZXJTZWNvbmQsIGNvbmZpZy5tZXNzYWdlc1BlclNlY29u
ZCAqIDIpOwogICAgd3MuYnl0ZUJ1ZGdldCA9IG5ldyBCdWNrZXQoY29uZmlnLmJ5dGVzUGVyU2Vj
b25kLCBNYXRoLm1heChjb25maWcuYnl0ZXNQZXJTZWNvbmQsIGNvbmZpZy5tYXhNZXNzYWdlQnl0
ZXMpICogMik7CiAgICBpZiAoaGVyb0ZpZ2h0ZXIpIHJldHVybiBoZi5jb25uZWN0KHdzLCByZXEs
IHVybCk7CgogICAgY29uc3QgdmVyc2lvbiA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCd2Jyk7CiAg
ICBpZiAodmVyc2lvbiA9PT0gJzInKSByZXR1cm4gam9pbkdyb3VwKHdzLCByb2xlLCBjb2RlKTsK
ICAgIGlmICh2ZXJzaW9uICE9PSBudWxsICYmIHZlcnNpb24gIT09ICcxJykgcmV0dXJuIGNsb3Nl
V2l0aCh3cywgQ0xPU0UuYmFkUmVxdWVzdCk7CiAgICBpZiAoZ3JvdXBzLmhhcyhjb2RlKSkgcmV0
dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UubmV3ZXJSb29tKTsKCiAgICBsZXQgcm9vbSA9IHJvb21z
LmdldChjb2RlKTsKICAgIGlmICghcm9vbSkgewogICAgICBpZiAoY29uZmlnLm1heFJvb21zICYm
IHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSA+PSBjb25maWcubWF4Um9vbXMpIHJldHVybiBjbG9z
ZVdpdGgod3MsIENMT1NFLnNlcnZlckZ1bGwpOwogICAgICByb29tID0geyBjb2RlLCBob3N0OiBu
dWxsLCBqb2luOiBudWxsLCB0aW1lcjogbnVsbCB9OwogICAgICByb29tcy5zZXQoY29kZSwgcm9v
bSk7CiAgICB9CiAgICBpZiAocm9vbVtyb2xlXSkgcmV0dXJuIGNsb3NlV2l0aCh3cywgcm9sZSA9
PT0gJ2hvc3QnID8gQ0xPU0UuaG9zdFRha2VuIDogQ0xPU0UuZ3Vlc3RUYWtlbik7CgogICAgcm9v
bVtyb2xlXSA9IHdzOwogICAgd3Mucm9vbSA9IHJvb207CiAgICB3cy5yb2xlID0gcm9sZTsKICAg
IHdzLnBlZXIgPSBudWxsOwogICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSwgaXNCaW5hcnkpID0+
IG9uTWVzc2FnZSh3cywgZGF0YSwgaXNCaW5hcnkpKTsKICAgIHdzLm9uKCdjbG9zZScsICgpID0+
IG9uQ2xvc2Uod3MpKTsKCiAgICBjb25zdCBvdGhlciA9IHJvb21bcm9sZSA9PT0gJ2hvc3QnID8g
J2pvaW4nIDogJ2hvc3QnXTsKICAgIGlmIChvdGhlcikgewogICAgICBjbGVhclRpbWVvdXQocm9v
bS50aW1lcik7CiAgICAgIHJvb20udGltZXIgPSBudWxsOwogICAgICB3cy5wZWVyID0gb3RoZXI7
CiAgICAgIG90aGVyLnBlZXIgPSB3czsKICAgICAgLy8gQm90aCBwZWVycyBhcmUgbGlua2VkIGJl
Zm9yZSBlaXRoZXIgbGVhcm5zIGFib3V0IGl0LCBzbyBhbnkgZGF0YSB0aGF0IGZvbGxvd3MgaGFz
IGEgZGVzdGluYXRpb24uCiAgICAgIHNlbmRDb250cm9sKG90aGVyLCB7IHQ6ICdwYWlyZWQnIH0p
OwogICAgICBzZW5kQ29udHJvbCh3cywgeyB0OiAncGFpcmVkJyB9KTsKICAgICAgbG9nKGByb29t
ICR7Y29kZX06IHBhaXJlZGApOwogICAgfSBlbHNlIHsKICAgICAgc2VuZENvbnRyb2wod3MsIHsg
dDogJ3dhaXRpbmcnLCByb29tOiBjb2RlIH0pOwogICAgICByb29tLnRpbWVyID0gc2V0VGltZW91
dCgoKSA9PiB7CiAgICAgICAgaWYgKHJvb21bcm9sZV0gPT09IHdzICYmICF3cy5wZWVyKSBjbG9z
ZVdpdGgod3MsIENMT1NFLnRpbWVvdXQpOwogICAgICB9LCBjb25maWcucm9vbVdhaXRNcyk7CiAg
ICAgIGxvZyhgcm9vbSAke2NvZGV9OiAke3JvbGV9IHdhaXRpbmdgKTsKICAgIH0KICB9KTsKCiAg
ZnVuY3Rpb24gb25NZXNzYWdlKHdzLCBkYXRhLCBpc0JpbmFyeSkgewogICAgaWYgKCFpc0JpbmFy
eSkgcmV0dXJuOyAvLyBvbmx5IHRoZSByZWxheSBzcGVha3MgdGV4dDsgY2xpZW50cyBzZW5kIGdh
bWUgYnl0ZXMgYXMgYmluYXJ5IGZyYW1lcwogICAgaWYgKCF3cy5wZWVyKSByZXR1cm4gY2xvc2VX
aXRoKHdzLCBDTE9TRS5lYXJseURhdGEpOwogICAgaWYgKCF3cy5tZXNzYWdlQnVkZ2V0LnRha2Uo
MSkgfHwgIXdzLmJ5dGVCdWRnZXQudGFrZShkYXRhLmxlbmd0aCkpIHsKICAgICAgbG9nKGByb29t
ICR7d3Mucm9vbS5jb2RlfTogcmF0ZSBsaW1pdGApOwogICAgICBjbG9zZVdpdGgod3MucGVlciwg
Q0xPU0UucmF0ZUxpbWl0ZWQpOwogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5yYXRl
TGltaXRlZCk7CiAgICB9CiAgICBjb25zdCBwZWVyID0gd3MucGVlcjsKICAgIGlmIChwZWVyLnJl
YWR5U3RhdGUgIT09IFdlYlNvY2tldC5PUEVOKSByZXR1cm47CiAgICBpZiAocGVlci5idWZmZXJl
ZEFtb3VudCA+IGNvbmZpZy5tYXhCdWZmZXJlZEJ5dGVzKSB7CiAgICAgIGNsb3NlV2l0aCh3cywg
Q0xPU0Uuc2xvd1BlZXIpOwogICAgICByZXR1cm4gY2xvc2VXaXRoKHBlZXIsIENMT1NFLnNsb3dQ
ZWVyKTsKICAgIH0KICAgIGlmIChjb25maWcuZm9yd2FyZERlbGF5TXMgPiAwKSB7CiAgICAgIC8v
IFRpbWVycyB3aXRoIHRoZSBzYW1lIGRlbGF5IGZpcmUgaW4gdGhlIG9yZGVyIHRoZXkgd2VyZSBz
ZXQsIHNvIHRoZSBzdHJlYW0gc3RheXMgaW4gb3JkZXIuCiAgICAgIHNldFRpbWVvdXQoKCkgPT4g
eyBpZiAocGVlci5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQuT1BFTikgcGVlci5zZW5kKGRhdGEs
IHsgYmluYXJ5OiB0cnVlIH0pOyB9LCBjb25maWcuZm9yd2FyZERlbGF5TXMpOwogICAgICByZXR1
cm47CiAgICB9CiAgICBwZWVyLnNlbmQoZGF0YSwgeyBiaW5hcnk6IHRydWUgfSk7CiAgfQoKICBm
dW5jdGlvbiBvbkNsb3NlKHdzKSB7CiAgICBjb25zdCByb29tID0gd3Mucm9vbTsKICAgIGlmICgh
cm9vbSkgcmV0dXJuOwogICAgaWYgKHJvb21bd3Mucm9sZV0gPT09IHdzKSByb29tW3dzLnJvbGVd
ID0gbnVsbDsKICAgIGNvbnN0IHBlZXIgPSB3cy5wZWVyOwogICAgd3MucGVlciA9IG51bGw7CiAg
ICBpZiAocGVlcikgewogICAgICAvLyBBIGxvY2tzdGVwIG1hdGNoIGNhbm5vdCBjb250aW51ZSB3
aXRoIG9uZSBwbGF5ZXIsIHNvIHRoZSByb29tIGVuZHMgd2l0aCB0aGUgcGFpciBhbmQgaXRzCiAg
ICAgIC8vIGNvZGUgaXMgZnJlZSBhZ2FpbiBhdCBvbmNlICh0aGUgaG9zdCBjYW4gcHJlc3MgSG9z
dCBhZ2FpbiB3aXRoIHRoZSBzYW1lIGNvZGUpLgogICAgICBwZWVyLnBlZXIgPSBudWxsOwogICAg
ICByb29tLmhvc3QgPSByb29tLmpvaW4gPSBudWxsOwogICAgICBjbG9zZVdpdGgocGVlciwgQ0xP
U0UucGVlckxlZnQpOwogICAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBlbmRlZGApOwogICAg
fQogICAgaWYgKCFyb29tLmhvc3QgJiYgIXJvb20uam9pbikgewogICAgICBjbGVhclRpbWVvdXQo
cm9vbS50aW1lcik7CiAgICAgIGlmIChyb29tcy5nZXQocm9vbS5jb2RlKSA9PT0gcm9vbSkgcm9v
bXMuZGVsZXRlKHJvb20uY29kZSk7CiAgICB9CiAgfQoKICAvLyAtLS0tIFJvb21zIChwcm90b2Nv
bCAyKSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLQogIC8vCiAgLy8gVXAgdG8gY29uZmlnLnJvb21QbGF5ZXJzIGdh
bWVzIHNoYXJlIGEgcm9vbS4gRWFjaCBzYXlzIEhFTExPIHdpdGggaXRzIHByb2ZpbGUgKGVuZ2lu
ZSwgc2NyaXB0cywKICAvLyBtb2RzIGFuZCBnYW1lIGRhdGE6IHRoZSBmaXJzdCBIRUxMTyBzZXRz
IHRoZSByb29tJ3MsIGFuZCBhIGdhbWUgd2l0aCBhbm90aGVyIG9uZSBpcyB0dXJuZWQgYXdheSkK
ICAvLyBhbmQgaXRzIHBsYXllciBuYW1lczsgTE9CQlkgbGlzdHMgdGhlIHBsYXllcnMgdG8gZXZl
cnlvbmUuIFRoZSBob3N0IHNlbmRzIFNUQVJUIHdpdGggdGhlIHNldHVwCiAgLy8gZXZlcnkgZ2Ft
ZSBuZWVkcyAodGhlIHJhbmRvbSB0YWJsZSk7IFNUQVJURUQgZ2l2ZXMgZXZlcnkgZ2FtZSB0aGUg
ZmluYWwgbGlzdCBvZiBwbGF5ZXJzLCB3aG9zZQogIC8vIHBvc2l0aW9uIGlzIHRoZSBwbGF5ZXIn
cyBpbmRleCwgYW5kIG9uY2UgZXZlcnkgZ2FtZSBpcyBSRUFEWSAob3IgYWZ0ZXIgc3RhcnRHcmFj
ZU1zKSB0aGUgYmVhdAogIC8vIGJlZ2luczogZXZlcnkgdGlja01zLCBGUkFNRSB3aXRoIHRoZSBp
bnB1dCBvZiBlYWNoIHBsYXllci4gVGhlIGlucHV0cyBhIHBsYXllciBzZW50IHNpbmNlIHRoZQog
IC8vIGxhc3QgYmVhdCBhcmUgbWVyZ2VkIChPUjogYSBrZXkgaGVsZCBpbiBhbnkgb2YgdGhlbSBp
cyBoZWxkLCBzbyBhIHF1aWNrIHRhcCBpcyBuZXZlciBsb3N0KSwgYW5kCiAgLy8gdGhlIG5ld2Vz
dCBvZiB0aGVtIHN0YXlzIGhpcyBpbnB1dCBvbiB0aGUgZm9sbG93aW5nIGJlYXRzIHdoaWxlIG5v
IG5ld3MgY29tZXMsIHdpdGhvdXQgaXRzCiAgLy8gb25lLXNob3QgZXZlbnRzIChieXRlIDApOyBh
ZnRlciByZXBlYXRMaW1pdCBiZWF0cyB3aXRob3V0IG5ld3MgdGhlIHBsYXllciBjb3VudHMgYXMg
aGF2aW5nCiAgLy8gcmVsZWFzZWQgZXZlcnkga2V5LiBHYW1lcyBzZW5kIHRoZWlyIGlucHV0IGFz
IHNvb24gYXMgaXQgY2hhbmdlcy4gRXZlcnkgZ2FtZSBydW5zIGV4YWN0bHkgdGhlCiAgLy8gZnJh
bWVzIGl0IHJlY2VpdmVzLCBpbiBvcmRlciwgc28gYWxsIHN0YXkgaW4gc3RlcCB3aGF0ZXZlciB0
aGVpciBvd24gY29ubmVjdGlvbiBkb2VzOiBhIGRpc3RhbnQKICAvLyBwbGF5ZXIncyBrZXlzIHRh
a2UgZWZmZWN0IGEgbGl0dGxlIGxhdGVyIGFuZCBoZSBzZWVzIHRoZSBnYW1lIGEgbGl0dGxlIGxh
dGVyLCBidXQgbm9ib2R5IHdhaXRzCiAgLy8gZm9yIGhpbS4gQSBnYW1lIHRoYXQgY2Fubm90IGtl
ZXAgdXAgd2l0aCB0aGUgZnJhbWVzIGlzIGRyb3BwZWQsIGFuZCB0aGUgb3RoZXJzIGdvIG9uLgog
IC8vCiAgLy8gQmluYXJ5IG1lc3NhZ2VzLCBib3RoIHdheXM6IGtpbmQgKDEgYnl0ZSksIHBheWxv
YWQgbGVuZ3RoICgyIGJ5dGVzLCBsaXR0bGUgZW5kaWFuKSwgcGF5bG9hZC4KICAvLyBBIFdlYlNv
Y2tldCBtZXNzYWdlIG1heSBjYXJyeSBzZXZlcmFsLiBHYW1lIHRvIHJlbGF5OgogIC8vICAgSEVM
TE8gICAweDAxICBwcm9maWxlIGxlbmd0aCAoMSksIHByb2ZpbGUsIGluZm8gKG5hbWVzOyBhdCBt
b3N0IDY0IGJ5dGVzKQogIC8vICAgU1RBUlQgICAweDAyICBzZXR1cCAoYXQgbW9zdCA4IEtpQik6
IHRoZSBob3N0LCBvbmNlIHR3byBwbGF5ZXJzIG9yIG1vcmUgc2FpZCBoZWxsbwogIC8vICAgSU5Q
VVQgICAweDAzICBpbnB1dCAoYXQgbW9zdCAxNiBieXRlczsgYnl0ZSAwIGhvbGRzIG9uZS1zaG90
IGV2ZW50cyksIGFmdGVyIFNUQVJURUQKICAvLyAgIFJFQURZICAgMHgwNCAgZW1wdHk6IFNUQVJU
RUQgaXMgYXBwbGllZAogIC8vICAgQ0hFQ0sgICAweDA1ICBmcmFtZSAoNCksIGhhc2ggKDIpOiBw
YXNzZWQgb24gdG8gdGhlIG90aGVycywgd2hpY2ggY29tcGFyZSBpdCB3aXRoIHRoZWlyIG93bgog
IC8vIFJlbGF5IHRvIGdhbWU6CiAgLy8gICBXRUxDT01FIDB4ODEgIGlkICgxKSwgZmxhZ3MgKDE7
IGJpdCAwOiBob3N0KSwgbW9zdCBwbGF5ZXJzICgxKSwgYmVhdCBpbiBtcyAoMSksCiAgLy8gICAg
ICAgICAgICAgICAgIHJvb20gY29kZSBsZW5ndGggKDEpLCByb29tIGNvZGUKICAvLyAgIExPQkJZ
ICAgMHg4MiAgY291bnQgKDEpOyBwZXIgcGxheWVyOiBpZCAoMSksIGZsYWdzICgxKSwgaW5mbyBs
ZW5ndGggKDEpLCBpbmZvCiAgLy8gICBTVEFSVEVEIDB4ODMgIHRoZSBwbGF5ZXJzIGFzIGluIExP
QkJZLCB0aGVuIHNldHVwIGxlbmd0aCAoMiksIHNldHVwCiAgLy8gICBGUkFNRSAgIDB4ODQgIGZy
YW1lICg0KSwgY291bnQgKDEpLCBmcmVzaCBtYXNrICgxKSwgcHJlc2VudCBtYXNrICgxKTsKICAv
LyAgICAgICAgICAgICAgICAgcGVyIHBsYXllcjogaW5wdXQgbGVuZ3RoICgxKSwgaW5wdXQKICAv
LyAgIENIRUNLRUQgMHg4NSAgaW5kZXggKDEpLCBmcmFtZSAoNCksIGhhc2ggKDIpCiAgLy8gICBM
RUZUICAgIDB4ODYgIGluZGV4ICgxKTogdGhhdCBwbGF5ZXIgaXMgZ29uZTsgaGlzIGlucHV0IHN0
YXlzIGVtcHR5CiAgLy8gVGV4dCAoSlNPTikgbWVzc2FnZXMgYXJlIGZvciB0aGUgcGFnZSBhcm91
bmQgdGhlIGdhbWU6IHsidCI6IndlbGNvbWUiLCJ2IjoyLCJyb29tIjoi4oCmIiwiaG9zdCI6dHJ1
ZX0KICAvLyBhbmQgeyJ0Ijoicm9vbSIsInBsYXllcnMiOjMsInN0YXJ0ZWQiOmZhbHNlfS4KCiAg
ZnVuY3Rpb24gam9pbkdyb3VwKHdzLCByb2xlLCBjb2RlKSB7CiAgICBpZiAocm9vbXMuaGFzKGNv
ZGUpKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5jb2RlSW5Vc2UpOwogICAgbGV0IHJvb20g
PSBncm91cHMuZ2V0KGNvZGUpOwogICAgaWYgKCFyb29tKSB7CiAgICAgIGlmIChjb25maWcubWF4
Um9vbXMgJiYgcm9vbXMuc2l6ZSArIGdyb3Vwcy5zaXplID49IGNvbmZpZy5tYXhSb29tcykgcmV0
dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0Uuc2VydmVyRnVsbCk7CiAgICAgIHJvb20gPSB7CiAgICAg
ICAgY29kZSwgbWVtYmVyczogW10sIGhvc3Q6IG51bGwsIG5leHRJZDogMSwgcHJvZmlsZTogbnVs
bCwgc3RhcnRlZDogZmFsc2UsIG9yZGVyOiBbXSwgZnJhbWU6IDAsCiAgICAgICAgdGlja2luZzog
ZmFsc2UsIHRpY2tzOiAwLCB0aWNrU3RhcnQ6IDAsIGxvYmJ5VGltZXI6IG51bGwsIGdyYWNlVGlt
ZXI6IG51bGwsIHRpY2tUaW1lcjogbnVsbCwgZW5kZWQ6IGZhbHNlLAogICAgICB9OwogICAgICBn
cm91cHMuc2V0KGNvZGUsIHJvb20pOwogICAgICByb29tLmxvYmJ5VGltZXIgPSBzZXRUaW1lb3V0
KCgpID0+IGVuZEdyb3VwKHJvb20sIENMT1NFLm5vdFN0YXJ0ZWQpLCBjb25maWcubG9iYnlXYWl0
TXMpOwogICAgICBsb2coYHJvb20gJHtjb2RlfTogb3BlbmVkYCk7CiAgICB9CiAgICBpZiAocm9v
bS5zdGFydGVkKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5zdGFydGVkKTsKICAgIGlmIChy
b2xlID09PSAnaG9zdCcgJiYgcm9vbS5ob3N0KSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5o
b3N0VGFrZW4pOwogICAgaWYgKHJvb20ubWVtYmVycy5sZW5ndGggPj0gY29uZmlnLnJvb21QbGF5
ZXJzKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5yb29tRnVsbCk7CiAgICB3aGlsZSAocm9v
bS5tZW1iZXJzLnNvbWUoKG90aGVyKSA9PiBvdGhlci5pZCA9PT0gcm9vbS5uZXh0SWQpKSByb29t
Lm5leHRJZCA9IChyb29tLm5leHRJZCAlIDI1NSkgKyAxOwogICAgY29uc3QgbWVtYmVyID0gewog
ICAgICB3cywgcm9vbSwgaWQ6IHJvb20ubmV4dElkLCBob3N0OiByb2xlID09PSAnaG9zdCcsIGlu
Zm86IG51bGwsIHJlYWR5OiBmYWxzZSwKICAgICAgcXVldWU6IFtdLCBsYXN0OiBFTVBUWSwgcmVw
ZWF0czogMCwgcHJlc2VudDogdHJ1ZSwgaW5kZXg6IC0xLAogICAgfTsKICAgIHJvb20ubmV4dElk
ID0gKHJvb20ubmV4dElkICUgMjU1KSArIDE7CiAgICByb29tLm1lbWJlcnMucHVzaChtZW1iZXIp
OwogICAgaWYgKG1lbWJlci5ob3N0KSByb29tLmhvc3QgPSBtZW1iZXI7CiAgICB3cy5vbignbWVz
c2FnZScsIChkYXRhLCBpc0JpbmFyeSkgPT4gb25Hcm91cE1lc3NhZ2UobWVtYmVyLCBkYXRhLCBp
c0JpbmFyeSkpOwogICAgd3Mub24oJ2Nsb3NlJywgKCkgPT4gbGVhdmVHcm91cChtZW1iZXIpKTsK
ICAgIHNlbmRDb250cm9sKHdzLCB7IHQ6ICd3ZWxjb21lJywgdjogMiwgcm9vbTogY29kZSwgaG9z
dDogbWVtYmVyLmhvc3QgfSk7CiAgICBjb25zdCB3ZWxjb21lID0gQnVmZmVyLmFsbG9jKDUgKyBj
b2RlLmxlbmd0aCk7CiAgICB3ZWxjb21lWzBdID0gbWVtYmVyLmlkOwogICAgLy8gRmxhZ3M6IGJp
dCAwIHRoZSBob3N0OyBiaXRzIDEtMiB0aGUgYmVhdCdzIHRoaXJkcyBvZiBhIG1pbGxpc2Vjb25k
IGJleW9uZCB3ZWxjb21lWzNdLgogICAgY29uc3QgdGhpcmRzID0gTWF0aC5yb3VuZChjb25maWcu
dGlja01zICogMyk7CiAgICB3ZWxjb21lWzFdID0gKG1lbWJlci5ob3N0ID8gMSA6IDApIHwgKCh0
aGlyZHMgJSAzKSA8PCAxKTsKICAgIHdlbGNvbWVbMl0gPSBjb25maWcucm9vbVBsYXllcnM7CiAg
ICB3ZWxjb21lWzNdID0gTWF0aC5taW4oMjU1LCBNYXRoLmZsb29yKHRoaXJkcyAvIDMpKTsKICAg
IHdlbGNvbWVbNF0gPSBjb2RlLmxlbmd0aDsKICAgIHdlbGNvbWUud3JpdGUoY29kZSwgNSwgJ2xh
dGluMScpOwogICAgc2VuZEJpbmFyeSh3cywgcGFja2V0KEtJTkQud2VsY29tZSwgd2VsY29tZSkp
OwogICAgc2VuZExvYmJ5KHJvb20sIG1lbWJlcik7CiAgICBsb2coYHJvb20gJHtjb2RlfTogJHty
b2xlfSBhcnJpdmVkICgke3Jvb20ubWVtYmVycy5sZW5ndGh9IGluIHRoZSByb29tKWApOwogIH0K
CiAgLy8gVGhlIHBsYXllcnMgd2hvIHNhaWQgaGVsbG8sIHRoZSBob3N0IGZpcnN0LCB0aGVuIGlu
IHRoZSBvcmRlciB0aGV5IGNhbWUuCiAgZnVuY3Rpb24gbGlzdGVkKHJvb20pIHsKICAgIGNvbnN0
IGtub3duID0gcm9vbS5tZW1iZXJzLmZpbHRlcigobWVtYmVyKSA9PiBtZW1iZXIuaW5mbyk7CiAg
ICByZXR1cm4ga25vd24uZmlsdGVyKChtZW1iZXIpID0+IG1lbWJlci5ob3N0KS5jb25jYXQoa25v
d24uZmlsdGVyKChtZW1iZXIpID0+ICFtZW1iZXIuaG9zdCkpOwogIH0KCiAgZnVuY3Rpb24gZGVz
Y3JpYmVQbGF5ZXJzKGxpc3QpIHsKICAgIGNvbnN0IHBhcnRzID0gW0J1ZmZlci5mcm9tKFtsaXN0
Lmxlbmd0aF0pXTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIGxpc3QpIHBhcnRzLnB1c2goQnVm
ZmVyLmZyb20oW21lbWJlci5pZCwgbWVtYmVyLmhvc3QgPyAxIDogMCwgbWVtYmVyLmluZm8ubGVu
Z3RoXSksIG1lbWJlci5pbmZvKTsKICAgIHJldHVybiBCdWZmZXIuY29uY2F0KHBhcnRzKTsKICB9
CgogIGZ1bmN0aW9uIHNlbmRMb2JieShyb29tLCBvbmx5KSB7CiAgICBjb25zdCBsaXN0ID0gbGlz
dGVkKHJvb20pOwogICAgY29uc3QgbWVzc2FnZSA9IHBhY2tldChLSU5ELmxvYmJ5LCBkZXNjcmli
ZVBsYXllcnMobGlzdCkpOwogICAgZm9yIChjb25zdCBtZW1iZXIgb2Ygb25seSA/IFtvbmx5XSA6
IHJvb20ubWVtYmVycykgewogICAgICBzZW5kQmluYXJ5KG1lbWJlci53cywgbWVzc2FnZSk7CiAg
ICAgIHNlbmRDb250cm9sKG1lbWJlci53cywgeyB0OiAncm9vbScsIHBsYXllcnM6IGxpc3QubGVu
Z3RoLCBzdGFydGVkOiBmYWxzZSB9KTsKICAgIH0KICB9CgogIGZ1bmN0aW9uIG9uR3JvdXBNZXNz
YWdlKG1lbWJlciwgZGF0YSwgaXNCaW5hcnkpIHsKICAgIGNvbnN0IHsgd3MsIHJvb20gfSA9IG1l
bWJlcjsKICAgIGlmICghaXNCaW5hcnkgfHwgcm9vbS5lbmRlZCB8fCAhcm9vbS5tZW1iZXJzLmlu
Y2x1ZGVzKG1lbWJlcikpIHJldHVybjsKICAgIGlmICghd3MubWVzc2FnZUJ1ZGdldC50YWtlKDEp
IHx8ICF3cy5ieXRlQnVkZ2V0LnRha2UoZGF0YS5sZW5ndGgpKSB7CiAgICAgIGxvZyhgcm9vbSAk
e3Jvb20uY29kZX06IHJhdGUgbGltaXRgKTsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xP
U0UucmF0ZUxpbWl0ZWQpOwogICAgfQogICAgbGV0IGF0ID0gMDsKICAgIHdoaWxlIChhdCA8IGRh
dGEubGVuZ3RoKSB7CiAgICAgIGlmIChkYXRhLmxlbmd0aCAtIGF0IDwgMykgcmV0dXJuIGNsb3Nl
V2l0aCh3cywgQ0xPU0UucHJvdG9jb2wpOwogICAgICBjb25zdCBraW5kID0gZGF0YVthdF07CiAg
ICAgIGNvbnN0IGxlbmd0aCA9IGRhdGEucmVhZFVJbnQxNkxFKGF0ICsgMSk7CiAgICAgIGlmIChk
YXRhLmxlbmd0aCAtIGF0IC0gMyA8IGxlbmd0aCkgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0Uu
cHJvdG9jb2wpOwogICAgICBjb25zdCBwcm9ibGVtID0gaGFuZGxlR3JvdXBNZXNzYWdlKG1lbWJl
ciwga2luZCwgZGF0YS5zdWJhcnJheShhdCArIDMsIGF0ICsgMyArIGxlbmd0aCkpOwogICAgICBp
ZiAocHJvYmxlbSkgcmV0dXJuIGNsb3NlV2l0aCh3cywgcHJvYmxlbSk7CiAgICAgIGlmIChyb29t
LmVuZGVkIHx8ICFyb29tLm1lbWJlcnMuaW5jbHVkZXMobWVtYmVyKSkgcmV0dXJuOwogICAgICBh
dCArPSAzICsgbGVuZ3RoOwogICAgfQogIH0KCiAgLy8gUmV0dXJucyB0aGUgY2xvc2UgY29kZSBh
bmQgcmVhc29uIGZvciBhIG1lc3NhZ2UgdGhlIGdhbWUgc2hvdWxkIG5vdCBoYXZlIHNlbnQuCiAg
ZnVuY3Rpb24gaGFuZGxlR3JvdXBNZXNzYWdlKG1lbWJlciwga2luZCwgcGF5bG9hZCkgewogICAg
Y29uc3Qgcm9vbSA9IG1lbWJlci5yb29tOwogICAgaWYgKGtpbmQgPT09IEtJTkQuaGVsbG8pIHsK
ICAgICAgaWYgKG1lbWJlci5pbmZvIHx8IHJvb20uc3RhcnRlZCB8fCBwYXlsb2FkLmxlbmd0aCA8
IDEpIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAgY29uc3QgbGVuZ3RoID0gcGF5bG9hZFsw
XTsKICAgICAgaWYgKCFsZW5ndGggfHwgbGVuZ3RoID4gUk9PTV9MSU1JVFMucHJvZmlsZSB8fCBw
YXlsb2FkLmxlbmd0aCA8IDEgKyBsZW5ndGgpIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAg
Y29uc3QgcHJvZmlsZSA9IEJ1ZmZlci5mcm9tKHBheWxvYWQuc3ViYXJyYXkoMSwgMSArIGxlbmd0
aCkpOwogICAgICBjb25zdCBpbmZvID0gQnVmZmVyLmZyb20ocGF5bG9hZC5zdWJhcnJheSgxICsg
bGVuZ3RoKSk7CiAgICAgIGlmIChpbmZvLmxlbmd0aCA+IFJPT01fTElNSVRTLmluZm8pIHJldHVy
biBDTE9TRS5wcm90b2NvbDsKICAgICAgaWYgKHJvb20ucHJvZmlsZSAmJiAhcm9vbS5wcm9maWxl
LmVxdWFscyhwcm9maWxlKSkgcmV0dXJuIENMT1NFLm1pc21hdGNoOwogICAgICByb29tLnByb2Zp
bGUgPSByb29tLnByb2ZpbGUgfHwgcHJvZmlsZTsKICAgICAgbWVtYmVyLmluZm8gPSBpbmZvOwog
ICAgICBzZW5kTG9iYnkocm9vbSk7CiAgICAgIHJldHVybiBudWxsOwogICAgfQogICAgaWYgKGtp
bmQgPT09IEtJTkQuc3RhcnQpIHsKICAgICAgaWYgKCFtZW1iZXIuaG9zdCB8fCAhbWVtYmVyLmlu
Zm8gfHwgcm9vbS5zdGFydGVkIHx8IHBheWxvYWQubGVuZ3RoID4gUk9PTV9MSU1JVFMuc2V0dXAp
IHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAgLy8gU29tZWJvZHkgbGVmdCBqdXN0IGJlZm9y
ZTogdGhlIGhvc3Qgc2VlcyB0aGUgbGlzdCBhZ2FpbiBpbnN0ZWFkLgogICAgICBpZiAobGlzdGVk
KHJvb20pLmxlbmd0aCA8IDIpIHNlbmRMb2JieShyb29tLCBtZW1iZXIpOwogICAgICBlbHNlIHN0
YXJ0R3JvdXAocm9vbSwgQnVmZmVyLmZyb20ocGF5bG9hZCkpOwogICAgICByZXR1cm4gbnVsbDsK
ICAgIH0KICAgIGlmIChraW5kID09PSBLSU5ELmlucHV0KSB7CiAgICAgIGlmICghcm9vbS5zdGFy
dGVkIHx8IG1lbWJlci5pbmRleCA8IDAgfHwgcGF5bG9hZC5sZW5ndGggPiBST09NX0xJTUlUUy5p
bnB1dCkgcmV0dXJuIENMT1NFLnByb3RvY29sOwogICAgICBtZW1iZXIucXVldWUucHVzaChCdWZm
ZXIuZnJvbShwYXlsb2FkKSk7CiAgICAgIC8vIEZhciBtb3JlIHRoYW4gYSBiZWF0J3Mgd29ydGgg
KHRoZSByYXRlIGxpbWl0IGFsbG93cyBidXJzdHMpOiBmb2xkIHRoZW0sIGtlZXBpbmcgdGhlIG5l
d2VzdCBsYXN0LgogICAgICBpZiAobWVtYmVyLnF1ZXVlLmxlbmd0aCA+IFJPT01fTElNSVRTLnF1
ZXVlKSBtZW1iZXIucXVldWUgPSBbbWVyZ2VJbnB1dHMobWVtYmVyLnF1ZXVlLnNsaWNlKDAsIC0x
KSksIG1lbWJlci5xdWV1ZS5hdCgtMSldOwogICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAgIGlm
IChraW5kID09PSBLSU5ELnJlYWR5KSB7CiAgICAgIGlmICghcm9vbS5zdGFydGVkIHx8IG1lbWJl
ci5pbmRleCA8IDAgfHwgcGF5bG9hZC5sZW5ndGgpIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAg
ICAgbWVtYmVyLnJlYWR5ID0gdHJ1ZTsKICAgICAgaWYgKHJvb20ub3JkZXIuZXZlcnkoKG90aGVy
KSA9PiBvdGhlci5yZWFkeSB8fCAhb3RoZXIucHJlc2VudCkpIHN0YXJ0QmVhdChyb29tKTsKICAg
ICAgcmV0dXJuIG51bGw7CiAgICB9CiAgICBpZiAoa2luZCA9PT0gS0lORC5jaGVjaykgewogICAg
ICBpZiAoIXJvb20uc3RhcnRlZCB8fCBtZW1iZXIuaW5kZXggPCAwIHx8IHBheWxvYWQubGVuZ3Ro
ICE9PSA2KSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNr
ZXQoS0lORC5jaGVja2VkLCBCdWZmZXIuY29uY2F0KFtCdWZmZXIuZnJvbShbbWVtYmVyLmluZGV4
XSksIHBheWxvYWRdKSk7CiAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5vcmRlcikgaWYg
KG90aGVyICE9PSBtZW1iZXIgJiYgb3RoZXIucHJlc2VudCkgc2VuZEJpbmFyeShvdGhlci53cywg
bWVzc2FnZSk7CiAgICAgIHJldHVybiBudWxsOwogICAgfQogICAgcmV0dXJuIENMT1NFLnByb3Rv
Y29sOwogIH0KCiAgZnVuY3Rpb24gc3RhcnRHcm91cChyb29tLCBzZXR1cCkgewogICAgY2xlYXJU
aW1lb3V0KHJvb20ubG9iYnlUaW1lcik7CiAgICByb29tLnN0YXJ0ZWQgPSB0cnVlOwogICAgcm9v
bS5vcmRlciA9IGxpc3RlZChyb29tKTsKICAgIHJvb20ub3JkZXIuZm9yRWFjaCgobWVtYmVyLCBp
bmRleCkgPT4geyBtZW1iZXIuaW5kZXggPSBpbmRleDsgfSk7CiAgICAvLyBBIGdhbWUgc3RpbGwg
Y29ubmVjdGluZyBoYXMgbWlzc2VkIHRoZSBzdGFydC4KICAgIGZvciAoY29uc3QgbWVtYmVyIG9m
IHJvb20ubWVtYmVycykgaWYgKCFtZW1iZXIuaW5mbykgY2xvc2VXaXRoKG1lbWJlci53cywgQ0xP
U0Uuc3RhcnRlZCk7CiAgICBjb25zdCBsZW5ndGggPSBCdWZmZXIuYWxsb2MoMik7CiAgICBsZW5n
dGgud3JpdGVVSW50MTZMRShzZXR1cC5sZW5ndGgsIDApOwogICAgY29uc3QgbWVzc2FnZSA9IHBh
Y2tldChLSU5ELnN0YXJ0ZWQsIEJ1ZmZlci5jb25jYXQoW2Rlc2NyaWJlUGxheWVycyhyb29tLm9y
ZGVyKSwgbGVuZ3RoLCBzZXR1cF0pKTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ub3Jk
ZXIpIHsKICAgICAgc2VuZEJpbmFyeShtZW1iZXIud3MsIG1lc3NhZ2UpOwogICAgICBzZW5kQ29u
dHJvbChtZW1iZXIud3MsIHsgdDogJ3Jvb20nLCBwbGF5ZXJzOiByb29tLm9yZGVyLmxlbmd0aCwg
c3RhcnRlZDogdHJ1ZSB9KTsKICAgIH0KICAgIHJvb20uZ3JhY2VUaW1lciA9IHNldFRpbWVvdXQo
KCkgPT4gc3RhcnRCZWF0KHJvb20pLCBjb25maWcuc3RhcnRHcmFjZU1zKTsKICAgIGxvZyhgcm9v
bSAke3Jvb20uY29kZX06IHN0YXJ0ZWQgd2l0aCAke3Jvb20ub3JkZXIubGVuZ3RofSBwbGF5ZXJz
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
ICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChtZW1iZXIuaW5kZXggPj0gMCAmJiBtZW1i
ZXIucHJlc2VudCkgewogICAgICBtZW1iZXIucHJlc2VudCA9IGZhbHNlOwogICAgICBtZW1iZXIu
cXVldWUgPSBbXTsKICAgICAgY29uc3QgbWVzc2FnZSA9IHBhY2tldChLSU5ELmxlZnQsIEJ1ZmZl
ci5mcm9tKFttZW1iZXIuaW5kZXhdKSk7CiAgICAgIGNvbnN0IHBsYXllcnMgPSByb29tLm9yZGVy
LmZpbHRlcigob3RoZXIpID0+IG90aGVyLnByZXNlbnQpLmxlbmd0aDsKICAgICAgZm9yIChjb25z
dCBvdGhlciBvZiByb29tLm9yZGVyKSB7CiAgICAgICAgaWYgKCFvdGhlci5wcmVzZW50KSBjb250
aW51ZTsKICAgICAgICBzZW5kQmluYXJ5KG90aGVyLndzLCBtZXNzYWdlKTsKICAgICAgICBzZW5k
Q29udHJvbChvdGhlci53cywgeyB0OiAncm9vbScsIHBsYXllcnMsIHN0YXJ0ZWQ6IHRydWUgfSk7
CiAgICAgIH0KICAgICAgbG9nKGByb29tICR7cm9vbS5jb2RlfTogcGxheWVyICR7bWVtYmVyLmlu
ZGV4ICsgMX0gbGVmdGApOwogICAgfQogICAgaWYgKCFyb29tLm9yZGVyLnNvbWUoKG90aGVyKSA9
PiBvdGhlci5wcmVzZW50KSkgZW5kR3JvdXAocm9vbSk7CiAgICBlbHNlIGlmIChyb29tLm9yZGVy
LmV2ZXJ5KChvdGhlcikgPT4gb3RoZXIucmVhZHkgfHwgIW90aGVyLnByZXNlbnQpKSBzdGFydEJl
YXQocm9vbSk7CiAgfQoKICBmdW5jdGlvbiBlbmRHcm91cChyb29tLCByZWFzb24pIHsKICAgIGlm
IChyb29tLmVuZGVkKSByZXR1cm47CiAgICByb29tLmVuZGVkID0gdHJ1ZTsKICAgIGNsZWFyVGlt
ZW91dChyb29tLmxvYmJ5VGltZXIpOwogICAgY2xlYXJUaW1lb3V0KHJvb20uZ3JhY2VUaW1lcik7
CiAgICBjbGVhclRpbWVvdXQocm9vbS50aWNrVGltZXIpOwogICAgaWYgKGdyb3Vwcy5nZXQocm9v
bS5jb2RlKSA9PT0gcm9vbSkgZ3JvdXBzLmRlbGV0ZShyb29tLmNvZGUpOwogICAgZm9yIChjb25z
dCBtZW1iZXIgb2Ygcm9vbS5tZW1iZXJzLnNsaWNlKCkpIGNsb3NlV2l0aChtZW1iZXIud3MsIHJl
YXNvbiB8fCBDTE9TRS5zaHV0ZG93bik7CiAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBlbmRl
ZGApOwogIH0KCiAgLy8gU2l6ZSBvZiB0aGUgaW5zdGFsbGVyIGZpbGUsIG9yIDAgd2hlbiBub25l
IGlzIGNvbmZpZ3VyZWQgb3IgcmVhZGFibGUuCiAgZnVuY3Rpb24gaW5zdGFsbGVyU2l6ZSgpIHsK
ICAgIGlmICghY29uZmlnLmluc3RhbGxlckZpbGUpIHJldHVybiAwOwogICAgdHJ5IHsKICAgICAg
Y29uc3Qgc3RhdCA9IGZzLnN0YXRTeW5jKGNvbmZpZy5pbnN0YWxsZXJGaWxlKTsKICAgICAgcmV0
dXJuIHN0YXQuaXNGaWxlKCkgPyBzdGF0LnNpemUgOiAwOwogICAgfSBjYXRjaCB7CiAgICAgIHJl
dHVybiAwOwogICAgfQogIH0KCiAgZnVuY3Rpb24gc2VydmVJbnN0YWxsZXIocmVxLCByZXMpIHsK
ICAgIGNvbnN0IGhlYWRlcnMgPSB7ICdjYWNoZS1jb250cm9sJzogJ3B1YmxpYywgbWF4LWFnZT04
NjQwMCcsICd4LWNvbnRlbnQtdHlwZS1vcHRpb25zJzogJ25vc25pZmYnLCAuLi5hbGxvd09yaWdp
bihyZXEpIH07CiAgICBpZiAocmVxLm1ldGhvZCAhPT0gJ0dFVCcgJiYgcmVxLm1ldGhvZCAhPT0g
J0hFQUQnKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoNDA1LCB7IC4uLmhlYWRlcnMsIGFsbG93OiAn
R0VULCBIRUFEJyB9KTsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBj
b25zdCBzaXplID0gaW5zdGFsbGVyU2l6ZSgpOwogICAgaWYgKCFzaXplKSB7CiAgICAgIHJlcy53
cml0ZUhlYWQoNDA0LCBoZWFkZXJzKTsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm47CiAg
ICB9CiAgICBpZiAocmVxLm1ldGhvZCA9PT0gJ0dFVCcgJiYgY29uZmlnLmluc3RhbGxlckRvd25s
b2Fkc1BlckhvdXIpIHsKICAgICAgY29uc3QgYWRkcmVzcyA9IGNsaWVudEFkZHJlc3MocmVxKTsK
ICAgICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgICAgbGV0IGVudHJ5ID0gaW5zdGFsbGVy
RG93bmxvYWRzLmdldChhZGRyZXNzKTsKICAgICAgaWYgKCFlbnRyeSB8fCBlbnRyeS51bnRpbCA8
PSBub3cpIHsKICAgICAgICBlbnRyeSA9IHsgY291bnQ6IDAsIHVudGlsOiBub3cgKyAzNjAwMDAw
IH07CiAgICAgICAgaW5zdGFsbGVyRG93bmxvYWRzLnNldChhZGRyZXNzLCBlbnRyeSk7CiAgICAg
IH0KICAgICAgaWYgKGVudHJ5LmNvdW50ID49IGNvbmZpZy5pbnN0YWxsZXJEb3dubG9hZHNQZXJI
b3VyKSB7CiAgICAgICAgcmVzLndyaXRlSGVhZCg0MjksIHsgLi4uaGVhZGVycywgJ3JldHJ5LWFm
dGVyJzogU3RyaW5nKE1hdGguY2VpbCgoZW50cnkudW50aWwgLSBub3cpIC8gMTAwMCkpIH0pOwog
ICAgICAgIHJlcy5lbmQoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgZW50cnkuY291
bnQgKz0gMTsKICAgIH0KICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7IC4uLmhlYWRlcnMsICdjb250
ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vb2N0ZXQtc3RyZWFtJywgJ2NvbnRlbnQtbGVuZ3RoJzog
U3RyaW5nKHNpemUpIH0pOwogICAgaWYgKHJlcS5tZXRob2QgPT09ICdIRUFEJykgewogICAgICBy
ZXMuZW5kKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHN0cmVhbSA9IGZzLmNyZWF0
ZVJlYWRTdHJlYW0oY29uZmlnLmluc3RhbGxlckZpbGUpOwogICAgc3RyZWFtLm9uKCdlcnJvcics
ICgpID0+IHJlcy5kZXN0cm95KCkpOwogICAgc3RyZWFtLnBpcGUocmVzKTsKICB9CgogIC8vIENy
b3NzLW9yaWdpbjogdGhlIGdhbWUgcGFnZSBsaXZlcyBlbHNld2hlcmUgKEdpdEh1YiBQYWdlcyku
IFdpdGggYW4gYWxsb3ctbGlzdCwgb25seSBpdHMgcGFnZXMgbWF5IHJlYWQuCiAgZnVuY3Rpb24g
YWxsb3dPcmlnaW4ocmVxKSB7CiAgICBpZiAoIWNvbmZpZy5hbGxvd2VkT3JpZ2lucy5sZW5ndGgp
IHJldHVybiB7ICdhY2Nlc3MtY29udHJvbC1hbGxvdy1vcmlnaW4nOiAnKicgfTsKICAgIGNvbnN0
IG9yaWdpbiA9IG5vcm1hbGl6ZU9yaWdpbihyZXEuaGVhZGVycy5vcmlnaW4pOwogICAgaWYgKG9y
aWdpbiAmJiBjb25maWcuYWxsb3dlZE9yaWdpbnMuaW5jbHVkZXMob3JpZ2luKSkgcmV0dXJuIHsg
J2FjY2Vzcy1jb250cm9sLWFsbG93LW9yaWdpbic6IHJlcS5oZWFkZXJzLm9yaWdpbiwgdmFyeTog
J09yaWdpbicgfTsKICAgIHJldHVybiB7fTsKICB9CgogIGZ1bmN0aW9uIGNsaWVudEFkZHJlc3Mo
cmVxKSB7CiAgICBpZiAoY29uZmlnLnRydXN0UHJveHkpIHsKICAgICAgLy8gVGhlIGxhc3QgZW50
cnkgaXMgdGhlIG9uZSBvdXIgb3duIHByb3h5IGFkZGVkIChBcGFjaGUgYXBwZW5kcywgQ2FkZHkg
cmVwbGFjZXMpOyBlbnRyaWVzIGJlZm9yZQogICAgICAvLyBpdCBjb21lIGZyb20gdGhlIGNsaWVu
dCBhbmQgY291bGQgYmUgbWFkZSB1cCB0byBzbGlwIHBhc3QgdGhlIHBlci1hZGRyZXNzIGxpbWl0
cy4KICAgICAgY29uc3QgZm9yd2FyZGVkID0gU3RyaW5nKHJlcS5oZWFkZXJzWyd4LWZvcndhcmRl
ZC1mb3InXSB8fCAnJykuc3BsaXQoJywnKS5tYXAoKHBhcnQpID0+IHBhcnQudHJpbSgpKS5maWx0
ZXIoQm9vbGVhbik7CiAgICAgIGlmIChmb3J3YXJkZWQubGVuZ3RoKSByZXR1cm4gZm9yd2FyZGVk
W2ZvcndhcmRlZC5sZW5ndGggLSAxXTsKICAgIH0KICAgIHJldHVybiByZXEuc29ja2V0LnJlbW90
ZUFkZHJlc3MgfHwgJ3Vua25vd24nOwogIH0KCiAgY29uc3QgaGVhcnRiZWF0ID0gc2V0SW50ZXJ2
YWwoKCkgPT4gewogICAgZm9yIChjb25zdCB3cyBvZiB3c3MuY2xpZW50cykgewogICAgICBpZiAo
IXdzLmlzQWxpdmUpIHsgd3MudGVybWluYXRlKCk7IGNvbnRpbnVlOyB9CiAgICAgIHdzLmlzQWxp
dmUgPSBmYWxzZTsKICAgICAgdHJ5IHsgd3MucGluZygpOyB9IGNhdGNoIHsgLyogY2xvc2luZyAq
LyB9CiAgICB9CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgZm9yIChjb25zdCBbYWRk
cmVzcywgZW50cnldIG9mIGluc3RhbGxlckRvd25sb2FkcykgaWYgKGVudHJ5LnVudGlsIDw9IG5v
dykgaW5zdGFsbGVyRG93bmxvYWRzLmRlbGV0ZShhZGRyZXNzKTsKICAgIHBhY2tzLmNsZWFudXAo
KTsKICB9LCBjb25maWcucGluZ0ludGVydmFsTXMpOwogIGhlYXJ0YmVhdC51bnJlZigpOwoKICBy
ZXR1cm4gewogICAgY29uZmlnLAogICAgc2VydmVyLAogICAgd3NzLAogICAgcm9vbXMsCiAgICBs
aXN0ZW4ocG9ydCA9IGNvbmZpZy5wb3J0LCBob3N0ID0gY29uZmlnLmhvc3QpIHsKICAgICAgcmV0
dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlLCByZWplY3QpID0+IHsKICAgICAgICBzZXJ2ZXIub25j
ZSgnZXJyb3InLCByZWplY3QpOwogICAgICAgIHNlcnZlci5saXN0ZW4ocG9ydCwgaG9zdCwgKCkg
PT4gewogICAgICAgICAgc2VydmVyLm9mZignZXJyb3InLCByZWplY3QpOwogICAgICAgICAgcmVz
b2x2ZShzZXJ2ZXIuYWRkcmVzcygpKTsKICAgICAgICB9KTsKICAgICAgfSk7CiAgICB9LAogICAg
Z3JvdXBzLAogICAgaGYsCiAgICBjbG9zZSgpIHsKICAgICAgY2xlYXJJbnRlcnZhbChoZWFydGJl
YXQpOwogICAgICBoZi5jbG9zZSgpOwogICAgICBmb3IgKGNvbnN0IHJvb20gb2Ygcm9vbXMudmFs
dWVzKCkpIGNsZWFyVGltZW91dChyb29tLnRpbWVyKTsKICAgICAgZm9yIChjb25zdCByb29tIG9m
IFsuLi5ncm91cHMudmFsdWVzKCldKSBlbmRHcm91cChyb29tLCBDTE9TRS5zaHV0ZG93bik7CiAg
ICAgIGZvciAoY29uc3Qgd3Mgb2Ygd3NzLmNsaWVudHMpIGNsb3NlV2l0aCh3cywgQ0xPU0Uuc2h1
dGRvd24pOwogICAgICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUpID0+IHsKICAgICAgICB3
c3MuY2xvc2UoKCkgPT4gc2VydmVyLmNsb3NlKCgpID0+IHJlc29sdmUoKSkpOwogICAgICAgIHNl
dFRpbWVvdXQoKCkgPT4geyBmb3IgKGNvbnN0IHdzIG9mIHdzcy5jbGllbnRzKSB3cy50ZXJtaW5h
dGUoKTsgfSwgMTAwMCkudW5yZWYoKTsKICAgICAgfSk7CiAgICB9LAogIH07Cn0KCmZ1bmN0aW9u
IHNlbmRDb250cm9sKHdzLCBtZXNzYWdlKSB7CiAgaWYgKHdzLnJlYWR5U3RhdGUgPT09IFdlYlNv
Y2tldC5PUEVOKSB3cy5zZW5kKEpTT04uc3RyaW5naWZ5KG1lc3NhZ2UpKTsKfQoKZnVuY3Rpb24g
c2VuZEJpbmFyeSh3cywgZGF0YSkgewogIGlmICh3cy5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQu
T1BFTikgd3Muc2VuZChkYXRhLCB7IGJpbmFyeTogdHJ1ZSB9KTsKfQoKY29uc3QgRU1QVFkgPSBC
dWZmZXIuYWxsb2MoMCk7CgovLyBBIHByb3RvY29sIDIgbWVzc2FnZToga2luZCwgcGF5bG9hZCBs
ZW5ndGggKDIgYnl0ZXMsIGxpdHRsZSBlbmRpYW4pLCBwYXlsb2FkLgpmdW5jdGlvbiBwYWNrZXQo
a2luZCwgcGF5bG9hZCkgewogIGNvbnN0IG1lc3NhZ2UgPSBCdWZmZXIuYWxsb2NVbnNhZmUoMyAr
IHBheWxvYWQubGVuZ3RoKTsKICBtZXNzYWdlWzBdID0ga2luZDsKICBtZXNzYWdlLndyaXRlVUlu
dDE2TEUocGF5bG9hZC5sZW5ndGgsIDEpOwogIHBheWxvYWQuY29weShtZXNzYWdlLCAzKTsKICBy
ZXR1cm4gbWVzc2FnZTsKfQoKLy8gSW5wdXRzIGFyZSBiaXQgc2V0cyAoa2V5cyBoZWxkLCBldmVu
dHMpOiBtZXJnZWQsIGV2ZXJ5IGJpdCBzZXQgaW4gYW55IG9mIHRoZW0gaXMgc2V0LgpmdW5jdGlv
biBtZXJnZUlucHV0cyhpbnB1dHMpIHsKICBjb25zdCBtZXJnZWQgPSBCdWZmZXIuYWxsb2MoTWF0
aC5tYXgoMCwgLi4uaW5wdXRzLm1hcCgoaW5wdXQpID0+IGlucHV0Lmxlbmd0aCkpKTsKICBmb3Ig
KGNvbnN0IGlucHV0IG9mIGlucHV0cykgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IGlucHV0
Lmxlbmd0aDsgaW5kZXggKz0gMSkgbWVyZ2VkW2luZGV4XSB8PSBpbnB1dFtpbmRleF07CiAgcmV0
dXJuIG1lcmdlZDsKfQoKLy8gQSByZXBlYXRlZCBpbnB1dCBrZWVwcyBpdHMgaGVsZCBrZXlzIGJ1
dCBub3QgaXRzIG9uZS1zaG90IGV2ZW50cyAoYnl0ZSAwKS4KZnVuY3Rpb24gd2l0aG91dEV2ZW50
cyhpbnB1dCkgewogIGlmICghaW5wdXQubGVuZ3RoIHx8IGlucHV0WzBdID09PSAwKSByZXR1cm4g
aW5wdXQ7CiAgY29uc3QgY29weSA9IEJ1ZmZlci5mcm9tKGlucHV0KTsKICBjb3B5WzBdID0gMDsK
ICByZXR1cm4gY29weTsKfQoKZnVuY3Rpb24gY2xvc2VXaXRoKHdzLCBbY29kZSwgcmVhc29uXSkg
ewogIGlmICh3cy5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQuT1BFTiB8fCB3cy5yZWFkeVN0YXRl
ID09PSBXZWJTb2NrZXQuQ09OTkVDVElORykgewogICAgd3MuY2xvc2UoY29kZSwgcmVhc29uKTsK
ICAgIC8vIERvIG5vdCB3YWl0IGZvcmV2ZXIgZm9yIGEgY2xpZW50IHRoYXQgbmV2ZXIgYW5zd2Vy
cyB0aGUgY2xvc2UgaGFuZHNoYWtlLgogICAgc2V0VGltZW91dCgoKSA9PiB7IGlmICh3cy5yZWFk
eVN0YXRlICE9PSBXZWJTb2NrZXQuQ0xPU0VEKSB3cy50ZXJtaW5hdGUoKTsgfSwgMzAwMCkudW5y
ZWYoKTsKICB9Cn0KCm1vZHVsZS5leHBvcnRzID0geyBjcmVhdGVSZWxheSwgcmVhZENvbmZpZywg
Q0xPU0UsIFJPT01fUEFUVEVSTiwgS0lORCwgUk9PTV9MSU1JVFMsIHBhY2tldCwgbWVyZ2VJbnB1
dHMgfTsKCmlmIChyZXF1aXJlLm1haW4gPT09IG1vZHVsZSkgewogIGNvbnN0IHJlbGF5ID0gY3Jl
YXRlUmVsYXkocmVhZENvbmZpZygpKTsKICByZWxheS5saXN0ZW4oKS50aGVuKChhZGRyZXNzKSA9
PiB7CiAgICBjb25zdCB3aGVyZSA9IHR5cGVvZiBhZGRyZXNzID09PSAnc3RyaW5nJyA/IGFkZHJl
c3MgOiBgJHthZGRyZXNzLmFkZHJlc3N9OiR7YWRkcmVzcy5wb3J0fWA7CiAgICBjb25zb2xlLmxv
ZyhgT3BlbkxGMiByZWxheSBsaXN0ZW5pbmcgb24gJHt3aGVyZX0sIFdlYlNvY2tldCBwYXRoICR7
cmVsYXkuY29uZmlnLnBhdGh9YCk7CiAgICBpZiAoIXJlbGF5LmNvbmZpZy5hbGxvd2VkT3JpZ2lu
cy5sZW5ndGgpIHsKICAgICAgY29uc29sZS5sb2coJ0FMTE9XRURfT1JJR0lOUyBpcyBlbXB0eTog
YW55IHdlYnNpdGUgbWF5IHVzZSB0aGlzIHJlbGF5LiBTZXQgaXQgdG8geW91ciBnYW1lIHBhZ2Ug
b3JpZ2luLicpOwogICAgfQogIH0pLmNhdGNoKChlcnJvcikgPT4gewogICAgY29uc29sZS5lcnJv
cihlcnJvci5tZXNzYWdlKTsKICAgIHByb2Nlc3MuZXhpdCgxKTsKICB9KTsKICBjb25zdCBzdG9w
ID0gKCkgPT4gcmVsYXkuY2xvc2UoKS50aGVuKCgpID0+IHByb2Nlc3MuZXhpdCgwKSk7CiAgcHJv
Y2Vzcy5vbignU0lHSU5UJywgc3RvcCk7CiAgcHJvY2Vzcy5vbignU0lHVEVSTScsIHN0b3ApOwp9
Cg==
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
YXMgdGV4dCAoWC1BZG1pbi1LZXkpCid1c2Ugc3RyaWN0JzsKCmNvbnN0IGNyeXB0byA9IHJlcXVp
cmUoJ25vZGU6Y3J5cHRvJyk7CmNvbnN0IGZzID0gcmVxdWlyZSgnbm9kZTpmcycpOwpjb25zdCBm
c3AgPSByZXF1aXJlKCdub2RlOmZzL3Byb21pc2VzJyk7CmNvbnN0IHBhdGggPSByZXF1aXJlKCdu
b2RlOnBhdGgnKTsKY29uc3QgeyBwaXBlbGluZSB9ID0gcmVxdWlyZSgnbm9kZTpzdHJlYW0vcHJv
bWlzZXMnKTsKY29uc3QgeyBUcmFuc2Zvcm0gfSA9IHJlcXVpcmUoJ25vZGU6c3RyZWFtJyk7CmNv
bnN0IHpsaWIgPSByZXF1aXJlKCdub2RlOnpsaWInKTsKCmNvbnN0IFBBQ0tfSUQgPSAvXlthLXow
LTldW2EtejAtOS1dezAsMzl9JC87CmNvbnN0IE1JQiA9IDEwMjQgKiAxMDI0OwovLyBGaWxlcyBi
ZXNpZGUgdGhlIGdhbWUgdGhhdCBubyBnYW1lIHJlYWRzOiBub3RlcywgYXJjaGl2ZXMsIHZpZGVv
cywgc2hvcnRjdXRzLgpjb25zdCBOT1RFUyA9IC9cLih0eHR8bmZvfGRvY3xkb2N4fHBkZnxydGZ8
aHRtfGh0bWx8dXJsfGxua3xzd2Z8cmFyfHppcHw3enxsZnJ8bXA0fGF2aXx3bXZ8anBnfGpwZWd8
Z2lmKSQvaTsKCmNsYXNzIFBhY2tFcnJvciBleHRlbmRzIEVycm9yIHt9CgovLyBUaGUgY2VudHJh
bCBkaXJlY3Rvcnkgb2YgYSBaSVAgZmlsZTogaXRzIGVudHJpZXMgd2l0aCB0aGVpciByYXcgcmVj
b3Jkcy4KYXN5bmMgZnVuY3Rpb24gcmVhZFppcChmaWxlKSB7CiAgY29uc3QgaGFuZGxlID0gYXdh
aXQgZnNwLm9wZW4oZmlsZSwgJ3InKTsKICB0cnkgewogICAgY29uc3QgeyBzaXplIH0gPSBhd2Fp
dCBoYW5kbGUuc3RhdCgpOwogICAgaWYgKHNpemUgPCAyMikgdGhyb3cgbmV3IFBhY2tFcnJvcign
dGhpcyBpcyBub3QgYSBaSVAgZmlsZScpOwogICAgaWYgKHNpemUgPiAweGZmZmZmZmZmKSB0aHJv
dyBuZXcgUGFja0Vycm9yKCdaSVAgZmlsZXMgb3ZlciA0IEdpQiBhcmUgbm90IHN1cHBvcnRlZCcp
OwogICAgY29uc3QgdGFpbFNpemUgPSBNYXRoLm1pbihzaXplLCAyMiArIDY1NTM1KTsKICAgIGNv
bnN0IHRhaWwgPSBCdWZmZXIuYWxsb2ModGFpbFNpemUpOwogICAgYXdhaXQgaGFuZGxlLnJlYWQo
dGFpbCwgMCwgdGFpbFNpemUsIHNpemUgLSB0YWlsU2l6ZSk7CiAgICBsZXQgZW5kID0gLTE7CiAg
ICBmb3IgKGxldCBhdCA9IHRhaWxTaXplIC0gMjI7IGF0ID49IDA7IGF0IC09IDEpIHsKICAgICAg
aWYgKHRhaWwucmVhZFVJbnQzMkxFKGF0KSA9PT0gMHgwNjA1NGI1MCAmJiBhdCArIDIyICsgdGFp
bC5yZWFkVUludDE2TEUoYXQgKyAyMCkgPT09IHRhaWxTaXplKSB7CiAgICAgICAgZW5kID0gYXQ7
CiAgICAgICAgYnJlYWs7CiAgICAgIH0KICAgIH0KICAgIGlmIChlbmQgPCAwKSB0aHJvdyBuZXcg
UGFja0Vycm9yKCd0aGlzIGlzIG5vdCBhIFpJUCBmaWxlJyk7CiAgICBjb25zdCBjb3VudCA9IHRh
aWwucmVhZFVJbnQxNkxFKGVuZCArIDEwKTsKICAgIGNvbnN0IGRpcmVjdG9yeVNpemUgPSB0YWls
LnJlYWRVSW50MzJMRShlbmQgKyAxMik7CiAgICBjb25zdCBkaXJlY3RvcnlPZmZzZXQgPSB0YWls
LnJlYWRVSW50MzJMRShlbmQgKyAxNik7CiAgICBpZiAodGFpbC5yZWFkVUludDE2TEUoZW5kICsg
NCkgIT09IDAgfHwgdGFpbC5yZWFkVUludDE2TEUoZW5kICsgOCkgIT09IGNvdW50KSB0aHJvdyBu
ZXcgUGFja0Vycm9yKCdzcGxpdCBaSVAgZmlsZXMgYXJlIG5vdCBzdXBwb3J0ZWQnKTsKICAgIGlm
IChjb3VudCA9PT0gMHhmZmZmIHx8IGRpcmVjdG9yeVNpemUgPT09IDB4ZmZmZmZmZmYgfHwgZGly
ZWN0b3J5T2Zmc2V0ID09PSAweGZmZmZmZmZmKSB7CiAgICAgIHRocm93IG5ldyBQYWNrRXJyb3Io
J1pJUDY0IGZpbGVzIGFyZSBub3Qgc3VwcG9ydGVkJyk7CiAgICB9CiAgICBpZiAoZGlyZWN0b3J5
T2Zmc2V0ICsgZGlyZWN0b3J5U2l6ZSA+IHNpemUpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBa
SVAgZmlsZSBpcyBkYW1hZ2VkJyk7CiAgICBjb25zdCBkaXJlY3RvcnkgPSBCdWZmZXIuYWxsb2Mo
ZGlyZWN0b3J5U2l6ZSk7CiAgICBhd2FpdCBoYW5kbGUucmVhZChkaXJlY3RvcnksIDAsIGRpcmVj
dG9yeVNpemUsIGRpcmVjdG9yeU9mZnNldCk7CiAgICBjb25zdCBlbnRyaWVzID0gW107CiAgICBm
b3IgKGxldCBhdCA9IDAsIGluZGV4ID0gMDsgaW5kZXggPCBjb3VudDsgaW5kZXggKz0gMSkgewog
ICAgICBpZiAoYXQgKyA0NiA+IGRpcmVjdG9yeS5sZW5ndGggfHwgZGlyZWN0b3J5LnJlYWRVSW50
MzJMRShhdCkgIT09IDB4MDIwMTRiNTApIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAgZmls
ZSBpcyBkYW1hZ2VkJyk7CiAgICAgIGNvbnN0IG5hbWVMZW5ndGggPSBkaXJlY3RvcnkucmVhZFVJ
bnQxNkxFKGF0ICsgMjgpOwogICAgICBjb25zdCBsZW5ndGggPSA0NiArIG5hbWVMZW5ndGggKyBk
aXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgMzApICsgZGlyZWN0b3J5LnJlYWRVSW50MTZMRShh
dCArIDMyKTsKICAgICAgaWYgKGF0ICsgbGVuZ3RoID4gZGlyZWN0b3J5Lmxlbmd0aCkgdGhyb3cg
bmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgICAgY29uc3QgZmxh
Z3MgPSBkaXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgOCk7CiAgICAgIGNvbnN0IG5hbWUgPSBk
aXJlY3RvcnkudG9TdHJpbmcoZmxhZ3MgJiAweDgwMCA/ICd1dGY4JyA6ICdsYXRpbjEnLCBhdCAr
IDQ2LCBhdCArIDQ2ICsgbmFtZUxlbmd0aCk7CiAgICAgIGVudHJpZXMucHVzaCh7CiAgICAgICAg
bmFtZSwgZmxhZ3MsIG1ldGhvZDogZGlyZWN0b3J5LnJlYWRVSW50MTZMRShhdCArIDEwKSwKICAg
ICAgICBjb21wcmVzc2VkU2l6ZTogZGlyZWN0b3J5LnJlYWRVSW50MzJMRShhdCArIDIwKSwgc2l6
ZTogZGlyZWN0b3J5LnJlYWRVSW50MzJMRShhdCArIDI0KSwKICAgICAgICBsb2NhbE9mZnNldDog
ZGlyZWN0b3J5LnJlYWRVSW50MzJMRShhdCArIDQyKSwgcmVjb3JkOiBCdWZmZXIuZnJvbShkaXJl
Y3Rvcnkuc3ViYXJyYXkoYXQsIGF0ICsgbGVuZ3RoKSksCiAgICAgIH0pOwogICAgICBhdCArPSBs
ZW5ndGg7CiAgICB9CiAgICByZXR1cm4geyBlbnRyaWVzLCBzaXplIH07CiAgfSBmaW5hbGx5IHsK
ICAgIGF3YWl0IGhhbmRsZS5jbG9zZSgpOwogIH0KfQoKLy8gV2hhdCBvZiBhIFpJUCBmaWxlIHRo
ZSBnYW1lIG5lZWRzOiB0aGUgZ2FtZSBmb2xkZXIgKHRoZSBvbmUgaG9sZGluZyBkYXRhL2RhdGEu
dHh0IG5lYXJlc3QgdGhlCi8vIHRvcCkgd2l0aG91dCBvdGhlciBjb3BpZXMgb2YgdGhlIGdhbWUg
aW5zaWRlIGl0LCByZWNvcmRpbmdzLCBub3RlcyBhbmQgb3RoZXIgcHJvZ3JhbXMuCmZ1bmN0aW9u
IGFuYWx5emVaaXAoZW50cmllcykgewogIGNvbnN0IGxvd2VyID0gKG5hbWUpID0+IG5hbWUucmVw
bGFjZSgvXFwvZywgJy8nKS50b0xvd2VyQ2FzZSgpOwogIGxldCByb290ID0gbnVsbDsKICBmb3Ig
KGNvbnN0IGVudHJ5IG9mIGVudHJpZXMpIHsKICAgIGNvbnN0IG5hbWUgPSBsb3dlcihlbnRyeS5u
YW1lKTsKICAgIGlmIChuYW1lID09PSAnZGF0YS9kYXRhLnR4dCcgfHwgbmFtZS5lbmRzV2l0aCgn
L2RhdGEvZGF0YS50eHQnKSkgewogICAgICBjb25zdCBmb2xkZXIgPSBuYW1lLnNsaWNlKDAsIG5h
bWUubGVuZ3RoIC0gJ2RhdGEvZGF0YS50eHQnLmxlbmd0aCk7CiAgICAgIGlmIChyb290ID09PSBu
dWxsIHx8IGZvbGRlci5sZW5ndGggPCByb290Lmxlbmd0aCkgcm9vdCA9IGZvbGRlcjsKICAgIH0K
ICB9CiAgaWYgKHJvb3QgPT09IG51bGwpIHRocm93IG5ldyBQYWNrRXJyb3IoJ25vIGRhdGEvZGF0
YS50eHQgaW5zaWRlOiB0aGlzIGlzIG5vdCBhbiBMRjIgZ2FtZSBmb2xkZXInKTsKICBjb25zdCBp
bnNpZGUgPSBbXTsKICBmb3IgKGNvbnN0IGVudHJ5IG9mIGVudHJpZXMpIHsKICAgIGNvbnN0IG5h
bWUgPSBsb3dlcihlbnRyeS5uYW1lKTsKICAgIGlmICghbmFtZS5zdGFydHNXaXRoKHJvb3QpIHx8
IG5hbWUuZW5kc1dpdGgoJy8nKSB8fCBuYW1lLmxlbmd0aCA9PT0gcm9vdC5sZW5ndGgpIGNvbnRp
bnVlOwogICAgaW5zaWRlLnB1c2goeyBlbnRyeSwgcGF0aDogbmFtZS5zbGljZShyb290Lmxlbmd0
aCkgfSk7CiAgfQogIC8vIEFub3RoZXIgY29weSBvZiBhIGdhbWUgaW5zaWRlIHRoaXMgb25lIChh
IHN1YmZvbGRlciB3aXRoIGl0cyBvd24gZGF0YS9kYXRhLnR4dCkuCiAgY29uc3QgY29waWVzID0g
aW5zaWRlLmZpbHRlcigoeyBwYXRoOiBuYW1lIH0pID0+IG5hbWUgIT09ICdkYXRhL2RhdGEudHh0
JyAmJiBuYW1lLmVuZHNXaXRoKCcvZGF0YS9kYXRhLnR4dCcpKQogICAgLm1hcCgoeyBwYXRoOiBu
YW1lIH0pID0+IG5hbWUuc2xpY2UoMCwgbmFtZS5sZW5ndGggLSAnZGF0YS9kYXRhLnR4dCcubGVu
Z3RoKSk7CiAgY29uc3QgZXhlY3V0YWJsZXMgPSBpbnNpZGUuZmlsdGVyKCh7IHBhdGg6IG5hbWUg
fSkgPT4gIW5hbWUuaW5jbHVkZXMoJy8nKSAmJiBuYW1lLmVuZHNXaXRoKCcuZXhlJykpOwogIGlm
ICghZXhlY3V0YWJsZXMubGVuZ3RoKSB0aHJvdyBuZXcgUGFja0Vycm9yKCdubyBnYW1lIHByb2dy
YW0gKC5leGUpIGJlc2lkZSBpdHMgZGF0YSBmb2xkZXInKTsKICBjb25zdCBtYWluID0gZXhlY3V0
YWJsZXMuZmluZCgoeyBwYXRoOiBuYW1lIH0pID0+IG5hbWUgPT09ICdsZjIuZXhlJykKICAgIHx8
IGV4ZWN1dGFibGVzLnJlZHVjZSgobGFyZ2VzdCwgaXRlbSkgPT4gKGl0ZW0uZW50cnkuc2l6ZSA+
IGxhcmdlc3QuZW50cnkuc2l6ZSA/IGl0ZW0gOiBsYXJnZXN0KSk7CiAgY29uc3Qga2VlcCA9IFtd
OwogIGZvciAoY29uc3QgaXRlbSBvZiBpbnNpZGUpIHsKICAgIGNvbnN0IG5hbWUgPSBpdGVtLnBh
dGg7CiAgICBjb25zdCB0b3BMZXZlbCA9ICFuYW1lLmluY2x1ZGVzKCcvJyk7CiAgICBpZiAoY29w
aWVzLnNvbWUoKGNvcHkpID0+IG5hbWUuc3RhcnRzV2l0aChjb3B5KSkpIGNvbnRpbnVlOwogICAg
aWYgKG5hbWUuc3RhcnRzV2l0aCgncmVjb3JkaW5nLycpKSBjb250aW51ZTsKICAgIGlmICh0b3BM
ZXZlbCAmJiBuYW1lLmVuZHNXaXRoKCcuZXhlJykgJiYgaXRlbSAhPT0gbWFpbikgY29udGludWU7
CiAgICBpZiAodG9wTGV2ZWwgJiYgTk9URVMudGVzdChuYW1lKSkgY29udGludWU7CiAgICBpZiAo
aXRlbS5lbnRyeS5mbGFncyAmIDEpIHRocm93IG5ldyBQYWNrRXJyb3IoYCR7aXRlbS5lbnRyeS5u
YW1lfSBpcyBlbmNyeXB0ZWRgKTsKICAgIGlmIChpdGVtLmVudHJ5Lm1ldGhvZCAhPT0gMCAmJiBp
dGVtLmVudHJ5Lm1ldGhvZCAhPT0gOCkgewogICAgICB0aHJvdyBuZXcgUGFja0Vycm9yKGAke2l0
ZW0uZW50cnkubmFtZX0gdXNlcyBhIGNvbXByZXNzaW9uIHRoZSBnYW1lIGNhbm5vdCByZWFkICh6
aXAgaXQgYWdhaW4gd2l0aCBEZWZsYXRlKWApOwogICAgfQogICAgLy8gVGhlIGdhbWUgcmVhZHMg
ZmlsZXMgdXAgdG8gMjU2IE1pQiBmcm9tIGEgcGFjayAoc3JjL3Jlc291cmNlcy9wYWNrLmNwcCku
CiAgICBpZiAoaXRlbS5lbnRyeS5zaXplID4gMjU2ICogTUlCKSB0aHJvdyBuZXcgUGFja0Vycm9y
KGAke2l0ZW0uZW50cnkubmFtZX0gaXMgbGFyZ2VyIHRoYW4gMjU2IE1CYCk7CiAgICBrZWVwLnB1
c2goaXRlbS5lbnRyeSk7CiAgfQogIHJldHVybiB7IHJvb3QsIGV4ZWN1dGFibGU6IG1haW4ucGF0
aCwga2VlcCwgZHJvcHBlZDogZW50cmllcy5sZW5ndGggLSBrZWVwLmxlbmd0aCB9Owp9CgovLyAt
LS0tIEZsYXNoIGdhbWVzIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KLy8gQSBGbGFzaCBwcm9q
ZWN0b3IgKEZsYXNoIFBsYXllciBmb3IgV2luZG93cyB3aXRoIGEgbW92aWUgaW5zaWRlKSBlbmRz
IHdpdGggMHhGQTEyMzQ1NiBhbmQgdGhlIG1vdmllJ3MKLy8gbGVuZ3RoIChib3RoIDQgYnl0ZXMs
IGxpdHRsZSBlbmRpYW4pLCB0aGUgbW92aWUganVzdCBiZWZvcmUuCmNvbnN0IFBST0pFQ1RPUl9N
QUdJQyA9IDB4ZmExMjM0NTY7Ci8vIEhlcm8gRmlnaHRlcidzIG1vdmllczogdGhlIG9uZSBpbiAi
SEZ2MC43Ky5leGUiIChIZXJvIEZpZ2h0ZXIgdjAuNyssIDIwMjEtMTAtMTEpLgpjb25zdCBIRVJP
X0ZJR0hURVIgPSBuZXcgU2V0KFsnNDJhZWM1ZTY4M2JkY2FiZDVjYWY2MTgxYmU1ZmU3NDYxOGFm
ZTUzNmVjNjIwMzA3MzRkOTUzNmZhYjE4NTJhOCddKTsKY29uc3QgSEVST19GSUdIVEVSX01BUksg
PSBCdWZmZXIuZnJvbSgnaHR0cDovL3d3dy5oZXJvZmlnaHRlci5jb20vdmVyLnR4dCcsICdsYXRp
bjEnKTsKCmZ1bmN0aW9uIGlzU3dmKGJ5dGVzKSB7CiAgcmV0dXJuIGJ5dGVzLmxlbmd0aCA+IDgg
JiYgWydGV1MnLCAnQ1dTJywgJ1pXUyddLmluY2x1ZGVzKGJ5dGVzLnRvU3RyaW5nKCdsYXRpbjEn
LCAwLCAzKSk7Cn0KCi8vIFRoZSBtb3ZpZSBvZiBhIHByb2plY3RvciBvciBvZiBhIG1vdmllIGZp
bGU7IG51bGwgZm9yIGFueXRoaW5nIGVsc2UuCmZ1bmN0aW9uIG1vdmllT2YoYnl0ZXMpIHsKICBp
ZiAoaXNTd2YoYnl0ZXMpKSByZXR1cm4gYnl0ZXM7CiAgaWYgKGJ5dGVzLmxlbmd0aCA8IDE2IHx8
IGJ5dGVzLnRvU3RyaW5nKCdsYXRpbjEnLCAwLCAyKSAhPT0gJ01aJykgcmV0dXJuIG51bGw7CiAg
aWYgKGJ5dGVzLnJlYWRVSW50MzJMRShieXRlcy5sZW5ndGggLSA4KSAhPT0gUFJPSkVDVE9SX01B
R0lDKSByZXR1cm4gbnVsbDsKICBjb25zdCBsZW5ndGggPSBieXRlcy5yZWFkVUludDMyTEUoYnl0
ZXMubGVuZ3RoIC0gNCk7CiAgaWYgKGxlbmd0aCA8IDkgfHwgbGVuZ3RoID4gYnl0ZXMubGVuZ3Ro
IC0gOCkgcmV0dXJuIG51bGw7CiAgY29uc3QgbW92aWUgPSBieXRlcy5zdWJhcnJheShieXRlcy5s
ZW5ndGggLSA4IC0gbGVuZ3RoLCBieXRlcy5sZW5ndGggLSA4KTsKICByZXR1cm4gaXNTd2YobW92
aWUpID8gbW92aWUgOiBudWxsOwp9CgovLyBXaGljaCBnYW1lIGEgbW92aWUgaXM6ICJoZXJvZmln
aHRlciIsIG9yICIiIGZvciBvbmUgdGhpcyByZWxheSBkb2VzIG5vdCBrbm93LgpmdW5jdGlvbiBm
bGFzaEdhbWUobW92aWUpIHsKICBjb25zdCBzaGEyNTYgPSBjcnlwdG8uY3JlYXRlSGFzaCgnc2hh
MjU2JykudXBkYXRlKG1vdmllKS5kaWdlc3QoJ2hleCcpOwogIGlmIChIRVJPX0ZJR0hURVIuaGFz
KHNoYTI1NikpIHJldHVybiAnaGVyb2ZpZ2h0ZXInOwogIC8vIEFuIHVuY29tcHJlc3NlZCBtb3Zp
ZSBjYW4gYmUgc2VhcmNoZWQgYXMgaXQgaXMgKEhlcm8gRmlnaHRlcidzIHByb2plY3RvciBtb3Zp
ZXMgYXJlKS4KICBpZiAobW92aWUudG9TdHJpbmcoJ2xhdGluMScsIDAsIDMpID09PSAnRldTJyAm
JiBtb3ZpZS5pbmNsdWRlcyhIRVJPX0ZJR0hURVJfTUFSSykpIHJldHVybiAnaGVyb2ZpZ2h0ZXIn
OwogIHJldHVybiAnJzsKfQoKLy8gQW4gZW50cnkncyBieXRlcyAoc3RvcmVkIG9yIERlZmxhdGUp
Lgphc3luYyBmdW5jdGlvbiByZWFkRW50cnkoZmlsZSwgZW50cnkpIHsKICBjb25zdCBoYW5kbGUg
PSBhd2FpdCBmc3Aub3BlbihmaWxlLCAncicpOwogIHRyeSB7CiAgICBjb25zdCBoZWFkZXIgPSBC
dWZmZXIuYWxsb2MoMzApOwogICAgYXdhaXQgaGFuZGxlLnJlYWQoaGVhZGVyLCAwLCAzMCwgZW50
cnkubG9jYWxPZmZzZXQpOwogICAgaWYgKGhlYWRlci5yZWFkVUludDMyTEUoMCkgIT09IDB4MDQw
MzRiNTApIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAgZmlsZSBpcyBkYW1hZ2VkJyk7CiAg
ICBjb25zdCBzdGFydCA9IGVudHJ5LmxvY2FsT2Zmc2V0ICsgMzAgKyBoZWFkZXIucmVhZFVJbnQx
NkxFKDI2KSArIGhlYWRlci5yZWFkVUludDE2TEUoMjgpOwogICAgY29uc3QgcGFja2VkID0gQnVm
ZmVyLmFsbG9jKGVudHJ5LmNvbXByZXNzZWRTaXplKTsKICAgIGF3YWl0IGhhbmRsZS5yZWFkKHBh
Y2tlZCwgMCwgcGFja2VkLmxlbmd0aCwgc3RhcnQpOwogICAgaWYgKGVudHJ5Lm1ldGhvZCA9PT0g
MCkgcmV0dXJuIHBhY2tlZDsKICAgIGlmIChlbnRyeS5tZXRob2QgPT09IDgpIHJldHVybiB6bGli
LmluZmxhdGVSYXdTeW5jKHBhY2tlZCwgeyBtYXhPdXRwdXRMZW5ndGg6IDUxMiAqIE1JQiB9KTsK
ICAgIHRocm93IG5ldyBQYWNrRXJyb3IoYCR7ZW50cnkubmFtZX0gdXNlcyBhIGNvbXByZXNzaW9u
IHRoZSByZWxheSBjYW5ub3QgcmVhZCAoemlwIGl0IGFnYWluIHdpdGggRGVmbGF0ZSlgKTsKICB9
IGZpbmFsbHkgewogICAgYXdhaXQgaGFuZGxlLmNsb3NlKCk7CiAgfQp9CgovLyBUaGUgRmxhc2gg
bW92aWUgYW4gdXBsb2FkIGhvbGRzIChhIG1vdmllIG9yIHByb2plY3RvciBmaWxlLCBvciBhIFpJ
UCBmaWxlIHdpdGggb25lKSwgb3IgbnVsbC4KYXN5bmMgZnVuY3Rpb24gZmluZE1vdmllKGZpbGUs
IHppcCkgewogIGlmICghemlwKSB7CiAgICBjb25zdCB7IHNpemUgfSA9IGF3YWl0IGZzcC5zdGF0
KGZpbGUpOwogICAgaWYgKHNpemUgPiA1MTIgKiBNSUIpIHJldHVybiBudWxsOwogICAgcmV0dXJu
IG1vdmllT2YoYXdhaXQgZnNwLnJlYWRGaWxlKGZpbGUpKTsKICB9CiAgY29uc3QgY2FuZGlkYXRl
cyA9IHppcC5lbnRyaWVzCiAgICAuZmlsdGVyKChlbnRyeSkgPT4gL1wuKHN3ZnxleGUpJC9pLnRl
c3QoZW50cnkubmFtZSkgJiYgIShlbnRyeS5mbGFncyAmIDEpICYmIGVudHJ5LnNpemUgPD0gNTEy
ICogTUlCKQogICAgLnNvcnQoKGEsIGIpID0+IGIuc2l6ZSAtIGEuc2l6ZSk7CiAgZm9yIChjb25z
dCBlbnRyeSBvZiBjYW5kaWRhdGVzKSB7CiAgICBjb25zdCBtb3ZpZSA9IG1vdmllT2YoYXdhaXQg
cmVhZEVudHJ5KGZpbGUsIGVudHJ5KSk7CiAgICBpZiAobW92aWUpIHJldHVybiBtb3ZpZTsKICB9
CiAgcmV0dXJuIG51bGw7Cn0KCi8vIFdyaXRlcyB0aGUga2VwdCBlbnRyaWVzIG9mIGBzb3VyY2Vg
IGFzIGEgbmV3IFpJUCBmaWxlLCBjb3B5aW5nIHRoZWlyIGNvbXByZXNzZWQgYnl0ZXMgYXMgdGhl
eSBhcmUuCmFzeW5jIGZ1bmN0aW9uIHdyaXRlWmlwKHNvdXJjZSwgdGFyZ2V0LCBrZWVwKSB7CiAg
Y29uc3QgaW5wdXQgPSBhd2FpdCBmc3Aub3Blbihzb3VyY2UsICdyJyk7CiAgY29uc3Qgb3V0cHV0
ID0gYXdhaXQgZnNwLm9wZW4odGFyZ2V0LCAndycpOwogIGNvbnN0IGhhc2ggPSBjcnlwdG8uY3Jl
YXRlSGFzaCgnc2hhMjU2Jyk7CiAgbGV0IG9mZnNldCA9IDA7CiAgY29uc3Qgd3JpdGUgPSBhc3lu
YyAoYnVmZmVyKSA9PiB7CiAgICBsZXQgZG9uZSA9IDA7CiAgICB3aGlsZSAoZG9uZSA8IGJ1ZmZl
ci5sZW5ndGgpIHsKICAgICAgY29uc3QgeyBieXRlc1dyaXR0ZW4gfSA9IGF3YWl0IG91dHB1dC53
cml0ZShidWZmZXIsIGRvbmUsIGJ1ZmZlci5sZW5ndGggLSBkb25lLCBvZmZzZXQgKyBkb25lKTsK
ICAgICAgZG9uZSArPSBieXRlc1dyaXR0ZW47CiAgICB9CiAgICBoYXNoLnVwZGF0ZShidWZmZXIp
OwogICAgb2Zmc2V0ICs9IGJ1ZmZlci5sZW5ndGg7CiAgfTsKICB0cnkgewogICAgY29uc3QgcmVj
b3JkcyA9IFtdOwogICAgZm9yIChjb25zdCBlbnRyeSBvZiBrZWVwKSB7CiAgICAgIGNvbnN0IGhl
YWRlciA9IEJ1ZmZlci5hbGxvYygzMCk7CiAgICAgIGF3YWl0IGlucHV0LnJlYWQoaGVhZGVyLCAw
LCAzMCwgZW50cnkubG9jYWxPZmZzZXQpOwogICAgICBpZiAoaGVhZGVyLnJlYWRVSW50MzJMRSgw
KSAhPT0gMHgwNDAzNGI1MCkgdGhyb3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRh
bWFnZWQnKTsKICAgICAgbGV0IGxlbmd0aCA9IDMwICsgaGVhZGVyLnJlYWRVSW50MTZMRSgyNikg
KyBoZWFkZXIucmVhZFVJbnQxNkxFKDI4KSArIGVudHJ5LmNvbXByZXNzZWRTaXplOwogICAgICBp
ZiAoZW50cnkuZmxhZ3MgJiA4KSB7IC8vIGEgZGF0YSBkZXNjcmlwdG9yIGZvbGxvd3MgdGhlIGRh
dGEKICAgICAgICBjb25zdCBwcm9iZSA9IEJ1ZmZlci5hbGxvYyg0KTsKICAgICAgICBhd2FpdCBp
bnB1dC5yZWFkKHByb2JlLCAwLCA0LCBlbnRyeS5sb2NhbE9mZnNldCArIGxlbmd0aCk7CiAgICAg
ICAgbGVuZ3RoICs9IHByb2JlLnJlYWRVSW50MzJMRSgwKSA9PT0gMHgwODA3NGI1MCA/IDE2IDog
MTI7CiAgICAgIH0KICAgICAgY29uc3QgcmVjb3JkID0gQnVmZmVyLmZyb20oZW50cnkucmVjb3Jk
KTsKICAgICAgcmVjb3JkLndyaXRlVUludDMyTEUob2Zmc2V0LCA0Mik7CiAgICAgIHJlY29yZHMu
cHVzaChyZWNvcmQpOwogICAgICBmb3IgKGxldCBjb3BpZWQgPSAwOyBjb3BpZWQgPCBsZW5ndGg7
KSB7CiAgICAgICAgY29uc3QgY2h1bmsgPSBCdWZmZXIuYWxsb2MoTWF0aC5taW4oNCAqIE1JQiwg
bGVuZ3RoIC0gY29waWVkKSk7CiAgICAgICAgY29uc3QgeyBieXRlc1JlYWQgfSA9IGF3YWl0IGlu
cHV0LnJlYWQoY2h1bmssIDAsIGNodW5rLmxlbmd0aCwgZW50cnkubG9jYWxPZmZzZXQgKyBjb3Bp
ZWQpOwogICAgICAgIGlmICghYnl0ZXNSZWFkKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGUgWklQ
IGZpbGUgaXMgZGFtYWdlZCcpOwogICAgICAgIGF3YWl0IHdyaXRlKGNodW5rLnN1YmFycmF5KDAs
IGJ5dGVzUmVhZCkpOwogICAgICAgIGNvcGllZCArPSBieXRlc1JlYWQ7CiAgICAgIH0KICAgIH0K
ICAgIGNvbnN0IGRpcmVjdG9yeU9mZnNldCA9IG9mZnNldDsKICAgIGZvciAoY29uc3QgcmVjb3Jk
IG9mIHJlY29yZHMpIGF3YWl0IHdyaXRlKHJlY29yZCk7CiAgICBjb25zdCBlbmQgPSBCdWZmZXIu
YWxsb2MoMjIpOwogICAgZW5kLndyaXRlVUludDMyTEUoMHgwNjA1NGI1MCwgMCk7CiAgICBlbmQu
d3JpdGVVSW50MTZMRShyZWNvcmRzLmxlbmd0aCwgOCk7CiAgICBlbmQud3JpdGVVSW50MTZMRShy
ZWNvcmRzLmxlbmd0aCwgMTApOwogICAgZW5kLndyaXRlVUludDMyTEUob2Zmc2V0IC0gZGlyZWN0
b3J5T2Zmc2V0LCAxMik7CiAgICBlbmQud3JpdGVVSW50MzJMRShkaXJlY3RvcnlPZmZzZXQsIDE2
KTsKICAgIGF3YWl0IHdyaXRlKGVuZCk7CiAgICByZXR1cm4geyBzaXplOiBvZmZzZXQsIHNoYTI1
NjogaGFzaC5kaWdlc3QoJ2hleCcpLCBmaWxlczogcmVjb3Jkcy5sZW5ndGggfTsKICB9IGZpbmFs
bHkgewogICAgYXdhaXQgaW5wdXQuY2xvc2UoKTsKICAgIGF3YWl0IG91dHB1dC5jbG9zZSgpOwog
IH0KfQoKZnVuY3Rpb24gc2FtZUtleShnaXZlbiwgZXhwZWN0ZWQpIHsKICBjb25zdCBhID0gY3J5
cHRvLmNyZWF0ZUhhc2goJ3NoYTI1NicpLnVwZGF0ZShTdHJpbmcoZ2l2ZW4gfHwgJycpKS5kaWdl
c3QoKTsKICBjb25zdCBiID0gY3J5cHRvLmNyZWF0ZUhhc2goJ3NoYTI1NicpLnVwZGF0ZShTdHJp
bmcoZXhwZWN0ZWQpKS5kaWdlc3QoKTsKICByZXR1cm4gY3J5cHRvLnRpbWluZ1NhZmVFcXVhbChh
LCBiKTsKfQoKZnVuY3Rpb24gY3JlYXRlUGFja3MoY29uZmlnLCB7IGxvZywgY2xpZW50QWRkcmVz
cywgYWxsb3dPcmlnaW4sIGhmSm91cm5hbCA9IG51bGwgfSkgewogIGNvbnN0IGRpcmVjdG9yeSA9
IGNvbmZpZy5wYWNrc0RpcjsKICBjb25zdCBkb3dubG9hZHMgPSBuZXcgTWFwKCk7IC8vIGNsaWVu
dCBhZGRyZXNzIC0+IHsgY291bnQsIHVudGlsIH0KICBjb25zdCBmYWlsdXJlcyA9IG5ldyBNYXAo
KTsgLy8gY2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwgfQogIGxldCB1cGxvYWRpbmcg
PSBmYWxzZTsKCiAgY29uc3QganNvbiA9IChyZXMsIHN0YXR1cywgYm9keSwgaGVhZGVycyA9IHt9
KSA9PiB7CiAgICByZXMud3JpdGVIZWFkKHN0YXR1cywgeyAnY29udGVudC10eXBlJzogJ2FwcGxp
Y2F0aW9uL2pzb247IGNoYXJzZXQ9dXRmLTgnLCAnY2FjaGUtY29udHJvbCc6ICduby1zdG9yZScs
IC4uLmhlYWRlcnMgfSk7CiAgICByZXMuZW5kKEpTT04uc3RyaW5naWZ5KGJvZHkpKTsKICB9Owog
IGNvbnN0IGNvdW50ZWQgPSAobWFwLCBhZGRyZXNzLCBsaW1pdCkgPT4gewogICAgY29uc3Qgbm93
ID0gRGF0ZS5ub3coKTsKICAgIGxldCBlbnRyeSA9IG1hcC5nZXQoYWRkcmVzcyk7CiAgICBpZiAo
IWVudHJ5IHx8IGVudHJ5LnVudGlsIDw9IG5vdykgewogICAgICBlbnRyeSA9IHsgY291bnQ6IDAs
IHVudGlsOiBub3cgKyAzNjAwMDAwIH07CiAgICAgIG1hcC5zZXQoYWRkcmVzcywgZW50cnkpOwog
ICAgfQogICAgcmV0dXJuIHsgb3ZlcjogbGltaXQgPiAwICYmIGVudHJ5LmNvdW50ID49IGxpbWl0
LCBhZGQ6ICgpID0+IHsgZW50cnkuY291bnQgKz0gMTsgfSwgcmV0cnk6IE1hdGguY2VpbCgoZW50
cnkudW50aWwgLSBub3cpIC8gMTAwMCkgfTsKICB9OwoKICBhc3luYyBmdW5jdGlvbiBsaXN0KCkg
ewogICAgaWYgKCFkaXJlY3RvcnkpIHJldHVybiBbXTsKICAgIGxldCBuYW1lczsKICAgIHRyeSB7
IG5hbWVzID0gYXdhaXQgZnNwLnJlYWRkaXIoZGlyZWN0b3J5KTsgfSBjYXRjaCB7IHJldHVybiBb
XTsgfQogICAgY29uc3QgcGFja3MgPSBbXTsKICAgIGZvciAoY29uc3QgbmFtZSBvZiBuYW1lcykg
ewogICAgICBpZiAoIW5hbWUuZW5kc1dpdGgoJy5qc29uJykpIGNvbnRpbnVlOwogICAgICBjb25z
dCBpZCA9IG5hbWUuc2xpY2UoMCwgLTUpOwogICAgICBpZiAoIVBBQ0tfSUQudGVzdChpZCkpIGNv
bnRpbnVlOwogICAgICB0cnkgewogICAgICAgIGNvbnN0IGluZm8gPSBKU09OLnBhcnNlKGF3YWl0
IGZzcC5yZWFkRmlsZShwYXRoLmpvaW4oZGlyZWN0b3J5LCBuYW1lKSwgJ3V0ZjgnKSk7CiAgICAg
ICAgY29uc3Qga2luZCA9IGluZm8ua2luZCA9PT0gJ2ZsYXNoJyA/ICdmbGFzaCcgOiAnbGYyJzsK
ICAgICAgICBjb25zdCBzdGF0ID0gYXdhaXQgZnNwLnN0YXQocGF0aC5qb2luKGRpcmVjdG9yeSwg
YCR7aWR9LiR7a2luZCA9PT0gJ2ZsYXNoJyA/ICdzd2YnIDogJ3ppcCd9YCkpOwogICAgICAgIHBh
Y2tzLnB1c2goeyBpZCwgdGl0bGU6IFN0cmluZyhpbmZvLnRpdGxlIHx8IGlkKSwgc2l6ZTogc3Rh
dC5zaXplLCBzaGEyNTY6IFN0cmluZyhpbmZvLnNoYTI1NiB8fCAnJyksCiAgICAgICAgICBraW5k
LCBnYW1lOiBTdHJpbmcoaW5mby5nYW1lIHx8ICcnKSwgZmlsZXM6IGluZm8uZmlsZXMsIHVwbG9h
ZGVkOiBpbmZvLnVwbG9hZGVkLCBvcmlnaW5hbDogaW5mby5vcmlnaW5hbCB9KTsKICAgICAgfSBj
YXRjaCB7IC8qIGEgaGFsZi13cml0dGVuIG9yIHJlbW92ZWQgcGFjayAqLyB9CiAgICB9CiAgICBy
ZXR1cm4gcGFja3Muc29ydCgoYSwgYikgPT4gYS50aXRsZS5sb2NhbGVDb21wYXJlKGIudGl0bGUp
KTsKICB9CgogIGZ1bmN0aW9uIGF1dGhvcml6ZWQocmVxLCByZXMpIHsKICAgIGlmICghY29uZmln
LmFkbWluS2V5KSB7CiAgICAgIGpzb24ocmVzLCA0MDMsIHsgZXJyb3I6ICdDaMawYSDEkeG6t3Qg
QURNSU5fS0VZIGNobyByZWxheSAoY2jhuqF5IGzhuqFpIGluc3RhbGwtdnBzLnNoKS4nIH0pOwog
ICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgICBjb25zdCBhZGRyZXNzID0gY2xpZW50QWRkcmVz
cyhyZXEpOwogICAgY29uc3QgdHJpZXMgPSBjb3VudGVkKGZhaWx1cmVzLCBhZGRyZXNzLCAyMCk7
CiAgICBpZiAodHJpZXMub3ZlcikgewogICAgICBqc29uKHJlcywgNDI5LCB7IGVycm9yOiAnU2Fp
IG3DoyBxdcOhIG5oaeG7gXUgbOG6p24sIHRo4butIGzhuqFpIHNhdSBt4buZdCBnaeG7nS4nIH0s
IHsgJ3JldHJ5LWFmdGVyJzogU3RyaW5nKHRyaWVzLnJldHJ5KSB9KTsKICAgICAgcmV0dXJuIGZh
bHNlOwogICAgfQogICAgaWYgKCFzYW1lS2V5KHJlcS5oZWFkZXJzWyd4LWFkbWluLWtleSddLCBj
b25maWcuYWRtaW5LZXkpKSB7CiAgICAgIHRyaWVzLmFkZCgpOwogICAgICBqc29uKHJlcywgNDAx
LCB7IGVycm9yOiAnU2FpIG3DoyBxdeG6o24gdHLhu4sgKEFETUlOX0tFWSkuJyB9KTsKICAgICAg
cmV0dXJuIGZhbHNlOwogICAgfQogICAgcmV0dXJuIHRydWU7CiAgfQoKICBhc3luYyBmdW5jdGlv
biB1cGxvYWQocmVxLCByZXMsIGlkLCB0aXRsZSkgewogICAgaWYgKCFkaXJlY3RvcnkpIHJldHVy
biBqc29uKHJlcywgNTAzLCB7IGVycm9yOiAnUmVsYXkgbsOgeSBraMO0bmcgZ2nhu68gYuG6o24g
bW9kIChjaMawYSDEkeG6t3QgUEFDS1NfRElSKS4nIH0pOwogICAgaWYgKHVwbG9hZGluZykgcmV0
dXJuIGpzb24ocmVzLCA0MDksIHsgZXJyb3I6ICfEkGFuZyBjw7MgbeG7mXQgbOG6p24gdOG6o2kg
bMOqbiBraMOhYywgY2jhu50geG9uZyBy4buTaSB0aOG7rSBs4bqhaS4nIH0pOwogICAgY29uc3Qg
ZGVjbGFyZWQgPSBOdW1iZXIocmVxLmhlYWRlcnNbJ2NvbnRlbnQtbGVuZ3RoJ10gfHwgMCk7CiAg
ICBpZiAoZGVjbGFyZWQgPiBjb25maWcubWF4UGFja0J5dGVzKSB7CiAgICAgIHJldHVybiBqc29u
KHJlcywgNDEzLCB7IGVycm9yOiBgRmlsZSBxdcOhIGzhu5tuICh04buRaSDEkWEgJHtNYXRoLnJv
dW5kKGNvbmZpZy5tYXhQYWNrQnl0ZXMgLyBNSUIpfSBNQikuYCB9KTsKICAgIH0KICAgIGF3YWl0
IGZzcC5ta2RpcihkaXJlY3RvcnksIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwogICAgdHJ5IHsKICAg
ICAgY29uc3Qgc3BhY2UgPSBhd2FpdCBmc3Auc3RhdGZzKGRpcmVjdG9yeSk7CiAgICAgIGNvbnN0
IGZyZWUgPSBzcGFjZS5iYXZhaWwgKiBzcGFjZS5ic2l6ZTsKICAgICAgaWYgKGZyZWUgPCAyICog
ZGVjbGFyZWQgKyAyNTYgKiBNSUIpIHsKICAgICAgICByZXR1cm4ganNvbihyZXMsIDUwNywgeyBl
cnJvcjogYFZQUyBraMO0bmcgxJHhu6cgY2jhu5cgdHLhu5FuZyAoY8OybiAke01hdGgucm91bmQo
ZnJlZSAvIE1JQil9IE1CKS5gIH0pOwogICAgICB9CiAgICB9IGNhdGNoIHsgLyogc3RhdGZzIHVu
YXZhaWxhYmxlOiB0cnkgYW55d2F5ICovIH0KICAgIHVwbG9hZGluZyA9IHRydWU7CiAgICBjb25z
dCBub25jZSA9IGNyeXB0by5yYW5kb21CeXRlcyg2KS50b1N0cmluZygnaGV4Jyk7CiAgICBjb25z
dCByZWNlaXZlZCA9IHBhdGguam9pbihkaXJlY3RvcnksIGAudXBsb2FkLSR7bm9uY2V9LnppcGAp
OwogICAgY29uc3Qgc2xpbSA9IHBhdGguam9pbihkaXJlY3RvcnksIGAucGFjay0ke25vbmNlfS56
aXBgKTsKICAgIHRyeSB7CiAgICAgIGxldCBieXRlcyA9IDA7CiAgICAgIGNvbnN0IGNvdW50ZXIg
PSBuZXcgVHJhbnNmb3JtKHsKICAgICAgICB0cmFuc2Zvcm0oY2h1bmssIGVuY29kaW5nLCBkb25l
KSB7CiAgICAgICAgICBieXRlcyArPSBjaHVuay5sZW5ndGg7CiAgICAgICAgICBpZiAoYnl0ZXMg
PiBjb25maWcubWF4UGFja0J5dGVzKSBkb25lKG5ldyBQYWNrRXJyb3IoYEZpbGUgcXXDoSBs4bub
biAodOG7kWkgxJFhICR7TWF0aC5yb3VuZChjb25maWcubWF4UGFja0J5dGVzIC8gTUlCKX0gTUIp
LmApKTsKICAgICAgICAgIGVsc2UgZG9uZShudWxsLCBjaHVuayk7CiAgICAgICAgfSwKICAgICAg
fSk7CiAgICAgIGF3YWl0IHBpcGVsaW5lKHJlcSwgY291bnRlciwgZnMuY3JlYXRlV3JpdGVTdHJl
YW0ocmVjZWl2ZWQpKTsKICAgICAgaWYgKGRlY2xhcmVkICYmIGJ5dGVzICE9PSBkZWNsYXJlZCkg
dGhyb3cgbmV3IFBhY2tFcnJvcignVOG6o2kgbMOqbiBi4buLIG5n4bqvdCBnaeG7r2EgY2jhu6tu
Zy4nKTsKICAgICAgbGV0IHppcCA9IG51bGw7CiAgICAgIHRyeSB7IHppcCA9IGF3YWl0IHJlYWRa
aXAocmVjZWl2ZWQpOyB9IGNhdGNoIChlcnJvcikgeyBpZiAoIShlcnJvciBpbnN0YW5jZW9mIFBh
Y2tFcnJvcikpIHRocm93IGVycm9yOyB9CiAgICAgIGNvbnN0IGxmMiA9IHppcCAmJiB6aXAuZW50
cmllcy5zb21lKCh7IG5hbWUgfSkgPT4gLyhefFtcXC9dKWRhdGFbXFwvXWRhdGFcLnR4dCQvaS50
ZXN0KG5hbWUpKTsKICAgICAgaWYgKCFsZjIpIHsKICAgICAgICAvLyBBIEZsYXNoIGdhbWUsIG9y
IHdoYXQgcmVhZFppcC9hbmFseXplWmlwIHNheSB0aGlzIGlzIG5vdC4KICAgICAgICBjb25zdCBt
b3ZpZSA9IGF3YWl0IGZpbmRNb3ZpZShyZWNlaXZlZCwgemlwKTsKICAgICAgICBpZiAoIW1vdmll
KSB7CiAgICAgICAgICBpZiAoIXppcCkgdGhyb3cgbmV3IFBhY2tFcnJvcignxJDDonkga2jDtG5n
IHBo4bqjaSBmaWxlIC56aXAsIGPFqW5nIGtow7RuZyBwaOG6o2kgZ2FtZSBGbGFzaCAoLnN3ZiBo
b+G6t2MgLmV4ZSBjw7MgZ2FtZSBGbGFzaCBiw6puIHRyb25nKS4nKTsKICAgICAgICAgIGFuYWx5
emVaaXAoemlwLmVudHJpZXMpOyAvLyB0aHJvd3Mgd2h5IHRoaXMgaXMgbm8gTEYyIGdhbWUgZm9s
ZGVyCiAgICAgICAgfQogICAgICAgIGNvbnN0IHNoYTI1NiA9IGNyeXB0by5jcmVhdGVIYXNoKCdz
aGEyNTYnKS51cGRhdGUobW92aWUpLmRpZ2VzdCgnaGV4Jyk7CiAgICAgICAgY29uc3QgZ2FtZSA9
IGZsYXNoR2FtZShtb3ZpZSk7CiAgICAgICAgYXdhaXQgZnNwLndyaXRlRmlsZShzbGltLCBtb3Zp
ZSk7CiAgICAgICAgZm9yIChjb25zdCBvbGQgb2YgW2Ake2lkfS56aXBgLCBgJHtpZH0uc3dmYF0p
IGF3YWl0IGZzcC5ybShwYXRoLmpvaW4oZGlyZWN0b3J5LCBvbGQpLCB7IGZvcmNlOiB0cnVlIH0p
OwogICAgICAgIGF3YWl0IGZzcC5yZW5hbWUoc2xpbSwgcGF0aC5qb2luKGRpcmVjdG9yeSwgYCR7
aWR9LnN3ZmApKTsKICAgICAgICBjb25zdCBpbmZvID0geyB0aXRsZSwgc2hhMjU2LCBmaWxlczog
MSwga2luZDogJ2ZsYXNoJywgZ2FtZSwgdXBsb2FkZWQ6IG5ldyBEYXRlKCkudG9JU09TdHJpbmco
KSwKICAgICAgICAgIG9yaWdpbmFsOiB7IHNpemU6IGJ5dGVzLCBmaWxlczogemlwID8gemlwLmVu
dHJpZXMubGVuZ3RoIDogMSB9IH07CiAgICAgICAgYXdhaXQgZnNwLndyaXRlRmlsZShwYXRoLmpv
aW4oZGlyZWN0b3J5LCBgJHtpZH0uanNvbmApLCBKU09OLnN0cmluZ2lmeShpbmZvLCBudWxsLCAy
KSk7CiAgICAgICAgYXdhaXQgZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVlIH0pOwogICAg
ICAgIGxvZyhgcGFjayAke2lkfTogJHtieXRlc30gYnl0ZXMgdXBsb2FkZWQsIGEgRmxhc2ggbW92
aWUgb2YgJHttb3ZpZS5sZW5ndGh9IGtlcHQke2dhbWUgPyBgICgke2dhbWV9KWAgOiAnJ31gKTsK
ICAgICAgICBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlLCBpZCwgdGl0bGUsIHNpemU6IG1vdmll
Lmxlbmd0aCwgc2hhMjU2LCBmaWxlczogMSwgZHJvcHBlZDogaW5mby5vcmlnaW5hbC5maWxlcyAt
IDEsCiAgICAgICAgICBraW5kOiAnZmxhc2gnLCBnYW1lLCBvcmlnaW5hbDogaW5mby5vcmlnaW5h
bCB9KTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgY29uc3QgYW5hbHlzaXMgPSBhbmFs
eXplWmlwKHppcC5lbnRyaWVzKTsKICAgICAgY29uc3Qgd3JpdHRlbiA9IGF3YWl0IHdyaXRlWmlw
KHJlY2VpdmVkLCBzbGltLCBhbmFseXNpcy5rZWVwKTsKICAgICAgYXdhaXQgZnNwLnJtKHBhdGgu
am9pbihkaXJlY3RvcnksIGAke2lkfS5zd2ZgKSwgeyBmb3JjZTogdHJ1ZSB9KTsKICAgICAgYXdh
aXQgZnNwLnJlbmFtZShzbGltLCBwYXRoLmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uemlwYCkpOwog
ICAgICBjb25zdCBpbmZvID0geyB0aXRsZSwgc2hhMjU2OiB3cml0dGVuLnNoYTI1NiwgZmlsZXM6
IHdyaXR0ZW4uZmlsZXMsIGV4ZWN1dGFibGU6IGFuYWx5c2lzLmV4ZWN1dGFibGUsCiAgICAgICAg
dXBsb2FkZWQ6IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKSwgb3JpZ2luYWw6IHsgc2l6ZTogYnl0
ZXMsIGZpbGVzOiB6aXAuZW50cmllcy5sZW5ndGggfSB9OwogICAgICBhd2FpdCBmc3Aud3JpdGVG
aWxlKHBhdGguam9pbihkaXJlY3RvcnksIGAke2lkfS5qc29uYCksIEpTT04uc3RyaW5naWZ5KGlu
Zm8sIG51bGwsIDIpKTsKICAgICAgYXdhaXQgZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVl
IH0pOwogICAgICBsb2coYHBhY2sgJHtpZH06ICR7Ynl0ZXN9IGJ5dGVzIHVwbG9hZGVkLCAke3dy
aXR0ZW4uc2l6ZX0ga2VwdCAoJHt3cml0dGVuLmZpbGVzfSBmaWxlcylgKTsKICAgICAganNvbihy
ZXMsIDIwMCwgeyBvazogdHJ1ZSwgaWQsIHRpdGxlLCBzaXplOiB3cml0dGVuLnNpemUsIHNoYTI1
Njogd3JpdHRlbi5zaGEyNTYsIGZpbGVzOiB3cml0dGVuLmZpbGVzLAogICAgICAgIGRyb3BwZWQ6
IGFuYWx5c2lzLmRyb3BwZWQsIGV4ZWN1dGFibGU6IGFuYWx5c2lzLmV4ZWN1dGFibGUsIG9yaWdp
bmFsOiBpbmZvLm9yaWdpbmFsIH0pOwogICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgYXdhaXQg
ZnNwLnJtKHJlY2VpdmVkLCB7IGZvcmNlOiB0cnVlIH0pOwogICAgICBhd2FpdCBmc3Aucm0oc2xp
bSwgeyBmb3JjZTogdHJ1ZSB9KTsKICAgICAgY29uc3QgbWVzc2FnZSA9IGVycm9yIGluc3RhbmNl
b2YgUGFja0Vycm9yID8gZXJyb3IubWVzc2FnZSA6ICdLaMO0bmcgbMawdSDEkcaw4bujYyBmaWxl
OiAnICsgKGVycm9yLm1lc3NhZ2UgfHwgZXJyb3IpOwogICAgICBpZiAoIXJlcy5oZWFkZXJzU2Vu
dCkganNvbihyZXMsIGVycm9yIGluc3RhbmNlb2YgUGFja0Vycm9yID8gNDAwIDogNTAwLCB7IGVy
cm9yOiBtZXNzYWdlIH0pOwogICAgfSBmaW5hbGx5IHsKICAgICAgdXBsb2FkaW5nID0gZmFsc2U7
CiAgICB9CiAgfQoKICBhc3luYyBmdW5jdGlvbiBzZXJ2ZVBhY2socmVxLCByZXMsIGlkLCBleHRl
bnNpb24gPSAnemlwJykgewogICAgY29uc3QgaGVhZGVycyA9IHsgJ3gtY29udGVudC10eXBlLW9w
dGlvbnMnOiAnbm9zbmlmZicsIC4uLmFsbG93T3JpZ2luKHJlcSkgfTsKICAgIGlmIChyZXEubWV0
aG9kICE9PSAnR0VUJyAmJiByZXEubWV0aG9kICE9PSAnSEVBRCcpIHsKICAgICAgcmVzLndyaXRl
SGVhZCg0MDUsIHsgLi4uaGVhZGVycywgYWxsb3c6ICdHRVQsIEhFQUQnIH0pOwogICAgICByZXMu
ZW5kKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGZpbGUgPSBwYXRoLmpvaW4oZGly
ZWN0b3J5IHx8ICcvbm9uZXhpc3RlbnQnLCBgJHtpZH0uJHtleHRlbnNpb259YCk7CiAgICBsZXQg
c3RhdDsKICAgIHRyeSB7IHN0YXQgPSBhd2FpdCBmc3Auc3RhdChmaWxlKTsgfSBjYXRjaCB7IHN0
YXQgPSBudWxsOyB9CiAgICBpZiAoIWRpcmVjdG9yeSB8fCAhc3RhdCB8fCAhc3RhdC5pc0ZpbGUo
KSkgewogICAgICByZXMud3JpdGVIZWFkKDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQoKTsK
ICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHJlcS5tZXRob2QgPT09ICdHRVQnKSB7CiAgICAg
IGNvbnN0IHF1b3RhID0gY291bnRlZChkb3dubG9hZHMsIGNsaWVudEFkZHJlc3MocmVxKSwgY29u
ZmlnLnBhY2tEb3dubG9hZHNQZXJIb3VyKTsKICAgICAgaWYgKHF1b3RhLm92ZXIpIHsKICAgICAg
ICByZXMud3JpdGVIZWFkKDQyOSwgeyAuLi5oZWFkZXJzLCAncmV0cnktYWZ0ZXInOiBTdHJpbmco
cXVvdGEucmV0cnkpIH0pOwogICAgICAgIHJlcy5lbmQoKTsKICAgICAgICByZXR1cm47CiAgICAg
IH0KICAgICAgcXVvdGEuYWRkKCk7CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAuLi5o
ZWFkZXJzLCAnY29udGVudC10eXBlJzogZXh0ZW5zaW9uID09PSAnc3dmJyA/ICdhcHBsaWNhdGlv
bi94LXNob2Nrd2F2ZS1mbGFzaCcgOiAnYXBwbGljYXRpb24vemlwJywKICAgICAgJ2NvbnRlbnQt
bGVuZ3RoJzogU3RyaW5nKHN0YXQuc2l6ZSksCiAgICAgICdjYWNoZS1jb250cm9sJzogJ25vLWNh
Y2hlJyB9KTsKICAgIGlmIChyZXEubWV0aG9kID09PSAnSEVBRCcpIHsKICAgICAgcmVzLmVuZCgp
OwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFkU3Ry
ZWFtKGZpbGUpOwogICAgc3RyZWFtLm9uKCdlcnJvcicsICgpID0+IHJlcy5kZXN0cm95KCkpOwog
ICAgc3RyZWFtLnBpcGUocmVzKTsKICB9CgogIC8vIFJldHVybnMgdHJ1ZSB3aGVuIHRoZSByZXF1
ZXN0IHdhcyBvbmUgb2YgdGhlIHBhY2tzJyBhbmQgaGFzIGJlZW4gYW5zd2VyZWQgKG9yIGlzIGJl
aW5nIGFuc3dlcmVkKS4KICBmdW5jdGlvbiBoYW5kbGUocmVxLCByZXMsIHBhdGhuYW1lKSB7CiAg
ICBpZiAocGF0aG5hbWUgPT09ICcvbGYyLXBhY2tzLmpzb24nKSB7CiAgICAgIGxpc3QoKS50aGVu
KChwYWNrcykgPT4ganNvbihyZXMsIDIwMCwgeyBwYWNrczogcGFja3MubWFwKCh7IGlkLCB0aXRs
ZSwgc2l6ZSwgc2hhMjU2LCBraW5kLCBnYW1lIH0pID0+ICh7IGlkLCB0aXRsZSwgc2l6ZSwgc2hh
MjU2LCBraW5kLCBnYW1lIH0pKSB9LAogICAgICAgIHsgJ2FjY2Vzcy1jb250cm9sLWFsbG93LW9y
aWdpbic6ICcqJyB9KSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgY29uc3QgcGFjayA9
IHBhdGhuYW1lLm1hdGNoKC9eXC9sZjItcGFja3NcLyhbYS16MC05XVthLXowLTktXXswLDM5fSlc
Lih6aXB8c3dmKSQvKTsKICAgIGlmIChwYWNrKSB7CiAgICAgIHNlcnZlUGFjayhyZXEsIHJlcywg
cGFja1sxXSwgcGFja1syXSkuY2F0Y2goKCkgPT4gcmVzLmRlc3Ryb3koKSk7CiAgICAgIHJldHVy
biB0cnVlOwogICAgfQogICAgaWYgKHBhdGhuYW1lID09PSAnL2FkbWluJyB8fCBwYXRobmFtZSA9
PT0gJy9hZG1pbi8nKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdjb250ZW50LXR5cGUn
OiAndGV4dC9odG1sOyBjaGFyc2V0PXV0Zi04JywgJ2NhY2hlLWNvbnRyb2wnOiAnbm8tc3RvcmUn
LAogICAgICAgICd4LWZyYW1lLW9wdGlvbnMnOiAnREVOWScsICdyZWZlcnJlci1wb2xpY3knOiAn
bm8tcmVmZXJyZXInIH0pOwogICAgICByZXMuZW5kKEFETUlOX1BBR0UpOwogICAgICByZXR1cm4g
dHJ1ZTsKICAgIH0KICAgIGlmIChwYXRobmFtZSA9PT0gJy9hZG1pbi9hcGkvcGFja3MnICYmIHJl
cS5tZXRob2QgPT09ICdHRVQnKSB7CiAgICAgIGlmIChhdXRob3JpemVkKHJlcSwgcmVzKSkgbGlz
dCgpLnRoZW4oKHBhY2tzKSA9PiBqc29uKHJlcywgMjAwLCB7IHBhY2tzLCBtYXhCeXRlczogY29u
ZmlnLm1heFBhY2tCeXRlcyB9KSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYgKHBh
dGhuYW1lID09PSAnL2FkbWluL2FwaS9oZi1qb3VybmFsJyAmJiByZXEubWV0aG9kID09PSAnR0VU
JykgewogICAgICAvLyBUaGUgSGVybyBGaWdodGVyIHJvb21zJyBqb3VybmFsIChoZi1yb29tLmpz
KTogd2hhdCBoYXBwZW5lZCBpbiB0aGVtIGxhdGVseSwgd2l0aCB0aGUgZGV0YWlscyBvZiBldmVy
eQogICAgICAvLyBmaWdodCB0aGF0IHdlbnQgb3V0IG9mIHN0ZXAsIGZvciBmaW5kaW5nIHRoZSBj
YXVzZS4KICAgICAgaWYgKGF1dGhvcml6ZWQocmVxLCByZXMpKSB7CiAgICAgICAgcmVzLndyaXRl
SGVhZCgyMDAsIHsgJ2NvbnRlbnQtdHlwZSc6ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04Jywg
J2NhY2hlLWNvbnRyb2wnOiAnbm8tc3RvcmUnIH0pOwogICAgICAgIHJlcy5lbmQoaGZKb3VybmFs
ID8gaGZKb3VybmFsKCkgOiAnbm8gSGVybyBGaWdodGVyIHJvb21zXG4nKTsKICAgICAgfQogICAg
ICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGNvbnN0IG1hbmFnZWQgPSBwYXRobmFtZS5tYXRjaCgv
XlwvYWRtaW5cL2FwaVwvcGFja3NcLyhbXi9dKikkLyk7CiAgICBpZiAobWFuYWdlZCkgewogICAg
ICBjb25zdCBpZCA9IG1hbmFnZWRbMV07CiAgICAgIGlmICghUEFDS19JRC50ZXN0KGlkKSkgewog
ICAgICAgIGpzb24ocmVzLCA0MDAsIHsgZXJyb3I6ICdNw6Mgbmfhuq9uIGNo4buJIGfhu5NtIGNo
4buvIHRoxrDhu51uZyBhLXosIHPhu5EgdsOgIGThuqV1IGfhuqFjaCBuZ2FuZyAodOG7kWkgxJFh
IDQwIGvDvSB04buxKS4nIH0pOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAgICAgIGlm
IChyZXEubWV0aG9kID09PSAnUFVUJykgewogICAgICAgIGlmICghYXV0aG9yaXplZChyZXEsIHJl
cykpIHsgcmVxLnJlc3VtZSgpOyByZXR1cm4gdHJ1ZTsgfQogICAgICAgIGNvbnN0IHRpdGxlID0g
U3RyaW5nKG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9yZWxheS5pbnZhbGlkJykuc2VhcmNoUGFy
YW1zLmdldCgndGl0bGUnKSB8fCBpZCkudHJpbSgpLnNsaWNlKDAsIDYwKSB8fCBpZDsKICAgICAg
ICB1cGxvYWQocmVxLCByZXMsIGlkLCB0aXRsZSkuY2F0Y2goKCkgPT4gcmVzLmRlc3Ryb3koKSk7
CiAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgIH0KICAgICAgaWYgKHJlcS5tZXRob2QgPT09ICdE
RUxFVEUnKSB7CiAgICAgICAgaWYgKCFhdXRob3JpemVkKHJlcSwgcmVzKSkgcmV0dXJuIHRydWU7
CiAgICAgICAgUHJvbWlzZS5hbGwoW2Ake2lkfS56aXBgLCBgJHtpZH0uc3dmYCwgYCR7aWR9Lmpz
b25gXS5tYXAoKG5hbWUpID0+IGZzcC5ybShwYXRoLmpvaW4oZGlyZWN0b3J5IHx8ICcvbm9uZXhp
c3RlbnQnLCBuYW1lKSwgeyBmb3JjZTogdHJ1ZSB9KSkpCiAgICAgICAgICAudGhlbigoKSA9PiB7
IGxvZyhgcGFjayAke2lkfTogcmVtb3ZlZGApOyBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlIH0p
OyB9KQogICAgICAgICAgLmNhdGNoKChlcnJvcikgPT4ganNvbihyZXMsIDUwMCwgeyBlcnJvcjog
U3RyaW5nKGVycm9yLm1lc3NhZ2UgfHwgZXJyb3IpIH0pKTsKICAgICAgICByZXR1cm4gdHJ1ZTsK
ICAgICAgfQogICAgICBqc29uKHJlcywgNDA1LCB7IGVycm9yOiAnbWV0aG9kIG5vdCBhbGxvd2Vk
JyB9LCB7IGFsbG93OiAnUFVULCBERUxFVEUnIH0pOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0K
ICAgIHJldHVybiBmYWxzZTsKICB9CgogIHJldHVybiB7IGhhbmRsZSwgbGlzdCwgY2xlYW51cDog
KCkgPT4gewogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAoY29uc3QgbWFwIG9m
IFtkb3dubG9hZHMsIGZhaWx1cmVzXSkgZm9yIChjb25zdCBba2V5LCBlbnRyeV0gb2YgbWFwKSBp
ZiAoZW50cnkudW50aWwgPD0gbm93KSBtYXAuZGVsZXRlKGtleSk7CiAgfSB9Owp9CgovLyBUaGUg
cGFnZSBhdCAvYWRtaW4gKFZpZXRuYW1lc2U6IHRoZSByZWxheSdzIG93bmVyIHJlYWRzIGl0KS4K
Y29uc3QgQURNSU5fUEFHRSA9IGA8IWRvY3R5cGUgaHRtbD4KPGh0bWwgbGFuZz0idmkiPjxoZWFk
PjxtZXRhIGNoYXJzZXQ9InV0Zi04Ij48bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lk
dGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+T3BlbkxGMiByZWxheTog
YuG6o24gbW9kPC90aXRsZT4KPHN0eWxlPgogIGJvZHkgeyBtYXJnaW46IDA7IHBhZGRpbmc6IDEu
NXJlbTsgYmFja2dyb3VuZDogIzExMTgyNzsgY29sb3I6ICNmM2Y0ZjY7IGZvbnQ6IDE2cHgvMS41
IHN5c3RlbS11aSwgc2Fucy1zZXJpZjsgfQogIG1haW4geyBtYXgtd2lkdGg6IDc2MHB4OyBtYXJn
aW46IGF1dG87IH0KICBoMSB7IGZvbnQtc2l6ZTogMS41cmVtOyBtYXJnaW46IDAgMCAuMjVyZW07
IH0KICAuY2FyZCB7IGJhY2tncm91bmQ6ICMxZjI5Mzc7IGJvcmRlcjogMXB4IHNvbGlkICMzNzQx
NTE7IGJvcmRlci1yYWRpdXM6IDEycHg7IHBhZGRpbmc6IDFyZW0gMS4ycmVtOyBtYXJnaW46IDFy
ZW0gMDsgfQogIGxhYmVsIHsgZGlzcGxheTogYmxvY2s7IG1hcmdpbjogLjZyZW0gMCAuMnJlbTsg
Zm9udC13ZWlnaHQ6IDYwMDsgfQogIGlucHV0W3R5cGU9dGV4dF0sIGlucHV0W3R5cGU9cGFzc3dv
cmRdIHsgd2lkdGg6IDEwMCU7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IHBhZGRpbmc6IC41cmVt
IC42cmVtOyBmb250OiBpbmhlcml0OwogICAgYm9yZGVyLXJhZGl1czogOHB4OyBib3JkZXI6IDFw
eCBzb2xpZCAjNGI1NTYzOyBiYWNrZ3JvdW5kOiAjMGIxMjIwOyBjb2xvcjogaW5oZXJpdDsgfQog
IGJ1dHRvbiB7IHBhZGRpbmc6IC41NXJlbSAxLjFyZW07IGZvbnQ6IGluaGVyaXQ7IGJvcmRlci1y
YWRpdXM6IDhweDsgYm9yZGVyOiAwOyBjdXJzb3I6IHBvaW50ZXI7IGJhY2tncm91bmQ6ICNmNTll
MGI7IGNvbG9yOiAjMWYxMzAwOyBmb250LXdlaWdodDogNzAwOyB9CiAgYnV0dG9uLnNlY29uZGFy
eSB7IGJhY2tncm91bmQ6ICMzNzQxNTE7IGNvbG9yOiAjZjNmNGY2OyBmb250LXdlaWdodDogNTAw
OyB9CiAgYnV0dG9uOmRpc2FibGVkIHsgb3BhY2l0eTogLjU7IGN1cnNvcjogZGVmYXVsdDsgfQog
IHByb2dyZXNzIHsgd2lkdGg6IDEwMCU7IGhlaWdodDogLjhyZW07IG1hcmdpbi10b3A6IC44cmVt
OyB9CiAgLm5vdGUgeyBjb2xvcjogIzljYTNhZjsgZm9udC1zaXplOiAuOXJlbTsgfQogIC5vayB7
IGNvbG9yOiAjNmVlN2I3OyB9IC5iYWQgeyBjb2xvcjogI2ZjYTVhNTsgfQogIHRhYmxlIHsgd2lk
dGg6IDEwMCU7IGJvcmRlci1jb2xsYXBzZTogY29sbGFwc2U7IH0gdGQsIHRoIHsgdGV4dC1hbGln
bjogbGVmdDsgcGFkZGluZzogLjRyZW0gLjNyZW07IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCAj
Mzc0MTUxOyB2ZXJ0aWNhbC1hbGlnbjogdG9wOyB9CiAgY29kZSB7IGJhY2tncm91bmQ6ICMwYjEy
MjA7IHBhZGRpbmc6IC4wNXJlbSAuM3JlbTsgYm9yZGVyLXJhZGl1czogNHB4OyB9Cjwvc3R5bGU+
PC9oZWFkPgo8Ym9keT48bWFpbj4KICA8aDE+QuG6o24gbW9kIGNobyBPcGVuTEYyPC9oMT4KICA8
cCBjbGFzcz0ibm90ZSI+VOG6o2kgbMOqbiBt4buZdCBmaWxlIC56aXAgY2jhu6lhIGPhuqMgdGjG
sCBt4bulYyBnYW1lIGPhu6dhIGLhuqNuIG1vZCAoY8OzIGZpbGUgLmV4ZSB2w6AgdGjGsCBt4bul
YyBkYXRhLCBzcHJpdGUsIGJnbSwgYmcpLgogICAgUmVsYXkgY2jhu4kgZ2nhu68gbOG6oWkgcGjh
uqduIGdhbWUgY+G6p24sIHLhu5NpIHBow6F0IGNobyB0csOsbmggZHV54buHdCBj4bunYSBuZ8aw
4budaSBjaMahaS4gQWkgY8WpbmcgY2jhu41uIGPDuW5nIG3hu5l0IGLhuqNuIG1vZCBt4bubaSB2
w6BvIGNodW5nIHBow7JuZyDEkcaw4bujYy48L3A+CiAgPHAgY2xhc3M9Im5vdGUiPkdhbWUgSGVy
byBGaWdodGVyIGPFqW5nIHThuqNpIGzDqm4g4bufIMSRw6J5OiBmaWxlIDxjb2RlPkhGdjAuNy56
aXA8L2NvZGU+IChob+G6t2MgPGNvZGU+SEZ2MC43Ky5leGU8L2NvZGU+KS4gUmVsYXkgZ2nhu68g
cGjhuqduIGdhbWUgRmxhc2ggYsOqbiB0cm9uZzsKICAgIHRyw6puIHRyYW5nIGdhbWUsIGNo4buN
biA8Yj5IZXJvIEZpZ2h0ZXI8L2I+IOG7nyBt4bulYyBHYW1lLjwvcD4KICA8ZGl2IGNsYXNzPSJj
YXJkIj4KICAgIDxsYWJlbCBmb3I9ImtleSI+TcOjIHF14bqjbiB0cuG7iyAoQURNSU5fS0VZKTwv
bGFiZWw+CiAgICA8aW5wdXQgaWQ9ImtleSIgdHlwZT0icGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0i
Y3VycmVudC1wYXNzd29yZCIgcGxhY2Vob2xkZXI9ImluIHJhIGtoaSBjaOG6oXkgaW5zdGFsbC12
cHMuc2giPgogICAgPGxhYmVsIGZvcj0iZmlsZSI+RmlsZSAuemlwIGPhu6dhIGLhuqNuIG1vZDwv
bGFiZWw+CiAgICA8aW5wdXQgaWQ9ImZpbGUiIHR5cGU9ImZpbGUiIGFjY2VwdD0iLnppcCwuZXhl
LC5zd2YsYXBwbGljYXRpb24vemlwIj4KICAgIDxsYWJlbCBmb3I9InRpdGxlIj5Uw6puIGhp4buD
biB0aOG7iyB0csOqbiB0cmFuZyBnYW1lPC9sYWJlbD4KICAgIDxpbnB1dCBpZD0idGl0bGUiIHR5
cGU9InRleHQiIG1heGxlbmd0aD0iNjAiIHBsYWNlaG9sZGVyPSJ2w60gZOG7pTogT25lIFBpZWNl
IEdyYW5kV29ybGQiPgogICAgPGxhYmVsIGZvcj0iaWQiPk3DoyBuZ+G6r24gKGTDuW5nIHRyb25n
IGxpbmsgbeG7nWkpPC9sYWJlbD4KICAgIDxpbnB1dCBpZD0iaWQiIHR5cGU9InRleHQiIG1heGxl
bmd0aD0iNDAiIHBsYWNlaG9sZGVyPSJ2w60gZOG7pTogb25lcGllY2UiIHBhdHRlcm49IlthLXow
LTldW2EtejAtOS1dKiI+CiAgICA8cD48YnV0dG9uIGlkPSJ1cGxvYWQiPlThuqNpIGzDqm48L2J1
dHRvbj48L3A+CiAgICA8cHJvZ3Jlc3MgaWQ9InByb2dyZXNzIiBoaWRkZW4+PC9wcm9ncmVzcz4K
ICAgIDxwIGlkPSJzdGF0dXMiIHJvbGU9InN0YXR1cyIgY2xhc3M9Im5vdGUiPjwvcD4KICA8L2Rp
dj4KICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgIDxoMiBzdHlsZT0iZm9udC1zaXplOjEuMTVyZW07
bWFyZ2luOjAgMCAuNXJlbSI+Q8OhYyBi4bqjbiBtb2QgdHLDqm4gcmVsYXk8L2gyPgogICAgPHA+
PGJ1dHRvbiBpZD0icmVmcmVzaCIgY2xhc3M9InNlY29uZGFyeSI+WGVtIGRhbmggc8OhY2g8L2J1
dHRvbj48L3A+CiAgICA8dGFibGU+PHRib2R5IGlkPSJsaXN0Ij48L3Rib2R5PjwvdGFibGU+CiAg
PC9kaXY+CiAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICA8aDIgc3R5bGU9ImZvbnQtc2l6ZToxLjE1
cmVtO21hcmdpbjowIDAgLjVyZW0iPk5o4bqtdCBrw70gcGjDsm5nIEhlcm8gRmlnaHRlcjwvaDI+
CiAgICA8cCBjbGFzcz0ibm90ZSI+QWkgdsOgby9yYSBwaMOybmcsIHRy4bqtbiBuw6BvIGLhuq90
IMSR4bqndSB2w6Aga+G6v3QgdGjDumMsIGFpIHThuqFtIGThu6tuZywgdsOgIGtoaSBoYWkgbcOh
eSBs4buHY2ggbmhhdSAoZGVzeW5jKSB0aMOsIG3hu41pIHRo4bupIGhhaSBnYW1lCiAgICAgIMSR
w6MgYsOhbyBxdWFuaCBraHVuZyBow6xuaCDEkcOzLiBLaGkgZ+G6t3AgbOG7l2kgZGVzeW5jLCBi
4bqlbSB4ZW0gcuG7k2kgY2jDqXAgdG/DoG4gYuG7mSBu4buZaSBkdW5nIGfhu61pIGNobyBuZ8aw
4budaSBsw6BtIHdlYi48L3A+CiAgICA8cD48YnV0dG9uIGlkPSJqb3VybmFsIiBjbGFzcz0ic2Vj
b25kYXJ5Ij5YZW0gbmjhuq10IGvDvTwvYnV0dG9uPiA8YnV0dG9uIGlkPSJjb3B5am91cm5hbCIg
Y2xhc3M9InNlY29uZGFyeSIgaGlkZGVuPkNow6lwIG7hu5lpIGR1bmc8L2J1dHRvbj48L3A+CiAg
ICA8cHJlIGlkPSJqb3VybmFsdGV4dCIgc3R5bGU9IndoaXRlLXNwYWNlOnByZS13cmFwO2ZvbnQt
c2l6ZTouOHJlbTttYXgtaGVpZ2h0OjYwdmg7b3ZlcmZsb3c6YXV0bztiYWNrZ3JvdW5kOiMwYjEy
MjA7cGFkZGluZzouNnJlbTtib3JkZXItcmFkaXVzOjhweCIgaGlkZGVuPjwvcHJlPgogIDwvZGl2
Pgo8L21haW4+CjxzY3JpcHQ+CiAgY29uc3QgJCA9IChpZCkgPT4gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoaWQpOwogIGNvbnN0IGFwaSA9IGxvY2F0aW9uLnBhdGhuYW1lLnJlcGxhY2UoL1xcLz8k
LywgJy8nKSArICdhcGkvcGFja3MnOwogIHRyeSB7ICQoJ2tleScpLnZhbHVlID0gbG9jYWxTdG9y
YWdlLmdldEl0ZW0oJ2xmMi1hZG1pbi1rZXknKSB8fCAnJzsgfSBjYXRjaCAoZXJyb3IpIHt9CiAg
Y29uc3QgcmVtZW1iZXIgPSAoKSA9PiB7IHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdsZjIt
YWRtaW4ta2V5JywgJCgna2V5JykudmFsdWUpOyB9IGNhdGNoIChlcnJvcikge30gfTsKICBjb25z
dCBzbHVnID0gKHRleHQpID0+IHRleHQudG9Mb3dlckNhc2UoKS5ub3JtYWxpemUoJ05GRCcpLnJl
cGxhY2UoL1tcXHUwMzAwLVxcdTAzNmZdL2csICcnKS5yZXBsYWNlKC/EkS9nLCAnZCcpCiAgICAu
cmVwbGFjZSgvW15hLXowLTldKy9nLCAnLScpLnJlcGxhY2UoL14tK3wtKyQvZywgJycpLnNsaWNl
KDAsIDQwKSB8fCAnbW9kJzsKICAkKCdmaWxlJykuYWRkRXZlbnRMaXN0ZW5lcignY2hhbmdlJywg
KCkgPT4gewogICAgY29uc3QgZmlsZSA9ICQoJ2ZpbGUnKS5maWxlc1swXTsKICAgIGlmICghZmls
ZSkgcmV0dXJuOwogICAgbGV0IG5hbWUgPSBmaWxlLm5hbWUucmVwbGFjZSgvXFwuKHppcHxleGV8
c3dmKSQvaSwgJycpLnJlcGxhY2UoL1tfXSsvZywgJyAnKS50cmltKCk7CiAgICBpZiAoL15oZiA/
dj8wXFwuNy9pLnRlc3QobmFtZSkpIG5hbWUgPSAnSGVybyBGaWdodGVyIHYwLjcrJzsKICAgIGlm
ICghJCgndGl0bGUnKS52YWx1ZSkgJCgndGl0bGUnKS52YWx1ZSA9IG5hbWU7CiAgICBpZiAoISQo
J2lkJykudmFsdWUpICQoJ2lkJykudmFsdWUgPSBzbHVnKG5hbWUpOwogIH0pOwogICQoJ3RpdGxl
JykuYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQnLCAoKSA9PiB7IGlmICghJCgnaWQnKS5kYXRhc2V0
LnRvdWNoZWQpICQoJ2lkJykudmFsdWUgPSBzbHVnKCQoJ3RpdGxlJykudmFsdWUpOyB9KTsKICAk
KCdpZCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4geyAkKCdpZCcpLmRhdGFzZXQu
dG91Y2hlZCA9ICcxJzsgfSk7CiAgY29uc3QgbWIgPSAoYnl0ZXMpID0+IChieXRlcyAvIDFlNiku
dG9GaXhlZCgxKSArICcgTUInOwogIGZ1bmN0aW9uIHN0YXR1cyh0ZXh0LCBraW5kKSB7ICQoJ3N0
YXR1cycpLnRleHRDb250ZW50ID0gdGV4dDsgJCgnc3RhdHVzJykuY2xhc3NOYW1lID0ga2luZCB8
fCAnbm90ZSc7IH0KICAkKCd1cGxvYWQnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+
IHsKICAgIGNvbnN0IGZpbGUgPSAkKCdmaWxlJykuZmlsZXNbMF07CiAgICBjb25zdCBpZCA9ICQo
J2lkJykudmFsdWUudHJpbSgpOwogICAgaWYgKCEkKCdrZXknKS52YWx1ZSkgcmV0dXJuIHN0YXR1
cygnTmjhuq1wIG3DoyBxdeG6o24gdHLhu4sgdHLGsOG7m2MuJywgJ2JhZCcpOwogICAgaWYgKCFm
aWxlKSByZXR1cm4gc3RhdHVzKCdDaOG7jW4gZmlsZSAuemlwIHRyxrDhu5tjLicsICdiYWQnKTsK
ICAgIGlmICghL15bYS16MC05XVthLXowLTktXXswLDM5fSQvLnRlc3QoaWQpKSByZXR1cm4gc3Rh
dHVzKCdNw6Mgbmfhuq9uIGNo4buJIGfhu5NtIGNo4buvIHRoxrDhu51uZyBhLXosIHPhu5EgdsOg
IGThuqV1IGfhuqFjaCBuZ2FuZy4nLCAnYmFkJyk7CiAgICByZW1lbWJlcigpOwogICAgY29uc3Qg
cmVxdWVzdCA9IG5ldyBYTUxIdHRwUmVxdWVzdCgpOwogICAgcmVxdWVzdC5vcGVuKCdQVVQnLCBh
cGkgKyAnLycgKyBpZCArICc/dGl0bGU9JyArIGVuY29kZVVSSUNvbXBvbmVudCgkKCd0aXRsZScp
LnZhbHVlLnRyaW0oKSB8fCBpZCkpOwogICAgcmVxdWVzdC5zZXRSZXF1ZXN0SGVhZGVyKCd4LWFk
bWluLWtleScsICQoJ2tleScpLnZhbHVlKTsKICAgIHJlcXVlc3Quc2V0UmVxdWVzdEhlYWRlcign
Y29udGVudC10eXBlJywgJ2FwcGxpY2F0aW9uL3ppcCcpOwogICAgJCgncHJvZ3Jlc3MnKS5oaWRk
ZW4gPSBmYWxzZTsKICAgICQoJ3VwbG9hZCcpLmRpc2FibGVkID0gdHJ1ZTsKICAgIHJlcXVlc3Qu
dXBsb2FkLm9ucHJvZ3Jlc3MgPSAoZXZlbnQpID0+IHsKICAgICAgaWYgKCFldmVudC5sZW5ndGhD
b21wdXRhYmxlKSByZXR1cm47CiAgICAgICQoJ3Byb2dyZXNzJykubWF4ID0gZXZlbnQudG90YWw7
CiAgICAgICQoJ3Byb2dyZXNzJykudmFsdWUgPSBldmVudC5sb2FkZWQ7CiAgICAgIHN0YXR1cygn
xJBhbmcgdOG6o2kgbMOqbjogJyArIG1iKGV2ZW50LmxvYWRlZCkgKyAnIC8gJyArIG1iKGV2ZW50
LnRvdGFsKSArIChldmVudC5sb2FkZWQgPT09IGV2ZW50LnRvdGFsID8gJyAocmVsYXkgxJFhbmcg
eOG7rSBsw70uLi4pJyA6ICcnKSk7CiAgICB9OwogICAgcmVxdWVzdC5vbmxvYWQgPSAoKSA9PiB7
CiAgICAgICQoJ3VwbG9hZCcpLmRpc2FibGVkID0gZmFsc2U7CiAgICAgICQoJ3Byb2dyZXNzJyku
aGlkZGVuID0gdHJ1ZTsKICAgICAgbGV0IGJvZHkgPSB7fTsKICAgICAgdHJ5IHsgYm9keSA9IEpT
T04ucGFyc2UocmVxdWVzdC5yZXNwb25zZVRleHQpOyB9IGNhdGNoIChlcnJvcikge30KICAgICAg
aWYgKHJlcXVlc3Quc3RhdHVzID09PSAyMDApIHsKICAgICAgICBpZiAoYm9keS5raW5kID09PSAn
Zmxhc2gnKSB7CiAgICAgICAgICBzdGF0dXMoJ1hvbmc6ICInICsgYm9keS50aXRsZSArICciIChn
YW1lIEZsYXNoLCAnICsgbWIoYm9keS5zaXplKSArICcpLiAnCiAgICAgICAgICAgICsgKGJvZHku
Z2FtZSA9PT0gJ2hlcm9maWdodGVyJyA/ICdUcsOqbiB0cmFuZyBnYW1lLCBjaOG7jW4gSGVybyBG
aWdodGVyIOG7nyBt4bulYyBHYW1lLicgOiAnxJDDonkga2jDtG5nIHBo4bqjaSBIZXJvIEZpZ2h0
ZXI6IHRyYW5nIGdhbWUgY2jGsGEgY2jGoWkgxJHGsOG7o2MgZ2FtZSBuw6B5LicpLCBib2R5Lmdh
bWUgPyAnb2snIDogJ2JhZCcpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBzdGF0dXMoJ1hv
bmc6ICInICsgYm9keS50aXRsZSArICciICgnICsgbWIoYm9keS5zaXplKSArICcsICcgKyBib2R5
LmZpbGVzICsgJyBmaWxlLCBi4buPIGLhu5t0ICcgKyBib2R5LmRyb3BwZWQgKyAnIGZpbGUga2jD
tG5nIGPhuqduKS4gJwogICAgICAgICAgICArICdUcsOqbiB0cmFuZyBnYW1lLCBjaOG7jW4gbsOz
IOG7nyBt4bulYyBHYW1lLCBob+G6t2MgZ+G7rWkgbGluayBt4budaSBjw7MgdGjDqm0gJnBhY2s9
JyArIGJvZHkuaWQgKyAnLicsICdvaycpOwogICAgICAgIH0KICAgICAgICByZWZyZXNoKCk7CiAg
ICAgIH0gZWxzZSBzdGF0dXMoJ0tow7RuZyDEkcaw4bujYzogJyArIChib2R5LmVycm9yIHx8ICgn
bOG7l2kgJyArIHJlcXVlc3Quc3RhdHVzKSksICdiYWQnKTsKICAgIH07CiAgICByZXF1ZXN0Lm9u
ZXJyb3IgPSAoKSA9PiB7ICQoJ3VwbG9hZCcpLmRpc2FibGVkID0gZmFsc2U7ICQoJ3Byb2dyZXNz
JykuaGlkZGVuID0gdHJ1ZTsgc3RhdHVzKCdN4bqldCBr4bq/dCBu4buRaSBraGkgdOG6o2kgbMOq
bi4nLCAnYmFkJyk7IH07CiAgICByZXF1ZXN0LnNlbmQoZmlsZSk7CiAgfSk7CiAgYXN5bmMgZnVu
Y3Rpb24gcmVmcmVzaCgpIHsKICAgIGlmICghJCgna2V5JykudmFsdWUpIHJldHVybiBzdGF0dXMo
J05o4bqtcCBtw6MgcXXhuqNuIHRy4buLIMSR4buDIHhlbSBkYW5oIHPDoWNoLicsICdiYWQnKTsK
ICAgIHJlbWVtYmVyKCk7CiAgICBjb25zdCByZXNwb25zZSA9IGF3YWl0IGZldGNoKGFwaSwgeyBo
ZWFkZXJzOiB7ICd4LWFkbWluLWtleSc6ICQoJ2tleScpLnZhbHVlIH0gfSk7CiAgICBjb25zdCBi
b2R5ID0gYXdhaXQgcmVzcG9uc2UuanNvbigpLmNhdGNoKCgpID0+ICh7fSkpOwogICAgaWYgKCFy
ZXNwb25zZS5vaykgcmV0dXJuIHN0YXR1cyhib2R5LmVycm9yIHx8ICgnbOG7l2kgJyArIHJlc3Bv
bnNlLnN0YXR1cyksICdiYWQnKTsKICAgIGNvbnN0IGxpc3QgPSAkKCdsaXN0Jyk7CiAgICBsaXN0
LnRleHRDb250ZW50ID0gJyc7CiAgICBpZiAoIWJvZHkucGFja3MubGVuZ3RoKSBsaXN0LmlubmVy
SFRNTCA9ICc8dHI+PHRkIGNsYXNzPSJub3RlIj5DaMawYSBjw7MgYuG6o24gbW9kIG7DoG8uPC90
ZD48L3RyPic7CiAgICBmb3IgKGNvbnN0IHBhY2sgb2YgYm9keS5wYWNrcykgewogICAgICBjb25z
dCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd0cicpOwogICAgICBjb25zdCBpbmZvID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgndGQnKTsKICAgICAgaW5mby5pbm5lckhUTUwgPSAnPGI+
PC9iPjxicj48c3BhbiBjbGFzcz0ibm90ZSI+PC9zcGFuPic7CiAgICAgIGluZm8ucXVlcnlTZWxl
Y3RvcignYicpLnRleHRDb250ZW50ID0gcGFjay50aXRsZTsKICAgICAgaW5mby5xdWVyeVNlbGVj
dG9yKCdzcGFuJykudGV4dENvbnRlbnQgPSAnbcOjOiAnICsgcGFjay5pZCArICcgwrcgJyArIG1i
KHBhY2suc2l6ZSkgKyAnIMK3IHThuqNpIGzDqm4gJyArIG5ldyBEYXRlKHBhY2sudXBsb2FkZWQp
LnRvTG9jYWxlU3RyaW5nKCk7CiAgICAgIGNvbnN0IGFjdGlvbnMgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCd0ZCcpOwogICAgICBjb25zdCByZW1vdmUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50
KCdidXR0b24nKTsKICAgICAgcmVtb3ZlLmNsYXNzTmFtZSA9ICdzZWNvbmRhcnknOwogICAgICBy
ZW1vdmUudGV4dENvbnRlbnQgPSAnWMOzYSc7CiAgICAgIHJlbW92ZS5vbmNsaWNrID0gYXN5bmMg
KCkgPT4gewogICAgICAgIGlmICghY29uZmlybSgnWMOzYSAiJyArIHBhY2sudGl0bGUgKyAnIiBr
aOG7j2kgcmVsYXk/JykpIHJldHVybjsKICAgICAgICBjb25zdCByZXN1bHQgPSBhd2FpdCBmZXRj
aChhcGkgKyAnLycgKyBwYWNrLmlkLCB7IG1ldGhvZDogJ0RFTEVURScsIGhlYWRlcnM6IHsgJ3gt
YWRtaW4ta2V5JzogJCgna2V5JykudmFsdWUgfSB9KTsKICAgICAgICBpZiAocmVzdWx0Lm9rKSBy
ZWZyZXNoKCk7IGVsc2Ugc3RhdHVzKCdLaMO0bmcgeMOzYSDEkcaw4bujYyAobOG7l2kgJyArIHJl
c3VsdC5zdGF0dXMgKyAnKS4nLCAnYmFkJyk7CiAgICAgIH07CiAgICAgIGFjdGlvbnMuYXBwZW5k
Q2hpbGQocmVtb3ZlKTsKICAgICAgcm93LmFwcGVuZChpbmZvLCBhY3Rpb25zKTsKICAgICAgbGlz
dC5hcHBlbmRDaGlsZChyb3cpOwogICAgfQogIH0KICAkKCdyZWZyZXNoJykuYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCByZWZyZXNoKTsKICAkKCdqb3VybmFsJykuYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBhc3luYyAoKSA9PiB7CiAgICBpZiAoISQoJ2tleScpLnZhbHVlKSByZXR1cm4gc3Rh
dHVzKCdOaOG6rXAgbcOjIHF14bqjbiB0cuG7iyDEkeG7gyB4ZW0gbmjhuq10IGvDvS4nLCAnYmFk
Jyk7CiAgICByZW1lbWJlcigpOwogICAgY29uc3QgcmVzcG9uc2UgPSBhd2FpdCBmZXRjaChsb2Nh
dGlvbi5wYXRobmFtZS5yZXBsYWNlKC9cXC8/JC8sICcvJykgKyAnYXBpL2hmLWpvdXJuYWwnLCB7
IGhlYWRlcnM6IHsgJ3gtYWRtaW4ta2V5JzogJCgna2V5JykudmFsdWUgfSB9KTsKICAgIGNvbnN0
IHRleHQgPSBhd2FpdCByZXNwb25zZS50ZXh0KCk7CiAgICBpZiAoIXJlc3BvbnNlLm9rKSByZXR1
cm4gc3RhdHVzKCdLaMO0bmcgeGVtIMSRxrDhu6NjIG5o4bqtdCBrw70gKGzhu5dpICcgKyByZXNw
b25zZS5zdGF0dXMgKyAnKS4nLCAnYmFkJyk7CiAgICAkKCdqb3VybmFsdGV4dCcpLnRleHRDb250
ZW50ID0gdGV4dDsKICAgICQoJ2pvdXJuYWx0ZXh0JykuaGlkZGVuID0gZmFsc2U7CiAgICAkKCdj
b3B5am91cm5hbCcpLmhpZGRlbiA9IGZhbHNlOwogIH0pOwogICQoJ2NvcHlqb3VybmFsJykuYWRk
RXZlbnRMaXN0ZW5lcignY2xpY2snLCBhc3luYyAoKSA9PiB7CiAgICB0cnkgeyBhd2FpdCBuYXZp
Z2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCgkKCdqb3VybmFsdGV4dCcpLnRleHRDb250ZW50KTsg
c3RhdHVzKCfEkMOjIGNow6lwIG5o4bqtdCBrw70gdsOgbyBi4buZIG5o4bubIHThuqFtLicsICdv
aycpOyB9CiAgICBjYXRjaCAoZXJyb3IpIHsgc3RhdHVzKCdLaMO0bmcgY2jDqXAgxJHGsOG7o2M6
IGNo4buNbiBu4buZaSBkdW5nIGLhurFuZyBjaHXhu5l0IHLhu5NpIEN0cmwrQy4nLCAnYmFkJyk7
IH0KICB9KTsKPC9zY3JpcHQ+CjwvYm9keT48L2h0bWw+CmA7Cgptb2R1bGUuZXhwb3J0cyA9IHsg
Y3JlYXRlUGFja3MsIHJlYWRaaXAsIGFuYWx5emVaaXAsIHdyaXRlWmlwLCBtb3ZpZU9mLCBmbGFz
aEdhbWUsIFBhY2tFcnJvciwgUEFDS19JRCB9Owo=
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
dGVkLCAwKSB9KSwKICAgIC8vIFRoZSByb29tcycgam91cm5hbHMgKGpvaW5zLCBmaWdodHMsIHBh
dXNlcywgb3V0LW9mLXN0ZXAgZHVtcHMpLCBuZXdlc3Qgcm9vbSBlbnRyaWVzIGxhc3QsIGFzIHRl
eHQuCiAgICBqb3VybmFsOiAoKSA9PiByb29tcy5tYXAoKHJvb20pID0+IGA9PSAke3Jvb20ubmFt
ZX0gKCR7cm9vbS5jb25uZWN0ZWR9IHBsYXlpbmcpXG4ke3Jvb20uam91cm5hbC5qb2luKCdcbicp
IHx8ICcobm90aGluZyB5ZXQpJ31gKS5qb2luKCdcblxuJykgKyAnXG4nLAogICAgY2xvc2UoKSB7
CiAgICAgIGNsZWFySW50ZXJ2YWwocHJ1bmVUaW1lcik7CiAgICAgIGZvciAoY29uc3Qgcm9vbSBv
ZiByb29tcykgcm9vbS5jbG9zZSgpOwogICAgICBhY2NvdW50cy5mbHVzaCgpOwogICAgfSwKICB9
Owp9CgovLyBUaGUgYWRkcmVzcyB0aGUgZ2FtZSBpcyBnaXZlbiBmb3IgdGhlIHJvb21zOiBhbnkg
bmFtZSB3b3JrcywgdGhlIHBhZ2UncyBzb2NrZXQgcHJveHkgbWFwcyBpdCAod2l0aAovLyB0aGUg
cG9ydCwgb25lIHBlciByb29tKSB0byB0aGUgcmVsYXkncyBXZWJTb2NrZXQuCmNvbnN0IEhPU1Qg
PSAnaGYub3BlbmxmMic7CmNvbnN0IFBPUlQgPSA4ODg4OwoKbW9kdWxlLmV4cG9ydHMgPSB7IGNy
ZWF0ZUhmLCBzdGF0dXNDb2RlLCBlbmNvZGVOdW1iZXIsIHNldHRsZWRWYWx1ZXMsIExPQ0tFRCwg
SE9TVCwgUE9SVCB9Owo=
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
Y3RpdmU6IDAsCiAgICBzdGVwczogW10sIHRpbWVzOiBbXSwgLy8gd2hhdCB0aGlzIGdhbWUgcmVw
b3J0ZWQgbGF0ZWx5OiBbZnJhbWUsIHJhbmRvbSBudW1iZXJzIHVzZWRdIGV2ZXJ5IDIwIGZyYW1l
cywgYW5kIGl0cyA8dD4gdmFsdWVzCiAgICBhZG1pbjogZmFsc2UsIGZsdXNoZXM6IDAsCiAgfTsK
fQoKY29uc3Qgc2xlZXAgPSAobXMpID0+IG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiBzZXRUaW1l
b3V0KHJlc29sdmUsIG1zKSk7CgpjbGFzcyBIZlJvb20gewogIGNvbnN0cnVjdG9yKHsgbnVtYmVy
LCBuYW1lLCBkZXNjcmlwdGlvbiA9ICcnLCBjYyA9ICdWTicsIGxpbWl0ID0gQ0xJRU5UUywgcmFu
ZG9tID0gTWF0aC5yYW5kb20sIGxvZyA9ICgpID0+IHt9IH0pIHsKICAgIHRoaXMubnVtYmVyID0g
bnVtYmVyOwogICAgdGhpcy5uYW1lID0gbmFtZTsgLy8gTWFpbi56CiAgICB0aGlzLmRlc2NyaXB0
aW9uID0gZGVzY3JpcHRpb247IC8vIE1haW4uQQogICAgdGhpcy5jYyA9IGNjOyAvLyBNYWluLkUK
ICAgIHRoaXMubGltaXQgPSBNYXRoLm1pbihDTElFTlRTLCBNYXRoLm1heCgyLCBsaW1pdCkpOyAv
LyBNYWluLk8KICAgIHRoaXMucGFzc3dvcmQgPSAnJzsgLy8gTWFpbi5DIC8gTWFpbi5EIChyb29t
cyBoZXJlIGhhdmUgbm9uZSkKICAgIHRoaXMubGF0ZW5jeUxpbWl0ID0gLTE7IC8vIE1haW4uYUoK
ICAgIHRoaXMuYWZrTWludXRlcyA9IC0xOyAvLyBNYWluLmFMCiAgICB0aGlzLnJhbmRvbSA9IHJh
bmRvbTsKICAgIHRoaXMubG9nID0gbG9nOwogICAgdGhpcy5zbG90cyA9IEFycmF5LmZyb20oeyBs
ZW5ndGg6IFNMT1RTIH0sIG5ld1Nsb3QpOyAvLyBNYWluLmFwCiAgICB0aGlzLnNsb3RzW0hPU1Rf
U0xPVF0ubmFtZSA9ICc8Zm9udCBjb2xvcj0iI0NDRkZGRiI+Um9vbSBIb3N0PC9mb250Pic7CiAg
ICB0aGlzLm1lbiA9IFtdOyAvLyBNYWluLmFxCiAgICB0aGlzLmNvbm5lY3RlZCA9IDA7IC8vIE1h
aW4uTQogICAgdGhpcy5jb25uZWN0aW9ucyA9IG5ldyBTZXQoKTsKICAgIC8vIGguYSwgaC5iOiB0
aGUgcmFuZG9tIHRhYmxlIGFuZCBpdHMgc3RhcnRpbmcgcG9pbnQsIHRoZSBzYW1lIGZvciBldmVy
eSBnYW1lIGluIHRoZSByb29tLgogICAgdGhpcy50YWJsZSA9IEFycmF5LmZyb20oeyBsZW5ndGg6
IDUwMDAgfSwgKCkgPT4gdGhpcy5uZXh0SW50KDEwMDAwKSk7CiAgICB0aGlzLnNlZWQgPSB0aGlz
Lm5leHRJbnQoNTAwMCk7CiAgICAvLyBUaGUgam91cm5hbDogd2hhdCBoYXBwZW5lZCBpbiB0aGlz
IHJvb20gbGF0ZWx5LCBmb3IgdGhlIGFkbWluIHBhZ2UgKGhmLmpzIC9hZG1pbi9hcGkvaGYtam91
cm5hbCkuIEpvaW5zLAogICAgLy8gbGVhdmVzLCBmaWdodHMsIHBhdXNlcywgYW5kIHdoZW4gYSBm
aWdodCBnb2VzIG91dCBvZiBzdGVwLCBldmVyeXRoaW5nIHRoZSB0d28gZ2FtZXMgcmVwb3J0ZWQg
YXJvdW5kIHRoYXQKICAgIC8vIGZyYW1lLCBzbyB0aGF0IHRoZSBjYXVzZSBjYW4gYmUgbG9va2Vk
IGZvciBhZnRlcndhcmRzLgogICAgdGhpcy5qb3VybmFsID0gW107CiAgICB0aGlzLndpblJlcG9y
dGVkID0gZmFsc2U7IC8vIGguYwogICAgdGhpcy5idWlsZCA9IG51bGw7IC8vIHRoZSBidWlsZCBv
ZiB0aGUgZ2FtZXMgaW4gdGhlIHJvb20gKGFjY2VwdHNCdWlsZCkKICAgIHRoaXMuc3RlcHMgPSBu
ZXcgTWFwKCk7IC8vIGZyYW1lIC0+IHRoZSByYW5kb20gbnVtYmVycyB1c2VkIGJ5IHRoZW4sIGFz
IHRoZSBmaXJzdCBnYW1lIHJlcG9ydGVkIGl0CiAgICB0aGlzLm91dE9mU3RlcCA9IGZhbHNlOwog
ICAgdGhpcy5zdGFydGluZyA9IGZhbHNlOyAvLyBNYWluLnI6IGEgZmlnaHQgaXMgc3RhcnRpbmc7
IGZyYW1lcyB3YWl0IHVudGlsIGV2ZXJ5IGdhbWUgaGFzIHN0YXJ0ZWQKICAgIHRoaXMuY291bnRk
b3duID0geyBvbjogZmFsc2UsIGNvdW50OiBDT1VOVERPV04sIGFjdGlvbjogJycgfTsgLy8gVC5h
LCBULmIsIFQuZAogICAgdGhpcy5maWdodGluZ05vdyA9IGZhbHNlOyAvLyBNYWluLmFtCiAgICB0
aGlzLm1vZGUgPSAnV0FJVFJPT00nOyAvLyBNYWluLmFrCiAgICB0aGlzLnBhZ2UgPSAnV0FJVFJP
T00nOyAvLyBNYWluLmFsCiAgICB0aGlzLnByZXZpb3VzUGFnZSA9ICcnOyAvLyBNYWluLmFuCiAg
ICB0aGlzLnN0b3J5ID0gMDsgLy8gTWFpbi5hbwogICAgdGhpcy5iYXR0bGVUeXBlID0gMTExMTsg
Ly8gTWFpbi5hQwogICAgdGhpcy5wcmVzZXQgPSAtMTsgLy8gTWFpbi5hRAogICAgdGhpcy50ZWFt
cyA9IDQ7IC8vIE1haW4uYUUKICAgIHRoaXMudGVhbU1hcCA9IFswLCAxLCAyLCAzXTsgLy8gTWFp
bi5hRgogICAgdGhpcy5yZXNldCgpOwogICAgdGhpcy5jbG9zZWQgPSBmYWxzZTsKICAgIHRoaXMu
dGltZXJzID0gW107CiAgICAvLyBUaGUgb3JpZ2luYWwncyB0aHJlYWRzOiB0aGUgY291bnRkb3du
IChULCBldmVyeSAxMDAgbXMpLCBmcmFtZSBzZW5kaW5nIChhdiwgZXZlcnkgMTAgbXMpIGFuZAog
ICAgLy8gdGhlIHdhdGNoZG9nIHRoYXQgcGluZ3MgYW5kIHRpbWVzIG91dCBnYW1lcyAoYUEsIGV2
ZXJ5IDIgcyBhZnRlciAxMCBzKS4KICAgIHRoaXMuY291bnRkb3duVGltZXIgPSBzZXRUaW1lb3V0
KCgpID0+IHRoaXMuY291bnRkb3duVGljaygpLCAxMDApOwogICAgdGhpcy50aW1lcnMucHVzaChz
ZXRJbnRlcnZhbCgoKSA9PiB0aGlzLmZsdXNoVGljaygpLCAxMCkpOwogICAgdGhpcy53YXRjaGRv
Z1N0YXJ0ID0gc2V0VGltZW91dCgoKSA9PiB7IHRoaXMudGltZXJzLnB1c2goc2V0SW50ZXJ2YWwo
KCkgPT4gdGhpcy53YXRjaGRvZygpLCAyMDAwKSk7IH0sIDEwMDAwKTsKICAgIGZvciAoY29uc3Qg
dGltZXIgb2YgdGhpcy50aW1lcnMpIGlmICh0aW1lci51bnJlZikgdGltZXIudW5yZWYoKTsKICB9
CgogIG5leHRJbnQoYm91bmQpIHsgcmV0dXJuIE1hdGguZmxvb3IodGhpcy5yYW5kb20oKSAqIGJv
dW5kKTsgfQoKICBjbG9zZSgpIHsKICAgIHRoaXMuY2xvc2VkID0gdHJ1ZTsKICAgIGNsZWFyVGlt
ZW91dCh0aGlzLmNvdW50ZG93blRpbWVyKTsKICAgIGNsZWFyVGltZW91dCh0aGlzLndhdGNoZG9n
U3RhcnQpOwogICAgZm9yIChjb25zdCB0aW1lciBvZiB0aGlzLnRpbWVycykgY2xlYXJJbnRlcnZh
bCh0aW1lcik7CiAgICBmb3IgKGNvbnN0IGNvbm5lY3Rpb24gb2YgWy4uLnRoaXMuY29ubmVjdGlv
bnNdKSBjb25uZWN0aW9uLmNsb3NlKCk7CiAgfQoKICAvLyBNYWluLms6IHRoZSBzZXR0aW5ncyBh
bmQgdGhlIG1lbiBhIHJvb20gc3RhcnRzIHdpdGguCiAgcmVzZXQoKSB7CiAgICB0aGlzLmFsbG93
Sm9pbldoZW5GaWdodGluZyA9IHRydWU7IC8vIE1haW4uVgogICAgdGhpcy5waWNrTXVzaWMoKTsK
ICAgIHRoaXMubXVzaWNSYW5kb20gPSB0cnVlOyAvLyBNYWluLlgKICAgIHRoaXMubXVsdGlwbGFu
ZSA9IHRydWU7IC8vIE1haW4uYWIKICAgIHRoaXMuYmFja2dyb3VuZCA9ICdyb29tMSc7IC8vIE1h
aW4uWQogICAgdGhpcy5iYWNrZ3JvdW5kQ2hvc2VuID0gJ3Jvb20xJzsgLy8gTWFpbi5aCiAgICB0
aGlzLmJhY2tncm91bmRSYW5kb20gPSBmYWxzZTsgLy8gTWFpbi5XCiAgICB0aGlzLmhvcnNlcyA9
IDA7IC8vIE1haW4uYWMKICAgIHRoaXMuZ2lhbnRPYmplY3RzID0gMDsgLy8gTWFpbi5hZAogICAg
dGhpcy5kaWZmaWN1bHR5ID0gMDsgLy8gTWFpbi5hZQogICAgdGhpcy5ub3JtYWxpemVMZXZlbCA9
IDE7IC8vIE1haW4uYWkKICAgIHRoaXMuZGlub3NhdXJzID0gMDsgLy8gTWFpbi5hagogICAgdGhp
cy50ZXN0VHJvb3BzID0gMDsgLy8gTWFpbi5hZgogICAgdGhpcy5zb2xkaWVyTnVtYmVyID0gMTsg
Ly8gTWFpbi5hZwogICAgdGhpcy5zb2xkaWVyUmVzZXJ2ZWQgPSAxOyAvLyBNYWluLmFoCiAgICB0
aGlzLnN0b3J5ID0gMDsKICAgIHRoaXMubW9kZSA9ICdXQUlUUk9PTSc7CiAgICB0aGlzLnBhZ2Ug
PSAnV0FJVFJPT00nOwogICAgdGhpcy5wcmV2aW91c1BhZ2UgPSAnJzsKICAgIHRoaXMubWVuID0g
QXJyYXkuZnJvbSh7IGxlbmd0aDogTUVOIH0sIG5ld01hbik7CiAgfQoKICAvLyBBIGNvbXB1dGVy
IHBsYXllcidzIGxldmVsIHdpdGggYSBjaGFyYWN0ZXI6IHRoZSBiZXN0IGEgcGxheWVyIGluIHRo
ZSByb29tIGhhcywgZWxzZSB0aGUgZ2FtZSdzIGhpZ2hlc3QuCiAgY29tcHV0ZXJMZXZlbChjaGFy
YWN0ZXIpIHsKICAgIGxldCBsZXZlbCA9IDA7CiAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5v
bmxpbmUoKSkgaWYgKHNsb3QubGV2ZWxzW2NoYXJhY3Rlcl0gPiBsZXZlbCkgbGV2ZWwgPSBzbG90
LmxldmVsc1tjaGFyYWN0ZXJdOwogICAgcmV0dXJuIGxldmVsID4gMCA/IGxldmVsIDogTUFYX0xF
VkVMOwogIH0KCiAgLy8gV2hldGhlciBhIGdhbWUgb2YgdGhpcyBidWlsZCAoaXRzIG1vdmllIGFu
ZCBSdWZmbGUsIGFzIHRoZSBwYWdlIHJlcG9ydHMgdGhlbSkgbWF5IGpvaW46IHRoZSBzYW1lIGFz
CiAgLy8gdGhlIGdhbWVzIGluIHRoZSByb29tLCB3aG9zZSBzaW11bGF0aW9ucyBtdXN0IG1hdGNo
IHN0ZXAgZm9yIHN0ZXAuCiAgYWNjZXB0c0J1aWxkKGJ1aWxkKSB7CiAgICBpZiAoIXRoaXMub25s
aW5lKCkubGVuZ3RoKSB0aGlzLmJ1aWxkID0gYnVpbGQ7CiAgICByZXR1cm4gdGhpcy5idWlsZCA9
PT0gYnVpbGQ7CiAgfQoKICAvLyBFdmVyeSBnYW1lIHJlcG9ydHMsIGV2ZXJ5IDIwIGZyYW1lcywg
aG93IG1hbnkgcmFuZG9tIG51bWJlcnMgaXQgaGFzIHVzZWQgc28gZmFyICg8cnBjPik7IGdhbWVz
IHRoYXQKICAvLyBkaWZmZXIgbm8gbG9uZ2VyIHNob3cgdGhlIHNhbWUgZmlnaHQuIFRoZSBvcmln
aW5hbCBwYXNzZWQgdGhlc2Ugb24gYW5kIHRoZSBnYW1lcyB0aGVtc2VsdmVzIGNsb3NlZAogIC8v
IHRoZSBjb25uZWN0aW9uIG9uIGEgZGlmZmVyZW5jZSAoIlN5bmNocm9uaXphdGlvbiBlcnJvciIp
LCB3aGljaCB0aHJldyBldmVyeW9uZSBvdXQgb2YgdGhlIHJvb207IGhlcmUKICAvLyB0aGUgc2Vy
dmVyIGNvbXBhcmVzIHRoZW0gYW5kIGVuZHMgdGhlIGZpZ2h0IGluc3RlYWQsIGJhY2sgdG8gdGhl
IG1lbnVzLCB3aXRoIGV2ZXJ5b25lIHN0aWxsIGluLgogIGNoZWNrU3RlcChpbmRleCwgZnJhbWUs
IHVzZWQpIHsKICAgIGlmICghdGhpcy5maWdodGluZ05vdyB8fCB0aGlzLm91dE9mU3RlcCkgcmV0
dXJuOwogICAgY29uc3Qgc2xvdCA9IHRoaXMuc2xvdHNbaW5kZXhdOwogICAgc2xvdC5zdGVwcy5w
dXNoKFtmcmFtZSwgdXNlZF0pOwogICAgaWYgKHNsb3Quc3RlcHMubGVuZ3RoID4gNjApIHNsb3Qu
c3RlcHMuc2hpZnQoKTsKICAgIGNvbnN0IHNlZW4gPSB0aGlzLnN0ZXBzLmdldChmcmFtZSk7CiAg
ICBpZiAoIXNlZW4pIHsKICAgICAgdGhpcy5zdGVwcy5zZXQoZnJhbWUsIHsgdXNlZCwgZnJvbTog
aW5kZXggfSk7CiAgICAgIGlmICh0aGlzLnN0ZXBzLnNpemUgPiA2NCkgdGhpcy5zdGVwcy5kZWxl
dGUodGhpcy5zdGVwcy5rZXlzKCkubmV4dCgpLnZhbHVlKTsKICAgICAgcmV0dXJuOwogICAgfQog
ICAgaWYgKHNlZW4udXNlZCA9PT0gdXNlZCkgcmV0dXJuOwogICAgdGhpcy5vdXRPZlN0ZXAgPSB0
cnVlOwogICAgdGhpcy5sb2coYGhmIHJvb20gJHt0aGlzLm51bWJlcn06IGdhbWVzICR7c2Vlbi5m
cm9tfSBhbmQgJHtpbmRleH0gb3V0IG9mIHN0ZXAgYXQgZnJhbWUgJHtmcmFtZX06IGVuZGluZyB0
aGUgZmlnaHRgKTsKICAgIHRoaXMuam90T3V0T2ZTdGVwKHNlZW4uZnJvbSwgaW5kZXgsIGZyYW1l
KTsKICAgIGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSB7CiAgICAgIHNsb3QuY29u
bmVjdGlvbi5ub3RpY2UoJ0hhaSBtYXkga2hvbmcgY29uIGtob3AgbmhhdSAoZGVzeW5jKTogdHJh
biBkYXUgZHVuZyBsYWkuIEJhbSBOZXh0IHJvaSBTdGFydCBGaWdodCEgZGUgZGFuaCBsYWkuJyk7
CiAgICB9CiAgICBjb25zdCBjb3VudGRvd24gPSB0aGlzLmNvdW50ZG93bjsKICAgIGNvdW50ZG93
bi5vbiA9IHRydWU7CiAgICBjb3VudGRvd24uYWN0aW9uID0gJ3F1aXRnYW1lJzsKICAgIGNvdW50
ZG93bi5jb3VudCA9IDE7CiAgfQoKICAvLyBBIGxpbmUgaW4gdGhlIHJvb20ncyBqb3VybmFsIChr
ZXB0OiB0aGUgbGFzdCA0MDApLgogIGpvdCh0ZXh0KSB7CiAgICBjb25zdCBzdGFtcCA9IG5ldyBE
YXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLCAxOSkucmVwbGFjZSgnVCcsICcgJyk7CiAgICB0
aGlzLmpvdXJuYWwucHVzaChgJHtzdGFtcH0gJHt0ZXh0fWApOwogICAgaWYgKHRoaXMuam91cm5h
bC5sZW5ndGggPiA0MDApIHRoaXMuam91cm5hbC5zcGxpY2UoMCwgdGhpcy5qb3VybmFsLmxlbmd0
aCAtIDQwMCk7CiAgfQoKICAvLyBUaGUgZmlnaHQgYXMgaXQgd2FzIHNldCB1cCwgZm9yIHRoZSBq
b3VybmFsLgogIGRlc2NyaWJlRmlnaHQoKSB7CiAgICBjb25zdCBtZW4gPSB0aGlzLm1lbi5maWx0
ZXIoKG1hbikgPT4gbWFuLmV4aXN0cykubWFwKChtYW4sIGspID0+IHsKICAgICAgY29uc3Qgd2hv
ID0gbWFuLmNsaWVudCA+PSAwID8gYCR7dGhpcy5zbG90c1ttYW4uY2xpZW50XS5uYW1lfS9QJHtt
YW4uY29udHJvbGxlciArIDF9YCA6IChtYW4uY29tbWFuZGVyID49IDAgPyBgc29sZGllciBvZiAk
e21hbi5jb21tYW5kZXJ9YCA6ICdjb21wdXRlcicpOwogICAgICByZXR1cm4gYCR7bWFuLmNoYXIg
fHwgJz8nfSBsdiR7bWFuLmxldmVsfSB0ZWFtJHttYW4udGVhbX0gKCR7d2hvfSlgOwogICAgfSk7
CiAgICByZXR1cm4gYCR7dGhpcy5tb2RlfSR7dGhpcy5tb2RlID09PSAnQkFUVExFTU9ERScgPyAn
ICcgKyB0aGlzLmJhdHRsZVR5cGUgOiAnJ30gZGlmZmljdWx0eSAke3RoaXMuZGlmZmljdWx0eX0g
bm9ybWFsaXplICR7dGhpcy5ub3JtYWxpemVMZXZlbH1gCiAgICAgICsgYCBkaW5vc2F1cnMgJHt0
aGlzLmRpbm9zYXVyc30gYmFja2dyb3VuZCAke3RoaXMuYmFja2dyb3VuZH07IG1lbjogJHttZW4u
am9pbignLCAnKX07IGxhdGVuY2llczogJHt0aGlzLnBlb3BsZSgpfWA7CiAgfQoKICAvLyBXaGF0
IGJvdGggZ2FtZXMgcmVwb3J0ZWQgYXJvdW5kIHRoZSBmcmFtZSB0aGV5IHdlbnQgb3V0IG9mIHN0
ZXA6IHRoZWlyIHJhbmRvbSBjb3VudHMgKGV2ZXJ5IDIwIGZyYW1lcyksCiAgLy8gdGhlaXIgPHQ+
IHRpbWluZyByZXBvcnRzICg1OTQwID0gZnVsbCBzcGVlZCksIGFuZCB0aGUga2V5IGZyYW1lcyB0
aGV5IHNlbnQganVzdCBiZWZvcmUuCiAgam90T3V0T2ZTdGVwKGEsIGIsIGZyYW1lKSB7CiAgICB0
aGlzLmpvdChgT1VUIE9GIFNURVAgYXQgZnJhbWUgJHtmcmFtZX06ICR7dGhpcy5zbG90c1thXS5u
YW1lfSAoZ2FtZSAke2F9KSBhbmQgJHt0aGlzLnNsb3RzW2JdLm5hbWV9IChnYW1lICR7Yn0pOyAk
e3RoaXMuZGVzY3JpYmVGaWdodCgpfWApOwogICAgZm9yIChjb25zdCBpbmRleCBvZiBbYSwgYl0p
IHsKICAgICAgY29uc3Qgc2xvdCA9IHRoaXMuc2xvdHNbaW5kZXhdOwogICAgICBjb25zdCBzdGVw
cyA9IHNsb3Quc3RlcHMuc2xpY2UoLTEyKS5tYXAoKFtmLCB1c2VkXSkgPT4gYCR7Zn06JHt1c2Vk
fWApLmpvaW4oJyAnKTsKICAgICAgdGhpcy5qb3QoYCAgZ2FtZSAke2luZGV4fSAke3Nsb3QubmFt
ZX06IGxhdGVuY3kgJHtzbG90LmxhdGVuY3l9IGxhc3QgcGFja2V0ICR7c2xvdC5sYXN0UGFja2V0
fSBwYXVzZWQgJHtzbG90LnBhdXNlZH07IHJhbmRvbSBjb3VudHMgJHtzdGVwc307IHQgJHtzbG90
LnRpbWVzLnNsaWNlKC04KS5qb2luKCcgJyl9YCk7CiAgICAgIGNvbnN0IGxpbmVzID0gW107CiAg
ICAgIGZvciAobGV0IGYgPSBNYXRoLm1heCgwLCBmcmFtZSAtIDQ0KTsgZiA8PSBNYXRoLm1pbihz
bG90Lmxhc3RQYWNrZXQsIGZyYW1lICsgNCk7IGYgKz0gMSkgewogICAgICAgIGNvbnN0IGxpbmUg
PSBzbG90LmZyYW1lc1tmICUgRlJBTUVTX0tFUFRdOwogICAgICAgIGlmICghbGluZSkgY29udGlu
dWU7CiAgICAgICAgY29uc3QgYm9keSA9IGxpbmUucmVwbGFjZSgvXjxmPjxjPlxkKzxcL2M+PGk+
KFxkKyk8XC9pPi8sICckMSAnKS5yZXBsYWNlKC88XC9mPiQvLCAnJyk7CiAgICAgICAgaWYgKCEv
XlxkKyAoPHMxPltAXl08XC9zMT4pPyQvLnRlc3QoYm9keSkgfHwgLzxtXGQ+Ly50ZXN0KGJvZHkp
KSBsaW5lcy5wdXNoKGJvZHkpOwogICAgICB9CiAgICAgIHRoaXMuam90KGAgIGdhbWUgJHtpbmRl
eH0ga2V5IGZyYW1lcyAke2ZyYW1lIC0gNDR9Li4ke2ZyYW1lICsgNH0gKG9ubHkgdGhvc2Ugd2l0
aCBjaGFuZ2VzKTogJHtsaW5lcy5qb2luKCcgfCAnKSB8fCAnbm9uZSd9YCk7CiAgICB9CiAgfQoK
ICBwaWNrQmFja2dyb3VuZCgpIHsgdGhpcy5iYWNrZ3JvdW5kID0gQkFDS0dST1VORFNbdGhpcy5u
ZXh0SW50KEJBQ0tHUk9VTkRTLmxlbmd0aCldOyB9IC8vIE1haW4uYQogIHBpY2tNdXNpYygpIHsg
dGhpcy5tdXNpYyA9IE1VU0lDW3RoaXMubmV4dEludChNVVNJQy5sZW5ndGgpXTsgfSAvLyBNYWlu
LmIKCiAgLy8gTWFpbi5mOiBjb3VudHMgdGhlIGNvbXB1dGVyczsgYSByb29tIG5vYm9keSBwbGF5
cyBpbiBhbnkgbW9yZSBzdGFydHMgb3Zlci4KICByZWNvdW50KCkgewogICAgbGV0IGVtcHR5ID0g
dHJ1ZTsKICAgIHRoaXMuY29ubmVjdGVkID0gMDsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5k
ZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3Rz
W2luZGV4XTsKICAgICAgaWYgKHNsb3Qub25saW5lKSB0aGlzLmNvbm5lY3RlZCArPSAxOwogICAg
ICBpZiAodGhpcy5wYWdlID09PSAnV0FJVFJPT00nKSB7CiAgICAgICAgaWYgKHNsb3Qub25saW5l
KSBlbXB0eSA9IGZhbHNlOwogICAgICB9IGVsc2UgaWYgKHNsb3Qub25saW5lICYmIHNsb3QucGFn
ZSAhPT0gJ1dBSVRST09NJykgewogICAgICAgIGVtcHR5ID0gZmFsc2U7CiAgICAgIH0KICAgIH0K
ICAgIGlmIChlbXB0eSkgewogICAgICB0aGlzLnJlc2V0KCk7CiAgICAgIHRoaXMuYnJvYWRjYXN0
R2FtZVNldHRpbmcoLTEpOwogICAgICB0aGlzLmJyb2FkY2FzdFNldHRpbmcoLTEpOwogICAgICB0
aGlzLmJyb2FkY2FzdFN0YXR1cygpOwogICAgICB0aGlzLmJyb2FkY2FzdE1lbigxKTsKICAgIH0K
ICB9CgogIG9ubGluZSgpIHsKICAgIGNvbnN0IGxpc3QgPSBbXTsKICAgIGZvciAobGV0IGluZGV4
ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSBpZiAodGhpcy5zbG90c1tpbmRleF0u
b25saW5lKSBsaXN0LnB1c2godGhpcy5zbG90c1tpbmRleF0pOwogICAgcmV0dXJuIGxpc3Q7CiAg
fQoKICBicm9hZGNhc3QodGV4dCkgeyBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkg
c2xvdC5jb25uZWN0aW9uLnNlbmQodGV4dCk7IH0gLy8gaC5hKFN0cmluZykKICBicm9hZGNhc3RM
aXN0KGpvaW5lZCwgcXVpdCkgeyBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkgc2xv
dC5jb25uZWN0aW9uLnNlbmRMaXN0KGpvaW5lZCwgcXVpdCk7IH0gLy8gaC5hKGludCwgaW50KQog
IGJyb2FkY2FzdFNldHRpbmcoY2lkKSB7IGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgp
KSBzbG90LmNvbm5lY3Rpb24uc2VuZFNldHRpbmcoY2lkKTsgfSAvLyBoLmIoaW50KQogIGJyb2Fk
Y2FzdEdhbWVTZXR0aW5nKGNpZCkgeyBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkg
c2xvdC5jb25uZWN0aW9uLnNlbmRHYW1lU2V0dGluZyhjaWQpOyB9IC8vIGguYyhpbnQpCiAgYnJv
YWRjYXN0U3RhdHVzKCkgeyAvLyBoLmUKICAgIGZvciAoY29uc3Qgc2xvdCBvZiB0aGlzLm9ubGlu
ZSgpKSB7CiAgICAgIHNsb3QuY29ubmVjdGlvbi5zZW5kKGA8c3RhdHVzPjxtb2RlPiR7dGhpcy5t
b2RlfTwvbW9kZT48cGFnZT4ke3RoaXMucGFnZX08L3BhZ2U+PHByZXBhZ2U+JHt0aGlzLnByZXZp
b3VzUGFnZX08L3ByZXBhZ2U+YAogICAgICAgICsgYDxzdG9yeWk+JHt0aGlzLnN0b3J5fTwvc3Rv
cnlpPjwvc3RhdHVzPmApOwogICAgfQogIH0KICAvLyBoLmEoaW50KTogc29sZGllcnMgd2hvc2Ug
Y29tbWFuZGVyJ3MgY29tcHV0ZXIgbGVmdCBnbyB0b287IHRoZW4gZXZlcnlvbmUgZ2V0cyB0aGUg
bWVuLgogIGJyb2FkY2FzdE1lbihjaGFuZ2VkKSB7CiAgICBmb3IgKGNvbnN0IG1hbiBvZiB0aGlz
Lm1lbikgewogICAgICBpZiAoIW1hbi5leGlzdHMgfHwgbWFuLmNvbW1hbmRlciA9PT0gLTEpIGNv
bnRpbnVlOwogICAgICBjb25zdCBjb21tYW5kZXIgPSB0aGlzLm1lblttYW4uY29tbWFuZGVyXTsK
ICAgICAgaWYgKGNvbW1hbmRlci5jbGllbnQgIT09IC0xICYmICF0aGlzLnNsb3RzW2NvbW1hbmRl
ci5jbGllbnRdLm9ubGluZSkgbWFuLmV4aXN0cyA9IGZhbHNlOwogICAgfQogICAgZm9yIChjb25z
dCBzbG90IG9mIHRoaXMub25saW5lKCkpIHNsb3QuY29ubmVjdGlvbi5zZW5kTWVuKGNoYW5nZWQp
OwogIH0KICBicm9hZGNhc3RDb3VudCgpIHsgLy8gaC5jKCkKICAgIHRoaXMuYnJvYWRjYXN0KGA8
c3RhcnRjb3VudD48YWN0aW9uPiR7dGhpcy5jb3VudGRvd24uYWN0aW9ufTwvYWN0aW9uPjxjb3Vu
dD4ke3RoaXMuY291bnRkb3duLmNvdW50fTwvY291bnQ+YAogICAgICArIGA8cGFnZT4ke3RoaXMu
cGFnZX08L3BhZ2U+PC9zdGFydGNvdW50PmApOwogIH0KICBicm9hZGNhc3RDbGljayhjaWQsIHdo
YXQpIHsgdGhpcy5icm9hZGNhc3QoYDxjaGF0Mj48Yz4ke2NpZH08L2M+PG0+JHt3aGF0fTwvbT48
L2NoYXQyPmApOyB9IC8vIGguYShpbnQsIFN0cmluZykKICBuZXdTZWVkKCkgeyAvLyBoLmYKICAg
IHRoaXMuc2VlZCA9IHRoaXMubmV4dEludCg1MDAwKTsKICAgIHRoaXMuYnJvYWRjYXN0KGA8cnA+
PHJwPiR7dGhpcy5zZWVkfTwvcnA+PC9ycD5gKTsKICB9CgogIC8vIGguYSgpOiB0aGUgZnJhbWVz
IG9mIHRoZSBmaWdodCBzdGFydCBvdmVyLgogIHJlc2V0RnJhbWVzKCkgewogICAgdGhpcy5zdGVw
cy5jbGVhcigpOwogICAgdGhpcy5vdXRPZlN0ZXAgPSBmYWxzZTsKICAgIGZvciAobGV0IGluZGV4
ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgIGNvbnN0IHNsb3QgPSB0
aGlzLnNsb3RzW2luZGV4XTsKICAgICAgc2xvdC5mbHVzaGVzID0gMDsKICAgICAgc2xvdC5wYXVz
ZWQgPSBmYWxzZTsKICAgICAgc2xvdC5maWdodGluZyA9IGZhbHNlOwogICAgICBzbG90Lmxhc3RQ
YWNrZXQgPSAtMTsKICAgICAgc2xvdC5sZWZ0RnJhbWUgPSAtMTsKICAgICAgaWYgKHNsb3QuY29u
bmVjdGlvbikgc2xvdC5jb25uZWN0aW9uLnJlc2V0RnJhbWVzKCk7CiAgICB9CiAgfQoKICAvLyBo
LmIoKTogbGF0ZW5jaWVzIGVhc2UgdG93YXJkcyB0aGVpciB0YXJnZXRzLgogIGVhc2VMYXRlbmNp
ZXMoKSB7CiAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgQ0xJRU5UUzsgaW5kZXggKz0g
MSkgewogICAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90c1tpbmRleF07CiAgICAgIGlmIChzbG90
Lm9ubGluZSkgc2xvdC5sYXRlbmN5ID0gTWF0aC50cnVuYygoc2xvdC5sYXRlbmN5VGFyZ2V0ICsg
c2xvdC5sYXRlbmN5ICogMykgLyA0KTsKICAgIH0KICAgIHRoaXMuYnJvYWRjYXN0TGlzdCgtMSwg
LTEpOwogIH0KCiAgLy8gVC5hKCk6IGEgZmlnaHQgc3RhcnRzOyBmcmFtZXMgd2FpdCBmb3IgZXZl
cnkgZ2FtZS4KICBzdGFydEZpZ2h0KCkgewogICAgZm9yIChjb25zdCBzbG90IG9mIHRoaXMuc2xv
dHMpIHNsb3Quc3RhcnRlZCA9IGZhbHNlOwogICAgdGhpcy5zdGFydGluZyA9IHRydWU7CiAgfQoK
ICAvLyBUaGUgY291bnRkb3duIHRocmVhZCAoVCk6IGV2ZXJ5IDEwMCBtcywgYW5kIDQwMCBtcyBt
b3JlIGFmdGVyIGEgc3RlcCBvZiBhIGNvdW50ZG93bi4KICBjb3VudGRvd25UaWNrKCkgewogICAg
aWYgKHRoaXMuY2xvc2VkKSByZXR1cm47CiAgICBsZXQgZGVsYXkgPSAxMDA7CiAgICB0cnkgewog
ICAgICBpZiAodGhpcy5zdGFydGluZykgewogICAgICAgIHRoaXMuc3RhcnRpbmcgPSBmYWxzZTsK
ICAgICAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5zbG90cykgewogICAgICAgICAgaWYgKHNs
b3Qub25saW5lICYmICFzbG90LnN0YXJ0ZWQgJiYgc2xvdC5wYWdlICE9PSAnV0FJVFJPT00nKSB0
aGlzLnN0YXJ0aW5nID0gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgaWYgKCF0aGlzLnN0YXJ0aW5n
KSB7CiAgICAgICAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5zbG90cykgaWYgKHNsb3QuY29u
bmVjdGlvbikgc2xvdC5jb25uZWN0aW9uLnJlc2V0RnJhbWVzKCk7CiAgICAgICAgICB0aGlzLnN0
ZXBzLmNsZWFyKCk7CiAgICAgICAgICB0aGlzLm91dE9mU3RlcCA9IGZhbHNlOwogICAgICAgICAg
Ly8gRWFjaCBnYW1lIHJlcG9ydHMgaXRzIGV4cGVyaWVuY2UgYWZ0ZXIgYSBmaWdodCBhbmQgd2Fp
dHMgZm9yIHRoZSBhbnN3ZXIgYmVmb3JlIGl0IHN0YXJ0cyB0aGUKICAgICAgICAgIC8vIG5leHQs
IHNlbmRpbmcgaXRzIGNoYXJhY3RlcnMnIGxldmVscyAoPGluZm8+KSBvbiB0aGUgd2F5OyBhIHJl
c3RhcnQgc2VuZHMgdGhlIG1lbiBiZWZvcmUKICAgICAgICAgIC8vIHRob3NlIGNvbWUuIFNvIGV2
ZXJ5IGdhbWUgZ2V0cyB0aGUgbWVuIGFnYWluIG5vdywgd2l0aCB0aGUgc2FtZSBsZXZlbHMgZm9y
IGV2ZXJ5b25lIChlYWNoCiAgICAgICAgICAvLyBnYW1lIGJ1aWxkcyB0aGUgZmlnaHQgZnJvbSB0
aGlzIGxpc3Qgb25jZSA8YWxsc3RhcnRlZGdhbWU+IGNvbWVzKS4KICAgICAgICAgIHRoaXMuYnJv
YWRjYXN0TWVuKDApOwogICAgICAgICAgdGhpcy5uZXdTZWVkKCk7CiAgICAgICAgICB0aGlzLmJy
b2FkY2FzdCgnPGFsbHN0YXJ0ZWRnYW1lPjwvYWxsc3RhcnRlZGdhbWU+Jyk7CiAgICAgICAgfQog
ICAgICB9CiAgICAgIGNvbnN0IGNvdW50ZG93biA9IHRoaXMuY291bnRkb3duOwogICAgICBpZiAo
Y291bnRkb3duLm9uKSB7CiAgICAgICAgY291bnRkb3duLmNvdW50IC09IDE7CiAgICAgICAgaWYg
KGNvdW50ZG93bi5jb3VudCA8PSAwKSB7CiAgICAgICAgICB0aGlzLmNvdW50ZG93bkRvbmUoY291
bnRkb3duLmFjdGlvbik7CiAgICAgICAgICB0aGlzLmJyb2FkY2FzdENvdW50KCk7CiAgICAgICAg
ICBjb3VudGRvd24uY291bnQgPSBDT1VOVERPV047CiAgICAgICAgICBjb3VudGRvd24ub24gPSBm
YWxzZTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgdGhpcy5icm9hZGNhc3RDb3VudCgpOwog
ICAgICAgIH0KICAgICAgICBkZWxheSArPSA0MDA7CiAgICAgIH0KICAgIH0gY2F0Y2ggKGVycm9y
KSB7CiAgICAgIHRoaXMubG9nKGBoZiByb29tICR7dGhpcy5udW1iZXJ9OiBjb3VudGRvd246ICR7
ZXJyb3Iuc3RhY2sgfHwgZXJyb3J9YCk7CiAgICB9CiAgICB0aGlzLmNvdW50ZG93blRpbWVyID0g
c2V0VGltZW91dCgoKSA9PiB0aGlzLmNvdW50ZG93blRpY2soKSwgZGVsYXkpOwogIH0KCiAgZW50
ZXJQYWdlKHBhZ2UsIHByZXZpb3VzKSB7CiAgICB0aGlzLnBhZ2UgPSBwYWdlOwogICAgdGhpcy5m
aWdodGluZ05vdyA9IGZhbHNlOwogICAgdGhpcy5wcmV2aW91c1BhZ2UgPSBwcmV2aW91czsKICB9
CgogIGNvdW50ZG93bkRvbmUoYWN0aW9uKSB7CiAgICBjb25zdCBwYWdlID0gdGhpcy5wYWdlOwog
ICAgY29uc3QgbW9kZSA9IHRoaXMubW9kZTsKICAgIGlmIChhY3Rpb24gPT09ICdjbGlja3ZzJyAm
JiBwYWdlID09PSAnV0FJVFJPT00nKSB7CiAgICAgIHRoaXMubW9kZSA9ICdWU01PREUnOwogICAg
ICB0aGlzLmVudGVyUGFnZSgnQ0hBUk1FTlUnLCAnV0FJVFJPT00nKTsKICAgICAgdGhpcy5iYXR0
bGVUeXBlID0gMTExMTsKICAgICAgdGhpcy5wcmVzZXQgPSAtMTsKICAgICAgaWYgKHRoaXMuYmFj
a2dyb3VuZENob3NlbiA9PT0gJ3JhbmRvbScpIHsKICAgICAgICB0aGlzLmJhY2tncm91bmQgPSBC
QUNLR1JPVU5EU1t0aGlzLm5leHRJbnQoQkFDS0dST1VORFMubGVuZ3RoKV07CiAgICAgICAgdGhp
cy5iYWNrZ3JvdW5kUmFuZG9tID0gdHJ1ZTsKICAgICAgfSBlbHNlIHsKICAgICAgICB0aGlzLmJh
Y2tncm91bmQgPSB0aGlzLmJhY2tncm91bmRDaG9zZW47CiAgICAgICAgdGhpcy5iYWNrZ3JvdW5k
UmFuZG9tID0gZmFsc2U7CiAgICAgIH0KICAgICAgdGhpcy5hZnRlclBhZ2VDaGFuZ2UoKTsKICAg
IH0gZWxzZSBpZiAoYWN0aW9uID09PSAnY2xpY2tzdG9yeScgJiYgcGFnZSA9PT0gJ1dBSVRST09N
JykgewogICAgICB0aGlzLm1vZGUgPSAnU1RPUllNT0RFJzsKICAgICAgdGhpcy5lbnRlclBhZ2Uo
J1NUT1JZTUVOVScsICdXQUlUUk9PTScpOwogICAgICB0aGlzLmFmdGVyUGFnZUNoYW5nZSgpOwog
ICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICdjbGlja2JhdHRsZScgJiYgcGFnZSA9PT0gJ1dBSVRS
T09NJykgewogICAgICB0aGlzLm1vZGUgPSAnQkFUVExFTU9ERSc7CiAgICAgIHRoaXMuZW50ZXJQ
YWdlKCdCQVRUTEVTRVRUSU5HTUVOVScsICdXQUlUUk9PTScpOwogICAgICB0aGlzLmJhdHRsZVR5
cGUgPSAxMTExOwogICAgICB0aGlzLnByZXNldCA9IC0xOwogICAgICB0aGlzLnRlYW1zID0gNDsK
ICAgICAgdGhpcy5iYWNrZ3JvdW5kID0gJ2JhdHRsZTQnOwogICAgICB0aGlzLmJhY2tncm91bmRS
YW5kb20gPSBmYWxzZTsKICAgICAgdGhpcy5hZnRlclBhZ2VDaGFuZ2UoKTsKICAgIH0gZWxzZSBp
ZiAoYWN0aW9uID09PSAnY2xpY2tuZXh0JyAmJiBwYWdlID09PSAnQkFUVExFU0VUVElOR01FTlUn
KSB7CiAgICAgIHRoaXMuZW50ZXJQYWdlKCdDSEFSTUVOVScsICdCQVRUTEVTRVRUSU5HTUVOVScp
OwogICAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgTUVOOyBpbmRleCArPSAxKSB7CiAg
ICAgICAgY29uc3QgbWFuID0gdGhpcy5tZW5baW5kZXhdOwogICAgICAgIGlmIChtYW4uZXhpc3Rz
ICYmIG1hbi50ZWFtID49IHRoaXMudGVhbXMpIG1hbi50ZWFtICU9IHRoaXMudGVhbXM7CiAgICAg
ICAgaWYgKGluZGV4IDwgTUVOIC0gMSAmJiBtYW4uY29udHJvbGxlciA+PSAwKSB7CiAgICAgICAg
ICBmb3IgKGxldCBvdGhlciA9IGluZGV4ICsgMTsgb3RoZXIgPCBNRU47IG90aGVyICs9IDEpIHsK
ICAgICAgICAgICAgY29uc3QgbmV4dCA9IHRoaXMubWVuW290aGVyXTsKICAgICAgICAgICAgaWYg
KG5leHQuZXhpc3RzICYmIG5leHQuY29udHJvbGxlciA+PSAwICYmIG5leHQuY2xpZW50ID09PSBt
YW4uY2xpZW50KSBuZXh0LnRlYW0gPSBtYW4udGVhbTsKICAgICAgICAgIH0KICAgICAgICB9CiAg
ICAgIH0KICAgICAgdGhpcy5hZnRlclBhZ2VDaGFuZ2UoKTsKICAgIH0gZWxzZSBpZiAoYWN0aW9u
ID09PSAnY2xpY2tuZXh0JyAmJiBwYWdlID09PSAnU1RPUllNRU5VJykgewogICAgICB0aGlzLmVu
dGVyUGFnZSgnQ0hBUk1FTlUnLCAnU1RPUllNRU5VJyk7CiAgICAgIHRoaXMuYWZ0ZXJQYWdlQ2hh
bmdlKCk7CiAgICB9IGVsc2UgaWYgKGFjdGlvbiA9PT0gJ2NsaWNrbmV4dCcgJiYgcGFnZSA9PT0g
J0NIQVJNRU5VJyAmJiBtb2RlID09PSAnVlNNT0RFJykgewogICAgICB0aGlzLmVudGVyUGFnZSgn
R0FNRVNFVFRJTkdNRU5VJywgJ0NIQVJNRU5VJyk7CiAgICAgIHRoaXMuYnJvYWRjYXN0TGlzdCgt
MSwgLTEpOwogICAgICB0aGlzLmJyb2FkY2FzdE1lbigxKTsKICAgICAgaWYgKHRoaXMuYmFja2dy
b3VuZFJhbmRvbSkgdGhpcy5waWNrQmFja2dyb3VuZCgpOwogICAgICBpZiAodGhpcy5tdXNpY1Jh
bmRvbSkgdGhpcy5waWNrTXVzaWMoKTsKICAgICAgdGhpcy5icm9hZGNhc3RHYW1lU2V0dGluZygt
MSk7CiAgICAgIHRoaXMuYnJvYWRjYXN0U3RhdHVzKCk7CiAgICB9IGVsc2UgaWYgKGFjdGlvbiA9
PT0gJ2NsaWNrbmV4dCcgJiYgcGFnZSA9PT0gJ0NIQVJNRU5VJyAmJiAobW9kZSA9PT0gJ1NUT1JZ
TU9ERScgfHwgbW9kZSA9PT0gJ0JBVFRMRU1PREUnKSkgewogICAgICB0aGlzLmZpZ2h0KCdDSEFS
TUVOVScpOwogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICdjbGlja2ZpZ2h0JyAmJiBwYWdlID09
PSAnR0FNRVNFVFRJTkdNRU5VJykgewogICAgICB0aGlzLmZpZ2h0KCdHQU1FU0VUVElOR01FTlUn
KTsKICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAncXVpdGdhbWUnICYmIHRoaXMuZmlnaHRpbmdO
b3cpIHsKICAgICAgdGhpcy5xdWl0VG9NZW51KCk7CiAgICB9IGVsc2UgaWYgKGFjdGlvbiA9PT0g
J3Jlc3RhcnRnYW1lJyAmJiB0aGlzLmZpZ2h0aW5nTm93KSB7CiAgICAgIGlmICh0aGlzLm9ubGlu
ZSgpLnNvbWUoKHNsb3QpID0+IHNsb3QucGFnZSA9PT0gJ1dBSVRST09NJykpIHsKICAgICAgICB0
aGlzLnF1aXRUb01lbnUoKTsKICAgICAgfSBlbHNlIHsKICAgICAgICB0aGlzLnN0YXJ0RmlnaHQo
KTsKICAgICAgICB0aGlzLnJlc2V0RnJhbWVzKCk7CiAgICAgICAgdGhpcy5icm9hZGNhc3QoJzxy
ZXN0YXJ0Z2FtZT48L3Jlc3RhcnRnYW1lPicpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0TGlzdCgt
MSwgLTEpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0TWVuKDEpOwogICAgICAgIHRoaXMucmVzZXRG
cmFtZXMoKTsKICAgICAgICB0aGlzLmVhc2VMYXRlbmNpZXMoKTsKICAgICAgICB0aGlzLmJyb2Fk
Y2FzdEdhbWVTZXR0aW5nKC0xKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdCgnPHJlc3RhcnRnYW1l
PjwvcmVzdGFydGdhbWU+Jyk7CiAgICAgIH0KICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAnbmV4
dHN0YWdlJyAmJiB0aGlzLmZpZ2h0aW5nTm93KSB7CiAgICAgIGlmICh0aGlzLm9ubGluZSgpLnNv
bWUoKHNsb3QpID0+IHNsb3QucGFnZSA9PT0gJ1dBSVRST09NJykpIHsKICAgICAgICB0aGlzLnBh
Z2UgPSAnU1RPUllNRU5VJzsKICAgICAgICB0aGlzLmZpZ2h0aW5nTm93ID0gZmFsc2U7CiAgICAg
ICAgdGhpcy5wcmV2aW91c1BhZ2UgPSAnRklHSFRJTkcnOwogICAgICAgIHRoaXMucXVpdEJyb2Fk
Y2FzdHMoKTsKICAgICAgfSBlbHNlIHsKICAgICAgICB0aGlzLnN0YXJ0RmlnaHQoKTsKICAgICAg
ICBpZiAodGhpcy5zdG9yeSA8IDYpIHRoaXMuc3RvcnkgKz0gMTsKICAgICAgICB0aGlzLmJyb2Fk
Y2FzdExpc3QoLTEsIC0xKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdE1lbigxKTsKICAgICAgICB0
aGlzLnJlc2V0RnJhbWVzKCk7CiAgICAgICAgdGhpcy5lYXNlTGF0ZW5jaWVzKCk7CiAgICAgICAg
dGhpcy5icm9hZGNhc3RHYW1lU2V0dGluZygtMSk7CiAgICAgICAgdGhpcy5icm9hZGNhc3QoJzxu
ZXh0c3RhZ2U+PC9uZXh0c3RhZ2U+Jyk7CiAgICAgIH0KICAgIH0KICB9CgogIGFmdGVyUGFnZUNo
YW5nZSgpIHsKICAgIHRoaXMuYnJvYWRjYXN0TGlzdCgtMSwgLTEpOwogICAgdGhpcy5icm9hZGNh
c3RNZW4oMSk7CiAgICB0aGlzLmJyb2FkY2FzdEdhbWVTZXR0aW5nKC0xKTsKICAgIHRoaXMuYnJv
YWRjYXN0U3RhdHVzKCk7CiAgfQoKICBmaWdodChwcmV2aW91cykgewogICAgdGhpcy5zdGFydEZp
Z2h0KCk7CiAgICB0aGlzLnBhZ2UgPSAnRklHSFRJTkcnOwogICAgdGhpcy5maWdodGluZ05vdyA9
IHRydWU7CiAgICB0aGlzLnByZXZpb3VzUGFnZSA9IHByZXZpb3VzOwogICAgZm9yIChjb25zdCBz
bG90IG9mIHRoaXMuc2xvdHMpIHsgc2xvdC5zdGVwcyA9IFtdOyBzbG90LnRpbWVzID0gW107IH0K
ICAgIHRoaXMuam90KGBmaWdodCBzdGFydHM6ICR7dGhpcy5kZXNjcmliZUZpZ2h0KCl9YCk7CiAg
ICB0aGlzLmJyb2FkY2FzdExpc3QoLTEsIC0xKTsKICAgIHRoaXMuYnJvYWRjYXN0TWVuKDEpOwog
ICAgdGhpcy5yZXNldEZyYW1lcygpOwogICAgdGhpcy5lYXNlTGF0ZW5jaWVzKCk7CiAgICB0aGlz
LmJyb2FkY2FzdEdhbWVTZXR0aW5nKC0xKTsKICAgIHRoaXMuYnJvYWRjYXN0U3RhdHVzKCk7CiAg
fQoKICBxdWl0VG9NZW51KCkgewogICAgdGhpcy5qb3QoYGZpZ2h0IGVuZHMgKGJhY2sgdG8gdGhl
IG1lbnVzKSR7dGhpcy5vdXRPZlN0ZXAgPyAnIGFmdGVyIGdvaW5nIG91dCBvZiBzdGVwJyA6ICcn
fTsgbGFzdCBwYWNrZXRzICR7dGhpcy5vbmxpbmUoKS5tYXAoKHNsb3QpID0+IGAke3Nsb3QubmFt
ZX0gJHtzbG90Lmxhc3RQYWNrZXR9YCkuam9pbignLCAnKX1gKTsKICAgIGlmICh0aGlzLm1vZGUg
PT09ICdWU01PREUnKSB0aGlzLmVudGVyUGFnZSgnQ0hBUk1FTlUnLCAnRklHSFRJTkcnKTsKICAg
IGVsc2UgaWYgKHRoaXMubW9kZSA9PT0gJ1NUT1JZTU9ERScpIHRoaXMuZW50ZXJQYWdlKCdTVE9S
WU1FTlUnLCAnRklHSFRJTkcnKTsKICAgIGVsc2UgaWYgKHRoaXMubW9kZSA9PT0gJ0JBVFRMRU1P
REUnKSB0aGlzLmVudGVyUGFnZSgnQkFUVExFU0VUVElOR01FTlUnLCAnRklHSFRJTkcnKTsKICAg
IHRoaXMucXVpdEJyb2FkY2FzdHMoKTsKICB9CgogIHF1aXRCcm9hZGNhc3RzKCkgewogICAgdGhp
cy5yZXNldEZyYW1lcygpOwogICAgdGhpcy5icm9hZGNhc3RTdGF0dXMoKTsKICAgIHRoaXMuYnJv
YWRjYXN0TGlzdCgtMSwgLTEpOwogICAgdGhpcy5icm9hZGNhc3RNZW4oMSk7CiAgICB0aGlzLnJl
c2V0RnJhbWVzKCk7CiAgICB0aGlzLmJyb2FkY2FzdEdhbWVTZXR0aW5nKC0xKTsKICAgIHRoaXMu
YnJvYWRjYXN0U3RhdHVzKCk7CiAgfQoKICAvLyBUaGUgZnJhbWUgc2VuZGVycyAoYXYsIG9uZSBw
ZXIgY29tcHV0ZXIpOiBldmVyeSAxMCBtczsgYSBzZW5kIGlzIGR1ZSBhZnRlciBhbm90aGVyIGdh
bWUncyBwYWNrZXQKICAvLyBhbmQsIGJlc2lkZXMsIGV2ZXJ5IDEwMCB0byAyMDAgbXMuCiAgZmx1
c2hUaWNrKCkgewogICAgaWYgKHRoaXMuc3RhcnRpbmcpIHJldHVybjsKICAgIGZvciAobGV0IGlu
ZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgIGNvbnN0IHNsb3Qg
PSB0aGlzLnNsb3RzW2luZGV4XTsKICAgICAgc2xvdC50aWNrQ291bnQgPSAoc2xvdC50aWNrQ291
bnQgfHwgMCkgKyAxOwogICAgICBpZiAoc2xvdC50aWNrQ291bnQgPT09IDIwKSB7CiAgICAgICAg
c2xvdC50aWNrQ291bnQgPSB0aGlzLm5leHRJbnQoMTApOwogICAgICAgIHNsb3QuZmx1c2hlcyAr
PSAxOwogICAgICB9CiAgICAgIGlmIChzbG90LmZsdXNoZXMgPD0gMCkgY29udGludWU7CiAgICAg
IGlmIChzbG90LmZpZ2h0aW5nICYmIHNsb3QuY29ubmVjdGlvbikgc2xvdC5jb25uZWN0aW9uLnNl
bmRGcmFtZXMoKTsKICAgICAgc2xvdC5mbHVzaGVzIC09IDE7CiAgICB9CiAgfQoKICAvLyBUaGUg
d2F0Y2hkb2cgKGFBKTogcGluZ3MgcXVpZXQgZ2FtZXMsIGFuZCB0YWtlcyBvdXQgZ2FtZXMgc2ls
ZW50IGZvciAzNSBzIChvciBpZGxlIHRvbyBsb25nKS4KICB3YXRjaGRvZygpIHsKICAgIGNvbnN0
IG5vdyA9IERhdGUubm93KCk7CiAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgQ0xJRU5U
UzsgaW5kZXggKz0gMSkgewogICAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90c1tpbmRleF07CiAg
ICAgIGlmICghc2xvdC5vbmxpbmUpIGNvbnRpbnVlOwogICAgICBjb25zdCBhZmsgPSB0aGlzLmFm
a01pbnV0ZXMgKiA2MDAwMDsKICAgICAgaWYgKHNsb3QubGFzdE1lc3NhZ2UgPCBub3cgLSAzNTAw
MCB8fCAoYWZrID4gNjAwMDAgJiYgc2xvdC5sYXN0QWN0aXZlIDwgbm93IC0gYWZrKSkgewogICAg
ICAgIHRoaXMubG9nKGBoZiByb29tICR7dGhpcy5udW1iZXJ9OiAke3Nsb3QubmFtZX0gJHtzbG90
Lmxhc3RNZXNzYWdlIDwgbm93IC0gMzUwMDAgPyAndGltZWQgb3V0JyA6ICd3YXMgaWRsZSd9YCk7
CiAgICAgICAgdGhpcy5qb3QoYCR7c2xvdC5uYW1lfSAke3Nsb3QubGFzdE1lc3NhZ2UgPCBub3cg
LSAzNTAwMCA/IGB0aW1lZCBvdXQgKHNpbGVudCBmb3IgJHtNYXRoLnJvdW5kKChub3cgLSBzbG90
Lmxhc3RNZXNzYWdlKSAvIDEwMDApfSBzKWAgOiAnd2FzIGlkbGUgdG9vIGxvbmcnfSR7dGhpcy5m
aWdodGluZ05vdyA/IGAgZHVyaW5nIGEgZmlnaHQsIGxhc3QgcGFja2V0ICR7c2xvdC5sYXN0UGFj
a2V0fWAgOiAnJ31gKTsKICAgICAgICBjb25zdCBjb25uZWN0aW9uID0gc2xvdC5jb25uZWN0aW9u
OwogICAgICAgIGNvbm5lY3Rpb24ubGVhdmUoKTsKICAgICAgICBjb25uZWN0aW9uLmtpY2tlZCA9
IHRydWU7CiAgICAgICAgY29ubmVjdGlvbi5jbG9zZSgpOwogICAgICAgIGNvbnRpbnVlOwogICAg
ICB9CiAgICAgIGlmIChzbG90Lmxhc3RNZXNzYWdlIDwgbm93IC0gMjAwMDApIHNsb3QuY29ubmVj
dGlvbi5zZW5kKCc8cGluZz48L3Bpbmc+Jyk7CiAgICB9CiAgfQoKICAvLyBUaGUgbGluZSB0aGUg
cm9vbSBsaXN0IHNob3dzIGZvciB0aGlzIHJvb20uCiAgcGVvcGxlKCkgewogICAgcmV0dXJuIHRo
aXMub25saW5lKCkubWFwKChzbG90KSA9PiBgJHtzbG90Lm5hbWV9KCR7c2xvdC5sYXRlbmN5U2hv
d24gLSAxfSlgKS5qb2luKCcsICcpOwogIH0KfQoKLy8gLS0tLSBPbmUgY29tcHV0ZXIgaW4gYSBy
b29tICh0aGUgb3JpZ2luYWwncyB0aHJlYWQgImkiKSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tCgpjbGFzcyBIZkNvbm5lY3Rpb24gewogIC8vIHNvY2tldDogeyB3
cml0ZSh0ZXh0KSwgY2xvc2UoKSB9OyBmZWVkIGl0IHRoZSByZWNlaXZlZCBieXRlcyB3aXRoIHJl
Y2VpdmUoKSwgYW5kIGNsb3NlZCgpIGF0IHRoZSBlbmQuCiAgY29uc3RydWN0b3Iocm9vbSwgc29j
a2V0LCB7IGFkZHJlc3MgPSAnJywgYnVpbGQgPSAnJyB9ID0ge30pIHsKICAgIHRoaXMucm9vbSA9
IHJvb207CiAgICB0aGlzLnNvY2tldCA9IHNvY2tldDsKICAgIHRoaXMuYWRkcmVzcyA9IGFkZHJl
c3M7CiAgICB0aGlzLmJ1aWxkID0gYnVpbGQ7IC8vIHRoZSBwYWdlJ3MgbW92aWUgYW5kIFJ1ZmZs
ZSAoYWNjZXB0c0J1aWxkKQogICAgdGhpcy5pbmRleCA9IC0xOyAvLyBuCiAgICB0aGlzLm5hbWUg
PSAnJzsgLy8gbwogICAgdGhpcy5jYyA9ICcnOyAvLyBwCiAgICB0aGlzLnBsYXllcnMgPSBbJycs
ICcnLCAnJ107IC8vIHIKICAgIHRoaXMubGFzdEZyYW1lID0gLTE7IC8vIHM6IHRoZSBsYXN0IGZy
YW1lIG9mIHRoaXMgZ2FtZSdzLCBpbiBvcmRlcgogICAgdGhpcy5uZXh0RnJhbWUgPSAwOyAvLyB0
OiB0aGUgbmV4dCBmcmFtZSB0byBzZW5kIHRoaXMgZ2FtZQogICAgdGhpcy5xdWV1ZWQgPSAnJzsg
Ly8gdjogPHJwYz4gbGluZXMgZnJvbSB0aGUgb3RoZXJzLCBzZW50IHdpdGggdGhlIG5leHQgZnJh
bWVzIChub25lIG5vdzogUm9vbS5jaGVja1N0ZXApCiAgICB0aGlzLmNoZWF0ID0gMDsgLy8geAog
ICAgdGhpcy5raWNrZWQgPSBmYWxzZTsgLy8gYgogICAgdGhpcy5lbmRlZCA9IGZhbHNlOwogICAg
dGhpcy5saW5lcyA9IFtdOwogICAgdGhpcy53YWl0aW5nID0gbnVsbDsKICAgIHRoaXMuYnVmZmVy
ID0gQnVmZmVyLmFsbG9jKDApOwogICAgcm9vbS5jb25uZWN0aW9ucy5hZGQodGhpcyk7CiAgICB0
aGlzLmRvbmUgPSB0aGlzLnJ1bigpOwogIH0KCiAgLy8gLS0tLSBieXRlcyBpbiBhbmQgb3V0CiAg
cmVjZWl2ZShjaHVuaykgewogICAgaWYgKHRoaXMuZW5kZWQpIHJldHVybjsKICAgIHRoaXMuYnVm
ZmVyID0gdGhpcy5idWZmZXIubGVuZ3RoID8gQnVmZmVyLmNvbmNhdChbdGhpcy5idWZmZXIsIGNo
dW5rXSkgOiBCdWZmZXIuZnJvbShjaHVuayk7CiAgICBsZXQgc3RhcnQgPSAwOwogICAgZm9yIChs
ZXQgYXQgPSB0aGlzLmJ1ZmZlci5pbmRleE9mKDEwKTsgYXQgPj0gMDsgYXQgPSB0aGlzLmJ1ZmZl
ci5pbmRleE9mKDEwLCBzdGFydCkpIHsKICAgICAgbGV0IGxpbmUgPSB0aGlzLmJ1ZmZlci50b1N0
cmluZygndXRmOCcsIHN0YXJ0LCBhdCk7CiAgICAgIGlmIChsaW5lLmVuZHNXaXRoKCdccicpKSBs
aW5lID0gbGluZS5zbGljZSgwLCAtMSk7CiAgICAgIHN0YXJ0ID0gYXQgKyAxOwogICAgICB0aGlz
LnB1c2hMaW5lKGxpbmUpOwogICAgfQogICAgdGhpcy5idWZmZXIgPSB0aGlzLmJ1ZmZlci5zdWJh
cnJheShzdGFydCk7CiAgICBpZiAodGhpcy5idWZmZXIubGVuZ3RoID4gMjYyMTQ0KSB0aGlzLmNs
b3NlKCk7IC8vIG5vIGxpbmUgaXMgdGhhdCBsb25nCiAgfQoKICBjbG9zZWQoKSB7CiAgICBpZiAo
dGhpcy5lbmRlZCkgcmV0dXJuOwogICAgdGhpcy5lbmRlZCA9IHRydWU7CiAgICB0aGlzLnB1c2hM
aW5lKG51bGwpOwogIH0KCiAgcHVzaExpbmUobGluZSkgewogICAgaWYgKHRoaXMud2FpdGluZykg
ewogICAgICBjb25zdCByZXNvbHZlID0gdGhpcy53YWl0aW5nOwogICAgICB0aGlzLndhaXRpbmcg
PSBudWxsOwogICAgICByZXNvbHZlKGxpbmUpOwogICAgfSBlbHNlIHsKICAgICAgdGhpcy5saW5l
cy5wdXNoKGxpbmUpOwogICAgfQogIH0KCiAgcmVhZExpbmUoKSB7IC8vIEJ1ZmZlcmVkUmVhZGVy
LnJlYWRMaW5lOiBudWxsIGF0IHRoZSBlbmQKICAgIGlmICh0aGlzLmxpbmVzLmxlbmd0aCkgcmV0
dXJuIFByb21pc2UucmVzb2x2ZSh0aGlzLmxpbmVzLnNoaWZ0KCkpOwogICAgaWYgKHRoaXMuZW5k
ZWQpIHJldHVybiBQcm9taXNlLnJlc29sdmUobnVsbCk7CiAgICByZXR1cm4gbmV3IFByb21pc2Uo
KHJlc29sdmUpID0+IHsgdGhpcy53YWl0aW5nID0gcmVzb2x2ZTsgfSk7CiAgfQoKICBzZW5kKHRl
eHQpIHsgLy8gaS5hKFN0cmluZykKICAgIGlmICh0aGlzLmVuZGVkKSByZXR1cm47CiAgICB0cnkg
eyB0aGlzLnNvY2tldC53cml0ZSh0ZXh0ICsgJ1xuJyk7IH0gY2F0Y2ggeyAvKiB0aGUgY2xvc2lu
ZyBmb2xsb3dzICovIH0KICB9CgogIGNsb3NlKCkgewogICAgaWYgKCF0aGlzLnNvY2tldENsb3Nl
ZCkgewogICAgICB0aGlzLnNvY2tldENsb3NlZCA9IHRydWU7CiAgICAgIHRyeSB7IHRoaXMuc29j
a2V0LmNsb3NlKCk7IH0gY2F0Y2ggeyAvKiBhbHJlYWR5IGNsb3NlZCAqLyB9CiAgICB9CiAgICB0
aGlzLmNsb3NlZCgpOwogIH0KCiAgZ2V0IHNsb3QoKSB7IHJldHVybiB0aGlzLnJvb20uc2xvdHNb
dGhpcy5pbmRleF07IH0KCiAgLy8gLS0tLSB0aGUgY29udmVyc2F0aW9uCiAgYXN5bmMgcnVuKCkg
ewogICAgdHJ5IHsKICAgICAgYXdhaXQgdGhpcy5jb252ZXJzYXRpb24oKTsKICAgIH0gY2F0Y2gg
KGVycm9yKSB7CiAgICAgIGlmICghKGVycm9yIGluc3RhbmNlb2YgWG1sRXJyb3IpKSB0aGlzLnJv
b20ubG9nKGBoZiByb29tICR7dGhpcy5yb29tLm51bWJlcn06ICR7ZXJyb3Iuc3RhY2sgfHwgZXJy
b3J9YCk7CiAgICB9IGZpbmFsbHkgewogICAgICB0aGlzLmxlYXZlKCk7IC8vIGkuaAogICAgICB0
aGlzLnJvb20uY29ubmVjdGlvbnMuZGVsZXRlKHRoaXMpOwogICAgICB0aGlzLmNsb3NlKCk7CiAg
ICB9CiAgfQoKICBhc3luYyBjb252ZXJzYXRpb24oKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5y
b29tOwogICAgYXdhaXQgc2xlZXAoMjUwKTsKICAgIHRoaXMuc2VuZCgnPGluaT48L2luaT4nKTsK
ICAgIGF3YWl0IHNsZWVwKDI1MCk7CiAgICBpZiAocm9vbS5jbG9zZWQpIHJldHVybjsKICAgIGxl
dCBsaW5lID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpOwogICAgaWYgKGxpbmUgPT09IG51bGwpIHJl
dHVybjsKICAgIGNvbnN0IGpvaW4gPSBwYXJzZVhtbChsaW5lKTsKICAgIGNvbnN0IHZlcnNpb25z
ID0gYnlUYWcoam9pbiwgJ3ZlcicpOwogICAgaWYgKCF2ZXJzaW9ucy5sZW5ndGgpIHJldHVybjsK
ICAgIGlmIChpbnQodmFsdWVPZih2ZXJzaW9uc1swXSkpICE9PSBWRVJTSU9OKSByZXR1cm4gdGhp
cy5yZWZ1c2UoJ3YnKTsKICAgIGlmICghcm9vbS5hY2NlcHRzQnVpbGQodGhpcy5idWlsZCkpIHsK
ICAgICAgcm9vbS5sb2coYGhmIHJvb20gJHtyb29tLm51bWJlcn06IGEgZ2FtZSBvZiBhbm90aGVy
IGJ1aWxkICgke3RoaXMuYnVpbGQgfHwgJ25vbmUnfSwgdGhlIHJvb20gaGFzICR7cm9vbS5idWls
ZH0pIHR1cm5lZCBhd2F5YCk7CiAgICAgIHJldHVybiB0aGlzLnJlZnVzZSgndicpOwogICAgfQog
ICAgaWYgKHJvb20uY29ubmVjdGVkID49IHJvb20ubGltaXQpIHJldHVybiB0aGlzLnJlZnVzZSgn
ZicpOwogICAgaWYgKCFyb29tLmFsbG93Sm9pbldoZW5GaWdodGluZyAmJiByb29tLmZpZ2h0aW5n
Tm93KSByZXR1cm4gdGhpcy5yZWZ1c2UoJ3AnKTsKICAgIGlmIChyb29tLnBhc3N3b3JkKSB7CiAg
ICAgIHRoaXMuc2VuZCgnPHJlcV9wdz48L3JlcV9wdz4nKTsKICAgICAgbGluZSA9IGF3YWl0IHRo
aXMucmVhZExpbmUoKTsKICAgICAgaWYgKGxpbmUgPT09IG51bGwpIHJldHVybjsKICAgICAgaWYg
KHJvb20ucGFzc3dvcmQgIT09IHRhZ1ZhbHVlKHBhcnNlWG1sKGxpbmUpLCAncHdkJykpIHJldHVy
biB0aGlzLnJlZnVzZSgncHdkJyk7CiAgICB9CiAgICBjb25zdCBsYXRlbmN5ID0gYXdhaXQgdGhp
cy5tZWFzdXJlKCk7CiAgICBpZiAobGF0ZW5jeSA9PT0gbnVsbCkgcmV0dXJuOwogICAgaWYgKHJv
b20ubGF0ZW5jeUxpbWl0ICE9PSAtMSAmJiBsYXRlbmN5ID4gcm9vbS5sYXRlbmN5TGltaXQpIHJl
dHVybiB0aGlzLnJlZnVzZSgnbCcpOwogICAgdGhpcy5zZW5kKGA8bWF4Y2xpZW50cz48bWF4Y2xp
ZW50cz4ke3Jvb20ubGltaXR9PC9tYXhjbGllbnRzPjwvbWF4Y2xpZW50cz5gKTsKICAgIHRoaXMu
c2VuZChgPHJwPjxycD4ke3Jvb20uc2VlZH08L3JwPjwvcnA+YCk7CiAgICBmb3IgKGxldCBwYXJ0
ID0gMDsgcGFydCA8IDEwOyBwYXJ0ICs9IDEpIHsKICAgICAgbGV0IHRleHQgPSBgPHJhbmQ+PGk+
JHtwYXJ0ICogNTAwfTwvaT5gOwogICAgICBmb3IgKGxldCBrID0gMDsgayA8IDUwMDsgayArPSAx
KSB0ZXh0ICs9IGA8bj4ke3Jvb20udGFibGVbayArIHBhcnQgKiA1MDBdfTwvbj5gOwogICAgICB0
aGlzLnNlbmQodGV4dCArICc8L3JhbmQ+Jyk7CiAgICB9CiAgICB0aGlzLnNlbmQoJzxyZXFfaW5m
bz48L3JlcV9pbmZvPicpOwogICAgbGluZSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKTsKICAgIGlm
IChsaW5lID09PSBudWxsIHx8IHJvb20uY2xvc2VkKSByZXR1cm47CiAgICByb29tLnJlY291bnQo
KTsKICAgIGlmIChyb29tLmNvbm5lY3RlZCA+PSByb29tLmxpbWl0KSByZXR1cm4gdGhpcy5yZWZ1
c2UoJ2YnKTsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCAr
PSAxKSB7CiAgICAgIGlmICghcm9vbS5zbG90c1tpbmRleF0ub25saW5lKSB7IHRoaXMuaW5kZXgg
PSBpbmRleDsgYnJlYWs7IH0KICAgIH0KICAgIGlmICh0aGlzLmluZGV4IDwgMCkgcmV0dXJuIHRo
aXMucmVmdXNlKCdmJyk7CiAgICBjb25zdCBpbmZvID0gcGFyc2VYbWwobGluZSk7CiAgICB0aGlz
Lm5hbWUgPSB0YWdWYWx1ZShpbmZvLCAnbmFtZScpOwogICAgY29uc3QgY2NzID0gYnlUYWcoaW5m
bywgJ2NjJyk7CiAgICB0aGlzLmNjID0gY2NzLmxlbmd0aCA/IHZhbHVlT2YoY2NzWzBdKSA6ICcn
OwogICAgY29uc3Qgc2xvdCA9IHRoaXMuc2xvdDsKICAgIGZvciAobGV0IGsgPSAwOyBrIDwgMzsg
ayArPSAxKSB0aGlzLnBsYXllcnNba10gPSB0YWdWYWx1ZShpbmZvLCAncCcsIGspOwogICAgZm9y
IChsZXQgayA9IDA7IGsgPCAzMDsgayArPSAxKSB7CiAgICAgIHNsb3QubGV2ZWxzW2tdID0gaW50
KHRhZ1ZhbHVlKGluZm8sICdsJywgaykpOwogICAgICBpZiAoc2xvdC5sZXZlbHNba10gPiBNQVhf
TEVWRUwpIHRoaXMuY2hlYXQgPSAxOwogICAgfQogICAgc2xvdC5sZXZlbHNbMjBdID0gc2xvdC5s
ZXZlbHNbOF07CiAgICBzbG90Lm5hbWUgPSB0aGlzLm5hbWU7CiAgICBzbG90LmNjID0gdGhpcy5j
YzsKICAgIHNsb3QuY291bnRyeSA9IHRoaXMuY2MgfHwgJ3Vua25vd24nOwogICAgc2xvdC5wbGF5
ZXJzID0gWy4uLnRoaXMucGxheWVyc107CiAgICBzbG90Lmxhc3RNZXNzYWdlID0gc2xvdC5sYXN0
QWN0aXZlID0gRGF0ZS5ub3coKTsKICAgIHNsb3QuY29ubmVjdGlvbiA9IHRoaXM7CiAgICBzbG90
Lm9ubGluZSA9IHRydWU7CiAgICBzbG90LnBhdXNlZCA9IGZhbHNlOwogICAgc2xvdC5oYXNQbGF5
ZXIgPSBmYWxzZTsKICAgIHNsb3QubGF0ZW5jeSA9IHNsb3QubGF0ZW5jeVRhcmdldCA9IHNsb3Qu
bGF0ZW5jeVNob3duID0gbGF0ZW5jeTsKICAgIHNsb3QucGFnZSA9ICdXQUlUUk9PTSc7CiAgICBz
bG90LmFkbWluID0gZmFsc2U7CiAgICByb29tLnJlY291bnQoKTsKICAgIHRoaXMuc2VuZFNldHRp
bmcoLTEpOwogICAgdGhpcy5zZW5kR2FtZVNldHRpbmcoLTEpOwogICAgdGhpcy5zZW5kTGlzdCgt
MSwgLTEpOwogICAgdGhpcy5zZW5kTWVuKDEpOwogICAgaWYgKCFyb29tLmZpZ2h0aW5nTm93KSB7
CiAgICAgIGlmIChyb29tLnBhZ2UgIT09ICdXQUlUUk9PTScpIHsKICAgICAgICBpZiAocm9vbS5t
b2RlID09PSAnVlNNT0RFJykgcm9vbS5wYWdlID0gJ0NIQVJNRU5VJzsKICAgICAgfSBlbHNlIHsK
ICAgICAgICByb29tLnBhZ2UgPSAnV0FJVFJPT00nOwogICAgICAgIHJvb20ubW9kZSA9ICdXQUlU
Uk9PTSc7CiAgICAgIH0KICAgIH0KICAgIHJvb20uYnJvYWRjYXN0U3RhdHVzKCk7CiAgICByb29t
LmxvZyhgaGYgcm9vbSAke3Jvb20ubnVtYmVyfTogJHt0aGlzLm5hbWV9IChsYXRlbmN5ICR7bGF0
ZW5jeSAtIDF9KSBqb2luc2ApOwogICAgcm9vbS5qb3QoYCR7dGhpcy5uYW1lfSBqb2lucyAobGF0
ZW5jeSAke2xhdGVuY3kgLSAxfSwgYnVpbGQgJHt0aGlzLmJ1aWxkIHx8ICd1bmtub3duJ30sIGZy
b20gJHt0aGlzLmFkZHJlc3MgfHwgJz8nfSkke3Jvb20uZmlnaHRpbmdOb3cgPyAnIGR1cmluZyBh
IGZpZ2h0JyA6ICcnfWApOwogICAgcm9vbS5icm9hZGNhc3RMaXN0KHRoaXMuaW5kZXgsIC0xKTsK
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
ICAgICAgICBzbG90LmZyYW1lc1tmcmFtZSAlIEZSQU1FU19LRVBUXSA9IGxpbmU7CiAgICAgICAg
dGhpcy5sYXN0RnJhbWUgPSBmcmFtZTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBp
ZiAoa2luZCA9PT0gJ3BrJykgeyAvLyB0aGUgZW5kIG9mIGEgcGFja2V0OiB0aGUgb3RoZXJzIG1h
eSBnZXQgdGhpcyBnYW1lJ3MgZnJhbWVzCiAgICAgIHNsb3QubGFzdFBhY2tldCA9IHRoaXMubGFz
dEZyYW1lOwogICAgICB0aGlzLnJlcXVlc3RGbHVzaGVzKCk7CiAgICAgIHJldHVybjsKICAgIH0K
ICAgIGlmIChraW5kID09PSAndCcpIHsKICAgICAgc2xvdC50aW1lcy5wdXNoKGludCh0YWdWYWx1
ZShkb2MsICdkJykpKTsKICAgICAgaWYgKHNsb3QudGltZXMubGVuZ3RoID4gMjApIHNsb3QudGlt
ZXMuc2hpZnQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdycGMnKSB7
CiAgICAgIHJvb20uY2hlY2tTdGVwKHRoaXMuaW5kZXgsIGludCh0YWdWYWx1ZShkb2MsICdjbCcp
KSwgaW50KHRhZ1ZhbHVlKGRvYywgJ3JwJykpKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYg
KGtpbmQgPT09ICdjaGF0JykgewogICAgICBjb25zdCBmcm9tID0gaW50KHRhZ1ZhbHVlKGRvYywg
J2MnKSk7CiAgICAgIGlmIChmcm9tIDwgMCB8fCBmcm9tID49IFNMT1RTKSB0aHJvdyBuZXcgWG1s
RXJyb3IoJ25vIHN1Y2ggY29tcHV0ZXInKTsKICAgICAgaWYgKHRoaXMuY29tbWFuZCh0YWdWYWx1
ZShkb2MsICdtJykpKSByb29tLmJyb2FkY2FzdChsaW5lKTsKICAgICAgcmV0dXJuOwogICAgfQog
ICAgaWYgKGtpbmQgPT09ICdwYXVzZWdhbWUnIHx8IGtpbmQgPT09ICdyZXN1bWVnYW1lJykgewog
ICAgICBzbG90LnBhdXNlZCA9IGtpbmQgPT09ICdwYXVzZWdhbWUnOwogICAgICBpZiAocm9vbS5m
aWdodGluZ05vdykgcm9vbS5qb3QoYCR7c2xvdC5uYW1lfSAke2tpbmQgPT09ICdwYXVzZWdhbWUn
ID8gJ3BhdXNlcycgOiAncmVzdW1lcyd9IGF0IGZyYW1lICR7c2xvdC5sYXN0UGFja2V0fWApOwog
ICAgICByb29tLmJyb2FkY2FzdExpc3QoLTEsIC0xKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
aWYgKGtpbmQgPT09ICdzdGFydGNvdW50JykgcmV0dXJuIHRoaXMuc3RhcnRDb3VudChkb2MpOwog
ICAgaWYgKGtpbmQgPT09ICdjYW5jZWxjb3VudCcpIHsKICAgICAgY29uc3QgY291bnRkb3duID0g
cm9vbS5jb3VudGRvd247CiAgICAgIGlmIChjb3VudGRvd24ub24gJiYgKGNvdW50ZG93bi5hY3Rp
b24gPT09ICdjbGlja2ZpZ2h0JyB8fCBjb3VudGRvd24uYWN0aW9uID09PSB0YWdWYWx1ZShkb2Ms
ICdhY3Rpb24nKSkpIHsKICAgICAgICBjb3VudGRvd24ub24gPSBmYWxzZTsKICAgICAgICBjb3Vu
dGRvd24uYWN0aW9uID0gJyc7CiAgICAgICAgY291bnRkb3duLmNvdW50ID0gQ09VTlRET1dOOwog
ICAgICAgIHJvb20uYnJvYWRjYXN0Q2xpY2sodGhpcy5pbmRleCwgJ2NsaWNrY2FuY2VsJyk7CiAg
ICAgICAgcm9vbS5icm9hZGNhc3QoJzxjYW5jZWxjb3VudD48L2NhbmNlbGNvdW50PicpOwogICAg
ICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnc2V0dGluZycpIHsKICAg
ICAgaWYgKHJvb20ucGFnZSA9PT0gJ1dBSVRST09NJykgewogICAgICAgIGNvbnN0IGFsbG93ID0g
YnlUYWcoZG9jLCAnd2FpdHdoZW5maWdodCcpOwogICAgICAgIGlmIChhbGxvdy5sZW5ndGgpIHJv
b20uYWxsb3dKb2luV2hlbkZpZ2h0aW5nID0gdmFsdWVPZihhbGxvd1swXSkgPT09ICcxJzsKICAg
ICAgICByb29tLmJyb2FkY2FzdFNldHRpbmcodGhpcy5pbmRleCk7CiAgICAgIH0KICAgICAgcmV0
dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdnYW1lc2V0dGluZycpIHJldHVybiB0aGlzLmdh
bWVTZXR0aW5nKGRvYyk7CiAgICBpZiAoa2luZCA9PT0gJ2NsaWNrYmFjaycpIHJldHVybiB0aGlz
LmNsaWNrQmFjayhkb2MpOwogICAgaWYgKGtpbmQgPT09ICdwYWdlJykgewogICAgICBzbG90LnBh
Z2UgPSB2YWx1ZU9mKGRvYyk7CiAgICAgIHNsb3QuZmlnaHRpbmcgPSBzbG90LnBhZ2UgPT09ICdG
SUdIVElORyc7CiAgICAgIHJvb20uYnJvYWRjYXN0TGlzdCgtMSwgLTEpOwogICAgICByZXR1cm47
CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ2luZm8nKSByZXR1cm4gdGhpcy51cGRhdGVJbmZvKGRv
Yyk7CiAgICBpZiAoa2luZCA9PT0gJ2FkZHBsYXllcicpIHJldHVybiB0aGlzLmFkZFBsYXllcihk
b2MpOwogICAgaWYgKGtpbmQgPT09ICdkZWxtYW4nKSB7CiAgICAgIGlmIChyb29tLnBhZ2UgIT09
ICdDSEFSTUVOVScpIHJldHVybjsKICAgICAgY29uc3QgaW5kZXggPSBpbnQodmFsdWVPZihkb2Mp
KTsKICAgICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhdOwogICAgICBpZiAoIW1hbikgdGhy
b3cgbmV3IFhtbEVycm9yKCdubyBzdWNoIG1hbicpOwogICAgICBpZiAobWFuLmV4aXN0cyAmJiAo
KG1hbi5jb250cm9sbGVyID09PSAtMSAmJiAhcm9vbS5jb3VudGRvd24ub24pIHx8IG1hbi5jbGll
bnQgPT09IHRoaXMuaW5kZXgpKSB7CiAgICAgICAgbWFuLmV4aXN0cyA9IGZhbHNlOwogICAgICAg
IGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5tZW4pIGlmIChvdGhlci5leGlzdHMgJiYgb3RoZXIu
Y29tbWFuZGVyID09PSBpbmRleCkgb3RoZXIuZXhpc3RzID0gZmFsc2U7CiAgICAgICAgcm9vbS5i
cm9hZGNhc3RNZW4oMSk7CiAgICAgIH0KICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQg
PT09ICdhZGRjb20nKSB7CiAgICAgIGlmIChyb29tLnBhZ2UgIT09ICdDSEFSTUVOVScpIHJldHVy
bjsKICAgICAgaWYgKCFyb29tLmNvdW50ZG93bi5vbiAmJiB0aGlzLmFkZENvbXB1dGVyKCkpIHsK
ICAgICAgICB0aGlzLmxpbWl0TWVuKCk7CiAgICAgICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAg
ICAgIH0KICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICdhZGRzb2xkaWVyJykg
cmV0dXJuIHRoaXMuYWRkU29sZGllcihkb2MpOwogICAgaWYgKGtpbmQgPT09ICdyZWRvcmFuZG9t
JykgewogICAgICBpZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47CiAgICAgIGlm
ICghcm9vbS5jb3VudGRvd24ub24pIHsKICAgICAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4
IDwgTUVOOyBpbmRleCArPSAxKSBpZiAocm9vbS5tZW5baW5kZXhdLmV4aXN0cyAmJiByb29tLm1l
bltpbmRleF0ucmFuZG9tKSB0aGlzLnBpY2tDaGFyYWN0ZXIoaW5kZXgpOwogICAgICAgIHJvb20u
YnJvYWRjYXN0TWVuKDApOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5k
ID09PSAnbWFudGVhbScpIHsKICAgICAgaWYgKHJvb20ucGFnZSAhPT0gJ0NIQVJNRU5VJykgcmV0
dXJuOwogICAgICBjb25zdCBpbmRleCA9IGludCh0YWdWYWx1ZShkb2MsICdpJykpOwogICAgICBj
b25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICAgIGlmICghbWFuKSB0aHJvdyBuZXcgWG1s
RXJyb3IoJ25vIHN1Y2ggbWFuJyk7CiAgICAgIGlmIChtYW4uZXhpc3RzICYmIChtYW4uY29udHJv
bGxlciA9PT0gLTEgfHwgbWFuLmNsaWVudCA9PT0gdGhpcy5pbmRleCkpIHsKICAgICAgICBjb25z
dCB0ZWFtID0gaW50KHRhZ1ZhbHVlKGRvYywgJ3RlYW0nKSk7CiAgICAgICAgbWFuLnRlYW0gPSB0
ZWFtOwogICAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5tZW4pIGlmIChvdGhlci5leGlz
dHMgJiYgb3RoZXIuY29tbWFuZGVyID09PSBpbmRleCkgb3RoZXIudGVhbSA9IHRlYW07CiAgICAg
ICAgaWYgKHJvb20ubW9kZSA9PT0gJ0JBVFRMRU1PREUnICYmIG1hbi5jb250cm9sbGVyID49IDAp
IHsKICAgICAgICAgIHJvb20ubWVuLmZvckVhY2goKG90aGVyLCBrKSA9PiB7IGlmIChrICE9PSBp
bmRleCAmJiBvdGhlci5leGlzdHMgJiYgb3RoZXIuY2xpZW50ID09PSBtYW4uY2xpZW50KSBvdGhl
ci50ZWFtID0gdGVhbTsgfSk7CiAgICAgICAgfQogICAgICAgIHJvb20uYnJvYWRjYXN0TWVuKDAp
OwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnbWFuY2hhcicp
IHJldHVybiB0aGlzLmNob29zZUNoYXJhY3Rlcihkb2MpOwogICAgaWYgKGtpbmQgPT09ICdpbmNy
ZWFzZWxhdGVuY3knKSB7CiAgICAgIHNsb3QubGF0ZW5jeSArPSAyOwogICAgICBzbG90LmxhdGVu
Y3lUYXJnZXQgKz0gMjsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgIHJl
dHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAncmVtZWFzdXJlJykgewogICAgICBsZXQgYmVz
dCA9IDUwMDA7CiAgICAgIGZvciAobGV0IGsgPSAwOyBrIDwgMTA7IGsgKz0gMSkgewogICAgICAg
IGNvbnN0IHNlbnQgPSBEYXRlLm5vdygpOwogICAgICAgIHRoaXMuc2VuZCgnPHBpbmc+PC9waW5n
PicpOwogICAgICAgIGZvciAobGV0IHJlcGx5ID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpOyByZXBs
eSAhPT0gJzxwaW5nb2s+PC9waW5nb2s+JzsgcmVwbHkgPSBhd2FpdCB0aGlzLnJlYWRMaW5lKCkp
IHsKICAgICAgICAgIGlmIChyZXBseSA9PT0gbnVsbCkgdGhyb3cgbmV3IFhtbEVycm9yKCdjbG9z
ZWQnKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgdG9vayA9IERhdGUubm93KCkgLSBzZW50Owog
ICAgICAgIGlmICh0b29rIDwgYmVzdCkgYmVzdCA9IHRvb2s7CiAgICAgICAgYXdhaXQgc2xlZXAo
dG9vayA8IDUwMCA/IHRvb2sgOiA1MDApOwogICAgICB9CiAgICAgIGlmIChiZXN0IDw9IDApIGJl
c3QgPSAxOwogICAgICBiZXN0ICs9IDE1OwogICAgICBzbG90LmxhdGVuY3kgPSBTVEVQICsgTWF0
aC5jZWlsKChiZXN0ICogMS43ICsgMC4xNikgLyAzMyAvIFNURVApICogU1RFUDsKICAgICAgc2xv
dC5sYXRlbmN5VGFyZ2V0ID0gc2xvdC5sYXRlbmN5OwogICAgICBzbG90LmxhdGVuY3lTaG93biA9
IHNsb3QubGF0ZW5jeTsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgIHJl
dHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnc3RhcnRlZGdhbWUnKSB7CiAgICAgIHNsb3Qu
ZmlnaHRpbmcgPSB0cnVlOwogICAgICBzbG90Lmhhc1BsYXllciA9IGZhbHNlOwogICAgICB0aGlz
LnJlc2V0RnJhbWVzKCk7CiAgICAgIGZvciAobGV0IGsgPSAwOyBrIDwgMzsgayArPSAxKSB7CiAg
ICAgICAgaWYgKCFyb29tLm1lblt0aGlzLmluZGV4ICogMyArIGtdLmV4aXN0cykgeyBzbG90Lmhh
c1BsYXllciA9IHRydWU7IGJyZWFrOyB9CiAgICAgIH0KICAgICAgc2xvdC5zdGFydGVkID0gdHJ1
ZTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICd3aW50ZWFtJykgewogICAg
ICBjb25zdCB0ZWFtID0gaW50KHRhZ1ZhbHVlKGRvYywgJ3dpbnRlYW0nKSk7CiAgICAgIGlmICgh
cm9vbS53aW5SZXBvcnRlZCkgewogICAgICAgIHJvb20ud2luUmVwb3J0ZWQgPSB0cnVlOwogICAg
ICAgIHJvb20ubG9nKGBoZiByb29tICR7cm9vbS5udW1iZXJ9OiAke3Jvb20ubW9kZX0gd29uIGJ5
ICR7dGVhbX1gKTsKICAgICAgICByb29tLmpvdChgJHtyb29tLm1vZGV9IHdvbiBieSB0ZWFtICR7
dGVhbX0gKHJlcG9ydGVkIGJ5ICR7c2xvdC5uYW1lfSBhdCBmcmFtZSAke3Nsb3QubGFzdFBhY2tl
dH0pYCk7CiAgICAgIH0KICAgIH0KICB9CgogIC8vIGkuaSgpOiB0aGlzIGdhbWUncyBwYWNrZXQg
Y2FtZTsgZWFjaCBvdGhlciBmaWdodGluZyBnYW1lIGdldHMgYSBzZW5kLgogIHJlcXVlc3RGbHVz
aGVzKCkgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGlmICghcm9vbS5maWdodGlu
Z05vdykgcmV0dXJuOwogICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGlu
ZGV4ICs9IDEpIHsKICAgICAgaWYgKGluZGV4ICE9PSB0aGlzLmluZGV4ICYmIHJvb20uc2xvdHNb
aW5kZXhdLmZpZ2h0aW5nKSByb29tLnNsb3RzW2luZGV4XS5mbHVzaGVzICs9IDE7CiAgICB9CiAg
fQoKICAvLyBpLmIoKTogdGhlIGZyYW1lcyBvZiB0aGUgb3RoZXJzIHRoaXMgZ2FtZSBoYXMgbm90
IGhhZCwgYXMgbG9uZyBhcyBldmVyeSBvdGhlciBnYW1lIHNlbnQgdGhlbS4KICBzZW5kRnJhbWVz
KCkgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGxldCB0ZXh0ID0gJyc7CiAgICBm
b3IgKDs7KSB7CiAgICAgIGNvbnN0IHQgPSB0aGlzLm5leHRGcmFtZTsKICAgICAgbGV0IGNvbXBs
ZXRlID0gdHJ1ZTsKICAgICAgbGV0IGFueSA9IGZhbHNlOwogICAgICBmb3IgKGxldCBpbmRleCA9
IDA7IGluZGV4IDwgQ0xJRU5UUzsgaW5kZXggKz0gMSkgewogICAgICAgIGlmIChpbmRleCA9PT0g
dGhpcy5pbmRleCkgY29udGludWU7CiAgICAgICAgY29uc3Qgb3RoZXIgPSByb29tLnNsb3RzW2lu
ZGV4XTsKICAgICAgICBpZiAoIW90aGVyLmZpZ2h0aW5nICYmIG90aGVyLmxlZnRGcmFtZSA8IHQp
IGNvbnRpbnVlOwogICAgICAgIGFueSA9IHRydWU7CiAgICAgICAgaWYgKG90aGVyLmxhc3RQYWNr
ZXQgPCB0KSB7IGNvbXBsZXRlID0gZmFsc2U7IGJyZWFrOyB9CiAgICAgIH0KICAgICAgaWYgKCFj
b21wbGV0ZSB8fCAhYW55KSBicmVhazsKICAgICAgbGV0IHBhcnQgPSAnJzsKICAgICAgZm9yIChs
ZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgICBpZiAo
aW5kZXggPT09IHRoaXMuaW5kZXgpIGNvbnRpbnVlOwogICAgICAgIGNvbnN0IG90aGVyID0gcm9v
bS5zbG90c1tpbmRleF07CiAgICAgICAgaWYgKChvdGhlci5maWdodGluZyB8fCBvdGhlci5sZWZ0
RnJhbWUgPj0gdCkgJiYgb3RoZXIubGFzdFBhY2tldCA+PSB0KSBwYXJ0ICs9IG90aGVyLmZyYW1l
c1t0ICUgRlJBTUVTX0tFUFRdIHx8ICcnOwogICAgICB9CiAgICAgIGlmICghcGFydCkgYnJlYWs7
CiAgICAgIHRleHQgKz0gcGFydDsKICAgICAgdGhpcy5uZXh0RnJhbWUgKz0gMTsKICAgIH0KICAg
IGlmICghdGV4dCkgcmV0dXJuOwogICAgaWYgKHRoaXMucXVldWVkKSB7CiAgICAgIHRleHQgKz0g
dGhpcy5xdWV1ZWQ7CiAgICAgIHRoaXMucXVldWVkID0gJyc7CiAgICB9CiAgICB0aGlzLnNlbmQo
dGV4dCk7CiAgfQoKICByZXNldEZyYW1lcygpIHsgLy8gaS5jKCkKICAgIHRoaXMubGFzdEZyYW1l
ID0gLTE7CiAgICB0aGlzLm5leHRGcmFtZSA9IDA7CiAgICB0aGlzLnF1ZXVlZCA9ICcnOwogIH0K
CiAgLy8gaS5hKCk6IHRoaXMgY29tcHV0ZXIgbGVhdmVzIHRoZSByb29tLgogIGxlYXZlKCkgewog
ICAgaWYgKHRoaXMuaW5kZXggPT09IC0xKSByZXR1cm47CiAgICBjb25zdCByb29tID0gdGhpcy5y
b29tOwogICAgY29uc3QgaW5kZXggPSB0aGlzLmluZGV4OwogICAgdGhpcy5yZXF1ZXN0Rmx1c2hl
cygpOwogICAgY29uc3Qgc2xvdCA9IHJvb20uc2xvdHNbaW5kZXhdOwogICAgaWYgKHNsb3Qub25s
aW5lICYmIHNsb3QuY29ubmVjdGlvbiA9PT0gdGhpcykgewogICAgICBmb3IgKGNvbnN0IG1hbiBv
ZiByb29tLm1lbikgewogICAgICAgIGlmIChtYW4uY2xpZW50ICE9PSBpbmRleCAmJiAobWFuLmNv
bW1hbmRlciA8IGluZGV4ICogMyB8fCBtYW4uY29tbWFuZGVyID4gaW5kZXggKiAzICsgMikpIGNv
bnRpbnVlOwogICAgICAgIE9iamVjdC5hc3NpZ24obWFuLCBuZXdNYW4oKSwgeyByYW5kb206IHRy
dWUgfSk7CiAgICAgICAgbWFuLmNoYXIgPSAnJzsKICAgICAgfQogICAgICBzbG90LmFkbWluID0g
ZmFsc2U7CiAgICAgIHNsb3Qub25saW5lID0gZmFsc2U7CiAgICAgIGlmIChzbG90Lmxhc3RQYWNr
ZXQgPiAwKSBzbG90LmxlZnRGcmFtZSA9IHNsb3QubGFzdFBhY2tldDsKICAgICAgc2xvdC5maWdo
dGluZyA9IGZhbHNlOwogICAgICBzbG90Lmhhc1BsYXllciA9IGZhbHNlOwogICAgICBzbG90LmNv
bm5lY3Rpb24gPSBudWxsOwogICAgICBpZiAoIXJvb20uZmlnaHRpbmdOb3cpIHJvb20uYnJvYWRj
YXN0TWVuKDEpOwogICAgICByb29tLmJyb2FkY2FzdExpc3QoLTEsIGluZGV4KTsKICAgICAgdGhp
cy5pbmRleCA9IC0xOwogICAgICByb29tLmxvZyhgaGYgcm9vbSAke3Jvb20ubnVtYmVyfTogJHt0
aGlzLm5hbWV9IGxlYXZlc2ApOwogICAgICByb29tLmpvdChgJHt0aGlzLm5hbWV9IGxlYXZlcyR7
dGhpcy5raWNrZWQgPyAnICh0YWtlbiBvdXQpJyA6ICcnfSR7cm9vbS5maWdodGluZ05vdyA/IGAg
ZHVyaW5nIGEgZmlnaHQsIGF0IGZyYW1lICR7c2xvdC5sZWZ0RnJhbWV9YCA6ICcnfWApOwogICAg
ICByb29tLnJlY291bnQoKTsKICAgIH0KICAgIHRoaXMuaW5kZXggPSAtMTsKICB9CgogIC8vIC0t
LS0gd2hhdCB0aGUgc2VydmVyIHNlbmRzIG9uZSBnYW1lCiAgc2VuZFNldHRpbmcoY2lkKSB7IC8v
IGkuYShpbnQpCiAgICB0aGlzLnNlbmQoYDxzZXR0aW5nPiR7Y2lkICE9PSAtMSA/IGA8Yz4ke2Np
ZH08L2M+YCA6ICcnfTx3YWl0d2hlbmZpZ2h0PiR7dGhpcy5yb29tLmFsbG93Sm9pbldoZW5GaWdo
dGluZyA/IDEgOiAwfTwvd2FpdHdoZW5maWdodD48L3NldHRpbmc+YCk7CiAgfQoKICBzZW5kR2Ft
ZVNldHRpbmcoY2lkKSB7IC8vIGkuYihpbnQpCiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwog
ICAgdGhpcy5zZW5kKGA8Z2FtZXNldHRpbmc+JHtjaWQgIT09IC0xID8gYDxjPiR7Y2lkfTwvYz5g
IDogJyd9PGJnaWQ+JHtyb29tLmJhY2tncm91bmR9PC9iZ2lkPjxtdXNpY2lkPiR7cm9vbS5tdXNp
Y308L211c2ljaWQ+YAogICAgICArIGA8bXA+JHtyb29tLm11bHRpcGxhbmUgPyAxIDogMH08L21w
PjxiZ3JhbmRvbT4ke3Jvb20uYmFja2dyb3VuZFJhbmRvbSA/IDEgOiAwfTwvYmdyYW5kb20+YAog
ICAgICArIGA8bXVzaWNyYW5kb20+JHtyb29tLm11c2ljUmFuZG9tID8gMSA6IDB9PC9tdXNpY3Jh
bmRvbT48aG9yc2U+JHtyb29tLmhvcnNlc308L2hvcnNlPmAKICAgICAgKyBgPGdpYW50b2JqPiR7
cm9vbS5naWFudE9iamVjdHN9PC9naWFudG9iaj48ZGlmZj4ke3Jvb20uZGlmZmljdWx0eX08L2Rp
ZmY+PG5vcmxldj4ke3Jvb20ubm9ybWFsaXplTGV2ZWx9PC9ub3JsZXY+YAogICAgICArIGA8ZGlu
bz4ke3Jvb20uZGlub3NhdXJzfTwvZGlubz48dGVzdHRyb29wPiR7cm9vbS50ZXN0VHJvb3BzfTwv
dGVzdHRyb29wPjxzb2xkaWVybnVtYmVyPiR7cm9vbS5zb2xkaWVyTnVtYmVyfTwvc29sZGllcm51
bWJlcj5gCiAgICAgICsgYDxzb2xkaWVycmVzZXJ2ZWQ+JHtyb29tLnNvbGRpZXJSZXNlcnZlZH08
L3NvbGRpZXJyZXNlcnZlZD48c3RvcnlpPiR7cm9vbS5zdG9yeX08L3N0b3J5aT5gCiAgICAgICsg
YDxiYXR0bGV0eXBlPiR7cm9vbS5iYXR0bGVUeXBlfTwvYmF0dGxldHlwZT48cHJlc2V0dHlwZT4k
e3Jvb20ucHJlc2V0fTwvcHJlc2V0dHlwZT48L2dhbWVzZXR0aW5nPmApOwogIH0KCiAgc2VuZExp
c3Qoam9pbmVkLCBxdWl0KSB7IC8vIGkuYShpbnQsIGludCkKICAgIGxldCB0ZXh0ID0gYDxsaXN0
PjxjaWQ+JHt0aGlzLmluZGV4fTwvY2lkPmA7CiAgICBpZiAoam9pbmVkICE9PSAtMSkgdGV4dCAr
PSBgPGpvaW5fY2lkPiR7am9pbmVkfTwvam9pbl9jaWQ+YDsKICAgIGlmIChxdWl0ICE9PSAtMSkg
dGV4dCArPSBgPHF1aXRfY2lkPiR7cXVpdH08L3F1aXRfY2lkPmA7CiAgICBmb3IgKGNvbnN0IHNs
b3Qgb2YgdGhpcy5yb29tLnNsb3RzKSB7CiAgICAgIHRleHQgKz0gYDxpbmZvPjxuYW1lPjwhW0NE
QVRBWyR7c2xvdC5uYW1lfV1dPjwvbmFtZT48b25saW5lPiR7c2xvdC5vbmxpbmUgPyAxIDogMH08
L29ubGluZT5gCiAgICAgICAgKyBgPGhhc3BsYXllcj4ke3Nsb3QuaGFzUGxheWVyID8gMSA6IDB9
PC9oYXNwbGF5ZXI+PGNjPiR7c2xvdC5jY308L2NjPjxwYXVzZWdhbWU+JHtzbG90LnBhdXNlZCA/
IDEgOiAwfTwvcGF1c2VnYW1lPmAKICAgICAgICArIGA8bGF0ZW5jeT4ke3Nsb3QubGF0ZW5jeX08
L2xhdGVuY3k+PHBhZ2U+JHtzbG90LnBhZ2V9PC9wYWdlPmA7CiAgICAgIGZvciAobGV0IGsgPSAw
OyBrIDwgMzsgayArPSAxKSB0ZXh0ICs9IGA8cD48IVtDREFUQVske3Nsb3QucGxheWVyc1trXX1d
XT48L3A+YDsKICAgICAgdGV4dCArPSBgPGxlYXZlX2Y+JHtzbG90LmxlZnRGcmFtZX08L2xlYXZl
X2Y+PC9pbmZvPmA7CiAgICB9CiAgICB0aGlzLnNlbmQodGV4dCArICc8L2xpc3Q+Jyk7CiAgfQoK
ICBzZW5kTWVuKGNoYW5nZWQpIHsgLy8gaS5jKGludCkKICAgIGxldCB0ZXh0ID0gYDxtYW5saXN0
PjxudW1jaGFuZ2VkPiR7Y2hhbmdlZH08L251bWNoYW5nZWQ+YDsKICAgIGZvciAoY29uc3QgbWFu
IG9mIHRoaXMucm9vbS5tZW4pIHsKICAgICAgdGV4dCArPSBgPG1hbj48Y2lkPiR7bWFuLmNsaWVu
dH08L2NpZD48Y29uPiR7bWFuLmNvbnRyb2xsZXJ9PC9jb24+PHRlYW0+JHttYW4udGVhbX08L3Rl
YW0+PGNoYXI+JHttYW4uY2hhcn08L2NoYXI+YAogICAgICAgICsgYDxsdj4ke21hbi5sZXZlbH08
L2x2Pjxjb21tPiR7bWFuLmNvbW1hbmRlcn08L2NvbW0+PHJhbmQ+JHttYW4ucmFuZG9tID8gMSA6
IDB9PC9yYW5kPjxleGlzdD4ke21hbi5leGlzdHMgPyAxIDogMH08L2V4aXN0PjwvbWFuPmA7CiAg
ICB9CiAgICB0aGlzLnNlbmQodGV4dCArICc8L21hbmxpc3Q+Jyk7CiAgfQoKICBub3RpY2UodGV4
dCkgeyAvLyBpLmIoU3RyaW5nKTogYSBsaW5lIGZyb20gdGhlIHNlcnZlciB0byB0aGlzIGdhbWUg
b25seQogICAgdGhpcy5zZW5kKGA8Y2hhdD48Yz4ke1NFUlZFUl9TTE9UfTwvYz48bT48IVtDREFU
QVs8Zm9udCBjb2xvcj0iI0ZGRkZBQSI+JHt0ZXh0fTwvZm9udD5dXT48L20+PC9jaGF0PmApOwog
IH0KCiAgYW5ub3VuY2UodGV4dCkgeyAvLyBpLmUoU3RyaW5nKTogYSBsaW5lIGZyb20gdGhlIHNl
cnZlciB0byBldmVyeW9uZQogICAgdGhpcy5yb29tLmJyb2FkY2FzdChgPGNoYXQ+PGM+JHtTRVJW
RVJfU0xPVH08L2M+PG0+PCFbQ0RBVEFbPGZvbnQgY29sb3I9IiNGRkNDRkYiPiR7dGV4dH08L2Zv
bnQ+XV0+PC9tPjwvY2hhdD5gKTsKICB9CgogIC8vIC0tLS0gdGhlIHdhaXRpbmcgcm9vbSBhbmQg
dGhlIG1lbnVzCiAgc3RhcnRDb3VudChkb2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207
CiAgICBjb25zdCBjb3VudGRvd24gPSByb29tLmNvdW50ZG93bjsKICAgIGlmIChjb3VudGRvd24u
b24pIHJldHVybjsKICAgIGNvbnN0IGFjdGlvbiA9IHRhZ1ZhbHVlKGRvYywgJ2FjdGlvbicpOwog
ICAgY29uc3QgcGFnZSA9IHRhZ1ZhbHVlKGRvYywgJ3BhZ2UnKTsKICAgIGxldCB0b2dldGhlciA9
IHRydWU7CiAgICBmb3IgKGNvbnN0IHNsb3Qgb2Ygcm9vbS5vbmxpbmUoKSkgewogICAgICBpZiAo
cGFnZSA9PT0gJ0ZJR0hUSU5HJyA/IHNsb3QucGFnZSAhPT0gJ0ZJR0hUSU5HJyAmJiBzbG90LnBh
Z2UgIT09ICdXQUlUUk9PTScgOiBzbG90LnBhZ2UgIT09IHBhZ2UpIHsgdG9nZXRoZXIgPSBmYWxz
ZTsgYnJlYWs7IH0KICAgIH0KICAgIGlmIChyb29tLnBhZ2UgIT09IHBhZ2UgfHwgIXRvZ2V0aGVy
KSByZXR1cm47CiAgICBjb25zdCBzdGFydCA9ICh3aGF0LCBjb3VudCA9IENPVU5URE9XTiwgc2hv
d24gPSB3aGF0KSA9PiB7CiAgICAgIGNvdW50ZG93bi5vbiA9IHRydWU7CiAgICAgIGNvdW50ZG93
bi5hY3Rpb24gPSB3aGF0OwogICAgICBjb3VudGRvd24uY291bnQgPSBjb3VudDsKICAgICAgcm9v
bS5icm9hZGNhc3RDbGljayh0aGlzLmluZGV4LCBzaG93bik7CiAgICB9OwogICAgY29uc3QgemVy
byA9ICgpID0+IGJ5VGFnKGRvYywgJ3plcm8nKS5sZW5ndGggJiYgdmFsdWVPZihieVRhZyhkb2Ms
ICd6ZXJvJylbMF0pID09PSAndHJ1ZSc7CiAgICBpZiAocm9vbS5wYWdlID09PSAnV0FJVFJPT00n
ICYmIChhY3Rpb24gPT09ICdjbGlja3ZzJyB8fCBhY3Rpb24gPT09ICdjbGlja3N0b3J5JyB8fCBh
Y3Rpb24gPT09ICdjbGlja2JhdHRsZScpKSB7CiAgICAgIHN0YXJ0KGFjdGlvbik7CiAgICB9IGVs
c2UgaWYgKHJvb20ucGFnZSA9PT0gJ0NIQVJNRU5VJyAmJiBhY3Rpb24gPT09ICdjbGlja25leHQn
KSB7CiAgICAgIGlmICh0aGlzLmNhblN0YXJ0KCkpIHN0YXJ0KGFjdGlvbiwgQ09VTlRET1dOLCBy
b29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJyB8fCByb29tLm1vZGUgPT09ICdTVE9SWU1PREUnID8g
J2NsaWNrZmlnaHQnIDogYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAoKHJvb20ucGFnZSA9PT0gJ1NU
T1JZTUVOVScgfHwgcm9vbS5wYWdlID09PSAnQkFUVExFU0VUVElOR01FTlUnKSAmJiBhY3Rpb24g
PT09ICdjbGlja25leHQnKSB7CiAgICAgIHN0YXJ0KGFjdGlvbik7CiAgICB9IGVsc2UgaWYgKHJv
b20ucGFnZSA9PT0gJ0dBTUVTRVRUSU5HTUVOVScgJiYgYWN0aW9uID09PSAnY2xpY2tmaWdodCcp
IHsKICAgICAgc3RhcnQoYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAocm9vbS5maWdodGluZ05vdyAm
JiBhY3Rpb24gPT09ICdxdWl0Z2FtZScpIHsKICAgICAgY29uc3QgaXNaZXJvID0gemVybygpOwog
ICAgICBzdGFydChhY3Rpb24sIGlzWmVybyA/IDEgOiBDT1VOVERPV04gKiAyKTsKICAgIH0gZWxz
ZSBpZiAocm9vbS5maWdodGluZ05vdyAmJiBhY3Rpb24gPT09ICdyZXN0YXJ0Z2FtZScpIHsKICAg
ICAgaWYgKHJvb20uYmFja2dyb3VuZFJhbmRvbSkgcm9vbS5waWNrQmFja2dyb3VuZCgpOwogICAg
ICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgTUVOOyBpbmRleCArPSAxKSBpZiAocm9vbS5t
ZW5baW5kZXhdLmV4aXN0cyAmJiByb29tLm1lbltpbmRleF0ucmFuZG9tKSB0aGlzLnBpY2tDaGFy
YWN0ZXIoaW5kZXgpOwogICAgICBpZiAocm9vbS5tdXNpY1JhbmRvbSkgcm9vbS5waWNrTXVzaWMo
KTsKICAgICAgc3RhcnQoYWN0aW9uLCBDT1VOVERPV04gKiAyKTsKICAgICAgaWYgKHplcm8oKSkg
Y291bnRkb3duLmNvdW50ID0gMTsKICAgIH0gZWxzZSBpZiAocm9vbS5maWdodGluZ05vdyAmJiBh
Y3Rpb24gPT09ICduZXh0c3RhZ2UnKSB7CiAgICAgIHN0YXJ0KGFjdGlvbiwgQ09VTlRET1dOICog
Mik7CiAgICAgIGlmICh6ZXJvKCkpIGNvdW50ZG93bi5jb3VudCA9IDE7CiAgICB9CiAgfQoKICAv
LyBpLmQoKTogd2hldGhlciB0aGUgY2hhcmFjdGVyIG1lbnUgbWF5IGdvIG9uLgogIGNhblN0YXJ0
KCkgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGNvbnN0IHBlclRlYW0gPSBbMCwg
MCwgMCwgMCwgMF07CiAgICBsZXQgbWVuID0gMDsKICAgIGxldCBodW1hbnMgPSAwOwogICAgZm9y
IChjb25zdCBtYW4gb2Ygcm9vbS5tZW4pIHsKICAgICAgaWYgKCFtYW4uZXhpc3RzKSBjb250aW51
ZTsKICAgICAgaWYgKG1hbi5jb250cm9sbGVyICE9PSAtMSAmJiByb29tLnNsb3RzW21hbi5jbGll
bnRdICYmIHJvb20uc2xvdHNbbWFuLmNsaWVudF0ub25saW5lKSBodW1hbnMgKz0gMTsKICAgICAg
bWVuICs9IDE7CiAgICAgIHBlclRlYW1bbWFuLnRlYW0gKyAxXSArPSAxOwogICAgfQogICAgbGV0
IHRlYW1zID0gcGVyVGVhbVswXTsKICAgIGxldCBjcm93ZGVkID0gZmFsc2U7CiAgICBmb3IgKGxl
dCBrID0gMTsgayA8IDU7IGsgKz0gMSkgewogICAgICBpZiAocGVyVGVhbVtrXSA+IDApIHRlYW1z
ICs9IDE7CiAgICAgIGlmIChwZXJUZWFtW2tdID4gNSkgY3Jvd2RlZCA9IHRydWU7CiAgICB9CiAg
ICBjb25zdCByZWZ1c2UgPSAoYm9keSkgPT4geyB0aGlzLnNlbmQoYDxjaGFybWVudW5leHRlcnJv
cj4ke2JvZHl9PC9jaGFybWVudW5leHRlcnJvcj5gKTsgcmV0dXJuIGZhbHNlOyB9OwogICAgaWYg
KG1lbiA9PT0gMCkgcmV0dXJuIHJlZnVzZSgnPG0+Tm9QbGF5ZXI8L20+Jyk7CiAgICBpZiAoaHVt
YW5zID09PSAwKSByZXR1cm4gcmVmdXNlKCc8bT5Ob0h1bWFuUGxheWVyPC9tPicpOwogICAgaWYg
KG1lbiA9PT0gMSAmJiByb29tLm1vZGUgPT09ICdWU01PREUnKSByZXR1cm4gcmVmdXNlKCc8bT5P
bmVQbGF5ZXJPbmx5PC9tPicpOwogICAgaWYgKHRlYW1zIDw9IDEgJiYgcm9vbS5tb2RlID09PSAn
VlNNT0RFJykgcmV0dXJuIHJlZnVzZSgnPG0+T25lVGVhbU9ubHk8L20+Jyk7CiAgICBpZiAocm9v
bS5tb2RlID09PSAnQkFUVExFTU9ERScpIHsKICAgICAgaWYgKHRlYW1zIDwgcm9vbS50ZWFtcykg
cmV0dXJuIHJlZnVzZShgPG0+YmF0dGxlTm9Fbm91Z2hUZWFtPC9tPjxhPiR7cm9vbS5iYXR0bGVU
eXBlfTwvYT48Yj4ke3Jvb20udGVhbXN9PC9iPjxjPiR7dGVhbXN9PC9jPmApOwogICAgICBpZiAo
Y3Jvd2RlZCkgcmV0dXJuIHJlZnVzZSgnPG0+YmF0dGxlTm90QWxsb3dNb3JlVGhhbjU8L20+Jyk7
CiAgICB9CiAgICByZXR1cm4gdHJ1ZTsKICB9CgogIGNsaWNrQmFjayhkb2MpIHsKICAgIGNvbnN0
IHJvb20gPSB0aGlzLnJvb207CiAgICBpZiAocm9vbS5jb3VudGRvd24ub24gfHwgcm9vbS5wYWdl
ICE9PSB0YWdWYWx1ZShkb2MsICdwYWdlJykpIHJldHVybjsKICAgIGNvbnN0IGJhY2sgPSAobW9k
ZSwgcGFnZSkgPT4gewogICAgICByb29tLnByZXZpb3VzUGFnZSA9IHJvb20ucGFnZTsKICAgICAg
aWYgKG1vZGUpIHJvb20ubW9kZSA9IG1vZGU7CiAgICAgIHJvb20ucGFnZSA9IHBhZ2U7CiAgICAg
IHJvb20uYnJvYWRjYXN0U3RhdHVzKCk7CiAgICAgIHJvb20uYnJvYWRjYXN0Q2xpY2sodGhpcy5p
bmRleCwgJ2NsaWNrYmFjaycpOwogICAgfTsKICAgIGlmIChyb29tLnBhZ2UgPT09ICdDSEFSTUVO
VScgJiYgcm9vbS5tb2RlID09PSAnVlNNT0RFJykgYmFjaygnV0FJVFJPT00nLCAnV0FJVFJPT00n
KTsKICAgIGVsc2UgaWYgKHJvb20ucGFnZSA9PT0gJ0NIQVJNRU5VJyAmJiByb29tLm1vZGUgPT09
ICdTVE9SWU1PREUnKSBiYWNrKCdTVE9SWU1PREUnLCAnU1RPUllNRU5VJyk7CiAgICBlbHNlIGlm
IChyb29tLnBhZ2UgPT09ICdDSEFSTUVOVScgJiYgcm9vbS5tb2RlID09PSAnQkFUVExFTU9ERScp
IGJhY2soJ0JBVFRMRU1PREUnLCAnQkFUVExFU0VUVElOR01FTlUnKTsKICAgIGVsc2UgaWYgKHJv
b20ucGFnZSA9PT0gJ1NUT1JZTUVOVScgfHwgcm9vbS5wYWdlID09PSAnQkFUVExFU0VUVElOR01F
TlUnKSBiYWNrKCdXQUlUUk9PTScsICdXQUlUUk9PTScpOwogICAgZWxzZSBpZiAocm9vbS5wYWdl
ID09PSAnR0FNRVNFVFRJTkdNRU5VJykgYmFjayhudWxsLCAnQ0hBUk1FTlUnKTsKICB9CgogIGdh
bWVTZXR0aW5nKGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGlmICghWydH
QU1FU0VUVElOR01FTlUnLCAnQ0hBUk1FTlUnLCAnU1RPUllNRU5VJywgJ0JBVFRMRVNFVFRJTkdN
RU5VJ10uaW5jbHVkZXMocm9vbS5wYWdlKSkgcmV0dXJuOwogICAgY29uc3QgdmFsdWUgPSAobmFt
ZSkgPT4geyBjb25zdCBmb3VuZCA9IGJ5VGFnKGRvYywgbmFtZSk7IHJldHVybiBmb3VuZC5sZW5n
dGggPyB2YWx1ZU9mKGZvdW5kWzBdKSA6IHVuZGVmaW5lZDsgfTsKICAgIGNvbnN0IGJhY2tncm91
bmQgPSB2YWx1ZSgnYmdpZCcpOwogICAgaWYgKGJhY2tncm91bmQgIT09IHVuZGVmaW5lZCAmJiAo
cm9vbS5iYWNrZ3JvdW5kUmFuZG9tIHx8IHJvb20uYmFja2dyb3VuZCAhPT0gYmFja2dyb3VuZCkp
IHsKICAgICAgcm9vbS5iYWNrZ3JvdW5kID0gcm9vbS5iYWNrZ3JvdW5kQ2hvc2VuID0gYmFja2dy
b3VuZDsKICAgICAgaWYgKGJhY2tncm91bmQgPT09ICdyYW5kb20nKSB7CiAgICAgICAgcm9vbS5i
YWNrZ3JvdW5kUmFuZG9tID0gdHJ1ZTsKICAgICAgICByb29tLnBpY2tCYWNrZ3JvdW5kKCk7CiAg
ICAgIH0gZWxzZSB7CiAgICAgICAgcm9vbS5iYWNrZ3JvdW5kUmFuZG9tID0gZmFsc2U7CiAgICAg
IH0KICAgIH0KICAgIGNvbnN0IG11c2ljID0gdmFsdWUoJ211c2ljaWQnKTsKICAgIGlmIChtdXNp
YyAhPT0gdW5kZWZpbmVkICYmIChyb29tLm11c2ljUmFuZG9tIHx8IHJvb20ubXVzaWMgIT09IG11
c2ljKSkgewogICAgICByb29tLm11c2ljID0gbXVzaWM7CiAgICAgIGlmIChtdXNpYyA9PT0gJ3Jh
bmRvbScpIHsKICAgICAgICByb29tLm11c2ljUmFuZG9tID0gdHJ1ZTsKICAgICAgICByb29tLnBp
Y2tNdXNpYygpOwogICAgICB9IGVsc2UgewogICAgICAgIHJvb20ubXVzaWNSYW5kb20gPSBmYWxz
ZTsKICAgICAgfQogICAgfQogICAgY29uc3QgbXVsdGlwbGFuZSA9IHZhbHVlKCdtcCcpOwogICAg
aWYgKG11bHRpcGxhbmUgIT09IHVuZGVmaW5lZCkgcm9vbS5tdWx0aXBsYW5lID0gbXVsdGlwbGFu
ZSA9PT0gJzEnOwogICAgY29uc3QgbnVtYmVycyA9IFtbJ2hvcnNlJywgJ2hvcnNlcyddLCBbJ2dp
YW50b2JqJywgJ2dpYW50T2JqZWN0cyddLCBbJ2RpZmYnLCAnZGlmZmljdWx0eSddLCBbJ25vcmxl
dicsICdub3JtYWxpemVMZXZlbCddLAogICAgICBbJ2Rpbm8nLCAnZGlub3NhdXJzJ10sIFsndGVz
dHRyb29wJywgJ3Rlc3RUcm9vcHMnXSwgWydzb2xkaWVybnVtYmVyJywgJ3NvbGRpZXJOdW1iZXIn
XSwKICAgICAgWydzb2xkaWVycmVzZXJ2ZWQnLCAnc29sZGllclJlc2VydmVkJ10sIFsnc3Rvcnlp
JywgJ3N0b3J5J11dOwogICAgZm9yIChjb25zdCBbdGFnLCBmaWVsZF0gb2YgbnVtYmVycykgewog
ICAgICBjb25zdCByYXcgPSB2YWx1ZSh0YWcpOwogICAgICBpZiAocmF3ICE9PSB1bmRlZmluZWQp
IHJvb21bZmllbGRdID0gaW50KHJhdyk7CiAgICB9CiAgICBjb25zdCByYXcgPSB2YWx1ZSgnYnQn
KTsKICAgIGlmIChyYXcgIT09IHVuZGVmaW5lZCAmJiByb29tLnByZXNldCAhPT0gLWludChyYXcp
IC0gMSAmJiAocm9vbS5wcmVzZXQgIT09IC0xIHx8IHJvb20uYmF0dGxlVHlwZSAhPT0gaW50KHJh
dykpKSB7CiAgICAgIGxldCB0eXBlID0gaW50KHJhdyk7CiAgICAgIGlmICh0eXBlIDwgMCkgewog
ICAgICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBNRU47IGluZGV4ICs9IDEpIHsKICAg
ICAgICAgIHJvb20ubWVuW2luZGV4XS5leGlzdHMgPSBmYWxzZTsKICAgICAgICAgIGlmIChpbmRl
eCA+PSAxMikgcm9vbS5tZW5baW5kZXhdLnJhbmRvbSA9IGZhbHNlOwogICAgICAgICAgcm9vbS5t
ZW5baW5kZXhdLmNvbW1hbmRlciA9IC0xOwogICAgICAgIH0KICAgICAgICByb29tLnByZXNldCA9
IC10eXBlIC0gMTsKICAgICAgICBjb25zdCBwcmVzZXQgPSAobGV2ZWwsIGxpc3QpID0+IGxpc3Qu
Zm9yRWFjaCgoW2luZGV4LCBjaGFyLCB0ZWFtXSkgPT4gT2JqZWN0LmFzc2lnbihyb29tLm1lbltp
bmRleF0sIHsgbGV2ZWwsIGNoYXIsIGV4aXN0czogdHJ1ZSwgdGVhbSB9KSk7CiAgICAgICAgaWYg
KHR5cGUgPT09IC0xKSB7CiAgICAgICAgICB0eXBlID0gMTE7CiAgICAgICAgICBwcmVzZXQoMTAs
IFtbMTksICdsZW8nLCAxXSwgWzIwLCAnaWN6enknLCAxXSwgWzIxLCAnaGVhdGVyJywgMV0sIFsy
MiwgJ3JheWUnLCAxXSwgWzIzLCAnc2luYW4nLCAxXV0pOwogICAgICAgIH0gZWxzZSBpZiAodHlw
ZSA9PT0gLTIpIHsKICAgICAgICAgIHR5cGUgPSAxMTExOwogICAgICAgICAgcHJlc2V0KDExLCBb
WzE1LCAndGF5bG9yJywgMV0sIFsxNiwgJ2xlbycsIDFdLCBbMTcsICdqZW5ueScsIDFdLCBbMTgs
ICdyYXllJywgMl0sIFsxOSwgJ2ljenp5JywgMl0sIFsyMCwgJ2hlYXRlcicsIDJdLAogICAgICAg
ICAgICBbMjEsICdnb3Jkb24nLCAzXSwgWzIyLCAnamFzb24nLCAzXSwgWzIzLCAndGl0dG8nLCAz
XV0pOwogICAgICAgIH0gZWxzZSBpZiAodHlwZSA9PT0gLTMpIHsKICAgICAgICAgIHR5cGUgPSAx
MTE7CiAgICAgICAgICBwcmVzZXQoMTIsIFtbMTUsICdoZWF0ZXInLCAxXSwgWzE2LCAnaWN6enkn
LCAxXSwgWzE3LCAncmF5ZScsIDFdLCBbMTgsICdzaW5hbicsIDFdLCBbMTksICd0aXR0bycsIDFd
LCBbMjAsICdsZW8nLCAyXSwKICAgICAgICAgICAgWzIxLCAnZ29yZG9uJywgMl0sIFsyMiwgJ2pl
bm55JywgMl0sIFsyMywgJ2phc29uJywgMl1dKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09
IC00KSB7CiAgICAgICAgICB0eXBlID0gMTEyOwogICAgICAgICAgcHJlc2V0KDE0LCBbWzE1LCAn
bGVvJywgMF0sIFsxNiwgJ3NpbmFuJywgMF0sIFsxNywgJ2dvcmRvbicsIDBdLCBbMTgsICdpY3p6
eScsIDFdLCBbMTksICdoZWF0ZXInLCAxXSwgWzIwLCAncmF5ZScsIDFdLAogICAgICAgICAgICBb
MjEsICdqYXNvbicsIDNdLCBbMjIsICd0aXR0bycsIDNdLCBbMjMsICdnaWdncycsIDNdXSk7CiAg
ICAgICAgfQogICAgICB9IGVsc2UgewogICAgICAgIHJvb20ucHJlc2V0ID0gLTE7CiAgICAgIH0K
ICAgICAgcm9vbS5iYXR0bGVUeXBlID0gdHlwZTsKICAgICAgaWYgKHR5cGUgPT09IDExKSByb29t
LnRlYW1zID0gMjsKICAgICAgZWxzZSBpZiAodHlwZSA9PT0gMTIgfHwgdHlwZSA9PT0gMTExKSBy
b29tLnRlYW1zID0gMzsKICAgICAgZWxzZSBpZiAodHlwZSA9PT0gMjIgfHwgdHlwZSA9PT0gMTMg
fHwgdHlwZSA9PT0gMTExMSB8fCB0eXBlID09PSAxMTIpIHJvb20udGVhbXMgPSA0OwogICAgICBp
ZiAocm9vbS50ZWFtcyA9PT0gMikgcm9vbS5iYWNrZ3JvdW5kID0gJ2JhdHRsZTInOwogICAgICBl
bHNlIGlmIChyb29tLnRlYW1zID09PSAzKSByb29tLmJhY2tncm91bmQgPSAnYmF0dGxlMyc7CiAg
ICAgIGVsc2UgaWYgKHJvb20udGVhbXMgPT09IDQpIHJvb20uYmFja2dyb3VuZCA9ICdiYXR0bGU0
JzsKICAgICAgY29uc3QgbWFwcyA9IHsgMTE6IFswLCAxLCAtMSwgLTFdLCAyMjogWzAsIDEsIDAs
IDFdLCAxMTE6IFswLCAxLCAyLCAtMV0sIDExMTE6IFswLCAxLCAyLCAzXSwgMTI6IFsxLCAwLCAx
LCAtMV0sCiAgICAgICAgMTM6IFswLCAxLCAxLCAxXSwgMTEyOiBbMSwgMSwgMCwgMl0gfTsKICAg
ICAgaWYgKG1hcHNbdHlwZV0pIHJvb20udGVhbU1hcCA9IG1hcHNbdHlwZV07CiAgICB9CiAgICBy
b29tLmJyb2FkY2FzdEdhbWVTZXR0aW5nKHRoaXMuaW5kZXgpOwogIH0KCiAgdXBkYXRlSW5mbyhk
b2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBjb25zdCBzbG90ID0gdGhpcy5z
bG90OwogICAgc2xvdC5uYW1lID0gdGFnVmFsdWUoZG9jLCAnbmFtZScpOyAvLyAodGhlIG9yaWdp
bmFsIGtlZXBzIHRoZSBuYW1lIGl0IGpvaW5lZCB3aXRoIGZvciBpdHMgbG9nIGFuZCAvbWUpCiAg
ICBmb3IgKGxldCBrID0gMDsgayA8IDM7IGsgKz0gMSkgc2xvdC5wbGF5ZXJzW2tdID0gdGhpcy5w
bGF5ZXJzW2tdID0gdGFnVmFsdWUoZG9jLCAncCcsIGspOwogICAgZm9yIChsZXQgayA9IDA7IGsg
PCAzMDsgayArPSAxKSB7CiAgICAgIHNsb3QubGV2ZWxzW2tdID0gaW50KHRhZ1ZhbHVlKGRvYywg
J2wnLCBrKSk7CiAgICAgIGlmIChzbG90LmxldmVsc1trXSA+IE1BWF9MRVZFTCkgdGhpcy5jaGVh
dCA9IDE7CiAgICB9CiAgICBmb3IgKGxldCBrID0gMDsgayA8IDM7IGsgKz0gMSkgewogICAgICBj
b25zdCBtYW4gPSByb29tLm1lblt0aGlzLmluZGV4ICogMyArIGtdOwogICAgICBpZiAoIW1hbi5l
eGlzdHMpIGNvbnRpbnVlOwogICAgICBjb25zdCBjaGFyYWN0ZXIgPSBDSEFSQUNURVJTLmluZGV4
T2YobWFuLmNoYXIpOwogICAgICBpZiAoY2hhcmFjdGVyID49IDAgJiYgc2xvdC5sZXZlbHNbY2hh
cmFjdGVyXSA+IDApIHsKICAgICAgICBtYW4ubGV2ZWwgPSBzbG90LmxldmVsc1tjaGFyYWN0ZXJd
OwogICAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5tZW4pIGlmIChvdGhlci5leGlzdHMg
JiYgb3RoZXIuY29tbWFuZGVyID09PSB0aGlzLmluZGV4ICogMyArIGspIG90aGVyLmxldmVsID0g
bWFuLmxldmVsOwogICAgICB9CiAgICB9CiAgICBpZiAoIXJvb20uZmlnaHRpbmdOb3cpIHsKICAg
ICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgIHJvb20uYnJvYWRjYXN0TWVuKDEp
OwogICAgfQogIH0KCiAgYWRkUGxheWVyKGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9v
bTsKICAgIGlmIChyb29tLnBhZ2UgIT09ICdDSEFSTUVOVScpIHJldHVybjsKICAgIGNvbnN0IGNv
bnRyb2xsZXIgPSBpbnQodmFsdWVPZihkb2MpKTsKICAgIGNvbnN0IGluZGV4ID0gdGhpcy5pbmRl
eCAqIDMgKyBjb250cm9sbGVyOwogICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhdOwogICAg
aWYgKCFtYW4gfHwgY29udHJvbGxlciA8IDAgfHwgY29udHJvbGxlciA+IDIpIHRocm93IG5ldyBY
bWxFcnJvcignbm8gc3VjaCBwbGF5ZXInKTsKICAgIGlmIChtYW4uZXhpc3RzKSByZXR1cm47CiAg
ICBtYW4uZXhpc3RzID0gdHJ1ZTsKICAgIG1hbi5jbGllbnQgPSB0aGlzLmluZGV4OwogICAgbWFu
LmNvbnRyb2xsZXIgPSBjb250cm9sbGVyOwogICAgbWFuLnRlYW0gPSAtMTsKICAgIHJvb20ubWVu
LmZvckVhY2goKG90aGVyLCBrKSA9PiB7IGlmIChrICE9PSBpbmRleCAmJiBvdGhlci5leGlzdHMg
JiYgb3RoZXIuY2xpZW50ID09PSB0aGlzLmluZGV4KSBtYW4udGVhbSA9IG90aGVyLnRlYW07IH0p
OwogICAgaWYgKG1hbi50ZWFtID09PSAtMSkgbWFuLnRlYW0gPSB0aGlzLmxlYXN0VGVhbShpbmRl
eCk7CiAgICBpZiAobWFuLnJhbmRvbSB8fCAhbWFuLmNoYXIpIHsKICAgICAgbWFuLnJhbmRvbSA9
IHRydWU7CiAgICAgIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7CiAgICB9IGVsc2UgewogICAg
ICBjb25zdCBjaGFyYWN0ZXIgPSBDSEFSQUNURVJTLmluZGV4T2YobWFuLmNoYXIpOwogICAgICBp
ZiAoY2hhcmFjdGVyID49IDAgJiYgKHRoaXMuc2xvdC5sZXZlbHNbY2hhcmFjdGVyXSA8PSAwIHx8
IHRoaXMuc2xvdC5sZXZlbHNbY2hhcmFjdGVyXSAhPT0gbWFuLmxldmVsKSkgewogICAgICAgIG1h
bi5yYW5kb20gPSB0cnVlOwogICAgICAgIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7CiAgICAg
IH0KICAgIH0KICAgIHRoaXMubGltaXRNZW4oKTsKICAgIHJvb20uYnJvYWRjYXN0TWVuKDEpOwog
IH0KCiAgLy8gVGhlIHRlYW0gd2l0aCB0aGUgZmV3ZXN0IG1lbiAobm90IGNvdW50aW5nIHNvbGRp
ZXJzKSwgZm9yIGEgbmV3IG1hbi4KICBsZWFzdFRlYW0oZXhjZXB0KSB7CiAgICBjb25zdCByb29t
ID0gdGhpcy5yb29tOwogICAgY29uc3QgY291bnRzID0gWzAsIDAsIDAsIDBdOwogICAgcm9vbS5t
ZW4uZm9yRWFjaCgob3RoZXIsIGspID0+IHsgaWYgKGsgIT09IGV4Y2VwdCAmJiBvdGhlci5leGlz
dHMgJiYgb3RoZXIuY29tbWFuZGVyID09PSAtMSkgY291bnRzW290aGVyLnRlYW1dICs9IDE7IH0p
OwogICAgaWYgKHJvb20ubW9kZSAhPT0gJ0JBVFRMRU1PREUnKSByb29tLnRlYW1zID0gNDsKICAg
IGxldCBmZXdlc3QgPSA5OTk7CiAgICBsZXQgdGVhbSA9IDA7CiAgICBmb3IgKGxldCBrID0gMDsg
ayA8IHJvb20udGVhbXM7IGsgKz0gMSkgewogICAgICBpZiAoY291bnRzW2tdIDwgZmV3ZXN0KSB7
CiAgICAgICAgZmV3ZXN0ID0gY291bnRzW2tdOwogICAgICAgIHRlYW0gPSBrOwogICAgICB9CiAg
ICB9CiAgICByZXR1cm4gdGVhbTsKICB9CgogIC8vIGkuZSgpOiBhIGNvbXB1dGVyIHBsYXllciwg
aW4gdGhlIGZpcnN0IGZyZWUgcGxhY2UgYWZ0ZXIgdGhlIDEyIGh1bWFuIG9uZXMuCiAgYWRkQ29t
cHV0ZXIoKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20ubWVuLmZp
bHRlcigobWFuKSA9PiBtYW4uZXhpc3RzKS5sZW5ndGggPj0gMTIpIHJldHVybiBmYWxzZTsKICAg
IGZvciAobGV0IGluZGV4ID0gTUVOIC0gMTsgaW5kZXggPj0gMTI7IGluZGV4IC09IDEpIHsKICAg
ICAgaWYgKHJvb20ubWVuW2luZGV4XS5leGlzdHMgfHwgKGluZGV4ICE9PSAxMiAmJiAhcm9vbS5t
ZW5baW5kZXggLSAxXS5leGlzdHMpKSBjb250aW51ZTsKICAgICAgY29uc3QgbWFuID0gcm9vbS5t
ZW5baW5kZXhdOwogICAgICBtYW4uZXhpc3RzID0gdHJ1ZTsKICAgICAgbWFuLnRlYW0gPSByb29t
Lm1vZGUgPT09ICdCQVRUTEVNT0RFJyB8fCByb29tLm1vZGUgPT09ICdWU01PREUnID8gdGhpcy5s
ZWFzdFRlYW0oaW5kZXgpIDogMzsKICAgICAgbWFuLmNsaWVudCA9IC0xOwogICAgICBtYW4uY29u
dHJvbGxlciA9IC0xOwogICAgICBtYW4ucmFuZG9tID0gdHJ1ZTsKICAgICAgbWFuLmNvbW1hbmRl
ciA9IC0xOwogICAgICB0aGlzLnBpY2tDaGFyYWN0ZXIoaW5kZXgpOwogICAgICByZXR1cm4gdHJ1
ZTsKICAgIH0KICAgIHJldHVybiBmYWxzZTsKICB9CgogIGFkZFNvbGRpZXIoZG9jKSB7CiAgICBj
b25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20ucGFnZSAhPT0gJ0NIQVJNRU5VJyB8
fCByb29tLmNvdW50ZG93bi5vbikgcmV0dXJuOwogICAgY29uc3QgaW5kZXggPSBpbnQodGFnVmFs
dWUoZG9jLCAnaScpKTsKICAgIGxldCBzb2xkaWVyID0gdGFnVmFsdWUoZG9jLCAnY2hhcicpOwog
ICAgY29uc3QgY29tbWFuZGVyID0gcm9vbS5tZW5baW5kZXhdOwogICAgaWYgKCFjb21tYW5kZXIp
IHRocm93IG5ldyBYbWxFcnJvcignbm8gc3VjaCBtYW4nKTsKICAgIGNvbnN0IHJvbGwgPSB0aGlz
LnJvb20ucmFuZG9tKCk7CiAgICBzd2l0Y2ggKGNvbW1hbmRlci5jaGFyKSB7CiAgICAgIGNhc2Ug
J2x1Y2FzJzogY2FzZSAnZHJldyc6IGNhc2UgJ3NoYXduJzoKICAgICAgICBpZiAoc29sZGllciA9
PT0gJ3pfaW5mYW50cnkwMScgJiYgcm9sbCA8IDAuMykgc29sZGllciA9ICd6X3ZpbGxhZ2VyMDEn
OwogICAgICAgIGVsc2UgaWYgKHNvbGRpZXIgPT09ICd6X2FyY2hlcjAxJyAmJiByb2xsIDwgMC4z
KSBzb2xkaWVyID0gJ3pfd29tYW4wMSc7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2UgJ3Zpdmlh
bic6CiAgICAgICAgaWYgKHNvbGRpZXIgPT09ICd6X2luZmFudHJ5MDEnKSBzb2xkaWVyID0gJ3pf
dmlsbGFnZXIwMSc7CiAgICAgICAgZWxzZSBpZiAoc29sZGllciA9PT0gJ3pfYXJjaGVyMDEnKSBz
b2xkaWVyID0gJ3pfd29tYW4wMSc7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2UgJ2plbm55Jzog
Y2FzZSAnc2luYW4nOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9hcmNoZXIwMScpIHNvbGRp
ZXIgPSAnel93b21hbjAxJzsKICAgICAgICBicmVhazsKICAgICAgY2FzZSAnamFzb24nOgogICAg
ICAgIGlmIChzb2xkaWVyID09PSAnel9pbmZhbnRyeTAxJykgc29sZGllciA9ICd6X2JhbmRpdDAx
JzsKICAgICAgICBlbHNlIGlmIChzb2xkaWVyID09PSAnel9hcmNoZXIwMScpIHNvbGRpZXIgPSAn
el9kYWdnZXIwMSc7CiAgICAgICAgZWxzZSBzb2xkaWVyID0gJ3pfc2lja2xlMDEnOwogICAgICAg
IGJyZWFrOwogICAgICBjYXNlICdnaWdncyc6IGNhc2UgJ3RpdHRvJzoKICAgICAgICBpZiAoc29s
ZGllciA9PT0gJ3pfaW5mYW50cnkwMScpIHNvbGRpZXIgPSAnel9iYW5kaXQwMSc7CiAgICAgICAg
ZWxzZSBpZiAoc29sZGllciA9PT0gJ3pfYXJjaGVyMDEnKSBzb2xkaWVyID0gJ3pfZGFnZ2VyMDEn
OwogICAgICAgIGJyZWFrOwogICAgICBjYXNlICdpY3p6eSc6CiAgICAgICAgaWYgKHNvbGRpZXIg
PT09ICd6X2NhdmFscnkwMScpIHNvbGRpZXIgPSAnel9pY2VtYW4nOwogICAgICAgIGJyZWFrOwog
ICAgICBjYXNlICdoZWF0ZXInOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9jYXZhbHJ5MDEn
KSBzb2xkaWVyID0gJ3pfc2t1bGwnOwogICAgICAgIGJyZWFrOwogICAgICBkZWZhdWx0OgogICAg
ICAgIGJyZWFrOwogICAgfQogICAgaWYgKGNvbW1hbmRlci5leGlzdHMgJiYgY29tbWFuZGVyLmNv
bW1hbmRlciA9PT0gLTEgJiYgdGhpcy5wbGFjZVNvbGRpZXIoaW5kZXgsIHNvbGRpZXIpKSB7CiAg
ICAgIHRoaXMubGltaXRNZW4oKTsKICAgICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAgICB9CiAg
fQoKICAvLyBpLmEoaW50LCBTdHJpbmcpCiAgcGxhY2VTb2xkaWVyKGNvbW1hbmRlckluZGV4LCBz
b2xkaWVyKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20ubWVuLmZp
bHRlcigobWFuKSA9PiBtYW4uZXhpc3RzKS5sZW5ndGggPj0gMTIpIHJldHVybiBmYWxzZTsKICAg
IGZvciAobGV0IGluZGV4ID0gMTI7IGluZGV4IDwgTUVOOyBpbmRleCArPSAxKSB7CiAgICAgIGNv
bnN0IG1hbiA9IHJvb20ubWVuW2luZGV4XTsKICAgICAgaWYgKG1hbi5leGlzdHMpIGNvbnRpbnVl
OwogICAgICBjb25zdCBjb21tYW5kZXIgPSByb29tLm1lbltjb21tYW5kZXJJbmRleF07CiAgICAg
IE9iamVjdC5hc3NpZ24obWFuLCB7IGV4aXN0czogdHJ1ZSwgY2xpZW50OiAtMSwgY29udHJvbGxl
cjogLTEsIHRlYW06IGNvbW1hbmRlci50ZWFtLCByYW5kb206IGZhbHNlLAogICAgICAgIGNvbW1h
bmRlcjogY29tbWFuZGVySW5kZXgsIGNoYXI6IHNvbGRpZXIsIGxldmVsOiBjb21tYW5kZXIubGV2
ZWwgfSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KCiAg
Ly8gaS5mKCk6IGF0IG1vc3QgMTIgbWVuOyB0aGUgbGF0ZXIgb25lcyBnby4KICBsaW1pdE1lbigp
IHsKICAgIGxldCBjb3VudCA9IDA7CiAgICBmb3IgKGNvbnN0IG1hbiBvZiB0aGlzLnJvb20ubWVu
KSB7CiAgICAgIGlmICghbWFuLmV4aXN0cykgY29udGludWU7CiAgICAgIGlmIChjb3VudCA8IDEy
KSBjb3VudCArPSAxOwogICAgICBlbHNlIG1hbi5leGlzdHMgPSBmYWxzZTsKICAgIH0KICB9Cgog
IGNob29zZUNoYXJhY3Rlcihkb2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBp
ZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47CiAgICBjb25zdCBpbmRleCA9IGlu
dCh0YWdWYWx1ZShkb2MsICdpJykpOwogICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhdOwog
ICAgaWYgKCFtYW4pIHRocm93IG5ldyBYbWxFcnJvcignbm8gc3VjaCBtYW4nKTsKICAgIGlmICgh
bWFuLmV4aXN0cyB8fCAobWFuLmNvbnRyb2xsZXIgIT09IC0xICYmIG1hbi5jbGllbnQgIT09IHRo
aXMuaW5kZXgpKSByZXR1cm47CiAgICBtYW4uY2hhciA9IHRhZ1ZhbHVlKGRvYywgJ2NoYXInKTsK
ICAgIGlmIChtYW4uY2hhciA9PT0gbnVsbCkgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBjaGFyYWN0
ZXInKTsKICAgIGlmIChtYW4uY2hhciA9PT0gJ3JhbmRvbScpIHsKICAgICAgbWFuLnJhbmRvbSA9
IHRydWU7CiAgICAgIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7CiAgICB9IGVsc2UgewogICAg
ICBtYW4ucmFuZG9tID0gZmFsc2U7CiAgICB9CiAgICBtYW4ubGV2ZWwgPSAxOwogICAgY29uc3Qg
Y2hhcmFjdGVyID0gQ0hBUkFDVEVSUy5pbmRleE9mKG1hbi5jaGFyKTsKICAgIGlmIChjaGFyYWN0
ZXIgPj0gMCkgewogICAgICBjb25zdCBsZXZlbCA9IG1hbi5jb250cm9sbGVyID09PSAtMSA/IHJv
b20uY29tcHV0ZXJMZXZlbChjaGFyYWN0ZXIpIDogdGhpcy5zbG90LmxldmVsc1tjaGFyYWN0ZXJd
OwogICAgICBpZiAobGV2ZWwgPiAwKSB7CiAgICAgICAgbWFuLmxldmVsID0gbGV2ZWw7CiAgICAg
ICAgZm9yIChjb25zdCBvdGhlciBvZiByb29tLm1lbikgaWYgKG90aGVyLmV4aXN0cyAmJiBvdGhl
ci5jb21tYW5kZXIgPT09IGluZGV4KSBvdGhlci5sZXZlbCA9IGxldmVsOwogICAgICB9CiAgICAg
IGlmIChsZXZlbCA8PSAwICYmIG1hbi5jb250cm9sbGVyID49IDAgJiYgbWFuLmNsaWVudCA9PT0g
dGhpcy5pbmRleCkgewogICAgICAgIC8vIEEgY2hhcmFjdGVyIHRoaXMgYWNjb3VudCBoYXMgbm90
IHVubG9ja2VkOiB0aGUgb3JpZ2luYWwgc2h1dHMgdGhlIGdhbWUgb3V0LgogICAgICAgIHRoaXMu
a2lja2VkID0gdHJ1ZTsKICAgICAgICB0aGlzLmxlYXZlKCk7CiAgICAgICAgcmV0dXJuOwogICAg
ICB9CiAgICB9CiAgICByb29tLmJyb2FkY2FzdE1lbigwKTsKICB9CgogIC8vIGkuZChpbnQpOiBh
IHJhbmRvbSBjaGFyYWN0ZXIgZm9yIGEgbWFuOiBvbmUgdGhlIGNvbXB1dGVyIGhhcywgbm90IHRh
a2VuIGJ5IGFub3RoZXIgbWFuIGJlZm9yZSBpdAogIC8vIG9yIG5vdCByYW5kb207IHRoZSBsZXZl
bCB0byBtYXRjaC4gKFRoZSBvcmlnaW5hbCBnYXZlIGEgY29tcHV0ZXIgcGxheWVyIG9uZSBvZiB0
aGUgY2hhcmFjdGVycyBzb21lCiAgLy8gY29tcHV0ZXIgaW4gdGhlIHJvb20gaGFzOyBoZXJlIGl0
IG1heSBiZSBhbnksIHRoZSBwcmVtaXVtIG9uZXMgdG9vLCB3aGljaCBwbGF5ZXJzJyBhY2NvdW50
cyBkbyBub3QKICAvLyBoYXZlOiBzZWUgaGYuanMuIE5vdCBZYWdhLCB3aG9tIHRoZSBnYW1lIGRv
ZXMgbm90IGxldCBhbnlvbmUgcGxheS4pCiAgcGlja0NoYXJhY3RlcihpbmRleCkgewogICAgY29u
c3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGNvbnN0IG1hbiA9IHJvb20ubWVuW2luZGV4XTsKICAg
IGNvbnN0IGh1bWFuID0gbWFuLmNsaWVudCAhPT0gLTE7CiAgICBsZXQgb3duZXIgPSBtYW4uY2xp
ZW50OwogICAgaWYgKG93bmVyID09PSAtMSB8fCAhcm9vbS5zbG90c1tvd25lcl0ub25saW5lKSBv
d25lciA9IHRoaXMuaW5kZXg7CiAgICBjb25zdCBzbG90ID0gcm9vbS5zbG90c1tvd25lcl07CiAg
ICBjb25zdCBhdmFpbGFibGUgPSAoKSA9PiB7CiAgICAgIGNvbnN0IGxpc3QgPSBbXTsKICAgICAg
Zm9yIChjb25zdCBuYW1lIG9mIENIQVJBQ1RFUlMpIHsKICAgICAgICBjb25zdCBjaGFyYWN0ZXIg
PSBDSEFSQUNURVJTLmluZGV4T2YobmFtZSk7CiAgICAgICAgaWYgKGh1bWFuID8gc2xvdC5sZXZl
bHNbY2hhcmFjdGVyXSA+IDAgOiBuYW1lICE9PSAneWFnYScpIGxpc3QucHVzaChuYW1lKTsKICAg
ICAgfQogICAgICByZXR1cm4gbGlzdDsKICAgIH07CiAgICBsZXQgbGlzdCA9IGF2YWlsYWJsZSgp
OwogICAgcm9vbS5tZW4uZm9yRWFjaCgob3RoZXIsIGspID0+IHsKICAgICAgaWYgKCFvdGhlci5l
eGlzdHMgfHwgKG90aGVyLnJhbmRvbSAmJiBrID49IGluZGV4KSkgcmV0dXJuOwogICAgICBmb3Ig
KGxldCBuID0gMDsgbiA8IGxpc3QubGVuZ3RoOyBuICs9IDEpIGlmIChsaXN0W25dID09PSBvdGhl
ci5jaGFyKSBsaXN0LnNwbGljZShuLCAxKTsKICAgIH0pOwogICAgaWYgKCFsaXN0Lmxlbmd0aCkg
bGlzdCA9IGF2YWlsYWJsZSgpOwogICAgaWYgKCFsaXN0Lmxlbmd0aCkgdGhyb3cgbmV3IFhtbEVy
cm9yKCdubyBjaGFyYWN0ZXJzJyk7CiAgICBtYW4uY2hhciA9IGxpc3RbdGhpcy5yb29tLm5leHRJ
bnQobGlzdC5sZW5ndGgpXTsKICAgIGNvbnN0IGNoYXJhY3RlciA9IENIQVJBQ1RFUlMuaW5kZXhP
ZihtYW4uY2hhcik7CiAgICBtYW4ubGV2ZWwgPSAxOwogICAgaWYgKGh1bWFuKSB7CiAgICAgIGlm
IChzbG90LmxldmVsc1tjaGFyYWN0ZXJdID4gMCkgbWFuLmxldmVsID0gc2xvdC5sZXZlbHNbY2hh
cmFjdGVyXTsKICAgIH0gZWxzZSB7CiAgICAgIG1hbi5sZXZlbCA9IHJvb20uY29tcHV0ZXJMZXZl
bChjaGFyYWN0ZXIpOwogICAgfQogICAgZm9yIChjb25zdCBvdGhlciBvZiByb29tLm1lbikgaWYg
KG90aGVyLmV4aXN0cyAmJiBvdGhlci5jb21tYW5kZXIgPT09IGluZGV4KSBvdGhlci5sZXZlbCA9
IG1hbi5sZXZlbDsKICB9CgogIC8vIGkuZyhTdHJpbmcpOiBjaGF0IHRoYXQgc3RhcnRzIHdpdGgg
Ii8iIGlzIGEgY29tbWFuZC4gUmV0dXJucyB3aGV0aGVyIHRoZSBsaW5lIGdvZXMgdG8gZXZlcnlv
bmUuCiAgY29tbWFuZCh0ZXh0KSB7CiAgICBpZiAodGV4dCA9PT0gbnVsbCkgcmV0dXJuIHRydWU7
CiAgICBjb25zdCBtZXNzYWdlID0gdGV4dC50cmltKCk7CiAgICBpZiAoIW1lc3NhZ2UgfHwgbWVz
c2FnZVswXSAhPT0gJy8nKSByZXR1cm4gdHJ1ZTsKICAgIGNvbnN0IHdvcmRzID0gbWVzc2FnZS5z
cGxpdCgvXHMrLyk7CiAgICBjb25zdCBuYW1lID0gd29yZHNbMF0udG9Mb3dlckNhc2UoKTsKICAg
IGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBpZiAobmFtZSA9PT0gJy9oZWxwJykgewogICAg
ICBpZiAod29yZHMubGVuZ3RoID4gMSkgcmV0dXJuIHRydWU7CiAgICAgIHRoaXMubm90aWNlKCc8
Yj5Db21tYW5kcyBhdmFpbGFibGU8L2I+OiAgL3F1aXQsIC9jbGVhciwgL21lLCAvbGF0LiA8YnIg
Lz5UeXBlID8gYWZ0ZXIgYSBjb21tYW5kIHRvIGxlYXJuIGFib3V0IGl0LiBFLmcuOiAvcXVpdCA/
ICcpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChuYW1lID09PSAnL3F1aXQnIHx8
IG5hbWUgPT09ICcvZXhpdCcpIHsKICAgICAgaWYgKHdvcmRzLmxlbmd0aCA+IDEgJiYgd29yZHNb
MV0gPT09ICc/JykgewogICAgICAgIHRoaXMubm90aWNlKCc8Yj5RdWl0PC9iPjogWW91IHdpbGwg
ZXhpdCB0aGUgcm9vbS48YnIgLz5JbnB1dHM6IC9xdWl0LCAvZXhpdC4nKTsKICAgICAgICByZXR1
cm4gdHJ1ZTsKICAgICAgfQogICAgICB0aGlzLmtpY2tlZCA9IHRydWU7CiAgICAgIHRoaXMubGVh
dmUoKTsKICAgICAgdGhpcy5jbG9zZSgpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlm
IChuYW1lID09PSAnL2NsZWFyJyB8fCBuYW1lID09PSAnL2NsZWFuJykgewogICAgICBpZiAod29y
ZHMubGVuZ3RoID4gMSkgewogICAgICAgIGlmICh3b3Jkc1sxXSA9PT0gJz8nKSB0aGlzLm5vdGlj
ZSgnPGI+Q2xlYXI8L2I+OiBXaWxsIGNsZWFyIGFsbCB0aGUgY2hhdCBvbiB5b3VyIHNjcmVlbi48
YnIgLz5JbnB1dHM6IC9jbGVhciwgL2NsZWFuLicpOwogICAgICAgIHJldHVybiB0cnVlOwogICAg
ICB9CiAgICAgIGZvciAobGV0IGsgPSAwOyBrIDwgNTA7IGsgKz0gMSkgdGhpcy5ub3RpY2UoJzxi
ciAvPicpOwogICAgICBmb3IgKGNvbnN0IHNsb3Qgb2Ygcm9vbS5vbmxpbmUoKSkgewogICAgICAg
IGlmIChzbG90LmNvbm5lY3Rpb24gIT09IHRoaXMpIHNsb3QuY29ubmVjdGlvbi5zZW5kKGA8Y2hh
dD48Yz4ke3RoaXMuaW5kZXh9PC9jPjxtPjwhW0NEQVRBWyR7d29yZHNbMF19XV0+PC9tPjwvY2hh
dD5gKTsKICAgICAgfQogICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgICBpZiAobmFtZSA9PT0g
Jy9tZScpIHsKICAgICAgaWYgKHdvcmRzLmxlbmd0aCA+IDEgJiYgd29yZHNbMV0gIT09ICc/Jykg
ewogICAgICAgIHRoaXMuYW5ub3VuY2UoYDxmb250IGNvbG9yPSIjQ0NDQ0ZGIj48aT4qPGI+ICR7
dGhpcy5uYW1lfTwvYj4gJHt3b3Jkcy5zbGljZSgxKS5qb2luKCcgJyl9IDwvaT48L2ZvbnQ+YCk7
CiAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgICB9CiAgICAgIHRoaXMubm90aWNlKCc8Yj5NRTwv
Yj46IFNlbmRzIHRoZSBhY3Rpb24gdG8gdGhlIGNoYXQgKGFjdGlvbnMgYXJlIHdyaXR0ZW4gaW4g
dGhlIDNyZCBwZXJzb24sIGxpa2UgL21lIGp1bXBzKS4nKTsKICAgICAgcmV0dXJuIHRydWU7CiAg
ICB9CiAgICBpZiAobmFtZSA9PT0gJy9sYXQnIHx8IG5hbWUgPT09ICcvbGF0ZW5jeScpIHsKICAg
ICAgY29uc3QgaGVscCA9ICdJdCB3aWxsIG5lZWQgYSBsYXRlbmN5IG51bWJlciBiZXR3ZWVuIDEg
YW5kIDk5IGFmdGVyIHRoZSBjb21tYW5kLiBFLmcuOiAvbGF0IDcnOwogICAgICBpZiAod29yZHMu
bGVuZ3RoIDw9IDEpIHRoaXMubm90aWNlKGA8Yj5MYXRlbmN5PC9iPjogJHtoZWxwfWApOwogICAg
ICBlbHNlIGlmICh3b3Jkc1sxXSA9PT0gJz8nKSB0aGlzLm5vdGljZShgPGI+TGF0ZW5jeTwvYj46
IENoYW5nZXMgeW91ciBsYXRlbmN5LiAke2hlbHB9PGJyIC8+SW5wdXRzOiAvbGF0LCAvbGF0ZW5j
eS5gKTsKICAgICAgZWxzZSBpZiAoIS9eWy0rXT9cZCskLy50ZXN0KHdvcmRzWzFdKSkgdGhpcy5u
b3RpY2UoYDxiPkxhdGVuY3k8L2I+OiAke2hlbHB9YCk7CiAgICAgIGVsc2UgewogICAgICAgIGNv
bnN0IHZhbHVlID0gTnVtYmVyKHdvcmRzWzFdKTsKICAgICAgICBpZiAodmFsdWUgPD0gMCkgdGhp
cy5ub3RpY2UoJzxiPkxhdGVuY3k8L2I+OiBZb3VyIGxhdGVuY3kgbXVzdCBiZSBiZXR3ZWVuIDEg
YW5kIDk5LicpOwogICAgICAgIGVsc2UgaWYgKHZhbHVlID4gOTkpIHRoaXMubm90aWNlKCdSZWFs
bHk/Jyk7CiAgICAgICAgZWxzZSB7CiAgICAgICAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90Owog
ICAgICAgICAgc2xvdC5sYXRlbmN5ID0gdmFsdWUgKyAxOwogICAgICAgICAgc2xvdC5sYXRlbmN5
VGFyZ2V0ID0gc2xvdC5sYXRlbmN5OwogICAgICAgICAgdGhpcy5ub3RpY2UoYDxiPkxhdGVuY3k8
L2I+OiBZb3VyIGxhdGVuY3kgaGFzIGJlZW4gY2hhbmdlZCB0byAke3Nsb3QubGF0ZW5jeSAtIDF9
LmApOwogICAgICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgICAgfQogICAg
ICB9CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgdGhpcy5ub3RpY2UoJ1VucmVjb2duaXpl
ZCBjb21tYW5kLicpOwogICAgcmV0dXJuIHRydWU7CiAgfQp9Cgptb2R1bGUuZXhwb3J0cyA9IHsg
SGZSb29tLCBIZkNvbm5lY3Rpb24sIHBhcnNlWG1sLCBieVRhZywgdmFsdWVPZiwgWG1sRXJyb3Is
IFZFUlNJT04sIENMSUVOVFMsIENIQVJBQ1RFUlMgfTsK
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
