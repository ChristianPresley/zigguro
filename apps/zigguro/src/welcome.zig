//! The first screen zigguro shows until the workbench (E04.F07) lands.

const std = @import("std");
const zg_gui = @import("zg_gui");

const Ui = zg_gui.Ui;
const w = zg_gui.w;
const themes = zg_gui.theme.theme;

/// A centred title, the version and a theme toggle.
pub const Welcome = struct {
    version: []const u8,
    dark: bool = true,
    toggles: u32 = 0,

    pub fn build(self: *Welcome, ui: *Ui) void {
        ui.open(.{ .style = .{
            .w = .{ .pct = 100 },
            .h = .{ .pct = 100 },
            .dir = .column,
            .align_items = .center,
            .justify = .center,
            .gap = 12,
            .bg = .{ .token = .bg_base },
        } });
        defer ui.close();
        ui.text("zigguro", .{ .style = .{ .size = 28 }, .theme_size = false });
        ui.textf("version {s}", .{self.version}, .{ .color = .fg_muted });
        if (w.button(ui, .{ .label = if (self.dark) "Light theme" else "Dark theme" }).clicked) {
            self.dark = !self.dark;
            self.toggles += 1;
            const app = ui.cx().app;
            app.follow_system = false;
            app.setTheme(if (self.dark) &themes.zigguro_dark else &themes.zigguro_light);
        }
    }
};
