  # Extension: Telegram WEB proxy on top of TELEMT (https://github.com/telemt/telemt).
# shellcheck shell=bash
# Telegram Desktop 7.1+ connects with a tg://webproxy link to https://<proxy name>/<secret path>/;
# nginx forwards only that path to the telemt container, every other path stays on
# the decoy site. The proxy name (TGPROXY_DOMAIN) is DOMAIN of the site by default; a
# separate name gets its own nginx server blocks (ext_nginx_server_put) and its own
# Let's Encrypt certificate (ext_cert_request), otherwise the secret path is a
# location in the server of the site (ext_nginx_location_put). The container's outgoing traffic leaves through a chosen host
# interface ("outway", policy routing). See README.md, section "Telegram web proxy".
#
# Menu entry -> install / update / remove / show link / change outway / rotate.
# Without a terminal choose the action by environment (read by this file only):
#   TGPROXY_ACTION=install|update|remove|link|outway|rotate|status
#   TGPROXY_DOMAIN=<proxy name> (default: the current one, else DOMAIN)
#   TGPROXY_OUTWAY=<interface name>|auto   TGPROXY_ROTATE=path|secret|all   TGPROXY_PURGE=1
#   TGPROXY_TELEMT_VERSION=<image tag>  TGPROXY_PUBLIC_IP (IPv4 or IPv6)  TGPROXY_SUBNET
#   TGPROXY_OUTWAY_FAMILIES=4|6|46 (override the detected address families of the outway)
#   TGPROXY_SAVE_IMAGE=0|1  TGPROXY_SCRIPTS_DIR  TGPROXY_MEM_LIMIT
#   TGPROXY_DRY_RUN=1 (outway commands only printed)
# e.g.: TGPROXY_ACTION=link TGPROXY_OUTWAY=eth0 sudo -E ./install.sh extensions --with telegram-web-proxy
#
# Install phases (see extensions.d/README.md): ext_telegram_web_proxy_collect asks every
# question (menu choice, proxy name, outgoing interface, rotation, confirmations) and changes nothing;
# ext_telegram_web_proxy_validate checks the answers; the install function only deploys.
#
# The heavy lifting is done by the standalone scripts in extensions.d/telegram-web-proxy/
# (tgproxy-config.sh, tgproxy-outway.sh, tgproxy-remove.sh), which are also copied to
# scripts/ of the install directory (TGPROXY_SCRIPTS_DIR overrides) with the path of the
# state file baked in; the systemd units of the outway run those copies.

register_extension telegram-web-proxy "Telegram web proxy (TELEMT, tg://webproxy link, selectable outgoing interface)" ext_telegram_web_proxy_install

TGP_ID="telegram-web-proxy"
TGP_TELEMT_VERSION_DEFAULT="3.5.17"
TGP_SRC="$CODE_DIR/extensions.d/telegram-web-proxy"
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

# _tgp_scripts_dir: where the standalone scripts are installed: scripts/ of the
# install directory (APP_DIR); TGPROXY_SCRIPTS_DIR overrides.
_tgp_scripts_dir() {
    printf '%s' "${TGPROXY_SCRIPTS_DIR:-$APP_DIR/scripts}"
}

# _tgp_install_scripts: copy the standalone scripts to the scripts directory (root-owned, 755),
# with the state file path baked in.
_tgp_install_scripts() {
    local dir="$1" s
    [[ "$dir" != *[[:space:]]* ]] || die "$(t tgp.dir_spaces "$dir")"
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
    ok "$(t tgp.scripts_ok "$dir")"
}

_tgp_preflight() {
    local c
    [[ -f "$APP_DIR/.env" ]] || die "$(t cmd.no_env "$APP_DIR/.env")"
    require_docker
    for c in ip openssl base64 sed python3 getent; do
        command -v "$c" >/dev/null 2>&1 || die "$(t tgp.need_tool "$c")"
    done
    site_domain >/dev/null
    [[ "$APP_DIR" != *[[:space:]]* ]] || die "$(t tgp.path_spaces "$APP_DIR")"
    mkdir -p "$TGP_DIR"
    chmod 700 "$TGP_DIR"
}

