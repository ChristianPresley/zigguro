//! Golden English for common cron shapes.

const std = @import("std");
const cron = @import("cron.zig");
const describe = @import("describe.zig").describe;

const cases = [_]struct { []const u8, []const u8 }{
    .{ "* * * * *", "every minute" },
    .{ "*/15 * * * *", "every 15 minutes" },
    .{ "*/10 9-17 * * *", "every 10 minutes from 09:00 to 17:59" },
    .{ "* 9 * * *", "every minute from 09:00 to 09:59" },
    .{ "0 * * * *", "every hour at :00" },
    .{ "5,35 * * * *", "every hour at :05 and :35" },
    .{ "30 9 * * *", "at 09:30 every day" },
    .{ "0 */2 * * *", "every 2 hours at :00" },
    .{ "0 9-17 * * 1-5", "every hour from 09:00 to 17:00 on weekdays" },
    .{ "0 9 * * 1-5", "at 09:00 on weekdays" },
    .{ "0 10 * * sat,sun", "at 10:00 on weekends" },
    .{ "0 9 * * 1,3,5", "at 09:00 on Monday, Wednesday and Friday" },
    .{ "0 9 * * mon-wed,fri", "at 09:00 on Monday to Wednesday and Friday" },
    .{ "0 8,12,18 * * *", "at 08:00, 12:00 and 18:00 every day" },
    .{ "15,45 9 * * *", "at 09:15 and 09:45 every day" },
    .{ "@daily", "at 00:00 every day" },
    .{ "@hourly", "every hour at :00" },
    .{ "@weekly", "at 00:00 on Sunday" },
    .{ "@monthly", "at 00:00 on day 1 of the month" },
    .{ "@yearly", "at 00:00 on day 1 in January" },
    .{ "0 0 1,15 * *", "at 00:00 on days 1 and 15 of the month" },
    .{ "0 0 13 * 5", "at 00:00 on day 13 of the month or on Friday" },
    .{ "0 0 * 6-8 *", "at 00:00 every day in June to August" },
    .{ "*/5 * * jan,jul *", "every 5 minutes in January and July" },
    .{ "7,19,31,43,55 3,15 * * *", "at minutes 7, 19, 31, 43 and 55 past hours 3 and 15 every day" },
};

test "describe_table" {
    var buf: [256]u8 = undefined;
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        const e = try cron.CronExpr.parse(c[0]);
        try describe(&e, &w);
        std.testing.expectEqualStrings(c[1], w.buffered()) catch |err| {
            std.debug.print("case \"{s}\"\n", .{c[0]});
            return err;
        };
    }
}
