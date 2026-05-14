const runtime_module = @import("__runtime.zig");
const SymbolId = runtime_module.SymbolId;
const ClassDefinition = runtime_module.ClassDefinition;
const types = runtime_module.types;
const Interpreter = runtime_module.Interpreter;
const Bytecode = runtime_module.Bytecode;

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
pub const PrimitiveMethodImplementation_ = *const fn (interpreter: *Interpreter) Interpreter.Error!void;

pub const BlockDefinition = struct {
    body: FunctionBody,

    /// Number of arguments to the `body` of the block **excluding** the receiver object
    /// which is the block itself.
    number_of_aditional_args: u16,
};

pub const FunctionBody = struct {
    bytecode: Bytecode,

    /// Number of local variables in the code of the function body.
    /// Used primarily for stackframe creation.
    number_of_locals: u16,
};
