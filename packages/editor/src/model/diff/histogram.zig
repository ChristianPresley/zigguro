//! Histogram diff (JGit's HistogramDiff): patience extended to
//! low-occurrence elements. In each region, index `a`'s elements by
//! occurrence, scan `b` for common elements, extend each candidate into its
//! longest matching run and split at the run whose rarest element occurs
//! least often (ties: the longer run, then the one nearest the middle of
//! the region, which keeps the recursion shallow when many hunks are
//! evenly spaced; JGit takes the first). Recurse on both sides. An element
//! occurring more than `max_chain_length` times in a region falls back to
//! Myers, as does deep recursion. The default for review views.

const std = @import("std");
const script = @import("script.zig");
const myers_mod = @import("myers.zig");

const Allocator = std.mem.Allocator;
const Edit = script.Edit;
const Marks = script.Marks;

/// Occurrences of one element in a region above which Myers takes over.
pub const max_chain_length = 64;
const max_depth = 512;

/// The histogram edit script turning `a` into `b`.
pub fn histogram(gpa: Allocator, a: []const u32, b: []const u32, deadline: ?script.Deadline) Allocator.Error![]Edit {
    var m = try Marks.init(gpa, a, b, deadline);
    defer m.deinit(gpa);
    try markRegion(gpa, &m, 0, a.len, 0, b.len);
    return m.toScript(gpa);
}

/// Marks `a[alo..ahi]` x `b[blo..bhi]` with histogram diff.
pub fn markRegion(gpa: Allocator, m: *Marks, alo: usize, ahi: usize, blo: usize, bhi: usize) Allocator.Error!void {
    var max_id: u32 = 0;
    for (m.a[alo..ahi]) |x| max_id = @max(max_id, x);
    for (m.b[blo..bhi]) |x| max_id = @max(max_id, x);
    const ids = @as(usize, max_id) + 1;
    const counts = try gpa.alloc(u32, ids);
    defer gpa.free(counts);
    @memset(counts, 0);
    const firsts = try gpa.alloc(u32, ids);
    defer gpa.free(firsts);
    const next = try gpa.alloc(u32, m.a.len);
    defer gpa.free(next);
    var h: Histo = .{ .gpa = gpa, .m = m, .counts = counts, .firsts = firsts, .next = next };
    try h.region(alo, ahi, blo, bhi, 0);
}

/// Distance (doubled) of a run's middle from the region's middle.
fn centre(r: Histo.Run, alo: usize, ahi: usize) usize {
    const a = r.as + r.ae;
    const b = alo + ahi;
    return if (a > b) a - b else b - a;
}

const Histo = struct {
    gpa: Allocator,
    m: *Marks,
    /// Per id: occurrences in the current region's `a` (zero outside a
    /// `findRun` call, which resets the entries it touched).
    counts: []u32,
    /// Per id: its first position in the region's `a`.
    firsts: []u32,
    /// Per position of `a`: the next occurrence of the same id.
    next: []u32,

    const Run = struct { as: usize, ae: usize, bs: usize, be: usize, rc: u32 };

    fn region(h: *Histo, alo_in: usize, ahi_in: usize, blo_in: usize, bhi_in: usize, depth: u32) Allocator.Error!void {
        const m = h.m;
        var alo = alo_in;
        var ahi = ahi_in;
        var blo = blo_in;
        var bhi = bhi_in;
        m.trim(&alo, &ahi, &blo, &bhi);
        if (alo == ahi or blo == bhi or m.checkTime()) {
            m.markAll(alo, ahi, blo, bhi);
            return;
        }
        if (depth > max_depth) return myers_mod.markRegion(h.gpa, m, alo, ahi, blo, bhi, false);
        const best = (try h.findRun(alo, ahi, blo, bhi)) orelse return;
        try h.region(alo, best.as, blo, best.bs, depth + 1);
        try h.region(best.ae, ahi, best.be, bhi, depth + 1);
    }

    /// The split run, or null when the region was marked here (nothing in
    /// common, or a chain too long and Myers did it).
    fn findRun(h: *Histo, alo: usize, ahi: usize, blo: usize, bhi: usize) Allocator.Error!?Run {
        const m = h.m;
        defer for (m.a[alo..ahi]) |x| {
            h.counts[x] = 0;
        };
        // Backwards, so each chain lists positions in ascending order.
        var i = ahi;
        while (i > alo) {
            i -= 1;
            const x = m.a[i];
            h.next[i] = if (h.counts[x] > 0) h.firsts[x] else std.math.maxInt(u32);
            h.firsts[x] = @intCast(i);
            h.counts[x] += 1;
            if (h.counts[x] > max_chain_length) {
                try myers_mod.markRegion(h.gpa, m, alo, ahi, blo, bhi, false);
                return null;
            }
        }
        var best: ?Run = null;
        var best_rc: u32 = max_chain_length + 1;
        var bi = blo;
        while (bi < bhi) {
            const count = h.counts[m.b[bi]];
            if (count == 0 or count > best_rc) {
                bi += 1;
                continue;
            }
            var next_bi = bi + 1;
            var ai: u32 = h.firsts[m.b[bi]];
            while (ai != std.math.maxInt(u32)) : (ai = h.next[ai]) {
                var r: Run = .{ .as = ai, .ae = ai + 1, .bs = bi, .be = bi + 1, .rc = count };
                while (r.as > alo and r.bs > blo and m.a[r.as - 1] == m.b[r.bs - 1]) {
                    r.as -= 1;
                    r.bs -= 1;
                    if (r.rc > 1) r.rc = @min(r.rc, h.counts[m.a[r.as]]);
                }
                while (r.ae < ahi and r.be < bhi and m.a[r.ae] == m.b[r.be]) {
                    if (r.rc > 1) r.rc = @min(r.rc, h.counts[m.a[r.ae]]);
                    r.ae += 1;
                    r.be += 1;
                }
                next_bi = @max(next_bi, r.be);
                const better = if (best) |b| (r.rc < best_rc or (r.rc == best_rc and (r.ae - r.as > b.ae - b.as or
                    (r.ae - r.as == b.ae - b.as and centre(r, alo, ahi) < centre(b, alo, ahi))))) else true;
                if (better) {
                    best = r;
                    best_rc = r.rc;
                }
            }
            bi = next_bi;
        }
        if (best == null) m.markAll(alo, ahi, blo, bhi);
        return best;
    }
};
