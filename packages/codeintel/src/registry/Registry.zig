//! The language server registry (E07.F01.S03.T01): which servers handle a
//! document, where their executables are, and which folder is their root.
//!
//! Definitions start from `builtin_servers.zon` and are overridden per id
//! by settings (`lsp.servers.<id>`, merged user < workspace < folder by
//! the caller into `Override`s). A workspace override of `command` is
//! honoured only in a trusted workspace (E16); otherwise the user or
//! built-in command stays and `ignored_commands` names the server so the
//! UI can say why.
//!
//! Executables are found on PATH (with PATHEXT on Windows) and cached by
//! name until `rescan`; nothing is executed during discovery. Roots are
//! the nearest ancestor holding a root marker, inside the workspace
//! folder, or the folder itself.

const Registry = @This();
const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const Feature = zg_lsp.client.caps.Feature;

/// How the server is reached.
pub const TransportKind = enum { stdio, tcp };

/// One language server.
pub const ServerDef = struct {
    id: []const u8,
    /// argv; argv[0] is looked up on PATH unless it is a path.
    command: []const []const u8,
    /// LSP languageIds it handles.
    languages: []const []const u8,
    /// Globs for files the editor cannot give a language id.
    file_patterns: []const []const u8 = &.{},
    root_markers: []const []const u8 = &.{},
    /// `initializationOptions` as JSON text.
    initialization_options: ?[]const u8 = null,
    /// The `workspace/configuration` section.
    settings_section: ?[]const u8 = null,
    /// When set, only these features are routed to the server.
    features_only: ?[]const Feature = null,
    features_except: []const Feature = &.{},
    version_args: []const []const u8 = &.{"--version"},
    install_hint: []const u8 = "",
    transport: TransportKind = .stdio,
    single_instance: enum { per_root, per_workspace, global } = .per_root,
    enabled: bool = true,

    /// Whether requests for `f` may go to this server (its capabilities
    /// decide the rest).
    pub fn allows(d: *const ServerDef, f: Feature) bool {
        if (d.features_only) |only| if (std.mem.indexOfScalar(Feature, only, f) == null) return false;
        return std.mem.indexOfScalar(Feature, d.features_except, f) == null;
    }
};

/// The built-in definitions.
pub const builtin_defs: []const ServerDef = @import("builtin_servers.zon");

/// Where an override came from.
pub const Scope = enum { user, workspace, folder };

/// Settings for one server id; null fields keep the definition's value.
/// An id with no built-in definition defines a new server (it then needs
/// `command` and `languages`).
pub const Override = struct {
    id: []const u8,
    scope: Scope = .user,
    enabled: ?bool = null,
    command: ?[]const []const u8 = null,
    languages: ?[]const []const u8 = null,
    file_patterns: ?[]const []const u8 = null,
    root_markers: ?[]const []const u8 = null,
    initialization_options: ?[]const u8 = null,
    settings_section: ?[]const u8 = null,
    features_only: ?[]const Feature = null,
    features_except: ?[]const Feature = null,
};

pub const Options = struct {
    /// Overrides in increasing precedence (user, then workspace, then folder).
    overrides: []const Override = &.{},
    /// Whether the workspace is trusted (workspace `command` overrides apply).
    trusted: bool = false,
    os: std.Target.Os.Tag = builtin.os.tag,
};

arena: std.heap.ArenaAllocator,
defs: []const ServerDef,
/// Servers whose workspace `command` override was ignored (untrusted).
ignored_commands: []const []const u8,
os: std.Target.Os.Tag,
/// Executable cache: argv[0] -> resolved path (null = not found).
exe_cache: std.StringHashMapUnmanaged(?[]const u8) = .empty,
cache_arena: std.heap.ArenaAllocator,

/// Builds the definitions. Strings are copied.
pub fn init(gpa: Allocator, o: Options) Allocator.Error!Registry {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var defs: std.ArrayList(ServerDef) = .empty;
    try defs.appendSlice(a, builtin_defs);
    var ignored: std.ArrayList([]const u8) = .empty;
    for (o.overrides) |ov| {
        const i = for (defs.items, 0..) |d, k| {
            if (std.mem.eql(u8, d.id, ov.id)) break k;
        } else blk: {
            // A new server needs a command and languages.
            if (ov.command == null or ov.languages == null) continue;
            if (ov.scope != .user and !o.trusted) {
                try ignored.append(a, try a.dupe(u8, ov.id));
                continue;
            }
            try defs.append(a, .{ .id = ov.id, .command = &.{}, .languages = &.{} });
            break :blk defs.items.len - 1;
        };
        const d = &defs.items[i];
        if (ov.enabled) |e| d.enabled = e;
        if (ov.command) |c| {
            if (ov.scope == .user or o.trusted) d.command = c else try ignored.append(a, try a.dupe(u8, ov.id));
        }
        if (ov.languages) |v| d.languages = v;
        if (ov.file_patterns) |v| d.file_patterns = v;
        if (ov.root_markers) |v| d.root_markers = v;
        if (ov.initialization_options) |v| d.initialization_options = v;
        if (ov.settings_section) |v| d.settings_section = v;
        if (ov.features_only) |v| d.features_only = v;
        if (ov.features_except) |v| d.features_except = v;
    }
    // Own every string, so overrides need not outlive the registry.
    for (defs.items) |*d| d.* = try dupeDef(a, d.*);
    return .{
        .arena = arena,
        .defs = defs.items,
        .ignored_commands = ignored.items,
        .os = o.os,
        .cache_arena = .init(gpa),
    };
}

