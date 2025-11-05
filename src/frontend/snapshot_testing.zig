const std = @import("std");
pub const opts = @import("snapshot_test_options");
const print = std.debug.print;

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

    var som_source_dir = try std.fs.openDirAbsolute(
        options.tested_files_directory,
        .{ .iterate = true },
    );
    defer som_source_dir.close();

    std.fs.makeDirAbsolute(options.snapshots_directory) catch {};
    var snapshots_dir = std.fs.openDirAbsolute(options.snapshots_directory, .{}) catch |err| {
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
    while (try som_source_dir_it.next()) |entry| {

        // Check if the entry is a SOM source code file
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".som")) continue;
        total_tests_count += 1;

        // Open the file
        var som_source_file = som_source_dir.openFile(entry.name, .{}) catch |err| {
            error_tests_count += 1;
            print(ERR ++ "Could not open file, because: {s}\n" ++ RESET, .{@errorName(err)});
            continue;
        };
        defer som_source_file.close();
        const source_code = try som_source_file.readToEndAlloc(gpa, read_limit);
        defer gpa.free(source_code);

        // Run the test
        var writer = std.io.Writer.Allocating.init(gpa);
        defer writer.deinit();
        var err_writer = std.io.Writer.Allocating.init(gpa);
        defer err_writer.deinit();
        //
        print(" - Test " ++ BOLD ++ "{s:<40}" ++ RESET ++ " ...", .{std.mem.sliceTo(entry.name, '.')});
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

        const program_output = try writer.toOwnedSlice();
        defer gpa.free(program_output);

        print(GREEN ++ "DONE! " ++ RESET, .{});
        if (err_output.len == 0) {
            print("(output:  ok) ", .{});
        } else {
            print("(output: err) ", .{});
        }
        print("| ", .{});

        // Save the program output
        const program_output_filename = try std.mem.concat(gpa, u8, &[_][]const u8{ entry.name, ".new.txt" });
        defer gpa.free(program_output_filename);
        {
            const error_message = ERR ++ "Could not save the program output, because: {t}\n" ++ RESET;

            var program_output_file = snapshots_dir.createFile(program_output_filename, .{}) catch |err| {
                error_tests_count += 1;
                print(error_message, .{err});
                continue;
            };
            defer program_output_file.close();

            program_output_file.writeAll(program_output) catch |err| {
                error_tests_count += 1;
                print(error_message, .{err});
                continue;
            };
        }

        print("Comparing to snapshot... ", .{});

        // Check that the snapshot exists
        const snapshot_filename = try std.mem.concat(gpa, u8, &[_][]const u8{ entry.name, ".snapshot.txt" });
        defer gpa.free(snapshot_filename);
        snapshots_dir.access(snapshot_filename, .{}) catch |err| if (err == error.FileNotFound) {
            if (opts.accept_all) {
                snapshots_dir.rename(program_output_filename, snapshot_filename) catch |e| {
                    error_tests_count += 1;
                    print(ERR ++ "Could not update the snapshot file, because: {t}\n" ++ RESET, .{e});
                    continue;
                };
                updated_snapshots_count += 1;
                print(BOLD ++ GREEN ++ "CREATED NEW SNAPSHOT!\n" ++ RESET, .{});
            } else {
                tests_without_snapshots_count += 1;
                print(WARN ++ "SNAPSHOT FILE NOT FOUND!\n" ++ RESET, .{});
            }
            continue;
        } else {
            error_tests_count += 1;
            print(ERR ++ "Could not check if snapshot exists, because: {t}\n" ++ RESET, .{err});
            continue;
        };

        // Compare the snapshot to the program of the output
        const compare_result = find_diff(program_output_filename, snapshot_filename, options.snapshots_directory, gpa) catch {
            error_tests_count += 1;
            continue;
        };
        if (!compare_result.were_same) {
            different_to_snapshot_count += 1;
            continue;
        }
        ok_tests_count += 1;
        print(GREEN ++ "OK! " ++ RESET, .{});
        snapshots_dir.deleteFile(program_output_filename) catch |err| {
            print(ERR ++ "(could not remove the program output file: {s}, because: {t}) " ++ RESET, .{ program_output_filename, err });
            error_tests_count += 1;
        };
        print("\n", .{});
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
        print(" - created new snapshots: {d}\n", .{updated_snapshots_count});
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
        print(GREEN ++ "All tests passed!\n" ++ RESET, .{});
    } else {
        print(" - ok tests: {d}\n", .{ok_tests_count});
    }
}

fn find_diff(
    program_output_filename: []const u8,
    snapshot_filename: []const u8,
    snapshots_directory: []const u8,
    allocator: std.mem.Allocator,
) !struct { were_same: bool } {
    const argv = &[_][]const u8{
        "git",
        "diff",
        "--no-index",
        "--color=always",
        "--ignore-cr-at-eol",
        program_output_filename,
        snapshot_filename,
    };
    const git_diff = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = snapshots_directory,
    });
    defer allocator.free(git_diff.stderr);
    defer allocator.free(git_diff.stdout);

    switch (git_diff.term) {
        .Exited => |exit_code| if (exit_code == 0) return .{ .were_same = true },
        else => {},
    }

    if (git_diff.stderr.len > 1) {
        const text = git_diff.stderr;
        print(ERR ++ "Error while diffing: \"{s}\"\n" ++ RESET, .{text[0 .. text.len - 2]});
        return error.git_diff_error;
    }

    const separator = ERR ++ ("=" ** 120) ++ RESET ++ "\n";
    print(ERR ++ "DIFFERENT!\n" ++ RESET, .{});
    if (opts.show_diff) {
        print(separator, .{});

        print(FAINT ++ "Command: ", .{});
        for (argv) |arg| {
            print("{s} ", .{arg});
        }
        print("\n" ++ RESET, .{});
        // Skip the first two lines
        const lines_to_skip = 4;
        var lines_iter = std.mem.splitScalar(u8, git_diff.stdout, '\n');
        for (0..lines_to_skip) |_| _ = lines_iter.next();
        print("{s}", .{lines_iter.rest()});

        print(separator ++ "\n", .{});
    }
    return .{ .were_same = false };
}

fn write_all_to_non_existing_filename(dir: std.fs.Dir, filename: []const u8, data: []const u8) !void {
    const file = try dir.createFile(filename, .{});
    try file.writeAll(data);
}

const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const BOLD = "\x1b[1m";
const RED_BG = "\x1b[41m";
const FAINT = "\x1b[2m";

const ERR = RED ++ BOLD;
const WARN = YELLOW ++ BOLD;

const RESET = "\x1b[0m";
