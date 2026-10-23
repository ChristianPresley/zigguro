//! GitHub Issues for the task board (E13.F03.S03): the REST client, its
//! pacing and the wire types.

pub const client = @import("client.zig");
pub const types = @import("types.zig");
pub const pacing = @import("pacing.zig");
pub const link_header = @import("link_header.zig");

pub const GitHubClient = client.GitHubClient;
pub const TokenProvider = client.TokenProvider;
pub const Repo = types.Repo;
pub const Issue = types.Issue;
pub const IssueWrite = types.IssueWrite;
pub const ListQuery = types.ListQuery;
pub const parseLinkHeader = link_header.parseLinkHeader;

test {
    _ = types;
    _ = pacing;
    _ = client;
    _ = @import("link_header_test.zig");
    _ = @import("client_test.zig");
}
