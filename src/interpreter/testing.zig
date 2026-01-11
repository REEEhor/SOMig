const std = @import("std");

fn run_test(input: []const u8, gpa: std.mem.Allocator, out: *std.io.Writer, err_out: *std.io.Writer) anyerror!void {
    _ = input; // autofix
    _ = gpa; // autofix
    _ = out; // autofix
    _ = err_out; // autofix
    unreachable;
}

test "snapshot test on example files" {
    const snapshot_testing = @import("../snapshot_testing.zig");
    // TODO: check if the path is not empty to ignore the test
    const opts = snapshot_testing.opts;
    try snapshot_testing.do_snapshot_tests(.{
        .snapshots_directory = opts.snapshots_path ++ "/interpreter",
        .tested_files_directory = opts.test_interpreter_files_path,
        .output_producer = run_test,
    }, "Interpreting");
}
