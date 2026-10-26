//! The three shapes a Genesis surface takes. One shell reflows between a
//! workstation, a tablet and a phone, so every layout decision that depends on
//! the room available reads this one name instead of comparing widths again.
const std = @import("std");

pub const FormFactor = enum {
    phone,
    tablet,
    desktop,

    /// Logical width, in the same units MediaQuery reports. The ranges are half
    /// open, so a width on a breakpoint belongs to the wider factor and never
    /// to both.
    pub fn fromWidth(width: f32) FormFactor {
        if (width < 600) return .phone;
        if (width < 1100) return .tablet;
        return .desktop;
    }
};

test "fromWidth maps the three reference sizes to the three form factors" {
    // 390 is an iPhone 14, 834 is an iPad Pro 11 held upright and 1280 is a
    // small laptop.
    try std.testing.expectEqual(FormFactor.phone, FormFactor.fromWidth(390));
    try std.testing.expectEqual(FormFactor.tablet, FormFactor.fromWidth(834));
    try std.testing.expectEqual(FormFactor.desktop, FormFactor.fromWidth(1280));
}

test "a tablet turned on its side gets the desktop layout, because it has the room" {
    // 1180 is an iPad Pro 11 held sideways. It is a tablet as hardware and a
    // desktop as a layout, and the width is what decides.
    try std.testing.expectEqual(FormFactor.desktop, FormFactor.fromWidth(1180));
}

test "the breakpoints are half open so a width never maps to two form factors" {
    // 600 and 1100 are the boundaries. An off by one here silently changes the
    // layout of every device that sits exactly on a breakpoint.
    try std.testing.expectEqual(FormFactor.phone, FormFactor.fromWidth(599));
    try std.testing.expectEqual(FormFactor.tablet, FormFactor.fromWidth(600));
    try std.testing.expectEqual(FormFactor.tablet, FormFactor.fromWidth(1099));
    try std.testing.expectEqual(FormFactor.desktop, FormFactor.fromWidth(1100));
}

test "a zero width resolves to the phone rather than crashing the layout" {
    // A compositor can send a zero sized configure during startup, and a widget
    // mounted with no MediaQuery ancestor reads the same zero.
    try std.testing.expectEqual(FormFactor.phone, FormFactor.fromWidth(0));
}
