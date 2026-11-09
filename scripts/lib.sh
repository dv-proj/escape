#!/usr/bin/env bash
# Shared helpers for scripts/*.sh. Source it; do not execute.
#
# Provides: REPO_ROOT, ENV_FILE, load_env, require_vars, compose, data_dir,
#           service_running, log, warn, die, need_cmd.

# shellcheck disable=SC2034  # variables are used by the sourcing scripts

if [[ -n "${_VPN_LIB_LOADED:-}" ]]; then
    return 0
fi
_VPN_LIB_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Override with ENV_FILE=/path/to/file to use another env file.
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command '$c' not found in PATH"
    done
}

# load_env: read KEY=VALUE pairs from $ENV_FILE into the environment.
# Uses docker compose .env semantics (no shell evaluation): blank lines and
# '#' comments are skipped, an optional leading 'export ' is ignored, and one
# pair of surrounding single or double quotes is stripped. Variables already
# set in the environment win over the file (same as docker compose).
load_env() {
    [[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE (copy .env.example to .env and fill it in)"
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#export }"
        [[ "$line" == *=* ]] || {
            warn "ignoring malformed line in $ENV_FILE: $line"
            continue
        }
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            warn "ignoring invalid variable name in $ENV_FILE: $key"
            continue
        }
        if [[ ${#value} -ge 2 && ( ("${value:0:1}" == '"' && "${value: -1}" == '"') || ("${value:0:1}" == "'" && "${value: -1}" == "'") ) ]]; then
            value="${value:1:${#value}-2}"
        else
            # Unquoted: ' #' starts an inline comment (compose semantics).
            value="${value%%[[:space:]]#*}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        if [[ -z "${!key+x}" ]]; then
            export "$key=$value"
        fi
    done <"$ENV_FILE"

    # Defaults mirrored from docker-compose.yml.
    : "${PANEL_PORT:=2053}" "${XHTTP_PORT:=10000}" "${NGINX_TLS_PORT:=8443}"
    : "${DATA_DIR:=./data}" "${ACME_SERVER:=letsencrypt}"
    : "${XUI_IMAGE:=ghcr.io/mhsanaei/3x-ui:v3.11.0}"
    : "${NGINX_IMAGE:=nginx:1.31.8-alpine}"
    : "${ACME_IMAGE:=neilpang/acme.sh:3.1.6}"
    export PANEL_PORT XHTTP_PORT NGINX_TLS_PORT DATA_DIR ACME_SERVER XUI_IMAGE NGINX_IMAGE ACME_IMAGE
}

# require_vars VAR...: fail with a clear message if any variable is empty.
require_vars() {
    local v missing=()
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    ((${#missing[@]} == 0)) || die "missing required variable(s) in $ENV_FILE: ${missing[*]}"
}

# data_dir [SUBDIR]: absolute path of $DATA_DIR (relative to the repo root,
# like docker compose resolves it), optionally with a subdirectory appended.
data_dir() {
    local base="$DATA_DIR"
    [[ "$base" == /* ]] || base="$REPO_ROOT/${base#./}"
    if [[ $# -gt 0 ]]; then
        printf '%s/%s\n' "${base%/}" "$1"
    else
        printf '%s\n' "${base%/}"
    fi
}

# compose ARGS...: docker compose bound to this repo and env file. Runs from
# the repo root so docker-compose.yml (+ docker-compose.override.yml, or
# COMPOSE_FILE / COMPOSE_PROJECT_NAME if set) are picked up as usual.
compose() {
    (cd "$REPO_ROOT" && docker compose --env-file "$ENV_FILE" "$@")
}

# service_running SERVICE: true if the compose service has a running container.
service_running() {
    [[ -n "$(compose ps --status running --quiet "$1" 2>/dev/null)" ]]
}

require_running() {
    local s
    for s in "$@"; do
        service_running "$s" || die "service '$s' is not running (start the stack: docker compose up -d)"
    done
}
