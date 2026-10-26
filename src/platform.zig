const std = @import("std");
const builtin = @import("builtin");

/// The shipping backend for both targets: a working clock read through the
/// injected `std.Io`, and battery, network, volume and media left on the
/// `unavailable` sentinel until UPower, NetworkManager and the browser APIs
/// land. Nothing in it is Linux-specific, which is why one file serves the
/// native build and the web build.
pub const system = @import("platform/system.zig");

/// The mutable stand-in every widget test mounts. It never ships: a build that
/// selected it would put a frozen clock and an invented laptop battery in front
/// of a user. Named unconditionally because a test injects it into
/// `ServicesHost` on any target; that injection is what stops a widget test
/// depending on which platform it compiled for.
pub const fixtures = @import("platform/fixtures.zig");

/// The only file in the tree that reads the target. Widgets ask a provider for
/// a `Reading`; they never ask what platform they are on.
pub const impl = switch (builtin.target.os.tag) {
    .linux, .freestanding => system,
    else => @compileError("genesis: unsupported target"),
};

/// The platform type `ServicesHost` constructs when nothing is injected. Read
/// off `impl` rather than switched on the target again, so there is exactly one
/// place a new target gets added.
pub const Impl = impl.Platform;

test "the platform selected for this target wires a clock the bar can render" {
    // std.Io.failing answers a clock query with the zero timestamp instead of
    // trapping, so this pins the wiring on every target without a real IO
    // backend: an implementation that forgot to set services.clock reports
    // `unavailable` and fails here.
    var p = Impl{};
    p.init(std.Io.failing);
    try std.testing.expect(p.services.clock.read().shows());
}

test "fixtures report a battery worth rendering by default on every target" {
    var fx = fixtures.Fixtures{};
    try std.testing.expect(fx.battery().read().shows());
}

test "no target ships the fixtures as its platform" {
    // The web build used to select `Fixtures`, so it shipped a clock frozen at
    // 2026-01-01T00:04:00Z and a laptop battery no browser can see. Fixtures are
    // for tests, and a target arm pointed back at them must fail here.
    try std.testing.expect(Impl != fixtures.Fixtures);
}

test "the shipping platform leaves every provider it cannot answer on the unavailable sentinel" {
    // The design's provider table gives the real platform a clock on both
    // targets and nothing else this slice. `unavailable` is what makes the bar
    // close the gap instead of drawing a placeholder for a reading nobody has.
    var p = Impl{};
    p.init(std.Io.failing);
    try std.testing.expect(!p.services.battery.read().shows());
    try std.testing.expect(!p.services.network.read().shows());
}
