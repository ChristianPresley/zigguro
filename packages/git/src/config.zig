//! git config files (E09.F07.S02.T02): the syntax, layered scopes,
//! `include.path` and `includeIf` (gitdir, gitdir/i, onbranch), and
//! `GIT_CONFIG_COUNT` overrides, read exactly like git.
//!
//! Keys are `section.name` or `section.subsection.name`; section and name
//! compare case-insensitively, the subsection case-sensitively. The last
//! value wins for `get`; `getAll` lists every value in load order.
//! `setValue` edits one file in place (comments and layout kept) under
//! `config.lock`.

const std = @import("std");
const zg_ignore = @import("zg_ignore");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Where a value came from.
pub const Scope = enum { system, global, local, worktree, command, env };

/// One `name = value` line.
pub const Entry = struct {
    /// Lowercased section.
    section: []const u8,
    /// Case-sensitive subsection, if any.
    subsection: ?[]const u8,
    /// Lowercased variable name.
    name: []const u8,
    /// null: a bare `name` (boolean true).
    value: ?[]const u8,
    scope: Scope,
    /// The file it came from ("" for overrides), and its 1-based line.
    file: []const u8,
    line: u32,
};

/// `file` and `line` of a value, for "show origin".
pub const Origin = struct { file: []const u8, line: u32, scope: Scope };

/// What `load` reads.
pub const Context = struct {
    /// This worktree's `$GIT_DIR` (absolute), or null outside a repository.
    git_dir: ?[]const u8 = null,
    /// `$GIT_COMMON_DIR` (null: same as `git_dir`).
    common_dir: ?[]const u8 = null,
    /// The user's home directory.
    home: ?[]const u8 = null,
    /// `$XDG_CONFIG_HOME`.
    xdg_config_home: ?[]const u8 = null,
    /// Environment for `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM`,
    /// `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n`.
    env: ?*const std.process.Environ.Map = null,
    /// The system file (`$(prefix)/etc/gitconfig`); null skips it.
    system_file: ?[]const u8 = null,
    /// The checked-out branch's short name, for `onbranch:`.
    branch: ?[]const u8 = null,
    /// `-c key=value` overrides.
    overrides: []const []const u8 = &.{},
};

pub const ParseError = error{ InvalidConfig, IncludeDepth, IncludeUnreadable } || Allocator.Error;

