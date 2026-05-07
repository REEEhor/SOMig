const std = @import("std");
const assert = std.debug.assert;
const BuiltinClassType = @import("__runtime.zig").BuiltinClassType;

const runtime_module = @import("__runtime.zig");
const ClassDefinition = runtime_module.ClassDefinition;
const Stack = runtime_module.Stack;
const MethodDefinition = runtime_module.MethodDefinition;
const Heap = runtime_module.Heap;
const Statics = runtime_module.Statics;

const SmallPtr = @import("small_ptr.zig").SmallPtr;

const codegen_module = @import("../frontend/codegen.zig");
const BlockDefinition = codegen_module.BlockDefinition;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;
const dbg_assert_eql = debug_module.dbg_assert_eql;
const dbg_assert_eql_msg = debug_module.dbg_assert_eql_msg;

const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

// TODO(speed): NaN tagging, we should be able to do:
//                 - pointers to `ObjectHeader`
//                 - singletons:
//                      - booleans (false, true)
//                      - the `system` singleton (it does not store any state, everything is in the `Interpreter` Zig struct)
//                      - nil
//                 - i48 numbers
//                 - `Double`s (of course xd)
//                 - maybe small string optimisation?

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
        const bits: (packed struct(u3) { bit1: u1, bit2: u1, bit3: u1 }) = @bitCast(deciding_bits);
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
    pub fn gc_mark_as_reachable_ignore_if_class_method(self: VmObject) void {
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
/// FIXME: Try reordering the fields here for speed, because they are ordered from least to most significant.
/// NOTE:  We want to try this, because most types store `SmallPtr` or integers in there, and we would like to not bit-shift that around uppon each access.
/// ! TODO:
///        [ ] 0. Check on godbolt, what code that this generate. Try `packed struct(u32) { value: u8, rest: u24 }` and `packed struct(u32) { rest: u24, value: u8 }`
///        [ ] 1. Reorder the fields here in the `OpaqueHeader`
///        [ ] 2. Reorder the fields in all the heap objects
///        [ ] 3. Everything should work after fixing all compile errors? There will be probably some in the `VmObject.from` function, which does a bunch of `comptime` asserts.
///        [ ] 4. Don't forget to reorder the fields also in the thesis code listings.
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

fn allocate_heap_data(
    allocator: anytype,
    header: anytype,
) std.mem.Allocator.Error!*@TypeOf(header) {
    comptime {
        const info = @typeInfo(@TypeOf(header)).@"struct";
        assert(info.layout == .@"packed");
        assert(info.backing_integer.? == u64);
        //
        assert(info.fields[0].type == HeapObject.Tag);
        assert(std.mem.eql(u8, info.fields[0].name, "tag"));
        //
        assert(info.fields[1].type == bool);
        assert(std.mem.eql(u8, info.fields[1].name, "is_marked"));
        assert(std.meta.hasFn(@TypeOf(header), "object_size_in_bytes"));
    }

    const AllocatorType = @TypeOf(allocator);
    const ptr: *@TypeOf(header) = sw: switch (AllocatorType) {
        *Heap => {
            const heap: *Heap = allocator;
            const opaque_header: *OpaqueHeader = try heap.allocate(header.object_size_in_bytes());
            break :sw @ptrCast(opaque_header);
        },
        *Statics, std.mem.Allocator => {
            const std_allocator: std.mem.Allocator = if (AllocatorType == *Statics) allocator.allocator else allocator;
            const alignment = comptime std.mem.Alignment.fromByteUnits(@alignOf(OpaqueHeader));
            const byte_size: usize = header.object_size_in_bytes();
            const bytes_ptr = try std_allocator.alignedAlloc(u8, alignment, byte_size);
            break :sw @ptrCast(bytes_ptr);
        },
        else => |Invalid| @compileError(std.fmt.comptimePrint(
            "Invalid type for an allocator: `{s}`",
            .{@typeName(Invalid)},
        )),
    };
    ptr.* = header;
    return ptr;
}

pub fn pointer_after(object_ptr: anytype, comptime Item: type) *Item {
    const Object = @typeInfo(@TypeOf(object_ptr)).pointer.child;
    const address = @intFromPtr(object_ptr) + @sizeOf(Object);
    return @ptrFromInt(address);
}

pub fn slice_after(object_ptr: anytype, comptime Item: type, length: usize) []align(@alignOf(@TypeOf(object_ptr))) Item {
    const Object = @typeInfo(@TypeOf(object_ptr)).pointer.child;
    const address = @intFromPtr(object_ptr) + @sizeOf(Object);
    const ptr: [*]align(@alignOf(Object)) Item = @ptrFromInt(address);
    return ptr[0..length];
}
pub const types = struct {
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
            // TODO: replace with memset
            for (self.get_fields()) |*field_object| {
                field_object.* = VmObject.nil;
            }
            return VmObject.from(self);
        }

        pub fn get_fields(self: *Self) []VmObject {
            const length: usize = @intCast(self.header.number_of_instance_fields);
            return slice_after(self, VmObject, length);
        }

        pub fn gc_mark_references(self: *Self) void {
            for (self.get_fields()) |field_object| {
                field_object.gc_mark_as_reachable_ignore_if_class_method();
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
                item.gc_mark_as_reachable_ignore_if_class_method();
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
        next_escaping_block: ?*types.Block = null,

        pub const Header = packed struct(u64) {
            tag: HeapObject.Tag = tag,
            is_marked: bool = false,
            has_escaped_home_context: bool = false,
            _padding: u6 = undefined,
            next_of_previous_escaping_block: SmallPtr(?*?*types.Block) = .init(null),

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
};

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
                .block => |block| VmObject.from(block).gc_mark_as_reachable_ignore_if_class_method(),
                .method => {},
            }

            for (FrameOnHeap.get_arguments_and_locals(header)) |local| {
                local.gc_mark_as_reachable_ignore_if_class_method();
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
