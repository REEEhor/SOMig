const std = @import("std");
const assert = std.debug.assert;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;

const SymbolId = @import("./symbol_id.zig").SymbolId;

pub fn GenericSymbolsManager(
    /// Symbols that are required to be able to get looked up by
    /// the `comptime_id_of` method.
    comptime comptime_known_symbols: []const []const u8,
) type {
    return struct {
        allocator: Allocator,
        string_set: std.StringArrayHashMapUnmanaged(void),

        pub fn create(
            allocator: Allocator,
            additional_init_capacity: usize,
        ) !Self {
            const real_init_capacity = additional_init_capacity + comptime_known_symbols.len;
            var manager = Self{
                .allocator = allocator,
                .string_set = .empty,
            };
            try manager.string_set.ensureTotalCapacity(allocator, @intCast(real_init_capacity));

            // Add the fields that might have been looked up in the compile time
            inline for (comptime_known_symbols, 0..) |comptime_symbol, idx| {
                const intern_result = manager.id_or_intern(comptime_symbol) catch |err| switch (err) {
                    // SAFETY: This should be okay, since we pre-allocated all of the items ahead of time
                    Allocator.Error.OutOfMemory => unreachable,
                };
                assert(intern_result.was_new); // If this fails, there is a duplicate item in the `comptime_known_symbols`
                assert(intern_result.id.idx == idx); // If this fails, there is some logic error in the interning.
            }

            return manager;
        }

        // NOTE(epic-zig): `comptime_id_of`
        pub fn comptime_id_of(comptime symbol: []const u8) SymbolId {
            inline for (comptime_known_symbols, 0..) |known_symbol, idx| {
                if (comptime std.mem.eql(u8, symbol, known_symbol)) {
                    return SymbolId.new(@intCast(idx));
                }
            }
            @compileError(std.fmt.comptimePrint("The symbol '{s}' could not be found in comptime.", .{symbol}));
        }

        pub const InternResult = struct { id: SymbolId, was_new: bool };

        /// Looks up the unique `SymbolId` for a string.
        /// If the string has not yet been interned, it will be added to the `SymbolsManager` and a new `SymbolId` will be returned.
        pub fn id_or_intern(self: *Self, symbol: []const u8) Allocator.Error!InternResult {
            const lookup_result = try self.string_set.getOrPut(self.allocator, symbol);

            if (lookup_result.found_existing) {
                return InternResult{
                    // SAFETY: We can do this `@intCast` since we assert the size when adding the element.
                    .id = SymbolId.new(@intCast(lookup_result.index)),
                    .was_new = false,
                };
            }
            errdefer self.string_set.swapRemoveAt(lookup_result.index);

            // The key was not found in the set
            const new_index = std.math.cast(SymbolId.IdRepr, lookup_result.index) orelse return error.OutOfMemory;
            const new_id = SymbolId.new(new_index);

            // We did the look-up via a non-owned string, we have to reassign the key.
            const owned_string: []const u8 = try self.allocator.dupe(u8, symbol);
            lookup_result.key_ptr.* = owned_string;

            return .{ .id = new_id, .was_new = true };
        }

        pub fn symbol_with_id_or_null(self: Self, id: SymbolId) ?[]const u8 {
            const strings = self.string_set.keys();
            if (id.idx >= strings.len) return null;
            return strings[id.idx];
        }

        pub fn symbol_with_id(self: Self, id: SymbolId) []const u8 {
            return self.string_set.keys()[id.idx];
        }

        pub fn dump(self: Self) void {
            std.debug.print("Dumping SymbolsManager:\n", .{});
            for (self.string_set.keys(), 0..) |string, idx| {
                std.debug.print("  {d:3}:  >{s}<\n", .{ idx, string });
            }
        }

        const Self = @This();
    };
}

/// Manages symbols (interned strings) in the SOM runtime.
/// See `SymbolId` for more info.
pub const SymbolsManager = GenericSymbolsManager(&[_][]const u8{
    // Needed for the initial class hiearchy setup
    "Object",
    "Object class",
    "Class",
    "Class class",
    "Metaclass",
    "Metaclass class",
    "initialize:",

    // Rest of the primitives
    "Nil",
    "Boolean",
    "True",
    "False",
    "Integer",
    "Double",
    "String",
    "Symbol",
    "Array",
    "Block",
    "Block1",
    "Block2",
    "Block3",
    "System",
    "Method",
    "Primitive",

    // Keywords of the language
    "self",
    "super",
    "nil",
    "true",
    "false",
    "system",

    // Required for runtime
    "perform:",
    "perform:withArguments:",
    "Array class",
    "Integer class",
    "Double class",
    "escapedBlock:",
    "doesNotUnderstand:arguments:",
    "unknownGlobal:",
});

const testing = struct {
    pub fn expect_lookup(expected_idx: usize, expected_was_new: bool, actual: SymbolsManager.InternResult) !void {
        try std.testing.expectEqual(expected_idx, actual.id.idx);
        try std.testing.expectEqual(expected_was_new, actual.was_new);
    }
};

test "interining" {
    const expect_lookup = testing.expect_lookup;

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    var manager = try GenericSymbolsManager(&[_][]const u8{}).create(arena.allocator(), 0);

    for (0..5) |idx| {
        const id = SymbolId.new(@truncate(idx));
        try std.testing.expectEqual(manager.symbol_with_id_or_null(id), null);
    }

    try expect_lookup(0, true, try manager.id_or_intern("Test"));
    try std.testing.expectEqualStrings("Test", manager.symbol_with_id(SymbolId.new(0)));
    try expect_lookup(0, false, try manager.id_or_intern("Test"));
    try expect_lookup(0, false, try manager.id_or_intern("Test"));
    try std.testing.expectEqualStrings("Test", manager.symbol_with_id(SymbolId.new(0)));

    for (1..5) |idx| {
        const id = SymbolId.new(@truncate(idx));
        try std.testing.expectEqual(manager.symbol_with_id_or_null(id), null);
    }

    try expect_lookup(1, true, try manager.id_or_intern("Som"));
    try std.testing.expectEqualStrings("Som", manager.symbol_with_id_or_null(SymbolId.new(1)).?);
    try expect_lookup(1, false, try manager.id_or_intern("Som"));
    try expect_lookup(1, false, try manager.id_or_intern("Som"));
    try std.testing.expectEqualStrings("Som", manager.symbol_with_id_or_null(SymbolId.new(1)).?);

    for (2..5) |idx| {
        const id = SymbolId.new(@truncate(idx));
        try std.testing.expectEqual(manager.symbol_with_id_or_null(id), null);
    }
}
