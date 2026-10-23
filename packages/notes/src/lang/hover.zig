//! Link hover previews (E08.F06.S02.T02): the target note's text, or just
//! the `#heading` section or `#^block`, for the E04 MarkdownView popover.
//! The app calls `preview` on a worker (it reads the target).

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const mentions = @import("../index/mentions.zig");
const extract_mod = @import("../vault/extract.zig");
const vault_mod = @import("../vault/vault.zig");
const note_mod = @import("../vault/note.zig");
const link_nav = @import("link_nav.zig");

const Allocator = std.mem.Allocator;
const FileId = note_mod.FileId;

pub const Preview = struct {
    id: FileId,
    path: []const u8,
    title: []const u8,
    /// Markdown to render: the slice of the target named by the link.
    text: []const u8,
    /// `text`'s range in the target's bytes.
    range: [2]u32,
    /// The slice was cut at `max_bytes`.
    truncated: bool,
};

/// The preview of the link at `cursor` in `text`, or null when there is
/// no link, it is unresolved or names an attachment (the app shows images
/// itself), or the subpath is unknown.
pub fn preview(a: Allocator, view: *const note_index.IndexView, vault: *const vault_mod.Vault, from_path: []const u8, text: []const u8, cursor: u32, content: mentions.ContentSource, max_bytes: usize) !?Preview {
    const meta = try extract_mod.extract(a, text, from_path, &vault.config);
    const l = link_nav.linkAt(&meta, cursor) orelse return null;
    const t = (try link_nav.resolveLink(a, view, vault, from_path, &meta, l)) orelse return null;
    const o = switch (t) {
        .open => |o| o,
        .create => return null,
    };
    if (o.attachment) return null;
    const is_self = std.mem.eql(u8, o.path, from_path);
    const bytes = if (is_self) text else (try content.read(content.ctx, a, o.id, o.path)) orelse return null;
    // Ranges from the live bytes, not the (possibly older) index.
    const tmeta = if (is_self) meta else try extract_mod.extract(a, bytes, o.path, &vault.config);
    var range: [2]u32 = if (l.subpath != null)
        (link_nav.subpathRange(&tmeta, l.subpath, @intCast(bytes.len)) orelse return null)
    else
        .{ if (tmeta.fm_range) |r| @min(r[1], @as(u32, @intCast(bytes.len))) else 0, @intCast(bytes.len) };
    var truncated = false;
    if (range[1] - range[0] > max_bytes) {
        var cut: u32 = range[0] + @as(u32, @intCast(max_bytes));
        while (cut > range[0] and (bytes[cut] & 0xC0) == 0x80) cut -= 1;
        range[1] = cut;
        truncated = true;
    }
    return .{
        .id = o.id,
        .path = o.path,
        .title = tmeta.title,
        .text = std.mem.trim(u8, bytes[range[0]..range[1]], "\r\n"),
        .range = range,
        .truncated = truncated,
    };
}
