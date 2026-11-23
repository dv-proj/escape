#!/usr/bin/env bash
# xray-config.sh - manage the 3x-ui panel (with Xray) of the xray-3xui extension
# without install.sh: needs bash, docker with the compose plugin, iproute2,
# openssl and python3, plus the project directory (APP_DIR in the state file).
# No network except `docker pull` of the pinned image (the saved image tar is
# loaded when the registry is unreachable).
#
# State: data/xray-3xui/state.env (written by the installer; mode 600; holds the
# panel password, the secret panel path, the REALITY keys and the client UUIDs).
#
# What runs where:
#   - the panel listens on PANEL_PORT inside the container only; nginx serves it
#     at https://DOMAIN/PANEL_PATH/ (data/nginx/locations.d/xray-3xui.conf);
# Two stages. Stage 1 (the default): the panel and the "plain" inbound. Stage 2
# (opt-in, WL_ENABLED=1, see `wl on`): the "wl" inbound as well.
#   - inbound "plain" (PLAIN_MODE selfsteal, see `plain`): REALITY on a SEPARATE
#     DNS name (PLAIN_DOMAIN) that has its own Let's Encrypt certificate and an
#     nginx server block with the decoy site. It listens on the internal port
#     PLAIN_INTERNAL_PORT (not published); the TLS front sends the connections
#     with SNI = PLAIN_DOMAIN there (same stream map as "wl"); the REALITY target
#     is the HTTPS server of this nginx, so a probe sees the real site and its
#     certificate;
#   - inbound "wl" (stage 2; VLESS + REALITY, SNI from the whitelist WL_SNI,
#     target WL_SNI:443) listens on WL_PORT in the container; the TLS front of nginx
#     (host HTTPS port) sends connections whose SNI is in WL_SNI there, with
#     the PROXY protocol (data/nginx/stream.d/xray-3xui.map);
#   - the container's own traffic leaves through the chosen outway (policy
#     routing of its own docker network, xray-outway.sh).
#
#   show | credentials   panel URL, login, password and the client links
#   link [wl|plain]      the vless:// links (of the enabled inbounds by default)
#   status               container, panel, inbounds, nginx routes, outway, default route
#   apply                render + image + outway + container + panel + inbounds + nginx
#   panel                panel login, password, port and secret path (x-ui CLI / API)
#   inbounds [--recreate] [--new-keys]
#                        create or update the enabled inbounds through the panel API
#                        (idempotent; --recreate deletes and creates them again with
#                        the same keys and UUIDs, --new-keys also generates new ones:
#                        the old links stop working)
#   plain selfsteal [NAME] | plain off
#                        the "plain" inbound on the separate name NAME (REALITY, target =
#                        this nginx; NAME must point to this server) or off
#   wl on [NAME[,NAME...]] | wl off
#                        stage 2: enable the "wl" inbound (whitelist SNI; NAME defaults to
#                        the current one, else ozon.ru; REALITY target = the first name)
#                        or disable it; wl-sni NAME[,NAME...] = wl on NAME[,NAME...]
#   outway [IFACE]       change the outgoing interface (prompts when IFACE is omitted)
#   rotate password|path|all   new panel password and/or secret path
#   render               regenerate docker-compose.yml and the nginx snippets
#   pull                 pull the pinned image (or `docker load` the saved tar) and save it
#   restart              restart the container
#   net-setup [--redetect] | net-check | check-route
#   migrate-state        drop the state keys of the earlier published "plain" port
#   state-get KEY | state-set KEY VALUE
#
# Environment: XRAY_STATE (state file), XRAY_DRY_RUN=1 (outway commands are only
# printed), XRAY_FORCE_PULL=1, XRAY_OUTWAY_FAMILIES=4|6|46 (override the detection
# of the families of the outway).
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
STATE_FILE="${XRAY_STATE:-@STATE_FILE@}"
if [[ "$STATE_FILE" == "@STATE_FILE@" ]]; then
    STATE_FILE="$HERE/../../data/xray-3xui/state.env"
fi
STATE_FILE="$(readlink -m "$STATE_FILE")"
X_DIR="$(dirname "$STATE_FILE")"
LOC_ID="xray-3xui"
SERVICE="xui"
WL_TAG="escape-wl"
PLAIN_TAG="escape-plain"
PLAIN_INTERNAL_PORT=10444

say() { printf '%s\n' "$*" >&2; }
info() { say "    $*"; }
warn() { say "warning: $*"; }
die() {
    say "error: $*"
    exit 1
}

# outway ARGS...: the installed copy (xray-outway.sh, XRAY_* environment), else the
# shared script of the repository (TGPROXY_* environment of that file).
outway() {
    if [[ -f "$HERE/xray-outway.sh" ]]; then
        XRAY_STATE="$STATE_FILE" bash "$HERE/xray-outway.sh" "$@"
    else
        TGPROXY_STATE="$STATE_FILE" TGPROXY_DRY_RUN="${XRAY_DRY_RUN:-0}" TGPROXY_FW="${XRAY_FW:-}" \
            TGPROXY_OUTWAY_FAMILIES="${XRAY_OUTWAY_FAMILIES:-}" TGPROXY_DRY_ASSUME_UP="${XRAY_DRY_ASSUME_UP:-0}" \
            bash "$HERE/../telegram-web-proxy/tgproxy-outway.sh" "$@"
    fi
}

# --- state ------------------------------------------------------------------------

state_get() {
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1
}

