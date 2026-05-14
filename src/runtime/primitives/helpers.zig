const std = @import("std");
const assert = std.debug.assert;

const runtime_module = @import("../__runtime.zig");
const MethodDefinition = runtime_module.MethodDefinition;
const types = runtime_module.types;

/// Returns the number of arguments from a selector **INCLUDING SELF**.
/// WARNING: Does not check the validity of the selector.
/// For example:
/// ```Zig
///     assert(get_method_arity_from_selector("a") == 1);
///     assert(get_method_arity_from_selector("an_iDentifiEr97") == 1);
///     assert(get_method_arity_from_selector("+++") == 2);
///     assert(get_method_arity_from_selector("a:") == 2);
///     assert(get_method_arity_from_selector("a:b:") == 3);
///     assert(get_method_arity_from_selector("a:b:c:") == 4);
/// ```
pub fn get_method_arity_from_selector(selector: []const u8) u32 {
    const lexer_module = @import("../../frontend/lexer.zig");
    const is_binary_message_char = lexer_module.is_binary_message_char;

    assert(selector.len >= 1);
    if (is_binary_message_char(selector[0])) {
        // Binary selector
        return 2;
    }

    const last_char = selector[selector.len - 1];
    if (last_char == ':') {
        // Keyword selector
        const number_of_colons = std.mem.count(u8, selector, ":");
        return @intCast(number_of_colons + 1);
    }

    // Unary selector
    return 1;
}

/// Represents the `nil` value in SOM. Since we don't have a
/// representation for `nil` in `VmObject` (or rather.. it has no extra payload/information/state),
/// we use this zero-sized struct to indicate that a primitive method accepts or returns
/// a `nil`.
pub const NilPlaceholder = struct {};

pub const PrimitiveMethodWrapper = struct {
    method_definition: *const MethodDefinition,

    pub fn init(method: *const MethodDefinition) PrimitiveMethodWrapper {
        assert(method.body == .primitive);
        return .{ .method_definition = method };
    }
};

/// Represents an "Array class" instance.
pub const ArrayClassPlaceholder = struct {};

/// Represents an "Integer class" instance.
pub const IntegerClassPlaceholder = struct {};

/// Represents a "Double class" instance.
pub const DoubleClassPlaceholder = struct {};
