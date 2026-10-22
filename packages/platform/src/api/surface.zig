//! The presentation contract between zg_platform and the renderer (E02).
//! Every backend implements `PresenterVTable`: Wayland and X11 put E02's
//! exported images on screen, Win32 and headless provide CPU buffers.
//! This file declares types only.

const types = @import("types.zig");
const WindowId = types.WindowId;
const PxRect = types.PxRect;

/// Where E02 renders a window's frames.
pub const SurfaceTarget = union(enum) {
    /// Win32: E02 creates a `VK_KHR_win32_surface` swapchain itself.
    win32: struct {
        /// The module's `HINSTANCE`.
        hinstance: *anyopaque,
        /// The window's `HWND`.
        hwnd: *anyopaque,
    },
    /// Wayland and X11: E02 renders into exportable images and hands them
    /// to this presenter.
    external: *Presenter,
    /// Offscreen: frames go to a sink that tests read back.
    headless: *HeadlessSink,
    /// macOS (later): a `CAMetalLayer`.
    metal_layer: *anyopaque,
};

/// A presenter: a type-erased `PresenterVTable` implementation.
pub const Presenter = struct {
    /// Backend state.
    ptr: *anyopaque,
    /// Backend functions.
    vtable: *const PresenterVTable,

    /// See `PresenterVTable.drmDevice`.
    pub fn drmDevice(p: Presenter) ?DrmDevice {
        return p.vtable.drmDevice(p.ptr);
    }
    /// See `PresenterVTable.formats`.
    pub fn formats(p: Presenter, out: []FormatModifier) usize {
        return p.vtable.formats(p.ptr, out);
    }
    /// See `PresenterVTable.syncMode`.
    pub fn syncMode(p: Presenter) SyncMode {
        return p.vtable.syncMode(p.ptr);
    }
    /// See `PresenterVTable.importBuffer`.
    pub fn importBuffer(p: Presenter, desc: *const BufferDesc) anyerror!BufferHandle {
        return p.vtable.importBuffer(p.ptr, desc);
    }
    /// See `PresenterVTable.present`.
    pub fn present(p: Presenter, buf: BufferHandle, damage: []const PxRect, acquire: SyncPoint, ack: ?ConfigureAck) anyerror!void {
        return p.vtable.present(p.ptr, buf, damage, acquire, ack);
    }
    /// See `PresenterVTable.releaseBuffer`.
    pub fn releaseBuffer(p: Presenter, buf: BufferHandle) void {
        p.vtable.releaseBuffer(p.ptr, buf);
    }
    /// See `PresenterVTable.pollReleased`.
    pub fn pollReleased(p: Presenter, out: []BufferHandle) usize {
        return p.vtable.pollReleased(p.ptr, out);
    }
    /// See `PresenterVTable.allocCpuBuffer`.
    pub fn allocCpuBuffer(p: Presenter, w: u32, h: u32, fourcc: u32) anyerror!CpuBuffer {
        return p.vtable.allocCpuBuffer(p.ptr, w, h, fourcc);
    }
};

/// The functions every presenter implements.
pub const PresenterVTable = struct {
    /// The main/sampling DRM device from dmabuf feedback, so E02 picks the
    /// matching `VkPhysicalDevice`; null without dmabuf.
    drmDevice: *const fn (*anyopaque) ?DrmDevice,
    /// Writes the DRM fourcc + modifier pairs the compositor accepts into
    /// `out` and returns how many were written.
    formats: *const fn (*anyopaque, out: []FormatModifier) usize,
    /// How E02 must synchronise with presentation.
    syncMode: *const fn (*anyopaque) SyncMode,
    /// Registers one ring image (dmabuf planes or an shm fd). Called once
    /// per image, not per frame.
    importBuffer: *const fn (*anyopaque, desc: *const BufferDesc) anyerror!BufferHandle,
    /// Presents `buf` once `acquire` signals. `damage` lists changed
    /// rectangles (empty means everything). `ack` is set on the first
    /// present after a configure at the new size.
    present: *const fn (*anyopaque, buf: BufferHandle, damage: []const PxRect, acquire: SyncPoint, ack: ?ConfigureAck) anyerror!void,
    /// Forgets an imported or allocated buffer.
    releaseBuffer: *const fn (*anyopaque, buf: BufferHandle) void,
    /// Writes buffers the compositor, X server or OS released since the
    /// last call into `out`; returns the count. Callable from any thread.
    pollReleased: *const fn (*anyopaque, out: []BufferHandle) usize,
    /// Allocates a CPU-visible buffer owned by zg_platform (memfd + wl_shm,
    /// MIT-SHM, a DIB section, or plain memory on headless).
    allocCpuBuffer: *const fn (*anyopaque, w: u32, h: u32, fourcc: u32) anyerror!CpuBuffer,
};

