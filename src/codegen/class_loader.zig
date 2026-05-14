const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const frontend_module = @import("../frontend/__frontend.zig");
const ErrorReporter = frontend_module.ErrorReporter;
const ParsedFile = frontend_module.ParsedFile;
const Ast = frontend_module.ast;
const token_iterator = frontend_module.token_iterator;
const literals = frontend_module.literals;
const lexer_module = frontend_module.lexer;
const parser_module = frontend_module.parser;

const bytecode_module = @import("../bytecode/__bytecode.zig");
const Bytecode = bytecode_module.Bytecode;
const Instruction = bytecode_module.Instruction;
const InstructionId = bytecode_module.InstructionId;
const InstructionEncoder = bytecode_module.InstructionEncoder;

const codegen_module = @import("__codegen.zig");
const LexicalScopeStack = codegen_module.LexicalScopeStack;
const BytecodeGenerator = codegen_module.BytecodeGenerator;

const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

const runtime_module = @import("../runtime/__runtime.zig");
const ConstantsManager = runtime_module.ConstantsManager;
const MethodDefinition = runtime_module.MethodDefinition;
const ClassDefinition = runtime_module.ClassDefinition;
const SmallPtr = runtime_module.SmallPtr;
const StringLiteralId = runtime_module.StringLiteralId;
const BlockDefinitionId = runtime_module.BlockDefinitionId;
const BlockDefinition = runtime_module.BlockDefinition;
const FunctionBody = runtime_module.FunctionBody;
const SourceCodeFiles = runtime_module.SourceCodeFiles;
const Statics = runtime_module.Statics;
const PrimitiveMethodsMap = runtime_module.PrimitiveMethodsMap;
const VmObject = runtime_module.VmObject;
const OpaqueHeader = runtime_module.OpaqueHeader;
const types = runtime_module.types;
const MethodBody = runtime_module.MethodBody;
const BuiltinClassDefinitions = runtime_module.BuiltinClassDefinitions;

pub fn find_file_and_parse_it(
    class_name: SymbolId,
    source_code_files: *SourceCodeFiles,
    statics: *Statics,
    error_writer: *std.io.Writer,
    parse_allocator: Allocator,
    use_colored_printing: bool,
) !ParsedFile {
    var reporter = ErrorReporter{
        .source = undefined,
        .source_path = null,
        .use_color = use_colored_printing,
        .writer = error_writer,
    };
    const lookup_result = (try source_code_files.get_source_code_of(class_name, parse_allocator, .{
        .error_reporter = &reporter,
        .temporary_allocator = parse_allocator,
        .symbols_manager = &statics.symbols_manager,
    })) orelse {
        const class_name_str = statics.symbols_manager.symbol_with_id(class_name);
        reporter.report_error(.no_location, "Could not find the source code for the class '{s}'.", .{class_name_str});
        if (std.mem.endsWith(u8, class_name_str, ".som")) {
            reporter.add_note(.no_location, "The class name ends with '.som', you probably wanted to load the class '{s}'.", .{class_name_str[0 .. class_name_str.len - ".som".len]});
        }
        return error.sourcecode_for_class_not_found;
    };
    reporter.source = lookup_result.source_code;
    reporter.source_path = lookup_result.filepath;

    const tokenized_file = try lexer_module.tokenize(.{
        .allocator = parse_allocator,
        .source_code = lookup_result.source_code,
        .source_code_filepath = lookup_result.filepath,
        .reporter = &reporter,
    });
    var parser = parser_module.Parser.create(tokenized_file, &reporter, parse_allocator);
    const parsed_file = try parser.parse();

    {
        const actual_class_name = parsed_file.text_at(parsed_file.class_ast.class_name);
        const expected_class_name = statics.symbols_manager.symbol_with_id(class_name);
        if (!std.mem.eql(u8, actual_class_name, expected_class_name)) {
            reporter.report_error(
                .{ .pos = parsed_file.pos_of(parsed_file.class_ast.class_name) },
                "Mismatch between the class name '{s}' and filename '{s}.som'.",
                .{ actual_class_name, expected_class_name },
            );
            return error.class_name_does_not_match_filename;
        }
    }

    return parsed_file;
}

pub fn symbol_of_parents_name(maybe_parent_name_token: ?Ast.TokenId, symbols_manager: *SymbolsManager, ast: ParsedFile) !?SymbolId {
    const text = if (maybe_parent_name_token) |token_id| ast.text_at(token_id) else "Object";
    if (std.mem.eql(u8, text, "nil")) {
        return null;
    }
    const intern_result = try symbols_manager.id_or_intern(text);
    return intern_result.id;
}

