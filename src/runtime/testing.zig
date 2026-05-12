const std = @import("std");
const runtime_module = @import("__runtime.zig");
const run_function = runtime_module.run;
const options = @import("integration_tests_options");
const colors = @import("../terminal.zig");

test "run integration tests" {
    std.debug.print(colors.BOLD ++ "\nIntegration tests" ++ colors.RESET ++ " from: {s}\n", .{options.integration_tests_path});
    if (!options.run_integration_tests) {
        warn_about_not_running_the_integration_tests();
        return;
    }
    try run_tests(std.testing.allocator);
}

pub fn run_tests(gpa: std.mem.Allocator) !void {
    var static = std.heap.ArenaAllocator.init(gpa);
    defer static.deinit();

    var root_dir = try std.fs.cwd().openDir(options.integration_tests_path, .{ .iterate = true });
    defer root_dir.close();

    const known_failing_tests = try get_known_failing_tests(static.allocator(), &root_dir);

    var error_configs = try std.ArrayList([]const u8).initCapacity(gpa, 100);
    defer error_configs.deinit(gpa);

    var total_tests: usize = 0;
    var known_failures_cnt: usize = 0;
    var ok_tests: usize = 0;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var it = root_dir.iterate();
    while (try it.next()) |entry| {
        _ = arena.reset(.retain_capacity);

        var dirs = std.ArrayList(runtime_module.SourceCodeFiles.Directory).empty;

        const tested_file: TestFile = get_file: {
            switch (entry.kind) {
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".som")) {
                        continue;
                    }
                    const contents = try root_dir.readFileAlloc(arena.allocator(), entry.name, 1024 * 1024);
                    break :get_file TestFile{
                        .contents = contents,
                        .filepath = try root_dir.realpathAlloc(arena.allocator(), entry.name),
                        .class_name = entry.name[0 .. entry.name.len - ".som".len],
                    };
                },
                .directory => {
                    try dirs.append(arena.allocator(), .{
                        .can_be_searched_recursively = false,
                        .path = try root_dir.realpathAlloc(arena.allocator(), entry.name),
                    });

                    const subpath = try std.fmt.allocPrint(arena.allocator(), "{s}/test.som", .{entry.name});
                    const path = try root_dir.realpathAlloc(arena.allocator(), subpath);
                    const contents = try root_dir.readFileAlloc(arena.allocator(), path, 1024 * 1024);
                    break :get_file TestFile{
                        .contents = contents,
                        .class_name = "test",
                        .filepath = path,
                    };
                },
                else => continue,
            }
        };

        const config = parse_config(arena.allocator(), tested_file.contents) catch {
            std.debug.print("Error with entry '{s}/{s}'\n", .{ options.integration_tests_path, entry.name });
            std.debug.print("\n", .{});
            try error_configs.append(gpa, try static.allocator().dupe(u8, entry.name));
            continue;
        };

        var allocating_stdout = std.Io.Writer.Allocating.init(arena.allocator());
        const stdout = &allocating_stdout.writer;

        var allocating_stderr = std.Io.Writer.Allocating.init(arena.allocator());
        const stderr = &allocating_stderr.writer;

        if (config.include_awfy) {
            try dirs.append(arena.allocator(), .{
                .path = options.core_awfy_path,
                .alert_on_duplicates = true,
                .can_be_searched_recursively = false,
            });
        }
        try dirs.append(arena.allocator(), .{
            .path = options.integration_tests_path,
            .alert_on_duplicates = true,
            .can_be_searched_recursively = false,
        });
        try dirs.append(arena.allocator(), .{
            .path = options.core_lib_path,
            .alert_on_duplicates = !config.include_awfy,
            .can_be_searched_recursively = false,
        });

        const program_args = get_args: {
            var program_args = std.ArrayList([]const u8).empty;
            try program_args.append(arena.allocator(), tested_file.class_name);
            break :get_args program_args;
        };

        var maybe_err: ?anyerror = null;
        const program_exit_value: ?u8 = run_function(.{
            .gpa = gpa,
            .stdout = stdout,
            .stderr = stderr,
            .stack_size = .{ .frames_count = 200, .objects_count = 1000 },
            .root_directories = dirs.items,
            .program_arguments_as_strings = program_args.items,
            .print_stack_on_error = false,
            .skip_bootstrap = false,
            .use_colored_printing = false,
        }) catch |err| blk: {
            maybe_err = err;
            break :blk null;
        };

        var allocating_issues_writer = std.Io.Writer.Allocating.init(arena.allocator());
        const w = &allocating_issues_writer.writer;

        if (config.status) |status| switch (status) {
            .@"error" => if (maybe_err == null and program_exit_value == 0) {
                try w.print("Mismatch: expected 'error' status, but there was no error.\n", .{});
            },
            .success => if (maybe_err) |err| {
                try w.print("Mismatch: expected 'success' status, but there was error: {t}.\n", .{err});
            },
            .integer_value => |expected_value| if (program_exit_value) |actual_value| {
                if (expected_value != actual_value) {
                    try w.print("Mismatch: expected status to be {d}, but it is {d}.\n", .{ expected_value, actual_value });
                }
            } else {
                try w.print("Mismatch: expected status to be {d}, but the program did not exit with such code.\n", .{expected_value});
            },
        };
        if (config.has_stderr and allocating_stderr.written().len == 0) {
            try w.print("Mismatch: expected the stderr to contain something, but it was empty.\n", .{});
        }
        if (config.expected_stdout) |expected_stdout| {
            if (!str_eql(expected_stdout, allocating_stdout.written())) {
                try w.print("Mismatch: stdout is different than expected.\n", .{});
            }
        }
        if (config.expected_stderr_contains) |expected_stderr| {
            if (null == std.mem.indexOf(u8, allocating_stderr.written(), expected_stderr)) {
                try w.print("Mismatch: stderr does not contain the specified string.\n", .{});
            }
        }

        const expected_to_fail: bool = known_failing_tests.contains(entry.name);
        const actually_failed: bool = allocating_issues_writer.written().len != 0;

        if (actually_failed and expected_to_fail) {
            known_failures_cnt += 1;
        }
        total_tests += 1;

        if (expected_to_fail != actually_failed) {
            if (!actually_failed) {
                try w.print("Expected to fail this test (it is in known failures), but the test actually passed.\n", .{});
            }
            const issues: []const u8 = allocating_issues_writer.written();
            std.debug.print(colors.ERR ++ "================== {s} ===============\n" ++ colors.RESET, .{tested_file.filepath});
            std.debug.print("{s}", .{issues});
            std.debug.print("========= Config: \n", .{});
            std.debug.print("Status:       {?}\n", .{config.status});
            std.debug.print("Include AWFY: {}\n", .{config.include_awfy});
            std.debug.print("Has stderr:   {}\n", .{config.has_stderr});
            if (config.expected_stderr_contains) |exact_expected_stderr| {
                std.debug.print("Expected stderr to contain:\n{s}", .{exact_expected_stderr});
            } else {
                std.debug.print("Expected stderr to contain: (unspecified)\n", .{});
            }
            if (config.expected_stdout) |expected_stdout| {
                std.debug.print("Expected stdout:\n{s}", .{expected_stdout});
            } else {
                std.debug.print("Expected stdout: (unspecified)\n", .{});
            }
            std.debug.print("========= Program stdout:\n", .{});
            std.debug.print("{s}", .{allocating_stdout.written()});
            std.debug.print("========= Program stderr:\n", .{});
            std.debug.print("{s}", .{allocating_stderr.written()});
        } else {
            ok_tests += 1;
        }
    }

    if (total_tests == ok_tests) {
        std.debug.print(
            colors.GREEN ++ "All " ++ colors.BOLD ++ "{d}" ++ colors.RESET ++ colors.GREEN ++ " tests passed!" ++ colors.RESET ++ colors.GREEN ++ colors.FAINT ++ "{s}" ++ colors.RESET ++ "\n",
            .{
                total_tests,
                if (known_failures_cnt != 0) " (counting known failing tests as passing)" else "",
            },
        );
    } else {
        std.debug.print(colors.BOLD ++ "===================== RESULTS: ===================== \n" ++ colors.RESET, .{});
        std.debug.print(colors.GREEN ++ "All tests:     {d}\n" ++ colors.RESET, .{total_tests});
        std.debug.print(colors.GREEN ++ "Passing tests: " ++ colors.BOLD ++ "{d}" ++ colors.RESET ++ colors.GREEN ++ colors.FAINT ++ " {s}\n" ++ colors.RESET, .{
            ok_tests,
            if (known_failures_cnt != 0) " (counting known failing tests as passing)" else "",
        });
        std.debug.print(colors.RED ++ "Failing tests: " ++ colors.BOLD ++ "{d}\n" ++ colors.RESET, .{total_tests - ok_tests});
    }

    if (known_failures_cnt != 0) {
        std.debug.print(colors.CYAN ++ "Known failing tests: " ++ colors.BOLD ++ "{d}" ++ colors.RESET ++ colors.CYAN ++ colors.FAINT ++ "\n" ++ colors.RESET, .{known_failures_cnt});
    }
}

