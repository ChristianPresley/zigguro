//! `BuildInfo`: what this binary is, filled at comptime from the forwarded
//! build options (`-Dversion`, `-Dchannel`, `-Dcommit`,
//! `-Dsource-date-epoch`, `-Dupdate-mode`, `-Ddistro`; see
//! docs/build-options.md). Zero runtime cost.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("zg_options");
const Version = @import("version.zig").Version;
const product = @import("product.zig").product;

/// Release channel. Insiders and rc are SemVer pre-releases of the next
/// version; dev is a local or CI build that is never published.
pub const Channel = enum { dev, insiders, rc, stable };

/// How the binary handles updates. `disabled` is forced by `-Ddistro`.
pub const UpdateMode = enum { managed_or_notify, notify_only, disabled };

/// Identity of one build.
pub const BuildInfo = struct {
    /// Parsed `version_string`.
    version: Version,
    /// Full version with build metadata, e.g. "0.4.0+g1a2b3c4d5e6f".
    version_string: []const u8,
    channel: Channel,
    /// Commit hash, or "unknown".
    commit: []const u8,
    /// Release target, e.g. "x86_64-linux-gnu.2.28".
    target: []const u8,
    optimize: std.builtin.OptimizeMode,
    /// Commit time in seconds since the epoch (0 for local builds).
    source_date_epoch: i64,
    update_mode: UpdateMode,
    /// Built for a distro package (FHS layout, updates disabled).
    distro: bool,

    /// Writes the `--version` line:
    /// `<name> <version_string> (<channel>, <target>, <optimize>, <commit>)`.
    pub fn writeLine(bi: *const BuildInfo, w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
        try w.print("{s} {s} ({s}, {s}, {s}, {s})\n", .{
            name,                  bi.version_string, @tagName(bi.channel), bi.target,
            @tagName(bi.optimize), bi.commit,
        });
    }

    /// Writes `BUILDINFO.zon`, the file shipped next to the binaries.
    pub fn writeZon(bi: *const BuildInfo, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(".{\n");
        try w.print("    .app_id = \"{f}\",\n", .{std.zig.fmtString(product.app_id)});
        try w.print("    .version = \"{f}\",\n", .{std.zig.fmtString(bi.version_string)});
        try w.print("    .channel = .{s},\n", .{@tagName(bi.channel)});
        try w.print("    .commit = \"{f}\",\n", .{std.zig.fmtString(bi.commit)});
        try w.print("    .target = \"{f}\",\n", .{std.zig.fmtString(bi.target)});
        try w.print("    .optimize = .{s},\n", .{@tagName(bi.optimize)});
        try w.print("    .source_date_epoch = {d},\n", .{bi.source_date_epoch});
        try w.print("    .update_mode = .{s},\n", .{@tagName(bi.update_mode)});
        try w.print("    .distro = {},\n", .{bi.distro});
        try w.writeAll("}\n");
    }
};

/// Builds the full version string: `version` unchanged when it already
/// carries `+build` metadata, otherwise `version ++ "+g" ++ commit[0..12]`,
/// or `version ++ "+local"` when the commit is "unknown".
pub fn versionString(comptime version: []const u8, comptime commit: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, version, '+') != null) return version;
    if (std.mem.eql(u8, commit, "unknown") or commit.len == 0) return version ++ "+local";
    return version ++ "+g" ++ commit[0..@min(12, commit.len)];
}

/// The `BuildInfo` of this binary.
pub const current: BuildInfo = blk: {
    @setEvalBranchQuota(10_000);
    const vs = versionString(options.version, options.commit);
    const v = Version.parse(vs) catch @compileError("-Dversion is not valid SemVer 2.0.0: " ++ vs);
    break :blk .{
        .version = v,
        .version_string = vs,
        .channel = std.meta.stringToEnum(Channel, @tagName(options.channel)).?,
        .commit = options.commit,
        .target = options.release_target,
        .optimize = builtin.mode,
        .source_date_epoch = options.source_date_epoch,
        .update_mode = if (options.distro) .disabled else std.meta.stringToEnum(UpdateMode, @tagName(options.update_mode)).?,
        .distro = options.distro,
    };
};

comptime {
    if (current.channel != .dev and product.release_keys.len == 0)
        @compileError("product.zon release_keys is empty; run the key ceremony (docs/release.md)");
}

const testing = std.testing;

test "build_info: version string metadata" {
    try testing.expectEqualStrings("0.4.0+g1a2b3c4d5e6f", comptime versionString("0.4.0", "1a2b3c4d5e6f7a8b9c0d"));
    try testing.expectEqualStrings("0.4.0+local", comptime versionString("0.4.0", "unknown"));
    try testing.expectEqualStrings("0.4.0+gabc", comptime versionString("0.4.0", "abc"));
    try testing.expectEqualStrings("0.4.0+custom", comptime versionString("0.4.0+custom", "abc"));
}

test "build_info: --version line format" {
    const bi: BuildInfo = .{
        .version = try Version.parse("1.2.3+gabc"),
        .version_string = "1.2.3+gabc",
        .channel = .stable,
        .commit = "abc",
        .target = "x86_64-linux-gnu.2.28",
        .optimize = .ReleaseFast,
        .source_date_epoch = 1761016620,
        .update_mode = .managed_or_notify,
        .distro = false,
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try bi.writeLine(&w, "zg");
    try testing.expectEqualStrings("zg 1.2.3+gabc (stable, x86_64-linux-gnu.2.28, ReleaseFast, abc)\n", w.buffered());

    var zbuf: [512]u8 = undefined;
    var zw: std.Io.Writer = .fixed(&zbuf);
    try bi.writeZon(&zw);
    try testing.expectEqualStrings(
        \\.{
        \\    .app_id = "dev.zigguro.zigguro",
        \\    .version = "1.2.3+gabc",
        \\    .channel = .stable,
        \\    .commit = "abc",
        \\    .target = "x86_64-linux-gnu.2.28",
        \\    .optimize = .ReleaseFast,
        \\    .source_date_epoch = 1761016620,
        \\    .update_mode = .managed_or_notify,
        \\    .distro = false,
        \\}
        \\
    , zw.buffered());
}

test "build_info: current is consistent" {
    try testing.expectEqual(builtin.mode, current.optimize);
    try testing.expect(std.mem.indexOfScalar(u8, current.version_string, '+') != null);
    try testing.expect(current.target.len > 0);
    if (current.distro) try testing.expectEqual(UpdateMode.disabled, current.update_mode);
}
