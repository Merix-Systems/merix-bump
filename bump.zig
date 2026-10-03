//! A caller-buffered, aligned bump allocator for small systems projects.

const std = @import("std");

/// Errors returned by `BumpAllocator.alloc`.
///
/// `ZeroSize` rejects zero-byte requests; `InvalidAlignment` rejects zero or
/// non-power-of-two alignments; `OutOfSpace` covers insufficient capacity and
/// any address, padding, or size arithmetic overflow. Failed allocations never
/// advance the allocator cursor.
pub const AllocError = error{
    OutOfSpace,
    InvalidAlignment,
    ZeroSize,
};

/// A minimal bump allocator over storage owned and kept alive by the caller.
///
/// Allocations are never individually freed. Call `reset` to reuse the whole
/// buffer. Reset changes only the cursor; it does not clear the bytes.
pub const BumpAllocator = struct {
    _buffer: []u8,
    _cursor: usize = 0,

    /// Initialize an allocator over caller-owned storage.
    pub fn init(buffer: []u8) BumpAllocator {
        return .{ ._buffer = buffer };
    }

    /// Allocate `size` bytes at an absolute address divisible by `alignment`.
    ///
    /// `alignment` must be a nonzero power of two. Zero-byte requests return
    /// `ZeroSize`. Invalid alignment returns `InvalidAlignment`. Requests that
    /// do not fit, or whose address/padding/size arithmetic overflows, return
    /// `OutOfSpace`. On every error the cursor is unchanged.
    pub fn alloc(self: *BumpAllocator, size: usize, alignment: usize) AllocError![]u8 {
        if (size == 0) return error.ZeroSize;
        if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
            return error.InvalidAlignment;
        }

        // Align the absolute address, not just the offset: the caller's slice
        // may itself begin at an address that is not aligned to `alignment`.
        const current_address = checkedAdd(@intFromPtr(self._buffer.ptr), self._cursor) orelse {
            return error.OutOfSpace;
        };
        const mask = alignment - 1;
        const remainder = current_address & mask;
        const padding = if (remainder == 0) 0 else alignment - remainder;
        const start = checkedAdd(self._cursor, padding) orelse return error.OutOfSpace;
        const end = checkedAdd(start, size) orelse return error.OutOfSpace;

        if (end > self._buffer.len) return error.OutOfSpace;

        // Commit only after all checked arithmetic and capacity validation pass.
        self._cursor = end;
        return self._buffer[start..end];
    }

    /// Reset the allocator for reuse without clearing the backing bytes.
    pub fn reset(self: *BumpAllocator) void {
        self._cursor = 0;
    }

    /// Return the number of backing-buffer bytes consumed, including padding.
    pub fn used(self: *const BumpAllocator) usize {
        return self._cursor;
    }
};

fn checkedAdd(a: usize, b: usize) ?usize {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

// Select a window whose starting address is deliberately misaligned to the
// requested power-of-two boundary, regardless of the raw array's own address.
fn misalignedWindow(raw: []u8, alignment: usize, len: usize) []u8 {
    const mask = alignment - 1;
    const remainder = @intFromPtr(raw.ptr) & mask;
    const to_next_aligned = (alignment - remainder) & mask;
    const start = to_next_aligned + 1;
    return raw[start .. start + len];
}

test "allocations satisfy absolute alignments from a deliberately misaligned base" {
    var raw: [128]u8 = undefined;
    const buffer = misalignedWindow(raw[0..], 16, 96);
    try std.testing.expect((@intFromPtr(buffer.ptr) & 15) != 0);

    var allocator = BumpAllocator.init(buffer);
    const alignments = [_]usize{ 1, 2, 4, 8, 16 };
    for (alignments) |alignment| {
        const allocation = try allocator.alloc(1, alignment);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(allocation.ptr) % alignment);
        try std.testing.expectEqual(@as(usize, 1), allocation.len);
    }
}

test "exact fit succeeds when alignment padding consumes the remaining space" {
    var raw: [32]u8 = undefined;
    const buffer = misalignedWindow(raw[0..], 8, 8);
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(buffer.ptr) & 7);

    var allocator = BumpAllocator.init(buffer);
    _ = try allocator.alloc(1, 1);
    const aligned = try allocator.alloc(1, 8);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) & 7);
    try std.testing.expectEqual(@as(usize, 8), allocator.used());
    try std.testing.expectError(error.OutOfSpace, allocator.alloc(1, 1));
    try std.testing.expectEqual(@as(usize, 8), allocator.used());
}

test "plain exact fit succeeds" {
    var storage: [16]u8 = undefined;
    var allocator = BumpAllocator.init(storage[0..]);

    const allocation = try allocator.alloc(storage.len, 1);
    try std.testing.expectEqual(storage.len, allocation.len);
    try std.testing.expectEqual(storage.len, allocator.used());
    try std.testing.expectError(error.OutOfSpace, allocator.alloc(1, 1));
    try std.testing.expectEqual(storage.len, allocator.used());
}

