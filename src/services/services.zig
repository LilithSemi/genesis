const std = @import("std");
const phantom = @import("phantom");
const platform = @import("../platform.zig");
const clock_mod = @import("clock.zig");
const battery_mod = @import("battery.zig");
const network_mod = @import("network.zig");
const apps_mod = @import("apps.zig");
const notifications_mod = @import("notifications.zig");

const Clock = clock_mod.Clock;
const Battery = battery_mod.Battery;
const Network = network_mod.Network;
const Apps = apps_mod.Apps;
const Notifications = notifications_mod.Notifications;

/// The one name the tree uses for the platform implementation. `platform.zig`
/// is the only file that reads the target.
const Platform = platform.Impl;

/// What a provider knows, and whether it can know it here at all.
/// `unsupported` is a comptime property of the platform. The rest are runtime
/// states. The bar renders an indicator only for `pending` and `ok`.
pub fn Reading(comptime T: type) type {
    return union(enum) {
        unsupported,
        unavailable,
        pending,
        ok: T,

        /// True when there is something worth putting on screen.
        pub fn shows(self: @This()) bool {
            return switch (self) {
                .unsupported, .unavailable => false,
                .pending, .ok => true,
            };
        }
    };
}

/// What gets handed down the widget tree. A widget reaches a provider
/// through `ServicesScope.of(bctx).clock.read()`, never through a
/// platform-specific type such as `Fixtures`.
///
/// `clock`, `battery` and `network` default to each provider's `unavailable`
/// sentinel, so a `Services{}` built before the platform implementation
/// wires it up reports a blank indicator instead of reading an undefined
/// pointer. The platform implementation (`Fixtures`, and later `linux.zig` /
/// `web.zig`) replaces them with real providers at construction.
///
/// Change notification. A provider fires this after it mutates its own
/// state; it never fires from inside a widget build and no build blocks on
/// IO. `ServicesHost.initState` (a later task) wires `changed_fn` to
/// `markNeedsBuild` on itself once mounted. Both fields stay optional
/// because a provider can be driven, or a bus signal can arrive, before
/// mount or after unmount.
pub const Services = struct {
    clock: Clock = Clock.unavailable,
    battery: Battery = Battery.unavailable,
    network: Network = Network.unavailable,
    apps: Apps = Apps.unavailable,
    notifications: Notifications = Notifications.unavailable,

    changed_ctx: ?*anyopaque = null,
    changed_fn: ?*const fn (*anyopaque) void = null,

    pub fn notifyChanged(self: *Services) void {
        if (self.changed_fn) |f| f(self.changed_ctx.?);
    }
};

/// What `ServicesScope.of` reports outside a `ServicesHost`. Every provider is
/// `unavailable`, so a widget mounted on its own (a layout test, an error
/// subtree) draws a blank indicator instead of following a null pointer.
/// Read-only: nothing ever writes it.
const unwired = Services{};

/// Carries a `*Services` down the tree. A widget asks for the nearest one with
/// `ServicesScope.of(b)` and never learns which platform produced it. This is
/// phantom's `Theme` inherited-widget shape with `Services` as the slot type.
pub const ServicesScope = struct {
    services: *Services,
    child: phantom.Widget,

    const vtable = phantom.Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const ServicesScope) phantom.Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The nearest ancestor `Services`, else a blank set in which every
    /// provider reports `unavailable`. Read-only: a widget reads through the
    /// result but never mutates it, so callers get `*const Services`.
    pub fn of(bctx: *phantom.BuildContext) *const Services {
        return phantom.inheritedOf(bctx.element, Services) orelse &unwired;
    }

    fn mount(
        ptr: *const anyopaque,
        bctx: *phantom.BuildContext,
        parent: ?*phantom.Element,
    ) anyerror!*phantom.Element {
        const self: *const ServicesScope = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const el = try gpa.create(phantom.Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(ServicesScope),
            .render_object = null,
            .inherited_id = phantom.typeId(Services),
            .inherited_data = self.services,
            .depth = phantom.widget.depthOf(parent),
        };
        el.child = try el.updateChild(null, self.child, bctx);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *phantom.Element, bctx: *phantom.BuildContext) anyerror!void {
        const self: *const ServicesScope = @ptrCast(@alignCast(ptr));
        el.inherited_data = self.services;
        el.child = try el.updateChild(el.child, self.child, bctx);
    }
};

