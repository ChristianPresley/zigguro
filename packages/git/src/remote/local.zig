//! Remotes on this machine (`/path/repo`, `../repo`, `file://`), served
//! in-process (E09.F08): the other repository is opened directly and
//! answers as `git-upload-pack` (protocol v2 `ls-refs` and `fetch`) or
//! `git-receive-pack` (v0 commands, pack and `report-status`) would.
//! Like smart HTTP, each request is buffered and answered in full when
//! `endRequest` is called.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const transport = @import("transport.zig");
const protocol = @import("protocol.zig");
const objects = @import("objects.zig");
const pktline = @import("../proto/pktline.zig");
const Caps = @import("../proto/caps.zig").Caps;
const pack_writer = @import("../pack/writer.zig");
const indexer_mod = @import("../pack/indexer.zig");
const tag_mod = @import("../tag.zig");
const commit_cmd = @import("../commit_cmd.zig");
const refname = @import("../refs/refname.zig");
const Repository = @import("../repository.zig").Repository;
const Oid = @import("../oid.zig").Oid;
const PktWriter = pktline.PktWriter;
const PktReader = pktline.PktReader;

/// The repository directory a local URL names, absolute.
pub fn path(gpa: Allocator, base: []const u8, url: []const u8) ![]u8 {
    const p = if (std.mem.startsWith(u8, url, "file://")) url["file://".len..] else url;
    return std.fs.path.resolve(gpa, &.{ base, p });
}

/// Opens the repository at `dir`: a working tree, a bare repository, or
/// `dir.git`.
pub fn openRepository(gpa: Allocator, io: Io, dir: []const u8, env: ?*const std.process.Environ.Map) !*Repository {
    const dot = try std.fs.path.join(gpa, &.{ dir, ".git" });
    defer gpa.free(dot);
    if (Io.Dir.cwd().access(io, dot, .{})) |_| {
        return Repository.open(gpa, io, dir, dot, .{ .env = env }) catch |e| return e;
    } else |_| {}
    if (isGitDir(io, dir)) return Repository.open(gpa, io, dir, dir, .{ .env = env });
    if (!std.mem.endsWith(u8, dir, ".git")) {
        const with = try std.mem.concat(gpa, u8, &.{ dir, ".git" });
        defer gpa.free(with);
        if (isGitDir(io, with)) return Repository.open(gpa, io, with, with, .{ .env = env });
    }
    return error.NotARepository;
}

fn isGitDir(io: Io, dir: []const u8) bool {
    var d = Io.Dir.openDirAbsolute(io, dir, .{}) catch return false;
    defer d.close(io);
    d.access(io, "HEAD", .{}) catch return false;
    d.access(io, "objects", .{}) catch return false;
    d.access(io, "refs", .{}) catch return false;
    return true;
}

