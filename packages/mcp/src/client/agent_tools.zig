//! A connected MCP server's tools, exported to the agent (E10.F06.S03.T01,
//! E11 side): the catalog's tools become `ForeignTool`s and agent calls
//! become `tools/call`.
//!
//! zg_mcp and zg_ai share a layer, so the exporter is generic over zg_ai's
//! foreign-tool contract; the app instantiates it with
//! `zg_ai.tools.adapters.foreign` and registers it through
//! `Adapters.registerAll` (`Services.mcp`):
//!
//! ```zig
//! const X = zg_mcp.client.agent_tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! var x: X = undefined;
//! x.init(gpa, io, "github", .{ .trusted = false });
//! const c = try zg_mcp.client.Client.connect(rt, gpa, factory, .{ ..., .on_notification = x.notificationHandler() });
//! x.attach(c);
//! services.mcp = &.{x.exporter()};
//! ```
//!
//! The registry namespaces the names (`mcp__github__create_issue`).
//! Annotations count only for servers the user trusts (zg_ai decides).
//! A server error comes back as an `isError` result naming the code, so
//! the model can correct itself; a header mismatch or unknown tool also
//! invalidates the catalog, so the next listing is current. Listing and
//! calling block on the network: call them off the UI thread.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");
const headers = @import("../transport/headers.zig");
const Client = @import("Client.zig");
const catalog = @import("catalog.zig");

const M = protocol.messages;

pub const Options = struct {
    /// The user trusts this server's annotations (E11 config).
    trusted: bool = false,
    /// Catalog options before `attach` reads the client's.
    catalog: catalog.Options = .{},
};