pub fn deinit(r: *Registry) void {
    r.exe_cache.deinit(r.cache_arena.child_allocator);
    r.cache_arena.deinit();
    r.arena.deinit();
}

fn dupeStrings(a: Allocator, ss: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, ss.len);
    for (ss, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}

fn dupeDef(a: Allocator, d: ServerDef) Allocator.Error!ServerDef {
    var n = d;
    n.id = try a.dupe(u8, d.id);
    n.command = try dupeStrings(a, d.command);
    n.languages = try dupeStrings(a, d.languages);
    n.file_patterns = try dupeStrings(a, d.file_patterns);
    n.root_markers = try dupeStrings(a, d.root_markers);
    n.version_args = try dupeStrings(a, d.version_args);
    n.install_hint = try a.dupe(u8, d.install_hint);
    if (d.initialization_options) |s| n.initialization_options = try a.dupe(u8, s);
    if (d.settings_section) |s| n.settings_section = try a.dupe(u8, s);
    if (d.features_only) |f| n.features_only = try a.dupe(Feature, f);
    n.features_except = try a.dupe(Feature, d.features_except);
    return n;
}

/// The definition with `id`, or null.
pub fn get(r: *const Registry, id: []const u8) ?*const ServerDef {
    for (r.defs) |*d| if (std.mem.eql(u8, d.id, id)) return d;
    return null;
}

/// The enabled servers for a document, in registry order (built-ins
/// first): those listing `language_id`, or matching `path` with one of
/// their `file_patterns`.
pub fn defsForDoc(r: *const Registry, language_id: []const u8, path: ?[]const u8, out: *std.ArrayList(*const ServerDef), gpa: Allocator) Allocator.Error!void {
    for (r.defs) |*d| {
        if (!d.enabled) continue;
        const by_lang = for (d.languages) |l| {
            if (std.mem.eql(u8, l, language_id)) break true;
        } else false;
        const by_pattern = if (path) |p| for (d.file_patterns) |g| {
            if (globMatch(g, std.fs.path.basename(p)) or globMatch(g, p)) break true;
        } else false else false;
        if (by_lang or by_pattern) try out.append(gpa, d);
    }
}

/// `*` and `?` glob over one string (enough for file patterns such as
/// `*.templ`; directory globs come from zg_lsp's `glob` when needed).
fn globMatch(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == s[i])) {
            p += 1;
            i += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            mark = i;
            p += 1;
        } else if (star) |st| {
            p = st + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// The executable for `def`, searched on `PATH` (and `PATHEXT` on
/// Windows) from `env`, cached by name; null when not found. An absolute
/// or relative argv[0] is used as is when it exists. Worker only (file
/// system access).
pub fn resolveExecutable(r: *Registry, io: Io, def: *const ServerDef, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (def.command.len == 0) return null;
    const name = def.command[0];
    if (r.exe_cache.get(name)) |hit| return hit;
    const ca = r.cache_arena.allocator();
    const found = try r.search(io, ca, name, env);
    try r.exe_cache.put(r.cache_arena.child_allocator, try ca.dupe(u8, name), found);
    return found;
}

/// Runs `<executable> <version_args>` and returns the first non-empty line
/// of its output, or null when the server is missing, cannot start, or
/// prints nothing within `timeout` (the process is then killed). The
/// initialize result's `serverInfo.version` takes precedence once a server
/// runs. Worker only; the result is `gpa`'s.
pub fn probeVersion(r: *Registry, io: Io, gpa: Allocator, def: *const ServerDef, env: *const std.process.Environ.Map, timeout: Io.Duration) Allocator.Error!?[]u8 {
    const exe = (try r.resolveExecutable(io, def, env)) orelse return null;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, exe);
    try argv.appendSlice(gpa, def.version_args);
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return null;
    // The read runs in its own task and the deadline is a plain wait:
    // blocking pipe reads are not cancelable on Windows, so a timeout kills
    // the process, which ends the read.
    var rd: FirstLine = .{};
    var task = io.concurrent(FirstLine.run, .{ &rd, io, child.stdout.? }) catch {
        child.kill(io);
        return null;
    };
    const timed_out = if (rd.done.waitTimeout(io, zg_core.runtime.Deadline.after(io, timeout).timeout())) false else |_| true;
    if (builtin.os.tag == .windows)
        _ = std.os.windows.ntdll.NtTerminateProcess(child.id.?, @enumFromInt(1))
    else
        std.posix.kill(child.id.?, .KILL) catch {};
    task.await(io);
    _ = child.wait(io) catch {};
    if (timed_out) return null;
    const buf = &rd.buf;
    const n = rd.n;
    var lines = std.mem.tokenizeAny(u8, buf[0..n], "\r\n");
    const line = std.mem.trim(u8, lines.next() orelse return null, " \t");
    if (line.len == 0) return null;
    return try gpa.dupe(u8, line);
}

