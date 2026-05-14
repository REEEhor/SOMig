//! Namespace with all heap allocated types

const std = @import("std");
const assert = std.debug.assert;

const objects_module = @import("__objects.zig");
const HeapObject = objects_module.HeapObject;
const OpaqueHeader = objects_module.OpaqueHeader;
const FrameOnHeap = objects_module.FrameOnHeap;
const EmptyHeapSegment = objects_module.EmptyHeapSegment;
const VmObject = objects_module.VmObject;

const pointer_after = objects_module.helpers.pointer_after;
const slice_after = objects_module.helpers.slice_after;
const allocate_heap_data = objects_module.helpers.allocate_heap_data;

const runtime_module = @import("../__runtime.zig");
const ClassDefinition = runtime_module.ClassDefinition;
const SmallPtr = runtime_module.SmallPtr;
const BlockDefinition = runtime_module.BlockDefinition;
const Stack = runtime_module.Stack;
const MethodDefinition = runtime_module.MethodDefinition;

/// Actual fields when allocated via `create_new` are:
/// ```zig
///     header: Header,
///     class: *ClassDefinition,
///     instance_field[0]: VmObject,
///     instance_field[1]: VmObject,
///     instance_field[2]: VmObject,
///     instance_field[3]: VmObject,
///     ...
///     instance_field[header.number_of_instance_fields-1]: VmObject,
/// ```
pub const GenericObject = extern struct {
    header: Header,
    class: *ClassDefinition,

    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,
        is_marked: bool = false,
        _padding: u7 = undefined,
        number_of_instance_fields: i48,

        pub fn object_size_in_bytes(header: @This()) usize {
            const length: usize = @intCast(header.number_of_instance_fields);
            return @sizeOf(GenericObject) + length * @sizeOf(VmObject);
        }
    };

    pub const tag: HeapObject.Tag = .generic_object;

    pub fn create_new(allocator: anytype, class: *ClassDefinition) std.mem.Allocator.Error!VmObject {
        const number_of_instance_fields: i48 = @intCast(class.identifiers_of_instance_variables.len);
        const self: *GenericObject = @ptrCast(try allocate_heap_data(allocator, Header{
            .number_of_instance_fields = number_of_instance_fields,
        }));
        self.class = class;
        @memset(self.get_fields(), VmObject.nil);
        return VmObject.from(self);
    }

    pub fn get_fields(self: *Self) []VmObject {
        const length: usize = @intCast(self.header.number_of_instance_fields);
        return slice_after(self, VmObject, length);
    }

    pub fn gc_mark_references(self: *Self) void {
        for (self.get_fields()) |field_object| {
            field_object.gc_mark_as_reachable_ignore_if_class_or_method();
        }
    }

    const Self = @This();
};

/// Actual fields when allocated via `create_new` are:
/// ```zig
///     header: Header,
///     represented_class: *ClassDefinition,
///     class_of_represented_class: *ClassDefinition,
///     class_fields_of_represented_class[0]: VmObject,
///     class_fields_of_represented_class[1]: VmObject,
///     class_fields_of_represented_class[2]: VmObject,
///     class_fields_of_represented_class[3]: VmObject,
///     ...
///     class_fields_of_represented_class[header.number_of_class_fields-1]: VmObject,
/// ```
pub const Class = extern struct {
    header: Header,
    represented_class: *ClassDefinition,
    class_of_represented_class: *ClassDefinition,

    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,
        is_marked: bool = false,
        _padding: u7 = undefined,
        number_of_class_fields: i48,

        pub fn object_size_in_bytes(header: @This()) usize {
            const cnt: usize = @intCast(header.number_of_class_fields);
            return @sizeOf(Class) + cnt * @sizeOf(VmObject);
        }
    };

    pub const tag: HeapObject.Tag = .class;

    pub fn create_new(
        allocator: anytype,
        params: struct {
            represented_class: *ClassDefinition,
            class_of_represented_class: *ClassDefinition,
            class_fields_count: i48,
        },
    ) std.mem.Allocator.Error!VmObject {
        const number_of_class_fields: i48 = params.class_fields_count;
        var self: *Class = @ptrCast(try allocate_heap_data(allocator, Header{
            .number_of_class_fields = number_of_class_fields,
        }));
        self.class_of_represented_class = params.class_of_represented_class;
        self.represented_class = params.represented_class;

        for (self.get_class_fields()) |*field_object| {
            field_object.* = VmObject.nil;
        }

        params.represented_class.as_vm_object = self;
        return VmObject.from(self);
    }

    pub fn get_class_fields(self: *Self) []VmObject {
        const length: usize = @intCast(self.header.number_of_class_fields);
        return slice_after(self, VmObject, length);
    }

    pub fn gc_mark_references(self: *Self) void {
        _ = self;
        @compileError("Mark all `class.get_class_fields()` manually.");
    }

    const Self = @This();
};

