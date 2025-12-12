const std = @import("std");
const SymbolId = @import("symbols_manager.zig").SymbolId;

/// A wrapper around the slice `[]Item`.
///
/// The slice of items is sorted according to the `SymbolId`: `Item.symbol_field_name_in_item`.
///
/// This enables `O(log n)` lookup where `n` is the length of the inner `[]Item`.
///
/// This struct also asserts, that the inner slice has no two `Item`s with the same `SymbolId`.
///
pub fn SymbolArrayMap(
    comptime Item: type,
    comptime symbol_field_name_in_item: []const u8,
) type {
    if (!@hasField(Item, symbol_field_name_in_item)) {
        @compileError(std.fmt.comptimePrint(
            "The type `Item` (which is `{s}`) does not have the field `{s}`.",
            .{ @typeName(Item), symbol_field_name_in_item },
        ));
    }
    if (@FieldType(Item, symbol_field_name_in_item) != SymbolId) {
        @compileError(std.fmt.comptimePrint(
            "The type of `{s}.{s}` is `{s}`, but but it should be `{s}`.",
            .{
                @typeName(Item),
                symbol_field_name_in_item,
                @typeName(@FieldType(Item, symbol_field_name_in_item)),
                @typeName(SymbolId),
            },
        ));
    }

    return struct {
        items: []Item,

        const Self = @This();
        pub const InitResult = union(enum) {
            ok: Self,
            duplicate: SymbolId,
        };

        /// Creates a new instance of `SortedArrayMap`.
        ///
        /// `slice` might get mutated if it was not sorted.
        pub fn from_slice(slice: []Item) InitResult {
            if (slice.len == 0) {
                return InitResult{ .ok = Self{ .items = slice } };
            }
            // Sort the slice according to the keys in items
            std.sort.pdq(Item, slice, {}, struct {
                pub fn less_than(_: void, lhs: Item, rhs: Item) bool {
                    return key_of(lhs).idx < key_of(rhs).idx;
                }
            }.less_than);

            // Make sure there aren't any duplicates
            for (1..slice.len) |idx| {
                const prev_key = key_of(slice[idx - 1]);
                const current_key = key_of(slice[idx]);
                if (prev_key.idx == current_key.idx) {
                    return InitResult{ .duplicate = current_key };
                }
            }

            return InitResult{ .ok = Self{ .items = slice } };
        }

        ///
        /// Creates a new instance of `SortedArrayMap`.
        ///
        /// `slice` might get mutated if it was not sorted.
        ///
        /// If the `slice` contains duplicate values, they will be
        /// moved to the end of the `slice` and they will not be included in the constructed `SortedArrayMap`.
        ///
        pub fn from_slice_remove_duplicates(slice: []Item) Self {
            // Needed for unordered removal below
            if (slice.len <= 1) return Self{ .items = slice };

            sort_slice(slice);

            // Unordered removal of duplicates
            const original_len = slice.len;
            var new_len = slice.len;
            var idx: usize = slice.len - 2;
            // Traverse the slice from back to front
            while (true) : (idx -= 1) {
                const prev_key = key_of(slice[idx + 1]);
                const current_key = key_of(slice[idx]);
                if (prev_key.idx == current_key.idx) {
                    std.mem.swap(Item, &slice[idx + 1], &slice[new_len - 1]);
                    new_len -= 1;
                }
                if (idx == 0) break;
            }

            const slice_with_unique_values = slice[0..new_len];
            if (new_len < original_len) {
                sort_slice(slice_with_unique_values);
            }

            return Self{ .items = slice_with_unique_values };
        }

        fn sort_slice(slice: []Item) void {
            // Sort the slice according to the keys in items
            std.sort.pdq(Item, slice, {}, struct {
                pub fn less_than(_: void, lhs: Item, rhs: Item) bool {
                    return key_of(lhs).idx < key_of(rhs).idx;
                }
            }.less_than);
        }

        inline fn key_of(item: Item) SymbolId {
            return @field(item, symbol_field_name_in_item);
        }

        pub inline fn len(self: Self) usize {
            return self.items.len;
        }

        pub fn get_idx(self: Self, key: SymbolId) ?usize {
            const cmp = struct {
                fn cmp(key_symbol_idx: SymbolId.IdRepr, item: Item) std.math.Order {
                    return std.math.order(key_symbol_idx, key_of(item).idx);
                }
            }.cmp;

            const idx: usize = std.sort.binarySearch(Item, self.items, key.idx, cmp) orelse return null;
            return idx;
        }

        pub fn get_ptr_mut(self: *Self, key: SymbolId) ?*Item {
            const idx = self.get_idx(key) orelse return null;
            return &self.items[idx];
        }

        pub fn get_ptr(self: Self, key: SymbolId) ?*const Item {
            const idx = self.get_idx(key) orelse return null;
            return &self.items[idx];
        }

        pub fn get(self: Self, key: SymbolId) ?Item {
            const idx = self.get_idx(key) orelse return null;
            return self.items[idx];
        }
    };
}

