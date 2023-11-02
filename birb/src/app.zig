const std = @import("std");

pub fn typeId(comptime T: type) usize {
    _ = T;
    const something = struct { a: u8 }{ .a = 0 };
    return @intFromPtr(&something);
}

test "non-incrementing type tracker" {
    const id = typeId(u8);
    _ = typeId(u16);
    try std.testing.expect(typeId(u8) == id);
}

pub const TypeTracker = struct {
    types: []const type = &.{},

    pub fn getId(comptime tracker: *TypeTracker, comptime T: type) usize {
        if (!@inComptime()) @compileError("must be invoked at comptime");

        for (tracker.types, 0..) |t, i| if (T == t)
            return i;

        tracker.types = tracker.types ++ &[_]type{T};
        return tracker.types.len - 1;
    }
};

test "incrementing type tracker with primitives" {
    comptime var tracker = TypeTracker{};

    try std.testing.expect(comptime tracker.getId(u8) == 0);
    try std.testing.expect(comptime tracker.getId(u16) == 1);
    try std.testing.expect(comptime tracker.getId(u32) == 2);
    try std.testing.expect(comptime tracker.getId(u8) == 0);
}

const EventBus = struct {
    const Listener = struct { func: *const fn (*anyopaque, *anyopaque) *anyopaque, data: *anyopaque };

    allocator: std.mem.Allocator,
    listeners: std.AutoHashMap(usize, std.ArrayList(Listener)),

    pub fn init(allocator: std.mem.Allocator) EventBus {
        const listeners = std.AutoHashMap(usize, std.ArrayList(Listener)).init(allocator);
        return EventBus{ .allocator = allocator, .listeners = listeners };
    }

    pub fn deinit(self: *EventBus) void {
        var values = self.listeners.valueIterator();
        while (values.next()) |value| {
            value.deinit();
        }
        self.listeners.deinit();
    }

    pub fn submit(self: *EventBus, event: anytype) !std.ArrayList(@TypeOf(event).Response) {
        const id = typeId(@TypeOf(event));

        const listeners = self.listeners.get(id);
        const responseIsVoid = comptime @TypeOf(event).Response == void;
        var responses = std.ArrayList(@TypeOf(event).Response).init(self.allocator);
        if (listeners) |*l| {
            for (l.items) |*listener| {
                std.debug.print("{*}\n", .{listener.data});
                var response = listener.func(listener.data, @ptrCast(@constCast(&event)));
                if (!responseIsVoid) {
                    try responses.append(@ptrCast(response));
                }
            }
        }
        return responses;
    }

    pub fn register(self: *EventBus, func: anytype, data: @typeInfo(@TypeOf(func)).Fn.params[0].type.?) !void {
        std.debug.print("register {*}\n", .{data});
        const id = typeId(@typeInfo(@typeInfo(@TypeOf(func)).Fn.params[1].type.?).Pointer.child);
        const listener = Listener{ .func = @ptrCast(&func), .data = data };
        var listeners = self.listeners.get(id);
        if (listeners) |*l| {
            try l.append(listener);
        } else {
            var l = std.ArrayList(Listener).init(self.allocator);
            try l.append(listener);
            try self.listeners.put(id, l);
        }
        std.debug.print("register {*}\n", .{@as(@typeInfo(@TypeOf(func)).Fn.params[0].type.?, @ptrCast(@alignCast(listener.data)))});
    }
};

test "event bus" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Event = struct {
        data: u8,
        const Response = u8;
    };

    const Handler = struct {
        const Self = @This();

        fn handleEvent(_: *Self, event: *Event, _: *App) *u8 {
            return &event.data;
        }
    };

    var handler = Handler{};

    try app.registerListener(Handler, Event, &handler, Handler.handleEvent);
    var event = Event{ .data = 42 };
    const responses = try app.submit(event);
    defer responses.deinit();

    std.debug.assert(responses.items[0].* == event.data);
}

const SystemClosure = struct {
    run: *const fn (*anyopaque, *anyopaque) void,
    system: *anyopaque,
    target: usize,
};
const ModuleClosure = struct { start: *const fn (*anyopaque) void, deinit: *const fn (*anyopaque) void, tick: *const fn (*anyopaque) void, module: *anyopaque };

pub const App = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entities: std.ArrayList(*anyopaque),
    systems: std.ArrayList(SystemClosure),
    modules: std.ArrayList(ModuleClosure),
    events: EventBus,

    pub fn init(allocator: std.mem.Allocator) Self {
        const entities = std.ArrayList(*anyopaque).init(allocator);
        const systems = std.ArrayList(SystemClosure).init(allocator);
        const modules = std.ArrayList(ModuleClosure).init(allocator);
        const events = EventBus.init(allocator);
        return Self{ .allocator = allocator, .entities = entities, .systems = systems, .modules = modules, .events = events };
    }

    pub fn deinit(self: *Self) void {
        for (self.entities.items) |v| {
            var entities: *std.ArrayList(*anyopaque) = @ptrCast(@alignCast(v));
            entities.deinit();
        }

        self.systems.deinit();

        for (self.modules.items) |module| {
            module.deinit(module.module);
            self.allocator.free(module.module);
        }
        self.modules.deinit();
        self.events.deinit();
    }

    pub fn addEntity(self: *Self, comptime T: type, comptime tracker: *TypeTracker, entity: T) !void {
        const id = comptime tracker.getId(T);

        if (self.entities.items.len > id) {
            const entry: *std.MultiArrayList(T) = @alignCast(@ptrCast(self.entities.items[id]));
            try entry.append(self.allocator, entity);
        } else {
            const entities: *std.MultiArrayList(T) = try self.allocator.create(std.MultiArrayList(T));
            entities.* = std.MultiArrayList(T){};
            try entities.append(self.allocator, entity);
            try self.entities.append(entities);
        }
    }

    pub fn addSystem(self: *Self, comptime T: type, comptime tracker: *TypeTracker, system: *T) !void {
        const closure = SystemClosure{ .run = @ptrCast(&T.run), .system = system, .target = comptime tracker.getId(T.Target) };
        try self.systems.append(closure);
    }

    pub fn addModule(self: *Self, comptime T: type) !void {
        const module = try self.allocator.create(T);
        try module.init(self);
        const closure = ModuleClosure{ .start = @ptrCast(&T.start), .deinit = @ptrCast(&T.deinit), .tick = @ptrCast(&T.tick), .module = module };
        try self.modules.append(closure);
    }

    pub fn start(self: *Self) void {
        for (self.modules.items) |*m| {
            m.start(m.module);
        }
    }

    fn get(self: *Self, id: usize) ?*anyopaque {
        if (self.entities.items.len > id) {
            return self.entities.items[id];
        } else {
            return null;
        }
    }

    pub fn tick(self: *Self) void {
        for (self.modules.items) |*module| {
            module.tick(module.module);
        }

        for (self.systems.items) |*system| {
            if (self.get(system.target)) |entities| {
                system.run(system.system, entities);
            }
        }
    }
};
