# Extension: 3x-ui panel (https://github.com/MHSanaei/3x-ui, bundles Xray) with
# Xray VLESS + REALITY inbounds. See README.md, section "3x-ui panel (Xray)".
# shellcheck shell=bash
#
#   - The panel (login admin, generated password) is served at a secret path of the
#     site: https://DOMAIN/<path>/ (an nginx location, ext_nginx_location_put); every
#     other path stays on the decoy site. The panel port is never published.
#   Two stages. Stage 1 (the default install): the panel and the "plain" inbound.
#   Stage 2 (opt-in): the "wl" inbound as well (XRAY_ACTION=wl, or answer the question
#   at the install).
#   - Inbound "plain": VLESS + REALITY self-steal on a SEPARATE DNS name
#     (XRAY_PLAIN_DOMAIN, empty = no plain inbound) on the HTTPS port (443). The name
#     has its own Let's Encrypt certificate and an nginx server block with the decoy
#     site (ext_cert_request, ext_nginx_server_put); the REALITY target is that nginx
#     (nginx:443, serverNames = the name), so a probe sees the real site with its
#     certificate. The TLS front of nginx sends connections with that SNI to the inbound
#     (an internal container port, ext_nginx_stream_put, PROXY protocol); no host port.
#   - Inbound "wl" (stage 2): VLESS + REALITY + xtls-rprx-vision with an SNI from a
#     whitelist (XRAY_WL_SNI, default ozon.ru; REALITY target = that name:443). Same
#     routing by the TLS front; everything else stays on the site.
#   - Client traffic of Xray leaves through a chosen host interface ("outway": the
#     container has its own docker network that the host policy-routes, fail-closed;
#     the same script as the telegram-web-proxy extension, its own table 7792).
#
# Menu entry -> install / update / remove / show credentials and links / change outway /
# rotate password or path / recreate inbounds / status.
# Without a terminal choose the action by environment (read by this file only):
#   XRAY_ACTION=install|update|remove|show|outway|rotate|inbounds|wl|status
#   XRAY_PLAIN_DOMAIN=<name>|off     XRAY_OUTWAY=<interface>|auto
#   XRAY_WL=1|0 (stage 2: enable/disable the wl inbound; XRAY_WL_SNI alone enables it)
#   XRAY_WL_SNI=<name>[,<name>...]
#   XRAY_ROTATE=password|path|all    XRAY_NEW_KEYS=1 (inbounds: new keys and UUIDs)
#   XRAY_PURGE=1  XRAY_XUI_VERSION=<image tag>  XRAY_PUBLIC_HOST (host of the links)
#   XRAY_SUBNET  XRAY_OUTWAY_FAMILIES=4|6|46  XRAY_SAVE_IMAGE=0|1  XRAY_SCRIPTS_DIR
#   XRAY_MEM_LIMIT  XRAY_DRY_RUN=1 (outway commands only printed)
# e.g.: XRAY_ACTION=show sudo -E ./install.sh extensions --with xray-3xui
#
# Install phases (see extensions.d/README.md): ext_xray_3xui_collect asks every question,
# ext_xray_3xui_validate checks the answers and the host (read-only), the install
# function only deploys. The work is done by the standalone scripts in
# extensions.d/xray-3xui/ (xray-config.sh, xray-remove.sh) plus a copy of the outway
# script of telegram-web-proxy (xray-outway.sh), installed into scripts/ of the install
# directory (XRAY_SCRIPTS_DIR overrides) with the path of the state file baked in.

register_extension xray-3xui "3x-ui panel (Xray VLESS+REALITY on 443 by a separate name, optional whitelist SNI, selectable outgoing interface)" ext_xray_3xui_install

X3_ID="xray-3xui"
X3_XUI_VERSION_DEFAULT="v3.11.0"
X3_SRC="$CODE_DIR/extensions.d/xray-3xui"
X3_OUTWAY_SRC="$CODE_DIR/extensions.d/telegram-web-proxy/tgproxy-outway.sh"
X3_DIR="$DATA_DIR/xray-3xui"
X3_STATE="$X3_DIR/state.env"
X3_MARKER="$X3_DIR/installed"
X3_SCRIPTS_DIR=""
X3_WL_PORT=10443
X3_PANEL_PORT=2053
X3_TABLE=7792

# --- small helpers -------------------------------------------------------------------------

_x3_installed() { [[ -f "$X3_MARKER" && -f "$X3_STATE" ]]; }
# _x3_plain_on: the "plain" inbound is enabled in the state (a separate name is set).
_x3_plain_on() { [[ "$(_x3_state_get PLAIN_MODE)" == selfsteal && -n "$(_x3_state_get PLAIN_DOMAIN)" ]]; }
_x3_state_get() { [[ -f "$X3_STATE" ]] && sed -n "s/^$1=//p" "$X3_STATE" | tail -n1 || true; }
_x3_state_set() { XRAY_STATE="$X3_STATE" bash "$X3_SRC/xray-config.sh" state-set "$1" "$2"; }
# _x3_cfg ARGS...: xray-config.sh (installed copy when present, else the repository's).
_x3_cfg() { XRAY_STATE="$X3_STATE" bash "${X3_SCRIPTS_DIR:-$X3_SRC}/xray-config.sh" "$@"; }
# _x3_outway ARGS...: the installed xray-outway.sh, else the shared repository script
# (it reads TGPROXY_* variables; XRAY_* of this extension are passed on).
_x3_outway() {
    if [[ -n "$X3_SCRIPTS_DIR" && -f "$X3_SCRIPTS_DIR/xray-outway.sh" ]]; then
        XRAY_STATE="$X3_STATE" bash "$X3_SCRIPTS_DIR/xray-outway.sh" "$@"
    else
        TGPROXY_STATE="$X3_STATE" TGPROXY_DRY_RUN="${XRAY_DRY_RUN:-0}" TGPROXY_FW="${XRAY_FW:-}" \
            TGPROXY_OUTWAY_FAMILIES="${XRAY_OUTWAY_FAMILIES:-}" bash "$X3_OUTWAY_SRC" "$@"
    fi
}

