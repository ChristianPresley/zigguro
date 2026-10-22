//! `zg scm ai` (E09.F06): the AI workflows from the command line.
//!
//! - `zg scm ai describe [REV]` (E09.F06.S01.T01) drafts a description
//!   for one change from its diff, the repo's conventions and the agent
//!   sessions behind it, and prints it; `--apply` rewrites the change.
//! - `zg scm ai resolve [REV]` (E09.F06.S02.T01) proposes a resolution
//!   for every conflicted region of one change and prints them; `--apply`
//!   rewrites the change when every region was resolved.
//!
//! REV is a revset naming one commit (default `@`). The model comes from
//! `--model`, `ZG_MODEL` or "sonnet", with keys from the environment (see
//! `scm_model.zig`). The commit index is kept in `.zg/repo/index`.
//! Exit codes: 0 done, 1 the model failed or (with `--apply`) a region
//! needs a human, 2 a usage error or no repository.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_scm = @import("zg_scm");
const cmd_scm = @import("cmd_scm.zig");
const scm_model = @import("scm_model.zig");

const ports = zg_scm.ai.ports;
const describe = zg_scm.ai.describe;
const resolve = zg_scm.ai.resolve;
const ObjectId = zg_scm.ObjectId;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const usage =
    \\Usage: zg scm ai describe [REV] [--conventional] [--apply] [options]
    \\       zg scm ai resolve [REV] [--apply] [options]
    \\
    \\`describe` drafts a description for the change REV (default @) and
    \\prints it; --apply rewrites the change with it. --conventional asks
    \\for a `type(scope): subject` line.
    \\
    \\`resolve` proposes a resolution for each conflicted region of REV
    \\and prints them; --apply rewrites the change when every region was
    \\resolved, and leaves it alone otherwise.
    \\
    \\--repo DIR     a workspace (or its .zg/repo); default: the nearest one
    \\--model NAME   the model (default: ZG_MODEL, else sonnet)
    \\--json         one JSON object instead of text
    \\
;

pub const Cmd = enum { describe, resolve };

pub const Args = struct {
    cmd: Cmd,
    rev: []const u8 = "@",
    repo: ?[]const u8 = null,
    model: ?[]const u8 = null,
    json: bool = false,
    apply: bool = false,
    conventional: bool = false,
};

/// Who the operations are recorded as.
pub const Who = struct { user: []const u8 = "", host: []const u8 = "" };

pub fn parse(argv: []const []const u8) ?Args {
    if (argv.len == 0) return null;
    var a: Args = .{ .cmd = std.meta.stringToEnum(Cmd, argv[0]) orelse return null };
    var rev_set = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (std.mem.eql(u8, s, "--json")) {
            a.json = true;
        } else if (std.mem.eql(u8, s, "--apply")) {
            a.apply = true;
        } else if (std.mem.eql(u8, s, "--conventional") and a.cmd == .describe) {
            a.conventional = true;
        } else if ((std.mem.eql(u8, s, "--repo") or std.mem.eql(u8, s, "--model")) and i + 1 < argv.len) {
            i += 1;
            if (s[2] == 'r') a.repo = argv[i] else a.model = argv[i];
        } else if (!rev_set and !std.mem.startsWith(u8, s, "--")) {
            a.rev = s;
            rev_set = true;
        } else return null;
    }
    return a;
}

/// Runs `zg scm ai <argv>`; returns the process exit code.
pub fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const []const u8) !u8 {
    var obuf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), rt.io, &obuf);
    defer out_w.interface.flush() catch {};
    var ebuf: [1024]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), rt.io, &ebuf);
    defer err_w.interface.flush() catch {};
    const out = &out_w.interface;
    const err = &err_w.interface;

    if (argv.len >= 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h"))) {
        try out.writeAll(usage);
        return 0;
    }
    const args = parse(argv) orelse {
        try err.writeAll(usage);
        return 2;
    };
    var backend: scm_model.Backend = undefined;
    backend.init(rt, min, err) catch |e| switch (e) {
        error.BadCassetteMode => {
            try err.writeAll("zg scm ai: ZG_CASSETTE_MODE must be replay, record or record_missing\n");
            return 2;
        },
        else => return e,
    };
    defer backend.deinit();
    var pm = (try backend.model(rt.io, args.model, err)) orelse return 2;
    const who: Who = .{
        .user = backend.env.get("USER") orelse backend.env.get("USERNAME") orelse "",
        .host = backend.env.get("HOSTNAME") orelse backend.env.get("COMPUTERNAME") orelse "",
    };
    return runWith(rt.gpa, rt.io, Io.Dir.cwd(), args, pm.port(), pm.model.id, who, out, err);
}

