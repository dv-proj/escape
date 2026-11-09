#!/usr/bin/env bash
# vpn.sh - deploy and manage the personal VPN stack (3X-UI/Xray REALITY+XHTTP,
# nginx, acme.sh, decoy web app) with rootless Docker on Ubuntu/Debian.
#
# Run `./vpn.sh --help` for usage. The stack itself lives in docker-compose.yml;
# this script prepares the host (packages, unprivileged user, rootless Docker),
# copies the project to the user's home, generates .env and runs the helper
# scripts in scripts/ in the right order.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VPN_USER="${VPN_USER:-vpn}"
VPN_DIR="${VPN_DIR:-}" # resolved by init_paths (default: ~VPN_USER/vpn-stack)
VPN_HOME=""
VPN_UID=""

SYSCTL_FILE=/etc/sysctl.d/99-vpn-rootless.conf
APPARMOR_FILE=/etc/apparmor.d/usr.bin.rootlesskit
MANAGED_MARK="# managed by vpn.sh"

PREREQ_PKGS=(uidmap dbus-user-session slirp4netns fuse-overlayfs curl ca-certificates iproute2 iptables)
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin)

ASSUME_YES=0
PURGE=0
CURRENT_STEP="startup"
STEP_NO=0
STEP_TOTAL=0
ROOTFUL_DOCKER_WAS_ACTIVE=0
OS_REPO_DISTRO=""
OS_CODENAME=""

# --- output -----------------------------------------------------------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_BOLD="" C_RESET=""
fi

info() { printf '    %s\n' "$*" >&2; }
ok() { printf '    %sok:%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
    printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}
step() {
    STEP_NO=$((STEP_NO + 1))
    CURRENT_STEP="$*"
    printf '\n%s==> [%d/%d] %s%s\n' "$C_BOLD" "$STEP_NO" "$STEP_TOTAL" "$*" "$C_RESET" >&2
}

on_err() {
    local code=$? line=$1 cmd=$2
    trap - ERR
    printf '\n%serror:%s step "%s" failed (exit %d) at vpn.sh line %s: %s\n' \
        "$C_RED" "$C_RESET" "$CURRENT_STEP" "$code" "$line" "$cmd" >&2
}

usage() {
    cat <<'EOF'
Usage: ./vpn.sh [options] <command>

Deploys and manages the personal VPN stack (3X-UI/Xray REALITY+XHTTP, nginx,
acme.sh, decoy web app) using rootless Docker under a dedicated unprivileged
user. Target systems: Ubuntu 24.04+ and Debian 12+.

Commands:
  deploy    Full idempotent setup (root): packages, rootless Docker for the VPN
            user, project copy, .env generation, certificates, stack start,
            panel/inbound provisioning. Prints panel URL, credentials and client
            links. Re-running updates files and restarts the stack without
            regenerating secrets.
  start     Start the stack (docker compose up -d --wait).
  stop      Stop the stack (docker compose stop).
  restart   Stop and start the stack.
  status    Show container and certificate status.
  links     Print panel URL/credentials and client links.
  remove    Remove the containers and built images (root). With --purge also
            deletes all data (certs, panel DB), the rootless Docker install,
            the VPN user and the sysctl file. Packages are never removed.

Options:
  -y, --yes   Assume "yes" for every confirmation (OS warning, DNS mismatch,
              disabling a running rootful Docker, remove/purge).
  --purge     With `remove`: also delete data, rootless Docker and the user.
  -h, --help  Show this help.

Environment:
  VPN_USER    Unprivileged user that runs the stack (default: vpn).
  VPN_DIR     Project directory of the deployed copy
              (default: <home of VPN_USER>/vpn-stack).
  DOMAIN, ACME_EMAIL, APP_NAME
              If set when .env is created by `deploy`, they are used without
              prompting (non-interactive mode). APP_DESCRIPTION, APP_KEYWORDS and
              PANEL_USERNAME are honoured the same way. Without a terminal, all
              other prompts silently use their defaults.

Notes:
  * deploy/remove must run as root; the other commands may run as root or as
    VPN_USER.
  * An existing $VPN_DIR/.env is reused as is and nothing is asked.
  * Firewall rules are not touched: open 80/tcp, 443/tcp and 443/udp yourself.
EOF
}

# --- generic helpers ----------------------------------------------------------------

# confirm QUESTION: ask y/N (always "yes" with --yes, "no" without a terminal).
confirm() {
    local question=$1 ans
    if ((ASSUME_YES)); then
        info "$question -> yes (--yes)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "$question (no terminal; re-run with --yes to accept)"
        return 1
    fi
    read -r -p "$question [y/N] " ans || return 1
    ans="${ans,,}"
    [[ "$ans" == y || "$ans" == yes ]]
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
    die "timed out after ${secs}s waiting for $desc"
}