/// The exporter for one server. `Foreign` is `zg_ai.tools.adapters.foreign`
/// (it provides `Exporter`, `ForeignTool`, `Annotations`, `Result` and
/// `ChangedCb`). Must not move after `init`.
pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        io: Io,
        name: []const u8,
        opts: Options,
        fetcher: catalog.ClientFetcher = undefined,
        store: catalog.CatalogStore,
        client: ?*Client = null,
        mutex: Io.Mutex = .init,
        changed: std.ArrayList(Foreign.ChangedCb) = .empty,

        /// `name` is the configured server name; it must outlive `self`.
        pub fn init(self: *Self, gpa: Allocator, io: Io, name: []const u8, opts: Options) void {
            self.* = .{
                .gpa = gpa,
                .io = io,
                .name = name,
                .opts = opts,
                .store = undefined,
            };
            self.store = .init(gpa, io, .{ .ctx = self, .fetch = fetch }, opts.catalog);
            self.store.onChange(.{ .ctx = self, .func = onCatalogChange }) catch {};
        }

        pub fn deinit(self: *Self) void {
            self.store.deinit();
            self.changed.deinit(self.gpa);
        }

        /// Pass to `Client.Options.on_notification`: `list_changed`
        /// refreshes the catalog.
        pub fn notificationHandler(self: *Self) Client.NotificationHandler {
            return .{ .ctx = self, .func = onNotification };
        }

        /// Binds the connected client (after `Client.connect`).
        pub fn attach(self: *Self, c: *Client) void {
            self.fetcher = .{ .client = c };
            self.store.opts = catalog.Options.forClient(c);
            self.store.opts.max_pages = self.opts.catalog.max_pages;
            self.store.opts.max_entries = self.opts.catalog.max_entries;
            self.store.opts.heuristic_ttl_ms = self.opts.catalog.heuristic_ttl_ms;
            self.client = c;
            self.store.invalidateAll();
        }

        /// The contract object for `Adapters.registerAll`.
        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{
                .name = self.name,
                .kind = .mcp,
                .trusted = self.opts.trusted,
                .ctx = self,
                .list = list,
                .call = call,
                .subscribe_changed = subscribe,
            };
        }

        fn fetch(ctx: ?*anyopaque, arena: Allocator, kind: catalog.CatalogKind, cursor: ?[]const u8) catalog.FetchError!catalog.Page {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.client == null) return error.Failed;
            const f = self.fetcher.fetcher();
            return f.fetch(f.ctx, arena, kind, cursor);
        }

        fn onNotification(ctx: ?*anyopaque, n: protocol.Notification) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.store.onNotification(n);
        }

        fn onCatalogChange(ctx: ?*anyopaque, d: catalog.Delta, _: *catalog.Catalog) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (d.kind != .tools) return;
            self.mutex.lockUncancelable(self.io);
            const cbs = self.gpa.dupe(Foreign.ChangedCb, self.changed.items) catch {
                self.mutex.unlock(self.io);
                return;
            };
            self.mutex.unlock(self.io);
            defer self.gpa.free(cbs);
            for (cbs) |cb| cb.changed(cb.ctx);
        }

        fn subscribe(ctx: *anyopaque, cb: Foreign.ChangedCb) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.changed.append(self.gpa, cb) catch {};
        }

        fn list(ctx: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const cat = try self.store.get(.tools);
            defer cat.release();
            const out = try arena.alloc(Foreign.ForeignTool, cat.entries.len);
            for (cat.entries, out) |e, *t| {
                const d = e.def;
                t.* = .{
                    .name = try arena.dupe(u8, d.name),
                    .description = try arena.dupe(u8, d.description orelse d.title orelse ""),
                    .input_schema_json = try std.json.Stringify.valueAlloc(arena, d.input_schema, .{}),
                };
                if (d.annotations) |n| t.annotations = .{
                    .title = if (n.title) |x| try arena.dupe(u8, x) else null,
                    .read_only_hint = n.read_only_hint,
                    .destructive_hint = n.destructive_hint,
                    .idempotent_hint = n.idempotent_hint,
                    .open_world_hint = n.open_world_hint,
                };
            }
            return out;
        }

        fn call(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            _ = io;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const c = self.client orelse return error.NotConnected;
            const args = try protocol.codec.parseValue(arena, input_json);
            // HTTP transports send `x-mcp-header` arguments as headers too.
            var param_headers: []const headers.ParamHeader = &.{};
            if (self.store.acquire(.tools)) |cat| {
                defer cat.release();
                if (cat.find(tool)) |e| if (e.x_mcp_headers.entries.len > 0) {
                    param_headers = headers.paramHeadersFor(arena, &e.x_mcp_headers, args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return .{ .json = try errorResult(arena, "The arguments do not match the tool's header parameters ({s}).", .{@errorName(err)}) },
                    };
                };
            }
            var info: Client.ErrorInfo = .{};
            const r = c.request(.tools_call, .{ .name = tool, .arguments = args }, .{
                .arena = arena,
                .param_headers = param_headers,
                .error_info = &info,
            }) catch |err| {
                self.store.noteCallError(err, &info);
                return switch (err) {
                    error.OutOfMemory, error.Canceled, error.Timeout => err,
                    error.ServerError => .{ .json = try errorResult(arena, "MCP server {s} returned error {d}: {s}", .{ self.name, info.code orelse 0, info.message }) },
                    error.InputDeclined => .{ .json = try errorResult(arena, "MCP server {s} asked for user input, which this session cannot give.", .{self.name}) },
                    error.MissingRequiredClientCapability => .{ .json = try errorResult(arena, "MCP server {s} needs a client capability zigguro did not declare.", .{self.name}) },
                    else => err,
                };
            };
            return .{ .json = try protocol.codec.encodeAlloc(arena, r) };
        }

        fn errorResult(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
            const text = try std.fmt.allocPrint(arena, fmt, args);
            const blocks = try arena.alloc(protocol.ContentBlock, 1);
            blocks[0] = .textBlock(text);
            const r: M.CallToolResult = .{ .content = blocks, .is_error = true };
            return protocol.codec.encodeAlloc(arena, r);
        }
    };
}
