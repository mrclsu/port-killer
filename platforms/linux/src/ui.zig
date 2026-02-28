const std = @import("std");
const c = @import("gtk_c.zig").c;
const AppState = @import("app_state.zig").AppState;
const port_manager = @import("port_manager.zig");

const KillActionData = struct {
    app: *AppState,
    pid: i32,
};

pub fn onActivate(application: ?*c.GtkApplication, user_data: ?*anyopaque) callconv(.c) void {
    const app: *AppState = @ptrCast(@alignCast(user_data orelse return));

    const window = c.gtk_application_window_new(application);
    app.window = window;
    c.gtk_window_set_title(@ptrCast(window), "PortKiller (Linux)");
    c.gtk_window_set_default_size(@ptrCast(window), 860, 580);

    const main_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_widget_set_margin_start(main_box, 16);
    c.gtk_widget_set_margin_end(main_box, 16);
    c.gtk_widget_set_margin_top(main_box, 16);
    c.gtk_widget_set_margin_bottom(main_box, 16);
    c.gtk_window_set_child(@ptrCast(window), main_box);

    const toolbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_box_append(@ptrCast(main_box), toolbar);

    const search_entry = c.gtk_search_entry_new();
    app.search_entry = search_entry;
    c.gtk_widget_set_hexpand(search_entry, 1);
    c.gtk_editable_set_text(@ptrCast(search_entry), "");
    c.gtk_box_append(@ptrCast(toolbar), search_entry);

    const refresh_button = c.gtk_button_new_with_label("Refresh");
    c.gtk_box_append(@ptrCast(toolbar), refresh_button);

    const overflow_button = c.gtk_menu_button_new();
    c.gtk_widget_set_tooltip_text(overflow_button, "More options");

    const overflow_icon = c.gtk_image_new_from_icon_name("open-menu-symbolic");
    c.gtk_menu_button_set_child(@ptrCast(overflow_button), overflow_icon);

    const overflow_popover = c.gtk_popover_new();
    const overflow_content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_set_margin_start(overflow_content, 12);
    c.gtk_widget_set_margin_end(overflow_content, 12);
    c.gtk_widget_set_margin_top(overflow_content, 12);
    c.gtk_widget_set_margin_bottom(overflow_content, 12);

    const auto_refresh_toggle = c.gtk_check_button_new_with_label("Auto Refresh (5s)");
    app.auto_refresh_toggle = auto_refresh_toggle;
    c.gtk_check_button_set_active(@ptrCast(auto_refresh_toggle), 1);
    c.gtk_box_append(@ptrCast(overflow_content), auto_refresh_toggle);

    c.gtk_popover_set_child(@ptrCast(overflow_popover), overflow_content);
    c.gtk_menu_button_set_popover(@ptrCast(overflow_button), overflow_popover);
    c.gtk_box_append(@ptrCast(toolbar), overflow_button);

    const scrolled = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scrolled, 1);
    c.gtk_box_append(@ptrCast(main_box), scrolled);

    const list_box = c.gtk_list_box_new();
    app.list_box = list_box;
    c.gtk_scrolled_window_set_child(@ptrCast(scrolled), list_box);

    const status_label = c.gtk_label_new("Scanning...");
    app.status_label = status_label;
    c.gtk_label_set_xalign(@ptrCast(status_label), 0.0);
    c.gtk_box_append(@ptrCast(main_box), status_label);

    _ = c.g_signal_connect_data(search_entry, "search-changed", @ptrCast(&onSearchChanged), app, null, 0);
    _ = c.g_signal_connect_data(refresh_button, "clicked", @ptrCast(&onRefreshClicked), app, null, 0);

    _ = c.g_timeout_add_seconds(app.refresh_interval_seconds, @ptrCast(&onAutoRefreshTick), app);

    refreshAndRender(app);
    c.gtk_window_present(@ptrCast(window));
}

fn refreshAndRender(app: *AppState) void {
    port_manager.refreshPorts(app.allocator, &app.ports) catch {
        if (app.status_label) |status_label| {
            c.gtk_label_set_text(@ptrCast(status_label), "Failed to scan ports. Ensure 'ss' is installed.");
        }
        return;
    };
    renderList(app);
}

