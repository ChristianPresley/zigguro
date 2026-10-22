//! zg_security_ui: the approval and workspace-trust dialogs over zg_gui
//! (E16 trust dialogs). A module of its own so headless consumers of
//! zg_security never import a GUI package.

const std = @import("std");

/// The `ApprovalPort` that asks in a modal dialog.
pub const approval_dialog = @import("approval_dialog.zig");
/// The workspace-trust prompt.
pub const trust_dialog = @import("trust_dialog.zig");

pub const DialogApprovalPort = approval_dialog.DialogApprovalPort;
pub const askTrust = trust_dialog.askTrust;
pub const TrustChoice = trust_dialog.TrustChoice;
pub const trustableParent = trust_dialog.trustableParent;

test {
    std.testing.refAllDecls(@This());
    _ = @import("ui_test.zig");
}
