//! gitignore(5) line parsing and per-file rule lookup.
//!
//! `parseRules` turns the bytes of one `.gitignore`, `.zgignore`,
//! `.git/info/exclude` or `core.excludesFile` into a `RuleList`.
//! `RuleList.match` answers "which line decides this path?" for a path
//! relative to the file's base directory: the last matching line wins.
//! Precedence between files (and the parent-excluded rule) is the caller's
//! job: zg-workspace's `IgnoreStack` for live trees, zg-git for snapshots.
//!
//! Line rules: blank lines and `#` comments are skipped (`\#` is a literal
//! `#`); trailing spaces are stripped unless escaped with `\ `; a leading `!`
//! negates (`\!` is a literal `!`); a trailing `/` matches directories only; a
//! leading or middle `/` anchors the pattern to the base directory, otherwise
//! it matches the basename at any depth. CRLF line ends and a UTF-8 BOM are
//! accepted. Lines that do not compile (a trailing lone `\`) are dropped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wildmatch = @import("wildmatch.zig");

/// Where a rule came from, in increasing precedence order of the enum's
/// reverse: `setting_files_exclude` beats everything, `builtin` loses to all.
pub const Source = enum(u8) { setting_files_exclude, zgignore, gitignore, git_info_exclude, core_excludes_file, builtin };

/// One parsed line.
pub const Rule = struct {
    /// The compiled pattern (leading `!`, leading `/` and trailing `/` removed).
    pat: wildmatch.Pattern,
    /// `!pattern`: a match re-includes the path.
    negate: bool,
    /// `pattern/`: matches directories only.
    dir_only: bool,
    /// Contains a `/` other than a trailing one: matched against the whole
    /// base-relative path instead of the basename.
    anchored: bool,
    /// The file kind the rule came from.
    source: Source,
    /// 1-based line number in the source file.
    line: u32,
    /// Caller-defined base directory tag (depth or a PathStore index).
    base_dir: u32 = 0,
    /// The line as written, after trailing-space trimming (for `explain`).
    text: []const u8,
};

/// The rule that decided a lookup.
pub const Hit = struct {
    /// The deciding rule.
    rule: *const Rule,
    /// Its index in `RuleList.rules` (later lines have higher indices).
    index: u32,
};

/// The rules of one ignore file, with hash indexes for the common shapes.
pub const RuleList = struct {
    /// Every rule in file order.
    rules: []const Rule,
    /// Unanchored literal basenames (lowercased) → ascending rule indices.
    literals: std.StringHashMapUnmanaged([]const u32) = .empty,
    /// Unanchored `*.ext` extensions (lowercased, with the dot) → indices.
    extensions: std.StringHashMapUnmanaged([]const u32) = .empty,
    /// Anchored rules whose first path segment is literal (lowercased
    /// segment) → ascending indices.
    first_segments: std.StringHashMapUnmanaged([]const u32) = .empty,
    /// Unanchored `abc*` prefix rules bucketed by their lowercased first
    /// byte, ascending; null when the file has none.
    prefixes: ?*const [256][]const u32 = null,
    /// Every other rule, ascending.
    general: []const u32 = &.{},

    /// An empty list.
    pub const empty: RuleList = .{ .rules = &.{} };

    /// The last line that matches `rel_to_base` (relative to this file's
    /// base directory, `/`-separated, no leading or trailing `/`), or null.
    /// `casefold` compares ASCII case-insensitively (core.ignoreCase).
    pub fn match(rl: *const RuleList, rel_to_base: []const u8, is_dir: bool, casefold: bool) ?Hit {
        if (rl.rules.len == 0) return null;
        const base = basename(rel_to_base);
        var best: ?u32 = null;
        var fold_buf: [256]u8 = undefined;
        if (rl.literals.count() == 0 and rl.extensions.count() == 0) {
            // Nothing indexed by basename.
        } else if (base.len <= fold_buf.len) {
            const key = std.ascii.lowerString(&fold_buf, base);
            if (rl.literals.get(key)) |ids| best = rl.bestOf(ids, best, rel_to_base, base, is_dir, casefold);
            if (std.mem.lastIndexOfScalar(u8, key, '.')) |dot| {
                if (rl.extensions.get(key[dot..])) |ids| best = rl.bestOf(ids, best, rel_to_base, base, is_dir, casefold);
            }
        } else {
            // Too long for the probe buffer: check the indexed rules directly.
            var it = rl.literals.valueIterator();
            while (it.next()) |ids| best = rl.bestOf(ids.*, best, rel_to_base, base, is_dir, casefold);
            var ie = rl.extensions.valueIterator();
            while (ie.next()) |ids| best = rl.bestOf(ids.*, best, rel_to_base, base, is_dir, casefold);
        }
        if (rl.prefixes) |px| {
            if (base.len > 0) best = rl.bestOf(px[std.ascii.toLower(base[0])], best, rel_to_base, base, is_dir, casefold);
        }
        if (rl.first_segments.count() > 0) {
            const first = rel_to_base[0 .. std.mem.indexOfScalar(u8, rel_to_base, '/') orelse rel_to_base.len];
            if (first.len <= fold_buf.len) {
                if (rl.first_segments.get(std.ascii.lowerString(&fold_buf, first))) |ids| best = rl.bestOf(ids, best, rel_to_base, base, is_dir, casefold);
            }
        }
        var i = rl.general.len;
        while (i > 0) {
            i -= 1;
            const idx = rl.general[i];
            if (best != null and idx < best.?) break;
            if (ruleMatches(&rl.rules[idx], rel_to_base, base, is_dir, casefold)) {
                best = idx;
                break;
            }
        }
        const b = best orelse return null;
        return .{ .rule = &rl.rules[b], .index = b };
    }

    fn bestOf(rl: *const RuleList, ids: []const u32, best: ?u32, rel: []const u8, base: []const u8, is_dir: bool, fold: bool) ?u32 {
        var i = ids.len;
        while (i > 0) {
            i -= 1;
            const idx = ids[i];
            if (best != null and idx < best.?) return best;
            if (ruleMatches(&rl.rules[idx], rel, base, is_dir, fold)) return idx;
        }
        return best;
    }
};

