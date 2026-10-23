//! External analysis programs (E13.F06.S02.T02): `data_run_program` runs
//! a program the user installed (python3, Rscript, duckdb, sqlite3, jq,
//! …) on workspace data and captures the files it writes as artifacts.
//!
//! Every run asks for an E16 decision first (`ApprovalPort`), showing
//! the exact argv, cwd, declared inputs, output directory and timeout.
//! The program then runs through `ExecPort`: E06's terminal service in
//! the app (a visible terminal tab the user can interrupt), or
//! `ProcessExec` headless. Either way it is spawned from an argv, never
//! through a shell. Files that are new or changed in the output
//! directory afterwards become artifacts.
//!
//! zg_terminal and zg_security sit on this package's layer, so both are
//! reached through ports that the app fills in.

const std = @import("std");
const builtin = @import("builtin");
const zg_ai = @import("zg_ai");
const artifacts = @import("../artifacts/root.zig");
const runs = @import("../runs/root.zig");
const data_tools = @import("tools.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;
const ArtifactId = artifacts.ArtifactId;

pub const tool_name = "data_run_program";
pub const max_timeout_s = 3600;
pub const default_timeout_s = 300;
/// The output tails returned to the model.
pub const tail_lines = 200;
pub const tail_bytes = 16 << 10;
/// Table previews in the result.
pub const preview_rows = 20;
/// The settings default for `agents.data.programs`: programs that a rule
/// may allow outright (any other program always asks).
pub const default_programs = [_][]const u8{ "python3", "python", "duckdb", "Rscript", "sqlite3", "jq" };

pub const schema = "{\"type\":\"object\",\"required\":[\"program\"],\"properties\":{" ++
    "\"program\":{\"type\":\"string\",\"description\":\"A program on PATH, like python3, duckdb, Rscript, sqlite3 or jq.\"}," ++
    "\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Arguments, passed as given (no shell).\"}," ++
    "\"script\":{\"type\":\"object\",\"properties\":{" ++
    "\"path\":{\"type\":\"string\",\"description\":\"A script in the workspace, or the file name for content.\"}," ++
    "\"content\":{\"type\":\"string\",\"description\":\"Script text, saved to the run's scratch folder.\"}" ++
    "},\"additionalProperties\":false,\"description\":\"Passed to the program before args.\"}," ++
    "\"inputs\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Workspace files the program reads.\"}," ++
    "\"output_dir\":{\"type\":\"string\",\"description\":\"Where the program writes results (also $ZIGGURO_OUTPUT_DIR). Default: .zigguro/artifacts/runs/<run>/.\"}," ++
    "\"timeout_s\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":3600,\"description\":\"Default 300.\"}" ++
    "},\"additionalProperties\":false}";

pub const tool = foreign.ForeignTool{
    .name = tool_name,
    .description = "Run an analysis program installed on this machine (python3, Rscript, duckdb, sqlite3, jq, …) on workspace data, after the user approves. Files written to the output directory come back as artifacts.",
    .input_schema_json = schema,
};

// ---------------------------------------------------------------------
// Ports

pub const Script = struct {
    /// Where the script is (workspace-relative).
    path: []const u8,
    /// The text, when the agent wrote it (shown in the approval card).
    content: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

/// What runs, as the approval card shows it.
pub const ProgramRun = struct {
    /// argv[0] is the resolved program path.
    argv: []const []const u8,
    /// The program as the agent named it.
    program: []const u8,
    cwd: []const u8,
    inputs: []const []const u8,
    output_dir: []const u8,
    timeout_s: u32,
    script: ?Script = null,
    /// Whether `program` is in `agents.data.programs` (a rule may allow
    /// it; any other program always asks).
    listed: bool,
};

/// An E16 decision. `allow` carries the approval ticket the exec port
/// passes on.
pub const Decision = union(enum) {
    allow: u64,
    deny: []const u8,
};

pub const ApprovalPort = struct {
    ctx: *anyopaque,
    decide: *const fn (ctx: *anyopaque, run: *const ProgramRun, payload_json: []const u8) Decision,
};

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const ExecRequest = struct {
    argv: []const []const u8,
    /// An absolute directory.
    cwd: []const u8,
    timeout_ms: u64,
    /// Added to the (secret-redacted) environment.
    env: []const EnvVar,
    /// The terminal tab's title.
    title: []const u8,
    ticket: u64,
    /// Data programs get no network unless a rule says otherwise.
    network: bool = false,
};

pub const ExecResult = struct {
    /// null when killed by a signal (or on timeout).
    exit: ?i32,
    timed_out: bool,
    stdout: []const u8,
    stderr: []const u8,
};

pub const ExecPort = struct {
    ctx: *anyopaque,
    exec: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, req: *const ExecRequest) anyerror!ExecResult,
};

/// How `resolveProgram` sees the file system.
pub const Lookup = struct {
    ctx: *anyopaque,
    /// Whether `path` is a file that can be run.
    isProgram: *const fn (ctx: *anyopaque, path: []const u8) bool,
};

// ---------------------------------------------------------------------
// Resolution

pub const Os = enum { posix, windows };

pub const ResolveOpts = struct {
    os: Os = if (builtin.os.tag == .windows) .windows else .posix,
    /// `PATHEXT` on Windows.
    pathext: []const u8 = ".COM;.EXE;.BAT;.CMD",
    /// `.bat`/`.cmd` go through cmd.exe's own argument parsing (an
    /// injection risk), so they need a policy that allows them.
    allow_batch: bool = false,
};

pub const Resolved = union(enum) {
    found: []const u8,
    /// Every place looked at, for the error message.
    not_found: []const []const u8,
    /// A batch file, refused without `allow_batch`.
    batch: []const u8,
};

/// Finds `name` on `env_path` (with `PATHEXT` on Windows: `.com` and
/// `.exe` first, `.bat` and `.cmd` only when allowed).
pub fn resolveWith(a: Allocator, lookup: Lookup, name: []const u8, env_path: []const u8, o: ResolveOpts) !Resolved {
    const sep: u8 = if (o.os == .windows) ';' else ':';
    const has_dir = std.mem.indexOfScalar(u8, name, '/') != null or (o.os == .windows and std.mem.indexOfScalar(u8, name, '\\') != null);
    const ext = std.fs.path.extension(name);
    const is_batch = o.os == .windows and (std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd"));
    if (is_batch and !o.allow_batch) return .{ .batch = name };

    // Candidate names: as given when it has an extension PATHEXT knows (or
    // on POSIX), else with each allowed extension.
    var names: std.ArrayList([]const u8) = .empty;
    if (o.os == .posix) {
        try names.append(a, name);
    } else {
        var exts: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ ".COM", ".EXE" }) |e| if (inPathext(o.pathext, e)) try exts.append(a, e);
        var it = std.mem.tokenizeScalar(u8, o.pathext, ';');
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e, ".COM") or std.ascii.eqlIgnoreCase(e, ".EXE")) continue;
            if (!o.allow_batch and (std.ascii.eqlIgnoreCase(e, ".BAT") or std.ascii.eqlIgnoreCase(e, ".CMD"))) continue;
            try exts.append(a, e);
        }
        if (ext.len > 0 and inPathext(o.pathext, ext)) try names.append(a, name);
        for (exts.items) |e| try names.append(a, try std.mem.concat(a, u8, &.{ name, lower(a, e) catch e }));
    }

    var checked: std.ArrayList([]const u8) = .empty;
    if (has_dir) {
        for (names.items) |n| {
            try checked.append(a, n);
            if (lookup.isProgram(lookup.ctx, n)) return .{ .found = n };
        }
        return .{ .not_found = checked.items };
    }
    var dirs = std.mem.tokenizeScalar(u8, env_path, sep);
    while (dirs.next()) |raw| {
        const dir = std.mem.trim(u8, raw, if (o.os == .windows) " \"" else " ");
        if (dir.len == 0) continue;
        try checked.append(a, dir);
        for (names.items) |n| {
            const full = if (o.os == .windows)
                try std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, dir, "\\/"), "\\", n })
            else
                try std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, dir, "/"), "/", n });
            if (lookup.isProgram(lookup.ctx, full)) return .{ .found = full };
        }
    }
    return .{ .not_found = checked.items };
}

