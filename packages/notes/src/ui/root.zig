//! zg_notes_ui: the notes UI over zg_gui (E08.F06): the sidebar (backlinks,
//! outgoing links, tags, properties), vault setup and the note search
//! view. A module of its own so headless consumers never import zg_gui.

const std = @import("std");

/// What the UI needs from the app.
pub const ports = @import("ports.zig");
/// The sidebar's state.
pub const sidebar_model = @import("sidebar_model.zig");
/// The sidebar dock panel.
pub const notes_sidebar = @import("notes_sidebar.zig");
pub const backlinks_panel = @import("backlinks_panel.zig");
pub const outgoing_panel = @import("outgoing_panel.zig");
pub const tags_panel = @import("tags_panel.zig");
pub const properties_panel = @import("properties_panel.zig");
/// The note search view's state and saved searches.
pub const search_view_model = @import("search_view_model.zig");
/// The note search dock panel.
pub const search_view = @import("search_view.zig");
/// The vault prompt and the notes commands.
pub const vault_setup = @import("vault_setup.zig");

pub const NotesSidebarModel = sidebar_model.NotesSidebarModel;
pub const SidebarView = notes_sidebar.SidebarView;
pub const notesSidebar = notes_sidebar.notesSidebar;
pub const propertiesEditor = properties_panel.propertiesEditor;
pub const VaultSetup = vault_setup.VaultSetup;
pub const NoteSearchViewModel = search_view_model.NoteSearchViewModel;
pub const SearchView = search_view.SearchView;
pub const noteSearchView = search_view.noteSearchView;

test {
    std.testing.refAllDecls(@This());
    _ = @import("notes_sidebar_test.zig");
    _ = @import("search_view_test.zig");
}
