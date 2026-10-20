const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const directory = @import("directory.zig");

const registry = .{
    @import("btrfs.zig"),
    @import("xfs.zig"),
    @import("ext.zig"),
    directory.Backend("tmpfs", 0x01021994),
    directory.Backend("ramfs", 0x858458f6),
    directory.Backend("F2FS", 0xf2f52010),
    directory.Backend("FAT", 0x4d44),
    directory.Backend("exFAT", 0x2011bab0),
    directory.Backend("NTFS3", 0x7366746e),
    directory.Backend("OverlayFS", 0x794c7630),
    directory.Backend("SquashFS", 0x73717368),
    directory.Backend("EROFS", 0xe0f5e1e2),
    directory.Backend("OpenZFS", 0x2fc12fc1),
    directory.Backend("NFS", 0x6969),
    directory.Backend("SMB/CIFS", 0xff534d42),
    directory.Backend("SMB/CIFS", 0xfe534d42),
    directory,
};

pub fn search(io: std.Io, gpa: std.mem.Allocator, opts: common.Options, root: []const u8, dir: std.Io.Dir, collector: *common.Collector) !u8 {
    if (opts.backend == .walk) return directory.search(io, gpa, opts, root, dir, collector);
    if (comptime builtin.os.tag != .linux or
        (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64))
    {
        if (opts.backend == .native) return error.NativeUnsupported;
        return directory.search(io, gpa, opts, root, dir, collector);
    }
    const magic = (try @import("linux.zig").statFs(dir.handle)).kind;
    inline for (registry) |Backend| {
        if (Backend.supports(magic)) {
            if (comptime Backend.native) {
                Backend.probe(io, dir) catch |err| switch (err) {
                    error.NativePermissionDenied, error.NativeUnsupported => {
                        if (opts.backend == .native) return err;
                        return directory.search(io, gpa, opts, root, dir, collector);
                    },
                    else => return err,
                };
            } else if (opts.backend == .native) {
                if (!opts.json) std.debug.print("fslocate: {s} has no supported native filename-search API\n", .{Backend.name});
                return error.NativeUnsupported;
            }
            return Backend.search(io, gpa, opts, root, dir, collector);
        }
    }
    unreachable;
}
