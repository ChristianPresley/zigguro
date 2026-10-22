//! Cursor shapes. The names mirror the CSS `cursor` keywords and
//! cursor-shape-v1, so Wayland maps them 1:1, Win32 maps them to `IDC_*`
//! and X11 to Xcursor theme names.

/// A cursor shape, set per window with `Command.set_cursor`.
pub const CursorShape = enum(u8) {
    /// The platform's default arrow.
    default,
    /// I-beam for text.
    text,
    /// Pointing hand for links.
    pointer,
    /// Busy; the app does not accept input.
    wait,
    /// Busy, but the app still accepts input.
    progress,
    /// Precise selection.
    crosshair,
    /// The action is not allowed.
    not_allowed,
    /// Something can be grabbed.
    grab,
    /// Something is being dragged.
    grabbing,
    /// Something can be moved.
    move,
    /// Drop will copy.
    copy,
    /// Drop will create a link.
    alias,
    /// Dropping here is not possible.
    no_drop,
    /// Resize east-west.
    ew_resize,
    /// Resize north-south.
    ns_resize,
    /// Resize north-east to south-west.
    nesw_resize,
    /// Resize north-west to south-east.
    nwse_resize,
    /// Resize a column.
    col_resize,
    /// Resize a row.
    row_resize,
    /// Scroll in any direction.
    all_scroll,
    /// Zoom in.
    zoom_in,
    /// Zoom out.
    zoom_out,
    /// A context menu is available.
    context_menu,
    /// Help is available.
    help,
    /// Table cell selection.
    cell,
    /// Vertical text.
    vertical_text,
    /// No cursor while the pointer is over the window.
    hidden,
};
