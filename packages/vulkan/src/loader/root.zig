//! The runtime Vulkan loader and the dispatch tables zigguro uses
//! (E02.F01.S02).

const loader = @import("loader.zig");

pub const Loader = loader.Loader;
pub const LoadError = loader.LoadError;
pub const OpenOptions = loader.OpenOptions;
pub const Diagnostics = loader.Diagnostics;
pub const ExtSet = loader.ExtSet;
pub const loadDevice = loader.loadDevice;
pub const apiNumber = loader.apiNumber;
pub const isRequired = loader.isRequired;
pub const missingStub = loader.missingStub;
/// The command lists and table types.
pub const tables = loader.tables;
/// Opening shared libraries.
pub const dynlib = @import("dynlib.zig");

test {
    _ = loader;
    _ = dynlib;
    _ = @import("gpu_test.zig");
}
