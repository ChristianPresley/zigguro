//! prlint rules: branch names, PR titles, commit messages and required doc
//! headings. Hand-written matchers (no regex engine: zg_regex sits higher
//! in the layer table).

const std = @import("std");
const packages = @import("zg_packages");
const build_api = @import("zg_build_api");

/// One rule violation.
pub const Finding = struct { rule: []const u8, message: []const u8 };

/// Conventional-commit types accepted everywhere.
pub const types = [_][]const u8{ "feat", "fix", "docs", "refactor", "perf", "test", "build", "ci", "chore" };

/// Non-package scopes.
pub const extra_scopes = [_][]const u8{ "build", "ci", "docs", "repo", "tools", "apps" };

fn isType(s: []const u8) bool {
    for (types) |t| if (std.mem.eql(u8, t, s)) return true;
    return false;
}

/// True if `s` is a package short name (from build/packages.zig) or an extra scope.
pub fn isScope(s: []const u8) bool {
    inline for (packages.all) |p| if (std.mem.eql(u8, comptime p.short(), s)) return true;
    for (extra_scopes) |e| if (std.mem.eql(u8, e, s)) return true;
    return false;
}

fn digits2(s: []const u8, i: usize) bool {
    return i + 2 <= s.len and std.ascii.isDigit(s[i]) and std.ascii.isDigit(s[i + 1]);
}

/// Length of a spec ID (`E05`, `E05.F02`, `E05.F02.S01`, `E05.F02.S01.T03`)
/// at the start of `s`, with letters in `upper` or lower case; 0 if none.
pub fn specIdLen(s: []const u8, upper: bool) usize {
    const letters = if (upper) "EFST" else "efst";
    if (s.len < 3 or s[0] != letters[0] or !digits2(s, 1)) return 0;
    var n: usize = 3;
    for (letters[1..]) |l| {
        if (n + 4 <= s.len and s[n] == '.' and s[n + 1] == l and digits2(s, n + 2)) n += 4 else break;
    }
    return n;
}

/// Branch: `<type>/e00[.f01[.s01[.t01]]]-<slug>` with a lowercase slug, or
/// `claude/<slug>` for branches created by the Claude agent harness.
pub fn checkBranch(name: []const u8) ?Finding {
    const bad: Finding = .{ .rule = "branch", .message = "branch must be <type>/<spec-id>-<slug>, e.g. feat/e00.f05.s01.t01-framers (lowercase)" };
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return bad;
    const head = name[0..slash];
    const rest = name[slash + 1 ..];
    if (std.mem.eql(u8, head, "claude")) return if (isSlug(rest)) null else bad;
    if (!isType(head)) return bad;
    const n = specIdLen(rest, false);
    if (n == 0 or n + 1 >= rest.len or rest[n] != '-') return bad;
    return if (isSlug(rest[n + 1 ..])) null else bad;
}

