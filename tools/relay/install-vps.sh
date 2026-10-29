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

INSTALLER_VERSION=7
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
ICAgaWYgKGl0ZW0uZW50cnkuc2l6ZSA+IDY0ICogTUlCKSB0aHJvdyBuZXcgUGFja0Vycm9yKGAk
e2l0ZW0uZW50cnkubmFtZX0gaXMgbGFyZ2VyIHRoYW4gNjQgTUJgKTsKICAgIGtlZXAucHVzaChp
dGVtLmVudHJ5KTsKICB9CiAgcmV0dXJuIHsgcm9vdCwgZXhlY3V0YWJsZTogbWFpbi5wYXRoLCBr
ZWVwLCBkcm9wcGVkOiBlbnRyaWVzLmxlbmd0aCAtIGtlZXAubGVuZ3RoIH07Cn0KCi8vIC0tLS0g
Rmxhc2ggZ2FtZXMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQovLyBBIEZsYXNoIHByb2plY3Rv
ciAoRmxhc2ggUGxheWVyIGZvciBXaW5kb3dzIHdpdGggYSBtb3ZpZSBpbnNpZGUpIGVuZHMgd2l0
aCAweEZBMTIzNDU2IGFuZCB0aGUgbW92aWUncwovLyBsZW5ndGggKGJvdGggNCBieXRlcywgbGl0
dGxlIGVuZGlhbiksIHRoZSBtb3ZpZSBqdXN0IGJlZm9yZS4KY29uc3QgUFJPSkVDVE9SX01BR0lD
ID0gMHhmYTEyMzQ1NjsKLy8gSGVybyBGaWdodGVyJ3MgbW92aWVzOiB0aGUgb25lIGluICJIRnYw
LjcrLmV4ZSIgKEhlcm8gRmlnaHRlciB2MC43KywgMjAyMS0xMC0xMSkuCmNvbnN0IEhFUk9fRklH
SFRFUiA9IG5ldyBTZXQoWyc0MmFlYzVlNjgzYmRjYWJkNWNhZjYxODFiZTVmZTc0NjE4YWZlNTM2
ZWM2MjAzMDczNGQ5NTM2ZmFiMTg1MmE4J10pOwpjb25zdCBIRVJPX0ZJR0hURVJfTUFSSyA9IEJ1
ZmZlci5mcm9tKCdodHRwOi8vd3d3Lmhlcm9maWdodGVyLmNvbS92ZXIudHh0JywgJ2xhdGluMScp
OwoKZnVuY3Rpb24gaXNTd2YoYnl0ZXMpIHsKICByZXR1cm4gYnl0ZXMubGVuZ3RoID4gOCAmJiBb
J0ZXUycsICdDV1MnLCAnWldTJ10uaW5jbHVkZXMoYnl0ZXMudG9TdHJpbmcoJ2xhdGluMScsIDAs
IDMpKTsKfQoKLy8gVGhlIG1vdmllIG9mIGEgcHJvamVjdG9yIG9yIG9mIGEgbW92aWUgZmlsZTsg
bnVsbCBmb3IgYW55dGhpbmcgZWxzZS4KZnVuY3Rpb24gbW92aWVPZihieXRlcykgewogIGlmIChp
c1N3ZihieXRlcykpIHJldHVybiBieXRlczsKICBpZiAoYnl0ZXMubGVuZ3RoIDwgMTYgfHwgYnl0
ZXMudG9TdHJpbmcoJ2xhdGluMScsIDAsIDIpICE9PSAnTVonKSByZXR1cm4gbnVsbDsKICBpZiAo
Ynl0ZXMucmVhZFVJbnQzMkxFKGJ5dGVzLmxlbmd0aCAtIDgpICE9PSBQUk9KRUNUT1JfTUFHSUMp
IHJldHVybiBudWxsOwogIGNvbnN0IGxlbmd0aCA9IGJ5dGVzLnJlYWRVSW50MzJMRShieXRlcy5s
ZW5ndGggLSA0KTsKICBpZiAobGVuZ3RoIDwgOSB8fCBsZW5ndGggPiBieXRlcy5sZW5ndGggLSA4
KSByZXR1cm4gbnVsbDsKICBjb25zdCBtb3ZpZSA9IGJ5dGVzLnN1YmFycmF5KGJ5dGVzLmxlbmd0
aCAtIDggLSBsZW5ndGgsIGJ5dGVzLmxlbmd0aCAtIDgpOwogIHJldHVybiBpc1N3Zihtb3ZpZSkg
PyBtb3ZpZSA6IG51bGw7Cn0KCi8vIFdoaWNoIGdhbWUgYSBtb3ZpZSBpczogImhlcm9maWdodGVy
Iiwgb3IgIiIgZm9yIG9uZSB0aGlzIHJlbGF5IGRvZXMgbm90IGtub3cuCmZ1bmN0aW9uIGZsYXNo
R2FtZShtb3ZpZSkgewogIGNvbnN0IHNoYTI1NiA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYn
KS51cGRhdGUobW92aWUpLmRpZ2VzdCgnaGV4Jyk7CiAgaWYgKEhFUk9fRklHSFRFUi5oYXMoc2hh
MjU2KSkgcmV0dXJuICdoZXJvZmlnaHRlcic7CiAgLy8gQW4gdW5jb21wcmVzc2VkIG1vdmllIGNh
biBiZSBzZWFyY2hlZCBhcyBpdCBpcyAoSGVybyBGaWdodGVyJ3MgcHJvamVjdG9yIG1vdmllcyBh
cmUpLgogIGlmIChtb3ZpZS50b1N0cmluZygnbGF0aW4xJywgMCwgMykgPT09ICdGV1MnICYmIG1v
dmllLmluY2x1ZGVzKEhFUk9fRklHSFRFUl9NQVJLKSkgcmV0dXJuICdoZXJvZmlnaHRlcic7CiAg
cmV0dXJuICcnOwp9CgovLyBBbiBlbnRyeSdzIGJ5dGVzIChzdG9yZWQgb3IgRGVmbGF0ZSkuCmFz
eW5jIGZ1bmN0aW9uIHJlYWRFbnRyeShmaWxlLCBlbnRyeSkgewogIGNvbnN0IGhhbmRsZSA9IGF3
YWl0IGZzcC5vcGVuKGZpbGUsICdyJyk7CiAgdHJ5IHsKICAgIGNvbnN0IGhlYWRlciA9IEJ1ZmZl
ci5hbGxvYygzMCk7CiAgICBhd2FpdCBoYW5kbGUucmVhZChoZWFkZXIsIDAsIDMwLCBlbnRyeS5s
b2NhbE9mZnNldCk7CiAgICBpZiAoaGVhZGVyLnJlYWRVSW50MzJMRSgwKSAhPT0gMHgwNDAzNGI1
MCkgdGhyb3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgIGNv
bnN0IHN0YXJ0ID0gZW50cnkubG9jYWxPZmZzZXQgKyAzMCArIGhlYWRlci5yZWFkVUludDE2TEUo
MjYpICsgaGVhZGVyLnJlYWRVSW50MTZMRSgyOCk7CiAgICBjb25zdCBwYWNrZWQgPSBCdWZmZXIu
YWxsb2MoZW50cnkuY29tcHJlc3NlZFNpemUpOwogICAgYXdhaXQgaGFuZGxlLnJlYWQocGFja2Vk
LCAwLCBwYWNrZWQubGVuZ3RoLCBzdGFydCk7CiAgICBpZiAoZW50cnkubWV0aG9kID09PSAwKSBy
ZXR1cm4gcGFja2VkOwogICAgaWYgKGVudHJ5Lm1ldGhvZCA9PT0gOCkgcmV0dXJuIHpsaWIuaW5m
bGF0ZVJhd1N5bmMocGFja2VkLCB7IG1heE91dHB1dExlbmd0aDogNTEyICogTUlCIH0pOwogICAg
dGhyb3cgbmV3IFBhY2tFcnJvcihgJHtlbnRyeS5uYW1lfSB1c2VzIGEgY29tcHJlc3Npb24gdGhl
IHJlbGF5IGNhbm5vdCByZWFkICh6aXAgaXQgYWdhaW4gd2l0aCBEZWZsYXRlKWApOwogIH0gZmlu
YWxseSB7CiAgICBhd2FpdCBoYW5kbGUuY2xvc2UoKTsKICB9Cn0KCi8vIFRoZSBGbGFzaCBtb3Zp
ZSBhbiB1cGxvYWQgaG9sZHMgKGEgbW92aWUgb3IgcHJvamVjdG9yIGZpbGUsIG9yIGEgWklQIGZp
bGUgd2l0aCBvbmUpLCBvciBudWxsLgphc3luYyBmdW5jdGlvbiBmaW5kTW92aWUoZmlsZSwgemlw
KSB7CiAgaWYgKCF6aXApIHsKICAgIGNvbnN0IHsgc2l6ZSB9ID0gYXdhaXQgZnNwLnN0YXQoZmls
ZSk7CiAgICBpZiAoc2l6ZSA+IDUxMiAqIE1JQikgcmV0dXJuIG51bGw7CiAgICByZXR1cm4gbW92
aWVPZihhd2FpdCBmc3AucmVhZEZpbGUoZmlsZSkpOwogIH0KICBjb25zdCBjYW5kaWRhdGVzID0g
emlwLmVudHJpZXMKICAgIC5maWx0ZXIoKGVudHJ5KSA9PiAvXC4oc3dmfGV4ZSkkL2kudGVzdChl
bnRyeS5uYW1lKSAmJiAhKGVudHJ5LmZsYWdzICYgMSkgJiYgZW50cnkuc2l6ZSA8PSA1MTIgKiBN
SUIpCiAgICAuc29ydCgoYSwgYikgPT4gYi5zaXplIC0gYS5zaXplKTsKICBmb3IgKGNvbnN0IGVu
dHJ5IG9mIGNhbmRpZGF0ZXMpIHsKICAgIGNvbnN0IG1vdmllID0gbW92aWVPZihhd2FpdCByZWFk
RW50cnkoZmlsZSwgZW50cnkpKTsKICAgIGlmIChtb3ZpZSkgcmV0dXJuIG1vdmllOwogIH0KICBy
ZXR1cm4gbnVsbDsKfQoKLy8gV3JpdGVzIHRoZSBrZXB0IGVudHJpZXMgb2YgYHNvdXJjZWAgYXMg
YSBuZXcgWklQIGZpbGUsIGNvcHlpbmcgdGhlaXIgY29tcHJlc3NlZCBieXRlcyBhcyB0aGV5IGFy
ZS4KYXN5bmMgZnVuY3Rpb24gd3JpdGVaaXAoc291cmNlLCB0YXJnZXQsIGtlZXApIHsKICBjb25z
dCBpbnB1dCA9IGF3YWl0IGZzcC5vcGVuKHNvdXJjZSwgJ3InKTsKICBjb25zdCBvdXRwdXQgPSBh
d2FpdCBmc3Aub3Blbih0YXJnZXQsICd3Jyk7CiAgY29uc3QgaGFzaCA9IGNyeXB0by5jcmVhdGVI
YXNoKCdzaGEyNTYnKTsKICBsZXQgb2Zmc2V0ID0gMDsKICBjb25zdCB3cml0ZSA9IGFzeW5jIChi
dWZmZXIpID0+IHsKICAgIGxldCBkb25lID0gMDsKICAgIHdoaWxlIChkb25lIDwgYnVmZmVyLmxl
bmd0aCkgewogICAgICBjb25zdCB7IGJ5dGVzV3JpdHRlbiB9ID0gYXdhaXQgb3V0cHV0LndyaXRl
KGJ1ZmZlciwgZG9uZSwgYnVmZmVyLmxlbmd0aCAtIGRvbmUsIG9mZnNldCArIGRvbmUpOwogICAg
ICBkb25lICs9IGJ5dGVzV3JpdHRlbjsKICAgIH0KICAgIGhhc2gudXBkYXRlKGJ1ZmZlcik7CiAg
ICBvZmZzZXQgKz0gYnVmZmVyLmxlbmd0aDsKICB9OwogIHRyeSB7CiAgICBjb25zdCByZWNvcmRz
ID0gW107CiAgICBmb3IgKGNvbnN0IGVudHJ5IG9mIGtlZXApIHsKICAgICAgY29uc3QgaGVhZGVy
ID0gQnVmZmVyLmFsbG9jKDMwKTsKICAgICAgYXdhaXQgaW5wdXQucmVhZChoZWFkZXIsIDAsIDMw
LCBlbnRyeS5sb2NhbE9mZnNldCk7CiAgICAgIGlmIChoZWFkZXIucmVhZFVJbnQzMkxFKDApICE9
PSAweDA0MDM0YjUwKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGUgWklQIGZpbGUgaXMgZGFtYWdl
ZCcpOwogICAgICBsZXQgbGVuZ3RoID0gMzAgKyBoZWFkZXIucmVhZFVJbnQxNkxFKDI2KSArIGhl
YWRlci5yZWFkVUludDE2TEUoMjgpICsgZW50cnkuY29tcHJlc3NlZFNpemU7CiAgICAgIGlmIChl
bnRyeS5mbGFncyAmIDgpIHsgLy8gYSBkYXRhIGRlc2NyaXB0b3IgZm9sbG93cyB0aGUgZGF0YQog
ICAgICAgIGNvbnN0IHByb2JlID0gQnVmZmVyLmFsbG9jKDQpOwogICAgICAgIGF3YWl0IGlucHV0
LnJlYWQocHJvYmUsIDAsIDQsIGVudHJ5LmxvY2FsT2Zmc2V0ICsgbGVuZ3RoKTsKICAgICAgICBs
ZW5ndGggKz0gcHJvYmUucmVhZFVJbnQzMkxFKDApID09PSAweDA4MDc0YjUwID8gMTYgOiAxMjsK
ICAgICAgfQogICAgICBjb25zdCByZWNvcmQgPSBCdWZmZXIuZnJvbShlbnRyeS5yZWNvcmQpOwog
ICAgICByZWNvcmQud3JpdGVVSW50MzJMRShvZmZzZXQsIDQyKTsKICAgICAgcmVjb3Jkcy5wdXNo
KHJlY29yZCk7CiAgICAgIGZvciAobGV0IGNvcGllZCA9IDA7IGNvcGllZCA8IGxlbmd0aDspIHsK
ICAgICAgICBjb25zdCBjaHVuayA9IEJ1ZmZlci5hbGxvYyhNYXRoLm1pbig0ICogTUlCLCBsZW5n
dGggLSBjb3BpZWQpKTsKICAgICAgICBjb25zdCB7IGJ5dGVzUmVhZCB9ID0gYXdhaXQgaW5wdXQu
cmVhZChjaHVuaywgMCwgY2h1bmsubGVuZ3RoLCBlbnRyeS5sb2NhbE9mZnNldCArIGNvcGllZCk7
CiAgICAgICAgaWYgKCFieXRlc1JlYWQpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAgZmls
ZSBpcyBkYW1hZ2VkJyk7CiAgICAgICAgYXdhaXQgd3JpdGUoY2h1bmsuc3ViYXJyYXkoMCwgYnl0
ZXNSZWFkKSk7CiAgICAgICAgY29waWVkICs9IGJ5dGVzUmVhZDsKICAgICAgfQogICAgfQogICAg
Y29uc3QgZGlyZWN0b3J5T2Zmc2V0ID0gb2Zmc2V0OwogICAgZm9yIChjb25zdCByZWNvcmQgb2Yg
cmVjb3JkcykgYXdhaXQgd3JpdGUocmVjb3JkKTsKICAgIGNvbnN0IGVuZCA9IEJ1ZmZlci5hbGxv
YygyMik7CiAgICBlbmQud3JpdGVVSW50MzJMRSgweDA2MDU0YjUwLCAwKTsKICAgIGVuZC53cml0
ZVVJbnQxNkxFKHJlY29yZHMubGVuZ3RoLCA4KTsKICAgIGVuZC53cml0ZVVJbnQxNkxFKHJlY29y
ZHMubGVuZ3RoLCAxMCk7CiAgICBlbmQud3JpdGVVSW50MzJMRShvZmZzZXQgLSBkaXJlY3RvcnlP
ZmZzZXQsIDEyKTsKICAgIGVuZC53cml0ZVVJbnQzMkxFKGRpcmVjdG9yeU9mZnNldCwgMTYpOwog
ICAgYXdhaXQgd3JpdGUoZW5kKTsKICAgIHJldHVybiB7IHNpemU6IG9mZnNldCwgc2hhMjU2OiBo
YXNoLmRpZ2VzdCgnaGV4JyksIGZpbGVzOiByZWNvcmRzLmxlbmd0aCB9OwogIH0gZmluYWxseSB7
CiAgICBhd2FpdCBpbnB1dC5jbG9zZSgpOwogICAgYXdhaXQgb3V0cHV0LmNsb3NlKCk7CiAgfQp9
CgpmdW5jdGlvbiBzYW1lS2V5KGdpdmVuLCBleHBlY3RlZCkgewogIGNvbnN0IGEgPSBjcnlwdG8u
Y3JlYXRlSGFzaCgnc2hhMjU2JykudXBkYXRlKFN0cmluZyhnaXZlbiB8fCAnJykpLmRpZ2VzdCgp
OwogIGNvbnN0IGIgPSBjcnlwdG8uY3JlYXRlSGFzaCgnc2hhMjU2JykudXBkYXRlKFN0cmluZyhl
eHBlY3RlZCkpLmRpZ2VzdCgpOwogIHJldHVybiBjcnlwdG8udGltaW5nU2FmZUVxdWFsKGEsIGIp
Owp9CgpmdW5jdGlvbiBjcmVhdGVQYWNrcyhjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzLCBh
bGxvd09yaWdpbiB9KSB7CiAgY29uc3QgZGlyZWN0b3J5ID0gY29uZmlnLnBhY2tzRGlyOwogIGNv
bnN0IGRvd25sb2FkcyA9IG5ldyBNYXAoKTsgLy8gY2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwg
dW50aWwgfQogIGNvbnN0IGZhaWx1cmVzID0gbmV3IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVzcyAt
PiB7IGNvdW50LCB1bnRpbCB9CiAgbGV0IHVwbG9hZGluZyA9IGZhbHNlOwoKICBjb25zdCBqc29u
ID0gKHJlcywgc3RhdHVzLCBib2R5LCBoZWFkZXJzID0ge30pID0+IHsKICAgIHJlcy53cml0ZUhl
YWQoc3RhdHVzLCB7ICdjb250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11
dGYtOCcsICdjYWNoZS1jb250cm9sJzogJ25vLXN0b3JlJywgLi4uaGVhZGVycyB9KTsKICAgIHJl
cy5lbmQoSlNPTi5zdHJpbmdpZnkoYm9keSkpOwogIH07CiAgY29uc3QgY291bnRlZCA9IChtYXAs
IGFkZHJlc3MsIGxpbWl0KSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgbGV0
IGVudHJ5ID0gbWFwLmdldChhZGRyZXNzKTsKICAgIGlmICghZW50cnkgfHwgZW50cnkudW50aWwg
PD0gbm93KSB7CiAgICAgIGVudHJ5ID0geyBjb3VudDogMCwgdW50aWw6IG5vdyArIDM2MDAwMDAg
fTsKICAgICAgbWFwLnNldChhZGRyZXNzLCBlbnRyeSk7CiAgICB9CiAgICByZXR1cm4geyBvdmVy
OiBsaW1pdCA+IDAgJiYgZW50cnkuY291bnQgPj0gbGltaXQsIGFkZDogKCkgPT4geyBlbnRyeS5j
b3VudCArPSAxOyB9LCByZXRyeTogTWF0aC5jZWlsKChlbnRyeS51bnRpbCAtIG5vdykgLyAxMDAw
KSB9OwogIH07CgogIGFzeW5jIGZ1bmN0aW9uIGxpc3QoKSB7CiAgICBpZiAoIWRpcmVjdG9yeSkg
cmV0dXJuIFtdOwogICAgbGV0IG5hbWVzOwogICAgdHJ5IHsgbmFtZXMgPSBhd2FpdCBmc3AucmVh
ZGRpcihkaXJlY3RvcnkpOyB9IGNhdGNoIHsgcmV0dXJuIFtdOyB9CiAgICBjb25zdCBwYWNrcyA9
IFtdOwogICAgZm9yIChjb25zdCBuYW1lIG9mIG5hbWVzKSB7CiAgICAgIGlmICghbmFtZS5lbmRz
V2l0aCgnLmpzb24nKSkgY29udGludWU7CiAgICAgIGNvbnN0IGlkID0gbmFtZS5zbGljZSgwLCAt
NSk7CiAgICAgIGlmICghUEFDS19JRC50ZXN0KGlkKSkgY29udGludWU7CiAgICAgIHRyeSB7CiAg
ICAgICAgY29uc3QgaW5mbyA9IEpTT04ucGFyc2UoYXdhaXQgZnNwLnJlYWRGaWxlKHBhdGguam9p
bihkaXJlY3RvcnksIG5hbWUpLCAndXRmOCcpKTsKICAgICAgICBjb25zdCBraW5kID0gaW5mby5r
aW5kID09PSAnZmxhc2gnID8gJ2ZsYXNoJyA6ICdsZjInOwogICAgICAgIGNvbnN0IHN0YXQgPSBh
d2FpdCBmc3Auc3RhdChwYXRoLmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uJHtraW5kID09PSAnZmxh
c2gnID8gJ3N3ZicgOiAnemlwJ31gKSk7CiAgICAgICAgcGFja3MucHVzaCh7IGlkLCB0aXRsZTog
U3RyaW5nKGluZm8udGl0bGUgfHwgaWQpLCBzaXplOiBzdGF0LnNpemUsIHNoYTI1NjogU3RyaW5n
KGluZm8uc2hhMjU2IHx8ICcnKSwKICAgICAgICAgIGtpbmQsIGdhbWU6IFN0cmluZyhpbmZvLmdh
bWUgfHwgJycpLCBmaWxlczogaW5mby5maWxlcywgdXBsb2FkZWQ6IGluZm8udXBsb2FkZWQsIG9y
aWdpbmFsOiBpbmZvLm9yaWdpbmFsIH0pOwogICAgICB9IGNhdGNoIHsgLyogYSBoYWxmLXdyaXR0
ZW4gb3IgcmVtb3ZlZCBwYWNrICovIH0KICAgIH0KICAgIHJldHVybiBwYWNrcy5zb3J0KChhLCBi
KSA9PiBhLnRpdGxlLmxvY2FsZUNvbXBhcmUoYi50aXRsZSkpOwogIH0KCiAgZnVuY3Rpb24gYXV0
aG9yaXplZChyZXEsIHJlcykgewogICAgaWYgKCFjb25maWcuYWRtaW5LZXkpIHsKICAgICAganNv
bihyZXMsIDQwMywgeyBlcnJvcjogJ0NoxrBhIMSR4bq3dCBBRE1JTl9LRVkgY2hvIHJlbGF5IChj
aOG6oXkgbOG6oWkgaW5zdGFsbC12cHMuc2gpLicgfSk7CiAgICAgIHJldHVybiBmYWxzZTsKICAg
IH0KICAgIGNvbnN0IGFkZHJlc3MgPSBjbGllbnRBZGRyZXNzKHJlcSk7CiAgICBjb25zdCB0cmll
cyA9IGNvdW50ZWQoZmFpbHVyZXMsIGFkZHJlc3MsIDIwKTsKICAgIGlmICh0cmllcy5vdmVyKSB7
CiAgICAgIGpzb24ocmVzLCA0MjksIHsgZXJyb3I6ICdTYWkgbcOjIHF1w6Egbmhp4buBdSBs4bqn
biwgdGjhu60gbOG6oWkgc2F1IG3hu5l0IGdp4budLicgfSwgeyAncmV0cnktYWZ0ZXInOiBTdHJp
bmcodHJpZXMucmV0cnkpIH0pOwogICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgICBpZiAoIXNh
bWVLZXkocmVxLmhlYWRlcnNbJ3gtYWRtaW4ta2V5J10sIGNvbmZpZy5hZG1pbktleSkpIHsKICAg
ICAgdHJpZXMuYWRkKCk7CiAgICAgIGpzb24ocmVzLCA0MDEsIHsgZXJyb3I6ICdTYWkgbcOjIHF1
4bqjbiB0cuG7iyAoQURNSU5fS0VZKS4nIH0pOwogICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAg
ICByZXR1cm4gdHJ1ZTsKICB9CgogIGFzeW5jIGZ1bmN0aW9uIHVwbG9hZChyZXEsIHJlcywgaWQs
IHRpdGxlKSB7CiAgICBpZiAoIWRpcmVjdG9yeSkgcmV0dXJuIGpzb24ocmVzLCA1MDMsIHsgZXJy
b3I6ICdSZWxheSBuw6B5IGtow7RuZyBnaeG7ryBi4bqjbiBtb2QgKGNoxrBhIMSR4bq3dCBQQUNL
U19ESVIpLicgfSk7CiAgICBpZiAodXBsb2FkaW5nKSByZXR1cm4ganNvbihyZXMsIDQwOSwgeyBl
cnJvcjogJ8SQYW5nIGPDsyBt4buZdCBs4bqnbiB04bqjaSBsw6puIGtow6FjLCBjaOG7nSB4b25n
IHLhu5NpIHRo4butIGzhuqFpLicgfSk7CiAgICBjb25zdCBkZWNsYXJlZCA9IE51bWJlcihyZXEu
aGVhZGVyc1snY29udGVudC1sZW5ndGgnXSB8fCAwKTsKICAgIGlmIChkZWNsYXJlZCA+IGNvbmZp
Zy5tYXhQYWNrQnl0ZXMpIHsKICAgICAgcmV0dXJuIGpzb24ocmVzLCA0MTMsIHsgZXJyb3I6IGBG
aWxlIHF1w6EgbOG7m24gKHThu5FpIMSRYSAke01hdGgucm91bmQoY29uZmlnLm1heFBhY2tCeXRl
cyAvIE1JQil9IE1CKS5gIH0pOwogICAgfQogICAgYXdhaXQgZnNwLm1rZGlyKGRpcmVjdG9yeSwg
eyByZWN1cnNpdmU6IHRydWUgfSk7CiAgICB0cnkgewogICAgICBjb25zdCBzcGFjZSA9IGF3YWl0
IGZzcC5zdGF0ZnMoZGlyZWN0b3J5KTsKICAgICAgY29uc3QgZnJlZSA9IHNwYWNlLmJhdmFpbCAq
IHNwYWNlLmJzaXplOwogICAgICBpZiAoZnJlZSA8IDIgKiBkZWNsYXJlZCArIDI1NiAqIE1JQikg
ewogICAgICAgIHJldHVybiBqc29uKHJlcywgNTA3LCB7IGVycm9yOiBgVlBTIGtow7RuZyDEkeG7
pyBjaOG7lyB0cuG7kW5nIChjw7JuICR7TWF0aC5yb3VuZChmcmVlIC8gTUlCKX0gTUIpLmAgfSk7
CiAgICAgIH0KICAgIH0gY2F0Y2ggeyAvKiBzdGF0ZnMgdW5hdmFpbGFibGU6IHRyeSBhbnl3YXkg
Ki8gfQogICAgdXBsb2FkaW5nID0gdHJ1ZTsKICAgIGNvbnN0IG5vbmNlID0gY3J5cHRvLnJhbmRv
bUJ5dGVzKDYpLnRvU3RyaW5nKCdoZXgnKTsKICAgIGNvbnN0IHJlY2VpdmVkID0gcGF0aC5qb2lu
KGRpcmVjdG9yeSwgYC51cGxvYWQtJHtub25jZX0uemlwYCk7CiAgICBjb25zdCBzbGltID0gcGF0
aC5qb2luKGRpcmVjdG9yeSwgYC5wYWNrLSR7bm9uY2V9LnppcGApOwogICAgdHJ5IHsKICAgICAg
bGV0IGJ5dGVzID0gMDsKICAgICAgY29uc3QgY291bnRlciA9IG5ldyBUcmFuc2Zvcm0oewogICAg
ICAgIHRyYW5zZm9ybShjaHVuaywgZW5jb2RpbmcsIGRvbmUpIHsKICAgICAgICAgIGJ5dGVzICs9
IGNodW5rLmxlbmd0aDsKICAgICAgICAgIGlmIChieXRlcyA+IGNvbmZpZy5tYXhQYWNrQnl0ZXMp
IGRvbmUobmV3IFBhY2tFcnJvcihgRmlsZSBxdcOhIGzhu5tuICh04buRaSDEkWEgJHtNYXRoLnJv
dW5kKGNvbmZpZy5tYXhQYWNrQnl0ZXMgLyBNSUIpfSBNQikuYCkpOwogICAgICAgICAgZWxzZSBk
b25lKG51bGwsIGNodW5rKTsKICAgICAgICB9LAogICAgICB9KTsKICAgICAgYXdhaXQgcGlwZWxp
bmUocmVxLCBjb3VudGVyLCBmcy5jcmVhdGVXcml0ZVN0cmVhbShyZWNlaXZlZCkpOwogICAgICBp
ZiAoZGVjbGFyZWQgJiYgYnl0ZXMgIT09IGRlY2xhcmVkKSB0aHJvdyBuZXcgUGFja0Vycm9yKCdU
4bqjaSBsw6puIGLhu4sgbmfhuq90IGdp4buvYSBjaOG7q25nLicpOwogICAgICBsZXQgemlwID0g
bnVsbDsKICAgICAgdHJ5IHsgemlwID0gYXdhaXQgcmVhZFppcChyZWNlaXZlZCk7IH0gY2F0Y2gg
KGVycm9yKSB7IGlmICghKGVycm9yIGluc3RhbmNlb2YgUGFja0Vycm9yKSkgdGhyb3cgZXJyb3I7
IH0KICAgICAgY29uc3QgbGYyID0gemlwICYmIHppcC5lbnRyaWVzLnNvbWUoKHsgbmFtZSB9KSA9
PiAvKF58W1xcL10pZGF0YVtcXC9dZGF0YVwudHh0JC9pLnRlc3QobmFtZSkpOwogICAgICBpZiAo
IWxmMikgewogICAgICAgIC8vIEEgRmxhc2ggZ2FtZSwgb3Igd2hhdCByZWFkWmlwL2FuYWx5emVa
aXAgc2F5IHRoaXMgaXMgbm90LgogICAgICAgIGNvbnN0IG1vdmllID0gYXdhaXQgZmluZE1vdmll
KHJlY2VpdmVkLCB6aXApOwogICAgICAgIGlmICghbW92aWUpIHsKICAgICAgICAgIGlmICghemlw
KSB0aHJvdyBuZXcgUGFja0Vycm9yKCfEkMOieSBraMO0bmcgcGjhuqNpIGZpbGUgLnppcCwgY8Wp
bmcga2jDtG5nIHBo4bqjaSBnYW1lIEZsYXNoICguc3dmIGhv4bq3YyAuZXhlIGPDsyBnYW1lIEZs
YXNoIGLDqm4gdHJvbmcpLicpOwogICAgICAgICAgYW5hbHl6ZVppcCh6aXAuZW50cmllcyk7IC8v
IHRocm93cyB3aHkgdGhpcyBpcyBubyBMRjIgZ2FtZSBmb2xkZXIKICAgICAgICB9CiAgICAgICAg
Y29uc3Qgc2hhMjU2ID0gY3J5cHRvLmNyZWF0ZUhhc2goJ3NoYTI1NicpLnVwZGF0ZShtb3ZpZSku
ZGlnZXN0KCdoZXgnKTsKICAgICAgICBjb25zdCBnYW1lID0gZmxhc2hHYW1lKG1vdmllKTsKICAg
ICAgICBhd2FpdCBmc3Aud3JpdGVGaWxlKHNsaW0sIG1vdmllKTsKICAgICAgICBmb3IgKGNvbnN0
IG9sZCBvZiBbYCR7aWR9LnppcGAsIGAke2lkfS5zd2ZgXSkgYXdhaXQgZnNwLnJtKHBhdGguam9p
bihkaXJlY3RvcnksIG9sZCksIHsgZm9yY2U6IHRydWUgfSk7CiAgICAgICAgYXdhaXQgZnNwLnJl
bmFtZShzbGltLCBwYXRoLmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uc3dmYCkpOwogICAgICAgIGNv
bnN0IGluZm8gPSB7IHRpdGxlLCBzaGEyNTYsIGZpbGVzOiAxLCBraW5kOiAnZmxhc2gnLCBnYW1l
LCB1cGxvYWRlZDogbmV3IERhdGUoKS50b0lTT1N0cmluZygpLAogICAgICAgICAgb3JpZ2luYWw6
IHsgc2l6ZTogYnl0ZXMsIGZpbGVzOiB6aXAgPyB6aXAuZW50cmllcy5sZW5ndGggOiAxIH0gfTsK
ICAgICAgICBhd2FpdCBmc3Aud3JpdGVGaWxlKHBhdGguam9pbihkaXJlY3RvcnksIGAke2lkfS5q
c29uYCksIEpTT04uc3RyaW5naWZ5KGluZm8sIG51bGwsIDIpKTsKICAgICAgICBhd2FpdCBmc3Au
cm0ocmVjZWl2ZWQsIHsgZm9yY2U6IHRydWUgfSk7CiAgICAgICAgbG9nKGBwYWNrICR7aWR9OiAk
e2J5dGVzfSBieXRlcyB1cGxvYWRlZCwgYSBGbGFzaCBtb3ZpZSBvZiAke21vdmllLmxlbmd0aH0g
a2VwdCR7Z2FtZSA/IGAgKCR7Z2FtZX0pYCA6ICcnfWApOwogICAgICAgIGpzb24ocmVzLCAyMDAs
IHsgb2s6IHRydWUsIGlkLCB0aXRsZSwgc2l6ZTogbW92aWUubGVuZ3RoLCBzaGEyNTYsIGZpbGVz
OiAxLCBkcm9wcGVkOiBpbmZvLm9yaWdpbmFsLmZpbGVzIC0gMSwKICAgICAgICAgIGtpbmQ6ICdm
bGFzaCcsIGdhbWUsIG9yaWdpbmFsOiBpbmZvLm9yaWdpbmFsIH0pOwogICAgICAgIHJldHVybjsK
ICAgICAgfQogICAgICBjb25zdCBhbmFseXNpcyA9IGFuYWx5emVaaXAoemlwLmVudHJpZXMpOwog
ICAgICBjb25zdCB3cml0dGVuID0gYXdhaXQgd3JpdGVaaXAocmVjZWl2ZWQsIHNsaW0sIGFuYWx5
c2lzLmtlZXApOwogICAgICBhd2FpdCBmc3Aucm0ocGF0aC5qb2luKGRpcmVjdG9yeSwgYCR7aWR9
LnN3ZmApLCB7IGZvcmNlOiB0cnVlIH0pOwogICAgICBhd2FpdCBmc3AucmVuYW1lKHNsaW0sIHBh
dGguam9pbihkaXJlY3RvcnksIGAke2lkfS56aXBgKSk7CiAgICAgIGNvbnN0IGluZm8gPSB7IHRp
dGxlLCBzaGEyNTY6IHdyaXR0ZW4uc2hhMjU2LCBmaWxlczogd3JpdHRlbi5maWxlcywgZXhlY3V0
YWJsZTogYW5hbHlzaXMuZXhlY3V0YWJsZSwKICAgICAgICB1cGxvYWRlZDogbmV3IERhdGUoKS50
b0lTT1N0cmluZygpLCBvcmlnaW5hbDogeyBzaXplOiBieXRlcywgZmlsZXM6IHppcC5lbnRyaWVz
Lmxlbmd0aCB9IH07CiAgICAgIGF3YWl0IGZzcC53cml0ZUZpbGUocGF0aC5qb2luKGRpcmVjdG9y
eSwgYCR7aWR9Lmpzb25gKSwgSlNPTi5zdHJpbmdpZnkoaW5mbywgbnVsbCwgMikpOwogICAgICBh
d2FpdCBmc3Aucm0ocmVjZWl2ZWQsIHsgZm9yY2U6IHRydWUgfSk7CiAgICAgIGxvZyhgcGFjayAk
e2lkfTogJHtieXRlc30gYnl0ZXMgdXBsb2FkZWQsICR7d3JpdHRlbi5zaXplfSBrZXB0ICgke3dy
aXR0ZW4uZmlsZXN9IGZpbGVzKWApOwogICAgICBqc29uKHJlcywgMjAwLCB7IG9rOiB0cnVlLCBp
ZCwgdGl0bGUsIHNpemU6IHdyaXR0ZW4uc2l6ZSwgc2hhMjU2OiB3cml0dGVuLnNoYTI1NiwgZmls
ZXM6IHdyaXR0ZW4uZmlsZXMsCiAgICAgICAgZHJvcHBlZDogYW5hbHlzaXMuZHJvcHBlZCwgZXhl
Y3V0YWJsZTogYW5hbHlzaXMuZXhlY3V0YWJsZSwgb3JpZ2luYWw6IGluZm8ub3JpZ2luYWwgfSk7
CiAgICB9IGNhdGNoIChlcnJvcikgewogICAgICBhd2FpdCBmc3Aucm0ocmVjZWl2ZWQsIHsgZm9y
Y2U6IHRydWUgfSk7CiAgICAgIGF3YWl0IGZzcC5ybShzbGltLCB7IGZvcmNlOiB0cnVlIH0pOwog
ICAgICBjb25zdCBtZXNzYWdlID0gZXJyb3IgaW5zdGFuY2VvZiBQYWNrRXJyb3IgPyBlcnJvci5t
ZXNzYWdlIDogJ0tow7RuZyBsxrB1IMSRxrDhu6NjIGZpbGU6ICcgKyAoZXJyb3IubWVzc2FnZSB8
fCBlcnJvcik7CiAgICAgIGlmICghcmVzLmhlYWRlcnNTZW50KSBqc29uKHJlcywgZXJyb3IgaW5z
dGFuY2VvZiBQYWNrRXJyb3IgPyA0MDAgOiA1MDAsIHsgZXJyb3I6IG1lc3NhZ2UgfSk7CiAgICB9
IGZpbmFsbHkgewogICAgICB1cGxvYWRpbmcgPSBmYWxzZTsKICAgIH0KICB9CgogIGFzeW5jIGZ1
bmN0aW9uIHNlcnZlUGFjayhyZXEsIHJlcywgaWQsIGV4dGVuc2lvbiA9ICd6aXAnKSB7CiAgICBj
b25zdCBoZWFkZXJzID0geyAneC1jb250ZW50LXR5cGUtb3B0aW9ucyc6ICdub3NuaWZmJywgLi4u
YWxsb3dPcmlnaW4ocmVxKSB9OwogICAgaWYgKHJlcS5tZXRob2QgIT09ICdHRVQnICYmIHJlcS5t
ZXRob2QgIT09ICdIRUFEJykgewogICAgICByZXMud3JpdGVIZWFkKDQwNSwgeyAuLi5oZWFkZXJz
LCBhbGxvdzogJ0dFVCwgSEVBRCcgfSk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwog
ICAgfQogICAgY29uc3QgZmlsZSA9IHBhdGguam9pbihkaXJlY3RvcnkgfHwgJy9ub25leGlzdGVu
dCcsIGAke2lkfS4ke2V4dGVuc2lvbn1gKTsKICAgIGxldCBzdGF0OwogICAgdHJ5IHsgc3RhdCA9
IGF3YWl0IGZzcC5zdGF0KGZpbGUpOyB9IGNhdGNoIHsgc3RhdCA9IG51bGw7IH0KICAgIGlmICgh
ZGlyZWN0b3J5IHx8ICFzdGF0IHx8ICFzdGF0LmlzRmlsZSgpKSB7CiAgICAgIHJlcy53cml0ZUhl
YWQoNDA0LCBoZWFkZXJzKTsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm47CiAgICB9CiAg
ICBpZiAocmVxLm1ldGhvZCA9PT0gJ0dFVCcpIHsKICAgICAgY29uc3QgcXVvdGEgPSBjb3VudGVk
KGRvd25sb2FkcywgY2xpZW50QWRkcmVzcyhyZXEpLCBjb25maWcucGFja0Rvd25sb2Fkc1Blckhv
dXIpOwogICAgICBpZiAocXVvdGEub3ZlcikgewogICAgICAgIHJlcy53cml0ZUhlYWQoNDI5LCB7
IC4uLmhlYWRlcnMsICdyZXRyeS1hZnRlcic6IFN0cmluZyhxdW90YS5yZXRyeSkgfSk7CiAgICAg
ICAgcmVzLmVuZCgpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBxdW90YS5hZGQoKTsK
ICAgIH0KICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7IC4uLmhlYWRlcnMsICdjb250ZW50LXR5cGUn
OiBleHRlbnNpb24gPT09ICdzd2YnID8gJ2FwcGxpY2F0aW9uL3gtc2hvY2t3YXZlLWZsYXNoJyA6
ICdhcHBsaWNhdGlvbi96aXAnLAogICAgICAnY29udGVudC1sZW5ndGgnOiBTdHJpbmcoc3RhdC5z
aXplKSwKICAgICAgJ2NhY2hlLWNvbnRyb2wnOiAnbm8tY2FjaGUnIH0pOwogICAgaWYgKHJlcS5t
ZXRob2QgPT09ICdIRUFEJykgewogICAgICByZXMuZW5kKCk7CiAgICAgIHJldHVybjsKICAgIH0K
ICAgIGNvbnN0IHN0cmVhbSA9IGZzLmNyZWF0ZVJlYWRTdHJlYW0oZmlsZSk7CiAgICBzdHJlYW0u
b24oJ2Vycm9yJywgKCkgPT4gcmVzLmRlc3Ryb3koKSk7CiAgICBzdHJlYW0ucGlwZShyZXMpOwog
IH0KCiAgLy8gUmV0dXJucyB0cnVlIHdoZW4gdGhlIHJlcXVlc3Qgd2FzIG9uZSBvZiB0aGUgcGFj
a3MnIGFuZCBoYXMgYmVlbiBhbnN3ZXJlZCAob3IgaXMgYmVpbmcgYW5zd2VyZWQpLgogIGZ1bmN0
aW9uIGhhbmRsZShyZXEsIHJlcywgcGF0aG5hbWUpIHsKICAgIGlmIChwYXRobmFtZSA9PT0gJy9s
ZjItcGFja3MuanNvbicpIHsKICAgICAgbGlzdCgpLnRoZW4oKHBhY2tzKSA9PiBqc29uKHJlcywg
MjAwLCB7IHBhY2tzOiBwYWNrcy5tYXAoKHsgaWQsIHRpdGxlLCBzaXplLCBzaGEyNTYsIGtpbmQs
IGdhbWUgfSkgPT4gKHsgaWQsIHRpdGxlLCBzaXplLCBzaGEyNTYsIGtpbmQsIGdhbWUgfSkpIH0s
CiAgICAgICAgeyAnYWNjZXNzLWNvbnRyb2wtYWxsb3ctb3JpZ2luJzogJyonIH0pKTsKICAgICAg
cmV0dXJuIHRydWU7CiAgICB9CiAgICBjb25zdCBwYWNrID0gcGF0aG5hbWUubWF0Y2goL15cL2xm
Mi1wYWNrc1wvKFthLXowLTldW2EtejAtOS1dezAsMzl9KVwuKHppcHxzd2YpJC8pOwogICAgaWYg
KHBhY2spIHsKICAgICAgc2VydmVQYWNrKHJlcSwgcmVzLCBwYWNrWzFdLCBwYWNrWzJdKS5jYXRj
aCgoKSA9PiByZXMuZGVzdHJveSgpKTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBpZiAo
cGF0aG5hbWUgPT09ICcvYWRtaW4nIHx8IHBhdGhuYW1lID09PSAnL2FkbWluLycpIHsKICAgICAg
cmVzLndyaXRlSGVhZCgyMDAsIHsgJ2NvbnRlbnQtdHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9
dXRmLTgnLCAnY2FjaGUtY29udHJvbCc6ICduby1zdG9yZScsCiAgICAgICAgJ3gtZnJhbWUtb3B0
aW9ucyc6ICdERU5ZJywgJ3JlZmVycmVyLXBvbGljeSc6ICduby1yZWZlcnJlcicgfSk7CiAgICAg
IHJlcy5lbmQoQURNSU5fUEFHRSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYgKHBh
dGhuYW1lID09PSAnL2FkbWluL2FwaS9wYWNrcycgJiYgcmVxLm1ldGhvZCA9PT0gJ0dFVCcpIHsK
ICAgICAgaWYgKGF1dGhvcml6ZWQocmVxLCByZXMpKSBsaXN0KCkudGhlbigocGFja3MpID0+IGpz
b24ocmVzLCAyMDAsIHsgcGFja3MsIG1heEJ5dGVzOiBjb25maWcubWF4UGFja0J5dGVzIH0pKTsK
ICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBjb25zdCBtYW5hZ2VkID0gcGF0aG5hbWUubWF0
Y2goL15cL2FkbWluXC9hcGlcL3BhY2tzXC8oW14vXSopJC8pOwogICAgaWYgKG1hbmFnZWQpIHsK
ICAgICAgY29uc3QgaWQgPSBtYW5hZ2VkWzFdOwogICAgICBpZiAoIVBBQ0tfSUQudGVzdChpZCkp
IHsKICAgICAgICBqc29uKHJlcywgNDAwLCB7IGVycm9yOiAnTcOjIG5n4bqvbiBjaOG7iSBn4buT
bSBjaOG7ryB0aMaw4budbmcgYS16LCBz4buRIHbDoCBk4bqldSBn4bqhY2ggbmdhbmcgKHThu5Fp
IMSRYSA0MCBrw70gdOG7sSkuJyB9KTsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgfQogICAg
ICBpZiAocmVxLm1ldGhvZCA9PT0gJ1BVVCcpIHsKICAgICAgICBpZiAoIWF1dGhvcml6ZWQocmVx
LCByZXMpKSB7IHJlcS5yZXN1bWUoKTsgcmV0dXJuIHRydWU7IH0KICAgICAgICBjb25zdCB0aXRs
ZSA9IFN0cmluZyhuZXcgVVJMKHJlcS51cmwsICdodHRwOi8vcmVsYXkuaW52YWxpZCcpLnNlYXJj
aFBhcmFtcy5nZXQoJ3RpdGxlJykgfHwgaWQpLnRyaW0oKS5zbGljZSgwLCA2MCkgfHwgaWQ7CiAg
ICAgICAgdXBsb2FkKHJlcSwgcmVzLCBpZCwgdGl0bGUpLmNhdGNoKCgpID0+IHJlcy5kZXN0cm95
KCkpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAgICAgIGlmIChyZXEubWV0aG9kID09
PSAnREVMRVRFJykgewogICAgICAgIGlmICghYXV0aG9yaXplZChyZXEsIHJlcykpIHJldHVybiB0
cnVlOwogICAgICAgIFByb21pc2UuYWxsKFtgJHtpZH0uemlwYCwgYCR7aWR9LnN3ZmAsIGAke2lk
fS5qc29uYF0ubWFwKChuYW1lKSA9PiBmc3Aucm0ocGF0aC5qb2luKGRpcmVjdG9yeSB8fCAnL25v
bmV4aXN0ZW50JywgbmFtZSksIHsgZm9yY2U6IHRydWUgfSkpKQogICAgICAgICAgLnRoZW4oKCkg
PT4geyBsb2coYHBhY2sgJHtpZH06IHJlbW92ZWRgKTsganNvbihyZXMsIDIwMCwgeyBvazogdHJ1
ZSB9KTsgfSkKICAgICAgICAgIC5jYXRjaCgoZXJyb3IpID0+IGpzb24ocmVzLCA1MDAsIHsgZXJy
b3I6IFN0cmluZyhlcnJvci5tZXNzYWdlIHx8IGVycm9yKSB9KSk7CiAgICAgICAgcmV0dXJuIHRy
dWU7CiAgICAgIH0KICAgICAganNvbihyZXMsIDQwNSwgeyBlcnJvcjogJ21ldGhvZCBub3QgYWxs
b3dlZCcgfSwgeyBhbGxvdzogJ1BVVCwgREVMRVRFJyB9KTsKICAgICAgcmV0dXJuIHRydWU7CiAg
ICB9CiAgICByZXR1cm4gZmFsc2U7CiAgfQoKICByZXR1cm4geyBoYW5kbGUsIGxpc3QsIGNsZWFu
dXA6ICgpID0+IHsKICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgICBmb3IgKGNvbnN0IG1h
cCBvZiBbZG93bmxvYWRzLCBmYWlsdXJlc10pIGZvciAoY29uc3QgW2tleSwgZW50cnldIG9mIG1h
cCkgaWYgKGVudHJ5LnVudGlsIDw9IG5vdykgbWFwLmRlbGV0ZShrZXkpOwogIH0gfTsKfQoKLy8g
VGhlIHBhZ2UgYXQgL2FkbWluIChWaWV0bmFtZXNlOiB0aGUgcmVsYXkncyBvd25lciByZWFkcyBp
dCkuCmNvbnN0IEFETUlOX1BBR0UgPSBgPCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9InZpIj48
aGVhZD48bWV0YSBjaGFyc2V0PSJ1dGYtOCI+PG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9
IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPk9wZW5MRjIgcmVs
YXk6IGLhuqNuIG1vZDwvdGl0bGU+CjxzdHlsZT4KICBib2R5IHsgbWFyZ2luOiAwOyBwYWRkaW5n
OiAxLjVyZW07IGJhY2tncm91bmQ6ICMxMTE4Mjc7IGNvbG9yOiAjZjNmNGY2OyBmb250OiAxNnB4
LzEuNSBzeXN0ZW0tdWksIHNhbnMtc2VyaWY7IH0KICBtYWluIHsgbWF4LXdpZHRoOiA3NjBweDsg
bWFyZ2luOiBhdXRvOyB9CiAgaDEgeyBmb250LXNpemU6IDEuNXJlbTsgbWFyZ2luOiAwIDAgLjI1
cmVtOyB9CiAgLmNhcmQgeyBiYWNrZ3JvdW5kOiAjMWYyOTM3OyBib3JkZXI6IDFweCBzb2xpZCAj
Mzc0MTUxOyBib3JkZXItcmFkaXVzOiAxMnB4OyBwYWRkaW5nOiAxcmVtIDEuMnJlbTsgbWFyZ2lu
OiAxcmVtIDA7IH0KICBsYWJlbCB7IGRpc3BsYXk6IGJsb2NrOyBtYXJnaW46IC42cmVtIDAgLjJy
ZW07IGZvbnQtd2VpZ2h0OiA2MDA7IH0KICBpbnB1dFt0eXBlPXRleHRdLCBpbnB1dFt0eXBlPXBh
c3N3b3JkXSB7IHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBwYWRkaW5nOiAu
NXJlbSAuNnJlbTsgZm9udDogaW5oZXJpdDsKICAgIGJvcmRlci1yYWRpdXM6IDhweDsgYm9yZGVy
OiAxcHggc29saWQgIzRiNTU2MzsgYmFja2dyb3VuZDogIzBiMTIyMDsgY29sb3I6IGluaGVyaXQ7
IH0KICBidXR0b24geyBwYWRkaW5nOiAuNTVyZW0gMS4xcmVtOyBmb250OiBpbmhlcml0OyBib3Jk
ZXItcmFkaXVzOiA4cHg7IGJvcmRlcjogMDsgY3Vyc29yOiBwb2ludGVyOyBiYWNrZ3JvdW5kOiAj
ZjU5ZTBiOyBjb2xvcjogIzFmMTMwMDsgZm9udC13ZWlnaHQ6IDcwMDsgfQogIGJ1dHRvbi5zZWNv
bmRhcnkgeyBiYWNrZ3JvdW5kOiAjMzc0MTUxOyBjb2xvcjogI2YzZjRmNjsgZm9udC13ZWlnaHQ6
IDUwMDsgfQogIGJ1dHRvbjpkaXNhYmxlZCB7IG9wYWNpdHk6IC41OyBjdXJzb3I6IGRlZmF1bHQ7
IH0KICBwcm9ncmVzcyB7IHdpZHRoOiAxMDAlOyBoZWlnaHQ6IC44cmVtOyBtYXJnaW4tdG9wOiAu
OHJlbTsgfQogIC5ub3RlIHsgY29sb3I6ICM5Y2EzYWY7IGZvbnQtc2l6ZTogLjlyZW07IH0KICAu
b2sgeyBjb2xvcjogIzZlZTdiNzsgfSAuYmFkIHsgY29sb3I6ICNmY2E1YTU7IH0KICB0YWJsZSB7
IHdpZHRoOiAxMDAlOyBib3JkZXItY29sbGFwc2U6IGNvbGxhcHNlOyB9IHRkLCB0aCB7IHRleHQt
YWxpZ246IGxlZnQ7IHBhZGRpbmc6IC40cmVtIC4zcmVtOyBib3JkZXItYm90dG9tOiAxcHggc29s
aWQgIzM3NDE1MTsgdmVydGljYWwtYWxpZ246IHRvcDsgfQogIGNvZGUgeyBiYWNrZ3JvdW5kOiAj
MGIxMjIwOyBwYWRkaW5nOiAuMDVyZW0gLjNyZW07IGJvcmRlci1yYWRpdXM6IDRweDsgfQo8L3N0
eWxlPjwvaGVhZD4KPGJvZHk+PG1haW4+CiAgPGgxPkLhuqNuIG1vZCBjaG8gT3BlbkxGMjwvaDE+
CiAgPHAgY2xhc3M9Im5vdGUiPlThuqNpIGzDqm4gbeG7mXQgZmlsZSAuemlwIGNo4bupYSBj4bqj
IHRoxrAgbeG7pWMgZ2FtZSBj4bunYSBi4bqjbiBtb2QgKGPDsyBmaWxlIC5leGUgdsOgIHRoxrAg
beG7pWMgZGF0YSwgc3ByaXRlLCBiZ20sIGJnKS4KICAgIFJlbGF5IGNo4buJIGdp4buvIGzhuqFp
IHBo4bqnbiBnYW1lIGPhuqduLCBy4buTaSBwaMOhdCBjaG8gdHLDrG5oIGR1eeG7h3QgY+G7p2Eg
bmfGsOG7nWkgY2jGoWkuIEFpIGPFqW5nIGNo4buNbiBjw7luZyBt4buZdCBi4bqjbiBtb2QgbeG7
m2kgdsOgbyBjaHVuZyBwaMOybmcgxJHGsOG7o2MuPC9wPgogIDxwIGNsYXNzPSJub3RlIj5HYW1l
IEhlcm8gRmlnaHRlciBjxaluZyB04bqjaSBsw6puIOG7nyDEkcOieTogZmlsZSA8Y29kZT5IRnYw
LjcuemlwPC9jb2RlPiAoaG/hurdjIDxjb2RlPkhGdjAuNysuZXhlPC9jb2RlPikuIFJlbGF5IGdp
4buvIHBo4bqnbiBnYW1lIEZsYXNoIGLDqm4gdHJvbmc7CiAgICB0csOqbiB0cmFuZyBnYW1lLCBj
aOG7jW4gPGI+SGVybyBGaWdodGVyPC9iPiDhu58gbeG7pWMgR2FtZS48L3A+CiAgPGRpdiBjbGFz
cz0iY2FyZCI+CiAgICA8bGFiZWwgZm9yPSJrZXkiPk3DoyBxdeG6o24gdHLhu4sgKEFETUlOX0tF
WSk8L2xhYmVsPgogICAgPGlucHV0IGlkPSJrZXkiIHR5cGU9InBhc3N3b3JkIiBhdXRvY29tcGxl
dGU9ImN1cnJlbnQtcGFzc3dvcmQiIHBsYWNlaG9sZGVyPSJpbiByYSBraGkgY2jhuqF5IGluc3Rh
bGwtdnBzLnNoIj4KICAgIDxsYWJlbCBmb3I9ImZpbGUiPkZpbGUgLnppcCBj4bunYSBi4bqjbiBt
b2Q8L2xhYmVsPgogICAgPGlucHV0IGlkPSJmaWxlIiB0eXBlPSJmaWxlIiBhY2NlcHQ9Ii56aXAs
LmV4ZSwuc3dmLGFwcGxpY2F0aW9uL3ppcCI+CiAgICA8bGFiZWwgZm9yPSJ0aXRsZSI+VMOqbiBo
aeG7g24gdGjhu4sgdHLDqm4gdHJhbmcgZ2FtZTwvbGFiZWw+CiAgICA8aW5wdXQgaWQ9InRpdGxl
IiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjYwIiBwbGFjZWhvbGRlcj0idsOtIGThu6U6IE9uZSBQ
aWVjZSBHcmFuZFdvcmxkIj4KICAgIDxsYWJlbCBmb3I9ImlkIj5Nw6Mgbmfhuq9uIChkw7luZyB0
cm9uZyBsaW5rIG3hu51pKTwvbGFiZWw+CiAgICA8aW5wdXQgaWQ9ImlkIiB0eXBlPSJ0ZXh0IiBt
YXhsZW5ndGg9IjQwIiBwbGFjZWhvbGRlcj0idsOtIGThu6U6IG9uZXBpZWNlIiBwYXR0ZXJuPSJb
YS16MC05XVthLXowLTktXSoiPgogICAgPHA+PGJ1dHRvbiBpZD0idXBsb2FkIj5U4bqjaSBsw6pu
PC9idXR0b24+PC9wPgogICAgPHByb2dyZXNzIGlkPSJwcm9ncmVzcyIgaGlkZGVuPjwvcHJvZ3Jl
c3M+CiAgICA8cCBpZD0ic3RhdHVzIiByb2xlPSJzdGF0dXMiIGNsYXNzPSJub3RlIj48L3A+CiAg
PC9kaXY+CiAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICA8aDIgc3R5bGU9ImZvbnQtc2l6ZToxLjE1
cmVtO21hcmdpbjowIDAgLjVyZW0iPkPDoWMgYuG6o24gbW9kIHRyw6puIHJlbGF5PC9oMj4KICAg
IDxwPjxidXR0b24gaWQ9InJlZnJlc2giIGNsYXNzPSJzZWNvbmRhcnkiPlhlbSBkYW5oIHPDoWNo
PC9idXR0b24+PC9wPgogICAgPHRhYmxlPjx0Ym9keSBpZD0ibGlzdCI+PC90Ym9keT48L3RhYmxl
PgogIDwvZGl2Pgo8L21haW4+CjxzY3JpcHQ+CiAgY29uc3QgJCA9IChpZCkgPT4gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoaWQpOwogIGNvbnN0IGFwaSA9IGxvY2F0aW9uLnBhdGhuYW1lLnJlcGxh
Y2UoL1xcLz8kLywgJy8nKSArICdhcGkvcGFja3MnOwogIHRyeSB7ICQoJ2tleScpLnZhbHVlID0g
bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2xmMi1hZG1pbi1rZXknKSB8fCAnJzsgfSBjYXRjaCAoZXJy
b3IpIHt9CiAgY29uc3QgcmVtZW1iZXIgPSAoKSA9PiB7IHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJ
dGVtKCdsZjItYWRtaW4ta2V5JywgJCgna2V5JykudmFsdWUpOyB9IGNhdGNoIChlcnJvcikge30g
fTsKICBjb25zdCBzbHVnID0gKHRleHQpID0+IHRleHQudG9Mb3dlckNhc2UoKS5ub3JtYWxpemUo
J05GRCcpLnJlcGxhY2UoL1tcXHUwMzAwLVxcdTAzNmZdL2csICcnKS5yZXBsYWNlKC/EkS9nLCAn
ZCcpCiAgICAucmVwbGFjZSgvW15hLXowLTldKy9nLCAnLScpLnJlcGxhY2UoL14tK3wtKyQvZywg
JycpLnNsaWNlKDAsIDQwKSB8fCAnbW9kJzsKICAkKCdmaWxlJykuYWRkRXZlbnRMaXN0ZW5lcign
Y2hhbmdlJywgKCkgPT4gewogICAgY29uc3QgZmlsZSA9ICQoJ2ZpbGUnKS5maWxlc1swXTsKICAg
IGlmICghZmlsZSkgcmV0dXJuOwogICAgbGV0IG5hbWUgPSBmaWxlLm5hbWUucmVwbGFjZSgvXFwu
KHppcHxleGV8c3dmKSQvaSwgJycpLnJlcGxhY2UoL1tfXSsvZywgJyAnKS50cmltKCk7CiAgICBp
ZiAoL15oZiA/dj8wXFwuNy9pLnRlc3QobmFtZSkpIG5hbWUgPSAnSGVybyBGaWdodGVyIHYwLjcr
JzsKICAgIGlmICghJCgndGl0bGUnKS52YWx1ZSkgJCgndGl0bGUnKS52YWx1ZSA9IG5hbWU7CiAg
ICBpZiAoISQoJ2lkJykudmFsdWUpICQoJ2lkJykudmFsdWUgPSBzbHVnKG5hbWUpOwogIH0pOwog
ICQoJ3RpdGxlJykuYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQnLCAoKSA9PiB7IGlmICghJCgnaWQn
KS5kYXRhc2V0LnRvdWNoZWQpICQoJ2lkJykudmFsdWUgPSBzbHVnKCQoJ3RpdGxlJykudmFsdWUp
OyB9KTsKICAkKCdpZCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4geyAkKCdpZCcp
LmRhdGFzZXQudG91Y2hlZCA9ICcxJzsgfSk7CiAgY29uc3QgbWIgPSAoYnl0ZXMpID0+IChieXRl
cyAvIDFlNikudG9GaXhlZCgxKSArICcgTUInOwogIGZ1bmN0aW9uIHN0YXR1cyh0ZXh0LCBraW5k
KSB7ICQoJ3N0YXR1cycpLnRleHRDb250ZW50ID0gdGV4dDsgJCgnc3RhdHVzJykuY2xhc3NOYW1l
ID0ga2luZCB8fCAnbm90ZSc7IH0KICAkKCd1cGxvYWQnKS5hZGRFdmVudExpc3RlbmVyKCdjbGlj
aycsICgpID0+IHsKICAgIGNvbnN0IGZpbGUgPSAkKCdmaWxlJykuZmlsZXNbMF07CiAgICBjb25z
dCBpZCA9ICQoJ2lkJykudmFsdWUudHJpbSgpOwogICAgaWYgKCEkKCdrZXknKS52YWx1ZSkgcmV0
dXJuIHN0YXR1cygnTmjhuq1wIG3DoyBxdeG6o24gdHLhu4sgdHLGsOG7m2MuJywgJ2JhZCcpOwog
ICAgaWYgKCFmaWxlKSByZXR1cm4gc3RhdHVzKCdDaOG7jW4gZmlsZSAuemlwIHRyxrDhu5tjLics
ICdiYWQnKTsKICAgIGlmICghL15bYS16MC05XVthLXowLTktXXswLDM5fSQvLnRlc3QoaWQpKSBy
ZXR1cm4gc3RhdHVzKCdNw6Mgbmfhuq9uIGNo4buJIGfhu5NtIGNo4buvIHRoxrDhu51uZyBhLXos
IHPhu5EgdsOgIGThuqV1IGfhuqFjaCBuZ2FuZy4nLCAnYmFkJyk7CiAgICByZW1lbWJlcigpOwog
ICAgY29uc3QgcmVxdWVzdCA9IG5ldyBYTUxIdHRwUmVxdWVzdCgpOwogICAgcmVxdWVzdC5vcGVu
KCdQVVQnLCBhcGkgKyAnLycgKyBpZCArICc/dGl0bGU9JyArIGVuY29kZVVSSUNvbXBvbmVudCgk
KCd0aXRsZScpLnZhbHVlLnRyaW0oKSB8fCBpZCkpOwogICAgcmVxdWVzdC5zZXRSZXF1ZXN0SGVh
ZGVyKCd4LWFkbWluLWtleScsICQoJ2tleScpLnZhbHVlKTsKICAgIHJlcXVlc3Quc2V0UmVxdWVz
dEhlYWRlcignY29udGVudC10eXBlJywgJ2FwcGxpY2F0aW9uL3ppcCcpOwogICAgJCgncHJvZ3Jl
c3MnKS5oaWRkZW4gPSBmYWxzZTsKICAgICQoJ3VwbG9hZCcpLmRpc2FibGVkID0gdHJ1ZTsKICAg
IHJlcXVlc3QudXBsb2FkLm9ucHJvZ3Jlc3MgPSAoZXZlbnQpID0+IHsKICAgICAgaWYgKCFldmVu
dC5sZW5ndGhDb21wdXRhYmxlKSByZXR1cm47CiAgICAgICQoJ3Byb2dyZXNzJykubWF4ID0gZXZl
bnQudG90YWw7CiAgICAgICQoJ3Byb2dyZXNzJykudmFsdWUgPSBldmVudC5sb2FkZWQ7CiAgICAg
IHN0YXR1cygnxJBhbmcgdOG6o2kgbMOqbjogJyArIG1iKGV2ZW50LmxvYWRlZCkgKyAnIC8gJyAr
IG1iKGV2ZW50LnRvdGFsKSArIChldmVudC5sb2FkZWQgPT09IGV2ZW50LnRvdGFsID8gJyAocmVs
YXkgxJFhbmcgeOG7rSBsw70uLi4pJyA6ICcnKSk7CiAgICB9OwogICAgcmVxdWVzdC5vbmxvYWQg
PSAoKSA9PiB7CiAgICAgICQoJ3VwbG9hZCcpLmRpc2FibGVkID0gZmFsc2U7CiAgICAgICQoJ3By
b2dyZXNzJykuaGlkZGVuID0gdHJ1ZTsKICAgICAgbGV0IGJvZHkgPSB7fTsKICAgICAgdHJ5IHsg
Ym9keSA9IEpTT04ucGFyc2UocmVxdWVzdC5yZXNwb25zZVRleHQpOyB9IGNhdGNoIChlcnJvcikg
e30KICAgICAgaWYgKHJlcXVlc3Quc3RhdHVzID09PSAyMDApIHsKICAgICAgICBpZiAoYm9keS5r
aW5kID09PSAnZmxhc2gnKSB7CiAgICAgICAgICBzdGF0dXMoJ1hvbmc6ICInICsgYm9keS50aXRs
ZSArICciIChnYW1lIEZsYXNoLCAnICsgbWIoYm9keS5zaXplKSArICcpLiAnCiAgICAgICAgICAg
ICsgKGJvZHkuZ2FtZSA9PT0gJ2hlcm9maWdodGVyJyA/ICdUcsOqbiB0cmFuZyBnYW1lLCBjaOG7
jW4gSGVybyBGaWdodGVyIOG7nyBt4bulYyBHYW1lLicgOiAnxJDDonkga2jDtG5nIHBo4bqjaSBI
ZXJvIEZpZ2h0ZXI6IHRyYW5nIGdhbWUgY2jGsGEgY2jGoWkgxJHGsOG7o2MgZ2FtZSBuw6B5Licp
LCBib2R5LmdhbWUgPyAnb2snIDogJ2JhZCcpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBz
dGF0dXMoJ1hvbmc6ICInICsgYm9keS50aXRsZSArICciICgnICsgbWIoYm9keS5zaXplKSArICcs
ICcgKyBib2R5LmZpbGVzICsgJyBmaWxlLCBi4buPIGLhu5t0ICcgKyBib2R5LmRyb3BwZWQgKyAn
IGZpbGUga2jDtG5nIGPhuqduKS4gJwogICAgICAgICAgICArICdUcsOqbiB0cmFuZyBnYW1lLCBj
aOG7jW4gbsOzIOG7nyBt4bulYyBHYW1lLCBob+G6t2MgZ+G7rWkgbGluayBt4budaSBjw7MgdGjD
qm0gJnBhY2s9JyArIGJvZHkuaWQgKyAnLicsICdvaycpOwogICAgICAgIH0KICAgICAgICByZWZy
ZXNoKCk7CiAgICAgIH0gZWxzZSBzdGF0dXMoJ0tow7RuZyDEkcaw4bujYzogJyArIChib2R5LmVy
cm9yIHx8ICgnbOG7l2kgJyArIHJlcXVlc3Quc3RhdHVzKSksICdiYWQnKTsKICAgIH07CiAgICBy
ZXF1ZXN0Lm9uZXJyb3IgPSAoKSA9PiB7ICQoJ3VwbG9hZCcpLmRpc2FibGVkID0gZmFsc2U7ICQo
J3Byb2dyZXNzJykuaGlkZGVuID0gdHJ1ZTsgc3RhdHVzKCdN4bqldCBr4bq/dCBu4buRaSBraGkg
dOG6o2kgbMOqbi4nLCAnYmFkJyk7IH07CiAgICByZXF1ZXN0LnNlbmQoZmlsZSk7CiAgfSk7CiAg
YXN5bmMgZnVuY3Rpb24gcmVmcmVzaCgpIHsKICAgIGlmICghJCgna2V5JykudmFsdWUpIHJldHVy
biBzdGF0dXMoJ05o4bqtcCBtw6MgcXXhuqNuIHRy4buLIMSR4buDIHhlbSBkYW5oIHPDoWNoLics
ICdiYWQnKTsKICAgIHJlbWVtYmVyKCk7CiAgICBjb25zdCByZXNwb25zZSA9IGF3YWl0IGZldGNo
KGFwaSwgeyBoZWFkZXJzOiB7ICd4LWFkbWluLWtleSc6ICQoJ2tleScpLnZhbHVlIH0gfSk7CiAg
ICBjb25zdCBib2R5ID0gYXdhaXQgcmVzcG9uc2UuanNvbigpLmNhdGNoKCgpID0+ICh7fSkpOwog
ICAgaWYgKCFyZXNwb25zZS5vaykgcmV0dXJuIHN0YXR1cyhib2R5LmVycm9yIHx8ICgnbOG7l2kg
JyArIHJlc3BvbnNlLnN0YXR1cyksICdiYWQnKTsKICAgIGNvbnN0IGxpc3QgPSAkKCdsaXN0Jyk7
CiAgICBsaXN0LnRleHRDb250ZW50ID0gJyc7CiAgICBpZiAoIWJvZHkucGFja3MubGVuZ3RoKSBs
aXN0LmlubmVySFRNTCA9ICc8dHI+PHRkIGNsYXNzPSJub3RlIj5DaMawYSBjw7MgYuG6o24gbW9k
IG7DoG8uPC90ZD48L3RyPic7CiAgICBmb3IgKGNvbnN0IHBhY2sgb2YgYm9keS5wYWNrcykgewog
ICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd0cicpOwogICAgICBjb25z
dCBpbmZvID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgndGQnKTsKICAgICAgaW5mby5pbm5lckhU
TUwgPSAnPGI+PC9iPjxicj48c3BhbiBjbGFzcz0ibm90ZSI+PC9zcGFuPic7CiAgICAgIGluZm8u
cXVlcnlTZWxlY3RvcignYicpLnRleHRDb250ZW50ID0gcGFjay50aXRsZTsKICAgICAgaW5mby5x
dWVyeVNlbGVjdG9yKCdzcGFuJykudGV4dENvbnRlbnQgPSAnbcOjOiAnICsgcGFjay5pZCArICcg
wrcgJyArIG1iKHBhY2suc2l6ZSkgKyAnIMK3IHThuqNpIGzDqm4gJyArIG5ldyBEYXRlKHBhY2su
dXBsb2FkZWQpLnRvTG9jYWxlU3RyaW5nKCk7CiAgICAgIGNvbnN0IGFjdGlvbnMgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCd0ZCcpOwogICAgICBjb25zdCByZW1vdmUgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgcmVtb3ZlLmNsYXNzTmFtZSA9ICdzZWNvbmRhcnkn
OwogICAgICByZW1vdmUudGV4dENvbnRlbnQgPSAnWMOzYSc7CiAgICAgIHJlbW92ZS5vbmNsaWNr
ID0gYXN5bmMgKCkgPT4gewogICAgICAgIGlmICghY29uZmlybSgnWMOzYSAiJyArIHBhY2sudGl0
bGUgKyAnIiBraOG7j2kgcmVsYXk/JykpIHJldHVybjsKICAgICAgICBjb25zdCByZXN1bHQgPSBh
d2FpdCBmZXRjaChhcGkgKyAnLycgKyBwYWNrLmlkLCB7IG1ldGhvZDogJ0RFTEVURScsIGhlYWRl
cnM6IHsgJ3gtYWRtaW4ta2V5JzogJCgna2V5JykudmFsdWUgfSB9KTsKICAgICAgICBpZiAocmVz
dWx0Lm9rKSByZWZyZXNoKCk7IGVsc2Ugc3RhdHVzKCdLaMO0bmcgeMOzYSDEkcaw4bujYyAobOG7
l2kgJyArIHJlc3VsdC5zdGF0dXMgKyAnKS4nLCAnYmFkJyk7CiAgICAgIH07CiAgICAgIGFjdGlv
bnMuYXBwZW5kQ2hpbGQocmVtb3ZlKTsKICAgICAgcm93LmFwcGVuZChpbmZvLCBhY3Rpb25zKTsK
ICAgICAgbGlzdC5hcHBlbmRDaGlsZChyb3cpOwogICAgfQogIH0KICAkKCdyZWZyZXNoJykuYWRk
RXZlbnRMaXN0ZW5lcignY2xpY2snLCByZWZyZXNoKTsKPC9zY3JpcHQ+CjwvYm9keT48L2h0bWw+
CmA7Cgptb2R1bGUuZXhwb3J0cyA9IHsgY3JlYXRlUGFja3MsIHJlYWRaaXAsIGFuYWx5emVaaXAs
IHdyaXRlWmlwLCBtb3ZpZU9mLCBmbGFzaEdhbWUsIFBhY2tFcnJvciwgUEFDS19JRCB9Owo=
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
IDxyZWxheSBmb2xkZXI+L2hmL2hmL3JsZy5waHAgICAgICAgICAgICAgICAgIHRoZSByb29tIGxp
c3Q6IHRoaXMgcmVsYXkncyByb29tcwovLyAgIEdFVCAgPHJlbGF5IGZvbGRlcj4vaGYvcm9vbXMu
anNvbiAgICAgICAgICAgICAgICAgdGhlIHJvb21zIGZvciB0aGUgcGFnZSAoaXRzIHNvY2tldCBw
cm94eSBzZXR0aW5ncykKLy8gICBXZWJTb2NrZXQgPHJlbGF5IHBhdGg+P2dhbWU9aGYmcm9vbT08
bj4gICAgICAgICAgcm9vbSBuIChoZi1yb29tLmpzKQovLyBBY2NvdW50cyAobmFtZSwgYSBoYXNo
IG9mIHRoZSBwYXNzd29yZCwgZWFjaCBjaGFyYWN0ZXIncyBsZXZlbCBhbmQgZXhwZXJpZW5jZSwg
c3RvcnkgcHJvZ3Jlc3MpCi8vIGFyZSBrZXB0IGluIDxQQUNLU19ESVI+L2hmL2FjY291bnRzLmpz
b24gKG9yIEhGX0RJUik7IGV2ZXJ5IGNoYXJhY3RlciBhbmQgc3RvcnkgaXMgb3BlbiBmcm9tIHRo
ZSBzdGFydC4KJ3VzZSBzdHJpY3QnOwoKY29uc3QgY3J5cHRvID0gcmVxdWlyZSgnbm9kZTpjcnlw
dG8nKTsKY29uc3QgZnMgPSByZXF1aXJlKCdub2RlOmZzJyk7CmNvbnN0IHBhdGggPSByZXF1aXJl
KCdub2RlOnBhdGgnKTsKY29uc3QgeyBIZlJvb20sIEhmQ29ubmVjdGlvbiwgQ0hBUkFDVEVSUyB9
ID0gcmVxdWlyZSgnLi9oZi1yb29tLmpzJyk7Cgpjb25zdCBTVE9SSUVTID0gNjsgLy8gR2xvYmFs
LnN0b3J5Q2hvc2VuX21heDogdGhlIGxhc3Qgc3RvcnkgZXBpc29kZQpjb25zdCBNQVhfRVhQRVJJ
RU5DRSA9IDE2OTk5OyAvLyBsZXZlbCAxNiAodGhlIGdhbWUncyBoaWdoZXN0OyBtb3JlIGlzIHRh
a2VuIGZvciBhIGNoZWF0KSwgOTk5IGV4cGVyaWVuY2UKY29uc3QgU1RBUlRfRVhQRVJJRU5DRSA9
IDEwMDA7IC8vIGxldmVsIDEsIGFsbCBjaGFyYWN0ZXJzIG9wZW4KCi8vIFRoZSBnYW1lIGNoZWNr
cyBsb2dpbiBhbnN3ZXJzIHdpdGggYSBjb2RlIG92ZXIgdGhlIG51bWJlcnMgaW4gdGhlbSAoR2xv
YmFsLkxvZ2luU3RhdHVzTWVzc2FnZSk6Ci8vIHdpdGggbiA9IHZbOF0sIG0gPSB2WzkrMm4uLis3
XSBhbmQgeCA9IHZbMTYrMm4uLis3XSwgKDk5OTk5OTggLSB4IC0gbSkgLyAzIG11c3QgYmUgdGhl
IHN1bSBiZWxvdwovLyAob3IgdGhhdCBwbHVzIGlkJTEzICsgaWQlNjEgKyBpZCUxMDcsIGZvciBh
IHByZW1pdW0gYWNjb3VudDogZXZlcnkgY2hhcmFjdGVyLCBhbHNvIHRoZSBwcmVtaXVtIG9uZXMp
LgpmdW5jdGlvbiBzdGF0dXNDb2RlKHZhbHVlcywgaWQsIGFjY3R5cGUsIHN0YWdlLCBzZXNzaW9u
LCBwcmVtaXVtKSB7CiAgY29uc3Qgc3VtID0gKHZhbHVlcy5yZWR1Y2UoKGEsIGIpID0+IGEgKyBi
LCAwKSArIGlkICsgYWNjdHlwZSArIHN0YWdlICsgc2Vzc2lvbiAlIDEwMDAwMDApICUgMTAwMDAw
MCArIDEwMDAwMDA7CiAgcmV0dXJuIGVuY29kZU51bWJlcihzdW0gKyAocHJlbWl1bSA/IGlkICUg
MTMgKyBpZCAlIDYxICsgaWQgJSAxMDcgOiAwKSk7Cn0KCi8vIEEgbnVtYmVyIHRoZSBnYW1lIHJl
YWRzIGJhY2sgYXMgKDk5OTk5OTggLSB4IC0gbSkgLyAzIGZyb20gdGhlIDI1LWRpZ2l0IGZvcm0g
YWJvdmUgKGFuZCBjYXB0Y2hhCi8vIGNvZGVzIGFzIHRoYXQgbW9kdWxvIDEwMDAwMDApOiByYW5k
b20gZGlnaXRzIGFyb3VuZCBpdCwgYXMgaGVyb2ZpZ2h0ZXIuY29tIHNlbnQuCmZ1bmN0aW9uIGVu
Y29kZU51bWJlcihudW1iZXIpIHsKICBjb25zdCBkaWdpdCA9ICgpID0+IFN0cmluZyhjcnlwdG8u
cmFuZG9tSW50KDEwKSk7CiAgY29uc3QgbiA9IGNyeXB0by5yYW5kb21JbnQoMTApOwogIGNvbnN0
IG0gPSBjcnlwdG8ucmFuZG9tSW50KDEwMDAwMDAsIDIwMDAwMDApOwogIGNvbnN0IHggPSA5OTk5
OTk4IC0gMyAqIG51bWJlciAtIG07CiAgbGV0IHRleHQgPSAnJzsKICBmb3IgKGxldCBrID0gMDsg
ayA8IDg7IGsgKz0gMSkgdGV4dCArPSBkaWdpdCgpOwogIHRleHQgKz0gU3RyaW5nKG4pOwogIGZv
ciAobGV0IGsgPSAwOyBrIDwgbiAqIDI7IGsgKz0gMSkgdGV4dCArPSBkaWdpdCgpOwogIHRleHQg
Kz0gU3RyaW5nKG0pLnBhZFN0YXJ0KDcsICcwJykgKyBTdHJpbmcoeCkucGFkU3RhcnQoNywgJzAn
KTsKICBmb3IgKGxldCBrID0gMDsgayA8IDE4IC0gbiAqIDI7IGsgKz0gMSkgdGV4dCArPSBkaWdp
dCgpOwogIHJldHVybiB0ZXh0Owp9CgpmdW5jdGlvbiB4bWxUZXh0KHZhbHVlKSB7CiAgcmV0dXJu
IFN0cmluZyh2YWx1ZSkucmVwbGFjZSgvWzw+Jl0vZywgKGMpID0+ICh7ICc8JzogJyZsdDsnLCAn
Pic6ICcmZ3Q7JywgJyYnOiAnJmFtcDsnIH1bY10pKTsKfQoKLy8gQSBkaXNwbGF5IG5hbWU6IHdo
YXQgdGhlIGdhbWUgYWxsb3dzIGluIG9uZSAobm8gWyBvciBdLCB3aGljaCBpdCB1c2VzIGl0c2Vs
ZiksIGF0IG1vc3QgMjAgY2hhcmFjdGVycy4KZnVuY3Rpb24gY2xlYW5OYW1lKHZhbHVlKSB7CiAg
cmV0dXJuIFN0cmluZyh2YWx1ZSB8fCAnJykucmVwbGFjZSgvW1tcXTw+JiJcdTAwMDAtXHUwMDFm
XS9nLCAnJykudHJpbSgpLnNsaWNlKDAsIDIwKTsKfQoKZnVuY3Rpb24gaGFzaFBhc3N3b3JkKHBh
c3N3b3JkLCBzYWx0KSB7CiAgcmV0dXJuIGNyeXB0by5zY3J5cHRTeW5jKFN0cmluZyhwYXNzd29y
ZCksIHNhbHQsIDMyKS50b1N0cmluZygnaGV4Jyk7Cn0KCmZ1bmN0aW9uIGNyZWF0ZUFjY291bnRz
KGZpbGUsIGxvZykgewogIGxldCBhY2NvdW50cyA9IHt9OwogIGxldCBuZXh0SWQgPSAxMDAxOyAv
LyBpZHMgdXAgdG8gMjAgb3BlbiB0aGUgZ2FtZSdzIGRldmVsb3BlciBrZXlzCiAgbGV0IHNhdmVU
aW1lciA9IG51bGw7CiAgaWYgKGZpbGUpIHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHNhdmVkID0g
SlNPTi5wYXJzZShmcy5yZWFkRmlsZVN5bmMoZmlsZSwgJ3V0ZjgnKSk7CiAgICAgIGFjY291bnRz
ID0gc2F2ZWQuYWNjb3VudHMgfHwge307CiAgICAgIG5leHRJZCA9IE1hdGgubWF4KG5leHRJZCwg
TnVtYmVyKHNhdmVkLm5leHRJZCkgfHwgMCk7CiAgICB9IGNhdGNoIChlcnJvcikgewogICAgICBp
ZiAoZXJyb3IuY29kZSAhPT0gJ0VOT0VOVCcpIGxvZyhgaGYgYWNjb3VudHM6IGNvdWxkIG5vdCBy
ZWFkICR7ZmlsZX06ICR7ZXJyb3IubWVzc2FnZX1gKTsKICAgIH0KICB9CiAgY29uc3Qgc2F2ZSA9
ICgpID0+IHsKICAgIGlmICghZmlsZSB8fCBzYXZlVGltZXIpIHJldHVybjsKICAgIHNhdmVUaW1l
ciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICBzYXZlVGltZXIgPSBudWxsOwogICAgICB0cnkg
ewogICAgICAgIGZzLm1rZGlyU3luYyhwYXRoLmRpcm5hbWUoZmlsZSksIHsgcmVjdXJzaXZlOiB0
cnVlIH0pOwogICAgICAgIGNvbnN0IHRlbXBvcmFyeSA9IGAke2ZpbGV9LiR7cHJvY2Vzcy5waWR9
LnRtcGA7CiAgICAgICAgZnMud3JpdGVGaWxlU3luYyh0ZW1wb3JhcnksIEpTT04uc3RyaW5naWZ5
KHsgdmVyc2lvbjogMSwgbmV4dElkLCBhY2NvdW50cyB9LCBudWxsLCAxKSk7CiAgICAgICAgZnMu
cmVuYW1lU3luYyh0ZW1wb3JhcnksIGZpbGUpOwogICAgICB9IGNhdGNoIChlcnJvcikgewogICAg
ICAgIGxvZyhgaGYgYWNjb3VudHM6IGNvdWxkIG5vdCBzYXZlOiAke2Vycm9yLm1lc3NhZ2V9YCk7
CiAgICAgIH0KICAgIH0sIDUwMCk7CiAgICBpZiAoc2F2ZVRpbWVyLnVucmVmKSBzYXZlVGltZXIu
dW5yZWYoKTsKICB9OwogIHJldHVybiB7CiAgICBnZXQoZW1haWwpIHsgcmV0dXJuIGFjY291bnRz
W2VtYWlsXSB8fCBudWxsOyB9LAogICAgYnlJZChpZCkgeyByZXR1cm4gT2JqZWN0LnZhbHVlcyhh
Y2NvdW50cykuZmluZCgoYWNjb3VudCkgPT4gU3RyaW5nKGFjY291bnQuaWQpID09PSBTdHJpbmco
aWQpKSB8fCBudWxsOyB9LAogICAgYnlOYW1lKG5hbWUpIHsgcmV0dXJuIE9iamVjdC52YWx1ZXMo
YWNjb3VudHMpLmZpbmQoKGFjY291bnQpID0+IGFjY291bnQubmFtZS50b0xvd2VyQ2FzZSgpID09
PSBuYW1lLnRvTG93ZXJDYXNlKCkpIHx8IG51bGw7IH0sCiAgICBjcmVhdGUoZW1haWwsIHBhc3N3
b3JkLCBuYW1lLCBjYykgewogICAgICBjb25zdCBzYWx0ID0gY3J5cHRvLnJhbmRvbUJ5dGVzKDEy
KS50b1N0cmluZygnaGV4Jyk7CiAgICAgIGxldCB1bmlxdWUgPSBuYW1lIHx8ICdQbGF5ZXInOwog
ICAgICBmb3IgKGxldCBrID0gMjsgdGhpcy5ieU5hbWUodW5pcXVlKTsgayArPSAxKSB1bmlxdWUg
PSBgJHtuYW1lLnNsaWNlKDAsIDE3KX0ke2t9YDsKICAgICAgY29uc3QgYWNjb3VudCA9IHsKICAg
ICAgICBpZDogbmV4dElkKyssIG5hbWU6IHVuaXF1ZSwgY2M6IGNjIHx8ICdWTicsIHNhbHQsIGhh
c2g6IGhhc2hQYXNzd29yZChwYXNzd29yZCwgc2FsdCksCiAgICAgICAgc2Vzc2lvbjogY3J5cHRv
LnJhbmRvbUludCgxMDAwMDAsIDEwMDAwMDAwMDApLCB2YWx1ZXM6IEFycmF5LmZyb20oeyBsZW5n
dGg6IDMwIH0sIChfLCBrKSA9PiAoayA8IDE5ID8gU1RBUlRfRVhQRVJJRU5DRSA6IDApKSwKICAg
ICAgICBzdGFnZTogU1RPUklFUywgbmFtZUNoYW5nZXM6IDksIGNyZWF0ZWQ6IG5ldyBEYXRlKCku
dG9JU09TdHJpbmcoKSwgLy8gKG5hbWUgY2hhbmdlcyBhcmUgbm90IGNvdW50ZWQgZG93bikKICAg
ICAgfTsKICAgICAgYWNjb3VudHNbZW1haWxdID0gYWNjb3VudDsKICAgICAgc2F2ZSgpOwogICAg
ICByZXR1cm4gYWNjb3VudDsKICAgIH0sCiAgICBjaGVja1Bhc3N3b3JkKGFjY291bnQsIHBhc3N3
b3JkKSB7CiAgICAgIGNvbnN0IGV4cGVjdGVkID0gQnVmZmVyLmZyb20oYWNjb3VudC5oYXNoLCAn
aGV4Jyk7CiAgICAgIGNvbnN0IGdpdmVuID0gQnVmZmVyLmZyb20oaGFzaFBhc3N3b3JkKHBhc3N3
b3JkLCBhY2NvdW50LnNhbHQpLCAnaGV4Jyk7CiAgICAgIHJldHVybiBleHBlY3RlZC5sZW5ndGgg
PT09IGdpdmVuLmxlbmd0aCAmJiBjcnlwdG8udGltaW5nU2FmZUVxdWFsKGV4cGVjdGVkLCBnaXZl
bik7CiAgICB9LAogICAgc2V0UGFzc3dvcmQoYWNjb3VudCwgcGFzc3dvcmQpIHsKICAgICAgYWNj
b3VudC5zYWx0ID0gY3J5cHRvLnJhbmRvbUJ5dGVzKDEyKS50b1N0cmluZygnaGV4Jyk7CiAgICAg
IGFjY291bnQuaGFzaCA9IGhhc2hQYXNzd29yZChwYXNzd29yZCwgYWNjb3VudC5zYWx0KTsKICAg
ICAgc2F2ZSgpOwogICAgfSwKICAgIHNhdmUsCiAgICBmbHVzaCgpIHsKICAgICAgaWYgKCFzYXZl
VGltZXIpIHJldHVybjsKICAgICAgY2xlYXJUaW1lb3V0KHNhdmVUaW1lcik7CiAgICAgIHNhdmVU
aW1lciA9IG51bGw7CiAgICAgIHRyeSB7CiAgICAgICAgZnMubWtkaXJTeW5jKHBhdGguZGlybmFt
ZShmaWxlKSwgeyByZWN1cnNpdmU6IHRydWUgfSk7CiAgICAgICAgZnMud3JpdGVGaWxlU3luYyhm
aWxlLCBKU09OLnN0cmluZ2lmeSh7IHZlcnNpb246IDEsIG5leHRJZCwgYWNjb3VudHMgfSwgbnVs
bCwgMSkpOwogICAgICB9IGNhdGNoIChlcnJvcikgewogICAgICAgIGxvZyhgaGYgYWNjb3VudHM6
IGNvdWxkIG5vdCBzYXZlOiAke2Vycm9yLm1lc3NhZ2V9YCk7CiAgICAgIH0KICAgIH0sCiAgfTsK
fQoKZnVuY3Rpb24gY3JlYXRlSGYoY29uZmlnLCB7IGxvZywgY2xpZW50QWRkcmVzcywgYWxsb3dP
cmlnaW4sIGJ1ZGdldCB9KSB7CiAgY29uc3QgZm9sZGVyID0gY29uZmlnLmhmRGlyIHx8IChjb25m
aWcucGFja3NEaXIgPyBwYXRoLmpvaW4oY29uZmlnLnBhY2tzRGlyLCAnaGYnKSA6ICcnKTsKICBj
b25zdCBhY2NvdW50cyA9IGNyZWF0ZUFjY291bnRzKGZvbGRlciAmJiBwYXRoLmpvaW4oZm9sZGVy
LCAnYWNjb3VudHMuanNvbicpLCBsb2cpOwogIGNvbnN0IHJvb21Db3VudCA9IE1hdGgubWF4KDEs
IE1hdGgubWluKDIwLCBNYXRoLnJvdW5kKGNvbmZpZy5oZlJvb21zIHx8IDQpKSk7CiAgY29uc3Qg
cm9vbXMgPSBbXTsKICBmb3IgKGxldCBudW1iZXIgPSAxOyBudW1iZXIgPD0gcm9vbUNvdW50OyBu
dW1iZXIgKz0gMSkgewogICAgcm9vbXMucHVzaChuZXcgSGZSb29tKHsgbnVtYmVyLCBuYW1lOiBg
UGhvbmcgJHtudW1iZXJ9YCwgZGVzY3JpcHRpb246IGNvbmZpZy5oZlJvb21EZXNjcmlwdGlvbiB8
fCAnT3BlbkxGMiByZWxheScsIGxvZyB9KSk7CiAgfQogIGNvbnN0IGNhcHRjaGFzID0gbmV3IE1h
cCgpOyAvLyBjbGllbnQga2V5IC0+IHsgY29kZSwgdW50aWwgfQogIGNvbnN0IHRyaWVzID0gbmV3
IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVzcyAtPiB7IGNvdW50LCB1bnRpbCB9OiBmYWlsZWQgcGFz
c3dvcmRzIGFuZCBjb2RlcwogIGNvbnN0IGNyZWF0aW9ucyA9IG5ldyBNYXAoKTsgLy8gY2xpZW50
IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwgfTogbmV3IGFjY291bnRzCiAgY29uc3QgbWF5Q3Jl
YXRlID0gKGFkZHJlc3MpID0+IHsKICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgICBsZXQg
ZW50cnkgPSBjcmVhdGlvbnMuZ2V0KGFkZHJlc3MpOwogICAgaWYgKCFlbnRyeSB8fCBlbnRyeS51
bnRpbCA8PSBub3cpIHsKICAgICAgZW50cnkgPSB7IGNvdW50OiAwLCB1bnRpbDogbm93ICsgMzYw
MDAwMCB9OwogICAgICBjcmVhdGlvbnMuc2V0KGFkZHJlc3MsIGVudHJ5KTsKICAgIH0KICAgIGlm
IChlbnRyeS5jb3VudCA+PSAyMCkgcmV0dXJuIGZhbHNlOwogICAgZW50cnkuY291bnQgKz0gMTsK
ICAgIHJldHVybiB0cnVlOwogIH07CiAgY29uc3QgTElNSVQgPSAnPGVuPlRvbyBtYW55IG5ldyBh
Y2NvdW50cyBmcm9tIHlvdXIgbmV0d29yazogdHJ5IGFnYWluIGluIGFuIGhvdXIuPC9lbj48YjU+
VG9vIG1hbnkgbmV3IGFjY291bnRzIGZyb20geW91ciBuZXR3b3JrOiB0cnkgYWdhaW4gaW4gYW4g
aG91ci48L2I1Pic7CgogIGZ1bmN0aW9uIGxvZ2luWG1sKGFjY291bnQsIHJvb3QgPSAnbG9naW4n
KSB7CiAgICBjb25zdCB2YWx1ZXMgPSBhY2NvdW50LnZhbHVlczsKICAgIGNvbnN0IGZpZWxkcyA9
IHZhbHVlcy5tYXAoKHZhbHVlLCBpbmRleCkgPT4gYDxjJHtpbmRleCArIDF9PiR7dmFsdWV9PC9j
JHtpbmRleCArIDF9PmApLmpvaW4oJycpOwogICAgY29uc3QgY29kZSA9IHN0YXR1c0NvZGUodmFs
dWVzLCBhY2NvdW50LmlkLCAwLCBhY2NvdW50LnN0YWdlLCBhY2NvdW50LnNlc3Npb24sIHRydWUp
OwogICAgcmV0dXJuIGA8JHtyb290fT4ke2ZpZWxkc308aT4ke2FjY291bnQuaWR9PC9pPjxuPiR7
eG1sVGV4dChhY2NvdW50Lm5hbWUpfTwvbj48Y2M+JHt4bWxUZXh0KGFjY291bnQuY2MpfTwvY2M+
YAogICAgICArIGA8cz4ke2FjY291bnQuc2Vzc2lvbn08L3M+PGFjY3R5cGU+MDwvYWNjdHlwZT48
c3RhZ2U+JHthY2NvdW50LnN0YWdlfTwvc3RhZ2U+PHY+JHtjb2RlfTwvdj48LyR7cm9vdH0+YDsK
ICB9CgogIGNvbnN0IHBydW5lID0gKCkgPT4gewogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsK
ICAgIGZvciAoY29uc3QgbWFwIG9mIFt0cmllcywgY3JlYXRpb25zXSkgZm9yIChjb25zdCBba2V5
LCBlbnRyeV0gb2YgbWFwKSBpZiAoZW50cnkudW50aWwgPD0gbm93KSBtYXAuZGVsZXRlKGtleSk7
CiAgICBmb3IgKGNvbnN0IFtrZXksIGVudHJ5XSBvZiBjYXB0Y2hhcykgaWYgKGVudHJ5LnVudGls
IDw9IG5vdykgY2FwdGNoYXMuZGVsZXRlKGtleSk7CiAgfTsKICBjb25zdCBwcnVuZVRpbWVyID0g
c2V0SW50ZXJ2YWwocHJ1bmUsIDYwMDAwMCk7CiAgaWYgKHBydW5lVGltZXIudW5yZWYpIHBydW5l
VGltZXIudW5yZWYoKTsKCiAgZnVuY3Rpb24gdG9vTWFueVRyaWVzKGFkZHJlc3MpIHsKICAgIGNv
bnN0IG5vdyA9IERhdGUubm93KCk7CiAgICBjb25zdCBlbnRyeSA9IHRyaWVzLmdldChhZGRyZXNz
KTsKICAgIHJldHVybiBCb29sZWFuKGVudHJ5ICYmIGVudHJ5LnVudGlsID4gbm93ICYmIGVudHJ5
LmNvdW50ID49IDMwKTsKICB9CiAgZnVuY3Rpb24gZmFpbGVkVHJ5KGFkZHJlc3MpIHsKICAgIGNv
bnN0IG5vdyA9IERhdGUubm93KCk7CiAgICBsZXQgZW50cnkgPSB0cmllcy5nZXQoYWRkcmVzcyk7
CiAgICBpZiAoIWVudHJ5IHx8IGVudHJ5LnVudGlsIDw9IG5vdykgewogICAgICBlbnRyeSA9IHsg
Y291bnQ6IDAsIHVudGlsOiBub3cgKyAzNjAwMDAwIH07CiAgICAgIHRyaWVzLnNldChhZGRyZXNz
LCBlbnRyeSk7CiAgICB9CiAgICBlbnRyeS5jb3VudCArPSAxOwogIH0KCiAgZnVuY3Rpb24gY2hl
Y2tDYXB0Y2hhKGtleSwgY29kZSkgewogICAgY29uc3QgZW50cnkgPSBjYXB0Y2hhcy5nZXQoU3Ry
aW5nKGtleSB8fCAnJykpOwogICAgY2FwdGNoYXMuZGVsZXRlKFN0cmluZyhrZXkgfHwgJycpKTsK
ICAgIHJldHVybiBCb29sZWFuKGVudHJ5ICYmIGVudHJ5LnVudGlsID4gRGF0ZS5ub3coKSAmJiBT
dHJpbmcoZW50cnkuY29kZSkgPT09IFN0cmluZyhjb2RlIHx8ICcnKS50cmltKCkpOwogIH0KCiAg
Y29uc3QgZW1haWwgPSAodmFsdWUpID0+IFN0cmluZyh2YWx1ZSB8fCAnJykudHJpbSgpLnRvTG93
ZXJDYXNlKCkuc2xpY2UoMCwgMTAwKTsKCiAgLy8gVGhlIGFuc3dlciB0byBvbmUgb2YgdGhlIGFj
Y291bnQgc2VydmljZXMsIGZyb20gdGhlIHF1ZXJ5IChhbmQgYSBmb3JtIGJvZHksIGlmIGFueSku
CiAgZnVuY3Rpb24gYW5zd2VyKHNlcnZpY2UsIHBhcmFtcywgYWRkcmVzcykgewogICAgY29uc3Qg
Z2V0ID0gKG5hbWUpID0+IHBhcmFtcy5nZXQobmFtZSkgfHwgJyc7CiAgICBpZiAoc2VydmljZSA9
PT0gJ3YwLjcvbG9naW4ucGhwJykgewogICAgICBjb25zdCBlbSA9IGVtYWlsKGdldCgnZW0nKSk7
CiAgICAgIGlmICghZW0pIHJldHVybiAnPGxvZ2luPjxlcnJvcj5lbTwvZXJyb3I+PC9sb2dpbj4n
OwogICAgICBpZiAodG9vTWFueVRyaWVzKGFkZHJlc3MpKSByZXR1cm4gJzxsb2dpbj48ZXJyb3I+
cmVhc29uPC9lcnJvcj48ZW4+VG9vIG1hbnkgd3JvbmcgcGFzc3dvcmRzOiB0cnkgYWdhaW4gaW4g
YW4gaG91ci48L2VuPjxiNT5Ub28gbWFueSB3cm9uZyBwYXNzd29yZHM6IHRyeSBhZ2FpbiBpbiBh
biBob3VyLjwvYjU+PC9sb2dpbj4nOwogICAgICBsZXQgYWNjb3VudCA9IGFjY291bnRzLmdldChl
bSk7CiAgICAgIGlmICghYWNjb3VudCkgewogICAgICAgIGlmICghbWF5Q3JlYXRlKGFkZHJlc3Mp
KSByZXR1cm4gYDxsb2dpbj48ZXJyb3I+cmVhc29uPC9lcnJvcj4ke0xJTUlUfTwvbG9naW4+YDsK
ICAgICAgICBhY2NvdW50ID0gYWNjb3VudHMuY3JlYXRlKGVtLCBnZXQoJ3B3JyksIGNsZWFuTmFt
ZShlbS5zcGxpdCgnQCcpWzBdKSwgJ1ZOJyk7CiAgICAgICAgbG9nKGBoZjogbmV3IGFjY291bnQg
JHthY2NvdW50LmlkfSAiJHthY2NvdW50Lm5hbWV9ImApOwogICAgICB9IGVsc2UgaWYgKCFhY2Nv
dW50cy5jaGVja1Bhc3N3b3JkKGFjY291bnQsIGdldCgncHcnKSkpIHsKICAgICAgICBmYWlsZWRU
cnkoYWRkcmVzcyk7CiAgICAgICAgcmV0dXJuICc8bG9naW4+PGVycm9yPnB3PC9lcnJvcj48L2xv
Z2luPic7CiAgICAgIH0KICAgICAgcmV0dXJuIGxvZ2luWG1sKGFjY291bnQpOwogICAgfQogICAg
aWYgKHNlcnZpY2UgPT09ICd2MC43L2x1LnBocCcpIHsKICAgICAgY29uc3QgYWNjb3VudCA9IGFj
Y291bnRzLmdldChlbWFpbChnZXQoJ2VtJykpKTsKICAgICAgaWYgKCFhY2NvdW50IHx8IFN0cmlu
ZyhhY2NvdW50LmlkKSAhPT0gZ2V0KCdpZCcpIHx8IFN0cmluZyhhY2NvdW50LnNlc3Npb24pICE9
PSBnZXQoJ3MnKSkgcmV0dXJuICc8bHU+PGVycm9yPnNhPC9lcnJvcj48L2x1Pic7CiAgICAgIGZv
ciAobGV0IGsgPSAxOyBrIDw9IDM7IGsgKz0gMSkgewogICAgICAgIGNvbnN0IGluZGV4ID0gTnVt
YmVyKGdldChgaSR7a31gKSk7CiAgICAgICAgY29uc3QgdG8gPSBOdW1iZXIoZ2V0KGB0byR7a31g
KSk7CiAgICAgICAgaWYgKCFOdW1iZXIuaXNJbnRlZ2VyKGluZGV4KSB8fCBpbmRleCA8IDEgfHwg
aW5kZXggPiBDSEFSQUNURVJTLmxlbmd0aCAtIDEgfHwgIU51bWJlci5pc0Zpbml0ZSh0bykpIGNv
bnRpbnVlOwogICAgICAgIGFjY291bnQudmFsdWVzW2luZGV4IC0gMV0gPSBNYXRoLm1heChhY2Nv
dW50LnZhbHVlc1tpbmRleCAtIDFdLCBNYXRoLm1pbihNQVhfRVhQRVJJRU5DRSwgTWF0aC5mbG9v
cih0bykpKTsKICAgICAgfQogICAgICBjb25zdCB1bmxvY2tlZCA9IE51bWJlcihnZXQoJ3VsaScp
KTsKICAgICAgaWYgKE51bWJlci5pc0ludGVnZXIodW5sb2NrZWQpICYmIHVubG9ja2VkID49IDEg
JiYgdW5sb2NrZWQgPD0gMzApIHsKICAgICAgICBhY2NvdW50LnZhbHVlc1t1bmxvY2tlZCAtIDFd
ID0gTWF0aC5tYXgoYWNjb3VudC52YWx1ZXNbdW5sb2NrZWQgLSAxXSwgU1RBUlRfRVhQRVJJRU5D
RSk7CiAgICAgIH0KICAgICAgY29uc3Qgc3RhZ2UgPSBOdW1iZXIoZ2V0KCdzdGcnKSk7CiAgICAg
IGlmIChOdW1iZXIuaXNJbnRlZ2VyKHN0YWdlKSkgYWNjb3VudC5zdGFnZSA9IE1hdGgubWF4KGFj
Y291bnQuc3RhZ2UsIE1hdGgubWluKFNUT1JJRVMsIHN0YWdlKSk7CiAgICAgIGFjY291bnRzLnNh
dmUoKTsKICAgICAgcmV0dXJuIGxvZ2luWG1sKGFjY291bnQsICdsdScpOwogICAgfQogICAgaWYg
KHNlcnZpY2UgPT09ICdjYXAucGhwJykgewogICAgICBjb25zdCBrZXkgPSBjcnlwdG8ucmFuZG9t
Qnl0ZXMoOCkudG9TdHJpbmcoJ2hleCcpOwogICAgICBjb25zdCBjb2RlID0gY3J5cHRvLnJhbmRv
bUludCgxMDAwLCAxMDAwMCk7CiAgICAgIGNhcHRjaGFzLnNldChrZXksIHsgY29kZSwgdW50aWw6
IERhdGUubm93KCkgKyA2MDAwMDAgfSk7CiAgICAgIGlmIChjYXB0Y2hhcy5zaXplID4gMjAwMCkg
Y2FwdGNoYXMuZGVsZXRlKGNhcHRjaGFzLmtleXMoKS5uZXh0KCkudmFsdWUpOwogICAgICByZXR1
cm4gYDxjYXA+PGMxPiR7a2V5fTwvYzE+PGMyPiR7ZW5jb2RlTnVtYmVyKGNvZGUpfTwvYzI+PC9j
YXA+YDsKICAgIH0KICAgIGlmIChzZXJ2aWNlID09PSAncmVnLnBocCcpIHsKICAgICAgaWYgKCFj
aGVja0NhcHRjaGEoZ2V0KCdjJyksIGdldCgncycpKSkgcmV0dXJuICc8cmVnPjxlcnJvcj5jb2Rl
PC9lcnJvcj48L3JlZz4nOwogICAgICBjb25zdCBlbSA9IGVtYWlsKGdldCgnZW0nKSk7CiAgICAg
IGlmICghZW0gfHwgYWNjb3VudHMuZ2V0KGVtKSkgcmV0dXJuICc8cmVnPjxlcnJvcj5zYW1lZW1h
aWw8L2Vycm9yPjwvcmVnPic7CiAgICAgIGNvbnN0IG5hbWUgPSBjbGVhbk5hbWUoZ2V0KCdubScp
KTsKICAgICAgaWYgKCFuYW1lKSByZXR1cm4gJzxyZWc+PGVycm9yPm5hbWU8L2Vycm9yPjwvcmVn
Pic7CiAgICAgIGlmIChhY2NvdW50cy5ieU5hbWUobmFtZSkpIHJldHVybiAnPHJlZz48ZXJyb3I+
c2FtZW5hbWU8L2Vycm9yPjwvcmVnPic7CiAgICAgIGlmICghbWF5Q3JlYXRlKGFkZHJlc3MpKSBy
ZXR1cm4gYDxyZWc+PGVycm9yPmxpbWl0PC9lcnJvcj4ke0xJTUlUfTwvcmVnPmA7CiAgICAgIGNv
bnN0IGFjY291bnQgPSBhY2NvdW50cy5jcmVhdGUoZW0sIGdldCgncHcnKSwgbmFtZSwgU3RyaW5n
KGdldCgnY2MnKSkucmVwbGFjZSgvW15BLVpdL2csICcnKS5zbGljZSgwLCAyKSB8fCAnVk4nKTsK
ICAgICAgbG9nKGBoZjogbmV3IGFjY291bnQgJHthY2NvdW50LmlkfSAiJHthY2NvdW50Lm5hbWV9
IiAocmVnaXN0ZXJlZClgKTsKICAgICAgcmV0dXJuIGxvZ2luWG1sKGFjY291bnQsICdyZWcnKTsK
ICAgIH0KICAgIGNvbnN0IGJ5SWQgPSAoKSA9PiB7CiAgICAgIGNvbnN0IGFjY291bnQgPSBhY2Nv
dW50cy5nZXQoZW1haWwoZ2V0KCdlbScpKSk7CiAgICAgIHJldHVybiBhY2NvdW50ICYmIFN0cmlu
ZyhhY2NvdW50LmlkKSA9PT0gZ2V0KCdpZCcpICYmIFN0cmluZyhhY2NvdW50LnNlc3Npb24pID09
PSBnZXQoJ3NzJykgPyBhY2NvdW50IDogbnVsbDsKICAgIH07CiAgICBpZiAoc2VydmljZSA9PT0g
J25hbWVjaGdfbGVmdC5waHAnKSB7CiAgICAgIGNvbnN0IGFjY291bnQgPSBhY2NvdW50cy5ieUlk
KGdldCgnaWQnKSk7CiAgICAgIHJldHVybiBgPG5hbWVjaGc+PG4+JHthY2NvdW50ID8gYWNjb3Vu
dC5uYW1lQ2hhbmdlcyA6IDB9PC9uPjwvbmFtZWNoZz5gOwogICAgfQogICAgaWYgKHNlcnZpY2Ug
PT09ICduYW1lY2hnLnBocCcpIHsKICAgICAgaWYgKCFjaGVja0NhcHRjaGEoZ2V0KCdjJyksIGdl
dCgncycpKSkgcmV0dXJuICc8bmFtZWNoZz48ZXJyb3I+Y29kZTwvZXJyb3I+PC9uYW1lY2hnPic7
CiAgICAgIGNvbnN0IGFjY291bnQgPSBieUlkKCk7CiAgICAgIGlmICghYWNjb3VudCkgcmV0dXJu
ICc8bmFtZWNoZz48ZXJyb3I+c2E8L2Vycm9yPjwvbmFtZWNoZz4nOwogICAgICBpZiAoIWFjY291
bnRzLmNoZWNrUGFzc3dvcmQoYWNjb3VudCwgZ2V0KCdwdycpKSkgeyBmYWlsZWRUcnkoYWRkcmVz
cyk7IHJldHVybiAnPG5hbWVjaGc+PGVycm9yPnB3ZDwvZXJyb3I+PC9uYW1lY2hnPic7IH0KICAg
ICAgY29uc3QgbmFtZSA9IGNsZWFuTmFtZShnZXQoJ25uJykpOwogICAgICBpZiAoIW5hbWUpIHJl
dHVybiAnPG5hbWVjaGc+PGVycm9yPm5hbWU8L2Vycm9yPjwvbmFtZWNoZz4nOwogICAgICBjb25z
dCBvdGhlciA9IGFjY291bnRzLmJ5TmFtZShuYW1lKTsKICAgICAgaWYgKG90aGVyICYmIG90aGVy
ICE9PSBhY2NvdW50KSByZXR1cm4gJzxuYW1lY2hnPjxlcnJvcj5zYW1lbmFtZTwvZXJyb3I+PC9u
YW1lY2hnPic7CiAgICAgIGFjY291bnQubmFtZSA9IG5hbWU7CiAgICAgIGFjY291bnRzLnNhdmUo
KTsKICAgICAgcmV0dXJuIGA8bmFtZWNoZz48bT4ke2FjY291bnQubmFtZUNoYW5nZXN9PC9tPjwv
bmFtZWNoZz5gOwogICAgfQogICAgaWYgKHNlcnZpY2UgPT09ICdwd2RjaGcucGhwJykgewogICAg
ICBpZiAoIWNoZWNrQ2FwdGNoYShnZXQoJ2MnKSwgZ2V0KCdzJykpKSByZXR1cm4gJzxwd2RjaGc+
PGVycm9yPmNvZGU8L2Vycm9yPjwvcHdkY2hnPic7CiAgICAgIGNvbnN0IGFjY291bnQgPSBieUlk
KCk7CiAgICAgIGlmICghYWNjb3VudCkgcmV0dXJuICc8cHdkY2hnPjxlcnJvcj5zYTwvZXJyb3I+
PC9wd2RjaGc+JzsKICAgICAgaWYgKCFhY2NvdW50cy5jaGVja1Bhc3N3b3JkKGFjY291bnQsIGdl
dCgncHcnKSkpIHsgZmFpbGVkVHJ5KGFkZHJlc3MpOyByZXR1cm4gJzxwd2RjaGc+PGVycm9yPnB3
ZDwvZXJyb3I+PC9wd2RjaGc+JzsgfQogICAgICBhY2NvdW50cy5zZXRQYXNzd29yZChhY2NvdW50
LCBnZXQoJ25wdycpKTsKICAgICAgcmV0dXJuICc8cHdkY2hnPjxvaz4xPC9vaz48L3B3ZGNoZz4n
OwogICAgfQogICAgaWYgKHNlcnZpY2UgPT09ICdwd2RyZXQucGhwJykgewogICAgICAvLyBObyBl
LW1haWwgZ29lcyBvdXQgZnJvbSBoZXJlOiB3aG9ldmVyIHJ1bnMgdGhlIHJlbGF5IGNhbiByZW1v
dmUgdGhlIGFjY291bnQgaW5zdGVhZC4KICAgICAgcmV0dXJuICc8cHdkcmV0PjxlcnJvcj5tYWls
PC9lcnJvcj48L3B3ZHJldD4nOwogICAgfQogICAgcmV0dXJuIG51bGw7CiAgfQoKICBmdW5jdGlv
biByb29tTGlzdFhtbCgpIHsKICAgIGxldCB0ZXh0ID0gJzxyb29tbGlzdD4nOwogICAgZm9yIChj
b25zdCByb29tIG9mIHJvb21zKSB7CiAgICAgIHRleHQgKz0gYDxyb29tPjx0PjE8L3Q+PHJuPiR7
eG1sVGV4dChyb29tLm5hbWUpfTwvcm4+PGRjPiR7eG1sVGV4dChyb29tLmRlc2NyaXB0aW9uKX08
L2RjPjxjYz4ke3Jvb20uY2N9PC9jYz5gCiAgICAgICAgKyBgPG4+JHtyb29tLmNvbm5lY3RlZH08
L24+PG5sPiR7cm9vbS5saW1pdH08L25sPjxwcGw+JHt4bWxUZXh0KHJvb20ucGVvcGxlKCkpfTwv
cHBsPmAKICAgICAgICArIGA8aXA+JHtIT1NUfTwvaXA+PHB0PiR7UE9SVCArIHJvb20ubnVtYmVy
IC0gMX08L3B0Pjwvcm9vbT5gOwogICAgfQogICAgcmV0dXJuIHRleHQgKyAnPC9yb29tbGlzdD4n
OwogIH0KCiAgLy8gUmV0dXJucyB0cnVlIHdoZW4gdGhlIHJlcXVlc3Qgd2FzIG9uZSBvZiB0aGVz
ZSBhbmQgaGFzIGJlZW4gYW5zd2VyZWQgKG9yIGlzIGJlaW5nIGFuc3dlcmVkKS4KICBmdW5jdGlv
biBoYW5kbGUocmVxLCByZXMsIHBhdGhuYW1lKSB7CiAgICBpZiAoIXBhdGhuYW1lLnN0YXJ0c1dp
dGgoJy9oZi8nKSkgcmV0dXJuIGZhbHNlOwogICAgY29uc3QgaGVhZGVycyA9IHsgJ2NhY2hlLWNv
bnRyb2wnOiAnbm8tc3RvcmUnLCAneC1jb250ZW50LXR5cGUtb3B0aW9ucyc6ICdub3NuaWZmJywg
Li4uYWxsb3dPcmlnaW4ocmVxKSB9OwogICAgaWYgKHJlcS5tZXRob2QgPT09ICdPUFRJT05TJykg
ewogICAgICByZXMud3JpdGVIZWFkKDIwNCwgeyAuLi5oZWFkZXJzLCAnYWNjZXNzLWNvbnRyb2wt
YWxsb3ctbWV0aG9kcyc6ICdHRVQsIFBPU1QsIE9QVElPTlMnLCAnYWNjZXNzLWNvbnRyb2wtYWxs
b3ctaGVhZGVycyc6ICdjb250ZW50LXR5cGUnIH0pOwogICAgICByZXMuZW5kKCk7CiAgICAgIHJl
dHVybiB0cnVlOwogICAgfQogICAgY29uc3Qgc2VuZCA9IChzdGF0dXMsIHR5cGUsIGJvZHkpID0+
IHsKICAgICAgcmVzLndyaXRlSGVhZChzdGF0dXMsIHsgLi4uaGVhZGVycywgJ2NvbnRlbnQtdHlw
ZSc6IHR5cGUgfSk7CiAgICAgIHJlcy5lbmQoYm9keSk7CiAgICB9OwogICAgaWYgKHJlcS5tZXRo
b2QgIT09ICdHRVQnICYmIHJlcS5tZXRob2QgIT09ICdQT1NUJykgewogICAgICBzZW5kKDQwNSwg
J3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnLCAnbWV0aG9kIG5vdCBhbGxvd2VkXG4nKTsKICAg
ICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBjb25zdCB1cmwgPSBuZXcgVVJMKHJlcS51cmwsICdo
dHRwOi8vcmVsYXkuaW52YWxpZCcpOwogICAgY29uc3QgbG9jYWwgPSBwYXRobmFtZS5zbGljZSgn
L2hmLycubGVuZ3RoKTsKICAgIGlmIChsb2NhbCA9PT0gJ3Zlci50eHQnKSB7CiAgICAgIHNlbmQo
MjAwLCAndGV4dC94bWw7IGNoYXJzZXQ9dXRmLTgnLCAnPHZlcj48cmVzIHZlcnNpb249IjcwMCIg
bG9jYWw9IjAiIC8+PC92ZXI+Jyk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgaWYgKGxv
Y2FsID09PSAncm9vbXMuanNvbicpIHsKICAgICAgc2VuZCgyMDAsICdhcHBsaWNhdGlvbi9qc29u
OyBjaGFyc2V0PXV0Zi04JywgSlNPTi5zdHJpbmdpZnkoewogICAgICAgIGhvc3Q6IEhPU1QsIHJv
b21zOiByb29tcy5tYXAoKHJvb20pID0+ICh7IHJvb206IHJvb20ubnVtYmVyLCBwb3J0OiBQT1JU
ICsgcm9vbS5udW1iZXIgLSAxLCBuYW1lOiByb29tLm5hbWUsIHBsYXllcnM6IHJvb20uY29ubmVj
dGVkLCBsaW1pdDogcm9vbS5saW1pdCB9KSksCiAgICAgIH0pKTsKICAgICAgcmV0dXJuIHRydWU7
CiAgICB9CiAgICBpZiAobG9jYWwgPT09ICdoZi9ybGcucGhwJykgewogICAgICBzZW5kKDIwMCwg
J3RleHQveG1sOyBjaGFyc2V0PXV0Zi04Jywgcm9vbUxpc3RYbWwoKSk7CiAgICAgIHJldHVybiB0
cnVlOwogICAgfQogICAgaWYgKGxvY2FsLnN0YXJ0c1dpdGgoJ3MvJykpIHsKICAgICAgLy8gVGhl
IGdhbWUgcG9zdHMgaXRzIGZvcm1zIHdpdGggdGhlIHZhbHVlcyBpbiB0aGUgYWRkcmVzczsgYSBi
b2R5LCBpZiBhbnksIGlzIHJlYWQgYXMgYSBmb3JtIHRvby4KICAgICAgbGV0IGJvZHkgPSAnJzsK
ICAgICAgcmVxLnNldEVuY29kaW5nKCd1dGY4Jyk7CiAgICAgIHJlcS5vbignZGF0YScsIChjaHVu
aykgPT4geyBpZiAoYm9keS5sZW5ndGggPCA4MTkyKSBib2R5ICs9IGNodW5rOyB9KTsKICAgICAg
cmVxLm9uKCdlbmQnLCAoKSA9PiB7CiAgICAgICAgY29uc3QgcGFyYW1zID0gbmV3IFVSTFNlYXJj
aFBhcmFtcyh1cmwuc2VhcmNoKTsKICAgICAgICBpZiAoYm9keSAmJiAvXltcdyUuKz0mLV0qJC8u
dGVzdChib2R5KSkgZm9yIChjb25zdCBba2V5LCB2YWx1ZV0gb2YgbmV3IFVSTFNlYXJjaFBhcmFt
cyhib2R5KSkgaWYgKCFwYXJhbXMuaGFzKGtleSkpIHBhcmFtcy5zZXQoa2V5LCB2YWx1ZSk7CiAg
ICAgICAgbGV0IHJlcGx5OwogICAgICAgIHRyeSB7CiAgICAgICAgICByZXBseSA9IGFuc3dlcihs
b2NhbC5zbGljZSgyKSwgcGFyYW1zLCBjbGllbnRBZGRyZXNzKHJlcSkpOwogICAgICAgIH0gY2F0
Y2ggKGVycm9yKSB7CiAgICAgICAgICBsb2coYGhmOiAke2xvY2FsfTogJHtlcnJvci5zdGFjayB8
fCBlcnJvcn1gKTsKICAgICAgICAgIHJlcGx5ID0gJzxlcnJvcj48ZXJyb3I+c2VydmVyPC9lcnJv
cj48L2Vycm9yPic7CiAgICAgICAgfQogICAgICAgIGlmIChyZXBseSA9PT0gbnVsbCkgc2VuZCg0
MDQsICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JywgJ25vdCBmb3VuZFxuJyk7CiAgICAgICAg
ZWxzZSBzZW5kKDIwMCwgJ3RleHQveG1sOyBjaGFyc2V0PXV0Zi04JywgcmVwbHkpOwogICAgICB9
KTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAgICBzZW5kKDQwNCwgJ3RleHQvcGxhaW47IGNo
YXJzZXQ9dXRmLTgnLCAnbm90IGZvdW5kXG4nKTsKICAgIHJldHVybiB0cnVlOwogIH0KCiAgLy8g
QSBnYW1lJ3Mgc29ja2V0IHRvIHJvb20gbiwgdGhyb3VnaCB0aGUgcGFnZSdzIFdlYlNvY2tldC4K
ICBmdW5jdGlvbiBjb25uZWN0KHdzLCByZXEsIHVybCkgewogICAgY29uc3QgbnVtYmVyID0gTnVt
YmVyKHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdyb29tJykpOwogICAgY29uc3Qgcm9vbSA9IHJvb21z
W251bWJlciAtIDFdOwogICAgaWYgKCFOdW1iZXIuaXNJbnRlZ2VyKG51bWJlcikgfHwgIXJvb20p
IHsKICAgICAgd3MuY2xvc2UoNDAwMCwgJ1JlbGF5OiBubyBzdWNoIEhlcm8gRmlnaHRlciByb29t
Jyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IGNvbm5lY3Rpb24gPSBuZXcgSGZDb25u
ZWN0aW9uKHJvb20sIHsKICAgICAgd3JpdGUodGV4dCkgewogICAgICAgIGlmICh3cy5yZWFkeVN0
YXRlICE9PSAxKSByZXR1cm47CiAgICAgICAgaWYgKHdzLmJ1ZmZlcmVkQW1vdW50ID4gY29uZmln
Lm1heEJ1ZmZlcmVkQnl0ZXMpIHsKICAgICAgICAgIHdzLmNsb3NlKDQwMTYsICdSZWxheTogeW91
ciBjb25uZWN0aW9uIGlzIHRvbyBzbG93IGZvciB0aGUgZ2FtZScpOwogICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICB3cy5zZW5kKEJ1ZmZlci5mcm9tKHRleHQsICd1dGY4JyksIHsg
YmluYXJ5OiB0cnVlIH0pOwogICAgICB9LAogICAgICBjbG9zZSgpIHsgaWYgKHdzLnJlYWR5U3Rh
dGUgPT09IDAgfHwgd3MucmVhZHlTdGF0ZSA9PT0gMSkgd3MuY2xvc2UoMTAwMCwgJ1JlbGF5OiBy
b29tIGxlZnQnKTsgfSwKICAgIH0sIHsgYWRkcmVzczogY2xpZW50QWRkcmVzcyhyZXEpIH0pOwog
ICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSkgPT4gewogICAgICBpZiAoYnVkZ2V0ICYmICFidWRn
ZXQod3MsIGRhdGEubGVuZ3RoKSkgewogICAgICAgIHdzLmNsb3NlKDQwMDcsICdSZWxheTogdG9v
IG11Y2ggdHJhZmZpYycpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBjb25uZWN0aW9u
LnJlY2VpdmUoQnVmZmVyLmlzQnVmZmVyKGRhdGEpID8gZGF0YSA6IEJ1ZmZlci5mcm9tKGRhdGEp
KTsKICAgIH0pOwogICAgd3Mub24oJ2Nsb3NlJywgKCkgPT4gY29ubmVjdGlvbi5jbG9zZWQoKSk7
CiAgfQoKICByZXR1cm4gewogICAgaGFuZGxlLAogICAgY29ubmVjdCwKICAgIHJvb21zLAogICAg
YWNjb3VudHMsCiAgICBkZXNjcmliZTogKCkgPT4gKHsgcm9vbXM6IHJvb21zLmxlbmd0aCwgcGxh
eWVyczogcm9vbXMucmVkdWNlKChzdW0sIHJvb20pID0+IHN1bSArIHJvb20uY29ubmVjdGVkLCAw
KSB9KSwKICAgIGNsb3NlKCkgewogICAgICBjbGVhckludGVydmFsKHBydW5lVGltZXIpOwogICAg
ICBmb3IgKGNvbnN0IHJvb20gb2Ygcm9vbXMpIHJvb20uY2xvc2UoKTsKICAgICAgYWNjb3VudHMu
Zmx1c2goKTsKICAgIH0sCiAgfTsKfQoKLy8gVGhlIGFkZHJlc3MgdGhlIGdhbWUgaXMgZ2l2ZW4g
Zm9yIHRoZSByb29tczogYW55IG5hbWUgd29ya3MsIHRoZSBwYWdlJ3Mgc29ja2V0IHByb3h5IG1h
cHMgaXQgKHdpdGgKLy8gdGhlIHBvcnQsIG9uZSBwZXIgcm9vbSkgdG8gdGhlIHJlbGF5J3MgV2Vi
U29ja2V0Lgpjb25zdCBIT1NUID0gJ2hmLm9wZW5sZjInOwpjb25zdCBQT1JUID0gODg4ODsKCm1v
ZHVsZS5leHBvcnRzID0geyBjcmVhdGVIZiwgc3RhdHVzQ29kZSwgZW5jb2RlTnVtYmVyLCBIT1NU
LCBQT1JUIH07Cg==
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
MCk7CiAgICB0aGlzLndpblJlcG9ydGVkID0gZmFsc2U7IC8vIGguYwogICAgdGhpcy5zdGFydGlu
ZyA9IGZhbHNlOyAvLyBNYWluLnI6IGEgZmlnaHQgaXMgc3RhcnRpbmc7IGZyYW1lcyB3YWl0IHVu
dGlsIGV2ZXJ5IGdhbWUgaGFzIHN0YXJ0ZWQKICAgIHRoaXMuY291bnRkb3duID0geyBvbjogZmFs
c2UsIGNvdW50OiBDT1VOVERPV04sIGFjdGlvbjogJycgfTsgLy8gVC5hLCBULmIsIFQuZAogICAg
dGhpcy5maWdodGluZ05vdyA9IGZhbHNlOyAvLyBNYWluLmFtCiAgICB0aGlzLm1vZGUgPSAnV0FJ
VFJPT00nOyAvLyBNYWluLmFrCiAgICB0aGlzLnBhZ2UgPSAnV0FJVFJPT00nOyAvLyBNYWluLmFs
CiAgICB0aGlzLnByZXZpb3VzUGFnZSA9ICcnOyAvLyBNYWluLmFuCiAgICB0aGlzLnN0b3J5ID0g
MDsgLy8gTWFpbi5hbwogICAgdGhpcy5iYXR0bGVUeXBlID0gMTExMTsgLy8gTWFpbi5hQwogICAg
dGhpcy5wcmVzZXQgPSAtMTsgLy8gTWFpbi5hRAogICAgdGhpcy50ZWFtcyA9IDQ7IC8vIE1haW4u
YUUKICAgIHRoaXMudGVhbU1hcCA9IFswLCAxLCAyLCAzXTsgLy8gTWFpbi5hRgogICAgdGhpcy5y
ZXNldCgpOwogICAgdGhpcy5jbG9zZWQgPSBmYWxzZTsKICAgIHRoaXMudGltZXJzID0gW107CiAg
ICAvLyBUaGUgb3JpZ2luYWwncyB0aHJlYWRzOiB0aGUgY291bnRkb3duIChULCBldmVyeSAxMDAg
bXMpLCBmcmFtZSBzZW5kaW5nIChhdiwgZXZlcnkgMTAgbXMpIGFuZAogICAgLy8gdGhlIHdhdGNo
ZG9nIHRoYXQgcGluZ3MgYW5kIHRpbWVzIG91dCBnYW1lcyAoYUEsIGV2ZXJ5IDIgcyBhZnRlciAx
MCBzKS4KICAgIHRoaXMuY291bnRkb3duVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHRoaXMuY291
bnRkb3duVGljaygpLCAxMDApOwogICAgdGhpcy50aW1lcnMucHVzaChzZXRJbnRlcnZhbCgoKSA9
PiB0aGlzLmZsdXNoVGljaygpLCAxMCkpOwogICAgdGhpcy53YXRjaGRvZ1N0YXJ0ID0gc2V0VGlt
ZW91dCgoKSA9PiB7IHRoaXMudGltZXJzLnB1c2goc2V0SW50ZXJ2YWwoKCkgPT4gdGhpcy53YXRj
aGRvZygpLCAyMDAwKSk7IH0sIDEwMDAwKTsKICAgIGZvciAoY29uc3QgdGltZXIgb2YgdGhpcy50
aW1lcnMpIGlmICh0aW1lci51bnJlZikgdGltZXIudW5yZWYoKTsKICB9CgogIG5leHRJbnQoYm91
bmQpIHsgcmV0dXJuIE1hdGguZmxvb3IodGhpcy5yYW5kb20oKSAqIGJvdW5kKTsgfQoKICBjbG9z
ZSgpIHsKICAgIHRoaXMuY2xvc2VkID0gdHJ1ZTsKICAgIGNsZWFyVGltZW91dCh0aGlzLmNvdW50
ZG93blRpbWVyKTsKICAgIGNsZWFyVGltZW91dCh0aGlzLndhdGNoZG9nU3RhcnQpOwogICAgZm9y
IChjb25zdCB0aW1lciBvZiB0aGlzLnRpbWVycykgY2xlYXJJbnRlcnZhbCh0aW1lcik7CiAgICBm
b3IgKGNvbnN0IGNvbm5lY3Rpb24gb2YgWy4uLnRoaXMuY29ubmVjdGlvbnNdKSBjb25uZWN0aW9u
LmNsb3NlKCk7CiAgfQoKICAvLyBNYWluLms6IHRoZSBzZXR0aW5ncyBhbmQgdGhlIG1lbiBhIHJv
b20gc3RhcnRzIHdpdGguCiAgcmVzZXQoKSB7CiAgICB0aGlzLmFsbG93Sm9pbldoZW5GaWdodGlu
ZyA9IHRydWU7IC8vIE1haW4uVgogICAgdGhpcy5waWNrTXVzaWMoKTsKICAgIHRoaXMubXVzaWNS
YW5kb20gPSB0cnVlOyAvLyBNYWluLlgKICAgIHRoaXMubXVsdGlwbGFuZSA9IHRydWU7IC8vIE1h
aW4uYWIKICAgIHRoaXMuYmFja2dyb3VuZCA9ICdyb29tMSc7IC8vIE1haW4uWQogICAgdGhpcy5i
YWNrZ3JvdW5kQ2hvc2VuID0gJ3Jvb20xJzsgLy8gTWFpbi5aCiAgICB0aGlzLmJhY2tncm91bmRS
YW5kb20gPSBmYWxzZTsgLy8gTWFpbi5XCiAgICB0aGlzLmhvcnNlcyA9IDA7IC8vIE1haW4uYWMK
ICAgIHRoaXMuZ2lhbnRPYmplY3RzID0gMDsgLy8gTWFpbi5hZAogICAgdGhpcy5kaWZmaWN1bHR5
ID0gMDsgLy8gTWFpbi5hZQogICAgdGhpcy5ub3JtYWxpemVMZXZlbCA9IDE7IC8vIE1haW4uYWkK
ICAgIHRoaXMuZGlub3NhdXJzID0gMDsgLy8gTWFpbi5hagogICAgdGhpcy50ZXN0VHJvb3BzID0g
MDsgLy8gTWFpbi5hZgogICAgdGhpcy5zb2xkaWVyTnVtYmVyID0gMTsgLy8gTWFpbi5hZwogICAg
dGhpcy5zb2xkaWVyUmVzZXJ2ZWQgPSAxOyAvLyBNYWluLmFoCiAgICB0aGlzLnN0b3J5ID0gMDsK
ICAgIHRoaXMubW9kZSA9ICdXQUlUUk9PTSc7CiAgICB0aGlzLnBhZ2UgPSAnV0FJVFJPT00nOwog
ICAgdGhpcy5wcmV2aW91c1BhZ2UgPSAnJzsKICAgIHRoaXMubWVuID0gQXJyYXkuZnJvbSh7IGxl
bmd0aDogTUVOIH0sIG5ld01hbik7CiAgfQoKICBwaWNrQmFja2dyb3VuZCgpIHsgdGhpcy5iYWNr
Z3JvdW5kID0gQkFDS0dST1VORFNbdGhpcy5uZXh0SW50KEJBQ0tHUk9VTkRTLmxlbmd0aCldOyB9
IC8vIE1haW4uYQogIHBpY2tNdXNpYygpIHsgdGhpcy5tdXNpYyA9IE1VU0lDW3RoaXMubmV4dElu
dChNVVNJQy5sZW5ndGgpXTsgfSAvLyBNYWluLmIKCiAgLy8gTWFpbi5mOiBjb3VudHMgdGhlIGNv
bXB1dGVyczsgYSByb29tIG5vYm9keSBwbGF5cyBpbiBhbnkgbW9yZSBzdGFydHMgb3Zlci4KICBy
ZWNvdW50KCkgewogICAgbGV0IGVtcHR5ID0gdHJ1ZTsKICAgIHRoaXMuY29ubmVjdGVkID0gMDsK
ICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAg
ICAgIGNvbnN0IHNsb3QgPSB0aGlzLnNsb3RzW2luZGV4XTsKICAgICAgaWYgKHNsb3Qub25saW5l
KSB0aGlzLmNvbm5lY3RlZCArPSAxOwogICAgICBpZiAodGhpcy5wYWdlID09PSAnV0FJVFJPT00n
KSB7CiAgICAgICAgaWYgKHNsb3Qub25saW5lKSBlbXB0eSA9IGZhbHNlOwogICAgICB9IGVsc2Ug
aWYgKHNsb3Qub25saW5lICYmIHNsb3QucGFnZSAhPT0gJ1dBSVRST09NJykgewogICAgICAgIGVt
cHR5ID0gZmFsc2U7CiAgICAgIH0KICAgIH0KICAgIGlmIChlbXB0eSkgewogICAgICB0aGlzLnJl
c2V0KCk7CiAgICAgIHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwogICAgICB0aGlzLmJy
b2FkY2FzdFNldHRpbmcoLTEpOwogICAgICB0aGlzLmJyb2FkY2FzdFN0YXR1cygpOwogICAgICB0
aGlzLmJyb2FkY2FzdE1lbigxKTsKICAgIH0KICB9CgogIG9ubGluZSgpIHsKICAgIGNvbnN0IGxp
c3QgPSBbXTsKICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCAr
PSAxKSBpZiAodGhpcy5zbG90c1tpbmRleF0ub25saW5lKSBsaXN0LnB1c2godGhpcy5zbG90c1tp
bmRleF0pOwogICAgcmV0dXJuIGxpc3Q7CiAgfQoKICBicm9hZGNhc3QodGV4dCkgeyBmb3IgKGNv
bnN0IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkgc2xvdC5jb25uZWN0aW9uLnNlbmQodGV4dCk7IH0g
Ly8gaC5hKFN0cmluZykKICBicm9hZGNhc3RMaXN0KGpvaW5lZCwgcXVpdCkgeyBmb3IgKGNvbnN0
IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkgc2xvdC5jb25uZWN0aW9uLnNlbmRMaXN0KGpvaW5lZCwg
cXVpdCk7IH0gLy8gaC5hKGludCwgaW50KQogIGJyb2FkY2FzdFNldHRpbmcoY2lkKSB7IGZvciAo
Y29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSBzbG90LmNvbm5lY3Rpb24uc2VuZFNldHRpbmco
Y2lkKTsgfSAvLyBoLmIoaW50KQogIGJyb2FkY2FzdEdhbWVTZXR0aW5nKGNpZCkgeyBmb3IgKGNv
bnN0IHNsb3Qgb2YgdGhpcy5vbmxpbmUoKSkgc2xvdC5jb25uZWN0aW9uLnNlbmRHYW1lU2V0dGlu
ZyhjaWQpOyB9IC8vIGguYyhpbnQpCiAgYnJvYWRjYXN0U3RhdHVzKCkgeyAvLyBoLmUKICAgIGZv
ciAoY29uc3Qgc2xvdCBvZiB0aGlzLm9ubGluZSgpKSB7CiAgICAgIHNsb3QuY29ubmVjdGlvbi5z
ZW5kKGA8c3RhdHVzPjxtb2RlPiR7dGhpcy5tb2RlfTwvbW9kZT48cGFnZT4ke3RoaXMucGFnZX08
L3BhZ2U+PHByZXBhZ2U+JHt0aGlzLnByZXZpb3VzUGFnZX08L3ByZXBhZ2U+YAogICAgICAgICsg
YDxzdG9yeWk+JHt0aGlzLnN0b3J5fTwvc3RvcnlpPjwvc3RhdHVzPmApOwogICAgfQogIH0KICAv
LyBoLmEoaW50KTogc29sZGllcnMgd2hvc2UgY29tbWFuZGVyJ3MgY29tcHV0ZXIgbGVmdCBnbyB0
b287IHRoZW4gZXZlcnlvbmUgZ2V0cyB0aGUgbWVuLgogIGJyb2FkY2FzdE1lbihjaGFuZ2VkKSB7
CiAgICBmb3IgKGNvbnN0IG1hbiBvZiB0aGlzLm1lbikgewogICAgICBpZiAoIW1hbi5leGlzdHMg
fHwgbWFuLmNvbW1hbmRlciA9PT0gLTEpIGNvbnRpbnVlOwogICAgICBjb25zdCBjb21tYW5kZXIg
PSB0aGlzLm1lblttYW4uY29tbWFuZGVyXTsKICAgICAgaWYgKGNvbW1hbmRlci5jbGllbnQgIT09
IC0xICYmICF0aGlzLnNsb3RzW2NvbW1hbmRlci5jbGllbnRdLm9ubGluZSkgbWFuLmV4aXN0cyA9
IGZhbHNlOwogICAgfQogICAgZm9yIChjb25zdCBzbG90IG9mIHRoaXMub25saW5lKCkpIHNsb3Qu
Y29ubmVjdGlvbi5zZW5kTWVuKGNoYW5nZWQpOwogIH0KICBicm9hZGNhc3RDb3VudCgpIHsgLy8g
aC5jKCkKICAgIHRoaXMuYnJvYWRjYXN0KGA8c3RhcnRjb3VudD48YWN0aW9uPiR7dGhpcy5jb3Vu
dGRvd24uYWN0aW9ufTwvYWN0aW9uPjxjb3VudD4ke3RoaXMuY291bnRkb3duLmNvdW50fTwvY291
bnQ+YAogICAgICArIGA8cGFnZT4ke3RoaXMucGFnZX08L3BhZ2U+PC9zdGFydGNvdW50PmApOwog
IH0KICBicm9hZGNhc3RDbGljayhjaWQsIHdoYXQpIHsgdGhpcy5icm9hZGNhc3QoYDxjaGF0Mj48
Yz4ke2NpZH08L2M+PG0+JHt3aGF0fTwvbT48L2NoYXQyPmApOyB9IC8vIGguYShpbnQsIFN0cmlu
ZykKICBuZXdTZWVkKCkgeyAvLyBoLmYKICAgIHRoaXMuc2VlZCA9IHRoaXMubmV4dEludCg1MDAw
KTsKICAgIHRoaXMuYnJvYWRjYXN0KGA8cnA+PHJwPiR7dGhpcy5zZWVkfTwvcnA+PC9ycD5gKTsK
ICB9CgogIC8vIGguYSgpOiB0aGUgZnJhbWVzIG9mIHRoZSBmaWdodCBzdGFydCBvdmVyLgogIHJl
c2V0RnJhbWVzKCkgewogICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGlu
ZGV4ICs9IDEpIHsKICAgICAgY29uc3Qgc2xvdCA9IHRoaXMuc2xvdHNbaW5kZXhdOwogICAgICBz
bG90LmZsdXNoZXMgPSAwOwogICAgICBzbG90LnBhdXNlZCA9IGZhbHNlOwogICAgICBzbG90LmZp
Z2h0aW5nID0gZmFsc2U7CiAgICAgIHNsb3QubGFzdFBhY2tldCA9IC0xOwogICAgICBzbG90Lmxl
ZnRGcmFtZSA9IC0xOwogICAgICBpZiAoc2xvdC5jb25uZWN0aW9uKSBzbG90LmNvbm5lY3Rpb24u
cmVzZXRGcmFtZXMoKTsKICAgIH0KICB9CgogIC8vIGguYigpOiBsYXRlbmNpZXMgZWFzZSB0b3dh
cmRzIHRoZWlyIHRhcmdldHMuCiAgZWFzZUxhdGVuY2llcygpIHsKICAgIGZvciAobGV0IGluZGV4
ID0gMDsgaW5kZXggPCBDTElFTlRTOyBpbmRleCArPSAxKSB7CiAgICAgIGNvbnN0IHNsb3QgPSB0
aGlzLnNsb3RzW2luZGV4XTsKICAgICAgaWYgKHNsb3Qub25saW5lKSBzbG90LmxhdGVuY3kgPSBN
YXRoLnRydW5jKChzbG90LmxhdGVuY3lUYXJnZXQgKyBzbG90LmxhdGVuY3kgKiAzKSAvIDQpOwog
ICAgfQogICAgdGhpcy5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgfQoKICAvLyBULmEoKTogYSBm
aWdodCBzdGFydHM7IGZyYW1lcyB3YWl0IGZvciBldmVyeSBnYW1lLgogIHN0YXJ0RmlnaHQoKSB7
CiAgICBmb3IgKGNvbnN0IHNsb3Qgb2YgdGhpcy5zbG90cykgc2xvdC5zdGFydGVkID0gZmFsc2U7
CiAgICB0aGlzLnN0YXJ0aW5nID0gdHJ1ZTsKICB9CgogIC8vIFRoZSBjb3VudGRvd24gdGhyZWFk
IChUKTogZXZlcnkgMTAwIG1zLCBhbmQgNDAwIG1zIG1vcmUgYWZ0ZXIgYSBzdGVwIG9mIGEgY291
bnRkb3duLgogIGNvdW50ZG93blRpY2soKSB7CiAgICBpZiAodGhpcy5jbG9zZWQpIHJldHVybjsK
ICAgIGxldCBkZWxheSA9IDEwMDsKICAgIHRyeSB7CiAgICAgIGlmICh0aGlzLnN0YXJ0aW5nKSB7
CiAgICAgICAgdGhpcy5zdGFydGluZyA9IGZhbHNlOwogICAgICAgIGZvciAoY29uc3Qgc2xvdCBv
ZiB0aGlzLnNsb3RzKSB7CiAgICAgICAgICBpZiAoc2xvdC5vbmxpbmUgJiYgIXNsb3Quc3RhcnRl
ZCAmJiBzbG90LnBhZ2UgIT09ICdXQUlUUk9PTScpIHRoaXMuc3RhcnRpbmcgPSB0cnVlOwogICAg
ICAgIH0KICAgICAgICBpZiAoIXRoaXMuc3RhcnRpbmcpIHsKICAgICAgICAgIGZvciAoY29uc3Qg
c2xvdCBvZiB0aGlzLnNsb3RzKSBpZiAoc2xvdC5jb25uZWN0aW9uKSBzbG90LmNvbm5lY3Rpb24u
cmVzZXRGcmFtZXMoKTsKICAgICAgICAgIHRoaXMubmV3U2VlZCgpOwogICAgICAgICAgdGhpcy5i
cm9hZGNhc3QoJzxhbGxzdGFydGVkZ2FtZT48L2FsbHN0YXJ0ZWRnYW1lPicpOwogICAgICAgIH0K
ICAgICAgfQogICAgICBjb25zdCBjb3VudGRvd24gPSB0aGlzLmNvdW50ZG93bjsKICAgICAgaWYg
KGNvdW50ZG93bi5vbikgewogICAgICAgIGNvdW50ZG93bi5jb3VudCAtPSAxOwogICAgICAgIGlm
IChjb3VudGRvd24uY291bnQgPD0gMCkgewogICAgICAgICAgdGhpcy5jb3VudGRvd25Eb25lKGNv
dW50ZG93bi5hY3Rpb24pOwogICAgICAgICAgdGhpcy5icm9hZGNhc3RDb3VudCgpOwogICAgICAg
ICAgY291bnRkb3duLmNvdW50ID0gQ09VTlRET1dOOwogICAgICAgICAgY291bnRkb3duLm9uID0g
ZmFsc2U7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgIHRoaXMuYnJvYWRjYXN0Q291bnQoKTsK
ICAgICAgICB9CiAgICAgICAgZGVsYXkgKz0gNDAwOwogICAgICB9CiAgICB9IGNhdGNoIChlcnJv
cikgewogICAgICB0aGlzLmxvZyhgaGYgcm9vbSAke3RoaXMubnVtYmVyfTogY291bnRkb3duOiAk
e2Vycm9yLnN0YWNrIHx8IGVycm9yfWApOwogICAgfQogICAgdGhpcy5jb3VudGRvd25UaW1lciA9
IHNldFRpbWVvdXQoKCkgPT4gdGhpcy5jb3VudGRvd25UaWNrKCksIGRlbGF5KTsKICB9CgogIGVu
dGVyUGFnZShwYWdlLCBwcmV2aW91cykgewogICAgdGhpcy5wYWdlID0gcGFnZTsKICAgIHRoaXMu
ZmlnaHRpbmdOb3cgPSBmYWxzZTsKICAgIHRoaXMucHJldmlvdXNQYWdlID0gcHJldmlvdXM7CiAg
fQoKICBjb3VudGRvd25Eb25lKGFjdGlvbikgewogICAgY29uc3QgcGFnZSA9IHRoaXMucGFnZTsK
ICAgIGNvbnN0IG1vZGUgPSB0aGlzLm1vZGU7CiAgICBpZiAoYWN0aW9uID09PSAnY2xpY2t2cycg
JiYgcGFnZSA9PT0gJ1dBSVRST09NJykgewogICAgICB0aGlzLm1vZGUgPSAnVlNNT0RFJzsKICAg
ICAgdGhpcy5lbnRlclBhZ2UoJ0NIQVJNRU5VJywgJ1dBSVRST09NJyk7CiAgICAgIHRoaXMuYmF0
dGxlVHlwZSA9IDExMTE7CiAgICAgIHRoaXMucHJlc2V0ID0gLTE7CiAgICAgIGlmICh0aGlzLmJh
Y2tncm91bmRDaG9zZW4gPT09ICdyYW5kb20nKSB7CiAgICAgICAgdGhpcy5iYWNrZ3JvdW5kID0g
QkFDS0dST1VORFNbdGhpcy5uZXh0SW50KEJBQ0tHUk9VTkRTLmxlbmd0aCldOwogICAgICAgIHRo
aXMuYmFja2dyb3VuZFJhbmRvbSA9IHRydWU7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgdGhpcy5i
YWNrZ3JvdW5kID0gdGhpcy5iYWNrZ3JvdW5kQ2hvc2VuOwogICAgICAgIHRoaXMuYmFja2dyb3Vu
ZFJhbmRvbSA9IGZhbHNlOwogICAgICB9CiAgICAgIHRoaXMuYWZ0ZXJQYWdlQ2hhbmdlKCk7CiAg
ICB9IGVsc2UgaWYgKGFjdGlvbiA9PT0gJ2NsaWNrc3RvcnknICYmIHBhZ2UgPT09ICdXQUlUUk9P
TScpIHsKICAgICAgdGhpcy5tb2RlID0gJ1NUT1JZTU9ERSc7CiAgICAgIHRoaXMuZW50ZXJQYWdl
KCdTVE9SWU1FTlUnLCAnV0FJVFJPT00nKTsKICAgICAgdGhpcy5hZnRlclBhZ2VDaGFuZ2UoKTsK
ICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAnY2xpY2tiYXR0bGUnICYmIHBhZ2UgPT09ICdXQUlU
Uk9PTScpIHsKICAgICAgdGhpcy5tb2RlID0gJ0JBVFRMRU1PREUnOwogICAgICB0aGlzLmVudGVy
UGFnZSgnQkFUVExFU0VUVElOR01FTlUnLCAnV0FJVFJPT00nKTsKICAgICAgdGhpcy5iYXR0bGVU
eXBlID0gMTExMTsKICAgICAgdGhpcy5wcmVzZXQgPSAtMTsKICAgICAgdGhpcy50ZWFtcyA9IDQ7
CiAgICAgIHRoaXMuYmFja2dyb3VuZCA9ICdiYXR0bGU0JzsKICAgICAgdGhpcy5iYWNrZ3JvdW5k
UmFuZG9tID0gZmFsc2U7CiAgICAgIHRoaXMuYWZ0ZXJQYWdlQ2hhbmdlKCk7CiAgICB9IGVsc2Ug
aWYgKGFjdGlvbiA9PT0gJ2NsaWNrbmV4dCcgJiYgcGFnZSA9PT0gJ0JBVFRMRVNFVFRJTkdNRU5V
JykgewogICAgICB0aGlzLmVudGVyUGFnZSgnQ0hBUk1FTlUnLCAnQkFUVExFU0VUVElOR01FTlUn
KTsKICAgICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IE1FTjsgaW5kZXggKz0gMSkgewog
ICAgICAgIGNvbnN0IG1hbiA9IHRoaXMubWVuW2luZGV4XTsKICAgICAgICBpZiAobWFuLmV4aXN0
cyAmJiBtYW4udGVhbSA+PSB0aGlzLnRlYW1zKSBtYW4udGVhbSAlPSB0aGlzLnRlYW1zOwogICAg
ICAgIGlmIChpbmRleCA8IE1FTiAtIDEgJiYgbWFuLmNvbnRyb2xsZXIgPj0gMCkgewogICAgICAg
ICAgZm9yIChsZXQgb3RoZXIgPSBpbmRleCArIDE7IG90aGVyIDwgTUVOOyBvdGhlciArPSAxKSB7
CiAgICAgICAgICAgIGNvbnN0IG5leHQgPSB0aGlzLm1lbltvdGhlcl07CiAgICAgICAgICAgIGlm
IChuZXh0LmV4aXN0cyAmJiBuZXh0LmNvbnRyb2xsZXIgPj0gMCAmJiBuZXh0LmNsaWVudCA9PT0g
bWFuLmNsaWVudCkgbmV4dC50ZWFtID0gbWFuLnRlYW07CiAgICAgICAgICB9CiAgICAgICAgfQog
ICAgICB9CiAgICAgIHRoaXMuYWZ0ZXJQYWdlQ2hhbmdlKCk7CiAgICB9IGVsc2UgaWYgKGFjdGlv
biA9PT0gJ2NsaWNrbmV4dCcgJiYgcGFnZSA9PT0gJ1NUT1JZTUVOVScpIHsKICAgICAgdGhpcy5l
bnRlclBhZ2UoJ0NIQVJNRU5VJywgJ1NUT1JZTUVOVScpOwogICAgICB0aGlzLmFmdGVyUGFnZUNo
YW5nZSgpOwogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09ICdjbGlja25leHQnICYmIHBhZ2UgPT09
ICdDSEFSTUVOVScgJiYgbW9kZSA9PT0gJ1ZTTU9ERScpIHsKICAgICAgdGhpcy5lbnRlclBhZ2Uo
J0dBTUVTRVRUSU5HTUVOVScsICdDSEFSTUVOVScpOwogICAgICB0aGlzLmJyb2FkY2FzdExpc3Qo
LTEsIC0xKTsKICAgICAgdGhpcy5icm9hZGNhc3RNZW4oMSk7CiAgICAgIGlmICh0aGlzLmJhY2tn
cm91bmRSYW5kb20pIHRoaXMucGlja0JhY2tncm91bmQoKTsKICAgICAgaWYgKHRoaXMubXVzaWNS
YW5kb20pIHRoaXMucGlja011c2ljKCk7CiAgICAgIHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmco
LTEpOwogICAgICB0aGlzLmJyb2FkY2FzdFN0YXR1cygpOwogICAgfSBlbHNlIGlmIChhY3Rpb24g
PT09ICdjbGlja25leHQnICYmIHBhZ2UgPT09ICdDSEFSTUVOVScgJiYgKG1vZGUgPT09ICdTVE9S
WU1PREUnIHx8IG1vZGUgPT09ICdCQVRUTEVNT0RFJykpIHsKICAgICAgdGhpcy5maWdodCgnQ0hB
Uk1FTlUnKTsKICAgIH0gZWxzZSBpZiAoYWN0aW9uID09PSAnY2xpY2tmaWdodCcgJiYgcGFnZSA9
PT0gJ0dBTUVTRVRUSU5HTUVOVScpIHsKICAgICAgdGhpcy5maWdodCgnR0FNRVNFVFRJTkdNRU5V
Jyk7CiAgICB9IGVsc2UgaWYgKGFjdGlvbiA9PT0gJ3F1aXRnYW1lJyAmJiB0aGlzLmZpZ2h0aW5n
Tm93KSB7CiAgICAgIHRoaXMucXVpdFRvTWVudSgpOwogICAgfSBlbHNlIGlmIChhY3Rpb24gPT09
ICdyZXN0YXJ0Z2FtZScgJiYgdGhpcy5maWdodGluZ05vdykgewogICAgICBpZiAodGhpcy5vbmxp
bmUoKS5zb21lKChzbG90KSA9PiBzbG90LnBhZ2UgPT09ICdXQUlUUk9PTScpKSB7CiAgICAgICAg
dGhpcy5xdWl0VG9NZW51KCk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgdGhpcy5zdGFydEZpZ2h0
KCk7CiAgICAgICAgdGhpcy5yZXNldEZyYW1lcygpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0KCc8
cmVzdGFydGdhbWU+PC9yZXN0YXJ0Z2FtZT4nKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdExpc3Qo
LTEsIC0xKTsKICAgICAgICB0aGlzLmJyb2FkY2FzdE1lbigxKTsKICAgICAgICB0aGlzLnJlc2V0
RnJhbWVzKCk7CiAgICAgICAgdGhpcy5lYXNlTGF0ZW5jaWVzKCk7CiAgICAgICAgdGhpcy5icm9h
ZGNhc3RHYW1lU2V0dGluZygtMSk7CiAgICAgICAgdGhpcy5icm9hZGNhc3QoJzxyZXN0YXJ0Z2Ft
ZT48L3Jlc3RhcnRnYW1lPicpOwogICAgICB9CiAgICB9IGVsc2UgaWYgKGFjdGlvbiA9PT0gJ25l
eHRzdGFnZScgJiYgdGhpcy5maWdodGluZ05vdykgewogICAgICBpZiAodGhpcy5vbmxpbmUoKS5z
b21lKChzbG90KSA9PiBzbG90LnBhZ2UgPT09ICdXQUlUUk9PTScpKSB7CiAgICAgICAgdGhpcy5w
YWdlID0gJ1NUT1JZTUVOVSc7CiAgICAgICAgdGhpcy5maWdodGluZ05vdyA9IGZhbHNlOwogICAg
ICAgIHRoaXMucHJldmlvdXNQYWdlID0gJ0ZJR0hUSU5HJzsKICAgICAgICB0aGlzLnF1aXRCcm9h
ZGNhc3RzKCk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgdGhpcy5zdGFydEZpZ2h0KCk7CiAgICAg
ICAgaWYgKHRoaXMuc3RvcnkgPCA2KSB0aGlzLnN0b3J5ICs9IDE7CiAgICAgICAgdGhpcy5icm9h
ZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgICAgdGhpcy5icm9hZGNhc3RNZW4oMSk7CiAgICAgICAg
dGhpcy5yZXNldEZyYW1lcygpOwogICAgICAgIHRoaXMuZWFzZUxhdGVuY2llcygpOwogICAgICAg
IHRoaXMuYnJvYWRjYXN0R2FtZVNldHRpbmcoLTEpOwogICAgICAgIHRoaXMuYnJvYWRjYXN0KCc8
bmV4dHN0YWdlPjwvbmV4dHN0YWdlPicpOwogICAgICB9CiAgICB9CiAgfQoKICBhZnRlclBhZ2VD
aGFuZ2UoKSB7CiAgICB0aGlzLmJyb2FkY2FzdExpc3QoLTEsIC0xKTsKICAgIHRoaXMuYnJvYWRj
YXN0TWVuKDEpOwogICAgdGhpcy5icm9hZGNhc3RHYW1lU2V0dGluZygtMSk7CiAgICB0aGlzLmJy
b2FkY2FzdFN0YXR1cygpOwogIH0KCiAgZmlnaHQocHJldmlvdXMpIHsKICAgIHRoaXMuc3RhcnRG
aWdodCgpOwogICAgdGhpcy5wYWdlID0gJ0ZJR0hUSU5HJzsKICAgIHRoaXMuZmlnaHRpbmdOb3cg
PSB0cnVlOwogICAgdGhpcy5wcmV2aW91c1BhZ2UgPSBwcmV2aW91czsKICAgIHRoaXMuYnJvYWRj
YXN0TGlzdCgtMSwgLTEpOwogICAgdGhpcy5icm9hZGNhc3RNZW4oMSk7CiAgICB0aGlzLnJlc2V0
RnJhbWVzKCk7CiAgICB0aGlzLmVhc2VMYXRlbmNpZXMoKTsKICAgIHRoaXMuYnJvYWRjYXN0R2Ft
ZVNldHRpbmcoLTEpOwogICAgdGhpcy5icm9hZGNhc3RTdGF0dXMoKTsKICB9CgogIHF1aXRUb01l
bnUoKSB7CiAgICBpZiAodGhpcy5tb2RlID09PSAnVlNNT0RFJykgdGhpcy5lbnRlclBhZ2UoJ0NI
QVJNRU5VJywgJ0ZJR0hUSU5HJyk7CiAgICBlbHNlIGlmICh0aGlzLm1vZGUgPT09ICdTVE9SWU1P
REUnKSB0aGlzLmVudGVyUGFnZSgnU1RPUllNRU5VJywgJ0ZJR0hUSU5HJyk7CiAgICBlbHNlIGlm
ICh0aGlzLm1vZGUgPT09ICdCQVRUTEVNT0RFJykgdGhpcy5lbnRlclBhZ2UoJ0JBVFRMRVNFVFRJ
TkdNRU5VJywgJ0ZJR0hUSU5HJyk7CiAgICB0aGlzLnF1aXRCcm9hZGNhc3RzKCk7CiAgfQoKICBx
dWl0QnJvYWRjYXN0cygpIHsKICAgIHRoaXMucmVzZXRGcmFtZXMoKTsKICAgIHRoaXMuYnJvYWRj
YXN0U3RhdHVzKCk7CiAgICB0aGlzLmJyb2FkY2FzdExpc3QoLTEsIC0xKTsKICAgIHRoaXMuYnJv
YWRjYXN0TWVuKDEpOwogICAgdGhpcy5yZXNldEZyYW1lcygpOwogICAgdGhpcy5icm9hZGNhc3RH
YW1lU2V0dGluZygtMSk7CiAgICB0aGlzLmJyb2FkY2FzdFN0YXR1cygpOwogIH0KCiAgLy8gVGhl
IGZyYW1lIHNlbmRlcnMgKGF2LCBvbmUgcGVyIGNvbXB1dGVyKTogZXZlcnkgMTAgbXM7IGEgc2Vu
ZCBpcyBkdWUgYWZ0ZXIgYW5vdGhlciBnYW1lJ3MgcGFja2V0CiAgLy8gYW5kLCBiZXNpZGVzLCBl
dmVyeSAxMDAgdG8gMjAwIG1zLgogIGZsdXNoVGljaygpIHsKICAgIGlmICh0aGlzLnN0YXJ0aW5n
KSByZXR1cm47CiAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgQ0xJRU5UUzsgaW5kZXgg
Kz0gMSkgewogICAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90c1tpbmRleF07CiAgICAgIHNsb3Qu
dGlja0NvdW50ID0gKHNsb3QudGlja0NvdW50IHx8IDApICsgMTsKICAgICAgaWYgKHNsb3QudGlj
a0NvdW50ID09PSAyMCkgewogICAgICAgIHNsb3QudGlja0NvdW50ID0gdGhpcy5uZXh0SW50KDEw
KTsKICAgICAgICBzbG90LmZsdXNoZXMgKz0gMTsKICAgICAgfQogICAgICBpZiAoc2xvdC5mbHVz
aGVzIDw9IDApIGNvbnRpbnVlOwogICAgICBpZiAoc2xvdC5maWdodGluZyAmJiBzbG90LmNvbm5l
Y3Rpb24pIHNsb3QuY29ubmVjdGlvbi5zZW5kRnJhbWVzKCk7CiAgICAgIHNsb3QuZmx1c2hlcyAt
PSAxOwogICAgfQogIH0KCiAgLy8gVGhlIHdhdGNoZG9nIChhQSk6IHBpbmdzIHF1aWV0IGdhbWVz
LCBhbmQgdGFrZXMgb3V0IGdhbWVzIHNpbGVudCBmb3IgMzUgcyAob3IgaWRsZSB0b28gbG9uZyku
CiAgd2F0Y2hkb2coKSB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgZm9yIChsZXQg
aW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgY29uc3Qgc2xv
dCA9IHRoaXMuc2xvdHNbaW5kZXhdOwogICAgICBpZiAoIXNsb3Qub25saW5lKSBjb250aW51ZTsK
ICAgICAgY29uc3QgYWZrID0gdGhpcy5hZmtNaW51dGVzICogNjAwMDA7CiAgICAgIGlmIChzbG90
Lmxhc3RNZXNzYWdlIDwgbm93IC0gMzUwMDAgfHwgKGFmayA+IDYwMDAwICYmIHNsb3QubGFzdEFj
dGl2ZSA8IG5vdyAtIGFmaykpIHsKICAgICAgICB0aGlzLmxvZyhgaGYgcm9vbSAke3RoaXMubnVt
YmVyfTogJHtzbG90Lm5hbWV9ICR7c2xvdC5sYXN0TWVzc2FnZSA8IG5vdyAtIDM1MDAwID8gJ3Rp
bWVkIG91dCcgOiAnd2FzIGlkbGUnfWApOwogICAgICAgIGNvbnN0IGNvbm5lY3Rpb24gPSBzbG90
LmNvbm5lY3Rpb247CiAgICAgICAgY29ubmVjdGlvbi5sZWF2ZSgpOwogICAgICAgIGNvbm5lY3Rp
b24ua2lja2VkID0gdHJ1ZTsKICAgICAgICBjb25uZWN0aW9uLmNsb3NlKCk7CiAgICAgICAgY29u
dGludWU7CiAgICAgIH0KICAgICAgaWYgKHNsb3QubGFzdE1lc3NhZ2UgPCBub3cgLSAyMDAwMCkg
c2xvdC5jb25uZWN0aW9uLnNlbmQoJzxwaW5nPjwvcGluZz4nKTsKICAgIH0KICB9CgogIC8vIFRo
ZSBsaW5lIHRoZSByb29tIGxpc3Qgc2hvd3MgZm9yIHRoaXMgcm9vbS4KICBwZW9wbGUoKSB7CiAg
ICByZXR1cm4gdGhpcy5vbmxpbmUoKS5tYXAoKHNsb3QpID0+IGAke3Nsb3QubmFtZX0oJHtzbG90
LmxhdGVuY3lTaG93biAtIDF9KWApLmpvaW4oJywgJyk7CiAgfQp9CgovLyAtLS0tIE9uZSBjb21w
dXRlciBpbiBhIHJvb20gKHRoZSBvcmlnaW5hbCdzIHRocmVhZCAiaSIpIC0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCmNsYXNzIEhmQ29ubmVjdGlvbiB7CiAgLy8g
c29ja2V0OiB7IHdyaXRlKHRleHQpLCBjbG9zZSgpIH07IGZlZWQgaXQgdGhlIHJlY2VpdmVkIGJ5
dGVzIHdpdGggcmVjZWl2ZSgpLCBhbmQgY2xvc2VkKCkgYXQgdGhlIGVuZC4KICBjb25zdHJ1Y3Rv
cihyb29tLCBzb2NrZXQsIHsgYWRkcmVzcyA9ICcnIH0gPSB7fSkgewogICAgdGhpcy5yb29tID0g
cm9vbTsKICAgIHRoaXMuc29ja2V0ID0gc29ja2V0OwogICAgdGhpcy5hZGRyZXNzID0gYWRkcmVz
czsKICAgIHRoaXMuaW5kZXggPSAtMTsgLy8gbgogICAgdGhpcy5uYW1lID0gJyc7IC8vIG8KICAg
IHRoaXMuY2MgPSAnJzsgLy8gcAogICAgdGhpcy5wbGF5ZXJzID0gWycnLCAnJywgJyddOyAvLyBy
CiAgICB0aGlzLmxhc3RGcmFtZSA9IC0xOyAvLyBzOiB0aGUgbGFzdCBmcmFtZSBvZiB0aGlzIGdh
bWUncywgaW4gb3JkZXIKICAgIHRoaXMubmV4dEZyYW1lID0gMDsgLy8gdDogdGhlIG5leHQgZnJh
bWUgdG8gc2VuZCB0aGlzIGdhbWUKICAgIHRoaXMucXVldWVkID0gJyc7IC8vIHY6IDxycGM+IGxp
bmVzIGZyb20gdGhlIG90aGVycywgc2VudCB3aXRoIHRoZSBuZXh0IGZyYW1lcwogICAgdGhpcy5j
aGVhdCA9IDA7IC8vIHgKICAgIHRoaXMua2lja2VkID0gZmFsc2U7IC8vIGIKICAgIHRoaXMuZW5k
ZWQgPSBmYWxzZTsKICAgIHRoaXMubGluZXMgPSBbXTsKICAgIHRoaXMud2FpdGluZyA9IG51bGw7
CiAgICB0aGlzLmJ1ZmZlciA9IEJ1ZmZlci5hbGxvYygwKTsKICAgIHJvb20uY29ubmVjdGlvbnMu
YWRkKHRoaXMpOwogICAgdGhpcy5kb25lID0gdGhpcy5ydW4oKTsKICB9CgogIC8vIC0tLS0gYnl0
ZXMgaW4gYW5kIG91dAogIHJlY2VpdmUoY2h1bmspIHsKICAgIGlmICh0aGlzLmVuZGVkKSByZXR1
cm47CiAgICB0aGlzLmJ1ZmZlciA9IHRoaXMuYnVmZmVyLmxlbmd0aCA/IEJ1ZmZlci5jb25jYXQo
W3RoaXMuYnVmZmVyLCBjaHVua10pIDogQnVmZmVyLmZyb20oY2h1bmspOwogICAgbGV0IHN0YXJ0
ID0gMDsKICAgIGZvciAobGV0IGF0ID0gdGhpcy5idWZmZXIuaW5kZXhPZigxMCk7IGF0ID49IDA7
IGF0ID0gdGhpcy5idWZmZXIuaW5kZXhPZigxMCwgc3RhcnQpKSB7CiAgICAgIGxldCBsaW5lID0g
dGhpcy5idWZmZXIudG9TdHJpbmcoJ3V0ZjgnLCBzdGFydCwgYXQpOwogICAgICBpZiAobGluZS5l
bmRzV2l0aCgnXHInKSkgbGluZSA9IGxpbmUuc2xpY2UoMCwgLTEpOwogICAgICBzdGFydCA9IGF0
ICsgMTsKICAgICAgdGhpcy5wdXNoTGluZShsaW5lKTsKICAgIH0KICAgIHRoaXMuYnVmZmVyID0g
dGhpcy5idWZmZXIuc3ViYXJyYXkoc3RhcnQpOwogICAgaWYgKHRoaXMuYnVmZmVyLmxlbmd0aCA+
IDI2MjE0NCkgdGhpcy5jbG9zZSgpOyAvLyBubyBsaW5lIGlzIHRoYXQgbG9uZwogIH0KCiAgY2xv
c2VkKCkgewogICAgaWYgKHRoaXMuZW5kZWQpIHJldHVybjsKICAgIHRoaXMuZW5kZWQgPSB0cnVl
OwogICAgdGhpcy5wdXNoTGluZShudWxsKTsKICB9CgogIHB1c2hMaW5lKGxpbmUpIHsKICAgIGlm
ICh0aGlzLndhaXRpbmcpIHsKICAgICAgY29uc3QgcmVzb2x2ZSA9IHRoaXMud2FpdGluZzsKICAg
ICAgdGhpcy53YWl0aW5nID0gbnVsbDsKICAgICAgcmVzb2x2ZShsaW5lKTsKICAgIH0gZWxzZSB7
CiAgICAgIHRoaXMubGluZXMucHVzaChsaW5lKTsKICAgIH0KICB9CgogIHJlYWRMaW5lKCkgeyAv
LyBCdWZmZXJlZFJlYWRlci5yZWFkTGluZTogbnVsbCBhdCB0aGUgZW5kCiAgICBpZiAodGhpcy5s
aW5lcy5sZW5ndGgpIHJldHVybiBQcm9taXNlLnJlc29sdmUodGhpcy5saW5lcy5zaGlmdCgpKTsK
ICAgIGlmICh0aGlzLmVuZGVkKSByZXR1cm4gUHJvbWlzZS5yZXNvbHZlKG51bGwpOwogICAgcmV0
dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiB7IHRoaXMud2FpdGluZyA9IHJlc29sdmU7IH0p
OwogIH0KCiAgc2VuZCh0ZXh0KSB7IC8vIGkuYShTdHJpbmcpCiAgICBpZiAodGhpcy5lbmRlZCkg
cmV0dXJuOwogICAgdHJ5IHsgdGhpcy5zb2NrZXQud3JpdGUodGV4dCArICdcbicpOyB9IGNhdGNo
IHsgLyogdGhlIGNsb3NpbmcgZm9sbG93cyAqLyB9CiAgfQoKICBjbG9zZSgpIHsKICAgIGlmICgh
dGhpcy5zb2NrZXRDbG9zZWQpIHsKICAgICAgdGhpcy5zb2NrZXRDbG9zZWQgPSB0cnVlOwogICAg
ICB0cnkgeyB0aGlzLnNvY2tldC5jbG9zZSgpOyB9IGNhdGNoIHsgLyogYWxyZWFkeSBjbG9zZWQg
Ki8gfQogICAgfQogICAgdGhpcy5jbG9zZWQoKTsKICB9CgogIGdldCBzbG90KCkgeyByZXR1cm4g
dGhpcy5yb29tLnNsb3RzW3RoaXMuaW5kZXhdOyB9CgogIC8vIC0tLS0gdGhlIGNvbnZlcnNhdGlv
bgogIGFzeW5jIHJ1bigpIHsKICAgIHRyeSB7CiAgICAgIGF3YWl0IHRoaXMuY29udmVyc2F0aW9u
KCk7CiAgICB9IGNhdGNoIChlcnJvcikgewogICAgICBpZiAoIShlcnJvciBpbnN0YW5jZW9mIFht
bEVycm9yKSkgdGhpcy5yb29tLmxvZyhgaGYgcm9vbSAke3RoaXMucm9vbS5udW1iZXJ9OiAke2Vy
cm9yLnN0YWNrIHx8IGVycm9yfWApOwogICAgfSBmaW5hbGx5IHsKICAgICAgdGhpcy5sZWF2ZSgp
OyAvLyBpLmgKICAgICAgdGhpcy5yb29tLmNvbm5lY3Rpb25zLmRlbGV0ZSh0aGlzKTsKICAgICAg
dGhpcy5jbG9zZSgpOwogICAgfQogIH0KCiAgYXN5bmMgY29udmVyc2F0aW9uKCkgewogICAgY29u
c3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGF3YWl0IHNsZWVwKDI1MCk7CiAgICB0aGlzLnNlbmQo
Jzxpbmk+PC9pbmk+Jyk7CiAgICBhd2FpdCBzbGVlcCgyNTApOwogICAgaWYgKHJvb20uY2xvc2Vk
KSByZXR1cm47CiAgICBsZXQgbGluZSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKTsKICAgIGlmIChs
aW5lID09PSBudWxsKSByZXR1cm47CiAgICBjb25zdCBqb2luID0gcGFyc2VYbWwobGluZSk7CiAg
ICBjb25zdCB2ZXJzaW9ucyA9IGJ5VGFnKGpvaW4sICd2ZXInKTsKICAgIGlmICghdmVyc2lvbnMu
bGVuZ3RoKSByZXR1cm47CiAgICBpZiAoaW50KHZhbHVlT2YodmVyc2lvbnNbMF0pKSAhPT0gVkVS
U0lPTikgcmV0dXJuIHRoaXMucmVmdXNlKCd2Jyk7CiAgICBpZiAocm9vbS5jb25uZWN0ZWQgPj0g
cm9vbS5saW1pdCkgcmV0dXJuIHRoaXMucmVmdXNlKCdmJyk7CiAgICBpZiAoIXJvb20uYWxsb3dK
b2luV2hlbkZpZ2h0aW5nICYmIHJvb20uZmlnaHRpbmdOb3cpIHJldHVybiB0aGlzLnJlZnVzZSgn
cCcpOwogICAgaWYgKHJvb20ucGFzc3dvcmQpIHsKICAgICAgdGhpcy5zZW5kKCc8cmVxX3B3Pjwv
cmVxX3B3PicpOwogICAgICBsaW5lID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpOwogICAgICBpZiAo
bGluZSA9PT0gbnVsbCkgcmV0dXJuOwogICAgICBpZiAocm9vbS5wYXNzd29yZCAhPT0gdGFnVmFs
dWUocGFyc2VYbWwobGluZSksICdwd2QnKSkgcmV0dXJuIHRoaXMucmVmdXNlKCdwd2QnKTsKICAg
IH0KICAgIGNvbnN0IGxhdGVuY3kgPSBhd2FpdCB0aGlzLm1lYXN1cmUoKTsKICAgIGlmIChsYXRl
bmN5ID09PSBudWxsKSByZXR1cm47CiAgICBpZiAocm9vbS5sYXRlbmN5TGltaXQgIT09IC0xICYm
IGxhdGVuY3kgPiByb29tLmxhdGVuY3lMaW1pdCkgcmV0dXJuIHRoaXMucmVmdXNlKCdsJyk7CiAg
ICB0aGlzLnNlbmQoYDxtYXhjbGllbnRzPjxtYXhjbGllbnRzPiR7cm9vbS5saW1pdH08L21heGNs
aWVudHM+PC9tYXhjbGllbnRzPmApOwogICAgdGhpcy5zZW5kKGA8cnA+PHJwPiR7cm9vbS5zZWVk
fTwvcnA+PC9ycD5gKTsKICAgIGZvciAobGV0IHBhcnQgPSAwOyBwYXJ0IDwgMTA7IHBhcnQgKz0g
MSkgewogICAgICBsZXQgdGV4dCA9IGA8cmFuZD48aT4ke3BhcnQgKiA1MDB9PC9pPmA7CiAgICAg
IGZvciAobGV0IGsgPSAwOyBrIDwgNTAwOyBrICs9IDEpIHRleHQgKz0gYDxuPiR7cm9vbS50YWJs
ZVtrICsgcGFydCAqIDUwMF19PC9uPmA7CiAgICAgIHRoaXMuc2VuZCh0ZXh0ICsgJzwvcmFuZD4n
KTsKICAgIH0KICAgIHRoaXMuc2VuZCgnPHJlcV9pbmZvPjwvcmVxX2luZm8+Jyk7CiAgICBsaW5l
ID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpOwogICAgaWYgKGxpbmUgPT09IG51bGwgfHwgcm9vbS5j
bG9zZWQpIHJldHVybjsKICAgIHJvb20ucmVjb3VudCgpOwogICAgaWYgKHJvb20uY29ubmVjdGVk
ID49IHJvb20ubGltaXQpIHJldHVybiB0aGlzLnJlZnVzZSgnZicpOwogICAgZm9yIChsZXQgaW5k
ZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgaWYgKCFyb29tLnNs
b3RzW2luZGV4XS5vbmxpbmUpIHsgdGhpcy5pbmRleCA9IGluZGV4OyBicmVhazsgfQogICAgfQog
ICAgaWYgKHRoaXMuaW5kZXggPCAwKSByZXR1cm4gdGhpcy5yZWZ1c2UoJ2YnKTsKICAgIGNvbnN0
IGluZm8gPSBwYXJzZVhtbChsaW5lKTsKICAgIHRoaXMubmFtZSA9IHRhZ1ZhbHVlKGluZm8sICdu
YW1lJyk7CiAgICBjb25zdCBjY3MgPSBieVRhZyhpbmZvLCAnY2MnKTsKICAgIHRoaXMuY2MgPSBj
Y3MubGVuZ3RoID8gdmFsdWVPZihjY3NbMF0pIDogJyc7CiAgICBjb25zdCBzbG90ID0gdGhpcy5z
bG90OwogICAgZm9yIChsZXQgayA9IDA7IGsgPCAzOyBrICs9IDEpIHRoaXMucGxheWVyc1trXSA9
IHRhZ1ZhbHVlKGluZm8sICdwJywgayk7CiAgICBmb3IgKGxldCBrID0gMDsgayA8IDMwOyBrICs9
IDEpIHsKICAgICAgc2xvdC5sZXZlbHNba10gPSBpbnQodGFnVmFsdWUoaW5mbywgJ2wnLCBrKSk7
CiAgICAgIGlmIChzbG90LmxldmVsc1trXSA+IE1BWF9MRVZFTCkgdGhpcy5jaGVhdCA9IDE7CiAg
ICB9CiAgICBzbG90LmxldmVsc1syMF0gPSBzbG90LmxldmVsc1s4XTsKICAgIHNsb3QubmFtZSA9
IHRoaXMubmFtZTsKICAgIHNsb3QuY2MgPSB0aGlzLmNjOwogICAgc2xvdC5jb3VudHJ5ID0gdGhp
cy5jYyB8fCAndW5rbm93bic7CiAgICBzbG90LnBsYXllcnMgPSBbLi4udGhpcy5wbGF5ZXJzXTsK
ICAgIHNsb3QubGFzdE1lc3NhZ2UgPSBzbG90Lmxhc3RBY3RpdmUgPSBEYXRlLm5vdygpOwogICAg
c2xvdC5jb25uZWN0aW9uID0gdGhpczsKICAgIHNsb3Qub25saW5lID0gdHJ1ZTsKICAgIHNsb3Qu
cGF1c2VkID0gZmFsc2U7CiAgICBzbG90Lmhhc1BsYXllciA9IGZhbHNlOwogICAgc2xvdC5sYXRl
bmN5ID0gc2xvdC5sYXRlbmN5VGFyZ2V0ID0gc2xvdC5sYXRlbmN5U2hvd24gPSBsYXRlbmN5Owog
ICAgc2xvdC5wYWdlID0gJ1dBSVRST09NJzsKICAgIHNsb3QuYWRtaW4gPSBmYWxzZTsKICAgIHJv
b20ucmVjb3VudCgpOwogICAgdGhpcy5zZW5kU2V0dGluZygtMSk7CiAgICB0aGlzLnNlbmRHYW1l
U2V0dGluZygtMSk7CiAgICB0aGlzLnNlbmRMaXN0KC0xLCAtMSk7CiAgICB0aGlzLnNlbmRNZW4o
MSk7CiAgICBpZiAoIXJvb20uZmlnaHRpbmdOb3cpIHsKICAgICAgaWYgKHJvb20ucGFnZSAhPT0g
J1dBSVRST09NJykgewogICAgICAgIGlmIChyb29tLm1vZGUgPT09ICdWU01PREUnKSByb29tLnBh
Z2UgPSAnQ0hBUk1FTlUnOwogICAgICB9IGVsc2UgewogICAgICAgIHJvb20ucGFnZSA9ICdXQUlU
Uk9PTSc7CiAgICAgICAgcm9vbS5tb2RlID0gJ1dBSVRST09NJzsKICAgICAgfQogICAgfQogICAg
cm9vbS5icm9hZGNhc3RTdGF0dXMoKTsKICAgIHJvb20ubG9nKGBoZiByb29tICR7cm9vbS5udW1i
ZXJ9OiAke3RoaXMubmFtZX0gKGxhdGVuY3kgJHtsYXRlbmN5IC0gMX0pIGpvaW5zYCk7CiAgICBy
b29tLmJyb2FkY2FzdExpc3QodGhpcy5pbmRleCwgLTEpOwogICAgaWYgKHJvb20uY29ubmVjdGVk
ID09PSAyICYmIHJvb20uZmlnaHRpbmdOb3cpIHsKICAgICAgcm9vbS5jb3VudGRvd24ub24gPSB0
cnVlOwogICAgICByb29tLmNvdW50ZG93bi5hY3Rpb24gPSAncXVpdGdhbWUnOwogICAgICByb29t
LmNvdW50ZG93bi5jb3VudCA9IDE7CiAgICB9CiAgICB0aGlzLm5vdGljZSgnUm9vbSBTZXJ2ZXIg
djAuNysuPGJyIC8+VHlwZSAvaGVscCBmb3IgY29tbWFuZHMuJyk7CiAgICBpZiAocm9vbS5maWdo
dGluZ05vdyAmJiByb29tLmNvbm5lY3RlZCA+IDIpIHsKICAgICAgaWYgKHJvb20ubW9kZSA9PT0g
J1ZTTU9ERScpIHRoaXMubm90aWNlKCdQbGF5ZXJzIGFyZSBpbiBWUyBNb2RlLicpOwogICAgICBl
bHNlIGlmIChyb29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJykgdGhpcy5ub3RpY2UoJ1BsYXllcnMg
YXJlIGluIEJhdHRsZSBNb2RlLicpOwogICAgICBlbHNlIGlmIChyb29tLm1vZGUgPT09ICdTVE9S
WU1PREUnKSB0aGlzLm5vdGljZShgUGxheWVycyBhcmUgaW4gU3RvcnkgJHtyb29tLnN0b3J5ICsg
MX1gKTsKICAgIH0KICAgIGlmICh0aGlzLmNoZWF0ID09PSAxKSByZXR1cm47IC8vIGxldmVscyBh
Ym92ZSB0aGUgZ2FtZSdzIGhpZ2hlc3Q6IG91dCAodGhlIGZpbmFsbHkgbGVhdmVzKQogICAgZm9y
IChsaW5lID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpOyBsaW5lICE9PSBudWxsOyBsaW5lID0gYXdh
aXQgdGhpcy5yZWFkTGluZSgpKSB7CiAgICAgIGlmICh0aGlzLmluZGV4IDwgMCkgcmV0dXJuOwog
ICAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgICBzbG90Lmxhc3RNZXNzYWdlID0gbm93
OwogICAgICBpZiAobGluZSAhPT0gJzxwaW5nb2s+PC9waW5nb2s+Jykgc2xvdC5sYXN0QWN0aXZl
ID0gbm93OwogICAgICBpZiAodGhpcy5raWNrZWQgfHwgdGhpcy5jaGVhdCA9PT0gMSkgcmV0dXJu
OwogICAgICBhd2FpdCB0aGlzLmhhbmRsZShsaW5lKTsKICAgICAgaWYgKHRoaXMua2lja2VkKSBy
ZXR1cm47CiAgICB9CiAgfQoKICByZWZ1c2UocmVhc29uKSB7CiAgICB0aGlzLnNlbmQoYDxlcnJv
cj48cmVhc29uPiR7cmVhc29ufTwvcmVhc29uPjwvZXJyb3I+YCk7CiAgICByZXR1cm4gdGhpcy5y
ZWFkTGluZSgpOwogIH0KCiAgLy8gVGVuIHBpbmdzOiB0aGUgbGF0ZW5jeSBpcyB0aGUgc2hvcnRl
c3Qgcm91bmQgdHJpcCwgaW4gZnJhbWVzIChhIG11bHRpcGxlIG9mIFNURVApLCB3aXRoIGEgbWFy
Z2luLgogIGFzeW5jIG1lYXN1cmUoKSB7CiAgICBsZXQgYmVzdCA9IDUwMDA7CiAgICBmb3IgKGxl
dCBrID0gMDsgayA8IDEwOyBrICs9IDEpIHsKICAgICAgY29uc3Qgc2VudCA9IERhdGUubm93KCk7
CiAgICAgIHRoaXMuc2VuZCgnPHBpbmc+PC9waW5nPicpOwogICAgICBpZiAoYXdhaXQgdGhpcy5y
ZWFkTGluZSgpID09PSBudWxsKSByZXR1cm4gbnVsbDsKICAgICAgY29uc3QgdG9vayA9IERhdGUu
bm93KCkgLSBzZW50OwogICAgICBpZiAodG9vayA8IGJlc3QpIGJlc3QgPSB0b29rOwogICAgICBh
d2FpdCBzbGVlcCh0b29rIDwgNTAwID8gdG9vayA6IDUwMCk7CiAgICB9CiAgICBpZiAoYmVzdCA8
PSAwKSBiZXN0ID0gMTsKICAgIGJlc3QgKz0gMTU7CiAgICByZXR1cm4gU1RFUCArIE1hdGguY2Vp
bCgoYmVzdCAqIDEuNyArIDAuMTYpIC8gMzMgLyBTVEVQKSAqIFNURVA7CiAgfQoKICBhc3luYyBo
YW5kbGUobGluZSkgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGNvbnN0IHNsb3Qg
PSB0aGlzLnNsb3Q7CiAgICBjb25zdCBkb2MgPSBwYXJzZVhtbChsaW5lKTsKICAgIGNvbnN0IGtp
bmQgPSBkb2MubmFtZTsKICAgIGlmIChraW5kID09PSAnZicpIHsgLy8gYSBmcmFtZSBvZiB0aGlz
IGdhbWUncyBrZXlzCiAgICAgIGNvbnN0IGZyYW1lID0gaW50KHRhZ1ZhbHVlKGRvYywgJ2knKSk7
CiAgICAgIGlmIChmcmFtZSA9PT0gMSkgcm9vbS53aW5SZXBvcnRlZCA9IGZhbHNlOwogICAgICBp
ZiAodGhpcy5sYXN0RnJhbWUgKyAxID09PSBmcmFtZSkgewogICAgICAgIHNsb3QuZnJhbWVzW2Zy
YW1lICUgRlJBTUVTX0tFUFRdID0gbGluZTsKICAgICAgICB0aGlzLmxhc3RGcmFtZSA9IGZyYW1l
OwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAncGsnKSB7IC8v
IHRoZSBlbmQgb2YgYSBwYWNrZXQ6IHRoZSBvdGhlcnMgbWF5IGdldCB0aGlzIGdhbWUncyBmcmFt
ZXMKICAgICAgc2xvdC5sYXN0UGFja2V0ID0gdGhpcy5sYXN0RnJhbWU7CiAgICAgIHRoaXMucmVx
dWVzdEZsdXNoZXMoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09ICd0Jykg
eyBpbnQodGFnVmFsdWUoZG9jLCAnZCcpKTsgcmV0dXJuOyB9CiAgICBpZiAoa2luZCA9PT0gJ3Jw
YycpIHsKICAgICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9
IDEpIHsKICAgICAgICBjb25zdCBvdGhlciA9IHJvb20uc2xvdHNbaW5kZXhdOwogICAgICAgIGlm
IChvdGhlci5maWdodGluZyAmJiBvdGhlci5jb25uZWN0aW9uKSBvdGhlci5jb25uZWN0aW9uLnF1
ZXVlZCArPSBsaW5lOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09
PSAnY2hhdCcpIHsKICAgICAgY29uc3QgZnJvbSA9IGludCh0YWdWYWx1ZShkb2MsICdjJykpOwog
ICAgICBpZiAoZnJvbSA8IDAgfHwgZnJvbSA+PSBTTE9UUykgdGhyb3cgbmV3IFhtbEVycm9yKCdu
byBzdWNoIGNvbXB1dGVyJyk7CiAgICAgIGlmICh0aGlzLmNvbW1hbmQodGFnVmFsdWUoZG9jLCAn
bScpKSkgcm9vbS5icm9hZGNhc3QobGluZSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChr
aW5kID09PSAncGF1c2VnYW1lJyB8fCBraW5kID09PSAncmVzdW1lZ2FtZScpIHsKICAgICAgc2xv
dC5wYXVzZWQgPSBraW5kID09PSAncGF1c2VnYW1lJzsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0
KC0xLCAtMSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnc3RhcnRjb3Vu
dCcpIHJldHVybiB0aGlzLnN0YXJ0Q291bnQoZG9jKTsKICAgIGlmIChraW5kID09PSAnY2FuY2Vs
Y291bnQnKSB7CiAgICAgIGNvbnN0IGNvdW50ZG93biA9IHJvb20uY291bnRkb3duOwogICAgICBp
ZiAoY291bnRkb3duLm9uICYmIChjb3VudGRvd24uYWN0aW9uID09PSAnY2xpY2tmaWdodCcgfHwg
Y291bnRkb3duLmFjdGlvbiA9PT0gdGFnVmFsdWUoZG9jLCAnYWN0aW9uJykpKSB7CiAgICAgICAg
Y291bnRkb3duLm9uID0gZmFsc2U7CiAgICAgICAgY291bnRkb3duLmFjdGlvbiA9ICcnOwogICAg
ICAgIGNvdW50ZG93bi5jb3VudCA9IENPVU5URE9XTjsKICAgICAgICByb29tLmJyb2FkY2FzdENs
aWNrKHRoaXMuaW5kZXgsICdjbGlja2NhbmNlbCcpOwogICAgICAgIHJvb20uYnJvYWRjYXN0KCc8
Y2FuY2VsY291bnQ+PC9jYW5jZWxjb3VudD4nKTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9
CiAgICBpZiAoa2luZCA9PT0gJ3NldHRpbmcnKSB7CiAgICAgIGlmIChyb29tLnBhZ2UgPT09ICdX
QUlUUk9PTScpIHsKICAgICAgICBjb25zdCBhbGxvdyA9IGJ5VGFnKGRvYywgJ3dhaXR3aGVuZmln
aHQnKTsKICAgICAgICBpZiAoYWxsb3cubGVuZ3RoKSByb29tLmFsbG93Sm9pbldoZW5GaWdodGlu
ZyA9IHZhbHVlT2YoYWxsb3dbMF0pID09PSAnMSc7CiAgICAgICAgcm9vbS5icm9hZGNhc3RTZXR0
aW5nKHRoaXMuaW5kZXgpOwogICAgICB9CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5k
ID09PSAnZ2FtZXNldHRpbmcnKSByZXR1cm4gdGhpcy5nYW1lU2V0dGluZyhkb2MpOwogICAgaWYg
KGtpbmQgPT09ICdjbGlja2JhY2snKSByZXR1cm4gdGhpcy5jbGlja0JhY2soZG9jKTsKICAgIGlm
IChraW5kID09PSAncGFnZScpIHsKICAgICAgc2xvdC5wYWdlID0gdmFsdWVPZihkb2MpOwogICAg
ICBzbG90LmZpZ2h0aW5nID0gc2xvdC5wYWdlID09PSAnRklHSFRJTkcnOwogICAgICByb29tLmJy
b2FkY2FzdExpc3QoLTEsIC0xKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGtpbmQgPT09
ICdpbmZvJykgcmV0dXJuIHRoaXMudXBkYXRlSW5mbyhkb2MpOwogICAgaWYgKGtpbmQgPT09ICdh
ZGRwbGF5ZXInKSByZXR1cm4gdGhpcy5hZGRQbGF5ZXIoZG9jKTsKICAgIGlmIChraW5kID09PSAn
ZGVsbWFuJykgewogICAgICBpZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47CiAg
ICAgIGNvbnN0IGluZGV4ID0gaW50KHZhbHVlT2YoZG9jKSk7CiAgICAgIGNvbnN0IG1hbiA9IHJv
b20ubWVuW2luZGV4XTsKICAgICAgaWYgKCFtYW4pIHRocm93IG5ldyBYbWxFcnJvcignbm8gc3Vj
aCBtYW4nKTsKICAgICAgaWYgKG1hbi5leGlzdHMgJiYgKChtYW4uY29udHJvbGxlciA9PT0gLTEg
JiYgIXJvb20uY291bnRkb3duLm9uKSB8fCBtYW4uY2xpZW50ID09PSB0aGlzLmluZGV4KSkgewog
ICAgICAgIG1hbi5leGlzdHMgPSBmYWxzZTsKICAgICAgICBmb3IgKGNvbnN0IG90aGVyIG9mIHJv
b20ubWVuKSBpZiAob3RoZXIuZXhpc3RzICYmIG90aGVyLmNvbW1hbmRlciA9PT0gaW5kZXgpIG90
aGVyLmV4aXN0cyA9IGZhbHNlOwogICAgICAgIHJvb20uYnJvYWRjYXN0TWVuKDEpOwogICAgICB9
CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChraW5kID09PSAnYWRkY29tJykgewogICAgICBp
ZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47CiAgICAgIGlmICghcm9vbS5jb3Vu
dGRvd24ub24gJiYgdGhpcy5hZGRDb21wdXRlcigpKSB7CiAgICAgICAgdGhpcy5saW1pdE1lbigp
OwogICAgICAgIHJvb20uYnJvYWRjYXN0TWVuKDEpOwogICAgICB9CiAgICAgIHJldHVybjsKICAg
IH0KICAgIGlmIChraW5kID09PSAnYWRkc29sZGllcicpIHJldHVybiB0aGlzLmFkZFNvbGRpZXIo
ZG9jKTsKICAgIGlmIChraW5kID09PSAncmVkb3JhbmRvbScpIHsKICAgICAgaWYgKHJvb20ucGFn
ZSAhPT0gJ0NIQVJNRU5VJykgcmV0dXJuOwogICAgICBpZiAoIXJvb20uY291bnRkb3duLm9uKSB7
CiAgICAgICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IE1FTjsgaW5kZXggKz0gMSkgaWYg
KHJvb20ubWVuW2luZGV4XS5leGlzdHMgJiYgcm9vbS5tZW5baW5kZXhdLnJhbmRvbSkgdGhpcy5w
aWNrQ2hhcmFjdGVyKGluZGV4KTsKICAgICAgICByb29tLmJyb2FkY2FzdE1lbigwKTsKICAgICAg
fQogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ21hbnRlYW0nKSB7CiAgICAg
IGlmIChyb29tLnBhZ2UgIT09ICdDSEFSTUVOVScpIHJldHVybjsKICAgICAgY29uc3QgaW5kZXgg
PSBpbnQodGFnVmFsdWUoZG9jLCAnaScpKTsKICAgICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5k
ZXhdOwogICAgICBpZiAoIW1hbikgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBzdWNoIG1hbicpOwog
ICAgICBpZiAobWFuLmV4aXN0cyAmJiAobWFuLmNvbnRyb2xsZXIgPT09IC0xIHx8IG1hbi5jbGll
bnQgPT09IHRoaXMuaW5kZXgpKSB7CiAgICAgICAgY29uc3QgdGVhbSA9IGludCh0YWdWYWx1ZShk
b2MsICd0ZWFtJykpOwogICAgICAgIG1hbi50ZWFtID0gdGVhbTsKICAgICAgICBmb3IgKGNvbnN0
IG90aGVyIG9mIHJvb20ubWVuKSBpZiAob3RoZXIuZXhpc3RzICYmIG90aGVyLmNvbW1hbmRlciA9
PT0gaW5kZXgpIG90aGVyLnRlYW0gPSB0ZWFtOwogICAgICAgIGlmIChyb29tLm1vZGUgPT09ICdC
QVRUTEVNT0RFJyAmJiBtYW4uY29udHJvbGxlciA+PSAwKSB7CiAgICAgICAgICByb29tLm1lbi5m
b3JFYWNoKChvdGhlciwgaykgPT4geyBpZiAoayAhPT0gaW5kZXggJiYgb3RoZXIuZXhpc3RzICYm
IG90aGVyLmNsaWVudCA9PT0gbWFuLmNsaWVudCkgb3RoZXIudGVhbSA9IHRlYW07IH0pOwogICAg
ICAgIH0KICAgICAgICByb29tLmJyb2FkY2FzdE1lbigwKTsKICAgICAgfQogICAgICByZXR1cm47
CiAgICB9CiAgICBpZiAoa2luZCA9PT0gJ21hbmNoYXInKSByZXR1cm4gdGhpcy5jaG9vc2VDaGFy
YWN0ZXIoZG9jKTsKICAgIGlmIChraW5kID09PSAnaW5jcmVhc2VsYXRlbmN5JykgewogICAgICBz
bG90LmxhdGVuY3kgKz0gMjsKICAgICAgc2xvdC5sYXRlbmN5VGFyZ2V0ICs9IDI7CiAgICAgIHJv
b20uYnJvYWRjYXN0TGlzdCgtMSwgLTEpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoa2lu
ZCA9PT0gJ3JlbWVhc3VyZScpIHsKICAgICAgbGV0IGJlc3QgPSA1MDAwOwogICAgICBmb3IgKGxl
dCBrID0gMDsgayA8IDEwOyBrICs9IDEpIHsKICAgICAgICBjb25zdCBzZW50ID0gRGF0ZS5ub3co
KTsKICAgICAgICB0aGlzLnNlbmQoJzxwaW5nPjwvcGluZz4nKTsKICAgICAgICBmb3IgKGxldCBy
ZXBseSA9IGF3YWl0IHRoaXMucmVhZExpbmUoKTsgcmVwbHkgIT09ICc8cGluZ29rPjwvcGluZ29r
Pic7IHJlcGx5ID0gYXdhaXQgdGhpcy5yZWFkTGluZSgpKSB7CiAgICAgICAgICBpZiAocmVwbHkg
PT09IG51bGwpIHRocm93IG5ldyBYbWxFcnJvcignY2xvc2VkJyk7CiAgICAgICAgfQogICAgICAg
IGNvbnN0IHRvb2sgPSBEYXRlLm5vdygpIC0gc2VudDsKICAgICAgICBpZiAodG9vayA8IGJlc3Qp
IGJlc3QgPSB0b29rOwogICAgICAgIGF3YWl0IHNsZWVwKHRvb2sgPCA1MDAgPyB0b29rIDogNTAw
KTsKICAgICAgfQogICAgICBpZiAoYmVzdCA8PSAwKSBiZXN0ID0gMTsKICAgICAgYmVzdCArPSAx
NTsKICAgICAgc2xvdC5sYXRlbmN5ID0gU1RFUCArIE1hdGguY2VpbCgoYmVzdCAqIDEuNyArIDAu
MTYpIC8gMzMgLyBTVEVQKSAqIFNURVA7CiAgICAgIHNsb3QubGF0ZW5jeVRhcmdldCA9IHNsb3Qu
bGF0ZW5jeTsKICAgICAgc2xvdC5sYXRlbmN5U2hvd24gPSBzbG90LmxhdGVuY3k7CiAgICAgIHJv
b20uYnJvYWRjYXN0TGlzdCgtMSwgLTEpOwogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAoa2lu
ZCA9PT0gJ3N0YXJ0ZWRnYW1lJykgewogICAgICBzbG90LmZpZ2h0aW5nID0gdHJ1ZTsKICAgICAg
c2xvdC5oYXNQbGF5ZXIgPSBmYWxzZTsKICAgICAgdGhpcy5yZXNldEZyYW1lcygpOwogICAgICBm
b3IgKGxldCBrID0gMDsgayA8IDM7IGsgKz0gMSkgewogICAgICAgIGlmICghcm9vbS5tZW5bdGhp
cy5pbmRleCAqIDMgKyBrXS5leGlzdHMpIHsgc2xvdC5oYXNQbGF5ZXIgPSB0cnVlOyBicmVhazsg
fQogICAgICB9CiAgICAgIHNsb3Quc3RhcnRlZCA9IHRydWU7CiAgICAgIHJldHVybjsKICAgIH0K
ICAgIGlmIChraW5kID09PSAnd2ludGVhbScpIHsKICAgICAgY29uc3QgdGVhbSA9IGludCh0YWdW
YWx1ZShkb2MsICd3aW50ZWFtJykpOwogICAgICBpZiAoIXJvb20ud2luUmVwb3J0ZWQpIHsKICAg
ICAgICByb29tLndpblJlcG9ydGVkID0gdHJ1ZTsKICAgICAgICByb29tLmxvZyhgaGYgcm9vbSAk
e3Jvb20ubnVtYmVyfTogJHtyb29tLm1vZGV9IHdvbiBieSAke3RlYW19YCk7CiAgICAgIH0KICAg
IH0KICB9CgogIC8vIGkuaSgpOiB0aGlzIGdhbWUncyBwYWNrZXQgY2FtZTsgZWFjaCBvdGhlciBm
aWdodGluZyBnYW1lIGdldHMgYSBzZW5kLgogIHJlcXVlc3RGbHVzaGVzKCkgewogICAgY29uc3Qg
cm9vbSA9IHRoaXMucm9vbTsKICAgIGlmICghcm9vbS5maWdodGluZ05vdykgcmV0dXJuOwogICAg
Zm9yIChsZXQgaW5kZXggPSAwOyBpbmRleCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAg
aWYgKGluZGV4ICE9PSB0aGlzLmluZGV4ICYmIHJvb20uc2xvdHNbaW5kZXhdLmZpZ2h0aW5nKSBy
b29tLnNsb3RzW2luZGV4XS5mbHVzaGVzICs9IDE7CiAgICB9CiAgfQoKICAvLyBpLmIoKTogdGhl
IGZyYW1lcyBvZiB0aGUgb3RoZXJzIHRoaXMgZ2FtZSBoYXMgbm90IGhhZCwgYXMgbG9uZyBhcyBl
dmVyeSBvdGhlciBnYW1lIHNlbnQgdGhlbS4KICBzZW5kRnJhbWVzKCkgewogICAgY29uc3Qgcm9v
bSA9IHRoaXMucm9vbTsKICAgIGxldCB0ZXh0ID0gJyc7CiAgICBmb3IgKDs7KSB7CiAgICAgIGNv
bnN0IHQgPSB0aGlzLm5leHRGcmFtZTsKICAgICAgbGV0IGNvbXBsZXRlID0gdHJ1ZTsKICAgICAg
bGV0IGFueSA9IGZhbHNlOwogICAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgQ0xJRU5U
UzsgaW5kZXggKz0gMSkgewogICAgICAgIGlmIChpbmRleCA9PT0gdGhpcy5pbmRleCkgY29udGlu
dWU7CiAgICAgICAgY29uc3Qgb3RoZXIgPSByb29tLnNsb3RzW2luZGV4XTsKICAgICAgICBpZiAo
IW90aGVyLmZpZ2h0aW5nICYmIG90aGVyLmxlZnRGcmFtZSA8IHQpIGNvbnRpbnVlOwogICAgICAg
IGFueSA9IHRydWU7CiAgICAgICAgaWYgKG90aGVyLmxhc3RQYWNrZXQgPCB0KSB7IGNvbXBsZXRl
ID0gZmFsc2U7IGJyZWFrOyB9CiAgICAgIH0KICAgICAgaWYgKCFjb21wbGV0ZSB8fCAhYW55KSBi
cmVhazsKICAgICAgbGV0IHBhcnQgPSAnJzsKICAgICAgZm9yIChsZXQgaW5kZXggPSAwOyBpbmRl
eCA8IENMSUVOVFM7IGluZGV4ICs9IDEpIHsKICAgICAgICBpZiAoaW5kZXggPT09IHRoaXMuaW5k
ZXgpIGNvbnRpbnVlOwogICAgICAgIGNvbnN0IG90aGVyID0gcm9vbS5zbG90c1tpbmRleF07CiAg
ICAgICAgaWYgKChvdGhlci5maWdodGluZyB8fCBvdGhlci5sZWZ0RnJhbWUgPj0gdCkgJiYgb3Ro
ZXIubGFzdFBhY2tldCA+PSB0KSBwYXJ0ICs9IG90aGVyLmZyYW1lc1t0ICUgRlJBTUVTX0tFUFRd
IHx8ICcnOwogICAgICB9CiAgICAgIGlmICghcGFydCkgYnJlYWs7CiAgICAgIHRleHQgKz0gcGFy
dDsKICAgICAgdGhpcy5uZXh0RnJhbWUgKz0gMTsKICAgIH0KICAgIGlmICghdGV4dCkgcmV0dXJu
OwogICAgaWYgKHRoaXMucXVldWVkKSB7CiAgICAgIHRleHQgKz0gdGhpcy5xdWV1ZWQ7CiAgICAg
IHRoaXMucXVldWVkID0gJyc7CiAgICB9CiAgICB0aGlzLnNlbmQodGV4dCk7CiAgfQoKICByZXNl
dEZyYW1lcygpIHsgLy8gaS5jKCkKICAgIHRoaXMubGFzdEZyYW1lID0gLTE7CiAgICB0aGlzLm5l
eHRGcmFtZSA9IDA7CiAgICB0aGlzLnF1ZXVlZCA9ICcnOwogIH0KCiAgLy8gaS5hKCk6IHRoaXMg
Y29tcHV0ZXIgbGVhdmVzIHRoZSByb29tLgogIGxlYXZlKCkgewogICAgaWYgKHRoaXMuaW5kZXgg
PT09IC0xKSByZXR1cm47CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgY29uc3QgaW5k
ZXggPSB0aGlzLmluZGV4OwogICAgdGhpcy5yZXF1ZXN0Rmx1c2hlcygpOwogICAgY29uc3Qgc2xv
dCA9IHJvb20uc2xvdHNbaW5kZXhdOwogICAgaWYgKHNsb3Qub25saW5lICYmIHNsb3QuY29ubmVj
dGlvbiA9PT0gdGhpcykgewogICAgICBmb3IgKGNvbnN0IG1hbiBvZiByb29tLm1lbikgewogICAg
ICAgIGlmIChtYW4uY2xpZW50ICE9PSBpbmRleCAmJiAobWFuLmNvbW1hbmRlciA8IGluZGV4ICog
MyB8fCBtYW4uY29tbWFuZGVyID4gaW5kZXggKiAzICsgMikpIGNvbnRpbnVlOwogICAgICAgIE9i
amVjdC5hc3NpZ24obWFuLCBuZXdNYW4oKSwgeyByYW5kb206IHRydWUgfSk7CiAgICAgICAgbWFu
LmNoYXIgPSAnJzsKICAgICAgfQogICAgICBzbG90LmFkbWluID0gZmFsc2U7CiAgICAgIHNsb3Qu
b25saW5lID0gZmFsc2U7CiAgICAgIGlmIChzbG90Lmxhc3RQYWNrZXQgPiAwKSBzbG90LmxlZnRG
cmFtZSA9IHNsb3QubGFzdFBhY2tldDsKICAgICAgc2xvdC5maWdodGluZyA9IGZhbHNlOwogICAg
ICBzbG90Lmhhc1BsYXllciA9IGZhbHNlOwogICAgICBzbG90LmNvbm5lY3Rpb24gPSBudWxsOwog
ICAgICBpZiAoIXJvb20uZmlnaHRpbmdOb3cpIHJvb20uYnJvYWRjYXN0TWVuKDEpOwogICAgICBy
b29tLmJyb2FkY2FzdExpc3QoLTEsIGluZGV4KTsKICAgICAgdGhpcy5pbmRleCA9IC0xOwogICAg
ICByb29tLmxvZyhgaGYgcm9vbSAke3Jvb20ubnVtYmVyfTogJHt0aGlzLm5hbWV9IGxlYXZlc2Ap
OwogICAgICByb29tLnJlY291bnQoKTsKICAgIH0KICAgIHRoaXMuaW5kZXggPSAtMTsKICB9Cgog
IC8vIC0tLS0gd2hhdCB0aGUgc2VydmVyIHNlbmRzIG9uZSBnYW1lCiAgc2VuZFNldHRpbmcoY2lk
KSB7IC8vIGkuYShpbnQpCiAgICB0aGlzLnNlbmQoYDxzZXR0aW5nPiR7Y2lkICE9PSAtMSA/IGA8
Yz4ke2NpZH08L2M+YCA6ICcnfTx3YWl0d2hlbmZpZ2h0PiR7dGhpcy5yb29tLmFsbG93Sm9pbldo
ZW5GaWdodGluZyA/IDEgOiAwfTwvd2FpdHdoZW5maWdodD48L3NldHRpbmc+YCk7CiAgfQoKICBz
ZW5kR2FtZVNldHRpbmcoY2lkKSB7IC8vIGkuYihpbnQpCiAgICBjb25zdCByb29tID0gdGhpcy5y
b29tOwogICAgdGhpcy5zZW5kKGA8Z2FtZXNldHRpbmc+JHtjaWQgIT09IC0xID8gYDxjPiR7Y2lk
fTwvYz5gIDogJyd9PGJnaWQ+JHtyb29tLmJhY2tncm91bmR9PC9iZ2lkPjxtdXNpY2lkPiR7cm9v
bS5tdXNpY308L211c2ljaWQ+YAogICAgICArIGA8bXA+JHtyb29tLm11bHRpcGxhbmUgPyAxIDog
MH08L21wPjxiZ3JhbmRvbT4ke3Jvb20uYmFja2dyb3VuZFJhbmRvbSA/IDEgOiAwfTwvYmdyYW5k
b20+YAogICAgICArIGA8bXVzaWNyYW5kb20+JHtyb29tLm11c2ljUmFuZG9tID8gMSA6IDB9PC9t
dXNpY3JhbmRvbT48aG9yc2U+JHtyb29tLmhvcnNlc308L2hvcnNlPmAKICAgICAgKyBgPGdpYW50
b2JqPiR7cm9vbS5naWFudE9iamVjdHN9PC9naWFudG9iaj48ZGlmZj4ke3Jvb20uZGlmZmljdWx0
eX08L2RpZmY+PG5vcmxldj4ke3Jvb20ubm9ybWFsaXplTGV2ZWx9PC9ub3JsZXY+YAogICAgICAr
IGA8ZGlubz4ke3Jvb20uZGlub3NhdXJzfTwvZGlubz48dGVzdHRyb29wPiR7cm9vbS50ZXN0VHJv
b3BzfTwvdGVzdHRyb29wPjxzb2xkaWVybnVtYmVyPiR7cm9vbS5zb2xkaWVyTnVtYmVyfTwvc29s
ZGllcm51bWJlcj5gCiAgICAgICsgYDxzb2xkaWVycmVzZXJ2ZWQ+JHtyb29tLnNvbGRpZXJSZXNl
cnZlZH08L3NvbGRpZXJyZXNlcnZlZD48c3RvcnlpPiR7cm9vbS5zdG9yeX08L3N0b3J5aT5gCiAg
ICAgICsgYDxiYXR0bGV0eXBlPiR7cm9vbS5iYXR0bGVUeXBlfTwvYmF0dGxldHlwZT48cHJlc2V0
dHlwZT4ke3Jvb20ucHJlc2V0fTwvcHJlc2V0dHlwZT48L2dhbWVzZXR0aW5nPmApOwogIH0KCiAg
c2VuZExpc3Qoam9pbmVkLCBxdWl0KSB7IC8vIGkuYShpbnQsIGludCkKICAgIGxldCB0ZXh0ID0g
YDxsaXN0PjxjaWQ+JHt0aGlzLmluZGV4fTwvY2lkPmA7CiAgICBpZiAoam9pbmVkICE9PSAtMSkg
dGV4dCArPSBgPGpvaW5fY2lkPiR7am9pbmVkfTwvam9pbl9jaWQ+YDsKICAgIGlmIChxdWl0ICE9
PSAtMSkgdGV4dCArPSBgPHF1aXRfY2lkPiR7cXVpdH08L3F1aXRfY2lkPmA7CiAgICBmb3IgKGNv
bnN0IHNsb3Qgb2YgdGhpcy5yb29tLnNsb3RzKSB7CiAgICAgIHRleHQgKz0gYDxpbmZvPjxuYW1l
PjwhW0NEQVRBWyR7c2xvdC5uYW1lfV1dPjwvbmFtZT48b25saW5lPiR7c2xvdC5vbmxpbmUgPyAx
IDogMH08L29ubGluZT5gCiAgICAgICAgKyBgPGhhc3BsYXllcj4ke3Nsb3QuaGFzUGxheWVyID8g
MSA6IDB9PC9oYXNwbGF5ZXI+PGNjPiR7c2xvdC5jY308L2NjPjxwYXVzZWdhbWU+JHtzbG90LnBh
dXNlZCA/IDEgOiAwfTwvcGF1c2VnYW1lPmAKICAgICAgICArIGA8bGF0ZW5jeT4ke3Nsb3QubGF0
ZW5jeX08L2xhdGVuY3k+PHBhZ2U+JHtzbG90LnBhZ2V9PC9wYWdlPmA7CiAgICAgIGZvciAobGV0
IGsgPSAwOyBrIDwgMzsgayArPSAxKSB0ZXh0ICs9IGA8cD48IVtDREFUQVske3Nsb3QucGxheWVy
c1trXX1dXT48L3A+YDsKICAgICAgdGV4dCArPSBgPGxlYXZlX2Y+JHtzbG90LmxlZnRGcmFtZX08
L2xlYXZlX2Y+PC9pbmZvPmA7CiAgICB9CiAgICB0aGlzLnNlbmQodGV4dCArICc8L2xpc3Q+Jyk7
CiAgfQoKICBzZW5kTWVuKGNoYW5nZWQpIHsgLy8gaS5jKGludCkKICAgIGxldCB0ZXh0ID0gYDxt
YW5saXN0PjxudW1jaGFuZ2VkPiR7Y2hhbmdlZH08L251bWNoYW5nZWQ+YDsKICAgIGZvciAoY29u
c3QgbWFuIG9mIHRoaXMucm9vbS5tZW4pIHsKICAgICAgdGV4dCArPSBgPG1hbj48Y2lkPiR7bWFu
LmNsaWVudH08L2NpZD48Y29uPiR7bWFuLmNvbnRyb2xsZXJ9PC9jb24+PHRlYW0+JHttYW4udGVh
bX08L3RlYW0+PGNoYXI+JHttYW4uY2hhcn08L2NoYXI+YAogICAgICAgICsgYDxsdj4ke21hbi5s
ZXZlbH08L2x2Pjxjb21tPiR7bWFuLmNvbW1hbmRlcn08L2NvbW0+PHJhbmQ+JHttYW4ucmFuZG9t
ID8gMSA6IDB9PC9yYW5kPjxleGlzdD4ke21hbi5leGlzdHMgPyAxIDogMH08L2V4aXN0PjwvbWFu
PmA7CiAgICB9CiAgICB0aGlzLnNlbmQodGV4dCArICc8L21hbmxpc3Q+Jyk7CiAgfQoKICBub3Rp
Y2UodGV4dCkgeyAvLyBpLmIoU3RyaW5nKTogYSBsaW5lIGZyb20gdGhlIHNlcnZlciB0byB0aGlz
IGdhbWUgb25seQogICAgdGhpcy5zZW5kKGA8Y2hhdD48Yz4ke1NFUlZFUl9TTE9UfTwvYz48bT48
IVtDREFUQVs8Zm9udCBjb2xvcj0iI0ZGRkZBQSI+JHt0ZXh0fTwvZm9udD5dXT48L20+PC9jaGF0
PmApOwogIH0KCiAgYW5ub3VuY2UodGV4dCkgeyAvLyBpLmUoU3RyaW5nKTogYSBsaW5lIGZyb20g
dGhlIHNlcnZlciB0byBldmVyeW9uZQogICAgdGhpcy5yb29tLmJyb2FkY2FzdChgPGNoYXQ+PGM+
JHtTRVJWRVJfU0xPVH08L2M+PG0+PCFbQ0RBVEFbPGZvbnQgY29sb3I9IiNGRkNDRkYiPiR7dGV4
dH08L2ZvbnQ+XV0+PC9tPjwvY2hhdD5gKTsKICB9CgogIC8vIC0tLS0gdGhlIHdhaXRpbmcgcm9v
bSBhbmQgdGhlIG1lbnVzCiAgc3RhcnRDb3VudChkb2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlz
LnJvb207CiAgICBjb25zdCBjb3VudGRvd24gPSByb29tLmNvdW50ZG93bjsKICAgIGlmIChjb3Vu
dGRvd24ub24pIHJldHVybjsKICAgIGNvbnN0IGFjdGlvbiA9IHRhZ1ZhbHVlKGRvYywgJ2FjdGlv
bicpOwogICAgY29uc3QgcGFnZSA9IHRhZ1ZhbHVlKGRvYywgJ3BhZ2UnKTsKICAgIGxldCB0b2dl
dGhlciA9IHRydWU7CiAgICBmb3IgKGNvbnN0IHNsb3Qgb2Ygcm9vbS5vbmxpbmUoKSkgewogICAg
ICBpZiAocGFnZSA9PT0gJ0ZJR0hUSU5HJyA/IHNsb3QucGFnZSAhPT0gJ0ZJR0hUSU5HJyAmJiBz
bG90LnBhZ2UgIT09ICdXQUlUUk9PTScgOiBzbG90LnBhZ2UgIT09IHBhZ2UpIHsgdG9nZXRoZXIg
PSBmYWxzZTsgYnJlYWs7IH0KICAgIH0KICAgIGlmIChyb29tLnBhZ2UgIT09IHBhZ2UgfHwgIXRv
Z2V0aGVyKSByZXR1cm47CiAgICBjb25zdCBzdGFydCA9ICh3aGF0LCBjb3VudCA9IENPVU5URE9X
Tiwgc2hvd24gPSB3aGF0KSA9PiB7CiAgICAgIGNvdW50ZG93bi5vbiA9IHRydWU7CiAgICAgIGNv
dW50ZG93bi5hY3Rpb24gPSB3aGF0OwogICAgICBjb3VudGRvd24uY291bnQgPSBjb3VudDsKICAg
ICAgcm9vbS5icm9hZGNhc3RDbGljayh0aGlzLmluZGV4LCBzaG93bik7CiAgICB9OwogICAgY29u
c3QgemVybyA9ICgpID0+IGJ5VGFnKGRvYywgJ3plcm8nKS5sZW5ndGggJiYgdmFsdWVPZihieVRh
Zyhkb2MsICd6ZXJvJylbMF0pID09PSAndHJ1ZSc7CiAgICBpZiAocm9vbS5wYWdlID09PSAnV0FJ
VFJPT00nICYmIChhY3Rpb24gPT09ICdjbGlja3ZzJyB8fCBhY3Rpb24gPT09ICdjbGlja3N0b3J5
JyB8fCBhY3Rpb24gPT09ICdjbGlja2JhdHRsZScpKSB7CiAgICAgIHN0YXJ0KGFjdGlvbik7CiAg
ICB9IGVsc2UgaWYgKHJvb20ucGFnZSA9PT0gJ0NIQVJNRU5VJyAmJiBhY3Rpb24gPT09ICdjbGlj
a25leHQnKSB7CiAgICAgIGlmICh0aGlzLmNhblN0YXJ0KCkpIHN0YXJ0KGFjdGlvbiwgQ09VTlRE
T1dOLCByb29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJyB8fCByb29tLm1vZGUgPT09ICdTVE9SWU1P
REUnID8gJ2NsaWNrZmlnaHQnIDogYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAoKHJvb20ucGFnZSA9
PT0gJ1NUT1JZTUVOVScgfHwgcm9vbS5wYWdlID09PSAnQkFUVExFU0VUVElOR01FTlUnKSAmJiBh
Y3Rpb24gPT09ICdjbGlja25leHQnKSB7CiAgICAgIHN0YXJ0KGFjdGlvbik7CiAgICB9IGVsc2Ug
aWYgKHJvb20ucGFnZSA9PT0gJ0dBTUVTRVRUSU5HTUVOVScgJiYgYWN0aW9uID09PSAnY2xpY2tm
aWdodCcpIHsKICAgICAgc3RhcnQoYWN0aW9uKTsKICAgIH0gZWxzZSBpZiAocm9vbS5maWdodGlu
Z05vdyAmJiBhY3Rpb24gPT09ICdxdWl0Z2FtZScpIHsKICAgICAgY29uc3QgaXNaZXJvID0gemVy
bygpOwogICAgICBzdGFydChhY3Rpb24sIGlzWmVybyA/IDEgOiBDT1VOVERPV04gKiAyKTsKICAg
IH0gZWxzZSBpZiAocm9vbS5maWdodGluZ05vdyAmJiBhY3Rpb24gPT09ICdyZXN0YXJ0Z2FtZScp
IHsKICAgICAgaWYgKHJvb20uYmFja2dyb3VuZFJhbmRvbSkgcm9vbS5waWNrQmFja2dyb3VuZCgp
OwogICAgICBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgTUVOOyBpbmRleCArPSAxKSBpZiAo
cm9vbS5tZW5baW5kZXhdLmV4aXN0cyAmJiByb29tLm1lbltpbmRleF0ucmFuZG9tKSB0aGlzLnBp
Y2tDaGFyYWN0ZXIoaW5kZXgpOwogICAgICBpZiAocm9vbS5tdXNpY1JhbmRvbSkgcm9vbS5waWNr
TXVzaWMoKTsKICAgICAgc3RhcnQoYWN0aW9uLCBDT1VOVERPV04gKiAyKTsKICAgICAgaWYgKHpl
cm8oKSkgY291bnRkb3duLmNvdW50ID0gMTsKICAgIH0gZWxzZSBpZiAocm9vbS5maWdodGluZ05v
dyAmJiBhY3Rpb24gPT09ICduZXh0c3RhZ2UnKSB7CiAgICAgIHN0YXJ0KGFjdGlvbiwgQ09VTlRE
T1dOICogMik7CiAgICAgIGlmICh6ZXJvKCkpIGNvdW50ZG93bi5jb3VudCA9IDE7CiAgICB9CiAg
fQoKICAvLyBpLmQoKTogd2hldGhlciB0aGUgY2hhcmFjdGVyIG1lbnUgbWF5IGdvIG9uLgogIGNh
blN0YXJ0KCkgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGNvbnN0IHBlclRlYW0g
PSBbMCwgMCwgMCwgMCwgMF07CiAgICBsZXQgbWVuID0gMDsKICAgIGxldCBodW1hbnMgPSAwOwog
ICAgZm9yIChjb25zdCBtYW4gb2Ygcm9vbS5tZW4pIHsKICAgICAgaWYgKCFtYW4uZXhpc3RzKSBj
b250aW51ZTsKICAgICAgaWYgKG1hbi5jb250cm9sbGVyICE9PSAtMSAmJiByb29tLnNsb3RzW21h
bi5jbGllbnRdICYmIHJvb20uc2xvdHNbbWFuLmNsaWVudF0ub25saW5lKSBodW1hbnMgKz0gMTsK
ICAgICAgbWVuICs9IDE7CiAgICAgIHBlclRlYW1bbWFuLnRlYW0gKyAxXSArPSAxOwogICAgfQog
ICAgbGV0IHRlYW1zID0gcGVyVGVhbVswXTsKICAgIGxldCBjcm93ZGVkID0gZmFsc2U7CiAgICBm
b3IgKGxldCBrID0gMTsgayA8IDU7IGsgKz0gMSkgewogICAgICBpZiAocGVyVGVhbVtrXSA+IDAp
IHRlYW1zICs9IDE7CiAgICAgIGlmIChwZXJUZWFtW2tdID4gNSkgY3Jvd2RlZCA9IHRydWU7CiAg
ICB9CiAgICBjb25zdCByZWZ1c2UgPSAoYm9keSkgPT4geyB0aGlzLnNlbmQoYDxjaGFybWVudW5l
eHRlcnJvcj4ke2JvZHl9PC9jaGFybWVudW5leHRlcnJvcj5gKTsgcmV0dXJuIGZhbHNlOyB9Owog
ICAgaWYgKG1lbiA9PT0gMCkgcmV0dXJuIHJlZnVzZSgnPG0+Tm9QbGF5ZXI8L20+Jyk7CiAgICBp
ZiAoaHVtYW5zID09PSAwKSByZXR1cm4gcmVmdXNlKCc8bT5Ob0h1bWFuUGxheWVyPC9tPicpOwog
ICAgaWYgKG1lbiA9PT0gMSAmJiByb29tLm1vZGUgPT09ICdWU01PREUnKSByZXR1cm4gcmVmdXNl
KCc8bT5PbmVQbGF5ZXJPbmx5PC9tPicpOwogICAgaWYgKHRlYW1zIDw9IDEgJiYgcm9vbS5tb2Rl
ID09PSAnVlNNT0RFJykgcmV0dXJuIHJlZnVzZSgnPG0+T25lVGVhbU9ubHk8L20+Jyk7CiAgICBp
ZiAocm9vbS5tb2RlID09PSAnQkFUVExFTU9ERScpIHsKICAgICAgaWYgKHRlYW1zIDwgcm9vbS50
ZWFtcykgcmV0dXJuIHJlZnVzZShgPG0+YmF0dGxlTm9Fbm91Z2hUZWFtPC9tPjxhPiR7cm9vbS5i
YXR0bGVUeXBlfTwvYT48Yj4ke3Jvb20udGVhbXN9PC9iPjxjPiR7dGVhbXN9PC9jPmApOwogICAg
ICBpZiAoY3Jvd2RlZCkgcmV0dXJuIHJlZnVzZSgnPG0+YmF0dGxlTm90QWxsb3dNb3JlVGhhbjU8
L20+Jyk7CiAgICB9CiAgICByZXR1cm4gdHJ1ZTsKICB9CgogIGNsaWNrQmFjayhkb2MpIHsKICAg
IGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBpZiAocm9vbS5jb3VudGRvd24ub24gfHwgcm9v
bS5wYWdlICE9PSB0YWdWYWx1ZShkb2MsICdwYWdlJykpIHJldHVybjsKICAgIGNvbnN0IGJhY2sg
PSAobW9kZSwgcGFnZSkgPT4gewogICAgICByb29tLnByZXZpb3VzUGFnZSA9IHJvb20ucGFnZTsK
ICAgICAgaWYgKG1vZGUpIHJvb20ubW9kZSA9IG1vZGU7CiAgICAgIHJvb20ucGFnZSA9IHBhZ2U7
CiAgICAgIHJvb20uYnJvYWRjYXN0U3RhdHVzKCk7CiAgICAgIHJvb20uYnJvYWRjYXN0Q2xpY2so
dGhpcy5pbmRleCwgJ2NsaWNrYmFjaycpOwogICAgfTsKICAgIGlmIChyb29tLnBhZ2UgPT09ICdD
SEFSTUVOVScgJiYgcm9vbS5tb2RlID09PSAnVlNNT0RFJykgYmFjaygnV0FJVFJPT00nLCAnV0FJ
VFJPT00nKTsKICAgIGVsc2UgaWYgKHJvb20ucGFnZSA9PT0gJ0NIQVJNRU5VJyAmJiByb29tLm1v
ZGUgPT09ICdTVE9SWU1PREUnKSBiYWNrKCdTVE9SWU1PREUnLCAnU1RPUllNRU5VJyk7CiAgICBl
bHNlIGlmIChyb29tLnBhZ2UgPT09ICdDSEFSTUVOVScgJiYgcm9vbS5tb2RlID09PSAnQkFUVExF
TU9ERScpIGJhY2soJ0JBVFRMRU1PREUnLCAnQkFUVExFU0VUVElOR01FTlUnKTsKICAgIGVsc2Ug
aWYgKHJvb20ucGFnZSA9PT0gJ1NUT1JZTUVOVScgfHwgcm9vbS5wYWdlID09PSAnQkFUVExFU0VU
VElOR01FTlUnKSBiYWNrKCdXQUlUUk9PTScsICdXQUlUUk9PTScpOwogICAgZWxzZSBpZiAocm9v
bS5wYWdlID09PSAnR0FNRVNFVFRJTkdNRU5VJykgYmFjayhudWxsLCAnQ0hBUk1FTlUnKTsKICB9
CgogIGdhbWVTZXR0aW5nKGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRoaXMucm9vbTsKICAgIGlm
ICghWydHQU1FU0VUVElOR01FTlUnLCAnQ0hBUk1FTlUnLCAnU1RPUllNRU5VJywgJ0JBVFRMRVNF
VFRJTkdNRU5VJ10uaW5jbHVkZXMocm9vbS5wYWdlKSkgcmV0dXJuOwogICAgY29uc3QgdmFsdWUg
PSAobmFtZSkgPT4geyBjb25zdCBmb3VuZCA9IGJ5VGFnKGRvYywgbmFtZSk7IHJldHVybiBmb3Vu
ZC5sZW5ndGggPyB2YWx1ZU9mKGZvdW5kWzBdKSA6IHVuZGVmaW5lZDsgfTsKICAgIGNvbnN0IGJh
Y2tncm91bmQgPSB2YWx1ZSgnYmdpZCcpOwogICAgaWYgKGJhY2tncm91bmQgIT09IHVuZGVmaW5l
ZCAmJiAocm9vbS5iYWNrZ3JvdW5kUmFuZG9tIHx8IHJvb20uYmFja2dyb3VuZCAhPT0gYmFja2dy
b3VuZCkpIHsKICAgICAgcm9vbS5iYWNrZ3JvdW5kID0gcm9vbS5iYWNrZ3JvdW5kQ2hvc2VuID0g
YmFja2dyb3VuZDsKICAgICAgaWYgKGJhY2tncm91bmQgPT09ICdyYW5kb20nKSB7CiAgICAgICAg
cm9vbS5iYWNrZ3JvdW5kUmFuZG9tID0gdHJ1ZTsKICAgICAgICByb29tLnBpY2tCYWNrZ3JvdW5k
KCk7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgcm9vbS5iYWNrZ3JvdW5kUmFuZG9tID0gZmFsc2U7
CiAgICAgIH0KICAgIH0KICAgIGNvbnN0IG11c2ljID0gdmFsdWUoJ211c2ljaWQnKTsKICAgIGlm
IChtdXNpYyAhPT0gdW5kZWZpbmVkICYmIChyb29tLm11c2ljUmFuZG9tIHx8IHJvb20ubXVzaWMg
IT09IG11c2ljKSkgewogICAgICByb29tLm11c2ljID0gbXVzaWM7CiAgICAgIGlmIChtdXNpYyA9
PT0gJ3JhbmRvbScpIHsKICAgICAgICByb29tLm11c2ljUmFuZG9tID0gdHJ1ZTsKICAgICAgICBy
b29tLnBpY2tNdXNpYygpOwogICAgICB9IGVsc2UgewogICAgICAgIHJvb20ubXVzaWNSYW5kb20g
PSBmYWxzZTsKICAgICAgfQogICAgfQogICAgY29uc3QgbXVsdGlwbGFuZSA9IHZhbHVlKCdtcCcp
OwogICAgaWYgKG11bHRpcGxhbmUgIT09IHVuZGVmaW5lZCkgcm9vbS5tdWx0aXBsYW5lID0gbXVs
dGlwbGFuZSA9PT0gJzEnOwogICAgY29uc3QgbnVtYmVycyA9IFtbJ2hvcnNlJywgJ2hvcnNlcydd
LCBbJ2dpYW50b2JqJywgJ2dpYW50T2JqZWN0cyddLCBbJ2RpZmYnLCAnZGlmZmljdWx0eSddLCBb
J25vcmxldicsICdub3JtYWxpemVMZXZlbCddLAogICAgICBbJ2Rpbm8nLCAnZGlub3NhdXJzJ10s
IFsndGVzdHRyb29wJywgJ3Rlc3RUcm9vcHMnXSwgWydzb2xkaWVybnVtYmVyJywgJ3NvbGRpZXJO
dW1iZXInXSwKICAgICAgWydzb2xkaWVycmVzZXJ2ZWQnLCAnc29sZGllclJlc2VydmVkJ10sIFsn
c3RvcnlpJywgJ3N0b3J5J11dOwogICAgZm9yIChjb25zdCBbdGFnLCBmaWVsZF0gb2YgbnVtYmVy
cykgewogICAgICBjb25zdCByYXcgPSB2YWx1ZSh0YWcpOwogICAgICBpZiAocmF3ICE9PSB1bmRl
ZmluZWQpIHJvb21bZmllbGRdID0gaW50KHJhdyk7CiAgICB9CiAgICBjb25zdCByYXcgPSB2YWx1
ZSgnYnQnKTsKICAgIGlmIChyYXcgIT09IHVuZGVmaW5lZCAmJiByb29tLnByZXNldCAhPT0gLWlu
dChyYXcpIC0gMSAmJiAocm9vbS5wcmVzZXQgIT09IC0xIHx8IHJvb20uYmF0dGxlVHlwZSAhPT0g
aW50KHJhdykpKSB7CiAgICAgIGxldCB0eXBlID0gaW50KHJhdyk7CiAgICAgIGlmICh0eXBlIDwg
MCkgewogICAgICAgIGZvciAobGV0IGluZGV4ID0gMDsgaW5kZXggPCBNRU47IGluZGV4ICs9IDEp
IHsKICAgICAgICAgIHJvb20ubWVuW2luZGV4XS5leGlzdHMgPSBmYWxzZTsKICAgICAgICAgIGlm
IChpbmRleCA+PSAxMikgcm9vbS5tZW5baW5kZXhdLnJhbmRvbSA9IGZhbHNlOwogICAgICAgICAg
cm9vbS5tZW5baW5kZXhdLmNvbW1hbmRlciA9IC0xOwogICAgICAgIH0KICAgICAgICByb29tLnBy
ZXNldCA9IC10eXBlIC0gMTsKICAgICAgICBjb25zdCBwcmVzZXQgPSAobGV2ZWwsIGxpc3QpID0+
IGxpc3QuZm9yRWFjaCgoW2luZGV4LCBjaGFyLCB0ZWFtXSkgPT4gT2JqZWN0LmFzc2lnbihyb29t
Lm1lbltpbmRleF0sIHsgbGV2ZWwsIGNoYXIsIGV4aXN0czogdHJ1ZSwgdGVhbSB9KSk7CiAgICAg
ICAgaWYgKHR5cGUgPT09IC0xKSB7CiAgICAgICAgICB0eXBlID0gMTE7CiAgICAgICAgICBwcmVz
ZXQoMTAsIFtbMTksICdsZW8nLCAxXSwgWzIwLCAnaWN6enknLCAxXSwgWzIxLCAnaGVhdGVyJywg
MV0sIFsyMiwgJ3JheWUnLCAxXSwgWzIzLCAnc2luYW4nLCAxXV0pOwogICAgICAgIH0gZWxzZSBp
ZiAodHlwZSA9PT0gLTIpIHsKICAgICAgICAgIHR5cGUgPSAxMTExOwogICAgICAgICAgcHJlc2V0
KDExLCBbWzE1LCAndGF5bG9yJywgMV0sIFsxNiwgJ2xlbycsIDFdLCBbMTcsICdqZW5ueScsIDFd
LCBbMTgsICdyYXllJywgMl0sIFsxOSwgJ2ljenp5JywgMl0sIFsyMCwgJ2hlYXRlcicsIDJdLAog
ICAgICAgICAgICBbMjEsICdnb3Jkb24nLCAzXSwgWzIyLCAnamFzb24nLCAzXSwgWzIzLCAndGl0
dG8nLCAzXV0pOwogICAgICAgIH0gZWxzZSBpZiAodHlwZSA9PT0gLTMpIHsKICAgICAgICAgIHR5
cGUgPSAxMTE7CiAgICAgICAgICBwcmVzZXQoMTIsIFtbMTUsICdoZWF0ZXInLCAxXSwgWzE2LCAn
aWN6enknLCAxXSwgWzE3LCAncmF5ZScsIDFdLCBbMTgsICdzaW5hbicsIDFdLCBbMTksICd0aXR0
bycsIDFdLCBbMjAsICdsZW8nLCAyXSwKICAgICAgICAgICAgWzIxLCAnZ29yZG9uJywgMl0sIFsy
MiwgJ2plbm55JywgMl0sIFsyMywgJ2phc29uJywgMl1dKTsKICAgICAgICB9IGVsc2UgaWYgKHR5
cGUgPT09IC00KSB7CiAgICAgICAgICB0eXBlID0gMTEyOwogICAgICAgICAgcHJlc2V0KDE0LCBb
WzE1LCAnbGVvJywgMF0sIFsxNiwgJ3NpbmFuJywgMF0sIFsxNywgJ2dvcmRvbicsIDBdLCBbMTgs
ICdpY3p6eScsIDFdLCBbMTksICdoZWF0ZXInLCAxXSwgWzIwLCAncmF5ZScsIDFdLAogICAgICAg
ICAgICBbMjEsICdqYXNvbicsIDNdLCBbMjIsICd0aXR0bycsIDNdLCBbMjMsICdnaWdncycsIDNd
XSk7CiAgICAgICAgfQogICAgICB9IGVsc2UgewogICAgICAgIHJvb20ucHJlc2V0ID0gLTE7CiAg
ICAgIH0KICAgICAgcm9vbS5iYXR0bGVUeXBlID0gdHlwZTsKICAgICAgaWYgKHR5cGUgPT09IDEx
KSByb29tLnRlYW1zID0gMjsKICAgICAgZWxzZSBpZiAodHlwZSA9PT0gMTIgfHwgdHlwZSA9PT0g
MTExKSByb29tLnRlYW1zID0gMzsKICAgICAgZWxzZSBpZiAodHlwZSA9PT0gMjIgfHwgdHlwZSA9
PT0gMTMgfHwgdHlwZSA9PT0gMTExMSB8fCB0eXBlID09PSAxMTIpIHJvb20udGVhbXMgPSA0Owog
ICAgICBpZiAocm9vbS50ZWFtcyA9PT0gMikgcm9vbS5iYWNrZ3JvdW5kID0gJ2JhdHRsZTInOwog
ICAgICBlbHNlIGlmIChyb29tLnRlYW1zID09PSAzKSByb29tLmJhY2tncm91bmQgPSAnYmF0dGxl
Myc7CiAgICAgIGVsc2UgaWYgKHJvb20udGVhbXMgPT09IDQpIHJvb20uYmFja2dyb3VuZCA9ICdi
YXR0bGU0JzsKICAgICAgY29uc3QgbWFwcyA9IHsgMTE6IFswLCAxLCAtMSwgLTFdLCAyMjogWzAs
IDEsIDAsIDFdLCAxMTE6IFswLCAxLCAyLCAtMV0sIDExMTE6IFswLCAxLCAyLCAzXSwgMTI6IFsx
LCAwLCAxLCAtMV0sCiAgICAgICAgMTM6IFswLCAxLCAxLCAxXSwgMTEyOiBbMSwgMSwgMCwgMl0g
fTsKICAgICAgaWYgKG1hcHNbdHlwZV0pIHJvb20udGVhbU1hcCA9IG1hcHNbdHlwZV07CiAgICB9
CiAgICByb29tLmJyb2FkY2FzdEdhbWVTZXR0aW5nKHRoaXMuaW5kZXgpOwogIH0KCiAgdXBkYXRl
SW5mbyhkb2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207CiAgICBjb25zdCBzbG90ID0g
dGhpcy5zbG90OwogICAgc2xvdC5uYW1lID0gdGFnVmFsdWUoZG9jLCAnbmFtZScpOyAvLyAodGhl
IG9yaWdpbmFsIGtlZXBzIHRoZSBuYW1lIGl0IGpvaW5lZCB3aXRoIGZvciBpdHMgbG9nIGFuZCAv
bWUpCiAgICBmb3IgKGxldCBrID0gMDsgayA8IDM7IGsgKz0gMSkgc2xvdC5wbGF5ZXJzW2tdID0g
dGhpcy5wbGF5ZXJzW2tdID0gdGFnVmFsdWUoZG9jLCAncCcsIGspOwogICAgZm9yIChsZXQgayA9
IDA7IGsgPCAzMDsgayArPSAxKSB7CiAgICAgIHNsb3QubGV2ZWxzW2tdID0gaW50KHRhZ1ZhbHVl
KGRvYywgJ2wnLCBrKSk7CiAgICAgIGlmIChzbG90LmxldmVsc1trXSA+IE1BWF9MRVZFTCkgdGhp
cy5jaGVhdCA9IDE7CiAgICB9CiAgICBmb3IgKGxldCBrID0gMDsgayA8IDM7IGsgKz0gMSkgewog
ICAgICBjb25zdCBtYW4gPSByb29tLm1lblt0aGlzLmluZGV4ICogMyArIGtdOwogICAgICBpZiAo
IW1hbi5leGlzdHMpIGNvbnRpbnVlOwogICAgICBjb25zdCBjaGFyYWN0ZXIgPSBDSEFSQUNURVJT
LmluZGV4T2YobWFuLmNoYXIpOwogICAgICBpZiAoY2hhcmFjdGVyID49IDAgJiYgc2xvdC5sZXZl
bHNbY2hhcmFjdGVyXSA+IDApIHsKICAgICAgICBtYW4ubGV2ZWwgPSBzbG90LmxldmVsc1tjaGFy
YWN0ZXJdOwogICAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5tZW4pIGlmIChvdGhlci5l
eGlzdHMgJiYgb3RoZXIuY29tbWFuZGVyID09PSB0aGlzLmluZGV4ICogMyArIGspIG90aGVyLmxl
dmVsID0gbWFuLmxldmVsOwogICAgICB9CiAgICB9CiAgICBpZiAoIXJvb20uZmlnaHRpbmdOb3cp
IHsKICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgIHJvb20uYnJvYWRjYXN0
TWVuKDEpOwogICAgfQogIH0KCiAgYWRkUGxheWVyKGRvYykgewogICAgY29uc3Qgcm9vbSA9IHRo
aXMucm9vbTsKICAgIGlmIChyb29tLnBhZ2UgIT09ICdDSEFSTUVOVScpIHJldHVybjsKICAgIGNv
bnN0IGNvbnRyb2xsZXIgPSBpbnQodmFsdWVPZihkb2MpKTsKICAgIGNvbnN0IGluZGV4ID0gdGhp
cy5pbmRleCAqIDMgKyBjb250cm9sbGVyOwogICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5kZXhd
OwogICAgaWYgKCFtYW4gfHwgY29udHJvbGxlciA8IDAgfHwgY29udHJvbGxlciA+IDIpIHRocm93
IG5ldyBYbWxFcnJvcignbm8gc3VjaCBwbGF5ZXInKTsKICAgIGlmIChtYW4uZXhpc3RzKSByZXR1
cm47CiAgICBtYW4uZXhpc3RzID0gdHJ1ZTsKICAgIG1hbi5jbGllbnQgPSB0aGlzLmluZGV4Owog
ICAgbWFuLmNvbnRyb2xsZXIgPSBjb250cm9sbGVyOwogICAgbWFuLnRlYW0gPSAtMTsKICAgIHJv
b20ubWVuLmZvckVhY2goKG90aGVyLCBrKSA9PiB7IGlmIChrICE9PSBpbmRleCAmJiBvdGhlci5l
eGlzdHMgJiYgb3RoZXIuY2xpZW50ID09PSB0aGlzLmluZGV4KSBtYW4udGVhbSA9IG90aGVyLnRl
YW07IH0pOwogICAgaWYgKG1hbi50ZWFtID09PSAtMSkgbWFuLnRlYW0gPSB0aGlzLmxlYXN0VGVh
bShpbmRleCk7CiAgICBpZiAobWFuLnJhbmRvbSB8fCAhbWFuLmNoYXIpIHsKICAgICAgbWFuLnJh
bmRvbSA9IHRydWU7CiAgICAgIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7CiAgICB9IGVsc2Ug
ewogICAgICBjb25zdCBjaGFyYWN0ZXIgPSBDSEFSQUNURVJTLmluZGV4T2YobWFuLmNoYXIpOwog
ICAgICBpZiAoY2hhcmFjdGVyID49IDAgJiYgKHRoaXMuc2xvdC5sZXZlbHNbY2hhcmFjdGVyXSA8
PSAwIHx8IHRoaXMuc2xvdC5sZXZlbHNbY2hhcmFjdGVyXSAhPT0gbWFuLmxldmVsKSkgewogICAg
ICAgIG1hbi5yYW5kb20gPSB0cnVlOwogICAgICAgIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7
CiAgICAgIH0KICAgIH0KICAgIHRoaXMubGltaXRNZW4oKTsKICAgIHJvb20uYnJvYWRjYXN0TWVu
KDEpOwogIH0KCiAgLy8gVGhlIHRlYW0gd2l0aCB0aGUgZmV3ZXN0IG1lbiAobm90IGNvdW50aW5n
IHNvbGRpZXJzKSwgZm9yIGEgbmV3IG1hbi4KICBsZWFzdFRlYW0oZXhjZXB0KSB7CiAgICBjb25z
dCByb29tID0gdGhpcy5yb29tOwogICAgY29uc3QgY291bnRzID0gWzAsIDAsIDAsIDBdOwogICAg
cm9vbS5tZW4uZm9yRWFjaCgob3RoZXIsIGspID0+IHsgaWYgKGsgIT09IGV4Y2VwdCAmJiBvdGhl
ci5leGlzdHMgJiYgb3RoZXIuY29tbWFuZGVyID09PSAtMSkgY291bnRzW290aGVyLnRlYW1dICs9
IDE7IH0pOwogICAgaWYgKHJvb20ubW9kZSAhPT0gJ0JBVFRMRU1PREUnKSByb29tLnRlYW1zID0g
NDsKICAgIGxldCBmZXdlc3QgPSA5OTk7CiAgICBsZXQgdGVhbSA9IDA7CiAgICBmb3IgKGxldCBr
ID0gMDsgayA8IHJvb20udGVhbXM7IGsgKz0gMSkgewogICAgICBpZiAoY291bnRzW2tdIDwgZmV3
ZXN0KSB7CiAgICAgICAgZmV3ZXN0ID0gY291bnRzW2tdOwogICAgICAgIHRlYW0gPSBrOwogICAg
ICB9CiAgICB9CiAgICByZXR1cm4gdGVhbTsKICB9CgogIC8vIGkuZSgpOiBhIGNvbXB1dGVyIHBs
YXllciwgaW4gdGhlIGZpcnN0IGZyZWUgcGxhY2UgYWZ0ZXIgdGhlIDEyIGh1bWFuIG9uZXMuCiAg
YWRkQ29tcHV0ZXIoKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20u
bWVuLmZpbHRlcigobWFuKSA9PiBtYW4uZXhpc3RzKS5sZW5ndGggPj0gMTIpIHJldHVybiBmYWxz
ZTsKICAgIGZvciAobGV0IGluZGV4ID0gTUVOIC0gMTsgaW5kZXggPj0gMTI7IGluZGV4IC09IDEp
IHsKICAgICAgaWYgKHJvb20ubWVuW2luZGV4XS5leGlzdHMgfHwgKGluZGV4ICE9PSAxMiAmJiAh
cm9vbS5tZW5baW5kZXggLSAxXS5leGlzdHMpKSBjb250aW51ZTsKICAgICAgY29uc3QgbWFuID0g
cm9vbS5tZW5baW5kZXhdOwogICAgICBtYW4uZXhpc3RzID0gdHJ1ZTsKICAgICAgbWFuLnRlYW0g
PSByb29tLm1vZGUgPT09ICdCQVRUTEVNT0RFJyB8fCByb29tLm1vZGUgPT09ICdWU01PREUnID8g
dGhpcy5sZWFzdFRlYW0oaW5kZXgpIDogMzsKICAgICAgbWFuLmNsaWVudCA9IC0xOwogICAgICBt
YW4uY29udHJvbGxlciA9IC0xOwogICAgICBtYW4ucmFuZG9tID0gdHJ1ZTsKICAgICAgbWFuLmNv
bW1hbmRlciA9IC0xOwogICAgICB0aGlzLnBpY2tDaGFyYWN0ZXIoaW5kZXgpOwogICAgICByZXR1
cm4gdHJ1ZTsKICAgIH0KICAgIHJldHVybiBmYWxzZTsKICB9CgogIGFkZFNvbGRpZXIoZG9jKSB7
CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20ucGFnZSAhPT0gJ0NIQVJN
RU5VJyB8fCByb29tLmNvdW50ZG93bi5vbikgcmV0dXJuOwogICAgY29uc3QgaW5kZXggPSBpbnQo
dGFnVmFsdWUoZG9jLCAnaScpKTsKICAgIGxldCBzb2xkaWVyID0gdGFnVmFsdWUoZG9jLCAnY2hh
cicpOwogICAgY29uc3QgY29tbWFuZGVyID0gcm9vbS5tZW5baW5kZXhdOwogICAgaWYgKCFjb21t
YW5kZXIpIHRocm93IG5ldyBYbWxFcnJvcignbm8gc3VjaCBtYW4nKTsKICAgIGNvbnN0IHJvbGwg
PSB0aGlzLnJvb20ucmFuZG9tKCk7CiAgICBzd2l0Y2ggKGNvbW1hbmRlci5jaGFyKSB7CiAgICAg
IGNhc2UgJ2x1Y2FzJzogY2FzZSAnZHJldyc6IGNhc2UgJ3NoYXduJzoKICAgICAgICBpZiAoc29s
ZGllciA9PT0gJ3pfaW5mYW50cnkwMScgJiYgcm9sbCA8IDAuMykgc29sZGllciA9ICd6X3ZpbGxh
Z2VyMDEnOwogICAgICAgIGVsc2UgaWYgKHNvbGRpZXIgPT09ICd6X2FyY2hlcjAxJyAmJiByb2xs
IDwgMC4zKSBzb2xkaWVyID0gJ3pfd29tYW4wMSc7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2Ug
J3Zpdmlhbic6CiAgICAgICAgaWYgKHNvbGRpZXIgPT09ICd6X2luZmFudHJ5MDEnKSBzb2xkaWVy
ID0gJ3pfdmlsbGFnZXIwMSc7CiAgICAgICAgZWxzZSBpZiAoc29sZGllciA9PT0gJ3pfYXJjaGVy
MDEnKSBzb2xkaWVyID0gJ3pfd29tYW4wMSc7CiAgICAgICAgYnJlYWs7CiAgICAgIGNhc2UgJ2pl
bm55JzogY2FzZSAnc2luYW4nOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9hcmNoZXIwMScp
IHNvbGRpZXIgPSAnel93b21hbjAxJzsKICAgICAgICBicmVhazsKICAgICAgY2FzZSAnamFzb24n
OgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9pbmZhbnRyeTAxJykgc29sZGllciA9ICd6X2Jh
bmRpdDAxJzsKICAgICAgICBlbHNlIGlmIChzb2xkaWVyID09PSAnel9hcmNoZXIwMScpIHNvbGRp
ZXIgPSAnel9kYWdnZXIwMSc7CiAgICAgICAgZWxzZSBzb2xkaWVyID0gJ3pfc2lja2xlMDEnOwog
ICAgICAgIGJyZWFrOwogICAgICBjYXNlICdnaWdncyc6IGNhc2UgJ3RpdHRvJzoKICAgICAgICBp
ZiAoc29sZGllciA9PT0gJ3pfaW5mYW50cnkwMScpIHNvbGRpZXIgPSAnel9iYW5kaXQwMSc7CiAg
ICAgICAgZWxzZSBpZiAoc29sZGllciA9PT0gJ3pfYXJjaGVyMDEnKSBzb2xkaWVyID0gJ3pfZGFn
Z2VyMDEnOwogICAgICAgIGJyZWFrOwogICAgICBjYXNlICdpY3p6eSc6CiAgICAgICAgaWYgKHNv
bGRpZXIgPT09ICd6X2NhdmFscnkwMScpIHNvbGRpZXIgPSAnel9pY2VtYW4nOwogICAgICAgIGJy
ZWFrOwogICAgICBjYXNlICdoZWF0ZXInOgogICAgICAgIGlmIChzb2xkaWVyID09PSAnel9jYXZh
bHJ5MDEnKSBzb2xkaWVyID0gJ3pfc2t1bGwnOwogICAgICAgIGJyZWFrOwogICAgICBkZWZhdWx0
OgogICAgICAgIGJyZWFrOwogICAgfQogICAgaWYgKGNvbW1hbmRlci5leGlzdHMgJiYgY29tbWFu
ZGVyLmNvbW1hbmRlciA9PT0gLTEgJiYgdGhpcy5wbGFjZVNvbGRpZXIoaW5kZXgsIHNvbGRpZXIp
KSB7CiAgICAgIHRoaXMubGltaXRNZW4oKTsKICAgICAgcm9vbS5icm9hZGNhc3RNZW4oMSk7CiAg
ICB9CiAgfQoKICAvLyBpLmEoaW50LCBTdHJpbmcpCiAgcGxhY2VTb2xkaWVyKGNvbW1hbmRlcklu
ZGV4LCBzb2xkaWVyKSB7CiAgICBjb25zdCByb29tID0gdGhpcy5yb29tOwogICAgaWYgKHJvb20u
bWVuLmZpbHRlcigobWFuKSA9PiBtYW4uZXhpc3RzKS5sZW5ndGggPj0gMTIpIHJldHVybiBmYWxz
ZTsKICAgIGZvciAobGV0IGluZGV4ID0gMTI7IGluZGV4IDwgTUVOOyBpbmRleCArPSAxKSB7CiAg
ICAgIGNvbnN0IG1hbiA9IHJvb20ubWVuW2luZGV4XTsKICAgICAgaWYgKG1hbi5leGlzdHMpIGNv
bnRpbnVlOwogICAgICBjb25zdCBjb21tYW5kZXIgPSByb29tLm1lbltjb21tYW5kZXJJbmRleF07
CiAgICAgIE9iamVjdC5hc3NpZ24obWFuLCB7IGV4aXN0czogdHJ1ZSwgY2xpZW50OiAtMSwgY29u
dHJvbGxlcjogLTEsIHRlYW06IGNvbW1hbmRlci50ZWFtLCByYW5kb206IGZhbHNlLAogICAgICAg
IGNvbW1hbmRlcjogY29tbWFuZGVySW5kZXgsIGNoYXI6IHNvbGRpZXIsIGxldmVsOiBjb21tYW5k
ZXIubGV2ZWwgfSk7CiAgICAgIHJldHVybiB0cnVlOwogICAgfQogICAgcmV0dXJuIGZhbHNlOwog
IH0KCiAgLy8gaS5mKCk6IGF0IG1vc3QgMTIgbWVuOyB0aGUgbGF0ZXIgb25lcyBnby4KICBsaW1p
dE1lbigpIHsKICAgIGxldCBjb3VudCA9IDA7CiAgICBmb3IgKGNvbnN0IG1hbiBvZiB0aGlzLnJv
b20ubWVuKSB7CiAgICAgIGlmICghbWFuLmV4aXN0cykgY29udGludWU7CiAgICAgIGlmIChjb3Vu
dCA8IDEyKSBjb3VudCArPSAxOwogICAgICBlbHNlIG1hbi5leGlzdHMgPSBmYWxzZTsKICAgIH0K
ICB9CgogIGNob29zZUNoYXJhY3Rlcihkb2MpIHsKICAgIGNvbnN0IHJvb20gPSB0aGlzLnJvb207
CiAgICBpZiAocm9vbS5wYWdlICE9PSAnQ0hBUk1FTlUnKSByZXR1cm47CiAgICBjb25zdCBpbmRl
eCA9IGludCh0YWdWYWx1ZShkb2MsICdpJykpOwogICAgY29uc3QgbWFuID0gcm9vbS5tZW5baW5k
ZXhdOwogICAgaWYgKCFtYW4pIHRocm93IG5ldyBYbWxFcnJvcignbm8gc3VjaCBtYW4nKTsKICAg
IGlmICghbWFuLmV4aXN0cyB8fCAobWFuLmNvbnRyb2xsZXIgIT09IC0xICYmIG1hbi5jbGllbnQg
IT09IHRoaXMuaW5kZXgpKSByZXR1cm47CiAgICBtYW4uY2hhciA9IHRhZ1ZhbHVlKGRvYywgJ2No
YXInKTsKICAgIGlmIChtYW4uY2hhciA9PT0gbnVsbCkgdGhyb3cgbmV3IFhtbEVycm9yKCdubyBj
aGFyYWN0ZXInKTsKICAgIGlmIChtYW4uY2hhciA9PT0gJ3JhbmRvbScpIHsKICAgICAgbWFuLnJh
bmRvbSA9IHRydWU7CiAgICAgIHRoaXMucGlja0NoYXJhY3RlcihpbmRleCk7CiAgICB9IGVsc2Ug
ewogICAgICBtYW4ucmFuZG9tID0gZmFsc2U7CiAgICB9CiAgICBtYW4ubGV2ZWwgPSAxOwogICAg
Y29uc3QgY2hhcmFjdGVyID0gQ0hBUkFDVEVSUy5pbmRleE9mKG1hbi5jaGFyKTsKICAgIGlmIChj
aGFyYWN0ZXIgPj0gMCkgewogICAgICBjb25zdCBsZXZlbCA9IHRoaXMuc2xvdC5sZXZlbHNbY2hh
cmFjdGVyXTsKICAgICAgaWYgKGxldmVsID4gMCkgewogICAgICAgIG1hbi5sZXZlbCA9IGxldmVs
OwogICAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5tZW4pIGlmIChvdGhlci5leGlzdHMg
JiYgb3RoZXIuY29tbWFuZGVyID09PSBpbmRleCkgb3RoZXIubGV2ZWwgPSBsZXZlbDsKICAgICAg
fQogICAgICBpZiAobGV2ZWwgPD0gMCAmJiBtYW4uY29udHJvbGxlciA+PSAwICYmIG1hbi5jbGll
bnQgPT09IHRoaXMuaW5kZXgpIHsKICAgICAgICAvLyBBIGNoYXJhY3RlciB0aGlzIGFjY291bnQg
aGFzIG5vdCB1bmxvY2tlZDogdGhlIG9yaWdpbmFsIHNodXRzIHRoZSBnYW1lIG91dC4KICAgICAg
ICB0aGlzLmtpY2tlZCA9IHRydWU7CiAgICAgICAgdGhpcy5sZWF2ZSgpOwogICAgICAgIHJldHVy
bjsKICAgICAgfQogICAgfQogICAgcm9vbS5icm9hZGNhc3RNZW4oMCk7CiAgfQoKICAvLyBpLmQo
aW50KTogYSByYW5kb20gY2hhcmFjdGVyIGZvciBhIG1hbjogb25lIHRoZSBjb21wdXRlciBoYXMg
KGZvciBhIGNvbXB1dGVyIHBsYXllciwgb25lIGFueQogIC8vIGNvbXB1dGVyIGluIHRoZSByb29t
IGhhcyksIG5vdCB0YWtlbiBieSBhbm90aGVyIG1hbiBiZWZvcmUgaXQgb3Igbm90IHJhbmRvbTsg
dGhlIGxldmVsIHRvIG1hdGNoLgogIHBpY2tDaGFyYWN0ZXIoaW5kZXgpIHsKICAgIGNvbnN0IHJv
b20gPSB0aGlzLnJvb207CiAgICBjb25zdCBtYW4gPSByb29tLm1lbltpbmRleF07CiAgICBjb25z
dCBodW1hbiA9IG1hbi5jbGllbnQgIT09IC0xOwogICAgbGV0IG93bmVyID0gbWFuLmNsaWVudDsK
ICAgIGlmIChvd25lciA9PT0gLTEgfHwgIXJvb20uc2xvdHNbb3duZXJdLm9ubGluZSkgb3duZXIg
PSB0aGlzLmluZGV4OwogICAgY29uc3Qgc2xvdCA9IHJvb20uc2xvdHNbb3duZXJdOwogICAgY29u
c3QgYXZhaWxhYmxlID0gKCkgPT4gewogICAgICBjb25zdCBsaXN0ID0gW107CiAgICAgIGZvciAo
Y29uc3QgbmFtZSBvZiBDSEFSQUNURVJTKSB7CiAgICAgICAgY29uc3QgY2hhcmFjdGVyID0gQ0hB
UkFDVEVSUy5pbmRleE9mKG5hbWUpOwogICAgICAgIGlmIChodW1hbiA/IHNsb3QubGV2ZWxzW2No
YXJhY3Rlcl0gPiAwIDogcm9vbS5vbmxpbmUoKS5zb21lKChvdGhlcikgPT4gb3RoZXIubGV2ZWxz
W2NoYXJhY3Rlcl0gPiAwKSkgbGlzdC5wdXNoKG5hbWUpOwogICAgICB9CiAgICAgIHJldHVybiBs
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
IHsKICAgICAgZm9yIChjb25zdCBvdGhlciBvZiByb29tLm9ubGluZSgpKSBpZiAob3RoZXIubGV2
ZWxzW2NoYXJhY3Rlcl0gPiBtYW4ubGV2ZWwpIG1hbi5sZXZlbCA9IG90aGVyLmxldmVsc1tjaGFy
YWN0ZXJdOwogICAgfQogICAgZm9yIChjb25zdCBvdGhlciBvZiByb29tLm1lbikgaWYgKG90aGVy
LmV4aXN0cyAmJiBvdGhlci5jb21tYW5kZXIgPT09IGluZGV4KSBvdGhlci5sZXZlbCA9IG1hbi5s
ZXZlbDsKICB9CgogIC8vIGkuZyhTdHJpbmcpOiBjaGF0IHRoYXQgc3RhcnRzIHdpdGggIi8iIGlz
IGEgY29tbWFuZC4gUmV0dXJucyB3aGV0aGVyIHRoZSBsaW5lIGdvZXMgdG8gZXZlcnlvbmUuCiAg
Y29tbWFuZCh0ZXh0KSB7CiAgICBpZiAodGV4dCA9PT0gbnVsbCkgcmV0dXJuIHRydWU7CiAgICBj
b25zdCBtZXNzYWdlID0gdGV4dC50cmltKCk7CiAgICBpZiAoIW1lc3NhZ2UgfHwgbWVzc2FnZVsw
XSAhPT0gJy8nKSByZXR1cm4gdHJ1ZTsKICAgIGNvbnN0IHdvcmRzID0gbWVzc2FnZS5zcGxpdCgv
XHMrLyk7CiAgICBjb25zdCBuYW1lID0gd29yZHNbMF0udG9Mb3dlckNhc2UoKTsKICAgIGNvbnN0
IHJvb20gPSB0aGlzLnJvb207CiAgICBpZiAobmFtZSA9PT0gJy9oZWxwJykgewogICAgICBpZiAo
d29yZHMubGVuZ3RoID4gMSkgcmV0dXJuIHRydWU7CiAgICAgIHRoaXMubm90aWNlKCc8Yj5Db21t
YW5kcyBhdmFpbGFibGU8L2I+OiAgL3F1aXQsIC9jbGVhciwgL21lLCAvbGF0LiA8YnIgLz5UeXBl
ID8gYWZ0ZXIgYSBjb21tYW5kIHRvIGxlYXJuIGFib3V0IGl0LiBFLmcuOiAvcXVpdCA/ICcpOwog
ICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChuYW1lID09PSAnL3F1aXQnIHx8IG5hbWUg
PT09ICcvZXhpdCcpIHsKICAgICAgaWYgKHdvcmRzLmxlbmd0aCA+IDEgJiYgd29yZHNbMV0gPT09
ICc/JykgewogICAgICAgIHRoaXMubm90aWNlKCc8Yj5RdWl0PC9iPjogWW91IHdpbGwgZXhpdCB0
aGUgcm9vbS48YnIgLz5JbnB1dHM6IC9xdWl0LCAvZXhpdC4nKTsKICAgICAgICByZXR1cm4gdHJ1
ZTsKICAgICAgfQogICAgICB0aGlzLmtpY2tlZCA9IHRydWU7CiAgICAgIHRoaXMubGVhdmUoKTsK
ICAgICAgdGhpcy5jbG9zZSgpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlmIChuYW1l
ID09PSAnL2NsZWFyJyB8fCBuYW1lID09PSAnL2NsZWFuJykgewogICAgICBpZiAod29yZHMubGVu
Z3RoID4gMSkgewogICAgICAgIGlmICh3b3Jkc1sxXSA9PT0gJz8nKSB0aGlzLm5vdGljZSgnPGI+
Q2xlYXI8L2I+OiBXaWxsIGNsZWFyIGFsbCB0aGUgY2hhdCBvbiB5b3VyIHNjcmVlbi48YnIgLz5J
bnB1dHM6IC9jbGVhciwgL2NsZWFuLicpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgICB9CiAg
ICAgIGZvciAobGV0IGsgPSAwOyBrIDwgNTA7IGsgKz0gMSkgdGhpcy5ub3RpY2UoJzxiciAvPicp
OwogICAgICBmb3IgKGNvbnN0IHNsb3Qgb2Ygcm9vbS5vbmxpbmUoKSkgewogICAgICAgIGlmIChz
bG90LmNvbm5lY3Rpb24gIT09IHRoaXMpIHNsb3QuY29ubmVjdGlvbi5zZW5kKGA8Y2hhdD48Yz4k
e3RoaXMuaW5kZXh9PC9jPjxtPjwhW0NEQVRBWyR7d29yZHNbMF19XV0+PC9tPjwvY2hhdD5gKTsK
ICAgICAgfQogICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgICBpZiAobmFtZSA9PT0gJy9tZScp
IHsKICAgICAgaWYgKHdvcmRzLmxlbmd0aCA+IDEgJiYgd29yZHNbMV0gIT09ICc/JykgewogICAg
ICAgIHRoaXMuYW5ub3VuY2UoYDxmb250IGNvbG9yPSIjQ0NDQ0ZGIj48aT4qPGI+ICR7dGhpcy5u
YW1lfTwvYj4gJHt3b3Jkcy5zbGljZSgxKS5qb2luKCcgJyl9IDwvaT48L2ZvbnQ+YCk7CiAgICAg
ICAgcmV0dXJuIGZhbHNlOwogICAgICB9CiAgICAgIHRoaXMubm90aWNlKCc8Yj5NRTwvYj46IFNl
bmRzIHRoZSBhY3Rpb24gdG8gdGhlIGNoYXQgKGFjdGlvbnMgYXJlIHdyaXR0ZW4gaW4gdGhlIDNy
ZCBwZXJzb24sIGxpa2UgL21lIGp1bXBzKS4nKTsKICAgICAgcmV0dXJuIHRydWU7CiAgICB9CiAg
ICBpZiAobmFtZSA9PT0gJy9sYXQnIHx8IG5hbWUgPT09ICcvbGF0ZW5jeScpIHsKICAgICAgY29u
c3QgaGVscCA9ICdJdCB3aWxsIG5lZWQgYSBsYXRlbmN5IG51bWJlciBiZXR3ZWVuIDEgYW5kIDk5
IGFmdGVyIHRoZSBjb21tYW5kLiBFLmcuOiAvbGF0IDcnOwogICAgICBpZiAod29yZHMubGVuZ3Ro
IDw9IDEpIHRoaXMubm90aWNlKGA8Yj5MYXRlbmN5PC9iPjogJHtoZWxwfWApOwogICAgICBlbHNl
IGlmICh3b3Jkc1sxXSA9PT0gJz8nKSB0aGlzLm5vdGljZShgPGI+TGF0ZW5jeTwvYj46IENoYW5n
ZXMgeW91ciBsYXRlbmN5LiAke2hlbHB9PGJyIC8+SW5wdXRzOiAvbGF0LCAvbGF0ZW5jeS5gKTsK
ICAgICAgZWxzZSBpZiAoIS9eWy0rXT9cZCskLy50ZXN0KHdvcmRzWzFdKSkgdGhpcy5ub3RpY2Uo
YDxiPkxhdGVuY3k8L2I+OiAke2hlbHB9YCk7CiAgICAgIGVsc2UgewogICAgICAgIGNvbnN0IHZh
bHVlID0gTnVtYmVyKHdvcmRzWzFdKTsKICAgICAgICBpZiAodmFsdWUgPD0gMCkgdGhpcy5ub3Rp
Y2UoJzxiPkxhdGVuY3k8L2I+OiBZb3VyIGxhdGVuY3kgbXVzdCBiZSBiZXR3ZWVuIDEgYW5kIDk5
LicpOwogICAgICAgIGVsc2UgaWYgKHZhbHVlID4gOTkpIHRoaXMubm90aWNlKCdSZWFsbHk/Jyk7
CiAgICAgICAgZWxzZSB7CiAgICAgICAgICBjb25zdCBzbG90ID0gdGhpcy5zbG90OwogICAgICAg
ICAgc2xvdC5sYXRlbmN5ID0gdmFsdWUgKyAxOwogICAgICAgICAgc2xvdC5sYXRlbmN5VGFyZ2V0
ID0gc2xvdC5sYXRlbmN5OwogICAgICAgICAgdGhpcy5ub3RpY2UoYDxiPkxhdGVuY3k8L2I+OiBZ
b3VyIGxhdGVuY3kgaGFzIGJlZW4gY2hhbmdlZCB0byAke3Nsb3QubGF0ZW5jeSAtIDF9LmApOwog
ICAgICAgICAgcm9vbS5icm9hZGNhc3RMaXN0KC0xLCAtMSk7CiAgICAgICAgfQogICAgICB9CiAg
ICAgIHJldHVybiB0cnVlOwogICAgfQogICAgdGhpcy5ub3RpY2UoJ1VucmVjb2duaXplZCBjb21t
YW5kLicpOwogICAgcmV0dXJuIHRydWU7CiAgfQp9Cgptb2R1bGUuZXhwb3J0cyA9IHsgSGZSb29t
LCBIZkNvbm5lY3Rpb24sIHBhcnNlWG1sLCBieVRhZywgdmFsdWVPZiwgWG1sRXJyb3IsIFZFUlNJ
T04sIENMSUVOVFMsIENIQVJBQ1RFUlMgfTsK
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