pub const ClassLoader = struct {
    statics: *Statics,
    temporary_arena: *std.heap.ArenaAllocator,
    source_code_files: *SourceCodeFiles,
    error_writer: *std.io.Writer,
    primitive_methods_map: *const PrimitiveMethodsMap,
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
    metaclass_definition: ?*ClassDefinition,
    object_definition: ?*ClassDefinition,
    use_colored_printing: bool,

    /// Loads a class together with its parents.
    /// WARN: `metaclass_definition` cannot be `null` at this point
    /// NOTE: `metaclass_definition` is set by the method `load_builtin_classes`, you can call that first.
    pub fn load_class(self: *Self, class_name: SymbolId) !*ClassDefinition {
        const metaclass_definition: *ClassDefinition = self.metaclass_definition orelse {
            std.debug.panic("The metaclass is not provided!", .{});
        };
        defer _ = self.temporary_arena.reset(.retain_capacity);
        const class_definition_pair = try compile_class_with_its_parents(.{
            .bottom_class_name = class_name,
            .statics = self.statics,
            .temporary_allocator = self.temporary_arena.allocator(),
            .source_code_files = self.source_code_files,
            .error_writer = self.error_writer,
            .primitive_methods_map = self.primitive_methods_map,
            .globals = self.globals,
            .use_colored_printing = self.use_colored_printing,
            .metaclass_definition = metaclass_definition,
        });
        return class_definition_pair.class;
    }

    pub fn load_builtin_classes(self: *Self) !BuiltinClassDefinitions {
        const base_classes: BuiltinBaseHierarchy = try self.load_builtin_base_hierarchy();

        return BuiltinClassDefinitions{
            .object = base_classes.class_of_object,
            .class = base_classes.class_of_class,
            .metaclass = base_classes.class_of_metaclass,
            .array = try self.load_builtin_class("Array", .{}),
            .string = try self.load_builtin_class("String", .{}),
            .double = try self.load_builtin_class("Double", .{}),
            .integer = try self.load_builtin_class("Integer", .{}),
            .symbol = try self.load_builtin_class("Symbol", .{ .expected_parent_apart_from_none_or_object = "String" }),
            .block1 = try self.load_builtin_class("Block1", .{ .expected_parent_apart_from_none_or_object = "Block" }),
            .block2 = try self.load_builtin_class("Block2", .{ .expected_parent_apart_from_none_or_object = "Block" }),
            .block3 = try self.load_builtin_class("Block3", .{ .expected_parent_apart_from_none_or_object = "Block" }),
            .method = try self.load_builtin_class("Method", .{}),
            .primitive = try self.load_builtin_class("Primitive", .{}),
            //                      NOTE: These classes are 100% user level defined, so they could have fields if we did not NaN boxed them (but we NaN box them)
            .nil = try self.load_builtin_class("Nil", .{ .can_inherit_from_whatever = true }), // Cannot have fields due to NaN boxing
            .true = try self.load_builtin_class("True", .{ .can_inherit_from_whatever = true }), // Cannot have fields due to NaN boxing
            .false = try self.load_builtin_class("False", .{ .can_inherit_from_whatever = true }), // Cannot have fields due to NaN boxing
            .system = try self.load_builtin_class("System", .{ .can_inherit_from_whatever = true }), // Cannot have fields due to NaN boxing
        };
    }

    fn load_builtin_class(self: *Self, comptime class_name: []const u8, params: struct {
        expected_parent_apart_from_none_or_object: ?[]const u8 = null,
        can_inherit_from_whatever: bool = false,
        can_have_fields: bool = false,
    }) !*ClassDefinition {
        const err = try_block: {
            const class_definition = self.load_class(SymbolsManager.comptime_id_of(class_name)) catch |err| break :try_block err;
            if (!params.can_inherit_from_whatever) {
                self.report_if_class_has_invalid_parent(class_definition, params.expected_parent_apart_from_none_or_object);
            }
            if (!params.can_have_fields) {
                self.validate_class_has_no_fields(class_definition) catch |err| break :try_block err;
            }
            return class_definition;
        };
        var reporter = ErrorReporter{ .source = undefined, .source_path = null, .use_color = self.use_colored_printing, .writer = self.error_writer };
        reporter.report_error(.no_location, "Could not load the builtin class {s}.", .{class_name});
        return err;
    }

    fn report_if_class_has_invalid_parent(self: *Self, class: *ClassDefinition, expected_parent_apart_from_none_or_object: ?[]const u8) void {
        var reporter = ErrorReporter{ .source = undefined, .source_path = null, .use_color = self.use_colored_printing, .writer = self.error_writer };
        const actual_parent = class.parent orelse return;
        const actual_parent_name: []const u8 = self.statics.symbols_manager.symbol_with_id(actual_parent.class_name);
        const class_name: []const u8 = self.statics.symbols_manager.symbol_with_id(class.class_name);

        if (expected_parent_apart_from_none_or_object) |expected_parent_name| {
            if (!std.mem.eql(u8, actual_parent_name, expected_parent_name) and actual_parent != self.object_definition) {
                reporter.report_warning(
                    .no_location,
                    "The class {s} has unexpected parent {s} (expected either none, Object, or {s}). Inherited methods may cause runtime errors.",
                    .{ class_name, actual_parent_name, expected_parent_name },
                );
            }
        } else if (actual_parent != self.object_definition) {
            reporter.report_warning(
                .no_location,
                "The class {s} has unexpected parent {s} (expected either none or Object). Inherited methods may cause runtime errors.",
                .{ class_name, actual_parent_name },
            );
        }
    }

    const BuiltinBaseHierarchy = struct {
        class_of_object: *ClassDefinition,
        class_of_class: *ClassDefinition,
        class_of_metaclass: *ClassDefinition,
    };
    /// Loads the builtin classes `Object`, `Class`, and `Metaclass`,
    /// which have more complicated structure than other classes.
    fn load_builtin_base_hierarchy(self: *Self) !BuiltinBaseHierarchy {
        // Parse the source code of the classes
        const object_ast: ParsedFile = self.parse_file(SymbolsManager.comptime_id_of("Object")) catch |err| {
            if (err == error.sourcecode_for_class_not_found) {
                var reporter = self.create_reporter();
                reporter.add_note(.no_location, "You probably did not include the path to the core library.", .{});
            }
            return err;
        };
        const class_ast: ParsedFile = try self.parse_file(SymbolsManager.comptime_id_of("Class"));
        const metaclass_ast: ParsedFile = try self.parse_file(SymbolsManager.comptime_id_of("Metaclass"));

        // Validate the hierarchy
        try self.validate_parent_is_nil(object_ast);
        try self.validate_parent_name_is(class_ast, "Object");
        try self.validate_parent_name_is(metaclass_ast, "Class");

        // Compile the classes
        const object = try self.compile_portion_of_builtin_class___do_not_set_as_vm_object(.{
            .ast = object_ast,
            .portion = object_ast.class_ast.instance_portion,
            .class_name_symbol = SymbolsManager.comptime_id_of("Object"),
            .compiled_parent = null,
        });
        const class = try self.compile_portion_of_builtin_class___do_not_set_as_vm_object(.{
            .ast = class_ast,
            .portion = class_ast.class_ast.instance_portion,
            .class_name_symbol = SymbolsManager.comptime_id_of("Class"),
            .compiled_parent = object,
        });
        const object_class = try self.compile_portion_of_builtin_class___do_not_set_as_vm_object(.{
            .ast = object_ast,
            .portion = object_ast.class_ast.class_portion,
            .class_name_symbol = SymbolsManager.comptime_id_of("Object class"),
            .compiled_parent = class,
        });
        const class_class = try self.compile_portion_of_builtin_class___do_not_set_as_vm_object(.{
            .ast = class_ast,
            .portion = class_ast.class_ast.class_portion,
            .class_name_symbol = SymbolsManager.comptime_id_of("Class class"),
            .compiled_parent = object_class,
        });
        const metaclass = try self.compile_portion_of_builtin_class___do_not_set_as_vm_object(.{
            .ast = metaclass_ast,
            .portion = metaclass_ast.class_ast.instance_portion,
            .class_name_symbol = SymbolsManager.comptime_id_of("Metaclass"),
            .compiled_parent = class,
        });
        const metaclass_class = try self.compile_portion_of_builtin_class___do_not_set_as_vm_object(.{
            .ast = metaclass_ast,
            .portion = metaclass_ast.class_ast.instance_portion,
            .class_name_symbol = SymbolsManager.comptime_id_of("Metaclass class"),
            .compiled_parent = class_class,
        });

        // Setup "is instance of" relationships through `as_vm_object`
        //    X is instance of X_class:
        try self.set_is_instance_of(object, object_class);
        try self.set_is_instance_of(class, class_class);
        try self.set_is_instance_of(metaclass, metaclass_class);
        //    X_class is instance of metaclass:
        try self.set_is_instance_of(object_class, metaclass);
        try self.set_is_instance_of(class_class, metaclass);
        try self.set_is_instance_of(metaclass_class, metaclass);

        // Assert that the classes do not have any fields
        try self.validate_class_has_no_fields(object);
        try self.validate_class_has_no_fields(object_class);
        try self.validate_class_has_no_fields(class);
        try self.validate_class_has_no_fields(class_class);
        try self.validate_class_has_no_fields(metaclass);
        try self.validate_class_has_no_fields(metaclass_class);

        // Put the classes into globals
        try self.globals.put(SymbolsManager.comptime_id_of("Object"), VmObject.from(object.as_vm_object));
        try self.globals.put(SymbolsManager.comptime_id_of("Class"), VmObject.from(class.as_vm_object));
        try self.globals.put(SymbolsManager.comptime_id_of("Metaclass"), VmObject.from(metaclass.as_vm_object));
        //
        try self.globals.put(SymbolsManager.comptime_id_of("Object class"), VmObject.from(object_class.as_vm_object));
        try self.globals.put(SymbolsManager.comptime_id_of("Class class"), VmObject.from(class_class.as_vm_object));
        try self.globals.put(SymbolsManager.comptime_id_of("Metaclass class"), VmObject.from(metaclass_class.as_vm_object));

        // Set our class definition fields
        self.metaclass_definition = metaclass;
        self.object_definition = object;

        // Return the loaded classes
        return BuiltinBaseHierarchy{
            .class_of_object = object,
            .class_of_class = class,
            .class_of_metaclass = metaclass,
        };
    }

    fn create_reporter(self: *Self) ErrorReporter {
        return ErrorReporter{
            .source = undefined,
            .source_path = null,
            .use_color = self.use_colored_printing,
            .writer = self.error_writer,
        };
    }

    fn set_is_instance_of(self: *Self, instance: *ClassDefinition, class_of_instance: *ClassDefinition) !void {
        const vm_object: VmObject = try types.Class.create_new(self.statics, .{
            .class_fields_count = @intCast(class_of_instance.identifiers_of_instance_variables.len),
            .represented_class = instance,
            .class_of_represented_class = class_of_instance,
        });
        const class_object: *types.Class = vm_object.as_heap_object(.class).?;
        instance.as_vm_object = class_object;
    }

    fn validate_class_has_no_fields(self: *Self, class: *ClassDefinition) !void {
        const fields = class.identifiers_of_instance_variables;
        const fields_count = fields.len;
        if (fields_count == 0) return;
        const FieldsPrinter = struct {
            fields: []SymbolId,
            symbols_manager: *SymbolsManager,
            pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                for (this.fields, 0..) |field_symbol, idx| {
                    const field_text: []const u8 = this.symbols_manager.symbol_with_id(field_symbol);
                    if (idx != 0) try writer.print(", ", .{});
                    try writer.print("'{s}'", .{field_text});
                }
            }
        };
        var reporter = ErrorReporter{ .source = undefined, .source_path = null, .use_color = self.use_colored_printing, .writer = self.error_writer };
        const class_name: []const u8 = self.statics.symbols_manager.symbol_with_id(class.class_name);
        const plurar_s: []const u8 = if (fields_count == 1) "" else "s";

        reporter.report_error(.no_location, "The class {s} has {d} field{s}: {f}. This class cannot have fields.", .{
            class_name,
            fields_count,
            plurar_s,
            (FieldsPrinter{ .fields = fields, .symbols_manager = &self.statics.symbols_manager }),
        });
        if (class.parent) |parent| if (parent.identifiers_of_instance_variables.len != 0) {
            const parent_fields = parent.identifiers_of_instance_variables;
            const parent_name = self.statics.symbols_manager.symbol_with_id(parent.class_name);
            reporter.add_note(.no_location, "The fields {f} are inherited from the parent class {s}.", .{
                (FieldsPrinter{ .fields = parent_fields, .symbols_manager = &self.statics.symbols_manager }),
                parent_name,
            });
        };

        return error.class_has_fields;
    }

    fn validate_parent_is_nil(self: *Self, ast: ParsedFile) !void {
        var reporter = ErrorReporter{
            .source = ast.source_code,
            .source_path = ast.source_code_filepath,
            .use_color = self.use_colored_printing,
            .writer = self.error_writer,
        };
        const class_name_text: []const u8 = ast.text_at(ast.class_ast.class_name);
        if (ast.class_ast.parent_class_name) |parent_name_token| {
            const parent_name_text: []const u8 = ast.text_at(parent_name_token);
            if (!std.mem.eql(u8, parent_name_text, "nil")) {
                reporter.report_error(.{ .pos = ast.pos_of(parent_name_token) }, "The parent of {s} is expected to be nil, but it is {s}.", .{ class_name_text, parent_name_text });
                return error.builtin_class_has_incorrect_parent;
            }
        }
        // The parent is unspecified, but in that case, it is implicitly `Object`, which is error.
        else {
            const error_pos = ast.pos_of( // TokenSpan describing the "NameOfClass = (" section in the source code
                Ast.TokenSpan.create(ast.class_ast.class_name.idx, ast.class_ast.class_name.idx + 2),
            );
            reporter.report_error(.{ .pos = ast.pos_of(error_pos) }, "The class {s} has no parent specified, therefore it is implicitly Object. But the class {s} is expected to have no parent.", .{ class_name_text, class_name_text });
            reporter.add_note(.no_location, "To say that class has no parent, explicitly specify that the class inherits from `nil`.", .{});
            return error.builtin_class_has_incorrect_parent;
        }
    }

    fn validate_parent_name_is(self: *Self, ast: ParsedFile, expected_parent_name: []const u8) !void {
        var reporter = ErrorReporter{
            .source = ast.source_code,
            .source_path = ast.source_code_filepath,
            .use_color = self.use_colored_printing,
            .writer = self.error_writer,
        };
        const class_name_text: []const u8 = ast.text_at(ast.class_ast.class_name);
        if (ast.class_ast.parent_class_name) |parent_name_token| {
            const parent_name_text: []const u8 = ast.text_at(parent_name_token);
            if (!std.mem.eql(u8, parent_name_text, expected_parent_name)) {
                reporter.report_error(.{ .pos = ast.pos_of(parent_name_token) }, "The parent of {s} is expected to be nil, but it is {s}.", .{ class_name_text, parent_name_text });
                return error.builtin_class_has_incorrect_parent;
            }
        } else if (!std.mem.eql(u8, expected_parent_name, "Object")) {
            const error_pos = ast.pos_of( // TokenSpan describing the "NameOfClass = (" section in the source code
                Ast.TokenSpan.create(ast.class_ast.class_name.idx, ast.class_ast.class_name.idx + 2),
            );
            reporter.report_error(.{ .pos = error_pos }, "The parent of {s} has no parent specified, therefore it is implicitly Object. But the parent of class {s} is expected to be {s}.", .{
                class_name_text,
                class_name_text,
                expected_parent_name,
            });
            return error.builtin_class_has_incorrect_parent;
        }
    }

    fn parse_file(self: *Self, class_name: SymbolId) !ParsedFile {
        return find_file_and_parse_it(
            class_name,
            self.source_code_files,
            self.statics,
            self.error_writer,
            self.temporary_arena.allocator(),
            self.use_colored_printing,
        );
    }

    fn compile_portion_of_builtin_class___do_not_set_as_vm_object(self: *Self, params: struct {
        ast: ParsedFile,
        portion: Ast.ClassAstPortion,
        class_name_symbol: SymbolId,
        compiled_parent: ?*ClassDefinition,
    }) !*ClassDefinition {
        var reporter = ErrorReporter{
            .source = params.ast.source_code,
            .source_path = params.ast.source_code_filepath,
            .use_color = self.use_colored_printing,
            .writer = self.error_writer,
        };

        return compile_portion(.{
            .ast = params.ast,
            .ast_portion = params.portion,
            .class_name_symbol = params.class_name_symbol,
            .compiled_parent = params.compiled_parent,
            .temporary_allocator = self.temporary_arena.allocator(),
            .statics = self.statics,
            .reporter = &reporter,
            .primitive_methods_map = self.primitive_methods_map,
        });
    }

    const Self = @This();
};

