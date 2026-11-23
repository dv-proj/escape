# lib/commands.sh - usage text, the cmd_* command handlers and main.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

usage() {
    printf '%s\n' "$(t usage)"
}

require_installed() {
    [[ -f "$APP_DIR/.env" ]] || die "$(t cmd.no_env "$APP_DIR/.env")"
}

# cmd_install: three explicit phases (the same for every extension):
#   1 COLLECT  - every question is asked here (domain, e-mail, site identity,
#                the choice of extensions, their own questions); the
#                environment / flags override the prompts. Nothing is changed.
#   2 VALIDATE - all collected values are checked together (and the host:
#                ports, DNS); every problem is reported at once and a fatal one
#                aborts before anything is changed.
#   3 DEPLOY   - packages, Docker, .env, config, build, start, certificate,
#                extensions. No questions are asked any more.
cmd_install() {
    require_root install
    check_system_tools

    ask_language
    phase 1 "$(t phase.collect)"
    collect_env
    collect_extensions

    phase 2 "$(t phase.validate)"
    validate_language
    check_project
    validate_env
    validate_ports
    validate_domain_dns
    validate_extensions
    finish_validation

    phase 3 "$(t phase.deploy)"
    local ext_count
    ext_count=$(wc -w <<<"$EXT_SELECTED")
    STEP_TOTAL=$((7 + ext_count))

    step "$(t cmd.step_prereqs "${PREREQ_PKGS[*]}")"
    install_prereqs

    step "$(t cmd.step_docker)"
    ensure_docker

    step "$(t cmd.step_env)"
    setup_env

    step "$(t cmd.step_data)"
    prepare_data_dir
    prepare_nginx_dir

    step "$(t cmd.step_stack)"
    compose up -d --build --wait
    check_https || true

    step "$(t cmd.step_cert)"
    issue_certificate || true

    step "$(t cmd.step_timer)"
    install_renew_timer

    run_extensions

    CURRENT_STEP="$(t cmd.step_summary)"
    printf '\n%s%s%s\n' "$C_BOLD" "$(t cmd.finished)" "$C_RESET" >&2
    print_summary
    print_results
}

cmd_extensions() {
    local id
    if ((!${#EXT_IDS[@]})); then
        t ext.none
        echo
        return 0
    fi
    for id in "${EXT_IDS[@]}"; do
        printf '%-20s %s\n' "$id" "$(ext_title "$id")"
    done
    if [[ -n "${WITH_EXT:-}" ]]; then
        require_root "extensions --with"
        ask_language
        phase 1 "$(t phase.collect)"
        collect_extensions
        phase 2 "$(t phase.validate)"
        validate_language
        validate_extensions
        finish_validation
        phase 3 "$(t phase.deploy)"
        STEP_TOTAL=$(wc -w <<<"$EXT_SELECTED")
        run_extensions
    fi
}

# refresh_nginx_conf: re-render the config before (re)starting; not fatal for
# users that may only run docker (the existing file is then used).
refresh_nginx_conf() {
    prepare_nginx_dir >/dev/null 2>&1 || warn "$(t cmd.refresh_warn "$NGINX_DATA")"
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

cmd_info() {
    require_installed
    print_results
}

cmd_status() {
    require_installed
    require_docker
    compose ps
    printf '%s\n' "$(t cmd.status_cert "$(cert_summary)")"
    printf '%s\n' "$(t cmd.status_renew "$(renew_timer_state)")"
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
    step "$(t cmd.step_renew)"
    renew_certificates
}

# remove_data_dir PATH: delete a data directory (refuses odd paths).
remove_data_dir() {
    local path=$1
    [[ "$path" =~ ^/[^/]+/[^/]+ && "$path" != "$HOME" ]] || die "$(t cmd.suspicious "$path")"
    [[ -e "$path" ]] || return 0
    rm -rf "$path" || warn "$(t cmd.delete_fail "$path")"
}

cmd_remove() {
    require_root remove
    STEP_TOTAL=$((PURGE ? 3 : 2))
    local data_dir=""
    [[ -f "$APP_DIR/.env" ]] && data_dir="$(fakeapp_data_dir)"

    if ((PURGE)); then
        confirm "$(t cmd.confirm_purge "${data_dir:+$data_dir, }$NGINX_DATA, $LE_DIR")" || die "$(t common.aborted)"
    else
        confirm "$(t cmd.confirm_remove)" || die "$(t common.aborted)"
    fi

    step "$(t cmd.step_rm_timer)"
    remove_renew_timer

    step "$(t cmd.step_rm_containers)"
    if [[ -f "$APP_DIR/.env" ]] && command -v docker >/dev/null 2>&1 && daemon_ok; then
        compose down --remove-orphans --rmi local
    else
        warn "$(t cmd.rm_skip_down "$APP_DIR/.env")"
    fi

    if ((!PURGE)); then
        info "$(t cmd.rm_kept "${data_dir:+$data_dir, }$NGINX_DATA, $LE_DIR")"
        return 0
    fi

    step "$(t cmd.step_rm_data)"
    [[ -z "$data_dir" ]] || remove_data_dir "$data_dir"
    remove_data_dir "$NGINX_DATA"
    remove_data_dir "$LE_DIR"
    info "$(t cmd.rm_done)"
}

main() {
    local cmd="" show_help=0
    while (($#)); do
        case "$1" in
            -h | --help | help) show_help=1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            --purge) PURGE=1 ;;
            --with)
                (($# > 1)) || die "$(t cmd.with_needs_value)"
                WITH_EXT="$2"
                shift
                ;;
            --with=*) WITH_EXT="${1#--with=}" ;;
            --lang)
                (($# > 1)) || die "$(t cmd.lang_needs_value)"
                LANG_FLAG="$2"
                shift
                ;;
            --lang=*) LANG_FLAG="${1#--lang=}" ;;
            install | start | stop | restart | status | info | logs | renew | remove | extensions)
                [[ -z "$cmd" ]] || die "$(t cmd.one_command "$cmd" "$1")"
                cmd="$1"
                ;;
            *) die "$(t cmd.unknown_arg "$1")" ;;
        esac
        shift
    done
    i18n_init
    if ((show_help)); then
        usage
        exit 0
    fi
    [[ -n "$cmd" ]] || {
        usage >&2
        exit 2
    }
    load_extensions
    ((!PURGE)) || [[ "$cmd" == remove ]] || die "$(t cmd.purge_only)"
    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
    "cmd_$cmd"
}