/// Owns the platform providers for as long as its subtree is mounted, and
/// publishes them through a `ServicesScope`. A provider change rebuilds this
/// host, so every reader below it sees the new reading on the next frame.
pub const ServicesHost = struct {
    /// Must live at an address that outlives the build pass that produced it.
    /// A provider change rebuilds this host alone, after the build arena was
    /// reset, so the parent keeps its child config on its own State.
    child: phantom.Widget,

    /// When null the host builds the platform implementation for this target.
    /// A test passes its own fixture-backed Services so a widget test never
    /// depends on which platform it compiled for. The caller keeps ownership
    /// and must outlive the mounted tree.
    services: ?*Services = null,

    pub const State = struct {
        base: phantom.StateBase = .{},
        /// On the heap because every provider handle inside `services` points
        /// back at this struct. A State that moved or was copied would leave
        /// those handles aimed at the old address. Null when the caller
        /// injected its own services.
        platform: ?*Platform = null,
        /// What the scope publishes. Points into `platform` when this State
        /// built one, at the caller's set when one was injected.
        services: ?*Services = null,
        /// True only when `platform` was allocated here. `dispose` frees on
        /// this flag alone, because freeing an injected set would be a double
        /// free the moment the caller's own defer runs.
        owns_platform: bool = false,
        child: phantom.Widget = undefined,
        scope: ServicesScope = undefined,

        pub fn initState(s: *@This(), config: *const ServicesHost) anyerror!void {
            // initState is the only hook that sees the widget config; build
            // does not, so the choice is made once, here.
            if (config.services) |injected| {
                s.services = injected;
            } else {
                const p = try s.base.gpa().create(Platform);
                p.* = .{};
                if (@hasDecl(Platform, "initWithOwner"))
                    p.initWithOwner(s.base.io(), s.base.element.owner)
                else
                    p.init(s.base.io());
                s.platform = p;
                s.services = &p.services;
                s.owns_platform = true;
            }
            // init() replaces the whole services struct, so the listener goes
            // on after it, never before.
            s.services.?.changed_ctx = s;
            s.services.?.changed_fn = onChanged;
            s.child = config.child;
        }

        pub fn didUpdateWidget(s: *@This(), config: *const ServicesHost) anyerror!void {
            // The provider set is chosen once, in initState, because the
            // ownership decision it makes cannot be undone mid-frame: the
            // subtree below is still reading the platform this State would
            // have to free. A rebuild that changes `services` therefore breaks
            // the widget's contract rather than describing a new runtime
            // state, so it is asserted instead of being dropped in silence.
            if (config.services) |injected| {
                std.debug.assert(!s.owns_platform);
                std.debug.assert(s.services == injected);
            } else {
                std.debug.assert(s.owns_platform);
            }
            s.child = config.child;
        }

        pub fn dispose(s: *@This()) void {
            if (s.services) |svc| {
                // Unhook before the free: a provider that fires from a timer
                // in this window would otherwise mark a dead element for
                // rebuild. Injected services keep running after this, so the
                // unhook matters most for them.
                svc.changed_ctx = null;
                svc.changed_fn = null;
            }
            s.services = null;
            if (!s.owns_platform) return;
            if (s.platform) |p| {
                // Every platform answers `deinit`. Today it only unwires the
                // provider handles, but the D-Bus backend owns a connection and
                // a heap device list, and a bare `destroy` would leak the list
                // and leave the socket open.
                p.deinit();
                s.base.gpa().destroy(p);
            }
            s.platform = null;
            s.owns_platform = false;
        }

        // anyerror matches phantom's StateVTable.build signature. It is a shim,
        // not a library error surface.
        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            _ = b;
            const svc = s.services orelse return error.ServicesHostNotInitialised;
            s.scope = .{ .services = svc, .child = s.child };
            return s.scope.widget();
        }

        fn onChanged(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            phantom.markNeedsBuild(s);
        }
    };

    pub fn widget(self: *const ServicesHost) phantom.Widget {
        return phantom.StatefulWidget(ServicesHost, self);
    }
};

