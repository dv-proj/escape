# lib/instdir.sh - the install directory: choosing and validating it, copying the project into it (sync), finding it again.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash
#
# Terms (see README.md, "Install directory"):
#   SRC_DIR  = CODE_DIR of the first stage: the directory of the running
#              install.sh while it is a source checkout or the unpacked download.
#   APP_DIR  = the install directory (default /opt/escape): the allowlisted code
#              copied there by sync_to_install_dir, .env, data/ and scripts/.
#              Marked by the file $INSTALL_MARKER.
#   CODE_DIR = the directory of the running install.sh (modules, message files,
#              extensions are read from it); equal to APP_DIR once the install
#              has been handed over to the installed copy.
# `install` run from a source checkout / download is a two-stage run: stage 1
# asks the language and the directory, copies the sources and re-executes the
# installed install.sh (ESCAPE_STAGE2=1), which does the real work.
#
# Environment (all optional): ESCAPE_DIR (install directory; FAKEAPP_DIR is a
# deprecated alias), ESCAPE_STAGE2 (set by stage 1 for stage 2), and for tests
# only ESCAPE_POINTER_FILE (instead of /etc/escape/install-dir) and
# ESCAPE_TEST_SYNC_ONLY=1 (install needs no root, runs the questions and the
# sync, and stops at the start of stage 2 before anything is deployed).

DEFAULT_INSTALL_DIR=/opt/escape
INSTALL_MARKER=.escape-install
POINTER_FILE="${ESCAPE_POINTER_FILE:-/etc/escape/install-dir}"
# Value of --dir (set by main).
DIR_FLAG=""
# install_dir_hint results: the directory and where it came from
# (flag | ESCAPE_DIR | FAKEAPP_DIR | installed | pointer | "").
DIR_HINT=""
DIR_HINT_SRC=""
# The arguments install.sh was started with (stage 2 gets the same).
ORIG_ARGS=()

# What goes into the install directory (paths relative to the source directory).
# Single files, then the directories that are mirrored (files the source no
# longer has are removed from them), then the build context of the decoy app.
# Everything else (.git*, tests/, editor files, CLAUDE.md, ...) stays out.
SYNC_TOP_FILES=(install.sh docker-compose.yml .env.example README.md README.en.md)
SYNC_MIRROR_DIRS=(lib nginx extensions.d fake-webapp)
SYNC_FAKEAPP_FILES=(Dockerfile .dockerignore go.mod go.sum docker-compose.yml gen/login.py gen/favicon.py)
SYNC_REQUIRED=(install.sh docker-compose.yml .env.example nginx/docker-compose.yml nginx/default.conf.template
    fake-webapp/docker-compose.yml fake-webapp/Dockerfile fake-webapp/gen/login.py fake-webapp/gen/favicon.py lib/commands.sh)

is_installation() { [[ -f "$1/$INSTALL_MARKER" ]]; }

# install_dir_hint: the install directory that is already known, without
# asking or validating: --dir, ESCAPE_DIR, FAKEAPP_DIR (deprecated), the
# directory of this very install.sh when it is an installed copy, the pointer
# file. Sets DIR_HINT / DIR_HINT_SRC (both empty when nothing is known).
install_dir_hint() {
    DIR_HINT="" DIR_HINT_SRC=""
    if [[ -n "$DIR_FLAG" ]]; then
        DIR_HINT=$DIR_FLAG DIR_HINT_SRC=flag
    elif [[ -n "${ESCAPE_DIR:-}" ]]; then
        DIR_HINT=$ESCAPE_DIR DIR_HINT_SRC=ESCAPE_DIR
    elif [[ -n "${FAKEAPP_DIR:-}" ]]; then
        DIR_HINT=$FAKEAPP_DIR DIR_HINT_SRC=FAKEAPP_DIR
    elif is_installation "$CODE_DIR"; then
        DIR_HINT=$CODE_DIR DIR_HINT_SRC=installed
    elif [[ -r "$POINTER_FILE" ]]; then
        DIR_HINT="$(head -n1 "$POINTER_FILE" 2>/dev/null || true)"
        [[ -z "$DIR_HINT" ]] || DIR_HINT_SRC=pointer
    fi
    return 0
}

