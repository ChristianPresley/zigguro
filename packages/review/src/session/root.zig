//! Reviewing hunk by hunk (E12.F03.S02): the controller the review
//! editor and `zg review` drive.

pub const review_session = @import("review_session.zig");

pub const ReviewSession = review_session.ReviewSession;
pub const Target = review_session.Target;
pub const Cursor = review_session.Cursor;
pub const FileRef = review_session.FileRef;
pub const Progress = review_session.Progress;
pub const Failure = review_session.Failure;
pub const Listener = review_session.Listener;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("review_session_test.zig");
}
