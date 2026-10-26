const std = @import("std");
const services = @import("services.zig");
const Reading = services.Reading;

/// A notification accepted through org.freedesktop.Notifications. The provider
/// owns every string and the slice returned by read until its next mutation.
pub const Notification = struct {
    pub const Action = struct {
        key: []const u8,
        label: []const u8,
    };

    id: u32,
    app_name: []const u8,
    app_icon: []const u8,
    summary: []const u8,
    body: []const u8,
    created_ns: i96,
    /// D-Bus timeout semantics: 0 never expires, -1 uses server policy.
    expire_timeout_ms: i32 = -1,
    actions: []const Action = &.{},
};

pub const Notifications = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque) Reading([]const Notification),
        dismiss: *const fn (*anyopaque, u32) void,
        clear: *const fn (*anyopaque) void,
        invoke: *const fn (*anyopaque, u32, []const u8) void,
    };

    pub fn read(self: Notifications) Reading([]const Notification) {
        return self.vtable.read(self.ptr);
    }

    pub fn dismiss(self: Notifications, id: u32) void {
        self.vtable.dismiss(self.ptr, id);
    }

    pub fn clear(self: Notifications) void {
        self.vtable.clear(self.ptr);
    }

    pub fn invoke(self: Notifications, id: u32, action: []const u8) void {
        self.vtable.invoke(self.ptr, id, action);
    }

    pub const unavailable: Notifications = .{ .ptr = undefined, .vtable = &unavailable_vtable };

    const unavailable_vtable = VTable{
        .read = readUnavailable,
        .dismiss = dismissUnavailable,
        .clear = clearUnavailable,
        .invoke = invokeUnavailable,
    };

    fn readUnavailable(_: *anyopaque) Reading([]const Notification) {
        return .unavailable;
    }

    fn dismissUnavailable(_: *anyopaque, _: u32) void {}
    fn clearUnavailable(_: *anyopaque) void {}
    fn invokeUnavailable(_: *anyopaque, _: u32, _: []const u8) void {}
};

test "the unavailable notification provider is safe to read and mutate" {
    try std.testing.expect(!Notifications.unavailable.read().shows());
    Notifications.unavailable.dismiss(7);
    Notifications.unavailable.clear();
    Notifications.unavailable.invoke(7, "default");
}
