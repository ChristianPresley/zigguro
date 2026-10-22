//! Tests for `variables.zig`.

const std = @import("std");
const testing = std.testing;
const zg_core = @import("zg_core");
const v = @import("variables.zig");

const Fake = struct {
    commands_run: u32 = 0,
    prompts: u32 = 0,
    cancel: bool = false,

    fn config(_: *anyopaque, key: []const u8, _: std.mem.Allocator) ?[]const u8 {
        if (std.mem.eql(u8, key, "zig.path")) return "/opt/zig/zig";
        return null;
    }

    fn command(p: *anyopaque, id: []const u8, _: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Fake = @ptrCast(@alignCast(p));
        if (!std.mem.eql(u8, id, "zig.pickProcess")) return error.CommandNotAllowed;
        self.commands_run += 1;
        return "4242";
    }

    fn input(p: *anyopaque, def: *const v.InputDef, _: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Fake = @ptrCast(@alignCast(p));
        self.prompts += 1;
        if (self.cancel) return null;
        return switch (def.kind) {
            .prompt_string => def.default orelse "typed",
            .pick_string => def.options[1],
        };
    }
};

fn makeCtx(fake: *Fake, env: *const std.process.Environ.Map, os: std.Target.Os.Tag) v.VarContext {
    const win = os == .windows;
    return .{
        .workspace_folder = if (win) "C:\\work\\proj" else "/work/proj",
        .file = if (win) "C:\\work\\proj\\src\\app\\main.zig" else "/work/proj/src/app/main.zig",
        .line = 12,
        .column = 5,
        .selected_text = "foo",
        .cwd = if (win) "C:\\work" else "/work",
        .exec_path = if (win) "C:\\zigguro\\zigguro.exe" else "/usr/bin/zigguro",
        .user_home = if (win) "C:\\Users\\me" else "/home/me",
        .default_build_task = "zig build",
        .os = os,
        .env = env,
        .config = Fake.config,
        .command = Fake.command,
        .input = Fake.input,
        .ctx = fake,
    };
}

const golden = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "${workspaceFolder}", "/work/proj", "C:\\work\\proj" },
    .{ "${workspaceFolderBasename}", "proj", "proj" },
    .{ "${file}", "/work/proj/src/app/main.zig", "C:\\work\\proj\\src\\app\\main.zig" },
    .{ "${fileWorkspaceFolder}", "/work/proj", "C:\\work\\proj" },
    .{ "${relativeFile}", "src/app/main.zig", "src\\app\\main.zig" },
    .{ "${relativeFileDirname}", "src/app", "src\\app" },
    .{ "${fileBasename}", "main.zig", "main.zig" },
    .{ "${fileBasenameNoExtension}", "main", "main" },
    .{ "${fileExtname}", ".zig", ".zig" },
    .{ "${fileDirname}", "/work/proj/src/app", "C:\\work\\proj\\src\\app" },
    .{ "${fileDirnameBasename}", "app", "app" },
    .{ "${cwd}", "/work", "C:\\work" },
    .{ "${lineNumber}", "12", "12" },
    .{ "${columnNumber}", "5", "5" },
    .{ "${selectedText}", "foo", "foo" },
    .{ "${execPath}", "/usr/bin/zigguro", "C:\\zigguro\\zigguro.exe" },
    .{ "${defaultBuildTask}", "zig build", "zig build" },
    .{ "${pathSeparator}", "/", "\\" },
    .{ "${/}", "/", "\\" },
    .{ "${userHome}", "/home/me", "C:\\Users\\me" },
    .{ "a${fileBasename}b${lineNumber}", "amain.zigb12", "amain.zigb12" },
    .{ "no vars", "no vars", "no vars" },
    .{ "$${file}", "$/work/proj/src/app/main.zig", "$C:\\work\\proj\\src\\app\\main.zig" },
    .{ "${unterminated", "${unterminated", "${unterminated" },
};

test "variables: all predefined (golden with fake context, linux and windows separators)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var fake: Fake = .{};
    for ([_]std.Target.Os.Tag{ .linux, .windows }) |os| {
        const ctx = makeCtx(&fake, &env, os);
        for (golden) |g| {
            const want = if (os == .windows) g[2] else g[1];
            const got = try v.substituteString(arena.allocator(), g[0], &ctx, &.{});
            testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("{s} on {t}\n", .{ g[0], os });
                return err;
            };
        }
    }
}

