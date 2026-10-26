const std = @import("std");
const phantom = @import("phantom");
const services = @import("../services/services.zig");
const Notification = @import("../services/notifications.zig").Notification;
const Notifications = @import("../services/notifications.zig").Notifications;
const AppEntry = @import("../services/apps.zig").Entry;

const max_toasts = 3;
const max_seen = 64;
const enter_ns: i96 = 420_000_000;
const leave_ns: i96 = 220_000_000;
const stagger_ns: i96 = 120_000_000;
const default_timeout_ns: i96 = 5_000_000_000;

fn alpha(color: phantom.Color, opacity: f32) phantom.Color {
    var result = color;
    result.a *= opacity;
    return result;
}

fn findNotification(items: []const Notification, id: u32) ?Notification {
    for (items) |item| if (item.id == id) return item;
    return null;
}

fn findIcon(apps: []const AppEntry, notification: Notification) []const u8 {
    for (apps) |app| {
        if ((notification.app_icon.len > 0 and std.mem.eql(u8, app.icon, notification.app_icon)) or
            std.ascii.eqlIgnoreCase(app.name, notification.app_name)) return app.icon_bytes;
    }
    return "";
}

/// Transient notification banners. History ownership remains with the session
/// service; this widget only tracks presentation lifetimes and animation state.
pub const NotificationToasts = struct {
    pub const State = struct {
        const Slot = struct { id: u32 = 0, born_ns: i96 = 0, hide_ns: ?i96 = null };
        const Target = struct { state: *State = undefined, id: u32 = 0, action: []const u8 = "" };

        base: phantom.StateBase = .{},
        ticker: phantom.Ticker = undefined,
        service: Notifications = Notifications.unavailable,
        slots: [max_toasts]Slot = @splat(.{}),
        seen: [max_seen]u32 = @splat(0),
        seen_count: usize = 0,

        app_labels: [max_toasts]phantom.Text = undefined,
        close_labels: [max_toasts]phantom.Text = undefined,
        close_buttons: [max_toasts]phantom.Button = undefined,
        close_targets: [max_toasts]Target = undefined,
        header_children: [max_toasts][2]phantom.Widget = undefined,
        headers: [max_toasts]phantom.Flex = undefined,
        header_sizes: [max_toasts]phantom.SizedBox = undefined,
        summaries: [max_toasts]phantom.Text = undefined,
        bodies: [max_toasts]phantom.Text = undefined,
        action_labels: [max_toasts][2]phantom.Text = undefined,
        action_buttons: [max_toasts][2]phantom.Button = undefined,
        action_targets: [max_toasts][2]Target = undefined,
        action_children: [max_toasts][2]phantom.Widget = undefined,
        action_rows: [max_toasts]phantom.Flex = undefined,
        content_children: [max_toasts][4]phantom.Widget = undefined,
        content_columns: [max_toasts]phantom.Flex = undefined,
        icons: [max_toasts]phantom.Image = undefined,
        glyphs: [max_toasts]phantom.Text = undefined,
        glyph_aligns: [max_toasts]phantom.Align = undefined,
        glyph_boxes: [max_toasts]phantom.ColoredBox = undefined,
        icon_sizes: [max_toasts]phantom.SizedBox = undefined,
        row_children: [max_toasts][2]phantom.Widget = undefined,
        rows: [max_toasts]phantom.Flex = undefined,
        paddings: [max_toasts]phantom.Padding = undefined,
        boxes: [max_toasts]phantom.DecoratedBox = undefined,
        sizes: [max_toasts]phantom.SizedBox = undefined,
        translations: [max_toasts]phantom.Translate = undefined,
        cards: [max_toasts]phantom.Widget = undefined,
        column: phantom.Flex = undefined,
        outer_padding: phantom.Padding = undefined,
        toast_align: phantom.Align = undefined,

        pub fn initState(s: *@This(), _: *const NotificationToasts) anyerror!void {
            s.ticker = .{ .scheduler = s.base.scheduler(), .ctx = s, .on_tick = onFrame };
        }

        pub fn dispose(s: *@This()) void {
            s.ticker.deinit();
        }

        fn wasSeen(s: *const @This(), id: u32) bool {
            for (s.seen[0..s.seen_count]) |seen| if (seen == id) return true;
            return false;
        }

        fn remember(s: *@This(), id: u32) void {
            if (s.seen_count < max_seen) {
                s.seen[s.seen_count] = id;
                s.seen_count += 1;
            } else {
                std.mem.copyForwards(u32, s.seen[0 .. max_seen - 1], s.seen[1..max_seen]);
                s.seen[max_seen - 1] = id;
            }
        }

        fn present(s: *@This(), notification: Notification, order: usize) void {
            var index: usize = 0;
            while (index < max_toasts and s.slots[index].id != 0) : (index += 1) {}
            if (index == max_toasts) {
                s.slots[0] = s.slots[1];
                s.slots[1] = s.slots[2];
                index = max_toasts - 1;
            }
            const born = s.base.scheduler().now + @as(i96, @intCast(order)) * stagger_ns;
            const timeout = if (notification.expire_timeout_ms < 0)
                default_timeout_ns
            else
                @as(i96, notification.expire_timeout_ms) * std.time.ns_per_ms;
            // Finish the leave animation as the daemon reaches the protocol
            // expiry deadline; otherwise removal from history would make the
            // toast disappear one frame before it can animate out.
            const hide = if (timeout == 0) null else born + @max(enter_ns, timeout - leave_ns);
            s.slots[index] = .{ .id = notification.id, .born_ns = born, .hide_ns = hide };
            s.remember(notification.id);
        }

        fn onFrame(ctx: *anyopaque, _: phantom.Ticker.Nanos) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            const now = s.base.scheduler().now;
            var needs_more_frames = false;
            for (&s.slots) |*slot| {
                if (slot.id == 0) continue;
                if (slot.hide_ns) |hide| {
                    if (now >= hide + leave_ns) {
                        slot.* = .{};
                        continue;
                    }
                    needs_more_frames = true;
                } else if (now < slot.born_ns + enter_ns) {
                    needs_more_frames = true;
                }
            }
            phantom.markNeedsBuild(s);
            if (!needs_more_frames) s.ticker.stop();
        }

        fn dismiss(ctx: *anyopaque) void {
            const target: *Target = @ptrCast(@alignCast(ctx));
            target.state.service.dismiss(target.id);
            for (&target.state.slots) |*slot| {
                if (slot.id == target.id) slot.* = .{};
            }
            phantom.markNeedsBuild(target.state);
        }

        fn invoke(ctx: *anyopaque) void {
            const target: *Target = @ptrCast(@alignCast(ctx));
            target.state.service.invoke(target.id, target.action);
            for (&target.state.slots) |*slot| {
                if (slot.id == target.id) slot.* = .{};
            }
            phantom.markNeedsBuild(target.state);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const svc = services.ServicesScope.of(b);
            s.service = svc.notifications;
            const notifications = switch (s.service.read()) {
                .ok => |items| items,
                else => &.{},
            };
            const apps = switch (svc.apps.read()) {
                .ok => |items| items,
                else => &.{},
            };

            var new_order: usize = 0;
            for (notifications) |notification| if (!s.wasSeen(notification.id)) {
                s.present(notification, new_order);
                new_order += 1;
            };
            if (new_order > 0 and !s.ticker.isRunning()) try s.ticker.start(s.base.gpa());

            const now = s.base.scheduler().now;
            var count: usize = 0;
            for (&s.slots) |*slot| {
                if (slot.id == 0) continue;
                const notification = findNotification(notifications, slot.id) orelse {
                    slot.* = .{};
                    continue;
                };
                const entering = (phantom.Tween(f32){ .begin = 0, .end = 1, .curve = .ease_out_cubic }).atTime(now - slot.born_ns, enter_ns);
                const visibility = if (slot.hide_ns) |hide|
                    if (now >= hide) (phantom.Tween(f32){ .begin = 1, .end = 0, .curve = .ease_in }).atTime(now - hide, leave_ns) else entering
                else
                    entering;
                const index = count;

                s.app_labels[index] = .{ .text = if (notification.app_name.len > 0) notification.app_name else "Application", .size = 11, .font = theme.body_bold_font, .color = alpha(theme.accent, visibility) };
                s.close_labels[index] = .{ .text = "×", .size = 14, .color = alpha(theme.colors.fg_muted, visibility) };
                s.close_targets[index] = .{ .state = s, .id = notification.id };
                s.close_buttons[index] = .{ .variant = .secondary, .padding = phantom.LogicalEdgeInsets.symmetric(7, 1), .on_tap = dismiss, .ctx = &s.close_targets[index], .child = s.close_labels[index].widget() };
                s.header_children[index] = .{ s.app_labels[index].widget(), s.close_buttons[index].widget() };
                s.headers[index] = phantom.Row(.{ .main = .space_between, .cross = .center, .children = &s.header_children[index] });
                s.header_sizes[index] = .{ .width = 277, .height = 20, .child = s.headers[index].widget() };
                s.summaries[index] = .{ .text = notification.summary, .size = 14, .font = theme.body_bold_font, .color = alpha(theme.colors.fg, visibility) };
                s.bodies[index] = .{ .text = notification.body, .size = 12, .color = alpha(theme.colors.fg_primary, visibility) };
                s.content_children[index][0] = s.header_sizes[index].widget();
                s.content_children[index][1] = s.summaries[index].widget();
                s.content_children[index][2] = s.bodies[index].widget();
                var content_count: usize = 3;
                const shown_actions = @min(notification.actions.len, 2);
                if (shown_actions > 0) {
                    for (notification.actions[0..shown_actions], 0..) |action, action_index| {
                        s.action_labels[index][action_index] = .{ .text = action.label, .size = 12, .font = theme.body_bold_font, .color = alpha(theme.accent, visibility) };
                        s.action_targets[index][action_index] = .{ .state = s, .id = notification.id, .action = action.key };
                        s.action_buttons[index][action_index] = .{ .variant = .secondary, .padding = phantom.LogicalEdgeInsets.symmetric(10, 4), .on_tap = invoke, .ctx = &s.action_targets[index][action_index], .child = s.action_labels[index][action_index].widget() };
                        s.action_children[index][action_index] = s.action_buttons[index][action_index].widget();
                    }
                    s.action_rows[index] = phantom.Row(.{ .main = .start, .cross = .center, .gap = 8, .children = s.action_children[index][0..shown_actions] });
                    s.content_children[index][content_count] = s.action_rows[index].widget();
                    content_count += 1;
                }
                s.content_columns[index] = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .gap = 3, .children = s.content_children[index][0..content_count] };

                const icon_bytes = findIcon(apps, notification);
                const icon_widget = if (icon_bytes.len > 0) blk: {
                    s.icons[index] = .{ .bytes = icon_bytes, .width = 34, .height = 34 };
                    break :blk s.icons[index].widget();
                } else blk: {
                    const glyph = if (notification.app_name.len > 0) notification.app_name[0..1] else "!";
                    s.glyphs[index] = .{ .text = glyph, .size = 15, .font = theme.body_bold_font, .color = alpha(theme.colors.bg_dark, visibility) };
                    s.glyph_boxes[index] = .{ .color = alpha(theme.accent, visibility), .radius = 9 };
                    s.glyph_aligns[index] = .{ .alignment = .center, .child = s.glyphs[index].widget() };
                    const layers = try b.arena.alloc(phantom.Widget, 2);
                    layers[0] = s.glyph_boxes[index].widget();
                    layers[1] = s.glyph_aligns[index].widget();
                    const stack = try b.arena.create(phantom.Stack);
                    stack.* = .{ .children = layers };
                    break :blk stack.widget();
                };
                s.icon_sizes[index] = .{ .width = 34, .height = 34, .child = icon_widget };
                s.row_children[index] = .{ s.icon_sizes[index].widget(), s.content_columns[index].widget() };
                s.rows[index] = phantom.Row(.{ .main = .start, .cross = .start, .main_size = .min, .gap = 11, .children = &s.row_children[index] });
                s.paddings[index] = .{ .insets = phantom.LogicalEdgeInsets.symmetric(13, 11), .child = s.rows[index].widget() };
                s.boxes[index] = .{ .color = alpha(theme.colors.bg_dark, 0.96 * visibility), .radius = 14, .border_color = alpha(theme.colors.fg_dim, 0.65 * visibility), .border_width = 1, .child = s.paddings[index].widget() };
                s.sizes[index] = .{ .width = 352, .height = if (notification.actions.len > 0) 118 else 90, .child = s.boxes[index].widget() };
                s.translations[index] = .{ .offset = .{ .x = (1 - visibility) * 30, .y = 0 }, .child = s.sizes[index].widget() };
                s.cards[index] = s.translations[index].widget();
                count += 1;
            }

            s.column = .{ .direction = .vertical, .main = .start, .cross = .end, .main_size = .min, .gap = 10, .children = s.cards[0..count] };
            s.outer_padding = .{ .insets = .{ .top = 12, .right = 12 }, .child = s.column.widget() };
            s.toast_align = .{ .alignment = .top_right, .child = s.outer_padding.widget() };
            return s.toast_align.widget();
        }
    };

    pub fn widget(self: *const NotificationToasts) phantom.Widget {
        return phantom.StatefulWidget(NotificationToasts, self);
    }
};

