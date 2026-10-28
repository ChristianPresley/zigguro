//! An SSH connection to a git server (E09.F08.S03.T04): reads
//! `~/.ssh/config` for the host, dials it, checks the host key against
//! known_hosts, authenticates with ssh-agent keys and key files, and
//! runs `git-upload-pack` or `git-receive-pack` on the remote.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const transport = @import("../remote/transport.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const config = @import("config.zig");
const known_hosts = @import("known_hosts.zig");
const keys = @import("keys.zig");
const agent_mod = @import("agent.zig");
const pubkey = @import("pubkey.zig");
const url_mod = @import("url.zig");
const wire = @import("wire.zig");

/// A byte stream to the server.
pub const Raw = struct {
    ctx: ?*anyopaque,
    reader: *Io.Reader,
    writer: *Io.Writer,
    close: *const fn (ctx: ?*anyopaque) void,
};

/// Opens the byte stream; the default dials TCP.
pub const Dialer = struct {
    ctx: ?*anyopaque = null,
    dial: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: Io, host: []const u8, port: u16) anyerror!Raw,
};

/// Asks the user whether to trust an unknown host key.
pub const HostKeyPrompt = struct {
    ctx: ?*anyopaque = null,
    ask: *const fn (ctx: ?*anyopaque, host: []const u8, key_type: []const u8, fingerprint: []const u8) bool,
};

/// Asks the user for a key file's passphrase; null means cancelled.
pub const PassphraseProvider = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, gpa: Allocator, key_path: []const u8, attempt: u32) anyerror!?[]u8,
};

pub const Options = struct {
    env: ?*const std.process.Environ.Map = null,
    /// Overrides HOME/USERPROFILE.
    home: ?[]const u8 = null,
    /// ssh_config text; null reads `<home>/.ssh/config`.
    ssh_config: ?[]const u8 = null,
    /// Overrides UserKnownHostsFile.
    known_hosts_files: ?[]const []const u8 = null,
    /// Overrides StrictHostKeyChecking (default `ask`).
    strict: ?config.Strict = null,
    host_key_prompt: ?HostKeyPrompt = null,
    passphrase: ?PassphraseProvider = null,
    dialer: ?Dialer = null,
    /// Overrides IdentityAgent / SSH_AUTH_SOCK; "none" disables it.
    agent: ?[]const u8 = null,
    /// Overrides IdentityFile (and the default key files).
    identity_files: ?[]const []const u8 = null,
    allow_terrapin: bool = false,
    protocol_v2: bool = true,
};

const KeyFile = struct {
    path: []const u8,
    text: []const u8,
    loaded: ?keys.Loaded = null,
};