# _tgp_have_ip: iproute2 is installed (it is a prerequisite that the deploy phase
# installs, so it may be missing while the questions are asked).
_tgp_have_ip() { command -v ip >/dev/null 2>&1; }

# _tgp_valid_outway NAME: usable interface (name syntax only while `ip` is missing;
# the deploy phase checks it again).
_tgp_valid_outway() {
    if _tgp_have_ip; then
        _tgp_outway check "$1" >/dev/null 2>&1
    else
        [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$ ]]
    fi
}

_tgp_list_outways() {
    if _tgp_have_ip; then
        _tgp_outway list || true
    else
        info "$(t tgp.no_iproute)"
    fi
}

# _tgp_fams_name FAMILIES: 4, 6 or 46 as text (technical terms, not translated).
_tgp_fams_name() {
    case "$1" in 46) printf 'IPv4+IPv6' ;; 6) printf 'IPv6 only' ;; 4) printf 'IPv4 only' ;; *) printf '?' ;; esac
}

# _tgp_resolve_outway ANSWER: the interface name for an answer of the prompt, which is
# the number from the list or the name; fails for a number outside the list.
_tgp_resolve_outway() {
    local a=$1
    if [[ "$a" =~ ^[0-9]+$ ]]; then
        _tgp_have_ip || return 1
        _tgp_outway resolve "$a" 2>/dev/null
    else
        printf '%s' "$a"
    fi
}

# _tgp_pick_outway [CURRENT]: COLLECT. The chosen interface goes to TGP_OUTWAY_CHOICE
# (TGPROXY_OUTWAY, "auto", the current one, or asked). Nothing is changed; a missing
# answer is recorded as a problem, the value itself is checked by the validate hook.
_tgp_pick_outway() {
    local current="${1:-}" want="${TGPROXY_OUTWAY:-}" ans name
    TGP_OUTWAY_CHOICE=""
    if [[ "$want" == auto ]]; then
        want="$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
        [[ -n "$want" ]] || want="$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
        if [[ -z "$want" ]]; then
            problem "$(t tgp.auto_no_route)"
            return 0
        fi
        info "$(t tgp.auto_picked "$want")"
    fi
    if [[ -z "$want" ]]; then
        if ! _tgp_interactive; then
            if [[ -n "$current" ]]; then
                TGP_OUTWAY_CHOICE="$current"
                return 0
            fi
            _tgp_list_outways
            problem "$(t tgp.choose_outway)"
            return 0
        fi
        printf '\n%s\n' "$(t tgp.outway_intro)" >&2
        _tgp_list_outways
        while :; do
            read -r -p "$(t tgp.q_outway "${current:+ [$current]}")" ans || die "$(t common.no_input)"
            ans="${ans:-$current}"
            if [[ -n "$ans" ]] && name="$(_tgp_resolve_outway "$ans")" && _tgp_valid_outway "$name"; then
                want="$name"
                break
            fi
            warn "$(t tgp.bad_iface "$ans")"
            _tgp_list_outways
        done
    fi
    TGP_OUTWAY_CHOICE="$want"
}

# _tgp_trim VALUE: VALUE without surrounding white space, lowercased.
_tgp_trim() {
    local v=$1
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "${v,,}"
}

# _tgp_current_domain: the proxy name of the installation (an installation made
# before the separate name existed has none: it uses DOMAIN).
_tgp_current_domain() {
    local d
    d="$(_tgp_state_get TGPROXY_DOMAIN)"
    [[ -n "$d" ]] || d="$(_tgp_state_get DOMAIN)"
    printf '%s' "$d"
}

