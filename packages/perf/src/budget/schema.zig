//! The typed schema of `budgets.zon`, the single registry of every
//! performance budget (E14.F01.S01.T01). Only types ZON can express are
//! used: structs, slices, strings, numbers, enums, optionals and tagged
//! unions.

const std = @import("std");

/// What a budget measures.
pub const Metric = enum {
    /// A duration in nanoseconds.
    duration_ns,
    /// A size in bytes.
    bytes,
    /// A machine-independent count (allocations, draw calls, wakeups).
    count,
    /// Events per second (wakeups/s, messages/s).
    per_second,
    /// Throughput in bytes per second.
    bytes_per_second,
    /// A percentage (CPU share, overhead).
    percent,
};

/// Which statistic of the measured distribution is compared.
pub const Stat = enum { p50, p95, p99, p999, max, mean, total };

/// Whether smaller or larger observations are better.
pub const Direction = enum { lower_is_better, higher_is_better };

/// What CI does on a violation or regression.
pub const Gate = enum {
    /// Fail the PR gate.
    block,
    /// Report in the summary, never fail.
    warn,
    /// Record the value only.
    track,
};

/// The machine a budget's absolute limit applies to.
pub const MachineClass = enum {
    /// The reference laptop (see `budgets.zon`).
    ref_laptop_2024,
    /// GitHub `ubuntu-24.04` hosted runner.
    ci_linux_x64,
    /// GitHub `windows-2025` hosted runner.
    ci_windows_x64,
    /// Machine-independent (counts such as allocations or wakeups).
    any,
};

/// A machine class description.
pub const Machine = struct {
    /// The class this row describes.
    class: MachineClass,
    /// One-line description.
    description: []const u8,
    /// CPU class.
    cpu: []const u8,
    /// Installed memory in GB.
    ram_gb: u16,
    /// GPU class.
    gpu: []const u8,
    /// Display size and refresh rate.
    display: []const u8,
};

/// A field of an E00 bench result (`docs/bench-format.md`).
pub const BenchField = enum {
    ns_per_op,
    p50_ns,
    /// Optional in schema 1 (startup and latency results write it).
    p95_ns,
    p99_ns,
    bytes_per_op,
    allocs_per_op,
    bytes_alloc_per_op,
    /// Derived: `bytes_per_op / ns_per_op * 1e9`.
    throughput_bps,
};

/// Where a budget's measurement comes from.
pub const Source = union(enum) {
    /// An E00 bench result: `suite` is the bench JSON `package`.
    bench: struct { suite: []const u8, name: []const u8, field: BenchField },
    /// A macro scenario metric (E14.F06).
    scenario: struct { name: []const u8, metric: []const u8 },
    /// Monitored live (HUD, flight recorder), or `"pending"` when no
    /// measurement exists yet.
    runtime: []const u8,
};

/// One budget row.
pub const Budget = struct {
    /// Dotted, stable, unique id such as `input.key_to_photon`.
    id: []const u8,
    /// Owning epic, `E00`..`E17`.
    owner: []const u8,
    /// The spec ID (or `CONVENTIONS`) the number comes from.
    spec: []const u8,
    /// Unit of `limit` and `target`.
    metric: Metric,
    /// Statistic compared against `limit`.
    stat: Stat,
    /// Whether lower or higher is better.
    direction: Direction = .lower_is_better,
    /// The hard limit.
    limit: f64,
    /// The goal, on the good side of `limit`.
    target: ?f64 = null,
    /// The machine the absolute limit applies to.
    machine: MachineClass = .ref_laptop_2024,
    /// Where the measurement comes from.
    source: Source,
    /// Relative regression perfgate tolerates against the baseline.
    regression_tolerance_pct: f64 = 10,
    /// CI behaviour.
    gate: Gate = .block,
    /// Free-form note (workload, caveats).
    note: []const u8 = "",
};

/// The whole registry file.
pub const File = struct {
    /// Schema version, currently 1.
    schema: u32,
    /// Machine class descriptions.
    machines: []const Machine,
    /// Every budget.
    budgets: []const Budget,
};

