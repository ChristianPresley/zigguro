//! A minimal HTTP/1.1 request-head parser for the egress proxy
//! (E16.F05.S01.T01). It accepts only the two proxy request shapes:
//!
//! - `CONNECT host:port HTTP/1.1` (authority-form, RFC 9112 section 3.2.3);
//! - `METHOD http://host[:port]/path HTTP/1.1` (absolute-form, section
//!   3.2.2) for plain HTTP forwarding.
//!
//! Anything ambiguous is rejected rather than interpreted, because the
//! proxy decides policy on what it parsed and the upstream acts on what it
//! receives: duplicate `Host`, obs-fold continuation lines, bare CR or LF,
//! both `Content-Length` and `Transfer-Encoding`, repeated
//! `Content-Length`, heads over 16 KiB and more than 100 headers.

const std = @import("std");

/// Largest accepted request head, including the final blank line.
pub const max_head = 16 * 1024;
/// Most header fields accepted.
pub const max_headers = 100;

pub const Error = error{ Incomplete, Malformed, TooLarge, Unsupported };

/// What the client asked the proxy to do.
pub const ProxyRequest = union(enum) {
    connect: struct { host: []const u8, port: u16 },
    forward: struct { method: []const u8, host: []const u8, port: u16, origin_form: []const u8 },

    /// The requested host (without brackets for IPv6 literals).
    pub fn host(r: ProxyRequest) []const u8 {
        return switch (r) {
            inline else => |x| x.host,
        };
    }

    /// The requested port.
    pub fn port(r: ProxyRequest) u16 {
        return switch (r) {
            inline else => |x| x.port,
        };
    }
};

/// A parsed head. All slices point into the buffer given to `parseHead`.
pub const Head = struct {
    req: ProxyRequest,
    /// Bytes of `buf` consumed by the head, including the blank line.
    head_len: usize,
    /// The header block: every field line with its CRLF, without the
    /// request line and the final blank line.
    fields: []const u8,

    /// Iterates the header fields.
    pub fn iterator(h: *const Head) FieldIterator {
        return .{ .rest = h.fields };
    }

    /// The first value of field `name` (case-insensitive).
    pub fn get(h: *const Head, name: []const u8) ?[]const u8 {
        var it = h.iterator();
        while (it.next()) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
        return null;
    }
};

/// One header field; the value has surrounding whitespace trimmed.
pub const Field = struct { name: []const u8, value: []const u8 };

/// Iterates `name: value\r\n` lines of an already validated block.
pub const FieldIterator = struct {
    rest: []const u8,

    pub fn next(it: *FieldIterator) ?Field {
        if (it.rest.len == 0) return null;
        const eol = std.mem.find(u8, it.rest, "\r\n") orelse it.rest.len;
        const line = it.rest[0..eol];
        it.rest = it.rest[@min(eol + 2, it.rest.len)..];
        const colon = std.mem.findScalar(u8, line, ':') orelse return null;
        return .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
    }
};

fn isTchar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