const max_include_depth = 10;
const max_file_bytes = 16 << 20;

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    /// For includes and errors: set by `load`.
    io: ?Io = null,
    ctx: Context = .{},
    /// The line of the first syntax error ("" file: none).
    error_file: []const u8 = "",
    error_line: u32 = 0,

    pub fn init(gpa: Allocator) Config {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Config) void {
        c.arena.deinit();
    }

    /// Reads every scope git reads for `ctx`, in git's order. Missing
    /// files are skipped; a malformed one fails with `error.InvalidConfig`
    /// (`error_file`/`error_line` say where).
    pub fn load(gpa: Allocator, io: Io, ctx: Context) !Config {
        var c: Config = .init(gpa);
        errdefer c.deinit();
        c.io = io;
        c.ctx = ctx;
        const a = c.arena.allocator();
        const env = ctx.env;
        const no_system = if (env) |e| e.get("GIT_CONFIG_NOSYSTEM") != null else false;
        if (!no_system) {
            const sys = if (env) |e| e.get("GIT_CONFIG_SYSTEM") orelse ctx.system_file else ctx.system_file;
            if (sys) |p| try c.loadFile(p, .system, 0);
        }
        if (if (env) |e| e.get("GIT_CONFIG_GLOBAL") else null) |g| {
            try c.loadFile(g, .global, 0);
        } else {
            if (ctx.xdg_config_home) |x| {
                try c.loadFile(try std.fs.path.join(a, &.{ x, "git", "config" }), .global, 0);
            } else if (ctx.home) |h| {
                try c.loadFile(try std.fs.path.join(a, &.{ h, ".config", "git", "config" }), .global, 0);
            }
            if (ctx.home) |h| try c.loadFile(try std.fs.path.join(a, &.{ h, ".gitconfig" }), .global, 0);
        }
        if (ctx.common_dir orelse ctx.git_dir) |d| try c.loadFile(try std.fs.path.join(a, &.{ d, "config" }), .local, 0);
        if (ctx.git_dir) |d| if (c.getBool("extensions.worktreeConfig") orelse false) {
            try c.loadFile(try std.fs.path.join(a, &.{ d, "config.worktree" }), .worktree, 0);
        };
        if (env) |e| try c.loadEnv(e);
        for (ctx.overrides) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=');
            try c.addKey(if (eq) |i| kv[0..i] else kv, if (eq) |i| kv[i + 1 ..] else null, .command, "", 0);
        }
        return c;
    }

    fn loadEnv(c: *Config, env: *const std.process.Environ.Map) !void {
        const n_text = env.get("GIT_CONFIG_COUNT") orelse return;
        const n = std.fmt.parseInt(u32, n_text, 10) catch return error.InvalidConfig;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var kb: [32]u8 = undefined;
            var vb: [32]u8 = undefined;
            const k = env.get(std.fmt.bufPrint(&kb, "GIT_CONFIG_KEY_{d}", .{i}) catch unreachable) orelse return error.InvalidConfig;
            const v = env.get(std.fmt.bufPrint(&vb, "GIT_CONFIG_VALUE_{d}", .{i}) catch unreachable) orelse return error.InvalidConfig;
            try c.addKey(k, v, .env, "", 0);
        }
    }

    /// Reads one file (skipped when missing).
    pub fn loadFile(c: *Config, path: []const u8, scope: Scope, depth: u8) !void {
        const io = c.io orelse return error.InvalidConfig;
        const a = c.arena.allocator();
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir, error.IsDir, error.AccessDenied => return,
            else => return e,
        };
        try c.parse(text, try a.dupe(u8, path), scope, depth);
    }

    /// Parses `text` (from `file`) and appends its entries, following
    /// includes when `load` set an `Io`.
    pub fn parse(c: *Config, text: []const u8, file: []const u8, scope: Scope, depth: u8) ParseError!void {
        const a = c.arena.allocator();
        var p: Parser = .{ .text = text, .a = a };
        // A UTF-8 BOM is skipped.
        if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) p.i = 3;
        var section: []const u8 = "";
        var subsection: ?[]const u8 = null;
        while (true) {
            p.skipBlank();
            if (p.done()) break;
            const ch = p.text[p.i];
            if (ch == '#' or ch == ';') {
                p.skipLine();
                continue;
            }
            if (ch == '\n') {
                p.nl();
                continue;
            }
            const line = p.line;
            if (ch == '[') {
                const h = p.header() catch return c.fail(file, line);
                section = h.section;
                subsection = h.subsection;
                continue;
            }
            if (section.len == 0) return c.fail(file, line);
            const kv = p.variable() catch return c.fail(file, line);
            const e: Entry = .{ .section = section, .subsection = subsection, .name = kv.name, .value = kv.value, .scope = scope, .file = file, .line = line };
            try c.entries.append(a, e);
            try c.maybeInclude(e, depth);
        }
    }

    fn fail(c: *Config, file: []const u8, line: u32) error{InvalidConfig} {
        if (c.error_file.len == 0 and c.error_line == 0) {
            c.error_file = file;
            c.error_line = line;
        }
        return error.InvalidConfig;
    }

    fn maybeInclude(c: *Config, e: Entry, depth: u8) ParseError!void {
        if (!std.mem.eql(u8, e.name, "path")) return;
        const io = c.io orelse return;
        _ = io;
        const v = e.value orelse return;
        if (std.mem.eql(u8, e.section, "include")) {
            if (e.subsection != null) return;
        } else if (std.mem.eql(u8, e.section, "includeif")) {
            const cond = e.subsection orelse return;
            if (!c.condition(cond, e.file)) return;
        } else return;
        if (depth + 1 > max_include_depth) return error.IncludeDepth;
        // Includes from overrides have no base directory.
        if (e.file.len == 0 and !std.fs.path.isAbsolute(v) and !std.mem.startsWith(u8, v, "~/")) return;
        const target = try c.expandPath(v, std.fs.path.dirname(e.file) orelse ".");
        c.loadFile(target, e.scope, depth + 1) catch |err| switch (err) {
            error.OutOfMemory, error.InvalidConfig, error.IncludeDepth, error.IncludeUnreadable => |x| return x,
            else => return error.IncludeUnreadable,
        };
    }

    /// `~/` expands to the home directory; a relative path is relative to
    /// `base`.
    fn expandPath(c: *Config, v: []const u8, base: []const u8) ![]const u8 {
        const a = c.arena.allocator();
        if (std.mem.startsWith(u8, v, "~/")) {
            const h = c.ctx.home orelse return v;
            return std.fs.path.join(a, &.{ h, v[2..] });
        }
        if (std.fs.path.isAbsolute(v)) return v;
        return std.fs.path.resolve(a, &.{ base, v });
    }

    /// Whether an `includeIf` condition holds.
    fn condition(c: *Config, cond: []const u8, file: []const u8) bool {
        if (std.mem.startsWith(u8, cond, "gitdir:")) return c.gitdirMatches(cond["gitdir:".len..], file, false);
        if (std.mem.startsWith(u8, cond, "gitdir/i:")) return c.gitdirMatches(cond["gitdir/i:".len..], file, true);
        if (std.mem.startsWith(u8, cond, "onbranch:")) {
            const b = c.ctx.branch orelse return false;
            var pat = cond["onbranch:".len..];
            const a = c.arena.allocator();
            if (std.mem.endsWith(u8, pat, "/")) pat = std.mem.concat(a, u8, &.{ pat, "**" }) catch return false;
            return globMatch(a, pat, b, false);
        }
        return false;
    }

    fn gitdirMatches(c: *Config, raw: []const u8, file: []const u8, casefold: bool) bool {
        const git_dir = c.ctx.git_dir orelse return false;
        const a = c.arena.allocator();
        var pat: []const u8 = raw;
        if (std.mem.startsWith(u8, pat, "~/")) {
            const h = c.ctx.home orelse return false;
            pat = std.mem.concat(a, u8, &.{ h, pat[1..] }) catch return false;
        } else if (std.mem.startsWith(u8, pat, "./")) {
            const base = std.fs.path.dirname(file) orelse return false;
            pat = std.mem.concat(a, u8, &.{ base, pat[1..] }) catch return false;
        } else if (!std.fs.path.isAbsolute(pat) and !(pat.len >= 3 and pat[1] == ':')) {
            pat = std.mem.concat(a, u8, &.{ "**/", pat }) catch return false;
        }
        if (std.mem.endsWith(u8, pat, "/")) pat = std.mem.concat(a, u8, &.{ pat, "**" }) catch return false;
        const subject = slashes(a, git_dir) catch return false;
        const p2 = slashes(a, pat) catch return false;
        return globMatch(a, p2, subject, casefold);
    }

    fn addKey(c: *Config, key: []const u8, value: ?[]const u8, scope: Scope, file: []const u8, line: u32) !void {
        const a = c.arena.allocator();
        const k = splitKey(key) orelse return error.InvalidConfig;
        try c.entries.append(a, .{
            .section = try std.ascii.allocLowerString(a, k.section),
            .subsection = if (k.subsection) |s| try a.dupe(u8, s) else null,
            .name = try std.ascii.allocLowerString(a, k.name),
            .value = if (value) |v| try a.dupe(u8, v) else null,
            .scope = scope,
            .file = file,
            .line = line,
        });
    }

    fn matches(e: Entry, k: Key) bool {
        if (!std.ascii.eqlIgnoreCase(e.section, k.section)) return false;
        if (!std.ascii.eqlIgnoreCase(e.name, k.name)) return false;
        if (k.subsection) |s| {
            const es = e.subsection orelse return false;
            return std.mem.eql(u8, es, s);
        }
        return e.subsection == null;
    }

    fn last(c: *const Config, key: []const u8) ?Entry {
        const k = splitKey(key) orelse return null;
        var i = c.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (matches(c.entries.items[i], k)) return c.entries.items[i];
        }
        return null;
    }

    /// The last value of `key` ("" for a bare boolean), or null.
    pub fn get(c: *const Config, key: []const u8) ?[]const u8 {
        const e = c.last(key) orelse return null;
        return e.value orelse "";
    }

    /// Every value of `key` in load order (bare booleans as "").
    pub fn getAll(c: *const Config, gpa: Allocator, key: []const u8) ![][]const u8 {
        const k = splitKey(key) orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (c.entries.items) |e| if (matches(e, k)) try out.append(gpa, e.value orelse "");
        return out.toOwnedSlice(gpa);
    }

    /// `key` as git's boolean (true/yes/on/1, false/no/off/0/""), or null
    /// when unset or not a boolean.
    pub fn getBool(c: *const Config, key: []const u8) ?bool {
        const e = c.last(key) orelse return null;
        const v = e.value orelse return true;
        return parseBool(v);
    }

    /// `key` as an integer with an optional k, m or g suffix.
    pub fn getInt(c: *const Config, key: []const u8) !?i64 {
        const v = c.get(key) orelse return null;
        return try parseInt(v);
    }

    pub fn origin(c: *const Config, key: []const u8) ?Origin {
        const e = c.last(key) orelse return null;
        return .{ .file = e.file, .line = e.line, .scope = e.scope };
    }

    /// The distinct subsections of `section` in first-seen order (remote
    /// names, branch names, submodule names).
    pub fn subsections(c: *const Config, gpa: Allocator, section: []const u8) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (c.entries.items) |e| {
            if (!std.ascii.eqlIgnoreCase(e.section, section)) continue;
            const s = e.subsection orelse continue;
            for (out.items) |have| {
                if (std.mem.eql(u8, have, s)) break;
            } else try out.append(gpa, s);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// git's boolean words.
pub fn parseBool(v: []const u8) ?bool {
    const words = [_]struct { []const u8, bool }{
        .{ "true", true },   .{ "yes", true }, .{ "on", true },   .{ "1", true },
        .{ "false", false }, .{ "no", false }, .{ "off", false }, .{ "0", false },
        .{ "", false },
    };
    for (words) |w| if (std.ascii.eqlIgnoreCase(v, w[0])) return w[1];
    return null;
}

/// An integer with git's k/m/g suffixes.
pub fn parseInt(v: []const u8) error{InvalidConfig}!i64 {
    const t = std.mem.trim(u8, v, " \t");
    if (t.len == 0) return error.InvalidConfig;
    var mul: i64 = 1;
    var digits = t;
    switch (std.ascii.toLower(t[t.len - 1])) {
        'k' => mul = 1 << 10,
        'm' => mul = 1 << 20,
        'g' => mul = 1 << 30,
        else => {},
    }
    if (mul != 1) digits = t[0 .. t.len - 1];
    const n = std.fmt.parseInt(i64, digits, 0) catch return error.InvalidConfig;
    return std.math.mul(i64, n, mul) catch error.InvalidConfig;
}

pub const Key = struct { section: []const u8, subsection: ?[]const u8, name: []const u8 };

/// Splits `section[.subsection].name` (the subsection may hold dots).
pub fn splitKey(key: []const u8) ?Key {
    const first = std.mem.indexOfScalar(u8, key, '.') orelse return null;
    const lastdot = std.mem.lastIndexOfScalar(u8, key, '.').?;
    if (first == 0 or lastdot + 1 == key.len) return null;
    return .{
        .section = key[0..first],
        .subsection = if (lastdot > first) key[first + 1 .. lastdot] else null,
        .name = key[lastdot + 1 ..],
    };
}

fn slashes(a: Allocator, p: []const u8) ![]u8 {
    const out = try a.dupe(u8, p);
    for (out) |*ch| if (ch.* == '\\') {
        ch.* = '/';
    };
    return out;
}

fn globMatch(a: Allocator, pattern: []const u8, text: []const u8, casefold: bool) bool {
    const pat = zg_ignore.wildmatch.compile(a, pattern, .{ .pathname = true }) catch return false;
    return zg_ignore.wildmatch.match(&pat, text, .{ .pathname = true, .casefold = casefold });
}

const Parser = struct {
    text: []const u8,
    a: Allocator,
    i: usize = 0,
    line: u32 = 1,

    fn done(p: *const Parser) bool {
        return p.i >= p.text.len;
    }

    fn nl(p: *Parser) void {
        p.i += 1;
        p.line += 1;
    }

    fn skipBlank(p: *Parser) void {
        while (p.i < p.text.len and (p.text[p.i] == ' ' or p.text[p.i] == '\t' or p.text[p.i] == '\r')) p.i += 1;
    }

    fn skipLine(p: *Parser) void {
        while (p.i < p.text.len and p.text[p.i] != '\n') p.i += 1;
        if (p.i < p.text.len) p.nl();
    }

    const Header = struct { section: []const u8, subsection: ?[]const u8 };

    /// `[section]`, `[section "sub"]` or the legacy `[section.sub]`.
    fn header(p: *Parser) !Header {
        p.i += 1;
        const start = p.i;
        while (p.i < p.text.len and (std.ascii.isAlphanumeric(p.text[p.i]) or p.text[p.i] == '-' or p.text[p.i] == '.')) p.i += 1;
        const name = p.text[start..p.i];
        if (name.len == 0) return error.InvalidConfig;
        var h: Header = .{ .section = undefined, .subsection = null };
        if (p.i < p.text.len and p.text[p.i] == ']') {
            p.i += 1;
            if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
                // Legacy: the subsection is lowercased too.
                h.section = try std.ascii.allocLowerString(p.a, name[0..dot]);
                h.subsection = try std.ascii.allocLowerString(p.a, name[dot + 1 ..]);
            } else h.section = try std.ascii.allocLowerString(p.a, name);
            return h;
        }
        if (std.mem.indexOfScalar(u8, name, '.') != null) return error.InvalidConfig;
        h.section = try std.ascii.allocLowerString(p.a, name);
        p.skipBlank();
        if (p.i >= p.text.len or p.text[p.i] != '"') return error.InvalidConfig;
        p.i += 1;
        var sub: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.i >= p.text.len or p.text[p.i] == '\n') return error.InvalidConfig;
            const ch = p.text[p.i];
            p.i += 1;
            if (ch == '"') break;
            if (ch == '\\') {
                if (p.i >= p.text.len or p.text[p.i] == '\n') return error.InvalidConfig;
                try sub.append(p.a, p.text[p.i]);
                p.i += 1;
                continue;
            }
            try sub.append(p.a, ch);
        }
        if (p.i >= p.text.len or p.text[p.i] != ']') return error.InvalidConfig;
        p.i += 1;
        h.subsection = sub.items;
        return h;
    }

    const Var = struct { name: []const u8, value: ?[]const u8 };

    fn variable(p: *Parser) !Var {
        const start = p.i;
        if (!std.ascii.isAlphabetic(p.text[p.i])) return error.InvalidConfig;
        while (p.i < p.text.len and (std.ascii.isAlphanumeric(p.text[p.i]) or p.text[p.i] == '-')) p.i += 1;
        const name = try std.ascii.allocLowerString(p.a, p.text[start..p.i]);
        p.skipBlank();
        if (p.i >= p.text.len or p.text[p.i] == '\n' or p.text[p.i] == '#' or p.text[p.i] == ';') {
            p.skipLine();
            return .{ .name = name, .value = null };
        }
        if (p.text[p.i] != '=') return error.InvalidConfig;
        p.i += 1;
        return .{ .name = name, .value = try p.value() };
    }

    /// A value: quotes, escapes, comments and continuations; unquoted
    /// runs of whitespace are kept inside the value, trimmed at its ends.
    fn value(p: *Parser) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var quoted = false;
        // Length of `out` up to its last byte that must be kept (trailing
        // unquoted whitespace is dropped).
        var keep: usize = 0;
        p.skipBlank();
        while (p.i < p.text.len) {
            const ch = p.text[p.i];
            if (ch == '\n') {
                if (quoted) return error.InvalidConfig;
                p.nl();
                break;
            }
            if (!quoted and (ch == '#' or ch == ';')) {
                p.skipLine();
                break;
            }
            p.i += 1;
            switch (ch) {
                '"' => {
                    quoted = !quoted;
                    keep = out.items.len;
                },
                '\\' => {
                    if (p.i >= p.text.len) return error.InvalidConfig;
                    const n = p.text[p.i];
                    p.i += 1;
                    switch (n) {
                        '\n' => {
                            p.line += 1;
                            continue;
                        },
                        '\r' => if (p.i < p.text.len and p.text[p.i] == '\n') {
                            p.i += 1;
                            p.line += 1;
                            continue;
                        } else return error.InvalidConfig,
                        'n' => try out.append(p.a, '\n'),
                        't' => try out.append(p.a, '\t'),
                        'b' => {
                            if (out.items.len > 0) out.items.len -= 1;
                        },
                        '\\', '"' => try out.append(p.a, n),
                        else => return error.InvalidConfig,
                    }
                    keep = out.items.len;
                },
                ' ', '\t', '\r' => {
                    if (ch == '\r' and !quoted and p.i < p.text.len and p.text[p.i] == '\n') continue;
                    try out.append(p.a, ch);
                    if (quoted) keep = out.items.len;
                },
                else => {
                    try out.append(p.a, ch);
                    keep = out.items.len;
                },
            }
        }
        if (quoted) return error.InvalidConfig;
        return out.items[0..keep];
    }
};