_x3_interactive() { [[ -t 0 && "${ASSUME_YES:-0}" != 1 ]]; }

_x3_confirm() {
    local q=$1 ans
    if [[ "${ASSUME_YES:-0}" == 1 ]]; then return 0; fi
    if [[ ! -t 0 ]]; then return 0; fi
    read -r -p "$q $(t common.yn) " ans || return 1
    [[ "${ans,,}" == y || "${ans,,}" == yes || "${ans,,}" == д || "${ans,,}" == да ]]
}

_x3_scripts_dir() { printf '%s' "${XRAY_SCRIPTS_DIR:-$APP_DIR/scripts}"; }

# _x3_install_scripts DIR: xray-config.sh and xray-remove.sh, plus xray-outway.sh (the
# outway script of telegram-web-proxy with the XRAY_* environment and this state file),
# root-owned, 755.
_x3_install_scripts() {
    local dir="$1" s
    [[ "$dir" != *[[:space:]]* ]] || die "$(t xui.dir_spaces "$dir")"
    mkdir -p "$dir"
    chown root:root "$dir" 2>/dev/null || true
    chmod 755 "$dir"
    for s in xray-config.sh xray-remove.sh; do
        sed "s|:-@STATE_FILE@}|:-$X3_STATE}|" "$X3_SRC/$s" >"$dir/$s.tmp"
        chmod 755 "$dir/$s.tmp"
        chown root:root "$dir/$s.tmp" 2>/dev/null || true
        mv -f "$dir/$s.tmp" "$dir/$s"
    done
    sed -e "s|\${TGPROXY_STATE:-@STATE_FILE@}|\${XRAY_STATE:-$X3_STATE}|" -e 's/TGPROXY_/XRAY_/g' \
        -e '2s|^# tgproxy-outway.sh - |# xray-outway.sh (installed copy of tgproxy-outway.sh, XRAY_* environment) - |' \
        "$X3_OUTWAY_SRC" >"$dir/xray-outway.sh.tmp"
    chmod 755 "$dir/xray-outway.sh.tmp"
    chown root:root "$dir/xray-outway.sh.tmp" 2>/dev/null || true
    mv -f "$dir/xray-outway.sh.tmp" "$dir/xray-outway.sh"
    X3_SCRIPTS_DIR="$dir"
    ok "$(t xui.scripts_ok "$dir")"
}

_x3_preflight() {
    local c
    [[ -f "$APP_DIR/.env" ]] || die "$(t cmd.no_env "$APP_DIR/.env")"
    require_docker
    for c in ip openssl sed python3 getent; do
        command -v "$c" >/dev/null 2>&1 || die "$(t xui.need_tool "$c")"
    done
    site_domain >/dev/null
    [[ "$APP_DIR" != *[[:space:]]* ]] || die "$(t xui.path_spaces "$APP_DIR")"
    mkdir -p "$X3_DIR"
    chmod 700 "$X3_DIR"
}

_x3_have_ip() { command -v ip >/dev/null 2>&1; }

_x3_valid_outway() {
    if _x3_have_ip; then
        _x3_outway check "$1" >/dev/null 2>&1
    else
        [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$ ]]
    fi
}

_x3_list_outways() {
    if _x3_have_ip; then
        _x3_outway list || true
    else
        info "$(t xui.no_iproute)"
    fi
}

_x3_fams_name() {
    case "$1" in 46) printf 'IPv4+IPv6' ;; 6) printf 'IPv6 only' ;; 4) printf 'IPv4 only' ;; *) printf '?' ;; esac
}

# _x3_telemt_outway: the outway of an installed telegram-web-proxy (the default of
# the question; each extension may still use its own interface).
_x3_telemt_outway() {
    local f="$DATA_DIR/telegram-web-proxy/state.env"
    [[ -f "$f" ]] || return 0
    sed -n 's/^OUTWAY=//p' "$f" | tail -n1
}

# _x3_pick_outway [CURRENT]: COLLECT. The chosen interface goes to X3_OUTWAY_CHOICE
# (XRAY_OUTWAY, "auto", the current one / the one of telegram-web-proxy, or asked).
_x3_pick_outway() {
    local current="${1:-}" want="${XRAY_OUTWAY:-}" ans name
    X3_OUTWAY_CHOICE=""
    [[ -n "$current" ]] || current="$(_x3_telemt_outway)"
    if [[ "$want" == auto ]]; then
        want="$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
        [[ -n "$want" ]] || want="$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
        if [[ -z "$want" ]]; then
            problem "$(t xui.auto_no_route)"
            return 0
        fi
        info "$(t xui.auto_picked "$want")"
    fi
    if [[ -z "$want" ]]; then
        if ! _x3_interactive; then
            if [[ -n "$current" ]]; then
                X3_OUTWAY_CHOICE="$current"
                return 0
            fi
            _x3_list_outways
            problem "$(t xui.choose_outway)"
            return 0
        fi
        printf '\n%s\n' "$(t xui.outway_intro)" >&2
        [[ -z "$(_x3_telemt_outway)" ]] || info "$(t xui.outway_telemt "$(_x3_telemt_outway)")"
        _x3_list_outways
        while :; do
            read -r -p "$(t xui.q_outway "${current:+ [$current]}")" ans || die "$(t common.no_input)"
            ans="${ans:-$current}"
            if [[ "$ans" =~ ^[0-9]+$ ]] && _x3_have_ip; then
                name="$(_x3_outway resolve "$ans" 2>/dev/null)" || name=""
            else
                name="$ans"
            fi
            if [[ -n "$name" ]] && _x3_valid_outway "$name"; then
                want="$name"
                break
            fi
            warn "$(t xui.bad_iface "$ans")"
            _x3_list_outways
        done
    fi
    X3_OUTWAY_CHOICE="$want"
}