/// `run` with the model, working directory and output streams given.
pub fn runWith(gpa: Allocator, io: Io, cwd: Io.Dir, args: Args, model: ports.ModelPort, model_name: []const u8, who: Who, out: *Io.Writer, err: *Io.Writer) !u8 {
    var repo_dir = cmd_scm.locate(io, cwd, args.repo) catch |e| switch (e) {
        error.NoRepository => {
            try err.writeAll("zg scm ai: no zg repository here (looked for .zg/repo/store)\n");
            return 2;
        },
        else => return e,
    };
    defer repo_dir.close(io);
    var store_dir = (try cmd_scm.storeIn(io, repo_dir)).?;
    defer store_dir.close(io);
    const s = try zg_scm.Store.open(gpa, io, store_dir, .{});
    defer s.close();
    const repo = zg_scm.Repo.load(gpa, io, repo_dir, s, .{}, .head) catch |e| switch (e) {
        error.NotInitialized, error.NoOpHeads => {
            try err.writeAll("zg scm ai: the repository has no operation log yet\n");
            return 2;
        },
        else => return e,
    };
    defer repo.close();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const target = (try resolveRev(gpa, io, repo_dir, s, repo, args.rev, err)) orelse return 2;
    const now: i64 = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const meta: zg_scm.OpMeta = .{
        .start_ms = now,
        .end_ms = now,
        .description = if (args.cmd == .describe) "describe with AI" else "resolve conflicts with AI",
        .user = who.user,
        .host = who.host,
        .workspace = "default",
        .actor = .human,
        .tags = &.{},
    };
    return switch (args.cmd) {
        .describe => describeCmd(a, repo, target, args, model, model_name, meta, out, err),
        .resolve => resolveCmd(gpa, io, a, repo, s, target, args, model, meta, out, err),
    };
}

/// The one commit `rev` names in the latest view, or null after saying
/// why not.
fn resolveRev(gpa: Allocator, io: Io, repo_dir: Io.Dir, s: *zg_scm.Store, repo: *zg_scm.Repo, rev: []const u8, err: *Io.Writer) !?ObjectId {
    var ix_dir = try repo_dir.createDirPathOpen(io, "index", .{ .open_options = .{ .iterate = true } });
    defer ix_dir.close(io);
    const ix = try zg_scm.CommitIndex.open(gpa, io, ix_dir, s, .{});
    defer ix.close();
    try ix.ensureIndexed(repo.view().heads);
    for (repo.view().wc_commits) |wc| try ix.ensureIndexed(&.{wc.commit});

    const view = ix.acquire();
    defer view.release();
    const ctx: zg_scm.revset.EvalContext = .{ .graph = view, .view = repo.view(), .store = s, .io = io };
    var diag: zg_scm.revset.ParseError = .{};
    var it = zg_scm.revset.evaluate(gpa, &ctx, rev, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            try err.print("zg scm ai: revset `{s}`: {t}", .{ rev, e });
            if (diag.message.len > 0) try err.print(": {s}", .{diag.message});
            try err.writeByte('\n');
            return null;
        },
    };
    defer it.deinit();
    const got = try it.collect(gpa, 2);
    defer gpa.free(got);
    if (got.len != 1) {
        try err.print("zg scm ai: `{s}` names {s} commits; give one\n", .{ rev, if (got.len == 0) "no" else "several" });
        return null;
    }
    return view.entry(got[0]).id;
}

