//! The `.zgcrash` v1 binary format (normative spec: docs/format.md).
//!
//! A 32-byte `Header` followed by sections, each a 16-byte
//! `SectionHeader` plus data padded to 8 bytes. Little-endian throughout.
//! The writer streams: the header says `section_count = 0xFFFF_FFFF` and is
//! never rewritten, so a crash mid-write leaves a valid prefix. `Writer`
//! works on a caller-provided buffer and never allocates; it is safe to
//! use from a signal handler as long as the sink is.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError(".zgcrash v1 is little-endian only");
}

/// File magic.
pub const magic = "ZGCRASH\x00".*;
/// Format version.
pub const version: u16 = 1;
/// `Header.section_count` of a streamed report.
pub const streaming: u32 = 0xFFFF_FFFF;
/// Section data alignment.
pub const alignment = 8;

/// File header (32 bytes).
pub const Header = extern struct {
    magic: [8]u8,
    version: u16,
    flags: u16,
    section_count: u32,
    created_unix_ms: i64,
    reserved: u64,
};

/// Section kinds. Unknown kinds are skipped by readers.
pub const SectionKind = enum(u32) {
    meta = 1,
    exception = 2,
    context = 3,
    stack = 4,
    trace = 5,
    modules = 6,
    threads = 7,
    log = 8,
    annotations = 9,
    flight = 10,
    panic_message = 11,
    _,
};

/// Section header flag: the data was cut to fit the writer buffer.
pub const section_flag_truncated: u32 = 1;

/// Section header (16 bytes); `len` data bytes follow, then zero padding to 8.
pub const SectionHeader = extern struct {
    kind: u32,
    len: u32,
    /// CRC-32 (IEEE) of the `len` data bytes.
    crc32: u32,
    /// Bit 0: `section_flag_truncated`.
    flags: u32,
};

/// What kind of crash a report describes.
pub const ReportKind = enum(u16) {
    unknown = 0,
    segfault = 1,
    illegal_instruction = 2,
    bus_error = 3,
    arithmetic = 4,
    abort = 5,
    trap = 6,
    bad_syscall = 7,
    panic = 8,
    stack_overflow = 9,
    windows_exception = 10,
    _,
};

/// Memory access kind of a fault.
pub const Access = enum(u8) { read = 0, write = 1, exec = 8, none = 255, _ };

/// EXCEPTION section data (48 bytes).
pub const Exception = extern struct {
    kind: u16,
    reserved0: u16 = 0,
    /// Signal number or NTSTATUS.
    os_code: u32,
    si_code: i32,
    has_fault_addr: u8,
    access: u8,
    reserved1: [2]u8 = .{ 0, 0 },
    fault_addr: u64,
    thread_id: u64,
    pc: u64,
    sp: u64,
};

/// Module id kinds in MODULES entries.
pub const ModuleIdKind = enum(u8) { none = 0, gnu_build_id = 1, pdb70 = 2, _ };

/// MODULES entry header (24 bytes); followed by `id_len` id bytes and
/// `path_len` path bytes, then padding to 8. The section starts with a
/// `u32` count and 4 bytes of padding.
pub const ModuleEntryHeader = extern struct {
    base: u64,
    size: u64,
    id_kind: u8,
    id_len: u8,
    path_len: u16,
    reserved: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 32);
    std.debug.assert(@sizeOf(SectionHeader) == 16);
    std.debug.assert(@sizeOf(Exception) == 48);
    std.debug.assert(@sizeOf(ModuleEntryHeader) == 24);
}

/// Where the writer's bytes go. Both functions must be async-signal-safe
/// when used from a crash handler.
pub const RawSink = struct {
    ctx: *anyopaque,
    /// Writes all of `bytes`; false on failure (the writer then stops).
    write: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
    sync: *const fn (ctx: *anyopaque) void,
};