// Stand-in providers for tests that exercise notifyChanged and do not care
// which clock, battery or network they carry. Every read reports
// unsupported since no test here inspects a reading.
var stub_target: u8 = 0;

fn stubClockRead(ptr: *anyopaque) Reading(Clock.State) {
    _ = ptr;
    return .unsupported;
}
fn stubBatteryRead(ptr: *anyopaque) Reading([]const Battery.Device) {
    _ = ptr;
    return .unsupported;
}
fn stubNetworkRead(ptr: *anyopaque) Reading(Network.State) {
    _ = ptr;
    return .unsupported;
}

const stub_clock_vtable = Clock.VTable{ .read = stubClockRead };
const stub_battery_vtable = Battery.VTable{ .read = stubBatteryRead };
const stub_network_vtable = Network.VTable{ .read = stubNetworkRead };

fn stubClock() Clock {
    return .{ .ptr = &stub_target, .vtable = &stub_clock_vtable };
}
fn stubBattery() Battery {
    return .{ .ptr = &stub_target, .vtable = &stub_battery_vtable };
}
fn stubNetwork() Network {
    return .{ .ptr = &stub_target, .vtable = &stub_network_vtable };
}

test "only pending and ok are worth rendering" {
    const R = Reading(u8);
    try std.testing.expect(!(R{ .unsupported = {} }).shows());
    try std.testing.expect(!(R{ .unavailable = {} }).shows());
    try std.testing.expect((R{ .pending = {} }).shows());
    try std.testing.expect((R{ .ok = 5 }).shows());
}

test "notifyChanged reaches the registered listener exactly once per call" {
    var fired: u32 = 0;
    var s = Services{
        .clock = stubClock(),
        .battery = stubBattery(),
        .network = stubNetwork(),
        .changed_ctx = &fired,
        .changed_fn = struct {
            fn f(ctx: *anyopaque) void {
                const c: *u32 = @ptrCast(@alignCast(ctx));
                c.* += 1;
            }
        }.f,
    };
    s.notifyChanged();
    s.notifyChanged();
    try std.testing.expectEqual(@as(u32, 2), fired);
}

test "notifyChanged with no listener is a no-op, not a crash" {
    // Services exist before the host widget mounts and after it unmounts. A
    // provider that fires in either window must not take the shell down.
    var s = Services{ .clock = stubClock(), .battery = stubBattery(), .network = stubNetwork() };
    s.notifyChanged();
}

test "an unwired Services reports every provider as unavailable rather than crashing" {
    // Forgetting init() used to be undefined behaviour. It must now be a
    // blank indicator, which is exactly what `unavailable` means.
    var s = Services{};
    try std.testing.expect(!s.clock.read().shows());
    try std.testing.expect(!s.battery.read().shows());
    try std.testing.expect(!s.network.read().shows());
}

test "notifyChanged on an unwired Services is a no-op" {
    var s = Services{};
    s.notifyChanged();
}

/// Widget tests below inject this rather than read `Platform`, so they pin the
/// same facts whichever target they were built for.
const Fixtures = platform.fixtures.Fixtures;

/// A mounted tree plus the scratch every widget test here needs. Keeping the
/// arena and the owner in one struct stops each test repeating six lines of
/// setup that say nothing about the fact it pins.
const Harness = struct {
    sink: phantom.FaultSink = .{},
    owner: phantom.BuildOwner = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(self: *Harness) void {
        self.owner = .{ .gpa = std.testing.allocator, .sink = &self.sink };
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        self.owner.deinit();
    }

    fn context(self: *Harness) phantom.BuildContext {
        return .{ .arena = self.arena.allocator(), .owner = &self.owner };
    }
};

