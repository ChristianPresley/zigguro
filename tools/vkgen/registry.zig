//! The typed model of vk.xml and its parser. Everything lives in one arena
//! owned by `Registry`; names and attribute values are slices of the input
//! (decoded copies when they contain entities). Elements whose `api`
//! attribute excludes `vulkan` are dropped at every level.

const std = @import("std");
const xml = @import("xml.zig");
const cdecl = @import("cdecl.zig");

pub const CType = cdecl.CType;
pub const ArrayDim = cdecl.ArrayDim;
pub const Piece = cdecl.Piece;

/// A struct member, command parameter or funcpointer parameter.
pub const Decl = struct {
    name: []const u8,
    ty: CType,
    /// `optional="a,b"`, outermost pointer first.
    optional: []const bool = &.{},
    /// `len="a,b"`, outermost pointer first.
    len: ?[]const u8 = null,
    /// `values=` (the sType of a struct).
    values: ?[]const u8 = null,

    /// True if the pointer (or value) at `level` (0 = outermost) may be null/zero.
    pub fn isOptional(d: Decl, level: usize) bool {
        return level < d.optional.len and d.optional[level];
    }

    /// The `len` entry for pointer level `level` (0 = outermost).
    pub fn lenAt(d: Decl, level: usize) ?[]const u8 {
        const l = d.len orelse return null;
        var it = std.mem.splitScalar(u8, l, ',');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) if (i == level) return part;
        return null;
    }
};

/// `<type category=...>`.
pub const Category = enum { basetype, bitmask, define, @"enum", funcpointer, group, handle, include, @"struct", @"union", none };

/// One `<type>`.
pub const Type = struct {
    name: []const u8,
    category: Category,
    alias: ?[]const u8 = null,
    /// struct/union members.
    members: []const Decl = &.{},
    structextends: []const []const u8 = &.{},
    returnedonly: bool = false,
    /// bitmask: the FlagBits type (`requires=` or `bitvalues=`); none: the header.
    requires: ?[]const u8 = null,
    /// basetype typedef target, or bitmask underlying type (VkFlags/VkFlags64).
    base: ?CType = null,
    /// handle: VK_DEFINE_HANDLE (pointer-sized) rather than non-dispatchable.
    dispatchable: bool = false,
    /// funcpointer return type and parameters.
    ret: ?CType = null,
    params: []const Decl = &.{},
};

/// One `<enum>` value in a group or an extension.
pub const EnumValue = struct {
    name: []const u8,
    value: Value,
    /// constants: the C type (`uint32_t`, `float`, ...).
    ctype: ?[]const u8 = null,
    deprecated: bool = false,

    pub const Value = union(enum) {
        int: i64,
        bitpos: u6,
        alias: []const u8,
        /// A constant expression such as `(~0U)` or `1000.0F`, or a quoted string.
        expr: []const u8,
    };

    /// Same value (aliases compare by name).
    pub fn sameValue(a: EnumValue, b: EnumValue) bool {
        return switch (a.value) {
            .int => |x| b.value == .int and b.value.int == x,
            .bitpos => |x| b.value == .bitpos and b.value.bitpos == x,
            .alias => |x| b.value == .alias and std.mem.eql(u8, b.value.alias, x),
            .expr => |x| b.value == .expr and std.mem.eql(u8, b.value.expr, x),
        };
    }
};

/// One `<enums>` block.
pub const EnumGroup = struct {
    name: []const u8,
    kind: Kind,
    bitwidth: u8 = 32,
    values: std.ArrayList(EnumValue) = .empty,

    pub const Kind = enum { constants, @"enum", bitmask };
};

/// One `<command>`.
pub const Command = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    ret: CType = .{ .base = "void" },
    params: []const Decl = &.{},
    success_codes: []const []const u8 = &.{},
    error_codes: []const []const u8 = &.{},
};

/// An `<enum>` inside a `<require>`/`<remove>`.
pub const ReqEnum = struct {
    name: []const u8,
    extends: ?[]const u8 = null,
    /// Null for a plain reference to an existing value.
    value: ?EnumValue.Value = null,
};

/// A `<require>` or `<remove>` block.
pub const Block = struct {
    depends: ?[]const u8 = null,
    types: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
    enums: []const ReqEnum = &.{},
};