/// No-allocation streaming report writer.
pub const Writer = struct {
    /// Preallocated buffer (256 KiB in production). One section must fit;
    /// longer sections are cut and flagged.
    buf: []u8,
    sink: RawSink,
    end: usize = 0,
    failed: bool = false,
    /// Total bytes handed to the sink.
    written: u64 = 0,

    /// Writes the file header.
    pub fn begin(w: *Writer, created_unix_ms: i64) void {
        const h: Header = .{ .magic = magic, .version = version, .flags = 0, .section_count = streaming, .created_unix_ms = created_unix_ms, .reserved = 0 };
        w.end = 0;
        w.append(std.mem.asBytes(&h));
        w.flush();
    }

    /// Starts a section; append its data, then call `SectionBuilder.end`.
    pub fn section(w: *Writer, kind: SectionKind) SectionBuilder {
        std.debug.assert(w.buf.len >= @sizeOf(SectionHeader) + alignment);
        const start = w.end;
        const h: SectionHeader = .{ .kind = @intFromEnum(kind), .len = 0, .crc32 = 0, .flags = 0 };
        w.append(std.mem.asBytes(&h));
        return .{ .w = w, .start = start, .crc = .init() };
    }

    /// Flushes and syncs.
    pub fn finish(w: *Writer) void {
        w.flush();
        if (!w.failed) w.sink.sync(w.sink.ctx);
    }

    fn append(w: *Writer, bytes: []const u8) void {
        @memcpy(w.buf[w.end..][0..bytes.len], bytes);
        w.end += bytes.len;
    }

    fn flush(w: *Writer) void {
        if (w.end == 0) return;
        if (!w.failed) {
            if (w.sink.write(w.sink.ctx, w.buf[0..w.end])) w.written += w.end else w.failed = true;
        }
        w.end = 0;
    }

    /// Convenience: a whole section from one slice.
    pub fn writeSection(w: *Writer, kind: SectionKind, data: []const u8) void {
        var s = w.section(kind);
        s.write(data);
        s.end();
    }
};

/// Appends one section's data into the writer buffer.
pub const SectionBuilder = struct {
    w: *Writer,
    start: usize,
    len: u32 = 0,
    crc: std.hash.Crc32,
    truncated: bool = false,

    /// Space left for data in this section (keeping room for padding).
    pub fn remaining(s: *const SectionBuilder) usize {
        const cap = s.w.buf.len - alignment;
        return cap -| s.w.end;
    }

    /// Appends data; whatever does not fit is dropped and the section is
    /// flagged truncated.
    pub fn write(s: *SectionBuilder, bytes: []const u8) void {
        const n = @min(bytes.len, s.remaining());
        if (n < bytes.len) s.truncated = true;
        // Hash the copy, not the source: a crash handler copies live
        // memory (its own stack) that changes under it.
        const at = s.w.end;
        s.w.append(bytes[0..n]);
        s.crc.update(s.w.buf[at..][0..n]);
        s.len += @intCast(n);
    }

    /// Appends the bytes of `v`.
    pub fn writeStruct(s: *SectionBuilder, v: anytype) void {
        s.write(std.mem.asBytes(&v));
    }

    /// Appends a little-endian integer.
    pub fn writeInt(s: *SectionBuilder, comptime T: type, v: T) void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        s.write(&b);
    }

    /// Pads the data to `alignment` inside the section (counted in `len`).
    pub fn alignData(s: *SectionBuilder) void {
        const pad = (alignment - s.len % alignment) % alignment;
        s.write(("\x00" ** alignment)[0..pad]);
    }

    /// Patches the header, pads to 8 and flushes the section.
    pub fn end(s: *SectionBuilder) void {
        const h: *align(1) SectionHeader = @ptrCast(s.w.buf[s.start..][0..@sizeOf(SectionHeader)]);
        h.len = s.len;
        h.crc32 = s.crc.final();
        h.flags = if (s.truncated) section_flag_truncated else 0;
        const pad = (alignment - s.len % alignment) % alignment;
        @memset(s.w.buf[s.w.end..][0..pad], 0);
        s.w.end += pad;
        s.w.flush();
    }
};

