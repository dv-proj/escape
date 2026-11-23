#!/usr/bin/env bash
# tgproxy-config.sh - manage the TELEMT Telegram web proxy of the
# telegram-web-proxy extension without fakeapp.sh and without the repository
# history: needs bash, docker with the compose plugin, iproute2 and the project
# directory (APP_DIR in the state file). No network except `docker pull` of the
# pinned image (the saved image tar is loaded when the registry is unreachable).
#
# State: data/telegram-web-proxy/state.env (written by the installer; mode 600).
#
#   link                 print the tg://webproxy link (from the container log, else computed)
#   status               container, outway, nginx location, default route check
#   outway [IFACE]       change the outgoing interface (prompts when IFACE is omitted)
#   rotate path|secret|all   new secret path and/or user secret, restart, new link
#   render               regenerate config.toml, docker-compose.yml, nginx-location.conf
#   apply                render + load/pull image + outway + nginx location + start telemt
#   restart              restart the telemt container
#   pull                 pull the pinned image (or `docker load` the saved tar) and save it
#   state-get KEY | state-set KEY VALUE   read / write one state.env value
#
# Environment: TGPROXY_STATE (state file), TGPROXY_DRY_RUN=1 (outway commands are
# only printed), TGPROXY_FORCE_PULL=1.
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