const ParsedFileToCompile = struct { name: SymbolId, ast: ParsedFile };

pub const CompileClassWithItsParentsParams = struct {
    bottom_class_name: SymbolId,
    statics: *Statics,
    temporary_allocator: Allocator,
    source_code_files: *SourceCodeFiles,
    error_writer: *std.io.Writer,
    primitive_methods_map: *const PrimitiveMethodsMap,
    /// Used for lookup of class definitions.
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
    metaclass_definition: *ClassDefinition,
    use_colored_printing: bool,
};

fn compile_class_with_its_parents(
    params: CompileClassWithItsParentsParams,
) !ClassDefinitionPair {
    const bottom_class_name = params.bottom_class_name;
    const statics = params.statics;
    const temporary_allocator = params.temporary_allocator;
    const source_code_files = params.source_code_files;
    const error_writer = params.error_writer;
    const primitive_methods_map = params.primitive_methods_map;
    const globals = params.globals;
    const metaclass_definition = params.metaclass_definition;

    var error_reporter = ErrorReporter{
        .source = undefined,
        .source_path = undefined,
        .use_color = params.use_colored_printing,
        .writer = error_writer,
    };

    const bottom_ast: ParsedFile = try find_file_and_parse_it(bottom_class_name, source_code_files, statics, error_writer, temporary_allocator, params.use_colored_printing);
    var maybe_parent_being_resolved: ?SymbolId = try symbol_of_parents_name(bottom_ast.class_ast.parent_class_name, &statics.symbols_manager, bottom_ast);

    // Parsed files to be compiled. This invariant should hold:
    //    (∀ idx in 1..len-1 ) ( classes_to_compile[idx] is_parent_of classes_to_compile[idx-1] )
    //
    // This means, we will have to compile them in the reverse order, so that the compiled version of the parent class
    // is available when we want to compile the child.
    //
    // The order of classes in this ArrayList is "reversed" like this, because we encounter and parse the classes in this order.
    //
    var classes_to_compile = try std.ArrayList(ParsedFileToCompile).initCapacity(temporary_allocator, 5);
    defer classes_to_compile.deinit(temporary_allocator);
    try classes_to_compile.append(temporary_allocator, ParsedFileToCompile{ .name = bottom_class_name, .ast = bottom_ast });

    const parent_of_last_class: ?*ClassDefinition = while (maybe_parent_being_resolved) |parent_being_resolved| {
        // Check if the name is in `classes_to_compile`
        for (classes_to_compile.items, 0..) |parsed_predecessor, idx| {
            if (parent_being_resolved != parsed_predecessor.name) continue;
            report_circular_dependency_error(&error_reporter, classes_to_compile.items[idx..]);
            return error.circular_dependency;
        }

        if (globals.get(parent_being_resolved)) |parent_definition| {
            if (parent_definition.as_heap_object(.class)) |class| {
                break class.represented_class;
            }
            report_parent_is_not_a_class(&error_reporter, classes_to_compile.getLast().ast, parent_definition, statics.symbols_manager);
            return error.parent_is_not_a_class;
        }
        const parent_ast: ParsedFile = try find_file_and_parse_it(parent_being_resolved, source_code_files, statics, error_writer, temporary_allocator, params.use_colored_printing);
        try classes_to_compile.append(temporary_allocator, ParsedFileToCompile{ .name = parent_being_resolved, .ast = parent_ast });
        maybe_parent_being_resolved = try symbol_of_parents_name(parent_ast.class_ast.parent_class_name, &statics.symbols_manager, parent_ast);
    } else null;

    try globals.ensureUnusedCapacity(classes_to_compile.items.len);
    try statics.all_classes.growCapacity(statics.allocator, statics.all_classes.len + classes_to_compile.items.len);

    // Compile the classes
    var current_parent: ?ClassDefinitionPair = blk: {
        const parent_definition = parent_of_last_class orelse break :blk null;
        const parent_metaclass = parent_definition.get_metaclass_through_vm_object();
        break :blk ClassDefinitionPair{ .class = parent_definition, .metaclass = parent_metaclass };
    };
    var iter = std.mem.reverseIterator(classes_to_compile.items);
    while (iter.nextPtr()) |class_to_compile| {
        error_reporter.source = class_to_compile.ast.source_code;
        error_reporter.source_path = class_to_compile.ast.source_code_filepath;
        const compiled_class: ClassDefinitionPair = try compile_class(
            class_to_compile.ast,
            class_to_compile.name,
            current_parent,
            temporary_allocator,
            statics,
            &error_reporter,
            primitive_methods_map,
            globals,
            metaclass_definition,
        );
        current_parent = compiled_class;
    }

    // The variable `current_parent` is now the class which would be the
    // parent of the next class to compile, if there was any.
    // Which means the last `current_parent` is a compiled version of the original class to be compiled.
    //
    assert(current_parent != null); // This should never fail since the loop will be executed at least once
    const compiled_root_class = current_parent.?;

    return compiled_root_class;
}