fn warn_about_not_running_the_integration_tests() void {
    std.debug.print( //
        colors.WARN ++ "  [WARN] THESE WERE NOT RUN!\n" ++ colors.RESET ++ //
            "  Hint: Use a " ++ colors.WARN ++ "-Dit=true" ++ colors.RESET ++ //
            " (or a " ++ colors.YELLOW ++ "-Drun-integration-tests=true" ++ colors.RESET ++ ")" ++ colors.RESET ++ //
            " flag to run the integration tests.\n",
        .{},
    );
    std.debug.print("  Note: This is becuse these test take around 10 seconds to run.\n", .{});
}

pub const TestFile = struct {
    contents: []const u8,
    filepath: []const u8,
    class_name: []const u8,
};

pub const Status = union(enum) { @"error", success, integer_value: i64 };

pub const TestConfig = struct {
    status: ?Status = null,
    has_stderr: bool = false,
    expected_stderr_contains: ?[]const u8 = null,
    expected_stdout: ?[]const u8 = null,
    include_awfy: bool = false,
};

fn get_known_failing_tests(gpa: std.mem.Allocator, dir: *std.fs.Dir) !std.StringArrayHashMap(void) {
    const contents = dir.readFileAlloc(gpa, "__known_failures.txt", 1024 * 1024 * 1024) catch |err| {
        std.debug.print("Could not open file '__known_failures.txt' which contains the which tests skip, because: {t}\n", .{err});
        return err;
    };

    var result = std.StringArrayHashMap(void).init(gpa);

    var line_it = split_to_trimmed_lines(contents);
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) continue;
        try result.put(try gpa.dupe(u8, line), {});
    }

    return result;
}

