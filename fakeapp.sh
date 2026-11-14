#!/usr/bin/env bash
# fakeapp.sh - deploy the decoy web application (fake-webapp) next to an
# existing Xray / 3X-UI install on Ubuntu/Debian.
#
# Run `./fakeapp.sh --help` for usage. The service is defined in
# fake-webapp/docker-compose.yml (included by docker-compose.yml). This script
# makes sure Docker with the compose plugin is available (the system Docker is
# reused, Docker CE is installed only when there is none), generates .env and
# the decoy page, and starts one container that listens on
# FAKEAPP_BIND:FAKEAPP_PORT (default 127.0.0.1:8080, plain HTTP). It never
# touches nginx, Xray, 3X-UI, certificates or the firewall: add the app to
# your nginx yourself (see README.md, or `./fakeapp.sh snippet`).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR"

PREREQ_PKGS=(curl ca-certificates iproute2 python3)
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

ASSUME_YES=0
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

Deploys the decoy web application (fake-webapp) as one Docker container next
to an existing Xray / 3X-UI install. The app listens on FAKEAPP_BIND:
FAKEAPP_PORT of the host (default 127.0.0.1:8080, plain HTTP and h2c); TLS,
certificates and routing stay with your own nginx (see README.md).
Target systems: Ubuntu 22.04+ and Debian 12+.

Commands:
  install   Idempotent setup (root/sudo): reuses the system Docker (installs
            Docker CE only when docker is missing, the compose plugin when it
            is missing), creates .env (asks for the site name, description,
            keywords, DNS name and local port; the rest is generated),
            generates the missing login.html and favicon.ico, builds and
            starts the container. Re-running rebuilds and restarts it;
            existing .env values and files in the data directory are kept.
  start     Start the container (docker compose up -d --wait).
  stop      Stop the container.
  restart   Restart the container (e.g. after editing login.html).
  status    Show the container state and check http://127.0.0.1:PORT/.
  logs      Follow the container log (Ctrl+C to quit).
  snippet   Print an nginx location block that proxies to the app.
  remove    Remove the container and its image (root/sudo). With --purge
            also delete the data directory (login.html, favicon.ico and
            your static files). .env, the project and Docker are kept.

Options:
  -y, --yes   Assume "yes" for every confirmation.
  --purge     With `remove`: also delete the data directory.
  -h, --help  Show this help.

Environment (used when install creates .env, without prompting):
  APP_NAME, APP_DESCRIPTION, APP_KEYWORDS, DOMAIN, FAKEAPP_PORT
              Unset APP_* values are generated at random (offered as defaults
              when interactive). Without a terminal every prompt uses its
              default (FAKEAPP_PORT: the first free port from 8080).

Notes:
  * Nothing is published to the internet: the app trusts X-Real-IP, keep
    FAKEAPP_BIND=127.0.0.1 and let nginx on the same host proxy to it.
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
    env -i -C "$APP_DIR" \
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "HOME=${HOME:-/root}" "LANG=C.UTF-8" "TERM=${TERM:-dumb}" \
        docker compose "$@"
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
        read -r -p "DNS name of the site served by your nginx, e.g. app.example.com (empty: none): " v || die "no input"
    fi
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [[ -z "${DOMAIN:-}" ]] || info "DOMAIN (from environment): $v"
    ENV_VALUES[DOMAIN]="$v"
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
    [[ "$1" == DOMAIN ]]
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
    ask FAKEAPP_PORT "Local port of the app (nginx will proxy to 127.0.0.1:PORT)" \
        "$(first_free_port 8080)" valid_free_port "a free TCP port 1024-65535"
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
    for f in docker-compose.yml .env.example fake-webapp/docker-compose.yml fake-webapp/Dockerfile \
        fake-webapp/gen/login.py fake-webapp/gen/favicon.py; do
        [[ -f "$APP_DIR/$f" ]] || die "$f missing in $APP_DIR"
    done
    ok "project: $APP_DIR"
}

setup_env() {
    local envf="$APP_DIR/.env"
    if [[ -f "$envf" ]]; then
        ok "$envf exists; reusing it (no questions asked)"
        sync_env_with_example "$envf" "$APP_DIR/.env.example"
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

# fakeapp_bind: FAKEAPP_BIND from .env (default 127.0.0.1).
fakeapp_bind() {
    local b
    b="$(env_get "$APP_DIR/.env" FAKEAPP_BIND)"
    printf '%s' "${b:-127.0.0.1}"
}

# fakeapp_url_host: address nginx on this host uses to reach the app.
fakeapp_url_host() {
    local b
    b="$(fakeapp_bind)"
    case "$b" in
        0.0.0.0 | '' ) printf '127.0.0.1' ;;
        *:*) printf '[%s]' "$b" ;;
        *) printf '%s' "$b" ;;
    esac
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

