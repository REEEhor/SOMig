const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const terminal = @import("terminal.zig");

const debug_module = @import("debug/debug.zig");
const dbg = debug_module.dbg;

const parser_module = @import("frontend/parser.zig");
const Parser = parser_module.Parser;

const interning_module = @import("interning/__interning.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;

const codegen = @import("frontend/codegen.zig");

const runtime_module = @import("runtime/__runtime.zig");
const run = runtime_module.run;

const lexer_module = @import("frontend/lexer.zig");
const Lexer = lexer_module.Lexer;
const reporter_module = @import("frontend/reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;

pub fn main() !void {
    // Setup allocator
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 100 }) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args_with_program: [][:0]u8 = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args_with_program);
    const args = args_with_program[1..];

    var stdout_buffer = [_]u8{0} ** 1024;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var arguments_for_som = std.ArrayList([]const u8).empty;
    defer arguments_for_som.deinit(gpa);

    var root_directories = std.ArrayList(codegen.SourceCodeFiles.Directory).empty;
    defer root_directories.deinit(gpa);

    var skip_bootstrap = false;
    var use_colors = true;

    var object_stack_size: usize = 1000;
    var frame_stack_size: usize = 1000;

    // Parse command line arguments
    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--include") or std.mem.eql(u8, arg, "-cp")) {
            arg_idx += 1;
            if (arg_idx >= args.len) std.debug.panic("Expected argument", .{});
            var iter = std.mem.splitScalar(u8, args[arg_idx], ':');
            while (iter.next()) |path| {
                try root_directories.append(gpa, .{
                    .can_be_searched_recursively = false,
                    .path = path,
                });
            }
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            use_colors = false;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "-ir") or std.mem.eql(u8, arg, "-ri") or std.mem.eql(u8, arg, "--recursively-include")) {
            arg_idx += 1;
            if (arg_idx >= args.len) std.debug.panic("Expected argument", .{});
            var iter = std.mem.splitScalar(u8, args[arg_idx], ':');
            while (iter.next()) |path| {
                try root_directories.append(gpa, .{
                    .can_be_searched_recursively = true,
                    .path = path,
                });
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            arg_idx += 1;
            try arguments_for_som.appendSlice(gpa, args[arg_idx..]);
            break;
        } else if (std.mem.eql(u8, arg, "--no-bs")) {
            skip_bootstrap = true;
        } else if (std.mem.endsWith(u8, arg, ".som")) {
            arg_idx += 1;
            var components = std.fs.path.componentIterator(arg) catch |err| {
                std.debug.print("Problem while resolving the path '{s}': {t}.\n", .{err});
                return err;
            };
            const filename = components.last().?.name;
            const class_name = filename[0 .. filename.len - ".som".len];
            const containing_directory_path = arg[0 .. arg.len - filename.len];

            try root_directories.append(gpa, .{
                .can_be_searched_recursively = false,
                .path = containing_directory_path,
            });
            try arguments_for_som.append(gpa, class_name);
            try arguments_for_som.appendSlice(gpa, args[arg_idx..]);

            break;
        } else if (std.mem.eql(u8, arg, "--object-stack")) {
            arg_idx += 1;
            if (arg_idx == args.len) {
                std.debug.print("Expected an integer after '--object-stack'.\n", .{});
                return error.invalid_args;
            }
            object_stack_size = std.fmt.parseInt(usize, args[arg_idx], 10) catch |err| {
                std.debug.print("Could not parse an integer from '{s}', because: {t}.\n", .{ args[arg_idx], err });
                return error.invalid_args;
            };
        } else if (std.mem.eql(u8, arg, "--frame-stack")) {
            arg_idx += 1;
            if (arg_idx == args.len) {
                std.debug.print("Expected an integer after '--frame-stack'.\n", .{});
                return error.invalid_args;
            }
            frame_stack_size = std.fmt.parseInt(usize, args[arg_idx], 10) catch |err| {
                std.debug.print("Could not parse an integer from '{s}', because: {t}.\n", .{ args[arg_idx], err });
                return error.invalid_args;
            };
        } else {
            std.debug.panic("Invalid flag '{s}'", .{arg});
        }
    }

    const exit_code = run(.{
        .gpa = gpa,
        .stdout = stdout,
        .stderr = stderr,
        .stack_size = .{
            .objects_count = object_stack_size,
            .frames_count = frame_stack_size,
        },
        .program_arguments_as_strings = arguments_for_som.items,
        .root_directories = root_directories.items,
        .skip_bootstrap = runtime_module.DEBUG_SKIP_BOOTSTRAP or skip_bootstrap,
        .use_colored_printing = use_colors,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => std.process.exit(1),
    };
    std.process.exit(exit_code);
}

// Forcing for `zig build test` to run tests in all files that
// are recursively imported from here.
test {
    std.testing.refAllDeclsRecursive(@This());
}