pub const testing = struct {
    const ERR = @import("../terminal.zig").ERR;
    const RESET = @import("../terminal.zig").RESET;
    const HIGHLIGHT = @import("../terminal.zig").CYAN;
    const FAINT = @import("../terminal.zig").FAINT;

    pub fn from_slice_remove_duplicates_test(
        comptime T: type,
        comptime symbol_field: []const u8,
        items_on_input_: anytype,
        expected_items_: anytype,
        expected_new_len: usize,
    ) !void {
        var items_on_input: []T = try std.testing.allocator.alloc(T, items_on_input_.len);
        var expected_items: []T = try std.testing.allocator.alloc(T, expected_items_.len);
        defer std.testing.allocator.free(items_on_input);
        defer std.testing.allocator.free(expected_items);
        inline for (0..items_on_input_.len) |idx| {
            items_on_input[idx] = items_on_input_[idx];
        }
        inline for (0..expected_items_.len) |idx| {
            expected_items[idx] = expected_items_[idx];
        }

        const new_len = SymbolArrayMap(T, symbol_field).from_slice_remove_duplicates(items_on_input).items.len;
        if (new_len != expected_new_len) {
            std.debug.print(
                ERR ++ "\n[FAILED TEST]" ++ RESET ++ " Different new length: actual={d}, expected={d}\n",
                .{ new_len, expected_new_len },
            );
            std.debug.print("Items are:\n" ++ HIGHLIGHT, .{});
            for (items_on_input, 0..) |item, idx| {
                if (idx == new_len) {
                    std.debug.print(FAINT, .{});
                }
                std.debug.print(" - {d:02}: {any}\n", .{ idx + 1, item });
            }
            std.debug.print(RESET, .{});
            return error.FailTest;
        }

        const actual_items = items_on_input;
        for (actual_items, expected_items, 0..) |actual, expected, idx| {
            if (idx == new_len) break;

            if (@field(actual, symbol_field).idx == @field(expected, symbol_field).idx) continue;
            std.debug.print(ERR ++ "\n[FAILED TEST]" ++ RESET ++ " Items at idx={d} differ:\n", .{idx});
            std.debug.print("\t - actual:    {any}\n", .{actual});
            std.debug.print("\t - expected:  {any}\n", .{expected});
            return error.FailTest;
        }

        const remaining_part_of_actual_items = items_on_input[new_len..];
        const remaining_part_of_expected_items = expected_items[new_len..];
        SymbolArrayMap(T, symbol_field).sort_slice(remaining_part_of_actual_items);
        SymbolArrayMap(T, symbol_field).sort_slice(remaining_part_of_expected_items);

        for (remaining_part_of_actual_items, remaining_part_of_expected_items, 0..) |actual, expected, idx| {
            if (@field(actual, symbol_field).idx == @field(expected, symbol_field).idx) continue;
            std.debug.print(ERR ++ "\n[FAILED TEST]" ++ RESET ++ " Items at idx={d} differ " ++ ERR ++ "(in the sorted part)" ++ RESET ++ "\n", .{idx});
            std.debug.print("\t - actual:    {any}\n", .{actual});
            std.debug.print("\t - expected:  {any}\n", .{expected});
            std.debug.print("Sorted section:\n", .{});
            std.debug.print("\t - actual:    {any}\n", .{remaining_part_of_actual_items});
            std.debug.print("\t - expected:  {any}\n", .{remaining_part_of_expected_items});
            return error.FailTest;
        }
    }
};

test "from_slice_remove_duplicates" {
    const Item = struct { id: SymbolId };

    const i = struct {
        fn i(id: u24) Item {
            return Item{ .id = SymbolId.new(id) };
        }
    }.i;

    try testing.from_slice_remove_duplicates_test(Item, "id", .{}, .{}, 0);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(10),
    }, .{
        i(10),
    }, 1);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(10),
        i(20),
    }, .{
        i(10),
        i(20),
    }, 2);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(10),
        i(20),
        i(30),
    }, .{
        i(10),
        i(20),
        i(30),
    }, 3);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(10),
        i(20),
        i(30),
        i(40),
    }, .{
        i(10),
        i(20),
        i(30),
        i(40),
    }, 4);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(40),
        i(30),
        i(20),
        i(10),
    }, .{
        i(10),
        i(20),
        i(30),
        i(40),
    }, 4);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(10),
        i(20),
        i(30),
        i(30),
        i(40),
    }, .{
        i(10),
        i(20),
        i(30),
        i(40),
        //
        i(30),
    }, 4);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(40),
        i(30),
        i(30),
        i(20),
        i(10),
    }, .{
        i(10),
        i(20),
        i(30),
        i(40),
        //
        i(30),
    }, 4);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(10),
        i(10),
        i(10),
        i(40),
        i(40),
        i(40),
        i(10),
        i(40),
        i(30),
        i(10),
        i(30),
        i(30),
        i(10),
        i(30),
        i(30),
        i(20),
        i(10),
        i(10),
    }, .{
        i(10),
        i(20),
        i(30),
        i(40),
        // ===========
        i(10),
        i(10),
        i(10),
        i(10),
        i(10),
        i(10),
        i(10),
        //
        i(30),
        i(30),
        i(30),
        i(30),
        //
        i(40),
        i(40),
        i(40),
    }, 4);

    try testing.from_slice_remove_duplicates_test(Item, "id", .{
        i(80),
        i(10),
        i(80),
        i(80),
        i(70),
        i(90),
        i(90),
        i(50),
        i(10),
        i(30),
        i(50),
        i(20),
        i(30),
    }, .{
        i(10), // 1
        i(20), // 2
        i(30), // 3
        i(50), // 4
        i(70), // 5
        i(80), // 6
        i(90), // 7
        //
        i(10),
        i(30),
        i(50),
        i(80),
        i(80),
        i(90),
    }, 7);
}
