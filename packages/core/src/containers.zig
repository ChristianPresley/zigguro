//! General containers std 0.16 does not provide. Prefer std where it has a
//! type: `ArrayList`, `MultiArrayList`, `Deque`, `PriorityQueue`, hash maps
//! and `bit_set`.

/// Generational-handle dense storage.
pub const SlotMap = @import("containers/slot_map.zig").SlotMap;
/// Single-threaded fixed-capacity ring.
pub const RingBuffer = @import("containers/ring_buffer.zig").RingBuffer;
/// Lock-free single-producer/single-consumer ring.
pub const SpscRing = @import("containers/ring_buffer.zig").SpscRing;
/// String deduplication with stable ids.
pub const StringInterner = @import("containers/interner.zig").StringInterner;
/// Inline-then-heap growable array.
pub const SmallArray = @import("containers/small_array.zig").SmallArray;

test {
    _ = @import("containers/slot_map.zig");
    _ = @import("containers/ring_buffer.zig");
    _ = @import("containers/interner.zig");
    _ = @import("containers/small_array.zig");
}
