const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const unions = @import("../../unions.zig");

const helpers_module = @import("helpers.zig");
const primitive_fn_postfix = helpers_module.primitive_fn_postfix;
const get_method_arity_from_selector = helpers_module.get_method_arity_from_selector;
const NilPlaceholder = helpers_module.NilPlaceholder;

const interpreter_module = @import("../__interpreter.zig");
const Interpreter = interpreter_module.Interpreter;

const interning_module = @import("../../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;
const SymbolArrayMap = interning_module.SymbolArrayMap;

const vm_object_module = @import("../vm_object.zig");
const VmObject = vm_object_module.VmObject;
const types = vm_object_module.types;

pub const PrimitiveMethodsMap = struct {
    sorted_classes: SortedClasses,
    all_methods: []PrimitiveMethod,

    const Self = @This();
    pub const SortedClasses = SymbolArrayMap(PrimitiveClass, "class_name");
    pub const SortedMethods = SymbolArrayMap(PrimitiveMethod, "method_name");

    /// Stores a list of primitive methods in a class.
    pub const PrimitiveClass = struct {
        class_name: SymbolId,

        /// This contains a slice of the `PrimitiveMethodsMap.all_methods` array
        methods: SortedMethods,

        pub fn get_method(self: @This(), method_name: SymbolId) ?*const PrimitiveMethod {
            return self.methods.get_ptr(method_name);
        }
    };
    const PrimitiveMethod = struct {
        method_name: SymbolId,
        function: PrimitiveMethodImplementation,
        args_cnt: u8,
    };

    /// FIXME: this comment is outdated
    /// Creates a new instance of `PrimitiveMethodsMap` via doing a comptime reflection on `primitives_module` argument.
    ///
    /// `primitives_module` is expected to be a type struct in this form:
    /// ```zig
    ///     pub const some_primitives_module = struct {
    ///         pub const SomePrimitiveClassInSom = struct {
    ///             pub fn someMethod__somig_arity = 2; // or some other number
    ///             pub fn someSomMethod__somig_primitive_fn (...) {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             pub fn someOtherMethod__somig_arity = 1; // or some other number
    ///             pub fn someOtherSomMethod__somig_primitive_fn (...) {...} // signature as `PrimitiveMethodImplementation`
    ///
    ///             ... // other methods and their arities
    ///         }
    ///
    ///         pub const AnotherClass = struct {
    ///             pub fn somMethod1__somig_arity = 2; // or some other number
    ///             pub fn somMethod1__somig_primitive_fn (...) {...} // signature as `PrimitiveMethodImplementation`
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
        symbols_manager: *SymbolsManager,
    ) Allocator.Error!Self {
        @setEvalBranchQuota(2000);

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
                const fn_arity: comptime_int = comptime get_method_arity_from_selector(fn_name);
                const fn_impl: PrimitiveMethodImplementation = create_primitive_method_implementation(
                    @field(PrimitiveType, decl.name),
                    primitive_type_name,
                    fn_name,
                );

                const primitive_method = PrimitiveMethod{
                    .method_name = (try symbols_manager.id_or_intern(fn_name)).id,
                    .function = fn_impl,
                    .args_cnt = fn_arity,
                };
                methods.appendAssumeCapacity(primitive_method);
            }

            // Sort the methods by their symbol id so they can be looked up later using binary sort
            const methods_end = methods.items.len;
            const methods_slice = methods.items[methods_start..methods_end];
            // We can assume there will be no duplicates, since the methods got parsed from a `struct` definition
            const sorted_methods_slice = SortedMethods.from_slice(methods_slice).ok;

            const class = PrimitiveClass{
                .class_name = (try symbols_manager.id_or_intern(primitive_type_name)).id,
                .methods = sorted_methods_slice,
            };
            classes.appendAssumeCapacity(class);
        }

        assert(classes.items.len == classes.capacity);
        assert(methods.items.len == methods.capacity);

        const sorted_classes = SortedClasses.from_slice(classes.items).ok;

        return PrimitiveMethodsMap{
            .sorted_classes = sorted_classes,
            .all_methods = methods.items,
        };
    }

    // NOTE(epic-zig)
    fn create_primitive_method_implementation(
        function: anytype,
        comptime class_name: []const u8,
        comptime fn_selector: []const u8,
    ) PrimitiveMethodImplementation {
        const Function = @TypeOf(function);
        const function_info = @typeInfo(Function).@"fn";
        const ReturnType = blk: {
            const MaybeErrorUnion = function_info.return_type.?;
            if (unions.get_payload(@typeInfo(MaybeErrorUnion), .error_union)) |error_union| {
                break :blk error_union.payload;
            }
            break :blk MaybeErrorUnion;
        };
        const Arguments = std.meta.ArgsTuple(Function);
        return struct {
            fn primitive_method_implementation(interpreter: *Interpreter) Interpreter.Error!?VmObject {
                // Pop arguments from the `interpreter`s stack, assert that they are the correct type and
                // put them into this `arguments` variable
                var arguments: Arguments = undefined;
                comptime var som_parameter_idx = 0;
                inline for (function_info.params, 0..) |parameter, inner_function_parameter_idx| {
                    const Parameter = parameter.type.?;
                    const argument: Parameter = switch (Parameter) {
                        NilPlaceholder => switch (interpreter.pop_object().kind()) {
                            .nil => .{},
                            else => return invalid_argument(interpreter, som_parameter_idx, "Nil"),
                        },
                        f64 => switch (interpreter.pop_object().kind()) {
                            .integer => |integer| @floatFromInt(integer.header.value),
                            .double => |double| double.value,
                            else => return invalid_argument(interpreter, som_parameter_idx, "Integer or Double"),
                        },
                        i48 => switch (interpreter.pop_object().kind()) {
                            .integer => |integer| integer.header.value,
                            .double => |double| std.math.lossyCast(i48, double.value),
                            else => return invalid_argument(interpreter, som_parameter_idx, "Integer or Double"),
                        },
                        *types.Class => switch (interpreter.pop_object().kind()) {
                            .class => |class| class,
                            else => return invalid_argument(interpreter, som_parameter_idx, "Class"),
                        },
                        *types.Array => switch (interpreter.pop_object().kind()) {
                            .array => |array| array,
                            else => return invalid_argument(interpreter, som_parameter_idx, "Array"),
                        },
                        []VmObject => switch (interpreter.pop_object().kind()) {
                            .array => |array| array.get_items(),
                            else => return invalid_argument(interpreter, som_parameter_idx, "Array"),
                        },
                        []const u8 => switch (interpreter.pop_object().kind()) {
                            .string => |string| string.contents(),
                            .symbol => |symbol| interpreter.statics.symbols_manager.symbol_with_id(symbol.header.symbol_id),
                            else => return invalid_argument(interpreter, som_parameter_idx, "String"),
                        },
                        SymbolId => switch (interpreter.pop_object().kind()) {
                            .symbol => |symbol| symbol.header.symbol_id,
                            .string => return invalid_argument(interpreter, som_parameter_idx, "Symbol, use `asSymbol` if the interning of the string is an okay cost to pay"),
                            else => return invalid_argument(interpreter, som_parameter_idx, "Symbol"),
                        },
                        *types.Block => switch (interpreter.pop_object().kind()) {
                            .block => |block| block,
                            else => return invalid_argument(interpreter, som_parameter_idx, "Block"),
                        },
                        VmObject => interpreter.pop_object(),
                        *Interpreter => interpreter,
                        else => |Invalid| @compileError(std.fmt.comptimePrint(
                            "Invalid argument type `{s}` in class `{s}` method `{s}` at index: {d}",
                            .{ @typeName(Invalid), class_name, fn_selector, inner_function_parameter_idx },
                        )),
                    };
                    arguments[inner_function_parameter_idx] = argument;
                    if (Parameter != *Interpreter) som_parameter_idx += 1;
                }

                // Assert that the number of arguments matches the selector
                comptime {
                    const som_parameters_count = som_parameter_idx;
                    const expected_arity = get_method_arity_from_selector(fn_selector);
                    if (som_parameters_count != expected_arity) {
                        @compileError(std.fmt.comptimePrint(
                            "Invalid number of arguments in class {s}. The arity of the selector `{s}` is {d}, but the function takes in {d} non-interpreter arguments.",
                            .{ class_name, fn_selector, expected_arity, som_parameters_count },
                        ));
                    }
                }

                // Call the function implementation
                const result: ReturnType = try @call(.auto, function, arguments);

                // Cast the result into a `VmObject`
                const heap = interpreter.heap_allocator;
                return switch (ReturnType) {
                    VmObject => result,
                    NilPlaceholder => VmObject.nil,
                    void => null,
                    i48 => try types.Integer.create_new(heap, result),
                    f64 => try types.Double.create_new(heap, result),
                    bool => interpreter.singletons.get_boolean_object(result),
                    SymbolId => try types.Symbol.create_new(heap, result),
                    else => |Invalid| @compileError(std.fmt.comptimePrint(
                        "Invalid return type `{s}` in class `{s}` method `{s}`",
                        .{ @typeName(Invalid), class_name, fn_selector },
                    )),
                };
            }
        }.primitive_method_implementation;
    }

    fn invalid_argument(interpreter: *Interpreter, parameter_idx: comptime_int, comptime expected: []const u8) Interpreter.Error {
        const actual_object: VmObject = interpreter.stack.objects.ptr[interpreter.stack.objects.len]; // We bypass the bounds check here
        const actual_class_name: SymbolId = interpreter.get_class_of(actual_object).class_name;
        interpreter.report_runtime_error("Argument at index {d} has invalid class: {s}. Expected an instance of " ++ expected, .{
            parameter_idx,
            interpreter.statics.symbols_manager.symbol_with_id(actual_class_name),
        });
        return Interpreter.Error.primitive_type_error;
    }

    fn could_not_cast_argument(
        interpreter: *Interpreter,
        parameter_idx: comptime_int,
        comptime actual_type: []const u8,
        actual_value: anytype,
        comptime target_type: []const u8,
    ) Interpreter.Error {
        interpreter.report_runtime_error(
            "Could not cast argument at index {d}, which is {s} with value {}. Target type is " ++ target_type,
            .{ parameter_idx, actual_type, actual_value },
        );
        return Interpreter.Error.primitive_type_error;
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

pub const PrimitiveMethodImplementation = *const fn (interpreter: *Interpreter) Interpreter.Error!?VmObject;
