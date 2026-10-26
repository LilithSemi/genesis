//! The strip across the top of every Genesis surface. It shows the time in the
//! centre and the machine's status on the right. An indicator appears only when
//! its provider can answer, so a machine with no battery gets a bar with no
//! battery on it, not a blank slot.
const std = @import("std");
const phantom = @import("phantom");
const platform = @import("../platform.zig");
const services = @import("../services/services.zig");
const Battery = @import("../services/battery.zig").Battery;
const FormFactor = @import("form_factor.zig").FormFactor;
const Clock = @import("../services/clock.zig").Clock;
const Network = @import("../services/network.zig").Network;

/// Logical gap in front of each indicator in the trailing cluster.
const indicator_gap: f32 = 12;

/// Logical inset that keeps the trailing cluster off the screen edge.
const edge_inset: f32 = 12;

/// Vertical breathing room above and below the torii. Without it the mark fills
/// the bar edge to edge and reads as cramped.
const icon_bar_inset: f32 = 5;

/// Wall clock nanoseconds to "HH:MM" in UTC. Local time needs a timezone
/// database, which is a later slice.
pub fn formatClock(buf: *[5]u8, unix_ns: i96) []const u8 {
    const secs_per_day = 24 * 60 * 60;
    const total_s = @divFloor(unix_ns, std.time.ns_per_s);
    // @mod, not @rem: a timestamp before the epoch is negative and @rem would
    // report a negative hour.
    const day_s = @mod(total_s, secs_per_day);
    const hh: u8 = @intCast(@divFloor(day_s, 3600));
    const mm: u8 = @intCast(@divFloor(@mod(day_s, 3600), 60));
    // The buffer is exactly five bytes and the output is exactly five bytes, so
    // an overflow here is a programmer error, not a runtime condition.
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hh, mm }) catch unreachable;
}

test "formatClock renders midnight as 00:00" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", formatClock(&buf, 0));
}

test "formatClock renders a known epoch time in UTC" {
    // 1767225840 seconds is 2026-01-01T00:04:00Z.
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:04", formatClock(&buf, 1_767_225_840 * std.time.ns_per_s));
}

test "formatClock zero pads a single digit minute" {
    // 09:05 is the shape that breaks a naive {d}:{d} format string.
    var buf: [5]u8 = undefined;
    const t = (9 * 3600 + 5 * 60) * std.time.ns_per_s;
    try std.testing.expectEqualStrings("09:05", formatClock(&buf, t));
}

test "formatClock wraps at the end of a day rather than reporting hour 24" {
    var buf: [5]u8 = undefined;
    const t = (23 * 3600 + 59 * 60) * std.time.ns_per_s;
    try std.testing.expectEqualStrings("23:59", formatClock(&buf, t));
    try std.testing.expectEqualStrings("00:00", formatClock(&buf, t + 60 * std.time.ns_per_s));
}

/// The clock text, or null when no clock answers. A `pending` clock keeps its
/// slot: a bar with no time at all reads as broken rather than as unequipped.
fn clockLabel(buf: *[5]u8, reading: services.Reading(Clock.State)) ?[]const u8 {
    return switch (reading) {
        .unsupported, .unavailable => null,
        .pending => "--:--",
        .ok => |state| formatClock(buf, state.unix_ns),
    };
}

const StatusIcon = struct { id: phantom.icon.Id, label: []const u8 };

/// The compact network mark, or null when no network provider answers.
fn networkIcon(reading: services.Reading(Network.State)) ?StatusIcon {
    const state = switch (reading) {
        .unsupported, .unavailable => return null,
        .pending => return .{ .id = .wifi_none, .label = "Checking network" },
        .ok => |value| value,
    };
    return switch (state.kind) {
        .none => .{ .id = .wifi_none, .label = "Offline" },
        .ethernet => .{ .id = .ethernet, .label = "Ethernet connected" },
        .wifi, .cellular => .{
            .id = switch (@min(state.strength, 4)) {
                0 => .wifi_none,
                1 => .wifi_weak,
                2 => .wifi_fair,
                3 => .wifi_good,
                else => .wifi_strong,
            },
            .label = if (state.kind == .wifi) "Wi-Fi connected" else "Cellular connected",
        },
    };
}

