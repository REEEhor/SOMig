pub const vm_object_module = @import("vm_object.zig");
pub const VmObject = vm_object_module.VmObject;
pub const Number = vm_object_module.Number;

pub const types = @import("types.zig");

pub const heap_object_module = @import("heap_object.zig");
pub const HeapObject = heap_object_module.HeapObject;
pub const OpaqueHeader = heap_object_module.OpaqueHeader;
pub const object_alignment_in_bytes = heap_object_module.object_alignment_in_bytes;

pub const helpers = @import("helpers.zig");

pub const FrameOnHeap = @import("frame_on_heap.zig").FrameOnHeap;

pub const EmptyHeapSegment = @import("empty_heap_segment.zig").EmptyHeapSegment;
