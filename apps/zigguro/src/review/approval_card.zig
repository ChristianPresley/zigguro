//! `ApprovalCard` (E12.F05.S02.T02): one approval request from E12's
//! `ApprovalBroker`, as the review panel's inbox shows it and E10's agent
//! pane can embed it. It shows who asks and what:
//! - a command, with its cwd and terminal;
//! - otherwise the request's details (JSON, collapsed when long).
//! Under that come E16's risk strings, then the answer buttons.
//!
//! - Allow once.
//! - Allow for the session: E16's suggested rule, else the command.
//! - Always allow: opens a preview of the rule that will be saved (E16's
//!   `rule_suggestion`, editable). A wildcard before the end of the rule
//!   is flagged.
//! - Edit and allow (editable requests only): the input in a text field.
//!   An input that is not a command must stay valid JSON.
//! - Deny, with an optional reason sent back to the agent.
//!
//! Answered cards show the outcome ("Allowed once by you"). Answers go to
//! the broker; the first one wins.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");
const zg_security = @import("zg_security");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const TextBuffer = zg_gui.w.TextBuffer;
const ap = zg_review.approvals;
const Answer = zg_security.contracts.Answer;

/// Which answer is being prepared.
pub const Mode = enum { view, edit, always, deny };

/// A card's UI state, kept by its owner per request.
pub const CardState = struct {
    gpa: Allocator,
    mode: Mode = .view,
    /// The edited input (`edit`), the rule (`always`) or the reason
    /// (`deny`); kept until `deinit`.
    field: ?TextBuffer = null,
    /// Long details shown in full.
    expanded: bool = false,
    /// Why the last answer was not taken.
    problem: []const u8 = "",

    pub fn init(gpa: Allocator) CardState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *CardState) void {
        if (s.field) |*f| f.deinit();
        s.field = null;
    }

    /// Switches to `m`, with the field holding `text`. The buffer is
    /// reused, never freed here: a field built this frame still points
    /// at it.
    pub fn start(s: *CardState, m: Mode, text: []const u8) void {
        s.problem = "";
        s.mode = m;
        if (m == .view) return;
        if (s.field) |*f| {
            f.setText(text) catch {};
        } else s.field = TextBuffer.init(s.gpa, text) catch null;
    }
};

/// What a key or button asks of a pending card.
pub const Act = enum { allow_once, allow_session, always, edit, deny, confirm, cancel, toggle_details };

pub const Options = struct {
    /// The view that answers (`answered_by`): "inbox", "agent-pane".
    view: []const u8 = "inbox",
    /// The keyboard selection is on this card.
    selected: bool = false,
    now_ms: i64 = 0,
};

/// Details longer than this are collapsed.
pub const collapse_bytes = 400;

/// Builds the card for `it` (a copy from `broker.list`/`get`) and runs a
/// clicked answer.
pub fn build(ui: *Ui, broker: *ap.ApprovalBroker, it: *const ap.InboxItem, st: *CardState, o: Options) void {
    const th = ui.theme();
    var name_buf: [160]u8 = undefined;
    const name = announce(&name_buf, it);
    ui.open(.{
        .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(8), .bg = .{ .token = if (o.selected) .selection_bg else .bg_elevated }, .shrink = 0 },
        .role = .group,
        .label = name,
    });
    defer ui.close();
    header(ui, it, o.now_ms);
    body(ui, it, st);
    if (it.state != .pending) {
        ui.text(outcome(&name_buf, it), .{ .color = if (it.state == .denied or it.state == .expired) .fg_muted else .success });
        return;
    }
    const act = if (st.mode != .view) form(ui, it, st) else buttons(ui, it);
    if (act) |a| {
        run(broker, it, st, a, o.view);
        ui.window().markAllDirty();
    }
    if (st.problem.len > 0) ui.text(st.problem, .{ .color = .danger });
}

fn header(ui: *Ui, it: *const ap.InboxItem, now_ms: i64) void {
    ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6 } });
    defer ui.close();
    ui.text(it.req.title, .{ .wrap = false });
    var ab: [96]u8 = undefined;
    ui.text(std.fmt.bufPrint(&ab, "{f}", .{it.req.actor}) catch "", .{ .color = .fg_muted, .wrap = false });
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    var tb: [16]u8 = undefined;
    ui.text(@import("queue_panel.zig").age(&tb, now_ms - it.req.created_ms), .{ .color = .fg_muted, .wrap = false });
}

