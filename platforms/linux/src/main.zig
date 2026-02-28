const std = @import("std");
const c = @import("gtk_c.zig").c;
const AppState = @import("app_state.zig").AppState;
const ui = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app_state = try AppState.init(allocator);
    defer app_state.deinit();

    const app = c.gtk_application_new("dev.productdevbook.portkiller.linux", c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);

    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&ui.onActivate), &app_state, null, 0);
    _ = c.g_application_run(@ptrCast(app), 0, null);
}
