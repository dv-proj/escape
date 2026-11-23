#!/usr/bin/env bash
# tgproxy-outway.sh - outgoing-interface ("outway") policy routing for the
# container of an extension: TELEMT of telegram-web-proxy (this file), and,
# installed as a renamed copy (xray-outway.sh), 3x-ui of xray-3xui.
#
# Self-contained: needs bash, iproute2 and iptables (or nft); no repository,
# no network. Reads the state file of the extension (data/telegram-web-proxy/
# state.env here). Only traffic whose source is the dedicated subnet of the
# container is affected; other containers and the host keep their routes.
#
# Everything it creates is named by the state file, so that several extensions
# can each have their own outway side by side (defaults: the telemt names, which
# older state files rely on):
#   ROUTE_TABLE / RULE_PRIO (7791)      OUTWAY_CHAIN (TGPROXY-OUTWAY, iptables chains)
#   OUTWAY_NFT_TABLE (tgproxy_outway)   OUTWAY_UNIT (telegram-web-proxy-outway, systemd)
#   OUTWAY_SYSCTL_NAME (90-telegram-web-proxy.conf)  OUTWAY_COMMENT (tgproxy-outway)
#   OUTWAY_LABEL (telemt, in messages)  OUTWAY_TITLE (Telegram web proxy, unit descriptions)
#
#   up         apply: routing table + ip rule + NAT + fail-closed firewall rules,
#              per address family (IPv4, IPv6 or both; see OUTWAY_FAMILIES below)
#   block      keep the rules and the DROP, remove the way out (fail-closed stop)
#   down       remove everything this script created (the routes, rules, chains,
#              the sysctl.d file)
#   status     show what is applied and whether the container traffic is blocked
#   list       numbered list of the candidate outgoing interfaces
#   names      the candidate interface names, one per line (same order as `list`)
#   resolve X  interface number (from `list`) or name -> name; exit 1 when invalid
#   check IF   validate the interface; exit 0 when it can be an outway
#   families IF  address families the interface can carry: 4, 6 or 46
#   install-unit | remove-unit   systemd service + timer (survive reboots)
#
# An outway may carry only IPv4, only IPv6 or both (a tunnel may have no IPv4 at
# all). The family set is detected from the global-scope addresses and the routes
# of the interface and stored as OUTWAY_FAMILIES in the state file. The
# container network has a ULA IPv6 subnet (NET_SUBNET6) when IPv6 is used. A
# family the outway does not carry is blocked for the container (fail closed).
#
# Environment: TGPROXY_STATE (state file), TGPROXY_DRY_RUN=1 (print the
# ip/iptables/ip6tables/nft/sysctl commands instead of running them),
# TGPROXY_FW=iptables|nft, TGPROXY_DRY_ASSUME_UP=1 (dry run: pretend the outway
# is up, for tests), TGPROXY_OUTWAY_FAMILIES=4|6|46 (override the detection),
# TGPROXY_SYSCTL_DIR (default /etc/sysctl.d).
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
STATE_FILE="${TGPROXY_STATE:-@STATE_FILE@}"
if [[ "$STATE_FILE" == "@STATE_FILE@" ]]; then
    # Running from the repository: extensions.d/telegram-web-proxy/ -> data/...
    STATE_FILE="$(dirname "$SELF")/../../data/telegram-web-proxy/state.env"
fi
DRY="${TGPROXY_DRY_RUN:-0}"
QUIET=0
# Names (see the header); load_names replaces them with the values of the state file.
CHAIN="TGPROXY-OUTWAY"
NFT_TABLE="tgproxy_outway"
UNIT="telegram-web-proxy-outway"
UNIT_DIR="${TGPROXY_UNIT_DIR:-/etc/systemd/system}"
SYSCTL_DIR="${TGPROXY_SYSCTL_DIR:-/etc/sysctl.d}"
SYSCTL_FILE="$SYSCTL_DIR/90-telegram-web-proxy.conf"
COMMENT="tgproxy-outway"
LABEL="telemt"
TITLE="Telegram web proxy"
ROUTE_STATE_4="" ROUTE_STATE_6=""
WARNED_DOWN=0

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

