//! The flowchart parser (E13.F07.S02.T01): the Mermaid flowchart subset
//! to a `Diagram`. It never fails on bad input: each problem becomes a
//! diagnostic and parsing goes on at the next line. Only a missing
//! `flowchart`/`graph` header gives no diagram.

const std = @import("std");
const ast = @import("ast.zig");
const diag_mod = @import("diag.zig");
const lexer = @import("lexer.zig");

const Allocator = std.mem.Allocator;
const Span = ast.Span;
const Style = ast.Style;
const Diagnostic = diag_mod.Diagnostic;
const Cursor = lexer.Cursor;

pub const max_nodes = 5_000;
pub const max_edges = 20_000;
pub const max_label_bytes = 64 << 10;

pub const DiagramType = enum { flowchart, unsupported, unknown };

/// Mermaid's other diagram keywords.
const other_types = [_][]const u8{
    "sequenceDiagram", "classDiagram",      "classDiagram-v2", "stateDiagram",  "stateDiagram-v2",    "erDiagram",
    "journey",         "gantt",             "pie",             "quadrantChart", "requirementDiagram", "gitGraph",
    "C4Context",       "C4Container",       "C4Component",     "C4Dynamic",     "C4Deployment",       "mindmap",
    "timeline",        "zenuml",            "sankey-beta",     "xychart-beta",  "block-beta",         "packet-beta",
    "kanban",          "architecture-beta", "radar-beta",      "treemap-beta",
};

/// What kind of Mermaid diagram `src` is, from its first keyword.
pub fn detectType(src: []const u8) DiagramType {
    var c: Cursor = .init(src);
    if (!skipPreamble(&c, null)) return .unknown;
    const w = headerWord(&c);
    if (isFlowchartWord(w)) return .flowchart;
    for (other_types) |t| if (std.mem.eql(u8, w, t)) return .unsupported;
    return .unknown;
}

fn isFlowchartWord(w: []const u8) bool {
    return std.mem.eql(u8, w, "flowchart") or std.mem.eql(u8, w, "graph") or std.mem.eql(u8, w, "flowchart-elk");
}

fn headerWord(c: *Cursor) []const u8 {
    const s = c.pos;
    while (!c.eof() and !lexer.isBlank(c.src[c.pos]) and c.src[c.pos] != '\n' and c.src[c.pos] != ';') c.pos += 1;
    return c.src[s..c.pos];
}

/// Skips blank lines, comments, directives and frontmatter (handing it
/// to `p`); false when the input ends first or frontmatter is unclosed.
fn skipPreamble(c: *Cursor, p: ?*Parser) bool {
    var first = true;
    while (true) {
        const line_start = c.pos;
        c.skipBlanks();
        if (c.eof()) return false;
        if (c.at(0) == '\n') {
            c.pos += 1;
            continue;
        }
        if (first and c.pos == line_start and c.startsWith("---") and isLineEnd(c, 3)) {
            first = false;
            c.skipLine();
            const body = c.pos;
            while (true) {
                if (c.eof()) {
                    if (p) |pp| pp.err(.{ .start = line_start, .end = line_start + 3 }, "unclosed frontmatter: no closing '---'", .{});
                    return false;
                }
                if (c.startsWith("---") and isLineEnd(c, 3)) break;
                c.skipLine();
            }
            if (p) |pp| pp.frontmatter(body, c.pos);
            c.skipLine();
            continue;
        }
        first = false;
        if (c.startsWith("%%{")) {
            const s = c.pos;
            const close = std.mem.indexOf(u8, c.rest(), "}%%");
            if (p) |pp| pp.warn(.{ .start = s, .end = s + 3 }, "%%{{init}}%% directives are ignored", .{});
            if (close) |k| c.pos += @intCast(k + 3) else c.pos = @intCast(c.src.len);
            continue;
        }
        if (c.startsWith("%%")) {
            c.skipLine();
            continue;
        }
        return true;
    }
}

fn isLineEnd(c: *const Cursor, k: u32) bool {
    var i = k;
    while (lexer.isBlank(c.at(i))) i += 1;
    return c.at(i) == '\n' or c.at(i) == 0;
}

/// Parses `src`; diagnostics are appended to `diags` (strings in
/// `arena`). Null when there is no flowchart header.
pub fn parse(arena: Allocator, src: []const u8, diags: *std.ArrayList(Diagnostic)) !?ast.Diagram {
    if (src.len > std.math.maxInt(u32)) {
        try diag_mod.add(arena, diags, src, .err, .{ .start = 0, .end = 0 }, "the diagram is too large", .{});
        return null;
    }
    var p: Parser = .{ .a = arena, .src = src, .c = .init(src), .diags = diags };
    return p.run();
}

const NodeB = struct {
    id: []const u8,
    label: []const u8,
    shape: ast.Shape = .rect,
    classes: std.ArrayList([]const u8) = .empty,
    style: Style = .{},
    span: Span,
    /// Given a label or shape (not only referenced).
    declared: bool = false,
    parent: ?u32 = null,
};

const SubB = struct {
    id: []const u8,
    title: []const u8,
    dir: ?ast.Dir = null,
    parent: ?u32,
    style: Style = .{},
    classes: std.ArrayList([]const u8) = .empty,
    span: Span,
};

/// A `class` or `style` statement, applied once every node is known.
const Pending = struct { id: []const u8, span: Span, what: union(enum) { class: []const u8, style: Style } };