# _tgp_pick_domain [CURRENT]: COLLECT. The proxy name goes to TGP_DOMAIN_CHOICE:
# TGPROXY_DOMAIN, else asked (default CURRENT, else DOMAIN of the site), else
# (no terminal) CURRENT or DOMAIN. The value is checked by the validate hook.
_tgp_pick_domain() {
    local current="${1:-}" site ans def
    site="$(_tgp_trim "$(env_value DOMAIN)")"
    def="${current:-$site}"
    TGP_DOMAIN_CHOICE="$(_tgp_trim "${TGPROXY_DOMAIN:-}")"
    if [[ -n "$TGP_DOMAIN_CHOICE" ]]; then
        info "$(t env.from_environment TGPROXY_DOMAIN "$TGP_DOMAIN_CHOICE")"
        return 0
    fi
    if ! _tgp_interactive; then
        TGP_DOMAIN_CHOICE="$def"
        return 0
    fi
    printf '\n%s\n' "$(t tgp.domain_intro "${site:-DOMAIN}")" >&2
    while :; do
        read -r -p "$(t tgp.q_domain "${def:+ [$def]}")" ans || die "$(t common.no_input)"
        ans="$(_tgp_trim "${ans:-$def}")"
        if valid_domain "$ans"; then
            TGP_DOMAIN_CHOICE="$ans"
            return 0
        fi
        warn "$(t env.invalid_value "$(t hint.domain)")"
    done
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

# _tgp_is_ip VALUE: an IPv4 or IPv6 address literal.
_tgp_is_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ && "${1,,}" != ::ffff:* ]]
}

# _tgp_dns_ip DOMAIN: the first address of DOMAIN: A, then AAAA (getent, then dig/host
# when installed); empty when the name resolves to nothing.
_tgp_dns_ip() {
    local d=$1 ip=""
    ip="$(getent ahostsv4 "$d" 2>/dev/null | awk '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ {print $1; exit}' || true)"
    [[ -n "$ip" ]] || ip="$(getent ahostsv6 "$d" 2>/dev/null | awk '$1 ~ /:/ && tolower($1) !~ /^::ffff:/ {print $1; exit}' || true)"
    if [[ -z "$ip" ]] && command -v dig >/dev/null 2>&1; then
        ip="$(dig +short +time=3 +tries=1 A "$d" 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/ {print; exit}' || true)"
        [[ -n "$ip" ]] || ip="$(dig +short +time=3 +tries=1 AAAA "$d" 2>/dev/null | awk '/:/ {print; exit}' || true)"
    fi
    if [[ -z "$ip" ]] && command -v host >/dev/null 2>&1; then
        ip="$(host -W 3 "$d" 2>/dev/null | awk '/ has address / {print $NF; exit}' || true)"
        [[ -n "$ip" ]] || ip="$(host -W 3 "$d" 2>/dev/null | awk '/ has IPv6 address / {print $NF; exit}' || true)"
    fi
    _tgp_is_ip "$ip" || return 0
    printf '%s' "$ip"
}

# _tgp_host_ip: the source address of the host's default route (IPv4, else IPv6).
_tgp_host_ip() {
    local a=""
    _tgp_have_ip || return 0
    a="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
    [[ -n "$a" ]] || a="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
    _tgp_is_ip "$a" || return 0
    printf '%s' "$a"
}

# _tgp_resolve_public_ip DOMAIN: prints "SOURCE VALUE" for the telemt public_addr (the
# concrete address of the proxy; it is not used to build the link). Never fatal for a
# missing record. Order: TGPROXY_PUBLIC_IP (SOURCE env; an invalid value fails), the
# address of DOMAIN (dns: A, AAAA), the default-route address of the host (route),
# the name itself (domain, the last resort: telemt may reject a name).
_tgp_resolve_public_ip() {
    local domain=$1 ip="${TGPROXY_PUBLIC_IP:-}"
    if [[ -n "$ip" ]]; then
        _tgp_is_ip "$ip" || return 1
        printf 'env %s' "$ip"
        return 0
    fi
    ip="$(_tgp_dns_ip "$domain")"
    if [[ -n "$ip" ]]; then
        printf 'dns %s' "$ip"
        return 0
    fi
    ip="$(_tgp_host_ip)"
    if [[ -n "$ip" ]]; then
        printf 'route %s' "$ip"
        return 0
    fi
    printf 'domain %s' "$domain"
}