fn parse_config(gpa: std.mem.Allocator, file_contents: []const u8) !TestConfig {
    const e = error.invalid;
    const input = get_input: {
        var it = std.mem.splitScalar(u8, file_contents, '"');
        _ = it.next().?;
        break :get_input it.next().?;
    };

    var result = TestConfig{};

    var line_it = split_to_trimmed_lines(input);
    {
        var vm_line = line_it.next().?;
        if (vm_line.len == 0) vm_line = line_it.next().?;
        if (!str_eql(vm_line, "VM:")) {
            std.debug.print("First comment line should be 'VM:', but is '{s}'.\n", .{vm_line});
            return e;
        }
    }

    while (true) {
        const first_line = line_it.next() orelse break;
        if (first_line.len == 0) continue;
        var token_it = std.mem.splitSequence(u8, first_line, ":");
        const kind = std.mem.trim(u8, token_it.next().?, " \t");
        if (str_eql(kind, "status")) {
            if (result.status != null) {
                std.debug.print("Field 'status' defined multiple times!\n", .{});
                return e;
            }

            const status_str = std.mem.trim(u8, token_it.next().?, " \t");
            if (std.meta.stringToEnum(std.meta.Tag(Status), status_str)) |st| {
                switch (st) {
                    .integer_value => {
                        std.debug.print("Invalid status: '{s}'\n", .{status_str});
                        return e;
                    },
                    inline else => |t| result.status = t,
                }
            } else if (std.fmt.parseInt(i64, status_str, 10) catch null) |int_status| {
                result.status = .{ .integer_value = int_status };
            } else {
                std.debug.print("Invalid status '{s}'\n", .{status_str});
                return e;
            }
        } else if (str_eql(kind, "stderr")) {
            result.has_stderr = true;
            // Now we have to skip reamining lines
            const kind_prefix = prefix_len(line_it.raw_line);
            while (true) {
                const stderr_line = line_it.inner_iter.peek() orelse break;
                const inner_prefix = prefix_len(stderr_line);
                if (inner_prefix <= kind_prefix and std.mem.trim(u8, stderr_line, " \t").len != 0) break;
                _ = line_it.next();
            }
        } else if (str_eql(kind, "stdout")) {
            if (result.expected_stdout != null) {
                std.debug.print("The 'stdout:' is defined multiple times!\n", .{});
                return e;
            }
            result.expected_stdout = try parse_expected_outputs_content(gpa, &line_it);
        } else if (str_eql(kind, "stderr-contains")) {
            if (result.expected_stderr_contains != null) {
                std.debug.print("The 'stderr-contains:' is defined multiple times!\n", .{});
                return e;
            }
            result.expected_stderr_contains = try parse_expected_outputs_content(gpa, &line_it);
        } else if (str_eql(kind, "include_awfy")) {
            result.include_awfy = true;
        } else {
            std.debug.print("Unhandeled kind: '{s}'\n", .{kind});
            return e;
        }
    }
    return result;
}

