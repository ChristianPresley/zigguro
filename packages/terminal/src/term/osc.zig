//! The OSC dispatcher: titles, working directory, hyperlinks, clipboard,
//! notifications, progress, shell-integration marks, iTerm2 extensions,
//! pointer shapes and the colour OSCs (handled in `reports.zig`). Anything
//! that changes UI or OS state becomes an `Effect`; the owner applies the
//! permission policy (E16) before acting. OSC content is never echoed back.

const std = @import("std");
const Terminal = @import("Terminal.zig");
const StringTerm = @import("../vt/Parser.zig").StringTerm;
const effects = @import("effects.zig");
const reports = @import("reports.zig");
const mark = @import("../shell/mark.zig");

/// OSC 8 limits (Egmont Koblinger's recommendations).
pub const uri_max = 2083;
pub const link_id_max = 250;
/// Notification title/body cap in bytes.
pub const notify_max = 1024;

fn splitFirst(s: []const u8, sep: u8) struct { []const u8, ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, s, sep)) |i| return .{ s[0..i], s[i + 1 ..] };
    return .{ s, null };
}

/// Dispatches one OSC string (`Ps ; Pt`).
pub fn dispatch(t: *Terminal, data: []const u8, term: StringTerm) void {
    const ps_s, const rest_opt = splitFirst(data, ';');
    const ps = std.fmt.parseInt(u16, ps_s, 10) catch return;
    const rest = rest_opt orelse "";
    switch (ps) {
        0 => t.setTitle(.both, rest),
        1 => t.setTitle(.icon, rest),
        2 => t.setTitle(.title, rest),
        4, 10...19, 104, 110...119 => reports.colorOsc(t, ps, rest, term),
        7 => cwdUrl(t, rest),
        8 => if (rest_opt != null) hyperlink(t, rest),
        9 => conemu(t, rest),
        22 => pointerShape(t, rest),
        52 => if (rest_opt != null) clipboard(t, rest, term),
        133 => shellMark(t, rest, false),
        633 => shellMark(t, rest, true),
        777 => {
            const kind, const tail = splitFirst(rest, ';');
            if (!std.mem.eql(u8, kind, "notify")) return;
            const title, const body = splitFirst(tail orelse "", ';');
            notify(t, title, body orelse "");
        },
        1337 => iterm(t, rest),
        else => {},
    }
}

fn isHostOf(t: *const Terminal, host: []const u8) bool {
    return host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost") or
        (t.opts.hostname.len > 0 and std.ascii.eqlIgnoreCase(host, t.opts.hostname));
}

/// Percent-decodes `s` into `out` (malformed escapes are kept literally).
pub fn percentDecode(out: []u8, s: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = s[i];
        i += 1;
    }
    return out[0..n];
}

/// Reports a working directory to the owner and the mark sink.
fn reportCwd(t: *Terminal, host: []const u8, path: []const u8) void {
    const remote = !isHostOf(t, host);
    const p = t.effects.dupe(path) catch return t.allocFailed();
    const h = t.effects.dupe(host) catch return t.allocFailed();
    t.effects.push(.{ .cwd = .{ .path = p, .host = h, .remote = remote } });
    t.emitMark(.{ .cwd = path });
}

/// OSC 7: `file://host/path` (or `kitty-shell-cwd://`).
fn cwdUrl(t: *Terminal, url: []const u8) void {
    const after = if (std.mem.startsWith(u8, url, "file://"))
        url["file://".len..]
    else if (std.mem.startsWith(u8, url, "kitty-shell-cwd://"))
        url["kitty-shell-cwd://".len..]
    else
        return;
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return;
    var buf: [4096]u8 = undefined;
    const path = percentDecode(&buf, after[slash..]);
    reportCwd(t, after[0..slash], path);
}

fn hasScheme(uri: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(uri[0])) return false;
    for (uri[1..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return false;
    }
    return true;
}