fn isSlug(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

/// Parses `type(scope)!: ` and returns the description, or a finding.
fn conventionalHeader(line: []const u8, rule: []const u8) union(enum) { ok: []const u8, bad: Finding } {
    var i: usize = 0;
    while (i < line.len and std.ascii.isLower(line[i])) i += 1;
    if (!isType(line[0..i])) return .{ .bad = .{ .rule = rule, .message = "must start with a conventional type: feat, fix, docs, refactor, perf, test, build, ci or chore" } };
    if (i < line.len and line[i] == '(') {
        const close = std.mem.indexOfScalarPos(u8, line, i, ')') orelse return .{ .bad = .{ .rule = rule, .message = "unterminated (scope)" } };
        if (!isScope(line[i + 1 .. close])) return .{ .bad = .{ .rule = rule, .message = "unknown scope: use a package short name (core, net, ...) or build, ci, docs, repo, tools, apps" } };
        i = close + 1;
    }
    if (i < line.len and line[i] == '!') i += 1;
    if (!std.mem.startsWith(u8, line[i..], ": ") or line.len <= i + 2) return .{ .bad = .{ .rule = rule, .message = "expected ': <description>' after the type/scope" } };
    return .{ .ok = line[i + 2 ..] };
}

/// PR title: `type(scope)!: description [E00.F01...]`.
pub fn checkTitle(title: []const u8) ?Finding {
    const desc = switch (conventionalHeader(title, "title")) {
        .ok => |d| d,
        .bad => |f| return f,
    };
    const missing: Finding = .{ .rule = "title", .message = "title must end with the spec ID in brackets, e.g. ' [E00.F05.S01.T01]'" };
    if (desc.len < 6 or desc[desc.len - 1] != ']') return missing;
    const open = std.mem.lastIndexOfScalar(u8, desc, '[') orelse return missing;
    if (open < 2 or desc[open - 1] != ' ') return missing;
    const id = desc[open + 1 .. desc.len - 1];
    if (specIdLen(id, true) != id.len) return missing;
    return null;
}

/// Commit message: conventional header line plus a `Spec: <ID>` footer line.
pub fn checkCommit(msg: []const u8) ?Finding {
    const first = std.mem.sliceTo(msg, '\n');
    switch (conventionalHeader(first, "commit")) {
        .ok => {},
        .bad => |f| return f,
    }
    var it = std.mem.splitScalar(u8, msg, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r ");
        if (std.mem.startsWith(u8, l, "Spec: ")) {
            const id = l["Spec: ".len..];
            if (id.len > 0 and specIdLen(id, true) == id.len) return null;
        }
    }
    return .{ .rule = "commit", .message = "commit message needs a 'Spec: <ID>' footer line, e.g. 'Spec: E00.F05.S01.T01'" };
}

/// A document and the headings it must contain.
pub const RequiredDoc = struct { path: []const u8, headings: []const []const u8 };

/// Every doc whose headings agents grep for.
pub const required_docs = [_]RequiredDoc{
    .{ .path = "docs/AGENTS.md", .headings = &.{ "## Picking work", "## Claiming", "## Branches", "## Commits", "## Pull requests", "## Definition of done", "## Cross-package changes", "## When blocked", "## Hard rules" } },
    .{ .path = "docs/CONTRIBUTING.md", .headings = &.{ "## Toolchain", "## Building", "## Testing", "## Benchmarks", "## Fuzzing", "## Style", "## Package layout", "## Layering", "## ADRs" } },
    .{ .path = "docs/definition-of-done.md", .headings = &.{} },
    .{ .path = "docs/ownership.md", .headings = &.{} },
    .{ .path = "docs/testing.md", .headings = &.{ "## Golden tests", "## Fuzzing" } },
    .{ .path = "docs/bench-format.md", .headings = &.{} },
    .{ .path = "docs/build-options.md", .headings = &.{"| Option | Type | Default | Forwarded | zg_options field | Owner | Purpose |"} },
    .{ .path = "docs/interfaces.md", .headings = &.{} },
    .{ .path = "AGENTS.md", .headings = &.{} },
};

/// Subsections every `## <interface>` in docs/interfaces.md must have.
pub const interface_subsections = [_][]const u8{ "### Defined in", "### Implemented by", "### Consumed by", "### Signature", "### Threading", "### Ownership/lifetime", "### Stability" };

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, std.mem.trimEnd(u8, l, "\r "), line)) return true;
    return false;
}

/// Checks the required docs, every ADR and the interfaces document. Findings
/// and their messages are allocated in `arena`.
pub fn checkDocsHeadings(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (required_docs) |doc| {
        const text = root.readFileAlloc(io, doc.path, arena, .limited(4 << 20)) catch {
            try out.append(arena, .{ .rule = "docs", .message = try std.fmt.allocPrint(arena, "missing {s}", .{doc.path}) });
            continue;
        };
        for (doc.headings) |h| if (!hasLine(text, h)) {
            try out.append(arena, .{ .rule = "docs", .message = try std.fmt.allocPrint(arena, "{s}: missing '{s}'", .{ doc.path, h }) });
        };
        if (std.mem.eql(u8, doc.path, "docs/interfaces.md")) try checkInterfaces(arena, text, &out);
        if (std.mem.eql(u8, doc.path, "docs/build-options.md")) try checkBuildOptions(arena, text, &out);
    }
    try checkAdrs(arena, io, root, &out);
    return out.items;
}

/// Each `## ` section of interfaces.md must carry all seven subsections.
pub fn checkInterfaces(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Finding)) !void {
    var sections = std.mem.splitSequence(u8, text, "\n## ");
    _ = sections.next(); // preamble
    var count: usize = 0;
    while (sections.next()) |sec| {
        count += 1;
        const title = std.mem.sliceTo(sec, '\n');
        for (interface_subsections) |sub| if (!hasLine(sec, sub)) {
            try out.append(arena, .{ .rule = "docs", .message = try std.fmt.allocPrint(arena, "docs/interfaces.md: '## {s}' lacks '{s}'", .{ title, sub }) });
        };
    }
    if (count == 0) try out.append(arena, .{ .rule = "docs", .message = "docs/interfaces.md has no interface sections" });
}

/// Every forwarded `zg_build.Args` option must appear in build-options.md.
pub fn checkBuildOptions(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Finding)) !void {
    inline for (@typeInfo(build_api.Args).@"struct".fields) |f| {
        const needle = "`-D" ++ f.name;
        if (std.mem.indexOf(u8, text, needle) == null) {
            try out.append(arena, .{ .rule = "docs", .message = "docs/build-options.md does not list -D" ++ f.name });
        }
    }
}

fn checkAdrs(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, out: *std.ArrayList(Finding)) !void {
    var dir = root.openDir(io, "docs/adr", .{ .iterate = true }) catch {
        try out.append(arena, .{ .rule = "docs", .message = "missing docs/adr/" });
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".md") or std.mem.eql(u8, e.name, "README.md")) continue;
        const text = try dir.readFileAlloc(io, e.name, arena, .limited(1 << 20));
        if (try checkAdr(arena, e.name, text)) |f| try out.append(arena, f);
    }
}