# _x3_norm_list VALUE: lowercased, spaces removed, comma separated.
_x3_norm_list() {
    local v="${1,,}"
    v="${v//[[:space:]]/,}"
    while [[ "$v" == *,,* ]]; do v="${v//,,/,}"; done
    v="${v#,}"
    printf '%s' "${v%,}"
}

# _x3_pick_sni [CURRENT]: COLLECT. The whitelist SNI (XRAY_WL_SNI, else asked, default
# CURRENT or ozon.ru) goes to X3_SNI_CHOICE; checked by the validate hook.
_x3_pick_sni() {
    local def="${1:-ozon.ru}" ans
    X3_SNI_CHOICE="$(_x3_norm_list "${XRAY_WL_SNI:-}")"
    if [[ -n "$X3_SNI_CHOICE" ]]; then
        info "$(t env.from_environment XRAY_WL_SNI "$X3_SNI_CHOICE")"
        return 0
    fi
    if ! _x3_interactive; then
        X3_SNI_CHOICE="$def"
        return 0
    fi
    printf '\n%s\n' "$(t xui.sni_intro)" >&2
    read -r -p "$(t xui.q_sni "$def")" ans || die "$(t common.no_input)"
    X3_SNI_CHOICE="$(_x3_norm_list "${ans:-$def}")"
}

# _x3_pick_plain [CURRENT]: COLLECT. The separate DNS name of the "plain" inbound
# (XRAY_PLAIN_DOMAIN, else asked; empty or "off" = no plain inbound) goes to
# X3_PLAIN_CHOICE, X3_PLAIN_SET=1 once it is decided. Checked by the validate hook.
_x3_pick_plain() {
    local def="${1:-}" ans
    X3_PLAIN_SET=0 X3_PLAIN_CHOICE=""
    if [[ -n "${XRAY_PLAIN_DOMAIN+x}" ]]; then
        X3_PLAIN_CHOICE="${XRAY_PLAIN_DOMAIN,,}"
        X3_PLAIN_CHOICE="${X3_PLAIN_CHOICE//[[:space:]]/}"
        [[ "$X3_PLAIN_CHOICE" != off ]] || X3_PLAIN_CHOICE=""
        X3_PLAIN_SET=1
        info "$(t env.from_environment XRAY_PLAIN_DOMAIN "${X3_PLAIN_CHOICE:-off}")"
        return 0
    fi
    [[ "$X3_ACTION" == install ]] && _x3_interactive || return 0
    printf '\n%s\n' "$(t xui.plain_intro "$(site_domain_hint)")" >&2
    while :; do
        read -r -p "$(t xui.q_plain "${def:+ [$def]}")" ans || die "$(t common.no_input)"
        ans="${ans:-$def}"
        ans="${ans,,}"
        ans="${ans//[[:space:]]/}"
        if [[ -z "$ans" ]] || valid_domain "$ans"; then
            X3_PLAIN_CHOICE="$ans"
            X3_PLAIN_SET=1
            return 0
        fi
        warn "$(t env.invalid_value "$(t hint.domain)")"
    done
}

# site_domain_hint: DOMAIN of .env for the prompt text.
site_domain_hint() { env_value DOMAIN; }

# _x3_pick_wl [CURRENT_SNI]: COLLECT, stage 2. X3_WL_CHOICE = 1 (enable), 0
# (disable) or "" (leave as is); with 1 the SNI goes to X3_SNI_CHOICE. XRAY_WL=1|0, or
# XRAY_WL_SNI alone (= enable); else, at an install, a question that defaults to No.
_x3_pick_wl() {
    local cur_sni="${1:-}" want="${XRAY_WL:-}" ans
    X3_WL_CHOICE="" X3_SNI_CHOICE="$(_x3_norm_list "${XRAY_WL_SNI:-}")"
    case "${want,,}" in
        1 | on | yes | true) X3_WL_CHOICE=1 ;;
        0 | off | no | false) X3_WL_CHOICE=0 X3_SNI_CHOICE="" ;;
        *)
            if [[ -n "$X3_SNI_CHOICE" ]]; then
                X3_WL_CHOICE=1
            elif [[ "$X3_ACTION" == install ]] && _x3_interactive; then
                if _x3_confirm "$(t xui.q_wl)"; then X3_WL_CHOICE=1; else X3_WL_CHOICE=0; fi
            elif [[ "$X3_ACTION" == wl ]]; then
                X3_WL_CHOICE=1
            fi
            ;;
    esac
    [[ "$X3_WL_CHOICE" == 1 ]] || return 0
    _x3_pick_sni "${cur_sni:-ozon.ru}"
}

# _x3_subnet WANT: "SUBNET GATEWAY XUI_IP" of a free private /24 (172.29.200-254 by
# default: telegram-web-proxy starts at 172.29.77), or WANT when it overlaps nothing.
# The subnet in the state file of telegram-web-proxy counts as used even while its
# network does not exist.
_x3_subnet() {
    local want="${1:-}" used
    used="$({
        ip -4 -o route show 2>/dev/null | awk '{print $1}'
        ip -4 -o addr show 2>/dev/null | awk '{print $4}'
        # shellcheck disable=SC2046
        docker network inspect $(docker network ls -q 2>/dev/null) --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null || true
        sed -n 's/^NET_SUBNET=//p' "$DATA_DIR/telegram-web-proxy/state.env" 2>/dev/null || true
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
        sys.exit("XRAY_SUBNET must be a private IPv4 network between /16 and /28")
    if not free(n):
        sys.exit("XRAY_SUBNET %s overlaps a host route, address or docker network" % n)
else:
    for i in range(200, 255):
        n = ipaddress.ip_network("172.29.%d.0/24" % i)
        if free(n):
            break
    else:
        sys.exit("no free 172.29.x.0/24 subnet; set XRAY_SUBNET")
h = list(n.hosts())
print(n, h[0], h[1])
PY
}

