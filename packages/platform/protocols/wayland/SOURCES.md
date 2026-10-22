# Vendored Wayland protocol XML

Protocol data (not code), copied unmodified with their license headers.
`zg_build.waylandModule` turns them into the `wl_gen` module at build time.

| File | Upstream | Path upstream |
|------|----------|---------------|
| `wayland.xml` | wayland 1.22.0 | `protocol/wayland.xml` |
| `xdg-shell.xml` | wayland-protocols 1.45 | `stable/xdg-shell/` |
| `viewporter.xml` | wayland-protocols 1.45 | `stable/viewporter/` |
| `presentation-time.xml` | wayland-protocols 1.45 | `stable/presentation-time/` |
| `linux-dmabuf-v1.xml` | wayland-protocols 1.45 | `stable/linux-dmabuf/` |
| `tablet-v2.xml` | wayland-protocols 1.45 | `stable/tablet/` |
| `fractional-scale-v1.xml` | wayland-protocols 1.45 | `staging/fractional-scale/` |
| `cursor-shape-v1.xml` | wayland-protocols 1.45 | `staging/cursor-shape/` |
| `linux-drm-syncobj-v1.xml` | wayland-protocols 1.45 | `staging/linux-drm-syncobj/` |
| `xdg-activation-v1.xml` | wayland-protocols 1.45 | `staging/xdg-activation/` |
| `xdg-decoration-unstable-v1.xml` | wayland-protocols 1.45 | `unstable/xdg-decoration/` |
| `text-input-unstable-v3.xml` | wayland-protocols 1.45 | `unstable/text-input/` |
| `primary-selection-unstable-v1.xml` | wayland-protocols 1.45 | `unstable/primary-selection/` |
| `xdg-foreign-unstable-v2.xml` | wayland-protocols 1.45 | `unstable/xdg-foreign/` |

The files were taken from the release tarballs as packaged by Ubuntu 24.04
(`libwayland-dev` 1.22.0-2.1build1, `wayland-protocols` 1.45-1~ubuntu0.24.04.2),
which ship the upstream files unchanged. The upstream release tags are
`1.22.0` in https://gitlab.freedesktop.org/wayland/wayland and `1.45` in
https://gitlab.freedesktop.org/wayland/wayland-protocols. The commit hashes
behind those tags could not be read from this environment; look them up by
tag when updating.

Licenses: `wayland.xml` has an MIT-style notice in its `<copyright>`
element; the wayland-protocols files are MIT (Expat), see
`LICENSE-wayland-protocols.txt` and each file's `<copyright>`.
