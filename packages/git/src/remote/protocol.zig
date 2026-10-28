//! The git wire protocol, client side (E09.F08): the server's
//! advertisement, protocol v2 `ls-refs` and `fetch` (with want/have
//! negotiation and a sidebanded pack), and v0 `receive-pack` for push
//! (commands, pack, `report-status`).

const std = @import("std");
const pktline = @import("../proto/pktline.zig");
const sideband = @import("../proto/sideband.zig");
const Caps = @import("../proto/caps.zig").Caps;
const transport = @import("transport.zig");
const indexer_mod = @import("../pack/indexer.zig");
const commit_mod = @import("../commit.zig");
const oid_mod = @import("../oid.zig");
const Repository = @import("../repository.zig").Repository;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Connection = transport.Connection;
const PktReader = pktline.PktReader;
const PktWriter = pktline.PktWriter;
const Allocator = std.mem.Allocator;

pub const agent = "zigguro/0.1";

pub const RemoteRef = struct {
    name: []const u8,
    oid: Oid,
    /// The target of a symbolic ref (`HEAD` -> `refs/heads/main`).
    symref: ?[]const u8 = null,
    /// What an annotated tag points at.
    peeled: ?Oid = null,
    /// `HEAD` of an empty repository: `symref` names the unborn branch.
    unborn: bool = false,
};

pub const Advertisement = struct {
    version: u8,
    caps: Caps,
    /// v0 only: the advertised refs.
    refs: []const RemoteRef = &.{},
    format: ObjectFormat = .sha1,
};

/// Reads the server's first response. Strings live in `a`.
pub fn readAdvertisement(a: Allocator, conn: Connection) !Advertisement {
    var pr: PktReader = .init(conn.reader());
    const first = (try pr.nextLine()) orelse return error.EmptyAdvertisement;
    if (std.mem.eql(u8, first, "version 2")) {
        var lines: std.ArrayList([]const u8) = .empty;
        while (try pr.nextLine()) |l| try lines.append(a, try a.dupe(u8, l));
        const caps = Caps.parseV2(lines.items);
        const fmt = if (caps.value("object-format")) |f| ObjectFormat.fromName(f) orelse return error.UnknownObjectFormat else .sha1;
        return .{ .version = 2, .caps = caps, .format = fmt };
    }
    if (std.mem.startsWith(u8, first, "ERR ")) return error.RemoteError;
    // v0/v1: "version 1" may come first, then refs, the first with caps.
    var line = first;
    if (std.mem.eql(u8, line, "version 1")) line = (try pr.nextLine()) orelse return error.EmptyAdvertisement;
    const caps_line = try a.dupe(u8, line);
    const caps = Caps.parseV0(caps_line);
    const fmt = if (caps.value("object-format")) |f| ObjectFormat.fromName(f) orelse return error.UnknownObjectFormat else .sha1;
    var refs: std.ArrayList(RemoteRef) = .empty;
    var cur: ?[]const u8 = Caps.refPartV0(caps_line);
    while (cur) |l| : (cur = try pr.nextLine()) {
        if (std.mem.startsWith(u8, l, "shallow ")) continue;
        const sp = std.mem.indexOfScalar(u8, l, ' ') orelse return error.BadAdvertisement;
        const id = Oid.parseHex(fmt, l[0..sp]) catch return error.BadAdvertisement;
        const name = l[sp + 1 ..];
        if (std.mem.eql(u8, name, "capabilities^{}")) continue;
        if (std.mem.endsWith(u8, name, "^{}")) {
            if (refs.items.len > 0) refs.items[refs.items.len - 1].peeled = id;
            continue;
        }
        try refs.append(a, .{ .name = try a.dupe(u8, name), .oid = id });
    }
    // symref=HEAD:refs/heads/main
    var it = caps.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.name, "symref")) continue;
        const v = e.value orelse continue;
        const colon = std.mem.indexOfScalar(u8, v, ':') orelse continue;
        for (refs.items) |*r| if (std.mem.eql(u8, r.name, v[0..colon])) {
            r.symref = v[colon + 1 ..];
        };
    }
    return .{ .version = 0, .caps = caps, .refs = refs.items, .format = fmt };
}

fn header(pw: PktWriter, adv: *const Advertisement, command: []const u8) !void {
    try pw.line("command={s}", .{command});
    if (adv.caps.has("agent")) try pw.line("agent={s}", .{agent});
    if (adv.caps.value("object-format") != null) try pw.line("object-format={s}", .{adv.format.name()});
    try pw.delim();
}