# state_set KEY VALUE: atomic rewrite, mode 600.
state_set() {
    local key=$1 val=$2 tmp
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "bad state key '$key'"
    [[ "$val" =~ ^[A-Za-z0-9_./:@%+,=-]*$ ]] || die "bad characters in the value of $key"
    mkdir -p "$X_DIR"
    tmp="$(umask 077 && mktemp "$STATE_FILE.XXXXXX")"
    { grep -v "^$key=" "$STATE_FILE" 2>/dev/null || true; } >"$tmp"
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

KEYS=(APP_DIR DOMAIN COMPOSE_PROJECT NET_NAME NET_SUBNET NET_GATEWAY XUI_IP NET_SUBNET6 NET_GATEWAY6 XUI_IP6
    OUTWAY OUTWAY_FAMILIES SHARED_SUBNET XUI_IMAGE MEM_LIMIT SAVE_IMAGE PANEL_PORT PANEL_PATH PANEL_USER PANEL_PASSWORD
    WL_ENABLED WL_SNI WL_PORT WL_UUID WL_SID WL_PRIVATE_KEY WL_PUBLIC_KEY PLAIN_MODE PLAIN_DOMAIN PLAIN_UUID PLAIN_SID
    PLAIN_PRIVATE_KEY PLAIN_PUBLIC_KEY PUBLIC_HOST HTTPS_PORT FINGERPRINT)
WL_ENABLED="" APP_DIR="" DOMAIN="" COMPOSE_PROJECT="" NET_NAME="" NET_SUBNET="" NET_GATEWAY="" XUI_IP="" NET_SUBNET6="" NET_GATEWAY6=""
XUI_IP6="" OUTWAY="" OUTWAY_FAMILIES="" SHARED_SUBNET="" XUI_IMAGE="" MEM_LIMIT="" SAVE_IMAGE="" PANEL_PORT="" PANEL_PATH=""
PANEL_USER="" PANEL_PASSWORD="" WL_SNI="" WL_PORT="" WL_UUID="" WL_SID="" WL_PRIVATE_KEY="" WL_PUBLIC_KEY="" PLAIN_MODE=""
PLAIN_DOMAIN="" PLAIN_UUID="" PLAIN_SID="" PLAIN_PRIVATE_KEY="" PLAIN_PUBLIC_KEY="" PUBLIC_HOST="" HTTPS_PORT="" FINGERPRINT=""
V6=0
load_state() {
    [[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE (is the extension installed?)"
    local k
    for k in "${KEYS[@]}"; do
        printf -v "$k" '%s' "$(state_get "$k")"
    done
    for k in APP_DIR DOMAIN NET_SUBNET NET_GATEWAY XUI_IP XUI_IMAGE OUTWAY PANEL_PATH PANEL_PASSWORD; do
        [[ -n "${!k}" ]] || die "$k is missing in $STATE_FILE"
    done
    COMPOSE_PROJECT="${COMPOSE_PROJECT:-escape}"
    NET_NAME="${NET_NAME:-${COMPOSE_PROJECT}-xray}"
    MEM_LIMIT="${MEM_LIMIT:-192m}"
    SAVE_IMAGE="${SAVE_IMAGE:-1}"
    PANEL_PORT="${PANEL_PORT:-2053}"
    PANEL_USER="${PANEL_USER:-admin}"
    WL_PORT="${WL_PORT:-10443}"
    WL_SNI="${WL_SNI:-ozon.ru}"
    [[ "$WL_ENABLED" == 1 ]] || WL_ENABLED=0
    PLAIN_DOMAIN="${PLAIN_DOMAIN,,}"
    # selfsteal | off ("direct" and the published port of earlier versions are gone).
    [[ "$PLAIN_MODE" == selfsteal && -n "$PLAIN_DOMAIN" ]] || PLAIN_MODE=off
    PUBLIC_HOST="${PUBLIC_HOST:-$DOMAIN}"
    HTTPS_PORT="${HTTPS_PORT:-443}"
    FINGERPRINT="${FINGERPRINT:-chrome}"
    OUTWAY_FAMILIES="${OUTWAY_FAMILIES:-4}"
    V6=0
    [[ -z "$NET_SUBNET6" || -z "$NET_GATEWAY6" || -z "$XUI_IP6" ]] || V6=1
}

plain_on() { [[ "$PLAIN_MODE" == selfsteal && -n "$PLAIN_DOMAIN" ]]; }

# wl_on: stage 2, the "wl" inbound is enabled.
wl_on() { [[ "$WL_ENABLED" == 1 ]]; }

# routes_any: some inbound is routed by the TLS front (the stream map has routes).
routes_any() { plain_on || wl_on; }

# state_del KEY: remove a key from the state file (atomic).
state_del() {
    local tmp
    [[ -f "$STATE_FILE" ]] || return 0
    grep -q "^$1=" "$STATE_FILE" || return 0
    tmp="$(umask 077 && mktemp "$STATE_FILE.XXXXXX")"
    { grep -v "^$1=" "$STATE_FILE" || true; } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# migrate_state: drop what only the published "plain" port needed (earlier versions);
# an old PLAIN_MODE without a name (nothing to route) becomes "off".
migrate_state() {
    local k
    for k in PLAIN_PORT OUTWAY_BRIDGE OUTWAY_REPLY_MARK OUTWAY_INBOUND_PORTS OUTWAY_REPLY_PRIO; do state_del "$k"; done
    # Installations of the version that always had the "wl" inbound keep it.
    if [[ -z "$(state_get WL_ENABLED)" ]]; then
        if [[ -n "$(state_get WL_UUID)" ]]; then state_set WL_ENABLED 1; else state_set WL_ENABLED 0; fi
    fi
    case "$(state_get PLAIN_MODE)" in
        selfsteal | off | "") ;;
        *) state_set PLAIN_MODE off ;;
    esac
}

# wl_names: the whitelist SNI, one per line; wl_first: the REALITY target name.
wl_names() { tr ',' '\n' <<<"$WL_SNI" | sed '/^$/d'; }
wl_first() { wl_names | head -n1; }

# --- docker ---------------------------------------------------------------------------

# compose ARGS...: docker compose of the project with a clean environment.
compose() {
    env -i -C "$APP_DIR" \
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "HOME=${HOME:-/root}" "LANG=C.UTF-8" "TERM=${TERM:-dumb}" \
        docker compose "$@"
}

need_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found"
    docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (not running, or no permission: try sudo)"
}

xui_cid() { compose ps -q "$SERVICE" 2>/dev/null | head -n1 || true; }
nginx_running() { [[ -n "$(compose ps -q nginx 2>/dev/null | head -n1)" ]]; }

# --- nginx ------------------------------------------------------------------------

ngx_dir() { printf '%s/data/nginx' "$APP_DIR"; }

nginx_check_reload() {
    nginx_running || {
        info "nginx is not running; the routes are used at its next start"
        return 0
    }
    compose exec -T nginx nginx -t >&2 || return 1
    compose exec -T nginx nginx -s reload >&2
}

# front_ready: the base config has the TLS front (install.sh of a version with the
# stream block) and the running nginx has it mounted.
front_ready() {
    local base
    base="$(ngx_dir)/conf.d/front.stream"
    [[ -f "$base" ]] || die "the nginx config has no TLS front ($base): update the project and run: sudo $APP_DIR/install.sh restart"
    if nginx_running && ! compose exec -T nginx test -d /etc/nginx/stream.d >/dev/null 2>&1; then
        info "nginx is recreated once to mount data/nginx/stream.d (TLS front)"
        compose up -d --wait nginx </dev/null >&2
    fi
}

# le_have NAME: the Let's Encrypt certificate of NAME exists.
le_have() {
    local le="$APP_DIR/data/letsencrypt/live/$1"
    [[ -s "$le/fullchain.pem" && -s "$le/privkey.pem" ]]
}

# cert_paths NAME: "CERT KEY" inside the nginx container: Let's Encrypt when issued,
# else the temporary self-signed certificate of NAME (created when missing). Same
# rule as ext_cert_paths of install.sh.
cert_paths() {
    local name=$1 dir
    if le_have "$name"; then
        printf '/etc/letsencrypt/live/%s/fullchain.pem /etc/letsencrypt/live/%s/privkey.pem\n' "$name" "$name"
        return 0
    fi
    dir="$(ngx_dir)/selfsigned/$name"
    if [[ ! -s "$dir/fullchain.pem" || ! -s "$dir/privkey.pem" ]]; then
        mkdir -p "$dir"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
            -addext "subjectAltName=DNS:$name" -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" 2>/dev/null ||
            die "cannot create the temporary self-signed certificate of $name (openssl)"
        chmod 600 "$dir/privkey.pem"
        info "temporary self-signed certificate created for $name"
    fi
    printf '/etc/nginx/selfsigned/%s/fullchain.pem /etc/nginx/selfsigned/%s/privkey.pem\n' "$name" "$name"
}

# certs_list_set NAME: register NAME (empty: drop) for this extension in
# data/nginx/extra-certs.list (same format as install.sh ext_cert_request).
certs_list_set() {
    local f name=${1:-} tmp
    f="$(ngx_dir)/extra-certs.list"
    tmp="$(mktemp "$f.XXXXXX")"
    {
        printf '# Generated by install.sh (ext_cert_request): "<extension id> <name>" per line.\n'
        if [[ -f "$f" ]]; then
            grep -E '^[a-z0-9][a-z0-9_-]* [A-Za-z0-9.-]+$' "$f" | awk -v id="$LOC_ID" '$1 != id' || true
        fi
        [[ -z "$name" ]] || printf '%s %s\n' "$LOC_ID" "$name"
    } >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$f"
}

# server_render_installed: servers.d/<id>.conf from its .conf.in (same rule as
# install.sh render_ext_servers: the certificate of the "# cert-domain:" name).
server_render_installed() {
    local src out name cert key content tmp
    src="$(ngx_dir)/servers.d/$LOC_ID.conf.in"
    out="${src%.in}"
    [[ -f "$src" ]] || return 0
    content="$(<"$src")"
    name="$(sed -n '1s/^# cert-domain: \([A-Za-z0-9.-]*\)$/\1/p' "$src")"
    if [[ -n "$name" ]]; then
        read -r cert key < <(cert_paths "$name")
        [[ -n "$key" ]] || die "no certificate for $name"
        content="${content//@SSL_CERT@/$cert}"
        content="${content//@SSL_KEY@/$key}"
    fi
    tmp="$(mktemp "$out.XXXXXX")"
    printf '%s\n' "$content" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

# nginx_apply_routes: install the panel location, the http-level snippet (with the
# server blocks of the "plain" name and its certificate registration) and the TLS
# front routes (rolled back together when nginx rejects the result).
nginx_apply_routes() {
    local loc srv_in srv map bdir f
    loc="$(ngx_dir)/locations.d/$LOC_ID.conf"
    srv_in="$(ngx_dir)/servers.d/$LOC_ID.conf.in"
    srv="$(ngx_dir)/servers.d/$LOC_ID.conf"
    map="$(ngx_dir)/stream.d/$LOC_ID.map"
    mkdir -p "$(ngx_dir)/locations.d" "$(ngx_dir)/servers.d" "$(ngx_dir)/stream.d"
    front_ready
    bdir="$(mktemp -d "$X_DIR/.nginx-backup.XXXXXX")"
    for f in "$loc" "$srv_in" "$srv" "$map"; do
        [[ ! -f "$f" ]] || cp -p "$f" "$bdir/$(basename "$f")"
    done
    {
        ! plain_on || printf '# cert-domain: %s\n' "$PLAIN_DOMAIN"
        cat "$X_DIR/nginx-http.conf"
    } >"$srv_in.tmp"
    chmod 644 "$srv_in.tmp"
    mv -f "$srv_in.tmp" "$srv_in"
    server_render_installed
    if plain_on; then certs_list_set "$PLAIN_DOMAIN"; else certs_list_set ""; fi
    install -m 644 "$X_DIR/nginx-location.conf" "$loc"
    if routes_any; then install -m 644 "$X_DIR/nginx-stream.map" "$map"; else rm -f "$map"; fi
    if nginx_check_reload; then
        rm -rf "$bdir"
        return 0
    fi
    rm -f "$loc" "$srv_in" "$srv" "$map"
    for f in "$loc" "$srv_in" "$srv" "$map"; do
        [[ ! -f "$bdir/$(basename "$f")" ]] || mv -f "$bdir/$(basename "$f")" "$f"
    done
    rm -rf "$bdir"
    die "nginx rejected the routes of the panel / the TLS front (rolled back)"
}

# register_compose: entry of this extension in data/extensions.compose.yml (same
# format as install.sh ext_register_compose), kept when already present.
register_compose() {
    local f="$APP_DIR/data/extensions.compose.yml" want="$X_DIR/docker-compose.yml" line tmp i
    local -a ids=() paths=()
    if [[ -f "$f" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\"(.*)\"[[:space:]]+#[[:space:]]+([a-z0-9][a-z0-9_-]*)$ ]]; then
                [[ "${BASH_REMATCH[2]}" != "$LOC_ID" ]] || continue
                paths+=("${BASH_REMATCH[1]}")
                ids+=("${BASH_REMATCH[2]}")
            fi
        done <"$f"
    fi
    ids+=("$LOC_ID")
    paths+=("$want")
    tmp="$(mktemp "$f.XXXXXX")"
    {
        printf '# Generated by install.sh (ext_register_compose): do not edit.\ninclude:\n'
        for i in "${!ids[@]}"; do
            printf '  - "%s" # %s\n' "${paths[i]}" "${ids[i]}"
        done
    } >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$f"
}

# --- rendering ------------------------------------------------------------------------------

gw_priority_supported() {
    local sv cv
    sv="$(docker version -f '{{.Server.Version}}' 2>/dev/null || true)"
    cv="$(docker compose version --short 2>/dev/null || true)"
    sv="${sv#v}"
    cv="${cv#v}"
    [[ "$sv" =~ ^([0-9]+)\. ]] && ((BASH_REMATCH[1] >= 28)) || return 1
    [[ "$cv" =~ ^([0-9]+)\.([0-9]+) ]] && ((BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 33)))
}

render_compose() {
    local out="$X_DIR/docker-compose.yml" tmp prio="" ip6="" net6="" ipam6="" expose
    tmp="$(mktemp "$out.XXXXXX")"
    gw_priority_supported && prio="        gw_priority: 100"
    if ((V6)); then
        ip6="        ipv6_address: $XUI_IP6"
        net6="    enable_ipv6: true"
        ipam6="        - subnet: $NET_SUBNET6
          gateway: $NET_GATEWAY6"
    fi
    expose="      - \"$PANEL_PORT\""
    if wl_on; then
        expose+="
      - \"$WL_PORT\""
    fi
    if plain_on; then
        expose+="
      - \"$PLAIN_INTERNAL_PORT\""
    fi
    cat >"$tmp" <<EOF_YML
# Generated by the xray-3xui extension (escape): do not edit, it is rewritten by
# xray-config.sh. 3x-ui panel with Xray (https://github.com/MHSanaei/3x-ui).
# The panel port and the inbound ports are not published: nginx reaches them over the
# project network. The container sits on two networks: the project network
# (nginx <-> panel / inbounds) and its own network $NET_NAME, which carries its
# default route; the host policy-routes that subnet through the chosen outway
# (xray-outway.sh).
services:
  $SERVICE:
    image: $XUI_IMAGE
    restart: unless-stopped
    mem_limit: $MEM_LIMIT
    pids_limit: 256
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    environment:
      # No fail2ban (it needs NET_ADMIN and would change iptables of the container).
      XUI_ENABLE_FAIL2BAN: "false"
      XRAY_VMESS_AEAD_FORCED: "false"
      # Used only by a fresh database; the installer sets the path with the CLI too.
      XUI_INIT_WEB_BASE_PATH: "/$PANEL_PATH/"
      TZ: "\${TZ:-UTC}"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    expose:
$expose
    networks:
      default: {}
      xray:
        ipv4_address: $XUI_IP
${ip6:+$ip6
}${prio:+$prio
}    volumes:
      # Panel database (users, settings, inbounds): data/xray-3xui/db.
      - ./db:/etc/x-ui
    healthcheck:
      # The panel answers HTTP (any status) on its port.
      test: ["CMD-SHELL", "curl -s -o /dev/null --max-time 4 http://127.0.0.1:$PANEL_PORT/ || exit 1"]
      interval: 30s
      timeout: 6s
      retries: 3
      start_period: 40s
    logging:
      driver: json-file
      options:
        max-size: "\${LOG_MAX_SIZE:-5m}"
        max-file: "\${LOG_MAX_FILE:-3}"

networks:
  xray:
    name: $NET_NAME
    driver: bridge
${net6:+$net6
}    ipam:
      config:
        - subnet: $NET_SUBNET
          gateway: $NET_GATEWAY${ipam6:+
$ipam6}
EOF_YML
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

# render_nginx: nginx-location.conf (the secret path of the panel in the server
# of the site), nginx-http.conf (http level: the rate-limit zone, the WebSocket
# map, trust of the PROXY protocol header sent by the "plain" inbound, and, when the
# "plain" inbound is on, the server blocks of its name with the decoy site;
# @SSL_CERT@ / @SSL_KEY@ are filled in when the file is installed) and
# nginx-stream.map (TLS front: the whitelist SNI -> the "wl" inbound, the plain
# name -> the "plain" inbound).
render_nginx() {
    local p="$PANEL_PATH" body tmp n
    body="    access_log off;
    limit_req zone=xray3xui_panel burst=60 nodelay;
    client_max_body_size 64m;
    resolver 127.0.0.11 valid=10s ipv6=off;
    set \$xui_panel_upstream http://$SERVICE:$PANEL_PORT;
    proxy_pass \$xui_panel_upstream;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$xui_connection_upgrade;
    proxy_connect_timeout 5s;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
    # Panel down or rate limit hit: the decoy answers, the path stays unremarkable.
    error_page 502 503 504 = @xray3xui_decoy;"
    tmp="$(mktemp "$X_DIR/nginx-location.conf.XXXXXX")"
    cat >"$tmp" <<EOF_LOC
# xray-3xui: ONLY the secret path goes to the 3x-ui panel; every other path is
# served by the decoy via "location /". Generated by xray-config.sh: do not edit.
location = /$p {
$body
}
location ^~ /$p/ {
$body
}
location @xray3xui_decoy {
    access_log off;
    resolver 127.0.0.11 valid=10s ipv6=off;
    set \$xui_decoy_upstream http://fakeapp:$(fakeapp_port);
    proxy_pass \$xui_decoy_upstream;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF_LOC
    chmod 644 "$tmp"
    mv -f "$tmp" "$X_DIR/nginx-location.conf"

    tmp="$(mktemp "$X_DIR/nginx-http.conf.XXXXXX")"
    cat >"$tmp" <<EOF_HTTP
# xray-3xui: http-level settings (included from servers.d). Generated by
# xray-config.sh: do not edit.
# Rate limit of the panel path (per client address).
limit_req_zone \$binary_remote_addr zone=xray3xui_panel:1m rate=10r/s;
# WebSocket upgrade for the panel.
map \$http_upgrade \$xui_connection_upgrade {
    default upgrade;
    ''      close;
}
# The "plain" inbound (REALITY, target = this nginx) passes the client address
# with the PROXY protocol from the project network: trust that header.
set_real_ip_from $SHARED_SUBNET;
EOF_HTTP
    if plain_on; then
        cat >>"$tmp" <<EOF_PLAIN
# The "plain" inbound: the name $PLAIN_DOMAIN shows the decoy site with its own
# certificate (REALITY target nginx:443); the TLS front routes the connections of
# real clients to the inbound by SNI, probes get this server.
server {
    listen 80;
    server_name $PLAIN_DOMAIN;
    server_tokens off;
    access_log off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
    }

    location / {
        return 301 https://$PLAIN_DOMAIN\$request_uri;
    }
}

server {
    # Only from the TLS front or the inbound (PROXY protocol, xver 1).
    listen 443 ssl proxy_protocol;
    http2 on;
    server_name $PLAIN_DOMAIN;
    server_tokens off;
    access_log off;

    ssl_certificate     @SSL_CERT@;
    ssl_certificate_key @SSL_KEY@;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:5m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location / {
        resolver 127.0.0.11 valid=10s ipv6=off;
        set \$fakeapp_upstream http://fakeapp:$(fakeapp_port);
        proxy_pass \$fakeapp_upstream;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
EOF_PLAIN
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$X_DIR/nginx-http.conf"

    tmp="$(mktemp "$X_DIR/nginx-stream.map.XXXXXX")"
    {
        printf '# xray-3xui: TLS front routes (the plain name -> the "plain" inbound, the whitelist SNI -> the "wl" inbound when enabled; PROXY protocol).\n'
        if wl_on; then
            while read -r n; do
                printf '%s %s:%s;\n' "$n" "$SERVICE" "$WL_PORT"
            done < <(wl_names)
        fi
        ! plain_on || printf '%s %s:%s;\n' "$PLAIN_DOMAIN" "$SERVICE" "$PLAIN_INTERNAL_PORT"
    } >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$X_DIR/nginx-stream.map"
}

fakeapp_port() {
    local p
    p="$(sed -n 's/^FAKEAPP_PORT=//p' "$APP_DIR/.env" 2>/dev/null | tail -n1 | tr -d "'\"")"
    printf '%s' "${p:-8080}"
}

cmd_render() {
    load_state
    mkdir -p "$X_DIR/db"
    chmod 700 "$X_DIR/db"
    render_compose
    render_nginx
    info "rendered: $X_DIR/docker-compose.yml, nginx-location.conf, nginx-http.conf, nginx-stream.map"
}

# --- image --------------------------------------------------------------------------------

image_tar() { printf '%s/xui-image.tar' "$X_DIR"; }

cmd_pull() {
    local tar tmp
    load_state
    need_docker
    tar="$(image_tar)"
    if [[ "${XRAY_FORCE_PULL:-0}" != 1 ]] && docker image inspect "$XUI_IMAGE" >/dev/null 2>&1; then
        info "image present: $XUI_IMAGE"
    elif docker pull -q "$XUI_IMAGE" >/dev/null; then
        info "pulled $XUI_IMAGE"
    elif [[ -f "$tar" ]]; then
        warn "cannot pull $XUI_IMAGE; loading the saved image $tar"
        docker load -i "$tar" >/dev/null
        docker image inspect "$XUI_IMAGE" >/dev/null 2>&1 || die "the saved image does not contain $XUI_IMAGE"
        return 0
    else
        die "cannot pull $XUI_IMAGE and there is no saved image ($tar)"
    fi
    if [[ "$SAVE_IMAGE" == 1 ]]; then
        tmp="$(mktemp "$tar.XXXXXX")"
        if docker save "$XUI_IMAGE" -o "$tmp"; then
            chmod 600 "$tmp"
            mv -f "$tmp" "$tar"
            info "image saved for offline reinstall: $tar"
        else
            rm -f "$tmp"
            warn "docker save failed; continuing without the offline copy"
        fi
    fi
}

# --- panel API (python3 drives curl inside the container: no host routing needed) ---------------

# xui_api ACTION: run the API client. Input: environment (XUI_*); the password is
# passed in the environment of python and in the request bodies (stdin of curl),
# never on a command line. Prints JSON results on stdout.
xui_api() {
    local cid
    cid="$(xui_cid)"
    [[ -n "$cid" ]] || die "the $SERVICE container is not running"
    XUI_CID="$cid" XUI_PORT="$PANEL_PORT" XUI_PATH="$PANEL_PATH" XUI_USER="$PANEL_USER" XUI_PASS="$PANEL_PASSWORD" \
        XUI_ACTION="$1" XUI_NEW_PASS="${XUI_NEW_PASS:-}" XUI_TRUST="${XUI_TRUST:-}" XUI_SPEC="${XUI_SPEC:-}" \
        python3 -I - <<'PYEOF'
import json, os, subprocess, sys, urllib.parse

cid = os.environ["XUI_CID"]
port = os.environ["XUI_PORT"]
path = os.environ["XUI_PATH"].strip("/")
jar = "/tmp/.escape-xui-api.jar"

def fail(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(1)

def curl(method, url, body=None, ctype=None, csrf=None):
    args = ["docker", "exec", "-i", cid, "curl", "-sS", "--max-time", "30", "-b", jar, "-c", jar,
            "-X", method, "-H", "Accept: application/json", "-H", "X-Requested-With: XMLHttpRequest",
            "-w", "\n%{http_code}"]
    if csrf:
        args += ["-H", "X-CSRF-Token: " + csrf]
    if ctype:
        args += ["-H", "Content-Type: " + ctype]
    if body is not None:
        args += ["--data-binary", "@-"]
    args.append(url)
    r = subprocess.run(args, input=(body or "").encode(), capture_output=True)
    out = r.stdout.decode(errors="replace")
    if r.returncode != 0:
        fail("panel request %s %s failed: %s" % (method, url.split("?")[0], r.stderr.decode(errors="replace").strip()))
    text, _, code = out.rpartition("\n")
    return int(code or 0), text

class Panel:
    def __init__(self, base):
        self.base = "http://127.0.0.1:%s/%s" % (port, base + "/" if base else "")
        self.csrf = None

    def token(self):
        code, text = curl("GET", self.base + "csrf-token")
        if code != 200:
            return None
        try:
            self.csrf = json.loads(text).get("obj")
        except ValueError:
            return None
        return self.csrf

    def login(self, user, pw):
        if not self.token():
            return False
        body = urllib.parse.urlencode({"username": user, "password": pw})
        code, text = curl("POST", self.base + "login", body, "application/x-www-form-urlencoded", self.csrf)
        try:
            ok = code == 200 and json.loads(text).get("success") is True
        except ValueError:
            ok = False
        if ok:
            self.token()
        return ok

    def call(self, method, rel, data=None, form=False):
        body = None
        ctype = None
        if data is not None:
            if form:
                body, ctype = urllib.parse.urlencode(data), "application/x-www-form-urlencoded"
            else:
                body, ctype = json.dumps(data), "application/json"
        code, text = curl(method, self.base + rel, body if method != "GET" else None, ctype, self.csrf if method != "GET" else None)
        if code != 200:
            fail("panel API %s %s: HTTP %s" % (method, rel, code))
        try:
            res = json.loads(text)
        except ValueError:
            fail("panel API %s %s: not JSON" % (method, rel))
        if not res.get("success"):
            fail("panel API %s %s: %s" % (method, rel, res.get("msg") or "failed"))
        return res.get("obj")

def cleanup():
    subprocess.run(["docker", "exec", cid, "rm", "-f", jar], capture_output=True)

action = os.environ["XUI_ACTION"]
user, pw = os.environ["XUI_USER"], os.environ["XUI_PASS"]
try:
    if action == "login-check":
        # 0: stored credentials work; 2: only the default admin/admin works; 1: neither.
        p = Panel(path)
        if p.login(user, pw):
            print("ok")
            sys.exit(0)
        if Panel(path).login("admin", "admin") or Panel("").login("admin", "admin"):
            print("default")
            sys.exit(2)
        print("none")
        sys.exit(1)
    if action == "set-password":
        # Log in with the stored credentials, else with the default admin/admin of a
        # fresh database, then set PANEL_USER / XUI_NEW_PASS.
        new = os.environ["XUI_NEW_PASS"]
        p = Panel(path)
        old_user, old_pw = user, pw
        if not p.login(user, pw):
            old_user, old_pw = "admin", "admin"
            if not p.login(old_user, old_pw):
                fail("cannot log in to the panel (neither the stored nor the default credentials work)")
        p.call("POST", "panel/api/setting/updateUser",
               {"oldUsername": old_user, "oldPassword": old_pw, "newUsername": user, "newPassword": new}, form=True)
        print("ok")
        sys.exit(0)

    p = Panel(path)
    if not p.login(user, pw):
        fail("cannot log in to the panel with the stored credentials (run: xray-config.sh panel)")

    if action == "trust":
        # trustedProxyCIDRs: the panel takes X-Real-IP / X-Forwarded-For of nginx.
        want = os.environ["XUI_TRUST"]
        allset = p.call("POST", "panel/api/setting/all")
        have = [c.strip() for c in str(allset.get("trustedProxyCIDRs", "")).split(",") if c.strip()]
        need = [c for c in want.split(",") if c and c not in have]
        if need:
            allset["trustedProxyCIDRs"] = ",".join(have + need)
            p.call("POST", "panel/api/setting/update", allset)
            print("updated")
        else:
            print("unchanged")
    elif action == "x25519":
        obj = p.call("GET", "panel/api/server/getNewX25519Cert")
        print("%s %s" % (obj["privateKey"], obj["publicKey"]))
    elif action == "list":
        obj = p.call("GET", "panel/api/inbounds/list") or []
        for ib in obj:
            print(json.dumps({"id": ib.get("id"), "tag": ib.get("tag"), "port": ib.get("port"),
                              "protocol": ib.get("protocol"), "enable": ib.get("enable"), "remark": ib.get("remark")}))
    elif action == "apply":
        # XUI_SPEC: JSON {"recreate": bool, "inbounds": [{tag, remark, port, uuid, email,
        # sid, privateKey, publicKey, target, serverNames, xver, acceptProxy}], "remove": [tags]}
        spec = json.loads(os.environ["XUI_SPEC"])
        existing = {ib.get("tag"): ib for ib in (p.call("GET", "panel/api/inbounds/list") or [])}
        for tag in spec.get("remove", []):
            if tag in existing:
                p.call("POST", "panel/api/inbounds/del/%d" % existing[tag]["id"])
                print("removed %s" % tag)
                existing.pop(tag)
        for want in spec["inbounds"]:
            tag = want["tag"]
            stream = {
                "network": "tcp",
                "tcpSettings": {"header": {"type": "none"}},
                "security": "reality",
                "realitySettings": {
                    "show": False, "xver": want["xver"], "target": want["target"],
                    "serverNames": want["serverNames"], "privateKey": want["privateKey"],
                    "minClientVer": "", "maxClientVer": "", "maxTimediff": 0,
                    "shortIds": [want["sid"]], "mldsa65Seed": "",
                    "settings": {"publicKey": want["publicKey"], "fingerprint": want["fingerprint"],
                                 "serverName": "", "spiderX": "/", "mldsa65Verify": ""},
                },
            }
            if want["acceptProxy"]:
                stream["sockopt"] = {"acceptProxyProtocol": True}
            client = {"id": want["uuid"], "email": want["email"], "flow": "xtls-rprx-vision", "limitIp": 0,
                      "totalGB": 0, "expiryTime": 0, "enable": True, "tgId": 0, "subId": want["subId"],
                      "comment": "escape (xray-3xui)", "reset": 0}
            settings = {"clients": [client], "decryption": "none", "encryption": "none", "fallbacks": []}
            sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic"], "metadataOnly": False, "routeOnly": False}
            body = {"remark": want["remark"], "enable": True, "listen": "", "port": want["port"],
                    "protocol": "vless", "tag": tag, "expiryTime": 0, "total": 0, "up": 0, "down": 0,
                    "settings": json.dumps(settings), "streamSettings": json.dumps(stream),
                    "sniffing": json.dumps(sniffing)}
            if tag in existing and spec.get("recreate"):
                p.call("POST", "panel/api/inbounds/del/%d" % existing[tag]["id"])
                existing.pop(tag)
                print("deleted %s (recreate)" % tag)
            if tag not in existing:
                p.call("POST", "panel/api/inbounds/add", body)
                print("created %s" % tag)
                continue
            cur = p.call("GET", "panel/api/inbounds/get/%d" % existing[tag]["id"])
            try:
                cs = json.loads(cur.get("streamSettings") or "{}")
                cset = json.loads(cur.get("settings") or "{}")
            except ValueError:
                cs, cset = {}, {}
            rs = cs.get("realitySettings") or {}
            same = (cur.get("port") == want["port"] and cur.get("protocol") == "vless" and cur.get("enable")
                    and cs.get("security") == "reality" and (rs.get("target") or rs.get("dest")) == want["target"]
                    and rs.get("serverNames") == want["serverNames"] and rs.get("privateKey") == want["privateKey"]
                    and want["sid"] in (rs.get("shortIds") or []) and int(rs.get("xver") or 0) == want["xver"]
                    and bool((cs.get("sockopt") or {}).get("acceptProxyProtocol")) == want["acceptProxy"])
            ids = [c.get("id") for c in cset.get("clients") or []]
            if same and want["uuid"] in ids:
                print("unchanged %s" % tag)
                continue
            # The panel keeps the stored clients on update; the client of this
            # installation is added through the clients API when it is missing.
            body["id"] = existing[tag]["id"]
            p.call("POST", "panel/api/inbounds/update/%d" % existing[tag]["id"], body)
            if want["uuid"] not in ids:
                p.call("POST", "panel/api/inbounds/del/%d" % existing[tag]["id"])
                body.pop("id", None)
                p.call("POST", "panel/api/inbounds/add", body)
                print("recreated %s (its client was missing)" % tag)
            else:
                print("updated %s" % tag)
    else:
        fail("unknown API action %s" % action)
finally:
    cleanup()
PYEOF
}

# --- panel setup ------------------------------------------------------------------------------

# xui_cli ARGS...: the x-ui binary (CLI) inside the container.
xui_cli() { docker exec "$(xui_cid)" /app/x-ui "$@"; }

# wait_panel [SECONDS]: the panel answers HTTP inside the container.
wait_panel() {
    local secs=${1:-90} i cid
    cid="$(xui_cid)"
    [[ -n "$cid" ]] || die "the $SERVICE container is not running"
    for ((i = 0; i < secs; i += 2)); do
        if docker exec "$cid" curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PANEL_PORT/" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    die "the panel does not answer on port $PANEL_PORT (waited ${secs}s); see: docker compose logs $SERVICE"
}

# panel_setup: port and secret path (x-ui CLI, then a restart when they changed),
# the login and the password (panel API from the stored or the default
# credentials; the CLI only as the last resort), the trusted proxy (nginx).
panel_setup() {
    local show restart=0 rc=0
    wait_panel
    show="$(xui_cli setting -show true 2>/dev/null || true)"
    if ! grep -qx "port: $PANEL_PORT" <<<"$show" || ! grep -qx "webBasePath: /$PANEL_PATH/" <<<"$show"; then
        xui_cli setting -port "$PANEL_PORT" -webBasePath "/$PANEL_PATH/" >/dev/null || die "x-ui setting (port, path) failed"
        restart=1
    fi
    if ((restart)); then
        compose restart "$SERVICE" >/dev/null 2>&1 || die "cannot restart the $SERVICE container"
        wait_panel
        info "panel port $PANEL_PORT and secret path set"
    fi
    xui_api login-check >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) info "panel login: $PANEL_USER (stored password works)" ;;
        2)
            XUI_NEW_PASS="$PANEL_PASSWORD" xui_api set-password >/dev/null
            info "panel login: $PANEL_USER, generated password set (the default admin/admin is gone)"
            ;;
        *)
            # The database has other credentials (changed in the panel, or a database
            # from elsewhere): reset them to the stored ones with the CLI.
            warn "the panel does not accept the stored credentials: resetting them with the x-ui CLI"
            xui_cli setting -username "$PANEL_USER" -password "$PANEL_PASSWORD" >/dev/null || die "x-ui setting (credentials) failed"
            xui_api login-check >/dev/null 2>&1 || die "the panel still rejects the stored credentials"
            ;;
    esac
    if [[ -n "$SHARED_SUBNET" ]]; then
        XUI_TRUST="$SHARED_SUBNET" xui_api trust >/dev/null 2>&1 || warn "could not add $SHARED_SUBNET to the trusted proxies of the panel (login IPs are then those of nginx)"
    fi
}

cmd_panel() {
    load_state
    need_docker
    panel_setup
}

# --- inbounds ------------------------------------------------------------------------------

new_uuid() {
    local h
    h="$(openssl rand -hex 16)"
    # RFC 4122 version 4, variant 10.
    printf '%s-%s-4%s-%x%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$(((16#${h:16:1} & 3) | 8))" "${h:17:3}" "${h:20:12}"
}
new_sid() { openssl rand -hex 4; }

# ensure_keys [--new]: UUIDs, short ids and REALITY key pairs of both inbounds,
# generated once (the panel API makes the X25519 keys) and kept in the state.
ensure_keys() {
    local new=${1:-} which priv pub
    for which in PLAIN WL; do
        [[ "$which" != WL ]] || wl_on || continue
        if [[ "$new" == --new || -z "$(state_get "${which}_UUID")" ]]; then state_set "${which}_UUID" "$(new_uuid)"; fi
        if [[ "$new" == --new || -z "$(state_get "${which}_SID")" ]]; then state_set "${which}_SID" "$(new_sid)"; fi
        if [[ "$new" == --new || -z "$(state_get "${which}_PRIVATE_KEY")" || -z "$(state_get "${which}_PUBLIC_KEY")" ]]; then
            read -r priv pub < <(xui_api x25519) || die "cannot generate the REALITY keys (panel API)"
            [[ "$priv" =~ ^[A-Za-z0-9_-]{40,}$ && "$pub" =~ ^[A-Za-z0-9_-]{40,}$ ]] || die "the panel returned unexpected REALITY keys"
            state_set "${which}_PRIVATE_KEY" "$priv"
            state_set "${which}_PUBLIC_KEY" "$pub"
        fi
    done
    load_state
}

# inbound_spec RECREATE: the JSON for `xui_api apply`.
inbound_spec() {
    local recreate=$1 names first
    names="$(wl_names | python3 -I -c 'import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    first="$(wl_first)"
    SPEC_RECREATE="$recreate" SPEC_WL_NAMES="$names" SPEC_WL_TARGET="$first:443" SPEC_PLAIN_DOMAIN="$PLAIN_DOMAIN" \
        SPEC_PLAIN_ON="$(plain_on && echo 1 || echo 0)" SPEC_WL_ON="$(wl_on && echo 1 || echo 0)" \
        python3 -I - "$WL_PORT" "$WL_UUID" "$WL_SID" "$WL_PRIVATE_KEY" "$WL_PUBLIC_KEY" \
        "$PLAIN_INTERNAL_PORT" "$PLAIN_UUID" "$PLAIN_SID" "$PLAIN_PRIVATE_KEY" "$PLAIN_PUBLIC_KEY" "$FINGERPRINT" <<'PYEOF'
import json, os, sys
wl_port, wl_uuid, wl_sid, wl_priv, wl_pub, pl_port, pl_uuid, pl_sid, pl_priv, pl_pub, fp = sys.argv[1:12]
names = json.loads(os.environ["SPEC_WL_NAMES"])
ibs = []
remove = []
if os.environ["SPEC_WL_ON"] == "1":
    ibs.append({
        "tag": "escape-wl", "remark": "escape wl (%s)" % names[0], "port": int(wl_port), "uuid": wl_uuid,
        "email": "escape-wl", "subId": wl_sid + wl_sid, "sid": wl_sid, "privateKey": wl_priv, "publicKey": wl_pub,
        "target": os.environ["SPEC_WL_TARGET"], "serverNames": names, "xver": 0, "acceptProxy": True, "fingerprint": fp,
    })
else:
    remove.append("escape-wl")
if os.environ["SPEC_PLAIN_ON"] == "1":
    # REALITY "steals" the TLS of this nginx (the decoy site of the plain name with its
    # certificate): probes see that site; xver 1 = PROXY protocol v1 towards nginx. The
    # connections come from the TLS front with the PROXY protocol (acceptProxy).
    name = os.environ["SPEC_PLAIN_DOMAIN"]
    ibs.append({
        "tag": "escape-plain", "remark": "escape plain (%s)" % name, "port": int(pl_port),
        "uuid": pl_uuid, "email": "escape-plain", "subId": pl_sid + pl_sid, "sid": pl_sid, "privateKey": pl_priv,
        "publicKey": pl_pub, "target": "nginx:443", "serverNames": [name], "xver": 1, "acceptProxy": True,
        "fingerprint": fp,
    })
else:
    remove.append("escape-plain")
print(json.dumps({"recreate": os.environ["SPEC_RECREATE"] == "1", "inbounds": ibs, "remove": remove}))
PYEOF
}

cmd_inbounds() {
    local recreate=0 newkeys="" a out
    for a in "$@"; do
        case "$a" in
            --recreate) recreate=1 ;;
            --new-keys)
                newkeys=--new
                recreate=1
                ;;
            *) die "usage: $0 inbounds [--recreate] [--new-keys]" ;;
        esac
    done
    load_state
    need_docker
    wait_panel
    ensure_keys $newkeys
    out="$(XUI_SPEC="$(inbound_spec "$recreate")" xui_api apply)" || die "the inbounds were not applied"
    while read -r a; do [[ -z "$a" ]] || info "inbound $a"; done <<<"$out"
}

# --- links ---------------------------------------------------------------------------------

# vless_link HOST UUID PORT SNI PUBKEY SID NAME
vless_link() {
    python3 -I - "$@" "$FINGERPRINT" <<'PYEOF'
import sys, urllib.parse
host, uuid, port, sni, pbk, sid, name, fp = sys.argv[1:9]
if ":" in host and not host.startswith("["):
    host = "[%s]" % host
q = urllib.parse.urlencode({"type": "tcp", "encryption": "none", "security": "reality", "flow": "xtls-rprx-vision",
                            "sni": sni, "fp": fp, "pbk": pbk, "sid": sid, "spx": "/"}, quote_via=urllib.parse.quote)
print("vless://%s@%s:%s?%s#%s" % (uuid, host, port, q, urllib.parse.quote(name, safe="")))
PYEOF
}

link_wl() {
    wl_on || return 0
    [[ -n "$WL_UUID" && -n "$WL_PUBLIC_KEY" ]] || die "the inbounds are not created yet (run: $0 inbounds)"
    vless_link "$PUBLIC_HOST" "$WL_UUID" "$HTTPS_PORT" "$(wl_first)" "$WL_PUBLIC_KEY" "$WL_SID" "$DOMAIN wl ($(wl_first))"
}

link_plain() {
    plain_on || return 0
    [[ -n "$PLAIN_UUID" && -n "$PLAIN_PUBLIC_KEY" ]] || die "the inbounds are not created yet (run: $0 inbounds)"
    # Host and SNI are the same separate name: the TLS front routes it by SNI.
    vless_link "$PLAIN_DOMAIN" "$PLAIN_UUID" "$HTTPS_PORT" "$PLAIN_DOMAIN" "$PLAIN_PUBLIC_KEY" "$PLAIN_SID" "$PLAIN_DOMAIN plain"
}

cmd_link() {
    load_state
    case "${1:-all}" in
        wl)
            wl_on || die "the wl inbound is off (stage 2; see: $0 wl on [SNI])"
            link_wl
            ;;
        plain)
            plain_on || die "the plain inbound is off (no PLAIN_DOMAIN; see: $0 plain selfsteal NAME)"
            link_plain
            ;;
        all)
            link_plain
            link_wl
            ;;
        *) die "usage: $0 link [wl|plain]" ;;
    esac
}

