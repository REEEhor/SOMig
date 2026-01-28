const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;
const dbg_assert_eql = debug_module.dbg_assert_eql;
const dbg_assert_eql_msg = debug_module.dbg_assert_eql_msg;

const SmallPtr = @import("../interpreter/small_ptr.zig").SmallPtr;

const interning_module = @import("../interning/__interning.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = interning_module.SymbolArrayMap;

const lexer_module = @import("../frontend/lexer.zig");
const TokenizedFile = lexer_module.TokenizedFile;
const parser_module = @import("../frontend/parser.zig");

const interpreter_module = @import("../interpreter/__interpreter.zig");
const VmObject = interpreter_module.VmObject;
const ClassDefinition = interpreter_module.ClassDefinition;
const PrimitiveMethodsMap = interpreter_module.PrimitiveMethodsMap;
const MethodDefinition = interpreter_module.MethodDefinition;
const MethodBody = interpreter_module.MethodBody;
const HeapData = interpreter_module.HeapData;
const primitives = interpreter_module.primitives;
const accessors = interpreter_module.accessors;
const Statics = interpreter_module.Statics;

const token_module = @import("token.zig");
const IntegerRepresentation = token_module.IntegerRepresentation;
const FloatRepresentation = token_module.FloatRepresentation;

const Ast = @import("ast.zig");
const token_iterator = Ast.TokenSpan.iterator;
const ParsedFile = Ast.ParsedFile;

const reporter_module = @import("reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;

/// A unique identifier of a constant in the constants pool.
pub const ConstantId = struct {
    idx: u32,

    pub fn to_relative(self: @This(), base_id: ConstantId) RelativeConstantId {
        assert(self.idx >= base_id.idx);
        const diff: @FieldType(RelativeConstantId, "idx") = @truncate(self.idx - base_id.idx);
        return RelativeConstantId{ .idx = diff };
    }
};

///
/// A unique identifier of a constant in the constants pool *for a given class*.
/// Each class has a `base_id` which is a `ConstantId` of the first constant in the constants pool.
///
/// The instructions themselves store `RelativeConstantId` which is just an offset from the `base_id`.
/// This enables the `load_constant` instruction to be smaller, which is nice for performance reasons.
///
pub const RelativeConstantId = struct {
    idx: u16,

    pub fn to_absolute(self: @This(), base_id: ConstantId) ConstantId {
        return ConstantId{ .idx = base_id.idx + @as(u32, self.idx) };
    }
};

pub const Constant = union(enum) {
    integer: IntegerRepresentation,
    float: FloatRepresentation,
    string: []const u8,
    nil,
};

pub const ConstantsManager = struct {
    const Self = @This();

    constants: std.MultiArrayList(Constant),
    allocator: Allocator,
    current_base_id: ConstantId,

    /// TODO(speed): make a `init_with_capacity` version or call `ensureCapacity` on `self.constants` for initial capacity
    pub fn init(allocator: Allocator) ConstantsManager {
        return ConstantsManager{
            .allocator = allocator,
            .constants = .empty,
            .current_base_id = ConstantId{ .idx = 0 },
        };
    }

    pub fn next_constant_id(self: Self) ConstantId {
        return ConstantId{ .idx = @truncate(self.constants.len) };
    }

    pub fn new_base_id_for_method(self: *Self) ConstantId {
        self.current_base_id = self.next_constant_id();
        return self.current_base_id;
    }

    pub fn add_constant(self: *Self, new_constant: Constant) Allocator.Error!RelativeConstantId {
        const new_constant_id = self.next_constant_id();
        try self.constants.append(self.allocator, new_constant);
        const relative_id = new_constant_id.to_relative(self.current_base_id);

        return relative_id;
    }

    pub fn get_constant(self: *Self, id: ConstantId) Constant {
        assert(id.idx < self.constants.len);
        return self.constants.get(id.idx);
    }

    pub fn deinit(self: *Self) void {
        self.constants.deinit(self.allocator);
    }
};

pub const LexicalScopesStack = struct {
    allocator: Allocator,
    all_variables: std.ArrayList(Variable),
    scopes: std.ArrayList(LexicalScope),

    const LexicalScope = struct {
        start_idx: usize,
        end_idx: usize,
        depth: u32,

        pub fn init_empty(params: struct { start_idx: usize, depth: u32 }) LexicalScope {
            return LexicalScope{
                .start_idx = params.start_idx,
                .end_idx = params.start_idx,
                .depth = params.depth,
            };
        }
    };

    pub fn init(
        allocator: Allocator,
        initial_capacity_for_scopes: usize,
        initial_capacity_for_variabels: usize,
    ) Allocator.Error!Self {
        return Self{
            .allocator = allocator,
            .all_variables = try .initCapacity(allocator, initial_capacity_for_variabels),
            .scopes = try .initCapacity(allocator, initial_capacity_for_scopes),
        };
    }

    fn current_depth(self: Self) u32 {
        if (self.scopes.getLastOrNull()) |last_scope| {
            return last_scope.depth;
        }
        return 0;
    }

    pub fn add_scope(self: *Self, params: struct { increase_depth: bool }) Allocator.Error!LexicalScopeHandle {
        try self.scopes.append(self.allocator, LexicalScope.init_empty(.{
            .start_idx = self.all_variables.items.len,
            .depth = self.current_depth() + @intFromBool(params.increase_depth),
        }));
        return LexicalScopeHandle{ .stack = self, .length_check = self.all_variables.items.len };
    }
    /// WARN: Asserts that the lexical scope stack is not empty
    pub fn pop_scope(self: *Self) void {
        assert(self.scopes.items.len != 0);
        const new_length = (self.scopes.pop() orelse unreachable).start_idx;
        self.all_variables.shrinkRetainingCapacity(new_length);
    }

    pub fn lookup_variable(self: Self, identifier: SymbolId) VariableLookup {
        const starting_depth = self.current_depth();
        var iter = std.mem.reverseIterator(self.scopes.items);
        while (iter.next()) |current_scope| {
            for (self.all_variables.items[current_scope.start_idx..current_scope.end_idx]) |variable| {
                if (variable.identifier.idx != identifier.idx) continue;
                if (current_scope.depth == 0) {
                    return .{ .instance = .{ .instance_variable_id = .{ .idx = variable.idx } } };
                }
                const scope_depth_difference = starting_depth - current_scope.depth;
                return .{ .local_or_method_argument = .{
                    .local_variable_id = .{ .idx = variable.idx },
                    .scope_depth_difference = scope_depth_difference,
                } };
            }
        }
        return VariableLookup.global;
    }

    const Self = @This();

    pub const VariableLookup = union(enum) {
        instance: struct {
            instance_variable_id: Instruction.InstanceVarId,
        },
        local_or_method_argument: struct {
            local_variable_id: Instruction.LocalVarId,
            scope_depth_difference: u32,
        },
        global,
    };

    pub const Variable = struct { identifier: SymbolId, idx: u32 };

    pub const LexicalScopeHandle = struct {
        stack: *LexicalScopesStack,
        length_check: usize,

        pub fn register_variable(
            self: *@This(),
            variable: Variable,
        ) Allocator.Error!void {
            const stack = self.stack;
            try stack.all_variables.append(stack.allocator, variable);
            stack.scopes.items[stack.scopes.items.len - 1].end_idx += 1;
            self.length_check += 1;
            // If this failed, we tried to register a variable
            // via a `LexicalScopeHandle` which doesn't represent the current top of the stack.
            assert(self.length_check == stack.all_variables.items.len);
        }
    };
};

pub const SourceCodeFiles = struct {
    cached_source_files: std.AutoArrayHashMapUnmanaged(SymbolId, []const u8),

    const Self = @This();
    pub const Map = std.AutoArrayHashMapUnmanaged(SymbolId, []const u8);

    pub const LookupError = error{some_file_error};
    pub fn get_source_code_of(self: Self, class_name: SymbolId) LookupError!?[]const u8 {
        const source = self.cached_source_files.get(class_name) orelse {
            // TODO: try to look in the file system
            return null;
        };
        return source;
    }
};

pub fn allocate_heap_data(allocator: Allocator, header: HeapData.Header) Allocator.Error!*HeapData {
    const bytes_needed = @sizeOf(HeapData.Header) + header.bytes_needed_after_header();
    const alignment = comptime std.mem.Alignment.fromByteUnits(@alignOf(HeapData));

    const bytes_ptr = try allocator.alignedAlloc(u8, alignment, bytes_needed);
    const ptr: *HeapData = @ptrCast(bytes_ptr);

    ptr.header = header;
    return ptr;
}

/// TODO: do this in a better way where we don't leak the methods by compiling the classes in portions
pub fn set_parent_and_leak_original_methods(
    class: *ClassDefinition,
    new_parent: *ClassDefinition,
    statics: *Statics,
) Allocator.Error!void {
    // NOTE:
    // We have to assert that the class had no parent before,
    // since the `class` could have contained methods from its original parent.
    //
    // At the time of implementing this method, there is no way to know which methods are inherited
    // and which are defined in the class.
    //
    // If that changes in the future, we can reimplment this method to also accomodate
    // for classes with existing parents via filtering the inherited methods out.
    //
    // For now, we assert that there was no parent.
    assert(class.parent == null);

    // The methods for this class are already compiled.
    // The `load_instance_var` instruction are already set.
    // These instructions rely on the number of fields
    // staying the same.
    assert(class.fields_count_including_parents() == 0);

    const new_methods = try ClassDefinition.MethodMap.from_merge_of(
        class.instance_methods,
        new_parent.instance_methods,
        statics.allocator,
    );
    class.instance_methods = new_methods;
    class.parent = new_parent;

    // TODO: once we re-work the implementation of how the instance variables are stored, we have to update that here
}

pub fn find_file_and_parse_it(
    class_name: SymbolId,
    source_code_files: *SourceCodeFiles,
    statics: *Statics,
    error_writer: *std.io.Writer,
    parse_allocator: Allocator,
) !ParsedFile {
    var reporter = ErrorReporter{
        .source = undefined, // TODO(HACK)
        .source_path = statics.symbols_manager.symbol_with_id(class_name), // TODO: get the actual path to the source code
        .use_color = true,
        .writer = error_writer,
    };
    const source_code = (try source_code_files.get_source_code_of(class_name)) orelse {
        const class_name_str = statics.symbols_manager.symbol_with_id(class_name);
        reporter.report_error(.no_location, "Could not find the source code for the class: {s}", .{class_name_str});
        return error.sourcecode_for_class_not_found;
    };
    reporter.source = source_code;

    const tokenized_file = try lexer_module.tokenize(parse_allocator, source_code, &reporter);
    var parser = parser_module.Parser.create(tokenized_file, &reporter, parse_allocator);
    const parsed_file = try parser.parse();

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
pub const CompileClassIgnoringParents = struct {
    class_name: SymbolId,
    statics: *Statics,
    temporary_allocator: Allocator,
    source_code_files: *SourceCodeFiles,
    error_writer: *std.io.Writer,
    primitive_methods_map: PrimitiveMethodsMap,
    /// Used for lookup of class definitions.
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
};

/// Sets the parent to null.
/// The metaclass has the VM object set to undefined.
pub fn compile_class_ignoring_parents(
    params: CompileClassIgnoringParents,
) !ClassDefinitionPair {
    const class_name = params.class_name;
    const statics = params.statics;
    const temporary_allocator = params.temporary_allocator;
    const source_code_files = params.source_code_files;
    const error_writer = params.error_writer;
    const primitive_methods_map = params.primitive_methods_map;
    const globals = params.globals;

    const ast = try find_file_and_parse_it(class_name, source_code_files, statics, error_writer, temporary_allocator);
    var reporter = ErrorReporter{
        .source = ast.source_code,
        // TODO: use actual filepath
        .source_path = statics.symbols_manager.symbol_with_id(class_name),
        .use_color = true,
        .writer = error_writer,
    };
    const class_pair = try compile_class(ast, class_name, null, temporary_allocator, statics, &reporter, primitive_methods_map, globals);
    return class_pair;
}

pub const CompileClassWithItsParentsParams = struct {
    bottom_class_name: SymbolId,
    statics: *Statics,
    temporary_allocator: Allocator,
    source_code_files: *SourceCodeFiles,
    error_writer: *std.io.Writer,
    primitive_methods_map: PrimitiveMethodsMap,
    /// Used for lookup of class definitions.
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
};

/// The metaclass has the VM object set to undefined.
pub fn compile_class_with_its_parents(
    params: CompileClassWithItsParentsParams,
) !ClassDefinitionPair {
    const bottom_class_name = params.bottom_class_name;
    const statics = params.statics;
    const temporary_allocator = params.temporary_allocator;
    const source_code_files = params.source_code_files;
    const error_writer = params.error_writer;
    const primitive_methods_map = params.primitive_methods_map;
    const globals = params.globals;

    // This method is expected to be called only when we cannot resolve a global symbol (presumably a class name)
    assert(!globals.contains(bottom_class_name));

    // TODO(cleanup): re-write this using a single while loop (actually a do-while would be better), it should be possible

    const bottom_ast: ParsedFile = try find_file_and_parse_it(bottom_class_name, source_code_files, statics, error_writer, temporary_allocator);
    var maybe_parent_being_resolved: ?SymbolId = try symbol_of_parents_name(bottom_ast.class_ast.super_class_name, &statics.symbols_manager, bottom_ast);

    // Parsed files to be compiled. This invariant should hold:
    //    (∀ idx in 1..len-1 ) ( classes_to_compile[idx] is_parent_of classes_to_compile[idx-1] )
    //
    // This means, we will have to compile them in the reverse order, so that the compiled version of the parent class
    // is available when we want to compile the child.
    //
    // The order of classes in this ArrayList is "reversed" like this, because we encounter and parse the classes in this order.
    //
    const ParsedFileToCompile = struct { name: SymbolId, ast: ParsedFile };
    var classes_to_compile = try std.ArrayList(ParsedFileToCompile).initCapacity(temporary_allocator, 5);
    defer classes_to_compile.deinit(temporary_allocator);
    try classes_to_compile.append(temporary_allocator, ParsedFileToCompile{ .name = bottom_class_name, .ast = bottom_ast });

    const parent_of_last_class: ?*ClassDefinition = while (maybe_parent_being_resolved) |parent_being_resolved| {

        // Check if the name is in `classes_to_compile`
        for (classes_to_compile.items) |parsed_predecessor| {
            if (parent_being_resolved.idx != parsed_predecessor.name.idx) continue;
            return error.circular_dependency; // TODO: nice error report that lists out the loop in the hiearchy
        }

        // TODO(consultation): Can we look-up the globals like this here? I think it makes sense.
        if (globals.get(parent_being_resolved)) |parent_definition| {
            break switch (parent_definition.data.kind()) {
                .class => |accessor| accessor.get_represented_class(parent_definition.data),
                else => return error.parent_is_not_a_class,
            };
        }
        const parent_ast: ParsedFile = try find_file_and_parse_it(parent_being_resolved, source_code_files, statics, error_writer, temporary_allocator);
        try classes_to_compile.append(temporary_allocator, ParsedFileToCompile{ .name = parent_being_resolved, .ast = parent_ast });
        maybe_parent_being_resolved = try symbol_of_parents_name(parent_ast.class_ast.super_class_name, &statics.symbols_manager, parent_ast);
    } else null;

    try globals.ensureUnusedCapacity(classes_to_compile.items.len);
    try statics.all_classes.growCapacity(statics.allocator, statics.all_classes.len + classes_to_compile.items.len);

    // Compile the classes
    var current_parent: ?ClassDefinitionPair = blk: {
        const parent_definition = parent_of_last_class orelse break :blk null;
        const parent_metaclass = (accessors.ClassAccessor{}).get_class_of_represented_class(parent_definition.as_vm_object.data);
        break :blk ClassDefinitionPair{ .class = parent_definition, .metaclass = parent_metaclass };
    };
    var iter = std.mem.reverseIterator(classes_to_compile.items);
    while (iter.nextPtr()) |class_to_compile| {
        var reporter = ErrorReporter{
            .source = class_to_compile.ast.source_code,
            // TODO: add an actual filepath here
            .source_path = statics.symbols_manager.symbol_with_id(class_to_compile.name),
            .use_color = true,
            .writer = error_writer,
        };
        const compiled_class: ClassDefinitionPair = try compile_class(
            class_to_compile.ast,
            class_to_compile.name,
            current_parent,
            temporary_allocator,
            statics,
            &reporter,
            primitive_methods_map,
            globals,
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
    primitive_methods_map: PrimitiveMethodsMap,
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
) !ClassDefinitionPair {
    // Concatenated name of the class with the string " class" (yes, with the space in front of it).
    const class_class_name_symbol: SymbolId = blk: {
        const class_name_string: []const u8 = statics.symbols_manager.symbol_with_id(class_name_symbol);
        const class_class_name: []const u8 = try std.fmt.allocPrint(temporary_allocator, "{s} class", .{class_name_string});
        break :blk ((try statics.symbols_manager.id_or_intern(class_class_name)).id);
    };
    const class_accessor = accessors.ClassAccessor{};

    // Compile the class portion
    const class_portion_definition: *ClassDefinition = blk: {
        var compiled_class = try compile_portion(.{
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
        var header = HeapData.Header.new_undefined_with_tag(.class);
        class_accessor.set_class_variables_count(header.as_heap_data(), @intCast(compiled_class.fields_count_including_parents()));
        const heap_data: *HeapData = try statics.allocate_for_static_object(header);
        class_accessor.set_represented_class(heap_data, compiled_class);
        class_accessor.set_class_of_represented_class(heap_data, undefined); // TODO: set to `Metaclass` here probably ?
        const class_as_som_object: VmObject = heap_data.as_vm_object();
        compiled_class.as_vm_object = class_as_som_object;
        // Someone might have tried to create a global variable with the name of the class of the represented class.
        // (for example it is concievable that someone could have created a global with the name "Integer class")
        // Therefore we do not assert, that the global does not exist already.
        try globals.put(compiled_class.class_name, class_as_som_object);

        break :blk compiled_class;
    };

    // Compile the instance portion
    const instance_portion_definition: *ClassDefinition = blk: {
        var compiled_class = try compile_portion(.{
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
        var header = HeapData.Header.new_undefined_with_tag(.class);
        class_accessor.set_class_variables_count(header.as_heap_data(), @intCast(compiled_class.fields_count_including_parents()));
        const heap_data: *HeapData = try statics.allocate_for_static_object(header);
        class_accessor.set_represented_class(heap_data, compiled_class);
        class_accessor.set_class_of_represented_class(heap_data, class_portion_definition);
        const class_as_som_object: VmObject = heap_data.as_vm_object();
        compiled_class.as_vm_object = class_as_som_object;

        // We assert that there was no such global before.
        // This should hold, otherwise we would have looked up the
        // class previously when we were figuring out the class hiearchy above.
        try globals.putNoClobber(compiled_class.class_name, class_as_som_object);

        compiled_class.as_vm_object = class_as_som_object;

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
    primitive_methods_map: PrimitiveMethodsMap,
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
        .symbols_manager = &statics.symbols_manager,
        .constants_manager = &statics.constants_manager,
        .reporter = reporter,
    });

    // TODO: after development, increase these numbers
    var lexical_scopes = try LexicalScopesStack.init(temporary_allocator, 0, 0);

    // Create a list of fields and create a lexical scope out of them
    var field_identifiers = try statics.allocator.alloc(
        SymbolId,
        if (ast_portion.fields) |f| f.number_of_tokens() else 0,
    );
    {
        const parent_fields_count: u32 = if (compiled_parent) |p| @intCast(p.identifiers_of_instance_variables.len) else 0;
        var lexical_scope = try lexical_scopes.add_scope(.{ .increase_depth = false });
        var iter = token_iterator(ast_portion.fields);
        var idx: u32 = 0;
        while (iter.next()) |field_token| : (idx += 1) {
            const field_text = ast.text_at(field_token);
            const field_symbol: SymbolId = (try statics.symbols_manager.id_or_intern(field_text)).id;
            field_identifiers[idx] = field_symbol;

            // The fields are stored right after all the parent's fields
            const field_idx = idx + parent_fields_count;
            try lexical_scope.register_variable(.{ .identifier = field_symbol, .idx = field_idx });
        }
        assert(idx == field_identifiers.len);
    }
    defer lexical_scopes.pop_scope();

    const all_methods_len = ast_portion.methods.len + (if (compiled_parent) |p| p.instance_methods.items.len else 0);
    var compiled_methods: []MethodDefinition = try temporary_allocator.alloc(MethodDefinition, all_methods_len);
    defer temporary_allocator.free(compiled_methods);

    const maybe_primitive_class = primitive_methods_map.sorted_classes.get_ptr(class_name_symbol);

    // TODO: consider putting this into the `SymbolsManager`?
    var buffer_for_selectors: [512]u8 = undefined;
    var selector_writer = std.io.Writer.fixed(&buffer_for_selectors);

    var method_idx: usize = 0;
    for (ast_portion.methods) |method_ast| {
        const method_selector: SymbolId = try get_selector_symbol(method_ast.header, &selector_writer, ast, statics, reporter);

        // TODO: if we ever want to mark methods if they are inherited or defined in the class, we can mark them as such here :D
        switch (method_ast.body) {
            .primitive => {
                const primitive_class = maybe_primitive_class orelse {
                    // TODO: add `report_warning` to the reporter
                    const class_name = ast.text_at(ast.class_ast.class_name);
                    const method_selector_text = statics.symbols_manager.symbol_with_id(method_selector);
                    reporter.report_error(
                        .{ .pos = ast.pos_of(method_ast.span) },
                        "The class '{s}' has the method '{s}' declared as `primitive`, but the class '{s}' is not primitive at all.",
                        .{ class_name, method_selector_text, class_name },
                    );
                    reporter.add_note(
                        .{ .pos = ast.pos_of(method_ast.header.span()) },
                        "The method '{s}' will not be compiled into the class.",
                        .{method_selector_text},
                    );
                    continue;
                };
                const primitive_method = primitive_class.get_method(method_selector) orelse {
                    // TODO: add `report_warning` to the reporter
                    const class_name = ast.text_at(ast.class_ast.class_name);
                    const method_selector_text = statics.symbols_manager.symbol_with_id(method_selector);
                    reporter.report_error(
                        .{ .pos = ast.pos_of(method_ast.span) },
                        "The class '{s}' has the method '{s}' declared as `primitive`, but the virtual machine does not have such primitive method implementation.",
                        .{ class_name, method_selector_text },
                    );
                    reporter.add_note(
                        .{ .pos = ast.pos_of(method_ast.header.span()) },
                        "The method '{s}' will not be compiled into the class.",
                        .{method_selector_text},
                    );
                    // TODO: print available methods on such class
                    continue;
                };

                compiled_methods[method_idx] = MethodDefinition{
                    .method_name = method_selector,
                    .number_of_aditional_args = primitive_method.args_cnt - 1,
                    .body = MethodBody{ .primitive = primitive_method.function },
                };
                method_idx += 1;
            },
            .impl => |function_body| {
                const method_constants_base_id: ConstantId = statics.constants_manager.new_base_id_for_method();
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
                compiled_methods[method_idx] = MethodDefinition{
                    .method_name = method_selector,
                    .number_of_aditional_args = @truncate(number_of_aditional_args),
                    .body = MethodBody{ .user_land = .{
                        .bytecode = bytecode,
                        .number_of_locals = @truncate(number_of_locals),
                        .constants_base_id = method_constants_base_id,
                    } },
                };
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
                selector_writer.end = 0;
                const selector = get_selector_symbol(method_ast.header, &selector_writer, ast, statics, reporter) catch unreachable;
                if (selector.idx == duplicate_method_selector.idx) {
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
            }
            assert(first_encounter == false);
            return error.duplicate_method_definition;
        },
    };

    const instance_methods = blk: {
        const parents_methods: ClassDefinition.MethodMap = if (compiled_parent) |parent_class|
            parent_class.instance_methods
        else
            .{ .items = &[0]MethodDefinition{} };
        const combined_methods = try ClassDefinition.MethodMap.from_merge_of(
            only_instance_methods,
            parents_methods,
            statics.allocator,
        );
        break :blk combined_methods;
    };

    // Add the class to the list of all classes
    const compiled_class: *ClassDefinition = blk: {
        const ptr = try statics.all_classes.addOne(statics.allocator);
        ptr.* = ClassDefinition{
            .class_name = class_name_symbol,
            .instance_methods = instance_methods,
            .as_vm_object = undefined,
            .identifiers_of_instance_variables = field_identifiers,
            .parent = compiled_parent,
        };
        break :blk ptr;
    };

    return compiled_class;
}

pub fn get_selector_symbol(
    method_header: Ast.MethodHeader,
    fixed_writer: *std.io.Writer,
    ast: ParsedFile,
    statics: *Statics,
    reporter: *ErrorReporter,
) !SymbolId {
    const method_selector_text: []const u8 = sw: switch (method_header) {
        .unary => |header_info| {
            break :sw ast.text_at(header_info.method_name);
        },
        .binary => |header_info| {
            break :sw ast.text_at(header_info.method_name);
        },
        .keyword => |header_info| {
            fixed_writer.end = 0;
            var kw_idx: u32 = 0;
            while (kw_idx < header_info.number_of_args_excluding_self()) : (kw_idx += 1) {
                const keyword_token = header_info.nth_keyword(kw_idx);
                const keyword_text = ast.text_at(keyword_token);
                _ = fixed_writer.write(keyword_text) catch {
                    // TODO: handle this after the api gets re-written.
                    reporter.report_error(
                        .{ .pos = ast.pos_of(method_header.span()) },
                        "The method's selector exceeds the maximum available length, which is {d} characters.",
                        .{fixed_writer.buffer.len},
                    );
                    reporter.add_note(
                        .no_location,
                        "TODO: This is a temporary solution, change it ({d} is not that many). Probably put the implementation into `SymbolsManager` (But maybe not???).",
                        .{fixed_writer.buffer.len},
                    );
                    return error.keyword_selector_too_long;
                };
            }
            break :sw fixed_writer.buffer[0..fixed_writer.end];
        },
    };

    const method_selector_symbol = (try statics.symbols_manager.id_or_intern(method_selector_text)).id;
    return method_selector_symbol;
}

pub const CompileError = error{
    keyword_selector_too_long,
    too_many_items_in_array_literal,
    super_call_in_class_without_parent,
    could_not_find_method_in_parent,
    /// FIXME: This shouldn't be here at the end of implementation
    TODO,
} || Allocator.Error;

pub const BytecodeGenerator = struct {
    const Self = @This();

    allocator: Allocator,

    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    reporter: *ErrorReporter,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    builder: InstructionEncoder = undefined,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    ast: *const ParsedFile = undefined,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    lexical_scope_stack: *LexicalScopesStack = undefined,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    compiled_parent_methods: ?*const ClassDefinition.MethodMap = undefined,

    last_instruction: ?Instruction = null,

    pub fn init(params: struct {
        allocator: Allocator,
        symbols_manager: *SymbolsManager,
        constants_manager: *ConstantsManager,
        reporter: *ErrorReporter,
    }) Self {
        return Self{
            .allocator = params.allocator,
            .symbols_manager = params.symbols_manager,
            .constants_manager = params.constants_manager,
            .reporter = params.reporter,
        };
    }

    pub fn compile_method(
        self: *Self,
        params: struct {
            ast: *const ParsedFile,
            scope_stack: *LexicalScopesStack,
            compiled_parent_methods: ?*const ClassDefinition.MethodMap,
            //
            method_span: Ast.TokenSpan,
            body: Ast.FunctionBody,
            method_header: Ast.MethodHeader,
        },
    ) CompileError!Bytecode {
        const method_span = params.method_span;
        _ = method_span;
        const body = params.body;
        const method_header = params.method_header;

        self.ast = params.ast;
        defer self.ast = undefined;
        //
        self.lexical_scope_stack = params.scope_stack;
        defer self.lexical_scope_stack = undefined;
        //
        self.compiled_parent_methods = params.compiled_parent_methods;
        defer self.compiled_parent_methods = undefined;
        //
        self.builder = InstructionEncoder{ .bytes = .empty };
        defer self.builder = undefined;

        // TODO: think about reporting a warning that a local is shadowing a variable

        // Setup arguments
        {
            var arguments_scope = try self.lexical_scope_stack.add_scope(.{ .increase_depth = true });
            var arguments_iterator = method_header.iterate_argument_identifiers_excluding_self();
            // We want to register the identifiers with reverse indexes
            var idx: i64 = @as(i64, method_header.number_of_arguments_including_self()) - 2;
            while (arguments_iterator.next()) |argument_identifier_token| : (idx -= 1) {
                const identifier_symbol: SymbolId = try self.symbol_from_token(argument_identifier_token);
                try arguments_scope.register_variable(.{ .identifier = identifier_symbol, .idx = @intCast(idx) });
            }
            try arguments_scope.register_variable(.{
                .identifier = SymbolsManager.comptime_id_of("self"),
                .idx = method_header.number_of_arguments_including_self() - 1,
            });
        }
        defer self.lexical_scope_stack.pop_scope();

        const nil_constant_id = try self.constants_manager.add_constant(Constant.nil);

        // Setup locals
        {
            // Locals live on the same stackframe as arguemnts => `.increase_depth = false`
            var locals_scope = try self.lexical_scope_stack.add_scope(.{ .increase_depth = false });
            //
            var local_idx: u32 = method_header.number_of_arguments_including_self();
            var registered_at_least_one_local: bool = false;
            var iter = token_iterator(body.locals);
            while (iter.next()) |identifier_var_token| : (local_idx += 1) {
                const identifier: SymbolId = try self.symbol_from_token(identifier_var_token);
                try locals_scope.register_variable(.{ .identifier = identifier, .idx = local_idx });
                // TODO: we want to do some static analysis here maybe, so that we are not setting variables to nil and then reassigning them later
                if (!registered_at_least_one_local) {
                    // Load a `nil` on the stack so we can set locals to `nil`
                    try self.add_instruction(.{ .load_constant = .{ .id = nil_constant_id } });
                    registered_at_least_one_local = true;
                }
                // Set the local to `nil`
                try self.add_instruction(.{ .set_local = .{ .idx = local_idx } });
            }
            if (registered_at_least_one_local) {
                // Pop the nil that is sitting on the stack
                try self.add_instruction(.pop);
            }
        }
        defer self.lexical_scope_stack.pop_scope();

        // Compile the expressions
        for (body.expressions) |expr_id| {
            // TODO: once we remove `.print` replace it with removal of the last bytecode instruction
            try self.compile_expression(expr_id);
            if (self.last_instruction.?.is_load_instruction()) {
                // TODO: remove the instruction here (or use pop instruction)
            }
            // try self.add_instruction(.print);
            try self.add_instruction(.pop);
        }
        // TODO: maybe don't do default `nil` return if we have already emitted a return?

        // TODO(consultation): this is a hack, don't store multiple `nil`s. What to do?
        //                     NOTE: We probably want to store the actual singleton values in the end.
        try self.add_instruction(.{ .load_constant = .{ .id = nil_constant_id } });
        try self.add_instruction(.{ .set_local = Instruction.LocalVarId.return_object });

        // TODO: maybe pop instruction here after `set_local`?? ^^^
        // Resolution: I don't think it's needed, since the stack gets popped after `normal_return` has been run.

        try self.add_instruction(.normal_return);

        return try self.builder.get_final_bytecode(self.allocator);
    }

    fn symbol_from_token(self: *Self, token_id: Ast.TokenId) Allocator.Error!SymbolId {
        const token_text = self.ast.text_at(token_id);
        const symbol_id: SymbolId = (try self.symbols_manager.id_or_intern(token_text)).id;
        return symbol_id;
    }

    fn add_instruction(self: *Self, instruction: Instruction) !void {
        _ = try self.builder.add_instruction(self.allocator, instruction);
        self.last_instruction = instruction;
    }

    fn compile_message_send(self: *Self, receiver: Ast.ExprId, message_selector: SymbolId) CompileError!void {
        const receiver_tag: Ast.Expression.Tag = self.ast.tag_of(receiver);
        const is_receiver_super = switch (receiver_tag) {
            .variable => std.mem.eql(u8, self.ast.text_at(receiver), "super"),
            else => false,
        };

        if (!is_receiver_super) {
            try self.compile_expression(receiver);
            try self.add_instruction(Instruction{
                // FIXME: remove field `aditional_args_count`, it is not needed
                .send_message = .{ .message_name = message_selector, .aditional_args_count = undefined },
            });
            return;
        }

        // We have to compile a call to a method in the super class
        const parent_methods = if (self.compiled_parent_methods) |methods| methods else {
            self.reporter.report_error(.{ .pos = self.ast.pos_of(receiver) }, "Referencing `super` inside a class without a parent class.", .{});
            return CompileError.super_call_in_class_without_parent;
        };
        const method_ptr: *const MethodDefinition = parent_methods.get_ptr(message_selector) orelse {
            // SAFETY: we can access `self.ast.class_ast.super_class_name.?` because the current class has a parent in this branch of code (we are currently compiling a call to a method from the parent)
            const position_of_parent_declaration = self.ast.pos_of(self.ast.class_ast.super_class_name.?);
            const parent_name = self.ast.text_at(position_of_parent_declaration);
            const selector_as_string = self.symbols_manager.symbol_with_id(message_selector);
            self.reporter.report_error(.{ .pos = self.ast.pos_of(receiver) }, "Call to a `super` with method `{s}`, but the parent class is `{s}`, which doesn't have that method defined.", .{ selector_as_string, parent_name });
            self.reporter.add_note(.{ .pos = position_of_parent_declaration }, "The parent is defined here.", .{});
            return CompileError.could_not_find_method_in_parent;
        };
        try self.add_instruction(Instruction{
            .resolved_method_call = .{ .method_ptr = SmallPtr(*const MethodDefinition).new(method_ptr) },
        });
    }

    fn compile_expression(self: *Self, expr_id: Ast.ExprId) CompileError!void {
        const expr = self.ast.expressions.get(expr_id);
        switch (expr) {
            .integer_literal => |token_id| {
                const text = self.ast.text_at(token_id);
                const number = integer_from_text(i48, text) orelse {
                    // TODO:
                    @panic("TODO: implement overflow error reporting in integer literals");
                };
                const constant_id = try self.constants_manager.add_constant(Constant{ .integer = number });
                try self.add_instruction(.{ .load_constant = Instruction.LoadConstant{ .id = constant_id } });
            },
            .float_literal => |token_id| {
                const text = self.ast.text_at(token_id);
                const number = float_from_text(f64, text);
                const constant_id = try self.constants_manager.add_constant(Constant{ .float = number });
                try self.add_instruction(.{ .load_constant = Instruction.LoadConstant{ .id = constant_id } });
            },
            .string_literal => |token_id| {
                // FIXME: parse escaped special characters from the text here (or make a function for that and use it)
                const text = self.ast.text_at(token_id);
                assert(text.len >= 2); // This assert should not fail, since the string literal must be at least `''`.
                const trimmed_string = text[1 .. text.len - 1];
                const constant_id = try self.constants_manager.add_constant(Constant{ .string = trimmed_string });
                try self.add_instruction(.{ .load_constant = Instruction.LoadConstant{ .id = constant_id } });
            },
            .unary_message_call => |unary_call| {
                const message_symbol: SymbolId = try self.symbol_from_token(unary_call.message);
                try self.compile_message_send(unary_call.argument, message_symbol);
            },
            .binary_message_call => |raw_binary_call| {
                const binary_call = raw_binary_call.decompress(self.ast.extras);
                const message_symbol: SymbolId = try self.symbol_from_token(binary_call.message);

                // The calling convention mandates that the order of the arguments is
                // pushed onto the stack in the *REVERSE* order in comparison to the
                // order of the arguments in code.
                try self.compile_expression(binary_call.rhs);
                try self.compile_message_send(binary_call.lhs, message_symbol);
            },
            .keyword_message_call => |keyword_message_call| {
                // TODO: the length of the `buffer` should be the same as in `get_selector_symbol`
                // Build the selector
                var buffer: [512]u8 = undefined;
                var writer = std.io.Writer.fixed(&buffer);
                const arguments = keyword_message_call.get_args(self.ast.extras);
                for (0..arguments.number_of_args()) |idx| {
                    const keyword_text = self.ast.text_at(arguments.nth_keyword(@intCast(idx)));
                    _ = writer.write(keyword_text) catch {
                        self.reporter.report_error(
                            .{ .pos = self.ast.pos_of(expr_id) },
                            "The selector is too long. Maximum is {d} characters.",
                            .{buffer.len},
                        );
                        return error.keyword_selector_too_long;
                    };
                }
                const selector_as_string = buffer[0..writer.end];
                const selector_symbol: SymbolId = (try self.symbols_manager.id_or_intern(selector_as_string)).id;

                // The calling convention mandates that the order of the arguments is
                // pushed onto the stack in the *REVERSE* order in comparison to the
                // order of the arguments in code.
                //
                // So we compile the arguments in the reverse order.
                for (0..arguments.number_of_args()) |reverse_idx| {
                    const argument_idx: u32 = @intCast(arguments.number_of_args() - reverse_idx - 1);
                    const argument_ast: Ast.ExprId = arguments.nth_argument(argument_idx);
                    try self.compile_expression(argument_ast);
                }
                try self.compile_message_send(keyword_message_call.first_argument, selector_symbol);
            },
            .variable => |identifier_token| {
                const identifier_symbol: SymbolId = try self.symbol_from_token(identifier_token);
                const load_instr: Instruction = sw: switch (self.lexical_scope_stack.lookup_variable(identifier_symbol)) {
                    .instance => |info| {
                        break :sw .{ .load_instance_var = info.instance_variable_id };
                    },
                    .local_or_method_argument => |info| {
                        // FIXME: Account for non zero `scope_depth_difference` (when we are in a block)
                        assert(info.scope_depth_difference == 0);
                        break :sw .{ .load_local = info.local_variable_id };
                    },
                    .global => break :sw .{ .load_global = identifier_symbol },
                };
                try self.add_instruction(load_instr);
            },
            .assignment => |assignment| {
                // TODO: try chained assignment, maybe this does not work???
                try self.compile_expression(assignment.target_value);
                const idenditifer_text = self.ast.text_at(assignment.variable);
                const identifier_symbol: SymbolId = try self.symbol_from_token(assignment.variable);
                const set_instr: Instruction = switch (self.lexical_scope_stack.lookup_variable(identifier_symbol)) {
                    .instance => |info| .{ .set_instance_var = info.instance_variable_id },
                    .local_or_method_argument => |info| .{ .set_local = info.local_variable_id },
                    .global => {
                        self.reporter.report_error(
                            .{ .pos = self.ast.pos_of(assignment.variable) },
                            "TODO: Cannot yet compile setting of a global variable, therefore could not set the global variable named '{s}'.",
                            .{idenditifer_text},
                        );
                        return error.TODO;
                    },
                };
                try self.add_instruction(set_instr);
            },
            .exit_expression => |exit_expr| {
                try self.compile_expression(exit_expr.return_value);
                // TODO: here we will probably have to check, whether we are in an block or not - and generate a different return
                try self.add_instruction(.{ .set_local = Instruction.LocalVarId.return_object });
                try self.add_instruction(.normal_return);
            },
            .array_literal => |array_literal| {
                const sub_expressions: []const Ast.ExprId = self.ast.extras.variable_span_of(array_literal.elements);
                for (sub_expressions) |sub_expression| {
                    try self.compile_expression(sub_expression);
                }
                const max_length = std.math.maxInt(Instruction.PopIntoNewArray.IntRepr);
                if (sub_expressions.len > max_length) {
                    self.reporter.report_error(.{ .pos = self.ast.pos_of(sub_expressions[max_length]) }, "This item causes the array literal to be too long. What are you even doing? Having more than {d} items (the limit) in an array literal seems a bit much.", .{max_length});
                    return error.too_many_items_in_array_literal;
                }
                try self.add_instruction(.{ .pop_into_new_array = .{
                    .number_of_items = @truncate(sub_expressions.len),
                } });
            },
            .symbol => |original_tokens_span| {
                // The symbol should consist of at least a `#` symbol and one more token
                assert(original_tokens_span.number_of_tokens() > 1);
                const token_span = Ast.TokenSpan.create(original_tokens_span.start_id.idx + 1, original_tokens_span.end_id.idx);
                if (self.ast.kind_of(token_span.start_id) == .string_literal) {
                    // FIXME: compile all kinds of symbols. Especially string literals
                    // NOTE: probably compile string literals properly first
                    self.reporter.report_error(.{ .pos = self.ast.pos_of(expr_id) }, "TODO: Compiling of symbols which are string literals", .{});
                    return error.TODO;
                }
                const symbol_as_string = self.ast.text_at(token_span);
                const symbol_id = (try self.symbols_manager.id_or_intern(symbol_as_string)).id;
                try self.add_instruction(.{ .load_symbol = symbol_id });
            },
            else => |todo_expr| {
                self.reporter.report_error(
                    .{ .pos = self.ast.pos_of(expr_id) },
                    "TODO: Compiling of expression type of '{t}' not implemented yet :D",
                    .{todo_expr.tag()},
                );
                return error.TODO;
            },
        }
    }
};

inline fn cast_integer_to(comptime Number: type, to_cast: anytype) Number {
    return switch (Number) {
        f64, f32 => @floatFromInt(to_cast),
        else => return @as(Number, to_cast),
    };
}

pub inline fn muliply_by_10_add(comptime Number: type, value: Number, signed_digit: Number) ?Number {
    switch (@typeInfo(Number)) {
        .int => {
            var result = value;
            result = std.math.mul(Number, result, 10) catch return null;
            result = std.math.add(Number, result, signed_digit) catch return null;
            return result;
        },
        .float => {
            return @mulAdd(Number, value, 10, signed_digit);
        },
        else => @compileError(std.fmt.comptimePrint("Unexpected type: {}", .{Number})),
    }
}

/// Returns a parsed number or `null` if the number does not fit into the integer's type range.
/// WARNING: Asserts all characters in `text` are digits (first one can be `-` for negative numbers).
pub inline fn integer_from_text(comptime Number: type, text: []const u8) ?Number {
    assert(text.len > 0);
    var result: Number = 0;
    var sign: Number = 1;
    var start_index: usize = 0;

    if (text[0] == '-') {
        sign = -1;
        start_index += 1;
    }

    for (text[start_index..]) |char| {
        assert(std.ascii.isDigit(char));
        const digit: Number = cast_integer_to(Number, char - '0');
        const signed_digit: Number = sign * digit;
        result = muliply_by_10_add(Number, result, signed_digit) orelse return null;
    }

    return result;
}

pub inline fn float_from_text(comptime Float: type, text: []const u8) Float {
    const whole_part_end = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    const whole_part_text = text[0..whole_part_end];
    const whole_part: Float = integer_from_text(Float, whole_part_text).?; // TODO: check if this actually never fails

    const decimal_part_start = if (whole_part_end == text.len) return whole_part else whole_part_end + 1;
    const decimal_part_text = text[decimal_part_start..];

    var decimal_part: Float = integer_from_text(Float, decimal_part_text).?; // TODO: check if this actually never fails
    if (std.math.signbit(whole_part)) decimal_part *= -1;
    const divisor = std.math.pow(Float, 10, @floatFromInt(decimal_part_text.len));
    decimal_part /= divisor;

    const result: Float = whole_part + decimal_part;
    return result;
}

pub const Bytecode = struct {
    bytes: []const u8,
};

/// TODO: maybe the `idx` could be smaller?
pub const InstructionId = struct { idx: usize };

pub const InstructionDecoder = struct {
    const Self = @This();

    bytes: []const u8,
    next_idx: usize,

    pub const empty = Self{ .bytes = &[_]u8{}, .next_idx = 0 };

    pub fn new(bytecode: Bytecode) Self {
        return InstructionDecoder{
            .bytes = bytecode.bytes,
            .next_idx = 0,
        };
    }

    pub fn is_at_end(self: Self) bool {
        return !(self.next_idx < self.bytes.len);
    }

    pub fn set_id_of_the_next_instruction(self: *Self, id: InstructionId) void {
        self.next_idx = id.idx;
    }

    pub fn id_of_next_instruction(self: Self) InstructionId {
        return InstructionId{ .idx = self.next_idx };
    }

    /// return null -> decoder is at the end of the bytecode
    pub inline fn next_instruction(self: *Self) ?Instruction {
        if (self.is_at_end()) {
            // Since in the practical VM code,
            // we will use `halt` to end fetching of the next_instruction
            @branchHint(.cold);
            return null;
        }

        const tag_byte: u8 = self.read_byte();
        const tag: Instruction.Tag = @enumFromInt(tag_byte);
        return sw: switch (tag) {
            .load_local => {
                const local_id = self.read_id(Instruction.LocalVarId);
                break :sw Instruction{ .load_local = local_id };
            },
            .set_local => {
                const local_id = self.read_id(Instruction.LocalVarId);
                break :sw Instruction{ .set_local = local_id };
            },
            .load_instance_var => {
                const id = self.read_id(Instruction.InstanceVarId);
                break :sw Instruction{ .load_instance_var = id };
            },
            .set_instance_var => {
                const local_id = self.read_id(Instruction.InstanceVarId);
                break :sw Instruction{ .set_instance_var = local_id };
            },
            .pop_into_new_array => {
                const number_of_items = self.read_integer(Instruction.PopIntoNewArray.IntRepr);
                break :sw Instruction{ .pop_into_new_array = .{ .number_of_items = number_of_items } };
            },
            .load_constant => {
                const id = self.read_id(RelativeConstantId);
                break :sw Instruction{ .load_constant = .{ .id = id } };
            },
            .load_global => {
                const identifier = self.read_id(SymbolId);
                break :sw Instruction{ .load_global = identifier };
            },
            .load_symbol => {
                const id = self.read_id(SymbolId);
                break :sw Instruction{ .load_symbol = id };
            },
            .send_message => {
                const ArgsCount = @FieldType(Instruction.SendMessage, "aditional_args_count");
                const args_cout = self.read_integer(ArgsCount);
                const message_name_id = self.read_id(SymbolId);

                break :sw Instruction{ .send_message = Instruction.SendMessage{
                    .aditional_args_count = args_cout,
                    .message_name = message_name_id,
                } };
            },
            .resolved_method_call => {
                const pointer_bits = self.read_integer(SmallPtr(*const MethodDefinition).BitsRepresentation);
                const small_ptr = SmallPtr(*const MethodDefinition){ .bits = pointer_bits };
                break :sw Instruction{ .resolved_method_call = .{ .method_ptr = small_ptr } };
            },
            .no_op => break :sw .no_op,
            .duplicate => break :sw .duplicate,
            .halt => break :sw .halt,
            .normal_return => break :sw .normal_return,
            .print => break :sw .print,
            .pop => break :sw .pop,
        };
    }

    pub inline fn read_byte(self: *Self) u8 {
        assert(self.next_idx < self.bytes.len);
        self.next_idx += 1;
        return self.bytes[self.next_idx - 1];
    }

    pub inline fn read_id(self: *Self, comptime IdType: type) IdType {
        const should_error = comptime switch (@typeInfo(IdType)) {
            .@"struct" => |info| (info.fields.len != 1 or !std.mem.eql(u8, info.fields[0].name, "idx")),
            else => true,
        };
        if (comptime should_error) {
            @compileError(std.fmt.comptimePrint("Expected a struct with exactly one field named `idx`. Got type `{s}`.", .{@typeName(IdType)}));
        }

        const Idx = @FieldType(IdType, "idx");
        const idx = self.read_integer(Idx);
        return IdType{ .idx = idx };
    }

    pub inline fn read_integer(self: *Self, comptime IntegerType: anytype) IntegerType {
        const byte_size = @divExact(@typeInfo(IntegerType).int.bits, 8);
        assert(self.next_idx + byte_size <= self.bytes.len); // NOTE the `<=` here!

        const bytes = self.bytes[self.next_idx .. self.next_idx + byte_size];
        const result = std.mem.readVarInt(IntegerType, bytes, .little);

        self.next_idx += byte_size;
        return result;
    }
};

pub const InstructionEncoder = struct {
    const Self = @This();
    bytes: std.ArrayList(u8),

    pub fn get_final_bytecode(self: *Self, allocator: Allocator) Allocator.Error!Bytecode {
        const bytecode_bytes = try self.bytes.toOwnedSlice(allocator);
        return Bytecode{ .bytes = bytecode_bytes };
    }

    pub fn id_of_the_next_instruction(self: Self) InstructionId {
        const idx = self.bytes.items.len;
        return InstructionId{ .idx = @truncate(idx) };
    }

    pub fn pop_last_instruction(self: *Self, instruction_size_in_bytes: u8) void {
        self.bytes.items.len -= instruction_size_in_bytes;
    }

    pub fn add_instruction(self: *Self, allocator: Allocator, instruction: Instruction) Allocator.Error!InstructionId {
        const instruction_id = self.id_of_the_next_instruction();
        try self.bytes.append(allocator, @intFromEnum(instruction.tag()));

        switch (instruction) {
            .load_local => |info| {
                try self.write_integer(allocator, info.idx);
            },
            .set_local => |info| {
                try self.write_integer(allocator, info.idx);
            },
            .load_instance_var => |info| {
                try self.write_integer(allocator, info.idx);
            },
            .set_instance_var => |info| {
                try self.write_integer(allocator, info.idx);
            },
            .load_constant => |info| {
                try self.write_integer(allocator, info.id.idx);
            },
            .load_global => |info| {
                try self.write_integer(allocator, info.idx);
            },
            .send_message => |info| {
                try self.write_integer(allocator, info.aditional_args_count);
                try self.write_integer(allocator, info.message_name.idx);
            },
            .pop_into_new_array => |info| {
                try self.write_integer(allocator, info.number_of_items);
            },
            .load_symbol => |symbol_id| {
                try self.write_integer(allocator, symbol_id.idx);
            },
            .resolved_method_call => |info| {
                try self.write_integer(allocator, info.method_ptr.bits);
            },
            // NOTE(epic-zig): comptime assert
            inline else => |payload, tag| {
                if (@TypeOf(payload) != void) {
                    const error_msg = std.fmt.comptimePrint("Missed instruction `{t}` which has non-void payload type `{s}`", .{ tag, @typeName(@TypeOf(payload)) });
                    @compileError(error_msg); // Actually saved me a couple of times :D
                }
            },
        }

        const bytes_added = self.bytes.items.len - instruction_id.idx;
        assert(bytes_added == instruction.bytecode_size_in_bytes());

        return instruction_id;
    }

    fn write_integer(self: *Self, allocator: Allocator, int: anytype) Allocator.Error!void {
        const IntegerType = @TypeOf(int);
        const byte_count = @typeInfo(IntegerType).int.bits / 8;

        var bytes: [byte_count]u8 = undefined;
        std.mem.writeInt(IntegerType, &bytes, int, .little);

        try self.bytes.appendSlice(allocator, &bytes);
    }
};

pub const InstructionFormatter = struct {
    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    base_constant_id: ConstantId,

    pub fn fmt(self: @This(), instruction: Instruction) Fmt {
        return Fmt{
            .instruction = instruction,
            //
            .constants_manager = self.constants_manager,
            .symbols_manager = self.symbols_manager,
            .base_constant_id = self.base_constant_id,
        };
    }

    const Fmt = struct {
        const Writer = std.io.Writer;
        symbols_manager: *SymbolsManager,
        constants_manager: *ConstantsManager,
        instruction: Instruction,
        base_constant_id: ConstantId,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const tag_name: []const u8 = @tagName(self.instruction.tag());
            try writer.print("{s:<13}", .{tag_name});

            switch (self.instruction) {
                .load_constant => |load_constant| {
                    const relative_id = load_constant.id;
                    const absolute_id = relative_id.to_absolute(self.base_constant_id);
                    try writer.print(" id({d:03}+{d:03}={d:03}) ", .{ self.base_constant_id.idx, relative_id.idx, absolute_id.idx });
                    try self.print_constant(writer, self.constants_manager.get_constant(absolute_id));
                },
                .send_message => |send_message| {
                    const message_name = self.symbols_manager.symbol_with_id(send_message.message_name);
                    try writer.print(" name=\"{s}\" args-count={d}", .{ message_name, send_message.aditional_args_count });
                },
                .load_local => |local_id| {
                    try writer.print(" id({d})", .{local_id.idx});
                },
                .set_local => |local_id| {
                    try writer.print(" id({d})", .{local_id.idx});
                },
                .load_instance_var => |instance_var_id| {
                    try writer.print(" id({d})", .{instance_var_id.idx});
                },
                .set_instance_var => |instance_var_id| {
                    try writer.print(" id({d})", .{instance_var_id.idx});
                },
                .pop_into_new_array => |info| {
                    try writer.print(" items-count={d}", .{info.number_of_items});
                },
                .load_global => |global_var_id| {
                    const identifier: []const u8 = self.symbols_manager.symbol_with_id(global_var_id);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ identifier, global_var_id.idx });
                },
                .load_symbol => |id| {
                    const string: []const u8 = self.symbols_manager.symbol_with_id(id);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ string, id.idx });
                },
                .resolved_method_call => |info| {
                    const method_ptr: *const MethodDefinition = info.method_ptr.pointee();
                    try writer.print(
                        " method-name=\"{s}\" is_primitive={s} ptr={x}",
                        .{
                            self.symbols_manager.symbol_with_id(method_ptr.method_name),
                            if (std.meta.activeTag(method_ptr.body) == .primitive) "YES" else "NO",
                            @as(usize, @intFromPtr(method_ptr)),
                        },
                    );
                },
                // NOTE(epic-zig): comptime assert
                inline else => |payload, tag| {
                    if (@TypeOf(payload) != void) {
                        const error_msg = std.fmt.comptimePrint("Missed instruction `{t}` which has non-void payload type `{s}`", .{ tag, @typeName(@TypeOf(payload)) });
                        @compileError(error_msg); // Actually saved me a couple of times :D
                    }
                },
            }

            try writer.print("\n", .{});
        }

        fn print_constant(self: @This(), writer: *Writer, constant: Constant) Writer.Error!void {
            _ = self;
            switch (constant) {
                .integer => |value| {
                    try writer.print("integer({d})", .{value});
                },
                .float => |value| {
                    try writer.print("float({d})", .{value});
                },
                .string => |value| {
                    try writer.print("string({s})", .{value});
                },
                .nil => {
                    try writer.print("nil", .{});
                },
            }
        }
    };
};

pub fn print_bytecode(
    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    base_constant_id: ConstantId,
    bytecode: Bytecode,
    writer: *std.io.Writer,
) std.io.Writer.Error!void {
    const f = InstructionFormatter{
        .constants_manager = constants_manager,
        .symbols_manager = symbols_manager,
        .base_constant_id = base_constant_id,
    };
    var decoder = InstructionDecoder.new(bytecode);
    var instruction_idx: InstructionId = decoder.id_of_next_instruction();

    while (decoder.next_instruction()) |instruction| {
        try writer.print("[{d:04}] {f}", .{ instruction_idx.idx, f.fmt(instruction) });
        instruction_idx = decoder.id_of_next_instruction();
    }
}

pub const Instruction = union(enum(u8)) {
    no_op = 0,
    load_constant: LoadConstant = 1,
    send_message: SendMessage = 2,

    /// Duplicates a value that is on the the top of the stack.
    /// The duplicate is pushed on the top of the stack.
    duplicate = 3,

    /// Stops the program.
    halt = 4,

    /// Pushes either a local variable or a method argument onto the stack.
    load_local: LocalVarId = 5,

    /// Pushes an instance variable of the current `self` object onto the stack.
    load_instance_var: InstanceVarId = 6,

    load_global: SymbolId = 7,

    normal_return = 8,

    /// TODO: maybe fix this? doesn't pop
    /// Gets the top value from the stack (doesn't pop) and assigns its value into a local variable
    set_local: LocalVarId = 9,

    /// TODO: maybe fix this? doesn't pop
    /// Gets the top value from the stack (doesn't pop) and assigns its value into an instance variable
    set_instance_var: InstanceVarId = 10,

    pop = 11,

    pop_into_new_array: PopIntoNewArray = 12,

    load_symbol: SymbolId = 13,

    resolved_method_call: struct { method_ptr: SmallPtr(*const MethodDefinition) },

    print, // TODO: remove this after development

    pub const PopIntoNewArray = packed struct {
        pub const IntRepr = u24;
        number_of_items: IntRepr,
    };
    /// TODO: THIS IS PROBABLY NOT VALID
    ///
    /// Represents the place relative to the base pointer in the
    /// object stack during interpreter runtime, where a variable is stored.
    ///
    /// The variable can be either a local varibale or an argument to a method.
    ///
    /// For example if the object stack was this:
    ///
    ///     object stack:
    ///                   ... (maybe previous locals)
    ///     base_ptr ---> method_argument[0] (<- this object should be always `self` by the way)
    ///                   method_argument[1]
    ///                   method_argument[2]
    ///                   method_argument[3]
    ///                   local_variable[0]
    ///                   local_variable[1]
    ///                   local_variable[2]
    ///                   ... (maybe arguments to the next method)
    ///
    /// To access the `method_argument[1]`, you would need `LocalId{.idx = 1}`.
    /// To access the `local_variable[0]`, you would need `LocalId{.idx = 4}` (4 = <number-of-arguments> + <index-of-local>)
    pub const LocalVarId = struct {
        idx: u32,
        pub const return_object = LocalVarId{ .idx = 0 };
    };

    pub const InstanceVarId = struct { idx: u32 };

    pub const SendMessage = struct {
        message_name: SymbolId,

        // TODO: remove this, I don't think this field is needed
        /// Number of arguments to pop from stack
        /// (excluding the first argument which is the message target object).
        ///
        /// For example, unary message has this field set to 0 and binary to 1.
        aditional_args_count: u8,
    };
    pub const LoadConstant = struct { id: RelativeConstantId };

    const Self = @This();
    const Tag = std.meta.Tag(Instruction);
    pub fn tag(self: Self) Tag {
        return std.meta.activeTag(self);
    }

    /// Whether the modifies the runtime stack in a way that pushes a single value onto it.
    pub fn is_load_instruction(self: Self) bool {
        return switch (self) {
            .no_op => false,
            .load_symbol => true,
            .pop_into_new_array => false,
            .load_constant => true,
            .send_message => false,
            .resolved_method_call => false,
            .duplicate => true,
            .halt => false,
            .set_instance_var => false,
            .load_local => true,
            .load_instance_var => true,
            .load_global => true,
            .normal_return => false,
            .set_local => false,
            .print => false,
            .pop => false,
        };
    }

    pub fn bytecode_size_in_bytes(self: Self) u8 {
        return res: switch (self) {
            inline else => |payload| {
                const payload_size: u8 = sw: switch (@typeInfo(@TypeOf(payload))) {
                    .@"struct" => |struct_info| {
                        comptime var fields_total_size_bytes = 0;
                        inline for (struct_info.fields) |payload_field| {
                            assert(@bitSizeOf(payload_field.type) % 8 == 0);
                            fields_total_size_bytes += @bitSizeOf(payload_field.type) / 8;
                        }
                        break :sw fields_total_size_bytes;
                    },
                    else => break :sw @bitSizeOf(@TypeOf(payload)) / 8,
                };
                const tag_size = @bitSizeOf(Tag) / 8;
                const total_size = payload_size + tag_size;
                break :res total_size;
            },
        };
    }
};

test InstructionEncoder {
    const allocator = std.testing.allocator;
    var encoder = InstructionEncoder{ .bytes = .empty };
    defer encoder.bytes.deinit(allocator);
    var id: InstructionId = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{},
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(0, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{0},
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(1, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0 },
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(2, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0 },
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, .halt);
    try std.testing.expectEqual(3, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4 },
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, .duplicate);
    try std.testing.expectEqual(4, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3 },
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, Instruction{
        .load_constant = .{ .id = RelativeConstantId{ .idx = 42 } },
    });
    try std.testing.expectEqual(5, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0 },
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(8, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0 },
        (try encoder.get_final_bytecode(allocator)).bytes,
    );

    id = try encoder.add_instruction(allocator, Instruction{ .send_message = .{
        .message_name = SymbolId.new(68),
        .aditional_args_count = 97,
    } });
    try std.testing.expectEqual(9, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0, 2, 97, 68, 0, 0 },
        (try encoder.get_final_bytecode(allocator)).bytes,
    );
}

test InstructionDecoder {
    const bytes = [_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0, 2, 97, 68, 0, 0 };
    const expected_instructions = [_]Instruction{
        .no_op,
        .no_op,
        .no_op,
        .halt,
        .duplicate,
        Instruction{
            .load_constant = .{ .id = RelativeConstantId{ .idx = 42 } },
        },
        .no_op,
        Instruction{ .send_message = .{
            .message_name = SymbolId.new(68),
            .aditional_args_count = 97,
        } },
    };

    const bytecode = Bytecode{ .bytes = &bytes };
    var decoder = InstructionDecoder.new(bytecode);
    var idx: u32 = 0;
    while (decoder.next_instruction()) |instruction| : (idx += 1) {
        const expected_instruction = expected_instructions[idx];
        std.testing.expectEqualDeep(expected_instruction, instruction) catch |err| {
            std.debug.print("Index of instruction is `{d}`\n", .{idx});
            return err;
        };
    }
}
