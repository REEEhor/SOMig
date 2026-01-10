const std = @import("std");
const assert = std.debug.assert;

const vm_object_module = @import("vm_object.zig");
const HeapData = vm_object_module.HeapData;
const VmObject = vm_object_module.VmObject;
const Header = HeapData.Header;

const SmallPtr = @import("small_ptr.zig").SmallPtr;

const class_definition_module = @import("class_definition.zig");
const ClassDefinition = class_definition_module.ClassDefinition;

pub fn AllocateHeapDataFn(comptime ContextType: type) type {
    return fn (context: ContextType, header: Header) error{OutOfMemory}!*HeapData;
}

pub const EmptyHeapSegmentAccessor = struct {
    const Self = @This();
    pub inline fn get_bytes_count_after_header(self: Self) usize {
        _ = self;
        return 0;
    }

    /// WARN: the pointer is not mutable (the pointee is), use `set_next_empty_slot` to set the pointer
    pub inline fn get_next_empty_slot(self: Self, heap_data: *const HeapData) ?*HeapData {
        _ = self;
        const small_ptr = SmallPtr(?*HeapData){ .bits = @truncate(heap_data.header.payload) };
        return small_ptr.pointee();
    }

    pub inline fn set_next_empty_slot(
        self: Self,
        heap_data: *const HeapData,
        new_ptr: ?*HeapData,
    ) void {
        _ = self;
        const small_ptr = SmallPtr(?*HeapData).new(new_ptr);
        heap_data.header.payload = small_ptr.bits;
    }
};

pub const GenericObjectAccessor = struct {
    pub const Self = @This();

    pub fn new_object(
        context: anytype,
        alloc_function: AllocateHeapDataFn(@TypeOf(context)),
        class_of_object: *ClassDefinition,
        default_field_object: VmObject,
    ) error{OutOfMemory}!VmObject {
        const self = Self{};
        const instance_fields_count: u32 = @intCast(class_of_object.fields_count_including_parents());

        var header = Header.new_undefined_with_tag(.generic_object);
        self.set_instance_variables_count(header.as_heap_data(), instance_fields_count);
        const new_object_data: *HeapData = try alloc_function(context, header);
        self.set_class_definition(new_object_data, class_of_object);

        // Set all instance fields to the default object:
        for (0..instance_fields_count) |idx| {
            self.set_instance_var_with_idx(new_object_data, @intCast(idx), default_field_object);
        }

        const object: VmObject = new_object_data.as_vm_object();
        return object;
    }

    pub inline fn get_bytes_count_after_header(self: Self, heap_data: HeapData) usize {
        const instance_vars_cnt = self.get_instance_variables_count(heap_data);
        const total_size_in_bytes = (@sizeOf(VmObject) * instance_vars_cnt) + @sizeOf(*ClassDefinition);
        return total_size_in_bytes;
    }

    pub inline fn get_instance_variables_count(self: Self, heap_data: HeapData) u32 {
        _ = self;
        return @truncate(heap_data.header.payload);
    }

    /// WARN: This does not affect the actual number of items, just sets the field describing the number of variables the object holds.
    pub inline fn set_instance_variables_count(self: Self, heap_data: *HeapData, new_count: u32) void {
        _ = self;
        heap_data.header.payload = new_count;
    }

    pub inline fn get_class_definition(self: Self, heap_data: *const HeapData) *ClassDefinition {
        _ = self;
        return heap_data.get_after_header_ptr(**ClassDefinition).*;
    }

    pub inline fn set_class_definition(self: Self, heap_data: *HeapData, class: *ClassDefinition) void {
        _ = self;
        heap_data.get_after_header_ptr(**ClassDefinition).* = class;
    }

    pub inline fn get_instance_var_with_idx(self: Self, heap_data: *const HeapData, instance_var_idx: u32) VmObject {
        assert(instance_var_idx < self.get_instance_variables_count(heap_data.*));
        const instances = heap_data.get_after_header_ptr([*]VmObject);
        return instances[instance_var_idx + 1]; // `+1` since we store the `*ClassDefinition` at the index 0
    }

    pub inline fn set_instance_var_with_idx(self: Self, heap_data: *HeapData, instance_var_idx: u32, object: VmObject) void {
        assert(instance_var_idx < self.get_instance_variables_count(heap_data.*));
        const instances = heap_data.get_after_header_ptr([*]VmObject);
        instances[instance_var_idx + 1] = object; // `+1` since we store the `*ClassDefinition` at the index 0
    }
};

