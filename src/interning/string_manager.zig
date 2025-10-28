const std = @import("std");
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

/// Unique identifier for a string
pub const StringId = u64;

pub const StringManager = struct {
    const Self = @This();
    const StringToIndexMap = std.StringHashMapUnmanaged(StringId);
    const IndexToStringMap = std.ArrayListUnmanaged([]const u8);

    map_arena: Arena,
    list_arena: Arena,
    string_arena: Arena,

    map_allocator: Allocator,
    list_allocator: Allocator,
    string_allocator: Allocator,

    string_to_id_map: StringToIndexMap,
    id_to_string_map: IndexToStringMap,

    pub fn create(
        map_arena: Arena,
        list_arena: Arena,
        string_arena: Arena,
        init_list_capacity: usize,
    ) !StringManager {
        // TODO(cleanup): this is probably not correct (with storing so many allocators), but it is not a problem to change this later
        var manager = StringManager{
            .map_arena = map_arena,
            .list_arena = list_arena,
            .string_arena = string_arena,

            .map_allocator = undefined,
            .list_allocator = undefined,
            .string_allocator = undefined,

            .string_to_id_map = StringToIndexMap.empty,
            .id_to_string_map = undefined,
        };

        manager.map_allocator = manager.map_arena.allocator();
        manager.list_allocator = manager.list_arena.allocator();
        manager.string_allocator = manager.string_arena.allocator();

        manager.id_to_string_map = try IndexToStringMap.initCapacity(manager.list_allocator, init_list_capacity);

        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.map_arena.deinit();
        self.list_arena.deinit();
        self.string_arena.deinit();
    }

    const InternResult = struct { id: StringId, was_new: bool };

    /// Looks up the unique `StringId` for a string.
    /// If the string has not yet been interned, it will be added to the `StringManager` and a new `StringId` will be returned.
    pub fn id_or_intern(self: *Self, string: []const u8) !InternResult {
        const lookup_result = try self.string_to_id_map.getOrPut(self.map_allocator, string);
        if (lookup_result.found_existing) {
            return .{ .id = lookup_result.value_ptr.*, .was_new = false };
        }

        // Create a new owned string and add it to the ArrayList and HashMap
        const owned_string = try self.string_allocator.dupe(u8, string);
        const new_id = self.id_to_string_map.items.len;
        //
        lookup_result.key_ptr.* = owned_string;
        lookup_result.value_ptr.* = new_id;
        //
        try self.id_to_string_map.append(self.list_allocator, owned_string);

        return .{ .id = new_id, .was_new = true };
    }

    pub fn string_with_id(self: *const Self, id: StringId) ?[]const u8 {
        if (id >= self.id_to_string_map.items.len) {
            return null;
        }
        return self.id_to_string_map.items[id];
    }
};

fn create_manager_for_tests() !StringManager {
    const manager = try StringManager.create(
        Arena.init(std.testing.allocator),
        Arena.init(std.testing.allocator),
        Arena.init(std.testing.allocator),
        0,
    );
    return manager;
}

fn expect_lookup(expected: StringManager.InternResult, actual: StringManager.InternResult) !void {
    try std.testing.expectEqual(expected.id, actual.id);
    try std.testing.expectEqual(expected.was_new, actual.was_new);
}

test "interining" {
    var manager = try create_manager_for_tests();
    defer manager.deinit();

    for (0..5) |id| {
        try std.testing.expectEqual(manager.string_with_id(id), null);
    }

    try expect_lookup(.{ .id = 0, .was_new = true }, try manager.id_or_intern("Test"));
    try std.testing.expectEqualStrings("Test", manager.string_with_id(0).?);
    try expect_lookup(.{ .id = 0, .was_new = false }, try manager.id_or_intern("Test"));
    try expect_lookup(.{ .id = 0, .was_new = false }, try manager.id_or_intern("Test"));
    try std.testing.expectEqualStrings("Test", manager.string_with_id(0).?);

    for (1..5) |id| {
        try std.testing.expectEqual(manager.string_with_id(id), null);
    }

    try expect_lookup(.{ .id = 1, .was_new = true }, try manager.id_or_intern("Som"));
    try std.testing.expectEqualStrings("Som", manager.string_with_id(1).?);
    try expect_lookup(.{ .id = 1, .was_new = false }, try manager.id_or_intern("Som"));
    try expect_lookup(.{ .id = 1, .was_new = false }, try manager.id_or_intern("Som"));
    try std.testing.expectEqualStrings("Som", manager.string_with_id(1).?);

    for (2..5) |id| {
        try std.testing.expectEqual(manager.string_with_id(id), null);
    }
}