/// The battery mark, or null when no battery provider answers and when every
/// battery is a peripheral. A tower with a wireless mouse shows no battery.
fn batteryIcon(buf: *[24]u8, battery: Battery) ?StatusIcon {
    if (!battery.read().shows()) return null;
    const device = battery.primary() orelse return null;
    return .{
        .id = if (device.status == .charging) .battery_charging else switch (device.percent) {
            0...10 => .battery_empty,
            11...30 => .battery_low,
            31...55 => .battery_half,
            56...80 => .battery_high,
            else => .battery_full,
        },
        .label = std.fmt.bufPrint(buf, "Battery {d}%", .{device.percent}) catch "Battery",
    };
}

/// The same color at a new opacity. The theme owns the hue; only the surface
/// opacity is applied here.
fn withAlpha(color: phantom.Color, opacity: f32) phantom.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = opacity };
}

pub const TopBar = struct {
    on_status: ?*const fn (*anyopaque) void = null,
    on_clock: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,
    /// Logical height of the strip on each form factor. A phone bar sits under
    /// a notch and is the only one a thumb hits, so it is the tallest. A
    /// desktop bar is only ever hit by a pointer, so it gives its pixels back
    /// to the windows below it.
    pub const phone_height: f32 = 36;
    pub const tablet_height: f32 = 32;
    pub const desktop_height: f32 = 28;

    /// What the leading cluster says. It names the shell the surface belongs
    /// to, the way a menu bar names its application.
    pub const leading_text = "Genesis";

    /// What one form factor changes about the bar. Everything else on the
    /// strip is identical across the three, because this slice proves the
    /// reflow rather than designs three bars.
    const Metrics = struct {
        height: f32,
        /// False on the phone, where the horizontal room goes to the clock and
        /// the indicators instead.
        leading: bool,
    };

    /// Every cluster `build` can stack: background, leading, clock, trailing.
    /// A fifth one must raise this, or it writes past `State.layers`.
    const max_layers = 4;

    /// Every indicator the trailing cluster can hold: network and battery.
    /// A third one must raise this, or it writes past `State.indicators`.
    const max_indicators = 3;

    pub const State = struct {
        base: phantom.StateBase = .{},
        /// The periodic redraw, cancelled on dispose. Null before initState
        /// registers it and after dispose cancels it.
        tick: ?phantom.Scheduler.Handle = null,
        on_status: ?*const fn (*anyopaque) void = null,
        on_clock: ?*const fn (*anyopaque) void = null,
        ctx: *anyopaque = undefined,

        // Text the labels point at. A render object copies the string it is
        // given, but the widget config is read after build returns, so the
        // bytes must outlive the build pass.
        clock_buf: [5]u8 = undefined,
        battery_buf: [24]u8 = undefined,

        // Every config below is a field, not a `b.new` arena copy: the bar
        // rebuilds on a tick of its own, after the build arena was reset.
        background: phantom.ColoredBox = undefined,
        leading: phantom.Icon = undefined,
        leading_inset: phantom.Padding = undefined,
        leading_slot: phantom.Align = undefined,
        clock: phantom.Text = undefined,
        clock_tap: phantom.GestureDetector = undefined,
        clock_slot: phantom.Align = undefined,
        network: phantom.Icon = undefined,
        network_slot: phantom.Padding = undefined,
        battery: phantom.Icon = undefined,
        battery_slot: phantom.Padding = undefined,
        notifications: phantom.Icon = undefined,
        notifications_slot: phantom.Padding = undefined,
        indicators: [max_indicators]phantom.Widget = undefined,
        indicator_row: phantom.Flex = undefined,
        trailing: phantom.Padding = undefined,
        status_tap: phantom.GestureDetector = undefined,
        layers: [max_layers]phantom.Widget = undefined,
        stack: phantom.Stack = undefined,
        strip: phantom.SizedBox = undefined,

        pub fn initState(s: *@This(), config: *const TopBar) std.mem.Allocator.Error!void {
            s.take(config);
            // One second is the coarsest period that still shows a minute
            // boundary within a second of the change.
            s.tick = try s.base.scheduler().every(
                s.base.gpa(),
                std.time.ns_per_s,
                s,
                onTick,
            );
        }

        pub fn didUpdateWidget(s: *@This(), config: *const TopBar) anyerror!void {
            s.take(config);
        }

        fn take(s: *@This(), config: *const TopBar) void {
            s.on_status = config.on_status;
            s.on_clock = config.on_clock;
            s.ctx = config.ctx;
        }

        pub fn dispose(s: *@This()) void {
            const handle = s.tick orelse return;
            s.base.scheduler().cancel(handle);
            s.tick = null;
        }

        /// Marks the bar for rebuild rather than mutating it: the new time
        /// comes from the clock provider on the next build, so there is no
        /// State field for a `setState` mutation to change.
        fn onTick(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            phantom.markNeedsBuild(s);
        }

        // anyerror matches phantom's StateVTable.build signature. It is a shim,
        // not a library error surface.
        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const svc = services.ServicesScope.of(b);

            // Exhaustive with no `else`: a fourth form factor must fail the
            // build here rather than land silently on a desktop bar.
            const metrics: Metrics = switch (FormFactor.fromWidth(phantom.MediaQuery.of(b).size.width)) {
                .phone => .{ .height = TopBar.phone_height, .leading = false },
                .tablet => .{ .height = TopBar.tablet_height, .leading = true },
                .desktop => .{ .height = TopBar.desktop_height, .leading = true },
            };

            // A full width strip meets all four screen edges, so the theme
            // radius would only cut the wallpaper in at the corners.
            s.background = .{
                .color = withAlpha(theme.colors.bg_dark, theme.surface_alpha),
                .radius = 0,
            };
            s.layers[0] = s.background.widget();
            var layer_count: usize = 1;

            if (metrics.leading) {
                // The torii sized to the bar rather than to its authoring grid,
                // so it scales with the form factor. No color: the theme
                // resolves it.
                // The label is the shell's name because the mark stands in for
                // it here. Without one the bar opens with a shape that a screen
                // reader cannot announce.
                s.leading = .{
                    .id = .torii,
                    .size = metrics.height - 2 * icon_bar_inset,
                    .label = TopBar.leading_text,
                };
                s.leading_inset = .{
                    .insets = .{ .left = edge_inset },
                    .child = s.leading.widget(),
                };
                s.leading_slot = .{
                    .alignment = .center_left,
                    .child = s.leading_inset.widget(),
                };
                s.layers[layer_count] = s.leading_slot.widget();
                layer_count += 1;
            }

            if (clockLabel(&s.clock_buf, svc.clock.read())) |text| {
                // The font, size and color stay null so the theme resolves
                // them. Genesis defines no typography of its own.
                s.clock = .{ .text = text };
                s.clock_tap = .{ .on_tap = s.on_clock, .ctx = s.ctx, .child = s.clock.widget() };
                s.clock_slot = .{ .alignment = .center, .child = s.clock_tap.widget() };
                s.layers[layer_count] = s.clock_slot.widget();
                layer_count += 1;
            }

            var indicator_count: usize = 0;
            const status_icon_size = metrics.height - 12;
            if (networkIcon(svc.network.read())) |icon| {
                s.network = .{ .id = icon.id, .size = status_icon_size, .color = theme.accent, .label = icon.label };
                s.network_slot = .{
                    .insets = .{ .left = indicator_gap },
                    .child = s.network.widget(),
                };
                s.indicators[indicator_count] = s.network_slot.widget();
                indicator_count += 1;
            }
            if (batteryIcon(&s.battery_buf, svc.battery)) |icon| {
                s.battery = .{ .id = icon.id, .size = status_icon_size, .label = icon.label };
                s.battery_slot = .{
                    .insets = .{ .left = indicator_gap },
                    .child = s.battery.widget(),
                };
                s.indicators[indicator_count] = s.battery_slot.widget();
                indicator_count += 1;
            }
            s.notifications = .{ .id = .notification, .size = metrics.height - 12, .label = "Notifications" };
            s.notifications_slot = .{
                .insets = .{ .left = indicator_gap },
                .child = s.notifications.widget(),
            };
            s.indicators[indicator_count] = s.notifications_slot.widget();
            indicator_count += 1;
            s.indicator_row = phantom.Row(.{
                .main = .end,
                .cross = .center,
                .children = s.indicators[0..indicator_count],
            });
            s.trailing = .{
                .insets = .{ .left = edge_inset, .right = edge_inset },
                .child = s.indicator_row.widget(),
            };
            s.status_tap = .{ .on_tap = s.on_status, .ctx = s.ctx, .child = s.trailing.widget() };
            s.layers[layer_count] = s.status_tap.widget();
            layer_count += 1;

            // The background is first, so it sizes the stack and every cluster
            // is laid out inside it.
            s.stack = .{ .children = s.layers[0..layer_count] };
            s.strip = .{ .height = metrics.height, .child = s.stack.widget() };
            return s.strip.widget();
        }
    };

    pub fn widget(self: *const TopBar) phantom.Widget {
        return phantom.StatefulWidget(TopBar, self);
    }
};

