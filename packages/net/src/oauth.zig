//! OAuth 2.1 for native apps: PKCE, the loopback redirect, discovery and
//! the token lifecycle used by MCP (E11) and OAuth-protected providers.

const std = @import("std");

pub const pkce = @import("oauth/pkce.zig");
pub const loopback = @import("oauth/loopback.zig");
pub const flow = @import("oauth/flow.zig");
pub const discovery = @import("oauth/discovery.zig");
pub const token_store = @import("oauth/token_store.zig");
pub const session = @import("oauth/session.zig");

pub const Pkce = pkce.Pkce;
pub const Loopback = loopback.Loopback;
pub const Callback = loopback.Callback;
pub const AuthRequest = flow.AuthRequest;
pub const TokenSet = flow.TokenSet;
pub const OpenUrlFn = flow.OpenUrlFn;
pub const buildAuthorizationUrl = flow.buildAuthorizationUrl;
pub const exchangeCode = flow.exchangeCode;
pub const ProtectedResourceMetadata = discovery.ProtectedResourceMetadata;
pub const AuthServerMetadata = discovery.AuthServerMetadata;
pub const parseWwwAuthenticate = discovery.parseWwwAuthenticate;
pub const fetchProtectedResourceMetadata = discovery.fetchProtectedResourceMetadata;
pub const fetchAuthServerMetadata = discovery.fetchAuthServerMetadata;
pub const TokenStore = token_store.TokenStore;
pub const MemoryTokenStore = token_store.MemoryTokenStore;
pub const Session = session.Session;
pub const ClientRegistration = session.ClientRegistration;

test {
    std.testing.refAllDecls(@This());
}