# load_names: the names of the state file (when it exists), validated.
load_names() {
    local v
    [[ -f "$STATE_FILE" ]] || return 0
    v="$(state_get OUTWAY_CHAIN)"
    if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[A-Z][A-Z0-9_-]{0,23}$ ]] || die "OUTWAY_CHAIN invalid in $STATE_FILE"
        CHAIN="$v"
    fi
    v="$(state_get OUTWAY_NFT_TABLE)"
    if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || die "OUTWAY_NFT_TABLE invalid in $STATE_FILE"
        NFT_TABLE="$v"
    fi
    v="$(state_get OUTWAY_UNIT)"
    if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || die "OUTWAY_UNIT invalid in $STATE_FILE"
        UNIT="$v"
    fi
    v="$(state_get OUTWAY_SYSCTL_NAME)"
    if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]{2}-[a-z0-9-]+\.conf$ ]] || die "OUTWAY_SYSCTL_NAME invalid in $STATE_FILE"
        SYSCTL_FILE="$SYSCTL_DIR/$v"
    fi
    v="$(state_get OUTWAY_COMMENT)"
    if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "OUTWAY_COMMENT invalid in $STATE_FILE"
        COMMENT="$v"
    fi
    v="$(state_get OUTWAY_LABEL)"
    if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || die "OUTWAY_LABEL invalid in $STATE_FILE"
        LABEL="$v"
    fi
    v="$(state_get OUTWAY_TITLE)"
    if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._()+-]{0,63}$ ]] || die "OUTWAY_TITLE invalid in $STATE_FILE"
        TITLE="$v"
    fi
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
iface_oper() { ip -o link show dev "$1" 2>/dev/null | sed -n 's/.* state \([A-Z-]*\).*/\1/p' | head -n1; }
# iface_up IF: administratively up, with a carrier. Tunnels (tun, wg, ppp, ...)
# report operstate UNKNOWN: that counts as up.
iface_up() {
    local flags oper
    if [[ "$DRY" == 1 && "${TGPROXY_DRY_ASSUME_UP:-0}" == 1 ]]; then return 0; fi
    flags="$(iface_flags "$1")"
    [[ ",$flags," == *,UP,* && ",$flags," != *,NO-CARRIER,* ]] || return 1
    [[ ",$flags," == *,LOWER_UP,* ]] && return 0
    oper="$(iface_oper "$1")"
    [[ "$oper" == UP || "$oper" == UNKNOWN ]]
}
iface_ptp() {
    local flags
    flags="$(iface_flags "$1")"
    [[ ",$flags," == *,POINTOPOINT,* || "$1" == tun* || "$1" == wg* || "$1" == ppp* || "$1" == tailscale* ]]
}

# iface_addrs FAMILY IF: global-scope addresses (a point-to-point "peer" is skipped).
iface_addrs() {
    ip -o "-$1" addr show dev "$2" scope global 2>/dev/null |
        awk '{for (i = 1; i < NF; i++) if ($i == "inet" || $i == "inet6") {print $(i + 1); break}}' || true
}
# iface_routes FAMILY IF: routes through the device, without link-local noise.
iface_routes() {
    ip "-$1" route show dev "$2" 2>/dev/null | grep -Ev '^(fe80:|ff00:|169\.254\.)' || true
}
# iface_families IF: "4", "6", "46" or "" (global addresses, or else routes: a tunnel
# without an address still carries a family when it has routes).
iface_families() {
    local f out=""
    for f in 4 6; do
        if [[ -n "$(iface_addrs "$f" "$1")" || -n "$(iface_routes "$f" "$1")" ]]; then out+=$f; fi
    done
    printf '%s' "$out"
}
# families_of IF: the detection, or TGPROXY_OUTWAY_FAMILIES when set.
families_of() {
    local o="${TGPROXY_OUTWAY_FAMILIES:-}"
    if [[ -n "$o" ]]; then
        [[ "$o" =~ ^(4|6|46)$ ]] || die "bad TGPROXY_OUTWAY_FAMILIES '$o' (4, 6 or 46)"
        printf '%s' "$o"
    else
        iface_families "$1"
    fi
}
fams_name() {
    case "$1" in 46) printf 'IPv4+IPv6' ;; 6) printf 'IPv6 only' ;; 4) printf 'IPv4 only' ;; *) printf 'none' ;; esac
}

# iface_default_note IF: which families have the host's main default route on IF.
iface_default_note() {
    local d4 d6
    d4="$(ip -4 route show default dev "$1" 2>/dev/null | head -n1 || true)"
    d6="$(ip -6 route show default dev "$1" 2>/dev/null | head -n1 || true)"
    if [[ -n "$d4" && -n "$d6" ]]; then
        printf 'main default route of the host (IPv4+IPv6)'
    elif [[ -n "$d4" ]]; then
        printf 'main default route of the host (IPv4)'
    elif [[ -n "$d6" ]]; then
        printf 'main default route of the host (IPv6)'
    fi
}

