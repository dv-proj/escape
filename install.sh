#!/usr/bin/env bash
# install.sh - deploy a docker compose stack on Ubuntu/Debian: nginx (TLS
# termination, Let's Encrypt certificates) in front of the decoy web
# application (fake-webapp).
#
# Run `./install.sh --help` for usage. The services are defined in
# nginx/docker-compose.yml and fake-webapp/docker-compose.yml (both included
# by docker-compose.yml). This script makes sure Docker with the compose plugin
# is available (the system Docker is reused, Docker CE is installed only when
# there is none), generates .env, the decoy page and the nginx config, starts
# the stack, issues the certificate (certbot, webroot) and installs a renewal
# timer. nginx publishes ports 80 and 443 of the host; the app itself is
# reachable only inside the compose network. It never touches Xray, 3X-UI or
# the firewall.
#
# This file is the entry point: it only bootstraps the project and sources the
# modules from lib/ (i18n, common, gen, env, system, nginx, certs, app,
# extensions, commands) in the fixed order below. User-facing texts live in
# lib/lang/{en,ru}.sh (see lib/i18n.sh). Everything else lives in lib/*.sh.
set -Eeuo pipefail

# --- bootstrap (curl | bash) --------------------------------------------------------
# `curl -fsSL <raw-url>/install.sh | sudo bash -s -- install` runs this file
# without the rest of the project: clone it to FAKEAPP_DIR and continue from
# there. Skipped when the project files sit next to the script. Nothing from
# lib/ is needed before this point: the modules arrive with the clone.
FAKEAPP_REPO="${FAKEAPP_REPO:-https://github.com/dv-proj/escape.git}"
FAKEAPP_DIR="${FAKEAPP_DIR:-/opt/fakeapp}"
FAKEAPP_BRANCH="${FAKEAPP_BRANCH:-}"

bootstrap_project() {
    local src="${BASH_SOURCE[0]:-}" self_dir=""
    [[ -f "$src" ]] && self_dir="$(cd "$(dirname "$src")" && pwd)"
    if [[ -n "$self_dir" && -f "$self_dir/docker-compose.yml" && -f "$self_dir/.env.example" ]]; then
        return 0
    fi
    [[ $EUID -eq 0 ]] || { echo "error: run as root: curl -fsSL <url> | sudo bash -s -- install" >&2; exit 1; }
    echo "==> fetching the project into $FAKEAPP_DIR" >&2
    if ! command -v git >/dev/null 2>&1; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates >&2
    fi
    if [[ -d "$FAKEAPP_DIR/.git" ]]; then
        git -C "$FAKEAPP_DIR" pull --ff-only >&2
    else
        [[ ! -e "$FAKEAPP_DIR" || -z "$(ls -A "$FAKEAPP_DIR" 2>/dev/null)" ]] \
            || { echo "error: $FAKEAPP_DIR exists and is not a fakeapp checkout" >&2; exit 1; }
        git clone ${FAKEAPP_BRANCH:+--branch "$FAKEAPP_BRANCH"} "$FAKEAPP_REPO" "$FAKEAPP_DIR" >&2
    fi
    # No command given: the one-liner means "install".
    (($#)) || set -- install
    # stdin is the pipe with this script; give prompts the terminal if there is one.
    if [[ ! -t 0 && -r /dev/tty ]] && (: </dev/tty) 2>/dev/null; then
        exec "$FAKEAPP_DIR/install.sh" "$@" </dev/tty
    fi
    exec "$FAKEAPP_DIR/install.sh" "$@"
}
if [[ -z "${FAKEAPP_SH_LIB:-}" ]]; then
    bootstrap_project "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR"

# --- modules ------------------------------------------------------------------------
# The order is fixed here (functions only call each other at run time, but the
# variable defaults of a module may use those of an earlier one).
# shellcheck source=lib/i18n.sh
source "$SCRIPT_DIR/lib/i18n.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/gen.sh
source "$SCRIPT_DIR/lib/gen.sh"
# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/system.sh
source "$SCRIPT_DIR/lib/system.sh"
# shellcheck source=lib/nginx.sh
source "$SCRIPT_DIR/lib/nginx.sh"
# shellcheck source=lib/certs.sh
source "$SCRIPT_DIR/lib/certs.sh"
# shellcheck source=lib/app.sh
source "$SCRIPT_DIR/lib/app.sh"
# shellcheck source=lib/extensions.sh
source "$SCRIPT_DIR/lib/extensions.sh"
# shellcheck source=lib/commands.sh
source "$SCRIPT_DIR/lib/commands.sh"

# Sourcing with FAKEAPP_SH_LIB=1 only defines the functions (used by tests).
if [[ -n "${FAKEAPP_SH_LIB:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
main "$@"
