//! AI SCM proposals (E09) as review items (E12.F05.S03).

pub const port = @import("port.zig");

pub const ScmReviewPort = port.ScmReviewPort;
pub const ScmDecision = port.ScmDecision;
pub const PreviewFile = port.PreviewFile;
pub const PreviewFiles = port.PreviewFiles;
pub const ScmActions = port.ScmActions;
pub const RepoActions = port.RepoActions;
pub const Item = port.Item;
pub const Outcome = port.Outcome;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("port_test.zig");
}
