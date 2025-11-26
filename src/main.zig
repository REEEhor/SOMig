const std = @import("std");
const lexer_module = @import("frontend/lexer.zig");
const StringLiteralsManager = @import("frontend/string_literals_manager.zig").StringLiteralsManager;
const Lexer = lexer_module.Lexer;
const parser_module = @import("frontend/parser.zig");
const Parser = parser_module.Parser;
const reporter_module = @import("frontend/reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;

const SymbolsManager = @import("interning/symbols_manager.zig").SymbolsManager;

const codegen = @import("frontend/codegen.zig");

const interpreter_module = @import("interpreter/interpreter.zig");
const Interpreter = interpreter_module.Interpreter;
const PrimitiveMethodsMap = interpreter_module.PrimitiveMethodsMap;
const primitives = interpreter_module.primitives;

const defs = @import("custom_definitions/definitions.zig");
const int = defs.int;
const uint = defs.uint;

const dbg = std.debug.print;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args: [][:0]u8 = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 3 and std.mem.eql(u8, args[1], "-lex")) {
        try lex(allocator, args);
        return;
    }

    std.debug.print(
        "This will be an amazing SOMig project!\n\nUsage (so far):\n\t- `somig -lex <path/to/file.som>` | prints tokens and exits\n\n",
        .{},
    );

    try playground(allocator);
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

    // Setup string literals manager
    var tmp_buffer: [4096]u8 = undefined;
    var buffer_tmp_fixed = std.heap.FixedBufferAllocator.init(&tmp_buffer);
    const buffer_tmp_allocator = buffer_tmp_fixed.allocator();
    //
    var all_strings_arena = std.heap.ArenaAllocator.init(allocator);
    defer all_strings_arena.deinit();
    const all_strings_allocator = all_strings_arena.allocator();

    // Setup lexer
    var string_literals_manager = try StringLiteralsManager.create(all_strings_allocator, buffer_tmp_allocator, 0);
    var reporter = ErrorReporter{ .source = code, .source_path = "Playground-code", .use_color = true, .writer = stdout };
    var lexer = Lexer.create(code, reporter, &string_literals_manager);

    // Parse the source code
    var parser_arena = std.heap.ArenaAllocator.init(allocator);
    defer parser_arena.deinit();
    const parser_allocator = parser_arena.allocator();
    //
    var parser = try Parser.create(&lexer, reporter, parser_allocator);
    var class_ast = try parser.parse();

    // Setup string internining
    var interning_arenas = .{
        std.heap.ArenaAllocator.init(allocator),
        std.heap.ArenaAllocator.init(allocator),
        std.heap.ArenaAllocator.init(allocator),
    };
    var string_interning_manager = try SymbolsManager.create(&interning_arenas.@"0", &interning_arenas.@"1", &interning_arenas.@"2", 0);
    defer string_interning_manager.deinit();

    // Setup bytecode generator
    var bytecode_generator_arena = std.heap.ArenaAllocator.init(allocator);
    defer bytecode_generator_arena.deinit();
    const bytecode_generator_allocator = bytecode_generator_arena.allocator();
    //
    var instruction_encoder = codegen.InstructionEncoder{ .bytes = .empty };
    var constants_arena = std.heap.ArenaAllocator.init(allocator);
    const constants_allocator = constants_arena.allocator();
    var constants_manager = codegen.ConstantsManager.init(constants_allocator);
    //
    var bytecode_generator = codegen.BytecodeGenerator{
        .allocator = bytecode_generator_allocator,
        .builder = &instruction_encoder,
        .class_ast = &class_ast,
        .parser = &parser,
        .reporter = &reporter,
        .constants_manager = &constants_manager,
        .symbols_manager = &string_interning_manager,
    };

    // Compile to bytecode
    try bytecode_generator.compile();
    const bytecode: codegen.Bytecode = bytecode_generator.builder.view_bytecode();

    // Print bytecode
    try stdout.print("=" ** 20 ++ "Bytecode" ++ "=" ** 20 ++ "\n", .{});
    try codegen.print_bytecode(&string_interning_manager, &constants_manager, constants_manager.current_base_id, bytecode, stdout);

    // Setup interpreter
    var interpreter_arena = std.heap.ArenaAllocator.init(allocator);
    defer interpreter_arena.deinit();
    const interpreter_allocator = interpreter_arena.allocator();
    //
    const primitive_methods_map = try PrimitiveMethodsMap.init_from(interpreter_allocator, primitives, &string_interning_manager);
    //
    var instruction_decoder = codegen.InstructionDecoder.new(bytecode);
    //
    var interpreter = Interpreter.new(
        interpreter_allocator,
        &instruction_decoder,
        &constants_manager,
        &string_interning_manager,
        stdout,
        stdout,
        primitive_methods_map,
    );
    //
    try interpreter.TODO_REMOVE_THIS__add_implementations_of_primitive_classes();

    // Run the program
    try stdout.print("=" ** 20 ++ "Program output" ++ "=" ** 20 ++ "\n", .{});
    try interpreter.run();
}

// Forcing for `zig build test` to run tests in all files that
// are recursively imported from here.
test {
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/codegen.zig");
    _ = @import("interning/symbols_manager.zig");
    std.testing.refAllDeclsRecursive(@This());
}
