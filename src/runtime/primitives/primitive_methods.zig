//! Definitions for primitive methods
//!
//! This file gets parsed (or.. "comptime reflected")
//! via the function `PrimitivesMethodsMap.init_from` in `primitives/primitives_methods_map`
//! NOTE(epic-zig): the reflection used to extract this info is really nice :D

pub const Object = struct {
    pub fn class(self: VmObject, interpreter: *Interpreter) VmObject {
        const class_definition = interpreter.get_class_of(self);
        return VmObject.from(class_definition.as_vm_object);
    }

    pub fn objectSize(self: VmObject) i48 {
        const heap_size: usize = switch (self.identify()) {
            .heap_object => self.as_asserted_ptr_to_heap().segment_size_in_bytes(),
            else => 0,
        };
        const total_size = @sizeOf(VmObject) + heap_size;
        return @intCast(total_size);
    }

    pub fn @"=="(self: VmObject, other: VmObject) bool {
        return self.bits == other.bits;
    }

    pub fn hashcode(self: VmObject) i48 {
        const hash_u64: u64 = std.hash.int(self.bits);
        return @truncate(@as(i64, @bitCast(hash_u64)));
    }

    pub fn inspect(self: VmObject, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        try interpreter.print_object(self);
        return .{};
    }

    pub fn dumpBytecode(_: VmObject, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        const bytecode = interpreter.top_frame().get_bytecode();
        try bytecode_module.print_bytecode(
            &interpreter.statics.symbols_manager,
            &interpreter.statics.constants_manager,
            bytecode,
            interpreter.stderr,
            .{},
        );
        try interpreter.stderr.flush();
        return .{};
    }

    pub fn halt(_: VmObject, interpreter: *Interpreter) error{interpreter_halted}!void {
        interpreter.exit_code = 0;
        return error.interpreter_halted;
    }

    pub fn @"perform:"(self: VmObject, method_selector: SymbolId, interpreter: *Interpreter) Interpreter.Error!void {
        const class_definition = interpreter.get_class_of(self);
        const method = class_definition.get_method(method_selector) orelse return failed_finding_method(
            method_selector,
            class_definition,
            interpreter,
        );

        if (method.number_of_aditional_args != 0) {
            interpreter.report_runtime_error("Tried to call `perform:` with a method `{s}`, which requires {d} arguments. Consider using the `perform:withArgs:` method.", .{
                interpreter.string_from_symbol(method_selector), method.number_of_aditional_args,
            });
            return Interpreter.Error.generic_runtime_error;
        }
        try invoke(.{
            .receiver = self,
            .method = method,
            .maybe_args = null,
            .invoker_method = "perform:",
            .interpreter = interpreter,
        });
    }

    pub fn @"perform:withArguments:"(self: VmObject, method_selector: SymbolId, args: VmObject, interpreter: *Interpreter) Interpreter.Error!void {
        const class_definition = interpreter.get_class_of(self);
        const method = class_definition.get_method(method_selector) orelse return failed_finding_method(
            method_selector,
            class_definition,
            interpreter,
        );
        try invoke(.{
            .receiver = self,
            .method = method,
            .maybe_args = args,
            .invoker_method = "perform:",
            .interpreter = interpreter,
        });
    }

    pub fn @"perform:inSuperclass:"(
        self: VmObject,
        method_selector: SymbolId,
        super_class: *const ClassDefinition,
        interpreter: *Interpreter,
    ) Interpreter.Error!void {
        try check_class_is_actually_a_superclass(.{
            .child_class = interpreter.get_class_of(self),
            .supposed_superclass = super_class,
            .interpreter = interpreter,
        });
        const method = super_class.get_method(method_selector) orelse return failed_finding_method(
            method_selector,
            super_class,
            interpreter,
        );
        if (method.number_of_aditional_args != 0) {
            interpreter.report_runtime_error("Tried to call `perform:inSuperClass:` with a method `{s}`, which requires {d} arguments. Consider using the `perform:inSuperClass:withArguments:` method.", .{
                interpreter.string_from_symbol(method_selector), method.number_of_aditional_args,
            });
            return Interpreter.Error.generic_runtime_error;
        }
        try invoke(.{
            .receiver = self,
            .method = method,
            .maybe_args = null,
            .invoker_method = "perform:inSuperclass:",
            .interpreter = interpreter,
        });
    }

    pub fn @"perform:withArguments:inSuperclass:"(
        self: VmObject,
        method_selector: SymbolId,
        args: VmObject,
        super_class: *const ClassDefinition,
        interpreter: *Interpreter,
    ) Interpreter.Error!void {
        try check_class_is_actually_a_superclass(.{
            .child_class = interpreter.get_class_of(self),
            .supposed_superclass = super_class,
            .interpreter = interpreter,
        });
        const method = super_class.get_method(method_selector) orelse return failed_finding_method(
            method_selector,
            super_class,
            interpreter,
        );
        try invoke(.{
            .receiver = self,
            .method = method,
            .maybe_args = args,
            .invoker_method = "perform:withArguments:inSuperclass:",
            .interpreter = interpreter,
        });
    }

    pub fn @"instVarAt:"(self: VmObject, index: i48, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const instance_fields: []VmObject = self.get_instance_fields();
        const index_usize = try interpreter.check_out_of_bounds_get_1_based_index(.{
            .accessee = "array of instance fields",
            .length = instance_fields.len,
            .access_index = index,
        });
        return instance_fields[index_usize - 1];
    }

    pub fn @"instVarAt:put:"(self: VmObject, index: i48, new_object: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const instance_fields: []VmObject = self.get_instance_fields();
        const index_usize = try interpreter.check_out_of_bounds_get_1_based_index(.{
            .accessee = "array of instance fields",
            .length = instance_fields.len,
            .access_index = index,
        });
        if (new_object.as_block()) |block| {
            @branchHint(.cold);
            block.add_to_escaping_blocks_list();
        }
        instance_fields[index_usize - 1] = new_object;
        return self; // Return `self` according to the `inst_var_at_put.som` integration test
    }

    pub fn @"instVarNamed:"(self: VmObject, field_name: SymbolId, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const cls = interpreter.get_class_of(self);
        const instance_fields: []VmObject = self.get_instance_fields();
        for (cls.identifiers_of_instance_variables, 0..) |actual_field_name, index| {
            if (actual_field_name == field_name) {
                return instance_fields[index];
            }
        }
        interpreter.report_runtime_error("There is no instance field named `{s}` in class `{s}`.", .{
            interpreter.string_from_symbol(field_name), interpreter.string_from_symbol(cls.class_name),
        });
        return Interpreter.Error.generic_runtime_error;
    }
};