/// Actual fields when allocated via `create_new` are:
/// ```zig
///     header: Header,
///     array_items[0]: VmObject,
///     array_items[1]: VmObject,
///     array_items[2]: VmObject,
///     array_items[3]: VmObject,
///     ...
///     array_items[header.length-1]: VmObject,
/// ```
pub const Array = extern struct {
    header: Header,

    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,
        is_marked: bool = false,
        _padding: u7 = undefined,
        length: i48,

        pub fn object_size_in_bytes(header: @This()) usize {
            const length: usize = @intCast(header.length);
            return @sizeOf(Array) + length * @sizeOf(VmObject);
        }
    };

    pub const tag: HeapObject.Tag = .array;

    pub fn create_new(allocator: anytype, items_to_copy: []VmObject) std.mem.Allocator.Error!VmObject {
        const length: i48 = @intCast(items_to_copy.len);
        const self: *Array = @ptrCast(try allocate_heap_data(allocator, Header{ .length = length }));
        const items: []VmObject = self.get_items();
        @memcpy(items, items_to_copy);
        return VmObject.from(self);
    }

    pub fn create_with_undefined_items(allocator: anytype, length: usize) std.mem.Allocator.Error!*Array {
        const self: *Array = @ptrCast(try allocate_heap_data(allocator, Header{ .length = @intCast(length) }));
        return self;
    }

    pub fn get_items(self: *Self) []VmObject {
        const length: usize = @intCast(self.header.length);
        return slice_after(self, VmObject, length);
    }

    pub fn gc_mark_references(self: *Self) void {
        for (self.get_items()) |item| {
            item.gc_mark_as_reachable_ignore_if_class_or_method();
        }
    }

    const Self = @This();
};

/// Actual fields when allocated via `create_new` or `create_new_fmt` are:
/// ```zig
///     header: Header,
///     contents[0]: u8,
///     contents[1]: u8,
///     contents[2]: u8,
///     contents[3]: u8,
///     ...
///     contents[header.length-1]: u8,
/// ```
pub const String = extern struct {
    header: Header,

    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,
        is_marked: bool = false,
        _padding: u7 = undefined,
        length: i48,

        pub fn object_size_in_bytes(header: @This()) usize {
            const length: usize = @intCast(header.length);
            return @sizeOf(Array) + length * @sizeOf(u8);
        }
    };

    pub const tag: HeapObject.Tag = .string;

    pub fn create_with_undefined_contents(allocator: anytype, length: i48) std.mem.Allocator.Error!*String {
        const self: *String = @ptrCast(try allocate_heap_data(allocator, Header{ .length = length }));
        return self;
    }

    pub fn create_new(allocator: anytype, contents_to_copy: []const u8) std.mem.Allocator.Error!VmObject {
        const self: *String = try create_with_undefined_contents(allocator, @intCast(contents_to_copy.len));
        @memcpy(self.contents(), contents_to_copy);
        return VmObject.from(self);
    }

    pub fn create_new_fmt(allocator: anytype, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!VmObject {
        const length = std.fmt.count(fmt, args);
        const self: *String = try create_with_undefined_contents(allocator, @intCast(length));
        const res = std.fmt.bufPrint(self.contents(), fmt, args) catch unreachable;
        assert(res.len == self.contents().len);
        return VmObject.from(self);
    }

    pub fn contents(self: *Self) []u8 {
        const length: usize = @intCast(self.header.length);
        return slice_after(self, u8, length);
    }
    pub fn gc_mark_references(_: *Self) void {
        // Nothing to mark
    }

    const Self = @This();
};

