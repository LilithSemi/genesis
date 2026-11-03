const std = @import("std");
const phantom = @import("phantom");

pub const services = @import("services/services.zig");
pub const platform = @import("platform.zig");
pub const config = @import("config.zig");
pub const shell = @import("shell.zig");
pub const android = @import("android.zig");

/// The entry point `phantom.addApp` calls on both the native and the web
/// target. It builds the tree and nothing else.
pub fn root(b: *phantom.BuildContext) phantom.Widget {
    // b.new copies the config into the build arena. Returning the stack local's
    // widget() would dangle the moment this function returns.
    return b.new(shell.Shell{}).widget();
}

/// Android hosts Genesis in three surfaces: HOME plus persistent status and
/// navigation windows above application tasks. The native entry point selects
/// one of these roots for each Android SurfaceView.
pub fn androidRoot(role: i32) phantom.Root {
    return android.root(role);
}

pub fn androidSystemBarsChanged(state: phantom.android.SystemBarsState) phantom.android.SystemBarsVisibility {
    return android.systemBarsChanged(state);
}

pub fn androidSystemShellState() i32 {
    return android.systemShellState();
}

pub fn androidHomeActivated(action: i32) void {
    android.homeActivated(action);
}

test {
    std.testing.refAllDecls(@This());
    _ = services;
    _ = @import("services/apps.zig");
    _ = @import("services/notifications.zig");
    _ = @import("xdg/desktop_entry.zig");
    _ = @import("xdg/app_index.zig");
    _ = platform;
    _ = shell;
    // refAllDecls does not recurse into a nested namespace, so the top bar's
    // tests only run when this file names the module itself.
    _ = shell.top_bar;
    _ = shell.dock;
    _ = shell.launcher;
    _ = shell.control_center;
    _ = shell.notification_toasts;
    _ = shell.active_apps;
    _ = android;
    // Named by path because the breakpoints are a leaf of the shell namespace,
    // and refAllDecls stops at the module boundary above it.
    _ = @import("shell/form_factor.zig");
    // Same reason. The fixtures are named as well as the shipping backend, so a
    // native run tests the stand-in no build selects.
    _ = platform.system;
    _ = platform.fixtures;
}
