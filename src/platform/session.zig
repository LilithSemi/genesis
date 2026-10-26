//! Linux session services owned by Genesis. A private dbus.zig daemon gives a
//! bare KMS session the same bus boundary that a nested development run uses.
const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus");
const notifications_mod = @import("../services/notifications.zig");
const Notifications = notifications_mod.Notifications;
const Notification = notifications_mod.Notification;
const Reading = @import("../services/services.zig").Reading;

const notification_path = "/org/freedesktop/Notifications";
const notification_interface = "org.freedesktop.Notifications";
const notification_name = "org.freedesktop.Notifications";

const OwnedNotification = struct {
    view: Notification,
    owned_actions: []Notification.Action,

    fn init(gpa: std.mem.Allocator, id: u32, app_name: []const u8, app_icon: []const u8, summary: []const u8, body: []const u8, created_ns: i96, expire_timeout_ms: i32, actions: []const Notification.Action) !OwnedNotification {
        const owned_app_name = try gpa.dupe(u8, app_name);
        errdefer gpa.free(owned_app_name);
        const owned_app_icon = try gpa.dupe(u8, app_icon);
        errdefer gpa.free(owned_app_icon);
        const owned_summary = try gpa.dupe(u8, summary);
        errdefer gpa.free(owned_summary);
        const owned_body = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_body);
        const owned_actions = try gpa.alloc(Notification.Action, actions.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_actions[0..initialized]) |action| {
                gpa.free(action.key);
                gpa.free(action.label);
            }
            gpa.free(owned_actions);
        }
        for (actions, 0..) |action, i| {
            const key = try gpa.dupe(u8, action.key);
            errdefer gpa.free(key);
            const label = try gpa.dupe(u8, action.label);
            owned_actions[i] = .{ .key = key, .label = label };
            initialized += 1;
        }
        return .{ .view = .{
            .id = id,
            .app_name = owned_app_name,
            .app_icon = owned_app_icon,
            .summary = owned_summary,
            .body = owned_body,
            .created_ns = created_ns,
            .expire_timeout_ms = expire_timeout_ms,
            .actions = owned_actions,
        }, .owned_actions = owned_actions };
    }

    fn deinit(self: *OwnedNotification, gpa: std.mem.Allocator) void {
        gpa.free(self.view.app_name);
        gpa.free(self.view.app_icon);
        gpa.free(self.view.summary);
        gpa.free(self.view.body);
        for (self.owned_actions) |action| {
            gpa.free(action.key);
            gpa.free(action.label);
        }
        gpa.free(self.owned_actions);
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket_path: []u8,
    address: []u8,
    daemon_loop: ?dbus.event_loop.EventLoop = null,
    daemon: ?*dbus.daemon.bus.Daemon = null,
    daemon_thread: ?std.Thread = null,
    client_loop: ?dbus.event_loop.EventLoop = null,
    bus: ?*dbus.client.Bus = null,
    methods: [4]dbus.object.Method = undefined,
    entries: std.ArrayList(OwnedNotification) = .empty,
    views: std.ArrayList(Notification) = .empty,
    next_id: u32 = 1,
    changed_ctx: ?*anyopaque = null,
    changed_fn: ?*const fn (*anyopaque) void = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, runtime_dir: []const u8) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        const socket_path = try std.fmt.allocPrint(gpa, "{s}/genesis-session-bus-{d}", .{ runtime_dir, linux.getpid() });
        errdefer gpa.free(socket_path);
        const address = try std.fmt.allocPrint(gpa, "unix:path={s}", .{socket_path});
        errdefer gpa.free(address);

        self.* = .{ .gpa = gpa, .io = io, .socket_path = socket_path, .address = address };
        errdefer self.deinit();

        unlinkSocket(socket_path);
        self.daemon_loop = try dbus.event_loop.EventLoop.init(gpa);
        self.daemon = try dbus.daemon.bus.Daemon.init(gpa, &self.daemon_loop.?, io);
        try self.daemon.?.listenUnix(socket_path, false);
        self.daemon_thread = try std.Thread.spawn(.{}, runDaemon, .{self.daemon.?});

        self.client_loop = try dbus.event_loop.EventLoop.init(gpa);
        for (0..3) |_| {
            self.bus = dbus.client.Bus.connectUnix(gpa, &self.client_loop.?, io, socket_path, false, linux.getuid()) catch continue;
            break;
        }
        if (self.bus == null) return error.SessionBusConnectionFailed;

        self.methods = .{
            .{ .name = "GetCapabilities", .handler = getCapabilities, .ctx = self, .out_sig = "as" },
            .{ .name = "Notify", .handler = notify, .ctx = self, .in_sig = "susssasa{sv}i", .out_sig = "u" },
            .{ .name = "CloseNotification", .handler = closeNotification, .ctx = self, .in_sig = "u" },
            .{ .name = "GetServerInformation", .handler = getServerInformation, .ctx = self, .out_sig = "ssss" },
        };
        const interfaces = [_]dbus.object.Interface{.{
            .name = notification_interface,
            .methods = &self.methods,
        }};
        try self.bus.?.exportObject(notification_path, &interfaces);
        try self.claimName();
        return self;
    }

    pub fn deinit(self: *Session) void {
        if (self.bus) |bus| {
            bus.deinit();
            self.bus = null;
        }
        if (self.client_loop) |*loop| {
            loop.deinit();
            self.client_loop = null;
        }
        if (self.daemon) |daemon| daemon.stop();
        if (self.daemon_thread) |thread| {
            thread.join();
            self.daemon_thread = null;
        }
        if (self.daemon) |daemon| {
            daemon.deinit();
            self.daemon = null;
        }
        if (self.daemon_loop) |*loop| {
            loop.deinit();
            self.daemon_loop = null;
        }
        for (self.entries.items) |*entry| entry.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.views.deinit(self.gpa);
        unlinkSocket(self.socket_path);
        self.gpa.free(self.socket_path);
        self.gpa.free(self.address);
        self.gpa.destroy(self);
    }

    pub fn pump(self: *Session) void {
        if (self.client_loop) |*loop| _ = loop.dispatch(0);
        const now = std.Io.Clock.now(.real, self.io).nanoseconds;
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const notification = self.entries.items[index].view;
            const timeout_ms: i64 = if (notification.expire_timeout_ms < 0) 5000 else notification.expire_timeout_ms;
            if (timeout_ms == 0) continue;
            const timeout_ns: i96 = @as(i96, timeout_ms) * std.time.ns_per_ms;
            if (now - notification.created_ns >= timeout_ns) self.remove(notification.id, 1);
        }
    }

    pub fn notifications(self: *Session) Notifications {
        return .{ .ptr = self, .vtable = &notifications_vtable };
    }

    pub fn setChangeListener(self: *Session, ctx: ?*anyopaque, callback: ?*const fn (*anyopaque) void) void {
        self.changed_ctx = ctx;
        self.changed_fn = callback;
    }

    fn changed(self: *Session) void {
        if (self.changed_fn) |callback| callback(self.changed_ctx.?);
    }

    fn runDaemon(daemon: *dbus.daemon.bus.Daemon) void {
        daemon.run();
    }

    fn claimName(self: *Session) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.marshal.Writer.init(self.gpa, &body, self.bus.?.conn.endian);
        try writer.string(notification_name);
        try writer.uint32(0);

        var result = NameResult{};
        _ = try self.bus.?.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "RequestName",
            .destination = "org.freedesktop.DBus",
            .body_signature = "su",
            .body = body.items,
        }, NameResult.reply, &result);
        var attempts: usize = 0;
        while (!result.done and attempts < 100) : (attempts += 1) _ = self.client_loop.?.dispatch(20);
        if (!result.done or (result.value != 1 and result.value != 4)) return error.NotificationNameUnavailable;
    }

    const NameResult = struct {
        done: bool = false,
        value: u32 = 0,

        fn reply(ctx: ?*anyopaque, _: *dbus.connection.Connection, message: ?*const dbus.Message) void {
            const self: *NameResult = @ptrCast(@alignCast(ctx.?));
            defer self.done = true;
            const msg = message orelse return;
            if (msg.msg_type != .method_return) return;
            var reader = dbus.unmarshal.Reader.init(msg.body, msg.endian);
            self.value = reader.uint32() catch 0;
        }
    };

    fn getCapabilities(_: ?*anyopaque, _: *const dbus.Message, writer: *dbus.marshal.Writer) dbus.object.HandlerError![]const u8 {
        const array = try writer.beginArray(dbus.types.alignmentOf(.string));
        try writer.string("body");
        try writer.string("persistence");
        try writer.string("actions");
        writer.endArray(array);
        return "as";
    }

    fn getServerInformation(_: ?*anyopaque, _: *const dbus.Message, writer: *dbus.marshal.Writer) dbus.object.HandlerError![]const u8 {
        try writer.string("Genesis");
        try writer.string("ExpidusOS");
        try writer.string("0.1.0");
        try writer.string("1.2");
        return "ssss";
    }

    fn notify(ctx: ?*anyopaque, call: *const dbus.Message, writer: *dbus.marshal.Writer) dbus.object.HandlerError![]const u8 {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        const id = self.acceptNotification(call) catch return error.Failed;
        try writer.uint32(id);
        return "u";
    }

    fn closeNotification(ctx: ?*anyopaque, call: *const dbus.Message, _: *dbus.marshal.Writer) dbus.object.HandlerError![]const u8 {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        var reader = dbus.unmarshal.Reader.init(call.body, call.endian);
        const id = reader.uint32() catch return error.Failed;
        self.remove(id, 3);
        return "";
    }

    fn acceptNotification(self: *Session, call: *const dbus.Message) !u32 {
        if (call.body_signature == null or !std.mem.eql(u8, call.body_signature.?, "susssasa{sv}i")) return error.BadSignature;
        var reader = dbus.unmarshal.Reader.init(call.body, call.endian);
        const app_name = try reader.string();
        const replaces_id = try reader.uint32();
        const app_icon = try reader.string();
        const summary = try reader.string();
        const body = try reader.string();
        const action_values = try reader.readValue(self.gpa, "as");
        defer dbus.unmarshal.freeValue(self.gpa, action_values);
        const hints = try reader.readValue(self.gpa, "a{sv}");
        defer dbus.unmarshal.freeValue(self.gpa, hints);
        const expire_timeout_ms = try reader.int32();
        if (reader.remaining() != 0) return error.TrailingData;

        const values = switch (action_values) {
            .array => |items| items,
            else => return error.BadActions,
        };
        if (values.len % 2 != 0) return error.BadActions;
        var parsed_actions: std.ArrayList(Notification.Action) = .empty;
        defer parsed_actions.deinit(self.gpa);
        var action_index: usize = 0;
        while (action_index < values.len) : (action_index += 2) {
            const key = switch (values[action_index]) {
                .string => |value| value,
                else => return error.BadActions,
            };
            const label = switch (values[action_index + 1]) {
                .string => |value| value,
                else => return error.BadActions,
            };
            try parsed_actions.append(self.gpa, .{ .key = key, .label = label });
        }

        var id = replaces_id;
        var replace_index: ?usize = null;
        if (id != 0) {
            for (self.entries.items, 0..) |entry, i| if (entry.view.id == id) {
                replace_index = i;
                break;
            };
        }
        if (replace_index == null) {
            id = self.next_id;
            self.next_id +%= 1;
            if (self.next_id == 0) self.next_id = 1;
        }
        var owned = try OwnedNotification.init(self.gpa, id, app_name, app_icon, summary, body, std.Io.Clock.now(.real, self.io).nanoseconds, expire_timeout_ms, parsed_actions.items);
        if (replace_index) |i| {
            self.entries.items[i].deinit(self.gpa);
            self.entries.items[i] = owned;
        } else {
            errdefer owned.deinit(self.gpa);
            if (self.entries.items.len == 64) {
                var oldest = self.entries.orderedRemove(0);
                oldest.deinit(self.gpa);
            }
            try self.entries.append(self.gpa, owned);
        }
        self.changed();
        return id;
    }

    fn emitClosed(self: *Session, id: u32, reason: u32) void {
        const bus = self.bus orelse return;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.marshal.Writer.init(self.gpa, &body, bus.conn.endian);
        writer.uint32(id) catch return;
        writer.uint32(reason) catch return;
        _ = bus.emitSignal(.{
            .msg_type = .signal,
            .serial = 0,
            .path = notification_path,
            .interface = notification_interface,
            .member = "NotificationClosed",
            .body_signature = "uu",
            .body = body.items,
        }) catch {};
    }

    fn emitAction(self: *Session, id: u32, action: []const u8) void {
        const bus = self.bus orelse return;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.marshal.Writer.init(self.gpa, &body, bus.conn.endian);
        writer.uint32(id) catch return;
        writer.string(action) catch return;
        _ = bus.emitSignal(.{
            .msg_type = .signal,
            .serial = 0,
            .path = notification_path,
            .interface = notification_interface,
            .member = "ActionInvoked",
            .body_signature = "us",
            .body = body.items,
        }) catch {};
    }

    fn remove(self: *Session, id: u32, reason: u32) void {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.view.id != id) continue;
            var removed = self.entries.orderedRemove(i);
            removed.deinit(self.gpa);
            self.emitClosed(id, reason);
            self.changed();
            return;
        }
    }

    const notifications_vtable = Notifications.VTable{
        .read = readNotifications,
        .dismiss = dismissNotification,
        .clear = clearNotifications,
        .invoke = invokeNotification,
    };

    fn readNotifications(ptr: *anyopaque) Reading([]const Notification) {
        const self: *Session = @ptrCast(@alignCast(ptr));
        self.views.clearRetainingCapacity();
        self.views.ensureTotalCapacity(self.gpa, self.entries.items.len) catch return .unavailable;
        for (self.entries.items) |entry| self.views.appendAssumeCapacity(entry.view);
        return .{ .ok = self.views.items };
    }

    fn dismissNotification(ptr: *anyopaque, id: u32) void {
        const self: *Session = @ptrCast(@alignCast(ptr));
        self.remove(id, 2);
    }

    fn clearNotifications(ptr: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(ptr));
        while (self.entries.items.len > 0) self.remove(self.entries.items[self.entries.items.len - 1].view.id, 2);
    }

    fn invokeNotification(ptr: *anyopaque, id: u32, action: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ptr));
        for (self.entries.items) |entry| if (entry.view.id == id) {
            self.emitAction(id, action);
            return;
        };
    }
};

