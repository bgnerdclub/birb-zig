const std = @import("std");
const WindowEvent = @import("window.zig").WindowEvent;
const Window = @import("window.zig").Window;
const glfw = @import("mach-glfw");
const App = @import("app.zig").App;
const AppEvent = @import("app.zig").AppEvent;
const String = @import("string.zig").String;

pub const WindowModule = struct {
    app: *App,
    window: glfw.Window,
    title: String,
    size: @Vector(2, u32),

    fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    fn handle_get_window(module: *WindowModule, _: *WindowEvent.GetWindow) !*const Window {
        var window = try module.app.allocator.create(Window);
        window.* = .{ .title = module.title.data.items, .size = module.size };
        return window;
    }

    fn handle_set_title(module: *WindowModule, event: *WindowEvent.SetTitle) !void {
        try module.title.set(event.title);

        const title = try module.app.allocator.alloc(u8, event.title.len + 1);
        defer module.app.allocator.free(title);
        @memcpy(title[0..event.title.len], event.title);
        title[event.title.len] = 0;
        module.window.setTitle(title[0..(event.title.len) :0]);
    }

    pub fn init(module: *WindowModule, app: *App) !void {
        glfw.setErrorCallback(errorCallback);
        if (!glfw.init(.{})) {
            std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        }

        const window = glfw.Window.create(640, 480, "", null, null, .{}) orelse {
            std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        };

        module.* = WindowModule{ .app = app, .window = window, .title = String.init(app.allocator), .size = @Vector(2, u32){ 640, 480 } };
        try app.requests.register(WindowModule.handle_get_window, module);
        try app.events.register(WindowModule.handle_set_title, module);
    }

    pub fn deinit(module: *WindowModule) void {
        module.window.destroy();
        glfw.terminate();
    }

    pub fn start(_: *WindowModule) void {}

    pub fn tick(module: *WindowModule) void {
        module.window.swapBuffers();
        glfw.pollEvents();

        if (module.window.shouldClose()) {
            module.app.events.submit(AppEvent.Stop{}) catch unreachable;
        }
    }
};
