const std = @import("std");
const common = @import("common.zig");

pub const name = "directory";
pub const native = false;

pub fn supports(_: usize) bool {
    return true;
}

pub fn Backend(comptime filesystem_name: []const u8, comptime magic: usize) type {
    return struct {
        pub const name = filesystem_name;
        pub const native = false;
        pub const search = @import("directory.zig").search;

        pub fn supports(value: usize) bool {
            return value == magic;
        }
    };
}

pub const Reader = struct {
    buffer: [64 * 1024]u8 align(@alignOf(usize)) = undefined,
    reader: std.Io.Dir.Reader,

    pub fn init(_: std.Io, dir: std.Io.Dir, _: common.Backend) !Reader {
        return .{ .reader = .{
            .dir = dir,
            .state = .reading,
            .buffer = undefined,
            .index = 0,
            .end = 0,
        } };
    }

    pub fn next(self: *Reader, io: std.Io) !?std.Io.Dir.Entry {
        self.reader.buffer = &self.buffer;
        return self.reader.next(io);
    }
};

pub fn search(io: std.Io, gpa: std.mem.Allocator, opts: common.Options, root: []const u8, dir: std.Io.Dir, collector: *common.Collector) !u8 {
    return @import("walk.zig").run(Reader, io, gpa, opts, root, dir, collector);
}
