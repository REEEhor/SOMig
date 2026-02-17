//! TODO: make this simpler

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const BuiltinClassType = @import("__interpreter.zig").BuiltinClassType;

const interpreter_module = @import("__interpreter.zig");
const ClassDefinition = interpreter_module.ClassDefinition;
const Stack = interpreter_module.Stack;

const codegen_module = @import("../frontend/codegen.zig");
const BlockDefinition = codegen_module.BlockDefinition;

const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;


// TODO(speed): NaN tagging, we should be able to do:
//                 - pointers to `ObjectHeader`
//                 - booleans (false, true)
//                 - nil
//                 - i48 numbers
//                 - maybe small string optimisation?
pub const VmObject = struct {
    data: ?*HeapData,

    pub const nil = VmObject{ .data = null };

    pub fn from(known_object: anytype) VmObject {
        comptime {
            const ObjectType = @typeInfo(@TypeOf(known_object)).pointer.child;
            const info = @typeInfo(ObjectType).@"struct";
            assert(info.layout == .@"extern");
            assert(std.mem.eql(u8, info.fields[0].name, "header"));
            const header_type_info = @typeInfo(info.fields[0].type).@"struct";
            assert(header_type_info.layout == .@"packed");
            assert(header_type_info.backing_integer.? == u64);
            assert(header_type_info.fields[0].type == HeapData.Header.Tag);
            assert(header_type_info.fields[1].type == bool);
            assert(std.mem.eql(u8, header_type_info.fields[1].name, "is_marked"));
        }
        const object = VmObject{ .data = @ptrCast(known_object) };
        return object;
    }

    pub fn kind(self: VmObject) Kind {
        const heap_data: *HeapData = self.data orelse return .nil;
        switch (heap_data.header.tag) {
            .empty_heap_segment => unreachable,
            .frame => unreachable,
            inline else => |heap_data_tag| {
                const ObjectType: type = comptime for (std.meta.declarations(types)) |object_type_declaration| {
                    const ObjectType: type = @field(types, object_type_declaration.name);
                    if (ObjectType.tag == heap_data_tag) break ObjectType;
                } else @compileError(std.fmt.comptimePrint("Could not find an object type which has the tag `{t}`", .{heap_data_tag}));

                const vm_object_type_tag: Kind.Tag = comptime Kind.tag_with_object_type(ObjectType);
                const casted_self: *ObjectType = @ptrCast(heap_data);
                return @unionInit(Kind, @tagName(vm_object_type_tag), casted_self);
            },
        }
    }

    pub const Kind = union(enum) {
        integer: *types.Integer,
        double: *types.Double,
        string: *types.String,
        array: *types.Array,
        nil,
        class: *types.Class,
        symbol: *types.Symbol,
        block: *types.Block,
        generic_object: *types.GenericObject,

        pub const Tag = std.meta.Tag(@This());

        const Self = @This();
        pub fn tag(self: Self) Tag {
            return std.meta.activeTag(self);
        }

        fn tag_with_object_type(comptime ObjectType: type) Tag {
            comptime {
                var result_tag: ?Tag = null;
                for (@typeInfo(Kind).@"union".fields) |field| {
                    if (field.type != *ObjectType) continue;
                    const current_tag = @field(Tag, field.name);
                    if (result_tag != null) {
                        @compileError(std.fmt.comptimePrint(
                            "Found payload `{s}` for tags `{t}` and `{t}`",
                            .{ @typeName(ObjectType), result_tag.?, current_tag },
                        ));
                    }
                    result_tag = current_tag;
                }

                return result_tag orelse @compileError(std.fmt.comptimePrint(
                    "Could not find payload of type `{s}` in `{s}`",
                    .{ @typeName(*ObjectType), @typeName(@This()) },
                ));
            }
        }
    };
};

pub const HeapData = struct {
    header: Header,

    pub const Header = packed struct(u64) {
        tag: Tag,
        is_marked: bool,
        _padding: u55,

        pub const Tag = enum(u8) {
            integer,
            double,
            string,
            array,
            class,
            symbol,
            block,
            generic_object,
            empty_heap_segment,
            frame,
        };
    };
};

comptime {
    // Simplifies a lot of things (especially the alignment).
    // It is far easier to allocate header and then other fields after it for example.
    assert(@sizeOf(HeapData) == 8);
    assert(@alignOf(HeapData) == 8);
}

fn allocate_heap_data(
    allocator: Allocator,
    header: anytype,
) Allocator.Error!*@TypeOf(header) {
    comptime {
        const info = @typeInfo(@TypeOf(header)).@"struct";
        assert(info.layout == .@"packed");
        assert(info.backing_integer.? == u64);
        //
        assert(info.fields[0].type == HeapData.Header.Tag);
        assert(std.mem.eql(u8, info.fields[0].name, "tag"));
        //
        assert(info.fields[1].type == bool);
        assert(std.mem.eql(u8, info.fields[1].name, "is_marked"));
        assert(std.meta.hasFn(@TypeOf(header), "object_size_in_bytes"));
    }

    const alignment = comptime std.mem.Alignment.fromByteUnits(@alignOf(HeapData));
    const byte_size: usize = header.object_size_in_bytes();
    const bytes_ptr = try allocator.alignedAlloc(u8, alignment, byte_size);
    const ptr: *@TypeOf(header) = @ptrCast(bytes_ptr);
    ptr.* = header;
    return ptr;
}

