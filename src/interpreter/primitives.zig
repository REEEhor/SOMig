const std = @import("std");
const assert = std.debug.assert;

const interpreter_module = @import("__interpreter.zig");
const Interpreter = interpreter_module.Interpreter;
const Heap = interpreter_module.Heap;

const class_definition_module = @import("class_definition.zig");
const ClassDefinition = class_definition_module.ClassDefinition;

const vm_object_module = @import("vm_object.zig");
const VmObject = vm_object_module.VmObject;
const HeapData = vm_object_module.HeapData;

const accessors = @import("accessors.zig");

// TODO: split the classes definitions into "instance" and "class" parts

pub const Object = struct {
    pub const class__somig_arity = 1;
    pub fn class__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const class_definition = interpreter.get_class_of(target_object);
        return class_definition.as_vm_object;
    }
};

pub const Class = struct {
    pub const new__somig_arity = 1;
    pub fn new__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const class_definition: *ClassDefinition = switch (target_object.data.kind()) {
            .class => |accessor| accessor.get_class_definition(target_object.data),
            else => unreachable,
        };

        const new_object = try interpreter.create_object(.heap, class_definition);
        return new_object;
    }

    pub const name__somig_arity = 1;
    pub fn name__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const class_definition: *ClassDefinition = switch (target_object.data.kind()) {
            .class => |accessor| accessor.get_class_definition(target_object.data),
            else => unreachable,
        };
        const name_as_u8_slice: []const u8 = interpreter.statics.symbols_manager.symbol_with_id(class_definition.class_name);
        const name_as_string_object = try interpreter.create_string(.heap, name_as_u8_slice);
        return name_as_string_object;
    }
};

pub const Integer = struct {
    pub const @"+__somig_arity" = 2;
    pub fn @"+__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return try binary_method(target_object, interpreter, struct {
            fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                return lhs + rhs;
            }
        }.f);
    }

    pub const @"-__somig_arity" = 2;
    pub fn @"-__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return try binary_method(target_object, interpreter, struct {
            fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                return lhs - rhs;
            }
        }.f);
    }

    pub const @"*__somig_arity" = 2;
    pub fn @"*__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return try binary_method(target_object, interpreter, struct {
            fn f(lhs: i48, rhs: i48) Interpreter.Error!i48 {
                return lhs * rhs;
            }
        }.f);
    }

    pub const @"/__somig_arity" = 2;
    pub fn @"/__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
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

    pub const asString__somig_arity = 1;
    pub fn asString__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const receiver_as_int: i48 = (accessors.IntegerAccessor{}).get_value(target_object.data);
        const string: VmObject = try interpreter.create_string_fmt(.heap, "{d}", .{receiver_as_int});
        return string;
    }

    fn binary_method(
        target_object: VmObject,
        interpreter: *Interpreter,
        comptime op: fn (i48, i48) Interpreter.Error!i48,
    ) Interpreter.Error!VmObject {
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
    pub const @"+__somig_arity" = 2;
    pub fn @"+__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs + rhs;
            }
        }.f);
    }

    pub const @"-__somig_arity" = 2;
    pub fn @"-__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs - rhs;
            }
        }.f);
    }

    pub const @"*__somig_arity" = 2;
    pub fn @"*__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs * rhs;
            }
        }.f);
    }

    pub const @"/__somig_arity" = 2;
    pub fn @"/__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return binary_method(target_object, interpreter, struct {
            fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                return lhs / rhs;
            }
        }.f);
    }

    pub const asString__somig_arity = 1;
    pub fn asString__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const receiver_as_double: f64 = (accessors.DoubleAccessor{}).get_value(target_object.data);
        const string: VmObject = try interpreter.create_string_fmt(.heap, "{d}", .{receiver_as_double});
        return string;
    }

    fn binary_method(
        target_object: VmObject,
        interpreter: *Interpreter,
        comptime op: fn (f64, f64) Interpreter.Error!f64,
    ) Interpreter.Error!VmObject {
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
    pub const println__somig_arity = 1;
    pub fn println__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const str: []const u8 = switch (target_object.data.kind()) {
            .string => |accessor| accessor.contents(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };
        _ = try interpreter.stdout.write(str);
        _ = try interpreter.stdout.writeByte('\n');
        try interpreter.stdout.flush();
        return try interpreter.get_nil_singleton();
    }

    pub const print__somig_arity = 1;
    pub fn print__somig_primitive_fn(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const str: []const u8 = switch (target_object.data.kind()) {
            .string => |accessor| accessor.contents(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };
        _ = try interpreter.stdout.write(str);
        return try interpreter.get_nil_singleton();
    }

    pub const @"concatWith:__somig_arity" = 2;
    pub fn @"concatWith:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
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

    pub const @"primSubstringFrom:to:__somig_arity" = 3;
    pub fn @"primSubstringFrom:to:__somig_primitive_fn"(target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const original_string: []const u8 = switch (target_object.data.kind()) {
            .string => |accessor| accessor.contents(target_object.data),
            else => return Interpreter.Error.primitive_type_error,
        };

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
};
