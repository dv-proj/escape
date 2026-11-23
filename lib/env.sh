# lib/env.sh - .env handling: validators, prompts, generation from .env.example, syncing and readers.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

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

# fmt_env_value VALUE: bare when plain, single-quoted otherwise (literal for
# docker compose). Callers reject ' and $.
fmt_env_value() {
    if [[ "$1" =~ ^[A-Za-z0-9_./:@+,-]*$ ]]; then
        printf '%s' "$1"
    else
        printf "'%s'" "$1"
    fi
}

declare -gA ENV_VALUES=()
# How the collected values are validated later (validate_env): validator
# function, hint and where the value came from (environment | input).
declare -gA ENV_CHECK_FN=() ENV_CHECK_HINT=() ENV_CHECK_SRC=()
# 1 when collect_env found no .env and collected the values of a new one.
ENV_NEW=0

# env_check KEY VALIDATOR HINT SOURCE: remember to validate ENV_VALUES[KEY] in
# the validate phase (a bad value from the environment is reported there,
# together with all other problems, instead of aborting the questions).
env_check() {
    ENV_CHECK_FN[$1]=$2
    ENV_CHECK_HINT[$1]=$3
    ENV_CHECK_SRC[$1]=$4
}

# ask KEY LABEL DEFAULT VALIDATOR HINT: store the value in ENV_VALUES[KEY].
# A non-empty KEY in the environment is used without prompting; without a
# terminal the default is used (an empty default means the value is required).
ask() {
    local key=$1 label=$2 default=$3 validator=$4 hint=$5 value=""
    if [[ -n "${!key:-}" ]]; then
        value="${!key}"
        env_check "$key" "$validator" "$hint" environment
        info "$(t env.from_environment "$key" "$value")"
    elif [[ ! -t 0 ]]; then
        if [[ -z "$default" ]]; then
            problem "$(t env.required_noterm "$key")"
            ENV_VALUES[$key]=""
            return 0
        fi
        value="$default"
        "$validator" "$value" || die "$(t env.default_invalid "$key" "$hint")"
        info "$(t env.from_default "$key" "$value")"
    else
        while :; do
            if [[ -n "$default" ]]; then
                read -r -p "$label [$default]: " value || die "$(t common.no_input)"
            else
                read -r -p "$label: " value || die "$(t common.no_input)"
            fi
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value:-$default}"
            if "$validator" "$value"; then
                break
            fi
            warn "$(t env.invalid_value "$hint")"
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
        env_check DOMAIN valid_domain "$(t hint.domain)" environment
        info "$(t env.from_environment DOMAIN "$v")"
    elif [[ -t 0 ]]; then
        while :; do
            read -r -p "$(t env.q_domain): " v || die "$(t common.no_input)"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
            valid_domain "$v" && break
            warn "$(t env.invalid_value "$(t hint.domain)")"
        done
    else
        problem "$(t env.required_noterm DOMAIN)"
    fi
    ENV_VALUES[DOMAIN]="${v,,}"
}

# ask_le_email: optional LE_EMAIL into ENV_VALUES[LE_EMAIL] (environment, else
# asked when interactive, else empty).
ask_le_email() {
    local v="${LE_EMAIL:-}"
    if [[ -n "$v" ]]; then
        env_check LE_EMAIL valid_email "$(t hint.email)" environment
        info "$(t env.from_environment LE_EMAIL "$v")"
    elif [[ -t 0 ]]; then
        while :; do
            read -r -p "$(t env.q_email): " v || die "$(t common.no_input)"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
            valid_email "$v" && break
            warn "$(t env.invalid_email)"
        done
    fi
    ENV_VALUES[LE_EMAIL]="$v"
}

# Keys of .env.example that may stay empty.
is_optional_key() {
    [[ "$1" == LE_EMAIL ]]
}

