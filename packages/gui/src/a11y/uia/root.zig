//! The Windows UI Automation bridge (E04.F09.S01.T02). The COM layer
//! compiles and is tested on every OS against a fake `Api`; only
//! `Api.windows()` needs Windows.

pub const com = @import("com.zig");
pub const provider = @import("provider.zig");
pub const bridge = @import("bridge.zig");

pub const Api = com.Api;
pub const Bridge = bridge.Bridge;
pub const Element = provider.Element;