test "variables: env/config/command allowlist/input once-per-launch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("HOME_DIR", "/h");
    var fake: Fake = .{};
    var ctx = makeCtx(&fake, &env, .linux);

    try testing.expectEqualStrings("/h|", try v.substituteString(a, "${env:HOME_DIR}|${env:NOPE}", &ctx, &.{}));
    try testing.expectEqualStrings("/opt/zig/zig;", try v.substituteString(a, "${config:zig.path};${config:x.y}", &ctx, &.{}));
    try testing.expectEqualStrings("4242", try v.substituteString(a, "${command:zig.pickProcess}", &ctx, &.{}));
    try testing.expectError(error.CommandNotAllowed, v.substituteString(a, "${command:rm.rf}", &ctx, &.{}));

    const inputs = [_]v.InputDef{
        .{ .id = "name", .kind = .prompt_string, .description = "Name", .default = "bob", .options = &.{} },
        .{ .id = "mode", .kind = .pick_string, .description = "Mode", .default = null, .options = &.{ "debug", "release" } },
    };
    var cache: v.InputCache = .empty;
    ctx.input_cache = &cache;
    try testing.expectEqualStrings("bob-release-bob", try v.substituteString(a, "${input:name}-${input:mode}-${input:name}", &ctx, &inputs));
    try testing.expectEqualStrings("bob", try v.substituteString(a, "${input:name}", &ctx, &inputs));
    try testing.expectEqual(@as(u32, 2), fake.prompts);

    ctx.input_cache = null;
    fake.cancel = true;
    try testing.expectError(error.Cancelled, v.substituteString(a, "${input:name}", &ctx, &inputs));
    try testing.expectError(error.UnknownVariable, v.substituteString(a, "${input:missing}", &ctx, &inputs));
}

test "variables: unknown variable error names it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var fake: Fake = .{};
    var diag: zg_core.report.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var ctx = makeCtx(&fake, &env, .linux);
    ctx.diag = &diag;
    try testing.expectError(error.UnknownVariable, v.substituteString(arena.allocator(), "x ${bogusVar} y", &ctx, &.{}));
    try testing.expect(std.mem.indexOf(u8, diag.messages.items[0].text, "${bogusVar}") != null);

    ctx.file = null;
    try testing.expectError(error.MissingContext, v.substituteString(arena.allocator(), "${fileBasename}", &ctx, &.{}));
}

test "variables: recursive substitution in nested objects and arrays, keys untouched" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var fake: Fake = .{};
    const ctx = makeCtx(&fake, &env, .linux);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"program":"${workspaceFolder}/zig-out/bin/app","args":["${fileBasename}",1,{"${file}":"${lineNumber}"}],"n":null}
    , .{});
    try v.substituteValue(a, &parsed, &ctx, &.{});
    const out = try std.json.Stringify.valueAlloc(a, parsed, .{});
    try testing.expectEqualStrings(
        \\{"program":"/work/proj/zig-out/bin/app","args":["main.zig",1,{"${file}":"12"}],"n":null}
    , out);
}

test "variables: single pass, no re-scan of substituted text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("EVIL", "${file}");
    var fake: Fake = .{};
    const ctx = makeCtx(&fake, &env, .linux);
    try testing.expectEqualStrings("${file}", try v.substituteString(arena.allocator(), "${env:EVIL}", &ctx, &.{}));
}

test "variables: workspaceFolder:name multi-root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var fake: Fake = .{};
    var ctx = makeCtx(&fake, &env, .linux);
    ctx.workspace_folders = &.{
        .{ .name = "proj", .path = "/work/proj" },
        .{ .name = "lib", .path = "/work/lib" },
        .{ .name = "app", .path = "/work/proj/src/app" },
    };
    try testing.expectEqualStrings("/work/lib", try v.substituteString(a, "${workspaceFolder:lib}", &ctx, &.{}));
    try testing.expectEqualStrings("lib", try v.substituteString(a, "${workspaceFolderBasename:lib}", &ctx, &.{}));
    // The most specific folder containing the file wins.
    try testing.expectEqualStrings("/work/proj/src/app", try v.substituteString(a, "${fileWorkspaceFolder}", &ctx, &.{}));
    try testing.expectEqualStrings("main.zig", try v.substituteString(a, "${relativeFile}", &ctx, &.{}));
    try testing.expectError(error.UnknownVariable, v.substituteString(a, "${workspaceFolder:nope}", &ctx, &.{}));
}
