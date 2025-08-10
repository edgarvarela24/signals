const std = @import("std");

fn isStringLike(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr_info| {
            return switch (ptr_info.size) {
                .slice => ptr_info.child == u8,
                .one => blk: {
                    const pointee_info = @typeInfo(ptr_info.child);
                    break :blk switch (pointee_info) {
                        .array => |arr_info| arr_info.child == u8,
                        else => false,
                    };
                },
                .c => false,
                .many => false,
            };
        },
        .array => |arr_info| arr_info.child == u8,
        else => false,
    };
}

fn getSignalType(comptime options: anytype) type {
    if (@hasField(@TypeOf(options), "T")) {
        return options.T;
    } else {
        const ValueType = @TypeOf(options.value);

        if (isStringLike(ValueType)) {
            return []const u8;
        } else if (ValueType == comptime_int) {
            return i32;
        } else if (ValueType == comptime_float) {
            return f64;
        } else {
            return ValueType;
        }
    }
}

pub const SignalSystem = struct {
    allocator: std.mem.Allocator,
    observer_stack: std.ArrayList(*Effect),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .observer_stack = std.ArrayList(*Effect).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        // The system only owns the stack. Signals/Effects are owned by the user.
        self.observer_stack.deinit();
    }

    pub fn createSignal(self: *@This(), options: anytype) !*Signal(getSignalType(options)) {
        const T = getSignalType(options);
        const ptr = try self.allocator.create(Signal(T));
        ptr.* = .{
            .allocator = self.allocator,
            .system = self,
            .value = options.value,
            .subscribers = std.ArrayList(*Effect).init(self.allocator),
        };
        return ptr;
    }

    pub fn createEffect(self: *@This(), comptime Context: type, context: *Context, run_fn: *const fn (*Context) void) !*Effect {
        const Wrapper = struct {
            fn run(effect: *Effect) void {
                const typed_context: *Context = @alignCast(@ptrCast(effect.context.?));
                const user_run_fn: *const fn (*Context) void = @alignCast(@ptrCast(effect.user_fn.?));
                user_run_fn(typed_context);
            }
        };

        const ptr = try self.allocator.create(Effect);
        ptr.* = .{
            .system = self, // Set the pointer back to the system.
            .context = context,
            .user_fn = @constCast(run_fn),
            .run_fn = &Wrapper.run,
        };
        // Run the effect once to establish initial subscriptions.
        ptr.run();
        return ptr;
    }
};

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        system: *SignalSystem,
        value: T,
        subscribers: std.ArrayList(*Effect),

        pub fn get(self: *Self) T {
            if (self.system.observer_stack.items.len > 0) {
                const current_effect = self.system.observer_stack.items[self.system.observer_stack.items.len - 1];
                const found_index = std.mem.indexOfScalar(*Effect, self.subscribers.items, current_effect);

                if (found_index == null) {
                    self.subscribers.append(current_effect) catch {};
                }
            }
            return self.value;
        }

        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            for (self.subscribers.items) |effect| {
                effect.run();
            }
        }

        pub fn deinit(self: *Self) void {
            self.subscribers.deinit();
            self.allocator.destroy(self);
        }
    };
}

pub const Effect = struct {
    const Self = @This();
    system: *SignalSystem,
    context: ?*anyopaque,
    user_fn: ?*anyopaque,
    run_fn: *const fn (*Effect) void,

    pub fn deinit(self: *Self) void {
        self.system.allocator.destroy(self);
    }

    pub fn run(self: *Self) void {
        self.system.observer_stack.append(self) catch return;
        defer _ = self.system.observer_stack.pop();
        self.run_fn(self);
    }
};

// --- TESTS ---
test "isStringLike function" {
    const testing = std.testing;

    // === Positive Cases (should return true) ===
    try testing.expect(isStringLike([]const u8));
    try testing.expect(isStringLike([]u8));
    try testing.expect(isStringLike(@TypeOf("hello")));
    try testing.expect(isStringLike(*const [10]u8));
    try testing.expect(isStringLike(*[10]u8));
    try testing.expect(isStringLike([10]u8));

    // === Negative Cases (should return false) ===
    try testing.expect(!isStringLike(i32));
    try testing.expect(!isStringLike([]const i32));
    try testing.expect(!isStringLike([10]bool));
    try testing.expect(!isStringLike(*const f32));
}

test "create signal, get and set value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = SignalSystem.init(gpa.allocator());
    defer ss.deinit();

    var my_signal = try ss.createSignal(.{ .value = 10 });
    defer my_signal.deinit();

    try std.testing.expectEqual(my_signal.get(), 10);
    my_signal.set(25);
    try std.testing.expectEqual(my_signal.get(), 25);
}

test "create type-safe effect" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = SignalSystem.init(gpa.allocator());
    defer ss.deinit();

    const EffectContext = struct {
        name: *Signal([]const u8),
        run_count: u32,

        fn run(self: *@This()) void {
            _ = self.name.get();
            self.run_count += 1;
        }
    };

    var context = EffectContext{
        .name = try ss.createSignal(.{ .value = "Evan" }),
        .run_count = 0,
    };
    defer context.name.deinit();

    var effect = try ss.createEffect(EffectContext, &context, &EffectContext.run);
    defer effect.deinit();

    try std.testing.expectEqual(context.run_count, 1);
    context.name.set("North Star");
    try std.testing.expectEqual(context.run_count, 2);
}

test "effect does not create duplicate subscriptions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = SignalSystem.init(gpa.allocator());
    defer ss.deinit();

    // ARRANGE: Set up a signal and a context to track the run count.
    var counter = try ss.createSignal(.{ .value = 0 });
    defer counter.deinit();

    const EffectContext = struct {
        signal_to_test: *Signal(i32),
        run_count: u32,

        fn run(self: *@This()) void {
            // This function now correctly gets the signal from its own context.
            _ = self.signal_to_test.get();
            _ = self.signal_to_test.get();
            _ = self.signal_to_test.get();

            self.run_count += 1;
        }
    };
    var context = EffectContext{ .signal_to_test = counter, .run_count = 0 };

    // Create the effect, passing the counter signal as the context.
    var effect = try ss.createEffect(EffectContext, &context, &EffectContext.run);
    defer effect.deinit();

    // ASSERT 1: The effect runs once on creation.
    try std.testing.expectEqual(@as(u32, 1), context.run_count);

    // ACT: Now, change the signal's value.
    counter.set(123);

    // ASSERT 2: The effect should have run ONLY ONE more time.
    // If the bug existed, the count would be 4 (1 initial + 3 from the set).
    // With the fix, the count will be 2 (1 initial + 1 from the set).
    try std.testing.expectEqual(@as(u32, 2), context.run_count);
}
