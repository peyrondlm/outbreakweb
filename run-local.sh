#!/usr/bin/env bash
# Resident Evil Outbreak File #1 (SLUS-20765) and File #2 (SLUS-20984) online, all on one machine.
#   1. the US "app01" server (TCP 10127): the Java server in server/ (also regweb on 8080);
#      PYAPP=1 uses the Python prototype server/tools/usapp.py instead,
#   2. the Ethernet-over-WebSocket gateway (net/gateway, 127.0.0.1:8765 by default),
#   3. the web build (ps2-web-recomp/scripts/serve.py, http://127.0.0.1:8620 by default).
#   The Java server also runs the US lobby (kkClient login + rooms, UDP 9090) and the HTTP API
#   (127.0.0.1:8088). serve.py forwards the page's /api/* to it (the pre-menu registers the
#   player name with POST /api/kk/register before starting; the site chat is /api/chat/poll and
#   /api/chat/send, and the room list on the page reads /api/rooms).
#   Owner's metrics panel: http://localhost:WEB_PORT/admin, with the local admin token printed at
#   start (REO_ADMIN_TOKEN, or a random one kept in LOGS/admin-token). Metrics data: server/data/metrics/.
# Ctrl+C stops all three.
#
# Two players on one PC: one normal Chrome window and one incognito window (each has its own
# token), a different player name in each pre-menu. See docs/playing-online.md.
#
# Usage (inside WSL):        ./run-local.sh
# From Windows PowerShell:   wsl -e bash -lc ./run-local.sh
# Then open http://localhost:8620/ in Chrome or Edge (picker; games at /file1/ and /file2/), start
# the game and pick NETWORK PLAY. The page talks to the gateway by itself and the memory card gets
# the "REO gateway (DHCP)" network configuration on first use.
#
# LAN or VPN: ./run-local.sh --all (all interfaces), or --address 100.x.y.z (one address).
# In these modes serve.py serves HTTPS with a self-signed certificate and proxies /eth to the
# gateway. Only TCP 8620 is exposed. Accept the certificate warning once on each device.
#
# Native instead of the browser (same gateway and server):
#   cd ps2-web-recomp && build/native-outbreak1/ps2run games/outbreak1/disc/SLUS_207.65 \
#     --disc games/outbreak1/disc.iso --memcard games/outbreak1/online.ps2 --net ws://127.0.0.1:8765/eth --window
#
# If GW_PORT is not 8765 in local mode, open http://localhost:WEB_PORT/?gateway=ws://localhost:GW_PORT/eth
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: run-local.sh [--local | --all | --address ADDRESS]

  --local          Listen on 127.0.0.1 only. This is the default.
  --all            Listen on all IPv4 interfaces with HTTPS. Use this for LAN or VPN play.
  --address ADDRESS
                   Listen on one IPv4 address. A non-loopback address uses HTTPS.
  --help           Show this help.

Network modes make a self-signed certificate. Accept the browser warning once on each device.
Only the web port needs to be open in the firewall.

Settings (environment): GW_PORT=8765 WEB_PORT=8620 APP_PORT=10127 GAME=outbreak1 METRICS_TZ=UTC
  SERVER_CMD="..." runs another server instead (it must listen on APP_PORT). PYAPP=1: usapp.py.
  LAN_ADDRS="IP [IP ...]" adds addresses to the certificate and the printed URLs.
  LAN_HOSTS="name [name ...]" adds DNS names to the certificate.
  LAN_TLS_CERT and LAN_TLS_KEY use your own certificate with --all or --address.
  PCAP=0 disables packet captures. Network modes disable them by default.
  Logs, certificates and pcaps go to net/runs/local/.
EOF
}

