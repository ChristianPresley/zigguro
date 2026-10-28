# zigguro shell integration for zsh, version 1 (.zshrc shim).
# Copyright the zigguro authors. Licensed under the Apache License 2.0.
# Protocol: docs/shell-integration.md.
#
# zigguro points ZDOTDIR here; this file sources the user's own .zshrc
# from their ZDOTDIR (or HOME) and keeps any ZDOTDIR change it makes.

__zg_dir="${ZDOTDIR}"
ZDOTDIR="${ZIGGURO_USER_ZDOTDIR:-$HOME}"
if [[ -r "$ZDOTDIR/.zshrc" ]]; then
    builtin source "$ZDOTDIR/.zshrc"
fi
ZIGGURO_USER_ZDOTDIR="$ZDOTDIR"
ZDOTDIR="$__zg_dir"

builtin source "$__zg_dir/zigguro-hooks.zsh"
# A login shell reads .zlogin next; it restores ZDOTDIR there.
if [[ ! -o login ]]; then
    __zg_restore_zdotdir
fi
