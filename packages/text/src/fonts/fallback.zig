//! Per-cluster font choice along a fallback chain.
//!
//! A chain is an ordered list of registered instances. `resolve` picks the
//! first instance that maps every visible code point of a grapheme
//! cluster, trying color instances first for emoji presentation, and falls
//! back to the chain's first instance (which draws `.notdef`).
//!
//! E03.F07.S02.T04 builds chains from family names through the font
//! database and adds OS per-script defaults and the last-resort font;
//! `chainOf` (explicit instances) stays for tests and fixed UIs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");
const FontRegistry = registry.FontRegistry;
const InstanceId = registry.InstanceId;
const unicode = @import("../unicode/root.zig");
const decode = @import("../unicode/decode.zig");
const buffer = @import("../shape/buffer.zig");

/// An interned fallback chain.
pub const ChainId = enum(u16) { _ };

/// The presentation a cluster asks for.
pub const Presentation = enum { text, emoji, default };

/// UTS #51 emoji presentation of a grapheme cluster: VS16, a keycap,
/// a modifier, ZWJ or tag sequence, a flag, or a base with
/// Emoji_Presentation; VS15 forces text.
pub fn emojiPresentation(cluster: []const u8) bool {
    var i: usize = 0;
    var first = true;
    var base_pres = false;
    var base_pict = false;
    var regional: u8 = 0;
    while (i < cluster.len) {
        const u = decode.at(cluster, i);
        i += u.len;
        const cp = u.cp;
        switch (cp) {
            0xFE0E => return false,
            0xFE0F, 0x20E3 => return true,
            0x1F3FB...0x1F3FF, 0xE0020...0xE007F => if (!first) return true,
            0x200D => if (base_pict) return true,
            0x1F1E6...0x1F1FF => regional += 1,
            else => {},
        }
        if (first) {
            const p = unicode.props(cp);
            base_pres = p.emoji_pres;
            base_pict = p.ext_pict;
            first = false;
        }
    }
    return base_pres or regional >= 2;
}

/// Chooses an instance per grapheme cluster.
pub const Fallback = struct {
    gpa: Allocator,
    reg: *const FontRegistry,
    chains: std.ArrayList([]const InstanceId) = .empty,

    /// A resolver over the instances of `reg`.
    pub fn init(gpa: Allocator, reg: *const FontRegistry) Fallback {
        return .{ .gpa = gpa, .reg = reg };
    }

    /// Frees the chains.
    pub fn deinit(f: *Fallback) void {
        for (f.chains.items) |c| f.gpa.free(c);
        f.chains.deinit(f.gpa);
        f.* = undefined;
    }

    /// The chain of `list` in order (interned; at least one).
    pub fn chainOf(f: *Fallback, list: []const InstanceId) Allocator.Error!ChainId {
        std.debug.assert(list.len > 0);
        for (f.chains.items, 0..) |c, i| if (std.mem.eql(InstanceId, c, list)) return @enumFromInt(i);
        if (f.chains.items.len > std.math.maxInt(u16)) return error.OutOfMemory;
        const copy = try f.gpa.dupe(InstanceId, list);
        errdefer f.gpa.free(copy);
        try f.chains.append(f.gpa, copy);
        return @enumFromInt(f.chains.items.len - 1);
    }

    /// The instances of `chain`.
    pub fn instances(f: *const Fallback, chain: ChainId) []const InstanceId {
        return f.chains.items[@intFromEnum(chain)];
    }

    /// The chain's first (primary) instance.
    pub fn primary(f: *const Fallback, chain: ChainId) InstanceId {
        return f.instances(chain)[0];
    }

    /// The instance to draw `cluster` with.
    pub fn resolve(f: *const Fallback, chain: ChainId, cluster: []const u8, presentation: Presentation) InstanceId {
        const list = f.instances(chain);
        if (cluster.len == 1 and cluster[0] < 0x80 and presentation != .emoji) {
            const bit = @as(u128, 1) << @intCast(cluster[0]);
            for (list) |id| if (f.reg.get(id).ascii & bit != 0) return id;
            return list[0];
        }
        const emoji = switch (presentation) {
            .emoji => true,
            .text => false,
            .default => emojiPresentation(cluster),
        };
        if (emoji) for (list) |id| {
            if (f.reg.get(id).color and f.covers(id, cluster)) return id;
        };
        for (list) |id| if (f.covers(id, cluster)) return id;
        return list[0];
    }

    /// True when instance `id` maps every code point of `cluster` that is
    /// drawn (default-ignorables and variation selectors are not).
    pub fn covers(f: *const Fallback, id: InstanceId, cluster: []const u8) bool {
        const face = f.reg.get(id).inst.face;
        var i: usize = 0;
        while (i < cluster.len) {
            const u = decode.at(cluster, i);
            i += u.len;
            if (buffer.isDefaultIgnorable(u.cp) or buffer.isVariationSelector(u.cp)) continue;
            if (u.cp < 0x20 or u.cp == 0x7F) continue;
            if (face.glyphIndex(u.cp) == 0) return false;
        }
        return true;
    }
};