# _tgp_public_ip DOMAIN: the value for the state. When nothing was resolved this time
# (route/domain fallback) and the state has a value, that one is kept.
_tgp_public_ip() {
    local res src val old
    res="$(_tgp_resolve_public_ip "$1")" || die "$(t tgp.bad_public_ip "${TGPROXY_PUBLIC_IP:-}")"
    src="${res%% *}"
    val="${res#* }"
    old="$(_tgp_state_get PUBLIC_IP)"
    if [[ ( "$src" == route || "$src" == domain ) && -n "$old" ]]; then val="$old"; fi
    printf '%s' "$val"
}

# _tgp_shared_subnet PROJECT: IPv4 subnet of the project's default network (nginx/fakeapp service).
_tgp_shared_subnet() {
    local nid sn
    nid="$(docker network ls -q --filter "label=com.docker.compose.project=$1" --filter "label=com.docker.compose.network=default" | head -n1)"
    [[ -n "$nid" ]] || die "$(t tgp.no_project_net)"
    sn="$(docker network inspect "$nid" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}/[0-9]+$' | head -n1 || true)"
    [[ -n "$sn" ]] || die "$(t tgp.no_project_subnet)"
    printf '%s' "$sn"
}

_tgp_rand_path() { rand_str 20 'A-Za-z0-9'; }
_tgp_rand_secret() { rand_str 32 '0-9a-f'; }

_tgp_confirm() {
    local q=$1 ans
    if [[ "${ASSUME_YES:-0}" == 1 ]]; then return 0; fi
    if [[ ! -t 0 ]]; then return 0; fi
    read -r -p "$q $(t common.yn) " ans || return 1
    [[ "${ans,,}" == y || "${ans,,}" == yes || "${ans,,}" == д || "${ans,,}" == да ]]
}

# ext_telegram_web_proxy_result: lines of the final "result data" block (stdout).
ext_telegram_web_proxy_result() {
    _tgp_installed || return 0
    printf '%s\n' "$(t tgp.res_link "$(_tgp_cfg link)")"
}

_tgp_print_result() {
    local link outway domain
    domain="$(_tgp_current_domain)"
    link="$(_tgp_cfg link)"
    outway="$(_tgp_state_get OUTWAY)"
    printf '\n' >&2
    ok "$(t tgp.ready)"
    printf '    %s\n\n        %s\n\n' "$(t tgp.link_hint)" "$link" >&2
    info "$(t tgp.outway_info "$outway" "$TGP_SCRIPTS_DIR")"
    warn "$(t tgp.secret_warn)"
    info "$(t tgp.client_info)"
    if [[ "$domain" != "$(site_domain)" ]]; then
        if have_le_cert "$domain"; then
            info "$(t tgp.own_server_info "$domain")"
        else
            warn "$(t tgp.cert_missing "$domain" "$TGP_SCRIPTS_DIR")"
        fi
    fi
    info "$(t tgp.manage_info "$TGP_SCRIPTS_DIR")"
    [[ "$(nginx_https_port)" == 443 ]] || warn "$(t tgp.port_warn "$(nginx_https_port)")"
}

# --- actions -------------------------------------------------------------------------------------

