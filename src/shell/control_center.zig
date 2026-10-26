const std = @import("std");
const phantom = @import("phantom");
const services = @import("../services/services.zig");
const Notification = @import("../services/notifications.zig").Notification;
const Notifications = @import("../services/notifications.zig").Notifications;
const Network = @import("../services/network.zig").Network;

fn alpha(color: phantom.Color, value: f32) phantom.Color {
    var result = color;
    result.a = value;
    return result;
}

const max_cards = 32;

/// The first real control-center slice: a modal session panel backed by the
/// notification daemon. Network, audio, brightness and media controls can join
/// this surface without changing its ownership or overlay behavior.
pub const ControlCenter = struct {
    on_close: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub const State = struct {
        const DismissTarget = struct { state: *State = undefined, id: u32 = 0 };
        const NotificationActionTarget = struct { state: *State = undefined, id: u32 = 0, action: []const u8 = "" };
        const WifiTarget = struct { state: *State = undefined, id: []const u8 = "", ssid: []const u8 = "", secured: bool = false, connected: bool = false };
        const PendingAction = enum { none, logout, restart, power_off };

        base: phantom.StateBase = .{},
        ticker: phantom.Ticker = undefined,
        animation_elapsed: i96 = 0,
        on_close: ?*const fn (*anyopaque) void = null,
        ctx: *anyopaque = undefined,
        scroll_controller: phantom.ScrollController = .{},
        notification_service: Notifications = Notifications.unavailable,
        network_service: Network = Network.unavailable,
        host_platform: phantom.Platform = .{},
        audio_state: phantom.platform.Audio = .{ .output_volume = 0, .muted = false },
        pending_action: PendingAction = .none,
        network_expanded: bool = false,
        pending_wifi_id: [256]u8 = undefined,
        pending_wifi_id_len: usize = 0,
        pending_wifi_name: [64]u8 = undefined,
        pending_wifi_name_len: usize = 0,
        wifi_dialog_title_buf: [96]u8 = undefined,
        password_controller: phantom.TextFieldController = .{},

        backdrop_box: phantom.ColoredBox = undefined,
        backdrop_tap: phantom.GestureDetector = undefined,
        session_title: phantom.Text = undefined,
        session_subtitle: phantom.Text = undefined,
        session_subtitle_buf: [160]u8 = undefined,
        session_children: [2]phantom.Widget = undefined,
        session_column: phantom.Flex = undefined,
        session_size: phantom.SizedBox = undefined,
        network_title: phantom.Text = undefined,
        network_detail: phantom.Text = undefined,
        network_children: [2]phantom.Widget = undefined,
        network_column: phantom.Flex = undefined,
        network_column_size: phantom.SizedBox = undefined,
        network_switch: phantom.Switch = undefined,
        network_row_children: [2]phantom.Widget = undefined,
        network_row: phantom.Flex = undefined,
        network_padding: phantom.Padding = undefined,
        network_box: phantom.DecoratedBox = undefined,
        network_size: phantom.SizedBox = undefined,
        network_tap: phantom.GestureDetector = undefined,
        wifi_header_label: phantom.Text = undefined,
        wifi_scan_label: phantom.Text = undefined,
        wifi_scan_button: phantom.Button = undefined,
        wifi_header_children: [2]phantom.Widget = undefined,
        wifi_header: phantom.Flex = undefined,
        wifi_header_size: phantom.SizedBox = undefined,
        wifi_labels: [6]phantom.Text = undefined,
        wifi_buttons: [6]phantom.Button = undefined,
        wifi_row_sizes: [6]phantom.SizedBox = undefined,
        wifi_targets: [6]WifiTarget = undefined,
        wifi_rows: [6]phantom.Widget = undefined,
        password_field: phantom.TextField = undefined,
        password_padding: phantom.Padding = undefined,
        password_box: phantom.DecoratedBox = undefined,
        password_size: phantom.SizedBox = undefined,
        connect_label: phantom.Text = undefined,
        connect_button: phantom.Button = undefined,
        password_children: [2]phantom.Widget = undefined,
        password_row: phantom.Flex = undefined,
        password_row_size: phantom.SizedBox = undefined,
        wifi_children: [8]phantom.Widget = undefined,
        wifi_column: phantom.Flex = undefined,
        wifi_padding: phantom.Padding = undefined,
        wifi_box: phantom.DecoratedBox = undefined,
        wifi_size: phantom.SizedBox = undefined,
        power_title: phantom.Text = undefined,
        power_detail: phantom.Text = undefined,
        power_buf: [32]u8 = undefined,
        power_children: [2]phantom.Widget = undefined,
        power_column: phantom.Flex = undefined,
        power_padding: phantom.Padding = undefined,
        power_box: phantom.DecoratedBox = undefined,
        power_size: phantom.SizedBox = undefined,
        quick_children: [2]phantom.Widget = undefined,
        quick_row: phantom.Flex = undefined,
        quick_size: phantom.SizedBox = undefined,
        audio_title: phantom.Text = undefined,
        audio_slider: phantom.Slider = undefined,
        audio_switch: phantom.Switch = undefined,
        audio_children: [3]phantom.Widget = undefined,
        audio_row: phantom.Flex = undefined,
        audio_padding: phantom.Padding = undefined,
        audio_box: phantom.DecoratedBox = undefined,
        audio_size: phantom.SizedBox = undefined,
        brightness_title: phantom.Text = undefined,
        brightness_slider: phantom.Slider = undefined,
        brightness_children: [2]phantom.Widget = undefined,
        brightness_row: phantom.Flex = undefined,
        brightness_padding: phantom.Padding = undefined,
        brightness_box: phantom.DecoratedBox = undefined,
        brightness_size: phantom.SizedBox = undefined,
        action_labels: [5]phantom.Text = undefined,
        action_buttons: [5]phantom.Button = undefined,
        action_widgets: [5]phantom.Widget = undefined,
        action_row: phantom.Flex = undefined,
        action_size: phantom.SizedBox = undefined,
        title: phantom.Text = undefined,
        clear_label: phantom.Text = undefined,
        clear_button: phantom.Button = undefined,
        header_children: [2]phantom.Widget = undefined,
        header: phantom.Flex = undefined,
        header_size: phantom.SizedBox = undefined,
        app_labels: [max_cards]phantom.Text = undefined,
        dismiss_labels: [max_cards]phantom.Text = undefined,
        dismiss_buttons: [max_cards]phantom.Button = undefined,
        dismiss_targets: [max_cards]DismissTarget = undefined,
        card_header_children: [max_cards][2]phantom.Widget = undefined,
        card_headers: [max_cards]phantom.Flex = undefined,
        card_header_sizes: [max_cards]phantom.SizedBox = undefined,
        summaries: [max_cards]phantom.Text = undefined,
        bodies: [max_cards]phantom.Text = undefined,
        notification_action_labels: [max_cards][2]phantom.Text = undefined,
        notification_action_buttons: [max_cards][2]phantom.Button = undefined,
        notification_action_targets: [max_cards][2]NotificationActionTarget = undefined,
        notification_action_children: [max_cards][2]phantom.Widget = undefined,
        notification_action_rows: [max_cards]phantom.Flex = undefined,
        card_children: [max_cards][4]phantom.Widget = undefined,
        card_columns: [max_cards]phantom.Flex = undefined,
        card_padding: [max_cards]phantom.Padding = undefined,
        card_boxes: [max_cards]phantom.DecoratedBox = undefined,
        card_sizes: [max_cards]phantom.SizedBox = undefined,
        cards: [max_cards]phantom.Widget = undefined,
        empty: phantom.Text = undefined,
        card_column: phantom.Flex = undefined,
        scroll: phantom.ScrollView = undefined,
        scroll_size: phantom.SizedBox = undefined,
        panel_children: [8]phantom.Widget = undefined,
        panel_column: phantom.Flex = undefined,
        panel_padding: phantom.Padding = undefined,
        panel_box: phantom.DecoratedBox = undefined,
        panel_size: phantom.SizedBox = undefined,
        panel_outer_padding: phantom.Padding = undefined,
        panel_align: phantom.Align = undefined,
        panel_translate: phantom.Translate = undefined,
        layers: [2]phantom.Widget = undefined,
        stack: phantom.Stack = undefined,
        dialog_title: phantom.Text = undefined,
        dialog_body: phantom.Text = undefined,
        dialog_cancel_label: phantom.Text = undefined,
        dialog_confirm_label: phantom.Text = undefined,
        dialog_cancel: phantom.Button = undefined,
        dialog_confirm: phantom.Button = undefined,
        dialog_action_children: [2]phantom.Widget = undefined,
        dialog_actions: phantom.Flex = undefined,
        dialog_actions_size: phantom.SizedBox = undefined,
        dialog_children: [4]phantom.Widget = undefined,
        dialog_column: phantom.Flex = undefined,
        dialog_padding: phantom.Padding = undefined,
        dialog_box: phantom.DecoratedBox = undefined,
        dialog_size: phantom.SizedBox = undefined,
        dialog_guard: phantom.GestureDetector = undefined,
        dialog_align: phantom.Align = undefined,
        root_layers: [2]phantom.Widget = undefined,
        root_stack: phantom.Stack = undefined,

        fn take(s: *@This(), config: *const ControlCenter) void {
            s.on_close = config.on_close;
            s.ctx = config.ctx;
        }

        pub fn initState(s: *@This(), config: *const ControlCenter) anyerror!void {
            s.take(config);
            s.ticker = .{ .scheduler = s.base.scheduler(), .ctx = s, .on_tick = onFrame };
            try s.ticker.start(s.base.gpa());
        }

        pub fn dispose(s: *@This()) void {
            s.ticker.deinit();
        }

        fn onFrame(ctx: *anyopaque, elapsed: phantom.Ticker.Nanos) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.animation_elapsed = elapsed;
            phantom.markNeedsBuild(s);
            if (elapsed >= 260 * std.time.ns_per_ms) s.ticker.stop();
        }

        pub fn didUpdateWidget(s: *@This(), config: *const ControlCenter) anyerror!void {
            s.take(config);
        }

        fn clear(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.notification_service.clear();
        }

        fn dismiss(ctx: *anyopaque) void {
            const target: *DismissTarget = @ptrCast(@alignCast(ctx));
            target.state.notification_service.dismiss(target.id);
        }

        fn invokeNotificationAction(ctx: *anyopaque) void {
            const target: *NotificationActionTarget = @ptrCast(@alignCast(ctx));
            target.state.notification_service.invoke(target.id, target.action);
        }

        fn toggleWifi(ctx: *anyopaque, enabled: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            _ = s.network_service.setWifiEnabled(enabled);
        }

        fn toggleNetworks(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.network_expanded = !s.network_expanded;
            if (s.network_expanded) _ = s.network_service.requestWifiScan();
            phantom.markNeedsBuild(s);
        }

        fn scanNetworks(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            _ = s.network_service.requestWifiScan();
            phantom.markNeedsBuild(s);
        }

        fn chooseNetwork(ctx: *anyopaque) void {
            const target: *WifiTarget = @ptrCast(@alignCast(ctx));
            if (target.connected) {
                _ = target.state.network_service.disconnectWifi(target.id);
            } else if (target.secured) {
                target.state.pending_wifi_id_len = @min(target.id.len, target.state.pending_wifi_id.len);
                @memcpy(target.state.pending_wifi_id[0..target.state.pending_wifi_id_len], target.id[0..target.state.pending_wifi_id_len]);
                target.state.pending_wifi_name_len = @min(target.ssid.len, target.state.pending_wifi_name.len);
                @memcpy(target.state.pending_wifi_name[0..target.state.pending_wifi_name_len], target.ssid[0..target.state.pending_wifi_name_len]);
                target.state.password_controller.setText("") catch {};
            } else {
                _ = target.state.network_service.connectWifi(target.id, "");
            }
            phantom.markNeedsBuild(target.state);
        }

        fn connectProtectedNetwork(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.pending_wifi_id_len == 0) return;
            if (s.network_service.connectWifi(s.pending_wifi_id[0..s.pending_wifi_id_len], s.password_controller.text())) {
                s.pending_wifi_id_len = 0;
                s.pending_wifi_name_len = 0;
                s.password_controller.setText("") catch {};
            }
            phantom.markNeedsBuild(s);
        }

        fn cancelProtectedNetwork(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.pending_wifi_id_len = 0;
            s.pending_wifi_name_len = 0;
            s.password_controller.setText("") catch {};
            phantom.markNeedsBuild(s);
        }

        fn changeVolume(ctx: *anyopaque, value: f32) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.host_platform.setAudio(.{ .output_volume = value, .muted = s.audio_state.muted })) phantom.markNeedsBuild(s);
        }

        fn toggleSound(ctx: *anyopaque, enabled: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.host_platform.setAudio(.{ .output_volume = s.audio_state.output_volume, .muted = !enabled })) phantom.markNeedsBuild(s);
        }

        fn changeBrightness(ctx: *anyopaque, value: f32) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.host_platform.setBrightness(.{ .level = value })) phantom.markNeedsBuild(s);
        }

        fn finishAction(s: *@This(), succeeded: bool) void {
            if (succeeded) if (s.on_close) |close| close(s.ctx);
        }

        fn lock(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.finishAction(s.host_platform.lockSession());
        }

        fn logout(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.pending_action = .logout;
            phantom.markNeedsBuild(s);
        }

        fn suspendAction(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.finishAction(s.host_platform.suspendSession());
        }

        fn restart(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.pending_action = .restart;
            phantom.markNeedsBuild(s);
        }

        fn powerOff(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.pending_action = .power_off;
            phantom.markNeedsBuild(s);
        }

        fn cancelAction(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.pending_action = .none;
            phantom.markNeedsBuild(s);
        }

        fn confirmAction(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            const action = s.pending_action;
            s.pending_action = .none;
            const succeeded = switch (action) {
                .logout => s.host_platform.logoutSession(),
                .restart => s.host_platform.restartSystem(),
                .power_off => s.host_platform.powerOffSystem(),
                .none => false,
            };
            s.finishAction(succeeded);
            if (!succeeded) phantom.markNeedsBuild(s);
        }

        fn absorbTap(_: *anyopaque) void {}

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const viewport = phantom.MediaQuery.of(b).size;
            s.host_platform = b.owner.platform;
            const notification_service = services.ServicesScope.of(b).notifications;
            s.notification_service = notification_service;
            const notifications = switch (notification_service.read()) {
                .ok => |items| items,
                else => &.{},
            };
            const visibility = (phantom.Tween(f32){ .begin = 0, .end = 1, .curve = .ease_out_cubic }).atTime(s.animation_elapsed, 260 * std.time.ns_per_ms);

            s.backdrop_box = .{ .color = alpha(theme.colors.bg_dark, 0.58 * visibility), .radius = 0 };
            s.backdrop_tap = .{ .on_tap = s.on_close, .ctx = s.ctx, .child = s.backdrop_box.widget() };
            s.layers[0] = s.backdrop_tap.widget();

            const identity = b.owner.platform.readIdentity();
            const user_name = if (identity) |value| value.display_name orelse value.user_name else "User";
            const system_name = if (identity) |value| value.system_name else "System";
            const subtitle = std.fmt.bufPrint(&s.session_subtitle_buf, "{s} · Genesis", .{system_name}) catch "Genesis";
            s.session_title = .{ .text = user_name, .size = 22, .font = theme.body_bold_font, .color = theme.colors.fg };
            s.session_subtitle = .{ .text = subtitle, .size = 13, .color = theme.colors.fg_muted };
            s.session_children = .{ s.session_title.widget(), s.session_subtitle.widget() };
            s.session_column = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .gap = 3, .children = &s.session_children };
            s.session_size = .{ .width = 318, .height = 48, .child = s.session_column.widget() };
            var panel_count: usize = 0;
            s.panel_children[panel_count] = s.session_size.widget();
            panel_count += 1;

            const network_service = services.ServicesScope.of(b).network;
            s.network_service = network_service;
            const network_reading = network_service.read();
            const network_detail = switch (network_reading) {
                .ok => |state| switch (state.kind) {
                    .none => "Offline",
                    .ethernet => "Ethernet connected",
                    .wifi => "Connected",
                    .cellular => "Cellular connected",
                },
                .pending => "Checking…",
                .unsupported, .unavailable => "Unavailable",
            };
            s.network_title = .{ .text = "Wi-Fi", .size = 14, .font = theme.body_bold_font, .color = theme.colors.fg };
            s.network_detail = .{ .text = network_detail, .size = 11, .color = if (network_reading.shows()) theme.accent else theme.colors.fg_muted };
            s.network_children = .{ s.network_title.widget(), s.network_detail.widget() };
            s.network_column = .{ .direction = .vertical, .main = .center, .cross = .start, .main_size = .min, .gap = 4, .children = &s.network_children };
            s.network_column_size = .{ .width = 78, .height = 46, .child = s.network_column.widget() };
            s.network_switch = .{
                .value = switch (network_reading) {
                    .ok => |state| state.wifi_enabled,
                    else => false,
                },
                .enabled = switch (network_reading) {
                    .ok => network_service.canSetWifi(),
                    else => false,
                },
                .width = 38,
                .height = 22,
                .label = "Wi-Fi",
                .on_changed = toggleWifi,
                .ctx = s,
            };
            s.network_row_children = .{ s.network_column_size.widget(), s.network_switch.widget() };
            s.network_row = phantom.Row(.{ .main = .space_between, .cross = .center, .children = &s.network_row_children });
            s.network_padding = .{ .insets = phantom.LogicalEdgeInsets.symmetric(10, 9), .child = s.network_row.widget() };
            s.network_box = .{ .color = alpha(theme.colors.bg_medium, 0.86), .radius = 10, .border_color = alpha(theme.colors.fg_dim, 0.42), .border_width = 1, .child = s.network_padding.widget() };
            s.network_size = .{ .width = 154, .height = 64, .child = s.network_box.widget() };
            s.network_tap = .{ .on_tap = toggleNetworks, .ctx = s, .child = s.network_size.widget() };

            const primary = services.ServicesScope.of(b).battery.primary();
            const power_detail = if (primary) |device|
                std.fmt.bufPrint(&s.power_buf, "{d}% · {s}", .{ device.percent, switch (device.status) {
                    .charging => "Charging",
                    .discharging => "Battery",
                    .full => "Full",
                    .empty => "Empty",
                    .unknown => "Unknown",
                } }) catch "Battery"
            else
                "No system battery";
            s.power_title = .{ .text = "Power", .size = 14, .font = theme.body_bold_font, .color = theme.colors.fg };
            s.power_detail = .{ .text = power_detail, .size = 11, .color = if (primary != null) theme.accent else theme.colors.fg_muted };
            s.power_children = .{ s.power_title.widget(), s.power_detail.widget() };
            s.power_column = .{ .direction = .vertical, .main = .center, .cross = .start, .main_size = .min, .gap = 4, .children = &s.power_children };
            s.power_padding = .{ .insets = phantom.LogicalEdgeInsets.symmetric(12, 9), .child = s.power_column.widget() };
            s.power_box = .{ .color = alpha(theme.colors.bg_medium, 0.86), .radius = 10, .border_color = alpha(theme.colors.fg_dim, 0.42), .border_width = 1, .child = s.power_padding.widget() };
            s.power_size = .{ .width = 154, .height = 64, .child = s.power_box.widget() };
            s.quick_children = .{ s.network_tap.widget(), s.power_size.widget() };
            s.quick_row = phantom.Row(.{ .main = .space_between, .cross = .center, .children = &s.quick_children });
            s.quick_size = .{ .width = 318, .height = 64, .child = s.quick_row.widget() };
            s.panel_children[panel_count] = s.quick_size.widget();
            panel_count += 1;

            var network_panel_height: f32 = 0;
            if (s.network_expanded) {
                s.wifi_header_label = .{ .text = "Available networks", .size = 14, .font = theme.body_bold_font, .color = theme.colors.fg };
                s.wifi_scan_label = .{ .text = "Scan", .size = 12, .color = theme.accent };
                s.wifi_scan_button = .{ .variant = .secondary, .padding = phantom.LogicalEdgeInsets.symmetric(9, 3), .on_tap = scanNetworks, .ctx = s, .child = s.wifi_scan_label.widget() };
                s.wifi_header_children = .{ s.wifi_header_label.widget(), s.wifi_scan_button.widget() };
                s.wifi_header = phantom.Row(.{ .main = .space_between, .cross = .center, .children = &s.wifi_header_children });
                // A horizontal Flex expands across its bounded cross axis. In
                // this vertical column it therefore needs an explicit height,
                // or it consumes the entire network panel and lays AP rows on
                // top of the controls below it.
                s.wifi_header_size = .{ .width = 298, .height = 30, .child = s.wifi_header.widget() };
                s.wifi_children[0] = s.wifi_header_size.widget();
                var wifi_child_count: usize = 1;
                const wifi_reading = network_service.wifiNetworks();
                const networks = switch (wifi_reading) {
                    .ok => |items| items,
                    else => &.{},
                };
                for (networks[0..@min(networks.len, 6)], 0..) |network, index| {
                    const suffix = if (network.connected) "  Connected" else if (network.security == .secured) "  Secured" else "  Open";
                    const label = try std.fmt.allocPrint(b.arena, "{s}  {d}%{s}", .{ network.ssid, network.strength, suffix });
                    s.wifi_labels[index] = .{ .text = label, .size = 12, .color = if (network.connected) theme.accent else theme.colors.fg_primary };
                    s.wifi_targets[index] = .{ .state = s, .id = network.id, .ssid = network.ssid, .secured = network.security == .secured, .connected = network.connected };
                    s.wifi_buttons[index] = .{ .variant = .secondary, .padding = phantom.LogicalEdgeInsets.symmetric(10, 5), .on_tap = chooseNetwork, .ctx = &s.wifi_targets[index], .child = s.wifi_labels[index].widget() };
                    s.wifi_row_sizes[index] = .{ .width = 298, .height = 30, .child = s.wifi_buttons[index].widget() };
                    s.wifi_rows[index] = s.wifi_row_sizes[index].widget();
                    s.wifi_children[wifi_child_count] = s.wifi_rows[index];
                    wifi_child_count += 1;
                }
                if (networks.len == 0) {
                    s.wifi_labels[0] = .{ .text = switch (wifi_reading) {
                        .ok => "No Wi-Fi networks found",
                        .pending => "Scanning for Wi-Fi networks…",
                        .unsupported => "Wi-Fi scanning is unsupported",
                        .unavailable => "No Wi-Fi adapter available",
                    }, .size = 12, .color = theme.colors.fg_muted };
                    s.wifi_children[wifi_child_count] = s.wifi_labels[0].widget();
                    wifi_child_count += 1;
                }
                s.wifi_column = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .gap = 5, .children = s.wifi_children[0..wifi_child_count] };
                s.wifi_padding = .{ .insets = phantom.LogicalEdgeInsets.all(10), .child = s.wifi_column.widget() };
                s.wifi_box = .{ .color = alpha(theme.colors.bg_medium, 0.72), .radius = 10, .child = s.wifi_padding.widget() };
                const visible_networks = @min(networks.len, 6);
                const child_total: usize = 1 + @max(visible_networks, 1);
                network_panel_height = 20 + 30 +
                    @as(f32, @floatFromInt(@max(visible_networks, 1))) * 30 +
                    @as(f32, @floatFromInt(child_total - 1)) * 5;
                s.wifi_size = .{ .width = 318, .height = @max(82, network_panel_height), .child = s.wifi_box.widget() };
                s.panel_children[panel_count] = s.wifi_size.widget();
                panel_count += 1;
            }

            var optional_height: f32 = 0;
            if (b.owner.platform.readAudio()) |audio| {
                s.audio_state = audio;
                s.audio_title = .{ .text = "Volume", .size = 13, .font = theme.body_bold_font, .color = theme.colors.fg };
                s.audio_slider = .{ .value = audio.output_volume, .width = 190, .height = 28, .label = "Output volume", .on_changed = changeVolume, .ctx = s };
                s.audio_switch = .{ .value = !audio.muted, .width = 40, .height = 22, .label = "Sound", .on_changed = toggleSound, .ctx = s };
                s.audio_children = .{ s.audio_title.widget(), s.audio_slider.widget(), s.audio_switch.widget() };
                s.audio_row = phantom.Row(.{ .main = .space_between, .cross = .center, .children = &s.audio_children });
                s.audio_padding = .{ .insets = phantom.LogicalEdgeInsets.symmetric(10, 5), .child = s.audio_row.widget() };
                s.audio_box = .{ .color = alpha(theme.colors.bg_medium, 0.72), .radius = 10, .child = s.audio_padding.widget() };
                s.audio_size = .{ .width = 318, .height = 40, .child = s.audio_box.widget() };
                s.panel_children[panel_count] = s.audio_size.widget();
                panel_count += 1;
                optional_height += 50;
            }

            if (b.owner.platform.readBrightness()) |brightness| {
                s.brightness_title = .{ .text = "Brightness", .size = 13, .font = theme.body_bold_font, .color = theme.colors.fg };
                s.brightness_slider = .{ .value = brightness.level, .width = 220, .height = 28, .label = "Display brightness", .on_changed = changeBrightness, .ctx = s };
                s.brightness_children = .{ s.brightness_title.widget(), s.brightness_slider.widget() };
                s.brightness_row = phantom.Row(.{ .main = .space_between, .cross = .center, .children = &s.brightness_children });
                s.brightness_padding = .{ .insets = phantom.LogicalEdgeInsets.symmetric(10, 5), .child = s.brightness_row.widget() };
                s.brightness_box = .{ .color = alpha(theme.colors.bg_medium, 0.72), .radius = 10, .child = s.brightness_padding.widget() };
                s.brightness_size = .{ .width = 318, .height = 40, .child = s.brightness_box.widget() };
                s.panel_children[panel_count] = s.brightness_size.widget();
                panel_count += 1;
                optional_height += 50;
            }

            const capabilities = b.owner.platform.sessionCapabilities();
            var action_count: usize = 0;
            const action_names = [_][]const u8{ "Lock", "Log out", "Suspend", "Restart", "Power" };
            const action_callbacks = [_]*const fn (*anyopaque) void{ lock, logout, suspendAction, restart, powerOff };
            const action_enabled = [_]bool{ capabilities.lock, capabilities.logout, capabilities.can_suspend, capabilities.restart, capabilities.power_off };
            for (action_names, action_callbacks, action_enabled) |name, callback, enabled| {
                if (!enabled) continue;
                s.action_labels[action_count] = .{ .text = name, .size = 11, .color = theme.colors.fg_primary };
                s.action_buttons[action_count] = .{ .variant = .secondary, .padding = phantom.LogicalEdgeInsets.symmetric(8, 6), .on_tap = callback, .ctx = s, .child = s.action_labels[action_count].widget() };
                s.action_widgets[action_count] = s.action_buttons[action_count].widget();
                action_count += 1;
            }
            if (action_count > 0) {
                s.action_row = phantom.Row(.{ .main = .space_between, .cross = .center, .children = s.action_widgets[0..action_count] });
                s.action_size = .{ .width = 318, .height = 38, .child = s.action_row.widget() };
                s.panel_children[panel_count] = s.action_size.widget();
                panel_count += 1;
                optional_height += 48;
            }

            s.title = .{ .text = "Notifications", .size = 18, .font = theme.body_bold_font, .color = theme.colors.fg };
            s.clear_label = .{ .text = "Clear", .size = 14, .color = theme.accent };
            s.clear_button = .{
                .variant = .secondary,
                .padding = phantom.LogicalEdgeInsets.symmetric(12, 6),
                .enabled = notifications.len > 0,
                .on_tap = clear,
                .ctx = s,
                .child = s.clear_label.widget(),
            };
            s.header_children = .{ s.title.widget(), s.clear_button.widget() };
            s.header = phantom.Row(.{
                .main = .space_between,
                .cross = .center,
                .children = &s.header_children,
            });
            // A horizontal Flex fills its bounded cross axis. Without this
            // explicit height the header consumes the complete panel height
            // and the notification history is laid out below the viewport.
            s.header_size = .{ .width = 318, .height = 38, .child = s.header.widget() };
            s.panel_children[panel_count] = s.header_size.widget();
            panel_count += 1;

            var count: usize = 0;
            while (count < @min(notifications.len, max_cards)) : (count += 1) {
                const notification = notifications[notifications.len - 1 - count];
                const app_name = if (notification.app_name.len > 0) notification.app_name else "Application";
                s.app_labels[count] = .{ .text = app_name, .size = 12, .font = theme.body_bold_font, .color = theme.accent };
                s.dismiss_labels[count] = .{ .text = "×", .size = 14, .color = theme.colors.fg_muted };
                s.dismiss_targets[count] = .{ .state = s, .id = notification.id };
                s.dismiss_buttons[count] = .{
                    .variant = .secondary,
                    .padding = phantom.LogicalEdgeInsets.symmetric(7, 1),
                    .on_tap = dismiss,
                    .ctx = &s.dismiss_targets[count],
                    .child = s.dismiss_labels[count].widget(),
                };
                s.card_header_children[count] = .{ s.app_labels[count].widget(), s.dismiss_buttons[count].widget() };
                s.card_headers[count] = phantom.Row(.{ .main = .space_between, .cross = .center, .children = &s.card_header_children[count] });
                s.card_header_sizes[count] = .{ .width = 294, .height = 18, .child = s.card_headers[count].widget() };
                s.summaries[count] = .{ .text = notification.summary, .size = 15, .font = theme.body_bold_font, .color = theme.colors.fg };
                s.bodies[count] = .{ .text = notification.body, .size = 13, .color = theme.colors.fg_primary };
                s.card_children[count][0] = s.card_header_sizes[count].widget();
                s.card_children[count][1] = s.summaries[count].widget();
                s.card_children[count][2] = s.bodies[count].widget();
                var card_child_count: usize = 3;
                const shown_actions = @min(notification.actions.len, 2);
                if (shown_actions > 0) {
                    for (notification.actions[0..shown_actions], 0..) |action, action_index| {
                        s.notification_action_labels[count][action_index] = .{ .text = action.label, .size = 12, .font = theme.body_bold_font, .color = theme.accent };
                        s.notification_action_targets[count][action_index] = .{ .state = s, .id = notification.id, .action = action.key };
                        s.notification_action_buttons[count][action_index] = .{
                            .variant = .secondary,
                            .padding = phantom.LogicalEdgeInsets.symmetric(10, 4),
                            .on_tap = invokeNotificationAction,
                            .ctx = &s.notification_action_targets[count][action_index],
                            .child = s.notification_action_labels[count][action_index].widget(),
                        };
                        s.notification_action_children[count][action_index] = s.notification_action_buttons[count][action_index].widget();
                    }
                    s.notification_action_rows[count] = phantom.Row(.{ .main = .start, .cross = .center, .gap = 8, .children = s.notification_action_children[count][0..shown_actions] });
                    s.card_children[count][card_child_count] = s.notification_action_rows[count].widget();
                    card_child_count += 1;
                }
                s.card_columns[count] = .{
                    .direction = .vertical,
                    .main = .start,
                    .cross = .start,
                    .main_size = .min,
                    .gap = 4,
                    .children = s.card_children[count][0..card_child_count],
                };
                s.card_padding[count] = .{ .insets = phantom.LogicalEdgeInsets.all(12), .child = s.card_columns[count].widget() };
                s.card_boxes[count] = .{
                    .color = alpha(theme.colors.bg_medium, 0.86),
                    .radius = theme.radius * 0.62,
                    .border_color = alpha(theme.colors.fg_dim, 0.48),
                    .border_width = 1,
                    .child = s.card_padding[count].widget(),
                };
                s.card_sizes[count] = .{ .width = 318, .height = if (shown_actions > 0) 122 else 86, .child = s.card_boxes[count].widget() };
                s.cards[count] = s.card_sizes[count].widget();
            }
            if (count == 0) {
                s.empty = .{ .text = "No notifications", .size = 15, .color = theme.colors.fg_muted };
                s.cards[0] = s.empty.widget();
                count = 1;
            }
            s.card_column = .{
                .direction = .vertical,
                .main = .start,
                .cross = .start,
                .main_size = .min,
                .gap = 9,
                .children = s.cards[0..count],
            };
            s.scroll = .{ .child = s.card_column.widget(), .controller = &s.scroll_controller, .id = "notification-history" };
            const panel_height = @max(@as(f32, 240), viewport.height - 60);
            // Keep the history within the panel's padded content box: 32px of
            // panel padding, the 38px header and the 14px column gap.
            s.scroll_size = .{ .width = 318, .height = @max(60, panel_height - 214 - optional_height - network_panel_height), .child = s.scroll.widget() };
            s.panel_children[panel_count] = s.scroll_size.widget();
            panel_count += 1;
            s.panel_column = .{
                .direction = .vertical,
                .main = .start,
                .cross = .start,
                .main_size = .min,
                .gap = 10,
                .children = s.panel_children[0..panel_count],
            };
            s.panel_padding = .{ .insets = phantom.LogicalEdgeInsets.all(16), .child = s.panel_column.widget() };
            s.panel_box = .{
                .color = alpha(theme.colors.bg_dark, 0.96),
                .radius = theme.radius,
                .border_color = alpha(theme.colors.fg_dim, 0.65),
                .border_width = 1,
                .child = s.panel_padding.widget(),
            };
            s.panel_size = .{ .width = 350, .height = panel_height, .child = s.panel_box.widget() };
            s.panel_outer_padding = .{ .insets = .{ .top = 8, .right = 8 }, .child = s.panel_size.widget() };
            s.panel_translate = .{ .offset = .{ .x = (1 - visibility) * 24, .y = 0 }, .child = s.panel_outer_padding.widget() };
            s.panel_align = .{ .alignment = .top_right, .child = s.panel_translate.widget() };
            s.layers[1] = s.panel_align.widget();
            s.stack = .{ .children = &s.layers };
            s.root_layers[0] = s.stack.widget();
            var root_count: usize = 1;
            if (s.pending_action != .none) {
                const DialogCopy = struct { title: []const u8, body: []const u8, confirm: []const u8 };
                const copy: DialogCopy = switch (s.pending_action) {
                    .logout => .{ .title = "Log out?", .body = "Applications in this Genesis session will be closed.", .confirm = "Log out" },
                    .restart => .{ .title = "Restart the system?", .body = "All running applications will be closed.", .confirm = "Restart" },
                    .power_off => .{ .title = "Power off the system?", .body = "All running applications will be closed.", .confirm = "Power off" },
                    .none => unreachable,
                };
                s.dialog_title = .{ .text = copy.title, .size = 19, .font = theme.body_bold_font, .color = theme.colors.fg };
                s.dialog_body = .{ .text = copy.body, .size = 13, .color = theme.colors.fg_primary };
                s.dialog_cancel_label = .{ .text = "Cancel", .size = 13, .color = theme.colors.fg_primary };
                s.dialog_confirm_label = .{ .text = copy.confirm, .size = 13, .font = theme.body_bold_font, .color = theme.colors.bg_dark };
                s.dialog_cancel = .{ .variant = .secondary, .on_tap = cancelAction, .ctx = s, .child = s.dialog_cancel_label.widget() };
                s.dialog_confirm = .{ .variant = .primary, .on_tap = confirmAction, .ctx = s, .child = s.dialog_confirm_label.widget() };
                s.dialog_action_children = .{ s.dialog_cancel.widget(), s.dialog_confirm.widget() };
                s.dialog_actions = phantom.Row(.{ .main = .end, .cross = .center, .gap = 10, .children = &s.dialog_action_children });
                s.dialog_actions_size = .{ .width = 320, .height = 36, .child = s.dialog_actions.widget() };
                s.dialog_children[0] = s.dialog_title.widget();
                s.dialog_children[1] = s.dialog_body.widget();
                s.dialog_children[2] = s.dialog_actions_size.widget();
                s.dialog_column = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .gap = 14, .children = s.dialog_children[0..3] };
                s.dialog_padding = .{ .insets = phantom.LogicalEdgeInsets.all(20), .child = s.dialog_column.widget() };
                s.dialog_box = .{ .color = theme.colors.bg_dark, .radius = 14, .border_color = theme.colors.fg_dim, .border_width = 1, .child = s.dialog_padding.widget() };
                s.dialog_size = .{ .width = 360, .height = 154, .child = s.dialog_box.widget() };
                s.dialog_guard = .{ .on_tap = absorbTap, .ctx = s, .child = s.dialog_size.widget() };
                s.dialog_align = .{ .alignment = .center, .child = s.dialog_guard.widget() };
                s.root_layers[root_count] = s.dialog_align.widget();
                root_count += 1;
            } else if (s.pending_wifi_id_len > 0) {
                const wifi_name = s.pending_wifi_name[0..s.pending_wifi_name_len];
                const title_text = std.fmt.bufPrint(&s.wifi_dialog_title_buf, "Connect to {s}", .{wifi_name}) catch "Connect to Wi-Fi";
                s.dialog_title = .{ .text = title_text, .size = 19, .font = theme.body_bold_font, .color = theme.colors.fg };
                s.dialog_body = .{ .text = "Enter the network password.", .size = 13, .color = theme.colors.fg_primary };
                s.password_field = .{ .placeholder = "Wi-Fi password", .obscure = true, .id = "wifi-password", .autofocus = true, .controller = &s.password_controller };
                s.password_padding = .{ .insets = phantom.LogicalEdgeInsets.symmetric(11, 7), .child = s.password_field.widget() };
                s.password_box = .{ .color = theme.colors.bg, .radius = 8, .border_color = theme.colors.fg_dim, .border_width = 1, .child = s.password_padding.widget() };
                s.password_size = .{ .width = 320, .height = 40, .child = s.password_box.widget() };
                s.dialog_cancel_label = .{ .text = "Cancel", .size = 13, .color = theme.colors.fg_primary };
                s.dialog_confirm_label = .{ .text = "Connect", .size = 13, .font = theme.body_bold_font, .color = theme.colors.bg_dark };
                s.dialog_cancel = .{ .variant = .secondary, .on_tap = cancelProtectedNetwork, .ctx = s, .child = s.dialog_cancel_label.widget() };
                s.dialog_confirm = .{ .variant = .primary, .on_tap = connectProtectedNetwork, .ctx = s, .child = s.dialog_confirm_label.widget() };
                s.dialog_action_children = .{ s.dialog_cancel.widget(), s.dialog_confirm.widget() };
                s.dialog_actions = phantom.Row(.{ .main = .end, .cross = .center, .gap = 10, .children = &s.dialog_action_children });
                s.dialog_actions_size = .{ .width = 320, .height = 36, .child = s.dialog_actions.widget() };
                s.dialog_children = .{ s.dialog_title.widget(), s.dialog_body.widget(), s.password_size.widget(), s.dialog_actions_size.widget() };
                s.dialog_column = .{ .direction = .vertical, .main = .start, .cross = .start, .main_size = .min, .gap = 12, .children = &s.dialog_children };
                s.dialog_padding = .{ .insets = phantom.LogicalEdgeInsets.all(20), .child = s.dialog_column.widget() };
                s.dialog_box = .{ .color = theme.colors.bg_dark, .radius = 14, .border_color = theme.colors.fg_dim, .border_width = 1, .child = s.dialog_padding.widget() };
                s.dialog_size = .{ .width = 360, .height = 206, .child = s.dialog_box.widget() };
                s.dialog_guard = .{ .on_tap = absorbTap, .ctx = s, .child = s.dialog_size.widget() };
                s.dialog_align = .{ .alignment = .center, .child = s.dialog_guard.widget() };
                s.root_layers[root_count] = s.dialog_align.widget();
                root_count += 1;
            }
            s.root_stack = .{ .children = s.root_layers[0..root_count] };
            return s.root_stack.widget();
        }
    };

    pub fn widget(self: *const ControlCenter) phantom.Widget {
        return phantom.StatefulWidget(ControlCenter, self);
    }
};

