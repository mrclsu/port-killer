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
    c.gtk_window_set_title(@ptrCast(window), "PortKiller");
    c.gtk_window_set_default_size(@ptrCast(window), 860, 580);

    const main_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_widget_set_margin_start(main_box, 16);
    c.gtk_widget_set_margin_end(main_box, 16);
    c.gtk_widget_set_margin_top(main_box, 16);
    c.gtk_widget_set_margin_bottom(main_box, 16);
    c.gtk_window_set_child(@ptrCast(window), main_box);

    const header_bar = c.gtk_header_bar_new();
    c.gtk_widget_add_css_class(header_bar, "flat");
    c.gtk_header_bar_set_show_title_buttons(@ptrCast(header_bar), 1);
    c.gtk_window_set_titlebar(@ptrCast(window), header_bar);

    const title_label = c.gtk_label_new("PortKiller");
    c.gtk_widget_add_css_class(title_label, "heading");
    c.gtk_header_bar_pack_start(@ptrCast(header_bar), title_label);

    const search_entry = c.gtk_search_entry_new();
    app.search_entry = search_entry;
    c.gtk_widget_set_hexpand(search_entry, 1);
    c.gtk_editable_set_text(@ptrCast(search_entry), "");
    c.gtk_widget_set_size_request(search_entry, 320, -1);
    c.gtk_header_bar_set_title_widget(@ptrCast(header_bar), search_entry);

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

    const refresh_button = c.gtk_button_new_with_label("Refresh");
    c.gtk_box_append(@ptrCast(overflow_content), refresh_button);

    const refresh_elevated_button = c.gtk_button_new_with_label("Refresh (Elevated)");
    c.gtk_widget_set_tooltip_text(refresh_elevated_button, "Run ss with pkexec to load all visible PIDs");
    c.gtk_box_append(@ptrCast(overflow_content), refresh_elevated_button);

    c.gtk_popover_set_child(@ptrCast(overflow_popover), overflow_content);
    c.gtk_menu_button_set_popover(@ptrCast(overflow_button), overflow_popover);
    c.gtk_header_bar_pack_end(@ptrCast(header_bar), overflow_button);

    const scrolled = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scrolled, 1);
    c.gtk_box_append(@ptrCast(main_box), scrolled);

    const list_box = c.gtk_list_box_new();
    app.list_box = list_box;
    c.gtk_list_box_set_selection_mode(@ptrCast(list_box), c.GTK_SELECTION_NONE);
    c.gtk_scrolled_window_set_child(@ptrCast(scrolled), list_box);

    const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
    c.gtk_box_append(@ptrCast(main_box), footer);

    const status_label = c.gtk_label_new("Scanning...");
    app.status_label = status_label;
    c.gtk_label_set_xalign(@ptrCast(status_label), 0.0);
    c.gtk_widget_set_hexpand(status_label, 1);
    c.gtk_box_append(@ptrCast(footer), status_label);

    const auto_refresh_toggle = c.gtk_check_button_new_with_label("Auto Refresh (5s)");
    app.auto_refresh_toggle = auto_refresh_toggle;
    c.gtk_check_button_set_active(@ptrCast(auto_refresh_toggle), 1);
    c.gtk_widget_set_halign(auto_refresh_toggle, c.GTK_ALIGN_END);
    c.gtk_box_append(@ptrCast(footer), auto_refresh_toggle);

    _ = c.g_signal_connect_data(search_entry, "search-changed", @ptrCast(&onSearchChanged), app, null, 0);
    _ = c.g_signal_connect_data(refresh_button, "clicked", @ptrCast(&onRefreshClicked), app, null, 0);
    _ = c.g_signal_connect_data(refresh_elevated_button, "clicked", @ptrCast(&onRefreshElevatedClicked), app, null, 0);

    _ = c.g_timeout_add_seconds(app.refresh_interval_seconds, @ptrCast(&onAutoRefreshTick), app);

    refreshAndRender(app, .normal);
    c.gtk_window_present(@ptrCast(window));
}

fn refreshAndRender(app: *AppState, mode: port_manager.RefreshMode) void {
    port_manager.refreshPorts(app.allocator, &app.ports, mode) catch {
        if (app.status_label) |status_label| {
            const message = switch (mode) {
                .normal => "Failed to scan ports. Ensure 'ss' is installed.",
                .elevated => "Elevated refresh failed. Authorize the admin prompt and verify pkexec is available.",
            };
            c.gtk_label_set_text(@ptrCast(status_label), message);
        }
        return;
    };

    app.last_refresh_was_elevated = mode == .elevated;
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
        const label_text = if (port.pid >= 0)
            std.fmt.bufPrintZ(&label_buf, "Port {d} • {s} (pid {d})", .{ port.port, port.process_name, port.pid }) catch continue
        else
            std.fmt.bufPrintZ(&label_buf, "Port {d} • {s} (pid unavailable)", .{ port.port, port.process_name }) catch continue;
        const label = c.gtk_label_new(label_text.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0.0);
        c.gtk_widget_set_hexpand(label, 1);

        const source_label: ?*c.GtkWidget = if (app.last_refresh_was_elevated)
            c.gtk_label_new("Elevated")
        else
            null;
        if (source_label) |source| {
            c.gtk_widget_add_css_class(source, "dim-label");
        }

        var button_buf: [64]u8 = undefined;
        const button_text = if (port.pid >= 0)
            std.fmt.bufPrintZ(&button_buf, "Kill {d}", .{port.port}) catch "Kill"
        else
            "No PID";
        const kill_button = c.gtk_button_new_with_label(button_text.ptr);
        if (port.pid < 0) {
            c.gtk_widget_set_sensitive(kill_button, 0);
        }

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
        if (source_label) |source| {
            c.gtk_box_append(@ptrCast(row_box), source);
        }
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
    refreshAndRender(app, .normal);
}

fn onRefreshElevatedClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const app: *AppState = @ptrCast(@alignCast(user_data orelse return));

    if (app.auto_refresh_toggle) |toggle| {
        c.gtk_check_button_set_active(@ptrCast(toggle), 0);
    }

    refreshAndRender(app, .elevated);
}

fn onAutoRefreshTick(user_data: ?*anyopaque) callconv(.c) c_int {
    const app: *AppState = @ptrCast(@alignCast(user_data orelse return 0));
    const toggle = app.auto_refresh_toggle orelse return 1;

    if (c.gtk_check_button_get_active(@ptrCast(toggle)) != 0) {
        refreshAndRender(app, .normal);
    }

    return 1;
}

fn onKillClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const kill_data: *KillActionData = @ptrCast(@alignCast(user_data orelse return));

    port_manager.killProcess(kill_data.app.allocator, kill_data.pid) catch {
        if (kill_data.app.status_label) |status_label| {
            c.gtk_label_set_text(@ptrCast(status_label), "Failed to kill process. Authorize the admin prompt if shown.");
        }
        return;
    };

    refreshAndRender(kill_data.app, .normal);
}

fn destroyKillActionData(data: ?*anyopaque, _: ?*c.GClosure) callconv(.c) void {
    const kill_data: *KillActionData = @ptrCast(@alignCast(data orelse return));
    kill_data.app.allocator.destroy(kill_data);
}
