#!/usr/bin/env bash
# vpn.sh - install and manage the decoy web application (fake-webapp) with
# rootless Docker on Ubuntu/Debian.
#
# Run `./vpn.sh --help` for usage. The service itself is defined in
# fake-webapp/docker-compose.yml (included by docker-compose.yml); this script
# prepares the host (packages, unprivileged user, rootless Docker), copies the
# project to the user's home, generates .env and starts the container.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Everything runs as the invoking user: SUDO_USER under sudo, else the current
# user (resolved by init_paths). The project and its data stay in SCRIPT_DIR.
VPN_USER=""
VPN_DIR="$SCRIPT_DIR"
VPN_HOME=""
VPN_UID=""


SYSCTL_FILE=/etc/sysctl.d/99-vpn-rootless.conf
APPARMOR_FILE=/etc/apparmor.d/usr.bin.rootlesskit
MANAGED_MARK="# managed by vpn.sh"

PREREQ_PKGS=(uidmap dbus-user-session slirp4netns fuse-overlayfs curl ca-certificates iproute2 iptables python3)
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
    # ERR is inherited by subshells (set -E): report only in the main shell,
    # which fires again when the subshell fails.
    [[ "$BASHPID" == "$$" ]] || return "$code"
    trap - ERR
    printf '\n%serror:%s step "%s" failed (exit %d) at vpn.sh line %s: %s\n' \
        "$C_RED" "$C_RESET" "$CURRENT_STEP" "$code" "$line" "$cmd" >&2
}

