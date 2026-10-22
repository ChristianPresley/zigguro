#!/usr/bin/env bash
# Installs the pinned Zig toolchain on a Linux runner (x86_64 or aarch64).
#
#   setup-zig.sh [--pin .github/zig-toolchain.txt] [--dest "$RUNNER_TOOL_CACHE/zig"]
#
# Tries the community mirrors in shuffled order, then ziglang.org, checks the
# archive's SHA-256 against the pin before extracting, and appends the zig
# directory to $GITHUB_PATH (and ZIG_VERSION to $GITHUB_ENV) when set.
# An extracted toolchain already in --dest is reused after `zig version`
# matches the pin.
#
# Exit codes: 0 ok, 10 hash mismatch, 11 all sources failed, 12 unsupported
# arch or missing pin entry.
#
# Nothing downloaded is executed before its hash matches, and no input comes
# from the PR. ZIGGURO_MIRRORS_URL, ZIGGURO_FALLBACK_URL and
# ZIGGURO_ALLOW_HTTP exist only for the fixture test (zig build test-ci-scripts).
set -euo pipefail

pin=".github/zig-toolchain.txt"
dest="${RUNNER_TOOL_CACHE:-${HOME}/.cache}/zig"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pin) pin="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    *) echo "setup-zig: unknown argument: $1" >&2; exit 2 ;;
  esac
done

mirrors_url="${ZIGGURO_MIRRORS_URL:-https://ziglang.org/download/community-mirrors.txt}"
fallback="${ZIGGURO_FALLBACK_URL:-https://ziglang.org/download}"
scheme='^https://'
if [ "${ZIGGURO_ALLOW_HTTP:-}" = "1" ]; then scheme='^https?://'; fi

case "$(uname -m)" in
  x86_64 | amd64) arch="x86_64" ;;
  aarch64 | arm64) arch="aarch64" ;;
  *) echo "setup-zig: unsupported architecture $(uname -m)" >&2; exit 12 ;;
esac
triple="${arch}-linux"

version="$(awk '$1 == "version" { print $2 }' "$pin")"
file="$(awk -v t="$triple" '$1 == t { print $2 }' "$pin")"
sha="$(awk -v t="$triple" '$1 == t { print $3 }' "$pin")"
if [ -z "$version" ] || [ -z "$file" ] || [ "${#sha}" -ne 64 ]; then
  echo "setup-zig: no pin entry for $triple in $pin" >&2
  exit 12
fi
install="${dest}/${file%.tar.xz}"

publish() {
  if [ -n "${GITHUB_PATH:-}" ]; then echo "$install" >> "$GITHUB_PATH"; fi
  if [ -n "${GITHUB_ENV:-}" ]; then echo "ZIG_VERSION=$version" >> "$GITHUB_ENV"; fi
  echo "setup-zig: zig $version at $install"
}

if [ -x "$install/zig" ] && [ "$("$install/zig" version 2>/dev/null || true)" = "$version" ]; then
  echo "setup-zig: cache hit"
  publish
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mirrors=()
if list="$(curl -fsSL --max-time 30 "$mirrors_url" 2>/dev/null)"; then
  mapfile -t mirrors < <(printf '%s\n' "$list" | tr -d '\r' | grep -E "$scheme" | shuf || true)
fi

sources=()
for m in "${mirrors[@]}"; do sources+=("${m%/}/${file}?source=zigguro-ci"); done
sources+=("${fallback%/}/${version}/${file}")

got_file=0
for url in "${sources[@]}"; do
  if curl -fsSL --retry 2 --max-time 120 "$url" -o "$tmp/$file"; then
    got_file=1
    break
  fi
  echo "setup-zig: $url failed, trying the next source" >&2
done
if [ "$got_file" -ne 1 ]; then
  echo "setup-zig: every source failed for $file" >&2
  exit 11
fi

if ! echo "${sha}  ${tmp}/${file}" | sha256sum -c --status -; then
  echo "zig toolchain hash mismatch: $file from $url" >&2
  exit 10
fi

mkdir -p "$tmp/x" "$dest"
tar -xJf "$tmp/$file" -C "$tmp/x"
rm -rf "$install"
mv "$tmp/x/${file%.tar.xz}" "$install"
if [ "$("$install/zig" version)" != "$version" ]; then
  echo "setup-zig: installed zig does not report $version" >&2
  exit 10
fi
publish