/// TODO(consultation): read the TODO below this one and ask if it is correct or not
/// TODO: This is probably not exactly correct according to the SOM class hiearchy (with Metaclasses and such), so consider chaning it later.
///
/// Same as a generic object, but `*ClassDefinition` which can be accessed
/// does not point to the primitive class `Class` but to the `ClassDefinition`
/// which is represented by the SOM runtime object.
///
pub const ClassAccessor = GenericObjectAccessor;

pub const IntegerAccessor = packed struct {
    pub inline fn get_bytes_count_after_header(self: IntegerAccessor) usize {
        _ = self;
        return 0;
    }
    pub inline fn get_value(self: IntegerAccessor, heap_data: *const HeapData) i48 {
        _ = self;
        const truncated: u48 = @truncate(heap_data.header.payload);
        return @bitCast(truncated);
    }
    pub inline fn set_value(self: IntegerAccessor, heap_data: *HeapData, value: i48) void {
        _ = self;
        const raw: u48 = @bitCast(value);
        heap_data.header.payload = raw;
    }
};

pub const DoubleAccessor = struct {
    pub inline fn get_bytes_count_after_header(self: DoubleAccessor) usize {
        _ = self;
        return @sizeOf(f64);
    }
    pub inline fn value_ptr(self: DoubleAccessor, heap_data: *HeapData) *f64 {
        _ = self;
        const ptr: *f64 = heap_data.get_after_header_ptr(*f64);
        return ptr;
    }
    pub inline fn get_value(self: DoubleAccessor, heap_data: *const HeapData) f64 {
        _ = self;
        const ptr: *f64 = heap_data.get_after_header_ptr(*f64);
        const value = ptr.*;
        return value;
    }
    pub inline fn set_value(self: DoubleAccessor, heap_data: *HeapData, value: f64) void {
        self.value_ptr(heap_data).* = value;
    }
};

pub const StringAccessor = packed struct {
    const Self = @This();

    pub fn new_string(
        context: anytype,
        alloc_function: AllocateHeapDataFn(@TypeOf(context)),
        new_string_contents: []const u8,
    ) error{OutOfMemory}!VmObject {
        const self = Self{};

        var header = HeapData.Header.new_undefined_with_tag(.string);
        self.set_length(header.as_heap_data(), @intCast(new_string_contents.len));
        const result_object_data: *HeapData = try alloc_function(context, header);
        @memcpy(self.contents(result_object_data), new_string_contents);

        const object: VmObject = result_object_data.as_vm_object();
        return object;
    }

    pub fn get_length(self: Self, heap_data: HeapData) i48 {
        _ = self;
        const raw: u48 = @truncate(heap_data.header.payload);
        const length: i48 = @bitCast(raw);
        return length;
    }

    pub fn get_length_usize(self: Self, heap_data: HeapData) usize {
        const length_signed: i48 = self.get_length(heap_data);
        return @intCast(length_signed);
    }

    pub fn set_length(self: Self, heap_data: *HeapData, new_length: i48) void {
        _ = self;
        const raw: u48 = @bitCast(new_length);
        heap_data.header.payload = raw;
    }

    pub fn get_bytes_count_after_header(self: Self, heap_data: HeapData) usize {
        return @intCast(self.get_length(heap_data));
    }

    pub fn contents(self: Self, heap_data: *HeapData) []u8 {
        // TODO: check that this works even when `self.length == 0`
        const ptr: [*]u8 = heap_data.get_after_header_ptr([*]u8);
        const length: usize = self.get_length_usize(heap_data.*);
        const slice: []u8 = ptr[0..length];
        return slice;
    }
};
