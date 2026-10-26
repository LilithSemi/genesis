const std = @import("std");
const phantom = @import("phantom");
const platform = @import("platform.zig");
const services = @import("services/services.zig");
const FormFactor = @import("shell/form_factor.zig").FormFactor;

pub const top_bar = @import("shell/top_bar.zig");
pub const dock = @import("shell/dock.zig");
pub const launcher = @import("shell/launcher.zig");
pub const control_center = @import("shell/control_center.zig");
pub const notification_toasts = @import("shell/notification_toasts.zig");
pub const calendar = @import("shell/calendar.zig");
pub const workspaces = @import("shell/workspaces.zig");

const wallpaper_bytes = @embedFile("assets/wallpaper/desktop/default-sm.jpg");

/// The root of every Genesis surface. Reads its colors from the nearest
/// `phantom.Theme`, so a theme variant restyles the whole shell without a
/// change here.
pub const Shell = struct {
    /// Passed straight to the `ServicesHost`. Null in the shipped shell, where
    /// the host builds the platform for this target. A widget test sets it so
    /// the tree mounts with fixtures swapped in.
    services: ?*services.Services = null,

    pub const State = struct {
        base: phantom.StateBase = .{},
        /// Copied in `initState`, because `build` never sees the config.
        services: ?*services.Services = null,
        launcher_visible: bool = false,
        control_center_visible: bool = false,
        calendar_visible: bool = false,
        overview_visible: bool = false,

        // Every config below is a field, not a `b.new` arena copy: the
        // ServicesHost keeps its child widget across a rebuild it schedules on
        // its own, and the build arena is reset each frame.
        wallpaper: phantom.Image = undefined,
        bar: top_bar.TopBar = undefined,
        bar_slot: phantom.Positioned = undefined,
        clients: phantom.CompositorView = undefined,
        clients_slot: phantom.Positioned = undefined,
        dock_view: dock.Dock = undefined,
        dock_slot: phantom.Positioned = undefined,
        launcher_view: launcher.Launcher = undefined,
        launcher_slot: phantom.Positioned = undefined,
        control_center_view: control_center.ControlCenter = undefined,
        control_center_slot: phantom.Positioned = undefined,
        calendar_view: calendar.CalendarPanel = undefined,
        calendar_slot: phantom.Positioned = undefined,
        workspace_view: workspaces.WorkspaceSwitcher = undefined,
        workspace_align: phantom.Align = undefined,
        workspace_slot: phantom.Positioned = undefined,
        toast_view: notification_toasts.NotificationToasts = .{},
        toast_slot: phantom.Positioned = undefined,
        layers: [8]phantom.Widget = undefined,
        stack: phantom.Stack = undefined,
        host: services.ServicesHost = undefined,

        pub fn initState(s: *@This(), config: *const Shell) anyerror!void {
            s.services = config.services;
        }

        pub fn didUpdateWidget(s: *@This(), config: *const Shell) anyerror!void {
            s.services = config.services;
        }

        fn toggleLauncher(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.launcher_visible = !s.launcher_visible;
            if (s.launcher_visible) s.control_center_visible = false;
            if (s.launcher_visible) s.calendar_visible = false;
            if (s.launcher_visible and s.overview_visible) {
                s.overview_visible = false;
                if (phantom.compositor.fromOwner(s.base.element.owner)) |host| host.setOverview(false);
            }
            phantom.markNeedsBuild(s);
        }

        fn toggleControlCenter(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.control_center_visible = !s.control_center_visible;
            if (s.control_center_visible) s.launcher_visible = false;
            if (s.control_center_visible) s.calendar_visible = false;
            if (s.control_center_visible and s.overview_visible) {
                s.overview_visible = false;
                if (phantom.compositor.fromOwner(s.base.element.owner)) |host| host.setOverview(false);
            }
            phantom.markNeedsBuild(s);
        }

        fn toggleCalendar(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.calendar_visible = !s.calendar_visible;
            if (s.calendar_visible) {
                s.launcher_visible = false;
                s.control_center_visible = false;
                if (s.overview_visible) {
                    s.overview_visible = false;
                    if (phantom.compositor.fromOwner(s.base.element.owner)) |host| host.setOverview(false);
                }
            }
            phantom.markNeedsBuild(s);
        }

        fn closeCalendar(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (!s.calendar_visible) return;
            s.calendar_visible = false;
            phantom.markNeedsBuild(s);
        }

        fn toggleOverview(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.overview_visible = !s.overview_visible;
            if (phantom.compositor.fromOwner(s.base.element.owner)) |host| host.setOverview(s.overview_visible);
            phantom.markNeedsBuild(s);
        }

        fn selectWorkspace(ctx: *anyopaque, index: u8) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (phantom.compositor.fromOwner(s.base.element.owner)) |host| host.setWorkspace(index);
            phantom.markNeedsBuild(s);
        }

        fn minimizeFocused(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (phantom.compositor.fromOwner(s.base.element.owner)) |host| host.minimizeFocused();
            phantom.markNeedsBuild(s);
        }

        fn closeLauncher(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (!s.launcher_visible) return;
            s.launcher_visible = false;
            phantom.markNeedsBuild(s);
        }

        fn closeControlCenter(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (!s.control_center_visible) return;
            s.control_center_visible = false;
            phantom.markNeedsBuild(s);
        }

        // anyerror matches phantom's StateVTable.build signature. It is a shim,
        // not a library error surface.
        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const metrics = phantom.MediaQuery.of(b);
            if (phantom.compositor.fromOwner(b.owner)) |host| s.overview_visible = host.isOverview();

            s.wallpaper = .{
                .bytes = wallpaper_bytes,
                .width = metrics.size.width,
                .height = metrics.size.height,
            };
            // The bar sets its own height, so this slot only pins it to the top
            // edge and stretches it across the full width.
            s.bar = .{ .on_status = toggleControlCenter, .on_clock = toggleCalendar, .ctx = s };
            s.bar_slot = .{ .top = 0, .left = 0, .right = 0, .child = s.bar.widget() };

            const bar_height = switch (FormFactor.fromWidth(metrics.size.width)) {
                .phone => top_bar.TopBar.phone_height,
                .tablet => top_bar.TopBar.tablet_height,
                .desktop => top_bar.TopBar.desktop_height,
            };
            s.clients = .{ .input_enabled = !s.launcher_visible and !s.control_center_visible and !s.calendar_visible };
            s.clients_slot = .{
                .top = bar_height,
                .left = 0,
                .right = 0,
                .bottom = 0,
                .child = s.clients.widget(),
            };

            s.dock_view = .{ .on_launcher = toggleLauncher, .on_overview = toggleOverview, .ctx = s };
            s.dock_slot = .{
                .left = 0,
                .right = 0,
                .bottom = 16,
                .child = s.dock_view.widget(),
            };

            // The wallpaper is first, so it sizes the stack and every later
            // layer is laid out inside it.
            s.layers[0] = s.wallpaper.widget();
            s.layers[1] = s.clients_slot.widget();
            var layer_count: usize = 2;
            s.toast_slot = .{ .top = bar_height, .left = 0, .right = 0, .bottom = 0, .child = s.toast_view.widget() };
            s.layers[layer_count] = s.toast_slot.widget();
            layer_count += 1;
            if (s.launcher_visible) {
                s.launcher_view = .{ .on_close = closeLauncher, .ctx = s };
                s.launcher_slot = .{
                    .top = bar_height,
                    .left = 0,
                    .right = 0,
                    .bottom = 0,
                    .child = s.launcher_view.widget(),
                };
                s.layers[layer_count] = s.launcher_slot.widget();
                layer_count += 1;
            } else if (s.control_center_visible) {
                s.control_center_view = .{ .on_close = closeControlCenter, .ctx = s };
                s.control_center_slot = .{
                    .top = bar_height,
                    .left = 0,
                    .right = 0,
                    .bottom = 0,
                    .child = s.control_center_view.widget(),
                };
                s.layers[layer_count] = s.control_center_slot.widget();
                layer_count += 1;
            } else if (s.calendar_visible) {
                s.calendar_view = .{ .on_close = closeCalendar, .ctx = s };
                s.calendar_slot = .{ .top = bar_height, .left = 0, .right = 0, .bottom = 0, .child = s.calendar_view.widget() };
                s.layers[layer_count] = s.calendar_slot.widget();
                layer_count += 1;
            }
            if (s.overview_visible) {
                const active = if (phantom.compositor.fromOwner(b.owner)) |host| host.activeWorkspace() else 0;
                s.workspace_view = .{ .active = active, .on_select = selectWorkspace, .on_minimize = minimizeFocused, .ctx = s };
                s.workspace_align = .{ .alignment = .top_center, .child = s.workspace_view.widget() };
                s.workspace_slot = .{ .top = 12, .left = 0, .right = 0, .child = s.workspace_align.widget() };
                s.layers[layer_count] = s.workspace_slot.widget();
                layer_count += 1;
            }
            s.layers[layer_count] = s.dock_slot.widget();
            layer_count += 1;
            s.layers[layer_count] = s.bar_slot.widget();
            layer_count += 1;
            s.stack = .{ .children = s.layers[0..layer_count] };
            s.host = .{ .child = s.stack.widget(), .services = s.services };
            return s.host.widget();
        }
    };

    pub fn widget(self: *const Shell) phantom.Widget {
        return phantom.StatefulWidget(Shell, self);
    }
};

