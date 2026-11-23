# lib/app.sh - the project itself: file checks, data directory, status/HTTP checks and the final summary.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

# check_project: phase 2: the project files are all there. Missing files are
# recorded as problems.
check_project() {
    local f missing=0
    for f in docker-compose.yml .env.example nginx/docker-compose.yml nginx/default.conf.template \
        fake-webapp/docker-compose.yml fake-webapp/Dockerfile fake-webapp/gen/login.py fake-webapp/gen/favicon.py; do
        [[ -f "$APP_DIR/$f" ]] || {
            problem "$(t app.missing_file "$f" "$APP_DIR")"
            missing=1
        }
    done
    ((missing)) || ok "$(t app.project_ok "$APP_DIR")"
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
        mkdir -p "$d" || die "$(t app.cant_create "$d")"
        chown "$owner" "$d"
    fi
    if [[ -e "$d/login.html" ]]; then
        ok "$(t app.file_kept "$d/login.html")"
    else
        python3 "$gen/login.py" --seed "$seed" --out "$d/login.html" || die "$(t app.login_fail)"
        chown "$owner" "$d/login.html"
        ok "$(t app.file_generated "$d/login.html")"
    fi
    if [[ -e "$d/favicon.ico" ]]; then
        ok "$(t app.file_kept "$d/favicon.ico")"
    else
        python3 "$gen/favicon.py" --seed "$seed" --name="$name" --out "$d/favicon.ico" ||
            die "$(t app.favicon_fail)"
        chown "$owner" "$d/favicon.ico"
        ok "$(t app.file_generated "$d/favicon.ico")"
    fi
    chmod -R a+rX "$d" || warn "$(t app.not_readable "$d")"
    ok "$(t app.readable "$d")"
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
        ok "$(t app.https_ok "$url")"
    elif curl -fsk -o /dev/null --max-time 8 --resolve "$domain:$port:127.0.0.1" "$url"; then
        warn "$(t app.https_untrusted "$url")"
    else
        warn "$(t app.https_down "$url")"
        return 1
    fi
}

print_summary() {
    local envf="$APP_DIR/.env" domain port suffix=""
    domain="$(site_domain)"
    port="$(nginx_https_port)"
    [[ "$port" == 443 ]] || suffix=":$port"
    printf '\n'
    printf '%s\n' "$(t app.sum_name "$(env_get "$envf" APP_NAME)")"
    printf '%s\n' "$(t app.sum_site "$domain" "$suffix" "$(nginx_http_port)" "$port" "$(fakeapp_port)")"
    printf '%s\n' "$(t app.sum_cert "$(cert_summary)")"
    printf '%s\n' "$(t app.sum_renew "$(renew_timer_state)")"
    printf '%s\n' "$(t app.sum_files "$(fakeapp_data_dir)")"
    printf '%s\n' "$(t app.sum_nginx "$NGINX_DATA" "$NGINX_DATA")"
}

# print_results: the final data the user needs, on stdout (so it can be copied
# or captured): the random-data URL of the decoy app and, for every installed
# extension that defines ext_<id>_result, its lines (e.g. the web-proxy link).
print_results() {
    local envf="$APP_DIR/.env" domain port suffix="" id hook
    domain="$(site_domain)"
    port="$(nginx_https_port)"
    [[ "$port" == 443 ]] || suffix=":$port"
    printf '\n%s\n' "$(t app.res_header)"
    printf '%s\n' "$(t app.res_random "$domain" "$suffix" "$(env_get "$envf" RANDOM_DATA_SUFFIX)")"
    for id in "${EXT_IDS[@]}"; do
        hook="$(ext_hook "$id" result)"
        [[ -n "$hook" ]] || continue
        ext_load_lang "$id"
        "$hook"
    done
    printf '\n'
}
