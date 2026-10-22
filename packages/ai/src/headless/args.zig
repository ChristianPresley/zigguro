//! `zg agent` flags (E10.F10.S01.T01). `parseArgs` only checks syntax and
//! combinations; the runner resolves sessions, models and files.

const std = @import("std");
const proto = @import("zg_ai_proto");
const resume_mod = @import("../session/resume.zig");
const store_mod = @import("../session/store.zig");
const index_mod = @import("../session/index.zig");
const deps = @import("../loop/deps.zig");
const validate = @import("../schema/validate.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const exit_codes = @import("exit_codes.zig");
const signals = @import("signals.zig");
const sj = @import("stream_json.zig");

const Allocator = std.mem.Allocator;

pub const PermissionMode = resume_mod.PermissionMode;
pub const OutputFormat = enum { text, json, stream_json };
pub const InputFormat = enum { text, stream_json };
pub const PermissionPrompts = enum { none, stream };

pub const HeadlessOptions = struct {
    /// `-p/--print <prompt>`; null runs the REPL, or reads the prompt from
    /// piped stdin or stream-json input.
    prompt: ?[]const u8 = null,
    model: ?[]const u8 = null,
    output_format: OutputFormat = .text,
    input_format: InputFormat = .text,
    /// `--resume <id|name>`.
    resume_session: ?[]const u8 = null,
    continue_session: bool = false,
    fork_session: bool = false,
    no_session_persistence: bool = false,
    /// E16 rule syntax: `Tool` or `Tool(pattern)`.
    allowed_tools: []const []const u8 = &.{},
    disallowed_tools: []const []const u8 = &.{},
    permission_mode: PermissionMode = .default,
    permission_prompts: PermissionPrompts = .none,
    max_turns: ?u32 = null,
    max_budget_micros: ?u64 = null,
    max_time_ms: ?u64 = null,
    append_system_prompt: ?[]const u8 = null,
    /// A file path, or the schema itself when it starts with `{`.
    json_schema: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    mcp_configs: []const []const u8 = &.{},
    bare: bool = false,
    include_partial: bool = false,
    verbose: bool = false,
    help: bool = false,
    /// What the app provides; never set from flags.
    env: Env = .{},

    /// Whether stdin carries protocol lines rather than prompt text.
    pub fn streamInput(o: HeadlessOptions) bool {
        return o.input_format == .stream_json;
    }
};

/// The process around a headless run, filled in by the app.
pub const Env = struct {
    /// Stdin is a pipe or a file rather than a terminal.
    stdin_piped: bool = false,
    /// Piped input over `stdin_cap` bytes is saved here and referenced by path.
    spill_dir: []const u8 = ".",
    stdin_cap: usize = 1 << 20,
    /// Session persistence; null keeps the session in memory.
    store: ?*store_mod.SessionStore = null,
    /// Finds sessions for `--continue` and `--resume <name>`.
    index: ?*index_mod.SessionIndex = null,
    signals: ?*signals.Signals = null,
    /// Errors, warnings and (`-v`) tool activity.
    err: ?*std.Io.Writer = null,
    cwd: []const u8 = ".",
    default_model: []const u8 = "sonnet",
    /// The id of a new session (tests); generated when null.
    session: ?proto.SessionId = null,
    mcp_servers: []const sj.McpStatus = &.{},
    /// Checks `--json-schema` answers; the bootstrap stub when null.
    validator: ?validate.Validator = null,
    /// Durations and the approval timeout.
    clock: ratelimit.Clock = .real,
    permission_timeout_ms: u64 = 5 * 60 * 1000,
    /// The E16 engine, consulted before the flag rules.
    base_permission: ?deps.Permission = null,
};

pub const usage_text =
    \\Usage: zg agent [flags]
    \\
    \\Runs the zigguro agent without the GUI. With -p, runs one prompt and
    \\exits; with piped stdin, the input is attached to the prompt; with
    \\neither, starts a line REPL (Ctrl-D exits).
    \\
    \\  -p, --print <prompt>          run one prompt and print the answer
    \\  --model <name>                model id or alias
    \\  --output-format <f>           text (default), json or stream-json
    \\  --input-format <f>            text (default) or stream-json
    \\  --include-partial             stream_event deltas in stream-json
    \\  -r, --resume <id|name>        continue a saved session
    \\  -c, --continue                continue the most recent session
    \\  --fork-session                resume into a new session
    \\  --no-session-persistence      do not save the session
    \\  --allowed-tools <rules>       allow rules, comma-separated or repeated
    \\  --disallowed-tools <rules>    deny rules, comma-separated or repeated
    \\  --permission-mode <m>         default, accept-edits, plan, dont-ask or bypass
    \\  --permission-prompts <p>      none (default: ask means deny) or stream
    \\  --max-turns <n>               stop after n model calls
    \\  --max-budget-usd <x>          stop when the run has cost x dollars
    \\  --max-time <dur>              stop after a duration (90s, 5m, 1h)
    \\  --append-system-prompt <t>    text added to the system prompt
    \\  --json-schema <file|json>     the final answer must match this schema
    \\  --agent <name>                run as a defined agent
    \\  --mcp-config <file>           MCP servers to load (repeatable)
    \\  --bare                        skip memory files, hooks, skills and auto-MCP
    \\  -v, --verbose                 tool activity on stderr
    \\  -h, --help                    this text
    \\
++ exit_codes.help;

pub const Error = error{ Usage, OutOfMemory };

/// Parses the arguments after `agent`. On `error.Usage`, `diag` (when
/// given) names the problem.
pub fn parseArgs(arena: Allocator, args: []const [:0]const u8) error{Usage}!HeadlessOptions {
    return parseArgsDiag(arena, args, null) catch |e| switch (e) {
        error.OutOfMemory, error.Usage => error.Usage,
    };
}

pub fn parseArgsDiag(arena: Allocator, args: []const [:0]const u8, diag: ?*[]const u8) Error!HeadlessOptions {
    var o: HeadlessOptions = .{};
    var allowed: std.ArrayList([]const u8) = .empty;
    var disallowed: std.ArrayList([]const u8) = .empty;
    var mcp: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    const fail = struct {
        fn f(d: ?*[]const u8, msg: []const u8) Error {
            if (d) |p| p.* = msg;
            return error.Usage;
        }
    }.f;
    while (i < args.len) : (i += 1) {
        const raw: []const u8 = args[i];
        // `--flag=value` and `--flag value` are both accepted.
        var name = raw;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, raw, "--")) if (std.mem.indexOfScalar(u8, raw, '=')) |at| {
            name = raw[0..at];
            inline_value = raw[at + 1 ..];
        };
        const Value = struct {
            fn take(a: []const [:0]const u8, idx: *usize, inl: ?[]const u8, d: ?*[]const u8) Error![]const u8 {
                if (inl) |v| return v;
                if (idx.* + 1 >= a.len) return fail(d, "missing value");
                idx.* += 1;
                return a[idx.*];
            }
        };
        if (eq(name, "-p", "--print")) {
            if (o.prompt != null) return fail(diag, "--print given twice");
            o.prompt = try Value.take(args, &i, inline_value, diag);
        } else if (eq(name, null, "--model")) {
            o.model = try Value.take(args, &i, inline_value, diag);
            if (o.model.?.len == 0) return fail(diag, "empty --model");
        } else if (eq(name, null, "--output-format")) {
            o.output_format = try enumArg(OutputFormat, try Value.take(args, &i, inline_value, diag), diag);
        } else if (eq(name, null, "--input-format")) {
            o.input_format = try enumArg(InputFormat, try Value.take(args, &i, inline_value, diag), diag);
        } else if (eq(name, "-r", "--resume")) {
            o.resume_session = try Value.take(args, &i, inline_value, diag);
        } else if (eq(name, "-c", "--continue")) {
            o.continue_session = true;
        } else if (eq(name, null, "--fork-session")) {
            o.fork_session = true;
        } else if (eq(name, null, "--no-session-persistence")) {
            o.no_session_persistence = true;
        } else if (eq(name, null, "--allowed-tools") or eq(name, null, "--allowedTools")) {
            try splitRules(arena, &allowed, try Value.take(args, &i, inline_value, diag), diag);
        } else if (eq(name, null, "--disallowed-tools") or eq(name, null, "--disallowedTools")) {
            try splitRules(arena, &disallowed, try Value.take(args, &i, inline_value, diag), diag);
        } else if (eq(name, null, "--permission-mode")) {
            const v = try Value.take(args, &i, inline_value, diag);
            o.permission_mode = permissionMode(v) orelse return fail(diag, "unknown --permission-mode");
        } else if (eq(name, null, "--permission-prompts")) {
            o.permission_prompts = try enumArg(PermissionPrompts, try Value.take(args, &i, inline_value, diag), diag);
        } else if (eq(name, null, "--max-turns")) {
            const n = std.fmt.parseInt(u32, try Value.take(args, &i, inline_value, diag), 10) catch return fail(diag, "--max-turns needs a whole number");
            if (n == 0) return fail(diag, "--max-turns must be at least 1");
            o.max_turns = n;
        } else if (eq(name, null, "--max-budget-usd")) {
            o.max_budget_micros = parseUsd(try Value.take(args, &i, inline_value, diag)) orelse return fail(diag, "--max-budget-usd needs a positive amount");
        } else if (eq(name, null, "--max-time")) {
            o.max_time_ms = parseDuration(try Value.take(args, &i, inline_value, diag)) orelse return fail(diag, "--max-time needs a duration such as 90s, 5m or 1h");
        } else if (eq(name, null, "--append-system-prompt")) {
            o.append_system_prompt = try Value.take(args, &i, inline_value, diag);
        } else if (eq(name, null, "--json-schema")) {
            o.json_schema = try Value.take(args, &i, inline_value, diag);
            if (o.json_schema.?.len == 0) return fail(diag, "empty --json-schema");
        } else if (eq(name, null, "--agent")) {
            o.agent = try Value.take(args, &i, inline_value, diag);
        } else if (eq(name, null, "--mcp-config")) {
            try mcp.append(arena, try Value.take(args, &i, inline_value, diag));
        } else if (eq(name, null, "--bare")) {
            o.bare = true;
        } else if (eq(name, null, "--include-partial") or eq(name, null, "--include-partial-messages")) {
            o.include_partial = true;
        } else if (eq(name, "-v", "--verbose")) {
            o.verbose = true;
        } else if (eq(name, "-h", "--help")) {
            o.help = true;
        } else {
            return fail(diag, try std.fmt.allocPrint(arena, "{s} {s}", .{ if (raw.len > 0 and raw[0] == '-') "unknown flag" else "unexpected argument (put the prompt after -p):", raw }));
        }
        if (inline_value != null and isSwitch(name)) return fail(diag, "this flag takes no value");
    }
    o.allowed_tools = allowed.items;
    o.disallowed_tools = disallowed.items;
    o.mcp_configs = mcp.items;
    if (o.help) return o;

    // Combinations.
    if (o.resume_session != null and o.continue_session) return fail(diag, "--resume and --continue exclude each other");
    if (o.fork_session and o.resume_session == null and !o.continue_session) return fail(diag, "--fork-session needs --resume or --continue");
    if (o.no_session_persistence and (o.resume_session != null or o.continue_session)) return fail(diag, "--no-session-persistence cannot resume a session");
    if (o.input_format == .stream_json and o.output_format != .stream_json) return fail(diag, "--input-format stream-json needs --output-format stream-json");
    if (o.input_format == .stream_json and o.prompt != null) return fail(diag, "with --input-format stream-json, prompts come from stdin");
    if (o.include_partial and o.output_format != .stream_json) return fail(diag, "--include-partial needs --output-format stream-json");
    if (o.permission_prompts == .stream and o.input_format != .stream_json) return fail(diag, "--permission-prompts stream needs --input-format stream-json");
    return o;
}

