# Extension: Telegram WEB proxy on top of TELEMT (https://github.com/telemt/telemt).
# Telegram Desktop 7.1+ connects with a tg://webproxy link to https://DOMAIN/<secret path>/;
# nginx forwards only that path to the telemt container, every other path stays on
# the decoy site. The container's outgoing traffic leaves through a chosen host
# interface ("outway", policy routing). See README.md, section "Telegram web proxy".
#
# Menu entry -> install / update / remove / show link / change outway / rotate.
# Without a terminal choose the action by environment (read by this file only):
#   TGPROXY_ACTION=install|update|remove|link|outway|rotate|status
#   TGPROXY_OUTWAY=<interface>|auto   TGPROXY_ROTATE=path|secret|all   TGPROXY_PURGE=1
#   TGPROXY_TELEMT_VERSION=<image tag>  TGPROXY_PUBLIC_IP  TGPROXY_SUBNET  TGPROXY_SAVE_IMAGE=0|1
#   TGPROXY_SCRIPTS_DIR  TGPROXY_MEM_LIMIT  TGPROXY_DRY_RUN=1 (outway commands only printed)
# e.g.: TGPROXY_ACTION=link TGPROXY_OUTWAY=eth0 sudo -E ./fakeapp.sh extensions --with telegram-web-proxy
#
# The heavy lifting is done by the standalone scripts in extensions.d/telegram-web-proxy/
# (tgproxy-config.sh, tgproxy-outway.sh, tgproxy-remove.sh), which are also installed on
# the host, so the proxy can be managed when this repository is not reachable.

register_extension telegram-web-proxy "Telegram web proxy (TELEMT, tg://webproxy link, selectable outgoing interface)" ext_telegram_web_proxy_install

TGP_ID="telegram-web-proxy"
TGP_TELEMT_VERSION_DEFAULT="3.5.17"
TGP_SRC="$APP_DIR/extensions.d/telegram-web-proxy"
TGP_DIR="$DATA_DIR/telegram-web-proxy"
TGP_STATE="$TGP_DIR/state.env"
TGP_MARKER="$TGP_DIR/installed"
TGP_SCRIPTS=(tgproxy-config.sh tgproxy-outway.sh tgproxy-remove.sh)
TGP_SCRIPTS_DIR=""

# --- small helpers -------------------------------------------------------------------------

_tgp_installed() { [[ -f "$TGP_MARKER" && -f "$TGP_STATE" ]]; }
_tgp_state_get() { [[ -f "$TGP_STATE" ]] && sed -n "s/^$1=//p" "$TGP_STATE" | tail -n1 || true; }
# _tgp_state_set KEY VALUE: via the standalone script (one implementation).
_tgp_state_set() { TGPROXY_STATE="$TGP_STATE" bash "$TGP_SRC/tgproxy-config.sh" state-set "$1" "$2"; }
# _tgp_cfg ARGS...: tgproxy-config.sh (installed copy when present, else the repository's).
_tgp_cfg() { TGPROXY_STATE="$TGP_STATE" bash "${TGP_SCRIPTS_DIR:-$TGP_SRC}/tgproxy-config.sh" "$@"; }
_tgp_outway() { TGPROXY_STATE="$TGP_STATE" bash "${TGP_SCRIPTS_DIR:-$TGP_SRC}/tgproxy-outway.sh" "$@"; }

_tgp_interactive() { [[ -t 0 && "${ASSUME_YES:-0}" != 1 ]]; }

# _tgp_scripts_dir: where the standalone scripts are installed. /opt/fakeapp-tgproxy,
# or ~/telegram-web-proxy of the user who ran sudo; TGPROXY_SCRIPTS_DIR overrides.
_tgp_scripts_dir() {
    local home
    if [[ -n "${TGPROXY_SCRIPTS_DIR:-}" ]]; then
        printf '%s' "$TGPROXY_SCRIPTS_DIR"
    elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] && home="$(getent passwd "$SUDO_USER" | cut -d: -f6)" && [[ -d "$home" ]]; then
        printf '%s/telegram-web-proxy' "$home"
    else
        printf '/opt/fakeapp-tgproxy'
    fi
}

