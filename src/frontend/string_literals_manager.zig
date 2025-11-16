const std = @import("std");
const Allocator: type = std.mem.Allocator;
pub const Error = error{OutOfMemory};

pub const StringLiteralsManager = struct {
    const Self = @This();

    /// Allocator which will be used to store all the managed strings.
    string_allocator: Allocator,

    /// Allocator used for allocations for `single_literal_buffer`.
    buffer_allocator: Allocator,
    /// Buffer for a literal that is currently being created.
    single_literal_buffer: std.ArrayList(u8),

    pub fn create(
        string_allocator: Allocator,
        buffer_allocator: Allocator,
        initial_buffer_capacity: usize,
    ) Error!StringLiteralsManager {
        return StringLiteralsManager{
            .string_allocator = string_allocator,
            .buffer_allocator = buffer_allocator,
            .single_literal_buffer = try std.ArrayList(u8).initCapacity(buffer_allocator, initial_buffer_capacity),
        };
    }

    pub fn start_new_literal(self: *Self) void {
        self.single_literal_buffer.clearRetainingCapacity();
    }

    pub fn append_to_current_literal(self: *Self, chr: u8) Error!void {
        try self.single_literal_buffer.append(self.buffer_allocator, chr);
    }

    pub fn get_allocated_literal(self: *Self) Error![]u8 {
        const allocated_string = try self.string_allocator.alloc(u8, self.single_literal_buffer.items.len);
        @memcpy(allocated_string, self.single_literal_buffer.items);
        return allocated_string;
    }

    pub fn deinit(self: *Self) void {
        self.single_literal_buffer.deinit(self.buffer_allocator);
    }
};
