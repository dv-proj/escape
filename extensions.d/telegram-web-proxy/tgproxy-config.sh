#!/usr/bin/env bash
# tgproxy-config.sh - manage the TELEMT Telegram web proxy of the
# telegram-web-proxy extension without install.sh and without the repository
# history: needs bash, docker with the compose plugin, iproute2 and the project
# directory (APP_DIR in the state file). No network except `docker pull` of the
# pinned image (the saved image tar is loaded when the registry is unreachable).
#
# State: data/telegram-web-proxy/state.env (written by the installer; mode 600).
#
# The proxy name TGPROXY_DOMAIN (state; an older state without it means DOMAIN,
# the name of the site) decides how nginx routes: equal to DOMAIN, the secret path
# is a location in the server of the site (data/nginx/locations.d/); a separate
# name gets its own server blocks (data/nginx/servers.d/, ports 80 and 443) with
# the secret path to telemt and every other path to the decoy site, and its own
# certificate (registered in data/nginx/extra-certs.list, renewed by the timer).
#
#   link                 print the tg://webproxy link (from the container log, else computed)
#   status               container, outway, nginx route, certificate, default route check
#   outway [IFACE]       change the outgoing interface (prompts with a numbered list when
#                        IFACE is omitted: answer with the number or the name)
#   net-setup [--redetect]  detect which address families the outway carries (IPv4,
#                        IPv6, both) and keep the dedicated ULA IPv6 subnet of the
#                        telemt network in step (state: OUTWAY_FAMILIES, NET_SUBNET6)
#   net-check            recreate the telemt network when its IPv6 setting is stale
#   rotate path|secret|all   new secret path and/or user secret, restart, new link
#   render               regenerate config.toml, docker-compose.yml, nginx-location.conf,
#                        nginx-server.conf (the last one only with a separate proxy name)
#   apply                render + load/pull image + outway + nginx route + start telemt
#   cert                 obtain the Let's Encrypt certificate of the separate proxy name
#                        (certbot webroot of the project; renewed by `install.sh renew`)
#   restart              restart the telemt container
#   pull                 pull the pinned image (or `docker load` the saved tar) and save it
#   state-get KEY | state-set KEY VALUE   read / write one state.env value
#
# Environment: TGPROXY_STATE (state file), TGPROXY_DRY_RUN=1 (outway commands are
# only printed), TGPROXY_FORCE_PULL=1, TGPROXY_OUTWAY_FAMILIES=4|6|46 (override the
# detection of the families of the outway).
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
STATE_FILE="${TGPROXY_STATE:-@STATE_FILE@}"
if [[ "$STATE_FILE" == "@STATE_FILE@" ]]; then
    STATE_FILE="$HERE/../../data/telegram-web-proxy/state.env"
fi
STATE_FILE="$(readlink -m "$STATE_FILE")"
TG_DIR="$(dirname "$STATE_FILE")"
OUTWAY_SH="$HERE/tgproxy-outway.sh"
LOC_ID="telegram-web-proxy"
TELEMT_UID=65532