/// Whether `r` alone matches the path (ignoring its negation flag).
pub fn ruleMatches(r: *const Rule, rel: []const u8, base: []const u8, is_dir: bool, casefold: bool) bool {
    if (r.dir_only and !is_dir) return false;
    const subject = if (r.anchored) rel else base;
    return wildmatch.match(&r.pat, subject, .{ .casefold = casefold });
}

fn basename(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return rel;
    return rel[slash + 1 ..];
}

/// Parses one ignore file. Rules, patterns and indexes live in `arena`;
/// `bytes` is copied and need not outlive the call.
pub fn parseRules(arena: Allocator, bytes: []const u8, source: Source) !RuleList {
    var rules: std.ArrayList(Rule) = .empty;
    var data = bytes;
    if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data = data[3..];
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = trimTrailingSpaces(line);
        if (line.len == 0 or line[0] == '#') continue;
        if (try parseLine(arena, line, source, line_no)) |r| try rules.append(arena, r);
    }
    return index(arena, rules.items);
}

/// Parses a single pattern line (already trimmed) into a rule, or null when
/// the line is empty after its prefixes or fails to compile.
pub fn parseLine(arena: Allocator, line: []const u8, source: Source, line_no: u32) !?Rule {
    var p = line;
    var negate = false;
    if (p.len > 0 and p[0] == '!') {
        negate = true;
        p = p[1..];
    }
    var dir_only = false;
    if (p.len > 0 and p[p.len - 1] == '/' and !(p.len >= 2 and p[p.len - 2] == '\\')) {
        dir_only = true;
        p = p[0 .. p.len - 1];
    }
    const anchored = std.mem.indexOfScalar(u8, p, '/') != null;
    if (p.len > 0 and p[0] == '/') p = p[1..];
    if (p.len == 0) return null;
    const pat = wildmatch.compile(arena, p, .{ .pathname = true }) catch |err| switch (err) {
        error.InvalidPattern => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{
        .pat = pat,
        .negate = negate,
        .dir_only = dir_only,
        .anchored = anchored,
        .source = source,
        .line = line_no,
        .text = try arena.dupe(u8, line),
    };
}

/// Builds the hash indexes of a rule list. `rules` must stay alive.
pub fn index(arena: Allocator, rules: []const Rule) !RuleList {
    var rl: RuleList = .{ .rules = rules };
    var lits: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    var exts: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    var firsts: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    var general: std.ArrayList(u32) = .empty;
    var pre: [256]std.ArrayList(u32) = @splat(.empty);
    var any_prefix = false;
    for (rules, 0..) |r, i| {
        const idx: u32 = @intCast(i);
        const first = if (r.anchored) literalFirstSegment(&r.pat) else null;
        const map = if (first != null) &firsts else if (r.anchored) null else switch (r.pat.kind) {
            .literal => &lits,
            .extension => &exts,
            else => null,
        };
        if (map) |m| {
            const key = try std.ascii.allocLowerString(arena, first orelse r.pat.literal);
            const gop = try m.getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, idx);
        } else if (!r.anchored and r.pat.kind == .prefix and r.pat.literal.len > 0) {
            try pre[std.ascii.toLower(r.pat.literal[0])].append(arena, idx);
            any_prefix = true;
        } else if (r.pat.kind != .never) {
            try general.append(arena, idx);
        }
    }
    if (any_prefix) {
        const px = try arena.create([256][]const u32);
        for (px, &pre) |*dst, *src| dst.* = src.items;
        rl.prefixes = px;
    }
    inline for (.{ .{ &lits, &rl.literals }, .{ &exts, &rl.extensions }, .{ &firsts, &rl.first_segments } }) |pair| {
        var it = pair[0].iterator();
        while (it.next()) |e| try pair[1].put(arena, e.key_ptr.*, e.value_ptr.items);
    }
    rl.general = general.items;
    return rl;
}

/// The literal first segment of an anchored pattern (`doc/*.html` → `doc`),
/// or null when the first segment contains a wildcard.
fn literalFirstSegment(p: *const wildmatch.Pattern) ?[]const u8 {
    const lit = switch (p.kind) {
        .literal => p.literal,
        .general => if (p.ops.len > 0 and p.ops[0] == .lit) p.ops[0].lit else return null,
        else => return null,
    };
    const slash = std.mem.indexOfScalar(u8, lit, '/') orelse return null;
    if (slash == 0) return null;
    return lit[0..slash];
}

/// Strips trailing spaces that are not escaped with a backslash.
fn trimTrailingSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') {
        // Count the backslashes before this space: an odd count escapes it.
        var bs: usize = 0;
        while (end - 1 - bs > 0 and line[end - 2 - bs] == '\\') bs += 1;
        if (bs % 2 == 1) break;
        end -= 1;
    }
    return line[0..end];
}
