const std = @import("std");
const c = @import("gtk_c.zig").c;

pub const PortInfo = struct {
    port: u16,
    pid: i32,
    process_name: []u8,
};

const ParsedLine = struct {
    port: u16,
    pid: i32,
    process_name: []const u8,
};

pub fn refreshPorts(allocator: std.mem.Allocator, ports: *std.ArrayList(PortInfo)) !void {
    clearPorts(allocator, ports);

    const output = try runCommand(allocator, &.{ "ss", "-ltnpH" });
    defer allocator.free(output);

    var lines = std.mem.tokenizeAny(u8, output, "\r\n");
    while (lines.next()) |line| {
        const parsed = parseSsLine(line) orelse continue;
        try ports.append(allocator, .{
            .port = parsed.port,
            .pid = parsed.pid,
            .process_name = try allocator.dupe(u8, parsed.process_name),
        });
    }

    std.mem.sort(PortInfo, ports.items, {}, struct {
        fn lessThan(_: void, a: PortInfo, b: PortInfo) bool {
            return a.port < b.port;
        }
    }.lessThan);
}

pub fn clearPorts(allocator: std.mem.Allocator, ports: *std.ArrayList(PortInfo)) void {
    for (ports.items) |port| {
        allocator.free(port.process_name);
    }
    ports.clearRetainingCapacity();
}

pub fn deinitPorts(allocator: std.mem.Allocator, ports: *std.ArrayList(PortInfo)) void {
    clearPorts(allocator, ports);
    ports.deinit(allocator);
}

pub fn killProcess(pid: i32) !void {
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