fn unlinkSocket(path: []const u8) void {
    if (path.len + 1 > std.Io.Dir.max_path_bytes) return;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = linux.unlinkat(linux.AT.FDCWD, @ptrCast(&buf), 0);
}

test "owned notifications copy all strings and release them together" {
    const actions = [_]Notification.Action{.{ .key = "default", .label = "Open" }};
    var n = try OwnedNotification.init(std.testing.allocator, 4, "Mail", "mail", "Hello", "World", 10, 5000, &actions);
    defer n.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello", n.view.summary);
    try std.testing.expectEqual(@as(u32, 4), n.view.id);
    try std.testing.expectEqualStrings("Open", n.view.actions[0].label);
}

test "a D-Bus client can notify the Genesis server on its private session bus" {
    const gpa = std.heap.smp_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const session = try Session.create(gpa, io_threaded.io(), "/tmp");
    defer session.deinit();

    var client_loop = try dbus.event_loop.EventLoop.init(gpa);
    defer client_loop.deinit();
    // The daemon runs on another thread. Under a heavily loaded test runner a
    // freshly authenticated connection can occasionally miss the Hello reply
    // window in dbus.zig's synchronous constructor. Reconnect so this real-bus
    // integration test does not depend on host scheduling luck.
    var client: ?*dbus.client.Bus = null;
    for (0..3) |_| {
        client = dbus.client.Bus.connectUnix(gpa, &client_loop, io_threaded.io(), session.socket_path, false, linux.getuid()) catch continue;
        break;
    }
    const connected_client = client orelse return error.NotificationTestClientUnavailable;
    defer connected_client.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var writer = dbus.marshal.Writer.init(gpa, &body, connected_client.conn.endian);
    try writer.string("Test App");
    try writer.uint32(0);
    try writer.string("");
    try writer.string("Hello");
    try writer.string("From dbus.zig");
    const actions = try writer.beginArray(dbus.types.alignmentOf(.string));
    try writer.string("default");
    try writer.string("Open");
    writer.endArray(actions);
    const hints = try writer.beginArray(dbus.types.alignmentOf(.dict_begin));
    writer.endArray(hints);
    try writer.int32(-1);

    var reply = NotifyReply{};
    _ = try connected_client.call(.{
        .msg_type = .method_call,
        .serial = 0,
        .path = notification_path,
        .interface = notification_interface,
        .member = "Notify",
        .destination = notification_name,
        .body_signature = "susssasa{sv}i",
        .body = body.items,
    }, NotifyReply.receive, &reply);
    var attempts: usize = 0;
    while (!reply.done and attempts < 100) : (attempts += 1) {
        session.pump();
        _ = client_loop.dispatch(20);
    }
    try std.testing.expect(reply.done);
    try std.testing.expect(reply.id != 0);
    const items = session.notifications().read().ok;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Hello", items[0].summary);
    try std.testing.expectEqualStrings("default", items[0].actions[0].key);
    try std.testing.expectEqualStrings("Open", items[0].actions[0].label);
}

const NotifyReply = struct {
    done: bool = false,
    id: u32 = 0,

    fn receive(ctx: ?*anyopaque, _: *dbus.connection.Connection, message: ?*const dbus.Message) void {
        const self: *NotifyReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        const msg = message orelse return;
        if (msg.msg_type != .method_return) return;
        var reader = dbus.unmarshal.Reader.init(msg.body, msg.endian);
        self.id = reader.uint32() catch 0;
    }
};