fn report_parent_is_not_a_class(reporter: *ErrorReporter, ast: ParsedFile, actual_value: VmObject, symbols: SymbolsManager) void {
    const Printer = struct {
        symbols: *const SymbolsManager,
        object: VmObject,
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.object.identify()) {
                .nil => try writer.print("a nil", .{}),
                .true => try writer.print("the true object", .{}),
                .false => try writer.print("the false object", .{}),
                .system => try writer.print("the system object", .{}),
                .integer => try writer.print("an integer", .{}),
                .symbol => try writer.print("a symbol", .{}),
                _ => try writer.print("a double", .{}),
                .heap_object => {
                    const header: *OpaqueHeader = self.object.as_asserted_ptr_to_heap();
                    switch (header.identify_heap_object()) {
                        .class => @panic("We should never get into this point"),
                        .generic_object => |generic_object| {
                            const class_name = self.symbols.symbol_with_id(generic_object.class.class_name);
                            try writer.print("an instance of {s}", .{class_name});
                        },
                        inline else => |_, tag| {
                            const tag_name = @tagName(tag);
                            if (std.mem.containsAtLeastScalar(u8, "aeio", 1, std.ascii.toLower(tag_name[0]))) {
                                try writer.print("an {t}", .{tag});
                            } else {
                                try writer.print("a {t}", .{tag});
                            }
                        },
                    }
                },
            }
        }
    };

    reporter.source = ast.source_code;
    reporter.source_path = ast.source_code_filepath;
    const parent_name: Ast.TokenId = ast.class_ast.parent_class_name.?;
    reporter.report_error(
        .{ .pos = ast.pos_of(parent_name) },
        "The specified parent '{s}' is a global that is not a class, it is {f}.",
        .{ ast.text_at(parent_name), (Printer{ .symbols = &symbols, .object = actual_value }) },
    );
}

