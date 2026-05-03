pub const DO_DEBUG_TRACE: bool = true;
// pub const DO_DEBUG_TRACE: bool = false;

pub const DEBUG_STRESS_GC: bool = false;
pub const DEBUG_PRINT_GC_STATS: bool = false;

pub const DEBUG_CLEAR_SCREEN: bool = false;
pub const DEBUG_PRINT_PTR: union(enum) { none, modulo: usize, full_dec } = .{ .modulo = 10_000 };
pub const DEBUG_SKIP_BOOTSTRAP: bool = false or (DO_DEBUG_TRACE and true);

pub const DEBUG_ARRAY_ELEMENTS_TO_PRINT: usize = 3;
pub const DEBUG_PRINT_STACK_ON_EXIT: bool = false or DO_DEBUG_TRACE;

const std = @import("std");

pub const interning_module = @import("../interning/__interning.zig");
pub const SymbolsManager = interning_module.SymbolsManager;
pub const SymbolId = interning_module.SymbolId;
pub const SymbolArrayMap = interning_module.SymbolArrayMap;

pub const testing_module = @import("testing.zig");

pub const codegen_module = @import("../frontend/codegen.zig");
pub const ClassDefinitionPair = codegen_module.ClassDefinitionPair;
pub const StringLiteralId = codegen_module.StringLiteralId;
pub const BlockDefinitionId = codegen_module.BlockDefinitionId;
pub const Bytecode = codegen_module.Bytecode;
pub const InstructionDecoder = codegen_module.InstructionDecoder;
pub const Instruction = codegen_module.Instruction;
pub const ConstantsManager = codegen_module.ConstantsManager;
pub const ConstantId = codegen_module.ConstantId;
pub const RelativeConstantId = codegen_module.RelativeConstantId;
pub const InstructionId = codegen_module.InstructionId;
pub const compile_class_with_its_parents = codegen_module.compile_class_with_its_parents;
pub const compile_class = codegen_module.compile_class;
pub const compile_class_ignoring_parents = codegen_module.compile_class_ignoring_parents;
pub const allocate_heap_data = codegen_module.allocate_heap_data;
pub const SourceCodeFiles = codegen_module.SourceCodeFiles;
pub const InstructionEncoder = codegen_module.InstructionEncoder;
pub const BlockDefinition = codegen_module.BlockDefinition;
pub const ClassLoader = codegen_module.ClassLoader;

pub const vm_object_module = @import("vm_object.zig");
pub const VmObject = vm_object_module.VmObject;
pub const HeapData = vm_object_module.HeapData;
pub const types = vm_object_module.types;
pub const FrameOnHeap = vm_object_module.FrameOnHeap;
pub const OpaqueHeader = vm_object_module.OpaqueHeader;
pub const EmptyHeapSegment = vm_object_module.EmptyHeapSegment;
pub const object_alignment_in_bytes = vm_object_module.object_alignment_in_bytes;
pub const pointer_after = vm_object_module.pointer_after;
pub const slice_after = vm_object_module.slice_after;

pub const primitives_module = @import("primitives/__primitives.zig");
pub const primitive_methods_module = primitives_module.primitive_methods;
pub const PrimitiveMethodsMap = primitives_module.PrimitiveMethodsMap;
pub const PrimitiveMethodImplementation = primitives_module.PrimitiveMethodImplementation;

pub const class_definition_module = @import("class_definition.zig");
pub const ClassDefinition = class_definition_module.ClassDefinition;
pub const MethodBody = class_definition_module.MethodBody;
pub const MethodDefinition = class_definition_module.MethodDefinition;
pub const FunctionBody = class_definition_module.FunctionBody;

pub const interpreter_module = @import("interpreter.zig");
pub const BuiltinClassDefinitions = interpreter_module.BuiltinClassDefinitions;
pub const Interpreter = interpreter_module.Interpreter;
pub const Statics = interpreter_module.Statics;
pub const Heap = interpreter_module.Heap;
pub const Stack = interpreter_module.Stack;

pub const RunParams = struct {
    gpa: std.mem.Allocator,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    stack_size: struct { objects_count: usize, frames_count: usize },
    root_directories: []const SourceCodeFiles.Directory,
    program_arguments_as_strings: []const []const u8,
    print_stack_on_error: bool = true,
    skip_bootstrap: bool,
};