/// Parses the head at the start of `buf`.
pub fn parseHead(buf: []const u8) Error!Head {
    const end = std.mem.find(u8, buf[0..@min(buf.len, max_head)], "\r\n\r\n") orelse
        return if (buf.len >= max_head) error.TooLarge else error.Incomplete;
    const head = buf[0 .. end + 2];
    // Bare CR or LF anywhere in the head is a smuggling vector.
    for (head, 0..) |c, i| {
        if (c == '\r' and (i + 1 >= head.len or head[i + 1] != '\n')) return error.Malformed;
        if (c == '\n' and (i == 0 or head[i - 1] != '\r')) return error.Malformed;
        if (c == 0) return error.Malformed;
    }
    const line_end = std.mem.find(u8, head, "\r\n").?;
    const line = head[0..line_end];
    const fields = head[line_end + 2 ..];

    // Request line: method SP target SP version.
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.Malformed;
    const target = parts.next() orelse return error.Malformed;
    const version = parts.next() orelse return error.Malformed;
    if (parts.next() != null or method.len == 0 or target.len == 0) return error.Malformed;
    for (method) |c| if (!isTchar(c)) return error.Malformed;
    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) return error.Unsupported;

    // Header fields.
    var count: usize = 0;
    var host_count: usize = 0;
    var cl_count: usize = 0;
    var te = false;
    var rest = fields;
    while (rest.len > 0) {
        const eol = std.mem.find(u8, rest, "\r\n").?;
        const fl = rest[0..eol];
        rest = rest[eol + 2 ..];
        count += 1;
        if (count > max_headers) return error.TooLarge;
        if (fl.len == 0 or fl[0] == ' ' or fl[0] == '\t') return error.Malformed; // obs-fold
        const colon = std.mem.findScalar(u8, fl, ':') orelse return error.Malformed;
        const name = fl[0..colon];
        if (name.len == 0) return error.Malformed;
        for (name) |c| if (!isTchar(c)) return error.Malformed;
        for (fl[colon + 1 ..]) |c| if (c < 0x20 and c != '\t' or c == 0x7f) return error.Malformed;
        if (std.ascii.eqlIgnoreCase(name, "host")) host_count += 1;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) cl_count += 1;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) te = true;
    }
    if (host_count > 1 or cl_count > 1 or (cl_count == 1 and te)) return error.Malformed;

    var result: Head = .{ .req = undefined, .head_len = end + 4, .fields = fields };
    if (std.mem.eql(u8, method, "CONNECT")) {
        const a = try parseAuthority(target, null);
        result.req = .{ .connect = .{ .host = a.host, .port = a.port } };
        return result;
    }
    const scheme = "http://";
    if (target.len < scheme.len or !std.ascii.eqlIgnoreCase(target[0..scheme.len], scheme)) {
        // https:// absolute-form is a client asking us to originate TLS,
        // and origin-form means the client did not treat us as a proxy.
        return error.Unsupported;
    }
    const after = target[scheme.len..];
    const path_start = std.mem.findAny(u8, after, "/?") orelse after.len;
    const authority = after[0..path_start];
    if (std.mem.findScalar(u8, authority, '@') != null) return error.Malformed; // userinfo
    if (std.mem.findScalar(u8, after, '#') != null) return error.Malformed;
    const a = try parseAuthority(authority, 80);
    if (result.get("host")) |h| {
        // A Host that disagrees with the target would let the policy and
        // the upstream see different hosts.
        const ha = parseAuthority(h, 80) catch return error.Malformed;
        if (!std.ascii.eqlIgnoreCase(ha.host, a.host) or ha.port != a.port) return error.Malformed;
    }
    const origin = if (path_start == after.len) "/" else after[path_start..];
    if (origin[0] == '?') return error.Malformed;
    for (origin) |c| if (c <= 0x20 or c == 0x7f) return error.Malformed;
    result.req = .{ .forward = .{ .method = method, .host = a.host, .port = a.port, .origin_form = origin } };
    return result;
}

const Authority = struct { host: []const u8, port: u16 };

/// Parses `host:port`, `[v6]:port`, or (with a default port) a bare host.
fn parseAuthority(text: []const u8, default_port: ?u16) Error!Authority {
    if (text.len == 0) return error.Malformed;
    var host: []const u8 = undefined;
    var port_text: ?[]const u8 = null;
    if (text[0] == '[') {
        const close = std.mem.findScalar(u8, text, ']') orelse return error.Malformed;
        host = text[1..close];
        if (close + 1 < text.len) {
            if (text[close + 1] != ':') return error.Malformed;
            port_text = text[close + 2 ..];
        }
        _ = std.Io.net.IpAddress.parseIp6(host, 0) catch return error.Malformed;
    } else {
        if (std.mem.findScalar(u8, text, ':')) |c| {
            host = text[0..c];
            port_text = text[c + 1 ..];
        } else host = text;
        for (host) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c >= 0x80;
            if (!ok) return error.Malformed;
        }
    }
    if (host.len == 0) return error.Malformed;
    const port: u16 = if (port_text) |p| blk: {
        if (p.len == 0 or p.len > 5) return error.Malformed;
        for (p) |c| if (!std.ascii.isDigit(c)) return error.Malformed;
        const v = std.fmt.parseInt(u16, p, 10) catch return error.Malformed;
        if (v == 0) return error.Malformed;
        break :blk v;
    } else default_port orelse return error.Malformed;
    return .{ .host = host, .port = port };
}

