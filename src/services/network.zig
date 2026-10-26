const std = @import("std");
const services = @import("services.zig");
const Reading = services.Reading;
const phantom = @import("phantom");

/// Connectivity state. `strength` is bars, 0-4, and is meaningless for
/// `ethernet` and `none` (always reported as 0 there). NetworkManager gives
/// the full `Kind`; the web build can only ask `navigator.onLine`, so its
/// implementation (a later task) narrows to `.none` or `.wifi` as a stand-in
/// for "online, kind unknown".
pub const Network = struct {
    pub const Kind = enum { none, ethernet, wifi, cellular };

    pub const State = struct {
        kind: Kind,
        strength: u8,
        networking_enabled: bool = true,
        wifi_enabled: bool = false,
        cellular_enabled: bool = false,
    };
    pub const WifiNetwork = phantom.platform.WifiNetwork;

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque) Reading(State),
        set_networking_enabled: ?*const fn (*anyopaque, bool) bool = null,
        set_wifi_enabled: ?*const fn (*anyopaque, bool) bool = null,
        set_cellular_enabled: ?*const fn (*anyopaque, bool) bool = null,
        read_wifi_networks: ?*const fn (*anyopaque) Reading([]const WifiNetwork) = null,
        request_wifi_scan: ?*const fn (*anyopaque) bool = null,
        connect_wifi: ?*const fn (*anyopaque, []const u8, []const u8) bool = null,
        disconnect_wifi: ?*const fn (*anyopaque, []const u8) bool = null,
    };

    pub fn read(self: Network) Reading(State) {
        return self.vtable.read(self.ptr);
    }

    pub fn canSetWifi(self: Network) bool {
        return self.vtable.set_wifi_enabled != null;
    }

    pub fn setNetworkingEnabled(self: Network, enabled: bool) bool {
        const f = self.vtable.set_networking_enabled orelse return false;
        return f(self.ptr, enabled);
    }

    pub fn setWifiEnabled(self: Network, enabled: bool) bool {
        const f = self.vtable.set_wifi_enabled orelse return false;
        return f(self.ptr, enabled);
    }

    pub fn setCellularEnabled(self: Network, enabled: bool) bool {
        const f = self.vtable.set_cellular_enabled orelse return false;
        return f(self.ptr, enabled);
    }

    pub fn wifiNetworks(self: Network) Reading([]const WifiNetwork) {
        const f = self.vtable.read_wifi_networks orelse return .unsupported;
        return f(self.ptr);
    }

    pub fn requestWifiScan(self: Network) bool {
        const f = self.vtable.request_wifi_scan orelse return false;
        return f(self.ptr);
    }

    pub fn connectWifi(self: Network, id: []const u8, password: []const u8) bool {
        const f = self.vtable.connect_wifi orelse return false;
        return f(self.ptr, id, password);
    }

    pub fn disconnectWifi(self: Network, id: []const u8) bool {
        const f = self.vtable.disconnect_wifi orelse return false;
        return f(self.ptr, id);
    }

    /// A provider that reports no service answered. Used as the default so an
    /// unwired Services degrades to a blank indicator instead of undefined
    /// behaviour.
    pub const unavailable: Network = .{ .ptr = undefined, .vtable = &unavailable_vtable };

    // `.ptr = undefined` is safe here, and only here: `readUnavailable`
    // ignores its argument and never dereferences it.
    const unavailable_vtable = Network.VTable{ .read = readUnavailable };

    fn readUnavailable(_: *anyopaque) Reading(State) {
        return .unavailable;
    }
};

const TestReader = struct {
    reading: Reading(Network.State),

    fn asNetwork(self: *TestReader) Network {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Network.VTable{ .read = read };

    fn read(ptr: *anyopaque) Reading(Network.State) {
        const self: *TestReader = @ptrCast(@alignCast(ptr));
        return self.reading;
    }
};

test "read returns the exact kind and strength the vtable supplies" {
    var reader = TestReader{ .reading = .{ .ok = .{ .kind = .wifi, .strength = 3 } } };
    const n = reader.asNetwork();
    const r = n.read();
    try std.testing.expectEqual(Network.Kind.wifi, r.ok.kind);
    try std.testing.expectEqual(@as(u8, 3), r.ok.strength);
}

test "an unsupported network reading reports nothing to render" {
    // This is how the web build's lack of NetworkManager is verified from a
    // native test: the vtable answers `unsupported`, not a fabricated state.
    var reader = TestReader{ .reading = .unsupported };
    try std.testing.expect(!reader.asNetwork().read().shows());
}