fn slice_after(object_ptr: anytype, comptime Item: type, length: usize) []Item {
    const Object = @typeInfo(@TypeOf(object_ptr)).pointer.child;
    const address = @intFromPtr(object_ptr) + @sizeOf(Object);
    const ptr: [*]Item = @ptrFromInt(address);
    return ptr[0..length];
}
pub const types = struct {
    pub const Integer = extern struct {
        header: Header,

        pub const Header = packed struct(u64) {
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u7 = undefined,
            value: i48,

            pub fn object_size_in_bytes(header: @This()) usize {
                _ = header;
                return @sizeOf(Integer);
            }
        };

        pub const tag: HeapData.Header.Tag = .integer;

        pub fn create_new(allocator: Allocator, value: i48) Allocator.Error!VmObject {
            const self: *Integer = @ptrCast(try allocate_heap_data(allocator, Header{ .value = value }));
            return VmObject.from(self);
        }
    };

    pub const Double = extern struct {
        header: Header,
        value: f64,

        pub const Header = packed struct(u64) {
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u55 = undefined,

            pub fn object_size_in_bytes(header: @This()) usize {
                _ = header;
                return @sizeOf(Double);
            }
        };

        pub const tag: HeapData.Header.Tag = .double;

        pub fn create_new(allocator: Allocator, value: f64) Allocator.Error!VmObject {
            const self: *Double = @ptrCast(try allocate_heap_data(allocator, Header{}));
            self.value = value;
            return VmObject.from(self);
        }
    };

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
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u7 = undefined,
            number_of_instance_fields: i48,

            pub fn object_size_in_bytes(header: @This()) usize {
                const length: usize = @intCast(header.number_of_instance_fields);
                return @sizeOf(GenericObject) + length * @sizeOf(VmObject);
            }
        };

        pub const tag: HeapData.Header.Tag = .generic_object;

        pub fn create_new(allocator: Allocator, class: *ClassDefinition) Allocator.Error!VmObject {
            const number_of_instance_fields: i48 = @intCast(class.fields_count_including_parents());
            const self: *GenericObject = @ptrCast(try allocate_heap_data(allocator, Header{
                .number_of_instance_fields = number_of_instance_fields,
            }));
            self.class = class;
            for (self.get_fields()) |*field_object| {
                field_object.* = VmObject.nil;
            }
            return VmObject.from(self);
        }

        pub fn get_fields(self: *@This()) []VmObject {
            const length: usize = @intCast(self.header.number_of_instance_fields);
            return slice_after(self, VmObject, length);
        }
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
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u7 = undefined,
            number_of_class_fields: i48,

            pub fn object_size_in_bytes(header: @This()) usize {
                const cnt: usize = @intCast(header.number_of_class_fields);
                return @sizeOf(Class) + cnt * @sizeOf(VmObject);
            }
        };

        pub const tag: HeapData.Header.Tag = .class;

        pub fn create_new(
            allocator: Allocator,
            classes: struct {
                represented_class: *ClassDefinition,
                class_of_represented_class: *ClassDefinition,
            },
        ) Allocator.Error!VmObject {
            const number_of_class_fields: i48 = @intCast(classes.represented_class.fields_count_including_parents());
            var self: *Class = @ptrCast(try allocate_heap_data(allocator, Header{
                .number_of_class_fields = number_of_class_fields,
            }));
            self.class_of_represented_class = classes.class_of_represented_class;
            self.represented_class = classes.represented_class;

            for (self.get_class_fields()) |*field_object| {
                field_object.* = VmObject.nil;
            }

            const object = VmObject.from(self);
            classes.represented_class.as_vm_object = object;
            return object;
        }

        const Self = @This();

        pub fn get_class_fields(self: *Self) []VmObject {
            const length: usize = @intCast(self.header.number_of_class_fields);
            return slice_after(self, VmObject, length);
        }
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
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u7 = undefined,
            length: i48,

            pub fn object_size_in_bytes(header: @This()) usize {
                const length: usize = @intCast(header.length);
                return @sizeOf(Array) + length * @sizeOf(VmObject);
            }
        };

        pub const tag: HeapData.Header.Tag = .array;

        pub fn create_new(allocator: Allocator, items_to_copy: []VmObject) Allocator.Error!VmObject {
            const length: i48 = @intCast(items_to_copy.len);
            const self: *Array = @ptrCast(try allocate_heap_data(allocator, Header{ .length = length }));
            const items: []VmObject = self.get_items();
            @memcpy(items, items_to_copy);
            return VmObject.from(self);
        }

        const Self = @This();
        pub fn get_items(self: *Self) []VmObject {
            const length: usize = @intCast(self.header.length);
            return slice_after(self, VmObject, length);
        }
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
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u7 = undefined,
            length: i48,

            pub fn object_size_in_bytes(header: @This()) usize {
                const length: usize = @intCast(header.length);
                return @sizeOf(Array) + length * @sizeOf(u8);
            }
        };

        pub const tag: HeapData.Header.Tag = .string;

        pub fn init_with_undefined_contents(allocator: Allocator, length: i48) Allocator.Error!*String {
            const self: *String = @ptrCast(try allocate_heap_data(allocator, Header{ .length = length }));
            return self;
        }

        pub fn create_new(allocator: Allocator, contents_to_copy: []const u8) Allocator.Error!VmObject {
            const self: *String = try init_with_undefined_contents(allocator, @intCast(contents_to_copy.len));
            @memcpy(self.contents(), contents_to_copy);
            return VmObject.from(self);
        }

        pub fn create_new_fmt(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!VmObject {
            const length = std.fmt.count(fmt, args);
            const self: *String = try init_with_undefined_contents(allocator, @intCast(length));
            const res = std.fmt.bufPrint(self.contents(), fmt, args) catch unreachable;
            assert(res.len == self.contents().len);
            return VmObject.from(self);
        }

        const Self = @This();
        pub fn contents(self: *Self) []u8 {
            const length: usize = @intCast(self.header.length);
            return slice_after(self, u8, length);
        }
    };

    pub const Symbol = extern struct {
        header: Header,

        pub const Header = packed struct(u64) {
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u31 = undefined,
            symbol_id: SymbolId,

            pub fn object_size_in_bytes(header: @This()) usize {
                _ = header;
                return @sizeOf(Symbol);
            }
        };

        pub const tag: HeapData.Header.Tag = .symbol;

        pub fn create_new(allocator: Allocator, symbol_id: SymbolId) Allocator.Error!VmObject {
            const self: *Symbol = @ptrCast(try allocate_heap_data(allocator, Header{ .symbol_id = symbol_id }));
            return VmObject.from(self);
        }
    };

    pub const Block = extern struct {
        header: Header,
        block_definition: *const BlockDefinition,
        home_frame: *Stack.Frame,

        /// Next blocks which is also consider to be escaped from
        /// its home frame.
        ///
        /// The `Block` might be a part of an intrusive list
        /// which tracks all blocks, that escaped from their home context.
        ///
        /// The first item of this list is in `Stack.Frame.escaped_blocks_list_head`.
        next_escaped_block: ?*types.Block = null,

        pub const Header = packed struct(u64) {
            tag: HeapData.Header.Tag = tag,
            is_marked: bool = false,
            _padding: u54 = undefined,
            has_escaped_home_context: bool = false,

            pub fn object_size_in_bytes(header: @This()) usize {
                _ = header;
                return @sizeOf(Block);
            }
        };

        pub const tag: HeapData.Header.Tag = .block;

        pub fn create_new(
            allocator: Allocator,
            block_definition: *const BlockDefinition,
            parent_frame: *Stack.Frame,
        ) Allocator.Error!VmObject {
            const self: *Block = @ptrCast(try allocate_heap_data(allocator, Header{}));
            self.block_definition = block_definition;
            self.home_frame = parent_frame;
            return VmObject.from(self);
        }

        pub fn add_to_escaped_blocks_list(self: *Block) void {
            if (self.header.has_escaped_home_context) return;
            const head = &self.home_frame.escaped_blocks_list_head;
            self.next_escaped_block = head.*;
            head.* = self;
        }
    };
};

