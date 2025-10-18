const std = @import("std");
pub const opts = @import("snapshot_test_options");

pub const OutputProducer = fn ([]const u8, std.mem.Allocator, *std.io.Writer) anyerror!void;

pub const TestOptions = struct {
    /// Absolute path to the directory containing snapshots.
    snapshots_directory: []const u8,

    /// Absolute path to the SOM code that is used for tests.
    tested_files_directory: []const u8,

    /// Function to be called on SOM source code.
    /// `std.io.Writer` is for output of the tested program.
    output_producer: OutputProducer,
};

pub fn do_snapshot_tests(options: TestOptions, comptime verb: []const u8) !void {
    const gpa = std.testing.allocator;
    const read_limit = 100_000;

    var som_source_dir = try std.fs.openDirAbsolute(
        options.tested_files_directory,
        .{ .iterate = true },
    );
    defer som_source_dir.close();

    std.fs.makeDirAbsolute(options.snapshots_directory) catch {};
    var snapshots_dir = std.fs.openDirAbsolute(options.snapshots_directory, .{}) catch |err| {
        std.debug.print("Could not open directory {s}, because: {t}\n", .{ options.snapshots_directory, err });
        return err;
    };
    defer snapshots_dir.close();

    var total_tests_count: i32 = 0;
    var failed_tests_count: i32 = 0;
    var tests_without_snapshots_count: i32 = 0;
    var error_tests_count: i32 = 0;
    var ok_tests_count: i32 = 0;
    var different_to_snapshot_count: i32 = 0;

    std.debug.print(verb ++ " the code in: {s}\n", .{options.tested_files_directory});
    var som_source_dir_it = som_source_dir.iterate();
    while (try som_source_dir_it.next()) |entry| {

        // Check if the entry is a SOM source code file
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".som")) continue;
        total_tests_count += 1;

        // Open the file
        var som_source_file = som_source_dir.openFile(entry.name, .{}) catch |err| {
            error_tests_count += 1;
            std.debug.print(ERR ++ "Could not open file, because: {s}\n" ++ RESET, .{@errorName(err)});
            continue;
        };
        defer som_source_file.close();
        const source_code = try som_source_file.readToEndAlloc(gpa, read_limit);
        defer gpa.free(source_code);

        // Run the test
        var writer = std.io.Writer.Allocating.init(gpa);
        defer writer.deinit();

        std.debug.print(" - Test " ++ BOLD ++ "{s:<40}" ++ RESET ++ " ...", .{std.mem.sliceTo(entry.name, '.')});
        options.output_producer(source_code, gpa, &writer.writer) catch |err| {
            failed_tests_count += 1;
            std.debug.print(ERR ++ "FAILED WITH: {t}\n" ++ RESET, .{err});
            continue;
        };
        const program_output = try writer.toOwnedSlice();
        defer gpa.free(program_output);
        std.debug.print(GREEN ++ "OK!" ++ RESET ++ " Comparing to snapshot... ", .{});

        // Open the snapshot file
        const snapshot_filename = try std.mem.concat(gpa, u8, &[_][]const u8{ entry.name, ".snapshot.txt" });
        defer gpa.free(snapshot_filename);

        var snapshot_file = blk: {
            if (snapshots_dir.openFile(snapshot_filename, .{ .mode = .read_write })) |file| {
                break :blk file;
            } else |err| {
                if (err == error.FileNotFound) {
                    tests_without_snapshots_count += 1;
                    std.debug.print(WARN ++ "No snapshot found" ++ RESET ++ " Creating one...", .{});
                    var file = snapshots_dir.createFile(snapshot_filename, .{}) catch |e| {
                        std.debug.print(ERR ++ "Could not create the file, because: {t}\n" ++ RESET, .{e});
                        continue;
                    };
                    defer file.close();
                    file.writeAll(program_output) catch |e| {
                        std.debug.print(ERR ++ "Could not write to the file, because: {t}\n" ++ RESET, .{e});
                        continue;
                    };
                    std.debug.print(" done!\n", .{});
                } else {
                    error_tests_count += 1;
                    std.debug.print(ERR ++ "Could not open snapshot, because: {t}\n" ++ RESET, .{err});
                }
                continue;
            }
        };
        defer snapshot_file.close();

        const snapshot_text = try snapshot_file.readToEndAlloc(gpa, read_limit);
        defer gpa.free(snapshot_text);

        // Compare the snapshot to the program of the output
        const diff_index = std.mem.indexOfDiff(u8, program_output, snapshot_text) orelse {
            ok_tests_count += 1;
            std.debug.print(GREEN ++ "OK!\n" ++ RESET, .{});
            continue;
        };
        different_to_snapshot_count += 1;
        std.debug.print(WARN ++ "DIFFERENT!\n" ++ RESET, .{});
        std.debug.print("=" ** 60 ++ "\n", .{});
        print_simple_diff(program_output, snapshot_text, diff_index);

        // Save the program of the output as a new snapshot
        std.debug.print("Updating the snapshot file... ", .{});
        snapshot_file.writeAll(program_output) catch |err| {
            error_tests_count += 1;
            std.debug.print(ERR ++ "Could not update the file, because: {t}\n" ++ RESET, .{err});
            std.debug.print("=" ** 60 ++ "\n", .{});
            continue;
        };
        std.debug.print(GREEN ++ "Done :)\n" ++ RESET, .{});
        std.debug.print("(HINT: Use Git for a better diff and accepting/rejecting the change)\n", .{});
        std.debug.print("=" ** 60 ++ "\n", .{});
    }

    // Print results
    std.debug.print("\n\n\nStats:\n", .{});
    std.debug.print(" - total test count: {d}\n", .{total_tests_count});
    if (tests_without_snapshots_count != 0) {
        std.debug.print(WARN ++ " - tests without a snapshot: {d}\n" ++ RESET, .{tests_without_snapshots_count});
    }
    if (different_to_snapshot_count != 0) {
        std.debug.print(ERR ++ " - tests where the snapshot was different: {d}\n" ++ RESET, .{different_to_snapshot_count});
    }
    if (failed_tests_count != 0) {
        std.debug.print(ERR ++ " - tests where the program threw an error: {d}\n" ++ RESET, .{failed_tests_count});
    }
    if (error_tests_count != 0) {
        std.debug.print(ERR ++ " - tests where there was some file error: {d}\n" ++ RESET, .{error_tests_count});
    }
    if (ok_tests_count == total_tests_count) {
        std.debug.print(GREEN ++ "All tests passed!\n" ++ RESET, .{});
    } else {
        std.debug.print(" - ok tests: {d}\n", .{ok_tests_count});
    }
}

