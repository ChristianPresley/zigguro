//! The chart spec's JSON Schema (E13.F07.S01.T03), published in the
//! artifact tools' input schema and in docs/formats/chart.md. `parseSpec`
//! is the authority: it also checks what a schema cannot say (field
//! types against aggregates, which marks stack), with messages that name
//! the JSON path.

const std = @import("std");
const spec = @import("spec.zig");

/// One encoding channel: a field or a constant `value`.
const field_def =
    \\{"type":"object","additionalProperties":false,"properties":{
    \\"field":{"type":"string","description":"Column name."},
    \\"type":{"enum":["quantitative","nominal","ordinal","temporal"]},
    \\"aggregate":{"enum":["count","sum","mean","median","min","max","distinct"]},
    \\"bin":{"oneOf":[{"const":true},{"type":"object","additionalProperties":false,"properties":{"maxbins":{"type":"number","minimum":2,"maximum":1000}}}]},
    \\"timeUnit":{"enum":["year","quarter","month","week","day","hour"]},
    \\"sort":{"enum":["ascending","descending","none","x","-x","y","-y"]},
    \\"title":{"type":"string"},
    \\"scale":{"type":"object","additionalProperties":false,"properties":{
    \\"type":{"enum":["linear","log","time","band","point"]},"zero":{"type":"boolean"},
    \\"domain":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2},"zone":{"enum":["utc","local"]}}},
    \\"axis":{"oneOf":[{"type":"null"},{"type":"object","additionalProperties":false,"properties":{
    \\"title":{"type":"string"},"grid":{"type":"boolean"},"format":{"enum":["auto","si","percent","plain"]},"labels":{"type":"boolean"}}}]},
    \\"legend":{"type":["boolean","null"]},
    \\"format":{"enum":["auto","si","percent","plain"]},
    \\"value":{"type":["number","string"],"description":"A constant instead of a field (no other keys)."}}}
;

const name_list =
    \\{"type":"array","items":{"type":"string"}}
;

/// The spec as an object schema (to nest in a tool's input schema).
pub const object_json =
    \\{"type":"object","required":["data","mark"],"additionalProperties":false,"properties":{
    \\"$schema":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"},
    \\"width":{"type":"number","minimum":10,"maximum":10000},"height":{"type":"number","minimum":10,"maximum":10000},
    \\"data":{"type":"object","additionalProperties":false,"description":"Exactly one of values, artifact, path (query only with path).","properties":{
    \\"values":{"type":"array","items":{"type":"object"},"maxItems":100000},
    \\"artifact":{"type":"string","description":"A table artifact id."},
    \\"path":{"type":"string","description":"A workspace data file (CSV, TSV, JSON, NDJSON)."},
    \\"query":{"type":"string","description":"A data query over the file."}}},
    \\"mark":{"oneOf":[{"enum":["bar","line","area","point","circle","square","rule","rect","tick","text"]},
    \\{"type":"object","required":["type"],"additionalProperties":false,"properties":{
    \\"type":{"enum":["bar","line","area","point","circle","square","rule","rect","tick","text"]},
    \\"stack":{"oneOf":[{"type":"boolean"},{"const":"group"}],"description":"Bars and areas: stacked (true), overlaid (false) or side by side (\"group\", bars)."},
    \\"filled":{"type":"boolean"},"color":{"type":"string","pattern":"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$"},
    \\"opacity":{"type":"number","minimum":0,"maximum":1},"size":{"type":"number","minimum":0,"maximum":10000},
    \\"strokeWidth":{"type":"number","minimum":0,"maximum":100},"point":{"type":"boolean"}}}]},
    \\"encoding":{"type":"object","additionalProperties":false,"properties":{
    \\"x":
++ field_def ++
    \\,"y":
++ field_def ++
    \\,"x2":
++ field_def ++
    \\,"y2":
++ field_def ++
    \\,"color":
++ field_def ++
    \\,"size":
++ field_def ++
    \\,"shape":
++ field_def ++
    \\,"opacity":
++ field_def ++
    \\,"text":
++ field_def ++
    \\,"tooltip":{"type":"array","items":
++ field_def ++
    \\},"detail":{"type":"array","items":
++ field_def ++
    \\}}},
    \\"transform":{"type":"array","items":{"oneOf":[
    \\{"type":"object","required":["filter"],"additionalProperties":false,"properties":{"filter":{"type":"string","description":"A data query expression."}}},
    \\{"type":"object","required":["calculate","as"],"additionalProperties":false,"properties":{"calculate":{"type":"string"},"as":{"type":"string"}}},
    \\{"type":"object","required":["bin","field","as"],"additionalProperties":false,"properties":{"bin":{"oneOf":[{"const":true},{"type":"object","properties":{"maxbins":{"type":"number"}}}]},"field":{"type":"string"},"as":{"type":"string"}}},
    \\{"type":"object","required":["timeUnit","field","as"],"additionalProperties":false,"properties":{"timeUnit":{"enum":["year","quarter","month","week","day","hour"]},"field":{"type":"string"},"as":{"type":"string"}}},
    \\{"type":"object","required":["fold"],"additionalProperties":false,"properties":{"fold":
++ name_list ++
    \\,"as":{"type":"array","items":{"type":"string"},"minItems":2,"maxItems":2}}},
    \\{"type":"object","required":["aggregate"],"additionalProperties":false,"properties":{"aggregate":{"type":"array","items":{"type":"object","required":["op","as"],"additionalProperties":false,"properties":{
    \\"op":{"enum":["count","sum","mean","median","min","max","distinct"]},"field":{"type":"string"},"as":{"type":"string"}}}},"groupby":
++ name_list ++
    \\}}]}}}}
;

/// The whole spec as a standalone schema document.
pub const json = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"$id\":\"zg-chart/1\",\"title\":\"Chart spec\"," ++ object_json[1..];

test {
    std.testing.refAllDecls(@This());
}

test "the schema is JSON and names every enum value" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const props = parsed.value.object.get("properties").?.object;
    // Every top-level key `parseSpec` accepts.
    for ([_][]const u8{ "$schema", "title", "description", "width", "height", "data", "mark", "encoding", "transform" }) |k| try std.testing.expect(props.contains(k));
    inline for (.{ spec.Mark, spec.FieldType, spec.Aggregate, spec.TimeUnit, spec.ScaleType, spec.Format }) |E| {
        inline for (@typeInfo(E).@"enum".fields) |f| {
            const quoted = "\"" ++ f.name ++ "\"";
            try std.testing.expect(std.mem.indexOf(u8, json, quoted) != null);
        }
    }
    for (spec.Sort.json_names) |n| {
        var buf: [16]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, json, try std.fmt.bufPrint(&buf, "\"{s}\"", .{n})) != null);
    }
}

test "docs/formats/chart.schema.json is this schema" {
    const a = std.testing.allocator;
    const root = @import("zg_options").package_root;
    const path = try std.fs.path.join(a, &.{ root, "..", "..", "docs", "formats", "chart.schema.json" });
    defer a.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20));
    defer a.free(text);
    const doc = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer doc.deinit();
    const ours = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer ours.deinit();
    const x = try std.json.Stringify.valueAlloc(a, doc.value, .{});
    defer a.free(x);
    const y = try std.json.Stringify.valueAlloc(a, ours.value, .{});
    defer a.free(y);
    try std.testing.expectEqualStrings(y, x);
}