test "the shell root reports exactly the size a tight constraint gives it" {
    // The binding layout rule at the root of the tree: whatever the shell
    // stacks inside itself, the size it hands back is the one it was given.
    // A layer that reported its own size instead would resize the window.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var s = Shell{};
    const el = try s.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    const size = el.renderObject().?.layout(
        phantom.BoxConstraints.tight(.{ .width = 1280, .height = 800 }),
    );
    try std.testing.expectEqual(@as(f32, 1280), size.width);
    try std.testing.expectEqual(@as(f32, 800), size.height);
    try std.testing.expect(sink.ok());
}

test "the shell paints the wallpaper across the full viewport" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var s = Shell{};
    const el = try s.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    const ro = el.renderObject().?;
    _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 1280, .height = 800 }));

    var canvas = phantom.Canvas.init(std.testing.allocator);
    canvas.sink = &sink;
    defer canvas.deinit();
    try ro.paint(&canvas, phantom.PhysicalOffset.zero);

    // The image primitive specifically, not "the list is non-empty": the bar's
    // own rrect keeps the list non-empty with the wallpaper deleted from
    // `s.layers`, so a count assertion cannot tell a shell with a wallpaper
    // from one without.
    var wallpaper: ?phantom.PhysicalRect = null;
    for (canvas.list.primitives.items) |p| switch (p) {
        .image => |img| wallpaper = img.rect,
        .rrect, .text, .icon, .texture, .push_scroll, .pop_scroll, .push_clip, .pop_clip => {},
    };

    const rect = wallpaper orelse return error.NoWallpaperPainted;
    try std.testing.expectEqual(@as(f32, 0), rect.x);
    try std.testing.expectEqual(@as(f32, 0), rect.y);
    try std.testing.expectEqual(@as(f32, 1280), rect.width);
    try std.testing.expectEqual(@as(f32, 800), rect.height);
    try std.testing.expect(sink.ok());
}

