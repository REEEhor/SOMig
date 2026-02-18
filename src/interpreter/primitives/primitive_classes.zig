const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const unions = @import("../../unions.zig");

const interning_module = @import("../../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

const helpers_module = @import("helpers.zig");
const NilPlaceholder = helpers_module.NilPlaceholder;
const SystemPlaceholder = helpers_module.SystemPlaceholder;

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
const Number = vm_object_module.Number;

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
    pub fn @"="(self: i48, rhs: Number) bool {
        return self == switch (rhs) {
            .integer => |value| value,
            .double => |value_as_f64| std.math.lossyCast(i48, value_as_f64),
        };
    }

    pub fn @"+"(self: i48, rhs: Number) Number {
        return switch (rhs) {
            .integer => |value| .{ .integer = self +% value },
            .double => |value_as_f64| .{
                .double = @as(f64, @floatFromInt(self)) + value_as_f64,
            },
        };
    }

    pub fn @"-"(self: i48, rhs: Number) Number {
        return switch (rhs) {
            .integer => |value| .{ .integer = self -% value },
            .double => |value_as_f64| .{
                .double = @as(f64, @floatFromInt(self)) - value_as_f64,
            },
        };
    }

    pub fn @"*"(self: i48, rhs: Number) Number {
        return switch (rhs) {
            .integer => |value| .{ .integer = self *% value },
            .double => |value_as_f64| .{
                .double = @as(f64, @floatFromInt(self)) * value_as_f64,
            },
        };
    }

    pub fn @"/"(self: i48, rhs_raw: Number, interpreter: *Interpreter) Interpreter.Error!i48 {
        return @"/_on_numbers"(self, rhs_raw, interpreter);
    }

    pub fn asString(self: i48, interpreter: *Interpreter) Interpreter.Error!VmObject {
        return try types.String.create_new_fmt(interpreter.heap_allocator, "{d}", .{self});
    }
};

pub const Double = struct {
    pub fn @"+"(self: f64, rhs_raw: Number) f64 {
        const rhs: f64 = switch (rhs_raw) {
            .double => |value| value,
            .integer => |value_as_i48| @as(f64, @floatFromInt(value_as_i48)),
        };
        return self + rhs;
    }

    pub fn @"-"(self: f64, rhs_raw: Number) f64 {
        const rhs: f64 = switch (rhs_raw) {
            .double => |value| value,
            .integer => |value_as_i48| @as(f64, @floatFromInt(value_as_i48)),
        };
        return self - rhs;
    }

    pub fn @"*"(self: f64, rhs_raw: Number) f64 {
        const rhs: f64 = switch (rhs_raw) {
            .double => |value| value,
            .integer => |value_as_i48| @as(f64, @floatFromInt(value_as_i48)),
        };
        return self * rhs;
    }

    pub fn @"/"(self: f64, rhs: Number, interpreter: *Interpreter) Interpreter.Error!i48 {
        return @"/_on_numbers"(self, rhs, interpreter);
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

pub const System = struct {
    pub fn printNewline(_: SystemPlaceholder, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        const newline = switch (builtin.os.tag) {
            .windows => "\r\n",
            else => "\n",
        };
        _ = try interpreter.stdout.write(newline);
        try interpreter.stdout.flush();
        return .{};
    }

    pub fn @"printString:"(_: SystemPlaceholder, string: []const u8, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        _ = try interpreter.stdout.write(string);
        if (interpreter.do_flush_on_every_print) {
            try interpreter.stdout.flush();
        }
        return .{};
    }
};

pub const Block = struct {
    pub fn value(self: *types.Block, interpreter: *Interpreter) Interpreter.Error!void {
        return try block_value_method(self, interpreter);
    }

    pub fn restart(_: *types.Block, interpreter: *Interpreter) void {
        interpreter.decoder.set_id_of_the_next_instruction(.{ .idx = 0 });
        // TODO(consultation): is this needed here? At least the usecase for `restart` in `Block restart` does not need this
        interpreter.stack.pop_all_temporaries_from_top_frame();
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

fn @"/_on_numbers"(lhs_raw: anytype, rhs_raw: Number, interpreter: *Interpreter) Interpreter.Error!i48 {
    const lhs = switch (@TypeOf(lhs_raw)) {
        i48 => lhs_raw,
        f64 => std.math.lossyCast(i48, lhs_raw),
        else => |Invalid| @compileError(std.fmt.comptimePrint("Invalid type: `{s}`", .{@typeName(Invalid)})),
    };
    const rhs = rhs_raw.as_i48_maybe_lossy();

    if (rhs == 0) {
        @branchHint(.cold); // If we are in a fail state, we don't care that this branch is slow
        interpreter.report_runtime_error("Tried to divide the Integer {d} by Integer zero.", .{lhs});
        return Interpreter.Error.division_by_zero;
    }
    return @divFloor(lhs, rhs);
}