panel_url() {
    local suffix=""
    [[ "$HTTPS_PORT" == 443 ]] || suffix=":$HTTPS_PORT"
    printf 'https://%s%s/%s/' "$DOMAIN" "$suffix" "$PANEL_PATH"
}

cmd_show() {
    load_state
    printf 'panel    : %s\n' "$(panel_url)"
    printf 'login    : %s\n' "$PANEL_USER"
    printf 'password : %s\n' "$PANEL_PASSWORD"
    if plain_on; then printf 'plain    : %s\n' "$(link_plain)"; fi
    if wl_on; then printf 'wl       : %s\n' "$(link_wl)"; fi
    say "keep these private: the panel path and the password are the credentials of the panel"
}

# --- default route of the container --------------------------------------------------------

check_route() {
    local cid pid line line6 report=${1:-} bad=""
    cid="$(xui_cid)"
    [[ -n "$cid" ]] || die "the $SERVICE container is not running"
    command -v nsenter >/dev/null 2>&1 || {
        warn "nsenter not found: cannot verify the default route of the container"
        return 0
    }
    pid="$(docker inspect -f '{{.State.Pid}}' "$cid")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "the $SERVICE container is not running"
    line="$(nsenter -t "$pid" -n ip -4 route show default 2>/dev/null | head -n1 || true)"
    if [[ "$line" == "default via $NET_GATEWAY "* ]]; then
        info "default route of the container (IPv4): via $NET_GATEWAY (network $NET_NAME)"
    else
        bad+="IPv4 default route of the container is '${line:-none}', expected via $NET_GATEWAY. "
    fi
    if ((V6)); then
        line6="$(nsenter -t "$pid" -n ip -6 route show default 2>/dev/null | head -n1 || true)"
        if [[ "$line6" == "default via $NET_GATEWAY6 "* ]]; then
            info "default route of the container (IPv6): via $NET_GATEWAY6 (network $NET_NAME)"
        else
            bad+="IPv6 default route of the container is '${line6:-none}', expected via $NET_GATEWAY6. "
        fi
    fi
    [[ -n "$bad" ]] || return 0
    if [[ "$report" == --report ]]; then
        say "${bad}Traffic would bypass the outway"
        return 1
    fi
    compose stop "$SERVICE" >/dev/null 2>&1 || true
    die "${bad}It would bypass the outway. The container was stopped; update Docker/compose (gw_priority needs Docker 28+, compose 2.33+)"
}

