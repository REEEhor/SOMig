const runtime_module = @import("__runtime.zig");
const SymbolId = runtime_module.SymbolId;
const SymbolArrayMap = runtime_module.SymbolArrayMap;
const types = runtime_module.types;
const MethodDefinition = runtime_module.MethodDefinition;

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
