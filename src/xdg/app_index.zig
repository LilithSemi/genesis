const std = @import("std");
const desktop_entry = @import("desktop_entry.zig");
const Entry = @import("../services/apps.zig").Entry;

const icon_themes = [_][]const u8{ "hicolor", "Papirus-Light", "Papirus-Dark", "Papirus", "Adwaita", "breeze", "breeze-dark" };
const icon_sizes = [_][]const u8{ "64x64", "scalable", "128x128", "48x48", "96x96", "256x256", "32x32" };
const icon_extensions = [_][]const u8{ ".png", ".svg" };

fn iconKey(name: []const u8) []const u8 {
    for (icon_extensions) |ext| if (std.mem.endsWith(u8, name, ext)) return name[0 .. name.len - ext.len];
    return name;
}

fn scanIconDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    wanted: *const std.StringHashMapUnmanaged(void),
    found: *std.StringHashMapUnmanaged([]const u8),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |item| {
        if (item.kind != .file and item.kind != .sym_link) continue;
        const key = iconKey(item.name);
        if (key.len == item.name.len or !wanted.contains(key) or found.contains(key)) continue;
        const bytes = dir.readFileAlloc(io, item.name, allocator, .limited(4 * 1024 * 1024)) catch continue;
        try found.put(allocator, try allocator.dupe(u8, key), bytes);
    }
}

fn scanIconsRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    wanted: *const std.StringHashMapUnmanaged(void),
    found: *std.StringHashMapUnmanaged([]const u8),
) !void {
    for (icon_themes) |theme| for (icon_sizes) |size| {
        const path = try std.fmt.allocPrint(allocator, "{s}/icons/{s}/{s}/apps", .{ root, theme, size });
        try scanIconDir(allocator, io, path, wanted, found);
    };
    const pixmaps = try std.fmt.allocPrint(allocator, "{s}/pixmaps", .{root});
    try scanIconDir(allocator, io, pixmaps, wanted, found);
}

fn readAbsoluteIcon(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024)) catch null;
}

fn resolveIcons(
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: []Entry,
    roots: []const []const u8,
) !void {
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    var found: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (entries) |*entry| {
        if (entry.icon.len == 0) continue;
        if (std.fs.path.isAbsolute(entry.icon)) {
            entry.icon_bytes = readAbsoluteIcon(allocator, io, entry.icon) orelse "";
        } else {
            try wanted.put(allocator, try allocator.dupe(u8, iconKey(entry.icon)), {});
        }
    }
    for (roots) |root| try scanIconsRoot(allocator, io, root, &wanted, &found);
    for (entries) |*entry| if (!std.fs.path.isAbsolute(entry.icon)) {
        entry.icon_bytes = found.get(iconKey(entry.icon)) orelse "";
    };
}

fn scanApplicationsDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    entries: *std.ArrayList(Entry),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |item| {
        if ((item.kind != .file and item.kind != .sym_link) or !std.mem.endsWith(u8, item.name, ".desktop")) continue;
        if (seen.contains(item.name)) continue;
        try seen.put(allocator, try allocator.dupe(u8, item.name), {});

        const bytes = dir.readFileAlloc(io, item.name, allocator, .limited(1024 * 1024)) catch continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, item.name });
        const parsed = desktop_entry.parse(bytes);
        if (try desktop_entry.toEntry(allocator, item.name, full_path, parsed)) |entry| {
            try entries.append(allocator, entry);
        }
    }
}

fn scanDataRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    entries: *std.ArrayList(Entry),
) !void {
    if (root.len == 0) return;
    const path = try std.fmt.allocPrint(allocator, "{s}/applications", .{root});
    try scanApplicationsDir(allocator, io, path, seen, entries);
}

/// Build the XDG application index in precedence order: user entries first,
/// then each system data directory. A desktop-file id seen earlier shadows a
/// later one, including a hidden entry, as required by the XDG lookup rules.
pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var data_roots: std.ArrayList([]const u8) = .empty;

    if (environ.get("XDG_DATA_HOME")) |home| {
        try data_roots.append(allocator, try allocator.dupe(u8, home));
        try scanDataRoot(allocator, io, home, &seen, &entries);
    } else if (environ.get("HOME")) |home| {
        const user_data = try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
        try data_roots.append(allocator, user_data);
        try scanDataRoot(allocator, io, user_data, &seen, &entries);
    }

    const system_dirs = environ.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share:/run/current-system/sw/share";
    var roots = std.mem.splitScalar(u8, system_dirs, ':');
    while (roots.next()) |root| {
        if (root.len == 0) continue;
        try data_roots.append(allocator, try allocator.dupe(u8, root));
        try scanDataRoot(allocator, io, root, &seen, &entries);
    }

    try resolveIcons(allocator, io, entries.items, data_roots.items);

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
        }
    }.lessThan);
    return entries.toOwnedSlice(allocator);
}

test "scan returns visible XDG applications in name order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "applications");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "applications/zeta.desktop",
        .data = "[Desktop Entry]\nType=Application\nName=Zeta\nExec=zeta\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "applications/alpha.desktop",
        .data = "[Desktop Entry]\nType=Application\nName=Alpha\nExec=alpha %U\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "applications/hidden.desktop",
        .data = "[Desktop Entry]\nType=Application\nName=Hidden\nExec=hidden\nNoDisplay=true\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_DATA_HOME", path_buf[0..path_len]);
    try environ.put("XDG_DATA_DIRS", "");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try scan(arena.allocator(), std.testing.io, &environ);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Alpha", entries[0].name);
    try std.testing.expectEqualStrings("Zeta", entries[1].name);
}

test "scan resolves an application icon from the XDG hicolor theme" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "applications");
    try tmp.dir.createDirPath(std.testing.io, "icons/hicolor/64x64/apps");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "applications/demo.desktop", .data = "[Desktop Entry]\nType=Application\nName=Demo\nExec=demo\nIcon=demo\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icons/hicolor/64x64/apps/demo.svg", .data = "<svg width=\"1\" height=\"1\"></svg>" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_DATA_HOME", path_buf[0..path_len]);
    try environ.put("XDG_DATA_DIRS", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try scan(arena.allocator(), std.testing.io, &environ);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(std.mem.startsWith(u8, entries[0].icon_bytes, "<svg"));
}