fn describeCmd(a: Allocator, repo: *zg_scm.Repo, target: ObjectId, args: Args, model: ports.ModelPort, model_name: []const u8, meta: zg_scm.OpMeta, out: *Io.Writer, err: *Io.Writer) !u8 {
    var d: describe.Describer = .{ .repo = repo, .model = model };
    const o: describe.DescribeOptions = .{
        .style = if (args.conventional) .conventional else .plain,
        .auto_apply = args.apply,
        .model = model_name,
    };
    var applied: ?ObjectId = null;
    var commit = target;
    const v = blk: {
        if (args.apply) {
            const p = d.propose(a, target, o, meta, null) catch |e| return describeError(e, &d, err);
            applied = p.outcome.applied;
            commit = p.commit;
            break :blk p.validated;
        }
        const ctx = try d.buildContext(a, target, o);
        break :blk d.generate(a, &ctx, o, null) catch |e| return describeError(e, &d, err);
    };
    if (v.issues.empty_subject) {
        try err.writeAll("zg scm ai: the model returned no subject\n");
        return 1;
    }
    if (args.json) {
        var js: std.json.Stringify = .{ .writer = out };
        try js.beginObject();
        try js.objectField("commit");
        try js.print("\"{f}\"", .{commit});
        inline for (.{ "subject", "body", "trailers", "confidence" }) |f| {
            try js.objectField(f);
            try js.write(@field(v.output, f));
        }
        try js.objectField("issues");
        try js.beginArray();
        inline for (@typeInfo(describe.Issues).@"struct".fields) |f| {
            if (@field(v.issues, f.name)) try js.write(f.name);
        }
        try js.endArray();
        try js.objectField("applied");
        if (applied) |h| try js.print("\"{f}\"", .{h}) else try js.write(null);
        try js.endObject();
        try out.writeByte('\n');
        return 0;
    }
    if (v.issues.subject_truncated) try err.writeAll("zg scm ai: note: the subject was shortened\n");
    if (v.issues.bad_type) try err.writeAll("zg scm ai: note: the subject has no known conventional type\n");
    if (v.issues.secret) try err.writeAll("zg scm ai: note: secrets in the reply were masked\n");
    const text = try v.output.text(a);
    try out.writeAll(text);
    if (!std.mem.endsWith(u8, text, "\n")) try out.writeByte('\n');
    if (applied != null) {
        var buf: [64]u8 = undefined;
        try err.print("zg scm ai: described {s}\n", .{commit.short(&buf, 12)});
    }
    return 0;
}

fn describeError(e: anyerror, d: *const describe.Describer, err: *Io.Writer) !u8 {
    switch (e) {
        error.ModelError => try err.print("zg scm ai: the model failed: {s}\n", .{d.last_error}),
        error.Cancelled => try err.writeAll("zg scm ai: cancelled\n"),
        error.CutOff => try err.writeAll("zg scm ai: the reply hit the output limit\n"),
        error.EmptyDescription => try err.writeAll("zg scm ai: the model returned no subject\n"),
        error.Conflicted => try err.writeAll("zg scm ai: the repository changed meanwhile; nothing applied\n"),
        else => return e,
    }
    return 1;
}

fn resolveCmd(gpa: Allocator, io: Io, a: Allocator, repo: *zg_scm.Repo, s: *zg_scm.Store, target: ObjectId, args: Args, model: ports.ModelPort, meta: zg_scm.OpMeta, out: *Io.Writer, err: *Io.Writer) !u8 {
    var res: resolve.Resolver = .{ .gpa = gpa, .io = io, .store = s, .model = model };
    const run_ = res.proposeForChange(target) catch |e| switch (e) {
        error.NotConflicted => {
            if (args.json) try out.print("{{\"change\":\"{f}\",\"regions\":[],\"applied\":null}}\n", .{target}) else try out.writeAll("no conflicts\n");
            return 0;
        },
        else => return e,
    };
    defer run_.deinit();
    const n = run_.jobs.len;
    var open: usize = 0;
    for (0..n) |i| open += @intFromBool(run_.proposal(i).status != .ok);

    var applied: ?ObjectId = null;
    var commit = target;
    if (args.apply and n > 0 and open == 0) {
        const decisions = try a.alloc(resolve.RegionDecision, n);
        for (decisions, 0..) |*dec, i| {
            const p = run_.proposal(i);
            dec.* = .{ .path = p.path, .region_idx = p.region_idx, .choice = .{ .accept = p.text } };
        }
        const ap = try resolve.applyResolutions(repo, &run_.set, decisions, meta);
        var r = zg_scm.adopt.adopt(repo, ap.preview, meta) catch |e| {
            zg_scm.preview.discard(repo, ap.preview.op);
            return e;
        };
        defer r.deinit();
        switch (r) {
            .adopted => |h| {
                applied = h;
                commit = ap.commit;
            },
            .conflicted => {
                zg_scm.preview.discard(repo, ap.preview.op);
                try err.writeAll("zg scm ai: the repository changed meanwhile; nothing applied\n");
                return 1;
            },
        }
    }

    if (args.json) {
        var js: std.json.Stringify = .{ .writer = out };
        try js.beginObject();
        try js.objectField("change");
        try js.print("\"{f}\"", .{target});
        try js.objectField("regions");
        try js.beginArray();
        for (0..n) |i| {
            const p = run_.proposal(i);
            try js.beginObject();
            try js.objectField("path");
            try js.write(p.path);
            try js.objectField("region");
            try js.write(p.region_idx);
            try js.objectField("kind");
            try js.write(@tagName(run_.set.regions[i].kind));
            try js.objectField("status");
            try js.write(@tagName(p.status));
            try js.objectField("reason");
            try js.write(p.reason);
            try js.objectField("rationale");
            try js.write(p.rationale);
            try js.objectField("text");
            try js.write(p.text);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("applied");
        if (applied) |h| try js.print("\"{f}\"", .{h}) else try js.write(null);
        try js.endObject();
        try out.writeByte('\n');
    } else {
        for (0..n) |i| {
            const p = run_.proposal(i);
            try out.print("{s} region {d}: ", .{ p.path, p.region_idx });
            if (p.status == .ok) try out.writeAll("resolved") else try out.print("needs a human ({s})", .{p.reason orelse "no answer"});
            if (p.rationale.len > 0) try out.print(": {s}", .{p.rationale});
            try out.writeByte('\n');
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, p.text, "\n"), '\n');
            if (p.text.len > 0) while (lines.next()) |l| try out.print("  | {s}\n", .{l});
        }
        if (applied != null) {
            var buf: [64]u8 = undefined;
            try err.print("zg scm ai: resolved {s}\n", .{commit.short(&buf, 12)});
        }
    }
    if (args.apply and open > 0) {
        try err.print("zg scm ai: {d} region{s} need{s} a human; nothing applied\n", .{ open, if (open == 1) "" else "s", if (open == 1) "s" else "" });
        return 1;
    }
    return 0;
}

