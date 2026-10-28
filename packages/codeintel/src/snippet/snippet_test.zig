const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const Snippet = @import("Snippet.zig");
const variables = @import("variables.zig");
const transform = @import("transform.zig");

/// "text|stops": each stop as index@start-end, `m` for a mirror and
/// `{a/b}` for choices.
fn render(src: []const u8, vars: Snippet.VariableResolver, indent: Snippet.IndentCtx) ![]u8 {
    var s = try Snippet.parse(gpa, src);
    defer s.deinit();
    var e: Snippet.Expansion = .{};
    defer e.deinit(gpa);
    try s.expand(gpa, vars, indent, &e);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, e.text.items);
    try out.append(gpa, '|');
    for (e.stops.items, 0..) |st, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "{d}@{d}-{d}", .{ st.index, st.start, st.end });
        if (st.mirror_of != null) try out.append(gpa, 'm');
        if (st.choice) |c| {
            try out.append(gpa, '{');
            for (c, 0..) |o, j| {
                if (j > 0) try out.append(gpa, '/');
                try out.appendSlice(gpa, o);
            }
            try out.append(gpa, '}');
        }
    }
    // Every stop lies inside the text.
    for (e.stops.items) |st| try testing.expect(st.start <= st.end and st.end <= e.text.items.len);
    return out.toOwnedSlice(gpa);
}

const Fake = struct {
    fn get(_: ?*anyopaque, name: []const u8, _: std.mem.Allocator) ?[]const u8 {
        if (std.mem.eql(u8, name, "TM_FILENAME_BASE")) return "my_file";
        if (std.mem.eql(u8, name, "TM_FILENAME")) return "my_file.zig";
        if (std.mem.eql(u8, name, "TM_SELECTED_TEXT")) return "";
        if (std.mem.eql(u8, name, "TM_CURRENT_WORD")) return "fooBar";
        if (std.mem.eql(u8, name, "MULTI")) return "a\nb";
        return null;
    }
    const vars: Snippet.VariableResolver = .{ .get = get };
};

