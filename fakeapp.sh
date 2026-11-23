#!/usr/bin/env bash
# fakeapp.sh - deploy a docker compose stack on Ubuntu/Debian: nginx (TLS
# termination, Let's Encrypt certificates) in front of the decoy web
# application (fake-webapp).
#
# Run `./fakeapp.sh --help` for usage. The services are defined in
# nginx/docker-compose.yml and fake-webapp/docker-compose.yml (both included
# by docker-compose.yml). This script makes sure Docker with the compose plugin
# is available (the system Docker is reused, Docker CE is installed only when
# there is none), generates .env, the decoy page and the nginx config, starts
# the stack, issues the certificate (certbot, webroot) and installs a renewal
# timer. nginx publishes ports 80 and 443 of the host; the app itself is
# reachable only inside the compose network. It never touches Xray, 3X-UI or
# the firewall.
set -Eeuo pipefail

# --- bootstrap (curl | bash) --------------------------------------------------------
# `curl -fsSL <raw-url>/fakeapp.sh | sudo bash -s -- install` runs this file
# without the rest of the project: clone it to FAKEAPP_DIR and continue from
# there. Skipped when the project files sit next to the script.
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
        exec "$FAKEAPP_DIR/fakeapp.sh" "$@" </dev/tty
    fi
    exec "$FAKEAPP_DIR/fakeapp.sh" "$@"
}
if [[ -z "${FAKEAPP_SH_LIB:-}" ]]; then
    bootstrap_project "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR"

PREREQ_PKGS=(curl ca-certificates iproute2 python3 openssl)
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

DATA_DIR="$APP_DIR/data"
NGINX_DATA="$DATA_DIR/nginx"
LE_DIR="$DATA_DIR/letsencrypt"
EXT_COMPOSE_FILE="$DATA_DIR/extensions.compose.yml"
RENEW_UNIT="fakeapp-certbot-renew"
RENEW_CRON=/etc/cron.d/fakeapp-certbot

ASSUME_YES=0
WITH_EXT=""
PURGE=0
CURRENT_STEP="startup"
STEP_NO=0
STEP_TOTAL=0
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
    printf '\n%serror:%s step "%s" failed (exit %d) at fakeapp.sh line %s: %s\n' \
        "$C_RED" "$C_RESET" "$CURRENT_STEP" "$code" "$line" "$cmd" >&2
}

usage() {
    cat <<'USAGE'
Usage: ./fakeapp.sh [options] <command>

Deploys a docker compose stack: nginx in a container (ports 80 and 443 of the
host, TLS with a Let's Encrypt certificate for DOMAIN) in front of the decoy
web application (fake-webapp), which is reachable only inside the compose
network. Target systems: Ubuntu 22.04+ and Debian 12+.

Commands:
  install   Idempotent setup (root/sudo): reuses the system Docker (installs
            Docker CE only when docker is missing, the compose plugin when it
            is missing), creates .env (asks for the DNS name of the site, the
            Let's Encrypt e-mail, the site name, description and keywords; the
            rest is generated), generates the missing login.html and
            favicon.ico and the nginx config, builds and starts the stack,
            obtains the certificate (certbot, webroot) and installs the renewal
            timer. Re-running rebuilds and restarts it; existing .env values
            and files in the data directory are kept.
  start     Start the stack (docker compose up -d --wait).
  stop      Stop the stack.
  restart   Restart the stack (e.g. after editing login.html).
  status    Show the container state, the certificate and check
            https://DOMAIN/ on this host (curl --resolve to 127.0.0.1).
  logs      Follow the container logs (Ctrl+C to quit).
  renew     Renew the certificates and reload nginx (run by the timer; issues
            the certificate when there is none yet). root/sudo.
  extensions  List additional features (extensions.d/); with --with ID,... install them.
  remove    Remove the stack, its images and the renewal timer (root/sudo).
            With --purge also delete the data directories (login.html,
            favicon.ico and your static files; the nginx config and the
            certificates). .env, the project and Docker are kept.

Options:
  -y, --yes   Assume "yes" for every confirmation.
  --with IDS  Extensions to install without the menu (comma list or "all");
              also FAKEAPP_EXTENSIONS. Used by install and extensions.
  --purge     With `remove`: also delete the data directories.
  -h, --help  Show this help.

Environment (used when install creates .env, without prompting):
  DOMAIN, LE_EMAIL, LE_STAGING, NGINX_HTTP_PORT, NGINX_HTTPS_PORT, FAKEAPP_PORT,
  APP_NAME, APP_DESCRIPTION, APP_KEYWORDS
              Unset APP_* values are generated at random (offered as defaults
              when interactive). Without a terminal every prompt uses its
              default, except DOMAIN, which is required.

Notes:
  * Ports 80 and 443 must be free (stop the host nginx / Xray first).
  * The site config is generated into data/nginx/ (do not edit it); extensions
    add locations as data/nginx/locations.d/<id>.conf (extensions.d/README.md).
  * start/stop/restart/status/logs need access to Docker (root, sudo or the
    docker group).
USAGE
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
    ((EUID == 0)) || die "'$1' must be run as root (try: sudo ./fakeapp.sh $1)"
}

# --- running docker compose ---------------------------------------------------------------

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

daemon_ok() { docker info >/dev/null 2>&1; }
compose_ok() { docker compose version >/dev/null 2>&1; }

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found; run: sudo ./fakeapp.sh install"
    daemon_ok || die "cannot talk to the Docker daemon (not running, or no permission: try sudo)"
}

