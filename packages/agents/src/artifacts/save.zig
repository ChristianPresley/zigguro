//! "Save to workspace" for artifacts (E13.F07.S01.T01). A save is an E12
//! changeset that the app's review queue creates through `SavePort`;
//! saves the user starts from the pane auto-apply (with undo). Agents
//! have no save tool: they write files with E10's tools instead.

const std = @import("std");
const store_mod = @import("store.zig");
const kinds = @import("kinds.zig");

const Allocator = std.mem.Allocator;
const ArtifactStore = store_mod.ArtifactStore;
const ArtifactId = store_mod.ArtifactId;
const Provenance = store_mod.Provenance;

/// `agents.artifacts.save_dir`: workspace folders by kind.
pub const SaveDirs = struct {
    docs: []const u8 = "docs",
    data: []const u8 = "data",
    assets: []const u8 = "assets",

    pub fn forKind(d: SaveDirs, k: kinds.ArtifactKind) []const u8 {
        return switch (k) {
            .table => d.data,
            .image, .chart => d.assets,
            .markdown, .diagram, .html_source, .code, .text => d.docs,
        };
    }
};

pub const SaveRequest = struct {
    /// Workspace-relative.
    path: []const u8,
    content: []const u8,
    /// Shown in the review queue.
    summary: []const u8,
    /// Apply now (a user's save from the pane); else it waits for review.
    auto_apply: bool,
    prov: Provenance,
};

/// Creates the E12 changeset (zg_review.Queue in the app); returns its id.
pub const SavePort = struct {
    ctx: *anyopaque,
    save: *const fn (ctx: *anyopaque, req: SaveRequest) anyerror!u64,
};

/// A file name from `title`: lowercase ASCII letters, digits and `-`
/// (at most 60), else "artifact".
pub fn slug(a: Allocator, title: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 0) try out.append(a, '-');
            dash = false;
            try out.append(a, std.ascii.toLower(c));
            if (out.items.len >= 60) break;
        } else dash = true;
    }
    if (out.items.len == 0) return "artifact";
    return out.items;
}

/// The default workspace path for saving `art` (version `v`).
pub fn proposePath(a: Allocator, dirs: SaveDirs, art: *const store_mod.Artifact, v: *const store_mod.Version) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.{s}", .{ dirs.forKind(art.kind), try slug(a, art.title), v.ext });
}

/// Saves version `version` (the latest when null) of `id` to `rel_path`
/// in the workspace; returns the changeset id.
pub fn saveToWorkspace(s: *ArtifactStore, id: ArtifactId, version: ?u32, rel_path: []const u8, port: SavePort, opts: struct { auto_apply: bool = true, prov: Provenance = .{} }) !u64 {
    if (rel_path.len == 0 or std.fs.path.isAbsolute(rel_path) or escapes(rel_path)) return error.InvalidPath;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const meta = (try s.get(id, a)) orelse return error.UnknownArtifact;
    const c = try s.read(id, version, a);
    const id_text = id.text();
    const summary = try std.fmt.allocPrint(a, "Save artifact {s} v{d} ({s}) to {s}", .{ &id_text, c.version, meta.title, rel_path });
    return port.save(port.ctx, .{ .path = rel_path, .content = c.bytes, .summary = summary, .auto_apply = opts.auto_apply, .prov = opts.prov });
}

fn escapes(p: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return true;
    return false;
}