# _tgp_install_scripts: copy the standalone scripts to the host (root-owned, 755),
# with the state file path baked in.
_tgp_install_scripts() {
    local dir="$1" s
    [[ "$dir" != *[[:space:]]* ]] || die "scripts directory with spaces is not supported: '$dir'"
    mkdir -p "$dir"
    chown root:root "$dir" 2>/dev/null || true
    chmod 755 "$dir"
    for s in "${TGP_SCRIPTS[@]}"; do
        sed "s|:-@STATE_FILE@}|:-$TGP_STATE}|" "$TGP_SRC/$s" >"$dir/$s.tmp"
        chmod 755 "$dir/$s.tmp"
        chown root:root "$dir/$s.tmp" 2>/dev/null || true
        mv -f "$dir/$s.tmp" "$dir/$s"
    done
    TGP_SCRIPTS_DIR="$dir"
    ok "standalone scripts installed in $dir (tgproxy-config.sh, tgproxy-outway.sh, tgproxy-remove.sh)"
}

_tgp_preflight() {
    local c
    [[ -f "$APP_DIR/.env" ]] || die "$APP_DIR/.env not found; run: sudo ./fakeapp.sh install"
    require_docker
    for c in ip openssl base64 sed python3 getent; do
        command -v "$c" >/dev/null 2>&1 || die "'$c' is required (apt install iproute2 openssl python3 coreutils libc-bin)"
    done
    site_domain >/dev/null
    [[ "$APP_DIR" != *[[:space:]]* ]] || die "the project path must not contain spaces: '$APP_DIR'"
    mkdir -p "$TGP_DIR"
    chmod 700 "$TGP_DIR"
}

# _tgp_pick_outway [CURRENT]: validated interface name in TGP_OUTWAY_CHOICE.
_tgp_pick_outway() {
    local current="${1:-}" want="${TGPROXY_OUTWAY:-}" ans
    TGP_OUTWAY_CHOICE=""
    if [[ "$want" == auto ]]; then
        want="$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
        [[ -n "$want" ]] || die "TGPROXY_OUTWAY=auto: the host has no default route; name the interface"
        info "outway (auto, interface of the default route): $want"
    fi
    if [[ -z "$want" ]]; then
        if ! _tgp_interactive; then
            [[ -z "$current" ]] || {
                TGP_OUTWAY_CHOICE="$current"
                return 0
            }
            _tgp_outway list || true
            die "choose the outgoing interface: TGPROXY_OUTWAY=<interface> (or auto = the interface of the default route)"
        fi
        printf '\nThe outgoing interface carries only the telemt container traffic to Telegram:\n' >&2
        _tgp_outway list || true
        while :; do
            read -r -p "Outgoing interface${current:+ [$current]}: " ans || die "no input"
            ans="${ans:-$current}"
            if [[ -n "$ans" ]] && _tgp_outway check "$ans" 2>/dev/null; then
                want="$ans"
                break
            fi
            warn "'$ans' is not a usable interface (see the list above)"
        done
    fi
    _tgp_outway check "$want" || die "invalid outway '$want'"
    TGP_OUTWAY_CHOICE="$want"
}

# _tgp_subnet WANT: "SUBNET GATEWAY TELEMT_IP" of a free private /24 (or WANT when
# it does not overlap any host route, address or docker network).
_tgp_subnet() {
    local want="${1:-}" used
    used="$({
        ip -4 -o route show 2>/dev/null | awk '{print $1}'
        ip -4 -o addr show 2>/dev/null | awk '{print $4}'
        # shellcheck disable=SC2046
        docker network inspect $(docker network ls -q 2>/dev/null) --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null || true
    } | grep -E '^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$' || true)"
    python3 -I - "$want" "$used" <<'PY'
import ipaddress, sys
want, used = sys.argv[1], sys.argv[2].split()
nets = []
for u in used:
    try:
        nets.append(ipaddress.ip_network(u, strict=False))
    except ValueError:
        pass
def free(n):
    return not any(n.overlaps(o) for o in nets)
if want:
    n = ipaddress.ip_network(want, strict=True)
    if n.version != 4 or not n.is_private or n.prefixlen > 28 or n.prefixlen < 16:
        sys.exit("TGPROXY_SUBNET must be a private IPv4 network between /16 and /28")
    if not free(n):
        sys.exit("TGPROXY_SUBNET %s overlaps a host route, address or docker network" % n)
else:
    for i in range(77, 200):
        n = ipaddress.ip_network("172.29.%d.0/24" % i)
        if free(n):
            break
    else:
        sys.exit("no free 172.29.x.0/24 subnet; set TGPROXY_SUBNET")
