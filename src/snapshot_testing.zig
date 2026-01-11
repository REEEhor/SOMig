const std = @import("std");
pub const opts = @import("snapshot_test_options");
const print = std.debug.print;
const fs = std.fs;
const Dir = fs.Dir;
const File = fs.File;

const colors = @import("terminal.zig");
const RED = colors.RED;
const GREEN = colors.GREEN;
const YELLOW = colors.YELLOW;
const BOLD = colors.BOLD;
const RED_BG = colors.RED_BG;
const FAINT = colors.FAINT;
const ERR = colors.ERR;
const WARN = colors.WARN;
const RESET = colors.RESET;

/// Both `out` and `err_out` will get flushed after the function returns.
/// The callee does not have to flush them.
///
/// If there is a problem with the `input` itself, it should not get returned but the error should be written
/// to `err_out`. Probably in a similiar way to:
/// ```zig
///     err_out.print("Got error: {t}\n", .{some_error});
/// ```
/// Other errors should be reported via the return value (out of memory, could not initialize some support object, ...)
pub const OutputProducer = fn (input: []const u8, std.mem.Allocator, out: *std.io.Writer, err_out: *std.io.Writer) anyerror!void;

pub const TestOptions = struct {
    /// Absolute path to the directory containing snapshots.
    snapshots_directory: []const u8,

    /// Absolute path to the SOM code that is used for tests.
    tested_files_directory: []const u8,

    /// Function to be called on SOM source code.
    output_producer: OutputProducer,
};

