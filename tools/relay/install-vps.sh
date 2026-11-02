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

INSTALLER_VERSION=12
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
IGluZm86IDY0LCBpbnB1dDogMTYsIHNldHVwOiA4MTkyLCBxdWV1ZTogNjQgfSk7Ci8vIFRoZSBs
YXJnZXN0IHRleHQgbWVzc2FnZSBhIHBhZ2UgbWF5IHNlbmQgKGEgZGlyZWN0IGNvbm5lY3Rpb24n
cyBvZmZlciBvciBhbnN3ZXIpLgpjb25zdCBTSUdOQUxfTElNSVQgPSAxNjM4NDsKCmZ1bmN0aW9u
IHJlYWRDb25maWcoZW52ID0gcHJvY2Vzcy5lbnYpIHsKICBjb25zdCBudW1iZXIgPSAobmFtZSwg
ZmFsbGJhY2spID0+IHsKICAgIGNvbnN0IHJhdyA9IGVudltuYW1lXTsKICAgIGNvbnN0IHZhbHVl
ID0gcmF3ID09PSB1bmRlZmluZWQgfHwgcmF3ID09PSAnJyA/IGZhbGxiYWNrIDogTnVtYmVyKHJh
dyk7CiAgICBpZiAoIU51bWJlci5pc0Zpbml0ZSh2YWx1ZSkgfHwgdmFsdWUgPCAwKSB0aHJvdyBu
ZXcgRXJyb3IoYCR7bmFtZX0gbXVzdCBiZSBhIG5vbi1uZWdhdGl2ZSBudW1iZXJgKTsKICAgIHJl
dHVybiB2YWx1ZTsKICB9OwogIHJldHVybiB7CiAgICBwb3J0OiBudW1iZXIoJ1BPUlQnLCA4Nzg3
KSwKICAgIGhvc3Q6IGVudi5IT1NUIHx8ICcwLjAuMC4wJywKICAgIHBhdGg6IGVudi5SRUxBWV9Q
QVRIIHx8ICcvcmVsYXknLAogICAgLy8gQ29tbWEtc2VwYXJhdGVkIHBhZ2Ugb3JpZ2lucyBhbGxv
d2VkIHRvIGNvbm5lY3QsIGUuZy4gImh0dHBzOi8veW91LmdpdGh1Yi5pbyIuIEVtcHR5IGFsbG93
cyBhbnkuCiAgICBhbGxvd2VkT3JpZ2luczogKGVudi5BTExPV0VEX09SSUdJTlMgfHwgJycpLnNw
bGl0KCcsJykubWFwKG5vcm1hbGl6ZU9yaWdpbikuZmlsdGVyKEJvb2xlYW4pLAogICAgLy8gQmVo
aW5kIGEgcmV2ZXJzZSBwcm94eSAoQ2FkZHksIG5naW54LCBDbG91ZGZsYXJlKSwgdGFrZSB0aGUg
Y2xpZW50IGFkZHJlc3MgZnJvbSBYLUZvcndhcmRlZC1Gb3IuCiAgICB0cnVzdFByb3h5OiBlbnYu
VFJVU1RfUFJPWFkgPT09ICcxJyB8fCBlbnYuVFJVU1RfUFJPWFkgPT09ICd0cnVlJywKICAgIG1h
eFJvb21zOiBudW1iZXIoJ01BWF9ST09NUycsIDUwMCksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIG1h
eENvbm5lY3Rpb25zUGVySXA6IG51bWJlcignTUFYX0NPTk5FQ1RJT05TX1BFUl9JUCcsIDgpLCAv
LyAwID0gdW5saW1pdGVkCiAgICByb29tV2FpdE1zOiBudW1iZXIoJ1JPT01fV0FJVF9NUycsIDEy
MDAwMCksCiAgICBwaW5nSW50ZXJ2YWxNczogbnVtYmVyKCdQSU5HX0lOVEVSVkFMX01TJywgMTUw
MDApLAogICAgbWF4TWVzc2FnZUJ5dGVzOiBudW1iZXIoJ01BWF9NRVNTQUdFX0JZVEVTJywgNjU1
MzYpLCAvLyB0aGUgZ2FtZSBxdWV1ZXMgYXQgbW9zdCA2NCBLaUIKICAgIG1lc3NhZ2VzUGVyU2Vj
b25kOiBudW1iZXIoJ01FU1NBR0VTX1BFUl9TRUNPTkQnLCAyNDApLCAvLyB0aGUgZ2FtZSBzZW5k
cyB+MzAgcGVyIHNlY29uZDsgMCA9IHVubGltaXRlZAogICAgYnl0ZXNQZXJTZWNvbmQ6IG51bWJl
cignQllURVNfUEVSX1NFQ09ORCcsIDEzMTA3MiksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIG1heEJ1
ZmZlcmVkQnl0ZXM6IG51bWJlcignTUFYX0JVRkZFUkVEX0JZVEVTJywgMTA0ODU3NiksCiAgICAv
LyBUZXN0aW5nIGFpZDogaG9sZCBldmVyeSBmb3J3YXJkZWQgZnJhbWUgdGhpcyBsb25nLCB0byBm
ZWVsIGhvdyBhIGRpc3RhbnQgcmVsYXkgd291bGQgcGxheS4KICAgIGZvcndhcmREZWxheU1zOiBu
dW1iZXIoJ0ZPUldBUkRfREVMQVlfTVMnLCAwKSwKICAgIC8vIFByb3RvY29sIDIgcm9vbXM6IG1v
c3QgcGxheWVycyBpbiBhIHJvb20gKGF0IG1vc3QgOCwgdGhlIGdhbWUncyBwbGF5ZXIgc2xvdHMp
LCB0aGUgYmVhdCwgaG93CiAgICAvLyBsb25nIGEgcm9vbSBtYXkgd2FpdCBmb3IgaXRzIGhvc3Qg
dG8gcHJlc3Mgc3RhcnQsIGhvdyBsb25nIHRoZSByZWxheSB3YWl0cyBmb3IgZXZlcnkgZ2FtZSB0
bwogICAgLy8gYmUgcmVhZHkgYWZ0ZXIgdGhlIHN0YXJ0LCBhbmQgYWZ0ZXIgaG93IG1hbnkgYmVh
dHMgd2l0aG91dCBuZXdzIGEgcGxheWVyJ3Mga2V5cyBjb3VudCBhcyByZWxlYXNlZC4KICAgIHJv
b21QbGF5ZXJzOiBNYXRoLm1pbihST09NX0xJTUlUUy5wbGF5ZXJzLCBNYXRoLm1heCgyLCBudW1i
ZXIoJ1JPT01fUExBWUVSUycsIFJPT01fTElNSVRTLnBsYXllcnMpKSksCiAgICAvLyAzMyAxLzMg
bXM6IDMwIGJlYXRzIHBlciBzZWNvbmQsIHR3byByZWZyZXNoZXMgb2YgYSA2MCBIeiBkaXNwbGF5
IGVhY2ggKHdob2xlIHRoaXJkcyBvZiBhIG1zIG9ubHkpLgogICAgdGlja01zOiBNYXRoLm1heCgx
LCBNYXRoLnJvdW5kKG51bWJlcignVElDS19NUycsIDEwMCAvIDMpICogMykgLyAzKSwKICAgIGxv
YmJ5V2FpdE1zOiBudW1iZXIoJ0xPQkJZX1dBSVRfTVMnLCAxODAwMDAwKSwKICAgIHN0YXJ0R3Jh
Y2VNczogbnVtYmVyKCdTVEFSVF9HUkFDRV9NUycsIDUwMDApLAogICAgcmVwZWF0TGltaXQ6IG51
bWJlcignUkVQRUFUX0xJTUlUJywgMTUpLAogICAgLy8gVGhlIExGMiBpbnN0YWxsZXIgc2VydmVk
IGF0IC9sZjItaW5zdGFsbGVyLmRhdGEgKGVtcHR5OiBub3Qgc2VydmVkKSwgYW5kIGhvdyBvZnRl
biBvbmUgY2xpZW50CiAgICAvLyBhZGRyZXNzIG1heSBkb3dubG9hZCBpdCAoYWJvdXQgMzAgTUIg
ZWFjaCB0aW1lOyBicm93c2VycyBrZWVwIGl0IGFmdGVyIHRoZSBmaXJzdCB0aW1lKS4KICAgIGlu
c3RhbGxlckZpbGU6IGVudi5JTlNUQUxMRVJfRklMRSB8fCAnJywKICAgIGluc3RhbGxlckRvd25s
b2Fkc1BlckhvdXI6IG51bWJlcignSU5TVEFMTEVSX0RPV05MT0FEU19QRVJfSE9VUicsIDIwKSwg
Ly8gMCA9IHVubGltaXRlZAogICAgLy8gR2FtZSBwYWNrcyAocGFja3MuanMpOiB3aGVyZSB0aGV5
IGFyZSBrZXB0IChlbXB0eTogbm9uZSksIHRoZSBrZXkgZm9yIHVwbG9hZGluZyB0aGVtIGF0IC9h
ZG1pbgogICAgLy8gKGVtcHR5OiBubyB1cGxvYWRzKSwgdGhlaXIgbGFyZ2VzdCBzaXplLCBhbmQg
aG93IG9mdGVuIG9uZSBjbGllbnQgYWRkcmVzcyBtYXkgZG93bmxvYWQgb25lLgogICAgcGFja3NE
aXI6IGVudi5QQUNLU19ESVIgfHwgJycsCiAgICBhZG1pbktleTogZW52LkFETUlOX0tFWSB8fCAn
JywKICAgIG1heFBhY2tCeXRlczogbnVtYmVyKCdNQVhfUEFDS19CWVRFUycsIDEwMjQgKiAxMDI0
ICogMTAyNCksCiAgICBwYWNrRG93bmxvYWRzUGVySG91cjogbnVtYmVyKCdQQUNLX0RPV05MT0FE
U19QRVJfSE9VUicsIDIwKSwgLy8gMCA9IHVubGltaXRlZAogICAgLy8gSGVybyBGaWdodGVyICho
Zi5qcyk6IGhvdyBtYW55IHJvb21zLCB0aGVpciBkZXNjcmlwdGlvbiBpbiB0aGUgZ2FtZSdzIHJv
b20gbGlzdCwgYW5kIHdoZXJlIHRoZQogICAgLy8gYWNjb3VudHMgYXJlIGtlcHQgKGVtcHR5OiBp
biA8UEFDS1NfRElSPi9oZiwgb3Igb25seSBpbiBtZW1vcnkgd2l0aG91dCBQQUNLU19ESVIpLgog
ICAgaGZSb29tczogbnVtYmVyKCdIRl9ST09NUycsIDQpLAogICAgaGZSb29tRGVzY3JpcHRpb246
IGVudi5IRl9ST09NX0RFU0NSSVBUSU9OIHx8ICdPcGVuTEYyIHJlbGF5JywKICAgIGhmRGlyOiBl
bnYuSEZfRElSIHx8ICcnLAogICAgcXVpZXQ6IGVudi5RVUlFVCA9PT0gJzEnIHx8IGVudi5RVUlF
VCA9PT0gJ3RydWUnLAogIH07Cn0KCmZ1bmN0aW9uIG5vcm1hbGl6ZU9yaWdpbih2YWx1ZSkgewog
IHJldHVybiBTdHJpbmcodmFsdWUgfHwgJycpLnRyaW0oKS5yZXBsYWNlKC9cLyskLywgJycpLnRv
TG93ZXJDYXNlKCk7Cn0KCi8vIFRva2VuIGJ1Y2tldDogYHJhdGVgIHVuaXRzIHBlciBzZWNvbmQs
IGJ1cnN0cyB1cCB0byBgY2FwYWNpdHlgLiBBIHJhdGUgb2YgMCBkaXNhYmxlcyB0aGUgbGltaXQu
CmNsYXNzIEJ1Y2tldCB7CiAgY29uc3RydWN0b3IocmF0ZSwgY2FwYWNpdHkpIHsKICAgIHRoaXMu
cmF0ZSA9IHJhdGU7CiAgICB0aGlzLmNhcGFjaXR5ID0gTWF0aC5tYXgoY2FwYWNpdHksIHJhdGUp
OwogICAgdGhpcy50b2tlbnMgPSB0aGlzLmNhcGFjaXR5OwogICAgdGhpcy5sYXN0ID0gRGF0ZS5u
b3coKTsKICB9CiAgdGFrZShhbW91bnQpIHsKICAgIGlmICh0aGlzLnJhdGUgPT09IDApIHJldHVy
biB0cnVlOwogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIHRoaXMudG9rZW5zID0gTWF0
aC5taW4odGhpcy5jYXBhY2l0eSwgdGhpcy50b2tlbnMgKyAoKG5vdyAtIHRoaXMubGFzdCkgKiB0
aGlzLnJhdGUpIC8gMTAwMCk7CiAgICB0aGlzLmxhc3QgPSBub3c7CiAgICBpZiAodGhpcy50b2tl
bnMgPCBhbW91bnQpIHJldHVybiBmYWxzZTsKICAgIHRoaXMudG9rZW5zIC09IGFtb3VudDsKICAg
IHJldHVybiB0cnVlOwogIH0KfQoKZnVuY3Rpb24gY3JlYXRlUmVsYXkob3ZlcnJpZGVzID0ge30p
IHsKICBjb25zdCBjb25maWcgPSB7IC4uLnJlYWRDb25maWcoe30pLCAuLi5vdmVycmlkZXMgfTsK
ICBjb25zdCByb29tcyA9IG5ldyBNYXAoKTsgLy8gcHJvdG9jb2wgMTogY29kZSAtPiB7IGNvZGUs
IGhvc3QsIGpvaW4sIHRpbWVyIH0KICBjb25zdCBncm91cHMgPSBuZXcgTWFwKCk7IC8vIHByb3Rv
Y29sIDI6IGNvZGUgLT4gcm9vbSAoc2VlICJSb29tcyIgYmVsb3cpCiAgY29uc3QgY29ubmVjdGlv
bnNQZXJJcCA9IG5ldyBNYXAoKTsKICBjb25zdCBsb2cgPSAoLi4ucGFydHMpID0+IHsgaWYgKCFj
b25maWcucXVpZXQpIGNvbnNvbGUubG9nKG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKSwgLi4ucGFy
dHMpOyB9OwoKICBjb25zdCBpbnN0YWxsZXJEb3dubG9hZHMgPSBuZXcgTWFwKCk7IC8vIGNsaWVu
dCBhZGRyZXNzIC0+IHsgY291bnQsIHVudGlsIH0KICBjb25zdCBpbnN0YWxsZXJQYXRocyA9IG5l
dyBTZXQoW0lOU1RBTExFUl9QQVRILCBjb25maWcucGF0aC5yZXBsYWNlKC9bXi9dKiQvLCBJTlNU
QUxMRVJfUEFUSC5zbGljZSgxKSldKTsKICAvLyBCZXNpZGUgdGhlIFdlYlNvY2tldCBwYXRoLCBh
cyB0aGUgaW5zdGFsbGVyIGNvcHk6IC94L3JlbGF5IC0+IC94L2xmMi1wYWNrcy5qc29uIGFuZCAv
eC9hZG1pbi4KICBjb25zdCByZWxheUZvbGRlciA9IGNvbmZpZy5wYXRoLnJlcGxhY2UoL1teL10q
JC8sICcnKTsKICBjb25zdCBwYWNrcyA9IGNyZWF0ZVBhY2tzKGNvbmZpZywgeyBsb2csIGNsaWVu
dEFkZHJlc3M6IChyZXEpID0+IGNsaWVudEFkZHJlc3MocmVxKSwgYWxsb3dPcmlnaW46IChyZXEp
ID0+IGFsbG93T3JpZ2luKHJlcSksCiAgICBoZkpvdXJuYWw6ICgpID0+IGhmLmpvdXJuYWwoKSB9
KTsKICBjb25zdCBoZiA9IGNyZWF0ZUhmKGNvbmZpZywgewogICAgbG9nLCBjbGllbnRBZGRyZXNz
OiAocmVxKSA9PiBjbGllbnRBZGRyZXNzKHJlcSksIGFsbG93T3JpZ2luOiAocmVxKSA9PiBhbGxv
d09yaWdpbihyZXEpLAogICAgYnVkZ2V0OiAod3MsIGJ5dGVzKSA9PiB3cy5tZXNzYWdlQnVkZ2V0
LnRha2UoMSkgJiYgd3MuYnl0ZUJ1ZGdldC50YWtlKGJ5dGVzKSwKICB9KTsKCiAgY29uc3Qgc2Vy
dmVyID0gaHR0cC5jcmVhdGVTZXJ2ZXIoKHJlcSwgcmVzKSA9PiB7CiAgICBjb25zdCB7IHBhdGhu
YW1lIH0gPSBuZXcgVVJMKHJlcS51cmwsICdodHRwOi8vcmVsYXkuaW52YWxpZCcpOwogICAgaWYg
KHBhdGhuYW1lID09PSAnL2hlYWx0aHonKSB7CiAgICAgIC8vIFJlYWRhYmxlIGZyb20gdGhlIGdh
bWUgcGFnZSAoYW5vdGhlciBvcmlnaW4pIHNvIGl0cyBPbmxpbmUgcGFuZWwgY2FuIHNob3cgInJl
bGF5IE9LIi4KICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsKICAgICAgICAnY29udGVudC10eXBl
JzogJ2FwcGxpY2F0aW9uL2pzb24nLAogICAgICAgICdjYWNoZS1jb250cm9sJzogJ25vLXN0b3Jl
JywKICAgICAgICAnYWNjZXNzLWNvbnRyb2wtYWxsb3ctb3JpZ2luJzogJyonLAogICAgICB9KTsK
ICAgICAgcmVzLmVuZChKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgb2s6IHRydWUsIHJvb21zOiBy
b29tcy5zaXplICsgZ3JvdXBzLnNpemUsIGNsaWVudHM6IHdzcy5jbGllbnRzLnNpemUsIGluc3Rh
bGxlcjogaW5zdGFsbGVyU2l6ZSgpID4gMCwKICAgICAgICBwcm90b2NvbHM6IFsxLCAyXSwgcGxh
eWVyczogY29uZmlnLnJvb21QbGF5ZXJzLCBwYWNrczogQm9vbGVhbihjb25maWcucGFja3NEaXIp
LCBoZjogaGYuZGVzY3JpYmUoKSwgZGlyZWN0OiB0cnVlLAogICAgICB9KSk7CiAgICAgIHJldHVy
bjsKICAgIH0KICAgIGlmIChpbnN0YWxsZXJQYXRocy5oYXMocGF0aG5hbWUpKSB7CiAgICAgIHNl
cnZlSW5zdGFsbGVyKHJlcSwgcmVzKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3QgbG9j
YWwgPSByZWxheUZvbGRlciAhPT0gJy8nICYmIHBhdGhuYW1lLnN0YXJ0c1dpdGgocmVsYXlGb2xk
ZXIpID8gcGF0aG5hbWUuc2xpY2UocmVsYXlGb2xkZXIubGVuZ3RoIC0gMSkgOiBwYXRobmFtZTsK
ICAgIGlmIChwYWNrcy5oYW5kbGUocmVxLCByZXMsIGxvY2FsKSkgcmV0dXJuOwogICAgaWYgKGhm
LmhhbmRsZShyZXEsIHJlcywgbG9jYWwpKSByZXR1cm47CiAgICBpZiAocGF0aG5hbWUgPT09ICcv
JyB8fCBwYXRobmFtZSA9PT0gY29uZmlnLnBhdGgpIHsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAs
IHsgJ2NvbnRlbnQtdHlwZSc6ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JyB9KTsKICAgICAg
cmVzLmVuZChgT3BlbkxGMiByZWxheSBpcyBydW5uaW5nLiBDb25uZWN0IHdpdGggYSBXZWJTb2Nr
ZXQgdG8gJHtjb25maWcucGF0aH1cbmApOwogICAgICByZXR1cm47CiAgICB9CiAgICByZXMud3Jp
dGVIZWFkKDQwNCwgeyAnY29udGVudC10eXBlJzogJ3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgn
IH0pOwogICAgcmVzLmVuZCgnTm90IGZvdW5kXG4nKTsKICB9KTsKCiAgLy8gVXBsb2FkaW5nIGEg
Z2FtZSBwYWNrIGZyb20gYSBzbG93IGxpbmUgbWF5IHRha2UgYSB3aGlsZSAoTm9kZSdzIGRlZmF1
bHQgZ2l2ZXMgdXAgYWZ0ZXIgNSBtaW51dGVzKS4KICBzZXJ2ZXIucmVxdWVzdFRpbWVvdXQgPSAy
ICogMzYwMCAqIDEwMDA7CgogIGNvbnN0IHdzcyA9IG5ldyBXZWJTb2NrZXRTZXJ2ZXIoewogICAg
bm9TZXJ2ZXI6IHRydWUsCiAgICBtYXhQYXlsb2FkOiBjb25maWcubWF4TWVzc2FnZUJ5dGVzLAog
ICAgcGVyTWVzc2FnZURlZmxhdGU6IGZhbHNlLCAvLyAyMi1ieXRlIHBhY2tldHM6IGNvbXByZXNz
aW9uIG9ubHkgYWRkcyBsYXRlbmN5CiAgfSk7CgogIHNlcnZlci5vbigndXBncmFkZScsIChyZXEs
IHNvY2tldCwgaGVhZCkgPT4gewogICAgY29uc3QgdXJsID0gbmV3IFVSTChyZXEudXJsLCAnaHR0
cDovL3JlbGF5LmludmFsaWQnKTsKICAgIGlmICh1cmwucGF0aG5hbWUgIT09IGNvbmZpZy5wYXRo
ICYmIHVybC5wYXRobmFtZSAhPT0gJy8nKSB7CiAgICAgIHNvY2tldC5lbmQoJ0hUVFAvMS4xIDQw
NCBOb3QgRm91bmRcclxuQ29ubmVjdGlvbjogY2xvc2VcclxuXHJcbicpOwogICAgICByZXR1cm47
CiAgICB9CiAgICAvLyBSZXF1ZXN0cyBhcmUgdmFsaWRhdGVkIGFmdGVyIHRoZSB1cGdyYWRlLCBz
byB0aGUgYnJvd3NlciByZWNlaXZlcyBhIGNsb3NlIGNvZGUgYW5kIHJlYXNvbgogICAgLy8gaW5z
dGVhZCBvZiBhbiBhbm9ueW1vdXMgY29ubmVjdGlvbiBlcnJvci4KICAgIHdzcy5oYW5kbGVVcGdy
YWRlKHJlcSwgc29ja2V0LCBoZWFkLCAod3MpID0+IHdzcy5lbWl0KCdjb25uZWN0aW9uJywgd3Ms
IHJlcSwgdXJsKSk7CiAgfSk7CgogIHdzcy5vbignY29ubmVjdGlvbicsICh3cywgcmVxLCB1cmwp
ID0+IHsKICAgIHdzLmlzQWxpdmUgPSB0cnVlOwogICAgd3Mub24oJ3BvbmcnLCAoKSA9PiB7IHdz
LmlzQWxpdmUgPSB0cnVlOyB9KTsKICAgIHdzLm9uKCdlcnJvcicsICgpID0+IHt9KTsgLy8gYSAn
Y2xvc2UnIGV2ZW50IGFsd2F5cyBmb2xsb3dzCgogICAgaWYgKGNvbmZpZy5hbGxvd2VkT3JpZ2lu
cy5sZW5ndGggJiYgIWNvbmZpZy5hbGxvd2VkT3JpZ2lucy5pbmNsdWRlcyhub3JtYWxpemVPcmln
aW4ocmVxLmhlYWRlcnMub3JpZ2luKSkpIHsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xP
U0Uub3JpZ2luRGVuaWVkKTsKICAgIH0KICAgIGNvbnN0IHJvbGUgPSB1cmwuc2VhcmNoUGFyYW1z
LmdldCgncm9sZScpOwogICAgY29uc3QgY29kZSA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdyb29t
JykgfHwgJyc7CiAgICBjb25zdCBoZXJvRmlnaHRlciA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdn
YW1lJykgPT09ICdoZic7IC8vIGEgSGVybyBGaWdodGVyIHJvb20gKGhmLmpzKQogICAgaWYgKCFo
ZXJvRmlnaHRlciAmJiAoKHJvbGUgIT09ICdob3N0JyAmJiByb2xlICE9PSAnam9pbicpIHx8ICFS
T09NX1BBVFRFUk4udGVzdChjb2RlKSkpIHsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xP
U0UuYmFkUmVxdWVzdCk7CiAgICB9CgogICAgY29uc3QgYWRkcmVzcyA9IGNsaWVudEFkZHJlc3Mo
cmVxKTsKICAgIGNvbnN0IGNvdW50ID0gY29ubmVjdGlvbnNQZXJJcC5nZXQoYWRkcmVzcykgfHwg
MDsKICAgIGlmIChjb25maWcubWF4Q29ubmVjdGlvbnNQZXJJcCAmJiBjb3VudCA+PSBjb25maWcu
bWF4Q29ubmVjdGlvbnNQZXJJcCkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS50
b29NYW55Q29ubmVjdGlvbnMpOwogICAgfQogICAgY29ubmVjdGlvbnNQZXJJcC5zZXQoYWRkcmVz
cywgY291bnQgKyAxKTsKICAgIHdzLm9uY2UoJ2Nsb3NlJywgKCkgPT4gewogICAgICBjb25zdCBs
ZWZ0ID0gKGNvbm5lY3Rpb25zUGVySXAuZ2V0KGFkZHJlc3MpIHx8IDEpIC0gMTsKICAgICAgaWYg
KGxlZnQgPiAwKSBjb25uZWN0aW9uc1BlcklwLnNldChhZGRyZXNzLCBsZWZ0KTsKICAgICAgZWxz
ZSBjb25uZWN0aW9uc1BlcklwLmRlbGV0ZShhZGRyZXNzKTsKICAgIH0pOwogICAgd3MubWVzc2Fn
ZUJ1ZGdldCA9IG5ldyBCdWNrZXQoY29uZmlnLm1lc3NhZ2VzUGVyU2Vjb25kLCBjb25maWcubWVz
c2FnZXNQZXJTZWNvbmQgKiAyKTsKICAgIHdzLmJ5dGVCdWRnZXQgPSBuZXcgQnVja2V0KGNvbmZp
Zy5ieXRlc1BlclNlY29uZCwgTWF0aC5tYXgoY29uZmlnLmJ5dGVzUGVyU2Vjb25kLCBjb25maWcu
bWF4TWVzc2FnZUJ5dGVzKSAqIDIpOwogICAgaWYgKGhlcm9GaWdodGVyKSByZXR1cm4gaGYuY29u
bmVjdCh3cywgcmVxLCB1cmwpOwoKICAgIGNvbnN0IHZlcnNpb24gPSB1cmwuc2VhcmNoUGFyYW1z
LmdldCgndicpOwogICAgaWYgKHZlcnNpb24gPT09ICcyJykgcmV0dXJuIGpvaW5Hcm91cCh3cywg
cm9sZSwgY29kZSk7CiAgICBpZiAodmVyc2lvbiAhPT0gbnVsbCAmJiB2ZXJzaW9uICE9PSAnMScp
IHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLmJhZFJlcXVlc3QpOwogICAgaWYgKGdyb3Vwcy5o
YXMoY29kZSkpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLm5ld2VyUm9vbSk7CgogICAgbGV0
IHJvb20gPSByb29tcy5nZXQoY29kZSk7CiAgICBpZiAoIXJvb20pIHsKICAgICAgaWYgKGNvbmZp
Zy5tYXhSb29tcyAmJiByb29tcy5zaXplICsgZ3JvdXBzLnNpemUgPj0gY29uZmlnLm1heFJvb21z
KSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5zZXJ2ZXJGdWxsKTsKICAgICAgcm9vbSA9IHsg
Y29kZSwgaG9zdDogbnVsbCwgam9pbjogbnVsbCwgdGltZXI6IG51bGwgfTsKICAgICAgcm9vbXMu
c2V0KGNvZGUsIHJvb20pOwogICAgfQogICAgaWYgKHJvb21bcm9sZV0pIHJldHVybiBjbG9zZVdp
dGgod3MsIHJvbGUgPT09ICdob3N0JyA/IENMT1NFLmhvc3RUYWtlbiA6IENMT1NFLmd1ZXN0VGFr
ZW4pOwoKICAgIHJvb21bcm9sZV0gPSB3czsKICAgIHdzLnJvb20gPSByb29tOwogICAgd3Mucm9s
ZSA9IHJvbGU7CiAgICB3cy5wZWVyID0gbnVsbDsKICAgIHdzLm9uKCdtZXNzYWdlJywgKGRhdGEs
IGlzQmluYXJ5KSA9PiBvbk1lc3NhZ2Uod3MsIGRhdGEsIGlzQmluYXJ5KSk7CiAgICB3cy5vbign
Y2xvc2UnLCAoKSA9PiBvbkNsb3NlKHdzKSk7CgogICAgY29uc3Qgb3RoZXIgPSByb29tW3JvbGUg
PT09ICdob3N0JyA/ICdqb2luJyA6ICdob3N0J107CiAgICBpZiAob3RoZXIpIHsKICAgICAgY2xl
YXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICByb29tLnRpbWVyID0gbnVsbDsKICAgICAgd3Mu
cGVlciA9IG90aGVyOwogICAgICBvdGhlci5wZWVyID0gd3M7CiAgICAgIC8vIEJvdGggcGVlcnMg
YXJlIGxpbmtlZCBiZWZvcmUgZWl0aGVyIGxlYXJucyBhYm91dCBpdCwgc28gYW55IGRhdGEgdGhh
dCBmb2xsb3dzIGhhcyBhIGRlc3RpbmF0aW9uLgogICAgICBzZW5kQ29udHJvbChvdGhlciwgeyB0
OiAncGFpcmVkJyB9KTsKICAgICAgc2VuZENvbnRyb2wod3MsIHsgdDogJ3BhaXJlZCcgfSk7CiAg
ICAgIGxvZyhgcm9vbSAke2NvZGV9OiBwYWlyZWRgKTsKICAgIH0gZWxzZSB7CiAgICAgIHNlbmRD
b250cm9sKHdzLCB7IHQ6ICd3YWl0aW5nJywgcm9vbTogY29kZSB9KTsKICAgICAgcm9vbS50aW1l
ciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgIGlmIChyb29tW3JvbGVdID09PSB3cyAmJiAh
d3MucGVlcikgY2xvc2VXaXRoKHdzLCBDTE9TRS50aW1lb3V0KTsKICAgICAgfSwgY29uZmlnLnJv
b21XYWl0TXMpOwogICAgICBsb2coYHJvb20gJHtjb2RlfTogJHtyb2xlfSB3YWl0aW5nYCk7CiAg
ICB9CiAgfSk7CgogIGZ1bmN0aW9uIG9uTWVzc2FnZSh3cywgZGF0YSwgaXNCaW5hcnkpIHsKICAg
IGlmICghaXNCaW5hcnkpIHJldHVybjsgLy8gb25seSB0aGUgcmVsYXkgc3BlYWtzIHRleHQ7IGNs
aWVudHMgc2VuZCBnYW1lIGJ5dGVzIGFzIGJpbmFyeSBmcmFtZXMKICAgIGlmICghd3MucGVlcikg
cmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuZWFybHlEYXRhKTsKICAgIGlmICghd3MubWVzc2Fn
ZUJ1ZGdldC50YWtlKDEpIHx8ICF3cy5ieXRlQnVkZ2V0LnRha2UoZGF0YS5sZW5ndGgpKSB7CiAg
ICAgIGxvZyhgcm9vbSAke3dzLnJvb20uY29kZX06IHJhdGUgbGltaXRgKTsKICAgICAgY2xvc2VX
aXRoKHdzLnBlZXIsIENMT1NFLnJhdGVMaW1pdGVkKTsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3
cywgQ0xPU0UucmF0ZUxpbWl0ZWQpOwogICAgfQogICAgY29uc3QgcGVlciA9IHdzLnBlZXI7CiAg
ICBpZiAocGVlci5yZWFkeVN0YXRlICE9PSBXZWJTb2NrZXQuT1BFTikgcmV0dXJuOwogICAgaWYg
KHBlZXIuYnVmZmVyZWRBbW91bnQgPiBjb25maWcubWF4QnVmZmVyZWRCeXRlcykgewogICAgICBj
bG9zZVdpdGgod3MsIENMT1NFLnNsb3dQZWVyKTsKICAgICAgcmV0dXJuIGNsb3NlV2l0aChwZWVy
LCBDTE9TRS5zbG93UGVlcik7CiAgICB9CiAgICBpZiAoY29uZmlnLmZvcndhcmREZWxheU1zID4g
MCkgewogICAgICAvLyBUaW1lcnMgd2l0aCB0aGUgc2FtZSBkZWxheSBmaXJlIGluIHRoZSBvcmRl
ciB0aGV5IHdlcmUgc2V0LCBzbyB0aGUgc3RyZWFtIHN0YXlzIGluIG9yZGVyLgogICAgICBzZXRU
aW1lb3V0KCgpID0+IHsgaWYgKHBlZXIucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4pIHBl
ZXIuc2VuZChkYXRhLCB7IGJpbmFyeTogdHJ1ZSB9KTsgfSwgY29uZmlnLmZvcndhcmREZWxheU1z
KTsKICAgICAgcmV0dXJuOwogICAgfQogICAgcGVlci5zZW5kKGRhdGEsIHsgYmluYXJ5OiB0cnVl
IH0pOwogIH0KCiAgZnVuY3Rpb24gb25DbG9zZSh3cykgewogICAgY29uc3Qgcm9vbSA9IHdzLnJv
b207CiAgICBpZiAoIXJvb20pIHJldHVybjsKICAgIGlmIChyb29tW3dzLnJvbGVdID09PSB3cykg
cm9vbVt3cy5yb2xlXSA9IG51bGw7CiAgICBjb25zdCBwZWVyID0gd3MucGVlcjsKICAgIHdzLnBl
ZXIgPSBudWxsOwogICAgaWYgKHBlZXIpIHsKICAgICAgLy8gQSBsb2Nrc3RlcCBtYXRjaCBjYW5u
b3QgY29udGludWUgd2l0aCBvbmUgcGxheWVyLCBzbyB0aGUgcm9vbSBlbmRzIHdpdGggdGhlIHBh
aXIgYW5kIGl0cwogICAgICAvLyBjb2RlIGlzIGZyZWUgYWdhaW4gYXQgb25jZSAodGhlIGhvc3Qg
Y2FuIHByZXNzIEhvc3QgYWdhaW4gd2l0aCB0aGUgc2FtZSBjb2RlKS4KICAgICAgcGVlci5wZWVy
ID0gbnVsbDsKICAgICAgcm9vbS5ob3N0ID0gcm9vbS5qb2luID0gbnVsbDsKICAgICAgY2xvc2VX
aXRoKHBlZXIsIENMT1NFLnBlZXJMZWZ0KTsKICAgICAgbG9nKGByb29tICR7cm9vbS5jb2RlfTog
ZW5kZWRgKTsKICAgIH0KICAgIGlmICghcm9vbS5ob3N0ICYmICFyb29tLmpvaW4pIHsKICAgICAg
Y2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICBpZiAocm9vbXMuZ2V0KHJvb20uY29kZSkg
PT09IHJvb20pIHJvb21zLmRlbGV0ZShyb29tLmNvZGUpOwogICAgfQogIH0KCiAgLy8gLS0tLSBS
b29tcyAocHJvdG9jb2wgMikgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAvLwogIC8vIFVwIHRvIGNvbmZpZy5y
b29tUGxheWVycyBnYW1lcyBzaGFyZSBhIHJvb20uIEVhY2ggc2F5cyBIRUxMTyB3aXRoIGl0cyBw
cm9maWxlIChlbmdpbmUsIHNjcmlwdHMsCiAgLy8gbW9kcyBhbmQgZ2FtZSBkYXRhOiB0aGUgZmly
c3QgSEVMTE8gc2V0cyB0aGUgcm9vbSdzLCBhbmQgYSBnYW1lIHdpdGggYW5vdGhlciBvbmUgaXMg
dHVybmVkIGF3YXkpCiAgLy8gYW5kIGl0cyBwbGF5ZXIgbmFtZXM7IExPQkJZIGxpc3RzIHRoZSBw
bGF5ZXJzIHRvIGV2ZXJ5b25lLiBUaGUgaG9zdCBzZW5kcyBTVEFSVCB3aXRoIHRoZSBzZXR1cAog
IC8vIGV2ZXJ5IGdhbWUgbmVlZHMgKHRoZSByYW5kb20gdGFibGUpOyBTVEFSVEVEIGdpdmVzIGV2
ZXJ5IGdhbWUgdGhlIGZpbmFsIGxpc3Qgb2YgcGxheWVycywgd2hvc2UKICAvLyBwb3NpdGlvbiBp
cyB0aGUgcGxheWVyJ3MgaW5kZXgsIGFuZCBvbmNlIGV2ZXJ5IGdhbWUgaXMgUkVBRFkgKG9yIGFm
dGVyIHN0YXJ0R3JhY2VNcykgdGhlIGJlYXQKICAvLyBiZWdpbnM6IGV2ZXJ5IHRpY2tNcywgRlJB
TUUgd2l0aCB0aGUgaW5wdXQgb2YgZWFjaCBwbGF5ZXIuIFRoZSBpbnB1dHMgYSBwbGF5ZXIgc2Vu
dCBzaW5jZSB0aGUKICAvLyBsYXN0IGJlYXQgYXJlIG1lcmdlZCAoT1I6IGEga2V5IGhlbGQgaW4g
YW55IG9mIHRoZW0gaXMgaGVsZCwgc28gYSBxdWljayB0YXAgaXMgbmV2ZXIgbG9zdCksIGFuZAog
IC8vIHRoZSBuZXdlc3Qgb2YgdGhlbSBzdGF5cyBoaXMgaW5wdXQgb24gdGhlIGZvbGxvd2luZyBi
ZWF0cyB3aGlsZSBubyBuZXdzIGNvbWVzLCB3aXRob3V0IGl0cwogIC8vIG9uZS1zaG90IGV2ZW50
cyAoYnl0ZSAwKTsgYWZ0ZXIgcmVwZWF0TGltaXQgYmVhdHMgd2l0aG91dCBuZXdzIHRoZSBwbGF5
ZXIgY291bnRzIGFzIGhhdmluZwogIC8vIHJlbGVhc2VkIGV2ZXJ5IGtleS4gR2FtZXMgc2VuZCB0
aGVpciBpbnB1dCBhcyBzb29uIGFzIGl0IGNoYW5nZXMuIEV2ZXJ5IGdhbWUgcnVucyBleGFjdGx5
IHRoZQogIC8vIGZyYW1lcyBpdCByZWNlaXZlcywgaW4gb3JkZXIsIHNvIGFsbCBzdGF5IGluIHN0
ZXAgd2hhdGV2ZXIgdGhlaXIgb3duIGNvbm5lY3Rpb24gZG9lczogYSBkaXN0YW50CiAgLy8gcGxh
eWVyJ3Mga2V5cyB0YWtlIGVmZmVjdCBhIGxpdHRsZSBsYXRlciBhbmQgaGUgc2VlcyB0aGUgZ2Ft
ZSBhIGxpdHRsZSBsYXRlciwgYnV0IG5vYm9keSB3YWl0cwogIC8vIGZvciBoaW0uIEEgZ2FtZSB0
aGF0IGNhbm5vdCBrZWVwIHVwIHdpdGggdGhlIGZyYW1lcyBpcyBkcm9wcGVkLCBhbmQgdGhlIG90
aGVycyBnbyBvbi4KICAvLwogIC8vIEJpbmFyeSBtZXNzYWdlcywgYm90aCB3YXlzOiBraW5kICgx
IGJ5dGUpLCBwYXlsb2FkIGxlbmd0aCAoMiBieXRlcywgbGl0dGxlIGVuZGlhbiksIHBheWxvYWQu
CiAgLy8gQSBXZWJTb2NrZXQgbWVzc2FnZSBtYXkgY2Fycnkgc2V2ZXJhbC4gR2FtZSB0byByZWxh
eToKICAvLyAgIEhFTExPICAgMHgwMSAgcHJvZmlsZSBsZW5ndGggKDEpLCBwcm9maWxlLCBpbmZv
IChuYW1lczsgYXQgbW9zdCA2NCBieXRlcykKICAvLyAgIFNUQVJUICAgMHgwMiAgc2V0dXAgKGF0
IG1vc3QgOCBLaUIpOiB0aGUgaG9zdCwgb25jZSB0d28gcGxheWVycyBvciBtb3JlIHNhaWQgaGVs
bG8KICAvLyAgIElOUFVUICAgMHgwMyAgaW5wdXQgKGF0IG1vc3QgMTYgYnl0ZXM7IGJ5dGUgMCBo
b2xkcyBvbmUtc2hvdCBldmVudHMpLCBhZnRlciBTVEFSVEVECiAgLy8gICBSRUFEWSAgIDB4MDQg
IGVtcHR5OiBTVEFSVEVEIGlzIGFwcGxpZWQKICAvLyAgIENIRUNLICAgMHgwNSAgZnJhbWUgKDQp
LCBoYXNoICgyKTogcGFzc2VkIG9uIHRvIHRoZSBvdGhlcnMsIHdoaWNoIGNvbXBhcmUgaXQgd2l0
aCB0aGVpciBvd24KICAvLyBSZWxheSB0byBnYW1lOgogIC8vICAgV0VMQ09NRSAweDgxICBpZCAo
MSksIGZsYWdzICgxOyBiaXQgMDogaG9zdCksIG1vc3QgcGxheWVycyAoMSksIGJlYXQgaW4gbXMg
KDEpLAogIC8vICAgICAgICAgICAgICAgICByb29tIGNvZGUgbGVuZ3RoICgxKSwgcm9vbSBjb2Rl
CiAgLy8gICBMT0JCWSAgIDB4ODIgIGNvdW50ICgxKTsgcGVyIHBsYXllcjogaWQgKDEpLCBmbGFn
cyAoMSksIGluZm8gbGVuZ3RoICgxKSwgaW5mbwogIC8vICAgU1RBUlRFRCAweDgzICB0aGUgcGxh
eWVycyBhcyBpbiBMT0JCWSwgdGhlbiBzZXR1cCBsZW5ndGggKDIpLCBzZXR1cAogIC8vICAgRlJB
TUUgICAweDg0ICBmcmFtZSAoNCksIGNvdW50ICgxKSwgZnJlc2ggbWFzayAoMSksIHByZXNlbnQg
bWFzayAoMSk7CiAgLy8gICAgICAgICAgICAgICAgIHBlciBwbGF5ZXI6IGlucHV0IGxlbmd0aCAo
MSksIGlucHV0CiAgLy8gICBDSEVDS0VEIDB4ODUgIGluZGV4ICgxKSwgZnJhbWUgKDQpLCBoYXNo
ICgyKQogIC8vICAgTEVGVCAgICAweDg2ICBpbmRleCAoMSk6IHRoYXQgcGxheWVyIGlzIGdvbmU7
IGhpcyBpbnB1dCBzdGF5cyBlbXB0eQogIC8vIFRleHQgKEpTT04pIG1lc3NhZ2VzIGFyZSBmb3Ig
dGhlIHBhZ2UgYXJvdW5kIHRoZSBnYW1lOiB7InQiOiJ3ZWxjb21lIiwidiI6Miwicm9vbSI6IuKA
piIsImhvc3QiOnRydWUsCiAgLy8gImlkIjoyLCJkaXJlY3QiOnvigKZ9fSBhbmQgeyJ0Ijoicm9v
bSIsInBsYXllcnMiOjMsInN0YXJ0ZWQiOmZhbHNlfS4KICAvLwogIC8vIERpcmVjdCBjb25uZWN0
aW9ucyAoZGlzdC93ZWIvb25saW5lLmpzKTogdGhlIHBhZ2VzIG9mIGEgcm9vbSBtYXkgY29ubmVj
dCB0byB0aGUgaG9zdCdzIHBhZ2UKICAvLyBkaXJlY3RseSAoV2ViUlRDKSwgdGhlIHJlbGF5IHBh
c3Npbmcgb24gd2hhdCB0aGV5IHNheSB0byBzZXQgaXQgdXAsIGFuZCB0aGUgaG9zdCdzIHBhZ2Ug
bWF5IGtlZXAKICAvLyB0aGUgYmVhdCBpdHNlbGYg4oCUIG9uIGEgTEFOLCBvciB3aGVyZXZlciBl
dmVyeSBwbGF5ZXIgcmVhY2hlcyB0aGUgaG9zdCBzb29uZXIgdGhhbiB0aGUgcmVsYXkuIFBhZ2UK
ICAvLyB0byByZWxheSwgdGV4dDogeyJ0Ijoic2lnbmFsIiwidG8iOiJob3N0Inw8aWQ+LCJkYXRh
Ijp74oCmfX0gKHBhc3NlZCBvbiBhcyB7InQiOiJzaWduYWwiLCJmcm9tIjo8aWQ+LAogIC8vICJk
YXRhIjp74oCmfX0sIGJldHdlZW4gdGhlIGhvc3QgYW5kIGFub3RoZXIgcGxheWVyIG9ubHkpLCB7
InQiOiJwaW5nIiwibiI6PG51bWJlcj59IChhbnN3ZXJlZCB3aXRoCiAgLy8geyJ0IjoicG9uZyIs
Im4iOuKApn0pLCBhbmQgZnJvbSB0aGUgaG9zdCBiZWZvcmUgU1RBUlQgeyJ0IjoiYmVhdCIsImJ5
IjoiaG9zdCJ8InJlbGF5In0uIFdoZW4gdGhlCiAgLy8gaG9zdCBrZWVwcyB0aGUgYmVhdCwgU1RB
UlQgaXMgZm9sbG93ZWQgYnkgeyJ0IjoiYmVhdCIsImJ5IjoiaG9zdCIsImhvc3QiOjxpZD59IHRv
IGV2ZXJ5IHBhZ2UgYmVmb3JlCiAgLy8gU1RBUlRFRDsgdGhlIHJlbGF5IHRoZW4gc2VuZHMgbm8g
ZnJhbWVzLCB0YWtlcyBubyBJTlBVVCwgUkVBRFkgb3IgQ0hFQ0ssIHRlbGxzIHRoZSBob3N0J3Mg
cGFnZQogIC8vIHsidCI6ImxlZnQiLCJpZCI6PGlkPn0gd2hlbiBhIHBsYXllcidzIGNvbm5lY3Rp
b24gdG8gaXQgY2xvc2VzICh0aGUgaG9zdCdzIHBhZ2Ugc2VuZHMgTEVGVCBhbW9uZyBpdHMKICAv
LyBmcmFtZXMpLCBhbmQgZW5kcyB0aGUgcm9vbSB3aGVuIHRoZSBob3N0IGxlYXZlcy4KCiAgZnVu
Y3Rpb24gam9pbkdyb3VwKHdzLCByb2xlLCBjb2RlKSB7CiAgICBpZiAocm9vbXMuaGFzKGNvZGUp
KSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5jb2RlSW5Vc2UpOwogICAgbGV0IHJvb20gPSBn
cm91cHMuZ2V0KGNvZGUpOwogICAgaWYgKCFyb29tKSB7CiAgICAgIGlmIChjb25maWcubWF4Um9v
bXMgJiYgcm9vbXMuc2l6ZSArIGdyb3Vwcy5zaXplID49IGNvbmZpZy5tYXhSb29tcykgcmV0dXJu
IGNsb3NlV2l0aCh3cywgQ0xPU0Uuc2VydmVyRnVsbCk7CiAgICAgIHJvb20gPSB7CiAgICAgICAg
Y29kZSwgbWVtYmVyczogW10sIGhvc3Q6IG51bGwsIG5leHRJZDogMSwgcHJvZmlsZTogbnVsbCwg
c3RhcnRlZDogZmFsc2UsIG9yZGVyOiBbXSwgZnJhbWU6IDAsCiAgICAgICAgdGlja2luZzogZmFs
c2UsIHRpY2tzOiAwLCB0aWNrU3RhcnQ6IDAsIGxvYmJ5VGltZXI6IG51bGwsIGdyYWNlVGltZXI6
IG51bGwsIHRpY2tUaW1lcjogbnVsbCwgZW5kZWQ6IGZhbHNlLAogICAgICAgIGJlYXRCeTogJ3Jl
bGF5JywgLy8gb3IgJ2hvc3QnOiB0aGUgaG9zdCdzIHBhZ2Uga2VlcHMgdGhlIGJlYXQgKGRpcmVj
dCBjb25uZWN0aW9ucykKICAgICAgfTsKICAgICAgZ3JvdXBzLnNldChjb2RlLCByb29tKTsKICAg
ICAgcm9vbS5sb2JieVRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBlbmRHcm91cChyb29tLCBDTE9T
RS5ub3RTdGFydGVkKSwgY29uZmlnLmxvYmJ5V2FpdE1zKTsKICAgICAgbG9nKGByb29tICR7Y29k
ZX06IG9wZW5lZGApOwogICAgfQogICAgaWYgKHJvb20uc3RhcnRlZCkgcmV0dXJuIGNsb3NlV2l0
aCh3cywgQ0xPU0Uuc3RhcnRlZCk7CiAgICBpZiAocm9sZSA9PT0gJ2hvc3QnICYmIHJvb20uaG9z
dCkgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuaG9zdFRha2VuKTsKICAgIGlmIChyb29tLm1l
bWJlcnMubGVuZ3RoID49IGNvbmZpZy5yb29tUGxheWVycykgcmV0dXJuIGNsb3NlV2l0aCh3cywg
Q0xPU0Uucm9vbUZ1bGwpOwogICAgd2hpbGUgKHJvb20ubWVtYmVycy5zb21lKChvdGhlcikgPT4g
b3RoZXIuaWQgPT09IHJvb20ubmV4dElkKSkgcm9vbS5uZXh0SWQgPSAocm9vbS5uZXh0SWQgJSAy
NTUpICsgMTsKICAgIGNvbnN0IG1lbWJlciA9IHsKICAgICAgd3MsIHJvb20sIGlkOiByb29tLm5l
eHRJZCwgaG9zdDogcm9sZSA9PT0gJ2hvc3QnLCBpbmZvOiBudWxsLCByZWFkeTogZmFsc2UsCiAg
ICAgIHF1ZXVlOiBbXSwgbGFzdDogRU1QVFksIHJlcGVhdHM6IDAsIHByZXNlbnQ6IHRydWUsIGlu
ZGV4OiAtMSwKICAgIH07CiAgICByb29tLm5leHRJZCA9IChyb29tLm5leHRJZCAlIDI1NSkgKyAx
OwogICAgcm9vbS5tZW1iZXJzLnB1c2gobWVtYmVyKTsKICAgIGlmIChtZW1iZXIuaG9zdCkgcm9v
bS5ob3N0ID0gbWVtYmVyOwogICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSwgaXNCaW5hcnkpID0+
IG9uR3JvdXBNZXNzYWdlKG1lbWJlciwgZGF0YSwgaXNCaW5hcnkpKTsKICAgIHdzLm9uKCdjbG9z
ZScsICgpID0+IGxlYXZlR3JvdXAobWVtYmVyKSk7CiAgICAvLyAoYGRpcmVjdGA6IHRoaXMgcmVs
YXkgcGFzc2VzIG9uIGRpcmVjdCBjb25uZWN0aW9uIHNldC11cHMsIGFuZCB0aGUgaG9zdCdzIHBh
Z2Uga2VlcHMgdGhlIGJlYXQgYnkKICAgIC8vIHRoZXNlIHJ1bGVzIHdoZW4gaXQgdGFrZXMgaXQg
b3Zlci4pCiAgICBzZW5kQ29udHJvbCh3cywgewogICAgICB0OiAnd2VsY29tZScsIHY6IDIsIHJv
b206IGNvZGUsIGhvc3Q6IG1lbWJlci5ob3N0LCBpZDogbWVtYmVyLmlkLAogICAgICBkaXJlY3Q6
IHsgcmVwZWF0OiBjb25maWcucmVwZWF0TGltaXQsIGdyYWNlOiBjb25maWcuc3RhcnRHcmFjZU1z
LCBidWZmZXJlZDogY29uZmlnLm1heEJ1ZmZlcmVkQnl0ZXMgfSwKICAgIH0pOwogICAgY29uc3Qg
d2VsY29tZSA9IEJ1ZmZlci5hbGxvYyg1ICsgY29kZS5sZW5ndGgpOwogICAgd2VsY29tZVswXSA9
IG1lbWJlci5pZDsKICAgIC8vIEZsYWdzOiBiaXQgMCB0aGUgaG9zdDsgYml0cyAxLTIgdGhlIGJl
YXQncyB0aGlyZHMgb2YgYSBtaWxsaXNlY29uZCBiZXlvbmQgd2VsY29tZVszXS4KICAgIGNvbnN0
IHRoaXJkcyA9IE1hdGgucm91bmQoY29uZmlnLnRpY2tNcyAqIDMpOwogICAgd2VsY29tZVsxXSA9
IChtZW1iZXIuaG9zdCA/IDEgOiAwKSB8ICgodGhpcmRzICUgMykgPDwgMSk7CiAgICB3ZWxjb21l
WzJdID0gY29uZmlnLnJvb21QbGF5ZXJzOwogICAgd2VsY29tZVszXSA9IE1hdGgubWluKDI1NSwg
TWF0aC5mbG9vcih0aGlyZHMgLyAzKSk7CiAgICB3ZWxjb21lWzRdID0gY29kZS5sZW5ndGg7CiAg
ICB3ZWxjb21lLndyaXRlKGNvZGUsIDUsICdsYXRpbjEnKTsKICAgIHNlbmRCaW5hcnkod3MsIHBh
Y2tldChLSU5ELndlbGNvbWUsIHdlbGNvbWUpKTsKICAgIHNlbmRMb2JieShyb29tLCBtZW1iZXIp
OwogICAgbG9nKGByb29tICR7Y29kZX06ICR7cm9sZX0gYXJyaXZlZCAoJHtyb29tLm1lbWJlcnMu
bGVuZ3RofSBpbiB0aGUgcm9vbSlgKTsKICB9CgogIC8vIFRoZSBwbGF5ZXJzIHdobyBzYWlkIGhl
bGxvLCB0aGUgaG9zdCBmaXJzdCwgdGhlbiBpbiB0aGUgb3JkZXIgdGhleSBjYW1lLgogIGZ1bmN0
aW9uIGxpc3RlZChyb29tKSB7CiAgICBjb25zdCBrbm93biA9IHJvb20ubWVtYmVycy5maWx0ZXIo
KG1lbWJlcikgPT4gbWVtYmVyLmluZm8pOwogICAgcmV0dXJuIGtub3duLmZpbHRlcigobWVtYmVy
KSA9PiBtZW1iZXIuaG9zdCkuY29uY2F0KGtub3duLmZpbHRlcigobWVtYmVyKSA9PiAhbWVtYmVy
Lmhvc3QpKTsKICB9CgogIGZ1bmN0aW9uIGRlc2NyaWJlUGxheWVycyhsaXN0KSB7CiAgICBjb25z
dCBwYXJ0cyA9IFtCdWZmZXIuZnJvbShbbGlzdC5sZW5ndGhdKV07CiAgICBmb3IgKGNvbnN0IG1l
bWJlciBvZiBsaXN0KSBwYXJ0cy5wdXNoKEJ1ZmZlci5mcm9tKFttZW1iZXIuaWQsIG1lbWJlci5o
b3N0ID8gMSA6IDAsIG1lbWJlci5pbmZvLmxlbmd0aF0pLCBtZW1iZXIuaW5mbyk7CiAgICByZXR1
cm4gQnVmZmVyLmNvbmNhdChwYXJ0cyk7CiAgfQoKICBmdW5jdGlvbiBzZW5kTG9iYnkocm9vbSwg
b25seSkgewogICAgY29uc3QgbGlzdCA9IGxpc3RlZChyb29tKTsKICAgIGNvbnN0IG1lc3NhZ2Ug
PSBwYWNrZXQoS0lORC5sb2JieSwgZGVzY3JpYmVQbGF5ZXJzKGxpc3QpKTsKICAgIGZvciAoY29u
c3QgbWVtYmVyIG9mIG9ubHkgPyBbb25seV0gOiByb29tLm1lbWJlcnMpIHsKICAgICAgc2VuZEJp
bmFyeShtZW1iZXIud3MsIG1lc3NhZ2UpOwogICAgICBzZW5kQ29udHJvbChtZW1iZXIud3MsIHsg
dDogJ3Jvb20nLCBwbGF5ZXJzOiBsaXN0Lmxlbmd0aCwgc3RhcnRlZDogZmFsc2UgfSk7CiAgICB9
CiAgfQoKICBmdW5jdGlvbiBvbkdyb3VwTWVzc2FnZShtZW1iZXIsIGRhdGEsIGlzQmluYXJ5KSB7
CiAgICBjb25zdCB7IHdzLCByb29tIH0gPSBtZW1iZXI7CiAgICBpZiAocm9vbS5lbmRlZCB8fCAh
cm9vbS5tZW1iZXJzLmluY2x1ZGVzKG1lbWJlcikpIHJldHVybjsKICAgIGlmICghd3MubWVzc2Fn
ZUJ1ZGdldC50YWtlKDEpIHx8ICF3cy5ieXRlQnVkZ2V0LnRha2UoZGF0YS5sZW5ndGgpKSB7CiAg
ICAgIGxvZyhgcm9vbSAke3Jvb20uY29kZX06IHJhdGUgbGltaXRgKTsKICAgICAgcmV0dXJuIGNs
b3NlV2l0aCh3cywgQ0xPU0UucmF0ZUxpbWl0ZWQpOwogICAgfQogICAgaWYgKCFpc0JpbmFyeSkg
cmV0dXJuIGhhbmRsZUdyb3VwVGV4dChtZW1iZXIsIGRhdGEpOwogICAgbGV0IGF0ID0gMDsKICAg
IHdoaWxlIChhdCA8IGRhdGEubGVuZ3RoKSB7CiAgICAgIGlmIChkYXRhLmxlbmd0aCAtIGF0IDwg
MykgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UucHJvdG9jb2wpOwogICAgICBjb25zdCBraW5k
ID0gZGF0YVthdF07CiAgICAgIGNvbnN0IGxlbmd0aCA9IGRhdGEucmVhZFVJbnQxNkxFKGF0ICsg
MSk7CiAgICAgIGlmIChkYXRhLmxlbmd0aCAtIGF0IC0gMyA8IGxlbmd0aCkgcmV0dXJuIGNsb3Nl
V2l0aCh3cywgQ0xPU0UucHJvdG9jb2wpOwogICAgICBjb25zdCBwcm9ibGVtID0gaGFuZGxlR3Jv
dXBNZXNzYWdlKG1lbWJlciwga2luZCwgZGF0YS5zdWJhcnJheShhdCArIDMsIGF0ICsgMyArIGxl
bmd0aCkpOwogICAgICBpZiAocHJvYmxlbSkgcmV0dXJuIGNsb3NlV2l0aCh3cywgcHJvYmxlbSk7
CiAgICAgIGlmIChyb29tLmVuZGVkIHx8ICFyb29tLm1lbWJlcnMuaW5jbHVkZXMobWVtYmVyKSkg
cmV0dXJuOwogICAgICBhdCArPSAzICsgbGVuZ3RoOwogICAgfQogIH0KCiAgLy8gQSBwYWdlJ3Mg
dGV4dCBtZXNzYWdlIChkaXJlY3QgY29ubmVjdGlvbnMsIHNlZSBhYm92ZSk7IGFueXRoaW5nIGVs
c2UgaXMgaWdub3JlZC4KICBmdW5jdGlvbiBoYW5kbGVHcm91cFRleHQobWVtYmVyLCBkYXRhKSB7
CiAgICBjb25zdCByb29tID0gbWVtYmVyLnJvb207CiAgICBpZiAoZGF0YS5sZW5ndGggPiBTSUdO
QUxfTElNSVQpIHJldHVybiBudWxsOwogICAgbGV0IG1lc3NhZ2U7CiAgICB0cnkgeyBtZXNzYWdl
ID0gSlNPTi5wYXJzZShkYXRhLnRvU3RyaW5nKCd1dGY4JykpOyB9IGNhdGNoIChlcnJvcikgeyBy
ZXR1cm4gbnVsbDsgfQogICAgaWYgKCFtZXNzYWdlIHx8IHR5cGVvZiBtZXNzYWdlICE9PSAnb2Jq
ZWN0JykgcmV0dXJuIG51bGw7CiAgICBpZiAobWVzc2FnZS50ID09PSAncGluZycpIHsKICAgICAg
aWYgKE51bWJlci5pc0Zpbml0ZShtZXNzYWdlLm4pKSBzZW5kQ29udHJvbChtZW1iZXIud3MsIHsg
dDogJ3BvbmcnLCBuOiBtZXNzYWdlLm4gfSk7CiAgICB9IGVsc2UgaWYgKG1lc3NhZ2UudCA9PT0g
J3NpZ25hbCcpIHsKICAgICAgaWYgKCFtZXNzYWdlLmRhdGEgfHwgdHlwZW9mIG1lc3NhZ2UuZGF0
YSAhPT0gJ29iamVjdCcpIHJldHVybiBudWxsOwogICAgICAvLyBCZXR3ZWVuIHRoZSBob3N0IGFu
ZCBhbm90aGVyIHBsYXllciBvbmx5LgogICAgICBjb25zdCB0YXJnZXQgPSBtZXNzYWdlLnRvID09
PSAnaG9zdCcgPyByb29tLmhvc3QgOiByb29tLm1lbWJlcnMuZmluZCgob3RoZXIpID0+IG90aGVy
LmlkID09PSBtZXNzYWdlLnRvKTsKICAgICAgaWYgKCF0YXJnZXQgfHwgdGFyZ2V0ID09PSBtZW1i
ZXIgfHwgKCFtZW1iZXIuaG9zdCAmJiAhdGFyZ2V0Lmhvc3QpKSByZXR1cm4gbnVsbDsKICAgICAg
c2VuZENvbnRyb2wodGFyZ2V0LndzLCB7IHQ6ICdzaWduYWwnLCBmcm9tOiBtZW1iZXIuaWQsIGRh
dGE6IG1lc3NhZ2UuZGF0YSB9KTsKICAgIH0gZWxzZSBpZiAobWVzc2FnZS50ID09PSAnYmVhdCcp
IHsKICAgICAgaWYgKG1lbWJlci5ob3N0ICYmICFyb29tLnN0YXJ0ZWQpIHJvb20uYmVhdEJ5ID0g
bWVzc2FnZS5ieSA9PT0gJ2hvc3QnID8gJ2hvc3QnIDogJ3JlbGF5JzsKICAgIH0KICAgIHJldHVy
biBudWxsOwogIH0KCiAgLy8gUmV0dXJucyB0aGUgY2xvc2UgY29kZSBhbmQgcmVhc29uIGZvciBh
IG1lc3NhZ2UgdGhlIGdhbWUgc2hvdWxkIG5vdCBoYXZlIHNlbnQuCiAgZnVuY3Rpb24gaGFuZGxl
R3JvdXBNZXNzYWdlKG1lbWJlciwga2luZCwgcGF5bG9hZCkgewogICAgY29uc3Qgcm9vbSA9IG1l
bWJlci5yb29tOwogICAgLy8gVGhlIGhvc3QncyBwYWdlIGtlZXBzIHRoZSBiZWF0OiB0aGUgZ2Ft
ZXMnIElOUFVULCBSRUFEWSBhbmQgQ0hFQ0sgZ28gdG8gaXQsIG5vdCBoZXJlLgogICAgaWYgKHJv
b20uc3RhcnRlZCAmJiByb29tLmJlYXRCeSA9PT0gJ2hvc3QnICYmIChraW5kID09PSBLSU5ELmlu
cHV0IHx8IGtpbmQgPT09IEtJTkQucmVhZHkgfHwga2luZCA9PT0gS0lORC5jaGVjaykpIHJldHVy
biBudWxsOwogICAgaWYgKGtpbmQgPT09IEtJTkQuaGVsbG8pIHsKICAgICAgaWYgKG1lbWJlci5p
bmZvIHx8IHJvb20uc3RhcnRlZCB8fCBwYXlsb2FkLmxlbmd0aCA8IDEpIHJldHVybiBDTE9TRS5w
cm90b2NvbDsKICAgICAgY29uc3QgbGVuZ3RoID0gcGF5bG9hZFswXTsKICAgICAgaWYgKCFsZW5n
dGggfHwgbGVuZ3RoID4gUk9PTV9MSU1JVFMucHJvZmlsZSB8fCBwYXlsb2FkLmxlbmd0aCA8IDEg
KyBsZW5ndGgpIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAgY29uc3QgcHJvZmlsZSA9IEJ1
ZmZlci5mcm9tKHBheWxvYWQuc3ViYXJyYXkoMSwgMSArIGxlbmd0aCkpOwogICAgICBjb25zdCBp
bmZvID0gQnVmZmVyLmZyb20ocGF5bG9hZC5zdWJhcnJheSgxICsgbGVuZ3RoKSk7CiAgICAgIGlm
IChpbmZvLmxlbmd0aCA+IFJPT01fTElNSVRTLmluZm8pIHJldHVybiBDTE9TRS5wcm90b2NvbDsK
ICAgICAgaWYgKHJvb20ucHJvZmlsZSAmJiAhcm9vbS5wcm9maWxlLmVxdWFscyhwcm9maWxlKSkg
cmV0dXJuIENMT1NFLm1pc21hdGNoOwogICAgICByb29tLnByb2ZpbGUgPSByb29tLnByb2ZpbGUg
fHwgcHJvZmlsZTsKICAgICAgbWVtYmVyLmluZm8gPSBpbmZvOwogICAgICBzZW5kTG9iYnkocm9v
bSk7CiAgICAgIHJldHVybiBudWxsOwogICAgfQogICAgaWYgKGtpbmQgPT09IEtJTkQuc3RhcnQp
IHsKICAgICAgaWYgKCFtZW1iZXIuaG9zdCB8fCAhbWVtYmVyLmluZm8gfHwgcm9vbS5zdGFydGVk
IHx8IHBheWxvYWQubGVuZ3RoID4gUk9PTV9MSU1JVFMuc2V0dXApIHJldHVybiBDTE9TRS5wcm90
b2NvbDsKICAgICAgLy8gU29tZWJvZHkgbGVmdCBqdXN0IGJlZm9yZTogdGhlIGhvc3Qgc2VlcyB0
aGUgbGlzdCBhZ2FpbiBpbnN0ZWFkLgogICAgICBpZiAobGlzdGVkKHJvb20pLmxlbmd0aCA8IDIp
IHNlbmRMb2JieShyb29tLCBtZW1iZXIpOwogICAgICBlbHNlIHN0YXJ0R3JvdXAocm9vbSwgQnVm
ZmVyLmZyb20ocGF5bG9hZCkpOwogICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAgIGlmIChraW5k
ID09PSBLSU5ELmlucHV0KSB7CiAgICAgIGlmICghcm9vbS5zdGFydGVkIHx8IG1lbWJlci5pbmRl
eCA8IDAgfHwgcGF5bG9hZC5sZW5ndGggPiBST09NX0xJTUlUUy5pbnB1dCkgcmV0dXJuIENMT1NF
LnByb3RvY29sOwogICAgICBtZW1iZXIucXVldWUucHVzaChCdWZmZXIuZnJvbShwYXlsb2FkKSk7
CiAgICAgIC8vIEZhciBtb3JlIHRoYW4gYSBiZWF0J3Mgd29ydGggKHRoZSByYXRlIGxpbWl0IGFs
bG93cyBidXJzdHMpOiBmb2xkIHRoZW0sIGtlZXBpbmcgdGhlIG5ld2VzdCBsYXN0LgogICAgICBp
ZiAobWVtYmVyLnF1ZXVlLmxlbmd0aCA+IFJPT01fTElNSVRTLnF1ZXVlKSBtZW1iZXIucXVldWUg
PSBbbWVyZ2VJbnB1dHMobWVtYmVyLnF1ZXVlLnNsaWNlKDAsIC0xKSksIG1lbWJlci5xdWV1ZS5h
dCgtMSldOwogICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAgIGlmIChraW5kID09PSBLSU5ELnJl
YWR5KSB7CiAgICAgIGlmICghcm9vbS5zdGFydGVkIHx8IG1lbWJlci5pbmRleCA8IDAgfHwgcGF5
bG9hZC5sZW5ndGgpIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAgbWVtYmVyLnJlYWR5ID0g
dHJ1ZTsKICAgICAgaWYgKHJvb20ub3JkZXIuZXZlcnkoKG90aGVyKSA9PiBvdGhlci5yZWFkeSB8
fCAhb3RoZXIucHJlc2VudCkpIHN0YXJ0QmVhdChyb29tKTsKICAgICAgcmV0dXJuIG51bGw7CiAg
ICB9CiAgICBpZiAoa2luZCA9PT0gS0lORC5jaGVjaykgewogICAgICBpZiAoIXJvb20uc3RhcnRl
ZCB8fCBtZW1iZXIuaW5kZXggPCAwIHx8IHBheWxvYWQubGVuZ3RoICE9PSA2KSByZXR1cm4gQ0xP
U0UucHJvdG9jb2w7CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lORC5jaGVja2VkLCBC
dWZmZXIuY29uY2F0KFtCdWZmZXIuZnJvbShbbWVtYmVyLmluZGV4XSksIHBheWxvYWRdKSk7CiAg
ICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5vcmRlcikgaWYgKG90aGVyICE9PSBtZW1iZXIg
JiYgb3RoZXIucHJlc2VudCkgc2VuZEJpbmFyeShvdGhlci53cywgbWVzc2FnZSk7CiAgICAgIHJl
dHVybiBudWxsOwogICAgfQogICAgcmV0dXJuIENMT1NFLnByb3RvY29sOwogIH0KCiAgZnVuY3Rp
b24gc3RhcnRHcm91cChyb29tLCBzZXR1cCkgewogICAgY2xlYXJUaW1lb3V0KHJvb20ubG9iYnlU
aW1lcik7CiAgICByb29tLnN0YXJ0ZWQgPSB0cnVlOwogICAgcm9vbS5vcmRlciA9IGxpc3RlZChy
b29tKTsKICAgIHJvb20ub3JkZXIuZm9yRWFjaCgobWVtYmVyLCBpbmRleCkgPT4geyBtZW1iZXIu
aW5kZXggPSBpbmRleDsgfSk7CiAgICAvLyBBIGdhbWUgc3RpbGwgY29ubmVjdGluZyBoYXMgbWlz
c2VkIHRoZSBzdGFydC4KICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ubWVtYmVycykgaWYg
KCFtZW1iZXIuaW5mbykgY2xvc2VXaXRoKG1lbWJlci53cywgQ0xPU0Uuc3RhcnRlZCk7CiAgICBj
b25zdCBsZW5ndGggPSBCdWZmZXIuYWxsb2MoMik7CiAgICBsZW5ndGgud3JpdGVVSW50MTZMRShz
ZXR1cC5sZW5ndGgsIDApOwogICAgY29uc3QgbWVzc2FnZSA9IHBhY2tldChLSU5ELnN0YXJ0ZWQs
IEJ1ZmZlci5jb25jYXQoW2Rlc2NyaWJlUGxheWVycyhyb29tLm9yZGVyKSwgbGVuZ3RoLCBzZXR1
cF0pKTsKICAgIGNvbnN0IGhvc3RCZWF0ID0gcm9vbS5iZWF0QnkgPT09ICdob3N0JyAmJiByb29t
Lmhvc3QgJiYgcm9vbS5ob3N0LmluZGV4ID49IDA7CiAgICBpZiAoIWhvc3RCZWF0KSByb29tLmJl
YXRCeSA9ICdyZWxheSc7CiAgICBmb3IgKGNvbnN0IG1lbWJlciBvZiByb29tLm9yZGVyKSB7CiAg
ICAgIC8vIChCZWZvcmUgU1RBUlRFRCwgc28gdGhhdCB0aGUgcGFnZSBzZW5kcyB0aGUgZ2FtZSdz
IFJFQURZIGFuZCBpbnB1dCB0aGUgcmlnaHQgd2F5LikKICAgICAgaWYgKGhvc3RCZWF0KSBzZW5k
Q29udHJvbChtZW1iZXIud3MsIHsgdDogJ2JlYXQnLCBieTogJ2hvc3QnLCBob3N0OiByb29tLmhv
c3QuaWQgfSk7CiAgICAgIHNlbmRCaW5hcnkobWVtYmVyLndzLCBtZXNzYWdlKTsKICAgICAgc2Vu
ZENvbnRyb2wobWVtYmVyLndzLCB7IHQ6ICdyb29tJywgcGxheWVyczogcm9vbS5vcmRlci5sZW5n
dGgsIHN0YXJ0ZWQ6IHRydWUgfSk7CiAgICB9CiAgICBpZiAoIWhvc3RCZWF0KSByb29tLmdyYWNl
VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHN0YXJ0QmVhdChyb29tKSwgY29uZmlnLnN0YXJ0R3Jh
Y2VNcyk7CiAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBzdGFydGVkIHdpdGggJHtyb29tLm9y
ZGVyLmxlbmd0aH0gcGxheWVycyR7aG9zdEJlYXQgPyAnLCB0aGUgYmVhdCBrZXB0IGJ5IHRoZSBo
b3N0JyA6ICcnfWApOwogIH0KCiAgZnVuY3Rpb24gc3RhcnRCZWF0KHJvb20pIHsKICAgIGlmIChy
b29tLnRpY2tpbmcgfHwgcm9vbS5lbmRlZCkgcmV0dXJuOwogICAgY2xlYXJUaW1lb3V0KHJvb20u
Z3JhY2VUaW1lcik7CiAgICByb29tLnRpY2tpbmcgPSB0cnVlOwogICAgcm9vbS50aWNrU3RhcnQg
PSBwZXJmb3JtYW5jZS5ub3coKTsKICAgIHJvb20udGlja3MgPSAwOwogICAgc2NoZWR1bGVCZWF0
KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gc2NoZWR1bGVCZWF0KHJvb20pIHsKICAgIGNvbnN0IGR1
ZSA9IHJvb20udGlja1N0YXJ0ICsgKHJvb20udGlja3MgKyAxKSAqIGNvbmZpZy50aWNrTXM7CiAg
ICByb29tLnRpY2tUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gcnVuQmVhdHMocm9vbSksIE1hdGgu
bWF4KDAsIGR1ZSAtIHBlcmZvcm1hbmNlLm5vdygpKSk7CiAgfQoKICAvLyBCZWF0cyBhcmUgY291
bnRlZCBmcm9tIHRoZSBzdGFydCwgc28gdGltZXIgZGVsYXlzIGRvIG5vdCBhZGQgdXA7IGFmdGVy
IGEgc3RhbGwgb2YgdGhlIHdob2xlCiAgLy8gcHJvY2VzcyBhIGZldyBtaXNzZWQgYmVhdHMgYXJl
IHNlbnQgYXQgb25jZSwgYW5kIGEgbG9uZ2VyIG9uZSByZXN0YXJ0cyB0aGUgY291bnQuCiAgZnVu
Y3Rpb24gcnVuQmVhdHMocm9vbSkgewogICAgaWYgKHJvb20uZW5kZWQpIHJldHVybjsKICAgIGNv
bnN0IG5vdyA9IHBlcmZvcm1hbmNlLm5vdygpOwogICAgY29uc3QgZHVlID0gTWF0aC5mbG9vcigo
bm93IC0gcm9vbS50aWNrU3RhcnQpIC8gY29uZmlnLnRpY2tNcykgLSByb29tLnRpY2tzOwogICAg
Zm9yIChsZXQgY291bnQgPSAwOyBjb3VudCA8IE1hdGgubWluKGR1ZSwgNCkgJiYgIXJvb20uZW5k
ZWQ7IGNvdW50ICs9IDEpIHsKICAgICAgcm9vbS50aWNrcyArPSAxOwogICAgICBiZWF0KHJvb20p
OwogICAgfQogICAgaWYgKHJvb20uZW5kZWQpIHJldHVybjsKICAgIGlmIChkdWUgPiA0KSByb29t
LnRpY2tTdGFydCA9IG5vdyAtIHJvb20udGlja3MgKiBjb25maWcudGlja01zOwogICAgc2NoZWR1
bGVCZWF0KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gYmVhdChyb29tKSB7CiAgICBsZXQgZnJlc2gg
PSAwOwogICAgbGV0IHByZXNlbnQgPSAwOwogICAgY29uc3QgcGFydHMgPSBbXTsKICAgIGZvciAo
Y29uc3QgbWVtYmVyIG9mIHJvb20ub3JkZXIpIHsKICAgICAgbGV0IGlucHV0ID0gRU1QVFk7CiAg
ICAgIGlmIChtZW1iZXIucHJlc2VudCkgewogICAgICAgIHByZXNlbnQgfD0gMSA8PCBtZW1iZXIu
aW5kZXg7CiAgICAgICAgY29uc3Qgd2FpdGluZyA9IG1lbWJlci5xdWV1ZS5sZW5ndGg7CiAgICAg
ICAgaWYgKHdhaXRpbmcpIHsKICAgICAgICAgIGZyZXNoIHw9IDEgPDwgbWVtYmVyLmluZGV4Owog
ICAgICAgICAgaW5wdXQgPSB3YWl0aW5nID09PSAxID8gbWVtYmVyLnF1ZXVlWzBdIDogbWVyZ2VJ
bnB1dHMobWVtYmVyLnF1ZXVlKTsKICAgICAgICAgIG1lbWJlci5sYXN0ID0gbWVtYmVyLnF1ZXVl
W3dhaXRpbmcgLSAxXTsKICAgICAgICAgIG1lbWJlci5xdWV1ZSA9IFtdOwogICAgICAgICAgbWVt
YmVyLnJlcGVhdHMgPSAwOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBtZW1iZXIucmVwZWF0
cyArPSAxOwogICAgICAgICAgaW5wdXQgPSBtZW1iZXIucmVwZWF0cyA+IGNvbmZpZy5yZXBlYXRM
aW1pdCA/IEVNUFRZIDogd2l0aG91dEV2ZW50cyhtZW1iZXIubGFzdCk7CiAgICAgICAgfQogICAg
ICB9CiAgICAgIHBhcnRzLnB1c2goQnVmZmVyLmZyb20oW2lucHV0Lmxlbmd0aF0pLCBpbnB1dCk7
CiAgICB9CiAgICBjb25zdCBoZWFkZXIgPSBCdWZmZXIuYWxsb2MoNyk7CiAgICBoZWFkZXIud3Jp
dGVVSW50MzJMRShyb29tLmZyYW1lICUgNDI5NDk2NzI5NiwgMCk7CiAgICBoZWFkZXJbNF0gPSBy
b29tLm9yZGVyLmxlbmd0aDsKICAgIGhlYWRlcls1XSA9IGZyZXNoOwogICAgaGVhZGVyWzZdID0g
cHJlc2VudDsKICAgIHJvb20uZnJhbWUgKz0gMTsKICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQo
S0lORC5mcmFtZSwgQnVmZmVyLmNvbmNhdChbaGVhZGVyLCAuLi5wYXJ0c10pKTsKICAgIGZvciAo
Y29uc3QgbWVtYmVyIG9mIHJvb20ub3JkZXIpIHsKICAgICAgaWYgKCFtZW1iZXIucHJlc2VudCkg
Y29udGludWU7CiAgICAgIGlmIChtZW1iZXIud3MuYnVmZmVyZWRBbW91bnQgPiBjb25maWcubWF4
QnVmZmVyZWRCeXRlcykgewogICAgICAgIGNsb3NlV2l0aChtZW1iZXIud3MsIENMT1NFLnNsb3dD
bGllbnQpOwogICAgICAgIGNvbnRpbnVlOwogICAgICB9CiAgICAgIHNlbmRCaW5hcnkobWVtYmVy
LndzLCBtZXNzYWdlKTsKICAgIH0KICB9CgogIGZ1bmN0aW9uIGxlYXZlR3JvdXAobWVtYmVyKSB7
CiAgICBjb25zdCByb29tID0gbWVtYmVyLnJvb207CiAgICBjb25zdCBwb3NpdGlvbiA9IHJvb20u
bWVtYmVycy5pbmRleE9mKG1lbWJlcik7CiAgICBpZiAocG9zaXRpb24gPj0gMCkgcm9vbS5tZW1i
ZXJzLnNwbGljZShwb3NpdGlvbiwgMSk7CiAgICBpZiAocm9vbS5lbmRlZCkgcmV0dXJuOwogICAg
aWYgKCFyb29tLnN0YXJ0ZWQpIHsKICAgICAgaWYgKG1lbWJlci5ob3N0KSB7CiAgICAgICAgcm9v
bS5ob3N0ID0gbnVsbDsKICAgICAgICBlbmRHcm91cChyb29tLCBDTE9TRS5ob3N0TGVmdCk7CiAg
ICAgIH0gZWxzZSBpZiAoIXJvb20ubWVtYmVycy5sZW5ndGgpIHsKICAgICAgICBlbmRHcm91cChy
b29tKTsKICAgICAgfSBlbHNlIGlmIChtZW1iZXIuaW5mbykgewogICAgICAgIHNlbmRMb2JieShy
b29tKTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAocm9vbS5iZWF0QnkgPT09
ICdob3N0JykgewogICAgICAvLyBUaGUgYmVhdCBsZWF2ZXMgd2l0aCB0aGUgaG9zdC4gQW5vdGhl
ciBwbGF5ZXI6IHRoZSBob3N0J3MgcGFnZSBzZW5kcyBMRUZUIGFtb25nIGl0cyBmcmFtZXMuCiAg
ICAgIGlmIChtZW1iZXIuaG9zdCkgcmV0dXJuIGVuZEdyb3VwKHJvb20sIENMT1NFLmhvc3RMZWZ0
KTsKICAgICAgaWYgKG1lbWJlci5pbmRleCA+PSAwICYmIG1lbWJlci5wcmVzZW50KSB7CiAgICAg
ICAgbWVtYmVyLnByZXNlbnQgPSBmYWxzZTsKICAgICAgICBjb25zdCBwbGF5ZXJzID0gcm9vbS5v
cmRlci5maWx0ZXIoKG90aGVyKSA9PiBvdGhlci5wcmVzZW50KS5sZW5ndGg7CiAgICAgICAgaWYg
KHJvb20uaG9zdCkgc2VuZENvbnRyb2wocm9vbS5ob3N0LndzLCB7IHQ6ICdsZWZ0JywgaWQ6IG1l
bWJlci5pZCB9KTsKICAgICAgICBmb3IgKGNvbnN0IG90aGVyIG9mIHJvb20ub3JkZXIpIGlmIChv
dGhlci5wcmVzZW50KSBzZW5kQ29udHJvbChvdGhlci53cywgeyB0OiAncm9vbScsIHBsYXllcnMs
IHN0YXJ0ZWQ6IHRydWUgfSk7CiAgICAgICAgbG9nKGByb29tICR7cm9vbS5jb2RlfTogcGxheWVy
ICR7bWVtYmVyLmluZGV4ICsgMX0gbGVmdGApOwogICAgICB9CiAgICAgIGlmICghcm9vbS5vcmRl
ci5zb21lKChvdGhlcikgPT4gb3RoZXIucHJlc2VudCkpIGVuZEdyb3VwKHJvb20pOwogICAgICBy
ZXR1cm47CiAgICB9CiAgICBpZiAobWVtYmVyLmluZGV4ID49IDAgJiYgbWVtYmVyLnByZXNlbnQp
IHsKICAgICAgbWVtYmVyLnByZXNlbnQgPSBmYWxzZTsKICAgICAgbWVtYmVyLnF1ZXVlID0gW107
CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lORC5sZWZ0LCBCdWZmZXIuZnJvbShbbWVt
YmVyLmluZGV4XSkpOwogICAgICBjb25zdCBwbGF5ZXJzID0gcm9vbS5vcmRlci5maWx0ZXIoKG90
aGVyKSA9PiBvdGhlci5wcmVzZW50KS5sZW5ndGg7CiAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Yg
cm9vbS5vcmRlcikgewogICAgICAgIGlmICghb3RoZXIucHJlc2VudCkgY29udGludWU7CiAgICAg
ICAgc2VuZEJpbmFyeShvdGhlci53cywgbWVzc2FnZSk7CiAgICAgICAgc2VuZENvbnRyb2wob3Ro
ZXIud3MsIHsgdDogJ3Jvb20nLCBwbGF5ZXJzLCBzdGFydGVkOiB0cnVlIH0pOwogICAgICB9CiAg
ICAgIGxvZyhgcm9vbSAke3Jvb20uY29kZX06IHBsYXllciAke21lbWJlci5pbmRleCArIDF9IGxl
ZnRgKTsKICAgIH0KICAgIGlmICghcm9vbS5vcmRlci5zb21lKChvdGhlcikgPT4gb3RoZXIucHJl
c2VudCkpIGVuZEdyb3VwKHJvb20pOwogICAgZWxzZSBpZiAocm9vbS5vcmRlci5ldmVyeSgob3Ro
ZXIpID0+IG90aGVyLnJlYWR5IHx8ICFvdGhlci5wcmVzZW50KSkgc3RhcnRCZWF0KHJvb20pOwog
IH0KCiAgZnVuY3Rpb24gZW5kR3JvdXAocm9vbSwgcmVhc29uKSB7CiAgICBpZiAocm9vbS5lbmRl
ZCkgcmV0dXJuOwogICAgcm9vbS5lbmRlZCA9IHRydWU7CiAgICBjbGVhclRpbWVvdXQocm9vbS5s
b2JieVRpbWVyKTsKICAgIGNsZWFyVGltZW91dChyb29tLmdyYWNlVGltZXIpOwogICAgY2xlYXJU
aW1lb3V0KHJvb20udGlja1RpbWVyKTsKICAgIGlmIChncm91cHMuZ2V0KHJvb20uY29kZSkgPT09
IHJvb20pIGdyb3Vwcy5kZWxldGUocm9vbS5jb2RlKTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9m
IHJvb20ubWVtYmVycy5zbGljZSgpKSBjbG9zZVdpdGgobWVtYmVyLndzLCByZWFzb24gfHwgQ0xP
U0Uuc2h1dGRvd24pOwogICAgbG9nKGByb29tICR7cm9vbS5jb2RlfTogZW5kZWRgKTsKICB9Cgog
IC8vIFNpemUgb2YgdGhlIGluc3RhbGxlciBmaWxlLCBvciAwIHdoZW4gbm9uZSBpcyBjb25maWd1
cmVkIG9yIHJlYWRhYmxlLgogIGZ1bmN0aW9uIGluc3RhbGxlclNpemUoKSB7CiAgICBpZiAoIWNv
bmZpZy5pbnN0YWxsZXJGaWxlKSByZXR1cm4gMDsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHN0YXQg
PSBmcy5zdGF0U3luYyhjb25maWcuaW5zdGFsbGVyRmlsZSk7CiAgICAgIHJldHVybiBzdGF0Lmlz
RmlsZSgpID8gc3RhdC5zaXplIDogMDsKICAgIH0gY2F0Y2ggewogICAgICByZXR1cm4gMDsKICAg
IH0KICB9CgogIGZ1bmN0aW9uIHNlcnZlSW5zdGFsbGVyKHJlcSwgcmVzKSB7CiAgICBjb25zdCBo
ZWFkZXJzID0geyAnY2FjaGUtY29udHJvbCc6ICdwdWJsaWMsIG1heC1hZ2U9ODY0MDAnLCAneC1j
b250ZW50LXR5cGUtb3B0aW9ucyc6ICdub3NuaWZmJywgLi4uYWxsb3dPcmlnaW4ocmVxKSB9Owog
ICAgaWYgKHJlcS5tZXRob2QgIT09ICdHRVQnICYmIHJlcS5tZXRob2QgIT09ICdIRUFEJykgewog
ICAgICByZXMud3JpdGVIZWFkKDQwNSwgeyAuLi5oZWFkZXJzLCBhbGxvdzogJ0dFVCwgSEVBRCcg
fSk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qgc2l6ZSA9
IGluc3RhbGxlclNpemUoKTsKICAgIGlmICghc2l6ZSkgewogICAgICByZXMud3JpdGVIZWFkKDQw
NCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYg
KHJlcS5tZXRob2QgPT09ICdHRVQnICYmIGNvbmZpZy5pbnN0YWxsZXJEb3dubG9hZHNQZXJIb3Vy
KSB7CiAgICAgIGNvbnN0IGFkZHJlc3MgPSBjbGllbnRBZGRyZXNzKHJlcSk7CiAgICAgIGNvbnN0
IG5vdyA9IERhdGUubm93KCk7CiAgICAgIGxldCBlbnRyeSA9IGluc3RhbGxlckRvd25sb2Fkcy5n
ZXQoYWRkcmVzcyk7CiAgICAgIGlmICghZW50cnkgfHwgZW50cnkudW50aWwgPD0gbm93KSB7CiAg
ICAgICAgZW50cnkgPSB7IGNvdW50OiAwLCB1bnRpbDogbm93ICsgMzYwMDAwMCB9OwogICAgICAg
IGluc3RhbGxlckRvd25sb2Fkcy5zZXQoYWRkcmVzcywgZW50cnkpOwogICAgICB9CiAgICAgIGlm
IChlbnRyeS5jb3VudCA+PSBjb25maWcuaW5zdGFsbGVyRG93bmxvYWRzUGVySG91cikgewogICAg
ICAgIHJlcy53cml0ZUhlYWQoNDI5LCB7IC4uLmhlYWRlcnMsICdyZXRyeS1hZnRlcic6IFN0cmlu
ZyhNYXRoLmNlaWwoKGVudHJ5LnVudGlsIC0gbm93KSAvIDEwMDApKSB9KTsKICAgICAgICByZXMu
ZW5kKCk7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGVudHJ5LmNvdW50ICs9IDE7CiAg
ICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBlJzog
J2FwcGxpY2F0aW9uL29jdGV0LXN0cmVhbScsICdjb250ZW50LWxlbmd0aCc6IFN0cmluZyhzaXpl
KSB9KTsKICAgIGlmIChyZXEubWV0aG9kID09PSAnSEVBRCcpIHsKICAgICAgcmVzLmVuZCgpOwog
ICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFkU3RyZWFt
KGNvbmZpZy5pbnN0YWxsZXJGaWxlKTsKICAgIHN0cmVhbS5vbignZXJyb3InLCAoKSA9PiByZXMu
ZGVzdHJveSgpKTsKICAgIHN0cmVhbS5waXBlKHJlcyk7CiAgfQoKICAvLyBDcm9zcy1vcmlnaW46
IHRoZSBnYW1lIHBhZ2UgbGl2ZXMgZWxzZXdoZXJlIChHaXRIdWIgUGFnZXMpLiBXaXRoIGFuIGFs
bG93LWxpc3QsIG9ubHkgaXRzIHBhZ2VzIG1heSByZWFkLgogIGZ1bmN0aW9uIGFsbG93T3JpZ2lu
KHJlcSkgewogICAgaWYgKCFjb25maWcuYWxsb3dlZE9yaWdpbnMubGVuZ3RoKSByZXR1cm4geyAn
YWNjZXNzLWNvbnRyb2wtYWxsb3ctb3JpZ2luJzogJyonIH07CiAgICBjb25zdCBvcmlnaW4gPSBu
b3JtYWxpemVPcmlnaW4ocmVxLmhlYWRlcnMub3JpZ2luKTsKICAgIGlmIChvcmlnaW4gJiYgY29u
ZmlnLmFsbG93ZWRPcmlnaW5zLmluY2x1ZGVzKG9yaWdpbikpIHJldHVybiB7ICdhY2Nlc3MtY29u
dHJvbC1hbGxvdy1vcmlnaW4nOiByZXEuaGVhZGVycy5vcmlnaW4sIHZhcnk6ICdPcmlnaW4nIH07
CiAgICByZXR1cm4ge307CiAgfQoKICBmdW5jdGlvbiBjbGllbnRBZGRyZXNzKHJlcSkgewogICAg
aWYgKGNvbmZpZy50cnVzdFByb3h5KSB7CiAgICAgIC8vIFRoZSBsYXN0IGVudHJ5IGlzIHRoZSBv
bmUgb3VyIG93biBwcm94eSBhZGRlZCAoQXBhY2hlIGFwcGVuZHMsIENhZGR5IHJlcGxhY2VzKTsg
ZW50cmllcyBiZWZvcmUKICAgICAgLy8gaXQgY29tZSBmcm9tIHRoZSBjbGllbnQgYW5kIGNvdWxk
IGJlIG1hZGUgdXAgdG8gc2xpcCBwYXN0IHRoZSBwZXItYWRkcmVzcyBsaW1pdHMuCiAgICAgIGNv
bnN0IGZvcndhcmRlZCA9IFN0cmluZyhyZXEuaGVhZGVyc1sneC1mb3J3YXJkZWQtZm9yJ10gfHwg
JycpLnNwbGl0KCcsJykubWFwKChwYXJ0KSA9PiBwYXJ0LnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4p
OwogICAgICBpZiAoZm9yd2FyZGVkLmxlbmd0aCkgcmV0dXJuIGZvcndhcmRlZFtmb3J3YXJkZWQu
bGVuZ3RoIC0gMV07CiAgICB9CiAgICByZXR1cm4gcmVxLnNvY2tldC5yZW1vdGVBZGRyZXNzIHx8
ICd1bmtub3duJzsKICB9CgogIGNvbnN0IGhlYXJ0YmVhdCA9IHNldEludGVydmFsKCgpID0+IHsK
ICAgIGZvciAoY29uc3Qgd3Mgb2Ygd3NzLmNsaWVudHMpIHsKICAgICAgaWYgKCF3cy5pc0FsaXZl
KSB7IHdzLnRlcm1pbmF0ZSgpOyBjb250aW51ZTsgfQogICAgICB3cy5pc0FsaXZlID0gZmFsc2U7
CiAgICAgIHRyeSB7IHdzLnBpbmcoKTsgfSBjYXRjaCB7IC8qIGNsb3NpbmcgKi8gfQogICAgfQog
ICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAoY29uc3QgW2FkZHJlc3MsIGVudHJ5
XSBvZiBpbnN0YWxsZXJEb3dubG9hZHMpIGlmIChlbnRyeS51bnRpbCA8PSBub3cpIGluc3RhbGxl
ckRvd25sb2Fkcy5kZWxldGUoYWRkcmVzcyk7CiAgICBwYWNrcy5jbGVhbnVwKCk7CiAgfSwgY29u
ZmlnLnBpbmdJbnRlcnZhbE1zKTsKICBoZWFydGJlYXQudW5yZWYoKTsKCiAgcmV0dXJuIHsKICAg
IGNvbmZpZywKICAgIHNlcnZlciwKICAgIHdzcywKICAgIHJvb21zLAogICAgbGlzdGVuKHBvcnQg
PSBjb25maWcucG9ydCwgaG9zdCA9IGNvbmZpZy5ob3N0KSB7CiAgICAgIHJldHVybiBuZXcgUHJv
bWlzZSgocmVzb2x2ZSwgcmVqZWN0KSA9PiB7CiAgICAgICAgc2VydmVyLm9uY2UoJ2Vycm9yJywg
cmVqZWN0KTsKICAgICAgICBzZXJ2ZXIubGlzdGVuKHBvcnQsIGhvc3QsICgpID0+IHsKICAgICAg
ICAgIHNlcnZlci5vZmYoJ2Vycm9yJywgcmVqZWN0KTsKICAgICAgICAgIHJlc29sdmUoc2VydmVy
LmFkZHJlc3MoKSk7CiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSwKICAgIGdyb3VwcywKICAg
IGhmLAogICAgY2xvc2UoKSB7CiAgICAgIGNsZWFySW50ZXJ2YWwoaGVhcnRiZWF0KTsKICAgICAg
aGYuY2xvc2UoKTsKICAgICAgZm9yIChjb25zdCByb29tIG9mIHJvb21zLnZhbHVlcygpKSBjbGVh
clRpbWVvdXQocm9vbS50aW1lcik7CiAgICAgIGZvciAoY29uc3Qgcm9vbSBvZiBbLi4uZ3JvdXBz
LnZhbHVlcygpXSkgZW5kR3JvdXAocm9vbSwgQ0xPU0Uuc2h1dGRvd24pOwogICAgICBmb3IgKGNv
bnN0IHdzIG9mIHdzcy5jbGllbnRzKSBjbG9zZVdpdGgod3MsIENMT1NFLnNodXRkb3duKTsKICAg
ICAgcmV0dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiB7CiAgICAgICAgd3NzLmNsb3NlKCgp
ID0+IHNlcnZlci5jbG9zZSgoKSA9PiByZXNvbHZlKCkpKTsKICAgICAgICBzZXRUaW1lb3V0KCgp
ID0+IHsgZm9yIChjb25zdCB3cyBvZiB3c3MuY2xpZW50cykgd3MudGVybWluYXRlKCk7IH0sIDEw
MDApLnVucmVmKCk7CiAgICAgIH0pOwogICAgfSwKICB9Owp9CgpmdW5jdGlvbiBzZW5kQ29udHJv
bCh3cywgbWVzc2FnZSkgewogIGlmICh3cy5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQuT1BFTikg
d3Muc2VuZChKU09OLnN0cmluZ2lmeShtZXNzYWdlKSk7Cn0KCmZ1bmN0aW9uIHNlbmRCaW5hcnko
d3MsIGRhdGEpIHsKICBpZiAod3MucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4pIHdzLnNl
bmQoZGF0YSwgeyBiaW5hcnk6IHRydWUgfSk7Cn0KCmNvbnN0IEVNUFRZID0gQnVmZmVyLmFsbG9j
KDApOwoKLy8gQSBwcm90b2NvbCAyIG1lc3NhZ2U6IGtpbmQsIHBheWxvYWQgbGVuZ3RoICgyIGJ5
dGVzLCBsaXR0bGUgZW5kaWFuKSwgcGF5bG9hZC4KZnVuY3Rpb24gcGFja2V0KGtpbmQsIHBheWxv
YWQpIHsKICBjb25zdCBtZXNzYWdlID0gQnVmZmVyLmFsbG9jVW5zYWZlKDMgKyBwYXlsb2FkLmxl
bmd0aCk7CiAgbWVzc2FnZVswXSA9IGtpbmQ7CiAgbWVzc2FnZS53cml0ZVVJbnQxNkxFKHBheWxv
YWQubGVuZ3RoLCAxKTsKICBwYXlsb2FkLmNvcHkobWVzc2FnZSwgMyk7CiAgcmV0dXJuIG1lc3Nh
Z2U7Cn0KCi8vIElucHV0cyBhcmUgYml0IHNldHMgKGtleXMgaGVsZCwgZXZlbnRzKTogbWVyZ2Vk
LCBldmVyeSBiaXQgc2V0IGluIGFueSBvZiB0aGVtIGlzIHNldC4KZnVuY3Rpb24gbWVyZ2VJbnB1
dHMoaW5wdXRzKSB7CiAgY29uc3QgbWVyZ2VkID0gQnVmZmVyLmFsbG9jKE1hdGgubWF4KDAsIC4u
LmlucHV0cy5tYXAoKGlucHV0KSA9PiBpbnB1dC5sZW5ndGgpKSk7CiAgZm9yIChjb25zdCBpbnB1
dCBvZiBpbnB1dHMpIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBpbnB1dC5sZW5ndGg7IGlu
ZGV4ICs9IDEpIG1lcmdlZFtpbmRleF0gfD0gaW5wdXRbaW5kZXhdOwogIHJldHVybiBtZXJnZWQ7
Cn0KCi8vIEEgcmVwZWF0ZWQgaW5wdXQga2VlcHMgaXRzIGhlbGQga2V5cyBidXQgbm90IGl0cyBv
bmUtc2hvdCBldmVudHMgKGJ5dGUgMCkuCmZ1bmN0aW9uIHdpdGhvdXRFdmVudHMoaW5wdXQpIHsK
ICBpZiAoIWlucHV0Lmxlbmd0aCB8fCBpbnB1dFswXSA9PT0gMCkgcmV0dXJuIGlucHV0OwogIGNv
bnN0IGNvcHkgPSBCdWZmZXIuZnJvbShpbnB1dCk7CiAgY29weVswXSA9IDA7CiAgcmV0dXJuIGNv
cHk7Cn0KCmZ1bmN0aW9uIGNsb3NlV2l0aCh3cywgW2NvZGUsIHJlYXNvbl0pIHsKICBpZiAod3Mu
cmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4gfHwgd3MucmVhZHlTdGF0ZSA9PT0gV2ViU29j
a2V0LkNPTk5FQ1RJTkcpIHsKICAgIHdzLmNsb3NlKGNvZGUsIHJlYXNvbik7CiAgICAvLyBEbyBu
b3Qgd2FpdCBmb3JldmVyIGZvciBhIGNsaWVudCB0aGF0IG5ldmVyIGFuc3dlcnMgdGhlIGNsb3Nl
IGhhbmRzaGFrZS4KICAgIHNldFRpbWVvdXQoKCkgPT4geyBpZiAod3MucmVhZHlTdGF0ZSAhPT0g
V2ViU29ja2V0LkNMT1NFRCkgd3MudGVybWluYXRlKCk7IH0sIDMwMDApLnVucmVmKCk7CiAgfQp9
Cgptb2R1bGUuZXhwb3J0cyA9IHsgY3JlYXRlUmVsYXksIHJlYWRDb25maWcsIENMT1NFLCBST09N
X1BBVFRFUk4sIEtJTkQsIFJPT01fTElNSVRTLCBwYWNrZXQsIG1lcmdlSW5wdXRzIH07CgppZiAo
cmVxdWlyZS5tYWluID09PSBtb2R1bGUpIHsKICBjb25zdCByZWxheSA9IGNyZWF0ZVJlbGF5KHJl
YWRDb25maWcoKSk7CiAgcmVsYXkubGlzdGVuKCkudGhlbigoYWRkcmVzcykgPT4gewogICAgY29u
c3Qgd2hlcmUgPSB0eXBlb2YgYWRkcmVzcyA9PT0gJ3N0cmluZycgPyBhZGRyZXNzIDogYCR7YWRk
cmVzcy5hZGRyZXNzfToke2FkZHJlc3MucG9ydH1gOwogICAgY29uc29sZS5sb2coYE9wZW5MRjIg
cmVsYXkgbGlzdGVuaW5nIG9uICR7d2hlcmV9LCBXZWJTb2NrZXQgcGF0aCAke3JlbGF5LmNvbmZp
Zy5wYXRofWApOwogICAgaWYgKCFyZWxheS5jb25maWcuYWxsb3dlZE9yaWdpbnMubGVuZ3RoKSB7
CiAgICAgIGNvbnNvbGUubG9nKCdBTExPV0VEX09SSUdJTlMgaXMgZW1wdHk6IGFueSB3ZWJzaXRl
IG1heSB1c2UgdGhpcyByZWxheS4gU2V0IGl0IHRvIHlvdXIgZ2FtZSBwYWdlIG9yaWdpbi4nKTsK
ICAgIH0KICB9KS5jYXRjaCgoZXJyb3IpID0+IHsKICAgIGNvbnNvbGUuZXJyb3IoZXJyb3IubWVz
c2FnZSk7CiAgICBwcm9jZXNzLmV4aXQoMSk7CiAgfSk7CiAgY29uc3Qgc3RvcCA9ICgpID0+IHJl
bGF5LmNsb3NlKCkudGhlbigoKSA9PiBwcm9jZXNzLmV4aXQoMCkpOwogIHByb2Nlc3Mub24oJ1NJ
R0lOVCcsIHN0b3ApOwogIHByb2Nlc3Mub24oJ1NJR1RFUk0nLCBzdG9wKTsKfQo=
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
Ly8gaXRzZWxmKSBzdGF5IGxvY2tlZCBmb3IgcGxheWVycy4gQ29tcHV0ZXIgcGxheWVycyBnZXQg
YW55IG9mIHRoZW0gKGhmLXJvb20uanMpLgondXNlIHN0cmljdCc7Cgpjb25zdCBjcnlwdG8gPSBy
ZXF1aXJlKCdub2RlOmNyeXB0bycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ25vZGU6ZnMnKTsKY29u
c3QgcGF0aCA9IHJlcXVpcmUoJ25vZGU6cGF0aCcpOwpjb25zdCB7IEhmUm9vbSwgSGZDb25uZWN0
aW9uLCBDSEFSQUNURVJTIH0gPSByZXF1aXJlKCcuL2hmLXJvb20uanMnKTsKCmNvbnN0IFNUT1JJ
RVMgPSA2OyAvLyBHbG9iYWwuc3RvcnlDaG9zZW5fbWF4OiB0aGUgbGFzdCBzdG9yeSBlcGlzb2Rl
CmNvbnN0IE1BWF9FWFBFUklFTkNFID0gMTY5OTk7IC8vIGxldmVsIDE2ICh0aGUgZ2FtZSdzIGhp
Z2hlc3Q7IG1vcmUgaXMgdGFrZW4gZm9yIGEgY2hlYXQpLCA5OTkgZXhwZXJpZW5jZQpjb25zdCBT
VEFSVF9FWFBFUklFTkNFID0gMTYwMDA7IC8vIGxldmVsIDE2OiBub2JvZHkgaGFzIHRvIHBsYXkg
Zm9yIGxldmVscwovLyBUaGUgYWNjb3VudCdzIHZhbHVlcyAoYzEuLmMzMCwgb25lIHBlciBjaGFy
YWN0ZXIsIENIQVJBQ1RFUlMnIG9yZGVyKSB0aGUgZ2FtZSBnZXRzIG5vIGNoYXJhY3RlciBmb3I6
Ci8vIHRoZSBwcmVtaXVtIG9uZXMgKGxlbywgZWFzb24gYW5kIHdpdGggaXQgZWFzb24wLCBpY3p6
eSwgaGVhdGVyLCByYXllLCBsaXZlcm1vcmUpLCB3aGljaCBhcmUgdG9vIHN0cm9uZwovLyBmb3Ig
cGxheWVycywgYW5kIHlhZ2EgKCJ1bmF2YWlsYWJsZSIpLiBBIHZhbHVlIG9mIDAga2VlcHMgYSBj
aGFyYWN0ZXIgbG9ja2VkOyBhIG5vbi1wcmVtaXVtIGFjY291bnQKLy8gKHN0YXR1c0NvZGUgYmVs
b3cpIGtlZXBzIHRoZSBwcmVtaXVtIG9uZXMgbG9ja2VkIHdoYXRldmVyIHRoZWlyIHZhbHVlLgpj
b25zdCBMT0NLRUQgPSBuZXcgU2V0KFs1LCA3LCA4LCAxNCwgMTUsIDE2LCAxOF0pOwpjb25zdCBQ
TEFZQUJMRSA9IDE5OyAvLyBjMS4uYzE5IGFyZSBjaGFyYWN0ZXJzOyBjMjAuLmMzMCBhcmUgbm90
IHVzZWQKLy8gVGhlIHZhbHVlcyBhbiBhY2NvdW50IGhhczogdGhlIHBsYXlhYmxlIGNoYXJhY3Rl
cnMgYXQgbGV2ZWwgMTYgYXQgbGVhc3QsIHRoZSBsb2NrZWQgb25lcyBhdCAwLgpmdW5jdGlvbiBz
ZXR0bGVkVmFsdWVzKHZhbHVlcykgewogIHJldHVybiBBcnJheS5mcm9tKHsgbGVuZ3RoOiAzMCB9
LCAoXywgaykgPT4gewogICAgaWYgKGsgPj0gUExBWUFCTEUpIHJldHVybiBOdW1iZXIodmFsdWVz
ICYmIHZhbHVlc1trXSkgfHwgMDsKICAgIGlmIChMT0NLRUQuaGFzKGspKSByZXR1cm4gMDsKICAg
IHJldHVybiBNYXRoLm1pbihNQVhfRVhQRVJJRU5DRSwgTWF0aC5tYXgoU1RBUlRfRVhQRVJJRU5D
RSwgTnVtYmVyKHZhbHVlcyAmJiB2YWx1ZXNba10pIHx8IDApKTsKICB9KTsKfQoKLy8gVGhlIGdh
bWUgY2hlY2tzIGxvZ2luIGFuc3dlcnMgd2l0aCBhIGNvZGUgb3ZlciB0aGUgbnVtYmVycyBpbiB0
aGVtIChHbG9iYWwuTG9naW5TdGF0dXNNZXNzYWdlKToKLy8gd2l0aCBuID0gdls4XSwgbSA9IHZb
OSsybi4uKzddIGFuZCB4ID0gdlsxNisybi4uKzddLCAoOTk5OTk5OCAtIHggLSBtKSAvIDMgbXVz
dCBiZSB0aGUgc3VtIGJlbG93Ci8vIChvciB0aGF0IHBsdXMgaWQlMTMgKyBpZCU2MSArIGlkJTEw
NywgZm9yIGEgcHJlbWl1bSBhY2NvdW50OiBldmVyeSBjaGFyYWN0ZXIsIGFsc28gdGhlIHByZW1p
dW0gb25lcykuCmZ1bmN0aW9uIHN0YXR1c0NvZGUodmFsdWVzLCBpZCwgYWNjdHlwZSwgc3RhZ2Us
IHNlc3Npb24sIHByZW1pdW0pIHsKICBjb25zdCBzdW0gPSAodmFsdWVzLnJlZHVjZSgoYSwgYikg
PT4gYSArIGIsIDApICsgaWQgKyBhY2N0eXBlICsgc3RhZ2UgKyBzZXNzaW9uICUgMTAwMDAwMCkg
JSAxMDAwMDAwICsgMTAwMDAwMDsKICByZXR1cm4gZW5jb2RlTnVtYmVyKHN1bSArIChwcmVtaXVt
ID8gaWQgJSAxMyArIGlkICUgNjEgKyBpZCAlIDEwNyA6IDApKTsKfQoKLy8gQSBudW1iZXIgdGhl
IGdhbWUgcmVhZHMgYmFjayBhcyAoOTk5OTk5OCAtIHggLSBtKSAvIDMgZnJvbSB0aGUgMjUtZGln
aXQgZm9ybSBhYm92ZSAoYW5kIGNhcHRjaGEKLy8gY29kZXMgYXMgdGhhdCBtb2R1bG8gMTAwMDAw
MCk6IHJhbmRvbSBkaWdpdHMgYXJvdW5kIGl0LCBhcyBoZXJvZmlnaHRlci5jb20gc2VudC4KZnVu
Y3Rpb24gZW5jb2RlTnVtYmVyKG51bWJlcikgewogIGNvbnN0IGRpZ2l0ID0gKCkgPT4gU3RyaW5n
KGNyeXB0by5yYW5kb21JbnQoMTApKTsKICBjb25zdCBuID0gY3J5cHRvLnJhbmRvbUludCgxMCk7
CiAgY29uc3QgbSA9IGNyeXB0by5yYW5kb21JbnQoMTAwMDAwMCwgMjAwMDAwMCk7CiAgY29uc3Qg
eCA9IDk5OTk5OTggLSAzICogbnVtYmVyIC0gbTsKICBsZXQgdGV4dCA9ICcnOwogIGZvciAobGV0
IGsgPSAwOyBrIDwgODsgayArPSAxKSB0ZXh0ICs9IGRpZ2l0KCk7CiAgdGV4dCArPSBTdHJpbmco
bik7CiAgZm9yIChsZXQgayA9IDA7IGsgPCBuICogMjsgayArPSAxKSB0ZXh0ICs9IGRpZ2l0KCk7
CiAgdGV4dCArPSBTdHJpbmcobSkucGFkU3RhcnQoNywgJzAnKSArIFN0cmluZyh4KS5wYWRTdGFy
dCg3LCAnMCcpOwogIGZvciAobGV0IGsgPSAwOyBrIDwgMTggLSBuICogMjsgayArPSAxKSB0ZXh0
ICs9IGRpZ2l0KCk7CiAgcmV0dXJuIHRleHQ7Cn0KCi8vIFdoYXQgdGhlIGdhbWUncyBwcmVtaXVt
IG9mZmVyIChpdCBzaG93cyBvbmUgYnkgdGhlIGxvY2tlZCBjaGFyYWN0ZXJzKSBvcGVucyBpbiBh
IG5ldyB0YWIuCmNvbnN0IFBSRU1JVU1fUEFHRSA9IGA8IWRvY3R5cGUgaHRtbD4KPGh0bWwgbGFu
Zz0idmkiPjxoZWFkPjxtZXRhIGNoYXJzZXQ9InV0Zi04Ij48bWV0YSBuYW1lPSJ2aWV3cG9ydCIg
Y29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+SGVy
byBGaWdodGVyOiBQcmVtaXVtPC90aXRsZT4KPHN0eWxlPmJvZHl7Zm9udDoxN3B4LzEuNTUgc3lz
dGVtLXVpLHNhbnMtc2VyaWY7bWF4LXdpZHRoOjM2cmVtO21hcmdpbjozcmVtIGF1dG87cGFkZGlu
ZzowIDE2cHg7Y29sb3I6IzFkMWQxZDtiYWNrZ3JvdW5kOiNmN2Y3ZjV9Cmgxe2ZvbnQtc2l6ZTox
LjM1cmVtfS5lbntjb2xvcjojNmE2YTZhO2ZvbnQtc2l6ZTouOTVyZW19CkBtZWRpYSAocHJlZmVy
cy1jb2xvci1zY2hlbWU6ZGFyayl7Ym9keXtjb2xvcjojZWNlY2VjO2JhY2tncm91bmQ6IzFhMWEx
YX0uZW57Y29sb3I6I2EwYTBhMH19PC9zdHlsZT48L2hlYWQ+Cjxib2R5PjxoMT5LaMO0bmcgY+G6
p24gbXVhIGfDrCBj4bqjPC9oMT4KPHA+VHLDqm4gbcOheSBjaOG7pyBuw6B5LCBjw6FjIG5ow6Ju
IHbhuq10IFByZW1pdW0gKExlbywgRWFzb24sIEljenp5LCBIZWF0ZXIsIFJheWUsIExpdmVybW9y
ZSkgYuG7iyBraMOzYSB24bubaSBuZ8aw4budaSBjaMahaSB2w6wgcXXDoQpt4bqhbmg7IG3DoXkg
KENvbSBQbGF5ZXIpIHbhuqtuIGTDuW5nIMSRxrDhu6NjLiBN4buNaSBuaMOibiB24bqtdCBraMOh
YyDEkeG7gXUgxJHDoyDhu58gTGV2ZWwgMTYuPC9wPgo8cD7EkMOzbmcgdHJhbmcgbsOgeSB2w6Ag
cXVheSBs4bqhaSBnYW1lLjwvcD4KPHAgY2xhc3M9ImVuIiBsYW5nPSJlbiI+Tm90aGluZyB0byBi
dXkgaGVyZTogb24gdGhpcyBzZXJ2ZXIgdGhlIHByZW1pdW0gY2hhcmFjdGVycyBhcmUgbG9ja2Vk
IGZvciBwbGF5ZXJzICh0aGV5IGFyZSB0b28Kc3Ryb25nKSwgYW5kIGNvbXB1dGVyIHBsYXllcnMg
bWF5IHN0aWxsIGhhdmUgdGhlbS4gRXZlcnkgb3RoZXIgY2hhcmFjdGVyIGlzIGF0IGxldmVsIDE2
LiBDbG9zZSB0aGlzIHBhZ2UgYW5kIGdvIGJhY2sKdG8gdGhlIGdhbWUuPC9wPgo8L2JvZHk+PC9o
dG1sPgpgOwoKZnVuY3Rpb24geG1sVGV4dCh2YWx1ZSkgewogIHJldHVybiBTdHJpbmcodmFsdWUp
LnJlcGxhY2UoL1s8PiZdL2csIChjKSA9PiAoeyAnPCc6ICcmbHQ7JywgJz4nOiAnJmd0OycsICcm
JzogJyZhbXA7JyB9W2NdKSk7Cn0KCi8vIEEgZGlzcGxheSBuYW1lOiB3aGF0IHRoZSBnYW1lIGFs
bG93cyBpbiBvbmUgKG5vIFsgb3IgXSwgd2hpY2ggaXQgdXNlcyBpdHNlbGYpLCBhdCBtb3N0IDIw
IGNoYXJhY3RlcnMuCmZ1bmN0aW9uIGNsZWFuTmFtZSh2YWx1ZSkgewogIHJldHVybiBTdHJpbmco
dmFsdWUgfHwgJycpLnJlcGxhY2UoL1tbXF08PiYiXHUwMDAwLVx1MDAxZl0vZywgJycpLnRyaW0o
KS5zbGljZSgwLCAyMCk7Cn0KCmZ1bmN0aW9uIGhhc2hQYXNzd29yZChwYXNzd29yZCwgc2FsdCkg
ewogIHJldHVybiBjcnlwdG8uc2NyeXB0U3luYyhTdHJpbmcocGFzc3dvcmQpLCBzYWx0LCAzMiku
dG9TdHJpbmcoJ2hleCcpOwp9CgpmdW5jdGlvbiBjcmVhdGVBY2NvdW50cyhmaWxlLCBsb2cpIHsK
ICBsZXQgYWNjb3VudHMgPSB7fTsKICBsZXQgbmV4dElkID0gMTAwMTsgLy8gaWRzIHVwIHRvIDIw
IG9wZW4gdGhlIGdhbWUncyBkZXZlbG9wZXIga2V5cwogIGxldCBzYXZlVGltZXIgPSBudWxsOwog
IGlmIChmaWxlKSB7CiAgICB0cnkgewogICAgICBjb25zdCBzYXZlZCA9IEpTT04ucGFyc2UoZnMu
cmVhZEZpbGVTeW5jKGZpbGUsICd1dGY4JykpOwogICAgICBhY2NvdW50cyA9IHNhdmVkLmFjY291
bnRzIHx8IHt9OwogICAgICBuZXh0SWQgPSBNYXRoLm1heChuZXh0SWQsIE51bWJlcihzYXZlZC5u
ZXh0SWQpIHx8IDApOwogICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgaWYgKGVycm9yLmNvZGUg
IT09ICdFTk9FTlQnKSBsb2coYGhmIGFjY291bnRzOiBjb3VsZCBub3QgcmVhZCAke2ZpbGV9OiAk
e2Vycm9yLm1lc3NhZ2V9YCk7CiAgICB9CiAgfQogIGNvbnN0IHNhdmUgPSAoKSA9PiB7CiAgICBp
ZiAoIWZpbGUgfHwgc2F2ZVRpbWVyKSByZXR1cm47CiAgICBzYXZlVGltZXIgPSBzZXRUaW1lb3V0
KCgpID0+IHsKICAgICAgc2F2ZVRpbWVyID0gbnVsbDsKICAgICAgdHJ5IHsKICAgICAgICBmcy5t
a2RpclN5bmMocGF0aC5kaXJuYW1lKGZpbGUpLCB7IHJlY3Vyc2l2ZTogdHJ1ZSB9KTsKICAgICAg
ICBjb25zdCB0ZW1wb3JhcnkgPSBgJHtmaWxlfS4ke3Byb2Nlc3MucGlkfS50bXBgOwogICAgICAg
IGZzLndyaXRlRmlsZVN5bmModGVtcG9yYXJ5LCBKU09OLnN0cmluZ2lmeSh7IHZlcnNpb246IDEs
IG5leHRJZCwgYWNjb3VudHMgfSwgbnVsbCwgMSkpOwogICAgICAgIGZzLnJlbmFtZVN5bmModGVt
cG9yYXJ5LCBmaWxlKTsKICAgICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgICBsb2coYGhmIGFj
Y291bnRzOiBjb3VsZCBub3Qgc2F2ZTogJHtlcnJvci5tZXNzYWdlfWApOwogICAgICB9CiAgICB9
LCA1MDApOwogICAgaWYgKHNhdmVUaW1lci51bnJlZikgc2F2ZVRpbWVyLnVucmVmKCk7CiAgfTsK
ICByZXR1cm4gewogICAgZ2V0KGVtYWlsKSB7IHJldHVybiBhY2NvdW50c1tlbWFpbF0gfHwgbnVs
bDsgfSwKICAgIGJ5SWQoaWQpIHsgcmV0dXJuIE9iamVjdC52YWx1ZXMoYWNjb3VudHMpLmZpbmQo
KGFjY291bnQpID0+IFN0cmluZyhhY2NvdW50LmlkKSA9PT0gU3RyaW5nKGlkKSkgfHwgbnVsbDsg
fSwKICAgIGJ5TmFtZShuYW1lKSB7IHJldHVybiBPYmplY3QudmFsdWVzKGFjY291bnRzKS5maW5k
KChhY2NvdW50KSA9PiBhY2NvdW50Lm5hbWUudG9Mb3dlckNhc2UoKSA9PT0gbmFtZS50b0xvd2Vy
Q2FzZSgpKSB8fCBudWxsOyB9LAogICAgY3JlYXRlKGVtYWlsLCBwYXNzd29yZCwgbmFtZSwgY2Mp
IHsKICAgICAgY29uc3Qgc2FsdCA9IGNyeXB0by5yYW5kb21CeXRlcygxMikudG9TdHJpbmcoJ2hl
eCcpOwogICAgICBsZXQgdW5pcXVlID0gbmFtZSB8fCAnUGxheWVyJzsKICAgICAgZm9yIChsZXQg
ayA9IDI7IHRoaXMuYnlOYW1lKHVuaXF1ZSk7IGsgKz0gMSkgdW5pcXVlID0gYCR7bmFtZS5zbGlj
ZSgwLCAxNyl9JHtrfWA7CiAgICAgIGNvbnN0IGFjY291bnQgPSB7CiAgICAgICAgaWQ6IG5leHRJ
ZCsrLCBuYW1lOiB1bmlxdWUsIGNjOiBjYyB8fCAnVk4nLCBzYWx0LCBoYXNoOiBoYXNoUGFzc3dv
cmQocGFzc3dvcmQsIHNhbHQpLAogICAgICAgIHNlc3Npb246IGNyeXB0by5yYW5kb21JbnQoMTAw
MDAwLCAxMDAwMDAwMDAwKSwgdmFsdWVzOiBzZXR0bGVkVmFsdWVzKG51bGwpLAogICAgICAgIHN0
YWdlOiBTVE9SSUVTLCBuYW1lQ2hhbmdlczogOSwgY3JlYXRlZDogbmV3IERhdGUoKS50b0lTT1N0
cmluZygpLCAvLyAobmFtZSBjaGFuZ2VzIGFyZSBub3QgY291bnRlZCBkb3duKQogICAgICB9Owog
ICAgICBhY2NvdW50c1tlbWFpbF0gPSBhY2NvdW50OwogICAgICBzYXZlKCk7CiAgICAgIHJldHVy
biBhY2NvdW50OwogICAgfSwKICAgIGNoZWNrUGFzc3dvcmQoYWNjb3VudCwgcGFzc3dvcmQpIHsK
ICAgICAgY29uc3QgZXhwZWN0ZWQgPSBCdWZmZXIuZnJvbShhY2NvdW50Lmhhc2gsICdoZXgnKTsK
ICAgICAgY29uc3QgZ2l2ZW4gPSBCdWZmZXIuZnJvbShoYXNoUGFzc3dvcmQocGFzc3dvcmQsIGFj
Y291bnQuc2FsdCksICdoZXgnKTsKICAgICAgcmV0dXJuIGV4cGVjdGVkLmxlbmd0aCA9PT0gZ2l2
ZW4ubGVuZ3RoICYmIGNyeXB0by50aW1pbmdTYWZlRXF1YWwoZXhwZWN0ZWQsIGdpdmVuKTsKICAg
IH0sCiAgICBzZXRQYXNzd29yZChhY2NvdW50LCBwYXNzd29yZCkgewogICAgICBhY2NvdW50LnNh
bHQgPSBjcnlwdG8ucmFuZG9tQnl0ZXMoMTIpLnRvU3RyaW5nKCdoZXgnKTsKICAgICAgYWNjb3Vu
dC5oYXNoID0gaGFzaFBhc3N3b3JkKHBhc3N3b3JkLCBhY2NvdW50LnNhbHQpOwogICAgICBzYXZl
KCk7CiAgICB9LAogICAgc2F2ZSwKICAgIGZsdXNoKCkgewogICAgICBpZiAoIXNhdmVUaW1lcikg
cmV0dXJuOwogICAgICBjbGVhclRpbWVvdXQoc2F2ZVRpbWVyKTsKICAgICAgc2F2ZVRpbWVyID0g
bnVsbDsKICAgICAgdHJ5IHsKICAgICAgICBmcy5ta2RpclN5bmMocGF0aC5kaXJuYW1lKGZpbGUp
LCB7IHJlY3Vyc2l2ZTogdHJ1ZSB9KTsKICAgICAgICBmcy53cml0ZUZpbGVTeW5jKGZpbGUsIEpT
T04uc3RyaW5naWZ5KHsgdmVyc2lvbjogMSwgbmV4dElkLCBhY2NvdW50cyB9LCBudWxsLCAxKSk7
CiAgICAgIH0gY2F0Y2ggKGVycm9yKSB7CiAgICAgICAgbG9nKGBoZiBhY2NvdW50czogY291bGQg
bm90IHNhdmU6ICR7ZXJyb3IubWVzc2FnZX1gKTsKICAgICAgfQogICAgfSwKICB9Owp9CgpmdW5j
dGlvbiBjcmVhdGVIZihjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzLCBhbGxvd09yaWdpbiwg
YnVkZ2V0IH0pIHsKICBjb25zdCBmb2xkZXIgPSBjb25maWcuaGZEaXIgfHwgKGNvbmZpZy5wYWNr
c0RpciA/IHBhdGguam9pbihjb25maWcucGFja3NEaXIsICdoZicpIDogJycpOwogIGNvbnN0IGFj
Y291bnRzID0gY3JlYXRlQWNjb3VudHMoZm9sZGVyICYmIHBhdGguam9pbihmb2xkZXIsICdhY2Nv
dW50cy5qc29uJyksIGxvZyk7CiAgY29uc3Qgcm9vbUNvdW50ID0gTWF0aC5tYXgoMSwgTWF0aC5t
aW4oMjAsIE1hdGgucm91bmQoY29uZmlnLmhmUm9vbXMgfHwgNCkpKTsKICBjb25zdCByb29tcyA9
IFtdOwogIGZvciAobGV0IG51bWJlciA9IDE7IG51bWJlciA8PSByb29tQ291bnQ7IG51bWJlciAr
PSAxKSB7CiAgICByb29tcy5wdXNoKG5ldyBIZlJvb20oeyBudW1iZXIsIG5hbWU6IGBQaG9uZyAk
e251bWJlcn1gLCBkZXNjcmlwdGlvbjogY29uZmlnLmhmUm9vbURlc2NyaXB0aW9uIHx8ICdPcGVu
TEYyIHJlbGF5JywgbG9nIH0pKTsKICB9CiAgY29uc3QgY2FwdGNoYXMgPSBuZXcgTWFwKCk7IC8v
IGNsaWVudCBrZXkgLT4geyBjb2RlLCB1bnRpbCB9CiAgY29uc3QgdHJpZXMgPSBuZXcgTWFwKCk7
IC8vIGNsaWVudCBhZGRyZXNzIC0+IHsgY291bnQsIHVudGlsIH06IGZhaWxlZCBwYXNzd29yZHMg
YW5kIGNvZGVzCiAgY29uc3QgY3JlYXRpb25zID0gbmV3IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVz
cyAtPiB7IGNvdW50LCB1bnRpbCB9OiBuZXcgYWNjb3VudHMKICBjb25zdCBtYXlDcmVhdGUgPSAo
YWRkcmVzcykgPT4gewogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGxldCBlbnRyeSA9
IGNyZWF0aW9ucy5nZXQoYWRkcmVzcyk7CiAgICBpZiAoIWVudHJ5IHx8IGVudHJ5LnVudGlsIDw9
IG5vdykgewogICAgICBlbnRyeSA9IHsgY291bnQ6IDAsIHVudGlsOiBub3cgKyAzNjAwMDAwIH07
CiAgICAgIGNyZWF0aW9ucy5zZXQoYWRkcmVzcywgZW50cnkpOwogICAgfQogICAgaWYgKGVudHJ5
LmNvdW50ID49IDIwKSByZXR1cm4gZmFsc2U7CiAgICBlbnRyeS5jb3VudCArPSAxOwogICAgcmV0
dXJuIHRydWU7CiAgfTsKICBjb25zdCBMSU1JVCA9ICc8ZW4+VG9vIG1hbnkgbmV3IGFjY291bnRz
IGZyb20geW91ciBuZXR3b3JrOiB0cnkgYWdhaW4gaW4gYW4gaG91ci48L2VuPjxiNT5Ub28gbWFu
eSBuZXcgYWNjb3VudHMgZnJvbSB5b3VyIG5ldHdvcms6IHRyeSBhZ2FpbiBpbiBhbiBob3VyLjwv
YjU+JzsKCiAgZnVuY3Rpb24gbG9naW5YbWwoYWNjb3VudCwgcm9vdCA9ICdsb2dpbicpIHsKICAg
IGNvbnN0IHZhbHVlcyA9IGFjY291bnQudmFsdWVzOwogICAgY29uc3QgZmllbGRzID0gdmFsdWVz
Lm1hcCgodmFsdWUsIGluZGV4KSA9PiBgPGMke2luZGV4ICsgMX0+JHt2YWx1ZX08L2Mke2luZGV4
ICsgMX0+YCkuam9pbignJyk7CiAgICBjb25zdCBjb2RlID0gc3RhdHVzQ29kZSh2YWx1ZXMsIGFj
Y291bnQuaWQsIDAsIGFjY291bnQuc3RhZ2UsIGFjY291bnQuc2Vzc2lvbiwgZmFsc2UpOwogICAg
cmV0dXJuIGA8JHtyb290fT4ke2ZpZWxkc308aT4ke2FjY291bnQuaWR9PC9pPjxuPiR7eG1sVGV4
dChhY2NvdW50Lm5hbWUpfTwvbj48Y2M+JHt4bWxUZXh0KGFjY291bnQuY2MpfTwvY2M+YAogICAg
ICArIGA8cz4ke2FjY291bnQuc2Vzc2lvbn08L3M+PGFjY3R5cGU+MDwvYWNjdHlwZT48c3RhZ2U+
JHthY2NvdW50LnN0YWdlfTwvc3RhZ2U+PHY+JHtjb2RlfTwvdj48LyR7cm9vdH0+YDsKICB9Cgog
IGNvbnN0IHBydW5lID0gKCkgPT4gewogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZv
ciAoY29uc3QgbWFwIG9mIFt0cmllcywgY3JlYXRpb25zXSkgZm9yIChjb25zdCBba2V5LCBlbnRy
eV0gb2YgbWFwKSBpZiAoZW50cnkudW50aWwgPD0gbm93KSBtYXAuZGVsZXRlKGtleSk7CiAgICBm
b3IgKGNvbnN0IFtrZXksIGVudHJ5XSBvZiBjYXB0Y2hhcykgaWYgKGVudHJ5LnVudGlsIDw9IG5v
dykgY2FwdGNoYXMuZGVsZXRlKGtleSk7CiAgfTsKICBjb25zdCBwcnVuZVRpbWVyID0gc2V0SW50
ZXJ2YWwocHJ1bmUsIDYwMDAwMCk7CiAgaWYgKHBydW5lVGltZXIudW5yZWYpIHBydW5lVGltZXIu
dW5yZWYoKTsKCiAgZnVuY3Rpb24gdG9vTWFueVRyaWVzKGFkZHJlc3MpIHsKICAgIGNvbnN0IG5v
dyA9IERhdGUubm93KCk7CiAgICBjb25zdCBlbnRyeSA9IHRyaWVzLmdldChhZGRyZXNzKTsKICAg
IHJldHVybiBCb29sZWFuKGVudHJ5ICYmIGVudHJ5LnVudGlsID4gbm93ICYmIGVudHJ5LmNvdW50
ID49IDMwKTsKICB9CiAgZnVuY3Rpb24gZmFpbGVkVHJ5KGFkZHJlc3MpIHsKICAgIGNvbnN0IG5v
dyA9IERhdGUubm93KCk7CiAgICBsZXQgZW50cnkgPSB0cmllcy5nZXQoYWRkcmVzcyk7CiAgICBp
ZiAoIWVudHJ5IHx8IGVudHJ5LnVudGlsIDw9IG5vdykgewogICAgICBlbnRyeSA9IHsgY291bnQ6
IDAsIHVudGlsOiBub3cgKyAzNjAwMDAwIH07CiAgICAgIHRyaWVzLnNldChhZGRyZXNzLCBlbnRy
eSk7CiAgICB9CiAgICBlbnRyeS5jb3VudCArPSAxOwogIH0KCiAgZnVuY3Rpb24gY2hlY2tDYXB0
Y2hhKGtleSwgY29kZSkgewogICAgY29uc3QgZW50cnkgPSBjYXB0Y2hhcy5nZXQoU3RyaW5nKGtl
eSB8fCAnJykpOwogICAgY2FwdGNoYXMuZGVsZXRlKFN0cmluZyhrZXkgfHwgJycpKTsKICAgIHJl
dHVybiBCb29sZWFuKGVudHJ5ICYmIGVudHJ5LnVudGlsID4gRGF0ZS5ub3coKSAmJiBTdHJpbmco
ZW50cnkuY29kZSkgPT09IFN0cmluZyhjb2RlIHx8ICcnKS50cmltKCkpOwogIH0KCiAgY29uc3Qg
ZW1haWwgPSAodmFsdWUpID0+IFN0cmluZyh2YWx1ZSB8fCAnJykudHJpbSgpLnRvTG93ZXJDYXNl
KCkuc2xpY2UoMCwgMTAwKTsKCiAgLy8gVGhlIGFuc3dlciB0byBvbmUgb2YgdGhlIGFjY291bnQg
c2VydmljZXMsIGZyb20gdGhlIHF1ZXJ5IChhbmQgYSBmb3JtIGJvZHksIGlmIGFueSkuCiAgZnVu
Y3Rpb24gYW5zd2VyKHNlcnZpY2UsIHBhcmFtcywgYWRkcmVzcykgewogICAgY29uc3QgZ2V0ID0g
KG5hbWUpID0+IHBhcmFtcy5nZXQobmFtZSkgfHwgJyc7CiAgICBpZiAoc2VydmljZSA9PT0gJ3Yw
LjcvbG9naW4ucGhwJykgewogICAgICBjb25zdCBlbSA9IGVtYWlsKGdldCgnZW0nKSk7CiAgICAg
IGlmICghZW0pIHJldHVybiAnPGxvZ2luPjxlcnJvcj5lbTwvZXJyb3I+PC9sb2dpbj4nOwogICAg
ICBpZiAodG9vTWFueVRyaWVzKGFkZHJlc3MpKSByZXR1cm4gJzxsb2dpbj48ZXJyb3I+cmVhc29u
PC9lcnJvcj48ZW4+VG9vIG1hbnkgd3JvbmcgcGFzc3dvcmRzOiB0cnkgYWdhaW4gaW4gYW4gaG91
ci48L2VuPjxiNT5Ub28gbWFueSB3cm9uZyBwYXNzd29yZHM6IHRyeSBhZ2FpbiBpbiBhbiBob3Vy
LjwvYjU+PC9sb2dpbj4nOwogICAgICBsZXQgYWNjb3VudCA9IGFjY291bnRzLmdldChlbSk7CiAg
ICAgIGlmICghYWNjb3VudCkgewogICAgICAgIGlmICghbWF5Q3JlYXRlKGFkZHJlc3MpKSByZXR1
cm4gYDxsb2dpbj48ZXJyb3I+cmVhc29uPC9lcnJvcj4ke0xJTUlUfTwvbG9naW4+YDsKICAgICAg
ICBhY2NvdW50ID0gYWNjb3VudHMuY3JlYXRlKGVtLCBnZXQoJ3B3JyksIGNsZWFuTmFtZShlbS5z
cGxpdCgnQCcpWzBdKSwgJ1ZOJyk7CiAgICAgICAgbG9nKGBoZjogbmV3IGFjY291bnQgJHthY2Nv
dW50LmlkfSAiJHthY2NvdW50Lm5hbWV9ImApOwogICAgICB9IGVsc2UgaWYgKCFhY2NvdW50cy5j
aGVja1Bhc3N3b3JkKGFjY291bnQsIGdldCgncHcnKSkpIHsKICAgICAgICBmYWlsZWRUcnkoYWRk
cmVzcyk7CiAgICAgICAgcmV0dXJuICc8bG9naW4+PGVycm9yPnB3PC9lcnJvcj48L2xvZ2luPic7
CiAgICAgIH0KICAgICAgLy8gQWNjb3VudHMgbWFkZSBiZWZvcmUgdGhlIGNoYXJhY3RlcnMnIHJ1
bGVzIHdlcmUgd2hhdCB0aGV5IGFyZSBub3cgZm9sbG93IHRoZW0gZnJvbSB0aGVpciBuZXh0IGxv
Z2luLgogICAgICBjb25zdCBzZXR0bGVkID0gc2V0dGxlZFZhbHVlcyhhY2NvdW50LnZhbHVlcyk7
CiAgICAgIGlmIChzZXR0bGVkLnNvbWUoKHZhbHVlLCBrKSA9PiB2YWx1ZSAhPT0gYWNjb3VudC52
YWx1ZXNba10pKSB7CiAgICAgICAgYWNjb3VudC52YWx1ZXMgPSBzZXR0bGVkOwogICAgICAgIGFj
Y291bnRzLnNhdmUoKTsKICAgICAgfQogICAgICByZXR1cm4gbG9naW5YbWwoYWNjb3VudCk7CiAg
ICB9CiAgICBpZiAoc2VydmljZSA9PT0gJ3YwLjcvbHUucGhwJykgewogICAgICBjb25zdCBhY2Nv
dW50ID0gYWNjb3VudHMuZ2V0KGVtYWlsKGdldCgnZW0nKSkpOwogICAgICBpZiAoIWFjY291bnQg
fHwgU3RyaW5nKGFjY291bnQuaWQpICE9PSBnZXQoJ2lkJykgfHwgU3RyaW5nKGFjY291bnQuc2Vz
c2lvbikgIT09IGdldCgncycpKSByZXR1cm4gJzxsdT48ZXJyb3I+c2E8L2Vycm9yPjwvbHU+JzsK
ICAgICAgZm9yIChsZXQgayA9IDE7IGsgPD0gMzsgayArPSAxKSB7CiAgICAgICAgY29uc3QgaW5k
ZXggPSBOdW1iZXIoZ2V0KGBpJHtrfWApKTsKICAgICAgICBjb25zdCB0byA9IE51bWJlcihnZXQo
YHRvJHtrfWApKTsKICAgICAgICBpZiAoIU51bWJlci5pc0ludGVnZXIoaW5kZXgpIHx8IGluZGV4
IDwgMSB8fCBpbmRleCA+IENIQVJBQ1RFUlMubGVuZ3RoIC0gMSB8fCAhTnVtYmVyLmlzRmluaXRl
KHRvKSkgY29udGludWU7CiAgICAgICAgYWNjb3VudC52YWx1ZXNbaW5kZXggLSAxXSA9IE1hdGgu
bWF4KGFjY291bnQudmFsdWVzW2luZGV4IC0gMV0sIE1hdGgubWluKE1BWF9FWFBFUklFTkNFLCBN
YXRoLmZsb29yKHRvKSkpOwogICAgICB9CiAgICAgIC8vICh1bGksIGEgY2hhcmFjdGVyIGEgc3Rv
cnkgdW5sb2NrczogZXZlcnkgY2hhcmFjdGVyIGEgcGxheWVyIG1heSBoYXZlIGlzIHVubG9ja2Vk
IGFscmVhZHkuKQogICAgICBhY2NvdW50LnZhbHVlcyA9IHNldHRsZWRWYWx1ZXMoYWNjb3VudC52
YWx1ZXMpOwogICAgICBjb25zdCBzdGFnZSA9IE51bWJlcihnZXQoJ3N0ZycpKTsKICAgICAgaWYg
KE51bWJlci5pc0ludGVnZXIoc3RhZ2UpKSBhY2NvdW50LnN0YWdlID0gTWF0aC5tYXgoYWNjb3Vu
dC5zdGFnZSwgTWF0aC5taW4oU1RPUklFUywgc3RhZ2UpKTsKICAgICAgYWNjb3VudHMuc2F2ZSgp
OwogICAgICByZXR1cm4gbG9naW5YbWwoYWNjb3VudCwgJ2x1Jyk7CiAgICB9CiAgICBpZiAoc2Vy
dmljZSA9PT0gJ2NhcC5waHAnKSB7CiAgICAgIGNvbnN0IGtleSA9IGNyeXB0by5yYW5kb21CeXRl
cyg4KS50b1N0cmluZygnaGV4Jyk7CiAgICAgIGNvbnN0IGNvZGUgPSBjcnlwdG8ucmFuZG9tSW50
KDEwMDAsIDEwMDAwKTsKICAgICAgY2FwdGNoYXMuc2V0KGtleSwgeyBjb2RlLCB1bnRpbDogRGF0
ZS5ub3coKSArIDYwMDAwMCB9KTsKICAgICAgaWYgKGNhcHRjaGFzLnNpemUgPiAyMDAwKSBjYXB0
Y2hhcy5kZWxldGUoY2FwdGNoYXMua2V5cygpLm5leHQoKS52YWx1ZSk7CiAgICAgIHJldHVybiBg
PGNhcD48YzE+JHtrZXl9PC9jMT48YzI+JHtlbmNvZGVOdW1iZXIoY29kZSl9PC9jMj48L2NhcD5g
OwogICAgfQogICAgaWYgKHNlcnZpY2UgPT09ICdyZWcucGhwJykgewogICAgICBpZiAoIWNoZWNr
Q2FwdGNoYShnZXQoJ2MnKSwgZ2V0KCdzJykpKSByZXR1cm4gJzxyZWc+PGVycm9yPmNvZGU8L2Vy
cm9yPjwvcmVnPic7CiAgICAgIGNvbnN0IGVtID0gZW1haWwoZ2V0KCdlbScpKTsKICAgICAgaWYg
KCFlbSB8fCBhY2NvdW50cy5nZXQoZW0pKSByZXR1cm4gJzxyZWc+PGVycm9yPnNhbWVlbWFpbDwv
ZXJyb3I+PC9yZWc+JzsKICAgICAgY29uc3QgbmFtZSA9IGNsZWFuTmFtZShnZXQoJ25tJykpOwog
ICAgICBpZiAoIW5hbWUpIHJldHVybiAnPHJlZz48ZXJyb3I+bmFtZTwvZXJyb3I+PC9yZWc+JzsK
ICAgICAgaWYgKGFjY291bnRzLmJ5TmFtZShuYW1lKSkgcmV0dXJuICc8cmVnPjxlcnJvcj5zYW1l
bmFtZTwvZXJyb3I+PC9yZWc+JzsKICAgICAgaWYgKCFtYXlDcmVhdGUoYWRkcmVzcykpIHJldHVy
biBgPHJlZz48ZXJyb3I+bGltaXQ8L2Vycm9yPiR7TElNSVR9PC9yZWc+YDsKICAgICAgY29uc3Qg
YWNjb3VudCA9IGFjY291bnRzLmNyZWF0ZShlbSwgZ2V0KCdwdycpLCBuYW1lLCBTdHJpbmcoZ2V0
KCdjYycpKS5yZXBsYWNlKC9bXkEtWl0vZywgJycpLnNsaWNlKDAsIDIpIHx8ICdWTicpOwogICAg
ICBsb2coYGhmOiBuZXcgYWNjb3VudCAke2FjY291bnQuaWR9ICIke2FjY291bnQubmFtZX0iIChy
ZWdpc3RlcmVkKWApOwogICAgICByZXR1cm4gbG9naW5YbWwoYWNjb3VudCwgJ3JlZycpOwogICAg
fQogICAgY29uc3QgYnlJZCA9ICgpID0+IHsKICAgICAgY29uc3QgYWNjb3VudCA9IGFjY291bnRz
LmdldChlbWFpbChnZXQoJ2VtJykpKTsKICAgICAgcmV0dXJuIGFjY291bnQgJiYgU3RyaW5nKGFj
Y291bnQuaWQpID09PSBnZXQoJ2lkJykgJiYgU3RyaW5nKGFjY291bnQuc2Vzc2lvbikgPT09IGdl
dCgnc3MnKSA/IGFjY291bnQgOiBudWxsOwogICAgfTsKICAgIGlmIChzZXJ2aWNlID09PSAnbmFt
ZWNoZ19sZWZ0LnBocCcpIHsKICAgICAgY29uc3QgYWNjb3VudCA9IGFjY291bnRzLmJ5SWQoZ2V0
KCdpZCcpKTsKICAgICAgcmV0dXJuIGA8bmFtZWNoZz48bj4ke2FjY291bnQgPyBhY2NvdW50Lm5h
bWVDaGFuZ2VzIDogMH08L24+PC9uYW1lY2hnPmA7CiAgICB9CiAgICBpZiAoc2VydmljZSA9PT0g
J25hbWVjaGcucGhwJykgewogICAgICBpZiAoIWNoZWNrQ2FwdGNoYShnZXQoJ2MnKSwgZ2V0KCdz
JykpKSByZXR1cm4gJzxuYW1lY2hnPjxlcnJvcj5jb2RlPC9lcnJvcj48L25hbWVjaGc+JzsKICAg
ICAgY29uc3QgYWNjb3VudCA9IGJ5SWQoKTsKICAgICAgaWYgKCFhY2NvdW50KSByZXR1cm4gJzxu
YW1lY2hnPjxlcnJvcj5zYTwvZXJyb3I+PC9uYW1lY2hnPic7CiAgICAgIGlmICghYWNjb3VudHMu
Y2hlY2tQYXNzd29yZChhY2NvdW50LCBnZXQoJ3B3JykpKSB7IGZhaWxlZFRyeShhZGRyZXNzKTsg
cmV0dXJuICc8bmFtZWNoZz48ZXJyb3I+cHdkPC9lcnJvcj48L25hbWVjaGc+JzsgfQogICAgICBj
b25zdCBuYW1lID0gY2xlYW5OYW1lKGdldCgnbm4nKSk7CiAgICAgIGlmICghbmFtZSkgcmV0dXJu
ICc8bmFtZWNoZz48ZXJyb3I+bmFtZTwvZXJyb3I+PC9uYW1lY2hnPic7CiAgICAgIGNvbnN0IG90
aGVyID0gYWNjb3VudHMuYnlOYW1lKG5hbWUpOwogICAgICBpZiAob3RoZXIgJiYgb3RoZXIgIT09
IGFjY291bnQpIHJldHVybiAnPG5hbWVjaGc+PGVycm9yPnNhbWVuYW1lPC9lcnJvcj48L25hbWVj
aGc+JzsKICAgICAgYWNjb3VudC5uYW1lID0gbmFtZTsKICAgICAgYWNjb3VudHMuc2F2ZSgpOwog
ICAgICByZXR1cm4gYDxuYW1lY2hnPjxtPiR7YWNjb3VudC5uYW1lQ2hhbmdlc308L20+PC9uYW1l
Y2hnPmA7CiAgICB9CiAgICBpZiAoc2VydmljZSA9PT0gJ3B3ZGNoZy5waHAnKSB7CiAgICAgIGlm
ICghY2hlY2tDYXB0Y2hhKGdldCgnYycpLCBnZXQoJ3MnKSkpIHJldHVybiAnPHB3ZGNoZz48ZXJy
b3I+Y29kZTwvZXJyb3I+PC9wd2RjaGc+JzsKICAgICAgY29uc3QgYWNjb3VudCA9IGJ5SWQoKTsK
ICAgICAgaWYgKCFhY2NvdW50KSByZXR1cm4gJzxwd2RjaGc+PGVycm9yPnNhPC9lcnJvcj48L3B3
ZGNoZz4nOwogICAgICBpZiAoIWFjY291bnRzLmNoZWNrUGFzc3dvcmQoYWNjb3VudCwgZ2V0KCdw
dycpKSkgeyBmYWlsZWRUcnkoYWRkcmVzcyk7IHJldHVybiAnPHB3ZGNoZz48ZXJyb3I+cHdkPC9l
cnJvcj48L3B3ZGNoZz4nOyB9CiAgICAgIGFjY291bnRzLnNldFBhc3N3b3JkKGFjY291bnQsIGdl
dCgnbnB3JykpOwogICAgICByZXR1cm4gJzxwd2RjaGc+PG9rPjE8L29rPjwvcHdkY2hnPic7CiAg
ICB9CiAgICBpZiAoc2VydmljZSA9PT0gJ3B3ZHJldC5waHAnKSB7CiAgICAgIC8vIE5vIGUtbWFp
bCBnb2VzIG91dCBmcm9tIGhlcmU6IHdob2V2ZXIgcnVucyB0aGUgcmVsYXkgY2FuIHJlbW92ZSB0
aGUgYWNjb3VudCBpbnN0ZWFkLgogICAgICByZXR1cm4gJzxwd2RyZXQ+PGVycm9yPm1haWw8L2Vy
cm9yPjwvcHdkcmV0Pic7CiAgICB9CiAgICByZXR1cm4gbnVsbDsKICB9CgogIGZ1bmN0aW9uIHJv
b21MaXN0WG1sKCkgewogICAgbGV0IHRleHQgPSAnPHJvb21saXN0Pic7CiAgICBmb3IgKGNvbnN0
IHJvb20gb2Ygcm9vbXMpIHsKICAgICAgdGV4dCArPSBgPHJvb20+PHQ+MTwvdD48cm4+JHt4bWxU
ZXh0KHJvb20ubmFtZSl9PC9ybj48ZGM+JHt4bWxUZXh0KHJvb20uZGVzY3JpcHRpb24pfTwvZGM+
PGNjPiR7cm9vbS5jY308L2NjPmAKICAgICAgICArIGA8bj4ke3Jvb20uY29ubmVjdGVkfTwvbj48
bmw+JHtyb29tLmxpbWl0fTwvbmw+PHBwbD4ke3htbFRleHQocm9vbS5wZW9wbGUoKSl9PC9wcGw+
YAogICAgICAgICsgYDxpcD4ke0hPU1R9PC9pcD48cHQ+JHtQT1JUICsgcm9vbS5udW1iZXIgLSAx
fTwvcHQ+PC9yb29tPmA7CiAgICB9CiAgICByZXR1cm4gdGV4dCArICc8L3Jvb21saXN0Pic7CiAg
fQoKICAvLyBSZXR1cm5zIHRydWUgd2hlbiB0aGUgcmVxdWVzdCB3YXMgb25lIG9mIHRoZXNlIGFu
ZCBoYXMgYmVlbiBhbnN3ZXJlZCAob3IgaXMgYmVpbmcgYW5zd2VyZWQpLgogIGZ1bmN0aW9uIGhh
bmRsZShyZXEsIHJlcywgcGF0aG5hbWUpIHsKICAgIGlmICghcGF0aG5hbWUuc3RhcnRzV2l0aCgn
L2hmLycpKSByZXR1cm4gZmFsc2U7CiAgICBjb25zdCBoZWFkZXJzID0geyAnY2FjaGUtY29udHJv
bCc6ICduby1zdG9yZScsICd4LWNvbnRlbnQtdHlwZS1vcHRpb25zJzogJ25vc25pZmYnLCAuLi5h
bGxvd09yaWdpbihyZXEpIH07CiAgICBpZiAocmVxLm1ldGhvZCA9PT0gJ09QVElPTlMnKSB7CiAg
ICAgIHJlcy53cml0ZUhlYWQoMjA0LCB7IC4uLmhlYWRlcnMsICdhY2Nlc3MtY29udHJvbC1hbGxv
dy1tZXRob2RzJzogJ0dFVCwgUE9TVCwgT1BUSU9OUycsICdhY2Nlc3MtY29udHJvbC1hbGxvdy1o
ZWFkZXJzJzogJ2NvbnRlbnQtdHlwZScgfSk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJu
IHRydWU7CiAgICB9CiAgICBjb25zdCBzZW5kID0gKHN0YXR1cywgdHlwZSwgYm9keSkgPT4gewog
ICAgICByZXMud3JpdGVIZWFkKHN0YXR1cywgeyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBlJzog
dHlwZSB9KTsKICAgICAgcmVzLmVuZChib2R5KTsKICAgIH07CiAgICBpZiAocmVxLm1ldGhvZCAh
PT0gJ0dFVCcgJiYgcmVxLm1ldGhvZCAhPT0gJ1BPU1QnKSB7CiAgICAgIHNlbmQoNDA1LCAndGV4
dC9wbGFpbjsgY2hhcnNldD11dGYtOCcsICdtZXRob2Qgbm90IGFsbG93ZWRcbicpOwogICAgICBy
ZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGNvbnN0IHVybCA9IG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6
Ly9yZWxheS5pbnZhbGlkJyk7CiAgICBjb25zdCBsb2NhbCA9IHBhdGhuYW1lLnNsaWNlKCcvaGYv
Jy5sZW5ndGgpOwogICAgaWYgKGxvY2FsID09PSAndmVyLnR4dCcpIHsKICAgICAgc2VuZCgyMDAs
ICd0ZXh0L3htbDsgY2hhcnNldD11dGYtOCcsICc8dmVyPjxyZXMgdmVyc2lvbj0iNzAwIiBsb2Nh
bD0iMCIgLz48L3Zlcj4nKTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBpZiAobG9jYWwg
PT09ICdyb29tcy5qc29uJykgewogICAgICBzZW5kKDIwMCwgJ2FwcGxpY2F0aW9uL2pzb247IGNo
YXJzZXQ9dXRmLTgnLCBKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgaG9zdDogSE9TVCwgcm9vbXM6
IHJvb21zLm1hcCgocm9vbSkgPT4gKHsgcm9vbTogcm9vbS5udW1iZXIsIHBvcnQ6IFBPUlQgKyBy
b29tLm51bWJlciAtIDEsIG5hbWU6IHJvb20ubmFtZSwgcGxheWVyczogcm9vbS5jb25uZWN0ZWQs
IGxpbWl0OiByb29tLmxpbWl0IH0pKSwKICAgICAgfSkpOwogICAgICByZXR1cm4gdHJ1ZTsKICAg
IH0KICAgIGlmIChsb2NhbCA9PT0gJ2hmL3JsZy5waHAnKSB7CiAgICAgIHNlbmQoMjAwLCAndGV4
dC94bWw7IGNoYXJzZXQ9dXRmLTgnLCByb29tTGlzdFhtbCgpKTsKICAgICAgcmV0dXJuIHRydWU7
CiAgICB9CiAgICBpZiAobG9jYWwgPT09ICdzL3ByZW1pdW0nKSB7CiAgICAgIHJlcy5zZXRIZWFk
ZXIoJ2NvbnRlbnQtc2VjdXJpdHktcG9saWN5JywgImRlZmF1bHQtc3JjICdub25lJzsgc3R5bGUt
c3JjICd1bnNhZmUtaW5saW5lJyIpOwogICAgICBzZW5kKDIwMCwgJ3RleHQvaHRtbDsgY2hhcnNl
dD11dGYtOCcsIFBSRU1JVU1fUEFHRSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYg
KGxvY2FsLnN0YXJ0c1dpdGgoJ3MvJykpIHsKICAgICAgLy8gVGhlIGdhbWUgcG9zdHMgaXRzIGZv
cm1zIHdpdGggdGhlIHZhbHVlcyBpbiB0aGUgYWRkcmVzczsgYSBib2R5LCBpZiBhbnksIGlzIHJl
YWQgYXMgYSBmb3JtIHRvby4KICAgICAgbGV0IGJvZHkgPSAnJzsKICAgICAgcmVxLnNldEVuY29k
aW5nKCd1dGY4Jyk7CiAgICAgIHJlcS5vbignZGF0YScsIChjaHVuaykgPT4geyBpZiAoYm9keS5s
ZW5ndGggPCA4MTkyKSBib2R5ICs9IGNodW5rOyB9KTsKICAgICAgcmVxLm9uKCdlbmQnLCAoKSA9
PiB7CiAgICAgICAgY29uc3QgcGFyYW1zID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh1cmwuc2VhcmNo
KTsKICAgICAgICBpZiAoYm9keSAmJiAvXltcdyUuKz0mLV0qJC8udGVzdChib2R5KSkgZm9yIChj
b25zdCBba2V5LCB2YWx1ZV0gb2YgbmV3IFVSTFNlYXJjaFBhcmFtcyhib2R5KSkgaWYgKCFwYXJh
bXMuaGFzKGtleSkpIHBhcmFtcy5zZXQoa2V5LCB2YWx1ZSk7CiAgICAgICAgbGV0IHJlcGx5Owog
ICAgICAgIHRyeSB7CiAgICAgICAgICByZXBseSA9IGFuc3dlcihsb2NhbC5zbGljZSgyKSwgcGFy
YW1zLCBjbGllbnRBZGRyZXNzKHJlcSkpOwogICAgICAgIH0gY2F0Y2ggKGVycm9yKSB7CiAgICAg
ICAgICBsb2coYGhmOiAke2xvY2FsfTogJHtlcnJvci5zdGFjayB8fCBlcnJvcn1gKTsKICAgICAg
ICAgIHJlcGx5ID0gJzxlcnJvcj48ZXJyb3I+c2VydmVyPC9lcnJvcj48L2Vycm9yPic7CiAgICAg
ICAgfQogICAgICAgIGlmIChyZXBseSA9PT0gbnVsbCkgc2VuZCg0MDQsICd0ZXh0L3BsYWluOyBj
aGFyc2V0PXV0Zi04JywgJ25vdCBmb3VuZFxuJyk7CiAgICAgICAgZWxzZSBzZW5kKDIwMCwgJ3Rl
eHQveG1sOyBjaGFyc2V0PXV0Zi04JywgcmVwbHkpOwogICAgICB9KTsKICAgICAgcmV0dXJuIHRy
dWU7CiAgICB9CiAgICBzZW5kKDQwNCwgJ3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnLCAnbm90
IGZvdW5kXG4nKTsKICAgIHJldHVybiB0cnVlOwogIH0KCiAgLy8gQSBnYW1lJ3Mgc29ja2V0IHRv
IHJvb20gbiwgdGhyb3VnaCB0aGUgcGFnZSdzIFdlYlNvY2tldDogaXRzIGJ5dGVzIGFzIGJpbmFy
eSBtZXNzYWdlcyBib3RoIHdheXMuIEEgcGFnZQogIC8vIHdpdGggZGlyZWN0PTEgKGRpc3QvcGFn
ZXMvaGYtZGlyZWN0LmpzKSBhbHNvIHBhc3NlcyB0aGUgZ2FtZSdzIGZyYW1lcyB0byB0aGUgb3Ro
ZXIgcGFnZXMgb2YgdGhlIHJvb20KICAvLyBkaXJlY3RseTsgaXRzIG93biBtZXNzYWdlcyBmb3Ig
dGhhdCBhcmUgdGV4dCAoSlNPTiksIGJvdGggd2F5cy4KICBmdW5jdGlvbiBjb25uZWN0KHdzLCBy
ZXEsIHVybCkgewogICAgY29uc3QgbnVtYmVyID0gTnVtYmVyKHVybC5zZWFyY2hQYXJhbXMuZ2V0
KCdyb29tJykpOwogICAgY29uc3Qgcm9vbSA9IHJvb21zW251bWJlciAtIDFdOwogICAgaWYgKCFO
dW1iZXIuaXNJbnRlZ2VyKG51bWJlcikgfHwgIXJvb20pIHsKICAgICAgd3MuY2xvc2UoNDAwMCwg
J1JlbGF5OiBubyBzdWNoIEhlcm8gRmlnaHRlciByb29tJyk7CiAgICAgIHJldHVybjsKICAgIH0K
ICAgIGNvbnN0IGRpcmVjdCA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdkaXJlY3QnKSA9PT0gJzEn
OwogICAgY29uc3QgaWQgPSBkaXJlY3QgPyBjcnlwdG8ucmFuZG9tQnl0ZXMoNikudG9TdHJpbmco
J2hleCcpIDogJyc7CiAgICBjb25zdCBjb25uZWN0aW9uID0gbmV3IEhmQ29ubmVjdGlvbihyb29t
LCB7CiAgICAgIHdyaXRlKHRleHQpIHsKICAgICAgICBpZiAod3MucmVhZHlTdGF0ZSAhPT0gMSkg
cmV0dXJuOwogICAgICAgIGlmICh3cy5idWZmZXJlZEFtb3VudCA+IGNvbmZpZy5tYXhCdWZmZXJl
ZEJ5dGVzKSB7CiAgICAgICAgICB3cy5jbG9zZSg0MDE2LCAnUmVsYXk6IHlvdXIgY29ubmVjdGlv
biBpcyB0b28gc2xvdyBmb3IgdGhlIGdhbWUnKTsKICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgd3Muc2VuZChCdWZmZXIuZnJvbSh0ZXh0LCAndXRmOCcpLCB7IGJpbmFyeTogdHJ1
ZSB9KTsKICAgICAgfSwKICAgICAgc2F5KG1lc3NhZ2UpIHsgaWYgKHdzLnJlYWR5U3RhdGUgPT09
IDEpIHdzLnNlbmQoSlNPTi5zdHJpbmdpZnkobWVzc2FnZSkpOyB9LAogICAgICBjbG9zZSgpIHsg
aWYgKHdzLnJlYWR5U3RhdGUgPT09IDAgfHwgd3MucmVhZHlTdGF0ZSA9PT0gMSkgd3MuY2xvc2Uo
MTAwMCwgJ1JlbGF5OiByb29tIGxlZnQnKTsgfSwKICAgIH0sIHsgYWRkcmVzczogY2xpZW50QWRk
cmVzcyhyZXEpLCBidWlsZDogU3RyaW5nKHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdidWlsZCcpIHx8
ICcnKS5yZXBsYWNlKC9bXlx3ListXS9nLCAnJykuc2xpY2UoMCwgODApLCBpZCwgZGlyZWN0IH0p
OwogICAgaWYgKGRpcmVjdCkgd3Muc2VuZChKU09OLnN0cmluZ2lmeSh7IHQ6ICdoZWxsbycsIHY6
IDEsIGlkIH0pKTsKICAgIHdzLm9uKCdtZXNzYWdlJywgKGRhdGEsIGlzQmluYXJ5KSA9PiB7CiAg
ICAgIGlmIChidWRnZXQgJiYgIWJ1ZGdldCh3cywgZGF0YS5sZW5ndGgpKSB7CiAgICAgICAgd3Mu
Y2xvc2UoNDAwNywgJ1JlbGF5OiB0b28gbXVjaCB0cmFmZmljJyk7CiAgICAgICAgcmV0dXJuOwog
ICAgICB9CiAgICAgIGNvbnN0IGJ5dGVzID0gQnVmZmVyLmlzQnVmZmVyKGRhdGEpID8gZGF0YSA6
IEJ1ZmZlci5mcm9tKGRhdGEpOwogICAgICBpZiAoZGlyZWN0ICYmIGlzQmluYXJ5ID09PSBmYWxz
ZSkgY29ubmVjdGlvbi5jb250cm9sKGJ5dGVzLnRvU3RyaW5nKCd1dGY4JykpOwogICAgICBlbHNl
IGNvbm5lY3Rpb24ucmVjZWl2ZShieXRlcyk7CiAgICB9KTsKICAgIHdzLm9uKCdjbG9zZScsICgp
ID0+IGNvbm5lY3Rpb24uY2xvc2VkKCkpOwogIH0KCiAgcmV0dXJuIHsKICAgIGhhbmRsZSwKICAg
IGNvbm5lY3QsCiAgICByb29tcywKICAgIGFjY291bnRzLAogICAgZGVzY3JpYmU6ICgpID0+ICh7
IHJvb21zOiByb29tcy5sZW5ndGgsIHBsYXllcnM6IHJvb21zLnJlZHVjZSgoc3VtLCByb29tKSA9
PiBzdW0gKyByb29tLmNvbm5lY3RlZCwgMCkgfSksCiAgICAvLyBUaGUgcm9vbXMnIGpvdXJuYWxz
IChqb2lucywgZmlnaHRzLCBwYXVzZXMsIG91dC1vZi1zdGVwIGR1bXBzKSwgbmV3ZXN0IHJvb20g
ZW50cmllcyBsYXN0LCBhcyB0ZXh0LgogICAgam91cm5hbDogKCkgPT4gcm9vbXMubWFwKChyb29t
KSA9PiBgPT0gJHtyb29tLm5hbWV9ICgke3Jvb20uY29ubmVjdGVkfSBwbGF5aW5nKVxuJHtyb29t
LmpvdXJuYWwuam9pbignXG4nKSB8fCAnKG5vdGhpbmcgeWV0KSd9YCkuam9pbignXG5cbicpICsg
J1xuJywKICAgIGNsb3NlKCkgewogICAgICBjbGVhckludGVydmFsKHBydW5lVGltZXIpOwogICAg
ICBmb3IgKGNvbnN0IHJvb20gb2Ygcm9vbXMpIHJvb20uY2xvc2UoKTsKICAgICAgYWNjb3VudHMu
Zmx1c2goKTsKICAgIH0sCiAgfTsKfQoKLy8gVGhlIGFkZHJlc3MgdGhlIGdhbWUgaXMgZ2l2ZW4g
Zm9yIHRoZSByb29tczogYW55IG5hbWUgd29ya3MsIHRoZSBwYWdlJ3Mgc29ja2V0IHByb3h5IG1h
cHMgaXQgKHdpdGgKLy8gdGhlIHBvcnQsIG9uZSBwZXIgcm9vbSkgdG8gdGhlIHJlbGF5J3MgV2Vi
U29ja2V0Lgpjb25zdCBIT1NUID0gJ2hmLm9wZW5sZjInOwpjb25zdCBQT1JUID0gODg4ODsKCm1v
ZHVsZS5leHBvcnRzID0geyBjcmVhdGVIZiwgc3RhdHVzQ29kZSwgZW5jb2RlTnVtYmVyLCBzZXR0
bGVkVmFsdWVzLCBMT0NLRUQsIEhPU1QsIFBPUlQgfTsK
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
