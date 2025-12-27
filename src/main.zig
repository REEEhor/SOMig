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
    const code =
        \\
        \\  SomeClass = (
        \\      run = (
        \\          'Hello SOMig!'.
        \\          42.
        \\          5 + 3.
        \\          1000.0 - 0.01.
        \\          'I want ' + 98 + ' ice-creams.'.
        \\          10.0 / 0.0.
        \\          10 / 4.
        \\          '\'5 + 3 * 2.0 + 3\' is ' + (5 + 3 * 2.0 + 3).
        \\          4 asString + 2.
        \\      )
        \\  )
        \\
    ;

    const buffers_length = 0;

    // Setup stdout
    var stdout_buffer: [buffers_length]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout: *std.io.Writer = &stdout_writer.interface;
    defer stdout.flush() catch |err| std.debug.print("Could not flush stdout: {t}\n", .{err});

    // Setup the arena allocator for parsing
    var parser_arena = std.heap.ArenaAllocator.init(allocator);
    defer parser_arena.deinit();
    const parser_allocator = parser_arena.allocator();

    // Setup error reporter
    var reporter = ErrorReporter{ .source = code, .source_path = "Playground-code", .use_color = true, .writer = stdout };

    // Tokenize the source code
    const tokenize_source_code = try lexer_module.tokenize(parser_allocator, code, &reporter);

    // Parse the source code
    var parser = Parser.create(tokenize_source_code, &reporter, parser_allocator);
    var parsed_file = try parser.parse();

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
        \\      + _ = primitive
        \\      asString = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Object")).id,
        \\ Object = nil ( )
    );

    // Setup bytecode generator
    var scope_stack = try codegen.ScopeStack.init(parser_allocator, 0, 0);
    //
    var bytecode_generator = codegen.BytecodeGenerator{
        .allocator = statics.allocator,
        .builder = &statics.instruction_encoder,
        .reporter = &reporter,
        .constants_manager = &statics.constants_manager,
        .symbols_manager = &statics.symbols_manager,
    };

    // Compile to bytecode
    const compiled_method = parsed_file.class_ast.instance_portion.methods[0];
    //
    const start_instruction_id = try bytecode_generator.compile_method(
        &parsed_file,
        &scope_stack,
        compiled_method.span,
        compiled_method.body.impl,
        compiled_method.header,
    );
    const bytecode: codegen.Bytecode = bytecode_generator.builder.view_bytecode();

    // Print bytecode
    try stdout.print("=" ** 20 ++ "Bytecode (first instruction is at: [{d:04}])" ++ "=" ** 20 ++ "\n", .{start_instruction_id.idx});
    try codegen.print_bytecode(
        &statics.symbols_manager,
        &statics.constants_manager,
        statics.constants_manager.current_base_id,
        bytecode,
        stdout,
    );

    // Allocate stack
    const frames = try allocator.alloc(interpreter_module.Stack.Frame, 10);
    defer allocator.free(frames);
    const objects = try allocator.alloc(interpreter_module.VmObject, 100);
    defer allocator.free(objects);

    // Setup interpreter
    const instruction_decoder = codegen.InstructionDecoder.new(bytecode);
    //
    var interpreter = Interpreter.new(
        // TODO: use a different allocator for heap, globals
        interpreter_allocator,
        interpreter_allocator,
        instruction_decoder,
        stdout,
        stdout,
        &statics,
        &source_code_files,
        primitive_methods_map,
        objects,
        frames,
    );

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
