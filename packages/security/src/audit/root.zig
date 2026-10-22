//! zg_security.audit: the audit record type and the hash-chained log.

const std = @import("std");

/// One audited event.
pub const AuditRecord = @import("record.zig").AuditRecord;

test {
    std.testing.refAllDecls(@This());
}