fn inPathext(pathext: []const u8, ext: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, pathext, ';');
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

fn lower(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// `resolveWith` over the real file system.
pub fn resolveProgram(io: Io, gpa: Allocator, name: []const u8, env_path: []const u8) !?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: RealFs = .{ .io = io };
    const r = try resolveWith(arena.allocator(), ctx.lookup(), name, env_path, .{});
    return switch (r) {
        .found => |p| try gpa.dupe(u8, p),
        else => null,
    };
}

pub const RealFs = struct {
    io: Io,

    pub fn lookup(r: *RealFs) Lookup {
        return .{ .ctx = r, .isProgram = isProgram };
    }

    fn isProgram(ctx: *anyopaque, path: []const u8) bool {
        const r: *RealFs = @ptrCast(@alignCast(ctx));
        const st = Io.Dir.cwd().statFile(r.io, path, .{}) catch return false;
        if (st.kind != .file) return false;
        if (builtin.os.tag == .windows) return true;
        return st.permissions.toMode() & 0o111 != 0;
    }
};

// ---------------------------------------------------------------------
// The tool

pub const Deps = struct {
    gpa: Allocator,
    io: Io,
    /// The workspace, and its absolute path (the program's cwd).
    workspace: Io.Dir,
    workspace_path: []const u8,
    approval: ApprovalPort,
    exec: ExecPort,
    store: *artifacts.ArtifactStore,
    run: runs.RunId,
    session: ?[]const u8 = null,
    lookup: ?Lookup = null,
    env_path: []const u8 = "",
    resolve: ResolveOpts = .{},
    /// `agents.data.programs`.
    programs: []const []const u8 = &default_programs,
    /// Input paths go through E16's path policy (default: inside the
    /// workspace).
    policy: ?data_tools.PathPolicy = null,
    clock: zg_ai.ratelimit.Clock = .real,
};

