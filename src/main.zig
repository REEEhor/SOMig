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
    try add_temprorary_source_code(allocator, &source_code_files, &statics);

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
    interpreter.heap_allocator = interpreter.heap.arena.allocator();

    // Setup the base class hiearchy
    // TODO: assert correct hiearchy (meaning the classes actually point to each other)
    {
        const object_definition, const object_class_definition = blk: {
            const class = try interpreter.load_class_ignore_parent(SymbolsManager.comptime_id_of("Object"));
            break :blk .{ class, class.get_metaclass_through_vm_object() catch unreachable };
        };
        const class_definition, const class_class_definition = blk: {
            const class = try interpreter.load_class_ignore_parent(SymbolsManager.comptime_id_of("Class"));
            break :blk .{ class, class.get_metaclass_through_vm_object() catch unreachable };
        };

        // Assign the parents
        try codegen.set_parent_and_leak_original_methods(class_definition, object_definition, interpreter.statics);
        try codegen.set_parent_and_leak_original_methods(object_class_definition, class_definition, interpreter.statics);
        try codegen.set_parent_and_leak_original_methods(class_class_definition, object_class_definition, interpreter.statics);

        const metaclass_definition = try interpreter.load_class(SymbolsManager.comptime_id_of("Metaclass"));

        // Update all VM objects which represent some metaclass in the runtime,
        // so the "class of the class they are representing" is actually metaclass and not undefined.
        object_class_definition.as_vm_object.kind().class.class_of_represented_class = metaclass_definition;
        class_class_definition.as_vm_object.kind().class.class_of_represented_class = metaclass_definition;
        {
            const metaclass_class_definition = metaclass_definition.get_metaclass_through_vm_object() catch unreachable;
            metaclass_class_definition.as_vm_object.kind().class.class_of_represented_class = metaclass_definition;
            assert(metaclass_class_definition.get_metaclass_through_vm_object() catch unreachable == metaclass_definition);
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
        inline for (std.meta.fields(interpreter_module.BuiltinClassDefinitions)) |field| {
            assert(@field(interpreter.builtin_class_definitions, field.name) != null);
        }
    }
    // Load singletons
    {
        const true_object = try interpreter_module.types.GenericObject.create_new(statics.allocator, interpreter.builtin_class_definitions.true.?);
        const false_object = try interpreter_module.types.GenericObject.create_new(statics.allocator, interpreter.builtin_class_definitions.false.?);
        interpreter.singletons = .{
            .true_object = true_object,
            .false_object = false_object,
        };
    }

    const main_class = try interpreter.load_class((try statics.symbols_manager.id_or_intern("Main")).id);
    const run_method = main_class.get_method((try statics.symbols_manager.id_or_intern("run")).id).?;
    const main_object: interpreter_module.VmObject = try interpreter_module.types.GenericObject.create_new(interpreter.heap_allocator, main_class);
    // Dump the bytecode
    try stdout.print("=" ** 20 ++ "Bytecode" ++ "=" ** 20 ++ "\n", .{});
    try codegen.print_bytecode(
        &statics.symbols_manager,
        &statics.constants_manager,
        run_method.body.user_land.constants_base_id,
        run_method.body.user_land.bytecode,
        stdout,
        .{},
    );
    try stdout.print("\n", .{});

    // Run the program
    try stdout.print("=" ** 20 ++ "Program output" ++ "=" ** 20 ++ "\n", .{});
    try interpreter.push_object(main_object);
    try interpreter.call_method(run_method);
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

fn add_temprorary_source_code(allocator: std.mem.Allocator, source_code_files: *codegen.SourceCodeFiles, statics: *Statics) !void {
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Main")).id,
        \\  Main = (
        \\      run = (
        \\          | local_of_run1 local_of_run2 |
        \\          'Hello SOMig!' println.
        \\
        \\          #'this is some kind of symbol' println.
        \\
        \\          '\tThis is\n\tmultiline\n\ttext!' println.
        \\
        \\          'Before assignment: ' print.
        \\          local_of_run1 print. ' ' print.
        \\          local_of_run2 println.
        \\
        \\          local_of_run2 := local_of_run1 := 42.
        \\
        \\          'After assignment: ' print.
        \\          local_of_run1 print. ' ' print.
        \\          local_of_run2 println.
        \\
        \\          (42) println.
        \\          (5 + 3) println.
        \\          (1000.0 - 0.01) println.
        \\          ('Test of ' concatWith: 'concat strings') println.
        \\          'Number is: ' + 42 println.
        \\          ('I want ' + 98 + ' ice-creams.') println.
        \\          (10.0 / 0.0) println.
        \\          (10.0 / -0.0) println.
        \\          (10 / 4) println.
        \\
        \\          "Try uncommenting the line below to crash to program:"
        \\          "SomeClassWithSyntaxErrorInItsDefinition."
        \\
        \\           "12345678"
        \\          ('knihovna' substringFrom: 2 to: 5) println.
        \\
        \\          self println.
        \\
        \\          'This-is-symbol' asSymbol println.
        \\          "123456"
        \\          ('SYMBOL' asSymbol substringFrom: 1 to: 3) println.
        \\
        \\          self some_other_method.
        \\          1.
        \\          self get_message println.
        \\
        \\          self array_example.
        \\
        \\          '"5 + 3 * 2.0 + 3" is ' + (5 + 3 * 2.0 + 3).
        \\          (4 asString + 2) println.
        \\
        \\          self block_example.
        \\
        \\          self boolean_example.
        \\
        \\      )
        \\
        \\      block_example = (
        \\          | method1 method2 blk |
        \\          '\n== Block example ==' println.
        \\          
        \\          [ 'Hello SOMig from block!' ] value println.
        \\
        \\          method1 := [
        \\              | block_local |
        \\              block_local := '"I am a local variable from a block"'.
        \\              'In a block: ' print.
        \\              block_local println.
        \\              block_local.
        \\          ] value.
        \\          'Outside of a block: ' print.
        \\          method1 println.
        \\
        \\          [ :arg |
        \\              'This print is from a block: ' print.
        \\              arg println.
        \\          ] value.
        \\
        \\          [ :arg |
        \\              'This print is from a block: ' print.
        \\              arg println.
        \\          ] value: '"Argument to a block"'.
        \\
        \\          [ :arg1 :arg2 |
        \\              'This print is from a block. Arg1: ' print.
        \\              arg1 print.
        \\              ' Arg2: ' print.
        \\              arg2 println.
        \\          ] value: '"Argument 1 to a block"' with: '"Argument 2 to a block"'.
        \\
        \\          [ :arg1 :arg2 |
        \\              'This print is from a block. Arg1: ' print.
        \\              arg1 print.
        \\              ' Arg2: ' print.
        \\              arg2 println.
        \\          ] value: '"Argument 1 to a block"'.
        \\
        \\          '---' println.
        \\
        \\          method1 := '"local method1"'.
        \\          method2 := '"local method2"'.
        \\          [ 
        \\              'Captured variable in block: ' print.
        \\              method1 println.
        \\          ] value.
        \\
        \\          '---' println.
        \\
        \\          [
        \\              | a_block1 a_block2 |
        \\              a_block1 := '"local a_block1"'.
        \\              a_block2 := '"local a_block2"'.
        \\              [ 
        \\                  'Captured method variable in block:  ' print. method1 println.
        \\                  'Captured method variable in block:  ' print. method2 println.
        \\                  'Captured block A variable in block: ' print. a_block1 println.
        \\                  'Captured block A variable in block: ' print. a_block2 println.
        \\              ] value.
        \\          ] value.
        \\
        \\          '---' println.
        \\
        \\          'block_runner:' println.
        \\          self block_runner: [ :a_block_argument |
        \\              | a_block1 a_block2 |
        \\              a_block1 := '"local a_block1"'.
        \\              a_block2 := '"local a_block2"'.
        \\              [ 
        \\                  'Captured method variable in block:    ' print. method1 println.
        \\                  'Captured method variable in block:    ' print. method2 println.
        \\                  'Captured block A variable in block:   ' print. a_block1 println.
        \\                  'Captured block A variable in block:   ' print. a_block2 println.
        \\                  'Captured block A argument in a block: ' print. a_block_argument println.
        \\              ] value.
        \\          ] with_argument: '"This is an argument to the `block_runner:` method"'.
        \\
        \\          '---' println.
        \\
        \\          method1 := '"NOT Changed method1 value (if you see this, it\'s an error)"'.
        \\          blk := [ 'In block: ' print. method1 println. ].
        \\          method1 := '"Changed method1 value"'.
        \\          blk value.
        \\
        \\          '---' println.
        \\
        \\          method1 := '"NOT Changed method1 value (if you see this, it\'s an error)"'.
        \\          blk := [ method1 := '"Value set by a block"'. ].
        \\          blk value.
        \\          'Changed value by a block: ' print. method1 println.
        \\
        \\          '---' println.
        \\      )
        \\
        \\      block_runner: blk with_argument: arg = (
        \\          [
        \\              blk value: arg.
        \\          ] value.
        \\      )
        \\
        \\      boolean_example = (
        \\          | var1 var2 var3 |
        \\
        \\          '' println.
        \\          '== Boolean example ==' println.
        \\
        \\          '3=4: ' print. (3 = 4) println.
        \\          '3=3: ' print. (3 = 3) println.
        \\          '3=2: ' print. (3 = 2) println.
        \\
        \\          (3=2) ifFalse: [ '3 really does not equal 2' println. ].
        \\          (3=2) ifTrue:  [ 'Uh oh, 3 = 2' println. ].
        \\
        \\          (3=3) ifTrue:  [ '3 really equals 2' println. ].
        \\          (3=3) ifFalse: [ 'Uh oh, 3 != 3' println. ].
        \\
        \\          var1 := (3 = 3) not.
        \\          var2 := (10 = 4.2).
        \\          var3 := (var1 not and: [ true ]) or: var2. "<- `var2` here should be a block, but its fine"
        \\          var3 ifTrue: [ '`var3` is really true, nice. The class is: ' print ].
        \\          var3 class println.
        \\
        \\          '---' println.
        \\
        \\          ((3=3) ifTrue: ['"3=3" is true'] ifFalse: ['OH NO! "3=3" is false']) println.
        \\          ((3=2) ifTrue: ['"3=2" is false'] ifFalse: ['OH NO! "3=2" is true']) println.
        \\
        \\      )
        \\
        \\      array_example = (
        \\          | arr |
        \\
        \\          '' println.
        \\          '== Array example ==' println.
        \\
        \\          arr := #().
        \\          ('Array length: ' + (arr length)) println.
        \\
        \\          arr := #( 10 ).
        \\          ('Array length: ' + (arr length) + ' item: ' + (arr at: 1)) println.
        \\
        \\          arr := #( 10 20 30 ).
        \\          ('Array length: ' + (arr length) + ' items: ' + (arr at: 1) + ' ' + (arr at: 2) + ' ' + (arr at: 3)) println.
        \\
        \\          'Array at index 2: ' print. (arr at: 2) println.
        \\          arr at: 2 put: 42.
        \\          'Array at index 2: ' print. (arr at: 2) print. ' (after update)' println.
        \\
        \\          arr println.
        \\          '' println.
        \\      )
        \\
        \\      some_other_method = (
        \\          | some_variable cat |
        \\          cat := Cat new.
        \\          cat say_hi.
        \\          cat println.
        \\          cat set_name_to: 'Shrodinger'.
        \\          cat println.
        \\          cat set_jump_height_to: 150 + 2.
        \\          cat say_hi.
        \\          cat jump.
        \\          cat print_likability.
        \\
        \\          '`Cat static_say_hi:`       ' print.
        \\          Cat static_say_hi.
        \\
        \\          '`cat class static_say_hi:` ' print.
        \\          cat class static_say_hi.
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
        \\      = _ = primitive
        \\      + _ = primitive
        \\      - _ = primitive
        \\      * _ = primitive
        \\      / _ = primitive
        \\      asString = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Animal")).id,
        \\ Animal = (
        \\    | name |
        \\
        \\    name = ( ^ name )
        \\
        \\    asString = ( ^ 'animal named "' + (self name) + '"' )
        \\
        \\    set_name_to: new_name = (
        \\       name := new_name.
        \\    )
        \\
        \\    say_hi = (
        \\      'The animal "' print.
        \\      name print.
        \\      '" says "hi!"' println.
        \\    )
        \\
        \\    " Used for super call shinenigans "
        \\    get_likability = ( ^ 5. )
        \\
        \\    print_likability = (
        \\       ('The likability is: ' + self get_likability + '/10') println.
        \\    )
        \\
        \\  ------------------------------------------------------
        \\    static_say_hi = (
        \\        'Static "Hi!" from the Animal class' println.
        \\    )
        \\ )
        \\
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Cat")).id,
        \\ Cat = Animal (
        \\    | jump_height |
        \\
        \\    asString = ( ^ 'cat named "' + (self name) + '"' )
        \\
        \\    set_jump_height_to: new_jump_height_in_cm = (
        \\       jump_height := new_jump_height_in_cm.
        \\    )
        \\
        \\    jump = (
        \\       ('The cat named "' + (self name) + '"') print.
        \\       (' jumped ' + (jump_height) + ' cm high!') println.
        \\    )
        \\
        \\    " Used for super call shinenigans "
        \\    get_likability = (
        \\       |parent_likability|
        \\       ''println.
        \\       '  (calling to super to get likability...)' println.
        \\       parent_likability := super get_likability.
        \\       ^ parent_likability + 5.
        \\    )
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("SomeClassWithSyntaxErrorInItsDefinition")).id,
        \\ SomeClassWithSyntaxErrorInItsDefinition = (
        \\      say_hi = this_causes_parser_error
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
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Array")).id,
        \\ Array = (
        \\     at: index            = primitive
        \\     at: index put: value = primitive
        \\     length               = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("String")).id,
        \\ String = (
        \\      + obj = ( ^ self concatWith: obj asString  )
        \\      concatWith: otherString = primitive
        \\      asString = ( ^ self )
        \\      asSymbol = primitive
        \\      print = primitive
        \\      println = primitive
        \\      substringFrom: from to: to = ( ^ self primSubstringFrom: from to: to. )
        \\      primSubstringFrom: _ to: _ = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Symbol")).id,
        \\ Symbol = String (
        \\    asString = primitive
        \\    asSymbol = ( ^ self )
        \\    print = ( '#' print. super print )
        \\    println = ( '#' print. super println )
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
        \\      asString = ( ^self name asString )
        \\
        \\      "Constructor"
        \\      new = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Nil")).id,
        \\ Nil = (
        \\      asString = ( ^ 'nil' )
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Metaclass")).id,
        \\ Metaclass = Class ( )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Boolean")).id,
        \\ Boolean = (
        \\
        \\     "Conditional evaluation"
        \\     ifTrue: trueBlock ifFalse: falseBlock = (
        \\         self ifTrue:  [ ^trueBlock value  ].
        \\         self ifFalse: [ ^falseBlock value ].
        \\     )
        \\
        \\     "Logical operations"
        \\     || boolean = ( ^self or: boolean  )
        \\     && boolean = ( ^self and: boolean )
        \\
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("True")).id,
        \\ True = Boolean (
        \\
        \\     "Converting"
        \\     asString       = ( ^'true' )
        \\
        \\     "Conditional evaluation"
        \\     ifTrue:  block = ( ^block value )
        \\     ifFalse: block = ( ^nil )
        \\
        \\     "Logical operations"
        \\     not        = ( ^false )
        \\     or: block  = ( ^true )
        \\     and: block = ( ^block value )
        \\
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("False")).id,
        \\ False = Boolean (
        \\
        \\     "Converting"
        \\     asString       = ( ^'false' )
        \\
        \\     "Conditional evaluation"
        \\     ifTrue:  block = ( ^nil )
        \\     ifFalse: block = ( ^block value )
        \\
        \\     "Logical operations"
        \\     not        = ( ^true )
        \\     or: block  = ( ^block value )
        \\     and: block = ( ^false )
        \\
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Block")).id,
        \\ Block = (
        \\      value = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Block1")).id,
        \\ Block1 = Block (
        \\      value = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Block2")).id,
        \\ Block2 = Block (
        \\      value           = ( self value: nil )
        \\      value: argument = primitive
        \\ )
    );
    try source_code_files.cached_source_files.putNoClobber(allocator, (try statics.symbols_manager.id_or_intern("Block3")).id,
        \\ Block3 = Block (
        \\      value                  = ( self value: nil with: nil )
        \\      value: arg             = ( self value: arg with: nil )
        \\      value: arg1 with: arg2 = primitive
        \\ )
    );
}
