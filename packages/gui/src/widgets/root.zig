//! Widgets (E04.F05).

const std = @import("std");

/// The `box.zig` module.
pub const box = @import("box.zig");
/// The `text.zig` module.
pub const text = @import("text.zig");
/// The `controls.zig` module.
pub const controls = @import("controls.zig");
/// The `scroll.zig` module.
pub const scroll = @import("scroll.zig");
/// The `height_index.zig` module.
pub const height_index = @import("height_index.zig");
/// The `text_field/` modules.
pub const text_field = @import("text_field/root.zig");
/// The `overlay.zig` module.
pub const overlay = @import("overlay.zig");
/// The `dialog.zig` module.
pub const dialog = @import("dialog.zig");
/// The `menu.zig` module.
pub const menu = @import("menu.zig");
/// The `menu_aim.zig` module.
pub const menu_aim = @import("menu_aim.zig");
/// The `menubar.zig` module.
pub const menubar_mod = @import("menubar.zig");

/// See `controls.button`.
pub const button = controls.button;
/// See `controls.checkbox`.
pub const checkbox = controls.checkbox;
/// See `controls.toggle`.
pub const toggle = controls.toggle;
/// See `controls.separator`.
pub const separator = controls.separator;
/// See `controls.progress`.
pub const progress = controls.progress;
/// See `controls.badge`.
pub const badge = controls.badge;
/// See `controls.spacer`.
pub const spacer = controls.spacer;
/// See `scroll.scrollArea`.
pub const scrollArea = scroll.scrollArea;
/// See `scroll.virtualList`.
pub const virtualList = scroll.virtualList;
/// See `height_index.HeightIndex`.
pub const HeightIndex = height_index.HeightIndex;
/// See `text_field.textField`.
pub const textField = text_field.textField;
/// See `text_field.TextField`.
pub const TextField = text_field.TextField;
/// See `text_field.TextBuffer`.
pub const TextBuffer = text_field.TextBuffer;
/// See `overlay.popover`.
pub const popover = overlay.popover;
/// See `dialog.dialog`.
pub const modalDialog = dialog.dialog;
/// See `dialog.confirm`.
pub const confirm = dialog.confirm;
/// See `menu.MenuItem`.
pub const MenuItem = menu.MenuItem;
/// See `menu.openMenu`.
pub const openMenu = menu.openMenu;
/// See `menu.contextMenu`.
pub const contextMenu = menu.contextMenu;
/// See `menu.menuButton`.
pub const menuButton = menu.menuButton;
/// See `menubar.menubar`.
pub const menubar = menubar_mod.menubar;
/// See `text.TextProps`.
pub const TextProps = text.TextProps;

test {
    std.testing.refAllDecls(@This());
}
