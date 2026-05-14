const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_module = @import("../bytecode/__bytecode.zig");
const Instruction = bytecode_module.Instruction;

const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

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
