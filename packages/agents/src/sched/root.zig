//! Automations (E13.F02): the cron engine, time zones, English
//! descriptions of schedules, automation files and the scheduler.

pub const zone = @import("zone.zig");
pub const cron = @import("cron.zig");
pub const tz = @import("tz.zig");
pub const tzif = @import("tzif.zig");
pub const posix_tz = @import("posix_tz.zig");
pub const tz_windows = @import("tz_windows.zig");
pub const tz_embedded = @import("tz_embedded.zig");
pub const describe_mod = @import("describe.zig");
pub const automation = @import("automation.zig");
pub const jitter = @import("jitter.zig");
pub const state = @import("state.zig");
pub const lease = @import("lease.zig");
pub const history = @import("history.zig");
pub const Scheduler = @import("scheduler.zig");
pub const loader = @import("loader.zig");
pub const AutomationRunner = @import("runner.zig");
pub const tools = @import("tools.zig");
pub const Service = @import("service.zig");
pub const Approvals = @import("approvals.zig");
pub const glob = @import("glob.zig");
pub const guard = @import("guard.zig");
pub const TriggerEngine = @import("triggers.zig");

pub const CronExpr = cron.CronExpr;
pub const ParseError = cron.ParseError;
pub const LocalDateTime = zone.LocalDateTime;
pub const ZoneResolver = zone.ZoneResolver;
pub const Resolved = zone.Resolved;
pub const FixedZone = zone.FixedZone;
pub const utcZone = zone.utcZone;
pub const TimeZone = tz.TimeZone;
pub const PosixRule = posix_tz.PosixRule;
pub const describe = describe_mod.describe;
pub const Automation = automation.Automation;

test {
    _ = zone;
    _ = cron;
    _ = describe_mod;
    _ = automation;
    _ = jitter;
    _ = state;
    _ = lease;
    _ = history;
    _ = Scheduler;
    _ = @import("scheduler_test.zig");
    _ = loader;
    _ = AutomationRunner;
    _ = @import("automation_test.zig");
    _ = @import("runner_test.zig");
    _ = tools;
    _ = @import("tools_test.zig");
    _ = Service;
    _ = Approvals;
    _ = @import("cron_test.zig");
    _ = @import("describe_test.zig");
    _ = tz;
    _ = tz_windows;
    _ = @import("tz_test.zig");
    _ = guard;
    _ = TriggerEngine;
    _ = @import("glob_test.zig");
    _ = @import("triggers_test.zig");
}
