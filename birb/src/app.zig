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

const RequestBus = struct {
    const Handler = struct { func: *const fn (*anyopaque, *anyopaque) anyerror!*anyopaque, data: *anyopaque };

    allocator: std.mem.Allocator,
    handlers: std.AutoHashMap(usize, std.ArrayList(Handler)),

    pub fn init(allocator: std.mem.Allocator) RequestBus {
        const handlers = std.AutoHashMap(usize, std.ArrayList(Handler)).init(allocator);
        return RequestBus{ .allocator = allocator, .handlers = handlers };
    }

    pub fn deinit(self: *RequestBus) void {
        var values = self.handlers.valueIterator();
        while (values.next()) |value| {
            value.deinit();
        }
        self.handlers.deinit();
    }

    pub fn submit(self: *RequestBus, event: anytype) !std.ArrayList(@TypeOf(event).Response) {
        const id = typeId(@TypeOf(event));

        const handlers = self.handlers.get(id);
        var responses = std.ArrayList(@TypeOf(event).Response).init(self.allocator);

        if (handlers) |*h| {
            for (h.items) |*handler| {
                var response = try handler.func(handler.data, @ptrCast(@constCast(&event)));
                try responses.append(@ptrCast(@alignCast(response)));
            }
        }

        return responses;
    }

    pub fn register(self: *RequestBus, func: anytype, data: @typeInfo(@TypeOf(func)).Fn.params[0].type.?) !void {
        const Wrapper = struct {
            fn handler(d: *anyopaque, e: *anyopaque) !*anyopaque {
                return @constCast(try func(@ptrCast(@alignCast(d)), @ptrCast(@alignCast(e))));
            }
        };

        const id = typeId(@typeInfo(@typeInfo(@TypeOf(func)).Fn.params[1].type.?).Pointer.child);
        const handler = Handler{ .func = &Wrapper.handler, .data = data };
        var handlers = self.handlers.get(id);
        if (handlers) |*h| {
            try h.append(handler);
        } else {
            var h = std.ArrayList(Handler).init(self.allocator);
            try h.append(handler);
            try self.handlers.put(id, h);
        }
    }
};

const EventBus = struct {
    const Handler = struct { func: *const fn (*anyopaque, *anyopaque) anyerror!void, data: *anyopaque };

    allocator: std.mem.Allocator,
    handlers: std.AutoHashMap(usize, std.ArrayList(Handler)),

    pub fn init(allocator: std.mem.Allocator) EventBus {
        const handlers = std.AutoHashMap(usize, std.ArrayList(Handler)).init(allocator);
        return EventBus{ .allocator = allocator, .handlers = handlers };
    }

    pub fn deinit(self: *EventBus) void {
        var values = self.handlers.valueIterator();
        while (values.next()) |value| {
            value.deinit();
        }
        self.handlers.deinit();
    }

    pub fn submit(self: *EventBus, event: anytype) !void {
        const id = typeId(@TypeOf(event));

        const handlers = self.handlers.get(id);

        if (handlers) |*h| {
            for (h.items) |*handler| {
                try handler.func(handler.data, @ptrCast(@constCast(&event)));
            }
        }
    }

    pub fn register(self: *EventBus, func: anytype, data: @typeInfo(@TypeOf(func)).Fn.params[0].type.?) !void {
        const Wrapper = struct {
            fn handler(d: *anyopaque, e: *anyopaque) !void {
                try func(@ptrCast(@alignCast(d)), @ptrCast(@alignCast(e)));
            }
        };

        const id = typeId(@typeInfo(@typeInfo(@TypeOf(func)).Fn.params[1].type.?).Pointer.child);
        const handler = Handler{ .func = &Wrapper.handler, .data = data };
        var handlers = self.handlers.get(id);
        if (handlers) |*h| {
            try h.append(handler);
        } else {
            var h = std.ArrayList(Handler).init(self.allocator);
            try h.append(handler);
            try self.handlers.put(id, h);
        }
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
const ModuleClosure = struct { start: *const fn (*anyopaque) void, deinit: *const fn (*anyopaque) void, run: *const fn (*anyopaque) void, module: *anyopaque };

pub const App = struct {
    const Self = @This();

    const State = enum { unstarted, started, running, finished };

    allocator: std.mem.Allocator,
    entities: std.ArrayList(*anyopaque),
    systems: std.ArrayList(SystemClosure),
    modules: std.ArrayList(ModuleClosure),
    events: EventBus,
    requests: RequestBus,
    state: State = State.unstarted,

    pub fn init(allocator: std.mem.Allocator) !Self {
        const entities = std.ArrayList(*anyopaque).init(allocator);
        const systems = std.ArrayList(SystemClosure).init(allocator);
        const modules = std.ArrayList(ModuleClosure).init(allocator);
        const events = EventBus.init(allocator);
        const requests = RequestBus.init(allocator);

        return Self{ .allocator = allocator, .entities = entities, .systems = systems, .modules = modules, .events = events, .requests = requests };
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

    pub fn addEntity(self: *Self, entity: anytype, comptime tracker: *TypeTracker) !void {
        const T = @TypeOf(entity);
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

    pub fn addSystem(self: *Self, system: anytype, comptime tracker: *TypeTracker) !void {
        if (self.state != State.unstarted) {
            unreachable;
        }

        const T = @typeInfo(@TypeOf(system)).Pointer.child;
        const closure = SystemClosure{ .run = @ptrCast(&T.run), .system = system, .target = comptime tracker.getId(T.Target) };
        try self.systems.append(closure);
    }

    pub fn addModule(self: *Self, comptime T: type) !void {
        if (self.state != State.unstarted) {
            unreachable;
        }

        const module = try self.allocator.create(T);
        try module.init(self);
        const closure = ModuleClosure{ .start = @ptrCast(&T.start), .deinit = @ptrCast(&T.deinit), .run = @ptrCast(&T.run), .module = module };
        try self.modules.append(closure);
    }

    pub fn start(self: *Self) !void {
        try self.events.register(Self.handle_stop, self);

        self.state = State.started;

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
            module.run(module.module);
        }

        for (self.systems.items) |*system| {
            if (self.get(system.target)) |entities| {
                system.run(system.system, entities);
            }
        }
    }

    pub fn run(self: *Self) void {
        self.state = State.running;

        while (self.state == State.running) {
            self.tick();
        }
    }

    fn handle_stop(self: *Self, _: *AppEvent.Stop) !void {
        self.state = State.finished;
    }
};

pub const AppEvent = struct {
    pub const Stop = struct {};
};
