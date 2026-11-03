const std = @import("std");
const phantom = @import("phantom");
const services = @import("../services/services.zig");
const Apps = @import("../services/apps.zig").Apps;

const max_apps = 32;

fn alpha(color: phantom.Color, value: f32) phantom.Color {
    var result = color;
    result.a = value;
    return result;
}

/// Android counterpart to the compositor overview. Tasks use the same grid
/// geometry as Wayland toplevel previews instead of becoming a separate list.
pub const ActiveApps = struct {
    on_close: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub const State = struct {
        const LaunchTarget = struct {
            apps: Apps = Apps.unavailable,
            id: []const u8 = "",
            on_close: ?*const fn (*anyopaque) void = null,
            close_ctx: *anyopaque = undefined,
        };

        base: phantom.StateBase = .{},
        on_close: ?*const fn (*anyopaque) void = null,
        ctx: *anyopaque = undefined,
        controller: phantom.ScrollController = .{},
        previews: [max_apps]phantom.Image = undefined,
        icons: [max_apps]phantom.Image = undefined,
        icon_aligns: [max_apps]phantom.Align = undefined,
        preview_backgrounds: [max_apps]phantom.ColoredBox = undefined,
        preview_layers: [max_apps][2]phantom.Widget = undefined,
        preview_stacks: [max_apps]phantom.Stack = undefined,
        preview_sizes: [max_apps]phantom.SizedBox = undefined,
        labels: [max_apps]phantom.Text = undefined,
        label_paddings: [max_apps]phantom.Padding = undefined,
        card_children: [max_apps][2]phantom.Widget = undefined,
        card_columns: [max_apps]phantom.Flex = undefined,
        cards: [max_apps]phantom.DecoratedBox = undefined,
        taps: [max_apps]phantom.GestureDetector = undefined,
        targets: [max_apps]LaunchTarget = undefined,
        children: [max_apps]phantom.Widget = undefined,
        grid: phantom.GridView = undefined,
        grid_size: phantom.SizedBox = undefined,
        grid_padding: phantom.Padding = undefined,
        empty: phantom.Text = undefined,
        empty_align: phantom.Align = undefined,

        fn take(s: *@This(), config: *const ActiveApps) void {
            s.on_close = config.on_close;
            s.ctx = config.ctx;
        }

        pub fn initState(s: *@This(), config: *const ActiveApps) anyerror!void {
            s.take(config);
        }

        pub fn didUpdateWidget(s: *@This(), config: *const ActiveApps) anyerror!void {
            s.take(config);
        }

        fn launch(ctx: *anyopaque) void {
            const target: *LaunchTarget = @ptrCast(@alignCast(ctx));
            target.apps.launch(target.id) catch return;
            if (target.on_close) |close| close(target.close_ctx);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const viewport = phantom.MediaQuery.of(b).size;
            const app_service = services.ServicesScope.of(b).apps;
            const catalog = switch (app_service.read()) {
                .ok => |items| items,
                else => &.{},
            };

            var running_count: usize = 0;
            for (catalog) |app| if (app.running) {
                running_count += 1;
            };
            const columns: u32 = if (running_count <= 1) 1 else if (running_count <= 4) 2 else 3;
            const gap: f32 = 24;
            const available_width = @max(@as(f32, 1), viewport.width - gap * @as(f32, @floatFromInt(columns + 1)));
            const card_width = available_width / @as(f32, @floatFromInt(columns));
            const card_height = card_width / 0.72;
            const preview_height = @max(@as(f32, 1), card_height - 42);

            var count: usize = 0;
            for (catalog) |app| {
                if (!app.running or count == max_apps) continue;
                const slot = count;
                const preview = if (app.preview_bytes.len > 0) blk: {
                    s.previews[slot] = .{ .bytes = app.preview_bytes, .width = card_width, .height = preview_height };
                    break :blk s.previews[slot].widget();
                } else blk: {
                    s.preview_backgrounds[slot] = .{ .color = alpha(theme.colors.bg_medium, 0.9), .radius = 0 };
                    s.preview_layers[slot][0] = s.preview_backgrounds[slot].widget();
                    if (app.icon_bytes.len > 0) {
                        s.icons[slot] = .{ .bytes = app.icon_bytes, .width = 64, .height = 64 };
                        s.icon_aligns[slot] = .{ .alignment = .center, .child = s.icons[slot].widget() };
                        s.preview_layers[slot][1] = s.icon_aligns[slot].widget();
                        s.preview_stacks[slot] = .{ .children = &s.preview_layers[slot] };
                        break :blk s.preview_stacks[slot].widget();
                    }
                    break :blk s.preview_backgrounds[slot].widget();
                };
                s.preview_sizes[slot] = .{ .height = preview_height, .child = preview };
                s.labels[slot] = .{ .text = app.name, .size = 15, .font = theme.body_bold_font, .color = theme.colors.fg_primary };
                s.label_paddings[slot] = .{ .insets = phantom.LogicalEdgeInsets.symmetric(12, 7), .child = s.labels[slot].widget() };
                s.card_children[slot][0] = s.preview_sizes[slot].widget();
                s.card_children[slot][1] = s.label_paddings[slot].widget();
                s.card_columns[slot] = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .children = &s.card_children[slot] };
                s.cards[slot] = .{
                    .color = alpha(theme.colors.bg_dark, 0.94),
                    .radius = theme.radius * 0.65,
                    .border_color = alpha(theme.colors.fg_dim, 0.7),
                    .border_width = 1,
                    .child = s.card_columns[slot].widget(),
                };
                s.targets[slot] = .{ .apps = app_service, .id = app.id, .on_close = s.on_close, .close_ctx = s.ctx };
                s.taps[slot] = .{ .on_tap = launch, .ctx = &s.targets[slot], .child = s.cards[slot].widget() };
                s.children[slot] = s.taps[slot].widget();
                count += 1;
            }

            if (count == 0) {
                s.empty = .{ .text = "No active windows", .size = 18, .color = theme.colors.fg_muted };
                s.empty_align = .{ .alignment = .center, .child = s.empty.widget() };
                return s.empty_align.widget();
            }
            s.grid = .{ .columns = columns, .spacing = gap, .aspect_ratio = 0.72, .id = "active-windows", .controller = &s.controller, .children = s.children[0..count] };
            s.grid_size = .{ .height = @max(@as(f32, 1), viewport.height - 170), .child = s.grid.widget() };
            s.grid_padding = .{ .insets = .{ .top = 64, .left = gap, .right = gap, .bottom = 82 }, .child = s.grid_size.widget() };
            return s.grid_padding.widget();
        }
    };

    pub fn widget(self: *const ActiveApps) phantom.Widget {
        return phantom.StatefulWidget(ActiveApps, self);
    }
};

