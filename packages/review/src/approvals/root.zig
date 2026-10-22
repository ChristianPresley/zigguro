//! The approvals inbox (E12.F05.S02): `ApprovalBroker` hosts E16's
//! approval tickets; the inbox model is what every view lists.

const broker = @import("broker.zig");
const inbox = @import("inbox.zig");

pub const ApprovalBroker = broker.ApprovalBroker;
pub const Options = broker.Options;
pub const Recorder = broker.Recorder;
pub const RestoreSink = broker.RestoreSink;
pub const AnswerError = broker.AnswerError;
pub const writeRecord = broker.writeRecord;
pub const readRecord = broker.readRecord;

pub const ApprovalId = inbox.ApprovalId;
pub const ApprovalState = inbox.ApprovalState;
pub const InboxItem = inbox.InboxItem;
pub const InboxListener = inbox.InboxListener;
pub const Filter = inbox.Filter;
pub const CommandView = inbox.CommandView;
pub const commandView = inbox.commandView;

test {
    _ = inbox;
    _ = @import("broker_test.zig");
}
