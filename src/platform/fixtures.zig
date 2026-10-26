const std = @import("std");
const services = @import("../services/services.zig");
const clock_mod = @import("../services/clock.zig");
const battery_mod = @import("../services/battery.zig");
const network_mod = @import("../services/network.zig");

const Reading = services.Reading;
const Services = services.Services;
const Clock = clock_mod.Clock;
const Battery = battery_mod.Battery;
const Network = network_mod.Network;

/// A real, mutable provider so tests can drive state and assert the UI
/// reacts. Also the web build's stand-in until plan E lands `platform/web.zig`,
/// and the whole reason a fixture is a provider rather than a test double:
/// driving it to `unsupported` on Linux is how web behaviour gets verified
/// from a native test run.
pub const Fixtures = struct {
    services: Services = .{},
    battery_state: Reading([]const Battery.Device) = .{ .ok = &default_batteries },
    network_state: Reading(Network.State) = .{ .ok = .{ .kind = .wifi, .strength = 3 } },
    /// Nanoseconds since the Unix epoch. Frozen unless `advanceClock` moves it.
    clock_ns: i128 = 1_767_225_840_000_000_000,

    const default_batteries = [_]Battery.Device{
        .{ .id = "/dev/BAT0", .name = "ThinkPad BAT0", .kind = .internal, .percent = 82, .status = .charging, .time_to_full_s = 2400 },
        .{ .id = "/dev/mouse", .name = "MX Master 3S", .kind = .mouse, .percent = 45, .status = .discharging },
    };

    /// Wires `services.clock`, `.battery` and `.network` back to this
    /// `Fixtures` instance. Each provider handle is a pointer into `self`,
    /// so this can only run once `self` has its final, stable address; call
    /// it right after the `Fixtures` is placed (never on a value that will
    /// still be copied or moved). Reading `services` before calling `init`
    /// is well defined, not a programmer error: every provider reports
    /// `unavailable` until `init` wires them.
    ///
    /// `io` is unused. It is in the signature so every platform implementation
    /// is constructed the same way, and `ServicesHost` needs no target test.
    pub fn init(self: *Fixtures, io: std.Io) void {
        _ = io;
        self.services = .{
            .clock = self.clock(),
            .battery = self.battery(),
            .network = self.network(),
        };
    }

    pub fn setBattery(self: *Fixtures, r: Reading([]const Battery.Device)) void {
        self.battery_state = r;
        self.services.notifyChanged();
    }

    pub fn setNetwork(self: *Fixtures, r: Reading(Network.State)) void {
        self.network_state = r;
        self.services.notifyChanged();
    }

    pub fn advanceClock(self: *Fixtures, ns: i128) void {
        self.clock_ns += ns;
        self.services.notifyChanged();
    }

    pub fn battery(self: *Fixtures) Battery {
        return .{ .ptr = self, .vtable = &battery_vtable };
    }

    pub fn network(self: *Fixtures) Network {
        return .{ .ptr = self, .vtable = &network_vtable };
    }

    pub fn clock(self: *Fixtures) Clock {
        return .{ .ptr = self, .vtable = &clock_vtable };
    }

    const battery_vtable = Battery.VTable{ .read = readBattery };
    fn readBattery(ptr: *anyopaque) Reading([]const Battery.Device) {
        const self: *Fixtures = @ptrCast(@alignCast(ptr));
        return self.battery_state;
    }

    const network_vtable = Network.VTable{ .read = readNetwork };
    fn readNetwork(ptr: *anyopaque) Reading(Network.State) {
        const self: *Fixtures = @ptrCast(@alignCast(ptr));
        return self.network_state;
    }

    const clock_vtable = Clock.VTable{ .read = readClock };
    fn readClock(ptr: *anyopaque) Reading(Clock.State) {
        const self: *Fixtures = @ptrCast(@alignCast(ptr));
        // Fixtures always know the time; the clock has no "unsupported" or
        // "unavailable" state on any target this slice ships.
        return .{ .ok = .{ .unix_ns = @intCast(self.clock_ns) } };
    }
};

fn countFn(ctx: *anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(ctx));
    c.* += 1;
}

test "setBattery changes what the provider reports and notifies once" {
    var fired: u32 = 0;
    var fx = Fixtures{};
    fx.services.changed_ctx = &fired;
    fx.services.changed_fn = countFn;

    fx.setBattery(.{ .ok = &.{.{
        .id = "/dev/BAT0",
        .name = "BAT0",
        .kind = .internal,
        .percent = 4,
        .status = .discharging,
        .time_to_empty_s = 600,
        .time_to_full_s = null,
    }} });

    const r = fx.battery().read();
    try std.testing.expectEqual(@as(u8, 4), r.ok[0].percent);
    try std.testing.expectEqual(@as(u32, 1), fired);
}

test "a provider driven to unsupported reports nothing to render" {
    // This is how the web build's behaviour is verified from a native test.
    var fx = Fixtures{};
    fx.setBattery(.unsupported);
    try std.testing.expect(!fx.battery().read().shows());
}

test "setNetwork changes what the provider reports and notifies once" {
    var fired: u32 = 0;
    var fx = Fixtures{};
    fx.services.changed_ctx = &fired;
    fx.services.changed_fn = countFn;

    fx.setNetwork(.{ .ok = .{ .kind = .ethernet, .strength = 0 } });

    const r = fx.network().read();
    try std.testing.expectEqual(Network.Kind.ethernet, r.ok.kind);
    try std.testing.expectEqual(@as(u32, 1), fired);
}

test "advanceClock moves the reported time forward by exactly the given delta" {
    var fx = Fixtures{};
    const before = fx.clock().read().ok.unix_ns;
    fx.advanceClock(60_000_000_000); // 60 seconds, in nanoseconds
    const after = fx.clock().read().ok.unix_ns;
    try std.testing.expectEqual(@as(i96, 60_000_000_000), after - before);
}

test "the default battery fixture has no ups device, so primary falls through to the internal one" {
    var fx = Fixtures{};
    const p = fx.battery().primary() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/dev/BAT0", p.id);
}

test "a provider reached through Services reports what the fixture was set to" {
    // Widgets only ever see Services, never Fixtures. If the wiring in init
    // is missing or stale, a widget reads a different provider than the one
    // the test drives.
    var fx = Fixtures{};
    fx.init(std.Io.failing);
    fx.setNetwork(.{ .ok = .{ .kind = .ethernet, .strength = 0 } });
    const r = fx.services.network.read();
    try std.testing.expectEqual(Network.Kind.ethernet, r.ok.kind);
}
