const phantom = @import("phantom");
const FormFactor = @import("form_factor.zig").FormFactor;
const services = @import("../services/services.zig");
const Apps = @import("../services/apps.zig").Apps;
const AppEntry = @import("../services/apps.zig").Entry;
const shell_config = @import("../config.zig");

fn alpha(color: phantom.Color, value: f32) phantom.Color {
    var result = color;
    result.a = value;
    return result;
}

const max_pinned = 7;

fn appColor(theme: *const phantom.ThemeData, index: usize) phantom.Color {
    return switch (index % max_pinned) {
        0 => theme.colors.blue,
        1 => theme.colors.green,
        2 => theme.colors.blue_light,
        3 => theme.colors.purple,
        4 => theme.colors.purple_dark,
        5 => theme.colors.orange,
        else => theme.colors.red,
    };
}

fn appGlyph(name: []const u8) []const u8 {
    if (name.len == 0 or !@import("std").ascii.isPrint(name[0]) or !@import("std").ascii.isAlphabetic(name[0])) return "?";
    return name[0..1];
}

fn containsEntry(entries: []const *const AppEntry, candidate: *const AppEntry) bool {
    for (entries) |entry| if (entry == candidate) return true;
    return false;
}

fn pinnedEntries(catalog: []const AppEntry, out: *[max_pinned]*const AppEntry) usize {
    var count: usize = 0;
    for (shell_config.pinned_apps) |id| {
        for (catalog) |*entry| {
            if (!@import("std").ascii.eqlIgnoreCase(entry.id, id)) continue;
            out[count] = entry;
            count += 1;
            break;
        }
        if (count == out.len) return count;
    }
    for (catalog) |*entry| {
        if (containsEntry(out[0..count], entry)) continue;
        out[count] = entry;
        count += 1;
        if (count == out.len) break;
    }
    return count;
}

/// One square in the dock. It deliberately knows nothing about launching an
/// application; the shell supplies the callback, which keeps policy outside a
/// reusable piece of UI.
const DockTile = struct {
    pub const Mark = union(enum) {
        text: []const u8,
        icon: phantom.icon.builtin.Id,
        image: []const u8,
    };

    mark: Mark,
    label: []const u8,
    color: phantom.Color,
    running: bool = false,
    size: f32,
    on_tap: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub const State = struct {
        base: phantom.StateBase = .{},
        mark: Mark = .{ .text = "" },
        label: []const u8 = "",
        color: phantom.Color = .{},
        running: bool = false,
        size: f32 = 44,
        on_tap: ?*const fn (*anyopaque) void = null,
        ctx: *anyopaque = undefined,

        background: phantom.ColoredBox = undefined,
        text: phantom.Text = undefined,
        icon: phantom.Icon = undefined,
        image: phantom.Image = undefined,
        mark_align: phantom.Align = undefined,
        dot: phantom.ColoredBox = undefined,
        dot_size: phantom.SizedBox = undefined,
        dot_align: phantom.Align = undefined,
        layers: [3]phantom.Widget = undefined,
        stack: phantom.Stack = undefined,
        size_box: phantom.SizedBox = undefined,
        tap: phantom.GestureDetector = undefined,

        fn take(s: *@This(), config: *const DockTile) void {
            s.mark = config.mark;
            s.label = config.label;
            s.color = config.color;
            s.running = config.running;
            s.size = config.size;
            s.on_tap = config.on_tap;
            s.ctx = config.ctx;
        }

        pub fn initState(s: *@This(), config: *const DockTile) anyerror!void {
            s.take(config);
        }

        pub fn didUpdateWidget(s: *@This(), config: *const DockTile) anyerror!void {
            s.take(config);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            s.background = .{ .color = s.color, .radius = theme.radius * 0.62 };
            s.layers[0] = s.background.widget();

            const mark_widget = switch (s.mark) {
                .text => |value| blk: {
                    s.text = .{
                        .text = value,
                        .size = s.size * 0.42,
                        .color = theme.colors.bg_dark,
                        .font = theme.body_bold_font,
                    };
                    break :blk s.text.widget();
                },
                .icon => |id| blk: {
                    s.icon = .{
                        .id = id,
                        .size = s.size * 0.52,
                        .color = theme.colors.fg,
                        .label = s.label,
                    };
                    break :blk s.icon.widget();
                },
                .image => |bytes| blk: {
                    const image_size = s.size * 0.82;
                    s.image = .{ .bytes = bytes, .width = image_size, .height = image_size };
                    break :blk s.image.widget();
                },
            };
            s.mark_align = .{ .alignment = .center, .child = mark_widget };
            s.layers[1] = s.mark_align.widget();

            var layer_count: usize = 2;
            if (s.running) {
                s.dot = .{ .color = theme.accent, .radius = 2.5 };
                s.dot_size = .{ .width = 5, .height = 5, .child = s.dot.widget() };
                s.dot_align = .{ .alignment = .bottom_center, .child = s.dot_size.widget() };
                s.layers[layer_count] = s.dot_align.widget();
                layer_count += 1;
            }

            s.stack = .{ .children = s.layers[0..layer_count] };
            s.size_box = .{ .width = s.size, .height = s.size, .child = s.stack.widget() };
            s.tap = .{ .on_tap = s.on_tap, .ctx = s.ctx, .child = s.size_box.widget() };
            return s.tap.widget();
        }
    };

    pub fn widget(self: *const DockTile) phantom.Widget {
        return phantom.StatefulWidget(DockTile, self);
    }
};

