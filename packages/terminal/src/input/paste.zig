//! Paste encoding: newline normalisation, control stripping, bracketed
//! paste (mode 2004) with its markers neutralised, and the verdicts the
//! view acts on (confirm a multi-line unbracketed paste, refuse a huge one).

const std = @import("std");
const Allocator = std.mem.Allocator;
const key_encode = @import("key_encode.zig");

/// Paste options (settings `terminal.paste.*`).
pub const PasteOptions = struct {
    /// Use bracketed paste when the application enabled it.
    bracketed: bool = true,
    /// `.unsafe` removes C0 controls except HT and CR, DEL, and C1
    /// (U+0080-U+009F); `.all` also removes HT; `.none` keeps them. ESC is
    /// always removed inside a bracketed paste.
    strip_controls: enum { none, unsafe, all } = .unsafe,
    /// Ask before sending a multi-line paste that is not bracketed.
    confirm_multiline: bool = true,
    max_bytes: usize = 16 << 20,
};

/// What the view does with the encoded paste.
pub const PasteVerdict = enum { send, needs_confirmation, too_large };

pub const start_marker = "\x1b[200~";
pub const end_marker = "\x1b[201~";

/// Encodes `text` into `out` (cleared first). With `.needs_confirmation`
/// the bytes are ready to send once the user agrees; with `.too_large`
/// nothing is written.
pub fn encodePaste(st: *const key_encode.EncoderState, text: []const u8, o: PasteOptions, out: *std.ArrayList(u8), gpa: Allocator) !PasteVerdict {
    out.clearRetainingCapacity();
    if (text.len > o.max_bytes) return .too_large;
    const bracketed = o.bracketed and st.bracketed_paste;
    try out.ensureTotalCapacity(gpa, text.len + start_marker.len + end_marker.len);
    if (bracketed) out.appendSliceAssumeCapacity(start_marker);
    var lines: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // CR LF and LF become CR, which is what Enter sends.
        if (c == '\r' or c == '\n') {
            out.appendAssumeCapacity('\r');
            lines += 1;
            i += if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') 2 else 1;
            continue;
        }
        // C1 controls as UTF-8: C2 80..C2 9F.
        if (c == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f) {
            if (o.strip_controls == .none) out.appendSliceAssumeCapacity(text[i..][0..2]);
            i += 2;
            continue;
        }
        const control = c < 0x20 or c == 0x7f;
        const keep = if (!control) true else if (c == 0x1b and bracketed) false else switch (o.strip_controls) {
            .none => true,
            .unsafe => c == '\t',
            .all => false,
        };
        if (keep) out.appendAssumeCapacity(c);
        i += 1;
    }
    if (bracketed) {
        // Defence in depth: ESC is already gone, so no marker can remain.
        std.debug.assert(std.mem.indexOf(u8, out.items[start_marker.len..], end_marker) == null);
        out.appendSliceAssumeCapacity(end_marker);
        return .send;
    }
    if (lines > 0 and o.confirm_multiline) return .needs_confirmation;
    return .send;
}

/// Writes a paste in chunks of at most `chunk` bytes through `write`, so
/// the session writer can apply backpressure between them.
pub fn writeChunked(bytes: []const u8, chunk: usize, ctx: anytype, comptime write: fn (@TypeOf(ctx), []const u8) anyerror!void) !void {
    var i: usize = 0;
    while (i < bytes.len) : (i += chunk) try write(ctx, bytes[i..@min(i + chunk, bytes.len)]);
}

test {
    _ = @import("paste_test.zig");
}
