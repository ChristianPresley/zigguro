//! On-demand position requests (hover, go to definition, references,
//! document highlight, ...): `ask` sends request `M` at a byte offset of
//! a document to every server routed for `feature` (up to `max_servers`,
//! in routing order), each with the position in that server's encoding.
//! Answers arrive on reader threads and wait in an inbox; `take` hands
//! the current round's answers to the UI thread.
//!
//! A new `ask` (or `cancel`) starts a new round: answers to older rounds
//! are dropped when they arrive, so a slow server never shows a stale
//! result. The UI thread compares an answer's `version` with the
//! document before using its ranges.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const position = @import("position.zig");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;

/// Most servers asked per round.
pub const max_servers = 4;

pub fn Requester(comptime M: protocol.Method, comptime feature: Manager.Feature) type {
    return struct {
        const Self = @This();
        pub const Params = protocol.RequestInfo(M).Params;
        pub const Value = protocol.RequestInfo(M).Result;

        /// One server's answer.
        pub const Answer = struct {
            h: DocHandle,
            /// The document version the request was made at.
            version: u64,
            /// The offset asked about.
            offset: u64,
            client: *Client,
            /// Index of the server in the round (routing order).
            index: u8,
            result: Client.Result(M) = undefined,
            round: u64,
            r: *Self,
        };

        gpa: Allocator,
        io: Io,
        mgr: *Manager,
        waker: zg_core.runtime.Waker,
        round: u64 = 0,
        /// Servers asked in the current round, and answers taken so far.
        asked: u8 = 0,
        answered: u8 = 0,
        inbox_mutex: Io.Mutex = .init,
        inbox: std.ArrayList(*Answer) = .empty,
        taken: std.ArrayList(*Answer) = .empty,
        outstanding: std.atomic.Value(usize) = .init(0),
        /// Requests sent (tests).
        sent: u32 = 0,

        pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker) Self {
            return .{ .gpa = mgr.gpa, .io = mgr.rt.io, .mgr = mgr, .waker = waker };
        }

        /// Call after `Manager.deinit`, which answers everything in
        /// flight.
        pub fn deinit(r: *Self) void {
            r.release();
            for (r.takeInbox()) |a| r.drop(a);
            r.taken.clearRetainingCapacity();
            std.debug.assert(r.outstanding.load(.acquire) == 0);
            r.inbox.deinit(r.gpa);
            r.taken.deinit(r.gpa);
        }

        /// Whether any server provides `feature` for `h`.
        pub fn available(r: *Self, h: DocHandle) bool {
            var cs: [1]*Client = undefined;
            return r.mgr.clientsFor(h, feature, &cs) > 0;
        }

        /// Starts a round: asks every routed server about byte `offset`
        /// of `h`. `extra` holds the params' other fields (`context` for
        /// references). Returns the servers asked (0: none provides it).
        pub fn ask(r: *Self, h: DocHandle, offset: u64, extra: anytype) !u8 {
            r.cancel();
            const doc = r.mgr.docs.get(h) orelse return 0;
            const uri = r.mgr.docs.uri(h) orelse return 0;
            var cs: [max_servers]*Client = undefined;
            const n = r.mgr.clientsFor(h, feature, &cs);
            for (cs[0..n], 0..) |c, i| {
                var m: position.Mapper = .{ .gpa = r.gpa, .tree = &doc.tree, .enc = position.encodingOf(c.encoding()) };
                defer m.deinit();
                var params: Params = undefined;
                params.textDocument = .{ .uri = uri };
                params.position = try m.positionOf(@min(offset, doc.len()));
                inline for (@typeInfo(Params).@"struct".fields) |f| {
                    if (comptime std.mem.eql(u8, f.name, "textDocument") or std.mem.eql(u8, f.name, "position")) continue;
                    @field(params, f.name) = if (@hasField(@TypeOf(extra), f.name)) @field(extra, f.name) else f.defaultValue().?;
                }
                const a = try r.gpa.create(Answer);
                errdefer r.gpa.destroy(a);
                a.* = .{ .h = h, .version = doc.version, .offset = offset, .client = c, .index = @intCast(i), .round = r.round, .r = r };
                _ = r.outstanding.fetchAdd(1, .acq_rel);
                _ = c.request(M, params, .{ .doc = r.mgr.docMatch(h) }, .{ .ctx = a, .func = onResult }) catch |e| {
                    _ = r.outstanding.fetchSub(1, .acq_rel);
                    return e;
                };
                r.asked += 1;
                r.sent += 1;
            }
            return r.asked;
        }

        /// Forgets the current round (its answers are dropped).
        pub fn cancel(r: *Self) void {
            r.release();
            r.round += 1;
            r.asked = 0;
            r.answered = 0;
        }

        /// Whether every server of the current round answered.
        pub fn done(r: *const Self) bool {
            return r.answered >= r.asked;
        }

        /// The current round's answers that arrived since the last
        /// `take`, in arrival order; valid until the next `take`,
        /// `cancel` or `ask`.
        pub fn take(r: *Self) []const *Answer {
            r.release();
            const got = r.takeInbox();
            var keep: usize = 0;
            for (got) |a| {
                if (a.round != r.round) {
                    r.drop(a);
                    continue;
                }
                got[keep] = a;
                keep += 1;
            }
            r.taken.shrinkRetainingCapacity(keep);
            r.answered += @intCast(keep);
            return r.taken.items;
        }

        /// Frees the answers `take` returned.
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

        /// Swaps the inbox into `taken` (which `release` emptied).
        fn takeInbox(r: *Self) []*Answer {
            r.inbox_mutex.lockUncancelable(r.io);
            defer r.inbox_mutex.unlock(r.io);
            std.mem.swap(std.ArrayList(*Answer), &r.inbox, &r.taken);
            return r.taken.items;
        }
    };
}