const Fixtures = platform.fixtures.Fixtures;
const Shell = @import("../shell.zig").Shell;

/// What the rendered leading cluster looks like in the frame. The angle
/// brackets keep it from matching a style attribute that happens to hold the
/// same word.
const leading_label = ">" ++ TopBar.leading_text ++ "<";

/// A `TopBar` published through a `ServicesHost`, which is the only way a
/// widget ever reaches a provider. `fx` is injected rather than built from the
/// target's platform, so every test below drives a provider it owns and pins
/// the same fact on Linux and on the web. `fx` and `host` must outlive the
/// returned harness. Leaves the caller to pump.
///
/// No `MediaQuery` ancestor, on purpose: `MediaQuery.of` then reports the zero
/// size and the bar builds in the phone form factor, whatever the harness
/// viewport is. Every test here is about a provider rather than a breakpoint,
/// so one fixed form factor keeps them from drifting apart. `mountShellAt`
/// below is the one that varies the width.
fn mountBar(
    bar: *const TopBar,
    host: *services.ServicesHost,
    fx: *Fixtures,
) !phantom.testing.Harness {
    fx.init(std.Io.failing);
    host.* = .{ .child = bar.widget(), .services = &fx.services };
    return phantom.testing.mount(std.testing.allocator, host.widget());
}

