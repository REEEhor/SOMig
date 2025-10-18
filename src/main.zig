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

    const Example = union(enum) { lol, bruh: []const u8, xd: int };
    const ex1: Example = .lol;
    const ex2: Example = .{ .bruh = "Toto je bruh" };
    const ex3: Example = .{ .xd = 42 };
    const exs: [3]Example = .{ ex1, ex2, ex3 };
    for (exs) |e| {
        // std.enums.values(comptime E: type)

        switch (e) {
            inline else => |payload, tag| {
                // Check if the payload type is void
                if (@typeInfo(@TypeOf(payload)) == .void) {
                    std.debug.print("{s}\n", .{@tagName(tag)});
                } else {
                    std.debug.print("{s}: {any}\n", .{ @tagName(tag), payload });
                }
            },
        }
        std.debug.print("\n", .{});
    }
}
test {
    std.testing.refAllDeclsRecursive(@This());
}