# _x3_shared_subnet PROJECT: IPv4 subnet of the project's default network.
_x3_shared_subnet() {
    local nid sn
    nid="$(docker network ls -q --filter "label=com.docker.compose.project=$1" --filter "label=com.docker.compose.network=default" | head -n1)"
    [[ -n "$nid" ]] || die "$(t xui.no_project_net)"
    sn="$(docker network inspect "$nid" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}/[0-9]+$' | head -n1 || true)"
    [[ -n "$sn" ]] || die "$(t xui.no_project_subnet)"
    printf '%s' "$sn"
}

_x3_rand_path() { rand_str 20 'A-Za-z0-9'; }
_x3_rand_password() { rand_str 24 'A-Za-z0-9'; }

# _x3_tls_probe NAME: the REALITY target answers TLS 1.3 with ALPN h2 (from this host).
# Prints "ok", "notls13", "noh2" or "offline".
_x3_tls_probe() {
    local out
    command -v openssl >/dev/null 2>&1 || { printf 'offline'; return 0; }
    out="$(timeout 10 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 </dev/null 2>&1 || true)"
    if ! grep -q 'BEGIN CERTIFICATE\|Server certificate\|Protocol *: *TLSv1.3\|New, TLSv1.3' <<<"$out"; then
        if grep -qi 'alert protocol version\|wrong version\|unsupported protocol' <<<"$out"; then printf 'notls13'; else printf 'offline'; fi
        return 0
    fi
    grep -q 'TLSv1.3' <<<"$out" || { printf 'notls13'; return 0; }
    grep -q 'ALPN protocol: h2' <<<"$out" || { printf 'noh2'; return 0; }
    printf 'ok'
}

# --- result ------------------------------------------------------------------------------

# ext_xray_3xui_result: lines of the final "result data" block (stdout).
ext_xray_3xui_result() {
    local out
    _x3_installed || return 0
    X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
    [[ -x "$X3_SCRIPTS_DIR/xray-config.sh" ]] || X3_SCRIPTS_DIR=""
    out="$(_x3_cfg show 2>/dev/null)" || return 0
    printf '%s\n' "$(t xui.res_panel "$(sed -n 's/^panel *: //p' <<<"$out")" "$(sed -n 's/^login *: //p' <<<"$out")" "$(sed -n 's/^password *: //p' <<<"$out")")"
    if grep -q '^plain *: ' <<<"$out"; then
        printf '%s\n' "$(t xui.res_plain "$(sed -n 's/^plain *: //p' <<<"$out")")"
    fi
    if grep -q '^wl *: ' <<<"$out"; then
        printf '%s\n' "$(t xui.res_wl "$(sed -n 's/^wl *: //p' <<<"$out")")"
    fi
}

_x3_print_result() {
    local out
    out="$(_x3_cfg show 2>/dev/null)"
    printf '\n' >&2
    ok "$(t xui.ready)"
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    printf '\n' >&2
    warn "$(t xui.secret_warn)"
    info "$(t xui.outway_info "$(_x3_state_get OUTWAY)" "$X3_SCRIPTS_DIR")"
    if _x3_plain_on; then
        info "$(t xui.plain_info "$(_x3_state_get PLAIN_DOMAIN)" "$X3_SCRIPTS_DIR")"
    else
        info "$(t xui.plain_off_info "$X3_SCRIPTS_DIR")"
    fi
    if [[ "$(_x3_state_get WL_ENABLED)" == 1 ]]; then
        info "$(t xui.wl_info "$(_x3_state_get WL_SNI)" "$X3_SCRIPTS_DIR")"
    else
        info "$(t xui.wl_off_info "$X3_SCRIPTS_DIR")"
    fi
    info "$(t xui.manage_info "$X3_SCRIPTS_DIR")"
    [[ "$(nginx_https_port)" == 443 ]] || warn "$(t xui.port_warn "$(nginx_https_port)")"
}

# --- actions -------------------------------------------------------------------------------------

