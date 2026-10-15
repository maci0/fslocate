const std = @import("std");
const linux = std.os.linux;
pub const ioc = linux.IOCTL;

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
    const result = linux.syscall2(.fstatfs, @intCast(fd), @intFromPtr(&stat));
    if (linux.errno(result) != .SUCCESS) return error.FilesystemDetectionFailed;
    return stat;
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

test "metadata names cannot introduce path components" {
    try std.testing.expect(validName("raw-\xff"));
    for ([_][]const u8{ "", ".", "..", "a/b", "a\x00b" }) |name|
        try std.testing.expect(!validName(name));
}