/// Protocol v2 `ls-refs`: the server's refs under `prefixes` (all when
/// empty), with symref targets and peeled tags.
pub fn lsRefs(a: Allocator, conn: Connection, adv: *const Advertisement, prefixes: []const []const u8) ![]RemoteRef {
    if (adv.version != 2) return a.dupe(RemoteRef, adv.refs);
    const pw: PktWriter = .init(conn.writer());
    try header(pw, adv, "ls-refs");
    try pw.line("peel", .{});
    try pw.line("symrefs", .{});
    if (adv.caps.hasFeature("ls-refs", "unborn")) try pw.line("unborn", .{});
    for (prefixes) |p| try pw.line("ref-prefix {s}", .{p});
    try pw.flush();
    try conn.endRequest();
    var pr: PktReader = .init(conn.reader());
    var out: std.ArrayList(RemoteRef) = .empty;
    while (try pr.nextLine()) |l| {
        var words = std.mem.tokenizeScalar(u8, l, ' ');
        const first = words.next() orelse return error.BadLsRefs;
        const name = words.next() orelse return error.BadLsRefs;
        var r: RemoteRef = .{ .name = try a.dupe(u8, name), .oid = Oid.zero(adv.format) };
        if (std.mem.eql(u8, first, "unborn")) r.unborn = true else r.oid = Oid.parseHex(adv.format, first) catch return error.BadLsRefs;
        while (words.next()) |attr| {
            if (std.mem.startsWith(u8, attr, "symref-target:")) r.symref = try a.dupe(u8, attr["symref-target:".len..]);
            if (std.mem.startsWith(u8, attr, "peeled:")) r.peeled = Oid.parseHex(adv.format, attr["peeled:".len..]) catch return error.BadLsRefs;
        }
        try out.append(a, r);
    }
    return out.items;
}

/// Ends a protocol v2 session politely (a flush), so the server exits
/// without complaining that the client hung up.
pub fn endSession(conn: Connection, adv: *const Advertisement) void {
    if (adv.version != 2) return;
    const pw: PktWriter = .init(conn.writer());
    pw.flush() catch return;
    conn.endRequest() catch {};
}

pub const FetchOptions = struct {
    on_progress: ?sideband.ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
    /// Ask for tag objects pointing at what is sent (auto-following tags).
    include_tag: bool = true,
    /// Commits to offer as "have" before giving up on finding more
    /// common history.
    max_haves: usize = 256,
};

/// Protocol v2 `fetch`: negotiates with the local history and stores
/// the pack the server sends. Null when there is nothing to fetch.
pub fn fetchPack(repo: *Repository, a: Allocator, conn: Connection, adv: *const Advertisement, wants: []const Oid, opts: FetchOptions) !?indexer_mod.IndexedPack {
    if (adv.version != 2) return error.ProtocolV0FetchUnsupported;
    if (!adv.caps.has("fetch")) return error.FetchUnsupported;
    if (wants.len == 0) return null;
    var neg = try Negotiator.init(repo, a);
    var round: usize = 0;
    var batch: usize = 16;
    var sent: usize = 0;
    var done = false;
    while (true) : (round += 1) {
        const pw: PktWriter = .init(conn.writer());
        try header(pw, adv, "fetch");
        try pw.line("thin-pack", .{});
        try pw.line("ofs-delta", .{});
        if (opts.include_tag) try pw.line("include-tag", .{});
        if (opts.on_progress == null) try pw.line("no-progress", .{});
        var hb: [64]u8 = undefined;
        for (wants) |w| try pw.line("want {s}", .{w.hex(&hb)});
        // In stateless mode the server forgets: repeat what is common.
        for (neg.common.items) |c| try pw.line("have {s}", .{c.hex(&hb)});
        var in_round: usize = 0;
        while (in_round < batch) : (in_round += 1) {
            const h = try neg.next() orelse break;
            try pw.line("have {s}", .{h.hex(&hb)});
            sent += 1;
        }
        if (in_round == 0 or sent >= opts.max_haves) done = true;
        if (done) try pw.line("done", .{});
        try pw.flush();
        try conn.endRequest();

        var pr: PktReader = .init(conn.reader());
        var ready = false;
        // Sections until "packfile" (or the end of the acknowledgments).
        while (true) {
            const sec = (try pr.nextLine()) orelse return error.UnexpectedFlush;
            if (std.mem.eql(u8, sec, "packfile")) return try receivePack(repo, &pr, opts);
            if (std.mem.eql(u8, sec, "acknowledgments")) {
                const end = try readAcks(&pr, &neg, adv.format, &ready);
                if (end == .flush) break;
                continue;
            }
            // shallow-info, wanted-refs, packfile-uris: skip to the delimiter.
            while (true) {
                const p = try pr.next() orelse return error.UnexpectedEof;
                if (p != .data) break;
            }
        }
        if (ready) done = true;
        if (batch < 128) batch *= 2;
    }
}