/// One parsed section.
pub const Section = struct {
    kind: SectionKind,
    data: []const u8,
    /// The writer cut the data to fit its buffer.
    cut: bool,
};

/// Tolerant reader: stops at EOF, a short section or a CRC mismatch.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize,
    header: Header,
    /// Set when iteration stopped before a clean end of file.
    truncated: bool = false,

    /// Validates the file header.
    pub fn init(bytes: []const u8) error{ BadMagic, UnsupportedVersion }!Reader {
        if (bytes.len < @sizeOf(Header)) return error.BadMagic;
        var h: Header = undefined;
        @memcpy(std.mem.asBytes(&h), bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &h.magic, &magic)) return error.BadMagic;
        if (h.version != version) return error.UnsupportedVersion;
        return .{ .bytes = bytes, .pos = @sizeOf(Header), .header = h };
    }

    /// The next intact section, or null.
    pub fn next(r: *Reader) ?Section {
        if (r.pos == r.bytes.len) return null;
        if (r.bytes.len - r.pos < @sizeOf(SectionHeader)) {
            r.truncated = true;
            r.pos = r.bytes.len;
            return null;
        }
        var h: SectionHeader = undefined;
        @memcpy(std.mem.asBytes(&h), r.bytes[r.pos..][0..@sizeOf(SectionHeader)]);
        const data_at = r.pos + @sizeOf(SectionHeader);
        if (r.bytes.len - data_at < h.len) {
            r.truncated = true;
            r.pos = r.bytes.len;
            return null;
        }
        const data = r.bytes[data_at..][0..h.len];
        if (std.hash.Crc32.hash(data) != h.crc32) {
            r.truncated = true;
            r.pos = r.bytes.len;
            return null;
        }
        const padded = h.len + (alignment - h.len % alignment) % alignment;
        r.pos = @min(r.bytes.len, data_at + padded);
        return .{ .kind = @enumFromInt(h.kind), .data = data, .cut = h.flags & section_flag_truncated != 0 };
    }

    /// The first section of `kind`, scanning from the start.
    pub fn find(bytes: []const u8, kind: SectionKind) ?Section {
        var r = Reader.init(bytes) catch return null;
        while (r.next()) |s| if (s.kind == kind) return s;
        return null;
    }
};

/// Decodes an EXCEPTION section.
pub fn decodeException(data: []const u8) ?Exception {
    if (data.len < @sizeOf(Exception)) return null;
    var e: Exception = undefined;
    @memcpy(std.mem.asBytes(&e), data[0..@sizeOf(Exception)]);
    return e;
}

/// A decoded TRACE section: `count: u32`, 4 padding bytes, `count` u64
/// return addresses (innermost first), then `skipped: u64`.
pub const Trace = struct {
    data: []const u8,
    count: u32,
    skipped: u64,

    /// Return address `i`.
    pub fn at(t: Trace, i: usize) u64 {
        return std.mem.readInt(u64, t.data[8 + i * 8 ..][0..8], .little);
    }
};

/// Decodes a TRACE section.
pub fn decodeTrace(data: []const u8) ?Trace {
    if (data.len < 16) return null;
    const count = std.mem.readInt(u32, data[0..4], .little);
    if ((data.len - 16) / 8 < count) return null;
    return .{ .data = data, .count = count, .skipped = std.mem.readInt(u64, data[8 + count * 8 ..][0..8], .little) };
}

/// Writes a TRACE section.
pub fn writeTrace(w: *Writer, addrs: []const usize, skipped: u64) void {
    var s = w.section(.trace);
    s.writeInt(u32, @intCast(addrs.len));
    s.writeInt(u32, 0);
    for (addrs) |a| s.writeInt(u64, a);
    s.writeInt(u64, skipped);
    s.end();
}

/// A decoded module.
pub const Module = struct {
    base: u64,
    size: u64,
    id_kind: ModuleIdKind,
    id: []const u8,
    path: []const u8,
};

