//! Research (E13.F05): the source library that captures what agents read
//! into vault notes, and the tools agents use to capture, find and cite
//! sources.

pub const canon_url = @import("canon_url.zig");
pub const extract = @import("extract.zig");
pub const blocks = @import("blocks.zig");
pub const sources = @import("sources.zig");
pub const tools = @import("tools.zig");
pub const citations = @import("citations.zig");
pub const report = @import("report.zig");
pub const verify = @import("verify.zig");

pub const SourceLibrary = sources.SourceLibrary;
pub const SourceId = sources.SourceId;
pub const canonicalize = canon_url.canonicalize;

test {
    _ = @import("canon_url_test.zig");
    _ = @import("capture_test.zig");
    _ = @import("citations_test.zig");
    _ = @import("report_test.zig");
    _ = @import("verify_test.zig");
}