/// A `<feature>` (core version) or `<extension>`.
pub const Interface = struct {
    name: []const u8,
    kind: enum { feature, extension },
    /// feature: `number="1.3"` as major*100+minor; extension: its number.
    number: u32,
    depends: ?[]const u8 = null,
    /// extension: `supported=`; feature: `api=`.
    supported: []const u8 = "",
    /// extension: "instance" or "device".
    ext_type: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    promotedto: ?[]const u8 = null,
    requires: []const Block = &.{},
    removes: []const Block = &.{},
};

/// Parse errors.
pub const ParseError = xml.Error || cdecl.Error || error{ OutOfMemory, InvalidRegistry };

/// The parsed registry.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    types: std.StringArrayHashMapUnmanaged(Type) = .empty,
    enums: std.StringArrayHashMapUnmanaged(EnumGroup) = .empty,
    commands: std.StringArrayHashMapUnmanaged(Command) = .empty,
    features: std.ArrayList(Interface) = .empty,
    extensions: std.ArrayList(Interface) = .empty,
    /// Vendor tags (`KHR`, `EXT`, ...).
    tags: std.ArrayList([]const u8) = .empty,
    header_version: u32 = 0,
    /// Line of the last parse error, for messages.
    err_line: u32 = 0,

    /// Parses `src`, which must outlive the registry.
    pub fn parse(gpa: std.mem.Allocator, src: []const u8) ParseError!Registry {
        var reg: Registry = .{ .arena = .init(gpa) };
        errdefer reg.arena.deinit();
        var p: xml.Parser = .init(src);
        var ctx: Ctx = .{ .reg = &reg, .p = &p, .a = reg.arena.allocator() };
        ctx.run() catch |err| {
            reg.err_line = p.location().line;
            return err;
        };
        return reg;
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }

    /// Follows type aliases to the defining type.
    pub fn resolveType(self: *const Registry, name: []const u8) ?*const Type {
        var n = name;
        for (0..8) |_| {
            const t = self.types.getPtr(n) orelse return null;
            n = t.alias orelse return t;
        }
        return null;
    }

    /// Follows command aliases to the defining command.
    pub fn resolveCommand(self: *const Registry, name: []const u8) ?*const Command {
        var n = name;
        for (0..8) |_| {
            const c = self.commands.getPtr(n) orelse return null;
            n = c.alias orelse return c;
        }
        return null;
    }

    /// The tag a name ends with (`VkSurfaceKHR` → "KHR"), or null.
    pub fn tagSuffix(self: *const Registry, name: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        for (self.tags.items) |t| {
            if (name.len > t.len and std.mem.endsWith(u8, name, t)) {
                if (best == null or t.len > best.?.len) best = t;
            }
        }
        return best;
    }
};

/// True if an `api=` / `supported=` list includes plain `vulkan`.
pub fn apiIncludesVulkan(list: ?[]const u8) bool {
    const l = list orelse return true;
    var it = std.mem.splitScalar(u8, l, ',');
    while (it.next()) |a| if (std.mem.eql(u8, a, "vulkan")) return true;
    return false;
}