pub fn do_snapshot_tests(options: TestOptions, comptime verb: []const u8) !void {
    const gpa = std.testing.allocator;
    const read_limit = 100_000;

    var som_source_dir: Dir = try std.fs.openDirAbsolute(
        options.tested_files_directory,
        .{ .iterate = true },
    );
    defer som_source_dir.close();

    std.fs.makeDirAbsolute(options.snapshots_directory) catch {};
    var snapshots_dir: Dir = std.fs.openDirAbsolute(options.snapshots_directory, .{}) catch |err| {
        print("Could not open directory {s}, because: {t}\n", .{ options.snapshots_directory, err });
        return err;
    };
    defer snapshots_dir.close();

    var total_tests_count: i32 = 0;
    var failed_tests_count: i32 = 0;
    var tests_without_snapshots_count: i32 = 0;
    var error_tests_count: i32 = 0;
    var ok_tests_count: i32 = 0;
    var updated_snapshots_count: i32 = 0;
    var different_to_snapshot_count: i32 = 0;

    print("\n" ++ verb ++ " the code in: {s}\n", .{options.tested_files_directory});
    var som_source_dir_it = som_source_dir.iterate();
    next_test: while (try som_source_dir_it.next()) |entry| {
        defer print("\n", .{});

        // Check if the entry is a SOM source code file
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".som")) continue;
        total_tests_count += 1;

        // Read in the file
        const source_code: []const u8 = blk: {
            var som_source_file = som_source_dir.openFile(entry.name, .{}) catch |err| {
                error_tests_count += 1;
                print(ERR ++ "Could not open file {s}, because: {s}" ++ RESET, .{ entry.name, @errorName(err) });
                continue :next_test;
            };
            defer som_source_file.close();
            break :blk try som_source_file.readToEndAlloc(gpa, read_limit);
        };
        defer gpa.free(source_code);

        // Generate the test name
        const current_test_name: []const u8 = blk: {
            // TODO: add the current directory
            break :blk std.mem.sliceTo(entry.name, '.');
        };
        // TODO: uncomment this:
        // defer gpa.free(current_test_name);

        // Run the test
        const program_output: []const u8 = running_the_tested_function: {
            var writer = std.io.Writer.Allocating.init(gpa);
            defer writer.deinit();
            var err_writer = std.io.Writer.Allocating.init(gpa);
            defer err_writer.deinit();
            //
            print(" - Test " ++ BOLD ++ "{s}" ++ RESET, .{current_test_name});
            { // Print the dots after the test name
                var buffer: [64]u8 = undefined;
                const bw = std.debug.lockStderrWriter(&buffer);
                defer std.debug.unlockStderrWriter();
                for (current_test_name.len..@max(current_test_name.len, 40)) |_| {
                    try bw.writeByte('.');
                }
                try bw.flush();
            }
            options.output_producer(source_code, gpa, &writer.writer, &err_writer.writer) catch |err| {
                failed_tests_count += 1;
                print(ERR ++ "Error occured: {t}\n" ++ RESET, .{err});
                continue;
            };
            try err_writer.writer.flush();
            const err_output: []u8 = try err_writer.toOwnedSlice();
            defer gpa.free(err_output);
            if (err_output.len != 0) {
                _ = try writer.writer.print("\n======== ERROR OUTPUT FROM THE PROGRAM ========\n", .{});
                _ = try writer.writer.write(err_output);
            }
            try writer.writer.flush();

            print(GREEN ++ "DONE! " ++ RESET, .{});
            if (err_output.len == 0) {
                print("(output:  ok) ", .{});
            } else {
                print("(output: err) ", .{});
            }
            print("| ", .{});

            break :running_the_tested_function try writer.toOwnedSlice();
        };
        defer gpa.free(program_output);

        // Check that the snapshot exists
        const snapshot_contents: []const u8 = get_snapshot_contents: {
            const snapshot_filename = try std.mem.concat(gpa, u8, &[_][]const u8{ current_test_name, ".snapshot.txt" });
            defer gpa.free(snapshot_filename);

            if (snapshots_dir.openFile(snapshot_filename, .{})) |snapshot_file| {
                break :get_snapshot_contents try snapshot_file.readToEndAlloc(gpa, read_limit);
            } else |file_open_err| if (file_open_err == error.FileNotFound) {
                if (opts.accept_all) {
                    snapshots_dir.writeFile(.{ .data = program_output, .sub_path = snapshot_filename }) catch |file_write_err| {
                        error_tests_count += 1;
                        print(ERR ++ "Could not update the snapshot file, because: {t}" ++ RESET, .{file_write_err});
                        continue :next_test;
                    };
                    updated_snapshots_count += 1;
                    print(BOLD ++ GREEN ++ "CREATED NEW SNAPSHOT!" ++ RESET, .{});
                    continue :next_test;
                } else {
                    tests_without_snapshots_count += 1;
                    print(WARN ++ "SNAPSHOT NOT FOUND!" ++ RESET, .{});
                    continue :next_test;
                }
            } else {
                error_tests_count += 1;
                print(ERR ++ "Could open the snapshot file, because: {t}\n" ++ RESET, .{file_open_err});
                continue :next_test;
            }
        };
        defer gpa.free(snapshot_contents);

        // Compare the snapshot to the program of the output
        const diff = switch (find_diff(program_output, snapshot_contents)) {
            .same => {
                ok_tests_count += 1;
                print(GREEN ++ BOLD ++ "OK!" ++ RESET, .{});
                continue :next_test;
            },
            .different => |diff| diff,
        };
        print(ERR ++ "SNAPSHOT DIFFERS!" ++ RESET, .{});

        different_to_snapshot_count += 1;
        if (opts.show_diff) {
            // Print diff
            print(ERR ++ "\n" ++ "=" ** 87 ++ RESET ++ "\n", .{}); // Separator line
            //
            print("   - " ++ colors.CYAN ++ "Snapshot contains" ++ RESET ++ " / " ++ YELLOW ++ "Program output contains" ++ RESET ++ ":\n", .{});
            print(FAINT ++ "     (line number {d}) |" ++ RESET, .{diff.first_different_line_number});
            print(colors.CYAN ++ "{s}\n" ++ RESET, .{diff.expected_line orelse FAINT ++ "(this line is not in the snapshot)"});
            print(FAINT ++ "     (line number {d}) |" ++ RESET, .{diff.first_different_line_number});
            print(YELLOW ++ "{s}\n" ++ RESET, .{diff.actual_line orelse FAINT ++ "(this line is not in the program output)"});
            //
            print(ERR ++ "=" ** 87 ++ RESET ++ "\n", .{}); // Separator line
        }

        // Write the program output into a file
        const program_output_filename: []const u8 = try std.mem.concat(gpa, u8, &[_][]const u8{ current_test_name, ".new.txt" });
        defer gpa.free(program_output_filename);
        snapshots_dir.writeFile(.{ .data = program_output, .sub_path = program_output_filename }) catch |err| {
            print(ERR ++ " Error while writing the program output into a file, because: {t}" ++ RESET, .{err});
            error_tests_count += 1;
        };
    }

    // Print results
    print("Stats:\n", .{});
    print(" - total test count: {d}\n", .{total_tests_count});
    if (tests_without_snapshots_count != 0) {
        print(WARN ++ " - tests without a snapshot: {d}\n" ++ RESET, .{tests_without_snapshots_count});
        if (!opts.accept_all) {
            print("   (Run the tests with `" ++ BOLD ++ "-Dsnap-accept-all=true" ++ RESET ++ "` to accept program outputs as new snapshots for the ones that are missing)\n", .{});
        }
    }
    if (updated_snapshots_count != 0) {
        print(GREEN ++ " - created new snapshots: {d}\n" ++ RESET, .{updated_snapshots_count});
    }
    if (different_to_snapshot_count != 0) {
        print(ERR ++ " - tests where the snapshot was different: {d}\n" ++ RESET, .{different_to_snapshot_count});
    }
    if (failed_tests_count != 0) {
        print(ERR ++ " - tests where the program returned an error: {d}\n" ++ RESET, .{failed_tests_count});
    }
    if (error_tests_count != 0) {
        print(ERR ++ " - tests where there was some file error: {d}\n" ++ RESET, .{error_tests_count});
    }
    if (ok_tests_count == total_tests_count) {
        print(GREEN ++ BOLD ++ "All tests passed!\n" ++ RESET, .{});
    } else {
        print(" - ok tests: {d}\n", .{ok_tests_count});
    }
}

