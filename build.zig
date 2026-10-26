const std = @import("std");
const phantom = @import("phantom");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const phantom_dep = b.dependency("phantom", .{
        .target = target,
        .optimize = optimize,
    });
    const dbus_dep = b.dependency("dbus", .{
        .target = target,
        .optimize = optimize,
    });

    const app = phantom.addApp(b, phantom_dep, .{
        .id = "com.expidusos.genesis",
        .exec_name = "genesis-shell",
        .name = .{ .default = "Genesis Shell" },
        .summary = .{ .default = "Convergent desktop and mobile shell" },
        .description = .{ .default = "One shell that reflows between a workstation, a tablet and a phone." },
        .categories = &.{.system},
        .root = b.path("src/root.zig"),
        .developer = "Midstall",
        .license = "AGPL-3.0-or-later",
        .compositor = true,
        .imports = &.{.{ .name = "dbus", .module = dbus_dep.module("dbus") }},
        .target = target,
        .optimize = optimize,
    });
    b.getInstallStep().dependOn(app);

    // A separate module from the one addApp builds: addApp wraps the root in a
    // generated entry point, and a test binary must not have one.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("phantom", phantom_dep.module("phantom"));
    tests.root_module.addImport("dbus", dbus_dep.module("dbus"));

    const test_step = b.step("test", "Run Genesis unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