pub const Block = extern struct {
    header: Header,
    block_definition: *const BlockDefinition,
    home_frame: *Stack.Frame,

    /// Next blocks which is also consider to be escaping from
    /// its home frame.
    ///
    /// The `Block` might be a part of an intrusive list
    /// which tracks all blocks, that are escaping from their home context.
    ///
    /// The first potential item of this list is in `Stack.Frame.escaping_blocks_list_head` of the frame `self.home_frame`.
    next_escaping_block: ?*Block = null,

    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,
        is_marked: bool = false,
        has_escaped_home_context: bool = false,
        _padding: u6 = undefined,
        next_of_previous_escaping_block: SmallPtr(?*?*Block) = .init(null),

        pub fn object_size_in_bytes(header: @This()) usize {
            _ = header;
            return @sizeOf(Block);
        }
    };

    pub const tag: HeapObject.Tag = .block;

    pub fn create_new(
        allocator: anytype,
        block_definition: *const BlockDefinition,
        parent_frame: *Stack.Frame,
    ) std.mem.Allocator.Error!VmObject {
        const self: *Block = @ptrCast(try allocate_heap_data(allocator, Header{}));
        self.block_definition = block_definition;
        self.home_frame = parent_frame;
        self.next_escaping_block = null;
        return VmObject.from(self);
    }

    /// Marks the block as a block that will **probably** "escape" by adding it to the escaping blocks list of its home frame.
    /// Meaning the block will most likely out-live the lifetime of its home frame (of type `*Stack.Frame`) that is on the stack.
    /// That home frame will have to then get relocated to the heap when it gets poppped from the frame stack in the future.
    pub fn add_to_escaping_blocks_list(self: *Block) void {
        if (self.header.has_escaped_home_context) return; // The block has already escaped, no one touches the escaping block list once the frame is on the heap
        if (self.header.next_of_previous_escaping_block.ptr() != null) return; // The block currently actually is inside the list => don't add it again
        assert(self.next_escaping_block == null); // Since we are not in a list, we shouldn't have a pointer to the next item

        const ptr_to_head: *?*Block = &self.home_frame.escaping_blocks_list_head;
        self.header.next_of_previous_escaping_block = .init(ptr_to_head);

        if (ptr_to_head.*) |previously_first_block| {
            previously_first_block.header.next_of_previous_escaping_block = .init(&self.next_escaping_block);
            self.next_escaping_block = previously_first_block;
        }

        ptr_to_head.* = self;
    }

    pub fn remove_from_potential_escaping_blocks_list(self: *Self) void {
        if (self.header.has_escaped_home_context) return; // No one touches the escaping block list once the frame is on the heap
        const next_of_previous_block: *?*Block = self.header.next_of_previous_escaping_block.ptr() orelse return; // We are not in a list
        assert(next_of_previous_block.* == self);

        if (self.next_escaping_block) |next_block| {
            next_block.header.next_of_previous_escaping_block = .init(next_of_previous_block);
        }
        next_of_previous_block.* = self.next_escaping_block;
        self.header.next_of_previous_escaping_block = .init(null);
        self.next_escaping_block = null;
    }

    pub fn home_method(self: *Block) *const MethodDefinition {
        sw: switch (self.home_frame.kind) {
            .method => |method| return method,
            .block => |block| continue :sw block.home_frame.kind,
        }
    }

    pub fn home_method_frame(self: *Self) *Stack.Frame {
        var it_frame = self.home_frame;
        while (true) switch (it_frame.kind) {
            .method => return it_frame,
            .block => |block| it_frame = block.home_frame,
        };
    }

    pub fn gc_mark_references(self: *Self) void {
        if (!self.header.has_escaped_home_context) return;

        const frame_header = FrameOnHeap.header_from_frame(self.home_frame);
        frame_header.gc_mark_as_reachable();
    }

    const Self = @This();
};

pub const Method = extern struct {
    header: Header,

    pub const Header = packed struct(u64) {
        tag: HeapObject.Tag = tag,
        is_marked: bool = false,
        _padding: u7 = undefined,
        method: SmallPtr(*const MethodDefinition),

        pub fn object_size_in_bytes(header: @This()) usize {
            _ = header;
            return @sizeOf(Header);
        }
    };

    pub const tag = HeapObject.Tag.method;

    pub fn create_new(allocator: anytype, method_definition: *MethodDefinition) std.mem.Allocator.Error!VmObject {
        const self: *Method = @ptrCast(try allocate_heap_data(allocator, Header{
            .method = SmallPtr(*const MethodDefinition).init(method_definition),
        }));
        method_definition.as_vm_object = self;
        return VmObject.from(self);
    }

    pub fn method(self: *Self) *const MethodDefinition {
        return self.header.method.ptr();
    }

    pub fn is_primitive(self: *Self) bool {
        return self.method().body == .primitive;
    }

    const Self = @This();
};
