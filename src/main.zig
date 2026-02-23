const std = @import("std");
const assert = std.debug.assert;

const terminal = @import("terminal.zig");

const debug_module = @import("debug/debug.zig");
const dbg = debug_module.dbg;

const parser_module = @import("frontend/parser.zig");
const Parser = parser_module.Parser;

const SymbolsManager = @import("interning/symbols_manager.zig").SymbolsManager;

const codegen = @import("frontend/codegen.zig");

const interpreter_module = @import("interpreter/__interpreter.zig");
const Interpreter = interpreter_module.Interpreter;
const Statics = interpreter_module.Statics;
const PrimitiveMethodsMap = interpreter_module.PrimitiveMethodsMap;
const types = interpreter_module.types;
const VmObject = interpreter_module.VmObject;

const lexer_module = @import("frontend/lexer.zig");
const Lexer = lexer_module.Lexer;
const reporter_module = @import("frontend/reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // const args: [][:0]u8 = try std.process.argsAlloc(allocator);
    // defer std.process.argsFree(allocator, args);

    // if (args.len == 3 and std.mem.eql(u8, args[1], "-lex")) {
    //     try lex(allocator, args);
    //     return;
    // }

    // if (args.len == 3 and std.mem.eql(u8, args[1], "-parse")) {
    //     try parse(allocator, args);
    //     return;
    // }

    // std.debug.print(
    //     "This will be an amazing SOMig project!\n\nUsage (so far):\n\t- `somig -lex <path/to/file.som>` | prints tokens and exits\n\n",
    //     .{},
    // );

    try playground(allocator);
}

fn parse(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const filepath = args[2];
    var file = std.fs.cwd().openFile(filepath, .{ .mode = .read_only }) catch |err| {
        std.debug.print("Could not open the file '{s}'\n", .{filepath});
        return err;
    };
    defer file.close();
    const file_contents = file.readToEndAlloc(gpa, 100 * 4096) catch |err| {
        std.debug.print("Could not read the entire file due to size limits\n", .{});
        return err;
    };
    defer gpa.free(file_contents);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;
    defer stdout.flush() catch |err| std.debug.print("Could not flush stdout: {t}\n", .{err});

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    var stderr = &stderr_writer.interface;
    defer stderr.flush() catch |err| std.debug.print("Could not flush stderr: {t}\n", .{err});

    try parser_module.print_class_ast(file_contents, gpa, stdout, stderr);
}

fn lex(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const filepath = args[2];
    var file = std.fs.cwd().openFile(filepath, .{ .mode = .read_only }) catch |err| {
        std.debug.print("Could not open the file '{s}'\n", .{filepath});
        return err;
    };
    defer file.close();
    const file_contents = file.readToEndAlloc(gpa, 100 * 4096) catch |err| {
        std.debug.print("Could not read the entire file due to size limits\n", .{});
        return err;
    };
    defer gpa.free(file_contents);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;
    defer stdout.flush() catch |err| std.debug.print("Could not flush stdout: {t}\n", .{err});

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    var stderr = &stderr_writer.interface;
    defer stderr.flush() catch |err| std.debug.print("Could not flush stderr: {t}\n", .{err});

    // TODO: cleanup: make the `print_tokens` function somehow report an error, so that we can return it from this `main` function.
    try lexer_module.print_tokens(file_contents, gpa, stdout, stderr);
    return;
}

