const std = @import("std");

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
        // We only deinit the stack. Signals/Effects are deinitialized by the user.
        self.observer_stack.deinit();
    }

    pub fn createSignal(self: *@This(), comptime T: type, value: T) !*Signal(T) {
        const ptr = try self.allocator.create(Signal(T));
        ptr.* = .{
            .allocator = self.allocator,
            .value = value,
            .subscribers = std.ArrayList(*Effect).init(self.allocator),
        };
        return ptr;
    }

    pub fn createEffect(self: *@This(), context: ?*anyopaque, run_fn: *const fn (?*anyopaque, *@This()) void) !*Effect {
        const ptr = try self.allocator.create(Effect);
        ptr.* = .{
            .allocator = self.allocator,
            .context = context,
            .run_fn = run_fn,
        };
        // Run the effect once to establish subscriptions
        ptr.run(self);
        return ptr;
    }
};

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        value: T,
        subscribers: std.ArrayList(*Effect),

        pub fn get(self: *Self, ss: *SignalSystem) T {
            if (ss.observer_stack.items.len > 0) {
                const current_effect = ss.observer_stack.items[ss.observer_stack.items.len - 1];
                self.subscribers.append(current_effect) catch {};
            }
            return self.value;
        }

        pub fn set(self: *Self, new_value: T, ss: *SignalSystem) void {
            self.value = new_value;
            for (self.subscribers.items) |effect| {
                effect.run(ss);
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
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
    run_fn: *const fn (?*anyopaque, *SignalSystem) void,

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn run(self: *Self, ss: *SignalSystem) void {
        ss.observer_stack.append(self) catch return;
        self.run_fn(self.context, ss);
        _ = ss.observer_stack.pop();
    }
};

// --- TESTS ---
test "create signal, get and set value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the system
    var ss = SignalSystem.init(allocator);
    defer ss.deinit();

    // Call the method correctly
    var my_signal = try ss.createSignal(i32, 10);
    defer my_signal.deinit();

    try std.testing.expectEqual(my_signal.get(&ss), 10);
    my_signal.set(25, &ss);
    try std.testing.expectEqual(my_signal.get(&ss), 25);
}

test "create effect and run it on dependency change" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ss = SignalSystem.init(allocator);
    defer ss.deinit();

    const EffectContext = struct {
        name: *Signal([]const u8),
        run_count: u32,

        fn run(ctx_ptr: ?*anyopaque, system: *SignalSystem) void {
            const self = @as(*@This(), @ptrFromInt(@intFromPtr(ctx_ptr.?)));
            _ = self.name.get(system);
            self.run_count += 1;
        }
    };

    var context = EffectContext{
        .name = try ss.createSignal([]const u8, "Evan"),
        .run_count = 0,
    };
    defer context.name.deinit();

    var effect = try ss.createEffect(&context, &EffectContext.run);
    defer effect.deinit();

    try std.testing.expectEqual(context.run_count, 1);
    context.name.set("North Star", &ss);
    try std.testing.expectEqual(context.run_count, 2);
}