usage() {
    cat <<'EOF'
Usage: ./vpn.sh [options] <command>

Installs and manages the decoy web application (fake-webapp) using rootless
Docker of the invoking user (the one who runs `sudo ./vpn.sh install`). No
users are created; the project, .env and data stay in this directory.
Target systems: Ubuntu 24.04+ and Debian 12+.

Commands:
  install   Idempotent setup (sudo/root): packages, rootless Docker for the
            invoking user, .env generation, generation of the missing
            login.html and favicon.ico, build and start of the fakeapp
            container. Re-running rebuilds/restarts the container; existing
            .env values and files in the data directory are never changed.
  start     Start the container (docker compose up -d --wait).
  stop      Stop the container (docker compose stop).
  remove    Remove the container and the built image (sudo/root). With
            --purge also deletes the data directory (login.html, favicon.ico
            and your static files), the rootless Docker install of the user
            (all its images and containers!), lingering and the
            sysctl/AppArmor files. The project directory, .env and packages
            are never removed.

Options:
  -y, --yes   Assume "yes" for every confirmation (OS warning, disabling a
              running rootful Docker, remove/purge).
  --purge     With `remove`: also delete data and the user's rootless Docker.
  -h, --help  Show this help.

Environment:
  APP_NAME, APP_DESCRIPTION, APP_KEYWORDS, DOMAIN
              If set when .env is created by `install`, they are used without
              prompting. Unset APP_* values are generated at random (offered
              as defaults when interactive). Without a terminal, all other
              prompts silently use their defaults.

Notes:
  * install/remove must run via sudo from a regular user (root itself cannot
    run rootless Docker); start/stop run as that user or via sudo.
  * An existing .env is reused: values are never changed; keys that
    are new in .env.example are appended with their description comments.
  * The app is published on FAKEAPP_BIND:FAKEAPP_PORT from .env (default
    127.0.0.1:8080, plain HTTP). Firewall rules are not touched.
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

# init_paths: resolve VPN_USER (SUDO_USER under sudo, else the current user),
# VPN_HOME and VPN_UID. Root itself cannot run rootless Docker.
init_paths() {
    local entry=""
    if ((EUID == 0)); then
        VPN_USER="${SUDO_USER:-}"
        [[ -n "$VPN_USER" && "$VPN_USER" != root ]] ||
            die "run this from a regular user via sudo (e.g. sudo ./vpn.sh install); root cannot run rootless Docker"
    else
        VPN_USER="$(id -un)"
    fi
    entry="$(getent passwd "$VPN_USER")" || die "user $VPN_USER not found"
    VPN_HOME="$(cut -d: -f6 <<<"$entry")"
    VPN_UID="$(cut -d: -f3 <<<"$entry")"
    [[ "$VPN_UID" != 0 ]] || die "the invoking user must not be root"
}

# _vpn_exec DIR CMD...: run CMD as VPN_USER with a clean environment, cwd DIR.
# The environment is rebuilt with `env -i` so that nothing from the caller
# (APP_NAME, DOCKER_HOST, ...) leaks into compose. XDG_RUNTIME_DIR /
# DBUS_SESSION_BUS_ADDRESS point at the user's systemd instance (it exists
# thanks to lingering), which makes `systemctl --user` and
# dockerd-rootless-setuptool.sh work without a login session. `runuser` is
# part of util-linux (always present), needs no PAM session or password and
# passes stdin through.
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
as_vpn() { _vpn_exec "$VPN_HOME" "$@"; }  # cwd = home
in_stack() { _vpn_exec "$VPN_DIR" "$@"; } # cwd = project dir

docker_ready() { as_vpn docker info >/dev/null 2>&1; }

# --- .env helpers (also usable from tests via VPN_SH_LIB=1) ---------------------------

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

# Free text that is safe inside a docker compose .env value.
valid_text() {
    [[ -n "$1" && ${#1} -le 200 ]] || return 1
    [[ ! "$1" =~ [\'\"\$\`\\[:cntrl:]] ]]
}
valid_tz() { [[ "$1" =~ ^[A-Za-z0-9_+/-]{1,64}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (($1 >= 1 && $1 <= 65535)); }

# rand_str LENGTH CHARSET: random string from /dev/urandom.
rand_str() {
    local n=$1 set=$2 out=""
    while ((${#out} < n)); do
        out+="$(LC_ALL=C tr -dc "$set" </dev/urandom | head -c "$n" || true)"
    done
    printf '%s' "${out:0:n}"
}

# fmt_env_value VALUE: bare when plain, single-quoted otherwise (literal for
# docker compose). Callers reject ' and $.
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

# ask_domain: optional DOMAIN (DNS name or IP address, not checked) into
# ENV_VALUES[DOMAIN]. From the environment if set; else asked when
# interactive (empty allowed); else empty. Surrounding spaces are trimmed.
ask_domain() {
    local v=""
    if [[ -n "${DOMAIN:-}" ]]; then
        v="$DOMAIN"
    elif [[ -t 0 ]]; then
        read -r -p "DNS name of the site, e.g. app.example.com (empty: none): " v || die "no input"
    fi
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [[ -z "${DOMAIN:-}" ]] || info "DOMAIN (from environment): $v"
    ENV_VALUES[DOMAIN]="$v"
}

# Keys of .env.example that may stay empty.
is_optional_key() { [[ "$1" == DOMAIN ]]; }

# --- generated values -------------------------------------------------------------------

# gen_random_data_suffix: lowercase hex, 8-12 chars.
gen_random_data_suffix() { rand_str $((8 + RANDOM % 5)) '0-9a-f'; }

# gen_page_seed: 32 lowercase hex chars (seed of the decoy login page variant).
gen_page_seed() { rand_str 32 '0-9a-f'; }

# rand_int MIN MAX: uniform random integer in [MIN, MAX].
rand_int() { printf '%s' "$(($1 + RANDOM % ($2 - $1 + 1)))"; }

gen_rate_limit_rps() { rand_int 8 15; }
gen_rate_limit_burst() { rand_int 15 40; }
gen_rate_limit_global_rps() { rand_int 150 400; }
gen_login_delay_min() { rand_int 180 400; }
# gen_login_delay_max [ENVFILE]: min + 300..900 (min is read from ENVFILE if set there).
gen_login_delay_max() {
    local min=""
    [[ -n "${1:-}" ]] && min="$(env_get "$1" LOGIN_DELAY_MIN_MS)"
    [[ "$min" =~ ^[0-9]+$ ]] || min="$(gen_login_delay_min)"
    printf '%s' "$((min + $(rand_int 300 900)))"
}

# --- decoy site identity -----------------------------------------------------------------

APP_NAME_HEAD=(Nova Lumi Brio Terra Verta Kora Zeno Orbi Mira Plano Cavo Remi Tavo Sela Vanta Ondo)
APP_NAME_TAIL=(ly ora ify base hub flow desk loop ware nest stack ra mo ix)
# Category: "descriptions separated by |" ; "eight keywords separated by ,".
APP_CAT_DESC=(
    "Simple time tracking and timesheets for small teams|Track hours, projects and billable time in one place"
    "Online invoicing and payment reminders for freelancers and small businesses|Create invoices, send reminders and see who has paid"
    "Shared inbox and ticketing for customer support teams|Answer customer requests faster with a shared support inbox"
    "Lightweight project planning with boards, tasks and deadlines|Plan work, assign tasks and keep deadlines visible for the whole team"
    "Secure file sharing and document storage for teams|Store, share and review documents with your colleagues and clients"
    "Leave requests and vacation planning for HR teams|Manage time off, approvals and team calendars in one place"
    "Inventory and stock management for small shops and warehouses|Keep track of stock levels, suppliers and orders"
    "Internal knowledge base and wiki for growing companies|Write down how things work and let your team find answers quickly"
    "Simple customer relationship management for small sales teams|Keep contacts, deals and follow-ups organised"
    "Online appointment booking and scheduling for service businesses|Let customers book appointments online and reduce no-shows"
    "Expense reports and receipt management for business travel|Submit expenses, attach receipts and get approvals faster"
    "Service status and incident communication portal for IT teams|Monitor services and keep your users informed during incidents"
)
APP_CAT_KEYWORDS=(
    "time tracking,timesheets,billable hours,projects,reports,teams,productivity,workforce"
    "invoicing,billing,payments,freelance,accounting,reminders,small business,finance"
    "helpdesk,support,tickets,shared inbox,customer service,sla,knowledge,teams"
    "project management,tasks,kanban,planning,deadlines,collaboration,teams,workflow"
    "file sharing,document storage,cloud storage,collaboration,secure,teams,sync,backup"
    "hr,leave management,vacation,time off,approvals,calendar,employees,teams"
    "inventory,stock,warehouse,suppliers,orders,barcode,retail,logistics"
    "knowledge base,wiki,documentation,internal,search,onboarding,teams,intranet"
    "crm,contacts,sales,deals,pipeline,follow-ups,customers,small business"
    "booking,appointments,scheduling,calendar,reminders,customers,services,online"
    "expenses,receipts,travel,reimbursement,approvals,finance,reports,business"
    "status page,incidents,monitoring,uptime,it,notifications,services,operations"
)

# gen_app_trio: set GEN_APP_NAME / GEN_APP_DESCRIPTION / GEN_APP_KEYWORDS to a
# coherent random name, description and keywords of a believable small product.
gen_app_trio() {
    local n=${#APP_CAT_DESC[@]} c descs kws k
    c=$((RANDOM % n))
    GEN_APP_NAME="${APP_NAME_HEAD[RANDOM % ${#APP_NAME_HEAD[@]}]}${APP_NAME_TAIL[RANDOM % ${#APP_NAME_TAIL[@]}]}"
    IFS='|' read -ra descs <<<"${APP_CAT_DESC[c]}"
    GEN_APP_DESCRIPTION="${descs[RANDOM % ${#descs[@]}]}"
    IFS=',' read -ra kws <<<"${APP_CAT_KEYWORDS[c]}"
    # Shuffle (Fisher-Yates) and keep five.
    local i j t
    for ((i = ${#kws[@]} - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        t="${kws[i]}"; kws[i]="${kws[j]}"; kws[j]="$t"
    done
    GEN_APP_KEYWORDS="${kws[0]}"
    for ((k = 1; k < 5; k++)); do GEN_APP_KEYWORDS+=", ${kws[k]}"; done
}
gen_app_name() { printf '%s' "${APP_NAME:-$GEN_APP_NAME}"; }
gen_app_description() { printf '%s' "${APP_DESCRIPTION:-$GEN_APP_DESCRIPTION}"; }
gen_app_keywords() { printf '%s' "${APP_KEYWORDS:-$GEN_APP_KEYWORDS}"; }
gen_tz() { host_timezone; }

# generator_for KEY: name of the function generating KEY (empty: none).
generator_for() {
    case "$1" in
        RANDOM_DATA_SUFFIX) echo gen_random_data_suffix ;;
        PAGE_SEED) echo gen_page_seed ;;
        APP_NAME) echo gen_app_name ;;
        APP_DESCRIPTION) echo gen_app_description ;;
        APP_KEYWORDS) echo gen_app_keywords ;;
        RATE_LIMIT_RPS) echo gen_rate_limit_rps ;;
        RATE_LIMIT_BURST) echo gen_rate_limit_burst ;;
        RATE_LIMIT_GLOBAL_RPS) echo gen_rate_limit_global_rps ;;
        LOGIN_DELAY_MIN_MS) echo gen_login_delay_min ;;
        LOGIN_DELAY_MAX_MS) echo gen_login_delay_max ;;
        TZ) echo gen_tz ;;
    esac
}

# ensure_generated_key FILE KEY GENERATOR_FN: fill KEY=<generated> in an existing
# .env when KEY is missing or empty; other lines are left untouched. The
# generator gets FILE as its first argument.
ensure_generated_key() {
    local file=$1 key=$2 gen=$3 val tmp line found=0
    [[ -n "$(env_get "$file" "$key")" ]] && return 0
    val="$("$gen" "$file")" || die "cannot generate $key"
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

# env_has FILE KEY: KEY= line exists (even with an empty value).
env_has() { grep -Eq "^[[:space:]]*$2=" "$1"; }

# example_comment_block EXAMPLE KEY: the contiguous # lines directly above KEY
# (without section banners "# --- ...").
example_comment_block() {
    awk -v k="$2" '
        { l[NR] = $0 }
        index($0, k "=") == 1 && !idx { idx = NR }
        END {
            if (!idx) exit
            s = idx
            while (s > 1 && l[s-1] ~ /^#/) s--
            for (i = s; i < idx; i++) if (l[i] ~ /^# ---/) s = i + 1
            for (i = s; i < idx; i++) print l[i]
        }' "$1"
}

# sync_env_with_example ENVFILE EXAMPLE: bring an existing .env up to date with
# .env.example. Missing keys are appended together with their comment block
# (generated value, else the example default, else optional/empty); present
# empty generated keys are filled in place. Existing values, comments and order
# are never changed; unknown keys are kept. Appending preserves mode/owner.
sync_env_with_example() {
    local envf=$1 example=$2 line key gen val def block
    [[ -f "$example" ]] || die "template not found: $example"
    local -a keys=()
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] && keys+=("${BASH_REMATCH[1]}")
    done <"$example"
    gen_app_trio
    for key in "${keys[@]}"; do
        if env_has "$envf" "$key"; then
            gen="$(generator_for "$key")"
            if [[ -n "$gen" && -z "$(env_get "$envf" "$key")" ]]; then
                ensure_generated_key "$envf" "$key" "$gen"
            fi
            continue
        fi
        gen="$(generator_for "$key")"
        def="$(env_get "$example" "$key")"
        if [[ -n "$gen" ]]; then
            val="$("$gen" "$envf")" || die "cannot generate $key"
        elif [[ -n "$def" ]]; then
            val="$def"
        elif [[ "$key" == DOMAIN ]]; then
            ask_domain
            val="${ENV_VALUES[DOMAIN]}"
        elif is_optional_key "$key"; then
            val=""
        else
            die "$key is missing in $envf and has no default; add it manually"
        fi
        [[ -n "$val" ]] || is_optional_key "$key" || die "no value for $key"
        block="$(example_comment_block "$example" "$key")"
        [[ -z "$(tail -c1 "$envf")" ]] || printf '\n' >>"$envf"
        {
            printf '\n'
            [[ -z "$block" ]] || printf '%s\n' "$block"
            printf '%s=%s\n' "$key" "$(fmt_env_value "$val")"
        } >>"$envf"
        info "added missing $key to $envf"
    done
}

# generate_env EXAMPLE OUT: build OUT (mode 600) from EXAMPLE, prompting for
# manual values and generating the rest. Never edits with sed: the template is
# rewritten line by line, so special characters in values are harmless.
generate_env() {
    local example=$1 out=$2 line key k v tmp def_tz
    [[ -f "$example" ]] || die "template not found: $example"
    ENV_VALUES=()

    gen_app_trio
    ask APP_NAME "Decoy site name" "$GEN_APP_NAME" valid_text "1-200 characters without ' \" \$ \` \\"
    ask APP_DESCRIPTION "Decoy site description" "$GEN_APP_DESCRIPTION" valid_text "1-200 characters without ' \" \$ \` \\"
    ask APP_KEYWORDS "Decoy site keywords" "$GEN_APP_KEYWORDS" valid_text "1-200 characters without ' \" \$ \` \\"
    ask_domain
    def_tz="$(host_timezone)"
    # TZ is deliberately not read from the environment (often set to odd values).
    local saved_tz="${TZ-__unset__}"
    unset TZ
    ask TZ "Time zone" "$def_tz" valid_tz "an IANA zone like Europe/Berlin"
    if [[ "$saved_tz" != __unset__ ]]; then export TZ="$saved_tz"; fi

    ENV_VALUES[RANDOM_DATA_SUFFIX]="$(gen_random_data_suffix)"
    ENV_VALUES[PAGE_SEED]="$(gen_page_seed)"
    ENV_VALUES[RATE_LIMIT_RPS]="$(gen_rate_limit_rps)"
    ENV_VALUES[RATE_LIMIT_BURST]="$(gen_rate_limit_burst)"
    ENV_VALUES[RATE_LIMIT_GLOBAL_RPS]="$(gen_rate_limit_global_rps)"
    ENV_VALUES[LOGIN_DELAY_MIN_MS]="$(gen_login_delay_min)"
    ENV_VALUES[LOGIN_DELAY_MAX_MS]=$((ENV_VALUES[LOGIN_DELAY_MIN_MS] + $(rand_int 300 900)))

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

    # Every non-optional key of the template must end up with a value.
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        k="${BASH_REMATCH[1]}"
        is_optional_key "$k" && continue
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

rootful_docker_active() {
    systemctl is-active --quiet docker.service 2>/dev/null || systemctl is-active --quiet docker.socket 2>/dev/null
}

# Rootful Docker must not be used. If it is running before we install
# anything, someone already uses it: ask before stopping it.
check_rootful_docker() {
    if rootful_docker_active; then
        ROOTFUL_DOCKER_WAS_ACTIVE=1
        warn "the system-wide (rootful) Docker daemon is running; this project uses rootless Docker."
        warn "Installing disables docker.service and docker.socket (running rootful containers will be stopped)."
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

# ensure_user: subordinate id ranges and lingering for the invoking user
# (no user is created).
ensure_user() {
    ok "running as user $VPN_USER (uid $VPN_UID, home $VPN_HOME)"
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

# Ubuntu 24.04 blocks unprivileged user namespaces through AppArmor; rootlesskit
# needs an exception (see the Docker rootless documentation).
configure_apparmor() {
    if [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" != 1 ]] ||
        ! command -v apparmor_parser >/dev/null 2>&1; then
        ok "no AppArmor user namespace restriction"
        return 0
    fi
    local other
    other="$(grep -rls '/usr/bin/rootlesskit' /etc/apparmor.d 2>/dev/null | grep -vx "$APPARMOR_FILE" || true)"
    if [[ -n "$other" ]]; then
        ok "AppArmor profile for rootlesskit already provided by $other"
        return 0
    fi
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
}

# configure_port PORT: let the unprivileged user publish PORT (< 1024 needs
# net.ipv4.ip_unprivileged_port_start <= PORT).
configure_port() {
    local port=$1 cur
    cur="$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)"
    if ((port >= cur)); then
        ok "port $port can be published by $VPN_USER (ip_unprivileged_port_start=$cur)"
        return 0
    fi
    write_if_changed "$SYSCTL_FILE" 644 <<EOF || true
$MANAGED_MARK
# Allow the unprivileged rootless-docker user to publish port $port.
net.ipv4.ip_unprivileged_port_start=$port
EOF
    sysctl -q -w "net.ipv4.ip_unprivileged_port_start=$port"
    ok "net.ipv4.ip_unprivileged_port_start=$port ($SYSCTL_FILE)"
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
        # The tool aborts when /var/run/docker.sock is writable for the user
        # (docker group), even if it is only a leftover of the stopped rootful
        # daemon. That daemon was disabled in an earlier step; --force skips
        # only this check.
        local -a setup=(dockerd-rootless-setuptool.sh)
        if rootful_docker_active; then
            die "the rootful Docker daemon is still running; stop it (systemctl disable --now docker.service docker.socket) and re-run install"
        fi
        [[ -S /var/run/docker.sock ]] && setup+=(--force)
        info "running ${setup[*]} install as $VPN_USER"
        as_vpn "${setup[@]}" install >&2
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

# check_project: the project directory must belong to the invoking user (the
# rootless Docker of that user builds and mounts from it).
check_project() {
    local owner
    owner="$(stat -c %U "$VPN_DIR")"
    [[ "$owner" == "$VPN_USER" ]] || die "$VPN_DIR is owned by $owner, not $VPN_USER; clone the project as $VPN_USER"
    [[ -f "$VPN_DIR/docker-compose.yml" && -f "$VPN_DIR/fake-webapp/docker-compose.yml" ]] ||
        die "docker-compose.yml or fake-webapp/docker-compose.yml missing in $VPN_DIR"
    ok "project: $VPN_DIR"
}

setup_env() {
    local envf="$VPN_DIR/.env"
    if [[ -f "$envf" ]]; then
        ok "$envf exists; reusing it (no questions asked)"
        sync_env_with_example "$envf" "$VPN_DIR/.env.example"
        return 0
    fi
    [[ -f "$VPN_DIR/.env.example" ]] || die "$VPN_DIR/.env.example is missing"
    info "creating $envf"
    generate_env "$VPN_DIR/.env.example" "$envf"
    chown "$VPN_USER:$VPN_USER" "$envf"
    chmod 600 "$envf"
    ok "$envf written (mode 600)"
}

# fakeapp_port: FAKEAPP_PORT from .env (default 8080), validated.
fakeapp_port() {
    local p
    p="$(env_get "$VPN_DIR/.env" FAKEAPP_PORT)"
    p="${p:-8080}"
    valid_port "$p" || die "FAKEAPP_PORT in $VPN_DIR/.env must be 1-65535 (got '$p')"
    printf '%s' "$p"
}

# fakeapp_data_dir: host data directory, resolved like compose does (relative
# to fake-webapp/, default ../data/fakeapp).
fakeapp_data_dir() {
    local d
    d="$(env_get "$VPN_DIR/.env" FAKEAPP_DATA_DIR)"
    d="${d:-../data/fakeapp}"
    [[ "$d" == /* ]] || d="$VPN_DIR/fake-webapp/$d"
    realpath -m "$d"
}

# prepare_data_dir: create the data directory as the invoking user, generate
# the missing login.html / favicon.ico (fake-webapp/gen/*.py, existing files
# are never overwritten) and make everything readable for the container. The
# container runs as a subordinate uid ("others" for these files) and mounts the
# directory read-only, so it needs r on files and r+x on directories.
prepare_data_dir() {
    local d envf="$VPN_DIR/.env" gen="$VPN_DIR/fake-webapp/gen" seed name
    d="$(fakeapp_data_dir)"
    seed="$(env_get "$envf" PAGE_SEED)"
    name="$(env_get "$envf" APP_NAME)"
    as_vpn mkdir -p "$d" || die "cannot create $d as $VPN_USER"
    if [[ -e "$d/login.html" ]]; then
        ok "$d/login.html exists; kept"
    else
        as_vpn python3 "$gen/login.py" --seed "$seed" --out "$d/login.html" || die "login.html generation failed"
        ok "$d/login.html generated"
    fi
    if [[ -e "$d/favicon.ico" ]]; then
        ok "$d/favicon.ico exists; kept"
    else
        as_vpn python3 "$gen/favicon.py" --seed "$seed" --name="$name" --out "$d/favicon.ico" ||
            die "favicon.ico generation failed"
        ok "$d/favicon.ico generated"
    fi
    as_vpn chmod -R a+rX "$d" || warn "could not make every file in $d readable for the container"
    ok "$d is readable for the container (mounted read-only)"
}

# --- summary ---------------------------------------------------------------------------------------

print_summary() {
    local envf="$VPN_DIR/.env" bind port rsuffix domain host
    bind="$(env_get "$envf" FAKEAPP_BIND)"
    bind="${bind:-127.0.0.1}"
    port="$(fakeapp_port)"
    rsuffix="$(env_get "$envf" RANDOM_DATA_SUFFIX)"
    domain="$(env_get "$envf" DOMAIN)"
    host="$bind"
    [[ "$host" != 0.0.0.0 ]] || host=127.0.0.1
    printf '\n'
    printf 'App name  : %s\n' "$(env_get "$envf" APP_NAME)"
    printf 'Listening : http://%s:%s/ (published on %s)\n' "$host" "$port" "$bind"
    [[ -z "$domain" ]] || printf 'Public URL: https://%s/ (canonical link and og:url)\n' "$domain"
    printf 'Random data (size 0-500000 bytes): http://%s:%s/random-%s?size=1000\n' "$host" "$port" "$rsuffix"
    printf 'Files     : %s (login.html: restart after editing; other files are served as is)\n' "$(fakeapp_data_dir)"
}

# --- commands -----------------------------------------------------------------------------------------

require_installed() {
    [[ -f "$VPN_DIR/docker-compose.yml" ]] || die "$VPN_DIR/docker-compose.yml not found; run: sudo ./vpn.sh install"
    [[ -f "$VPN_DIR/.env" ]] || die "$VPN_DIR/.env not found; run: sudo ./vpn.sh install"
}

cmd_install() {
    require_root install
    STEP_TOTAL=10
    init_paths

    step "Checking the system"
    check_os
    check_system_tools
    check_rootful_docker

    step "Installing packages (prerequisites and Docker CE)"
    install_packages

    step "Disabling the rootful Docker daemon"
    disable_rootful_docker

    step "Preparing user $VPN_USER (subuid/subgid, lingering)"
    ensure_user

    step "Configuring AppArmor for rootlesskit"
    configure_apparmor

    step "Installing rootless Docker for $VPN_USER"
    install_rootless_docker

    step "Checking the project directory"
    check_project

    step "Preparing .env"
    setup_env

    step "Preparing the port and the data directory (login.html, favicon.ico)"
    configure_port "$(fakeapp_port)"
    prepare_data_dir

    step "Building and starting fakeapp"
    in_stack docker compose up -d --build --wait

    CURRENT_STEP="summary"
    printf '\n%sInstall finished.%s\n' "$C_BOLD" "$C_RESET" >&2
    print_summary
}

cmd_start() {
    require_installed
    info "starting fakeapp"
    ensure_docker_running
    in_stack docker compose up -d --wait
}

cmd_stop() {
    require_installed
    ensure_docker_running
    info "stopping fakeapp"
    in_stack docker compose stop
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
    local data_dir=""
    [[ -f "$VPN_DIR/.env" ]] && data_dir="$(fakeapp_data_dir)"

    if ((PURGE)); then
        warn "--purge deletes ${data_dir:+the data in $data_dir and }the rootless Docker of $VPN_USER with ALL its images and containers."
        if ((ASSUME_YES)); then
            info "confirmation skipped (--yes)"
        else
            [[ -t 0 ]] || die "no terminal; re-run with --yes to purge"
            local ans
            read -r -p "Type 'yes' to confirm: " ans || die "aborted"
            [[ "$ans" == yes ]] || die "aborted"
        fi
    else
        confirm "Stop and remove the fakeapp container and its built image?" || die "aborted"
    fi

    step "Removing the container and the image"
    if [[ -f "$VPN_DIR/docker-compose.yml" && -f "$VPN_DIR/.env" ]] && docker_up_or_start; then
        local -a down=(docker compose down --remove-orphans --rmi local)
        ((PURGE)) && down+=(--volumes)
        in_stack "${down[@]}"
    else
        warn "docker or $VPN_DIR/.env not available; skipping 'docker compose down'"
    fi

    if ((!PURGE)); then
        info "data${data_dir:+ in $data_dir} and rootless Docker were kept (use --purge to delete them)"
        return 0
    fi

    step "Deleting the data${data_dir:+ ($data_dir)}"
    [[ -z "$data_dir" ]] || remove_data_dir "$data_dir"
    as_vpn systemctl --user stop docker.service >/dev/null 2>&1 || true

    step "Uninstalling rootless Docker"
    as_vpn dockerd-rootless-setuptool.sh uninstall >&2 || warn "setuptool uninstall reported an error"
    remove_data_dir "$VPN_HOME/.local/share/docker"
    rm -rf "$VPN_HOME/.config/systemd/user/docker.service.d"

    step "Disabling lingering for $VPN_USER"
    loginctl disable-linger "$VPN_USER" || true

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
            install | start | stop | remove)
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
