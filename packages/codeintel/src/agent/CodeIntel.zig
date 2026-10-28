//! The language services as agents use them (E07.F05.S01.T01): a
//! headless facade whose calls block, with a deadline, on the agent's
//! worker thread. It is what the `lsp_*` tools (agent/tools.zig), the
//! MCP server and the `zg` CLI stand on.
//!
//! Symbols are addressed with a `SymbolRef` (agent/locate.zig): a line
//! and a column in characters, a name on or near a line, or a qualified
//! name that a `workspace/symbol` search resolves. Paths may be absolute
//! or relative to the first workspace root; paths outside every root are
//! refused. Files the editor does not have open are opened in the
//! background (agent/background_docs.zig) so servers answer for them.
//!
//! Each call hops to the UI thread (`UiPort`) for the parts that touch
//! documents and the manager, and sends its requests from there; requests
//! carry the deadline, so their answers always come. Waiting for a server
//! to start counts against the same deadline. A failure returns an error
//! with the reason in `Call.why`, written for the model.
//!
//! Rename and code actions never apply directly: the edit goes through
//! the workspace edit engine with the agent as its origin and
//! `force_review`, and the call returns the E12 changeset id.

const CodeIntel = @This();
const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const Store = @import("../diagnostics/Store.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");
const position = @import("../features/position.zig");
const code_action = @import("../features/code_action.zig");
const BackgroundDocs = @import("background_docs.zig");
const SettleDetector = @import("../diagnostics/settle.zig");
pub const locate = @import("locate.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const PositionEncoding = zg_lsp.position.PositionEncoding;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const registry = zg_editor.model.api.registry;
const Feature = Manager.Feature;

pub const SymbolRef = locate.SymbolRef;

/// Runs work on the UI thread.
pub const UiPort = struct {
    ctx: *anyopaque,
    /// Runs `f(arg)` on the UI thread and returns once it has run; false
    /// when it could not be queued (nothing ran).
    run: *const fn (ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool,
};

mgr: *Manager,
store: *Store,
/// Workspace roots (absolute); relative paths resolve against the
/// first, and paths outside every root are refused.
roots: []const []const u8,
ui: UiPort,
/// Deadline of each call (`lsp.agent.timeoutMs`).
timeout: Io.Duration = .fromSeconds(15),
/// Rename and code actions plan and apply through it (null: they are
/// refused).
engine: ?*Engine = null,
/// Opens files the editor does not have (null: only open files).
bg: ?*BackgroundDocs = null,
/// Waits for diagnostics after an edit (`lsp_wait_for_diagnostics`).
settle: ?*SettleDetector = null,
/// Code actions listed to agents (`codeActions`), by id.
actions: std.ArrayList(Action) = .empty,
actions_mutex: Io.Mutex = .init,
next_action: u32 = 1,

/// How long a listed code action can be applied.
pub const action_ttl: Io.Duration = .fromSeconds(5 * 60);
const max_actions = 256;

const Action = struct {
    id: u32,
    server: u32,
    client: *Client,
    /// The `TextDocumentCodeActionResultItem`, as JSON (owned).
    json: []u8,
    listed_ns: i96,
};

pub fn deinit(ci: *CodeIntel) void {
    for (ci.actions.items) |a| ci.mgr.gpa.free(a.json);
    ci.actions.deinit(ci.mgr.gpa);
}

pub const Error = error{
    /// No such file, symbol, line or code action.
    NotFound,
    /// A qualified name with several matches (`Call.candidates`).
    Ambiguous,
    OutsideWorkspace,
    /// No language server answers this for the file.
    NoServer,
    Timeout,
    /// The server answered with an error, or went away.
    ServerError,
    /// The request is not allowed (a disabled action, no review queue).
    Refused,
} || Allocator.Error;

/// One call's allocator, deadline and failure details.
pub const Call = struct {
    io: Io,
    arena: Allocator,
    /// Why the call failed, for the model.
    why: []const u8 = "",
    /// `error.Ambiguous`: the best matches.
    candidates: []const Symbol = &.{},
    /// The symbol was found on this 1-based line, not the one given.
    adjusted_line: ?u32 = null,
    deadline_ns: i96 = 0,
    /// Paths in answers are normalized in it (the store's).
    style: registry.PathStyle = .native,
    /// The position encoding of the server that answered last.
    enc: PositionEncoding = .utf16,

    pub fn init(io: Io, arena: Allocator) Call {
        return .{ .io = io, .arena = arena };
    }

    fn fail(c: *Call, err: Error, comptime fmt: []const u8, args: anytype) Error {
        c.why = std.fmt.allocPrint(c.arena, fmt, args) catch "out of memory";
        return err;
    }
};

/// A place in a file (or a document the server names by URI).
pub const Location = struct {
    /// Absolute path, or the URI when not a file.
    path: []const u8,
    is_file: bool,
    /// 0-based, in the server's units (`enc`).
    range: protocol.Range,
    enc: PositionEncoding = .utf16,
};

/// A workspace or document symbol.
pub const Symbol = struct {
    name: []const u8,
    kind: protocol.SymbolKind,
    container: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    /// Null when the server gave no range (a bare URI).
    location: ?Location,
    /// Nesting in a document's outline (0: top level).
    depth: u8 = 0,
};

pub const NavKind = enum { definition, declaration, type_definition, implementation };

pub const RefResult = struct {
    locations: []const Location,
    /// Before `limit`.
    total: usize,
};

pub const CallDirection = enum { incoming, outgoing };

pub const CallNode = struct {
    name: []const u8,
    kind: protocol.SymbolKind,
    detail: ?[]const u8,
    location: Location,
    /// 0: the symbol asked about.
    depth: u8,
    /// Call sites between it and its parent.
    calls: u32 = 0,
    /// Already listed above (a recursive call): not expanded again.
    repeated: bool = false,
};

pub const EditSummary = struct {
    label: []const u8,
    files: []const FileEdit,
    /// Text replacements in all files.
    edits: usize,
};

pub const FileEdit = struct {
    path: []const u8,
    op: enum { edit, create, rename, delete },
    edits: usize = 0,
    /// Rename: the new path.
    to: ?[]const u8 = null,
};

pub const ActionSummary = struct {
    id: u32,
    title: []const u8,
    kind: []const u8,
    preferred: bool,
    /// Why it cannot be applied.
    disabled: ?[]const u8,
};

// ------------------------------------------------------------- queries

pub fn hover(ci: *CodeIntel, call: *Call, ref: SymbolRef) Error!?[]const u8 {
    var q = try ci.begin(call, ref, .hover);
    defer ci.end(&q);
    const r = try ci.exchange(call, .@"textDocument/hover", q.at, .{ .textDocument = .{ .uri = q.at.uri }, .position = q.at.pos });
    defer r.deinit();
    const h = try okValue(call, .@"textDocument/hover", r) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    switch (h.contents) {
        .markup_content => |m| try out.appendSlice(call.arena, m.value),
        .marked_string => |ms| try appendMarked(call.arena, &out, ms),
        .marked_string_array => |arr| for (arr, 0..) |ms, i| {
            if (i > 0) try out.appendSlice(call.arena, "\n\n");
            try appendMarked(call.arena, &out, ms);
        },
    }
    if (out.items.len == 0) return null;
    return out.items;
}

fn appendMarked(arena: Allocator, out: *std.ArrayList(u8), ms: protocol.MarkedString) Allocator.Error!void {
    switch (ms) {
        .string => |t| try out.appendSlice(arena, t),
        .marked_string_with_language => |m| try out.print(arena, "```{s}\n{s}\n```", .{ m.language, m.value }),
    }
}

pub fn definition(ci: *CodeIntel, call: *Call, ref: SymbolRef, kind: NavKind) Error![]const Location {
    return switch (kind) {
        .definition => ci.navigate(.@"textDocument/definition", .definition, call, ref),
        .declaration => ci.navigate(.@"textDocument/declaration", .declaration, call, ref),
        .type_definition => ci.navigate(.@"textDocument/typeDefinition", .type_definition, call, ref),
        .implementation => ci.navigate(.@"textDocument/implementation", .implementation, call, ref),
    };
}

fn navigate(ci: *CodeIntel, comptime M: protocol.Method, feature: Feature, call: *Call, ref: SymbolRef) Error![]const Location {
    var q = try ci.begin(call, ref, feature);
    defer ci.end(&q);
    const r = try ci.exchange(call, M, q.at, .{ .textDocument = .{ .uri = q.at.uri }, .position = q.at.pos });
    defer r.deinit();
    var out: std.ArrayList(Location) = .empty;
    if (try okValue(call, M, r)) |v| try collect(call, &out, v);
    return out.items;
}

pub fn references(ci: *CodeIntel, call: *Call, ref: SymbolRef, include_decl: bool, limit: usize) Error!RefResult {
    var q = try ci.begin(call, ref, .references);
    defer ci.end(&q);
    const r = try ci.exchange(call, .@"textDocument/references", q.at, .{ .textDocument = .{ .uri = q.at.uri }, .position = q.at.pos, .context = .{ .includeDeclaration = include_decl } });
    defer r.deinit();
    var out: std.ArrayList(Location) = .empty;
    if (try okValue(call, .@"textDocument/references", r)) |v| try collect(call, &out, v);
    sortLocations(out.items);
    return .{ .locations = out.items[0..@min(out.items.len, limit)], .total = out.items.len };
}

/// The outline of `path`, `max_depth` levels deep (0: top level only).
pub fn documentSymbols(ci: *CodeIntel, call: *Call, path: []const u8, max_depth: u8) Error![]const Symbol {
    var q = try ci.beginDoc(call, path, .document_symbol);
    defer ci.end(&q);
    const r = try ci.exchange(call, .@"textDocument/documentSymbol", q.at, .{ .textDocument = .{ .uri = q.at.uri } });
    defer r.deinit();
    var out: std.ArrayList(Symbol) = .empty;
    const v = try okValue(call, .@"textDocument/documentSymbol", r) orelse return out.items;
    switch (v) {
        .document_symbol_array => |ds| for (ds) |d| try flattenSymbol(call, &out, q.held.abs, d, 0, max_depth),
        .symbol_information_array => |si| for (si) |s| try out.append(call.arena, .{
            .name = try call.arena.dupe(u8, s.name),
            .kind = s.kind,
            .container = if (s.containerName) |c| try call.arena.dupe(u8, c) else null,
            .location = try toLocation(call, s.location.uri, s.location.range),
        }),
    }
    return out.items;
}

fn flattenSymbol(call: *Call, out: *std.ArrayList(Symbol), abs: []const u8, d: protocol.DocumentSymbol, depth: u8, max_depth: u8) Allocator.Error!void {
    try out.append(call.arena, .{
        .name = try call.arena.dupe(u8, d.name),
        .kind = d.kind,
        .detail = if (d.detail) |x| try call.arena.dupe(u8, x) else null,
        .location = .{ .path = abs, .is_file = true, .range = d.selectionRange },
        .depth = depth,
    });
    if (depth == max_depth) return;
    for (d.children orelse &.{}) |c| try flattenSymbol(call, out, abs, c, depth + 1, max_depth);
}

/// Symbols matching `query` from every running server that searches the
/// workspace, at most `limit`.
pub fn workspaceSymbols(ci: *CodeIntel, call: *Call, query: []const u8, limit: usize) Error![]const Symbol {
    ci.startDeadline(call);
    return ci.searchWorkspace(call, query, limit);
}

fn searchWorkspace(ci: *CodeIntel, call: *Call, query: []const u8, limit: usize) Error![]const Symbol {
    var job: struct {
        ci: *CodeIntel,
        servers: [8]*Manager.Server = undefined,
        clients: [8]*Client = undefined,
        n: usize = 0,
        fn run(j: *@This()) void {
            for (j.ci.mgr.serverList()) |s| {
                if (j.n == j.servers.len) break;
                if (s.status != .running) continue;
                const c = s.client orelse continue;
                const caps = c.caps() orelse continue;
                if (!caps.supports(.workspace_symbol, null)) continue;
                j.servers[j.n] = s;
                j.clients[j.n] = c;
                j.n += 1;
            }
        }
    } = .{ .ci = ci };
    try ci.onUi(call, &job);
    if (job.n == 0) return call.fail(error.NoServer, "no running language server searches the workspace (servers start when a file of their language is opened)", .{});
    var out: std.ArrayList(Symbol) = .empty;
    var answered: usize = 0;
    for (job.servers[0..job.n], job.clients[0..job.n]) |s, c| {
        const at: At = .{ .server = s, .client = c, .h = null, .uri = "", .pos = .{ .line = 0, .character = 0 } };
        const r = ci.exchange(call, .@"workspace/symbol", at, .{ .query = query }) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue,
        };
        defer r.deinit();
        const v = (okValue(call, .@"workspace/symbol", r) catch continue) orelse {
            answered += 1;
            continue;
        };
        answered += 1;
        switch (v) {
            .symbol_information_array => |si| for (si) |x| try out.append(call.arena, .{
                .name = try call.arena.dupe(u8, x.name),
                .kind = x.kind,
                .container = if (x.containerName) |n| try call.arena.dupe(u8, n) else null,
                .location = try toLocation(call, x.location.uri, x.location.range),
            }),
            .workspace_symbol_array => |ws| for (ws) |x| try out.append(call.arena, .{
                .name = try call.arena.dupe(u8, x.name),
                .kind = x.kind,
                .container = if (x.containerName) |n| try call.arena.dupe(u8, n) else null,
                .location = switch (x.location) {
                    .location => |l| try toLocation(call, l.uri, l.range),
                    .location_uri_only => |l| blk: {
                        var loc = try toLocation(call, l.uri, .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } });
                        // No range: the name is searched for in the file.
                        loc.range.start.line = std.math.maxInt(u32);
                        break :blk loc;
                    },
                },
            }),
        }
    }
    if (answered == 0) return call.fail(error.ServerError, "{s}", .{call.why});
    return out.items[0..@min(out.items.len, limit)];
}

