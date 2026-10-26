const std = @import("std");
const services = @import("services.zig");
const Reading = services.Reading;

/// Wall-clock time. Reads through `std.Io` rather than owning a clock, so
/// the same interface serves native and web without Genesis touching
/// `builtin.target` itself. Formatting the timestamp into `HH:MM` is the
/// bar's job, not this provider's: the provider reports time, the widget
/// decides how to show it.
pub const Clock = struct {
    pub const State = struct {
        /// Nanoseconds since the Unix epoch.
        unix_ns: i96,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque) Reading(State),
    };

    pub fn read(self: Clock) Reading(State) {
        return self.vtable.read(self.ptr);
    }

    /// A provider that reports no service answered. Used as the default so an
    /// unwired Services degrades to a blank indicator instead of undefined
    /// behaviour.
    pub const unavailable: Clock = .{ .ptr = undefined, .vtable = &unavailable_vtable };

    // `.ptr = undefined` is safe here, and only here: `readUnavailable`
    // ignores its argument and never dereferences it.
    const unavailable_vtable = Clock.VTable{ .read = readUnavailable };

    fn readUnavailable(_: *anyopaque) Reading(State) {
        return .unavailable;
    }
};

const TestReader = struct {
    reading: Reading(Clock.State),

    fn asClock(self: *TestReader) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Clock.VTable{ .read = read };

    fn read(ptr: *anyopaque) Reading(Clock.State) {
        const self: *TestReader = @ptrCast(@alignCast(ptr));
        return self.reading;
    }
};

test "read returns the exact unix time the vtable supplies" {
    var reader = TestReader{ .reading = .{ .ok = .{ .unix_ns = 1_767_225_840_000_000_000 } } };
    const c = reader.asClock();
    try std.testing.expectEqual(@as(i96, 1_767_225_840_000_000_000), c.read().ok.unix_ns);
}

test "a clock with no timer source reports nothing to render" {
    // Pins that Clock is a thin pass-through: an unavailable reading from
    // the vtable reaches the caller unchanged, it is not coerced to ok(0).
    var reader = TestReader{ .reading = .unavailable };
    const c = reader.asClock();
    try std.testing.expect(!c.read().shows());
}
