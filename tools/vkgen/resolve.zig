//! Selects what `vk.zig` contains: the `vulkan` core versions up to
//! `max_version`, the allowlisted extensions plus their dependencies, every
//! type and command they require, and everything those reference. Enum
//! groups that are emitted get all of their values from every core version
//! and every Vulkan extension (values cost nothing and name more results).

const std = @import("std");
const reg_mod = @import("registry.zig");
const Registry = reg_mod.Registry;
const Interface = reg_mod.Interface;
const EnumValue = reg_mod.EnumValue;

/// What to select.
pub const Config = struct {
    /// Highest core version, as major*100+minor.
    max_version: u32 = 104,
    extensions: []const []const u8,
};

pub const ResolveError = error{
    OutOfMemory,
    UnknownExtension,
    UnsupportedExtension,
    UnknownType,
    UnknownCommand,
    ConflictingEnumValue,
    InvalidDepends,
    UnsatisfiableDepends,
};

/// A selected extension and its name/spec-version constants.
pub const SelectedExt = struct {
    iface: *const Interface,
    spec_version: u32 = 0,
};

/// The result of `resolve`.
pub const Selection = struct {
    arena: std.heap.ArenaAllocator,
    features: std.ArrayList(*const Interface) = .empty,
    extensions: std.ArrayList(SelectedExt) = .empty,
    types: std.StringArrayHashMapUnmanaged(void) = .empty,
    commands: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Values of every emitted enum group, de-duplicated, in document order.
    enum_values: std.StringArrayHashMapUnmanaged(std.ArrayList(EnumValue)) = .empty,
    /// Which versions/extensions require each type or command.
    provided_by: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    /// The name of the last conflicting or unknown item, for messages.
    culprit: []const u8 = "",

    pub fn deinit(self: *Selection) void {
        self.arena.deinit();
    }

    pub fn hasType(self: *const Selection, name: []const u8) bool {
        return self.types.contains(name);
    }

    pub fn hasExtension(self: *const Selection, name: []const u8) bool {
        for (self.extensions.items) |e| if (std.mem.eql(u8, e.iface.name, name)) return true;
        return false;
    }
};

/// Resolves `cfg` against `reg`. On error `culprit_out` receives the name of
/// the offending item (a slice of the registry or of `cfg`).
pub fn resolve(gpa: std.mem.Allocator, reg: *const Registry, cfg: Config, culprit_out: ?*[]const u8) ResolveError!Selection {
    var sel: Selection = .{ .arena = .init(gpa) };
    errdefer sel.arena.deinit();
    var r: Resolver = .{ .reg = reg, .sel = &sel, .a = sel.arena.allocator(), .cfg = cfg };
    r.run() catch |err| {
        if (culprit_out) |c| c.* = sel.culprit;
        return err;
    };
    return sel;
}

