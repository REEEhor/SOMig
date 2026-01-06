const std = @import("std");

const parser_module = @import("frontend/parser.zig");
const Parser = parser_module.Parser;

const SymbolsManager = @import("interning/symbols_manager.zig").SymbolsManager;

const codegen = @import("frontend/codegen.zig");

const interpreter_module = @import("interpreter/interpreter.zig");
const Interpreter = interpreter_module.Interpreter;
const Statics = interpreter_module.Statics;
const PrimitiveMethodsMap = interpreter_module.PrimitiveMethodsMap;

const lexer_module = @import("frontend/lexer.zig");
const Lexer = lexer_module.Lexer;
const reporter_module = @import("frontend/reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args: [][:0]u8 = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 3 and std.mem.eql(u8, args[1], "-lex")) {
        try lex(allocator, args);
        return;
    }

    if (args.len == 3 and std.mem.eql(u8, args[1], "-parse")) {
        try parse(allocator, args);
        return;
    }

    std.debug.print(
        "This will be an amazing SOMig project!\n\nUsage (so far):\n\t- `somig -lex <path/to/file.som>` | prints tokens and exits\n\n",
        .{},
    );

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
    const buffers_length = 0;

    // Setup stdout
    var stdout_buffer: [buffers_length]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout: *std.io.Writer = &stdout_writer.interface;
    defer stdout.flush() catch |err| std.debug.print("Could not flush stdout: {t}\n", .{err});

    // Setup static fields
    var interpreter_arena = std.heap.ArenaAllocator.init(allocator);
    defer interpreter_arena.deinit();
    const interpreter_allocator = interpreter_arena.allocator();
    //
    var statics = Statics{
        .all_classes = .{},
        // TODO: use a different allocator dedicated
        .allocator = interpreter_allocator,
        .symbols_manager = blk: {
            const manager = try SymbolsManager.create(interpreter_allocator, 0);
            break :blk manager;
        },
        .constants_manager = codegen.ConstantsManager.init(interpreter_allocator),
        .instruction_encoder = codegen.InstructionEncoder{ .bytes = .empty },
    };
    //
    const primitive_methods_map = try PrimitiveMethodsMap.init_from(
        interpreter_allocator,
        interpreter_module.primitives,
        &statics.symbols_manager,
    );
    //
    var source_code_files = codegen.SourceCodeFiles{ .cached_source_files = codegen.SourceCodeFiles.Map.empty };
    defer source_code_files.cached_source_files.deinit(allocator);

    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Main")).id,
        \\  Main = (
        \\      run = (
        \\          'Hello SOMig!' println.
        \\          42.
        \\          5 + 3.
        \\          1000.0 - 0.01.
        \\          ('Test of ' concatWith: 'concat strings') println.
        \\          'Number is: ' + 42 println.
        \\          'I want ' + 98 + ' ice-creams.'.
        \\          10.0 / 0.0.
        \\          10 / 4.
        \\
        \\          self some_other_method.
        \\          1.
        \\          self get_message println.
        \\
        \\          '"5 + 3 * 2.0 + 3" is ' + (5 + 3 * 2.0 + 3).
        \\          4 asString + 2.
        \\      )
        \\
        \\      some_other_method = (
        \\          |some_variable|
        \\          some_variable := 'ahoj'.
        \\          'Hello from another method!'
        \\      )
        \\
        \\      get_message = (
        \\          'Currently inside the `get_message` function'.
        \\          ^ 'This is a message from a function'.
        \\      )
        \\
        \\  )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Integer")).id,
        \\ Integer = (
        \\      + _ = primitive
        \\      - _ = primitive
        \\      * _ = primitive
        \\      / _ = primitive
        \\      asString = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Double")).id,
        \\ Double = (
        \\      + _ = primitive
        \\      - _ = primitive
        \\      * _ = primitive
        \\      / _ = primitive
        \\      asString = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("String")).id,
        \\ String = (
        \\      + obj = ( ^ self concatWith: obj asString  )
        \\      concatWith: otherString = primitive
        \\      asString = ( ^ self )
        \\      print = primitive
        \\      println = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Object")).id,
        \\ Object = nil (
        \\      print = ( self asString print )
        \\      println = ( self asString println )
        \\      asString = ( ^ 'An instance of the class ' + self class name )
        \\      class = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Class")).id,
        \\ Class = (
        \\      name = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Nil")).id,
        \\ Nil = (
        \\      asString = ( ^ 'nil' )
        \\ )
    );

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
    const frames = try allocator.alloc(interpreter_module.Stack.Frame, 10);
    defer allocator.free(frames);
    const objects = try allocator.alloc(interpreter_module.VmObject, 100);
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

    // NOTE: This will probably have to be also in the final implementation together with loading of the `Metaclass`
    try interpreter.ensure_primitive_class_is_loaded(.class);

    const main_class = try interpreter.load_class((try statics.symbols_manager.id_or_intern("Main")).id);
    const run_method = main_class.get_method((try statics.symbols_manager.id_or_intern("run")).id).?;

    var header = interpreter_module.HeapData.Header.new_undefined_with_tag(.generic_object);
    (interpreter_module.GenericObjectAccessor{}).set_instance_variables_count(header.as_heap_data(), 0);
    const main_object_data = try interpreter.statics.allocate_for_static_object(header);
    (interpreter_module.GenericObjectAccessor{}).set_class_definition(main_object_data, main_class);
    const main_object = main_object_data.as_vm_object();

    try interpreter.push_object(main_object);
    try interpreter.push_frame(run_method.body.user_land.constants_base_id, 0, 0, codegen.InstructionId{ .idx = 9999 }); // TODO: remove hack with return instruction id!!!
    interpreter.decoder.set_id_of_the_next_instruction(run_method.body.user_land.start_instruction);

    // Dump the bytecode
    try stdout.print("=" ** 20 ++ "Bytecode" ++ "=" ** 20 ++ "\n", .{});
    try codegen.print_bytecode(
        &statics.symbols_manager,
        &statics.constants_manager,
        run_method.body.user_land.constants_base_id,
        statics.instruction_encoder.view_bytecode(),
        stdout,
    );
    try stdout.print("\n", .{});

    // Run the program
    try stdout.print("=" ** 20 ++ "Program output" ++ "=" ** 20 ++ "\n", .{});
    try interpreter.run();
}

// Forcing for `zig build test` to run tests in all files that
// are recursively imported from here.
test {
    _ = @import("frontend/parser.zig");
    // _ = @import("frontend/codegen.zig");
    // _ = @import("interning/symbol_array_map.zig");
    std.testing.refAllDeclsRecursive(@This());
}
