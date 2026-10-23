//! Artifact kinds (E13.F07.S01.T01): file extensions, size caps and the
//! per-kind validation run on every create and update. Charts and
//! diagrams are checked by validators the app plugs in (E13.F07.S01.T03's
//! ChartSpec, F07.S02's diagram parser); without one they get a basic
//! well-formedness check.

const std = @import("std");
const sniff = @import("../data/sniff.zig");
const chart = @import("../chart/root.zig");

pub const ArtifactKind = enum {
    markdown,
    table,
    chart,
    diagram,
    image,
    html_source,
    code,
    text,

    pub fn isText(k: ArtifactKind) bool {
        return k != .image;
    }

    /// The size cap for one version.
    pub fn maxSize(k: ArtifactKind) usize {
        return if (k == .image) max_binary else max_text;
    }
};

pub const max_text = 5 << 20;
pub const max_binary = 50 << 20;

pub const ImageFormat = enum {
    png,
    jpeg,
    gif,
    svg,

    pub fn ext(f: ImageFormat) []const u8 {
        return switch (f) {
            .png => "png",
            .jpeg => "jpg",
            .gif => "gif",
            .svg => "svg",
        };
    }

    pub fn mime(f: ImageFormat) []const u8 {
        return switch (f) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .svg => "image/svg+xml",
        };
    }
};

pub const ImageInfo = struct { format: ImageFormat, w: u32 = 0, h: u32 = 0 };

/// Format and pixel size from an image's first bytes (SVG: its `width`
/// and `height` attributes, or the `viewBox`, when they are numbers).
pub fn probeImage(b: []const u8) ?ImageInfo {
    if (b.len >= 24 and std.mem.eql(u8, b[0..8], "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, b[12..16], "IHDR"))
        return .{ .format = .png, .w = std.mem.readInt(u32, b[16..20], .big), .h = std.mem.readInt(u32, b[20..24], .big) };
    if (b.len >= 10 and (std.mem.startsWith(u8, b, "GIF87a") or std.mem.startsWith(u8, b, "GIF89a")))
        return .{ .format = .gif, .w = std.mem.readInt(u16, b[6..8], .little), .h = std.mem.readInt(u16, b[8..10], .little) };
    if (b.len >= 4 and b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF) return probeJpeg(b);
    return probeSvg(b);
}

fn probeJpeg(b: []const u8) ?ImageInfo {
    var i: usize = 2;
    while (i + 4 <= b.len) {
        if (b[i] != 0xFF) return null;
        const m = b[i + 1];
        if (m == 0xFF) {
            i += 1;
            continue;
        }
        if (m == 0x01 or (m >= 0xD0 and m <= 0xD9)) {
            i += 2;
            continue;
        }
        const len = std.mem.readInt(u16, b[i + 2 ..][0..2], .big);
        if (len < 2) return null;
        // SOF0..SOF15, except DHT (C4), JPG (C8) and DAC (CC).
        if (m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC) {
            if (i + 9 > b.len) return .{ .format = .jpeg };
            return .{ .format = .jpeg, .h = std.mem.readInt(u16, b[i + 5 ..][0..2], .big), .w = std.mem.readInt(u16, b[i + 7 ..][0..2], .big) };
        }
        i += 2 + len;
    }
    return .{ .format = .jpeg };
}

fn probeSvg(b: []const u8) ?ImageInfo {
    var s = b[utf8Bom(b)..];
    s = s[0..@min(s.len, 4096)];
    // Skip the XML declaration, comments and a doctype.
    while (true) {
        s = std.mem.trimStart(u8, s, " \t\r\n");
        if (std.mem.startsWith(u8, s, "<?")) {
            s = s[(std.mem.indexOf(u8, s, "?>") orelse return null) + 2 ..];
        } else if (std.mem.startsWith(u8, s, "<!--")) {
            s = s[(std.mem.indexOf(u8, s, "-->") orelse return null) + 3 ..];
        } else if (std.mem.startsWith(u8, s, "<!")) {
            s = s[(std.mem.indexOfScalar(u8, s, '>') orelse return null) + 1 ..];
        } else break;
    }
    if (!std.mem.startsWith(u8, s, "<svg") or s.len < 5 or !(std.ascii.isWhitespace(s[4]) or s[4] == '>' or s[4] == '/')) return null;
    const tag = s[0 .. std.mem.indexOfScalar(u8, s, '>') orelse s.len];
    var info: ImageInfo = .{ .format = .svg };
    info.w = attrNumber(tag, "width") orelse 0;
    info.h = attrNumber(tag, "height") orelse 0;
    if ((info.w == 0 or info.h == 0) and attr(tag, "viewBox") != null) {
        var it = std.mem.tokenizeAny(u8, attr(tag, "viewBox").?, " ,");
        var v: [4]f64 = undefined;
        var n: usize = 0;
        while (it.next()) |t| : (n += 1) {
            if (n == 4) break;
            v[n] = std.fmt.parseFloat(f64, t) catch break;
        }
        if (n == 4 and v[2] > 0 and v[3] > 0 and v[2] < 1e6 and v[3] < 1e6) {
            info.w = @intFromFloat(@round(v[2]));
            info.h = @intFromFloat(@round(v[3]));
        }
    }
    return info;
}

fn utf8Bom(b: []const u8) usize {
    return if (std.mem.startsWith(u8, b, "\xEF\xBB\xBF")) 3 else 0;
}

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |at| {
        i = at + name.len;
        if (at == 0 or !std.ascii.isWhitespace(tag[at - 1])) continue;
        var j = i;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const q = tag[j];
        const end = std.mem.indexOfScalarPos(u8, tag, j + 1, q) orelse return null;
        return tag[j + 1 .. end];
    }
    return null;
}

fn attrNumber(tag: []const u8, name: []const u8) ?u32 {
    var v = attr(tag, name) orelse return null;
    if (std.mem.endsWith(u8, v, "px")) v = v[0 .. v.len - 2];
    const f = std.fmt.parseFloat(f64, v) catch return null;
    if (!(f > 0 and f < 1e6)) return null;
    return @intFromFloat(@round(f));
}

/// Checks a chart spec or diagram source; returns an error message for
/// the tool result, or null when it is valid.
pub const Validator = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, content: []const u8) anyerror!?[]const u8,
};

