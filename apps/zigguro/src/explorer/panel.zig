//! `ExplorerPanel`: the file browser (E08.F03.S01): the workspace folders
//! as a tree (`FsTree` through a `zg_gui` `TreeView`) in a side-bar dock
//! panel. A click opens a file, Enter or a double click opens it and
//! moves focus to the editor; folders open and close with a click.
//!
//! The header's toolbar and the context menu (right-click, Shift+F10)
//! run the `explorer.*` commands, which the workbench registers and binds
//! in keybindings.zon (F2 renames, Delete deletes, Ctrl+C/X/V copy, cut and paste files):
//! New File and New Folder (names may hold '/' to create subfolders),
//! Rename, Delete (asks first with `explorer.confirmDelete`), Copy Path,
//! Copy Relative Path, Refresh, Collapse All and Add or Remove Folder
//! (multi-root workspaces). Names are typed into a prompt under the
//! header; Enter applies, Escape cancels.
//!
//! The tree re-reads folders whose modification time changed (`refresh`,
//! on the workbench's poll and when the window gains focus), so files
//! made in the terminal or by the agent show up. `files.exclude`,
//! `explorer.sortOrder` and `explorer.respectGitIgnore` apply through
//! `setOptions`. UI thread only.
//!
//! Each create, rename, move and delete is reported through
//! `Hooks.file_op` before (`will`) and after (`did`) it happens, so
//! language servers can update imports and forget files (LSP
//! `workspace/will*Files` and `did*Files`). A copy is reported as a
//! create once it is made.

const std = @import("std");
const zg_gui = @import("zg_gui");
const fs_tree = @import("fs_tree.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const FsTree = fs_tree.FsTree;
const Id = fs_tree.Id;
const virtual = zg_gui.virtual;
const TreeView = virtual.TreeView;
const TreeSource = virtual.TreeSource;
const LoadDone = virtual.tree_view.LoadDone;
const ChildCount = virtual.tree_view.ChildCount;

/// What the explorer asks of its host (the workbench).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Opens the file at `abs` in an editor (`focus`: move focus there).
    open: *const fn (ctx: *anyopaque, abs: []const u8, focus: bool) void,
    /// A file or folder moved from `old` to `new` (null: deleted), so
    /// open editors can follow.
    moved: ?*const fn (ctx: *anyopaque, old: []const u8, new: ?[]const u8) void = null,
    /// Opens folder `abs` in a new window.
    open_folder: ?*const fn (ctx: *anyopaque, abs: []const u8) void = null,
    /// A file operation is about to happen or has happened (see the
    /// module doc).
    file_op: ?*const fn (ctx: *anyopaque, phase: FileOp.Phase, kind: FileOp.Kind, items: []const FileOp.Item) void = null,
};

/// A file operation the explorer reports through `Hooks.file_op`.
pub const FileOp = struct {
    pub const Phase = enum { will, did };
    pub const Kind = enum { create, rename, delete };
    /// `path` (absolute) is the file or folder; a rename's new path is
    /// `new`.
    pub const Item = struct { path: []const u8, new: ?[]const u8 = null, folder: bool = false };
};