# owner of the project directory: files created by the script get it.
project_owner() { stat -c '%u:%g' "$APP_DIR"; }

# --- .env helpers (also usable from tests via FAKEAPP_SH_LIB=1) ---------------------------

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
valid_01() { [[ "$1" == 0 || "$1" == 1 ]]; }
# valid_domain NAME: a DNS name with at least two labels (no IP addresses).
valid_domain() {
    ((${#1} <= 253)) || return 1
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}
# valid_email ADDRESS: empty is fine (LE_EMAIL is optional).
valid_email() {
    [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

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

# ask_domain: DOMAIN (required DNS name) into ENV_VALUES[DOMAIN]. From the
# environment if set; else asked when interactive (repeats until valid); else
# an error. Surrounding spaces are trimmed, the name is lowercased.
ask_domain() {
    local v="${DOMAIN:-}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ -n "$v" ]]; then
        valid_domain "$v" || die "DOMAIN from the environment is invalid: expected a DNS name like app.example.com"
        info "DOMAIN (from environment): $v"
    elif [[ -t 0 ]]; then
        while :; do
            read -r -p "DNS name of the site (its A record must point to this server), e.g. app.example.com: " v || die "no input"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
            valid_domain "$v" && break
            warn "invalid value; expected a DNS name like app.example.com"
        done
    else
        die "DOMAIN is required (set it in the environment; no terminal to ask)"
    fi
    ENV_VALUES[DOMAIN]="${v,,}"
}

# ask_le_email: optional LE_EMAIL into ENV_VALUES[LE_EMAIL] (environment, else
# asked when interactive, else empty).
ask_le_email() {
    local v="${LE_EMAIL:-}"
    if [[ -n "$v" ]]; then
        valid_email "$v" || die "LE_EMAIL from the environment is invalid"
        info "LE_EMAIL (from environment): $v"
    elif [[ -t 0 ]]; then
        while :; do
            read -r -p "E-mail for Let's Encrypt expiry notices (empty: none): " v || die "no input"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
            valid_email "$v" && break
            warn "invalid e-mail address"
        done
    fi
    ENV_VALUES[LE_EMAIL]="$v"
}

# port_in_use PORT: something listens on TCP PORT of the host (any address).
port_in_use() {
    ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
}

# valid_free_port VALUE: a port 1024-65535 that nothing listens on yet.
valid_free_port() {
    valid_port "$1" && (($1 >= 1024)) && ! port_in_use "$1"
}

# first_free_port FROM: the first free port >= FROM (FROM itself if none found).
first_free_port() {
    local p
    for ((p = $1; p < $1 + 200 && p <= 65535; p++)); do
        port_in_use "$p" || {
            printf '%s' "$p"
            return 0
        }
    done
    printf '%s' "$1"
}

# Keys of .env.example that may stay empty.
is_optional_key() {
    [[ "$1" == LE_EMAIL ]]
}

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

# env_set FILE KEY VALUE: set KEY=VALUE in place (all existing KEY= lines are
# replaced, else it is appended); other lines are untouched. Keeps mode/owner.
env_set() {
    local file=$1 key=$2 val=$3 tmp line found=0
    tmp="$(mktemp "$file.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^${key}= ]]; then
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
            elif [[ "$key" == DOMAIN && -z "$(env_get "$envf" DOMAIN)" ]]; then
                ask_domain
                env_set "$envf" DOMAIN "${ENV_VALUES[DOMAIN]}"
                info "DOMAIN set in $envf"
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
        elif [[ "$key" == LE_EMAIL ]]; then
            ask_le_email
            val="${ENV_VALUES[LE_EMAIL]}"
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
    ask_le_email
    # Not asked: taken from the environment when set (else the .env.example default).
    local ev
    for ev in FAKEAPP_PORT NGINX_HTTP_PORT NGINX_HTTPS_PORT LE_STAGING; do
        [[ -n "${!ev:-}" ]] || continue
        case "$ev" in
            LE_STAGING) valid_01 "${!ev}" || die "$ev from the environment must be 0 or 1" ;;
            *) valid_port "${!ev}" || die "$ev from the environment must be a port 1-65535" ;;
        esac
        ENV_VALUES[$ev]="${!ev}"
        info "$ev (from environment): ${!ev}"
    done
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
    warn "$pretty is not supported (need Ubuntu 22.04+ or Debian 12+)"
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
    command -v apt-get >/dev/null 2>&1 || die "apt-get not found (only Debian/Ubuntu are supported)"
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found (systemd is required)"
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
        info "installing prerequisites: ${missing[*]}"
        apt_update_once
        apt_install "${missing[@]}"
    else
        ok "prerequisites already installed (${PREREQ_PKGS[*]})"
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
        info "fetching the Docker repository key"
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
    info "docker is not installed: installing Docker CE from download.docker.com"
    add_docker_repo
    apt_install "${DOCKER_PKGS[@]}"
    systemctl enable --now docker.service >/dev/null 2>&1 || warn "could not enable docker.service"
}

# install_compose_plugin: add `docker compose` (v2) to an existing Docker.
install_compose_plugin() {
    info "the docker compose plugin is missing: installing it"
    if pkg_installed docker-ce; then
        add_docker_repo
        apt_install docker-compose-plugin docker-buildx-plugin
    elif pkg_installed docker.io; then
        apt_update_once
        apt_install docker-compose-v2 2>/dev/null || apt_install docker-compose ||
            die "cannot install the compose plugin for docker.io; install Docker Compose v2 manually"
    else
        die "docker is installed but not from apt (snap, binary?); install the Docker Compose v2 plugin manually"
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
        ok "docker found: $(docker --version 2>/dev/null)"
        if ! daemon_ok; then
            info "the Docker daemon does not answer; starting docker.service"
            systemctl enable --now docker.service >/dev/null 2>&1 || true
            wait_for 30 "the Docker daemon" daemon_ok
        fi
    else
        install_docker_ce
        wait_for 30 "the Docker daemon" daemon_ok
        ok "$(docker --version)"
    fi
    compose_ok || install_compose_plugin
    compose_ok || die "docker compose is not available"
    compose_version_ok ||
        die "docker compose $(docker compose version --short 2>/dev/null) is too old (need 2.20+); update docker-compose-plugin"
    ok "docker compose $(docker compose version --short)"
}

# --- project -------------------------------------------------------------------------------------

check_project() {
    local f
    for f in docker-compose.yml .env.example nginx/docker-compose.yml nginx/default.conf.template \
        fake-webapp/docker-compose.yml fake-webapp/Dockerfile fake-webapp/gen/login.py fake-webapp/gen/favicon.py; do
        [[ -f "$APP_DIR/$f" ]] || die "$f missing in $APP_DIR"
    done
    ok "project: $APP_DIR"
}

setup_env() {
    local envf="$APP_DIR/.env"
    if [[ -f "$envf" ]]; then
        ok "$envf exists; reusing it (no questions asked)"
        sync_env_with_example "$envf" "$APP_DIR/.env.example"
        valid_domain "$(env_get "$envf" DOMAIN)" || die "DOMAIN in $envf is not a valid DNS name; fix it and re-run install"
        return 0
    fi
    info "creating $envf"
    generate_env "$APP_DIR/.env.example" "$envf"
    chown "$(project_owner)" "$envf"
    chmod 600 "$envf"
    ok "$envf written (mode 600)"
}

# fakeapp_port: FAKEAPP_PORT from .env (default 8080), validated.
fakeapp_port() {
    local p
    p="$(env_get "$APP_DIR/.env" FAKEAPP_PORT)"
    p="${p:-8080}"
    valid_port "$p" || die "FAKEAPP_PORT in $APP_DIR/.env must be 1-65535 (got '$p')"
    printf '%s' "$p"
}

# env_or_default KEY DEFAULT: value of KEY from .env, else DEFAULT.
env_or_default() {
    local v
    v="$(env_get "$APP_DIR/.env" "$1")"
    printf '%s' "${v:-$2}"
}

site_domain() {
    local d
    d="$(env_get "$APP_DIR/.env" DOMAIN)"
    valid_domain "$d" || die "DOMAIN in $APP_DIR/.env is missing or not a DNS name (got '$d'); set it and re-run install"
    printf '%s' "$d"
}

nginx_http_port() {
    local p
    p="$(env_or_default NGINX_HTTP_PORT 80)"
    valid_port "$p" || die "NGINX_HTTP_PORT in $APP_DIR/.env must be 1-65535 (got '$p')"
    printf '%s' "$p"
}

nginx_https_port() {
    local p
    p="$(env_or_default NGINX_HTTPS_PORT 443)"
    valid_port "$p" || die "NGINX_HTTPS_PORT in $APP_DIR/.env must be 1-65535 (got '$p')"
    printf '%s' "$p"
}

# fakeapp_data_dir: host data directory, resolved like compose does (relative
# to fake-webapp/, default ../data/fakeapp).
fakeapp_data_dir() {
    local d
    d="$(env_get "$APP_DIR/.env" FAKEAPP_DATA_DIR)"
    d="${d:-../data/fakeapp}"
    [[ "$d" == /* ]] || d="$APP_DIR/fake-webapp/$d"
    realpath -m "$d"
}

# port_holder PORT: the program listening on TCP PORT (needs root for others' sockets).
port_holder() {
    ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -n1 | sed 's/^users:(("//; s/"$//' || true
}

# stack_running SERVICE: the compose service has a running container.
stack_running() {
    [[ -n "$(compose ps -q "$1" 2>/dev/null)" ]]
}

# check_port_free: the nginx host ports (80/443) must be free, or already ours.
check_port_free() {
    local port holder
    for port in "$(nginx_http_port)" "$(nginx_https_port)"; do
        if port_in_use "$port" && ! stack_running nginx; then
            holder="$(port_holder "$port")"
            # shellcheck disable=SC2016
            die "port $port is already in use${holder:+ by '$holder'} (another nginx / Xray / 3X-UI?); stop it or move it to another port, check with: ss -ltnp 'sport = :$port'. The nginx of this stack needs ports $(nginx_http_port) and $(nginx_https_port) (NGINX_HTTP_PORT / NGINX_HTTPS_PORT in $APP_DIR/.env)"
        fi
    done
    ok "ports $(nginx_http_port) and $(nginx_https_port) are free for nginx"
    [[ "$(nginx_http_port)" == 80 ]] ||
        warn "NGINX_HTTP_PORT=$(nginx_http_port): Let's Encrypt validates on port 80 only; forward it here or issuing the certificate fails"
}

# prepare_data_dir: create the data directory, generate the missing
# login.html / favicon.ico (fake-webapp/gen/*.py, existing files are never
# overwritten) and make everything readable for the container (it runs as a
# non-root uid and mounts the directory read-only).
prepare_data_dir() {
    local d envf="$APP_DIR/.env" gen="$APP_DIR/fake-webapp/gen" seed name owner
    d="$(fakeapp_data_dir)"
    seed="$(env_get "$envf" PAGE_SEED)"
    name="$(env_get "$envf" APP_NAME)"
    owner="$(project_owner)"
    if [[ ! -d "$d" ]]; then
        mkdir -p "$d" || die "cannot create $d"
        chown "$owner" "$d"
    fi
    if [[ -e "$d/login.html" ]]; then
        ok "$d/login.html exists; kept"
    else
        python3 "$gen/login.py" --seed "$seed" --out "$d/login.html" || die "login.html generation failed"
        chown "$owner" "$d/login.html"
        ok "$d/login.html generated"
    fi
    if [[ -e "$d/favicon.ico" ]]; then
        ok "$d/favicon.ico exists; kept"
    else
        python3 "$gen/favicon.py" --seed "$seed" --name="$name" --out "$d/favicon.ico" ||
            die "favicon.ico generation failed"
        chown "$owner" "$d/favicon.ico"
        ok "$d/favicon.ico generated"
    fi
    chmod -R a+rX "$d" || warn "could not make every file in $d readable for the container"
    ok "$d is readable for the container (mounted read-only)"
}

# --- nginx config and certificates -----------------------------------------------------------------

# ensure_selfsigned DOMAIN: temporary certificate so that nginx can start
# before Let's Encrypt has issued the real one (kept while it matches DOMAIN).
ensure_selfsigned() {
    local domain=$1 dir="$NGINX_DATA/selfsigned"
    mkdir -p "$dir"
    if [[ -s "$dir/fullchain.pem" && -s "$dir/privkey.pem" ]] &&
        openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'; then
        return 0
    fi
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain" \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" 2>/dev/null ||
        die "cannot create the temporary self-signed certificate (openssl)"
    chmod 600 "$dir/privkey.pem"
    info "temporary self-signed certificate created for $domain"
}

# have_le_cert DOMAIN: a Let's Encrypt certificate for DOMAIN exists.
have_le_cert() {
    [[ -s "$LE_DIR/live/$1/fullchain.pem" && -s "$LE_DIR/live/$1/privkey.pem" ]]
}

# render_nginx_conf [TEMPLATE OUT]: fill nginx/default.conf.template from .env
# (default OUT: data/nginx/conf.d/default.conf). The Let's Encrypt certificate
# is used when it exists, else the temporary self-signed one.
render_nginx_conf() {
    local tpl="${1:-$APP_DIR/nginx/default.conf.template}"
    local out="${2:-$NGINX_DATA/conf.d/default.conf}"
    local domain port https_port cert key suffix content tmp
    domain="$(site_domain)"
    port="$(fakeapp_port)"
    https_port="$(nginx_https_port)"
    suffix=""
    [[ "$https_port" == 443 ]] || suffix=":$https_port"
    if have_le_cert "$domain"; then
        cert="/etc/letsencrypt/live/$domain/fullchain.pem"
        key="/etc/letsencrypt/live/$domain/privkey.pem"
    else
        cert=/etc/nginx/selfsigned/fullchain.pem
        key=/etc/nginx/selfsigned/privkey.pem
    fi
    [[ -f "$tpl" ]] || die "template not found: $tpl"
    content="$(<"$tpl")"
    content="${content//@DOMAIN@/$domain}"
    content="${content//@FAKEAPP_PORT@/$port}"
    content="${content//@HTTPS_PORT_SUFFIX@/$suffix}"
    content="${content//@SSL_CERT@/$cert}"
    content="${content//@SSL_KEY@/$key}"
    mkdir -p "$(dirname "$out")"
    tmp="$(mktemp "$out.XXXXXX")"
    printf '%s\n' "$content" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

# prepare_nginx_dir: data/nginx/{conf.d,locations.d,webroot,selfsigned}, the
# temporary certificate and the rendered config.
prepare_nginx_dir() {
    local d owner
    owner="$(project_owner)"
    mkdir -p "$NGINX_DATA/conf.d" "$NGINX_DATA/locations.d" "$NGINX_DATA/webroot" "$NGINX_DATA/selfsigned" "$LE_DIR"
    ensure_selfsigned "$(site_domain)"
    render_nginx_conf
    chmod -R a+rX "$NGINX_DATA/conf.d" "$NGINX_DATA/locations.d" "$NGINX_DATA/webroot"
    for d in "$DATA_DIR" "$NGINX_DATA" "$NGINX_DATA/conf.d" "$NGINX_DATA/locations.d" "$NGINX_DATA/webroot"; do
        chown "$owner" "$d" 2>/dev/null || true
    done
    ok "nginx config rendered: $NGINX_DATA/conf.d/default.conf ($(have_le_cert "$(site_domain)" && echo "Let's Encrypt certificate" || echo "temporary self-signed certificate"))"
}

# nginx_reload: test the config in the running container and reload it.
nginx_reload() {
    compose exec -T nginx nginx -t >/dev/null 2>&1 || {
        compose exec -T nginx nginx -t >&2 || true
        return 1
    }
    compose exec -T nginx nginx -s reload >/dev/null 2>&1
}

# issue_certificate: Let's Encrypt via the one-shot certbot container
# (webroot). Returns 1 with a hint on failure; callers carry on.
issue_certificate() {
    local domain email
    domain="$(site_domain)"
    email="$(env_get "$APP_DIR/.env" LE_EMAIL)"
    local -a args=(certonly --webroot -w /var/www/acme -d "$domain" --cert-name "$domain"
        --non-interactive --agree-tos --keep-until-expiring)
    if [[ -n "$email" ]]; then
        args+=(--email "$email" --no-eff-email)
    else
        args+=(--register-unsafely-without-email)
    fi
    [[ "$(env_or_default LE_STAGING 0)" != 1 ]] || {
        args+=(--staging)
        warn "LE_STAGING=1: the certificate will not be trusted by browsers"
    }
    info "requesting a certificate for $domain from Let's Encrypt"
    if ! compose run --rm -T certbot "${args[@]}" >&2; then
        warn "could not obtain a certificate for $domain; nginx keeps serving the temporary self-signed one"
        info "check that: the DNS A/AAAA record of $domain points to this server;"
        info "            port 80 is reachable from the internet (firewall, cloud security group) and is served by this stack;"
        info "            Let's Encrypt rate limits are not hit (try LE_STAGING=1 for tests)."
        info "then retry with: sudo ./fakeapp.sh renew   (or re-run install)"
        return 1
    fi
    ok "certificate issued for $domain"
    render_nginx_conf
    if nginx_reload; then
        ok "nginx reloaded with the new certificate"
    else
        warn "nginx did not reload (see: ./fakeapp.sh logs)"
        return 1
    fi
}

# renew_certificates: the work of the timer: renew, then reload nginx.
renew_certificates() {
    local domain
    domain="$(site_domain)"
    if ! have_le_cert "$domain"; then
        issue_certificate
        return
    fi
    compose run --rm -T certbot renew --quiet >&2 || {
        warn "certbot renew failed"
        return 1
    }
    render_nginx_conf
    nginx_reload || {
        warn "nginx did not reload"
        return 1
    }
    ok "certificates checked, nginx reloaded"
}

# install_renew_timer: systemd timer (twice a day) running `fakeapp.sh renew`;
# /etc/cron.d entry when systemd is not running.
install_renew_timer() {
    local script="$APP_DIR/fakeapp.sh"
    if [[ -d /run/systemd/system ]]; then
        cat >"/etc/systemd/system/$RENEW_UNIT.service" <<UNIT
[Unit]
Description=Renew Let's Encrypt certificates of the fakeapp stack
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart="$script" renew
UNIT
        cat >"/etc/systemd/system/$RENEW_UNIT.timer" <<UNIT
[Unit]
Description=Renew Let's Encrypt certificates of the fakeapp stack twice a day

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        systemctl daemon-reload
        if systemctl enable --now "$RENEW_UNIT.timer" >/dev/null 2>&1; then
            ok "renewal timer installed: $RENEW_UNIT.timer (systemctl list-timers $RENEW_UNIT.timer)"
            rm -f "$RENEW_CRON"
            return 0
        fi
        warn "could not enable $RENEW_UNIT.timer; using $RENEW_CRON instead"
    fi
    printf '# Renew Let'"'"'s Encrypt certificates of the fakeapp stack (installed by fakeapp.sh).\n17 3,15 * * * root "%s" renew >/dev/null 2>&1\n' "$script" >"$RENEW_CRON"
    chmod 644 "$RENEW_CRON"
    ok "renewal cron entry installed: $RENEW_CRON"
}

# remove_renew_timer: remove the systemd timer and the cron entry.
remove_renew_timer() {
    if [[ -f "/etc/systemd/system/$RENEW_UNIT.timer" ]]; then
        systemctl disable --now "$RENEW_UNIT.timer" >/dev/null 2>&1 || true
    fi
    rm -f "/etc/systemd/system/$RENEW_UNIT.timer" "/etc/systemd/system/$RENEW_UNIT.service" "$RENEW_CRON"
    [[ ! -d /run/systemd/system ]] || systemctl daemon-reload 2>/dev/null || true
}

renew_timer_state() {
    if [[ -f "/etc/systemd/system/$RENEW_UNIT.timer" ]]; then
        printf 'systemd timer %s (%s)' "$RENEW_UNIT.timer" "$(systemctl is-active "$RENEW_UNIT.timer" 2>/dev/null || true)"
    elif [[ -f "$RENEW_CRON" ]]; then
        printf 'cron entry %s' "$RENEW_CRON"
    else
        printf 'not installed (run: sudo ./fakeapp.sh install)'
    fi
}

# check_https: https://DOMAIN/ answers on this host (curl --resolve to
# 127.0.0.1). A certificate that is not trusted (self-signed, LE_STAGING) is
# only a warning; no answer at all fails.
check_https() {
    local domain port url
    domain="$(site_domain)"
    port="$(nginx_https_port)"
    url="https://$domain/"
    [[ "$port" == 443 ]] || url="https://$domain:$port/"
    if curl -fs -o /dev/null --max-time 8 --resolve "$domain:$port:127.0.0.1" "$url"; then
        ok "$url answers (nginx -> fakeapp, trusted certificate)"
    elif curl -fsk -o /dev/null --max-time 8 --resolve "$domain:$port:127.0.0.1" "$url"; then
        warn "$url answers, but the certificate is not trusted yet (temporary self-signed or LE_STAGING=1)"
    else
        warn "$url does not answer (see: ./fakeapp.sh logs)"
        return 1
    fi
}

# cert_summary: one line about the certificate nginx serves.
cert_summary() {
    local domain f end
    domain="$(site_domain)"
    if have_le_cert "$domain"; then
        end="$(openssl x509 -in "$LE_DIR/live/$domain/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
        printf "Let's Encrypt%s, expires %s" "$([[ "$(env_or_default LE_STAGING 0)" != 1 ]] || printf ' (staging)')" "${end:-unknown}"
    else
        printf 'temporary self-signed (no Let'"'"'s Encrypt certificate yet: sudo ./fakeapp.sh renew)'
    fi
}

print_summary() {
    local envf="$APP_DIR/.env" domain port suffix=""
    domain="$(site_domain)"
    port="$(nginx_https_port)"
    [[ "$port" == 443 ]] || suffix=":$port"
    printf '\n'
    printf 'App name  : %s\n' "$(env_get "$envf" APP_NAME)"
    printf 'Site      : https://%s%s/ (nginx container on ports %s/%s; the app is internal: http://fakeapp:%s)\n' \
        "$domain" "$suffix" "$(nginx_http_port)" "$port" "$(fakeapp_port)"
    printf 'Certificate: %s\n' "$(cert_summary)"
    printf 'Renewal   : %s\n' "$(renew_timer_state)"
    printf 'Random    : https://%s%s/random-%s?size=1000 (0-500000 bytes)\n' "$domain" "$suffix" "$(env_get "$envf" RANDOM_DATA_SUFFIX)"
    printf 'Files     : %s (login.html: ./fakeapp.sh restart after editing; other files are served as is)\n' "$(fakeapp_data_dir)"
    printf 'nginx     : %s/conf.d/default.conf is generated (do not edit); extensions add locations in %s/locations.d/\n' "$NGINX_DATA" "$NGINX_DATA"
}

# --- extensions ---------------------------------------------------------------------------------------
# Each extension is one file extensions.d/<NN>-<id>.sh (see extensions.d/README.md).
# Files are only added, never edited here, so branches adding extensions do not
# conflict on merge. A file calls: register_extension ID "Title" INSTALL_FN.
# Helpers for extension files (documented in extensions.d/README.md):
#   ext_register_compose ID FILE / ext_unregister_compose ID
#   ext_nginx_location_put ID (content on stdin) / ext_nginx_location_rm ID
#   ext_domain, ext_compose

EXT_IDS=()
declare -A EXT_TITLE=() EXT_FN=()
EXT_SELECTED=""

# ext_valid_id ID: an identifier usable as a file name and a compose key.
ext_valid_id() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }

# ext_compose ARGS...: the project's docker compose wrapper (all included files).
ext_compose() { compose "$@"; }

# ext_domain: DOMAIN of .env.
ext_domain() { env_get "$APP_DIR/.env" DOMAIN; }

# _ext_compose_rewrite ID PATH: set (PATH non-empty) or drop (PATH empty) the
# entry of ID in data/extensions.compose.yml, keeping the other entries.
# File format: `services: {}` when empty, else an `include:` list of lines
#   - "/absolute/path/to/compose.yml" # <id>
_ext_compose_rewrite() {
    local id=$1 path=$2 line i tmp
    local -a ids=() paths=()
    if [[ -f "$EXT_COMPOSE_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\"(.*)\"[[:space:]]+#[[:space:]]+([a-z0-9][a-z0-9_-]*)$ ]]; then
                [[ "${BASH_REMATCH[2]}" != "$id" ]] || continue
                paths+=("${BASH_REMATCH[1]}")
                ids+=("${BASH_REMATCH[2]}")
            fi
        done <"$EXT_COMPOSE_FILE"
    fi
    if [[ -n "$path" ]]; then
        ids+=("$id")
        paths+=("$path")
    fi
    mkdir -p "$DATA_DIR"
    tmp="$(mktemp "$EXT_COMPOSE_FILE.XXXXXX")"
    if ((${#ids[@]})); then
        {
            printf '# Generated by fakeapp.sh (ext_register_compose): do not edit.\ninclude:\n'
            for i in "${!ids[@]}"; do
                printf '  - "%s" # %s\n' "${paths[i]}" "${ids[i]}"
            done
        } >"$tmp"
    else
        printf 'services: {}\n' >"$tmp"
    fi
    chmod 644 "$tmp"
    if [[ $EUID -eq 0 ]]; then chown "$(project_owner)" "$tmp" 2>/dev/null || true; fi
    mv -f "$tmp" "$EXT_COMPOSE_FILE"
}

# ext_register_compose ID FILE: include the compose file FILE (an extension's
# services) in the stack: data/extensions.compose.yml is rewritten.
ext_register_compose() {
    local id=${1:-} file=${2:-}
    ext_valid_id "$id" || die "ext_register_compose: bad id '$id'"
    [[ -f "$file" ]] || die "ext_register_compose: compose file not found: '$file'"
    file="$(realpath "$file")"
    [[ "$file" != *[\"$'\n']* ]] || die "ext_register_compose: unsupported characters in '$file'"
    _ext_compose_rewrite "$id" "$file"
    ok "compose file registered for '$id': $file"
}

# ext_unregister_compose ID: drop the entry of ID (stop its containers first).
ext_unregister_compose() {
    local id=${1:-}
    ext_valid_id "$id" || die "ext_unregister_compose: bad id '$id'"
    _ext_compose_rewrite "$id" ""
    ok "compose file unregistered for '$id'"
}

# ext_nginx_location_put ID: write stdin to data/nginx/locations.d/<ID>.conf (a
# location block, included in the 443 server before `location /`), then test
# the config and reload nginx when it runs. A rejected config is rolled back.
ext_nginx_location_put() {
    local id=${1:-} dir="$NGINX_DATA/locations.d" file tmp backup=""
    ext_valid_id "$id" || die "ext_nginx_location_put: bad id '$id'"
    file="$dir/$id.conf"
    mkdir -p "$dir"
    tmp="$(mktemp "$file.XXXXXX")"
    cat >"$tmp"
    [[ -s "$tmp" ]] || { rm -f "$tmp"; die "ext_nginx_location_put: empty location for '$id'"; }
    chmod 644 "$tmp"
    if [[ -f "$file" ]]; then
        backup="$(mktemp "$file.bak.XXXXXX")"
        cp -p "$file" "$backup"
    fi
    mv -f "$tmp" "$file"
    if ext_nginx_apply; then
        [[ -z "$backup" ]] || rm -f "$backup"
        ok "nginx location '$id' installed: $file"
        return 0
    fi
    if [[ -n "$backup" ]]; then mv -f "$backup" "$file"; else rm -f "$file"; fi
    die "nginx rejected the location '$id' (rolled back); see the message above"
}

# ext_nginx_location_rm ID: delete data/nginx/locations.d/<ID>.conf and reload.
ext_nginx_location_rm() {
    local id=${1:-}
    ext_valid_id "$id" || die "ext_nginx_location_rm: bad id '$id'"
    rm -f "$NGINX_DATA/locations.d/$id.conf"
    ext_nginx_apply || warn "nginx did not accept the config after removing '$id'"
    ok "nginx location '$id' removed"
}

# ext_nginx_apply: `nginx -t` and reload when the nginx container runs (else
# the files are picked up at its next start). Fails when the test fails.
ext_nginx_apply() {
    if ! stack_running nginx; then
        info "nginx is not running; the locations are used at its next start"
        return 0
    fi
    compose exec -T nginx nginx -t >&2 || return 1
    compose exec -T nginx nginx -s reload >&2
}

register_extension() {
    local id=$1
    [[ "$id" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "extension: bad id '$id'"
    EXT_IDS+=("$id")
    EXT_TITLE[$id]=$2
    EXT_FN[$id]=$3
}

load_extensions() {
    local f
    for f in "$APP_DIR"/extensions.d/*.sh; do
        [[ -f "$f" ]] || continue
        # shellcheck disable=SC1090
        source "$f"
    done
}

# select_extensions: fill EXT_SELECTED (space separated ids) from --with /
# FAKEAPP_EXTENSIONS ("all" allowed) or an interactive menu.
select_extensions() {
    local want="${WITH_EXT:-${FAKEAPP_EXTENSIONS:-}}" id i ans
    EXT_SELECTED=""
    ((${#EXT_IDS[@]})) || return 0
    if [[ -n "$want" ]]; then
        want="${want//,/ }"
        if [[ "$want" == all ]]; then
            EXT_SELECTED="${EXT_IDS[*]}"
            return 0
        fi
        for id in $want; do
            [[ -n "${EXT_FN[$id]:-}" ]] || die "unknown extension '$id' (see: ./fakeapp.sh extensions)"
        done
        EXT_SELECTED="$want"
        return 0
    fi
    [[ -t 0 && ! $ASSUME_YES -eq 1 ]] || return 0
    printf '\nAdditional features:\n' >&2
    for i in "${!EXT_IDS[@]}"; do
        printf '  %d) %s\n' $((i + 1)) "${EXT_TITLE[${EXT_IDS[i]}]}" >&2
    done
    read -r -p "Install which? numbers separated by spaces, 'all' or empty for none: " ans || return 0
    [[ -n "$ans" ]] || return 0
    if [[ "${ans,,}" == all ]]; then
        EXT_SELECTED="${EXT_IDS[*]}"
        return 0
    fi
    for i in ${ans//,/ }; do
        [[ "$i" =~ ^[0-9]+$ && -n "${EXT_IDS[i - 1]:-}" ]] || die "bad choice '$i'"
        EXT_SELECTED+=" ${EXT_IDS[i - 1]}"
    done
}

run_extensions() {
    local id
    for id in $EXT_SELECTED; do
        step "Extension: ${EXT_TITLE[$id]}"
        "${EXT_FN[$id]}"
    done
}

# --- commands -----------------------------------------------------------------------------------------

require_installed() {
    [[ -f "$APP_DIR/.env" ]] || die "$APP_DIR/.env not found; run: sudo ./fakeapp.sh install"
}

cmd_install() {
    require_root install
    select_extensions
    local ext_count
    ext_count=$(wc -w <<<"$EXT_SELECTED")
    STEP_TOTAL=$((8 + ext_count))
    check_system_tools

    step "Checking the project directory"
    check_project

    step "Installing prerequisites (${PREREQ_PKGS[*]})"
    install_prereqs

    step "Checking Docker and docker compose"
    ensure_docker

    step "Preparing .env"
    setup_env

    step "Checking ports 80/443, preparing the data directory and the nginx config"
    check_port_free
    prepare_data_dir
    prepare_nginx_dir

    step "Building and starting nginx and fakeapp"
    compose up -d --build --wait
    check_https || true

    step "Obtaining the Let's Encrypt certificate"
    issue_certificate || true

    step "Installing the certificate renewal timer"
    install_renew_timer

    run_extensions

    CURRENT_STEP="summary"
    printf '\n%sInstall finished.%s\n' "$C_BOLD" "$C_RESET" >&2
    print_summary
}

cmd_extensions() {
    local id
    if ((!${#EXT_IDS[@]})); then
        echo "no extensions installed (see extensions.d/README.md)"
        return 0
    fi
    for id in "${EXT_IDS[@]}"; do
        printf '%-20s %s\n' "$id" "${EXT_TITLE[$id]}"
    done
    if [[ -n "${WITH_EXT:-}" ]]; then
        require_root "extensions --with"
        select_extensions
        STEP_TOTAL=$(wc -w <<<"$EXT_SELECTED")
        run_extensions
    fi
}

# refresh_nginx_conf: re-render the config before (re)starting; not fatal for
# users that may only run docker (the existing file is then used).
refresh_nginx_conf() {
    prepare_nginx_dir >/dev/null 2>&1 || warn "could not refresh the nginx config in $NGINX_DATA (need root?); using the existing one"
}

cmd_start() {
    require_installed
    require_docker
    refresh_nginx_conf
    compose up -d --wait
    check_https || true
}

cmd_stop() {
    require_installed
    require_docker
    compose stop
}

cmd_restart() {
    require_installed
    require_docker
    refresh_nginx_conf
    compose restart
    compose up -d --wait
    check_https || true
}

cmd_status() {
    require_installed
    require_docker
    compose ps
    printf 'Certificate: %s\n' "$(cert_summary)"
    printf 'Renewal    : %s\n' "$(renew_timer_state)"
    check_https || exit 1
}

cmd_logs() {
    require_installed
    require_docker
    compose logs -f --tail 100
}

cmd_renew() {
    require_installed
    require_docker
    STEP_TOTAL=1
    step "Renewing the certificates"
    renew_certificates
}

# remove_data_dir PATH: delete a data directory (refuses odd paths).
remove_data_dir() {
    local path=$1
    [[ "$path" =~ ^/[^/]+/[^/]+ && "$path" != "$HOME" ]] || die "refusing to delete suspicious path '$path'"
    [[ -e "$path" ]] || return 0
    rm -rf "$path" || warn "could not fully delete $path"
}

cmd_remove() {
    require_root remove
    STEP_TOTAL=$((PURGE ? 3 : 2))
    local data_dir=""
    [[ -f "$APP_DIR/.env" ]] && data_dir="$(fakeapp_data_dir)"

    if ((PURGE)); then
        confirm "Remove the containers, their images, the renewal timer and the data (${data_dir:+$data_dir, }$NGINX_DATA, $LE_DIR)?" || die "aborted"
    else
        confirm "Stop and remove the containers, their images and the renewal timer (data and certificates are kept)?" || die "aborted"
    fi

    step "Removing the renewal timer"
    remove_renew_timer

    step "Removing the containers and the images"
    if [[ -f "$APP_DIR/.env" ]] && command -v docker >/dev/null 2>&1 && daemon_ok; then
        compose down --remove-orphans --rmi local
    else
        warn "docker or $APP_DIR/.env not available; skipping 'docker compose down'"
    fi

    if ((!PURGE)); then
        info "data${data_dir:+ in $data_dir}, $NGINX_DATA, $LE_DIR and .env were kept (use --purge to delete the data)"
        return 0
    fi

    step "Deleting the data"
    [[ -z "$data_dir" ]] || remove_data_dir "$data_dir"
    remove_data_dir "$NGINX_DATA"
    remove_data_dir "$LE_DIR"
    info ".env, the project directory and Docker were kept"
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
            --with)
                (($# > 1)) || die "--with needs a value"
                WITH_EXT="$2"
                shift
                ;;
            --with=*) WITH_EXT="${1#--with=}" ;;
            install | start | stop | restart | status | logs | renew | remove | extensions)
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
    load_extensions
    ((!PURGE)) || [[ "$cmd" == remove ]] || die "--purge only applies to 'remove'"
    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
    "cmd_$cmd"
}

# Sourcing with FAKEAPP_SH_LIB=1 only defines the functions (used by tests).
if [[ -n "${FAKEAPP_SH_LIB:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
main "$@"
