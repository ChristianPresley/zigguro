# 0008. Toolchain trust: pinned and signature-verified Zig

Status: Accepted
Date: 2026-10-21

## Context

The Zig toolchain is the only external artifact the project uses. CI and contributors download it, possibly through community mirrors, and a tampered compiler would compromise every build.

## Decision

- The toolchain is pinned in `.github/zig-toolchain.txt`: version 0.16.0 and the SHA-256 of each tier-1 host tarball.
- Every download is verified twice: the SHA-256 must match the pin, and the tarball's minisign signature must verify against the Zig Software Foundation public key published on ziglang.org/download. `tools/zig-verify` implements minisign verification in Zig (Ed25519 from std).
- Downloads try the community mirrors (in the published order, per the mirror rules for automated downloads) and fall back to ziglang.org; a mirror is only a transport, never a trust anchor.
- CI uses only GitHub-hosted runners, `actions/checkout`, `actions/cache` and `actions/upload-artifact`; no third-party actions.

## Consequences

- Bumping Zig is an explicit pull request that updates the pin (`zig build zig-pin`).
- A compromised mirror can deny service but cannot change the toolchain.

## References

- [Zig downloads (tarball names, minisign public key)](https://ziglang.org/download/)
- [Zig community mirrors: rules for automated downloads](https://ziglang.org/download/community-mirrors/)
- [Minisign: signature and key format](https://jedisct1.github.io/minisign/)
