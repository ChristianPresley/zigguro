//! ZLS as the first-class Zig server (E07.F01.S03.T02): finds the Zig
//! toolchain (`zig version`, `zig env`), checks that ZLS pairs with it
//! (tagged Zig wants a ZLS of the same major.minor, dev Zig a dev ZLS),
//! builds the `zls` configuration section from the settings (`zig.path`
//! as `zig_exe_path`, every `zig.zls.<name>` passed through as `<name>`),
//! reads `zig build -l` for a `check` step (ZLS turns build-on-save on
//! by itself when there is one) and proposes one when there is not.
//! The process helpers block: workers only.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const SemanticVersion = std.SemanticVersion;

pub const install_guide = "https://zigtools.org/zls/install/";

pub const ZigToolchain = struct {
    exe_path: []const u8,
    version: SemanticVersion,
    lib_dir: ?[]const u8 = null,
};

/// A `zig version` / `zls --version` line as a version.
pub fn parseVersion(text: []const u8) error{InvalidVersion}!SemanticVersion {
    const t = std.mem.trim(u8, text, " \t\r\n");
    // `zls --version` may print a prefix ("zls 0.16.0").
    const v = if (std.mem.lastIndexOfScalar(u8, t, ' ')) |i| t[i + 1 ..] else t;
    return SemanticVersion.parse(v) catch error.InvalidVersion;
}

pub const Pairing = enum {
    ok,
    /// Same major.minor, another patch: fine.
    patch_mismatch_ok,
    /// Tagged releases of different major.minor.
    minor_mismatch,
    /// One is a dev build and the other is not (or dev builds of
    /// different major.minor).
    dev_mismatch,

    pub fn isOk(p: Pairing) bool {
        return p == .ok or p == .patch_mismatch_ok;
    }
};

pub fn checkPairing(zig: SemanticVersion, zls: SemanticVersion) Pairing {
    const zig_dev = zig.pre != null;
    const zls_dev = zls.pre != null;
    const same_minor = zig.major == zls.major and zig.minor == zls.minor;
    if (zig_dev != zls_dev) return .dev_mismatch;
    if (zig_dev) return if (same_minor) .ok else .dev_mismatch;
    if (!same_minor) return .minor_mismatch;
    return if (zig.patch == zls.patch) .ok else .patch_mismatch_ok;
}

/// The warning for a bad pairing (null when it is fine).
pub fn pairingWarning(buf: []u8, zig: SemanticVersion, zls: SemanticVersion) ?[]const u8 {
    const p = checkPairing(zig, zls);
    if (p.isOk()) return null;
    return std.fmt.bufPrint(buf, "ZLS {f} does not match Zig {f}: {s}. See {s}", .{
        zls,           zig,
        switch (p) {
            .dev_mismatch => "a development Zig needs a development ZLS of the same version",
            else => "install the ZLS release for this Zig version",
        },
        install_guide,
    }) catch buf[0..0];
}

pub const ZigEnv = struct {
    zig_exe: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

/// `zig env` output: ZON since 0.16, JSON before.
pub fn parseZigEnv(arena: Allocator, text: []const u8) error{ OutOfMemory, InvalidEnv }!ZigEnv {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, ".{")) {
        const z = try arena.dupeZ(u8, t);
        return std.zon.parse.fromSliceAlloc(ZigEnv, arena, z, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.ParseZon => error.InvalidEnv,
        };
    }
    return std.json.parseFromSliceLeaky(ZigEnv, arena, t, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidEnv,
    };
}

pub const BuildStep = struct {
    name: []const u8,
    description: []const u8,
    default: bool = false,
};

/// `zig build -l` output: one step per line, its name padded, then its
/// description; the default step says `(default)` after its name.
/// Slices point into `text`.
pub fn parseBuildSteps(arena: Allocator, text: []const u8) Allocator.Error![]BuildStep {
    var out: std.ArrayList(BuildStep) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const name_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        var rest = std.mem.trimStart(u8, line[name_end..], " \t");
        var default = false;
        if (std.mem.startsWith(u8, rest, "(default)")) {
            default = true;
            rest = std.mem.trimStart(u8, rest["(default)".len..], " \t");
        }
        try out.append(arena, .{ .name = line[0..name_end], .description = rest, .default = default });
    }
    return out.items;
}

pub fn hasStep(steps: []const BuildStep, name: []const u8) bool {
    for (steps) |s| if (std.mem.eql(u8, s.name, name)) return true;
    return false;
}

/// One `zig.zls.<name>` setting.
pub const Option = struct { name: []const u8, value: std.json.Value };

pub const Settings = struct {
    /// `zig.path`: the Zig executable (null: PATH).
    zig_path: ?[]const u8 = null,
    /// `zig.zls.*`, passed through under their ZLS names.
    zls: []const Option = &.{},
};

