const std = @import("std");
const phantom = @import("phantom");
const services = @import("../services/services.zig");
const Apps = @import("../services/apps.zig").Apps;

fn alpha(color: phantom.Color, value: f32) phantom.Color {
    var result = color;
    result.a = value;
    return result;
}

/// The catalog is indexed once by the platform provider. Keeping this bounded
/// protects the state size from a malformed source while still accommodating
/// a full desktop installation; the result area itself is clipped and scrolled
/// rather than truncating what the user can reach.
const max_results = 256;

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var equal = true;
        for (haystack[start..][0..needle.len], needle) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

/// Slice-one launcher: a searchable, compact application list in the shell's
/// single overlay slot. App activation is intentionally left to the Apps
/// service; this surface establishes the interaction and responsive layout.
pub const Launcher = struct {
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
        controller: phantom.TextFieldController = .{},
        scroll_controller: phantom.ScrollController = .{},
        query: [256]u8 = undefined,
        query_len: usize = 0,

        backdrop: phantom.ColoredBox = undefined,
        title: phantom.Text = undefined,
        search: phantom.TextField = undefined,
        search_padding: phantom.Padding = undefined,
        search_box: phantom.DecoratedBox = undefined,
        search_size: phantom.SizedBox = undefined,
        entries: [max_results]phantom.Text = undefined,
        entry_images: [max_results]phantom.Image = undefined,
        entry_glyphs: [max_results]phantom.Text = undefined,
        entry_glyph_backgrounds: [max_results]phantom.ColoredBox = undefined,
        entry_glyph_aligns: [max_results]phantom.Align = undefined,
        entry_marks: [max_results]phantom.SizedBox = undefined,
        entry_row_children: [max_results][2]phantom.Widget = undefined,
        entry_rows: [max_results]phantom.Flex = undefined,
        entry_padding: [max_results]phantom.Padding = undefined,
        entry_boxes: [max_results]phantom.DecoratedBox = undefined,
        entry_sizes: [max_results]phantom.SizedBox = undefined,
        entry_taps: [max_results]phantom.GestureDetector = undefined,
        launch_targets: [max_results]LaunchTarget = undefined,
        empty: phantom.Text = undefined,
        result_children: [max_results]phantom.Widget = undefined,
        result_column: phantom.Flex = undefined,
        results_scroll: phantom.ScrollView = undefined,
        results_size: phantom.SizedBox = undefined,
        children: [3]phantom.Widget = undefined,
        column: phantom.Flex = undefined,
        panel_padding: phantom.Padding = undefined,
        panel: phantom.DecoratedBox = undefined,
        panel_size: phantom.SizedBox = undefined,
        top_padding: phantom.Padding = undefined,
        panel_align: phantom.Align = undefined,
        layers: [2]phantom.Widget = undefined,
        stack: phantom.Stack = undefined,

        fn take(s: *@This(), config: *const Launcher) void {
            s.on_close = config.on_close;
            s.ctx = config.ctx;
        }

        pub fn initState(s: *@This(), config: *const Launcher) anyerror!void {
            s.take(config);
        }

        pub fn didUpdateWidget(s: *@This(), config: *const Launcher) anyerror!void {
            s.take(config);
        }

        fn onChange(ctx: *anyopaque, text: []const u8) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.query_len = @min(text.len, s.query.len);
            @memcpy(s.query[0..s.query_len], text[0..s.query_len]);
            _ = s.scroll_controller.jumpTo(.zero);
            phantom.markNeedsBuild(s);
        }

        fn onKey(ctx: *anyopaque, ev: phantom.input.KeyEvent) bool {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (ev.keysym != .escape or ev.action != .press) return false;
            if (s.on_close) |close| close(s.ctx);
            return true;
        }

        fn launch(ctx: *anyopaque) void {
            const target: *LaunchTarget = @ptrCast(@alignCast(ctx));
            target.apps.launch(target.id) catch return;
            if (target.on_close) |close| close(target.close_ctx);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const viewport = phantom.MediaQuery.of(b).size;
            const panel_width = @min(@as(f32, 520), viewport.width * 0.88);

            s.backdrop = .{ .color = alpha(theme.colors.bg_dark, 0.76), .radius = 0 };
            s.layers[0] = s.backdrop.widget();

            var child_count: usize = 0;
            s.title = .{
                .text = "Applications",
                .size = 28,
                .font = theme.body_bold_font,
                .color = theme.colors.fg,
            };
            s.children[child_count] = s.title.widget();
            child_count += 1;

            s.search = .{
                .placeholder = "Search applications",
                .id = "launcher-search",
                .autofocus = true,
                .controller = &s.controller,
                .on_change = onChange,
                .on_key = onKey,
                .ctx = s,
                .max_lines = 1,
            };
            s.search_padding = .{
                .insets = phantom.LogicalEdgeInsets.symmetric(14, 9),
                .child = s.search.widget(),
            };
            s.search_box = .{
                .color = alpha(theme.colors.bg, 0.92),
                .radius = theme.radius * 0.55,
                .border_color = alpha(theme.colors.fg_dim, 0.55),
                .border_width = 1,
                .child = s.search_padding.widget(),
            };
            s.search_size = .{ .width = panel_width - 36, .child = s.search_box.widget() };
            s.children[child_count] = s.search_size.widget();
            child_count += 1;

            const query = s.query[0..s.query_len];
            var match_count: usize = 0;
            // Header, panel padding, and the floating dock remain outside the
            // scrolling viewport. Results may be taller, but are clipped here.
            const result_height = @max(@as(f32, 176), viewport.height - 355);
            const app_service = services.ServicesScope.of(b).apps;
            const catalog = switch (app_service.read()) {
                .ok => |items| items,
                else => &.{},
            };
            for (catalog) |app| {
                if (!containsIgnoreCase(app.name, query)) continue;
                if (match_count == max_results) break;
                const slot = match_count;
                s.entries[slot] = .{
                    .text = app.name,
                    .size = 18,
                    .color = theme.colors.fg_primary,
                };
                const mark_widget = if (app.icon_bytes.len > 0) blk: {
                    s.entry_images[slot] = .{ .bytes = app.icon_bytes, .width = 30, .height = 30 };
                    break :blk s.entry_images[slot].widget();
                } else blk: {
                    s.entry_glyphs[slot] = .{
                        .text = if (app.name.len > 0 and std.ascii.isAlphabetic(app.name[0])) app.name[0..1] else "?",
                        .size = 15,
                        .font = theme.body_bold_font,
                        .color = theme.colors.fg,
                    };
                    s.entry_glyph_backgrounds[slot] = .{ .color = alpha(theme.colors.bg_medium, 0.65), .radius = theme.radius * 0.34 };
                    s.entry_glyph_aligns[slot] = .{ .alignment = .center, .child = s.entry_glyphs[slot].widget() };
                    const glyph_layers = try b.arena.alloc(phantom.Widget, 2);
                    glyph_layers[0] = s.entry_glyph_backgrounds[slot].widget();
                    glyph_layers[1] = s.entry_glyph_aligns[slot].widget();
                    const glyph_stack = try b.arena.create(phantom.Stack);
                    glyph_stack.* = .{ .children = glyph_layers };
                    break :blk glyph_stack.widget();
                };
                s.entry_marks[slot] = .{ .width = 30, .height = 30, .child = mark_widget };
                s.entry_row_children[slot][0] = s.entry_marks[slot].widget();
                s.entry_row_children[slot][1] = s.entries[slot].widget();
                s.entry_rows[slot] = .{
                    .direction = .horizontal,
                    .main = .start,
                    .cross = .center,
                    .main_size = .min,
                    .gap = 11,
                    .children = &s.entry_row_children[slot],
                };
                s.entry_padding[slot] = .{
                    .insets = phantom.LogicalEdgeInsets.symmetric(10, 6),
                    .child = s.entry_rows[slot].widget(),
                };
                s.entry_boxes[slot] = .{
                    .color = alpha(theme.colors.bg_medium, 0.72),
                    .radius = theme.radius * 0.42,
                    .child = s.entry_padding[slot].widget(),
                };
                s.launch_targets[slot] = .{
                    .apps = app_service,
                    .id = app.id,
                    .on_close = s.on_close,
                    .close_ctx = s.ctx,
                };
                s.entry_taps[slot] = .{
                    .on_tap = launch,
                    .ctx = &s.launch_targets[slot],
                    .child = undefined,
                };
                // A horizontal Flex fills a bounded cross axis. Give the row
                // its intended height as well as its width, otherwise it takes
                // the overlay's remaining height and vertically centres one
                // application inside a giant result tile.
                s.entry_sizes[slot] = .{ .width = panel_width - 36, .height = 42, .child = s.entry_boxes[slot].widget() };
                s.entry_taps[slot].child = s.entry_sizes[slot].widget();
                s.result_children[slot] = s.entry_taps[slot].widget();
                match_count += 1;
            }
            if (match_count == 0) {
                s.empty = .{ .text = "No matching applications", .color = theme.colors.fg_muted };
                s.result_children[0] = s.empty.widget();
                match_count = 1;
            }

            s.result_column = .{
                .direction = .vertical,
                .main = .start,
                .cross = .start,
                .main_size = .min,
                .gap = 7,
                .children = s.result_children[0..match_count],
            };
            s.results_scroll = .{
                .child = s.result_column.widget(),
                .controller = &s.scroll_controller,
                .id = "launcher-results",
            };
            s.results_size = .{
                .width = panel_width - 36,
                .height = result_height,
                .child = s.results_scroll.widget(),
            };
            s.children[child_count] = s.results_size.widget();
            child_count += 1;

            s.column = .{
                .direction = .vertical,
                .main = .start,
                .cross = .start,
                .main_size = .min,
                .gap = 7,
                .children = s.children[0..child_count],
            };
            s.panel_padding = .{ .insets = phantom.LogicalEdgeInsets.all(18), .child = s.column.widget() };
            s.panel = .{
                .color = alpha(theme.colors.bg_dark, 0.94),
                .radius = theme.radius,
                .border_color = alpha(theme.colors.fg_dim, 0.65),
                .border_width = 1,
                .child = s.panel_padding.widget(),
            };
            s.panel_size = .{ .width = panel_width, .child = s.panel.widget() };
            s.top_padding = .{
                .insets = .{ .top = 64 },
                .child = s.panel_size.widget(),
            };
            s.panel_align = .{ .alignment = .top_center, .child = s.top_padding.widget() };
            s.layers[1] = s.panel_align.widget();
            s.stack = .{ .children = &s.layers };
            return s.stack.widget();
        }
    };

    pub fn widget(self: *const Launcher) phantom.Widget {
        return phantom.StatefulWidget(Launcher, self);
    }
};