fn report_circular_dependency_error(reporter: *ErrorReporter, cycle: []ParsedFileToCompile) void {
    assert(cycle.len != 0);
    if (cycle.len == 1) {
        const ast = &cycle[0].ast;
        const class_name: Ast.TokenId = ast.class_ast.class_name;
        const parent_name: Ast.TokenId = ast.class_ast.parent_class_name.?;
        const error_pos = ast.pos_of(Ast.TokenSpan.create(class_name.idx, parent_name.idx));
        reporter.source = ast.source_code;
        reporter.source_path = ast.source_code_filepath;
        reporter.report_error(.{ .pos = error_pos }, "Class {s} inherits from itself.", .{ast.text_at(class_name)});
        return;
    }

    const CyclePrinter = struct {
        cycle: []ParsedFileToCompile,
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (0..self.cycle.len + 1) |iteration_idx| {
                const file = &self.cycle[iteration_idx % self.cycle.len];
                if (iteration_idx != 0) try writer.print(" inherits ", .{});
                const class_name: []const u8 = file.ast.text_at(file.ast.class_ast.parent_class_name.?);
                try writer.print("{s}", .{class_name});
            }
        }
    };
    reporter.report_error(.no_location, "Detected circular inheritance of classes: {f}.", .{CyclePrinter{ .cycle = cycle }});
}