const test_notifications = [_]Notification{
    .{
        .id = 7,
        .app_name = "Mail",
        .app_icon = "",
        .summary = "A real notification",
        .body = "Delivered over the session bus",
        .created_ns = 1,
    },
};
var test_notification_target: u8 = 0;

fn readTestNotifications(_: *anyopaque) services.Reading([]const Notification) {
    return .{ .ok = &test_notifications };
}

fn dismissTestNotification(_: *anyopaque, _: u32) void {}
fn clearTestNotifications(_: *anyopaque) void {}
fn invokeTestNotification(_: *anyopaque, _: u32, _: []const u8) void {}

const test_notifications_vtable = Notifications.VTable{
    .read = readTestNotifications,
    .dismiss = dismissTestNotification,
    .clear = clearTestNotifications,
    .invoke = invokeTestNotification,
};

test "control center renders notification history supplied by the session service" {
    var service_set = services.Services{
        .notifications = .{ .ptr = &test_notification_target, .vtable = &test_notifications_vtable },
    };
    var center = ControlCenter{};
    var scope = services.ServicesScope{ .services = &service_set, .child = center.widget() };
    var metrics = phantom.MediaQueryData{
        .size = .{ .width = 1512, .height = 914 },
        .dpr = 1,
    };
    var media = phantom.MediaQuery{ .data = &metrics, .child = scope.widget() };
    var harness = try phantom.testing.mount(std.testing.allocator, media.widget());
    defer harness.deinit();
    harness.viewport = metrics.size;
    try harness.pump();

    try harness.expectHtml(">Notifications<");
    try harness.expectHtml(">User<");
    try harness.expectHtml(">System · Genesis<");
    try harness.expectNoHtml(">Guest<");
    try harness.expectHtml(">Mail<");
    try harness.expectHtml(">A real notification<");
    try harness.expectHtml(">Delivered over the session bus<");
    // The Wi-Fi control shares a 154px card with its label. Its compact size
    // is intentional: the default 44px switch overflows into the adjacent
    // battery card at this panel width.
    try harness.expectSize(phantom.testing.find.byType(phantom.Switch), 38, 22);

    // Keep the history directly below the fixed session and hardware sections.
    // A Row without an explicit height expands across the panel's cross axis
    // and silently pushes these runs below the visible viewport.
    var summary_y: ?f32 = null;
    for (harness.canvas.list.primitives.items) |primitive| switch (primitive) {
        .text => |run| if (std.mem.eql(u8, run.text, "A real notification")) {
            summary_y = run.origin.y;
        },
        else => {},
    };
    try std.testing.expect(summary_y != null);
    try std.testing.expect(summary_y.? < 320);
    try harness.expectNoFaults();
}