fn readAcks(pr: *PktReader, neg: *Negotiator, fmt: ObjectFormat, ready: *bool) !pktline.Pkt {
    while (true) {
        const p = try pr.next() orelse return error.UnexpectedEof;
        switch (p) {
            .data => |d| {
                const l = pktline.trimLf(d);
                if (std.mem.startsWith(u8, l, "ACK ")) {
                    try neg.ack(Oid.parseHex(fmt, l[4..]) catch return error.BadAck);
                } else if (std.mem.eql(u8, l, "ready")) ready.* = true;
            },
            else => return p,
        }
    }
}

fn receivePack(repo: *Repository, pr: *PktReader, opts: FetchOptions) !indexer_mod.IndexedPack {
    var sb: sideband.Sideband = .init(pr, .all);
    sb.on_progress = opts.on_progress;
    sb.progress_ctx = opts.progress_ctx;
    var buf: [64 * 1024]u8 = undefined;
    const r = sb.reader(&buf);
    const ix = try indexer_mod.Indexer.init(repo.gpa, repo.io, repo.odb, repo.format, .{});
    defer ix.deinit();
    _ = r.streamRemaining(ix.writer()) catch |e| switch (e) {
        error.ReadFailed => return sb.err orelse error.ReadFailed,
        else => return e,
    };
    const packed_ = try ix.finish(null);
    try repo.odb.rescan();
    return packed_;
}

/// Offers local commits newest first, skipping the history of commits
/// the server acknowledged.
const Negotiator = struct {
    repo: *Repository,
    a: Allocator,
    queue: std.PriorityQueue(Item, void, newer) = .empty,
    seen: std.AutoHashMapUnmanaged(Oid, void) = .empty,
    common_set: std.AutoHashMapUnmanaged(Oid, void) = .empty,
    common: std.ArrayList(Oid) = .empty,

    const Item = struct { id: Oid, time: i64 };

    fn newer(_: void, x: Item, y: Item) std.math.Order {
        return std.math.order(y.time, x.time);
    }

    fn init(repo: *Repository, a: Allocator) !Negotiator {
        var n: Negotiator = .{ .repo = repo, .a = a };
        var refs = try repo.refs.iterate(repo.gpa, "refs/");
        defer refs.deinit();
        for (refs.refs) |r| switch (r.value) {
            .direct => |id| try n.push(id),
            .symbolic => {},
        };
        if (try repo.head()) |h| try n.push(h);
        return n;
    }

    fn push(n: *Negotiator, id0: Oid) !void {
        // Peel tags to commits; skip what is not a commit.
        var id = id0;
        while (true) {
            const obj = n.repo.odb.read(n.a, id) catch return;
            switch (obj.type) {
                .commit => {
                    if ((try n.seen.getOrPut(n.a, id)).found_existing) return;
                    const c = try commit_mod.parseCommit(n.a, n.repo.format, obj.data);
                    try n.queue.push(n.a, .{ .id = id, .time = c.committer.time });
                    return;
                },
                .tag => id = (try @import("../tag.zig").parseTag(n.a, n.repo.format, obj.data)).object,
                else => return,
            }
        }
    }

    fn next(n: *Negotiator) !?Oid {
        while (n.queue.pop()) |it| {
            const obj = try n.repo.odb.read(n.a, it.id);
            const c = try commit_mod.parseCommit(n.a, n.repo.format, obj.data);
            const is_common = n.common_set.contains(it.id);
            for (c.parents) |p| {
                if (is_common) try n.common_set.put(n.a, p, {});
                try n.push(p);
            }
            if (!is_common) return it.id;
        }
        return null;
    }

    /// Marks `id` common; its parents are then common too, so walking
    /// stops below it.
    fn ack(n: *Negotiator, id: Oid) !void {
        try n.common.append(n.a, id);
        try n.common_set.put(n.a, id, {});
        const obj = n.repo.odb.read(n.a, id) catch return;
        if (obj.type != .commit) return;
        const c = try commit_mod.parseCommit(n.a, n.repo.format, obj.data);
        for (c.parents) |p| try n.common_set.put(n.a, p, {});
    }
};