require_root() {
    ((EUID == 0)) || die "'$1' must be run as root (try: sudo ./vpn.sh $1)"
}

# --- paths and running things as the VPN user ------------------------------------------

# init_paths: resolve VPN_HOME, VPN_UID and VPN_DIR (works before the user exists).
init_paths() {
    local entry=""
    if entry="$(getent passwd "$VPN_USER")"; then
        VPN_HOME="$(cut -d: -f6 <<<"$entry")"
        VPN_UID="$(cut -d: -f3 <<<"$entry")"
    else
        VPN_HOME="/home/$VPN_USER"
        VPN_UID=""
    fi
    : "${VPN_DIR:=$VPN_HOME/vpn-stack}"
}

# _vpn_exec DIR CMD...: run CMD as VPN_USER with a clean environment, cwd DIR.
# The environment is rebuilt with `env -i` so that nothing from the caller
# (DOMAIN, ENV_FILE, DOCKER_HOST, ...) leaks into compose or the helper scripts.
# XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS point at the user's systemd
# instance (it exists thanks to lingering), which makes `systemctl --user` and
# dockerd-rootless-setuptool.sh work without a login session. `runuser` is
# used instead of machinectl/systemd-run/sudo: it is part of util-linux
# (always present), needs no PAM session or password and passes stdin through.
_vpn_exec() {
    local dir=$1
    shift
    local -a e=(
        "HOME=$VPN_HOME" "USER=$VPN_USER" "LOGNAME=$VPN_USER"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "LANG=C.UTF-8" "TERM=${TERM:-dumb}"
        "XDG_RUNTIME_DIR=/run/user/$VPN_UID"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$VPN_UID/bus"
        "DOCKER_HOST=unix:///run/user/$VPN_UID/docker.sock"
    )
    if [[ "$(id -u)" == "$VPN_UID" ]]; then
        env -i -C "$dir" "${e[@]}" "$@"
    else
        (cd / && runuser -u "$VPN_USER" -- env -i -C "$dir" "${e[@]}" "$@")
    fi
}
as_vpn() { _vpn_exec "$VPN_HOME" "$@"; }   # cwd = home
in_stack() { _vpn_exec "$VPN_DIR" "$@"; }  # cwd = project dir

docker_ready() { as_vpn docker info >/dev/null 2>&1; }

# --- .env helpers (also used by the unit test via VPN_SH_LIB=1) ----------------------