APP_DIR="" DOMAIN="" PUBLIC_IP="" BASE_PATH="" USER_SECRET="" USER_NAME="" SECRET_MODE="" CARRIER=""
LISTEN_PORT="" FAKEAPP_PORT="" SHARED_SUBNET="" COMPOSE_PROJECT="" NET_NAME="" NET_SUBNET="" NET_GATEWAY=""
TELEMT_IP="" TELEMT_IMAGE="" MEM_LIMIT="" SAVE_IMAGE="" OUTWAY=""
load_state() {
    [[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE (is the extension installed?)"
    local k v
    for k in APP_DIR DOMAIN PUBLIC_IP BASE_PATH USER_SECRET USER_NAME SECRET_MODE CARRIER LISTEN_PORT FAKEAPP_PORT \
        SHARED_SUBNET COMPOSE_PROJECT NET_NAME NET_SUBNET NET_GATEWAY TELEMT_IP TELEMT_IMAGE MEM_LIMIT SAVE_IMAGE OUTWAY; do
        v="$(state_get "$k")"
        printf -v "$k" '%s' "$v"
    done
    for k in APP_DIR DOMAIN PUBLIC_IP BASE_PATH USER_SECRET SHARED_SUBNET NET_SUBNET NET_GATEWAY TELEMT_IP TELEMT_IMAGE OUTWAY; do
        [[ -n "${!k}" ]] || die "$k is missing in $STATE_FILE"
    done
    USER_NAME="${USER_NAME:-tgweb}"
    SECRET_MODE="${SECRET_MODE:-dd}"
    CARRIER="${CARRIER:-https}"
    LISTEN_PORT="${LISTEN_PORT:-18080}"
    FAKEAPP_PORT="${FAKEAPP_PORT:-8080}"
    COMPOSE_PROJECT="${COMPOSE_PROJECT:-fakeapp}"
    NET_NAME="${NET_NAME:-${COMPOSE_PROJECT}-tgproxy}"
    MEM_LIMIT="${MEM_LIMIT:-128m}"
    SAVE_IMAGE="${SAVE_IMAGE:-1}"
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
        info "nginx is not running; the location is used at its next start"
        return 0
    }
    compose exec -T nginx nginx -t >&2 || return 1
    compose exec -T nginx nginx -s reload >&2
}

# nginx_put_file SRC: install SRC as data/nginx/locations.d/<id>.conf (rolled back on error).
nginx_put_file() {
    local src=$1 dir="$APP_DIR/data/nginx/locations.d" file backup=""
    file="$dir/$LOC_ID.conf"
    mkdir -p "$dir"
    if [[ -f "$file" ]]; then
        backup="$(mktemp "$file.bak.XXXXXX")"
        cp -p "$file" "$backup"
    fi
    install -m 644 "$src" "$file"
    if nginx_check_reload; then
        [[ -z "$backup" ]] || rm -f "$backup"
        return 0
    fi
    if [[ -n "$backup" ]]; then mv -f "$backup" "$file"; else rm -f "$file"; fi
    die "nginx rejected the location (rolled back)"
}

# register_compose: entry of this extension in data/extensions.compose.yml (same
# format as fakeapp.sh ext_register_compose), kept when already present.
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
        printf '# Generated by fakeapp.sh (ext_register_compose): do not edit.\ninclude:\n'
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

render_config() {
    local out="$TG_DIR/telemt/config.toml" tmp
    mkdir -p "$TG_DIR/telemt"
    chmod 755 "$TG_DIR/telemt"
    tmp="$(umask 077 && mktemp "$out.XXXXXX")"
    cat >"$tmp" <<EOF_TOML
# Generated by the telegram-web-proxy extension (fakeapp): do not edit, it is
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
enabled = false

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
host = "$DOMAIN"
base_path = "$BASE_PATH"
public_addr = "$PUBLIC_IP:443"

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
    local out="$TG_DIR/docker-compose.yml" tmp prio=""
    tmp="$(mktemp "$out.XXXXXX")"
    gw_priority_supported && prio="        gw_priority: 100"
    cat >"$tmp" <<EOF_YML
# Generated by the telegram-web-proxy extension (fakeapp): do not edit.
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
${prio:+$prio
}    volumes:
      - ./telemt:/etc/telemt:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=8m
    healthcheck:
      test: ["CMD", "/app/telemt", "healthcheck", "/etc/telemt/config.toml", "--mode", "liveness"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  tgproxy:
    name: $NET_NAME
    driver: bridge
    ipam:
      config:
        - subnet: $NET_SUBNET
          gateway: $NET_GATEWAY
EOF_YML
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

# The location is a variable proxy_pass (resolved at request time, like the base
# config): nginx keeps starting when the telemt container is stopped or removed.
render_location() {
    local out="$TG_DIR/nginx-location.conf" tmp p="$BASE_PATH" body
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
    tmp="$(mktemp "$out.XXXXXX")"
    cat >"$tmp" <<EOF_LOC
# telegram-web-proxy: ONLY the secret path goes to telemt; every other path is
# served by the decoy via "location /". Generated: do not edit.
location = /$p {
$body
}
location ^~ /$p/ {
$body
}
EOF_LOC
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

cmd_render() {
    load_state
    render_config
    render_compose
    render_location
    info "rendered: $TG_DIR/telemt/config.toml (600), docker-compose.yml, nginx-location.conf"
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
    printf 'tg://webproxy?server=%s%%2F%s&secret=%s' "$DOMAIN" "$BASE_PATH" "$b64"
}

cmd_link() {
    local cid link=""
    load_state
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        cid="$(telemt_cid)"
        if [[ -n "$cid" ]]; then
            link="$(docker logs "$cid" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'tg://webproxy?[^[:space:]]*' | grep -F "server=$DOMAIN%2F$BASE_PATH&" | tail -n1 || true)"
        fi
    fi
    if [[ -z "$link" ]]; then
        link="$(computed_link)"
    fi
    printf '%s\n' "$link"
}

# --- default route of the container --------------------------------------------------------

# check_route [--report]: the container's default route must go through its own
# network (the one the host routes through the outway); stops the container
# otherwise (--report: only say so, return 1).
check_route() {
    local cid pid line report=${1:-}
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
        info "default route of the container: via $NET_GATEWAY (network $NET_NAME)"
        return 0
    fi
    if [[ "$report" == --report ]]; then
        say "default route of the container is '${line:-none}', expected via $NET_GATEWAY: traffic would bypass the outway"
        return 1
    fi
    compose stop telemt >/dev/null 2>&1 || true
    die "the default route of the container is '${line:-none}', expected via $NET_GATEWAY ($NET_NAME): it would bypass the outway. The container was stopped; update Docker/compose (gw_priority needs Docker 28+, compose 2.33+) or rename the network so that it sorts first"
}

# --- commands ---------------------------------------------------------------------------------

start_telemt() {
    compose up -d --wait telemt >&2 || die "telemt did not become healthy; see: docker compose logs telemt"
}

cmd_apply() {
    load_state
    need_docker
    render_config
    render_compose
    render_location
    cmd_pull
    register_compose
    "$OUTWAY_SH" up
    start_telemt
    check_route
    nginx_put_file "$TG_DIR/nginx-location.conf"
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
    printf 'domain     : %s, secret path: %s (keep private)\n' "$DOMAIN" "$BASE_PATH"
    if [[ -f "$APP_DIR/data/nginx/locations.d/$LOC_ID.conf" ]]; then
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
    local new=${1:-} ans
    load_state
    if [[ -z "$new" ]]; then
        [[ -t 0 ]] || die "usage: $0 outway IFACE (current: $OUTWAY)"
        "$OUTWAY_SH" list
        read -r -p "Outgoing interface [$OUTWAY]: " ans || die "no input"
        new="${ans:-$OUTWAY}"
    fi
    "$OUTWAY_SH" check "$new"
    state_set OUTWAY "$new"
    state_set OUTWAY_GW ""
    "$OUTWAY_SH" up
    if docker info >/dev/null 2>&1 && [[ -n "$(telemt_cid)" ]]; then
        compose restart telemt >&2
    fi
    info "outway changed: $OUTWAY -> $new (telemt restarted)"
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
    nginx_put_file "$TG_DIR/nginx-location.conf"
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
        restart) cmd_restart ;;
        pull) cmd_pull ;;
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