/// Iterates a MODULES section.
pub const ModuleIterator = struct {
    data: []const u8,
    pos: usize = 8,
    left: u32,

    /// Starts iterating `data`.
    pub fn init(data: []const u8) ModuleIterator {
        if (data.len < 8) return .{ .data = data, .left = 0 };
        return .{ .data = data, .left = std.mem.readInt(u32, data[0..4], .little) };
    }

    /// The next module, or null at the end or on malformed data.
    pub fn next(it: *ModuleIterator) ?Module {
        if (it.left == 0 or it.data.len - it.pos < @sizeOf(ModuleEntryHeader)) return null;
        var h: ModuleEntryHeader = undefined;
        @memcpy(std.mem.asBytes(&h), it.data[it.pos..][0..@sizeOf(ModuleEntryHeader)]);
        const body = it.pos + @sizeOf(ModuleEntryHeader);
        const n = @as(usize, h.id_len) + h.path_len;
        if (it.data.len - body < n) return null;
        const m: Module = .{
            .base = h.base,
            .size = h.size,
            .id_kind = @enumFromInt(h.id_kind),
            .id = it.data[body..][0..h.id_len],
            .path = it.data[body + h.id_len ..][0..h.path_len],
        };
        it.pos = body + n + (alignment - n % alignment) % alignment;
        it.left -= 1;
        return m;
    }
};

/// Appends one MODULES entry (after the leading count written by the caller).
pub fn writeModule(s: *SectionBuilder, m: Module) void {
    s.writeStruct(ModuleEntryHeader{
        .base = m.base,
        .size = m.size,
        .id_kind = @intFromEnum(m.id_kind),
        .id_len = @intCast(m.id.len),
        .path_len = @intCast(m.path.len),
    });
    s.write(m.id);
    s.write(m.path);
    s.alignData();
}

const testing = std.testing;

/// Sink that appends into a fixed test buffer.
pub const MemorySink = struct {
    buf: []u8,
    len: usize = 0,
    syncs: u32 = 0,

    /// The sink interface.
    pub fn sink(m: *MemorySink) RawSink {
        return .{ .ctx = m, .write = write, .sync = sync };
    }

    /// Bytes written so far.
    pub fn bytes(m: *const MemorySink) []const u8 {
        return m.buf[0..m.len];
    }

    fn write(ctx: *anyopaque, b: []const u8) bool {
        const m: *MemorySink = @ptrCast(@alignCast(ctx));
        if (m.buf.len - m.len < b.len) return false;
        @memcpy(m.buf[m.len..][0..b.len], b);
        m.len += b.len;
        return true;
    }

    fn sync(ctx: *anyopaque) void {
        const m: *MemorySink = @ptrCast(@alignCast(ctx));
        m.syncs += 1;
    }
};

fn sampleReport(out: []u8, wbuf: []u8) []const u8 {
    var ms: MemorySink = .{ .buf = out };
    var w: Writer = .{ .buf = wbuf, .sink = ms.sink() };
    w.begin(1761016620123);
    w.writeSection(.meta, ".{ .product = \"dev.zigguro.zigguro\", .version = \"0.4.0\" }");
    var e = w.section(.exception);
    e.writeStruct(Exception{ .kind = @intFromEnum(ReportKind.segfault), .os_code = 11, .si_code = 1, .has_fault_addr = 1, .access = 1, .fault_addr = 0, .thread_id = 42, .pc = 0x401000, .sp = 0x7ffe0000 });
    e.end();
    writeTrace(&w, &.{ 0x401000, 0x401234, 0x402000 }, 0);
    var m = w.section(.modules);
    m.writeInt(u32, 2);
    m.writeInt(u32, 0);
    writeModule(&m, .{ .base = 0x400000, .size = 0x10000, .id_kind = .gnu_build_id, .id = &.{ 1, 2, 3, 4, 5 }, .path = "/opt/zigguro/zigguro" });
    writeModule(&m, .{ .base = 0x7fff0000, .size = 0x2000, .id_kind = .none, .id = "", .path = "[vdso]" });
    m.end();
    var big = w.section(.log);
    for (0..400) |i| {
        var line: [64]u8 = undefined;
        big.write(std.fmt.bufPrint(&line, "{d} info app: line {d}\n", .{ 1761016620 + i, i }) catch unreachable);
    }
    big.end();
    w.writeSection(.panic_message, "integer overflow");
    w.finish();
    return ms.bytes();
}