test "snippet: grammar table" {
    const cases = [_][2][]const u8{
        // Text and escapes.
        .{ "", "|0@0-0" },
        .{ "abc", "abc|0@3-3" },
        .{ "\\$1", "$1|0@2-2" },
        .{ "a\\}b", "a}b|0@3-3" },
        .{ "a\\\\b", "a\\b|0@3-3" },
        .{ "a\\nb", "a\\nb|0@4-4" },
        .{ "}", "}|0@1-1" },
        .{ "a}b", "a}b|0@3-3" },
        .{ "$", "$|0@1-1" },
        .{ "a$", "a$|0@2-2" },
        .{ "$ x", "$ x|0@3-3" },
        .{ "${", "${|0@2-2" },
        .{ "${}", "${}|0@3-3" },
        .{ "$$1", "$|1@1-1,0@1-1" },
        // Tab stops.
        .{ "$1", "|1@0-0,0@0-0" },
        .{ "${1}", "|1@0-0,0@0-0" },
        .{ "$0", "|0@0-0" },
        .{ "${0}", "|0@0-0" },
        .{ "a$1b$2c", "abc|1@1-1,2@2-2,0@3-3" },
        .{ "$2$1", "|1@0-0,2@0-0,0@0-0" },
        .{ "$10", "|10@0-0,0@0-0" },
        .{ "$1x$0y", "xy|1@0-0,0@1-1" },
        .{ "${1", "${1|0@3-3" },
        .{ "${1x}", "${1x}|0@5-5" },
        .{ "$99999999999", "$99999999999|0@12-12" },
        // Placeholders.
        .{ "${1:foo}", "foo|1@0-3,0@3-3" },
        .{ "${1:}", "|1@0-0,0@0-0" },
        .{ "${1:a b c}", "a b c|1@0-5,0@5-5" },
        .{ "${1:foo", "${1:foo|0@7-7" },
        .{ "${1:a\\}b}", "a}b|1@0-3,0@3-3" },
        .{ "${1:a$2b}", "ab|1@0-2,2@1-1,0@2-2" },
        .{ "${1:a${2:b}c}", "abc|1@0-3,2@1-2,0@3-3" },
        .{ "${1:${2:${3:x}}}", "x|1@0-1,2@0-1,3@0-1,0@1-1" },
        .{ "${0:end}", "end|0@0-3" },
        .{ "${1:a}{b}", "a{b}|1@0-1,0@4-4" },
        .{ "${1:{}}", "{}|1@0-1,0@2-2" },
        // Linked indices.
        .{ "${1:foo} $1", "foo foo|1@0-3,1@4-7m,0@7-7" },
        .{ "$1 ${1:foo}", "foo foo|1@0-3,1@4-7m,0@7-7" },
        .{ "${1:a} ${1:b}", "a a|1@0-1,1@2-3m,0@3-3" },
        .{ "${1:x}$1$1", "xxx|1@0-1,1@1-2m,1@2-3m,0@3-3" },
        // Choices.
        .{ "${1|a,b,c|}", "a|1@0-1{a/b/c},0@1-1" },
        .{ "${1|one|}", "one|1@0-3{one},0@3-3" },
        .{ "${1|a\\,b,c|}", "a,b|1@0-3{a,b/c},0@3-3" },
        .{ "${1|a\\|b,c|}", "a|b|1@0-3{a|b/c},0@3-3" },
        .{ "${1|a,b}", "${1|a,b}|0@8-8" },
        .{ "${1|a,b|", "${1|a,b||0@8-8" },
        .{ "${1|a,b|} $1", "a a|1@0-1{a/b},1@2-3m,0@3-3" },
        .{ "${1|,x|}", "|1@0-0{/x},0@0-0" },
        // Variables.
        .{ "$TM_FILENAME", "my_file.zig|0@11-11" },
        .{ "${TM_FILENAME}", "my_file.zig|0@11-11" },
        .{ "${TM_SELECTED_TEXT:none}", "none|0@4-4" },
        .{ "${TM_SELECTED_TEXT}", "|0@0-0" },
        .{ "$UNKNOWN", "UNKNOWN|1@0-7,0@7-7" },
        .{ "${UNKNOWN}", "UNKNOWN|1@0-7,0@7-7" },
        .{ "${UNKNOWN:dflt}", "dflt|0@4-4" },
        .{ "${UNKNOWN:${1:x}}", "x|1@0-1,0@1-1" },
        .{ "$1$UNKNOWN", "UNKNOWN|1@0-0,2@0-7,0@7-7" },
        .{ "$_", "_|1@0-1,0@1-1" },
        .{ "$a1_b", "a1_b|1@0-4,0@4-4" },
        .{ "${TM_FILENAME", "${TM_FILENAME|0@13-13" },
        .{ "${TM_FILENAME?}", "${TM_FILENAME?}|0@15-15" },
        .{ "$TM_FILENAME.x", "my_file.zig.x|0@13-13" },
        .{ "${-x}", "${-x}|0@5-5" },
        // Transforms on variables.
        .{ "${TM_FILENAME_BASE/(.*)/${1:/pascalcase}/}", "MyFile|0@6-6" },
        .{ "${TM_FILENAME_BASE/(.*)/${1:/camelcase}/}", "myFile|0@6-6" },
        .{ "${TM_FILENAME_BASE/(.*)/${1:/upcase}/}", "MY_FILE|0@7-7" },
        .{ "${TM_CURRENT_WORD/(.*)/${1:/snakecase}/}", "foo_bar|0@7-7" },
        .{ "${TM_CURRENT_WORD/(.*)/${1:/kebabcase}/}", "foo-bar|0@7-7" },
        .{ "${TM_CURRENT_WORD/(.*)/${1:/downcase}/}", "foobar|0@6-6" },
        .{ "${TM_CURRENT_WORD/(.*)/${1:/capitalize}/}", "FooBar|0@6-6" },
        .{ "${TM_FILENAME_BASE/_/-/}", "my-file|0@7-7" },
        .{ "${TM_FILENAME/[aeiou]/X/g}", "my_fXlX.zXg|0@11-11" },
        .{ "${TM_FILENAME/[aeiou]/X/}", "my_fXle.zig|0@11-11" },
        .{ "${TM_FILENAME/MY/X/i}", "X_file.zig|0@10-10" },
        .{ "${TM_FILENAME/(\\.zig)?$/${1:+has}/}", "my_filehas|0@10-10" },
        .{ "${TM_FILENAME_BASE/(x)?$/${1:?yes:no}/}", "my_fileno|0@9-9" },
        .{ "${TM_FILENAME_BASE/(x)?$/${1:-def}/}", "my_filedef|0@10-10" },
        .{ "${TM_FILENAME_BASE/(x)?$/${1:def}/}", "my_filedef|0@10-10" },
        .{ "${TM_FILENAME_BASE/(my)/[$1]/}", "[my]_file|0@9-9" },
        .{ "${TM_FILENAME_BASE/(my)/\\$1\\/x/}", "$1/x_file|0@9-9" },
        .{ "${TM_FILENAME_BASE/(a)\\1/x/}", "my_file|0@7-7" },
        .{ "${TM_FILENAME_BASE/x/y}", "${TM_FILENAME_BASE/x/y}|0@23-23" },
        // Transforms on tab stops: mirrors.
        .{ "${1:foo} ${1/(.*)/${1:/upcase}/}", "foo FOO|1@0-3,1@4-7m,0@7-7" },
        .{ "${1:a b} ${1/ /_/g}", "a b a_b|1@0-3,1@4-7m,0@7-7" },
        // LSP and VS Code documentation examples.
        .{ "for (${1:i} = 0; $1 < ${2:n}; $1++) {\n\t$0\n}", "for (i = 0; i < n; i++) {\n\t\n}|1@5-6,1@12-13m,1@19-20m,2@16-17,0@27-27" },
        .{ "${1:${TM_FILENAME_BASE}}", "my_file|1@0-7,0@7-7" },
        .{ "Hello $1, ${2|world,there|}!", "Hello , world!|1@6-6,2@8-13{world/there},0@14-14" },
    };
    for (cases) |c| {
        const got = try render(c[0], Fake.vars, .{ .indent_unit = "\t" });
        defer gpa.free(got);
        testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("snippet: {s}\n", .{c[0]});
            return e;
        };
    }
}

