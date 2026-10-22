#!/bin/sh
# Blocks `rm` commands, like the Claude Code hooks guide's Bash validator:
# reads the PreToolUse JSON on stdin, exits 2 with the reason on stderr.
input=$(cat)
case "$input" in
  *'"command":"rm '*) echo "Blocked: rm is not allowed here; move files to trash/ instead." >&2; exit 2 ;;
esac
exit 0