const testing = std.testing;
const FakeModel = zg_scm.ai.testing.fake_model.FakeModel;

fn testMeta(description: []const u8) zg_scm.OpMeta {
    return .{ .start_ms = 1, .end_ms = 1, .description = description, .user = "t", .host = "h", .workspace = "default", .actor = .human, .tags = &.{} };
}

fn testCommit(m: *zg_scm.mutable_repo.MutableRepo, gpa: Allocator, parents: []const ObjectId, terms: []const []const [2][]const u8, description: []const u8) !ObjectId {
    var tm = zg_scm.tree_merge.TreeMerger.init(gpa, m.batch.store, m.batch);
    defer tm.deinit();
    const trees = try m.arena.alloc(ObjectId, terms.len);
    for (trees, terms) |*tr, files| tr.* = try zg_scm.tree_merge.testTree(&tm, files);
    const sig: zg_scm.Signature = .{ .name = "t", .email = "t@example.com", .time_ms = 0, .tz_offset_min = 0 };
    var cid: zg_scm.ChangeId = undefined;
    std.mem.writeInt(u128, &cid.bytes, std.hash.Wyhash.hash(7, description), .little);
    return m.writeChange(.{
        .parents = try m.arena.dupe(ObjectId, parents),
        .tree_terms = trees,
        .change_id = cid,
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = try m.arena.dupe(u8, description),
        .provenance = null,
        .extra = &.{},
        .sig = null,
    });
}

/// A workspace `ws` whose working copy is a change on top of `main`; with
/// `conflicted`, the change holds a three-term conflict in src/a.txt.
fn setupRepo(gpa: Allocator, io: Io, tmp: Io.Dir, conflicted: bool) !void {
    var repo_dir = try tmp.createDirPathOpen(io, "ws/.zg/repo", .{});
    defer repo_dir.close(io);
    var seg = try repo_dir.createDirPathOpen(io, "store/seg", .{});
    seg.close(io);
    var store_dir = try repo_dir.openDir(io, "store", .{});
    defer store_dir.close(io);
    const s = try zg_scm.Store.open(gpa, io, store_dir, .{ .fsync = false });
    defer s.close();
    const r0 = try zg_scm.Repo.init(gpa, io, repo_dir, s, .{}, testMeta("init"));
    defer r0.close();
    const tx = try r0.startTransaction(testMeta("setup"));
    const m = tx.mutRepo();
    const base = [_][2][]const u8{.{ "src/a.txt", "one\ntwo\nthree\n" }};
    const root = try testCommit(m, gpa, &.{}, &.{&base}, "Add a");
    var main: ?ObjectId = root;
    try m.setBookmark("main", .normal(&main));
    const change = if (conflicted)
        try testCommit(m, gpa, &.{root}, &.{ &.{.{ "src/a.txt", "one\nTWO\nthree\n" }}, &base, &.{.{ "src/a.txt", "one\nzwei\nthree\n" }} }, "merge")
    else
        try testCommit(m, gpa, &.{root}, &.{&.{.{ "src/a.txt", "one\ntwo\nthree\nfour\n" }}}, "");
    try m.setWcCommit("default", change);
    const r1 = try tx.commit();
    r1.close();
}

