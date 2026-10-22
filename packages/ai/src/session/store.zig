//! `SessionStore`: the session files of one workspace (E10.F08.S01.T01),
//! `<data_dir>/sessions/<workspace_key>/<session_id>.jsonl`. `data_dir`
//! comes from E15 paths (XDG data home on Linux, `%LOCALAPPDATA%` on
//! Windows); the workspace key is shared with auto memory (`key.zig`).

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const writer = @import("writer.zig");
const loader = @import("loader.zig");
const key = @import("key.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const SessionWriter = writer.SessionWriter;
pub const LoadedSession = loader.LoadedSession;
pub const LoadMode = loader.LoadMode;

/// What `create` needs to know about a new session.
pub const NewSession = struct {
    /// Generated when null.
    id: ?proto.SessionId = null,
    parent: ?records.Parent = null,
    cwd: []const u8,
    prompt_version: []const u8 = "",
    app_version: []const u8 = "",
    origin: records.Origin = .gui,
    model: []const u8 = "",
};

pub const SessionStore = struct {
    gpa: Allocator,
    /// `<data_dir>/sessions/<workspace_key>` (owned).
    dir: []const u8,
    /// Owned.
    workspace_key: []const u8,
    ulids: proto.agent_ref.UlidGen = .{},
    /// `ai.sessions.redactSecrets` (default on) uses this redactor.
    redactor: writer.Redactor = .{},
    redact_secrets: bool = true,

    pub fn init(gpa: Allocator, data_dir: []const u8, workspace_root: []const u8) Allocator.Error!SessionStore {
        var buf: [key.max_len]u8 = undefined;
        const k = try gpa.dupe(u8, key.workspaceKey(&buf, workspace_root));
        errdefer gpa.free(k);
        return .{ .gpa = gpa, .dir = try std.fs.path.join(gpa, &.{ data_dir, "sessions", k }), .workspace_key = k };
    }

    pub fn deinit(s: *SessionStore) void {
        s.gpa.free(s.dir);
        s.gpa.free(s.workspace_key);
    }

    /// The file of session `id`; caller frees.
    pub fn pathFor(s: *const SessionStore, gpa: Allocator, id: proto.SessionId) Allocator.Error![]u8 {
        const name = proto.agent_ref.format(id);
        return std.fmt.allocPrint(gpa, "{s}{c}{s}.jsonl", .{ s.dir, std.fs.path.sep, &name });
    }

    /// Creates the file, writes the header and returns its locked writer.
    pub fn create(s: *SessionStore, io: Io, meta: NewSession) !*SessionWriter {
        try Io.Dir.cwd().createDirPath(io, s.dir);
        const id = meta.id orelse s.ulids.next(io);
        const path = try s.pathFor(s.gpa, id);
        defer s.gpa.free(path);
        const w = try SessionWriter.open(s.gpa, io, path, id, true);
        errdefer w.close();
        if (s.redact_secrets) w.redactor = s.redactor;
        try w.append(0, .{ .header = .{
            .session = id,
            .parent = meta.parent,
            .created_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
            .cwd = meta.cwd,
            .workspace_key = s.workspace_key,
            .prompt_version = meta.prompt_version,
            .app_version = meta.app_version,
            .origin = meta.origin,
            .model = meta.model,
        } });
        return w;
    }

    /// Opens an existing session for appending (after a resume). Fails
    /// with `error.SessionLocked` while another writer holds it.
    pub fn reopen(s: *SessionStore, io: Io, id: proto.SessionId, last_seq: u64) !*SessionWriter {
        const path = try s.pathFor(s.gpa, id);
        defer s.gpa.free(path);
        const w = try SessionWriter.open(s.gpa, io, path, id, false);
        if (s.redact_secrets) w.redactor = s.redactor;
        w.last_seq = last_seq;
        return w;
    }

    /// Loads session `id` (repairing a torn tail first).
    pub fn open(s: *SessionStore, io: Io, id: proto.SessionId, opts: loader.Options) !*LoadedSession {
        const path = try s.pathFor(s.gpa, id);
        defer s.gpa.free(path);
        return loader.open(s.gpa, io, path, opts);
    }
};