// -- writing ---------------------------------------------------------------

/// Sets `key` to `value` in the file at `path` (null removes every
/// occurrence), keeping everything else byte for byte. A new value goes
/// after the section's last variable, or into a new section at the end.
/// Writes `<path>.lock`, then renames it over the file.
pub fn setValue(gpa: Allocator, io: Io, path: []const u8, key: []const u8, value: ?[]const u8) !void {
    const k = splitKey(key) orelse return error.InvalidConfig;
    const old = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return e,
    };
    defer gpa.free(old);
    const next = try editText(gpa, old, k, value);
    defer gpa.free(next);
    try writeLocked(io, path, next);
}

/// Adds another `key = value` after the section's last variable, keeping
/// existing values (multi-valued keys such as `remote.<name>.fetch`).
pub fn addValue(gpa: Allocator, io: Io, path: []const u8, key: []const u8, value: []const u8) !void {
    const k = splitKey(key) orelse return error.InvalidConfig;
    const old = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return e,
    };
    defer gpa.free(old);
    const next = try edit(gpa, old, k, value, true);
    defer gpa.free(next);
    try writeLocked(io, path, next);
}

/// Renames the section `[section "sub"]` to `[section "new_sub"]`, or
/// removes it with everything in it when `new_sub` is null (`git remote
/// rename` / `git remote remove`).
pub fn renameSection(gpa: Allocator, io: Io, path: []const u8, section: []const u8, sub: []const u8, new_sub: ?[]const u8) !void {
    const old = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(old);
    const next = try editSection(gpa, old, section, sub, new_sub);
    defer gpa.free(next);
    try writeLocked(io, path, next);
}

