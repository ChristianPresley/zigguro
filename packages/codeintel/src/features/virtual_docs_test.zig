//! Virtual documents against the scripted fake server (virtual_docs.script).

const std = @import("std");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const VirtualDocs = @import("virtual_docs.zig");
const NavService = @import("navigation.zig");

const testing = std.testing;
const gpa = testing.allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[0])) return true;
    return false;
}

const Fx = struct {
    h: Harness,
    d: DocHandle,
    v: VirtualDocs,
    nav: NavService,

    fn init(f: *Fx) !void {
        try f.h.init("virtual_docs.script", &.{});
        f.d = try f.h.open("main.zig", "const s = String;\n");
        try f.v.init(&f.h.mgr, .noop);
        f.nav.init(&f.h.mgr, .noop);
        try f.until(running);
    }

    fn deinit(f: *Fx) void {
        f.h.mgr.closeDoc(f.d);
        f.h.docs.release(f.d);
        f.h.mgr.deinit();
        f.nav.deinit();
        f.v.deinit();
        f.h.docs.deinit();
        f.h.reg.deinit();
        gpa.free(f.h.script);
        f.h.tmp.cleanup();
        _ = f.h.rt.deinit();
    }

    fn until(f: *Fx, comptime cond: fn (*Harness) bool) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            if (cond(&f.h)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    /// Ticks until `h` is `state` with the virtual documents' generation
    /// past `g`.
    fn settled(f: *Fx, h: DocHandle, g: u64, state: VirtualDocs.State) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.v.tick();
            if (f.v.generation > g and f.v.entryOf(h).?.state == state) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    /// Types a space at the end of the file.
    fn edit(f: *Fx) !void {
        const doc = f.h.docs.get(f.d).?;
        var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = doc.len(), .end = doc.len() }, .text = " " }});
        defer cs.deinit();
        try doc.applyChangeSet(&cs, .{ .user = 0 });
        f.h.mgr.flush();
    }

    fn text(f: *Fx, h: DocHandle) ![]u8 {
        const doc = f.h.docs.get(h).?;
        return doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    }
};

var jdt_fx: *Fx = undefined;

fn jdtClaimed(_: *Harness) bool {
    return jdt_fx.v.canOpen("jdt://contents/x");
}

test "virtual_docs: open fetches a read-only document, refresh replaces it, a registered scheme serves a definition, an unclaimed scheme shows a placeholder" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    // A scheme claimed in the capabilities.
    const uri = "rust-analyzer://expand/lib.rs";
    try testing.expect(f.v.canOpen(uri));
    try testing.expect(!f.v.canOpen("file:///w/main.zig"));
    var g = f.v.generation;
    const a = try f.v.open(uri);
    try testing.expectEqual(VirtualDocs.State.loading, f.v.entryOf(a).?.state);
    try testing.expect(f.h.docs.isReadOnly(a));
    try testing.expectEqualStrings("lib.rs", f.h.docs.name(a).?);
    try f.settled(a, g, .ready);
    var t = try f.text(a);
    try testing.expectEqualStrings("fn a() {}\nfn b() {}\n", t);
    gpa.free(t);
    // A second open shares the document.
    const a2 = try f.v.open(uri);
    try testing.expectEqual(a, a2);

    // The server's refresh (sent after the next edit) fetches it again;
    // only the changed line is replaced and the document stays clean.
    g = f.v.generation;
    const v0 = f.h.docs.get(a).?.version;
    try f.edit();
    try f.settled(a, g, .ready);
    t = try f.text(a);
    try testing.expectEqualStrings("fn a() {}\nfn c() {}\n", t);
    gpa.free(t);
    const doc = f.h.docs.get(a).?;
    try testing.expectEqual(v0 + 1, doc.version);
    try testing.expect(!doc.isDirty());
    const entries = doc.change_log.since(v0).?;
    try testing.expect(entries[0].changes.replaces[0].range.start >= 10);

    // A scheme registered later.
    jdt_fx = &f;
    try f.until(jdtClaimed);
    try testing.expectEqual(@as(u8, 1), try f.nav.go(.definition, f.d, 10, true));
    var target: ?NavService.Target = null;
    for (0..2000) |_| {
        f.h.mgr.tick();
        _ = f.nav.tick();
        if (f.nav.results()) |r| if (r.complete) {
            target = r.targets[0];
            break;
        };
        try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    const tg = target orelse return error.Timeout;
    try testing.expect(tg.path == null);
    g = f.v.generation;
    const j = try f.v.open(tg.uri);
    try testing.expectEqualStrings("String.class", f.h.docs.name(j).?);
    try f.settled(j, g, .ready);
    t = try f.text(j);
    try testing.expectEqualStrings("package java.lang;\npublic final class String {}\n", t);
    gpa.free(t);

    // Nobody claims this scheme: a placeholder, no request.
    const u = try f.v.open("zipfile:///a.zip::b.txt");
    try testing.expectEqual(VirtualDocs.State.unavailable, f.v.entryOf(u).?.state);
    t = try f.text(u);
    try testing.expectEqualStrings("Content unavailable for zipfile:\n", t);
    gpa.free(t);

    // The last release closes a document.
    f.v.release(u);
    try testing.expect(!f.h.docs.isValid(u));
    f.v.release(a);
    try testing.expect(f.h.docs.isValid(a));
    f.v.release(a2);
    try testing.expect(!f.h.docs.isValid(a));
}

test "virtual_docs: scheme and name of a URI" {
    try testing.expectEqualStrings("jdt", VirtualDocs.schemeOf("jdt://contents/A.class?x=1"));
    try testing.expectEqualStrings("", VirtualDocs.schemeOf("noscheme"));
    try testing.expectEqualStrings("A.class", VirtualDocs.nameOf("jdt://contents/A.class?x=1"));
    try testing.expectEqualStrings("b.txt", VirtualDocs.nameOf("zipfile:///a.zip::b.txt"));
    try testing.expectEqualStrings("expand", VirtualDocs.nameOf("rust-analyzer://expand/"));
}