test "snippet: expansion indentation and \\t" {
    const got = try render("if ($1) {\n\t$0\n}", .none, .{ .line_indent = "    ", .indent_unit = "  " });
    defer gpa.free(got);
    try testing.expectEqualStrings("if () {\n      \n    }|1@4-4,0@14-14", got);
    // Variable values keep their tabs; their lines are indented too.
    const v = try render("x$MULTI\t", Fake.vars, .{ .line_indent = "  ", .indent_unit = "    " });
    defer gpa.free(v);
    try testing.expectEqualStrings("xa\n  b    |0@10-10", v);
}

test "snippet: variables" {
    var ctx: variables.Context = .{
        .selected_text = "sel",
        .current_line = "  line",
        .current_word = "word",
        .line_index = 4,
        .file_path = "/w/src/main.zig",
        .workspace_folder = "/w",
        .clipboard = "clip",
        .cursor_index = 1,
        .line_comment = "//",
        .block_comment = .{ "/*", "*/" },
        // 2024-02-29 13:05:09.123 UTC, a Thursday.
        .now_ms = 1709211909123,
        .tz_offset_min = 0,
        .random_bytes = &.{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 },
    };
    const want = [_][2][]const u8{
        .{ "TM_SELECTED_TEXT", "sel" },
        .{ "TM_CURRENT_LINE", "  line" },
        .{ "TM_CURRENT_WORD", "word" },
        .{ "TM_LINE_INDEX", "4" },
        .{ "TM_LINE_NUMBER", "5" },
        .{ "TM_FILENAME", "main.zig" },
        .{ "TM_FILENAME_BASE", "main" },
        .{ "TM_DIRECTORY", "/w/src" },
        .{ "TM_FILEPATH", "/w/src/main.zig" },
        .{ "RELATIVE_FILEPATH", "src/main.zig" },
        .{ "CLIPBOARD", "clip" },
        .{ "WORKSPACE_NAME", "w" },
        .{ "WORKSPACE_FOLDER", "/w" },
        .{ "CURSOR_INDEX", "1" },
        .{ "CURSOR_NUMBER", "2" },
        .{ "CURRENT_YEAR", "2024" },
        .{ "CURRENT_YEAR_SHORT", "24" },
        .{ "CURRENT_MONTH", "02" },
        .{ "CURRENT_MONTH_NAME", "February" },
        .{ "CURRENT_MONTH_NAME_SHORT", "Feb" },
        .{ "CURRENT_DATE", "29" },
        .{ "CURRENT_DAY_NAME", "Thursday" },
        .{ "CURRENT_DAY_NAME_SHORT", "Thu" },
        .{ "CURRENT_HOUR", "13" },
        .{ "CURRENT_MINUTE", "05" },
        .{ "CURRENT_SECOND", "09" },
        .{ "CURRENT_MILLISECOND", "123" },
        .{ "CURRENT_SECONDS_UNIX", "1709211909" },
        .{ "CURRENT_MILLISECONDS_UNIX", "1709211909123" },
        .{ "CURRENT_TIMEZONE_OFFSET", "+00:00" },
        .{ "CURRENT_TIMEZONE_NAME", "UTC" },
        .{ "RANDOM", "915346" },
        .{ "RANDOM_HEX", "123456" },
        .{ "UUID", "12345678-9abc-4ef0-9234-56789abcdef0" },
        .{ "LINE_COMMENT", "//" },
        .{ "BLOCK_COMMENT_START", "/*" },
        .{ "BLOCK_COMMENT_END", "*/" },
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = ctx.resolver();
    for (want) |w| {
        const got = r.get(r.ctx, w[0], arena.allocator()) orelse return error.Unknown;
        testing.expectEqualStrings(w[1], got) catch |e| {
            std.debug.print("variable {s}\n", .{w[0]});
            return e;
        };
    }
    try testing.expect(r.get(r.ctx, "NOPE", arena.allocator()) == null);
    ctx.tz_offset_min = -330;
    try testing.expectEqualStrings("-05:30", r.get(r.ctx, "CURRENT_TIMEZONE_OFFSET", arena.allocator()).?);
    try testing.expectEqualStrings("07", r.get(r.ctx, "CURRENT_HOUR", arena.allocator()).?);
    // Real time and randomness come from std.Io.
    const live: variables.Context = .{ .io = testing.io };
    const lr = live.resolver();
    const y = try std.fmt.parseInt(u32, lr.get(lr.ctx, "CURRENT_YEAR", arena.allocator()).?, 10);
    try testing.expect(y >= 2024);
    try testing.expectEqual(@as(usize, 36), lr.get(lr.ctx, "UUID", arena.allocator()).?.len);
}

test "snippet: transforms, global vs first match, empty matches" {
    var t: transform.Transform = try .init(gpa, "a*", &.{.{ .text = "-" }}, "g");
    defer t.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try transform.applyTransform(gpa, &t, "baac", &out);
    try testing.expectEqualStrings("-b--c-", out.items);
    out.clearRetainingCapacity();
    try transform.convertCase(gpa, .pascalcase, "HTTPServer error-code", &out);
    try testing.expectEqualStrings("HttpServerErrorCode", out.items);
    out.clearRetainingCapacity();
    try transform.convertCase(gpa, .snakecase, "parseHTTPRequest", &out);
    try testing.expectEqualStrings("parse_http_request", out.items);
}

test "snippet: plain text, and malformed input never fails" {
    var s = try Snippet.parse(gpa, "fn ${1:name}(${2|a,b|}) $0");
    defer s.deinit();
    const p = try s.plainText(gpa);
    defer gpa.free(p);
    try testing.expectEqualStrings("fn name(a) ", p);
    var prng: std.Random.DefaultPrng = .init(1);
    const alphabet = "${}:|,/\\01aZ_ +?-";
    var buf: [24]u8 = undefined;
    for (0..2000) |_| {
        for (&buf) |*c| c.* = alphabet[prng.random().uintLessThan(usize, alphabet.len)];
        const n = prng.random().uintLessThan(usize, buf.len + 1);
        const got = try render(buf[0..n], Fake.vars, .{});
        gpa.free(got);
    }
}

test "fuzz: snippet parse" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            const got = try render(input, Fake.vars, .{ .line_indent = "  ", .indent_unit = "    " });
            gpa.free(got);
        }
    }.f, .{});
}
