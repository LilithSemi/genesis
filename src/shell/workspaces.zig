const phantom = @import("phantom");

pub const WorkspaceSwitcher = struct {
    active: u8 = 0,
    on_select: ?*const fn (*anyopaque, u8) void = null,
    on_minimize: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,

    const Target = struct { config: *const WorkspaceSwitcher, index: u8 };

    pub const State = struct {
        base: phantom.StateBase = .{},
        config: WorkspaceSwitcher = .{},
        targets: [4]Target = undefined,
        labels: [4]phantom.Text = undefined,
        buttons: [4]phantom.Button = undefined,
        minimize_label: phantom.Text = undefined,
        minimize_button: phantom.Button = undefined,
        children: [5]phantom.Widget = undefined,
        row: phantom.Flex = undefined,
        padding: phantom.Padding = undefined,
        box: phantom.DecoratedBox = undefined,
        size: phantom.SizedBox = undefined,

        pub fn initState(s: *@This(), config: *const WorkspaceSwitcher) anyerror!void {
            s.config = config.*;
        }
        pub fn didUpdateWidget(s: *@This(), config: *const WorkspaceSwitcher) anyerror!void {
            s.config = config.*;
        }

        fn select(ctx: *anyopaque) void {
            const target: *Target = @ptrCast(@alignCast(ctx));
            if (target.config.on_select) |callback| callback(target.config.ctx, target.index);
        }

        fn minimize(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.config.on_minimize) |callback| callback(s.config.ctx);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            for (0..4) |index| {
                const label = switch (index) {
                    0 => "1",
                    1 => "2",
                    2 => "3",
                    else => "4",
                };
                s.labels[index] = .{ .text = label, .size = 13, .font = theme.body_bold_font, .color = if (index == s.config.active) theme.colors.bg_dark else theme.colors.fg_primary };
                s.targets[index] = .{ .config = &s.config, .index = @intCast(index) };
                s.buttons[index] = .{ .variant = if (index == s.config.active) .primary else .secondary, .padding = phantom.LogicalEdgeInsets.symmetric(12, 6), .on_tap = select, .ctx = &s.targets[index], .child = s.labels[index].widget() };
                s.children[index] = s.buttons[index].widget();
            }
            s.minimize_label = .{ .text = "Minimize", .size = 12, .color = theme.colors.fg_primary };
            s.minimize_button = .{ .variant = .secondary, .padding = phantom.LogicalEdgeInsets.symmetric(10, 6), .on_tap = minimize, .ctx = s, .child = s.minimize_label.widget() };
            s.children[4] = s.minimize_button.widget();
            s.row = phantom.Row(.{ .main = .center, .cross = .center, .main_size = .min, .gap = 8, .children = &s.children });
            s.padding = .{ .insets = phantom.LogicalEdgeInsets.symmetric(10, 7), .child = s.row.widget() };
            s.box = .{ .color = theme.colors.bg_dark, .radius = 12, .border_color = theme.colors.fg_dim, .border_width = 1, .child = s.padding.widget() };
            s.size = .{ .width = 270, .height = 48, .child = s.box.widget() };
            return s.size.widget();
        }
    };

    pub fn widget(self: *const WorkspaceSwitcher) phantom.Widget {
        return phantom.StatefulWidget(WorkspaceSwitcher, self);
    }
};