# --- address families and the IPv6 subnet of the container network ------------------------------

ula_free() {
    python3 -I - "$1::/64" "$2" <<'PYEOF'
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1])
for u in sys.argv[2].split():
    try:
        o = ipaddress.ip_network(u, strict=False)
    except ValueError:
        continue
    if o.prefixlen >= 16 and n.overlaps(o):
        sys.exit(1)
PYEOF
}

pick_ula() {
    local used h prefix i
    used="$({
        ip -6 route show 2>/dev/null | awk '{print $1}'
        ip -6 -o addr show 2>/dev/null | awk '{print $4}'
        if docker info >/dev/null 2>&1; then
            # shellcheck disable=SC2046
            docker network inspect $(docker network ls -q 2>/dev/null) --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true
        fi
    } | tr ' ' '\n' | grep ':' || true)"
    for ((i = 0; i < 20; i++)); do
        h="$(openssl rand -hex 7)"
        prefix="fd${h:0:2}:$(printf '%x' "$((16#${h:2:4}))"):$(printf '%x' "$((16#${h:6:4}))"):$(printf '%x' "$((16#${h:10:4} % 65535 + 1))")"
        if ula_free "$prefix" "$used"; then
            printf '%s' "$prefix"
            return 0
        fi
    done
    return 1
}

# cmd_net_setup [--redetect]: OUTWAY_FAMILIES (4, 6 or 46) and the ULA IPv6 subnet of
# the container network (created once, dropped when the outway has no IPv6).
cmd_net_setup() {
    local redetect=0 out fams prefix
    [[ "${1:-}" != --redetect ]] || redetect=1
    out="$(state_get OUTWAY)"
    [[ -n "$out" ]] || die "OUTWAY is missing in $STATE_FILE"
    fams="$(state_get OUTWAY_FAMILIES)"
    if ((redetect)) || [[ -z "$fams" ]]; then
        fams="$(outway families "$out")" || die "cannot determine the address families of '$out'"
        state_set OUTWAY_FAMILIES "$fams"
    fi
    case "$fams" in
        *6*)
            if [[ -z "$(state_get NET_SUBNET6)" ]]; then
                prefix="$(pick_ula)" || die "no free ULA IPv6 subnet found"
                state_set NET_SUBNET6 "$prefix::/64"
                state_set NET_GATEWAY6 "$prefix::1"
                state_set XUI_IP6 "$prefix::2"
            fi
            ;;
        *)
            state_set NET_SUBNET6 ""
            state_set NET_GATEWAY6 ""
            state_set XUI_IP6 ""
            ;;
    esac
    info "outway $out carries $(case "$fams" in 46) echo 'IPv4 and IPv6' ;; 6) echo 'IPv6 only' ;; *) echo 'IPv4 only' ;; esac)"
}

