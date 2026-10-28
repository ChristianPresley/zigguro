# zigguro shell integration for zsh, version 1 (.zlogin shim).
# Copyright the zigguro authors. Licensed under the Apache License 2.0.
# Protocol: docs/shell-integration.md.
#
# zigguro points ZDOTDIR here; this file sources the user's own .zlogin
# from their ZDOTDIR (or HOME) and keeps any ZDOTDIR change it makes.

__zg_dir="${ZDOTDIR}"
ZDOTDIR="${ZIGGURO_USER_ZDOTDIR:-$HOME}"
if [[ -r "$ZDOTDIR/.zlogin" ]]; then
    builtin source "$ZDOTDIR/.zlogin"
fi
ZIGGURO_USER_ZDOTDIR="$ZDOTDIR"
ZDOTDIR="$__zg_dir"

if [[ -o login ]]; then
    __zg_restore_zdotdir
fi
