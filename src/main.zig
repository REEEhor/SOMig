const std = @import("std");
const lexer_module = @import("frontend/lexer.zig");
const Lexer = lexer_module.Lexer;

const defs = @import("custom_definitions/definitions.zig");
const int = defs.int;
const uint = defs.uint;

const dbg = std.debug.print;

pub fn main() !void {
    var lexer = Lexer.create("", .{}, undefined);
    _ = try lexer.next_token();
    std.debug.print("This will be an amazing {s} project.\n\n", .{"SOMig"});
}
