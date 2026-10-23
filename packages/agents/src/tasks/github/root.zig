//! GitHub Issues for the task board (E13.F03.S03): the REST client, its
//! pacing and wire types, and the two-way sync engine.

pub const client = @import("client.zig");
pub const types = @import("types.zig");
pub const pacing = @import("pacing.zig");
pub const link_header = @import("link_header.zig");
pub const map = @import("map.zig");
pub const state = @import("state.zig");
pub const sync = @import("sync.zig");
/// An in-memory GitHub issues API (tests of the sync and its callers).
pub const fake = @import("fake_github.zig");

pub const GitHubClient = client.GitHubClient;
pub const TokenProvider = client.TokenProvider;
pub const Repo = types.Repo;
pub const Issue = types.Issue;
pub const IssueWrite = types.IssueWrite;
pub const ListQuery = types.ListQuery;
pub const parseLinkHeader = link_header.parseLinkHeader;
pub const SyncEngine = sync.SyncEngine;
pub const SyncConfig = sync.SyncConfig;
pub const SyncReport = sync.SyncReport;
pub const ConflictPort = sync.ConflictPort;

test {
    _ = types;
    _ = pacing;
    _ = client;
    _ = @import("link_header_test.zig");
    _ = @import("client_test.zig");
    _ = @import("map_test.zig");
    _ = @import("sync_test.zig");
}