fn check_class_is_actually_a_superclass(
    params: struct {
        child_class: *const ClassDefinition,
        supposed_superclass: *const ClassDefinition,
        interpreter: *Interpreter,
    },
) Interpreter.Error!void {
    const child_class = params.child_class;
    const supposed_superclass = params.supposed_superclass;
    const interpreter = params.interpreter;

    var it_super_class: ?*const ClassDefinition = child_class;
    while (it_super_class) |current_super_class| {
        if (current_super_class == supposed_superclass) break;
        it_super_class = current_super_class.parent;
    } else {
        interpreter.report_runtime_error("Superclass argument `{s}` is not a superclass of the receiver, which is an instance of the class `{s}`.", .{
            interpreter.string_from_symbol(supposed_superclass.class_name),
            interpreter.string_from_symbol(child_class.class_name),
        });
        return Interpreter.Error.generic_runtime_error;
    }
}

fn failed_finding_method(method_selector: SymbolId, class_definition: *const ClassDefinition, interpreter: *Interpreter) Interpreter.Error!void {
    try interpreter.send_do_not_understand(class_definition, method_selector);
}

pub const Class = struct {
    pub fn new(class: *ClassDefinition, interpreter: *Interpreter) Interpreter.Error!VmObject {
        // NOTE(GC): We don't need GC protection here, because the `class` argument is from the static region.
        return try types.GenericObject.create_new(&interpreter.heap, class);
    }

    pub fn name(self: *const ClassDefinition) SymbolId {
        return self.class_name;
    }

    pub fn superclass(self: *ClassDefinition) VmObject {
        const parent = self.parent orelse return VmObject.nil;
        return VmObject.from(parent.as_vm_object);
    }

    pub fn fields(self: *ClassDefinition, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const fields_count = self.identifiers_of_instance_variables.len;
        const array = try types.Array.create_with_undefined_items(&interpreter.heap, fields_count);

        // Go through the instance field names of the entire class hiearchy.
        for (array.get_items(), self.identifiers_of_instance_variables) |*array_item, field_name| {
            array_item.* = VmObject.from_symbol(field_name);
        }

        return VmObject.from(array);
    }

    pub fn methods(self: *ClassDefinition, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const all_method_definitions = self.instance_methods.items;
        var non_inherited_methods_count: usize = 0;
        for (all_method_definitions) |method_definition| {
            if (method_definition.source_class == self) non_inherited_methods_count += 1;
        }

        // NOTE(GC):
        //      We don't have do GC protection here, because after creating the result object (array),
        //      we will not allocate anything else (the methods are already created objects).
        const array = try types.Array.create_with_undefined_items(&interpreter.heap, non_inherited_methods_count);
        const methods_slice = array.get_items();
        var result_array_index: usize = 0;
        for (all_method_definitions) |method_definition| {
            if (method_definition.source_class != self) continue;
            methods_slice[result_array_index] = VmObject.from(method_definition.as_vm_object);
            result_array_index += 1;
        }
        assert(result_array_index == non_inherited_methods_count);

        // We have to sort the methods by the order they were defined in.
        //
        // This is needed, because the test suite
        // `TestSuite/ClassStructureTest.som >> testThatCertainMethodsArePrimitives`
        // depends on this order because of this assert:
        // ```SOM
        //     m := Object methods at: 7.
        //     self optional: #invokableTypes assert: Method equals: m class.
        // ```
        std.sort.pdq(VmObject, methods_slice, {}, struct {
            fn less_than(_: void, lhs_obj: VmObject, rhs_obj: VmObject) bool {
                // SAFETY: The array should contain only methods.
                // We have just created this array and put only method objects into it.
                const lhs = lhs_obj.as_heap_object(.method).?.method().definition_order_index;
                const rhs = rhs_obj.as_heap_object(.method).?.method().definition_order_index;
                return lhs < rhs;
            }
        }.less_than);

        return VmObject.from(array);
    }
};

