//! Shell integration (E06.F06): the mark types the OSC dispatcher produces,
//! the `MarkSink` interface, the command blocks built from the marks, and
//! the scripts that make shells send them (`inject`).

pub const mark = @import("shell/mark.zig");
pub const Mark = mark.Mark;
pub const MarkSink = mark.MarkSink;
pub const RecordingMarkSink = mark.RecordingMarkSink;
pub const blocks = @import("shell/blocks.zig");
pub const Blocks = blocks.Blocks;
pub const Block = blocks.Block;
pub const BlockId = blocks.BlockId;
pub const BlockEvent = blocks.BlockEvent;
pub const BlockListener = blocks.BlockListener;
pub const inject = @import("shell/inject.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("shell/blocks_test.zig");
    _ = @import("shell/inject_test.zig");
}