test "zg scm ai describe: prints, then applies with --apply" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRepo(gpa, io, tmp.dir, false);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    var fm = FakeModel.init(gpa, &.{.{ .json = "{\"subject\":\"Add a fourth line\",\"body\":\"The parser needs it.\",\"trailers\":[],\"confidence\":0.8}" }});
    defer fm.deinit();
    const dry = parse(&.{ "describe", "--repo", "ws" }).?;
    try testing.expectEqual(@as(u8, 0), try runWith(gpa, io, tmp.dir, dry, fm.port(), "m-1", .{}, &out.writer, &err.writer));
    try testing.expectEqualStrings("Add a fourth line\n\nThe parser needs it.\n", out.written());
    try testing.expect(std.mem.indexOf(u8, fm.prompts.items[0], "+four") != null);

    out.clearRetainingCapacity();
    const apply = parse(&.{ "describe", "@", "--repo", "ws", "--apply", "--json" }).?;
    try testing.expectEqual(@as(u8, 0), try runWith(gpa, io, tmp.dir, apply, fm.port(), "m-1", .{}, &out.writer, &err.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Add a fourth line", parsed.value.object.get("subject").?.string);
    try testing.expect(parsed.value.object.get("applied").? == .string);

    // The working copy now carries the description.
    out.clearRetainingCapacity();
    var fm2 = FakeModel.init(gpa, &.{.{ .json = "{\"subject\":\"x\",\"body\":\"\",\"trailers\":[],\"confidence\":1}" }});
    defer fm2.deinit();
    _ = try runWith(gpa, io, tmp.dir, dry, fm2.port(), "m-1", .{}, &out.writer, &err.writer);
    try testing.expect(std.mem.indexOf(u8, fm2.prompts.items[0], "Add a fourth line") != null);
}

test "zg scm ai describe: usage and model errors" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    try testing.expect(parse(&.{"split"}) == null);
    try testing.expect(parse(&.{ "resolve", "--conventional" }) == null);
    try testing.expect(parse(&.{ "describe", "a", "b" }) == null);

    var fm = FakeModel.init(gpa, &.{.{ .fail = "overloaded" }});
    defer fm.deinit();
    const args = parse(&.{"describe"}).?;
    try testing.expectEqual(@as(u8, 2), try runWith(gpa, io, tmp.dir, args, fm.port(), "m", .{}, &out.writer, &err.writer));
    try setupRepo(gpa, io, tmp.dir, false);
    var ws = try tmp.dir.openDir(io, "ws", .{});
    defer ws.close(io);
    try testing.expectEqual(@as(u8, 1), try runWith(gpa, io, ws, args, fm.port(), "m", .{}, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, err.written(), "the model failed: overloaded") != null);
    err.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 2), try runWith(gpa, io, ws, parse(&.{ "describe", "nosuch" }).?, fm.port(), "m", .{}, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, err.written(), "revset `nosuch`") != null);
}

test "zg scm ai resolve: proposes, then applies with --apply" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRepo(gpa, io, tmp.dir, true);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    var fm = FakeModel.init(gpa, &.{.{ .json = "{\"resolution\":\"TWO zwei\\n\",\"rationale\":\"Keep both spellings.\",\"addresses_sides\":[true,true],\"confidence\":0.9}" }});
    defer fm.deinit();
    try testing.expectEqual(@as(u8, 0), try runWith(gpa, io, tmp.dir, parse(&.{ "resolve", "--repo", "ws" }).?, fm.port(), "m", .{}, &out.writer, &err.writer));
    try testing.expectEqualStrings("src/a.txt region 0: resolved: Keep both spellings.\n  | TWO zwei\n", out.written());

    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runWith(gpa, io, tmp.dir, parse(&.{ "resolve", "--repo", "ws", "--apply", "--json" }).?, fm.port(), "m", .{}, &out.writer, &err.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ok", parsed.value.object.get("regions").?.array.items[0].object.get("status").?.string);
    try testing.expect(parsed.value.object.get("applied").? == .string);

    // Resolved: nothing left to propose.
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runWith(gpa, io, tmp.dir, parse(&.{ "resolve", "--repo", "ws" }).?, fm.port(), "m", .{}, &out.writer, &err.writer));
    try testing.expectEqualStrings("no conflicts\n", out.written());
}

test "zg scm ai resolve: --apply refuses when a region needs a human" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRepo(gpa, io, tmp.dir, true);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var fm = FakeModel.init(gpa, &.{.{ .text = "not json" }});
    defer fm.deinit();
    try testing.expectEqual(@as(u8, 1), try runWith(gpa, io, tmp.dir, parse(&.{ "resolve", "--repo", "ws", "--apply" }).?, fm.port(), "m", .{}, &out.writer, &err.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "needs a human") != null);
    try testing.expect(std.mem.indexOf(u8, err.written(), "1 region needs a human; nothing applied") != null);
}