/// OSC 8: `params ; URI`; an empty URI closes the link.
fn hyperlink(t: *Terminal, rest: []const u8) void {
    const s = t.screen();
    const params, const uri_opt = splitFirst(rest, ';');
    const uri = uri_opt orelse return;
    if (uri.len == 0) {
        s.setLink(null) catch {};
        return;
    }
    if (uri.len > uri_max or !hasScheme(uri)) return;
    var id: []const u8 = "";
    var it = std.mem.splitScalar(u8, params, ':');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "id=")) id = kv[3..];
    }
    if (id.len > link_id_max) return;
    for (uri) |c| if (c < 0x20 or c == 0x7F) return;
    s.setLink(.{ .uri = uri, .id = id }) catch t.allocFailed();
}

/// OSC 9: ConEmu / Windows Terminal (progress, cwd) or a notification.
fn conemu(t: *Terminal, rest: []const u8) void {
    const sub, const tail = splitFirst(rest, ';');
    const numeric = sub.len > 0 and for (sub) |c| {
        if (!std.ascii.isDigit(c)) break false;
    } else true;
    if (!numeric) return notify(t, "", rest);
    if (std.mem.eql(u8, sub, "4")) {
        const st_s, const pr_s = splitFirst(tail orelse "", ';');
        const st = std.fmt.parseInt(u8, st_s, 10) catch 0;
        const pr = std.fmt.parseInt(u16, pr_s orelse "0", 10) catch 0;
        const state: @FieldType(effects.Progress, "state") = switch (st) {
            1 => .normal,
            2 => .err,
            3 => .indeterminate,
            4 => .paused,
            else => .remove,
        };
        t.effects.push(.{ .progress = .{ .state = state, .percent = @intCast(@min(pr, 100)) } });
    } else if (std.mem.eql(u8, sub, "9")) {
        var path = tail orelse return;
        if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') path = path[1 .. path.len - 1];
        reportCwd(t, "", path);
    }
    // Other numeric ConEmu commands (sleep, message boxes, ...) are ignored.
}

fn cleanDupe(t: *Terminal, text: []const u8) ?[]const u8 {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(t.gpa);
    Terminal.sanitizeText(&tmp, t.gpa, text, notify_max) catch return null;
    return t.effects.dupe(tmp.items) catch null;
}

fn notify(t: *Terminal, title: []const u8, body: []const u8) void {
    if (!t.notifyAllowed()) return;
    const ti = cleanDupe(t, title) orelse return t.allocFailed();
    const bo = cleanDupe(t, body) orelse return t.allocFailed();
    t.effects.push(.{ .notify = .{ .title = ti, .body = bo } });
}

fn pointerShape(t: *Terminal, name: []const u8) void {
    if (name.len > 64) return;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return;
    const n = t.effects.dupe(name) catch return t.allocFailed();
    t.effects.push(.{ .pointer_shape = n });
}

/// Decodes base64 with ASCII whitespace ignored, padded or not. Returns
/// null for invalid input.
pub fn decodeBase64(gpa: std.mem.Allocator, src: []const u8) !?[]u8 {
    var clean: std.ArrayList(u8) = try .initCapacity(gpa, src.len);
    defer clean.deinit(gpa);
    for (src) |c| switch (c) {
        ' ', '\t', '\r', '\n' => {},
        else => clean.appendAssumeCapacity(c),
    };
    const codec = if (clean.items.len % 4 == 0) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder;
    const n = codec.calcSizeForSlice(clean.items) catch return null;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    codec.decode(out, clean.items) catch {
        gpa.free(out);
        return null;
    };
    return out;
}

/// OSC 52: `Pc ; Pd`.
fn clipboard(t: *Terminal, rest: []const u8, term: StringTerm) void {
    const pc, const pd_opt = splitFirst(rest, ';');
    const pd = pd_opt orelse return;
    var targets: effects.ClipTargets = .{};
    for (pc) |c| switch (c) {
        'c' => targets.c = true,
        'p' => targets.p = true,
        'q' => targets.q = true,
        's' => targets.s = true,
        '0'...'7' => targets.cut |= @as(u8, 1) << @intCast(c - '0'),
        else => {},
    };
    if (pc.len == 0) {
        targets.s = true;
        targets.cut = 1;
    }
    if (std.mem.eql(u8, pd, "?")) {
        t.clip_read = term;
        t.effects.push(.{ .clipboard_read = .{ .targets = targets, .data = null, .term = term } });
        return;
    }
    // The decoded size is at most 3/4 of the encoded size.
    if (pd.len / 4 * 3 > t.opts.clipboard_max) return;
    const decoded = (decodeBase64(t.gpa, pd) catch return t.allocFailed()) orelse return;
    defer t.gpa.free(decoded);
    if (decoded.len > t.opts.clipboard_max) return;
    const d = t.effects.dupe(decoded) catch return t.allocFailed();
    t.effects.push(.{ .clipboard_write = .{ .targets = targets, .data = d, .term = term } });
}