pub const Local = struct {
    gpa: Allocator,
    io: Io,
    server: *Repository,
    service: transport.Service,
    request: Io.Writer.Allocating,
    response: []u8 = &.{},
    rd: Io.Reader,

    pub fn connect(client: *Repository, url: []const u8, service: transport.Service) !*Local {
        const gpa = client.gpa;
        const dir = try path(gpa, client.root, url);
        defer gpa.free(dir);
        const l = try gpa.create(Local);
        errdefer gpa.destroy(l);
        const server = try openRepository(gpa, client.io, dir, client.env);
        errdefer server.close();
        l.* = .{ .gpa = gpa, .io = client.io, .server = server, .service = service, .request = .init(gpa), .rd = .fixed("") };
        errdefer l.request.deinit();
        try l.respond(switch (service) {
            .upload_pack => advertiseUpload,
            .receive_pack => advertiseReceive,
        });
        return l;
    }

    pub fn connection(l: *Local) transport.Connection {
        return .{ .ptr = l, .vtable = &.{ .reader = reader, .writer = writer, .end_request = endRequest, .close = close } };
    }

    fn reader(ptr: *anyopaque) *Io.Reader {
        const l: *Local = @ptrCast(@alignCast(ptr));
        return &l.rd;
    }

    fn writer(ptr: *anyopaque) *Io.Writer {
        const l: *Local = @ptrCast(@alignCast(ptr));
        return &l.request.writer;
    }

    fn endRequest(ptr: *anyopaque) anyerror!void {
        const l: *Local = @ptrCast(@alignCast(ptr));
        try l.respond(switch (l.service) {
            .upload_pack => serveUpload,
            .receive_pack => serveReceive,
        });
    }

    fn close(ptr: *anyopaque) void {
        const l: *Local = @ptrCast(@alignCast(ptr));
        l.server.close();
        l.request.deinit();
        l.gpa.free(l.response);
        l.gpa.destroy(l);
    }

    /// Runs a handler over the buffered request; its output becomes
    /// what the reader returns next.
    fn respond(l: *Local, handler: *const fn (l: *Local, a: Allocator, req: []const u8, out: *Io.Writer) anyerror!void) !void {
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        var out: Io.Writer.Allocating = .init(l.gpa);
        errdefer out.deinit();
        const written = l.request.written();
        const req_buf = try arena.allocator().alloc(u8, @max(written.len, transport.read_buffer_len));
        @memcpy(req_buf[0..written.len], written);
        const req = req_buf[0..written.len];
        l.request.clearRetainingCapacity();
        try handler(l, arena.allocator(), req, &out.writer);
        // Pkt-line readers want a buffer that can hold any packet.
        const body = out.written();
        const buf = try l.gpa.alloc(u8, @max(body.len, transport.read_buffer_len));
        @memcpy(buf[0..body.len], body);
        out.deinit();
        l.gpa.free(l.response);
        l.response = buf;
        l.rd = .fixed(buf);
        l.rd.end = body.len;
    }
};

/// A reader over a request from `respond`, whose allocation is at least
/// `read_buffer_len` long as pkt-line readers need.
fn requestReader(req: []const u8) Io.Reader {
    var r: Io.Reader = .fixed(req.ptr[0..@max(req.len, transport.read_buffer_len)]);
    r.end = req.len;
    return r;
}

// ---- upload-pack ----

fn advertiseUpload(l: *Local, _: Allocator, _: []const u8, out: *Io.Writer) anyerror!void {
    const pw: PktWriter = .init(out);
    try pw.line("version 2", .{});
    try pw.line("agent={s}", .{protocol.agent});
    try pw.line("ls-refs=unborn", .{});
    try pw.line("fetch", .{});
    try pw.line("object-format={s}", .{l.server.format.name()});
    try pw.flush();
}

const Request = struct {
    command: []const u8 = "",
    args: std.ArrayList([]const u8) = .empty,
};

fn parseRequest(a: Allocator, req: []const u8) !?Request {
    var r = requestReader(req);
    var pr: PktReader = .init(&r);
    var out: Request = .{};
    var in_args = false;
    while (true) {
        const p = (try pr.next()) orelse return if (out.command.len == 0) null else out;
        switch (p) {
            .data => |d| {
                const line = pktline.trimLf(d);
                if (in_args) {
                    try out.args.append(a, try a.dupe(u8, line));
                } else if (std.mem.startsWith(u8, line, "command=")) out.command = try a.dupe(u8, line["command=".len..]);
            },
            .delim => in_args = true,
            .flush => return if (out.command.len == 0) null else out,
            else => {},
        }
    }
}

fn serveUpload(l: *Local, a: Allocator, req: []const u8, out: *Io.Writer) anyerror!void {
    // A lone flush ends the session.
    const r = (try parseRequest(a, req)) orelse return;
    if (std.mem.eql(u8, r.command, "ls-refs")) return lsRefs(l, a, r.args.items, out);
    if (std.mem.eql(u8, r.command, "fetch")) return fetch(l, a, r.args.items, out);
    const pw: PktWriter = .init(out);
    try pw.line("ERR unknown command {s}", .{r.command});
}