pub const Command = struct {
    ref: []const u8,
    old: Oid,
    new: Oid,
};

pub const RefStatus = struct {
    ref: []const u8,
    /// null: updated; otherwise the server's reason ("non-fast-forward").
    err: ?[]const u8,
};

pub const PushReport = struct {
    unpack_ok: bool,
    unpack_msg: []const u8,
    refs: []const RefStatus,
};

/// v0 `receive-pack`: sends `commands` and `pack` (the bytes of a pack,
/// empty when only deleting), then reads `report-status`.
pub fn sendPack(a: Allocator, conn: Connection, adv: *const Advertisement, commands: []const Command, pack: []const u8, on_progress: ?sideband.ProgressFn, ctx: ?*anyopaque) !PushReport {
    if (adv.version != 0) return error.UnexpectedProtocol;
    const report = adv.caps.has("report-status");
    const band = adv.caps.has("side-band-64k");
    const pw: PktWriter = .init(conn.writer());
    var hb: [64]u8 = undefined;
    var hb2: [64]u8 = undefined;
    for (commands, 0..) |c, i| {
        if (i == 0) {
            var caps: std.ArrayList(u8) = .empty;
            if (report) try caps.appendSlice(a, " report-status");
            if (band) try caps.appendSlice(a, " side-band-64k");
            if (adv.caps.has("quiet") and on_progress == null) try caps.appendSlice(a, " quiet");
            if (adv.caps.has("object-format")) try caps.print(a, " object-format={s}", .{adv.format.name()});
            if (adv.caps.has("agent")) try caps.print(a, " agent={s}", .{agent});
            try pw.line("{s} {s} {s}\x00{s}", .{ c.old.hex(&hb), c.new.hex(&hb2), c.ref, std.mem.trimStart(u8, caps.items, " ") });
        } else try pw.line("{s} {s} {s}", .{ c.old.hex(&hb), c.new.hex(&hb2), c.ref });
    }
    try pw.flush();
    try conn.writer().writeAll(pack);
    try conn.endRequest();
    if (!report) return .{ .unpack_ok = true, .unpack_msg = "", .refs = &.{} };

    var pr: PktReader = .init(conn.reader());
    var text: std.ArrayList(u8) = .empty;
    if (band) {
        var sb: sideband.Sideband = .init(&pr, .band64k);
        sb.on_progress = on_progress;
        sb.progress_ctx = ctx;
        while (sb.nextData() catch |e| return if (e == error.RemoteError) error.RemoteError else e) |d| try text.appendSlice(a, d);
    } else {
        // Unbanded: the report's pkt-lines until a flush.
        var w: std.Io.Writer.Allocating = .init(a);
        const pw2: PktWriter = .init(&w.writer);
        while (try pr.nextLine()) |l| try pw2.line("{s}", .{l});
        try pw2.flush();
        try text.appendSlice(a, w.written());
    }
    // The report is itself pkt-lines inside band 1.
    var fixed: std.Io.Reader = .fixed(text.items);
    // A fixed reader holds the whole text, so `init`'s buffer check does
    // not apply.
    var inner: PktReader = .{ .r = &fixed };
    const unpack = (try inner.nextLine()) orelse return error.BadReport;
    if (!std.mem.startsWith(u8, unpack, "unpack ")) return error.BadReport;
    const msg = try a.dupe(u8, unpack["unpack ".len..]);
    var refs: std.ArrayList(RefStatus) = .empty;
    while (try inner.nextLine()) |l| {
        if (std.mem.startsWith(u8, l, "ok ")) {
            try refs.append(a, .{ .ref = try a.dupe(u8, l[3..]), .err = null });
        } else if (std.mem.startsWith(u8, l, "ng ")) {
            const rest = l[3..];
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            try refs.append(a, .{ .ref = try a.dupe(u8, rest[0..sp]), .err = try a.dupe(u8, if (sp < rest.len) rest[sp + 1 ..] else "failed") });
        }
    }
    return .{ .unpack_ok = std.mem.eql(u8, msg, "ok"), .unpack_msg = msg, .refs = refs.items };
}
