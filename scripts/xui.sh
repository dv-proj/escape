#!/usr/bin/env bash
# 3X-UI / Xray configuration for the VPN stack.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat <<'EOF'
Usage: scripts/xui.sh <command>

Commands:
  genkeys          Print freshly generated secrets as KEY=value lines (stdout):
                   REALITY_PRIVATE_KEY, REALITY_PUBLIC_KEY, REALITY_SHORT_ID,
                   CLIENT_UUID. Uses the xray binary from $XUI_IMAGE in a
                   throwaway container; the stack does not need to be running
                   and .env is optional. Nothing is written anywhere.
  configure-panel  Set panel username/password/port/webBasePath with the x-ui
                   CLI inside the running xui container, then restart it and
                   wait for the panel. Idempotent.
  provision        Create the 'reality' and 'xhttp' inbounds via the 3X-UI HTTP
                   API unless inbounds with these remarks already exist, then
                   restart Xray, then run configure-hosts. Requires a running
                   xui container (run configure-panel first). Idempotent.
  configure-hosts  Create/update the 3X-UI "hosts" (per-inbound link overrides)
                   so that panel and subscription links point to
                   DOMAIN:443 with TLS (xhttp: h2 and h3 variants) instead of
                   the inbound's internal port/security. Matches hosts by
                   remark; changes nothing when they are already right.
                   Also adds h2/h3 hosts to additional XHTTP inbounds
                   (port matching XHTTP_ROUTE_PORT_RE, path
                   /XHTTP_PATH-<port>/, security none) that have no host
                   yet; their existing hosts are never changed. Idempotent.
  auto-hosts       Like configure-hosts, but only adds missing hosts (never
                   changes existing ones), prints nothing when there is
                   nothing to do and does nothing while xui is not running.
                   Run every minute by the vpn-hosts.timer user unit
                   (installed by vpn.sh deploy).
  configure-sub    Apply the subscription settings through the panel API
                   (enabled, port SUB_PORT, path /SUB_PATH/, public URL
                   https://DOMAIN/SUB_PATH/, no TLS on the sub server: nginx
                   terminates it) and restart xui only if something changed.
                   Idempotent.
  sub-links        Print the subscription URL of every client (one per line):
                   https://DOMAIN/SUB_PATH/<subId>. Requires a running panel.
  links            Print client share links (stdout, one per line):
                   1) VLESS+REALITY+Vision (TCP 443)
                   2) VLESS+XHTTP over TLS/h2 (TCP 443 -> REALITY fallback ->
                      nginx -> Xray XHTTP)
                   3) VLESS+XHTTP over HTTP/3 (UDP 443 -> nginx -> Xray XHTTP)
                   Pure string formatting; needs no running containers.
  help             Show this help.

Environment (.env at the repo root, or ENV_FILE=path):
  configure-panel  PANEL_USERNAME PANEL_PASSWORD PANEL_PATH [PANEL_PORT=2053]
  provision        DOMAIN CLIENT_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
                   REALITY_SHORT_ID XHTTP_PATH [XHTTP_PORT=10000]
                   [NGINX_TLS_PORT=8443] [PANEL_PORT=2053]
  configure-hosts  DOMAIN XHTTP_PATH [PANEL_PORT=2053] [PANEL_PATH]
                   [XHTTP_ROUTE_PORT_RE=1[0-9]{4}]
  auto-hosts       same as configure-hosts
  configure-sub    DOMAIN SUB_PATH [SUB_PORT=2096] [PANEL_PORT=2053] [PANEL_PATH]
  sub-links        DOMAIN SUB_PATH [PANEL_PORT=2053] [PANEL_PATH]
  links            DOMAIN CLIENT_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID
                   XHTTP_PATH [LINK_NAME, default: APP_NAME or "vpn"]
  genkeys          [XUI_IMAGE]
EOF
}