cmd_list() {
    local n i=0 addr st
    printf '%-4s %-14s %-6s %-44s %s\n' '#' INTERFACE STATE ADDRESS ROUTE >&2
    while read -r n; do
        i=$((i + 1))
        st=DOWN
        iface_up "$n" && st=UP
        addr="$({ iface_addrs 4 "$n"; iface_addrs 6 "$n"; } | paste -sd, -)"
        printf '%-4s %-14s %-6s %-44s %s\n' "$i)" "$n" "$st" "${addr:--}" "$(iface_default_note "$n")" >&2
    done < <(iface_names)
}

# cmd_resolve ANSWER: a number from `list` or an interface name -> the name.
cmd_resolve() {
    local a=${1:-} name
    if [[ "$a" =~ ^[0-9]+$ ]]; then
        [[ "$a" =~ ^[1-9][0-9]*$ ]] || die "no interface number $a in the list"
        name="$(iface_names | sed -n "${a}p")"
        [[ -n "$name" ]] || die "no interface number $a in the list"
        printf '%s\n' "$name"
    else
        valid_iface "$a" || die "bad interface name '$a'"
        printf '%s\n' "$a"
    fi
}

cmd_check() {
    local n=${1:-} fams
    valid_iface "$n" || die "bad interface name '$n'"
    ! excluded_iface "$n" || die "'$n' cannot be an outway (lo, docker*, br-*, veth*, virbr* are excluded)"
    iface_exists "$n" || die "interface '$n' does not exist (see: $0 list)"
    fams="$(families_of "$n")"
    [[ -n "$fams" ]] || die "'$n' has no global IPv4/IPv6 address and no route: configure it first (or set TGPROXY_OUTWAY_FAMILIES=4|6|46 when it gets them later)"
}

cmd_families() {
    local n=${1:-} fams
    cmd_check "$n"
    fams="$(families_of "$n")"
    printf '%s\n' "$fams"
}

# --- state ----------------------------------------------------------------------------

