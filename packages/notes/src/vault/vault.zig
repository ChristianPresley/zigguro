//! Vaults (E08.F06.S01.T01): a folder of Markdown notes inside a
//! workspace root, configured by `.zigguro/vault.zon` (ZON, the fields of
//! `VaultConfig`). A folder with an Obsidian `.obsidian/` directory is a
//! vault too: its `app.json`, `daily-notes.json` and `templates.json`
//! supply compatible settings. Nothing is ever written into `.obsidian/`.

const std = @import("std");
const zg_workspace = @import("zg_workspace");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const RootId = zg_workspace.RootId;

pub const VaultId = enum(u16) {
    _,

    pub fn of(i: u16) VaultId {
        return @enumFromInt(i);
    }
};

pub const NewNoteDir = enum { vault_root, same_as_current, fixed };
pub const LinkStyle = enum { shortest, relative, absolute };

pub const VaultConfig = struct {
    /// Vault-relative; `./` means next to the note.
    attachments_dir: []const u8 = "attachments",
    daily_dir: []const u8 = "daily",
    /// Moment-style tokens (E08.F07.S02.T01 `datefmt`).
    daily_format: []const u8 = "YYYY-MM-DD",
    /// Template applied to new daily notes (vault-relative, optional).
    daily_template: []const u8 = "",
    templates_dir: []const u8 = "templates",
    new_note_dir: NewNoteDir = .vault_root,
    /// The folder for `new_note_dir = .fixed`.
    new_note_folder: []const u8 = "",
    link_style: LinkStyle = .shortest,
    use_wikilinks: bool = true,
    alias_resolution: bool = true,
};

pub const Vault = struct {
    id: VaultId,
    root: RootId,
    /// Root-relative folder of the vault; empty for the whole root.
    rel_dir: []const u8,
    config: VaultConfig,

    /// Whether root-relative `rel` is a note of this vault: `*.md` or
    /// `*.markdown` under `rel_dir`, outside the `.obsidian`, `.zigguro`
    /// and `.trash` folders. Ignore rules are the caller's (the scanner
    /// never reports ignored files).
    pub fn isNotePath(v: *const Vault, rel: []const u8) bool {
        const inner = v.vaultRel(rel) orelse return false;
        if (!isMarkdownName(inner)) return false;
        return !hasHiddenSegment(inner);
    }

    /// Whether root-relative `rel` lies in the vault (notes and
    /// attachments).
    pub fn contains(v: *const Vault, rel: []const u8) bool {
        const inner = v.vaultRel(rel) orelse return false;
        return !hasHiddenSegment(inner);
    }

    /// `rel` (root-relative) made vault-relative, or null outside.
    pub fn vaultRel(v: *const Vault, rel: []const u8) ?[]const u8 {
        if (v.rel_dir.len == 0) return rel;
        if (!std.mem.startsWith(u8, rel, v.rel_dir)) return null;
        if (rel.len == v.rel_dir.len) return "";
        if (rel[v.rel_dir.len] != '/') return null;
        return rel[v.rel_dir.len + 1 ..];
    }

    /// A vault-relative path made root-relative (in `a`).
    pub fn rootRel(v: *const Vault, a: Allocator, inner: []const u8) ![]const u8 {
        if (v.rel_dir.len == 0) return a.dupe(u8, inner);
        return std.fmt.allocPrint(a, "{s}/{s}", .{ v.rel_dir, inner });
    }
};

pub fn isMarkdownName(p: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(p, ".md") or std.ascii.endsWithIgnoreCase(p, ".markdown");
}

fn hasHiddenSegment(p: []const u8) bool {
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".obsidian") or std.mem.eql(u8, seg, ".zigguro") or std.mem.eql(u8, seg, ".trash")) return true;
    }
    return false;
}

/// The config of the vault at `dir`, or null if `dir` is not a vault:
/// `.zigguro/vault.zon` wins; else `.obsidian/` settings are mapped onto
/// the defaults. Strings are allocated in `arena`. Malformed files are
/// treated as absent fields, never as errors.
pub fn detectVault(arena: Allocator, io: Io, dir: Io.Dir) !?VaultConfig {
    if (readSmall(arena, io, dir, ".zigguro/vault.zon")) |src| {
        const z = try arena.dupeZ(u8, src);
        if (std.zon.parse.fromSliceAlloc(VaultConfig, arena, z, null, .{ .ignore_unknown_fields = true })) |cfg| {
            return cfg;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{},
        }
    }
    var obs = dir.openDir(io, ".obsidian", .{}) catch return null;
    defer obs.close(io);
    var cfg: VaultConfig = .{};
    if (readSmall(arena, io, obs, "app.json")) |src| try applyObsidianApp(arena, &cfg, src);
    if (readSmall(arena, io, obs, "daily-notes.json")) |src| try applyObsidianDaily(arena, &cfg, src);
    if (readSmall(arena, io, obs, "templates.json")) |src| try applyObsidianTemplates(arena, &cfg, src);
    return cfg;
}

fn readSmall(arena: Allocator, io: Io, dir: Io.Dir, name: []const u8) ?[]const u8 {
    return dir.readFileAlloc(io, name, arena, .limited(256 * 1024)) catch null;
}

fn jsonObject(arena: Allocator, src: []const u8) ?std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch return null;
    return if (v == .object) v.object else null;
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn trimSlashes(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, "/");
}

