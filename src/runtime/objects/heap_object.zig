const std = @import("std");
const assert = std.debug.assert;

const objects_module = @import("__objects.zig");
const types = objects_module.types;
const FrameOnHeap = objects_module.FrameOnHeap;
const EmptyHeapSegment = objects_module.EmptyHeapSegment;

const pointer_after = objects_module.helpers.pointer_after;
const slice_after = objects_module.helpers.slice_after;
const allocate_heap_data = objects_module.helpers.allocate_heap_data;

/// Tag of the `HeapObject` - prefer to use the `HeapObject.Tag`.
/// This enum is defined separatelly because implicit definition via `const HeapObject = union(enum(u64)) {...}` causes dependency-loop compile errors.
/// These might be caused by the field `tag` in the payloads of the `HeapObject` variants, such as `types.String.Header.tag`.
const TagOfHeapObject = enum(u8) {
    array,
    block,
    class,
    method,
    string,
    generic_object,
    frame_header,
    empty_heap_segment,
};

pub const HeapObject = union(TagOfHeapObject) {
    array: *types.Array,
    block: *types.Block,
    class: *types.Class,
    method: *types.Method,
    string: *types.String,
    generic_object: *types.GenericObject,

    frame_header: *FrameOnHeap.Header,
    empty_heap_segment: *EmptyHeapSegment,

    pub fn tag(self: Self) Tag {
        return std.meta.activeTag(self);
    }

    pub fn Accessor(comptime t: Tag) type {
        const PayloadType = @FieldType(HeapObject, @tagName(t));
        return struct {
            pub fn get(_: @This(), opaque_header: *OpaqueHeader) PayloadType {
                return opaque_header.asserted_cast_to(t);
            }
        };
    }

    pub const Fetch = blk: {
        const UnionField = std.builtin.Type.UnionField;
        const original_fields: []const UnionField = @typeInfo(HeapObject).@"union".fields;
        var fields: [original_fields.len]UnionField = undefined;
        for (original_fields, &fields) |original_field, *new_field| {
            const tag_name = original_field.name;
            const tag_value: Tag = std.meta.stringToEnum(Tag, original_field.name).?;
            new_field.* = UnionField{
                .name = tag_name,
                .type = Accessor(tag_value),
                .alignment = @alignOf(void),
            };
        }
        break :blk @Type(.{ .@"union" = .{
            .tag_type = Tag,
            .decls = &.{},
            .layout = .auto,
            .fields = &fields,
        } });
    };

    pub const Tag = TagOfHeapObject;
    const Self = @This();
};

/// Header which is at the beginning of every heap allocated segment (or a free segment that is on the heap).
/// All heap allocated runtime objects must contain a header at their beginning which can be casted to this struct.
pub const OpaqueHeader = packed struct(u64) {
    tag: HeapObject.Tag,
    is_marked: bool,
    /// Other objects can reuse the spot of this field to store additional info (usualy used for the total size of the object)
    _padding: u55,

    pub fn identify_heap_object(header: *OpaqueHeader) HeapObject {
        return switch (header.tag) {
            inline else => |kind_tag| {
                const tag_name = @tagName(kind_tag);
                const PayloadType = @FieldType(HeapObject, tag_name);
                const casted_header: PayloadType = @ptrCast(header);
                return @unionInit(HeapObject, tag_name, casted_header);
            },
        };
    }

    pub fn fetch(header: *OpaqueHeader) HeapObject.Fetch {
        return header.tag; // Implicit cast from `HeapObject.Tag` to `HeapObject.Fetch`
    }

    pub fn ObjectHeaderWithTag(comptime tag: HeapObject.Tag) type {
        const Object = KindPayloadOf(tag);
        if (Object == *FrameOnHeap.Header) return Object;
        return std.meta.Child(Object).Header;
    }
    pub fn asserted_cast_to_header_of(header: *OpaqueHeader, comptime tag: HeapObject.Tag) ObjectHeaderWithTag(tag) {
        const object = asserted_cast_to(header, tag);
        if (@TypeOf(object) == *FrameOnHeap.Header) return object;
        return object.header;
    }

    pub fn KindPayloadOf(comptime tag: HeapObject.Tag) type {
        return @FieldType(HeapObject, @tagName(tag));
    }
    pub fn asserted_cast_to(header: *OpaqueHeader, comptime tag: HeapObject.Tag) KindPayloadOf(tag) {
        assert(header.tag == tag);
        return @ptrCast(header);
    }

    pub fn segment_size_in_bytes(opaque_header: *OpaqueHeader) usize {
        switch (opaque_header.tag) {
            .empty_heap_segment => {
                const empty_segment: *EmptyHeapSegment = opaque_header.asserted_cast_to(.empty_heap_segment);
                return empty_segment.size_in_bytes();
            },
            inline else => |tag| {
                const header = opaque_header.asserted_cast_to_header_of(tag);
                const unaligned_size = header.object_size_in_bytes();
                return std.mem.alignForward(usize, unaligned_size, object_alignment_in_bytes);
            },
        }
    }
};

/// All heap allocated objects must have this alignment
pub const object_alignment_in_bytes = 8;

comptime {
    // Simplifies a lot of things (especially the alignment).
    // It is far easier to allocate header and then other fields after it for example.
    assert(@sizeOf(OpaqueHeader) == 8);
    assert(@alignOf(OpaqueHeader) == object_alignment_in_bytes);
}
