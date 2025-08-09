const std = @import("std");

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        value: T,

        pub fn get(self: *const Self) T {
            return self.value;
        }

        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }
    };
}

fn createSignal(comptime T: type, allocator: std.mem.Allocator, value: T) !*Signal(T) {
    const ptr_to_signal = try allocator.create(Signal(T));
    ptr_to_signal.* = Signal(T){ .value = value, .allocator = allocator };
    return ptr_to_signal;
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
