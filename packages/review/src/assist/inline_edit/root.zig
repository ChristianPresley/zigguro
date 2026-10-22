//! Inline edit (E12.F06.S01): the prompt for a selection and an
//! instruction, the `<rewrite>` stream parser and the stable streaming
//! diff against the original region.

pub const prompt = @import("prompt.zig");
pub const stream_parser = @import("stream_parser.zig");
pub const stream_diff = @import("stream_diff.zig");

pub const PromptInput = prompt.PromptInput;
pub const PromptParts = prompt.PromptParts;
pub const buildPrompt = prompt.buildPrompt;
pub const StreamParser = stream_parser.StreamParser;
pub const StreamDiff = stream_diff.StreamDiff;

test {
    @import("std").testing.refAllDecls(@This());
}
