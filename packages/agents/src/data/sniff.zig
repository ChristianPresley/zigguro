//! Dialect sniffing (E13.F06.S01.T01) on a file's first 64 KiB.
//!
//! Every candidate delimiter (`, ; \t | ^ \x1f`) and quote (`"`, `'`) is
//! tried on the first 50 records with the real (quote-aware) reader; the
//! winner has the most stable field count above one (ties: more columns,
//! then the order above). Escapes are backslashes only when the sample
//! has `\"` inside quotes and no doubled quotes. The header guess: the
//! first row is all text while some later column is mostly numbers, or
//! its names are unique and identifier-like. `confidence` is the share of
//! records with the winning field count; the UI lets the user override.

const std = @import("std");
const csv = @import("csv.zig");

const Dialect = csv.Dialect;

pub const SniffResult = struct {
    dialect: Dialect,
    confidence: f32,
    header: bool,
    /// The usual field count.
    columns: u32,
};

pub const delimiters = [_]u8{ ',', ';', '\t', '|', '^', 0x1f };
pub const sample_len = 64 << 10;
const max_records = 50;

const Count = struct { modal: u32, share: f32, records: u32 };

/// Field counts of the first records of `sample` under `d`.
fn counts(sample: []const u8, d: Dialect) Count {
    var mem: [16 << 10]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    var fields: std.ArrayList(csv.Field) = .empty;
    var r: csv.CsvReader = .init(sample, d);
    var ns: [max_records]u32 = undefined;
    var n: usize = 0;
    while (n < max_records) {
        _ = (r.nextRecord(&fields, fba.allocator()) catch {
            // Too many fields to hold: count the record as very wide.
            ns[n] = std.math.maxInt(u32);
            n += 1;
            while (r.pos < sample.len and !csv.isTerminator(sample[@intCast(r.pos)])) r.pos += 1;
            continue;
        }) orelse break;
        // A record cut by the end of the sample doesn't count.
        if (r.pos >= sample.len and sample.len >= sample_len and n > 0) break;
        ns[n] = @intCast(fields.items.len);
        n += 1;
    }
    if (n == 0) return .{ .modal = 0, .share = 0, .records = 0 };
    var best: u32 = 0;
    var best_n: u32 = 0;
    for (ns[0..n]) |x| {
        var c: u32 = 0;
        for (ns[0..n]) |y| c += @intFromBool(x == y);
        if (c > best_n or (c == best_n and x > best)) {
            best = x;
            best_n = c;
        }
    }
    return .{ .modal = best, .share = @as(f32, @floatFromInt(best_n)) / @as(f32, @floatFromInt(n)), .records = @intCast(n) };
}

pub fn sniff(sample_in: []const u8) SniffResult {
    const sample = sample_in[0..@min(sample_in.len, sample_len)];
    var best: ?struct { d: Dialect, c: Count } = null;
    for ([_]u8{ '"', '\'' }) |q| {
        const esc = escapeOf(sample, q);
        for (delimiters) |delim| {
            const d: Dialect = .{ .delimiter = delim, .quote = q, .escape = esc };
            const c = counts(sample, d);
            if (c.modal <= 1) continue;
            if (best) |b| {
                const better = c.share > b.c.share + 0.001 or (@abs(c.share - b.c.share) <= 0.001 and c.modal > b.c.modal);
                if (!better) continue;
            }
            best = .{ .d = d, .c = c };
        }
    }
    const b = best orelse {
        const one = counts(sample, .{});
        return .{ .dialect = .{}, .confidence = if (one.records > 0) 0.3 else 0, .header = false, .columns = @max(one.modal, 1) };
    };
    var conf = b.c.share;
    if (b.c.records < 2) conf *= 0.5;
    return .{ .dialect = b.d, .confidence = conf, .header = guessHeader(sample, b.d, b.c.modal), .columns = b.c.modal };
}

/// Backslash escapes when `\q` appears and `qq` doesn't.
fn escapeOf(sample: []const u8, q: u8) csv.Escape {
    var doubled: usize = 0;
    var backslash: usize = 0;
    var i: usize = 0;
    while (i + 1 < sample.len) : (i += 1) {
        if (sample[i] == q and sample[i + 1] == q) {
            // `""` as a whole empty field doesn't count.
            const before = if (i == 0) '\n' else sample[i - 1];
            const after = if (i + 2 < sample.len) sample[i + 2] else '\n';
            if (!(isSep(before) and isSep(after))) doubled += 1;
            i += 1;
        } else if (sample[i] == '\\' and sample[i + 1] == q) {
            backslash += 1;
            i += 1;
        }
    }
    return if (backslash > 0 and doubled == 0) .backslash else .doubled;
}

fn isSep(c: u8) bool {
    return csv.isTerminator(c) or std.mem.indexOfScalar(u8, &delimiters, c) != null;
}

const Kind = enum { empty, number, text };

fn kindOf(s: []const u8) Kind {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return .empty;
    _ = std.fmt.parseFloat(f64, t) catch {
        // Thousands separators and percentages still count as numbers.
        var digits: usize = 0;
        for (t) |c| {
            if (std.ascii.isDigit(c)) {
                digits += 1;
            } else if (std.mem.indexOfScalar(u8, ",.%-+$ ", c) == null) return .text;
        }
        return if (digits > 0) .number else .text;
    };
    return .number;
}

fn identifierLike(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " ");
    if (t.len == 0 or t.len > 64 or !(std.ascii.isAlphabetic(t[0]) or t[0] == '_' or t[0] >= 0x80)) return false;
    for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == ' ' or c == '-' or c == '.' or c >= 0x80)) return false;
    return true;
}

fn guessHeader(sample: []const u8, d: Dialect, columns: u32) bool {
    var mem: [16 << 10]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    var fields: std.ArrayList(csv.Field) = .empty;
    var r: csv.CsvReader = .init(sample, d);
    var arena_buf: [8192]u8 = undefined;
    var arena: std.heap.FixedBufferAllocator = .init(&arena_buf);
    _ = (r.nextRecord(&fields, fba.allocator()) catch return false) orelse return false;
    const ncols = @min(fields.items.len, 64);
    var head: [64][]const u8 = undefined;
    var all_text = true;
    var texts: usize = 0;
    for (fields.items[0..ncols], 0..) |f, i| {
        head[i] = r.fieldText(f, arena.allocator()) catch r.raw(f);
        // Empty names (a trailing delimiter) don't count either way.
        switch (kindOf(head[i])) {
            .text => texts += 1,
            .number => all_text = false,
            .empty => {},
        }
    }
    if (texts == 0) all_text = false;
    // Later rows: does some column hold mostly numbers?
    var numeric: [64]u32 = @splat(0);
    var rows: u32 = 0;
    while (rows < max_records) {
        _ = (r.nextRecord(&fields, fba.allocator()) catch break) orelse break;
        rows += 1;
        for (fields.items[0..@min(fields.items.len, ncols)], 0..) |f, i| {
            if (kindOf(r.raw(f)) == .number) numeric[i] += 1;
        }
    }
    if (rows == 0) return false;
    var some_numeric = false;
    for (numeric[0..ncols]) |n| some_numeric = some_numeric or n * 2 > rows;
    if (all_text and some_numeric) return true;
    // Unique identifier-like names.
    if (ncols < columns or !all_text) return false;
    for (head[0..ncols], 0..) |h, i| {
        if (h.len == 0 and i == ncols - 1) continue;
        if (!identifierLike(h)) return false;
        for (head[0..i]) |o| if (std.ascii.eqlIgnoreCase(o, h)) return false;
    }
    return true;
}