OUTWAY="" SUBNET="" SUBNET6="" TABLE="" PRIO="" GW_OVERRIDE="" GW6_OVERRIDE="" FAMILIES=""
load_state() {
    [[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE"
    OUTWAY="$(state_get OUTWAY)"
    SUBNET="$(state_get NET_SUBNET)"
    SUBNET6="$(state_get NET_SUBNET6)"
    TABLE="$(state_get ROUTE_TABLE)"
    PRIO="$(state_get RULE_PRIO)"
    GW_OVERRIDE="$(state_get OUTWAY_GW)"
    GW6_OVERRIDE="$(state_get OUTWAY_GW6)"
    FAMILIES="$(state_get OUTWAY_FAMILIES)"
    TABLE="${TABLE:-7791}"
    PRIO="${PRIO:-7791}"
    [[ "$SUBNET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "NET_SUBNET missing or invalid in $STATE_FILE"
    [[ -z "$SUBNET6" || "$SUBNET6" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] || die "NET_SUBNET6 invalid in $STATE_FILE"
    [[ "$TABLE" =~ ^[0-9]+$ && "$PRIO" =~ ^[0-9]+$ ]] || die "ROUTE_TABLE/RULE_PRIO invalid in $STATE_FILE"
    valid_iface "$OUTWAY" || die "OUTWAY missing or invalid in $STATE_FILE"
    if [[ -z "$FAMILIES" ]]; then
        # An installation without the setting (older version): the outway is IPv4.
        FAMILIES=4
    fi
    [[ "$FAMILIES" =~ ^(4|6|46)$ ]] || die "OUTWAY_FAMILIES invalid in $STATE_FILE (4, 6 or 46)"
}

# egress FAMILY: 1 when the container's family-FAMILY traffic may leave through the outway.
egress() {
    if [[ "$FAMILIES" == *"$1"* ]] && { [[ "$1" == 4 ]] || [[ -n "$SUBNET6" ]]; }; then printf 1; else printf 0; fi
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
    if [[ "$b" == iptables && -n "$SUBNET6" && "$DRY" != 1 ]] && ! command -v ip6tables >/dev/null 2>&1; then
        die "IPv6 is used but ip6tables is not installed (install it, or set TGPROXY_FW=nft)"
    fi
    printf '%s' "$b"
}

# --- routing -----------------------------------------------------------------------

outway_usable() {
    if [[ "$DRY" == 1 && "${TGPROXY_DRY_ASSUME_UP:-0}" == 1 ]]; then return 0; fi
    iface_exists "$OUTWAY" && iface_up "$OUTWAY"
}

# rule_present FAMILY SUBNET
rule_present() {
    ip "-$1" rule show | grep -Eq "^${PRIO}:[[:space:]]+from ${2//./\\.} lookup ${TABLE}([[:space:]]|\$)"
}

# apply_routes_family FAMILY SUBNET EGRESS MODE: in the dedicated table, default via the
# outway (MODE up and the outway carries FAMILY), else only "unreachable".
apply_routes_family() {
    local f=$1 subnet=$2 eg=$3 mode=$4 line gw="" onlink="" over st
    # Fail-closed fallback: when the outway route is missing, the lookup in this
    # table ends in "unreachable" and never falls through to the main table.
    run ip "-$f" route replace unreachable default metric 4096 table "$TABLE"
    if [[ "$mode" == up && "$eg" == 1 ]] && outway_usable; then
        over="$GW_OVERRIDE"
        [[ "$f" == 4 ]] || over="$GW6_OVERRIDE"
        if [[ -n "$over" ]]; then
            [[ "$over" == - ]] || gw="$over"
        elif ! iface_ptp "$OUTWAY"; then
            line="$(ip "-$f" route show default dev "$OUTWAY" 2>/dev/null | head -n1 || true)"
            if [[ "$line" =~ via[[:space:]]+([0-9a-fA-F.:]+) ]]; then
                gw="${BASH_REMATCH[1]}"
                [[ "$line" == *onlink* ]] && onlink=onlink
            else
                note "no IPv$f default gateway found for $OUTWAY: using 'default dev $OUTWAY' (set OUTWAY_GW$([[ "$f" == 6 ]] && printf 6) in $STATE_FILE if needed)"
            fi
        fi
        if [[ -n "$gw" ]]; then
            # shellcheck disable=SC2086
            run ip "-$f" route replace default via "$gw" dev "$OUTWAY" ${onlink:+$onlink} metric 100 table "$TABLE"
        else
            run ip "-$f" route replace default dev "$OUTWAY" metric 100 table "$TABLE"
        fi
        st="up"
    else
        try ip "-$f" route del default metric 100 table "$TABLE"
        if [[ "$mode" != up ]]; then
            st="blocked"
        elif [[ "$eg" != 1 ]]; then
            st="blocked (the outway has no IPv$f)"
        else
            st="down"
            if ((!WARNED_DOWN)); then
                WARNED_DOWN=1
                warn "outway '$OUTWAY' is down or missing: $LABEL traffic is blocked (fail-closed) until it is back"
            fi
        fi
    fi
    if [[ "$DRY" == 1 ]]; then
        printf '+ ip -%s rule add from %s lookup %s priority %s   # skipped when already present\n' "$f" "$subnet" "$TABLE" "$PRIO"
    elif ! rule_present "$f" "$subnet"; then
        # A rule of an older setting (e.g. with iif) goes first.
        while ip "-$f" rule del from "$subnet" lookup "$TABLE" priority "$PRIO" 2>/dev/null; do :; done
        ip "-$f" rule add from "$subnet" lookup "$TABLE" priority "$PRIO"
    fi
    if [[ "$f" == 4 ]]; then ROUTE_STATE_4="$st"; else ROUTE_STATE_6="$st"; fi
}

# purge_legacy_reply FAMILY SUBNET: the fwmark rule that an earlier version added for
# a published port ("from SUBNET fwmark MARK lookup main" at RULE_PRIO - 100).
purge_legacy_reply() {
    local prio=$((PRIO > 100 ? PRIO - 100 : 1))
    [[ "$DRY" != 1 && -n "$2" ]] || return 0
    ip "-$1" rule show 2>/dev/null | grep -Eq "^${prio}:[[:space:]]+from ${2//./\\.} fwmark .* lookup main" || return 0
    while ip "-$1" rule del priority "$prio" lookup main 2>/dev/null; do :; done
}

# apply_routes MODE: up = default via the outway, block = unreachable only.
apply_routes() {
    apply_routes_family 4 "$SUBNET" "$(egress 4)" "$1"
    if [[ -n "$SUBNET6" ]]; then apply_routes_family 6 "$SUBNET6" "$(egress 6)" "$1"; fi
}

remove_routes() {
    local f subnet
    for f in 4 6; do
        subnet="$SUBNET"
        [[ "$f" == 4 ]] || subnet="$SUBNET6"
        if [[ -n "$subnet" ]]; then
            if [[ "$DRY" == 1 ]]; then
                printf '+ ip -%s rule del from %s lookup %s priority %s\n' "$f" "$subnet" "$TABLE" "$PRIO"
            else
                while ip "-$f" rule del from "$subnet" lookup "$TABLE" priority "$PRIO" 2>/dev/null; do :; done
            fi
        fi
        purge_legacy_reply "$f" "$subnet"
        try ip "-$f" route flush table "$TABLE"
    done
}

# --- IPv6 forwarding (sysctl.d file owned by this script) ------------------------------------------

# ensure_v6_forwarding: net.ipv6.conf.all.forwarding=1 now and after a reboot. Forwarding
# makes the kernel ignore router advertisements on interfaces with accept_ra=1, so
# interfaces that hold an RA-learnt default route get accept_ra=2 first.
ensure_v6_forwarding() {
    local content ifc cur ra="" tmp
    if [[ -e "$SYSCTL_FILE" && "$DRY" != 1 ]]; then
        [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" == 1 ]] && return 0
    else
        if [[ "$DRY" != 1 ]]; then
            while read -r ifc; do
                [[ -n "$ifc" ]] || continue
                cur="$(sysctl -n "net.ipv6.conf.${ifc//./\/}.accept_ra" 2>/dev/null || echo 2)"
                [[ "$cur" != 1 ]] || ra+="net.ipv6.conf.${ifc//./\/}.accept_ra = 2"$'\n'
            done < <(ip -6 route show default 2>/dev/null | awk '/proto ra/ {for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u)
        fi
        content="# Generated by $(basename "$SELF") ($TITLE): IPv6 forwarding for the $LABEL container.
# Removed by the remove script of the extension.
${ra}net.ipv6.conf.all.forwarding = 1"
        if [[ "$DRY" == 1 ]]; then
            printf '+ write %s:\n%s\n' "$SYSCTL_FILE" "$(sed 's/^/+   /' <<<"$content")"
            printf '+ sysctl -q -p %s\n' "$SYSCTL_FILE"
            return 0
        fi
        if mkdir -p "$(dirname "$SYSCTL_FILE")" && tmp="$(mktemp "$SYSCTL_FILE.XXXXXX")" &&
            printf '%s\n' "$content" >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$SYSCTL_FILE"; then
            :
        else
            warn "cannot write $SYSCTL_FILE: set net.ipv6.conf.all.forwarding=1 persistently by hand"
        fi
    fi
    if ! sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" != 1 ]]; then
        warn "cannot set net.ipv6.conf.all.forwarding=1: IPv6 traffic of $LABEL will not be forwarded (run: sysctl -w net.ipv6.conf.all.forwarding=1)"
    fi
}

# remove_src_valid_mark: the sysctl.d file of an earlier version (published port).
remove_src_valid_mark() {
    local f="${SYSCTL_FILE%.conf}-srcmark.conf"
    [[ -e "$f" ]] || return 0
    run rm -f "$f"
}

remove_v6_forwarding() {
    [[ -e "$SYSCTL_FILE" ]] || return 0
    run rm -f "$SYSCTL_FILE"
}

# --- firewall: iptables / ip6tables ---------------------------------------------------------------

# ipt_ensure_jump BIN TABLE PARENT ARGS...: insert "-j CHAIN" in PARENT unless present.
ipt_ensure_jump() {
    local bin=$1 t=$2 parent=$3
    shift 3
    if [[ "$DRY" == 1 ]]; then
        printf '+ %s -t %s -I %s 1 %s -j %s   # skipped when already present\n' "$bin" "$t" "$parent" "$*" "$CHAIN"
    elif ! "$bin" -t "$t" -C "$parent" "$@" -j "$CHAIN" 2>/dev/null; then
        "$bin" -t "$t" -I "$parent" 1 "$@" -j "$CHAIN"
    fi
}

ipt_filter_parent() {
    if [[ "$DRY" == 1 ]] || "$1" -t filter -S DOCKER-USER >/dev/null 2>&1; then
        printf 'DOCKER-USER'
    else
        printf 'FORWARD'
    fi
}

# ipt_apply_family BIN SUBNET EGRESS MODE
ipt_apply_family() {
    local bin=$1 subnet=$2 eg=$3 mode=$4 parent
    parent="$(ipt_filter_parent "$bin")"
    if [[ "$bin" == ip6tables && "$DRY" != 1 ]]; then
        "$bin" -t nat -S >/dev/null 2>&1 || die "the ip6tables nat table is not available (modprobe ip6table_nat)"
        if [[ "$parent" == FORWARD ]]; then
            # Docker runs with ip6tables disabled: it adds no IPv6 rules at all. The
            # masquerade is added here; the forwarding itself must be allowed.
            note "Docker has no IPv6 firewall chains (ip6tables disabled in the daemon): the MASQUERADE and the DROP rules are added here"
            if "$bin" -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP'; then
                warn "the ip6tables FORWARD policy is DROP: allow forwarding for $subnet, or enable \"ip6tables\": true in the Docker daemon"
            fi
        fi
    fi
    # nat: MASQUERADE out of the outway only
    try "$bin" -t nat -N "$CHAIN"
    run "$bin" -t nat -F "$CHAIN"
    if [[ "$eg" == 1 ]]; then
        run "$bin" -t nat -A "$CHAIN" -s "$subnet" -o "$OUTWAY" -m comment --comment "$COMMENT" -j MASQUERADE
    fi
    ipt_ensure_jump "$bin" nat POSTROUTING -s "$subnet"
    # filter: nothing from the subnet may leave through any other interface
    try "$bin" -t filter -N "$CHAIN"
    run "$bin" -t filter -F "$CHAIN"
    if [[ "$mode" == up && "$eg" == 1 ]]; then
        run "$bin" -t filter -A "$CHAIN" -s "$subnet" ! -o "$OUTWAY" -m comment --comment "$COMMENT" -j DROP
    else
        run "$bin" -t filter -A "$CHAIN" -s "$subnet" -m comment --comment "$COMMENT" -j DROP
    fi
    ipt_ensure_jump "$bin" filter "$parent" -s "$subnet"
}

# ipt_purge_jumps BIN TABLE PARENT: delete every "-j CHAIN" rule of PARENT (any subnet).
ipt_purge_jumps() {
    local bin=$1 t=$2 parent=$3 r
    local -a a
    while IFS= read -r r; do
        [[ "$r" == "-A $parent "* && "$r" == *" -j $CHAIN" ]] || continue
        read -ra a <<<"${r/-A/-D}"
        "$bin" -t "$t" "${a[@]}" 2>/dev/null || true
    done < <("$bin" -t "$t" -S "$parent" 2>/dev/null || true)
}

# ipt_remove_family BIN SUBNET
ipt_remove_family() {
    local bin=$1 subnet=$2 parent
    if [[ "$DRY" == 1 ]]; then
        for parent in DOCKER-USER FORWARD; do
            printf '+ %s -t filter -D %s -s %s -j %s\n' "$bin" "$parent" "$subnet" "$CHAIN"
        done
        printf '+ %s -t nat -D POSTROUTING -s %s -j %s\n' "$bin" "$subnet" "$CHAIN"
    else
        command -v "$bin" >/dev/null 2>&1 || return 0
        for parent in DOCKER-USER FORWARD; do ipt_purge_jumps "$bin" filter "$parent"; done
        ipt_purge_jumps "$bin" nat POSTROUTING
        # mangle chain of an earlier version (reply marks of a published port).
        for parent in FORWARD PREROUTING; do ipt_purge_jumps "$bin" mangle "$parent"; done
    fi
    try "$bin" -t filter -F "$CHAIN"
    try "$bin" -t filter -X "$CHAIN"
    try "$bin" -t nat -F "$CHAIN"
    try "$bin" -t nat -X "$CHAIN"
    if [[ "$DRY" != 1 ]]; then
        try "$bin" -t mangle -F "$CHAIN"
        try "$bin" -t mangle -X "$CHAIN"
    fi
}

ipt_apply() {
    ipt_apply_family iptables "$SUBNET" "$(egress 4)" "$1"
    if [[ -n "$SUBNET6" ]]; then ipt_apply_family ip6tables "$SUBNET6" "$(egress 6)" "$1"; fi
}
ipt_remove() {
    ipt_remove_family iptables "$SUBNET"
    # IPv6 leftovers are removed whether or not the state still has NET_SUBNET6.
    if [[ -n "$SUBNET6" || "$DRY" != 1 ]]; then ipt_remove_family ip6tables "$SUBNET6"; fi
}

# purge_stale_v6: the container network is IPv4-only now (the outway was changed or its
# IPv6 is gone): remove the IPv6 rules, chains and routes left by an earlier run.
purge_stale_v6() {
    [[ "$DRY" != 1 ]] || return 0
    ip -6 rule show 2>/dev/null | grep -q "^${PRIO}:" || return 0
    if [[ "$(fw_backend)" == iptables ]]; then ipt_remove_family ip6tables ""; else try nft delete table ip6 "$NFT_TABLE"; fi
    while ip -6 rule del priority "$PRIO" lookup "$TABLE" 2>/dev/null; do :; done
    purge_legacy_reply 6 "$SUBNET6"
    ip -6 route flush table "$TABLE" 2>/dev/null || true
}

# --- firewall: nft (hosts without iptables) -------------------------------------------------

# nft_table FAMILY(ip|ip6) SUBNET EGRESS MODE: add/delete/define one table.
nft_table() {
    local fam=$1 subnet=$2 eg=$3 mode=$4 drop masq=""
    if [[ "$mode" == up && "$eg" == 1 ]]; then
        drop="$fam saddr $subnet oifname != \"$OUTWAY\" counter drop comment \"$COMMENT\""
    else
        drop="$fam saddr $subnet counter drop comment \"$COMMENT\""
    fi
    [[ "$eg" != 1 ]] || masq="$fam saddr $subnet oifname \"$OUTWAY\" counter masquerade comment \"$COMMENT\""
    printf 'add table %s %s\ndelete table %s %s\ntable %s %s {\n    chain nat_post {\n        type nat hook postrouting priority srcnat; policy accept;\n        %s\n    }\n    chain filter_fwd {\n        type filter hook forward priority -10; policy accept;\n        %s\n    }\n}\n' \
        "$fam" "$NFT_TABLE" "$fam" "$NFT_TABLE" "$fam" "$NFT_TABLE" "$masq" "$drop"
}

nft_apply() {
    local rules
    rules="$(nft_table ip "$SUBNET" "$(egress 4)" "$1")"
    if [[ -n "$SUBNET6" ]]; then rules+=$'\n'"$(nft_table ip6 "$SUBNET6" "$(egress 6)" "$1")"; fi
    if [[ "$DRY" == 1 ]]; then
        printf '+ nft -f - <<EOF\n%s\nEOF\n' "$rules"
    else
        nft -f - <<<"$rules"
    fi
}
nft_remove() {
    try nft delete table ip "$NFT_TABLE"
    try nft delete table ip6 "$NFT_TABLE"
}

fw_apply() { if [[ "$(fw_backend)" == iptables ]]; then ipt_apply "$1"; else nft_apply "$1"; fi; }
fw_remove() { if [[ "$(fw_backend)" == iptables ]]; then ipt_remove; else nft_remove; fi; }

# --- rp_filter hint ----------------------------------------------------------------------

check_rp_filter() {
    local all dev
    [[ "$DRY" == 1 ]] && return 0
    [[ "$(egress 4)" == 1 ]] || return 0
    all="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)"
    dev="$(sysctl -n "net.ipv4.conf.${OUTWAY//./\/}.rp_filter" 2>/dev/null || echo 0)"
    if ((all == 1 || dev == 1)); then
        warn "strict reverse-path filtering (rp_filter=1) may drop replies arriving on $OUTWAY; if $LABEL cannot connect, set net.ipv4.conf.all.rp_filter=2 and net.ipv4.conf.$OUTWAY.rp_filter=2"
    fi
}

# --- commands ---------------------------------------------------------------------------------

# remove_legacy_reply: what an earlier version added for a published port (fwmark rule,
# mangle chain, src_valid_mark sysctl.d file); nothing to do on a clean host.
remove_legacy_reply() {
    local bin
    [[ "$DRY" != 1 ]] || return 0
    remove_src_valid_mark
    purge_legacy_reply 4 "$SUBNET"
    purge_legacy_reply 6 "$SUBNET6"
    [[ "$(fw_backend)" == iptables ]] || return 0
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        "$bin" -t mangle -S "$CHAIN" >/dev/null 2>&1 || continue
        ipt_purge_jumps "$bin" mangle FORWARD
        ipt_purge_jumps "$bin" mangle PREROUTING
        try "$bin" -t mangle -F "$CHAIN"
        try "$bin" -t mangle -X "$CHAIN"
    done
}

cmd_up() {
    load_state
    if [[ -n "$SUBNET6" ]]; then
        ensure_v6_forwarding
    else
        remove_v6_forwarding
        purge_stale_v6
    fi
    remove_legacy_reply
    apply_routes up
    fw_apply up
    check_rp_filter
    note "outway $OUTWAY ($(fams_name "$FAMILIES")) applied for $SUBNET${SUBNET6:+ and $SUBNET6} (table $TABLE, $(fw_backend)): IPv4 ${ROUTE_STATE_4}${SUBNET6:+, IPv6 ${ROUTE_STATE_6}}"
}

cmd_block() {
    load_state
    apply_routes block
    fw_apply block
    note "$LABEL traffic from $SUBNET${SUBNET6:+ and $SUBNET6} is blocked (fail-closed)"
}

cmd_down() {
    load_state
    fw_remove
    remove_routes
    remove_v6_forwarding
    remove_src_valid_mark
    note "outway rules for $SUBNET${SUBNET6:+ and $SUBNET6} removed"
}

# status_family FAMILY SUBNET: prints the rule/route lines of one family; sets ST.
status_family() {
    local f=$1 subnet=$2 route
    if rule_present "$f" "$subnet"; then
        printf 'ip rule    : IPv%s present\n' "$f"
    else
        printf 'ip rule    : IPv%s MISSING (%s traffic is NOT policy-routed)\n' "$f" "$LABEL"
        ST=bad
    fi
    route="$(ip "-$f" route show table "$TABLE" 2>/dev/null || true)"
    printf 'table %s (IPv%s):\n' "$TABLE" "$f"
    # shellcheck disable=SC2001
    [[ -z "$route" ]] || sed 's/^/    /' <<<"$route"
    if [[ "$(egress "$f")" != 1 ]]; then
        printf 'state      : IPv%s is not carried by %s: %s IPv%s traffic is dropped (fail-closed)\n' "$f" "$OUTWAY" "$LABEL" "$f"
    elif ! grep -Eq "^default .*dev ${OUTWAY//./\\.}( |\$)" <<<"$route"; then
        printf 'state      : IPv%s BLOCKED (fail-closed): no route via %s, %s traffic is dropped\n' "$f" "$OUTWAY" "$LABEL"
        [[ "$ST" != ok ]] || ST=blocked
    fi
}

cmd_status() {
    local fw
    ST=ok
    load_state
    fw="$(fw_backend)"
    printf 'outway     : %s (%s), carries %s\n' "$OUTWAY" "$(if iface_exists "$OUTWAY"; then iface_up "$OUTWAY" && echo up || echo DOWN; else echo MISSING; fi)" "$(fams_name "$FAMILIES")"
    printf 'subnet     : %s%s, table %s, rule priority %s, firewall %s\n' "$SUBNET" "${SUBNET6:+, $SUBNET6}" "$TABLE" "$PRIO" "$fw"
    status_family 4 "$SUBNET"
    if [[ -n "$SUBNET6" ]]; then status_family 6 "$SUBNET6"; fi
    if [[ "$fw" == iptables ]]; then
        iptables -t filter -S "$CHAIN" >/dev/null 2>&1 || { printf 'firewall   : filter chain %s MISSING\n' "$CHAIN"; ST=bad; }
        iptables -t nat -S "$CHAIN" >/dev/null 2>&1 || { printf 'firewall   : nat chain %s MISSING\n' "$CHAIN"; ST=bad; }
        if [[ -n "$SUBNET6" ]]; then
            ip6tables -t filter -S "$CHAIN" >/dev/null 2>&1 || { printf 'firewall   : ip6tables filter chain %s MISSING\n' "$CHAIN"; ST=bad; }
            ip6tables -t nat -S "$CHAIN" >/dev/null 2>&1 || { printf 'firewall   : ip6tables nat chain %s MISSING\n' "$CHAIN"; ST=bad; }
        fi
    else
        nft list table ip "$NFT_TABLE" >/dev/null 2>&1 || { printf 'firewall   : nft table ip %s MISSING\n' "$NFT_TABLE"; ST=bad; }
        if [[ -n "$SUBNET6" ]]; then
            nft list table ip6 "$NFT_TABLE" >/dev/null 2>&1 || { printf 'firewall   : nft table ip6 %s MISSING\n' "$NFT_TABLE"; ST=bad; }
        fi
    fi
    if [[ -n "$SUBNET6" ]]; then
        if [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" == 1 ]]; then
            printf 'sysctl     : net.ipv6.conf.all.forwarding = 1\n'
        else
            printf 'sysctl     : net.ipv6.conf.all.forwarding is NOT 1 (IPv6 of %s is not forwarded)\n' "$LABEL"
            ST=bad
        fi
    fi
    [[ "$ST" != ok ]] || printf 'state      : OK, %s egress goes out through %s (%s)\n' "$LABEL" "$OUTWAY" "$(fams_name "$FAMILIES")"
    if systemctl is-enabled "$UNIT.service" >/dev/null 2>&1; then
        printf 'systemd    : %s.service enabled\n' "$UNIT"
    else
        printf 'systemd    : %s.service not enabled\n' "$UNIT"
    fi
    [[ "$ST" == ok ]]
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
Description=$TITLE: outgoing interface (policy routing) of the $LABEL container
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
Description=$TITLE: re-apply the outway rules (VPN restarts, interface flaps)
After=$UNIT.service
ConditionPathExists=$STATE_FILE

[Service]
Type=oneshot
ExecStart=$exec_self --quiet up
UNIT_EOF
    cat >"$UNIT_DIR/$UNIT.timer" <<UNIT_EOF
[Unit]
Description=$TITLE: periodic outway check

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
    [[ -n "$cmd" ]] || die "usage: $0 [--quiet] [--dry-run] up|block|down|status|list|names|resolve N|families IF|check IF|install-unit|remove-unit"
    load_names
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
        names) iface_names ;;
        resolve) cmd_resolve "${1:-}" ;;
        families) cmd_families "${1:-}" ;;
        check) cmd_check "${1:-}" ;;
        install-unit) cmd_install_unit ;;
        remove-unit) cmd_remove_unit ;;
        *) die "unknown command '$cmd'" ;;
    esac
}
main "$@"
