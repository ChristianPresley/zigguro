//! prlint: enforces branch, PR-title, commit and docs conventions in CI.
//!
//!   prlint --root <repo> [--title <t>] [--branch <b>] [--commits <file>] [--docs]
//!
//! `--commits` names a file of commit messages separated by NUL bytes
//! (`git log --format=%B%x00 base..head`). Exit codes: 0 clean, 1 findings,
//! 2 usage error.

const std = @import("std");
const rules = @import("rules.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var buf: [4096]u8 = undefined;
    var ew: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const err = &ew.interface;
    defer err.flush() catch {};

    var root_path: []const u8 = ".";
    var title: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var commits: ?[]const u8 = null;
    var docs = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--docs")) {
            docs = true;
            continue;
        }
        if (i + 1 >= args.len) {
            try err.print("prlint: missing value for {s}\n", .{a});
            return 2;
        }
        i += 1;
        if (std.mem.eql(u8, a, "--root")) {
            root_path = args[i];
        } else if (std.mem.eql(u8, a, "--title")) {
            title = args[i];
        } else if (std.mem.eql(u8, a, "--branch")) {
            branch = args[i];
        } else if (std.mem.eql(u8, a, "--commits")) {
            commits = args[i];
        } else {
            try err.print("prlint: unknown argument {s}\n", .{a});
            return 2;
        }
    }

    var findings: std.ArrayList(rules.Finding) = .empty;
    if (title) |t| if (rules.checkTitle(t)) |f| try findings.append(arena, f);
    if (branch) |b| if (rules.checkBranch(b)) |f| try findings.append(arena, f);
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    if (commits) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var it = std.mem.splitScalar(u8, text, 0);
        while (it.next()) |raw| {
            const msg = std.mem.trim(u8, raw, "\n\r ");
            if (msg.len == 0 or std.mem.startsWith(u8, msg, "Merge ")) continue;
            if (rules.checkCommit(msg)) |f| try findings.append(arena, .{
                .rule = f.rule,
                .message = try std.fmt.allocPrint(arena, "{s} ('{s}')", .{ f.message, std.mem.sliceTo(msg, '\n') }),
            });
        }
    }
    if (docs) try findings.appendSlice(arena, try rules.checkDocsHeadings(arena, io, root));

    for (findings.items) |f| try err.print("prlint [{s}]: {s}\n", .{ f.rule, f.message });
    if (findings.items.len == 0) try err.writeAll("prlint: ok\n");
    return if (findings.items.len == 0) 0 else 1;
}

test {
    _ = rules;
}
