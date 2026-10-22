//! zg_update: auto-update client (E17.F04).
//!
//! - `manifest`: update manifest schema v1 and its strict parser.
//! - `verify`: the client acceptance rules 1-9 (`decide`).
//! - `state`: persisted updater state (`update.*`).
//! - `layout`: the install root's directories and the install kinds.
//! - `schedule`: when to check (first check, interval, jitter, backoff).
//! - `fetch`: manifest and signature from the feed URLs.
//! - `download`: resumable, size- and hash-checked artifact download.
//! - `stage`: extraction and checks into `<root>/staged/`.
//! - `disk`: free space on the install volume.
//! - `updater`: the pipeline (`Updater`), its `Status` and schedule loop.

const std = @import("std");

/// Update manifest schema v1.
pub const manifest = @import("manifest.zig");
/// Client acceptance rules.
pub const verify = @import("verify.zig");
/// Persisted updater state.
pub const state = @import("state.zig");
/// Install layout and kinds.
pub const layout = @import("layout.zig");
/// Check scheduling.
pub const schedule = @import("schedule.zig");
/// Feed fetching.
pub const fetch = @import("fetch.zig");
/// Artifact download.
pub const download = @import("download.zig");
/// Extraction into `staged/`.
pub const stage = @import("stage.zig");
/// Free disk space.
pub const disk = @import("disk.zig");
/// The update pipeline and its status.
pub const updater = @import("updater.zig");
pub const Updater = updater.Updater;
pub const Status = updater.Status;

test {
    std.testing.refAllDecls(@This());
    _ = manifest;
    _ = verify;
    _ = state;
    _ = layout;
    _ = schedule;
    _ = fetch;
    _ = download;
    _ = stage;
    _ = disk;
    _ = updater;
}