test "control center exposes host audio brightness and session capabilities" {
    const Host = struct {
        fn audio(_: *anyopaque) ?phantom.platform.Audio {
            return .{ .output_volume = 0.65, .muted = false };
        }
        fn brightness(_: *anyopaque) ?phantom.platform.Brightness {
            return .{ .level = 0.72 };
        }
        fn capabilities(_: *anyopaque) phantom.platform.SessionCapabilities {
            return .{ .lock = true, .logout = true, .can_suspend = true, .restart = true, .power_off = true };
        }
    };
    var host: u8 = 0;
    const host_platform = phantom.Platform{
        .ctx = &host,
        .read_audio = Host.audio,
        .read_brightness = Host.brightness,
        .session_capabilities = Host.capabilities,
    };
    var center = ControlCenter{};
    var metrics = phantom.MediaQueryData{ .size = .{ .width = 1512, .height = 914 }, .dpr = 1 };
    var media = phantom.MediaQuery{ .data = &metrics, .child = center.widget() };
    var harness = try phantom.testing.mountWithPlatform(std.testing.allocator, media.widget(), host_platform);
    defer harness.deinit();
    harness.viewport = metrics.size;
    try harness.pump();

    try harness.expectHtml(">Volume<");
    try harness.expectHtml(">Brightness<");
    try harness.expectHtml(">Lock<");
    try harness.expectHtml(">Log out<");
    try harness.expectHtml(">Suspend<");
    try harness.expectHtml(">Restart<");
    try harness.expectHtml(">Power<");
    try harness.expectNoFaults();
}
