//! `git commit` (E09.F09.S01.T03): writes the index's trees and a commit
//! object, then moves the checked-out branch (or a detached HEAD) with a
//! reflog entry, all-or-nothing through a ref transaction.
//!
//! Covers `-m` with git's message cleanup, `-a`, `--amend` (keeping the
//! author), `--allow-empty`, finishing a merge (`MERGE_HEAD` parents),
//! and identities and dates from `GIT_AUTHOR_*`/`GIT_COMMITTER_*` or
//! `user.name`/`user.email`. The time zone comes from the caller (zg_git
//! has no zone database). With `commit.gpgSign` (or `Options.sign =
//! .on`) commits are signed with SSH keys (`gpg.format = ssh`); other
//! formats fail with `error.SigningUnsupported`. Not yet: hooks.

const std = @import("std");
const commit_mod = @import("commit.zig");
const config_mod = @import("config.zig");
const stage = @import("stage.zig");
const write_tree = @import("write_tree.zig");
const oid_mod = @import("oid.zig");
const Repository = @import("repository.zig").Repository;
const Oid = oid_mod.Oid;
const Ident = commit_mod.Ident;
const Allocator = std.mem.Allocator;
const signing = @import("sign/signing.zig");

pub const Cleanup = enum {
    /// Trailing whitespace, and leading, trailing and repeated blank
    /// lines go (git's default for `-m`).
    whitespace,
    /// As `whitespace`, and comment lines go too.
    strip,
    verbatim,
};

pub const Options = struct {
    message: []const u8,
    /// `-a`: stage changes to tracked files first.
    all: bool = false,
    amend: bool = false,
    allow_empty: bool = false,
    cleanup: Cleanup = .whitespace,
    /// Minutes east of UTC for dates the environment does not give.
    tz_offset_min: i32 = 0,
    /// Seconds since the epoch (null: the clock).
    now: ?i64 = null,
    /// `.config` follows `commit.gpgSign`; `.on` is `-S`, `.off` is
    /// `--no-gpg-sign`.
    sign: enum { config, on, off } = .config,
    /// Passphrase prompt and agent for the signing key.
    signing: signing.Options = .{},
    /// The environment (null: the repository's).
    env: ?*const std.process.Environ.Map = null,
};

pub const Result = struct {
    oid: Oid,
    /// The branch that moved (`refs/heads/x`), or "HEAD" when detached.
    ref: []u8,
    /// The reflog message used.
    summary: []u8,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.ref);
        gpa.free(r.summary);
    }
};

/// Commits the index. Fails with `error.NothingToCommit` when the tree
/// equals the parent's (unless `allow_empty`, `amend` or a merge),
/// `error.UnmergedEntries` with conflicts left, `error.EmptyMessage`,
/// and `error.IdentityUnknown` without a name and email.
pub fn commit(repo: *Repository, opts: Options) !Result {
    const gpa = repo.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const want_sign = switch (opts.sign) {
        .on => true,
        .off => false,
        .config => signing.wanted(repo),
    };
    // Load the key first: a missing key fails before anything is written.
    const signer: ?*signing.KeySigner = if (want_sign) try signing.fromConfig(repo, opts.signing) else null;
    defer if (signer) |k| k.deinit();

    const comment = repo.config.get("core.commentchar") orelse "#";
    const message = try cleanMessage(a, opts.message, opts.cleanup, if (comment.len > 0) comment[0] else '#');
    if (message.len == 0) return error.EmptyMessage;

    var ix = try repo.readIndex();
    defer ix.deinit();
    if (opts.all) {
        if (try stage.addInto(repo, &ix, &.{}, .{ .update_only = true }) > 0) try repo.writeIndex(&ix);
    }
    const tree = try write_tree.writeTree(repo, &ix);

    const head = try repo.head();
    var parents: std.ArrayList(Oid) = .empty;
    var old_author: ?Ident = null;
    if (opts.amend) {
        const h = head orelse return error.NothingToAmend;
        const obj = try repo.odb.read(a, h);
        const c = try commit_mod.parseCommit(a, repo.format, obj.data);
        try parents.appendSlice(a, c.parents);
        old_author = c.author;
    } else if (head) |h| try parents.append(a, h);
    const merge_heads = try readMergeHeads(repo, a);
    try parents.appendSlice(a, merge_heads);

    if (!opts.allow_empty and !opts.amend and merge_heads.len == 0) {
        const same = if (head) |h| (try repo.treeOf(h)).eql(tree) else ix.entries.items.len == 0;
        if (same) return error.NothingToCommit;
    }

    const env = opts.env orelse repo.envMap();
    const now = opts.now orelse @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s)));
    const author = old_author orelse try ident(repo, a, env, .author, now, opts.tz_offset_min);
    const committer = try ident(repo, a, env, .committer, now, opts.tz_offset_min);

    const c: commit_mod.Commit = .{ .tree = tree, .parents = parents.items, .author = author, .committer = committer, .message = message };
    var aw: std.Io.Writer.Allocating = .init(a);
    try commit_mod.serializeCommit(&c, &aw.writer);
    const raw = if (signer) |k| try signing.signCommit(a, k.signer(), aw.written(), repo.format) else aw.written();
    const id = try repo.odb.writeLoose(.commit, raw);

    const subject = std.mem.sliceTo(message, '\n');
    const kind = if (opts.amend) " (amend)" else if (merge_heads.len > 0) " (merge)" else if (head == null) " (initial)" else "";
    const summary = try std.fmt.allocPrint(gpa, "commit{s}: {s}", .{ kind, subject });
    errdefer gpa.free(summary);
    const ref = (try repo.headRef(gpa)) orelse try gpa.dupe(u8, "HEAD");
    errdefer gpa.free(ref);
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update(ref, .{ .direct = id }, if (head) |h| .{ .oid = h } else .absent, summary, committer);
    try tx.commit();
    clearOperationState(repo);
    return .{ .oid = id, .ref = @constCast(ref), .summary = summary };
}