# install_dir_is_system PATH: a directory that must never be the install directory.
install_dir_is_system() {
    local p=$1 home
    case "$p" in
        / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /libx32 | /lost+found | /media | /mnt | /opt | /proc | /root | /run | /sbin | /snap | /srv | /sys | /tmp | /usr | /var) return 0 ;;
        /usr/bin | /usr/include | /usr/lib | /usr/lib64 | /usr/libexec | /usr/local | /usr/local/bin | /usr/local/lib | /usr/local/sbin | /usr/sbin | /usr/share | /usr/src) return 0 ;;
        /var/cache | /var/lib | /var/log | /var/mail | /var/opt | /var/run | /var/spool | /var/tmp) return 0 ;;
        /etc/* | /proc/* | /sys/* | /dev/* | /boot/* | /bin/* | /sbin/* | /lib/* | /lib32/* | /lib64/* | /libx32/* | /usr/bin/* | /usr/sbin/* | /usr/lib/* | /var/lib/docker/*) return 0 ;;
    esac
    # The home directory of any user itself.
    while IFS= read -r home; do
        [[ "$home" != "$p" ]] || return 0
    done < <(getent passwd 2>/dev/null | cut -d: -f6)
    return 1
}

# dir_has_only_state DIR: DIR contains nothing but .env and data/ (copied there
# beforehand when moving an old installation): usable as a new install directory.
dir_has_only_state() {
    local e
    while IFS= read -r e; do
        [[ "$e" == .env || "$e" == data ]] || return 1
    done < <(ls -A "$1" 2>/dev/null)
    return 0
}

# install_dir_problems DIR: one message per line for everything wrong with DIR
# as the install directory (nothing is printed when it is fine).
install_dir_problems() {
    local raw=$1 d anc
    if [[ "$raw" != /* ]]; then
        printf '%s\n' "$(t dir.not_absolute "$raw")"
        return 0
    fi
    d="$(realpath -m -- "$raw")"
    if install_dir_is_system "$d"; then
        printf '%s\n' "$(t dir.system "$d")"
        return 0
    fi
    if [[ ! "$d" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]; then
        printf '%s\n' "$(t dir.bad_chars "$d")"
        return 0
    fi
    if [[ -e "$d" || -L "$d" ]]; then
        if [[ ! -d "$d" ]]; then
            printf '%s\n' "$(t dir.not_dir "$d")"
        elif is_installation "$d"; then
            [[ -w "$d" ]] || printf '%s\n' "$(t dir.not_writable "$d")"
        elif [[ "$d" == "$CODE_DIR" ]]; then
            printf '%s\n' "$(t dir.is_checkout "$d")"
        elif dir_has_only_state "$d"; then
            [[ -w "$d" ]] || printf '%s\n' "$(t dir.not_writable "$d")"
        elif [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
            if [[ -e "$d/.git" || ( -f "$d/docker-compose.yml" && ( -f "$d/.env" || -d "$d/data" ) ) ]]; then
                printf '%s\n' "$(t dir.legacy "$d")"
            else
                printf '%s\n' "$(t dir.not_empty "$d" "$INSTALL_MARKER")"
            fi
        elif [[ ! -w "$d" ]]; then
            printf '%s\n' "$(t dir.not_writable "$d")"
        fi
        return 0
    fi
    anc="$d"
    while [[ ! -e "$anc" && "$anc" != / ]]; do anc="$(dirname "$anc")"; done
    if [[ ! -d "$anc" || ! -w "$anc" ]]; then
        printf '%s\n' "$(t dir.cant_create "$d" "$anc")"
    fi
    return 0
}

# ask_install_dir: the second question of an install (after the language).
# The directory comes from --dir, ESCAPE_DIR, FAKEAPP_DIR (deprecated), this
# very installed copy, or is asked (default: the one of the pointer file, else
# /opt/escape; no terminal: the default). Problems of a value that was not
# asked interactively are recorded with `problem`; an interactive answer is
# repeated until it is valid. Sets APP_DIR and the paths derived from it.
ask_install_dir() {
    local v default prompted=0 line bad
    install_dir_hint
    default="${DIR_HINT:-$DEFAULT_INSTALL_DIR}"
    case "$DIR_HINT_SRC" in
        flag)
            v=$DIR_HINT
            info "$(t dir.from_flag "$v")"
            ;;
        ESCAPE_DIR)
            v=$DIR_HINT
            info "$(t env.from_environment ESCAPE_DIR "$v")"
            ;;
        FAKEAPP_DIR)
            v=$DIR_HINT
            warn "$(t dir.deprecated_env)"
            info "$(t env.from_environment FAKEAPP_DIR "$v")"
            ;;
        installed)
            v=$DIR_HINT
            info "$(t dir.this_copy "$v")"
            ;;
        *)
            if [[ -t 0 ]]; then
                prompted=1
                while :; do
                    read -r -p "$(t dir.q) [$default]: " v || die "$(t common.no_input)"
                    v="${v#"${v%%[![:space:]]*}"}"
                    v="${v%"${v##*[![:space:]]}"}"
                    v="${v:-$default}"
                    bad="$(install_dir_problems "$v")"
                    [[ -z "$bad" ]] && break
                    while IFS= read -r line; do warn "$line"; done <<<"$bad"
                done
            else
                v=$default
                info "$(t dir.from_default "$v")"
            fi
            ;;
    esac
    if ((!prompted)); then
        while IFS= read -r line; do
            [[ -z "$line" ]] || problem "$line"
        done < <(install_dir_problems "$v")
    fi
    if [[ "$v" == /* ]]; then
        APP_DIR="$(realpath -m -- "$v")"
    else
        APP_DIR="$v"
    fi
    init_paths
    if ((!${#PROBLEMS[@]})); then
        if is_installation "$APP_DIR"; then
            ok "$(t dir.reuse "$APP_DIR")"
        else
            ok "$(t dir.new "$APP_DIR")"
        fi
    fi
}

# sync_file_list SRC: the files of SRC that belong into the install directory
# (relative paths, sorted, one per line): the allowlist. The decoy app gets only
# what `docker build` and the generators need (no tests, no test data).
sync_file_list() {
    local src=$1 f
    (
        cd "$src" || exit 1
        for f in "${SYNC_TOP_FILES[@]}"; do
            [[ ! -f "$f" ]] || printf '%s\n' "$f"
        done
        find lib nginx extensions.d -type f ! -name '.*' ! -name '*~' ! -name '*.swp' ! -name '*.orig' ! -name '*.rej' ! -name '*.bak' 2>/dev/null
        find fake-webapp -maxdepth 1 -type f -name '*.go' ! -name '*_test.go' 2>/dev/null
        for f in "${SYNC_FAKEAPP_FILES[@]}"; do
            [[ ! -f "fake-webapp/$f" ]] || printf '%s\n' "fake-webapp/$f"
        done
    ) | LC_ALL=C sort -u
}

# sync_to_install_dir: copy the allowlisted sources of CODE_DIR into APP_DIR
# (tar, no rsync), remove the files of the mirrored directories that the
# sources no longer have, write the marker. .env, data/, scripts/ and anything
# else the user keeps in APP_DIR are never touched.
sync_to_install_dir() {
    local list stale root f n=0 removed=0
    for f in "${SYNC_REQUIRED[@]}"; do
        [[ -f "$CODE_DIR/$f" ]] || die "$(t dir.src_incomplete "$f" "$CODE_DIR")"
    done
    mkdir -p -- "$APP_DIR" || die "$(t dir.sync_fail "$APP_DIR")"
    # The marker first: an interrupted copy is then an installation that the next run completes.
    printf 'project=escape\nsource=%s\nsynced=%s\n' "$CODE_DIR" "$(date -u +%FT%TZ)" >"$APP_DIR/$INSTALL_MARKER" ||
        die "$(t dir.sync_fail "$APP_DIR")"
    list="$(mktemp)"
    sync_file_list "$CODE_DIR" >"$list"
    n="$(wc -l <"$list")"
    tar -C "$CODE_DIR" -cf - -T "$list" | tar -C "$APP_DIR" -xpf - --no-same-owner ||
        { rm -f "$list"; die "$(t dir.sync_fail "$APP_DIR")"; }
    (cd "$APP_DIR" && xargs -d '\n' chmod go-w -- <"$list") || true
    for root in "${SYNC_MIRROR_DIRS[@]}"; do
        [[ -d "$APP_DIR/$root" ]] || continue
        stale="$(LC_ALL=C comm -23 <(cd "$APP_DIR" && find "$root" \( -type f -o -type l \) | LC_ALL=C sort) "$list")"
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            rm -f -- "${APP_DIR:?}/$f"
            removed=$((removed + 1))
        done <<<"$stale"
        find "$APP_DIR/$root" -mindepth 1 -type d -empty -delete
    done
    rm -f "$list"
    ok "$(t dir.synced "$n" "$APP_DIR" "$removed")"
}

# hand_over_to_install: stage 1 -> stage 2. Re-executes the installed install.sh
# with the same arguments; the language and the directory are passed in the
# environment so that nothing is asked twice.
hand_over_to_install() {
    exec env -u FAKEAPP_DIR ESCAPE_STAGE2=1 ESCAPE_DIR="$APP_DIR" FAKEAPP_LANG="$FAKEAPP_LANG_ACTIVE" \
        bash "$APP_DIR/install.sh" "${ORIG_ARGS[@]}"
}

# resolve_app_dir: for every command but install: find the installation
# (--dir, ESCAPE_DIR, this installed copy, the pointer file) and set APP_DIR.
# When this install.sh is not the installed copy (a source checkout, a
# download), the installed install.sh is executed instead with the same
# arguments: the commands always run the installed code.
resolve_app_dir() {
    install_dir_hint
    [[ -n "$DIR_HINT" ]] || die "$(t dir.no_install "$POINTER_FILE" "$DEFAULT_INSTALL_DIR")"
    [[ "$DIR_HINT_SRC" != FAKEAPP_DIR ]] || warn "$(t dir.deprecated_env)"
    [[ "$DIR_HINT" == /* ]] || die "$(t dir.not_absolute "$DIR_HINT")"
    APP_DIR="$(realpath -m -- "$DIR_HINT")"
    is_installation "$APP_DIR" || die "$(t dir.not_installation "$APP_DIR" "$INSTALL_MARKER")"
    if [[ "$APP_DIR" != "$CODE_DIR" ]]; then
        [[ -f "$APP_DIR/install.sh" ]] || die "$(t dir.no_installed_script "$APP_DIR")"
        exec env -u FAKEAPP_DIR ESCAPE_DIR="$APP_DIR" bash "$APP_DIR/install.sh" "${ORIG_ARGS[@]}"
    fi
}

# register_install_dir: write the pointer file (root) that lets commands find
# the installation from anywhere.
register_install_dir() {
    local tmp
    mkdir -p -- "$(dirname "$POINTER_FILE")"
    tmp="$(mktemp "$POINTER_FILE.XXXXXX")"
    printf '%s\n' "$APP_DIR" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$POINTER_FILE"
    ok "$(t dir.registered "$POINTER_FILE" "$APP_DIR")"
}

# unregister_install_dir: delete the pointer file when it points to APP_DIR.
unregister_install_dir() {
    [[ -f "$POINTER_FILE" && "$(head -n1 "$POINTER_FILE")" == "$APP_DIR" ]] || return 0
    rm -f "$POINTER_FILE"
    [[ "$POINTER_FILE" != /etc/escape/install-dir ]] || rmdir /etc/escape 2>/dev/null || true
}
