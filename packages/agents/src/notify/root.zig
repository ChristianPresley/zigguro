//! Agent notifications (E13.F01.S03): the router (policy, de-duplication,
//! grouping, focus awareness), the run-event mapping and the OS backends.

pub const notification = @import("notification.zig");
pub const policy = @import("policy.zig");
pub const map = @import("map.zig");
pub const os_headless = @import("os_headless.zig");
pub const NotificationRouter = @import("router.zig");
pub const RunNotifier = @import("run_notifier.zig");

pub const Notification = notification.Notification;
pub const NotifyAction = notification.NotifyAction;
pub const Severity = notification.Severity;
pub const OsBackend = notification.OsBackend;
pub const ToastSink = notification.ToastSink;
pub const ActivateFn = notification.ActivateFn;
pub const Policy = policy.Policy;
pub const FocusState = policy.FocusState;
pub const fromRunEvent = map.fromRunEvent;
pub const headlessBackend = os_headless.headlessBackend;

test {
    _ = notification;
    _ = policy;
    _ = map;
    _ = os_headless;
    _ = NotificationRouter;
    _ = RunNotifier;
    _ = @import("policy_test.zig");
    _ = @import("router_test.zig");
}