_tgp_write_state() {
    local domain project
    domain="$(site_domain)"
    project="$(sed -n 's/^name:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "$APP_DIR/docker-compose.yml" | head -n1)"
    project="${project:-escape}"
    local net gw tip
    # Existing values (a reinstall after "remove" without --purge) are kept: same link.
    [[ -n "$(_tgp_state_get BASE_PATH)" ]] || _tgp_state_set BASE_PATH "$(_tgp_rand_path)"
    [[ -n "$(_tgp_state_get USER_SECRET)" ]] || _tgp_state_set USER_SECRET "$(_tgp_rand_secret)"
    if [[ -z "$(_tgp_state_get NET_SUBNET)" ]]; then
        read -r net gw tip < <(_tgp_subnet "${TGPROXY_SUBNET:-}") || die "$(t tgp.no_subnet)"
        [[ -n "$tip" ]] || die "$(t tgp.no_subnet)"
        _tgp_state_set NET_SUBNET "$net"
        _tgp_state_set NET_GATEWAY "$gw"
        _tgp_state_set TELEMT_IP "$tip"
    fi
    _tgp_state_set TGPROXY_STATE_VERSION 1
    _tgp_state_set APP_DIR "$APP_DIR"
    _tgp_state_set DOMAIN "$domain"
    _tgp_state_set TGPROXY_DOMAIN "${TGP_DOMAIN_CHOICE:-$domain}"
    _tgp_state_set PUBLIC_IP "$(_tgp_public_ip "${TGP_DOMAIN_CHOICE:-$domain}")"
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
    [[ "$ver" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "$(t tgp.bad_version "$ver")"
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
    # An outway that changed between IPv4 and IPv6 needs the network created again.
    _tgp_cfg net-check
    # shellcheck disable=SC2086
    ext_compose up -d --wait $recreate telemt || {
        ext_compose logs --tail 30 telemt >&2 || true
        die "$(t tgp.unhealthy)"
    }
    _tgp_cfg check-route
    _tgp_nginx_routes
}

# _tgp_nginx_routes: the nginx route of the proxy name. A separate name: its own
# server blocks (self-signed until Let's Encrypt has issued the certificate; a
# failure is not fatal, the renewal timer retries), the location in the server of
# the site goes away. The name of the site: the location, and no server blocks or
# certificate registration of this extension.
_tgp_nginx_routes() {
    local name
    name="$(_tgp_current_domain)"
    if [[ "$name" != "$(site_domain)" ]]; then
        ext_nginx_server_put "$TGP_ID" "$name" <"$TGP_DIR/nginx-server.conf"
        [[ ! -f "$NGINX_DATA/locations.d/$TGP_ID.conf" ]] || ext_nginx_location_rm "$TGP_ID"
        ext_cert_request "$TGP_ID" "$name" || warn "$(t tgp.cert_failed "$name")"
    else
        ext_nginx_location_put "$TGP_ID" <"$TGP_DIR/nginx-location.conf"
        ext_nginx_server_rm "$TGP_ID"
        ext_cert_release "$TGP_ID"
    fi
}

ext_telegram_web_proxy_do_install() {
    _tgp_preflight
    # The interface was chosen in the collect phase; iproute2 is installed by now.
    _tgp_outway check "$TGP_OUTWAY_CHOICE" || die "$(t tgp.invalid_outway "$TGP_OUTWAY_CHOICE")"
    TGP_SCRIPTS_DIR="$(_tgp_scripts_dir)"
    _tgp_state_set OUTWAY "$TGP_OUTWAY_CHOICE"
    _tgp_write_state
    _tgp_set_image "$(_tgp_state_get TELEMT_VERSION)"
    _tgp_install_scripts "$TGP_SCRIPTS_DIR"
    # Which address families the outway carries (IPv4, IPv6, both) and the IPv6 subnet.
    _tgp_cfg net-setup --redetect
    _tgp_bring_up
    date -u +%FT%TZ >"$TGP_MARKER"
    chmod 600 "$TGP_MARKER"
    _tgp_print_result
}

ext_telegram_web_proxy_do_update() {
    local rotate="$TGP_ROTATE" old_image new_image
    _tgp_preflight
    TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
    [[ -n "$TGP_SCRIPTS_DIR" && -x "$TGP_SCRIPTS_DIR/tgproxy-config.sh" ]] || TGP_SCRIPTS_DIR="$(_tgp_scripts_dir)"
    old_image="$(_tgp_state_get TELEMT_IMAGE)"
    if [[ -n "${TGPROXY_OUTWAY:-}" ]]; then
        _tgp_outway check "$TGP_OUTWAY_CHOICE" || die "$(t tgp.invalid_outway "$TGP_OUTWAY_CHOICE")"
        _tgp_state_set OUTWAY "$TGP_OUTWAY_CHOICE"
        _tgp_state_set OUTWAY_GW ""
        _tgp_state_set OUTWAY_GW6 ""
    fi
    # The proxy name (asked in the collect phase; an old installation gets it here).
    [[ -z "$TGP_DOMAIN_CHOICE" ]] || _tgp_state_set TGPROXY_DOMAIN "$TGP_DOMAIN_CHOICE"
    [[ -n "$(_tgp_state_get TGPROXY_DOMAIN)" ]] || _tgp_state_set TGPROXY_DOMAIN "$(site_domain)"
    _tgp_state_set DOMAIN "$(site_domain)"
    case "$rotate" in
        path | all) _tgp_state_set BASE_PATH "$(_tgp_rand_path)" ;;
    esac
    case "$rotate" in
        secret | all) _tgp_state_set USER_SECRET "$(_tgp_rand_secret)" ;;
    esac
    _tgp_set_image
    _tgp_state_set PUBLIC_IP "$(_tgp_public_ip "$(_tgp_current_domain)")"
    _tgp_state_set SHARED_SUBNET "$(_tgp_shared_subnet "$(_tgp_state_get COMPOSE_PROJECT)")"
    _tgp_install_scripts "$TGP_SCRIPTS_DIR"
    if [[ -n "${TGPROXY_OUTWAY:-}" ]]; then _tgp_cfg net-setup --redetect; else _tgp_cfg net-setup; fi
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
    ((!TGP_PURGE)) || purge=(--purge)
    TGPROXY_STATE="$TGP_STATE" bash "$script" --yes "${purge[@]}"
}