fn body(ui: *Ui, it: *const ap.InboxItem, st: *CardState) void {
    const r = &it.req;
    var arena_state: std.heap.ArenaAllocator = .init(st.gpa);
    defer arena_state.deinit();
    if (ap.commandView(r, arena_state.allocator()) catch null) |cv| {
        ui.open(.{ .style = .{ .padding = .xy(8, 6), .bg = .{ .token = .bg_base } } });
        ui.text(cv.line, .{ .style = .{ .font = .mono } });
        ui.close();
        var lb: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&lb);
        if (cv.cwd) |c| w.print("in {s}", .{c}) catch {};
        if (cv.terminal) |t| w.print("{s}terminal {d}", .{ if (w.end > 0) " · " else "", t }) catch {};
        if (cv.shell) |s| w.print("{s}{s}", .{ if (w.end > 0) " · " else "", s }) catch {};
        if (w.end > 0) ui.text(w.buffered(), .{ .color = .fg_muted, .wrap = false });
    } else if (r.detail_json.len > 0) {
        const pretty = prettyJson(arena_state.allocator(), r.detail_json) catch r.detail_json;
        const long = pretty.len > collapse_bytes;
        ui.open(.{ .style = .{ .padding = .xy(8, 6), .bg = .{ .token = .bg_base } } });
        ui.text(if (long and !st.expanded) pretty[0..collapse_bytes] else pretty, .{ .style = .{ .font = .mono } });
        ui.close();
        if (long) {
            ui.id(1);
            if (zg_gui.w.button(ui, .{ .label = if (st.expanded) "Show less" else "Show all", .variant = .ghost }).clicked) {
                st.expanded = !st.expanded;
                ui.window().markAllDirty();
            }
        }
    }
    for (r.risk, 0..) |risk, i| {
        ui.id(1000 + i);
        ui.textf("\u{26a0} {s}", .{risk}, .{ .color = .warning });
    }
}

/// The answer buttons; the clicked one.
fn buttons(ui: *Ui, it: *const ap.InboxItem) ?Act {
    ui.open(.{ .style = .{ .dir = .row, .gap = 6, .wrap = true } });
    defer ui.close();
    var act: ?Act = null;
    if (zg_gui.w.button(ui, .{ .label = "Allow once", .variant = .primary }).clicked) act = .allow_once;
    if (zg_gui.w.button(ui, .{ .label = "Allow for session" }).clicked) act = .allow_session;
    if (zg_gui.w.button(ui, .{ .label = "Always allow…" }).clicked) act = .always;
    if (it.req.editable and zg_gui.w.button(ui, .{ .label = "Edit and allow…" }).clicked) act = .edit;
    if (zg_gui.w.button(ui, .{ .label = "Deny", .variant = .danger }).clicked) act = .deny;
    return act;
}

/// The edit, rule or reason form; its confirm or cancel.
fn form(ui: *Ui, it: *const ap.InboxItem, st: *CardState) ?Act {
    const f = &(st.field orelse return .cancel);
    const label, const ok, const multiline = switch (st.mode) {
        .edit => .{ "Edited input", "Run edited", true },
        .always => .{ "Rule to save", "Save rule and allow", false },
        .deny => .{ "Reason (sent back to the agent)", "Deny", false },
        .view => unreachable,
    };
    if (st.mode == .always) ui.text("Always allow saves this rule:", .{ .color = .fg_muted });
    const r = zg_gui.w.textField(ui, .{
        .buffer = f,
        .multiline = multiline,
        .max_rows = if (multiline) 8 else 1,
        .font = if (st.mode == .deny) .ui else .mono,
        .a11y_label = label,
        .placeholder = if (st.mode == .deny) "Optional" else "",
        .invalid = st.problem.len > 0,
    });
    if (st.mode == .always) if (wildcardWarning(f.slice())) |wn| ui.text(wn, .{ .color = .warning });
    _ = it;
    ui.open(.{ .style = .{ .dir = .row, .gap = 6 } });
    defer ui.close();
    var act: ?Act = if (r.submitted) .confirm else null;
    if (zg_gui.w.button(ui, .{ .label = ok, .variant = if (st.mode == .deny) .danger else .primary }).clicked) act = .confirm;
    if (zg_gui.w.button(ui, .{ .label = "Cancel", .variant = .ghost }).clicked) act = .cancel;
    return act;
}

