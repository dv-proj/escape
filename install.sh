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
# timer. nginx publishes ports 80 and 443 of the host (443: a TLS front that
# routes by SNI, the HTTPS server behind it gets the client address with the
# PROXY protocol); the app itself is reachable only inside the compose network.
# The base never touches Xray, 3X-UI or the firewall (optional extensions in
# extensions.d/ may, see their files).
#
# This file is the entry point: it only bootstraps the project and sources the
# modules from lib/ (i18n, common, instdir, gen, env, system, nginx, certs, app,
# extensions, commands) in the fixed order below. User-facing texts live in
# lib/lang/{en,ru}.sh (see lib/i18n.sh). Everything else lives in lib/*.sh.
#
# Where things live (see README.md, "Install directory"): the project is never
# run from a git checkout. `install` copies an allowlist of the sources (the
# checkout this script sits in, or a downloaded tarball) into the install
# directory (default /opt/escape, ESCAPE_DIR / --dir) and continues from the
# installed copy; the installed copy is what start/stop/status/renew/remove run.
# lib/instdir.sh has the details (and the ESCAPE_TEST_* variables for tests).
set -Eeuo pipefail

# --- bootstrap (curl | bash) --------------------------------------------------------
# `curl -fsSL <raw-url>/install.sh | sudo bash -s -- install` runs this file
# without the rest of the project: download the repository as a tarball (curl,
# no git) into a temporary directory, run the install.sh from it with the same
# arguments and delete the directory on exit. Skipped when the project files sit
# next to the script. Nothing from lib/ is needed before this point.
#   ESCAPE_REPO_URL  base URL of the archive host (default: codeload.github.com/dv-proj/escape);
#                    the archive is <base>/tar.gz/<ref>  (ref: branch, tag or commit hash)
#   ESCAPE_BRANCH    branch to download (default: main; FAKEAPP_BRANCH is a deprecated alias)
ESCAPE_REPO_URL="${ESCAPE_REPO_URL:-https://codeload.github.com/dv-proj/escape}"
ESCAPE_BRANCH="${ESCAPE_BRANCH:-${FAKEAPP_BRANCH:-main}}"

bootstrap_project() {
    local src="${BASH_SOURCE[0]:-}" self_dir="" tmp url rc=0
    [[ -f "$src" ]] && self_dir="$(cd "$(dirname "$src")" && pwd)"
    if [[ -n "$self_dir" && -f "$self_dir/docker-compose.yml" && -f "$self_dir/.env.example" && -d "$self_dir/lib" ]]; then
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        [[ $EUID -eq 0 ]] || { echo "error: curl and tar are required (install them, or run as root)" >&2; exit 1; }
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar ca-certificates >&2
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    url="${ESCAPE_REPO_URL%/}/tar.gz/$ESCAPE_BRANCH"
    echo "==> downloading $url" >&2
    mkdir "$tmp/src"
    curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$tmp/escape.tar.gz" ||
        { echo "error: cannot download $url" >&2; exit 1; }
    tar -xzf "$tmp/escape.tar.gz" -C "$tmp/src" --strip-components=1 ||
        { echo "error: cannot unpack the downloaded archive" >&2; exit 1; }
    [[ -f "$tmp/src/install.sh" && -f "$tmp/src/docker-compose.yml" && -d "$tmp/src/lib" ]] ||
        { echo "error: the downloaded archive is not the escape project (no install.sh / lib/)" >&2; exit 1; }
    # No command given: the one-liner means "install".
    (($#)) || set -- install
    # stdin is the pipe with this script; give prompts the terminal if there is one.
    if [[ ! -t 0 && -r /dev/tty ]] && (: </dev/tty) 2>/dev/null; then
        bash "$tmp/src/install.sh" "$@" </dev/tty || rc=$?
    else
        bash "$tmp/src/install.sh" "$@" || rc=$?
    fi
    exit "$rc"
}
if [[ -z "${FAKEAPP_SH_LIB:-}" ]]; then
    bootstrap_project "$@"
fi

# Directory of this install.sh: where lib/, extensions.d/ and the message files are
# read from. APP_DIR (the install directory: .env, data/) is set by lib/instdir.sh.
CODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR=""

# --- modules ------------------------------------------------------------------------
# The order is fixed here (functions only call each other at run time, but the
# variable defaults of a module may use those of an earlier one).
# shellcheck source=lib/i18n.sh
source "$CODE_DIR/lib/i18n.sh"
# shellcheck source=lib/common.sh
source "$CODE_DIR/lib/common.sh"
# shellcheck source=lib/instdir.sh
source "$CODE_DIR/lib/instdir.sh"
# shellcheck source=lib/gen.sh
source "$CODE_DIR/lib/gen.sh"
# shellcheck source=lib/env.sh
source "$CODE_DIR/lib/env.sh"
# shellcheck source=lib/system.sh
source "$CODE_DIR/lib/system.sh"
# shellcheck source=lib/nginx.sh
source "$CODE_DIR/lib/nginx.sh"
# shellcheck source=lib/certs.sh
source "$CODE_DIR/lib/certs.sh"
# shellcheck source=lib/app.sh
source "$CODE_DIR/lib/app.sh"
# shellcheck source=lib/extensions.sh
source "$CODE_DIR/lib/extensions.sh"
# shellcheck source=lib/commands.sh
source "$CODE_DIR/lib/commands.sh"

# Sourcing with FAKEAPP_SH_LIB=1 only defines the functions (used by tests).
if [[ -n "${FAKEAPP_SH_LIB:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
main "$@"