const Ident = struct {
    s: *Session,
    blob: []const u8,
    file: ?*KeyFile,
};

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    opts: Options,
    raw: ?Raw = null,
    client: ?*Client = null,
    host: []const u8 = "",
    known_name: []const u8 = "",
    known_files: []const []const u8 = &.{},
    strict: config.Strict = .ask,
    /// The server's host key fingerprint, once seen.
    fingerprint: [50]u8 = undefined,
    fingerprint_len: usize = 0,
    agent: ?agent_mod.Agent = null,
    key_files: std.ArrayList(*KeyFile) = .empty,

    pub fn fingerprintText(s: *const Session) []const u8 {
        return s.fingerprint[0..s.fingerprint_len];
    }

    /// What the remote command wrote to stderr.
    pub fn stderrText(s: *const Session) []const u8 {
        return if (s.client) |c| c.stderr.items else "";
    }

    pub fn connection(s: *Session) transport.Connection {
        return .{ .ptr = s, .vtable = &.{ .reader = reader, .writer = writer, .end_request = endRequest, .close = close } };
    }

    fn reader(ptr: *anyopaque) *Io.Reader {
        const s: *Session = @ptrCast(@alignCast(ptr));
        return s.client.?.reader();
    }

    fn writer(ptr: *anyopaque) *Io.Writer {
        const s: *Session = @ptrCast(@alignCast(ptr));
        return s.client.?.writer();
    }

    fn endRequest(ptr: *anyopaque) anyerror!void {
        const s: *Session = @ptrCast(@alignCast(ptr));
        const c = s.client.?;
        c.writer().flush() catch return c.err orelse error.WriteFailed;
    }

    fn close(ptr: *anyopaque) void {
        const s: *Session = @ptrCast(@alignCast(ptr));
        s.deinit();
    }

    pub fn deinit(s: *Session) void {
        if (s.client) |c| {
            c.shutdown();
            c.destroy();
        }
        if (s.raw) |r| r.close(r.ctx);
        for (s.key_files.items) |k| if (k.loaded) |*l| l.deinit(s.gpa);
        const gpa = s.gpa;
        s.arena.deinit();
        gpa.destroy(s);
    }

    fn verifyHostKey(ctx: ?*anyopaque, blob: []const u8) anyerror!void {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        const a = s.arena.allocator();
        s.fingerprint_len = pubkey.fingerprint(&s.fingerprint, blob).len;
        var changed = false;
        for (s.known_files) |f| {
            const text = readFile(a, s.io, f) orelse continue;
            switch (try known_hosts.check(s.gpa, text, s.known_name, blob)) {
                .known => return,
                .revoked => return error.HostKeyRevoked,
                .changed => changed = true,
                .unknown => {},
            }
        }
        // A changed key is never accepted, whatever the policy.
        if (changed) return error.HostKeyChanged;
        const pk = try pubkey.PublicKey.parse(blob);
        switch (s.strict) {
            .yes => return error.HostKeyUnknown,
            .no => return,
            .accept_new => {},
            .ask => {
                const p = s.opts.host_key_prompt orelse return error.HostKeyUnknown;
                if (!p.ask(p.ctx, s.known_name, pk.typeName(), s.fingerprintText())) return error.HostKeyRejected;
            },
        }
        if (s.known_files.len > 0) try appendKnownHost(s, s.known_files[0], blob);
    }

    fn signWith(ctx: ?*anyopaque, gpa: Allocator, alg: []const u8, data: []const u8) anyerror![]u8 {
        const id: *Ident = @ptrCast(@alignCast(ctx.?));
        const s = id.s;
        if (id.file) |kf| {
            if (kf.loaded == null) kf.loaded = try loadKey(s, kf);
            return kf.loaded.?.key.sign(gpa, alg, data);
        }
        const flags: u32 = if (std.mem.eql(u8, alg, "rsa-sha2-512"))
            agent_mod.flag_rsa_sha2_512
        else if (std.mem.eql(u8, alg, "rsa-sha2-256")) agent_mod.flag_rsa_sha2_256 else 0;
        return s.agent.?.sign(id.blob, data, flags);
    }
};

fn loadKey(s: *Session, kf: *KeyFile) !keys.Loaded {
    if (!try keys.isEncrypted(s.gpa, kf.text)) return keys.parse(s.gpa, kf.text, null);
    const p = s.opts.passphrase orelse return error.PassphraseRequired;
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        const pass = (try p.get(p.ctx, s.gpa, kf.path, attempt)) orelse return error.PassphraseCancelled;
        defer {
            std.crypto.secureZero(u8, pass);
            s.gpa.free(pass);
        }
        return keys.parse(s.gpa, kf.text, pass) catch |e| switch (e) {
            error.BadPassphrase => continue,
            else => |x| return x,
        };
    }
    return error.BadPassphrase;
}

fn readFile(a: Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch null;
}

fn appendKnownHost(s: *Session, path: []const u8, blob: []const u8) !void {
    const a = s.arena.allocator();
    const line = try known_hosts.entry(a, s.known_name, blob);
    const old = readFile(a, s.io, path) orelse "";
    const sep: []const u8 = if (old.len > 0 and old[old.len - 1] != '\n') "\n" else "";
    if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(s.io, d) catch {};
    const text = try std.mem.concat(a, u8, &.{ old, sep, line });
    try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = text });
}

