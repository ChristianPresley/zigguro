#!/usr/bin/env bash
# Collects the fuzzer state after a failed nightly run and opens one issue
# per distinct crashing input (deduplicated by SHA-256).
#
#   fuzz-triage.sh <target name> <exit code>
#
# Exit code 124 (timeout ended an infinite run) is success: nothing to do.
# Needs GH_TOKEN with issues: write. Copies .zig-cache/f/in* and
# .zig-cache/tmp/libfuzzer.log to fuzz-crashes/<target>/ for upload.
set -euo pipefail

target="$1"
code="$2"
if [ "$code" -eq 0 ] || [ "$code" -eq 124 ]; then
  echo "fuzz-triage: $target finished with $code, no crash"
  exit 0
fi

slug="$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '_')"
out="fuzz-crashes/$slug"
mkdir -p "$out"
shopt -s nullglob
inputs=(.zig-cache/f/in*)
for f in "${inputs[@]}"; do cp -- "$f" "$out/"; done
if [ -f .zig-cache/tmp/libfuzzer.log ]; then cp -- .zig-cache/tmp/libfuzzer.log "$out/"; fi

if [ "${#inputs[@]}" -eq 0 ]; then
  echo "fuzz-triage: $target exited $code without a fuzzer input file" >&2
fi

commit="${GITHUB_SHA:-$(git rev-parse HEAD)}"
for f in "$out"/in*; do
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  existing="$(gh issue list --label fuzz-crash --state open --search "$sha" --json number --jq 'length')"
  if [ "$existing" != "0" ]; then
    echo "fuzz-triage: $sha already reported"
    continue
  fi
  body="$(mktemp)"
  {
    echo "Fuzz target: \`$target\`"
    echo
    echo "Commit: $commit"
    echo
    echo "Input SHA-256: \`$sha\`"
    echo
    echo "Reproduce on Linux:"
    echo
    echo '```'
    echo "zig build test -Doptimize=ReleaseSafe -Dtest-filter=\"$target\" --fuzz"
    echo '```'
    if [ "$(stat -c %s "$f")" -lt 4096 ]; then
      echo
      echo "Input (base64):"
      echo
      echo '```'
      base64 -w 76 "$f"
      echo '```'
    else
      echo
      echo "The input is larger than 4 KiB; download it from the run's fuzz-crashes artifact."
    fi
    if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
      echo
      echo "Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    fi
  } > "$body"
  gh issue create --label fuzz-crash --title "[fuzz] $target crash ${sha:0:8}" --body-file "$body"
  rm -f "$body"
done