_x3_write_state() {
    local domain project net gw xip
    domain="$(site_domain)"
    # State of earlier versions: the published plain port, the bridge name, reply marks.
    XRAY_STATE="$X3_STATE" bash "$X3_SRC/xray-config.sh" migrate-state
    project="$(sed -n 's/^name:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "$APP_DIR/docker-compose.yml" | head -n1)"
    project="${project:-escape}"
    # Existing values (a reinstall after "remove" without --purge) are kept: same panel and links.
    [[ -n "$(_x3_state_get PANEL_PATH)" ]] || _x3_state_set PANEL_PATH "$(_x3_rand_path)"
    [[ -n "$(_x3_state_get PANEL_PASSWORD)" ]] || _x3_state_set PANEL_PASSWORD "$(_x3_rand_password)"
    if [[ -z "$(_x3_state_get NET_SUBNET)" ]]; then
        read -r net gw xip < <(_x3_subnet "${XRAY_SUBNET:-}") || die "$(t xui.no_subnet)"
        [[ -n "$xip" ]] || die "$(t xui.no_subnet)"
        _x3_state_set NET_SUBNET "$net"
        _x3_state_set NET_GATEWAY "$gw"
        _x3_state_set XUI_IP "$xip"
    fi
    _x3_state_set XRAY_STATE_VERSION 1
    _x3_state_set APP_DIR "$APP_DIR"
    _x3_state_set DOMAIN "$domain"
    _x3_state_set COMPOSE_PROJECT "$project"
    _x3_state_set NET_NAME "$project-xray"
    _x3_state_set SHARED_SUBNET "$(_x3_shared_subnet "$project")"
    _x3_state_set HTTPS_PORT "$(nginx_https_port)"
    _x3_state_set PUBLIC_HOST "${XRAY_PUBLIC_HOST:-$domain}"
    _x3_state_set PANEL_USER admin
    _x3_state_set PANEL_PORT "$X3_PANEL_PORT"
    _x3_state_set WL_PORT "$X3_WL_PORT"
    # Stage 2 (the "wl" inbound) is opt-in: WL_ENABLED stays 0 unless asked for.
    [[ -n "$(_x3_state_get WL_ENABLED)" ]] || _x3_state_set WL_ENABLED 0
    [[ -z "$X3_WL_CHOICE" ]] || _x3_state_set WL_ENABLED "$X3_WL_CHOICE"
    [[ -z "$X3_SNI_CHOICE" ]] || _x3_state_set WL_SNI "$X3_SNI_CHOICE"
    [[ -n "$(_x3_state_get WL_SNI)" ]] || _x3_state_set WL_SNI ozon.ru
    # Stage 1: the "plain" inbound on its own DNS name (empty = none).
    if ((X3_PLAIN_SET)); then
        _x3_state_set PLAIN_DOMAIN "$X3_PLAIN_CHOICE"
        if [[ -n "$X3_PLAIN_CHOICE" ]]; then _x3_state_set PLAIN_MODE selfsteal; else _x3_state_set PLAIN_MODE off; fi
    fi
    [[ -n "$(_x3_state_get PLAIN_MODE)" ]] || _x3_state_set PLAIN_MODE off
    _x3_state_set FINGERPRINT chrome
    # Outway: own names, table and rule priority (side by side with telegram-web-proxy).
    [[ -n "$(_x3_state_get ROUTE_TABLE)" ]] || _x3_state_set ROUTE_TABLE "$X3_TABLE"
    [[ -n "$(_x3_state_get RULE_PRIO)" ]] || _x3_state_set RULE_PRIO "$(_x3_state_get ROUTE_TABLE)"
    _x3_state_set OUTWAY_CHAIN XRAY-OUTWAY
    _x3_state_set OUTWAY_NFT_TABLE xray_outway
    _x3_state_set OUTWAY_UNIT xray-3xui-outway
    _x3_state_set OUTWAY_SYSCTL_NAME 90-xray-3xui.conf
    _x3_state_set OUTWAY_COMMENT xray-outway
    _x3_state_set OUTWAY_LABEL 3x-ui
    _x3_state_set OUTWAY_TITLE Xray-3x-ui
    _x3_state_set FW_BACKEND "${XRAY_FW:-auto}"
    if [[ -n "${XRAY_MEM_LIMIT:-}" ]]; then
        _x3_state_set MEM_LIMIT "$XRAY_MEM_LIMIT"
    elif [[ -z "$(_x3_state_get MEM_LIMIT)" ]]; then
        _x3_state_set MEM_LIMIT 192m
    fi
    _x3_state_set SAVE_IMAGE "${XRAY_SAVE_IMAGE:-1}"
    _x3_state_set SCRIPTS_DIR "$X3_SCRIPTS_DIR"
}

