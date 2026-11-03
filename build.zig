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
        .id = "com.lilithsemi.genesis",
        .exec_name = "genesis-shell",
        .name = .{ .default = "Genesis Shell" },
        .summary = .{ .default = "Convergent desktop and mobile shell" },
        .description = .{ .default = "One shell that reflows between a workstation, a tablet and a phone." },
        .categories = &.{.system},
        .root = b.path("src/root.zig"),
        .developer = "Lilith Semiconductor",
        .license = "Apache-2.0",
        .compositor = true,
        .android = .{
            // Stock bars are absent in the AOSP shell product. Do not ask
            // Android to transiently hide the shell provider's own bar windows.
            .system_ui = .edge_to_edge,
            .home_screen = true,
            .system_shell = true,
            .system_shell_navigation_bar = false,
            .permissions = &.{
                .status_bar_service,
                .internal_system_window,
                .network_state,
                .wifi_state,
                .wifi_control,
                .wifi_privileged,
                .nearby_wifi,
                .fine_location,
                .cellular_state,
                .cellular_control,
                .bluetooth,
                .bluetooth_scan,
                .bluetooth_privileged,
                .app_discovery,
                .running_tasks,
                .manage_activity_tasks,
                .read_frame_buffer,
                .audio_settings,
                .control_display_brightness,
                .query_users,
            },
        },
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