pub fn run(params: RunParams) !u8 {
    const gpa = params.gpa;
    const stdout = params.stdout;
    const stderr = params.stderr;
    const stack_size = params.stack_size;
    const root_directories = params.root_directories;
    const program_arguments_as_strings = params.program_arguments_as_strings;
    const skip_bootstrap = params.skip_bootstrap;

    // Setup static fields
    var static_arena = std.heap.ArenaAllocator.init(gpa);
    defer static_arena.deinit();
    const static_allocator = static_arena.allocator();
    //
    var statics = Statics{
        .all_classes = .{},
        .all_methods = .{},
        .allocator = static_allocator,
        .symbols_manager = try SymbolsManager.create(static_allocator, 0),
        .constants_manager = ConstantsManager.init(static_allocator),
    };

    // Prepare primitive methods
    const primitive_methods_map = try PrimitiveMethodsMap.init_from(
        static_allocator,
        primitive_methods_module,
        &statics.symbols_manager,
    );

    // Prepare source code loader
    var source_code_files = SourceCodeFiles.init(.{
        .allocator = gpa,
        .root_directories = root_directories,
    });
    defer source_code_files.deinit();

    // Allocate stack
    const frames = try static_allocator.alloc(Stack.Frame, stack_size.frames_count);
    const objects = try static_allocator.alloc(VmObject, stack_size.objects_count);

    // Set up temporary arena
    var temporary_arena = std.heap.ArenaAllocator.init(gpa);
    defer temporary_arena.deinit();

    // Set up globals
    var globals = std.AutoArrayHashMap(SymbolId, VmObject).init(static_allocator);

    // Load builtin classes
    var class_loader = ClassLoader{
        .statics = &statics,
        .temporary_arena = &temporary_arena,
        .source_code_files = &source_code_files,
        .error_writer = stderr,
        .primitive_methods_map = &primitive_methods_map,
        .globals = &globals,
        .metaclass_definition = null,
        .object_definition = null,
    };
    const builtin_classes = try class_loader.load_builtin_classes();

    // Load singletons
    try globals.put(SymbolsManager.comptime_id_of("system"), VmObject.system_object);
    try globals.put(SymbolsManager.comptime_id_of("true"), VmObject.true_object);
    try globals.put(SymbolsManager.comptime_id_of("false"), VmObject.false_object);
    try globals.put(SymbolsManager.comptime_id_of("nil"), VmObject.nil);

    // Setup interpreter
    var interpreter = Interpreter.new(
        Heap{ .backing_allocator = gpa, .interpreter = undefined },
        globals,
        &temporary_arena,
        stdout,
        stderr,
        &statics,
        &source_code_files,
        primitive_methods_map,
        objects,
        frames,
        builtin_classes,
    );
    interpreter.heap.interpreter = &interpreter;
    defer interpreter.heap.deinit();
    try interpreter.heap.reserve_at_least(.{ .total_minimum_number_of_bytes = 1 });

    // Make program arguments into VM strings
    const programs_arguments = try types.Array.create_with_undefined_items(&statics, program_arguments_as_strings.len);
    for (programs_arguments.get_items(), program_arguments_as_strings) |*argument, argument_as_string| {
        argument.* = try types.String.create_new(&statics, argument_as_string);
    }

    if (skip_bootstrap) {
        // This is basically code from `System >> initialize:` method, but in Zig.
        if (program_arguments_as_strings.len == 0) {
            interpreter.report_runtime_error("No entrypoint class was supplied.", .{});
            return error.no_entrypoint_class;
        }
        const main_class = try interpreter.load_class((try statics.symbols_manager.id_or_intern(program_arguments_as_strings[0])).id);
        const main_object: VmObject = try types.GenericObject.create_new(&statics, main_class);
        if (main_class.get_method((try statics.symbols_manager.id_or_intern("run")).id)) |run_method| {
            try interpreter.push_object(main_object);
            try interpreter.call_method(run_method);
        } else if (main_class.get_method((try statics.symbols_manager.id_or_intern("run:")).id)) |run_method| {
            try interpreter.push_object(VmObject.from(programs_arguments));
            try interpreter.push_object(main_object);
            try interpreter.call_method(run_method);
        } else {
            interpreter.report_runtime_error("The entrypoint class `{s}` does not have a `run` nor `run:` method.", .{
                program_arguments_as_strings[0],
            });
            return error.no_run_method;
        }
    } else {
        const initialize_method = interpreter.builtin_class_definitions.system.get_method(SymbolsManager.comptime_id_of("initialize:")) orelse {
            interpreter.report_runtime_error("The class `System` does not have the expected `initialize: arguments` method.", .{});
            return error.no_initialize_method;
        };
        try interpreter.push_object(VmObject.from(programs_arguments));
        try interpreter.push_object(VmObject.system_object);
        try interpreter.call_method(initialize_method);
    }

    var maybe_err: ?Interpreter.Error = null;
    interpreter.run() catch |err| {
        maybe_err = err;
    };
    interpreter.stderr.flush() catch {};
    interpreter.stdout.flush() catch {};

    const err = maybe_err orelse return interpreter.exit_code;
    if (err == Interpreter.Error.interpreter_halted) return interpreter.exit_code;

    if (params.print_stack_on_error) {
        interpreter.debug_print_stack() catch {};
    }
    return err;
}
