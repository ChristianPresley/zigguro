//! `McpInputDialogs`: the IDE's `zg_mcp` `InputBroker`. When an MCP server
//! asks for user input in the middle of a call (E11.F03.S03), a modal
//! dialog names the server and the tool, prompt or resource it is working
//! on, shows the server's message and renders the request through
//! `zg_mcp`'s headless models:
//!
//! - form elicitation (`FormModel`): a field per schema property (text,
//!   number, integer, a yes/no box, a choice, or several choices), with
//!   the schema's defaults, required ones marked; Submit validates the
//!   values against the schema (errors under their fields) and accepts,
//!   Decline declines and Escape cancels. When the model flags a field as
//!   a secret a warning goes on top. A schema the model doesn't support
//!   is declined without a dialog;
//! - URL elicitation (`UrlConsent`): the link and its host (punycode
//!   decoded, the registrable part on its own) and the model's warnings
//!   (not HTTPS, a user name before the host, an IP address, mixed
//!   alphabets, ...); Continue accepts (the user opens it), Decline
//!   declines. A link that isn't http(s) is declined without a dialog.
//!
//! `roots/list` is answered without asking (the working folder, encoded by
//! `roots.fileUri`); sampling is not offered: a request is checked by
//! `SamplingModel` only to say what is wrong with it, and declined.
//! `resolve` runs on a worker: it posts the dialog to the UI thread and
//! waits for the answer or the call's cancel token. Requests and answers
//! live in an arena owned by the dialogs, so they stay valid until
//! `deinit` (input requests are rare and small).

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
const elicit = zg_mcp.client.elicitation;
const M = zg_mcp.protocol.messages;

/// One form field's state.
const Field = struct {
    spec: *const elicit.FormField,
    /// `single_select`: the option picked.
    picked: ?usize = null,
    /// `multi_select`: one per option.
    chosen: []bool = &.{},
    flag: bool = false,
    /// UI thread only (text and number kinds).
    buf: ?TextBuffer = null,
    default_text: []const u8 = "",
    /// The last Submit's problem with this field.
    problem: ?[]const u8 = null,

    fn texty(f: *const Field) bool {
        return f.spec.kind == .string or f.spec.kind == .number;
    }

    fn placeholder(f: *const Field) []const u8 {
        return switch (f.spec.kind) {
            .string => |s| if (s.format) |fm| switch (fm) {
                .email => "name@example.com",
                .uri => "https://",
                .date => "YYYY-MM-DD",
                .date_time => "YYYY-MM-DDThh:mm:ssZ",
            } else "",
            .number => |n| if (n.integer) "A whole number" else "A number",
            else => "",
        };
    }
};