/// Host key algorithms with the types known_hosts already has for this
/// host first, so a known key is the one the server presents.
fn hostKeyOrder(a: Allocator, s: *Session) ![]const u8 {
    var first: std.ArrayList(u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (s.known_files) |f| {
        const text = readFile(a, s.io, f) orelse continue;
        const types = try known_hosts.knownTypes(a, text, s.known_name);
        for (types) |t| {
            const algs: []const []const u8 = if (std.mem.eql(u8, t, "ssh-rsa")) &.{ "rsa-sha2-512", "rsa-sha2-256" } else &.{t};
            for (algs) |alg| {
                if (!wire.hasName(client_mod.default_host_key_algorithms, alg)) continue;
                if ((try seen.getOrPut(a, alg)).found_existing) continue;
                if (first.items.len > 0) try first.append(a, ',');
                try first.appendSlice(a, alg);
            }
        }
    }
    var it = wire.names(client_mod.default_host_key_algorithms);
    while (it.next()) |alg| {
        if ((try seen.getOrPut(a, alg)).found_existing) continue;
        if (first.items.len > 0) try first.append(a, ',');
        try first.appendSlice(a, alg);
    }
    return first.items;
}

const Tcp = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    r: Io.net.Stream.Reader,
    w: Io.net.Stream.Writer,
    rbuf: [32 * 1024]u8 = undefined,
    wbuf: [32 * 1024]u8 = undefined,

    fn dial(_: ?*anyopaque, gpa: Allocator, io: Io, host: []const u8, port: u16) anyerror!Raw {
        const t = try gpa.create(Tcp);
        errdefer gpa.destroy(t);
        const name = try Io.net.HostName.init(host);
        t.* = .{ .gpa = gpa, .io = io, .stream = try name.connect(io, port, .{ .mode = .stream }), .r = undefined, .w = undefined };
        t.r = t.stream.reader(io, &t.rbuf);
        t.w = t.stream.writer(io, &t.wbuf);
        return .{ .ctx = t, .reader = &t.r.interface, .writer = &t.w.interface, .close = close };
    }

    fn close(ctx: ?*anyopaque) void {
        const t: *Tcp = @ptrCast(@alignCast(ctx.?));
        t.stream.close(t.io);
        t.gpa.destroy(t);
    }
};