# ensure_generated_key FILE KEY GENERATOR_FN: fill KEY=<generated> in an existing
# .env when KEY is missing or empty; other lines are left untouched. The
# generator gets FILE as its first argument.
ensure_generated_key() {
    local file=$1 key=$2 gen=$3 val tmp line found=0
    [[ -n "$(env_get "$file" "$key")" ]] && return 0
    val="$("$gen" "$file")" || die "$(t env.cannot_generate "$key")"
    [[ -n "$val" ]] || die "$(t env.generator_empty "$key")"
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
    info "$(t env.added_key "$key" "$file")"
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
    [[ -f "$example" ]] || die "$(t env.no_template "$example")"
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
                info "$(t env.domain_set "$envf")"
            fi
            continue
        fi
        gen="$(generator_for "$key")"
        def="$(env_get "$example" "$key")"
        if [[ -n "$gen" ]]; then
            val="$("$gen" "$envf")" || die "$(t env.cannot_generate "$key")"
        elif [[ "$key" == FAKEAPP_LANG ]]; then
            val="$FAKEAPP_LANG_ACTIVE"
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
            die "$(t env.missing_no_default "$key" "$envf")"
        fi
        [[ -n "$val" ]] || is_optional_key "$key" || die "$(t env.no_value "$key")"
        block="$(example_comment_block "$example" "$key")"
        [[ -z "$(tail -c1 "$envf")" ]] || printf '\n' >>"$envf"
        {
            printf '\n'
            [[ -z "$block" ]] || printf '%s\n' "$block"
            printf '%s=%s\n' "$key" "$(fmt_env_value "$val")"
        } >>"$envf"
        info "$(t env.added_key "$key" "$envf")"
    done
}

# generate_env EXAMPLE OUT: build OUT (mode 600) from EXAMPLE, prompting for
# manual values and generating the rest (collect_env_values + write_env_file).
generate_env() {
    collect_env_values "$1"
    write_env_file "$1" "$2"
}

# collect_env_values EXAMPLE: ask for the manual values (the environment
# overrides the prompts; without a terminal the defaults are used) and generate
# the rest, all into ENV_VALUES. Writes nothing: a bad value from the
# environment is only recorded (env_check) and reported by validate_env.
collect_env_values() {
    local example=$1 def_tz
    [[ -f "$example" ]] || die "$(t env.no_template "$example")"
    ENV_VALUES=()
    ENV_VALUES[FAKEAPP_LANG]="$FAKEAPP_LANG_ACTIVE"

    gen_app_trio
    ask APP_NAME "$(t env.q_app_name)" "$GEN_APP_NAME" valid_text "$(t hint.text)"
    ask APP_DESCRIPTION "$(t env.q_app_desc)" "$GEN_APP_DESCRIPTION" valid_text "$(t hint.text)"
    ask APP_KEYWORDS "$(t env.q_app_kw)" "$GEN_APP_KEYWORDS" valid_text "$(t hint.text)"
    ask_domain
    ask_le_email
    # Not asked: taken from the environment when set (else the .env.example default).
    local ev
    for ev in FAKEAPP_PORT NGINX_HTTP_PORT NGINX_HTTPS_PORT LE_STAGING; do
        [[ -n "${!ev:-}" ]] || continue
        case "$ev" in
            LE_STAGING) env_check "$ev" valid_01 "$(t hint.01)" environment ;;
            *) env_check "$ev" valid_port "$(t hint.port)" environment ;;
        esac
        ENV_VALUES[$ev]="${!ev}"
        info "$(t env.from_environment "$ev" "${!ev}")"
    done
    def_tz="$(host_timezone)"
    # TZ is deliberately not read from the environment (often set to odd values).
    local saved_tz="${TZ-__unset__}"
    unset TZ
    ask TZ "$(t env.q_tz)" "$def_tz" valid_tz "$(t hint.tz)"
    if [[ "$saved_tz" != __unset__ ]]; then export TZ="$saved_tz"; fi

    ENV_VALUES[RANDOM_DATA_SUFFIX]="$(gen_random_data_suffix)"
    ENV_VALUES[PAGE_SEED]="$(gen_page_seed)"
    ENV_VALUES[RATE_LIMIT_RPS]="$(gen_rate_limit_rps)"
    ENV_VALUES[RATE_LIMIT_BURST]="$(gen_rate_limit_burst)"
    ENV_VALUES[RATE_LIMIT_GLOBAL_RPS]="$(gen_rate_limit_global_rps)"
    ENV_VALUES[LOGIN_DELAY_MIN_MS]="$(gen_login_delay_min)"
    ENV_VALUES[LOGIN_DELAY_MAX_MS]=$((ENV_VALUES[LOGIN_DELAY_MIN_MS] + $(rand_int 300 900)))
}

