const std = @import("std");
const assert = std.debug.assert;

const objects_module = @import("__objects.zig");
const types = objects_module.types;
const HeapObject = objects_module.HeapObject;
const VmObject = objects_module.VmObject;
const OpaqueHeader = objects_module.OpaqueHeader;
const object_alignment_in_bytes = objects_module.object_alignment_in_bytes;

const pointer_after = objects_module.helpers.pointer_after;
const slice_after = objects_module.helpers.slice_after;
const allocate_heap_data = objects_module.helpers.allocate_heap_data;

const runtime_module = @import("../__runtime.zig");
const SmallPtr = runtime_module.SmallPtr;

/// Represents an empty spot in the heap.
/// Created for example by a garbage collection of some object.
///
/// Actual memory layout of this struct is:
/// ```zig
///     header: EmptyHeapSegment.Header,
///     segment_size_in_bytes: switch(self.header.size_kind) {
///         .big => u64,
///         .small => void,
///     },
///     empty_space: [size_in_bytes()-@sizeOf(Header)]u8,
/// ```
pub const EmptyHeapSegment = extern struct {
    header: Header,

    comptime {
        assert(@sizeOf(@This()) == 8);
    }

    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,

        /// The `OpaqueHeader` has a flag here for marking of objects for (not) GC,
        /// we want to ignore this to not cause badly-trackable bugs.
        _ignorred_gc_flag: bool = undefined,
        size_kind: enum(u1) {
            /// This `EmptyHeapSegment` is the size of a single `OpaqueHeader` (64 bits).
            small,
            /// This `EmptyHeapSegment` contains a u64 after the header,
            /// which describes how many bytes are free after the header.
            big,
        },
        _padding: u6 = undefined,
        next_empty_segment: SmallPtr(?*EmptyHeapSegment),
    };

    pub const tag = .empty_heap_segment;

    const Self = @This();

    pub fn create_from(params: struct {
        spot_to_free: *align(object_alignment_in_bytes) anyopaque,
        length_in_bytes: u64,
        previous_empty_segment: *EmptyHeapSegment,
    }) *EmptyHeapSegment {
        assert(params.length_in_bytes >= @sizeOf(@This()));
        const previous_empty_segment = params.previous_empty_segment;
        const next_empty_segment = previous_empty_segment.header.next_empty_segment;
        const length_in_bytes = std.mem.alignForward(u64, params.length_in_bytes, object_alignment_in_bytes);
        const self: *EmptyHeapSegment = @ptrCast(params.spot_to_free);

        previous_empty_segment.header.next_empty_segment = .init(self);

        switch (length_in_bytes) {
            @sizeOf(Header) => self.header = Header{
                .size_kind = .small,
                .next_empty_segment = next_empty_segment,
            },
            else => |total_size| {
                assert(total_size > @sizeOf(Header));
                self.header = Header{
                    .size_kind = .big,
                    .next_empty_segment = next_empty_segment,
                };
                self.after_header_size_ptr().* = total_size;
            },
        }

        return self;
    }

    /// Makes the empty heap segment longer.
    /// Parameter `bytes_to_add` must be a multiple of `object_alignment_in_bytes`.
    pub fn prolong_by_aligned_bytes(self: *Self, bytes_to_add: usize) void {
        if (bytes_to_add == 0) return;
        assert(bytes_to_add % object_alignment_in_bytes == 0);

        const old_size = self.size_in_bytes();
        self.header.size_kind = .big; // We know that any non-zero enlargement results in a `.big` empty segment
        self.after_header_size_ptr().* = old_size + bytes_to_add;
    }

    /// Makes the empty heap segment longer.
    /// Parameter `bytes_to_remove` must be a multiple of `object_alignment_in_bytes`.
    /// Also, the new size of this empty segment after the shortening cannot be zero.
    pub fn shorten_by_aligned_bytes(self: *Self, bytes_to_remove: usize) void {
        if (bytes_to_remove == 0) return;
        assert(bytes_to_remove % object_alignment_in_bytes == 0);
        assert(self.size_in_bytes() >= bytes_to_remove);

        const new_size = self.size_in_bytes() - bytes_to_remove;
        assert(new_size >= @sizeOf(Header));

        if (new_size == @sizeOf(Header)) {
            self.header.size_kind = .small;
        } else {
            self.after_header_size_ptr().* = new_size;
        }
    }

    pub fn pointer_to_after_self(self: *Self) *OpaqueHeader {
        return @ptrFromInt(@intFromPtr(self) + self.size_in_bytes());
    }

    pub const AllocateFromResult = struct {
        allocated_data: *OpaqueHeader,
        /// The allocation from the empty segment may actually allocate more bytes if
        /// the data was not aligned. This field desribes how many bytes were actually allocated.
        total_bytes_allocated: usize,
    };
    pub fn try_allocate_from(
        self: *Self,
        params: struct {
            unaligned_bytes_required: usize,
            previous_segment: *EmptyHeapSegment,
        },
    ) ?AllocateFromResult {
        const previous_segment = params.previous_segment;
        const available_bytes = self.size_in_bytes();
        const bytes_required = std.mem.alignForward(usize, params.unaligned_bytes_required, object_alignment_in_bytes);

        assert(previous_segment.header.next_empty_segment.ptr() == self);

        // Check if the allocation is possible
        if (available_bytes < bytes_required) return null;

        if (available_bytes == bytes_required) {
            // We managed to fill this entire empty segment => we have to remove ourselves from the free list
            previous_segment.header.next_empty_segment = self.header.next_empty_segment;
            return .{
                .allocated_data = @ptrCast(self),
                .total_bytes_allocated = bytes_required,
            };
        }

        // We didn't fill this entire empty segment.
        // So we allocate the space for an object *at the end* of this empty segment.
        // NOTE: We don't allocate at the beginning of this segment so that we don't have to readjust the pointers in the free list.
        self.shorten_by_aligned_bytes(bytes_required);
        const allocated_segment: *OpaqueHeader = self.pointer_to_after_self();

        return .{
            .allocated_data = allocated_segment,
            .total_bytes_allocated = bytes_required,
        };
    }

    pub fn size_in_bytes(self: *const Self) usize {
        switch (self.header.size_kind) {
            .small => return @sizeOf(Header),
            .big => {
                const total_size = self.after_header_size_ptr().*;
                return total_size;
            },
        }
    }

    pub fn after_header_size_ptr(self: *const Self) *u64 {
        assert(self.header.size_kind == .big);
        return pointer_after(self, u64);
    }
};
