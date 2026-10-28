# zigguro shell integration for fish, version 1.
# Copyright the zigguro authors. Licensed under the Apache License 2.0.
# Protocol: docs/shell-integration.md (OSC 133 A/B/C/D, OSC 633 E/P, OSC 7).
#
# zigguro adds this folder's parent to XDG_DATA_DIRS so fish loads this
# file as a vendor snippet; it puts XDG_DATA_DIRS back first. Prints
# nothing but escape sequences.

if test "$ZIGGURO_XDG_DATA_DIRS_ORIG" = __unset__
    set -e XDG_DATA_DIRS
else if set -q ZIGGURO_XDG_DATA_DIRS_ORIG
    set -gx XDG_DATA_DIRS $ZIGGURO_XDG_DATA_DIRS_ORIG
end
set -e ZIGGURO_XDG_DATA_DIRS_ORIG

status is-interactive; or exit 0
set -q __zg_installed; and exit 0
set -g __zg_installed 1

set -g __zg_nonce "$ZIGGURO_NONCE"
set -e ZIGGURO_NONCE
set -g __zg_ran 0
set -g __zg_props 1

# fish 4 prints OSC 133 A, C and D itself; then only the command line,
# the input mark and the folder come from here.
set -g __zg_native 0
if test (string split -f1 . $version) -ge 4
    set -g __zg_native 1
end

function __zg_escape
    string replace -a '\\' '\\\\' -- $argv[1] \
        | string replace -a ';' '\\x3b' \
        | string replace -a \e '\\x1b' \
        | string replace -a \a '\\x07' \
        | string replace -a \r '\\x0d' \
        | string replace -a \t '\\x09' \
        | string join '\\x0a'
end

function __zg_cwd
    set -l enc (string escape --style=url -- $PWD)
    printf '\e]7;file://%s%s\a' (hostname 2>/dev/null; or echo) $enc
end

function __zg_prompt --on-event fish_prompt
    set -l ec $status
    if test $__zg_props = 1
        set -g __zg_props 0
        printf '\e]633;P;Shell=fish\a\e]633;P;IntegrationVersion=1\a'
    end
    if test $__zg_native = 0
        if test $__zg_ran = 1
            printf '\e]133;D;%s\a' $__zg_last_status
        end
    end
    set -g __zg_ran 0
    __zg_cwd
    test $__zg_native = 0; and printf '\e]133;A\a'
end

function __zg_preexec --on-event fish_preexec
    set -g __zg_ran 1
    printf '\e]133;B\a\e]633;E;%s;%s\a' (__zg_escape "$argv[1]") $__zg_nonce
    test $__zg_native = 0; and printf '\e]133;C\a'
end

function __zg_postexec --on-event fish_postexec
    set -g __zg_last_status $status
end