const Ctx = struct {
    reg: *Registry,
    p: *xml.Parser,
    a: std.mem.Allocator,

    fn attr(self: *Ctx, s: xml.Event.Start, name: []const u8) ParseError!?[]const u8 {
        const raw = s.attrs.get(name) orelse return null;
        if (xml.isPlain(raw)) return raw;
        var out: std.ArrayList(u8) = .empty;
        try xml.decodeValue(raw, &out, self.a);
        return out.items;
    }

    fn need(self: *Ctx, s: xml.Event.Start, name: []const u8) ParseError![]const u8 {
        return (try self.attr(s, name)) orelse error.InvalidRegistry;
    }

    fn run(self: *Ctx) ParseError!void {
        // Find <registry>.
        while (true) {
            switch (try self.p.next()) {
                .start => |s| {
                    if (!std.mem.eql(u8, s.name, "registry")) return error.InvalidRegistry;
                    break;
                },
                .eof => return error.InvalidRegistry,
                else => {},
            }
        }
        while (true) {
            switch (try self.p.next()) {
                .start => |s| {
                    if (eql(s.name, "tags")) {
                        try self.tagsBlock();
                    } else if (eql(s.name, "types")) {
                        try self.typesBlock();
                    } else if (eql(s.name, "enums")) {
                        try self.enumsBlock(s);
                    } else if (eql(s.name, "commands")) {
                        try self.commandsBlock();
                    } else if (eql(s.name, "feature")) {
                        try self.interface(s, .feature);
                    } else if (eql(s.name, "extensions")) {
                        try self.extensionsBlock();
                    } else try self.p.skipElement();
                },
                .end => return,
                .eof => return error.InvalidRegistry,
                else => {},
            }
        }
    }

    fn tagsBlock(self: *Ctx) ParseError!void {
        while (true) {
            switch (try self.p.next()) {
                .start => |s| {
                    if (eql(s.name, "tag")) try self.reg.tags.append(self.a, try self.need(s, "name"));
                    try self.p.skipElement();
                },
                .end => return,
                else => {},
            }
        }
    }

    /// Collects the text and child tags of a declaration element.
    fn pieces(self: *Ctx) ParseError![]const Piece {
        var out: std.ArrayList(Piece) = .empty;
        var current: ?Piece.Kind = null;
        while (true) {
            switch (try self.p.next()) {
                .start => |s| {
                    if (eql(s.name, "type")) {
                        current = .type;
                    } else if (eql(s.name, "name")) {
                        current = .name;
                    } else if (eql(s.name, "enum")) {
                        current = .@"enum";
                    } else {
                        try self.p.skipElement(); // <comment>
                    }
                },
                .text => |t| {
                    var buf: std.ArrayList(u8) = .empty;
                    const s = if (!t.cdata and xml.isPlain(t.raw)) t.raw else blk: {
                        try t.decode(&buf, self.a);
                        break :blk buf.items;
                    };
                    try out.append(self.a, .{ .kind = current orelse .text, .s = s });
                },
                .end => |n| {
                    if (current != null and (eql(n, "type") or eql(n, "name") or eql(n, "enum"))) {
                        current = null;
                    } else return out.items;
                },
                .eof => return error.UnexpectedEof,
                else => {},
            }
        }
    }

    fn typesBlock(self: *Ctx) ParseError!void {
        while (true) {
            switch (try self.p.next()) {
                .start => |s| {
                    if (eql(s.name, "type")) try self.typeElem(s) else try self.p.skipElement();
                },
                .end => return,
                else => {},
            }
        }
    }

    fn typeElem(self: *Ctx, s: xml.Event.Start) ParseError!void {
        if (!apiIncludesVulkan(try self.attr(s, "api"))) return self.p.skipElement();
        const cat_s = try self.attr(s, "category");
        const category: Category = if (cat_s) |c| std.meta.stringToEnum(Category, c) orelse return error.InvalidRegistry else .none;
        var t: Type = .{ .name = "", .category = category };
        t.alias = try self.attr(s, "alias");
        t.requires = (try self.attr(s, "requires")) orelse try self.attr(s, "bitvalues");
        t.returnedonly = if (try self.attr(s, "returnedonly")) |r| eql(r, "true") else false;
        if (try self.attr(s, "structextends")) |se| t.structextends = try splitList(self.a, se);
        if (try self.attr(s, "name")) |n| t.name = n;

        if (s.self_closing) {
            if (t.name.len == 0) return error.InvalidRegistry;
            return self.addType(t);
        }
        if (category == .@"struct" or category == .@"union") {
            var members: std.ArrayList(Decl) = .empty;
            while (true) {
                switch (try self.p.next()) {
                    .start => |m| {
                        if (!eql(m.name, "member")) {
                            try self.p.skipElement();
                            continue;
                        }
                        if (!apiIncludesVulkan(try self.attr(m, "api"))) {
                            try self.p.skipElement();
                            continue;
                        }
                        var d = try self.decl(m);
                        d.values = try self.attr(m, "values");
                        try members.append(self.a, d);
                    },
                    .end => break,
                    else => {},
                }
            }
            t.members = members.items;
            return self.addType(t);
        }
        const ps = try self.pieces();
        if (t.name.len == 0) t.name = cdecl.nameOf(ps) orelse return error.InvalidRegistry;
        switch (category) {
            .basetype => t.base = cdecl.basetype(ps),
            .bitmask => if (t.alias == null) {
                t.base = .{ .base = cdecl.firstOf(ps, .type) orelse return error.InvalidRegistry };
            },
            .handle => t.dispatchable = if (cdecl.firstOf(ps, .type)) |m| eql(m, "VK_DEFINE_HANDLE") else false,
            .funcpointer => {
                const fp = try cdecl.funcpointer(self.a, ps);
                t.ret = fp.ret;
                var params: std.ArrayList(Decl) = .empty;
                for (fp.params) |prm| try params.append(self.a, .{ .name = prm.name, .ty = prm.ty });
                t.params = params.items;
            },
            .define => if (eql(t.name, "VK_HEADER_VERSION")) {
                // `#define <name>VK_HEADER_VERSION</name> 330`
                const last = ps[ps.len - 1].s;
                t.base = null;
                self.reg.header_version = std.fmt.parseInt(u32, std.mem.trim(u8, last, " \t\r\n"), 10) catch return error.InvalidRegistry;
            },
            else => {},
        }
        return self.addType(t);
    }

    fn addType(self: *Ctx, t: Type) ParseError!void {
        const gop = try self.reg.types.getOrPut(self.a, t.name);
        // A later definition for the same api replaces an earlier one only
        // if the earlier one was a bare reference.
        if (!gop.found_existing or gop.value_ptr.category == .none) gop.value_ptr.* = t;
    }

    fn decl(self: *Ctx, s: xml.Event.Start) ParseError!Decl {
        const ps = try self.pieces();
        const ty = try cdecl.parse(self.a, ps);
        var d: Decl = .{ .name = cdecl.nameOf(ps) orelse return error.InvalidRegistry, .ty = ty };
        if (try self.attr(s, "optional")) |o| {
            var list: std.ArrayList(bool) = .empty;
            var it = std.mem.splitScalar(u8, o, ',');
            while (it.next()) |x| try list.append(self.a, eql(x, "true"));
            d.optional = list.items;
        }
        d.len = try self.attr(s, "len");
        return d;
    }

    fn enumsBlock(self: *Ctx, s: xml.Event.Start) ParseError!void {
        const name = try self.need(s, "name");
        const kind_s = (try self.attr(s, "type")) orelse "constants";
        const kind = std.meta.stringToEnum(EnumGroup.Kind, kind_s) orelse return error.InvalidRegistry;
        const gop = try self.reg.enums.getOrPut(self.a, name);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = name, .kind = kind };
        const g = gop.value_ptr;
        if (try self.attr(s, "bitwidth")) |bw| g.bitwidth = std.fmt.parseInt(u8, bw, 10) catch return error.InvalidRegistry;
        if (s.self_closing) return;
        while (true) {
            switch (try self.p.next()) {
                .start => |e| {
                    if (eql(e.name, "enum") and apiIncludesVulkan(try self.attr(e, "api"))) {
                        const v = (try self.enumValue(e, 0)) orelse return error.InvalidRegistry;
                        try g.values.append(self.a, .{
                            .name = try self.need(e, "name"),
                            .value = v,
                            .ctype = try self.attr(e, "type"),
                            .deprecated = (try self.attr(e, "deprecated")) != null,
                        });
                    }
                    try self.p.skipElement();
                },
                .end => return,
                else => {},
            }
        }
    }

    /// The value of an `<enum>`; `ext_number` is the enclosing extension's
    /// number (0 in a feature or a group).
    fn enumValue(self: *Ctx, e: xml.Event.Start, ext_number: u32) ParseError!?EnumValue.Value {
        if (try self.attr(e, "alias")) |a| return .{ .alias = a };
        if (try self.attr(e, "bitpos")) |b| return .{ .bitpos = std.fmt.parseInt(u6, b, 10) catch return error.InvalidRegistry };
        if (try self.attr(e, "offset")) |o| {
            const off = std.fmt.parseInt(u32, o, 10) catch return error.InvalidRegistry;
            const n = if (try self.attr(e, "extnumber")) |x| std.fmt.parseInt(u32, x, 10) catch return error.InvalidRegistry else ext_number;
            if (n == 0) return error.InvalidRegistry;
            const neg = if (try self.attr(e, "dir")) |d| eql(d, "-") else false;
            return .{ .int = extEnumValue(n, off, neg) };
        }
        if (try self.attr(e, "value")) |v| {
            if (std.fmt.parseInt(i64, v, 0)) |n| return .{ .int = n } else |_| return .{ .expr = v };
        }
        return null;
    }

    fn commandsBlock(self: *Ctx) ParseError!void {
        while (true) {
            switch (try self.p.next()) {
                .start => |s| {
                    if (eql(s.name, "command")) try self.command(s) else try self.p.skipElement();
                },
                .end => return,
                else => {},
            }
        }
    }

    fn command(self: *Ctx, s: xml.Event.Start) ParseError!void {
        if (!apiIncludesVulkan(try self.attr(s, "api"))) return self.p.skipElement();
        if (try self.attr(s, "alias")) |alias| {
            const name = try self.need(s, "name");
            try self.p.skipElement();
            try self.reg.commands.put(self.a, name, .{ .name = name, .alias = alias });
            return;
        }
        var c: Command = .{ .name = "" };
        if (try self.attr(s, "successcodes")) |sc| c.success_codes = try splitList(self.a, sc);
        if (try self.attr(s, "errorcodes")) |ec| c.error_codes = try splitList(self.a, ec);
        var params: std.ArrayList(Decl) = .empty;
        while (true) {
            switch (try self.p.next()) {
                .start => |e| {
                    if (eql(e.name, "proto")) {
                        const ps = try self.pieces();
                        c.name = cdecl.nameOf(ps) orelse return error.InvalidRegistry;
                        c.ret = try cdecl.parse(self.a, ps);
                    } else if (eql(e.name, "param") and apiIncludesVulkan(try self.attr(e, "api"))) {
                        try params.append(self.a, try self.decl(e));
                    } else try self.p.skipElement();
                },
                .end => break,
                else => {},
            }
        }
        if (c.name.len == 0) return error.InvalidRegistry;
        c.params = params.items;
        try self.reg.commands.put(self.a, c.name, c);
    }

    fn extensionsBlock(self: *Ctx) ParseError!void {
        while (true) {
            switch (try self.p.next()) {
                .start => |s| {
                    if (eql(s.name, "extension")) try self.interface(s, .extension) else try self.p.skipElement();
                },
                .end => return,
                else => {},
            }
        }
    }

    fn interface(self: *Ctx, s: xml.Event.Start, kind: @FieldType(Interface, "kind")) ParseError!void {
        var it: Interface = .{ .name = try self.need(s, "name"), .kind = kind, .number = 0 };
        const num = try self.need(s, "number");
        if (kind == .feature) {
            const dot = std.mem.indexOfScalar(u8, num, '.') orelse return error.InvalidRegistry;
            const major = std.fmt.parseInt(u32, num[0..dot], 10) catch return error.InvalidRegistry;
            const minor = std.fmt.parseInt(u32, num[dot + 1 ..], 10) catch return error.InvalidRegistry;
            it.number = major * 100 + minor;
            it.supported = (try self.attr(s, "api")) orelse "vulkan";
        } else {
            it.number = std.fmt.parseInt(u32, num, 10) catch return error.InvalidRegistry;
            it.supported = (try self.attr(s, "supported")) orelse "";
            it.ext_type = try self.attr(s, "type");
            it.platform = try self.attr(s, "platform");
            it.promotedto = try self.attr(s, "promotedto");
        }
        it.depends = try self.attr(s, "depends");
        var requires: std.ArrayList(Block) = .empty;
        var removes: std.ArrayList(Block) = .empty;
        while (true) {
            switch (try self.p.next()) {
                .start => |b| {
                    const is_req = eql(b.name, "require");
                    if ((!is_req and !eql(b.name, "remove")) or !apiIncludesVulkan(try self.attr(b, "api"))) {
                        try self.p.skipElement();
                        continue;
                    }
                    const blk = try self.block(b, if (kind == .extension) it.number else 0);
                    try (if (is_req) &requires else &removes).append(self.a, blk);
                },
                .end => break,
                else => {},
            }
        }
        it.requires = requires.items;
        it.removes = removes.items;
        try (if (kind == .feature) &self.reg.features else &self.reg.extensions).append(self.a, it);
    }

    fn block(self: *Ctx, b: xml.Event.Start, ext_number: u32) ParseError!Block {
        var blk: Block = .{ .depends = try self.attr(b, "depends") };
        if (b.self_closing) return blk;
        var types: std.ArrayList([]const u8) = .empty;
        var commands: std.ArrayList([]const u8) = .empty;
        var enums: std.ArrayList(ReqEnum) = .empty;
        while (true) {
            switch (try self.p.next()) {
                .start => |e| {
                    if (apiIncludesVulkan(try self.attr(e, "api"))) {
                        if (eql(e.name, "type")) {
                            try types.append(self.a, try self.need(e, "name"));
                        } else if (eql(e.name, "command")) {
                            try commands.append(self.a, try self.need(e, "name"));
                        } else if (eql(e.name, "enum")) {
                            try enums.append(self.a, .{
                                .name = try self.need(e, "name"),
                                .extends = try self.attr(e, "extends"),
                                .value = try self.enumValue(e, ext_number),
                            });
                        }
                    }
                    try self.p.skipElement();
                },
                .end => break,
                else => {},
            }
        }
        blk.types = types.items;
        blk.commands = commands.items;
        blk.enums = enums.items;
        return blk;
    }
};