pub const ClassDefinitionPair = struct {
    class: *ClassDefinition,
    metaclass: *ClassDefinition,
};

pub fn compile_class(
    ast: ParsedFile,
    class_name_symbol: SymbolId,
    compiled_parent: ?ClassDefinitionPair,
    temporary_allocator: Allocator,
    statics: *Statics,
    reporter: *ErrorReporter,
    primitive_methods_map: *const PrimitiveMethodsMap,
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
    metaclass_definition: ?*ClassDefinition,
) !ClassDefinitionPair {
    // Concatenated name of the class with the string " class" (yes, with the space in front of it).
    const class_class_name_symbol: SymbolId = blk: {
        const class_name_string: []const u8 = statics.symbols_manager.symbol_with_id(class_name_symbol);
        const class_class_name: []const u8 = try std.fmt.allocPrint(temporary_allocator, "{s} class", .{class_name_string});
        break :blk ((try statics.symbols_manager.id_or_intern(class_class_name)).id);
    };

    // Compile the class portion
    const class_portion_definition: *ClassDefinition = blk: {
        const compiled_class = try compile_portion(.{
            .ast = ast,
            .ast_portion = ast.class_ast.class_portion,
            .class_name_symbol = class_class_name_symbol,
            .compiled_parent = if (compiled_parent) |p| p.metaclass else null,
            .temporary_allocator = temporary_allocator,
            .statics = statics,
            .reporter = reporter,
            .primitive_methods_map = primitive_methods_map,
        });
        // Create a new global object which represents the newly compiled class
        const class_as_som_object: VmObject = try types.Class.create_new(statics, .{
            .represented_class = compiled_class,
            .class_of_represented_class = metaclass_definition orelse undefined,
            .class_fields_count = if (metaclass_definition) |m| @intCast(m.identifiers_of_instance_variables.len) else 0,
        });
        try globals.put(compiled_class.class_name, class_as_som_object);
        break :blk compiled_class;
    };

    // Compile the instance portion
    const instance_portion_definition: *ClassDefinition = blk: {
        const compiled_class = try compile_portion(.{
            .ast = ast,
            .ast_portion = ast.class_ast.instance_portion,
            .class_name_symbol = class_name_symbol,
            .compiled_parent = if (compiled_parent) |p| p.class else null,
            .temporary_allocator = temporary_allocator,
            .statics = statics,
            .reporter = reporter,
            .primitive_methods_map = primitive_methods_map,
        });
        // Create a new global object which represents the newly compiled class
        const class_as_som_object: VmObject = try types.Class.create_new(statics, .{
            .represented_class = compiled_class,
            .class_of_represented_class = class_portion_definition,
            .class_fields_count = @intCast(class_portion_definition.identifiers_of_instance_variables.len),
        });
        try globals.put(compiled_class.class_name, class_as_som_object);
        break :blk compiled_class;
    };

    return .{
        .class = instance_portion_definition,
        .metaclass = class_portion_definition,
    };
}