_x3_set_image() {
    local ver="${XRAY_XUI_VERSION:-${1:-$X3_XUI_VERSION_DEFAULT}}"
    [[ "$ver" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "$(t xui.bad_version "$ver")"
    _x3_state_set XUI_VERSION "$ver"
    _x3_state_set XUI_IMAGE "ghcr.io/mhsanaei/3x-ui:$ver"
}

# _x3_nginx_routes: the http-level snippet (rate-limit zone, WebSocket map, PROXY
# protocol trust; with the plain name also its server blocks and certificate), the
# panel location (uses the zone) and the TLS front routes (plain name, whitelist SNI).
_x3_nginx_routes() {
    local name="" routes
    _x3_plain_on && name="$(_x3_state_get PLAIN_DOMAIN)"
    if [[ -n "$name" ]]; then
        ext_nginx_server_put "$X3_ID" "$name" <"$X3_DIR/nginx-http.conf"
    else
        ext_nginx_server_put "$X3_ID" <"$X3_DIR/nginx-http.conf"
        ext_cert_release "$X3_ID"
    fi
    ext_nginx_location_put "$X3_ID" <"$X3_DIR/nginx-location.conf"
    routes="$(grep -v '^#' "$X3_DIR/nginx-stream.map" || true)"
    if [[ -n "$routes" ]]; then
        ext_nginx_stream_put "$X3_ID" <<<"$routes"
    else
        ext_nginx_stream_rm "$X3_ID"
    fi
    # Self-signed until Let's Encrypt has issued the certificate; a failure is not
    # fatal (the renewal timer retries).
    [[ -z "$name" ]] || ext_cert_request "$X3_ID" "$name" || warn "$(t xui.cert_failed "$name")"
}

# _x3_bring_up [--force-recreate]: render, image, compose registration, outway,
# container, route check, panel credentials, inbounds, nginx.
_x3_bring_up() {
    local recreate=${1:-}
    _x3_cfg render
    _x3_cfg pull
    ext_register_compose "$X3_ID" "$X3_DIR/docker-compose.yml"
    _x3_outway up
    _x3_outway install-unit
    _x3_cfg net-check
    # shellcheck disable=SC2086
    ext_compose up -d --wait $recreate xui || {
        ext_compose logs --tail 30 xui >&2 || true
        die "$(t xui.unhealthy)"
    }
    _x3_cfg check-route
    _x3_cfg panel
    _x3_cfg inbounds
    _x3_nginx_routes
}

ext_xray_3xui_do_install() {
    _x3_preflight
    _x3_outway check "$X3_OUTWAY_CHOICE" || die "$(t xui.invalid_outway "$X3_OUTWAY_CHOICE")"
    X3_SCRIPTS_DIR="$(_x3_scripts_dir)"
    _x3_state_set OUTWAY "$X3_OUTWAY_CHOICE"
    _x3_write_state
    _x3_set_image "$(_x3_state_get XUI_VERSION)"
    _x3_install_scripts "$X3_SCRIPTS_DIR"
    _x3_cfg net-setup --redetect
    _x3_bring_up
    date -u +%FT%TZ >"$X3_MARKER"
    chmod 600 "$X3_MARKER"
    _x3_print_result
}

ext_xray_3xui_do_update() {
    local old_image new_image
    _x3_preflight
    X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
    [[ -n "$X3_SCRIPTS_DIR" && -x "$X3_SCRIPTS_DIR/xray-config.sh" ]] || X3_SCRIPTS_DIR="$(_x3_scripts_dir)"
    old_image="$(_x3_state_get XUI_IMAGE)"
    if [[ -n "${XRAY_OUTWAY:-}" ]]; then
        _x3_outway check "$X3_OUTWAY_CHOICE" || die "$(t xui.invalid_outway "$X3_OUTWAY_CHOICE")"
        _x3_state_set OUTWAY "$X3_OUTWAY_CHOICE"
        _x3_state_set OUTWAY_GW ""
        _x3_state_set OUTWAY_GW6 ""
    fi
    _x3_write_state
    _x3_set_image
    _x3_install_scripts "$X3_SCRIPTS_DIR"
    if [[ -n "${XRAY_OUTWAY:-}" ]]; then _x3_cfg net-setup --redetect; else _x3_cfg net-setup; fi
    XRAY_FORCE_PULL=1 _x3_bring_up --force-recreate
    [[ -z "$X3_ROTATE" ]] || _x3_cfg rotate "$X3_ROTATE" >/dev/null
    new_image="$(_x3_state_get XUI_IMAGE)"
    [[ "$old_image" == "$new_image" ]] || docker rmi "$old_image" >/dev/null 2>&1 || true
    _x3_print_result
}

ext_xray_3xui_do_remove() {
    local script purge=()
    X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
    script="$X3_SCRIPTS_DIR/xray-remove.sh"
    [[ -x "$script" ]] || script="$X3_SRC/xray-remove.sh"
    ((!X3_PURGE)) || purge=(--purge)
    XRAY_STATE="$X3_STATE" bash "$script" --yes "${purge[@]}"
}

# ext_xray_3xui_purge: hook of `install.sh remove --purge`: remove the panel completely
# (container, outway rules, systemd units, sysctl.d file, nginx routes, state, panel
# database) while the stack still runs.
ext_xray_3xui_purge() {
    ext_load_lang "$X3_ID"
    _x3_installed || return 0
    X3_PURGE=1
    ext_xray_3xui_do_remove
}

_x3_do_outway() {
    X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
    _x3_preflight
    _x3_outway check "$X3_OUTWAY_CHOICE" || die "$(t xui.invalid_outway "$X3_OUTWAY_CHOICE")"
    _x3_cfg outway "$X3_OUTWAY_CHOICE"
    ok "$(t xui.outway_done "$X3_OUTWAY_CHOICE")"
}

_x3_do_rotate() {
    X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
    # A new path: the standalone script renders and installs the nginx location itself.
    _x3_cfg rotate "$X3_ROTATE" >/dev/null
    _x3_print_result
}

_x3_do_inbounds() {
    X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
    if [[ "$X3_NEW_KEYS" == 1 ]]; then _x3_cfg inbounds --new-keys; else _x3_cfg inbounds --recreate; fi
    _x3_print_result
}

# _x3_do_wl: stage 2, enable (with the SNI), change or disable the "wl" inbound.
_x3_do_wl() {
    X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
    if [[ "$X3_WL_CHOICE" == 1 ]]; then
        _x3_cfg wl on "${X3_SNI_CHOICE:-$(_x3_state_get WL_SNI)}" >/dev/null
    else
        _x3_cfg wl off >/dev/null
    fi
    _x3_print_result
}

ext_xray_3xui_menu() {
    local ans
    printf '\n%s\n' "$(t xui.menu_head "$(_x3_state_get PLAIN_DOMAIN)" "$(_x3_state_get OUTWAY)")" >&2
    printf '%s\n' "$(t xui.menu_items)" >&2
    read -r -p "$(t xui.menu_prompt)" ans || return 0
    case "$ans" in
        1) X3_ACTION="update" ;;
        2) X3_ACTION="remove" ;;
        3) X3_ACTION="show" ;;
        4) X3_ACTION="outway" ;;
        5) X3_ACTION="rotate" ;;
        6) X3_ACTION="inbounds" ;;
        7) X3_ACTION="status" ;;
        8) X3_ACTION="wl" ;;
        *) X3_ACTION="cancel" ;;
    esac
}

# --- install phases --------------------------------------------------------------------------