/// The calls into (`incoming`) or out of the symbol, `max_depth` levels
/// deep, at most `limit` nodes.
pub fn callHierarchy(ci: *CodeIntel, call: *Call, ref: SymbolRef, dir: CallDirection, max_depth: u8, limit: usize) Error![]const CallNode {
    var q = try ci.begin(call, ref, .call_hierarchy);
    defer ci.end(&q);
    const r = try ci.exchange(call, .@"textDocument/prepareCallHierarchy", q.at, .{ .textDocument = .{ .uri = q.at.uri }, .position = q.at.pos });
    defer r.deinit();
    const roots = try okValue(call, .@"textDocument/prepareCallHierarchy", r) orelse return &.{};

    const Item = protocol.CallHierarchyItem;
    var out: std.ArrayList(CallNode) = .empty;
    // Items waiting to be expanded: (item, depth), breadth first.
    var queue: std.ArrayList(struct { item: Item, depth: u8 }) = .empty;
    for (roots) |it| {
        if (out.items.len == limit) break;
        const own = try copyItem(call.arena, it);
        try out.append(call.arena, try callNode(call, own, 0, 0));
        try queue.append(call.arena, .{ .item = own, .depth = 0 });
    }
    var next: usize = 0;
    while (next < queue.items.len and out.items.len < limit) : (next += 1) {
        const e = queue.items[next];
        if (e.depth >= max_depth) continue;
        const children = switch (dir) {
            .incoming => try ci.calls(.@"callHierarchy/incomingCalls", call, q.at, e.item),
            .outgoing => try ci.calls(.@"callHierarchy/outgoingCalls", call, q.at, e.item),
        };
        // Children go right after their parent (a depth-first listing).
        var parent_at: usize = 0;
        for (out.items, 0..) |n, i| if (n.depth == e.depth and sameItem(n, e.item)) {
            parent_at = i;
        };
        var insert_at = parent_at + 1;
        while (insert_at < out.items.len and out.items[insert_at].depth > e.depth) insert_at += 1;
        for (children) |ch| {
            if (out.items.len == limit) break;
            var node = try callNode(call, ch.item, e.depth + 1, ch.calls);
            node.repeated = for (out.items) |n| {
                if (sameItem(n, ch.item)) break true;
            } else false;
            try out.insert(call.arena, insert_at, node);
            insert_at += 1;
            if (!node.repeated) try queue.append(call.arena, .{ .item = ch.item, .depth = e.depth + 1 });
        }
    }
    return out.items;
}

