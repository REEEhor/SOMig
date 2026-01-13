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
        const Self = @This();
        pub const SymbolToIdMap = std.StringHashMapUnmanaged(SymbolId);
        pub const IdToSymbolMap = std.ArrayListUnmanaged([]const u8);

        allocator: Allocator,
        string_to_id_map: SymbolToIdMap,
        id_to_string_map: IdToSymbolMap,

        pub fn create(
            allocator: Allocator,
            additional_init_capacity: usize,
        ) !SymbolsManager {
            const real_init_capacity = additional_init_capacity + comptime_known_symbols.len;
            var manager = SymbolsManager{
                .allocator = allocator,
                .string_to_id_map = SymbolToIdMap.empty,
                .id_to_string_map = try IdToSymbolMap.initCapacity(allocator, real_init_capacity),
            };
            try manager.string_to_id_map.ensureTotalCapacity(allocator, @intCast(real_init_capacity));

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

        pub const InternResult = struct { id: SymbolId, was_new: bool };

        pub fn comptime_id_of(comptime symbol: []const u8) SymbolId {
            inline for (comptime_known_symbols, 0..) |known_symbol, idx| {
                if (std.mem.eql(u8, symbol, known_symbol)) {
                    return SymbolId.new(@intCast(idx));
                }
            }
            @compileError(std.fmt.comptimePrint("The symbol '{s}' could not be found in comptime.", .{symbol}));
        }

        /// Looks up the unique `SymbolId` for a string.
        /// If the string has not yet been interned, it will be added to the `SymbolsManager` and a new `SymbolId` will be returned.
        pub fn id_or_intern(self: *Self, symbol: []const u8) Allocator.Error!InternResult {
            const lookup_result = try self.string_to_id_map.getOrPut(self.allocator, symbol);
            if (lookup_result.found_existing) {
                return .{ .id = lookup_result.value_ptr.*, .was_new = false };
            }

            // The symbol is not registered.
            // Create a new owned string and add it to the ArrayList and HashMap
            const owned_string = try self.allocator.dupe(u8, symbol);

            assert(self.id_to_string_map.items.len <= std.math.maxInt(SymbolId.IdRepr));
            const symbol_idx: SymbolId.IdRepr = @truncate(self.id_to_string_map.items.len);
            const new_id = SymbolId{ .idx = symbol_idx };

            // Add it to the HashMap
            lookup_result.key_ptr.* = owned_string;
            lookup_result.value_ptr.* = new_id;

            // Add it to the ArrayList
            try self.id_to_string_map.append(self.allocator, owned_string);

            return .{ .id = new_id, .was_new = true };
        }

        pub fn id_of(self: Self, symbol: []const u8) ?SymbolId {
            return self.string_to_id_map.get(symbol);
        }

        pub fn symbol_with_id_or_null(self: Self, id: SymbolId) ?[]const u8 {
            if (id.idx >= self.id_to_string_map.items.len) {
                @branchHint(.unlikely);
                return null;
            }
            return self.id_to_string_map.items[id.idx];
        }

        pub fn symbol_with_id(self: Self, id: SymbolId) []const u8 {
            assert(id.idx < self.id_to_string_map.items.len);
            return self.id_to_string_map.items[id.idx];
        }
    };
}

pub const SymbolsManager = GenericSymbolsManager(&[_][]const u8{
    "Object",
    "Array",
    "String",
    "Double",
    "Integer",
    "Class",
    "Nil",
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

    var manager = try SymbolsManager.create(arena.allocator(), 0);

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
