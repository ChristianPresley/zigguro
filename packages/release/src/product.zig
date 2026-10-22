//! Product constants, comptime-imported from `packaging/product.zon` (the
//! build exposes it as the module `zg_product_zon`). That file is the only
//! place the app id, AUMID, update feeds, release keys and OAuth
//! identifiers are written; everything else reads them from here.

const std = @import("std");

/// One file extension zigguro registers an association for.
pub const FileAssociation = struct {
    /// Extension with its leading dot, e.g. ".zig".
    ext: []const u8,
    /// MIME type, e.g. "text/x-zig".
    mime: []const u8,
    /// Human-readable type description shown by the OS.
    description: []const u8,
};

/// OAuth identifiers other epics need (E09, E11).
pub const OAuth = struct {
    /// GitHub OAuth device-flow client id (E09). Empty until registered.
    github_client_id: []const u8,
    /// URL of the OAuth Client ID Metadata Document hosted on the feed site (E11).
    cimd_url: []const u8,
};

/// The shape of `packaging/product.zon`.
pub const Product = struct {
    /// Reverse-DNS application id: Wayland app_id, `.desktop` basename (E01).
    app_id: []const u8,
    /// Windows AppUserModelID (Company.Product, no spaces).
    aumid: []const u8,
    /// Name shown to users.
    display_name: []const u8,
    /// Publisher shown in Apps & features and VERSIONINFO.
    publisher: []const u8,
    /// X11 WM_CLASS class part (E01.F05.S02.T01).
    wm_class: []const u8,
    /// Project home page.
    homepage: []const u8,
    /// "New issue" URL used for crash sharing.
    issues_url: []const u8,
    /// Update feed URL templates; `{channel}` is replaced by the channel.
    update_feeds: []const []const u8,
    /// Minisign public keys ("RW..."), newest first.
    release_keys: []const []const u8,
    /// Symbols download URL template with `{version}` and `{target}`.
    symbols_url_template: []const u8,
    /// OAuth identifiers.
    oauth: OAuth,
    /// File extensions zigguro offers to open.
    file_associations: []const FileAssociation,
};

/// The product constants of this build.
pub const product: Product = @import("zg_product_zon");

/// Expands `{channel}` in an update feed template into `buf`.
pub fn feedUrl(buf: []u8, template: []const u8, channel: []const u8) error{NoSpaceLeft}![]const u8 {
    return expand(buf, template, &.{.{ "{channel}", channel }});
}

/// Expands `{version}` and `{target}` in `product.symbols_url_template`.
pub fn symbolsUrl(buf: []u8, version: []const u8, target: []const u8) error{NoSpaceLeft}![]const u8 {
    return expand(buf, product.symbols_url_template, &.{ .{ "{version}", version }, .{ "{target}", target } });
}

fn expand(buf: []u8, template: []const u8, vars: []const [2][]const u8) error{NoSpaceLeft}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    outer: while (i < template.len) {
        for (vars) |v| {
            if (std.mem.startsWith(u8, template[i..], v[0])) {
                w.writeAll(v[1]) catch return error.NoSpaceLeft;
                i += v[0].len;
                continue :outer;
            }
        }
        w.writeByte(template[i]) catch return error.NoSpaceLeft;
        i += 1;
    }
    return w.buffered();
}

const testing = std.testing;

test "product: constants load from product.zon" {
    try testing.expectEqualStrings("dev.zigguro.zigguro", product.app_id);
    try testing.expectEqualStrings("Zigguro.Zigguro", product.aumid);
    try testing.expect(std.mem.indexOfScalar(u8, product.aumid, ' ') == null);
    try testing.expect(product.aumid.len <= 128);
    try testing.expect(product.update_feeds.len >= 1);
    for (product.update_feeds) |u| try testing.expect(std.mem.startsWith(u8, u, "https://"));
    for (product.file_associations) |a| {
        try testing.expect(a.ext[0] == '.');
        try testing.expect(std.mem.indexOfScalar(u8, a.mime, '/') != null);
    }
}

test "product: url templates" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "https://christianpresley.github.io/zigguro/updates/v1/stable.json",
        try feedUrl(&buf, product.update_feeds[0], "stable"),
    );
    try testing.expectEqualStrings(
        "https://github.com/ChristianPresley/zigguro/releases/download/v0.4.0/zigguro-0.4.0-x86_64-linux-symbols.tar.gz",
        try symbolsUrl(&buf, "0.4.0", "x86_64-linux"),
    );
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, feedUrl(&tiny, product.update_feeds[0], "stable"));
}