/// See the module doc.
pub const ExplorerPanel = struct {
    gpa: Allocator,
    io: std.Io,
    tree: FsTree,
    tv: TreeView = undefined,
    hooks: Hooks,
    win: ?*Window = null,
    /// Folders whose children were asked for, listed at the next build.
    loads: std.ArrayList(Load) = .empty,
    /// The tree revision the rows were built from.
    rev_seen: u64 = 0,
    /// The name prompt, while open.
    prompt: ?Prompt = null,
    prompt_buf: zg_gui.w.TextBuffer,
    /// Focus the prompt once it is in the tree.
    focus_prompt: bool = false,
    prompt_node: zg_gui.core.NodeId = .none,
    /// Files copied or cut (absolute paths), for paste.
    clip: std.ArrayList([]u8) = .empty,
    clip_cut: bool = false,
    confirm_delete: bool = true,
    /// The last outcome shown under the header (errors).
    status: [200]u8 = undefined,
    status_len: usize = 0,
    /// Paths waiting for a delete confirmation.
    doomed: std.ArrayList([]u8) = .empty,

    const Load = struct { node: u64, done: LoadDone };

    pub const PromptKind = enum { new_file, new_folder, rename, add_folder, open_folder };

    const Prompt = struct {
        kind: PromptKind,
        /// The folder new entries go into, or the entry to rename.
        target: Id,
        invalid: bool = false,
    };

    /// An explorer of `root` (absolute). `p` must not move afterwards.
    pub fn init(p: *ExplorerPanel, gpa: Allocator, io: std.Io, root: []const u8, hooks: Hooks) !void {
        p.* = .{ .gpa = gpa, .io = io, .tree = .init(gpa, io), .hooks = hooks, .prompt_buf = try .init(gpa, "") };
        errdefer p.prompt_buf.deinit();
        errdefer p.tree.deinit();
        _ = try p.tree.addRoot(root);
        p.tv = try TreeView.init(gpa, p.source(), .{
            .label = "Explorer",
            .test_id = "explorer-tree",
            .multi = true,
            .on_open = .{ .ctx = p, .f = onOpen },
            .on_click = .{ .ctx = p, .f = onClick },
        });
        // The first folder starts open.
        _ = try p.tv.expandRow(0);
        p.rev_seen = p.tree.revision;
    }

    pub fn deinit(p: *ExplorerPanel) void {
        p.tv.deinit();
        p.tree.deinit();
        p.loads.deinit(p.gpa);
        p.prompt_buf.deinit();
        p.clearClip();
        p.clip.deinit(p.gpa);
        for (p.doomed.items) |d| p.gpa.free(d);
        p.doomed.deinit(p.gpa);
    }

    // -- the tree's data ------------------------------------------------------

    fn source(p: *ExplorerPanel) TreeSource {
        return .{ .ptr = p, .vtable = &vtable };
    }

    const vtable: TreeSource.VTable = .{
        .root_count = rootCount,
        .child_count = childCount,
        .child = child,
        .load = load,
        .label = label,
    };

    fn self(ptr: *anyopaque) *ExplorerPanel {
        return @ptrCast(@alignCast(ptr));
    }

    fn rootCount(ptr: *anyopaque) u32 {
        return @intCast(self(ptr).tree.roots.items.len);
    }

    fn childCount(ptr: *anyopaque, node: u64) ChildCount {
        const n = self(ptr).tree.get(@intCast(node)) orelse return .leaf;
        if (!n.is_dir) return .leaf;
        const c = n.children orelse return .unknown_loading;
        return .{ .known = @intCast(c.items.len) };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const t = &self(ptr).tree;
        const q = parent orelse return t.roots.items[i];
        return t.node(@intCast(q)).children.?.items[i];
    }

    /// Folders list at the next build (the tree view is mid-update now).
    fn load(ptr: *anyopaque, node: u64, done: LoadDone) void {
        const p = self(ptr);
        p.loads.append(p.gpa, .{ .node = node, .done = done }) catch return;
        if (p.win) |w| w.markAllDirty();
    }

    fn label(ptr: *anyopaque, node: u64) []const u8 {
        const n = self(ptr).tree.get(@intCast(node)) orelse return "";
        return if (n.parent == 0) std.fs.path.basename(n.name) else n.name;
    }

    // -- queries ----------------------------------------------------------------

    /// The node commands act on: the active row, or the first root.
    fn focusNode(p: *ExplorerPanel) Id {
        if (p.tv.active) |a| if (p.tree.get(@intCast(a)) != null) return @intCast(a);
        return p.tree.roots.items[0];
    }

    /// The nodes Delete, Copy and Cut act on: the selection when it holds
    /// the active row, else the active row.
    fn targets(p: *ExplorerPanel, out: *std.ArrayList(Id)) !void {
        const a = p.focusNode();
        if (p.tv.isSelected(a)) {
            for (p.tv.selection()) |s| if (p.tree.get(@intCast(s)) != null) try out.append(p.gpa, @intCast(s));
        } else try out.append(p.gpa, a);
    }

    /// The workspace folders (absolute).
    pub fn roots(p: *ExplorerPanel, out: *std.ArrayList([]const u8)) !void {
        for (p.tree.roots.items) |r| try out.append(p.gpa, p.tree.node(r).name);
    }

    // -- events -----------------------------------------------------------------

    fn onOpen(ctx: *anyopaque, node: u64) void {
        const p = self(ctx);
        const n = p.tree.get(@intCast(node)) orelse return;
        if (n.is_dir) {
            if (p.tv.flat.rowOf(node)) |i| {
                if (p.tv.flat.isExpanded(node)) _ = p.tv.collapseRow(i) else _ = p.tv.expandRow(i) catch {};
            }
            return;
        }
        p.openNode(@intCast(node), true);
    }

    fn onClick(ctx: *anyopaque, node: u64) void {
        const p = self(ctx);
        const n = p.tree.get(@intCast(node)) orelse return;
        if (!n.is_dir) p.openNode(@intCast(node), false);
    }

    fn openNode(p: *ExplorerPanel, id: Id, focus: bool) void {
        const abs = p.tree.absPath(id) catch return;
        defer p.gpa.free(abs);
        p.hooks.open(p.hooks.ctx, abs, focus);
    }

    fn say(p: *ExplorerPanel, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&p.status, fmt, args) catch p.status[0..p.status.len];
        p.status_len = s.len;
        if (p.win) |w| w.markAllDirty();
    }

    fn changed(p: *ExplorerPanel) void {
        if (p.win) |w| w.markAllDirty();
    }

    // -- commands -----------------------------------------------------------

    /// Re-reads folders that changed on disk; true when the tree changed.
    pub fn refresh(p: *ExplorerPanel) bool {
        if (!p.tree.refresh()) return false;
        p.changed();
        return true;
    }

    /// Applies `files.exclude`, `explorer.sortOrder` and
    /// `explorer.respectGitIgnore`.
    pub fn setOptions(p: *ExplorerPanel, o: fs_tree.Options) void {
        const same_globs = o.exclude.len == p.tree.opts.exclude.len and for (o.exclude, p.tree.opts.exclude) |a, b| {
            if (!std.mem.eql(u8, a, b)) break false;
        } else true;
        if (same_globs and o.sort == p.tree.opts.sort and o.respect_gitignore == p.tree.opts.respect_gitignore) return;
        p.tree.setOptions(o) catch |e| p.say("Explorer: {t}", .{e});
        p.changed();
    }

    /// Closes every folder.
    pub fn collapseAll(p: *ExplorerPanel) void {
        var i: usize = p.tv.flat.len();
        while (i > 0) {
            i -= 1;
            if (p.tv.flat.rows.items[i].flags.expanded) _ = p.tv.collapseRow(i);
        }
        p.tv.flat.expanded.clearRetainingCapacity();
        p.changed();
    }

    /// Opens the name prompt for `kind` (on the active row).
    pub fn startPrompt(p: *ExplorerPanel, kind: PromptKind) void {
        const at = p.focusNode();
        const target: Id = switch (kind) {
            .new_file, .new_folder => p.tree.targetDir(at),
            .rename => at,
            .add_folder, .open_folder => 0,
        };
        if (kind == .rename and p.tree.node(at).parent == 0) return p.say("A workspace folder cannot be renamed here", .{});
        const initial: []const u8 = switch (kind) {
            .rename => p.tree.node(at).name,
            .add_folder, .open_folder => std.fs.path.dirname(p.tree.node(p.tree.roots.items[0]).name) orelse "",
            else => "",
        };
        p.prompt_buf.setText(initial) catch return;
        p.prompt = .{ .kind = kind, .target = target };
        p.focus_prompt = true;
        p.status_len = 0;
        p.changed();
    }

    fn closePrompt(p: *ExplorerPanel) void {
        p.prompt = null;
        if (p.win) |w| if (!p.tv.node.isNone() and w.store.valid(p.tv.node)) w.setFocus(p.tv.node, false);
        p.changed();
    }

    /// Applies the prompt's name; false keeps it open (a bad name).
    fn submitPrompt(p: *ExplorerPanel) bool {
        const pr = p.prompt orelse return true;
        const name = std.mem.trim(u8, p.prompt_buf.slice(), " \t");
        if (name.len == 0) return true;
        switch (pr.kind) {
            .new_file, .new_folder => {
                if (p.tree.get(pr.target) == null) return true;
                const folder = pr.kind == .new_folder;
                if (p.tree.childPath(pr.target, name)) |will| {
                    defer p.gpa.free(will);
                    p.fileOp(.will, .create, &.{.{ .path = will, .folder = folder }});
                } else |_| {}
                const made = (if (pr.kind == .new_file) p.tree.createFile(pr.target, name) else p.tree.createDir(pr.target, name)) catch |e| {
                    p.say("{s}: {s}", .{ name, opMessage(e) });
                    return false;
                };
                defer p.gpa.free(made);
                p.fileOp(.did, .create, &.{.{ .path = made, .folder = folder }});
                p.reveal(made);
                if (pr.kind == .new_file) p.hooks.open(p.hooks.ctx, made, true);
            },
            .rename => {
                if (p.tree.get(pr.target) == null) return true;
                if (std.mem.eql(u8, p.tree.node(pr.target).name, name)) return true;
                const old = p.tree.absPath(pr.target) catch return true;
                defer p.gpa.free(old);
                const folder = p.tree.node(pr.target).is_dir;
                if (FsTree.validName(name)) if (std.fs.path.dirname(old)) |dir| {
                    if (std.fs.path.join(p.gpa, &.{ dir, name })) |will| {
                        defer p.gpa.free(will);
                        p.fileOp(.will, .rename, &.{.{ .path = old, .new = will, .folder = folder }});
                    } else |_| {}
                };
                const made = p.tree.rename(pr.target, name) catch |e| {
                    p.say("{s}: {s}", .{ name, opMessage(e) });
                    return false;
                };
                defer p.gpa.free(made);
                p.fileOp(.did, .rename, &.{.{ .path = old, .new = made, .folder = folder }});
                if (p.hooks.moved) |f| f(p.hooks.ctx, old, made);
                p.reveal(made);
            },
            .add_folder => p.addFolder(name) catch |e| {
                p.say("{s}: {t}", .{ name, e });
                return false;
            },
            .open_folder => {
                const abs = p.folderPath(name) catch |e| {
                    p.say("{s}: {t}", .{ name, e });
                    return false;
                };
                defer p.gpa.free(abs);
                if (p.hooks.open_folder) |f| f(p.hooks.ctx, abs);
            },
        }
        return true;
    }

    /// Adds `path` (absolute, or relative to the first folder) as a
    /// workspace folder.
    pub fn addFolder(p: *ExplorerPanel, path: []const u8) !void {
        const abs = try p.folderPath(path);
        defer p.gpa.free(abs);
        const id = try p.tree.addRoot(abs);
        try p.tv.reload();
        p.rev_seen = p.tree.revision;
        if (p.tv.flat.rowOf(id)) |i| {
            _ = try p.tv.expandRow(i);
            p.tv.moveTo(i, .replace);
        }
        p.changed();
    }

    /// `path` (absolute, or relative to the first folder) made absolute,
    /// when it is a folder (caller frees).
    fn folderPath(p: *ExplorerPanel, path: []const u8) ![]u8 {
        const base = p.tree.node(p.tree.roots.items[0]).name;
        const abs = try std.fs.path.resolve(p.gpa, &.{ base, path });
        errdefer p.gpa.free(abs);
        var d = std.Io.Dir.cwd().openDir(p.io, abs, .{}) catch return error.NotAFolder;
        d.close(p.io);
        return abs;
    }

    /// Removes the active row's workspace folder (not the first).
    pub fn removeFolder(p: *ExplorerPanel) void {
        const r = p.tree.rootOf(p.focusNode());
        if (r == p.tree.roots.items[0]) return p.say("The first workspace folder stays", .{});
        p.tree.removeRoot(r);
        p.changed();
    }

    /// Deletes the targets, asking first with `confirm_delete`.
    pub fn deleteSelection(p: *ExplorerPanel) void {
        var ids: std.ArrayList(Id) = .empty;
        defer ids.deinit(p.gpa);
        p.targets(&ids) catch return;
        for (p.doomed.items) |d| p.gpa.free(d);
        p.doomed.clearRetainingCapacity();
        for (ids.items) |id| {
            if (p.tree.node(id).parent == 0) continue;
            const abs = p.tree.absPath(id) catch continue;
            p.doomed.append(p.gpa, abs) catch p.gpa.free(abs);
        }
        if (p.doomed.items.len == 0) return;
        const w = p.win orelse return;
        if (!p.confirm_delete) return p.deleteDoomed();
        var msg: [400]u8 = undefined;
        const first = std.fs.path.basename(p.doomed.items[0]);
        const text = if (p.doomed.items.len == 1)
            std.fmt.bufPrint(&msg, "Delete '{s}'? This cannot be undone.", .{first}) catch "Delete it?"
        else
            std.fmt.bufPrint(&msg, "Delete '{s}' and {d} more? This cannot be undone.", .{ first, p.doomed.items.len - 1 }) catch "Delete them?";
        _ = zg_gui.w.confirm(w, .{ .title = "Delete", .message = text, .ok_label = "Delete", .danger = true }, .{ .ctx = p, .f = onConfirmDelete }) catch {};
    }

    fn onConfirmDelete(ctx: ?*anyopaque, r: zg_gui.w.dialog.Result) void {
        const p = self(ctx.?);
        if (r == .ok) p.deleteDoomed();
        if (p.win) |w| if (!p.tv.node.isNone() and w.store.valid(p.tv.node)) w.setFocus(p.tv.node, false);
    }

    fn deleteDoomed(p: *ExplorerPanel) void {
        var items: std.ArrayList(FileOp.Item) = .empty;
        defer items.deinit(p.gpa);
        for (p.doomed.items) |abs| {
            const id = p.tree.find(abs) orelse continue;
            items.append(p.gpa, .{ .path = abs, .folder = p.tree.node(id).is_dir }) catch {};
        }
        p.fileOp(.will, .delete, items.items);
        var done: usize = 0;
        for (items.items) |it| {
            const id = p.tree.find(it.path) orelse continue;
            p.tree.delete(id) catch |e| {
                p.say("{s}: {s}", .{ std.fs.path.basename(it.path), opMessage(e) });
                continue;
            };
            items.items[done] = it;
            done += 1;
            if (p.hooks.moved) |f| f(p.hooks.ctx, it.path, null);
        }
        p.fileOp(.did, .delete, items.items[0..done]);
        for (p.doomed.items) |d| p.gpa.free(d);
        p.doomed.clearRetainingCapacity();
        p.changed();
    }

    fn fileOp(p: *ExplorerPanel, phase: FileOp.Phase, kind: FileOp.Kind, items: []const FileOp.Item) void {
        if (items.len == 0) return;
        if (p.hooks.file_op) |f| f(p.hooks.ctx, phase, kind, items);
    }

    fn clearClip(p: *ExplorerPanel) void {
        for (p.clip.items) |c| p.gpa.free(c);
        p.clip.clearRetainingCapacity();
    }

    /// Remembers the targets for Paste (`cut`: move them).
    pub fn copySelection(p: *ExplorerPanel, cut: bool) void {
        var ids: std.ArrayList(Id) = .empty;
        defer ids.deinit(p.gpa);
        p.targets(&ids) catch return;
        p.clearClip();
        for (ids.items) |id| {
            if (cut and p.tree.node(id).parent == 0) continue;
            const abs = p.tree.absPath(id) catch continue;
            p.clip.append(p.gpa, abs) catch p.gpa.free(abs);
        }
        p.clip_cut = cut;
        p.changed();
    }

    pub fn canPaste(p: *const ExplorerPanel) bool {
        return p.clip.items.len > 0;
    }

    /// Copies or moves the remembered entries into the active folder.
    pub fn paste(p: *ExplorerPanel) void {
        if (p.clip.items.len == 0) return;
        const dir = p.tree.targetDir(p.focusNode());
        var last: ?[]u8 = null;
        defer if (last) |l| p.gpa.free(l);
        for (p.clip.items) |src| {
            const folder = if (std.Io.Dir.cwd().statFile(p.io, src, .{})) |st| st.kind == .directory else |_| false;
            // A move keeps its name; a copy's name is known once made.
            if (p.clip_cut) if (p.tree.childPath(dir, std.fs.path.basename(src))) |will| {
                defer p.gpa.free(will);
                if (!std.mem.eql(u8, will, src)) p.fileOp(.will, .rename, &.{.{ .path = src, .new = will, .folder = folder }});
            } else |_| {};
            const made = p.tree.paste(src, dir, p.clip_cut) catch |e| {
                p.say("{s}: {s}", .{ std.fs.path.basename(src), opMessage(e) });
                continue;
            };
            if (!p.clip_cut) {
                p.fileOp(.did, .create, &.{.{ .path = made, .folder = folder }});
            } else if (!std.mem.eql(u8, made, src)) {
                p.fileOp(.did, .rename, &.{.{ .path = src, .new = made, .folder = folder }});
            }
            if (p.clip_cut) if (p.hooks.moved) |f| f(p.hooks.ctx, src, made);
            if (last) |l| p.gpa.free(l);
            last = made;
        }
        // Cut entries move once.
        if (p.clip_cut) p.clearClip();
        if (last) |l| p.reveal(l);
        p.changed();
    }

    /// Puts the active entry's path on the clipboard (`relative`: to its
    /// workspace folder).
    pub fn copyPath(p: *ExplorerPanel, relative: bool) void {
        const w = p.win orelse return;
        const id = p.focusNode();
        const text = (if (relative) p.tree.relPath(p.gpa, id) else p.tree.absPath(id)) catch return;
        defer p.gpa.free(text);
        w.app.clipboard.set(w.gpa, text);
    }

    /// Opens the folders down to `abs` and selects it (when it is in the
    /// workspace and not hidden).
    pub fn reveal(p: *ExplorerPanel, abs: []const u8) void {
        const id = p.tree.find(abs) orelse return;
        p.syncRows();
        var chain: [64]Id = undefined;
        var n: usize = 0;
        var cur = p.tree.node(id).parent;
        while (cur != 0 and n < chain.len) : (cur = p.tree.node(cur).parent) {
            chain[n] = cur;
            n += 1;
        }
        while (n > 0) {
            n -= 1;
            const row = p.tv.flat.rowOf(chain[n]) orelse return;
            if (!p.tv.flat.isExpanded(chain[n])) _ = p.tv.expandRow(row) catch return;
        }
        const row = p.tv.flat.rowOf(id) orelse return;
        if (p.tv.active != null and p.tv.active.? == id and p.tv.isSelected(id)) return;
        p.tv.moveTo(row, .replace);
        p.changed();
    }

    /// Rebuilds the rows when the tree changed since the last time.
    fn syncRows(p: *ExplorerPanel) void {
        if (p.tree.revision == p.rev_seen) return;
        p.rev_seen = p.tree.revision;
        p.tv.reload() catch {};
    }

    // -- building -----------------------------------------------------------

    pub fn build(p: *ExplorerPanel, ui: *Ui) void {
        p.win = ui.window();
        // Folders asked for during the last frame.
        if (p.loads.items.len > 0) {
            const pending = p.loads.toOwnedSlice(p.gpa) catch &.{};
            defer p.gpa.free(pending);
            for (pending) |l| {
                if (p.tree.get(@intCast(l.node))) |_| p.tree.list(@intCast(l.node)) catch {};
                // Its own change, not one to rebuild everything for.
                p.rev_seen = p.tree.revision;
                l.done.call(l.node);
            }
        }
        p.syncRows();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_elevated } }, .role = .group, .label = "Explorer" });
        defer ui.close();
        p.header(ui);
        if (p.prompt != null) p.promptRow(ui);
        if (p.status_len > 0) {
            ui.open(.{ .style = .{ .padding = .xy(10, 2), .shrink = 0 } });
            ui.text(p.status[0..p.status_len], .{ .color = .danger });
            ui.close();
        }
        // The explorer's keys (F2, Delete, Ctrl+C/X/V) act in the tree only,
        // not in the prompt.
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "explorerTreeFocus" });
        p.contextMenu(ui);
        p.tv.build(ui);
        ui.close();
    }

    fn header(p: *ExplorerPanel, ui: *Ui) void {
        _ = p;
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .padding = .xy(10, 2), .h = .{ .px = 28 }, .shrink = 0 } });
        defer ui.close();
        ui.text("EXPLORER", .{ .color = .fg_muted, .wrap = false, .style = .{ .size = 11, .weight = 600 } });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        const tools = [_]zg_gui.w.ToolItem{
            .{ .id = "new-file", .icon = "+", .label = "New File", .tooltip = "New File", .action = "explorer.newFile", .priority = 1000 },
            .{ .id = "new-folder", .icon = "\u{25a3}", .label = "New Folder", .tooltip = "New Folder", .action = "explorer.newFolder", .priority = 1000 },
            .{ .id = "refresh", .icon = "\u{21bb}", .label = "Refresh", .tooltip = "Refresh Explorer", .action = "explorer.refresh", .priority = 1000 },
            .{ .id = "collapse", .icon = "\u{229f}", .label = "Collapse All", .tooltip = "Collapse Folders in Explorer", .action = "explorer.collapseAll", .priority = 1000 },
        };
        zg_gui.w.toolbar(ui, &tools, .{ .label = "Explorer actions", .width = 120, .test_id = "explorer-toolbar" });
    }

    fn promptRow(p: *ExplorerPanel, ui: *Ui) void {
        const pr = &p.prompt.?;
        ui.open(.{ .style = .{ .dir = .column, .gap = 2, .padding = .xy(8, 4), .shrink = 0 } });
        defer ui.close();
        var lb: [300]u8 = undefined;
        const where = if (pr.target != 0 and p.tree.get(pr.target) != null) p.tree.relPath(p.gpa, if (pr.kind == .rename) pr.target else pr.target) catch null else null;
        defer if (where) |x| p.gpa.free(x);
        const title = switch (pr.kind) {
            .new_file => std.fmt.bufPrint(&lb, "New file in {s}/", .{if (where) |x| x else ""}) catch "New file",
            .new_folder => std.fmt.bufPrint(&lb, "New folder in {s}/", .{if (where) |x| x else ""}) catch "New folder",
            .rename => std.fmt.bufPrint(&lb, "Rename {s}", .{if (where) |x| x else ""}) catch "Rename",
            .add_folder => "Add folder to workspace (path)",
            .open_folder => "Open folder in a new window (path)",
        };
        ui.text(title, .{ .color = .fg_muted, .wrap = false, .style = .{ .size = 11 } });
        const r = zg_gui.w.textField(ui, .{ .buffer = &p.prompt_buf, .invalid = pr.invalid, .a11y_label = title, .placeholder = if (pr.kind == .add_folder or pr.kind == .open_folder) "C:\\path\\to\\folder or ../other" else "name (a/b.txt makes folder a)" });
        p.prompt_node = ui.lastNode();
        if (p.focus_prompt) {
            p.focus_prompt = false;
            ui.window().afterNextFrame(.{ .ctx = p, .f = focusPrompt });
        }
        if (r.changed) pr.invalid = false;
        if (r.cancelled) return p.closePrompt();
        if (r.submitted) {
            if (p.submitPrompt()) p.closePrompt() else pr.invalid = true;
        }
    }

    fn focusPrompt(ctx: *anyopaque, w: *Window) void {
        const p = self(ctx);
        if (!p.prompt_node.isNone() and w.store.valid(p.prompt_node)) w.setFocus(p.prompt_node, true);
    }

    fn contextMenu(p: *ExplorerPanel, ui: *Ui) void {
        const at = p.focusNode();
        const n = p.tree.node(at);
        const is_root = n.parent == 0;
        const extra_root = is_root and at != p.tree.roots.items[0];
        var items: [20]zg_gui.w.MenuItem = undefined;
        var k: usize = 0;
        const add = struct {
            fn f(list: []zg_gui.w.MenuItem, i: *usize, it: zg_gui.w.MenuItem) void {
                list[i.*] = it;
                i.* += 1;
            }
        }.f;
        if (!n.is_dir) {
            add(&items, &k, .{ .action = .{ .label = "Open", .action = "explorer.open" } });
            add(&items, &k, .separator);
        }
        add(&items, &k, .{ .action = .{ .label = "New File\u{2026}", .action = "explorer.newFile" } });
        add(&items, &k, .{ .action = .{ .label = "New Folder\u{2026}", .action = "explorer.newFolder" } });
        add(&items, &k, .separator);
        add(&items, &k, .{ .action = .{ .label = "Cut", .action = "explorer.cut", .enabled = !is_root } });
        add(&items, &k, .{ .action = .{ .label = "Copy", .action = "explorer.copy" } });
        add(&items, &k, .{ .action = .{ .label = "Paste", .action = "explorer.paste", .enabled = p.canPaste() } });
        add(&items, &k, .separator);
        add(&items, &k, .{ .action = .{ .label = "Copy Path", .action = "explorer.copyPath" } });
        add(&items, &k, .{ .action = .{ .label = "Copy Relative Path", .action = "explorer.copyRelativePath" } });
        add(&items, &k, .separator);
        add(&items, &k, .{ .action = .{ .label = "Rename\u{2026}", .action = "explorer.rename", .enabled = !is_root } });
        add(&items, &k, .{ .action = .{ .label = "Delete", .action = "explorer.delete", .enabled = !is_root } });
        add(&items, &k, .separator);
        add(&items, &k, .{ .action = .{ .label = "Add Folder to Workspace\u{2026}", .action = "workspace.addFolder" } });
        if (extra_root) add(&items, &k, .{ .action = .{ .label = "Remove Folder from Workspace", .action = "workspace.removeFolder" } });
        add(&items, &k, .{ .action = .{ .label = "Refresh", .action = "explorer.refresh" } });
        zg_gui.w.contextMenu(ui, items[0..k], .{ .test_id = "explorer-menu" });
    }

    /// Opens the active file (the context menu's Open).
    pub fn openActive(p: *ExplorerPanel) void {
        const id = p.focusNode();
        if (!p.tree.node(id).is_dir) p.openNode(id, true);
    }
};

