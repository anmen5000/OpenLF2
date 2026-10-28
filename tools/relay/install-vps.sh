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
# It also keeps a copy of the original LF2 v2.0a installer (freeware, by Marti Wong and Starsky
# Wong; checked by SHA-256 as the game does), which the relay serves to the game page as
# /lf2-installer.data: players then need no download manager workaround, and the page falls back to
# archive.org when the copy is missing.
#
# Everything lives in /opt/lf2-relay plus two services, lf2-relay and lf2-caddy. The relay's own
# files are embedded below (update-installer.js writes them), so this file is all a server needs.
# Messages are Vietnamese without diacritics, so that every terminal shows them.
set -euo pipefail

INSTALLER_VERSION=3
CADDY_MODE=full # check_ports decides
HAVE_DATA=0     # install_game_data decides
PREFIX=${LF2_PREFIX:-/opt/lf2-relay}
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
ExecStart=$PREFIX/node/bin/node $PREFIX/app/server.js
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
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

# Sets CADDY_MODE: "full" when ports 80 and 443 are free, "tls-only" when another program keeps
# port 80 (it is left alone). Stops with an explanation when port 443 is taken.
check_ports() {
	local listening="" owner80="" owner443=""
	CADDY_MODE=full
	if command -v ss >/dev/null 2>&1; then
		listening=$(ss -ltnp 2>/dev/null || true)
		owner80=$(other_owner "$listening" 80)
		owner443=$(other_owner "$listening" 443)
	fi
	[ -z "$owner443" ] || port_443_taken "$owner443"
	if [ -n "$owner80" ]; then
		CADDY_MODE=tls-only
		info "Cong 80 dang do \"$owner80\" dung: giu nguyen, khong dong cham toi."
		info "Relay se chi dung cong 443."
	fi
}