# ext_telegram_web_proxy_purge: hook of `install.sh remove --purge`: remove the proxy
# completely (container, outway rules, systemd units, sysctl.d file, nginx route,
# certificate of a separate name, config and secrets) while the stack still runs.
ext_telegram_web_proxy_purge() {
    ext_load_lang "$TGP_ID"
    _tgp_installed || return 0
    TGP_PURGE=1
    ext_telegram_web_proxy_do_remove
}

_tgp_do_outway() {
    TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
    _tgp_preflight
    _tgp_outway check "$TGP_OUTWAY_CHOICE" || die "$(t tgp.invalid_outway "$TGP_OUTWAY_CHOICE")"
    _tgp_cfg outway "$TGP_OUTWAY_CHOICE"
    ok "$(t tgp.outway_done "$TGP_OUTWAY_CHOICE")"
}

_tgp_do_rotate() {
    TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
    _tgp_cfg rotate "$TGP_ROTATE"
}

ext_telegram_web_proxy_menu() {
    local ans
    printf '\n%s\n' "$(t tgp.menu_head "$(_tgp_current_domain)" "$(_tgp_state_get OUTWAY)")" >&2
    [[ -n "$(_tgp_state_get TGPROXY_DOMAIN)" ]] || printf '%s\n' "$(t tgp.menu_old)" >&2
    printf '%s\n' "$(t tgp.menu_items)" >&2
    read -r -p "$(t tgp.menu_prompt)" ans || return 0
    case "$ans" in
        1) TGP_ACTION="update" ;;
        2) TGP_ACTION="remove" ;;
        3) TGP_ACTION="link" ;;
        4) TGP_ACTION="outway" ;;
        5) TGP_ACTION="rotate" ;;
        6) TGP_ACTION="status" ;;
        *) TGP_ACTION="cancel" ;;
    esac
}

