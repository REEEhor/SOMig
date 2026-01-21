const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const colors = @import("../terminal.zig");

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;
const dbg_assert_eql = debug_module.dbg_assert_eql;
const dbg_assert_eql_msg = debug_module.dbg_assert_eql_msg;

const interning_module = @import("../interning/__interning.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = interning_module.SymbolArrayMap;

const codegen_module = @import("../frontend/codegen.zig");
const ClassDefinitionPair = codegen_module.ClassDefinitionPair;
const InstructionDecoder = codegen_module.InstructionDecoder;
const Instruction = codegen_module.Instruction;
const ConstantsManager = codegen_module.ConstantsManager;
const ConstantId = codegen_module.ConstantId;
const RelativeConstantId = codegen_module.RelativeConstantId;
const InstructionId = codegen_module.InstructionId;
const compile_class_with_its_parents = codegen_module.compile_class_with_its_parents;
const compile_class = codegen_module.compile_class;
const compile_class_ignoring_parents = codegen_module.compile_class_ignoring_parents;
const allocate_heap_data = codegen_module.allocate_heap_data;
const SourceCodeFiles = codegen_module.SourceCodeFiles;
const InstructionEncoder = codegen_module.InstructionEncoder;

pub const vm_object_module = @import("vm_object.zig");
pub const VmObject = vm_object_module.VmObject;
pub const HeapData = vm_object_module.HeapData;

pub const primitives = @import("primitives.zig");
pub const accessors = @import("accessors.zig");

const primitive_methods_map_module = @import("primitive_methods_map.zig");
pub const PrimitiveMethodsMap = primitive_methods_map_module.PrimitiveMethodsMap;
pub const PrimitiveMethodImplementation = primitive_methods_map_module.PrimitiveMethodImplementation;

pub const class_definition_module = @import("class_definition.zig");
pub const ClassDefinition = class_definition_module.ClassDefinition;
pub const MethodBody = class_definition_module.MethodBody;
pub const MethodDefinition = class_definition_module.MethodDefinition;

pub const DO_DEBUG_TRACE: bool = false;
pub const PRINT_PTR_MODULO: bool = true;

/// Stores stuff that does not get deallocated
pub const Statics = struct {
    /// Allocator used for all fields in this struct.
    /// It will presumably be an arena allocator, since we just need allocating and never deallocating from it (deallocation happens only at the end).
    allocator: Allocator,

    // TODO: remove at least some of the allocators from `SymbolsManager` so the `Allocator` in here is used
    symbols_manager: SymbolsManager,

    /// NOTE: This must be a `SegmentedList`, because we want to be able to store pointers to `ClassDefinition` in other structures.
    ///       If this was just an `ArrayList`, then the pointers to `ClassDefinition`s would get invalidated during reallocations.
    all_classes: std.SegmentedList(ClassDefinition, 64),

    instruction_encoder: InstructionEncoder,

    constants_manager: ConstantsManager,

    const Self = @This();

    /// TODO: consider making wrapper methods for different kinds of objects
    pub inline fn allocate_for_static_object(self: *Self, header: HeapData.Header) Allocator.Error!*HeapData {
        return try allocate_heap_data(self.allocator, header);
    }
};

// TODO: implement a GC so that we also deallocate stuff
// TODO: consider making this heap take in just a `[]align(@alignOf(HeapData.Header))u8` instead of the allocator
pub const Heap = struct {
    arena: std.heap.ArenaAllocator,

    const Self = @This();
    pub fn allocate(self: *Self, header: HeapData.Header) Allocator.Error!*HeapData {
        return try allocate_heap_data(self.arena.allocator(), header);
    }
};

pub const Stack = struct {
    frames: []Frame,
    objects: []VmObject,

    max_frames_len: usize,
    max_objects_len: usize,

    const Self = @This();

    pub const OverflowError = error{
        frame_stack_overflow,
        object_stack_overflow,
    };

    pub const Frame = struct {
        /// Index into the array `objects`
        base_idx: u32,
        after_return_instruction_id: InstructionId,

        /// Has guaranteed that the `body` is of type `user_land`.
        method: *const MethodDefinition,

        pub fn self_object_idx(self: @This()) u32 {
            const number_of_args = self.method.number_of_aditional_args;
            return self.base_idx - number_of_args;
        }

        pub fn constants_base_id(self: @This()) ConstantId {
            return self.method.body.user_land.constants_base_id;
        }

        pub fn get_variable_ptr(self: @This(), objects: []VmObject, offset: u32) *VmObject {
            return &objects[self.base_idx + offset];
        }
    };

    pub fn init(allocated_frames: []Frame, allocated_objects: []VmObject) Self {
        var frames = allocated_frames;
        frames.len = 0;
        var objects = allocated_objects;
        objects.len = 0;
        return Self{
            .frames = frames,
            .objects = objects,
            .max_frames_len = allocated_frames.len,
            .max_objects_len = allocated_objects.len,
        };
    }

    /// Asserts that the stack is not empty
    pub fn top_frame(self: *Self) *Frame {
        assert(self.frames.len > 0);
        return &self.frames[self.frames.len - 1];
    }

    pub inline fn frames_count(self: *Self) usize {
        return self.frames.len;
    }
};

// TODO: track the current function (which will be probably in the final `stack` implementation, which will also store stack frames)
// and use it for error reporting.
pub const Interpreter = struct {
    decoder: InstructionDecoder,
    globals: std.AutoArrayHashMap(SymbolId, VmObject),
    statics: *Statics,
    heap: Heap,

    stdout: *Writer,
    stderr: *Writer,

    primitive_methods: PrimitiveMethodsMap,
    primitive_class_definitions: std.EnumMap(PrimitiveClassType, *ClassDefinition),

    source_code_files: *SourceCodeFiles,

    cached_nil_object: ?VmObject,

    stack: Stack,

    const Self = @This();

    pub const Error = error{
        generic_runtime_error,
        primitive_type_error,
        method_not_found,
        frame_stack_overflow,
        object_stack_overflow,
        class_declared_multiple_times,
        division_by_zero,
        compilation_error,
        TODO,
    } || Allocator.Error || Writer.Error;

    pub fn new(
        allocator_for_heap: Allocator,
        allocator_for_globals: Allocator,
        stdout: *Writer,
        stderr: *Writer,
        statics: *Statics,
        source_code_files: *SourceCodeFiles,
        primitive_methods: PrimitiveMethodsMap,
        preallocated_object_stack: []VmObject,
        preallocated_frame_stack: []Stack.Frame,
    ) Interpreter {
        return Interpreter{
            .decoder = InstructionDecoder.empty,
            .stdout = stdout,
            .stderr = stderr,
            .statics = statics,
            .heap = Heap{ .arena = std.heap.ArenaAllocator.init(allocator_for_heap) },
            .primitive_methods = primitive_methods,
            .globals = .init(allocator_for_globals),
            .source_code_files = source_code_files,
            .primitive_class_definitions = .{},
            .stack = Stack.init(preallocated_frame_stack, preallocated_object_stack),
            .cached_nil_object = null,
        };
    }

    pub const NewObjectAllocationStrategy = enum { heap, static };

    fn allocate_heap_data_from_header(self: *Self, comptime alloc: NewObjectAllocationStrategy, header: HeapData.Header) Error!*HeapData {
        switch (alloc) {
            .heap => {
                return self.heap.allocate(header);
            },
            .static => {
                return self.statics.allocate_for_static_object(header);
            },
        }
    }

    pub fn create_object(self: *Self, comptime alloc: NewObjectAllocationStrategy, class_of_object: *ClassDefinition) Error!VmObject {
        const instance_fields_count: u32 = @intCast(class_of_object.fields_count_including_parents());
        var header = HeapData.Header.new_undefined_with_tag(.generic_object);
        (accessors.GenericObjectAccessor{}).set_instance_variables_count(header.as_heap_data(), instance_fields_count);
        const new_object_data: *HeapData = try self.allocate_heap_data_from_header(alloc, header);
        (accessors.GenericObjectAccessor{}).set_class_definition(new_object_data, class_of_object);

        // Set all instance fields to the default object:
        const nil_singleton = try self.get_nil_singleton();
        for (0..instance_fields_count) |idx| {
            (accessors.GenericObjectAccessor{}).set_instance_var_with_idx(new_object_data, @intCast(idx), nil_singleton);
        }

        const object: VmObject = new_object_data.as_vm_object();
        return object;
    }

    pub fn create_string(
        self: *Self,
        comptime alloc: NewObjectAllocationStrategy,
        new_string_contents: []const u8,
    ) Error!VmObject {
        try self.ensure_primitive_class_is_loaded(.string);

        var header = HeapData.Header.new_undefined_with_tag(.string);
        (accessors.StringAccessor{}).set_length(header.as_heap_data(), @intCast(new_string_contents.len));
        const result_object_data: *HeapData = try self.allocate_heap_data_from_header(alloc, header);
        @memcpy((accessors.StringAccessor{}).contents(result_object_data), new_string_contents);

        const object: VmObject = result_object_data.as_vm_object();
        return object;
    }

    pub fn create_string_fmt(
        self: *Self,
        comptime alloc: NewObjectAllocationStrategy,
        comptime fmt: []const u8,
        fmt_args: anytype,
    ) Error!VmObject {
        try self.ensure_primitive_class_is_loaded(.string);

        const length_usize: usize = std.fmt.count(fmt, fmt_args);
        if (length_usize > std.math.maxInt(i48)) {
            @branchHint(.cold);
            self.report_runtime_error("Tried to create a string with {d} characters, which is more than possible maximum (which is {d}).", .{ length_usize, std.math.maxInt(i48) });
            return Error.generic_runtime_error;
        }
        const length_i48: i48 = @intCast(length_usize);

        var header = HeapData.Header.new_undefined_with_tag(.string);
        (accessors.StringAccessor{}).set_length(header.as_heap_data(), length_i48);
        const result_object_data: *HeapData = try self.allocate_heap_data_from_header(alloc, header);

        // SAFETY: We got the length from `std.fmt.count` above.
        _ = std.fmt.bufPrint((accessors.StringAccessor{}).contents(result_object_data), fmt, fmt_args) catch unreachable;

        const object: VmObject = result_object_data.as_vm_object();
        return object;
    }

    pub fn create_array_with_undefined_items(
        self: *Self,
        comptime alloc: NewObjectAllocationStrategy,
        number_of_items: i48,
    ) Error!VmObject {
        try self.ensure_primitive_class_is_loaded(.array);

        var header = HeapData.Header.new_undefined_with_tag(.array);
        (accessors.ArrayAccessor{}).set_length(header.as_heap_data(), number_of_items);
        const result_object_data: *HeapData = try self.allocate_heap_data_from_header(alloc, header);

        const object: VmObject = result_object_data.as_vm_object();
        return object;
    }

    pub fn create_array(
        self: *Self,
        comptime alloc: NewObjectAllocationStrategy,
        items_to_copy_into_array: []VmObject,
    ) Error!VmObject {
        const array: VmObject = try self.create_array_with_undefined_items(alloc, @intCast(items_to_copy_into_array.len));
        @memcpy((accessors.ArrayAccessor{}).items(array.data), items_to_copy_into_array);
        return array;
    }

    // TODO: here will be argument for an entire class that is being run.. I think
    pub fn run(self: *Self) !void {
        while (true) {
            const instr_id = self.decoder.id_of_next_instruction();
            const instruction: Instruction = self.decoder.next_instruction() orelse {
                try self.report_info("The end of the bytecode has been reached.", .{});
                return;
            };
            if (DO_DEBUG_TRACE) {
                const formatter = codegen_module.InstructionFormatter{ .base_constant_id = self.top_frame().constants_base_id(), .constants_manager = &self.statics.constants_manager, .symbols_manager = &self.statics.symbols_manager };
                std.debug.print("\n[debug] Currently executing: [{d:04}]{f}", .{ instr_id.idx, formatter.fmt(instruction) });
            }
            switch (instruction) {
                .no_op => {},
                .halt => {
                    try self.report_info("The halt instruction has been encountered.", .{});
                    return;
                },
                .pop => {
                    _ = self.pop_object();
                },
                .load_local => |local_id| {
                    const object: VmObject = self.stack.objects[self.top_frame().base_idx + local_id.idx];
                    try self.push_object(object);
                },
                .set_local => |local_to_set_id| {
                    const to_assign: VmObject = self.stack.objects[self.stack.objects.len - 1];
                    self.stack.objects[self.top_frame().base_idx + local_to_set_id.idx] = to_assign;
                },
                .load_instance_var => |instance_var_id| {
                    const self_object: VmObject = self.stack.objects[self.top_frame().self_object_idx()];
                    const instance_variable = switch (self_object.data.kind()) {
                        .generic_object => |accessor| accessor.get_instance_var_with_idx(self_object.data, instance_var_id.idx),
                        // TODO: maybe this will not be a different case?
                        .class => return self.report_TODO("Loading of class variables", .{}),
                        else => unreachable,
                    };
                    try self.push_object(instance_variable);
                },
                .pop_into_new_array => |info| {
                    // Get the items slice from the stack
                    const items_count = info.number_of_items;
                    const len = self.stack.objects.len;
                    const items_start_idx = len - items_count;
                    const items: []VmObject = self.stack.objects[items_start_idx..len];

                    // Create the array object
                    const array_object: VmObject = try self.create_array(.heap, items);

                    // Pop all the objects that were copied into the new array
                    self.stack.objects.len = items_start_idx;

                    try self.push_object(array_object);
                },
                .set_instance_var => |instance_var_id| {
                    const top_object: VmObject = self.top_stack_object();
                    const self_object: VmObject = self.stack.objects[self.top_frame().self_object_idx()];
                    switch (self_object.data.kind()) {
                        .generic_object => |accessor| accessor.set_instance_var_with_idx(
                            self_object.data,
                            instance_var_id.idx,
                            top_object,
                        ),
                        // TODO: maybe this will not be a different case?
                        .class => return self.report_TODO("Setting of class variables", .{}),
                        else => unreachable,
                    }
                },
                .load_global => |global_symbol_id| {
                    const maybe_global_object: ?VmObject = self.globals.get(global_symbol_id);
                    if (maybe_global_object) |global_object| {
                        try self.push_object(global_object);
                    } else {
                        // TODO: here we will probably invoke `doesNotUnderstand` or something similiar
                        const newly_loaded_class: *ClassDefinition = try self.load_class(global_symbol_id);
                        try self.push_object(newly_loaded_class.as_vm_object);
                    }
                },
                .print => {
                    const to_print: VmObject = self.pop_object();
                    // TODO: do this using the `println` message or `toString` or something
                    try self.print_object(to_print);
                },
                .duplicate => {
                    const object = self.stack_top_object();
                    try self.push_object(object);
                },
                .load_constant => |constant_info| {
                    const constant_id: ConstantId = constant_info.id.to_absolute(self.top_frame().constants_base_id());
                    const constant = self.statics.constants_manager.get_constant(constant_id);
                    const object: VmObject = blk: switch (constant) {
                        .integer => |value| {
                            try self.ensure_primitive_class_is_loaded(.integer);
                            // TODO(hack): consider whether making the integers smaller or arbitrary in size or something
                            const value_i48: i48 = @intCast(value);

                            const header = HeapData.Header.new_undefined_with_tag(.integer);
                            const result_object_data: *HeapData = try self.heap.allocate(header);
                            (accessors.IntegerAccessor{}).set_value(result_object_data, value_i48);
                            break :blk result_object_data.as_vm_object();
                        },
                        .float => |value| {
                            try self.ensure_primitive_class_is_loaded(.double);
                            const header = HeapData.Header.new_undefined_with_tag(.double);
                            const result_object_data: *HeapData = try self.heap.allocate(header);
                            (accessors.DoubleAccessor{}).set_value(result_object_data, value);
                            break :blk result_object_data.as_vm_object();
                        },
                        .string => |value| {
                            const string_object: VmObject = try self.create_string(.heap, value);
                            break :blk string_object;
                        },
                        .nil => {
                            const nil_object: VmObject = try self.get_nil_singleton();
                            break :blk nil_object;
                        },
                    };
                    try self.push_object(object);
                },
                .send_message => |call_info| {
                    try self.send_message(call_info);
                },
                .normal_return => {
                    const next_instruction = self.top_frame().after_return_instruction_id;
                    self.decoder.set_id_of_the_next_instruction(next_instruction);
                    self.pop_frame();
                },
            }
            if (DO_DEBUG_TRACE) {
                try self.debug_print_stack();
            }
        }
        unreachable;
    }

    pub fn print_object_no_newline(self: *Self, object: VmObject) Error!void {
        if (PRINT_PTR_MODULO) {
            try self.stdout.print(" [{d:03}] ", .{@intFromPtr(object.data) % 999});
        }
        switch (object.data.kind()) {
            .integer => |accessor| try self.stdout.print("{d}", .{accessor.get_value(object.data)}),
            .double => |accessor| try self.stdout.print("{d}", .{accessor.get_value(object.data)}),
            .string => |accessor| try self.stdout.print("'{s}'", .{accessor.contents(object.data)}),
            .generic_object => |accessor| {
                const class_name: SymbolId = accessor.get_class_definition(object.data).class_name;
                const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                try self.stdout.print("Instance of class: '{s}'", .{class_name_string});
            },
            .nil => {
                try self.stdout.print("nil", .{});
            },
            .class => |accessor| {
                const class_name: SymbolId = accessor.get_represented_class(object.data).class_name;
                const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                try self.stdout.print("Instance of class: '{s} class'", .{class_name_string});
            },
            .array => |accessor| {
                const items: []VmObject = accessor.items(object.data);
                try self.stdout.print("Array: #(", .{});
                for (items, 0..) |item, idx| {
                    if (idx != 0) try self.stdout.print(", ", .{});
                    try self.print_object_no_newline(item);
                }
                try self.stdout.print(")", .{});
            },
            else => {
                return self.report_TODO("Printing of VmObject of type `{t}` is not supported yet :)", .{object.data.header.tag});
            },
        }
    }

    pub fn print_object(self: *Self, object: VmObject) Error!void {
        try self.print_object_no_newline(object);
        try self.stdout.print("\n", .{});
        try self.stdout.flush();
    }

    pub fn debug_print_stack(self: *Self) Error!void {
        std.debug.print("State of the stack:\n", .{});
        if (self.stack.frames_count() == 0) {
            std.debug.print("  (empty stack)", .{});
            if (self.stack.objects.len == 0) {
                std.debug.print(" (no objects)\n", .{});
            } else {
                std.debug.print(" Objects: \n", .{});
                for (self.stack.objects, 0..) |obj, idx| {
                    std.debug.print(" - stack[{d:02}] = ", .{idx});
                    try self.print_object(obj);
                }
            }
            return;
        }

        var object_idx: usize = 0;
        var next_frame_idx: usize = 1;
        while (next_frame_idx <= self.stack.frames_count()) : (next_frame_idx += 1) {
            const current_frame: Stack.Frame = self.stack.frames[next_frame_idx - 1];
            std.debug.print("Frame number {d:02}: \n - base_idx: {d}\n - constant_base_id: {d}\n - return_instr_id:{d}\n", .{
                next_frame_idx - 1,
                current_frame.base_idx,
                current_frame.constants_base_id().idx,
                current_frame.after_return_instruction_id.idx,
            });
            std.debug.print(" - Objects: \n", .{});

            const sentinel_object_idx: usize = blk: {
                if (next_frame_idx >= self.stack.frames_count()) {
                    break :blk self.stack.objects.len;
                } else {
                    break :blk self.stack.frames[next_frame_idx].base_idx;
                }
            };
            while (object_idx < sentinel_object_idx) : (object_idx += 1) {
                std.debug.print("    - stack[{d:02}] = ", .{object_idx});
                const obj = self.stack.objects[object_idx];
                try self.print_object(obj);
            }
        }
    }

    pub fn ensure_primitive_class_is_loaded(self: *Self, primitive_class_type: PrimitiveClassType) Error!void {
        if (self.primitive_class_definitions.contains(primitive_class_type)) {
            @branchHint(.likely);
            return;
        }
        const class_name: SymbolId = (try self.statics.symbols_manager.id_or_intern(primitive_class_type.as_string())).id;
        const class_definition = self.load_class(class_name) catch |err| {
            self.report_runtime_error("Got error '{t}' while compiling a primitive class \"{s}\".", .{ err, primitive_class_type.as_string() });
            return Error.compilation_error;
        };
        assert(self.primitive_class_definitions.getAssertContains(primitive_class_type) == class_definition);
    }

    pub fn load_class_ignore_parent(self: *Self, class_name: SymbolId) !*ClassDefinition {
        const class_pair = try compile_class_ignoring_parents(.{
            .class_name = class_name,
            .error_writer = self.stderr,
            .globals = &self.globals,
            .primitive_methods_map = self.primitive_methods,
            .source_code_files = self.source_code_files,
            .statics = self.statics,
            .temporary_allocator = self.statics.allocator, // TODO: use an actual *temporary* allocator
        });
        self.register_newly_compiled_class(class_pair, 1);

        // The bytecode array might have gotten reallocated during the compilation
        self.decoder.bytes = self.statics.instruction_encoder.view_bytecode().bytes;
        return class_pair.class;
    }

    pub fn load_class(self: *Self, class_name: SymbolId) !*ClassDefinition {
        const number_of_classes_before_load: usize = self.statics.all_classes.len;
        const class_definition_pair: ClassDefinitionPair = try compile_class_with_its_parents(.{
            .bottom_class_name = class_name,
            .error_writer = self.stderr,
            .globals = &self.globals,
            .primitive_methods_map = self.primitive_methods,
            .source_code_files = self.source_code_files,
            .statics = self.statics,
            .temporary_allocator = self.statics.allocator, // TODO: use an actual *temporary* allocator
        });
        const number_of_classes_after_load: usize = self.statics.all_classes.len;
        const number_of_compiled_classes = number_of_classes_after_load - number_of_classes_before_load;
        self.register_newly_compiled_class(class_definition_pair, number_of_compiled_classes);

        // The bytecode array might have gotten reallocated during the compilation
        self.decoder.bytes = self.statics.instruction_encoder.view_bytecode().bytes;
        return class_definition_pair.class;
    }

    fn register_newly_compiled_class(self: *Self, class_pair: ClassDefinitionPair, number_of_compiled_classes: usize) void {
        // We have to register primitive classes that might have gotten loaded
        // during the compilation.
        var class_iter: ?*ClassDefinition = class_pair.class;
        for (0..number_of_compiled_classes) |_| {
            const class = class_iter orelse break;
            defer class_iter = class.parent;
            const primitive_class_type: PrimitiveClassType = switch (class.class_name.idx) {
                SymbolsManager.comptime_id_of("Metaclass").idx => .metaclass,
                SymbolsManager.comptime_id_of("Object").idx => .object,
                SymbolsManager.comptime_id_of("Array").idx => .array,
                SymbolsManager.comptime_id_of("String").idx => .string,
                SymbolsManager.comptime_id_of("Double").idx => .double,
                SymbolsManager.comptime_id_of("Integer").idx => .integer,
                SymbolsManager.comptime_id_of("Class").idx => .class,
                SymbolsManager.comptime_id_of("Nil").idx => .nil,
                else => continue,
            };
            self.primitive_class_definitions.put(primitive_class_type, class);
        }
        // Register new metaclasses if we have a metaclass loaded
        if (self.primitive_class_definitions.get(.metaclass)) |metaclass_definition| {
            class_iter = class_pair.class;
            const class_accessor = accessors.ClassAccessor{};
            for (0..number_of_compiled_classes) |_| {
                const class = class_iter orelse break;
                defer class_iter = class.parent;
                const metaclass = class_accessor.get_class_of_represented_class(class.as_vm_object.data);
                class_accessor.set_class_of_represented_class(metaclass.as_vm_object.data, metaclass_definition);
            }
        }
    }

    pub fn push_frame(
        self: *Self,
        method: *const MethodDefinition,
        arguments_count_without_self: u16,
        locals_count: u16,
        after_return_instruction_id: InstructionId,
    ) Error!void {
        if (self.stack.frames.len >= self.stack.max_frames_len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow (too many function frames)! :D", .{});
            return Error.frame_stack_overflow;
        }
        const arguments_count = arguments_count_without_self +| 1;
        if (self.stack.objects.len +| arguments_count +| locals_count > self.stack.max_objects_len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow (too many objects)! :D", .{});
            return Error.object_stack_overflow;
        }
        // Grow the stack
        const new_base_index: u32 = @intCast(self.stack.objects.len - arguments_count);
        self.stack.frames.len += 1;
        self.stack.frames[self.stack.frames.len - 1] = Stack.Frame{
            .base_idx = new_base_index,
            .method = method,
            .after_return_instruction_id = after_return_instruction_id,
        };
        self.stack.objects.len += locals_count;
    }

    /// Asserts that the stack is not empty
    pub fn pop_frame(self: *Self) void {
        assert(self.stack.frames_count() > 0);
        // We need to not pop the top-most object on the popped frame,
        // since it is the return value of the function (therefore the `+1`):
        self.stack.objects.len = self.top_frame().base_idx + 1;
        self.stack.frames.len -= 1;
    }

    /// Asserts that the stack is not empty
    pub fn top_frame(self: *Self) *Stack.Frame {
        return self.stack.top_frame();
    }

    /// Asserts that the stack is not empty
    pub fn stack_top_object(self: Self) VmObject {
        assert(self.stack.objects.len > 0);
        return self.stack.objects[self.stack.objects.len - 1];
    }

    /// Asserts that the stack is not empty
    pub fn current_self_object(self: *Self) VmObject {
        return self.objects[self.top_frame().base_idx];
    }

    /// TODO: this will be simpler when we have NaN tagging
    pub fn get_nil_singleton(self: *Self) Error!VmObject {
        if (self.cached_nil_object) |nil| {
            @branchHint(.likely);
            return nil;
        }
        try self.ensure_primitive_class_is_loaded(.nil);
        const header = HeapData.Header.new_undefined_with_tag(.nil);
        var nil_object_data = try self.statics.allocate_for_static_object(header);
        const nil_object = nil_object_data.as_vm_object();
        self.cached_nil_object = nil_object;
        return nil_object;
    }

    pub fn push_object(self: *Self, object: VmObject) Error!void {
        if (self.stack.objects.len + 1 > self.stack.max_objects_len) {
            @branchHint(.cold);
            return Error.object_stack_overflow;
        }
        self.stack.objects.ptr[self.stack.objects.len] = object;
        self.stack.objects.len += 1;
    }

    /// Asserts that the stack is not empty
    pub fn pop_object(self: *Self) VmObject {
        assert(self.stack.objects.len > 0);
        self.stack.objects.len -= 1;
        return self.stack.objects.ptr[self.stack.objects.len];
    }

    /// Asserts that the stack is not empty
    pub fn top_stack_object(self: *Self) VmObject {
        return self.stack.objects[self.stack.objects.len - 1];
    }

    pub fn send_message(self: *Self, call_info: Instruction.SendMessage) Error!void {
        const target_object: VmObject = self.top_stack_object();
        const class: *const ClassDefinition = self.get_class_of(target_object);
        const method: *const MethodDefinition = class.get_method(call_info.message_name) orelse {
            self.report_runtime_error(
                "Tried to call the method `{s}` on an instance of a class `{s}`, but that method is not defined on that class.",
                .{ self.statics.symbols_manager.symbol_with_id(call_info.message_name), self.statics.symbols_manager.symbol_with_id(class.class_name) },
            );
            // TODO: maybe also print the methods that exist on that class?
            return Error.method_not_found;
        };

        switch (method.body) {
            .user_land => |method_body_info| {
                try self.push_frame(
                    method,
                    method.number_of_aditional_args,
                    method_body_info.number_of_locals,
                    self.decoder.id_of_next_instruction(),
                );
                self.decoder.set_id_of_the_next_instruction(method_body_info.start_instruction);
            },
            .primitive => |primitive_method| {
                _ = self.pop_object(); // The primitive methods get `target_object` via an argument
                const result_object: VmObject = primitive_method(target_object, self) catch |err| {
                    // TODO: remove this once we have a propper stack trace
                    self.report_info(
                        "Error happened in the primitive method `{s}` of class `{s}`",
                        .{ self.statics.symbols_manager.symbol_with_id(call_info.message_name), self.statics.symbols_manager.symbol_with_id(class.class_name) },
                    ) catch {};
                    return err;
                };
                try self.push_object(result_object);
            },
        }
    }

    inline fn fetch_class_by_name(self: *Self, class_name_id: SymbolId) Error!*const ClassDefinition {
        // TODO: if the class is not found, the interpreter should go and find the class definition
        const class = self.class_map.getPtr(class_name_id) orelse {
            std.debug.print("Could not find the class `{s}`\n", .{self.symbols_manager.symbol_with_id(class_name_id)});
            unreachable;
        };
        return class;
    }

    pub fn get_class_of(self: *Self, object: VmObject) *const ClassDefinition {
        // TODO: if the class is not found, the interpreter should go and find the class definition
        return switch (object.data.kind()) {
            .integer => self.primitive_class_definitions.getAssertContains(.integer),
            .double => self.primitive_class_definitions.getAssertContains(.double),
            .string => self.primitive_class_definitions.getAssertContains(.string),
            .class => |accessor| accessor.get_class_of_represented_class(object.data),
            .nil => self.primitive_class_definitions.getAssertContains(.nil),
            .array => self.primitive_class_definitions.getAssertContains(.array),

            .generic_object => |accessor| accessor.get_class_definition(object.data),
            .empty_heap_segment => unreachable,
        };
    }

    pub fn report_info(self: *Self, comptime fmt: []const u8, args: anytype) Error!void {
        try self.stderr.print(colors.CYAN ++ "[runtime-info] " ++ colors.RESET ++ fmt ++ "\n", args);
    }

    // TODO: remove this once all the major features are implemented
    pub fn report_TODO(self: *Self, comptime fmt: []const u8, args: anytype) error{TODO} {
        self.stderr.print(colors.ERR ++ "[TODO (not implemented)] " ++ colors.RESET ++ fmt ++ "\n", args) catch {};
        return error.TODO;
    }

    pub fn report_runtime_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        // Ignore error since we report errors when there already is an error
        self.stderr.print(colors.ERR ++ "[runtime-error] " ++ colors.RESET ++ fmt ++ "\n", args) catch return;
    }

    // TODO: position of the error
    fn report_primitive_method_type_mismatch(
        self: *Self,
        expected_type_name: []const u8,
        actual_type_name: []const u8,
        method_name: []const u8,
    ) Error {
        // Ignore error since we eport errors when there already is an error
        self.report_runtime_error(
            "In method `{s}`, the argument had type `{s}`, which was not possible to convert to required type `{s}`",
            .{ method_name, actual_type_name, expected_type_name },
        );
        return Error.primitive_type_error;
    }
};

pub const PrimitiveClassType = enum {
    object,
    integer,
    double,
    string,
    nil,
    array,
    class,
    metaclass,
    // TODO: remaining primitive classes

    const Self = @This();
    pub fn as_string(self: Self) []const u8 {
        return switch (self) {
            .object => "object",
            .integer => "Integer",
            .double => "Double",
            .string => "String",
            .nil => "Nil",
            .array => "Array",
            .class => "Class",
            .metaclass => "Metaclass",
        };
    }
};

test {
    _ = @import("testing.zig");
}
