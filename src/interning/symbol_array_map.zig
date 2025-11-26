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