test "padding-induced exhaustion leaves the cursor unchanged" {
    var raw: [32]u8 = undefined;
    const buffer = misalignedWindow(raw[0..], 8, 8);
    var allocator = BumpAllocator.init(buffer);

    _ = try allocator.alloc(1, 1);
    try std.testing.expectEqual(@as(usize, 1), allocator.used());

    // Six bytes of padding plus two payload bytes would exceed the 8-byte
    // window. Failure must not commit the padding or advance the cursor.
    try std.testing.expectError(error.OutOfSpace, allocator.alloc(2, 8));
    try std.testing.expectEqual(@as(usize, 1), allocator.used());

    const final_byte = try allocator.alloc(1, 8);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(final_byte.ptr) & 7);
    try std.testing.expectEqual(@as(usize, 8), allocator.used());
}

test "zero size and invalid alignments are explicit errors without mutation" {
    var storage: [16]u8 = undefined;
    var allocator = BumpAllocator.init(storage[0..]);

    try std.testing.expectError(error.ZeroSize, allocator.alloc(0, 1));
    try std.testing.expectEqual(@as(usize, 0), allocator.used());
    try std.testing.expectError(error.InvalidAlignment, allocator.alloc(1, 0));
    try std.testing.expectEqual(@as(usize, 0), allocator.used());
    try std.testing.expectError(error.InvalidAlignment, allocator.alloc(1, 3));
    try std.testing.expectEqual(@as(usize, 0), allocator.used());
}

test "size arithmetic overflow returns out of space without mutation" {
    var storage: [8]u8 = undefined;
    var allocator = BumpAllocator.init(storage[0..]);

    _ = try allocator.alloc(1, 1);
    try std.testing.expectEqual(@as(usize, 1), allocator.used());

    const largest_size = ~@as(usize, 0);
    try std.testing.expectError(error.OutOfSpace, allocator.alloc(largest_size, 1));
    try std.testing.expectEqual(@as(usize, 1), allocator.used());
}

test "reset permits reuse of the full buffer" {
    var storage: [12]u8 = undefined;
    var allocator = BumpAllocator.init(storage[0..]);

    _ = try allocator.alloc(8, 4);
    try std.testing.expect(allocator.used() > 0);

    allocator.reset();
    try std.testing.expectEqual(@as(usize, 0), allocator.used());
    const allocation = try allocator.alloc(storage.len, 1);
    try std.testing.expectEqual(storage.len, allocation.len);
    try std.testing.expectEqual(storage.len, allocator.used());
}

test "sequential allocations are distinct and non-overlapping" {
    var storage: [16]u8 = undefined;
    var allocator = BumpAllocator.init(storage[0..]);

    const first = try allocator.alloc(4, 1);
    const second = try allocator.alloc(3, 1);

    try std.testing.expect(first.ptr != second.ptr);
    const first_end = @intFromPtr(first.ptr) + first.len;
    const second_start = @intFromPtr(second.ptr);
    try std.testing.expect(first_end <= second_start);

    @memset(first, 0xA1);
    @memset(second, 0xB2);
    try std.testing.expectEqual(@as(u8, 0xA1), storage[0]);
    try std.testing.expectEqual(@as(u8, 0xA1), storage[3]);
    try std.testing.expectEqual(@as(u8, 0xB2), storage[4]);
    try std.testing.expectEqual(@as(u8, 0xB2), storage[6]);
    try std.testing.expectEqual(@as(usize, 7), allocator.used());
}

test "used-byte accounting includes alignment padding" {
    var raw: [32]u8 = undefined;
    const buffer = misalignedWindow(raw[0..], 8, 16);
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(buffer.ptr) & 7);

    var allocator = BumpAllocator.init(buffer);
    _ = try allocator.alloc(1, 1);
    try std.testing.expectEqual(@as(usize, 1), allocator.used());

    const aligned = try allocator.alloc(1, 8);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) & 7);
    // The second allocation uses six bytes of padding and one payload byte.
    try std.testing.expectEqual(@as(usize, 8), allocator.used());
}

test "empty buffer reports out of space without advancing" {
    var storage: [0]u8 = .{};
    var allocator = BumpAllocator.init(storage[0..]);

    try std.testing.expectError(error.OutOfSpace, allocator.alloc(1, 1));
    try std.testing.expectEqual(@as(usize, 0), allocator.used());
}

test "reset preserves backing bytes and permits reuse of the same region" {
    var storage: [8]u8 = undefined;
    var allocator = BumpAllocator.init(storage[0..]);

    const first = try allocator.alloc(4, 1);
    @memcpy(first, &[_]u8{ 0x11, 0x22, 0x33, 0x44 });

    allocator.reset();
    try std.testing.expectEqual(@as(usize, 0), allocator.used());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, storage[0..4]);

    const reused = try allocator.alloc(4, 1);
    try std.testing.expectEqual(first.ptr, reused.ptr);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, reused);
    reused[0] = 0xFE;
    try std.testing.expectEqual(@as(u8, 0xFE), storage[0]);
    try std.testing.expectEqual(@as(usize, 4), allocator.used());
}