/// One request, from `present` until `deinit`.
pub const Pending = struct {
    dialogs: *McpInputDialogs,
    server: []const u8,
    origin: ?[]const u8,
    message: []const u8,
    /// Form mode (owned).
    form: ?elicit.FormModel = null,
    /// URL mode.
    consent: ?elicit.UrlConsent = null,
    fields: []Field = &.{},
    answer: ?M.ElicitResult = null,
    done: std.Io.Event = .unset,
    overlay: overlay.OverlayId = .none,
    /// The last Submit's problem not tied to a field, shown above the
    /// buttons.
    problem: ?[]const u8 = null,

    pub fn build(p: *Pending, ui: *Ui) void {
        const th = ui.theme();
        ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_md) } });
        defer ui.close();
        if (p.origin) |o| {
            ui.textf("MCP server {s}, while running {s}", .{ p.server, o }, .{ .color = .fg_muted });
        } else ui.textf("MCP server {s}", .{p.server}, .{ .color = .fg_muted });
        ui.text(p.message, .{});
        if (p.consent) |*c| {
            ui.textf("Opens {s}", .{c.host_display}, .{ .style = .{ .font = .mono } });
            if (!std.mem.eql(u8, c.registrable_hint, c.host_display))
                ui.textf("Site: {s}", .{c.registrable_hint}, .{ .color = .fg_muted });
            ui.open(.{ .style = .{ .padding = .xy(8, 6), .bg = .{ .token = .bg_base } } });
            ui.text(c.full_url, .{ .style = .{ .font = .mono } });
            ui.close();
            for (c.warnings) |w| ui.textf("\u{26a0} {s}", .{urlWarning(w)}, .{ .color = .warning });
        }
        if (p.form) |*f| if (f.looksSensitive())
            ui.text("\u{26a0} This asks for something secret. MCP servers must not ask for passwords or keys in a form.", .{ .color = .warning });
        for (p.fields, 0..) |*f, i| {
            ui.id(i);
            field(ui, f);
        }
        if (p.problem) |msg| ui.text(msg, .{ .color = .danger });

        ui.open(.{ .style = .{ .gap = th.dim(.space_sm), .justify = .end } });
        defer ui.close();
        if (controls.button(ui, .{ .label = "Decline", .variant = .danger }).clicked) p.finish(.{ .action = .decline });
        controls.spacer(ui);
        if (p.consent != null) {
            if (controls.button(ui, .{ .label = "Continue", .variant = .primary }).clicked) p.finish(.{ .action = .accept });
        } else if (controls.button(ui, .{ .label = "Submit", .variant = .primary }).clicked) {
            // Rebuilt to show the problems when the values are refused.
            if (!p.submit()) ui.window().markViewDirty(ui.currentView());
        }
    }

    fn field(ui: *Ui, f: *Field) void {
        const s = f.spec;
        ui.open(.{ .style = .{ .dir = .column, .gap = 2 } });
        defer ui.close();
        if (s.kind != .boolean) ui.textf("{s}{s}", .{ s.title, if (s.required) " *" else "" }, .{});
        switch (s.kind) {
            .boolean => _ = controls.checkbox(ui, s.title, &f.flag),
            .single_select => |opts| {
                ui.open(.{ .style = .{ .dir = .row, .gap = 4, .wrap = true } });
                defer ui.close();
                for (opts, 0..) |o, i| {
                    ui.id(i);
                    const on = f.picked == i;
                    if (controls.button(ui, .{ .label = o.label, .variant = if (on) .primary else .ghost }).clicked and !on) {
                        f.picked = i;
                        ui.window().markViewDirty(ui.currentView());
                    }
                }
            },
            .multi_select => |ms| {
                ui.open(.{ .style = .{ .dir = .row, .gap = 8, .wrap = true } });
                defer ui.close();
                for (ms.options, f.chosen, 0..) |o, *on, i| {
                    ui.id(i);
                    _ = controls.checkbox(ui, o.label, on);
                }
            },
            .string, .number => if (f.buf) |*b| {
                _ = zg_gui.w.textField(ui, .{ .buffer = b, .a11y_label = s.title, .placeholder = f.placeholder() });
            },
        }
        if (s.description) |d| ui.text(d, .{ .color = .fg_muted });
        if (f.problem) |msg| ui.text(msg, .{ .color = .danger });
    }

    /// Checks the fields and accepts with their values; false when they
    /// were refused.
    fn submit(p: *Pending) bool {
        const d = p.dialogs;
        const vals = blk: {
            d.mutex.lockUncancelable(d.io);
            defer d.mutex.unlock(d.io);
            break :blk p.check(d.arena.allocator());
        } orelse return false;
        p.finish(.{ .action = .accept, .content = vals });
        return true;
    }

    /// The values when the schema takes them; otherwise null with the
    /// problems recorded. Holds the mutex.
    fn check(p: *Pending, a: Allocator) ?Value {
        p.problem = null;
        for (p.fields) |*f| f.problem = null;
        const vals = p.values(a) catch |e| {
            p.problem = switch (e) {
                error.Invalid => "Fix the fields marked below.",
                error.OutOfMemory => "Out of memory.",
            };
            return null;
        };
        const form = &(p.form orelse return vals);
        const gpa = p.dialogs.gpa;
        var out: zg_mcp.schema.Output = .init(gpa);
        defer out.deinit();
        if (form.validate(gpa, vals, &out)) return vals;
        for (out.errors.items) |e| {
            const msg = a.dupe(u8, e.message) catch continue;
            if (p.fieldAt(e.instance_location)) |f| {
                if (f.problem == null) f.problem = msg;
            } else if (p.problem == null) p.problem = msg;
        }
        if (p.problem == null) p.problem = "Fix the fields marked below.";
        return null;
    }

    /// The field an instance location (`/key/...`) points into.
    fn fieldAt(p: *Pending, loc: []const u8) ?*Field {
        if (loc.len < 2 or loc[0] != '/') return null;
        const rest = loc[1..];
        const key = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        for (p.fields) |*f| if (std.mem.eql(u8, f.spec.key, key)) return f;
        return null;
    }

    /// The object the form sends: empty optional fields are left out, a
    /// missing required one or a bad number is marked on its field.
    fn values(p: *Pending, a: Allocator) error{ Invalid, OutOfMemory }!Value {
        var obj: std.json.ObjectMap = .empty;
        var bad = false;
        for (p.fields) |*f| {
            const v: ?Value = switch (f.spec.kind) {
                .boolean => .{ .bool = f.flag },
                .single_select => |opts| if (f.picked) |i| .{ .string = opts[i].value } else null,
                .multi_select => |ms| blk: {
                    var arr: std.json.Array = .init(a);
                    for (ms.options, f.chosen) |o, on| if (on) try arr.append(.{ .string = o.value });
                    break :blk if (arr.items.len > 0 or f.spec.required) .{ .array = arr } else null;
                },
                .string, .number => blk: {
                    const raw = std.mem.trim(u8, if (f.buf) |*b| b.slice() else "", " \t");
                    if (raw.len == 0) break :blk null;
                    break :blk switch (f.spec.kind) {
                        .number => |n| if (n.integer)
                            .{ .integer = std.fmt.parseInt(i64, raw, 10) catch {
                                f.problem = "Enter a whole number.";
                                bad = true;
                                continue;
                            } }
                        else
                            .{ .float = std.fmt.parseFloat(f64, raw) catch {
                                f.problem = "Enter a number.";
                                bad = true;
                                continue;
                            } },
                        else => .{ .string = try a.dupe(u8, raw) },
                    };
                },
            };
            if (v) |x| {
                try obj.put(a, f.spec.key, x);
            } else if (f.spec.required) {
                f.problem = "Required.";
                bad = true;
            }
        }
        if (bad) return error.Invalid;
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
        for (d.pending.items) |p| {
            for (p.fields) |*f| if (f.buf) |*b| b.deinit();
            if (p.form) |*m| m.deinit();
        }
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
            .sampling => |s| .{ .failed = try samplingRefusal(arena, s) },
            .unknown => .{ .failed = "unsupported input request" },
            .elicitation => |e| blk: {
                const p = d.present(ic, e) catch |err| switch (err) {
                    // Nothing the dialog can show.
                    error.UnsupportedSchema, error.InvalidUrl, error.UnsupportedScheme => break :blk .{ .elicitation = .{ .action = .decline } },
                    else => return err,
                };
                break :blk .{ .elicitation = d.wait(p, ic.cancel) };
            },
        };
    }

    /// The working folder as a `file:` root (none when it isn't
    /// absolute).
    fn roots(d: *McpInputDialogs, a: Allocator) ![]const M.Root {
        const uri = zg_mcp.client.roots.fileUri(a, d.root) catch |e| switch (e) {
            error.NotAbsolute => return &.{},
            error.OutOfMemory => return error.OutOfMemory,
        };
        const out = try a.alloc(M.Root, 1);
        out[0] = .{ .uri = uri, .name = std.fs.path.basename(d.root) };
        return out;
    }

    /// For a client that takes a `RootsProvider` of its own.
    pub fn rootsProvider(d: *McpInputDialogs) zg_mcp.client.RootsProvider {
        const F = struct {
            fn list(ctx: ?*anyopaque, arena: Allocator) anyerror![]const M.Root {
                const dd: *McpInputDialogs = @ptrCast(@alignCast(ctx.?));
                return dd.roots(arena);
            }
        };
        return .{ .ctx = d, .list = F.list };
    }

    /// Compiles `e` into its model, copies it and posts its dialog (any
    /// thread). A form schema or a link the models reject is an error.
    pub fn present(d: *McpInputDialogs, ic: input.InputContext, e: M.ElicitParams) !*Pending {
        var form: ?elicit.FormModel = if (e.kind() == .form) try elicit.FormModel.fromRequest(d.gpa, e) else null;
        errdefer if (form) |*m| m.deinit();
        const p = blk: {
            d.mutex.lockUncancelable(d.io);
            defer d.mutex.unlock(d.io);
            const a = d.arena.allocator();
            const consent: ?elicit.UrlConsent = if (e.kind() == .url) try elicit.UrlConsent.fromRequest(a, e.url orelse "") else null;
            const p = try a.create(Pending);
            p.* = .{
                .dialogs = d,
                .server = try a.dupe(u8, ic.server_id),
                .origin = if (ic.origin_name) |n| try a.dupe(u8, n) else null,
                .message = try a.dupe(u8, e.message),
                .consent = consent,
            };
            if (form) |*m| p.fields = try fieldsOf(a, m);
            try d.pending.append(d.gpa, p);
            p.form = form;
            break :blk p;
        };
        form = null;
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
        for (p.fields) |*f| if (f.texty()) {
            f.buf = TextBuffer.init(d.gpa, f.default_text) catch null;
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

/// The UI state of `m`'s fields, set to their defaults.
fn fieldsOf(a: Allocator, m: *const elicit.FormModel) Allocator.Error![]Field {
    const out = try a.alloc(Field, m.fields.len);
    for (m.fields, out) |*spec, *f| {
        f.* = .{ .spec = spec };
        const dv = spec.default;
        switch (spec.kind) {
            .boolean => f.flag = dv != null and dv.? == .bool and dv.?.bool,
            .single_select => |opts| if (dv) |v| if (v == .string) {
                for (opts, 0..) |o, i| if (std.mem.eql(u8, o.value, v.string)) {
                    f.picked = i;
                };
            },
            .multi_select => |ms| {
                f.chosen = try a.alloc(bool, ms.options.len);
                @memset(f.chosen, false);
                if (dv) |v| if (v == .array) for (v.array.items) |x| if (x == .string) {
                    for (ms.options, f.chosen) |o, *on| if (std.mem.eql(u8, o.value, x.string)) {
                        on.* = true;
                    };
                };
            },
            .string, .number => if (dv) |v| {
                f.default_text = switch (v) {
                    .string => |x| x,
                    .integer => |x| try std.fmt.allocPrint(a, "{d}", .{x}),
                    .float => |x| try std.fmt.allocPrint(a, "{d}", .{x}),
                    .number_string => |x| x,
                    else => "",
                };
            },
        }
    }
    return out;
}

/// What a URL warning means to the user.
fn urlWarning(w: elicit.UrlWarning) []const u8 {
    return switch (w) {
        .not_https => "The link is not encrypted (http, not https).",
        .punycode => "The address uses international characters, shown decoded.",
        .ip_literal => "The link goes to a bare IP address, not a named site.",
        .userinfo_present => "The link has a user name before the host, which can disguise where it goes.",
        .very_long => "The link is unusually long.",
        .mixed_scripts => "The address mixes alphabets, which can imitate another site.",
    };
}

/// Why a sampling request is refused: the problems `SamplingModel` finds,
/// or that zigguro doesn't offer sampling.
fn samplingRefusal(a: Allocator, s: M.CreateMessageParams) Allocator.Error![]const u8 {
    const m = try zg_mcp.client.SamplingModel.fromRequest(a, s, false, false);
    if (m.issues.len == 0) return "zigguro does not offer sampling to MCP servers";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "invalid sampling request: ");
    for (m.issues, 0..) |is, i| {
        if (i > 0) try out.appendSlice(a, "; ");
        try out.appendSlice(a, is);
    }
    return out.items;
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

/// A form with no fields.
fn emptyForm(a: Allocator) !Value {
    return std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"object\"}", .{});
}

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
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var p = try d.present(context(&token), .{ .mode = .url, .message = "Sign in", .url = "https://user@auth.example.com/login?x=1" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name = "Opens auth.example.com" }) != null);
    try testing.expect(t.find(.{ .name_contains = comptime urlWarning(.userinfo_present) }) != null);
    try t.click(.{ .role = .button, .name = "Decline" });
    try testing.expectEqual(M.ElicitResult.Action.decline, d.wait(p, &token).action);

    p = try d.present(context(&token), .{ .message = "Name?", .requested_schema = try emptyForm(arena.allocator()) });
    _ = t.settle();
    t.press(.escape, .{});
    try testing.expectEqual(M.ElicitResult.Action.cancel, d.wait(p, &token).action);

    p = try d.present(context(&token), .{ .message = "Name?", .requested_schema = try emptyForm(arena.allocator()) });
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
    // Sampling is refused, saying what is wrong with the request.
    const s = try b.resolve(b.ctx, context(&token), .{ .sampling = .{ .messages = &.{}, .max_tokens = 1 } }, arena.allocator());
    try testing.expectEqualStrings("invalid sampling request: messages is empty", s.failed);
    try testing.expectEqual(@as(usize, 0), d.openCount());
    const rp = d.rootsProvider();
    try testing.expectEqualStrings("file:///work/my%20repo", (try rp.list(rp.ctx, arena.allocator()))[0].uri);
}

