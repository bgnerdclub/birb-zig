const std = @import("std");
const birb = @import("birb");
const MultiArrayList = std.MultiArrayList;

const Birb = struct { id: u32 };

const BirbSystem = struct {
    const Self = @This();
    pub const Target = Birb;

    pub fn run(_: *Self, entities: *MultiArrayList(Birb)) void {
        for (entities.items(.id)) |*id| {
            id.* += 1;
        }
    }
};

const ITERATIONS = 1_000;
const NUM_ENTITIES = 100_000;

pub fn main() !void {
    comptime var tracker = birb.TypeTracker{};

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var app = birb.App.init(allocator);

    {
        var i: u32 = 0;
        while (i < NUM_ENTITIES) {
            try app.addEntity(Birb, &tracker, Birb{ .id = i });
            i += 1;
        }
    }

    var birbSystem = BirbSystem{};
    try app.addSystem(BirbSystem, &tracker, &birbSystem);
    try app.addModule(birb.glfw.WindowModule);

    app.start();

    const event = birb.WindowEvent.SetTitle{ .title = "owo" };
    _ = try app.events.submit(event);

    {
        var i: u32 = 0;
        const start = std.time.microTimestamp();
        while (i < ITERATIONS) {
            app.tick();
            i += 1;
        }
        const end = std.time.microTimestamp();

        std.debug.print("{d} iterations took {d}us", .{ ITERATIONS, end - start });
    }

    while (true) {}
}