/// The start of a probed process's output.
const FirstLine = struct {
    buf: [512]u8 = undefined,
    n: usize = 0,
    done: Io.Event = .unset,

    /// Reads until a line ends, end of input, or `buf` is full.
    fn run(f: *FirstLine, io: Io, file: Io.File) void {
        defer f.done.set(io);
        while (f.n < f.buf.len) {
            const got = file.readStreaming(io, &.{f.buf[f.n..]}) catch break;
            if (got == 0) break;
            f.n += got;
            const text = std.mem.trimStart(u8, f.buf[0..f.n], " \t\r\n");
            if (std.mem.indexOfScalar(u8, text, '\n') != null) break;
        }
    }
};

/// Forgets the executable cache ("Rescan", or PATH changed).
pub fn rescan(r: *Registry) void {
    r.exe_cache.clearRetainingCapacity();
    _ = r.cache_arena.reset(.retain_capacity);
}

fn search(r: *const Registry, io: Io, a: Allocator, name: []const u8, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    const windows = r.os == .windows;
    // Windows runs an extensionless file only by its spelled-out name.
    const exts: []const []const u8 = if (windows) try pathExts(a, env.get("PATHEXT"), std.fs.path.extension(name).len > 0) else &.{""};
    const has_sep = std.mem.indexOfScalar(u8, name, '/') != null or (windows and std.mem.indexOfScalar(u8, name, '\\') != null);
    if (has_sep) return r.firstExisting(io, a, &.{""}, name, exts);
    const path_var = env.get("PATH") orelse env.get("Path") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_var, if (windows) ';' else ':');
    while (it.next()) |dir| {
        if (try r.firstExisting(io, a, &.{dir}, name, exts)) |p| return p;
    }
    return null;
}

fn firstExisting(r: *const Registry, io: Io, a: Allocator, dirs: []const []const u8, name: []const u8, exts: []const []const u8) Allocator.Error!?[]const u8 {
    const windows = r.os == .windows;
    for (dirs) |dir| for (exts) |ext| {
        // A name that already ends in one of the extensions is tried as is.
        const full = if (dir.len == 0)
            try std.mem.concat(a, u8, &.{ name, ext })
        else
            try std.mem.concat(a, u8, &.{ dir, if (windows) "\\" else "/", name, ext });
        const ok = if (windows)
            Io.Dir.cwd().access(io, full, .{}) catch null
        else
            Io.Dir.cwd().access(io, full, .{ .execute = true }) catch null;
        if (ok) |_| {
            const st = Io.Dir.cwd().statFile(io, full, .{}) catch continue;
            if (st.kind == .directory) continue;
            return full;
        }
    };
    return null;
}

/// `PATHEXT` as lowercase extensions, the bare name first when it already
/// has an extension.
fn pathExts(a: Allocator, pathext: ?[]const u8, bare: bool) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (bare) try out.append(a, "");
    var it = std.mem.tokenizeScalar(u8, pathext orelse ".COM;.EXE;.BAT;.CMD", ';');
    while (it.next()) |e| try out.append(a, try std.ascii.allocLowerString(a, e));
    return out.items;
}

/// The root folder for `file_path`: the nearest ancestor directory (up to
/// the workspace folder containing the file) holding one of `def`'s root
/// markers, else that workspace folder, else the file's directory.
/// Returns a slice of `file_path` or of a folder in `ws_folders`.
pub fn findRoot(io: Io, def: *const ServerDef, file_path: []const u8, ws_folders: []const []const u8) []const u8 {
    const folder: ?[]const u8 = for (ws_folders) |f| {
        if (isUnder(file_path, f)) break f;
    } else null;
    var dir = std.fs.path.dirname(file_path) orelse return file_path;
    while (true) {
        for (def.root_markers) |m| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, m }) catch continue;
            if (Io.Dir.cwd().access(io, p, .{})) |_| return dir else |_| {}
        }
        if (folder) |f| if (dir.len <= f.len) return f;
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return folder orelse std.fs.path.dirname(file_path) orelse file_path;
}

fn isUnder(path: []const u8, folder: []const u8) bool {
    if (!std.mem.startsWith(u8, path, folder)) return false;
    if (path.len == folder.len) return true;
    const f = std.mem.trimEnd(u8, folder, "/\\");
    return path.len > f.len and (path[f.len] == '/' or path[f.len] == '\\');
}
