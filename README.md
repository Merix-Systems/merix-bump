# Merix Bump

A small, source-only Zig bump allocator over a fixed `[]u8` buffer owned by the caller. The caller must keep the backing buffer alive for the allocator and every slice it returns.

## Contract

- `BumpAllocator.init(buffer)` creates an allocator over caller-owned storage.
- `alloc(size, alignment)` supports positive, power-of-two alignment and aligns the absolute address; the buffer itself need not start aligned.
- A zero-size request returns `error.ZeroSize`; an invalid alignment returns `error.InvalidAlignment`.
- Insufficient capacity or address, padding, or size arithmetic overflow returns `error.OutOfSpace`.
- A failed allocation does not advance the cursor. `used()` includes alignment padding.
- Allocations cannot be freed individually. `reset()` rewinds the allocator without clearing the buffer.
- This v1 is single-owner and unsynchronized; resizing, individual frees, and a CLI are out of scope.

The allocator uses `_buffer` and `_cursor` to mark its state fields as internal by convention. Zig still exposes them to importing code; do not mutate them directly, since doing so can violate allocator invariants. Making state truly opaque would require a different API design and is outside this v1.

## Build and test

Use Zig 0.17.0. From this directory, run:

```sh
zig test bump.zig
zig fmt --check bump.zig
```

## Example

```zig
const bump = @import("bump.zig");

var storage: [1024]u8 = undefined;
var arena = bump.BumpAllocator.init(storage[0..]);
const bytes = try arena.alloc(32, 16);
```
