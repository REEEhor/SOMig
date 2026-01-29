const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = interning_module.SymbolArrayMap;
//
const interpreter_module = @import("__interpreter.zig");
const Interpreter = interpreter_module.Interpreter;
//
const vm_object_module = @import("vm_object.zig");
const VmObject = vm_object_module.VmObject;
//
const codegen_module = @import("../frontend/codegen.zig");
const InstructionId = codegen_module.InstructionId;
const ConstantId = codegen_module.ConstantId;
const Bytecode = codegen_module.Bytecode;

/// Runtime definition of any class in SOM
pub const ClassDefinition = struct {
    class_name: SymbolId,
    instance_methods: MethodMap,
    as_vm_object: VmObject,
    identifiers_of_instance_variables: []SymbolId,
    parent: ?*ClassDefinition,

    const Self = @This();
    pub const MethodMap = SymbolArrayMap(MethodDefinition, "method_name");

    pub fn get_metaclass_through_vm_object(self: Self) Interpreter.Error!*ClassDefinition {
        return switch (self.as_vm_object.data.kind()) {
            .class => |accessor| accessor.get_class_of_represented_class(self.as_vm_object.data),
            else => Interpreter.Error.primitive_type_error,
        };
    }

    pub fn fields_count_including_parents(self: Self) usize {
        // TODO: - Check this
        // TODO: - This doesn't probably work, we have to loop over all parent in the hiearchy and sum their instance variables coujnt
        // TODO: - It might be better to store the number of instance variables of the parent (maybe we are doing this here???)
        var result: usize = self.identifiers_of_instance_variables.len;
        if (self.parent) |parent| {
            result += parent.identifiers_of_instance_variables.len;
        }
        return result;
    }

    pub fn get_method(self: Self, method_name: SymbolId) ?*const MethodDefinition {
        const idx = self.instance_methods.get_idx(method_name) orelse return null;
        return &self.instance_methods.items[idx];
    }
};

/// Runtime definition of any method in SOM
pub const MethodDefinition = struct {
    /// The method selector.
    /// Some examples of selectors are strings: "value", "+++", "get:with:andWith:".
    method_name: SymbolId,

    /// Number of arguments of this method **excluding** the first argument
    /// which is the message target object.
    ///
    /// For example, every unary method has this field set to 0 and every binary method to 1.
    /// Keyword method `get:with:AndWith:` (example method) has this field set to 3.
    ///
    /// This field is used for example for a stackframe creation.
    number_of_aditional_args: u16,

    body: MethodBody,
};

pub const MethodBody = union(enum) {
    primitive: PrimitiveMethodImplementation_,
    user_land: FunctionBody,
};

/// Same as `PrimitiveMethodImplementation` (without `_` at the end) which is defined elsewhere,
/// but made into a different type, because of circular dependency reasons.
/// (Having two aliases for these function pointers removes the circular depenedency errors, maybe in future versions of Zig, they will not be a problem.)
pub const PrimitiveMethodImplementation_ = *const fn (target_object: VmObject, interpreter: *Interpreter) Interpreter.Error!?VmObject;

pub const FunctionBody = struct {
    bytecode: Bytecode,

    /// Number of local variables in the code of the function body.
    /// Used primarily for stackframe creation.
    number_of_locals: u16,
    constants_base_id: ConstantId,
};