pub const Integer = struct {
    // ========================= Arithmetic =========================
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
    pub fn @"//"(self: i48, rhs_raw: Number) f64 {
        return @"//_on_numbers"(self, rhs_raw);
    }
    pub fn @"%"(self: i48, rhs_raw: Number, interpreter: *Interpreter) Interpreter.Error!i48 {
        const lhs = self;
        const rhs = rhs_raw.as_i48_maybe_lossy();
        const quotient: i48 = std.math.divFloor(i48, lhs, rhs) catch |err| switch (err) {
            error.DivisionByZero => {
                @branchHint(.cold);
                interpreter.report_runtime_error("Tried to compute {d} modulus 0.", .{self});
                return Interpreter.Error.division_by_zero;
            },
            error.Overflow => {
                // Happens when `lhs=minInt(i48)` and `rhs=-1`, therefore the result is `0` in such cases.
                assert(lhs == std.math.minInt(i48));
                assert(rhs == -1);
                return 0;
            },
        };

        return lhs - rhs * quotient;
    }
    pub fn @"rem:"(self: i48, rhs_raw: Number, interpreter: *Interpreter) Interpreter.Error!i48 {
        const rhs = rhs_raw.as_i48_maybe_lossy();
        if (rhs == 0) {
            @branchHint(.cold);
            interpreter.report_runtime_error("Tried to compute remainder of division of {d} by 0.", .{self});
            return Interpreter.Error.division_by_zero;
        }
        return self - rhs * @divTrunc(self, rhs);
    }
    pub fn @"&"(self: i48, rhs: i48) i48 {
        return self & rhs;
    }
    pub fn @"<<"(self: i48, rhs: i48) i48 {
        return std.math.shl(i48, self, rhs);
    }
    pub fn @">>>"(self: i48, rhs: i48) i48 {
        return std.math.shr(i48, self, rhs);
    }
    pub fn @"bitXor:"(self: i48, rhs: i48) i48 {
        return self ^ rhs;
    }
    pub fn sqrt(self: i48, interpreter: *Interpreter) Interpreter.Error!Number {
        if (self < 0) {
            @branchHint(.cold);
            interpreter.report_runtime_error("Tried to take a square root of a negative number: {d}.", .{self});
            return Interpreter.Error.generic_runtime_error;
        }
        const as_float: f64 = @floatFromInt(self);
        const result_float: f64 = std.math.sqrt(as_float);
        return Number.from_f64(result_float);
    }

    // ========================= Random numbers =========================
    pub fn atRandom(_: i48, interpreter: *Interpreter) i48 {
        var random = interpreter.prng.random();
        return random.int(i48);
    }

    // ========================= Comparing =========================
    pub fn @"="(self: i48, other: VmObject) bool {
        const other_as_number = other.as_number() orelse return false;

        switch (other_as_number) {
            .integer => |value| return self == value,
            .double => |value| return int_equals_double(self, value),
        }
    }
    pub fn @"<"(self: i48, rhs: Number) bool {
        return switch (rhs) {
            .integer => |value| self < value,
            .double => |value| self < @as(i48, @intFromFloat(std.math.ceil(value))),
        };
    }

    // ========================= Converting =========================
    pub fn asString(self: i48, interpreter: *Interpreter) Interpreter.Error!VmObject {
        // NOTE(GC): We don't have to protect `self` from GC, since `self: i48` is passed by value.
        return try types.String.create_new_fmt(&interpreter.heap, "{d}", .{self});
    }
    pub fn as32BitSignedValue(self: i48) i48 {
        const raw48: u48 = @bitCast(self);
        const raw32: u32 = @truncate(raw48);
        return @as(i32, @bitCast(raw32));
    }
    pub fn as32BitUnsignedValue(self: i48) i48 {
        const raw48: u48 = @bitCast(self);
        const raw32: u32 = @truncate(raw48);
        return raw32;
    }
    pub fn asDouble(self: i48) f64 {
        return @floatFromInt(self);
    }
};

