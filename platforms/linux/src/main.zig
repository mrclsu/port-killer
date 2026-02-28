const std = @import("std");

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("signal.h");
});

const PortInfo = struct {
    port: u16,
    pid: i32,
    process_name: []u8,
};

const KillActionData = struct {
    app: *AppState,
    pid: i32,
};

const AppState = struct {
    allocator: std.mem.Allocator,
    window: ?*c.GtkWidget = null,
    search_entry: ?*c.GtkWidget = null,
    status_label: ?*c.GtkWidget = null,
    list_box: ?*c.GtkWidget = null,
    auto_refresh_toggle: ?*c.GtkWidget = null,
    ports: std.ArrayList(PortInfo),
    search_query: []u8,
    refresh_interval_seconds: u32 = 5,

    fn init(allocator: std.mem.Allocator) !AppState {
        return .{
            .allocator = allocator,
            .ports = .empty,
            .search_query = try allocator.dupe(u8, ""),
        };
    }

    fn deinit(self: *AppState) void {
        for (self.ports.items) |port| {
            self.allocator.free(port.process_name);
        }
        self.ports.deinit(self.allocator);
        self.allocator.free(self.search_query);
    }

    fn scanPorts(self: *AppState) !void {
        for (self.ports.items) |port| {
            self.allocator.free(port.process_name);
        }
        self.ports.clearRetainingCapacity();

        const output = try runCommand(self.allocator, &.{ "ss", "-ltnpH" });
        defer self.allocator.free(output);

        var lines = std.mem.tokenizeAny(u8, output, "\r\n");
        while (lines.next()) |line| {
            const parsed = parseSsLine(line) orelse continue;
            try self.ports.append(self.allocator, .{
                .port = parsed.port,
                .pid = parsed.pid,
                .process_name = try self.allocator.dupe(u8, parsed.process_name),
            });
        }

        std.mem.sort(PortInfo, self.ports.items, {}, struct {
            fn lessThan(_: void, a: PortInfo, b: PortInfo) bool {
                return a.port < b.port;
            }
        }.lessThan);
    }

    fn matchesSearch(self: *const AppState, port: PortInfo) bool {
        if (self.search_query.len == 0) return true;

        var port_buf: [16]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{port.port}) catch return true;
        if (containsIgnoreCase(port_text, self.search_query)) return true;
        if (containsIgnoreCase(port.process_name, self.search_query)) return true;
        return false;
    }

    fn renderList(self: *AppState) void {
        const list_box = self.list_box orelse return;

        var child = c.gtk_widget_get_first_child(list_box);
        while (child != null) {
            const next = c.gtk_widget_get_next_sibling(child);
            c.gtk_list_box_remove(@ptrCast(list_box), child);
            child = next;
        }

        var visible_count: usize = 0;

        for (self.ports.items) |port| {
            if (!self.matchesSearch(port)) continue;
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

            const kill_data = self.allocator.create(KillActionData) catch continue;
            kill_data.* = .{ .app = self, .pid = port.pid };

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

        if (self.status_label) |status_label| {
            var status_buf: [128]u8 = undefined;
            const total = self.ports.items.len;
            const status_text = std.fmt.bufPrintZ(
                &status_buf,
                "Showing {d} of {d} listening ports",
                .{ visible_count, total },
            ) catch "Ready";
            c.gtk_label_set_text(@ptrCast(status_label), status_text.ptr);
        }
    }
};

const ParsedLine = struct {
    port: u16,
    pid: i32,
    process_name: []const u8,
};

fn parseSsLine(line: []const u8) ?ParsedLine {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    var token_index: usize = 0;
    var local_address: ?[]const u8 = null;
    var process_field: ?[]const u8 = null;

    while (parts.next()) |token| {
        if (token.len == 0) continue;
        token_index += 1;
        if (token_index == 4) {
            local_address = token;
        } else if (token_index == 6) {
            process_field = token;
            break;
        }
    }

    const address = local_address orelse return null;
    const port = parsePort(address) orelse return null;

    const process_text = process_field orelse return null;
    const pid = extractNumberAfter(process_text, "pid=") orelse return null;
    const process_name = extractProcessName(process_text) orelse "unknown";

    return .{ .port = port, .pid = pid, .process_name = process_name };
}

fn parsePort(address: []const u8) ?u16 {
    const colon_index = std.mem.lastIndexOfScalar(u8, address, ':') orelse return null;
    const port_text = address[colon_index + 1 ..];
    return std.fmt.parseInt(u16, port_text, 10) catch null;
}

fn extractNumberAfter(text: []const u8, needle: []const u8) ?i32 {
    const start = std.mem.indexOf(u8, text, needle) orelse return null;
    const number_start = start + needle.len;
    var i = number_start;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i == number_start) return null;
    return std.fmt.parseInt(i32, text[number_start..i], 10) catch null;
}

fn extractProcessName(text: []const u8) ?[]const u8 {
    const quote_start = std.mem.indexOfScalar(u8, text, '"') orelse return null;
    const rest = text[quote_start + 1 ..];
    const quote_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..quote_end];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1_000_000);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 65_536);
    defer allocator.free(stderr);

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }

    return stdout;
}

fn refreshAndRender(app: *AppState) void {
    app.scanPorts() catch {
        if (app.status_label) |status_label| {
            c.gtk_label_set_text(@ptrCast(status_label), "Failed to scan ports. Ensure 'ss' is installed.");
        }
        return;
    };
    app.renderList();
}

fn killProcess(pid: i32) !void {
    if (c.kill(pid, c.SIGTERM) != 0) {
        return error.TerminationFailed;
    }

    std.Thread.sleep(400 * std.time.ns_per_ms);

    if (c.kill(pid, 0) == 0) {
        if (c.kill(pid, c.SIGKILL) != 0) {
            return error.ForceKillFailed;
        }
    }
}

fn onActivate(application: ?*c.GtkApplication, user_data: ?*anyopaque) callconv(.c) void {
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

    const auto_refresh_toggle = c.gtk_check_button_new_with_label("Auto Refresh (5s)");
    app.auto_refresh_toggle = auto_refresh_toggle;
    c.gtk_check_button_set_active(@ptrCast(auto_refresh_toggle), 1);
    c.gtk_box_append(@ptrCast(toolbar), auto_refresh_toggle);

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

fn onSearchChanged(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const app: *AppState = @ptrCast(@alignCast(user_data orelse return));
    const search_entry = app.search_entry orelse return;
    const text = c.gtk_editable_get_text(@ptrCast(search_entry));
    const text_slice = std.mem.span(text);

    app.allocator.free(app.search_query);
    app.search_query = app.allocator.dupe(u8, text_slice) catch return;

    app.renderList();
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

    killProcess(kill_data.pid) catch {
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app_state = try AppState.init(allocator);
    defer app_state.deinit();

    const app = c.gtk_application_new("dev.productdevbook.portkiller.linux", c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);

    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&onActivate), &app_state, null, 0);
    _ = c.g_application_run(@ptrCast(app), 0, null);
}