// TODO:
//   It might be better to show the entire output, but that would be pretty annoying in the
//   case of all tests having a different output. It would probably be best to hide this behind a flag.
fn print_simple_diff(program_output: []const u8, snapshot_text: []const u8, diff_idx: usize) void {
    const newlines_until_diff = std.mem.count(u8, program_output[0..diff_idx], "\n");

    var diff_line_start = std.mem.lastIndexOfScalar(u8, program_output[0..diff_idx], '\n') orelse 0;
    if (diff_line_start != 0) diff_line_start += 1;
    var diff_line_end_program = std.mem.indexOfScalar(u8, program_output[diff_idx..], '\n') orelse blk: {
        break :blk program_output.len - diff_idx;
    };
    diff_line_end_program += diff_idx;
    const line_program = program_output[diff_line_start..diff_line_end_program];

    std.debug.print("First line that is different (there might be more differences):\n", .{});
    std.debug.print(
        " - Program output:\n    (line {d}) " ++ RED ++ ">>>" ++ RESET ++ "{s}" ++ RED ++ "<<<\n" ++ RESET,
        .{ newlines_until_diff, line_program },
    );

    var diff_line_end_snapshot = std.mem.indexOfScalar(u8, snapshot_text[diff_idx..], '\n') orelse blk: {
        break :blk snapshot_text.len - diff_idx;
    };
    diff_line_end_snapshot += diff_idx;
    const line_snapshot = snapshot_text[diff_line_start..diff_line_end_snapshot];
    std.debug.print(
        " - Snapshot contains:\n    (line {d}) " ++ GREEN ++ ">>>" ++ RESET ++ "{s}" ++ GREEN ++ "<<<\n" ++ RESET,
        .{ newlines_until_diff, line_snapshot },
    );
}

fn write_all_to_non_existing_filename(dir: std.fs.Dir, filename: []const u8, data: []const u8) !void {
    const file = try dir.createFile(filename, .{});
    try file.writeAll(data);
}

const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const BOLD = "\x1b[1m";

const ERR = RED ++ BOLD;
const WARN = YELLOW ++ BOLD;

const RESET = "\x1b[0m";
