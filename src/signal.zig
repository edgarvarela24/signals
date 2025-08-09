const std = @import("std");

var observer_stack = std.ArrayList(*Effect).init(std.heap.page_allocator);

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        value: T,
        subscribers: std.ArrayList(*Effect),

        pub fn get(self: *Self) T {
            if (observer_stack.items.len > 0) {
                const current_effect = observer_stack.items[observer_stack.items.len - 1];
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
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
    run_fn: *const fn (?*anyopaque) void,

    pub fn deinit(self: *Effect) void {
        self.allocator.destroy(self);
    }

    pub fn run(self: *Effect) void {
        observer_stack.append(self) catch return;
        self.run_fn(self.context);
        _ = observer_stack.pop();
    }
};

fn createSignal(comptime T: type, allocator: std.mem.Allocator, value: T) !*Signal(T) {
    const ptr_to_signal = try allocator.create(Signal(T));
    ptr_to_signal.* = Signal(T){
        .value = value,
        .allocator = allocator,
        .subscribers = std.ArrayList(*Effect).init(allocator),
    };
    return ptr_to_signal;
}

fn createEffect(allocator: std.mem.Allocator, context: ?*anyopaque, run_fn: *const fn (?*anyopaque) void) !*Effect {
    const ptr_to_effect = try allocator.create(Effect);
    ptr_to_effect.* = Effect{
        .allocator = allocator,
        .context = context,
        .run_fn = run_fn,
    };
    ptr_to_effect.run();
    return ptr_to_effect;
}

test "create signal, get and set value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 1. Create a signal with an initial value of 10.
    //    We need a function `createSignal` that takes a value and an allocator.
    var my_signal = try createSignal(i32, allocator, 10);
    defer my_signal.deinit();

    // 2. Check if the `get()` method returns the initial value.
    try std.testing.expectEqual(my_signal.get(), 10);

    // 3. Use the `set()` method to update the value to 25.
    my_signal.set(25);

    // 4. Check if `get()` now returns the new value.
    try std.testing.expectEqual(my_signal.get(), 25);
}

test "create effect and run it on dependency change" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Define a context struct to hold all the data our effect needs.
    const EffectContext = struct {
        name: *Signal([]const u8),
        run_count: u32,

        // The run function is now a method of our context.
        fn run(ctx_ptr: ?*anyopaque) void {
            const self = @as(*@This(), @ptrFromInt(@intFromPtr(ctx_ptr.?)));
            _ = self.name.get();
            self.run_count += 1;
        }
    };

    // Create an instance of our context.
    var context = EffectContext{
        .name = try createSignal([]const u8, allocator, "Evan"),
        .run_count = 0,
    };
    defer context.name.deinit();

    // We will update createEffect to take a context pointer and a function pointer.
    var effect = try createEffect(allocator, &context, &EffectContext.run);
    defer effect.deinit();

    try std.testing.expectEqual(context.run_count, 1);

    context.name.set("North Star");

    try std.testing.expectEqual(context.run_count, 2);
}
