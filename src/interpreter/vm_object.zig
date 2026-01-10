const std = @import("std");
const assert = std.debug.assert;

const accessors = @import("accessors.zig");

// TODO(speed): NaN tagging, we should be able to do:
//                 - pointers to `ObjectHeader`
//                 - booleans (false, true)
//                 - nil
//                 - i48 numbers
//                 - maybe small string optimisation?
pub const VmObject = struct {
    data: *HeapData,
};

pub const HeapData = struct {
    header: Header,

    ///
    /// `Header` could have been a `union(enum)`, but a tagged union cannot be packed.
    /// Which means the payload could have been just 32 bits at maximum.
    ///
    /// Being able to store up to 56 bits is nice, since we can fit a lot
    /// of stuff (even `SmallPtr`) in there.
    pub const Header = packed struct {
        tag: Tag,
        payload: u56,

        pub inline fn new_undefined_with_tag(tag: Tag) Header {
            return .{ .tag = tag, .payload = undefined };
        }

        pub inline fn kind(self: Header) Kind {
            // We can coerce an enum into a tagged union when
            // the fields of the tagged union have only a single known value.
            // Which is true for all cases of `Kind`.
            return self.tag;
        }

        pub inline fn as_heap_data(self: *Header) *HeapData {
            return @fieldParentPtr("header", self);
        }

        pub inline fn bytes_needed_after_header(self: Header) usize {
            return switch (self.kind()) {
                .integer => |accessor| accessor.get_bytes_count_after_header(),
                .double => |accessor| accessor.get_bytes_count_after_header(),
                .string => |accessor| accessor.get_bytes_count_after_header(.{ .header = self }),
                .class => |accessor| accessor.get_bytes_count_after_header(.{ .header = self }),
                .nil => 0,
                .generic_object => |accessor| accessor.get_bytes_count_after_header(.{ .header = self }),
                .empty_heap_segment => |accessor| accessor.get_bytes_count_after_header(),
            };
        }

        pub const Tag = std.meta.Tag(Kind);

        pub const Kind = union(enum(u8)) {
            integer: accessors.IntegerAccessor,
            double: accessors.DoubleAccessor,
            string: accessors.StringAccessor,
            nil,
            class: accessors.ClassAccessor,
            // TODO: rest of the primitives

            generic_object: accessors.GenericObjectAccessor,
            empty_heap_segment: accessors.EmptyHeapSegmentAccessor,

            pub inline fn tag(self: Kind) Tag {
                return self;
            }
        };
    };

    pub inline fn as_vm_object(self: *HeapData) VmObject {
        return VmObject{ .data = self };
    }

    pub inline fn kind(self: HeapData) Header.Kind {
        return self.header.kind();
    }

    pub fn get_after_header_ptr(self: *const HeapData, comptime Ptr: type) Ptr {
        const offset = @sizeOf(Header);
        const address = @intFromPtr(self) + offset;
        const ptr: Ptr = @ptrFromInt(address);
        return ptr;
    }
};

comptime {
    // Simplifies a lot of things (especially the alignment).
    // It is far easier to allocate header and then other fields after it for example.
    assert(@sizeOf(HeapData) == 8);
    assert(@alignOf(HeapData) == 8);
}