/// `1000000000 + (ext_number - 1) * 1000 + offset`, negated for `dir="-"`.
pub fn extEnumValue(ext_number: u32, offset: u32, negative: bool) i64 {
    const v: i64 = 1_000_000_000 + (@as(i64, ext_number) - 1) * 1000 + offset;
    return if (negative) -v else v;
}

fn splitList(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |x| try list.append(a, x);
    return list.items;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "registry: ext enum value" {
    try std.testing.expectEqual(@as(i64, -1000001004), extEnumValue(2, 4, true));
    try std.testing.expectEqual(@as(i64, 1000001000), extEnumValue(2, 0, false));
}

test "registry: api filter drops vulkansc-only members" {
    const src =
        \\<registry><types>
        \\<type category="struct" name="VkA">
        \\  <member><type>uint32_t</type> <name>x</name></member>
        \\  <member api="vulkansc"><type>uint32_t</type> <name>sc</name></member>
        \\  <member api="vulkan"><type>uint32_t</type> <name>y</name></member>
        \\</type>
        \\<type category="struct" name="VkB" api="vulkansc"><member><type>uint32_t</type> <name>z</name></member></type>
        \\</types></registry>
    ;
    var reg = try Registry.parse(std.testing.allocator, src);
    defer reg.deinit();
    const a = reg.types.get("VkA").?;
    try std.testing.expectEqual(@as(usize, 2), a.members.len);
    try std.testing.expectEqualStrings("x", a.members[0].name);
    try std.testing.expectEqualStrings("y", a.members[1].name);
    try std.testing.expect(reg.types.get("VkB") == null);
}

test "registry: vendored vk.xml parses" {
    var reg = try Registry.parse(std.testing.allocator, @embedFile("data/vk.xml"));
    defer reg.deinit();
    try std.testing.expect(reg.header_version >= 330);
    try std.testing.expect(reg.types.get("VkImageCreateInfo") != null);
    try std.testing.expect(reg.commands.get("vkCmdBeginRendering") != null);
    try std.testing.expectEqualStrings("vkCmdBeginRendering", reg.resolveCommand("vkCmdBeginRenderingKHR").?.name);
    const swap = for (reg.extensions.items) |e| {
        if (eql(e.name, "VK_KHR_swapchain")) break e;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), swap.number);
    const app = reg.types.get("VkApplicationInfo").?;
    try std.testing.expectEqualStrings("VK_STRUCTURE_TYPE_APPLICATION_INFO", app.members[0].values.?);
    try std.testing.expect(app.members[2].isOptional(0));
    try std.testing.expectEqualStrings("null-terminated", app.members[2].lenAt(0).?);
    const cb = reg.types.get("PFN_vkDebugUtilsMessengerCallbackEXT").?;
    try std.testing.expectEqual(@as(usize, 4), cb.params.len);
    try std.testing.expectEqualStrings("pCallbackData", cb.params[2].name);
    try std.testing.expect(reg.types.get("VkInstance").?.dispatchable);
    try std.testing.expect(!reg.types.get("VkImage").?.dispatchable);
}
