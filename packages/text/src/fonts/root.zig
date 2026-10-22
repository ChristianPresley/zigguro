//! The `fonts` namespace of zg_text: instance ids and per-cluster
//! fallback, and font discovery. E03.F07 adds the font database and
//! matching.

const std = @import("std");

/// Instance ids for laid-out faces.
pub const registry = @import("registry.zig");
/// Fallback chains and per-cluster resolution.
pub const fallback = @import("fallback.zig");
/// Font directories, generic-family aliases and font file listing.
pub const discovery = @import("discovery.zig");
/// Linux discovery from fontconfig's XML configuration.
pub const discovery_linux = @import("discovery_linux.zig");
/// The fontconfig configuration subset discovery reads.
pub const fontconfig_xml = @import("fontconfig_xml.zig");
/// A minimal XML tokenizer.
pub const xml = @import("xml.zig");
/// The font database: scanned face metadata and coverage, persisted.
pub const db = @import("db.zig");
/// The database's binary (cache) format.
pub const db_cache = @import("db_cache.zig");
/// CSS Fonts 4 style matching and generic families.
pub const matcher = @import("matcher.zig");
/// The last-resort glyph (code point in a box).
pub const last_resort = @import("last_resort.zig");

pub const InstanceId = registry.InstanceId;
pub const FontRegistry = registry.FontRegistry;
pub const Fallback = fallback.Fallback;
pub const ChainId = fallback.ChainId;
pub const Presentation = fallback.Presentation;
pub const OsDefaults = fallback.OsDefaults;
pub const ChainStyle = fallback.ChainStyle;
pub const last_resort_instance = registry.last_resort_instance;
pub const lastResortBitmap = last_resort.lastResortBitmap;
pub const Discovery = discovery.Discovery;
pub const FileEntry = discovery.FileEntry;
pub const listFontFiles = discovery.listFontFiles;
pub const discoverLinux = discovery_linux.discoverLinux;
pub const FontDb = db.FontDb;
pub const FaceInfo = db.FaceInfo;
pub const FaceRef = db.FaceRef;
pub const ScanStats = db.ScanStats;
pub const Query = matcher.Query;
pub const Match = matcher.Match;
pub const Synth = matcher.Synth;
pub const Generics = matcher.Generics;

test {
    std.testing.refAllDecls(@This());
    _ = @import("fallback_test.zig");
    _ = @import("discovery_test.zig");
    _ = @import("db_test.zig");
    _ = @import("fallback_db_test.zig");
}
