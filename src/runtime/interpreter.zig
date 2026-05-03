const runtime_module = @import("__runtime.zig");

const DO_DEBUG_TRACE = runtime_module.DO_DEBUG_TRACE;
const DEBUG_STRESS_GC = runtime_module.DEBUG_STRESS_GC;
const DEBUG_PRINT_GC_STATS = runtime_module.DEBUG_PRINT_GC_STATS;
const DEBUG_CLEAR_SCREEN = runtime_module.DEBUG_CLEAR_SCREEN;
const DEBUG_PRINT_PTR = runtime_module.DEBUG_PRINT_PTR;
const DEBUG_SKIP_BOOTSTRAP = runtime_module.DEBUG_SKIP_BOOTSTRAP;
const DEBUG_ARRAY_ELEMENTS_TO_PRINT = runtime_module.DEBUG_ARRAY_ELEMENTS_TO_PRINT;
const DEBUG_PRINT_STACK_ON_EXIT = runtime_module.DEBUG_PRINT_STACK_ON_EXIT;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const colors = @import("../terminal.zig");

const unions = @import("../unions.zig");

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;
const dbg_assert_eql = debug_module.dbg_assert_eql;
const dbg_assert_eql_msg = debug_module.dbg_assert_eql_msg;

const interning_module = @import("../interning/__interning.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = interning_module.SymbolArrayMap;

const codegen_module = @import("../frontend/codegen.zig");
const ClassDefinitionPair = codegen_module.ClassDefinitionPair;
const StringLiteralId = codegen_module.StringLiteralId;
const BlockDefinitionId = codegen_module.BlockDefinitionId;
const Bytecode = codegen_module.Bytecode;
const InstructionDecoder = codegen_module.InstructionDecoder;
const Instruction = codegen_module.Instruction;
const ConstantsManager = codegen_module.ConstantsManager;
const ConstantId = codegen_module.ConstantId;
const RelativeConstantId = codegen_module.RelativeConstantId;
const InstructionId = codegen_module.InstructionId;
const compile_class_with_its_parents = codegen_module.compile_class_with_its_parents;
const compile_class = codegen_module.compile_class;
const compile_class_ignoring_parents = codegen_module.compile_class_ignoring_parents;
const allocate_heap_data = codegen_module.allocate_heap_data;
const SourceCodeFiles = codegen_module.SourceCodeFiles;
const InstructionEncoder = codegen_module.InstructionEncoder;
pub const BlockDefinition = codegen_module.BlockDefinition;

const vm_object_module = @import("vm_object.zig");
const VmObject = vm_object_module.VmObject;
const HeapData = vm_object_module.HeapData;
const types = vm_object_module.types;
const FrameOnHeap = vm_object_module.FrameOnHeap;
const OpaqueHeader = vm_object_module.OpaqueHeader;
const EmptyHeapSegment = vm_object_module.EmptyHeapSegment;
const object_alignment_in_bytes = vm_object_module.object_alignment_in_bytes;
const pointer_after = vm_object_module.pointer_after;
const slice_after = vm_object_module.slice_after;

const primitives_module = @import("primitives/__primitives.zig");
const primitive_methods_module = primitives_module.primitive_methods;
const PrimitiveMethodsMap = primitives_module.PrimitiveMethodsMap;
const PrimitiveMethodImplementation = primitives_module.PrimitiveMethodImplementation;

const class_definition_module = @import("class_definition.zig");
const ClassDefinition = class_definition_module.ClassDefinition;
const MethodBody = class_definition_module.MethodBody;
const MethodDefinition = class_definition_module.MethodDefinition;
const FunctionBody = class_definition_module.FunctionBody;

/// Stores stuff that does not get deallocated
pub const Statics = struct {
    /// Allocator used for all fields in this struct.
    /// It will presumably be an arena allocator, since we just need allocating and never deallocating from it (deallocation happens only at the end).
    allocator: Allocator,

    // TODO: remove at least some of the allocators from `SymbolsManager` so the `Allocator` in here is used
    symbols_manager: SymbolsManager,

    /// NOTE: This must be a `SegmentedList`, because we want to be able to store pointers to `ClassDefinition` in other structures.
    ///       If this was just an `ArrayList`, then the pointers to `ClassDefinition`s would get invalidated during reallocations.
    all_classes: std.SegmentedList(ClassDefinition, 64),

    /// NOTE: This must be a `SegmentedList`, because we want to be able to store pointers to `MethodDefinition` in other structures.
    ///       If this was just an `ArrayList`, then the pointers to `MethodDefinition`s would get invalidated during reallocations.
    all_methods: std.SegmentedList(MethodDefinition, 128),

    constants_manager: ConstantsManager,

    const Self = @This();

    /// TODO: consider making wrapper methods for different kinds of objects
    pub inline fn allocate_for_static_object(self: *Self, header: HeapData.Header) Allocator.Error!*HeapData {
        return try allocate_heap_data(self.allocator, header);
    }
};

pub const Heap = struct {
    backing_allocator: std.mem.Allocator,
    buffer_list_head: ?*BufferHeader = null,
    interpreter: *Interpreter,

    /// Array of objects which will be considered as roots in the GC mark.
    /// See the method `protect_against_gc(...)` for more information.
    /// The allocator used for this ArrayList is the `backing_allocator` in the `Heap` struct.
    protected_objects: std.ArrayList(VmObject) = .empty,

    /// WARN: Only `.header.next_empty_segment` of this field should ever be accessed.
    ///
    /// The `.header.next_empty_segment` represents an optional head of the free list of the heap.
    ///
    /// This field represents a non-existant empty heap segment which points to the
    /// *actual* optional first empty segment, which is *actually on the heap* (if it exists).
    ///
    /// We do this shenanigan because we sometimes need a pointer of the previous item to its next item,
    /// for example in a linked-list iteration with a manipulation of the linked-list.
    /// We would use `*?*EmptyHeapSegment` in such scenarios, but that is not viable,
    /// since we store `?*EmptyHeapSegment` in `SmallPtr(?*EmptyHeapSegment)` inside packed structs,
    /// so it is not possible to take pointers to such pointers. And since the it is inside a packed
    /// struct, we cannot have a pointer of the `SmallPtr(..)` (as in `*SmallPtr(..)`) also.
    ///
    /// So we just have a dummy item that acts as if it was at the beginning of the list
    /// and instad of doing `prev_segment_next_ptr: *?*EmptyHeapSegment`, we do `prev_segment: *EmptyHeapSegment`.
    ///
    free_list_dummy_before_head: EmptyHeapSegment = .{
        .header = .{ .size_kind = undefined, .next_empty_segment = .init(null) },
    },

    minimum_number_of_pages_per_buffer: usize = 1,

    /// Does not include `BufferHeader` in buffers
    total_managed_memory_in_bytes: usize = 0,
    /// Total number of bytes in the free list.
    total_free_memory_in_bytes: usize = 0,
    gc_trigger_percentage: usize = 90,

    const Self = @This();

    pub const BufferHeader = struct {
        next_buffer: ?*BufferHeader,
        size_without_header: usize,

        pub fn slice_without_header(header: *BufferHeader) []align(object_alignment_in_bytes) u8 {
            return slice_after(header, u8, header.size_without_header);
        }
        pub fn slice_containing_header(header: *BufferHeader) []align(object_alignment_in_bytes) u8 {
            const total_size = header.size_without_header + @sizeOf(BufferHeader);
            return @as([*]align(object_alignment_in_bytes) u8, @ptrCast(header))[0..total_size];
        }
    };

    /// `required_bytes` does NOT have to be aligned to `object_alignment_in_bytes`.
    pub fn allocate(self: *Self, required_bytes: usize) Allocator.Error!*OpaqueHeader {
        var ran_gc = false;

        // Run GC if there is too much stuff allocated.
        if (self.is_gc_percentage_exceeded() or DEBUG_STRESS_GC) {
            ran_gc = true;
            try self.run_garbage_collection();
        }

        // Try to firstly allocate from the free list
        if (self.try_allocating_in_the_free_list(required_bytes)) |new_header| {
            return new_header;
        }

        // Free list failed, try it again, but now after we run GC.
        // (Only if we didn't run GC before, otherwise it wouldn't help to run it again)
        if (!ran_gc) {
            try self.run_garbage_collection();
            if (self.try_allocating_in_the_free_list(required_bytes)) |new_header| {
                return new_header;
            }
        }

        // There is no empty segment in the free list that is big enough,
        // we have to add a new buffer:
        try self.add_empty_buffer(.{ .minimum_required_bytes = required_bytes });

        // There is now a new empty buffer at the beginning
        // of the free list in the size that we need (or bigger).
        //
        // So allocating from the free list should not fail now.
        // It should also be quick, since the first item is the buffer that we want.
        return self.try_allocating_in_the_free_list(required_bytes).?;
    }

    pub fn deinit(self: *Self) void {
        self.protected_objects.deinit(self.backing_allocator);

        var maybe_current_buffer: ?*BufferHeader = self.buffer_list_head;
        while (maybe_current_buffer) |current_buffer| {
            const next = current_buffer.next_buffer;
            defer maybe_current_buffer = next;
            self.backing_allocator.free(current_buffer.slice_containing_header());
        }
    }

    pub fn reserve_at_least(self: *Self, params: struct { total_minimum_number_of_bytes: usize }) Allocator.Error!void {
        const to_allocate = params.total_minimum_number_of_bytes -| self.total_free_memory_in_bytes;
        if (to_allocate == 0) return;
        try self.add_empty_buffer(.{ .minimum_required_bytes = to_allocate });
    }

    pub const GcProtector = struct {
        heap: *Heap,
        protected_objects_length_at_creation: usize,

        pub fn protect(self: *GcProtector, object: VmObject) Allocator.Error!void {
            const allocator = self.heap.backing_allocator;
            try self.heap.protected_objects.append(allocator, object);
        }

        pub fn unprotect(self: *GcProtector) void {
            self.heap.protected_objects.shrinkRetainingCapacity(self.protected_objects_length_at_creation);
            self.heap = undefined;
            self.protected_objects_length_at_creation = undefined;
        }
    };
    pub fn protect_against_gc(self: *Self, params: struct { number_of_planned_protections: usize }) Allocator.Error!GcProtector {
        try self.protected_objects.ensureUnusedCapacity(self.backing_allocator, params.number_of_planned_protections);
        return GcProtector{
            .heap = self,
            .protected_objects_length_at_creation = self.protected_objects.items.len,
        };
    }

    fn add_empty_buffer(self: *Self, params: struct { minimum_required_bytes: usize }) Allocator.Error!void {
        const new_buffer_size = align_to_page_size(@max(
            params.minimum_required_bytes + @sizeOf(BufferHeader),
            self.minimum_buffer_size_including_header(),
        ));
        const size_of_created_space = new_buffer_size - @sizeOf(BufferHeader);

        const new_buffer: *BufferHeader = @ptrCast(try self.backing_allocator.alignedAlloc(
            u8,
            std.mem.Alignment.of(BufferHeader),
            new_buffer_size,
        ));
        new_buffer.* = BufferHeader{
            .size_without_header = size_of_created_space,
            .next_buffer = self.buffer_list_head,
        };
        self.buffer_list_head = new_buffer;
        self.total_managed_memory_in_bytes += size_of_created_space;
        self.total_free_memory_in_bytes += size_of_created_space;

        const new_empty_segment = EmptyHeapSegment.create_from(.{
            .spot_to_free = new_buffer.slice_without_header().ptr,
            .length_in_bytes = size_of_created_space,
            .previous_empty_segment = &self.free_list_dummy_before_head,
        });
        _ = new_empty_segment;
    }

    pub fn run_garbage_collection(self: *Self) Allocator.Error!void {
        if (DEBUG_PRINT_GC_STATS) {
            std.debug.print("=====================\n", .{});
            std.debug.print("=== GC MARK START ===\n", .{});
            self.debug_print();
        }
        self.gc_mark();
        if (DEBUG_PRINT_GC_STATS) {
            std.debug.print("=== GC MARK END ===\n", .{});
            self.debug_print();
            std.debug.print("=== GC SWEEP START ===\n", .{});
        }
        self.gc_sweep();
        if (DEBUG_PRINT_GC_STATS) {
            std.debug.print("=== GC SWEEP END ===\n", .{});
            self.debug_print();
            std.debug.print("--------------------\n", .{});
            std.debug.print("=====================\n", .{});
        }
    }

    fn gc_mark(self: *Self) void {
        // Mark objects on the stack
        if (DEBUG_PRINT_GC_STATS) std.debug.print("Marking stack objects: \n", .{});
        for (self.interpreter.stack.objects) |stack_object| {
            if (DEBUG_PRINT_GC_STATS) {
                std.debug.print("  • ", .{});
                self.interpreter.print_object(stack_object) catch unreachable;
            }
            stack_object.gc_mark_as_reachable_ignore_if_class_method();
        }

        // Mark blocks which currently have stack frames
        for (self.interpreter.stack.frames) |frame| {
            const block: *types.Block = unions.get_payload(frame.kind, .block) orelse continue;
            VmObject.from(block).gc_mark_as_reachable_ignore_if_class_method();
        }

        // Mark global objects
        for (self.interpreter.globals.values()) |global_object| {
            global_object.gc_mark_as_reachable_ignore_if_class_method();
        }

        // Mark protected objects
        for (self.protected_objects.items) |protected_object| {
            protected_object.gc_mark_as_reachable_ignore_if_class_method();
        }

        // Mark static objects
        var it_classes = self.interpreter.statics.all_classes.iterator(0);
        while (it_classes.next()) |class| {
            for (class.as_vm_object.get_class_fields()) |object| {
                object.gc_mark_as_reachable_ignore_if_class_method();
            }
        }

        // NOTE: `types.Method` and `types.System` objects don't require marking (they live in the static space and they don't refer to any other objects)
    }

    fn gc_sweep(self: *Self) void {
        var last_seen_empty_segment = &self.free_list_dummy_before_head;

        var next_buffer_header = self.buffer_list_head;
        while (next_buffer_header) |buffer_header| : (next_buffer_header = buffer_header.next_buffer) {
            const buffer: []align(object_alignment_in_bytes) u8 = buffer_header.slice_without_header();
            const buffer_end: *OpaqueHeader = @ptrCast(@alignCast(buffer.ptr + buffer.len));

            var object_header: *OpaqueHeader = @ptrCast(buffer.ptr);
            while (object_header != buffer_end) {
                const segment_size_in_bytes: usize = object_header.segment_size_in_bytes();
                defer {
                    // Advance the object header
                    object_header = @ptrCast(@alignCast(@as([*]u8, @ptrCast(object_header)) + segment_size_in_bytes));
                    assert(@intFromPtr(object_header) <= @intFromPtr(buffer_end));
                }
                const was_segment_before_empty: bool = last_seen_empty_segment.pointer_to_after_self() == object_header;

                if (object_header.tag == .empty_heap_segment) {
                    if (was_segment_before_empty) {
                        // Merge the previous segment with the current one
                        const current_empty_segment: *EmptyHeapSegment = object_header.asserted_cast_to(.empty_heap_segment);
                        last_seen_empty_segment.header.next_empty_segment = current_empty_segment.header.next_empty_segment;
                        last_seen_empty_segment.prolong_by_aligned_bytes(segment_size_in_bytes);
                    } else {
                        last_seen_empty_segment = @ptrCast(object_header);
                    }
                    continue;
                }
                if (object_header.is_marked) {
                    object_header.is_marked = false;
                    continue;
                }

                if (DEBUG_PRINT_GC_STATS) {
                    std.debug.print("GC sweeping: {t} at: {d:04} size={d}_bytes\n", .{
                        object_header.tag,
                        @intFromPtr(object_header) % 10_000,
                        segment_size_in_bytes,
                    });
                }

                // If the object is a block, remove it from the escaping blocks list of its home frame
                if (object_header.tag == .block) {
                    const block: *types.Block = object_header.asserted_cast_to(.block);
                    block.remove_from_potential_escaping_blocks_list();
                }

                // Now free the unmarked object
                self.total_free_memory_in_bytes += segment_size_in_bytes;

                // Mark the area as empty segment
                if (was_segment_before_empty) {
                    last_seen_empty_segment.prolong_by_aligned_bytes(segment_size_in_bytes);
                } else {
                    last_seen_empty_segment = EmptyHeapSegment.create_from(.{
                        .spot_to_free = object_header,
                        .length_in_bytes = segment_size_in_bytes,
                        .previous_empty_segment = last_seen_empty_segment,
                    });
                }

                if (DEBUG_PRINT_GC_STATS) {
                    std.debug.print("State of heap after this sweep:\n", .{});
                    self.debug_print();
                }
            }
        }
    }

    fn minimum_buffer_size_including_header(self: Self) usize {
        return self.minimum_number_of_pages_per_buffer * std.heap.pageSize();
    }

    fn align_to_page_size(addr: usize) usize {
        return std.mem.alignForward(usize, addr, std.heap.pageSize());
    }

    fn is_gc_percentage_exceeded(self: Self) bool {
        const taken = self.total_managed_memory_in_bytes - self.total_free_memory_in_bytes;
        const total = self.total_managed_memory_in_bytes;
        const percentage = self.gc_trigger_percentage;
        //
        //    taken          percentage
        //  ---------  >  ---------------    / × 100 × total
        //    total             100
        //              |
        //              V
        //  100 × taken >  total × percentage
        //
        //
        return 100 * taken > total * percentage;
    }

    fn try_allocating_in_the_free_list(self: *Self, unaligned_bytes_required: usize) ?*OpaqueHeader {
        // NOTE:
        //  `total_free_memory_in_bytes` is always aligned, so comparing aligned and unaligned values is okay via `<`
        if (self.total_free_memory_in_bytes < unaligned_bytes_required) return null;

        // Now go through the free list and try to find an empty segment which we allocate into.
        var previous_segment: *EmptyHeapSegment = &self.free_list_dummy_before_head;
        while (previous_segment.header.next_empty_segment.ptr()) |free_segment| {
            defer previous_segment = free_segment;

            const alloc_result = free_segment.try_allocate_from(.{
                .unaligned_bytes_required = unaligned_bytes_required,
                .previous_segment = previous_segment,
            }) orelse continue;

            self.total_free_memory_in_bytes -= alloc_result.total_bytes_allocated;
            return alloc_result.allocated_data;
        }

        return null;
    }

    pub fn debug_print(self: *Self) void {
        var idx: usize = 0;
        var next_buffer_header = self.buffer_list_head;

        while (next_buffer_header) |buffer_header| : (next_buffer_header = buffer_header.next_buffer) {
            defer idx += 1;
            const buffer: []align(object_alignment_in_bytes) u8 = buffer_header.slice_without_header();
            const buffer_end: *OpaqueHeader = @ptrCast(@alignCast(buffer.ptr + buffer.len));

            std.debug.print("[BUFFEER {d:02}] start={d:04}_dec size={d}_bytes end={d:04}\n", .{
                idx,
                @intFromPtr(buffer.ptr) % 10_000,
                buffer.len,
                @intFromPtr(buffer.ptr + buffer.len) % 10_000,
            });

            var object_header: *OpaqueHeader = @ptrCast(buffer.ptr);
            var object_idx: usize = 0;
            while (object_header != buffer_end) : (object_idx += 1) {
                const segment_size_in_bytes: usize = object_header.segment_size_in_bytes();
                defer {
                    // Advance the object header
                    object_header = @ptrCast(@alignCast(@as([*]u8, @ptrCast(object_header)) + segment_size_in_bytes));
                    assert(@intFromPtr(object_header) <= @intFromPtr(buffer_end));
                }

                if (object_header.tag == .empty_heap_segment) {
                    std.debug.print(colors.FAINT, .{});
                }
                defer {
                    if (object_header.tag == .empty_heap_segment) {
                        std.debug.print(colors.RESET_FAINT, .{});
                    }
                }

                std.debug.print(" • [{d:03} {d:04}_dec tag={s:<14} size={d:02}_bytes", .{
                    object_idx,
                    @intFromPtr(object_header) % 1_000_000,
                    @tagName(object_header.tag),
                    segment_size_in_bytes,
                });

                if (object_header.tag != .empty_heap_segment) {
                    std.debug.print(" marked={s}", .{if (object_header.is_marked) "1" else "0"});
                }
                std.debug.print("] ", .{});

                switch (object_header.tag) {
                    .empty_heap_segment => {},
                    .frame_header => {
                        const frame_header: *FrameOnHeap.Header = object_header.asserted_cast_to(.frame_header);
                        const frame = FrameOnHeap.frame_from_header(frame_header);
                        switch (frame.kind) {
                            .method => |method| {
                                std.debug.print("method '{s}' from '{s}'", .{
                                    self.interpreter.string_from_symbol(method.method_name),
                                    self.interpreter.string_from_symbol(method.source_class.class_name),
                                });
                            },
                            .block => |block| {
                                std.debug.print("block from method '{s}' from '{s}'", .{
                                    self.interpreter.string_from_symbol(block.home_method().method_name),
                                    self.interpreter.string_from_symbol(block.home_method().source_class.class_name),
                                });
                            },
                        }
                    },
                    else => {
                        const object = VmObject{ .data = object_header };
                        self.interpreter.print_object_no_newline(object) catch unreachable;
                    },
                }
                std.debug.print("\n", .{});
            }
        }
    }
};

pub const Stack = struct {
    frames: []Frame,
    objects: []VmObject,

    max_frames_len: usize,
    max_objects_len: usize,

    const Self = @This();

    pub const OverflowError = error{
        frame_stack_overflow,
        object_stack_overflow,
    };

    pub const Frame = struct {
        /// Index into the array `objects`
        base_ptr: [*]VmObject,
        after_return_instruction_id: InstructionId,
        kind: Kind,
        escaping_blocks_list_head: ?*types.Block = null,

        pub const Kind = union(enum) {
            /// Has guaranteed that the `body` is of type `user_land`.
            method: *const MethodDefinition,
            block: *types.Block,
        };

        pub fn self_object_ptr(self: @This()) *VmObject {
            const number_of_args = switch (self.kind) {
                .method => |method| method.number_of_aditional_args,
                .block => |block| block.block_definition.number_of_aditional_args,
            };
            return &self.base_ptr[number_of_args];
        }

        pub fn get_bytecode(self: @This()) Bytecode {
            return switch (self.kind) {
                .method => |method| method.body.user_land.bytecode,
                .block => |block| block.block_definition.body.bytecode,
            };
        }

        pub fn get_variable_ptr(self: @This(), objects: []VmObject, offset: u32) *VmObject {
            return &objects[self.base_ptr + offset];
        }

        pub fn number_of_args_and_locals(self: @This()) usize {
            // NOTE: We have to do `1 + ` to include the `self` in the number of arguments
            return switch (self.kind) {
                .method => |method| 1 + method.number_of_aditional_args + method.body.user_land.number_of_locals,
                .block => |block| 1 + block.block_definition.number_of_aditional_args + block.block_definition.body.number_of_locals,
            };
        }
    };

    pub fn init(allocated_frames: []Frame, allocated_objects: []VmObject) Self {
        var frames = allocated_frames;
        frames.len = 0;
        var objects = allocated_objects;
        objects.len = 0;
        return Self{
            .frames = frames,
            .objects = objects,
            .max_frames_len = allocated_frames.len,
            .max_objects_len = allocated_objects.len,
        };
    }

    /// Asserts that the stack is not empty
    pub fn top_frame(self: *Self) *Frame {
        assert(self.frames.len > 0);
        return &self.frames[self.frames.len - 1];
    }

    pub inline fn frames_count(self: *Self) usize {
        return self.frames.len;
    }

    pub fn pop_all_temporaries_from_top_frame(self: *Self) void {
        const base_ptr: [*]VmObject = self.top_frame().base_ptr;
        const number_of_args_and_locals: usize = self.top_frame().number_of_args_and_locals();
        const ptr_to_first_temporary: [*]VmObject = base_ptr + number_of_args_and_locals;
        const new_length: usize = index_or_length_from_pointer(ptr_to_first_temporary, self.objects).?;
        self.objects.len = new_length;
    }
};

pub const BuiltinClassDefinitions = struct {
    nil: *ClassDefinition,
    object: *ClassDefinition,
    class: *ClassDefinition,
    metaclass: *ClassDefinition,
    true: *ClassDefinition,
    false: *ClassDefinition,
    integer: *ClassDefinition,
    double: *ClassDefinition,
    array: *ClassDefinition,
    string: *ClassDefinition,
    symbol: *ClassDefinition,
    block1: *ClassDefinition,
    block2: *ClassDefinition,
    block3: *ClassDefinition,
    system: *ClassDefinition,
    method: *ClassDefinition,
    primitive: *ClassDefinition,

    pub fn block_from_number_of_non_self_arguments(self: @This(), number_of_non_self_arguments: u16) *ClassDefinition {
        return switch (number_of_non_self_arguments) {
            0 => self.block1,
            1 => self.block2,
            2 => self.block3,
            else => unreachable,
        };
    }
};

// TODO: track the current function (which will be probably in the final `stack` implementation, which will also store stack frames)
// and use it for error reporting.
pub const Interpreter = struct {
    decoder: InstructionDecoder,
    globals: std.AutoArrayHashMap(SymbolId, VmObject),
    statics: *Statics,
    heap: Heap,

    temporary_arena: *std.heap.ArenaAllocator,

    exit_code: u8 = 0,

    stdout: *Writer,
    stderr: *Writer,

    primitive_methods: PrimitiveMethodsMap,
    /// TODO: move compilation of classes outside of `Interpreter` so we don't have to have this undefined
    builtin_class_definitions: BuiltinClassDefinitions,

    source_code_files: *SourceCodeFiles,

    timer: ?std.time.Timer,

    /// TODO: put this into an argument and maybe set it to `false` by default
    do_flush_on_every_print: bool = true,
    /// TODO: put this into an argument and maybe set it to `false` by default
    nil_out_items_of_new_array: bool = true,

    stack: Stack,

    debug_max_set_object: if (DO_DEBUG_TRACE) usize else void = if (DO_DEBUG_TRACE) 0 else {},

    const Self = @This();

    pub const Error = error{
        /// TODO: maybe remove this and replace all instances with a proper error
        generic_runtime_error,
        primitive_type_error,
        method_not_found,
        frame_stack_overflow,
        object_stack_overflow,
        class_declared_multiple_times,
        division_by_zero,
        compilation_error,
        block_escaped_its_home_scope,
        out_of_bounds,
        interpreter_halted,

        /// TODO: remove this
        TODO,
    } || Allocator.Error || Writer.Error;

    pub fn new(
        heap: Heap,
        globals: std.AutoArrayHashMap(SymbolId, VmObject),
        temporary_arena: *std.heap.ArenaAllocator,
        stdout: *Writer,
        stderr: *Writer,
        statics: *Statics,
        source_code_files: *SourceCodeFiles,
        primitive_methods: PrimitiveMethodsMap,
        preallocated_object_stack: []VmObject,
        preallocated_frame_stack: []Stack.Frame,
        builtin_class_definitions: BuiltinClassDefinitions,
    ) Interpreter {
        const interpreter = Interpreter{
            .decoder = InstructionDecoder.empty,
            .stdout = stdout,
            .temporary_arena = temporary_arena,
            .stderr = stderr,
            .statics = statics,
            .heap = heap,
            .timer = null,
            .primitive_methods = primitive_methods,
            .globals = globals,
            .source_code_files = source_code_files,
            .builtin_class_definitions = builtin_class_definitions,
            .stack = Stack.init(preallocated_frame_stack, preallocated_object_stack),
        };

        return interpreter;
    }

    pub fn run(self: *Self) !void {
        self.timer = std.time.Timer.start() catch blk: {
            // TODO: make this a warning
            self.report_runtime_error("Could not initialise internal timer. `system time` and `system ticks` will return 0 every time.", .{});
            break :blk null;
        };

        while (true) {
            if (DO_DEBUG_TRACE) {
                const instr_id = self.decoder.id_of_next_instruction();
                const instruction: Instruction = self.decoder.next_instruction().?;
                const formatter = codegen_module.InstructionFormatter{
                    .constants_manager = &self.statics.constants_manager,
                    .symbols_manager = &self.statics.symbols_manager,
                    .use_color = true,
                };
                std.debug.print("\nCurrently executing: [{d:04}]{f}", .{ instr_id.idx, formatter.fmt(instruction) });
                self.decoder.set_id_of_the_next_instruction(instr_id);
            }
            const fetch = self.decoder.fetch_instruction() orelse {
                @branchHint(.cold);
                try self.report_info("The end of the bytecode has been reached.", .{});
                return;
            };
            switch_instruction: switch (fetch) {
                .pop => {
                    _ = self.pop_object();
                },
                .load_local => |access| {
                    const info: Instruction.LoadLocal = access.get(&self.decoder);
                    // TODO: create a different instruction for going up the frames and a different one for not going up the frames (so we don't have to have this loop here)
                    // NOTE: or maybe don't do that? The loop is pretty simple...

                    var result_frame: *Stack.Frame = self.top_frame();
                    for (0..info.required_frame_up_steps) |_| {
                        result_frame = switch (result_frame.kind) {
                            .method => unreachable, // If we want to go up the frame, it should be only viable via a block, not method.
                            .block => |block_object| block_object.home_frame,
                        };
                    }

                    const object: VmObject = result_frame.base_ptr[info.local_id.idx];
                    try self.push_object(object);
                },
                .set_local => |access| {
                    const info: Instruction.SetLocal = access.get(&self.decoder);
                    // TODO: create a different instruction for going up the frames and a different one for not going up the frames (so we don't have to have this loop here)
                    // NOTE: or maybe don't do that? The loop is pretty simple...

                    var result_frame: *Stack.Frame = self.top_frame();
                    for (0..info.required_frame_up_steps) |_| {
                        result_frame = switch (result_frame.kind) {
                            .method => unreachable, // If we want to go up the frame, it should be only viable via a block, not method.
                            .block => |block_object| block_object.home_frame,
                        };
                    }

                    const to_assign: VmObject = self.stack.objects[self.stack.objects.len - 1];
                    result_frame.base_ptr[info.local_id.idx] = to_assign;

                    if (to_assign.as_block()) |block| if (info.required_frame_up_steps != 0) {
                        @branchHint(.unlikely);
                        block.add_to_escaping_blocks_list();
                    };
                },
                .load_instance_var => |access| {
                    const info: Instruction.LoadInstanceVar = access.get(&self.decoder);
                    const self_object: VmObject = self.top_frame().self_object_ptr().*;
                    const instance_variable = self_object.get_instance_fields()[info.instance_var_id.idx];
                    try self.push_object(instance_variable);
                },
                .set_instance_var => |access| {
                    const info: Instruction.SetInstanceVar = access.get(&self.decoder);
                    const top_object: VmObject = self.top_stack_object().*;
                    const self_object: VmObject = self.top_frame().self_object_ptr().*;
                    self_object.get_instance_fields()[info.instance_var_id.idx] = top_object;

                    // If we have assigned a block to an instance variable,
                    // we presume that the block will escape and out-live its home frame.
                    if (top_object.as_block()) |block| {
                        @branchHint(.unlikely);
                        block.add_to_escaping_blocks_list();
                    }
                },
                .pop_into_new_array => |access| {
                    const info: Instruction.PopIntoNewArray = access.get(&self.decoder);

                    // Get the items slice from the stack
                    const items_count = info.number_of_items;
                    const len = self.stack.objects.len;
                    const items_start_idx = len - items_count;
                    const items: []VmObject = self.stack.objects[items_start_idx..len];

                    for (items) |item| {
                        if (item.as_block()) |block| {
                            @branchHint(.cold);
                            block.add_to_escaping_blocks_list();
                        }
                    }

                    // Create the array object
                    const array_object: VmObject = try types.Array.create_new(&self.heap, items);
                    // NOTE(GC): It is important to not trigger a GC until we put `array_object` on the stack below

                    // Pop all the objects that were copied into the new array
                    self.stack.objects.len = items_start_idx;

                    try self.push_object(array_object);
                },
                .load_global => |access| {
                    const global_symbol_id: SymbolId = access.get(&self.decoder);

                    const maybe_global_object: ?VmObject = self.globals.get(global_symbol_id);
                    if (maybe_global_object) |global_object| {
                        try self.push_object(global_object);
                    } else {
                        @branchHint(.unlikely);
                        // We have to invoke `unknownGlobal:` method on the `self` object.
                        const self_object: VmObject = self.top_frame().self_object_ptr().*;
                        const global_name = VmObject.from_symbol(global_symbol_id);

                        try self.push_object(global_name);
                        try self.push_object(self_object);
                        try self.send_message(SymbolsManager.comptime_id_of("unknownGlobal:"));
                    }
                },
                .set_global => |access| {
                    const global_symbol_id: SymbolId = access.get(&self.decoder);

                    const object = self.top_stack_object();
                    if (object.as_block()) |block| block.add_to_escaping_blocks_list();
                    try self.globals.put(global_symbol_id, object.*);
                },
                .load_symbol => |access| {
                    const symbol_id: SymbolId = access.get(&self.decoder);
                    const object = VmObject.from_symbol(symbol_id);
                    try self.push_object(object);
                },
                .load_integer_i8 => |access| {
                    const value: i8 = access.get(&self.decoder);
                    try self.push_object(VmObject.from_integer(value));
                },
                .load_integer_i48 => |access| {
                    const value: i48 = access.get(&self.decoder);
                    try self.push_object(VmObject.from_integer(value));
                },
                .load_double => |access| {
                    const value: f64 = access.get(&self.decoder);
                    try self.push_object(VmObject.from_double(value));
                },
                .load_string => |access| {
                    const string_literal_id: StringLiteralId = access.get(&self.decoder);
                    const string_object: *types.String = self.statics.constants_manager.get_string(string_literal_id);
                    try self.push_object(VmObject.from(string_object));
                },
                .load_block => |access| {
                    const block_id: BlockDefinitionId = access.get(&self.decoder);
                    const block_info: *const BlockDefinition = self.statics.constants_manager.get_block(block_id);
                    const block_object: VmObject = try types.Block.create_new(&self.heap, block_info, self.top_frame());
                    try self.push_object(block_object);
                },
                .resolved_method_call => |access| {
                    const call_info = access.get(&self.decoder);
                    const method_ptr: *const MethodDefinition = call_info.method_ptr.ptr();
                    try self.call_method(method_ptr);
                },
                .invalid_super_call => |access| {
                    const call_info = access.get(&self.decoder);
                    try self.send_do_not_understand(null, call_info.selector);
                },
                .send_message => |access| {
                    const send_info: Instruction.SendMessage = access.get(&self.decoder);
                    try self.send_message(send_info.message_name);
                },
                .normal_return => {
                    const return_value: VmObject = self.top_stack_object().*;

                    if (return_value.as_block()) |block| {
                        @branchHint(.cold);
                        block.add_to_escaping_blocks_list();
                    }

                    // Leaves a spot at the top of the stack for the `return_value`
                    const next_instruction = (try self.pop_frame()).next_instruction;
                    if (self.stack.frames.len == 0) {
                        @branchHint(.unlikely);
                        // The program has ended
                        return;
                    }

                    // Put the return value on the top of the stack
                    self.top_stack_object().* = return_value;

                    const bytecode = self.top_frame().get_bytecode();
                    self.decoder.bytes = bytecode.bytes;
                    self.decoder.set_id_of_the_next_instruction(next_instruction);
                },
                .non_local_return => {
                    const return_value: VmObject = self.top_stack_object().*;

                    // NOTE(GC): We might be popping multiple stack frame here.
                    //           This might mean allocation of a new `Stack.Frame` on the heap,
                    //           which could trigger a deallocation of the `return_value`.
                    var p = try self.heap.protect_against_gc(.{ .number_of_planned_protections = 1 });
                    defer p.unprotect();
                    try p.protect(return_value);

                    if (return_value.as_block()) |block| {
                        @branchHint(.cold);
                        block.add_to_escaping_blocks_list();
                    }
                    const wanted_frame: *Stack.Frame, const block = switch (self.top_frame().kind) {
                        .method => unreachable, // We should never encounter a non local in a method
                        .block => |block| .{ block.home_method_frame(), block },
                    };

                    const frame_is_still_on_stack = null != index_from_pointer(wanted_frame, self.stack.frames);
                    if (!frame_is_still_on_stack) {
                        @branchHint(.cold);
                        // We have to send a message `escapedBlock:` to the current `self`.
                        const self_object: VmObject = self.top_frame().self_object_ptr().*;

                        // Put arguments on the top of the stack `self`.
                        try self.push_object(VmObject.from(block));
                        try self.push_object(self_object);

                        // Send the error message to `self` that is currently on the top of the stack.
                        try self.send_message(SymbolsManager.comptime_id_of("escapedBlock:"));

                        break :switch_instruction; // We are done with execution of this instruction
                    }

                    // We know that we want to pop at least one frame (the block frame)
                    _ = try self.pop_frame();
                    while (wanted_frame != self.top_frame()) {
                        _ = try self.pop_frame();
                    }

                    // Put the return value on the top of the stack
                    self.top_stack_object().* = return_value;

                    continue :switch_instruction .normal_return;
                },
            }
            if (DO_DEBUG_TRACE) {
                try self.debug_print_stack();
                std.debug.print("\n", .{});
            }
        }
        unreachable;
    }

    pub fn print_object_no_newline(self: *Self, object: VmObject) Error!void {
        switch (object.identify()) {
            .nil => std.debug.print("nil", .{}),
            .true => std.debug.print("true", .{}),
            .false => std.debug.print("false", .{}),
            .system => std.debug.print("system", .{}),
            .integer => std.debug.print("int({d})", .{object.as_asserted_integer()}),
            _ => std.debug.print("double({d})", .{object.as_asserted_double()}),
            .symbol => std.debug.print("symbol('{s}', id={d})", .{ self.string_from_symbol(object.as_asserted_symbol()), object.as_asserted_symbol().idx }),
            .heap_object => {
                const heap_ptr: *OpaqueHeader = object.as_asserted_ptr_to_heap();
                switch (DEBUG_PRINT_PTR) {
                    .none => {},
                    .modulo => |mod| {
                        std.debug.print("[{d:04}] ", .{@intFromPtr(heap_ptr) % mod});
                    },
                    .full_dec => {
                        std.debug.print("{d:015}_dec ", .{@intFromPtr(heap_ptr)});
                    },
                }
                switch (heap_ptr.fetch()) {
                    .string => |access| {
                        const string = access.get(heap_ptr);
                        std.debug.print("string('", .{});
                        try codegen_module.print_escaped_string(self.stderr, string.contents());
                        try self.stderr.flush();
                        std.debug.print("')", .{});
                    },
                    .generic_object => |access| {
                        const generic_object = access.get(heap_ptr);
                        const class_name: SymbolId = generic_object.class.class_name;
                        const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                        std.debug.print("Instance of class: '{s}'", .{class_name_string});
                    },
                    .class => |access| {
                        const class = access.get(heap_ptr);
                        const class_name: SymbolId = class.represented_class.class_name;
                        const class_name_string = self.statics.symbols_manager.symbol_with_id(class_name);
                        std.debug.print("Instance of class: '{s} class'", .{class_name_string});
                    },
                    .array => |access| {
                        const array = access.get(heap_ptr);
                        const items: []VmObject = array.get_items();
                        std.debug.print("Array: #(", .{});
                        for (items, 0..) |item, idx| {
                            if (idx + 1 > DEBUG_ARRAY_ELEMENTS_TO_PRINT) {
                                std.debug.print(", .. {d} more ", .{items.len - idx});
                                break;
                            }
                            if (idx != 0) std.debug.print(", ", .{});
                            try self.print_object_no_newline(item);
                        }
                        std.debug.print(")", .{});
                    },
                    .block => |access| {
                        const block = access.get(heap_ptr);
                        std.debug.print("block esc:{s} from: ", .{
                            if (block.header.has_escaped_home_context) "true " else "false",
                        });
                        try self.print_object_no_newline(VmObject.from(block.home_method().as_vm_object));
                    },
                    .method => |access| {
                        const method = access.get(heap_ptr);
                        std.debug.print("Method '{s}' from '{s}'", .{
                            self.string_from_symbol(method.method().method_name),
                            self.string_from_symbol(method.method().source_class.class_name),
                        });
                    },
                    .empty_heap_segment => unreachable,
                    .frame_header => unreachable,
                }
            },
        }
    }

    pub fn print_object(self: *Self, object: VmObject) Error!void {
        try self.print_object_no_newline(object);
        if (DEBUG_CLEAR_SCREEN) {
            std.debug.print("\x1b[0K", .{});
        }
        std.debug.print("\n", .{});
    }

    pub fn debug_print_stack(self: *Self) Error!void {
        if (DEBUG_CLEAR_SCREEN) {
            std.debug.print("\x1b[H", .{});
        }
        defer if (DEBUG_CLEAR_SCREEN) {
            std.debug.print("\x1b[0J", .{});
        };

        std.debug.print("State of the stack:\n", .{});
        if (self.stack.frames_count() == 0) {
            std.debug.print("  (empty stack)", .{});
            if (self.stack.objects.len == 0) {
                std.debug.print(" (no objects)\n", .{});
            } else {
                std.debug.print(" Objects: \n", .{});
                for (self.stack.objects, 0..) |obj, idx| {
                    std.debug.print(" - stack[{d:02}] = ", .{idx});
                    try self.print_object(obj);
                }
            }
            return;
        }

        var object_idx: usize = 0;
        var next_frame_idx: usize = 1;
        while (next_frame_idx <= self.stack.frames_count()) : (next_frame_idx += 1) {
            const current_frame: Stack.Frame = self.stack.frames[next_frame_idx - 1];
            const frame_format_string = "[{d:02} {s:<7} {s:<18}] ";
            const frame_args = .{
                next_frame_idx - 1,
                switch (current_frame.kind) {
                    .method => |method| self.string_from_symbol(method.source_class.class_name),
                    .block => |block| self.string_from_symbol(block.home_method().source_class.class_name),
                },
                switch (current_frame.kind) {
                    .method => |method| self.statics.symbols_manager.symbol_with_id(method.method_name),
                    .block => "block",
                },
            };
            const frame_length = std.fmt.count(frame_format_string, frame_args) + 2;
            std.debug.print("• " ++ frame_format_string, frame_args);

            const sentinel_object_idx: usize = blk: {
                if (next_frame_idx >= self.stack.frames_count()) {
                    break :blk self.stack.objects.len;
                } else {
                    break :blk self.stack.frames[next_frame_idx].base_ptr - self.stack.objects.ptr;
                }
            };
            var first_iteration = true;
            while (object_idx < sentinel_object_idx) : (object_idx += 1) {
                if (!first_iteration) {
                    for (0..frame_length) |_| std.debug.print(" ", .{});
                }
                first_iteration = false;
                std.debug.print("[{d:02}] ", .{object_idx});
                const obj = self.stack.objects[object_idx];
                try self.print_object(obj);
            }
        }
    }

    pub fn load_class(self: *Self, class_name: SymbolId) !*ClassDefinition {
        var class_loader = codegen_module.ClassLoader{
            .error_writer = self.stderr,
            .globals = &self.globals,
            .metaclass_definition = self.builtin_class_definitions.metaclass,
            .object_definition = self.builtin_class_definitions.object,
            .primitive_methods_map = &self.primitive_methods,
            .source_code_files = self.source_code_files,
            .statics = self.statics,
            .temporary_arena = self.temporary_arena,
        };
        return class_loader.load_class(class_name);
    }

    pub fn push_frame(
        self: *Self,
        frame_kind: Stack.Frame.Kind,
        bytecode: Bytecode,
        arguments_count_without_self: u16,
        locals_count: u16,
    ) Error!void {
        if (self.stack.frames.len >= self.stack.max_frames_len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow (too many function frames)! :D", .{});
            return Error.frame_stack_overflow;
        }
        const arguments_count: usize = @as(usize, arguments_count_without_self) + 1;
        if (self.stack.objects.len + arguments_count + locals_count > self.stack.max_objects_len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow (too many objects)! :D", .{});
            return Error.object_stack_overflow;
        }
        // Grow the stack
        const old_stack_length = self.stack.objects.len;
        const new_base_ptr: [*]VmObject = self.stack.objects.ptr + self.stack.objects.len - arguments_count;
        self.stack.frames.len += 1;
        self.stack.frames[self.stack.frames.len - 1] = Stack.Frame{
            .base_ptr = new_base_ptr,
            .kind = frame_kind,
            .after_return_instruction_id = self.decoder.id_of_next_instruction(),
        };
        self.stack.objects.len += locals_count;
        self.decoder = .new(bytecode);

        // Set all locals to nil
        const locals: []VmObject = self.stack.objects[old_stack_length..self.stack.objects.len];
        @memset(locals, VmObject.nil);
    }

    /// Asserts that the stack is not empty
    pub fn pop_frame(self: *Self) Allocator.Error!struct { next_instruction: InstructionId } {
        assert(self.stack.frames_count() > 0);

        var number_of_escaped_blocks: if (DO_DEBUG_TRACE) i32 else void = if (DO_DEBUG_TRACE) 0 else {};
        if (self.top_frame().escaping_blocks_list_head != null) putting_frame_on_heap: {
            const heap_frame: *Stack.Frame = try FrameOnHeap.reallocate_frame_to_heap(
                &self.heap,
                self.top_frame().*,
            );
            // NOTE(GC): The reallocation might have triggered a GC of the escaped block, we have to check it again
            var escaping_block = self.top_frame().escaping_blocks_list_head orelse break :putting_frame_on_heap;
            switch (self.top_frame().kind) {
                .block => |block| block.add_to_escaping_blocks_list(),
                .method => {},
            }
            while (true) {
                assert(escaping_block.header.has_escaped_home_context == false);
                assert(escaping_block.home_frame == self.top_frame());
                if (DO_DEBUG_TRACE) number_of_escaped_blocks += 1;
                escaping_block.home_frame = heap_frame;
                escaping_block.header.has_escaped_home_context = true;
                escaping_block = escaping_block.next_escaping_block orelse break;
            }
        }
        if (DO_DEBUG_TRACE) {
            std.debug.print("(popped a stackframe with {d} escaped blocks)\n", .{number_of_escaped_blocks});
        }

        // We need to not pop the top-most object on the popped frame,
        // since there will be the return value of function that is getting returned out of
        // (therefore the `+1`):
        const after_return_instruction_id = self.top_frame().after_return_instruction_id;
        const new_objects_len = (self.top_frame().base_ptr + 1) - self.stack.objects.ptr;
        self.stack.objects.len = new_objects_len;
        self.stack.frames.len -= 1;

        return .{ .next_instruction = after_return_instruction_id };
    }

    /// Asserts that the stack is not empty
    pub fn top_frame(self: *Self) *Stack.Frame {
        return self.stack.top_frame();
    }

    /// Asserts that the stack is not empty
    pub fn stack_top_object(self: Self) VmObject {
        assert(self.stack.objects.len > 0);
        return self.stack.objects[self.stack.objects.len - 1];
    }

    /// Asserts that the stack is not empty
    pub fn current_self_object(self: *Self) VmObject {
        return self.objects[self.top_frame().base_ptr];
    }

    pub fn push_object(self: *Self, object: VmObject) Error!void {
        if (self.stack.objects.len + 1 > self.stack.max_objects_len) {
            @branchHint(.cold);
            self.report_runtime_error("Stack overflow (too many objects)! :D", .{});
            return Error.object_stack_overflow;
        }
        const object_index = self.stack.objects.len;
        self.stack.objects.ptr[object_index] = object;
        self.stack.objects.len += 1;

        if (DO_DEBUG_TRACE) {
            if (self.debug_max_set_object < self.stack.objects.len) {
                self.debug_max_set_object = self.stack.objects.len;
                if (DEBUG_CLEAR_SCREEN) {
                    std.debug.print("\x1b[2J", .{});
                }
            }
        }
    }

    /// Asserts that the stack is not empty
    pub fn pop_object(self: *Self) VmObject {
        assert(self.stack.objects.len > 0);
        self.stack.objects.len -= 1;
        const object_index = self.stack.objects.len;
        return self.stack.objects.ptr[object_index];
    }

    /// Asserts that the stack is not empty
    pub fn top_stack_object(self: *Self) *VmObject {
        return &self.stack.objects[self.stack.objects.len - 1];
    }

    pub fn call_method(self: *Self, method: *const MethodDefinition) Error!void {
        switch (method.body) {
            .user_land => |method_body_info| {
                try self.push_frame(
                    .{ .method = method },
                    method_body_info.bytecode,
                    method.number_of_aditional_args,
                    method_body_info.number_of_locals,
                );
            },
            .primitive => |primitive_method| {
                const result_object: ?VmObject = primitive_method(self) catch |err| {
                    if (err != Error.interpreter_halted) {
                        self.report_info(
                            "Error happened in the primitive method `{s}` defined in class `{s}`.",
                            .{
                                self.string_from_symbol(method.method_name),
                                self.string_from_symbol(method.source_class.class_name),
                            },
                        ) catch {};
                    }
                    return err;
                };
                if (result_object) |object| try self.push_object(object);
            },
        }
    }

    pub fn send_message(self: *Self, message_selector: SymbolId) Error!void {
        const receiver_object: VmObject = self.top_stack_object().*;
        const class: *const ClassDefinition = self.get_class_of(receiver_object);
        const method: *const MethodDefinition = class.get_method(message_selector) orelse {
            @branchHint(.cold);
            try self.send_do_not_understand(class, message_selector);
            return;
        };
        try self.call_method(method);
    }

    pub fn send_do_not_understand(self: *Self, maybe_class: ?*const ClassDefinition, message_selector: SymbolId) Error!void {
        // The method was not defined in the receiver's class.
        // We now have to send the error message `doesNotUnderstand:arguments:` to the `self` object.
        const self_object: VmObject = self.top_frame().self_object_ptr().*;
        const class_of_self: *const ClassDefinition = self.get_class_of(self_object);
        const method__does_not_understand = class_of_self.get_method(SymbolsManager.comptime_id_of("doesNotUnderstand:arguments:")) orelse {
            self.report_runtime_error(
                "Tried to call the method `{s}` on an instance of a class `{s}`, but that method is not defined on that class.",
                .{
                    self.string_from_symbol(message_selector),
                    if (maybe_class) |class| self.string_from_symbol(class.class_name) else "(unknown)",
                },
            );
            self.report_runtime_error(
                "Therefore tried to call `doesNotUnderstand:arguments:` on `self` (with class '{s}'), but that class does not have that method defined as well.",
                .{self.string_from_symbol(class_of_self.class_name)},
            );
            return Error.method_not_found;
        };

        // Create an `arguments` array containing the arguments for the original method,
        // since the method `doesNotUnderstand:arguments:` requires them.
        const arity = primitives_module.helpers_module.get_method_arity_from_selector(self.string_from_symbol(message_selector));
        const arguments_len = arity - 1;
        const arguments_start_index = self.stack.objects.len - arity;
        const arguments_slice = self.stack.objects[arguments_start_index..][0..arguments_len];

        // Reverse the arguments since they are in a reverse order on the stack due to the calling convention.
        std.mem.reverse(VmObject, arguments_slice);

        for (arguments_slice) |object| {
            if (object.as_block()) |block| {
                block.add_to_escaping_blocks_list();
            }
        }

        // Create an object representing the arguments.
        const arguments: VmObject = try types.Array.create_new(&self.heap, arguments_slice);

        // NOTE(GC): We have to protect the `arguments` object because `selector_symbol`'s creation below might trigger a GC.
        var protector = try self.heap.protect_against_gc(.{ .number_of_planned_protections = 1 });
        try protector.protect(arguments);
        defer protector.unprotect();

        // Create an selector object (also required for the `doesNotUnderstand:arguments:` method).
        const selector_symbol: VmObject = VmObject.from_symbol(message_selector);

        // Pop the now-copied arguments from the stack.
        // NOTE(GC): Pop the arguments from the stack *after* the creation of the array object and selector symbol,
        //           since their creation might trigger a GC and we need to protect the objects from getting swept.
        self.stack.objects.len -= arity;

        // Push arguments for the `doesNotUnderstand:arguments:` method onto the stack.
        try self.push_object(arguments);
        try self.push_object(selector_symbol);
        try self.push_object(self_object);

        // Finally, call the method.
        try self.call_method(method__does_not_understand);
        return;
    }

    inline fn fetch_class_by_name(self: *Self, class_name_id: SymbolId) Error!*const ClassDefinition {
        // TODO: if the class is not found, the interpreter should go and find the class definition
        const class = self.class_map.getPtr(class_name_id) orelse {
            std.debug.print("Could not find the class `{s}`\n", .{self.symbols_manager.symbol_with_id(class_name_id)});
            unreachable;
        };
        return class;
    }

    pub fn get_class_of(self: *Self, object: VmObject) *const ClassDefinition {
        return switch (object.identify()) {
            _ => self.builtin_class_definitions.double,
            .nil => self.builtin_class_definitions.nil,
            .true => self.builtin_class_definitions.true,
            .false => self.builtin_class_definitions.false,
            .system => self.builtin_class_definitions.system,
            .symbol => self.builtin_class_definitions.symbol,
            .integer => self.builtin_class_definitions.integer,
            .heap_object => {
                const header_ptr: *OpaqueHeader = object.as_asserted_ptr_to_heap();
                return switch (header_ptr.fetch()) {
                    .frame_header => unreachable,
                    .empty_heap_segment => unreachable,
                    .array => self.builtin_class_definitions.array,
                    .string => self.builtin_class_definitions.string,
                    .class => |access| access.get(header_ptr).class_of_represented_class,
                    .generic_object => |access| access.get(header_ptr).class,
                    .method => |access| blk: {
                        const method: *types.Method = access.get(header_ptr);
                        if (method.is_primitive()) break :blk self.builtin_class_definitions.primitive;
                        break :blk self.builtin_class_definitions.method;
                    },
                    .block => |access| blk: {
                        const block: *types.Block = access.get(header_ptr);
                        break :blk self.builtin_class_definitions.block_from_number_of_non_self_arguments(
                            block.block_definition.number_of_aditional_args,
                        );
                    },
                };
            },
            // .class => opaque_header_ptr.asserted_cast_to(.class).class_of_represented_class,
            // .generic_object => opaque_header_ptr.asserted_cast_to(.generic_object).class,

            // .block => blk: {
            //     const block = opaque_header_ptr.asserted_cast_to(.block);
            //     break :blk self.builtin_class_definitions.block_from_number_of_non_self_arguments(
            //         block.block_definition.number_of_aditional_args,
            //     );
            // },
            // .method => blk: {
            //     const method: *types.Method = opaque_header_ptr.asserted_cast_to(.method);
            //     if (method.is_primitive()) break :blk self.builtin_class_definitions.primitive;
            //     break :blk self.builtin_class_definitions.method;
            // },

            // .frame_header => unreachable,
            // .empty_heap_segment => unreachable,
        };
    }

    pub fn report_info(self: *Self, comptime fmt: []const u8, args: anytype) Error!void {
        try self.stderr.print(colors.CYAN ++ "[runtime-info] " ++ colors.RESET ++ fmt ++ "\n", args);
        self.stderr.flush() catch {};
    }

    // TODO: remove this once all the major features are implemented
    pub fn report_TODO(self: *Self, comptime fmt: []const u8, args: anytype) error{TODO} {
        self.stderr.print(colors.ERR ++ "[TODO (not implemented)] " ++ colors.RESET ++ fmt ++ "\n", args) catch {};
        self.stderr.flush() catch {};
        return error.TODO;
    }

    pub fn report_runtime_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        // Ignore error since we report errors when there already is an error
        self.stderr.print(colors.ERR ++ "[runtime-error] " ++ colors.RESET ++ fmt ++ "\n", args) catch {};
        self.stderr.flush() catch {};
    }

    pub fn string_from_symbol(self: *Self, symbol_id: SymbolId) []const u8 {
        return self.statics.symbols_manager.symbol_with_id(symbol_id);
    }

    pub fn check_out_of_bounds_get_1_based_index(self: *Self, params: struct { accessee: []const u8, length: usize, access_index: i48 }) Error!usize {
        const accessee = params.accessee;
        const length = params.length;
        const access_index = params.access_index;
        if (access_index == 0) {
            @branchHint(.cold);
            self.report_runtime_error("Out of bounds: Tried to access {s} at index 0. SOM has 1 based indexing ;)", .{accessee});
            return Error.out_of_bounds;
        }
        if (access_index < 1) {
            @branchHint(.cold);
            self.report_runtime_error("Out of bounds: Tried to access {s} at index {d}.", .{ accessee, access_index });
            return Error.out_of_bounds;
        }
        if (access_index > length) {
            @branchHint(.cold);
            self.report_runtime_error(
                "Out of bounds: Tried to access {s} of length {d} at index {d}. Valid indexes are 1..{d}(inclusive).",
                .{ accessee, length, access_index, length },
            );
            return Error.out_of_bounds;
        }
        return @intCast(access_index);
    }

    // TODO: position of the error
    fn report_primitive_method_type_mismatch(
        self: *Self,
        expected_type_name: []const u8,
        actual_type_name: []const u8,
        method_name: []const u8,
    ) Error {
        // Ignore error since we eport errors when there already is an error
        self.report_runtime_error(
            "In method `{s}`, the argument had type `{s}`, which was not possible to convert to required type `{s}`",
            .{ method_name, actual_type_name, expected_type_name },
        );
        return Error.primitive_type_error;
    }

    fn debug_validate_escaping_blocks_list(self: *Self) void {
        for (self.stack.frames) |*frame| {
            if (frame.escaping_blocks_list_head) |first_block| {
                const from_block: *?*types.Block = first_block.header.next_of_previous_escaping_block.ptr().?;
                if (from_block.*) |b| {
                    assert(b.header.tag == .block);
                }
                assert(&frame.escaping_blocks_list_head == from_block);
            }

            var it_block = frame.escaping_blocks_list_head;
            while (it_block) |block| : (it_block = block.next_escaping_block) {
                assert(block.header.tag == .block);
                assert(block.home_frame == frame);

                // Blocks in the home context should not be marked as escaped
                assert(block.header.has_escaped_home_context == false);
                assert(block.header.next_of_previous_escaping_block.ptr().?.*.? == block);
            }
        }
    }
};

/// TODO: maybe refactor together with `index_or_length_from_pointer`
fn index_from_pointer(ptr_to_item: anytype, slice: anytype) ?usize {
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.size == .slice);
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.child == @typeInfo(@TypeOf(ptr_to_item)).pointer.child);

    const min: usize = @intFromPtr(slice.ptr);
    const max: usize = @intFromPtr(slice.ptr + slice.len);
    const value: usize = @intFromPtr(ptr_to_item);

    const check = (min <= value) and (value < max); // Difference `<= max`
    if (!check) return null;

    return ptr_to_item - slice.ptr;
}

/// TODO: maybe refactor together with `index_or_length`
fn index_or_length_from_pointer(ptr_to_item: anytype, slice: anytype) ?usize {
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.size == .slice);
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.child == @typeInfo(@TypeOf(ptr_to_item)).pointer.child);

    const min: usize = @intFromPtr(slice.ptr);
    const max: usize = @intFromPtr(slice.ptr + slice.len);
    const value: usize = @intFromPtr(ptr_to_item);

    const check = (min <= value) and (value <= max); // Difference `<= max`
    if (!check) return null;

    return ptr_to_item - slice.ptr;
}

test {
    _ = @import("testing.zig");
}
