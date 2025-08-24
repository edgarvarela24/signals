const std = @import("std");
const signal = @import("signal.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Signals Library Demo", .{});
    
    // Initialize a scope for managing signals
    var scope = signal.Scope.init(allocator);
    defer scope.deinit();

    // Create a counter signal
    var counter = try scope.createSignal(.{ .value = 0 });
    defer counter.deinit();

    // Create an effect that logs changes to the counter
    const LoggingEffect = struct {
        counter_signal: *signal.Signal(i32),
        
        pub fn run(self: *@This()) void {
            const value = self.counter_signal.get();
            std.log.info("Counter value changed to: {}", .{value});
        }
    };

    var logging_effect = LoggingEffect{ .counter_signal = counter };
    var effect = try scope.createEffect(.{ .effect = &logging_effect });
    defer effect.deinit();

    // Create a memo that doubles the counter value
    const DoublerComputer = struct {
        counter_signal: *signal.Signal(i32),
        
        pub fn run(self: *const @This()) i32 {
            return self.counter_signal.get() * 2;
        }
    };

    var doubler_computer = DoublerComputer{ .counter_signal = counter };
    var doubled_memo = try scope.createMemo(.{ .compute = &doubler_computer });
    defer doubled_memo.deinit();

    // Create an effect that logs the doubled value
    const DoublerEffect = struct {
        doubled_memo: *signal.Memo(i32),
        
        pub fn run(self: *@This()) void {
            const value = self.doubled_memo.get();
            std.log.info("Doubled value: {}", .{value});
        }
    };

    var doubler_effect_ctx = DoublerEffect{ .doubled_memo = doubled_memo };
    var doubler_effect = try scope.createEffect(.{ .effect = &doubler_effect_ctx });
    defer doubler_effect.deinit();

    // Demonstrate reactive updates
    std.log.info("Setting counter to 5...", .{});
    counter.set(5);

    std.log.info("Setting counter to 10...", .{});
    counter.set(10);

    std.log.info("Setting counter to 42...", .{});
    counter.set(42);

    std.log.info("Demo completed successfully!", .{});
}
