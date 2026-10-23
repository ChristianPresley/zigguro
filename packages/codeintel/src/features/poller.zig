//! The request loop shared by whole-document feature drivers (folding
//! ranges, document links): per tracked document, ask the first server
//! routed for `feature` again `debounce` after each edit, on refresh, and
//! when the serving server changes; hand results back on the UI thread.
//!
//! A result computed for an older document version is dropped and asked
//! again (positions would need mapping); ContentModified is retried once;
//! an error clears the document's results until the next edit or refresh.
//! Responses arrive on reader threads and wait in an inbox until `tick`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");

const Client = zg_lsp.client.Client;
const Server = Manager.Server;
const DocHandle = zg_editor.model.api.registry.DocHandle;

const log = std.log.scoped(.codeintel);

/// What the driver does with results.
pub fn Hooks(comptime M: zg_lsp.protocol.Method) type {
    return struct {
        ctx: *anyopaque,
        /// A successful result for the document's current version; true
        /// when what the editor shows changed.
        apply: *const fn (ctx: *anyopaque, h: DocHandle, client: *Client, value: zg_lsp.protocol.RequestInfo(M).Result) bool,
        /// The document lost its server (or failed): drop its results and
        /// let the editor fall back.
        clear: *const fn (ctx: *anyopaque, h: DocHandle) void,
    };
}

