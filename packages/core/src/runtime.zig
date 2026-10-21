//! The zg_core runtime model: `Runtime` (allocator + `std.Io` owner, UI
//! mailbox, UI-thread assertions), wakers, subsystems and deadlines. See
//! `runtime/Runtime.zig` for the threading rules.

/// The process runtime.
pub const Runtime = @import("runtime/Runtime.zig");
/// Message type of the UI mailbox.
pub const UiMsg = @import("runtime/mailbox.zig").UiMsg;
/// The bounded UI mailbox.
pub const Mailbox = @import("runtime/mailbox.zig").Mailbox;
/// Platform wake hook (implemented by E01).
pub const Waker = @import("runtime/waker.zig").Waker;
/// `std.Io.Event`-backed waker for headless loops.
pub const EventWaker = @import("runtime/waker.zig").EventWaker;
/// Waker that counts calls (tests).
pub const TestWaker = @import("runtime/waker.zig").TestWaker;
/// Structured background work on an `Io.Group`.
pub const Subsystem = @import("runtime/task.zig").Subsystem;
/// Monotonic deadline.
pub const Deadline = @import("runtime/deadline.zig").Deadline;
/// Race a call against a deadline.
pub const withDeadline = @import("runtime/deadline.zig").withDeadline;

test {
    _ = @import("runtime/Runtime.zig");
    _ = @import("runtime/mailbox.zig");
    _ = @import("runtime/waker.zig");
    _ = @import("runtime/task.zig");
    _ = @import("runtime/deadline.zig");
}