pub const ProgramResult = struct {
    exit: ?i32,
    timed_out: bool,
    stdout_tail: []const u8,
    stderr_tail: []const u8,
    outputs: []const ArtifactId,
    duration_ms: u64,
};

pub const In = struct {
    program: []const u8,
    args: []const []const u8 = &.{},
    script: ?struct { path: ?[]const u8 = null, content: ?[]const u8 = null } = null,
    inputs: []const []const u8 = &.{},
    output_dir: ?[]const u8 = null,
    timeout_s: u32 = default_timeout_s,
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    deps: Deps,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "data_programs", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &.{tool});
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, name: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        if (!std.mem.eql(u8, name, tool_name)) return error.UnknownTool;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try run(&self.deps, arena, input_json);
        return .{ .json = r.json };
    }
};

pub const Output = data_tools.Output;

/// Runs the tool on its JSON input.
pub fn run(d: *Deps, arena: Allocator, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    const out = runTool(d, arena, if (input_json.len == 0) "{}" else input_json, &msg) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BadInput => null,
        else => blk: {
            msg = try std.fmt.allocPrint(arena, "{s} failed: {t}", .{ tool_name, e });
            break :blk null;
        },
    };
    const text = out orelse msg;
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const R = struct { content: []const Block, isError: bool };
    return .{ .json = try std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = out == null }, .{}), .is_error = out == null, .text = text };
}

