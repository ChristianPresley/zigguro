//! Column type inference.

const std = @import("std");
const infer = @import("infer.zig");

const testing = std.testing;

const Case = struct { []const []const u8, infer.InferCtx, infer.ColType };

test "infer_table" {
    const cases = [_]Case{
        .{ &.{ "true", "false", "true" }, .{}, .bool_ },
        .{ &.{ "Yes", "no", "YES" }, .{}, .bool_ },
        .{ &.{ "0", "1", "1", "0" }, .{}, .bool_ },
        .{ &.{ "1", "0", "true" }, .{}, .bool_ },
        .{ &.{ "1", "2", "3" }, .{}, .int },
        .{ &.{ "-5", "+7", "0", "42" }, .{}, .int },
        .{ &.{ "9223372036854775807", "-9223372036854775808" }, .{}, .int },
        .{ &.{ "99999999999999999999", "1" }, .{}, .float },
        .{ &.{ "1", "2", "", "\\N", "null" }, .{}, .int },
        .{ &.{ "1.5", "2", "3.25" }, .{}, .float },
        .{ &.{ "1e3", "-2.5E-2", ".5" }, .{}, .float },
        .{ &.{ "1_000", "2_000" }, .{}, .string },
        .{ &.{ "1,000", "2,500" }, .{}, .string },
        .{ &.{ "12,50", "3,75", "100" }, .{ .decimal_comma = true }, .decimal },
        .{ &.{ "12,50", "3,75" }, .{}, .string },
        .{ &.{ "1.5", "2.5" }, .{ .decimal_comma = true }, .float },
        .{ &.{ "-0,5", "1,25" }, .{ .decimal_comma = true }, .decimal },
        .{ &.{ "inf", "nan" }, .{}, .string },
        .{ &.{ "0x10", "0x20" }, .{}, .string },
        .{ &.{ "2026-10-23", "1999-01-31" }, .{}, .date },
        .{ &.{ "2026-02-30", "2026-01-01" }, .{}, .string },
        .{ &.{ "2024-02-29", "2023-03-01" }, .{}, .date },
        .{ &.{ "23/10/2026", "01/02/2026" }, .{}, .date },
        .{ &.{ "10/23/2026", "02/01/2026" }, .{}, .date },
        .{ &.{ "01/02/2026", "03/04/2026" }, .{}, .date },
        .{ &.{ "23.10.2026", "01.02.2026" }, .{}, .date },
        .{ &.{ "2026-10-23T09:30:00Z", "2026-10-23T10:00:00.250+02:00" }, .{}, .datetime },
        .{ &.{ "2026-10-23 09:30:00", "2026-10-23T23:59:60Z" }, .{}, .datetime },
        .{ &.{ "2026-10-23T25:00:00Z", "x" }, .{}, .string },
        .{ &.{ "2026-10-23", "2026-10-23T09:30:00Z" }, .{}, .string },
        .{ &.{ "Oslo", "Lima" }, .{}, .string },
        .{ &.{ "", "", "NA" }, .{}, .null_ },
        .{ &.{}, .{}, .null_ },
        .{ &.{ " 1 ", " 2" }, .{}, .int },
        .{ &.{ "N/A", "3", "4" }, .{}, .int },
        .{ &.{ "abc", "1", "2" }, .{}, .string },
        .{ &.{ "yes", "maybe" }, .{}, .string },
        .{ &.{ "1.0", "2.0", "x" }, .{}, .string },
        .{ &.{ "007", "010" }, .{}, .int },
        .{ &.{ "-", "+" }, .{}, .string },
    };
    try testing.expectEqual(@as(usize, 40), cases.len);
    var failed = false;
    for (cases, 0..) |c, i| {
        const got = infer.inferColumn(c[0], c[1]);
        if (got != c[2]) {
            std.debug.print("case {d}: got {t}, want {t}\n", .{ i, got, c[2] });
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}

test "98 percent rule" {
    var samples: [100][]const u8 = undefined;
    for (&samples, 0..) |*s, i| s.* = if (i < 98) "12" else "oops";
    try testing.expectEqual(infer.ColType.int, infer.inferColumn(&samples, .{}));
    samples[97] = "oops";
    try testing.expectEqual(infer.ColType.string, infer.inferColumn(&samples, .{}));
}

test "parsed values" {
    try testing.expectEqual(@as(?i32, 0), infer.parseIsoDate("1970-01-01"));
    try testing.expectEqual(@as(?i32, 20749), infer.parseIsoDate("2026-10-23"));
    try testing.expectEqual(@as(?i32, -1), infer.parseIsoDate("1969-12-31"));
    try testing.expectEqual(@as(?i64, 1_792_747_800_000), infer.parseDatetime("2026-10-23T09:30:00Z"));
    try testing.expectEqual(@as(?i64, 1_792_747_800_250 - 2 * 3_600_000), infer.parseDatetime("2026-10-23T09:30:00.25+02:00"));
    try testing.expectEqual(infer.DateOrder.dmy, infer.dateOrderOf(&.{ "01/02/2026", "23/10/2026" }).?);
    try testing.expectEqual(infer.DateOrder.mdy, infer.dateOrderOf(&.{"10/23/2026"}).?);
    try testing.expectEqual(@as(?infer.DateOrder, null), infer.dateOrderOf(&.{"01/02/2026"}));
    try testing.expectEqual(infer.parseIsoDate("2026-02-01"), infer.parseSlashDate("01/02/2026", .dmy));
    try testing.expectEqual(@as(?f64, 12.5), infer.parseDecimalComma("12,5"));
    const v = infer.parse("3,75", .decimal, .{ .decimal_comma = true }).?;
    try testing.expectEqual(@as(f64, 3.75), v.float);
    try testing.expect(infer.parse("", .int, .{}) == null);
    try testing.expectEqual(std.math.Order.lt, (infer.Value{ .int = 2 }).order(.{ .float = 2.5 }));
}