# env_get FILE KEY: value of KEY (last occurrence, one pair of quotes stripped).
env_get() {
    local file=$1 key=$2 line v result=""
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
        v="${BASH_REMATCH[1]}"
        v="${v#"${v%%[![:space:]]*}"}"
        if [[ ${#v} -ge 2 && ( ("${v:0:1}" == '"' && "${v: -1}" == '"') || ("${v:0:1}" == "'" && "${v: -1}" == "'") ) ]]; then
            v="${v:1:${#v}-2}"
        else
            v="${v%%[[:space:]]#*}"
            v="${v%"${v##*[![:space:]]}"}"
        fi
        result="$v"
    done <"$file"
    printf '%s' "$result"
}

valid_domain() {
    local re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
    [[ "$1" =~ $re && ${#1} -le 253 ]] || return 1
    [[ "${1,,}" != example.com && "${1,,}" != *.example.com ]]
}
valid_email() {
    local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    [[ "$1" =~ $re ]] || return 1
    [[ "${1,,}" != *@example.com ]]
}
# Free text that is safe inside a docker compose .env value.
valid_text() {
    [[ -n "$1" && ${#1} -le 200 ]] || return 1
    [[ ! "$1" =~ [\'\"\$\`\\[:cntrl:]] ]]
}
valid_username() { [[ "$1" =~ ^[A-Za-z0-9_.-]{3,32}$ ]]; }
valid_tz() { [[ "$1" =~ ^[A-Za-z0-9_+/-]{1,64}$ ]]; }

# rand_str LENGTH CHARSET: random string from /dev/urandom.
rand_str() {
    local n=$1 set=$2 out=""
    while ((${#out} < n)); do
        out+="$(LC_ALL=C tr -dc "$set" </dev/urandom | head -c "$n" || true)"
    done
    printf '%s' "${out:0:n}"
}

# fmt_env_value VALUE: bare when plain, single-quoted otherwise (literal for
# docker compose, and stripped by scripts/lib.sh). Callers reject ' and $.
fmt_env_value() {
    if [[ "$1" =~ ^[A-Za-z0-9_./:@+,-]*$ ]]; then
        printf '%s' "$1"
    else
        printf "'%s'" "$1"
    fi
}

host_timezone() {
    local tz=""
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    [[ -n "$tz" ]] || tz="$(head -n1 /etc/timezone 2>/dev/null || true)"
    valid_tz "$tz" || tz=UTC
    printf '%s' "$tz"
}

declare -gA ENV_VALUES=()

# ask KEY LABEL DEFAULT VALIDATOR HINT: store the value in ENV_VALUES[KEY].
# A non-empty KEY in the environment is used without prompting; without a
# terminal the default is used (an empty default means the value is required).
ask() {
    local key=$1 label=$2 default=$3 validator=$4 hint=$5 value=""
    if [[ -n "${!key:-}" ]]; then
        value="${!key}"
        "$validator" "$value" || die "$key from the environment is invalid: expected $hint"
        info "$key (from environment): $value"
    elif [[ ! -t 0 ]]; then
        [[ -n "$default" ]] || die "$key is required (set it in the environment; no terminal to ask)"
        value="$default"
        "$validator" "$value" || die "default for $key is invalid: expected $hint"
        info "$key (default): $value"
    else
        while :; do
            if [[ -n "$default" ]]; then
                read -r -p "$label [$default]: " value || die "no input"
            else
                read -r -p "$label: " value || die "no input"
            fi
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value:-$default}"
            if "$validator" "$value"; then
                break
            fi
            warn "invalid value; expected $hint"
        done
    fi
    ENV_VALUES[$key]="$value"
}

# gen_random_data_suffix: lowercase hex, 8-12 chars.
gen_random_data_suffix() { rand_str $((8 + RANDOM % 5)) '0-9a-f'; }

# gen_page_seed: 32 lowercase hex chars (seed of the decoy login page variant).
gen_page_seed() { rand_str 32 '0-9a-f'; }

# ensure_generated_key FILE KEY GENERATOR_FN: append KEY=<generated> to an existing
# .env when KEY is missing or empty; other lines are left untouched.
ensure_generated_key() {
    local file=$1 key=$2 gen=$3 val tmp line found=0
    [[ -n "$(env_get "$file" "$key")" ]] && return 0
    val="$("$gen")" || die "cannot generate $key"
    [[ -n "$val" ]] || die "generator for $key returned nothing"
    tmp="$(mktemp "$file.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^${key}=[[:space:]]*$ ]]; then
            printf '%s=%s\n' "$key" "$(fmt_env_value "$val")" >>"$tmp"
            found=1
        else
            printf '%s\n' "$line" >>"$tmp"
        fi
    done <"$file"
    ((found)) || printf '%s=%s\n' "$key" "$(fmt_env_value "$val")" >>"$tmp"
    chmod --reference="$file" "$tmp"
    if [[ $EUID -eq 0 ]]; then chown --reference="$file" "$tmp"; fi
    mv -f "$tmp" "$file"
    info "added missing $key to $file"
}

# gen_secrets: print REALITY_*/CLIENT_UUID lines. Overridden in tests.
gen_secrets() {
    in_stack scripts/xui.sh genkeys
}

# generate_env EXAMPLE OUT: build OUT (mode 600) from EXAMPLE, prompting for
# manual values and generating secrets. Never edits with sed: the template is
# rewritten line by line, so special characters in values are harmless.
generate_env() {
    local example=$1 out=$2 line key k v tmp def_tz
    [[ -f "$example" ]] || die "template not found: $example"
    ENV_VALUES=()

    local d
    d="$(env_get "$example" APP_NAME)"
    ask DOMAIN "Domain name (A record must point to this server)" "" valid_domain "a fully qualified domain name (not example.com)"
    ENV_VALUES[DOMAIN]="${ENV_VALUES[DOMAIN],,}"
    ask ACME_EMAIL "E-mail for Let's Encrypt" "" valid_email "an e-mail address (not @example.com)"
    ask APP_NAME "Decoy site name" "$d" valid_text "1-200 characters without ' \" \$ \` \\"
    d="$(env_get "$example" APP_DESCRIPTION)"
    ask APP_DESCRIPTION "Decoy site description" "$d" valid_text "1-200 characters without ' \" \$ \` \\"
    d="$(env_get "$example" APP_KEYWORDS)"
    ask APP_KEYWORDS "Decoy site keywords" "$d" valid_text "1-200 characters without ' \" \$ \` \\"
    ask PANEL_USERNAME "Panel username" "admin" valid_username "3-32 characters: letters, digits, _ . -"
    def_tz="$(host_timezone)"
    # TZ is deliberately not read from the environment (often set to odd values).
    local saved_tz="${TZ-__unset__}"
    unset TZ
    ask TZ "Time zone" "$def_tz" valid_tz "an IANA zone like Europe/Berlin"
    if [[ "$saved_tz" != __unset__ ]]; then export TZ="$saved_tz"; fi

    # Generated values.
    local ppath xpath
    ppath="$(rand_str $((16 + RANDOM % 9)) 'a-z0-9')"
    xpath="$ppath"
    while [[ "$xpath" == "$ppath" ]]; do
        xpath="$(rand_str $((16 + RANDOM % 9)) 'a-z0-9')"
    done
    ENV_VALUES[PANEL_PATH]="$ppath"
    ENV_VALUES[XHTTP_PATH]="$xpath"
    ENV_VALUES[PANEL_PASSWORD]="$(rand_str 28 'A-Za-z0-9')"
    ENV_VALUES[RANDOM_DATA_SUFFIX]="$(gen_random_data_suffix)"
    ENV_VALUES[PAGE_SEED]="$(gen_page_seed)"

    local keys_out
    keys_out="$(gen_secrets)" || die "key generation failed"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" =~ ^(REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID|CLIENT_UUID)=([A-Za-z0-9_=-]+)$ ]]; then
            ENV_VALUES[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
        else
            die "unexpected output from genkeys: $line"
        fi
    done <<<"$keys_out"
    for k in REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID CLIENT_UUID; do
        [[ -n "${ENV_VALUES[$k]:-}" ]] || die "genkeys did not return $k"
    done

    # Rewrite the template.
    local old_umask
    old_umask="$(umask)"
    umask 077
    tmp="$(mktemp "$out.XXXXXX")"
    umask "$old_umask"
    declare -A done_keys=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            if [[ -n "${ENV_VALUES[$key]+x}" ]]; then
                printf '%s=%s\n' "$key" "$(fmt_env_value "${ENV_VALUES[$key]}")" >>"$tmp"
                done_keys[$key]=1
                continue
            fi
        fi
        printf '%s\n' "$line" >>"$tmp"
    done <"$example"
    for k in "${!ENV_VALUES[@]}"; do
        [[ -n "${done_keys[$k]+x}" ]] || printf '%s=%s\n' "$k" "$(fmt_env_value "${ENV_VALUES[$k]}")" >>"$tmp"
    done
    chmod 600 "$tmp"

    # Every key of the template must end up with a value.
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        k="${BASH_REMATCH[1]}"
        v="$(env_get "$tmp" "$k")"
        if [[ -z "$v" ]]; then
            rm -f "$tmp"
            die "generated .env has an empty value for $k"
        fi
    done <"$example"
    mv -f "$tmp" "$out"
}

# --- host checks ---------------------------------------------------------------------------

# shellcheck source=/dev/null
check_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found: unsupported system"
    local id version like codename ucodename pretty supported=0
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-0}")"
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    ucodename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-}")"
    pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$id}")"

    case "$id" in
        ubuntu) dpkg --compare-versions "$version" ge 24.04 && supported=1 ;;
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
    warn "$pretty is not supported (need Ubuntu 24.04+ or Debian 12+)"
    case " $id $like " in
        *" ubuntu "*) OS_REPO_DISTRO=ubuntu ;;
        *" debian "*) OS_REPO_DISTRO=debian ;;
        *) die "no Debian/Ubuntu base detected; the Docker apt repository cannot be configured" ;;
    esac
    OS_CODENAME="${ucodename:-$codename}"
    [[ -n "$OS_CODENAME" ]] || die "cannot determine the distribution codename"
    confirm "Continue anyway using the $OS_REPO_DISTRO Docker repository?" || die "aborted"
}

check_system_tools() {
    command -v apt-get >/dev/null 2>&1 || die "apt-get not found"
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || die "systemd is required (not running as PID 1?)"
    command -v loginctl >/dev/null 2>&1 || die "loginctl not found"
    command -v runuser >/dev/null 2>&1 || die "runuser not found (util-linux)"
}

# Rootful Docker must not be used by this stack. If it is running before we
# install anything, the person already uses it: ask before stopping it.
check_rootful_docker() {
    if systemctl is-active --quiet docker.service 2>/dev/null || systemctl is-active --quiet docker.socket 2>/dev/null; then
        ROOTFUL_DOCKER_WAS_ACTIVE=1
        warn "the system-wide (rootful) Docker daemon is running; this stack uses rootless Docker."
        warn "Deploying disables docker.service and docker.socket (running rootful containers will be stopped)."
        confirm "Disable the rootful Docker daemon?" || die "aborted; nothing was changed"
    fi
}

disable_rootful_docker() {
    local unit
    for unit in docker.service docker.socket; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            if ((ROOTFUL_DOCKER_WAS_ACTIVE)); then
                info "disabling $unit"
            fi
            systemctl disable --now "$unit" >/dev/null 2>&1 || warn "could not disable $unit"
        fi
    done
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

install_packages() {
    local -a missing
    mapfile -t missing < <(missing_pkgs "${PREREQ_PKGS[@]}")
    if ((${#missing[@]})); then
        info "installing prerequisites: ${missing[*]}"
        apt-get update >&2
        apt_install "${missing[@]}"
    else
        ok "prerequisites already installed"
    fi

    # Docker CE from the official repository (signed-by keyring).
    local keyring=/etc/apt/keyrings/docker.asc
    local list=/etc/apt/sources.list.d/docker.sources
    local arch repo_changed=0 want
    arch="$(dpkg --print-architecture)"
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s "$keyring" ]]; then
        info "fetching the Docker repository key"
        curl -fsSL "https://download.docker.com/linux/$OS_REPO_DISTRO/gpg" -o "$keyring.tmp"
        mv -f "$keyring.tmp" "$keyring"
        chmod a+r "$keyring"
        repo_changed=1
    fi
    want="Types: deb
URIs: https://download.docker.com/linux/$OS_REPO_DISTRO
Suites: $OS_CODENAME
Components: stable
Architectures: $arch
Signed-By: $keyring"
    if [[ "$(cat "$list" 2>/dev/null || true)" != "$want" ]]; then
        printf '%s\n' "$want" >"$list"
        repo_changed=1
    fi

    mapfile -t missing < <(missing_pkgs "${DOCKER_PKGS[@]}")
    if ((${#missing[@]})); then
        info "installing Docker CE packages: ${missing[*]}"
        apt-get update >&2
        apt_install "${missing[@]}"
    else
        if ((repo_changed)); then apt-get update >&2; fi
        ok "Docker packages already installed"
    fi
}

# --- user, sysctl, rootless docker -------------------------------------------------------------

# next_sub_start FILE: first free subordinate id start (>= 100000).
next_sub_start() {
    awk -F: 'BEGIN{n=100000} $2+$3>n{n=$2+$3} END{print n}' "$1" 2>/dev/null || echo 100000
}

ensure_user() {
    if getent passwd "$VPN_USER" >/dev/null; then
        ok "user $VPN_USER exists"
    else
        info "creating user $VPN_USER"
        # A regular (non-system) account: gets a home directory and subordinate
        # uid/gid ranges; login is impossible (no shell, no password).
        useradd --create-home --home-dir "/home/$VPN_USER" --shell /usr/sbin/nologin \
            --comment "VPN stack (rootless docker)" "$VPN_USER"
    fi
    init_paths
    [[ "$VPN_UID" != 0 ]] || die "VPN_USER must not be root"

    local f start
    for f in /etc/subuid /etc/subgid; do
        touch "$f"
        if ! grep -q "^$VPN_USER:" "$f"; then
            start="$(next_sub_start "$f")"
            printf '%s:%s:65536\n' "$VPN_USER" "$start" >>"$f"
            info "added $f range $start+65536 for $VPN_USER"
        fi
    done

    info "enabling lingering (user services survive logout and start at boot)"
    loginctl enable-linger "$VPN_USER"
    systemctl start "user@${VPN_UID}.service" >/dev/null 2>&1 || true
    wait_for 30 "the systemd user session of $VPN_USER" test -S "/run/user/$VPN_UID/bus"
}

write_if_changed() { # FILE MODE (content on stdin) -> returns 0 if changed
    local file=$1 mode=$2 new
    new="$(cat)"
    if [[ -f "$file" && "$(cat "$file")" == "$new" ]]; then
        return 1
    fi
    printf '%s\n' "$new" >"$file"
    chmod "$mode" "$file"
    return 0
}

configure_sysctl() {
    local note=""
    if write_if_changed "$SYSCTL_FILE" 644 <<EOF
$MANAGED_MARK
# Allow the unprivileged rootless-docker user to publish ports 80 and 443.
net.ipv4.ip_unprivileged_port_start=80
EOF
    then
        note=", written"
    fi
    sysctl -q -w net.ipv4.ip_unprivileged_port_start=80
    ok "net.ipv4.ip_unprivileged_port_start=80 ($SYSCTL_FILE$note)"

    # Ubuntu 24.04 blocks unprivileged user namespaces through AppArmor; rootlesskit
    # needs an exception (see the Docker rootless documentation).
    if [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" == 1 ]] &&
        command -v apparmor_parser >/dev/null 2>&1; then
        local other
        other="$(grep -rls '/usr/bin/rootlesskit' /etc/apparmor.d 2>/dev/null | grep -vx "$APPARMOR_FILE" || true)"
        if [[ -n "$other" ]]; then
            ok "AppArmor profile for rootlesskit already provided by $other"
        else
            write_if_changed "$APPARMOR_FILE" 644 <<EOF || true
$MANAGED_MARK
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,

  include if exists <local/usr.bin.rootlesskit>
}
EOF
            apparmor_parser -r "$APPARMOR_FILE"
            ok "AppArmor profile allowing user namespaces for rootlesskit loaded"
        fi
    fi
}

install_rootless_docker() {
    local cfg="$VPN_HOME/.config/systemd/user"
    local dropin_dir="$cfg/docker.service.d" dropin="$cfg/docker.service.d/vpn-rootless.conf"
    local unit_existed=0 changed=0
    [[ -f "$cfg/docker.service" ]] && unit_existed=1

    # The slirp4netns port driver preserves the real client source IPs (the
    # default "builtin" driver shows every client as 10.0.2.2/127.0.0.1).
    as_vpn mkdir -p "$dropin_dir"
    if ! [[ -f "$dropin" ]] || [[ "$(cat "$dropin")" != "$(drop_in_content)" ]]; then
        drop_in_content | as_vpn tee "$dropin" >/dev/null
        changed=1
        info "wrote $dropin"
    fi

    if ((unit_existed)); then
        ok "rootless Docker is already installed for $VPN_USER"
    else
        info "running dockerd-rootless-setuptool.sh install as $VPN_USER"
        as_vpn dockerd-rootless-setuptool.sh install >&2
    fi
    as_vpn systemctl --user daemon-reload
    as_vpn systemctl --user enable docker.service >/dev/null 2>&1
    if ((changed && unit_existed)); then
        as_vpn systemctl --user restart docker.service
    else
        as_vpn systemctl --user start docker.service
    fi
    wait_for 60 "rootless dockerd" docker_ready
    verify_rootless
}

drop_in_content() {
    cat <<'EOF'
# managed by vpn.sh
[Service]
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns"
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns"
EOF
}

verify_rootless() {
    local sec
    sec="$(as_vpn docker info --format '{{json .SecurityOptions}}')"
    [[ "$sec" == *rootless* ]] || die "docker for $VPN_USER is not running in rootless mode (SecurityOptions: $sec)"
    ok "docker for $VPN_USER is rootless ($(as_vpn docker info --format '{{.ServerVersion}}'))"
}

# docker_up_or_start: true if rootless dockerd answers (starting it if needed).
docker_up_or_start() {
    local i
    docker_ready && return 0
    as_vpn systemctl --user start docker.service >/dev/null 2>&1 || true
    for ((i = 0; i < 30; i++)); do
        docker_ready && return 0
        sleep 1
    done
    return 1
}

ensure_docker_running() {
    docker_up_or_start || die "rootless docker of $VPN_USER is not running (see: journalctl _UID=$VPN_UID)"
}

# --- project -------------------------------------------------------------------------------------

sync_project() {
    if [[ "$(realpath "$SCRIPT_DIR")" == "$(realpath -m "$VPN_DIR")" ]]; then
        ok "running from $VPN_DIR; nothing to copy"
        return 0
    fi
    mkdir -p "$(dirname "$VPN_DIR")"
    install -d -o "$VPN_USER" -g "$VPN_USER" -m 750 "$VPN_DIR"
    info "$SCRIPT_DIR -> $VPN_DIR (excluding .git, data, .env, .idea, .claude)"
    # Extracting as VPN_USER makes every file owned by that user (data/ is
    # never touched: it holds files owned by subordinate ids).
    tar -C "$SCRIPT_DIR" --anchored --exclude=./.git --exclude=./data --exclude=./.env \
        --exclude=./.idea --exclude=./.claude -cf - . |
        _vpn_exec "$VPN_DIR" tar -xf - --no-same-owner
    ok "project files are up to date"
}

setup_env() {
    local envf="$VPN_DIR/.env"
    if [[ -f "$envf" ]]; then
        ok "$envf exists; reusing it (no questions asked)"
        ensure_generated_key "$envf" RANDOM_DATA_SUFFIX gen_random_data_suffix
        ensure_generated_key "$envf" PAGE_SEED gen_page_seed
        return 0
    fi
    [[ -f "$VPN_DIR/.env.example" ]] || die "$VPN_DIR/.env.example is missing"
    info "creating $envf"
    generate_env "$VPN_DIR/.env.example" "$envf"
    chown "$VPN_USER:$VPN_USER" "$envf"
    chmod 600 "$envf"
    ok "$envf written (mode 600)"
}

# --- network pre-flight ---------------------------------------------------------------------------

check_dns() {
    local domain=$1 resolved server="" ip
    resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    server="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    local local_ip
    local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
    info "$domain resolves to: ${resolved//$'\n'/ }"
    info "this server: public ${server:-unknown}, primary ${local_ip:-unknown}"
    for ip in $resolved; do
        if [[ "$ip" == "$server" || "$ip" == "$local_ip" ]]; then
            ok "DNS for $domain points to this server"
            return 0
        fi
    done
    warn "$domain does not resolve to an address of this server; Let's Encrypt validation will fail"
    confirm "Continue anyway?" || die "aborted: fix the DNS record for $domain and run deploy again"
}

firewall_note() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        warn "ufw is active: make sure 80/tcp, 443/tcp and 443/udp are allowed (e.g. ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 443/udp)"
    fi
}

# --- summary ---------------------------------------------------------------------------------------

print_summary() {
    local envf="$VPN_DIR/.env" domain ppath puser ppass
    domain="$(env_get "$envf" DOMAIN)"
    ppath="$(env_get "$envf" PANEL_PATH)"
    puser="$(env_get "$envf" PANEL_USERNAME)"
    ppass="$(env_get "$envf" PANEL_PASSWORD)"
    printf '\n'
    printf 'Panel URL : https://%s/%s/\n' "$domain" "$ppath"
    printf 'Username  : %s\n' "$puser"
    printf 'Password  : %s\n' "$ppass"
    printf '\nClient links:\n'
    in_stack scripts/xui.sh links
}

# --- commands -----------------------------------------------------------------------------------------

require_installed() {
    getent passwd "$VPN_USER" >/dev/null || die "user $VPN_USER does not exist; run: sudo ./vpn.sh deploy"
    init_paths
    [[ -f "$VPN_DIR/docker-compose.yml" ]] || die "$VPN_DIR/docker-compose.yml not found; run: sudo ./vpn.sh deploy"
    [[ -f "$VPN_DIR/.env" ]] || die "$VPN_DIR/.env not found; run: sudo ./vpn.sh deploy"
    if ((EUID != 0)) && [[ "$(id -un)" != "$VPN_USER" ]]; then
        die "run as root or as $VPN_USER"
    fi
}

cmd_deploy() {
    require_root deploy
    STEP_TOTAL=12
    init_paths

    step "Checking the system"
    check_os
    check_system_tools
    check_rootful_docker
    firewall_note

    step "Installing packages (prerequisites and Docker CE)"
    install_packages

    step "Disabling the rootful Docker daemon"
    disable_rootful_docker

    step "Preparing user $VPN_USER (subuid/subgid, lingering)"
    ensure_user

    step "Configuring unprivileged ports and AppArmor"
    configure_sysctl

    step "Installing rootless Docker for $VPN_USER"
    install_rootless_docker

    step "Copying the project to $VPN_DIR"
    sync_project

    step "Preparing .env"
    setup_env

    step "Checking DNS"
    check_dns "$(env_get "$VPN_DIR/.env" DOMAIN)"

    step "Bootstrapping data directories and placeholder certificate"
    in_stack scripts/certs.sh bootstrap

    step "Building and starting the stack"
    in_stack docker compose up -d --build --wait

    step "Configuring the panel, creating inbounds, issuing the certificate"
    in_stack scripts/xui.sh configure-panel
    in_stack scripts/xui.sh provision
    in_stack scripts/certs.sh issue

    CURRENT_STEP="summary"
    printf '\n%sDeploy finished.%s\n' "$C_BOLD" "$C_RESET" >&2
    print_summary
}

cmd_start() {
    require_installed
    info "starting the stack"
    ensure_docker_running
    in_stack docker compose up -d --wait
}

cmd_stop() {
    require_installed
    ensure_docker_running
    info "stopping the stack"
    in_stack docker compose stop
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    require_installed
    ensure_docker_running
    in_stack docker compose ps
    printf '\n'
    in_stack scripts/certs.sh status || warn "certificate status unavailable"
}

cmd_links() {
    require_installed
    print_summary
}

remove_data_dir() { # PATH: delete a directory that may contain subuid-owned files
    local path=$1
    [[ "$path" =~ ^/[^/]+/[^/]+ && "$path" != "$VPN_HOME" ]] || die "refusing to delete suspicious path '$path'"
    [[ -e "$path" ]] || return 0
    # rootlesskit maps the subordinate ids, so it can delete files that
    # containers created as other uids; plain rm is the fallback.
    as_vpn rootlesskit rm -rf "$path" 2>/dev/null || as_vpn rm -rf "$path" || warn "could not fully delete $path"
    if [[ -e "$path" ]]; then
        rm -rf "$path" || warn "$path still exists"
    fi
}

cmd_remove() {
    require_root remove
    STEP_TOTAL=$((PURGE ? 6 : 1))
    getent passwd "$VPN_USER" >/dev/null || die "user $VPN_USER does not exist; nothing to remove"
    init_paths
    local domain=""
    domain="$(env_get "$VPN_DIR/.env" DOMAIN)"

    if ((PURGE)); then
        warn "--purge deletes ALL data: certificates, panel database, $VPN_DIR, rootless Docker and user $VPN_USER."
        if ((ASSUME_YES)); then
            info "confirmation skipped (--yes)"
        else
            [[ -t 0 ]] || die "no terminal; re-run with --yes to purge"
            local ans want="${domain:-yes}"
            read -r -p "Type '$want' (or 'yes') to confirm: " ans || die "aborted"
            [[ "$ans" == "$want" || "$ans" == yes ]] || die "aborted"
        fi
    else
        confirm "Stop and remove the containers and built images of the stack?" || die "aborted"
    fi

    step "Removing containers and images"
    if [[ -f "$VPN_DIR/docker-compose.yml" && -f "$VPN_DIR/.env" ]] && docker_up_or_start; then
        local -a down=(docker compose down --remove-orphans --rmi local)
        ((PURGE)) && down+=(--volumes)
        in_stack "${down[@]}"
    else
        warn "docker or $VPN_DIR/.env not available; skipping 'docker compose down'"
    fi

    if ((!PURGE)); then
        info "data in $VPN_DIR/data and rootless Docker were kept (use --purge to delete them)"
        return 0
    fi

    step "Deleting the project and data ($VPN_DIR)"
    as_vpn systemctl --user stop docker.service >/dev/null 2>&1 || true
    remove_data_dir "$VPN_DIR"

    step "Uninstalling rootless Docker"
    as_vpn dockerd-rootless-setuptool.sh uninstall >&2 || warn "setuptool uninstall reported an error"
    remove_data_dir "$VPN_HOME/.local/share/docker"
    rm -rf "$VPN_HOME/.config/systemd/user/docker.service.d"

    step "Removing the user $VPN_USER"
    loginctl disable-linger "$VPN_USER" || true
    loginctl terminate-user "$VPN_USER" >/dev/null 2>&1 || true
    sleep 2
    userdel -r "$VPN_USER" || warn "userdel reported an error; check $VPN_HOME and /etc/subuid"

    step "Removing system configuration"
    if [[ -f "$SYSCTL_FILE" ]] && grep -q "$MANAGED_MARK" "$SYSCTL_FILE"; then
        rm -f "$SYSCTL_FILE"
        info "removed $SYSCTL_FILE (the running kernel value is unchanged until reboot)"
    fi
    if [[ -f "$APPARMOR_FILE" ]] && grep -q "$MANAGED_MARK" "$APPARMOR_FILE"; then
        apparmor_parser -R "$APPARMOR_FILE" 2>/dev/null || true
        rm -f "$APPARMOR_FILE"
        info "removed $APPARMOR_FILE"
    fi

    step "Done"
    info "Installed packages were left in place. To remove Docker:"
    info "  apt-get purge ${DOCKER_PKGS[*]} && rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc"
    info "The rootful docker.service stays disabled; re-enable it with: systemctl enable --now docker.service docker.socket"
}

# --- main ---------------------------------------------------------------------------------------------------

main() {
    local cmd=""
    while (($#)); do
        case "$1" in
            -h | --help | help)
                usage
                exit 0
                ;;
            -y | --yes) ASSUME_YES=1 ;;
            --purge) PURGE=1 ;;
            deploy | start | stop | restart | status | links | remove)
                [[ -z "$cmd" ]] || die "only one command allowed (got '$cmd' and '$1')"
                cmd="$1"
                ;;
            *) die "unknown argument '$1' (see --help)" ;;
        esac
        shift
    done
    [[ -n "$cmd" ]] || {
        usage >&2
        exit 2
    }
    ((!PURGE)) || [[ "$cmd" == remove ]] || die "--purge only applies to 'remove'"
    [[ "$VPN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid VPN_USER '$VPN_USER'"

    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
    init_paths
    "cmd_$cmd"
}

# Sourcing with VPN_SH_LIB=1 only defines the functions (used by tests).
if [[ -n "${VPN_SH_LIB:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
main "$@"
