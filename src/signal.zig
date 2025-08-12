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

pub const Scope = struct {
    allocator: std.mem.Allocator,
    observer_stack: std.ArrayList(*Effect),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .observer_stack = std.ArrayList(*Effect).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        // The scope only owns the stack. Signals/Effects are owned by the user.
        self.observer_stack.deinit();
    }

    pub fn createSignal(self: *@This(), options: anytype) !*Signal(getSignalType(options)) {
        const T = getSignalType(options);
        const ptr = try self.allocator.create(Signal(T));
        ptr.* = .{
            .allocator = self.allocator,
            .scope = self,
            .value = options.value,
            .subscribers = std.ArrayList(*Effect).init(self.allocator),
        };
        return ptr;
    }

    pub fn createEffect(self: *@This(), options: anytype) !*Effect {
        const effect_object = @field(options, "effect");
        const EffectObject = @TypeOf(effect_object.*);

        comptime {
            if (!@hasDecl(EffectObject, "run")) {
                @compileError("Effect object of type '" ++ @typeName(EffectObject) ++ "' must have a 'run' method.");
            }
        }

        const run_fn = &EffectObject.run;
        const has_deinit = @hasDecl(EffectObject, "deinit");
        const deinit_fn: ?*const fn (*EffectObject) void = if (has_deinit) &EffectObject.deinit else null;

        const Wrapper = struct {
            fn run(effect: *Effect) void {
                const typed_context: *EffectObject = @alignCast(@ptrCast(effect.context.?));
                const user_run_fn: *const fn (*EffectObject) void = @alignCast(@ptrCast(effect.user_fn.?));
                user_run_fn(typed_context);
            }

            fn deinit(effect: *Effect) void {
                const typed_context: *EffectObject = @alignCast(@ptrCast(effect.context.?));
                if (effect.user_deinit_fn) |user_deinit| {
                    const user_deinit_fn: *const fn (*EffectObject) void = @alignCast(@ptrCast(user_deinit));
                    user_deinit_fn(typed_context);
                }
            }
        };

        const ptr = try self.allocator.create(Effect);
        ptr.* = .{
            .scope = self,
            .context = effect_object,
            .user_fn = @constCast(run_fn),
            .user_deinit_fn = @constCast(deinit_fn),
            .run_fn = &Wrapper.run,
            .deinit_fn = &Wrapper.deinit,
        };

        ptr.run();
        return ptr;
    }

    pub fn createMemo(self: *@This(), options: anytype) !*Memo(@TypeOf(options.compute.run())) {
        const ComputeObj = @TypeOf(options.compute.*);
        const T = @TypeOf(options.compute.run());

        comptime {
            if (!@hasDecl(ComputeObj, "run")) {
                @compileError("Memo compute object of type '" ++ @typeName(ComputeObj) ++ "' must have a 'run' method.");
            }
        }

        const MemoUpdater = struct {
            compute_obj: *const ComputeObj,
            memo_signal: *Signal(T),
            allocator: std.mem.Allocator,
            is_initialized: bool = false,

            fn run(_self: *@This()) void {
                // First, compute the new value.
                const new_value = _self.compute_obj.run();

                const old_value = _self.memo_signal.value;

                _self.memo_signal.set(new_value);

                // If this wasn't the first run, it's now safe to free the old memory.
                if (_self.is_initialized) {
                    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
                        _self.allocator.free(old_value);
                    }
                }

                _self.is_initialized = true;
            }

            fn deinit(_self: *@This()) void {
                // Free the very last computed value when the memo is destroyed.
                if (_self.is_initialized) {
                    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
                        _self.allocator.free(_self.memo_signal.get());
                    }
                }
            }
        };

        const helpers = struct {
            fn destroy_memo_updater(allocator: std.mem.Allocator, context: ?*anyopaque) void {
                const typed_context: *MemoUpdater = @ptrCast(@alignCast(context.?));
                allocator.destroy(typed_context);
            }
        };

        const memo = try self.allocator.create(Memo(T));
        // The signal's value is `undefined` initially. The effect will immediately
        // run and set it to a valid, heap-allocated string.
        const internal_signal = try self.createSignal(.{ .value = undefined, .T = T });

        const updater_context = try self.allocator.create(MemoUpdater);
        updater_context.* = .{
            .compute_obj = options.compute,
            .memo_signal = internal_signal,
            .allocator = self.allocator,
        };

        const internal_effect = try self.createEffect(.{ .effect = updater_context });

        memo.* = .{
            .allocator = self.allocator,
            .signal = internal_signal,
            .effect = internal_effect,
            .updater_context = updater_context,
            .destroy_updater_fn = &helpers.destroy_memo_updater,
        };

        return memo;
    }
};

