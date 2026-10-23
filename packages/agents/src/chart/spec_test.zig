//! Chart spec reading: valid specs and 30 invalid ones, each with the
//! exact message (JSON path first) a model would see.

const std = @import("std");
const spec = @import("spec.zig");

const testing = std.testing;

const Case = struct { json: []const u8, message: []const u8 };

const base_data =
    \\"data":{"values":[{"a":1,"b":"x"}]}
;

const cases = [_]Case{
    .{ .json = "[1]", .message = "(root): expected an object, found an array" },
    .{ .json = "{\"mark\":\"bar\"", .message = "(root): invalid JSON at line 1, column 14" },
    .{ .json = "{\"mark\":\"bar\",\"mark\":\"line\"}", .message = "(root): duplicate key at line 1, column 28" },
    .{ .json = "{\"mark\":\"bar\"}", .message = "data: required" },
    .{ .json = "{" ++ base_data ++ "}", .message = "mark: required" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"pie\"}", .message = "mark: expected one of bar|line|area|point|circle|square|rule|rect|tick|text" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encodings\":{}}", .message = "encodings: unknown key; allowed: $schema, title, description, width, height, data, mark, encoding, transform" },
    .{ .json = "{\"data\":{},\"mark\":\"bar\"}", .message = "data: expected exactly one of values, artifact, path" },
    .{ .json = "{\"data\":{\"values\":[1]},\"mark\":\"bar\"}", .message = "data.values[0]: expected an object, found a number" },
    .{ .json = "{\"data\":{\"artifact\":\"A-1\",\"query\":\"from t\"},\"mark\":\"bar\"}", .message = "data.query: only allowed with path" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"width\":5}", .message = "width: expected a number from 10 to 10000, found 5" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"height\":\"tall\"}", .message = "height: expected a number, found a string" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":{\"type\":\"line\",\"stack\":true},\"encoding\":{\"x\":{\"field\":\"a\",\"type\":\"quantitative\"},\"y\":{\"field\":\"a\",\"type\":\"quantitative\"}}}", .message = "mark.stack: only bar and area marks stack" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":{\"type\":\"bar\",\"color\":\"blue\"}}", .message = "mark.color: expected a colour like \"#4c78a8\"" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":{\"kind\":\"bar\"}}", .message = "mark.kind: unknown key; allowed: type, stack, filled, color, opacity, size, strokeWidth, point" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"y\":{\"field\":\"a\",\"type\":\"number\"}}}", .message = "encoding.y.type: expected one of quantitative|nominal|ordinal|temporal" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"y\":{\"field\":\"a\"}}}", .message = "encoding.y.type: required (one of quantitative|nominal|ordinal|temporal)" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"y\":{\"type\":\"quantitative\"}}}", .message = "encoding.y.field: required unless aggregate is count" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"y\":{\"field\":\"a\",\"type\":\"quantitative\",\"aggregate\":\"avg\"}}}", .message = "encoding.y.aggregate: expected one of count|sum|mean|median|min|max|distinct" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"y\":{\"field\":\"b\",\"type\":\"nominal\",\"aggregate\":\"sum\"}}}", .message = "encoding.y.aggregate: sum needs a quantitative field" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"b\",\"type\":\"nominal\",\"bin\":true}}}", .message = "encoding.x.bin: needs a quantitative field" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"a\",\"type\":\"quantitative\",\"timeUnit\":\"month\"}}}", .message = "encoding.x.timeUnit: needs a temporal field" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"a\",\"type\":\"temporal\",\"timeUnit\":\"minute\"}}}", .message = "encoding.x.timeUnit: expected one of year|quarter|month|week|day|hour" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"a\",\"type\":\"quantitative\",\"scale\":{\"type\":\"band\"}}}}", .message = "encoding.x.scale.type: a quantitative field cannot use a band scale" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"a\",\"type\":\"quantitative\",\"scale\":{\"domain\":[5,1]}}}}", .message = "encoding.x.scale.domain: min must be less than max" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"a\",\"type\":\"quantitative\",\"sort\":\"up\"}}}", .message = "encoding.x.sort: expected one of ascending|descending|none|x|-x|y|-y" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"colour\":{\"field\":\"b\",\"type\":\"nominal\"}}}", .message = "encoding.colour: unknown key; allowed: x, y, x2, y2, color, size, shape, opacity, text, tooltip, detail" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"line\",\"encoding\":{\"x\":{\"field\":\"a\",\"type\":\"quantitative\"}}}", .message = "encoding: line needs x and y" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"b\",\"type\":\"nominal\"},\"size\":{\"field\":\"a\",\"type\":\"quantitative\"}}}", .message = "encoding.size: only point, circle, square and text marks have a size" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"b\",\"type\":\"nominal\"},\"tooltip\":[{\"field\":\"a\",\"type\":\"quantitative\"},{\"field\":\"a\",\"typo\":1}]}}", .message = "encoding.tooltip[1].typo: unknown key; allowed: field, type, aggregate, bin, timeUnit, sort, title, scale, axis, legend, format, value" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"b\",\"type\":\"nominal\"}},\"transform\":[{\"filter\":\"a > 1\",\"calculate\":\"a\"}]}", .message = "transform[0]: expected exactly one of filter, calculate, bin, aggregate, timeUnit, fold" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"b\",\"type\":\"nominal\"}},\"transform\":[{\"calculate\":\"a * 2\"}]}", .message = "transform[0].as: required" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"b\",\"type\":\"nominal\"}},\"transform\":[{\"aggregate\":[{\"op\":\"sum\",\"as\":\"s\"}]}]}", .message = "transform[0].aggregate[0].field: required unless op is count" },
    .{ .json = "{" ++ base_data ++ ",\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"b\",\"type\":\"nominal\"}},\"transform\":[{\"fold\":[\"a\"],\"as\":[\"k\"]}]}", .message = "transform[0].as: expected [key, value] names" },
};