port_443_taken() { # owner
	{
		printf '\n[LOI] Cong 443 (HTTPS) dang duoc chuong trinh "%s" dung.\n' "$1"
		printf '      Relay can rieng cong 443, nen chua cai duoc. Chua co gi bi thay doi.\n'
		if [ "$1" = httpd ] && command -v httpd >/dev/null 2>&1; then
			printf '      Website ma httpd dang chay:\n'
			httpd -S 2>/dev/null | grep -oE '(namevhost|default server) [^ ]+' | awk '{print "         " $NF}' | sort -u || true
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

uninstall() {
	say "Go relay"
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
	check_ports

	if [ -z "${DOMAIN:-}" ]; then
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
	ensure_user lf2caddy "$PREFIX/caddy-data"
	install_app
	info "Relay da cai vao $PREFIX/app"

	say "Luu du lieu game LF2 tren VPS (khoang 30 MB)"
	install_game_data

	say "Cai Caddy (HTTPS)"
	install_caddy

	say "Mo $(caddy_ports)"
	open_firewall

	say "Khoi dong dich vu"
	write_units
	"$SYSTEMCTL" daemon-reload
	"$SYSTEMCTL" enable lf2-relay.service lf2-caddy.service >/dev/null 2>&1 ||
		fail "Khong bat duoc dich vu. Gui thong bao nay cho nguoi huong dan ban."
	"$SYSTEMCTL" restart lf2-relay.service
	wait_for "http://127.0.0.1:$RELAY_PORT/healthz" 30 ||
		fail "Relay khong chay. Xem loi bang lenh: journalctl -u lf2-relay -n 30 --no-pager"
	info "Relay dang chay"
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
============================================================
EOF
	if [ "$CADDY_MODE" = tls-only ]; then
		info "Ghi chu: website dang chay o cong 80 van giu nguyen; relay chi dung cong 443."
	fi
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
IHNvY2tldHMsIHNvIE9wZW5MRjIncyB3ZWIgYnVpbGQgc2VuZHMgaXRzIG5ldHdvcmsgYnl0ZSBz
dHJlYW0gb3ZlcgovLyBhIFdlYlNvY2tldCB0byB0aGlzIHJlbGF5IGluc3RlYWQuIFRoZSByZWxh
eSBwYWlycyB0d28gcGxheWVycyBieSBhIG51bWVyaWMgcm9vbSBjb2RlIGFuZCBjb3BpZXMKLy8g
YmluYXJ5IGZyYW1lcyBmcm9tIG9uZSB0byB0aGUgb3RoZXIgdW5jaGFuZ2VkLiBUaGUgZ2FtZSdz
IG93biBsb2Nrc3RlcCBwcm90b2NvbCAoaGFuZHNoYWtlLAovLyByYW5kb20gdGFibGUsIG9uZSAy
Mi1ieXRlIGlucHV0IHBhY2tldCBwZXIgZnJhbWUpIHJ1bnMgb24gdG9wOyB0aGUgcmVsYXkgbmV2
ZXIgcGFyc2VzIG9yIHN0b3JlcyBpdC4KLy8KLy8gICB3cyhzKTovLzxzZXJ2ZXI+L3JlbGF5P3Jv
bGU9aG9zdCZyb29tPTQ4MjkxMyAgIE5ldHdvcmsgR2FtZSA+IEhvc3QKLy8gICB3cyhzKTovLzxz
ZXJ2ZXI+L3JlbGF5P3JvbGU9am9pbiZyb29tPTQ4MjkxMyAgIE5ldHdvcmsgR2FtZSA+IENvbm5l
Y3QsIHJvb20gY29kZSBhcyB0aGUgYWRkcmVzcwovLwovLyBFaXRoZXIgc2lkZSBtYXkgYXJyaXZl
IGZpcnN0LiBTZXJ2ZXItdG8tY2xpZW50IGNvbnRyb2wgbWVzc2FnZXMgYXJlIEpTT04gdGV4dCBm
cmFtZXM6Ci8vICAgeyJ0Ijoid2FpdGluZyIsInJvb20iOiI0ODI5MTMifSAgIHJlZ2lzdGVyZWQs
IHdhaXRpbmcgZm9yIHRoZSBvdGhlciBwbGF5ZXIKLy8gICB7InQiOiJwYWlyZWQifSAgICAgICAg
ICAgICAgICAgICAgYm90aCBwbGF5ZXJzIGFyZSBwcmVzZW50OyBiaW5hcnkgZnJhbWVzIG5vdyBm
bG93Ci8vIFByb2JsZW1zIGNsb3NlIHRoZSBzb2NrZXQgd2l0aCBhIDR4eHggY29kZSBhbmQgYSBz
aG9ydCBBU0NJSSByZWFzb24sIHdoaWNoIHRoZSBnYW1lIHNob3dzLgovLwovLyBXaXRoIElOU1RB
TExFUl9GSUxFIHNldCAoaW5zdGFsbC12cHMuc2ggZG9lcyksIHRoZSByZWxheSBhbHNvIHNlcnZl
cyBpdHMgY29weSBvZiB0aGUgb3JpZ2luYWwgTEYyCi8vIHYyLjBhIGluc3RhbGxlciBhdCAvbGYy
LWluc3RhbGxlci5kYXRhLCB3aGljaCB0aGUgZ2FtZSBwYWdlIGRvd25sb2FkcyBiZWZvcmUgdHJ5
aW5nIGFyY2hpdmUub3JnOgovLyBkb3dubG9hZCBtYW5hZ2VycyBzdWNoIGFzIElETSBsZXQgdGhh
dCBuYW1lIHRocm91Z2gsIHdoaWxlIHRoZXkgdGFrZSBvdmVyIHRoZSAuZXhlIGZyb20gYXJjaGl2
ZS5vcmcuCid1c2Ugc3RyaWN0JzsKCmNvbnN0IGZzID0gcmVxdWlyZSgnbm9kZTpmcycpOwpjb25z
dCBodHRwID0gcmVxdWlyZSgnbm9kZTpodHRwJyk7CmNvbnN0IHsgV2ViU29ja2V0U2VydmVyLCBX
ZWJTb2NrZXQgfSA9IHJlcXVpcmUoJ3dzJyk7Cgpjb25zdCBJTlNUQUxMRVJfUEFUSCA9ICcvbGYy
LWluc3RhbGxlci5kYXRhJzsKCmNvbnN0IFJPT01fUEFUVEVSTiA9IC9eXGR7NCwxMn0kLzsKCi8v
IENsb3NlIGNvZGVzIGFyZSBwYXJ0IG9mIHRoZSBjb250cmFjdCB3aXRoIG9ubGluZS5qcyAoaXQg
bWFwcyB0aGVtIHRvIG1lc3NhZ2VzIHRvbykuCmNvbnN0IENMT1NFID0gT2JqZWN0LmZyZWV6ZSh7
CiAgYmFkUmVxdWVzdDogWzQwMDAsICdSZWxheTogYmFkIHJlcXVlc3QnXSwKICBvcmlnaW5EZW5p
ZWQ6IFs0MDAxLCAnUmVsYXk6IHRoaXMgd2Vic2l0ZSBtYXkgbm90IHVzZSB0aGUgcmVsYXknXSwK
ICB0b29NYW55Q29ubmVjdGlvbnM6IFs0MDAyLCAnUmVsYXk6IHRvbyBtYW55IGNvbm5lY3Rpb25z
IGZyb20geW91ciBuZXR3b3JrJ10sCiAgc2VydmVyRnVsbDogWzQwMDMsICdSZWxheTogc2VydmVy
IGlzIGZ1bGwnXSwKICBob3N0VGFrZW46IFs0MDA0LCAnUmVsYXk6IHJvb20gYWxyZWFkeSBoYXMg
YSBob3N0J10sCiAgZ3Vlc3RUYWtlbjogWzQwMDQsICdSZWxheTogcm9vbSBhbHJlYWR5IGhhcyBh
IGd1ZXN0J10sCiAgdGltZW91dDogWzQwMDUsICdSZWxheTogbm9ib2R5IGpvaW5lZCBpbiB0aW1l
J10sCiAgcGVlckxlZnQ6IFs0MDA2LCAnUmVsYXk6IHRoZSBvdGhlciBwbGF5ZXIgbGVmdCddLAog
IHJhdGVMaW1pdGVkOiBbNDAwNywgJ1JlbGF5OiB0b28gbXVjaCB0cmFmZmljJ10sCiAgc2xvd1Bl
ZXI6IFs0MDA4LCAnUmVsYXk6IHRoZSBvdGhlciBwbGF5ZXIgc3RvcHBlZCByZWFkaW5nJ10sCiAg
ZWFybHlEYXRhOiBbNDAwOSwgJ1JlbGF5OiBkYXRhIHNlbnQgYmVmb3JlIHBhaXJpbmcnXSwKICBz
aHV0ZG93bjogWzEwMDEsICdSZWxheTogc2VydmVyIGlzIHJlc3RhcnRpbmcnXSwKfSk7CgpmdW5j
dGlvbiByZWFkQ29uZmlnKGVudiA9IHByb2Nlc3MuZW52KSB7CiAgY29uc3QgbnVtYmVyID0gKG5h
bWUsIGZhbGxiYWNrKSA9PiB7CiAgICBjb25zdCByYXcgPSBlbnZbbmFtZV07CiAgICBjb25zdCB2
YWx1ZSA9IHJhdyA9PT0gdW5kZWZpbmVkIHx8IHJhdyA9PT0gJycgPyBmYWxsYmFjayA6IE51bWJl
cihyYXcpOwogICAgaWYgKCFOdW1iZXIuaXNGaW5pdGUodmFsdWUpIHx8IHZhbHVlIDwgMCkgdGhy
b3cgbmV3IEVycm9yKGAke25hbWV9IG11c3QgYmUgYSBub24tbmVnYXRpdmUgbnVtYmVyYCk7CiAg
ICByZXR1cm4gdmFsdWU7CiAgfTsKICByZXR1cm4gewogICAgcG9ydDogbnVtYmVyKCdQT1JUJywg
ODc4NyksCiAgICBob3N0OiBlbnYuSE9TVCB8fCAnMC4wLjAuMCcsCiAgICBwYXRoOiBlbnYuUkVM
QVlfUEFUSCB8fCAnL3JlbGF5JywKICAgIC8vIENvbW1hLXNlcGFyYXRlZCBwYWdlIG9yaWdpbnMg
YWxsb3dlZCB0byBjb25uZWN0LCBlLmcuICJodHRwczovL3lvdS5naXRodWIuaW8iLiBFbXB0eSBh
bGxvd3MgYW55LgogICAgYWxsb3dlZE9yaWdpbnM6IChlbnYuQUxMT1dFRF9PUklHSU5TIHx8ICcn
KS5zcGxpdCgnLCcpLm1hcChub3JtYWxpemVPcmlnaW4pLmZpbHRlcihCb29sZWFuKSwKICAgIC8v
IEJlaGluZCBhIHJldmVyc2UgcHJveHkgKENhZGR5LCBuZ2lueCwgQ2xvdWRmbGFyZSksIHRha2Ug
dGhlIGNsaWVudCBhZGRyZXNzIGZyb20gWC1Gb3J3YXJkZWQtRm9yLgogICAgdHJ1c3RQcm94eTog
ZW52LlRSVVNUX1BST1hZID09PSAnMScgfHwgZW52LlRSVVNUX1BST1hZID09PSAndHJ1ZScsCiAg
ICBtYXhSb29tczogbnVtYmVyKCdNQVhfUk9PTVMnLCA1MDApLCAvLyAwID0gdW5saW1pdGVkCiAg
ICBtYXhDb25uZWN0aW9uc1BlcklwOiBudW1iZXIoJ01BWF9DT05ORUNUSU9OU19QRVJfSVAnLCA4
KSwgLy8gMCA9IHVubGltaXRlZAogICAgcm9vbVdhaXRNczogbnVtYmVyKCdST09NX1dBSVRfTVMn
LCAxMjAwMDApLAogICAgcGluZ0ludGVydmFsTXM6IG51bWJlcignUElOR19JTlRFUlZBTF9NUycs
IDE1MDAwKSwKICAgIG1heE1lc3NhZ2VCeXRlczogbnVtYmVyKCdNQVhfTUVTU0FHRV9CWVRFUycs
IDY1NTM2KSwgLy8gdGhlIGdhbWUgcXVldWVzIGF0IG1vc3QgNjQgS2lCCiAgICBtZXNzYWdlc1Bl
clNlY29uZDogbnVtYmVyKCdNRVNTQUdFU19QRVJfU0VDT05EJywgMjQwKSwgLy8gdGhlIGdhbWUg
c2VuZHMgfjMwIHBlciBzZWNvbmQ7IDAgPSB1bmxpbWl0ZWQKICAgIGJ5dGVzUGVyU2Vjb25kOiBu
dW1iZXIoJ0JZVEVTX1BFUl9TRUNPTkQnLCAxMzEwNzIpLCAvLyAwID0gdW5saW1pdGVkCiAgICBt
YXhCdWZmZXJlZEJ5dGVzOiBudW1iZXIoJ01BWF9CVUZGRVJFRF9CWVRFUycsIDEwNDg1NzYpLAog
ICAgLy8gVGVzdGluZyBhaWQ6IGhvbGQgZXZlcnkgZm9yd2FyZGVkIGZyYW1lIHRoaXMgbG9uZywg
dG8gZmVlbCBob3cgYSBkaXN0YW50IHJlbGF5IHdvdWxkIHBsYXkuCiAgICBmb3J3YXJkRGVsYXlN
czogbnVtYmVyKCdGT1JXQVJEX0RFTEFZX01TJywgMCksCiAgICAvLyBUaGUgTEYyIGluc3RhbGxl
ciBzZXJ2ZWQgYXQgL2xmMi1pbnN0YWxsZXIuZGF0YSAoZW1wdHk6IG5vdCBzZXJ2ZWQpLCBhbmQg
aG93IG9mdGVuIG9uZSBjbGllbnQKICAgIC8vIGFkZHJlc3MgbWF5IGRvd25sb2FkIGl0IChhYm91
dCAzMCBNQiBlYWNoIHRpbWU7IGJyb3dzZXJzIGtlZXAgaXQgYWZ0ZXIgdGhlIGZpcnN0IHRpbWUp
LgogICAgaW5zdGFsbGVyRmlsZTogZW52LklOU1RBTExFUl9GSUxFIHx8ICcnLAogICAgaW5zdGFs
bGVyRG93bmxvYWRzUGVySG91cjogbnVtYmVyKCdJTlNUQUxMRVJfRE9XTkxPQURTX1BFUl9IT1VS
JywgMjApLCAvLyAwID0gdW5saW1pdGVkCiAgICBxdWlldDogZW52LlFVSUVUID09PSAnMScgfHwg
ZW52LlFVSUVUID09PSAndHJ1ZScsCiAgfTsKfQoKZnVuY3Rpb24gbm9ybWFsaXplT3JpZ2luKHZh
bHVlKSB7CiAgcmV0dXJuIFN0cmluZyh2YWx1ZSB8fCAnJykudHJpbSgpLnJlcGxhY2UoL1wvKyQv
LCAnJykudG9Mb3dlckNhc2UoKTsKfQoKLy8gVG9rZW4gYnVja2V0OiBgcmF0ZWAgdW5pdHMgcGVy
IHNlY29uZCwgYnVyc3RzIHVwIHRvIGBjYXBhY2l0eWAuIEEgcmF0ZSBvZiAwIGRpc2FibGVzIHRo
ZSBsaW1pdC4KY2xhc3MgQnVja2V0IHsKICBjb25zdHJ1Y3RvcihyYXRlLCBjYXBhY2l0eSkgewog
ICAgdGhpcy5yYXRlID0gcmF0ZTsKICAgIHRoaXMuY2FwYWNpdHkgPSBNYXRoLm1heChjYXBhY2l0
eSwgcmF0ZSk7CiAgICB0aGlzLnRva2VucyA9IHRoaXMuY2FwYWNpdHk7CiAgICB0aGlzLmxhc3Qg
PSBEYXRlLm5vdygpOwogIH0KICB0YWtlKGFtb3VudCkgewogICAgaWYgKHRoaXMucmF0ZSA9PT0g
MCkgcmV0dXJuIHRydWU7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgdGhpcy50b2tl
bnMgPSBNYXRoLm1pbih0aGlzLmNhcGFjaXR5LCB0aGlzLnRva2VucyArICgobm93IC0gdGhpcy5s
YXN0KSAqIHRoaXMucmF0ZSkgLyAxMDAwKTsKICAgIHRoaXMubGFzdCA9IG5vdzsKICAgIGlmICh0
aGlzLnRva2VucyA8IGFtb3VudCkgcmV0dXJuIGZhbHNlOwogICAgdGhpcy50b2tlbnMgLT0gYW1v
dW50OwogICAgcmV0dXJuIHRydWU7CiAgfQp9CgpmdW5jdGlvbiBjcmVhdGVSZWxheShvdmVycmlk
ZXMgPSB7fSkgewogIGNvbnN0IGNvbmZpZyA9IHsgLi4ucmVhZENvbmZpZyh7fSksIC4uLm92ZXJy
aWRlcyB9OwogIGNvbnN0IHJvb21zID0gbmV3IE1hcCgpOyAvLyBjb2RlIC0+IHsgY29kZSwgaG9z
dCwgam9pbiwgdGltZXIgfQogIGNvbnN0IGNvbm5lY3Rpb25zUGVySXAgPSBuZXcgTWFwKCk7CiAg
Y29uc3QgbG9nID0gKC4uLnBhcnRzKSA9PiB7IGlmICghY29uZmlnLnF1aWV0KSBjb25zb2xlLmxv
ZyhuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCksIC4uLnBhcnRzKTsgfTsKCiAgY29uc3QgaW5zdGFs
bGVyRG93bmxvYWRzID0gbmV3IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVzcyAtPiB7IGNvdW50LCB1
bnRpbCB9CiAgY29uc3QgaW5zdGFsbGVyUGF0aHMgPSBuZXcgU2V0KFtJTlNUQUxMRVJfUEFUSCwg
Y29uZmlnLnBhdGgucmVwbGFjZSgvW14vXSokLywgSU5TVEFMTEVSX1BBVEguc2xpY2UoMSkpXSk7
CgogIGNvbnN0IHNlcnZlciA9IGh0dHAuY3JlYXRlU2VydmVyKChyZXEsIHJlcykgPT4gewogICAg
Y29uc3QgeyBwYXRobmFtZSB9ID0gbmV3IFVSTChyZXEudXJsLCAnaHR0cDovL3JlbGF5LmludmFs
aWQnKTsKICAgIGlmIChwYXRobmFtZSA9PT0gJy9oZWFsdGh6JykgewogICAgICAvLyBSZWFkYWJs
ZSBmcm9tIHRoZSBnYW1lIHBhZ2UgKGFub3RoZXIgb3JpZ2luKSBzbyBpdHMgT25saW5lIHBhbmVs
IGNhbiBzaG93ICJyZWxheSBPSyIuCiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7CiAgICAgICAg
J2NvbnRlbnQtdHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJywKICAgICAgICAnY2FjaGUtY29udHJv
bCc6ICduby1zdG9yZScsCiAgICAgICAgJ2FjY2Vzcy1jb250cm9sLWFsbG93LW9yaWdpbic6ICcq
JywKICAgICAgfSk7CiAgICAgIHJlcy5lbmQoSlNPTi5zdHJpbmdpZnkoeyBvazogdHJ1ZSwgcm9v
bXM6IHJvb21zLnNpemUsIGNsaWVudHM6IHdzcy5jbGllbnRzLnNpemUsIGluc3RhbGxlcjogaW5z
dGFsbGVyU2l6ZSgpID4gMCB9KSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChpbnN0YWxs
ZXJQYXRocy5oYXMocGF0aG5hbWUpKSB7CiAgICAgIHNlcnZlSW5zdGFsbGVyKHJlcSwgcmVzKTsK
ICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHBhdGhuYW1lID09PSAnLycgfHwgcGF0aG5hbWUg
PT09IGNvbmZpZy5wYXRoKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdjb250ZW50LXR5
cGUnOiAndGV4dC9wbGFpbjsgY2hhcnNldD11dGYtOCcgfSk7CiAgICAgIHJlcy5lbmQoYE9wZW5M
RjIgcmVsYXkgaXMgcnVubmluZy4gQ29ubmVjdCB3aXRoIGEgV2ViU29ja2V0IHRvICR7Y29uZmln
LnBhdGh9XG5gKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgcmVzLndyaXRlSGVhZCg0MDQsIHsg
J2NvbnRlbnQtdHlwZSc6ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JyB9KTsKICAgIHJlcy5l
bmQoJ05vdCBmb3VuZFxuJyk7CiAgfSk7CgogIGNvbnN0IHdzcyA9IG5ldyBXZWJTb2NrZXRTZXJ2
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
Z2V0KCdyb29tJykgfHwgJyc7CiAgICBpZiAoKHJvbGUgIT09ICdob3N0JyAmJiByb2xlICE9PSAn
am9pbicpIHx8ICFST09NX1BBVFRFUk4udGVzdChjb2RlKSkgewogICAgICByZXR1cm4gY2xvc2VX
aXRoKHdzLCBDTE9TRS5iYWRSZXF1ZXN0KTsKICAgIH0KCiAgICBjb25zdCBhZGRyZXNzID0gY2xp
ZW50QWRkcmVzcyhyZXEpOwogICAgY29uc3QgY291bnQgPSBjb25uZWN0aW9uc1BlcklwLmdldChh
ZGRyZXNzKSB8fCAwOwogICAgaWYgKGNvbmZpZy5tYXhDb25uZWN0aW9uc1BlcklwICYmIGNvdW50
ID49IGNvbmZpZy5tYXhDb25uZWN0aW9uc1BlcklwKSB7CiAgICAgIHJldHVybiBjbG9zZVdpdGgo
d3MsIENMT1NFLnRvb01hbnlDb25uZWN0aW9ucyk7CiAgICB9CiAgICBjb25uZWN0aW9uc1Blcklw
LnNldChhZGRyZXNzLCBjb3VudCArIDEpOwogICAgd3Mub25jZSgnY2xvc2UnLCAoKSA9PiB7CiAg
ICAgIGNvbnN0IGxlZnQgPSAoY29ubmVjdGlvbnNQZXJJcC5nZXQoYWRkcmVzcykgfHwgMSkgLSAx
OwogICAgICBpZiAobGVmdCA+IDApIGNvbm5lY3Rpb25zUGVySXAuc2V0KGFkZHJlc3MsIGxlZnQp
OwogICAgICBlbHNlIGNvbm5lY3Rpb25zUGVySXAuZGVsZXRlKGFkZHJlc3MpOwogICAgfSk7Cgog
ICAgbGV0IHJvb20gPSByb29tcy5nZXQoY29kZSk7CiAgICBpZiAoIXJvb20pIHsKICAgICAgaWYg
KGNvbmZpZy5tYXhSb29tcyAmJiByb29tcy5zaXplID49IGNvbmZpZy5tYXhSb29tcykgcmV0dXJu
IGNsb3NlV2l0aCh3cywgQ0xPU0Uuc2VydmVyRnVsbCk7CiAgICAgIHJvb20gPSB7IGNvZGUsIGhv
c3Q6IG51bGwsIGpvaW46IG51bGwsIHRpbWVyOiBudWxsIH07CiAgICAgIHJvb21zLnNldChjb2Rl
LCByb29tKTsKICAgIH0KICAgIGlmIChyb29tW3JvbGVdKSByZXR1cm4gY2xvc2VXaXRoKHdzLCBy
b2xlID09PSAnaG9zdCcgPyBDTE9TRS5ob3N0VGFrZW4gOiBDTE9TRS5ndWVzdFRha2VuKTsKCiAg
ICByb29tW3JvbGVdID0gd3M7CiAgICB3cy5yb29tID0gcm9vbTsKICAgIHdzLnJvbGUgPSByb2xl
OwogICAgd3MucGVlciA9IG51bGw7CiAgICB3cy5tZXNzYWdlQnVkZ2V0ID0gbmV3IEJ1Y2tldChj
b25maWcubWVzc2FnZXNQZXJTZWNvbmQsIGNvbmZpZy5tZXNzYWdlc1BlclNlY29uZCAqIDIpOwog
ICAgd3MuYnl0ZUJ1ZGdldCA9IG5ldyBCdWNrZXQoY29uZmlnLmJ5dGVzUGVyU2Vjb25kLCBNYXRo
Lm1heChjb25maWcuYnl0ZXNQZXJTZWNvbmQsIGNvbmZpZy5tYXhNZXNzYWdlQnl0ZXMpICogMik7
CiAgICB3cy5vbignbWVzc2FnZScsIChkYXRhLCBpc0JpbmFyeSkgPT4gb25NZXNzYWdlKHdzLCBk
YXRhLCBpc0JpbmFyeSkpOwogICAgd3Mub24oJ2Nsb3NlJywgKCkgPT4gb25DbG9zZSh3cykpOwoK
ICAgIGNvbnN0IG90aGVyID0gcm9vbVtyb2xlID09PSAnaG9zdCcgPyAnam9pbicgOiAnaG9zdCdd
OwogICAgaWYgKG90aGVyKSB7CiAgICAgIGNsZWFyVGltZW91dChyb29tLnRpbWVyKTsKICAgICAg
cm9vbS50aW1lciA9IG51bGw7CiAgICAgIHdzLnBlZXIgPSBvdGhlcjsKICAgICAgb3RoZXIucGVl
ciA9IHdzOwogICAgICAvLyBCb3RoIHBlZXJzIGFyZSBsaW5rZWQgYmVmb3JlIGVpdGhlciBsZWFy
bnMgYWJvdXQgaXQsIHNvIGFueSBkYXRhIHRoYXQgZm9sbG93cyBoYXMgYSBkZXN0aW5hdGlvbi4K
ICAgICAgc2VuZENvbnRyb2wob3RoZXIsIHsgdDogJ3BhaXJlZCcgfSk7CiAgICAgIHNlbmRDb250
cm9sKHdzLCB7IHQ6ICdwYWlyZWQnIH0pOwogICAgICBsb2coYHJvb20gJHtjb2RlfTogcGFpcmVk
YCk7CiAgICB9IGVsc2UgewogICAgICBzZW5kQ29udHJvbCh3cywgeyB0OiAnd2FpdGluZycsIHJv
b206IGNvZGUgfSk7CiAgICAgIHJvb20udGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICBpZiAocm9vbVtyb2xlXSA9PT0gd3MgJiYgIXdzLnBlZXIpIGNsb3NlV2l0aCh3cywgQ0xPU0Uu
dGltZW91dCk7CiAgICAgIH0sIGNvbmZpZy5yb29tV2FpdE1zKTsKICAgICAgbG9nKGByb29tICR7
Y29kZX06ICR7cm9sZX0gd2FpdGluZ2ApOwogICAgfQogIH0pOwoKICBmdW5jdGlvbiBvbk1lc3Nh
Z2Uod3MsIGRhdGEsIGlzQmluYXJ5KSB7CiAgICBpZiAoIWlzQmluYXJ5KSByZXR1cm47IC8vIG9u
bHkgdGhlIHJlbGF5IHNwZWFrcyB0ZXh0OyBjbGllbnRzIHNlbmQgZ2FtZSBieXRlcyBhcyBiaW5h
cnkgZnJhbWVzCiAgICBpZiAoIXdzLnBlZXIpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLmVh
cmx5RGF0YSk7CiAgICBpZiAoIXdzLm1lc3NhZ2VCdWRnZXQudGFrZSgxKSB8fCAhd3MuYnl0ZUJ1
ZGdldC50YWtlKGRhdGEubGVuZ3RoKSkgewogICAgICBsb2coYHJvb20gJHt3cy5yb29tLmNvZGV9
OiByYXRlIGxpbWl0YCk7CiAgICAgIGNsb3NlV2l0aCh3cy5wZWVyLCBDTE9TRS5yYXRlTGltaXRl
ZCk7CiAgICAgIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnJhdGVMaW1pdGVkKTsKICAgIH0K
ICAgIGNvbnN0IHBlZXIgPSB3cy5wZWVyOwogICAgaWYgKHBlZXIucmVhZHlTdGF0ZSAhPT0gV2Vi
U29ja2V0Lk9QRU4pIHJldHVybjsKICAgIGlmIChwZWVyLmJ1ZmZlcmVkQW1vdW50ID4gY29uZmln
Lm1heEJ1ZmZlcmVkQnl0ZXMpIHsKICAgICAgY2xvc2VXaXRoKHdzLCBDTE9TRS5zbG93UGVlcik7
CiAgICAgIHJldHVybiBjbG9zZVdpdGgocGVlciwgQ0xPU0Uuc2xvd1BlZXIpOwogICAgfQogICAg
aWYgKGNvbmZpZy5mb3J3YXJkRGVsYXlNcyA+IDApIHsKICAgICAgLy8gVGltZXJzIHdpdGggdGhl
IHNhbWUgZGVsYXkgZmlyZSBpbiB0aGUgb3JkZXIgdGhleSB3ZXJlIHNldCwgc28gdGhlIHN0cmVh
bSBzdGF5cyBpbiBvcmRlci4KICAgICAgc2V0VGltZW91dCgoKSA9PiB7IGlmIChwZWVyLnJlYWR5
U3RhdGUgPT09IFdlYlNvY2tldC5PUEVOKSBwZWVyLnNlbmQoZGF0YSwgeyBiaW5hcnk6IHRydWUg
fSk7IH0sIGNvbmZpZy5mb3J3YXJkRGVsYXlNcyk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHBl
ZXIuc2VuZChkYXRhLCB7IGJpbmFyeTogdHJ1ZSB9KTsKICB9CgogIGZ1bmN0aW9uIG9uQ2xvc2Uo
d3MpIHsKICAgIGNvbnN0IHJvb20gPSB3cy5yb29tOwogICAgaWYgKCFyb29tKSByZXR1cm47CiAg
ICBpZiAocm9vbVt3cy5yb2xlXSA9PT0gd3MpIHJvb21bd3Mucm9sZV0gPSBudWxsOwogICAgY29u
c3QgcGVlciA9IHdzLnBlZXI7CiAgICB3cy5wZWVyID0gbnVsbDsKICAgIGlmIChwZWVyKSB7CiAg
ICAgIC8vIEEgbG9ja3N0ZXAgbWF0Y2ggY2Fubm90IGNvbnRpbnVlIHdpdGggb25lIHBsYXllciwg
c28gdGhlIHJvb20gZW5kcyB3aXRoIHRoZSBwYWlyIGFuZCBpdHMKICAgICAgLy8gY29kZSBpcyBm
cmVlIGFnYWluIGF0IG9uY2UgKHRoZSBob3N0IGNhbiBwcmVzcyBIb3N0IGFnYWluIHdpdGggdGhl
IHNhbWUgY29kZSkuCiAgICAgIHBlZXIucGVlciA9IG51bGw7CiAgICAgIHJvb20uaG9zdCA9IHJv
b20uam9pbiA9IG51bGw7CiAgICAgIGNsb3NlV2l0aChwZWVyLCBDTE9TRS5wZWVyTGVmdCk7CiAg
ICAgIGxvZyhgcm9vbSAke3Jvb20uY29kZX06IGVuZGVkYCk7CiAgICB9CiAgICBpZiAoIXJvb20u
aG9zdCAmJiAhcm9vbS5qb2luKSB7CiAgICAgIGNsZWFyVGltZW91dChyb29tLnRpbWVyKTsKICAg
ICAgaWYgKHJvb21zLmdldChyb29tLmNvZGUpID09PSByb29tKSByb29tcy5kZWxldGUocm9vbS5j
b2RlKTsKICAgIH0KICB9CgogIC8vIFNpemUgb2YgdGhlIGluc3RhbGxlciBmaWxlLCBvciAwIHdo
ZW4gbm9uZSBpcyBjb25maWd1cmVkIG9yIHJlYWRhYmxlLgogIGZ1bmN0aW9uIGluc3RhbGxlclNp
emUoKSB7CiAgICBpZiAoIWNvbmZpZy5pbnN0YWxsZXJGaWxlKSByZXR1cm4gMDsKICAgIHRyeSB7
CiAgICAgIGNvbnN0IHN0YXQgPSBmcy5zdGF0U3luYyhjb25maWcuaW5zdGFsbGVyRmlsZSk7CiAg
ICAgIHJldHVybiBzdGF0LmlzRmlsZSgpID8gc3RhdC5zaXplIDogMDsKICAgIH0gY2F0Y2ggewog
ICAgICByZXR1cm4gMDsKICAgIH0KICB9CgogIGZ1bmN0aW9uIHNlcnZlSW5zdGFsbGVyKHJlcSwg
cmVzKSB7CiAgICBjb25zdCBoZWFkZXJzID0geyAnY2FjaGUtY29udHJvbCc6ICdwdWJsaWMsIG1h
eC1hZ2U9ODY0MDAnLCAneC1jb250ZW50LXR5cGUtb3B0aW9ucyc6ICdub3NuaWZmJyB9OwogICAg
Ly8gQ3Jvc3Mtb3JpZ2luOiB0aGUgZ2FtZSBwYWdlIGxpdmVzIGVsc2V3aGVyZSAoR2l0SHViIFBh
Z2VzKS4gV2l0aCBhbiBhbGxvdy1saXN0LCBvbmx5IGl0cyBwYWdlcyBtYXkgcmVhZCBpdC4KICAg
IGNvbnN0IG9yaWdpbiA9IG5vcm1hbGl6ZU9yaWdpbihyZXEuaGVhZGVycy5vcmlnaW4pOwogICAg
aWYgKCFjb25maWcuYWxsb3dlZE9yaWdpbnMubGVuZ3RoKSBoZWFkZXJzWydhY2Nlc3MtY29udHJv
bC1hbGxvdy1vcmlnaW4nXSA9ICcqJzsKICAgIGVsc2UgaWYgKG9yaWdpbiAmJiBjb25maWcuYWxs
b3dlZE9yaWdpbnMuaW5jbHVkZXMob3JpZ2luKSkgewogICAgICBoZWFkZXJzWydhY2Nlc3MtY29u
dHJvbC1hbGxvdy1vcmlnaW4nXSA9IHJlcS5oZWFkZXJzLm9yaWdpbjsKICAgICAgaGVhZGVycy52
YXJ5ID0gJ09yaWdpbic7CiAgICB9CiAgICBpZiAocmVxLm1ldGhvZCAhPT0gJ0dFVCcgJiYgcmVx
Lm1ldGhvZCAhPT0gJ0hFQUQnKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoNDA1LCB7IC4uLmhlYWRl
cnMsIGFsbG93OiAnR0VULCBIRUFEJyB9KTsKICAgICAgcmVzLmVuZCgpOwogICAgICByZXR1cm47
CiAgICB9CiAgICBjb25zdCBzaXplID0gaW5zdGFsbGVyU2l6ZSgpOwogICAgaWYgKCFzaXplKSB7
CiAgICAgIHJlcy53cml0ZUhlYWQoNDA0LCBoZWFkZXJzKTsKICAgICAgcmVzLmVuZCgpOwogICAg
ICByZXR1cm47CiAgICB9CiAgICBpZiAocmVxLm1ldGhvZCA9PT0gJ0dFVCcgJiYgY29uZmlnLmlu
c3RhbGxlckRvd25sb2Fkc1BlckhvdXIpIHsKICAgICAgY29uc3QgYWRkcmVzcyA9IGNsaWVudEFk
ZHJlc3MocmVxKTsKICAgICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgICAgbGV0IGVudHJ5
ID0gaW5zdGFsbGVyRG93bmxvYWRzLmdldChhZGRyZXNzKTsKICAgICAgaWYgKCFlbnRyeSB8fCBl
bnRyeS51bnRpbCA8PSBub3cpIHsKICAgICAgICBlbnRyeSA9IHsgY291bnQ6IDAsIHVudGlsOiBu
b3cgKyAzNjAwMDAwIH07CiAgICAgICAgaW5zdGFsbGVyRG93bmxvYWRzLnNldChhZGRyZXNzLCBl
bnRyeSk7CiAgICAgIH0KICAgICAgaWYgKGVudHJ5LmNvdW50ID49IGNvbmZpZy5pbnN0YWxsZXJE
b3dubG9hZHNQZXJIb3VyKSB7CiAgICAgICAgcmVzLndyaXRlSGVhZCg0MjksIHsgLi4uaGVhZGVy
cywgJ3JldHJ5LWFmdGVyJzogU3RyaW5nKE1hdGguY2VpbCgoZW50cnkudW50aWwgLSBub3cpIC8g
MTAwMCkpIH0pOwogICAgICAgIHJlcy5lbmQoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAg
ICAgZW50cnkuY291bnQgKz0gMTsKICAgIH0KICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7IC4uLmhl
YWRlcnMsICdjb250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vb2N0ZXQtc3RyZWFtJywgJ2NvbnRl
bnQtbGVuZ3RoJzogU3RyaW5nKHNpemUpIH0pOwogICAgaWYgKHJlcS5tZXRob2QgPT09ICdIRUFE
JykgewogICAgICByZXMuZW5kKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHN0cmVh
bSA9IGZzLmNyZWF0ZVJlYWRTdHJlYW0oY29uZmlnLmluc3RhbGxlckZpbGUpOwogICAgc3RyZWFt
Lm9uKCdlcnJvcicsICgpID0+IHJlcy5kZXN0cm95KCkpOwogICAgc3RyZWFtLnBpcGUocmVzKTsK
ICB9CgogIGZ1bmN0aW9uIGNsaWVudEFkZHJlc3MocmVxKSB7CiAgICBpZiAoY29uZmlnLnRydXN0
UHJveHkpIHsKICAgICAgY29uc3QgZm9yd2FyZGVkID0gU3RyaW5nKHJlcS5oZWFkZXJzWyd4LWZv
cndhcmRlZC1mb3InXSB8fCAnJykuc3BsaXQoJywnKVswXS50cmltKCk7CiAgICAgIGlmIChmb3J3
YXJkZWQpIHJldHVybiBmb3J3YXJkZWQ7CiAgICB9CiAgICByZXR1cm4gcmVxLnNvY2tldC5yZW1v
dGVBZGRyZXNzIHx8ICd1bmtub3duJzsKICB9CgogIGNvbnN0IGhlYXJ0YmVhdCA9IHNldEludGVy
dmFsKCgpID0+IHsKICAgIGZvciAoY29uc3Qgd3Mgb2Ygd3NzLmNsaWVudHMpIHsKICAgICAgaWYg
KCF3cy5pc0FsaXZlKSB7IHdzLnRlcm1pbmF0ZSgpOyBjb250aW51ZTsgfQogICAgICB3cy5pc0Fs
aXZlID0gZmFsc2U7CiAgICAgIHRyeSB7IHdzLnBpbmcoKTsgfSBjYXRjaCB7IC8qIGNsb3Npbmcg
Ki8gfQogICAgfQogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAoY29uc3QgW2Fk
ZHJlc3MsIGVudHJ5XSBvZiBpbnN0YWxsZXJEb3dubG9hZHMpIGlmIChlbnRyeS51bnRpbCA8PSBu
b3cpIGluc3RhbGxlckRvd25sb2Fkcy5kZWxldGUoYWRkcmVzcyk7CiAgfSwgY29uZmlnLnBpbmdJ
bnRlcnZhbE1zKTsKICBoZWFydGJlYXQudW5yZWYoKTsKCiAgcmV0dXJuIHsKICAgIGNvbmZpZywK
ICAgIHNlcnZlciwKICAgIHdzcywKICAgIHJvb21zLAogICAgbGlzdGVuKHBvcnQgPSBjb25maWcu
cG9ydCwgaG9zdCA9IGNvbmZpZy5ob3N0KSB7CiAgICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVz
b2x2ZSwgcmVqZWN0KSA9PiB7CiAgICAgICAgc2VydmVyLm9uY2UoJ2Vycm9yJywgcmVqZWN0KTsK
ICAgICAgICBzZXJ2ZXIubGlzdGVuKHBvcnQsIGhvc3QsICgpID0+IHsKICAgICAgICAgIHNlcnZl
ci5vZmYoJ2Vycm9yJywgcmVqZWN0KTsKICAgICAgICAgIHJlc29sdmUoc2VydmVyLmFkZHJlc3Mo
KSk7CiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSwKICAgIGNsb3NlKCkgewogICAgICBjbGVh
ckludGVydmFsKGhlYXJ0YmVhdCk7CiAgICAgIGZvciAoY29uc3Qgcm9vbSBvZiByb29tcy52YWx1
ZXMoKSkgY2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICBmb3IgKGNvbnN0IHdzIG9mIHdz
cy5jbGllbnRzKSBjbG9zZVdpdGgod3MsIENMT1NFLnNodXRkb3duKTsKICAgICAgcmV0dXJuIG5l
dyBQcm9taXNlKChyZXNvbHZlKSA9PiB7CiAgICAgICAgd3NzLmNsb3NlKCgpID0+IHNlcnZlci5j
bG9zZSgoKSA9PiByZXNvbHZlKCkpKTsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsgZm9yIChj
b25zdCB3cyBvZiB3c3MuY2xpZW50cykgd3MudGVybWluYXRlKCk7IH0sIDEwMDApLnVucmVmKCk7
CiAgICAgIH0pOwogICAgfSwKICB9Owp9CgpmdW5jdGlvbiBzZW5kQ29udHJvbCh3cywgbWVzc2Fn
ZSkgewogIGlmICh3cy5yZWFkeVN0YXRlID09PSBXZWJTb2NrZXQuT1BFTikgd3Muc2VuZChKU09O
LnN0cmluZ2lmeShtZXNzYWdlKSk7Cn0KCmZ1bmN0aW9uIGNsb3NlV2l0aCh3cywgW2NvZGUsIHJl
YXNvbl0pIHsKICBpZiAod3MucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4gfHwgd3MucmVh
ZHlTdGF0ZSA9PT0gV2ViU29ja2V0LkNPTk5FQ1RJTkcpIHsKICAgIHdzLmNsb3NlKGNvZGUsIHJl
YXNvbik7CiAgICAvLyBEbyBub3Qgd2FpdCBmb3JldmVyIGZvciBhIGNsaWVudCB0aGF0IG5ldmVy
IGFuc3dlcnMgdGhlIGNsb3NlIGhhbmRzaGFrZS4KICAgIHNldFRpbWVvdXQoKCkgPT4geyBpZiAo
d3MucmVhZHlTdGF0ZSAhPT0gV2ViU29ja2V0LkNMT1NFRCkgd3MudGVybWluYXRlKCk7IH0sIDMw
MDApLnVucmVmKCk7CiAgfQp9Cgptb2R1bGUuZXhwb3J0cyA9IHsgY3JlYXRlUmVsYXksIHJlYWRD
b25maWcsIENMT1NFLCBST09NX1BBVFRFUk4gfTsKCmlmIChyZXF1aXJlLm1haW4gPT09IG1vZHVs
ZSkgewogIGNvbnN0IHJlbGF5ID0gY3JlYXRlUmVsYXkocmVhZENvbmZpZygpKTsKICByZWxheS5s
aXN0ZW4oKS50aGVuKChhZGRyZXNzKSA9PiB7CiAgICBjb25zdCB3aGVyZSA9IHR5cGVvZiBhZGRy
ZXNzID09PSAnc3RyaW5nJyA/IGFkZHJlc3MgOiBgJHthZGRyZXNzLmFkZHJlc3N9OiR7YWRkcmVz
cy5wb3J0fWA7CiAgICBjb25zb2xlLmxvZyhgT3BlbkxGMiByZWxheSBsaXN0ZW5pbmcgb24gJHt3
aGVyZX0sIFdlYlNvY2tldCBwYXRoICR7cmVsYXkuY29uZmlnLnBhdGh9YCk7CiAgICBpZiAoIXJl
bGF5LmNvbmZpZy5hbGxvd2VkT3JpZ2lucy5sZW5ndGgpIHsKICAgICAgY29uc29sZS5sb2coJ0FM
TE9XRURfT1JJR0lOUyBpcyBlbXB0eTogYW55IHdlYnNpdGUgbWF5IHVzZSB0aGlzIHJlbGF5LiBT
ZXQgaXQgdG8geW91ciBnYW1lIHBhZ2Ugb3JpZ2luLicpOwogICAgfQogIH0pLmNhdGNoKChlcnJv
cikgPT4gewogICAgY29uc29sZS5lcnJvcihlcnJvci5tZXNzYWdlKTsKICAgIHByb2Nlc3MuZXhp
dCgxKTsKICB9KTsKICBjb25zdCBzdG9wID0gKCkgPT4gcmVsYXkuY2xvc2UoKS50aGVuKCgpID0+
IHByb2Nlc3MuZXhpdCgwKSk7CiAgcHJvY2Vzcy5vbignU0lHSU5UJywgc3RvcCk7CiAgcHJvY2Vz
cy5vbignU0lHVEVSTScsIHN0b3ApOwp9Cg==
LF2_PAYLOAD
}
write_package_json() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
ewogICJuYW1lIjogIm9wZW5sZjItb25saW5lLXJlbGF5IiwKICAidmVyc2lvbiI6ICIxLjAuMCIs
CiAgInByaXZhdGUiOiB0cnVlLAogICJkZXNjcmlwdGlvbiI6ICJXZWJTb2NrZXQgcmVsYXkgdGhh
dCBwYWlycyB0d28gT3BlbkxGMiB3ZWIgcGxheWVycyBieSByb29tIGNvZGUgYW5kIGZvcndhcmRz
IHRoZWlyIGdhbWUgYnl0ZSBzdHJlYW0iLAogICJsaWNlbnNlIjogIk1JVCIsCiAgIm1haW4iOiAi
c2VydmVyLmpzIiwKICAiYmluIjogewogICAgIm9wZW5sZjItcmVsYXkiOiAic2VydmVyLmpzIgog
IH0sCiAgInNjcmlwdHMiOiB7CiAgICAic3RhcnQiOiAibm9kZSBzZXJ2ZXIuanMiLAogICAgInRl
c3QiOiAibm9kZSAtLXRlc3QgXCJ0ZXN0LyoudGVzdC5qc1wiIgogIH0sCiAgImVuZ2luZXMiOiB7
CiAgICAibm9kZSI6ICI+PTIwIgogIH0sCiAgImRlcGVuZGVuY2llcyI6IHsKICAgICJ3cyI6ICJe
OC4xOC4wIgogIH0KfQo=
LF2_PAYLOAD
}
# <<< generated

# Last line on purpose: bash reads the whole script before running anything, so a cut-off
# download does nothing, and commands cannot swallow the script through stdin.
[ "${LF2_INSTALLER_LIB:-}" = 1 ] || main "$@"
