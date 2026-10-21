#!/usr/bin/env bash
# Creates or updates every label in .github/labels.txt (name<TAB>color<TAB>description).
# Run manually by a maintainer with the GitHub CLI authenticated: .github/scripts/sync-labels.sh
set -euo pipefail
repo="${1:-ChristianPresley/zigguro}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while IFS=$'\t' read -r name color description; do
  [ -z "$name" ] && continue
  gh label create "$name" --repo "$repo" --color "$color" --description "$description" --force
done < "$here/../labels.txt"