fn parse_expected_outputs_content(
    gpa: std.mem.Allocator,
    line_it: *LineIterator,
) ![]const u8 {
    var allocating_writer = std.Io.Writer.Allocating.init(gpa);
    var w = &allocating_writer.writer;
    const kind_prefix_len = prefix_len(line_it.raw_line);
    while (true) {
        const raw_stdout_line = line_it.inner_iter.peek() orelse break;
        const inner_prefix = prefix_len(raw_stdout_line);
        if (inner_prefix <= kind_prefix_len) break;
        const stdout_line = line_it.next().?; // we peeked - it should be there
        if (!std.mem.startsWith(u8, stdout_line, "|")) break;
        try w.print("{s}\n", .{stdout_line[1..]});
    }
    return allocating_writer.written();
}

fn str_eql(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}

fn prefix_len(str: []const u8) usize {
    var idx: usize = 0;
    while (idx < str.len) : (idx += 1) {
        const chr = str[idx];
        if (chr != ' ' and chr != '\t') break;
    }
    return idx;
}

fn assert(ok: bool) void {
    if (!ok) @panic("Assertion failed");
}

pub const LineIterator = struct {
    inner_iter: std.mem.SplitIterator(u8, .scalar),
    raw_line: []const u8 = &.{},
    line_number: usize = 0,

    pub fn next(self: *Self) ?[]const u8 {
        const raw_line = self.inner_iter.next() orelse return null;
        self.line_number += 1;
        self.raw_line = raw_line;
        return std.mem.trim(u8, raw_line, " \r\n\t");
    }

    const Self = @This();
};

pub fn split_to_trimmed_lines(string: []const u8) LineIterator {
    return .{
        .inner_iter = std.mem.splitScalar(u8, string, '\n'),
    };
}
