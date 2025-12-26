const std = @import("std");
const assert = std.debug.assert;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;

///
/// `SymbolId` is a unique identifier that `SymbolsManager` uses to identify symbols.
///
/// A symbol in SOM refers to a string that is deduplicated (interned).
/// There is only a single instance of a string in the entire runtime per (unique string).
///
/// This enables for example fast comparisons between symbols.
///
/// In SOM, it has the syntax `#some_symbol` or `#"some_symbol"` (in quotes)
/// and it can also be used to specify methods by their name, like: `#some:keyword:method:`.
///
/// In SOMig (this virtual machine), symbols are also used for representing identifiers
/// - which means not only names of methods, but also the names of classes, local variables...
///
/// String literals (which are surrounded by the `'` character in the source code)
/// and SOM string objects are managed elsewhere.
/// In a similiar way as other virtual machine objects are.
///
pub const SymbolId = struct {
    ///
    /// Index into an array of symbols in `SymbolsManager`.
    ///
    /// A 24 bit index should be enough, it gives us 2^24 = ~16.8 million possible values.
    /// That should be enough for any application written in SOM.
    ///
    /// Even if every line in a SOM source code contained 16 symbols, there could be a codebase with over one million rows.
    /// Also, the symbols would have to be *unique*, which increases the options even more.
    ///
    /// On the other hand, having only 24 bit identifier is nice for storing that in instructions.
    /// For example, the `send_message` instruction can be 32 bits in total (1 byte tag, rest `SymbolId`).
    /// Which is actually important, since that is probably the most common instruction in the whole SOM.
    ///
    idx: IdRepr,
    pub const IdRepr = u24;

    pub fn new(idx: u24) SymbolId {
        return .{ .idx = idx };
    }
};

pub const SymbolsManager = struct {
    const Self = @This();
    pub const SymbolToIdMap = std.StringHashMapUnmanaged(SymbolId);
    pub const IdToSymbolMap = std.ArrayListUnmanaged([]const u8);

    allocator: Allocator,
    string_to_id_map: SymbolToIdMap,
    id_to_string_map: IdToSymbolMap,

    pub fn create(
        allocator: Allocator,
        init_capacity: usize,
    ) !SymbolsManager {
        var manager = SymbolsManager{
            .allocator = allocator,
            .string_to_id_map = SymbolToIdMap.empty,
            .id_to_string_map = try IdToSymbolMap.initCapacity(allocator, init_capacity),
        };
        try manager.string_to_id_map.ensureTotalCapacity(allocator, @intCast(init_capacity));
        return manager;
    }

    pub const InternResult = struct { id: SymbolId, was_new: bool };

    /// Looks up the unique `SymbolId` for a string.
    /// If the string has not yet been interned, it will be added to the `SymbolManager` and a new `SymbolId` will be returned.
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