/// Connects to the SSH remote `url` and starts `service` on it.
pub fn connect(gpa: Allocator, io: Io, url: []const u8, service: transport.Service, opts: Options) !*Session {
    const s = try gpa.create(Session);
    s.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .opts = opts };
    errdefer s.deinit();
    const a = s.arena.allocator();
    const target = try url_mod.parse(url);
    const env = opts.env;
    const home = opts.home orelse if (env) |e| (e.get("HOME") orelse e.get("USERPROFILE") orelse "") else "";
    const local_user = if (env) |e| (e.get("USER") orelse e.get("USERNAME") orelse "") else "";
    const cfg_text = opts.ssh_config orelse blk: {
        if (home.len == 0) break :blk "";
        const p = try std.fs.path.join(a, &.{ home, ".ssh", "config" });
        break :blk readFile(a, io, p) orelse "";
    };
    const cfg = try config.resolve(a, cfg_text, target.host);
    if (cfg.proxy orelse false) return error.SshProxyUnsupported;
    s.host = cfg.host_name orelse target.host;
    const port = target.port orelse cfg.port orelse 22;
    const user = target.user orelse cfg.user orelse (if (local_user.len > 0) local_user else "git");
    var nb: [300]u8 = undefined;
    s.known_name = try a.dupe(u8, known_hosts.hostName(&nb, s.host, port));
    s.strict = opts.strict orelse cfg.strict orelse .ask;

    if (opts.known_hosts_files) |f| s.known_files = f else if (cfg.known_hosts_files) |files| {
        const list = try a.alloc([]const u8, files.len);
        for (files, list) |f, *o| o.* = try config.expand(a, f, home, s.host, user, local_user);
        s.known_files = list;
    } else if (home.len > 0) {
        s.known_files = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ home, ".ssh", "known_hosts" }),
            try std.fs.path.join(a, &.{ home, ".ssh", "known_hosts2" }),
        });
    }

    const dialer = opts.dialer orelse Dialer{ .dial = Tcp.dial };
    s.raw = try dialer.dial(dialer.ctx, gpa, io, s.host, port);
    s.client = try Client.create(gpa, io, s.raw.?.reader, s.raw.?.writer);
    const c = s.client.?;
    try c.handshake(.{
        .host_key_algorithms = try hostKeyOrder(a, s),
        .verifier = .{ .ctx = s, .verify = Session.verifyHostKey },
        .allow_terrapin = opts.allow_terrapin,
    });

    // Identities: the agent's keys, then key files not already offered.
    var ids: std.ArrayList(*Ident) = .empty;
    const agent_path: ?[]const u8 = if (opts.agent) |p| p else if (cfg.identity_agent) |p|
        (if (std.mem.eql(u8, p, "SSH_AUTH_SOCK")) agent_mod.defaultPath(env) else try config.expand(a, p, home, s.host, user, local_user))
    else
        agent_mod.defaultPath(env);
    const file_paths: []const []const u8 = if (opts.identity_files) |f| f else if (cfg.identity_files.len > 0) blk: {
        const list = try a.alloc([]const u8, cfg.identity_files.len);
        for (cfg.identity_files, list) |f, *o| o.* = try config.expand(a, f, home, s.host, user, local_user);
        break :blk list;
    } else if (home.len > 0) blk: {
        var list: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "id_rsa", "id_ecdsa", "id_ed25519" }) |n| try list.append(a, try std.fs.path.join(a, &.{ home, ".ssh", n }));
        break :blk list.items;
    } else &.{};
    var file_blobs: std.ArrayList([]const u8) = .empty;
    for (file_paths) |p| {
        const text = readFile(a, io, p) orelse continue;
        const blob = keys.publicBlob(a, text) catch continue;
        const kf = try a.create(KeyFile);
        kf.* = .{ .path = p, .text = text };
        try s.key_files.append(a, kf);
        try file_blobs.append(a, blob);
    }
    if (agent_path) |p| if (!std.mem.eql(u8, p, "none")) {
        s.agent = .{ .gpa = gpa, .io = io, .path = p };
        if (s.agent.?.identities()) |list| {
            defer s.agent.?.freeIdentities(list);
            for (list) |id| {
                if (cfg.identities_only orelse false) {
                    var listed = false;
                    for (file_blobs.items) |b| listed = listed or std.mem.eql(u8, b, id.blob);
                    if (!listed) continue;
                }
                const ident = try a.create(Ident);
                ident.* = .{ .s = s, .blob = try a.dupe(u8, id.blob), .file = null };
                try ids.append(a, ident);
            }
        } else |_| s.agent = null;
    };
    for (s.key_files.items, file_blobs.items) |kf, blob| {
        var dup = false;
        for (ids.items) |id| dup = dup or std.mem.eql(u8, id.blob, blob);
        if (dup) continue;
        const ident = try a.create(Ident);
        ident.* = .{ .s = s, .blob = blob, .file = kf };
        try ids.append(a, ident);
    }
    const identities = try a.alloc(client_mod.Identity, ids.items.len);
    for (ids.items, identities) |id, *o| o.* = .{ .blob = id.blob, .ctx = id, .sign = Session.signWith };
    try c.authenticate(user, identities);

    const cmd = try url_mod.command(a, service.name(), target.path);
    const env_vars: []const [2][]const u8 = if (opts.protocol_v2 and service == .upload_pack) &.{.{ "GIT_PROTOCOL", "version=2" }} else &.{};
    try c.exec(cmd, env_vars);
    return s;
}