pub const @"Integer class" = struct {
    pub fn @"fromString:"(_: IntegerClassPlaceholder, string: []const u8, interpreter: *Interpreter) Interpreter.Error!i48 {
        const fmt = "Could not convert '{s}' into an integer, because {s}. The value has been set to {d}.";
        return std.fmt.parseInt(i48, string, 10) catch |err| {
            var default_value: i48 = 0;
            if (err == error.Overflow) {
                if (string[0] == '-') {
                    default_value = std.math.minInt(i48);
                } else {
                    default_value = std.math.maxInt(i48);
                }
            }
            interpreter.report_runtime_error(fmt, .{
                string,
                if (string.len == 0) "the string is empty" else switch (err) {
                    std.fmt.ParseIntError.InvalidCharacter => "the string contains an invalid character",
                    std.fmt.ParseIntError.Overflow => "the integer is too large to fit into the internal representation of an integer",
                },
                default_value,
            });
            return default_value;
        };
    }
};

pub const Double = struct {
    // ========================= Arithmetic =========================
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
    pub fn @"//"(self: f64, rhs: Number) f64 {
        return @"//_on_numbers"(self, rhs);
    }
    /// NOTE: This method is not technically defined in the standard library, but we can keep it here.
    pub fn @"/"(self: f64, rhs: Number, interpreter: *Interpreter) Interpreter.Error!i48 {
        return @"/_on_numbers"(self, rhs, interpreter);
    }
    pub fn @"%"(self: f64, rhs_raw: Number) Interpreter.Error!f64 {
        const sign = std.math.sign;
        const lhs = self;
        const rhs = rhs_raw.as_f64();

        var quotient = @divTrunc(@abs(lhs), @abs(rhs));
        if (sign(lhs) != sign(rhs)) quotient *= -1;

        return lhs - quotient * rhs;
    }
    pub fn sqrt(self: f64) f64 {
        return std.math.sqrt(self); // Produces NaN if `self < 0`
    }
    pub fn round(self: f64) f64 {
        return std.math.round(self);
    }
    pub fn asInteger(self: f64, interpreter: *Interpreter) Interpreter.Error!i48 {
        if (self > std.math.maxInt(i48)) {
            interpreter.report_runtime_error("Could not convert the Double {d} into an integer (too big).", .{self});
            return Interpreter.Error.generic_runtime_error;
        }
        if (self < std.math.minInt(i48)) {
            interpreter.report_runtime_error("Could not convert the Double {d} into an integer (too small).", .{self});
            return Interpreter.Error.generic_runtime_error;
        }
        return @intFromFloat(self);
    }
    pub fn cos(self: f64) f64 {
        return std.math.cos(self);
    }
    pub fn sin(self: f64) f64 {
        return std.math.sin(self);
    }

    // ========================= Comparing =========================
    pub fn @"="(self: f64, other: VmObject) bool {
        const other_as_number = other.as_number() orelse return false;
        switch (other_as_number) {
            .integer => |value| return int_equals_double(value, self),
            .double => |value| return self == value,
        }
    }
    pub fn @"<"(self: f64, other: Number) bool {
        return self < other.as_f64();
    }

    // ========================= Converting =========================
    pub fn asString(self: f64, interpreter: *Interpreter) Interpreter.Error!VmObject {
        // NOTE(GC): We don't have to protect `self` from GC, since `self: f64` is passed by value.
        return try types.String.create_new_fmt(&interpreter.heap, "{d}", .{self});
    }
};

pub const @"Double class" = struct {
    pub fn PositiveInfinity(_: DoubleClassPlaceholder) f64 {
        return std.math.inf(f64);
    }

    /// NOTE:
    /// This method returns float `NaN` in case of a parse error, which is not correct
    /// according to 'core-lib/IntegrationTests/Tests/fromstring_double_err.som'
    /// - in case of a parse error, it should actually crash the program.
    ///
    /// But it makes more sense to not crash the entire application and
    /// the docs comment in 'core-lib/Smalltalk/Double.som'
    /// (which is something like a standard library)
    /// says that it actually SHOULD return `NaN`.
    pub fn @"fromString:"(_: DoubleClassPlaceholder, string: []const u8) f64 {
        return std.fmt.parseFloat(f64, string) catch std.math.nan(f64);
    }
};