fn peel(repo: *Repository, a: Allocator, id: Oid) !?Oid {
    var t = id;
    var peeled = false;
    while (true) {
        const obj = repo.odb.read(a, t) catch return null;
        if (obj.type != .tag) return if (peeled) t else null;
        t = (try tag_mod.parseTag(a, repo.format, obj.data)).object;
        peeled = true;
    }
}

fn lsRefs(l: *Local, a: Allocator, args: []const []const u8, out: *Io.Writer) !void {
    const repo = l.server;
    var want_peel = false;
    var want_symrefs = false;
    var want_unborn = false;
    var prefixes: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "peel")) want_peel = true else if (std.mem.eql(u8, arg, "symrefs")) want_symrefs = true else if (std.mem.eql(u8, arg, "unborn")) want_unborn = true else if (std.mem.startsWith(u8, arg, "ref-prefix ")) try prefixes.append(a, arg["ref-prefix ".len..]);
    }
    const pw: PktWriter = .init(out);
    var hb: [64]u8 = undefined;
    var pb: [64]u8 = undefined;
    const wanted = struct {
        fn f(ps: []const []const u8, name: []const u8) bool {
            if (ps.len == 0) return true;
            for (ps) |p| if (std.mem.startsWith(u8, name, p)) return true;
            return false;
        }
    }.f;
    if (wanted(prefixes.items, "HEAD")) {
        const target = (try repo.headRef(a));
        if (try repo.head()) |h| {
            if (want_symrefs and target != null) try pw.line("{s} HEAD symref-target:{s}", .{ h.hex(&hb), target.? }) else try pw.line("{s} HEAD", .{h.hex(&hb)});
        } else if (want_unborn and target != null) try pw.line("unborn HEAD symref-target:{s}", .{target.?});
    }
    var list = try repo.refs.iterate(a, "refs/");
    defer list.deinit();
    for (list.refs) |ref| {
        if (!wanted(prefixes.items, ref.name)) continue;
        const id = switch (ref.value) {
            .direct => |d| d,
            .symbolic => (try repo.refs.resolve(ref.name)) orelse continue,
        };
        var line: std.ArrayList(u8) = .empty;
        try line.print(a, "{s} {s}", .{ id.hex(&hb), ref.name });
        if (want_symrefs) switch (ref.value) {
            .symbolic => |t| try line.print(a, " symref-target:{s}", .{t}),
            else => {},
        };
        if (want_peel) if (try peel(repo, a, id)) |p| try line.print(a, " peeled:{s}", .{p.hex(&pb)});
        try pw.data(line.items);
    }
    try pw.flush();
}

fn bandWrite(pw: PktWriter, band: u8, bytes: []const u8) !void {
    var buf: [65520]u8 = undefined;
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, 65515);
        buf[0] = band;
        @memcpy(buf[1..][0..n], rest[0..n]);
        try pw.data(buf[0 .. n + 1]);
        rest = rest[n..];
    }
}