const NodeRef = struct { idx: u32, span: Span };

const Parser = struct {
    a: Allocator,
    src: []const u8,
    c: Cursor,
    diags: *std.ArrayList(Diagnostic),
    oom: bool = false,
    /// Set when a limit is hit: the rest is not parsed.
    stopped: bool = false,
    dir: ast.Dir = .TB,
    title: ?[]const u8 = null,
    acc_title: ?[]const u8 = null,
    acc_descr: ?[]const u8 = null,
    nodes: std.ArrayList(NodeB) = .empty,
    node_map: std.StringHashMapUnmanaged(u32) = .empty,
    edges: std.ArrayList(ast.Edge) = .empty,
    subs: std.ArrayList(SubB) = .empty,
    open: std.ArrayList(u32) = .empty,
    class_defs: std.ArrayList(ast.ClassDef) = .empty,
    link_styles: std.ArrayList(ast.LinkStyle) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    label_bytes: usize = 0,

    // -- diagnostics ------------------------------------------------------------

    fn report(p: *Parser, sev: diag_mod.Severity, span: Span, comptime fmt: []const u8, args: anytype) void {
        diag_mod.add(p.a, p.diags, p.src, sev, span, fmt, args) catch {
            p.oom = true;
        };
    }

    fn err(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) void {
        p.report(.err, span, fmt, args);
    }

    fn warn(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) void {
        p.report(.warning, span, fmt, args);
    }

    fn here(p: *const Parser) Span {
        const e = @min(p.c.pos + 1, @as(u32, @intCast(p.src.len)));
        return .{ .start = p.c.pos, .end = e };
    }

    // -- driver -------------------------------------------------------------------

    fn run(p: *Parser) !?ast.Diagram {
        if (!skipPreamble(&p.c, p)) {
            if (!diag_mod.hasErrors(p.diags.items)) p.err(.{ .start = 0, .end = 0 }, "expected 'flowchart' or 'graph'", .{});
            return p.finishOom(null);
        }
        const hs = p.c.pos;
        const w = headerWord(&p.c);
        if (!isFlowchartWord(w)) {
            const span: Span = .{ .start = hs, .end = p.c.pos };
            var known = false;
            for (other_types) |t| known = known or std.mem.eql(u8, w, t);
            if (known) p.err(span, "'{s}' diagrams are not supported; only flowcharts are", .{w}) else p.err(span, "expected 'flowchart' or 'graph', found '{s}'", .{w});
            return p.finishOom(null);
        }
        p.c.skipBlanks();
        if (!p.c.atEnd()) {
            const ds = p.c.pos;
            const d = headerWord(&p.c);
            p.dir = parseDir(d) orelse blk: {
                p.err(.{ .start = ds, .end = p.c.pos }, "unknown direction '{s}' (use TB, TD, BT, LR or RL)", .{d});
                break :blk .TB;
            };
            p.c.skipBlanks();
        }
        if (!p.c.atEnd()) {
            p.err(p.here(), "unexpected text after the header", .{});
            p.c.skipLine();
        } else if (!p.c.eof()) p.c.pos += 1;

        while (!p.c.eof() and !p.stopped and !p.oom) p.statement() catch |e| switch (e) {
            error.OutOfMemory => p.oom = true,
            error.Recover => p.c.skipLine(),
        };
        if (p.open.items.len > 0 and !p.stopped) {
            const s = p.subs.items[p.open.items[p.open.items.len - 1]];
            p.err(s.span, "subgraph '{s}' has no 'end'", .{s.id});
        }
        if (p.oom) return error.OutOfMemory;
        return try p.finish();
    }

    fn finishOom(p: *Parser, v: ?ast.Diagram) !?ast.Diagram {
        if (p.oom) return error.OutOfMemory;
        return v;
    }

    const Error = error{ OutOfMemory, Recover };

    fn statement(p: *Parser) Error!void {
        const c = &p.c;
        c.skipBlanks();
        if (c.eof()) return;
        if (c.at(0) == '\n' or c.at(0) == ';') {
            c.pos += 1;
            return;
        }
        if (c.startsWith("%%{")) {
            p.warn(.{ .start = c.pos, .end = c.pos + 3 }, "%%{{init}}%% directives are ignored", .{});
            if (std.mem.indexOf(u8, c.rest(), "}%%")) |k| c.pos += @intCast(k + 3) else c.pos = @intCast(c.src.len);
            return;
        }
        if (c.startsWith("%%")) return c.skipLine();
        const ks = c.pos;
        const w = c.peekWord();
        const after = c.at(@intCast(w.len));
        const kw_ok = after == 0 or lexer.isBlank(after) or after == '\n' or after == ';';
        if (std.mem.eql(u8, w, "end") and kw_ok) {
            c.pos += 3;
            var t = c.*;
            t.skipBlanks();
            if (lexer.scanLink(&t) != .none or t.at(0) == '&') {
                p.err(.{ .start = ks, .end = ks + 3 }, "'end' cannot be a node id; capitalize a letter (End or END)", .{});
                return error.Recover;
            }
            if (p.open.items.len == 0) {
                p.err(.{ .start = ks, .end = ks + 3 }, "'end' without an open subgraph", .{});
            } else _ = p.open.pop();
            return p.endStatement();
        }
        if (kw_ok and isKeyword(w) and !p.keywordIsNode(w)) {
            c.pos += @intCast(w.len);
            c.skipBlanks();
            if (std.mem.eql(u8, w, "subgraph")) return p.subgraph(ks);
            if (std.mem.eql(u8, w, "direction")) return p.direction();
            if (std.mem.eql(u8, w, "classDef")) return p.classDef(ks);
            if (std.mem.eql(u8, w, "class")) return p.classStmt(ks);
            if (std.mem.eql(u8, w, "style")) return p.styleStmt(ks);
            if (std.mem.eql(u8, w, "linkStyle")) return p.linkStyle(ks);
            // click, callback
            p.warn(.{ .start = ks, .end = ks + @as(u32, @intCast(w.len)) }, "'{s}' is not supported and is ignored", .{w});
            return c.skipLine();
        }
        if ((std.mem.eql(u8, w, "accTitle") or std.mem.eql(u8, w, "accDescr")) and (after == ':' or after == '{' or lexer.isBlank(after))) {
            c.pos += @intCast(w.len);
            return p.accessibility(w, ks);
        }
        return p.chain();
    }

    fn isKeyword(w: []const u8) bool {
        for ([_][]const u8{ "subgraph", "direction", "classDef", "class", "style", "linkStyle", "click", "callback" }) |k| {
            if (std.mem.eql(u8, w, k)) return true;
        }
        return false;
    }

    /// `style --> x`: a keyword used as a node id.
    fn keywordIsNode(p: *Parser, w: []const u8) bool {
        var t = p.c;
        t.pos += @intCast(w.len);
        t.skipBlanks();
        return t.atEnd() or t.at(0) == '&' or lexer.scanLink(&t) != .none;
    }

    /// The statement ends here: a newline, `;` or the end.
    fn endStatement(p: *Parser) Error!void {
        p.c.skipBlanks();
        if (p.c.eof()) return;
        if (p.c.atEnd()) {
            p.c.pos += 1;
            return;
        }
        p.err(p.here(), "unexpected '{s}'", .{p.c.rest()[0..charLen(p.c.rest())]});
        return error.Recover;
    }

    // -- nodes and links ------------------------------------------------------------

    fn chain(p: *Parser) Error!void {
        var lhs = try p.group();
        while (true) {
            p.c.skipBlanks();
            if (p.c.atEnd()) break;
            const link = switch (lexer.scanLink(&p.c)) {
                .none => {
                    p.err(p.here(), "unexpected '{s}'; expected a link such as '-->'", .{p.c.rest()[0..charLen(p.c.rest())]});
                    return error.Recover;
                },
                .err => |e| {
                    p.err(e.span, "{s}", .{e.message});
                    return error.Recover;
                },
                .link => |l| l,
            };
            p.c.skipBlanks();
            if (p.c.atEnd()) {
                p.err(link.span, "a link needs a node after it", .{});
                return error.Recover;
            }
            const rhs = try p.group();
            const text = if (link.label) |ls| try p.label(ls) else null;
            for (lhs) |f| for (rhs) |t| {
                if (p.edges.items.len >= max_edges) return p.limit(link.span, "edges", max_edges);
                try p.edges.append(p.a, .{
                    .from = f.idx,
                    .to = t.idx,
                    .style = link.style,
                    .head = link.head,
                    .tail = link.tail,
                    .label = text,
                    .min_len = link.min_len,
                    .span = .{ .start = f.span.start, .end = t.span.end },
                });
            };
            lhs = rhs;
        }
        return p.endStatement();
    }

    fn limit(p: *Parser, span: Span, what: []const u8, n: usize) Error!void {
        p.err(span, "too many {s} (the limit is {d})", .{ what, n });
        p.stopped = true;
    }

    /// `a & b & c`.
    fn group(p: *Parser) Error![]const NodeRef {
        var out: std.ArrayList(NodeRef) = .empty;
        while (true) {
            try out.append(p.a, try p.nodeRef());
            var t = p.c;
            t.skipBlanks();
            if (t.at(0) != '&') break;
            t.pos += 1;
            t.skipBlanks();
            p.c = t;
        }
        return out.items;
    }

    fn nodeRef(p: *Parser) Error!NodeRef {
        const c = &p.c;
        const start = c.pos;
        const id = c.ident() orelse {
            if (c.atEnd()) p.err(p.here(), "expected a node id", .{}) else p.err(p.here(), "expected a node id, found '{s}'", .{c.rest()[0..charLen(c.rest())]});
            return error.Recover;
        };
        if (std.mem.eql(u8, id, "end")) {
            p.err(.{ .start = start, .end = c.pos }, "'end' cannot be a node id; capitalize a letter (End or END)", .{});
            return error.Recover;
        }
        const idx = try p.node(id, .{ .start = start, .end = c.pos });
        while (true) {
            if (c.startsWith(":::")) {
                c.pos += 3;
                const cs = c.pos;
                const name = c.word() orelse {
                    p.err(p.here(), "expected a class name after ':::'", .{});
                    return error.Recover;
                };
                _ = cs;
                try p.nodes.items[idx].classes.append(p.a, name);
            } else if (c.startsWith("@{")) {
                try p.shapeObject(idx);
            } else if (lexer.shapeOpen(c)) |o| {
                switch (lexer.bracketBody(c, o)) {
                    .err => |e| {
                        p.err(e.span, "{s}", .{e.message});
                        return error.Recover;
                    },
                    .ok => |b| {
                        const n = &p.nodes.items[idx];
                        n.shape = b.shape;
                        n.label = try p.label(b.text);
                        n.declared = true;
                    },
                }
            } else break;
        }
        return .{ .idx = idx, .span = .{ .start = start, .end = c.pos } };
    }

    /// The node `id` (created on first use) as a member of the open
    /// subgraph when it has no subgraph yet.
    fn node(p: *Parser, id: []const u8, span: Span) Error!u32 {
        const gop = try p.node_map.getOrPut(p.a, id);
        if (!gop.found_existing) {
            if (p.nodes.items.len >= max_nodes) {
                _ = p.node_map.remove(id);
                try p.limit(span, "nodes", max_nodes);
                return error.Recover;
            }
            gop.value_ptr.* = @intCast(p.nodes.items.len);
            try p.nodes.append(p.a, .{ .id = id, .label = id, .span = span });
        }
        const n = &p.nodes.items[gop.value_ptr.*];
        if (n.parent == null and p.open.items.len > 0) n.parent = p.open.items[p.open.items.len - 1];
        return gop.value_ptr.*;
    }

    /// `id@{ shape: diam, label: "Decide" }`.
    fn shapeObject(p: *Parser, idx: u32) Error!void {
        const c = &p.c;
        const open_at = c.pos;
        c.pos += 2;
        const close = std.mem.indexOfScalar(u8, c.rest(), '}') orelse {
            p.err(.{ .start = open_at, .end = open_at + 2 }, "unclosed '@{{'", .{});
            return error.Recover;
        };
        const body_start = c.pos;
        const body = c.rest()[0..close];
        c.pos += @intCast(close + 1);
        var it = splitTopLevel(body);
        while (it.next()) |part| {
            const off: u32 = body_start + @as(u32, @intCast(@intFromPtr(part.ptr) - @intFromPtr(body.ptr)));
            const colon = std.mem.indexOfScalar(u8, part, ':') orelse {
                if (std.mem.trim(u8, part, " \t\r\n").len > 0) p.err(.{ .start = off, .end = off + @as(u32, @intCast(part.len)) }, "expected 'key: value'", .{});
                continue;
            };
            const key = std.mem.trim(u8, part[0..colon], " \t\r\n");
            const vspan = trimSpan(p.src, .{ .start = off + @as(u32, @intCast(colon + 1)), .end = off + @as(u32, @intCast(part.len)) });
            const kspan: Span = .{ .start = off, .end = off + @as(u32, @intCast(colon)) };
            const n = &p.nodes.items[idx];
            if (std.mem.eql(u8, key, "shape")) {
                const v = unquote(p.src[vspan.start..vspan.end]);
                n.shape = shapeByName(v) orelse blk: {
                    p.warn(vspan, "shape '{s}' is not supported; drawn as a rectangle", .{v});
                    break :blk .rect;
                };
                n.declared = true;
            } else if (std.mem.eql(u8, key, "label")) {
                n.label = try p.label(vspan);
                n.declared = true;
            } else p.warn(kspan, "'{s}' is ignored", .{key});
        }
    }

    // -- labels -----------------------------------------------------------------------

    /// A label's text: unquoted, Markdown emphasis stripped, `<br>` as a
    /// newline, `#quot;` and `#35;` entities decoded.
    fn label(p: *Parser, span: Span) Error![]const u8 {
        const out = try labelText(p.a, p.src[span.start..span.end]);
        p.label_bytes += out.len;
        if (p.label_bytes > max_label_bytes) {
            try p.limit(span, "label bytes", max_label_bytes);
            return error.Recover;
        }
        return out;
    }

    // -- statements -----------------------------------------------------------------

    fn subgraph(p: *Parser, ks: u32) Error!void {
        const c = &p.c;
        const line = c.lineRest();
        const end_rel = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const text_start = c.pos;
        const text = std.mem.trimEnd(u8, line[0..end_rel], " \t\r");
        var id: []const u8 = undefined;
        var title: []const u8 = undefined;
        if (text.len == 0) {
            p.err(.{ .start = ks, .end = c.pos }, "a subgraph needs an id or a title", .{});
            return error.Recover;
        }
        if (text[0] == '"') {
            title = try p.label(.{ .start = text_start, .end = text_start + @as(u32, @intCast(text.len)) });
            id = try std.fmt.allocPrint(p.a, "subGraph{d}", .{p.subs.items.len});
        } else if (std.mem.indexOfScalar(u8, text, '[')) |b| {
            id = std.mem.trim(u8, text[0..b], " \t");
            if (text[text.len - 1] != ']') {
                p.err(.{ .start = text_start + @as(u32, @intCast(b)), .end = text_start + @as(u32, @intCast(text.len)) }, "unclosed '[' in the subgraph title", .{});
                return error.Recover;
            }
            title = try p.label(.{ .start = text_start + @as(u32, @intCast(b + 1)), .end = text_start + @as(u32, @intCast(text.len - 1)) });
            if (id.len == 0) id = try std.fmt.allocPrint(p.a, "subGraph{d}", .{p.subs.items.len});
        } else {
            id = text;
            title = text;
        }
        c.pos = text_start + @as(u32, @intCast(end_rel));
        for (p.subs.items) |s| if (std.mem.eql(u8, s.id, id)) {
            p.err(.{ .start = ks, .end = c.pos }, "duplicate subgraph id '{s}'", .{id});
            return error.Recover;
        };
        const parent: ?u32 = if (p.open.items.len > 0) p.open.items[p.open.items.len - 1] else null;
        const idx: u32 = @intCast(p.subs.items.len);
        try p.subs.append(p.a, .{ .id = id, .title = title, .parent = parent, .span = .{ .start = ks, .end = c.pos } });
        try p.open.append(p.a, idx);
        return p.endStatement();
    }

    fn direction(p: *Parser) Error!void {
        const s = p.c.pos;
        const w = headerWord(&p.c);
        const d = parseDir(w) orelse {
            p.err(.{ .start = s, .end = p.c.pos }, "unknown direction '{s}' (use TB, TD, BT, LR or RL)", .{w});
            return error.Recover;
        };
        if (p.open.items.len > 0) p.subs.items[p.open.items[p.open.items.len - 1]].dir = d else p.dir = d;
        return p.endStatement();
    }

    /// The rest of the statement (to `;` or the newline) as a span.
    fn restSpan(p: *Parser) Span {
        const s = p.c.pos;
        while (!p.c.atEnd()) p.c.pos += 1;
        return trimSpan(p.src, .{ .start = s, .end = p.c.pos });
    }

    /// `a,b,c` up to the first blank.
    fn nameList(p: *Parser) Error![]const []const u8 {
        const s = p.c.pos;
        while (!p.c.atEnd() and !lexer.isBlank(p.c.at(0))) p.c.pos += 1;
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, p.src[s..p.c.pos], ',');
        while (it.next()) |n| {
            const t = std.mem.trim(u8, n, " \t");
            if (t.len > 0) try out.append(p.a, t);
        }
        if (out.items.len == 0) {
            p.err(p.here(), "expected a name", .{});
            return error.Recover;
        }
        p.c.skipBlanks();
        return out.items;
    }

    fn classDef(p: *Parser, ks: u32) Error!void {
        const names = try p.nameList();
        const span = p.restSpan();
        const st = try p.styleProps(span);
        for (names) |n| try p.class_defs.append(p.a, .{ .name = n, .style = st, .span = .{ .start = ks, .end = span.end } });
        return p.endStatement();
    }

    fn classStmt(p: *Parser, ks: u32) Error!void {
        const ids = try p.nameList();
        const span = p.restSpan();
        const name = p.src[span.start..span.end];
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t,") != null) {
            p.err(if (name.len == 0) p.here() else span, "expected one class name", .{});
            return error.Recover;
        }
        for (ids) |id| try p.pending.append(p.a, .{ .id = id, .span = .{ .start = ks, .end = span.end }, .what = .{ .class = name } });
        return p.endStatement();
    }

    fn styleStmt(p: *Parser, ks: u32) Error!void {
        const ids = try p.nameList();
        const span = p.restSpan();
        const st = try p.styleProps(span);
        for (ids) |id| try p.pending.append(p.a, .{ .id = id, .span = .{ .start = ks, .end = span.end }, .what = .{ .style = st } });
        return p.endStatement();
    }

    fn linkStyle(p: *Parser, ks: u32) Error!void {
        const which = try p.nameList();
        const span = p.restSpan();
        const st = try p.styleProps(span);
        for (which) |w| {
            const index: ?u32 = if (std.mem.eql(u8, w, "default")) null else std.fmt.parseInt(u32, w, 10) catch {
                p.err(.{ .start = ks, .end = span.start }, "linkStyle takes edge numbers or 'default', not '{s}'", .{w});
                return error.Recover;
            };
            try p.link_styles.append(p.a, .{ .index = index, .style = st, .span = .{ .start = ks, .end = span.end } });
        }
        return p.endStatement();
    }

    fn accessibility(p: *Parser, w: []const u8, ks: u32) Error!void {
        const c = &p.c;
        c.skipBlanks();
        var span: Span = undefined;
        if (c.at(0) == '{') {
            const close = std.mem.indexOfScalar(u8, c.rest(), '}') orelse {
                p.err(.{ .start = ks, .end = c.pos + 1 }, "unclosed '{{'", .{});
                return error.Recover;
            };
            span = trimSpan(p.src, .{ .start = c.pos + 1, .end = c.pos + @as(u32, @intCast(close)) });
            c.pos += @intCast(close + 1);
        } else {
            if (c.at(0) == ':') c.pos += 1;
            const s = c.pos;
            c.pos += @intCast(c.lineRest().len);
            span = trimSpan(p.src, .{ .start = s, .end = c.pos });
        }
        const text = p.src[span.start..span.end];
        if (std.mem.eql(u8, w, "accTitle")) p.acc_title = text else p.acc_descr = text;
        return p.endStatement();
    }

    /// `fill:#f9f,stroke:#333,stroke-width:4px,stroke-dasharray: 5 5`.
    fn styleProps(p: *Parser, span: Span) Error!Style {
        var st: Style = .{};
        const text = p.src[span.start..span.end];
        // Pieces without a colon continue the previous value (`5, 5`).
        var pieces: std.ArrayList(Span) = .empty;
        var i: usize = 0;
        while (i <= text.len) {
            const j = std.mem.indexOfScalarPos(u8, text, i, ',') orelse text.len;
            const piece = text[i..j];
            const ps: Span = .{ .start = span.start + @as(u32, @intCast(i)), .end = span.start + @as(u32, @intCast(j)) };
            if (std.mem.indexOfScalar(u8, piece, ':') == null and pieces.items.len > 0) {
                pieces.items[pieces.items.len - 1].end = ps.end;
            } else try pieces.append(p.a, ps);
            i = j + 1;
        }
        for (pieces.items) |ps| {
            const piece = p.src[ps.start..ps.end];
            if (std.mem.trim(u8, piece, " \t").len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, piece, ':') orelse {
                p.err(trimSpan(p.src, ps), "expected 'property:value'", .{});
                continue;
            };
            const key = std.mem.trim(u8, piece[0..colon], " \t");
            var val = std.mem.trim(u8, piece[colon + 1 ..], " \t");
            if (std.mem.endsWith(u8, val, "!important")) val = std.mem.trimEnd(u8, val[0 .. val.len - "!important".len], " \t");
            const vspan = trimSpan(p.src, .{ .start = ps.start + @as(u32, @intCast(colon + 1)), .end = ps.end });
            if (std.mem.eql(u8, key, "fill") or std.mem.eql(u8, key, "stroke") or std.mem.eql(u8, key, "color")) {
                const col = parseColor(val) orelse {
                    p.err(vspan, "invalid colour '{s}'", .{val});
                    continue;
                };
                if (key[0] == 'f') st.fill = col else if (key[0] == 's') st.stroke = col else st.color = col;
            } else if (std.mem.eql(u8, key, "stroke-width")) {
                st.stroke_width = parseLength(val) orelse {
                    p.err(vspan, "invalid width '{s}'", .{val});
                    continue;
                };
            } else if (std.mem.eql(u8, key, "stroke-dasharray")) {
                var dashes: std.ArrayList(f32) = .empty;
                var it = std.mem.tokenizeAny(u8, val, " ,\t");
                var ok = true;
                while (it.next()) |d| {
                    const v = parseLength(d) orelse {
                        ok = false;
                        break;
                    };
                    try dashes.append(p.a, v);
                }
                if (!ok or dashes.items.len == 0) {
                    p.err(vspan, "invalid dash pattern '{s}'", .{val});
                    continue;
                }
                st.stroke_dasharray = dashes.items;
            } else p.warn(trimSpan(p.src, .{ .start = ps.start, .end = ps.start + @as(u32, @intCast(colon)) }), "style '{s}' is ignored", .{key});
        }
        return st;
    }

    // -- frontmatter ------------------------------------------------------------------

    fn frontmatter(p: *Parser, start: u32, end: u32) void {
        var it = std.mem.splitScalar(u8, p.src[start..end], '\n');
        var off = start;
        while (it.next()) |line| : (off += @intCast(line.len + 1)) {
            const t = std.mem.trimEnd(u8, line, " \t\r");
            if (std.mem.startsWith(u8, t, "title:")) {
                p.title = unquote(std.mem.trim(u8, t["title:".len..], " \t"));
            } else if (t.len > 0 and t[0] != ' ' and t[0] != '\t' and t[0] != '#') {
                const colon = std.mem.indexOfScalar(u8, t, ':') orelse t.len;
                p.warn(.{ .start = off, .end = off + @as(u32, @intCast(colon)) }, "frontmatter '{s}' is ignored", .{t[0..colon]});
            }
        }
    }

    // -- the result -------------------------------------------------------------------

    fn finish(p: *Parser) !ast.Diagram {
        const a = p.a;
        // Pending class and style statements.
        for (p.pending.items) |pd| {
            const sub = p.subIndex(pd.id);
            if (p.node_map.get(pd.id)) |ni| {
                const n = &p.nodes.items[ni];
                switch (pd.what) {
                    .class => |c| try n.classes.append(a, c),
                    .style => |s| n.style = n.style.merge(s),
                }
            } else if (sub) |si| {
                const s = &p.subs.items[si];
                switch (pd.what) {
                    .class => |c| try s.classes.append(a, c),
                    .style => |st| s.style = s.style.merge(st),
                }
            } else p.warn(pd.span, "unknown node '{s}'", .{pd.id});
        }
        // Nodes that only name a subgraph are edges to its cluster.
        const remap = try a.alloc(?u32, p.nodes.items.len);
        const cluster = try a.alloc(?u32, p.nodes.items.len);
        var nodes: std.ArrayList(ast.Node) = .empty;
        for (p.nodes.items, 0..) |*n, i| {
            cluster[i] = null;
            remap[i] = null;
            if (!n.declared and n.classes.items.len == 0 and n.style.isEmpty()) {
                if (p.subIndex(n.id)) |si| {
                    cluster[i] = si;
                    continue;
                }
            }
            remap[i] = @intCast(nodes.items.len);
            try nodes.append(a, .{ .id = n.id, .label = n.label, .shape = n.shape, .classes = n.classes.items, .style = n.style, .span = n.span });
        }
        for (p.edges.items) |*e| {
            if (cluster[e.from]) |si| {
                e.from = si;
                e.from_kind = .subgraph;
            } else e.from = remap[e.from].?;
            if (cluster[e.to]) |si| {
                e.to = si;
                e.to_kind = .subgraph;
            } else e.to = remap[e.to].?;
        }
        const subs = try a.alloc(ast.Subgraph, p.subs.items.len);
        for (subs, p.subs.items, 0..) |*s, b, si| {
            var members: std.ArrayList(u32) = .empty;
            for (p.nodes.items, 0..) |n, ni| if (n.parent == @as(u32, @intCast(si))) if (remap[ni]) |r| try members.append(a, r);
            var children: std.ArrayList(u32) = .empty;
            for (p.subs.items, 0..) |o, oi| if (o.parent == @as(u32, @intCast(si))) try children.append(a, @intCast(oi));
            s.* = .{ .id = b.id, .title = b.title, .dir = b.dir, .members = members.items, .children = children.items, .style = b.style, .classes = b.classes.items, .span = b.span };
        }
        for (p.link_styles.items) |ls| if (ls.index) |ix| if (ix >= p.edges.items.len) {
            p.err(ls.span, "linkStyle {d}: there are only {d} links", .{ ix, p.edges.items.len });
        };
        if (p.oom) return error.OutOfMemory;
        return .{
            .dir = p.dir,
            .title = p.title,
            .acc_title = p.acc_title,
            .acc_descr = p.acc_descr,
            .nodes = nodes.items,
            .edges = p.edges.items,
            .subgraphs = subs,
            .class_defs = p.class_defs.items,
            .link_styles = p.link_styles.items,
        };
    }

    fn subIndex(p: *const Parser, id: []const u8) ?u32 {
        for (p.subs.items, 0..) |s, i| if (std.mem.eql(u8, s.id, id)) return @intCast(i);
        return null;
    }
};

