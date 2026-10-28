//! Document links in the editors (E07.F03.S02.T02): the links a language
//! server reports (`textDocument/documentLink`) are underlined in the
//! link colour (owner `lsp.link`), and Ctrl+click follows one: the
//! server resolves it first when it left the target out. `file:` targets
//! open in the editor (at the `#L<line>` fragment), web targets in the
//! browser; `command:` targets only from the allowlist (empty: none).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_editor = @import("zg_editor");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const store = zg_editor.model.decorations.store;
const DecorationStore = store.DecorationStore;
const StyleRef = store.StyleRef;
const Manager = zg_codeintel.Manager;
pub const LinkDriver = zg_codeintel.features.LinkDriver;

pub const DocLinks = struct {
    pub const Opener = LinkDriver.Opener;

    gpa: Allocator,
    driver: LinkDriver = undefined,
    style: StyleRef,
    files: std.ArrayList(Shown) = .empty,
    scratch: std.ArrayList(store.Decoration) = .empty,

    const Shown = struct { h: DocHandle, deco: *DecorationStore, owner: store.OwnerId };

    /// `dl` must not move once initialized.
    pub fn init(dl: *DocLinks, gpa: Allocator, mgr: *Manager, waker: zg_core.runtime.Waker, opener: Opener, style: StyleRef) void {
        dl.* = .{ .gpa = gpa, .style = style };
        dl.driver.init(mgr, opener, .{ .poll = .{ .waker = waker } });
    }

    /// Before the editors go; the driver after `Manager.deinit`
    /// (`deinitDriver`).
    pub fn release(dl: *DocLinks) void {
        for (dl.files.items) |s| s.deco.clearOwner(s.owner);
        dl.files.clearRetainingCapacity();
    }

    pub fn deinitDriver(dl: *DocLinks) void {
        dl.driver.deinit();
        dl.files.deinit(dl.gpa);
        dl.scratch.deinit(dl.gpa);
    }

    /// `h` is attached to the servers; its links go into `deco`.
    pub fn track(dl: *DocLinks, h: DocHandle, deco: ?*DecorationStore) void {
        dl.driver.track(h) catch return;
        const d = deco orelse return;
        const owner = d.ownerByName("lsp.link") orelse d.registerOwner("lsp.link", 2) catch return;
        dl.files.append(dl.gpa, .{ .h = h, .deco = d, .owner = owner }) catch {};
    }

    /// `h` closed.
    pub fn untrack(dl: *DocLinks, h: DocHandle) void {
        dl.driver.untrack(h);
        for (dl.files.items, 0..) |s, i| if (std.meta.eql(s.h, h)) {
            s.deco.clearOwner(s.owner);
            _ = dl.files.swapRemove(i);
            return;
        };
    }

    /// Takes answers and redraws the underlines; true when they changed.
    pub fn tick(dl: *DocLinks) bool {
        if (!dl.driver.tick()) return false;
        for (dl.files.items) |s| dl.apply(s);
        return true;
    }

    pub fn nextDue(dl: *const DocLinks) ?i96 {
        return dl.driver.nextDue();
    }

    /// Ctrl+click at byte `off` of `h`: follows the link there; true when
    /// there is one.
    pub fn click(dl: *DocLinks, h: DocHandle, off: u64) bool {
        const i = dl.driver.linkAt(h, off) orelse return false;
        dl.driver.open(h, i);
        return true;
    }

    /// The tooltip of the link at `off`, if any.
    pub fn tooltipAt(dl: *const DocLinks, h: DocHandle, off: u64) ?[]const u8 {
        const i = dl.driver.linkAt(h, off) orelse return null;
        return dl.driver.links(h)[i].tooltip;
    }

    fn apply(dl: *DocLinks, s: Shown) void {
        const doc = s.deco.doc;
        dl.scratch.clearRetainingCapacity();
        for (dl.driver.links(s.h)) |l| dl.scratch.append(dl.gpa, .{
            .range = .{ .start = l.start, .end = l.end },
            .owner = s.owner,
            .kind = .{ .underline = .{ .kind = .straight, .style = dl.style } },
        }) catch return;
        s.deco.setOwnerDecorations(s.owner, doc.version, dl.scratch.items) catch {};
    }
};

/// A `file:` link target as a path and a zero-based line (`#L12`, `#12`
/// or `#L12,3` fragments); null when it is not a local file.
pub fn fileTarget(buf: []u8, target: []const u8) ?struct { path: []const u8, line: ?u32 } {
    var t = target;
    var line: ?u32 = null;
    if (std.mem.indexOfScalar(u8, t, '#')) |i| {
        var frag = t[i + 1 ..];
        t = t[0..i];
        if (frag.len > 0 and (frag[0] == 'L' or frag[0] == 'l')) frag = frag[1..];
        const end = std.mem.indexOfNone(u8, frag, "0123456789") orelse frag.len;
        if (end > 0) if (std.fmt.parseInt(u32, frag[0..end], 10)) |n| {
            line = n -| 1;
        } else |_| {};
    }
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const path = (zg_codeintel.protocol_uri.pathFromUri(fba.allocator(), t) catch return null) orelse return null;
    return .{ .path = path, .line = line };
}

test "doc_links: file targets with line fragments" {
    const testing = std.testing;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const native = @import("builtin").os.tag != .windows;
    if (native) {
        const a = fileTarget(&buf, "file:///w/a%20b.zig#L12").?;
        try testing.expectEqualStrings("/w/a b.zig", a.path);
        try testing.expectEqual(@as(?u32, 11), a.line);
        const b = fileTarget(&buf, "file:///w/c.zig").?;
        try testing.expect(b.line == null);
        try testing.expectEqual(@as(?u32, 2), fileTarget(&buf, "file:///w/c.zig#3,4").?.line);
    }
    try testing.expect(fileTarget(&buf, "https://x") == null);
}