fn opMessage(e: fs_tree.OpError) []const u8 {
    return switch (e) {
        error.InvalidName => "not a valid name",
        error.AlreadyExists => "a file or folder with that name already exists",
        error.NotFound => "it no longer exists",
        error.IntoItself => "a folder cannot go into itself",
        error.OutOfMemory => "out of memory",
        error.Failed => "the file system refused",
    };
}

const testing = std.testing;

const TestHost = struct {
    opened: std.ArrayList(u8) = .empty,
    focus: bool = false,
    moves: u32 = 0,
    ops: std.ArrayList(u8) = .empty,

    fn open(ctx: *anyopaque, abs: []const u8, focus: bool) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.opened.clearRetainingCapacity();
        h.opened.appendSlice(testing.allocator, std.fs.path.basename(abs)) catch {};
        h.focus = focus;
    }
    fn moved(ctx: *anyopaque, _: []const u8, _: ?[]const u8) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.moves += 1;
    }
    /// "phase kind name[>new][/]" lines.
    fn fileOp(ctx: *anyopaque, phase: FileOp.Phase, kind: FileOp.Kind, items: []const FileOp.Item) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        for (items) |it| {
            h.ops.print(testing.allocator, "{t} {t} {s}", .{ phase, kind, std.fs.path.basename(it.path) }) catch {};
            if (it.new) |n| h.ops.print(testing.allocator, ">{s}", .{n[std.mem.lastIndexOfScalar(u8, n, std.fs.path.sep).? + 1 ..]}) catch {};
            h.ops.appendSlice(testing.allocator, if (it.folder) "/\n" else "\n") catch {};
        }
    }
};