/// Just a namespace for manipulating a `Stack.Frame` which has been moved
/// to the heap. We need to at least sometimes put a stack frame on a heap,
/// because of blocks (lambdas) in SOM, which escape their home context
/// (home context == stack frame in which the block was created).
///
/// The `FrameOnHeap` is just a namespace and not a `VmObject` as in other SOM implementations,
/// because we want to hold the invariant, that the frame is not an object that
/// can be stored in some class for example.
///
/// Also the `FrameOnHeap` cannot be accessed just via casting `*HeapData`
/// to `*FrameOnHeap`, since `Stack.Frame` contains a tagged union,
/// which has unspecified memory layout, therefore `Stack.Frame` cannot
/// be an `extern struct`, therefore `FrameOnHeap` cannot be an `extern struct`,
/// which means a `FrameOnHeap.Header` could not be ensured to be in front
/// of the `Stack.Frame` when it is on the heap. We need header to be at the front
/// for garbage collection.
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
        tag: HeapData.Header.Tag = tag,
        is_marked: bool = false,

        /// Number of local variables (including arguments) of the frame.
        /// These are stored right after the `Stack.Frame`
        number_of_locals: u55,

        pub fn object_size_in_bytes(header: @This()) usize {
            return @sizeOf(Header) + @sizeOf(Stack.Frame) + header.number_of_locals * @sizeOf(VmObject);
        }
    };

    pub const tag = HeapData.Header.Tag.frame;

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

    pub fn reallocate_frame_to_heap(allocator: Allocator, frame: Stack.Frame) Allocator.Error!*Stack.Frame {
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
