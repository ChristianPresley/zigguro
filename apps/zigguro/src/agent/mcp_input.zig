//! `McpInputDialogs`: the IDE's `zg_mcp` `InputBroker`. When an MCP server
//! asks for user input in the middle of a call (E11.F03.S03), a modal
//! dialog names the server and the tool, prompt or resource it is working
//! on, shows the server's message and:
//!
//! - form elicitation: a field per schema property (text, number,
//!   integer, a yes/no box, or a choice for `enum`/`oneOf`), required
//!   ones marked; Submit accepts with the values, Decline declines and
//!   Escape cancels. A field named like a secret (password, token, API
//!   key) puts a warning on top;
//! - URL elicitation: the link, with its host shown on its own so the
//!   user sees where it goes; Continue accepts (the user opens it),
//!   Decline declines.
//!
//! `roots/list` is answered without asking (the working folder);
//! sampling is not offered. `resolve` runs on a worker: it posts the
//! dialog to the UI thread and waits for the answer or the call's cancel
//! token. Requests and answers live in an arena owned by the dialogs, so
//! they stay valid until `deinit` (input requests are rare and small).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_mcp = @import("zg_mcp");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const controls = zg_gui.w.controls;
const overlay = zg_gui.w.overlay;
const TextBuffer = zg_gui.w.TextBuffer;
const input = zg_mcp.client.input;
const M = zg_mcp.protocol.messages;

/// One schema property.
const Field = struct {
    key: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
    kind: Kind,
    required: bool = false,
    /// `choice`: the values sent and their labels.
    values: []const []const u8 = &.{},
    labels: []const []const u8 = &.{},
    picked: ?usize = null,
    flag: bool = false,
    /// UI thread only (text kinds).
    buf: ?TextBuffer = null,
    default_text: []const u8 = "",

    const Kind = enum { text, number, integer, boolean, choice };
};

