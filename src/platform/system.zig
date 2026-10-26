const std = @import("std");
const builtin = @import("builtin");
const services = @import("../services/services.zig");
const clock_mod = @import("../services/clock.zig");
const battery_mod = @import("../services/battery.zig");
const network_mod = @import("../services/network.zig");
const apps_mod = @import("../services/apps.zig");
const app_index = @import("../xdg/app_index.zig");
const phantom = @import("phantom");

const Reading = services.Reading;
const Services = services.Services;
const Clock = clock_mod.Clock;
const Battery = battery_mod.Battery;
const Network = network_mod.Network;
const Apps = apps_mod.Apps;
const AppEntry = apps_mod.Entry;
const session_supported = builtin.os.tag == .linux and !builtin.abi.isAndroid();
const Session = if (session_supported) @import("session.zig").Session else void;

/// The backend both shipping targets select. It holds nothing target-specific:
/// a clock read through the injected `std.Io`, which the native loop backs with
/// the process IO and the web build backs with the browser clocks. That is why
/// `platform.zig` points the `.linux` and the `.freestanding` arm at this one
/// file instead of giving the web build the test fixtures.
///
/// Hardware stays behind Phantom's platform contract. Its Linux host reads
/// UPower and NetworkManager over the system D-Bus; an Android host can provide
/// the same value types through its Java bridge. Genesis only adapts those
/// portable values into its reactive service scope. A missing platform hook
/// remains `unavailable`, so unsupported hardware produces no fabricated state.
pub const Platform = struct {
    services: Services = .{},
    /// Read through for every clock query. Given at construction rather
    /// than reached for as a global, so this type stays instantiable twice
    /// (e.g. once per test) without the instances fighting over an IO
    /// backend.
    io: std.Io = std.Io.failing,
    owner: ?*phantom.BuildOwner = null,
    arena: ?std.heap.ArenaAllocator = null,
    entries: []AppEntry = &.{},
    session: if (session_supported) ?*Session else void = if (session_supported) null else {},
    session_pump: if (session_supported) ?phantom.Scheduler.Handle else void = if (session_supported) null else {},
    hardware_poll: ?phantom.Scheduler.Handle = null,
    network_state: Reading(Network.State) = .unavailable,
    battery_devices: [1]battery_mod.Battery.Device = undefined,
    battery_count: usize = 0,

    /// Wires `services.clock` back to this instance. Must run once `self`
    /// has its final address, since the returned `Clock` carries a pointer
    /// into `self`; the same rule `Fixtures.init` documents.
    pub fn init(self: *Platform, io: std.Io) void {
        self.io = io;
        self.services = .{ .clock = self.clock() };
    }

    /// Native construction path. Application discovery is deliberately done
    /// once here, outside widget builds; reads remain allocation-free.
    pub fn initWithOwner(self: *Platform, io: std.Io, owner: *phantom.BuildOwner) void {
        self.init(io);
        self.owner = owner;
        const environ = owner.environ orelse return;
        self.arena = std.heap.ArenaAllocator.init(owner.gpa);
        self.entries = app_index.scan(self.arena.?.allocator(), io, environ) catch &.{};
        self.services.apps = self.apps();
        self.services.network = self.network();
        self.services.battery = self.battery();
        self.refreshHardware();
        self.hardware_poll = owner.scheduler.every(owner.gpa, 2 * std.time.ns_per_s, self, pollHardware) catch null;
        if (phantom.compositor.fromOwner(owner)) |host| host.setChangeListener(self, compositorChanged);
        if (session_supported) self.initSession() catch |err| {
            std.debug.print("genesis: session D-Bus unavailable: {s}\n", .{@errorName(err)});
        };
    }

    /// Releases whatever `init` acquired, before `ServicesHost.dispose` frees
    /// this struct. Nothing is owned this slice, but the D-Bus backend will own
    /// a bus connection and a heap device list, and a `destroy` on its own
    /// would leak both. Every provider handle in `services` points back into
    /// this struct, so they go back to the `unavailable` sentinel here rather
    /// than being left aimed at memory about to be freed.
    pub fn deinit(self: *Platform) void {
        if (self.owner) |owner| if (phantom.compositor.fromOwner(owner)) |host| host.setChangeListener(null, null);
        if (self.owner) |owner| if (self.hardware_poll) |handle| owner.scheduler.cancel(handle);
        self.hardware_poll = null;
        if (session_supported) {
            if (self.owner) |owner| if (self.session_pump) |handle| owner.scheduler.cancel(handle);
            self.session_pump = null;
            if (self.session) |session| {
                session.setChangeListener(null, null);
                session.deinit();
            }
            self.session = null;
        }
        self.services = .{};
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.entries = &.{};
        self.owner = null;
        self.io = std.Io.failing;
    }

    pub fn clock(self: *Platform) Clock {
        return .{ .ptr = self, .vtable = &clock_vtable };
    }

    pub fn apps(self: *Platform) Apps {
        return .{ .ptr = self, .vtable = &apps_vtable };
    }

    pub fn network(self: *Platform) Network {
        return .{ .ptr = self, .vtable = &network_vtable };
    }

    pub fn battery(self: *Platform) Battery {
        return .{ .ptr = self, .vtable = &battery_vtable };
    }

    const network_vtable = Network.VTable{
        .read = readNetwork,
        .set_networking_enabled = setNetworkingEnabled,
        .set_wifi_enabled = setWifiEnabled,
        .set_cellular_enabled = setCellularEnabled,
        .read_wifi_networks = readWifiNetworks,
        .request_wifi_scan = requestWifiScan,
        .connect_wifi = connectWifi,
        .disconnect_wifi = disconnectWifi,
    };
    const battery_vtable = Battery.VTable{ .read = readBattery };

    fn readNetwork(ptr: *anyopaque) Reading(Network.State) {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        return self.network_state;
    }

    fn setNetworkingEnabled(ptr: *anyopaque, enabled: bool) bool {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return false;
        if (!owner.platform.setNetworkingEnabled(enabled)) return false;
        self.refreshHardware();
        self.services.notifyChanged();
        return true;
    }

    fn setWifiEnabled(ptr: *anyopaque, enabled: bool) bool {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return false;
        if (!owner.platform.setWifiEnabled(enabled)) return false;
        self.refreshHardware();
        self.services.notifyChanged();
        return true;
    }

    fn setCellularEnabled(ptr: *anyopaque, enabled: bool) bool {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return false;
        if (!owner.platform.setCellularEnabled(enabled)) return false;
        self.refreshHardware();
        self.services.notifyChanged();
        return true;
    }

    fn readWifiNetworks(ptr: *anyopaque) Reading([]const Network.WifiNetwork) {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return .unavailable;
        return if (owner.platform.readWifiNetworks()) |items| .{ .ok = items } else .unavailable;
    }

    fn requestWifiScan(ptr: *anyopaque) bool {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return false;
        const ok = owner.platform.requestWifiScan();
        if (ok) self.services.notifyChanged();
        return ok;
    }

    fn connectWifi(ptr: *anyopaque, id: []const u8, password: []const u8) bool {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return false;
        const ok = owner.platform.connectWifi(id, password);
        if (ok) self.services.notifyChanged();
        return ok;
    }

    fn disconnectWifi(ptr: *anyopaque, id: []const u8) bool {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return false;
        const ok = owner.platform.disconnectWifi(id);
        if (ok) self.services.notifyChanged();
        return ok;
    }

    fn readBattery(ptr: *anyopaque) Reading([]const Battery.Device) {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        if (self.owner == null) return .unavailable;
        return .{ .ok = self.battery_devices[0..self.battery_count] };
    }

    fn pollHardware(ptr: *anyopaque) void {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        self.refreshHardware();
        self.services.notifyChanged();
    }

    fn refreshHardware(self: *Platform) void {
        const owner = self.owner orelse return;
        self.network_state = if (owner.platform.readConnectivity()) |state| .{ .ok = .{
            .kind = switch (state.transport) {
                .none => .none,
                .ethernet => .ethernet,
                .wifi => .wifi,
                .cellular => .cellular,
            },
            .strength = if (state.strength) |percent| @min(4, @as(u8, @intCast((@as(u16, percent) * 4 + 99) / 100))) else 0,
            .networking_enabled = state.networking_enabled,
            .wifi_enabled = state.wifi_enabled,
            .cellular_enabled = state.cellular_enabled,
        } } else .unavailable;

        self.battery_count = 0;
        if (owner.platform.readPower()) |power| if (power.present) {
            self.battery_devices[0] = .{
                .id = "system-primary",
                .name = "System battery",
                .kind = .internal,
                .percent = power.percent,
                .status = switch (power.status) {
                    .charging, .pending => .charging,
                    .discharging => .discharging,
                    .full => .full,
                    .empty => .empty,
                    .unknown => .unknown,
                },
                .time_to_empty_s = if (power.time_to_empty_s) |seconds| @intCast(@min(seconds, std.math.maxInt(u32))) else null,
                .time_to_full_s = if (power.time_to_full_s) |seconds| @intCast(@min(seconds, std.math.maxInt(u32))) else null,
            };
            self.battery_count = 1;
        };
    }

    const apps_vtable = Apps.VTable{ .read = readApps, .launch = launchApp };

    fn readApps(ptr: *anyopaque) Reading([]const AppEntry) {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return .unavailable;
        if (phantom.compositor.fromOwner(owner)) |host| {
            for (self.entries) |*entry| {
                entry.running = host.isAppRunning(entry.id, entry.startup_wm_class);
            }
        }
        return .{ .ok = self.entries };
    }

    fn launchApp(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        const owner = self.owner orelse return error.AppsUnavailable;
        const environ = owner.environ orelse return error.NoEnvironment;
        const host = phantom.compositor.fromOwner(owner) orelse return error.NoCompositor;
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return host.launch(environ, entry.argv);
        }
        return error.AppNotFound;
    }

    fn compositorChanged(ptr: *anyopaque) void {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        self.services.notifyChanged();
    }

    fn initSession(self: *Platform) !void {
        if (!session_supported) return;
        const owner = self.owner orelse return error.NoBuildOwner;
        const environ = owner.environ orelse return error.NoEnvironment;
        const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
        const session = try Session.create(owner.gpa, self.io, runtime_dir);
        errdefer session.deinit();
        session.setChangeListener(self, sessionChanged);
        self.session = session;
        self.services.notifications = session.notifications();
        self.session_pump = try owner.scheduler.everyFrame(owner.gpa, self, pumpSession);
        if (phantom.compositor.fromOwner(owner)) |host| try host.setChildEnvironment("DBUS_SESSION_BUS_ADDRESS", session.address);
        std.debug.print("genesis: session D-Bus {s}\n", .{session.address});
    }

    fn pumpSession(ptr: *anyopaque) void {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        if (session_supported) if (self.session) |session| session.pump();
    }

    fn sessionChanged(ptr: *anyopaque) void {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        self.services.notifyChanged();
    }

    const clock_vtable = Clock.VTable{ .read = readClock };
    fn readClock(ptr: *anyopaque) Reading(Clock.State) {
        const self: *Platform = @ptrCast(@alignCast(ptr));
        // .real is wall-clock time (nanoseconds since the Unix epoch); the
        // bar shows a time of day, not an uptime. This call cannot fail.
        const ts = std.Io.Clock.now(.real, self.io);
        return .{ .ok = .{ .unix_ns = ts.nanoseconds } };
    }
};