// -- helpers --------------------------------------------------------------------------

fn charLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return @min(n, s.len);
}

fn trimSpan(src: []const u8, s: Span) Span {
    var a = s.start;
    var b = s.end;
    while (a < b and std.ascii.isWhitespace(src[a])) a += 1;
    while (b > a and std.ascii.isWhitespace(src[b - 1])) b -= 1;
    return .{ .start = a, .end = b };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) return s[1 .. s.len - 1];
    return s;
}

pub fn parseDir(w: []const u8) ?ast.Dir {
    const map = [_]struct { []const u8, ast.Dir }{
        .{ "TB", .TB }, .{ "TD", .TB }, .{ "BT", .BT }, .{ "LR", .LR }, .{ "RL", .RL },
        .{ "v", .TB },  .{ "^", .BT },  .{ ">", .LR },  .{ "<", .RL },
    };
    for (map) |m| if (std.mem.eql(u8, w, m[0])) return m[1];
    return null;
}

/// Commas outside quotes.
fn splitTopLevel(s: []const u8) struct {
    s: []const u8,
    i: usize = 0,
    fn next(it: *@This()) ?[]const u8 {
        if (it.i > it.s.len) return null;
        const start = it.i;
        var q: ?u8 = null;
        while (it.i < it.s.len) : (it.i += 1) {
            const ch = it.s[it.i];
            if (q) |qc| {
                if (ch == qc) q = null;
            } else if (ch == '"' or ch == '\'') {
                q = ch;
            } else if (ch == ',') break;
        }
        const out = it.s[start..it.i];
        it.i += 1;
        return out;
    }
} {
    return .{ .s = s };
}