# ext_xray_3xui_collect: COLLECT. Decide the action (XRAY_ACTION, the menu, or the default)
# and ask everything it needs. Changes nothing.
ext_xray_3xui_collect() {
    ext_load_lang "$X3_ID"
    local action="${XRAY_ACTION:-}" ans
    X3_ACTION="" X3_OUTWAY_CHOICE="" X3_ROTATE="" X3_PURGE=0 X3_SCRIPTS_DIR="" X3_SNI_CHOICE="" X3_PLAIN_CHOICE="" X3_PLAIN_SET=0 X3_WL_CHOICE="" X3_PLAIN_SET=0 X3_WL_CHOICE=""
    X3_NEW_KEYS="${XRAY_NEW_KEYS:-0}"
    if _x3_installed; then
        X3_SCRIPTS_DIR="$(_x3_state_get SCRIPTS_DIR)"
        [[ -x "$X3_SCRIPTS_DIR/xray-config.sh" ]] || X3_SCRIPTS_DIR=""
        if [[ -z "$action" ]]; then
            if _x3_interactive; then
                ext_xray_3xui_menu
                action="$X3_ACTION"
            else
                action=update
            fi
        fi
        [[ "$action" != install ]] || action=update
    else
        [[ -n "$action" ]] || action=install
    fi
    X3_ACTION="$action"
    case "$action" in
        install)
            _x3_pick_plain "$(_x3_state_get PLAIN_DOMAIN)"
            _x3_pick_wl "$(_x3_state_get WL_SNI)"
            _x3_pick_outway "$(_x3_state_get OUTWAY)"
            ;;
        update)
            _x3_pick_plain "$(_x3_state_get PLAIN_DOMAIN)"
            _x3_pick_wl "$(_x3_state_get WL_SNI)"
            X3_ROTATE="${XRAY_ROTATE:-}"
            if [[ -z "$X3_ROTATE" ]] && _x3_interactive; then
                _x3_confirm "$(t xui.q_rotate_all)" && X3_ROTATE=all
            fi
            [[ -z "${XRAY_OUTWAY:-}" ]] || _x3_pick_outway "$(_x3_state_get OUTWAY)"
            ;;
        remove)
            if [[ "${XRAY_PURGE:-0}" == 1 ]]; then
                X3_PURGE=1
            elif _x3_interactive && _x3_confirm "$(t xui.q_purge)"; then
                X3_PURGE=1
            fi
            _x3_confirm "$(t xui.q_remove)" || die "$(t common.aborted)"
            ;;
        outway) _x3_pick_outway "$(_x3_state_get OUTWAY)" ;;
        wl) _x3_pick_wl "$(_x3_state_get WL_SNI)" ;;
        rotate)
            X3_ROTATE="${XRAY_ROTATE:-}"
            if [[ -z "$X3_ROTATE" ]]; then
                if _x3_interactive; then
                    read -r -p "$(t xui.q_rotate)" ans || die "$(t common.no_input)"
                    X3_ROTATE="${ans:-password}"
                else
                    problem "$(t xui.set_rotate)"
                fi
            fi
            ;;
        inbounds)
            if [[ "$X3_NEW_KEYS" != 1 ]] && _x3_interactive && _x3_confirm "$(t xui.q_new_keys)"; then
                X3_NEW_KEYS=1
            fi
            ;;
    esac
}

# _x3_validate_sni LIST DOMAIN FAMILIES: syntax (problems), DNS and the TLS 1.3 / h2
# probe of the REALITY target (warnings: the host may be offline).
_x3_validate_sni() {
    local list=$1 domain=$2 fams=$3 n first res
    first="${list%%,*}"
    for n in ${list//,/ }; do
        if ! valid_domain "$n"; then
            problem "$(t xui.bad_sni "$n")"
            continue
        fi
        if [[ "$n" == "${domain,,}" ]] || { [[ -f "$EXT_CERTS_FILE" ]] && awk -v x="$n" '$2 == x {f = 1} END {exit !f}' "$EXT_CERTS_FILE"; }; then
            problem "$(t xui.sni_is_ours "$n")"
            continue
        fi
        if [[ -z "$(getent ahosts "$n" 2>/dev/null | head -n1)" ]]; then
            warn "$(t xui.sni_noresolve "$n")"
        elif [[ "$fams" == 6 && -z "$(getent ahostsv6 "$n" 2>/dev/null | awk '$1 ~ /:/ && tolower($1) !~ /^::ffff:/' | head -n1)" ]]; then
            warn "$(t xui.sni_no_v6 "$n")"
        fi
    done
    valid_domain "$first" || return 0
    res="$(_x3_tls_probe "$first")"
    case "$res" in
        ok) ok "$(t xui.sni_tls_ok "$first")" ;;
        notls13) warn "$(t xui.sni_no_tls13 "$first")" ;;
        noh2) warn "$(t xui.sni_no_h2 "$first")" ;;
        *) warn "$(t xui.sni_probe_failed "$first")" ;;
    esac
}

# _x3_telemt_domain: the proxy name of an installed telegram-web-proxy.
_x3_telemt_domain() {
    local f="$DATA_DIR/telegram-web-proxy/state.env"
    [[ -f "$f" ]] || return 0
    sed -n 's/^TGPROXY_DOMAIN=//p' "$f" | tail -n1
}

# _x3_validate_plain DOMAIN FAMILIES: the separate name of the "plain" inbound (the
# choice of this run, else the state): a DNS name that differs from the name of the
# site, the Telegram proxy name and the whitelist SNI; the DNS check is the one used
# for TGPROXY_DOMAIN (warnings: the name may still be propagating).
_x3_validate_plain() {
    local site=${1,,} name tg
    if ((X3_PLAIN_SET)); then name="$X3_PLAIN_CHOICE"; else name="$(_x3_state_get PLAIN_DOMAIN)"; fi
    [[ -n "$name" ]] || return 0
    if ! valid_domain "$name"; then
        problem "$(t xui.bad_plain_domain "$name")"
        return 0
    fi
    tg="$(_x3_telemt_domain)"
    if [[ "$name" == "$site" ]]; then
        problem "$(t xui.plain_is_site "$name")"
    elif [[ -n "$tg" && "$name" == "${tg,,}" ]]; then
        problem "$(t xui.plain_is_tgproxy "$name")"
    elif [[ ",$(_x3_norm_list "${X3_SNI_CHOICE:-$(_x3_state_get WL_SNI)}")," == *",$name,"* ]]; then
        problem "$(t xui.plain_is_wl "$name")"
    else
        info "$(t xui.plain_separate "$name")"
        check_domain_dns "$name"
    fi
}

