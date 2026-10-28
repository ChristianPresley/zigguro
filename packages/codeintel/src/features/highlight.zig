//! Document highlight (E07.F03.S02.T01): the occurrences of the symbol
//! under the caret, from every server routed for documentHighlight,
//! united and mapped to byte ranges, each with its kind (text, read,
//! write). `onCursor` asks once the caret rests (`delay`) on a new word;
//! moving to another word clears the highlights until the answer comes.
//! Results for an older document version are dropped.

const HighlightService = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const position = @import("position.zig");
const request = @import("request.zig");
const hover = @import("hover.zig");

const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Range = zg_editor.model.buffer.piece_tree.Range;
const Req = request.Requester(.@"textDocument/documentHighlight", .document_highlight);

pub const Kind = enum(u2) { text = 1, read = 2, write = 3 };

/// One highlighted occurrence.
pub const Mark = struct { range: Range, kind: Kind };

pub const Options = struct {
    delay: Io.Duration = .fromMilliseconds(50),
};

gpa: Allocator,
io: Io,
req: Req,
opts: Options,
/// The caret's document, offset and word, and when it got there.
at: ?struct { h: DocHandle, offset: u64, word: Range, version: u64, since_ns: i96, asked: bool } = null,
marks: std.ArrayList(Mark) = .empty,
/// The document and version `marks` are for.
marks_doc: ?DocHandle = null,
marks_version: u64 = 0,
/// The request round `marks` came from.
marks_round: u64 = std.math.maxInt(u64),
/// Bumped when `marks` change.
generation: u64 = 0,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker, opts: Options) HighlightService {
    return .{ .gpa = mgr.gpa, .io = mgr.rt.io, .req = .init(mgr, waker), .opts = opts };
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *HighlightService) void {
    s.req.deinit();
    s.marks.deinit(s.gpa);
}

/// The caret of `h` is at `offset` (null `h`: no editor has a caret).
pub fn onCursor(s: *HighlightService, h: ?DocHandle, offset: u64) void {
    const d = h orelse return s.clear();
    const doc = s.req.mgr.docs.get(d) orelse return s.clear();
    const word = hover.wordAt(doc, offset);
    if (s.at) |a| if (std.meta.eql(a.h, d) and a.version == doc.version and a.word.start == word.start and a.word.end == word.end) {
        s.at.?.offset = offset;
        return;
    };
    // Another word: what was shown no longer applies.
    if (s.marks.items.len > 0) s.clearMarks();
    s.req.cancel();
    const now = Io.Clock.Timestamp.now(s.io, .awake).raw.nanoseconds;
    s.at = .{ .h = d, .offset = offset, .word = word, .version = doc.version, .since_ns = now, .asked = false };
}

fn clear(s: *HighlightService) void {
    s.req.cancel();
    s.at = null;
    if (s.marks.items.len > 0) s.clearMarks();
}

fn clearMarks(s: *HighlightService) void {
    s.marks.clearRetainingCapacity();
    s.marks_doc = null;
    s.generation += 1;
}

/// The highlights to show for `h`.
pub fn marksFor(s: *const HighlightService, h: DocHandle) []const Mark {
    const d = s.marks_doc orelse return &.{};
    return if (std.meta.eql(d, h)) s.marks.items else &.{};
}

/// When the next request is due (`.awake` ns), if one waits.
pub fn nextDue(s: *const HighlightService) ?i96 {
    const a = s.at orelse return null;
    if (a.asked) return null;
    return a.since_ns + s.opts.delay.nanoseconds;
}

/// Sends a due request and applies answers; true when the marks changed.
pub fn tick(s: *HighlightService) bool {
    var changed = false;
    if (s.at) |*a| if (!a.asked) {
        const now = Io.Clock.Timestamp.now(s.io, .awake).raw.nanoseconds;
        if (now >= a.since_ns + s.opts.delay.nanoseconds) {
            a.asked = true;
            _ = s.req.ask(a.h, a.offset, .{}) catch 0;
        }
    };
    const answers = s.req.take();
    if (answers.len == 0) return changed;
    for (answers) |ans| {
        const doc = s.req.mgr.docs.get(ans.h) orelse continue;
        if (doc.version != ans.version) continue;
        const list = switch (ans.result) {
            .ok => |o| o.value orelse continue,
            else => continue,
        };
        // The first answer of a round replaces; later ones add.
        if (ans.round != s.marks_round) {
            s.marks.clearRetainingCapacity();
            s.marks_round = ans.round;
        }
        var m: position.Mapper = .{ .gpa = s.gpa, .tree = &doc.tree, .enc = position.encodingOf(ans.client.encoding()) };
        defer m.deinit();
        for (list) |dh| {
            const r = m.toRange(dh.range) catch continue;
            const kind: Kind = switch (dh.kind orelse .Text) {
                .Read => .read,
                .Write => .write,
                else => .text,
            };
            addUnion(s, .{ .range = r, .kind = kind }) catch continue;
        }
        s.marks_doc = ans.h;
        s.marks_version = ans.version;
        changed = true;
    }
    if (changed) {
        std.mem.sort(Mark, s.marks.items, {}, struct {
            fn lt(_: void, a: Mark, b: Mark) bool {
                return a.range.start < b.range.start or (a.range.start == b.range.start and a.range.end < b.range.end);
            }
        }.lt);
        s.generation += 1;
    }
    return changed;
}

/// Adds `mk` unless the same range is there; the strongest kind wins
/// (write over read over text).
fn addUnion(s: *HighlightService, mk: Mark) Allocator.Error!void {
    for (s.marks.items) |*x| if (x.range.start == mk.range.start and x.range.end == mk.range.end) {
        if (@intFromEnum(mk.kind) > @intFromEnum(x.kind)) x.kind = mk.kind;
        return;
    };
    try s.marks.append(s.gpa, mk);
}