const Resolver = struct {
    reg: *const Registry,
    sel: *Selection,
    a: std.mem.Allocator,
    cfg: Config,

    fn fail(self: *Resolver, what: []const u8, err: ResolveError) ResolveError {
        self.sel.culprit = what;
        return err;
    }

    fn run(self: *Resolver) ResolveError!void {
        const reg = self.reg;
        for (reg.features.items) |*f| {
            if (reg_mod.apiIncludesVulkan(f.supported) and f.number <= self.cfg.max_version) try self.sel.features.append(self.a, f);
        }
        for (self.cfg.extensions) |name| try self.addExtension(name);
        // Pull in dependencies until nothing changes.
        var i: usize = 0;
        while (i < self.sel.extensions.items.len) : (i += 1) {
            const e = self.sel.extensions.items[i].iface;
            if (e.depends) |d| try self.satisfy(d);
        }
        // Keep document order for the extensions.
        std.mem.sort(SelectedExt, self.sel.extensions.items, {}, struct {
            fn lt(_: void, x: SelectedExt, y: SelectedExt) bool {
                return @intFromPtr(x.iface) < @intFromPtr(y.iface);
            }
        }.lt);

        for (self.sel.features.items) |f| try self.apply(f);
        for (self.sel.extensions.items) |*e| {
            try self.apply(e.iface);
            e.spec_version = specVersion(e.iface);
        }
        try self.closure();
        try self.collectEnums();
    }

    fn addExtension(self: *Resolver, name: []const u8) ResolveError!void {
        if (self.sel.hasExtension(name)) return;
        const e = self.findExtension(name) orelse return self.fail(name, error.UnknownExtension);
        if (!reg_mod.apiIncludesVulkan(e.supported)) return self.fail(name, error.UnsupportedExtension);
        try self.sel.extensions.append(self.a, .{ .iface = e });
    }

    fn findExtension(self: *Resolver, name: []const u8) ?*const Interface {
        for (self.reg.extensions.items) |*e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    fn termTrue(self: *Resolver, term: []const u8) bool {
        // `Struct::member` feature terms are assumed satisfied.
        if (std.mem.indexOf(u8, term, "::") != null) return true;
        for (self.sel.features.items) |f| if (std.mem.eql(u8, f.name, term)) return true;
        return self.sel.hasExtension(term);
    }

    /// Adds extensions until `expr` holds: every operand of `+`, the first
    /// operand of an unsatisfied `,`.
    fn satisfy(self: *Resolver, expr: []const u8) ResolveError!void {
        var e: Expr = .{ .src = expr };
        const root = e.parse(self.a) catch return self.fail(expr, error.InvalidDepends);
        try self.satisfyNode(root);
    }

    fn satisfyNode(self: *Resolver, n: *const Node) ResolveError!void {
        if (n.eval(self)) return;
        switch (n.*) {
            .term => |t| {
                if (std.mem.startsWith(u8, t, "VK_VERSION_") or std.mem.startsWith(u8, t, "VK_BASE_VERSION_")) return self.fail(t, error.UnsatisfiableDepends);
                try self.addExtension(t);
            },
            .op => |o| switch (o.kind) {
                .@"and" => {
                    try self.satisfyNode(o.lhs);
                    try self.satisfyNode(o.rhs);
                },
                .@"or" => try self.satisfyNode(o.lhs),
            },
        }
    }

    fn holds(self: *Resolver, expr: ?[]const u8) ResolveError!bool {
        const d = expr orelse return true;
        var e: Expr = .{ .src = d };
        const root = e.parse(self.a) catch return self.fail(d, error.InvalidDepends);
        return root.eval(self);
    }

    fn apply(self: *Resolver, iface: *const Interface) ResolveError!void {
        for (iface.requires) |b| {
            if (!try self.holds(b.depends)) continue;
            for (b.types) |t| try self.addType(t, iface.name);
            for (b.commands) |c| try self.addCommand(c, iface.name);
        }
        for (iface.removes) |b| {
            for (b.types) |t| _ = self.sel.types.orderedRemove(t);
            for (b.commands) |c| _ = self.sel.commands.orderedRemove(c);
        }
    }

    fn provide(self: *Resolver, name: []const u8, by: []const u8) ResolveError!void {
        const gop = try self.sel.provided_by.getOrPut(self.a, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |x| if (std.mem.eql(u8, x, by)) return;
        try gop.value_ptr.append(self.a, by);
    }

    fn addType(self: *Resolver, name: []const u8, by: ?[]const u8) ResolveError!void {
        if (!self.reg.types.contains(name)) return self.fail(name, error.UnknownType);
        try self.sel.types.put(self.a, name, {});
        if (by) |b| try self.provide(name, b);
    }

    fn addCommand(self: *Resolver, name: []const u8, by: ?[]const u8) ResolveError!void {
        const c = self.reg.commands.get(name) orelse return self.fail(name, error.UnknownCommand);
        // Aliases select their target; the alias name is used by the loader.
        const target = if (c.alias != null) (self.reg.resolveCommand(name) orelse return self.fail(name, error.UnknownCommand)).name else name;
        try self.sel.commands.put(self.a, target, {});
        if (by) |b| try self.provide(target, b);
    }

    /// Adds every type referenced by the selected types and commands.
    fn closure(self: *Resolver) ResolveError!void {
        for (self.sel.commands.keys()) |cname| {
            const c = self.reg.commands.get(cname).?;
            try self.addType(c.ret.base, null);
            for (c.params) |p| try self.addType(p.ty.base, null);
        }
        var i: usize = 0;
        while (i < self.sel.types.count()) : (i += 1) {
            const name = self.sel.types.keys()[i];
            const t = self.reg.types.get(name).?;
            if (t.alias) |al| try self.addType(al, null);
            if (t.requires) |rq| if (self.reg.types.contains(rq)) try self.addType(rq, null);
            if (t.base) |b| try self.addType(b.base, null);
            if (t.ret) |rt| try self.addType(rt.base, null);
            for (t.members) |m| try self.addType(m.ty.base, null);
            for (t.params) |p| try self.addType(p.ty.base, null);
        }
    }

    fn collectEnums(self: *Resolver) ResolveError!void {
        const reg = self.reg;
        for (self.sel.types.keys()) |name| {
            const t = reg.types.get(name).?;
            if (t.category != .@"enum" or t.alias != null) continue;
            var list: std.ArrayList(EnumValue) = .empty;
            if (reg.enums.get(name)) |g| for (g.values.items) |v| try self.addValue(&list, v);
            try self.sel.enum_values.put(self.a, name, list);
        }
        // Extension values from every core version and every Vulkan extension.
        for (self.sel.features.items) |f| try self.extendFrom(f);
        for (reg.extensions.items) |*e| {
            if (!reg_mod.apiIncludesVulkan(e.supported)) continue;
            try self.extendFrom(e);
        }
        // Drop aliases whose target is missing.
        for (self.sel.enum_values.values()) |*list| {
            var k: usize = 0;
            while (k < list.items.len) {
                const v = list.items[k];
                if (v.value == .alias and !hasValue(list.items, v.value.alias)) {
                    _ = list.orderedRemove(k);
                } else k += 1;
            }
        }
    }

    fn extendFrom(self: *Resolver, iface: *const Interface) ResolveError!void {
        for (iface.requires) |b| for (b.enums) |re| {
            const ext = re.extends orelse continue;
            const v = re.value orelse continue;
            const list = self.sel.enum_values.getPtr(ext) orelse continue;
            try self.addValue(list, .{ .name = re.name, .value = v });
        };
    }

    fn addValue(self: *Resolver, list: *std.ArrayList(EnumValue), v: EnumValue) ResolveError!void {
        for (list.items) |x| if (std.mem.eql(u8, x.name, v.name)) {
            if (!x.sameValue(v)) return self.fail(v.name, error.ConflictingEnumValue);
            return;
        };
        try list.append(self.a, v);
    }
};

fn hasValue(items: []const EnumValue, name: []const u8) bool {
    for (items) |x| if (std.mem.eql(u8, x.name, name)) return true;
    return false;
}

/// `VK_*_SPEC_VERSION` of an extension.
fn specVersion(iface: *const Interface) u32 {
    for (iface.requires) |b| for (b.enums) |e| {
        if (e.extends == null and std.mem.endsWith(u8, e.name, "_SPEC_VERSION")) {
            if (e.value) |v| if (v == .int) return @intCast(v.int);
        }
    };
    return 0;
}

const Node = union(enum) {
    term: []const u8,
    op: struct { kind: enum { @"and", @"or" }, lhs: *const Node, rhs: *const Node },

    fn eval(n: *const Node, r: *Resolver) bool {
        return switch (n.*) {
            .term => |t| r.termTrue(t),
            .op => |o| switch (o.kind) {
                .@"and" => o.lhs.eval(r) and o.rhs.eval(r),
                .@"or" => o.lhs.eval(r) or o.rhs.eval(r),
            },
        };
    }
};

/// `depends` expressions: `+` is AND, `,` is OR, equal precedence, left to
/// right, with parentheses (as in Vulkan-Docs scripts/parse_dependency.py).
const Expr = struct {
    src: []const u8,
    pos: usize = 0,

    fn parse(e: *Expr, a: std.mem.Allocator) error{ OutOfMemory, Invalid }!*const Node {
        const n = try e.seq(a);
        if (e.pos != e.src.len) return error.Invalid;
        return n;
    }

    fn seq(e: *Expr, a: std.mem.Allocator) error{ OutOfMemory, Invalid }!*const Node {
        var lhs = try e.primary(a);
        while (e.pos < e.src.len and (e.src[e.pos] == '+' or e.src[e.pos] == ',')) {
            const kind: @FieldType(@FieldType(Node, "op"), "kind") = if (e.src[e.pos] == '+') .@"and" else .@"or";
            e.pos += 1;
            const rhs = try e.primary(a);
            const n = try a.create(Node);
            n.* = .{ .op = .{ .kind = kind, .lhs = lhs, .rhs = rhs } };
            lhs = n;
        }
        return lhs;
    }

    fn primary(e: *Expr, a: std.mem.Allocator) error{ OutOfMemory, Invalid }!*const Node {
        if (e.pos >= e.src.len) return error.Invalid;
        if (e.src[e.pos] == '(') {
            e.pos += 1;
            const n = try e.seq(a);
            if (e.pos >= e.src.len or e.src[e.pos] != ')') return error.Invalid;
            e.pos += 1;
            return n;
        }
        const st = e.pos;
        while (e.pos < e.src.len and (std.ascii.isAlphanumeric(e.src[e.pos]) or e.src[e.pos] == '_' or e.src[e.pos] == ':')) e.pos += 1;
        if (e.pos == st) return error.Invalid;
        const n = try a.create(Node);
        n.* = .{ .term = e.src[st..e.pos] };
        return n;
    }
};

test "resolve: depends expression" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var reg: Registry = .{ .arena = .init(std.testing.allocator) };
    defer reg.deinit();
    const v11: Interface = .{ .name = "VK_VERSION_1_1", .kind = .feature, .number = 101 };
    const ka: Interface = .{ .name = "VK_KHR_a", .kind = .extension, .number = 1, .supported = "vulkan" };
    var sel: Selection = .{ .arena = .init(std.testing.allocator) };
    defer sel.deinit();
    var r: Resolver = .{ .reg = &reg, .sel = &sel, .a = arena.allocator(), .cfg = .{ .extensions = &.{} } };

    // Left to right: (a + b) , 1.1
    try std.testing.expect(!try r.holds("VK_KHR_a+VK_KHR_b,VK_VERSION_1_1"));
    try sel.features.append(arena.allocator(), &v11);
    try std.testing.expect(try r.holds("VK_KHR_a+VK_KHR_b,VK_VERSION_1_1"));
    try std.testing.expect(!try r.holds("VK_KHR_a+(VK_KHR_b,VK_VERSION_1_1)"));
    try sel.extensions.append(arena.allocator(), .{ .iface = &ka });
    try std.testing.expect(try r.holds("VK_KHR_a+(VK_KHR_b,VK_VERSION_1_1)"));
    try std.testing.expect(try r.holds("VkPhysicalDeviceFeatures::x"));
    try std.testing.expectError(error.InvalidDepends, r.holds("VK_KHR_a+"));
    try std.testing.expectError(error.InvalidDepends, r.holds("(VK_KHR_a"));
}

test "resolve: conflicting duplicate enum value is an error" {
    const src =
        \\<registry>
        \\<types><type name="VkE" category="enum"/><type category="struct" name="VkS"><member><type>VkE</type> <name>e</name></member></type></types>
        \\<enums name="VkE" type="enum"><enum value="0" name="VK_E_A"/></enums>
        \\<feature api="vulkan" name="VK_VERSION_1_0" number="1.0"><require><type name="VkS"/></require></feature>
        \\<extensions>
        \\<extension name="VK_KHR_x" number="1" supported="vulkan"><require><enum offset="0" extends="VkE" name="VK_E_X"/></require></extension>
        \\<extension name="VK_KHR_y" number="2" supported="vulkan"><require><enum offset="1" extends="VkE" name="VK_E_X"/></require></extension>
        \\</extensions>
        \\</registry>
    ;
    var reg = try Registry.parse(std.testing.allocator, src);
    defer reg.deinit();
    try std.testing.expectError(error.ConflictingEnumValue, resolve(std.testing.allocator, &reg, .{ .extensions = &.{} }, null));
}

test "resolve: vendored vk.xml with the allowlist" {
    var reg = try Registry.parse(std.testing.allocator, @embedFile("data/vk.xml"));
    defer reg.deinit();
    var sel = try resolve(std.testing.allocator, &reg, .{ .extensions = @import("extensions.zon") }, null);
    defer sel.deinit();
    try std.testing.expect(sel.commands.contains("vkCmdBeginRendering"));
    try std.testing.expect(sel.commands.contains("vkCreateSwapchainKHR"));
    try std.testing.expect(!sel.commands.contains("vkCmdBeginRenderingKHR"));
    try std.testing.expect(sel.hasType("VkPhysicalDeviceVulkan13Features"));
    try std.testing.expect(sel.hasType("VkPresentRegionsKHR"));
    try std.testing.expect(sel.hasType("HWND"));
    try std.testing.expect(!sel.hasType("VkVideoProfileInfoKHR"));
    // Dependencies come in automatically.
    try std.testing.expect(sel.hasExtension("VK_KHR_external_memory_fd"));
    // Values from extensions, including negative ones.
    const results = sel.enum_values.get("VkResult").?;
    for (results.items) |v| {
        if (std.mem.eql(u8, v.name, "VK_ERROR_OUT_OF_DATE_KHR")) {
            try std.testing.expectEqual(@as(i64, -1000001004), v.value.int);
            break;
        }
    } else return error.TestUnexpectedResult;
    const st = sel.enum_values.get("VkStructureType").?;
    for (st.items) |v| {
        if (std.mem.eql(u8, v.name, "VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR")) {
            try std.testing.expectEqual(@as(i64, 1000001000), v.value.int);
            break;
        }
    } else return error.TestUnexpectedResult;
    // No dangling names: every member and parameter type is selected.
    for (sel.types.keys()) |name| {
        const t = reg.types.get(name).?;
        for (t.members) |m| try std.testing.expect(sel.hasType(m.ty.base));
    }
}
