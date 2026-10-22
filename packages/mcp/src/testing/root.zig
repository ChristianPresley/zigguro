//! Test doubles for zg_mcp and its users: a loopback HTTP server and a
//! scripted in-process MCP server.

pub const fake_http_server = @import("fake_http_server.zig");
pub const FakeHttpServer = fake_http_server.FakeHttpServer;
pub const mock_server = @import("mock_server.zig");
pub const MockServer = mock_server.MockServer;