h = list(n.hosts())
print(n, h[0], h[1])
PY
}

_tgp_public_ip() {
    local domain=$1 ip="${TGPROXY_PUBLIC_IP:-}"
    [[ -n "$ip" ]] || ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot resolve an IPv4 address for $domain; set TGPROXY_PUBLIC_IP"
    printf '%s' "$ip"
}

# _tgp_shared_subnet PROJECT: IPv4 subnet of the project's default network (nginx/fakeapp).
_tgp_shared_subnet() {
    local nid sn
    nid="$(docker network ls -q --filter "label=com.docker.compose.project=$1" --filter "label=com.docker.compose.network=default" | head -n1)"
    [[ -n "$nid" ]] || die "the project network of the stack does not exist: start the stack first (./fakeapp.sh start)"
    sn="$(docker network inspect "$nid" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}/[0-9]+$' | head -n1 || true)"
    [[ -n "$sn" ]] || die "cannot determine the IPv4 subnet of the project network"
    printf '%s' "$sn"
}

_tgp_rand_path() { rand_str 20 'A-Za-z0-9'; }
_tgp_rand_secret() { rand_str 32 '0-9a-f'; }

_tgp_confirm() {
    local q=$1 ans
    if [[ "${ASSUME_YES:-0}" == 1 ]]; then return 0; fi
    if [[ ! -t 0 ]]; then return 0; fi
    read -r -p "$q [y/N] " ans || return 1
    [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

_tgp_print_result() {
    local link outway
    link="$(_tgp_cfg link)"
    outway="$(_tgp_state_get OUTWAY)"
    printf '\n' >&2
    ok "Telegram web proxy is ready"
    printf '    Link (open it in Telegram Desktop 7.1 or newer):\n\n        %s\n\n' "$link" >&2
    info "Outgoing interface (outway): $outway; status: $TGP_SCRIPTS_DIR/tgproxy-outway.sh status"
    warn "the secret path is part of the credential: keep the link private; rotating the path or the secret invalidates old links"
    info "Telegram Desktop 7.1+ is required (the WEB proxy type); other clients cannot use this link"
    info "Manage without the repository: $TGP_SCRIPTS_DIR/tgproxy-config.sh (link, status, outway, rotate) and tgproxy-remove.sh"
    [[ "$(nginx_https_port)" == 443 ]] || warn "NGINX_HTTPS_PORT is $(nginx_https_port): Telegram Desktop requires port 443 for web proxies"
}

# --- actions -------------------------------------------------------------------------------------

_tgp_write_state() {
    local domain project
    domain="$(site_domain)"
    project="$(sed -n 's/^name:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "$APP_DIR/docker-compose.yml" | head -n1)"
    project="${project:-fakeapp}"
    local net gw tip
    # Existing values (a reinstall after "remove" without --purge) are kept: same link.
    [[ -n "$(_tgp_state_get BASE_PATH)" ]] || _tgp_state_set BASE_PATH "$(_tgp_rand_path)"
    [[ -n "$(_tgp_state_get USER_SECRET)" ]] || _tgp_state_set USER_SECRET "$(_tgp_rand_secret)"
    if [[ -z "$(_tgp_state_get NET_SUBNET)" ]]; then
        read -r net gw tip < <(_tgp_subnet "${TGPROXY_SUBNET:-}") || die "no usable subnet for the telemt network"
        [[ -n "$tip" ]] || die "no usable subnet for the telemt network"
        _tgp_state_set NET_SUBNET "$net"
        _tgp_state_set NET_GATEWAY "$gw"
        _tgp_state_set TELEMT_IP "$tip"
    fi
    _tgp_state_set TGPROXY_STATE_VERSION 1
    _tgp_state_set APP_DIR "$APP_DIR"
    _tgp_state_set DOMAIN "$domain"
    _tgp_state_set PUBLIC_IP "$(_tgp_public_ip "$domain")"
    _tgp_state_set COMPOSE_PROJECT "$project"
    _tgp_state_set NET_NAME "$project-tgproxy"
    _tgp_state_set SHARED_SUBNET "$(_tgp_shared_subnet "$project")"
    _tgp_state_set FAKEAPP_PORT "$(fakeapp_port)"
    _tgp_state_set USER_NAME tgweb
    _tgp_state_set SECRET_MODE dd
    _tgp_state_set CARRIER https
    _tgp_state_set LISTEN_PORT 18080
    [[ -n "$(_tgp_state_get ROUTE_TABLE)" ]] || _tgp_state_set ROUTE_TABLE 7791
    [[ -n "$(_tgp_state_get RULE_PRIO)" ]] || _tgp_state_set RULE_PRIO "$(_tgp_state_get ROUTE_TABLE)"
    _tgp_state_set FW_BACKEND "${TGPROXY_FW:-auto}"
    if [[ -n "${TGPROXY_MEM_LIMIT:-}" ]]; then
        _tgp_state_set MEM_LIMIT "$TGPROXY_MEM_LIMIT"
    elif [[ -z "$(_tgp_state_get MEM_LIMIT)" ]]; then
        _tgp_state_set MEM_LIMIT 128m
    fi
    _tgp_state_set SAVE_IMAGE "${TGPROXY_SAVE_IMAGE:-1}"
    _tgp_state_set SCRIPTS_DIR "$TGP_SCRIPTS_DIR"
}

_tgp_set_image() {
    local ver="${TGPROXY_TELEMT_VERSION:-${1:-$TGP_TELEMT_VERSION_DEFAULT}}"
    [[ "$ver" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "bad TGPROXY_TELEMT_VERSION '$ver'"
    _tgp_state_set TELEMT_VERSION "$ver"
    _tgp_state_set TELEMT_IMAGE "ghcr.io/telemt/telemt:$ver"
}

# _tgp_bring_up: render, image, compose registration, outway, container, route check, nginx.
_tgp_bring_up() {
    local recreate=${1:-}
    _tgp_cfg render
    _tgp_cfg pull
    ext_register_compose "$TGP_ID" "$TGP_DIR/docker-compose.yml"
    _tgp_outway up
    _tgp_outway install-unit
    # shellcheck disable=SC2086
    ext_compose up -d --wait $recreate telemt || {
        ext_compose logs --tail 30 telemt >&2 || true
        die "telemt did not become healthy (see the log above); fix the cause and re-run, or remove it"
    }
    _tgp_cfg check-route
    ext_nginx_location_put "$TGP_ID" <"$TGP_DIR/nginx-location.conf"
}

ext_telegram_web_proxy_do_install() {
    _tgp_preflight
    _tgp_pick_outway "$(_tgp_state_get OUTWAY)"
    TGP_SCRIPTS_DIR="$(_tgp_scripts_dir)"
    _tgp_state_set OUTWAY "$TGP_OUTWAY_CHOICE"
    _tgp_write_state
    _tgp_set_image "$(_tgp_state_get TELEMT_VERSION)"
    _tgp_install_scripts "$TGP_SCRIPTS_DIR"
    _tgp_bring_up
    date -u +%FT%TZ >"$TGP_MARKER"
    chmod 600 "$TGP_MARKER"
    _tgp_print_result
}

ext_telegram_web_proxy_do_update() {
    local rotate="${TGPROXY_ROTATE:-}" old_image new_image
    _tgp_preflight
    TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
    [[ -n "$TGP_SCRIPTS_DIR" && -x "$TGP_SCRIPTS_DIR/tgproxy-config.sh" ]] || TGP_SCRIPTS_DIR="$(_tgp_scripts_dir)"
    old_image="$(_tgp_state_get TELEMT_IMAGE)"
    if [[ -z "$rotate" ]] && _tgp_interactive; then
        _tgp_confirm "Also rotate the secret path and the user secret (the old link stops working)?" && rotate=all
    fi
    if [[ -n "${TGPROXY_OUTWAY:-}" ]]; then
        _tgp_pick_outway "$(_tgp_state_get OUTWAY)"
        _tgp_state_set OUTWAY "$TGP_OUTWAY_CHOICE"
        _tgp_state_set OUTWAY_GW ""
    fi
    case "$rotate" in
        path | all) _tgp_state_set BASE_PATH "$(_tgp_rand_path)" ;;
    esac
    case "$rotate" in
        secret | all) _tgp_state_set USER_SECRET "$(_tgp_rand_secret)" ;;
    esac
    [[ -z "$rotate" || "$rotate" == path || "$rotate" == secret || "$rotate" == all ]] || die "bad TGPROXY_ROTATE '$rotate' (path|secret|all)"
    _tgp_set_image
    _tgp_state_set PUBLIC_IP "$(_tgp_public_ip "$(site_domain)")"
    _tgp_state_set SHARED_SUBNET "$(_tgp_shared_subnet "$(_tgp_state_get COMPOSE_PROJECT)")"
    _tgp_install_scripts "$TGP_SCRIPTS_DIR"
    TGPROXY_FORCE_PULL=1 _tgp_bring_up --force-recreate
    new_image="$(_tgp_state_get TELEMT_IMAGE)"
    [[ "$old_image" == "$new_image" ]] || docker rmi "$old_image" >/dev/null 2>&1 || true
    _tgp_print_result
}

ext_telegram_web_proxy_do_remove() {
    local script purge=()
    TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
    script="$TGP_SCRIPTS_DIR/tgproxy-remove.sh"
    [[ -x "$script" ]] || script="$TGP_SRC/tgproxy-remove.sh"
    if [[ "${TGPROXY_PURGE:-0}" == 1 ]]; then
        purge=(--purge)
    elif _tgp_interactive && _tgp_confirm "Also delete the config and the secrets (data/telegram-web-proxy)? Otherwise a reinstall restores the same link."; then
        purge=(--purge)
    fi
    _tgp_confirm "Remove the Telegram web proxy (the rest of the stack keeps running)?" || die "aborted"
    TGPROXY_STATE="$TGP_STATE" bash "$script" --yes "${purge[@]}"
}

_tgp_do_outway() {
    TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
    _tgp_preflight
    _tgp_pick_outway "$(_tgp_state_get OUTWAY)"
    _tgp_cfg outway "$TGP_OUTWAY_CHOICE"
    ok "outway: $TGP_OUTWAY_CHOICE"
}

_tgp_do_rotate() {
    local what="${TGPROXY_ROTATE:-}" ans
    TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
    if [[ -z "$what" ]]; then
        _tgp_interactive || die "set TGPROXY_ROTATE=path|secret|all"
        read -r -p "Rotate: path, secret or all [all]: " ans || die "no input"
        what="${ans:-all}"
    fi
    _tgp_cfg rotate "$what"
}

ext_telegram_web_proxy_menu() {
    local ans
    printf '\nThe Telegram web proxy is installed (outway: %s).\n' "$(_tgp_state_get OUTWAY)" >&2
    printf '  1) update (pull the image, rebuild the config, restart; optional rotation)\n  2) remove\n  3) show link\n  4) change outway (outgoing interface)\n  5) rotate secret path / secret\n  6) status\n  0) cancel\n' >&2
    read -r -p "Choose: " ans || return 0
    case "$ans" in
        1) TGPROXY_ACTION="update" ;;
        2) TGPROXY_ACTION="remove" ;;
        3) TGPROXY_ACTION="link" ;;
        4) TGPROXY_ACTION="outway" ;;
        5) TGPROXY_ACTION="rotate" ;;
        6) TGPROXY_ACTION="status" ;;
        *) TGPROXY_ACTION="cancel" ;;
    esac
}