fn runTool(d: *Deps, a: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const in = std.json.parseFromSliceLeaky(In, a, input, .{ .allocate = .alloc_always }) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "invalid input: {t}", .{e});
        return error.BadInput;
    };
    const pr = try prepare(d, a, in, msg);
    const result = try execute(d, a, &pr, msg);
    return resultJson(d, a, &pr, result);
}

/// Checks the input and builds the run: resolves the program, writes a
/// script to the run's scratch folder, and checks paths.
pub fn prepare(d: *Deps, a: Allocator, in: In, msg: *[]const u8) !ProgramRun {
    if (in.program.len == 0) return bad(msg, "`program` is empty");
    if (in.timeout_s == 0 or in.timeout_s > max_timeout_s) return bad(msg, "`timeout_s` must be 1..3600");

    var fs: RealFs = .{ .io = d.io };
    const lookup = d.lookup orelse fs.lookup();
    const program_path = switch (try resolveWith(a, lookup, in.program, d.env_path, d.resolve)) {
        .found => |p| p,
        .batch => |p| {
            msg.* = try std.fmt.allocPrint(a, "`{s}` is a batch file; batch files run through cmd.exe's argument parsing and need a policy that allows them", .{p});
            return error.BadInput;
        },
        .not_found => |checked| {
            var m: std.ArrayList(u8) = .empty;
            try m.print(a, "`{s}` not found on PATH (checked: ", .{in.program});
            for (checked, 0..) |c, i| try m.print(a, "{s}{s}", .{ if (i > 0) ", " else "", c });
            if (checked.len == 0) try m.appendSlice(a, "PATH is empty");
            try m.appendSlice(a, "). Programs usually available for data work: ");
            for (d.programs, 0..) |p, i| try m.print(a, "{s}{s}", .{ if (i > 0) ", " else "", p });
            try m.append(a, '.');
            msg.* = m.items;
            return error.BadInput;
        },
    };

    // The program runs in the workspace, so a relative path (a `.` entry
    // on PATH) must not resolve against it.
    const program_abs = if (std.fs.path.isAbsolute(program_path)) program_path else Io.Dir.cwd().realPathFileAlloc(d.io, program_path, a) catch program_path;

    for (in.inputs) |p| try checkPath(d, a, p, "input", msg);

    var run_buf: [26]u8 = d.run.text();
    const run_text: []const u8 = &run_buf;
    const output_dir = in.output_dir orelse try std.fmt.allocPrint(a, ".zigguro/artifacts/runs/{s}", .{run_text});
    if (data_tools.workspaceOnly(output_dir)) |why| {
        msg.* = try std.fmt.allocPrint(a, "cannot use output_dir `{s}`: {s}", .{ output_dir, why });
        return error.BadInput;
    }

    var script: ?Script = null;
    if (in.script) |s| {
        if (s.content) |content| {
            const name = std.fs.path.basename(s.path orelse try std.fmt.allocPrint(a, "script{s}", .{scriptExt(in.program)}));
            if (name.len == 0 or std.mem.eql(u8, name, "..")) return bad(msg, "bad script name");
            const dir = try std.fmt.allocPrint(a, ".zigguro/runs/{s}/scripts", .{run_text});
            try d.workspace.createDirPath(d.io, dir);
            const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
            try d.workspace.writeFile(d.io, .{ .sub_path = rel, .data = content });
            script = .{ .path = rel, .content = content, .language = languageOf(in.program, name) };
        } else if (s.path) |p| {
            try checkPath(d, a, p, "script", msg);
            script = .{ .path = p, .language = languageOf(in.program, p) };
        } else return bad(msg, "`script` needs `path` or `content`");
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, program_abs);
    if (script) |s| try argv.append(a, s.path);
    try argv.appendSlice(a, in.args);

    var listed = false;
    for (d.programs) |p| {
        if (std.mem.eql(u8, p, in.program)) listed = true;
    }
    return .{
        .argv = argv.items,
        .program = in.program,
        .cwd = d.workspace_path,
        .inputs = in.inputs,
        .output_dir = output_dir,
        .timeout_s = in.timeout_s,
        .script = script,
        .listed = listed,
    };
}