fn fetch(l: *Local, a: Allocator, args: []const []const u8, out: *Io.Writer) !void {
    const repo = l.server;
    var wants: std.ArrayList(Oid) = .empty;
    var haves: std.ArrayList(Oid) = .empty;
    var done = false;
    var thin = false;
    var ofs = false;
    var include_tag = false;
    const pw: PktWriter = .init(out);
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "want ")) {
            const id = Oid.parseHex(repo.format, arg[5..]) catch return pw.line("ERR bad want", .{});
            if (!repo.odb.exists(id)) return pw.line("ERR upload-pack: not our ref {s}", .{arg[5..]});
            try wants.append(a, id);
        } else if (std.mem.startsWith(u8, arg, "have ")) {
            const id = Oid.parseHex(repo.format, arg[5..]) catch continue;
            if (repo.odb.exists(id)) try haves.append(a, id);
        } else if (std.mem.eql(u8, arg, "done")) done = true else if (std.mem.eql(u8, arg, "thin-pack")) thin = true else if (std.mem.eql(u8, arg, "ofs-delta")) ofs = true else if (std.mem.eql(u8, arg, "include-tag")) include_tag = true else if (std.mem.startsWith(u8, arg, "deepen") or std.mem.startsWith(u8, arg, "shallow ") or std.mem.startsWith(u8, arg, "filter "))
            return pw.line("ERR shallow and partial clones are not supported", .{});
    }
    var hb: [64]u8 = undefined;
    if (!done) {
        // Always ready: what the client has decides what is left out.
        try pw.line("acknowledgments", .{});
        if (haves.items.len == 0) try pw.line("NAK", .{});
        for (haves.items) |h| try pw.line("ACK {s}", .{h.hex(&hb)});
        try pw.line("ready", .{});
        try pw.delim();
    }
    try pw.line("packfile", .{});

    const p = try objects.plan(repo, a, wants.items, haves.items);
    var w: pack_writer.PackWriter = .init(repo.gpa, repo.odb, repo.format);
    defer w.deinit();
    var sent: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    for (p.send) |it| {
        try w.add(it.id, .{ .path = it.path });
        try sent.put(a, it.id, {});
    }
    if (include_tag) {
        // Annotated tags whose target is being sent go along.
        var list = try repo.refs.iterate(a, "refs/tags/");
        defer list.deinit();
        for (list.refs) |ref| {
            const id = switch (ref.value) {
                .direct => |d| d,
                else => continue,
            };
            if (sent.contains(id)) continue;
            const obj = repo.odb.read(a, id) catch continue;
            if (obj.type != .tag) continue;
            const target = (try tag_mod.parseTag(a, repo.format, obj.data)).object;
            if (!sent.contains(target)) continue;
            try w.add(id, .{ .path = "" });
            try sent.put(a, id, {});
        }
    }
    var pack: Io.Writer.Allocating = .init(a);
    _ = try w.finish(&pack.writer, .{ .thin_bases = if (thin) p.thin_bases else &.{}, .ofs_delta = ofs });
    try bandWrite(pw, 1, pack.written());
    try pw.flush();
}

// ---- receive-pack ----

const receive_caps = "report-status delete-refs side-band-64k quiet atomic ofs-delta";

fn advertiseReceive(l: *Local, a: Allocator, _: []const u8, out: *Io.Writer) anyerror!void {
    const repo = l.server;
    const pw: PktWriter = .init(out);
    var hb: [64]u8 = undefined;
    const caps = try std.fmt.allocPrint(a, "{s} object-format={s} agent={s}", .{ receive_caps, repo.format.name(), protocol.agent });
    var first = true;
    var list = try repo.refs.iterate(a, "refs/");
    defer list.deinit();
    for (list.refs) |ref| {
        const id = switch (ref.value) {
            .direct => |d| d,
            .symbolic => continue,
        };
        if (first) try pw.line("{s} {s}\x00{s}", .{ id.hex(&hb), ref.name, caps }) else try pw.line("{s} {s}", .{ id.hex(&hb), ref.name });
        first = false;
    }
    if (first) try pw.line("{s} capabilities^{{}}\x00{s}", .{ Oid.zero(repo.format).hex(&hb), caps });
    try pw.flush();
}