const Child = struct { item: protocol.CallHierarchyItem, calls: u32 };

fn calls(ci: *CodeIntel, comptime M: protocol.Method, call: *Call, at: At, item: protocol.CallHierarchyItem) Error![]const Child {
    const r = ci.exchange(call, M, at, .{ .item = item }) catch |e| switch (e) {
        // One failed expansion leaves that branch empty.
        error.OutOfMemory => return e,
        else => return &.{},
    };
    defer r.deinit();
    const v = (okValue(call, M, r) catch return &.{}) orelse return &.{};
    var out: std.ArrayList(Child) = .empty;
    for (v) |c| {
        const it = if (M == .@"callHierarchy/incomingCalls") c.from else c.to;
        try out.append(call.arena, .{ .item = try copyItem(call.arena, it), .calls = @intCast(c.fromRanges.len) });
    }
    return out.items;
}

fn copyItem(arena: Allocator, it: protocol.CallHierarchyItem) Allocator.Error!protocol.CallHierarchyItem {
    const json = try std.json.Stringify.valueAlloc(arena, it, .{});
    return std.json.parseFromSliceLeaky(protocol.CallHierarchyItem, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => it,
    };
}

fn callNode(call: *Call, it: protocol.CallHierarchyItem, depth: u8, n: u32) Allocator.Error!CallNode {
    return .{ .name = it.name, .kind = it.kind, .detail = it.detail, .location = try toLocation(call, it.uri, it.selectionRange), .depth = depth, .calls = n };
}

fn sameItem(n: CallNode, it: protocol.CallHierarchyItem) bool {
    return std.mem.eql(u8, n.name, it.name) and n.location.range.start.line == it.selectionRange.start.line and n.location.range.start.character == it.selectionRange.start.character;
}

