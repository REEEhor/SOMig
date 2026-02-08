const std = @import("std");
const assert = std.debug.assert;

const interning_module = @import("../../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;

const helpers_module = @import("helpers.zig");
const assert_arity_is = helpers_module.assert_arity_is;

const interpreter_module = @import("../__interpreter.zig");
const Interpreter = interpreter_module.Interpreter;
const Heap = interpreter_module.Heap;
const BlockDefinition = interpreter_module.BlockDefinition;
const types = interpreter_module.types;

const class_definition_module = @import("../class_definition.zig");
const ClassDefinition = class_definition_module.ClassDefinition;

const vm_object_module = @import("../vm_object.zig");
const VmObject = vm_object_module.VmObject;
const HeapData = vm_object_module.HeapData;

// TODO: split the classes definitions into "instance" and "class" parts

pub const Object = struct {
    pub fn class__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const class_definition = interpreter.get_class_of(target_object);
        return class_definition.as_vm_object;
    }
};

pub const Class = struct {
    /// TODO: this does not work! We have to handle cases for primtive classes
    pub fn new__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const class_definition: *ClassDefinition = switch (target_object.kind()) {
            .class => |class| class.represented_class,
            else => return Interpreter.Error.primitive_type_error,
        };
        return try types.GenericObject.create_new(interpreter.heap_allocator, class_definition);
    }

    pub fn name__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const class_definition: *ClassDefinition = switch (target_object.kind()) {
            .class => |class| class.represented_class,
            else => return Interpreter.Error.primitive_type_error,
        };
        return try types.Symbol.create_new(interpreter.heap_allocator, class_definition.class_name);
    }
};

pub const Integer = struct {
    pub fn @"=__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        const functions = struct {
            fn eql(lhs: i48, rhs: i48) Interpreter.Error!bool {
                return lhs == rhs;
            }
            fn eql_with_f64_as_rhs(lhs: i48, rhs: f64) Interpreter.Error!bool {
                const rhs_as_int = std.math.lossyCast(i48, rhs);
                return lhs == rhs_as_int;
            }
        };

        return try binary_predicate(target_object, interpreter, functions.eql, functions.eql_with_f64_as_rhs);
    }

    pub fn @"+__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        return try binary_method(target_object, interpreter, struct {
            fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                return lhs + rhs;
            }
        }.f);
    }

    pub fn @"-__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        return try binary_method(target_object, interpreter, struct {
            fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                return lhs - rhs;
            }
        }.f);
    }

    pub fn @"*__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        return try binary_method(target_object, interpreter, struct {
            fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                return lhs * rhs;
            }
        }.f);
    }

    pub fn @"/__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        const i48_dividion = struct {
            fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                if (rhs == 0) {
                    @branchHint(.unlikely);
                    return Interpreter.Error.division_by_zero;
                }
                // TODO: Check if this is the correct behaviour. This is probably the behaviour of `//` on the `Integer` class
                // TODO: Also check if the `/` method rounds towards zero or -infinity (in case of towards zero, change to `@divTrunc`)
                return @divFloor(lhs, rhs);
            }
        }.f;

        const result_object = binary_method(target_object, interpreter, i48_dividion) catch |err| {
            if (err == error.division_by_zero) interpreter.report_runtime_error("Division by zero", .{});
            return err;
        };
        return result_object;
    }

    pub fn asString__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const receiver_as_int: i48 = target_object.kind().integer.header.value;
        const string: VmObject = try types.String.create_new_fmt(
            interpreter.heap_allocator,
            "{d}",
            .{receiver_as_int},
        );
        return string;
    }

    fn binary_predicate(
        target_object: VmObject,
        interpreter: *Interpreter,
        comptime op: fn (i48, i48) Interpreter.Error!bool,
        comptime op_when_rhs_is_double: fn (i48, f64) Interpreter.Error!bool,
    ) Interpreter.Error!?VmObject {
        const lhs_int = target_object.kind().integer.header.value;

        const rhs_object = interpreter.pop_object();
        const result_bool: bool = switch (rhs_object.kind()) {
            .integer => |int| try op(lhs_int, int.header.value),
            .double => |double| try op_when_rhs_is_double(lhs_int, double.value),
            else => return Interpreter.Error.primitive_type_error,
        };

        if (result_bool) {
            return interpreter.singletons.true_object;
        } else {
            return interpreter.singletons.false_object;
        }
    }

    fn binary_method(
        target_object: VmObject,
        interpreter: *Interpreter,
        comptime op: fn (i48, i48) Interpreter.Error!i48,
    ) Interpreter.Error!?VmObject {
        const lhs_int = target_object.kind().integer.header.value;

        const rhs_object = interpreter.pop_object();
        const rhs_int: i48 = switch (rhs_object.kind()) {
            .integer => |int| int.header.value,
            // TODO: check the size of the integer
            // TODO: use `asInteger` primitive method in the `Double` class
            .double => |double| @intFromFloat(double.value),
            // TODO: better error reporting
            else => return Interpreter.Error.primitive_type_error,
        };
        const result_int = try op(lhs_int, rhs_int);

        return try types.Integer.create_new(interpreter.heap_allocator, result_int);
    }
};