/// One request, from `present` until `deinit`.
pub const Pending = struct {
    dialogs: *McpInputDialogs,
    server: []const u8,
    origin: ?[]const u8,
    message: []const u8,
    url: ?[]const u8,
    fields: []Field,
    answer: ?M.ElicitResult = null,
    done: std.Io.Event = .unset,
    overlay: overlay.OverlayId = .none,
    /// The last Submit's problem, shown above the buttons.
    problem: ?[]const u8 = null,

    pub fn build(p: *Pending, ui: *Ui) void {
        const th = ui.theme();
        ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_md) } });
        defer ui.close();
        if (p.origin) |o| {
            ui.textf("MCP server {s}, while running {s}", .{ p.server, o }, .{ .color = .fg_muted });
        } else ui.textf("MCP server {s}", .{p.server}, .{ .color = .fg_muted });
        ui.text(p.message, .{});
        if (p.url) |u| {
            ui.textf("Opens {s}", .{hostOf(u)}, .{ .style = .{ .font = .mono } });
            ui.open(.{ .style = .{ .padding = .xy(8, 6), .bg = .{ .token = .bg_base } } });
            ui.text(u, .{ .style = .{ .font = .mono } });
            ui.close();
        }
        for (p.fields) |f| if (looksSensitive(f.key) or looksSensitive(f.label)) {
            ui.text("\u{26a0} This asks for something secret. MCP servers must not ask for passwords or keys in a form.", .{ .color = .warning });
            break;
        };
        for (p.fields) |*f| p.field(ui, f);
        if (p.problem) |msg| ui.text(msg, .{ .color = .danger });

        ui.open(.{ .style = .{ .gap = th.dim(.space_sm), .justify = .end } });
        defer ui.close();
        if (controls.button(ui, .{ .label = "Decline", .variant = .danger }).clicked) p.finish(.{ .action = .decline });
        controls.spacer(ui);
        if (p.url != null) {
            if (controls.button(ui, .{ .label = "Continue", .variant = .primary }).clicked) p.finish(.{ .action = .accept });
        } else if (controls.button(ui, .{ .label = "Submit", .variant = .primary }).clicked) p.submit();
    }

    fn field(p: *Pending, ui: *Ui, f: *Field) void {
        _ = p;
        ui.open(.{ .style = .{ .dir = .column, .gap = 2 } });
        defer ui.close();
        if (f.kind != .boolean) ui.textf("{s}{s}", .{ f.label, if (f.required) " *" else "" }, .{});
        switch (f.kind) {
            .boolean => _ = controls.checkbox(ui, f.label, &f.flag),
            .choice => {
                ui.open(.{ .style = .{ .dir = .row, .gap = 4, .wrap = true } });
                defer ui.close();
                for (f.labels, 0..) |l, i| {
                    ui.id(i);
                    const on = f.picked == i;
                    if (controls.button(ui, .{ .label = l, .variant = if (on) .primary else .ghost }).clicked) f.picked = i;
                }
            },
            .text, .number, .integer => if (f.buf) |*b| {
                _ = zg_gui.w.textField(ui, .{ .buffer = b, .a11y_label = f.label });
            },
        }
        if (f.description) |d| ui.text(d, .{ .color = .fg_muted });
    }

    /// Checks the fields and accepts with their values.
    fn submit(p: *Pending) void {
        const d = p.dialogs;
        d.mutex.lockUncancelable(d.io);
        const vals = p.values(d.arena.allocator()) catch |e| {
            d.mutex.unlock(d.io);
            p.problem = switch (e) {
                error.Missing => "Fill in the required fields (marked *).",
                error.NotANumber => "A number field holds something else.",
                error.OutOfMemory => "Out of memory.",
            };
            return;
        };
        d.mutex.unlock(d.io);
        p.finish(.{ .action = .accept, .content = vals });
    }

    fn values(p: *Pending, a: Allocator) error{ Missing, NotANumber, OutOfMemory }!Value {
        var obj: std.json.ObjectMap = .empty;
        for (p.fields) |*f| {
            const v: ?Value = switch (f.kind) {
                .boolean => .{ .bool = f.flag },
                .choice => if (f.picked) |i| .{ .string = try a.dupe(u8, f.values[i]) } else null,
                .text, .number, .integer => blk: {
                    const raw = std.mem.trim(u8, if (f.buf) |*b| b.slice() else "", " \t");
                    if (raw.len == 0) break :blk null;
                    break :blk switch (f.kind) {
                        .number => .{ .float = std.fmt.parseFloat(f64, raw) catch return error.NotANumber },
                        .integer => .{ .integer = std.fmt.parseInt(i64, raw, 10) catch return error.NotANumber },
                        else => .{ .string = try a.dupe(u8, raw) },
                    };
                },
            };
            if (v) |x| {
                try obj.put(a, f.key, x);
            } else if (f.required) return error.Missing;
        }
        return .{ .object = obj };
    }

    /// Records `r`, wakes `wait` and closes the dialog. UI thread.
    fn finish(p: *Pending, r: M.ElicitResult) void {
        const d = p.dialogs;
        {
            d.mutex.lockUncancelable(d.io);
            defer d.mutex.unlock(d.io);
            if (p.answer != null) return;
            p.answer = r;
        }
        p.done.set(d.io);
        if (p.overlay != .none) d.win.closeOverlay(p.overlay);
    }

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const p: *Pending = @ptrCast(@alignCast(ctx));
        p.overlay = .none;
        // Escape or the window closing.
        p.finish(.{ .action = .cancel });
    }
};