/// The `zls` section: `zig_exe_path` from the settings or the detected
/// toolchain, then every `zig.zls.*` option (which may override it).
/// `enable_build_on_save` stays unset unless set, so ZLS decides from the
/// `check` step.
pub fn configSection(arena: Allocator, s: *const Settings, zig: ?*const ZigToolchain) Allocator.Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    if (s.zig_path orelse if (zig) |z| z.exe_path else null) |p| try obj.put(arena, "zig_exe_path", .{ .string = p });
    for (s.zls) |o| try obj.put(arena, o.name, o.value);
    return .{ .object = obj };
}

/// The step `check` for build-on-save: the project's root source built
/// again without emitting a binary (`zig build check`).
pub fn checkStepSnippet(arena: Allocator, root_source: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\
        \\    // `zig build check`: compiles without emitting a binary, for ZLS
        \\    // build-on-save (https://zigtools.org/zls/guides/build-on-save/).
        \\    const check_exe = b.addExecutable(.{{
        \\        .name = "check",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("{s}"),
        \\            .target = b.graph.host,
        \\        }}),
        \\    }});
        \\    const check = b.step("check", "Check that the code compiles");
        \\    check.dependOn(&check_exe.step);
        \\
    , .{root_source});
}

/// Where the check step goes in `build.zig` source: the start of the
/// line with the closing brace of `pub fn build`. Null when there is no
/// such function.
pub fn checkStepInsertion(gpa: Allocator, source: [:0]const u8) Allocator.Error!?usize {
    var ast = try std.zig.Ast.parse(gpa, source, .zig);
    defer ast.deinit(gpa);
    for (ast.rootDecls()) |decl| {
        if (ast.nodeTag(decl) != .fn_decl) continue;
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = ast.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        if (!std.mem.eql(u8, ast.tokenSlice(name_tok), "build")) continue;
        const body = ast.nodeData(decl).node_and_node[1];
        const rbrace = ast.lastToken(body);
        const off = ast.tokenStart(rbrace);
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..off], '\n')) |i| i + 1 else 0;
        return line_start;
    }
    return null;
}

// ------------------------------------------------------------- processes

/// Runs `argv` and returns its stdout when it exits 0 within `timeout`.
fn capture(arena: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map, timeout: Io.Duration) ?[]const u8 {
    const r = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = timeout, .clock = .awake } },
    }) catch return null;
    return switch (r.term) {
        .exited => |c| if (c == 0) r.stdout else null,
        else => null,
    };
}

/// The toolchain at `exe` (an absolute path or a name on PATH): its
/// version and library directory. Null when it does not run.
pub fn detectZig(arena: Allocator, io: Io, exe: []const u8, env: ?*const std.process.Environ.Map) ?ZigToolchain {
    const t: Io.Duration = .fromSeconds(10);
    const out = capture(arena, io, &.{ exe, "version" }, null, env, t) orelse return null;
    const version = parseVersion(out) catch return null;
    var tc: ZigToolchain = .{ .exe_path = exe, .version = version };
    if (capture(arena, io, &.{ exe, "env" }, null, env, t)) |text| {
        if (parseZigEnv(arena, text)) |e| {
            tc.lib_dir = e.lib_dir;
            if (e.zig_exe) |z| tc.exe_path = z;
        } else |_| {}
    }
    return tc;
}

/// The steps of the build in `build_root` (`zig build -l`, 10 s at most;
/// it may fetch lazy dependencies). Null when it fails.
pub fn listBuildSteps(arena: Allocator, io: Io, zig_exe: []const u8, build_root: []const u8, env: ?*const std.process.Environ.Map) ?[]BuildStep {
    const out = capture(arena, io, &.{ zig_exe, "build", "-l" }, build_root, env, .fromSeconds(10)) orelse return null;
    return parseBuildSteps(arena, out) catch null;
}

/// `zls env`'s `config_file` (the user's `zls.json`), if it has one.
pub fn zlsConfigFile(arena: Allocator, io: Io, zls_exe: []const u8, env: ?*const std.process.Environ.Map) ?[]const u8 {
    const out = capture(arena, io, &.{ zls_exe, "env" }, null, env, .fromSeconds(5)) orelse return null;
    const E = struct { config_file: ?[]const u8 = null };
    const e = std.json.parseFromSliceLeaky(E, arena, out, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return e.config_file;
}

/// `zls --version` as a version.
pub fn probeZlsVersion(arena: Allocator, io: Io, zls_exe: []const u8, env: ?*const std.process.Environ.Map) ?SemanticVersion {
    const out = capture(arena, io, &.{ zls_exe, "--version" }, null, env, .fromSeconds(5)) orelse return null;
    return parseVersion(out) catch null;
}