/// Mermaid's `@{ shape: … }` names for the shapes drawn.
pub fn shapeByName(n: []const u8) ?ast.Shape {
    const map = [_]struct { []const u8, ast.Shape }{
        .{ "rect", .rect },                   .{ "rectangle", .rect },              .{ "proc", .rect },                .{ "process", .rect },
        .{ "rounded", .round },               .{ "event", .round },                 .{ "stadium", .stadium },          .{ "pill", .stadium },
        .{ "terminal", .stadium },            .{ "subproc", .subroutine },          .{ "subprocess", .subroutine },    .{ "fr-rect", .subroutine },
        .{ "framed-rectangle", .subroutine }, .{ "cyl", .cylinder },                .{ "cylinder", .cylinder },        .{ "database", .cylinder },
        .{ "db", .cylinder },                 .{ "circle", .circle },               .{ "circ", .circle },              .{ "dbl-circ", .double_circle },
        .{ "double-circle", .double_circle }, .{ "odd", .asymmetric },              .{ "diam", .rhombus },             .{ "diamond", .rhombus },
        .{ "decision", .rhombus },            .{ "question", .rhombus },            .{ "hex", .hexagon },              .{ "hexagon", .hexagon },
        .{ "prepare", .hexagon },             .{ "lean-r", .parallelogram },        .{ "lean-right", .parallelogram }, .{ "in-out", .parallelogram },
        .{ "lean-l", .parallelogram_alt },    .{ "lean-left", .parallelogram_alt }, .{ "out-in", .parallelogram_alt }, .{ "trap-b", .trapezoid },
        .{ "trapezoid-bottom", .trapezoid },  .{ "priority", .trapezoid },          .{ "trap-t", .trapezoid_alt },     .{ "trapezoid-top", .trapezoid_alt },
        .{ "manual", .trapezoid_alt },
    };
    for (map) |m| if (std.mem.eql(u8, n, m[0])) return m[1];
    return null;
}

