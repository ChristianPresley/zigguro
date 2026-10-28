//! ssh-agent client (RFC 9987): list identities and ask the agent to sign.
//! Connects to the Unix socket in `SSH_AUTH_SOCK`, or on Windows to the
//! OpenSSH agent's named pipe.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("wire.zig");

const request_identities = 11;
const identities_answer = 12;
const sign_request = 13;
const sign_response = 14;
const failure = 5;

pub const flag_rsa_sha2_256 = 2;
pub const flag_rsa_sha2_512 = 4;

pub const windows_pipe = "\\\\.\\pipe\\openssh-ssh-agent";

/// The agent's address from the environment, if there is one.
pub fn defaultPath(env: ?*const std.process.Environ.Map) ?[]const u8 {
    if (env) |e| if (e.get("SSH_AUTH_SOCK")) |s| if (s.len > 0) return s;
    if (builtin.os.tag == .windows) return windows_pipe;
    return null;
}

pub const Identity = struct {
    blob: []const u8,
    comment: []const u8,
};

pub const Agent = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,

    /// The keys the agent holds. Free with `freeIdentities`.
    pub fn identities(a: Agent) ![]Identity {
        const reply = try a.call(&.{request_identities});
        defer a.gpa.free(reply);
        if (reply.len == 0 or reply[0] != identities_answer) return error.AgentFailure;
        var p: wire.Parser = .init(reply[1..]);
        const n = try p.int();
        var list: std.ArrayList(Identity) = .empty;
        errdefer freeList(a.gpa, list.items);
        defer list.deinit(a.gpa);
        for (0..n) |_| {
            const blob = try a.gpa.dupe(u8, try p.string());
            errdefer a.gpa.free(blob);
            const comment = try a.gpa.dupe(u8, try p.string());
            errdefer a.gpa.free(comment);
            try list.append(a.gpa, .{ .blob = blob, .comment = comment });
        }
        return list.toOwnedSlice(a.gpa);
    }

    pub fn freeIdentities(a: Agent, ids: []Identity) void {
        freeList(a.gpa, ids);
        a.gpa.free(ids);
    }

    fn freeList(gpa: Allocator, ids: []Identity) void {
        for (ids) |id| {
            gpa.free(id.blob);
            gpa.free(id.comment);
        }
    }

    /// Asks the agent to sign `data` with the key `blob`; returns the
    /// signature blob.
    pub fn sign(a: Agent, blob: []const u8, data: []const u8, flags: u32) ![]u8 {
        var b: wire.Builder = .init(a.gpa);
        defer b.deinit();
        try b.byte(sign_request);
        try b.string(blob);
        try b.string(data);
        try b.int(flags);
        const reply = try a.call(b.bytes());
        defer a.gpa.free(reply);
        if (reply.len == 0 or reply[0] != sign_response) return error.AgentRefused;
        var p: wire.Parser = .init(reply[1..]);
        return a.gpa.dupe(u8, try p.string());
    }

    fn call(a: Agent, msg: []const u8) ![]u8 {
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        if (builtin.os.tag == .windows and std.mem.startsWith(u8, a.path, "\\\\.\\pipe\\")) {
            const f = try Io.Dir.openFileAbsolute(a.io, a.path, .{ .mode = .read_write });
            defer f.close(a.io);
            var r = f.readerStreaming(a.io, &rbuf);
            var w = f.writerStreaming(a.io, &wbuf);
            return exchange(a.gpa, &r.interface, &w.interface, msg);
        }
        const addr = try Io.net.UnixAddress.init(a.path);
        const s = try addr.connect(a.io);
        defer s.close(a.io);
        var r = s.reader(a.io, &rbuf);
        var w = s.writer(a.io, &wbuf);
        return exchange(a.gpa, &r.interface, &w.interface, msg);
    }
};

fn exchange(gpa: Allocator, r: *Io.Reader, w: *Io.Writer, msg: []const u8) ![]u8 {
    try w.writeInt(u32, @intCast(msg.len), .big);
    try w.writeAll(msg);
    try w.flush();
    const len = try r.takeInt(u32, .big);
    if (len > 256 * 1024) return error.AgentFailure;
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    try r.readSliceAll(out);
    return out;
}