# cmd_net_check: the existing network has another IPv6 setting than the state: remove
# the container and the network (compose creates them again on the next `up`).
cmd_net_check() {
    local have subnets br
    load_state
    need_docker
    have="$(docker network inspect "$NET_NAME" --format '{{.EnableIPv6}}' 2>/dev/null || true)"
    [[ -n "$have" ]] || return 0
    subnets="$(docker network inspect "$NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
    br="$(docker network inspect "$NET_NAME" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)"
    [[ "$br" != "<no value>" ]] || br=""
    # A bridge name set by an earlier version is no longer used: the network is recreated.
    if [[ -z "$br" ]]; then
        if ((V6)); then
            [[ "$have" == true && " $subnets" == *" $NET_SUBNET6 "* ]] && return 0
        else
            [[ "$have" != true ]] && return 0
        fi
    fi
    info "network $NET_NAME: the IPv6 setting or the bridge name option changed: recreating the $SERVICE container and the network"
    compose rm -sf "$SERVICE" >/dev/null 2>&1 || true
    docker network rm "$NET_NAME" >/dev/null || die "cannot remove the network $NET_NAME (still in use?)"
}

# --- commands ---------------------------------------------------------------------------------

start_xui() {
    compose up -d --wait "$@" "$SERVICE" >&2 || {
        compose logs --tail 30 "$SERVICE" >&2 || true
        die "the $SERVICE container did not become healthy"
    }
}