fn playground(allocator: std.mem.Allocator) !void {
    const buffers_length = 256;

    // Setup stdout
    var stdout_buffer: [buffers_length]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    var stdout: *std.io.Writer = &stdout_writer.interface;
    defer stdout.flush() catch |err| std.debug.print("Could not flush stdout: {t}\n", .{err});

    // Setup static fields
    var interpreter_arena = std.heap.ArenaAllocator.init(allocator);
    defer interpreter_arena.deinit();
    const interpreter_allocator = interpreter_arena.allocator();
    //
    var statics = Statics{
        .all_classes = .{},
        .all_methods = .{},
        // TODO: use a different allocator dedicated
        .allocator = interpreter_allocator,
        .symbols_manager = blk: {
            const manager = try SymbolsManager.create(interpreter_allocator, 0);
            break :blk manager;
        },
        .constants_manager = codegen.ConstantsManager.init(interpreter_allocator),
    };
    //
    const primitive_methods_map = try PrimitiveMethodsMap.init_from(
        interpreter_allocator,
        interpreter_module.primitives,
        &statics.symbols_manager,
    );
    //
    var source_code_files_arena = std.heap.ArenaAllocator.init(allocator);
    defer source_code_files_arena.deinit();
    var source_code_files = codegen.SourceCodeFiles{
        .cached_source_filepaths = codegen.SourceCodeFiles.Map.empty,
        .arena = source_code_files_arena,
        .root_filepath = "playground/",
    };

    // // Print bytecode
    // try stdout.print("=" ** 20 ++ "Bytecode (first instruction is at: [{d:04}])" ++ "=" ** 20 ++ "\n", .{start_instruction_id.idx});
    // try codegen.print_bytecode(
    //     &statics.symbols_manager,
    //     &statics.constants_manager,
    //     statics.constants_manager.current_base_id,
    //     bytecode,
    //     stdout,
    // );

    // Allocate stack
    const frames = try allocator.alloc(interpreter_module.Stack.Frame, 1000);
    defer allocator.free(frames);
    const objects = try allocator.alloc(interpreter_module.VmObject, 200);
    defer allocator.free(objects);

    // Setup interpreter
    var interpreter = Interpreter.new(
        // TODO: use a different allocator for heap, globals
        interpreter_allocator,
        interpreter_allocator,
        stdout,
        stdout,
        &statics,
        &source_code_files,
        primitive_methods_map,
        objects,
        frames,
    );
    interpreter.heap_allocator = interpreter.heap.arena.allocator();

    // Setup the base class hiearchy
    // TODO: assert correct hiearchy (meaning the classes actually point to each other)
    {
        const object_definition, const object_class_definition = blk: {
            const class = try interpreter.load_class_ignore_parent(SymbolsManager.comptime_id_of("Object"));
            break :blk .{ class, class.get_metaclass_through_vm_object() };
        };
        const class_definition, const class_class_definition = blk: {
            const class = try interpreter.load_class_ignore_parent(SymbolsManager.comptime_id_of("Class"));
            break :blk .{ class, class.get_metaclass_through_vm_object() };
        };

        // Assign the parents
        try codegen.set_parent_and_leak_original_methods(class_definition, object_definition, interpreter.statics);
        try codegen.set_parent_and_leak_original_methods(object_class_definition, class_definition, interpreter.statics);
        try codegen.set_parent_and_leak_original_methods(class_class_definition, object_class_definition, interpreter.statics);

        const metaclass_definition = try interpreter.load_class(SymbolsManager.comptime_id_of("Metaclass"));

        // Update all VM objects which represent some metaclass in the runtime,
        // so the "class of the class they are representing" is actually metaclass and not undefined.
        object_class_definition.as_vm_object.class_of_represented_class = metaclass_definition;
        class_class_definition.as_vm_object.class_of_represented_class = metaclass_definition;
        {
            const metaclass_class_definition = metaclass_definition.get_metaclass_through_vm_object();
            metaclass_class_definition.as_vm_object.class_of_represented_class = metaclass_definition;
            assert(metaclass_class_definition.get_metaclass_through_vm_object() == metaclass_definition);
        }
    }

    // Force load required builtin classes
    {
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Nil"));
        // _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Object")); // NOTE: this was loaded above
        // _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Class")); // NOTE: this was loaded above
        // _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Metaclass")); // NOTE: this was loaded above
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("True"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("False"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Integer"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Double"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Array"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("String"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Symbol"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Block1"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Block2"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Block3"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("System"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Method"));
        _ = try interpreter.load_class(SymbolsManager.comptime_id_of("Primitive"));
        inline for (std.meta.fields(interpreter_module.BuiltinClassDefinitions)) |field| {
            assert(@field(interpreter.builtin_class_definitions, field.name) != null);
        }
    }

    // Load singletons
    {
        const true_object = try types.GenericObject.create_new(statics.allocator, interpreter.builtin_class_definitions.true.?);
        const false_object = try types.GenericObject.create_new(statics.allocator, interpreter.builtin_class_definitions.false.?);
        const system_object = try types.System.crate_new(statics.allocator);
        interpreter.singletons = .{
            .true_object = true_object,
            .false_object = false_object,
            .system = system_object,
        };
        try interpreter.globals.put(SymbolsManager.comptime_id_of("system"), system_object);
        try interpreter.globals.put(SymbolsManager.comptime_id_of("true"), true_object);
        try interpreter.globals.put(SymbolsManager.comptime_id_of("false"), false_object);
        try interpreter.globals.put(SymbolsManager.comptime_id_of("nil"), VmObject.nil);
    }

    if (!interpreter_module.DEBUG_SKIP_BOOTSTRAP) {
        const program_arguments: VmObject = get_args: {
            // TODO: handle this properly, it should be arguments from the console
            var args_array: [1]VmObject = undefined;
            args_array[0] = try types.Symbol.create_new(statics.allocator, ((try statics.symbols_manager.id_or_intern("Main")).id));
            break :get_args try types.Array.create_new(statics.allocator, &args_array);
        };
        const initialize_method = interpreter.builtin_class_definitions.system.?.get_method(SymbolsManager.comptime_id_of("initialize:")) orelse {
            interpreter.report_runtime_error("The class `System` does not have an `initialize:` method, which is expected.", .{});
            std.process.exit(1);
        };
        try interpreter.push_object(program_arguments);
        try interpreter.push_object(interpreter.singletons.system);
        try interpreter.call_method(initialize_method);
        try interpreter.run();
    } else {
        const main_class = try interpreter.load_class((try statics.symbols_manager.id_or_intern("Main")).id);
        const run_method = main_class.get_method((try statics.symbols_manager.id_or_intern("run")).id).?;
        const main_object: VmObject = try types.GenericObject.create_new(interpreter.heap_allocator, main_class);
        try interpreter.push_object(main_object);
        try interpreter.call_method(run_method);
        try interpreter.run();
    }

    // // Dump the bytecode
    // try stdout.print("=" ** 20 ++ "Bytecode" ++ "=" ** 20 ++ "\n", .{});
    // try codegen.print_bytecode(
    //     &statics.symbols_manager,
    //     &statics.constants_manager,
    //     run_method.body.user_land.constants_base_id,
    //     run_method.body.user_land.bytecode,
    //     stdout,
    //     .{},
    // );
    // try stdout.print("\n", .{});

    // // Run the program
    // try stdout.print("=" ** 20 ++ "Program output" ++ "=" ** 20 ++ "\n", .{});
    // try interpreter.push_object(main_object);
    // try interpreter.call_method(run_method);
    // try interpreter.run();
}

// Forcing for `zig build test` to run tests in all files that
// are recursively imported from here.
test {
    _ = @import("frontend/parser.zig");
    // _ = @import("frontend/codegen.zig");
    // _ = @import("interning/symbol_array_map.zig");
    std.testing.refAllDeclsRecursive(@This());
}
