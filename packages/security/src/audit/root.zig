//! zg_security.audit: the audit record type and the hash-chained log.

const std = @import("std");

/// One audited event.
pub const AuditRecord = @import("record.zig").AuditRecord;

/// The hash-chained, segmented on-disk audit log.
pub const log = @import("log.zig");
pub const AuditLog = log.AuditLog;
pub const verify = log.verify;
pub const query = log.query;

test {
    std.testing.refAllDecls(@This());
}
