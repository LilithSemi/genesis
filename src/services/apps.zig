const services = @import("services.zig");

const Reading = services.Reading;

pub const Entry = struct {
    /// XDG desktop-file id, including the `.desktop` suffix.
    id: []const u8,
    name: []const u8,
    comment: []const u8 = "",
    icon: []const u8 = "",
    /// Encoded PNG/SVG bytes resolved through the XDG icon search path.
    /// Empty means the theme did not provide a renderable icon.
    icon_bytes: []const u8 = "",
    categories: []const u8 = "",
    startup_wm_class: []const u8 = "",
    argv: []const []const u8,
    running: bool = false,
};

/// Platform-neutral application catalog. Linux supplies XDG desktop entries;
/// fixtures can supply an embedded catalog without changing shell widgets.
pub const Apps = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque) Reading([]const Entry),
        launch: *const fn (*anyopaque, []const u8) anyerror!void,
    };

    pub fn read(self: Apps) Reading([]const Entry) {
        return self.vtable.read(self.ptr);
    }

    pub fn launch(self: Apps, id: []const u8) !void {
        try self.vtable.launch(self.ptr, id);
    }

    pub const unavailable = Apps{ .ptr = &unavailable_target, .vtable = &unavailable_vtable };
};

var unavailable_target: u8 = 0;

fn readUnavailable(_: *anyopaque) Reading([]const Entry) {
    return .unavailable;
}

fn launchUnavailable(_: *anyopaque, _: []const u8) anyerror!void {
    return error.AppsUnavailable;
}

const unavailable_vtable = Apps.VTable{
    .read = readUnavailable,
    .launch = launchUnavailable,
};