pub const String = struct {
    pub fn @"concatenate:"(self: []const u8, other: []const u8, interpreter: *Interpreter) Interpreter.Error!VmObject {
        // NOTE(GC):
        //      We have to mark the arguments of this function as roots,
        //      otherwise the contenst of `self` and `other` could get deallocated.
        const p = protect_args_from_gc(@src(), interpreter);
        defer p.end_protection_from_gc(@src(), interpreter);

        return try types.String.create_new_fmt(
            &interpreter.heap,
            "{s}{s}",
            .{ self, other },
        );
    }

    // ========================= Converting =========================
    pub fn asSymbol(self: []const u8, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const symbol_id = (try interpreter.statics.symbols_manager.id_or_intern(self)).id;
        return VmObject.from_symbol(symbol_id);
    }
    pub fn hashcode(self: []const u8) i48 {
        const seed = 42;
        const raw: u48 = @truncate(std.hash.Wyhash.hash(seed, self));
        return @bitCast(raw);
    }

    // ========================= Info =========================
    pub fn length(self: []const u8) i48 {
        return @intCast(self.len);
    }

    // NOTE: All of the predicates here really return false for empty string...
    // See: 'core-lib/Smalltalk/String.som'
    // ========================= Predicates =========================
    pub fn isWhiteSpace(self: []const u8) bool {
        if (self.len == 0) return false;
        for (self) |chr| if (!std.ascii.isWhitespace(chr)) return false;
        return true;
    }
    pub fn isLetters(self: []const u8) bool {
        if (self.len == 0) return false;
        for (self) |chr| if (!std.ascii.isAlphabetic(chr)) return false;
        return true;
    }
    pub fn isDigits(self: []const u8) bool {
        if (self.len == 0) return false;
        for (self) |chr| if (!std.ascii.isDigit(chr)) return false;
        return true;
    }

    // ========================= Comparing =========================
    pub fn @"="(self: []const u8, other: VmObject, interpreter: *Interpreter) bool {
        const other_str = other.as_text(&interpreter.statics.symbols_manager) orelse return false;
        return std.mem.eql(u8, self, other_str);
    }

    // ========================= Substring implementation =========================
    pub fn @"primSubstringFrom:to:"(
        self: []const u8,
        from_idx_raw: i48,
        to_idx_raw: i48,
        interpreter: *Interpreter,
    ) Interpreter.Error!VmObject {
        const from_index: usize = try interpreter.check_out_of_bounds_get_1_based_index(.{
            .accessee = "an instance of String",
            .length = self.len,
            .access_index = from_idx_raw,
        });
        const to_index: usize = try interpreter.check_out_of_bounds_get_1_based_index(.{
            .accessee = "an instance of String",
            .length = self.len,
            .access_index = to_idx_raw,
        });
        if (to_index < from_idx_raw) {
            return types.String.create_new(&interpreter.heap, "");
        }

        const substring: []const u8 = self[(from_index - 1)..(to_index)];

        // NOTE(GC):
        //     We have to protect the contents of `substring` from getting collected,
        //     because `String.create_*` might trigger GC. We have to protect
        //     the object `self`, since the `substring` originates from it.
        const p = protect_args_from_gc(@src(), interpreter);
        defer p.end_protection_from_gc(@src(), interpreter);
        return try types.String.create_new(&interpreter.heap, substring);
    }
};

pub const Symbol = struct {
    pub fn asString(self: SymbolId, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const symbol_as_string: []const u8 = interpreter.statics.symbols_manager.symbol_with_id(self);
        return try types.String.create_new(&interpreter.heap, symbol_as_string);
    }
};

pub const Array = struct {
    pub fn @"at:"(self: []VmObject, index_raw: i48, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const index: usize = try interpreter.check_out_of_bounds_get_1_based_index(.{
            .accessee = "an instance of Array",
            .length = self.len,
            .access_index = index_raw,
        });
        return self[index - 1];
    }

    pub fn @"at:put:"(self: []VmObject, index_raw: i48, new_value: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const index: usize = try interpreter.check_out_of_bounds_get_1_based_index(.{
            .accessee = "an instance of Array",
            .length = self.len,
            .access_index = index_raw,
        });
        if (new_value.as_block()) |block| {
            @branchHint(.cold);
            block.add_to_escaping_blocks_list();
        }
        self[index - 1] = new_value;
        const orignal_array: VmObject = interpreter.stack.objects.ptr[interpreter.stack.objects.len - 1];
        return orignal_array;
    }

    pub fn length(self: []VmObject) i48 {
        return @intCast(self.len);
    }
};

