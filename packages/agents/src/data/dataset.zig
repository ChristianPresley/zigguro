//! A data file opened for data mode (E13.F06.S01.T01).
//!
//! `open` maps the file read-only (or reads it when mapping fails, e.g.
//! on network filesystems), detects the encoding, sniffs the dialect from
//! the first 64 KiB and indexes the first 1 MiB of records, so the first
//! screen shows without a full scan. The full row index is built on a
//! background task; until it completes, `rowCount` is `at_least(n)` and
//! rows past the first 1 MiB read as empty (the UI jumps with
//! `seekApprox`). UTF-16 files are transcoded to UTF-8 at open; Latin-1
//! files are converted cell by cell.
//!
//! JSON and NDJSON (`json_array`, `ndjson`) arrive with E13.F06.S01.T03
//! behind the same `rowCount`/`cell` API.

const std = @import("std");
const builtin = @import("builtin");
const csv = @import("csv.zig");
const sniff_mod = @import("sniff.zig");
const encoding = @import("encoding.zig");
const row_index = @import("row_index.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RowIndex = row_index.RowIndex;

pub const Format = enum { csv, tsv, json_array, ndjson };

pub const RowCount = union(enum) {
    exact: u64,
    at_least: u64,
};

pub const first_screen_bytes = 1 << 20;

pub const Dataset = struct {
    gpa: Allocator,
    io: Io,
    format: Format,
    bytes: []const u8,
    map: ?Io.File.MemoryMap = null,
    owned: ?[]u8 = null,
    encoding: encoding.Encoding,
    sniffed: sniff_mod.SniffResult,
    dialect: csv.Dialect,
    /// Column names (from the header row, else "Column N").
    columns: []const []const u8,
    arena: std.heap.ArenaAllocator,
    /// Records in the first `first_screen_bytes`.
    head: RowIndex,
    full: RowIndex,
    indexed: std.atomic.Value(bool) = .init(false),
    progress: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    index_error: ?anyerror = null,
    task: ?Io.Future(void) = null,

    /// Opens `path` under `dir`. `hint` overrides the format guessed from
    /// the extension.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, hint: ?Format) !*Dataset {
        const format = hint orelse formatOf(path);
        if (format == .json_array or format == .ndjson) return error.Unsupported;
        const file = try dir.openFile(io, path, .{});
        defer file.close(io);
        const st = try file.stat(io);
        if (st.size > std.math.maxInt(usize)) return error.FileTooBig;
        const len: usize = @intCast(st.size);
        var map: ?Io.File.MemoryMap = null;
        var owned: ?[]u8 = null;
        var bytes: []const u8 = "";
        if (len > 0) {
            if (Io.File.MemoryMap.create(io, file, .{
                .len = len,
                .protection = .{ .read = true },
                .populate = builtin.os.tag == .windows,
            })) |mm| {
                map = mm;
                bytes = mm.memory[0..len];
            } else |_| {
                const buf = try gpa.alloc(u8, len);
                errdefer gpa.free(buf);
                const n = try file.readPositionalAll(io, buf, 0);
                owned = buf;
                bytes = buf[0..n];
            }
        }
        errdefer {
            if (map) |*m| m.destroy(io);
            if (owned) |b| gpa.free(b);
        }
        return init(gpa, io, bytes, map, owned, format);
    }

    /// A dataset over bytes the caller keeps alive.
    pub fn openBytes(gpa: Allocator, io: Io, bytes: []const u8, format: Format) !*Dataset {
        if (format == .json_array or format == .ndjson) return error.Unsupported;
        return init(gpa, io, bytes, null, null, format);
    }

    fn init(gpa: Allocator, io: Io, raw: []const u8, map: ?Io.File.MemoryMap, owned_in: ?[]u8, format: Format) !*Dataset {
        var owned = owned_in;
        const enc = encoding.detect(raw);
        var bytes = raw[encoding.bomLen(enc)..];
        if (enc == .utf16le or enc == .utf16be) {
            const utf8 = try encoding.utf16ToUtf8(gpa, bytes, enc == .utf16be);
            if (owned) |o| gpa.free(o);
            owned = utf8;
            bytes = utf8;
        }
        const ds = try gpa.create(Dataset);
        errdefer gpa.destroy(ds);
        var sniffed = sniff_mod.sniff(bytes);
        if (format == .tsv and sniffed.dialect.delimiter != '\t') {
            sniffed.dialect = .{ .delimiter = '\t', .quote = sniffed.dialect.quote, .escape = sniffed.dialect.escape };
            sniffed.confidence = 1;
        }
        ds.* = .{
            .gpa = gpa,
            .io = io,
            .format = format,
            .bytes = bytes,
            .map = map,
            .owned = owned,
            .encoding = enc,
            .sniffed = sniffed,
            .dialect = sniffed.dialect,
            .columns = &.{},
            .arena = .init(gpa),
            .head = .init(gpa),
            .full = .init(gpa),
        };
        errdefer ds.deinitParts();
        try ds.reindex(sniffed.dialect, sniffed.header);
        return ds;
    }

    fn deinitParts(ds: *Dataset) void {
        ds.head.deinit();
        ds.full.deinit();
        ds.arena.deinit();
    }

    /// Re-reads the file under another dialect or header choice (the
    /// user's override); restarts the background index.
    pub fn reindex(ds: *Dataset, d: csv.Dialect, header: bool) !void {
        ds.stopIndex();
        ds.dialect = d;
        ds.sniffed.header = header;
        _ = ds.arena.reset(.retain_capacity);
        try row_index.indexPrefix(ds.bytes, d, first_screen_bytes, &ds.head);
        ds.columns = try ds.columnNames();
        ds.full.reset();
        ds.progress.store(ds.head.count(), .release);
        ds.indexed.store(false, .release);
        ds.cancel.store(false, .release);
        ds.index_error = null;
        if (ds.bytes.len <= first_screen_bytes) {
            // The head is the whole file.
            ds.indexed.store(true, .release);
            return;
        }
        ds.task = ds.io.concurrent(indexTask, .{ds}) catch blk: {
            indexTask(ds);
            break :blk null;
        };
    }

    fn indexTask(ds: *Dataset) void {
        row_index.buildIndex(ds.io, ds.bytes, ds.dialect, &ds.full, &ds.progress, &ds.cancel) catch |e| {
            ds.index_error = e;
            return;
        };
        ds.indexed.store(true, .release);
    }

    fn stopIndex(ds: *Dataset) void {
        ds.cancel.store(true, .release);
        if (ds.task) |*t| t.await(ds.io);
        ds.task = null;
    }

    /// Waits for the background index.
    pub fn waitIndexed(ds: *Dataset) !void {
        if (ds.task) |*t| t.await(ds.io);
        ds.task = null;
        if (ds.index_error) |e| return e;
    }

    pub fn close(ds: *Dataset) void {
        ds.stopIndex();
        ds.deinitParts();
        if (ds.map) |*m| m.destroy(ds.io);
        if (ds.owned) |b| ds.gpa.free(b);
        ds.gpa.destroy(ds);
    }

    fn index(ds: *const Dataset) *const RowIndex {
        return if (ds.indexed.load(.acquire) and ds.full.complete()) &ds.full else &ds.head;
    }

    fn headerRows(ds: *const Dataset) u64 {
        return @intFromBool(ds.sniffed.header);
    }

    /// Data rows (the header row not counted).
    pub fn rowCount(ds: *const Dataset) RowCount {
        if (ds.indexed.load(.acquire)) return .{ .exact = ds.index().count() -| ds.headerRows() };
        return .{ .at_least = ds.progress.load(.acquire) -| ds.headerRows() };
    }

    pub fn columnCount(ds: *const Dataset) usize {
        return ds.columns.len;
    }

    /// The text of a cell ("" past the row's fields, or for a row not
    /// indexed yet).
    pub fn cell(ds: *const Dataset, row: u64, col: u32, arena: Allocator) ![]const u8 {
        const ix = ds.index();
        const r = row + ds.headerRows();
        if (r >= ix.count()) return "";
        return ds.cellAt(ix.offset(r), col, arena);
    }

    /// The text of field `col` of the record starting at `offset` (e.g.
    /// from `seekApprox`).
    pub fn cellAt(ds: *const Dataset, offset: u64, col: u32, arena: Allocator) ![]const u8 {
        var rd: csv.CsvReader = .initAt(ds.bytes, ds.dialect, offset);
        var fields: std.ArrayList(csv.Field) = .empty;
        _ = (try rd.nextRecord(&fields, arena)) orelse return "";
        if (col >= fields.items.len) return "";
        const t = try rd.fieldText(fields.items[col], arena);
        return if (ds.encoding == .latin1) encoding.latin1ToUtf8(arena, t) else t;
    }

    /// Whether the cell is null under the dialect's null rules.
    pub fn isNull(ds: *const Dataset, row: u64, col: u32, arena: Allocator) !bool {
        const ix = ds.index();
        const r = row + ds.headerRows();
        if (r >= ix.count()) return true;
        var rd: csv.CsvReader = .initAt(ds.bytes, ds.dialect, ix.offset(r));
        var fields: std.ArrayList(csv.Field) = .empty;
        _ = (try rd.nextRecord(&fields, arena)) orelse return true;
        return col >= fields.items.len or rd.isNull(fields.items[col]);
    }

    /// Whether the row's field count differs from the columns.
    pub fn rowShape(ds: *const Dataset, row: u64, arena: Allocator) !csv.Shape {
        const ix = ds.index();
        const r = row + ds.headerRows();
        if (r >= ix.count()) return .ok;
        var rd: csv.CsvReader = .initAt(ds.bytes, ds.dialect, ix.offset(r));
        var fields: std.ArrayList(csv.Field) = .empty;
        _ = (try rd.nextRecord(&fields, arena)) orelse return .ok;
        return csv.shape(fields.items, ds.columns.len);
    }

    /// Whether cells are converted from Latin-1 (shown to the user).
    pub fn latin1(ds: *const Dataset) bool {
        return ds.encoding == .latin1;
    }

    fn columnNames(ds: *Dataset) ![]const []const u8 {
        const a = ds.arena.allocator();
        const n: usize = @max(ds.sniffed.columns, 1);
        const names = try a.alloc([]const u8, n);
        var fields: std.ArrayList(csv.Field) = .empty;
        var rd: csv.CsvReader = .init(ds.bytes, ds.dialect);
        const has = ds.sniffed.header and (try rd.nextRecord(&fields, a)) != null;
        for (names, 0..) |*name, i| {
            name.* = if (has and i < fields.items.len) blk: {
                const t = try rd.fieldText(fields.items[i], a);
                break :blk if (ds.encoding == .latin1) try encoding.latin1ToUtf8(a, t) else t;
            } else try std.fmt.allocPrint(a, "Column {d}", .{i + 1});
        }
        return names;
    }
};

/// The format named by a file's extension (CSV when unknown).
pub fn formatOf(path: []const u8) Format {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".tsv") or std.ascii.eqlIgnoreCase(ext, ".tab")) return .tsv;
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return .json_array;
    if (std.ascii.eqlIgnoreCase(ext, ".ndjson") or std.ascii.eqlIgnoreCase(ext, ".jsonl")) return .ndjson;
    return .csv;
}