cmd_apply() {
    local recreate=()
    [[ "${1:-}" != --force-recreate ]] || recreate=(--force-recreate)
    load_state
    need_docker
    migrate_state
    cmd_net_setup
    load_state
    mkdir -p "$X_DIR/db"
    chmod 700 "$X_DIR/db"
    render_compose
    render_nginx
    cmd_pull
    register_compose
    outway up
    cmd_net_check
    start_xui "${recreate[@]}"
    check_route
    panel_setup
    cmd_inbounds
    nginx_apply_routes
    info "applied; panel: $(panel_url)"
}

cmd_restart() {
    load_state
    need_docker
    compose restart "$SERVICE" >&2
    check_route
}

cmd_status() {
    local cid st rc=0 out
    load_state
    need_docker
    cid="$(xui_cid)"
    if [[ -n "$cid" ]]; then
        st="$(docker inspect -f '{{.State.Status}} ({{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}})' "$cid")"
        printf 'container  : %s, %s\n' "$st" "$XUI_IMAGE"
    else
        printf 'container  : NOT RUNNING (%s)\n' "$XUI_IMAGE"
        rc=1
    fi
    printf 'panel      : %s (login %s; keep the path and the password private)\n' "$(panel_url)" "$PANEL_USER"
    if wl_on; then
        printf 'wl         : SNI %s -> %s:%s (through the TLS front on port %s)\n' "$WL_SNI" "$SERVICE" "$WL_PORT" "$HTTPS_PORT"
    else
        printf 'wl         : off (stage 2: %s wl on [SNI])\n' "$0"
    fi
    if plain_on; then
        printf 'plain      : %s %s -> %s:%s (through the TLS front on port %s)\n' "$PLAIN_MODE" "$PLAIN_DOMAIN" "$SERVICE" "$PLAIN_INTERNAL_PORT" "$HTTPS_PORT"
    else
        printf 'plain      : off\n'
    fi
    printf 'network    : %s, IPv4 %s%s\n' "$NET_NAME" "$NET_SUBNET" "$( ((V6)) && printf ', IPv6 %s' "$NET_SUBNET6")"
    local f
    local -a files=("locations.d/$LOC_ID.conf" "servers.d/$LOC_ID.conf")
    ! routes_any || files+=("stream.d/$LOC_ID.map")
    for f in "${files[@]}"; do
        if [[ -f "$(ngx_dir)/$f" ]]; then
            printf 'nginx      : %s installed\n' "$f"
        else
            printf 'nginx      : %s MISSING (run: %s apply)\n' "$f" "$0"
            rc=1
        fi
    done
    if [[ -n "$cid" ]]; then
        if out="$(xui_api list 2>&1)"; then
            local tag
            for tag in "$WL_TAG" "$PLAIN_TAG"; do
                if [[ "$tag" == "$WL_TAG" ]]; then wl_on || continue; else plain_on || continue; fi
                if grep -q "\"$tag\"" <<<"$out"; then
                    printf 'inbound    : %s present\n' "$tag"
                else
                    printf 'inbound    : %s MISSING (run: %s inbounds)\n' "$tag" "$0"
                    rc=1
                fi
            done
        else
            printf 'panel API  : %s\n' "${out##*error: }"
            rc=1
        fi
    fi
    outway status || rc=1
    [[ -z "$cid" ]] || check_route --report || rc=1
    return "$rc"
}