/// See the module doc. Must not move after `init`.
pub const McpInputDialogs = struct {
    gpa: Allocator,
    io: std.Io,
    win: *Window,
    /// The working folder, answered to `roots/list` (borrowed).
    root: []const u8,
    /// Guards `arena`, `pending` and every `Pending.answer`.
    mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    pending: std.ArrayList(*Pending) = .empty,

    pub fn init(gpa: Allocator, io: std.Io, win: *Window, root: []const u8) McpInputDialogs {
        return .{ .gpa = gpa, .io = io, .win = win, .root = root, .arena = .init(gpa) };
    }

    /// Closes open dialogs and frees every request. UI thread; no call may
    /// still be waiting.
    pub fn deinit(d: *McpInputDialogs) void {
        for (d.pending.items) |p| if (p.overlay != .none) d.win.closeOverlay(p.overlay);
        for (d.pending.items) |p| for (p.fields) |*f| if (f.buf) |*b| b.deinit();
        d.pending.deinit(d.gpa);
        d.arena.deinit();
    }

    /// For `zg_mcp_servers.Servers.broker`.
    pub fn broker(d: *McpInputDialogs) input.InputBroker {
        return .{ .ctx = d, .resolve = resolve };
    }

    /// Requests not answered yet.
    pub fn openCount(d: *McpInputDialogs) usize {
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        var n: usize = 0;
        for (d.pending.items) |p| n += @intFromBool(p.answer == null);
        return n;
    }

    fn resolve(ctx: ?*anyopaque, ic: input.InputContext, req: input.InputRequest, arena: Allocator) anyerror!input.InputResponse {
        const d: *McpInputDialogs = @ptrCast(@alignCast(ctx.?));
        return switch (req) {
            .roots => .{ .roots = .{ .roots = try d.roots(arena) } },
            .sampling => .{ .failed = "zigguro does not offer sampling to MCP servers" },
            .unknown => .{ .failed = "unsupported input request" },
            .elicitation => |e| blk: {
                const p = try d.present(ic, e);
                break :blk .{ .elicitation = d.wait(p, ic.cancel) };
            },
        };
    }

    /// The working folder as a `file:` root.
    fn roots(d: *McpInputDialogs, a: Allocator) ![]const M.Root {
        var uri: std.ArrayList(u8) = .empty;
        try uri.appendSlice(a, "file://");
        if (d.root.len > 0 and d.root[0] != '/') try uri.append(a, '/');
        for (d.root) |c| switch (c) {
            '\\' => try uri.append(a, '/'),
            ' ' => try uri.appendSlice(a, "%20"),
            '%' => try uri.appendSlice(a, "%25"),
            '#' => try uri.appendSlice(a, "%23"),
            '?' => try uri.appendSlice(a, "%3F"),
            else => try uri.append(a, c),
        };
        const out = try a.alloc(M.Root, 1);
        out[0] = .{ .uri = uri.items, .name = std.fs.path.basename(d.root) };
        return out;
    }

    /// Copies `e` and posts its dialog (any thread).
    pub fn present(d: *McpInputDialogs, ic: input.InputContext, e: M.ElicitParams) !*Pending {
        const p = blk: {
            d.mutex.lockUncancelable(d.io);
            defer d.mutex.unlock(d.io);
            const a = d.arena.allocator();
            const p = try a.create(Pending);
            p.* = .{
                .dialogs = d,
                .server = try a.dupe(u8, ic.server_id),
                .origin = if (ic.origin_name) |n| try a.dupe(u8, n) else null,
                .message = try a.dupe(u8, e.message),
                .url = if (e.kind() == .url) try a.dupe(u8, e.url orelse "") else null,
                .fields = if (e.kind() == .form) try fieldsOf(a, e.requested_schema) else &.{},
            };
            try d.pending.append(d.gpa, p);
            break :blk p;
        };
        try d.win.app.post(.{ .ctx = p, .f = openOnUi });
        return p;
    }

    /// Blocks until `p` is answered or `cancel` fires (then the dialog
    /// closes and the answer is `cancel`).
    pub fn wait(d: *McpInputDialogs, p: *Pending, cancel: ?*zg_mcp.client.request.CancelToken) M.ElicitResult {
        while (!p.done.isSet()) {
            if (cancel) |c| if (c.isCanceled()) {
                d.mutex.lockUncancelable(d.io);
                const first = p.answer == null;
                if (first) p.answer = .{ .action = .cancel };
                d.mutex.unlock(d.io);
                if (first) {
                    p.done.set(d.io);
                    d.win.app.post(.{ .ctx = p, .f = closeOnUi }) catch {};
                }
                break;
            };
            d.io.sleep(.fromMilliseconds(20), .awake) catch break;
        }
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        return p.answer orelse .{ .action = .cancel };
    }

    fn openOnUi(ctx: *anyopaque, _: *zg_gui.App) void {
        const p: *Pending = @ptrCast(@alignCast(ctx));
        const d = p.dialogs;
        if (p.answer != null) return; // cancelled before it showed
        for (p.fields) |*f| switch (f.kind) {
            .text, .number, .integer => f.buf = TextBuffer.init(d.gpa, f.default_text) catch null,
            else => {},
        };
        var title_buf: [128]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} asks for input", .{p.server}) catch "An MCP server asks for input";
        p.overlay = d.win.openOverlay(.of(p), .{
            .layer = .dialog,
            .modal = true,
            .light_dismiss = false,
            .title = title,
            .label = title,
            .test_id = "mcp-input",
            .width = zg_gui.w.dialog.DialogSize.md.width(d.win.size.w),
            .on_close = .{ .ctx = p, .f = Pending.onClose },
        }) catch {
            p.finish(.{ .action = .cancel });
            return;
        };
    }

    fn closeOnUi(ctx: *anyopaque, _: *zg_gui.App) void {
        const p: *Pending = @ptrCast(@alignCast(ctx));
        if (p.overlay != .none) p.dialogs.win.closeOverlay(p.overlay);
    }
};

