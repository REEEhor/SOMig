pub const DO_DEBUG_TRACE: bool = false;
pub const PRINT_PTR_MODULO: bool = true;

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
const Bytecode = codegen_module.Bytecode;
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
pub const BlockDefinition = codegen_module.BlockDefinition;

pub const vm_object_module = @import("vm_object.zig");
pub const VmObject = vm_object_module.VmObject;
pub const HeapData = vm_object_module.HeapData;
pub const types = vm_object_module.types;

const primitives_module = @import("primitives/__primitives.zig");
pub const primitives = primitives_module.primitive_classes;
pub const PrimitiveMethodsMap = primitives_module.PrimitiveMethodsMap;
pub const PrimitiveMethodImplementation = primitives_module.PrimitiveMethodImplementation;

pub const class_definition_module = @import("class_definition.zig");
pub const ClassDefinition = class_definition_module.ClassDefinition;
pub const MethodBody = class_definition_module.MethodBody;
pub const MethodDefinition = class_definition_module.MethodDefinition;
pub const FunctionBody = class_definition_module.FunctionBody;

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
        base_ptr: [*]VmObject,
        after_return_instruction_id: InstructionId,
        kind: Kind,

        pub const Kind = union(enum) {
            /// Has guaranteed that the `body` is of type `user_land`.
            method: *const MethodDefinition,
            block: *types.Block,
        };

        pub fn self_object_ptr(self: @This()) *VmObject {
            const number_of_args = switch (self.kind) {
                .method => |method| method.number_of_aditional_args,
                .block => |block| block.block_definition.number_of_aditional_args,
            };
            return &self.base_ptr[number_of_args];
        }

        pub fn constants_base_id(self: @This()) ConstantId {
            return switch (self.kind) {
                .method => |method| method.body.user_land.constants_base_id,
                .block => |block| block.block_definition.body.constants_base_id,
            };
        }

        pub fn get_bytecode(self: @This()) Bytecode {
            return switch (self.kind) {
                .method => |method| method.body.user_land.bytecode,
                .block => |block| block.block_definition.body.bytecode,
            };
        }

        pub fn get_variable_ptr(self: @This(), objects: []VmObject, offset: u32) *VmObject {
            return &objects[self.base_ptr + offset];
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

pub const BuiltinClassDefinitions = struct {
    nil: ?*ClassDefinition = null,
    object: ?*ClassDefinition = null,
    class: ?*ClassDefinition = null,
    metaclass: ?*ClassDefinition = null,
    true: ?*ClassDefinition = null,
    false: ?*ClassDefinition = null,
    integer: ?*ClassDefinition = null,
    double: ?*ClassDefinition = null,
    array: ?*ClassDefinition = null,
    string: ?*ClassDefinition = null,
    symbol: ?*ClassDefinition = null,
    block1: ?*ClassDefinition = null,
    block2: ?*ClassDefinition = null,
    block3: ?*ClassDefinition = null,
    // TODO: method
    // TODO: primitive

    pub fn block_from_number_of_non_self_arguments(self: @This(), number_of_non_self_arguments: u16) ?*const ClassDefinition {
        return switch (number_of_non_self_arguments) {
            0 => self.block1,
            1 => self.block2,
            2 => self.block3,
            else => unreachable,
        };
    }
};

// TODO: track the current function (which will be probably in the final `stack` implementation, which will also store stack frames)
// and use it for error reporting.
pub const Interpreter = struct {
    decoder: InstructionDecoder,
    globals: std.AutoArrayHashMap(SymbolId, VmObject),
    statics: *Statics,
    heap: Heap,

    heap_allocator: Allocator,

    stdout: *Writer,
    stderr: *Writer,

    primitive_methods: PrimitiveMethodsMap,
    builtin_class_definitions: BuiltinClassDefinitions = undefined,

    source_code_files: *SourceCodeFiles,

    singletons: struct {
        true_object: VmObject,
        false_object: VmObject,
        // NOTE: here will also maybe be the `System` object
    } = undefined, // TODO: move compilation of classes outside of `Interpreter` so we don't have to have this undefined

    stack: Stack,

    debug_frame_to_initialised_objects_mapping: if (DO_DEBUG_TRACE) std.DynamicBitSetUnmanaged else void = if (DO_DEBUG_TRACE) .{} else {},

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
        var interpreter = Interpreter{
            .decoder = InstructionDecoder.empty,
            .stdout = stdout,
            .stderr = stderr,
            .statics = statics,
            .heap = Heap{ .arena = std.heap.ArenaAllocator.init(allocator_for_heap) },
            .heap_allocator = undefined,
            .primitive_methods = primitive_methods,
            .globals = .init(allocator_for_globals),
            .source_code_files = source_code_files,
            .builtin_class_definitions = .{},
            .stack = Stack.init(preallocated_frame_stack, preallocated_object_stack),
        };
        if (DO_DEBUG_TRACE) {
            interpreter.debug_frame_to_initialised_objects_mapping = std.DynamicBitSetUnmanaged.initEmpty(statics.allocator, preallocated_object_stack.len) catch unreachable;
        }

        return interpreter;
    }

    pub const NewObjectAllocationStrategy = enum { heap, static };

    pub fn run(self: *Self) !void {
        while (true) {
            const instr_id = self.decoder.id_of_next_instruction();
            const instruction: Instruction = self.decoder.next_instruction() orelse {
                try self.report_info("The end of the bytecode has been reached.", .{});
                return;
            };
            if (DO_DEBUG_TRACE) {
                const formatter = codegen_module.InstructionFormatter{
                    .base_constant_id = self.top_frame().constants_base_id(),
                    .constants_manager = &self.statics.constants_manager,
                    .symbols_manager = &self.statics.symbols_manager,
                    .use_color = true,
                };
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
                .load_local => |info| {
                    // FIXME: go up multiple frames
                    assert(info.required_frame_up_steps == 0);

                    const object: VmObject = self.top_frame().base_ptr[info.local_id.idx];
                    try self.push_object(object);
                },
                .set_local => |info| {
                    // FIXME: go up multiple frames
                    assert(info.required_frame_up_steps == 0);

                    const to_assign: VmObject = self.stack.objects[self.stack.objects.len - 1];
                    self.top_frame().base_ptr[info.local_id.idx] = to_assign;

                    if (DO_DEBUG_TRACE) {
                        const object_index = undefined;
                        self.debug_frame_to_initialised_objects_mapping.set(object_index);
                    }
                },
                .load_instance_var => |info| {
                    // FIXME: go up multiple frames
                    assert(info.required_frame_up_steps == 0);

                    const self_object: VmObject = self.top_frame().self_object_ptr().*;
                    const instance_variable = switch (self_object.kind()) {
                        .generic_object => |object| object.get_fields()[info.instance_var_id.idx],
                        // FIXME: implement this
                        .class => return self.report_TODO("Loading of class variables", .{}),
                        else => unreachable,
                    };
                    try self.push_object(instance_variable);
                },
                .set_instance_var => |info| {
                    // FIXME: go up multiple frames
                    assert(info.required_frame_up_steps == 0);

                    const top_object: VmObject = self.top_stack_object();
                    const self_object: VmObject = self.top_frame().self_object_ptr().*;
                    switch (self_object.kind()) {
                        .generic_object => |object| object.get_fields()[info.instance_var_id.idx] = top_object,
                        // FIXME: implement this
                        .class => return self.report_TODO("Setting of class variables", .{}),
                        else => unreachable,
                    }
                },
                .pop_into_new_array => |info| {
                    // Get the items slice from the stack
                    const items_count = info.number_of_items;
                    const len = self.stack.objects.len;
                    const items_start_idx = len - items_count;
                    const items: []VmObject = self.stack.objects[items_start_idx..len];

                    // Create the array object
                    const array_object: VmObject = try types.Array.create_new(self.heap_allocator, items);

                    // Pop all the objects that were copied into the new array
                    const old_stack_len = self.stack.objects.len;
                    self.stack.objects.len = items_start_idx;
                    const new_stack_len = self.stack.objects.len;

                    if (DO_DEBUG_TRACE) {
                        for (new_stack_len..old_stack_len) |index| {
                            self.debug_frame_to_initialised_objects_mapping.unset(index);
                        }
                    }

                    try self.push_object(array_object);
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
                .load_symbol => |symbol_id| {
                    const object: VmObject = try types.Symbol.create_new(self.heap_allocator, symbol_id);
                    try self.push_object(object);
                },
                .duplicate => {
                    const object = self.stack_top_object();
                    try self.push_object(object);
                },
                .load_constant => |constant_info| {
                    const constant_id: ConstantId = constant_info.id.to_absolute(self.top_frame().constants_base_id());
                    const constant = self.statics.constants_manager.get_constant(constant_id);
                    const allocator = self.heap.arena.allocator();
                    const object: VmObject = switch (constant) {
                        .integer => |value| try types.Integer.create_new(self.heap.arena.allocator(), value),
                        .float => |value| try types.Double.create_new(allocator, value),
                        .string => |value| try types.String.create_new(allocator, value),
                        .block => |block_info| try types.Block.create_new(allocator, block_info, self.top_frame()),
                    };
                    try self.push_object(object);
                },
                .load_nil => try self.push_object(VmObject.nil),
                .load_true => try self.push_object(self.singletons.true_object),
                .load_false => try self.push_object(self.singletons.false_object),
                .resolved_method_call => |call_info| {
                    const method_ptr: *const MethodDefinition = call_info.method_ptr.pointee();
                    try self.call_method(method_ptr);
                },
                .send_message => |call_info| {
                    try self.send_message(call_info);
                },
                .normal_return => {
                    const return_value: VmObject = self.top_stack_object();

                    const next_instruction = self.top_frame().after_return_instruction_id;
                    self.decoder.set_id_of_the_next_instruction(next_instruction);

                    // Leaves a spot at the top of the stack for the `return_value`
                    self.pop_frame();
                    if (self.stack.frames.len == 0) {
                        try self.report_info("The program's entry point function has returned", .{});
                        return;
                    }

                    // Put the return value on the top of the stack
                    self.stack.objects[self.stack.objects.len - 1] = return_value;

                    const bytecode = self.top_frame().get_bytecode();
                    self.decoder.bytes = bytecode.bytes;
                },
            }
            if (DO_DEBUG_TRACE) {
                try self.debug_print_stack();
                std.debug.print("\n", .{});
            }
        }
        unreachable;
    }

    pub fn print_object_no_newline(self: *Self, object: VmObject) Error!void {
        if (PRINT_PTR_MODULO) {
            try self.stdout.print(" [{d:03}] ", .{@intFromPtr(object.data) % 999});
        }
        switch (object.kind()) {
            .integer => |int| try self.stdout.print("{d}", .{int.header.value}),
            .double => |double| try self.stdout.print("{d}", .{double.value}),
            .string => |string| {
                for (string.contents()) |char| {
                    switch (char) {
                        '\n' => try self.stdout.write("\\n"),
                        '\r' => try self.stdout.write("\\r"),
                        else => if (std.ascii.isPrint(char)) {
                            try self.stdout.writeByte(char);
                        } else {
                            try self.stdout.print("\\x{x}", .{char});
                        },
                    }
                }
            },
            .generic_object => |generic_object| {
                const class_name: SymbolId = generic_object.class.class_name;
                switch (class_name.idx) {
                    SymbolsManager.comptime_id_of("True").idx => try self.stdout.print("true", .{}),
                    SymbolsManager.comptime_id_of("False").idx => try self.stdout.print("false", .{}),
                    else => {
                        const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                        try self.stdout.print("Instance of class: '{s}'", .{class_name_string});
                    },
                }
            },
            .nil => {
                try self.stdout.print("nil", .{});
            },
            .class => |class| {
                const class_name: SymbolId = class.represented_class.class_name;
                const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                try self.stdout.print("Instance of class: '{s} class'", .{class_name_string});
            },
            .array => |array| {
                const items: []VmObject = array.get_items();
                try self.stdout.print("Array: #(", .{});
                for (items, 0..) |item, idx| {
                    if (idx != 0) try self.stdout.print(", ", .{});
                    try self.print_object_no_newline(item);
                }
                try self.stdout.print(")", .{});
            },
            .symbol => |symbol| {
                const symbol_id: SymbolId = symbol.header.symbol_id;
                const symbol_string = self.statics.symbols_manager.symbol_with_id(symbol_id);
                try self.stdout.print("symbol '{s}' id({d})", .{ symbol_string, symbol_id.idx });
            },
            .block => {
                try self.stdout.print("block (yup, this is not really helpful info)", .{});
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
                    if (DO_DEBUG_TRACE) {
                        if (!self.debug_frame_to_initialised_objects_mapping.isSet(idx)) {
                            std.debug.print(colors.FAINT ++ colors.YELLOW ++ " garbage \n" ++ colors.RESET, .{});
                            return;
                        }
                    }
                    try self.print_object(obj);
                }
            }
            return;
        }

        var object_idx: usize = 0;
        var next_frame_idx: usize = 1;
        while (next_frame_idx <= self.stack.frames_count()) : (next_frame_idx += 1) {
            const current_frame: Stack.Frame = self.stack.frames[next_frame_idx - 1];
            const frame_format_string = "[Frame {d:02} cons_base={d:03} ret_inst={d:03}] ";
            const frame_args = .{
                next_frame_idx - 1,
                current_frame.constants_base_id().idx,
                current_frame.after_return_instruction_id.idx,
            };
            const frame_length = std.fmt.count(frame_format_string, frame_args);
            std.debug.print(frame_format_string, frame_args);

            const sentinel_object_idx: usize = blk: {
                if (next_frame_idx >= self.stack.frames_count()) {
                    break :blk self.stack.objects.len;
                } else {
                    break :blk self.stack.frames[next_frame_idx].base_ptr;
                }
            };
            var first_iteration = true;
            while (object_idx < sentinel_object_idx) : (object_idx += 1) {
                if (!first_iteration) {
                    for (0..frame_length) |_| std.debug.print(" ", .{});
                }
                first_iteration = false;
                std.debug.print("[{d:02}]", .{object_idx});
                const obj = self.stack.objects[object_idx];
                if (DO_DEBUG_TRACE) {
                    if (!self.debug_frame_to_initialised_objects_mapping.isSet(object_idx)) {
                        std.debug.print(colors.FAINT ++ colors.YELLOW ++ " garbage \n" ++ colors.RESET, .{});
                        continue;
                    }
                }
                try self.print_object(obj);
            }
        }
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
            .builtin_class_definitions = &self.builtin_class_definitions,
        });
        return class_pair.class;
    }

    pub fn load_class(self: *Self, class_name: SymbolId) !*ClassDefinition {
        const class_definition_pair: ClassDefinitionPair = try compile_class_with_its_parents(.{
            .bottom_class_name = class_name,
            .error_writer = self.stderr,
            .globals = &self.globals,
            .primitive_methods_map = self.primitive_methods,
            .source_code_files = self.source_code_files,
            .statics = self.statics,
            .temporary_allocator = self.statics.allocator, // TODO: use an actual *temporary* allocator
            .builtin_class_definitions = &self.builtin_class_definitions,
        });

        // The bytecode array might have gotten reallocated during the compilation
        return class_definition_pair.class;
    }

    pub fn push_frame(
        self: *Self,
        frame_kind: Stack.Frame.Kind,
        bytecode: Bytecode,
        arguments_count_without_self: u16,
        locals_count: u16,
    ) Error!void {
        if (self.stack.frames.len >= self.stack.max_frames_len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow (too many function frames)! :D", .{});
            return Error.frame_stack_overflow;
        }
        const arguments_count: usize = @as(usize, arguments_count_without_self) + 1;
        if (self.stack.objects.len + arguments_count + locals_count > self.stack.max_objects_len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow (too many objects)! :D", .{});
            return Error.object_stack_overflow;
        }
        // Grow the stack
        const new_base_ptr: [*]VmObject = self.stack.objects.ptr + self.stack.objects.len - arguments_count;
        self.stack.frames.len += 1;
        self.stack.frames[self.stack.frames.len - 1] = Stack.Frame{
            .base_ptr = new_base_ptr,
            .kind = frame_kind,
            .after_return_instruction_id = self.decoder.id_of_next_instruction(),
        };
        self.stack.objects.len += locals_count;
        self.decoder = .new(bytecode);
    }

    /// Asserts that the stack is not empty
    pub fn pop_frame(self: *Self) void {
        assert(self.stack.frames_count() > 0);
        // We need to not pop the top-most object on the popped frame,
        // since there will be the return value of function that is getting returned out of
        // (therefore the `+1`):
        const new_objects_len = (self.top_frame().base_ptr + 1) - self.stack.objects.ptr;
        const old_objects_len = self.stack.objects.len;
        self.stack.objects.len = new_objects_len;
        self.stack.frames.len -= 1;

        if (DO_DEBUG_TRACE) {
            for (new_objects_len..old_objects_len) |object_idx| {
                self.debug_frame_to_initialised_objects_mapping.unset(object_idx);
            }
        }
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
        return self.objects[self.top_frame().base_ptr];
    }

    pub fn push_object(self: *Self, object: VmObject) Error!void {
        if (self.stack.objects.len + 1 > self.stack.max_objects_len) {
            @branchHint(.cold);
            return Error.object_stack_overflow;
        }
        const object_index = self.stack.objects.len;
        self.stack.objects.ptr[object_index] = object;
        self.stack.objects.len += 1;

        if (DO_DEBUG_TRACE) {
            self.debug_frame_to_initialised_objects_mapping.set(object_index);
        }
    }

    /// Asserts that the stack is not empty
    pub fn pop_object(self: *Self) VmObject {
        assert(self.stack.objects.len > 0);
        self.stack.objects.len -= 1;
        const object_index = self.stack.objects.len;
        if (DO_DEBUG_TRACE) {
            self.debug_frame_to_initialised_objects_mapping.unset(object_index);
        }
        return self.stack.objects.ptr[object_index];
    }

    /// Asserts that the stack is not empty
    pub fn top_stack_object(self: *Self) VmObject {
        return self.stack.objects[self.stack.objects.len - 1];
    }

    pub fn call_method(self: *Self, method: *const MethodDefinition) Error!void {
        switch (method.body) {
            .user_land => |method_body_info| {
                try self.push_frame(
                    .{ .method = method },
                    method_body_info.bytecode,
                    method.number_of_aditional_args,
                    method_body_info.number_of_locals,
                );
            },
            .primitive => |primitive_method| {
                const target_object = self.pop_object();
                const result_object: ?VmObject = primitive_method(target_object, self) catch |err| {
                    // TODO: remove this once we have a propper stack trace
                    self.report_info(
                        "Error happened in the primitive method `{s}`",
                        .{self.statics.symbols_manager.symbol_with_id(method.method_name)},
                    ) catch {};
                    return err;
                };
                if (result_object) |object| try self.push_object(object);
            },
        }
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

        try self.call_method(method);
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
        return switch (object.kind()) {
            .class => |class| class.class_of_represented_class,
            .generic_object => |generic_object| generic_object.class,

            .integer => self.builtin_class_definitions.integer.?,
            .double => self.builtin_class_definitions.double.?,
            .string => self.builtin_class_definitions.string.?,
            .nil => self.builtin_class_definitions.nil.?,
            .array => self.builtin_class_definitions.array.?,
            .symbol => self.builtin_class_definitions.symbol.?,
            .block => |block| self.builtin_class_definitions.block_from_number_of_non_self_arguments(
                block.block_definition.number_of_aditional_args,
            ).?,
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

test {
    _ = @import("testing.zig");
}