pub const @"Array class" = struct {
    pub fn @"new:"(_: ArrayClassPlaceholder, length: usize, interpreter: *Interpreter) Interpreter.Error!*types.Array {
        // NOTE(GC):
        //     We don't need GC protection here, because after `Array.create_*`, we don't allocate.
        const array = try types.Array.create_with_undefined_items(&interpreter.heap, length);
        if (interpreter.nil_out_items_of_new_array) {
            for (array.get_items()) |*item| item.* = VmObject.nil; // This does not cause an allocation
        }
        return array;
    }
};

pub const System = struct {
    // ========================= Globals =========================
    pub fn @"global:"(_: VmObject, global_name: SymbolId, interpreter: *Interpreter) VmObject {
        return interpreter.globals.get(global_name) orelse VmObject.nil;
    }
    pub fn @"global:put:"(_: VmObject, global_name: SymbolId, new_value: VmObject, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        if (new_value.as_block()) |block| {
            @branchHint(.cold);
            block.add_to_escaping_blocks_list();
        }
        try interpreter.globals.put(global_name, new_value);
        return .{};
    }
    pub fn @"hasGlobal:"(_: VmObject, global_name: SymbolId, interpreter: *Interpreter) bool {
        return interpreter.globals.contains(global_name);
    }

    // ========================= File support =========================
    pub fn @"loadFile:"(_: VmObject, filepath: []const u8, interpreter: *Interpreter) Interpreter.Error!VmObject {
        var file = std.fs.cwd().openFile(filepath, .{ .mode = .read_only }) catch return VmObject.nil;
        defer file.close();

        const file_size = (file.stat() catch return VmObject.nil).size;

        // NOTE(GC): We don't need GC protection here, because after `String.create_*`, no allocations are done.
        const string_object: *types.String = try types.String.create_with_undefined_contents(
            &interpreter.heap,
            std.math.cast(i48, file_size) orelse return VmObject.nil,
        );
        var reader = file.reader(string_object.contents());
        _ = reader.interface.take(file_size) catch return VmObject.nil;

        return VmObject.from(string_object);
    }

    // ========================= Loading =========================
    pub fn @"load:"(_: VmObject, class_name: SymbolId, interpreter: *Interpreter) VmObject {
        const loaded_class: *ClassDefinition = interpreter.load_class(class_name) catch return VmObject.nil;
        return VmObject.from(loaded_class.as_vm_object);
    }

    // ========================= Exiting =========================
    pub fn @"exit:"(_: VmObject, error_code: i48, interpreter: *Interpreter) Interpreter.Error!void {
        const error_code_as_u8: u8 = std.math.cast(u8, error_code) orelse {
            interpreter.report_runtime_error("Invalid argument, got integer {d} but only integers from the range [0,255] are expected.", .{error_code});
            return Interpreter.Error.generic_runtime_error;
        };

        if (runtime_module.DEBUG_PRINT_STACK_ON_EXIT) {
            std.debug.print("The process will be terminated with the exit code: {d}.\n", .{error_code});
            interpreter.debug_print_stack() catch {};
        }

        interpreter.exit_code = error_code_as_u8;
        return Interpreter.Error.interpreter_halted;
    }

    // ========================= Input =========================
    pub fn getLine(_: VmObject, interpreter: *Interpreter) Interpreter.Error!VmObject {
        const stdin = interpreter.stdin orelse return VmObject.nil;
        const raw_line = stdin.takeDelimiterExclusive('\n') catch return VmObject.nil;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        return try types.String.create_new(&interpreter.heap, line);
    }

    // ========================= Printing =========================
    pub fn printNewline(_: VmObject, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        _ = try interpreter.stdout.writeAll(newline);
        try interpreter.stdout.flush();
        return .{};
    }
    pub fn @"printString:"(_: VmObject, string: []const u8, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        _ = try interpreter.stdout.writeAll(string);
        if (interpreter.do_flush_on_every_print) {
            try interpreter.stdout.flush();
        }
        return .{};
    }
    pub fn @"errorPrintln:"(_: VmObject, string: []const u8, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        _ = try interpreter.stderr.writeAll(string);
        _ = try interpreter.stderr.writeAll(newline);
        try interpreter.stderr.flush();
        return .{};
    }
    pub fn @"errorPrint:"(_: VmObject, string: []const u8, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        _ = try interpreter.stderr.writeAll(string);
        if (interpreter.do_flush_on_every_print) {
            try interpreter.stderr.flush();
        }
        return .{};
    }
    pub fn printStackTrace(_: VmObject, interpreter: *Interpreter) Interpreter.Error!NilPlaceholder {
        for (interpreter.stack.frames) |frame| {
            switch (frame.kind) {
                .method => |method| {
                    try interpreter.stderr.print("- Method {s}>>{s}\n", .{
                        interpreter.string_from_symbol(method.source_class.class_name),
                        interpreter.string_from_symbol(method.selector),
                    });
                },
                .block => |block| {
                    const method = block.home_method();
                    try interpreter.stderr.print("- Block from method {s}>>{s}\n", .{
                        interpreter.string_from_symbol(method.source_class.class_name),
                        interpreter.string_from_symbol(method.selector),
                    });
                },
            }
        }
        try interpreter.stderr.flush();
        return .{};
    }

    // ========================= Time =========================
    pub fn time(_: VmObject, interpreter: *Interpreter) i48 {
        var timer = interpreter.timer orelse return 0;
        const nanos = timer.read();
        const millis = nanos / 1000 / 1000;
        return std.math.lossyCast(i48, millis);
    }
    pub fn ticks(_: VmObject, interpreter: *Interpreter) i48 {
        var timer = interpreter.timer orelse return 0;
        const nanos = timer.read();
        const micros = nanos / 1000;
        return std.math.lossyCast(i48, micros);
    }

    // ========================= Force Garbage Collection =========================
    /// NOTE: yes, it should really return a `bool`, see `IntegrationTests/Tests/fullgc.com`
    pub fn fullGC(_: VmObject, interpreter: *Interpreter) Interpreter.Error!bool {
        try interpreter.heap.run_garbage_collection();
        return true;
    }
};