test "ServicesScope.of returns the same Services a descendant element asks for" {
    var h = Harness{};
    h.init();
    defer h.deinit();
    var bctx = h.context();

    var fx = Fixtures{};
    fx.init(std.Io.failing);
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var scope = ServicesScope{ .services = &fx.services, .child = box.widget() };

    const el = try scope.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    var child_ctx = h.context();
    child_ctx.element = el.child;
    try std.testing.expect(ServicesScope.of(&child_ctx) == &fx.services);
}

test "a fixture change while mounted marks the host for rebuild" {
    var h = Harness{};
    h.init();
    defer h.deinit();
    var bctx = h.context();

    var fx = Fixtures{};
    fx.init(std.Io.failing);

    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var host = ServicesHost{ .child = box.widget(), .services = &fx.services };
    const el = try host.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), h.owner.dirty.items.len);

    // Driving the injected fixture, not whatever the target selected: the
    // listener the host hooked onto it is what schedules the rebuild.
    fx.setNetwork(.{ .ok = .{ .kind = .ethernet, .strength = 0 } });

    try std.testing.expectEqual(@as(usize, 1), h.owner.dirty.items.len);
}

// Test-only stateful widget: records what ServicesScope.of(b) hands back
// during its own build, so a test can inspect it after mount.
const OfProbe = struct {
    seen: *?*const Services,

    pub const State = struct {
        base: phantom.StateBase = .{},
        seen: *?*const Services = undefined,
        box: phantom.ColoredBox = undefined,

        pub fn initState(s: *@This(), config: *const OfProbe) anyerror!void {
            s.seen = config.seen;
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            s.seen.* = ServicesScope.of(b);
            s.box = .{ .color = phantom.Color.rgb(0, 0, 0), .radius = 0 };
            return s.box.widget();
        }
    };

    pub fn widget(self: *const OfProbe) phantom.Widget {
        return phantom.StatefulWidget(OfProbe, self);
    }
};

test "of with no ancestor scope returns a blank set rather than reaching a mutable global" {
    var h = Harness{};
    h.init();
    defer h.deinit();
    var bctx = h.context();

    var seen: ?*const Services = null;
    var probe = OfProbe{ .seen = &seen };
    const el = try probe.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    const found = seen orelse return error.OfDidNotRun;
    try std.testing.expect(!found.clock.read().shows());
    try std.testing.expect(!found.battery.read().shows());
    try std.testing.expect(!found.network.read().shows());
}

test "ServicesHost releases its platform services when unmounted" {
    // No assertion here on purpose: std.testing.allocator fails the test on a
    // leak, so an unfreed platform allocation is the failure.
    var h = Harness{};
    h.init();
    defer h.deinit();
    var bctx = h.context();

    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var host = ServicesHost{ .child = box.widget() };
    const el = try host.widget().mount(&bctx, null);
    el.deinit(std.testing.allocator);
}

test "an injected Services is not freed when the host unmounts" {
    // The caller owns injected services. Freeing them here would be a double
    // free the moment the caller's own defer runs. std.testing.allocator
    // catches the mirror bug, a leak, if the ownership flag is inverted.
    var h = Harness{};
    h.init();
    defer h.deinit();
    var bctx = h.context();

    var fx = Fixtures{};
    fx.init(std.Io.failing);

    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var host = ServicesHost{ .child = box.widget(), .services = &fx.services };
    const el = try host.widget().mount(&bctx, null);

    const state: *ServicesHost.State = @ptrCast(@alignCast(el.state.?));
    try std.testing.expect(!state.owns_platform);
    try std.testing.expect(state.platform == null);

    el.deinit(std.testing.allocator);

    // The fixtures still answer after the tree that used them is gone, and
    // the unhooked notifier no longer reaches the freed State.
    fx.setNetwork(.{ .ok = .{ .kind = .ethernet, .strength = 0 } });
    try std.testing.expectEqual(Network.Kind.ethernet, fx.services.network.read().ok.kind);
}
