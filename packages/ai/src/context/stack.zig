//! `ContextStack`: the context pieces an app wires into an agent manager
//! (E10.F07.S01.T02, E10.F07.S03.T01). It loads the memory files once,
//! owns the reminder queue and the `ContextAssembler`, and adds the
//! compactor (automatic near the window, and `/compact [focus]`) with the
//! memory, skills and plan re-injected after a summary.
//!
//! `zg agent` builds one per run. `/context` reads `report`, and `/memory`
//! reads `memorySet`. The stack must not move after `install`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Agent = @import("../loop/Agent.zig");
const Provider = @import("../provider/Provider.zig");
const registry = @import("../models/registry.zig");
const memory = @import("memory.zig");
const reminders = @import("reminders.zig");
const assembler = @import("assembler.zig");
const compactor = @import("compactor.zig");
const env_block = @import("env_block.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    /// Where memory files come from; null loads none (`--bare`).
    sources: ?memory.Sources = null,
    env: env_block.Env,
    assembler: assembler.Options = .{},
    /// The summarizer; null leaves compaction off.
    compaction: ?Compaction = null,

    pub const Compaction = struct {
        provider: Provider,
        /// The `compaction` role model (`ModelRegistry.modelForRole`).
        model: *const registry.ModelInfo,
        cfg: compactor.Config = .{},
        hooks: ?compactor.Hooks = null,
    };
};

pub const ContextStack = struct {
    gpa: Allocator,
    io: Io,
    loader: memory.MemoryLoader,
    queue: reminders.ReminderQueue,
    assembler: assembler.ContextAssembler,
    compactor: ?compactor.Compactor = null,
    loop_compaction: compactor.LoopCompaction = undefined,
    /// Owns copies of the skills listing.
    arena: std.heap.ArenaAllocator,

    /// Loads the memory files; when that fails, the run goes on without
    /// them.
    pub fn init(s: *ContextStack, gpa: Allocator, io: Io, opts: Options) !void {
        s.* = .{
            .gpa = gpa,
            .io = io,
            .loader = .init(gpa),
            .queue = .init(gpa, io),
            .assembler = undefined,
            .arena = .init(gpa),
        };
        var state: assembler.State = .{ .env = opts.env };
        if (opts.sources) |src| state.memory = s.loader.loadInitial(io, src) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        s.assembler = .init(gpa, &s.queue, state, opts.assembler);
        if (opts.compaction) |c| {
            s.compactor = .{ .provider = c.provider, .model = c.model, .cfg = c.cfg, .hooks = c.hooks };
            s.loop_compaction = .{ .compactor = &s.compactor.?, .reinject = .{ .memory = state.memory } };
        }
    }

    pub fn deinit(s: *ContextStack) void {
        s.assembler.deinit();
        s.queue.deinit();
        s.loader.deinit();
        s.arena.deinit();
    }

    /// Plugs the assembler (and the compactor) into `d`.
    pub fn install(s: *ContextStack, d: *Agent.Deps) void {
        d.context = s.assembler.builder();
        if (s.compactor != null) d.compaction = s.loop_compaction.compaction();
    }

    /// The memory files loaded so far.
    pub fn memorySet(s: *const ContextStack) *const memory.MemorySet {
        return s.loader.current();
    }

    /// What the last request was made of, by section.
    pub fn report(s: *const ContextStack) assembler.Report {
        return s.assembler.report;
    }

    /// Lists `skills` in the system prompt and re-injects them after a
    /// compaction. Call between turns.
    pub fn setSkills(s: *ContextStack, skills: []const assembler.SkillSummary) Allocator.Error!void {
        const a = s.arena.allocator();
        const copy = try a.alloc(assembler.SkillSummary, skills.len);
        for (skills, copy) |k, *c| c.* = .{ .name = try a.dupe(u8, k.name), .description = try a.dupe(u8, k.description) };
        s.assembler.state.skills = copy;
        if (s.compactor != null) s.loop_compaction.reinject.skills = copy;
    }

    /// Plan mode adds its addendum to the system prompt. Call between turns.
    pub fn setMode(s: *ContextStack, mode: assembler.Mode) void {
        s.assembler.state.mode = mode;
    }

    /// Switches the summarizer (after `/model`).
    pub fn setCompactionModel(s: *ContextStack, provider: Provider, model: *const registry.ModelInfo) void {
        if (s.compactor) |*c| {
            c.provider = provider;
            c.model = model;
        }
    }
};