pub const Double = struct {
    pub fn @"+__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs + rhs;
            }
        }.f);
    }

    pub fn @"-__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs - rhs;
            }
        }.f);
    }

    pub fn @"*__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs * rhs;
            }
        }.f);
    }

    pub fn @"/__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs / rhs;
            }
        }.f);
    }

    pub fn asString__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const receiver_as_double: f64 = target_object.kind().double.value;
        const string: VmObject = try types.String.create_new_fmt(
            interpreter.heap_allocator,
            "{d}",
            .{receiver_as_double},
        );
        return string;
    }

    fn binary_method(
        target_object: VmObject,
        interpreter: *Interpreter,
        comptime op: fn (f64, f64) Interpreter.Error!f64,
    ) Interpreter.Error!?VmObject {
        const lhs_double = target_object.kind().double.value;
        const rhs_object = interpreter.pop_object();

        // TODO: better error reporting
        const rhs_double: f64 = switch (rhs_object.kind()) {
            .integer => |int| @floatFromInt(int.header.value),
            .double => |double| double.value,
            else => return Interpreter.Error.primitive_type_error,
        };
        const result_double: f64 = try op(lhs_double, rhs_double);

        return try types.Double.create_new(interpreter.heap_allocator, result_double);
    }
};

pub const String = struct {
    /// FIXME: this method should be defined in object, not here
    pub fn println__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const str = try get_u8_slice_from_string_or_symbol(target_object, interpreter);
        _ = try interpreter.stdout.write(str);
        _ = try interpreter.stdout.writeByte('\n');
        try interpreter.stdout.flush();
        return VmObject.nil;
    }

    pub fn print__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);

        const str = try get_u8_slice_from_string_or_symbol(target_object, interpreter);
        _ = try interpreter.stdout.write(str);

        return VmObject.nil;
    }

    pub fn asSymbol__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);

        const str: []const u8 = switch (target_object.kind()) {
            .string => |ptr| ptr.contents(),

            else => return Interpreter.Error.primitive_type_error,
        };

        const symbol_id = (try interpreter.statics.symbols_manager.id_or_intern(str)).id;

        return try vm_object_module.types.Symbol.create_new(interpreter.heap_allocator, symbol_id);
    }

    pub fn @"concatWith:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);

        const lhs_string: []const u8 = switch (target_object.kind()) {
            .string => |ptr| ptr.contents(),

            else => return Interpreter.Error.primitive_type_error,
        };

        const rhs_object = interpreter.pop_object();

        const rhs_string: []const u8 = switch (rhs_object.kind()) {
            .string => |ptr| ptr.contents(),

            else => return Interpreter.Error.primitive_type_error,
        };

        const result_string: VmObject = try types.String.create_new_fmt(
            interpreter.heap_allocator,
            "{s}{s}",
            .{ lhs_string, rhs_string },
        );

        return result_string;
    }

    pub fn @"primSubstringFrom:to:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 3);

        const original_string: []const u8 = try get_u8_slice_from_string_or_symbol(target_object, interpreter);

        const som_idx_from = blk: {
            const obj = interpreter.pop_object();

            const idx = switch (obj.kind()) {
                .integer => |ptr| ptr.header.value,

                else => return Interpreter.Error.primitive_type_error,
            };

            if (idx < 1 or idx > original_string.len) {
                interpreter.report_runtime_error(
                    "The `from:` argument is {d}, which is invalid for string of length {d}. The valid values are from 1 to {d} inclusive.",

                    .{ idx, original_string.len, original_string.len },
                );

                return Interpreter.Error.generic_runtime_error;
            }

            break :blk idx;
        };

        const som_idx_to = blk: {
            const obj = interpreter.pop_object();

            const idx = switch (obj.kind()) {
                .integer => |ptr| ptr.header.value,

                else => return Interpreter.Error.primitive_type_error,
            };

            if (idx < 1 or idx > original_string.len) {
                interpreter.report_runtime_error(
                    "The `to:` argument is {d}, which is invalid for string of length {d}. The valid values are from 1 to {d} inclusive.",

                    .{ idx, original_string.len, original_string.len },
                );

                return Interpreter.Error.generic_runtime_error;
            }

            break :blk idx;
        };

        if (som_idx_from > som_idx_to) {
            interpreter.report_runtime_error("Argument `from:` is {d}, which is bigger than `to:`, which is {d}", .{ som_idx_from, som_idx_to });

            return Interpreter.Error.generic_runtime_error;
        }

        const substring: []const u8 = original_string[@intCast(som_idx_from - 1)..@intCast(som_idx_to)];

        const result_string: VmObject = try types.String.create_new(interpreter.heap_allocator, substring);

        return result_string;
    }

    fn get_u8_slice_from_string_or_symbol(object: VmObject, interpreter: *Interpreter) Interpreter.Error![]const u8 {
        const string: []const u8 = sw: switch (object.kind()) {
            .string => |ptr| break :sw ptr.contents(),

            .symbol => |ptr| {
                const symbol_id: SymbolId = ptr.header.symbol_id;

                break :sw interpreter.statics.symbols_manager.symbol_with_id(symbol_id);
            },

            else => return Interpreter.Error.primitive_type_error,
        };

        return string;
    }
};

