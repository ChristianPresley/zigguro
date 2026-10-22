//! The client side of D-Bus SASL: a NUL byte, `AUTH EXTERNAL <hex uid>`,
//! `OK <guid>`, then optionally `NEGOTIATE_UNIX_FD`, then `BEGIN`. A pure
//! state machine: the connection feeds it server lines and sends what it
//! returns, so it is tested without a socket.

const std = @import("std");

/// Errors from the exchange.
pub const Error = error{ AuthRejected, AuthProtocol };

/// What to do after a server line.
pub const Step = union(enum) {
    /// Send these bytes and wait for the next line.
    send: []const u8,
    /// Send these bytes (`BEGIN`); authentication is done and binary
    /// messages follow.
    begin: []const u8,
};

/// The client state machine.
pub const Client = struct {
    state: enum { start, wait_ok, wait_fd, done } = .start,
    negotiate_fd: bool,
    uid_hex: [20]u8 = undefined,
    uid_hex_len: usize = 0,
    line: [64]u8 = undefined,
    /// The server guid, valid after `OK`.
    guid: [32]u8 = undefined,
    /// Whether the server agreed to pass fds.
    unix_fd: bool = false,

    /// A client for `uid`, asking for fd passing when `negotiate_fd`.
    pub fn init(uid: u32, negotiate_fd: bool) Client {
        var c: Client = .{ .negotiate_fd = negotiate_fd };
        var dec: [10]u8 = undefined;
        const digits = std.fmt.bufPrint(&dec, "{d}", .{uid}) catch unreachable;
        const hex = std.fmt.bufPrint(&c.uid_hex, "{x}", .{digits}) catch unreachable;
        c.uid_hex_len = hex.len;
        return c;
    }

    /// The opening bytes: a NUL, then the AUTH command.
    pub fn initial(c: *Client) []const u8 {
        std.debug.assert(c.state == .start);
        c.state = .wait_ok;
        return std.fmt.bufPrint(&c.line, "\x00AUTH EXTERNAL {s}\r\n", .{c.uid_hex[0..c.uid_hex_len]}) catch unreachable;
    }

    /// Handles one server line, without its `\r\n`.
    pub fn onLine(c: *Client, line: []const u8) Error!Step {
        switch (c.state) {
            .wait_ok => {
                if (std.mem.startsWith(u8, line, "OK ")) {
                    const g = line[3..];
                    if (g.len != 32) return error.AuthProtocol;
                    for (g) |ch| if (!std.ascii.isHex(ch)) return error.AuthProtocol;
                    @memcpy(&c.guid, g);
                    if (c.negotiate_fd) {
                        c.state = .wait_fd;
                        return .{ .send = "NEGOTIATE_UNIX_FD\r\n" };
                    }
                    c.state = .done;
                    return .{ .begin = "BEGIN\r\n" };
                }
                if (std.mem.startsWith(u8, line, "REJECTED")) return error.AuthRejected;
                // A server may ask for the identity again as DATA; answer
                // with an empty response, which means "the one I sent".
                if (std.mem.eql(u8, line, "DATA") or std.mem.startsWith(u8, line, "DATA ")) return .{ .send = "DATA\r\n" };
                if (std.mem.startsWith(u8, line, "ERROR")) return error.AuthRejected;
                return error.AuthProtocol;
            },
            .wait_fd => {
                if (std.mem.eql(u8, line, "AGREE_UNIX_FD")) {
                    c.unix_fd = true;
                } else if (!std.mem.startsWith(u8, line, "ERROR")) return error.AuthProtocol;
                c.state = .done;
                return .{ .begin = "BEGIN\r\n" };
            },
            .start, .done => return error.AuthProtocol,
        }
    }
};

const testing = std.testing;

test "auth line exchange with fake server" {
    var c: Client = .init(1000, true);
    try testing.expectEqualStrings("\x00AUTH EXTERNAL 31303030\r\n", c.initial());
    const s1 = try c.onLine("OK 0123456789abcdef0123456789abcdef");
    try testing.expectEqualStrings("NEGOTIATE_UNIX_FD\r\n", s1.send);
    const s2 = try c.onLine("AGREE_UNIX_FD");
    try testing.expectEqualStrings("BEGIN\r\n", s2.begin);
    try testing.expect(c.unix_fd);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", &c.guid);
}

test "auth without fd passing, and refusals" {
    var c: Client = .init(0, false);
    try testing.expectEqualStrings("\x00AUTH EXTERNAL 30\r\n", c.initial());
    try testing.expectEqualStrings("DATA\r\n", (try c.onLine("DATA")).send);
    try testing.expectEqualStrings("BEGIN\r\n", (try c.onLine("OK 0123456789abcdef0123456789abcdef")).begin);
    try testing.expect(!c.unix_fd);

    var r: Client = .init(5, true);
    _ = r.initial();
    try testing.expectError(error.AuthRejected, r.onLine("REJECTED EXTERNAL DBUS_COOKIE_SHA1"));

    var f: Client = .init(5, true);
    _ = f.initial();
    _ = try f.onLine("OK 0123456789abcdef0123456789abcdef");
    try testing.expectEqualStrings("BEGIN\r\n", (try f.onLine("ERROR \"not supported\"")).begin);
    try testing.expect(!f.unix_fd);

    var g: Client = .init(5, false);
    _ = g.initial();
    try testing.expectError(error.AuthProtocol, g.onLine("OK short"));
}