/// The text of `path` for excerpts: the open document's, else the
/// file's on disk (null when it cannot be read).
pub fn fileText(ci: *CodeIntel, call: *Call, path: []const u8) Allocator.Error!?[]const u8 {
    var job: struct {
        ci: *CodeIntel,
        arena: Allocator,
        path: []const u8,
        out: Allocator.Error!?[]const u8 = null,
        fn run(j: *@This()) void {
            j.out = j.get();
        }
        fn get(j: *@This()) Allocator.Error!?[]const u8 {
            const docs = j.ci.mgr.docs;
            const h = try docs.findFile(j.path) orelse return null;
            const doc = docs.get(h) orelse return null;
            var t: std.ArrayList(u8) = .empty;
            try t.ensureTotalCapacity(j.arena, @intCast(doc.len()));
            var it = doc.tree.chunks(0);
            while (it.next()) |c| t.appendSliceAssumeCapacity(c);
            return t.items;
        }
    } = .{ .ci = ci, .arena = call.arena, .path = path };
    if (ci.ui.run(ci.ui.ctx, Wrap(@TypeOf(job)).run, &job)) {
        if (try job.out) |t| return t;
    }
    return Io.Dir.cwd().readFileAlloc(call.io, path, call.arena, .limited(16 << 20)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

// ------------------------------------------------------------- edits

/// What renaming the symbol to `new_name` would change; nothing is
/// applied.
pub fn renamePreview(ci: *CodeIntel, call: *Call, ref: SymbolRef, new_name: []const u8) Error!EditSummary {
    return (try ci.rename(call, ref, new_name, null)).summary;
}

/// Proposes the rename for review; returns the changeset id.
pub fn renameApply(ci: *CodeIntel, call: *Call, ref: SymbolRef, new_name: []const u8, agent: u32) Error!u64 {
    return (try ci.rename(call, ref, new_name, agent)).changeset.?;
}

const Planned = struct { summary: EditSummary, changeset: ?u64 = null };

fn rename(ci: *CodeIntel, call: *Call, ref: SymbolRef, new_name: []const u8, agent: ?u32) Error!Planned {
    if (ci.engine == null) return call.fail(error.Refused, "workspace edits are not available here", .{});
    if (new_name.len == 0) return call.fail(error.NotFound, "the new name is empty", .{});
    var q = try ci.begin(call, ref, .rename);
    defer ci.end(&q);
    if (!q.held.inside) return call.fail(error.OutsideWorkspace, "{s} is outside the workspace; only workspace files can be renamed", .{q.held.abs});
    const r = try ci.exchange(call, .@"textDocument/rename", q.at, .{ .textDocument = .{ .uri = q.at.uri }, .position = q.at.pos, .newName = new_name });
    defer r.deinit();
    const edit = try okValue(call, .@"textDocument/rename", r) orelse return call.fail(error.NotFound, "the server cannot rename this symbol", .{});
    const label = try std.fmt.allocPrint(call.arena, "Rename to {s}", .{new_name});
    return ci.planEdit(call, q.at.server, &edit, label, agent);
}

/// Plans `edit` on the UI thread: a summary, and with `agent` the plan
/// queued for review.
fn planEdit(ci: *CodeIntel, call: *Call, s: *Manager.Server, edit: *const protocol.WorkspaceEdit, label: []const u8, agent: ?u32) Error!Planned {
    var job: struct {
        ci: *CodeIntel,
        call: *Call,
        s: *Manager.Server,
        edit: *const protocol.WorkspaceEdit,
        label: []const u8,
        agent: ?u32,
        out: Error!Planned = error.Refused,
        fn run(j: *@This()) void {
            j.out = j.plan();
        }
        fn plan(j: *@This()) Error!Planned {
            const engine = j.ci.engine.?;
            var why: plan_mod.Failure = .{ .index = 0, .err = error.Unknown };
            var p = engine.plan(j.edit, Engine.sourceOf(j.s), j.label, &why) catch
                return j.call.fail(error.Refused, "the edit cannot be applied: {s}", .{plan_mod.reason(why.err)});
            defer p.deinit();
            for (p.files) |f| if (!j.ci.inside(j.call.arena, f.path)) return j.call.fail(error.OutsideWorkspace, "the edit changes {s}, outside the workspace", .{f.path});
            var out: Planned = .{ .summary = try summarize(j.call.arena, &p) };
            if (j.agent) |id| {
                const res = engine.apply(&p, .{ .agent = id }, .force_review) catch |e|
                    return j.call.fail(error.Refused, "the edit could not be proposed: {s}", .{plan_mod.reason(e)});
                switch (res) {
                    .queued => |qd| out.changeset = qd.changeset,
                    .failed => |f| return j.call.fail(error.Refused, "the edit could not be proposed: {s}", .{f.reason}),
                    // `force_review` never applies.
                    .applied => unreachable,
                }
            }
            return out;
        }
    } = .{ .ci = ci, .call = call, .s = s, .edit = edit, .label = label, .agent = agent };
    try ci.onUi(call, &job);
    return job.out;
}

fn summarize(arena: Allocator, p: *const plan_mod.EditPlan) Allocator.Error!EditSummary {
    var files: std.ArrayList(FileEdit) = .empty;
    var total: usize = 0;
    for (p.steps) |st| switch (st.op) {
        .text => |t| {
            total += t.edits.len;
            for (files.items) |*f| {
                if (f.op == .edit and std.mem.eql(u8, f.path, t.path)) {
                    f.edits += t.edits.len;
                    break;
                }
            } else try files.append(arena, .{ .path = try arena.dupe(u8, t.path), .op = .edit, .edits = t.edits.len });
        },
        .create => |c| try files.append(arena, .{ .path = try arena.dupe(u8, c.path), .op = .create }),
        .rename => |rn| try files.append(arena, .{ .path = try arena.dupe(u8, rn.old), .op = .rename, .to = try arena.dupe(u8, rn.new) }),
        .delete => |d| try files.append(arena, .{ .path = try arena.dupe(u8, d.path), .op = .delete }),
        .skip => {},
    };
    std.mem.sort(FileEdit, files.items, {}, struct {
        fn lt(_: void, a: FileEdit, b: FileEdit) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);
    return .{ .label = try arena.dupe(u8, p.label), .files = files.items, .edits = total };
}

/// The code actions over 1-based lines `lines[0]..lines[1]` of `path`.
/// Their ids can be applied for `action_ttl`.
pub fn codeActions(ci: *CodeIntel, call: *Call, path: []const u8, lines: [2]u32) Error![]const ActionSummary {
    var q = try ci.beginDoc(call, path, .code_action);
    defer ci.end(&q);
    // The range and the diagnostics over it, from the document.
    var job: struct {
        ci: *CodeIntel,
        call: *Call,
        h: DocHandle,
        lines: [2]u32,
        out: Error!struct { range: protocol.Range, diags: []const protocol.Diagnostic } = error.NotFound,
        fn run(j: *@This()) void {
            j.out = j.get();
        }
        fn get(j: *@This()) Error!@typeInfo(@TypeOf(j.out)).error_union.payload {
            const mgr = j.ci.mgr;
            const doc = mgr.docs.get(j.h) orelse return j.call.fail(error.NotFound, "the file was closed", .{});
            const n = doc.tree.lineCount();
            const a = @max(j.lines[0], 1);
            const b = @max(j.lines[1], a);
            if (a > n) return j.call.fail(error.NotFound, "line {d} is past the end of the file ({d} lines)", .{ a, n });
            // Whole lines: character 0 means the same in every encoding.
            const range: protocol.Range = .{ .start = .{ .line = a - 1, .character = 0 }, .end = if (b >= n) .{ .line = @intCast(n), .character = 0 } else .{ .line = b, .character = 0 } };
            var m: position.Mapper = .{ .gpa = mgr.gpa, .tree = &doc.tree, .enc = .utf8 };
            defer m.deinit();
            const bytes = try m.toRange(range);
            const diags = code_action.contextDiagnostics(mgr, j.ci.store, j.call.arena, j.h, bytes) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => &.{},
            };
            return .{ .range = range, .diags = diags };
        }
    } = .{ .ci = ci, .call = call, .h = q.held.h, .lines = lines };
    try ci.onUi(call, &job);
    const ctx = try job.out;
    const r = try ci.exchange(call, .@"textDocument/codeAction", q.at, .{ .textDocument = .{ .uri = q.at.uri }, .range = ctx.range, .context = .{ .diagnostics = ctx.diags, .triggerKind = .Invoked } });
    defer r.deinit();
    const items = try okValue(call, .@"textDocument/codeAction", r) orelse return &.{};
    const gpa = ci.mgr.gpa;
    const now = nowNs(call.io);
    var out: std.ArrayList(ActionSummary) = .empty;
    ci.actions_mutex.lockUncancelable(call.io);
    defer ci.actions_mutex.unlock(call.io);
    ci.pruneActions(now);
    for (items) |it| {
        const json = try std.json.Stringify.valueAlloc(gpa, it, .{});
        errdefer gpa.free(json);
        if (ci.actions.items.len == max_actions) {
            gpa.free(ci.actions.items[0].json);
            _ = ci.actions.orderedRemove(0);
        }
        const id = ci.next_action;
        ci.next_action +%= 1;
        try ci.actions.append(gpa, .{ .id = id, .server = q.at.server.id, .client = q.at.client, .json = json, .listed_ns = now });
        try out.append(call.arena, switch (it) {
            .command => |c| .{ .id = id, .title = try call.arena.dupe(u8, c.title), .kind = "command", .preferred = false, .disabled = "it runs a server command, which agents cannot run" },
            .code_action => |ca| .{
                .id = id,
                .title = try call.arena.dupe(u8, ca.title),
                .kind = if (ca.kind) |k| try call.arena.dupe(u8, k.toString()) else "",
                .preferred = ca.isPreferred orelse false,
                .disabled = if (ca.disabled) |d| try call.arena.dupe(u8, d.reason) else null,
            },
        });
    }
    // Quick fixes the server prefers first.
    std.mem.sort(ActionSummary, out.items, {}, struct {
        fn lt(_: void, a: ActionSummary, b: ActionSummary) bool {
            if ((a.disabled == null) != (b.disabled == null)) return a.disabled == null;
            if (a.preferred != b.preferred) return a.preferred;
            return a.id < b.id;
        }
    }.lt);
    return out.items;
}

fn pruneActions(ci: *CodeIntel, now: i96) void {
    var i: usize = 0;
    while (i < ci.actions.items.len) {
        if (now - ci.actions.items[i].listed_ns >= action_ttl.nanoseconds) {
            ci.mgr.gpa.free(ci.actions.items[i].json);
            _ = ci.actions.orderedRemove(i);
        } else i += 1;
    }
}

/// Proposes code action `id` (from `codeActions`) for review; returns
/// the changeset id.
pub fn applyCodeAction(ci: *CodeIntel, call: *Call, id: u32, agent: u32) Error!u64 {
    if (ci.engine == null) return call.fail(error.Refused, "workspace edits are not available here", .{});
    ci.startDeadline(call);
    const a = blk: {
        ci.actions_mutex.lockUncancelable(call.io);
        defer ci.actions_mutex.unlock(call.io);
        ci.pruneActions(nowNs(call.io));
        for (ci.actions.items) |x| if (x.id == id) break :blk .{ x.server, x.client, try call.arena.dupe(u8, x.json) };
        return call.fail(error.NotFound, "no code action {d} (ids last {d} minutes; list the actions again)", .{ id, @divTrunc(action_ttl.nanoseconds, std.time.ns_per_min) });
    };
    const server_id, const client, const json = a;
    const item = std.json.parseFromSliceLeaky(protocol.TextDocumentCodeActionResultItem, call.arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return call.fail(error.NotFound, "code action {d} could not be read back", .{id});
    var ca = switch (item) {
        .command => return call.fail(error.Refused, "this action runs a server command, which agents cannot run", .{}),
        .code_action => |x| x,
    };
    if (ca.disabled) |d| return call.fail(error.Refused, "the action is disabled: {s}", .{d.reason});
    const s = try ci.liveServer(call, server_id, client);
    const at: At = .{ .server = s, .client = client, .h = null, .uri = "", .pos = .{ .line = 0, .character = 0 } };
    if (ca.edit == null and code_action.canResolve(client)) {
        const r = try ci.exchange(call, .@"codeAction/resolve", at, ca);
        defer r.deinit();
        const resolved = try okValue(call, .@"codeAction/resolve", r);
        const again = try std.json.Stringify.valueAlloc(call.arena, resolved, .{});
        ca = std.json.parseFromSliceLeaky(protocol.CodeAction, call.arena, again, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return call.fail(error.ServerError, "the server's resolved action could not be read", .{});
    }
    const edit = ca.edit orelse return call.fail(error.Refused, "this action only runs a server command, which agents cannot run", .{});
    return (try ci.planEdit(call, s, &edit, ca.title, agent)).changeset.?;
}

/// Server `id` if it still runs with `client`.
fn liveServer(ci: *CodeIntel, call: *Call, id: u32, client: *Client) Error!*Manager.Server {
    var job: struct {
        mgr: *Manager,
        id: u32,
        client: *Client,
        s: ?*Manager.Server = null,
        fn run(j: *@This()) void {
            const list = j.mgr.serverList();
            if (j.id >= list.len) return;
            const s = list[j.id];
            if (s.status == .running and s.client == j.client) j.s = s;
        }
    } = .{ .mgr = ci.mgr, .id = id, .client = client };
    try ci.onUi(call, &job);
    return job.s orelse call.fail(error.ServerError, "the language server restarted since the actions were listed; list them again", .{});
}

// ------------------------------------------------------------ plumbing

/// A query's document and where its request goes.
const Query = struct { held: Held, at: At };

const Held = struct {
    h: DocHandle,
    abs: []const u8,
    /// Held through `bg` (released at the end).
    bg: bool,
    /// Inside the workspace roots.
    inside: bool,
};

/// The routed server and the position (in its units) of a request.
const At = struct {
    server: *Manager.Server,
    client: *Client,
    h: ?DocHandle,
    uri: []const u8,
    pos: protocol.Position,
};

/// Where a ref points, before its document is open.
const Spot = struct {
    abs: []const u8,
    inside: bool,
    ref: SymbolRef,
    /// From a workspace symbol: its position, in `enc` units.
    lsp: ?struct { pos: protocol.Position, enc: PositionEncoding } = null,
    /// The name looked for from that position on (or from the start of
    /// the file when the server gave no range).
    find: ?[]const u8 = null,
};

fn startDeadline(ci: *const CodeIntel, call: *Call) void {
    if (call.deadline_ns == 0) call.deadline_ns = nowNs(call.io) + ci.timeout.nanoseconds;
    call.style = ci.store.style;
}

fn nowNs(io: Io) i96 {
    return Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

/// Opens the ref's document, waits for a server providing `feature` and
/// finds the position.
fn begin(ci: *CodeIntel, call: *Call, ref: SymbolRef, feature: Feature) Error!Query {
    ci.startDeadline(call);
    const spot = try ci.spotOf(call, ref);
    const held = try ci.hold(call, spot.abs, spot.inside);
    errdefer ci.releaseHeld(held);
    try ci.waitReady(call, held.h, feature);
    return .{ .held = held, .at = try ci.locateIn(call, held.h, &spot, feature) };
}

/// `begin` for a whole document.
fn beginDoc(ci: *CodeIntel, call: *Call, path: []const u8, feature: Feature) Error!Query {
    ci.startDeadline(call);
    const abs = try ci.resolvePath(call, path);
    const held = try ci.hold(call, abs, true);
    errdefer ci.releaseHeld(held);
    try ci.waitReady(call, held.h, feature);
    return .{ .held = held, .at = try ci.locateIn(call, held.h, null, feature) };
}

fn end(ci: *CodeIntel, q: *Query) void {
    ci.releaseHeld(q.held);
}

fn releaseHeld(ci: *CodeIntel, held: Held) void {
    if (!held.bg) return;
    var job: struct {
        bg: *BackgroundDocs,
        h: DocHandle,
        fn run(j: *@This()) void {
            j.bg.release(j.h);
        }
    } = .{ .bg = ci.bg.?, .h = held.h };
    // When the UI is gone, so is the table.
    const W = Wrap(@TypeOf(job));
    _ = ci.ui.run(ci.ui.ctx, W.run, &job);
}

fn Wrap(comptime T: type) type {
    return struct {
        fn run(arg: *anyopaque) void {
            const j: *T = @ptrCast(@alignCast(arg));
            j.run();
        }
    };
}

/// Runs `job.run()` on the UI thread.
fn onUi(ci: *const CodeIntel, call: *Call, job: anytype) Error!void {
    const W = Wrap(@TypeOf(job.*));
    if (!ci.ui.run(ci.ui.ctx, W.run, job)) return call.fail(error.ServerError, "the editor is not taking requests", .{});
}

/// `path` made absolute and checked against the roots.
pub fn resolvePath(ci: *const CodeIntel, call: *Call, path: []const u8) Error![]const u8 {
    const style = ci.store.style;
    const sep: []const u8 = if (style == .windows) "\\" else "/";
    const abs = if (registry.isAbsolute(path, style) or ci.roots.len == 0) path else try std.mem.concat(call.arena, u8, &.{ ci.roots[0], sep, path });
    const norm = try registry.normalizePath(call.arena, abs, style);
    if (!ci.inside(call.arena, norm)) return call.fail(error.OutsideWorkspace, "{s} is outside the workspace", .{path});
    return norm;
}

/// Whether the normalized path `norm` is under a root.
fn inside(ci: *const CodeIntel, arena: Allocator, norm: []const u8) bool {
    const style = ci.store.style;
    const key = registry.pathKey(arena, norm, style) catch return false;
    for (ci.roots) |root| {
        const rk = registry.pathKey(arena, registry.normalizePath(arena, root, style) catch continue, style) catch continue;
        if (rk.len == 0) continue;
        if (std.mem.startsWith(u8, key, rk) and (key.len == rk.len or key[rk.len] == '/' or key[rk.len] == '\\' or rk[rk.len - 1] == '/' or rk[rk.len - 1] == '\\')) return true;
    }
    return false;
}

fn spotOf(ci: *CodeIntel, call: *Call, ref: SymbolRef) Error!Spot {
    switch (ref) {
        .qualified => |q| return ci.resolveQualified(call, q),
        .position => |p| {
            if (p.line == 0) return call.fail(error.NotFound, "lines start at 1", .{});
            var r = ref;
            r.position.path = try ci.resolvePath(call, p.path);
            return .{ .abs = r.position.path, .inside = true, .ref = r };
        },
        .name_on_line => |n| {
            if (n.line == 0) return call.fail(error.NotFound, "lines start at 1", .{});
            var r = ref;
            r.name_on_line.path = try ci.resolvePath(call, n.path);
            return .{ .abs = r.name_on_line.path, .inside = true, .ref = r };
        },
    }
}

/// A qualified name through `workspace/symbol`: the last segment is
/// searched, the container filters.
fn resolveQualified(ci: *CodeIntel, call: *Call, q: []const u8) Error!Spot {
    const want = try locate.splitQualified(call.arena, q);
    if (want.name.len == 0) return call.fail(error.NotFound, "the qualified name is empty", .{});
    const found = try ci.searchWorkspace(call, want.name, 1000);
    const cands = try call.arena.alloc(locate.Candidate, found.len);
    for (found, cands) |s, *c| c.* = .{
        .name = s.name,
        .container = s.container,
        .kind = s.kind,
        .uri = if (s.location) |l| l.path else "",
    };
    switch (try locate.pick(call.arena, cands, q)) {
        .none => return call.fail(error.NotFound, "no symbol {s} in the workspace ({d} named {s} elsewhere)", .{ q, found.len, want.name }),
        .ambiguous => |at| {
            const list = try call.arena.alloc(Symbol, at.len);
            for (at, list) |i, *s| s.* = found[i];
            call.candidates = list;
            return call.fail(error.Ambiguous, "{s} matches {d} symbols; qualify it further or give a path and line", .{ q, at.len });
        },
        .one => |i| {
            const loc = found[i].location orelse return call.fail(error.NotFound, "the server gave no location for {s}", .{q});
            if (!loc.is_file) return call.fail(error.NotFound, "{s} is in {s}, not a file", .{ q, loc.path });
            // Library code (outside the roots) can be read, not edited.
            const in = ci.inside(call.arena, loc.path);
            const no_range = loc.range.start.line == std.math.maxInt(u32);
            return .{
                .abs = loc.path,
                .inside = in,
                .ref = .{ .position = .{ .path = loc.path, .line = if (no_range) 1 else loc.range.start.line + 1 } },
                .lsp = if (no_range) null else .{ .pos = loc.range.start, .enc = ci.encodingOf(call, loc.path) },
                .find = want.name,
            };
        },
    }
}

/// The position encoding of the server that answered for `path`: the
/// first running workspace-symbol server's (they are asked in order).
fn encodingOf(ci: *CodeIntel, call: *Call, _: []const u8) PositionEncoding {
    var job: struct {
        mgr: *Manager,
        enc: PositionEncoding = .utf16,
        fn run(j: *@This()) void {
            for (j.mgr.serverList()) |s| {
                if (s.status != .running) continue;
                const c = s.client orelse continue;
                const caps = c.caps() orelse continue;
                if (!caps.supports(.workspace_symbol, null)) continue;
                j.enc = c.encoding();
                return;
            }
        }
    } = .{ .mgr = ci.mgr };
    ci.onUi(call, &job) catch {};
    return job.enc;
}

/// The document of `abs`, held for the call.
fn hold(ci: *CodeIntel, call: *Call, abs: []const u8, in: bool) Error!Held {
    var job: struct {
        ci: *CodeIntel,
        call: *Call,
        abs: []const u8,
        out: Error!Held = error.NotFound,
        fn run(j: *@This()) void {
            j.out = j.get();
        }
        fn get(j: *@This()) Error!Held {
            const ci_ = j.ci;
            if (ci_.bg) |bg| {
                const h = bg.acquire(j.abs) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.FileNotFound => j.call.fail(error.NotFound, "{s} does not exist", .{j.abs}),
                    error.NoLanguage => j.call.fail(error.NoServer, "no language services for this kind of file", .{}),
                    error.TooLarge => j.call.fail(error.Refused, "the file is too large for the language servers", .{}),
                    else => j.call.fail(error.NotFound, "{s} cannot be read: {t}", .{ j.abs, e }),
                };
                return .{ .h = h, .abs = j.abs, .bg = true, .inside = false };
            }
            const h = try ci_.mgr.docs.findFile(j.abs) orelse return j.call.fail(error.NotFound, "the file is not open in the editor, so no language server has it", .{});
            if (ci_.mgr.docMatch(h) == null) return j.call.fail(error.NoServer, "no language server handles this file (unknown language, or the folder is not trusted)", .{});
            return .{ .h = h, .abs = j.abs, .bg = false, .inside = false };
        }
    } = .{ .ci = ci, .call = call, .abs = abs };
    try ci.onUi(call, &job);
    var held = try job.out;
    held.inside = in;
    return held;
}

/// Waits until a running server provides `feature` for `h`.
fn waitReady(ci: *CodeIntel, call: *Call, h: DocHandle, feature: Feature) Error!void {
    while (true) {
        var job: struct {
            mgr: *Manager,
            h: DocHandle,
            feature: Feature,
            state: enum { ready, starting, closed, unhandled, unsupported } = .closed,
            fn run(j: *@This()) void {
                const m = j.mgr;
                if (!m.docs.isValid(j.h)) return;
                if (m.docMatch(j.h) == null) {
                    j.state = .unhandled;
                    return;
                }
                var out: [1]*Client = undefined;
                if (m.clientsFor(j.h, j.feature, &out) > 0) {
                    j.state = .ready;
                    return;
                }
                if (m.starting(j.h)) {
                    j.state = .starting;
                    return;
                }
                j.state = .unhandled;
                for (m.serverList()) |s| if (s.status == .running and s.hasDoc(j.h)) {
                    j.state = .unsupported;
                };
            }
        } = .{ .mgr = ci.mgr, .h = h, .feature = feature };
        try ci.onUi(call, &job);
        switch (job.state) {
            .ready => return,
            .closed => return call.fail(error.NotFound, "the file was closed", .{}),
            .unhandled => return call.fail(error.NoServer, "no language server handles this file (none is configured or installed for its language, or the folder is not trusted)", .{}),
            .unsupported => return call.fail(error.NoServer, "the language server for this file does not provide {t}", .{feature}),
            .starting => {},
        }
        if (nowNs(call.io) >= call.deadline_ns) return call.fail(error.Timeout, "the language server did not start in time", .{});
        call.io.sleep(.fromMilliseconds(20), .awake) catch return call.fail(error.Timeout, "canceled", .{});
    }
}

/// The routed server and the position, on the UI thread.
fn locateIn(ci: *CodeIntel, call: *Call, h: DocHandle, spot: ?*const Spot, feature: Feature) Error!At {
    var job: struct {
        ci: *CodeIntel,
        call: *Call,
        h: DocHandle,
        spot: ?*const Spot,
        feature: Feature,
        out: Error!At = error.NotFound,
        fn run(j: *@This()) void {
            j.out = j.get();
        }
        fn get(j: *@This()) Error!At {
            const mgr = j.ci.mgr;
            var servers: [1]*Manager.Server = undefined;
            if (mgr.serversFor(j.h, j.feature, &servers) == 0) return j.call.fail(error.NoServer, "the language server stopped", .{});
            const s = servers[0];
            const c = s.client.?;
            const doc = mgr.docs.get(j.h) orelse return j.call.fail(error.NotFound, "the file was closed", .{});
            const uri = try j.call.arena.dupe(u8, mgr.docs.uri(j.h).?);
            var at: At = .{ .server = s, .client = c, .h = j.h, .uri = uri, .pos = .{ .line = 0, .character = 0 } };
            const sp = j.spot orelse return at;
            var m: position.Mapper = .{ .gpa = mgr.gpa, .tree = &doc.tree, .enc = position.encodingOf(c.encoding()) };
            defer m.deinit();
            var off: u64 = undefined;
            if (sp.lsp) |l| {
                var src: position.Mapper = .{ .gpa = mgr.gpa, .tree = &doc.tree, .enc = position.encodingOf(l.enc) };
                defer src.deinit();
                off = try src.byteOf(l.pos);
            } else if (sp.find != null) {
                off = 0;
            } else switch (try locate.inDocument(&m, sp.ref)) {
                .hit => |hit| {
                    off = hit.offset;
                    if (hit.line + 1 != sp.ref.line().?) j.call.adjusted_line = @intCast(hit.line + 1);
                },
                .past_end => |n| return j.call.fail(error.NotFound, "line {d} is past the end of the file ({d} lines)", .{ sp.ref.line().?, n }),
                .not_found => return j.call.fail(error.NotFound, "\"{s}\" is not on line {d} or within {d} lines of it", .{ sp.ref.name_on_line.name, sp.ref.line().?, locate.max_line_drift }),
            }
            if (sp.find) |name| {
                // A workspace symbol's range may start before its name.
                const max_lines: u64 = if (sp.lsp != null) locate.max_line_drift else std.math.maxInt(u32);
                if (try locate.forward(&m, off, name, max_lines)) |o| off = o;
            }
            at.pos = try m.positionOf(off);
            return at;
        }
    } = .{ .ci = ci, .call = call, .h = h, .spot = spot, .feature = feature };
    try ci.onUi(call, &job);
    return job.out;
}

fn Pending(comptime M: protocol.Method) type {
    return struct {
        io: Io,
        done: Io.Event = .unset,
        result: Client.Result(M) = undefined,

        fn onResult(ctx: ?*anyopaque, r: Client.Result(M)) void {
            const p: *@This() = @ptrCast(@alignCast(ctx.?));
            p.result = r;
            p.done.set(p.io);
        }
    };
}

/// Sends `M` from the UI thread (after the pending edits, so the server
/// has the text) and waits for its answer. The caller deinits it.
fn exchange(ci: *CodeIntel, call: *Call, comptime M: protocol.Method, at: At, params: protocol.RequestInfo(M).Params) Error!Client.Result(M) {
    const gpa = ci.mgr.gpa;
    const p = try gpa.create(Pending(M));
    p.* = .{ .io = call.io };
    const left = call.deadline_ns - nowNs(call.io);
    if (left <= 0) {
        gpa.destroy(p);
        return call.fail(error.Timeout, "the language server did not answer in time", .{});
    }
    var job: struct {
        mgr: *Manager,
        at: At,
        params: protocol.RequestInfo(M).Params,
        timeout: Io.Duration,
        pending: *Pending(M),
        err: ?anyerror = null,
        fn run(j: *@This()) void {
            // The server may have restarted since the position was found.
            if (j.at.server.status != .running or j.at.server.client != j.at.client) {
                j.err = error.ServerGone;
                return;
            }
            j.mgr.flush();
            const doc = if (j.at.h) |h| j.mgr.docMatch(h) else null;
            _ = j.at.client.request(M, j.params, .{ .doc = doc, .timeout = j.timeout }, .{ .ctx = j.pending, .func = Pending(M).onResult }) catch |e| {
                j.err = e;
            };
        }
    } = .{ .mgr = ci.mgr, .at = at, .params = params, .timeout = .{ .nanoseconds = left }, .pending = p };
    ci.onUi(call, &job) catch |e| {
        gpa.destroy(p);
        return e;
    };
    if (job.err) |e| {
        gpa.destroy(p);
        return if (e == error.OutOfMemory) error.OutOfMemory else call.fail(error.ServerError, "the request could not be sent: {t}", .{e});
    }
    // Requests carry a deadline, so the answer always comes.
    p.done.waitUncancelable(call.io);
    call.enc = at.client.encoding();
    const r = p.result;
    gpa.destroy(p);
    return r;
}

/// The answer's value, or the error the outcome stands for.
fn okValue(call: *Call, comptime M: protocol.Method, r: Client.Result(M)) Error!protocol.RequestInfo(M).Result {
    return switch (r) {
        .ok => |o| o.value,
        .timeout => call.fail(error.Timeout, "the language server did not answer in time", .{}),
        .lsp_error => |e| call.fail(error.ServerError, "the language server answered with an error: {s}", .{e.message}),
        .unsupported => call.fail(error.NoServer, "the language server does not provide this for the file", .{}),
        .content_modified => call.fail(error.ServerError, "the file changed while the server worked; ask again", .{}),
        .canceled, .server_gone => call.fail(error.ServerError, "the language server gave no answer ({t})", .{r}),
    };
}

/// Appends the locations in a navigation answer (locations, links, and
/// optionals and unions of them).
fn collect(call: *Call, out: *std.ArrayList(Location), v: anytype) Allocator.Error!void {
    const T = @TypeOf(v);
    if (T == protocol.Location) return out.append(call.arena, try toLocation(call, v.uri, v.range));
    if (T == protocol.LocationLink) return out.append(call.arena, try toLocation(call, v.targetUri, v.targetSelectionRange));
    switch (@typeInfo(T)) {
        .optional => if (v) |x| try collect(call, out, x),
        .pointer => for (v) |x| try collect(call, out, x),
        .@"union" => switch (v) {
            inline else => |x| try collect(call, out, x),
        },
        else => @compileError("not a location: " ++ @typeName(T)),
    }
}

fn toLocation(call: *Call, uri: []const u8, range: protocol.Range) Allocator.Error!Location {
    const d = zg_lsp.uri.docUriFromLsp(call.arena, uri) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .path = try call.arena.dupe(u8, uri), .is_file = false, .range = range, .enc = call.enc },
    };
    return switch (d) {
        .file => |p| .{ .path = try registry.normalizePath(call.arena, p, call.style), .is_file = true, .range = range, .enc = call.enc },
        .untitled, .virtual => .{ .path = try call.arena.dupe(u8, uri), .is_file = false, .range = range, .enc = call.enc },
    };
}

fn sortLocations(ls: []Location) void {
    std.mem.sort(Location, ls, {}, struct {
        fn lt(_: void, a: Location, b: Location) bool {
            switch (std.mem.order(u8, a.path, b.path)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
            return a.range.start.character < b.range.start.character;
        }
    }.lt);
}