test "launcher matching ignores ASCII case" {
    try std.testing.expect(containsIgnoreCase("Aster Web", "WEB"));
    try std.testing.expect(!containsIgnoreCase("Files", "mail"));
}

const layout_test_entries = [_]@import("../services/apps.zig").Entry{
    .{ .id = "one.desktop", .name = "First application", .argv = &.{"one"} },
    .{ .id = "two.desktop", .name = "Second application", .argv = &.{"two"} },
};
var layout_test_target: u8 = 0;

fn readLayoutTestApps(_: *anyopaque) services.Reading([]const @import("../services/apps.zig").Entry) {
    return .{ .ok = &layout_test_entries };
}

fn launchLayoutTestApp(_: *anyopaque, _: []const u8) anyerror!void {}

const layout_test_apps_vtable = Apps.VTable{
    .read = readLayoutTestApps,
    .launch = launchLayoutTestApp,
};

const scroll_test_entry = @import("../services/apps.zig").Entry{
    .id = "scroll.desktop",
    .name = "Scrollable application",
    .argv = &.{"scroll"},
};
const scroll_test_entries = blk: {
    var entries: [24]@import("../services/apps.zig").Entry = undefined;
    for (&entries) |*entry| entry.* = scroll_test_entry;
    break :blk entries;
};
var scroll_test_target: u8 = 0;

