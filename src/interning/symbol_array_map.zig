const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const SymbolId = @import("symbol_id.zig").SymbolId;

///
/// A wrapper around the slice `[]Item`.
///
/// The `SymbolArrayMap` represents the mapping:
/// ```
///     unique_id: SymbolId  ->  item: ?Item
/// where:
///      @field(item, symbol_field_name_in_item) == unique_id
/// ```
///
/// The slice of `Item`s is sorted according to the `SymbolId`: `Item.symbol_field_name_in_item`.
///
/// This enables `O(log n)` lookup where `n` is the length of the inner `[]Item`.
///
/// This struct also asserts, that the inner slice has no two `Item`s with the same `SymbolId`.
///
/// This struct is generally immutable. If you want to modify it, take the inner slice, do some
/// operation on it and create a new instance of `SymbolArrayMap`.
/// If you are sure, that the new slice is sorted and contains no duplicates,
/// you can use the `fn from_slice_assert_sorted_no_duplicates(slice: []Item) Self` function.
///
pub fn SymbolArrayMap(
    comptime Item: type,
    comptime symbol_field_name_in_item: []const u8,
) type {
    const ActualType = switch (@typeInfo(Item)) {
        .@"struct" => Item,
        .pointer => |info| info.child,
        else => |invalid| @compileError(std.fmt.comptimePrint(
            "Expected `Item` (which is `{s}`) to be either a struct or a pointer to a struct. But it is {t}.",
            .{ @typeName(Item), @tagName(invalid) },
        )),
    };

    if (!@hasField(ActualType, symbol_field_name_in_item)) {
        @compileError(std.fmt.comptimePrint(
            "The type `Item` (which is `{s}`) does not have the field `{s}`.",
            .{ @typeName(Item), symbol_field_name_in_item },
        ));
    }
    if (@FieldType(ActualType, symbol_field_name_in_item) != SymbolId) {
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

        pub fn from_slice_assert_sorted_no_duplicates(slice: []Item) Self {
            if (slice.len == 0) {
                return Self{ .items = slice };
            }
            if (builtin.mode != .Debug and builtin.mode != .ReleaseSafe) {
                return Self{ .items = slice };
            }
            for (1..slice.len) |idx| {
                const prev_key = key_of(slice[idx - 1]);
                const current_key = key_of(slice[idx]);
                if (prev_key.idx >= current_key.idx) unreachable;
            }
            return Self{ .items = slice };
        }

        /// Creates a new instance of `SymbolArrayMap` via combining two existing instances.
        /// This operation can be thought of as doing a set-like union on two sets `left` and `right`.
        ///
        /// In case of items, which have the same key in `left` and `right`, the item from `left` will get put into the result.
        ///
        /// This function allocates only once and it does not allocate more space than it needs for the result.
        ///
        pub fn from_merge_of(left: Self, right: Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var total_cnt: usize = 0;
            var left_idx: usize = 0;
            var right_idx: usize = 0;

            // First we calculate the number of items which will have to be allocated at the end.
            while (true) : (total_cnt += 1) {
                if (left_idx >= left.items.len) break;
                const left_top = key_of(left.items[left_idx]);
                if (right_idx >= right.items.len) break;
                const right_top = key_of(right.items[right_idx]);
                //
                switch (std.math.order(left_top.idx, right_top.idx)) {
                    .eq => {
                        left_idx += 1;
                        right_idx += 1;
                    },
                    .lt => left_idx += 1,
                    .gt => right_idx += 1,
                }
            }
            total_cnt += (left.items.len - left_idx);
            total_cnt += (right.items.len - right_idx);

            left_idx = 0;
            right_idx = 0;

            const merged_slice: []Item = try allocator.alloc(Item, total_cnt);

            // Now we do a second pass, which is almost the same, but this time we actually copy elements.
            var idx: usize = 0;
            while (true) : (idx += 1) {
                if (left_idx >= left.items.len) break;
                const left_top = key_of(left.items[left_idx]);
                if (right_idx >= right.items.len) break;
                const right_top = key_of(right.items[right_idx]);
                //
                switch (std.math.order(left_top.idx, right_top.idx)) {
                    .eq => {
                        merged_slice[idx] = left.items[left_idx];
                        left_idx += 1;
                        right_idx += 1;
                    },
                    .lt => {
                        merged_slice[idx] = left.items[left_idx];
                        left_idx += 1;
                    },
                    .gt => {
                        merged_slice[idx] = right.items[right_idx];
                        right_idx += 1;
                    },
                }
            }
            @memcpy(merged_slice[idx..].ptr, left.items[left_idx..]);
            idx += (left.items.len - left_idx);
            @memcpy(merged_slice[idx..].ptr, right.items[right_idx..]);
            idx += (right.items.len - right_idx);
            assert(idx == total_cnt);

            return Self.from_slice_assert_sorted_no_duplicates(merged_slice);
        }

        ///
        /// Creates a new instance of `SortedArrayMap`.
        ///
        /// `slice` might get mutated if it was not sorted.
        ///
        /// If the `slice` contains duplicate values, they will be
        /// moved to the end of the `slice` and they will not be included in the constructed `SortedArrayMap`.
        ///
        /// To find out, which items were duplicates, you can do something similiar to this:
        /// ```zig
        ///     const slice_with_maybe_duplicates: []Item = ...;
        ///     const map = SymbolArrayMap(Item, "id").from_slice_remove_duplicates(slice_with_maybe_duplicates);
        ///     const duplicates: []Item = slice_with_maybe_duplicates[map.items.len..];
        ///
        ///     // Example usage:
        ///     const has_duplicates: bool = duplicates.len > 0;
        ///     if (has_duplicates) {
        ///         return error.has_duplicates;
        ///     }
        /// ```
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

        /// Sorts the slice according to the keys in items
        fn sort_slice(slice: []Item) void {
            std.sort.pdq(Item, slice, {}, less_than);
        }

        pub fn less_than(_: void, lhs: Item, rhs: Item) bool {
            return key_of(lhs).idx < key_of(rhs).idx;
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

    pub fn from_merge_test(
        comptime T: type,
        comptime symbol_field: []const u8,
        left_: anytype,
        right_: anytype,
        expected_: anytype,
    ) !void {
        const Map = SymbolArrayMap(T, symbol_field);

        const left_items: []T = try std.testing.allocator.alloc(T, left_.len);
        defer std.testing.allocator.free(left_items);
        inline for (0..left_.len) |idx| left_items[idx] = left_[idx];
        const left = Map.from_slice_assert_sorted_no_duplicates(left_items);
        //
        const right_items: []T = try std.testing.allocator.alloc(T, right_.len);
        defer std.testing.allocator.free(right_items);
        inline for (0..right_.len) |idx| right_items[idx] = right_[idx];
        const right = Map.from_slice_assert_sorted_no_duplicates(right_items);
        //
        const expected_items: []T = try std.testing.allocator.alloc(T, expected_.len);
        defer std.testing.allocator.free(expected_items);
        inline for (0..expected_.len) |idx| expected_items[idx] = expected_[idx];

        var buffer: []u8 = try std.testing.allocator.alloc(u8, expected_items.len * @sizeOf(T));
        defer std.testing.allocator.free(buffer);
        var fixed = std.heap.FixedBufferAllocator.init(buffer[0..]);
        //
        const actual: Map = try Map.from_merge_of(left, right, fixed.allocator());

        errdefer {
            std.debug.print(ERR ++ "\n[FAILED TEST]" ++ RESET ++ " Merge differs from expected!\n", .{});
            const min_length = @min(actual.items.len, expected_items.len);
            std.debug.print("Actual         Expected\n", .{});
            for (actual.items[0..min_length], expected_items[0..min_length]) |actual_item, expected_item| {
                if (!std.meta.eql(actual_item, expected_item)) {
                    std.debug.print(ERR, .{});
                } else {
                    std.debug.print(HIGHLIGHT ++ FAINT, .{});
                }
                std.debug.print("{any} | {any}\n", .{ actual_item, expected_item });
                std.debug.print(RESET, .{});
            }
            for (actual.items[min_length..]) |item| {
                std.debug.print(ERR ++ "(actual) {any}\n" ++ RESET, .{item});
            }
            for (expected_items[min_length..]) |item| {
                std.debug.print(ERR ++ "(expected) {any}\n" ++ RESET, .{item});
            }
        }

        if (actual.len() != expected_items.len) {
            return error.different_length;
        }
        for (actual.items, expected_items) |actual_item, expected_item| {
            if (!std.meta.eql(actual_item, expected_item)) {
                return error.item_missmatch;
            }
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

test "merge" {
    const Item = struct {
        id: SymbolId,
        secret: i32,
    };
    const i = struct {
        fn i(id: u24, secret: i32) Item {
            return Item{ .id = SymbolId.new(id), .secret = secret };
        }
    }.i;
    const i_ = struct {
        fn i_(id: u24) Item {
            return Item{ .id = SymbolId.new(id), .secret = -1 };
        }
    }.i_;

    try testing.from_merge_test(Item, "id", .{}, .{}, .{});

    try testing.from_merge_test(Item, "id", .{i_(10)}, .{}, .{i_(10)});
    try testing.from_merge_test(Item, "id", .{}, .{i_(10)}, .{i_(10)});

    try testing.from_merge_test(Item, "id", .{i_(10)}, .{}, .{i_(10)});

    try testing.from_merge_test(Item, "id", .{}, .{
        i_(10),
        i_(20),
        i_(30),
    }, .{
        i_(10),
        i_(20),
        i_(30),
    });

    try testing.from_merge_test(Item, "id", .{
        i_(10),
    }, .{
        i_(20),
    }, .{
        i_(10),
        i_(20),
    });

    try testing.from_merge_test(Item, "id", .{
        i_(20),
    }, .{
        i_(10),
    }, .{
        i_(10),
        i_(20),
    });

    try testing.from_merge_test(Item, "id", .{
        i(10, -11),
    }, .{
        i(10, -22),
    }, .{
        i(10, -11),
    });

    try testing.from_merge_test(Item, "id", .{
        i(10, -11),
        i(20, -11),
        i(30, -11),
    }, .{
        i(20, -22),
    }, .{
        i(10, -11),
        i(20, -11),
        i(30, -11),
    });

    try testing.from_merge_test(Item, "id", .{
        i(20, -11),
    }, .{
        i(10, -22),
        i(20, -22),
        i(30, -22),
    }, .{
        i(10, -22),
        i(20, -11),
        i(30, -22),
    });

    try testing.from_merge_test(Item, "id", .{
        i(30, -11),
        i(40, -11),
        i(70, -11),
        i(80, -11),
    }, .{
        i(10, -22),
        i(20, -22),
        i(30, -22),
        i(40, -22),
        i(50, -22),
        i(60, -22),
        i(70, -22),
        i(80, -22),
        i(90, -22),
    }, .{
        i(10, -22),
        i(20, -22),
        i(30, -11),
        i(40, -11),
        i(50, -22),
        i(60, -22),
        i(70, -11),
        i(80, -11),
        i(90, -22),
    });

    try testing.from_merge_test(Item, "id", .{
        i(60, -11),
        i(70, -11),
        i(80, -11),
        i(90, -11),
    }, .{
        i(30, -22),
        i(40, -22),
        i(70, -22),
        i(80, -22),
    }, .{
        i(30, -22),
        i(40, -22),
        i(60, -11),
        i(70, -11),
        i(80, -11),
        i(90, -11),
    });

    try testing.from_merge_test(Item, "id", .{
        i(60, -11),
        i(70, -11),
        i(80, -11),
        i(90, -11),
    }, .{
        i(10, -22),
        i(20, -22),
        i(30, -22),
        i(40, -22),
    }, .{
        i(10, -22),
        i(20, -22),
        i(30, -22),
        i(40, -22),
        i(60, -11),
        i(70, -11),
        i(80, -11),
        i(90, -11),
    });

    try testing.from_merge_test(Item, "id", .{
        i(10, -11),
        i(20, -11),
        i(30, -11),
        i(40, -11),
    }, .{
        i(60, -22),
        i(70, -22),
        i(80, -22),
        i(90, -22),
    }, .{
        i(10, -11),
        i(20, -11),
        i(30, -11),
        i(40, -11),
        i(60, -22),
        i(70, -22),
        i(80, -22),
        i(90, -22),
    });
}
