#!/usr/bin/env bash
# tgproxy-outway.sh - outgoing-interface ("outway") policy routing for the
# TELEMT container of the telegram-web-proxy extension.
#
# Self-contained: needs bash, iproute2 and iptables (or nft); no repository,
# no network. Reads data/telegram-web-proxy/state.env. Only traffic whose source
# is the dedicated subnet of the telemt container is affected; other containers
# and the host keep their routes.
#
#   up         apply: routing table + ip rule + NAT + fail-closed firewall rules
#   block      keep the rule and the DROP, remove the way out (fail-closed stop)
#   down       remove everything this script created (the routes, rules, chains)
#   status     show what is applied and whether telemt traffic is blocked
#   list       list the candidate outgoing interfaces
#   check IF   validate the interface name; exit 0 when it can be an outway
#   install-unit | remove-unit   systemd service + timer (survive reboots)
#
# Environment: TGPROXY_STATE (state file), TGPROXY_DRY_RUN=1 (print the
# ip/iptables/nft commands instead of running them), TGPROXY_FW=iptables|nft,
# TGPROXY_DRY_ASSUME_UP=1 (dry run: pretend the outway is up, for tests).
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
STATE_FILE="${TGPROXY_STATE:-@STATE_FILE@}"
if [[ "$STATE_FILE" == "@STATE_FILE@" ]]; then
    # Running from the repository: extensions.d/telegram-web-proxy/ -> data/...
    STATE_FILE="$(dirname "$SELF")/../../data/telegram-web-proxy/state.env"
fi
DRY="${TGPROXY_DRY_RUN:-0}"
QUIET=0
CHAIN="TGPROXY-OUTWAY"
NFT_TABLE="tgproxy_outway"
UNIT="telegram-web-proxy-outway"
UNIT_DIR="${TGPROXY_UNIT_DIR:-/etc/systemd/system}"
ROUTE_STATE=""

say() { printf '%s\n' "$*" >&2; }
note() { ((QUIET)) || say "    $*"; }
warn() { say "warning: $*"; }
die() {
    say "error: $*"
    exit 1
}

# run CMD...: execute, or print in dry-run mode.
run() {
    if [[ "$DRY" == 1 ]]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}
# try CMD...: like run, a failure is not fatal.
try() { run "$@" 2>/dev/null || true; }

state_get() {
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1
}

valid_iface() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$ ]]; }
excluded_iface() { [[ "$1" == lo || "$1" == docker* || "$1" == br-* || "$1" == veth* || "$1" == virbr* ]]; }

# iface_names: interface names (no lo/docker*/br-*/veth*), one per line.
iface_names() {
    local n
    while read -r _ n _; do
        n="${n%:}"
        n="${n%%@*}"
        excluded_iface "$n" || printf '%s\n' "$n"
    done < <(ip -o link show)
}

iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }
iface_flags() { ip -o link show dev "$1" 2>/dev/null | sed -n 's/.*<\([^>]*\)>.*/\1/p'; }
iface_up() {
    local flags
    if [[ "$DRY" == 1 && "${TGPROXY_DRY_ASSUME_UP:-0}" == 1 ]]; then return 0; fi
    flags="$(iface_flags "$1")"
    [[ ",$flags," == *,UP,* && ",$flags," == *,LOWER_UP,* ]]
}
iface_ptp() {
    local flags
    flags="$(iface_flags "$1")"
    [[ ",$flags," == *,POINTOPOINT,* || "$1" == tun* || "$1" == wg* || "$1" == ppp* || "$1" == tailscale* ]]
}

cmd_list() {
    local n def addr st
    printf '%-14s %-6s %-20s %s\n' INTERFACE STATE ADDRESS ROUTE >&2
    while read -r n; do
        st=DOWN
        iface_up "$n" && st=UP
        addr="$(ip -o -4 addr show dev "$n" 2>/dev/null | awk '{print $4; exit}')"
        def="$(ip -4 route show default dev "$n" 2>/dev/null | head -n1)"
        printf '%-14s %-6s %-20s %s\n' "$n" "$st" "${addr:--}" "${def:+main default route of the host}" >&2
    done < <(iface_names)
}