# ext_telegram_web_proxy_install: entry point of the menu entry.
ext_telegram_web_proxy_install() {
    local action="${TGPROXY_ACTION:-}"
    TGP_SCRIPTS_DIR=""
    if _tgp_installed; then
        TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
        [[ -x "$TGP_SCRIPTS_DIR/tgproxy-config.sh" ]] || TGP_SCRIPTS_DIR=""
        if [[ -z "$action" ]]; then
            if _tgp_interactive; then
                ext_telegram_web_proxy_menu
                action="$TGPROXY_ACTION"
                TGPROXY_ACTION=""
            else
                action=update
            fi
        fi
        [[ "$action" != install ]] || action=update
    else
        [[ -n "$action" ]] || action=install
        [[ "$action" == install ]] || die "the Telegram web proxy is not installed (TGPROXY_ACTION=$action); use TGPROXY_ACTION=install"
    fi
    case "$action" in
        install) ext_telegram_web_proxy_do_install ;;
        update) ext_telegram_web_proxy_do_update ;;
        remove) ext_telegram_web_proxy_do_remove ;;
        link) _tgp_cfg link ;;
        outway) _tgp_do_outway ;;
        rotate) _tgp_do_rotate ;;
        status) _tgp_cfg status ;;
        cancel) info "nothing done" ;;
        *) die "unknown TGPROXY_ACTION '$action' (install|update|remove|link|outway|rotate|status)" ;;
    esac
}
