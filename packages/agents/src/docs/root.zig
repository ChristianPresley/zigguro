//! Document mode (E13.F04): an agent writing long-form alongside a
//! person. Sections and sticky anchors over a Markdown document, edit
//! proposals as E12 changesets of word hunks, the agent's document
//! tools, and the model behind the document mode view (tracked changes,
//! shortcuts).

pub const sections = @import("sections.zig");
pub const anchors = @import("anchors.zig");
pub const words = @import("words.zig");
pub const doc_session = @import("doc_session.zig");
pub const tools = @import("tools.zig");
pub const shortcuts = @import("shortcuts.zig");
pub const tracked = @import("tracked.zig");
pub const html_sanitize = @import("html_sanitize.zig");
pub const comments = @import("comments.zig");
pub const versions = @import("versions.zig");

pub const DocSession = doc_session.DocSession;
pub const Section = sections.Section;
pub const Proposal = doc_session.Proposal;
pub const ProposeResult = doc_session.ProposeResult;
pub const DocChange = doc_session.DocChange;
pub const ChangePort = doc_session.ChangePort;
pub const TrackedChanges = tracked.TrackedChanges;
pub const CommentStore = comments.CommentStore;

test {
    _ = @import("sections_test.zig");
    _ = @import("anchors_test.zig");
    _ = @import("tools_test.zig");
    _ = @import("doc_mode_test.zig");
    _ = @import("comments_test.zig");
    _ = @import("versions_test.zig");
}
