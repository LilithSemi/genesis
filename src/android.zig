//! Android surface composition for Genesis.
//!
//! Android's window manager owns application task surfaces. Genesis supplies
//! the HOME surface and persistent chrome around those tasks, while the Linux
//! build supplies the same shell with Phantom's Wayland compositor host.
const std = @import("std");
const phantom = @import("phantom");
const platform = @import("platform.zig");
const services = @import("services/services.zig");
const shell = @import("shell.zig");
const FormFactor = @import("shell/form_factor.zig").FormFactor;

var visible_system_bars: std.atomic.Value(u8) = .init(1);
var system_shell_state: std.atomic.Value(u8) = .init(0);

pub fn root(role: i32) phantom.Root {
    return switch (role) {
        1 => phantom.Root.plain(statusRoot),
        2 => phantom.Root.plain(emptyRoot),
        3 => phantom.Root.plain(statusMenuRoot),
        else => phantom.Root.plain(homeRoot),
    };
}

/// Bit zero tells the Android host that the status surface has expanded from
/// its top-edge hit target into a full-display shell overlay.
pub fn systemShellState() i32 {
    return system_shell_state.load(.acquire);
}

pub fn homeActivated(action: i32) void {
    if (action == 1) shell.showLauncher() else shell.goHome();
}

/// Android reports application bar-visibility policy here; Genesis remains
/// the authority that decides which of its own surfaces are visible.
pub fn systemBarsChanged(state: phantom.android.SystemBarsState) phantom.android.SystemBarsVisibility {
    const effective = state.effectiveVisibility();
    const visibility = phantom.android.SystemBarsVisibility{
        .status = effective.status,
        .navigation = effective.navigation,
    };
    visible_system_bars.store(if (visibility.status) 1 else 0, .release);
    return visibility;
}

fn homeRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(shell.Shell{}).widget();
}

fn emptyRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "" }).widget();
}

fn statusRoot(b: *phantom.BuildContext) phantom.Widget {
    const chrome = b.new(StatusChrome{});
    return b.new(services.ServicesHost{ .child = chrome.widget() }).widget();
}

fn statusMenuRoot(b: *phantom.BuildContext) phantom.Widget {
    const menu = b.new(StatusMenu{});
    return b.new(services.ServicesHost{ .child = menu.widget() }).widget();
}

const StatusChrome = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        expanded: bool = false,
        bar: shell.top_bar.TopBar = undefined,
        bar_slot: phantom.Positioned = undefined,

        pub fn initState(_: *@This(), _: *const StatusChrome) anyerror!void {}

        pub fn dispose(s: *@This()) void {
            s.expanded = false;
            system_shell_state.store(0, .release);
        }

        fn setExpanded(s: *@This(), expanded: bool) void {
            if (s.expanded == expanded) return;
            s.expanded = expanded;
            system_shell_state.store(if (expanded) 1 else 0, .release);
            phantom.markNeedsBuild(s);
        }

        fn toggle(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.setExpanded(!s.expanded);
        }

        pub fn build(s: *@This(), _: *phantom.BuildContext) anyerror!phantom.Widget {
            s.bar = .{ .on_status = toggle, .ctx = s };
            s.bar_slot = .{ .top = 0, .left = 0, .right = 0, .child = s.bar.widget() };
            return s.bar_slot.widget();
        }
    };

    pub fn widget(self: *const StatusChrome) phantom.Widget {
        return phantom.StatefulWidget(StatusChrome, self);
    }
};

const StatusMenu = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        control_center: shell.control_center.ControlCenter = undefined,
        control_slot: phantom.Positioned = undefined,
        layers: [1]phantom.Widget = undefined,
        stack: phantom.Stack = undefined,

        pub fn initState(_: *@This(), _: *const StatusMenu) anyerror!void {}

        fn close(_: *anyopaque) void {
            system_shell_state.store(0, .release);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const bar_height = switch (FormFactor.fromWidth(phantom.MediaQuery.of(b).size.width)) {
                .phone => shell.top_bar.TopBar.phone_height,
                .tablet => shell.top_bar.TopBar.tablet_height,
                .desktop => shell.top_bar.TopBar.desktop_height,
            };
            s.control_center = .{ .on_close = close, .ctx = s };
            s.control_slot = .{
                .top = bar_height,
                .left = 0,
                .right = 0,
                .bottom = 0,
                .child = s.control_center.widget(),
            };
            s.layers[0] = s.control_slot.widget();
            s.stack = .{ .children = &s.layers };
            return s.stack.widget();
        }
    };

    pub fn widget(self: *const StatusMenu) phantom.Widget {
        return phantom.StatefulWidget(StatusMenu, self);
    }
};

test "Android surface roles select independent application and shell roots" {
    try std.testing.expect(root(0).build != root(1).build);
    try std.testing.expect(root(1).build != root(2).build);
    try std.testing.expect(root(2).build != root(3).build);
}

test "Android system shell state exposes status overlay expansion" {
    system_shell_state.store(1, .release);
    defer system_shell_state.store(0, .release);
    try std.testing.expectEqual(@as(i32, 1), systemShellState());
}

test "Android status menu is positioned below the phone status bar" {
    var fixtures = platform.fixtures.Fixtures{};
    fixtures.init(std.Io.failing);
    var menu = StatusMenu{};
    var host = services.ServicesHost{ .child = menu.widget(), .services = &fixtures.services };
    var harness = try phantom.testing.mount(std.testing.allocator, host.widget());
    defer harness.deinit();
    try harness.pump();
    try harness.expectHtml("left:0;top:2.25rem;");
    try harness.expectNoFaults();
}

test "Android applications control Genesis system bar visibility" {
    const hidden = systemBarsChanged(.{
        .status_requested_visible = false,
        .navigation_requested_visible = true,
        .status_transient = false,
        .navigation_transient = true,
        .behavior = 0,
    });
    try std.testing.expect(!hidden.status);
    try std.testing.expect(hidden.navigation);

    const transient = systemBarsChanged(.{
        .status_requested_visible = false,
        .navigation_requested_visible = false,
        .status_transient = true,
        .navigation_transient = false,
        .behavior = 0,
    });
    try std.testing.expect(transient.status);
    try std.testing.expect(!transient.navigation);
}