test "the shell puts a bar with a running clock across the top edge" {
    // Pins the wiring, not the bar: the placeholder used to fill this slot with
    // a plain box, which paints the same strip but shows no time. The fixtures
    // are injected, so the assertion below holds on every target rather than
    // only on the one whose platform happens to freeze its clock.
    var fx = platform.fixtures.Fixtures{};
    fx.init(std.Io.failing);

    var s = Shell{ .services = &fx.services };
    var t = try phantom.testing.mount(std.testing.allocator, s.widget());
    defer t.deinit();
    try t.pump();

    // No MediaQuery ancestor, so MediaQuery.of reports the zero size and the
    // bar builds in the phone form factor: 36 is the phone height, and the
    // 800 is the harness viewport the strip is stretched across.
    try t.expectHtml("left:0;top:0;width:50rem;height:2.25rem");
    // The fixture clock is frozen at 2026-01-01T00:04:00Z.
    try t.expectHtml(">00:04<");
    try t.expectNoFaults();
}

test "the embedded wallpaper is a JPEG the decoder recognises" {
    // Pins the asset, not the widget. A truncated or re-encoded file that the
    // decoder rejects would otherwise only show up as a blank shell at runtime.
    try std.testing.expectEqual(
        phantom.image.Format.jpeg,
        phantom.image.detectFormat(wallpaper_bytes),
    );
}