REALITY_REMARK=reality
XHTTP_REMARK=xhttp
# Host (link override) remarks. A subscription link is named
# "<inbound remark>-<host remark>-<client email>".
# The panel's factory remark template has no {{HOST}}, so the h2 and h3 xhttp
# links would get the same name. configure-sub adds {{HOST}} to it, but only
# while the template still is the factory one (a customised one is kept).
FACTORY_REMARK_TEMPLATE='{{INBOUND}}-{{EMAIL}}|📊{{TRAFFIC_LEFT}}|⏳{{DAYS_LEFT}}D'
LINK_REMARK_TEMPLATE='{{INBOUND}}-{{HOST}}-{{EMAIL}}|📊{{TRAFFIC_LEFT}}|⏳{{DAYS_LEFT}}D'
REALITY_HOST_REMARK=tcp
XHTTP_H2_HOST_REMARK=h2
XHTTP_H3_HOST_REMARK=h3
# Token name used for API access during provisioning; rotated (invalidated)
# again when provisioning finishes.
# XUI_API_TOKEN_NAME lets concurrent callers (the auto-hosts timer) use their
# own token, so one run never invalidates the token of another.
API_TOKEN_NAME="${XUI_API_TOKEN_NAME:-vpn-provision}"
[[ "$API_TOKEN_NAME" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || {
    printf 'error: invalid XUI_API_TOKEN_NAME\n' >&2
    exit 1
}
XHTTP_MODE=auto

# --- validation -------------------------------------------------------------------

validate() {
    local name="$1" re="$2" hint="$3"
    [[ "${!name}" =~ $re ]] || die "$name has an invalid value ('${!name}'): expected $hint"
}

validate_common() {
    [[ -z "${DOMAIN:-}" ]] || validate DOMAIN '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' "a fully qualified domain name"
    [[ -z "${CLIENT_UUID:-}" ]] || validate CLIENT_UUID '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' "a UUID"
    [[ -z "${REALITY_PRIVATE_KEY:-}" ]] || validate REALITY_PRIVATE_KEY '^[A-Za-z0-9_-]{43}$' "a base64url x25519 key (xui.sh genkeys)"
    [[ -z "${REALITY_PUBLIC_KEY:-}" ]] || validate REALITY_PUBLIC_KEY '^[A-Za-z0-9_-]{43}$' "a base64url x25519 key (xui.sh genkeys)"
    [[ -z "${REALITY_SHORT_ID:-}" ]] || validate REALITY_SHORT_ID '^([0-9a-f]{2}){1,8}$' "1-8 bytes of lowercase hex (2-16 chars)"
    [[ -z "${XHTTP_PATH:-}" ]] || validate XHTTP_PATH '^[A-Za-z0-9._~-]+$' "a single URL path segment without slashes"
    [[ -z "${PANEL_PATH:-}" ]] || validate PANEL_PATH '^[A-Za-z0-9._~-]+$' "a single URL path segment without slashes"
    [[ -z "${SUB_PATH:-}" ]] || validate SUB_PATH '^[A-Za-z0-9._~-]+$' "a single URL path segment without slashes"
    [[ -z "${REALITY_MAX_TIME_DIFF_MS:-}" ]] || validate REALITY_MAX_TIME_DIFF_MS '^[0-9]{1,9}$' "a non-negative integer in milliseconds (0 disables the check)"
    validate PANEL_PORT '^[0-9]{1,5}$' "a port number"
    validate XHTTP_PORT '^[0-9]{1,5}$' "a port number"
    validate SUB_PORT '^[0-9]{1,5}$' "a port number"
    validate NGINX_TLS_PORT '^[0-9]{1,5}$' "a port number"
    validate_route_port_re
}

# Same checks as nginx/docker-entrypoint.d/15-xhttp-route.envsh (nginx refuses
# to start otherwise).
validate_route_port_re() {
    local re="$XHTTP_ROUTE_PORT_RE" ports p
    validate XHTTP_ROUTE_PORT_RE '^[][0-9{},|()?-]+$' "a port regex of 0-9 [ ] - { } , | ( ) ? (e.g. 1[0-9]{4})"
    ports="$(seq 0 99999 | grep -Ex -- "$re")" || die "XHTTP_ROUTE_PORT_RE '$re' matches no port"
    # seq output is sorted: the first and last matches are the extremes.
    for p in "${ports%%$'\n'*}" "${ports##*$'\n'}"; do
        ((10#$p >= 1024 && 10#$p <= 65535)) || die "XHTTP_ROUTE_PORT_RE matches $p: only ports 1024-65535 are allowed"
    done
    for p in "$PANEL_PORT" "$SUB_PORT" "$NGINX_TLS_PORT"; do
        ! grep -Eqx -- "$re" <<<"$p" || die "XHTTP_ROUTE_PORT_RE matches port $p (PANEL_PORT/SUB_PORT/NGINX_TLS_PORT)"
    done
}

# --- helpers ---------------------------------------------------------------------------

# json_str VALUE: VALUE as a JSON string literal.
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

# urlencode VALUE: percent-encode everything except RFC 3986 unreserved chars.
urlencode() {
    local s="$1" out="" c i
    local LC_ALL=C
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

random_hex() { # BYTES
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

xui_exec() {
    compose exec -T xui "$@"
}

# wait_port PORT WHAT: wait until xui listens on PORT (inside the container).
wait_port() {
    local port="$1" what="$2" i
    for ((i = 0; i < 60; i++)); do
        if xui_exec nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    die "$what did not start listening on port $port within 120s; see: docker compose logs xui"
}

wait_panel() { wait_port "$PANEL_PORT" "panel"; }

# --- genkeys -------------------------------------------------------------------------

cmd_genkeys() {
    local out priv pub uuid
    # The binary is /app/bin/xray-linux-<arch>; resolve it inside the container.
    # shellcheck disable=SC2016  # expanded by the container shell
    out="$(docker run --rm --network none --entrypoint /bin/sh "$XUI_IMAGE" -c '
        set -e
        x=$(ls /app/bin/xray-linux-* | head -n 1)
        "$x" x25519
        echo "UUID: $("$x" uuid)"
    ')" || die "failed to run xray from $XUI_IMAGE"
    # Output formats: "PrivateKey: X" / "Password (PublicKey): Y" (Xray >= 25.x)
    # or "Private key: X" / "Public key: Y" (older releases).
    priv="$(awk -F': *' 'tolower($1) ~ /^private ?key$/ {print $2; exit}' <<<"$out")"
    pub="$(awk -F': *' 'tolower($1) ~ /public ?key/ {print $2; exit}' <<<"$out")"
    uuid="$(awk -F': *' '$1 == "UUID" {print $2; exit}' <<<"$out")"
    [[ -n "$priv" && -n "$pub" && -n "$uuid" ]] || die "could not parse xray output: $out"
    printf 'REALITY_PRIVATE_KEY=%s\n' "$priv"
    printf 'REALITY_PUBLIC_KEY=%s\n' "$pub"
    printf 'REALITY_SHORT_ID=%s\n' "$(random_hex 8)"
    printf 'CLIENT_UUID=%s\n' "$uuid"
}

# --- configure-panel -------------------------------------------------------------

cmd_configure_panel() {
    require_vars PANEL_USERNAME PANEL_PASSWORD PANEL_PATH
    require_running xui
    log "applying panel settings (port $PANEL_PORT, path /$PANEL_PATH/)"
    xui_exec /app/x-ui setting \
        -username "$PANEL_USERNAME" -password "$PANEL_PASSWORD" \
        -port "$PANEL_PORT" -webBasePath "/$PANEL_PATH/" >/dev/null ||
        die "x-ui setting failed"
    log "restarting xui"
    compose restart xui >/dev/null 2>&1 || die "failed to restart xui; see: docker compose logs xui"
    wait_panel
    log "panel is up at https://${DOMAIN:-<DOMAIN>}/$PANEL_PATH/"
}

# --- provision -----------------------------------------------------------------------

API_TOKEN=""
API_BASE=""
PROVISION_SUB_ID=""

issue_token() {
    xui_exec /app/x-ui setting -getApiToken -tokenName "$API_TOKEN_NAME" -tokenScope admin 2>/dev/null |
        awk '/^apiToken:/ {print $2; exit}'
}

revoke_token() {
    # Regenerating the named token invalidates the one we used.
    if [[ -n "$API_TOKEN" ]]; then
        issue_token >/dev/null 2>&1 || true
    fi
}

# api METHOD PATH [JSON_BODY]: call /panel/api/PATH, print the response body.
api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS --max-time 60 -X "$method" -K -)
    if [[ -n "$body" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi
    # The bearer token goes through stdin (curl config), not argv.
    printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN" |
        xui_exec curl "${args[@]}" "$API_BASE/panel/api/$path"
}

api_ok() { # RESPONSE
    [[ "$1" =~ \"success\":[[:space:]]*true ]]
}

api_msg() { # RESPONSE
    sed -n 's/.*"msg":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$1" | head -n 1
}

has_remark() { # LIST_RESPONSE REMARK
    [[ "$1" =~ \"remark\":[[:space:]]*\"$2\" ]]
}

client_json() { # EMAIL FLOW
    printf '{"id":%s,"flow":%s,"email":%s,"limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":0,"subId":%s,"comment":"","reset":0}' \
        "$(json_str "$CLIENT_UUID")" "$(json_str "$2")" "$(json_str "$1")" "$(json_str "${PROVISION_SUB_ID:-$(random_hex 8)}")"
}

SNIFFING='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

# inbound_json REMARK PORT SETTINGS STREAM_SETTINGS: body for /inbounds/add.
# settings/streamSettings/sniffing are JSON documents passed as strings.
inbound_json() {
    printf '{"up":0,"down":0,"total":0,"remark":%s,"enable":true,"expiryTime":0,"listen":"","port":%d,"protocol":"vless","settings":%s,"streamSettings":%s,"sniffing":%s}' \
        "$(json_str "$1")" "$2" "$(json_str "$3")" "$(json_str "$4")" "$(json_str "$SNIFFING")"
}

reality_inbound() {
    local settings stream
    settings="{\"clients\":[$(client_json "client-reality" "xtls-rprx-vision")],\"decryption\":\"none\",\"encryption\":\"none\",\"fallbacks\":[]}"
    # target = nginx TLS listener; xver 1 = PROXY protocol v1 (matches
    # `listen ... proxy_protocol` in nginx, which auto-detects v1/v2).
    stream="{\"network\":\"tcp\",\"security\":\"reality\",\"externalProxy\":[],\"realitySettings\":{\"show\":false,\"xver\":1,\"target\":$(json_str "nginx:$NGINX_TLS_PORT"),\"serverNames\":[$(json_str "$DOMAIN")],\"privateKey\":$(json_str "$REALITY_PRIVATE_KEY"),\"minClientVer\":\"\",\"maxClientVer\":\"\",\"maxTimediff\":${REALITY_MAX_TIME_DIFF_MS:-0},\"shortIds\":[$(json_str "$REALITY_SHORT_ID")],\"settings\":{\"publicKey\":$(json_str "$REALITY_PUBLIC_KEY"),\"fingerprint\":\"chrome\",\"serverName\":\"\",\"spiderX\":\"/\"}},\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
    inbound_json "$REALITY_REMARK" 443 "$settings" "$stream"
}

xhttp_inbound() {
    local settings stream
    settings="{\"clients\":[$(client_json "client-xhttp" "")],\"decryption\":\"none\",\"encryption\":\"none\",\"fallbacks\":[]}"
    # TLS is terminated by nginx; Xray sees h2c via grpc_pass. Mode "auto"
    # on the server accepts every client mode (stream-one, stream-up,
    # packet-up). X-Real-IP (set by nginx) is trusted for the client address.
    stream="{\"network\":\"xhttp\",\"security\":\"none\",\"externalProxy\":[],\"xhttpSettings\":{\"path\":$(json_str "/$XHTTP_PATH"),\"host\":\"\",\"mode\":$(json_str "$XHTTP_MODE"),\"headers\":{}},\"sockopt\":{\"trustedXForwardedFor\":[\"X-Real-IP\"]}}"
    inbound_json "$XHTTP_REMARK" "$XHTTP_PORT" "$settings" "$stream"
}

add_inbound() { # REMARK JSON
    local resp
    resp="$(api POST inbounds/add "$2")" || die "API request inbounds/add failed"
    api_ok "$resp" || die "failed to add inbound '$1': $(api_msg "$resp")"
    log "inbound '$1' created"
}

# api_session_start: wait for the panel, find its base path, obtain a token
# (revoked again on exit). No-op when a session is already open.
api_session_start() {
    [[ -z "$API_TOKEN" ]] || return 0
    require_running xui
    wait_panel

    local base_path
    base_path="$(xui_exec /app/x-ui setting -show 2>/dev/null | awk '/^webBasePath:/ {print $2; exit}')"
    [[ -n "$base_path" ]] || base_path=/
    [[ -z "${PANEL_PATH:-}" || "$base_path" == "/$PANEL_PATH/" ]] ||
        warn "panel webBasePath is '$base_path', expected '/$PANEL_PATH/' (run: scripts/xui.sh configure-panel)"
    API_BASE="http://127.0.0.1:${PANEL_PORT}${base_path%/}"

    API_TOKEN="$(issue_token)"
    [[ -n "$API_TOKEN" ]] || die "could not obtain an API token from 'x-ui setting -getApiToken'"
    trap revoke_token EXIT
}

cmd_provision() {
    require_vars DOMAIN CLIENT_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID XHTTP_PATH
    api_session_start
    # Both new clients share one subscription id: a single subscription URL
    # then carries the REALITY link and both XHTTP links.
    PROVISION_SUB_ID="$(random_hex 8)"

    local list changed=0
    list="$(api GET inbounds/list)" || die "API request inbounds/list failed"
    api_ok "$list" || die "inbounds/list failed: $(api_msg "$list") (response: ${list:0:200})"

    if has_remark "$list" "$REALITY_REMARK"; then
        log "inbound '$REALITY_REMARK' already exists; skipping"
    else
        add_inbound "$REALITY_REMARK" "$(reality_inbound)"
        changed=1
    fi
    if has_remark "$list" "$XHTTP_REMARK"; then
        log "inbound '$XHTTP_REMARK' already exists; skipping"
    else
        add_inbound "$XHTTP_REMARK" "$(xhttp_inbound)"
        changed=1
    fi

    if ((changed)); then
        local resp
        resp="$(api POST server/restartXrayService)" || die "API request server/restartXrayService failed"
        api_ok "$resp" || die "failed to restart Xray: $(api_msg "$resp")"
        log "Xray restarted"
    fi

    apply_hosts
}

# --- hosts (link overrides) -------------------------------------------------------

# 3X-UI builds panel and subscription links from the inbound itself (internal
# port, security "none" for xhttp, server address). A "host" overrides that per
# inbound: with at least one enabled host the inbound's own link is replaced by
# one link per host. Reads two JSON lines on stdin (inbounds/list and
# hosts/list responses), prints the changes needed, one per line:
#   add<TAB><HostGroup JSON>   |   update<TAB><groupId><TAB><HostGroup JSON>
# Existing groups (matched by remark + inbound) are merged, so fields not
# managed here (sort order, tags, ...) survive an update.
# Additional XHTTP inbounds (created in the panel, port in
# XHTTP_ROUTE_PORT_RE, path /<XHTTP_PATH>-<port>/, security none) get
# h2 and h3 hosts too, but only while they have no host at all: once a host
# exists for such an inbound it is left to the user.
# argv: DOMAIN REALITY_INBOUND XHTTP_INBOUND REALITY_HOST H2_HOST H3_HOST
#       XHTTP_PATH PORT_RE
HOSTS_PLAN_PY='
import json, sys
domain, in_reality, in_xhttp, host_reality, host_h2, host_h3, xhttp_path = sys.argv[1:8]
import re
port_re = re.compile("(?:%s)" % sys.argv[8])
inbounds = json.loads(sys.stdin.readline()).get("obj") or []
groups = json.loads(sys.stdin.readline()).get("obj") or []
ids = {i["remark"]: i["id"] for i in inbounds}

def want_id(inbound_id, remark, security, sni, header, alpn, fp):
    return {"inboundIds": [inbound_id], "hosts": [domain], "remark": remark,
            "port": 443, "security": security, "sni": sni, "hostHeader": header,
            "alpn": alpn, "fingerprint": fp, "isDisabled": False}

def want(inbound, *rest):
    return want_id(ids[inbound], *rest)

desired = []
if in_reality in ids:
    desired.append(want(in_reality, host_reality, "same", "", "", [], ""))
else:
    sys.stderr.write("inbound %r not found; skipping its host\n" % in_reality)
if in_xhttp in ids:
    desired.append(want(in_xhttp, host_h2, "tls", domain, domain, ["h2"], "chrome"))
    desired.append(want(in_xhttp, host_h3, "tls", domain, domain, ["h3"], "chrome"))
else:
    sys.stderr.write("inbound %r not found; skipping its hosts\n" % in_xhttp)

def stream_of(inbound):
    st = inbound.get("streamSettings") or "{}"
    try:
        return json.loads(st) if isinstance(st, str) else st
    except ValueError:
        return {}

with_hosts = {i for g in groups for i in (g.get("inboundIds") or [])}
managed = {ids.get(in_reality), ids.get(in_xhttp)}
for inb in inbounds:
    st = stream_of(inb)
    if inb["id"] in managed or st.get("network") != "xhttp":
        continue
    port = int(inb.get("port") or 0)
    if not port_re.fullmatch(str(port)):
        continue
    name = inb.get("remark") or "#%d" % inb["id"]
    path = ((st.get("xhttpSettings") or {}).get("path") or "").rstrip("/")
    expected = "/%s-%d" % (xhttp_path, port)
    if path != expected:
        sys.stderr.write("inbound %r (port %d): path %r is not routed by nginx; set it to %r\n" % (name, port, path or "/", expected + "/"))
        continue
    if st.get("security", "none") != "none":
        sys.stderr.write("inbound %r (port %d): security must be none (nginx terminates TLS); skipping its hosts\n" % (name, port))
        continue
    if inb["id"] in with_hosts:
        continue
    desired.append(dict(want_id(inb["id"], host_h2, "tls", domain, domain, ["h2"], "chrome")))
    desired.append(dict(want_id(inb["id"], host_h3, "tls", domain, domain, ["h3"], "chrome")))

def same(group, w):
    for k, v in w.items():
        if k == "hosts":
            v = ["%s:%d" % (domain, w["port"])]
        cur = group.get(k)
        if cur is None:
            cur = [] if isinstance(v, list) else ("" if isinstance(v, str) else cur)
        if cur != v:
            return False
    return True

for w in desired:
    found = [g for g in groups if g.get("remark") == w["remark"] and w["inboundIds"][0] in (g.get("inboundIds") or [])]
    if not found:
        print("add\t" + json.dumps(w, separators=(",", ":")))
    elif not same(found[0], w):
        merged = dict(found[0]); merged.update(w)
        print("update\t%s\t%s" % (found[0]["groupId"], json.dumps(merged, separators=(",", ":"))))
'

# apply_hosts: needs an open API session. Safe to repeat.
apply_hosts() {
    local inbounds hosts plan action a b resp n=0
    inbounds="$(api GET inbounds/list)" || die "API request inbounds/list failed"
    api_ok "$inbounds" || die "inbounds/list failed: $(api_msg "$inbounds")"
    hosts="$(api GET hosts/list)" || die "API request hosts/list failed"
    api_ok "$hosts" || die "hosts/list failed: $(api_msg "$hosts") (response: ${hosts:0:200})"
    plan="$(printf '%s\n%s\n' "$inbounds" "$hosts" |
        xui_exec python3 -I -c "$HOSTS_PLAN_PY" "$DOMAIN" "$REALITY_REMARK" "$XHTTP_REMARK" \
            "$REALITY_HOST_REMARK" "$XHTTP_H2_HOST_REMARK" "$XHTTP_H3_HOST_REMARK" \
            "$XHTTP_PATH" "$XHTTP_ROUTE_PORT_RE")" ||
        die "could not compute the host changes"
    while IFS=$'\t' read -r action a b; do
        [[ -n "$action" ]] || continue
        # Add-only mode (auto-hosts): hosts the user edited are never reverted.
        [[ "$action" != update || -z "${HOSTS_ADD_ONLY:-}" ]] || continue
        case "$action" in
            add) resp="$(api POST hosts/add "$a")" || die "API request hosts/add failed" ;;
            update) resp="$(api POST "hosts/update/$a" "$b")" || die "API request hosts/update failed" ;;
            *) die "unexpected host plan line: $action" ;;
        esac
        api_ok "$resp" || die "host $action failed: $(api_msg "$resp") (response: ${resp:0:200})"
        n=$((n + 1))
    done <<<"$plan"
    if ((n)); then
        log "hosts configured ($n changed)"
    elif [[ -z "${HOSTS_ADD_ONLY:-}" ]]; then
        log "hosts already up to date"
    fi
}

# auto-hosts: run by the vpn-hosts.timer user unit every minute. Adds missing
# hosts only (never updates existing ones), silent when nothing changes and
# when the stack is not running.
cmd_auto_hosts() {
    require_vars DOMAIN XHTTP_PATH
    service_running xui || return 0
    HOSTS_ADD_ONLY=1
    api_session_start
    apply_hosts
}

cmd_configure_hosts() {
    require_vars DOMAIN XHTTP_PATH
    api_session_start
    apply_hosts
}

# --- subscriptions ------------------------------------------------------------------

# Reads the setting/all response on stdin. argv items:
#   KEY=<JSON value>                  set KEY
#   ?KEY<TAB><JSON old><TAB><JSON new>  set KEY to new only if it currently is old
# Prints the full settings body to post when any key differs (the differences
# go to stderr), nothing otherwise.
SETTINGS_PATCH_PY='
import json, sys
resp = json.loads(sys.stdin.readline())
obj = resp.get("obj")
if not resp.get("success") or not isinstance(obj, dict):
    sys.exit("setting/all failed: %s" % resp.get("msg"))
changed = False
for item in sys.argv[1:]:
    if item.startswith("?"):
        key, old, raw = item[1:].split("\t")
        if key not in obj:
            sys.exit("unknown setting key: %s" % key)
        if obj[key] != json.loads(old):
            continue
    else:
        key, raw = item.split("=", 1)
    val = json.loads(raw)
    if key not in obj:
        sys.exit("unknown setting key: %s" % key)
    if obj[key] != val:
        sys.stderr.write("  %s: %s -> %s\n" % (key, json.dumps(obj[key]), json.dumps(val)))
        obj[key] = val
        changed = True
if changed:
    print(json.dumps(obj, separators=(",", ":")))
'

cmd_configure_sub() {
    require_vars DOMAIN SUB_PATH
    [[ "$SUB_PATH" != "${PANEL_PATH:-}" && "$SUB_PATH" != "${XHTTP_PATH:-}" ]] ||
        die "SUB_PATH must differ from PANEL_PATH and XHTTP_PATH"
    api_session_start

    local resp body domain="${DOMAIN,,}"
    resp="$(api POST setting/all)" || die "API request setting/all failed"
    api_ok "$resp" || die "setting/all failed: $(api_msg "$resp") (response: ${resp:0:200})"
    # The sub server speaks plain HTTP on all addresses of the container;
    # nginx publishes it at https://DOMAIN/SUB_PATH/ (path passed unchanged).
    log "checking subscription settings (port $SUB_PORT, path /$SUB_PATH/)"
    body="$(printf '%s\n' "$resp" | xui_exec python3 -I -c "$SETTINGS_PATCH_PY" \
        'subEnable=true' 'subListen=""' "subPort=$SUB_PORT" \
        "subPath=$(json_str "/$SUB_PATH/")" "subDomain=$(json_str "$domain")" \
        "subURI=$(json_str "https://$domain/$SUB_PATH/")" \
        'subCertFile=""' 'subKeyFile=""' \
        "$(printf '?remarkTemplate\t%s\t%s' "$(json_str "$FACTORY_REMARK_TEMPLATE")" "$(json_str "$LINK_REMARK_TEMPLATE")")")" || die "could not prepare the subscription settings"
    if [[ -z "$body" ]]; then
        log "subscription settings already up to date"
        return 0
    fi
    resp="$(api POST setting/update "$body")" || die "API request setting/update failed"
    api_ok "$resp" || die "setting/update failed: $(api_msg "$resp") (response: ${resp:0:200})"
    # The subscription server reads its settings at start.
    log "restarting xui to apply the subscription settings"
    compose restart xui >/dev/null 2>&1 || die "failed to restart xui; see: docker compose logs xui"
    wait_panel
    wait_port "$SUB_PORT" "subscription server"
    log "subscriptions are served at https://$domain/$SUB_PATH/<subId>"
}

cmd_sub_links() {
    require_vars DOMAIN SUB_PATH
    api_session_start
    local resp ids id
    resp="$(api GET clients/list)" || die "API request clients/list failed"
    api_ok "$resp" || die "clients/list failed: $(api_msg "$resp") (response: ${resp:0:200})"
    ids="$(grep -o '"subId":[[:space:]]*"[^"]*"' <<<"$resp" | cut -d'"' -f4 | awk 'NF && !seen[$0]++')" || true
    [[ -n "$ids" ]] || {
        warn "no client with a subscription id found"
        return 0
    }
    while IFS= read -r id; do
        printf 'https://%s/%s/%s\n' "${DOMAIN,,}" "$SUB_PATH" "$id"
    done <<<"$ids"
}

# --- links ------------------------------------------------------------------------------

cmd_links() {
    require_vars DOMAIN CLIENT_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID XHTTP_PATH
    local name host path
    name="${LINK_NAME:-${APP_NAME:-vpn}}"
    host="$(urlencode "$DOMAIN")"
    path="$(urlencode "/$XHTTP_PATH")"

    printf 'vless://%s@%s:443?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$CLIENT_UUID" "$host" "$host" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$(urlencode "$name-reality")"
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&alpn=h2&fp=chrome&type=xhttp&host=%s&path=%s&mode=%s#%s\n' \
        "$CLIENT_UUID" "$host" "$host" "$host" "$path" "$XHTTP_MODE" "$(urlencode "$name-xhttp")"
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&alpn=h3&fp=chrome&type=xhttp&host=%s&path=%s&mode=%s#%s\n' \
        "$CLIENT_UUID" "$host" "$host" "$host" "$path" "$XHTTP_MODE" "$(urlencode "$name-xhttp-h3")"
}

# --- main --------------------------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        -h | --help | help)
            usage
            return 0
            ;;
        genkeys)
            need_cmd docker od
            # .env is optional here; only XUI_IMAGE is used.
            if [[ -f "$ENV_FILE" ]]; then load_env; fi
            : "${XUI_IMAGE:=ghcr.io/mhsanaei/3x-ui:v3.11.0}"
            cmd_genkeys
            ;;
        configure-panel | provision | configure-hosts | auto-hosts | configure-sub | sub-links)
            need_cmd docker od
            load_env
            validate_common
            "cmd_${cmd//-/_}"
            ;;
        links)
            load_env
            validate_common
            cmd_links
            ;;
        *)
            usage >&2
            die "unknown command: $cmd"
            ;;
    esac
}

main "$@"