/// The chart validator: strict spec reading (E13.F07.S01.T03).
pub const chart_validator: Validator = .{ .ctx = @constCast(@as(*const anyopaque, &chart_validator_ctx)), .check = chart.checkSpec };
const chart_validator_ctx: u8 = 0;

pub const Validators = struct {
    chart: ?Validator = null,
    diagram: ?Validator = null,
};

pub const Checked = struct {
    /// The content file's extension.
    ext: []const u8,
    mime: []const u8,
    image: ?ImageInfo = null,
};

pub const Invalid = struct { message: []const u8 };

pub const Result = union(enum) { ok: Checked, invalid: Invalid };

/// Validates `content` as `kind`; the message of an invalid result is
/// returned verbatim as a tool error.
pub fn validate(arena: std.mem.Allocator, kind: ArtifactKind, content: []const u8, source_lang: ?[]const u8, vs: Validators) !Result {
    if (content.len > kind.maxSize())
        return invalid(arena, "{s} artifacts are limited to {d} MB, got {d} bytes", .{ @tagName(kind), kind.maxSize() >> 20, content.len });
    if (kind.isText() and !std.unicode.utf8ValidateSlice(content)) {
        // UTF-16 and Latin-1 tables open through F06's decoder.
        if (kind == .table) return ok("csv", "text/csv");
        return invalid(arena, "{s} artifacts must be UTF-8 text", .{@tagName(kind)});
    }
    switch (kind) {
        .markdown => return ok("md", "text/markdown"),
        .text => return ok("txt", "text/plain"),
        .html_source => return ok("html", "text/html"),
        .code => return ok(extForLang(source_lang), "text/plain"),
        .image => {
            const info = probeImage(content) orelse
                return invalid(arena, "image artifacts must be PNG, JPEG, GIF or SVG", .{});
            return .{ .ok = .{ .ext = info.format.ext(), .mime = info.format.mime(), .image = info } };
        },
        .table => {
            const t = std.mem.trimStart(u8, content[utf8Bom(content)..], " \t\r\n");
            if (t.len == 0) return invalid(arena, "the table is empty", .{});
            if (t[0] == '[') {
                if (!(try std.json.validate(arena, t))) return invalid(arena, "the table is not valid JSON", .{});
                return ok("json", "application/json");
            }
            if (t[0] == '{') {
                var lines = std.mem.tokenizeAny(u8, t, "\r\n");
                var n: usize = 1;
                while (lines.next()) |line| : (n += 1) {
                    if (std.mem.trim(u8, line, " \t").len == 0) continue;
                    if (!(try std.json.validate(arena, line))) return invalid(arena, "line {d} of the table is not valid JSON", .{n});
                }
                return ok("ndjson", "application/x-ndjson");
            }
            const s = sniff.sniff(content[0..@min(content.len, 64 << 10)]);
            if (s.columns == 0) return invalid(arena, "the table has no columns", .{});
            return if (s.dialect.delimiter == '\t') ok("tsv", "text/tab-separated-values") else ok("csv", "text/csv");
        },
        .chart => {
            if (vs.chart) |v| if (try v.check(v.ctx, arena, content)) |m| return .{ .invalid = .{ .message = m } };
            if (!(try std.json.validate(arena, content))) return invalid(arena, "the chart spec is not valid JSON", .{});
            return ok("json", "application/json");
        },
        .diagram => {
            if (vs.diagram) |v| if (try v.check(v.ctx, arena, content)) |m| return .{ .invalid = .{ .message = m } };
            if (std.mem.trim(u8, content, " \t\r\n").len == 0) return invalid(arena, "the diagram source is empty", .{});
            return ok("mmd", "text/vnd.mermaid");
        },
    }
}

