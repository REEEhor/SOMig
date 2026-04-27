//! FIXME: Assert that primitive classes don't have any fields and inherit from each other only via `Symbol <: String` (you can actually emit a warning for the second one)
//! FIXME: Check if empty blocks actually return `nil`.
//! FIXME: Check if we are creating an error out of exit being non-last expression
//!
//! FIXME: create an instruction something like "unresolved_super_call", which will be generated when there is a call to a `super` method which does not exits.
//!
//! TODO: Make instruction `load_self`. Or add it to every scope of a block - which is probably already how it is implemented - check it please!

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const terminal = @import("../terminal.zig");

const literals = @import("literals.zig");

const unions = @import("../unions.zig");

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
const OpaqueHeader = interpreter_module.OpaqueHeader;
const ClassDefinition = interpreter_module.ClassDefinition;
const FunctionBody = interpreter_module.FunctionBody;
const PrimitiveMethodsMap = interpreter_module.PrimitiveMethodsMap;
const MethodDefinition = interpreter_module.MethodDefinition;
const MethodBody = interpreter_module.MethodBody;
const HeapData = interpreter_module.HeapData;
const primitives = interpreter_module.primitive_methods;
const Statics = interpreter_module.Statics;
const BuiltinClassDefinitions = interpreter_module.BuiltinClassDefinitions;
const types = interpreter_module.types;

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
pub const RelativeConstantId = packed struct {
    idx: u16,

    pub fn to_absolute(self: @This(), base_id: ConstantId) ConstantId {
        return ConstantId{ .idx = base_id.idx + @as(u32, self.idx) };
    }
};

pub const BlockDefinition = struct {
    body: FunctionBody,

    /// Number of arguments to the `body` of the block **excluding** the receiver object
    /// which is the block itself.
    number_of_aditional_args: u16,
};

pub const ConstantsManager = struct {
    strings: std.ArrayHashMapUnmanaged(*types.String, void, StringObjectContext, true),
    blocks: std.ArrayList(*const BlockDefinition),
    allocator: Allocator,

    /// TODO(speed): make a `init_with_capacity` version or call `ensureCapacity` on `self.constants` for initial capacity
    pub fn init(allocator: Allocator) ConstantsManager {
        return ConstantsManager{
            .allocator = allocator,
            .strings = .empty,
            .blocks = .empty,
        };
    }

    pub fn add_block_definition(self: *Self, block_definition: BlockDefinition) (Allocator.Error || error{too_many_blocks})!BlockDefinitionId {
        if (self.blocks.items.len + 1 > std.math.maxInt(BlockDefinitionId.IdxRepr)) {
            @branchHint(.cold);
            return error.too_many_blocks;
        }
        const block_definition_ptr: *BlockDefinition = try self.allocator.create(BlockDefinition);
        block_definition_ptr.* = block_definition;
        try self.blocks.append(self.allocator, block_definition_ptr);
        return BlockDefinitionId{ .idx = @intCast(self.blocks.items.len - 1) };
    }

    pub fn add_string(self: *Self, string_to_copy: []const u8) (Allocator.Error || error{too_many_string_literals})!StringLiteralId {
        if (self.strings.count() + 1 > std.math.maxInt(StringLiteralId.IdxRepr)) {
            @branchHint(.cold);
            return error.too_many_string_literals;
        }
        const object: VmObject = try types.String.create_new(self.allocator, string_to_copy);
        const string_object: *types.String = object.data.?.asserted_cast_to(.string);
        const insert_result = try self.strings.getOrPut(self.allocator, string_object);

        return StringLiteralId{ .idx = @intCast(insert_result.index) };
    }

    pub fn get_string(self: *Self, string_literal_id: StringLiteralId) *types.String {
        return self.strings.keys()[string_literal_id.idx];
    }

    pub fn get_block(self: *Self, block_id: BlockDefinitionId) *const BlockDefinition {
        return self.blocks.items[block_id.idx];
    }

    const StringObjectContext = struct {
        pub fn hash(_: @This(), str: *types.String) u32 {
            return (std.array_hash_map.StringContext{}).hash(str.contents());
        }
        pub fn eql(_: @This(), lhs: *types.String, rhs: *types.String, b_index: usize) bool {
            return (std.array_hash_map.StringContext{}).eql(lhs.contents(), rhs.contents(), b_index);
        }
    };

    const Self = @This();
};