const named_colors = [_]struct { []const u8, u32 }{
    .{ "black", 0x000000 },      .{ "white", 0xffffff },     .{ "red", 0xff0000 },      .{ "green", 0x008000 },     .{ "blue", 0x0000ff },
    .{ "yellow", 0xffff00 },     .{ "orange", 0xffa500 },    .{ "purple", 0x800080 },   .{ "gray", 0x808080 },      .{ "grey", 0x808080 },
    .{ "pink", 0xffc0cb },       .{ "brown", 0xa52a2a },     .{ "cyan", 0x00ffff },     .{ "magenta", 0xff00ff },   .{ "lime", 0x00ff00 },
    .{ "navy", 0x000080 },       .{ "teal", 0x008080 },      .{ "olive", 0x808000 },    .{ "maroon", 0x800000 },    .{ "silver", 0xc0c0c0 },
    .{ "gold", 0xffd700 },       .{ "indigo", 0x4b0082 },    .{ "violet", 0xee82ee },   .{ "coral", 0xff7f50 },     .{ "salmon", 0xfa8072 },
    .{ "tomato", 0xff6347 },     .{ "crimson", 0xdc143c },   .{ "khaki", 0xf0e68c },    .{ "beige", 0xf5f5dc },     .{ "ivory", 0xfffff0 },
    .{ "lavender", 0xe6e6fa },   .{ "plum", 0xdda0dd },      .{ "orchid", 0xda70d6 },   .{ "turquoise", 0x40e0d0 }, .{ "aqua", 0x00ffff },
    .{ "fuchsia", 0xff00ff },    .{ "chocolate", 0xd2691e }, .{ "tan", 0xd2b48c },      .{ "wheat", 0xf5deb3 },     .{ "lightgray", 0xd3d3d3 },
    .{ "lightgrey", 0xd3d3d3 },  .{ "darkgray", 0xa9a9a9 },  .{ "darkgrey", 0xa9a9a9 }, .{ "lightblue", 0xadd8e6 }, .{ "darkblue", 0x00008b },
    .{ "lightgreen", 0x90ee90 }, .{ "darkgreen", 0x006400 }, .{ "darkred", 0x8b0000 },  .{ "steelblue", 0x4682b4 }, .{ "skyblue", 0x87ceeb },
};