cmd_outway() {
    local new=${1:-} ans old
    load_state
    old=$OUTWAY
    if [[ -z "$new" ]]; then
        [[ -t 0 ]] || die "usage: $0 outway IFACE (current: $OUTWAY)"
        outway list
        while :; do
            read -r -p "Outgoing interface (number or name) [$OUTWAY]: " ans || die "no input"
            ans="${ans:-$OUTWAY}"
            if new="$(outway resolve "$ans" 2>/dev/null)" && outway check "$new" 2>/dev/null; then
                break
            fi
            say "'$ans' is not a usable interface (see the list below)"
            outway list
        done
    fi
    outway check "$new"
    state_set OUTWAY "$new"
    state_set OUTWAY_GW ""
    state_set OUTWAY_GW6 ""
    cmd_net_setup --redetect
    load_state
    render_compose
    outway up
    if docker info >/dev/null 2>&1 && [[ -n "$(xui_cid)" ]]; then
        cmd_net_check
        start_xui --force-recreate
        check_route
    fi
    info "outway changed: $old -> $new (3x-ui restarted)"
}

new_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24; }
new_path() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

cmd_rotate() {
    local what=${1:-}
    [[ "$what" == password || "$what" == path || "$what" == all ]] || die "usage: $0 rotate password|path|all"
    load_state
    need_docker
    if [[ "$what" == password || "$what" == all ]]; then
        local pw
        pw="$(new_password)"
        XUI_NEW_PASS="$pw" xui_api set-password >/dev/null || die "the panel did not accept the new password"
        state_set PANEL_PASSWORD "$pw"
        info "new panel password set"
    fi
    if [[ "$what" == path || "$what" == all ]]; then
        state_set PANEL_PATH "$(new_path)"
        load_state
        render_compose
        render_nginx
        panel_setup
        nginx_apply_routes
        info "new secret path set"
    fi
    load_state
    cmd_show
}