/// Assert `needle` is NOT in the rendered frame. `Harness.expectHtml` only
/// proves presence, and the capability model needs the opposite proof: an
/// indicator whose provider cannot answer must leave no mark on screen.
fn expectHtmlAbsent(t: *phantom.testing.Harness, needle: []const u8) !void {
    try t.expectNoHtml(needle);
}

test "the bar renders the time the clock provider reports" {
    var fx = Fixtures{};
    var bar = TopBar{};
    var host: services.ServicesHost = undefined;
    var t = try mountBar(&bar, &host, &fx);
    defer t.deinit();
    try t.pump();

    // The fixture clock is frozen at 2026-01-01T00:04:00Z.
    try t.expectHtml(">00:04<");
    try t.expectNoFaults();
}

test "a battery driven to unsupported leaves no indicator on the bar" {
    var fx = Fixtures{};
    var bar = TopBar{};
    var host: services.ServicesHost = undefined;
    var t = try mountBar(&bar, &host, &fx);
    defer t.deinit();
    try t.pump();

    // The default fixture reports an internal battery at 82 percent.
    try t.expectHtml(">Battery 82%<");

    fx.setBattery(.unsupported);
    try t.pump();
    try expectHtmlAbsent(&t, ">Battery 82%<");
    try t.expectNoFaults();
}

test "a network driven to unsupported leaves no indicator on the bar" {
    var fx = Fixtures{};
    var bar = TopBar{};
    var host: services.ServicesHost = undefined;
    var t = try mountBar(&bar, &host, &fx);
    defer t.deinit();
    try t.pump();

    try t.expectHtml(">Wi-Fi connected<");

    fx.setNetwork(.unsupported);
    try t.pump();
    try expectHtmlAbsent(&t, ">Wi-Fi connected<");
    try t.expectNoFaults();
}

test "a one second scheduler tick redraws the bar with the new minute" {
    // The end to end proof of the scheduler. The fixture is moved WITHOUT its
    // notifier, so only the periodic callback can put the new minute on screen.
    var fx = Fixtures{};
    var bar = TopBar{};
    var host: services.ServicesHost = undefined;
    var t = try mountBar(&bar, &host, &fx);
    defer t.deinit();
    try t.pump();
    try t.expectHtml(">00:04<");

    fx.clock_ns += 60 * std.time.ns_per_s;
    try t.pump();
    try t.expectHtml(">00:04<"); // nothing marked the bar dirty yet

    t.owner.scheduler.tick(0); // baselines the entry
    t.owner.scheduler.tick(std.time.ns_per_s);
    try t.pump();
    try t.expectHtml(">00:05<");
    try t.expectNoFaults();
}

