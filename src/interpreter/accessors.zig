//!
//! An "accessor" is a zero-sized struct, which has methods for accessing (getting and setting) properties of runtime objects.
//! This results in a bit of a bloated code, since we write a lot of getters and setters,
//! but the accessors are quite convinient to use and are typesafe.
//!
//! The type safety is nice, since the runtime objects are defined in a low level way
//! and there is a non trivial amount of bit manipulation going on.
//!
//! See `VmObject` and `HeapData.Header` for more info.
//!

const std = @import("std");
const assert = std.debug.assert;

const codegen_module = @import("../frontend/codegen.zig");
const InstructionId = codegen_module.InstructionId;
const BlockDefinition = codegen_module.BlockDefinition;

const interpreter_module = @import("__interpreter.zig");
const Stack = interpreter_module.Stack;

const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;

const vm_object_module = @import("vm_object.zig");
const HeapData = vm_object_module.HeapData;
const VmObject = vm_object_module.VmObject;
const Header = HeapData.Header;

const SmallPtr = @import("small_ptr.zig").SmallPtr;

const class_definition_module = @import("class_definition.zig");
const ClassDefinition = class_definition_module.ClassDefinition;
const FunctionBody = class_definition_module.FunctionBody;

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

/// The structure of an `VmObject` representing a class is this:
///    .__________________________.__________________________.__________________________.__________________________.__________________________.
///    | Header                   | *ClassDefinition         | *ClassDefinition         | VmObject (class var 1)   | VmObject (class var 2)   |
///    |--------------------------|--------------------------|--------------------------|--------------------------|--------------------------|
///    | - tag=.class             | The class that the       | The class of the         |                          |                          |
///    | - class_variables_count  | VmObject represents      | VmObject represents.     |                          |                          |  ... (the rest of class variables)
///    |                          |                          |                          |                          |                          |
///    |                          |                          | Contains the methods     |                          |                          |
///    |                          |                          | of the VmObject.         |                          |                          |
///    |__________________________|__________________________|__________________________|__________________________|__________________________|
///
pub const ClassAccessor = packed struct {
    pub const Self = @This();

    pub fn get_bytes_count_after_header(self: Self, heap_data: HeapData) usize {
        const class_vars_count = self.get_class_variables_count(heap_data);

        // We need space for two pointers to `ClassDefinition` and for the class variables
        const total_size_in_bytes = 2 * @sizeOf(*ClassDefinition) + (@sizeOf(VmObject) * class_vars_count);
        return total_size_in_bytes;
    }

    pub fn get_class_variables_count(self: Self, heap_data: HeapData) u32 {
        _ = self;
        return @truncate(heap_data.header.payload);
    }

    /// WARN: This does not affect the actual number of items, just sets the field describing the number of variables the object holds.
    pub fn set_class_variables_count(self: Self, heap_data: *HeapData, new_count: u32) void {
        _ = self;
        heap_data.header.payload = new_count;
    }

    pub fn get_represented_class(self: Self, heap_data: *const HeapData) *ClassDefinition {
        _ = self;
        const ptr = heap_data.get_after_header_ptr([*]*ClassDefinition);
        return ptr[0];
    }

    pub fn set_represented_class(self: Self, heap_data: *HeapData, class: *ClassDefinition) void {
        _ = self;
        const ptr = heap_data.get_after_header_ptr([*]*ClassDefinition);
        ptr[0] = class;
    }

    pub fn get_class_of_represented_class(self: Self, heap_data: *const HeapData) *ClassDefinition {
        _ = self;
        const ptr = heap_data.get_after_header_ptr([*]*ClassDefinition);
        return ptr[1];
    }

    pub fn set_class_of_represented_class(self: Self, heap_data: *const HeapData, class: *ClassDefinition) void {
        _ = self;
        const ptr = heap_data.get_after_header_ptr([*]*ClassDefinition);
        ptr[1] = class;
    }

    pub fn get_class_var_with_idx(self: Self, heap_data: *const HeapData, class_var_idx: u32) VmObject {
        assert(class_var_idx < self.get_class_variables_count(heap_data.*));
        const instances = heap_data.get_after_header_ptr([*]VmObject);
        return instances[class_var_idx + 2]; // `+2` since we store the two `*ClassDefinition`s at the indexes 0 and 1
    }

    pub fn set_class_var_with_idx(self: Self, heap_data: *HeapData, class_var_idx: u32, object: VmObject) void {
        assert(class_var_idx < self.get_class_variables_count(heap_data.*));
        const instances = heap_data.get_after_header_ptr([*]VmObject);
        instances[class_var_idx + 2] = object; // `+2` since we store the two `*ClassDefinition`s at the indexes 0 and 1
    }
};

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

