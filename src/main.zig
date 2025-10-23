const std = @import("std");
const lexer_module = @import("frontend/lexer.zig");
const StringLiteralsManager = @import("frontend/string_literals_manager.zig").StringLiteralsManager;
const Lexer = lexer_module.Lexer;
const Parser = @import("frontend/parser.zig").Parser;

const defs = @import("custom_definitions/definitions.zig");
const int = defs.int;
const uint = defs.uint;

const dbg = std.debug.print;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 3 and std.mem.eql(u8, args[1], "-lex")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const gpa = arena.allocator();

        const filepath = args[2];
        var file = std.fs.cwd().openFile(filepath, .{ .mode = .read_only }) catch |err| {
            std.debug.print("Could not open the file '{s}'\n", .{filepath});
            return err;
        };
        defer file.close();
        const file_contents = file.readToEndAlloc(gpa, 100 * 4096) catch |err| {
            std.debug.print("Could not read the entire file due to size limits\n", .{});
            return err;
        };
        defer gpa.free(file_contents);

        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        var stdout = &stdout_writer.interface;
        try lexer_module.print_tokens(file_contents, gpa, stdout);
        defer stdout.flush() catch std.debug.print("Could not flush stdout\n", .{});
        return;
    }

    std.debug.print(
        "This will be an amazing SOMig project!\n\nUsage (so far):\n\t- `somig -lex <path/to/file.som>` | prints tokens and exits",
        .{},
    );
}

// Forcing for `zig build test` to run tests in all files that
// are recursively imported from here.
test {
    std.testing.refAllDeclsRecursive(@This());
}
