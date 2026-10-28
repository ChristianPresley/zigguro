# zigguro shell integration for zsh, version 1 (.zshenv shim).
# Copyright the zigguro authors. Licensed under the Apache License 2.0.
# Protocol: docs/shell-integration.md.
#
# zigguro points ZDOTDIR here; this file sources the user's own .zshenv
# from their ZDOTDIR (or HOME) and keeps any ZDOTDIR change it makes.

__zg_dir="${ZDOTDIR}"
ZDOTDIR="${ZIGGURO_USER_ZDOTDIR:-$HOME}"
if [[ -r "$ZDOTDIR/.zshenv" ]]; then
    builtin source "$ZDOTDIR/.zshenv"
fi
ZIGGURO_USER_ZDOTDIR="$ZDOTDIR"
ZDOTDIR="$__zg_dir"