pub fn Memo(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        signal: *Signal(T),
        effect: *Effect,
        updater_context: ?*anyopaque,
        destroy_updater_fn: ?*const fn (std.mem.Allocator, *anyopaque) void,

        pub fn get(self: *Self) T {
            return self.signal.get();
        }

        pub fn deinit(self: *Self) void {
            self.effect.deinit();
            self.signal.deinit();
            if (self.destroy_updater_fn) |destroy_fn| {
                destroy_fn(self.allocator, self.updater_context.?);
            }
            self.allocator.destroy(self);
        }
    };
}

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        scope: *Scope,
        value: T,
        subscribers: std.ArrayList(*Effect),

        pub fn get(self: *Self) T {
            if (self.scope.observer_stack.items.len > 0) {
                const current_effect = self.scope.observer_stack.items[self.scope.observer_stack.items.len - 1];
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
    scope: *Scope,
    context: ?*anyopaque,
    user_fn: ?*anyopaque,
    user_deinit_fn: ?*anyopaque,
    run_fn: *const fn (*Effect) void,
    deinit_fn: *const fn (*Effect) void,

    pub fn deinit(self: *Self) void {
        self.deinit_fn(self);
        self.scope.allocator.destroy(self);
    }

    pub fn run(self: *Self) void {
        self.scope.observer_stack.append(self) catch return;
        defer _ = self.scope.observer_stack.pop();
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
    var ss = Scope.init(gpa.allocator());
    defer ss.deinit();

    var my_signal = try ss.createSignal(.{ .value = 10 });
    defer my_signal.deinit();

    try std.testing.expectEqual(my_signal.get(), 10);
    my_signal.set(25);
    try std.testing.expectEqual(my_signal.get(), 25);
}

test "effect does not create duplicate subscriptions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = Scope.init(gpa.allocator());
    defer ss.deinit();

    // Set up a signal and a context to track the run count.
    var counter = try ss.createSignal(.{ .value = 0 });
    defer counter.deinit();

    const EffectContext = struct {
        signal_to_test: *Signal(i32),
        run_count: u32,

        fn run(self: *@This()) void {
            _ = self.signal_to_test.get();
            _ = self.signal_to_test.get();
            _ = self.signal_to_test.get();

            self.run_count += 1;
        }
    };
    var context = EffectContext{ .signal_to_test = counter, .run_count = 0 };

    // Create the effect, passing the counter signal as the context.
    var effect = try ss.createEffect(.{ .effect = &context });
    defer effect.deinit();

    // The effect runs once on creation.
    try std.testing.expectEqual(@as(u32, 1), context.run_count);

    // change the signal's value.
    counter.set(123);

    // The effect should have run ONLY ONE more time.
    // If the bug existed, the count would be 4 (1 initial + 3 from the set).
    // With the fix, the count will be 2 (1 initial + 1 from the set).
    try std.testing.expectEqual(@as(u32, 2), context.run_count);
}

test "createEffect with an effect object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = Scope.init(gpa.allocator());
    defer ss.deinit();

    const TestEffectWithContext = struct {
        name: *Signal([]const u8),
        run_count: u32,

        fn run(self: *@This()) void {
            _ = self.name.get();
            self.run_count += 1;
        }
    };
    var my_signal = try ss.createSignal(.{ .value = "Evan" });
    defer my_signal.deinit();
    var my_effect = TestEffectWithContext{
        .name = my_signal,
        .run_count = 0,
    };

    var effect = try ss.createEffect(.{ .effect = &my_effect });
    defer effect.deinit();

    try std.testing.expectEqual(my_effect.run_count, 1);
    my_signal.set("North Star");
    try std.testing.expectEqual(my_effect.run_count, 2);
}

test "createEffect works with simple, field-less objects" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = Scope.init(gpa.allocator());
    defer ss.deinit();

    const SimpleEffect = struct {
        pub var run_count: u32 = 0;

        fn run(self: *@This()) void {
            _ = self;
            run_count += 1;
        }
    };

    // Reset static state before each test run for consistency.
    SimpleEffect.run_count = 0;

    // Create an instance of our simple effect.
    var simple_effect = SimpleEffect{};

    // Pass the simple effect object to createEffect.
    var effect = try ss.createEffect(.{ .effect = &simple_effect });
    defer effect.deinit();

    // It should have run once on creation.
    try std.testing.expectEqual(1, SimpleEffect.run_count);

    // Manually running it should increment the count again.
    // This proves the effect was created and is functional.
    effect.run();
    try std.testing.expectEqual(2, SimpleEffect.run_count);
}

