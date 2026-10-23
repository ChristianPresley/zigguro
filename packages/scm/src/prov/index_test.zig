//! Tests for the provenance index (`index.zig`).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const fx = @import("../oplog/test_fixture.zig");
const functions = @import("../graph/revset/functions.zig");
const record = @import("record.zig");
const attribution = @import("attribution.zig");
const manifest = @import("manifest.zig");
const remap = @import("remap.zig");
const ProvenanceIndex = @import("index.zig").ProvenanceIndex;
const ObjectId = id_mod.ObjectId;
const t = std.testing;

fn idN(n: u8) ObjectId {
    var o: ObjectId = .zero;
    o.bytes[0] = n;
    return o;
}

test "prov index: agents, models, sessions and humans per commit" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var b = f.store.batch();
    var ctx: remap.RemapContext = .{ .gpa = t.allocator, .store = f.store, .batch = &b };
    const claude = try remap.writeRecord(&ctx, .{ .actor = record.Actor.agent("claude", "anthropic/claude-x", "s-1"), .created_ms = 1 });
    const other = try remap.writeRecord(&ctx, .{ .actor = record.Actor.agent("helper", "openai/gpt-y", "s-2"), .created_ms = 2 });
    const bob = try remap.writeRecord(&ctx, .{ .actor = record.Actor.human("Bob", "bob@example.com"), .created_ms = 3 });
    // c1: claude and Bob; c2: helper only; c3: Bob only.
    const specs = [_][]const ObjectId{ &.{ claude, bob }, &.{other}, &.{bob} };
    var mids: [3]ObjectId = undefined;
    for (specs, &mids, 0..) |recs, *mid, i| {
        var bld: attribution.Builder = .init(t.allocator);
        defer bld.deinit();
        for (recs) |r| try bld.push(.{ .len = 2, .prov = r });
        const fa = try manifest.encodeFile(a, "f.txt", idN(@intCast(10 + i)), try bld.toMap(a));
        mid.* = try manifest.write(&b, t.allocator, .{ .files = &.{fa} });
    }
    try b.commit();

    var ix: ProvenanceIndex = .init(t.allocator);
    defer ix.deinit();
    for (mids, 1..) |m, i| try ix.addManifest(f.store, idN(@intCast(i)), m);

    const pat = struct {
        fn p(text: []const u8) functions.Pattern {
            return functions.Pattern.parse("", text) catch unreachable;
        }
    }.p;
    try t.expect(try ix.hasAgentLines(idN(1), null));
    try t.expect(try ix.hasAgentLines(idN(2), null));
    try t.expect(!try ix.hasAgentLines(idN(3), null));
    try t.expect(!try ix.hasAgentLines(idN(4), null));
    try t.expect(try ix.hasAgentLines(idN(1), pat("claude")));
    try t.expect(!try ix.hasAgentLines(idN(2), pat("claude")));
    // Models match too.
    try t.expect(try ix.hasAgentLines(idN(2), pat("openai/")));
    try t.expect(try ix.hasAgentLines(idN(2), functions.Pattern.parse("glob", "openai/gpt-*") catch unreachable));
    try t.expect(!try ix.hasAgentLines(idN(1), pat("openai/")));
    try t.expect(ix.inSession(idN(1), "s-1"));
    try t.expect(!ix.inSession(idN(1), "s-2"));
    try t.expect(ix.inSession(idN(2), "s-2"));
    try t.expect(!ix.inSession(idN(3), "s-1"));

    // Through the evaluator's provider interface.
    const q = ix.query();
    try t.expect(try q.hasAgentLines(q.ctx, idN(1), pat("claude")));
    try t.expect(try q.inSession(q.ctx, idN(2), "s-2"));

    // Re-indexing a commit replaces its entry; one with no agent lines
    // drops it.
    try ix.addManifest(f.store, idN(1), mids[2]);
    try t.expect(!try ix.hasAgentLines(idN(1), null));
    try ix.addManifest(f.store, idN(3), mids[0]);
    try t.expect(try ix.hasAgentLines(idN(3), pat("claude")));
}