# check_port_free: the port of .env must be free, or already ours.
check_port_free() {
    local port bind
    port="$(fakeapp_port)"
    bind="$(fakeapp_bind)"
    [[ "$bind" == 127.0.0.1 || "$bind" == ::1 ]] ||
        warn "FAKEAPP_BIND=$bind: the app is reachable beyond localhost; it trusts X-Real-IP, so block the port in the firewall"
    if port_in_use "$port" && [[ -z "$(compose ps -q fakeapp 2>/dev/null)" ]]; then
        die "port $port is already in use by another program (ss -ltnp 'sport = :$port'); set another FAKEAPP_PORT in $APP_DIR/.env and re-run install"
    fi
    ok "port $port on $bind"
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

# check_http: the app answers 200 on / of the published port.
check_http() {
    local url
    url="http://$(fakeapp_url_host):$(fakeapp_port)/"
    if curl -fs -o /dev/null --max-time 5 "$url"; then
        ok "$url answers"
    else
        warn "$url does not answer (see: ./fakeapp.sh logs)"
        return 1
    fi
}

# --- nginx snippet and summary ---------------------------------------------------------------------

print_snippet() {
    local up
    up="http://$(fakeapp_url_host):$(fakeapp_port)"
    cat <<EOS
# fake-webapp: put this into the server { } block of your site (see README.md).
# Locations of Xray (ws/grpc/xhttp paths) and the 3X-UI panel stay as they are;
# everything else goes to the decoy site.
location / {
    proxy_pass $up;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    # The app rate-limits by X-Real-IP: always overwrite it.
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_connect_timeout 5s;
    proxy_read_timeout 60s;
}
EOS
}

print_summary() {
    local envf="$APP_DIR/.env" domain up
    domain="$(env_get "$envf" DOMAIN)"
    up="http://$(fakeapp_url_host):$(fakeapp_port)"
    printf '\n'
    printf 'App name  : %s\n' "$(env_get "$envf" APP_NAME)"
    printf 'Upstream  : %s/ (published on %s; point nginx here)\n' "$up" "$(fakeapp_bind)"
    if [[ -n "$domain" ]]; then
        printf 'Site      : https://%s/ (canonical link and og:url; TLS is up to your nginx)\n' "$domain"
    else
        printf 'Site      : no DOMAIN set (canonical link and og:url are not emitted)\n'
    fi
    printf 'Random    : %s/random-%s?size=1000 (0-500000 bytes)\n' "$up" "$(env_get "$envf" RANDOM_DATA_SUFFIX)"
    printf 'Files     : %s (login.html: ./fakeapp.sh restart after editing; other files are served as is)\n' "$(fakeapp_data_dir)"
    printf '\nNext: add the app to your nginx (README.md, section "nginx"). Ready block:\n'
    printf '  ./fakeapp.sh snippet\n'
}

# --- commands -----------------------------------------------------------------------------------------

require_installed() {
    [[ -f "$APP_DIR/.env" ]] || die "$APP_DIR/.env not found; run: sudo ./fakeapp.sh install"
}

cmd_install() {
    require_root install
    STEP_TOTAL=6
    check_system_tools

    step "Checking the project directory"
    check_project

    step "Installing prerequisites (${PREREQ_PKGS[*]})"
    install_prereqs

    step "Checking Docker and docker compose"
    ensure_docker

    step "Preparing .env"
    setup_env

    step "Preparing the port and the data directory (login.html, favicon.ico)"
    check_port_free
    prepare_data_dir

    step "Building and starting fakeapp"
    compose up -d --build --wait
    check_http || true

    CURRENT_STEP="summary"
    printf '\n%sInstall finished.%s\n' "$C_BOLD" "$C_RESET" >&2
    print_summary
}

cmd_start() {
    require_installed
    require_docker
    compose up -d --wait
    check_http || true
}

cmd_stop() {
    require_installed
    require_docker
    compose stop
}

cmd_restart() {
    require_installed
    require_docker
    compose restart
    compose up -d --wait
    check_http || true
}

cmd_status() {
    require_installed
    require_docker
    compose ps
    check_http || exit 1
}

cmd_logs() {
    require_installed
    require_docker
    compose logs -f --tail 100
}

cmd_snippet() {
    require_installed
    print_snippet
}

# remove_data_dir PATH: delete the data directory (refuses odd paths).
remove_data_dir() {
    local path=$1
    [[ "$path" =~ ^/[^/]+/[^/]+ && "$path" != "$HOME" ]] || die "refusing to delete suspicious path '$path'"
    [[ -e "$path" ]] || return 0
    rm -rf "$path" || warn "could not fully delete $path"
}

cmd_remove() {
    require_root remove
    STEP_TOTAL=$((PURGE ? 2 : 1))
    local data_dir=""
    [[ -f "$APP_DIR/.env" ]] && data_dir="$(fakeapp_data_dir)"

    if ((PURGE)); then
        confirm "Remove the container, its image and the data directory${data_dir:+ $data_dir}?" || die "aborted"
    else
        confirm "Stop and remove the container and its image (data is kept)?" || die "aborted"
    fi

    step "Removing the container and the image"
    if [[ -f "$APP_DIR/.env" ]] && command -v docker >/dev/null 2>&1 && daemon_ok; then
        compose down --remove-orphans --rmi local
    else
        warn "docker or $APP_DIR/.env not available; skipping 'docker compose down'"
    fi

    if ((!PURGE)); then
        info "data${data_dir:+ in $data_dir} and .env were kept (use --purge to delete the data)"
        info "remember to remove the fake-webapp location from your nginx config"
        return 0
    fi

    step "Deleting the data${data_dir:+ ($data_dir)}"
    [[ -z "$data_dir" ]] || remove_data_dir "$data_dir"
    info ".env, the project directory and Docker were kept"
    info "remember to remove the fake-webapp location from your nginx config"
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
            install | start | stop | restart | status | logs | snippet | remove)
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
    "cmd_$cmd"
}

# Sourcing with FAKEAPP_SH_LIB=1 only defines the functions (used by tests).
if [[ -n "${FAKEAPP_SH_LIB:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
main "$@"
