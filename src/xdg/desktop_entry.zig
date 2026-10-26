const std = @import("std");
const AppEntry = @import("../services/apps.zig").Entry;

pub const Parsed = struct {
    name: []const u8 = "",
    comment: []const u8 = "",
    icon: []const u8 = "",
    categories: []const u8 = "",
    startup_wm_class: []const u8 = "",
    exec: []const u8 = "",
    application: bool = false,
    hidden: bool = false,
    no_display: bool = false,
};

fn boolean(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "true");
}

/// Parse the locale-neutral keys from the Desktop Entry group. Localized keys
/// deliberately do not overwrite `Name`: locale selection belongs in the
/// platform provider once Genesis has a locale service.
pub fn parse(bytes: []const u8) Parsed {
    var result = Parsed{};
    var in_desktop_entry = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_desktop_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_desktop_entry) continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..split], " \t");
        const value = std.mem.trim(u8, line[split + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Type")) result.application = std.mem.eql(u8, value, "Application") else if (std.mem.eql(u8, key, "Name")) result.name = value else if (std.mem.eql(u8, key, "Comment")) result.comment = value else if (std.mem.eql(u8, key, "Icon")) result.icon = value else if (std.mem.eql(u8, key, "Categories")) result.categories = value else if (std.mem.eql(u8, key, "StartupWMClass")) result.startup_wm_class = value else if (std.mem.eql(u8, key, "Exec")) result.exec = value else if (std.mem.eql(u8, key, "Hidden")) result.hidden = boolean(value) else if (std.mem.eql(u8, key, "NoDisplay")) result.no_display = boolean(value);
    }
    return result;
}

fn appendFieldCode(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    code: u8,
    entry: Parsed,
    desktop_path: []const u8,
) !void {
    switch (code) {
        'c' => if (entry.name.len > 0) try list.append(allocator, try allocator.dupe(u8, entry.name)),
        'k' => try list.append(allocator, try allocator.dupe(u8, desktop_path)),
        // `%i` expands to two arguments according to the desktop-entry spec.
        'i' => if (entry.icon.len > 0) {
            try list.append(allocator, try allocator.dupe(u8, "--icon"));
            try list.append(allocator, try allocator.dupe(u8, entry.icon));
        },
        '%' => try list.append(allocator, try allocator.dupe(u8, "%")),
        // File and URL arguments are absent when launched from the app grid.
        'f', 'F', 'u', 'U' => {},
        else => {},
    }
}

/// Tokenize an Exec key without invoking a shell. Quotes and backslash escapes
/// are handled directly, and desktop-entry field codes are expanded only in
/// their standalone form. This keeps a crafted desktop file from becoming a
/// shell command injection surface.
pub fn argv(
    allocator: std.mem.Allocator,
    entry: Parsed,
    desktop_path: []const u8,
) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);
    var quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i <= entry.exec.len) : (i += 1) {
        const at_end = i == entry.exec.len;
        const ch: u8 = if (at_end) ' ' else entry.exec[i];
        if (escaped) {
            try token.append(allocator, ch);
            escaped = false;
            continue;
        }
        if (!at_end and ch == '\\') {
            escaped = true;
            continue;
        }
        if (!at_end and (ch == '\'' or ch == '"')) {
            if (quote == null) {
                quote = ch;
                continue;
            }
            if (quote.? == ch) {
                quote = null;
                continue;
            }
        }
        if ((at_end or std.ascii.isWhitespace(ch)) and quote == null) {
            if (token.items.len > 0) {
                if (token.items.len == 2 and token.items[0] == '%') {
                    try appendFieldCode(&args, allocator, token.items[1], entry, desktop_path);
                } else {
                    try args.append(allocator, try allocator.dupe(u8, token.items));
                }
                token.clearRetainingCapacity();
            }
            continue;
        }
        try token.append(allocator, ch);
    }
    return args.toOwnedSlice(allocator);
}

pub fn toEntry(
    allocator: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    parsed: Parsed,
) !?AppEntry {
    if (!parsed.application or parsed.hidden or parsed.no_display or parsed.name.len == 0 or parsed.exec.len == 0) return null;
    const command = try argv(allocator, parsed, path);
    if (command.len == 0) return null;
    return .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, parsed.name),
        .comment = try allocator.dupe(u8, parsed.comment),
        .icon = try allocator.dupe(u8, parsed.icon),
        .categories = try allocator.dupe(u8, parsed.categories),
        .startup_wm_class = try allocator.dupe(u8, parsed.startup_wm_class),
        .argv = command,
    };
}

test "desktop entry parser rejects hidden launchers" {
    const parsed = parse(
        "[Desktop Entry]\nType=Application\nName=Hidden\nExec=hidden %U\nNoDisplay=true\n",
    );
    try std.testing.expect(parsed.application);
    try std.testing.expect(parsed.no_display);
    try std.testing.expect((try toEntry(std.testing.allocator, "hidden.desktop", "/tmp/hidden.desktop", parsed)) == null);
}

test "Exec becomes argv without a shell and drops absent URL arguments" {
    const parsed = parse(
        "[Desktop Entry]\nType=Application\nName=Demo App\nIcon=demo\nExec=demo --name \"two words\" %U %c\n",
    );
    const args = try argv(std.testing.allocator, parsed, "/tmp/demo.desktop");
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("demo", args[0]);
    try std.testing.expectEqualStrings("two words", args[2]);
    try std.testing.expectEqualStrings("Demo App", args[3]);
}
