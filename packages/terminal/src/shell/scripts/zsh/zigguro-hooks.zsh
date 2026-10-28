# zigguro shell integration for zsh, version 1 (hooks).
# Copyright the zigguro authors. Licensed under the Apache License 2.0.
# Protocol: docs/shell-integration.md (OSC 133 A/B/C/D, OSC 633 E/P, OSC 7).
#
# Sourced by the .zshrc shim after the user's .zshrc. Prints nothing
# during startup (prompt frameworks such as p10k's instant prompt rely on
# that); marks are printed from the hooks only.

__zg_restore_zdotdir() {
    if [[ -n "$ZIGGURO_USER_ZDOTDIR" && "$ZIGGURO_USER_ZDOTDIR" != "$HOME" ]]; then
        ZDOTDIR="$ZIGGURO_USER_ZDOTDIR"
    else
        builtin unset ZDOTDIR
    fi
    builtin unset ZIGGURO_USER_ZDOTDIR __zg_dir
}

[[ -o interactive ]] || return 0
(( ${+__zg_installed} )) && return 0
typeset -g __zg_installed=1

typeset -g __zg_nonce="${ZIGGURO_NONCE:-}"
builtin unset ZIGGURO_NONCE
typeset -g __zg_ran=
typeset -g __zg_props=1

# Escapes a command line for OSC 633;E.
__zg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//;/\\x3b}"
    s="${s//$'\n'/\\x0a}"
    s="${s//$'\r'/\\x0d}"
    s="${s//$'\e'/\\x1b}"
    s="${s//$'\a'/\\x07}"
    s="${s//$'\t'/\\x09}"
    REPLY="$s"
}

__zg_cwd() {
    emulate -L zsh
    setopt localoptions noshwordsplit
    local LC_ALL=C s="$PWD" out="" c i
    for (( i = 1; i <= ${#s}; i++ )); do
        c="${s[i]}"
        case "$c" in
        ([a-zA-Z0-9/._~-]) out+="$c" ;;
        (*) out+="$(builtin printf '%%%02X' "'$c")" ;;
        esac
    done
    builtin printf '\e]7;file://%s%s\a' "${HOST:-}" "$out"
}

__zg_precmd() {
    local ec=$?
    if (( __zg_props )); then
        __zg_props=0
        builtin printf '\e]633;P;Shell=zsh\a\e]633;P;IntegrationVersion=1\a'
    fi
    if [[ -n "$__zg_ran" ]]; then
        builtin printf '\e]133;D;%s\a' "$ec"
    fi
    __zg_ran=
    __zg_cwd
    builtin printf '\e]133;A\a'
    return $ec
}

# Runs after the other precmd hooks, which may have rewritten PS1.
__zg_prompt_end() {
    local ec=$?
    local mark=$'%{\e]133;B\a%}'
    if [[ "$PS1" != *"$mark" ]]; then
        PS1="$PS1$mark"
    fi
    return $ec
}

__zg_preexec() {
    __zg_ran=1
    __zg_escape "$1"
    builtin printf '\e]633;E;%s;%s\a\e]133;C\a' "$REPLY" "$__zg_nonce"
}

autoload -Uz add-zsh-hook
precmd_functions=(__zg_precmd ${precmd_functions[@]} __zg_prompt_end)
add-zsh-hook preexec __zg_preexec