say() { printf '%s\n' "$*" >&2; }
info() { say "    $*"; }
warn() { say "warning: $*"; }
die() {
    say "error: $*"
    exit 1
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
    mkdir -p "$TG_DIR"
    tmp="$(umask 077 && mktemp "$STATE_FILE.XXXXXX")"
    { grep -v "^$key=" "$STATE_FILE" 2>/dev/null || true; } >"$tmp"
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

APP_DIR="" DOMAIN="" TGPROXY_DOMAIN="" PUBLIC_IP="" BASE_PATH="" USER_SECRET="" USER_NAME="" SECRET_MODE="" CARRIER=""
LISTEN_PORT="" FAKEAPP_PORT="" SHARED_SUBNET="" COMPOSE_PROJECT="" NET_NAME="" NET_SUBNET="" NET_GATEWAY=""
TELEMT_IP="" TELEMT_IMAGE="" MEM_LIMIT="" SAVE_IMAGE="" OUTWAY=""
NET_SUBNET6="" NET_GATEWAY6="" TELEMT_IP6="" OUTWAY_FAMILIES="" V6=0
load_state() {
    [[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE (is the extension installed?)"
    local k v
    for k in APP_DIR DOMAIN TGPROXY_DOMAIN PUBLIC_IP BASE_PATH USER_SECRET USER_NAME SECRET_MODE CARRIER LISTEN_PORT FAKEAPP_PORT \
        SHARED_SUBNET COMPOSE_PROJECT NET_NAME NET_SUBNET NET_GATEWAY TELEMT_IP TELEMT_IMAGE MEM_LIMIT SAVE_IMAGE OUTWAY \
        NET_SUBNET6 NET_GATEWAY6 TELEMT_IP6 OUTWAY_FAMILIES; do
        v="$(state_get "$k")"
        printf -v "$k" '%s' "$v"
    done
    for k in APP_DIR DOMAIN PUBLIC_IP BASE_PATH USER_SECRET SHARED_SUBNET NET_SUBNET NET_GATEWAY TELEMT_IP TELEMT_IMAGE OUTWAY; do
        [[ -n "${!k}" ]] || die "$k is missing in $STATE_FILE"
    done
    # An installation made before the separate proxy name serves the proxy on DOMAIN.
    TGPROXY_DOMAIN="${TGPROXY_DOMAIN:-$DOMAIN}"
    USER_NAME="${USER_NAME:-tgweb}"
    SECRET_MODE="${SECRET_MODE:-dd}"
    CARRIER="${CARRIER:-https}"
    LISTEN_PORT="${LISTEN_PORT:-18080}"
    FAKEAPP_PORT="${FAKEAPP_PORT:-8080}"
    COMPOSE_PROJECT="${COMPOSE_PROJECT:-escape}"
    NET_NAME="${NET_NAME:-${COMPOSE_PROJECT}-tgproxy}"
    MEM_LIMIT="${MEM_LIMIT:-128m}"
    SAVE_IMAGE="${SAVE_IMAGE:-1}"
    # An installation without the family settings is IPv4 only.
    OUTWAY_FAMILIES="${OUTWAY_FAMILIES:-4}"
    V6=0
    [[ -z "$NET_SUBNET6" || -z "$NET_GATEWAY6" || -z "$TELEMT_IP6" ]] || V6=1
}

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

telemt_cid() { compose ps -q telemt 2>/dev/null | head -n1 || true; }

nginx_running() { [[ -n "$(compose ps -q nginx 2>/dev/null | head -n1)" ]]; }

# nginx_check_reload: nginx -t, then reload; fails when the test fails.
nginx_check_reload() {
    nginx_running || {
        info "nginx is not running; the route is used at its next start"
        return 0
    }
    compose exec -T nginx nginx -t >&2 || return 1
    compose exec -T nginx nginx -s reload >&2
}

# separate_name: the proxy has its own name (server blocks and certificate).
separate_name() { [[ "$TGPROXY_DOMAIN" != "$DOMAIN" ]]; }

ngx_dir() { printf '%s/data/nginx' "$APP_DIR"; }

# le_have NAME: the Let's Encrypt certificate of NAME exists.
le_have() {
    local le="$APP_DIR/data/letsencrypt/live/$1"
    [[ -s "$le/fullchain.pem" && -s "$le/privkey.pem" ]]
}

# cert_paths NAME: "CERT KEY" inside the nginx container: Let's Encrypt when
# issued, else the temporary self-signed certificate of NAME (created when
# missing). Same rule as ext_cert_paths of install.sh.
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

# server_render_installed: render data/nginx/servers.d/<id>.conf from its .conf.in
# (same rule as install.sh render_ext_servers).
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

# servers_d_ready: nginx includes data/nginx/servers.d (base config of a current
# install.sh); fails with a hint otherwise.
servers_d_ready() {
    local base
    base="$(ngx_dir)/conf.d/default.conf"
    grep -qF '/etc/nginx/servers.d/' "$base" 2>/dev/null ||
        die "the nginx config ($base) does not include servers.d yet: update the project and run: sudo $APP_DIR/install.sh restart"
    mkdir -p "$(ngx_dir)/servers.d"
    if nginx_running && ! compose exec -T nginx test -d /etc/nginx/servers.d >/dev/null 2>&1; then
        info "nginx is recreated once to mount data/nginx/servers.d"
        compose up -d --wait nginx </dev/null >&2
    fi
}

# nginx_apply_routes: install the nginx route of the proxy and remove the other
# kind: the location (proxy name = DOMAIN) or the server blocks of the separate
# name (with its certificate registration). Everything changed is rolled back
# when nginx rejects the result.
nginx_apply_routes() {
    local loc srv_in srv bdir f
    loc="$(ngx_dir)/locations.d/$LOC_ID.conf"
    srv_in="$(ngx_dir)/servers.d/$LOC_ID.conf.in"
    srv="$(ngx_dir)/servers.d/$LOC_ID.conf"
    mkdir -p "$(ngx_dir)/locations.d"
    separate_name && servers_d_ready
    bdir="$(mktemp -d "$TG_DIR/.nginx-backup.XXXXXX")"
    for f in "$loc" "$srv_in" "$srv"; do
        [[ ! -f "$f" ]] || cp -p "$f" "$bdir/$(basename "$f")"
    done
    if separate_name; then
        rm -f "$loc"
        {
            printf '# cert-domain: %s\n' "$TGPROXY_DOMAIN"
            cat "$TG_DIR/nginx-server.conf"
        } >"$srv_in.tmp"
        chmod 644 "$srv_in.tmp"
        mv -f "$srv_in.tmp" "$srv_in"
        server_render_installed
        certs_list_set "$TGPROXY_DOMAIN"
    else
        rm -f "$srv_in" "$srv"
        install -m 644 "$TG_DIR/nginx-location.conf" "$loc"
        certs_list_set ""
    fi
    if nginx_check_reload; then
        rm -rf "$bdir"
        return 0
    fi
    rm -f "$loc" "$srv_in" "$srv"
    for f in "$loc" "$srv_in" "$srv"; do
        [[ ! -f "$bdir/$(basename "$f")" ]] || mv -f "$bdir/$(basename "$f")" "$f"
    done
    rm -rf "$bdir"
    die "nginx rejected the proxy route (rolled back)"
}

# register_compose: entry of this extension in data/extensions.compose.yml (same
# format as install.sh ext_register_compose), kept when already present.
register_compose() {
    local f="$APP_DIR/data/extensions.compose.yml" want="$TG_DIR/docker-compose.yml" line tmp i
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

# public_addr: "IPv4:443", "[IPv6]:443" (a SocketAddr, as telemt expects), or, as the
# last resort when no address is known, "HOST:443".
public_addr() {
    if [[ "$PUBLIC_IP" == *:* ]]; then printf '[%s]:443' "$PUBLIC_IP"; else printf '%s:443' "$PUBLIC_IP"; fi
}

# network_toml: the [network] table when the outway carries IPv6 (nothing for an
# IPv4-only outway: the telemt defaults apply). IPv6 only: prefer IPv6 so that telemt
# does not try the IPv4 path that the host blocks (fail-closed).
network_toml() {
    ((V6)) || return 0
    local prefer=4
    [[ "$OUTWAY_FAMILIES" == *4* ]] || prefer=6
    cat <<EOF_NET
# The outway carries IPv6$([[ "$prefer" == 6 ]] && printf ' only (the host blocks IPv4 of this container, fail-closed)'): telemt reaches
# the Telegram datacenters over IPv6.
[network]
ipv4 = true
ipv6 = true
prefer = $prefer
EOF_NET
}

render_config() {
    local out="$TG_DIR/telemt/config.toml" tmp net_toml
    net_toml="$(network_toml)"
    mkdir -p "$TG_DIR/telemt"
    chmod 755 "$TG_DIR/telemt"
    tmp="$(umask 077 && mktemp "$out.XXXXXX")"
    cat >"$tmp" <<EOF_TOML
# Generated by the telegram-web-proxy extension (escape): do not edit, it is
# rewritten by tgproxy-config.sh. Contains the user secret: keep mode 600.
# Keys: https://github.com/telemt/telemt/blob/main/docs/WEB/WEB_PROXY.en.md

[general]
# Direct connections to the Telegram datacenters (no Middle-End bootstrap).
use_middle_proxy = false
log_level = "normal"

# WEB mode needs at least one mode enabled; there is no native listener, so the
# classic mode only satisfies the validation (and needs no TLS-front fetch).
[general.modes]
classic = true
secure = false
tls = false

# Startup log prints the tg://webproxy link of this user.
[general.links]
show = ["$USER_NAME"]

# No control API (no extra listener, no config rewriting).
[server.api]
enabled = false${net_toml:+

$net_toml}

[access.users]
$USER_NAME = "$USER_SECRET"

# Plain HTTP/1.1 from nginx only, inside the compose network (never published).
[[server.listeners]]
ip = "0.0.0.0"
port = $LISTEN_PORT
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["$SHARED_SUBNET"]

[web]
enabled = true
carrier = "$CARRIER"
decoy_fasttrack_mode = "off"
http_connection_capacity_action = "drop"

[[web.vhosts]]
host = "$TGPROXY_DOMAIN"
base_path = "$BASE_PATH"
public_addr = "$(public_addr)"

# Everything that is not valid carrier traffic goes to the decoy site.
[web.vhosts.decoy]
mode = "http_upstream"
upstream = "http://fakeapp:$FAKEAPP_PORT"
resolve = "startup"

[[web.vhosts.profiles]]
user = "$USER_NAME"
secret_mode = "$SECRET_MODE"
max_sessions = 8
max_streams = 512
max_streams_per_session = 64
EOF_TOML
    chmod 600 "$tmp"
    chown "$TELEMT_UID:$TELEMT_UID" "$tmp" 2>/dev/null || {
        ((EUID == 0)) || warn "not root: $out stays owned by $(id -un); the container (uid $TELEMT_UID) may not read it"
    }
    mv -f "$tmp" "$out"
}

render_compose() {
    local out="$TG_DIR/docker-compose.yml" tmp prio="" ip6="" net6="" ipam6=""
    tmp="$(mktemp "$out.XXXXXX")"
    gw_priority_supported && prio="        gw_priority: 100"
    if ((V6)); then
        ip6="        ipv6_address: $TELEMT_IP6"
        net6="    enable_ipv6: true"
        ipam6="        - subnet: $NET_SUBNET6
          gateway: $NET_GATEWAY6"
    fi
    cat >"$tmp" <<EOF_YML
# Generated by the telegram-web-proxy extension (escape): do not edit.
# TELEMT in WEB mode (https://github.com/telemt/telemt). Nothing is published on
# the host. The container sits on two networks: the project network (nginx
# reaches telemt, telemt reaches the decoy app) and its own network $NET_NAME,
# which carries its default route; the host policy-routes that subnet through
# the chosen outway (tgproxy-outway.sh).
services:
  telemt:
    image: $TELEMT_IMAGE
    restart: unless-stopped
    read_only: true
    working_dir: /run/telemt
    command: ["/etc/telemt/config.toml"]
    mem_limit: $MEM_LIMIT
    pids_limit: 256
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    depends_on:
      fakeapp:
        condition: service_started
    expose:
      - "$LISTEN_PORT"
    networks:
      default: {}
      tgproxy:
        ipv4_address: $TELEMT_IP
${ip6:+$ip6
}${prio:+$prio
}    volumes:
      - ./telemt:/etc/telemt:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=8m
    healthcheck:
      test: ["CMD", "/app/telemt", "healthcheck", "/etc/telemt/config.toml", "--mode", "ready"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    logging:
      driver: json-file
      options:
        max-size: "\${LOG_MAX_SIZE:-5m}"
        max-file: "\${LOG_MAX_FILE:-3}"

networks:
  tgproxy:
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

# location_blocks: the locations of the secret path (exact and prefix). A variable
# proxy_pass (resolved at request time, like the base config): nginx keeps
# starting when the telemt container is stopped or removed.
location_blocks() {
    local p="$BASE_PATH" body
    body="    access_log off;
    client_max_body_size 4m;
    resolver 127.0.0.11 valid=10s ipv6=off;
    set \$tgproxy_upstream http://telemt:$LISTEN_PORT;
    proxy_pass \$tgproxy_upstream;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_connect_timeout 5s;
    proxy_send_timeout 65s;
    proxy_read_timeout 65s;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_next_upstream off;"
    cat <<EOF_LOC
location = /$p {
$body
}
location ^~ /$p/ {
$body
}
EOF_LOC
}

render_location() {
    local out="$TG_DIR/nginx-location.conf" tmp
    tmp="$(mktemp "$out.XXXXXX")"
    {
        printf '%s\n' "# telegram-web-proxy: ONLY the secret path goes to telemt; every other path is" \
            '# served by the decoy via "location /". Generated: do not edit.'
        location_blocks
    } >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

# render_server: nginx-server.conf, the server blocks of the separate proxy name
# (removed when the proxy uses DOMAIN). Port 80: ACME challenges and a redirect
# to HTTPS; port 443: the secret path to telemt, every other path to the decoy
# (the headers of "location /" of the base config). @SSL_CERT@ / @SSL_KEY@ are
# filled in when the file is installed (Let's Encrypt or self-signed).
render_server() {
    local out="$TG_DIR/nginx-server.conf" tmp d="$TGPROXY_DOMAIN"
    if ! separate_name; then
        rm -f "$out"
        return 0
    fi
    tmp="$(mktemp "$out.XXXXXX")"
    {
        cat <<EOF_SRV
# telegram-web-proxy: the proxy name $d. ONLY the secret path goes to telemt;
# every other path is served by the decoy site. Generated: do not edit.
server {
    listen 80;
    server_name $d;
    server_tokens off;
    access_log off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
    }

    location / {
        return 301 https://$d\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name $d;
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

EOF_SRV
        location_blocks | sed 's/^/    /; s/^    $//'
        cat <<EOF_SRV

    location / {
        resolver 127.0.0.11 valid=10s ipv6=off;
        set \$fakeapp_upstream http://fakeapp:$FAKEAPP_PORT;
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
EOF_SRV
    } >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

cmd_render() {
    load_state
    render_config
    render_compose
    render_location
    render_server
    info "rendered: $TG_DIR/telemt/config.toml (600), docker-compose.yml, nginx-location.conf$(separate_name && printf ', nginx-server.conf')"
}

# --- image --------------------------------------------------------------------------------

image_tar() { printf '%s/telemt-image.tar' "$TG_DIR"; }

cmd_pull() {
    local tar tmp
    load_state
    need_docker
    tar="$(image_tar)"
    if [[ "${TGPROXY_FORCE_PULL:-0}" != 1 ]] && docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1; then
        info "image present: $TELEMT_IMAGE"
    elif docker pull -q "$TELEMT_IMAGE" >/dev/null; then
        info "pulled $TELEMT_IMAGE"
    elif [[ -f "$tar" ]]; then
        warn "cannot pull $TELEMT_IMAGE; loading the saved image $tar"
        docker load -i "$tar" >/dev/null
        docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1 || die "the saved image does not contain $TELEMT_IMAGE"
        return 0
    else
        die "cannot pull $TELEMT_IMAGE and there is no saved image ($tar)"
    fi
    if [[ "$SAVE_IMAGE" == 1 ]]; then
        tmp="$(mktemp "$tar.XXXXXX")"
        if docker save "$TELEMT_IMAGE" -o "$tmp"; then
            chmod 644 "$tmp"
            mv -f "$tmp" "$tar"
            info "image saved for offline reinstall: $tar"
        else
            rm -f "$tmp"
            warn "docker save failed; continuing without the offline copy"
        fi
    fi
}

# --- link -----------------------------------------------------------------------------------

# computed_link: documented WEB link format: server=HOST%2FBASE, secret =
# base64url (no padding) of 0x70 || [0xdd] || the 16 secret bytes.
computed_link() {
    local hex b64
    hex="70"
    [[ "$SECRET_MODE" != dd ]] || hex+="dd"
    hex+="$USER_SECRET"
    # shellcheck disable=SC2059,SC2001
    b64="$(printf "$(sed 's/../\\x&/g' <<<"$hex")" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    printf 'tg://webproxy?server=%s%%2F%s&secret=%s' "$TGPROXY_DOMAIN" "$BASE_PATH" "$b64"
}

cmd_link() {
    local cid link=""
    load_state
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        cid="$(telemt_cid)"
        if [[ -n "$cid" ]]; then
            link="$(docker logs "$cid" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'tg://webproxy?[^[:space:]]*' | grep -F "server=$TGPROXY_DOMAIN%2F$BASE_PATH&" | tail -n1 || true)"
        fi
    fi
    if [[ -z "$link" ]]; then
        link="$(computed_link)"
    fi
    printf '%s\n' "$link"
}

# --- default route of the container --------------------------------------------------------

# check_route [--report]: the container's default routes (IPv4, and IPv6 when the
# network is dual-stack) must go through its own network (the one the host routes
# through the outway); stops the container otherwise (--report: only say so,
# return 1).
check_route() {
    local cid pid line line6 report=${1:-} bad=""
    cid="$(telemt_cid)"
    [[ -n "$cid" ]] || die "the telemt container is not running"
    command -v nsenter >/dev/null 2>&1 || {
        warn "nsenter not found: cannot verify the default route of the container"
        return 0
    }
    pid="$(docker inspect -f '{{.State.Pid}}' "$cid")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "the telemt container is not running"
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
    compose stop telemt >/dev/null 2>&1 || true
    die "${bad}It would bypass the outway. The container was stopped; update Docker/compose (gw_priority needs Docker 28+, compose 2.33+) or rename the network so that it sorts first"
}

# --- address families and the IPv6 subnet of the telemt network -----------------------------------

# ula_free PREFIX USED: PREFIX::/64 overlaps none of the networks listed in USED.
ula_free() {
    if command -v python3 >/dev/null 2>&1; then
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
    else
        ! grep -qiF "$1" <<<"$2"
    fi
}

# pick_ula: a free random ULA /64 (fdXX:XXXX:XXXX:SSSS::/64); prints the 4-group prefix.
# Groups are printed without leading zeros, exactly like the kernel prints them, so
# the addresses can be compared with `ip -6 route` output.
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

# cmd_net_setup [--redetect]: OUTWAY_FAMILIES (4, 6 or 46) and the IPv6 subnet of the
# telemt network. Detection runs on --redetect, and when the state has no value yet
# (an installation made before IPv6 support keeps IPv4 only). The ULA subnet is created
# once and kept in the state; it is dropped when the outway has no IPv6.
cmd_net_setup() {
    local redetect=0 out fams prefix
    [[ "${1:-}" != --redetect ]] || redetect=1
    out="$(state_get OUTWAY)"
    [[ -n "$out" ]] || die "OUTWAY is missing in $STATE_FILE"
    fams="$(state_get OUTWAY_FAMILIES)"
    if ((redetect)) || [[ -z "$fams" ]]; then
        if ((!redetect)) && [[ -n "$(state_get NET_SUBNET)" ]]; then
            fams=4
        else
            fams="$("$OUTWAY_SH" families "$out")" || die "cannot determine the address families of '$out'"
        fi
        state_set OUTWAY_FAMILIES "$fams"
    fi
    case "$fams" in
        *6*)
            if [[ -z "$(state_get NET_SUBNET6)" ]]; then
                prefix="$(pick_ula)" || die "no free ULA IPv6 subnet found"
                state_set NET_SUBNET6 "$prefix::/64"
                state_set NET_GATEWAY6 "$prefix::1"
                state_set TELEMT_IP6 "$prefix::2"
            fi
            ;;
        *)
            state_set NET_SUBNET6 ""
            state_set NET_GATEWAY6 ""
            state_set TELEMT_IP6 ""
            ;;
    esac
    info "outway $out carries $(case "$fams" in 46) echo 'IPv4 and IPv6' ;; 6) echo 'IPv6 only' ;; *) echo 'IPv4 only' ;; esac)"
}

# cmd_net_check: when the existing docker network of telemt has another IPv6 setting
# than the state (the outway changed between IPv4 and IPv6), remove the container and
# the network: compose creates them again on the next `up`.
cmd_net_check() {
    local have subnets
    load_state
    need_docker
    have="$(docker network inspect "$NET_NAME" --format '{{.EnableIPv6}}' 2>/dev/null || true)"
    [[ -n "$have" ]] || return 0
    subnets="$(docker network inspect "$NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
    if ((V6)); then
        [[ "$have" == true && " $subnets" == *" $NET_SUBNET6 "* ]] && return 0
    else
        [[ "$have" != true ]] && return 0
    fi
    info "network $NET_NAME: the IPv6 setting changed: recreating the telemt container and the network"
    compose rm -sf telemt >/dev/null 2>&1 || true
    docker network rm "$NET_NAME" >/dev/null || die "cannot remove the network $NET_NAME (still in use?)"
}

# --- commands ---------------------------------------------------------------------------------

start_telemt() {
    compose up -d --wait telemt >&2 || die "telemt did not become healthy; see: docker compose logs telemt"
}

cmd_apply() {
    load_state
    need_docker
    cmd_net_setup
    load_state
    render_config
    render_compose
    render_location
    render_server
    cmd_pull
    register_compose
    "$OUTWAY_SH" up
    cmd_net_check
    start_telemt
    check_route
    nginx_apply_routes
    if separate_name && ! le_have "$TGPROXY_DOMAIN"; then
        warn "no Let's Encrypt certificate for $TGPROXY_DOMAIN yet (Telegram rejects the self-signed one): run: $0 cert"
    fi
    info "applied; link: $(cmd_link)"
}

cmd_restart() {
    load_state
    need_docker
    compose restart telemt >&2
    check_route
}

cmd_status() {
    local cid st rc=0
    load_state
    need_docker
    cid="$(telemt_cid)"
    if [[ -n "$cid" ]]; then
        st="$(docker inspect -f '{{.State.Status}} ({{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}})' "$cid")"
        printf 'container  : %s, %s\n' "$st" "$TELEMT_IMAGE"
    else
        printf 'container  : NOT RUNNING (%s)\n' "$TELEMT_IMAGE"
        rc=1
    fi
    printf 'proxy name : %s%s, secret path: %s (keep private)\n' "$TGPROXY_DOMAIN" "$(separate_name && printf ' (own server blocks; site: %s)' "$DOMAIN")" "$BASE_PATH"
    printf 'network    : %s, IPv4 %s%s; telemt public_addr %s\n' "$NET_NAME" "$NET_SUBNET" "$( ((V6)) && printf ', IPv6 %s' "$NET_SUBNET6")" "$(public_addr)"
    if separate_name; then
        if [[ -f "$(ngx_dir)/servers.d/$LOC_ID.conf" ]]; then
            printf 'nginx      : server blocks installed (data/nginx/servers.d/%s.conf)\n' "$LOC_ID"
        else
            printf 'nginx      : server blocks MISSING (run: %s apply)\n' "$0"
            rc=1
        fi
        if le_have "$TGPROXY_DOMAIN"; then
            printf 'certificate: Let'"'"'s Encrypt, expires %s\n' "$(openssl x509 -in "$APP_DIR/data/letsencrypt/live/$TGPROXY_DOMAIN/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
        else
            printf 'certificate: temporary self-signed, Telegram rejects it (run: %s cert)\n' "$0"
            rc=1
        fi
    elif [[ -f "$(ngx_dir)/locations.d/$LOC_ID.conf" ]]; then
        printf 'nginx      : location installed\n'
    else
        printf 'nginx      : location MISSING (run: %s apply)\n' "$0"
        rc=1
    fi
    "$OUTWAY_SH" status || rc=1
    [[ -z "$cid" ]] || check_route --report || rc=1
    return "$rc"
}

cmd_outway() {
    local new=${1:-} ans old
    load_state
    old=$OUTWAY
    if [[ -z "$new" ]]; then
        [[ -t 0 ]] || die "usage: $0 outway IFACE (current: $OUTWAY)"
        "$OUTWAY_SH" list
        while :; do
            read -r -p "Outgoing interface (number or name) [$OUTWAY]: " ans || die "no input"
            ans="${ans:-$OUTWAY}"
            if new="$("$OUTWAY_SH" resolve "$ans" 2>/dev/null)" && "$OUTWAY_SH" check "$new" 2>/dev/null; then
                break
            fi
            say "'$ans' is not a usable interface (see the list below)"
            "$OUTWAY_SH" list
        done
    fi
    "$OUTWAY_SH" check "$new"
    state_set OUTWAY "$new"
    state_set OUTWAY_GW ""
    state_set OUTWAY_GW6 ""
    cmd_net_setup --redetect
    load_state
    # The families may have changed: the config (IPv6 keys) and the compose file follow.
    render_config
    render_compose
    "$OUTWAY_SH" up
    if docker info >/dev/null 2>&1 && [[ -n "$(telemt_cid)" ]]; then
        cmd_net_check
        compose up -d --force-recreate --wait telemt >&2
        check_route
    fi
    info "outway changed: $old -> $new (telemt restarted)"
}

# cmd_cert: Let's Encrypt certificate of the separate proxy name via the certbot
# service of the project (webroot; port 80 answers the challenge), then the server
# blocks are rendered again and nginx reloaded. LE_EMAIL / LE_STAGING from .env.
cmd_cert() {
    local email staging
    load_state
    need_docker
    separate_name || {
        info "the proxy uses the name of the site ($DOMAIN): its certificate is managed by install.sh"
        return 0
    }
    email="$(sed -n 's/^LE_EMAIL=//p' "$APP_DIR/.env" 2>/dev/null | tail -n1 | tr -d "'\"")"
    staging="$(sed -n 's/^LE_STAGING=//p' "$APP_DIR/.env" 2>/dev/null | tail -n1 | tr -d "'\"")"
    local -a args=(certonly --webroot -w /var/www/acme -d "$TGPROXY_DOMAIN" --cert-name "$TGPROXY_DOMAIN"
        --non-interactive --agree-tos --keep-until-expiring)
    if [[ -n "$email" ]]; then args+=(--email "$email" --no-eff-email); else args+=(--register-unsafely-without-email); fi
    [[ "$staging" != 1 ]] || args+=(--staging)
    certs_list_set "$TGPROXY_DOMAIN"
    if ! compose run --rm -T certbot "${args[@]}" >&2; then
        die "could not obtain a certificate for $TGPROXY_DOMAIN: check its DNS record (A/AAAA to this server), that port 80 is reachable and the Let's Encrypt rate limits; the self-signed certificate stays in use"
    fi
    server_render_installed
    nginx_check_reload || die "nginx did not reload"
    info "certificate of $TGPROXY_DOMAIN issued; nginx reloaded"
}

new_path() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20; }
new_secret() { openssl rand -hex 16; }

cmd_rotate() {
    local what=${1:-}
    [[ "$what" == path || "$what" == secret || "$what" == all ]] || die "usage: $0 rotate path|secret|all"
    load_state
    need_docker
    if [[ "$what" == path || "$what" == all ]]; then state_set BASE_PATH "$(new_path)"; fi
    if [[ "$what" == secret || "$what" == all ]]; then state_set USER_SECRET "$(new_secret)"; fi
    load_state
    render_config
    render_location
    render_server
    nginx_apply_routes
    compose restart telemt >&2
    check_route
    info "rotated ($what): the old link no longer works"
    printf '%s\n' "$(cmd_link)"
}

main() {
    local cmd=${1:-}
    shift || true
    case "$cmd" in
        link) cmd_link ;;
        status) cmd_status ;;
        outway) cmd_outway "$@" ;;
        rotate) cmd_rotate "$@" ;;
        render) cmd_render ;;
        apply) cmd_apply ;;
        cert) cmd_cert ;;
        restart) cmd_restart ;;
        pull) cmd_pull ;;
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
