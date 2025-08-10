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
        // The system only owns the stack. Signals/Effects are owned by the user.
        self.observer_stack.deinit();
    }

    pub fn createSignal(self: *@This(), comptime T: type, value: T) !*Signal(T) {
        const ptr = try self.allocator.create(Signal(T));
        ptr.* = .{
            .allocator = self.allocator,
            .system = self, // Set the pointer back to the system.
            .value = value,
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
                self.subscribers.append(current_effect) catch {};
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
test "create signal, get and set value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = SignalSystem.init(gpa.allocator());
    defer ss.deinit();

    var my_signal = try ss.createSignal(i32, 10);
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
        .name = try ss.createSignal([]const u8, "Evan"),
        .run_count = 0,
    };
    defer context.name.deinit();

    var effect = try ss.createEffect(EffectContext, &context, &EffectContext.run);
    defer effect.deinit();

    try std.testing.expectEqual(context.run_count, 1);
    context.name.set("North Star");
    try std.testing.expectEqual(context.run_count, 2);
}
