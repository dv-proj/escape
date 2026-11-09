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
                   restart Xray. Requires a running xui container (run
                   configure-panel first). Idempotent.
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
  links            DOMAIN CLIENT_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID
                   XHTTP_PATH [LINK_NAME, default: APP_NAME or "vpn"]
  genkeys          [XUI_IMAGE]
EOF
}

REALITY_REMARK=reality
XHTTP_REMARK=xhttp
# Token name used for API access during provisioning; rotated (invalidated)
# again when provisioning finishes.
API_TOKEN_NAME=vpn-provision
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
    [[ -z "${REALITY_MAX_TIME_DIFF_MS:-}" ]] || validate REALITY_MAX_TIME_DIFF_MS '^[0-9]{1,9}$' "a non-negative integer in milliseconds (0 disables the check)"
    validate PANEL_PORT '^[0-9]{1,5}$' "a port number"
    validate XHTTP_PORT '^[0-9]{1,5}$' "a port number"
    validate NGINX_TLS_PORT '^[0-9]{1,5}$' "a port number"
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

wait_panel() {
    local i
    for ((i = 0; i < 60; i++)); do
        if xui_exec nc -z 127.0.0.1 "$PANEL_PORT" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    die "panel did not start listening on port $PANEL_PORT within 120s; see: docker compose logs xui"
}

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
        "$(json_str "$CLIENT_UUID")" "$(json_str "$2")" "$(json_str "$1")" "$(json_str "$(random_hex 8)")"
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

cmd_provision() {
    require_vars DOMAIN CLIENT_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID XHTTP_PATH
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
        configure-panel | provision)
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
