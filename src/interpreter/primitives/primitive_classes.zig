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

const class_definition_module = @import("../class_definition.zig");
const ClassDefinition = class_definition_module.ClassDefinition;

const vm_object_module = @import("../vm_object.zig");
const VmObject = vm_object_module.VmObject;
const HeapData = vm_object_module.HeapData;

const accessors = @import("../accessors.zig");

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
        const class_definition: *ClassDefinition = switch (target_object.data.kind()) {
            .class => |accessor| accessor.get_represented_class(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };

        const new_object = try interpreter.create_object(.heap, class_definition);
        return new_object;
    }

    pub fn name__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const class_definition: *ClassDefinition = switch (target_object.data.kind()) {
            .class => |accessor| accessor.get_represented_class(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };
        return try interpreter.create_symbol_object(.heap, class_definition.class_name);
    }
};

pub const Integer = struct {
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
        const receiver_as_int: i48 = (accessors.IntegerAccessor{}).get_value(target_object.data);
        const string: VmObject = try interpreter.create_string_fmt(.heap, "{d}", .{receiver_as_int});
        return string;
    }

    fn binary_method(
        target_object: VmObject,
        interpreter: *Interpreter,
        comptime op: fn (i48, i48) Interpreter.Error!i48,
    ) Interpreter.Error!?VmObject {
        const lhs_int = (accessors.IntegerAccessor{}).get_value(target_object.data);

        const rhs_object = interpreter.pop_object();
        const rhs_int: i48 = switch (rhs_object.data.kind()) {
            .integer => |accessor| accessor.get_value(rhs_object.data),
            // TODO: check the size of the integer
            // TODO: use `asInteger` primitive method in the `Double` class
            .double => |accessor| @intFromFloat(accessor.get_value(rhs_object.data)),
            // TODO: better error reporting
            else => return Interpreter.Error.primitive_type_error,
        };
        const result_int = try op(lhs_int, rhs_int);

        const header = HeapData.Header.new_undefined_with_tag(.integer);
        const result_object_data: *HeapData = try interpreter.heap.allocate(header);
        (accessors.IntegerAccessor{}).set_value(result_object_data, result_int);
        const result_object = result_object_data.as_vm_object();

        return result_object;
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
        const receiver_as_double: f64 = (accessors.DoubleAccessor{}).get_value(target_object.data);
        const string: VmObject = try interpreter.create_string_fmt(.heap, "{d}", .{receiver_as_double});
        return string;
    }

    fn binary_method(
        target_object: VmObject,
        interpreter: *Interpreter,
        comptime op: fn (f64, f64) Interpreter.Error!f64,
    ) Interpreter.Error!?VmObject {
        const lhs_double = (accessors.DoubleAccessor{}).get_value(target_object.data);

        const rhs_object = interpreter.pop_object();

        // TODO: better error reporting
        const rhs_double: f64 = switch (rhs_object.data.kind()) {
            .integer => |accessor| @floatFromInt(accessor.get_value(rhs_object.data)),
            .double => |accessor| accessor.get_value(rhs_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };
        const result_double: f64 = try op(lhs_double, rhs_double);

        const header = HeapData.Header.new_undefined_with_tag(.double);
        const result_object_data: *HeapData = try interpreter.heap.allocate(header);
        (accessors.DoubleAccessor{}).set_value(result_object_data, result_double);
        const result_object = result_object_data.as_vm_object();

        return result_object;
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
        return try interpreter.get_nil_singleton();
    }

    pub fn print__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const str = try get_u8_slice_from_string_or_symbol(target_object, interpreter);
        _ = try interpreter.stdout.write(str);
        return try interpreter.get_nil_singleton();
    }

    pub fn asSymbol__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const str: []const u8 = switch (target_object.data.kind()) {
            .string => |accessor| accessor.contents(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };
        return try interpreter.create_symbol_object_from_string(.heap, str);
    }

    pub fn @"concatWith:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 2);
        const lhs_string: []const u8 = switch (target_object.data.kind()) {
            .string => |accessor| accessor.contents(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };

        const rhs_object = interpreter.pop_object();
        const rhs_string: []const u8 = switch (rhs_object.data.kind()) {
            .string => |accessor| accessor.contents(rhs_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };

        const result_string: VmObject = try interpreter.create_string_fmt(.heap, "{s}{s}", .{ lhs_string, rhs_string });
        return result_string;
    }

    pub fn @"primSubstringFrom:to:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 3);
        const original_string: []const u8 = try get_u8_slice_from_string_or_symbol(target_object, interpreter);
        const som_idx_from = blk: {
            const obj = interpreter.pop_object();
            const idx = switch (obj.data.kind()) {
                .integer => |accessor| accessor.get_value(obj.data),
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
            const idx = switch (obj.data.kind()) {
                .integer => |accessor| accessor.get_value(obj.data),
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

        const result_string: VmObject = try interpreter.create_string(.heap, substring);
        return result_string;
    }

    fn get_u8_slice_from_string_or_symbol(object: VmObject, interpreter: *Interpreter) Interpreter.Error![]const u8 {
        const string: []const u8 = sw: switch (object.data.kind()) {
            .string => |accessor| break :sw accessor.contents(object.data),
            .symbol => |accessor| {
                const symbol_id: SymbolId = accessor.get_symbol_id(object.data.*);
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
        const symbol_id: SymbolId = switch (target_object.data.kind()) {
            .symbol => |accessor| accessor.get_symbol_id(target_object.data.*),
            else => return Interpreter.Error.primitive_type_error,
        };
        const symbol_as_string: []const u8 = interpreter.statics.symbols_manager.symbol_with_id(symbol_id);
        const object = try interpreter.create_string(.heap, symbol_as_string);
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

        // Pop the value that is supposed to replace item
        const new_value: VmObject = interpreter.pop_object();
        item_ptr.* = new_value;

        // NOTE: We are returning the object that was assigned.
        //       This might not be correct, but the language does not have a specified behaviour :)
        //       If we are expected to return `Nil`, this cannot cause much issue anyway
        //       and might have better usability.
        //       Also, this could be faster, since we don't have to go fetching the `Nil` singleton.
        return new_value;
    }

    pub fn length__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 1);
        const length_i48: i48 = switch (target_object.data.kind()) {
            .array => |accessor| accessor.get_length(target_object.data.*),
            else => return Interpreter.Error.primitive_type_error,
        };

        try interpreter.ensure_primitive_class_is_loaded(.integer);

        const header = HeapData.Header.new_undefined_with_tag(.integer);
        const result_object_data: *HeapData = try interpreter.heap.allocate(header);
        (accessors.IntegerAccessor{}).set_value(result_object_data, length_i48);

        const object: VmObject = result_object_data.as_vm_object();
        return object;
    }

    /// Assumes there is index at the top of the runtime object stack
    fn get_pointer_to_item(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!*VmObject {
        const items: []VmObject = switch (target_object.data.kind()) {
            .array => |accessor| accessor.items(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };

        const index_object: VmObject = interpreter.pop_object();
        const index_i48: i48 = switch (index_object.data.kind()) {
            .integer => |accessor| accessor.get_value(index_object.data),
            // TODO - probably create some generic function which validates indexes
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
};

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
        const block_definition: *const BlockDefinition = switch (target_object.data.kind()) {
            .block => |accessor| accessor.get_block_definition(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };

        // TODO: consider doing this to store the `self` of the method the block is currently in.
        //          try interpreter.push(interpreter.stack.objects[interpreter.top_frame().base_idx + interpreter.top_frame().self_object_idx()])
        try interpreter.push_object(target_object);

        try interpreter.push_frame(
            .{ .block = block_definition },
            block_definition.body.bytecode,
            block_definition.number_of_aditional_args,
            block_definition.body.number_of_locals,
        );

        return null;
    }
};

pub const Block3 = struct {
    pub fn @"value:with:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject {
        assert_arity_is(@src(), 3);
        const block_definition: *const BlockDefinition = switch (target_object.data.kind()) {
            .block => |accessor| accessor.get_block_definition(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };

        // TODO: consider doing this to store the `self` of the method the block is currently in.
        //          try interpreter.push(interpreter.stack.objects[interpreter.top_frame().base_idx + interpreter.top_frame().self_object_idx()])
        try interpreter.push_object(target_object);

        try interpreter.push_frame(
            .{ .block = block_definition },
            block_definition.body.bytecode,
            block_definition.number_of_aditional_args,
            block_definition.body.number_of_locals,
        );

        return null;
    }
};

fn block_value_method(
    target_object: VmObject,
    interpreter: *Interpreter,
) Interpreter.Error!?VmObject {
    const block_definition: *const BlockDefinition = switch (target_object.data.kind()) {
        .block => |accessor| accessor.get_block_definition(target_object.data),
        else => return Interpreter.Error.primitive_type_error,
    };

    // TODO: consider doing this to store the `self` of the method the block is currently in.
    //          try interpreter.push(interpreter.stack.objects[interpreter.top_frame().base_idx + interpreter.top_frame().self_object_idx()])
    try interpreter.push_object(target_object);

    try interpreter.push_frame(
        .{ .block = block_definition },
        block_definition.body.bytecode,
        block_definition.number_of_aditional_args,
        block_definition.body.number_of_locals,
    );

    return null;
}
