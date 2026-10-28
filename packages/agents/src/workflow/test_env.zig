//! Shared setup for the engine tests: an in-memory registry, the engine
//! and a scripted worker port.

const std = @import("std");
const run = @import("../runs/run.zig");
const RunRegistry = @import("../runs/registry.zig");
const WorkflowEngine = @import("exec.zig");
const BuiltinRegistry = @import("builtins.zig");
const parse = @import("parse.zig");
const fake_workers = @import("fake_workers.zig");

const testing = std.testing;
pub const io = testing.io;
pub const gpa = testing.allocator;
pub const RunId = run.RunId;
pub const Fake = fake_workers.Fake;
pub const Reply = fake_workers.Reply;
pub const Job = fake_workers.Job;

pub const Env = struct {
    reg: *RunRegistry,
    eng: *WorkflowEngine,
    fake: Fake,
    builtins: BuiltinRegistry,
    arena: std.heap.ArenaAllocator,
    parsed: std.ArrayList(parse.Parsed) = .empty,

    pub const Opts = struct {
        commands: ?WorkflowEngine.CommandPort = null,
        validator: ?@import("zg_ai").schema.validate.Validator = null,
        runs_dir: ?std.Io.Dir = null,
        delay_ms: u32 = 0,
        library: ?*@import("../library/index.zig") = null,
        ports: BuiltinRegistry.Ports = .{},
    };

    pub fn init(e: *Env, script: fake_workers.Script, opts: Opts) !void {
        e.arena = .init(gpa);
        e.parsed = .empty;
        e.reg = try RunRegistry.init(gpa, io, null, .{});
        try e.fake.init(gpa, io, script);
        e.fake.delay_ms = opts.delay_ms;
        e.builtins = try BuiltinRegistry.standard(gpa, opts.ports);
        e.eng = try WorkflowEngine.init(gpa, io, e.reg, .{
            .workers = e.fake.port(),
            .commands = opts.commands,
            .validator = opts.validator,
            .builtins = &e.builtins,
            .runs_dir = opts.runs_dir,
            .library = opts.library,
            .stall_poll_ms = 10,
        });
        e.fake.eng = e.eng;
    }

    pub fn deinit(e: *Env) void {
        e.eng.deinit();
        e.fake.deinit();
        e.builtins.deinit();
        e.reg.deinit();
        for (e.parsed.items) |*p| p.deinit();
        e.parsed.deinit(gpa);
        e.arena.deinit();
    }

    /// Parses `src` without validation (tests use limits validation
    /// would refuse, like short stall times).
    pub fn def(e: *Env, src: [:0]const u8) !*const @import("def.zig").WorkflowDef {
        var diags: parse.Diagnostics = .init(gpa);
        defer diags.deinit();
        const p = parse.parseOnly(gpa, src, &diags) catch |err| {
            var w: std.Io.Writer.Allocating = .init(gpa);
            defer w.deinit();
            try diags.format("test", &w.writer);
            std.debug.print("{s}", .{w.written()});
            return err;
        };
        try e.parsed.append(gpa, p);
        return &e.parsed.items[e.parsed.items.len - 1].def;
    }

    pub fn json(e: *Env, src: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, e.arena.allocator(), src, .{});
    }

    /// Runs `src` with `args` to the end.
    pub fn runToEnd(e: *Env, src: [:0]const u8, args: []const u8) !RunId {
        const d = try e.def(src);
        const id = try e.eng.start(d, try e.json(args), .{});
        _ = try e.eng.wait(id);
        return id;
    }

    pub fn record(e: *Env, id: RunId) run.RunRecord {
        const v = e.reg.snapshot();
        defer e.reg.release(v);
        return v.get(id).?.*;
    }

    pub fn status(e: *Env, id: RunId) run.RunStatus {
        return e.record(id).status;
    }

    /// The run's error text (copied).
    pub fn errText(e: *Env, id: RunId) []const u8 {
        const v = e.reg.snapshot();
        defer e.reg.release(v);
        const s = v.get(id).?.error_ orelse return "";
        return e.arena.allocator().dupe(u8, s) catch "";
    }

    pub fn result(e: *Env, id: RunId, step: []const u8) !std.json.Value {
        return (try e.eng.result(id, step, e.arena.allocator())) orelse .null;
    }

    /// Canonical JSON of a step's result.
    pub fn resultJson(e: *Env, id: RunId, step: []const u8) ![]const u8 {
        return WorkflowEngine.canonical(e.arena.allocator(), try e.result(id, step));
    }

    pub fn waitStatus(e: *Env, id: RunId, s: run.RunStatus) !void {
        for (0..4000) |_| {
            if (e.status(id) == s) return;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        std.debug.print("status {t}, wanted {t}\n", .{ e.status(id), s });
        return error.Timeout;
    }
};

pub const fake_workers_echo = fake_workers.echo;