const TestPage = struct {
    p: *ExplorerPanel,
    pub fn build(pg: *TestPage, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 300 }, .h = .{ .px = 500 }, .dir = .column } });
        defer ui.close();
        pg.p.build(ui);
    }
};

test "explorer panel: browse, open, create, rename, copy and delete" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var host: TestHost = .{};
    defer host.opened.deinit(gpa);
    defer host.ops.deinit(gpa);
    var p: ExplorerPanel = undefined;
    try p.init(gpa, io, root, .{ .ctx = &host, .open = TestHost.open, .moved = TestHost.moved, .file_op = TestHost.fileOp });
    defer p.deinit();
    p.confirm_delete = false;
    var page: TestPage = .{ .p = &p };
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .root = zg_gui.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    _ = t.settle();

    // The root is open: folders first.
    try testing.expect(t.find(.{ .role = .treeitem, .name = "src" }) != null);
    try testing.expect(t.find(.{ .role = .treeitem, .name = "README.md" }) != null);
    try testing.expect(t.find(.{ .role = .treeitem, .name = "main.zig" }) == null);

    // A click opens a folder (listed on the next frame) and a file.
    try t.click(.{ .role = .treeitem, .name = "src" });
    _ = t.settle();
    _ = t.settle();
    try testing.expect(t.find(.{ .role = .treeitem, .name = "main.zig" }) != null);
    try t.click(.{ .role = .treeitem, .name = "main.zig" });
    try testing.expectEqualStrings("main.zig", host.opened.items);
    try testing.expect(!host.focus);
    try t.doubleClick(.{ .role = .treeitem, .name = "README.md" });
    try testing.expectEqualStrings("README.md", host.opened.items);
    try testing.expect(host.focus);

    // New File in src (the active row's folder), through the prompt.
    try t.click(.{ .role = .treeitem, .name = "main.zig" });
    p.startPrompt(.new_file);
    _ = t.settle();
    _ = t.settle();
    t.typeText("lib/util.zig");
    t.press(.enter, .{});
    _ = t.settle();
    _ = t.settle();
    try testing.expect(p.prompt == null);
    _ = try tmp.dir.statFile(io, "src/lib/util.zig", .{});
    try testing.expectEqualStrings("util.zig", host.opened.items);
    try testing.expect(t.find(.{ .role = .treeitem, .name = "util.zig" }) != null);

    // A bad name keeps the prompt open.
    p.startPrompt(.rename);
    _ = t.settle();
    _ = t.settle();
    t.press(.end, .{});
    t.typeText("/x");
    t.press(.enter, .{});
    _ = t.settle();
    try testing.expect(p.prompt != null);
    t.press(.escape, .{});
    _ = t.settle();
    try testing.expect(p.prompt == null);

    // Rename util.zig.
    p.startPrompt(.rename);
    _ = t.settle();
    _ = t.settle();
    t.press(.home, .{});
    t.typeText("new_");
    t.press(.enter, .{});
    _ = t.settle();
    _ = try tmp.dir.statFile(io, "src/lib/new_util.zig", .{});
    try testing.expectEqual(@as(u32, 1), host.moves);
    try testing.expect(t.find(.{ .role = .treeitem, .name = "new_util.zig" }) != null);

    // Copy README.md into src: "README copy.md" when pasted twice.
    try t.click(.{ .role = .treeitem, .name = "README.md" });
    p.copySelection(false);
    p.paste();
    _ = t.settle();
    _ = try tmp.dir.statFile(io, "README copy.md", .{});

    // Delete it (no confirmation in this test).
    try t.click(.{ .role = .treeitem, .name = "README copy.md" });
    p.deleteSelection();
    _ = t.settle();
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "README copy.md", .{}));
    try testing.expect(t.find(.{ .role = .treeitem, .name = "README copy.md" }) == null);

    // Cut new_util.zig into the root folder.
    try t.click(.{ .role = .treeitem, .name = "new_util.zig" });
    p.copySelection(true);
    try t.click(.{ .role = .treeitem, .name = "README.md" });
    p.paste();
    _ = t.settle();
    _ = try tmp.dir.statFile(io, "new_util.zig", .{});

    // Language servers heard of each operation, before and after.
    try testing.expectEqualStrings(
        \\will create util.zig
        \\did create util.zig
        \\will rename util.zig>new_util.zig
        \\did rename util.zig>new_util.zig
        \\did create README copy.md
        \\will delete README copy.md
        \\did delete README copy.md
        \\will rename new_util.zig>new_util.zig
        \\did rename new_util.zig>new_util.zig
        \\
    , host.ops.items);

    // A file made outside shows up after a refresh.
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "x" });
    _ = p.refresh();
    _ = t.settle();
    try testing.expect(t.find(.{ .role = .treeitem, .name = "outside.txt" }) != null);
}