/// A colour as 0xAARRGGBB (alpha 0xff unless `#rgba`/`#rrggbbaa`;
/// `none` and `transparent` are 0): `#rgb`, `#rgba`, `#rrggbb`,
/// `#rrggbbaa` or a common CSS name.
pub fn parseColor(s: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(s, "none") or std.ascii.eqlIgnoreCase(s, "transparent")) return 0;
    if (s.len > 1 and s[0] == '#') {
        const h = s[1..];
        const v = std.fmt.parseInt(u32, h, 16) catch return null;
        return switch (h.len) {
            3 => 0xff000000 | expand(v >> 8) << 16 | expand((v >> 4) & 0xf) << 8 | expand(v & 0xf),
            4 => expand(v & 0xf) << 24 | expand(v >> 12) << 16 | expand((v >> 8) & 0xf) << 8 | expand((v >> 4) & 0xf),
            6 => 0xff000000 | v,
            8 => (v & 0xff) << 24 | v >> 8,
            else => null,
        };
    }
    for (named_colors) |c| if (std.ascii.eqlIgnoreCase(s, c[0])) return 0xff000000 | c[1];
    return null;
}

fn expand(n: u32) u32 {
    return n * 0x11;
}

fn parseLength(s: []const u8) ?f32 {
    const t = if (std.mem.endsWith(u8, s, "px")) s[0 .. s.len - 2] else s;
    const v = std.fmt.parseFloat(f32, t) catch return null;
    if (!std.math.isFinite(v) or v < 0 or v > 1000) return null;
    return v;
}