fn ok(ext: []const u8, mime: []const u8) Result {
    return .{ .ok = .{ .ext = ext, .mime = mime } };
}

fn invalid(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Result {
    return .{ .invalid = .{ .message = try std.fmt.allocPrint(arena, fmt, args) } };
}

const lang_exts = [_]struct { []const u8, []const u8 }{
    .{ "zig", "zig" },   .{ "python", "py" },      .{ "py", "py" },       .{ "javascript", "js" },
    .{ "js", "js" },     .{ "typescript", "ts" },  .{ "ts", "ts" },       .{ "rust", "rs" },
    .{ "go", "go" },     .{ "c", "c" },            .{ "cpp", "cpp" },     .{ "c++", "cpp" },
    .{ "java", "java" }, .{ "sql", "sql" },        .{ "shell", "sh" },    .{ "bash", "sh" },
    .{ "sh", "sh" },     .{ "powershell", "ps1" }, .{ "r", "r" },         .{ "json", "json" },
    .{ "yaml", "yaml" }, .{ "toml", "toml" },      .{ "html", "html" },   .{ "css", "css" },
    .{ "ruby", "rb" },   .{ "kotlin", "kt" },      .{ "swift", "swift" }, .{ "csharp", "cs" },
};

/// A file extension for code in `lang` ("txt" when unknown).
pub fn extForLang(lang: ?[]const u8) []const u8 {
    const l = lang orelse return "txt";
    for (lang_exts) |e| if (std.ascii.eqlIgnoreCase(e[0], l)) return e[1];
    return "txt";
}

/// The kind a file most likely holds, from its extension (for imported
/// program outputs).
pub fn kindForPath(path: []const u8) ArtifactKind {
    const ext = std.fs.path.extension(path);
    const e = if (ext.len > 0) ext[1..] else "";
    const eq = std.ascii.eqlIgnoreCase;
    for ([_][]const u8{ "csv", "tsv", "json", "ndjson", "jsonl" }) |x| if (eq(e, x)) return .table;
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "svg" }) |x| if (eq(e, x)) return .image;
    for ([_][]const u8{ "md", "markdown" }) |x| if (eq(e, x)) return .markdown;
    for ([_][]const u8{ "html", "htm" }) |x| if (eq(e, x)) return .html_source;
    if (eq(e, "mmd")) return .diagram;
    if (eq(e, "txt") or eq(e, "log") or e.len == 0) return .text;
    for (lang_exts) |x| if (eq(e, x[1])) return .code;
    return .text;
}
