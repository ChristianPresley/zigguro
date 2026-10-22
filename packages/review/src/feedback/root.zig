//! Review feedback (E12.F03.S03): comment threads on changesets, with
//! Conventional Comments labels and anchors that follow the text.

const comments = @import("comments.zig");
const labels = @import("labels.zig");
const feedback = @import("feedback.zig");

pub const outcome = @import("outcome.zig");
pub const follow = @import("follow.zig");

pub const message = @import("message.zig");

pub const anchor = @import("anchor.zig");

pub const CommentStore = comments.CommentStore;
pub const Options = comments.Options;
pub const Recorder = comments.Recorder;
pub const RestoreSink = comments.RestoreSink;
pub const Listener = comments.Listener;
pub const ThreadId = comments.ThreadId;
pub const Thread = comments.Thread;
pub const Comment = comments.Comment;
pub const Author = comments.Author;
pub const CommentAnchor = comments.CommentAnchor;
pub const ReanchorOptions = comments.ReanchorOptions;
pub const ReanchorReport = comments.ReanchorReport;
pub const Error = comments.Error;
pub const Op = comments.Op;
pub const writeSnapshot = comments.writeSnapshot;
pub const Side = anchor.Side;

pub const Feedback = feedback.Feedback;
pub const AgentPort = feedback.AgentPort;
pub const AgentStatus = feedback.AgentStatus;
pub const SubmitMode = feedback.SubmitMode;
pub const Delivery = feedback.Delivery;
pub const EndedChoice = feedback.EndedChoice;
pub const FeedbackOptions = feedback.Options;
pub const InterdiffDocs = feedback.InterdiffDocs;
pub const FeedbackMessage = message.FeedbackMessage;
pub const OutcomeReporter = outcome.OutcomeReporter;
pub const Follow = follow.Follow;
pub const Outcome = outcome.Outcome;
pub const FileOutcome = outcome.FileOutcome;
pub const OutcomeSink = outcome.OutcomeSink;
pub const OutcomeOptions = outcome.Options;
pub const ReviewRef = outcome.ReviewRef;
pub const ReviewRecords = outcome.ReviewRecords;

pub const Label = labels.Label;
pub const Prefix = labels.Prefix;
pub const parseLabelPrefix = labels.parseLabelPrefix;

test {
    _ = labels;
    _ = anchor;
    _ = @import("comments_test.zig");
    _ = @import("feedback_test.zig");
    _ = @import("outcome_test.zig");
    _ = @import("follow_test.zig");
}