const newline = switch (builtin.os.tag) {
    .windows => "\r\n",
    else => "\n",
};

fn invoke(
    params: struct {
        receiver: VmObject,
        method: *const MethodDefinition,
        maybe_args: ?VmObject,
        invoker_method: []const u8,
        interpreter: *Interpreter,
    },
) Interpreter.Error!void {
    const receiver = params.receiver;
    const method = params.method;
    const maybe_args = params.maybe_args;
    const invoker_method = params.invoker_method;
    const interpreter = params.interpreter;

    const args_array: []VmObject = get_args_array: {
        const args = maybe_args orelse {
            assert(method.number_of_aditional_args == 0); // This should get handeled above
            break :get_args_array &.{};
        };

        const args_array = args.as_array() orelse {
            const class_name = interpreter.statics.symbols_manager.symbol_with_id(method.source_class.class_name);
            interpreter.report_runtime_error(
                "The method `{s}` expects an array of objects as arguments, but got non-array object of class {s}.",
                .{ invoker_method, class_name },
            );
            switch (method.number_of_aditional_args) {
                0 => _ = interpreter.report_info("Consider passing in an empty array, like this: `#( )`.", .{}) catch {},
                1 => _ = interpreter.report_info("Consider wrapping the argument into an array, like this: `#( <the-argument> )`.", .{}) catch {},
                else => {},
            }
            return Interpreter.Error.primitive_type_error;
        };

        if (method.number_of_aditional_args != args_array.len) {
            const method_selector = interpreter.statics.symbols_manager.symbol_with_id(method.selector);
            interpreter.report_runtime_error(
                "Passed incorrect number of arguments for the method `{s}`. Expected {d} arguments, but the arguments array has length {d}.",
                .{ method_selector, method.number_of_aditional_args, args_array.len },
            );
            return Interpreter.Error.generic_runtime_error;
        }

        break :get_args_array args_array;
    };

    // Now we put the arguments onto the stack but in a reverse order (according to the calling convention)
    var iter = std.mem.reverseIterator(args_array);
    while (iter.next()) |argument| try interpreter.push_object(argument);
    try interpreter.push_object(receiver); // The receiver object is the top-most argument on the stack before the call

    // Now call the method.
    // This will result in a new stack frame being created or an execution of primitive method,
    // then the interpreter will resume.
    try interpreter.call_method(method);
}

pub const Method = struct {
    pub fn signature(method: *const MethodDefinition) SymbolId {
        return method.selector;
    }

    pub fn holder(method: *const MethodDefinition) VmObject {
        return VmObject.from(method.source_class.as_vm_object);
    }

    pub fn @"invokeOn:with:"(
        method: *const MethodDefinition,
        receiver: VmObject,
        args: VmObject,
        interpreter: *Interpreter,
    ) Interpreter.Error!void {
        return invoke(.{
            .receiver = receiver,
            .method = method,
            .maybe_args = args,
            .invoker_method = "invokeOn:with:",
            .interpreter = interpreter,
        });
    }
};

