const std = @import("std");
const builtin = @import("builtin");
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
const Heap = interpreter_module.Heap;

const lexer_module = @import("frontend/lexer.zig");
const Lexer = lexer_module.Lexer;
const reporter_module = @import("frontend/reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;

pub fn main() !void {
    // Setup allocator
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 100 }) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args_with_program: [][:0]u8 = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args_with_program);
    const args = args_with_program[1..];

    if (std.mem.eql(u8, args[0], "--parse")) {
        if (args.len != 2) {
            std.debug.print("ERROR: Expected a single filepath argument after `--parse`.\n", .{});
            return;
        }
        const filepath = args[1];
        return parse(gpa, filepath);
    }

    var stdout_buffer = [_]u8{0} ** 1024;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var arguments_for_som = std.ArrayList([]const u8).empty;
    defer arguments_for_som.deinit(gpa);

    var root_directories = std.ArrayList(codegen.SourceCodeFiles.Directory).empty;
    defer root_directories.deinit(gpa);

    var skip_bootstrap = false;

    // Parse command line arguments
    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--include")) {
            arg_idx += 1;
            if (arg_idx >= args.len) std.debug.panic("Expected argument", .{});
            try root_directories.append(gpa, .{
                .can_be_searched_recursively = false,
                .path = args[arg_idx],
            });
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "-ir") or std.mem.eql(u8, arg, "-ri") or std.mem.eql(u8, arg, "--recursively-include")) {
            arg_idx += 1;
            if (arg_idx >= args.len) std.debug.panic("Expected argument", .{});
            try root_directories.append(gpa, .{
                .can_be_searched_recursively = true,
                .path = args[arg_idx],
            });
        } else if (std.mem.eql(u8, arg, "--")) {
            arg_idx += 1;
            try arguments_for_som.appendSlice(gpa, args[arg_idx..]);
            break;
        } else if (std.mem.eql(u8, arg, "--no-bs")) {
            skip_bootstrap = true;
        } else {
            std.debug.panic("Invalid flag '{s}'", .{arg});
        }
    }

    try run(.{
        .gpa = gpa,
        .stdout = stdout,
        .stderr = stderr,
        .stack_size = .{
            .objects_count = 200, // TODO: these should be parsed from args
            .frames_count = 1000, // TODO: these should be parsed from args
        },
        .program_arguments_as_strings = arguments_for_som.items,
        .root_directories = root_directories.items,
        .skip_bootstrap = interpreter_module.DEBUG_SKIP_BOOTSTRAP or skip_bootstrap,
    });
}

fn parse(allocator: std.mem.Allocator, filepath: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

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

pub const RunParams = struct {
    gpa: std.mem.Allocator,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    stack_size: struct { objects_count: usize, frames_count: usize },
    root_directories: []const codegen.SourceCodeFiles.Directory,
    program_arguments_as_strings: []const []const u8,
    skip_bootstrap: bool,
};

pub fn run(params: RunParams) !void {
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
        .constants_manager = codegen.ConstantsManager.init(static_allocator),
    };

    // Make program arguments into VM strings
    const programs_arguments = try types.Array.create_with_undefined_items(&statics, program_arguments_as_strings.len);
    for (programs_arguments.get_items(), program_arguments_as_strings) |*argument, argument_as_string| {
        argument.* = try interpreter_module.types.String.create_new(&statics, argument_as_string);
    }

    // Prepare primitive methods
    const primitive_methods_map = try PrimitiveMethodsMap.init_from(
        static_allocator,
        interpreter_module.primitive_methods_module,
        &statics.symbols_manager,
    );

    // Prepare source code loader
    var source_code_files = codegen.SourceCodeFiles.init(.{
        .allocator = gpa,
        .root_directories = root_directories,
    });
    defer source_code_files.deinit();

    // Allocate stack
    const frames = try static_allocator.alloc(interpreter_module.Stack.Frame, stack_size.frames_count);
    const objects = try static_allocator.alloc(interpreter_module.VmObject, stack_size.objects_count);

    // Set up temporary arena
    var temporary_arena = std.heap.ArenaAllocator.init(gpa);
    defer temporary_arena.deinit();

    // Setup interpreter
    var interpreter = Interpreter.new(
        Heap{ .backing_allocator = gpa, .interpreter = undefined },
        static_allocator,
        &temporary_arena,
        stdout,
        stderr,
        &statics,
        &source_code_files,
        primitive_methods_map,
        objects,
        frames,
    );
    interpreter.heap.interpreter = &interpreter;
    defer interpreter.heap.deinit();
    try interpreter.heap.reserve_at_least(.{ .total_minimum_number_of_bytes = 1 });

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
        const true_object = try types.GenericObject.create_new(&statics, interpreter.builtin_class_definitions.true.?);
        const false_object = try types.GenericObject.create_new(&statics, interpreter.builtin_class_definitions.false.?);
        const system_object = try types.System.create_new(&statics);
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

    if (skip_bootstrap) {
        // This is basically code from `System >> initialize:` method, but in Zig.
        if (program_arguments_as_strings.len == 0) {
            interpreter.report_runtime_error("No entrypoint class was supplied.", .{});
            return error.no_entrypoint_class;
        }
        const main_class = try interpreter.load_class((try statics.symbols_manager.id_or_intern(program_arguments_as_strings[0])).id);
        const main_object: VmObject = try types.GenericObject.create_new(&interpreter.heap, main_class);
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
        interpreter.run() catch |err| {
            interpreter.stderr.flush() catch {};
            interpreter.stdout.flush() catch {};
            interpreter.debug_print_stack() catch {};
            return err;
        };
    } else {
        const initialize_method = interpreter.builtin_class_definitions.system.?.get_method(SymbolsManager.comptime_id_of("initialize:")) orelse {
            interpreter.report_runtime_error("The class `System` does not have the expected `initialize: arguments` method.", .{});
            return error.no_initialize_method;
        };
        try interpreter.push_object(VmObject.from(programs_arguments));
        try interpreter.push_object(interpreter.singletons.system);
        try interpreter.call_method(initialize_method);
        interpreter.run() catch |err| {
            interpreter.stderr.flush() catch {};
            interpreter.stdout.flush() catch {};
            interpreter.debug_print_stack() catch {};
            return err;
        };
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