cmd_check() {
    local n=${1:-}
    valid_iface "$n" || die "bad interface name '$n'"
    ! excluded_iface "$n" || die "'$n' cannot be an outway (lo, docker*, br-*, veth*, virbr* are excluded)"
    iface_exists "$n" || die "interface '$n' does not exist (see: $0 list)"
}

# --- state ----------------------------------------------------------------------------

OUTWAY="" SUBNET="" TABLE="" PRIO="" GW_OVERRIDE=""
load_state() {
    [[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE"
    OUTWAY="$(state_get OUTWAY)"
    SUBNET="$(state_get NET_SUBNET)"
    TABLE="$(state_get ROUTE_TABLE)"
    PRIO="$(state_get RULE_PRIO)"
    GW_OVERRIDE="$(state_get OUTWAY_GW)"
    TABLE="${TABLE:-7791}"
    PRIO="${PRIO:-7791}"
    [[ "$SUBNET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "NET_SUBNET missing or invalid in $STATE_FILE"
    [[ "$TABLE" =~ ^[0-9]+$ && "$PRIO" =~ ^[0-9]+$ ]] || die "ROUTE_TABLE/RULE_PRIO invalid in $STATE_FILE"
    valid_iface "$OUTWAY" || die "OUTWAY missing or invalid in $STATE_FILE"
}

fw_backend() {
    local b="${TGPROXY_FW:-}"
    [[ -n "$b" ]] || b="$(state_get FW_BACKEND)"
    if [[ -z "$b" || "$b" == auto ]]; then
        if command -v iptables >/dev/null 2>&1; then
            b=iptables
        elif command -v nft >/dev/null 2>&1; then
            b=nft
        else
            die "neither iptables nor nft found"
        fi
    fi
    [[ "$b" == iptables || "$b" == nft ]] || die "bad firewall backend '$b'"
    printf '%s' "$b"
}

# --- routing -----------------------------------------------------------------------

outway_usable() {
    if [[ "$DRY" == 1 && "${TGPROXY_DRY_ASSUME_UP:-0}" == 1 ]]; then return 0; fi
    iface_exists "$OUTWAY" && iface_up "$OUTWAY"
}

# apply_routes MODE: MODE up = default via the outway, block = unreachable only.
apply_routes() {
    local mode=$1 line gw="" onlink=""
    # Fail-closed fallback: when the outway route is missing, the lookup in this
    # table ends in "unreachable" and never falls through to the main table.
    run ip route replace unreachable default metric 4096 table "$TABLE"
    if [[ "$mode" == up ]] && outway_usable; then
        if [[ -n "$GW_OVERRIDE" ]]; then
            [[ "$GW_OVERRIDE" == - ]] || gw="$GW_OVERRIDE"
        elif ! iface_ptp "$OUTWAY"; then
            line="$(ip -4 route show default dev "$OUTWAY" 2>/dev/null | head -n1 || true)"
            if [[ "$line" =~ via[[:space:]]+([0-9.]+) ]]; then
                gw="${BASH_REMATCH[1]}"
                [[ "$line" == *onlink* ]] && onlink=onlink
            else
                note "no default gateway found for $OUTWAY: using 'default dev $OUTWAY' (set OUTWAY_GW in $STATE_FILE if needed)"
            fi
        fi
        if [[ -n "$gw" ]]; then
            # shellcheck disable=SC2086
            run ip route replace default via "$gw" dev "$OUTWAY" ${onlink:+$onlink} metric 100 table "$TABLE"
        else
            run ip route replace default dev "$OUTWAY" metric 100 table "$TABLE"
        fi
        ROUTE_STATE="up"
    else
        try ip route del default metric 100 table "$TABLE"
        if [[ "$mode" == up ]]; then
            ROUTE_STATE="down"
            warn "outway '$OUTWAY' is down or missing: telemt traffic is blocked (fail-closed) until it is back"
        else
            ROUTE_STATE="blocked"
        fi
    fi
    if [[ "$DRY" == 1 ]]; then
        printf '+ ip rule add from %s lookup %s priority %s   # skipped when already present\n' "$SUBNET" "$TABLE" "$PRIO"
    elif ! ip rule show | grep -Eq "^${PRIO}:[[:space:]]+from ${SUBNET//./\\.} lookup ${TABLE}\$"; then
        ip rule add from "$SUBNET" lookup "$TABLE" priority "$PRIO"
    fi
}

remove_routes() {
    if [[ "$DRY" == 1 ]]; then
        printf '+ ip rule del from %s lookup %s priority %s\n' "$SUBNET" "$TABLE" "$PRIO"
    else
        while ip rule del from "$SUBNET" lookup "$TABLE" priority "$PRIO" 2>/dev/null; do :; done
    fi
    try ip route flush table "$TABLE"
}

# --- firewall: iptables ----------------------------------------------------------------

# ipt_ensure_jump TABLE PARENT ARGS...: insert "-j CHAIN" in PARENT unless present.
ipt_ensure_jump() {
    local t=$1 parent=$2
    shift 2
    if [[ "$DRY" == 1 ]]; then
        printf '+ iptables -t %s -I %s 1 %s -j %s   # skipped when already present\n' "$t" "$parent" "$*" "$CHAIN"
    elif ! iptables -t "$t" -C "$parent" "$@" -j "$CHAIN" 2>/dev/null; then
        iptables -t "$t" -I "$parent" 1 "$@" -j "$CHAIN"
    fi
}

ipt_filter_parent() {
    if [[ "$DRY" == 1 ]] || iptables -t filter -S DOCKER-USER >/dev/null 2>&1; then
        printf 'DOCKER-USER'
    else
        printf 'FORWARD'
    fi
}

ipt_apply() {
    local mode=$1 parent
    parent="$(ipt_filter_parent)"
    # nat: MASQUERADE out of the outway only
    try iptables -t nat -N "$CHAIN"
    run iptables -t nat -F "$CHAIN"
    run iptables -t nat -A "$CHAIN" -s "$SUBNET" -o "$OUTWAY" -m comment --comment tgproxy-outway -j MASQUERADE
    ipt_ensure_jump nat POSTROUTING -s "$SUBNET"
    # filter: nothing from the subnet may leave through any other interface
    try iptables -t filter -N "$CHAIN"
    run iptables -t filter -F "$CHAIN"
    if [[ "$mode" == up ]]; then
        run iptables -t filter -A "$CHAIN" -s "$SUBNET" ! -o "$OUTWAY" -m comment --comment tgproxy-outway -j DROP
    else
        run iptables -t filter -A "$CHAIN" -s "$SUBNET" -m comment --comment tgproxy-outway -j DROP
    fi
    ipt_ensure_jump filter "$parent" -s "$SUBNET"
}

ipt_remove() {
    local parent
    for parent in DOCKER-USER FORWARD; do
        if [[ "$DRY" == 1 ]]; then
            printf '+ iptables -t filter -D %s -s %s -j %s\n' "$parent" "$SUBNET" "$CHAIN"
        else
            while iptables -t filter -D "$parent" -s "$SUBNET" -j "$CHAIN" 2>/dev/null; do :; done
        fi
    done
    if [[ "$DRY" == 1 ]]; then
        printf '+ iptables -t nat -D POSTROUTING -s %s -j %s\n' "$SUBNET" "$CHAIN"
    else
        while iptables -t nat -D POSTROUTING -s "$SUBNET" -j "$CHAIN" 2>/dev/null; do :; done
    fi
    try iptables -t filter -F "$CHAIN"
    try iptables -t filter -X "$CHAIN"
    try iptables -t nat -F "$CHAIN"
    try iptables -t nat -X "$CHAIN"
}

# --- firewall: nft (hosts without iptables) -------------------------------------------------

nft_apply() {
    local mode=$1 drop rules
    if [[ "$mode" == up ]]; then
        drop="ip saddr $SUBNET oifname != \"$OUTWAY\" counter drop comment \"tgproxy-outway\""
    else
        drop="ip saddr $SUBNET counter drop comment \"tgproxy-outway\""
    fi
    rules="add table ip $NFT_TABLE
delete table ip $NFT_TABLE
table ip $NFT_TABLE {
    chain post {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $SUBNET oifname \"$OUTWAY\" counter masquerade comment \"tgproxy-outway\"
    }
    chain fwd {
        type filter hook forward priority -10; policy accept;
        $drop
    }
}"
    if [[ "$DRY" == 1 ]]; then
        printf '+ nft -f - <<EOF\n%s\nEOF\n' "$rules"
    else
        nft -f - <<<"$rules"
    fi
}
nft_remove() { try nft delete table ip "$NFT_TABLE"; }

fw_apply() { if [[ "$(fw_backend)" == iptables ]]; then ipt_apply "$1"; else nft_apply "$1"; fi; }
fw_remove() { if [[ "$(fw_backend)" == iptables ]]; then ipt_remove; else nft_remove; fi; }

# --- rp_filter hint ----------------------------------------------------------------------

check_rp_filter() {
    local all dev
    [[ "$DRY" == 1 ]] && return 0
    all="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)"
    dev="$(sysctl -n "net.ipv4.conf.${OUTWAY//./\/}.rp_filter" 2>/dev/null || echo 0)"
    if ((all == 1 || dev == 1)); then
        warn "strict reverse-path filtering (rp_filter=1) may drop replies arriving on $OUTWAY; if telemt cannot connect, set net.ipv4.conf.all.rp_filter=2 and net.ipv4.conf.$OUTWAY.rp_filter=2"
    fi
}

# --- commands ---------------------------------------------------------------------------------

cmd_up() {
    load_state
    apply_routes up
    fw_apply up
    check_rp_filter
    note "outway $OUTWAY applied for $SUBNET (table $TABLE, $(fw_backend)): $ROUTE_STATE"
}

cmd_block() {
    load_state
    apply_routes block
    fw_apply block
    note "telemt traffic from $SUBNET is blocked (fail-closed)"
}

cmd_down() {
    load_state
    fw_remove
    remove_routes
    note "outway rules for $SUBNET removed"
}

cmd_status() {
    local st=ok route
    load_state
    printf 'outway     : %s (%s)\n' "$OUTWAY" "$(if iface_exists "$OUTWAY"; then iface_up "$OUTWAY" && echo up || echo DOWN; else echo MISSING; fi)"
    printf 'subnet     : %s, table %s, rule priority %s, firewall %s\n' "$SUBNET" "$TABLE" "$PRIO" "$(fw_backend)"
    if ip rule show | grep -Eq "from ${SUBNET//./\\.} lookup ${TABLE}\$"; then
        printf 'ip rule    : present\n'
    else
        printf 'ip rule    : MISSING (telemt traffic is NOT policy-routed)\n'
        st=bad
    fi
    route="$(ip -4 route show table "$TABLE" 2>/dev/null || true)"
    printf 'table %s:\n' "$TABLE"
    # shellcheck disable=SC2001
    [[ -z "$route" ]] || sed 's/^/    /' <<<"$route"
    if ! grep -Eq "^default .*dev ${OUTWAY//./\\.}( |\$)" <<<"$route"; then
        printf 'state      : BLOCKED (fail-closed): no route via %s, telemt traffic is dropped\n' "$OUTWAY"
        st=blocked
    fi
    if [[ "$(fw_backend)" == iptables ]]; then
        iptables -t filter -S "$CHAIN" >/dev/null 2>&1 || { printf 'firewall   : filter chain %s MISSING\n' "$CHAIN"; st=bad; }
        iptables -t nat -S "$CHAIN" >/dev/null 2>&1 || { printf 'firewall   : nat chain %s MISSING\n' "$CHAIN"; st=bad; }
    else
        nft list table ip "$NFT_TABLE" >/dev/null 2>&1 || { printf 'firewall   : nft table %s MISSING\n' "$NFT_TABLE"; st=bad; }
    fi
    [[ "$st" != ok ]] || printf 'state      : OK, telemt egress goes out through %s\n' "$OUTWAY"
    if systemctl is-enabled "$UNIT.service" >/dev/null 2>&1; then
        printf 'systemd    : %s.service enabled\n' "$UNIT"
    else
        printf 'systemd    : %s.service not enabled\n' "$UNIT"
    fi
    [[ "$st" == ok ]]
}

systemd_running() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

cmd_install_unit() {
    local exec_self="$SELF"
    [[ "$exec_self" != *[[:space:]]* ]] || die "path with spaces is not supported in the unit: $exec_self"
    if [[ "$DRY" == 1 ]]; then
        printf '+ write %s/%s.service, %s-check.service and %s.timer; systemctl daemon-reload; systemctl enable %s.service %s.timer\n' \
            "$UNIT_DIR" "$UNIT" "$UNIT" "$UNIT" "$UNIT" "$UNIT"
        return 0
    fi
    if ! systemd_running; then
        warn "systemd is not running: the outway rules are not persisted across reboots (run '$SELF up' after boot)"
        return 0
    fi
    cat >"$UNIT_DIR/$UNIT.service" <<UNIT_EOF
[Unit]
Description=Telegram web proxy: outgoing interface (policy routing) of the telemt container
After=docker.service network-online.target
Wants=network-online.target
ConditionPathExists=$STATE_FILE

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$exec_self up
ExecReload=$exec_self up
# Stopping keeps the traffic of the container blocked instead of leaking it.
ExecStop=$exec_self block

[Install]
WantedBy=multi-user.target
UNIT_EOF
    cat >"$UNIT_DIR/$UNIT-check.service" <<UNIT_EOF
[Unit]
Description=Telegram web proxy: re-apply the outway rules (VPN restarts, interface flaps)
After=$UNIT.service
ConditionPathExists=$STATE_FILE

[Service]
Type=oneshot
ExecStart=$exec_self --quiet up
UNIT_EOF
    cat >"$UNIT_DIR/$UNIT.timer" <<UNIT_EOF
[Unit]
Description=Telegram web proxy: periodic outway check

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
Unit=$UNIT-check.service

[Install]
WantedBy=timers.target
UNIT_EOF
    chmod 644 "$UNIT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT-check.service" "$UNIT_DIR/$UNIT.timer"
    systemctl daemon-reload
    systemctl enable "$UNIT.service" "$UNIT.timer" >/dev/null 2>&1
    systemctl start "$UNIT.timer" || true
    note "systemd units installed: $UNIT.service (runs '$exec_self up' at boot) and $UNIT.timer"
}

cmd_remove_unit() {
    if [[ "$DRY" == 1 ]]; then
        printf '+ systemctl disable --now %s.timer; systemctl disable %s.service; delete the unit files in %s; systemctl daemon-reload\n' "$UNIT" "$UNIT" "$UNIT_DIR"
        return 0
    fi
    if systemd_running; then
        systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
        systemctl disable "$UNIT.service" >/dev/null 2>&1 || true
        # ExecStop runs "block"; the caller removes the rules with "down" next.
        systemctl stop "$UNIT.service" >/dev/null 2>&1 || true
    fi
    rm -f "${UNIT_DIR:?}/${UNIT:?}.service" "${UNIT_DIR:?}/${UNIT:?}-check.service" "${UNIT_DIR:?}/${UNIT:?}.timer"
    if systemd_running; then
        systemctl daemon-reload || true
        systemctl reset-failed "$UNIT.service" "$UNIT-check.service" >/dev/null 2>&1 || true
    fi
    note "systemd units removed"
}

main() {
    local cmd=""
    while (($#)); do
        case "$1" in
            --quiet) QUIET=1 ;;
            --dry-run) DRY=1 ;;
            -h | --help | help)
                sed -n '2,/^set -E/p' "$SELF" | sed '$d; s/^# \{0,1\}//'
                exit 0
                ;;
            *)
                cmd="$1"
                shift
                break
                ;;
        esac
        shift
    done
    [[ -n "$cmd" ]] || die "usage: $0 [--quiet] [--dry-run] up|block|down|status|list|check IF|install-unit|remove-unit"
    if [[ "$DRY" != 1 ]]; then
        case "$cmd" in
            up | block | down | install-unit | remove-unit) ((EUID == 0)) || die "'$cmd' must run as root" ;;
        esac
    fi
    case "$cmd" in
        up) cmd_up ;;
        block) cmd_block ;;
        down) cmd_down ;;
        status) cmd_status ;;
        list) cmd_list ;;
        check) cmd_check "${1:-}" ;;
        install-unit) cmd_install_unit ;;
        remove-unit) cmd_remove_unit ;;
        *) die "unknown command '$cmd'" ;;
    esac
}
main "$@"
