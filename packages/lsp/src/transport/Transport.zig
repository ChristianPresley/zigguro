//! A byte transport for one protocol connection: a buffered reader and
//! writer plus a way to end it. `zg_jsonrpc.Endpoint` (LSP) and the DAP
//! connection sit on top; `zg_dap` reuses these through `zg_lsp.transport`.
//!
//! Implementations embed a `Transport` and recover themselves with
//! `@fieldParentPtr`.
//!
//! - `close` ends the outgoing direction so the peer sees end of input
//!   (stdio: closes the child's stdin; TCP: shuts the socket down, which
//!   also wakes a blocked reader). Idempotent; any thread.
//! - `deinit` releases everything; call it once nothing uses `reader` or
//!   `writer` any more.

const Transport = @This();
const std = @import("std");

reader: *std.Io.Reader,
writer: *std.Io.Writer,
vtable: *const VTable,

pub const VTable = struct {
    close: *const fn (t: *Transport) void,
    deinit: *const fn (t: *Transport) void,
};

/// Read and write buffer size of the built-in transports.
pub const buffer_size = 64 << 10;

/// Ends the outgoing direction.
pub fn close(t: *Transport) void {
    t.vtable.close(t);
}

/// Releases the transport.
pub fn deinit(t: *Transport) void {
    t.vtable.deinit(t);
}
