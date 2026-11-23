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
#   1 COLLECT  - every question is asked here (language, install directory,
#                domain, e-mail, site identity, the choice of extensions, their
#                own questions); the environment / flags override the prompts.
#                Nothing is changed.
#   2 VALIDATE - all collected values are checked together (and the host:
#                ports, DNS); every problem is reported at once and a fatal one
#                aborts before anything is deployed.
#   3 DEPLOY   - packages, Docker, .env, config, build, start, certificate,
#                extensions. No questions are asked any more.
# Run from a source checkout / download (CODE_DIR is not the install directory)
# it is two-stage: stage 1 asks the language and the directory, validates the
# directory, copies the project there (sync_to_install_dir) and re-executes the
# installed install.sh (ESCAPE_STAGE2=1), which continues with the rest.
cmd_install() {
    require_root install
    [[ -n "${ESCAPE_TEST_SYNC_ONLY:-}" ]] || check_system_tools

    if [[ -z "${ESCAPE_STAGE2:-}" ]]; then
        ask_language
        phase 1 "$(t phase.collect)"
        ask_install_dir
        validate_language
        # An unusable directory is reported now, before more questions are asked.
        ((!${#PROBLEMS[@]})) || finish_validation
        if [[ "$APP_DIR" != "$CODE_DIR" ]]; then
            sync_to_install_dir
            hand_over_to_install
        fi
    else
        # Stage 2: the directory was chosen and validated by stage 1.
        APP_DIR="${ESCAPE_DIR:?}"
        init_paths
        if [[ -n "${ESCAPE_TEST_SYNC_ONLY:-}" ]]; then
            printf 'test mode (ESCAPE_TEST_SYNC_ONLY): stage 2 started in %s; stopping before the deploy\n' "$APP_DIR" >&2
            exit 0
        fi
    fi
    load_extensions
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
    STEP_TOTAL=$((8 + ext_count))

    step "$(t dir.step_register "$POINTER_FILE")"
    register_install_dir

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

# remove_install_dir: delete the install directory itself (purge): only a
# directory that carries the marker and is not a system path.
remove_install_dir() {
    local d="$APP_DIR"
    is_installation "$d" && ! install_dir_is_system "$d" && [[ "$d" =~ ^/[^/]+/[^/]+ && "$d" != "$HOME" ]] ||
        die "$(t cmd.suspicious "$d")"
    cd /
    rm -rf -- "${d:?}" || warn "$(t cmd.delete_fail "$d")"
}

cmd_remove() {
    require_root remove
    STEP_TOTAL=$((PURGE ? 4 : 2))
    local data_dir="" id hook
    [[ -f "$APP_DIR/.env" ]] && data_dir="$(fakeapp_data_dir)"

    if ((PURGE)); then
        confirm "$(t cmd.confirm_purge "${data_dir:+$data_dir, }$NGINX_DATA, $LE_DIR" "$APP_DIR")" || die "$(t common.aborted)"
    else
        confirm "$(t cmd.confirm_remove)" || die "$(t common.aborted)"
    fi

    step "$(t cmd.step_rm_timer)"
    remove_renew_timer

    # Purge: the system files of the extensions (units, sysctl, firewall rules)
    # go first, while the stack still runs (their hooks use compose and nginx).
    if ((PURGE)); then
        step "$(t cmd.step_rm_ext)"
        for id in "${EXT_IDS[@]}"; do
            hook="$(ext_hook "$id" purge)"
            [[ -n "$hook" ]] || continue
            ext_load_lang "$id"
            "$hook" || warn "$(t cmd.ext_purge_fail "$id")"
        done
    fi

    step "$(t cmd.step_rm_containers)"
    if [[ -f "$APP_DIR/.env" ]] && command -v docker >/dev/null 2>&1 && daemon_ok; then
        compose down --remove-orphans --rmi local
    else
        warn "$(t cmd.rm_skip_down "$APP_DIR/.env")"
    fi

    if ((!PURGE)); then
        info "$(t cmd.rm_kept "${data_dir:+$data_dir, }$NGINX_DATA, $LE_DIR" "$APP_DIR")"
        return 0
    fi

    step "$(t cmd.step_rm_data)"
    [[ -z "$data_dir" ]] || remove_data_dir "$data_dir"
    unregister_install_dir
    remove_install_dir
    info "$(t cmd.rm_done "$APP_DIR")"
}

main() {
    local cmd="" show_help=0
    ORIG_ARGS=("$@")
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
            --dir)
                (($# > 1)) || die "$(t cmd.dir_needs_value)"
                DIR_FLAG="$2"
                shift
                ;;
            --dir=*) DIR_FLAG="${1#--dir=}" ;;
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
    ((!PURGE)) || [[ "$cmd" == remove ]] || die "$(t cmd.purge_only)"
    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
    if [[ "$cmd" != install ]]; then
        # Every other command runs the installed copy (resolve_app_dir re-executes it).
        resolve_app_dir
        init_paths
        load_extensions
    fi
    "cmd_$cmd"
}