test "mcp input: the schema checks values, defaults fill the form, secrets warn" {
    const gpa = testing.allocator;
    const io = testing.io;
    var blank: Blank = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&blank), .size = .{ .w = 800, .h = 700 } });
    defer t.deinit();
    var d: McpInputDialogs = .init(gpa, io, t.win, "/work/repo");
    defer d.deinit();
    var token: zg_mcp.client.request.CancelToken = .init(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const schema = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"type":"object","properties":{
        \\  "email":{"type":"string","title":"Email","format":"email"},
        \\  "api_token":{"type":"string","title":"API token","minLength":4,"default":"ab"},
        \\  "labels":{"type":"array","title":"Labels","items":{"type":"string","enum":["bug","ui"]},"default":["ui"]},
        \\  "size":{"type":"string","title":"Size","oneOf":[{"const":"s","title":"Small"},{"const":"l","title":"Large"}],"default":"l"}},
        \\ "required":["email"]}
    , .{});
    const p = try d.present(context(&token), .{ .message = "Who are you?", .requested_schema = schema });
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "This asks for something secret" }) != null);

    // Missing required, then a bad email and a too short default.
    try t.click(.{ .role = .button, .name = "Submit" });
    _ = t.settle();
    try testing.expectEqualStrings("Required.", p.fields[0].problem.?);
    try testing.expect(t.find(.{ .name = "Required." }) != null);
    try t.click(.{ .role = .textbox, .name = "Email" });
    t.typeText("not an email");
    try t.click(.{ .role = .button, .name = "Submit" });
    try testing.expectEqual(@as(usize, 1), d.openCount());
    try testing.expect(p.fields[0].problem != null);
    try testing.expect(p.fields[1].problem != null);

    try t.click(.{ .role = .textbox, .name = "Email" });
    t.press(.key_a, .{ .ctrl = true });
    t.typeText("ana@example.com");
    try t.click(.{ .role = .textbox, .name = "API token" });
    t.typeText("cdef");
    try t.click(.{ .name = "bug" });
    try t.click(.{ .role = .button, .name = "Submit" });
    const r = d.wait(p, &token);
    try testing.expectEqual(M.ElicitResult.Action.accept, r.action);
    const c = r.content.?.object;
    try testing.expectEqualStrings("ana@example.com", c.get("email").?.string);
    try testing.expectEqualStrings("abcdef", c.get("api_token").?.string);
    try testing.expectEqualStrings("l", c.get("size").?.string);
    const labels = c.get("labels").?.array.items;
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqualStrings("bug", labels[0].string);
    try testing.expectEqualStrings("ui", labels[1].string);
}