# ext_xray_3xui_validate: VALIDATE. Read-only checks; works before docker, .env and
# iproute2 exist (a new install). Problems are recorded with `problem`.
ext_xray_3xui_validate() {
    ext_load_lang "$X3_ID"
    local domain ver out dir fams="" sni wl_final
    case "$X3_ACTION" in
        install | update | remove | show | outway | rotate | inbounds | wl | status | cancel) ;;
        *)
            problem "$(t xui.unknown_action "$X3_ACTION")"
            return 0
            ;;
    esac
    if ! _x3_installed && [[ "$X3_ACTION" != install ]]; then
        problem "$(t xui.not_installed "$X3_ACTION")"
        return 0
    fi
    domain="$(env_value DOMAIN)"
    case "$X3_ACTION" in
        install | update | outway)
            [[ -n "$domain" ]] || ((ENV_NEW)) || problem "$(t xui.no_domain "$APP_DIR/.env")"
            [[ "$APP_DIR" != *[[:space:]]* ]] || problem "$(t xui.path_spaces "$APP_DIR")"
            if [[ -n "$X3_OUTWAY_CHOICE" ]] && _x3_have_ip; then
                if out="$(_x3_outway check "$X3_OUTWAY_CHOICE" 2>&1)"; then
                    fams="$(_x3_outway families "$X3_OUTWAY_CHOICE" 2>/dev/null || true)"
                    info "$(t xui.families_info "$X3_OUTWAY_CHOICE" "$(_x3_fams_name "$fams")")"
                else
                    problem "$(t xui.outway_problem "$X3_OUTWAY_CHOICE" "${out#error: }")"
                fi
            fi
            ;;
    esac
    case "$X3_ACTION" in
        install | update)
            ver="${XRAY_XUI_VERSION:-}"
            [[ -z "$ver" || "$ver" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || problem "$(t xui.bad_version "$ver")"
            ver="${ver:-$(_x3_state_get XUI_VERSION)}"
            ver="${ver:-$X3_XUI_VERSION_DEFAULT}"
            if command -v docker >/dev/null 2>&1 && ! docker image inspect "ghcr.io/mhsanaei/3x-ui:$ver" >/dev/null 2>&1; then
                if ! timeout 30 docker manifest inspect "ghcr.io/mhsanaei/3x-ui:$ver" >/dev/null 2>&1; then
                    warn "$(t xui.image_unchecked "ghcr.io/mhsanaei/3x-ui:$ver")"
                fi
            fi
            [[ -n "$fams" ]] || fams="$(_x3_state_get OUTWAY_FAMILIES)"
            _x3_validate_plain "$domain" "$fams"
            wl_final="${X3_WL_CHOICE:-$(_x3_state_get WL_ENABLED)}"
            sni="${X3_SNI_CHOICE:-$(_x3_state_get WL_SNI)}"
            [[ "$wl_final" != 1 || -z "$sni" ]] || _x3_validate_sni "$sni" "$domain" "$fams"
            [[ -z "${XRAY_PUBLIC_HOST:-}" ]] || [[ "$XRAY_PUBLIC_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || problem "$(t xui.bad_public_host "$XRAY_PUBLIC_HOST")"
            [[ "$(env_value NGINX_HTTPS_PORT)" == "" || "$(env_value NGINX_HTTPS_PORT)" == 443 ]] || warn "$(t xui.port_warn "$(env_value NGINX_HTTPS_PORT)")"
            ;;
    esac
    if [[ "$X3_ACTION" == install ]]; then
        dir="$(_x3_scripts_dir)"
        [[ "$dir" != *[[:space:]]* ]] || problem "$(t xui.dir_spaces "$dir")"
        info "$(t xui.generated_info)"
    fi
    if [[ "$X3_ACTION" == wl && "$X3_WL_CHOICE" == 1 ]]; then
        fams="$(_x3_state_get OUTWAY_FAMILIES)"
        [[ -n "${X3_SNI_CHOICE:-}" ]] || X3_SNI_CHOICE="$(_x3_state_get WL_SNI)"
        _x3_validate_sni "${X3_SNI_CHOICE:-ozon.ru}" "$domain" "$fams"
    fi
    case "$X3_ROTATE" in
        "" | password | path | all) ;;
        *) problem "$(t xui.bad_rotate "$X3_ROTATE")" ;;
    esac
    return 0
}

# ext_xray_3xui_install: DEPLOY (the registered install function). Runs the action chosen
# in the collect phase; asks nothing.
ext_xray_3xui_install() {
    ext_load_lang "$X3_ID"
    local action="${X3_ACTION:-}"
    [[ -n "$action" ]] || die "$(t xui.no_collect)"
    case "$action" in
        install) ext_xray_3xui_do_install ;;
        update) ext_xray_3xui_do_update ;;
        remove) ext_xray_3xui_do_remove ;;
        show) _x3_cfg show ;;
        outway) _x3_do_outway ;;
        rotate) _x3_do_rotate ;;
        inbounds) _x3_do_inbounds ;;
        wl) _x3_do_wl ;;
        status) _x3_cfg status ;;
        cancel) info "$(t xui.nothing_done)" ;;
        *) die "$(t xui.unknown_action "$action")" ;;
    esac
}