/// The fields of a form schema (`properties` in order, `required`).
fn fieldsOf(a: Allocator, schema: ?Value) Allocator.Error![]Field {
    const s = schema orelse return &.{};
    if (s != .object) return &.{};
    const props = s.object.get("properties") orelse return &.{};
    if (props != .object) return &.{};
    var out: std.ArrayList(Field) = .empty;
    for (props.object.keys(), props.object.values()) |key, v| {
        if (v != .object) continue;
        const o = v.object;
        var f: Field = .{ .key = try a.dupe(u8, key), .label = try a.dupe(u8, str(o, "title") orelse key), .kind = .text };
        if (str(o, "description")) |dsc| f.description = try a.dupe(u8, dsc);
        const ty = str(o, "type") orelse "string";
        if (std.mem.eql(u8, ty, "boolean")) {
            f.kind = .boolean;
            if (o.get("default")) |dv| if (dv == .bool) {
                f.flag = dv.bool;
            };
        } else if (std.mem.eql(u8, ty, "number")) {
            f.kind = .number;
        } else if (std.mem.eql(u8, ty, "integer")) {
            f.kind = .integer;
        } else if (try choices(a, o, &f)) {
            f.kind = .choice;
        }
        if (f.kind != .boolean and f.kind != .choice) if (o.get("default")) |dv| {
            f.default_text = switch (dv) {
                .string => |x| try a.dupe(u8, x),
                .integer => |x| try std.fmt.allocPrint(a, "{d}", .{x}),
                .float => |x| try std.fmt.allocPrint(a, "{d}", .{x}),
                else => "",
            };
        };
        try out.append(a, f);
    }
    if (s.object.get("required")) |r| if (r == .array) for (r.array.items) |k| {
        if (k != .string) continue;
        for (out.items) |*f| if (std.mem.eql(u8, f.key, k.string)) {
            f.required = true;
        };
    };
    return out.items;
}

/// `enum` (with `enumNames`) or `oneOf` of `{const, title}`.
fn choices(a: Allocator, o: std.json.ObjectMap, f: *Field) Allocator.Error!bool {
    var values: std.ArrayList([]const u8) = .empty;
    var labels: std.ArrayList([]const u8) = .empty;
    if (o.get("enum")) |e| if (e == .array) {
        const names = if (o.get("enumNames")) |n| (if (n == .array) n.array.items else &.{}) else &.{};
        for (e.array.items, 0..) |x, i| if (x == .string) {
            try values.append(a, try a.dupe(u8, x.string));
            const l = if (i < names.len and names[i] == .string) names[i].string else x.string;
            try labels.append(a, try a.dupe(u8, l));
        };
    };
    if (values.items.len == 0) if (o.get("oneOf")) |e| if (e == .array) for (e.array.items) |x| {
        if (x != .object) continue;
        const c = str(x.object, "const") orelse continue;
        try values.append(a, try a.dupe(u8, c));
        try labels.append(a, try a.dupe(u8, str(x.object, "title") orelse c));
    };
    if (values.items.len == 0) return false;
    f.values = values.items;
    f.labels = labels.items;
    if (str(o, "default")) |dv| for (f.values, 0..) |v, i| if (std.mem.eql(u8, v, dv)) {
        f.picked = i;
    };
    return true;
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// A field name that suggests a secret (password, token, key, card).
fn looksSensitive(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(name.len, buf.len);
    const low = std.ascii.lowerString(buf[0..n], name[0..n]);
    const words = [_][]const u8{ "pass", "secret", "token", "apikey", "api_key", "api key", "api-key", "private key", "private_key", "credit", "cvv", "ssn" };
    for (words) |w| if (std.mem.indexOf(u8, low, w) != null) return true;
    return false;
}

/// The host of `url` (the whole text when it has none).
fn hostOf(url: []const u8) []const u8 {
    const rest = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else return url;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..end];
    // Credentials before an @ are not the host.
    return if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host[at + 1 ..] else host;
}

// -- tests ----------------------------------------------------------------------

const testing = std.testing;
const TestApp = zg_gui.testing.TestApp;

const Blank = struct {
    pub fn build(_: *Blank, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        ui.close();
    }
};

fn context(token: *zg_mcp.client.request.CancelToken) input.InputContext {
    return .{ .server_id = "github", .server_info = null, .origin_method = .tools_call, .origin_name = "create_issue", .principal = .agent, .key = "e1", .cancel = token };
}

