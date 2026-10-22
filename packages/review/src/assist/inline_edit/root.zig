//! Inline edit (E12.F06.S01): the prompt for a selection and an
//! instruction, the `<rewrite>` stream parser, the stable streaming diff
//! against the original region, and the session that ties them to a
//! model stream and the review queue.

pub const prompt = @import("prompt.zig");
pub const stream_parser = @import("stream_parser.zig");
pub const stream_diff = @import("stream_diff.zig");
pub const session = @import("session.zig");

pub const PromptInput = prompt.PromptInput;
pub const PromptParts = prompt.PromptParts;
pub const buildPrompt = prompt.buildPrompt;
pub const StreamParser = stream_parser.StreamParser;
pub const StreamDiff = stream_diff.StreamDiff;
pub const InlineEditSession = session.InlineEditSession;
pub const ModelPort = session.ModelPort;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("session_test.zig");
}
