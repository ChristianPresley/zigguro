//! Single requests to one chosen server (`codeAction/resolve`,
//! `workspace/executeCommand`): `send` tags each with a caller value;
//! answers arrive on reader threads and wait in an inbox until `take`
//! hands them to the UI thread.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;

pub fn Oneshot(comptime M: protocol.Method, comptime Tag: type) type {
    return struct {
        const Self = @This();
        pub const Params = protocol.RequestInfo(M).Params;

        pub const Answer = struct {
            client: *Client,
            tag: Tag,
            result: Client.Result(M) = undefined,
            r: *Self,
        };

        gpa: Allocator,
        io: Io,
        waker: zg_core.runtime.Waker,
        inbox_mutex: Io.Mutex = .init,
        inbox: std.ArrayList(*Answer) = .empty,
        taken: std.ArrayList(*Answer) = .empty,
        outstanding: std.atomic.Value(usize) = .init(0),

        pub fn init(gpa: Allocator, io: Io, waker: zg_core.runtime.Waker) Self {
            return .{ .gpa = gpa, .io = io, .waker = waker };
        }

        /// Call after the clients are gone (they answer everything in
        /// flight first).
        pub fn deinit(r: *Self) void {
            r.release();
            for (r.takeInbox()) |a| r.drop(a);
            r.taken.clearRetainingCapacity();
            std.debug.assert(r.outstanding.load(.acquire) == 0);
            r.inbox.deinit(r.gpa);
            r.taken.deinit(r.gpa);
        }

        pub fn send(r: *Self, c: *Client, params: Params, opts: Client.ReqOpts, tag: Tag) !void {
            const a = try r.gpa.create(Answer);
            errdefer r.gpa.destroy(a);
            a.* = .{ .client = c, .tag = tag, .r = r };
            _ = r.outstanding.fetchAdd(1, .acq_rel);
            _ = c.request(M, params, opts, .{ .ctx = a, .func = onResult }) catch |e| {
                _ = r.outstanding.fetchSub(1, .acq_rel);
                return e;
            };
        }

        /// `send` with the params already serialized (`params_json`,
        /// copied), so items go back to the server byte for byte.
        pub fn sendRaw(r: *Self, c: *Client, params_json: []const u8, opts: Client.ReqOpts, tag: Tag) !void {
            const a = try r.gpa.create(Answer);
            errdefer r.gpa.destroy(a);
            a.* = .{ .client = c, .tag = tag, .r = r };
            _ = r.outstanding.fetchAdd(1, .acq_rel);
            _ = c.requestRaw(M, params_json, opts, .{ .ctx = a, .func = onResult }) catch |e| {
                _ = r.outstanding.fetchSub(1, .acq_rel);
                return e;
            };
        }

        /// Whether a request is in flight or unread.
        pub fn busy(r: *const Self) bool {
            return r.outstanding.load(.acquire) > r.taken.items.len;
        }

        /// The answers that arrived since the last `take`; valid until the
        /// next one.
        pub fn take(r: *Self) []const *Answer {
            r.release();
            return r.takeInbox();
        }

        fn release(r: *Self) void {
            for (r.taken.items) |a| r.drop(a);
            r.taken.clearRetainingCapacity();
        }

        fn onResult(ctx: ?*anyopaque, res: Client.Result(M)) void {
            const a: *Answer = @ptrCast(@alignCast(ctx.?));
            a.result = res;
            const r = a.r;
            {
                r.inbox_mutex.lockUncancelable(r.io);
                defer r.inbox_mutex.unlock(r.io);
                r.inbox.append(r.gpa, a) catch {
                    res.deinit();
                    r.gpa.destroy(a);
                    _ = r.outstanding.fetchSub(1, .acq_rel);
                    return;
                };
            }
            r.waker.wake();
        }

        fn drop(r: *Self, a: *Answer) void {
            a.result.deinit();
            r.gpa.destroy(a);
            _ = r.outstanding.fetchSub(1, .acq_rel);
        }

        fn takeInbox(r: *Self) []*Answer {
            r.inbox_mutex.lockUncancelable(r.io);
            defer r.inbox_mutex.unlock(r.io);
            std.mem.swap(std.ArrayList(*Answer), &r.inbox, &r.taken);
            return r.taken.items;
        }
    };
}