valid_name() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

cmd_plain() {
    local mode=${1:-} name=${2:-} tg=""
    [[ "$mode" == selfsteal || "$mode" == off ]] || die "usage: $0 plain selfsteal [NAME] | plain off"
    load_state
    need_docker
    if [[ "$mode" == selfsteal ]]; then
        name="${name:-$PLAIN_DOMAIN}"
        name="${name,,}"
        [[ -n "$name" ]] || die "NAME is required (a DNS name of this server, not the name of the site)"
        valid_name "$name" || die "bad name '$name'"
        [[ "$name" != "${DOMAIN,,}" ]] || die "the plain name must differ from the name of the site ($DOMAIN)"
        tg="$(sed -n 's/^TGPROXY_DOMAIN=//p' "$APP_DIR/data/telegram-web-proxy/state.env" 2>/dev/null | tail -n1 || true)"
        [[ -z "$tg" || "$name" != "${tg,,}" ]] || die "the plain name must differ from the name of the Telegram proxy ($tg)"
        [[ ",${WL_SNI,,}," != *",$name,"* ]] || die "the plain name must differ from the whitelist SNI"
        state_set PLAIN_DOMAIN "$name"
    fi
    state_set PLAIN_MODE "$mode"
    cmd_apply --force-recreate
    cmd_show
}

# cmd_wl on [NAME[,NAME...]] | off: stage 2, the "wl" inbound.
cmd_wl() {
    local mode=${1:-} list=${2:-} n
    [[ "$mode" == on || "$mode" == off ]] || die "usage: $0 wl on [NAME[,NAME...]] | wl off"
    load_state
    if [[ "$mode" == on ]]; then
        list="${list:-$WL_SNI}"
        list="${list,,}"
        for n in ${list//,/ }; do
            valid_name "$n" || die "bad name '$n'"
            [[ "$n" != "${DOMAIN,,}" && "$n" != "${PLAIN_DOMAIN,,}" ]] || die "'$n' is the name of the site or of the plain inbound: use a foreign name (e.g. ozon.ru)"
        done
        state_set WL_SNI "$(tr ' ' ',' <<<"${list//,/ }")"
        state_set WL_ENABLED 1
    else
        state_set WL_ENABLED 0
    fi
    load_state
    render_nginx
    need_docker
    cmd_inbounds
    nginx_apply_routes
    cmd_show
}

main() {
    local cmd=${1:-}
    shift || true
    case "$cmd" in
        show | credentials) cmd_show ;;
        link) cmd_link "$@" ;;
        status) cmd_status ;;
        apply) cmd_apply "$@" ;;
        panel) cmd_panel ;;
        inbounds) cmd_inbounds "$@" ;;
        plain) cmd_plain "$@" ;;
        wl) cmd_wl "$@" ;;
        wl-sni) cmd_wl on "$@" ;;
        outway) cmd_outway "$@" ;;
        rotate) cmd_rotate "$@" ;;
        render) cmd_render ;;
        pull) cmd_pull ;;
        restart) cmd_restart ;;
        migrate-state) migrate_state ;;
        net-setup) cmd_net_setup "$@" ;;
        net-check) cmd_net_check ;;
        state-get) state_get "${1:?usage: state-get KEY}" ;;
        state-set) state_set "${1:?usage: state-set KEY VALUE}" "${2-}" ;;
        check-route)
            load_state
            check_route
            ;;
        -h | --help | help | "")
            sed -n '2,/^set -E/p' "$SELF" | sed '$d; s/^# \{0,1\}//'
            ;;
        *) die "unknown command '$cmd' (see --help)" ;;
    esac
}
main "$@"