/// `.obsidian/app.json`: `attachmentFolderPath`, `newFileLocation`,
/// `newFileFolderPath`, `useMarkdownLinks`, `newLinkFormat`.
pub fn applyObsidianApp(arena: Allocator, cfg: *VaultConfig, src: []const u8) !void {
    const o = jsonObject(arena, src) orelse return;
    if (str(o, "attachmentFolderPath")) |p| {
        cfg.attachments_dir = if (std.mem.eql(u8, p, "/")) "" else if (std.mem.startsWith(u8, p, "./")) p else trimSlashes(p);
    }
    if (str(o, "newFileLocation")) |l| {
        if (std.mem.eql(u8, l, "current")) cfg.new_note_dir = .same_as_current else if (std.mem.eql(u8, l, "folder")) cfg.new_note_dir = .fixed else cfg.new_note_dir = .vault_root;
    }
    if (str(o, "newFileFolderPath")) |p| cfg.new_note_folder = trimSlashes(p);
    if (o.get("useMarkdownLinks")) |v| if (v == .bool) {
        cfg.use_wikilinks = !v.bool;
    };
    if (str(o, "newLinkFormat")) |f| {
        if (std.mem.eql(u8, f, "relative")) cfg.link_style = .relative else if (std.mem.eql(u8, f, "absolute")) cfg.link_style = .absolute else cfg.link_style = .shortest;
    }
}

/// `.obsidian/daily-notes.json`: `folder`, `format`, `template`.
pub fn applyObsidianDaily(arena: Allocator, cfg: *VaultConfig, src: []const u8) !void {
    const o = jsonObject(arena, src) orelse return;
    if (str(o, "folder")) |p| cfg.daily_dir = trimSlashes(p);
    if (str(o, "format")) |f| if (f.len > 0) {
        cfg.daily_format = f;
    };
    if (str(o, "template")) |t| cfg.daily_template = trimSlashes(t);
}

/// `.obsidian/templates.json`: `folder`.
pub fn applyObsidianTemplates(arena: Allocator, cfg: *VaultConfig, src: []const u8) !void {
    const o = jsonObject(arena, src) orelse return;
    if (str(o, "folder")) |p| cfg.templates_dir = trimSlashes(p);
}

test "vault: note paths" {
    const v: Vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "docs/notes", .config = .{} };
    try std.testing.expect(v.isNotePath("docs/notes/a.md"));
    try std.testing.expect(v.isNotePath("docs/notes/sub/B.Markdown"));
    try std.testing.expect(!v.isNotePath("docs/notes.md"));
    try std.testing.expect(!v.isNotePath("docs/notesx/a.md"));
    try std.testing.expect(!v.isNotePath("docs/notes/a.txt"));
    try std.testing.expect(!v.isNotePath("docs/notes/.obsidian/x.md"));
    try std.testing.expectEqualStrings("sub/x.png", v.vaultRel("docs/notes/sub/x.png").?);
    const whole: Vault = .{ .id = .of(1), .root = .of(0), .rel_dir = "", .config = .{} };
    try std.testing.expect(whole.isNotePath("a.md"));
}

test "vault: obsidian settings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: VaultConfig = .{};
    try applyObsidianApp(a, &cfg, "{\"attachmentFolderPath\":\"assets/img/\",\"newFileLocation\":\"folder\",\"newFileFolderPath\":\"inbox\",\"useMarkdownLinks\":true,\"newLinkFormat\":\"relative\",\"unknown\":[1]}");
    try applyObsidianDaily(a, &cfg, "{\"folder\":\"/journal\",\"format\":\"YYYY/MM/DD\",\"template\":\"tpl/daily\"}");
    try applyObsidianTemplates(a, &cfg, "{\"folder\":\"tpl\"}");
    try applyObsidianApp(a, &cfg, "not json");
    try std.testing.expectEqualStrings("assets/img", cfg.attachments_dir);
    try std.testing.expectEqual(NewNoteDir.fixed, cfg.new_note_dir);
    try std.testing.expectEqualStrings("inbox", cfg.new_note_folder);
    try std.testing.expect(!cfg.use_wikilinks);
    try std.testing.expectEqual(LinkStyle.relative, cfg.link_style);
    try std.testing.expectEqualStrings("journal", cfg.daily_dir);
    try std.testing.expectEqualStrings("YYYY/MM/DD", cfg.daily_format);
    try std.testing.expectEqualStrings("tpl/daily", cfg.daily_template);
    try std.testing.expectEqualStrings("tpl", cfg.templates_dir);
}

test "vault: detect from vault.zon and .obsidian" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try detectVault(a, io, tmp.dir)) == null);
    try tmp.dir.createDirPath(io, ".obsidian");
    try tmp.dir.writeFile(io, .{ .sub_path = ".obsidian/app.json", .data = "{\"attachmentFolderPath\":\"/\"}" });
    const o = (try detectVault(a, io, tmp.dir)).?;
    try std.testing.expectEqualStrings("", o.attachments_dir);
    try tmp.dir.createDirPath(io, ".zigguro");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/vault.zon", .data = ".{ .daily_dir = \"journal\", .link_style = .absolute, .future_field = 1 }" });
    const z = (try detectVault(a, io, tmp.dir)).?;
    try std.testing.expectEqualStrings("journal", z.daily_dir);
    try std.testing.expectEqual(LinkStyle.absolute, z.link_style);
}