/// A CPU-visible buffer from `allocCpuBuffer`.
pub const CpuBuffer = struct {
    /// Handle to pass to `present`.
    handle: BufferHandle,
    /// The pixels, `stride * height` bytes.
    pixels: []u8,
    /// Bytes per row.
    stride: u32,
};

/// Ties a present to the configure it answers. Passed back by E02 with the
/// first present at the new size (Wayland `ack_configure`, Win32 resize
/// throttling).
pub const ConfigureAck = struct {
    /// The configured window.
    win: WindowId,
    /// The configure serial from `Event.window_configure`.
    serial: u32,
};

/// A buffer being imported.
pub const BufferDesc = struct {
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
    /// DRM fourcc, such as `XRGB8888`.
    fourcc: u32,
    /// DRM format modifier (`DRM_FORMAT_MOD_LINEAR` is 0).
    modifier: u64,
    /// One entry per plane.
    planes: []const Plane,
    /// How the planes are shared.
    kind: BufferKind,
};

/// How an imported buffer's memory is shared.
pub const BufferKind = enum(u8) {
    /// Linux dmabuf file descriptors.
    dmabuf,
    /// Shared memory file descriptors (memfd).
    shm,
};

/// One plane of an imported buffer.
pub const Plane = struct {
    /// File descriptor; ownership stays with the caller.
    fd: i32,
    /// Byte offset of the plane in `fd`.
    offset: u32,
    /// Bytes per row.
    stride: u32,
};

/// When a presented buffer is ready to read.
pub const SyncPoint = union(enum) {
    /// A `wp_linux_drm_syncobj_v1` timeline point.
    syncobj: struct {
        /// The timeline's DRM syncobj fd.
        timeline_fd: i32,
        /// The point to wait for.
        point: u64,
    },
    /// A sync_file fd, attached through implicit sync.
    sync_file: i32,
    /// The buffer is ready now (CPU rendering, or E02 waited already).
    none,
};

/// The synchronisation the presenter supports, best first.
pub const SyncMode = enum(u8) {
    /// Explicit sync via `wp_linux_drm_syncobj_v1`.
    drm_syncobj,
    /// Implicit sync: E02 imports a sync_file into the dmabuf.
    implicit_sync_file,
    /// No GPU sync: E02 waits on the CPU before presenting.
    none_cpu_wait,
    /// No dmabuf at all: render to `allocCpuBuffer` buffers.
    cpu_only,
};

/// A DRM device, as a `dev_t` split into major and minor.
pub const DrmDevice = struct {
    /// Device major number.
    major: u32,
    /// Device minor number.
    minor: u32,
};

/// A DRM format and modifier pair.
pub const FormatModifier = struct {
    /// DRM fourcc.
    fourcc: u32,
    /// DRM format modifier.
    modifier: u64,
};

/// A presenter's handle to an imported or allocated buffer.
pub const BufferHandle = enum(u32) { _ };

/// Where the headless backend sends presented frames.
pub const HeadlessSink = struct {
    /// Sink state.
    ptr: *anyopaque,
    /// Receives each presented frame; `pixels` is `stride * height` bytes of
    /// premultiplied BGRA and is only valid during the call.
    write: *const fn (*anyopaque, win: WindowId, damage: []const PxRect, pixels: []const u8, stride: u32) void,
};