pub const Symbol = struct {
    pub fn asString__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);

        const symbol_id: SymbolId = switch (target_object.kind()) {
            .symbol => |ptr| ptr.header.symbol_id,

            else => return Interpreter.Error.primitive_type_error,
        };
        const symbol_as_string: []const u8 = interpreter.statics.symbols_manager.symbol_with_id(symbol_id);
        const object = try types.String.create_new(interpreter.heap_allocator, symbol_as_string);

        return object;
    }
};

pub const Array = struct {
    pub fn @"at:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        const item_ptr: *VmObject = try get_pointer_to_item(target_object, interpreter);
        return item_ptr.*;
    }

    pub fn @"at:put:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 3);
        const item_ptr: *VmObject = try get_pointer_to_item(target_object, interpreter);
        const new_value: VmObject = interpreter.pop_object();
        item_ptr.* = new_value;
        return new_value;
    }

    pub fn length__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const length_i48: i48 = switch (target_object.kind()) {
            .array => |ptr| ptr.header.length,
            else => return Interpreter.Error.primitive_type_error,
        };
        const object: VmObject = try vm_object_module.types.Integer.create_new(interpreter.heap_allocator, length_i48);
        return object;
    }
};

fn get_pointer_to_item(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!*VmObject {
    const items: []VmObject = switch (target_object.kind()) {
        .array => |ptr| ptr.get_items(),

        else => return Interpreter.Error.primitive_type_error,
    };

    const index_object: VmObject = interpreter.pop_object();

    const index_i48: i48 = switch (index_object.kind()) {
        .integer => |ptr| ptr.header.value,

        .double => return interpreter.report_TODO("Indexing arrays with double", .{}),

        else => return Interpreter.Error.primitive_type_error,
    };

    if (index_i48 < 1 or index_i48 > items.len) {
        interpreter.report_runtime_error(
            "The argument `index` has value of {d}, which is invalid for an array with length {d}. Valid range is from 1 to {d} (including).",

            .{ index_i48, items.len, items.len },
        );

        return Interpreter.Error.generic_runtime_error;
    }

    return &items[@intCast(index_i48 - 1)];
}

pub const Block = struct {
    pub fn value__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        return try block_value_method(target_object, interpreter);
    }
};

pub const Block1 = struct {
    pub fn value__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        return try block_value_method(target_object, interpreter);
    }
};

pub const Block2 = struct {
    pub fn @"value:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);

        const block: *types.Block = switch (target_object.kind()) {
            .block => |block| block,
            else => return Interpreter.Error.primitive_type_error,
        };
        try interpreter.push_object(target_object);
        try interpreter.push_frame(
            .{ .block = block },
            block.block_definition.body.bytecode,
            block.block_definition.number_of_aditional_args,
            block.block_definition.body.number_of_locals,
        );
        return null;
    }
};

pub const Block3 = struct {
    pub fn @"value:with:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 3);

        const block: *types.Block = switch (target_object.kind()) {
            .block => |block| block,
            else => return Interpreter.Error.primitive_type_error,
        };
        try interpreter.push_object(target_object);
        try interpreter.push_frame(
            .{ .block = block },
            block.block_definition.body.bytecode,
            block.block_definition.number_of_aditional_args,
            block.block_definition.body.number_of_locals,
        );
        return null;
    }
};

fn block_value_method(
    target_object: VmObject,
    interpreter: *Interpreter,
) Interpreter.Error!?VmObject {
    const block: *types.Block = switch (target_object.kind()) {
        .block => |block| block,
        else => return Interpreter.Error.primitive_type_error,
    };
    try interpreter.push_object(target_object);
    try interpreter.push_frame(
        .{ .block = block },
        block.block_definition.body.bytecode,
        block.block_definition.number_of_aditional_args,
        block.block_definition.body.number_of_locals,
    );
    return null;
}
