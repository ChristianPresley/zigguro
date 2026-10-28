//! The project section of a run's system prompt (E13.F09.S01.T01):
//! title, description, `instructions.md` (with its imports) and the
//! knowledge index, as
//!
//!     # Project: <title>
//!
//!     <description>
//!
//!     ## Instructions
//!
//!     <instructions.md>
//!
//!     ## Knowledge
//!
//!     - <path> · <title> · <size> · <modified>
//!     +N more
//!
//! Runs outside a project get no section, so their prompts stay
//! byte-identical. `Context.port` plugs it into `RunHost` (it runs on the
//! host's worker thread, which may read the disk).

const std = @import("std");
const project = @import("project.zig");
const knowledge = @import("knowledge.zig");
const ProjectStore = @import("store.zig");
const runs_port = @import("../runs/port.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Context = struct {
    io: Io,
    store: *ProjectStore,
    env: knowledge.Env,
    limits: knowledge.Limits = .{},

    /// The section for `slug`; null when there is no such project.
    pub fn section(c: *Context, arena: Allocator, slug: []const u8) !?[]const u8 {
        const v = c.store.view();
        defer c.store.release(v);
        const p = v.get(slug) orelse return null;
        const ins = try c.store.instructions(arena, slug);
        const idx = try knowledge.build(c.io, arena, p, c.env, c.limits);
        var w: Io.Writer.Allocating = .init(arena);
        write(&w.writer, p, ins, &idx) catch return error.OutOfMemory;
        return w.written();
    }

    /// Must not move after this.
    pub fn port(c: *Context) runs_port.ContextPort {
        return .{ .ctx = c, .section = sectionFn };
    }

    fn sectionFn(ctx: *anyopaque, arena: Allocator, slug: []const u8) anyerror!?[]const u8 {
        const c: *Context = @ptrCast(@alignCast(ctx));
        return c.section(arena, slug);
    }
};

pub fn write(w: *Io.Writer, p: *const project.Project, ins: ProjectStore.Instructions, idx: *const knowledge.KnowledgeIndex) Io.Writer.Error!void {
    try w.print("# Project: {s}\n\n", .{p.title});
    const desc = std.mem.trim(u8, p.description, " \t\r\n");
    if (desc.len > 0) try w.print("{s}\n\n", .{desc});
    const text = std.mem.trim(u8, ins.text, " \t\r\n");
    if (text.len > 0) {
        try w.print("## Instructions\n\n{s}\n\n", .{text});
        if (ins.truncated) try w.print("(The instructions were cut at {d} KiB.)\n\n", .{project.max_instructions / 1024});
    }
    try w.writeAll("## Knowledge\n\n");
    try knowledge.render(w, idx);
}