fn checkPath(d: *Deps, a: Allocator, p: []const u8, what: []const u8, msg: *[]const u8) !void {
    const denied = if (d.policy) |pol| pol.check(pol.ctx, p) else data_tools.workspaceOnly(p);
    if (denied) |why| {
        msg.* = try std.fmt.allocPrint(a, "cannot use {s} `{s}`: {s}", .{ what, p, why });
        return error.BadInput;
    }
}

fn bad(msg: *[]const u8, text: []const u8) error{BadInput} {
    msg.* = text;
    return error.BadInput;
}

fn scriptExt(program: []const u8) []const u8 {
    const base = std.fs.path.stem(program);
    const map = [_]struct { []const u8, []const u8 }{
        .{ "python", ".py" },   .{ "python3", ".py" }, .{ "Rscript", ".R" },  .{ "duckdb", ".sql" },
        .{ "sqlite3", ".sql" }, .{ "jq", ".jq" },      .{ "gnuplot", ".gp" }, .{ "awk", ".awk" },
    };
    for (map) |m| if (std.mem.eql(u8, base, m[0])) return m[1];
    return ".txt";
}

fn languageOf(program: []const u8, path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const by_ext = [_]struct { []const u8, []const u8 }{
        .{ ".py", "python" }, .{ ".R", "r" }, .{ ".r", "r" }, .{ ".sql", "sql" }, .{ ".jq", "jq" }, .{ ".awk", "awk" }, .{ ".gp", "gnuplot" },
    };
    for (by_ext) |m| if (std.mem.eql(u8, ext, m[0])) return m[1];
    _ = program;
    return null;
}