# --- install phases --------------------------------------------------------------------------

# ext_telegram_web_proxy_collect: COLLECT. Decide the action (TGPROXY_ACTION, the menu,
# or the default) and ask everything it needs; the answers go to TGP_ACTION,
# TGP_DOMAIN_CHOICE, TGP_OUTWAY_CHOICE, TGP_ROTATE and TGP_PURGE. Changes nothing.
ext_telegram_web_proxy_collect() {
    ext_load_lang "$TGP_ID"
    local action="${TGPROXY_ACTION:-}" ans
    TGP_ACTION="" TGP_OUTWAY_CHOICE="" TGP_ROTATE="" TGP_PURGE=0 TGP_SCRIPTS_DIR="" TGP_DOMAIN_CHOICE=""
    if _tgp_installed; then
        TGP_SCRIPTS_DIR="$(_tgp_state_get SCRIPTS_DIR)"
        [[ -x "$TGP_SCRIPTS_DIR/tgproxy-config.sh" ]] || TGP_SCRIPTS_DIR=""
        if [[ -z "$action" ]]; then
            if _tgp_interactive; then
                ext_telegram_web_proxy_menu
                action="$TGP_ACTION"
            else
                action=update
            fi
        fi
        [[ "$action" != install ]] || action=update
    else
        [[ -n "$action" ]] || action=install
    fi
    TGP_ACTION="$action"
    case "$action" in
        install)
            _tgp_pick_domain "$(_tgp_state_get TGPROXY_DOMAIN)"
            _tgp_pick_outway "$(_tgp_state_get OUTWAY)"
            ;;
        update)
            _tgp_pick_domain "$(_tgp_current_domain)"
            TGP_ROTATE="${TGPROXY_ROTATE:-}"
            if [[ -z "$TGP_ROTATE" ]] && _tgp_interactive; then
                _tgp_confirm "$(t tgp.q_rotate_all)" && TGP_ROTATE=all
            fi
            [[ -z "${TGPROXY_OUTWAY:-}" ]] || _tgp_pick_outway "$(_tgp_state_get OUTWAY)"
            ;;
        remove)
            if [[ "${TGPROXY_PURGE:-0}" == 1 ]]; then
                TGP_PURGE=1
            elif _tgp_interactive && _tgp_confirm "$(t tgp.q_purge)"; then
                TGP_PURGE=1
            fi
            _tgp_confirm "$(t tgp.q_remove)" || die "$(t common.aborted)"
            ;;
        outway) _tgp_pick_outway "$(_tgp_state_get OUTWAY)" ;;
        rotate)
            TGP_ROTATE="${TGPROXY_ROTATE:-}"
            if [[ -z "$TGP_ROTATE" ]]; then
                if _tgp_interactive; then
                    read -r -p "$(t tgp.q_rotate)" ans || die "$(t common.no_input)"
                    TGP_ROTATE="${ans:-all}"
                else
                    problem "$(t tgp.set_rotate)"
                fi
            fi
            ;;
    esac
}