test "mcp input: unsupported forms and links are declined without a dialog; link warnings" {
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
    const b = d.broker();
    const nested = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"type":"object","properties":{"who":{"type":"object","properties":{"name":{"type":"string"}}}}}
    , .{});
    var r = try b.resolve(b.ctx, context(&token), .{ .elicitation = .{ .message = "Nested", .requested_schema = nested } }, arena.allocator());
    try testing.expectEqual(M.ElicitResult.Action.decline, r.elicitation.action);
    r = try b.resolve(b.ctx, context(&token), .{ .elicitation = .{ .mode = .url, .message = "Open", .url = "javascript:alert(1)" } }, arena.allocator());
    try testing.expectEqual(M.ElicitResult.Action.decline, r.elicitation.action);
    _ = t.settle();
    try testing.expect(t.find(.{ .test_id = "mcp-input" }) == null);

    const p = try d.present(context(&token), .{ .mode = .url, .message = "Sign in", .url = "http://xn--80ak6aa92e.com/login" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = comptime urlWarning(.not_https) }) != null);
    try testing.expect(t.find(.{ .name_contains = comptime urlWarning(.punycode) }) != null);
    try t.click(.{ .role = .button, .name = "Continue" });
    try testing.expectEqual(M.ElicitResult.Action.accept, d.wait(p, &token).action);
}