/// A label's display text (see `Parser.label`).
pub fn labelText(a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    var markdown = false;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        s = s[1 .. s.len - 1];
        if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') {
            s = s[1 .. s.len - 1];
            markdown = true;
        }
    }
    if (!markdown and std.mem.indexOfAny(u8, s, "<#") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (markdown) {
            if (ch == '*') {
                i += 1;
                continue;
            }
            if (ch == '\n') {
                while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                try out.append(a, '\n');
                i += 1;
                while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r')) i += 1;
                continue;
            }
        }
        if (ch == '<') if (brLen(s[i..])) |n| {
            try out.append(a, '\n');
            i += n;
            continue;
        };
        if (ch == '#') if (entity(s[i..])) |e| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(e.cp, &buf) catch 0;
            try out.appendSlice(a, buf[0..n]);
            i += e.len;
            continue;
        };
        try out.append(a, ch);
        i += 1;
    }
    return out.items;
}

/// The length of the `<br>`, `<br/>` or `<br />` at the start of `s`.
fn brLen(s: []const u8) ?usize {
    for ([_][]const u8{ "<br>", "<br/>", "<br />" }) |br| {
        if (s.len >= br.len and std.ascii.eqlIgnoreCase(s[0..br.len], br)) return br.len;
    }
    return null;
}

/// `#quot;`, `#35;`, `#x2014;`: the code point and the entity's length.
fn entity(s: []const u8) ?struct { cp: u21, len: usize } {
    const semi = std.mem.indexOfScalar(u8, s[0..@min(s.len, 12)], ';') orelse return null;
    const body = s[1..semi];
    if (body.len == 0) return null;
    const named = [_]struct { []const u8, u21 }{
        .{ "quot", '"' }, .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "apos", '\'' }, .{ "nbsp", 0xa0 }, .{ "hash", '#' },
    };
    for (named) |n| if (std.mem.eql(u8, body, n[0])) return .{ .cp = n[1], .len = semi + 1 };
    const v = if (body[0] == 'x' or body[0] == 'X')
        std.fmt.parseInt(u21, body[1..], 16) catch return null
    else
        std.fmt.parseInt(u21, body, 10) catch return null;
    if (v == 0 or v > 0x10ffff or (v >= 0xd800 and v <= 0xdfff)) return null;
    return .{ .cp = v, .len = semi + 1 };
}

test {
    std.testing.refAllDecls(@This());
}