const FindDiffResult = union(enum) {
    same,
    different: struct {
        first_different_line_number: usize,
        actual_line: ?[]const u8 = null,
        expected_line: ?[]const u8 = null,
        line_diff_idx: ?usize = null,
    },
};

fn find_diff(actual: []const u8, expected: []const u8) FindDiffResult {
    if (std.mem.eql(u8, actual, expected)) {
        return .same;
    }

    var actual_line_iter = std.mem.splitScalar(u8, actual, '\n');
    var expected_line_iter = std.mem.splitScalar(u8, expected, '\n');

    var line_idx: usize = 1;
    while (true) : (line_idx += 1) {
        const maybe_actual_line = actual_line_iter.next();
        const maybe_expected_line = expected_line_iter.next();

        if (maybe_actual_line == null and maybe_expected_line == null) {
            @panic("This should not happen. This means `std.mem.eql` returned `true` and we got to the end anyway.");
        }
        if (maybe_actual_line == null) {
            return .{ .different = .{ .expected_line = maybe_expected_line.?, .first_different_line_number = line_idx } };
        }
        if (maybe_expected_line == null) {
            return .{ .different = .{ .actual_line = maybe_actual_line.?, .first_different_line_number = line_idx } };
        }
        const actual_line, const expected_line = .{ maybe_actual_line.?, maybe_expected_line.? };
        if (std.mem.indexOfDiff(u8, actual_line, expected_line)) |diff_idx| {
            return .{ .different = .{
                .actual_line = actual_line,
                .expected_line = expected_line,
                .first_different_line_number = line_idx,
                .line_diff_idx = diff_idx,
            } };
        }
    }
}