/// The approval card's payload (E16 renders it): exact argv, cwd,
/// inputs, output dir, timeout, the script, and the rule a user could
/// add to allow this program.
pub fn approvalPayload(a: Allocator, r: *const ProgramRun) ![]const u8 {
    const P = struct {
        kind: []const u8 = "RunProgram",
        program: []const u8,
        argv: []const []const u8,
        cwd: []const u8,
        inputs: []const []const u8,
        output_dir: []const u8,
        timeout_s: u32,
        script: ?Script,
        listed: bool,
        /// The program-level rule (E16 rule kind requested), and the
        /// `run_command` rule it maps to until that exists.
        rule: []const u8,
        fallback_rule: []const u8,
    };
    const base = std.fs.path.stem(r.program);
    return std.json.Stringify.valueAlloc(a, P{
        .program = r.program,
        .argv = r.argv,
        .cwd = r.cwd,
        .inputs = r.inputs,
        .output_dir = r.output_dir,
        .timeout_s = r.timeout_s,
        .script = r.script,
        .listed = r.listed,
        .rule = try std.fmt.allocPrint(a, "RunProgram({s}:*)", .{base}),
        .fallback_rule = try std.fmt.allocPrint(a, "run_command({s} *)", .{r.argv[0]}),
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

/// Asks for the decision, runs the program and captures its outputs.
pub fn execute(d: *Deps, a: Allocator, r: *const ProgramRun, msg: *[]const u8) !ProgramResult {
    const payload = try approvalPayload(a, r);
    const ticket = switch (d.approval.decide(d.approval.ctx, r, payload)) {
        .allow => |t| t,
        .deny => |why| {
            msg.* = try std.fmt.allocPrint(a, "running {s} was denied{s}{s}", .{ r.program, if (why.len > 0) ": " else "", why });
            return error.BadInput;
        },
    };

    try d.workspace.createDirPath(d.io, r.output_dir);
    const before = try snapshot(d, a, r.output_dir);

    const start = d.clock.now(d.io);
    const req: ExecRequest = .{
        .argv = r.argv,
        .cwd = r.cwd,
        .timeout_ms = @as(u64, r.timeout_s) * 1000,
        .env = &.{.{ .name = "ZIGGURO_OUTPUT_DIR", .value = r.output_dir }},
        .title = try std.fmt.allocPrint(a, "\u{2699} {s}", .{std.fs.path.basename(r.program)}),
        .ticket = ticket,
    };
    const res = try d.exec.exec(d.exec.ctx, d.io, a, &req);
    const duration: u64 = @intCast(@max(0, d.clock.now(d.io) - start));

    const after = try snapshot(d, a, r.output_dir);
    var outputs: std.ArrayList(ArtifactId) = .empty;
    for (after) |f| {
        const old = for (before) |b| {
            if (std.mem.eql(u8, b.path, f.path)) break b;
        } else null;
        if (old) |o| if (o.size == f.size and o.mtime == f.mtime) continue;
        const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ r.output_dir, f.path });
        const abs = try std.fs.path.join(a, &.{ d.workspace_path, rel });
        const id = try d.store.importFileWith(abs, .{ .run = d.run, .title = f.path, .session = d.session });
        try outputs.append(a, id);
    }
    return .{
        .exit = res.exit,
        .timed_out = res.timed_out,
        .stdout_tail = tail(res.stdout),
        .stderr_tail = tail(res.stderr),
        .outputs = outputs.items,
        .duration_ms = duration,
    };
}

const FileState = struct { path: []const u8, size: u64, mtime: i96 };

/// The files under `dir` (paths relative to it), sorted.
fn snapshot(d: *Deps, a: Allocator, dir_path: []const u8) ![]FileState {
    var dir = try d.workspace.openDir(d.io, dir_path, .{ .iterate = true });
    defer dir.close(d.io);
    var out: std.ArrayList(FileState) = .empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(d.io)) |e| {
        if (e.kind != .file) continue;
        const st = try dir.statFile(d.io, e.path, .{});
        try out.append(a, .{ .path = try a.dupe(u8, e.path), .size = st.size, .mtime = st.mtime.nanoseconds });
    }
    std.sort.pdq(FileState, out.items, {}, struct {
        fn lt(_: void, x: FileState, y: FileState) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.items;
}

/// The last `tail_lines` lines and at most `tail_bytes` bytes of `s`
/// (starting on a UTF-8 boundary).
pub fn tail(s: []const u8) []const u8 {
    var start = s.len -| tail_bytes;
    while (start < s.len and start > 0 and s[start] & 0xC0 == 0x80) start += 1;
    var lines: usize = 0;
    var i = s.len;
    // A final newline doesn't start another line.
    if (i > 0 and s[i - 1] == '\n') i -= 1;
    while (i > start) {
        i -= 1;
        if (s[i] == '\n') {
            lines += 1;
            if (lines == tail_lines) return s[i + 1 ..];
        }
    }
    return s[start..];
}

fn resultJson(d: *Deps, a: Allocator, r: *const ProgramRun, res: ProgramResult) ![]const u8 {
    const Out = struct { id: []const u8, kind: []const u8, title: []const u8, preview: ?[]const u8 = null };
    const outs = try a.alloc(Out, res.outputs.len);
    for (outs, res.outputs) |*o, id| {
        const meta = (try d.store.get(id, a)).?;
        var preview: ?[]const u8 = null;
        if (meta.kind == .table or meta.kind == .markdown or meta.kind == .text) {
            const c = d.store.read(id, null, a) catch null;
            if (c) |content| if (content.link == null) {
                preview = firstLines(content.bytes, preview_rows + 1, 8 << 10);
            };
        }
        o.* = .{ .id = try std.fmt.allocPrint(a, "{f}", .{id}), .kind = @tagName(meta.kind), .title = meta.title, .preview = preview };
    }
    const R = struct {
        argv: []const []const u8,
        exit: ?i32,
        timed_out: bool,
        duration_ms: u64,
        stdout_tail: []const u8,
        stderr_tail: []const u8,
        output_dir: []const u8,
        outputs: []const Out,
    };
    return std.json.Stringify.valueAlloc(a, R{
        .argv = r.argv,
        .exit = res.exit,
        .timed_out = res.timed_out,
        .duration_ms = res.duration_ms,
        .stdout_tail = res.stdout_tail,
        .stderr_tail = res.stderr_tail,
        .output_dir = r.output_dir,
        .outputs = outs,
    }, .{ .emit_null_optional_fields = false });
}

fn firstLines(s: []const u8, n: usize, max: usize) []const u8 {
    var count: usize = 0;
    for (s, 0..) |c, i| {
        if (i >= max) return s[0..i];
        if (c == '\n') {
            count += 1;
            if (count == n) return s[0 .. i + 1];
        }
    }
    return s;
}

// ---------------------------------------------------------------------
// Headless execution

/// Runs programs directly (no terminal): the exec port for `zg` and
/// tests. argv-based spawn, no shell; on POSIX the program gets its own
/// process group, which a timeout kills whole.
pub const ProcessExec = struct {
    gpa: Allocator,
    /// The environment the program inherits (already redacted by E16).
    env: *const std.process.Environ.Map,
    /// Output kept per stream while the program runs (the rest is
    /// dropped from the front).
    keep_bytes: usize = 256 << 10,

    pub fn port(p: *ProcessExec) ExecPort {
        return .{ .ctx = p, .exec = execFn };
    }

    fn execFn(ctx: *anyopaque, io: Io, arena: Allocator, req: *const ExecRequest) anyerror!ExecResult {
        const p: *ProcessExec = @ptrCast(@alignCast(ctx));
        var env: std.process.Environ.Map = .init(p.gpa);
        defer env.deinit();
        for (p.env.keys(), p.env.values()) |k, v| try env.put(k, v);
        for (req.env) |e| try env.put(e.name, e.value);

        // argv[0] resolves before the change of directory: a relative
        // path must not resolve against `cwd`.
        const argv = try arena.dupe([]const u8, req.argv);
        if (argv.len > 0 and !std.fs.path.isAbsolute(argv[0]) and std.mem.indexOfAny(u8, argv[0], "/\\") != null)
            argv[0] = Io.Dir.cwd().realPathFileAlloc(io, argv[0], arena) catch argv[0];
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = req.cwd },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .create_no_window = true,
        });
        defer child.kill(io);
        const pid = child.id;

        var buf: Io.File.MultiReader.Buffer(2) = undefined;
        var mr: Io.File.MultiReader = undefined;
        mr.init(p.gpa, io, buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer mr.deinit();
        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(@intCast(req.timeout_ms)), .clock = .awake } }).toDeadline(io);
        var timed_out = false;
        var dropped = [2]bool{ false, false };
        while (mr.fill(4096, deadline)) |_| {
            for (0..2) |i| {
                const rd = mr.reader(i);
                const n = rd.buffered().len;
                if (n > p.keep_bytes) {
                    rd.toss(n - p.keep_bytes / 2);
                    dropped[i] = true;
                }
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.Timeout => timed_out = true,
            else => |e| return e,
        }

        var exit: ?i32 = null;
        if (timed_out) {
            if (builtin.os.tag != .windows) if (pid) |id| std.posix.kill(-id, .KILL) catch {};
            child.kill(io);
        } else {
            switch (try child.wait(io)) {
                .exited => |c| exit = c,
                else => {},
            }
        }
        const out = try arena.dupe(u8, mr.reader(0).buffered());
        const err_out = try arena.dupe(u8, mr.reader(1).buffered());
        return .{ .exit = exit, .timed_out = timed_out, .stdout = out, .stderr = err_out };
    }
};