test "mcp input: a form names the server and sends typed values" {
    const gpa = testing.allocator;
    const io = testing.io;
    var blank: Blank = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&blank), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    var d: McpInputDialogs = .init(gpa, io, t.win, "/work/repo");
    defer d.deinit();
    var token: zg_mcp.client.request.CancelToken = .init(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const schema = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"type":"object","properties":{
        \\  "title":{"type":"string","title":"Title"},
        \\  "count":{"type":"integer","title":"Count"},
        \\  "urgent":{"type":"boolean","title":"Urgent"},
        \\  "repo":{"type":"string","title":"Repository","enum":["a","b"],"enumNames":["Alpha","Beta"]}},
        \\ "required":["title","repo"]}
    , .{});
    const p = try d.present(context(&token), .{ .message = "Describe the issue", .requested_schema = schema });
    _ = t.settle();
    try testing.expect(t.find(.{ .test_id = "mcp-input" }) != null);
    try testing.expect(t.find(.{ .name = "MCP server github, while running create_issue" }) != null);
    // Required fields are checked.
    try t.click(.{ .role = .button, .name = "Submit" });
    try testing.expect(t.find(.{ .test_id = "mcp-input" }) != null);
    try testing.expectEqual(@as(usize, 1), d.openCount());

    try t.click(.{ .role = .textbox, .name = "Title" });
    t.typeText("Crash on save");
    try t.click(.{ .role = .textbox, .name = "Count" });
    t.typeText("3");
    try t.click(.{ .name = "Urgent" });
    try t.click(.{ .role = .button, .name = "Beta" });
    try t.click(.{ .role = .button, .name = "Submit" });
    try testing.expect(t.find(.{ .test_id = "mcp-input" }) == null);
    const r = d.wait(p, &token);
    try testing.expectEqual(M.ElicitResult.Action.accept, r.action);
    const c = r.content.?.object;
    try testing.expectEqualStrings("Crash on save", c.get("title").?.string);
    try testing.expectEqual(@as(i64, 3), c.get("count").?.integer);
    try testing.expect(c.get("urgent").?.bool);
    try testing.expectEqualStrings("b", c.get("repo").?.string);
}

test "mcp input: decline, Escape cancels, a cancelled call closes the dialog" {
    const gpa = testing.allocator;
    const io = testing.io;
    var blank: Blank = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&blank), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    var d: McpInputDialogs = .init(gpa, io, t.win, "/work/repo");
    defer d.deinit();
    var token: zg_mcp.client.request.CancelToken = .init(io);

    var p = try d.present(context(&token), .{ .mode = .url, .message = "Sign in", .url = "https://user@auth.example.com/login?x=1" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name = "Opens auth.example.com" }) != null);
    try t.click(.{ .role = .button, .name = "Decline" });
    try testing.expectEqual(M.ElicitResult.Action.decline, d.wait(p, &token).action);

    p = try d.present(context(&token), .{ .message = "Name?" });
    _ = t.settle();
    t.press(.escape, .{});
    try testing.expectEqual(M.ElicitResult.Action.cancel, d.wait(p, &token).action);

    p = try d.present(context(&token), .{ .message = "Name?" });
    _ = t.settle();
    token.cancel(null);
    try testing.expectEqual(M.ElicitResult.Action.cancel, d.wait(p, &token).action);
    _ = t.settle();
    try testing.expect(t.find(.{ .test_id = "mcp-input" }) == null);
}

test "mcp input: roots answer the working folder without a dialog" {
    const gpa = testing.allocator;
    const io = testing.io;
    var blank: Blank = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&blank), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    var d: McpInputDialogs = .init(gpa, io, t.win, "/work/my repo");
    defer d.deinit();
    var token: zg_mcp.client.request.CancelToken = .init(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const b = d.broker();
    const r = try b.resolve(b.ctx, context(&token), .{ .roots = .{} }, arena.allocator());
    try testing.expectEqualStrings("file:///work/my%20repo", r.roots.roots[0].uri);
    try testing.expectEqualStrings("my repo", r.roots.roots[0].name.?);
    const s = try b.resolve(b.ctx, context(&token), .{ .sampling = .{ .messages = &.{}, .max_tokens = 1 } }, arena.allocator());
    try testing.expect(s == .failed);
    try testing.expect(looksSensitive("GitHub Token") and looksSensitive("api_key") and !looksSensitive("Title"));
    try testing.expectEqual(@as(usize, 0), d.openCount());
}
