#!/usr/bin/env bash
# tests/check-i18n.sh - consistency of the message files.
# Fails when
#   * lib/lang/en.sh and lib/lang/ru.sh (or extensions.d/<id>/lang/{en,ru}.sh) have different key sets,
#   * a key used in code as `t KEY` is missing in the English files,
#   * a message has a different number of %s/%d placeholders in en and ru.
# Keys that no code uses are only listed. Run: tests/check-i18n.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
bad() {
    printf 'FAIL: %s\n' "$*" >&2
    fail=1
}

# keys_of FILE: sorted keys of a message file.
keys_of() {
    (
        declare -A MSG=()
        # shellcheck disable=SC1090
        source "$1" || exit 1
        printf '%s\n' "${!MSG[@]}" | sort
    )
}

# placeholders FILE KEY: number of %s/%d in the message (%% excluded).
placeholders() {
    (
        declare -A MSG=()
        # shellcheck disable=SC1090
        source "$1"
        local v="${MSG[$2]//%%/}"
        grep -o '%[sd]' <<<"$v" | wc -l
    )
}

declare -A en_all=()
dirs=("$ROOT/lib/lang")
for d in "$ROOT"/extensions.d/*/lang; do
    [[ -d "$d" ]] && dirs+=("$d")
done

for d in "${dirs[@]}"; do
    rel="${d#"$ROOT"/}"
    [[ -f "$d/en.sh" && -f "$d/ru.sh" ]] || {
        bad "$rel: en.sh and ru.sh are both required"
        continue
    }
    en="$(keys_of "$d/en.sh")" || bad "$rel/en.sh does not load"
    ru="$(keys_of "$d/ru.sh")" || bad "$rel/ru.sh does not load"
    missing_ru="$(comm -23 <(printf '%s\n' "$en") <(printf '%s\n' "$ru"))"
    missing_en="$(comm -13 <(printf '%s\n' "$en") <(printf '%s\n' "$ru"))"
    [[ -z "$missing_ru" ]] || bad "$rel: keys missing in ru.sh: $(tr '\n' ' ' <<<"$missing_ru")"
    [[ -z "$missing_en" ]] || bad "$rel: keys missing in en.sh: $(tr '\n' ' ' <<<"$missing_en")"
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        en_all[$k]=1
        grep -qFx -- "$k" <<<"$ru" || continue
        [[ "$(placeholders "$d/en.sh" "$k")" == "$(placeholders "$d/ru.sh" "$k")" ]] ||
            bad "$rel: placeholder count differs for '$k'"
    done <<<"$en"
done

# Keys used in code: `t KEY` (KEY is "usage" or has a dot).
mapfile -t used < <(
    grep -hoE '(^|[^A-Za-z0-9_.-])t (usage|[a-z0-9-]+\.[A-Za-z0-9_.-]+)' \
        "$ROOT/install.sh" "$ROOT"/lib/*.sh "$ROOT"/extensions.d/*.sh |
        sed -E 's/^.*t //' | sort -u
)
declare -A is_used=()
for k in "${used[@]}"; do
    is_used[$k]=1
    [[ -n "${en_all[$k]:-}" ]] || bad "key used in code but missing in en: $k"
done
for k in "${!en_all[@]}"; do
    [[ -n "${is_used[$k]:-}" || "$k" == *.title ]] || printf 'note: unused key: %s\n' "$k" >&2
done | sort

if ((fail)); then
    exit 1
fi
printf 'i18n ok: %d keys, %d used in code\n' "${#en_all[@]}" "${#used[@]}"
