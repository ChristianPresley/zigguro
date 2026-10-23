//! Seeded synthetic notes and vaults for tests and benches: frontmatter,
//! headings, paragraphs with wikilinks, Markdown links, tags, tasks and
//! block ids, in roughly the proportions of real vaults.

const std = @import("std");

const Allocator = std.mem.Allocator;

const words = [_][]const u8{
    "alpha",  "beta",   "gamma",   "delta",  "system", "design",  "notes",   "meeting", "project", "review",
    "idea",   "draft",  "summary", "plan",   "zig",    "editor",  "vault",   "graph",   "index",   "search",
    "query",  "budget", "release", "bug",    "fix",    "feature", "context", "agent",   "model",   "workspace",
    "rename", "link",   "tag",     "folder", "daily",  "weekly",  "goal",    "task",    "done",    "later",
};

pub const Vault = struct {
    /// Vault-relative paths, `n<i>.md` under `f<i % folders>/`.
    paths: []const []const u8,
    /// Note bytes, parallel to `paths`.
    notes: []const []const u8,
};

pub const Options = struct {
    notes: u32,
    links_per_note: u32 = 5,
    tags: u32 = 2000,
    folders: u32 = 50,
    /// Paragraphs per note (about 60 words each).
    paragraphs: u32 = 4,
    seed: u64 = 0x5eed_0001,
};

pub fn notePath(a: Allocator, i: u32, folders: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "f{d}/n{d}.md", .{ i % folders, i });
}

/// A vault of `o.notes` notes linking to each other.
pub fn vault(a: Allocator, o: Options) !Vault {
    var prng: std.Random.DefaultPrng = .init(o.seed);
    const r = prng.random();
    const paths = try a.alloc([]const u8, o.notes);
    const notes = try a.alloc([]const u8, o.notes);
    for (paths, notes, 0..) |*p, *n, i| {
        p.* = try notePath(a, @intCast(i), o.folders);
        n.* = try note(a, r, @intCast(i), o);
    }
    return .{ .paths = paths, .notes = notes };
}

/// One note. Links go to random other notes by stem (`[[n<j>]]`), some
/// with headings, aliases or as Markdown links.
pub fn note(a: Allocator, r: std.Random, i: u32, o: Options) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    const out = &w.writer;
    try out.print("---\ntitle: Note {d}\ntags:\n  - t{d}\n  - area/{d}\naliases: [N{d}]\nstatus: {s}\nrating: {d}\ncreated: 2024-{d:0>2}-{d:0>2}\n---\n", .{
        i, r.uintLessThan(u32, o.tags), r.uintLessThan(u32, 20), i, if (r.boolean()) "draft" else "done", r.uintLessThan(u32, 5), r.uintLessThan(u32, 12) + 1, r.uintLessThan(u32, 28) + 1,
    });
    try out.print("# Note {d}\n\n", .{i});
    var links_left = o.links_per_note;
    for (0..o.paragraphs) |p| {
        if (p % 2 == 1) try out.print("## Section {d}\n\n", .{p});
        for (0..60) |k| {
            if (k > 0) try out.writeByte(' ');
            const roll = r.uintLessThan(u32, 100);
            if (links_left > 0 and roll < 4) {
                links_left -= 1;
                const j = r.uintLessThan(u32, o.notes);
                switch (r.uintLessThan(u32, 4)) {
                    0 => try out.print("[[n{d}]]", .{j}),
                    1 => try out.print("[[n{d}#Section 1|see {d}]]", .{ j, j }),
                    2 => try out.print("[link](../f{d}/n{d}.md)", .{ j % o.folders, j }),
                    else => try out.print("[[f{d}/n{d}]]", .{ j % o.folders, j }),
                }
            } else if (roll < 6) {
                try out.print("#t{d}", .{r.uintLessThan(u32, o.tags)});
            } else if (roll < 7) {
                try out.writeAll("`code #x`");
            } else {
                try out.writeAll(words[r.uintLessThan(usize, words.len)]);
            }
        }
        if (p == 0) try out.print(" ^b{d}", .{i});
        try out.writeAll("\n\n");
    }
    try out.writeAll("- [ ] open task\n- [x] closed task\n\n```zig\nconst x = 1; // #notatag [[notalink]]\n```\n");
    // Remaining links at the end.
    while (links_left > 0) : (links_left -= 1) try out.print("- related [[n{d}]]\n", .{r.uintLessThan(u32, o.notes)});
    return w.written();
}

/// A note of about `target` bytes (paragraph-padded).
pub fn sizedNote(a: Allocator, target: usize, seed: u64) ![]const u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var w: std.Io.Writer.Allocating = .init(a);
    var i: u32 = 0;
    while (w.written().len < target) : (i += 1) {
        try w.writer.writeAll(try note(a, r, i, .{ .notes = 1000, .links_per_note = 8, .paragraphs = 2 }));
    }
    return w.written();
}