/// The commits a pending merge adds as parents (`MERGE_HEAD`).
fn readMergeHeads(repo: *Repository, a: Allocator) ![]Oid {
    const text = repo.git_dir.readFileAlloc(repo.io, "MERGE_HEAD", a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList(Oid) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \r\n");
    while (it.next()) |hex| try out.append(a, Oid.parseHex(repo.format, hex) catch return error.CorruptMergeHead);
    return out.items;
}

/// A commit ends a merge, cherry-pick or revert in progress.
fn clearOperationState(repo: *Repository) void {
    for ([_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE", "CHERRY_PICK_HEAD", "REVERT_HEAD", "SQUASH_MSG" }) |f| {
        repo.git_dir.deleteFile(repo.io, f) catch {};
    }
}

const Role = enum { author, committer };

/// Name, email and date for `role` the way git finds them.
pub fn ident(repo: *const Repository, a: Allocator, env: ?*const std.process.Environ.Map, role: Role, now: i64, tz_offset_min: i32) !Ident {
    const up = if (role == .author) "AUTHOR" else "COMMITTER";
    const low = if (role == .author) "author" else "committer";
    var kb: [32]u8 = undefined;
    const getenv = struct {
        fn f(e: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
            const m = e orelse return null;
            return m.get(key);
        }
    }.f;
    const name = getenv(env, try std.fmt.bufPrint(&kb, "GIT_{s}_NAME", .{up})) orelse
        repo.config.get(try std.fmt.bufPrint(&kb, "{s}.name", .{low})) orelse
        repo.config.get("user.name") orelse return error.IdentityUnknown;
    const email = getenv(env, try std.fmt.bufPrint(&kb, "GIT_{s}_EMAIL", .{up})) orelse
        repo.config.get(try std.fmt.bufPrint(&kb, "{s}.email", .{low})) orelse
        repo.config.get("user.email") orelse getenv(env, "EMAIL") orelse return error.IdentityUnknown;
    if (std.mem.trim(u8, name, " ").len == 0) return error.IdentityUnknown;
    var id: Ident = .{ .name = try a.dupe(u8, name), .email = try a.dupe(u8, email), .time = now, .tz = try formatTz(a, tz_offset_min) };
    if (getenv(env, try std.fmt.bufPrint(&kb, "GIT_{s}_DATE", .{up}))) |d| {
        const parsed = try parseDate(d);
        id.time = parsed.time;
        id.tz = try formatTz(a, parsed.tz_min);
    }
    return id;
}

/// "+0100" for 60.
pub fn formatTz(a: Allocator, min: i32) ![]const u8 {
    const sign: u8 = if (min < 0) '-' else '+';
    const m: u32 = @abs(min);
    return std.fmt.allocPrint(a, "{c}{d:0>2}{d:0>2}", .{ sign, m / 60, m % 60 });
}

pub const Date = struct { time: i64, tz_min: i32 };

/// git's raw date forms: "@1700000000 +0100", "1700000000 +0100",
/// "1700000000"; and ISO 8601 "2023-11-14T22:13:20+01:00" (or a space
/// for 'T', "Z", "+0100").
pub fn parseDate(text: []const u8) !Date {
    var t = std.mem.trim(u8, text, " ");
    if (t.len > 0 and t[0] == '@') t = t[1..];
    if (t.len > 0 and std.ascii.isDigit(t[0]) and (t.len < 5 or t[4] != '-')) {
        const sp = std.mem.indexOfScalar(u8, t, ' ');
        const secs = std.fmt.parseInt(i64, t[0 .. sp orelse t.len], 10) catch return error.InvalidDate;
        const tz: i32 = if (sp) |s| try parseTz(std.mem.trim(u8, t[s + 1 ..], " ")) else 0;
        return .{ .time = secs, .tz_min = tz };
    }
    // ISO 8601.
    if (t.len < 19) return error.InvalidDate;
    const y = std.fmt.parseInt(i32, t[0..4], 10) catch return error.InvalidDate;
    const mo = std.fmt.parseInt(u8, t[5..7], 10) catch return error.InvalidDate;
    const d = std.fmt.parseInt(u8, t[8..10], 10) catch return error.InvalidDate;
    const hh = std.fmt.parseInt(i64, t[11..13], 10) catch return error.InvalidDate;
    const mi = std.fmt.parseInt(i64, t[14..16], 10) catch return error.InvalidDate;
    const ss = std.fmt.parseInt(i64, t[17..19], 10) catch return error.InvalidDate;
    if (t[4] != '-' or t[7] != '-' or (t[10] != 'T' and t[10] != ' ') or t[13] != ':' or t[16] != ':') return error.InvalidDate;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return error.InvalidDate;
    const rest = std.mem.trim(u8, t[19..], " ");
    const tz: i32 = if (rest.len == 0 or std.mem.eql(u8, rest, "Z")) 0 else try parseTz(rest);
    const days = daysFromCivil(y, mo, d);
    return .{ .time = days * 86400 + hh * 3600 + mi * 60 + ss - @as(i64, tz) * 60, .tz_min = tz };
}

fn parseTz(s: []const u8) !i32 {
    if (s.len < 3 or (s[0] != '+' and s[0] != '-')) return error.InvalidDate;
    var digits: [4]u8 = undefined;
    var n: usize = 0;
    for (s[1..]) |c| {
        if (c == ':') continue;
        if (!std.ascii.isDigit(c) or n == 4) return error.InvalidDate;
        digits[n] = c;
        n += 1;
    }
    if (n != 4 and n != 2) return error.InvalidDate;
    const h = std.fmt.parseInt(i32, digits[0..2], 10) catch return error.InvalidDate;
    const m = if (n == 4) std.fmt.parseInt(i32, digits[2..4], 10) catch return error.InvalidDate else 0;
    const v = h * 60 + m;
    return if (s[0] == '-') -v else v;
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn daysFromCivil(y0: i32, m: u8, d: u8) i64 {
    const y: i64 = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// git's message cleanup (`git stripspace`, with `-s` for `.strip`).
pub fn cleanMessage(a: Allocator, msg: []const u8, mode: Cleanup, comment: u8) ![]const u8 {
    if (mode == .verbatim) return a.dupe(u8, msg);
    var out: std.ArrayList(u8) = .empty;
    var blank_pending = false;
    var it = std.mem.splitScalar(u8, msg, '\n');
    while (it.next()) |raw| {
        if (mode == .strip and raw.len > 0 and raw[0] == comment) continue;
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) {
            blank_pending = out.items.len > 0;
            continue;
        }
        if (blank_pending) try out.append(a, '\n');
        blank_pending = false;
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

const testing = std.testing;
const status_mod = @import("status.zig");

test "commit: message cleanup and dates" {
    const a = testing.allocator;
    const m = try cleanMessage(a, "\n\n  Subject  \n\n\n\nbody line   \n# comment\n\n", .strip, '#');
    defer a.free(m);
    try testing.expectEqualStrings("  Subject\n\nbody line\n", m);
    const w = try cleanMessage(a, "x\n# kept\n", .whitespace, '#');
    defer a.free(w);
    try testing.expectEqualStrings("x\n# kept\n", w);
    try testing.expectEqual(Date{ .time = 1700000000, .tz_min = 60 }, try parseDate("@1700000000 +0100"));
    try testing.expectEqual(Date{ .time = 1700000000, .tz_min = -330 }, try parseDate("1700000000 -0530"));
    try testing.expectEqual(Date{ .time = 1700000000, .tz_min = 60 }, try parseDate("2023-11-14T23:13:20+01:00"));
    try testing.expectEqual(Date{ .time = 1700000000, .tz_min = 0 }, try parseDate("2023-11-14 22:13:20Z"));
    try testing.expectError(error.InvalidDate, parseDate("yesterday"));
    const tz = try formatTz(a, -90);
    defer a.free(tz);
    try testing.expectEqualStrings("-0130", tz);
}

test "commit: initial, second, amend, empty and detached" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try stage.TestRepo.init(gpa, io);
    defer t.deinit(gpa);
    try t.env.put("GIT_AUTHOR_DATE", "@1700000000 +0100");
    try t.env.put("GIT_COMMITTER_DATE", "@1700000000 +0100");
    const d = t.tmp.dir;
    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "a\n" });
    _ = try stage.add(t.repo, &.{}, .{});
    var r1 = try commit(t.repo, .{ .message = "first", .env = &t.env });
    defer r1.deinit(gpa);
    try testing.expectEqualStrings("refs/heads/main", r1.ref);
    try testing.expectEqualStrings("commit (initial): first", r1.summary);
    // git 2.43 gives this id for the same tree, idents and dates.
    var hb: [64]u8 = undefined;
    try testing.expectEqualStrings("adc03a77aaee5a9a1bed291e4233c245c19ad3dc", r1.oid.hex(&hb));
    try testing.expectError(error.NothingToCommit, commit(t.repo, .{ .message = "again", .env = &t.env }));

    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "b\n" });
    var r2 = try commit(t.repo, .{ .message = "second", .all = true, .env = &t.env });
    defer r2.deinit(gpa);
    const s = try t.porcelain(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("", s);
    try testing.expect((try t.repo.head()).?.eql(r2.oid));

    var r3 = try commit(t.repo, .{ .message = "second, amended", .amend = true, .env = &t.env });
    defer r3.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const obj = try t.repo.odb.read(arena.allocator(), r3.oid);
    const c = try commit_mod.parseCommit(arena.allocator(), .sha1, obj.data);
    try testing.expectEqual(@as(usize, 1), c.parents.len);
    try testing.expect(c.parents[0].eql(r1.oid));
    try testing.expectEqualStrings("second, amended\n", c.message);

    var r4 = try commit(t.repo, .{ .message = "empty", .allow_empty = true, .env = &t.env });
    defer r4.deinit(gpa);
    try testing.expectError(error.EmptyMessage, commit(t.repo, .{ .message = " \n\n", .allow_empty = true, .env = &t.env }));

    // The reflog has every step.
    const log = try d.readFileAlloc(io, ".git/logs/HEAD", gpa, .limited(1 << 16));
    defer gpa.free(log);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, log, "\n"));
    try testing.expect(std.mem.indexOf(u8, log, "commit (amend): second, amended") != null);

    // Detached HEAD moves itself.
    var hex: [64]u8 = undefined;
    const detached = try std.fmt.allocPrint(gpa, "{s}\n", .{r4.oid.hex(&hex)});
    defer gpa.free(detached);
    try d.writeFile(io, .{ .sub_path = ".git/HEAD", .data = detached });
    var r5 = try commit(t.repo, .{ .message = "on detached", .allow_empty = true, .env = &t.env });
    defer r5.deinit(gpa);
    try testing.expectEqualStrings("HEAD", r5.ref);
    try testing.expect((try t.repo.head()).?.eql(r5.oid));

    // OpenPGP (the default gpg.format) is refused.
    try d.writeFile(io, .{ .sub_path = ".git/config", .data = "[commit]\n\tgpgsign = true\n" });
    try t.repo.reloadConfig(.{ .env = &t.env });
    try testing.expectError(error.SigningUnsupported, commit(t.repo, .{ .message = "x", .allow_empty = true, .env = &t.env }));
}

test "commit: identity from config, unknown identity" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try stage.TestRepo.init(gpa, io);
    defer t.deinit(gpa);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try testing.expectError(error.IdentityUnknown, commit(t.repo, .{ .message = "x", .allow_empty = true, .env = &env }));
    try t.tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[user]\n\tname = Cfg Name\n\temail = cfg@example.com\n" });
    try t.repo.reloadConfig(.{ .env = &t.env });
    var r = try commit(t.repo, .{ .message = "x", .allow_empty = true, .env = &env, .now = 1700000000, .tz_offset_min = 120 });
    defer r.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const obj = try t.repo.odb.read(arena.allocator(), r.oid);
    try testing.expect(std.mem.indexOf(u8, obj.data, "author Cfg Name <cfg@example.com> 1700000000 +0200\n") != null);
}
