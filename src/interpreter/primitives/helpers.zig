const std = @import("std");
const assert = std.debug.assert;

pub const primitive_fn_postfix = "__somig_primitive_fn";

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
        return number_of_colons + 1;
    }

    // Unary selector
    return 1;
}

pub fn assert_arity_is(comptime source_location: std.builtin.SourceLocation, comptime expected_arity: u32) void {
    comptime {
        if (!std.mem.endsWith(u8, source_location.fn_name, primitive_fn_postfix)) {
            @compileError(std.fmt.comptimePrint(
                "The function `{s}` does not end with `{s}`.",
                .{ source_location.fn_name, primitive_fn_postfix },
            ));
        }
        const end_index_of_selector = source_location.fn_name.len - primitive_fn_postfix.len;
        const selector = source_location.fn_name[0..end_index_of_selector];
        const actual_arity = get_method_arity_from_selector(selector);

        if (actual_arity != expected_arity) {
            @compileError(std.fmt.comptimePrint(
                "Failed arity check! The selector `{s}` has the arity {d}, but {d} was expected.",
                .{ selector, actual_arity, expected_arity },
            ));
        }
    }
}

/// Represents the `nil` value in SOM. Since we don't have a
/// representation for `nil` in `VmObject` (or rather.. it has no extra payload/information/state),
/// we use this zero-sized struct to indicate that a primitive method accepts or returns
/// a `nil`.
pub const NilPlaceholder = struct {};

/// Represents the `system` value in SOM. Since the representation of `system` in `VmObject`
/// does not cary any infromation, we use this zero-sized struct to indicate
/// that a primitive method accepts or returns an instance of the `System` class.
pub const SystemPlaceholder = struct {};
