const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;
const dbg_assert_eql = debug_module.dbg_assert_eql;
const dbg_assert_eql_msg = debug_module.dbg_assert_eql_msg;

const interning_module = @import("../interning/symbols_manager.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = @import("../interning/symbol_array_map.zig").SymbolArrayMap;

const lexer_module = @import("../frontend/lexer.zig");
const TokenizedFile = lexer_module.TokenizedFile;
const parser_module = @import("../frontend/parser.zig");

const interpreter_module = @import("../interpreter/interpreter.zig");
const VmObject = interpreter_module.VmObject;
const ClassDefinition = interpreter_module.ClassDefinition;
const PrimitiveMethodsMap = interpreter_module.PrimitiveMethodsMap;
const Method = interpreter_module.Method;
const MethodBody = interpreter_module.MethodBody;
const HeapData = interpreter_module.HeapData;
const primitives = interpreter_module.primitives;
const Statics = interpreter_module.Statics;

const token_module = @import("token.zig");
const IntegerRepresentation = token_module.IntegerRepresentation;
const FloatRepresentation = token_module.FloatRepresentation;

const Ast = @import("ast.zig");
const iterator = Ast.TokenSpan.iterator;
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

    pub fn new_base_id_for_class(self: *Self) ConstantId {
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

pub const ScopeStack = struct {
    all_entries: std.ArrayList(Variable),
    allocator: Allocator,

    /// Lexical stack of identifiers.
    /// All `ScopeSymbolMap`s contain slices of the `all_entries` array list.
    scopes: std.ArrayList(ScopeSymbolMap),

    const Self = @This();
    pub const Variable = struct { identifier: SymbolId, idx: u32 };
    pub const VariableId = union(enum) {
        instance: Instruction.InstanceVarId,
        local_or_method_argument: Instruction.LocalVarId,
        global,
    };
    pub const ScopeSymbolMap = SymbolArrayMap(Variable, "identifier");

    pub const Scope = struct {
        original_stack: *ScopeStack,
        start_idx: usize,

        pub fn register_variable(self: *@This(), variable: Variable) Allocator.Error!void {
            try self.original_stack.all_entries.append(self.original_stack.allocator, variable);
        }
    };

    pub fn get_idx_of(self: Self, identifier: SymbolId) VariableId {
        var scope_idx: i32 = @intCast(self.scopes.items.len - 1);
        while (scope_idx >= 0) : (scope_idx -= 1) {
            if (self.scopes.items[@intCast(scope_idx)].get(identifier)) |variable| {
                if (scope_idx == 0) {
                    return VariableId{ .instance = .{ .idx = variable.idx } };
                } else {
                    return VariableId{ .local_or_method_argument = .{ .idx = variable.idx } };
                }
            }
        }
        return VariableId.global;
    }

    pub fn init(allocator: Allocator, init_stack_capacity: usize, init_all_entries_capacity: usize) Allocator.Error!Self {
        const stack = try std.ArrayList(ScopeSymbolMap).initCapacity(allocator, init_stack_capacity);
        const all_entries = try std.ArrayList(Variable).initCapacity(allocator, init_all_entries_capacity);
        return Self{ .all_entries = all_entries, .scopes = stack, .allocator = allocator };
    }

    pub fn reset_but_retain_capacity(self: *Self) void {
        self.all_entries.clearRetainingCapacity();
        self.scopes.clearRetainingCapacity();
    }

    pub fn new_scope(self: *Self) Scope {
        return Scope{ .original_stack = self, .start_idx = self.all_entries.items.len };
    }

    /// TODO: report a warning when there are duplicate identifiers in the scope (see comment below in this function where to do it)
    pub fn push_scope(self: *Self, scope: Scope) !void {
        const variables_slice: []Variable = self.all_entries.items[scope.start_idx..];
        const new_symbol_map = ScopeSymbolMap.from_slice_remove_duplicates(variables_slice);
        const new_entries_len = scope.start_idx + new_symbol_map.items.len;

        const duplicates_start_idx = new_entries_len;
        assert(duplicates_start_idx <= self.all_entries.items.len);
        if (duplicates_start_idx != self.all_entries.items.len) {
            // TODO: report the duplicates warning here
            const duplicates_slice = self.all_entries.items[duplicates_start_idx..];
            _ = duplicates_slice; // (we silently ignore the duplicates for now)
        }

        self.all_entries.shrinkRetainingCapacity(new_entries_len);
        try self.scopes.append(self.allocator, new_symbol_map);
    }

    /// Asserts that there is at least one scope.
    pub fn pop_scope(self: *Self) void {
        const popped_scope_map: ScopeSymbolMap = self.scopes.pop().?;
        const current_entries_length = self.all_entries.items.len;
        const popped_entries_cnt = popped_scope_map.items.len;

        const new_entries_length = current_entries_length - popped_entries_cnt;
        self.all_entries.shrinkRetainingCapacity(new_entries_length);
    }
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

pub fn compile_class_with_its_parents(
    params: CompileClassWithItsParentsParams,
) !*ClassDefinition {
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

    // Parsed classes to be compiled. This invariant should hold:
    //    (∀ idx in 1..len-1 ) ( classes_to_compile[idx] is_parent_of classes_to_compile[idx-1] )
    //
    // This means, we will have to compile them in the reverse order, so that the compiled version of the parent class
    // is available when we want to compile the child.
    //
    // The order of classes in this ArrayList is "reversed" like this, because we encounter and parse the classes in this order.
    //
    const CompiledClass = struct { name: SymbolId, ast: ParsedFile };
    var classes_to_compile = try std.ArrayList(CompiledClass).initCapacity(temporary_allocator, 5);
    defer classes_to_compile.deinit(temporary_allocator);
    try classes_to_compile.append(temporary_allocator, CompiledClass{ .name = bottom_class_name, .ast = bottom_ast });

    const parent_of_last_class: ?*ClassDefinition = while (maybe_parent_being_resolved) |parent_being_resolved| {

        // Check if the name is in `classes_to_compile`
        for (classes_to_compile.items) |parsed_predecessor| {
            if (parent_being_resolved.idx != parsed_predecessor.name.idx) continue;
            return error.circular_dependency; // TODO: nice error report that lists out the loop in the hiearchy
        }

        // TODO(consultation): Can we look-up the globals like this here? I think it makes sense.
        if (globals.get(parent_being_resolved)) |parent_definition| {
            break switch (parent_definition.data.kind()) {
                .class => |accessor| accessor.get_class_definition(parent_definition.data),
                else => return error.parent_is_not_a_class,
            };
        }
        const parent_ast: ParsedFile = try find_file_and_parse_it(parent_being_resolved, source_code_files, statics, error_writer, temporary_allocator);
        try classes_to_compile.append(temporary_allocator, CompiledClass{ .name = parent_being_resolved, .ast = parent_ast });
        maybe_parent_being_resolved = try symbol_of_parents_name(parent_ast.class_ast.super_class_name, &statics.symbols_manager, parent_ast);
    } else null;

    try globals.ensureUnusedCapacity(classes_to_compile.items.len);
    try statics.all_classes.growCapacity(statics.allocator, statics.all_classes.len + classes_to_compile.items.len);

    // Compile the classes
    var current_parent: ?*ClassDefinition = parent_of_last_class;
    var iter = std.mem.reverseIterator(classes_to_compile.items);
    while (iter.nextPtr()) |class_to_compile| {
        var reporter = ErrorReporter{
            .source = class_to_compile.ast.source_code,
            // TODO: add filepath here
            .source_path = "TODO the filepath here :D",
            .use_color = true,
            .writer = error_writer,
        };
        const compiled_class = try compile_class(
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

pub fn compile_class(
    ast: ParsedFile,
    class_name_symbol: SymbolId,
    compiled_parent: ?*ClassDefinition,
    temporary_allocator: Allocator,
    statics: *Statics,
    reporter: *ErrorReporter,
    primitive_methods_map: PrimitiveMethodsMap,
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
) !*ClassDefinition {
    // TODO: class portion is ignored here, we assume only the instance portion for now

    const constants_base_id = statics.constants_manager.new_base_id_for_class();

    var bytecode_generator = BytecodeGenerator{
        .allocator = statics.allocator,
        .symbols_manager = &statics.symbols_manager,
        .builder = &statics.instruction_encoder,
        .constants_manager = &statics.constants_manager,
        .reporter = reporter,
    };

    var lexical_scopes = try ScopeStack.init(temporary_allocator, 5, 30);

    const all_methods_len = ast.class_ast.instance_portion.methods.len + (if (compiled_parent) |p| p.instance_methods.items.len else 0);
    var compiled_methods: []Method = try temporary_allocator.alloc(Method, all_methods_len);
    defer temporary_allocator.free(compiled_methods);

    const maybe_primitive_class = primitive_methods_map.sorted_classes.get_ptr(class_name_symbol);

    // TODO: consider putting this into the `SymbolsManager`?
    var buffer_for_selectors: [16]u8 = undefined;
    var selector_writer = std.io.Writer.fixed(&buffer_for_selectors);

    var method_idx: usize = 0;
    for (ast.class_ast.instance_portion.methods) |method_ast| {
        lexical_scopes.reset_but_retain_capacity();

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

                compiled_methods[method_idx] = Method{
                    .method_name = method_selector,
                    .number_of_aditional_args = primitive_method.args_cnt - 1,
                    .body = MethodBody{ .primitive = primitive_method.function },
                };
                method_idx += 1;
            },
            .impl => |function_body| {
                const start_instruction_id: InstructionId = try bytecode_generator.compile_method(
                    &ast,
                    &lexical_scopes,
                    method_ast.span,
                    function_body,
                    method_ast.header,
                );
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
                compiled_methods[method_idx] = Method{
                    .method_name = method_selector,
                    .number_of_aditional_args = @truncate(number_of_aditional_args),
                    .body = MethodBody{ .user_land = .{ .start_instruction = start_instruction_id, .number_of_locals = @truncate(number_of_locals) } },
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
            // TODO: when we re-factor the method to compile a portion of the class AST, we have to change what we are iterating over
            for (ast.class_ast.instance_portion.methods) |method_ast| {
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
            return error.duplicate_method_definition;
        },
    };

    const instance_methods = blk: {
        const parents_methods: ClassDefinition.MethodMap = if (compiled_parent) |parent_class|
            parent_class.instance_methods
        else
            .{ .items = &[0]Method{} };
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
            .constants_base_id = constants_base_id,
            .as_vm_object = undefined,
        };
        break :blk ptr;
    };

    // Create a new global object which represents the newly compiled class
    var header = HeapData.Header.new_undefined_with_tag(.class);
    (primitives.Class.Accessor{}).set_instance_variables_count(header.as_heap_data(), 0); // TODO: replace the `0` with something like `compiled_class.class_variables.count`
    const heap_data: *HeapData = try statics.allocate_for_static_object(header);
    (primitives.Class.Accessor{}).set_class_definition(heap_data, compiled_class);
    const class_as_som_object: VmObject = heap_data.as_vm_object();
    // We assert that there was no such global before.
    // This should hold, otherwise we would have looked up the
    // class previously when we were figuring out the class hiearchy above.
    try globals.putNoClobber(compiled_class.class_name, class_as_som_object);

    compiled_class.as_vm_object = class_as_som_object;

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
            while (kw_idx < header_info.number_of_args()) : (kw_idx += 1) {
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

pub const BytecodeGenerator = struct {
    const Self = @This();

    allocator: Allocator,

    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    builder: *InstructionEncoder,
    reporter: *ErrorReporter,

    /// WARN: Do not use!
    /// Invalid between calls to `compile_method`.
    ast: *const ParsedFile = undefined,

    /// WARN: Do not use!
    /// Invalid between calls to `compile_method`.
    scope_stack: *ScopeStack = undefined,

    last_instruction: ?Instruction = null,

    pub fn compile_method(
        self: *Self,
        ast: *const ParsedFile,
        scope_stack: *ScopeStack,
        //
        method_span: Ast.TokenSpan,
        body: Ast.FunctionBody,
        method_header: Ast.MethodHeader,
    ) !InstructionId {
        _ = method_span;

        const start_instruction_id = self.builder.id_of_the_next_instruction();

        self.ast = ast;
        self.scope_stack = scope_stack;
        defer self.ast = undefined;
        defer self.scope_stack = undefined;

        // TODO: think about reporting a warning that a local is shadowing a variable

        // Setup arguments
        // NOTE: Notice how we put index the variables and locals from 1. That is because there is always `self` at index 0.
        var arguments_scope = self.scope_stack.new_scope();
        defer self.scope_stack.pop_scope();
        //
        switch (method_header) {
            .unary => {},
            .binary => |header_info| {
                const parameter_symbol: SymbolId = try self.symbol_from_token(header_info.parameter);
                try arguments_scope.register_variable(.{ .identifier = parameter_symbol, .idx = 1 });
            },
            .keyword => |header_info| {
                var idx: u32 = 0;
                while (idx < header_info.number_of_args()) : (idx += 1) {
                    const parameter_token = header_info.nth_parameter((idx));
                    const parameter_symbol: SymbolId = try self.symbol_from_token(parameter_token);
                    try arguments_scope.register_variable(.{ .identifier = parameter_symbol, .idx = idx + 1 });
                }
            },
        }
        try self.scope_stack.push_scope(arguments_scope);

        // Setup locals
        var locals_scope = self.scope_stack.new_scope();
        defer self.scope_stack.pop_scope();
        //
        var iter = iterator(body.locals);
        var local_idx: u32 = method_header.number_of_arguments_including_self();
        while (iter.next()) |identifier_var_token| : (local_idx += 1) {
            const identifier: SymbolId = try self.symbol_from_token(identifier_var_token);
            try locals_scope.register_variable(.{ .identifier = identifier, .idx = local_idx });
        }
        try self.scope_stack.push_scope(locals_scope);

        // Compile the expressions
        for (body.expressions) |expr_id| {
            // TODO: once we remove `.print` replace it with removal of the last bytecode instruction
            try self.compile_expression(expr_id);
            if (self.last_instruction.?.is_load_instruction()) {
                // TODO: remove the instruction here (or use pop instruction)
            }
            try self.add_instruction(.print);
        }
        // TODO: maybe don't do default `nil` return if we have already emitted a return?

        // TODO(consultation): this is a hack, don't store multiple `nil`s. What to do?
        //                     NOTE: We probably want to store the actual values in the end.
        const constant_id = try self.constants_manager.add_constant(Constant.nil);
        try self.add_instruction(.{ .load_constant = .{ .id = constant_id } });
        try self.add_instruction(.{ .set_local = Instruction.LocalVarId.return_object });
        // TODO: maybe pop instruction here after `set_local`?? ^^^
        // Resolution: I don't think it's needed, since the stack gets popped after `normal_return` has been run.

        try self.add_instruction(.normal_return);

        return start_instruction_id;
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

    fn compile_expression(self: *Self, expr_id: Ast.ExprId) !void {
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
                // TODO: parse escaped special characters from the text here (or make a function for that and use it)
                const text = self.ast.text_at(token_id);
                assert(text.len >= 2); // This assert should not fail, since the string literal must be at least `''`.
                const trimmed_string = text[1 .. text.len - 1];
                const constant_id = try self.constants_manager.add_constant(Constant{ .string = trimmed_string });
                try self.add_instruction(.{ .load_constant = Instruction.LoadConstant{ .id = constant_id } });
            },
            .unary_message_call => |unary_call| {
                try self.compile_expression(unary_call.argument);
                const message_string = self.ast.text_at(unary_call.message);
                const message: SymbolId = (try self.symbols_manager.id_or_intern(message_string)).id;
                try self.add_instruction(Instruction{
                    .send_message = .{ .message_name = message, .aditional_args_count = 0 },
                });
            },
            .binary_message_call => |raw_binary_call| {
                const binary_call = raw_binary_call.decompress(self.ast.extras);

                // NOTE: compile rhs first! (the VM is stack-based -> swap args :D)
                try self.compile_expression(binary_call.rhs);
                try self.compile_expression(binary_call.lhs);
                const message_string = self.ast.text_at(binary_call.message);
                const message: SymbolId = (try self.symbols_manager.id_or_intern(message_string)).id;
                try self.add_instruction(Instruction{
                    .send_message = .{ .message_name = message, .aditional_args_count = 1 },
                });
            },
            .variable => |identifier_token| {
                const identifier_symbol: SymbolId = try self.symbol_from_token(identifier_token);
                const self_symbol: SymbolId = (try self.symbols_manager.id_or_intern("self")).id;
                if (identifier_symbol.idx == self_symbol.idx) {
                    try self.add_instruction(.{ .load_local = .{ .idx = 0 } });
                    return;
                }
                const load_instr: Instruction = switch (self.scope_stack.get_idx_of(identifier_symbol)) {
                    .instance => |instance_var_id| .{ .load_instance_var = instance_var_id },
                    .local_or_method_argument => |local_var_id| .{ .load_local = local_var_id },
                    .global => .{ .load_global = identifier_symbol },
                };
                try self.add_instruction(load_instr);
            },
            .assignment => |info| {
                // TODO: try chained assignment, maybe this does not work???
                try self.compile_expression(info.target_value);
                const idenditifer_text = self.ast.text_at(info.variable);
                const identifier_symbol: SymbolId = try self.symbol_from_token(info.variable);
                const set_instr: Instruction = switch (self.scope_stack.get_idx_of(identifier_symbol)) {
                    .instance => {
                        self.reporter.report_error(
                            .{ .pos = self.ast.pos_of(info.variable) },
                            "TODO: Cannot yet compile setting of an instance variable, therefore could not set the instance variable named '{s}'.",
                            .{idenditifer_text},
                        );
                        return error.TODO;
                    },
                    .local_or_method_argument => |local_var_id| .{ .set_local = local_var_id },
                    .global => {
                        self.reporter.report_error(
                            .{ .pos = self.ast.pos_of(info.variable) },
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
                // TODO: here we will probably have to check, whether we are in an escaped block or not
                try self.add_instruction(.{ .set_local = Instruction.LocalVarId.return_object });
                try self.add_instruction(.normal_return);
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
            .load_constant => {
                const id = self.read_id(RelativeConstantId);
                break :sw Instruction{ .load_constant = .{ .id = id } };
            },
            .load_global => {
                const identifier = self.read_id(SymbolId);
                break :sw Instruction{ .load_global = identifier };
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
            .no_op => break :sw .no_op,
            .duplicate => break :sw .duplicate,
            .halt => break :sw .halt,
            .normal_return => break :sw .normal_return,
            .print => break :sw .print,
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

    pub fn view_bytecode(self: Self) Bytecode {
        return Bytecode{ .bytes = self.bytes.items };
    }

    pub fn id_of_the_next_instruction(self: Self) InstructionId {
        const idx = self.bytes.items.len;
        return InstructionId{ .idx = @truncate(idx) };
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
            // NOTE(epic-zig): comptime assert
            inline else => |payload, tag| {
                if (@TypeOf(payload) != void) {
                    const error_msg = std.fmt.comptimePrint("Missed instruction `{t}` which has non-void payload type `{s}`", .{ tag, @typeName(@TypeOf(payload)) });
                    @compileError(error_msg); // Actually saved me a couple of times :D
                }
            },
        }

        // const bytes_added = self.bytes.items.len - start_len;
        // TODO(consultation): is this nescessary here?
        // Not really I think, if we have a test that handles all instructions at least two times,
        // it doesn't really need to be here.
        // Also there was a problem with the payload being bigger due to p
        // assert(bytes_added == instruction.payload_byte_size() + 1);

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
                    try writer.print(" id({d})\n", .{local_id.idx});
                },
                .set_local => |local_id| {
                    try writer.print(" id({d})\n", .{local_id.idx});
                },
                .load_instance_var => |instance_var_id| {
                    try writer.print(" id({d})\n", .{instance_var_id.idx});
                },
                .load_global => |global_var_id| {
                    const identifier: []const u8 = self.symbols_manager.symbol_with_id(global_var_id);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ identifier, global_var_id.idx });
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

    print, // TODO: remove this after development

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
        pub const self_object = LocalVarId{ .idx = 0 };
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
            .load_constant => true,
            .send_message => false,
            .duplicate => true,
            .halt => false,
            .load_local => true,
            .load_instance_var => true,
            .load_global => true,
            .normal_return => false,
            .set_local => false,
            .print => false,
        };
    }

    pub fn payload_byte_size(self: Self) u8 {
        switch (self) {
            inline else => |payload| {
                return @sizeOf(@TypeOf(payload));
            },
        }
        unreachable;
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
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(0, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{0},
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(1, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(2, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .halt);
    try std.testing.expectEqual(3, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .duplicate);
    try std.testing.expectEqual(4, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, Instruction{
        .load_constant = .{ .id = RelativeConstantId{ .idx = 42 } },
    });
    try std.testing.expectEqual(5, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(8, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, Instruction{ .send_message = .{
        .message_name = SymbolId.new(68),
        .aditional_args_count = 97,
    } });
    try std.testing.expectEqual(9, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0, 2, 97, 68, 0, 0 },
        encoder.view_bytecode().bytes,
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
