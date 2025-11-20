const std = @import("std");
const assert = std.debug.assert;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;

/// Unique identifier for a string
pub const StringId = struct {
    idx: u64,
    pub fn new(idx: u64) StringId {
        return .{ .idx = idx };
    }
};

// TODO(cleanup): this is probably not correct (storing so many allocators),
// but it is not a problem to change this later
pub const StringManager = struct {
    const Self = @This();
    pub const StringToIdMap = std.StringHashMapUnmanaged(StringId);
    pub const IdToStringMap = std.ArrayListUnmanaged([]const u8);

    map_arena: *Arena,
    list_arena: *Arena,
    string_arena: *Arena,

    map_allocator: Allocator,
    list_allocator: Allocator,
    string_allocator: Allocator,

    string_to_id_map: StringToIdMap,
    id_to_string_map: IdToStringMap,

    pub fn create(
        map_arena: *Arena,
        list_arena: *Arena,
        string_arena: *Arena,
        init_list_capacity: usize,
    ) !StringManager {
        var manager = StringManager{
            .map_arena = map_arena,
            .list_arena = list_arena,
            .string_arena = string_arena,

            .map_allocator = undefined,
            .list_allocator = undefined,
            .string_allocator = undefined,

            .string_to_id_map = StringToIdMap.empty,
            .id_to_string_map = undefined,
        };

        manager.map_allocator = manager.map_arena.allocator();
        manager.list_allocator = manager.list_arena.allocator();
        manager.string_allocator = manager.string_arena.allocator();

        manager.id_to_string_map = try IdToStringMap.initCapacity(manager.list_allocator, init_list_capacity);

        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.map_arena.deinit();
        self.list_arena.deinit();
        self.string_arena.deinit();
    }

    pub const InternResult = struct { id: StringId, was_new: bool };

    /// Looks up the unique `StringId` for a string.
    /// If the string has not yet been interned, it will be added to the `StringManager` and a new `StringId` will be returned.
    pub fn id_or_intern(self: *Self, string: []const u8) !InternResult {
        const lookup_result = try self.string_to_id_map.getOrPut(self.map_allocator, string);
        if (lookup_result.found_existing) {
            return .{ .id = lookup_result.value_ptr.*, .was_new = false };
        }

        // Create a new owned string and add it to the ArrayList and HashMap
        const owned_string = try self.string_allocator.dupe(u8, string);
        const new_id = StringId{ .idx = self.id_to_string_map.items.len };
        //
        lookup_result.key_ptr.* = owned_string;
        lookup_result.value_ptr.* = new_id;
        //
        try self.id_to_string_map.append(self.list_allocator, owned_string);

        return .{ .id = new_id, .was_new = true };
    }

    pub fn id_of(self: Self, string: []const u8) ?StringId {
        return self.string_to_id_map.get(string);
    }

    pub fn string_with_id_or_null(self: Self, id: StringId) ?[]const u8 {
        if (id.idx >= self.id_to_string_map.items.len) {
            @branchHint(.unlikely);
            return null;
        }
        return self.id_to_string_map.items[id.idx];
    }

    pub fn string_with_id(self: Self, id: StringId) []const u8 {
        assert(id.idx < self.id_to_string_map.items.len);
        return self.id_to_string_map.items[id.idx];
    }
};

const testing = struct {
    pub fn expect_lookup(expected_idx: usize, expected_was_new: bool, actual: StringManager.InternResult) !void {
        try std.testing.expectEqual(expected_idx, actual.id.idx);
        try std.testing.expectEqual(expected_was_new, actual.was_new);
    }
};

test "interining" {
    const expect_lookup = testing.expect_lookup;

    var arenas = .{
        Arena.init(std.testing.allocator),
        Arena.init(std.testing.allocator),
        Arena.init(std.testing.allocator),
    };
    var manager = try StringManager.create(&arenas.@"0", &arenas.@"1", &arenas.@"2", 0);
    defer manager.deinit();

    for (0..5) |idx| {
        const id = StringId.new(idx);
        try std.testing.expectEqual(manager.string_with_id_or_null(id), null);
    }

    try expect_lookup(0, true, try manager.id_or_intern("Test"));
    try std.testing.expectEqualStrings("Test", manager.string_with_id(StringId.new(0)));
    try expect_lookup(0, false, try manager.id_or_intern("Test"));
    try expect_lookup(0, false, try manager.id_or_intern("Test"));
    try std.testing.expectEqualStrings("Test", manager.string_with_id(StringId.new(0)));

    for (1..5) |idx| {
        const id = StringId.new(idx);
        try std.testing.expectEqual(manager.string_with_id_or_null(id), null);
    }

    try expect_lookup(1, true, try manager.id_or_intern("Som"));
    try std.testing.expectEqualStrings("Som", manager.string_with_id_or_null(StringId.new(1)).?);
    try expect_lookup(1, false, try manager.id_or_intern("Som"));
    try expect_lookup(1, false, try manager.id_or_intern("Som"));
    try std.testing.expectEqualStrings("Som", manager.string_with_id_or_null(StringId.new(1)).?);

    for (2..5) |idx| {
        const id = StringId.new(idx);
        try std.testing.expectEqual(manager.string_with_id_or_null(id), null);
    }
}