pub const Primitive = struct {
    pub fn signature(method: PrimitiveMethodWrapper) SymbolId {
        return method.method_definition.selector;
    }

    pub fn holder(method: PrimitiveMethodWrapper) VmObject {
        return VmObject.from(method.method_definition.source_class.as_vm_object);
    }

    pub fn @"invokeOn:with:"(
        method: PrimitiveMethodWrapper,
        receiver: VmObject,
        args: VmObject,
        interpreter: *Interpreter,
    ) Interpreter.Error!void {
        return invoke(.{
            .receiver = receiver,
            .method = method.method_definition,
            .maybe_args = args,
            .invoker_method = "invokeOn:with:",
            .interpreter = interpreter,
        });
    }
};

pub const Block = struct {
    pub fn value(self: *types.Block, interpreter: *Interpreter) Interpreter.Error!void {
        try block_value_method(self, interpreter);
    }

    pub fn restart(_: *types.Block, interpreter: *Interpreter) void {
        interpreter.decoder.set_id_of_the_next_instruction(.{ .idx = 0 });
        interpreter.stack.pop_all_temporaries_from_top_frame();
    }
};

pub const Block1 = struct {
    pub fn value(self: *types.Block, interpreter: *Interpreter) Interpreter.Error!void {
        try block_value_method(self, interpreter);
    }
};

pub const Block2 = struct {
    pub fn @"value:"(self: *types.Block, argument: VmObject, interpreter: *Interpreter) Interpreter.Error!void {
        try interpreter.push_object(argument);
        try block_value_method(self, interpreter);
    }
};

pub const Block3 = struct {
    pub fn @"value:with:"(self: *types.Block, argument1: VmObject, argument2: VmObject, interpreter: *Interpreter) Interpreter.Error!void {
        // We have to push them onto the stack in a reverse order.
        // So the call is valid according to the calling convention!
        try interpreter.push_object(argument2);
        try interpreter.push_object(argument1);
        try block_value_method(self, interpreter);
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

fn @"//_on_numbers"(lhs_raw: anytype, rhs_raw: Number) f64 {
    const lhs: f64 = switch (@TypeOf(lhs_raw)) {
        i48 => @floatFromInt(lhs_raw),
        f64 => lhs_raw,
        else => |Invalid| @compileError(std.fmt.comptimePrint("Invalid type: `{s}`", .{@typeName(Invalid)})),
    };
    const rhs = rhs_raw.as_f64();
    return lhs / rhs;
}

const GcAllArgsProtector = struct {
    fn end_protection_from_gc(_: GcAllArgsProtector, comptime location: std.builtin.SourceLocation, interpreter: *Interpreter) void {
        const args_to_protect = helpers_module.get_method_arity_from_selector(location.fn_name);
        assert(interpreter.stack.objects.len >= args_to_protect);
        interpreter.stack.objects.len -= args_to_protect;
    }
};
fn protect_args_from_gc(comptime location: std.builtin.SourceLocation, interpreter: *Interpreter) GcAllArgsProtector {
    const args_to_protect = comptime helpers_module.get_method_arity_from_selector(location.fn_name);
    assert(interpreter.stack.max_objects_len >= interpreter.stack.objects.len + args_to_protect);
    interpreter.stack.objects.len += args_to_protect;
    return .{};
}

fn int_equals_double(int: i48, double: f64) bool {
    const ceil = std.math.lossyCast(i48, std.math.ceil(double));
    const floor = std.math.lossyCast(i48, std.math.floor(double));
    return int == ceil and int == floor;
}

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const unions = @import("../../unions.zig");

const interning_module = @import("../../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

const helpers_module = @import("helpers.zig");
const NilPlaceholder = helpers_module.NilPlaceholder;
const PrimitiveMethodWrapper = helpers_module.PrimitiveMethodWrapper;
const ArrayClassPlaceholder = helpers_module.ArrayClassPlaceholder;
const IntegerClassPlaceholder = helpers_module.IntegerClassPlaceholder;
const DoubleClassPlaceholder = helpers_module.DoubleClassPlaceholder;

const runtime_module = @import("../__runtime.zig");
const Interpreter = runtime_module.Interpreter;
const Heap = runtime_module.Heap;
const BlockDefinition = runtime_module.BlockDefinition;
const MethodDefinition = runtime_module.MethodDefinition;
const types = runtime_module.types;
const ClassDefinition = runtime_module.ClassDefinition;
const VmObject = runtime_module.VmObject;
const HeapData = runtime_module.HeapData;
const Number = runtime_module.Number;

const bytecode_module = @import("../../bytecode/__bytecode.zig");
