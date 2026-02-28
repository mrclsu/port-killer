const std = @import("std");
const c = @import("gtk_c.zig").c;

pub const PortInfo = struct {
    port: u16,
    pid: i32,
    process_name: []u8,
};

pub const RefreshMode = enum {
    normal,
    elevated,
};

const ParsedLine = struct {
    port: u16,
    pid: i32,
    process_name: []const u8,
};

pub fn refreshPorts(allocator: std.mem.Allocator, ports: *std.ArrayList(PortInfo), mode: RefreshMode) !void {
    clearPorts(allocator, ports);

    const output = try loadSsOutput(allocator, mode);
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

fn loadSsOutput(allocator: std.mem.Allocator, mode: RefreshMode) ![]u8 {
    return switch (mode) {
        .normal => runCommand(allocator, &.{ "ss", "-ltnpH" }),
        .elevated => runElevatedSs(allocator),
    };
}

fn runElevatedSs(allocator: std.mem.Allocator) ![]u8 {
    return runCommand(allocator, &.{ "pkexec", "/usr/bin/ss", "-ltnpH" }) catch |err| switch (err) {
        error.FileNotFound => error.ElevationUnavailable,
        error.CommandFailed => runCommand(allocator, &.{ "pkexec", "/bin/ss", "-ltnpH" }) catch |fallback_err| switch (fallback_err) {
            error.FileNotFound => error.ElevationUnavailable,
            else => fallback_err,
        },
        else => err,
    };
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

pub fn killProcess(allocator: std.mem.Allocator, pid: i32) !void {
    if (c.kill(pid, c.SIGTERM) != 0) {
        try killProcessWithElevation(allocator, pid, c.SIGTERM);
    }

    std.Thread.sleep(400 * std.time.ns_per_ms);

    if (c.kill(pid, 0) == 0) {
        if (c.kill(pid, c.SIGKILL) != 0) {
            try killProcessWithElevation(allocator, pid, c.SIGKILL);
        }
    }
}

fn killProcessWithElevation(allocator: std.mem.Allocator, pid: i32, signal: c_int) !void {
    const signal_arg = switch (signal) {
        c.SIGTERM => "-TERM",
        c.SIGKILL => "-KILL",
        else => return error.UnsupportedSignal,
    };

    var pid_buf: [16]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});

    runCommandNoOutput(allocator, &.{ "pkexec", "/usr/bin/kill", signal_arg, pid_text }) catch |err| switch (err) {
        error.FileNotFound => return error.ElevationUnavailable,
        error.CommandFailed => {
            try runCommandNoOutput(allocator, &.{ "pkexec", "/bin/kill", signal_arg, pid_text });
        },
        else => return err,
    };
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

    const process_text = process_field orelse "";
    const pid = extractNumberAfter(process_text, "pid=") orelse -1;
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

fn runCommandNoOutput(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return error.CommandFailed;
    }
}
