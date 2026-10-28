//! Workspace file-operation hooks (E07.F04.S02.T03) around the user's
//! own file operations (the Explorer's create, rename and delete):
//! `will*` asks every server whose registered `FileOperationFilter`s
//! match (scheme, glob, file or folder, ignoring case when asked) and
//! applies the edits they return (import updates on a rename) through the
//! workspace edit engine before the operation; `did*` tells them after.
//! A server that does not answer within the deadline (1 s) is skipped.
//!
//! Operations that are part of a workspace edit send nothing (the spec:
//! the server made them).

const FileOpHooks = @This();
const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const oneshot = @import("oneshot.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");
const SaveActions = @import("save_actions.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Feature = zg_lsp.client.caps.Feature;
const Glob = zg_lsp.glob.Glob;
const fileUri = zg_editor.model.api.registry.fileUri;
const log = std.log.scoped(.file_ops);

/// A file or folder taking part (absolute path).
pub const Entry = struct { path: []const u8, folder: bool = false };
pub const Pair = struct { old: []const u8, new: []const u8, folder: bool = false };

const CreateReq = oneshot.Oneshot(.@"workspace/willCreateFiles", u64);
const RenameReq = oneshot.Oneshot(.@"workspace/willRenameFiles", u64);
const DeleteReq = oneshot.Oneshot(.@"workspace/willDeleteFiles", u64);

gpa: Allocator,
mgr: *Manager,
engine: *Engine,
create_req: CreateReq,
rename_req: RenameReq,
delete_req: DeleteReq,
budget_ms: u64 = 1000,
serial: u64 = 0,
/// Edits applied from `will*` answers (tests).
applied: u32 = 0,

pub fn init(mgr: *Manager, engine: *Engine) FileOpHooks {
    const io = mgr.rt.io;
    return .{
        .gpa = mgr.gpa,
        .mgr = mgr,
        .engine = engine,
        .create_req = .init(mgr.gpa, io, .noop),
        .rename_req = .init(mgr.gpa, io, .noop),
        .delete_req = .init(mgr.gpa, io, .noop),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(h: *FileOpHooks) void {
    h.create_req.deinit();
    h.rename_req.deinit();
    h.delete_req.deinit();
}

/// Whether `filters` take `path` (a file, or a folder when `folder`).
pub fn matches(gpa: Allocator, filters: []const protocol.FileOperationFilter, path: []const u8, folder: bool) bool {
    for (filters) |f| {
        if (f.scheme) |sc| if (!std.mem.eql(u8, sc, "file")) continue;
        if (f.pattern.matches) |k| if ((k == .folder) != folder) continue;
        const ci = if (f.pattern.options) |o| o.ignoreCase orelse false else false;
        var g = Glob.compile(gpa, f.pattern.glob, .{ .case_insensitive = ci }) catch continue;
        defer g.deinit(gpa);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len > buf.len) continue;
        // Globs use forward slashes.
        const p = buf[0..path.len];
        @memcpy(p, path);
        std.mem.replaceScalar(u8, p, '\\', '/');
        if (g.match(p)) return true;
    }
    return false;
}

/// The filters server `s` registered for `f` (static or dynamic), in
/// `a`.
fn filtersOf(a: Allocator, s: *const Manager.Server, comptime f: Feature) []const protocol.FileOperationFilter {
    if (s.status != .running) return &.{};
    const cl = s.client orelse return &.{};
    const caps = cl.caps() orelse return &.{};
    if (caps.options(f)) |o| return o.filters;
    const v = caps.registrationOptions(f, null) orelse return &.{};
    const o = std.json.parseFromValueLeaky(protocol.FileOperationRegistrationOptions, a, v, .{ .ignore_unknown_fields = true }) catch return &.{};
    return o.filters;
}

fn wanted(a: Allocator, s: *const Manager.Server, comptime f: Feature, path: []const u8, folder: bool) bool {
    return matches(a, filtersOf(a, s, f), path, folder);
}

pub fn willCreate(h: *FileOpHooks, entries: []const Entry, clk: SaveActions.Clock) void {
    h.will(.will_create_files, &h.create_req, entries, clk);
}

pub fn willDelete(h: *FileOpHooks, entries: []const Entry, clk: SaveActions.Clock) void {
    h.will(.will_delete_files, &h.delete_req, entries, clk);
}

pub fn willRename(h: *FileOpHooks, pairs: []const Pair, clk: SaveActions.Clock) void {
    h.will(.will_rename_files, &h.rename_req, pairs, clk);
}

pub fn didCreate(h: *FileOpHooks, entries: []const Entry) void {
    h.did(.did_create_files, entries);
}

pub fn didDelete(h: *FileOpHooks, entries: []const Entry) void {
    h.did(.did_delete_files, entries);
}

pub fn didRename(h: *FileOpHooks, pairs: []const Pair) void {
    h.did(.did_rename_files, pairs);
}

fn pathOf(x: anytype) []const u8 {
    return if (@TypeOf(x) == Pair) x.old else x.path;
}

/// The params of `f` for the `items` server `s` wants, null for none.
fn params(a: Allocator, s: *const Manager.Server, comptime f: Feature, items: anytype) !?ParamsOf(f) {
    const T = @typeInfo(@FieldType(ParamsOf(f), "files")).pointer.child;
    var files: std.ArrayList(T) = .empty;
    for (items) |it| {
        if (!wanted(a, s, f, pathOf(it), it.folder)) {
            // A rename matches by either name.
            if (@TypeOf(it) != Pair or !wanted(a, s, f, it.new, it.folder)) continue;
        }
        try files.append(a, if (@TypeOf(it) == Pair)
            .{ .oldUri = try fileUri(a, it.old), .newUri = try fileUri(a, it.new) }
        else
            .{ .uri = try fileUri(a, it.path) });
    }
    if (files.items.len == 0) return null;
    return .{ .files = files.items };
}

fn ParamsOf(comptime f: Feature) type {
    return switch (f) {
        .will_create_files, .did_create_files => protocol.CreateFilesParams,
        .will_rename_files, .did_rename_files => protocol.RenameFilesParams,
        .will_delete_files, .did_delete_files => protocol.DeleteFilesParams,
        else => unreachable,
    };
}

fn will(h: *FileOpHooks, comptime f: Feature, req: anytype, items: anytype, clk: SaveActions.Clock) void {
    var arena: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const deadline = clk.now_ms(clk.ctx) + h.budget_ms;
    for (h.mgr.serverList()) |s| {
        const p = (params(a, s, f, items) catch continue) orelse continue;
        h.mgr.flush();
        h.serial += 1;
        req.send(s.client.?, p, .{}, h.serial) catch continue;
        const ans = wait: while (true) {
            h.mgr.tick();
            for (req.take()) |x| if (x.tag == h.serial) break :wait x;
            if (clk.now_ms(clk.ctx) >= deadline) {
                log.info("{s} did not answer {t} in time", .{ s.def.id, f });
                return;
            }
            h.mgr.rt.io.sleep(.fromMilliseconds(1), .awake) catch {};
        };
        const edit = switch (ans.result) {
            .ok => |o| o.value orelse continue,
            else => continue,
        };
        var why: plan_mod.Failure = .{ .index = 0, .err = error.Unknown };
        var pl = h.engine.plan(&edit, Engine.sourceOf(s), "Update references", &why) catch {
            log.info("{t} edit from {s}: {s}", .{ f, s.def.id, plan_mod.reason(why.err) });
            continue;
        };
        defer pl.deinit();
        const out = h.engine.apply(&pl, .user, .auto) catch continue;
        if (out == .applied) h.applied += 1;
    }
}

fn did(h: *FileOpHooks, comptime f: Feature, items: anytype) void {
    var arena: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const N: protocol.NotificationMethod = switch (f) {
        .did_create_files => .@"workspace/didCreateFiles",
        .did_rename_files => .@"workspace/didRenameFiles",
        .did_delete_files => .@"workspace/didDeleteFiles",
        else => unreachable,
    };
    for (h.mgr.serverList()) |s| {
        const p = (params(a, s, f, items) catch continue) orelse continue;
        s.client.?.notify(N, p) catch |e| log.info("{t} to {s}: {t}", .{ f, s.def.id, e });
    }
}