/// Hop-by-hop fields that are never forwarded upstream (RFC 9110 7.6.1).
const hop_by_hop = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate", "te", "trailer", "upgrade", "host" };

fn listedInConnection(head: *const Head, name: []const u8) bool {
    var it = head.iterator();
    while (it.next()) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "connection")) continue;
        var toks = std.mem.tokenizeAny(u8, f.value, ", \t");
        while (toks.next()) |t| if (std.ascii.eqlIgnoreCase(t, name)) return true;
    }
    return false;
}

/// Writes the head to send upstream for a forward request: origin-form
/// request line, the target's `Host`, the client's end-to-end fields, and
/// `Connection: close` (one request per upstream connection).
pub fn writeForwardHead(w: *std.Io.Writer, head: *const Head) std.Io.Writer.Error!void {
    const f = head.req.forward;
    try w.print("{s} {s} HTTP/1.1\r\nHost: ", .{ f.method, f.origin_form });
    if (std.mem.findScalar(u8, f.host, ':') != null) try w.print("[{s}]", .{f.host}) else try w.writeAll(f.host);
    if (f.port != 80) try w.print(":{d}", .{f.port});
    try w.writeAll("\r\n");
    var it = head.iterator();
    outer: while (it.next()) |fl| {
        for (hop_by_hop) |h| if (std.ascii.eqlIgnoreCase(fl.name, h)) continue :outer;
        if (listedInConnection(head, fl.name)) continue;
        try w.print("{s}: {s}\r\n", .{ fl.name, fl.value });
    }
    try w.writeAll("Connection: close\r\n\r\n");
}

/// Checks a `Proxy-Authorization: Basic base64(user:token)` value against
/// the expected token (hex), in constant time over the token bytes. The
/// user name is ignored.
pub fn basicAuthMatches(value: ?[]const u8, token_hex: *const [32]u8) bool {
    const v = value orelse return false;
    const prefix = "basic ";
    if (v.len <= prefix.len or !std.ascii.eqlIgnoreCase(v[0..prefix.len], prefix)) return false;
    const enc = std.mem.trim(u8, v[prefix.len..], " ");
    var dec: [128]u8 = undefined;
    const d = std.base64.standard.Decoder;
    const n = d.calcSizeForSlice(enc) catch return false;
    if (n > dec.len) return false;
    d.decode(dec[0..n], enc) catch return false;
    const creds = dec[0..n];
    const colon = std.mem.findScalar(u8, creds, ':') orelse return false;
    const pass = creds[colon + 1 ..];
    if (pass.len != token_hex.len) return false;
    return std.crypto.timing_safe.eql([32]u8, pass[0..32].*, token_hex.*);
}

/// Writes a short error response and nothing else.
pub fn writeError(w: *std.Io.Writer, status: u16, reason: []const u8, body: []const u8) std.Io.Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, reason, body.len, body });
}