const test_entries = [_]@import("../services/apps.zig").Entry{
    .{ .id = "running.desktop", .name = "Running app", .argv = &.{"running"}, .running = true },
    .{ .id = "closed.desktop", .name = "Closed app", .argv = &.{"closed"} },
};
var test_target: u8 = 0;

fn readTestApps(_: *anyopaque) services.Reading([]const @import("../services/apps.zig").Entry) {
    return .{ .ok = &test_entries };
}

fn launchTestApp(_: *anyopaque, _: []const u8) anyerror!void {}

const test_vtable = Apps.VTable{ .read = readTestApps, .launch = launchTestApp };

test "Android overview uses only active windows" {
    var service_set = services.Services{ .apps = .{ .ptr = &test_target, .vtable = &test_vtable } };
    var overview = ActiveApps{};
    var scope = services.ServicesScope{ .services = &service_set, .child = overview.widget() };
    var metrics = phantom.MediaQueryData{ .size = .{ .width = 720, .height = 1280 }, .dpr = 2 };
    var media = phantom.MediaQuery{ .data = &metrics, .child = scope.widget() };
    var harness = try phantom.testing.mount(std.testing.allocator, media.widget());
    defer harness.deinit();
    harness.viewport = metrics.size;
    try harness.pump();
    try harness.expectHtml(">Running app<");
    try harness.expectNoHtml(">Closed app<");
    try harness.expectNoFaults();
}