/// Carries out `a` on a pending card (from a button or a key).
pub fn run(broker: *ap.ApprovalBroker, it: *const ap.InboxItem, st: *CardState, a: Act, view: []const u8) void {
    const r = &it.req;
    switch (a) {
        .allow_once => answer(broker, it, st, .allow_once, view),
        .allow_session => answer(broker, it, st, .{ .allow_session = sessionRule(r) }, view),
        .always => st.start(.always, r.rule_suggestion orelse sessionRule(r)),
        .edit => if (r.editable) st.start(.edit, r.command orelse r.detail_json),
        .deny => st.start(.deny, ""),
        .cancel => st.start(.view, ""),
        .toggle_details => st.expanded = !st.expanded,
        .confirm => {
            const f = &(st.field orelse return);
            const text = f.slice();
            switch (st.mode) {
                .view => {},
                .edit => {
                    if (r.command == null and !validJson(st.gpa, text)) {
                        st.problem = "The input must be valid JSON";
                        return;
                    }
                    answer(broker, it, st, .{ .edit = text }, view);
                },
                .always => {
                    if (std.mem.trim(u8, text, " \t").len == 0) {
                        st.problem = "The rule is empty";
                        return;
                    }
                    answer(broker, it, st, .{ .allow_always = text }, view);
                },
                .deny => answer(broker, it, st, .{ .deny = if (text.len > 0) text else "denied by the user" }, view),
            }
        },
    }
}

fn answer(broker: *ap.ApprovalBroker, it: *const ap.InboxItem, st: *CardState, a: Answer, view: []const u8) void {
    // The broker copies the answer before the field is freed.
    broker.answer(it.id, a, view) catch |e| {
        st.problem = switch (e) {
            error.AlreadyAnswered => "Already answered elsewhere",
            error.UnknownApproval => "The request is gone",
            error.NotEditable => "This request cannot be edited",
            error.OutOfMemory => "Out of memory",
        };
        return;
    };
    st.start(.view, "");
}

/// What "Allow for session" allows: E16's rule, else the command, else
/// the title (as the dialog did).
pub fn sessionRule(r: *const zg_security.contracts.ApprovalRequest) []const u8 {
    return r.rule_suggestion orelse r.command orelse r.title;
}

/// A warning when a `*` comes before the end of the rule's pattern
/// (`run_command(* --force)` matches far more than it reads).
pub fn wildcardWarning(rule: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, rule, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, rule, ')') orelse rule.len;
    if (close <= open) return null;
    const pat = std.mem.trim(u8, rule[open + 1 .. close], " ");
    const star = std.mem.indexOfScalar(u8, pat, '*') orelse return null;
    if (star + 1 == pat.len) return null;
    return "A wildcard before the end of the rule matches more than it seems to: put it last";
}

fn validJson(gpa: Allocator, s: []const u8) bool {
    return std.json.validate(gpa, s) catch false;
}

fn prettyJson(arena: Allocator, s: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, s, .{});
    return std.json.Stringify.valueAlloc(arena, v, .{ .whitespace = .indent_2 });
}

/// "Allowed once by you", "Denied from the CLI", "Expired".
pub fn outcome(buf: []u8, it: *const ap.InboxItem) []const u8 {
    const by = it.answered_by orelse return it.state.label();
    const who = if (std.mem.eql(u8, by, "cli")) "from the CLI" else "by you";
    return std.fmt.bufPrint(buf, "{s} {s}", .{ it.state.label(), who }) catch it.state.label();
}

/// The screen reader's name: "Approval needed: run command cargo test
/// in /ws".
pub fn announce(buf: []u8, it: *const ap.InboxItem) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}: {s}", .{ if (it.state == .pending) "Approval needed" else it.state.label(), it.req.title }) catch {};
    if (it.req.command) |c| w.print(" {s}", .{c}) catch {};
    return w.buffered();
}

test "approval card: wildcard warning, session rule, outcome" {
    const t = std.testing;
    try t.expect(wildcardWarning("run_command(cargo test *)") == null);
    try t.expect(wildcardWarning("run_command(* --force)") != null);
    try t.expect(wildcardWarning("web_fetch") == null);
    var req: zg_security.contracts.ApprovalRequest = .{ .kind = .command, .actor = .system, .title = "Run command", .detail_json = "{}", .command = "ls", .created_ms = 0 };
    try t.expectEqualStrings("ls", sessionRule(&req));
    req.rule_suggestion = "run_command(ls *)";
    try t.expectEqualStrings("run_command(ls *)", sessionRule(&req));
    var buf: [64]u8 = undefined;
    const it: ap.InboxItem = .{ .id = @enumFromInt(1), .req = req, .state = .allowed_once, .answered_by = "inbox" };
    try t.expectEqualStrings("Allowed once by you", outcome(&buf, &it));
    try t.expectEqualStrings("Allowed once: Run command ls", announce(&buf, &it));
}