fn eq(name: []const u8, short: ?[]const u8, long: []const u8) bool {
    if (short) |s| if (std.mem.eql(u8, name, s)) return true;
    return std.mem.eql(u8, name, long);
}

fn isSwitch(name: []const u8) bool {
    const switches = [_][]const u8{ "--continue", "--fork-session", "--no-session-persistence", "--bare", "--include-partial", "--include-partial-messages", "--verbose", "--help" };
    for (switches) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn enumArg(comptime E: type, v: []const u8, diag: ?*[]const u8) Error!E {
    var buf: [32]u8 = undefined;
    if (v.len > buf.len) return usage(diag, "unknown value");
    const norm = buf[0..v.len];
    for (v, norm) |c, *d| d.* = if (c == '-') '_' else c;
    return std.meta.stringToEnum(E, norm) orelse usage(diag, "unknown value");
}

fn usage(diag: ?*[]const u8, msg: []const u8) Error {
    if (diag) |p| p.* = msg;
    return error.Usage;
}

fn permissionMode(v: []const u8) ?PermissionMode {
    const map = [_]struct { []const u8, PermissionMode }{
        .{ "default", .default },
        .{ "accept-edits", .accept_edits },
        .{ "acceptEdits", .accept_edits },
        .{ "plan", .plan },
        .{ "dont-ask", .dont_ask },
        .{ "dontAsk", .dont_ask },
        .{ "bypass", .bypass_permissions },
        .{ "bypassPermissions", .bypass_permissions },
    };
    for (map) |m| if (std.mem.eql(u8, v, m[0])) return m[1];
    return null;
}

/// Splits `a,b` while keeping commas inside parentheses (`Bash(git a,b)`).
fn splitRules(arena: Allocator, out: *std.ArrayList([]const u8), v: []const u8, diag: ?*[]const u8) Error!void {
    var depth: usize = 0;
    var start: usize = 0;
    for (v, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 0) {
            try addRule(arena, out, v[start..i], diag);
            start = i + 1;
        },
        else => {},
    };
    if (depth != 0) return usage(diag, "unbalanced parenthesis in a tool rule");
    try addRule(arena, out, v[start..], diag);
}

