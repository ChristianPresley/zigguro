//! The app's startup services by phase (E14.F05.S01.T02): the
//! composition list that docs/perf/startup.md classifies. Each epic adds
//! its line here.
//!
//! Today `main` still runs the critical steps inline, in this order, and
//! the deferred services start where their owners start them; the list is
//! what the critical-path allowlist test checks. A service moves onto the
//! registry's scheduling by giving its entry an init function.

const std = @import("std");
const zg_perf = @import("zg_perf");

const InitRegistry = zg_perf.startup.InitRegistry;

/// Registers every startup service.
pub fn registerAll(r: *InitRegistry) !void {
    // Before the first frame (startup_allowlist.zon).
    try r.register(.{ .name = "runtime", .phase = .critical });
    try r.register(.{ .name = "config", .phase = .critical, .deps = &.{"runtime"} });
    try r.register(.{ .name = "fonts", .phase = .critical, .deps = &.{"runtime"} });
    try r.register(.{ .name = "platform", .phase = .critical, .deps = &.{"runtime"} });
    // GPU bring-up may overlap window creation (E02).
    try r.register(.{ .name = "gpu", .phase = .critical, .deps = &.{"platform"}, .parallel_ok = true });
    try r.register(.{ .name = "window", .phase = .critical, .deps = &.{"platform"} });
    try r.register(.{ .name = "session", .phase = .critical, .deps = &.{"config"} });
    try r.register(.{ .name = "workbench", .phase = .critical, .deps = &.{ "window", "gpu", "fonts", "session" } });

    // Right after the first presented frame, on a worker.
    try r.register(.{ .name = "font database", .phase = .after_first_frame, .priority = 5 });
    try r.register(.{ .name = "file watcher", .phase = .after_first_frame, .priority = 4 });
    try r.register(.{ .name = "indexer", .phase = .after_first_frame, .deps = &.{"file watcher"}, .priority = 3 });
    try r.register(.{ .name = "scm", .phase = .after_first_frame, .priority = 3 });
    try r.register(.{ .name = "lsp registry", .phase = .after_first_frame, .priority = 2 });
    try r.register(.{ .name = "mcp catalog", .phase = .after_first_frame, .priority = 1 });
    try r.register(.{ .name = "agent sessions", .phase = .after_first_frame, .priority = 1 });
    try r.register(.{ .name = "ca bundle", .phase = .after_first_frame });
    try r.register(.{ .name = "update check", .phase = .after_first_frame });

    // Once the UI is idle.
    try r.register(.{ .name = "trigram index", .phase = .idle, .deps = &.{"indexer"} });
    try r.register(.{ .name = "pipeline cache save", .phase = .idle });
    try r.register(.{ .name = "shader prewarm", .phase = .idle });

    // Only when asked for.
    try r.register(.{ .name = "debugger", .phase = .on_demand });
    try r.register(.{ .name = "terminal", .phase = .on_demand });
    try r.register(.{ .name = "notes graph", .phase = .on_demand });
}

test "startup allowlist: critical services match startup_allowlist.zon" {
    var r: InitRegistry = .init(std.testing.allocator, std.testing.io);
    r.dry_run = true;
    defer r.deinit();
    try registerAll(&r);
    // The phases order without cycles.
    inline for (.{ .critical, .after_first_frame, .idle, .on_demand }) |phase| {
        const ord = try r.order(std.testing.allocator, phase);
        std.testing.allocator.free(ord);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try zg_perf.startup.allowlist.compare(arena.allocator(), try r.criticalNames(arena.allocator()));
    for (m.unlisted) |n| std.debug.print("critical service \"{s}\" is not in packages/perf/startup_allowlist.zon (see docs/perf/startup.md)\n", .{n});
    for (m.missing) |n| std.debug.print("startup_allowlist.zon lists \"{s}\", which the app no longer registers\n", .{n});
    try std.testing.expect(m.ok());
    // A dry run runs nothing but still walks the critical path.
    try r.runCritical();
    try std.testing.expect(r.isDone("workbench"));
}
