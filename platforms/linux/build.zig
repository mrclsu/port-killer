const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "portkiller-linux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    exe.linkSystemLibrary2("gtk4", .{ .use_pkg_config = .force });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the Linux GTK app");
    run_step.dependOn(&run_cmd.step);

    const check = b.step("check", "Build the Linux GTK app");
    check.dependOn(&exe.step);
}
