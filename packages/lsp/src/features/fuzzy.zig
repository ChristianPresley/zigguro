//! Fuzzy subsequence scoring tuned for code identifiers, shared by
//! completion filtering, the symbol pickers and REPL completions.
//!
//! `Fuzzy.score` first rejects candidates that do not contain the pattern
//! as a case-insensitive subsequence (most candidates stop here), then runs
//! a two-row dynamic program in the style of fzf v2 / VS Code `fuzzyScore`
//! to find the best alignment:
//!
//! - +1 per matched character, +1 more when the case matches exactly;
//! - +8 when the first pattern character matches the first candidate
//!   character;
//! - +6 at a word start (after `_ - . / space`, at a lower-to-upper hump or
//!   at a letter/digit boundary);
//! - +4 for a match that directly follows the previous match;
//! - -1 per skipped character between matches, at most -8 per gap; the gap
//!   before the first match costs at most -3.
//!
//! Nothing allocates: the caller passes a reusable `Scratch`. Matching is
//! byte-wise; ASCII letters fold case and other bytes compare exactly (no
//! Unicode case folding). An empty pattern scores 0 for every candidate.

const std = @import("std");

/// Longest pattern considered; longer patterns are truncated.
pub const max_pattern = 64;
/// Candidates longer than this get a greedy alignment instead of the DP.
pub const max_candidate = 255;

/// Caller-owned DP rows, reused across candidates.
pub const Scratch = struct {
    rows: [2][256]i32 = undefined,
    /// Best score for each (pattern, candidate) cell ending in a match,
    /// kept to reconstruct match positions.
    trace: [max_pattern][256]i16 = undefined,
};

const neg_inf: i32 = std.math.minInt(i32) / 4;

const bonus_first = 8;
const bonus_word = 6;
const bonus_consecutive = 4;
const bonus_case = 1;
const gap_cap = 8;
const leading_gap_cap = 3;

