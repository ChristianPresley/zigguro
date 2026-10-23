//! Per-note metadata (E08.F06.S01.T01): what `extract` finds in one note.
//! Every slice lives in the allocator `extract` was given (an arena per
//! note in the index); none points into the note's bytes.

const std = @import("std");
const zg_workspace = @import("zg_workspace");
const frontmatter = @import("zg_frontmatter").frontmatter;

pub const FileId = zg_workspace.FileId;

pub const PropertyType = enum { text, list, number, checkbox, date, datetime, tags, aliases, unknown };

pub const Property = struct {
    name: []const u8,
    ty: PropertyType,
    node: frontmatter.Node,
};

pub const TagRef = struct {
    /// Case-folded (`Projects/Alpha` and `projects/alpha` share a key).
    key: []const u8,
    /// As written, without `#`.
    display: []const u8,
    /// The `#tag` bytes in the note, or the frontmatter value's range.
    src: [2]u32,
    in_frontmatter: bool = false,
};

pub const Heading = struct {
    level: u8,
    /// Inline markup stripped.
    text: []const u8,
    /// The heading line (excluding EOL).
    src: [2]u32,
    line: u32,
};

pub const BlockId = struct {
    id: []const u8,
    /// The block (paragraph, list item, quote or table) it names.
    range: [2]u32,
    /// The `^id` marker itself.
    marker: [2]u32,
    line: u32,
};

pub const Task = struct {
    /// The raw status character: ' ', 'x', 'X', '/', '-', '>' or another.
    status: u8,
    /// The item text after `[ ] `.
    text: [2]u32,
    line: u32,

    pub fn done(t: Task) bool {
        return t.status == 'x' or t.status == 'X';
    }
};

pub const Subpath = union(enum) {
    /// `#A#B`: nested heading path, outermost first.
    heading: []const []const u8,
    /// `#^id`.
    block: []const u8,
};

pub const LinkKind = enum { wiki, embed, markdown, markdown_embed };

pub const Link = struct {
    kind: LinkKind,
    /// The target as written, percent-decoded for Markdown links; empty
    /// for `[[#Heading]]` (the note itself).
    target: []const u8,
    subpath: ?Subpath = null,
    alias: ?[]const u8 = null,
    /// The whole link.
    src: [2]u32,
    /// The target text (what a rename rewrites).
    target_src: [2]u32,
    line: u32,
    /// The line the link is on (backlink context).
    context: [2]u32 = .{ 0, 0 },
    /// Markdown destinations: written in `<...>`, or with `%XX` escapes.
    angle: bool = false,
    encoded: bool = false,
};

pub const NoteMeta = struct {
    /// Set by the index; `FileId.none` from `extract`.
    id: FileId = .none,
    title: []const u8,
    aliases: []const []const u8,
    tags: []const TagRef,
    props: []const Property,
    headings: []const Heading,
    blocks: []const BlockId,
    links: []const Link,
    tasks: []const Task,
    /// `http(s):`, `mailto:` and other URLs (for agents).
    external_links: []const []const u8,
    word_count: u32,
    /// The frontmatter block (fences included).
    fm_range: ?[2]u32,
    /// Frontmatter problems (the note still indexed).
    fm_diagnostics: u32 = 0,

    /// The property named `name` (case-insensitive, as Obsidian).
    pub fn prop(m: *const NoteMeta, name: []const u8) ?*const Property {
        for (m.props) |*p| if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
        return null;
    }

    /// Whether the note has tag `key` (folded) or a tag nested under it.
    pub fn hasTag(m: *const NoteMeta, key: []const u8) bool {
        for (m.tags) |t| {
            if (std.mem.eql(u8, t.key, key)) return true;
            if (t.key.len > key.len and std.mem.startsWith(u8, t.key, key) and t.key[key.len] == '/') return true;
        }
        return false;
    }

    /// The section of heading `i`: from its line to the next heading of
    /// the same or a higher level (`body_end` when none).
    pub fn sectionRange(m: *const NoteMeta, i: usize, body_end: u32) [2]u32 {
        const h = m.headings[i];
        for (m.headings[i + 1 ..]) |n| if (n.level <= h.level) return .{ h.src[0], n.src[0] };
        return .{ h.src[0], body_end };
    }
};
