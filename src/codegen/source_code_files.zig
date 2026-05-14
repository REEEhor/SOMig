const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const frontend_module = @import("../frontend/__frontend.zig");
const ErrorReporter = frontend_module.ErrorReporter;

const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

pub const SourceCodeFiles = struct {
    cached_source_filepaths: Map,
    /// Arena used for storing the `cached_source_filepaths`, including the owned filepaths in it.
    arena: std.heap.ArenaAllocator,
    root_directories: []const Directory,

    /// Mapping from: class name to: class name filepath
    pub const Map = std.AutoArrayHashMapUnmanaged(SymbolId, []const u8);

    pub const Directory = struct {
        path: []const u8,
        can_be_searched_recursively: bool,
        alert_on_duplicates: bool = true,
    };

    pub fn init(params: struct {
        allocator: Allocator,
        root_directories: []const Directory,
    }) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(params.allocator),
            .root_directories = params.root_directories,
            .cached_source_filepaths = .empty,
        };
    }
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub const LookupError = RefreshError;
    pub const LookupResult = struct {
        source_code: []const u8,
        filepath: []const u8,
    };
    pub fn get_source_code_of(self: *Self, class_name: SymbolId, source_code_allocator: Allocator, refresh_params: RefreshParams) LookupError!?LookupResult {
        var retry_count: i32 = 0;
        const max_retry_count = 1;
        const filepath = while (retry_count <= max_retry_count) : (retry_count += 1) {
            if (self.cached_source_filepaths.get(class_name)) |filepath| break filepath;
            try self.refresh_cached_filepaths(refresh_params);
        } else return null;

        const source_code: []const u8 = get_src: {
            var file = std.fs.cwd().openFile(filepath, .{ .mode = .read_only }) catch |err| break :get_src err;
            defer file.close();
            break :get_src file.readToEndAlloc(source_code_allocator, 1 << 32);
        } catch |err| {
            refresh_params.error_reporter.report_error(
                .no_location,
                "Could not open '{s}' (which should contain the class '{s}') because: {t}.",
                .{ filepath, refresh_params.symbols_manager.symbol_with_id(class_name), err },
            );
            return null;
        };

        return .{ .source_code = source_code, .filepath = filepath };
    }

    pub const RefreshError = Allocator.Error;
    pub const RefreshParams = struct {
        temporary_allocator: Allocator,
        symbols_manager: *SymbolsManager,
        /// For reporting duplicate errors and file errors
        error_reporter: *ErrorReporter,
    };
    pub fn refresh_cached_filepaths(
        self: *Self,
        params: RefreshParams,
    ) RefreshError!void {

        // Free all the cached entries
        _ = self.arena.reset(.retain_capacity);
        self.cached_source_filepaths = .empty;

        for (self.root_directories) |directory| {
            var root_dir = std.fs.cwd().openDir(directory.path, .{ .iterate = true }) catch |err| {
                params.error_reporter.report_error(.no_location, "Error while opening the directory '{s}': {t}.", .{ directory.path, err });
                return;
            };
            if (directory.can_be_searched_recursively) {
                try self.refresh_single_directory_recursively(&root_dir, directory.path, directory.alert_on_duplicates, params);
            } else {
                try self.refresh_single_directory(&root_dir, directory.path, directory.alert_on_duplicates, params);
            }
        }
    }
    fn refresh_single_directory_recursively(self: *Self, root_dir: *std.fs.Dir, root_dir_name: []const u8, alert_duplicates: bool, params: RefreshParams) !void {
        const temporary_allocator = params.temporary_allocator;
        const symbols_manager = params.symbols_manager;
        const error_reporter = params.error_reporter;
        defer root_dir.close();
        var walker = try root_dir.walk(temporary_allocator);
        defer walker.deinit();
        while (true) {
            const entry = walker.next() catch |err| {
                error_reporter.report_warning(.no_location, "Had to skip an entry while looking up classes in '{s}', because of error: {t}.", .{ root_dir_name, err });
                continue;
            } orelse break;
            if (entry.kind != .file) continue;
            const file_ending = ".som";
            if (!std.mem.endsWith(u8, entry.basename, file_ending)) continue;
            const class_name = entry.basename[0 .. entry.basename.len - file_ending.len];
            const class_name_as_symbol: SymbolId = (try symbols_manager.id_or_intern(class_name)).id;
            const owned_path: []const u8 = root_dir.realpathAlloc(self.arena.allocator(), entry.path) catch |err| switch (err) {
                Allocator.Error.OutOfMemory => return Allocator.Error.OutOfMemory,
                else => {
                    error_reporter.report_error(
                        .no_location,
                        "Had to skip an while looking up classes in '{s}/{s}', because of error: {t}.",
                        .{ root_dir_name, entry.path, err },
                    );
                    continue;
                },
            };
            const gop = try self.cached_source_filepaths.getOrPut(self.arena.allocator(), class_name_as_symbol);
            if (gop.found_existing) {
                if (alert_duplicates) {
                    error_reporter.report_warning(
                        .no_location,
                        "Found the same class definition for '{s}' in multiple files. First '{s}' and now '{s}'. Ignoring the later entry.",
                        .{ class_name, gop.value_ptr.*, owned_path },
                    );
                }
            } else {
                gop.value_ptr.* = owned_path;
            }
        }
    }

    fn refresh_single_directory(self: *Self, root_dir: *std.fs.Dir, root_dir_name: []const u8, alert_duplicates: bool, params: RefreshParams) RefreshError!void {
        const symbols_manager = params.symbols_manager;
        const error_reporter = params.error_reporter;
        defer root_dir.close();
        var iterator = root_dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                error_reporter.report_warning(.no_location, "Had to skip an entry while looking up classes in '{s}', because of error: {t}.", .{ root_dir_name, err });
                continue;
            } orelse break;
            if (entry.kind != .file) continue;
            const file_ending = ".som";
            if (!std.mem.endsWith(u8, entry.name, file_ending)) continue;
            const class_name = entry.name[0 .. entry.name.len - file_ending.len];
            const class_name_as_symbol: SymbolId = (try symbols_manager.id_or_intern(class_name)).id;
            const owned_path: []const u8 = root_dir.realpathAlloc(self.arena.allocator(), entry.name) catch |err| {
                error_reporter.report_warning(.no_location, "Had to skip an entry while looking up classes in '{s}', because of error: {t}.", .{ root_dir_name, err });
                continue;
            };
            const gop = try self.cached_source_filepaths.getOrPut(self.arena.allocator(), class_name_as_symbol);
            if (gop.found_existing) {
                if (alert_duplicates) {
                    error_reporter.report_warning(
                        .no_location,
                        "Found the same class definition for '{s}' in multiple files. First '{s}' and now '{s}'. Ignoring the later entry.",
                        .{ class_name, gop.value_ptr.*, owned_path },
                    );
                }
            } else {
                gop.value_ptr.* = owned_path;
            }
        }
    }

    const Self = @This();
};