var test_target: u8 = 0;
const test_items = [_]Notification{.{
    .id = 42,
    .app_name = "Mail",
    .app_icon = "",
    .summary = "Animated toast",
    .body = "Moves in from the right",
    .created_ns = 0,
    .expire_timeout_ms = 5000,
}};

fn readTest(_: *anyopaque) services.Reading([]const Notification) {
    return .{ .ok = &test_items };
}
fn dismissTest(_: *anyopaque, _: u32) void {}
fn clearTest(_: *anyopaque) void {}
fn invokeTest(_: *anyopaque, _: u32, _: []const u8) void {}

const test_vtable = Notifications.VTable{
    .read = readTest,
    .dismiss = dismissTest,
    .clear = clearTest,
    .invoke = invokeTest,
};

fn textX(primitives: []const phantom.Primitive, wanted: []const u8) ?f32 {
    for (primitives) |primitive| switch (primitive) {
        .text => |run| if (std.mem.eql(u8, run.text, wanted)) return run.origin.x,
        else => {},
    };
    return null;
}

test "notification toast slides into place and expires without deleting history" {
    var service_set = services.Services{ .notifications = .{ .ptr = &test_target, .vtable = &test_vtable } };
    var toasts = NotificationToasts{};
    var scope = services.ServicesScope{ .services = &service_set, .child = toasts.widget() };
    var harness = try phantom.testing.mount(std.testing.allocator, scope.widget());
    defer harness.deinit();
    harness.viewport = .{ .width = 1512, .height = 914 };
    try harness.pump();
    const initial_x = textX(harness.canvas.list.primitives.items, "Animated toast") orelse return error.ToastMissing;

    harness.owner.scheduler.tick(enter_ns);
    try harness.pump();
    const settled_x = textX(harness.canvas.list.primitives.items, "Animated toast") orelse return error.ToastMissing;
    try std.testing.expect(settled_x < initial_x);

    harness.owner.scheduler.tick(enter_ns + default_timeout_ns + leave_ns + 1);
    try harness.pump();
    try std.testing.expect(textX(harness.canvas.list.primitives.items, "Animated toast") == null);
    // Expiring the banner does not dismiss the history item.
    try std.testing.expectEqual(@as(usize, 1), service_set.notifications.read().ok.len);
    try harness.expectNoFaults();
}
