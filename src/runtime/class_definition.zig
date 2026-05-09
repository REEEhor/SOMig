const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = interning_module.SymbolArrayMap;
//
const runtime_module = @import("__runtime.zig");
const Interpreter = runtime_module.Interpreter;
//
const vm_object_module = @import("vm_object.zig");
const VmObject = vm_object_module.VmObject;
const types = vm_object_module.types;
//
const codegen_module = @import("../frontend/codegen.zig");
const InstructionId = codegen_module.InstructionId;
const ConstantId = codegen_module.ConstantId;
const Bytecode = codegen_module.Bytecode;

/// Runtime definition of any class in SOM
pub const ClassDefinition = struct {
    class_name: SymbolId,
    instance_methods: MethodMap,
    as_vm_object: *types.Class,
    identifiers_of_instance_variables: []SymbolId,
    parent: ?*ClassDefinition,

    const Self = @This();
    pub const MethodMap = SymbolArrayMap(*const MethodDefinition, "selector");

    pub fn get_metaclass_through_vm_object(self: Self) *ClassDefinition {
        return self.as_vm_object.class_of_represented_class;
    }

    pub fn get_method(self: Self, method_name: SymbolId) ?*const MethodDefinition {
        return self.instance_methods.get(method_name);
    }
};

/// Runtime definition of any method in SOM
pub const MethodDefinition = struct {
    /// The method's selector as symbol.
    /// Some examples of selectors are: "value", "+++", "get:with:andWith:".
    selector: SymbolId,

    /// Number of arguments of this method **excluding** the first argument
    /// which is the message target object.
    ///
    /// For example, every unary method has this field set to 0 and every binary method to 1.
    /// Keyword method `get:with:AndWith:` (example method) has this field set to 3.
    ///
    /// This field is used for example for a stackframe creation.
    number_of_aditional_args: u16,

    /// Class in which the method was defined.
    source_class: *const ClassDefinition,

    /// Number describing the order in which the methods were defined in
    /// the source code. The first method in the class has this field set
    /// to 0, the second method to 1, third to 2 and so on.
    definition_order_index: u32,

    as_vm_object: *types.Method,

    body: MethodBody,
};

pub const MethodBody = union(enum) {
    primitive: PrimitiveMethodImplementation_,
    user_land: FunctionBody,
};

/// Same as `PrimitiveMethodImplementation` (without `_` at the end) which is defined elsewhere,
/// but made into a different type, because of circular dependency reasons.
/// (Having two aliases for these function pointers removes the circular depenedency errors, maybe in future versions of Zig, they will not be a problem.)
pub const PrimitiveMethodImplementation_ = *const fn (interpreter: *Interpreter) Interpreter.Error!?VmObject;

pub const FunctionBody = struct {
    bytecode: Bytecode,

    /// Number of local variables in the code of the function body.
    /// Used primarily for stackframe creation.
    number_of_locals: u16,
};
