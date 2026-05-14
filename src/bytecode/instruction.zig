const std = @import("std");

const runtime_module = @import("../runtime/__runtime.zig");
const SymbolId = runtime_module.SymbolId;
const SmallPtr = runtime_module.SmallPtr;
const MethodDefinition = runtime_module.MethodDefinition;
const StringLiteralId = runtime_module.StringLiteralId;
const BlockDefinitionId = runtime_module.BlockDefinitionId;

pub const Instruction = union(enum(u8)) {
    load_integer_i8: i8,
    load_integer_i48: i48,
    load_double: f64,
    load_string: StringLiteralId,
    load_block: BlockDefinitionId,
    load_nil,

    send_message: SendMessage,

    /// Pushes either a local variable or a method argument onto the stack.
    load_local: LoadLocal,

    /// Pushes an instance variable of the current `self` object onto the stack.
    load_instance_var: LoadInstanceVar,

    load_global: SymbolId,

    /// Gets the top value from the stack (doesn't pop) and assigns its value to a global variable.
    set_global: SymbolId,

    normal_return,

    non_local_return,

    /// Gets the top value from the stack (doesn't pop) and assigns its value into a local variable
    set_local: SetLocal,

    /// Gets the top value from the stack (doesn't pop) and assigns its value into an instance variable
    set_instance_var: SetInstanceVar,

    pop,

    pop_into_new_array: PopIntoNewArray,

    load_symbol: SymbolId,

    resolved_method_call: packed struct { method_ptr: SmallPtr(*const MethodDefinition) },

    invalid_super_send: packed struct { selector: SymbolId },

    pub const LoadInstanceVar = packed struct {
        instance_var_id: InstanceVarId,
    };

    pub const SetInstanceVar = packed struct {
        instance_var_id: InstanceVarId,
    };

    pub const LoadLocal = packed struct {
        local_id: LocalVarId,
        required_frame_up_steps: u32,
    };

    pub const SetLocal = packed struct {
        local_id: LocalVarId,
        required_frame_up_steps: u32,
    };

    pub const PopIntoNewArray = packed struct {
        pub const IntRepr = u24;
        number_of_items: IntRepr,
    };

    /// Represents the place relative to the base pointer in the
    /// object stack during interpreter runtime, where a variable is stored.
    ///
    /// The variable can be either a local variable or an argument to a method.
    ///
    /// For example if the object stack was this:
    ///
    ///     object stack:
    ///                   ... (maybe objects of previous frames)
    ///     base_ptr ---> method_argument[3]
    ///                   method_argument[2]
    ///                   method_argument[1]
    ///                   method_argument[0]   (<- this object is `self`)
    ///                   local_variable[0]
    ///                   local_variable[1]
    ///                   local_variable[2]
    ///                   ... (maybe arguments of the next method)
    ///
    /// To access the `method_argument[3]`, you would need `LocalId{.idx = 0}`.
    /// To access the `local_variable[1]`, you would need `LocalId{.idx = 5}` (4 = <number-of-arguments> + <index-of-local>)
    pub const LocalVarId = packed struct {
        idx: u32,
    };

    pub const InstanceVarId = packed struct { idx: u32 };

    pub const SendMessage = packed struct {
        message_name: SymbolId,
    };

    const Self = @This();
    pub const Tag = std.meta.Tag(Instruction);
    pub fn tag(self: Self) Tag {
        return std.meta.activeTag(self);
    }

    /// Whether the modifies the runtime stack in a way that pushes a single value onto it.
    pub fn is_load_instruction(self: Self) bool {
        return switch (self) {
            .no_op => false,
            .load_symbol => true,
            .pop_into_new_array => false,
            .load_constant => true,
            .send_message => false,
            .resolved_method_call => false,
            .duplicate => true,
            .halt => false,
            .set_instance_var => false,
            .load_local => true,
            .load_instance_var => true,
            .load_global => true,
            .normal_return => false,
            .set_local => false,
            .print => false,
            .pop => false,
        };
    }
};