/// `renameSection` on text.
pub fn editSection(gpa: Allocator, text: []const u8, section: []const u8, sub: []const u8, new_sub: ?[]const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = LineIter{ .text = text };
    var inside = false;
    while (it.next()) |ln| {
        const line = text[ln[0]..it.lineEnd(ln)];
        const t = std.mem.trimStart(u8, text[ln[0]..ln[1]], " \t");
        if (t.len > 0 and t[0] == '[') {
            var p: Parser = .{ .text = t, .a = arena.allocator() };
            inside = if (p.header()) |h|
                std.ascii.eqlIgnoreCase(h.section, section) and h.subsection != null and std.mem.eql(u8, h.subsection.?, sub)
            else |_|
                false;
            if (inside) {
                if (new_sub) |ns| {
                    try out.print(gpa, "[{s} \"", .{section});
                    for (ns) |ch| {
                        if (ch == '"' or ch == '\\') try out.append(gpa, '\\');
                        try out.append(gpa, ch);
                    }
                    try out.appendSlice(gpa, "\"]\n");
                }
                continue;
            }
        }
        if (inside and new_sub == null) continue;
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// `setValue` on text.
pub fn editText(gpa: Allocator, text: []const u8, k: Key, value: ?[]const u8) ![]u8 {
    return edit(gpa, text, k, value, false);
}

fn edit(gpa: Allocator, text: []const u8, k: Key, value: ?[]const u8, add: bool) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: Config = .init(gpa);
    defer c.deinit();
    try c.parse(text, "", .local, 0);
    // Byte ranges of each matching line, and of the section's last line.
    var lines: std.ArrayList([2]usize) = .empty;
    defer lines.deinit(gpa);
    var section_end: ?usize = null;
    var it = LineIter{ .text = text };
    var cur_match = false;
    while (it.next()) |ln| {
        const t = std.mem.trimStart(u8, text[ln[0]..ln[1]], " \t");
        if (t.len > 0 and t[0] == '[') {
            var p: Parser = .{ .text = t, .a = arena.allocator() };
            const h = p.header() catch {
                cur_match = false;
                continue;
            };
            cur_match = std.ascii.eqlIgnoreCase(h.section, k.section) and optEql(h.subsection, k.subsection, std.ascii.eqlIgnoreCase(h.section, k.section) and isLegacy(t));
            if (cur_match) section_end = it.lineEnd(ln);
            continue;
        }
        if (!cur_match) continue;
        if (t.len == 0 or t[0] == '#' or t[0] == ';') continue;
        var p: Parser = .{ .text = t, .a = arena.allocator() };
        const v = p.variable() catch continue;
        section_end = it.lineEnd(ln);
        if (std.ascii.eqlIgnoreCase(v.name, k.name)) try lines.append(gpa, .{ ln[0], it.lineEnd(ln) });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const new_line = if (value) |v| try formatLine(arena.allocator(), k.name, v) else null;
    if (lines.items.len > 0 and !add) {
        // Replace the last occurrence (or remove them all).
        var pos: usize = 0;
        for (lines.items, 0..) |r, i| {
            try out.appendSlice(gpa, text[pos..r[0]]);
            if (new_line != null and i == lines.items.len - 1) try out.appendSlice(gpa, new_line.?);
            if (new_line != null and i != lines.items.len - 1) try out.appendSlice(gpa, text[r[0]..r[1]]);
            pos = r[1];
        }
        try out.appendSlice(gpa, text[pos..]);
        return out.toOwnedSlice(gpa);
    }
    const nl = new_line orelse {
        try out.appendSlice(gpa, text);
        return out.toOwnedSlice(gpa);
    };
    if (section_end) |end| {
        try out.appendSlice(gpa, text[0..end]);
        if (end > 0 and text[end - 1] != '\n') try out.append(gpa, '\n');
        try out.appendSlice(gpa, nl);
        try out.appendSlice(gpa, text[end..]);
        return out.toOwnedSlice(gpa);
    }
    try out.appendSlice(gpa, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(gpa, '\n');
    try out.print(gpa, "[{s}", .{k.section});
    if (k.subsection) |s| {
        try out.appendSlice(gpa, " \"");
        for (s) |ch| {
            if (ch == '"' or ch == '\\') try out.append(gpa, '\\');
            try out.append(gpa, ch);
        }
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "]\n");
    try out.appendSlice(gpa, nl);
    return out.toOwnedSlice(gpa);
}

fn isLegacy(header_line: []const u8) bool {
    const close = std.mem.indexOfScalar(u8, header_line, ']') orelse return false;
    return std.mem.indexOfScalar(u8, header_line[0..close], '"') == null;
}

fn optEql(a: ?[]const u8, b: ?[]const u8, fold: bool) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return if (fold) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
}

/// `\tname = value\n`, quoted when the value needs it.
fn formatLine(a: Allocator, name: []const u8, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "\t{s} = ", .{name});
    const needs_quotes = v.len > 0 and (v[0] == ' ' or v[0] == '\t' or v[v.len - 1] == ' ' or v[v.len - 1] == '\t' or
        std.mem.indexOfAny(u8, v, "#;") != null);
    if (needs_quotes) try out.append(a, '"');
    for (v) |ch| switch (ch) {
        '\n' => try out.appendSlice(a, "\\n"),
        '\t' => try out.appendSlice(a, "\\t"),
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        else => try out.append(a, ch),
    };
    if (needs_quotes) try out.append(a, '"');
    try out.append(a, '\n');
    return out.items;
}

/// Lines as [start, end) without the newline; `lineEnd` includes it and
/// any continuation lines.
const LineIter = struct {
    text: []const u8,
    i: usize = 0,

    fn next(it: *LineIter) ?[2]usize {
        if (it.i >= it.text.len) return null;
        const start = it.i;
        var end = start;
        while (end < it.text.len and it.text[end] != '\n') {
            // A trailing backslash continues the logical line.
            if (it.text[end] == '\\' and end + 1 < it.text.len and it.text[end + 1] == '\n') end += 1;
            end += 1;
        }
        it.i = if (end < it.text.len) end + 1 else end;
        return .{ start, end };
    }

    fn lineEnd(it: *const LineIter, ln: [2]usize) usize {
        return if (ln[1] < it.text.len) ln[1] + 1 else ln[1];
    }
};

/// Writes `bytes` to `<path>.lock` (failing when another writer holds
/// it), then renames it over `path`.
pub fn writeLocked(io: Io, path: []const u8, bytes: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = std.fmt.bufPrint(&buf, "{s}.lock", .{path}) catch return error.NameTooLong;
    const cwd = Io.Dir.cwd();
    var f = cwd.createFile(io, lock, .{ .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => return error.ConfigLocked,
        else => return e,
    };
    var ok = false;
    defer if (!ok) cwd.deleteFile(io, lock) catch {};
    {
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }
    try cwd.rename(lock, cwd, path, io);
    ok = true;
}

test "config: syntax table (quotes, escapes, continuation, comments)" {
    const gpa = std.testing.allocator;
    var c: Config = .init(gpa);
    defer c.deinit();
    try c.parse("# comment\n" ++
        "[core]\n" ++
        "\tbare\n" ++
        "\tName = Value ; trailing\n" ++
        "\tspaced =   a   b   # x\n" ++
        "\tquoted = \"  keep  \" tail\n" ++
        "\tesc = a\\tb\\\"c\\\\d\n" ++
        "\tcont = one \\\n" ++
        "two\n" ++
        "\thash = \"a#b;c\"\n" ++
        "\tempty =\n" ++
        "[Remote \"Origin\"]\n" ++
        "\turl = git@example.com:x.git\n" ++
        "[branch.Main]\n" ++
        "\tremote = origin\n" ++
        "\n", "f", .local, 0);
    try std.testing.expectEqualStrings("", c.get("core.bare").?);
    try std.testing.expectEqual(true, c.getBool("core.bare").?);
    try std.testing.expectEqualStrings("Value", c.get("CORE.NAME").?);
    try std.testing.expectEqualStrings("a   b", c.get("core.spaced").?);
    try std.testing.expectEqualStrings("  keep   tail", c.get("core.quoted").?);
    try std.testing.expectEqualStrings("a\tb\"c\\d", c.get("core.esc").?);
    try std.testing.expectEqualStrings("one two", c.get("core.cont").?);
    try std.testing.expectEqualStrings("a#b;c", c.get("core.hash").?);
    try std.testing.expectEqualStrings("", c.get("core.empty").?);
    try std.testing.expectEqual(false, c.getBool("core.empty").?);
    try std.testing.expectEqualStrings("git@example.com:x.git", c.get("remote.Origin.url").?);
    try std.testing.expect(c.get("remote.origin.url") == null);
    // Legacy headers lowercase the subsection.
    try std.testing.expectEqualStrings("origin", c.get("branch.main.remote").?);
    try std.testing.expectEqual(@as(u32, 13), c.origin("remote.Origin.url").?.line);

    var bad: Config = .init(gpa);
    defer bad.deinit();
    try std.testing.expectError(error.InvalidConfig, bad.parse("[core]\n\tx = \"open\n", "b", .local, 0));
    try std.testing.expectEqual(@as(u32, 2), bad.error_line);
}

test "config: ints, bools, getAll and subsections" {
    const gpa = std.testing.allocator;
    var c: Config = .init(gpa);
    defer c.deinit();
    try c.parse("[pack]\n\tlimit = 2k\n[remote \"a\"]\n\tfetch = x\n\tfetch = y\n[remote \"b\"]\n\turl = u\n[x]\n\ty = maybe\n", "f", .local, 0);
    try std.testing.expectEqual(@as(i64, 2048), (try c.getInt("pack.limit")).?);
    const all = try c.getAll(gpa, "remote.a.fetch");
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("y", c.get("remote.a.fetch").?);
    const subs = try c.subsections(gpa, "remote");
    defer gpa.free(subs);
    try std.testing.expectEqual(@as(usize, 2), subs.len);
    try std.testing.expect(c.getBool("x.y") == null);
}

test "config: includes, includeIf and env overrides" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "home/work/repo/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/inc.cfg", .data = "[user]\n\tname = Included\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/work.cfg", .data = "[user]\n\temail = w@example.com\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/other.cfg", .data = "[user]\n\temail = other@example.com\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/main.cfg", .data = "[user]\n\tname = First\n\temail = g@example.com\n[include]\n\tpath = inc.cfg\n[includeIf \"gitdir:~/work/\"]\n\tpath = ~/work.cfg\n[includeIf \"onbranch:feature/\"]\n\tpath = other.cfg\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/work/repo/.git/config", .data = "[core]\n\tbare = false\n" });
    const home = try std.fs.path.join(gpa, &.{ root, "home" });
    defer gpa.free(home);
    const git_dir = try std.fs.path.join(gpa, &.{ home, "work", "repo", ".git" });
    defer gpa.free(git_dir);
    const global = try std.fs.path.join(gpa, &.{ home, "main.cfg" });
    defer gpa.free(global);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("GIT_CONFIG_GLOBAL", global);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_COUNT", "1");
    try env.put("GIT_CONFIG_KEY_0", "core.editor");
    try env.put("GIT_CONFIG_VALUE_0", "vi");
    var c = try Config.load(gpa, io, .{ .git_dir = git_dir, .home = home, .env = &env, .branch = "main", .overrides = &.{"core.pager=less"} });
    defer c.deinit();
    try std.testing.expectEqualStrings("Included", c.get("user.name").?);
    try std.testing.expectEqualStrings("w@example.com", c.get("user.email").?);
    try std.testing.expectEqual(false, c.getBool("core.bare").?);
    try std.testing.expectEqualStrings("vi", c.get("core.editor").?);
    try std.testing.expectEqualStrings("less", c.get("core.pager").?);
    try std.testing.expectEqual(Scope.local, c.origin("core.bare").?.scope);

    var c2 = try Config.load(gpa, io, .{ .git_dir = git_dir, .home = home, .env = &env, .branch = "feature/x" });
    defer c2.deinit();
    try std.testing.expectEqualStrings("other@example.com", c2.get("user.email").?);
}

