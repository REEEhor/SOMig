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

    if (args.len > 0 and std.mem.eql(u8, args[0], "--parse")) {
        if (args.len != 2) {
            std.debug.print("ERROR: Expected a single filepath argument after `--parse`.\n", .{});
            return;
        }
        const filepath = args[1];
        return parse(gpa, filepath);
    }

    if (args.len == 1 and std.mem.eql(u8, args[0], "--itest")) {
        if (false) { // HACK: Used to silent the LSP
            return runtime_module.testing_module.run_tests(gpa);
        } else {
            const src = @src();
            std.debug.print("ERROR: at '{s}:{d}' change the `false` to `true`. \n", .{ src.file, src.line - 3 });
            return;
        }
    }

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
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "-ir") or std.mem.eql(u8, arg, "-ri") or std.mem.eql(u8, arg, "--recursively-include")) {
            arg_idx += 1;
            if (arg_idx >= args.len) std.debug.panic("Expected argument", .{});
            try root_directories.append(gpa, .{
                .can_be_searched_recursively = true,
                .path = args[arg_idx],
            });
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
        } else {
            std.debug.panic("Invalid flag '{s}'", .{arg});
        }
    }

    const exit_code = run(.{
        .gpa = gpa,
        .stdout = stdout,
        .stderr = stderr,
        .stack_size = .{
            .objects_count = 1000, // TODO: these should be parsed from args
            .frames_count = 1000, // TODO: these should be parsed from args
        },
        .program_arguments_as_strings = arguments_for_som.items,
        .root_directories = root_directories.items,
        .skip_bootstrap = runtime_module.DEBUG_SKIP_BOOTSTRAP or skip_bootstrap,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => std.process.exit(1),
    };
    std.process.exit(exit_code);
}

fn parse(allocator: std.mem.Allocator, filepath: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

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
    defer stdout.flush() catch |err| std.debug.print("Could not flush stdout: {t}\n", .{err});

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    var stderr = &stderr_writer.interface;
    defer stderr.flush() catch |err| std.debug.print("Could not flush stderr: {t}\n", .{err});

    try parser_module.print_class_ast(file_contents, gpa, stdout, stderr);
}

fn lex(allocator: std.mem.Allocator, args: [][:0]u8) !void {
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
    defer stdout.flush() catch |err| std.debug.print("Could not flush stdout: {t}\n", .{err});

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    var stderr = &stderr_writer.interface;
    defer stderr.flush() catch |err| std.debug.print("Could not flush stderr: {t}\n", .{err});

    // TODO: cleanup: make the `print_tokens` function somehow report an error, so that we can return it from this `main` function.
    try lexer_module.print_tokens(file_contents, gpa, stdout, stderr);
    return;
}

// Forcing for `zig build test` to run tests in all files that
// are recursively imported from here.
test {
    _ = @import("frontend/parser.zig");
    // _ = @import("frontend/codegen.zig");
    // _ = @import("interning/symbol_array_map.zig");
    std.testing.refAllDeclsRecursive(@This());
}