/// The whole shell mounted at one logical size, with fixtures injected. The
/// width only reaches a widget through a `MediaQuery` ancestor, so a test that
/// set the harness viewport alone would leave every build reading zero. Every
/// argument must outlive the returned harness. Leaves the caller to pump.
fn mountShellAt(
    sh: *Shell,
    metrics: *phantom.MediaQueryData,
    mq: *phantom.MediaQuery,
    fx: *Fixtures,
    size: phantom.LogicalSize,
) !phantom.testing.Harness {
    fx.init(std.Io.failing);
    sh.* = .{ .services = &fx.services };
    metrics.* = .{ .size = size, .dpr = 1, .text_scale = 1 };
    mq.* = .{ .data = metrics, .child = sh.widget() };
    var t = try phantom.testing.mount(std.testing.allocator, mq.widget());
    // The harness lays out against its own viewport, so the two must agree or
    // the bar would be measured at a width nothing reported.
    t.viewport = size;
    return t;
}

test "a phone sized shell gets the tall bar and no leading cluster" {
    var fx = Fixtures{};
    var sh: Shell = undefined;
    var metrics: phantom.MediaQueryData = undefined;
    var mq: phantom.MediaQuery = undefined;
    var t = try mountShellAt(&sh, &metrics, &mq, &fx, .{ .width = 390, .height = 844 });
    defer t.deinit();
    try t.pump();

    try t.expectHtml("left:0;top:0;width:24.375rem;height:2.25rem");
    // The clock stays, so the missing cluster below is a reflow and not a bar
    // that failed to build.
    try t.expectHtml(">00:04<");
    try expectHtmlAbsent(&t, leading_label);
    try t.expectNoFaults();
}

test "a tablet sized shell gets the middle bar height and keeps the leading cluster" {
    var fx = Fixtures{};
    var sh: Shell = undefined;
    var metrics: phantom.MediaQueryData = undefined;
    var mq: phantom.MediaQuery = undefined;
    var t = try mountShellAt(&sh, &metrics, &mq, &fx, .{ .width = 834, .height = 1112 });
    defer t.deinit();
    try t.pump();

    try t.expectHtml("left:0;top:0;width:52.125rem;height:2rem");
    try t.expectHtml(leading_label);
    try t.expectNoFaults();
}

test "a desktop sized shell gets the short bar and keeps the leading cluster" {
    var fx = Fixtures{};
    var sh: Shell = undefined;
    var metrics: phantom.MediaQueryData = undefined;
    var mq: phantom.MediaQuery = undefined;
    var t = try mountShellAt(&sh, &metrics, &mq, &fx, .{ .width = 1280, .height = 800 });
    defer t.deinit();
    try t.pump();

    // 28 against the phone's 36: the two form factors must not agree, or
    // nothing on screen would tell them apart.
    try t.expectHtml("left:0;top:0;width:80rem;height:1.75rem");
    try t.expectHtml(leading_label);
    try t.expectNoFaults();
}

test "a tablet turned on its side reflows to the desktop bar" {
    // 1180 is an iPad Pro 11 held sideways. It sits above the 1100 breakpoint,
    // so the layout follows the room on screen rather than the hardware.
    var fx = Fixtures{};
    var sh: Shell = undefined;
    var metrics: phantom.MediaQueryData = undefined;
    var mq: phantom.MediaQuery = undefined;
    var t = try mountShellAt(&sh, &metrics, &mq, &fx, .{ .width = 1180, .height = 820 });
    defer t.deinit();
    try t.pump();

    try t.expectHtml("left:0;top:0;width:73.75rem;height:1.75rem");
    try t.expectHtml(leading_label);
    try t.expectNoFaults();
}

test "the bar registers exactly one callback and cancels it when unmounted" {
    // A leaked registration fires on a freed State, which is a use after free
    // rather than a cosmetic leak.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var bar = TopBar{};
    const el = try bar.widget().mount(&bctx, null);
    try std.testing.expectEqual(@as(usize, 1), owner.scheduler.entries.items.len);
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), owner.scheduler.entries.items[0].period);

    el.deinit(std.testing.allocator);
    // A cancelled entry only leaves the list on the next sweep, and that sweep
    // must not reach the State that was just freed.
    owner.scheduler.tick(0);
    try std.testing.expectEqual(@as(usize, 0), owner.scheduler.entries.items.len);
    try std.testing.expect(sink.ok());
}