test "effect reacts to multiple signal dependencies" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = Scope.init(gpa.allocator());
    defer ss.deinit();
    var first_name_sig = try ss.createSignal(.{ .value = "John" });
    defer first_name_sig.deinit();
    var last_name_sig = try ss.createSignal(.{ .value = "Doe" });
    defer last_name_sig.deinit();
    const FullNameEffect = struct {
        first_name: *Signal([]const u8),
        last_name: *Signal([]const u8),
        full_name_buf: []u8,
        run_count: u32,

        fn run(self: *@This()) void {
            const first = self.first_name.get();
            const last = self.last_name.get();

            _ = std.fmt.bufPrintZ(
                self.full_name_buf,
                "{s} {s}",
                .{ first, last },
            ) catch unreachable;

            self.run_count += 1;
        }
    };

    var buf: [100]u8 = undefined;
    var my_effect = FullNameEffect{
        .first_name = first_name_sig,
        .last_name = last_name_sig,
        .full_name_buf = &buf,
        .run_count = 0,
    };

    var effect = try ss.createEffect(.{ .effect = &my_effect });
    defer effect.deinit();

    // Check initial state
    try std.testing.expectEqual(@as(u32, 1), my_effect.run_count);
    try std.testing.expectEqualStrings("John Doe", std.mem.sliceTo(my_effect.full_name_buf, 0));
    first_name_sig.set("Jane");
    try std.testing.expectEqual(@as(u32, 2), my_effect.run_count);
    try std.testing.expectEqualStrings("Jane Doe", std.mem.sliceTo(my_effect.full_name_buf, 0));
    last_name_sig.set("Smith");
    try std.testing.expectEqual(@as(u32, 3), my_effect.run_count);
    try std.testing.expectEqualStrings("Jane Smith", std.mem.sliceTo(my_effect.full_name_buf, 0));
}

test "signal can be updated from anywhere" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = Scope.init(gpa.allocator());
    defer ss.deinit();

    // Create a signal completely on its own.
    var standalone_signal = try ss.createSignal(.{ .value = "Click me" });
    defer standalone_signal.deinit();

    const ButtonEffect = struct {
        // The effect just holds a pointer to the signal.
        button_text: *Signal([]const u8),
        click_count: u32,

        fn run(self: *@This()) void {
            // This effect just "listens" to the signal.
            _ = self.button_text.get();
            self.click_count += 1;
        }
    };

    var my_button_effect = ButtonEffect{
        .button_text = standalone_signal,
        .click_count = 0,
    };

    var effect = try ss.createEffect(.{ .effect = &my_button_effect });
    defer effect.deinit();

    // The effect ran once on creation.
    try std.testing.expectEqual(1, my_button_effect.click_count);

    // Now, update the original, standalone signal variable.
    //    We are NOT touching the effect object at all.
    standalone_signal.set("Clicked!");

    // The effect still re-ran automatically!
    try std.testing.expectEqual(2, my_button_effect.click_count);
}

test "createMemo computes derived state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ss = Scope.init(gpa.allocator());
    defer ss.deinit();

    var first_name = try ss.createSignal(.{ .value = "John" });
    defer first_name.deinit();

    var last_name = try ss.createSignal(.{ .value = "Doe" });
    defer last_name.deinit();

    const FullNameComputer = struct {
        allocator: std.mem.Allocator,
        first: *Signal([]const u8),
        last: *Signal([]const u8),
        fn run(self: *const @This()) []const u8 {
            const f = self.first.get();
            const l = self.last.get();
            const combined = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ f, l }) catch unreachable;
            return combined;
        }
    };

    const computer = FullNameComputer{
        .allocator = ss.allocator,
        .first = first_name,
        .last = last_name,
    };

    var full_name = try ss.createMemo(.{ .compute = &computer });
    defer full_name.deinit();

    try std.testing.expectEqualStrings("John Doe", full_name.get());

    first_name.set("Jane");

    try std.testing.expectEqualStrings("Jane Doe", full_name.get());
}
