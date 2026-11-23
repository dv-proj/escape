# lib/i18n.sh - user-facing language: message lookup `t`, language selection, extension message files.
# Sourced by install.sh (see the source list there), first of the modules.
# shellcheck shell=bash
#
# Design: every user-facing text is a printf format in the associative array
# MSG, filled by lib/lang/en.sh and (for the other language) lib/lang/ru.sh.
# English is always loaded first and the chosen language is loaded over it, so
# a key missing in ru.sh falls back to English; an unknown key prints as itself.
# Extensions may ship extensions.d/<id>/lang/{en,ru}.sh (see ext_load_lang).
# Command names, flags, variable names and paths are never translated.

declare -gA MSG=()
# Languages offered by install (code -> menu number is the order here).
I18N_LANGS=(en ru)
# Active language, where the choice came from (--lang | FAKEAPP_LANG | .env | ""),
# and an unknown value that was given (reported by validate_language).
FAKEAPP_LANG_ACTIVE=en
LANG_SRC=""
LANG_INVALID=""
LANG_INVALID_SRC=""
# Value of --lang (set by main).
LANG_FLAG=""
# Extension ids whose message files are loaded (re-loaded on a language change).
I18N_EXT_LOADED=()

# t KEY [ARGS...]: the message KEY of the active language, formatted like
# printf (%s placeholders; a literal percent sign is written %%).
t() {
    local key=$1 fmt
    shift
    fmt="${MSG[$key]-}"
    [[ -n "$fmt" ]] || fmt="$key"
    # shellcheck disable=SC2059
    printf -- "$fmt" "$@"
}

valid_lang() { [[ "$1" == en || "$1" == ru ]]; }

# _i18n_source_dir DIR: load DIR/en.sh, then DIR/<active>.sh over it.
_i18n_source_dir() {
    local dir=$1
    # shellcheck disable=SC1090
    [[ ! -f "$dir/en.sh" ]] || source "$dir/en.sh"
    # shellcheck disable=SC1090
    [[ "$FAKEAPP_LANG_ACTIVE" == en || ! -f "$dir/$FAKEAPP_LANG_ACTIVE.sh" ]] || source "$dir/$FAKEAPP_LANG_ACTIVE.sh"
}

# set_language CODE: make CODE (en or ru) the active language and (re)load the
# message files of the core and of the extensions loaded so far.
set_language() {
    local id
    FAKEAPP_LANG_ACTIVE=$1
    MSG=()
    _i18n_source_dir "$APP_DIR/lib/lang"
    for id in "${I18N_EXT_LOADED[@]}"; do
        _i18n_source_dir "$APP_DIR/extensions.d/$id/lang"
    done
}

# ext_load_lang ID: load extensions.d/<ID>/lang/en.sh and <active>.sh (same
# format as lib/lang/*.sh; keys should start with "<ID>." or a short prefix of
# your own). Safe to call many times; a missing directory is not an error.
ext_load_lang() {
    local id=$1 have=0 l
    for l in "${I18N_EXT_LOADED[@]}"; do
        [[ "$l" != "$id" ]] || have=1
    done
    ((have)) || I18N_EXT_LOADED+=("$id")
    _i18n_source_dir "$APP_DIR/extensions.d/$id/lang"
}

# ext_title ID: the menu title of an extension: the message "<ID>.title" of its
# message files when there is one, else the title given to register_extension.
ext_title() {
    ext_load_lang "$1"
    if [[ -n "${MSG[$1.title]-}" ]]; then
        t "$1.title"
    else
        printf '%s' "${EXT_TITLE[$1]}"
    fi
}

# i18n_init: resolve the language without asking: --lang, then the
# FAKEAPP_LANG environment variable, then FAKEAPP_LANG in .env. An unknown
# value is remembered (LANG_INVALID) and English is used until validation.
i18n_init() {
    local v="" src=""
    if [[ -n "$LANG_FLAG" ]]; then
        v=$LANG_FLAG src="--lang"
    elif [[ -n "${FAKEAPP_LANG:-}" ]]; then
        v=$FAKEAPP_LANG src="FAKEAPP_LANG"
    elif [[ -f "$APP_DIR/.env" ]]; then
        v="$(env_get "$APP_DIR/.env" FAKEAPP_LANG)"
        src=".env"
    fi
    v="${v,,}"
    LANG_SRC=""
    LANG_INVALID=""
    if [[ -z "$v" ]]; then
        set_language en
    elif valid_lang "$v"; then
        LANG_SRC=$src
        set_language "$v"
    else
        LANG_SRC=$src
        LANG_INVALID=$v
        LANG_INVALID_SRC=$src
        set_language en
    fi
}

# ask_language: the first question of an interactive install. Skipped when the
# language is already known (flag, environment, .env) or an unknown value was
# given (validate_language reports it) or there is no terminal (English).
ask_language() {
    local ans
    [[ -z "$LANG_SRC" && -z "$LANG_INVALID" && -t 0 ]] || return 0
    while :; do
        read -r -p "Language / Язык: 1 - English, 2 - Russian [1]: " ans || ans=1
        ans="${ans,,}"
        case "${ans:-1}" in
            1 | en | english) set_language en; return 0 ;;
            2 | ru | russian | русский) set_language ru; return 0 ;;
        esac
    done
}

# validate_language: phase 2: an unknown language value is a problem.
validate_language() {
    [[ -z "$LANG_INVALID" ]] || problem "$(t i18n.bad_lang "$LANG_INVALID" "$LANG_INVALID_SRC")"
}
