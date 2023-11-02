const std = @import("std");

pub const Window = struct { title: []const u8, size: @Vector(2, u32) };

pub const WindowEvent = struct {
    pub const Resize = struct {
        old: @Vector(2, u32),
        new: @Vector(2, u32),
    };

    pub const GetWindow = struct {
        pub const Response = *const Window;
    };

    pub const SetTitle = struct {
        title: []const u8,
    };
};