test "http1: parse CONNECT" {
    const h = try parseHead("CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\nextra");
    try std.testing.expectEqualStrings("api.github.com", h.req.connect.host);
    try std.testing.expectEqual(@as(u16, 443), h.req.connect.port);
    try std.testing.expectEqual(@as(usize, 65), h.head_len);
    const v6 = try parseHead("CONNECT [2001:db8::1]:8443 HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("2001:db8::1", v6.req.host());
    try std.testing.expectEqual(@as(u16, 8443), v6.req.port());
    try std.testing.expectError(error.Malformed, parseHead("CONNECT example.com HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("CONNECT example.com:0 HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("CONNECT example.com:99999 HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("CONNECT [::1:443 HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("CONNECT a/b:443 HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Incomplete, parseHead("CONNECT example.com:443 HTTP/1.1\r\n"));
}

test "http1: parse absolute-form and rewrite to origin-form" {
    const raw = "GET http://Example.com:8080/a/b?q=1 HTTP/1.1\r\nHost: example.com:8080\r\nAccept: */*\r\nProxy-Authorization: Basic eDp5\r\nConnection: keep-alive, X-Secret\r\nX-Secret: 1\r\nUser-Agent: curl\r\n\r\n";
    const h = try parseHead(raw);
    const f = h.req.forward;
    try std.testing.expectEqualStrings("GET", f.method);
    try std.testing.expectEqualStrings("Example.com", f.host);
    try std.testing.expectEqual(@as(u16, 8080), f.port);
    try std.testing.expectEqualStrings("/a/b?q=1", f.origin_form);
    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeForwardHead(&w, &h);
    try std.testing.expectEqualStrings("GET /a/b?q=1 HTTP/1.1\r\nHost: Example.com:8080\r\nAccept: */*\r\nUser-Agent: curl\r\nConnection: close\r\n\r\n", w.buffered());

    const bare = try parseHead("HEAD http://example.com HTTP/1.0\r\n\r\n");
    try std.testing.expectEqualStrings("/", bare.req.forward.origin_form);
    try std.testing.expectEqual(@as(u16, 80), bare.req.forward.port);
    try std.testing.expectError(error.Unsupported, parseHead("GET https://example.com/ HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Unsupported, parseHead("GET /index.html HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Unsupported, parseHead("GET http://x/ HTTP/2\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://user:pw@example.com/ HTTP/1.1\r\n\r\n"));
}

test "http1: reject smuggling (duplicate Host, obs-fold, oversized head)" {
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\r\nHost: a.com\r\nHost: b.com\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\r\nHost: b.com\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\r\nX-A: 1\r\n folded\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\nX: y\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\r\nX: a\rb\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET http://a.com/ HTTP/1.1\r\nBad Name: x\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET  http://a.com/ HTTP/1.1\r\n\r\n"));
    const big = "GET http://a.com/ HTTP/1.1\r\nX: " ++ "a" ** max_head;
    try std.testing.expectError(error.TooLarge, parseHead(big));
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(std.testing.allocator);
    try many.appendSlice(std.testing.allocator, "CONNECT a.com:443 HTTP/1.1\r\n");
    for (0..max_headers + 1) |_| try many.appendSlice(std.testing.allocator, "X: y\r\n");
    try many.appendSlice(std.testing.allocator, "\r\n");
    try std.testing.expectError(error.TooLarge, parseHead(many.items));
}

test "http1: basic proxy auth" {
    const token = "00112233445566778899aabbccddeeff";
    var enc: [128]u8 = undefined;
    const good = std.base64.standard.Encoder.encode(&enc, "zg:" ++ token);
    var hdr: [160]u8 = undefined;
    const value = try std.fmt.bufPrint(&hdr, "Basic {s}", .{good});
    try std.testing.expect(basicAuthMatches(value, token));
    try std.testing.expect(!basicAuthMatches(null, token));
    try std.testing.expect(!basicAuthMatches("Basic eDp5", token));
    try std.testing.expect(!basicAuthMatches("Bearer abc", token));
    try std.testing.expect(!basicAuthMatches("Basic !!!", token));
}

test "http1: fuzz parseHead" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const h = parseHead(input) catch return;
            try std.testing.expect(h.head_len <= input.len);
            var out: [2048]u8 = undefined;
            var w: std.Io.Writer = .fixed(&out);
            if (h.req == .forward) writeForwardHead(&w, &h) catch {};
            var it = h.iterator();
            while (it.next()) |_| {}
        }
    }.one, .{ .corpus = &.{
        "CONNECT a.com:443 HTTP/1.1\r\nHost: a.com\r\n\r\n",
        "GET http://a.com:81/x?y HTTP/1.1\r\nHost: a.com:81\r\nConnection: x\r\nx: 1\r\n\r\n",
    } });
}