/// A validation failure found by `validateRuntime`.
pub const Problem = struct {
    /// What is wrong.
    kind: Kind,
    /// Index of the offending budget in `File.budgets`.
    index: usize,

    /// Problem kinds.
    pub const Kind = enum { bad_id, duplicate_id, bad_limit, target_wrong_side, empty_bench, bad_owner, bad_schema };

    /// A human-readable message for `kind`.
    pub fn message(p: Problem) []const u8 {
        return switch (p.kind) {
            .bad_id => "budget id must match ^[a-z0-9_]+(\\.[a-z0-9_]+)+$",
            .duplicate_id => "duplicate budget id",
            .bad_limit => "budget limit must be > 0",
            .target_wrong_side => "budget target is on the wrong side of limit",
            .empty_bench => "bench source needs a non-empty suite and name",
            .bad_owner => "budget owner must match ^E\\d\\d$",
            .bad_schema => "unsupported budgets.zon schema",
        };
    }
};

fn isSegChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// True when `id` matches `^[a-z0-9_]+(\.[a-z0-9_]+)+$`.
pub fn validId(id: []const u8) bool {
    var segs: usize = 0;
    var seg_len: usize = 0;
    for (id) |c| {
        if (c == '.') {
            if (seg_len == 0) return false;
            segs += 1;
            seg_len = 0;
        } else if (isSegChar(c)) {
            seg_len += 1;
        } else return false;
    }
    if (seg_len == 0) return false;
    return segs >= 1;
}

/// True when `owner` matches `^E\d\d$`.
pub fn validOwner(owner: []const u8) bool {
    return owner.len == 3 and owner[0] == 'E' and std.ascii.isDigit(owner[1]) and std.ascii.isDigit(owner[2]);
}

/// Checks `f` and returns the first problem, or null. Pure and callable at
/// comptime (the registry's `validate`) and at runtime (tests, tools).
pub fn validateRuntime(f: *const File) ?Problem {
    if (f.schema != 1) return .{ .kind = .bad_schema, .index = 0 };
    for (f.budgets, 0..) |b, i| {
        if (!validId(b.id)) return .{ .kind = .bad_id, .index = i };
        for (f.budgets[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, b.id)) return .{ .kind = .duplicate_id, .index = i };
        }
        if (!(b.limit > 0)) return .{ .kind = .bad_limit, .index = i };
        if (b.target) |t| {
            const ok = switch (b.direction) {
                .lower_is_better => t <= b.limit,
                .higher_is_better => t >= b.limit,
            };
            if (!ok) return .{ .kind = .target_wrong_side, .index = i };
        }
        switch (b.source) {
            .bench => |s| if (s.suite.len == 0 or s.name.len == 0) return .{ .kind = .empty_bench, .index = i },
            else => {},
        }
        if (!validOwner(b.owner)) return .{ .kind = .bad_owner, .index = i };
    }
    return null;
}

fn fixture(budgets: []const Budget) File {
    return .{ .schema = 1, .machines = &.{}, .budgets = budgets };
}

const ok_row: Budget = .{ .id = "a.b", .owner = "E14", .spec = "E14", .metric = .duration_ns, .stat = .p99, .limit = 10, .source = .{ .runtime = "pending" } };

test "budget: validate rejects duplicate id" {
    var bad = fixture(&.{ ok_row, ok_row });
    try std.testing.expectEqual(Problem.Kind.duplicate_id, validateRuntime(&bad).?.kind);
    try std.testing.expectEqual(@as(usize, 1), validateRuntime(&bad).?.index);
}

test "budget: validate rejects bad owner, wrong-side target, empty bench, bad id" {
    var r = ok_row;
    r.owner = "E1";
    try std.testing.expectEqual(Problem.Kind.bad_owner, validateRuntime(&fixture(&.{r})).?.kind);
    r = ok_row;
    r.target = 20;
    try std.testing.expectEqual(Problem.Kind.target_wrong_side, validateRuntime(&fixture(&.{r})).?.kind);
    r.direction = .higher_is_better;
    try std.testing.expectEqual(@as(?Problem, null), validateRuntime(&fixture(&.{r})));
    r = ok_row;
    r.source = .{ .bench = .{ .suite = "zg_core", .name = "", .field = .p99_ns } };
    try std.testing.expectEqual(Problem.Kind.empty_bench, validateRuntime(&fixture(&.{r})).?.kind);
    r = ok_row;
    r.limit = 0;
    try std.testing.expectEqual(Problem.Kind.bad_limit, validateRuntime(&fixture(&.{r})).?.kind);
    for ([_][]const u8{ "nodot", "Upper.case", "a..b", ".a", "a.", "a.b-c" }) |id| {
        r = ok_row;
        r.id = id;
        try std.testing.expectEqual(Problem.Kind.bad_id, validateRuntime(&fixture(&.{r})).?.kind);
    }
    try std.testing.expect(validId("startup.phase.e00"));
}
