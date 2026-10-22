//! Shell integration (E06.F06). So far: the mark types the OSC dispatcher
//! produces and the `MarkSink` interface.

pub const mark = @import("shell/mark.zig");
pub const Mark = mark.Mark;
pub const MarkSink = mark.MarkSink;
pub const RecordingMarkSink = mark.RecordingMarkSink;

test {
    @import("std").testing.refAllDecls(@This());
}
