const std = @import("std");

pub const String = struct {
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) String {
        return .{ .data = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(string: *String) void {
        string.data.deinit();
    }

    pub fn set(string: *String, text: []const u8) !void {
        string.data.clearRetainingCapacity();
        try string.data.appendSlice(text);
    }
};