fn serveReceive(l: *Local, a: Allocator, req: []const u8, out: *Io.Writer) anyerror!void {
    const repo = l.server;
    var r = requestReader(req);
    var pr: PktReader = .init(&r);
    const Cmd = struct { old: Oid, new: Oid, ref: []const u8, err: ?[]const u8 = null };
    var cmds: std.ArrayList(Cmd) = .empty;
    var caps: Caps = Caps.parseV0("");
    while (pr.nextLine() catch null) |line| {
        var l2 = line;
        if (std.mem.indexOfScalar(u8, line, 0)) |z| {
            caps = Caps.parseV0(try a.dupe(u8, line));
            l2 = line[0..z];
        }
        var it = std.mem.tokenizeScalar(u8, l2, ' ');
        const old = Oid.parseHex(repo.format, it.next() orelse return error.BadCommand) catch return error.BadCommand;
        const new = Oid.parseHex(repo.format, it.next() orelse return error.BadCommand) catch return error.BadCommand;
        try cmds.append(a, .{ .old = old, .new = new, .ref = try a.dupe(u8, it.next() orelse return error.BadCommand) });
    }
    if (cmds.items.len == 0) return;

    // The pack follows the commands.
    var unpack_err: ?[]const u8 = null;
    const pack = r.buffered();
    var any_new = false;
    for (cmds.items) |c| any_new = any_new or !c.new.isZero();
    // A pack with no objects (the new tips are already here) is skipped.
    const empty = pack.len >= 12 and std.mem.readInt(u32, pack[8..12], .big) == 0;
    if (any_new and pack.len > 0 and !empty) {
        const ix = try indexer_mod.Indexer.init(repo.gpa, repo.io, repo.odb, repo.format, .{});
        defer ix.deinit();
        ix.writer().writeAll(pack) catch {
            unpack_err = "index-pack failed";
        };
        if (unpack_err == null) {
            if (ix.finish(null)) |_| try repo.odb.rescan() else |_| unpack_err = "index-pack failed";
        }
    }

    const bare = repo.config.getBool("core.bare") orelse false;
    const current = try repo.headRef(a);
    for (cmds.items) |*c| {
        if (unpack_err != null) {
            c.err = "unpacker error";
            continue;
        }
        if (!std.mem.startsWith(u8, c.ref, "refs/") or !refname.checkRefFormat(c.ref, .{})) {
            c.err = "funny refname";
            continue;
        }
        if (!bare and current != null and std.mem.eql(u8, current.?, c.ref)) {
            c.err = "branch is currently checked out";
            continue;
        }
        if (!c.new.isZero() and !repo.odb.exists(c.new)) {
            c.err = "missing necessary objects";
            continue;
        }
        const have = try repo.refs.resolve(c.ref);
        const matches = if (have) |h| h.eql(c.old) else c.old.isZero();
        if (!matches) c.err = "failed to lock";
    }
    const atomic = caps.has("atomic");
    var failed = false;
    for (cmds.items) |c| failed = failed or c.err != null;
    if (atomic and failed) {
        for (cmds.items) |*c| if (c.err == null) {
            c.err = "atomic transaction failed";
        };
    }
    if (!atomic or !failed) {
        const now: i64 = @intCast(@divFloor(Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s));
        const who = commit_cmd.ident(repo, a, repo.envMap(), .committer, now, 0) catch @import("../commit.zig").Ident{ .name = "zigguro", .email = "", .time = now, .tz = "+0000" };
        var tx = repo.refs.transaction();
        defer tx.deinit();
        var n: usize = 0;
        for (cmds.items) |c| {
            if (c.err != null) continue;
            const expect: @import("../refs/transaction.zig").Expect = if (c.old.isZero()) .absent else .{ .oid = c.old };
            if (c.new.isZero()) try tx.delete(c.ref, expect, "push") else try tx.update(c.ref, .{ .direct = c.new }, expect, "push", who);
            n += 1;
        }
        if (n > 0) tx.commit() catch {
            for (cmds.items) |*c| if (c.err == null) {
                c.err = "failed to update ref";
            };
        };
    }

    if (!caps.has("report-status")) return;
    var rep: Io.Writer.Allocating = .init(a);
    const rpw: PktWriter = .init(&rep.writer);
    if (unpack_err) |e| try rpw.line("unpack {s}", .{e}) else try rpw.line("unpack ok", .{});
    for (cmds.items) |c| {
        if (c.err) |e| try rpw.line("ng {s} {s}", .{ c.ref, e }) else try rpw.line("ok {s}", .{c.ref});
    }
    try rpw.flush();
    const pw: PktWriter = .init(out);
    if (caps.has("side-band-64k")) {
        try bandWrite(pw, 1, rep.written());
        try pw.flush();
    } else try out.writeAll(rep.written());
}