pub const LexicalScopesStack = struct {
    allocator: Allocator,
    all_variables: std.ArrayList(Variable),
    scopes: std.ArrayList(LexicalScope),

    const Depth = enum(i32) { at_instance_variable_scope = -1, _ };

    const LexicalScope = struct {
        start_idx: usize,
        end_idx: usize,
        depth: Depth,

        pub fn init_empty(params: struct { start_idx: usize, depth: Depth }) LexicalScope {
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

    fn current_depth(self: Self) Depth {
        if (self.scopes.getLastOrNull()) |last_scope| {
            return last_scope.depth;
        }
        return .at_instance_variable_scope;
    }

    pub fn add_scope(self: *Self, params: struct { increase_depth: bool }) Allocator.Error!LexicalScopeHandle {
        const depth: Depth = @enumFromInt(@intFromEnum(self.current_depth()) + @intFromBool(params.increase_depth));
        try self.scopes.append(self.allocator, LexicalScope.init_empty(.{
            .start_idx = self.all_variables.items.len,
            .depth = depth,
        }));
        return LexicalScopeHandle{ .stack = self, .length_check = self.all_variables.items.len, .depth_at_creation = depth };
    }
    /// WARN: Asserts that the lexical scope stack is not empty
    pub fn pop_scope(self: *Self) void {
        assert(self.scopes.items.len != 0);
        const new_length = (self.scopes.pop() orelse unreachable).start_idx;
        self.all_variables.shrinkRetainingCapacity(new_length);
    }

    pub fn lookup_variable(self: Self, identifier: SymbolId) VariableLookup {
        const starting_depth = self.current_depth();
        assert(starting_depth != .at_instance_variable_scope);

        var iter = std.mem.reverseIterator(self.scopes.items);
        while (iter.next()) |current_scope| {
            for (self.all_variables.items[current_scope.start_idx..current_scope.end_idx]) |variable| {
                if (variable.identifier.idx != identifier.idx) continue;
                if (current_scope.depth == .at_instance_variable_scope) {
                    return .{ .instance = .{
                        .instance_variable_id = .{ .idx = variable.idx },
                        .scope_depth_difference = @intCast(@intFromEnum(starting_depth)),
                    } };
                }
                const scope_depth_difference: u32 = @intCast(@intFromEnum(starting_depth) - @intFromEnum(current_scope.depth));
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
            scope_depth_difference: u32,
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
        depth_at_creation: Depth,

        pub fn depth_difference(self: @This()) u32 {
            if (self.depth_at_creation == .at_instance_variable_scope) {
                return 0;
            }
            const starting_depth = self.stack.current_depth();
            return @as(u32, @intCast(@intFromEnum(starting_depth) - @intFromEnum(self.depth_at_creation)));
        }

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
    cached_source_filepaths: Map,
    /// Arena used for storing the `cached_source_filepaths`, including the owned filepaths in it.
    arena: std.heap.ArenaAllocator,
    root_directories: []const Directory,

    /// Mapping from: class name to: class name filepath
    pub const Map = std.AutoArrayHashMapUnmanaged(SymbolId, []const u8);

    pub const Directory = struct {
        path: []const u8,
        can_be_searched_recursively: bool,
    };

    pub fn init(params: struct {
        allocator: Allocator,
        root_directories: []const Directory,
    }) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(params.allocator),
            .root_directories = params.root_directories,
            .cached_source_filepaths = .empty,
        };
    }
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub const LookupError = RefreshError;
    pub const LookupResult = struct {
        source_code: []const u8,
        filepath: []const u8,
    };
    pub fn get_source_code_of(self: *Self, class_name: SymbolId, source_code_allocator: Allocator, refresh_params: RefreshParams) LookupError!?LookupResult {
        var retry_count: i32 = 0;
        const max_retry_count = 1;
        const filepath = while (retry_count <= max_retry_count) : (retry_count += 1) {
            if (self.cached_source_filepaths.get(class_name)) |filepath| break filepath;
            try self.refresh_cached_filepaths(refresh_params);
        } else return null;

        const source_code: []const u8 = get_src: {
            var file = std.fs.cwd().openFile(filepath, .{ .mode = .read_only }) catch |err| break :get_src err;
            defer file.close();
            break :get_src file.readToEndAlloc(source_code_allocator, 1 << 32);
        } catch |err| {
            refresh_params.error_reporter.report_error(
                .no_location,
                "Could not open '{s}' (which should contain the class '{s}') because: {t}.",
                .{ filepath, refresh_params.symbols_manager.symbol_with_id(class_name), err },
            );
            return null;
        };

        return .{ .source_code = source_code, .filepath = filepath };
    }

    pub const RefreshError = Allocator.Error;
    pub const RefreshParams = struct {
        temporary_allocator: Allocator,
        symbols_manager: *SymbolsManager,
        /// For reporting duplicate errors and file errors
        error_reporter: *ErrorReporter,
    };
    pub fn refresh_cached_filepaths(
        self: *Self,
        params: RefreshParams,
    ) RefreshError!void {

        // Free all the cached entries
        _ = self.arena.reset(.retain_capacity);
        self.cached_source_filepaths = .empty;

        for (self.root_directories) |directory| {
            var root_dir = std.fs.cwd().openDir(directory.path, .{ .iterate = true }) catch |err| {
                params.error_reporter.report_error(.no_location, "Error while opening the directory '{s}': {t}.", .{ directory.path, err });
                return;
            };
            if (directory.can_be_searched_recursively) {
                try self.refresh_single_directory_recursively(&root_dir, directory.path, params);
            } else {
                try self.refresh_single_directory(&root_dir, directory.path, params);
            }
        }
    }
    fn refresh_single_directory_recursively(self: *Self, root_dir: *std.fs.Dir, root_dir_name: []const u8, params: RefreshParams) !void {
        const temporary_allocator = params.temporary_allocator;
        const symbols_manager = params.symbols_manager;
        const error_reporter = params.error_reporter;
        defer root_dir.close();
        var walker = try root_dir.walk(temporary_allocator);
        defer walker.deinit();
        while (true) {
            const entry = walker.next() catch |err| {
                // TODO: if we ever have warnings, they would be nice here
                error_reporter.add_note(.no_location, "Had to skip an entry while looking up classes in '{s}', because of error: {t}.", .{ root_dir_name, err });
                continue;
            } orelse break;
            if (entry.kind != .file) continue;
            const file_ending = ".som";
            if (!std.mem.endsWith(u8, entry.basename, file_ending)) continue;
            const class_name = entry.basename[0 .. entry.basename.len - file_ending.len];
            const class_name_as_symbol: SymbolId = (try symbols_manager.id_or_intern(class_name)).id;
            const owned_path: []const u8 = root_dir.realpathAlloc(self.arena.allocator(), entry.path) catch |err| switch (err) {
                Allocator.Error.OutOfMemory => return Allocator.Error.OutOfMemory,
                else => {
                    error_reporter.report_error(
                        .no_location,
                        "Had to skip an while looking up classes in '{s}/{s}', because of error: {t}.",
                        .{ root_dir_name, entry.path, err },
                    );
                    continue;
                },
            };
            const gop = try self.cached_source_filepaths.getOrPut(self.arena.allocator(), class_name_as_symbol);
            if (gop.found_existing) {
                error_reporter.report_error(
                    .no_location,
                    "Found the same class definition for '{s}' in multiple files. First '{s}' and now '{s}'. Ignoring the later entry.",
                    .{ class_name, gop.value_ptr.*, owned_path },
                );
            } else {
                gop.value_ptr.* = owned_path;
            }
        }
    }

    fn refresh_single_directory(self: *Self, root_dir: *std.fs.Dir, root_dir_name: []const u8, params: RefreshParams) RefreshError!void {
        const symbols_manager = params.symbols_manager;
        const error_reporter = params.error_reporter;
        defer root_dir.close();
        var iterator = root_dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                // TODO: if we ever have warnings, they would be nice here
                error_reporter.add_note(.no_location, "Had to skip an entry while looking up classes in '{s}', because of error: {t}.", .{ root_dir_name, err });
                continue;
            } orelse break;
            if (entry.kind != .file) continue;
            const file_ending = ".som";
            if (!std.mem.endsWith(u8, entry.name, file_ending)) continue;
            const class_name = entry.name[0 .. entry.name.len - file_ending.len];
            const class_name_as_symbol: SymbolId = (try symbols_manager.id_or_intern(class_name)).id;
            const owned_path: []const u8 = root_dir.realpathAlloc(self.arena.allocator(), entry.name) catch |err| {
                // TODO: if we ever have warnings, they would be nice here
                error_reporter.add_note(.no_location, "Had to skip an entry while looking up classes in '{s}', because of error: {t}.", .{ root_dir_name, err });
                continue;
            };
            const gop = try self.cached_source_filepaths.getOrPut(self.arena.allocator(), class_name_as_symbol);
            if (gop.found_existing) {
                error_reporter.report_error(
                    .no_location,
                    "Found the same class definition for '{s}' in multiple files. First '{s}' and now '{s}'. Ignoring the later entry.",
                    .{ class_name, gop.value_ptr.*, owned_path },
                );
            } else {
                gop.value_ptr.* = owned_path;
            }
        }
    }

    const Self = @This();
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
    assert(class.identifiers_of_instance_variables.len == 0);

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
        .source = undefined,
        .source_path = null,
        .use_color = true,
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
pub const CompileClassIgnoringParents = struct {
    class_name: SymbolId,
    statics: *Statics,
    temporary_allocator: Allocator,
    source_code_files: *SourceCodeFiles,
    error_writer: *std.io.Writer,
    primitive_methods_map: PrimitiveMethodsMap,
    /// Used for lookup of class definitions.
    globals: *std.AutoArrayHashMap(SymbolId, VmObject),
    metaclass_definition: ?*ClassDefinition,
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
    const metaclass_definition = params.metaclass_definition;

    const ast = try find_file_and_parse_it(class_name, source_code_files, statics, error_writer, temporary_allocator);
    var reporter = ErrorReporter{
        .source = ast.source_code,
        .source_path = ast.source_code_filepath,
        .use_color = true,
        .writer = error_writer,
    };
    const class_pair = try compile_class(
        ast,
        class_name,
        null,
        temporary_allocator,
        statics,
        &reporter,
        primitive_methods_map,
        globals,
        metaclass_definition,
    );
    return class_pair;
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
            //                                                               FIXME: Fix these comments (the "potential" part) after done with implementation
            .nil = try self.load_builtin_class("Nil", .{ .can_inherit_from_whatever = true }), // Cannot have fields due to potential nan-boxing
            .true = try self.load_builtin_class("True", .{ .can_inherit_from_whatever = true }), // Cannot have fields due to potential nan-boxing
            .false = try self.load_builtin_class("False", .{ .can_inherit_from_whatever = true }), // Cannot have fields due to potential nan-boxing
            .system = try self.load_builtin_class("System", .{ .can_inherit_from_whatever = true, .can_have_fields = true }),
            .integer = try self.load_builtin_class("Integer", .{}),
            .double = try self.load_builtin_class("Double", .{}),
            .array = try self.load_builtin_class("Array", .{}),
            .string = try self.load_builtin_class("String", .{}),
            .symbol = try self.load_builtin_class("Symbol", .{ .expected_parent_apart_from_none_or_object = "String" }),
            .block1 = try self.load_builtin_class("Block1", .{ .expected_parent_apart_from_none_or_object = "Block" }),
            .block2 = try self.load_builtin_class("Block2", .{ .expected_parent_apart_from_none_or_object = "Block" }),
            .block3 = try self.load_builtin_class("Block3", .{ .expected_parent_apart_from_none_or_object = "Block" }),
            .method = try self.load_builtin_class("Method", .{}),
            .primitive = try self.load_builtin_class("Primitive", .{}),
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
        var reporter = ErrorReporter{ .source = undefined, .source_path = null, .use_color = true, .writer = self.error_writer };
        reporter.report_error(.no_location, "Could not load the builtin class {s}.", .{class_name});
        return err;
    }

    fn report_if_class_has_invalid_parent(self: *Self, class: *ClassDefinition, expected_parent_apart_from_none_or_object: ?[]const u8) void {
        var reporter = ErrorReporter{ .source = undefined, .source_path = null, .use_color = true, .writer = self.error_writer };
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
        const object_ast: ParsedFile = try self.parse_file(SymbolsManager.comptime_id_of("Object"));
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

    fn set_is_instance_of(self: *Self, instance: *ClassDefinition, class_of_instance: *ClassDefinition) !void {
        const vm_object: VmObject = try types.Class.create_new(self.statics, .{
            .class_fields_count = @intCast(class_of_instance.identifiers_of_instance_variables.len),
            .represented_class = instance,
            .class_of_represented_class = class_of_instance,
        });
        const class_object: *types.Class = vm_object.as(.class).?;
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
        var reporter = ErrorReporter{ .source = undefined, .source_path = null, .use_color = true, .writer = self.error_writer };
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
            .use_color = true,
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
            .use_color = true,
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
            .use_color = true,
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
};

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
    const metaclass_definition = params.metaclass_definition;

    var error_reporter = ErrorReporter{
        .source = undefined,
        .source_path = undefined,
        .use_color = true,
        .writer = error_writer,
    };

    // TODO(cleanup): re-write this using a single while loop (actually a do-while would be better), it should be possible

    const bottom_ast: ParsedFile = try find_file_and_parse_it(bottom_class_name, source_code_files, statics, error_writer, temporary_allocator);
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
            if (parent_definition.as(.class)) |class| {
                break class.represented_class;
            }
            report_parent_is_not_a_class(&error_reporter, classes_to_compile.getLast().ast, parent_definition, statics.symbols_manager);
            return error.parent_is_not_a_class;
        }
        const parent_ast: ParsedFile = try find_file_and_parse_it(parent_being_resolved, source_code_files, statics, error_writer, temporary_allocator);
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
            switch (self.object.kind()) {
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

    // TODO: after development, increase these numbers
    var lexical_scopes = try LexicalScopesStack.init(temporary_allocator, 0, 0);

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

    // TODO: consider putting this into the `SymbolsManager`?
    var buffer_for_selectors: [512]u8 = undefined;
    var selector_writer = std.io.Writer.fixed(&buffer_for_selectors);

    var method_idx: usize = 0;
    for (ast_portion.methods) |method_ast| {
        const method_selector: SymbolId = try get_selector_symbol(method_ast.header, &selector_writer, ast, statics, reporter);

        switch (method_ast.body) {
            .primitive => {
                const primitive_class = maybe_primitive_class orelse {
                    // TODO: add `report_warning` to the reporter
                    const class_name = ast.text_at(ast.class_ast.class_name);
                    const method_selector_text = statics.symbols_manager.symbol_with_id(method_selector);
                    reporter.report_error(
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
                    // TODO: add `report_warning` to the reporter
                    const class_name = ast.text_at(ast.class_ast.class_name);
                    const method_selector_text = statics.symbols_manager.symbol_with_id(method_selector);
                    reporter.report_error(
                        .{ .pos = ast.pos_of(method_ast.span) },
                        "The class '{s}' has the method '{s}' declared as `primitive`, but the virtual machine does not have such primitive method implementation.",
                        .{ class_name, method_selector_text },
                    );
                    reporter.add_note(
                        .no_location,
                        "The method '{s}' will not be compiled into the class.",
                        .{method_selector_text},
                    );
                    // TODO: print available methods on such class
                    continue;
                };

                const new_method_ptr: *MethodDefinition = try statics.all_methods.addOne(statics.allocator);
                new_method_ptr.* = MethodDefinition{
                    .method_name = method_selector,
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
                    .method_name = method_selector,
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
                selector_writer.end = 0;
                const selector = get_selector_symbol(method_ast.header, &selector_writer, ast, statics, reporter) catch unreachable;
                if (selector.idx != duplicate_method_selector.idx) continue;
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

pub fn get_selector_symbol(
    method_header: Ast.MethodHeader,
    fixed_writer: *std.io.Writer,
    ast: ParsedFile,
    statics: *Statics,
    reporter: *ErrorReporter,
) !SymbolId {
    const method_selector_text: []const u8 = sw: switch (method_header) {
        .unary => |header_info| {
            break :sw ast.text_at(header_info.selector);
        },
        .binary => |header_info| {
            break :sw ast.text_at(header_info.selector);
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
    too_many_arguments_in_a_block,
    invalid_string_literal,
    invalid_integer_literal,
    too_many_string_literals,
    too_many_blocks,
    /// FIXME: This shouldn't be here at the end of implementation
    TODO,
} || Allocator.Error;

pub const BytecodeGenerator = struct {
    const Self = @This();

    allocator: Allocator,
    temporary_allocator: Allocator,

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

    currently_compiling_block: bool = false,

    last_instruction: ?Instruction = null,

    pub fn init(params: struct {
        allocator: Allocator,
        temporary_allocator: Allocator,
        symbols_manager: *SymbolsManager,
        constants_manager: *ConstantsManager,
        reporter: *ErrorReporter,
    }) Self {
        return Self{
            .allocator = params.allocator,
            .temporary_allocator = params.temporary_allocator,
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
        // TODO: consider pre-allocating a chuck of bytes
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
            try arguments_scope.register_variable(.{
                .identifier = SymbolsManager.comptime_id_of("super"),
                .idx = method_header.number_of_arguments_including_self() - 1,
            });
        }
        defer self.lexical_scope_stack.pop_scope();

        const bytecode: Bytecode = try self.compile_function_body(.{
            .body = body,
            .number_of_arguments_including_self = method_header.number_of_arguments_including_self(),
        });
        return bytecode;
    }

    fn compile_function_body(
        self: *Self,
        params: struct {
            body: Ast.FunctionBody,
            number_of_arguments_including_self: u32,
        },
    ) CompileError!Bytecode {
        const body = params.body;
        const number_of_arguments_including_self = params.number_of_arguments_including_self;

        // Register local variables into the lexical scope
        {
            // Locals live on the same stackframe as arguments => `.increase_depth = false`
            var locals_scope = try self.lexical_scope_stack.add_scope(.{ .increase_depth = false });
            //
            var local_idx: u32 = number_of_arguments_including_self;
            var iter = token_iterator(body.locals);
            while (iter.next()) |identifier_var_token| : (local_idx += 1) {
                const identifier: SymbolId = try self.symbol_from_token(identifier_var_token);
                try locals_scope.register_variable(.{ .identifier = identifier, .idx = local_idx });
            }
        }
        defer self.lexical_scope_stack.pop_scope();

        // Compile the expressions
        for (body.expressions, 0..) |expr_id, idx| {
            // Compile the expression. The generated bytecode leaves the result value on the top of the stack.
            try self.compile_expression(expr_id);

            // Most of the times, we want to get rid of the value from the compiled expression (pop it from the stack).
            // But we also want to keep the value on the top of the stack in a case we are compiling
            // a block, since we need it for the default return (normal return) of that block.
            const compiled_last_expression: bool = ((idx + 1) == body.expressions.len);
            const keep_value_on_the_stack: bool = (self.currently_compiling_block and compiled_last_expression);
            if (!keep_value_on_the_stack) {
                // TODO: use `self.last_instruction.(somehow unwrap ?).is_load_instruction() => remove_last_instruction()` instead of emitting pop here
                try self.add_instruction(.pop);
            }
        }
        // We want to generate a default return in case when there was not a return already generated.
        // TODO: It might be possible to look at `body.expressions[last] == .exit_expression` to not generate this.
        // WARN: But be careful! We have also check that somehow in the `for` loop above.
        // WARN: Also, if we do the check in a way that is mentioned, we have throw a compile error on dead code after exit expressions (returns) (Which we are not doing currently.)

        if (!self.currently_compiling_block) {
            try self.add_instruction(.{ .load_local = .{
                .local_id = .{ .idx = number_of_arguments_including_self - 1 },
                .required_frame_up_steps = 0,
            } });
        } else {
            // In case we are compiling a block, we left the value on the top of the stack already.
        }
        try self.add_instruction(.normal_return);

        return try self.builder.get_final_bytecode(self.allocator);
    }

    fn symbol_from_block_parameter_token(self: *Self, token_id: Ast.TokenId) Allocator.Error!SymbolId {
        assert(self.ast.kind_of(token_id) == .block_param);
        const token_text = self.ast.text_at(token_id);
        assert(token_text.len >= 2);
        assert(token_text[0] == ':');
        const identifier_text = token_text[1..];
        const symbol_id: SymbolId = (try self.symbols_manager.id_or_intern(identifier_text)).id;
        return symbol_id;
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

    fn compile_message_send(self: *Self, receiver_id: Ast.ExprId, message_selector: SymbolId) CompileError!void {
        const receiver: Ast.Expression = self.ast.get_expr(receiver_id);
        const is_receiver_super = switch (receiver) {
            .variable => |identifier_token| std.mem.eql(u8, self.ast.text_at(identifier_token), "super"),
            else => false,
        };

        if (!is_receiver_super) {
            try self.compile_expression(receiver_id);
            try self.add_instruction(Instruction{
                .send_message = .{ .message_name = message_selector },
            });
            return;
        }

        // We have to compile a call to a method in the super class
        const parent_methods = if (self.compiled_parent_methods) |methods| methods else {
            self.reporter.report_error(.{ .pos = self.ast.pos_of(receiver_id) }, "Referencing `super` inside a class without a parent class.", .{});
            return CompileError.super_call_in_class_without_parent;
        };
        const method_ptr: *const MethodDefinition = parent_methods.get(message_selector) orelse {
            // SAFETY: we can access `self.ast.class_ast.super_class_name.?` because the current class has a parent in this branch of code (we are currently compiling a call to a method from the parent)
            const position_of_parent_declaration = self.ast.pos_of(self.ast.class_ast.parent_class_name.?);
            const parent_name = self.ast.text_at(position_of_parent_declaration);
            const selector_as_string = self.symbols_manager.symbol_with_id(message_selector);
            self.reporter.report_error(.{ .pos = self.ast.pos_of(receiver_id) }, "Call to a `super` with method `{s}`, but the parent class is `{s}`, which doesn't have that method defined.", .{ selector_as_string, parent_name });
            self.reporter.add_note(.{ .pos = position_of_parent_declaration }, "The parent is defined here.", .{});
            return CompileError.could_not_find_method_in_parent;
        };
        const local_self = self.lexical_scope_stack.lookup_variable(SymbolsManager.comptime_id_of("self")).local_or_method_argument;
        try self.add_instruction(Instruction{ .load_local = .{
            .required_frame_up_steps = local_self.scope_depth_difference,
            .local_id = local_self.local_variable_id,
        } });
        try self.add_instruction(Instruction{
            .resolved_method_call = .{ .method_ptr = SmallPtr(*const MethodDefinition).new(method_ptr) },
        });
    }

    fn compile_expression(self: *Self, expr_id: Ast.ExprId) CompileError!void {
        const expr = self.ast.expressions.get(expr_id);
        switch (expr) {
            .integer_literal => |literal_info| {
                const text = self.ast.text_at(literal_info.absolute_value_token);
                var number: i48 = literals.parse_integer_literal(text) orelse {
                    // TODO: Change how we parse this if we implement arbitrary-sized integers.
                    self.reporter.report_error(
                        .{ .pos = self.ast.pos_of(expr_id) },
                        "This integer literal is too big to fit into the VM representation of integers, which is 48 bits. The valid range is from {d} to {d}.",
                        .{ std.math.minInt(i48), std.math.maxInt(i48) },
                    );
                    return CompileError.invalid_integer_literal;
                };
                if (literal_info.is_negative) number *= -1;

                if (std.math.cast(i8, number)) |number_i8| {
                    try self.add_instruction(.{ .load_integer_i8 = number_i8 });
                } else {
                    try self.add_instruction(.{ .load_integer_i48 = number });
                }
            },
            .float_literal => |literal_info| {
                const text = self.ast.text_at(literal_info.absolute_value_token);
                var number: f64 = literals.parse_float_literal(text);
                if (literal_info.is_negative) number *= -1;
                try self.add_instruction(.{ .load_double = number });
            },
            .string_literal => |token_id| {
                const string: []const u8 = try self.parse_string_literal(self.temporary_allocator, token_id);
                const string_literal_id: StringLiteralId = self.constants_manager.add_string(string) catch |err| {
                    if (err == error.too_many_string_literals) {
                        self.reporter.report_error(.{ .pos = self.ast.pos_of(token_id) }, "Too many string literals in the codebase (>{d}).", .{std.math.maxInt(StringLiteralId.IdxRepr)});
                    }
                    return err;
                };
                try self.add_instruction(.{ .load_string = string_literal_id });
            },
            .unary_message_send => |unary_call| {
                const message_symbol: SymbolId = try self.symbol_from_token(unary_call.message);
                try self.compile_message_send(unary_call.argument, message_symbol);
            },
            .binary_message_send => |raw_binary_call| {
                const binary_call = raw_binary_call.decompress(self.ast.extras);
                const message_symbol: SymbolId = try self.symbol_from_token(binary_call.message);

                // The calling convention mandates that the order of the arguments is
                // pushed onto the stack in the *REVERSE* order in comparison to the
                // order of the arguments in code.
                try self.compile_expression(binary_call.rhs);
                try self.compile_message_send(binary_call.lhs, message_symbol);
            },
            .keyword_message_send => |keyword_message_call| {
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
                        break :sw .{ .load_instance_var = .{
                            .instance_var_id = info.instance_variable_id,
                        } };
                    },
                    .local_or_method_argument => |info| {
                        break :sw .{ .load_local = .{
                            .local_id = info.local_variable_id,
                            .required_frame_up_steps = info.scope_depth_difference,
                        } };
                    },
                    .global => break :sw .{ .load_global = identifier_symbol },
                };
                try self.add_instruction(load_instr);
            },
            .assignment => |assignment| {
                try self.compile_expression(assignment.target_value);
                const identifier_symbol: SymbolId = try self.symbol_from_token(assignment.variable);
                const set_instr: Instruction = switch (self.lexical_scope_stack.lookup_variable(identifier_symbol)) {
                    .instance => |info| .{ .set_instance_var = .{
                        .instance_var_id = info.instance_variable_id,
                    } },
                    .local_or_method_argument => |info| .{ .set_local = .{
                        .local_id = info.local_variable_id,
                        .required_frame_up_steps = info.scope_depth_difference,
                    } },
                    .global => .{ .set_global = identifier_symbol },
                };
                try self.add_instruction(set_instr);
            },
            .exit_expression => |exit_expr| {
                try self.compile_expression(exit_expr.return_value);
                if (self.currently_compiling_block) {
                    try self.add_instruction(.non_local_return);
                } else {
                    try self.add_instruction(.normal_return);
                }
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
                assert(std.mem.eql(u8, "#", self.ast.text_at(original_tokens_span.start_id)));
                //
                const token_span = Ast.TokenSpan.create(original_tokens_span.start_id.idx + 1, original_tokens_span.end_id.idx);
                var symbol_as_string = self.ast.text_at(token_span);
                if (self.ast.kind_of(token_span.start_id) == .string_literal) {
                    assert(token_span.number_of_tokens() == 1);
                    symbol_as_string = try self.parse_string_literal(self.temporary_allocator, token_span.start_id);
                }
                const symbol_id = (try self.symbols_manager.id_or_intern(symbol_as_string)).id;
                try self.add_instruction(.{ .load_symbol = symbol_id });
            },
            .block_literal => |block_info| {
                const block_id: BlockDefinitionId = try self.compile_block_literal(block_info, expr_id);
                try self.add_instruction(.{ .load_block = block_id });
            },
        }
    }

    fn parse_string_literal(self: *Self, allocator: Allocator, token_id: Ast.TokenId) CompileError![]const u8 {
        assert(self.ast.kind_of(token_id) == .string_literal);
        const text = self.ast.text_at(token_id);
        const string: []const u8 = sw: switch (try literals.parse_string_literal(allocator, text)) {
            .ok => |result| break :sw result.parsed_owned_string,
            .invalid_escape_sequence => |info| {
                self.reporter.report_error(
                    .{ .pos = self.ast.pos_of(token_id) },
                    "This string literal contains invalid escape code \"{s}\".",
                    .{info.invalid_sequence},
                );
                return CompileError.invalid_string_literal;
            },
            .invalid_hex_code => |info| {
                self.reporter.report_error(
                    .{ .pos = self.ast.pos_of(token_id) },
                    "This string literal contains invalid escaped hex code \"{s}\".",
                    .{info.invalid_hex_code},
                );
                return CompileError.invalid_string_literal;
            },
        };
        return string;
    }

    fn compile_block_literal(self: *Self, block_literal: Ast.BlockLiteral, block_expr_id: Ast.ExprId) CompileError!BlockDefinitionId {
        const old_are_we_compiling_block_right_now = self.currently_compiling_block;
        defer self.currently_compiling_block = old_are_we_compiling_block_right_now;
        self.currently_compiling_block = true;

        // We have to use a brand new `InstructionEncoder` for the compilation of the block literal.
        const old_builder = self.builder;
        defer self.builder = old_builder;
        self.builder = InstructionEncoder{ .bytes = .empty }; // TODO: pre-allocate some bytes up front

        // Setup arguments (put them into the lexical scope stack)
        const parameters_span: ?Ast.TokenSpan = block_literal.get_parameters(self.ast.tokens);
        const parameters_count_excluding_self = if (parameters_span) |s| s.number_of_tokens() else 0;
        const max_block_parameters_count = 2;
        if (parameters_count_excluding_self > max_block_parameters_count) {
            // SAFETY: We can unwrap `.?` the `parameters_span` because the number of parameters is more than 2.
            //         This means, that the `parameters_span` is not empty.
            const parameters_position = self.ast.pos_of(parameters_span.?);
            self.reporter.report_error(.{ .pos = parameters_position }, "This block has {d} parameters, which is too many. Maximum is {d}.", .{ parameters_count_excluding_self, max_block_parameters_count });
            self.reporter.add_note(.no_location, "Consider taking the arguments as a single array argument with {d} elements.", .{parameters_count_excluding_self});
            return CompileError.too_many_arguments_in_a_block;
        }
        // Register block parameter identifiers as arguments in the lexical scope stack
        {
            var arguments_scope = try self.lexical_scope_stack.add_scope(.{ .increase_depth = true });
            var parameter_iterator = token_iterator(parameters_span);
            // We want to register the identifiers with reverse indexes
            var idx: i64 = @as(i64, parameters_count_excluding_self) - 1;
            while (parameter_iterator.next()) |parameter_token| : (idx -= 1) {
                const parameter_symbol: SymbolId = try self.symbol_from_block_parameter_token(parameter_token);
                try arguments_scope.register_variable(.{ .identifier = parameter_symbol, .idx = @intCast(idx) });
            }
        }
        defer self.lexical_scope_stack.pop_scope();

        const body_ast: Ast.FunctionBody = self.ast.extras.function_body_of(block_literal.body_id);
        const bytecode = try self.compile_function_body(.{
            .body = body_ast,
            .number_of_arguments_including_self = parameters_count_excluding_self + 1,
        });

        const block_id = self.constants_manager.add_block_definition(BlockDefinition{
            .body = FunctionBody{
                .bytecode = bytecode,
                .number_of_locals = @intCast(body_ast.number_of_locals()),
            },
            .number_of_aditional_args = @intCast(parameters_count_excluding_self),
        }) catch |err| {
            if (err == error.too_many_blocks) {
                self.reporter.report_error(.{ .pos = self.ast.pos_of(block_expr_id) }, "Too many blocks in the codebase (>{d}).", .{std.math.maxInt(BlockDefinitionId.IdxRepr)});
            }
            return err;
        };
        return block_id;
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

    pub fn fetch_instruction(self: *Self) ?Fetch {
        if (self.is_at_end()) {
            // The code should actually never hit the end.
            // There will always be a `normal_return` or `non_local_return` instruction at the end.
            @branchHint(.cold);
            return null;
        }
        const tag_byte: u8 = self.read_byte();
        const runtime_tag: Instruction.Tag = @enumFromInt(tag_byte);
        return runtime_tag;
    }

    /// return null -> decoder is at the end of the bytecode
    pub inline fn next_instruction(self: *Self) ?Instruction {
        const fetch = self.fetch_instruction() orelse return null;
        switch (fetch) {
            inline else => |access, tag| {
                const payload = access.get(self);
                const instruction = @unionInit(Instruction, @tagName(tag), payload);
                return instruction;
            },
        }
        unreachable;
    }

    pub fn decode_type(self: *Self, comptime ToDecode: type) ToDecode {
        return switch (@typeInfo(ToDecode)) {
            .void => return,
            .int => self.read_integer(ToDecode),
            .float => self.read_float(ToDecode),
            .@"struct" => |struct_info| blk: {
                const BackingInteger: type = struct_info.backing_integer orelse @compileError(std.fmt.comptimePrint(
                    "Cannot decode the struct `{s}`, because it is not a packed struct.",
                    .{@typeName(ToDecode)},
                ));
                const result_raw = self.read_integer(BackingInteger);
                break :blk @as(ToDecode, @bitCast(result_raw));
            },
            else => @compileError(std.fmt.comptimePrint(
                "Cannot decode the type `{s}` (which is `{t}`). Expected either a `void`, an integer or a struct.",
                .{ @typeName(ToDecode), @typeInfo(ToDecode) },
            )),
        };
    }

    pub inline fn read_byte(self: *Self) u8 {
        assert(self.next_idx < self.bytes.len);
        self.next_idx += 1;
        return self.bytes[self.next_idx - 1];
    }

    pub inline fn read_float(self: *Self, comptime FloatType: type) FloatType {
        const bits = self.read_integer(IntWithTheSameBitsCountAsFloat(FloatType));
        return @bitCast(bits);
    }

    pub inline fn read_integer(self: *Self, comptime IntegerType: type) IntegerType {
        const byte_size = @divExact(@typeInfo(IntegerType).int.bits, 8);
        assert(self.next_idx + byte_size <= self.bytes.len); // NOTE the `<=` here!

        const bytes = self.bytes[self.next_idx .. self.next_idx + byte_size];
        const result = std.mem.readVarInt(IntegerType, bytes, .little);

        self.next_idx += byte_size;
        return result;
    }

    pub fn Accessor(comptime instruction_tag: Instruction.Tag) type {
        const Payload: type = @FieldType(Instruction, @tagName(instruction_tag));
        return struct {
            pub fn get(_: @This(), decoder: *InstructionDecoder) Payload {
                return switch (@typeInfo(Payload)) {
                    .void => return,
                    .int => decoder.read_integer(Payload),
                    .float => decoder.read_float(Payload),
                    .@"struct" => |struct_info| blk: {
                        const BackingInteger: type = struct_info.backing_integer orelse @compileError(std.fmt.comptimePrint(
                            "Cannot decode the struct `{s}`, because it is not a packed struct.",
                            .{@typeName(Payload)},
                        ));
                        const result_raw = decoder.read_integer(BackingInteger);
                        break :blk @as(Payload, @bitCast(result_raw));
                    },
                    else => @compileError(std.fmt.comptimePrint(
                        "Cannot decode the type `{s}` (which is `{t}`). Expected either a `void`, an integer or a struct.",
                        .{ @typeName(Payload), @typeInfo(Payload) },
                    )),
                };
            }
        };
    }

    pub const Fetch = blk: {
        const instruction_info = @typeInfo(Instruction).@"union";
        const Type = std.builtin.Type;
        var fields: [instruction_info.fields.len]Type.UnionField = undefined;
        for (instruction_info.fields, 0..) |field, idx| {
            fields[idx] = Type.UnionField{
                .name = field.name,
                .type = Accessor(@enumFromInt(idx)),
                .alignment = @alignOf(void),
            };
        }
        break :blk @Type(.{ .@"union" = .{
            .tag_type = Instruction.Tag,
            .decls = &.{},
            .layout = .auto,
            .fields = &fields,
        } });
    };
};

fn IntWithTheSameBitsCountAsFloat(comptime Float: type) type {
    const bits_count = @typeInfo(Float).float.bits;
    return std.meta.Int(.unsigned, bits_count);
}

fn bit_cast_float_to_int(float: anytype) IntWithTheSameBitsCountAsFloat(@TypeOf(float)) {
    return @bitCast(float);
}

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
            inline else => |payload| try self.encode_value(allocator, @TypeOf(payload), payload),
        }
        const bytes_added = self.bytes.items.len - instruction_id.idx;
        assert(bytes_added == instruction.bytecode_size_in_bytes());

        return instruction_id;
    }

    fn encode_value(self: *Self, allocator: Allocator, comptime Value: type, to_encode: Value) Allocator.Error!void {
        _ = std.builtin.Type;
        switch (@typeInfo(Value)) {
            .void => return,
            .int => try self.write_integer(allocator, to_encode),
            .float => try self.write_float(allocator, to_encode),
            .@"struct" => |struct_info| {
                const BackingInteger: type = struct_info.backing_integer orelse @compileError(std.fmt.comptimePrint(
                    "Cannot encode the struct `{s}`, because it is not a packed struct.\nThe thought behind that we can just dump the struct into the memory, which is faster.",
                    .{@typeName(Value)},
                ));
                const value_raw = @as(BackingInteger, @bitCast(to_encode));
                try self.write_integer(allocator, value_raw);
            },
            else => @compileError(std.fmt.comptimePrint(
                "Cannot encode the type `{s}` (which is `{t}`). Available types to encode are `void`, an integer, a float or a struct.",
                .{ @typeName(Value), @typeInfo(Value) },
            )),
        }
    }

    fn write_float(self: *Self, allocator: Allocator, float: anytype) Allocator.Error!void {
        const raw = bit_cast_float_to_int(float);
        return self.write_integer(allocator, raw);
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
    use_color: bool,

    pub fn fmt(self: @This(), instruction: Instruction) Fmt {
        return Fmt{
            .instruction = instruction,
            //
            .constants_manager = self.constants_manager,
            .symbols_manager = self.symbols_manager,
            .use_color = self.use_color,
        };
    }

    const Fmt = struct {
        const Writer = std.io.Writer;
        symbols_manager: *SymbolsManager,
        constants_manager: *ConstantsManager,
        instruction: Instruction,
        use_color: bool,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const tag_name: []const u8 = @tagName(self.instruction.tag());
            if (self.use_color) try writer.print(terminal.BOLD, .{});
            try writer.print("{s:<13}", .{tag_name});
            if (self.use_color) try writer.print(terminal.RESET, .{});

            switch (self.instruction) {
                .load_integer_i8 => |integer_value| {
                    try writer.print(" {d}", .{integer_value});
                },
                .load_integer_i48 => |integer_value| {
                    try writer.print(" {d}", .{integer_value});
                },
                .load_double => |double_value| {
                    try writer.print(" {d}", .{double_value});
                },
                .load_string => |string_literal_id| {
                    const string_object = self.constants_manager.get_string(string_literal_id);
                    try writer.print(" ", .{});
                    try print_escaped_string(writer, string_object.contents());
                    try writer.print(" ", .{});
                },
                .load_block => |block_id| {
                    const block_info = self.constants_manager.get_block(block_id);
                    try writer.print(
                        "block id{d} body-arguments-cnt={d} locals-cnt={d}",
                        .{
                            block_id.idx,
                            block_info.number_of_aditional_args,
                            block_info.body.number_of_locals,
                        },
                    );
                },
                .send_message => |send_message| {
                    const message_name = self.symbols_manager.symbol_with_id(send_message.message_name);
                    try writer.print(" selector=\"{s}\"", .{message_name});
                },
                .load_local => |info| {
                    try writer.print(" id({d}) up-frame-steps={d}", .{ info.local_id.idx, info.required_frame_up_steps });
                },
                .set_local => |info| {
                    try writer.print(" id({d}) up-frame-steps={d}", .{ info.local_id.idx, info.required_frame_up_steps });
                },
                .load_instance_var => |info| {
                    try writer.print(" id({d})", .{info.instance_var_id.idx});
                },
                .set_instance_var => |info| {
                    try writer.print(" id({d})", .{info.instance_var_id.idx});
                },
                .pop_into_new_array => |info| {
                    try writer.print(" items-count={d}", .{info.number_of_items});
                },
                .load_global => |global_var_id| {
                    const identifier: []const u8 = self.symbols_manager.symbol_with_id(global_var_id);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ identifier, global_var_id.idx });
                },
                .set_global => |global_var_id| {
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

        // fn print_constant(self: @This(), writer: *Writer, constant: Constant) Writer.Error!void {
        //     _ = self;
        //     switch (constant) {
        //         .integer => |value| {
        //             try writer.print("integer({d})", .{value});
        //         },
        //         .float => |value| {
        //             try writer.print("float({d})", .{value});
        //         },
        //         .string => |value| {
        //             try writer.print("string(", .{});
        //             try print_escaped_string(writer, value);
        //             try writer.print(")", .{});
        //         },
        //         .block => |block_info| {
        //             try writer.print(
        //                 "block body-arguments-cnt={d} locals-cnt={d} constant-base-id={d}",
        //                 .{
        //                     block_info.number_of_aditional_args,
        //                     block_info.body.number_of_locals,
        //                     block_info.body.constants_base_id.idx,
        //                 },
        //             );
        //         },
        //     }
        // }
    };
};

pub fn print_escaped_string(writer: *std.io.Writer, string_bytes: []const u8) std.io.Writer.Error!void {
    for (string_bytes) |char| {
        switch (char) {
            '\n' => _ = try writer.write("\\n"),
            '\r' => _ = try writer.write("\\r"),
            '\'' => _ = try writer.write("\\'"),
            '\t' => _ = try writer.write("\\t"),
            else => if (std.ascii.isPrint(char)) {
                try writer.writeByte(char);
            } else {
                try writer.print("\\x{x:02}", .{char});
            },
        }
    }
}

pub fn print_bytecode(
    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    bytecode: Bytecode,
    writer: *std.io.Writer,
    options: struct {
        print_recursive: bool = true,
        indent: usize = 0,
        use_color: bool = true,
    },
) std.io.Writer.Error!void {
    const f = InstructionFormatter{
        .constants_manager = constants_manager,
        .symbols_manager = symbols_manager,
        .use_color = options.use_color,
    };
    var decoder = InstructionDecoder.new(bytecode);
    var instruction_idx: InstructionId = decoder.id_of_next_instruction();

    while (decoder.next_instruction()) |instruction| {
        for (0..10 * options.indent) |_| try writer.writeByte(' ');

        try writer.print("[{d:04}] {f}", .{ instruction_idx.idx, f.fmt(instruction) });
        instruction_idx = decoder.id_of_next_instruction();
        if (!options.print_recursive) continue;

        switch (instruction) {
            .load_block => |block_id| {
                const block_info: *const BlockDefinition = constants_manager.get_block(block_id);
                var options_copy = options;
                options_copy.indent += 1;
                try print_bytecode(
                    symbols_manager,
                    constants_manager,
                    block_info.body.bytecode,
                    writer,
                    options_copy,
                );
            },
            else => {},
        }
    }
}

pub const StringLiteralId = packed struct(u32) {
    pub const IdxRepr = u32;
    idx: IdxRepr,
};

pub const BlockDefinitionId = packed struct(u32) {
    pub const IdxRepr = u32;
    idx: IdxRepr,
};

pub const Instruction = union(enum(u8)) {
    load_integer_i8: i8,
    load_integer_i48: i48,
    load_double: f64,
    load_string: StringLiteralId,
    load_block: BlockDefinitionId,

    send_message: SendMessage,

    /// Pushes either a local variable or a method argument onto the stack.
    load_local: LoadLocal,

    /// Pushes an instance variable of the current `self` object onto the stack.
    load_instance_var: LoadInstanceVar,

    load_global: SymbolId,

    /// Gets the top value from the stack (doesn't pop) and assigns its value to a global variable.
    set_global: SymbolId,

    normal_return,

    non_local_return,

    /// Gets the top value from the stack (doesn't pop) and assigns its value into a local variable
    set_local: SetLocal,

    /// Gets the top value from the stack (doesn't pop) and assigns its value into an instance variable
    set_instance_var: SetInstanceVar,

    pop,

    pop_into_new_array: PopIntoNewArray,

    load_symbol: SymbolId,

    resolved_method_call: packed struct { method_ptr: SmallPtr(*const MethodDefinition) },

    pub const LoadInstanceVar = packed struct {
        instance_var_id: InstanceVarId,
    };

    pub const SetInstanceVar = packed struct {
        instance_var_id: InstanceVarId,
    };

    pub const LoadLocal = packed struct {
        local_id: LocalVarId,
        required_frame_up_steps: u32,
    };

    pub const SetLocal = packed struct {
        local_id: LocalVarId,
        required_frame_up_steps: u32,
    };

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
    pub const LocalVarId = packed struct {
        idx: u32,
    };

    pub const InstanceVarId = packed struct { idx: u32 };

    pub const SendMessage = packed struct {
        message_name: SymbolId,
    };
    pub const LoadConstant = packed struct { id: RelativeConstantId };

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

// TODO: finish this test
test "Encoding and decoding of instructions" {
    const instructions: []Instruction = &[_]Instruction{
        // Instruction.load_constant{.{.sdfsdf}},
        // Instruction.duplicate,
        // Instruction.pop,
        // Instruction.halt,
        // Instruction.normal_return,
        // Instruction.send_message{ .aditional_args_count = 9, .message_name = .{ .idx = 5 } },
    };
    _ = instructions;
}
