const std = @import("std");
const assert = std.debug.assert;

const interning_module = @import("../../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

const helpers_module = @import("helpers.zig");
const NilPlaceholder = helpers_module.NilPlaceholder;

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

// NOTE(epic-zig): the reflection used to extract this info is really nice :D

pub const Object = struct {
    pub fn class(self: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const class_definition = interpreter.get_class_of(self);
        return class_definition.as_vm_object;
    }
};

pub const Class = struct {
    pub fn new(class: *types.Class, interpreter: *Interpreter) Interpreter.Error!VmObject {
        // FIXME: this does not work! We have to handle cases for primtive classes
        // switch(class.represented_class.class_name) {
        //     SymbolsManager.comptime_id_of("Integer").idx => todo,
        //     SymbolsManager.comptime_id_of("Double").idx => todo,
        //     SymbolsManager.comptime_id_of("Symbol").idx => todo,
        //     SymbolsManager.comptime_id_of("String").idx => todo,
        //     // ...
        //     else => try types.GenericObject.create_new(interpreter.heap_allocator, class.represented_class),
        // }
        return try types.GenericObject.create_new(interpreter.heap_allocator, class.represented_class);
    }

    pub fn name(self: *types.Class) SymbolId {
        return self.represented_class.class_name;
    }
};

pub const Integer = struct {
    pub fn @"="(self: i48, rhs: i48) bool {
        return self == rhs;
    }

    pub fn @"+"(self: i48, rhs: i48) i48 {
        return self +% rhs;
    }

    pub fn @"-"(self: i48, rhs: i48) i48 {
        return self -% rhs;
    }

    pub fn @"*"(self: i48, rhs: i48) i48 {
        return self *% rhs;
    }

    pub fn @"/"(self: i48, rhs: i48, interpreter: *Interpreter) Interpreter.Error!i48 {
        if (rhs == 0) {
            @branchHint(.cold); // If we are in a fail state, we don't care that this branch is slow
            interpreter.report_runtime_error("Tried to divide the Integer {d} by Integer zero.", .{self});
            return Interpreter.Error.division_by_zero;
        }
        // TODO: Check if this is the correct behaviour. This is probably the behaviour of `//` on the `Integer` class. Which means we should return Double here maybe
        // TODO: Also check if the `/` method rounds towards zero or -infinity (in case of towards zero, change to `@divTrunc`)
        return @divFloor(self, rhs);
    }

    pub fn asString(self: i48, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return try types.String.create_new_fmt(interpreter.heap_allocator, "{d}", .{self});
    }
};

pub const Double = struct {
    pub fn @"+"(self: f64, rhs: f64) f64 {
        return self + rhs;
    }

    pub fn @"-"(self: f64, rhs: f64) f64 {
        return self - rhs;
    }

    pub fn @"*"(self: f64, rhs: f64) f64 {
        return self * rhs;
    }

    pub fn @"/"(self: f64, rhs: f64) f64 {
        return self / rhs;
    }

    pub fn asString(self: f64, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return try types.String.create_new_fmt(interpreter.heap_allocator, "{d}", .{self});
    }
};

pub const String = struct {
    /// FIXME: this method should be defined in object, not here
    pub fn println(self: []const u8, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        _ = try interpreter.stdout.write(self);
        _ = try interpreter.stdout.writeByte('\n');
        try interpreter.stdout.flush();
        return .{};
    }

    pub fn print(self: []const u8, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        _ = try interpreter.stdout.write(self);
        if (interpreter.do_flush_on_every_print) {
            try interpreter.stdout.flush();
        }
        return .{};
    }

    pub fn asSymbol(self: []const u8, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const symbol_id = (try interpreter.statics.symbols_manager.id_or_intern(self)).id;
        return try types.Symbol.create_new(interpreter.heap_allocator, symbol_id);
    }

    pub fn @"concatWith:"(self: []const u8, other: []const u8, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return try types.String.create_new_fmt(
            interpreter.heap_allocator,
            "{s}{s}",
            .{ self, other },
        );
    }

    pub fn @"primSubstringFrom:to:"(self: []const u8, from_idx_raw: i48, to_idx_raw: i48, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const from_index: usize = try interpreter.check_out_of_bounds_get_1_base_index(.{
            .class_name = "String",
            .length = self.len,
            .access_index = from_idx_raw,
        });
        const to_index: usize = try interpreter.check_out_of_bounds_get_1_base_index(.{
            .class_name = "String",
            .length = self.len,
            .access_index = to_idx_raw,
        });
        if (from_index > to_index) {
            interpreter.report_runtime_error("Argument `from:` is {d}, which is bigger than `to:`, which is {d}", .{ from_index, to_index });
            return Interpreter.Error.generic_runtime_error;
        }
        const substring: []const u8 = self[(from_index - 1)..(to_index)];
        return try types.String.create_new(interpreter.heap_allocator, substring);
    }
};

pub const Symbol = struct {
    pub fn asString(self: SymbolId, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const symbol_as_string: []const u8 = interpreter.statics.symbols_manager.symbol_with_id(self);
        return try types.String.create_new(interpreter.heap_allocator, symbol_as_string);
    }
};

pub const Array = struct {
    pub fn @"at:"(self: []VmObject, index_raw: i48, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const index: usize = try interpreter.check_out_of_bounds_get_1_base_index(.{
            .class_name = "Array",
            .length = self.len,
            .access_index = index_raw,
        });
        return self[index - 1];
    }

    pub fn @"at:put:"(self: []VmObject, index_raw: i48, new_value: VmObject, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        const index: usize = try interpreter.check_out_of_bounds_get_1_base_index(.{
            .class_name = "Array",
            .length = self.len,
            .access_index = index_raw,
        });
        self[index - 1] = new_value;
        return .{};
    }

    pub fn length(self: []VmObject) i48 {
        return @intCast(self.len);
    }
};

pub const Block = struct {
    pub fn value(self: *types.Block, interpreter: *Interpreter) Interpreter.Error!void {
        return try block_value_method(self, interpreter);
    }
};

pub const Block1 = struct {
    pub fn value(self: *types.Block, interpreter: *Interpreter) Interpreter.Error!void {
        return try block_value_method(self, interpreter);
    }
};

pub const Block2 = struct {
    pub fn @"value:"(self: *types.Block, argument: VmObject, interpreter: *Interpreter) Interpreter.Error!void {
        try interpreter.push_object(argument);
        return try block_value_method(self, interpreter);
    }
};

pub const Block3 = struct {
    pub fn @"value:with:"(self: *types.Block, argument1: VmObject, argument2: VmObject, interpreter: *Interpreter) Interpreter.Error!void {
        // We have to push them onto the stack in a reverse order.
        // So the call is valid according to the calling convention!
        try interpreter.push_object(argument2);
        try interpreter.push_object(argument1);
        return try block_value_method(self, interpreter);
    }
};

fn block_value_method(block: *types.Block, interpreter: *Interpreter) Interpreter.Error!void {
    try interpreter.push_object(block.home_frame.self_object_ptr().*);
    try interpreter.push_frame(
        .{ .block = block },
        block.block_definition.body.bytecode,
        block.block_definition.number_of_aditional_args,
        block.block_definition.body.number_of_locals,
    );
}
