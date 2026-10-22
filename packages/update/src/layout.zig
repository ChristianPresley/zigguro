//! Install layout as the updater sees it (E17.F04, E17.F02.S02.T01): one
//! root directory on a single volume holding the running `app/`, the
//! previous version in `prev/`, the next one in `staged/` and the swap
//! journal, so every step of an update is a directory rename.
//!
//! ```
//! <root>/app/                  the installed version
//! <root>/prev/                 the version before the last swap
//! <root>/staged/               a verified, extracted update
//! <root>/staged.zon            what `staged/` holds
//! <root>/staged.tmp/           extraction in progress
//! <root>/staged.download/      archives being downloaded
//! <root>/swap.journal          the swap protocol's journal
//! ```

const std = @import("std");

/// How zigguro was installed. Only managed installs download and swap;
/// the others stop at "available" and link to the release notes.
pub const InstallKind = enum {
    /// Per-user setup (`%LOCALAPPDATA%\Programs\zigguro`).
    user,
    /// Per-machine setup (needs elevation to swap).
    machine,
    /// Linux AppImage-style layout under the user's data directory.
    appimage,
    /// A portable folder or archive the user manages.
    portable,
    /// Distro packages (`update_mode = disabled`).
    distro,
    /// A developer build or an unknown install.
    unmanaged,

    /// True when the updater may download and apply updates itself.
    pub fn managed(k: InstallKind) bool {
        return switch (k) {
            .user, .machine, .appimage => true,
            .portable, .distro, .unmanaged => false,
        };
    }
};

/// Names under the root.
pub const names = struct {
    pub const app = "app";
    pub const prev = "prev";
    pub const staged = "staged";
    pub const staged_zon = "staged.zon";
    pub const staged_tmp = "staged.tmp";
    pub const download = "staged.download";
    pub const journal = "swap.journal";
};

/// An install root and its kind.
pub const Layout = struct {
    /// Absolute path of the install root.
    root: []const u8,
    kind: InstallKind,
};

/// The layout of the running binary in `exe_dir`: a managed install when
/// the binary lives in `<root>/app/`, otherwise an unmanaged one rooted
/// at `exe_dir`. Installers record the precise kind (E17.F02/F03); this is
/// the fallback.
pub fn detect(exe_dir: []const u8, os: std.Target.Os.Tag) Layout {
    const base = std.fs.path.basename(exe_dir);
    if (std.mem.eql(u8, base, names.app)) {
        if (std.fs.path.dirname(exe_dir)) |root| return .{ .root = root, .kind = if (os == .windows) .user else .appimage };
    }
    return .{ .root = exe_dir, .kind = .unmanaged };
}

test "layout: detect" {
    const sep = std.fs.path.sep_str;
    const l = detect("x" ++ sep ++ "zigguro" ++ sep ++ "app", .linux);
    try std.testing.expectEqualStrings("x" ++ sep ++ "zigguro", l.root);
    try std.testing.expectEqual(InstallKind.appimage, l.kind);
    try std.testing.expectEqual(InstallKind.user, detect("x" ++ sep ++ "app", .windows).kind);
    try std.testing.expectEqual(InstallKind.unmanaged, detect("x" ++ sep ++ "bin", .linux).kind);
}

test "layout: managed kinds" {
    try std.testing.expect(InstallKind.user.managed());
    try std.testing.expect(InstallKind.appimage.managed());
    try std.testing.expect(!InstallKind.portable.managed());
    try std.testing.expect(!InstallKind.unmanaged.managed());
}
