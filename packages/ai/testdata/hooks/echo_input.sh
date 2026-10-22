#!/bin/sh
# Writes its stdin and the project dir variables to $1 (for inspection).
cat > "$1"
printf '%s\n%s\n' "$ZIGGURO_PROJECT_DIR" "${CLAUDE_PROJECT_DIR:-}" >> "$1"