# write_env_file EXAMPLE OUT: write OUT (mode 600) from EXAMPLE and ENV_VALUES.
# Never edits with sed: the template is rewritten line by line, so special
# characters in values are harmless.
write_env_file() {
    local example=$1 out=$2 line key k v tmp
    [[ -f "$example" ]] || die "$(t env.no_template "$example")"
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
            die "$(t env.empty_generated "$k")"
        fi
    done <"$example"
    mv -f "$tmp" "$out"
}

setup_env() {
    local envf="$APP_DIR/.env"
    if [[ -f "$envf" ]]; then
        ok "$(t env.reusing "$envf")"
        sync_env_with_example "$envf" "$APP_DIR/.env.example"
        valid_domain "$(env_get "$envf" DOMAIN)" || die "$(t env.domain_bad_fix "$envf")"
        # The language of this run (--lang / FAKEAPP_LANG) is the one kept in .env.
        if [[ "$(env_get "$envf" FAKEAPP_LANG)" != "$FAKEAPP_LANG_ACTIVE" ]]; then
            env_set "$envf" FAKEAPP_LANG "$FAKEAPP_LANG_ACTIVE"
            info "$(t env.lang_saved "$FAKEAPP_LANG_ACTIVE" "$envf")"
        fi
        return 0
    fi
    info "$(t env.creating "$envf")"
    # Normally collected up front (collect_env); standalone callers get it here.
    ((${#ENV_VALUES[@]})) || collect_env_values "$APP_DIR/.env.example"
    write_env_file "$APP_DIR/.env.example" "$envf"
    chown "$(project_owner)" "$envf"
    chmod 600 "$envf"
    ok "$(t env.written "$envf")"
}

# env_value KEY: value of KEY from .env, or (no .env yet: new install in the
# collect/validate phases) from the collected ENV_VALUES.
env_value() {
    if [[ -f "$APP_DIR/.env" ]]; then
        env_get "$APP_DIR/.env" "$1"
    else
        printf '%s' "${ENV_VALUES[$1]:-}"
    fi
}

# collect_env: phase 1 for the core. An existing .env is reused without
# questions; otherwise the values of a new one are collected into ENV_VALUES
# (nothing is written until setup_env).
collect_env() {
    if [[ -f "$APP_DIR/.env" ]]; then
        ENV_NEW=0
        info "$(t env.reusing "$APP_DIR/.env")"
        return 0
    fi
    ENV_NEW=1
    collect_env_values "$APP_DIR/.env.example"
}

# validate_env: phase 2 for the core: the collected values (new .env) or the
# values of the existing .env. Problems are recorded, not fatal here.
validate_env() {
    local k key v envf="$APP_DIR/.env"
    if ((ENV_NEW)); then
        for k in "${!ENV_CHECK_FN[@]}"; do
            "${ENV_CHECK_FN[$k]}" "${ENV_VALUES[$k]}" ||
                problem "$(t env.invalid_from_env "$k" "${ENV_CHECK_HINT[$k]}")"
        done
    else
        valid_domain "$(env_get "$envf" DOMAIN)" ||
            problem "$(t env.domain_bad_fix "$envf")"
        for key in FAKEAPP_PORT NGINX_HTTP_PORT NGINX_HTTPS_PORT; do
            v="$(env_get "$envf" "$key")"
            [[ -z "$v" ]] || valid_port "$v" || problem "$(t env.port_range "$key" "$envf" "$v")"
        done
    fi
}

# fakeapp_port: FAKEAPP_PORT from .env (default 8080), validated.
fakeapp_port() {
    local p
    p="$(env_value FAKEAPP_PORT)"
    p="${p:-8080}"
    valid_port "$p" || die "$(t env.port_range FAKEAPP_PORT "$APP_DIR/.env" "$p")"
    printf '%s' "$p"
}

# env_or_default KEY DEFAULT: value of KEY from .env, else DEFAULT.
env_or_default() {
    local v
    v="$(env_value "$1")"
    printf '%s' "${v:-$2}"
}

site_domain() {
    local d
    d="$(env_value DOMAIN)"
    valid_domain "$d" || die "$(t env.domain_missing "$APP_DIR/.env" "$d")"
    printf '%s' "$d"
}
