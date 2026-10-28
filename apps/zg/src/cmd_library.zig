//! `zg library` (E13.F08.S02.T01): the prompt library from the command
//! line. `list` shows entries (project, user, built-in), `show ID` an
//! entry's header and body, `render ID --var k=v ...` the expanded text.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_config = @import("zg_config");
const zg_agents = @import("zg_agents");

const Io = std.Io;
const library = zg_agents.library;
const PromptLibrary = library.PromptLibrary;

pub const usage_text =
    \\Usage: zg library list [QUERY] [--json]
    \\       zg library show ID [--json]
    \\       zg library render ID [--var NAME=VALUE]... [--selection TEXT] [--file PATH]
    \\
    \\Options: --workspace DIR   (default: the current directory)
    \\
    \\Prompts live in .zigguro/prompts/**/*.md (project) and <config>/prompts
    \\(user); see docs/formats/prompts.md. Project entries override user ones,
    \\which override the built-ins (doc/*, research/*).
    \\
;

pub const Cmd = enum { list, show, render };

pub fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8) !u8 {
    var obuf: [16 * 1024]u8 = undefined;
    var ebuf: [2048]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), rt.io, &obuf);
    var err_w: Io.File.Writer = .init(.stderr(), rt.io, &ebuf);
    defer out_w.interface.flush() catch {};
    defer err_w.interface.flush() catch {};
    var user = openUserPrompts(rt, min);
    defer if (user) |*d| d.close(rt.io);
    return runIn(rt, user, argv, &out_w.interface, &err_w.interface);
}

/// `<config>/prompts`, if it exists.
fn openUserPrompts(rt: *zg_core.Runtime, min: std.process.Init.Minimal) ?Io.Dir {
    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    var env = min.environ.createMap(arena.allocator()) catch return null;
    const paths = zg_config.paths.resolve(arena.allocator(), &env, .{}) catch return null;
    const dir = std.fs.path.join(arena.allocator(), &.{ paths.config, "prompts" }) catch return null;
    return Io.Dir.cwd().openDir(rt.io, dir, .{ .iterate = true }) catch null;
}

pub fn runIn(rt: *zg_core.Runtime, user: ?Io.Dir, argv: []const [:0]const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const gpa = rt.gpa;
    const io = rt.io;
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        const asked = argv.len > 0;
        try (if (asked) out else err).writeAll(usage_text);
        return if (asked) 0 else 2;
    }
    const cmd = std.meta.stringToEnum(Cmd, argv[0]) orelse return usage(err);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var json = false;
    var workspace: []const u8 = ".";
    var vars: std.ArrayList(library.Var) = .empty;
    var ctx: library.RenderCtx = .{};
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "--var") or std.mem.eql(u8, arg, "--selection") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= argv.len) return usage(err);
            const v = argv[i];
            switch (arg[2]) {
                'w' => workspace = v,
                's' => ctx.selection = v,
                'f' => ctx.file = v,
                else => {
                    const eq = std.mem.indexOfScalar(u8, v, '=') orelse return usage(err);
                    try vars.append(a, .{ .name = v[0..eq], .value = v[eq + 1 ..] });
                },
            }
        } else try pos.append(a, arg);
    }
    switch (cmd) {
        .list => if (pos.items.len > 1) return usage(err),
        .show, .render => if (pos.items.len != 1) return usage(err),
    }

    var project: ?Io.Dir = Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ workspace, ".zigguro/prompts" }), .{ .iterate = true }) catch null;
    defer if (project) |*d| d.close(io);
    const lib = try PromptLibrary.open(gpa, io, .{ .project = project, .user = user }, null);
    defer lib.deinit();

    switch (cmd) {
        .list => {
            var hits: std.ArrayList(PromptLibrary.Hit) = .empty;
            try lib.search(if (pos.items.len == 1) pos.items[0] else "", std.math.maxInt(u32), &hits, a);
            if (pos.items.len == 0) std.mem.sort(PromptLibrary.Hit, hits.items, {}, struct {
                fn lt(_: void, x: PromptLibrary.Hit, y: PromptLibrary.Hit) bool {
                    return std.mem.lessThan(u8, x.entry.id, y.entry.id);
                }
            }.lt);
            if (json) {
                const Row = struct { id: []const u8, title: []const u8, source: []const u8, description: []const u8, tags: []const []const u8 };
                const rows = try a.alloc(Row, hits.items.len);
                for (hits.items, rows) |h, *r| r.* = .{ .id = h.entry.id, .title = h.entry.title, .source = @tagName(h.entry.source), .description = h.entry.description, .tags = h.entry.tags };
                try std.json.Stringify.value(rows, .{}, out);
                try out.writeByte('\n');
            } else for (hits.items) |h| {
                try out.print("{s:<32} {s:<8} {s}\n", .{ h.entry.id, @tagName(h.entry.source), h.entry.title });
            }
            return 0;
        },
        .show => {
            const e = lib.get(pos.items[0]) orelse return unknown(err, pos.items[0]);
            const body = try lib.body(e.id, a);
            if (json) {
                try std.json.Stringify.value(.{ .id = e.id, .title = e.title, .source = @tagName(e.source), .description = e.description, .tags = e.tags, .variables = e.variables, .body = body }, .{}, out);
                try out.writeByte('\n');
                return 0;
            }
            try out.print("{s} ({t})\n{s}\n", .{ e.id, e.source, e.title });
            if (e.description.len > 0) try out.print("{s}\n", .{e.description});
            for (e.variables) |v| {
                try out.print("  {{{{{s}}}}}  {t}{s}", .{ v.name, v.kind, if (v.required) ", required" else "" });
                if (v.default) |d| try out.print(", default {s}", .{d});
                if (v.options.len > 0) {
                    try out.writeAll(", one of");
                    for (v.options) |o| try out.print(" {s}", .{o});
                }
                try out.writeByte('\n');
            }
            try out.print("\n{s}", .{body});
            if (body.len == 0 or body[body.len - 1] != '\n') try out.writeByte('\n');
            return 0;
        },
        .render => {
            if (lib.get(pos.items[0]) == null) return unknown(err, pos.items[0]);
            const ins = lib.insertion(a, pos.items[0], vars.items, ctx, "") catch |e| {
                try err.print("zg library: {s}: {t}\n", .{ pos.items[0], e });
                return 1;
            };
            switch (ins) {
                .command => |c| try out.print("{s}\n", .{c}),
                .text => |r| {
                    try out.writeAll(r.text);
                    for (r.missing) |m| try err.print("zg library: missing --var {s}=...\n", .{m});
                    for (r.invalid) |x| try err.print("zg library: {s}: {s}\n", .{ x.name, x.reason });
                    if (!r.ok()) return 3;
                },
            }
            return 0;
        },
    }
}

fn unknown(err: *Io.Writer, id: []const u8) !u8 {
    try err.print("zg library: no entry \"{s}\" (zg library list)\n", .{id});
    return 1;
}

fn usage(err: *Io.Writer) !u8 {
    try err.writeAll(usage_text);
    return 2;
}

const testing = std.testing;

test "zg library list show render" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".zigguro/prompts/notes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zigguro/prompts/notes/standup.md", .data = "---\ntitle: Standup\nvariables:\n  - {name: done, type: text, required: true}\n---\nDone: {{done}}\n" });
    var buf: [96]u8 = undefined;
    const ws = try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    try testing.expectEqual(@as(u8, 0), try runIn(&rt, null, &.{ "list", "--workspace", ws }, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "notes/standup") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "research/lead") != null);

    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, null, &.{ "show", "notes/standup", "--workspace", ws }, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "{{done}}  text, required") != null);

    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, null, &.{ "render", "notes/standup", "--var", "done=shipped", "--workspace", ws }, &out.writer, &err.writer));
    try testing.expectEqualStrings("Done: shipped\n", out.written());

    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 3), try runIn(&rt, null, &.{ "render", "notes/standup", "--workspace", ws }, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, err.written(), "missing --var done") != null);
    try testing.expectEqual(@as(u8, 1), try runIn(&rt, null, &.{ "show", "nope", "--workspace", ws }, &out.writer, &err.writer));
}
