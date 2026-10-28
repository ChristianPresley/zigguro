//! Smart HTTP(S) transport (E09.F08.S01, gitprotocol-http): the
//! advertisement from `GET <url>/info/refs?service=<service>`, then each
//! request as a `POST <url>/<service>` (stateless). Response bodies go
//! to a temporary file so a large pack never has to fit in memory. A 401
//! runs the credential pipeline and retries with Basic auth, approving or
//! rejecting the credential by the result.

const std = @import("std");
const zg_net = @import("zg_net");
const transport = @import("transport.zig");
const credential = @import("credential.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    client: *zg_net.http.Client,
    /// Where 401s get credentials (copied into the connection).
    credentials: ?credential.Pipeline = null,
    /// Where response bodies are spooled (e.g. `$GIT_DIR`).
    tmp_dir: Io.Dir,
};

pub const Http = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    opts: Options,
    service: transport.Service,
    /// The repository URL without userinfo or a trailing slash.
    base: []const u8,
    cred: credential.Credential,
    auth: ?[]const u8 = null,
    approved: bool = false,
    request: Io.Writer.Allocating,
    tmp_name: [32]u8 = undefined,
    file: ?Io.File = null,
    rbuf: []u8,
    file_reader: Io.File.Reader = undefined,

    pub fn connect(gpa: Allocator, io: Io, url: []const u8, service: transport.Service, opts: Options) !*Http {
        const h = try gpa.create(Http);
        const rbuf = gpa.alloc(u8, transport.read_buffer_len) catch |e| {
            gpa.destroy(h);
            return e;
        };
        h.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .opts = opts,
            .service = service,
            .base = undefined,
            .cred = undefined,
            .request = .init(gpa),
            .rbuf = rbuf,
        };
        errdefer h.deinit();
        const a = h.arena.allocator();
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        var hb: [256]u8 = undefined;
        const host = (uri.host orelse return error.InvalidUrl).toRaw(&hb) catch return error.InvalidUrl;
        h.cred = .{
            .protocol = try a.dupe(u8, uri.scheme),
            .host = if (uri.port) |p| try std.fmt.allocPrint(a, "{s}:{d}", .{ host, p }) else try a.dupe(u8, host),
            .path = std.mem.trim(u8, try (uri.path).toRawMaybeAlloc(a), "/"),
            .username = if (uri.user) |u| try a.dupe(u8, try u.toRawMaybeAlloc(a)) else null,
            .password = if (uri.password) |p| try a.dupe(u8, try p.toRawMaybeAlloc(a)) else null,
        };
        var no_user = uri;
        no_user.user = null;
        no_user.password = null;
        var bw: Io.Writer.Allocating = .init(a);
        try no_user.format(&bw.writer);
        h.base = std.mem.trimEnd(u8, bw.written(), "/");
        if (h.cred.complete()) try h.setAuth();
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        _ = std.fmt.bufPrint(&h.tmp_name, "tmp_http_{x}", .{rnd}) catch unreachable;

        const adv_url = try std.fmt.allocPrint(a, "{s}/info/refs?service={s}", .{ h.base, service.name() });
        try h.perform(.GET, adv_url, null);
        try h.skipServiceLine();
        return h;
    }

    pub fn connection(h: *Http) transport.Connection {
        return .{ .ptr = h, .vtable = &.{ .reader = reader, .writer = writer, .end_request = endRequest, .close = close } };
    }

    fn reader(ptr: *anyopaque) *Io.Reader {
        const h: *Http = @ptrCast(@alignCast(ptr));
        return &h.file_reader.interface;
    }

    fn writer(ptr: *anyopaque) *Io.Writer {
        const h: *Http = @ptrCast(@alignCast(ptr));
        return &h.request.writer;
    }

    fn endRequest(ptr: *anyopaque) anyerror!void {
        const h: *Http = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(h.arena.allocator(), "{s}/{s}", .{ h.base, h.service.name() });
        const body = try h.request.toOwnedSlice();
        defer h.gpa.free(body);
        try h.perform(.POST, url, body);
    }

    fn close(ptr: *anyopaque) void {
        const h: *Http = @ptrCast(@alignCast(ptr));
        h.deinit();
    }

    fn deinit(h: *Http) void {
        if (h.file) |f| {
            f.close(h.io);
            h.opts.tmp_dir.deleteFile(h.io, h.tmpName()) catch {};
        }
        h.request.deinit();
        h.gpa.free(h.rbuf);
        h.arena.deinit();
        h.gpa.destroy(h);
    }

    fn tmpName(h: *const Http) []const u8 {
        return h.tmp_name[0 .. "tmp_http_".len + 16];
    }

    fn setAuth(h: *Http) !void {
        const a = h.arena.allocator();
        const plain = try std.fmt.allocPrint(a, "{s}:{s}", .{ h.cred.username.?, h.cred.password.? });
        const enc = std.base64.standard.Encoder;
        const out = try a.alloc(u8, enc.calcSize(plain.len));
        h.auth = try std.fmt.allocPrint(a, "Basic {s}", .{enc.encode(out, plain)});
    }

    const Sink = struct {
        w: *Io.Writer,
        status: std.http.Status = .ok,

        fn onChunk(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
            const s: *Sink = @ptrCast(@alignCast(ctx.?));
            try s.w.writeAll(bytes);
        }

        fn onHead(ctx: ?*anyopaque, status: std.http.Status, _: *const zg_net.http.OwnedHeaders) anyerror!void {
            const s: *Sink = @ptrCast(@alignCast(ctx.?));
            s.status = status;
        }
    };

    /// One request, its body spooled to the temp file and the reader set
    /// to read it; 401s go through the credential pipeline.
    fn perform(h: *Http, method: std.http.Method, url: []const u8, body: ?[]const u8) !void {
        const a = h.arena.allocator();
        const svc = h.service.name();
        var attempts: u8 = 0;
        while (true) : (attempts += 1) {
            var headers: std.ArrayList(std.http.Header) = .empty;
            if (h.service == .upload_pack) try headers.append(a, .{ .name = "Git-Protocol", .value = "version=2" });
            if (method == .POST) {
                try headers.append(a, .{ .name = "Content-Type", .value = try std.fmt.allocPrint(a, "application/x-{s}-request", .{svc}) });
                try headers.append(a, .{ .name = "Accept", .value = try std.fmt.allocPrint(a, "application/x-{s}-result", .{svc}) });
            }
            if (h.auth) |v| try headers.append(a, .{ .name = "Authorization", .value = v });
            if (h.file) |f| {
                f.close(h.io);
                h.file = null;
            }
            const f = try h.opts.tmp_dir.createFile(h.io, h.tmpName(), .{ .read = true, .truncate = true });
            h.file = f;
            var wbuf: [64 * 1024]u8 = undefined;
            var fw = f.writer(h.io, &wbuf);
            var sink: Sink = .{ .w = &fw.interface };
            var head = try h.opts.client.stream(.{
                .method = method,
                .url = url,
                .headers = headers.items,
                .body = body,
                .accept_encoding_gzip = false,
                // upload-pack requests only read, so a dropped keep-alive
                // connection can be retried; a push cannot.
                .retry = if (method == .GET or h.service == .upload_pack) .always else .never,
            }, .{ .ctx = &sink, .onChunk = Sink.onChunk, .onHead = Sink.onHead });
            head.deinit(h.opts.client.gpa);
            try fw.interface.flush();
            const status = head.status;
            if (status == .unauthorized) {
                const pipe = if (h.opts.credentials) |*p| p else return error.AuthenticationRequired;
                if (h.auth != null) {
                    pipe.reject(a, &h.cred);
                    if (attempts > 0 or h.cred.password != null) return error.AuthenticationFailed;
                }
                h.cred.password = null;
                if (!try pipe.fill(a, &h.cred)) return error.AuthenticationRequired;
                try h.setAuth();
                continue;
            }
            if (status.class() != .success) return error.HttpStatus;
            if (h.auth != null and !h.approved) {
                if (h.opts.credentials) |*pipe| pipe.approve(a, &h.cred);
                h.approved = true;
            }
            h.file_reader = f.reader(h.io, h.rbuf);
            return;
        }
    }

    /// Smart HTTP v0 advertisements start with "# service=<name>" and a
    /// flush; protocol v2 ones go straight to "version 2".
    fn skipServiceLine(h: *Http) !void {
        const r = &h.file_reader.interface;
        const hdr = r.peek(4) catch return error.EmptyAdvertisement;
        const len = @import("../proto/pktline.zig").parseLength(hdr[0..4].*) catch return error.NotSmartHttp;
        if (len < 4) return;
        const pkt = r.peek(len) catch return error.NotSmartHttp;
        if (!std.mem.startsWith(u8, pkt[4..], "# service=")) return;
        r.toss(len);
        const flush = r.peek(4) catch return error.NotSmartHttp;
        if (std.mem.eql(u8, flush[0..4], "0000")) r.toss(4);
    }
};
