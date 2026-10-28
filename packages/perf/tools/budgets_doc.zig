//! `zig build budgets-doc`: renders the budget registry to
//! docs/perf/budgets.md. With `--check`, compares instead and exits 1
//! naming the first differing line when the committed file is stale.

const std = @import("std");
const zg_perf = @import("zg_perf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: budgets-doc <out.md> [--check]\n", .{});
        return 2;
    }
    const path = args[1];
    const check_only = args.len > 2 and std.mem.eql(u8, args[2], "--check");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try zg_perf.budget.docgen.writeMarkdown(&zg_perf.budget.registry.file, &out.writer);
    const rendered = out.written();

    const cwd = std.Io.Dir.cwd();
    if (!check_only) {
        try cwd.writeFile(io, .{ .sub_path = path, .data = rendered });
        return 0;
    }
    const committed = cwd.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| {
        std.debug.print("budgets-doc: cannot read {s}: {t}; run `zig build budgets-doc`\n", .{ path, err });
        return 1;
    };
    defer gpa.free(committed);
    if (std.mem.eql(u8, committed, rendered)) return 0;
    var a = std.mem.splitScalar(u8, committed, '\n');
    var b = std.mem.splitScalar(u8, rendered, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) break;
        if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) {
            std.debug.print("budgets-doc: {s} is stale at line {d}\n  committed: {s}\n  generated: {s}\nrun `zig build budgets-doc`\n", .{ path, line, x orelse "<eof>", y orelse "<eof>" });
            break;
        }
    }
    return 1;
}
