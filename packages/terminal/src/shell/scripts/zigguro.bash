# zigguro shell integration for bash, version 1.
# Copyright the zigguro authors. Licensed under the Apache License 2.0.
# Protocol: docs/shell-integration.md (OSC 133 A/B/C/D, OSC 633 E/P, OSC 7).
#
# zigguro starts bash with `--init-file <this file>`, which replaces the
# usual startup files, so this file loads them first and then installs
# its hooks. It prints nothing but escape sequences.

if [[ -n "${__zg_loaded:-}" ]]; then
    return 0 2>/dev/null
fi
__zg_loaded=1

__zg_nonce="${ZIGGURO_NONCE:-}"
unset ZIGGURO_NONCE

# The startup files bash would have read without --init-file.
if [[ "${ZIGGURO_SHELL_LOGIN:-0}" == 1 ]]; then
    unset ZIGGURO_SHELL_LOGIN
    if [[ -r /etc/profile ]]; then . /etc/profile; fi
    for __zg_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [[ -r "$__zg_f" ]]; then
            . "$__zg_f"
            break
        fi
    done
    unset __zg_f
else
    unset ZIGGURO_SHELL_LOGIN
    if [[ -r /etc/bash.bashrc ]]; then . /etc/bash.bashrc; fi
    if [[ -r "$HOME/.bashrc" ]]; then . "$HOME/.bashrc"; fi
fi

# A startup file may have loaded us again through `exec bash`.
if [[ -n "${__zg_installed:-}" ]]; then
    return 0 2>/dev/null
fi
__zg_installed=1

# Escapes a command line for OSC 633;E: backslash, semicolon and control
# characters become \\, \x3b and \xNN.
__zg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//;/\\x3b}"
    s="${s//$'\n'/\\x0a}"
    s="${s//$'\r'/\\x0d}"
    s="${s//$'\e'/\\x1b}"
    s="${s//$'\a'/\\x07}"
    s="${s//$'\t'/\\x09}"
    __zg_escaped="$s"
}

# Percent-encodes $PWD for OSC 7.
__zg_cwd() {
    local LC_ALL=C s="$PWD" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
        [a-zA-Z0-9/._~-]) out+="$c" ;;
        *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '\e]7;file://%s%s\a' "${HOSTNAME:-}" "$out"
}

__zg_ran=
__zg_hist=

# Runs first at each prompt, so $? is still the command's exit code.
__zg_precmd() {
    local ec=$?
    if [[ -n "$__zg_ran" ]]; then
        printf '\e]133;D;%s\a' "$ec"
    fi
    __zg_ran=
    __zg_hist="$HISTCMD"
    __zg_cwd
    printf '\e]133;A\a'
    return $ec
}

# Runs last at each prompt: prompt frameworks rewrite PS1 in their own
# hooks, so the input mark goes back on the end of it here.
__zg_prompt_end() {
    local ec=$?
    if [[ "$PS1" != *'\[\e]133;B\a\]' ]]; then
        PS1="$PS1"'\[\e]133;B\a\]'
    fi
    return $ec
}

# Expanded by PS0 in a subshell after a command line was read: prints the
# command line (only when it reached the history, else the terminal reads
# it from the screen) and the output mark.
__zg_preexec_print() {
    if [[ "$HISTCMD" != "$__zg_hist" ]]; then
        local line
        line="$(HISTTIMEFORMAT= builtin history 1)"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#*[0-9] }"
        line="${line#"${line%%[![:space:]]*}"}"
        __zg_escape "$line"
        printf '\e]633;E;%s;%s\a' "$__zg_escaped" "$__zg_nonce"
    fi
    printf '\e]133;C\a'
}

# `${__zg_set[__zg_ran=1]}` expands to nothing but sets __zg_ran in the
# shell itself (PS0 is expanded there; only $(...) runs in a subshell).
PS0='${__zg_set[__zg_ran=1]}$(__zg_preexec_print)'"${PS0:-}"

if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    PROMPT_COMMAND=(__zg_precmd "${PROMPT_COMMAND[@]}" __zg_prompt_end)
else
    PROMPT_COMMAND=$'__zg_precmd\n'"${PROMPT_COMMAND:-}"$'\n__zg_prompt_end'
fi

printf '\e]633;P;Shell=bash\a\e]633;P;IntegrationVersion=1\a'