test "format: writer→reader roundtrip all sections" {
    var out: [64 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    const bytes = sampleReport(&out, &wbuf);
    var r = try Reader.init(bytes);
    try testing.expectEqual(@as(i64, 1761016620123), r.header.created_unix_ms);
    try testing.expectEqual(streaming, r.header.section_count);
    const kinds = [_]SectionKind{ .meta, .exception, .trace, .modules, .log, .panic_message };
    for (kinds) |k| {
        const s = r.next().?;
        try testing.expectEqual(k, s.kind);
        try testing.expect(!s.cut);
        switch (k) {
            .exception => try testing.expectEqual(@as(u64, 0x401000), decodeException(s.data).?.pc),
            .trace => {
                const t = decodeTrace(s.data).?;
                try testing.expectEqual(@as(u32, 3), t.count);
                try testing.expectEqual(@as(u64, 0x401234), t.at(1));
            },
            .modules => {
                var it: ModuleIterator = .init(s.data);
                const m0 = it.next().?;
                try testing.expectEqualStrings("/opt/zigguro/zigguro", m0.path);
                try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, m0.id);
                try testing.expectEqualStrings("[vdso]", it.next().?.path);
                try testing.expect(it.next() == null);
            },
            .panic_message => try testing.expectEqualStrings("integer overflow", s.data),
            else => {},
        }
    }
    try testing.expect(r.next() == null);
    try testing.expect(!r.truncated);
}

test "format: truncated at every byte offset yields a valid prefix" {
    var out: [64 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    const bytes = sampleReport(&out, &wbuf);
    try testing.expect(bytes.len > 10_000);
    var full: usize = 0;
    var rf = try Reader.init(bytes);
    while (rf.next()) |_| full += 1;
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        var r = Reader.init(bytes[0..cut]) catch {
            try testing.expect(cut < @sizeOf(Header));
            continue;
        };
        var n: usize = 0;
        while (r.next()) |_| n += 1;
        try testing.expect(n <= full);
    }
}

test "format: crc mismatch stops iteration and sets truncated" {
    var out: [64 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    const bytes = sampleReport(&out, &wbuf);
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    copy[@sizeOf(Header) + @sizeOf(SectionHeader) + 2] ^= 0xff; // inside META data
    var r = try Reader.init(copy);
    try testing.expect(r.next() == null);
    try testing.expect(r.truncated);
    try testing.expectError(error.BadMagic, Reader.init("ZGCRASX\x00" ++ "\x00" ** 24));
    var v2 = try testing.allocator.dupe(u8, bytes[0..32]);
    defer testing.allocator.free(v2);
    v2[8] = 2;
    try testing.expectError(error.UnsupportedVersion, Reader.init(v2));
}

test "format: writer never allocates (1 KiB buffer, many flushes)" {
    var out: [64 * 1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    const bytes = sampleReport(&out, &wbuf);
    var r = try Reader.init(bytes);
    var saw_cut = false;
    var n: usize = 0;
    while (r.next()) |s| : (n += 1) {
        if (s.kind == .log) saw_cut = s.cut;
    }
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expect(saw_cut);
}

test "fuzz: zgcrash Reader on arbitrary bytes" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var input: [4096]u8 = undefined;
            const n = s.slice(&input);
            var r = Reader.init(input[0..n]) catch return;
            while (r.next()) |sec| switch (sec.kind) {
                .exception => _ = decodeException(sec.data),
                .trace => if (decodeTrace(sec.data)) |t| {
                    for (0..t.count) |i| _ = t.at(i);
                },
                .modules => {
                    var it: ModuleIterator = .init(sec.data);
                    while (it.next()) |_| {}
                },
                else => {},
            };
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "zgcrash_reader") });
}
