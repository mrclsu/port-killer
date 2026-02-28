const std = @import("std");
const c = @import("gtk_c.zig").c;
const port_manager = @import("port_manager.zig");

pub const AppState = struct {
    allocator: std.mem.Allocator,
    window: ?*c.GtkWidget = null,
    search_entry: ?*c.GtkWidget = null,
    status_label: ?*c.GtkWidget = null,
    list_box: ?*c.GtkWidget = null,
    auto_refresh_toggle: ?*c.GtkWidget = null,
    ports: std.ArrayList(port_manager.PortInfo),
    search_query: []u8,
    refresh_interval_seconds: u32 = 5,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        return .{
            .allocator = allocator,
            .ports = .empty,
            .search_query = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *AppState) void {
        port_manager.deinitPorts(self.allocator, &self.ports);
        self.allocator.free(self.search_query);
    }

    pub fn setSearchQuery(self: *AppState, query: []const u8) !void {
        self.allocator.free(self.search_query);
        self.search_query = try self.allocator.dupe(u8, query);
    }

    pub fn matchesSearch(self: *const AppState, port: port_manager.PortInfo) bool {
        if (self.search_query.len == 0) return true;

        var port_buf: [16]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{port.port}) catch return true;
        if (containsIgnoreCase(port_text, self.search_query)) return true;
        if (containsIgnoreCase(port.process_name, self.search_query)) return true;
        return false;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