/// A compiled pattern.
pub const Fuzzy = struct {
    pattern: []const u8,
    pattern_lower: [max_pattern]u8,
    len: u8,

    /// Prepares `pattern`, truncated to `max_pattern` bytes.
    pub fn init(pattern: []const u8) Fuzzy {
        const p = pattern[0..@min(pattern.len, max_pattern)];
        var f: Fuzzy = .{ .pattern = p, .pattern_lower = undefined, .len = @intCast(p.len) };
        for (p, 0..) |c, i| f.pattern_lower[i] = std.ascii.toLower(c);
        return f;
    }

    /// Scores `candidate`; null means no match. When `out_matches` is
    /// non-null, the first `len` entries receive the candidate byte index
    /// of each pattern character.
    pub fn score(f: *const Fuzzy, candidate: []const u8, scratch: *Scratch, out_matches: ?*[max_pattern]u16) ?i32 {
        const m: usize = f.len;
        if (m == 0) return 0;
        const n = candidate.len;
        if (n < m) return null;
        if (!f.isSubsequence(candidate)) return null;
        if (n > max_candidate) return f.greedy(candidate, out_matches);

        // rows[cur][j]: best score aligning pattern[0..=i] with the last
        // match at candidate[j] (neg_inf if impossible).
        var prev = &scratch.rows[0];
        var cur = &scratch.rows[1];
        const want_trace = out_matches != null;
        for (0..m) |i| {
            const pc = f.pattern_lower[i];
            // Best `prev[k]` over k <= j - 1 - gap_cap, where the gap cost
            // is capped; nearer k are scanned directly.
            var far_best: i32 = neg_inf;
            var far_k: usize = 0;
            for (0..n) |j| {
                if (i > 0 and j >= gap_cap + 1) {
                    const k = j - 1 - gap_cap;
                    if (prev[k] > far_best) {
                        far_best = prev[k];
                        far_k = k;
                    }
                }
                const c = candidate[j];
                if (std.ascii.toLower(c) != pc) {
                    cur[j] = neg_inf;
                    if (want_trace) scratch.trace[i][j] = -1;
                    continue;
                }
                var s: i32 = 1;
                if (c == f.pattern[i]) s += bonus_case;
                if (j == 0) {
                    if (i == 0) s += bonus_first;
                } else if (isWordStart(candidate[j - 1], c)) s += bonus_word;
                if (i == 0) {
                    cur[j] = s - @as(i32, @intCast(@min(j, leading_gap_cap)));
                    if (want_trace) scratch.trace[i][j] = -1;
                    continue;
                }
                // Consecutive with a match at j - 1, or after a gap.
                var best: i32 = neg_inf;
                var from: i16 = -1;
                if (j > 0 and prev[j - 1] > neg_inf) {
                    best = prev[j - 1] + bonus_consecutive;
                    from = @intCast(j - 1);
                }
                if (far_best > neg_inf and far_best - gap_cap > best) {
                    best = far_best - gap_cap;
                    from = @intCast(far_k);
                }
                var k = j -| gap_cap;
                while (k + 1 < j) : (k += 1) {
                    if (prev[k] == neg_inf) continue;
                    const g = prev[k] - gapCost(j - 1 - k);
                    if (g > best) {
                        best = g;
                        from = @intCast(k);
                    }
                }
                if (best == neg_inf) {
                    cur[j] = neg_inf;
                    if (want_trace) scratch.trace[i][j] = -1;
                    continue;
                }
                cur[j] = best + s;
                if (want_trace) scratch.trace[i][j] = from;
            }
            const t = prev;
            prev = cur;
            cur = t;
        }
        var best: i32 = neg_inf;
        var best_j: usize = 0;
        for (0..n) |j| {
            if (prev[j] > best) {
                best = prev[j];
                best_j = j;
            }
        }
        if (best == neg_inf) return null;
        if (out_matches) |out| {
            var j: i16 = @intCast(best_j);
            var i: usize = m;
            while (i > 0) {
                i -= 1;
                out[i] = @intCast(j);
                j = scratch.trace[i][@intCast(j)];
            }
        }
        return best;
    }

    fn isSubsequence(f: *const Fuzzy, candidate: []const u8) bool {
        var i: usize = 0;
        for (candidate) |c| {
            if (std.ascii.toLower(c) == f.pattern_lower[i]) {
                i += 1;
                if (i == f.len) return true;
            }
        }
        return false;
    }

    /// Greedy left-to-right alignment for candidates too long for the DP.
    fn greedy(f: *const Fuzzy, candidate: []const u8, out_matches: ?*[max_pattern]u16) ?i32 {
        var total: i32 = 0;
        var i: usize = 0;
        var last: ?usize = null;
        for (candidate, 0..) |c, j| {
            if (i == f.len) break;
            if (std.ascii.toLower(c) != f.pattern_lower[i]) continue;
            var s: i32 = 1;
            if (c == f.pattern[i]) s += bonus_case;
            if (j == 0) {
                if (i == 0) s += bonus_first;
            } else if (isWordStart(candidate[j - 1], c)) s += bonus_word;
            if (last) |l| {
                if (l + 1 == j) s += bonus_consecutive else s -= gapCost(j - 1 - l);
            } else s -= @intCast(@min(j, leading_gap_cap));
            total += s;
            if (out_matches) |out| out[i] = @intCast(@min(j, std.math.maxInt(u16)));
            last = j;
            i += 1;
        }
        return if (i == f.len) total else null;
    }
};

fn gapCost(gap: usize) i32 {
    return @intCast(@min(gap, gap_cap));
}

/// Whether `cur` starts a word given the preceding byte `prev`.
pub fn isWordStart(prev: u8, cur: u8) bool {
    return switch (prev) {
        '_', '-', '.', '/', ' ', '\\', ':' => cur != prev,
        else => (std.ascii.isLower(prev) and std.ascii.isUpper(cur)) or
            (std.ascii.isDigit(prev) != std.ascii.isDigit(cur) and std.ascii.isAlphanumeric(prev) and std.ascii.isAlphanumeric(cur)),
    };
}