MODE=local
MODE_SET=0
LISTEN_ADDR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --local|--all|--address)
            if [ "$MODE_SET" = 1 ]; then
                echo "use only one of --local, --all and --address" >&2
                exit 2
            fi
            MODE_SET=1
            case "$1" in
                --local) MODE=local ;;
                --all) MODE=all ;;
                --address)
                    shift
                    if [ $# -eq 0 ]; then
                        echo "--address needs an IPv4 address" >&2
                        exit 2
                    fi
                    MODE=address
                    LISTEN_ADDR="$1"
                    ;;
            esac
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1 (use --help)" >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$MODE" = address ] && ! [[ "$LISTEN_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "--address needs an IPv4 address" >&2
    exit 2
fi

GW_PORT="${GW_PORT:-8765}"; WEB_PORT="${WEB_PORT:-8620}"; APP_PORT="${APP_PORT:-10127}"; GAME="${GAME:-outbreak1}"
API_PORT="${API_PORT:-8088}"; KK_PORT="${KK_PORT:-9090}"; KK2_PORT="${KK2_PORT:-9092}"
RECOMP="$HERE/ps2-web-recomp"; GATEWAY="$HERE/net/gateway/bin/reo-gateway"
LOGS="${LOGS:-$HERE/net/runs/local}"
mkdir -p "$LOGS"
LOGS="$(cd "$LOGS" && pwd)"

WEB_HOST=127.0.0.1
if [ "$MODE" = all ]; then
    WEB_HOST=0.0.0.0
elif [ "$MODE" = address ]; then
    WEB_HOST="$LISTEN_ADDR"
fi
NETWORK_MODE=1
case "$WEB_HOST" in
    127.*|localhost|::1) NETWORK_MODE=0; WEB_HOST=127.0.0.1 ;;
esac
GW_HOST=127.0.0.1

lan_entries() {
    # Print the subjectAltName list for the self-signed certificate.
    local entries=() seen=" " name ip entry out="" hosts addrs
    add_entry() {
        case "$seen" in *" $1 "*) return ;; esac
        entries+=("$1")
        seen="$seen$1 "
    }
    add_entry "DNS:localhost"
    add_entry "IP:127.0.0.1"
    name="$(hostname -s 2>/dev/null || true)"
    [ -n "$name" ] && add_entry "DNS:$name"
    name="$(hostname -f 2>/dev/null || true)"
    [ -n "$name" ] && add_entry "DNS:$name"
    hosts="${LAN_HOSTS:-}"
    for name in ${hosts//,/ }; do
        [ -n "$name" ] && add_entry "DNS:$name"
    done
    addrs="${LAN_ADDRS:-}"
    for ip in $(hostname -I 2>/dev/null || true) ${addrs//,/ }; do
        case "$ip" in
            ""|*:*|127.*|0.0.0.0|169.254.*) continue ;;
        esac
        add_entry "IP:$ip"
    done
    if [ "$MODE" = bind ] && [ "$WEB_HOST" != 127.0.0.1 ] && [ "$WEB_HOST" != 0.0.0.0 ]; then
        add_entry "IP:$WEB_HOST"
    fi
    for entry in "${entries[@]}"; do
        out="${out:+$out,}$entry"
    done
    printf '%s' "$out"
}

lan_url_addrs() {
    # Print the IPv4 addresses to show in the ready message.
    local addrs
    if [ "$WEB_HOST" != 0.0.0.0 ]; then
        printf '%s\n' "$WEB_HOST"
        return
    fi
    addrs="${LAN_ADDRS:-}"
    {
        for ip in $(hostname -I 2>/dev/null || true) ${addrs//,/ }; do
            case "$ip" in
                ""|*:*|127.*|0.0.0.0|169.254.*) continue ;;
            esac
            printf '%s\n' "$ip"
        done
    } | sort -u
}

TLS_CERT="${LAN_TLS_CERT:-}"
TLS_KEY="${LAN_TLS_KEY:-}"
if [ "$NETWORK_MODE" = 1 ]; then
    if [ -n "$TLS_CERT" ] || [ -n "$TLS_KEY" ]; then
        if [ -z "$TLS_CERT" ] || [ -z "$TLS_KEY" ]; then
            echo "set both LAN_TLS_CERT and LAN_TLS_KEY" >&2
            exit 1
        fi
        TLS_CERT="$(readlink -f "$TLS_CERT")"
        TLS_KEY="$(readlink -f "$TLS_KEY")"
        if [ ! -r "$TLS_CERT" ] || [ ! -r "$TLS_KEY" ]; then
            echo "cannot read LAN_TLS_CERT or LAN_TLS_KEY" >&2
            exit 1
        fi
    else
        if ! command -v openssl >/dev/null 2>&1; then
            echo "openssl is required to make the self-signed certificate" >&2
            exit 1
        fi
        TLS_DIR="$LOGS/tls"
        mkdir -p "$TLS_DIR"
        TLS_CERT="$TLS_DIR/reo-lan.crt"
        TLS_KEY="$TLS_DIR/reo-lan.key"
        SAN_LIST="$(lan_entries)"
        if [ ! -s "$TLS_CERT" ] || [ ! -s "$TLS_KEY" ] \
                || [ "$(cat "$TLS_DIR/reo-lan.sans" 2>/dev/null || true)" != "$SAN_LIST" ]; then
            if ! openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
                    -keyout "$TLS_KEY" -out "$TLS_CERT" \
                    -subj "/CN=reo-local" \
                    -addext "subjectAltName=$SAN_LIST" \
                    -addext "basicConstraints=critical,CA:FALSE" \
                    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
                    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1; then
                echo "cannot create the self-signed certificate" >&2
                exit 1
            fi
            chmod 600 "$TLS_KEY"
            chmod 644 "$TLS_CERT"
            printf '%s' "$SAN_LIST" > "$TLS_DIR/reo-lan.sans"
        fi
    fi
fi

if [ "$NETWORK_MODE" = 1 ]; then
    PCAP="${PCAP:-0}"
else
    PCAP="${PCAP:-1}"
fi
pcap_args=()
if [ "$PCAP" = 1 ]; then
    mkdir -p "$LOGS/pcap"
    pcap_args=(-pcap "$LOGS/pcap")
fi

[ -x "$GATEWAY" ] || { echo "no gateway binary: cd $HERE/net/gateway && go build -o bin/reo-gateway ./cmd/reo-gateway" >&2; exit 1; }
[ -f "$RECOMP/build/web-$GAME/ps2web.html" ] || { echo "no web build: cd $RECOMP && scripts/build_web.sh $GAME" >&2; exit 1; }
[ -e "$RECOMP/games/$GAME/disc.iso" ] || { echo "no disc image at $RECOMP/games/$GAME/disc.iso (run scripts/port.sh first)" >&2; exit 1; }
listening() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
udp_listening() { ss -Hlun "sport = :$1" 2>/dev/null | grep -q .; }
for p in "$GW_PORT" "$WEB_PORT" "$APP_PORT" "$API_PORT"; do
    if listening "$p"; then echo "port $p is already in use. Stop what uses it or pick another (GW_PORT/WEB_PORT/APP_PORT/API_PORT)." >&2; exit 1; fi
done
if udp_listening "$KK_PORT"; then echo "UDP port $KK_PORT is already in use (another lobby server?)" >&2; exit 1; fi
# The Java server needs MariaDB (the File #1/#2 JP lobbies use it).
if [ -z "${SERVER_CMD:-}" ] && [ "${PYAPP:-0}" != 1 ] && ! (echo > /dev/tcp/127.0.0.1/3306) 2>/dev/null; then
    echo "starting MariaDB (sudo)..."
    sudo -n service mariadb start >/dev/null 2>&1 || sudo -n systemctl start mariadb 2>/dev/null || {
        echo "MariaDB is not running. From Windows: wsl -u root -e service mariadb start" >&2; exit 1; }
fi

# Gateway limits are generous here: every local window (up to 4 players and their reloads) comes from 127.0.0.1.
# In network mode the gateway stays on loopback and serve.py proxies /eth to it. The proxy sends the real client
# address in X-Forwarded-For, so the gateway applies the per-IP limits to each device.
# Gateway: only the game's own services are reachable (allowlist), DNS answers
# *.reo.capcom.sf.yav4.com with 198.18.0.10 (app01, File #1 lobby), *.capcom.client.sf.yav4.com with 198.18.0.11
# (File #2 lobby: the second kk instance on KK2_PORT), and only the web page's origin may connect.
if [ "$NETWORK_MODE" = 1 ]; then
    ORIGIN_PATTERNS="\"*:$WEB_PORT\""
    PROXY_FIELDS=" \"trust_proxy\": true, \"trusted_proxies\": [\"127.0.0.1\", \"::1\"], \"real_ip_header\": \"X-Forwarded-For\","
else
    ORIGIN_PATTERNS="\"localhost:$WEB_PORT\", \"127.0.0.1:$WEB_PORT\""
    PROXY_FIELDS=""
fi
cat > "$LOGS/gateway.json" <<EOF
{
 "listen": "$GW_HOST:$GW_PORT",
 "path": "/eth",
 "origin_patterns": [$ORIGIN_PATTERNS],
$PROXY_FIELDS
 "network": {"gateway": "10.0.2.2", "client": "10.0.2.15", "prefix_len": 24, "gateway_mac": "52:55:0a:00:02:02", "lease_secs": 86400, "domain_name": "reo.local"},
 "dns": {"overrides": {"*.reo.capcom.sf.yav4.com": "198.18.0.10", "*.capcom.client.sf.yav4.com": "198.18.0.11", "*.dnas.playstation.org": "198.18.0.20"}, "ttl": 60},
 "allow": [
  {"proto": "tcp", "dst": "198.18.0.10:10127", "upstream": "127.0.0.1:$APP_PORT"},
  {"proto": "tcp", "dst": "198.18.0.10:80", "upstream": "127.0.0.1:8080"},
  {"proto": "tcp", "dst": "198.18.0.10:8300", "upstream": "127.0.0.1:8300"},
  {"proto": "tcp", "dst": "198.18.0.10:8690", "upstream": "127.0.0.1:8690"},
  {"proto": "udp", "dst": "198.18.0.10:9090", "upstream": "127.0.0.1:$KK_PORT"},
  {"proto": "udp", "dst": "198.18.0.11:9090", "upstream": "127.0.0.1:$KK2_PORT"}
 ],
 "limits": {"max_sessions": 64, "max_sessions_per_ip": 32, "connects_per_min_per_ip": 600,
            "ip_frames_per_sec": 100000, "ip_bytes_per_sec": 67108864, "frames_per_sec": 3000, "bytes_per_sec": 2097152, "max_flows": 32,
            "idle_timeout": "15m", "udp_idle": "60s", "dial_timeout": "5s"}
}
EOF

# Admin token for /api/admin and the metrics panel (/admin): REO_ADMIN_TOKEN, else one kept in $LOGS/admin-token.
if [ -z "${REO_ADMIN_TOKEN:-}" ]; then
    [ -s "$LOGS/admin-token" ] || (umask 077; head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LOGS/admin-token")
    REO_ADMIN_TOKEN="$(cat "$LOGS/admin-token")"
fi
export REO_ADMIN_TOKEN
METRICS_TZ="${METRICS_TZ:-UTC}"

pids=(); stopping=""
cleanup() {
    stopping=1
    trap - INT TERM EXIT
    echo; echo "stopping..."
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

if [ -n "${SERVER_CMD:-}" ]; then
    bash -c "$SERVER_CMD" > "$LOGS/server.log" 2>&1 & pids+=($!)
elif [ "${PYAPP:-0}" != 1 ] && [ -f "$HERE/server/build/reo-bioserver.jar" ]; then
    # Java server (default): US app01 service on APP_PORT (protocol "us"), regweb stand-in on 8080,
    # File #1/#2 lobbies (8300/8690, 8200/8590) and the HTTP API on 8088. Needs MariaDB running.
    # News page of app01: an empty one (size 0) makes the client ask 0x6402 and fail with D901, so a
    # one-line page is served (one X press on the news screen).
    printf "<HTML><BODY>reo-web local server<BR>Welcome to the Raccoon City network.</BODY></HTML>" > "$LOGS/news.htm"
    (cd "$HERE/server" && JAVA_OPTS="-Dreo.bind=127.0.0.1 -Dreo.api.names_per_ip_hour=100 -Dreo.us.app.info_file=$LOGS/news.htm -Dreo.us.app.port=$APP_PORT -Dreo.api.port=$API_PORT -Dreo.us.kk.port=$KK_PORT -Dreo.us.kk2.port=$KK2_PORT -Dreo.us.kk2.public_port=9090 -Dreo.metrics.tz=$METRICS_TZ ${JAVA_OPTS:-}" exec scripts/run.sh) > "$LOGS/server.log" 2>&1 & pids+=($!)
else
    python3 "$HERE/server/tools/usapp.py" --port "$APP_PORT" --log "$LOGS/server.log" > "$LOGS/server.out" 2>&1 & pids+=($!)
fi
"$GATEWAY" -config "$LOGS/gateway.json" "${pcap_args[@]}" > "$LOGS/gateway.log" 2>&1 & pids+=($!)
# One web server for every built game: /file1/ (outbreak1), /file2/ (outbreak2), game picker at /.
sites=()
for g in outbreak1:file1 outbreak2:file2; do
    if [ -f "$RECOMP/build/web-${g%%:*}/ps2web.wasm" ] && [ -e "$RECOMP/games/${g%%:*}/disc.iso" ]; then
        sites+=("${g#*:}=build/web-${g%%:*},games/${g%%:*}/disc.iso")
    fi
done
serve_args=("${sites[@]}" "$WEB_PORT" --host "$WEB_HOST" --api "http://127.0.0.1:$API_PORT")
if [ "$NETWORK_MODE" = 1 ]; then
    serve_args+=(--tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" --gateway "127.0.0.1:$GW_PORT")
fi
(cd "$RECOMP" && exec python3 scripts/serve.py "${serve_args[@]}") > "$LOGS/web.log" 2>&1 & pids+=($!)

checks=("server:$APP_PORT" "gateway:$GW_PORT" "web:$WEB_PORT")
[ -n "${SERVER_CMD:-}" ] || [ "${PYAPP:-0}" = 1 ] || checks+=("server:$API_PORT")
for name_port in "${checks[@]}"; do
    for _ in $(seq 50); do listening "${name_port#*:}" && break; sleep 0.2; done
    if listening "${name_port#*:}"; then echo "  ${name_port%%:*} listening on ${name_port#*:}"
    else echo "  ${name_port%%:*} did not start, see $LOGS/${name_port%%:*}.log" >&2; exit 1; fi
done
if [ -z "${SERVER_CMD:-}" ] && [ "${PYAPP:-0}" != 1 ]; then
    for _ in $(seq 25); do udp_listening "$KK_PORT" && break; sleep 0.2; done
    udp_listening "$KK_PORT" && echo "  lobby (kk) listening on UDP $KK_PORT" || echo "  warning: no UDP $KK_PORT (see $LOGS/server.log)"
fi

pcap_note=""
if [ "$PCAP" = 1 ]; then
    pcap_note="  (pcaps in $LOGS/pcap)"
fi

if [ "$NETWORK_MODE" = 1 ]; then
    SCHEME=https
    if [ "$WEB_HOST" = 0.0.0.0 ]; then PAGE_HOST=localhost; else PAGE_HOST="$WEB_HOST"; fi
    PLAYERS_NOTE="Players on other devices: open one of the URLs above. Two players on this PC: a normal Chrome window and an incognito one."
    echo
    echo "Ready. Open one of these URLs from another device:"
    while IFS= read -r ip; do
        [ -n "$ip" ] && printf '  https://%s:%s/\n' "$ip" "$WEB_PORT"
    done < <(lan_url_addrs)
    if [ "$WEB_HOST" = 0.0.0.0 ]; then
        printf '  https://localhost:%s/   (this machine only)\n' "$WEB_PORT"
    fi
    echo
    echo "The certificate is self-signed. Accept the browser warning once on each device."
    echo "Only TCP $WEB_PORT needs to be open in the firewall."
    if [ -n "${WSL_DISTRO_NAME:-}" ]; then
        echo "WSL2: if Windows uses NAT, forward TCP $WEB_PORT to this distribution. See docs/playing-online.md."
    fi
else
    SCHEME=http
    PAGE_HOST=localhost
    PLAYERS_NOTE="Two players: a normal Chrome window and an incognito one, with a different name in each."
    url="http://localhost:$WEB_PORT/"
    [ "$GW_PORT" = 8765 ] || url+="?gateway=ws://localhost:$GW_PORT/eth"
    echo
    echo "Ready. Open $url"
fi
cat <<EOF
$PLAYERS_NOTE
File #1 -> Iniciar -> Network (steps: docs/playing-online.md). Rooms: $SCHEME://$PAGE_HOST:$WEB_PORT/api/rooms
Metrics panel (owner): $SCHEME://$PAGE_HOST:$WEB_PORT/admin  token: $REO_ADMIN_TOKEN
Logs: $LOGS/{server,gateway,web}.log$pcap_note
Ctrl+C stops everything.
EOF
wait -n "${pids[@]}" || true
[ -n "$stopping" ] || echo "A process exited. See the logs in $LOGS."
