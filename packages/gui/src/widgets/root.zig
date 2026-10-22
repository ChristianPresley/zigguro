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
/// The `quick_pick.zig` module.
pub const quick_pick = @import("quick_pick.zig");
/// The `quick_pick/matcher.zig` module.
pub const quick_pick_matcher = @import("quick_pick/matcher.zig");
/// The `quick_pick/provider.zig` module.
pub const quick_pick_provider = @import("quick_pick/provider.zig");
/// The `quick_pick/mru.zig` module.
pub const quick_pick_mru = @import("quick_pick/mru.zig");
/// The `notification_center.zig` module.
pub const notification_center = @import("notification_center.zig");
/// The `toast.zig` module.
pub const toast_mod = @import("toast.zig");
/// The `status_bar.zig` module.
pub const status_bar = @import("status_bar.zig");
/// The `tooltip.zig` module.
pub const tooltip_mod = @import("tooltip.zig");
/// The `roving.zig` module.
pub const roving = @import("roving.zig");
/// The `toolbar.zig` module.
pub const toolbar_mod = @import("toolbar.zig");
/// The `tabs.zig` module.
pub const tabs_mod = @import("tabs.zig");
/// The `breadcrumbs.zig` module.
pub const breadcrumbs_mod = @import("breadcrumbs.zig");

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
/// See `text_field.PromptHooks`.
pub const PromptHooks = text_field.PromptHooks;
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
/// See `toast.toast`.
pub const toast = toast_mod.toast;
/// See `toast.updateToast`.
pub const updateToast = toast_mod.updateToast;
/// See `toast.dismissToast`.
pub const dismissToast = toast_mod.dismissToast;
/// See `notification_center.Toast`.
pub const Toast = notification_center.Toast;
/// See `notification_center.ToastId`.
pub const ToastId = notification_center.ToastId;
/// See `notification_center.NotificationCenter`.
pub const NotificationCenter = notification_center.NotificationCenter;
/// See `status_bar.statusBar`.
pub const statusBar = status_bar.statusBar;
/// See `status_bar.StatusItem`.
pub const StatusItem = status_bar.StatusItem;
/// See `tooltip.tooltip`.
pub const tooltip = tooltip_mod.tooltip;
/// See `tooltip.tooltipLast`.
pub const tooltipLast = tooltip_mod.tooltipLast;
/// See `tabs.tabs`.
pub const tabs = tabs_mod.tabs;
/// See `tabs.Tab`.
pub const Tab = tabs_mod.Tab;
/// See `toolbar.toolbar`.
pub const toolbar = toolbar_mod.toolbar;
/// See `toolbar.ToolItem`.
pub const ToolItem = toolbar_mod.ToolItem;
/// See `breadcrumbs.breadcrumbs`.
pub const breadcrumbs = breadcrumbs_mod.breadcrumbs;
/// See `breadcrumbs.Crumb`.
pub const Crumb = breadcrumbs_mod.Crumb;
/// See `quick_pick.openQuickPick`.
pub const openQuickPick = quick_pick.openQuickPick;
/// See `quick_pick.QpItem`.
pub const QpItem = quick_pick.QpItem;
/// See `text.TextProps`.
pub const TextProps = text.TextProps;

test {
    std.testing.refAllDecls(@This());
}