fn realIo(threaded: *std.Io.Threaded) std.Io {
    return threaded.io();
}

test "the system clock moves between two reads rather than repeating a constant" {
    // init_single_threaded needs no deinit and spawns no threads, but its
    // clock functions are the real posix ones, so `now` reads the actual
    // wall clock rather than a stub.
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = realIo(&threaded);

    var platform = Platform{};
    platform.init(io);

    const first = platform.clock().read().ok.unix_ns;

    // Read until the reported time moves. A frozen provider, which is what the
    // web target shipped, never leaves this loop, so the bound turns the hang
    // into a failed assertion. CLOCK_REALTIME resolves to a nanosecond on
    // Linux, so one extra read is normally enough and the bound is never
    // approached. An earlier `second >= first` here could not tell a working
    // clock from a hardcoded literal.
    const max_reads = 1_000_000;
    var reads: u32 = 0;
    var second = first;
    while (second == first and reads < max_reads) : (reads += 1) {
        second = platform.clock().read().ok.unix_ns;
    }
    try std.testing.expect(second > first);

    // 2020-01-01T00:00:00Z in unix nanoseconds. A provider reporting an uptime
    // or a zero epoch offset advances too, so the floor still earns its place.
    const year_2020_ns: i96 = 1_577_836_800_000_000_000;
    try std.testing.expect(first >= year_2020_ns);
}

test "deinit puts every provider back on the sentinel a read after teardown is safe to take" {
    var threaded = std.Io.Threaded.init_single_threaded;
    var platform = Platform{};
    platform.init(realIo(&threaded));
    try std.testing.expect(platform.services.clock.read().shows());

    platform.deinit();
    try std.testing.expect(!platform.services.clock.read().shows());
}

test "an unwired battery on the system platform reports nothing to show" {
    // Pins the capability model rather than a crash: reading a provider
    // Services{} left on its unavailable default must degrade cleanly, not
    // dereference an unset pointer.
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = realIo(&threaded);

    var platform = Platform{};
    platform.init(io);

    try std.testing.expect(!platform.services.battery.read().shows());
}
