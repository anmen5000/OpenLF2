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
# Everything lives in /opt/lf2-relay plus two services, lf2-relay and lf2-caddy. The relay's own
# files are embedded below (update-installer.js writes them), so this file is all a server needs.
# Messages are Vietnamese without diacritics, so that every terminal shows them.
set -euo pipefail

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
	cat >"$PREFIX/Caddyfile" <<EOF
# Written by install-vps.sh. HTTPS for the OpenLF2 relay; the certificate renews by itself.
{
	admin off
}

$DOMAIN {
	reverse_proxy 127.0.0.1:$RELAY_PORT
}
EOF
	info "Caddy $CADDY_VERSION da san sang (chay bang tai khoan $CADDY_USER)"
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

open_firewall() {
	if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --quiet --permanent --add-service=http --add-service=https
		firewall-cmd --quiet --reload
		info "Da mo cong 80 va 443 tren firewalld"
	elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow 80/tcp >/dev/null
		ufw allow 443/tcp >/dev/null
		info "Da mo cong 80 va 443 tren ufw"
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

check_ports() {
	local listening port owner
	command -v ss >/dev/null 2>&1 || return 0
	listening=$(ss -ltnp 2>/dev/null || true)
	for port in 80 443; do
		owner=$(printf '%s\n' "$listening" | port_owner "$port" || true)
		[ -n "$owner" ] || continue
		if [ "$owner" = caddy ] && "$SYSTEMCTL" is-active --quiet lf2-caddy.service 2>/dev/null; then
			continue # our own Caddy from an earlier run
		fi
		fail "Cong $port dang duoc chuong trinh \"$owner\" dung (thuong la mot web server khac).
       Relay can cong 80 va 443. Gui thong bao nay cho nguoi huong dan ban."
	done
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

	say "Kiem tra may chu"
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

	say "Cai Caddy (HTTPS)"
	install_caddy

	say "Mo cong 80 va 443"
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
			printf '\n[LOI] Chua lay duoc chung chi HTTPS cho %s.\n' "$DOMAIN" >&2
			printf '      Thuong la do tuong lua cua nha cung cap VPS chan cong 80/443:\n' >&2
			printf '      vao trang quan ly VPS, mo cong TCP 80 va 443, roi chay lai lenh cai dat.\n' >&2
			printf '      Nhat ky cua Caddy: journalctl -u lf2-caddy -n 30 --no-pager\n' >&2
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
aG9ydCBBU0NJSSByZWFzb24sIHdoaWNoIHRoZSBnYW1lIHNob3dzLgondXNlIHN0cmljdCc7Cgpj
b25zdCBodHRwID0gcmVxdWlyZSgnbm9kZTpodHRwJyk7CmNvbnN0IHsgV2ViU29ja2V0U2VydmVy
LCBXZWJTb2NrZXQgfSA9IHJlcXVpcmUoJ3dzJyk7Cgpjb25zdCBST09NX1BBVFRFUk4gPSAvXlxk
ezQsMTJ9JC87CgovLyBDbG9zZSBjb2RlcyBhcmUgcGFydCBvZiB0aGUgY29udHJhY3Qgd2l0aCBv
bmxpbmUuanMgKGl0IG1hcHMgdGhlbSB0byBtZXNzYWdlcyB0b28pLgpjb25zdCBDTE9TRSA9IE9i
amVjdC5mcmVlemUoewogIGJhZFJlcXVlc3Q6IFs0MDAwLCAnUmVsYXk6IGJhZCByZXF1ZXN0J10s
CiAgb3JpZ2luRGVuaWVkOiBbNDAwMSwgJ1JlbGF5OiB0aGlzIHdlYnNpdGUgbWF5IG5vdCB1c2Ug
dGhlIHJlbGF5J10sCiAgdG9vTWFueUNvbm5lY3Rpb25zOiBbNDAwMiwgJ1JlbGF5OiB0b28gbWFu
eSBjb25uZWN0aW9ucyBmcm9tIHlvdXIgbmV0d29yayddLAogIHNlcnZlckZ1bGw6IFs0MDAzLCAn
UmVsYXk6IHNlcnZlciBpcyBmdWxsJ10sCiAgaG9zdFRha2VuOiBbNDAwNCwgJ1JlbGF5OiByb29t
IGFscmVhZHkgaGFzIGEgaG9zdCddLAogIGd1ZXN0VGFrZW46IFs0MDA0LCAnUmVsYXk6IHJvb20g
YWxyZWFkeSBoYXMgYSBndWVzdCddLAogIHRpbWVvdXQ6IFs0MDA1LCAnUmVsYXk6IG5vYm9keSBq
b2luZWQgaW4gdGltZSddLAogIHBlZXJMZWZ0OiBbNDAwNiwgJ1JlbGF5OiB0aGUgb3RoZXIgcGxh
eWVyIGxlZnQnXSwKICByYXRlTGltaXRlZDogWzQwMDcsICdSZWxheTogdG9vIG11Y2ggdHJhZmZp
YyddLAogIHNsb3dQZWVyOiBbNDAwOCwgJ1JlbGF5OiB0aGUgb3RoZXIgcGxheWVyIHN0b3BwZWQg
cmVhZGluZyddLAogIGVhcmx5RGF0YTogWzQwMDksICdSZWxheTogZGF0YSBzZW50IGJlZm9yZSBw
YWlyaW5nJ10sCiAgc2h1dGRvd246IFsxMDAxLCAnUmVsYXk6IHNlcnZlciBpcyByZXN0YXJ0aW5n
J10sCn0pOwoKZnVuY3Rpb24gcmVhZENvbmZpZyhlbnYgPSBwcm9jZXNzLmVudikgewogIGNvbnN0
IG51bWJlciA9IChuYW1lLCBmYWxsYmFjaykgPT4gewogICAgY29uc3QgcmF3ID0gZW52W25hbWVd
OwogICAgY29uc3QgdmFsdWUgPSByYXcgPT09IHVuZGVmaW5lZCB8fCByYXcgPT09ICcnID8gZmFs
bGJhY2sgOiBOdW1iZXIocmF3KTsKICAgIGlmICghTnVtYmVyLmlzRmluaXRlKHZhbHVlKSB8fCB2
YWx1ZSA8IDApIHRocm93IG5ldyBFcnJvcihgJHtuYW1lfSBtdXN0IGJlIGEgbm9uLW5lZ2F0aXZl
IG51bWJlcmApOwogICAgcmV0dXJuIHZhbHVlOwogIH07CiAgcmV0dXJuIHsKICAgIHBvcnQ6IG51
bWJlcignUE9SVCcsIDg3ODcpLAogICAgaG9zdDogZW52LkhPU1QgfHwgJzAuMC4wLjAnLAogICAg
cGF0aDogZW52LlJFTEFZX1BBVEggfHwgJy9yZWxheScsCiAgICAvLyBDb21tYS1zZXBhcmF0ZWQg
cGFnZSBvcmlnaW5zIGFsbG93ZWQgdG8gY29ubmVjdCwgZS5nLiAiaHR0cHM6Ly95b3UuZ2l0aHVi
LmlvIi4gRW1wdHkgYWxsb3dzIGFueS4KICAgIGFsbG93ZWRPcmlnaW5zOiAoZW52LkFMTE9XRURf
T1JJR0lOUyB8fCAnJykuc3BsaXQoJywnKS5tYXAobm9ybWFsaXplT3JpZ2luKS5maWx0ZXIoQm9v
bGVhbiksCiAgICAvLyBCZWhpbmQgYSByZXZlcnNlIHByb3h5IChDYWRkeSwgbmdpbngsIENsb3Vk
ZmxhcmUpLCB0YWtlIHRoZSBjbGllbnQgYWRkcmVzcyBmcm9tIFgtRm9yd2FyZGVkLUZvci4KICAg
IHRydXN0UHJveHk6IGVudi5UUlVTVF9QUk9YWSA9PT0gJzEnIHx8IGVudi5UUlVTVF9QUk9YWSA9
PT0gJ3RydWUnLAogICAgbWF4Um9vbXM6IG51bWJlcignTUFYX1JPT01TJywgNTAwKSwgLy8gMCA9
IHVubGltaXRlZAogICAgbWF4Q29ubmVjdGlvbnNQZXJJcDogbnVtYmVyKCdNQVhfQ09OTkVDVElP
TlNfUEVSX0lQJywgOCksIC8vIDAgPSB1bmxpbWl0ZWQKICAgIHJvb21XYWl0TXM6IG51bWJlcign
Uk9PTV9XQUlUX01TJywgMTIwMDAwKSwKICAgIHBpbmdJbnRlcnZhbE1zOiBudW1iZXIoJ1BJTkdf
SU5URVJWQUxfTVMnLCAxNTAwMCksCiAgICBtYXhNZXNzYWdlQnl0ZXM6IG51bWJlcignTUFYX01F
U1NBR0VfQllURVMnLCA2NTUzNiksIC8vIHRoZSBnYW1lIHF1ZXVlcyBhdCBtb3N0IDY0IEtpQgog
ICAgbWVzc2FnZXNQZXJTZWNvbmQ6IG51bWJlcignTUVTU0FHRVNfUEVSX1NFQ09ORCcsIDI0MCks
IC8vIHRoZSBnYW1lIHNlbmRzIH4zMCBwZXIgc2Vjb25kOyAwID0gdW5saW1pdGVkCiAgICBieXRl
c1BlclNlY29uZDogbnVtYmVyKCdCWVRFU19QRVJfU0VDT05EJywgMTMxMDcyKSwgLy8gMCA9IHVu
bGltaXRlZAogICAgbWF4QnVmZmVyZWRCeXRlczogbnVtYmVyKCdNQVhfQlVGRkVSRURfQllURVMn
LCAxMDQ4NTc2KSwKICAgIC8vIFRlc3RpbmcgYWlkOiBob2xkIGV2ZXJ5IGZvcndhcmRlZCBmcmFt
ZSB0aGlzIGxvbmcsIHRvIGZlZWwgaG93IGEgZGlzdGFudCByZWxheSB3b3VsZCBwbGF5LgogICAg
Zm9yd2FyZERlbGF5TXM6IG51bWJlcignRk9SV0FSRF9ERUxBWV9NUycsIDApLAogICAgcXVpZXQ6
IGVudi5RVUlFVCA9PT0gJzEnIHx8IGVudi5RVUlFVCA9PT0gJ3RydWUnLAogIH07Cn0KCmZ1bmN0
aW9uIG5vcm1hbGl6ZU9yaWdpbih2YWx1ZSkgewogIHJldHVybiBTdHJpbmcodmFsdWUgfHwgJycp
LnRyaW0oKS5yZXBsYWNlKC9cLyskLywgJycpLnRvTG93ZXJDYXNlKCk7Cn0KCi8vIFRva2VuIGJ1
Y2tldDogYHJhdGVgIHVuaXRzIHBlciBzZWNvbmQsIGJ1cnN0cyB1cCB0byBgY2FwYWNpdHlgLiBB
IHJhdGUgb2YgMCBkaXNhYmxlcyB0aGUgbGltaXQuCmNsYXNzIEJ1Y2tldCB7CiAgY29uc3RydWN0
b3IocmF0ZSwgY2FwYWNpdHkpIHsKICAgIHRoaXMucmF0ZSA9IHJhdGU7CiAgICB0aGlzLmNhcGFj
aXR5ID0gTWF0aC5tYXgoY2FwYWNpdHksIHJhdGUpOwogICAgdGhpcy50b2tlbnMgPSB0aGlzLmNh
cGFjaXR5OwogICAgdGhpcy5sYXN0ID0gRGF0ZS5ub3coKTsKICB9CiAgdGFrZShhbW91bnQpIHsK
ICAgIGlmICh0aGlzLnJhdGUgPT09IDApIHJldHVybiB0cnVlOwogICAgY29uc3Qgbm93ID0gRGF0
ZS5ub3coKTsKICAgIHRoaXMudG9rZW5zID0gTWF0aC5taW4odGhpcy5jYXBhY2l0eSwgdGhpcy50
b2tlbnMgKyAoKG5vdyAtIHRoaXMubGFzdCkgKiB0aGlzLnJhdGUpIC8gMTAwMCk7CiAgICB0aGlz
Lmxhc3QgPSBub3c7CiAgICBpZiAodGhpcy50b2tlbnMgPCBhbW91bnQpIHJldHVybiBmYWxzZTsK
ICAgIHRoaXMudG9rZW5zIC09IGFtb3VudDsKICAgIHJldHVybiB0cnVlOwogIH0KfQoKZnVuY3Rp
b24gY3JlYXRlUmVsYXkob3ZlcnJpZGVzID0ge30pIHsKICBjb25zdCBjb25maWcgPSB7IC4uLnJl
YWRDb25maWcoe30pLCAuLi5vdmVycmlkZXMgfTsKICBjb25zdCByb29tcyA9IG5ldyBNYXAoKTsg
Ly8gY29kZSAtPiB7IGNvZGUsIGhvc3QsIGpvaW4sIHRpbWVyIH0KICBjb25zdCBjb25uZWN0aW9u
c1BlcklwID0gbmV3IE1hcCgpOwogIGNvbnN0IGxvZyA9ICguLi5wYXJ0cykgPT4geyBpZiAoIWNv
bmZpZy5xdWlldCkgY29uc29sZS5sb2cobmV3IERhdGUoKS50b0lTT1N0cmluZygpLCAuLi5wYXJ0
cyk7IH07CgogIGNvbnN0IHNlcnZlciA9IGh0dHAuY3JlYXRlU2VydmVyKChyZXEsIHJlcykgPT4g
ewogICAgY29uc3QgeyBwYXRobmFtZSB9ID0gbmV3IFVSTChyZXEudXJsLCAnaHR0cDovL3JlbGF5
LmludmFsaWQnKTsKICAgIGlmIChwYXRobmFtZSA9PT0gJy9oZWFsdGh6JykgewogICAgICAvLyBS
ZWFkYWJsZSBmcm9tIHRoZSBnYW1lIHBhZ2UgKGFub3RoZXIgb3JpZ2luKSBzbyBpdHMgT25saW5l
IHBhbmVsIGNhbiBzaG93ICJyZWxheSBPSyIuCiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7CiAg
ICAgICAgJ2NvbnRlbnQtdHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJywKICAgICAgICAnY2FjaGUt
Y29udHJvbCc6ICduby1zdG9yZScsCiAgICAgICAgJ2FjY2Vzcy1jb250cm9sLWFsbG93LW9yaWdp
bic6ICcqJywKICAgICAgfSk7CiAgICAgIHJlcy5lbmQoSlNPTi5zdHJpbmdpZnkoeyBvazogdHJ1
ZSwgcm9vbXM6IHJvb21zLnNpemUsIGNsaWVudHM6IHdzcy5jbGllbnRzLnNpemUgfSkpOwogICAg
ICByZXR1cm47CiAgICB9CiAgICBpZiAocGF0aG5hbWUgPT09ICcvJyB8fCBwYXRobmFtZSA9PT0g
Y29uZmlnLnBhdGgpIHsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ2NvbnRlbnQtdHlwZSc6
ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JyB9KTsKICAgICAgcmVzLmVuZChgT3BlbkxGMiBy
ZWxheSBpcyBydW5uaW5nLiBDb25uZWN0IHdpdGggYSBXZWJTb2NrZXQgdG8gJHtjb25maWcucGF0
aH1cbmApOwogICAgICByZXR1cm47CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDQwNCwgeyAnY29u
dGVudC10eXBlJzogJ3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgcmVzLmVuZCgn
Tm90IGZvdW5kXG4nKTsKICB9KTsKCiAgY29uc3Qgd3NzID0gbmV3IFdlYlNvY2tldFNlcnZlcih7
CiAgICBub1NlcnZlcjogdHJ1ZSwKICAgIG1heFBheWxvYWQ6IGNvbmZpZy5tYXhNZXNzYWdlQnl0
ZXMsCiAgICBwZXJNZXNzYWdlRGVmbGF0ZTogZmFsc2UsIC8vIDIyLWJ5dGUgcGFja2V0czogY29t
cHJlc3Npb24gb25seSBhZGRzIGxhdGVuY3kKICB9KTsKCiAgc2VydmVyLm9uKCd1cGdyYWRlJywg
KHJlcSwgc29ja2V0LCBoZWFkKSA9PiB7CiAgICBjb25zdCB1cmwgPSBuZXcgVVJMKHJlcS51cmws
ICdodHRwOi8vcmVsYXkuaW52YWxpZCcpOwogICAgaWYgKHVybC5wYXRobmFtZSAhPT0gY29uZmln
LnBhdGggJiYgdXJsLnBhdGhuYW1lICE9PSAnLycpIHsKICAgICAgc29ja2V0LmVuZCgnSFRUUC8x
LjEgNDA0IE5vdCBGb3VuZFxyXG5Db25uZWN0aW9uOiBjbG9zZVxyXG5cclxuJyk7CiAgICAgIHJl
dHVybjsKICAgIH0KICAgIC8vIFJlcXVlc3RzIGFyZSB2YWxpZGF0ZWQgYWZ0ZXIgdGhlIHVwZ3Jh
ZGUsIHNvIHRoZSBicm93c2VyIHJlY2VpdmVzIGEgY2xvc2UgY29kZSBhbmQgcmVhc29uCiAgICAv
LyBpbnN0ZWFkIG9mIGFuIGFub255bW91cyBjb25uZWN0aW9uIGVycm9yLgogICAgd3NzLmhhbmRs
ZVVwZ3JhZGUocmVxLCBzb2NrZXQsIGhlYWQsICh3cykgPT4gd3NzLmVtaXQoJ2Nvbm5lY3Rpb24n
LCB3cywgcmVxLCB1cmwpKTsKICB9KTsKCiAgd3NzLm9uKCdjb25uZWN0aW9uJywgKHdzLCByZXEs
IHVybCkgPT4gewogICAgd3MuaXNBbGl2ZSA9IHRydWU7CiAgICB3cy5vbigncG9uZycsICgpID0+
IHsgd3MuaXNBbGl2ZSA9IHRydWU7IH0pOwogICAgd3Mub24oJ2Vycm9yJywgKCkgPT4ge30pOyAv
LyBhICdjbG9zZScgZXZlbnQgYWx3YXlzIGZvbGxvd3MKCiAgICBpZiAoY29uZmlnLmFsbG93ZWRP
cmlnaW5zLmxlbmd0aCAmJiAhY29uZmlnLmFsbG93ZWRPcmlnaW5zLmluY2x1ZGVzKG5vcm1hbGl6
ZU9yaWdpbihyZXEuaGVhZGVycy5vcmlnaW4pKSkgewogICAgICByZXR1cm4gY2xvc2VXaXRoKHdz
LCBDTE9TRS5vcmlnaW5EZW5pZWQpOwogICAgfQogICAgY29uc3Qgcm9sZSA9IHVybC5zZWFyY2hQ
YXJhbXMuZ2V0KCdyb2xlJyk7CiAgICBjb25zdCBjb2RlID0gdXJsLnNlYXJjaFBhcmFtcy5nZXQo
J3Jvb20nKSB8fCAnJzsKICAgIGlmICgocm9sZSAhPT0gJ2hvc3QnICYmIHJvbGUgIT09ICdqb2lu
JykgfHwgIVJPT01fUEFUVEVSTi50ZXN0KGNvZGUpKSB7CiAgICAgIHJldHVybiBjbG9zZVdpdGgo
d3MsIENMT1NFLmJhZFJlcXVlc3QpOwogICAgfQoKICAgIGNvbnN0IGFkZHJlc3MgPSBjbGllbnRB
ZGRyZXNzKHJlcSk7CiAgICBjb25zdCBjb3VudCA9IGNvbm5lY3Rpb25zUGVySXAuZ2V0KGFkZHJl
c3MpIHx8IDA7CiAgICBpZiAoY29uZmlnLm1heENvbm5lY3Rpb25zUGVySXAgJiYgY291bnQgPj0g
Y29uZmlnLm1heENvbm5lY3Rpb25zUGVySXApIHsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywg
Q0xPU0UudG9vTWFueUNvbm5lY3Rpb25zKTsKICAgIH0KICAgIGNvbm5lY3Rpb25zUGVySXAuc2V0
KGFkZHJlc3MsIGNvdW50ICsgMSk7CiAgICB3cy5vbmNlKCdjbG9zZScsICgpID0+IHsKICAgICAg
Y29uc3QgbGVmdCA9IChjb25uZWN0aW9uc1BlcklwLmdldChhZGRyZXNzKSB8fCAxKSAtIDE7CiAg
ICAgIGlmIChsZWZ0ID4gMCkgY29ubmVjdGlvbnNQZXJJcC5zZXQoYWRkcmVzcywgbGVmdCk7CiAg
ICAgIGVsc2UgY29ubmVjdGlvbnNQZXJJcC5kZWxldGUoYWRkcmVzcyk7CiAgICB9KTsKCiAgICBs
ZXQgcm9vbSA9IHJvb21zLmdldChjb2RlKTsKICAgIGlmICghcm9vbSkgewogICAgICBpZiAoY29u
ZmlnLm1heFJvb21zICYmIHJvb21zLnNpemUgPj0gY29uZmlnLm1heFJvb21zKSByZXR1cm4gY2xv
c2VXaXRoKHdzLCBDTE9TRS5zZXJ2ZXJGdWxsKTsKICAgICAgcm9vbSA9IHsgY29kZSwgaG9zdDog
bnVsbCwgam9pbjogbnVsbCwgdGltZXI6IG51bGwgfTsKICAgICAgcm9vbXMuc2V0KGNvZGUsIHJv
b20pOwogICAgfQogICAgaWYgKHJvb21bcm9sZV0pIHJldHVybiBjbG9zZVdpdGgod3MsIHJvbGUg
PT09ICdob3N0JyA/IENMT1NFLmhvc3RUYWtlbiA6IENMT1NFLmd1ZXN0VGFrZW4pOwoKICAgIHJv
b21bcm9sZV0gPSB3czsKICAgIHdzLnJvb20gPSByb29tOwogICAgd3Mucm9sZSA9IHJvbGU7CiAg
ICB3cy5wZWVyID0gbnVsbDsKICAgIHdzLm1lc3NhZ2VCdWRnZXQgPSBuZXcgQnVja2V0KGNvbmZp
Zy5tZXNzYWdlc1BlclNlY29uZCwgY29uZmlnLm1lc3NhZ2VzUGVyU2Vjb25kICogMik7CiAgICB3
cy5ieXRlQnVkZ2V0ID0gbmV3IEJ1Y2tldChjb25maWcuYnl0ZXNQZXJTZWNvbmQsIE1hdGgubWF4
KGNvbmZpZy5ieXRlc1BlclNlY29uZCwgY29uZmlnLm1heE1lc3NhZ2VCeXRlcykgKiAyKTsKICAg
IHdzLm9uKCdtZXNzYWdlJywgKGRhdGEsIGlzQmluYXJ5KSA9PiBvbk1lc3NhZ2Uod3MsIGRhdGEs
IGlzQmluYXJ5KSk7CiAgICB3cy5vbignY2xvc2UnLCAoKSA9PiBvbkNsb3NlKHdzKSk7CgogICAg
Y29uc3Qgb3RoZXIgPSByb29tW3JvbGUgPT09ICdob3N0JyA/ICdqb2luJyA6ICdob3N0J107CiAg
ICBpZiAob3RoZXIpIHsKICAgICAgY2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICByb29t
LnRpbWVyID0gbnVsbDsKICAgICAgd3MucGVlciA9IG90aGVyOwogICAgICBvdGhlci5wZWVyID0g
d3M7CiAgICAgIC8vIEJvdGggcGVlcnMgYXJlIGxpbmtlZCBiZWZvcmUgZWl0aGVyIGxlYXJucyBh
Ym91dCBpdCwgc28gYW55IGRhdGEgdGhhdCBmb2xsb3dzIGhhcyBhIGRlc3RpbmF0aW9uLgogICAg
ICBzZW5kQ29udHJvbChvdGhlciwgeyB0OiAncGFpcmVkJyB9KTsKICAgICAgc2VuZENvbnRyb2wo
d3MsIHsgdDogJ3BhaXJlZCcgfSk7CiAgICAgIGxvZyhgcm9vbSAke2NvZGV9OiBwYWlyZWRgKTsK
ICAgIH0gZWxzZSB7CiAgICAgIHNlbmRDb250cm9sKHdzLCB7IHQ6ICd3YWl0aW5nJywgcm9vbTog
Y29kZSB9KTsKICAgICAgcm9vbS50aW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgIGlm
IChyb29tW3JvbGVdID09PSB3cyAmJiAhd3MucGVlcikgY2xvc2VXaXRoKHdzLCBDTE9TRS50aW1l
b3V0KTsKICAgICAgfSwgY29uZmlnLnJvb21XYWl0TXMpOwogICAgICBsb2coYHJvb20gJHtjb2Rl
fTogJHtyb2xlfSB3YWl0aW5nYCk7CiAgICB9CiAgfSk7CgogIGZ1bmN0aW9uIG9uTWVzc2FnZSh3
cywgZGF0YSwgaXNCaW5hcnkpIHsKICAgIGlmICghaXNCaW5hcnkpIHJldHVybjsgLy8gb25seSB0
aGUgcmVsYXkgc3BlYWtzIHRleHQ7IGNsaWVudHMgc2VuZCBnYW1lIGJ5dGVzIGFzIGJpbmFyeSBm
cmFtZXMKICAgIGlmICghd3MucGVlcikgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuZWFybHlE
YXRhKTsKICAgIGlmICghd3MubWVzc2FnZUJ1ZGdldC50YWtlKDEpIHx8ICF3cy5ieXRlQnVkZ2V0
LnRha2UoZGF0YS5sZW5ndGgpKSB7CiAgICAgIGxvZyhgcm9vbSAke3dzLnJvb20uY29kZX06IHJh
dGUgbGltaXRgKTsKICAgICAgY2xvc2VXaXRoKHdzLnBlZXIsIENMT1NFLnJhdGVMaW1pdGVkKTsK
ICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UucmF0ZUxpbWl0ZWQpOwogICAgfQogICAg
Y29uc3QgcGVlciA9IHdzLnBlZXI7CiAgICBpZiAocGVlci5yZWFkeVN0YXRlICE9PSBXZWJTb2Nr
ZXQuT1BFTikgcmV0dXJuOwogICAgaWYgKHBlZXIuYnVmZmVyZWRBbW91bnQgPiBjb25maWcubWF4
QnVmZmVyZWRCeXRlcykgewogICAgICBjbG9zZVdpdGgod3MsIENMT1NFLnNsb3dQZWVyKTsKICAg
ICAgcmV0dXJuIGNsb3NlV2l0aChwZWVyLCBDTE9TRS5zbG93UGVlcik7CiAgICB9CiAgICBpZiAo
Y29uZmlnLmZvcndhcmREZWxheU1zID4gMCkgewogICAgICAvLyBUaW1lcnMgd2l0aCB0aGUgc2Ft
ZSBkZWxheSBmaXJlIGluIHRoZSBvcmRlciB0aGV5IHdlcmUgc2V0LCBzbyB0aGUgc3RyZWFtIHN0
YXlzIGluIG9yZGVyLgogICAgICBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKHBlZXIucmVhZHlTdGF0
ZSA9PT0gV2ViU29ja2V0Lk9QRU4pIHBlZXIuc2VuZChkYXRhLCB7IGJpbmFyeTogdHJ1ZSB9KTsg
fSwgY29uZmlnLmZvcndhcmREZWxheU1zKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgcGVlci5z
ZW5kKGRhdGEsIHsgYmluYXJ5OiB0cnVlIH0pOwogIH0KCiAgZnVuY3Rpb24gb25DbG9zZSh3cykg
ewogICAgY29uc3Qgcm9vbSA9IHdzLnJvb207CiAgICBpZiAoIXJvb20pIHJldHVybjsKICAgIGlm
IChyb29tW3dzLnJvbGVdID09PSB3cykgcm9vbVt3cy5yb2xlXSA9IG51bGw7CiAgICBjb25zdCBw
ZWVyID0gd3MucGVlcjsKICAgIHdzLnBlZXIgPSBudWxsOwogICAgaWYgKHBlZXIpIHsKICAgICAg
Ly8gQSBsb2Nrc3RlcCBtYXRjaCBjYW5ub3QgY29udGludWUgd2l0aCBvbmUgcGxheWVyLCBzbyB0
aGUgcm9vbSBlbmRzIHdpdGggdGhlIHBhaXIgYW5kIGl0cwogICAgICAvLyBjb2RlIGlzIGZyZWUg
YWdhaW4gYXQgb25jZSAodGhlIGhvc3QgY2FuIHByZXNzIEhvc3QgYWdhaW4gd2l0aCB0aGUgc2Ft
ZSBjb2RlKS4KICAgICAgcGVlci5wZWVyID0gbnVsbDsKICAgICAgcm9vbS5ob3N0ID0gcm9vbS5q
b2luID0gbnVsbDsKICAgICAgY2xvc2VXaXRoKHBlZXIsIENMT1NFLnBlZXJMZWZ0KTsKICAgICAg
bG9nKGByb29tICR7cm9vbS5jb2RlfTogZW5kZWRgKTsKICAgIH0KICAgIGlmICghcm9vbS5ob3N0
ICYmICFyb29tLmpvaW4pIHsKICAgICAgY2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwogICAgICBp
ZiAocm9vbXMuZ2V0KHJvb20uY29kZSkgPT09IHJvb20pIHJvb21zLmRlbGV0ZShyb29tLmNvZGUp
OwogICAgfQogIH0KCiAgZnVuY3Rpb24gY2xpZW50QWRkcmVzcyhyZXEpIHsKICAgIGlmIChjb25m
aWcudHJ1c3RQcm94eSkgewogICAgICBjb25zdCBmb3J3YXJkZWQgPSBTdHJpbmcocmVxLmhlYWRl
cnNbJ3gtZm9yd2FyZGVkLWZvciddIHx8ICcnKS5zcGxpdCgnLCcpWzBdLnRyaW0oKTsKICAgICAg
aWYgKGZvcndhcmRlZCkgcmV0dXJuIGZvcndhcmRlZDsKICAgIH0KICAgIHJldHVybiByZXEuc29j
a2V0LnJlbW90ZUFkZHJlc3MgfHwgJ3Vua25vd24nOwogIH0KCiAgY29uc3QgaGVhcnRiZWF0ID0g
c2V0SW50ZXJ2YWwoKCkgPT4gewogICAgZm9yIChjb25zdCB3cyBvZiB3c3MuY2xpZW50cykgewog
ICAgICBpZiAoIXdzLmlzQWxpdmUpIHsgd3MudGVybWluYXRlKCk7IGNvbnRpbnVlOyB9CiAgICAg
IHdzLmlzQWxpdmUgPSBmYWxzZTsKICAgICAgdHJ5IHsgd3MucGluZygpOyB9IGNhdGNoIHsgLyog
Y2xvc2luZyAqLyB9CiAgICB9CiAgfSwgY29uZmlnLnBpbmdJbnRlcnZhbE1zKTsKICBoZWFydGJl
YXQudW5yZWYoKTsKCiAgcmV0dXJuIHsKICAgIGNvbmZpZywKICAgIHNlcnZlciwKICAgIHdzcywK
ICAgIHJvb21zLAogICAgbGlzdGVuKHBvcnQgPSBjb25maWcucG9ydCwgaG9zdCA9IGNvbmZpZy5o
b3N0KSB7CiAgICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVzb2x2ZSwgcmVqZWN0KSA9PiB7CiAg
ICAgICAgc2VydmVyLm9uY2UoJ2Vycm9yJywgcmVqZWN0KTsKICAgICAgICBzZXJ2ZXIubGlzdGVu
KHBvcnQsIGhvc3QsICgpID0+IHsKICAgICAgICAgIHNlcnZlci5vZmYoJ2Vycm9yJywgcmVqZWN0
KTsKICAgICAgICAgIHJlc29sdmUoc2VydmVyLmFkZHJlc3MoKSk7CiAgICAgICAgfSk7CiAgICAg
IH0pOwogICAgfSwKICAgIGNsb3NlKCkgewogICAgICBjbGVhckludGVydmFsKGhlYXJ0YmVhdCk7
CiAgICAgIGZvciAoY29uc3Qgcm9vbSBvZiByb29tcy52YWx1ZXMoKSkgY2xlYXJUaW1lb3V0KHJv
b20udGltZXIpOwogICAgICBmb3IgKGNvbnN0IHdzIG9mIHdzcy5jbGllbnRzKSBjbG9zZVdpdGgo
d3MsIENMT1NFLnNodXRkb3duKTsKICAgICAgcmV0dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlKSA9
PiB7CiAgICAgICAgd3NzLmNsb3NlKCgpID0+IHNlcnZlci5jbG9zZSgoKSA9PiByZXNvbHZlKCkp
KTsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsgZm9yIChjb25zdCB3cyBvZiB3c3MuY2xpZW50
cykgd3MudGVybWluYXRlKCk7IH0sIDEwMDApLnVucmVmKCk7CiAgICAgIH0pOwogICAgfSwKICB9
Owp9CgpmdW5jdGlvbiBzZW5kQ29udHJvbCh3cywgbWVzc2FnZSkgewogIGlmICh3cy5yZWFkeVN0
YXRlID09PSBXZWJTb2NrZXQuT1BFTikgd3Muc2VuZChKU09OLnN0cmluZ2lmeShtZXNzYWdlKSk7
Cn0KCmZ1bmN0aW9uIGNsb3NlV2l0aCh3cywgW2NvZGUsIHJlYXNvbl0pIHsKICBpZiAod3MucmVh
ZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4gfHwgd3MucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0
LkNPTk5FQ1RJTkcpIHsKICAgIHdzLmNsb3NlKGNvZGUsIHJlYXNvbik7CiAgICAvLyBEbyBub3Qg
d2FpdCBmb3JldmVyIGZvciBhIGNsaWVudCB0aGF0IG5ldmVyIGFuc3dlcnMgdGhlIGNsb3NlIGhh
bmRzaGFrZS4KICAgIHNldFRpbWVvdXQoKCkgPT4geyBpZiAod3MucmVhZHlTdGF0ZSAhPT0gV2Vi
U29ja2V0LkNMT1NFRCkgd3MudGVybWluYXRlKCk7IH0sIDMwMDApLnVucmVmKCk7CiAgfQp9Cgpt
b2R1bGUuZXhwb3J0cyA9IHsgY3JlYXRlUmVsYXksIHJlYWRDb25maWcsIENMT1NFLCBST09NX1BB
VFRFUk4gfTsKCmlmIChyZXF1aXJlLm1haW4gPT09IG1vZHVsZSkgewogIGNvbnN0IHJlbGF5ID0g
Y3JlYXRlUmVsYXkocmVhZENvbmZpZygpKTsKICByZWxheS5saXN0ZW4oKS50aGVuKChhZGRyZXNz
KSA9PiB7CiAgICBjb25zdCB3aGVyZSA9IHR5cGVvZiBhZGRyZXNzID09PSAnc3RyaW5nJyA/IGFk
ZHJlc3MgOiBgJHthZGRyZXNzLmFkZHJlc3N9OiR7YWRkcmVzcy5wb3J0fWA7CiAgICBjb25zb2xl
LmxvZyhgT3BlbkxGMiByZWxheSBsaXN0ZW5pbmcgb24gJHt3aGVyZX0sIFdlYlNvY2tldCBwYXRo
ICR7cmVsYXkuY29uZmlnLnBhdGh9YCk7CiAgICBpZiAoIXJlbGF5LmNvbmZpZy5hbGxvd2VkT3Jp
Z2lucy5sZW5ndGgpIHsKICAgICAgY29uc29sZS5sb2coJ0FMTE9XRURfT1JJR0lOUyBpcyBlbXB0
eTogYW55IHdlYnNpdGUgbWF5IHVzZSB0aGlzIHJlbGF5LiBTZXQgaXQgdG8geW91ciBnYW1lIHBh
Z2Ugb3JpZ2luLicpOwogICAgfQogIH0pLmNhdGNoKChlcnJvcikgPT4gewogICAgY29uc29sZS5l
cnJvcihlcnJvci5tZXNzYWdlKTsKICAgIHByb2Nlc3MuZXhpdCgxKTsKICB9KTsKICBjb25zdCBz
dG9wID0gKCkgPT4gcmVsYXkuY2xvc2UoKS50aGVuKCgpID0+IHByb2Nlc3MuZXhpdCgwKSk7CiAg
cHJvY2Vzcy5vbignU0lHSU5UJywgc3RvcCk7CiAgcHJvY2Vzcy5vbignU0lHVEVSTScsIHN0b3Ap
Owp9Cg==
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
