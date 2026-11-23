# lib/system.sh - host checks (OS, tools), prerequisite packages, Docker detection and installation.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

PREREQ_PKGS=(curl ca-certificates iproute2 python3 openssl)
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

OS_REPO_DISTRO=""
OS_CODENAME=""

# shellcheck source=/dev/null
check_os() {
    [[ -r /etc/os-release ]] || die "$(t system.no_osrel)"
    local id version like codename ucodename pretty supported=0
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-0}")"
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    ucodename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-}")"
    pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$id}")"

    case "$id" in
        ubuntu) dpkg --compare-versions "$version" ge 22.04 && supported=1 ;;
        debian) dpkg --compare-versions "$version" ge 12 && supported=1 ;;
        *) ;;
    esac
    if ((supported)); then
        OS_REPO_DISTRO="$id"
        OS_CODENAME="${ucodename:-$codename}"
        [[ "$id" == debian ]] && OS_CODENAME="$codename"
        ok "$pretty"
        return 0
    fi
    warn "$(t system.unsupported "$pretty")"
    case " $id $like " in
        *" ubuntu "*) OS_REPO_DISTRO=ubuntu ;;
        *" debian "*) OS_REPO_DISTRO=debian ;;
        *) die "$(t system.no_base)" ;;
    esac
    OS_CODENAME="${ucodename:-$codename}"
    [[ -n "$OS_CODENAME" ]] || die "$(t system.no_codename)"
    confirm "$(t system.continue_anyway "$OS_REPO_DISTRO")" || die "$(t common.aborted)"
}

check_system_tools() {
    command -v apt-get >/dev/null 2>&1 || die "$(t system.no_apt)"
    command -v systemctl >/dev/null 2>&1 || die "$(t system.no_systemd)"
}

pkg_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]; }

# missing_pkgs PKG...: print the packages that are not installed yet.
missing_pkgs() {
    local p
    for p in "$@"; do
        pkg_installed "$p" || printf '%s\n' "$p"
    done
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >&2
}

APT_UPDATED=0

apt_update_once() {
    ((APT_UPDATED)) && return 0
    apt-get update >&2
    APT_UPDATED=1
}

install_prereqs() {
    local -a missing
    mapfile -t missing < <(missing_pkgs "${PREREQ_PKGS[@]}")
    if ((${#missing[@]})); then
        info "$(t system.installing_prereqs "${missing[*]}")"
        apt_update_once
        apt_install "${missing[@]}"
    else
        ok "$(t system.prereqs_ok "${PREREQ_PKGS[*]}")"
    fi
}

# add_docker_repo: the official Docker CE apt repository (signed-by keyring).
add_docker_repo() {
    local keyring=/etc/apt/keyrings/docker.asc
    local list=/etc/apt/sources.list.d/docker.sources
    local arch want
    check_os
    arch="$(dpkg --print-architecture)"
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s "$keyring" ]]; then
        info "$(t system.fetch_key)"
        curl -fsSL "https://download.docker.com/linux/$OS_REPO_DISTRO/gpg" -o "$keyring.tmp"
        mv -f "$keyring.tmp" "$keyring"
        chmod a+r "$keyring"
    fi
    want="Types: deb
URIs: https://download.docker.com/linux/$OS_REPO_DISTRO
Suites: $OS_CODENAME
Components: stable
Architectures: $arch
Signed-By: $keyring"
    if [[ "$(cat "$list" 2>/dev/null || true)" != "$want" ]]; then
        printf '%s\n' "$want" >"$list"
    fi
    APT_UPDATED=0
    apt_update_once
}

install_docker_ce() {
    info "$(t system.docker_missing)"
    add_docker_repo
    apt_install "${DOCKER_PKGS[@]}"
    systemctl enable --now docker.service >/dev/null 2>&1 || warn "$(t system.cant_enable_docker)"
}

# install_compose_plugin: add `docker compose` (v2) to an existing Docker.
install_compose_plugin() {
    info "$(t system.compose_missing)"
    if pkg_installed docker-ce; then
        add_docker_repo
        apt_install docker-compose-plugin docker-buildx-plugin
    elif pkg_installed docker.io; then
        apt_update_once
        apt_install docker-compose-v2 2>/dev/null || apt_install docker-compose ||
            die "$(t system.compose_manual_io)"
    else
        die "$(t system.docker_not_apt)"
    fi
}

# compose_version_ok: compose >= 2.20 (needed for `include` in docker-compose.yml).
compose_version_ok() {
    local v major minor
    v="$(docker compose version --short 2>/dev/null)" || return 1
    v="${v#v}"
    IFS=. read -r major minor _ <<<"$v"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    ((major > 2 || (major == 2 && minor >= 20)))
}

# ensure_docker: reuse the system Docker (start it if stopped); install Docker
# CE only when docker is missing, the compose plugin only when it is missing.
# A running rootful Docker (e.g. one that runs 3X-UI) is never reconfigured.
ensure_docker() {
    if command -v docker >/dev/null 2>&1; then
        ok "$(t system.docker_found "$(docker --version 2>/dev/null)")"
        if ! daemon_ok; then
            info "$(t system.daemon_start)"
            systemctl enable --now docker.service >/dev/null 2>&1 || true
            wait_for 30 "$(t system.desc_daemon)" daemon_ok
        fi
    else
        install_docker_ce
        wait_for 30 "$(t system.desc_daemon)" daemon_ok
        ok "$(docker --version)"
    fi
    compose_ok || install_compose_plugin
    compose_ok || die "$(t system.compose_na)"
    compose_version_ok ||
        die "$(t system.compose_old "$(docker compose version --short 2>/dev/null)")"
    ok "docker compose $(docker compose version --short)"
}

daemon_ok() { docker info >/dev/null 2>&1; }

compose_ok() { docker compose version >/dev/null 2>&1; }

require_docker() {
    command -v docker >/dev/null 2>&1 || die "$(t system.docker_not_found)"
    daemon_ok || die "$(t system.daemon_unreachable)"
}
