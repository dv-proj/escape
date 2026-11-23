# lib/common.sh - output helpers, die/step/on_err, confirm, the docker compose wrapper, shared paths and flags.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

# Directories and files derived from APP_DIR (the install directory). APP_DIR is
# known only after the install directory has been chosen (ask_install_dir) or
# found (resolve_app_dir), so init_paths fills these in at that point.
DATA_DIR=""
NGINX_DATA=""
LE_DIR=""
EXT_COMPOSE_FILE=""
EXT_CERTS_FILE=""

ASSUME_YES=0
WITH_EXT=""
PURGE=0
CURRENT_STEP="startup"
PROBLEMS=()
STEP_NO=0
STEP_TOTAL=0

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_BOLD="" C_RESET=""
fi

# init_paths: derive every data path from APP_DIR (all runtime data lives in
# $APP_DIR/data). Call it whenever APP_DIR is set or changed.
init_paths() {
    DATA_DIR="$APP_DIR/data"
    NGINX_DATA="$DATA_DIR/nginx"
    LE_DIR="$DATA_DIR/letsencrypt"
    EXT_COMPOSE_FILE="$DATA_DIR/extensions.compose.yml"
    EXT_CERTS_FILE="$NGINX_DATA/extra-certs.list"
}

info() { printf '    %s\n' "$*" >&2; }

ok() { printf '    %s%s:%s %s\n' "$C_GREEN" "$(t lbl.ok)" "$C_RESET" "$*" >&2; }

warn() { printf '%s%s:%s %s\n' "$C_YELLOW" "$(t lbl.warning)" "$C_RESET" "$*" >&2; }

die() {
    printf '%s%s:%s %s\n' "$C_RED" "$(t lbl.error)" "$C_RESET" "$*" >&2
    exit 1
}

step() {
    STEP_NO=$((STEP_NO + 1))
    CURRENT_STEP="$*"
    printf '\n%s%s%s\n' "$C_BOLD" "$(t common.step "$STEP_NO" "$STEP_TOTAL" "$*")" "$C_RESET" >&2
}

# phase N TITLE: banner of one of the three install phases (collect, validate,
# deploy; see cmd_install).
phase() {
    printf '\n%s%s%s\n' "$C_BOLD" "$(t common.phase "$1" "$2")" "$C_RESET" >&2
}

# problem MESSAGE...: record a fatal problem found while collecting or
# validating; finish_validation reports all of them at once.
problem() {
    PROBLEMS+=("$*")
}

# finish_validation: end of the validate phase. Prints every recorded problem
# and aborts (nothing has been changed yet), or returns when there are none.
finish_validation() {
    local p
    if ((!${#PROBLEMS[@]})); then
        ok "$(t common.all_valid)"
        return 0
    fi
    printf '\n%s%s:%s %s\n' "$C_RED" "$(t lbl.error)" "$C_RESET" "$(t common.problems_found "${#PROBLEMS[@]}")" >&2
    for p in "${PROBLEMS[@]}"; do
        printf '  - %s\n' "$p" >&2
    done
    exit 1
}

on_err() {
    local code=$? line=$1 cmd=$2 src="${BASH_SOURCE[1]:-install.sh}"
    src="${src#"${APP_DIR:-$CODE_DIR}"/}"
    # ERR is inherited by subshells (set -E): report only in the main shell,
    # which fires again when the subshell fails.
    [[ "$BASHPID" == "$$" ]] || return "$code"
    trap - ERR
    printf '\n%s%s:%s %s\n' "$C_RED" "$(t lbl.error)" "$C_RESET" \
        "$(t common.step_failed "$CURRENT_STEP" "$code" "$src" "$line" "$cmd")" >&2
}

# confirm QUESTION: ask y/N (always "yes" with --yes, "no" without a terminal).
confirm() {
    local question=$1 ans
    if ((ASSUME_YES)); then
        info "$(t common.assume_yes "$question")"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "$(t common.no_terminal "$question")"
        return 1
    fi
    read -r -p "$question $(t common.yn) " ans || return 1
    ans="${ans,,}"
    [[ "$ans" == y || "$ans" == yes || "$ans" == д || "$ans" == да ]]
}

# wait_for SECONDS DESCRIPTION CMD...: poll CMD once a second.
wait_for() {
    local secs=$1 desc=$2 i
    shift 2
    for ((i = 0; i < secs; i++)); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    die "$(t common.wait_timeout "$secs" "$desc")"
}

require_root() {
    [[ -z "${ESCAPE_TEST_SYNC_ONLY:-}" ]] || return 0
    ((EUID == 0)) || die "$(t common.need_root "$1" "$1")"
}

# compose ARGS...: docker compose in the project directory with a clean
# environment, so that nothing from the caller (APP_NAME, DOCKER_HOST, ...)
# overrides the values of .env.
compose() {
    ensure_ext_compose || true
    env -i -C "$APP_DIR" \
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "HOME=${HOME:-/root}" "LANG=C.UTF-8" "TERM=${TERM:-dumb}" \
        docker compose "$@"
}

# ensure_ext_compose: data/extensions.compose.yml is included by
# docker-compose.yml, so it must exist (empty: `services: {}`).
ensure_ext_compose() {
    [[ -f "$EXT_COMPOSE_FILE" ]] && return 0
    mkdir -p "$DATA_DIR" 2>/dev/null && printf 'services: {}\n' >"$EXT_COMPOSE_FILE" 2>/dev/null || return 1
    if [[ $EUID -eq 0 ]]; then chown "$(project_owner)" "$DATA_DIR" "$EXT_COMPOSE_FILE" 2>/dev/null || true; fi
}

# owner of the project directory: files created by the script get it.
project_owner() { stat -c '%u:%g' "$APP_DIR"; }
