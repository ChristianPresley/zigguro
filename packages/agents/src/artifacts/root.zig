//! Artifacts (E13.F07): what agents make beside the conversation
//! (documents, tables, charts, diagrams, images, code), versioned and
//! saved under `.zigguro/artifacts`.

pub const kinds = @import("kinds.zig");
pub const store = @import("store.zig");
pub const save = @import("save.zig");
pub const tools = @import("tools.zig");

pub const ArtifactKind = kinds.ArtifactKind;
pub const ArtifactId = store.ArtifactId;
pub const ArtifactStore = store.ArtifactStore;
pub const Artifact = store.Artifact;
pub const NewArtifact = store.NewArtifact;
pub const Content = store.Content;

test {
    _ = @import("kinds_test.zig");
    _ = @import("store_test.zig");
    _ = @import("tools_test.zig");
}