fn renderList(app: *AppState) void {
    const list_box = app.list_box orelse return;

    var child = c.gtk_widget_get_first_child(list_box);
    while (child != null) {
        const next = c.gtk_widget_get_next_sibling(child);
        c.gtk_list_box_remove(@ptrCast(list_box), child);
        child = next;
    }

    var visible_count: usize = 0;

    for (app.ports.items) |port| {
        if (!app.matchesSearch(port)) continue;
        visible_count += 1;

        const row = c.gtk_list_box_row_new();
        const row_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
        c.gtk_widget_set_margin_start(row_box, 8);
        c.gtk_widget_set_margin_end(row_box, 8);
        c.gtk_widget_set_margin_top(row_box, 6);
        c.gtk_widget_set_margin_bottom(row_box, 6);

        var label_buf: [256]u8 = undefined;
        const label_text = std.fmt.bufPrintZ(&label_buf, "Port {d} • {s} (pid {d})", .{ port.port, port.process_name, port.pid }) catch continue;
        const label = c.gtk_label_new(label_text.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0.0);
        c.gtk_widget_set_hexpand(label, 1);

        var button_buf: [64]u8 = undefined;
        const button_text = std.fmt.bufPrintZ(&button_buf, "Kill {d}", .{port.port}) catch "Kill";
        const kill_button = c.gtk_button_new_with_label(button_text.ptr);

        const kill_data = app.allocator.create(KillActionData) catch continue;
        kill_data.* = .{ .app = app, .pid = port.pid };

        _ = c.g_signal_connect_data(
            kill_button,
            "clicked",
            @ptrCast(&onKillClicked),
            kill_data,
            @ptrCast(&destroyKillActionData),
            0,
        );

        c.gtk_box_append(@ptrCast(row_box), label);
        c.gtk_box_append(@ptrCast(row_box), kill_button);
        c.gtk_list_box_row_set_child(@ptrCast(row), row_box);
        c.gtk_list_box_append(@ptrCast(list_box), row);
    }

    if (app.status_label) |status_label| {
        var status_buf: [128]u8 = undefined;
        const total = app.ports.items.len;
        const status_text = std.fmt.bufPrintZ(
            &status_buf,
            "Showing {d} of {d} listening ports",
            .{ visible_count, total },
        ) catch "Ready";
        c.gtk_label_set_text(@ptrCast(status_label), status_text.ptr);
    }
}

fn onSearchChanged(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const app: *AppState = @ptrCast(@alignCast(user_data orelse return));
    const search_entry = app.search_entry orelse return;
    const text = c.gtk_editable_get_text(@ptrCast(search_entry));
    const text_slice = std.mem.span(text);

    app.setSearchQuery(text_slice) catch return;
    renderList(app);
}

fn onRefreshClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const app: *AppState = @ptrCast(@alignCast(user_data orelse return));
    refreshAndRender(app);
}

fn onAutoRefreshTick(user_data: ?*anyopaque) callconv(.c) c_int {
    const app: *AppState = @ptrCast(@alignCast(user_data orelse return 0));
    const toggle = app.auto_refresh_toggle orelse return 1;

    if (c.gtk_check_button_get_active(@ptrCast(toggle)) != 0) {
        refreshAndRender(app);
    }

    return 1;
}

fn onKillClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const kill_data: *KillActionData = @ptrCast(@alignCast(user_data orelse return));

    port_manager.killProcess(kill_data.pid) catch {
        if (kill_data.app.status_label) |status_label| {
            c.gtk_label_set_text(@ptrCast(status_label), "Failed to kill process. Try running with elevated privileges.");
        }
        return;
    };

    refreshAndRender(kill_data.app);
}

fn destroyKillActionData(data: ?*anyopaque, _: ?*c.GClosure) callconv(.c) void {
    const kill_data: *KillActionData = @ptrCast(@alignCast(data orelse return));
    kill_data.app.allocator.destroy(kill_data);
}