fn addRule(arena: Allocator, out: *std.ArrayList([]const u8), r: []const u8, diag: ?*[]const u8) Error!void {
    const t = std.mem.trim(u8, r, " ");
    if (t.len == 0) return;
    if (t[0] == '(' or (std.mem.indexOfScalar(u8, t, '(') != null and t[t.len - 1] != ')')) return usage(diag, "malformed tool rule");
    try out.append(arena, t);
}

/// Dollars to micro-dollars; null unless positive.
pub fn parseUsd(v: []const u8) ?u64 {
    const x = std.fmt.parseFloat(f64, v) catch return null;
    if (!(x > 0) or x > 1e9) return null;
    return @intFromFloat(@round(x * 1_000_000));
}

/// `500ms`, `90s`, `5m`, `1h`, or bare seconds; null when invalid or 0.
pub fn parseDuration(v: []const u8) ?u64 {
    const units = [_]struct { []const u8, u64 }{ .{ "ms", 1 }, .{ "s", 1000 }, .{ "m", 60_000 }, .{ "h", 3_600_000 } };
    var num = v;
    var mul: u64 = 1000;
    for (units) |u| if (std.mem.endsWith(u8, v, u[0])) {
        num = v[0 .. v.len - u[0].len];
        mul = u[1];
        break;
    };
    const n = std.fmt.parseInt(u64, num, 10) catch return null;
    if (n == 0) return null;
    return std.math.mul(u64, n, mul) catch null;
}