pub const CompilePortionParams = struct {
    ast: ParsedFile,
    ast_portion: Ast.ClassAstPortion,
    class_name_symbol: SymbolId,
    compiled_parent: ?*ClassDefinition,
    temporary_allocator: Allocator,
    statics: *Statics,
    reporter: *ErrorReporter,
    primitive_methods_map: *const PrimitiveMethodsMap,
};

/// WARN: The returned class has the `ClassDefinition.as_vm_object` set to `undefined`!
pub fn compile_portion(params: CompilePortionParams) !*ClassDefinition {
    const ast = params.ast;
    const ast_portion = params.ast_portion;
    const class_name_symbol = params.class_name_symbol;
    const compiled_parent = params.compiled_parent;
    const temporary_allocator = params.temporary_allocator;
    const statics = params.statics;
    const reporter = params.reporter;
    const primitive_methods_map = params.primitive_methods_map;

    var bytecode_generator = BytecodeGenerator.init(.{
        .allocator = statics.allocator,
        .temporary_allocator = temporary_allocator,
        .symbols_manager = &statics.symbols_manager,
        .constants_manager = &statics.constants_manager,
        .reporter = reporter,
    });

    var lexical_scopes = try LexicalScopeStack.init(temporary_allocator, 0, 0);

    // Create a list of instance field identifiers and create a lexical scope out of them
    const parent_fields: []SymbolId = if (compiled_parent) |p| p.identifiers_of_instance_variables else &[_]SymbolId{};
    var field_identifiers: []SymbolId = blk: {
        const current_fields_count = if (ast_portion.fields) |f| f.number_of_tokens() else 0;
        break :blk try statics.allocator.alloc(SymbolId, current_fields_count + parent_fields.len);
    };
    {
        var field_idx: u32 = 0;

        // Deal with the fields of the parent
        @memcpy(field_identifiers[0..parent_fields.len], parent_fields);
        //
        var parent_fields_scope = try lexical_scopes.add_scope(.{ .increase_depth = false });
        for (parent_fields) |parent_field| {
            try parent_fields_scope.register_variable(.{ .identifier = parent_field, .idx = field_idx });
            field_idx += 1;
        }
        assert(field_idx == parent_fields.len);

        // Deal with the current fields
        var current_fields_scope = try lexical_scopes.add_scope(.{ .increase_depth = false });
        var iter = token_iterator(ast_portion.fields);
        while (iter.next()) |field_token| : (field_idx += 1) {
            const field_text = ast.text_at(field_token);
            const field_symbol: SymbolId = (try statics.symbols_manager.id_or_intern(field_text)).id;
            try current_fields_scope.register_variable(.{ .identifier = field_symbol, .idx = field_idx });
            field_identifiers[field_idx] = field_symbol;
        }
        assert(field_idx == field_identifiers.len);
    }
    defer lexical_scopes.pop_scope(); // Pop `current_fields_scope`
    defer lexical_scopes.pop_scope(); // Pop `parent_fields_scope`

    // Add the class to the list of all classes
    const compiled_class: *ClassDefinition = blk: {
        const ptr = try statics.all_classes.addOne(statics.allocator);
        ptr.* = ClassDefinition{
            .class_name = class_name_symbol,
            .instance_methods = undefined,
            .as_vm_object = undefined,
            .identifiers_of_instance_variables = field_identifiers,
            .parent = compiled_parent,
        };
        break :blk ptr;
    };

    const all_methods_len = ast_portion.methods.len + (if (compiled_parent) |p| p.instance_methods.items.len else 0);
    var compiled_methods: []*const MethodDefinition = try temporary_allocator.alloc(*const MethodDefinition, all_methods_len);
    defer temporary_allocator.free(compiled_methods);

    const maybe_primitive_class = primitive_methods_map.sorted_classes.get_ptr(class_name_symbol);

    var method_idx: usize = 0;
    for (ast_portion.methods) |method_ast| {
        const method_selector: SymbolId = try get_selector_symbol(.{
            .method_header = &method_ast.header,
            .ast = &ast,
            .statics = statics,
            .temporary_allocator = temporary_allocator,
        });

        switch (method_ast.body) {
            .primitive => {
                const primitive_class = maybe_primitive_class orelse {
                    const class_name = ast.text_at(ast.class_ast.class_name);
                    const method_selector_text = statics.symbols_manager.symbol_with_id(method_selector);
                    reporter.report_warning(
                        .{ .pos = ast.pos_of(method_ast.span) },
                        "The class '{s}' has the method '{s}' declared as `primitive`, but the class '{s}' is not primitive at all (has no primitive methods).",
                        .{ class_name, method_selector_text, class_name },
                    );
                    reporter.add_note(
                        .no_location,
                        "The method '{s}' will not be compiled into the class.",
                        .{method_selector_text},
                    );
                    continue;
                };
                const primitive_method = primitive_class.get_method(method_selector) orelse {
                    const class_name = ast.text_at(ast.class_ast.class_name);
                    const method_selector_text = statics.symbols_manager.symbol_with_id(method_selector);
                    reporter.report_warning(
                        .{ .pos = ast.pos_of(method_ast.span) },
                        "The class '{s}' has the method '{s}' declared as `primitive`, but the virtual machine does not have such primitive method implementation.",
                        .{ class_name, method_selector_text },
                    );
                    reporter.add_note(
                        .no_location,
                        "The method '{s}' will not be compiled into the class.",
                        .{method_selector_text},
                    );
                    continue;
                };

                const new_method_ptr: *MethodDefinition = try statics.all_methods.addOne(statics.allocator);
                new_method_ptr.* = MethodDefinition{
                    .selector = method_selector,
                    .number_of_aditional_args = primitive_method.args_cnt - 1,
                    .body = MethodBody{ .primitive = primitive_method.function },
                    .source_class = compiled_class,
                    .as_vm_object = undefined,
                    .definition_order_index = @intCast(method_idx),
                };
                _ = try types.Method.create_new(statics, new_method_ptr);
                compiled_methods[method_idx] = new_method_ptr;
                method_idx += 1;
            },
            .impl => |function_body| {
                const bytecode: Bytecode = try bytecode_generator.compile_method(.{
                    .ast = &ast,
                    .scope_stack = &lexical_scopes,
                    .compiled_parent_methods = if (compiled_parent) |p| &p.instance_methods else null,
                    .method_span = method_ast.span,
                    .body = function_body,
                    .method_header = method_ast.header,
                });
                const number_of_locals = function_body.number_of_locals();
                if (number_of_locals > std.math.maxInt(u16)) {
                    reporter.report_error(.{ .pos = ast.pos_of(function_body.locals.?) }, "Too many locals. Found {d} locals, maximum is {d}.", .{ number_of_locals, std.math.maxInt(u16) });
                    return error.too_many_locals;
                }
                const number_of_aditional_args = method_ast.header.number_of_arguments_including_self() - 1;
                if (number_of_aditional_args > std.math.maxInt(u16)) {
                    reporter.report_error(.{ .pos = ast.pos_of(method_ast.header.span()) }, "Too many arguments. Found {d} arguments, maximum is {d}.", .{ number_of_aditional_args, std.math.maxInt(u16) });
                    return error.too_many_arguments;
                }
                const new_method_ptr: *MethodDefinition = try statics.all_methods.addOne(statics.allocator);
                new_method_ptr.* = MethodDefinition{
                    .selector = method_selector,
                    .number_of_aditional_args = @truncate(number_of_aditional_args),
                    .body = MethodBody{ .user_land = .{
                        .bytecode = bytecode,
                        .number_of_locals = @truncate(number_of_locals),
                    } },
                    .source_class = compiled_class,
                    .as_vm_object = undefined,
                    .definition_order_index = @intCast(method_idx),
                };
                _ = try types.Method.create_new(statics, new_method_ptr);
                compiled_methods[method_idx] = new_method_ptr;
                method_idx += 1;
            },
        }
    }
    const number_of_invalid_methods = compiled_methods.len - method_idx;
    compiled_methods.len -= number_of_invalid_methods;

    const only_instance_methods: ClassDefinition.MethodMap = sw: switch (ClassDefinition.MethodMap.from_slice(compiled_methods[0..method_idx])) {
        .ok => |new_instance| break :sw new_instance,
        .duplicate => |duplicate_method_selector| {

            // For a nice error message, we have to go through the AST again and find the positions of duplicate methods.
            const class_name = ast.text_at(ast.class_ast.class_name);
            const duplicate_selector_text: []const u8 = statics.symbols_manager.symbol_with_id(duplicate_method_selector);
            var first_encounter = true;
            for (ast_portion.methods) |method_ast| {
                const selector = try get_selector_symbol(.{
                    .method_header = &method_ast.header,
                    .ast = &ast,
                    .statics = statics,
                    .temporary_allocator = temporary_allocator,
                });
                if (selector != duplicate_method_selector) continue;
                if (first_encounter) {
                    first_encounter = false;
                    reporter.report_error(
                        .{ .pos = ast.pos_of(method_ast.header.span()) },
                        "The class '{s}' contains a duplicate definition of the '{s}' method.",
                        .{ class_name, duplicate_selector_text },
                    );
                } else {
                    reporter.add_note(
                        .{ .pos = ast.pos_of(method_ast.header.span()) },
                        "The method with the same selector '{s}' is also defined here.",
                        .{duplicate_selector_text},
                    );
                }
            }
            assert(first_encounter == false);
            return error.duplicate_method_definition;
        },
    };

    compiled_class.instance_methods = blk: {
        const parents_methods: ClassDefinition.MethodMap = if (compiled_parent) |parent_class|
            parent_class.instance_methods
        else
            .{ .items = &[0]*const MethodDefinition{} };
        const combined_methods = try ClassDefinition.MethodMap.from_merge_of(
            only_instance_methods,
            parents_methods,
            statics.allocator,
        );
        break :blk combined_methods;
    };

    return compiled_class;
}

pub fn get_selector_symbol(params: struct {
    method_header: *const Ast.MethodHeader,
    ast: *const ParsedFile,
    statics: *Statics,
    temporary_allocator: std.mem.Allocator,
}) !SymbolId {
    const method_selector_text: []const u8 = sw: switch (params.method_header.*) {
        .unary => |header_info| params.ast.text_at(header_info.selector),
        .binary => |header_info| params.ast.text_at(header_info.selector),
        .keyword => |header_info| {
            var selector = std.io.Writer.Allocating.init(params.temporary_allocator);
            var kw_idx: u32 = 0;
            while (kw_idx < header_info.number_of_args_excluding_self()) : (kw_idx += 1) {
                const keyword_token = header_info.nth_keyword(kw_idx);
                const keyword_text = params.ast.text_at(keyword_token);
                try selector.writer.print("{s}", .{keyword_text});
            }
            break :sw selector.written();
        },
    };

    const method_selector_symbol = (try params.statics.symbols_manager.id_or_intern(method_selector_text)).id;
    return method_selector_symbol;
}