test "config: writer preserves comments" {
    const gpa = std.testing.allocator;
    const src = "# top\n[core]\n\tbare = false # keep\n\tx = 1\n[remote \"origin\"]\n\turl = a\n";
    const k = splitKey("core.bare").?;
    const a = try editText(gpa, src, k, "true");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("# top\n[core]\n\tbare = true\n\tx = 1\n[remote \"origin\"]\n\turl = a\n", a);
    const b = try editText(gpa, src, splitKey("remote.origin.pushurl").?, "b c#d");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("# top\n[core]\n\tbare = false # keep\n\tx = 1\n[remote \"origin\"]\n\turl = a\n\tpushurl = \"b c#d\"\n", b);
    const c = try editText(gpa, src, splitKey("user.name").?, "Me");
    defer gpa.free(c);
    try std.testing.expectEqualStrings(src ++ "[user]\n\tname = Me\n", c);
    const d = try editText(gpa, src, splitKey("core.x").?, null);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("# top\n[core]\n\tbare = false # keep\n[remote \"origin\"]\n\turl = a\n", d);
    const e = try editText(gpa, src, splitKey("remote.origin.url").?, "z");
    defer gpa.free(e);
    try std.testing.expectEqualStrings("# top\n[core]\n\tbare = false # keep\n\tx = 1\n[remote \"origin\"]\n\turl = z\n", e);
    // The edit reads back.
    var cfg: Config = .init(gpa);
    defer cfg.deinit();
    try cfg.parse(b, "", .local, 0);
    try std.testing.expectEqualStrings("b c#d", cfg.get("remote.origin.pushurl").?);
}
