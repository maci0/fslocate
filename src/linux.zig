const std = @import("std");
const linux = std.os.linux;
pub const ioc = linux.IOCTL;

pub fn openDirNoSymlinks(root_fd: i32, path: []const u8) ?std.Io.Dir {
    const OpenHow = extern struct { flags: u64, mode: u64 = 0, resolve: u64 = 0x04 };
    const how: OpenHow = .{ .flags = @as(u32, @bitCast(linux.O{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true })) };
    var remaining = path;
    var fd = root_fd;
    defer if (fd != root_fd) {
        _ = linux.close(fd);
    };
    while (true) {
        // Chunk at component boundaries so kernel path resolution also works beyond PATH_MAX.
        const end = if (remaining.len >= std.posix.PATH_MAX)
            std.mem.lastIndexOfScalar(u8, remaining[0 .. std.posix.PATH_MAX - 1], '/') orelse return null
        else
            remaining.len;
        const name = std.posix.toPosixPath(remaining[0..end]) catch return null;
        const result = linux.syscall4(.openat2, @as(u32, @bitCast(fd)), @intFromPtr(&name), @intFromPtr(&how), @sizeOf(OpenHow));
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (fd != root_fd) _ = linux.close(fd);
                fd = @intCast(result);
                if (end == remaining.len) {
                    const dir: std.Io.Dir = .{ .handle = fd };
                    fd = root_fd;
                    return dir;
                }
                remaining = remaining[end + 1 ..];
            },
            .INTR => continue,
            else => return null,
        }
    }
}

pub fn ioctl(fd: i32, request: u32, args: anytype) !void {
    while (true) {
        const result = linux.ioctl(fd, request, @intFromPtr(args));
        switch (linux.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            .PERM, .ACCES => return error.NativePermissionDenied,
            .NOTTY, .OPNOTSUPP, .NOSYS => return error.NativeUnsupported,
            .NOENT, .STALE => return error.FilesystemChanged,
            .OVERFLOW => return error.NativeBufferTooSmall,
            .NOMEM => return error.OutOfMemory,
            .IO => return error.InputOutput,
            else => return error.NativeQueryFailed,
        }
    }
}

pub const StatFs = extern struct {
    kind: usize,
    block_size: usize,
    blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    files: u64,
    free_files: u64,
    fsid: [2]i32,
    name_length: usize,
    fragment_size: usize,
    flags: usize,
    spare: [4]usize,
};

pub fn statFs(fd: i32) !StatFs {
    var stat: StatFs = undefined;
    while (true) {
        const result = linux.syscall2(.fstatfs, @intCast(fd), @intFromPtr(&stat));
        switch (linux.errno(result)) {
            .SUCCESS => return stat,
            .INTR => continue,
            else => return error.FilesystemDetectionFailed,
        }
    }
}

pub fn syncFs(fd: i32) !void {
    while (true) {
        switch (linux.errno(linux.syscall1(.syncfs, @intCast(fd)))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.FilesystemSyncFailed,
        }
    }
}

pub fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= 255 and
        std.mem.indexOfScalar(u8, name, 0) == null and
        std.mem.indexOfScalar(u8, name, '/') == null and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

test "openat2 rejects directory symlinks" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "real/child");
    try temporary.dir.symLink(io, "real", "alias", .{});
    const dir = openDirNoSymlinks(temporary.dir.handle, "real/child") orelse return error.SkipZigTest;
    dir.close(io);
    try std.testing.expect(openDirNoSymlinks(temporary.dir.handle, "alias/child") == null);
    try std.testing.expect(openDirNoSymlinks(-1, "real/child") == null);
}

test "metadata names cannot introduce path components" {
    // validName boundary: 255 ok, 256 reject, NUL, slash, dot variants already covered.
    try std.testing.expect(validName("raw-\xff"));
    for ([_][]const u8{ "", ".", "..", "a/b", "a\x00b" }) |name|
        try std.testing.expect(!validName(name));
    // 255-byte max valid, 256 invalid
    const max_name: [255]u8 = @splat('a');
    try std.testing.expect(validName(&max_name));
    const over_name: [256]u8 = @splat('a');
    try std.testing.expect(!validName(&over_name));
    // single char valid, hidden ".x" valid (not "." or "..")
    try std.testing.expect(validName("a"));
    try std.testing.expect(validName(".hidden"));
}