# ext_telegram_web_proxy_validate: VALIDATE. Read-only checks of the answers; works before
# docker, .env and iproute2 exist (a new install). Problems are recorded with `problem`.
ext_telegram_web_proxy_validate() {
    ext_load_lang "$TGP_ID"
    local domain ver out dir res
    case "$TGP_ACTION" in
        install | update | remove | link | outway | rotate | status | cancel) ;;
        *)
            problem "$(t tgp.unknown_action "$TGP_ACTION")"
            return 0
            ;;
    esac
    if ! _tgp_installed && [[ "$TGP_ACTION" != install ]]; then
        problem "$(t tgp.not_installed "$TGP_ACTION")"
        return 0
    fi
    case "$TGP_ACTION" in
        install | update | outway)
            domain="$(env_value DOMAIN)"
            # A new install reports a missing DOMAIN itself (core validation).
            [[ -n "$domain" ]] || ((ENV_NEW)) || problem "$(t tgp.no_domain "$APP_DIR/.env")"
            [[ "$APP_DIR" != *[[:space:]]* ]] || problem "$(t tgp.path_spaces "$APP_DIR")"
            if [[ -n "$TGP_OUTWAY_CHOICE" ]] && _tgp_have_ip; then
                if out="$(_tgp_outway check "$TGP_OUTWAY_CHOICE" 2>&1)"; then
                    out="$(_tgp_outway families "$TGP_OUTWAY_CHOICE" 2>/dev/null || true)"
                    info "$(t tgp.families_info "$TGP_OUTWAY_CHOICE" "$(_tgp_fams_name "$out")")"
                else
                    problem "$(t tgp.outway_problem "$TGP_OUTWAY_CHOICE" "${out#error: }")"
                fi
            fi
            ;;
    esac
    case "$TGP_ACTION" in
        install | update)
            ver="${TGPROXY_TELEMT_VERSION:-}"
            [[ -z "$ver" || "$ver" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || problem "$(t tgp.bad_version "$ver")"
            # The proxy name: the name of the site, or a separate one (own certificate).
            if [[ -n "$TGP_DOMAIN_CHOICE" ]]; then
                if ! valid_domain "$TGP_DOMAIN_CHOICE"; then
                    problem "$(t tgp.bad_domain "$TGP_DOMAIN_CHOICE")"
                elif [[ "$TGP_DOMAIN_CHOICE" != "${domain,,}" ]]; then
                    info "$(t tgp.domain_separate "$TGP_DOMAIN_CHOICE")"
                    check_domain_dns "$TGP_DOMAIN_CHOICE"
                    domain="$TGP_DOMAIN_CHOICE"
                else
                    info "$(t tgp.domain_same "$TGP_DOMAIN_CHOICE")"
                fi
            fi
            if valid_domain "$domain"; then
                if res="$(_tgp_resolve_public_ip "$domain")"; then
                    # A domain without an address is only a warning: the public_addr of
                    # telemt falls back (and the Let's Encrypt check warns about the DNS).
                    case "${res%% *}" in
                        route) warn "$(t tgp.public_fallback "$domain" "${res#* }")" ;;
                        domain) warn "$(t tgp.public_fallback_name "$domain" "${res#* }")" ;;
                    esac
                else
                    problem "$(t tgp.bad_public_ip "${TGPROXY_PUBLIC_IP:-}")"
                fi
            fi
            ;;
    esac
    if [[ "$TGP_ACTION" == install ]]; then
        dir="$(_tgp_scripts_dir)"
        [[ "$dir" != *[[:space:]]* ]] || problem "$(t tgp.dir_spaces "$dir")"
    fi
    case "$TGP_ROTATE" in
        "" | path | secret | all) ;;
        *) problem "$(t tgp.bad_rotate "$TGP_ROTATE")" ;;
    esac
    return 0
}

# ext_telegram_web_proxy_install: DEPLOY (the registered install function). Runs the
# action chosen in the collect phase; asks nothing.
ext_telegram_web_proxy_install() {
    ext_load_lang "$TGP_ID"
    local action="${TGP_ACTION:-}"
    [[ -n "$action" ]] || die "$(t tgp.no_collect)"
    case "$action" in
        install) ext_telegram_web_proxy_do_install ;;
        update) ext_telegram_web_proxy_do_update ;;
        remove) ext_telegram_web_proxy_do_remove ;;
        link) _tgp_cfg link ;;
        outway) _tgp_do_outway ;;
        rotate) _tgp_do_rotate ;;
        status) _tgp_cfg status ;;
        cancel) info "$(t tgp.nothing_done)" ;;
        *) die "$(t tgp.unknown_action "$action")" ;;
    esac
}
