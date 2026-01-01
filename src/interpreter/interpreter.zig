const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const colors = @import("../terminal.zig");

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;

const interning_module = @import("../interning/symbols_manager.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = @import("../interning/symbol_array_map.zig").SymbolArrayMap;

const codegen_module = @import("../frontend/codegen.zig");
const InstructionDecoder = codegen_module.InstructionDecoder;
const Instruction = codegen_module.Instruction;
const ConstantsManager = codegen_module.ConstantsManager;
const ConstantId = codegen_module.ConstantId;
const RelativeConstantId = codegen_module.RelativeConstantId;
const InstructionId = codegen_module.InstructionId;
const compile_class_with_its_parents = codegen_module.compile_class_with_its_parents;
const allocate_heap_data = codegen_module.allocate_heap_data;
const SourceCodeFiles = codegen_module.SourceCodeFiles;
const InstructionEncoder = codegen_module.InstructionEncoder;

const DO_DEBUG_TRACE: bool = true;

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
pub const stack_size = 4096;

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
        constants_base_id: ConstantId,
        after_return_instruction_id: InstructionId,

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

    /// Takes the `primitive_methods` of the `Interpreter` and makes them into a classes with only the primitive methods.
    /// This is temporary, since later `primitive_methods` should be used only to retrive information about
    /// primitive methods during the loading of a class
    /// TODO: remove this once we can load individial classes and their definitions
    pub fn TODO_REMOVE_THIS__add_implementations_of_primitive_classes(self: *Self) Error!void {
        const integer_symbol_id = self.statics.symbols_manager.id_of("Integer").?;
        const double_symbol_id = self.statics.symbols_manager.id_of("Double").?;
        const string_symbol_id = self.statics.symbols_manager.id_of("String").?;

        for (self.primitive_methods.sorted_classes.items) |primitive_class| {
            const methods = try self.statics.allocator.alloc(Method, primitive_class.methods.len());
            for (primitive_class.methods.items, 0..) |primitive_method, idx| {
                methods[idx] = Method{
                    .method_name = primitive_method.method_name,
                    .body = MethodBody{ .primitive = primitive_method.function },
                    .number_of_aditional_args = primitive_method.args_cnt - 1,
                };
            }
            const sorted_methods = ClassDefinition.MethodMap.from_slice(methods).ok; // NOTE: we can use `.ok` here, since the primitive methods were parsed from a struct definition, if not and there is a duplicate method name, we crash :D
            const class_definition = try self.statics.all_classes.addOne(self.statics.allocator);
            class_definition.* = ClassDefinition{
                .class_name = primitive_class.class_name,
                .instance_methods = sorted_methods,
            };

            if (class_definition.class_name.idx == integer_symbol_id.idx) {
                self.primitive_class_definitions.put(.integer, class_definition);
            } else if (class_definition.class_name.idx == double_symbol_id.idx) {
                self.primitive_class_definitions.put(.double, class_definition);
            } else if (class_definition.class_name.idx == string_symbol_id.idx) {
                self.primitive_class_definitions.put(.string, class_definition);
            }
        }
    }

    pub const ResultOfRegisterClass = struct {
        is_already_registered: bool,
        ptr_to_class: *ClassDefinition,
    };

    // TODO: here will be argument for an entire class that is being run.. I think
    pub fn run(self: *Self) Error!void {
        while (true) {
            const instr_id = self.decoder.id_of_next_instruction();
            const instruction: Instruction = self.decoder.next_instruction() orelse {
                try self.report_info("The end of the bytecode has been reached.", .{});
                return;
            };
            if (DO_DEBUG_TRACE) {
                const formatter = codegen_module.InstructionFormatter{ .base_constant_id = self.top_frame().constants_base_id, .constants_manager = &self.statics.constants_manager, .symbols_manager = &self.statics.symbols_manager };
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
                    return self.report_TODO("Execution of instruction 'load_instance_var' (id is {d})", .{instance_var_id.idx});
                },
                .load_global => |global_var_id| {
                    return self.report_TODO("Execution of instruction 'load_global' (id is {d})", .{global_var_id.idx});
                    //      const maybe_global_object: ?VmObject = self.get_global(global_object_id);
                    //      const global_object = if (maybe_global_object) |obj| obj
                    //                            else try self.load_class(global_object_id);
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
                    const constant_id: ConstantId = constant_info.id.to_absolute(self.top_frame().constants_base_id);
                    const constant = self.statics.constants_manager.get_constant(constant_id);
                    const object: VmObject = blk: switch (constant) {
                        .integer => |value| {
                            try self.ensure_primitive_class_is_loaded(.integer);
                            // TODO(hack): consider whether making the integers smaller or arbitrary in size or something
                            const value_i48: i48 = @intCast(value);

                            const header = HeapData.Header.new_undefined_with_tag(.integer);
                            const result_object_data: *HeapData = try self.heap.allocate(header);
                            (primitives.Integer.Accessor{}).set_value(result_object_data, value_i48);
                            break :blk result_object_data.as_vm_object();
                        },
                        .float => |value| {
                            try self.ensure_primitive_class_is_loaded(.double);
                            const header = HeapData.Header.new_undefined_with_tag(.double);
                            const result_object_data: *HeapData = try self.heap.allocate(header);
                            (primitives.Double.Accessor{}).set_value(result_object_data, value);
                            break :blk result_object_data.as_vm_object();
                        },
                        .string => |value| {
                            try self.ensure_primitive_class_is_loaded(.string);
                            var header = HeapData.Header.new_undefined_with_tag(.string);
                            (primitives.String.Accessor{}).set_length(header.as_heap_data(), @intCast(value.len));
                            const result_object_data: *HeapData = try self.heap.allocate(header);
                            @memcpy((primitives.String.Accessor{}).contents(result_object_data), value);
                            break :blk result_object_data.as_vm_object();
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

    pub fn print_object(self: *Self, object: VmObject) Error!void {
        switch (object.data.kind()) {
            .integer => |accessor| try self.stdout.print("{d}\n", .{accessor.get_value(object.data)}),
            .double => |accessor| try self.stdout.print("{d}\n", .{accessor.get_value(object.data)}),
            .string => |accessor| try self.stdout.print("'{s}'\n", .{accessor.contents(object.data)}),
            .generic_object => |accessor| {
                const class_name: SymbolId = accessor.get_class_definition(object.data).class_name;
                const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                try self.stdout.print("Instance of class: '{s}'\n", .{class_name_string});
            },
            .nil => {
                try self.stdout.print("nil\n", .{});
            },
            else => {
                return self.report_TODO("Printing of VmObject of type `{t}` is not supported yet :)", .{object.data.header.tag});
            },
        }
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
                current_frame.constants_base_id.idx,
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
        // TODO: we have to walk the linked-list of `class_definition.parent.parent.parent...` so we can properly update the primitive classes list
        // TODO: I think this should be in the `load_class` method and not here, since there is a possibility that `load_class` will be called from elsewhere (for example in the following SOM code: `Integer new.` should force a load of the `Integer` class.)
        self.primitive_class_definitions.put(primitive_class_type, class_definition);
    }

    pub fn load_class(self: *Self, class_name: SymbolId) !*ClassDefinition {
        const class_definition = try compile_class_with_its_parents(.{
            .bottom_class_name = class_name,
            .error_writer = self.stderr,
            .globals = &self.globals,
            .primitive_methods_map = self.primitive_methods,
            .source_code_files = self.source_code_files,
            .statics = self.statics,
            .temporary_allocator = self.statics.allocator, // TODO: use an actual *temporary* allocator
        });
        // The bytecode array might have gotten reallocated during the compilation
        self.decoder.bytes = self.statics.instruction_encoder.view_bytecode().bytes;
        return class_definition;
    }

    pub fn push_frame(
        self: *Self,
        constants_base_id: ConstantId,
        self_object: VmObject,
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
            self.report_runtime_error("Stack overflow (too many objects frames)! :D", .{});
            return Error.object_stack_overflow;
        }
        // Grow the stack
        const new_base_index: u32 = @intCast(self.stack.objects.len);
        self.stack.frames.ptr[self.stack.frames.len] = Stack.Frame{
            .constants_base_id = constants_base_id,
            .base_idx = new_base_index,
            .after_return_instruction_id = after_return_instruction_id,
        };
        self.stack.frames.len += 1;
        self.stack.objects.len += arguments_count + locals_count;

        // Initialize the objects in the newly allocated space
        self.stack.objects[new_base_index] = self_object;

        // TODO: consider not-initializing the objects here. Instead, the compiler could do an analysis of which variables get used before initialization and generate load nil instructions.
        // Initialize the objects to `nil`
        const nil_object: VmObject = try self.get_nil_singleton();
        for ((new_base_index + 1)..self.stack.objects.len) |stack_idx| {
            self.stack.objects[stack_idx] = nil_object;
        }
    }

    /// Asserts that the stack is not empty
    pub fn pop_frame(self: *Self) void {
        assert(self.stack.frames_count() > 0);
        // We need to not pop the top object, since it is the return value of the function
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

    fn send_message(self: *Self, call_info: Instruction.SendMessage) Error!void {
        const target_object: VmObject = self.pop_object();
        const class: *const ClassDefinition = self.get_class_of(target_object);
        const method: *const Method = class.get_method(call_info.message_name) orelse {
            self.report_runtime_error(
                "Tried to call the method `{s}` on an instance of a class `{s}`, but that does not exist.",
                .{ self.statics.symbols_manager.symbol_with_id(call_info.message_name), self.statics.symbols_manager.symbol_with_id(class.class_name) },
            );
            // TODO: maybe also print the methods that exist on that class?
            return Error.method_not_found;
        };

        switch (method.body) {
            .user_land => |method_body_info| {
                try self.push_frame(
                    class.constants_base_id,
                    target_object,
                    method.number_of_aditional_args,
                    method_body_info.number_of_locals,
                    self.decoder.id_of_next_instruction(),
                );
                self.decoder.set_id_of_the_next_instruction(method_body_info.start_instruction);
            },
            .primitive => |primitive_method| {
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

    fn get_class_of(self: *Self, object: VmObject) *const ClassDefinition {
        // TODO: if the class is not found, the interpreter should go and find the class definition
        return switch (object.data.kind()) {
            .integer => self.primitive_class_definitions.getAssertContains(.integer),
            .double => self.primitive_class_definitions.getAssertContains(.double),
            .string => self.primitive_class_definitions.getAssertContains(.string),
            .class => self.primitive_class_definitions.getAssertContains(.class),
            .nil => self.primitive_class_definitions.getAssertContains(.nil),

            .generic_object => |accessor| accessor.get_class_definition(object.data),
            .empty_heap_segment => unreachable,
        };
    }

    fn report_info(self: *Self, comptime fmt: []const u8, args: anytype) Error!void {
        try self.stderr.print(colors.CYAN ++ "[runtime-info] " ++ colors.RESET ++ fmt ++ "\n", args);
    }

    // TODO: remove this once all the major features are implemented
    fn report_TODO(self: *Self, comptime fmt: []const u8, args: anytype) error{TODO} {
        self.stderr.print(colors.ERR ++ "[TODO (not implemented)] " ++ colors.RESET ++ fmt ++ "\n", args) catch {};
        return error.TODO;
    }

    fn report_runtime_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
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

pub const PrimitiveMethodImplementation = *const fn (target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject;
/// Same as `PrimitiveMethodImplementation`, but made into a different type, because of circular dependency reasons.
/// (Having two aliases for these function pointers remove the circular depenedency errors, maybe in future versions of Zig, they will not be a problem.)
pub const PrimitiveMethodImplementation_ = *const fn (target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject;

pub const ClassDefinition = struct {
    class_name: SymbolId,
    instance_methods: MethodMap,
    constants_base_id: ConstantId,
    as_vm_object: VmObject,

    // TODO: add instance variables
    // TODO: add !!optional!! pointer to parent class

    const Self = @This();
    pub const MethodMap = SymbolArrayMap(Method, "method_name");

    pub fn get_method(self: Self, method_name: SymbolId) ?*const Method {
        const idx = self.instance_methods.get_idx(method_name) orelse return null;
        return &self.instance_methods.items[idx];
    }
};

pub const PrimitiveMethodsMap = struct {
    sorted_classes: SortedClasses,
    all_methods: []PrimitiveMethod,

    const Self = @This();
    pub const SortedClasses = SymbolArrayMap(PrimitiveClass, "class_name");
    pub const SortedMethods = SymbolArrayMap(PrimitiveMethod, "method_name");

    /// Stores a list of primitive methods in a class.
    pub const PrimitiveClass = struct {
        class_name: SymbolId,

        /// This contains a slice of the `PrimitiveMethodsMap.all_methods` array
        methods: SortedMethods,

        pub fn get_method(self: @This(), method_name: SymbolId) ?*const PrimitiveMethod {
            return self.methods.get_ptr(method_name);
        }
    };
    const PrimitiveMethod = struct {
        method_name: SymbolId,
        function: PrimitiveMethodImplementation,
        args_cnt: u8,
    };

    ///
    /// Creates a new instance of `PrimitiveMethodsMap` via doing a comptime reflection on `primitives_module` argument.
    ///
    /// `primitives_module` is expected to be a type struct in this form:
    /// ```zig
    ///     pub const some_primitives_module = struct {
    ///         pub const SomePrimitiveClassInSom = struct {
    ///             pub fn someMethod__somig_arity = 2; // or some other number
    ///             pub fn someSomMethod__somig_primitive_fn (...) {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             pub fn someOtherMethod__somig_arity = 1; // or some other number
    ///             pub fn someOtherSomMethod__somig_primitive_fn (...) {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             ... // other methods and their arities
    ///         }
    ///
    ///         pub const AnotherClass = struct {
    ///             pub fn somMethod1__somig_arity = 2; // or some other number
    ///             pub fn somMethod1__somig_primitive_fn (...) {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             ... // other methods and their arities
    ///         }
    ///
    ///         ... // other classes definitions
    ///     }
    /// ```
    ///
    pub fn init_from(
        allocator: Allocator,
        comptime primitives_module: type,
        symbols_manager: *SymbolsManager,
    ) Allocator.Error!Self {
        const primitive_fn_postfix = "__somig_primitive_fn";
        const fn_arity_postix = "__somig_arity";
        const module_info: std.builtin.Type.Struct = @typeInfo(primitives_module).@"struct";

        // Get the number of primitive classes and their methods
        // so the arraylists below don't have to realloc.
        const pritimive_classes_cnt = module_info.decls.len;
        comptime var primitive_methods_cnt = 0;
        //
        inline for (module_info.decls) |decl| {
            inline for (@typeInfo(@field(primitives_module, decl.name)).@"struct".decls) |primitive_decl| {
                if (comptime std.mem.endsWith(u8, primitive_decl.name, primitive_fn_postfix)) {
                    primitive_methods_cnt += 1;
                }
            }
        }

        var classes = try std.ArrayList(PrimitiveClass).initCapacity(allocator, pritimive_classes_cnt);
        var methods = try std.ArrayList(PrimitiveMethod).initCapacity(allocator, primitive_methods_cnt);

        // Go through each primitive class
        inline for (module_info.decls) |module_decl| {
            const primitive_type_name = module_decl.name;
            const PrimitiveType: type = @field(primitives_module, primitive_type_name);
            const primitive_type_info = @typeInfo(PrimitiveType).@"struct";
            const methods_start = methods.items.len;

            // Go through each declaration in the primitive class
            // and find all functions that are supposed to be implementations of primitive SOM methods
            inline for (primitive_type_info.decls) |decl| {
                if (comptime !std.mem.endsWith(u8, decl.name, primitive_fn_postfix)) continue;
                const fn_name = decl.name[0..(decl.name.len - primitive_fn_postfix.len)];
                const fn_arity: comptime_int = @field(PrimitiveType, fn_name ++ fn_arity_postix);
                const fn_impl: PrimitiveMethodImplementation = @field(PrimitiveType, decl.name);

                const primitive_method = PrimitiveMethod{
                    .method_name = (try symbols_manager.id_or_intern(fn_name)).id,
                    .function = fn_impl,
                    .args_cnt = fn_arity,
                };
                methods.appendAssumeCapacity(primitive_method);
            }

            // Sort the methods by their symbol id so they can be looked up later using binary sort
            const methods_end = methods.items.len;
            const methods_slice = methods.items[methods_start..methods_end];
            // We can assume there will be no duplicates, since the methods got parsed from a `struct` definition
            const sorted_methods_slice = SortedMethods.from_slice(methods_slice).ok;

            const class = PrimitiveClass{
                .class_name = (try symbols_manager.id_or_intern(primitive_type_name)).id,
                .methods = sorted_methods_slice,
            };
            classes.appendAssumeCapacity(class);
        }

        assert(classes.items.len == classes.capacity);
        assert(methods.items.len == methods.capacity);

        const sorted_classes = SortedClasses.from_slice(classes.items).ok;

        return PrimitiveMethodsMap{
            .sorted_classes = sorted_classes,
            .all_methods = methods.items,
        };
    }

    pub fn get_primitive_class(self: Self, class_name: SymbolId) ?*const PrimitiveClass {
        const maybe_idx: ?usize = std.sort.binarySearch(PrimitiveClass, self.sorted_classes, class_name, struct {
            fn compare(class_name_id: SymbolId, class: PrimitiveClass) std.math.Order {
                return std.math.order(class_name_id, class.class_name);
            }
        }.compare);

        if (maybe_idx) |idx| {
            return &self.sorted_classes[idx];
        }
        return null;
    }

    fn primitive_method_less_than_fn(_: void, a: PrimitiveMethod, b: PrimitiveMethod) bool {
        return a.method_name.idx < b.method_name.idx;
    }

    fn primitive_class_less_than_fn(_: void, a: PrimitiveClass, b: PrimitiveClass) bool {
        return a.class_name.idx < b.class_name.idx;
    }
};

pub const Method = struct {
    method_name: SymbolId,
    /// Number of arguments to pop from stack
    /// (**excluding** the first argument which is the message target object).
    ///
    /// For example, every unary method has this field set to 0 and every binary method to 1.
    /// Keyword method `get:with:AndWith:` (example method) has this field set to 3.
    ///
    /// TODO(consultation): This field might be probably needed only for asserts when we do a dynamic call into a method.
    ///                     NOTE: maybe not, we might need it for a stackframe creation
    number_of_aditional_args: u16,
    body: MethodBody,
};

pub const MethodBody = union(enum) {
    primitive: PrimitiveMethodImplementation_,
    user_land: struct { start_instruction: InstructionId, number_of_locals: u16 },
};

pub fn SmallPtr(comptime Ptr: type) type {
    const is_maybe_optional_pointer = switch (@typeInfo(Ptr)) {
        .pointer => true,
        .optional => |optional_info| switch (@typeInfo(optional_info.child)) {
            .pointer => true,
            else => false,
        },
        else => false,
    };

    if (!is_maybe_optional_pointer) {
        @compileError(std.fmt.comptimePrint(
            "Expected `Ptr` to be a pointer type, or an optional pointer type, but it is `{s}`.",
            .{@typeName(Ptr)},
        ));
    }

    return packed struct {
        bits: u48,

        const Self = @This();

        pub fn pointee(self: Self) Ptr {
            return @ptrFromInt(@as(u64, self.bits));
        }

        pub fn new(full_ptr: Ptr) Self {
            const all_bits: u64 = @intFromPtr(full_ptr);
            assert(all_bits <= std.math.maxInt(u48));
            const truncated_bits: u48 = @truncate(all_bits);
            return .{ .bits = truncated_bits };
        }
    };
}

// TODO(speed): NaN tagging, we should be able to do:
//                 - pointers to `ObjectHeader`
//                 - booleans (false, true)
//                 - nil
//                 - i48 numbers
//                 - maybe small string optimisation?
pub const VmObject = struct {
    data: *HeapData,
};

pub const HeapData = struct {
    header: Header,

    ///
    /// `Header` could have been a `union(enum)`, but a tagged union cannot be packed.
    /// Which means the payload could have been just 32 bits at maximum.
    ///
    /// Being able to store up to 56 bits is nice, since we can fit a lot
    /// of stuff (even `SmallPtr`) in there.
    pub const Header = packed struct {
        tag: Tag,
        payload: u56,

        pub inline fn new_undefined_with_tag(tag: Tag) Header {
            return .{ .tag = tag, .payload = undefined };
        }

        pub inline fn kind(self: Header) Kind {
            // We can coerce an enum into a tagged union when
            // the fields of the tagged union have only a single known value.
            // Which is true for all cases of `Kind`.
            return self.tag;
        }

        pub inline fn as_heap_data(self: *Header) *HeapData {
            return @fieldParentPtr("header", self);
        }

        pub inline fn bytes_needed_after_header(self: Header) usize {
            return switch (self.kind()) {
                .integer => |accessor| accessor.get_bytes_count_after_header(),
                .double => |accessor| accessor.get_bytes_count_after_header(),
                .string => |accessor| accessor.get_bytes_count_after_header(.{ .header = self }),
                .class => |accessor| accessor.get_bytes_count_after_header(.{ .header = self }),
                .nil => 0,
                .generic_object => |accessor| accessor.get_bytes_count_after_header(.{ .header = self }),
                .empty_heap_segment => |accessor| accessor.get_bytes_count_after_header(),
            };
        }

        pub const Tag = std.meta.Tag(Kind);

        pub const Kind = union(enum(u8)) {
            integer: primitives.Integer.Accessor,
            double: primitives.Double.Accessor,
            string: primitives.String.Accessor,
            nil,
            class: primitives.Class.Accessor,
            // TODO: rest of the primitives

            generic_object: GenericObjectAccessor,
            empty_heap_segment: EmptyHeapSegmentAccessor,

            pub inline fn tag(self: Kind) Tag {
                return self;
            }
        };
    };

    pub inline fn as_vm_object(self: *HeapData) VmObject {
        return VmObject{ .data = self };
    }

    pub inline fn kind(self: HeapData) Header.Kind {
        return self.header.kind();
    }

    pub fn get_after_header_ptr(self: *const HeapData, comptime Ptr: type) Ptr {
        const offset = @sizeOf(Header);
        const address = @intFromPtr(self) + offset;
        const ptr: Ptr = @ptrFromInt(address);
        return ptr;
    }
};

comptime {
    // Simplifies a lot of things (especially the alignment).
    // It is far easier to allocate header and then other fields after it for example.
    assert(@sizeOf(HeapData) == 8);
    assert(@alignOf(HeapData) == 8);
}

pub const EmptyHeapSegmentAccessor = struct {
    pub inline fn get_bytes_count_after_header(self: EmptyHeapSegmentAccessor) usize {
        _ = self;
        return 0;
    }

    /// WARN: the pointer is not mutable (the pointee is), use `set_next_empty_slot` to set the pointer
    pub inline fn get_next_empty_slot(self: EmptyHeapSegmentAccessor, heap_data: *const HeapData) ?*HeapData {
        _ = self;
        const small_ptr = SmallPtr(?*HeapData){ .bits = @truncate(heap_data.header.payload) };
        return small_ptr.pointee();
    }

    pub inline fn set_next_empty_slot(
        self: EmptyHeapSegmentAccessor,
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
        assert(instance_var_idx < self.get_instance_variables_count(heap_data));
        const instances = heap_data.get_after_header_ptr([*]VmObject);
        return instances[instance_var_idx + 1]; // `+1` since we store the `*ClassDefinition` at the index 0
    }

    pub inline fn set_instance_var_with_idx(self: Self, heap_data: *HeapData, instance_var_idx: u32, new_object: VmObject) void {
        assert(instance_var_idx < self.get_instance_variables_count(heap_data));
        const instances = heap_data.get_after_header_ptr([*]VmObject);
        instances[instance_var_idx + 1] = new_object; // `+1` since we store the `*ClassDefinition` at the index 0
    }
};

// TODO: move this into another file called `primitives`
// But then, private methods on `Interpreter` will not be accesible from here... eh, doesn't matter probably
//
// TODO: split the classes definitions into "instance" and "class" parts

pub const PrimitiveClassType = enum {
    integer,
    double,
    string,
    nil,
    array,
    class,
    // TODO: remaining primitive classes

    const Self = @This();
    pub fn as_string(self: Self) []const u8 {
        return switch (self) {
            .integer => "Integer",
            .double => "Double",
            .string => "String",
            .nil => "Nil",
            .array => "Array",
            .class => "Class",
        };
    }
};

pub const primitives = struct {
    pub const Object = struct {
        pub const class__somig_arity = 1;
        pub fn class__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const class_definition = interpreter.get_class_of(target_object);
            return class_definition.as_vm_object;
        }
    };

    pub const Class = struct {
        /// TODO(consultation): read the TODO below this one and ask if it is correct or not
        /// TODO: This is probably not exactly correct according to the SOM class hiearchy (with Metaclasses and such), so consider chaning it later.
        ///
        /// Same as a generic object, but `*ClassDefinition` which can be accessed
        /// does not point to the primitive class `Class` but to the `ClassDefinition`
        /// which is represented by the SOM runtime object.
        ///
        pub const Accessor = GenericObjectAccessor;

        pub const name__somig_arity = 1;
        pub fn name__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const class_definition: *ClassDefinition = switch (target_object.data.kind()) {
                .class => |accessor| accessor.get_class_definition(target_object.data),
                // TODO: proper error reporting
                else => return Interpreter.Error.primitive_type_error,
            };
            const name_as_u8_slice: []const u8 = interpreter.statics.symbols_manager.symbol_with_id(class_definition.class_name);

            // TODO(str): consider making a proper interpreter method for this *already*
            try interpreter.ensure_primitive_class_is_loaded(.string);
            var header = HeapData.Header.new_undefined_with_tag(.string);
            (String.Accessor{}).set_length(header.as_heap_data(), @intCast(name_as_u8_slice.len));
            const result_object_data: *HeapData = try interpreter.heap.allocate(header);
            @memcpy((String.Accessor{}).contents(result_object_data), name_as_u8_slice);

            const name_as_string_object = result_object_data.as_vm_object();
            return name_as_string_object;
        }
    };

    pub const Integer = struct {
        pub const Accessor = packed struct {
            pub inline fn get_bytes_count_after_header(self: Accessor) usize {
                _ = self;
                return 0;
            }
            pub inline fn get_value(self: Accessor, heap_data: *const HeapData) i48 {
                _ = self;
                const truncated: u48 = @truncate(heap_data.header.payload);
                return @bitCast(truncated);
            }
            pub inline fn set_value(self: Accessor, heap_data: *HeapData, value: i48) void {
                _ = self;
                const raw: u48 = @bitCast(value);
                heap_data.header.payload = raw;
            }
        };

        pub const @"+__somig_arity" = 2;
        pub fn @"+__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            return try binary_method(target_object, interpreter, struct {
                fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                    return lhs + rhs;
                }
            }.f);
        }

        pub const @"-__somig_arity" = 2;
        pub fn @"-__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            return try binary_method(target_object, interpreter, struct {
                fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                    return lhs - rhs;
                }
            }.f);
        }

        pub const @"*__somig_arity" = 2;
        pub fn @"*__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            return try binary_method(target_object, interpreter, struct {
                fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                    return lhs * rhs;
                }
            }.f);
        }

        pub const @"/__somig_arity" = 2;
        pub fn @"/__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const i48_dividion = struct {
                fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                    if (rhs == 0) {
                        @branchHint(.unlikely);
                        return Interpreter.Error.division_by_zero;
                    }
                    // TODO: Check if this is the correct behaviour. This is probably the behaviour of `//` on the `Integer` class
                    // TODO: Also check if the `/` method rounds towards zero or -infinity (in case of towards zero, change to `@divTrunc`)
                    return @divFloor(lhs, rhs);
                }
            }.f;

            const result_object = binary_method(target_object, interpreter, i48_dividion) catch |err| {
                if (err == error.division_by_zero) interpreter.report_runtime_error("Division by zero", .{});
                return err;
            };
            return result_object;
        }

        pub const asString__somig_arity = 1;
        pub fn asString__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const receiver_as_int: i48 = (Accessor{}).get_value(target_object.data);

            // TODO: use interpter string allocator (??? i don't know what that means :D)
            var print_buffer: [128]u8 = undefined;
            const receiver_as_str: []u8 = std.fmt.bufPrint(&print_buffer, "{d}", .{receiver_as_int}) catch {
                std.debug.panic("Could not print the integer: '{d}', because it was too long.", .{receiver_as_int});
            };
            const length: i48 = @intCast(receiver_as_str.len);

            try interpreter.ensure_primitive_class_is_loaded(.string);
            var header = HeapData.Header.new_undefined_with_tag(.string);
            (String.Accessor{}).set_length(header.as_heap_data(), length);
            const result_object_data: *HeapData = try interpreter.heap.allocate(header);
            // TODO(speed): figure out the length of the string before printing it so that we don't have to memcpy here and we can just print to the buffer directly
            @memcpy((String.Accessor{}).contents(result_object_data), receiver_as_str);

            const result_object = result_object_data.as_vm_object();

            return result_object;
        }

        fn binary_method(
            target_object: VmObject,
            interpreter: *Interpreter,
            comptime op: fn (i48, i48) Interpreter.Error!i48,
        ) Interpreter.Error!VmObject {
            const lhs_int = (Accessor{}).get_value(target_object.data);

            const rhs_object = interpreter.pop_object();
            const rhs_int: i48 = switch (rhs_object.data.kind()) {
                .integer => |accessor| accessor.get_value(rhs_object.data),
                // TODO: check the size of the integer
                // TODO: use `asInteger` primitive method in the `Double` class
                .double => |accessor| @intFromFloat(accessor.get_value(rhs_object.data)),
                // TODO: better error reporting
                else => return Interpreter.Error.primitive_type_error,
            };
            const result_int = try op(lhs_int, rhs_int);

            const header = HeapData.Header.new_undefined_with_tag(.integer);
            const result_object_data: *HeapData = try interpreter.heap.allocate(header);
            (Accessor{}).set_value(result_object_data, result_int);
            const result_object = result_object_data.as_vm_object();

            return result_object;
        }
    };

    pub const Double = struct {
        pub const Accessor = struct {
            pub inline fn get_bytes_count_after_header(self: Accessor) usize {
                _ = self;
                return @sizeOf(f64);
            }
            pub inline fn value_ptr(self: Accessor, heap_data: *HeapData) *f64 {
                _ = self;
                const ptr: *f64 = heap_data.get_after_header_ptr(*f64);
                return ptr;
            }
            pub inline fn get_value(self: Accessor, heap_data: *const HeapData) f64 {
                _ = self;
                const ptr: *f64 = heap_data.get_after_header_ptr(*f64);
                const value = ptr.*;
                return value;
            }
            pub inline fn set_value(self: Accessor, heap_data: *HeapData, value: f64) void {
                self.value_ptr(heap_data).* = value;
            }
        };

        pub const @"+__somig_arity" = 2;
        pub fn @"+__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs + rhs;
                }
            }.f);
        }

        pub const @"-__somig_arity" = 2;
        pub fn @"-__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs - rhs;
                }
            }.f);
        }

        pub const @"*__somig_arity" = 2;
        pub fn @"*__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs * rhs;
                }
            }.f);
        }

        pub const @"/__somig_arity" = 2;
        pub fn @"/__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs / rhs;
                }
            }.f);
        }

        pub const asString__somig_arity = 1;
        pub fn asString__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const receiver_as_double: f64 = (Accessor{}).get_value(target_object.data);

            // TODO: use interpter string allocator (??? i don't know what that means :D)
            var print_buffer: [256]u8 = undefined;
            const receiver_as_str: []u8 = std.fmt.bufPrint(&print_buffer, "{d}", .{receiver_as_double}) catch {
                std.debug.panic("Could not print the double: '{d}', because it was too long.", .{receiver_as_double});
            };
            const length: i48 = @intCast(receiver_as_str.len);

            try interpreter.ensure_primitive_class_is_loaded(.string);
            var header = HeapData.Header.new_undefined_with_tag(.string);
            (String.Accessor{}).set_length(header.as_heap_data(), length);
            const result_object_data: *HeapData = try interpreter.heap.allocate(header);
            // TODO(speed): figure out the length of the string before printing it so that we don't have to memcpy here and we can just print to the buffer directly
            @memcpy((String.Accessor{}).contents(result_object_data), receiver_as_str);

            const result_object = result_object_data.as_vm_object();

            return result_object;
        }

        fn binary_method(
            target_object: VmObject,
            interpreter: *Interpreter,
            comptime op: fn (f64, f64) Interpreter.Error!f64,
        ) Interpreter.Error!VmObject {
            const lhs_double = (Accessor{}).get_value(target_object.data);

            const rhs_object = interpreter.pop_object();

            // TODO: better error reporting
            const rhs_double: f64 = switch (rhs_object.data.kind()) {
                .integer => |accessor| @floatFromInt(accessor.get_value(rhs_object.data)),
                .double => |accessor| accessor.get_value(rhs_object.data),
                else => return Interpreter.Error.primitive_type_error,
            };
            const result_double: f64 = try op(lhs_double, rhs_double);

            const header = HeapData.Header.new_undefined_with_tag(.double);
            const result_object_data: *HeapData = try interpreter.heap.allocate(header);
            (Accessor{}).set_value(result_object_data, result_double);
            const result_object = result_object_data.as_vm_object();

            return result_object;
        }
    };

    pub const String = struct {
        pub const Accessor = packed struct {
            pub fn get_length(self: Accessor, heap_data: HeapData) i48 {
                _ = self;
                const raw: u48 = @truncate(heap_data.header.payload);
                const length: i48 = @bitCast(raw);
                return length;
            }

            pub fn get_length_usize(self: Accessor, heap_data: HeapData) usize {
                const length_signed: i48 = self.get_length(heap_data);
                return @intCast(length_signed);
            }

            pub fn set_length(self: Accessor, heap_data: *HeapData, new_length: i48) void {
                _ = self;
                const raw: u48 = @bitCast(new_length);
                heap_data.header.payload = raw;
            }

            pub fn get_bytes_count_after_header(self: Accessor, heap_data: HeapData) usize {
                return @intCast(self.get_length(heap_data));
            }

            pub fn contents(self: Accessor, heap_data: *HeapData) []u8 {
                // TODO: check that this works even when `self.length == 0`
                const ptr: [*]u8 = heap_data.get_after_header_ptr([*]u8);
                const length: usize = self.get_length_usize(heap_data.*);
                const slice: []u8 = ptr[0..length];
                return slice;
            }
        };

        pub const println__somig_arity = 1;
        pub fn println__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const str: []const u8 = switch (target_object.data.kind()) {
                .string => |accessor| accessor.contents(target_object.data),
                else => return Interpreter.Error.primitive_type_error,
            };
            _ = try interpreter.stdout.write(str);
            _ = try interpreter.stdout.writeByte('\n');
            try interpreter.stdout.flush();
            return try interpreter.get_nil_singleton();
        }

        pub const print__somig_arity = 1;
        pub fn print__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const str: []const u8 = switch (target_object.data.kind()) {
                .string => |accessor| accessor.contents(target_object.data),
                else => return Interpreter.Error.primitive_type_error,
            };
            _ = try interpreter.stdout.write(str);
            return try interpreter.get_nil_singleton();
        }

        // TODO: replace this with `concatWith:` once we are able to compile keyword messages
        pub const @"+++__somig_arity" = 2;
        pub fn @"+++__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
            const lhs_string: []const u8 = switch (target_object.data.kind()) {
                .string => |accessor| accessor.contents(target_object.data),
                else => return Interpreter.Error.primitive_type_error,
            };

            const rhs_object = interpreter.pop_object();
            const rhs_string: []const u8 = switch (rhs_object.data.kind()) {
                .string => |accessor| accessor.contents(rhs_object.data),
                else => return Interpreter.Error.primitive_type_error,
            };
            const total_length: i48 = @intCast(lhs_string.len + rhs_string.len);

            try interpreter.ensure_primitive_class_is_loaded(.string);
            var header = HeapData.Header.new_undefined_with_tag(.string);
            (String.Accessor{}).set_length(header.as_heap_data(), total_length);
            const result_object_data: *HeapData = try interpreter.heap.allocate(header);
            const written = std.fmt.bufPrint((String.Accessor{}).contents(result_object_data), "{s}{s}", .{ lhs_string, rhs_string }) catch unreachable;
            assert(written.len == total_length);

            return result_object_data.as_vm_object();
        }
    };
};
