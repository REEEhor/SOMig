const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const colors = @import("../terminal.zig");

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;

const interning_module = @import("../interning/symbols_manager.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;

const codegen_module = @import("../frontend/codegen.zig");
const InstructionDecoder = codegen_module.InstructionDecoder;
const Instruction = codegen_module.Instruction;
const ConstantsManager = codegen_module.ConstantsManager;
const ConstantId = codegen_module.ConstantId;
const RelativeConstantId = codegen_module.RelativeConstantId;
const InstructionId = codegen_module.InstructionId;

pub const stack_size = 4096;

// TODO: track the current function (which will be probably in the final `stack` implementation, which will also store stack frames)
// and use it for error reporting.
pub const Interpreter = struct {
    decoder: *InstructionDecoder,
    constants_manager: *ConstantsManager,
    symbols_manager: *SymbolsManager,
    stdout: *Writer,
    stderr: *Writer,
    allocator: Allocator,
    primitive_methods: PrimitiveMethodsMap,

    stack_top: usize = 0,
    stack: [4096]SomObject = undefined,

    /// Mapping: `name_of_the_class` -> `class`
    class_map: std.AutoHashMap(SymbolId, Class),

    // TODO: here will be an `current_class: *Class` I think
    current_class_constant_base_id: ConstantId,

    const Self = @This();

    pub const Error = error{
        primitive_type_error,
        method_not_found,
        stack_overflow,
        class_declared_multiple_times,
        division_by_zero,
        TODO,
    } || Allocator.Error || Writer.Error;

    pub fn new(
        allocator: Allocator,
        decoder: *InstructionDecoder,
        constants_manager: *ConstantsManager,
        strings_manager: *SymbolsManager,
        stdout: *Writer,
        stderr: *Writer,
        primitive_methods: PrimitiveMethodsMap,
    ) Interpreter {
        return Interpreter{
            .allocator = allocator,
            .decoder = decoder,
            .stdout = stdout,
            .stderr = stderr,
            .constants_manager = constants_manager,
            .symbols_manager = strings_manager,
            .class_map = std.AutoHashMap(SymbolId, Class).init(allocator),
            .primitive_methods = primitive_methods,
            .current_class_constant_base_id = ConstantId{ .idx = 0 },
        };
    }

    /// Takes the `primitive_methods` of the `Interpreter` and makes them into a classes with only the primitive methods.
    /// This is temporary, since later `primitive_methods` should be used only to retrive information about
    /// primitive methods during the loading of a class
    /// TODO: remove this once we can load individial classes and their definitions
    pub fn TODO_REMOVE_THIS__add_implementations_of_primitive_classes(self: *Self) Error!void {
        for (self.primitive_methods.sorted_classes) |primitive_class| {
            var vm_class = Class.empty;
            for (primitive_class.sorted_methods) |primitive_method| {
                vm_class.add_method(self.allocator, .instance_method, primitive_method.method_name, Method{
                    .number_of_aditional_args = primitive_method.args_cnt - 1,
                    .body = MethodBody{ .primitive = primitive_method.function },
                }) catch |err| switch (err) {
                    error.duplicate => {
                        std.debug.print(
                            "A duplicate method inside a primary class was found: `{s}` (id={d})\n",
                            .{ self.symbols_manager.symbol_with_id(primitive_method.method_name), primitive_method.method_name.idx },
                        );
                        std.debug.print("This should not happen, but we are not handeling that since this method will get remove :D\n", .{});
                        unreachable;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            const register_result = try self.register_class(primitive_class.class_name, vm_class);
            assert(!register_result.is_already_registered);
        }
    }

    // TODO: for a better error reporting, store where a class is defined (for example the filepath to its file)
    // and return it in an optional string here.
    pub fn register_class(self: *Self, class_name: SymbolId, class: Class) Error!struct { is_already_registered: bool } {
        const entry = try self.class_map.getOrPut(class_name);
        if (entry.found_existing) {
            return .{ .is_already_registered = true };
        }
        entry.value_ptr.* = class;
        return .{ .is_already_registered = false };
    }

    // TODO: here will be argument for an entire class that is being run.. I think
    pub fn run(self: *Self) Error!void {
        while (true) {
            const instruction: Instruction = self.decoder.next_instruction() orelse {
                try self.report_info("The end of the bytecode has been reached.", .{});
                return;
            };
            switch (instruction) {
                .no_op => {},
                .halt => {
                    try self.report_info("The halt instruction has been encountered.", .{});
                    return;
                },
                .print => {
                    const to_print: SomObject = self.pop_stack();
                    // TODO: do this using the `println` message or `toString` or something
                    switch (to_print) {
                        .integer => |value| try self.stdout.print("{d}\n", .{value}),
                        .double => |value| try self.stdout.print("{d}\n", .{value}),
                        .string => |value| try self.stdout.print("{s}\n", .{value}),
                    }
                },
                .duplicate => {
                    const object = self.get_stack_top();
                    try self.push_stack(object);
                },
                .load_constant => |constant_info| {
                    const constant_id: ConstantId = constant_info.id.to_absolute(self.current_class_constant_base_id);
                    const constant = self.constants_manager.get_constant(constant_id);
                    const object: SomObject = switch (constant) {
                        .integer => |value| .{ .integer = value },
                        .float => |value| .{ .double = value },
                        .string => |value| .{ .string = value },
                    };
                    try self.push_stack(object);
                },
                .send_message => |call_info| {
                    try self.send_message(call_info);
                },
            }
        }
        unreachable;
    }

    inline fn send_message(self: *Self, call_info: Instruction.SendMessage) Error!void {
        const target_object: SomObject = self.pop_stack();
        const class: *const Class = try self.fetch_class(
            // TODO(for SomClass): probably don't store the name of the class but just the `SymbolId`
            // and don't do this lookup in the `self.strings_manager`
            self.symbols_manager.id_of(target_object.class_name()).?,
        );
        const method: *const Method = class.instance_methods.getPtr(call_info.message_name) orelse {
            // TODO: also check the parent classes (multiple!) if the method exists or no
            // TODO(consultation): what about copying the implementation into the child classes from the parent classes
            //  idea from Crafting interpreters:  https://craftinginterpreters.com/superclasses.html
            self.report_runtime_error(
                "Tried to call the method `{s}` on an instance of a class `{s}`, but that does not exist.",
                .{ self.symbols_manager.symbol_with_id(call_info.message_name), target_object.class_name() },
            );
            // TODO: maybe also print the methods that exist on that class?
            return Error.method_not_found;
        };

        switch (method.body) {
            .user_land => {
                // TODO: handle `user_land` methods
                return self.report_TODO(
                    "Tried calling the method `{s}` which is defined in user land and we don't do user land methods yet :)",
                    .{self.symbols_manager.symbol_with_id(call_info.message_name)},
                );
            },
            .primitive => |primitive_method| {
                const result_object: SomObject = primitive_method(target_object, self) catch |err| {
                    // TODO: remove this once we have a propper stack trace
                    self.report_info(
                        "Error happened in the primitive method `{s}` of class `{s}`",
                        .{ self.symbols_manager.symbol_with_id(call_info.message_name), target_object.class_name() },
                    ) catch {};
                    return err;
                };
                try self.push_stack(result_object);
            },
        }
    }

    inline fn fetch_class(self: *Self, class_name_id: SymbolId) Error!*const Class {
        // TODO: if the class is not found, the interpreter should go and find the class definition
        const class = self.class_map.getPtr(class_name_id) orelse {
            std.debug.print("Could not find the class `{s}`\n", .{self.symbols_manager.symbol_with_id(class_name_id)});
            unreachable;
        };
        return class;
    }

    inline fn get_stack_top(self: *Self) SomObject {
        assert(self.stack_top > 0);
        return self.stack[self.stack_top - 1];
    }

    inline fn pop_stack(self: *Self) SomObject {
        const top_object: SomObject = self.get_stack_top();
        self.stack_top -= 1;
        return top_object;
    }

    inline fn push_stack(self: *Self, object: SomObject) Error!void {
        // TODO(consultation): should the stack maybe grow here?
        if (self.stack_top >= self.stack.len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow! :D", .{});
            return Error.stack_overflow;
        }

        self.stack[self.stack_top] = object;
        self.stack_top += 1;
    }

    fn report_info(self: *Self, comptime fmt: []const u8, args: anytype) Error!void {
        try self.stderr.print(colors.GREEN ++ "[runtime-info] " ++ colors.RESET ++ fmt ++ "\n", args);
    }

    // TODO: remove this once all the major features are implemented
    fn report_TODO(self: *Self, comptime fmt: []const u8, args: anytype) error{TODO} {
        self.stderr.print(colors.ERR ++ "[TODO (not implemented)] " ++ colors.RESET ++ fmt ++ "\n", args) catch {};
        return error.TODO;
    }

    fn report_runtime_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        // Ignore error since we report errors when there already is an error
        self.stderr.print(colors.ERR ++ "[runtime-error] " ++ colors.RESET ++ fmt ++ "\n", args) catch return;
    }

    // TODO: position of the error
    fn report_primitive_method_type_mismatch(
        self: *Self,
        expected_type_name: []const u8,
        actual_type_name: []const u8,
        method_name: []const u8,
    ) Error {
        // Ignore error since we eport errors when there already is an error
        self.report_runtime_error(
            "In method `{s}`, the argument had type `{s}`, which was not possible to convert to required type `{s}`",
            .{ method_name, actual_type_name, expected_type_name },
        );
        return Error.primitive_type_error;
    }
};

pub const Class = struct {
    instance_methods: MethodMap,
    class_methods: MethodMap,

    // TODO: add pointer to parent class
    // TODO: add pointer to the singleton SOM object of class `Class`
    // TODO: remove `class_methods`

    pub const empty = Class{ .instance_methods = .empty, .class_methods = .empty };

    const Self = @This();

    /// TODO(cleanup): use sorted array (not even ArrayList) with binary search on top
    pub const MethodMap = std.AutoHashMapUnmanaged(SymbolId, Method);
    pub const InitPair = struct { method_name_id: SymbolId, method: Method };

    pub const AddMethodError = error{duplicate} || Allocator.Error;
    pub fn add_method(
        self: *Self,
        allocator: Allocator,
        instance_or_class: enum { instance_method, class_method },
        method_name: SymbolId,
        method: Method,
    ) AddMethodError!void {
        const map_to_update: *MethodMap = switch (instance_or_class) {
            .instance_method => &self.instance_methods,
            .class_method => &self.class_methods,
        };
        const entry = try map_to_update.getOrPut(allocator, method_name);
        if (entry.found_existing) {
            return error.duplicate;
        }
        entry.value_ptr.* = method;
    }
};

pub const PrimitiveMethodsMap = struct {
    const Self = @This();

    /// Stores a list of primitive methods in a class.
    pub const PrimitiveClass = struct {
        class_name: SymbolId,
        /// This is a slice of the `PrimitiveMethodsMap.all_methods` array
        sorted_methods: []PrimitiveMethod,

        pub fn get_method(self: Self, method_name: SymbolId) ?*const PrimitiveMethod {
            const maybe_idx: ?usize = std.sort.binarySearch(PrimitiveMethod, self.sorted_methods, method_name, struct {
                fn compare(method_name_id: SymbolId, method: PrimitiveMethod) std.math.Order {
                    return std.math.order(method_name_id, method.method_name);
                }
            }.compare);

            if (maybe_idx) |idx| {
                return &self.sorted_methods[idx];
            }
            return null;
        }
    };
    const PrimitiveMethod = struct { method_name: SymbolId, function: PrimitiveMethodImplementation, args_cnt: u8 };

    sorted_classes: []PrimitiveClass,
    all_methods: []PrimitiveMethod,

    ///
    /// Creates a new instance of `PrimitiveMethodsMap` via doing a comptime reflection on `primitives_module` argument.
    ///
    /// `primitives_module` is expected to be a type struct in this form:
    /// ```zig
    ///     pub const some_primitives_module = struct {
    ///         pub const SomePrimitiveClassInSom = struct {
    ///             pub fn someMethod__somig_arity = 2; // or some other number
    ///             pub fn someSomMethod__somig_primitive_fn {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             pub fn someOtherMethod__somig_arity = 1; // or some other number
    ///             pub fn someOtherSomMethod__somig_primitive_fn {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             ... // other methods and their arities
    ///         }
    ///
    ///         pub const AnotherClass = struct {
    ///             pub fn somMethod1__somig_arity = 2; // or some other number
    ///             pub fn somMethod1__somig_primitive_fn {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             ... // other methods and their arities
    ///         }
    ///
    ///         ... // other classes definitions
    ///     }
    /// ```
    ///
    pub fn init_from(
        allocator: Allocator,
        comptime primitives_module: type,
        strings_manager: *SymbolsManager,
    ) Allocator.Error!Self {
        const primitive_fn_postfix = "__somig_primitive_fn";
        const fn_arity_postix = "__somig_arity";
        const module_info: std.builtin.Type.Struct = @typeInfo(primitives_module).@"struct";

        // Get the number of primitive classes and their methods
        // so the arraylists below don't have to realloc.
        const pritimive_classes_cnt = module_info.decls.len;
        comptime var primitive_methods_cnt = 0;
        //
        inline for (module_info.decls) |decl| {
            inline for (@typeInfo(@field(primitives_module, decl.name)).@"struct".decls) |primitive_decl| {
                if (comptime std.mem.endsWith(u8, primitive_decl.name, primitive_fn_postfix)) {
                    primitive_methods_cnt += 1;
                }
            }
        }

        var classes = try std.ArrayList(PrimitiveClass).initCapacity(allocator, pritimive_classes_cnt);
        var methods = try std.ArrayList(PrimitiveMethod).initCapacity(allocator, primitive_methods_cnt);

        // Go through each primitive class
        inline for (module_info.decls) |module_decl| {
            const primitive_type_name = module_decl.name;
            const PrimitiveType: type = @field(primitives_module, primitive_type_name);
            const primitive_type_info = @typeInfo(PrimitiveType).@"struct";
            const methods_start = methods.items.len;

            // Go through each declaration in the primitive class
            // and find all functions that are supposed to be implementations of primitive SOM methods
            inline for (primitive_type_info.decls) |decl| {
                if (comptime !std.mem.endsWith(u8, decl.name, primitive_fn_postfix)) continue;
                const fn_name = decl.name[0..(decl.name.len - primitive_fn_postfix.len)];
                const fn_arity: comptime_int = @field(PrimitiveType, fn_name ++ fn_arity_postix);
                const fn_impl: PrimitiveMethodImplementation = @field(PrimitiveType, decl.name);

                const primitive_method = PrimitiveMethod{
                    .method_name = (try strings_manager.id_or_intern(fn_name)).id,
                    .function = fn_impl,
                    .args_cnt = fn_arity,
                };
                methods.appendAssumeCapacity(primitive_method);
            }

            // Sort the methods by their symbol id so they can be looked up later using binary sort
            const methods_end = methods.items.len;
            const methods_slice = methods.items[methods_start..methods_end];
            std.sort.pdq(PrimitiveMethod, methods_slice, {}, primitive_method_less_than_fn);

            const class = PrimitiveClass{
                .class_name = (try strings_manager.id_or_intern(primitive_type_name)).id,
                .sorted_methods = methods_slice,
            };
            classes.appendAssumeCapacity(class);
        }

        // Sort the classes by their symbol id so they can be looked up later using binary sort
        std.sort.pdq(PrimitiveClass, classes.items, {}, primitive_class_less_than_fn);

        // TODO: remove this, once there are tests, that would catch the error that the assert below is trying to catch
        // Sanity check - there is no big cost to this, there are not many primitive methods and classses
        for (classes.items) |class| {
            const is_sorted = std.sort.isSorted(PrimitiveMethod, class.sorted_methods, {}, primitive_method_less_than_fn);
            assert(is_sorted);
        }

        assert(classes.items.len == classes.capacity);
        assert(methods.items.len == methods.capacity);

        return PrimitiveMethodsMap{
            .sorted_classes = classes.items,
            .all_methods = methods.items,
        };
    }

    pub fn get_primitive_class(self: Self, class_name: SymbolId) ?*const PrimitiveClass {
        const maybe_idx: ?usize = std.sort.binarySearch(PrimitiveClass, self.sorted_classes, class_name, struct {
            fn compare(class_name_id: SymbolId, class: PrimitiveClass) std.math.Order {
                return std.math.order(class_name_id, class.class_name);
            }
        }.compare);

        if (maybe_idx) |idx| {
            return &self.sorted_classes[idx];
        }
        return null;
    }

    fn primitive_method_less_than_fn(_: void, a: PrimitiveMethod, b: PrimitiveMethod) bool {
        return a.method_name.idx < b.method_name.idx;
    }

    fn primitive_class_less_than_fn(_: void, a: PrimitiveClass, b: PrimitiveClass) bool {
        return a.class_name.idx < b.class_name.idx;
    }
};

pub const Method = struct {
    /// Number of arguments to pop from stack
    /// (**excluding** the first argument which is the message target object).
    ///
    /// For example, every unary method has this field set to 0 and every binary method to 1.
    /// Keyword method `get:with:AndWith:` (example method) has this field set to 3.
    ///
    /// TODO(consultation): This field might be probably needed only for asserts when we do a dynamic call into a method.
    ///                     NOTE: maybe not, we might need it for a stackframe creation
    number_of_aditional_args: u8,
    body: MethodBody,
};

pub const PrimitiveMethodImplementation = *const fn (target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject;

pub const MethodBody = union(enum) {
    primitive: PrimitiveMethodImplementation,
    user_land: struct { start_instruction: InstructionId },
};

pub const SomObject = union(enum) {
    integer: i64,
    double: f64,
    string: []const u8,

    const Self = @This();
    pub fn to_integer(self: Self) ?i64 {
        return switch (self) {
            .integer => |value| value,
            .double => |value| @intFromFloat(value),
            .string => null,
        };
    }

    pub fn to_double(self: Self) ?f64 {
        return switch (self) {
            .integer => |value| @floatFromInt(value),
            .double => |value| value,
            .string => null,
        };
    }

    /// TODO(for SomClass): extract this information from the header of the SOM object in the future
    pub fn class_name(self: Self) []const u8 {
        return switch (self) {
            .integer => "Integer",
            .double => "Double",
            .string => "String",
        };
    }
};

// TODO: move this into another file called `primitives`
// But then, private methods on `Interpreter` will not be accesible from here... eh, doesn't matter probably
//
// TODO: split the classes definitions into "instance" and "class" parts
pub const primitives = struct {
    pub const Integer = struct {
        pub const @"+__somig_arity" = 2;
        pub fn @"+__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            return try binary_method(target_object, interpreter, struct {
                fn f(lhs: i64, rhs: i64) Interpreter.Error!i64 {
                    return lhs + rhs;
                }
            }.f);
        }

        pub const @"-__somig_arity" = 2;
        pub fn @"-__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            return try binary_method(target_object, interpreter, struct {
                fn f(lhs: i64, rhs: i64) Interpreter.Error!i64 {
                    return lhs - rhs;
                }
            }.f);
        }

        pub const @"*__somig_arity" = 2;
        pub fn @"*__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            return try binary_method(target_object, interpreter, struct {
                fn f(lhs: i64, rhs: i64) Interpreter.Error!i64 {
                    return lhs * rhs;
                }
            }.f);
        }

        pub const @"/__somig_arity" = 2;
        pub fn @"/__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            const i64_dividion = struct {
                fn f(lhs: i64, rhs: i64) Interpreter.Error!i64 {
                    if (rhs == 0) {
                        @branchHint(.unlikely);
                        return Interpreter.Error.division_by_zero;
                    }
                    // TODO: Check if this is the correct behaviour. This is probably the behaviour of `//` on the `Integer` class
                    // TODO: Also check if the `/` method rounds towards zero or -infinity (in case of towards zero, change to `@divTrunc`)
                    return @divFloor(lhs, rhs);
                }
            }.f;

            const result_object = binary_method(target_object, interpreter, i64_dividion) catch |err| {
                if (err == error.division_by_zero) interpreter.report_runtime_error("Division by zero", .{});
                return err;
            };
            return result_object;
        }

        pub const asString__somig_arity = 2;
        pub fn asString__somig_primitive_fn(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            const receiver_as_int: i64 = target_object.integer;
            // TODO: use interpter string allocator
            const receiver_as_str: []u8 = try std.fmt.allocPrint(interpreter.allocator, "{d}", .{receiver_as_int});
            return SomObject{ .string = receiver_as_str };
        }

        fn binary_method(
            target_object: SomObject,
            interpreter: *Interpreter,
            comptime op: fn (i64, i64) Interpreter.Error!i64,
        ) Interpreter.Error!SomObject {
            const lhs_int = target_object.integer;
            const rhs_object = interpreter.pop_stack();
            // TODO: better error reporting
            const rhs_int = rhs_object.to_integer() orelse return Interpreter.Error.primitive_type_error;
            const result_int = try op(lhs_int, rhs_int);
            const result_object = SomObject{ .integer = result_int };
            return result_object;
        }
    };

    pub const Double = struct {
        pub const @"+__somig_arity" = 2;
        pub fn @"+__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs + rhs;
                }
            }.f);
        }

        pub const @"-__somig_arity" = 2;
        pub fn @"-__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs - rhs;
                }
            }.f);
        }

        pub const @"*__somig_arity" = 2;
        pub fn @"*__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs * rhs;
                }
            }.f);
        }

        pub const @"/__somig_arity" = 2;
        pub fn @"/__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            return binary_method(target_object, interpreter, struct {
                fn f(lhs: f64, rhs: f64) Interpreter.Error!f64 {
                    return lhs / rhs;
                }
            }.f);
        }

        pub const asString__somig_arity = 2;
        pub fn asString__somig_primitive_fn(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            const receiver_as_double: f64 = target_object.double;
            // TODO: use interpter string allocator
            const receiver_as_str: []u8 = try std.fmt.allocPrint(interpreter.allocator, "{d}", .{receiver_as_double});
            return SomObject{ .string = receiver_as_str };
        }

        fn binary_method(
            target_object: SomObject,
            interpreter: *Interpreter,
            comptime op: fn (f64, f64) Interpreter.Error!f64,
        ) Interpreter.Error!SomObject {
            const lhs_double = target_object.double;
            const rhs_object = interpreter.pop_stack();
            // TODO: better error reporting
            const rhs_double = rhs_object.to_double() orelse return Interpreter.Error.primitive_type_error;
            const result_double = try op(lhs_double, rhs_double);
            const result_object = SomObject{ .double = result_double };
            return result_object;
        }
    };

    pub const String = struct {
        // TODO: remove this from primitive methods (it is not a primitive)
        pub const asString__somig_arity = 2;
        pub fn asString__somig_primitive_fn(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            _ = interpreter;
            return target_object;
        }

        // TODO: Remove this, the primitive method is called `concatenate:` and `+` is just an alias to it
        // NOTE: Implementing `concatenate:` should be easier, since the argument it takes in is a string
        pub const @"+__somig_arity" = 1;
        pub fn @"+__somig_primitive_fn"(target_object: SomObject, interpreter: *Interpreter) Interpreter.Error!SomObject {
            const receiver = target_object.string;

            const rhs_obj = interpreter.pop_stack();
            const rhs_str = switch (rhs_obj) {
                .integer => try Integer.asString__somig_primitive_fn(rhs_obj, interpreter),
                .double => try Double.asString__somig_primitive_fn(rhs_obj, interpreter),
                .string => rhs_obj,
            };

            const concatenated_result = try std.fmt.allocPrint(interpreter.allocator, "{s}{s}", .{ receiver, rhs_str.string });
            return SomObject{ .string = concatenated_result };
        }
    };
};