test "spec_errors_with_paths" {
    try testing.expect(cases.len >= 30);
    for (cases) |cs| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var diag: spec.Diagnostic = .{};
        if (spec.parseSpec(arena.allocator(), cs.json, &diag)) |_| {
            std.debug.print("accepted: {s}\n", .{cs.json});
            return error.TestUnexpectedResult;
        } else |e| {
            try testing.expectEqual(error.InvalidSpec, e);
            testing.expectEqualStrings(cs.message, diag.message) catch |err| {
                std.debug.print("spec: {s}\n", .{cs.json});
                return err;
            };
        }
    }
}

test "valid spec reads every part" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: spec.Diagnostic = .{};
    const s = try spec.parseSpec(arena.allocator(),
        \\{"$schema":"zg-chart/1","title":"Revenue by month","width":600,"height":320,
        \\ "data":{"path":"data/sales.csv","query":"from sales | where region != 'EU'"},
        \\ "mark":{"type":"bar","stack":"group","opacity":0.9},
        \\ "encoding":{
        \\   "x":{"field":"month","type":"temporal","timeUnit":"month","axis":{"title":"Month","grid":false}},
        \\   "y":{"field":"revenue","type":"quantitative","aggregate":"sum","scale":{"zero":true},"format":"si"},
        \\   "color":{"field":"region","type":"nominal","legend":false},
        \\   "tooltip":[{"field":"region","type":"nominal"},{"field":"revenue","type":"quantitative","aggregate":"sum"}]},
        \\ "transform":[{"filter":"revenue > 0"},{"bin":{"maxbins":30},"field":"price","as":"p"},
        \\   {"timeUnit":"week","field":"day","as":"wk"},{"fold":["a","b"]},
        \\   {"aggregate":[{"op":"count","as":"n"}],"groupby":["region"]},{"calculate":"revenue * 2","as":"r2"}]}
    , &diag);
    try testing.expectEqualStrings("Revenue by month", s.title.?);
    try testing.expectEqual(spec.Mark.bar, s.mark.type);
    try testing.expectEqual(spec.Stack.grouped, s.mark.stack.?);
    try testing.expectEqualStrings("data/sales.csv", s.data.file.path);
    try testing.expectEqual(spec.TimeUnit.month, s.encoding.x.?.time_unit.?);
    try testing.expect(!s.encoding.x.?.axis.?.grid.?);
    try testing.expectEqual(spec.Aggregate.sum, s.encoding.y.?.aggregate.?);
    try testing.expectEqual(spec.Format.si, s.encoding.y.?.format);
    try testing.expect(!s.encoding.color.?.legend);
    try testing.expectEqual(2, s.encoding.tooltip.len);
    try testing.expectEqual(6, s.transform.len);
    try testing.expectEqual(30, s.transform[1].bin.maxbins);
    try testing.expectEqualStrings("value", s.transform[3].fold.as[1]);
    // Shorthands: a mark name, a count without a field, `"axis": null`.
    const t = try spec.parseSpec(arena.allocator(),
        \\{"data":{"values":[]},"mark":"bar","encoding":{"x":{"field":"a","type":"nominal","axis":null},"y":{"aggregate":"count"}}}
    , &diag);
    try testing.expect(t.encoding.x.?.axis == null);
    try testing.expectEqualStrings("count", t.encoding.y.?.name());
}

test "hex colours" {
    try testing.expectEqual(0x4C78A8, spec.parseHex("#4c78a8").?);
    try testing.expectEqual(0xFFAA00, spec.parseHex("#fa0").?);
    try testing.expectEqual(null, spec.parseHex("4c78a8"));
}