pub const ArrayAccessor = packed struct {
    const Self = @This();

    pub fn get_bytes_count_after_header(self: Self, heap_data: HeapData) usize {
        return @intCast(self.get_length(heap_data) * @sizeOf(VmObject));
    }

    pub fn get_length(self: Self, heap_data: HeapData) i48 {
        _ = self;
        return @intCast(heap_data.header.payload);
    }
    pub fn set_length(self: Self, heap_data: *HeapData, new_length: i48) void {
        _ = self;
        assert(new_length >= 0);
        heap_data.header.payload = @intCast(new_length);
    }
    pub fn items(self: Self, heap_data: *HeapData) []VmObject {
        _ = self;
        const items_ptr = heap_data.get_after_header_ptr([*]VmObject);
        const length = heap_data.header.payload;
        return items_ptr[0..length];
    }
};

pub const StringAccessor = packed struct {
    const Self = @This();

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

pub const SymbolAccessor = struct {
    const Self = @This();

    pub fn get_symbol_id(self: Self, heap_data: HeapData) SymbolId {
        _ = self;
        assert(heap_data.header.tag == .symbol);
        const idx: SymbolId.IdRepr = @intCast(heap_data.header.payload);
        return SymbolId.new(idx);
    }

    pub fn set_symbol_id(self: Self, heap_data: *HeapData, new_id: SymbolId) void {
        _ = self;
        assert(heap_data.header.tag == .symbol);
        heap_data.header.payload = new_id.idx;
    }

    pub fn get_bytes_count_after_header(self: Self) usize {
        _ = self;
        // We need just the header
        return 0;
    }
};

pub const BlockAccessor = struct {
    const Self = @This();

    pub fn get_bytes_count_after_header(self: Self) usize {
        _ = self;
        return @sizeOf(*const BlockDefinition) + @sizeOf(*const Stack.Frame);
    }

    pub fn get_has_escaped_home_frame(self: Self, heap_data: HeapData) bool {
        _ = self;
        return @as(bool, @truncate(heap_data.header.payload));
    }
    pub fn set_has_escaped_home_frame(self: Self, heap_data: *HeapData, has_escaped: bool) void {
        _ = self;
        heap_data.header.payload = @intFromBool(has_escaped);
    }

    pub fn get_block_definition(self: Self, heap_data: *HeapData) *const BlockDefinition {
        _ = self;
        return heap_data.get_after_header_ptr(**const BlockDefinition).*;
    }
    pub fn set_block_definition(self: Self, heap_data: *HeapData, body: *const BlockDefinition) void {
        _ = self;
        heap_data.get_after_header_ptr(**const BlockDefinition).* = body;
    }

    pub fn get_home_frame(self: Self, heap_data: *const HeapData) *const Stack.Frame {
        _ = self;
        return heap_data.get_after_header_ptr([*]*Stack.Frame)[1]; // There is `*const BlockDefinition` at index 0
    }
    pub fn set_home_frame(self: Self, heap_data: *HeapData, home_frame: *const Stack.Frame) void {
        _ = self;
        heap_data.get_after_header_ptr([*]*const Stack.Frame)[1] = home_frame; // There is `*const BlockDefinition` at index 0
    }
};
