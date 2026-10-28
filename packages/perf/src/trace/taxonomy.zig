//! The async span taxonomy (E14.F02.S01.T03): one name per kind of
//! asynchronous work, so agent, protocol and indexing work appear in a
//! trace exactly like editor work. The normative list with the privacy
//! rules is docs/perf/tracing-conventions.md.

const std = @import("std");
const Category = @import("categories.zig").Category;

/// An async span name.
pub const Name = enum {
    ai_turn,
    ai_request,
    ai_first_byte,
    ai_first_token,
    ai_stream,
    ai_tool_call,
    ai_tool_exec,
    ai_context_build,
    mcp_request,
    lsp_request,
    dap_request,
    net_http,
    workspace_index_job,
    scm_op,

    /// The dotted trace name: `ai_turn` is `ai.turn`.
    pub fn str(comptime n: Name) []const u8 {
        comptime {
            const tag = @tagName(n);
            var out: [tag.len]u8 = undefined;
            const i = std.mem.indexOfScalar(u8, tag, '_').?;
            @memcpy(&out, tag);
            out[i] = '.';
            const final = out;
            return &final;
        }
    }

    /// The dotted trace name at runtime.
    pub fn name(n: Name) []const u8 {
        return switch (n) {
            inline else => |c| comptime c.str(),
        };
    }

    /// The category: the first segment of the name.
    pub fn category(n: Name) Category {
        return Category.ofName(n.name());
    }
};

test "taxonomy: every Name has str, category and a row in tracing-conventions.md" {
    const doc = @import("zg_perf_docs").tracing_conventions;
    inline for (comptime std.meta.tags(Name)) |n| {
        const s = comptime n.str();
        try std.testing.expect(std.mem.indexOfScalar(u8, s, '.') != null);
        try std.testing.expect(n.category() != .other);
        // A table row "| `ai.turn` |".
        try std.testing.expect(std.mem.indexOf(u8, doc, "| `" ++ s ++ "` |") != null);
    }
    try std.testing.expectEqualStrings("workspace.index_job", Name.workspace_index_job.name());
}
