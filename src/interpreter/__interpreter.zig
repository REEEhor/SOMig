// pub const DO_DEBUG_TRACE: bool = true;
pub const DO_DEBUG_TRACE: bool = false;
pub const PRINT_PTR_MODULO: bool = true;
pub const DEBUG_CLEAR_SCREEN: bool = true;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const colors = @import("../terminal.zig");

const unions = @import("../unions.zig");

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
pub const FrameOnHeap = vm_object_module.FrameOnHeap;

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

    /// NOTE: This must be a `SegmentedList`, because we want to be able to store pointers to `MethodDefinition` in other structures.
    ///       If this was just an `ArrayList`, then the pointers to `MethodDefinition`s would get invalidated during reallocations.
    all_methods: std.SegmentedList(MethodDefinition, 128),

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
        escaped_blocks_list_head: ?*types.Block = null,

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

        pub fn number_of_args_and_locals(self: @This()) usize {
            // NOTE: We have to do `1 + ` to include the `self` in the number of arguments
            return switch (self.kind) {
                .method => |method| 1 + method.number_of_aditional_args + method.body.user_land.number_of_locals,
                .block => |block| 1 + block.block_definition.number_of_aditional_args + block.block_definition.body.number_of_locals,
            };
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

    pub fn pop_all_temporaries_from_top_frame(self: *Self) void {
        const base_ptr: [*]VmObject = self.top_frame().base_ptr;
        const number_of_args_and_locals: usize = self.top_frame().number_of_args_and_locals();
        const ptr_to_first_temporary: [*]VmObject = base_ptr + number_of_args_and_locals;
        const new_length: usize = index_or_length_from_pointer(ptr_to_first_temporary, self.objects).?;
        self.objects.len = new_length;
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
    system: ?*ClassDefinition = null,
    method: ?*ClassDefinition = null,
    primitive: ?*ClassDefinition = null,

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

    timer: ?std.time.Timer,

    /// TODO: put this into an argument and maybe set it to `false` by default
    do_flush_on_every_print: bool = true,
    /// TODO: put this into an argument and maybe set it to `false` by default
    nil_out_items_of_new_array: bool = false,

    singletons: struct {
        true_object: VmObject,
        false_object: VmObject,
        system: VmObject,

        pub fn get_boolean_object(self: @This(), boolean: bool) VmObject {
            if (boolean) {
                return self.true_object;
            }
            return self.false_object;
        }
    } = undefined, // TODO: move compilation of classes outside of `Interpreter` so we don't have to have this undefined

    stack: Stack,

    debug_frame_to_initialised_objects_mapping: if (DO_DEBUG_TRACE) std.DynamicBitSetUnmanaged else void = if (DO_DEBUG_TRACE) .{} else {},
    debug_max_set_object: if (DO_DEBUG_TRACE) usize else void = if (DO_DEBUG_TRACE) 0 else {},

    const Self = @This();

    pub const Error = error{
        /// TODO: maybe remove this and replace all instances with a proper error
        generic_runtime_error,
        primitive_type_error,
        method_not_found,
        frame_stack_overflow,
        object_stack_overflow,
        class_declared_multiple_times,
        division_by_zero,
        compilation_error,
        block_escaped_its_home_scope,
        out_of_bounds,

        /// TODO: remove this
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
            .timer = null,
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
        self.timer = std.time.Timer.start() catch blk: {
            // TODO: make this a warning
            self.report_runtime_error("Could not initialise internal timer. `system time` and `system ticks` will return 0 every time.", .{});
            break :blk null;
        };

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
                std.debug.print("\nCurrently executing: [{d:04}]{f}", .{ instr_id.idx, formatter.fmt(instruction) });
            }
            sw_instruction: switch (instruction) {
                .no_op => {},
                .halt => {
                    try self.report_info("The halt instruction has been encountered.", .{});
                    return;
                },
                .pop => {
                    _ = self.pop_object();
                },
                .load_local => |info| {
                    // TODO: create a different instruction for going up the frames and a different one for not going up the frames (so we don't have to have this loop here)
                    // NOTE: or maybe don't do that? The loop is pretty simple...

                    var result_frame: *Stack.Frame = self.top_frame();
                    for (0..info.required_frame_up_steps) |_| {
                        result_frame = switch (result_frame.kind) {
                            .method => unreachable, // If we want to go up the frame, it should be only viable via a block, not method.
                            .block => |block_object| block_object.home_frame,
                        };
                    }

                    const object: VmObject = result_frame.base_ptr[info.local_id.idx];
                    try self.push_object(object);
                },
                .set_local => |info| {
                    // TODO: create a different instruction for going up the frames and a different one for not going up the frames (so we don't have to have this loop here)
                    // NOTE: or maybe don't do that? The loop is pretty simple...

                    var result_frame: *Stack.Frame = self.top_frame();
                    for (0..info.required_frame_up_steps) |_| {
                        result_frame = switch (result_frame.kind) {
                            .method => unreachable, // If we want to go up the frame, it should be only viable via a block, not method.
                            .block => |block_object| block_object.home_frame,
                        };
                    }

                    const to_assign: VmObject = self.stack.objects[self.stack.objects.len - 1];
                    result_frame.base_ptr[info.local_id.idx] = to_assign;

                    if (to_assign.as_block()) |block| if (info.required_frame_up_steps != 0) {
                        @branchHint(.unlikely);
                        block.add_to_escaped_blocks_list();
                    };

                    if (DO_DEBUG_TRACE) {
                        const ptr = &result_frame.base_ptr[info.local_id.idx];
                        if (index_from_pointer(ptr, self.stack.objects)) |index| {
                            self.debug_frame_to_initialised_objects_mapping.set(index);
                        }
                    }
                },
                .load_instance_var => |info| {
                    const self_object: VmObject = self.top_frame().self_object_ptr().*;
                    const instance_variable = self_object.get_instance_fields()[info.instance_var_id.idx];
                    try self.push_object(instance_variable);
                },
                .set_instance_var => |info| {
                    const top_object: VmObject = self.top_stack_object().*;
                    const self_object: VmObject = self.top_frame().self_object_ptr().*;
                    self_object.get_instance_fields()[info.instance_var_id.idx] = top_object;

                    // If we have assigned a block to an instance variable, we say that the block
                    // will escape and out-live its home frame.
                    if (top_object.as_block()) |block| {
                        @branchHint(.unlikely);
                        block.add_to_escaped_blocks_list();
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
                        try self.push_object(VmObject.from(newly_loaded_class.as_vm_object));
                    }
                },
                // .set_global => |global_symbol_id| {
                // //  TODO: once we implent `.set_global`, we need to ensure, that check if assigned object is block and add it to the escaped blocks
                // },
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
                    const return_value: VmObject = self.top_stack_object().*;

                    if (return_value.as_block()) |block| {
                        @branchHint(.cold);
                        block.add_to_escaped_blocks_list();
                    }

                    // Leaves a spot at the top of the stack for the `return_value`
                    const next_instruction = (try self.pop_frame()).next_instruction;
                    if (self.stack.frames.len == 0) {
                        try self.report_info("The program's entry point function has returned", .{});
                        return;
                    }

                    // Put the return value on the top of the stack
                    self.top_stack_object().* = return_value;

                    const bytecode = self.top_frame().get_bytecode();
                    self.decoder.bytes = bytecode.bytes;
                    self.decoder.set_id_of_the_next_instruction(next_instruction);
                },
                .non_local_return => {
                    const return_value: VmObject = self.top_stack_object().*;

                    const wanted_frame: *Stack.Frame = switch (self.top_frame().kind) {
                        .block => |block| blk: {
                            if (block.header.has_escaped_home_context) {
                                @branchHint(.cold);
                                self.report_runtime_error("A non local return was encountered in a block that has escaped its home scope.", .{});
                                return Error.block_escaped_its_home_scope;
                            }
                            break :blk block.home_frame;
                        },
                        .method => unreachable, // We should never encounter a non local in a method
                    };

                    // We know that we want to pop at least one frame (the block frame)
                    _ = try self.pop_frame();
                    while (wanted_frame != self.top_frame()) {
                        // We should never fail to pop frame here,
                        // since we assert above, that the block has not escaped its home context.
                        _ = try self.pop_frame();
                    }

                    // Put the return value on the top of the stack
                    self.top_stack_object().* = return_value;

                    continue :sw_instruction .normal_return;
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
            std.debug.print(" [{d:03}] ", .{@intFromPtr(object.data) % 999});
        }
        switch (object.kind()) {
            .integer => |int| std.debug.print("{d}", .{int.header.value}),
            .double => |double| std.debug.print("{d}", .{double.value}),
            .string => |string| {
                std.debug.print("'", .{});
                try codegen_module.print_escaped_string(self.stdout, string.contents());
                std.debug.print("'", .{});
            },
            .generic_object => |generic_object| {
                const class_name: SymbolId = generic_object.class.class_name;
                switch (class_name.idx) {
                    SymbolsManager.comptime_id_of("True").idx => std.debug.print("true", .{}),
                    SymbolsManager.comptime_id_of("False").idx => std.debug.print("false", .{}),
                    else => {
                        const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                        std.debug.print("Instance of class: '{s}'", .{class_name_string});
                    },
                }
            },
            .nil => {
                std.debug.print("nil", .{});
            },
            .class => |class| {
                const class_name: SymbolId = class.represented_class.class_name;
                const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                std.debug.print("Instance of class: '{s} class'", .{class_name_string});
            },
            .array => |array| {
                const items: []VmObject = array.get_items();
                std.debug.print("Array: #(", .{});
                for (items, 0..) |item, idx| {
                    if (idx > 1) {
                        std.debug.print("... {d} more", .{items.len - idx});
                        break;
                    }
                    if (idx != 0) std.debug.print(", ", .{});
                    try self.print_object_no_newline(item);
                }
                std.debug.print(")", .{});
            },
            .symbol => |symbol| {
                const symbol_id: SymbolId = symbol.header.symbol_id;
                const symbol_string = self.statics.symbols_manager.symbol_with_id(symbol_id);
                std.debug.print("symbol '{s}' id({d})", .{ symbol_string, symbol_id.idx });
            },
            .block => |block| {
                std.debug.print("block esc:{s} from: ", .{
                    if (block.header.has_escaped_home_context) "true " else "false",
                });
                try self.print_object_no_newline(VmObject.from(block.home_method().as_vm_object));
            },
            .system => {
                std.debug.print("system_singleton", .{});
            },
            .method => |method| {
                std.debug.print("Method '{s}' from '{s}'", .{
                    self.string_from_symbol(method.method().method_name),
                    self.string_from_symbol(method.method().source_class.class_name),
                });
            },
            .empty_heap_segment => unreachable,
            .frame_header => unreachable,
        }
    }

    pub fn print_object(self: *Self, object: VmObject) Error!void {
        try self.print_object_no_newline(object);
        std.debug.print("\x1b[0K", .{});
        std.debug.print("\n", .{});
    }

    pub fn debug_print_stack(self: *Self) Error!void {
        std.debug.print("\x1b[H", .{});
        defer std.debug.print("\x1b[0J", .{});
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
            const frame_format_string = "[{d:02} {s:<15} cons_base={d:03} ret_inst={d:03}] ";
            const frame_args = .{
                next_frame_idx - 1,
                switch (current_frame.kind) {
                    .method => |method| self.statics.symbols_manager.symbol_with_id(method.method_name),
                    .block => "block",
                },
                current_frame.constants_base_id().idx,
                current_frame.after_return_instruction_id.idx,
            };
            const frame_length = std.fmt.count(frame_format_string, frame_args) + 2;
            std.debug.print("• " ++ frame_format_string, frame_args);

            const sentinel_object_idx: usize = blk: {
                if (next_frame_idx >= self.stack.frames_count()) {
                    break :blk self.stack.objects.len;
                } else {
                    break :blk self.stack.frames[next_frame_idx].base_ptr - self.stack.objects.ptr;
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
    pub fn pop_frame(self: *Self) Allocator.Error!struct { next_instruction: InstructionId } {
        assert(self.stack.frames_count() > 0);

        var number_of_escaped_blocks: if (DO_DEBUG_TRACE) i32 else void = if (DO_DEBUG_TRACE) 0 else {};
        if (self.top_frame().escaped_blocks_list_head) |first_escaped_block| {
            const heap_frame: *Stack.Frame = try FrameOnHeap.reallocate_frame_to_heap(
                self.heap_allocator,
                self.top_frame().*,
            );
            switch (self.top_frame().kind) {
                .block => |block| block.add_to_escaped_blocks_list(),
                .method => {},
            }
            var escaped_block = first_escaped_block;
            while (true) {
                assert(escaped_block.home_frame == self.top_frame());
                assert(escaped_block.header.has_escaped_home_context == false);
                if (DO_DEBUG_TRACE) number_of_escaped_blocks += 1;
                escaped_block.home_frame = heap_frame;
                escaped_block.header.has_escaped_home_context = true;
                escaped_block = escaped_block.next_escaped_block orelse break;
            }
        }
        if (DO_DEBUG_TRACE) {
            std.debug.print("(popped a stackframe with {d} escaped blocks)\n", .{number_of_escaped_blocks});
        }

        // We need to not pop the top-most object on the popped frame,
        // since there will be the return value of function that is getting returned out of
        // (therefore the `+1`):
        const after_return_instruction_id = self.top_frame().after_return_instruction_id;
        const new_objects_len = (self.top_frame().base_ptr + 1) - self.stack.objects.ptr;
        const old_objects_len = self.stack.objects.len;
        self.stack.objects.len = new_objects_len;
        self.stack.frames.len -= 1;

        if (DO_DEBUG_TRACE) {
            for (new_objects_len..old_objects_len) |object_idx| {
                self.debug_frame_to_initialised_objects_mapping.unset(object_idx);
            }
        }

        return .{ .next_instruction = after_return_instruction_id };
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
            self.report_runtime_error("Stack overflow (too many objects)! :D", .{});
            return Error.object_stack_overflow;
        }
        const object_index = self.stack.objects.len;
        self.stack.objects.ptr[object_index] = object;
        self.stack.objects.len += 1;

        if (DO_DEBUG_TRACE) {
            self.debug_frame_to_initialised_objects_mapping.set(object_index);
            if (self.debug_max_set_object < self.stack.objects.len) {
                self.debug_max_set_object = self.stack.objects.len;
                if (DEBUG_CLEAR_SCREEN) {
                    std.debug.print("\x1b[2J", .{});
                }
            }
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
    pub fn top_stack_object(self: *Self) *VmObject {
        return &self.stack.objects[self.stack.objects.len - 1];
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
                const result_object: ?VmObject = primitive_method(self) catch |err| {
                    self.report_info(
                        "Error happened in the primitive method `{s}`", // TODO: add the classname here once we can do `method.class`
                        .{self.statics.symbols_manager.symbol_with_id(method.method_name)},
                    ) catch {};
                    return err;
                };
                if (result_object) |object| try self.push_object(object);
            },
        }
    }

    pub fn send_message(self: *Self, call_info: Instruction.SendMessage) Error!void {
        const target_object: VmObject = self.top_stack_object().*;
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
        // TODO(consultation): what to do here? Can we use `.kind()` here?
        return switch (object.kind()) {
            .class => |class| class.class_of_represented_class,
            .generic_object => |generic_object| generic_object.class,

            .integer => self.builtin_class_definitions.integer.?,
            .double => self.builtin_class_definitions.double.?,
            .string => self.builtin_class_definitions.string.?,
            .nil => self.builtin_class_definitions.nil.?,
            .array => self.builtin_class_definitions.array.?,
            .symbol => self.builtin_class_definitions.symbol.?,
            .system => self.builtin_class_definitions.system.?,

            .block => |block| self.builtin_class_definitions.block_from_number_of_non_self_arguments(
                block.block_definition.number_of_aditional_args,
            ).?,

            .method => |method| blk: {
                if (method.is_primitive()) break :blk self.builtin_class_definitions.primitive.?;
                break :blk self.builtin_class_definitions.method.?;
            },

            .frame_header => unreachable,
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

    pub fn string_from_symbol(self: *Self, symbol_id: SymbolId) []const u8 {
        return self.statics.symbols_manager.symbol_with_id(symbol_id);
    }

    pub fn check_out_of_bounds_get_1_based_index(self: *Self, params: struct { accessee: []const u8, length: usize, access_index: i48 }) Error!usize {
        const accessee = params.accessee;
        const length = params.length;
        const access_index = params.access_index;
        if (access_index == 0) {
            @branchHint(.cold);
            self.report_runtime_error("Out of bounds: Tried to access {s} at index 0. SOM has 1 based indexing ;)", .{accessee});
            return Error.out_of_bounds;
        }
        if (access_index < 1) {
            @branchHint(.cold);
            self.report_runtime_error("Out of bounds: Tried to access {s} at index {d}.", .{ accessee, access_index });
            return Error.out_of_bounds;
        }
        if (access_index > length) {
            @branchHint(.cold);
            self.report_runtime_error(
                "Out of bounds: Tried to access {s} of length {d} at index {d}. Valid indexes are 1..{d}(inclusive).",
                .{ accessee, length, access_index, length },
            );
            return Error.out_of_bounds;
        }
        return @intCast(access_index);
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

/// TODO: maybe refactor together with `index_or_length_from_pointer`
fn index_from_pointer(ptr_to_item: anytype, slice: anytype) ?usize {
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.size == .slice);
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.child == @typeInfo(@TypeOf(ptr_to_item)).pointer.child);

    const min: usize = @intFromPtr(slice.ptr);
    const max: usize = @intFromPtr(slice.ptr + slice.len);
    const value: usize = @intFromPtr(ptr_to_item);

    const check = (min <= value) and (value < max); // Difference `<= max`
    if (!check) return null;

    return ptr_to_item - slice.ptr;
}

/// TODO: maybe refactor together with `index_or_length`
fn index_or_length_from_pointer(ptr_to_item: anytype, slice: anytype) ?usize {
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.size == .slice);
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.child == @typeInfo(@TypeOf(ptr_to_item)).pointer.child);

    const min: usize = @intFromPtr(slice.ptr);
    const max: usize = @intFromPtr(slice.ptr + slice.len);
    const value: usize = @intFromPtr(ptr_to_item);

    const check = (min <= value) and (value <= max); // Difference `<= max`
    if (!check) return null;

    return ptr_to_item - slice.ptr;
}

test {
    _ = @import("testing.zig");
}
