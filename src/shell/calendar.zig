const std = @import("std");
const phantom = @import("phantom");
const services = @import("../services/services.zig");

fn alpha(color: phantom.Color, value: f32) phantom.Color {
    var result = color;
    result.a = value;
    return result;
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekday_names = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };

pub const CalendarPanel = struct {
    on_close: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub const State = struct {
        base: phantom.StateBase = .{},
        on_close: ?*const fn (*anyopaque) void = null,
        ctx: *anyopaque = undefined,
        title_buf: [32]u8 = undefined,
        day_bufs: [42][2]u8 = undefined,
        backdrop: phantom.ColoredBox = undefined,
        backdrop_tap: phantom.GestureDetector = undefined,
        title: phantom.Text = undefined,
        weekday_labels: [7]phantom.Text = undefined,
        weekday_aligns: [7]phantom.Align = undefined,
        weekday_sizes: [7]phantom.SizedBox = undefined,
        day_labels: [42]phantom.Text = undefined,
        day_aligns: [42]phantom.Align = undefined,
        day_boxes: [42]phantom.DecoratedBox = undefined,
        day_sizes: [42]phantom.SizedBox = undefined,
        grid_children: [49]phantom.Widget = undefined,
        grid: phantom.GridView = undefined,
        grid_size: phantom.SizedBox = undefined,
        upcoming_title: phantom.Text = undefined,
        upcoming_empty: phantom.Text = undefined,
        recent_title: phantom.Text = undefined,
        recent_items: [2]phantom.Text = undefined,
        recent_children: [2]phantom.Widget = undefined,
        recent_column: phantom.Flex = undefined,
        children: [6]phantom.Widget = undefined,
        column: phantom.Flex = undefined,
        padding: phantom.Padding = undefined,
        box: phantom.DecoratedBox = undefined,
        size: phantom.SizedBox = undefined,
        panel_align: phantom.Align = undefined,
        layers: [2]phantom.Widget = undefined,
        stack: phantom.Stack = undefined,

        fn take(s: *@This(), config: *const CalendarPanel) void {
            s.on_close = config.on_close;
            s.ctx = config.ctx;
        }

        pub fn initState(s: *@This(), config: *const CalendarPanel) anyerror!void {
            s.take(config);
        }
        pub fn didUpdateWidget(s: *@This(), config: *const CalendarPanel) anyerror!void {
            s.take(config);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const svc = services.ServicesScope.of(b);
            s.backdrop = .{ .color = alpha(theme.colors.bg_dark, 0.48), .radius = 0 };
            s.backdrop_tap = .{ .on_tap = s.on_close, .ctx = s.ctx, .child = s.backdrop.widget() };
            s.layers[0] = s.backdrop_tap.widget();

            const unix_ns = switch (svc.clock.read()) {
                .ok => |clock| clock.unix_ns,
                else => 0,
            };
            const seconds: u64 = @intCast(@max(0, @divFloor(unix_ns, std.time.ns_per_s)));
            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
            const epoch_day = epoch_seconds.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const month_number: usize = @backingInt(month_day.month);
            const title = std.fmt.bufPrint(&s.title_buf, "{s} {d}", .{ month_names[month_number - 1], year_day.year }) catch "Calendar";
            s.title = .{ .text = title, .size = 22, .font = theme.body_bold_font, .color = theme.colors.fg };

            for (weekday_names, 0..) |name, index| {
                s.weekday_labels[index] = .{ .text = name, .size = 12, .font = theme.body_bold_font, .color = theme.colors.fg_muted };
                s.weekday_aligns[index] = .{ .alignment = .center, .child = s.weekday_labels[index].widget() };
                s.weekday_sizes[index] = .{ .width = 40, .height = 28, .child = s.weekday_aligns[index].widget() };
                s.grid_children[index] = s.weekday_sizes[index].widget();
            }
            const month_start_day = epoch_day.day - month_day.day_index;
            const first_weekday: usize = @intCast((month_start_day + 4) % 7);
            const days_in_month: usize = std.time.epoch.getDaysInMonth(year_day.year, month_day.month);
            for (0..42) |index| {
                const occupied = index >= first_weekday and index < first_weekday + days_in_month;
                const day: usize = if (occupied) index - first_weekday + 1 else 0;
                const text = if (occupied) std.fmt.bufPrint(&s.day_bufs[index], "{d}", .{day}) catch "" else "";
                const today = occupied and day == @as(usize, month_day.day_index) + 1;
                s.day_labels[index] = .{ .text = text, .size = 13, .font = if (today) theme.body_bold_font else null, .color = if (today) theme.colors.bg_dark else theme.colors.fg_primary };
                s.day_aligns[index] = .{ .alignment = .center, .child = s.day_labels[index].widget() };
                s.day_boxes[index] = .{ .color = if (today) theme.accent else .{ .a = 0 }, .radius = 15, .child = s.day_aligns[index].widget() };
                s.day_sizes[index] = .{ .width = 40, .height = 34, .child = s.day_boxes[index].widget() };
                s.grid_children[index + 7] = s.day_sizes[index].widget();
            }
            s.grid = .{ .columns = 7, .spacing = 4, .aspect_ratio = 1.18, .children = &s.grid_children };
            s.grid_size = .{ .width = 316, .height = 272, .child = s.grid.widget() };
            s.upcoming_title = .{ .text = "Upcoming", .size = 15, .font = theme.body_bold_font, .color = theme.colors.fg };
            s.upcoming_empty = .{ .text = "No upcoming events", .size = 13, .color = theme.colors.fg_muted };
            s.recent_title = .{ .text = "Recent notifications", .size = 15, .font = theme.body_bold_font, .color = theme.colors.fg };

            const notifications = switch (svc.notifications.read()) {
                .ok => |items| items,
                else => &.{},
            };
            var recent_count: usize = 0;
            while (recent_count < @min(notifications.len, 2)) : (recent_count += 1) {
                const notification = notifications[notifications.len - 1 - recent_count];
                s.recent_items[recent_count] = .{ .text = notification.summary, .size = 13, .color = theme.colors.fg_primary };
                s.recent_children[recent_count] = s.recent_items[recent_count].widget();
            }
            if (recent_count == 0) {
                s.recent_items[0] = .{ .text = "No recent notifications", .size = 13, .color = theme.colors.fg_muted };
                s.recent_children[0] = s.recent_items[0].widget();
                recent_count = 1;
            }
            s.recent_column = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .gap = 5, .children = s.recent_children[0..recent_count] };
            s.children = .{ s.title.widget(), s.grid_size.widget(), s.upcoming_title.widget(), s.upcoming_empty.widget(), s.recent_title.widget(), s.recent_column.widget() };
            s.column = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .gap = 10, .children = &s.children };
            s.padding = .{ .insets = phantom.LogicalEdgeInsets.all(18), .child = s.column.widget() };
            s.box = .{ .color = alpha(theme.colors.bg_dark, 0.97), .radius = theme.radius, .border_color = alpha(theme.colors.fg_dim, 0.65), .border_width = 1, .child = s.padding.widget() };
            s.size = .{ .width = 352, .height = 486, .child = s.box.widget() };
            s.panel_align = .{ .alignment = .top_center, .child = s.size.widget() };
            s.layers[1] = s.panel_align.widget();
            s.stack = .{ .children = &s.layers };
            return s.stack.widget();
        }
    };

    pub fn widget(self: *const CalendarPanel) phantom.Widget {
        return phantom.StatefulWidget(CalendarPanel, self);
    }
};