/// The adaptive dock from the approved Aurora slice. Desktop gets the compact
/// six-item dock, tablet gets seven larger favourites, and phone keeps four.
pub const Dock = struct {
    on_launcher: ?*const fn (*anyopaque) void = null,
    on_overview: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,

    const max_children = max_pinned + 4;

    pub const State = struct {
        const LaunchTarget = struct {
            apps: Apps = Apps.unavailable,
            id: []const u8 = "",
        };

        base: phantom.StateBase = .{},
        on_launcher: ?*const fn (*anyopaque) void = null,
        on_overview: ?*const fn (*anyopaque) void = null,
        ctx: *anyopaque = undefined,

        launcher: DockTile = undefined,
        apps: [max_pinned]DockTile = undefined,
        launch_targets: [max_pinned]LaunchTarget = undefined,
        overview: DockTile = undefined,
        separator_boxes: [2]phantom.ColoredBox = undefined,
        separators: [2]phantom.SizedBox = undefined,
        children: [max_children]phantom.Widget = undefined,
        row: phantom.Flex = undefined,
        row_size: phantom.SizedBox = undefined,
        padding: phantom.Padding = undefined,
        panel: phantom.DecoratedBox = undefined,
        dock_align: phantom.Align = undefined,

        fn take(s: *@This(), config: *const Dock) void {
            s.on_launcher = config.on_launcher;
            s.on_overview = config.on_overview;
            s.ctx = config.ctx;
        }

        pub fn initState(s: *@This(), config: *const Dock) anyerror!void {
            s.take(config);
        }

        pub fn didUpdateWidget(s: *@This(), config: *const Dock) anyerror!void {
            s.take(config);
        }

        fn launch(ctx: *anyopaque) void {
            const target: *LaunchTarget = @ptrCast(@alignCast(ctx));
            target.apps.launch(target.id) catch {};
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const form = FormFactor.fromWidth(phantom.MediaQuery.of(b).size.width);
            const tile_size: f32 = switch (form) {
                .phone => 46,
                .tablet => 54,
                .desktop => 44,
            };
            const wanted_apps: usize = switch (form) {
                .phone => 4,
                .tablet => 7,
                .desktop => 6,
            };
            const app_service = services.ServicesScope.of(b).apps;
            const catalog = switch (app_service.read()) {
                .ok => |items| items,
                else => &.{},
            };
            var pinned: [max_pinned]*const AppEntry = undefined;
            const pinned_count = pinnedEntries(catalog, &pinned);
            const app_count = @min(wanted_apps, pinned_count);

            var child_count: usize = 0;
            s.launcher = .{
                .mark = .{ .icon = .apps_grid },
                .label = "Open applications",
                .color = theme.colors.bg_medium,
                .size = tile_size,
                .on_tap = s.on_launcher,
                .ctx = s.ctx,
            };
            s.children[child_count] = s.launcher.widget();
            child_count += 1;

            s.separator_boxes[0] = .{ .color = alpha(theme.colors.fg_dim, 0.7), .radius = 0.5 };
            s.separators[0] = .{ .width = 1, .height = tile_size * 0.62, .child = s.separator_boxes[0].widget() };
            s.children[child_count] = s.separators[0].widget();
            child_count += 1;

            for (pinned[0..app_count], 0..) |app_ptr, i| {
                const app = app_ptr.*;
                s.launch_targets[i] = .{ .apps = app_service, .id = app.id };
                s.apps[i] = .{
                    .mark = if (app.icon_bytes.len > 0) .{ .image = app.icon_bytes } else .{ .text = appGlyph(app.name) },
                    .label = app.name,
                    .color = if (app.icon_bytes.len > 0) alpha(theme.colors.bg_medium, 0.32) else appColor(theme, i),
                    .running = app.running,
                    .size = tile_size,
                    .on_tap = launch,
                    .ctx = &s.launch_targets[i],
                };
                s.children[child_count] = s.apps[i].widget();
                child_count += 1;
            }

            // Do not advertise an overview until a window-management owner
            // supplies the action. A visible control that cannot do anything
            // is a mock, not progressive implementation.
            if (s.on_overview != null) {
                s.separator_boxes[1] = .{ .color = alpha(theme.colors.fg_dim, 0.7), .radius = 0.5 };
                s.separators[1] = .{ .width = 1, .height = tile_size * 0.62, .child = s.separator_boxes[1].widget() };
                s.children[child_count] = s.separators[1].widget();
                child_count += 1;

                s.overview = .{
                    .mark = .{ .icon = .overview },
                    .label = "Window overview",
                    .color = theme.colors.bg_medium,
                    .size = tile_size,
                    .on_tap = s.on_overview,
                    .ctx = s.ctx,
                };
                s.children[child_count] = s.overview.widget();
                child_count += 1;
            }

            s.row = .{
                .direction = .horizontal,
                .main = .start,
                .cross = .center,
                .main_size = .min,
                .gap = 8,
                .children = s.children[0..child_count],
            };
            // Flex fills its bounded cross axis. Without this exact height the
            // horizontal row accepts the entire overlay height, turning the
            // dock panel into a tall translucent column with its tiles halfway
            // down the screen.
            s.row_size = .{ .height = tile_size, .child = s.row.widget() };
            s.padding = .{ .insets = phantom.LogicalEdgeInsets.all(8), .child = s.row_size.widget() };
            s.panel = .{
                .color = alpha(theme.colors.bg_dark, theme.surface_alpha),
                .radius = theme.radius,
                .border_color = alpha(theme.colors.fg_dim, 0.55),
                .border_width = 1,
                .child = s.padding.widget(),
            };
            s.dock_align = .{ .alignment = .bottom_center, .child = s.panel.widget() };
            return s.dock_align.widget();
        }
    };

    pub fn widget(self: *const Dock) phantom.Widget {
        return phantom.StatefulWidget(Dock, self);
    }
};

test "dock has room for the approved seven tablet favourites" {
    try @import("std").testing.expectEqual(@as(usize, 7), max_pinned);
}

test "dock panel wraps its tiles instead of filling the viewport height" {
    const std = @import("std");
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var dock = Dock{};
    const element = try dock.widget().mount(&bctx, null);
    defer element.deinit(std.testing.allocator);
    const render = element.renderObject().?;
    _ = render.layout(phantom.BoxConstraints.tight(.{ .width = 800, .height = 600 }));

    var canvas = phantom.Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try render.paint(&canvas, phantom.PhysicalOffset.zero);

    var panel_height: ?f32 = null;
    for (canvas.list.primitives.items) |primitive| switch (primitive) {
        .rrect => |shape| if (shape.rect.width > 50) {
            panel_height = shape.rect.height;
            break;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(f32, 62), panel_height orelse return error.DockPanelMissing);
    try std.testing.expect(sink.ok());
}
