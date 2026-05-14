const std = @import("std");
const assert = std.debug.assert;

const objects_module = @import("__objects.zig");
const types = objects_module.types;
const HeapObject = objects_module.HeapObject;
const VmObject = objects_module.VmObject;

const pointer_after = objects_module.helpers.pointer_after;
const slice_after = objects_module.helpers.slice_after;
const allocate_heap_data = objects_module.helpers.allocate_heap_data;

const runtime_module = @import("../__runtime.zig");
const Stack = runtime_module.Stack;

/// Just a namespace for manipulating a `Stack.Frame` which has been moved
/// to the heap. We need to at least sometimes put a stack frame on a heap,
/// because of blocks (lambdas) in SOM, which escape their home context
/// (home context == stack frame in which the block was created).
///
/// Sadly, `FrameOnHeap` cannot be a struct like other `VmObject`s,
/// and accessed just via casting `*OpaqueHeader`to `*FrameOnHeap`, since:
///     - `Stack.Frame` contains a tagged union (which we don't want to remove, it's really handy),
///     - but a tagged union has unspecified memory layout,
///     - therefore `Stack.Frame` cannot be an `extern struct`,
///     - therefore `FrameOnHeap` cannot be an `extern struct`,
///     - therefore `FrameOnHeap.Header` could not be ensured
///         to be at front of the `Stack.Frame` in this hypothetical `FrameOnHeap` object.
/// ... but we need the header to be at the front for garbage collection (the ability to iterate through heap).
///
/// The namespace `FrameOnHeap` and `FrameOnHeap.Header` have methods for accessing
/// individual parts (header, frame, and local+argument variables).
///
/// The actual memory layout of heap allocated stackframe is this:
/// ```zig
///     header: Header,
///     frame: Stack.Frame,
///     locals_and_args[0]: VmObject,
///     locals_and_args[1]: VmObject,
///     locals_and_args[2]: VmObject,
///     locals_and_args[3]: VmObject,
///     ...
///     locals_and_args[header.number_of_locals-1]: VmObject,
/// ```
pub const FrameOnHeap = struct {
    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,
        is_marked: bool = false,

        /// Number of local variables (including arguments) of the frame.
        /// These are stored right after the `Stack.Frame`
        number_of_locals: u55,

        pub fn object_size_in_bytes(header: @This()) usize {
            return @sizeOf(Header) + @sizeOf(Stack.Frame) + header.number_of_locals * @sizeOf(VmObject);
        }

        pub fn frame_ptr(header_ptr: *const @This()) *Stack.Frame {
            return frame_from_header(header_ptr);
        }

        pub fn gc_mark_as_reachable(header: *@This()) void {
            if (header.is_marked) return;
            header.is_marked = true;

            const frame = FrameOnHeap.frame_from_header(header);
            switch (frame.kind) {
                .block => |block| VmObject.from(block).gc_mark_as_reachable_ignore_if_class_or_method(),
                .method => {},
            }

            for (FrameOnHeap.get_arguments_and_locals(header)) |local| {
                local.gc_mark_as_reachable_ignore_if_class_or_method();
            }
        }
    };

    pub const tag = HeapObject.Tag.frame_header;

    comptime {
        // We want to put the header right before the `Stack.Frame`.
        // For that we need these comptime asserts.
        // When the asserts pass, we know that we can find the `Header` at `pointer_to_frame - @sizeOf(Header)`.
        // We also need these asserts so that `Header.object_size_in_bytes()` can just sum up the size of `Header` and `Stack.Frame`
        // to get the result.
        assert(@alignOf(Stack.Frame) == 8);
        assert(@alignOf(Header) == 8);
        assert(@sizeOf(Header) == 8);
    }

    pub fn header_from_frame(frame_ptr: *const Stack.Frame) *Header {
        const frame_ptr_as_int: usize = @intFromPtr(frame_ptr);
        const header_ptr_as_int: usize = frame_ptr_as_int - @sizeOf(Header);
        const header_ptr: *Header = @ptrFromInt(header_ptr_as_int);
        return header_ptr;
    }

    pub fn frame_from_header(header: *const Header) *Stack.Frame {
        const header_ptr_as_int: usize = @intFromPtr(header);
        const frame_ptr_as_int: usize = header_ptr_as_int + @sizeOf(Header);
        const frame_ptr: *Stack.Frame = @ptrFromInt(frame_ptr_as_int);
        return frame_ptr;
    }

    pub fn get_arguments_and_locals(header_ptr_or_frame_ptr: anytype) []VmObject {
        const frame_ptr: *Stack.Frame, const header_ptr: *Header = switch (@TypeOf(header_ptr_or_frame_ptr)) {
            *Header, *const Header => .{ frame_from_header(header_ptr_or_frame_ptr), header_ptr_or_frame_ptr },
            *Stack.Frame, *const Stack.Frame => .{ header_ptr_or_frame_ptr, header_from_frame(header_ptr_or_frame_ptr) },
            else => |Invalid| @compileError(std.fmt.comptimePrint("Invalid type: `{s}`", .{@typeName(Invalid)})),
        };
        const length: u55 = header_ptr.number_of_locals;

        const values = slice_after(frame_ptr, VmObject, length);
        assert(values.ptr == frame_ptr.base_ptr);
        return values;
    }

    pub fn reallocate_frame_to_heap(allocator: anytype, frame: Stack.Frame) std.mem.Allocator.Error!*Stack.Frame {
        const header_ptr: *Header = try allocate_heap_data(allocator, Header{
            .number_of_locals = @truncate(frame.number_of_args_and_locals()),
        });
        const frame_ptr: *Stack.Frame = frame_from_header(header_ptr);
        frame_ptr.* = frame;

        // Move the locals onto the heap
        const new_locals: []VmObject = slice_after(frame_ptr, VmObject, header_ptr.number_of_locals);
        @memcpy(new_locals, frame.base_ptr[0..new_locals.len]);
        frame_ptr.base_ptr = new_locals.ptr;

        return frame_ptr;
    }
};