/// Undoes VS Code command-line escaping (`\\`, `\xHH`).
fn unescapeCommand(out: []u8, s: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) : (n += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            if (s[i + 1] == '\\') {
                out[n] = '\\';
                i += 2;
                continue;
            }
            if (s[i + 1] == 'x' and i + 3 < s.len) {
                if (std.fmt.parseInt(u8, s[i + 2 .. i + 4], 16)) |b| {
                    out[n] = b;
                    i += 4;
                    continue;
                } else |_| {}
            }
        }
        out[n] = s[i];
        i += 1;
    }
    return out[0..n];
}

/// OSC 133 (FinalTerm) and OSC 633 (VS Code) marks.
fn shellMark(t: *Terminal, rest: []const u8, vscode: bool) void {
    if (rest.len == 0) return;
    const letter, const tail = splitFirst(rest, ';');
    if (letter.len != 1) return;
    switch (letter[0]) {
        'A' => {
            var o: mark.PromptOpts = .{};
            var it = std.mem.splitScalar(u8, tail orelse "", ';');
            while (it.next()) |kv| {
                if (std.mem.startsWith(u8, kv, "aid=")) o.aid = kv[4..];
                if (std.mem.eql(u8, kv, "k=c")) o.kind = .continuation;
                if (std.mem.eql(u8, kv, "k=s")) o.kind = .secondary;
                if (std.mem.eql(u8, kv, "k=r")) o.kind = .right;
            }
            t.emitMark(.{ .prompt_start = o });
        },
        'B' => t.emitMark(.input_start),
        'C' => t.emitMark(.command_executed),
        'D' => {
            const code_s, _ = splitFirst(tail orelse "", ';');
            t.emitMark(.{ .command_finished = std.fmt.parseInt(i32, code_s, 10) catch null });
        },
        'E' => if (vscode) {
            const cmd, const nonce = splitFirst(tail orelse "", ';');
            var buf: [4096]u8 = undefined;
            const trusted = if (t.opts.shell_nonce) |want| if (nonce) |got| std.mem.eql(u8, want, got) else false else false;
            t.emitMark(.{ .command_line = .{ .text = unescapeCommand(&buf, cmd), .trusted = trusted } });
        },
        'P' => if (vscode) {
            const key, const value = splitFirst(tail orelse "", '=');
            t.emitMark(.{ .property = .{ .key = key, .value = value orelse "" } });
        },
        else => {},
    }
}

/// OSC 1337 (iTerm2): CurrentDir, SetUserVar, SetMark. File= arrives with
/// graphics (E06.F08).
fn iterm(t: *Terminal, rest: []const u8) void {
    if (std.mem.startsWith(u8, rest, "CurrentDir=")) {
        reportCwd(t, "", rest["CurrentDir=".len..]);
    } else if (std.mem.startsWith(u8, rest, "SetUserVar=")) {
        const key, const b64 = splitFirst(rest["SetUserVar=".len..], '=');
        if (key.len == 0) return;
        const value = (decodeBase64(t.gpa, b64 orelse "") catch return t.allocFailed()) orelse return;
        defer t.gpa.free(value);
        t.setUserVar(key, value) catch return;
        const k = t.effects.dupe(key) catch return t.allocFailed();
        const v = t.effects.dupe(value) catch return t.allocFailed();
        t.effects.push(.{ .user_var = .{ .key = k, .value = v } });
    } else if (std.mem.eql(u8, rest, "SetMark")) {
        t.emitMark(.bookmark);
    }
}
