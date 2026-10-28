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

INSTALLER_VERSION=5
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
IGV2ZXJ5IDMzIG1zIGl0IHNlbmRzIGVhY2ggcGxheWVyIG9uZSBmcmFtZSBob2xkaW5nIHRoZSBu
ZXdlc3QgaW5wdXQgb2YKLy8gZXZlcnkgcGxheWVyLCBzbyBub2JvZHkgd2FpdHMgZm9yIHRoZSBz
bG93ZXN0IGNvbm5lY3Rpb24uCi8vCi8vIFByb3RvY29sIDEsIHR3byBwbGF5ZXJzIChvbGRlciBn
YW1lIHBhZ2VzKTogdGhlIHJlbGF5IHBhaXJzIGhvc3QgYW5kIGd1ZXN0IGFuZCBjb3BpZXMgYmlu
YXJ5IGZyYW1lcwovLyBmcm9tIG9uZSB0byB0aGUgb3RoZXIgdW5jaGFuZ2VkLiBUaGUgZ2FtZSdz
IG93biBsb2Nrc3RlcCBwcm90b2NvbCAoaGFuZHNoYWtlLCByYW5kb20gdGFibGUsIG9uZQovLyAy
Mi1ieXRlIGlucHV0IHBhY2tldCBwZXIgZnJhbWUpIHJ1bnMgb24gdG9wOyB0aGUgcmVsYXkgbmV2
ZXIgcGFyc2VzIG9yIHN0b3JlcyBpdC4KLy8gICB3cyhzKTovLzxzZXJ2ZXI+L3JlbGF5P3JvbGU9
aG9zdCZyb29tPTQ4MjkxMwovLyAgIHdzKHMpOi8vPHNlcnZlcj4vcmVsYXk/cm9sZT1qb2luJnJv
b209NDgyOTEzCi8vIEVpdGhlciBzaWRlIG1heSBhcnJpdmUgZmlyc3QuIFNlcnZlci10by1jbGll
bnQgY29udHJvbCBtZXNzYWdlcyBhcmUgSlNPTiB0ZXh0IGZyYW1lczoKLy8gICB7InQiOiJ3YWl0
aW5nIiwicm9vbSI6IjQ4MjkxMyJ9ICAgcmVnaXN0ZXJlZCwgd2FpdGluZyBmb3IgdGhlIG90aGVy
IHBsYXllcgovLyAgIHsidCI6InBhaXJlZCJ9ICAgICAgICAgICAgICAgICAgICBib3RoIHBsYXll
cnMgYXJlIHByZXNlbnQ7IGJpbmFyeSBmcmFtZXMgbm93IGZsb3cKLy8KLy8gUHJvYmxlbXMgY2xv
c2UgdGhlIHNvY2tldCB3aXRoIGEgNHh4eCBjb2RlIGFuZCBhIHNob3J0IEFTQ0lJIHJlYXNvbiwg
d2hpY2ggdGhlIGdhbWUgc2hvd3MuCi8vCi8vIFdpdGggSU5TVEFMTEVSX0ZJTEUgc2V0IChpbnN0
YWxsLXZwcy5zaCBkb2VzKSwgdGhlIHJlbGF5IGFsc28gc2VydmVzIGl0cyBjb3B5IG9mIHRoZSBv
cmlnaW5hbCBMRjIKLy8gdjIuMGEgaW5zdGFsbGVyIGF0IC9sZjItaW5zdGFsbGVyLmRhdGEsIHdo
aWNoIHRoZSBnYW1lIHBhZ2UgZG93bmxvYWRzIGJlZm9yZSB0cnlpbmcgYXJjaGl2ZS5vcmc6Ci8v
IGRvd25sb2FkIG1hbmFnZXJzIHN1Y2ggYXMgSURNIGxldCB0aGF0IG5hbWUgdGhyb3VnaCwgd2hp
bGUgdGhleSB0YWtlIG92ZXIgdGhlIC5leGUgZnJvbSBhcmNoaXZlLm9yZy4KLy8gV2l0aCBQQUNL
U19ESVIgc2V0LCBpdCBhbHNvIGtlZXBzIGdhbWUgcGFja3MgKG1vZHMgcGxheWVkIGluc3RlYWQg
b2YgdGhlIG9yaWdpbmFsIGdhbWUsIHNlZQovLyBwYWNrcy5qcyksIHdoaWNoIHdob2V2ZXIgaG9s
ZHMgQURNSU5fS0VZIHVwbG9hZHMgYXQgL2FkbWluLgondXNlIHN0cmljdCc7Cgpjb25zdCBmcyA9
IHJlcXVpcmUoJ25vZGU6ZnMnKTsKY29uc3QgaHR0cCA9IHJlcXVpcmUoJ25vZGU6aHR0cCcpOwpj
b25zdCB7IFdlYlNvY2tldFNlcnZlciwgV2ViU29ja2V0IH0gPSByZXF1aXJlKCd3cycpOwpjb25z
dCB7IGNyZWF0ZVBhY2tzIH0gPSByZXF1aXJlKCcuL3BhY2tzLmpzJyk7Cgpjb25zdCBJTlNUQUxM
RVJfUEFUSCA9ICcvbGYyLWluc3RhbGxlci5kYXRhJzsKCmNvbnN0IFJPT01fUEFUVEVSTiA9IC9e
XGR7NCwxMn0kLzsKCi8vIENsb3NlIGNvZGVzIGFyZSBwYXJ0IG9mIHRoZSBjb250cmFjdCB3aXRo
IG9ubGluZS5qcyAoaXQgbWFwcyB0aGVtIHRvIG1lc3NhZ2VzIHRvbykuCmNvbnN0IENMT1NFID0g
T2JqZWN0LmZyZWV6ZSh7CiAgYmFkUmVxdWVzdDogWzQwMDAsICdSZWxheTogYmFkIHJlcXVlc3Qn
XSwKICBvcmlnaW5EZW5pZWQ6IFs0MDAxLCAnUmVsYXk6IHRoaXMgd2Vic2l0ZSBtYXkgbm90IHVz
ZSB0aGUgcmVsYXknXSwKICB0b29NYW55Q29ubmVjdGlvbnM6IFs0MDAyLCAnUmVsYXk6IHRvbyBt
YW55IGNvbm5lY3Rpb25zIGZyb20geW91ciBuZXR3b3JrJ10sCiAgc2VydmVyRnVsbDogWzQwMDMs
ICdSZWxheTogc2VydmVyIGlzIGZ1bGwnXSwKICBob3N0VGFrZW46IFs0MDA0LCAnUmVsYXk6IHJv
b20gYWxyZWFkeSBoYXMgYSBob3N0J10sCiAgZ3Vlc3RUYWtlbjogWzQwMDQsICdSZWxheTogcm9v
bSBhbHJlYWR5IGhhcyBhIGd1ZXN0J10sCiAgdGltZW91dDogWzQwMDUsICdSZWxheTogbm9ib2R5
IGpvaW5lZCBpbiB0aW1lJ10sCiAgcGVlckxlZnQ6IFs0MDA2LCAnUmVsYXk6IHRoZSBvdGhlciBw
bGF5ZXIgbGVmdCddLAogIHJhdGVMaW1pdGVkOiBbNDAwNywgJ1JlbGF5OiB0b28gbXVjaCB0cmFm
ZmljJ10sCiAgc2xvd1BlZXI6IFs0MDA4LCAnUmVsYXk6IHRoZSBvdGhlciBwbGF5ZXIgc3RvcHBl
ZCByZWFkaW5nJ10sCiAgZWFybHlEYXRhOiBbNDAwOSwgJ1JlbGF5OiBkYXRhIHNlbnQgYmVmb3Jl
IHBhaXJpbmcnXSwKICAvLyBQcm90b2NvbCAyIHJvb21zLgogIHJvb21GdWxsOiBbNDAxMCwgJ1Jl
bGF5OiB0aGUgcm9vbSBpcyBmdWxsJ10sCiAgc3RhcnRlZDogWzQwMTEsICdSZWxheTogdGhlIGdh
bWUgaW4gdGhpcyByb29tIGhhcyBhbHJlYWR5IHN0YXJ0ZWQnXSwKICBtaXNtYXRjaDogWzQwMTIs
ICdSZWxheTogdGhpcyByb29tIHBsYXlzIGFub3RoZXIgZ2FtZSB2ZXJzaW9uIG9yIG1vZCddLAog
IGhvc3RMZWZ0OiBbNDAxMywgJ1JlbGF5OiB0aGUgaG9zdCBsZWZ0IHRoZSByb29tJ10sCiAgbm90
U3RhcnRlZDogWzQwMTQsICdSZWxheTogdGhlIGhvc3QgZGlkIG5vdCBzdGFydCB0aGUgZ2FtZSBp
biB0aW1lJ10sCiAgcHJvdG9jb2w6IFs0MDE1LCAnUmVsYXk6IHVuZXhwZWN0ZWQgbWVzc2FnZSBm
cm9tIHRoZSBnYW1lJ10sCiAgc2xvd0NsaWVudDogWzQwMTYsICdSZWxheTogeW91ciBjb25uZWN0
aW9uIGlzIHRvbyBzbG93IGZvciB0aGUgZ2FtZSddLAogIGNvZGVJblVzZTogWzQwMTcsICdSZWxh
eTogdGhpcyByb29tIGNvZGUgaXMgaW4gdXNlIGJ5IGFuIG9sZGVyIGdhbWUgcGFnZSddLAogIG5l
d2VyUm9vbTogWzQwMTcsICdSZWxheTogdGhpcyByb29tIGlzIGZvciBhIG5ld2VyIGdhbWUgcGFn
ZSAocmVsb2FkIHRoZSBwYWdlKSddLAogIHNodXRkb3duOiBbMTAwMSwgJ1JlbGF5OiBzZXJ2ZXIg
aXMgcmVzdGFydGluZyddLAp9KTsKCi8vIFByb3RvY29sIDIgbWVzc2FnZSBraW5kcyAoc2VlICJS
b29tcyIgYmVsb3cpLgpjb25zdCBLSU5EID0gT2JqZWN0LmZyZWV6ZSh7CiAgaGVsbG86IDB4MDEs
IHN0YXJ0OiAweDAyLCBpbnB1dDogMHgwMywgcmVhZHk6IDB4MDQsIGNoZWNrOiAweDA1LAogIHdl
bGNvbWU6IDB4ODEsIGxvYmJ5OiAweDgyLCBzdGFydGVkOiAweDgzLCBmcmFtZTogMHg4NCwgY2hl
Y2tlZDogMHg4NSwgbGVmdDogMHg4NiwKfSk7CmNvbnN0IFJPT01fTElNSVRTID0gT2JqZWN0LmZy
ZWV6ZSh7IHBsYXllcnM6IDgsIHByb2ZpbGU6IDIwMCwgaW5mbzogNjQsIGlucHV0OiAxNiwgc2V0
dXA6IDgxOTIsIHF1ZXVlOiA2NCB9KTsKCmZ1bmN0aW9uIHJlYWRDb25maWcoZW52ID0gcHJvY2Vz
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
TElNSVRTLnBsYXllcnMpKSksCiAgICB0aWNrTXM6IE1hdGgubWF4KDEsIG51bWJlcignVElDS19N
UycsIDMzKSksCiAgICBsb2JieVdhaXRNczogbnVtYmVyKCdMT0JCWV9XQUlUX01TJywgMTgwMDAw
MCksCiAgICBzdGFydEdyYWNlTXM6IG51bWJlcignU1RBUlRfR1JBQ0VfTVMnLCA1MDAwKSwKICAg
IHJlcGVhdExpbWl0OiBudW1iZXIoJ1JFUEVBVF9MSU1JVCcsIDE1KSwKICAgIC8vIFRoZSBMRjIg
aW5zdGFsbGVyIHNlcnZlZCBhdCAvbGYyLWluc3RhbGxlci5kYXRhIChlbXB0eTogbm90IHNlcnZl
ZCksIGFuZCBob3cgb2Z0ZW4gb25lIGNsaWVudAogICAgLy8gYWRkcmVzcyBtYXkgZG93bmxvYWQg
aXQgKGFib3V0IDMwIE1CIGVhY2ggdGltZTsgYnJvd3NlcnMga2VlcCBpdCBhZnRlciB0aGUgZmly
c3QgdGltZSkuCiAgICBpbnN0YWxsZXJGaWxlOiBlbnYuSU5TVEFMTEVSX0ZJTEUgfHwgJycsCiAg
ICBpbnN0YWxsZXJEb3dubG9hZHNQZXJIb3VyOiBudW1iZXIoJ0lOU1RBTExFUl9ET1dOTE9BRFNf
UEVSX0hPVVInLCAyMCksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIC8vIEdhbWUgcGFja3MgKHBhY2tz
LmpzKTogd2hlcmUgdGhleSBhcmUga2VwdCAoZW1wdHk6IG5vbmUpLCB0aGUga2V5IGZvciB1cGxv
YWRpbmcgdGhlbSBhdCAvYWRtaW4KICAgIC8vIChlbXB0eTogbm8gdXBsb2FkcyksIHRoZWlyIGxh
cmdlc3Qgc2l6ZSwgYW5kIGhvdyBvZnRlbiBvbmUgY2xpZW50IGFkZHJlc3MgbWF5IGRvd25sb2Fk
IG9uZS4KICAgIHBhY2tzRGlyOiBlbnYuUEFDS1NfRElSIHx8ICcnLAogICAgYWRtaW5LZXk6IGVu
di5BRE1JTl9LRVkgfHwgJycsCiAgICBtYXhQYWNrQnl0ZXM6IG51bWJlcignTUFYX1BBQ0tfQllU
RVMnLCAxMDI0ICogMTAyNCAqIDEwMjQpLAogICAgcGFja0Rvd25sb2Fkc1BlckhvdXI6IG51bWJl
cignUEFDS19ET1dOTE9BRFNfUEVSX0hPVVInLCAyMCksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIHF1
aWV0OiBlbnYuUVVJRVQgPT09ICcxJyB8fCBlbnYuUVVJRVQgPT09ICd0cnVlJywKICB9Owp9Cgpm
dW5jdGlvbiBub3JtYWxpemVPcmlnaW4odmFsdWUpIHsKICByZXR1cm4gU3RyaW5nKHZhbHVlIHx8
ICcnKS50cmltKCkucmVwbGFjZSgvXC8rJC8sICcnKS50b0xvd2VyQ2FzZSgpOwp9CgovLyBUb2tl
biBidWNrZXQ6IGByYXRlYCB1bml0cyBwZXIgc2Vjb25kLCBidXJzdHMgdXAgdG8gYGNhcGFjaXR5
YC4gQSByYXRlIG9mIDAgZGlzYWJsZXMgdGhlIGxpbWl0LgpjbGFzcyBCdWNrZXQgewogIGNvbnN0
cnVjdG9yKHJhdGUsIGNhcGFjaXR5KSB7CiAgICB0aGlzLnJhdGUgPSByYXRlOwogICAgdGhpcy5j
YXBhY2l0eSA9IE1hdGgubWF4KGNhcGFjaXR5LCByYXRlKTsKICAgIHRoaXMudG9rZW5zID0gdGhp
cy5jYXBhY2l0eTsKICAgIHRoaXMubGFzdCA9IERhdGUubm93KCk7CiAgfQogIHRha2UoYW1vdW50
KSB7CiAgICBpZiAodGhpcy5yYXRlID09PSAwKSByZXR1cm4gdHJ1ZTsKICAgIGNvbnN0IG5vdyA9
IERhdGUubm93KCk7CiAgICB0aGlzLnRva2VucyA9IE1hdGgubWluKHRoaXMuY2FwYWNpdHksIHRo
aXMudG9rZW5zICsgKChub3cgLSB0aGlzLmxhc3QpICogdGhpcy5yYXRlKSAvIDEwMDApOwogICAg
dGhpcy5sYXN0ID0gbm93OwogICAgaWYgKHRoaXMudG9rZW5zIDwgYW1vdW50KSByZXR1cm4gZmFs
c2U7CiAgICB0aGlzLnRva2VucyAtPSBhbW91bnQ7CiAgICByZXR1cm4gdHJ1ZTsKICB9Cn0KCmZ1
bmN0aW9uIGNyZWF0ZVJlbGF5KG92ZXJyaWRlcyA9IHt9KSB7CiAgY29uc3QgY29uZmlnID0geyAu
Li5yZWFkQ29uZmlnKHt9KSwgLi4ub3ZlcnJpZGVzIH07CiAgY29uc3Qgcm9vbXMgPSBuZXcgTWFw
KCk7IC8vIHByb3RvY29sIDE6IGNvZGUgLT4geyBjb2RlLCBob3N0LCBqb2luLCB0aW1lciB9CiAg
Y29uc3QgZ3JvdXBzID0gbmV3IE1hcCgpOyAvLyBwcm90b2NvbCAyOiBjb2RlIC0+IHJvb20gKHNl
ZSAiUm9vbXMiIGJlbG93KQogIGNvbnN0IGNvbm5lY3Rpb25zUGVySXAgPSBuZXcgTWFwKCk7CiAg
Y29uc3QgbG9nID0gKC4uLnBhcnRzKSA9PiB7IGlmICghY29uZmlnLnF1aWV0KSBjb25zb2xlLmxv
ZyhuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCksIC4uLnBhcnRzKTsgfTsKCiAgY29uc3QgaW5zdGFs
bGVyRG93bmxvYWRzID0gbmV3IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVzcyAtPiB7IGNvdW50LCB1
bnRpbCB9CiAgY29uc3QgaW5zdGFsbGVyUGF0aHMgPSBuZXcgU2V0KFtJTlNUQUxMRVJfUEFUSCwg
Y29uZmlnLnBhdGgucmVwbGFjZSgvW14vXSokLywgSU5TVEFMTEVSX1BBVEguc2xpY2UoMSkpXSk7
CiAgLy8gQmVzaWRlIHRoZSBXZWJTb2NrZXQgcGF0aCwgYXMgdGhlIGluc3RhbGxlciBjb3B5OiAv
eC9yZWxheSAtPiAveC9sZjItcGFja3MuanNvbiBhbmQgL3gvYWRtaW4uCiAgY29uc3QgcmVsYXlG
b2xkZXIgPSBjb25maWcucGF0aC5yZXBsYWNlKC9bXi9dKiQvLCAnJyk7CiAgY29uc3QgcGFja3Mg
PSBjcmVhdGVQYWNrcyhjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzOiAocmVxKSA9PiBjbGll
bnRBZGRyZXNzKHJlcSksIGFsbG93T3JpZ2luOiAocmVxKSA9PiBhbGxvd09yaWdpbihyZXEpIH0p
OwoKICBjb25zdCBzZXJ2ZXIgPSBodHRwLmNyZWF0ZVNlcnZlcigocmVxLCByZXMpID0+IHsKICAg
IGNvbnN0IHsgcGF0aG5hbWUgfSA9IG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9yZWxheS5pbnZh
bGlkJyk7CiAgICBpZiAocGF0aG5hbWUgPT09ICcvaGVhbHRoeicpIHsKICAgICAgLy8gUmVhZGFi
bGUgZnJvbSB0aGUgZ2FtZSBwYWdlIChhbm90aGVyIG9yaWdpbikgc28gaXRzIE9ubGluZSBwYW5l
bCBjYW4gc2hvdyAicmVsYXkgT0siLgogICAgICByZXMud3JpdGVIZWFkKDIwMCwgewogICAgICAg
ICdjb250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vanNvbicsCiAgICAgICAgJ2NhY2hlLWNvbnRy
b2wnOiAnbm8tc3RvcmUnLAogICAgICAgICdhY2Nlc3MtY29udHJvbC1hbGxvdy1vcmlnaW4nOiAn
KicsCiAgICAgIH0pOwogICAgICByZXMuZW5kKEpTT04uc3RyaW5naWZ5KHsKICAgICAgICBvazog
dHJ1ZSwgcm9vbXM6IHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSwgY2xpZW50czogd3NzLmNsaWVu
dHMuc2l6ZSwgaW5zdGFsbGVyOiBpbnN0YWxsZXJTaXplKCkgPiAwLAogICAgICAgIHByb3RvY29s
czogWzEsIDJdLCBwbGF5ZXJzOiBjb25maWcucm9vbVBsYXllcnMsIHBhY2tzOiBCb29sZWFuKGNv
bmZpZy5wYWNrc0RpciksCiAgICAgIH0pKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKGlu
c3RhbGxlclBhdGhzLmhhcyhwYXRobmFtZSkpIHsKICAgICAgc2VydmVJbnN0YWxsZXIocmVxLCBy
ZXMpOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBsb2NhbCA9IHJlbGF5Rm9sZGVyICE9
PSAnLycgJiYgcGF0aG5hbWUuc3RhcnRzV2l0aChyZWxheUZvbGRlcikgPyBwYXRobmFtZS5zbGlj
ZShyZWxheUZvbGRlci5sZW5ndGggLSAxKSA6IHBhdGhuYW1lOwogICAgaWYgKHBhY2tzLmhhbmRs
ZShyZXEsIHJlcywgbG9jYWwpKSByZXR1cm47CiAgICBpZiAocGF0aG5hbWUgPT09ICcvJyB8fCBw
YXRobmFtZSA9PT0gY29uZmlnLnBhdGgpIHsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ2Nv
bnRlbnQtdHlwZSc6ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JyB9KTsKICAgICAgcmVzLmVu
ZChgT3BlbkxGMiByZWxheSBpcyBydW5uaW5nLiBDb25uZWN0IHdpdGggYSBXZWJTb2NrZXQgdG8g
JHtjb25maWcucGF0aH1cbmApOwogICAgICByZXR1cm47CiAgICB9CiAgICByZXMud3JpdGVIZWFk
KDQwNCwgeyAnY29udGVudC10eXBlJzogJ3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnIH0pOwog
ICAgcmVzLmVuZCgnTm90IGZvdW5kXG4nKTsKICB9KTsKCiAgLy8gVXBsb2FkaW5nIGEgZ2FtZSBw
YWNrIGZyb20gYSBzbG93IGxpbmUgbWF5IHRha2UgYSB3aGlsZSAoTm9kZSdzIGRlZmF1bHQgZ2l2
ZXMgdXAgYWZ0ZXIgNSBtaW51dGVzKS4KICBzZXJ2ZXIucmVxdWVzdFRpbWVvdXQgPSAyICogMzYw
MCAqIDEwMDA7CgogIGNvbnN0IHdzcyA9IG5ldyBXZWJTb2NrZXRTZXJ2ZXIoewogICAgbm9TZXJ2
ZXI6IHRydWUsCiAgICBtYXhQYXlsb2FkOiBjb25maWcubWF4TWVzc2FnZUJ5dGVzLAogICAgcGVy
TWVzc2FnZURlZmxhdGU6IGZhbHNlLCAvLyAyMi1ieXRlIHBhY2tldHM6IGNvbXByZXNzaW9uIG9u
bHkgYWRkcyBsYXRlbmN5CiAgfSk7CgogIHNlcnZlci5vbigndXBncmFkZScsIChyZXEsIHNvY2tl
dCwgaGVhZCkgPT4gewogICAgY29uc3QgdXJsID0gbmV3IFVSTChyZXEudXJsLCAnaHR0cDovL3Jl
bGF5LmludmFsaWQnKTsKICAgIGlmICh1cmwucGF0aG5hbWUgIT09IGNvbmZpZy5wYXRoICYmIHVy
bC5wYXRobmFtZSAhPT0gJy8nKSB7CiAgICAgIHNvY2tldC5lbmQoJ0hUVFAvMS4xIDQwNCBOb3Qg
Rm91bmRcclxuQ29ubmVjdGlvbjogY2xvc2VcclxuXHJcbicpOwogICAgICByZXR1cm47CiAgICB9
CiAgICAvLyBSZXF1ZXN0cyBhcmUgdmFsaWRhdGVkIGFmdGVyIHRoZSB1cGdyYWRlLCBzbyB0aGUg
YnJvd3NlciByZWNlaXZlcyBhIGNsb3NlIGNvZGUgYW5kIHJlYXNvbgogICAgLy8gaW5zdGVhZCBv
ZiBhbiBhbm9ueW1vdXMgY29ubmVjdGlvbiBlcnJvci4KICAgIHdzcy5oYW5kbGVVcGdyYWRlKHJl
cSwgc29ja2V0LCBoZWFkLCAod3MpID0+IHdzcy5lbWl0KCdjb25uZWN0aW9uJywgd3MsIHJlcSwg
dXJsKSk7CiAgfSk7CgogIHdzcy5vbignY29ubmVjdGlvbicsICh3cywgcmVxLCB1cmwpID0+IHsK
ICAgIHdzLmlzQWxpdmUgPSB0cnVlOwogICAgd3Mub24oJ3BvbmcnLCAoKSA9PiB7IHdzLmlzQWxp
dmUgPSB0cnVlOyB9KTsKICAgIHdzLm9uKCdlcnJvcicsICgpID0+IHt9KTsgLy8gYSAnY2xvc2Un
IGV2ZW50IGFsd2F5cyBmb2xsb3dzCgogICAgaWYgKGNvbmZpZy5hbGxvd2VkT3JpZ2lucy5sZW5n
dGggJiYgIWNvbmZpZy5hbGxvd2VkT3JpZ2lucy5pbmNsdWRlcyhub3JtYWxpemVPcmlnaW4ocmVx
LmhlYWRlcnMub3JpZ2luKSkpIHsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0Uub3Jp
Z2luRGVuaWVkKTsKICAgIH0KICAgIGNvbnN0IHJvbGUgPSB1cmwuc2VhcmNoUGFyYW1zLmdldCgn
cm9sZScpOwogICAgY29uc3QgY29kZSA9IHVybC5zZWFyY2hQYXJhbXMuZ2V0KCdyb29tJykgfHwg
Jyc7CiAgICBpZiAoKHJvbGUgIT09ICdob3N0JyAmJiByb2xlICE9PSAnam9pbicpIHx8ICFST09N
X1BBVFRFUk4udGVzdChjb2RlKSkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5i
YWRSZXF1ZXN0KTsKICAgIH0KCiAgICBjb25zdCBhZGRyZXNzID0gY2xpZW50QWRkcmVzcyhyZXEp
OwogICAgY29uc3QgY291bnQgPSBjb25uZWN0aW9uc1BlcklwLmdldChhZGRyZXNzKSB8fCAwOwog
ICAgaWYgKGNvbmZpZy5tYXhDb25uZWN0aW9uc1BlcklwICYmIGNvdW50ID49IGNvbmZpZy5tYXhD
b25uZWN0aW9uc1BlcklwKSB7CiAgICAgIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnRvb01h
bnlDb25uZWN0aW9ucyk7CiAgICB9CiAgICBjb25uZWN0aW9uc1BlcklwLnNldChhZGRyZXNzLCBj
b3VudCArIDEpOwogICAgd3Mub25jZSgnY2xvc2UnLCAoKSA9PiB7CiAgICAgIGNvbnN0IGxlZnQg
PSAoY29ubmVjdGlvbnNQZXJJcC5nZXQoYWRkcmVzcykgfHwgMSkgLSAxOwogICAgICBpZiAobGVm
dCA+IDApIGNvbm5lY3Rpb25zUGVySXAuc2V0KGFkZHJlc3MsIGxlZnQpOwogICAgICBlbHNlIGNv
bm5lY3Rpb25zUGVySXAuZGVsZXRlKGFkZHJlc3MpOwogICAgfSk7CiAgICB3cy5tZXNzYWdlQnVk
Z2V0ID0gbmV3IEJ1Y2tldChjb25maWcubWVzc2FnZXNQZXJTZWNvbmQsIGNvbmZpZy5tZXNzYWdl
c1BlclNlY29uZCAqIDIpOwogICAgd3MuYnl0ZUJ1ZGdldCA9IG5ldyBCdWNrZXQoY29uZmlnLmJ5
dGVzUGVyU2Vjb25kLCBNYXRoLm1heChjb25maWcuYnl0ZXNQZXJTZWNvbmQsIGNvbmZpZy5tYXhN
ZXNzYWdlQnl0ZXMpICogMik7CgogICAgY29uc3QgdmVyc2lvbiA9IHVybC5zZWFyY2hQYXJhbXMu
Z2V0KCd2Jyk7CiAgICBpZiAodmVyc2lvbiA9PT0gJzInKSByZXR1cm4gam9pbkdyb3VwKHdzLCBy
b2xlLCBjb2RlKTsKICAgIGlmICh2ZXJzaW9uICE9PSBudWxsICYmIHZlcnNpb24gIT09ICcxJykg
cmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuYmFkUmVxdWVzdCk7CiAgICBpZiAoZ3JvdXBzLmhh
cyhjb2RlKSkgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UubmV3ZXJSb29tKTsKCiAgICBsZXQg
cm9vbSA9IHJvb21zLmdldChjb2RlKTsKICAgIGlmICghcm9vbSkgewogICAgICBpZiAoY29uZmln
Lm1heFJvb21zICYmIHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSA+PSBjb25maWcubWF4Um9vbXMp
IHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnNlcnZlckZ1bGwpOwogICAgICByb29tID0geyBj
b2RlLCBob3N0OiBudWxsLCBqb2luOiBudWxsLCB0aW1lcjogbnVsbCB9OwogICAgICByb29tcy5z
ZXQoY29kZSwgcm9vbSk7CiAgICB9CiAgICBpZiAocm9vbVtyb2xlXSkgcmV0dXJuIGNsb3NlV2l0
aCh3cywgcm9sZSA9PT0gJ2hvc3QnID8gQ0xPU0UuaG9zdFRha2VuIDogQ0xPU0UuZ3Vlc3RUYWtl
bik7CgogICAgcm9vbVtyb2xlXSA9IHdzOwogICAgd3Mucm9vbSA9IHJvb207CiAgICB3cy5yb2xl
ID0gcm9sZTsKICAgIHdzLnBlZXIgPSBudWxsOwogICAgd3Mub24oJ21lc3NhZ2UnLCAoZGF0YSwg
aXNCaW5hcnkpID0+IG9uTWVzc2FnZSh3cywgZGF0YSwgaXNCaW5hcnkpKTsKICAgIHdzLm9uKCdj
bG9zZScsICgpID0+IG9uQ2xvc2Uod3MpKTsKCiAgICBjb25zdCBvdGhlciA9IHJvb21bcm9sZSA9
PT0gJ2hvc3QnID8gJ2pvaW4nIDogJ2hvc3QnXTsKICAgIGlmIChvdGhlcikgewogICAgICBjbGVh
clRpbWVvdXQocm9vbS50aW1lcik7CiAgICAgIHJvb20udGltZXIgPSBudWxsOwogICAgICB3cy5w
ZWVyID0gb3RoZXI7CiAgICAgIG90aGVyLnBlZXIgPSB3czsKICAgICAgLy8gQm90aCBwZWVycyBh
cmUgbGlua2VkIGJlZm9yZSBlaXRoZXIgbGVhcm5zIGFib3V0IGl0LCBzbyBhbnkgZGF0YSB0aGF0
IGZvbGxvd3MgaGFzIGEgZGVzdGluYXRpb24uCiAgICAgIHNlbmRDb250cm9sKG90aGVyLCB7IHQ6
ICdwYWlyZWQnIH0pOwogICAgICBzZW5kQ29udHJvbCh3cywgeyB0OiAncGFpcmVkJyB9KTsKICAg
ICAgbG9nKGByb29tICR7Y29kZX06IHBhaXJlZGApOwogICAgfSBlbHNlIHsKICAgICAgc2VuZENv
bnRyb2wod3MsIHsgdDogJ3dhaXRpbmcnLCByb29tOiBjb2RlIH0pOwogICAgICByb29tLnRpbWVy
ID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgaWYgKHJvb21bcm9sZV0gPT09IHdzICYmICF3
cy5wZWVyKSBjbG9zZVdpdGgod3MsIENMT1NFLnRpbWVvdXQpOwogICAgICB9LCBjb25maWcucm9v
bVdhaXRNcyk7CiAgICAgIGxvZyhgcm9vbSAke2NvZGV9OiAke3JvbGV9IHdhaXRpbmdgKTsKICAg
IH0KICB9KTsKCiAgZnVuY3Rpb24gb25NZXNzYWdlKHdzLCBkYXRhLCBpc0JpbmFyeSkgewogICAg
aWYgKCFpc0JpbmFyeSkgcmV0dXJuOyAvLyBvbmx5IHRoZSByZWxheSBzcGVha3MgdGV4dDsgY2xp
ZW50cyBzZW5kIGdhbWUgYnl0ZXMgYXMgYmluYXJ5IGZyYW1lcwogICAgaWYgKCF3cy5wZWVyKSBy
ZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5lYXJseURhdGEpOwogICAgaWYgKCF3cy5tZXNzYWdl
QnVkZ2V0LnRha2UoMSkgfHwgIXdzLmJ5dGVCdWRnZXQudGFrZShkYXRhLmxlbmd0aCkpIHsKICAg
ICAgbG9nKGByb29tICR7d3Mucm9vbS5jb2RlfTogcmF0ZSBsaW1pdGApOwogICAgICBjbG9zZVdp
dGgod3MucGVlciwgQ0xPU0UucmF0ZUxpbWl0ZWQpOwogICAgICByZXR1cm4gY2xvc2VXaXRoKHdz
LCBDTE9TRS5yYXRlTGltaXRlZCk7CiAgICB9CiAgICBjb25zdCBwZWVyID0gd3MucGVlcjsKICAg
IGlmIChwZWVyLnJlYWR5U3RhdGUgIT09IFdlYlNvY2tldC5PUEVOKSByZXR1cm47CiAgICBpZiAo
cGVlci5idWZmZXJlZEFtb3VudCA+IGNvbmZpZy5tYXhCdWZmZXJlZEJ5dGVzKSB7CiAgICAgIGNs
b3NlV2l0aCh3cywgQ0xPU0Uuc2xvd1BlZXIpOwogICAgICByZXR1cm4gY2xvc2VXaXRoKHBlZXIs
IENMT1NFLnNsb3dQZWVyKTsKICAgIH0KICAgIGlmIChjb25maWcuZm9yd2FyZERlbGF5TXMgPiAw
KSB7CiAgICAgIC8vIFRpbWVycyB3aXRoIHRoZSBzYW1lIGRlbGF5IGZpcmUgaW4gdGhlIG9yZGVy
IHRoZXkgd2VyZSBzZXQsIHNvIHRoZSBzdHJlYW0gc3RheXMgaW4gb3JkZXIuCiAgICAgIHNldFRp
bWVvdXQoKCkgPT4geyBpZiAocGVlci5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQuT1BFTikgcGVl
ci5zZW5kKGRhdGEsIHsgYmluYXJ5OiB0cnVlIH0pOyB9LCBjb25maWcuZm9yd2FyZERlbGF5TXMp
OwogICAgICByZXR1cm47CiAgICB9CiAgICBwZWVyLnNlbmQoZGF0YSwgeyBiaW5hcnk6IHRydWUg
fSk7CiAgfQoKICBmdW5jdGlvbiBvbkNsb3NlKHdzKSB7CiAgICBjb25zdCByb29tID0gd3Mucm9v
bTsKICAgIGlmICghcm9vbSkgcmV0dXJuOwogICAgaWYgKHJvb21bd3Mucm9sZV0gPT09IHdzKSBy
b29tW3dzLnJvbGVdID0gbnVsbDsKICAgIGNvbnN0IHBlZXIgPSB3cy5wZWVyOwogICAgd3MucGVl
ciA9IG51bGw7CiAgICBpZiAocGVlcikgewogICAgICAvLyBBIGxvY2tzdGVwIG1hdGNoIGNhbm5v
dCBjb250aW51ZSB3aXRoIG9uZSBwbGF5ZXIsIHNvIHRoZSByb29tIGVuZHMgd2l0aCB0aGUgcGFp
ciBhbmQgaXRzCiAgICAgIC8vIGNvZGUgaXMgZnJlZSBhZ2FpbiBhdCBvbmNlICh0aGUgaG9zdCBj
YW4gcHJlc3MgSG9zdCBhZ2FpbiB3aXRoIHRoZSBzYW1lIGNvZGUpLgogICAgICBwZWVyLnBlZXIg
PSBudWxsOwogICAgICByb29tLmhvc3QgPSByb29tLmpvaW4gPSBudWxsOwogICAgICBjbG9zZVdp
dGgocGVlciwgQ0xPU0UucGVlckxlZnQpOwogICAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBl
bmRlZGApOwogICAgfQogICAgaWYgKCFyb29tLmhvc3QgJiYgIXJvb20uam9pbikgewogICAgICBj
bGVhclRpbWVvdXQocm9vbS50aW1lcik7CiAgICAgIGlmIChyb29tcy5nZXQocm9vbS5jb2RlKSA9
PT0gcm9vbSkgcm9vbXMuZGVsZXRlKHJvb20uY29kZSk7CiAgICB9CiAgfQoKICAvLyAtLS0tIFJv
b21zIChwcm90b2NvbCAyKSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIC8vCiAgLy8gVXAgdG8gY29uZmlnLnJv
b21QbGF5ZXJzIGdhbWVzIHNoYXJlIGEgcm9vbS4gRWFjaCBzYXlzIEhFTExPIHdpdGggaXRzIHBy
b2ZpbGUgKGVuZ2luZSwgc2NyaXB0cywKICAvLyBtb2RzIGFuZCBnYW1lIGRhdGE6IHRoZSBmaXJz
dCBIRUxMTyBzZXRzIHRoZSByb29tJ3MsIGFuZCBhIGdhbWUgd2l0aCBhbm90aGVyIG9uZSBpcyB0
dXJuZWQgYXdheSkKICAvLyBhbmQgaXRzIHBsYXllciBuYW1lczsgTE9CQlkgbGlzdHMgdGhlIHBs
YXllcnMgdG8gZXZlcnlvbmUuIFRoZSBob3N0IHNlbmRzIFNUQVJUIHdpdGggdGhlIHNldHVwCiAg
Ly8gZXZlcnkgZ2FtZSBuZWVkcyAodGhlIHJhbmRvbSB0YWJsZSk7IFNUQVJURUQgZ2l2ZXMgZXZl
cnkgZ2FtZSB0aGUgZmluYWwgbGlzdCBvZiBwbGF5ZXJzLCB3aG9zZQogIC8vIHBvc2l0aW9uIGlz
IHRoZSBwbGF5ZXIncyBpbmRleCwgYW5kIG9uY2UgZXZlcnkgZ2FtZSBpcyBSRUFEWSAob3IgYWZ0
ZXIgc3RhcnRHcmFjZU1zKSB0aGUgYmVhdAogIC8vIGJlZ2luczogZXZlcnkgdGlja01zLCBGUkFN
RSB3aXRoIHRoZSBpbnB1dCBvZiBlYWNoIHBsYXllci4gVGhlIGlucHV0cyBhIHBsYXllciBzZW50
IHNpbmNlIHRoZQogIC8vIGxhc3QgYmVhdCBhcmUgbWVyZ2VkIChPUjogYSBrZXkgaGVsZCBpbiBh
bnkgb2YgdGhlbSBpcyBoZWxkLCBzbyBhIHF1aWNrIHRhcCBpcyBuZXZlciBsb3N0KSwgYW5kCiAg
Ly8gdGhlIG5ld2VzdCBvZiB0aGVtIHN0YXlzIGhpcyBpbnB1dCBvbiB0aGUgZm9sbG93aW5nIGJl
YXRzIHdoaWxlIG5vIG5ld3MgY29tZXMsIHdpdGhvdXQgaXRzCiAgLy8gb25lLXNob3QgZXZlbnRz
IChieXRlIDApOyBhZnRlciByZXBlYXRMaW1pdCBiZWF0cyB3aXRob3V0IG5ld3MgdGhlIHBsYXll
ciBjb3VudHMgYXMgaGF2aW5nCiAgLy8gcmVsZWFzZWQgZXZlcnkga2V5LiBHYW1lcyBzZW5kIHRo
ZWlyIGlucHV0IGFzIHNvb24gYXMgaXQgY2hhbmdlcy4gRXZlcnkgZ2FtZSBydW5zIGV4YWN0bHkg
dGhlCiAgLy8gZnJhbWVzIGl0IHJlY2VpdmVzLCBpbiBvcmRlciwgc28gYWxsIHN0YXkgaW4gc3Rl
cCB3aGF0ZXZlciB0aGVpciBvd24gY29ubmVjdGlvbiBkb2VzOiBhIGRpc3RhbnQKICAvLyBwbGF5
ZXIncyBrZXlzIHRha2UgZWZmZWN0IGEgbGl0dGxlIGxhdGVyIGFuZCBoZSBzZWVzIHRoZSBnYW1l
IGEgbGl0dGxlIGxhdGVyLCBidXQgbm9ib2R5IHdhaXRzCiAgLy8gZm9yIGhpbS4gQSBnYW1lIHRo
YXQgY2Fubm90IGtlZXAgdXAgd2l0aCB0aGUgZnJhbWVzIGlzIGRyb3BwZWQsIGFuZCB0aGUgb3Ro
ZXJzIGdvIG9uLgogIC8vCiAgLy8gQmluYXJ5IG1lc3NhZ2VzLCBib3RoIHdheXM6IGtpbmQgKDEg
Ynl0ZSksIHBheWxvYWQgbGVuZ3RoICgyIGJ5dGVzLCBsaXR0bGUgZW5kaWFuKSwgcGF5bG9hZC4K
ICAvLyBBIFdlYlNvY2tldCBtZXNzYWdlIG1heSBjYXJyeSBzZXZlcmFsLiBHYW1lIHRvIHJlbGF5
OgogIC8vICAgSEVMTE8gICAweDAxICBwcm9maWxlIGxlbmd0aCAoMSksIHByb2ZpbGUsIGluZm8g
KG5hbWVzOyBhdCBtb3N0IDY0IGJ5dGVzKQogIC8vICAgU1RBUlQgICAweDAyICBzZXR1cCAoYXQg
bW9zdCA4IEtpQik6IHRoZSBob3N0LCBvbmNlIHR3byBwbGF5ZXJzIG9yIG1vcmUgc2FpZCBoZWxs
bwogIC8vICAgSU5QVVQgICAweDAzICBpbnB1dCAoYXQgbW9zdCAxNiBieXRlczsgYnl0ZSAwIGhv
bGRzIG9uZS1zaG90IGV2ZW50cyksIGFmdGVyIFNUQVJURUQKICAvLyAgIFJFQURZICAgMHgwNCAg
ZW1wdHk6IFNUQVJURUQgaXMgYXBwbGllZAogIC8vICAgQ0hFQ0sgICAweDA1ICBmcmFtZSAoNCks
IGhhc2ggKDIpOiBwYXNzZWQgb24gdG8gdGhlIG90aGVycywgd2hpY2ggY29tcGFyZSBpdCB3aXRo
IHRoZWlyIG93bgogIC8vIFJlbGF5IHRvIGdhbWU6CiAgLy8gICBXRUxDT01FIDB4ODEgIGlkICgx
KSwgZmxhZ3MgKDE7IGJpdCAwOiBob3N0KSwgbW9zdCBwbGF5ZXJzICgxKSwgYmVhdCBpbiBtcyAo
MSksCiAgLy8gICAgICAgICAgICAgICAgIHJvb20gY29kZSBsZW5ndGggKDEpLCByb29tIGNvZGUK
ICAvLyAgIExPQkJZICAgMHg4MiAgY291bnQgKDEpOyBwZXIgcGxheWVyOiBpZCAoMSksIGZsYWdz
ICgxKSwgaW5mbyBsZW5ndGggKDEpLCBpbmZvCiAgLy8gICBTVEFSVEVEIDB4ODMgIHRoZSBwbGF5
ZXJzIGFzIGluIExPQkJZLCB0aGVuIHNldHVwIGxlbmd0aCAoMiksIHNldHVwCiAgLy8gICBGUkFN
RSAgIDB4ODQgIGZyYW1lICg0KSwgY291bnQgKDEpLCBmcmVzaCBtYXNrICgxKSwgcHJlc2VudCBt
YXNrICgxKTsKICAvLyAgICAgICAgICAgICAgICAgcGVyIHBsYXllcjogaW5wdXQgbGVuZ3RoICgx
KSwgaW5wdXQKICAvLyAgIENIRUNLRUQgMHg4NSAgaW5kZXggKDEpLCBmcmFtZSAoNCksIGhhc2gg
KDIpCiAgLy8gICBMRUZUICAgIDB4ODYgIGluZGV4ICgxKTogdGhhdCBwbGF5ZXIgaXMgZ29uZTsg
aGlzIGlucHV0IHN0YXlzIGVtcHR5CiAgLy8gVGV4dCAoSlNPTikgbWVzc2FnZXMgYXJlIGZvciB0
aGUgcGFnZSBhcm91bmQgdGhlIGdhbWU6IHsidCI6IndlbGNvbWUiLCJ2IjoyLCJyb29tIjoi4oCm
IiwiaG9zdCI6dHJ1ZX0KICAvLyBhbmQgeyJ0Ijoicm9vbSIsInBsYXllcnMiOjMsInN0YXJ0ZWQi
OmZhbHNlfS4KCiAgZnVuY3Rpb24gam9pbkdyb3VwKHdzLCByb2xlLCBjb2RlKSB7CiAgICBpZiAo
cm9vbXMuaGFzKGNvZGUpKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5jb2RlSW5Vc2UpOwog
ICAgbGV0IHJvb20gPSBncm91cHMuZ2V0KGNvZGUpOwogICAgaWYgKCFyb29tKSB7CiAgICAgIGlm
IChjb25maWcubWF4Um9vbXMgJiYgcm9vbXMuc2l6ZSArIGdyb3Vwcy5zaXplID49IGNvbmZpZy5t
YXhSb29tcykgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0Uuc2VydmVyRnVsbCk7CiAgICAgIHJv
b20gPSB7CiAgICAgICAgY29kZSwgbWVtYmVyczogW10sIGhvc3Q6IG51bGwsIG5leHRJZDogMSwg
cHJvZmlsZTogbnVsbCwgc3RhcnRlZDogZmFsc2UsIG9yZGVyOiBbXSwgZnJhbWU6IDAsCiAgICAg
ICAgdGlja2luZzogZmFsc2UsIHRpY2tzOiAwLCB0aWNrU3RhcnQ6IDAsIGxvYmJ5VGltZXI6IG51
bGwsIGdyYWNlVGltZXI6IG51bGwsIHRpY2tUaW1lcjogbnVsbCwgZW5kZWQ6IGZhbHNlLAogICAg
ICB9OwogICAgICBncm91cHMuc2V0KGNvZGUsIHJvb20pOwogICAgICByb29tLmxvYmJ5VGltZXIg
PSBzZXRUaW1lb3V0KCgpID0+IGVuZEdyb3VwKHJvb20sIENMT1NFLm5vdFN0YXJ0ZWQpLCBjb25m
aWcubG9iYnlXYWl0TXMpOwogICAgICBsb2coYHJvb20gJHtjb2RlfTogb3BlbmVkYCk7CiAgICB9
CiAgICBpZiAocm9vbS5zdGFydGVkKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5zdGFydGVk
KTsKICAgIGlmIChyb2xlID09PSAnaG9zdCcgJiYgcm9vbS5ob3N0KSByZXR1cm4gY2xvc2VXaXRo
KHdzLCBDTE9TRS5ob3N0VGFrZW4pOwogICAgaWYgKHJvb20ubWVtYmVycy5sZW5ndGggPj0gY29u
ZmlnLnJvb21QbGF5ZXJzKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS5yb29tRnVsbCk7CiAg
ICB3aGlsZSAocm9vbS5tZW1iZXJzLnNvbWUoKG90aGVyKSA9PiBvdGhlci5pZCA9PT0gcm9vbS5u
ZXh0SWQpKSByb29tLm5leHRJZCA9IChyb29tLm5leHRJZCAlIDI1NSkgKyAxOwogICAgY29uc3Qg
bWVtYmVyID0gewogICAgICB3cywgcm9vbSwgaWQ6IHJvb20ubmV4dElkLCBob3N0OiByb2xlID09
PSAnaG9zdCcsIGluZm86IG51bGwsIHJlYWR5OiBmYWxzZSwKICAgICAgcXVldWU6IFtdLCBsYXN0
OiBFTVBUWSwgcmVwZWF0czogMCwgcHJlc2VudDogdHJ1ZSwgaW5kZXg6IC0xLAogICAgfTsKICAg
IHJvb20ubmV4dElkID0gKHJvb20ubmV4dElkICUgMjU1KSArIDE7CiAgICByb29tLm1lbWJlcnMu
cHVzaChtZW1iZXIpOwogICAgaWYgKG1lbWJlci5ob3N0KSByb29tLmhvc3QgPSBtZW1iZXI7CiAg
ICB3cy5vbignbWVzc2FnZScsIChkYXRhLCBpc0JpbmFyeSkgPT4gb25Hcm91cE1lc3NhZ2UobWVt
YmVyLCBkYXRhLCBpc0JpbmFyeSkpOwogICAgd3Mub24oJ2Nsb3NlJywgKCkgPT4gbGVhdmVHcm91
cChtZW1iZXIpKTsKICAgIHNlbmRDb250cm9sKHdzLCB7IHQ6ICd3ZWxjb21lJywgdjogMiwgcm9v
bTogY29kZSwgaG9zdDogbWVtYmVyLmhvc3QgfSk7CiAgICBjb25zdCB3ZWxjb21lID0gQnVmZmVy
LmFsbG9jKDUgKyBjb2RlLmxlbmd0aCk7CiAgICB3ZWxjb21lWzBdID0gbWVtYmVyLmlkOwogICAg
d2VsY29tZVsxXSA9IG1lbWJlci5ob3N0ID8gMSA6IDA7CiAgICB3ZWxjb21lWzJdID0gY29uZmln
LnJvb21QbGF5ZXJzOwogICAgd2VsY29tZVszXSA9IE1hdGgubWluKDI1NSwgTWF0aC5yb3VuZChj
b25maWcudGlja01zKSk7CiAgICB3ZWxjb21lWzRdID0gY29kZS5sZW5ndGg7CiAgICB3ZWxjb21l
LndyaXRlKGNvZGUsIDUsICdsYXRpbjEnKTsKICAgIHNlbmRCaW5hcnkod3MsIHBhY2tldChLSU5E
LndlbGNvbWUsIHdlbGNvbWUpKTsKICAgIHNlbmRMb2JieShyb29tLCBtZW1iZXIpOwogICAgbG9n
KGByb29tICR7Y29kZX06ICR7cm9sZX0gYXJyaXZlZCAoJHtyb29tLm1lbWJlcnMubGVuZ3RofSBp
biB0aGUgcm9vbSlgKTsKICB9CgogIC8vIFRoZSBwbGF5ZXJzIHdobyBzYWlkIGhlbGxvLCB0aGUg
aG9zdCBmaXJzdCwgdGhlbiBpbiB0aGUgb3JkZXIgdGhleSBjYW1lLgogIGZ1bmN0aW9uIGxpc3Rl
ZChyb29tKSB7CiAgICBjb25zdCBrbm93biA9IHJvb20ubWVtYmVycy5maWx0ZXIoKG1lbWJlcikg
PT4gbWVtYmVyLmluZm8pOwogICAgcmV0dXJuIGtub3duLmZpbHRlcigobWVtYmVyKSA9PiBtZW1i
ZXIuaG9zdCkuY29uY2F0KGtub3duLmZpbHRlcigobWVtYmVyKSA9PiAhbWVtYmVyLmhvc3QpKTsK
ICB9CgogIGZ1bmN0aW9uIGRlc2NyaWJlUGxheWVycyhsaXN0KSB7CiAgICBjb25zdCBwYXJ0cyA9
IFtCdWZmZXIuZnJvbShbbGlzdC5sZW5ndGhdKV07CiAgICBmb3IgKGNvbnN0IG1lbWJlciBvZiBs
aXN0KSBwYXJ0cy5wdXNoKEJ1ZmZlci5mcm9tKFttZW1iZXIuaWQsIG1lbWJlci5ob3N0ID8gMSA6
IDAsIG1lbWJlci5pbmZvLmxlbmd0aF0pLCBtZW1iZXIuaW5mbyk7CiAgICByZXR1cm4gQnVmZmVy
LmNvbmNhdChwYXJ0cyk7CiAgfQoKICBmdW5jdGlvbiBzZW5kTG9iYnkocm9vbSwgb25seSkgewog
ICAgY29uc3QgbGlzdCA9IGxpc3RlZChyb29tKTsKICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQo
S0lORC5sb2JieSwgZGVzY3JpYmVQbGF5ZXJzKGxpc3QpKTsKICAgIGZvciAoY29uc3QgbWVtYmVy
IG9mIG9ubHkgPyBbb25seV0gOiByb29tLm1lbWJlcnMpIHsKICAgICAgc2VuZEJpbmFyeShtZW1i
ZXIud3MsIG1lc3NhZ2UpOwogICAgICBzZW5kQ29udHJvbChtZW1iZXIud3MsIHsgdDogJ3Jvb20n
LCBwbGF5ZXJzOiBsaXN0Lmxlbmd0aCwgc3RhcnRlZDogZmFsc2UgfSk7CiAgICB9CiAgfQoKICBm
dW5jdGlvbiBvbkdyb3VwTWVzc2FnZShtZW1iZXIsIGRhdGEsIGlzQmluYXJ5KSB7CiAgICBjb25z
dCB7IHdzLCByb29tIH0gPSBtZW1iZXI7CiAgICBpZiAoIWlzQmluYXJ5IHx8IHJvb20uZW5kZWQg
fHwgIXJvb20ubWVtYmVycy5pbmNsdWRlcyhtZW1iZXIpKSByZXR1cm47CiAgICBpZiAoIXdzLm1l
c3NhZ2VCdWRnZXQudGFrZSgxKSB8fCAhd3MuYnl0ZUJ1ZGdldC50YWtlKGRhdGEubGVuZ3RoKSkg
ewogICAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiByYXRlIGxpbWl0YCk7CiAgICAgIHJldHVy
biBjbG9zZVdpdGgod3MsIENMT1NFLnJhdGVMaW1pdGVkKTsKICAgIH0KICAgIGxldCBhdCA9IDA7
CiAgICB3aGlsZSAoYXQgPCBkYXRhLmxlbmd0aCkgewogICAgICBpZiAoZGF0YS5sZW5ndGggLSBh
dCA8IDMpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnByb3RvY29sKTsKICAgICAgY29uc3Qg
a2luZCA9IGRhdGFbYXRdOwogICAgICBjb25zdCBsZW5ndGggPSBkYXRhLnJlYWRVSW50MTZMRShh
dCArIDEpOwogICAgICBpZiAoZGF0YS5sZW5ndGggLSBhdCAtIDMgPCBsZW5ndGgpIHJldHVybiBj
bG9zZVdpdGgod3MsIENMT1NFLnByb3RvY29sKTsKICAgICAgY29uc3QgcHJvYmxlbSA9IGhhbmRs
ZUdyb3VwTWVzc2FnZShtZW1iZXIsIGtpbmQsIGRhdGEuc3ViYXJyYXkoYXQgKyAzLCBhdCArIDMg
KyBsZW5ndGgpKTsKICAgICAgaWYgKHByb2JsZW0pIHJldHVybiBjbG9zZVdpdGgod3MsIHByb2Js
ZW0pOwogICAgICBpZiAocm9vbS5lbmRlZCB8fCAhcm9vbS5tZW1iZXJzLmluY2x1ZGVzKG1lbWJl
cikpIHJldHVybjsKICAgICAgYXQgKz0gMyArIGxlbmd0aDsKICAgIH0KICB9CgogIC8vIFJldHVy
bnMgdGhlIGNsb3NlIGNvZGUgYW5kIHJlYXNvbiBmb3IgYSBtZXNzYWdlIHRoZSBnYW1lIHNob3Vs
ZCBub3QgaGF2ZSBzZW50LgogIGZ1bmN0aW9uIGhhbmRsZUdyb3VwTWVzc2FnZShtZW1iZXIsIGtp
bmQsIHBheWxvYWQpIHsKICAgIGNvbnN0IHJvb20gPSBtZW1iZXIucm9vbTsKICAgIGlmIChraW5k
ID09PSBLSU5ELmhlbGxvKSB7CiAgICAgIGlmIChtZW1iZXIuaW5mbyB8fCByb29tLnN0YXJ0ZWQg
fHwgcGF5bG9hZC5sZW5ndGggPCAxKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIGNvbnN0
IGxlbmd0aCA9IHBheWxvYWRbMF07CiAgICAgIGlmICghbGVuZ3RoIHx8IGxlbmd0aCA+IFJPT01f
TElNSVRTLnByb2ZpbGUgfHwgcGF5bG9hZC5sZW5ndGggPCAxICsgbGVuZ3RoKSByZXR1cm4gQ0xP
U0UucHJvdG9jb2w7CiAgICAgIGNvbnN0IHByb2ZpbGUgPSBCdWZmZXIuZnJvbShwYXlsb2FkLnN1
YmFycmF5KDEsIDEgKyBsZW5ndGgpKTsKICAgICAgY29uc3QgaW5mbyA9IEJ1ZmZlci5mcm9tKHBh
eWxvYWQuc3ViYXJyYXkoMSArIGxlbmd0aCkpOwogICAgICBpZiAoaW5mby5sZW5ndGggPiBST09N
X0xJTUlUUy5pbmZvKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIGlmIChyb29tLnByb2Zp
bGUgJiYgIXJvb20ucHJvZmlsZS5lcXVhbHMocHJvZmlsZSkpIHJldHVybiBDTE9TRS5taXNtYXRj
aDsKICAgICAgcm9vbS5wcm9maWxlID0gcm9vbS5wcm9maWxlIHx8IHByb2ZpbGU7CiAgICAgIG1l
bWJlci5pbmZvID0gaW5mbzsKICAgICAgc2VuZExvYmJ5KHJvb20pOwogICAgICByZXR1cm4gbnVs
bDsKICAgIH0KICAgIGlmIChraW5kID09PSBLSU5ELnN0YXJ0KSB7CiAgICAgIGlmICghbWVtYmVy
Lmhvc3QgfHwgIW1lbWJlci5pbmZvIHx8IHJvb20uc3RhcnRlZCB8fCBwYXlsb2FkLmxlbmd0aCA+
IFJPT01fTElNSVRTLnNldHVwKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIC8vIFNvbWVi
b2R5IGxlZnQganVzdCBiZWZvcmU6IHRoZSBob3N0IHNlZXMgdGhlIGxpc3QgYWdhaW4gaW5zdGVh
ZC4KICAgICAgaWYgKGxpc3RlZChyb29tKS5sZW5ndGggPCAyKSBzZW5kTG9iYnkocm9vbSwgbWVt
YmVyKTsKICAgICAgZWxzZSBzdGFydEdyb3VwKHJvb20sIEJ1ZmZlci5mcm9tKHBheWxvYWQpKTsK
ICAgICAgcmV0dXJuIG51bGw7CiAgICB9CiAgICBpZiAoa2luZCA9PT0gS0lORC5pbnB1dCkgewog
ICAgICBpZiAoIXJvb20uc3RhcnRlZCB8fCBtZW1iZXIuaW5kZXggPCAwIHx8IHBheWxvYWQubGVu
Z3RoID4gUk9PTV9MSU1JVFMuaW5wdXQpIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAgbWVt
YmVyLnF1ZXVlLnB1c2goQnVmZmVyLmZyb20ocGF5bG9hZCkpOwogICAgICAvLyBGYXIgbW9yZSB0
aGFuIGEgYmVhdCdzIHdvcnRoICh0aGUgcmF0ZSBsaW1pdCBhbGxvd3MgYnVyc3RzKTogZm9sZCB0
aGVtLCBrZWVwaW5nIHRoZSBuZXdlc3QgbGFzdC4KICAgICAgaWYgKG1lbWJlci5xdWV1ZS5sZW5n
dGggPiBST09NX0xJTUlUUy5xdWV1ZSkgbWVtYmVyLnF1ZXVlID0gW21lcmdlSW5wdXRzKG1lbWJl
ci5xdWV1ZS5zbGljZSgwLCAtMSkpLCBtZW1iZXIucXVldWUuYXQoLTEpXTsKICAgICAgcmV0dXJu
IG51bGw7CiAgICB9CiAgICBpZiAoa2luZCA9PT0gS0lORC5yZWFkeSkgewogICAgICBpZiAoIXJv
b20uc3RhcnRlZCB8fCBtZW1iZXIuaW5kZXggPCAwIHx8IHBheWxvYWQubGVuZ3RoKSByZXR1cm4g
Q0xPU0UucHJvdG9jb2w7CiAgICAgIG1lbWJlci5yZWFkeSA9IHRydWU7CiAgICAgIGlmIChyb29t
Lm9yZGVyLmV2ZXJ5KChvdGhlcikgPT4gb3RoZXIucmVhZHkgfHwgIW90aGVyLnByZXNlbnQpKSBz
dGFydEJlYXQocm9vbSk7CiAgICAgIHJldHVybiBudWxsOwogICAgfQogICAgaWYgKGtpbmQgPT09
IEtJTkQuY2hlY2spIHsKICAgICAgaWYgKCFyb29tLnN0YXJ0ZWQgfHwgbWVtYmVyLmluZGV4IDwg
MCB8fCBwYXlsb2FkLmxlbmd0aCAhPT0gNikgcmV0dXJuIENMT1NFLnByb3RvY29sOwogICAgICBj
b25zdCBtZXNzYWdlID0gcGFja2V0KEtJTkQuY2hlY2tlZCwgQnVmZmVyLmNvbmNhdChbQnVmZmVy
LmZyb20oW21lbWJlci5pbmRleF0pLCBwYXlsb2FkXSkpOwogICAgICBmb3IgKGNvbnN0IG90aGVy
IG9mIHJvb20ub3JkZXIpIGlmIChvdGhlciAhPT0gbWVtYmVyICYmIG90aGVyLnByZXNlbnQpIHNl
bmRCaW5hcnkob3RoZXIud3MsIG1lc3NhZ2UpOwogICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAg
IHJldHVybiBDTE9TRS5wcm90b2NvbDsKICB9CgogIGZ1bmN0aW9uIHN0YXJ0R3JvdXAocm9vbSwg
c2V0dXApIHsKICAgIGNsZWFyVGltZW91dChyb29tLmxvYmJ5VGltZXIpOwogICAgcm9vbS5zdGFy
dGVkID0gdHJ1ZTsKICAgIHJvb20ub3JkZXIgPSBsaXN0ZWQocm9vbSk7CiAgICByb29tLm9yZGVy
LmZvckVhY2goKG1lbWJlciwgaW5kZXgpID0+IHsgbWVtYmVyLmluZGV4ID0gaW5kZXg7IH0pOwog
ICAgLy8gQSBnYW1lIHN0aWxsIGNvbm5lY3RpbmcgaGFzIG1pc3NlZCB0aGUgc3RhcnQuCiAgICBm
b3IgKGNvbnN0IG1lbWJlciBvZiByb29tLm1lbWJlcnMpIGlmICghbWVtYmVyLmluZm8pIGNsb3Nl
V2l0aChtZW1iZXIud3MsIENMT1NFLnN0YXJ0ZWQpOwogICAgY29uc3QgbGVuZ3RoID0gQnVmZmVy
LmFsbG9jKDIpOwogICAgbGVuZ3RoLndyaXRlVUludDE2TEUoc2V0dXAubGVuZ3RoLCAwKTsKICAg
IGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lORC5zdGFydGVkLCBCdWZmZXIuY29uY2F0KFtkZXNj
cmliZVBsYXllcnMocm9vbS5vcmRlciksIGxlbmd0aCwgc2V0dXBdKSk7CiAgICBmb3IgKGNvbnN0
IG1lbWJlciBvZiByb29tLm9yZGVyKSB7CiAgICAgIHNlbmRCaW5hcnkobWVtYmVyLndzLCBtZXNz
YWdlKTsKICAgICAgc2VuZENvbnRyb2wobWVtYmVyLndzLCB7IHQ6ICdyb29tJywgcGxheWVyczog
cm9vbS5vcmRlci5sZW5ndGgsIHN0YXJ0ZWQ6IHRydWUgfSk7CiAgICB9CiAgICByb29tLmdyYWNl
VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHN0YXJ0QmVhdChyb29tKSwgY29uZmlnLnN0YXJ0R3Jh
Y2VNcyk7CiAgICBsb2coYHJvb20gJHtyb29tLmNvZGV9OiBzdGFydGVkIHdpdGggJHtyb29tLm9y
ZGVyLmxlbmd0aH0gcGxheWVyc2ApOwogIH0KCiAgZnVuY3Rpb24gc3RhcnRCZWF0KHJvb20pIHsK
ICAgIGlmIChyb29tLnRpY2tpbmcgfHwgcm9vbS5lbmRlZCkgcmV0dXJuOwogICAgY2xlYXJUaW1l
b3V0KHJvb20uZ3JhY2VUaW1lcik7CiAgICByb29tLnRpY2tpbmcgPSB0cnVlOwogICAgcm9vbS50
aWNrU3RhcnQgPSBwZXJmb3JtYW5jZS5ub3coKTsKICAgIHJvb20udGlja3MgPSAwOwogICAgc2No
ZWR1bGVCZWF0KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gc2NoZWR1bGVCZWF0KHJvb20pIHsKICAg
IGNvbnN0IGR1ZSA9IHJvb20udGlja1N0YXJ0ICsgKHJvb20udGlja3MgKyAxKSAqIGNvbmZpZy50
aWNrTXM7CiAgICByb29tLnRpY2tUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gcnVuQmVhdHMocm9v
bSksIE1hdGgubWF4KDAsIGR1ZSAtIHBlcmZvcm1hbmNlLm5vdygpKSk7CiAgfQoKICAvLyBCZWF0
cyBhcmUgY291bnRlZCBmcm9tIHRoZSBzdGFydCwgc28gdGltZXIgZGVsYXlzIGRvIG5vdCBhZGQg
dXA7IGFmdGVyIGEgc3RhbGwgb2YgdGhlIHdob2xlCiAgLy8gcHJvY2VzcyBhIGZldyBtaXNzZWQg
YmVhdHMgYXJlIHNlbnQgYXQgb25jZSwgYW5kIGEgbG9uZ2VyIG9uZSByZXN0YXJ0cyB0aGUgY291
bnQuCiAgZnVuY3Rpb24gcnVuQmVhdHMocm9vbSkgewogICAgaWYgKHJvb20uZW5kZWQpIHJldHVy
bjsKICAgIGNvbnN0IG5vdyA9IHBlcmZvcm1hbmNlLm5vdygpOwogICAgY29uc3QgZHVlID0gTWF0
aC5mbG9vcigobm93IC0gcm9vbS50aWNrU3RhcnQpIC8gY29uZmlnLnRpY2tNcykgLSByb29tLnRp
Y2tzOwogICAgZm9yIChsZXQgY291bnQgPSAwOyBjb3VudCA8IE1hdGgubWluKGR1ZSwgNCkgJiYg
IXJvb20uZW5kZWQ7IGNvdW50ICs9IDEpIHsKICAgICAgcm9vbS50aWNrcyArPSAxOwogICAgICBi
ZWF0KHJvb20pOwogICAgfQogICAgaWYgKHJvb20uZW5kZWQpIHJldHVybjsKICAgIGlmIChkdWUg
PiA0KSByb29tLnRpY2tTdGFydCA9IG5vdyAtIHJvb20udGlja3MgKiBjb25maWcudGlja01zOwog
ICAgc2NoZWR1bGVCZWF0KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gYmVhdChyb29tKSB7CiAgICBs
ZXQgZnJlc2ggPSAwOwogICAgbGV0IHByZXNlbnQgPSAwOwogICAgY29uc3QgcGFydHMgPSBbXTsK
ICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ub3JkZXIpIHsKICAgICAgbGV0IGlucHV0ID0g
RU1QVFk7CiAgICAgIGlmIChtZW1iZXIucHJlc2VudCkgewogICAgICAgIHByZXNlbnQgfD0gMSA8
PCBtZW1iZXIuaW5kZXg7CiAgICAgICAgY29uc3Qgd2FpdGluZyA9IG1lbWJlci5xdWV1ZS5sZW5n
dGg7CiAgICAgICAgaWYgKHdhaXRpbmcpIHsKICAgICAgICAgIGZyZXNoIHw9IDEgPDwgbWVtYmVy
LmluZGV4OwogICAgICAgICAgaW5wdXQgPSB3YWl0aW5nID09PSAxID8gbWVtYmVyLnF1ZXVlWzBd
IDogbWVyZ2VJbnB1dHMobWVtYmVyLnF1ZXVlKTsKICAgICAgICAgIG1lbWJlci5sYXN0ID0gbWVt
YmVyLnF1ZXVlW3dhaXRpbmcgLSAxXTsKICAgICAgICAgIG1lbWJlci5xdWV1ZSA9IFtdOwogICAg
ICAgICAgbWVtYmVyLnJlcGVhdHMgPSAwOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBtZW1i
ZXIucmVwZWF0cyArPSAxOwogICAgICAgICAgaW5wdXQgPSBtZW1iZXIucmVwZWF0cyA+IGNvbmZp
Zy5yZXBlYXRMaW1pdCA/IEVNUFRZIDogd2l0aG91dEV2ZW50cyhtZW1iZXIubGFzdCk7CiAgICAg
ICAgfQogICAgICB9CiAgICAgIHBhcnRzLnB1c2goQnVmZmVyLmZyb20oW2lucHV0Lmxlbmd0aF0p
LCBpbnB1dCk7CiAgICB9CiAgICBjb25zdCBoZWFkZXIgPSBCdWZmZXIuYWxsb2MoNyk7CiAgICBo
ZWFkZXIud3JpdGVVSW50MzJMRShyb29tLmZyYW1lICUgNDI5NDk2NzI5NiwgMCk7CiAgICBoZWFk
ZXJbNF0gPSByb29tLm9yZGVyLmxlbmd0aDsKICAgIGhlYWRlcls1XSA9IGZyZXNoOwogICAgaGVh
ZGVyWzZdID0gcHJlc2VudDsKICAgIHJvb20uZnJhbWUgKz0gMTsKICAgIGNvbnN0IG1lc3NhZ2Ug
PSBwYWNrZXQoS0lORC5mcmFtZSwgQnVmZmVyLmNvbmNhdChbaGVhZGVyLCAuLi5wYXJ0c10pKTsK
ICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ub3JkZXIpIHsKICAgICAgaWYgKCFtZW1iZXIu
cHJlc2VudCkgY29udGludWU7CiAgICAgIGlmIChtZW1iZXIud3MuYnVmZmVyZWRBbW91bnQgPiBj
b25maWcubWF4QnVmZmVyZWRCeXRlcykgewogICAgICAgIGNsb3NlV2l0aChtZW1iZXIud3MsIENM
T1NFLnNsb3dDbGllbnQpOwogICAgICAgIGNvbnRpbnVlOwogICAgICB9CiAgICAgIHNlbmRCaW5h
cnkobWVtYmVyLndzLCBtZXNzYWdlKTsKICAgIH0KICB9CgogIGZ1bmN0aW9uIGxlYXZlR3JvdXAo
bWVtYmVyKSB7CiAgICBjb25zdCByb29tID0gbWVtYmVyLnJvb207CiAgICBjb25zdCBwb3NpdGlv
biA9IHJvb20ubWVtYmVycy5pbmRleE9mKG1lbWJlcik7CiAgICBpZiAocG9zaXRpb24gPj0gMCkg
cm9vbS5tZW1iZXJzLnNwbGljZShwb3NpdGlvbiwgMSk7CiAgICBpZiAocm9vbS5lbmRlZCkgcmV0
dXJuOwogICAgaWYgKCFyb29tLnN0YXJ0ZWQpIHsKICAgICAgaWYgKG1lbWJlci5ob3N0KSB7CiAg
ICAgICAgcm9vbS5ob3N0ID0gbnVsbDsKICAgICAgICBlbmRHcm91cChyb29tLCBDTE9TRS5ob3N0
TGVmdCk7CiAgICAgIH0gZWxzZSBpZiAoIXJvb20ubWVtYmVycy5sZW5ndGgpIHsKICAgICAgICBl
bmRHcm91cChyb29tKTsKICAgICAgfSBlbHNlIGlmIChtZW1iZXIuaW5mbykgewogICAgICAgIHNl
bmRMb2JieShyb29tKTsKICAgICAgfQogICAgICByZXR1cm47CiAgICB9CiAgICBpZiAobWVtYmVy
LmluZGV4ID49IDAgJiYgbWVtYmVyLnByZXNlbnQpIHsKICAgICAgbWVtYmVyLnByZXNlbnQgPSBm
YWxzZTsKICAgICAgbWVtYmVyLnF1ZXVlID0gW107CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNr
ZXQoS0lORC5sZWZ0LCBCdWZmZXIuZnJvbShbbWVtYmVyLmluZGV4XSkpOwogICAgICBjb25zdCBw
bGF5ZXJzID0gcm9vbS5vcmRlci5maWx0ZXIoKG90aGVyKSA9PiBvdGhlci5wcmVzZW50KS5sZW5n
dGg7CiAgICAgIGZvciAoY29uc3Qgb3RoZXIgb2Ygcm9vbS5vcmRlcikgewogICAgICAgIGlmICgh
b3RoZXIucHJlc2VudCkgY29udGludWU7CiAgICAgICAgc2VuZEJpbmFyeShvdGhlci53cywgbWVz
c2FnZSk7CiAgICAgICAgc2VuZENvbnRyb2wob3RoZXIud3MsIHsgdDogJ3Jvb20nLCBwbGF5ZXJz
LCBzdGFydGVkOiB0cnVlIH0pOwogICAgICB9CiAgICAgIGxvZyhgcm9vbSAke3Jvb20uY29kZX06
IHBsYXllciAke21lbWJlci5pbmRleCArIDF9IGxlZnRgKTsKICAgIH0KICAgIGlmICghcm9vbS5v
cmRlci5zb21lKChvdGhlcikgPT4gb3RoZXIucHJlc2VudCkpIGVuZEdyb3VwKHJvb20pOwogICAg
ZWxzZSBpZiAocm9vbS5vcmRlci5ldmVyeSgob3RoZXIpID0+IG90aGVyLnJlYWR5IHx8ICFvdGhl
ci5wcmVzZW50KSkgc3RhcnRCZWF0KHJvb20pOwogIH0KCiAgZnVuY3Rpb24gZW5kR3JvdXAocm9v
bSwgcmVhc29uKSB7CiAgICBpZiAocm9vbS5lbmRlZCkgcmV0dXJuOwogICAgcm9vbS5lbmRlZCA9
IHRydWU7CiAgICBjbGVhclRpbWVvdXQocm9vbS5sb2JieVRpbWVyKTsKICAgIGNsZWFyVGltZW91
dChyb29tLmdyYWNlVGltZXIpOwogICAgY2xlYXJUaW1lb3V0KHJvb20udGlja1RpbWVyKTsKICAg
IGlmIChncm91cHMuZ2V0KHJvb20uY29kZSkgPT09IHJvb20pIGdyb3Vwcy5kZWxldGUocm9vbS5j
b2RlKTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJvb20ubWVtYmVycy5zbGljZSgpKSBjbG9z
ZVdpdGgobWVtYmVyLndzLCByZWFzb24gfHwgQ0xPU0Uuc2h1dGRvd24pOwogICAgbG9nKGByb29t
ICR7cm9vbS5jb2RlfTogZW5kZWRgKTsKICB9CgogIC8vIFNpemUgb2YgdGhlIGluc3RhbGxlciBm
aWxlLCBvciAwIHdoZW4gbm9uZSBpcyBjb25maWd1cmVkIG9yIHJlYWRhYmxlLgogIGZ1bmN0aW9u
IGluc3RhbGxlclNpemUoKSB7CiAgICBpZiAoIWNvbmZpZy5pbnN0YWxsZXJGaWxlKSByZXR1cm4g
MDsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHN0YXQgPSBmcy5zdGF0U3luYyhjb25maWcuaW5zdGFs
bGVyRmlsZSk7CiAgICAgIHJldHVybiBzdGF0LmlzRmlsZSgpID8gc3RhdC5zaXplIDogMDsKICAg
IH0gY2F0Y2ggewogICAgICByZXR1cm4gMDsKICAgIH0KICB9CgogIGZ1bmN0aW9uIHNlcnZlSW5z
dGFsbGVyKHJlcSwgcmVzKSB7CiAgICBjb25zdCBoZWFkZXJzID0geyAnY2FjaGUtY29udHJvbCc6
ICdwdWJsaWMsIG1heC1hZ2U9ODY0MDAnLCAneC1jb250ZW50LXR5cGUtb3B0aW9ucyc6ICdub3Nu
aWZmJywgLi4uYWxsb3dPcmlnaW4ocmVxKSB9OwogICAgaWYgKHJlcS5tZXRob2QgIT09ICdHRVQn
ICYmIHJlcS5tZXRob2QgIT09ICdIRUFEJykgewogICAgICByZXMud3JpdGVIZWFkKDQwNSwgeyAu
Li5oZWFkZXJzLCBhbGxvdzogJ0dFVCwgSEVBRCcgfSk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAg
cmV0dXJuOwogICAgfQogICAgY29uc3Qgc2l6ZSA9IGluc3RhbGxlclNpemUoKTsKICAgIGlmICgh
c2l6ZSkgewogICAgICByZXMud3JpdGVIZWFkKDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQo
KTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHJlcS5tZXRob2QgPT09ICdHRVQnICYmIGNv
bmZpZy5pbnN0YWxsZXJEb3dubG9hZHNQZXJIb3VyKSB7CiAgICAgIGNvbnN0IGFkZHJlc3MgPSBj
bGllbnRBZGRyZXNzKHJlcSk7CiAgICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgICAgIGxl
dCBlbnRyeSA9IGluc3RhbGxlckRvd25sb2Fkcy5nZXQoYWRkcmVzcyk7CiAgICAgIGlmICghZW50
cnkgfHwgZW50cnkudW50aWwgPD0gbm93KSB7CiAgICAgICAgZW50cnkgPSB7IGNvdW50OiAwLCB1
bnRpbDogbm93ICsgMzYwMDAwMCB9OwogICAgICAgIGluc3RhbGxlckRvd25sb2Fkcy5zZXQoYWRk
cmVzcywgZW50cnkpOwogICAgICB9CiAgICAgIGlmIChlbnRyeS5jb3VudCA+PSBjb25maWcuaW5z
dGFsbGVyRG93bmxvYWRzUGVySG91cikgewogICAgICAgIHJlcy53cml0ZUhlYWQoNDI5LCB7IC4u
LmhlYWRlcnMsICdyZXRyeS1hZnRlcic6IFN0cmluZyhNYXRoLmNlaWwoKGVudHJ5LnVudGlsIC0g
bm93KSAvIDEwMDApKSB9KTsKICAgICAgICByZXMuZW5kKCk7CiAgICAgICAgcmV0dXJuOwogICAg
ICB9CiAgICAgIGVudHJ5LmNvdW50ICs9IDE7CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwg
eyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBlJzogJ2FwcGxpY2F0aW9uL29jdGV0LXN0cmVhbScs
ICdjb250ZW50LWxlbmd0aCc6IFN0cmluZyhzaXplKSB9KTsKICAgIGlmIChyZXEubWV0aG9kID09
PSAnSEVBRCcpIHsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25z
dCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFkU3RyZWFtKGNvbmZpZy5pbnN0YWxsZXJGaWxlKTsKICAg
IHN0cmVhbS5vbignZXJyb3InLCAoKSA9PiByZXMuZGVzdHJveSgpKTsKICAgIHN0cmVhbS5waXBl
KHJlcyk7CiAgfQoKICAvLyBDcm9zcy1vcmlnaW46IHRoZSBnYW1lIHBhZ2UgbGl2ZXMgZWxzZXdo
ZXJlIChHaXRIdWIgUGFnZXMpLiBXaXRoIGFuIGFsbG93LWxpc3QsIG9ubHkgaXRzIHBhZ2VzIG1h
eSByZWFkLgogIGZ1bmN0aW9uIGFsbG93T3JpZ2luKHJlcSkgewogICAgaWYgKCFjb25maWcuYWxs
b3dlZE9yaWdpbnMubGVuZ3RoKSByZXR1cm4geyAnYWNjZXNzLWNvbnRyb2wtYWxsb3ctb3JpZ2lu
JzogJyonIH07CiAgICBjb25zdCBvcmlnaW4gPSBub3JtYWxpemVPcmlnaW4ocmVxLmhlYWRlcnMu
b3JpZ2luKTsKICAgIGlmIChvcmlnaW4gJiYgY29uZmlnLmFsbG93ZWRPcmlnaW5zLmluY2x1ZGVz
KG9yaWdpbikpIHJldHVybiB7ICdhY2Nlc3MtY29udHJvbC1hbGxvdy1vcmlnaW4nOiByZXEuaGVh
ZGVycy5vcmlnaW4sIHZhcnk6ICdPcmlnaW4nIH07CiAgICByZXR1cm4ge307CiAgfQoKICBmdW5j
dGlvbiBjbGllbnRBZGRyZXNzKHJlcSkgewogICAgaWYgKGNvbmZpZy50cnVzdFByb3h5KSB7CiAg
ICAgIC8vIFRoZSBsYXN0IGVudHJ5IGlzIHRoZSBvbmUgb3VyIG93biBwcm94eSBhZGRlZCAoQXBh
Y2hlIGFwcGVuZHMsIENhZGR5IHJlcGxhY2VzKTsgZW50cmllcyBiZWZvcmUKICAgICAgLy8gaXQg
Y29tZSBmcm9tIHRoZSBjbGllbnQgYW5kIGNvdWxkIGJlIG1hZGUgdXAgdG8gc2xpcCBwYXN0IHRo
ZSBwZXItYWRkcmVzcyBsaW1pdHMuCiAgICAgIGNvbnN0IGZvcndhcmRlZCA9IFN0cmluZyhyZXEu
aGVhZGVyc1sneC1mb3J3YXJkZWQtZm9yJ10gfHwgJycpLnNwbGl0KCcsJykubWFwKChwYXJ0KSA9
PiBwYXJ0LnRyaW0oKSkuZmlsdGVyKEJvb2xlYW4pOwogICAgICBpZiAoZm9yd2FyZGVkLmxlbmd0
aCkgcmV0dXJuIGZvcndhcmRlZFtmb3J3YXJkZWQubGVuZ3RoIC0gMV07CiAgICB9CiAgICByZXR1
cm4gcmVxLnNvY2tldC5yZW1vdGVBZGRyZXNzIHx8ICd1bmtub3duJzsKICB9CgogIGNvbnN0IGhl
YXJ0YmVhdCA9IHNldEludGVydmFsKCgpID0+IHsKICAgIGZvciAoY29uc3Qgd3Mgb2Ygd3NzLmNs
aWVudHMpIHsKICAgICAgaWYgKCF3cy5pc0FsaXZlKSB7IHdzLnRlcm1pbmF0ZSgpOyBjb250aW51
ZTsgfQogICAgICB3cy5pc0FsaXZlID0gZmFsc2U7CiAgICAgIHRyeSB7IHdzLnBpbmcoKTsgfSBj
YXRjaCB7IC8qIGNsb3NpbmcgKi8gfQogICAgfQogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsK
ICAgIGZvciAoY29uc3QgW2FkZHJlc3MsIGVudHJ5XSBvZiBpbnN0YWxsZXJEb3dubG9hZHMpIGlm
IChlbnRyeS51bnRpbCA8PSBub3cpIGluc3RhbGxlckRvd25sb2Fkcy5kZWxldGUoYWRkcmVzcyk7
CiAgICBwYWNrcy5jbGVhbnVwKCk7CiAgfSwgY29uZmlnLnBpbmdJbnRlcnZhbE1zKTsKICBoZWFy
dGJlYXQudW5yZWYoKTsKCiAgcmV0dXJuIHsKICAgIGNvbmZpZywKICAgIHNlcnZlciwKICAgIHdz
cywKICAgIHJvb21zLAogICAgbGlzdGVuKHBvcnQgPSBjb25maWcucG9ydCwgaG9zdCA9IGNvbmZp
Zy5ob3N0KSB7CiAgICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVzb2x2ZSwgcmVqZWN0KSA9PiB7
CiAgICAgICAgc2VydmVyLm9uY2UoJ2Vycm9yJywgcmVqZWN0KTsKICAgICAgICBzZXJ2ZXIubGlz
dGVuKHBvcnQsIGhvc3QsICgpID0+IHsKICAgICAgICAgIHNlcnZlci5vZmYoJ2Vycm9yJywgcmVq
ZWN0KTsKICAgICAgICAgIHJlc29sdmUoc2VydmVyLmFkZHJlc3MoKSk7CiAgICAgICAgfSk7CiAg
ICAgIH0pOwogICAgfSwKICAgIGdyb3VwcywKICAgIGNsb3NlKCkgewogICAgICBjbGVhckludGVy
dmFsKGhlYXJ0YmVhdCk7CiAgICAgIGZvciAoY29uc3Qgcm9vbSBvZiByb29tcy52YWx1ZXMoKSkg
Y2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICBmb3IgKGNvbnN0IHJvb20gb2YgWy4uLmdy
b3Vwcy52YWx1ZXMoKV0pIGVuZEdyb3VwKHJvb20sIENMT1NFLnNodXRkb3duKTsKICAgICAgZm9y
IChjb25zdCB3cyBvZiB3c3MuY2xpZW50cykgY2xvc2VXaXRoKHdzLCBDTE9TRS5zaHV0ZG93bik7
CiAgICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVzb2x2ZSkgPT4gewogICAgICAgIHdzcy5jbG9z
ZSgoKSA9PiBzZXJ2ZXIuY2xvc2UoKCkgPT4gcmVzb2x2ZSgpKSk7CiAgICAgICAgc2V0VGltZW91
dCgoKSA9PiB7IGZvciAoY29uc3Qgd3Mgb2Ygd3NzLmNsaWVudHMpIHdzLnRlcm1pbmF0ZSgpOyB9
LCAxMDAwKS51bnJlZigpOwogICAgICB9KTsKICAgIH0sCiAgfTsKfQoKZnVuY3Rpb24gc2VuZENv
bnRyb2wod3MsIG1lc3NhZ2UpIHsKICBpZiAod3MucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9Q
RU4pIHdzLnNlbmQoSlNPTi5zdHJpbmdpZnkobWVzc2FnZSkpOwp9CgpmdW5jdGlvbiBzZW5kQmlu
YXJ5KHdzLCBkYXRhKSB7CiAgaWYgKHdzLnJlYWR5U3RhdGUgPT09IFdlYlNvY2tldC5PUEVOKSB3
cy5zZW5kKGRhdGEsIHsgYmluYXJ5OiB0cnVlIH0pOwp9Cgpjb25zdCBFTVBUWSA9IEJ1ZmZlci5h
bGxvYygwKTsKCi8vIEEgcHJvdG9jb2wgMiBtZXNzYWdlOiBraW5kLCBwYXlsb2FkIGxlbmd0aCAo
MiBieXRlcywgbGl0dGxlIGVuZGlhbiksIHBheWxvYWQuCmZ1bmN0aW9uIHBhY2tldChraW5kLCBw
YXlsb2FkKSB7CiAgY29uc3QgbWVzc2FnZSA9IEJ1ZmZlci5hbGxvY1Vuc2FmZSgzICsgcGF5bG9h
ZC5sZW5ndGgpOwogIG1lc3NhZ2VbMF0gPSBraW5kOwogIG1lc3NhZ2Uud3JpdGVVSW50MTZMRShw
YXlsb2FkLmxlbmd0aCwgMSk7CiAgcGF5bG9hZC5jb3B5KG1lc3NhZ2UsIDMpOwogIHJldHVybiBt
ZXNzYWdlOwp9CgovLyBJbnB1dHMgYXJlIGJpdCBzZXRzIChrZXlzIGhlbGQsIGV2ZW50cyk6IG1l
cmdlZCwgZXZlcnkgYml0IHNldCBpbiBhbnkgb2YgdGhlbSBpcyBzZXQuCmZ1bmN0aW9uIG1lcmdl
SW5wdXRzKGlucHV0cykgewogIGNvbnN0IG1lcmdlZCA9IEJ1ZmZlci5hbGxvYyhNYXRoLm1heCgw
LCAuLi5pbnB1dHMubWFwKChpbnB1dCkgPT4gaW5wdXQubGVuZ3RoKSkpOwogIGZvciAoY29uc3Qg
aW5wdXQgb2YgaW5wdXRzKSBmb3IgKGxldCBpbmRleCA9IDA7IGluZGV4IDwgaW5wdXQubGVuZ3Ro
OyBpbmRleCArPSAxKSBtZXJnZWRbaW5kZXhdIHw9IGlucHV0W2luZGV4XTsKICByZXR1cm4gbWVy
Z2VkOwp9CgovLyBBIHJlcGVhdGVkIGlucHV0IGtlZXBzIGl0cyBoZWxkIGtleXMgYnV0IG5vdCBp
dHMgb25lLXNob3QgZXZlbnRzIChieXRlIDApLgpmdW5jdGlvbiB3aXRob3V0RXZlbnRzKGlucHV0
KSB7CiAgaWYgKCFpbnB1dC5sZW5ndGggfHwgaW5wdXRbMF0gPT09IDApIHJldHVybiBpbnB1dDsK
ICBjb25zdCBjb3B5ID0gQnVmZmVyLmZyb20oaW5wdXQpOwogIGNvcHlbMF0gPSAwOwogIHJldHVy
biBjb3B5Owp9CgpmdW5jdGlvbiBjbG9zZVdpdGgod3MsIFtjb2RlLCByZWFzb25dKSB7CiAgaWYg
KHdzLnJlYWR5U3RhdGUgPT09IFdlYlNvY2tldC5PUEVOIHx8IHdzLnJlYWR5U3RhdGUgPT09IFdl
YlNvY2tldC5DT05ORUNUSU5HKSB7CiAgICB3cy5jbG9zZShjb2RlLCByZWFzb24pOwogICAgLy8g
RG8gbm90IHdhaXQgZm9yZXZlciBmb3IgYSBjbGllbnQgdGhhdCBuZXZlciBhbnN3ZXJzIHRoZSBj
bG9zZSBoYW5kc2hha2UuCiAgICBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKHdzLnJlYWR5U3RhdGUg
IT09IFdlYlNvY2tldC5DTE9TRUQpIHdzLnRlcm1pbmF0ZSgpOyB9LCAzMDAwKS51bnJlZigpOwog
IH0KfQoKbW9kdWxlLmV4cG9ydHMgPSB7IGNyZWF0ZVJlbGF5LCByZWFkQ29uZmlnLCBDTE9TRSwg
Uk9PTV9QQVRURVJOLCBLSU5ELCBST09NX0xJTUlUUywgcGFja2V0LCBtZXJnZUlucHV0cyB9OwoK
aWYgKHJlcXVpcmUubWFpbiA9PT0gbW9kdWxlKSB7CiAgY29uc3QgcmVsYXkgPSBjcmVhdGVSZWxh
eShyZWFkQ29uZmlnKCkpOwogIHJlbGF5Lmxpc3RlbigpLnRoZW4oKGFkZHJlc3MpID0+IHsKICAg
IGNvbnN0IHdoZXJlID0gdHlwZW9mIGFkZHJlc3MgPT09ICdzdHJpbmcnID8gYWRkcmVzcyA6IGAk
e2FkZHJlc3MuYWRkcmVzc306JHthZGRyZXNzLnBvcnR9YDsKICAgIGNvbnNvbGUubG9nKGBPcGVu
TEYyIHJlbGF5IGxpc3RlbmluZyBvbiAke3doZXJlfSwgV2ViU29ja2V0IHBhdGggJHtyZWxheS5j
b25maWcucGF0aH1gKTsKICAgIGlmICghcmVsYXkuY29uZmlnLmFsbG93ZWRPcmlnaW5zLmxlbmd0
aCkgewogICAgICBjb25zb2xlLmxvZygnQUxMT1dFRF9PUklHSU5TIGlzIGVtcHR5OiBhbnkgd2Vi
c2l0ZSBtYXkgdXNlIHRoaXMgcmVsYXkuIFNldCBpdCB0byB5b3VyIGdhbWUgcGFnZSBvcmlnaW4u
Jyk7CiAgICB9CiAgfSkuY2F0Y2goKGVycm9yKSA9PiB7CiAgICBjb25zb2xlLmVycm9yKGVycm9y
Lm1lc3NhZ2UpOwogICAgcHJvY2Vzcy5leGl0KDEpOwogIH0pOwogIGNvbnN0IHN0b3AgPSAoKSA9
PiByZWxheS5jbG9zZSgpLnRoZW4oKCkgPT4gcHJvY2Vzcy5leGl0KDApKTsKICBwcm9jZXNzLm9u
KCdTSUdJTlQnLCBzdG9wKTsKICBwcm9jZXNzLm9uKCdTSUdURVJNJywgc3RvcCk7Cn0K
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
b2RzIG9mdGVuIGNhcnJ5LCBzbyB0aGF0IHBsYXllcnMgZG93bmxvYWQgbGVzcy4KLy8KLy8gICBH
RVQgIC9sZjItcGFja3MuanNvbiAgICAgICAgICAgICB0aGUgcGFja3M6IHsicGFja3MiOlt7Imlk
IiwidGl0bGUiLCJzaXplIiwic2hhMjU2In1dfQovLyAgIEdFVCAgL2xmMi1wYWNrcy88aWQ+Lnpp
cCAgICAgICAgIGEgcGFjawovLyAgIEdFVCAgL2FkbWluICAgICAgICAgICAgICAgICAgICAgIHRo
ZSBwYWdlIHRvIG1hbmFnZSB0aGVtCi8vICAgR0VUICAvYWRtaW4vYXBpL3BhY2tzICAgICAgICAg
ICAgdGhlIHNhbWUgbGlzdCwgd2l0aCBkZXRhaWxzIChYLUFkbWluLUtleSkKLy8gICBQVVQgIC9h
ZG1pbi9hcGkvcGFja3MvPGlkPj90aXRsZT08dGl0bGU+ICAgdXBsb2FkIGEgWklQIGZpbGUgYXMg
dGhlIGJvZHkgKFgtQWRtaW4tS2V5KQovLyAgIERFTEVURSAvYWRtaW4vYXBpL3BhY2tzLzxpZD4g
ICAgIHJlbW92ZSBvbmUgKFgtQWRtaW4tS2V5KQondXNlIHN0cmljdCc7Cgpjb25zdCBjcnlwdG8g
PSByZXF1aXJlKCdub2RlOmNyeXB0bycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ25vZGU6ZnMnKTsK
Y29uc3QgZnNwID0gcmVxdWlyZSgnbm9kZTpmcy9wcm9taXNlcycpOwpjb25zdCBwYXRoID0gcmVx
dWlyZSgnbm9kZTpwYXRoJyk7CmNvbnN0IHsgcGlwZWxpbmUgfSA9IHJlcXVpcmUoJ25vZGU6c3Ry
ZWFtL3Byb21pc2VzJyk7CmNvbnN0IHsgVHJhbnNmb3JtIH0gPSByZXF1aXJlKCdub2RlOnN0cmVh
bScpOwoKY29uc3QgUEFDS19JRCA9IC9eW2EtejAtOV1bYS16MC05LV17MCwzOX0kLzsKY29uc3Qg
TUlCID0gMTAyNCAqIDEwMjQ7Ci8vIEZpbGVzIGJlc2lkZSB0aGUgZ2FtZSB0aGF0IG5vIGdhbWUg
cmVhZHM6IG5vdGVzLCBhcmNoaXZlcywgdmlkZW9zLCBzaG9ydGN1dHMuCmNvbnN0IE5PVEVTID0g
L1wuKHR4dHxuZm98ZG9jfGRvY3h8cGRmfHJ0ZnxodG18aHRtbHx1cmx8bG5rfHN3ZnxyYXJ8emlw
fDd6fGxmcnxtcDR8YXZpfHdtdnxqcGd8anBlZ3xnaWYpJC9pOwoKY2xhc3MgUGFja0Vycm9yIGV4
dGVuZHMgRXJyb3Ige30KCi8vIFRoZSBjZW50cmFsIGRpcmVjdG9yeSBvZiBhIFpJUCBmaWxlOiBp
dHMgZW50cmllcyB3aXRoIHRoZWlyIHJhdyByZWNvcmRzLgphc3luYyBmdW5jdGlvbiByZWFkWmlw
KGZpbGUpIHsKICBjb25zdCBoYW5kbGUgPSBhd2FpdCBmc3Aub3BlbihmaWxlLCAncicpOwogIHRy
eSB7CiAgICBjb25zdCB7IHNpemUgfSA9IGF3YWl0IGhhbmRsZS5zdGF0KCk7CiAgICBpZiAoc2l6
ZSA8IDIyKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGlzIGlzIG5vdCBhIFpJUCBmaWxlJyk7CiAg
ICBpZiAoc2l6ZSA+IDB4ZmZmZmZmZmYpIHRocm93IG5ldyBQYWNrRXJyb3IoJ1pJUCBmaWxlcyBv
dmVyIDQgR2lCIGFyZSBub3Qgc3VwcG9ydGVkJyk7CiAgICBjb25zdCB0YWlsU2l6ZSA9IE1hdGgu
bWluKHNpemUsIDIyICsgNjU1MzUpOwogICAgY29uc3QgdGFpbCA9IEJ1ZmZlci5hbGxvYyh0YWls
U2l6ZSk7CiAgICBhd2FpdCBoYW5kbGUucmVhZCh0YWlsLCAwLCB0YWlsU2l6ZSwgc2l6ZSAtIHRh
aWxTaXplKTsKICAgIGxldCBlbmQgPSAtMTsKICAgIGZvciAobGV0IGF0ID0gdGFpbFNpemUgLSAy
MjsgYXQgPj0gMDsgYXQgLT0gMSkgewogICAgICBpZiAodGFpbC5yZWFkVUludDMyTEUoYXQpID09
PSAweDA2MDU0YjUwICYmIGF0ICsgMjIgKyB0YWlsLnJlYWRVSW50MTZMRShhdCArIDIwKSA9PT0g
dGFpbFNpemUpIHsKICAgICAgICBlbmQgPSBhdDsKICAgICAgICBicmVhazsKICAgICAgfQogICAg
fQogICAgaWYgKGVuZCA8IDApIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoaXMgaXMgbm90IGEgWklQ
IGZpbGUnKTsKICAgIGNvbnN0IGNvdW50ID0gdGFpbC5yZWFkVUludDE2TEUoZW5kICsgMTApOwog
ICAgY29uc3QgZGlyZWN0b3J5U2l6ZSA9IHRhaWwucmVhZFVJbnQzMkxFKGVuZCArIDEyKTsKICAg
IGNvbnN0IGRpcmVjdG9yeU9mZnNldCA9IHRhaWwucmVhZFVJbnQzMkxFKGVuZCArIDE2KTsKICAg
IGlmICh0YWlsLnJlYWRVSW50MTZMRShlbmQgKyA0KSAhPT0gMCB8fCB0YWlsLnJlYWRVSW50MTZM
RShlbmQgKyA4KSAhPT0gY291bnQpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3NwbGl0IFpJUCBmaWxl
cyBhcmUgbm90IHN1cHBvcnRlZCcpOwogICAgaWYgKGNvdW50ID09PSAweGZmZmYgfHwgZGlyZWN0
b3J5U2l6ZSA9PT0gMHhmZmZmZmZmZiB8fCBkaXJlY3RvcnlPZmZzZXQgPT09IDB4ZmZmZmZmZmYp
IHsKICAgICAgdGhyb3cgbmV3IFBhY2tFcnJvcignWklQNjQgZmlsZXMgYXJlIG5vdCBzdXBwb3J0
ZWQnKTsKICAgIH0KICAgIGlmIChkaXJlY3RvcnlPZmZzZXQgKyBkaXJlY3RvcnlTaXplID4gc2l6
ZSkgdGhyb3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgIGNv
bnN0IGRpcmVjdG9yeSA9IEJ1ZmZlci5hbGxvYyhkaXJlY3RvcnlTaXplKTsKICAgIGF3YWl0IGhh
bmRsZS5yZWFkKGRpcmVjdG9yeSwgMCwgZGlyZWN0b3J5U2l6ZSwgZGlyZWN0b3J5T2Zmc2V0KTsK
ICAgIGNvbnN0IGVudHJpZXMgPSBbXTsKICAgIGZvciAobGV0IGF0ID0gMCwgaW5kZXggPSAwOyBp
bmRleCA8IGNvdW50OyBpbmRleCArPSAxKSB7CiAgICAgIGlmIChhdCArIDQ2ID4gZGlyZWN0b3J5
Lmxlbmd0aCB8fCBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0KSAhPT0gMHgwMjAxNGI1MCkgdGhy
b3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgICAgY29uc3Qg
bmFtZUxlbmd0aCA9IGRpcmVjdG9yeS5yZWFkVUludDE2TEUoYXQgKyAyOCk7CiAgICAgIGNvbnN0
IGxlbmd0aCA9IDQ2ICsgbmFtZUxlbmd0aCArIGRpcmVjdG9yeS5yZWFkVUludDE2TEUoYXQgKyAz
MCkgKyBkaXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgMzIpOwogICAgICBpZiAoYXQgKyBsZW5n
dGggPiBkaXJlY3RvcnkubGVuZ3RoKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGUgWklQIGZpbGUg
aXMgZGFtYWdlZCcpOwogICAgICBjb25zdCBmbGFncyA9IGRpcmVjdG9yeS5yZWFkVUludDE2TEUo
YXQgKyA4KTsKICAgICAgY29uc3QgbmFtZSA9IGRpcmVjdG9yeS50b1N0cmluZyhmbGFncyAmIDB4
ODAwID8gJ3V0ZjgnIDogJ2xhdGluMScsIGF0ICsgNDYsIGF0ICsgNDYgKyBuYW1lTGVuZ3RoKTsK
ICAgICAgZW50cmllcy5wdXNoKHsKICAgICAgICBuYW1lLCBmbGFncywgbWV0aG9kOiBkaXJlY3Rv
cnkucmVhZFVJbnQxNkxFKGF0ICsgMTApLAogICAgICAgIGNvbXByZXNzZWRTaXplOiBkaXJlY3Rv
cnkucmVhZFVJbnQzMkxFKGF0ICsgMjApLCBzaXplOiBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0
ICsgMjQpLAogICAgICAgIGxvY2FsT2Zmc2V0OiBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0ICsg
NDIpLCByZWNvcmQ6IEJ1ZmZlci5mcm9tKGRpcmVjdG9yeS5zdWJhcnJheShhdCwgYXQgKyBsZW5n
dGgpKSwKICAgICAgfSk7CiAgICAgIGF0ICs9IGxlbmd0aDsKICAgIH0KICAgIHJldHVybiB7IGVu
dHJpZXMsIHNpemUgfTsKICB9IGZpbmFsbHkgewogICAgYXdhaXQgaGFuZGxlLmNsb3NlKCk7CiAg
fQp9CgovLyBXaGF0IG9mIGEgWklQIGZpbGUgdGhlIGdhbWUgbmVlZHM6IHRoZSBnYW1lIGZvbGRl
ciAodGhlIG9uZSBob2xkaW5nIGRhdGEvZGF0YS50eHQgbmVhcmVzdCB0aGUKLy8gdG9wKSB3aXRo
b3V0IG90aGVyIGNvcGllcyBvZiB0aGUgZ2FtZSBpbnNpZGUgaXQsIHJlY29yZGluZ3MsIG5vdGVz
IGFuZCBvdGhlciBwcm9ncmFtcy4KZnVuY3Rpb24gYW5hbHl6ZVppcChlbnRyaWVzKSB7CiAgY29u
c3QgbG93ZXIgPSAobmFtZSkgPT4gbmFtZS5yZXBsYWNlKC9cXC9nLCAnLycpLnRvTG93ZXJDYXNl
KCk7CiAgbGV0IHJvb3QgPSBudWxsOwogIGZvciAoY29uc3QgZW50cnkgb2YgZW50cmllcykgewog
ICAgY29uc3QgbmFtZSA9IGxvd2VyKGVudHJ5Lm5hbWUpOwogICAgaWYgKG5hbWUgPT09ICdkYXRh
L2RhdGEudHh0JyB8fCBuYW1lLmVuZHNXaXRoKCcvZGF0YS9kYXRhLnR4dCcpKSB7CiAgICAgIGNv
bnN0IGZvbGRlciA9IG5hbWUuc2xpY2UoMCwgbmFtZS5sZW5ndGggLSAnZGF0YS9kYXRhLnR4dCcu
bGVuZ3RoKTsKICAgICAgaWYgKHJvb3QgPT09IG51bGwgfHwgZm9sZGVyLmxlbmd0aCA8IHJvb3Qu
bGVuZ3RoKSByb290ID0gZm9sZGVyOwogICAgfQogIH0KICBpZiAocm9vdCA9PT0gbnVsbCkgdGhy
b3cgbmV3IFBhY2tFcnJvcignbm8gZGF0YS9kYXRhLnR4dCBpbnNpZGU6IHRoaXMgaXMgbm90IGFu
IExGMiBnYW1lIGZvbGRlcicpOwogIGNvbnN0IGluc2lkZSA9IFtdOwogIGZvciAoY29uc3QgZW50
cnkgb2YgZW50cmllcykgewogICAgY29uc3QgbmFtZSA9IGxvd2VyKGVudHJ5Lm5hbWUpOwogICAg
aWYgKCFuYW1lLnN0YXJ0c1dpdGgocm9vdCkgfHwgbmFtZS5lbmRzV2l0aCgnLycpIHx8IG5hbWUu
bGVuZ3RoID09PSByb290Lmxlbmd0aCkgY29udGludWU7CiAgICBpbnNpZGUucHVzaCh7IGVudHJ5
LCBwYXRoOiBuYW1lLnNsaWNlKHJvb3QubGVuZ3RoKSB9KTsKICB9CiAgLy8gQW5vdGhlciBjb3B5
IG9mIGEgZ2FtZSBpbnNpZGUgdGhpcyBvbmUgKGEgc3ViZm9sZGVyIHdpdGggaXRzIG93biBkYXRh
L2RhdGEudHh0KS4KICBjb25zdCBjb3BpZXMgPSBpbnNpZGUuZmlsdGVyKCh7IHBhdGg6IG5hbWUg
fSkgPT4gbmFtZSAhPT0gJ2RhdGEvZGF0YS50eHQnICYmIG5hbWUuZW5kc1dpdGgoJy9kYXRhL2Rh
dGEudHh0JykpCiAgICAubWFwKCh7IHBhdGg6IG5hbWUgfSkgPT4gbmFtZS5zbGljZSgwLCBuYW1l
Lmxlbmd0aCAtICdkYXRhL2RhdGEudHh0Jy5sZW5ndGgpKTsKICBjb25zdCBleGVjdXRhYmxlcyA9
IGluc2lkZS5maWx0ZXIoKHsgcGF0aDogbmFtZSB9KSA9PiAhbmFtZS5pbmNsdWRlcygnLycpICYm
IG5hbWUuZW5kc1dpdGgoJy5leGUnKSk7CiAgaWYgKCFleGVjdXRhYmxlcy5sZW5ndGgpIHRocm93
IG5ldyBQYWNrRXJyb3IoJ25vIGdhbWUgcHJvZ3JhbSAoLmV4ZSkgYmVzaWRlIGl0cyBkYXRhIGZv
bGRlcicpOwogIGNvbnN0IG1haW4gPSBleGVjdXRhYmxlcy5maW5kKCh7IHBhdGg6IG5hbWUgfSkg
PT4gbmFtZSA9PT0gJ2xmMi5leGUnKQogICAgfHwgZXhlY3V0YWJsZXMucmVkdWNlKChsYXJnZXN0
LCBpdGVtKSA9PiAoaXRlbS5lbnRyeS5zaXplID4gbGFyZ2VzdC5lbnRyeS5zaXplID8gaXRlbSA6
IGxhcmdlc3QpKTsKICBjb25zdCBrZWVwID0gW107CiAgZm9yIChjb25zdCBpdGVtIG9mIGluc2lk
ZSkgewogICAgY29uc3QgbmFtZSA9IGl0ZW0ucGF0aDsKICAgIGNvbnN0IHRvcExldmVsID0gIW5h
bWUuaW5jbHVkZXMoJy8nKTsKICAgIGlmIChjb3BpZXMuc29tZSgoY29weSkgPT4gbmFtZS5zdGFy
dHNXaXRoKGNvcHkpKSkgY29udGludWU7CiAgICBpZiAobmFtZS5zdGFydHNXaXRoKCdyZWNvcmRp
bmcvJykpIGNvbnRpbnVlOwogICAgaWYgKHRvcExldmVsICYmIG5hbWUuZW5kc1dpdGgoJy5leGUn
KSAmJiBpdGVtICE9PSBtYWluKSBjb250aW51ZTsKICAgIGlmICh0b3BMZXZlbCAmJiBOT1RFUy50
ZXN0KG5hbWUpKSBjb250aW51ZTsKICAgIGlmIChpdGVtLmVudHJ5LmZsYWdzICYgMSkgdGhyb3cg
bmV3IFBhY2tFcnJvcihgJHtpdGVtLmVudHJ5Lm5hbWV9IGlzIGVuY3J5cHRlZGApOwogICAgaWYg
KGl0ZW0uZW50cnkubWV0aG9kICE9PSAwICYmIGl0ZW0uZW50cnkubWV0aG9kICE9PSA4KSB7CiAg
ICAgIHRocm93IG5ldyBQYWNrRXJyb3IoYCR7aXRlbS5lbnRyeS5uYW1lfSB1c2VzIGEgY29tcHJl
c3Npb24gdGhlIGdhbWUgY2Fubm90IHJlYWQgKHppcCBpdCBhZ2FpbiB3aXRoIERlZmxhdGUpYCk7
CiAgICB9CiAgICBpZiAoaXRlbS5lbnRyeS5zaXplID4gNjQgKiBNSUIpIHRocm93IG5ldyBQYWNr
RXJyb3IoYCR7aXRlbS5lbnRyeS5uYW1lfSBpcyBsYXJnZXIgdGhhbiA2NCBNQmApOwogICAga2Vl
cC5wdXNoKGl0ZW0uZW50cnkpOwogIH0KICByZXR1cm4geyByb290LCBleGVjdXRhYmxlOiBtYWlu
LnBhdGgsIGtlZXAsIGRyb3BwZWQ6IGVudHJpZXMubGVuZ3RoIC0ga2VlcC5sZW5ndGggfTsKfQoK
Ly8gV3JpdGVzIHRoZSBrZXB0IGVudHJpZXMgb2YgYHNvdXJjZWAgYXMgYSBuZXcgWklQIGZpbGUs
IGNvcHlpbmcgdGhlaXIgY29tcHJlc3NlZCBieXRlcyBhcyB0aGV5IGFyZS4KYXN5bmMgZnVuY3Rp
b24gd3JpdGVaaXAoc291cmNlLCB0YXJnZXQsIGtlZXApIHsKICBjb25zdCBpbnB1dCA9IGF3YWl0
IGZzcC5vcGVuKHNvdXJjZSwgJ3InKTsKICBjb25zdCBvdXRwdXQgPSBhd2FpdCBmc3Aub3Blbih0
YXJnZXQsICd3Jyk7CiAgY29uc3QgaGFzaCA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYnKTsK
ICBsZXQgb2Zmc2V0ID0gMDsKICBjb25zdCB3cml0ZSA9IGFzeW5jIChidWZmZXIpID0+IHsKICAg
IGxldCBkb25lID0gMDsKICAgIHdoaWxlIChkb25lIDwgYnVmZmVyLmxlbmd0aCkgewogICAgICBj
b25zdCB7IGJ5dGVzV3JpdHRlbiB9ID0gYXdhaXQgb3V0cHV0LndyaXRlKGJ1ZmZlciwgZG9uZSwg
YnVmZmVyLmxlbmd0aCAtIGRvbmUsIG9mZnNldCArIGRvbmUpOwogICAgICBkb25lICs9IGJ5dGVz
V3JpdHRlbjsKICAgIH0KICAgIGhhc2gudXBkYXRlKGJ1ZmZlcik7CiAgICBvZmZzZXQgKz0gYnVm
ZmVyLmxlbmd0aDsKICB9OwogIHRyeSB7CiAgICBjb25zdCByZWNvcmRzID0gW107CiAgICBmb3Ig
KGNvbnN0IGVudHJ5IG9mIGtlZXApIHsKICAgICAgY29uc3QgaGVhZGVyID0gQnVmZmVyLmFsbG9j
KDMwKTsKICAgICAgYXdhaXQgaW5wdXQucmVhZChoZWFkZXIsIDAsIDMwLCBlbnRyeS5sb2NhbE9m
ZnNldCk7CiAgICAgIGlmIChoZWFkZXIucmVhZFVJbnQzMkxFKDApICE9PSAweDA0MDM0YjUwKSB0
aHJvdyBuZXcgUGFja0Vycm9yKCd0aGUgWklQIGZpbGUgaXMgZGFtYWdlZCcpOwogICAgICBsZXQg
bGVuZ3RoID0gMzAgKyBoZWFkZXIucmVhZFVJbnQxNkxFKDI2KSArIGhlYWRlci5yZWFkVUludDE2
TEUoMjgpICsgZW50cnkuY29tcHJlc3NlZFNpemU7CiAgICAgIGlmIChlbnRyeS5mbGFncyAmIDgp
IHsgLy8gYSBkYXRhIGRlc2NyaXB0b3IgZm9sbG93cyB0aGUgZGF0YQogICAgICAgIGNvbnN0IHBy
b2JlID0gQnVmZmVyLmFsbG9jKDQpOwogICAgICAgIGF3YWl0IGlucHV0LnJlYWQocHJvYmUsIDAs
IDQsIGVudHJ5LmxvY2FsT2Zmc2V0ICsgbGVuZ3RoKTsKICAgICAgICBsZW5ndGggKz0gcHJvYmUu
cmVhZFVJbnQzMkxFKDApID09PSAweDA4MDc0YjUwID8gMTYgOiAxMjsKICAgICAgfQogICAgICBj
b25zdCByZWNvcmQgPSBCdWZmZXIuZnJvbShlbnRyeS5yZWNvcmQpOwogICAgICByZWNvcmQud3Jp
dGVVSW50MzJMRShvZmZzZXQsIDQyKTsKICAgICAgcmVjb3Jkcy5wdXNoKHJlY29yZCk7CiAgICAg
IGZvciAobGV0IGNvcGllZCA9IDA7IGNvcGllZCA8IGxlbmd0aDspIHsKICAgICAgICBjb25zdCBj
aHVuayA9IEJ1ZmZlci5hbGxvYyhNYXRoLm1pbig0ICogTUlCLCBsZW5ndGggLSBjb3BpZWQpKTsK
ICAgICAgICBjb25zdCB7IGJ5dGVzUmVhZCB9ID0gYXdhaXQgaW5wdXQucmVhZChjaHVuaywgMCwg
Y2h1bmsubGVuZ3RoLCBlbnRyeS5sb2NhbE9mZnNldCArIGNvcGllZCk7CiAgICAgICAgaWYgKCFi
eXRlc1JlYWQpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAgZmlsZSBpcyBkYW1hZ2VkJyk7
CiAgICAgICAgYXdhaXQgd3JpdGUoY2h1bmsuc3ViYXJyYXkoMCwgYnl0ZXNSZWFkKSk7CiAgICAg
ICAgY29waWVkICs9IGJ5dGVzUmVhZDsKICAgICAgfQogICAgfQogICAgY29uc3QgZGlyZWN0b3J5
T2Zmc2V0ID0gb2Zmc2V0OwogICAgZm9yIChjb25zdCByZWNvcmQgb2YgcmVjb3JkcykgYXdhaXQg
d3JpdGUocmVjb3JkKTsKICAgIGNvbnN0IGVuZCA9IEJ1ZmZlci5hbGxvYygyMik7CiAgICBlbmQu
d3JpdGVVSW50MzJMRSgweDA2MDU0YjUwLCAwKTsKICAgIGVuZC53cml0ZVVJbnQxNkxFKHJlY29y
ZHMubGVuZ3RoLCA4KTsKICAgIGVuZC53cml0ZVVJbnQxNkxFKHJlY29yZHMubGVuZ3RoLCAxMCk7
CiAgICBlbmQud3JpdGVVSW50MzJMRShvZmZzZXQgLSBkaXJlY3RvcnlPZmZzZXQsIDEyKTsKICAg
IGVuZC53cml0ZVVJbnQzMkxFKGRpcmVjdG9yeU9mZnNldCwgMTYpOwogICAgYXdhaXQgd3JpdGUo
ZW5kKTsKICAgIHJldHVybiB7IHNpemU6IG9mZnNldCwgc2hhMjU2OiBoYXNoLmRpZ2VzdCgnaGV4
JyksIGZpbGVzOiByZWNvcmRzLmxlbmd0aCB9OwogIH0gZmluYWxseSB7CiAgICBhd2FpdCBpbnB1
dC5jbG9zZSgpOwogICAgYXdhaXQgb3V0cHV0LmNsb3NlKCk7CiAgfQp9CgpmdW5jdGlvbiBzYW1l
S2V5KGdpdmVuLCBleHBlY3RlZCkgewogIGNvbnN0IGEgPSBjcnlwdG8uY3JlYXRlSGFzaCgnc2hh
MjU2JykudXBkYXRlKFN0cmluZyhnaXZlbiB8fCAnJykpLmRpZ2VzdCgpOwogIGNvbnN0IGIgPSBj
cnlwdG8uY3JlYXRlSGFzaCgnc2hhMjU2JykudXBkYXRlKFN0cmluZyhleHBlY3RlZCkpLmRpZ2Vz
dCgpOwogIHJldHVybiBjcnlwdG8udGltaW5nU2FmZUVxdWFsKGEsIGIpOwp9CgpmdW5jdGlvbiBj
cmVhdGVQYWNrcyhjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzLCBhbGxvd09yaWdpbiB9KSB7
CiAgY29uc3QgZGlyZWN0b3J5ID0gY29uZmlnLnBhY2tzRGlyOwogIGNvbnN0IGRvd25sb2FkcyA9
IG5ldyBNYXAoKTsgLy8gY2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwgfQogIGNvbnN0
IGZhaWx1cmVzID0gbmV3IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVzcyAtPiB7IGNvdW50LCB1bnRp
bCB9CiAgbGV0IHVwbG9hZGluZyA9IGZhbHNlOwoKICBjb25zdCBqc29uID0gKHJlcywgc3RhdHVz
LCBib2R5LCBoZWFkZXJzID0ge30pID0+IHsKICAgIHJlcy53cml0ZUhlYWQoc3RhdHVzLCB7ICdj
b250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCcsICdjYWNoZS1j
b250cm9sJzogJ25vLXN0b3JlJywgLi4uaGVhZGVycyB9KTsKICAgIHJlcy5lbmQoSlNPTi5zdHJp
bmdpZnkoYm9keSkpOwogIH07CiAgY29uc3QgY291bnRlZCA9IChtYXAsIGFkZHJlc3MsIGxpbWl0
KSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgbGV0IGVudHJ5ID0gbWFwLmdl
dChhZGRyZXNzKTsKICAgIGlmICghZW50cnkgfHwgZW50cnkudW50aWwgPD0gbm93KSB7CiAgICAg
IGVudHJ5ID0geyBjb3VudDogMCwgdW50aWw6IG5vdyArIDM2MDAwMDAgfTsKICAgICAgbWFwLnNl
dChhZGRyZXNzLCBlbnRyeSk7CiAgICB9CiAgICByZXR1cm4geyBvdmVyOiBsaW1pdCA+IDAgJiYg
ZW50cnkuY291bnQgPj0gbGltaXQsIGFkZDogKCkgPT4geyBlbnRyeS5jb3VudCArPSAxOyB9LCBy
ZXRyeTogTWF0aC5jZWlsKChlbnRyeS51bnRpbCAtIG5vdykgLyAxMDAwKSB9OwogIH07CgogIGFz
eW5jIGZ1bmN0aW9uIGxpc3QoKSB7CiAgICBpZiAoIWRpcmVjdG9yeSkgcmV0dXJuIFtdOwogICAg
bGV0IG5hbWVzOwogICAgdHJ5IHsgbmFtZXMgPSBhd2FpdCBmc3AucmVhZGRpcihkaXJlY3Rvcnkp
OyB9IGNhdGNoIHsgcmV0dXJuIFtdOyB9CiAgICBjb25zdCBwYWNrcyA9IFtdOwogICAgZm9yIChj
b25zdCBuYW1lIG9mIG5hbWVzKSB7CiAgICAgIGlmICghbmFtZS5lbmRzV2l0aCgnLmpzb24nKSkg
Y29udGludWU7CiAgICAgIGNvbnN0IGlkID0gbmFtZS5zbGljZSgwLCAtNSk7CiAgICAgIGlmICgh
UEFDS19JRC50ZXN0KGlkKSkgY29udGludWU7CiAgICAgIHRyeSB7CiAgICAgICAgY29uc3QgaW5m
byA9IEpTT04ucGFyc2UoYXdhaXQgZnNwLnJlYWRGaWxlKHBhdGguam9pbihkaXJlY3RvcnksIG5h
bWUpLCAndXRmOCcpKTsKICAgICAgICBjb25zdCBzdGF0ID0gYXdhaXQgZnNwLnN0YXQocGF0aC5q
b2luKGRpcmVjdG9yeSwgYCR7aWR9LnppcGApKTsKICAgICAgICBwYWNrcy5wdXNoKHsgaWQsIHRp
dGxlOiBTdHJpbmcoaW5mby50aXRsZSB8fCBpZCksIHNpemU6IHN0YXQuc2l6ZSwgc2hhMjU2OiBT
dHJpbmcoaW5mby5zaGEyNTYgfHwgJycpLAogICAgICAgICAgZmlsZXM6IGluZm8uZmlsZXMsIHVw
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
u6tuZy4nKTsKICAgICAgY29uc3QgemlwID0gYXdhaXQgcmVhZFppcChyZWNlaXZlZCk7CiAgICAg
IGNvbnN0IGFuYWx5c2lzID0gYW5hbHl6ZVppcCh6aXAuZW50cmllcyk7CiAgICAgIGNvbnN0IHdy
aXR0ZW4gPSBhd2FpdCB3cml0ZVppcChyZWNlaXZlZCwgc2xpbSwgYW5hbHlzaXMua2VlcCk7CiAg
ICAgIGF3YWl0IGZzcC5yZW5hbWUoc2xpbSwgcGF0aC5qb2luKGRpcmVjdG9yeSwgYCR7aWR9Lnpp
cGApKTsKICAgICAgY29uc3QgaW5mbyA9IHsgdGl0bGUsIHNoYTI1Njogd3JpdHRlbi5zaGEyNTYs
IGZpbGVzOiB3cml0dGVuLmZpbGVzLCBleGVjdXRhYmxlOiBhbmFseXNpcy5leGVjdXRhYmxlLAog
ICAgICAgIHVwbG9hZGVkOiBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCksIG9yaWdpbmFsOiB7IHNp
emU6IGJ5dGVzLCBmaWxlczogemlwLmVudHJpZXMubGVuZ3RoIH0gfTsKICAgICAgYXdhaXQgZnNw
LndyaXRlRmlsZShwYXRoLmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uanNvbmApLCBKU09OLnN0cmlu
Z2lmeShpbmZvLCBudWxsLCAyKSk7CiAgICAgIGF3YWl0IGZzcC5ybShyZWNlaXZlZCwgeyBmb3Jj
ZTogdHJ1ZSB9KTsKICAgICAgbG9nKGBwYWNrICR7aWR9OiAke2J5dGVzfSBieXRlcyB1cGxvYWRl
ZCwgJHt3cml0dGVuLnNpemV9IGtlcHQgKCR7d3JpdHRlbi5maWxlc30gZmlsZXMpYCk7CiAgICAg
IGpzb24ocmVzLCAyMDAsIHsgb2s6IHRydWUsIGlkLCB0aXRsZSwgc2l6ZTogd3JpdHRlbi5zaXpl
LCBzaGEyNTY6IHdyaXR0ZW4uc2hhMjU2LCBmaWxlczogd3JpdHRlbi5maWxlcywKICAgICAgICBk
cm9wcGVkOiBhbmFseXNpcy5kcm9wcGVkLCBleGVjdXRhYmxlOiBhbmFseXNpcy5leGVjdXRhYmxl
LCBvcmlnaW5hbDogaW5mby5vcmlnaW5hbCB9KTsKICAgIH0gY2F0Y2ggKGVycm9yKSB7CiAgICAg
IGF3YWl0IGZzcC5ybShyZWNlaXZlZCwgeyBmb3JjZTogdHJ1ZSB9KTsKICAgICAgYXdhaXQgZnNw
LnJtKHNsaW0sIHsgZm9yY2U6IHRydWUgfSk7CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBlcnJvciBp
bnN0YW5jZW9mIFBhY2tFcnJvciA/IGVycm9yLm1lc3NhZ2UgOiAnS2jDtG5nIGzGsHUgxJHGsOG7
o2MgZmlsZTogJyArIChlcnJvci5tZXNzYWdlIHx8IGVycm9yKTsKICAgICAgaWYgKCFyZXMuaGVh
ZGVyc1NlbnQpIGpzb24ocmVzLCBlcnJvciBpbnN0YW5jZW9mIFBhY2tFcnJvciA/IDQwMCA6IDUw
MCwgeyBlcnJvcjogbWVzc2FnZSB9KTsKICAgIH0gZmluYWxseSB7CiAgICAgIHVwbG9hZGluZyA9
IGZhbHNlOwogICAgfQogIH0KCiAgYXN5bmMgZnVuY3Rpb24gc2VydmVQYWNrKHJlcSwgcmVzLCBp
ZCkgewogICAgY29uc3QgaGVhZGVycyA9IHsgJ3gtY29udGVudC10eXBlLW9wdGlvbnMnOiAnbm9z
bmlmZicsIC4uLmFsbG93T3JpZ2luKHJlcSkgfTsKICAgIGlmIChyZXEubWV0aG9kICE9PSAnR0VU
JyAmJiByZXEubWV0aG9kICE9PSAnSEVBRCcpIHsKICAgICAgcmVzLndyaXRlSGVhZCg0MDUsIHsg
Li4uaGVhZGVycywgYWxsb3c6ICdHRVQsIEhFQUQnIH0pOwogICAgICByZXMuZW5kKCk7CiAgICAg
IHJldHVybjsKICAgIH0KICAgIGNvbnN0IGZpbGUgPSBwYXRoLmpvaW4oZGlyZWN0b3J5IHx8ICcv
bm9uZXhpc3RlbnQnLCBgJHtpZH0uemlwYCk7CiAgICBsZXQgc3RhdDsKICAgIHRyeSB7IHN0YXQg
PSBhd2FpdCBmc3Auc3RhdChmaWxlKTsgfSBjYXRjaCB7IHN0YXQgPSBudWxsOyB9CiAgICBpZiAo
IWRpcmVjdG9yeSB8fCAhc3RhdCB8fCAhc3RhdC5pc0ZpbGUoKSkgewogICAgICByZXMud3JpdGVI
ZWFkKDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQog
ICAgaWYgKHJlcS5tZXRob2QgPT09ICdHRVQnKSB7CiAgICAgIGNvbnN0IHF1b3RhID0gY291bnRl
ZChkb3dubG9hZHMsIGNsaWVudEFkZHJlc3MocmVxKSwgY29uZmlnLnBhY2tEb3dubG9hZHNQZXJI
b3VyKTsKICAgICAgaWYgKHF1b3RhLm92ZXIpIHsKICAgICAgICByZXMud3JpdGVIZWFkKDQyOSwg
eyAuLi5oZWFkZXJzLCAncmV0cnktYWZ0ZXInOiBTdHJpbmcocXVvdGEucmV0cnkpIH0pOwogICAg
ICAgIHJlcy5lbmQoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgcXVvdGEuYWRkKCk7
CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBl
JzogJ2FwcGxpY2F0aW9uL3ppcCcsICdjb250ZW50LWxlbmd0aCc6IFN0cmluZyhzdGF0LnNpemUp
LAogICAgICAnY2FjaGUtY29udHJvbCc6ICduby1jYWNoZScgfSk7CiAgICBpZiAocmVxLm1ldGhv
ZCA9PT0gJ0hFQUQnKSB7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
Y29uc3Qgc3RyZWFtID0gZnMuY3JlYXRlUmVhZFN0cmVhbShmaWxlKTsKICAgIHN0cmVhbS5vbign
ZXJyb3InLCAoKSA9PiByZXMuZGVzdHJveSgpKTsKICAgIHN0cmVhbS5waXBlKHJlcyk7CiAgfQoK
ICAvLyBSZXR1cm5zIHRydWUgd2hlbiB0aGUgcmVxdWVzdCB3YXMgb25lIG9mIHRoZSBwYWNrcycg
YW5kIGhhcyBiZWVuIGFuc3dlcmVkIChvciBpcyBiZWluZyBhbnN3ZXJlZCkuCiAgZnVuY3Rpb24g
aGFuZGxlKHJlcSwgcmVzLCBwYXRobmFtZSkgewogICAgaWYgKHBhdGhuYW1lID09PSAnL2xmMi1w
YWNrcy5qc29uJykgewogICAgICBsaXN0KCkudGhlbigocGFja3MpID0+IGpzb24ocmVzLCAyMDAs
IHsgcGFja3M6IHBhY2tzLm1hcCgoeyBpZCwgdGl0bGUsIHNpemUsIHNoYTI1NiB9KSA9PiAoeyBp
ZCwgdGl0bGUsIHNpemUsIHNoYTI1NiB9KSkgfSwKICAgICAgICB7ICdhY2Nlc3MtY29udHJvbC1h
bGxvdy1vcmlnaW4nOiAnKicgfSkpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGNvbnN0
IHBhY2sgPSBwYXRobmFtZS5tYXRjaCgvXlwvbGYyLXBhY2tzXC8oW2EtejAtOV1bYS16MC05LV17
MCwzOX0pXC56aXAkLyk7CiAgICBpZiAocGFjaykgewogICAgICBzZXJ2ZVBhY2socmVxLCByZXMs
IHBhY2tbMV0pLmNhdGNoKCgpID0+IHJlcy5kZXN0cm95KCkpOwogICAgICByZXR1cm4gdHJ1ZTsK
ICAgIH0KICAgIGlmIChwYXRobmFtZSA9PT0gJy9hZG1pbicgfHwgcGF0aG5hbWUgPT09ICcvYWRt
aW4vJykgewogICAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAnY29udGVudC10eXBlJzogJ3RleHQv
aHRtbDsgY2hhcnNldD11dGYtOCcsICdjYWNoZS1jb250cm9sJzogJ25vLXN0b3JlJywKICAgICAg
ICAneC1mcmFtZS1vcHRpb25zJzogJ0RFTlknLCAncmVmZXJyZXItcG9saWN5JzogJ25vLXJlZmVy
cmVyJyB9KTsKICAgICAgcmVzLmVuZChBRE1JTl9QQUdFKTsKICAgICAgcmV0dXJuIHRydWU7CiAg
ICB9CiAgICBpZiAocGF0aG5hbWUgPT09ICcvYWRtaW4vYXBpL3BhY2tzJyAmJiByZXEubWV0aG9k
ID09PSAnR0VUJykgewogICAgICBpZiAoYXV0aG9yaXplZChyZXEsIHJlcykpIGxpc3QoKS50aGVu
KChwYWNrcykgPT4ganNvbihyZXMsIDIwMCwgeyBwYWNrcywgbWF4Qnl0ZXM6IGNvbmZpZy5tYXhQ
YWNrQnl0ZXMgfSkpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGNvbnN0IG1hbmFnZWQg
PSBwYXRobmFtZS5tYXRjaCgvXlwvYWRtaW5cL2FwaVwvcGFja3NcLyhbXi9dKikkLyk7CiAgICBp
ZiAobWFuYWdlZCkgewogICAgICBjb25zdCBpZCA9IG1hbmFnZWRbMV07CiAgICAgIGlmICghUEFD
S19JRC50ZXN0KGlkKSkgewogICAgICAgIGpzb24ocmVzLCA0MDAsIHsgZXJyb3I6ICdNw6Mgbmfh
uq9uIGNo4buJIGfhu5NtIGNo4buvIHRoxrDhu51uZyBhLXosIHPhu5EgdsOgIGThuqV1IGfhuqFj
aCBuZ2FuZyAodOG7kWkgxJFhIDQwIGvDvSB04buxKS4nIH0pOwogICAgICAgIHJldHVybiB0cnVl
OwogICAgICB9CiAgICAgIGlmIChyZXEubWV0aG9kID09PSAnUFVUJykgewogICAgICAgIGlmICgh
YXV0aG9yaXplZChyZXEsIHJlcykpIHsgcmVxLnJlc3VtZSgpOyByZXR1cm4gdHJ1ZTsgfQogICAg
ICAgIGNvbnN0IHRpdGxlID0gU3RyaW5nKG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9yZWxheS5p
bnZhbGlkJykuc2VhcmNoUGFyYW1zLmdldCgndGl0bGUnKSB8fCBpZCkudHJpbSgpLnNsaWNlKDAs
IDYwKSB8fCBpZDsKICAgICAgICB1cGxvYWQocmVxLCByZXMsIGlkLCB0aXRsZSkuY2F0Y2goKCkg
PT4gcmVzLmRlc3Ryb3koKSk7CiAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgIH0KICAgICAgaWYg
KHJlcS5tZXRob2QgPT09ICdERUxFVEUnKSB7CiAgICAgICAgaWYgKCFhdXRob3JpemVkKHJlcSwg
cmVzKSkgcmV0dXJuIHRydWU7CiAgICAgICAgUHJvbWlzZS5hbGwoW2Ake2lkfS56aXBgLCBgJHtp
ZH0uanNvbmBdLm1hcCgobmFtZSkgPT4gZnNwLnJtKHBhdGguam9pbihkaXJlY3RvcnkgfHwgJy9u
b25leGlzdGVudCcsIG5hbWUpLCB7IGZvcmNlOiB0cnVlIH0pKSkKICAgICAgICAgIC50aGVuKCgp
ID0+IHsgbG9nKGBwYWNrICR7aWR9OiByZW1vdmVkYCk7IGpzb24ocmVzLCAyMDAsIHsgb2s6IHRy
dWUgfSk7IH0pCiAgICAgICAgICAuY2F0Y2goKGVycm9yKSA9PiBqc29uKHJlcywgNTAwLCB7IGVy
cm9yOiBTdHJpbmcoZXJyb3IubWVzc2FnZSB8fCBlcnJvcikgfSkpOwogICAgICAgIHJldHVybiB0
cnVlOwogICAgICB9CiAgICAgIGpzb24ocmVzLCA0MDUsIHsgZXJyb3I6ICdtZXRob2Qgbm90IGFs
bG93ZWQnIH0sIHsgYWxsb3c6ICdQVVQsIERFTEVURScgfSk7CiAgICAgIHJldHVybiB0cnVlOwog
ICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KCiAgcmV0dXJuIHsgaGFuZGxlLCBsaXN0LCBjbGVh
bnVwOiAoKSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgZm9yIChjb25zdCBt
YXAgb2YgW2Rvd25sb2FkcywgZmFpbHVyZXNdKSBmb3IgKGNvbnN0IFtrZXksIGVudHJ5XSBvZiBt
YXApIGlmIChlbnRyeS51bnRpbCA8PSBub3cpIG1hcC5kZWxldGUoa2V5KTsKICB9IH07Cn0KCi8v
IFRoZSBwYWdlIGF0IC9hZG1pbiAoVmlldG5hbWVzZTogdGhlIHJlbGF5J3Mgb3duZXIgcmVhZHMg
aXQpLgpjb25zdCBBRE1JTl9QQUdFID0gYDwhZG9jdHlwZSBodG1sPgo8aHRtbCBsYW5nPSJ2aSI+
PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50
PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+Cjx0aXRsZT5PcGVuTEYyIHJl
bGF5OiBi4bqjbiBtb2Q8L3RpdGxlPgo8c3R5bGU+CiAgYm9keSB7IG1hcmdpbjogMDsgcGFkZGlu
ZzogMS41cmVtOyBiYWNrZ3JvdW5kOiAjMTExODI3OyBjb2xvcjogI2YzZjRmNjsgZm9udDogMTZw
eC8xLjUgc3lzdGVtLXVpLCBzYW5zLXNlcmlmOyB9CiAgbWFpbiB7IG1heC13aWR0aDogNzYwcHg7
IG1hcmdpbjogYXV0bzsgfQogIGgxIHsgZm9udC1zaXplOiAxLjVyZW07IG1hcmdpbjogMCAwIC4y
NXJlbTsgfQogIC5jYXJkIHsgYmFja2dyb3VuZDogIzFmMjkzNzsgYm9yZGVyOiAxcHggc29saWQg
IzM3NDE1MTsgYm9yZGVyLXJhZGl1czogMTJweDsgcGFkZGluZzogMXJlbSAxLjJyZW07IG1hcmdp
bjogMXJlbSAwOyB9CiAgbGFiZWwgeyBkaXNwbGF5OiBibG9jazsgbWFyZ2luOiAuNnJlbSAwIC4y
cmVtOyBmb250LXdlaWdodDogNjAwOyB9CiAgaW5wdXRbdHlwZT10ZXh0XSwgaW5wdXRbdHlwZT1w
YXNzd29yZF0geyB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgcGFkZGluZzog
LjVyZW0gLjZyZW07IGZvbnQ6IGluaGVyaXQ7CiAgICBib3JkZXItcmFkaXVzOiA4cHg7IGJvcmRl
cjogMXB4IHNvbGlkICM0YjU1NjM7IGJhY2tncm91bmQ6ICMwYjEyMjA7IGNvbG9yOiBpbmhlcml0
OyB9CiAgYnV0dG9uIHsgcGFkZGluZzogLjU1cmVtIDEuMXJlbTsgZm9udDogaW5oZXJpdDsgYm9y
ZGVyLXJhZGl1czogOHB4OyBib3JkZXI6IDA7IGN1cnNvcjogcG9pbnRlcjsgYmFja2dyb3VuZDog
I2Y1OWUwYjsgY29sb3I6ICMxZjEzMDA7IGZvbnQtd2VpZ2h0OiA3MDA7IH0KICBidXR0b24uc2Vj
b25kYXJ5IHsgYmFja2dyb3VuZDogIzM3NDE1MTsgY29sb3I6ICNmM2Y0ZjY7IGZvbnQtd2VpZ2h0
OiA1MDA7IH0KICBidXR0b246ZGlzYWJsZWQgeyBvcGFjaXR5OiAuNTsgY3Vyc29yOiBkZWZhdWx0
OyB9CiAgcHJvZ3Jlc3MgeyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAuOHJlbTsgbWFyZ2luLXRvcDog
LjhyZW07IH0KICAubm90ZSB7IGNvbG9yOiAjOWNhM2FmOyBmb250LXNpemU6IC45cmVtOyB9CiAg
Lm9rIHsgY29sb3I6ICM2ZWU3Yjc7IH0gLmJhZCB7IGNvbG9yOiAjZmNhNWE1OyB9CiAgdGFibGUg
eyB3aWR0aDogMTAwJTsgYm9yZGVyLWNvbGxhcHNlOiBjb2xsYXBzZTsgfSB0ZCwgdGggeyB0ZXh0
LWFsaWduOiBsZWZ0OyBwYWRkaW5nOiAuNHJlbSAuM3JlbTsgYm9yZGVyLWJvdHRvbTogMXB4IHNv
bGlkICMzNzQxNTE7IHZlcnRpY2FsLWFsaWduOiB0b3A7IH0KICBjb2RlIHsgYmFja2dyb3VuZDog
IzBiMTIyMDsgcGFkZGluZzogLjA1cmVtIC4zcmVtOyBib3JkZXItcmFkaXVzOiA0cHg7IH0KPC9z
dHlsZT48L2hlYWQ+Cjxib2R5PjxtYWluPgogIDxoMT5C4bqjbiBtb2QgY2hvIE9wZW5MRjI8L2gx
PgogIDxwIGNsYXNzPSJub3RlIj5U4bqjaSBsw6puIG3hu5l0IGZpbGUgLnppcCBjaOG7qWEgY+G6
oyB0aMawIG3hu6VjIGdhbWUgY+G7p2EgYuG6o24gbW9kIChjw7MgZmlsZSAuZXhlIHbDoCB0aMaw
IG3hu6VjIGRhdGEsIHNwcml0ZSwgYmdtLCBiZykuCiAgICBSZWxheSBjaOG7iSBnaeG7ryBs4bqh
aSBwaOG6p24gZ2FtZSBj4bqnbiwgcuG7k2kgcGjDoXQgY2hvIHRyw6xuaCBkdXnhu4d0IGPhu6dh
IG5nxrDhu51pIGNoxqFpLiBBaSBjxaluZyBjaOG7jW4gY8O5bmcgbeG7mXQgYuG6o24gbW9kIG3h
u5tpIHbDoG8gY2h1bmcgcGjDsm5nIMSRxrDhu6NjLjwvcD4KICA8ZGl2IGNsYXNzPSJjYXJkIj4K
ICAgIDxsYWJlbCBmb3I9ImtleSI+TcOjIHF14bqjbiB0cuG7iyAoQURNSU5fS0VZKTwvbGFiZWw+
CiAgICA8aW5wdXQgaWQ9ImtleSIgdHlwZT0icGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0iY3VycmVu
dC1wYXNzd29yZCIgcGxhY2Vob2xkZXI9ImluIHJhIGtoaSBjaOG6oXkgaW5zdGFsbC12cHMuc2gi
PgogICAgPGxhYmVsIGZvcj0iZmlsZSI+RmlsZSAuemlwIGPhu6dhIGLhuqNuIG1vZDwvbGFiZWw+
CiAgICA8aW5wdXQgaWQ9ImZpbGUiIHR5cGU9ImZpbGUiIGFjY2VwdD0iLnppcCxhcHBsaWNhdGlv
bi96aXAiPgogICAgPGxhYmVsIGZvcj0idGl0bGUiPlTDqm4gaGnhu4NuIHRo4buLIHRyw6puIHRy
YW5nIGdhbWU8L2xhYmVsPgogICAgPGlucHV0IGlkPSJ0aXRsZSIgdHlwZT0idGV4dCIgbWF4bGVu
Z3RoPSI2MCIgcGxhY2Vob2xkZXI9InbDrSBk4bulOiBPbmUgUGllY2UgR3JhbmRXb3JsZCI+CiAg
ICA8bGFiZWwgZm9yPSJpZCI+TcOjIG5n4bqvbiAoZMO5bmcgdHJvbmcgbGluayBt4budaSk8L2xh
YmVsPgogICAgPGlucHV0IGlkPSJpZCIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI0MCIgcGxhY2Vo
b2xkZXI9InbDrSBk4bulOiBvbmVwaWVjZSIgcGF0dGVybj0iW2EtejAtOV1bYS16MC05LV0qIj4K
ICAgIDxwPjxidXR0b24gaWQ9InVwbG9hZCI+VOG6o2kgbMOqbjwvYnV0dG9uPjwvcD4KICAgIDxw
cm9ncmVzcyBpZD0icHJvZ3Jlc3MiIGhpZGRlbj48L3Byb2dyZXNzPgogICAgPHAgaWQ9InN0YXR1
cyIgcm9sZT0ic3RhdHVzIiBjbGFzcz0ibm90ZSI+PC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9
ImNhcmQiPgogICAgPGgyIHN0eWxlPSJmb250LXNpemU6MS4xNXJlbTttYXJnaW46MCAwIC41cmVt
Ij5Dw6FjIGLhuqNuIG1vZCB0csOqbiByZWxheTwvaDI+CiAgICA8cD48YnV0dG9uIGlkPSJyZWZy
ZXNoIiBjbGFzcz0ic2Vjb25kYXJ5Ij5YZW0gZGFuaCBzw6FjaDwvYnV0dG9uPjwvcD4KICAgIDx0
YWJsZT48dGJvZHkgaWQ9Imxpc3QiPjwvdGJvZHk+PC90YWJsZT4KICA8L2Rpdj4KPC9tYWluPgo8
c2NyaXB0PgogIGNvbnN0ICQgPSAoaWQpID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsK
ICBjb25zdCBhcGkgPSBsb2NhdGlvbi5wYXRobmFtZS5yZXBsYWNlKC9cXC8/JC8sICcvJykgKyAn
YXBpL3BhY2tzJzsKICB0cnkgeyAkKCdrZXknKS52YWx1ZSA9IGxvY2FsU3RvcmFnZS5nZXRJdGVt
KCdsZjItYWRtaW4ta2V5JykgfHwgJyc7IH0gY2F0Y2ggKGVycm9yKSB7fQogIGNvbnN0IHJlbWVt
YmVyID0gKCkgPT4geyB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnbGYyLWFkbWluLWtleScs
ICQoJ2tleScpLnZhbHVlKTsgfSBjYXRjaCAoZXJyb3IpIHt9IH07CiAgY29uc3Qgc2x1ZyA9ICh0
ZXh0KSA9PiB0ZXh0LnRvTG93ZXJDYXNlKCkubm9ybWFsaXplKCdORkQnKS5yZXBsYWNlKC9bXFx1
MDMwMC1cXHUwMzZmXS9nLCAnJykucmVwbGFjZSgvxJEvZywgJ2QnKQogICAgLnJlcGxhY2UoL1te
YS16MC05XSsvZywgJy0nKS5yZXBsYWNlKC9eLSt8LSskL2csICcnKS5zbGljZSgwLCA0MCkgfHwg
J21vZCc7CiAgJCgnZmlsZScpLmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsICgpID0+IHsKICAg
IGNvbnN0IGZpbGUgPSAkKCdmaWxlJykuZmlsZXNbMF07CiAgICBpZiAoIWZpbGUpIHJldHVybjsK
ICAgIGNvbnN0IG5hbWUgPSBmaWxlLm5hbWUucmVwbGFjZSgvXFwuemlwJC9pLCAnJykucmVwbGFj
ZSgvW19dKy9nLCAnICcpLnRyaW0oKTsKICAgIGlmICghJCgndGl0bGUnKS52YWx1ZSkgJCgndGl0
bGUnKS52YWx1ZSA9IG5hbWU7CiAgICBpZiAoISQoJ2lkJykudmFsdWUpICQoJ2lkJykudmFsdWUg
PSBzbHVnKG5hbWUpOwogIH0pOwogICQoJ3RpdGxlJykuYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQn
LCAoKSA9PiB7IGlmICghJCgnaWQnKS5kYXRhc2V0LnRvdWNoZWQpICQoJ2lkJykudmFsdWUgPSBz
bHVnKCQoJ3RpdGxlJykudmFsdWUpOyB9KTsKICAkKCdpZCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2lu
cHV0JywgKCkgPT4geyAkKCdpZCcpLmRhdGFzZXQudG91Y2hlZCA9ICcxJzsgfSk7CiAgY29uc3Qg
bWIgPSAoYnl0ZXMpID0+IChieXRlcyAvIDFlNikudG9GaXhlZCgxKSArICcgTUInOwogIGZ1bmN0
aW9uIHN0YXR1cyh0ZXh0LCBraW5kKSB7ICQoJ3N0YXR1cycpLnRleHRDb250ZW50ID0gdGV4dDsg
JCgnc3RhdHVzJykuY2xhc3NOYW1lID0ga2luZCB8fCAnbm90ZSc7IH0KICAkKCd1cGxvYWQnKS5h
ZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IHsKICAgIGNvbnN0IGZpbGUgPSAkKCdmaWxl
JykuZmlsZXNbMF07CiAgICBjb25zdCBpZCA9ICQoJ2lkJykudmFsdWUudHJpbSgpOwogICAgaWYg
KCEkKCdrZXknKS52YWx1ZSkgcmV0dXJuIHN0YXR1cygnTmjhuq1wIG3DoyBxdeG6o24gdHLhu4sg
dHLGsOG7m2MuJywgJ2JhZCcpOwogICAgaWYgKCFmaWxlKSByZXR1cm4gc3RhdHVzKCdDaOG7jW4g
ZmlsZSAuemlwIHRyxrDhu5tjLicsICdiYWQnKTsKICAgIGlmICghL15bYS16MC05XVthLXowLTkt
XXswLDM5fSQvLnRlc3QoaWQpKSByZXR1cm4gc3RhdHVzKCdNw6Mgbmfhuq9uIGNo4buJIGfhu5Nt
IGNo4buvIHRoxrDhu51uZyBhLXosIHPhu5EgdsOgIGThuqV1IGfhuqFjaCBuZ2FuZy4nLCAnYmFk
Jyk7CiAgICByZW1lbWJlcigpOwogICAgY29uc3QgcmVxdWVzdCA9IG5ldyBYTUxIdHRwUmVxdWVz
dCgpOwogICAgcmVxdWVzdC5vcGVuKCdQVVQnLCBhcGkgKyAnLycgKyBpZCArICc/dGl0bGU9JyAr
IGVuY29kZVVSSUNvbXBvbmVudCgkKCd0aXRsZScpLnZhbHVlLnRyaW0oKSB8fCBpZCkpOwogICAg
cmVxdWVzdC5zZXRSZXF1ZXN0SGVhZGVyKCd4LWFkbWluLWtleScsICQoJ2tleScpLnZhbHVlKTsK
ICAgIHJlcXVlc3Quc2V0UmVxdWVzdEhlYWRlcignY29udGVudC10eXBlJywgJ2FwcGxpY2F0aW9u
L3ppcCcpOwogICAgJCgncHJvZ3Jlc3MnKS5oaWRkZW4gPSBmYWxzZTsKICAgICQoJ3VwbG9hZCcp
LmRpc2FibGVkID0gdHJ1ZTsKICAgIHJlcXVlc3QudXBsb2FkLm9ucHJvZ3Jlc3MgPSAoZXZlbnQp
ID0+IHsKICAgICAgaWYgKCFldmVudC5sZW5ndGhDb21wdXRhYmxlKSByZXR1cm47CiAgICAgICQo
J3Byb2dyZXNzJykubWF4ID0gZXZlbnQudG90YWw7CiAgICAgICQoJ3Byb2dyZXNzJykudmFsdWUg
PSBldmVudC5sb2FkZWQ7CiAgICAgIHN0YXR1cygnxJBhbmcgdOG6o2kgbMOqbjogJyArIG1iKGV2
ZW50LmxvYWRlZCkgKyAnIC8gJyArIG1iKGV2ZW50LnRvdGFsKSArIChldmVudC5sb2FkZWQgPT09
IGV2ZW50LnRvdGFsID8gJyAocmVsYXkgxJFhbmcgeOG7rSBsw70uLi4pJyA6ICcnKSk7CiAgICB9
OwogICAgcmVxdWVzdC5vbmxvYWQgPSAoKSA9PiB7CiAgICAgICQoJ3VwbG9hZCcpLmRpc2FibGVk
ID0gZmFsc2U7CiAgICAgICQoJ3Byb2dyZXNzJykuaGlkZGVuID0gdHJ1ZTsKICAgICAgbGV0IGJv
ZHkgPSB7fTsKICAgICAgdHJ5IHsgYm9keSA9IEpTT04ucGFyc2UocmVxdWVzdC5yZXNwb25zZVRl
eHQpOyB9IGNhdGNoIChlcnJvcikge30KICAgICAgaWYgKHJlcXVlc3Quc3RhdHVzID09PSAyMDAp
IHsKICAgICAgICBzdGF0dXMoJ1hvbmc6ICInICsgYm9keS50aXRsZSArICciICgnICsgbWIoYm9k
eS5zaXplKSArICcsICcgKyBib2R5LmZpbGVzICsgJyBmaWxlLCBi4buPIGLhu5t0ICcgKyBib2R5
LmRyb3BwZWQgKyAnIGZpbGUga2jDtG5nIGPhuqduKS4gJwogICAgICAgICAgKyAnVHLDqm4gdHJh
bmcgZ2FtZSwgY2jhu41uIG7DsyDhu58gbeG7pWMgR2FtZSwgaG/hurdjIGfhu61pIGxpbmsgbeG7
nWkgY8OzIHRow6ptICZwYWNrPScgKyBib2R5LmlkICsgJy4nLCAnb2snKTsKICAgICAgICByZWZy
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
IHdyaXRlWmlwLCBQYWNrRXJyb3IsIFBBQ0tfSUQgfTsK
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