pub fn Poller(comptime M: zg_lsp.protocol.Method, comptime feature: Manager.Feature) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            debounce: Io.Duration = .fromMilliseconds(300),
            waker: zg_core.runtime.Waker = .noop,
        };

        const State = struct {
            server: ?*Server = null,
            client: ?*Client = null,
            inflight: ?*Pending = null,
            applied: ?u64 = null,
            seen: u64 = 0,
            due_ns: i96 = 0,
            force: bool = false,
            retried: bool = false,
        };

        const Pending = struct {
            p: *Self,
            h: DocHandle,
            client: *Client,
            version: u64,
            result: Client.Result(M) = undefined,
        };

        gpa: Allocator,
        io: Io,
        mgr: *Manager,
        hooks: Hooks(M),
        opts: Options,
        states: std.AutoArrayHashMapUnmanaged(DocHandle, State) = .empty,
        inbox_mutex: Io.Mutex = .init,
        inbox: std.ArrayList(*Pending) = .empty,
        taken: std.ArrayList(*Pending) = .empty,
        outstanding: usize = 0,
        /// Requests sent (tests, status).
        sent: u32 = 0,

        pub fn init(mgr: *Manager, hooks: Hooks(M), opts: Options) Self {
            return .{ .gpa = mgr.gpa, .io = mgr.rt.io, .mgr = mgr, .hooks = hooks, .opts = opts };
        }

        /// Call after `Manager.deinit`, which answers every request still
        /// in flight.
        pub fn deinit(p: *Self) void {
            for (p.takeInbox()) |x| p.drop(x);
            std.debug.assert(p.outstanding == 0);
            p.taken.deinit(p.gpa);
            p.inbox.deinit(p.gpa);
            p.states.deinit(p.gpa);
        }

        pub fn track(p: *Self, h: DocHandle) Allocator.Error!void {
            const gop = try p.states.getOrPut(p.gpa, h);
            if (!gop.found_existing) gop.value_ptr.* = .{};
        }

        pub fn untrack(p: *Self, h: DocHandle) void {
            _ = p.states.swapRemove(h);
        }

        pub fn isTracked(p: *const Self, h: DocHandle) bool {
            return p.states.contains(h);
        }

        /// Asks every tracked document again.
        pub fn refresh(p: *Self) void {
            for (p.states.values()) |*st| st.force = true;
        }

        /// Applies results and sends due requests; true when anything
        /// shown changed.
        pub fn tick(p: *Self) bool {
            var changed = false;
            for (p.takeInbox()) |x| {
                defer p.drop(x);
                const st = p.states.getPtr(x.h) orelse continue;
                if (st.inflight != x) continue;
                st.inflight = null;
                if (p.handle(x, st)) changed = true;
            }
            p.taken.clearRetainingCapacity();
            const now = Io.Clock.Timestamp.now(p.io, .awake).raw.nanoseconds;
            for (p.states.keys(), p.states.values()) |h, *st| p.maybeRequest(h, st, now);
            return changed;
        }

        /// The earliest debounced request (`.awake` nanoseconds), if any.
        pub fn nextDue(p: *const Self) ?i96 {
            var best: ?i96 = null;
            for (p.states.values()) |st| {
                if (st.server == null or st.inflight != null) continue;
                if (!st.force and st.applied == st.seen) continue;
                best = if (best) |b| @min(b, st.due_ns) else st.due_ns;
            }
            return best;
        }

        fn handle(p: *Self, x: *Pending, st: *State) bool {
            switch (x.result) {
                .ok => |o| {
                    if (st.client != x.client) return false;
                    const doc = p.mgr.docs.get(x.h) orelse return false;
                    if (doc.version != x.version) {
                        st.force = true;
                        return false;
                    }
                    st.applied = x.version;
                    st.retried = false;
                    return p.hooks.apply(p.hooks.ctx, x.h, x.client, o.value);
                },
                .content_modified => if (!st.retried) {
                    st.retried = true;
                    st.force = true;
                },
                // The server cannot answer for this version: fall back
                // until the next edit or refresh.
                .lsp_error, .unsupported, .timeout => {
                    st.applied = x.version;
                    p.hooks.clear(p.hooks.ctx, x.h);
                    return true;
                },
                .canceled, .server_gone => {},
            }
            return false;
        }

        fn maybeRequest(p: *Self, h: DocHandle, st: *State, now: i96) void {
            const doc = p.mgr.docs.get(h) orelse return;
            var servers: [1]*Server = undefined;
            if (p.mgr.serversFor(h, feature, &servers) == 0) {
                if (st.server != null) {
                    p.hooks.clear(p.hooks.ctx, h);
                    st.* = .{};
                }
                return;
            }
            const s = servers[0];
            if (st.server != s or st.client != s.client) {
                if (st.server != null) p.hooks.clear(p.hooks.ctx, h);
                st.server = s;
                st.client = s.client;
                st.applied = null;
                st.force = true;
            }
            if (st.inflight != null) return;
            const ver = doc.version;
            if (ver != st.seen) {
                st.seen = ver;
                st.due_ns = if (st.applied == null) now else now + p.opts.debounce.nanoseconds;
            }
            if (!st.force and st.applied == ver) return;
            if (now < st.due_ns) return;
            p.send(h, st, s.client.?, ver) catch |err| log.debug("{s}: {t}", .{ @tagName(feature), err });
        }

        fn send(p: *Self, h: DocHandle, st: *State, c: *Client, ver: u64) !void {
            const uri = p.mgr.docs.uri(h) orelse return;
            const x = try p.gpa.create(Pending);
            errdefer p.gpa.destroy(x);
            x.* = .{ .p = p, .h = h, .client = c, .version = ver };
            st.inflight = x;
            errdefer st.inflight = null;
            _ = try c.request(M, .{ .textDocument = .{ .uri = uri } }, .{ .doc = p.mgr.docMatch(h) }, .{ .ctx = x, .func = onResult });
            p.outstanding += 1;
            p.sent += 1;
            st.force = false;
        }

        fn onResult(ctx: ?*anyopaque, r: Client.Result(M)) void {
            const x: *Pending = @ptrCast(@alignCast(ctx.?));
            x.result = r;
            const p = x.p;
            {
                p.inbox_mutex.lockUncancelable(p.io);
                defer p.inbox_mutex.unlock(p.io);
                p.inbox.append(p.gpa, x) catch {
                    log.err("{s}: inbox out of memory", .{@tagName(feature)});
                    return;
                };
            }
            p.opts.waker.wake();
        }

        fn drop(p: *Self, x: *Pending) void {
            x.result.deinit();
            p.gpa.destroy(x);
            p.outstanding -= 1;
        }

        fn takeInbox(p: *Self) []const *Pending {
            p.inbox_mutex.lockUncancelable(p.io);
            defer p.inbox_mutex.unlock(p.io);
            std.mem.swap(std.ArrayList(*Pending), &p.inbox, &p.taken);
            return p.taken.items;
        }
    };
}
