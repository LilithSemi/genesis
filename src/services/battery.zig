const std = @import("std");
const services = @import("services.zig");
const Reading = services.Reading;

/// Battery is a list because UPower reports the machine, the mouse, the
/// keyboard, the headset and the phone as separate devices. The top bar
/// shows only `primary()`; the control center in slice 2 lists every
/// device, which is why the list exists now rather than being retrofitted.
///
/// Ownership: the provider owns the slice and every string in it, valid for
/// the current frame only. A widget that keeps a name past the frame copies
/// it into the build arena. The provider frees the old list when it builds
/// a new one.
pub const Battery = struct {
    pub const Kind = enum {
        internal,
        ups,
        mouse,
        keyboard,
        headset,
        headphones,
        phone,
        tablet,
        pen,
        gaming_input,
        speakers,
        other,
    };

    pub const Status = enum { charging, discharging, full, empty, unknown };

    pub const Device = struct {
        /// Stable key. On Linux, the UPower object path.
        id: []const u8,
        name: []const u8,
        kind: Kind,
        percent: u8,
        status: Status,
        time_to_empty_s: ?u32 = null,
        time_to_full_s: ?u32 = null,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque) Reading([]const Device),
    };

    pub fn read(self: Battery) Reading([]const Device) {
        return self.vtable.read(self.ptr);
    }

    /// The device the top bar shows: internal, else UPS, else null.
    /// Peripherals never take over the bar.
    pub fn primary(self: Battery) ?Device {
        const devices = switch (self.read()) {
            .ok => |d| d,
            .unsupported, .unavailable, .pending => return null,
        };
        for (devices) |d| {
            if (d.kind == .internal) return d;
        }
        for (devices) |d| {
            if (d.kind == .ups) return d;
        }
        return null;
    }

    /// A provider that reports no service answered. Used as the default so an
    /// unwired Services degrades to a blank indicator instead of undefined
    /// behaviour.
    pub const unavailable: Battery = .{ .ptr = undefined, .vtable = &unavailable_vtable };

    // `.ptr = undefined` is safe here, and only here: `readUnavailable`
    // ignores its argument and never dereferences it.
    const unavailable_vtable = Battery.VTable{ .read = readUnavailable };

    fn readUnavailable(_: *anyopaque) Reading([]const Device) {
        return .unavailable;
    }
};

const TestReader = struct {
    devices: []const Battery.Device,

    fn asBattery(self: *TestReader) Battery {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Battery.VTable{ .read = read };

    fn read(ptr: *anyopaque) Reading([]const Battery.Device) {
        const self: *TestReader = @ptrCast(@alignCast(ptr));
        return .{ .ok = self.devices };
    }
};

test "primary prefers the internal battery over any peripheral" {
    const devices = [_]Battery.Device{
        .{ .id = "/dev/mouse", .name = "MX Master 3S", .kind = .mouse, .percent = 45, .status = .discharging },
        .{ .id = "/dev/BAT0", .name = "ThinkPad BAT0", .kind = .internal, .percent = 82, .status = .charging, .time_to_full_s = 2400 },
    };
    var reader = TestReader{ .devices = &devices };
    const p = reader.asBattery().primary() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/dev/BAT0", p.id);
}

test "primary falls back to the UPS when there is no internal battery" {
    const devices = [_]Battery.Device{
        .{ .id = "/dev/mouse", .name = "MX Master 3S", .kind = .mouse, .percent = 45, .status = .discharging },
        .{ .id = "/dev/ups0", .name = "APC Smart-UPS", .kind = .ups, .percent = 97, .status = .charging },
    };
    var reader = TestReader{ .devices = &devices };
    const p = reader.asBattery().primary() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/dev/ups0", p.id);
}

test "primary is null on a desktop whose only battery is a mouse" {
    // A tower with a wireless mouse must not sprout a battery indicator.
    const devices = [_]Battery.Device{
        .{ .id = "/dev/mouse", .name = "MX Master 3S", .kind = .mouse, .percent = 45, .status = .discharging },
    };
    var reader = TestReader{ .devices = &devices };
    try std.testing.expectEqual(@as(?Battery.Device, null), reader.asBattery().primary());
}

const UnavailableReader = struct {
    fn asBattery(self: *UnavailableReader) Battery {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Battery.VTable{ .read = read };

    fn read(ptr: *anyopaque) Reading([]const Battery.Device) {
        _ = ptr;
        return .unavailable;
    }
};

test "primary is null when the reading is unavailable, not an empty device list" {
    // The null tells the two implementations apart only by whether the test
    // survives: an implementation that reached for `.ok` on this reading traps
    // on the wrong union tag in Debug rather than returning null. That trap is
    // the failure this pins.
    var reader = UnavailableReader{};
    try std.testing.expectEqual(@as(?Battery.Device, null), reader.asBattery().primary());
}

test "primary is null on the unavailable sentinel provider" {
    // Pins that Battery.unavailable, the default an unwired Services now
    // carries, is itself safe to call primary() on.
    try std.testing.expectEqual(@as(?Battery.Device, null), Battery.unavailable.primary());
}
