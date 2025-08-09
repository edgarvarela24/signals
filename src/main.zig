const std = @import("std");

const termbox = @import("termbox");
const Termbox = termbox.Termbox;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var t = try Termbox.init(allocator);
    defer t.shutdown() catch {};

    try t.selectInputSettings(.{
        .mode = .Esc,
        .mouse = true,
    });

    var anchor = t.back_buffer.anchor(1, 1);
    try anchor.writer().print("Input testing", .{});

    anchor.move(1, 2);
    try anchor.writer().print("Press q key to quit", .{});

    try t.present();

    main: while (try t.pollEvent()) |ev| {
        switch (ev) {
            .Key => |key_ev| switch (key_ev.ch) {
                'q' => break :main,
                else => {},
            },
            else => {},
        }

        t.clear();
        anchor.move(1, 1);
        switch (ev) {
            .Key => |key_ev| {
                // Check if it's a printable character (like 'a', 'b', '$')
                if (key_ev.ch != 0) {
                    // Use {u} to print the character, and {} to print the number code
                    try anchor.writer().print("Key Press: '{u}' (code: {})", .{ key_ev.ch, key_ev.ch });
                } else {
                    // It's a special key like F1, Arrow Up, Spacebar, etc.
                    try anchor.writer().print("Special Key: {}", .{key_ev.key});
                }
            },
            .Mouse => |mouse_ev| {
                try anchor.writer().print("Mouse: {} at ({}, {})", .{ mouse_ev.action, mouse_ev.x, mouse_ev.y });
            },
            else => |other_ev| {
                // A catch-all for any other event types, like a resize event
                try anchor.writer().print("Other Event: {}", .{other_ev});
            },
        }
        anchor.move(1, 2);
        try anchor.writer().print("Press q key to quit", .{});

        try t.present();
    }
}
