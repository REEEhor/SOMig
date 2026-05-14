const std = @import("std");
const assert = std.debug.assert;

const objects_module = @import("__objects.zig");
const HeapObject = objects_module.HeapObject;
const OpaqueHeader = objects_module.OpaqueHeader;
const FrameOnHeap = objects_module.FrameOnHeap;
const EmptyHeapSegment = objects_module.EmptyHeapSegment;
const types = objects_module.types;

const runtime_module = @import("../__runtime.zig");
const ClassDefinition = runtime_module.ClassDefinition;
const SmallPtr = runtime_module.SmallPtr;

const interning_module = @import("../../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

pub const VmObject = packed struct(u64) {
    bits: u64,

    /// Constant for the `nil` singleton global object.
    pub const nil = VmObject{ .bits = @intFromEnum(Identity.nil) };

    /// Constant for the `true` singleton global object.
    pub const true_object = VmObject{ .bits = @intFromEnum(Identity.true) };

    /// Constant for the `false` singleton global object.
    pub const false_object = VmObject{ .bits = @intFromEnum(Identity.false) };

    /// Constant for the `system` singleton global object.
    pub const system_object = VmObject{ .bits = @intFromEnum(Identity.system) };

    /// Cast the `VmObject` into this type by calling the `.identify()` method.
    pub const Identity = enum(u64) {
        /// The `VmObject` is the `nil` singleton global object.
        nil = nan_boxed_pattern(0),
        /// The `VmObject` is the `true` singleton global object.
        true = nan_boxed_pattern(1),
        /// The `VmObject` is the `false` singleton global object.
        false = nan_boxed_pattern(2),
        /// The `VmObject` is the `system` singleton global object.
        system = nan_boxed_pattern(3),

        /// The `VmObject` is an instance of a heap allocated object.
        /// Use the `as_asserted_heap_object()` method to access
        /// the underlying pointer to the heap data.
        heap_object = nan_boxed_pattern(4),

        /// The `VmObject` is an instance of the `Integer` class.
        /// Use the `as_asserted_integer()` method to access
        /// the underlying integer value.
        integer = nan_boxed_pattern(5),

        /// The `VmObject` is an instance of the `Symbol` class.
        /// Use the `as_asserted_symbol()` method to access
        /// the underlying `SymbolId`.
        symbol = nan_boxed_pattern(6),

        /// The `VmObject` is an instance of the `Double` class.
        /// Use the `as_asserted_double()` method to access
        /// the underlying float value.
        _,
    };

    /// Cast the `VmObject` into the `Identity` enum, which describes what kind of `VmObject` `self` is.
    pub fn identify(self: VmObject) Identity {
        return @enumFromInt(self.bits & identification_mask);
    }

    /// A 64 bit pattern of a 64 bit float, which cannot be created by a normal floating-point arithmetic on know CPUs.
    /// Meaning that all floats (even NaNs) that can be encountered have at least one 0 bit at the places `nan_mask` has 1 bits.
    /// ```
    ///      this bit is also 0                       |<------ 50 bits ------>|
    ///            |                                  |                       |
    /// bit value: 0   1   1   1   1   1   ...  1  1  0  0  0  0   ...  0  0  0
    /// bit index: 63  62  61  60  59  58  ...  51 50 49 48 47 46  ...  2  1  0
    /// ```
    const nan_mask: u64 = 0b0_1111111111111_00000_00000_00000_00000_00000_00000_00000_00000_00000_00000;

    /// Mask used for casting the `VmObject` into the `Identity` enum.
    /// When the `bits` field of a `VmObject` is masked with this constant, a valid value of the `Identity`
    /// enum will be created. Usage can be seen in the `.identify()` method.
    /// ```
    ///                                least significat bit with the value 1
    ///                                                  |
    /// bit value: 1   1   1   1   1   1   ...  1  1  1  1  0  0   ...  0  0  0
    /// bit index: 63  62  61  60  59  58  ...  51 50 49 48 47 46  ...  2  1  0
    /// ```
    const identification_mask: u64 = nan_boxed_pattern(~@as(u3, 0));

    const symbol_pattern: u64 = @intFromEnum(Identity.symbol);
    const integer_pattern: u64 = @intFromEnum(Identity.integer);
    const heap_object_pattern: u64 = @intFromEnum(Identity.heap_object);

    pub fn from_boolean(value: bool) VmObject {
        if (value) return VmObject.true_object;
        return VmObject.false_object;
    }
    pub fn as_asserted_boolean(self: VmObject) bool {
        return switch (self) {
            VmObject.false_object => return false,
            VmObject.true_object => return true,
            else => unreachable,
        };
    }

    pub fn from_symbol(id: SymbolId) VmObject {
        const bits = asserted_bit_or(symbol_pattern, id.idx);
        return VmObject{ .bits = bits };
    }
    pub fn as_asserted_symbol(self: VmObject) SymbolId {
        const raw: u48 = self.extract_asserted_nan_boxed_bits(symbol_pattern);
        return SymbolId{ .idx = @intCast(raw) };
    }

    pub fn from_integer(integer_value: i48) VmObject {
        const bits = asserted_bit_or(integer_pattern, @as(u48, @bitCast(integer_value)));
        return VmObject{ .bits = bits };
    }
    pub fn as_asserted_integer(self: VmObject) i48 {
        const raw: u48 = self.extract_asserted_nan_boxed_bits(integer_pattern);
        return @bitCast(raw);
    }

    pub fn from_double(value: f64) VmObject {
        const value_raw: u64 = @bitCast(value);
        assert(is_float_bits(value_raw));
        return VmObject{ .bits = @bitCast(value) };
    }
    pub fn as_asserted_double(self: VmObject) f64 {
        assert(is_float_bits(self.bits));
        return @bitCast(self.bits);
    }

    pub fn from(heap_object_ptr: anytype) VmObject {
        const supposed_tag: HeapObject.Tag = comptime blk: {
            // Assert that the pointer we got points to an extern struct
            // which has the field named `header` as its first field.
            const ObjectType = @typeInfo(@TypeOf(heap_object_ptr)).pointer.child;
            const info = @typeInfo(ObjectType).@"struct";
            assert(info.layout == .@"extern");
            assert(std.mem.eql(u8, info.fields[0].name, "header"));

            // Assert that the shape of the `header` is corrent and
            // can be casted into an `OpaqueHeader`.
            const header_type_info = @typeInfo(info.fields[0].type).@"struct";
            assert(header_type_info.layout == .@"packed");
            assert(header_type_info.backing_integer.? == u64);
            assert(header_type_info.fields[0].type == HeapObject.Tag);
            assert(header_type_info.fields[1].type == bool);
            assert(std.mem.eql(u8, header_type_info.fields[1].name, "is_marked"));

            // Assert that the default value of the tag is correct.
            const tag: HeapObject.Tag = header_type_info.fields[0].defaultValue().?;
            assert(@field(ObjectType, "tag") == tag);
            assert(@FieldType(HeapObject, @tagName(tag)) == @TypeOf(heap_object_ptr));

            // The `VmObject` should never represent a `FrameOnHeap`.
            assert(tag != HeapObject.Tag.frame_header);
            // The `VmObject` should never represent a `EmptyHeapSegment`.
            assert(tag != HeapObject.Tag.empty_heap_segment);

            break :blk tag;
        };

        // Check for curruption or logic errors of the tag.
        assert(heap_object_ptr.header.tag == supposed_tag);

        // Okay, we are done with the asserts...
        // Now we can cast the pointer to the `bits` field of an `VmObject`.
        const header_ptr: *OpaqueHeader = @ptrCast(heap_object_ptr);
        const small_header_ptr: SmallPtr(*OpaqueHeader) = .init(header_ptr);
        const bits = asserted_bit_or(heap_object_pattern, small_header_ptr.bits);
        return VmObject{ .bits = bits };
    }
    pub fn as_asserted_ptr_to_heap(self: VmObject) *OpaqueHeader {
        const raw: u48 = self.extract_asserted_nan_boxed_bits(heap_object_pattern);
        const small_ptr = SmallPtr(*OpaqueHeader){ .bits = raw };
        return small_ptr.ptr();
    }

    inline fn extract_asserted_nan_boxed_bits(self: VmObject, bit_pattern: u64) u48 {
        assert(satisfies_pattern(self.bits, bit_pattern));
        return @intCast(self.bits & ~identification_mask);
    }
    inline fn satisfies_pattern(val: u64, bit_pattern: u64) bool {
        return (val & identification_mask) == bit_pattern;
    }
    inline fn is_float_bits(bits: u64) bool {
        // All floats will NOT have all ones set at the places `nan_mask` has bits set to 1.
        return (bits & nan_mask) != nan_mask;
    }

    pub fn nan_boxed_pattern(deciding_bits: u3) u64 {
        const bits: (packed struct(u3) { bit3: u1, bit2: u1, bit1: u1 }) = @bitCast(deciding_bits);
        return nan_mask //
        | (@as(u64, bits.bit1) << 63) //
        | (@as(u64, bits.bit2) << 49) //
        | (@as(u64, bits.bit3) << 48) //
        ;
    }

    pub fn asserted_bit_or(lhs: u64, rhs: u64) u64 {
        assert(lhs & rhs == 0);
        return lhs | rhs;
    }

    pub fn as_ptr_to_heap(self: VmObject) ?*OpaqueHeader {
        return switch (self.identify()) {
            .heap_object => return self.as_asserted_ptr_to_heap(),
            else => null,
        };
    }

    pub fn as_heap_object(self: VmObject, comptime tag: HeapObject.Tag) ?@FieldType(HeapObject, @tagName(tag)) {
        const header_ptr: *OpaqueHeader = self.as_ptr_to_heap() orelse return null;
        switch (header_ptr.fetch()) {
            inline else => |accessor, actual_tag| {
                if (actual_tag == tag) return accessor.get(header_ptr);
                return null;
            },
        }
    }

    /// We ignore `types.(Class|Method)` because they are allocated
    /// in the static space. We have to mark their references manually
    /// in order for this to make sense.
    /// NOTE: Only `types.Class` has actuall references - class fields - so we mark only those manualy in `gc_mark()`. `types.Method` doesn't store object references.
    pub fn gc_mark_as_reachable_ignore_if_class_or_method(self: VmObject) void {
        const header: *OpaqueHeader = self.as_ptr_to_heap() orelse return;
        switch (header.tag) {
            .frame_header,
            .empty_heap_segment,
            => unreachable,

            .method,
            .class,
            => return,

            inline else => |tag| {
                const object = header.asserted_cast_to(tag);
                if (object.header.is_marked) return;
                object.header.is_marked = true;
                object.gc_mark_references();
            },
        }
    }

    /// Just a simple wrapper around `self.as(.block)`
    pub fn as_block(self: VmObject) ?*types.Block {
        return self.as_heap_object(.block);
    }

    pub fn as_symbol(self: VmObject) ?SymbolId {
        if (self.identify() != .symbol) return null;
        return self.as_asserted_symbol();
    }

    pub fn as_class(self: VmObject) ?*ClassDefinition {
        const cls = self.as_heap_object(.class) orelse return null;
        return cls.represented_class;
    }

    pub fn as_integer(self: VmObject) ?i48 {
        if (self.identify() != .integer) return null;
        return self.as_asserted_integer();
    }

    pub fn as_double(self: VmObject) ?f64 {
        if (!is_float_bits(self.bits)) return null;
        return self.as_asserted_double();
    }

    pub fn as_array(self: VmObject) ?[]VmObject {
        const array = self.as_heap_object(.array) orelse return null;
        return array.get_items();
    }

    pub fn as_text(self: VmObject, symbols_manager: *SymbolsManager) ?[]const u8 {
        switch (self.identify()) {
            .symbol => {
                const id: SymbolId = self.as_asserted_symbol();
                return symbols_manager.symbol_with_id(id);
            },
            .heap_object => {
                const header: *OpaqueHeader = self.as_ptr_to_heap() orelse return null;
                if (header.tag != .string) return null;
                const string_object = header.asserted_cast_to(.string);
                return string_object.contents();
            },
            else => return null,
        }
    }

    pub fn as_number(self: VmObject) ?Number {
        return switch (self.identify()) {
            .integer => .{ .integer = self.as_asserted_integer() },
            _ => .{ .double = as_asserted_double(self) },
            else => return null,
        };
    }

    pub fn get_instance_fields(self: VmObject) []VmObject {
        const data = self.as_ptr_to_heap() orelse return &.{};
        switch (data.tag) {
            .generic_object => {
                const object = data.asserted_cast_to(.generic_object);
                return object.get_fields();
            },
            .class => {
                const class = data.asserted_cast_to(.class);
                return class.get_class_fields();
            },
            else => return &.{},
        }
    }
};

pub const Number = union(enum) {
    integer: i48,
    double: f64,

    pub fn from_f64(value: f64) Number {
        const ceil = std.math.ceil(value);
        const floor = std.math.floor(value);
        if (ceil == floor) {
            const integer_value = std.math.lossyCast(i48, ceil);
            if (integer_value == @as(i48, @intFromFloat(ceil))) {
                return Number{ .integer = integer_value };
            }
        }
        return Number{ .double = value };
    }

    pub fn as_i48_maybe_lossy(self: Self) i48 {
        return self.as_int_maybe_lossy(i48);
    }

    pub fn as_int_maybe_lossy(self: Self, comptime IntegerType: type) IntegerType {
        return switch (self) {
            .integer => |x| x,
            .double => |x| std.math.lossyCast(IntegerType, x),
        };
    }
    pub fn as_f64(self: Self) f64 {
        return switch (self) {
            .integer => |x| @floatFromInt(x),
            .double => |x| x,
        };
    }

    const Self = @This();
};