/// Validates one ADR: title line, Status value, Date and required sections.
pub fn checkAdr(arena: std.mem.Allocator, name: []const u8, text: []const u8) !?Finding {
    const required = [_][]const u8{ "## Context", "## Decision", "## Consequences", "## References" };
    if (!std.mem.startsWith(u8, text, "# ")) return .{ .rule = "adr", .message = try std.fmt.allocPrint(arena, "{s}: must start with '# NNNN. Title'", .{name}) };
    for (required) |h| if (!hasLine(text, h)) return .{ .rule = "adr", .message = try std.fmt.allocPrint(arena, "{s}: missing '{s}'", .{ name, h }) };
    var status_ok = false;
    var date_ok = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "Status: ")) {
            const v = std.mem.trimEnd(u8, l["Status: ".len..], "\r ");
            for ([_][]const u8{ "Proposed", "Accepted", "Deprecated" }) |s| if (std.mem.eql(u8, v, s)) {
                status_ok = true;
            };
            if (std.mem.startsWith(u8, v, "Superseded by ") or std.mem.eql(u8, v, "Proposed|Accepted|Deprecated|Superseded by NNNN")) status_ok = true;
        }
        if (std.mem.startsWith(u8, l, "Date: ")) date_ok = true;
    }
    if (!status_ok) return .{ .rule = "adr", .message = try std.fmt.allocPrint(arena, "{s}: needs 'Status: Proposed|Accepted|Deprecated|Superseded by NNNN'", .{name}) };
    if (!date_ok) return .{ .rule = "adr", .message = try std.fmt.allocPrint(arena, "{s}: needs a 'Date: YYYY-MM-DD' line", .{name}) };
    return null;
}

test "prlint: valid branch" {
    try std.testing.expect(checkBranch("feat/e00.f05.s01.t01-framers") == null);
    try std.testing.expect(checkBranch("fix/e05-crash-on-open") == null);
    try std.testing.expect(checkBranch("claude/project-thread-b6p0zn") == null);
}

test "prlint: rejects uppercase branch" {
    try std.testing.expect(checkBranch("feat/E00.F05-framers") != null);
    try std.testing.expect(checkBranch("feat/e00-Framers") != null);
    try std.testing.expect(checkBranch("wip/e00-x") != null);
    try std.testing.expect(checkBranch("feat/e00") != null);
}

test "prlint: valid title with spec id" {
    try std.testing.expect(checkTitle("feat(net): add SSE parser [E00.F06.S02.T01]") == null);
    try std.testing.expect(checkTitle("docs: add ADRs [E00]") == null);
}

test "prlint: rejects title without spec" {
    try std.testing.expect(checkTitle("feat(net): add SSE parser") != null);
    try std.testing.expect(checkTitle("feat(net): add SSE parser [E00.F6]") != null);
    try std.testing.expect(checkTitle("Add SSE parser [E00]") != null);
}

test "prlint: breaking change ! accepted" {
    try std.testing.expect(checkTitle("refactor(core)!: rename Runtime.post [E00.F04.S02.T01]") == null);
}

test "prlint: commit footer required" {
    try std.testing.expect(checkCommit("feat(core): x\n\nbody\n\nSpec: E00.F04.S01.T01\n") == null);
    try std.testing.expect(checkCommit("feat(core): x\n\nbody\n") != null);
    try std.testing.expect(checkCommit("feat(core): x\n\nSpec: nope\n") != null);
}

test "prlint: unknown scope rejected" {
    try std.testing.expect(checkTitle("feat(nope): x [E00]") != null);
    try std.testing.expect(checkTitle("feat(core): x [E00]") == null);
}

test "prlint: adr validation" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const good = "# 0001. X\n\nStatus: Accepted\nDate: 2026-10-21\n\n## Context\n## Decision\n## Consequences\n## References\n";
    try std.testing.expect(try checkAdr(arena.allocator(), "0001.md", good) == null);
    try std.testing.expect(try checkAdr(arena.allocator(), "0002.md", "# 0002. Y\nStatus: Maybe\nDate: x\n## Context\n## Decision\n## Consequences\n## References\n") != null);
}

test "prlint: interfaces subsections" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var out: std.ArrayList(Finding) = .empty;
    try checkInterfaces(arena.allocator(), "pre\n## A\n### Defined in\n", &out);
    try std.testing.expectEqual(@as(usize, 6), out.items.len);
}

test "fuzz: prlint title" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const t = buf[0..s.slice(&buf)];
            _ = checkTitle(t);
            _ = checkBranch(t);
            _ = checkCommit(t);
        }
    }.one, .{ .corpus = &.{ "feat(core): x [E00]", "fix!: [", "feat(): [E00.F01.S01.T01]" } });
}
