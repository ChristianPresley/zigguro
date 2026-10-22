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

pub const InstanceId = registry.InstanceId;
pub const FontRegistry = registry.FontRegistry;
pub const Fallback = fallback.Fallback;
pub const ChainId = fallback.ChainId;
pub const Presentation = fallback.Presentation;
pub const Discovery = discovery.Discovery;
pub const FileEntry = discovery.FileEntry;
pub const listFontFiles = discovery.listFontFiles;
pub const discoverLinux = discovery_linux.discoverLinux;

test {
    std.testing.refAllDecls(@This());
    _ = @import("fallback_test.zig");
    _ = @import("discovery_test.zig");
}