fn readScrollTestApps(_: *anyopaque) services.Reading([]const @import("../services/apps.zig").Entry) {
    return .{ .ok = &scroll_test_entries };
}

const scroll_test_apps_vtable = Apps.VTable{
    .read = readScrollTestApps,
    .launch = launchLayoutTestApp,
};

test "launcher result rows keep their compact height inside a tall overlay" {
    var service_set = services.Services{
        .apps = .{ .ptr = &layout_test_target, .vtable = &layout_test_apps_vtable },
    };
    var launcher = Launcher{};
    var scope = services.ServicesScope{ .services = &service_set, .child = launcher.widget() };
    var metrics = phantom.MediaQueryData{
        .size = .{ .width = 1512, .height = 914 },
        .dpr = 1,
    };
    var media = phantom.MediaQuery{ .data = &metrics, .child = scope.widget() };
    var harness = try phantom.testing.mount(std.testing.allocator, media.widget());
    defer harness.deinit();
    harness.viewport = metrics.size;
    try harness.pump();

    // 484 x 42 logical pixels. Without the explicit height, the horizontal
    // row takes nearly the whole overlay and only the first app is visible.
    try harness.expectHtml("width:30.25rem;height:2.625rem");
    try harness.expectHtml(">First application<");
    try harness.expectHtml(">Second application<");
    try harness.expectNoFaults();
}

test "launcher catalog scrolls without moving its header or into the dock" {
    var service_set = services.Services{
        .apps = .{ .ptr = &scroll_test_target, .vtable = &scroll_test_apps_vtable },
    };
    var launcher = Launcher{};
    var scope = services.ServicesScope{ .services = &service_set, .child = launcher.widget() };
    var metrics = phantom.MediaQueryData{
        .size = .{ .width = 1512, .height = 914 },
        .dpr = 1,
    };
    var media = phantom.MediaQuery{ .data = &metrics, .child = scope.widget() };
    var harness = try phantom.testing.mount(std.testing.allocator, media.widget());
    defer harness.deinit();
    harness.viewport = metrics.size;
    try harness.pump();

    const findScroll = struct {
        fn run(primitives: []const phantom.Primitive) ?phantom.display_list.ScrollRegion {
            for (primitives) |primitive| switch (primitive) {
                .push_scroll => |region| return region,
                else => {},
            };
            return null;
        }
    }.run;
    const initial = findScroll(harness.canvas.list.primitives.items) orelse return error.LauncherScrollRegionMissing;
    try std.testing.expect(initial.content.height > initial.viewport.height);
    try std.testing.expectEqual(@as(f32, 559), initial.viewport.height);

    try harness.scrollAt(.{ .x = 756, .y = 400 }, 0, 120);
    const moved = findScroll(harness.canvas.list.primitives.items) orelse return error.LauncherScrollRegionMissing;
    try std.testing.expectApproxEqAbs(@as(f32, 120), moved.offset.y, 0.001);
    try harness.expectHtml(">Applications<");
    try harness.expectNoFaults();
}
