const std = @import("std");
const common = @import("common.zig");
const linux = @import("linux.zig");
const Allocator = std.mem.Allocator;

pub const name = "xfs";
pub const native = true;
pub fn supports(magic: usize) bool {
    return magic == 0x58465342;
}

const BulkHeader = extern struct {
    inode: u64 = 0,
    flags: u32 = 1 << 2,
    count: u32 = 256,
    returned: u32 = 0,
    agno: u32 = 0,
    reserved: [5]u64 = @splat(0),
};
const BulkStat = extern struct {
    inode: u64,
    size: u64,
    blocks: u64,
    xflags: u64,
    times: [4]i64,
    generation: u32,
    uid: u32,
    gid: u32,
    project_id: u32,
    nanoseconds: [4]u32,
    block_size: u32,
    rdev: u32,
    cow_extent_size: u32,
    extent_size: u32,
    links: u32,
    extents: u32,
    attr_extents: u32,
    version: u16,
    fork_offset: u16,
    sick: u16,
    checked: u16,
    mode: u16,
    pad: u16,
    extents64: u64,
    reserved: [6]u64,
};
const BulkArgs = extern struct { header: BulkHeader, records: [256]BulkStat };
const Handle = extern struct {
    fsid: u64,
    length: u16 = 14,
    pad: u16 = 0,
    generation: u32,
    inode: u64,
};
const HandleRequest = extern struct {
    fd: u32,
    path: usize = 0,
    flags: u32 = 0,
    input: usize = 0,
    input_length: u32 = 0,
    output: usize,
    output_length: usize,
};
const ParentRequest = extern struct {
    cursor: [4]u32 = @splat(0),
    input_flags: u16 = 0,
    output_flags: u16 = 0,
    buffer_size: u32 = 4096,
    reserved: u64 = 0,
    buffer: u64 = 0,
};
const ParentsByHandle = extern struct { handle: Handle, request: ParentRequest = .{} };
const ParentHeader = extern struct { handle: Handle, length: u32, reserved: u32 };
const Parent = struct { handle: Handle, name: []const u8 };

const bulkstat = linux.ioc.IOR('X', 127, BulkHeader);
const fd_to_handle = linux.ioc.IOWR('X', 106, HandleRequest);
const getparents = linux.ioc.IOWR('X', 63, ParentsByHandle);

fn rootHandle(dir: std.Io.Dir) !Handle {
    var handle: Handle = undefined;
    var length: u32 = @sizeOf(Handle);
    var request: HandleRequest = .{
        .fd = @intCast(dir.handle),
        .output = @intFromPtr(&handle),
        .output_length = @intFromPtr(&length),
    };
    try linux.ioctl(dir.handle, fd_to_handle, &request);
    if (length != @sizeOf(Handle) or handle.length != 14) return error.CorruptMetadata;
    return handle;
}

fn parseParent(data: []const u8) !struct { parent: ?Parent, size: usize } {
    if (data.len < @sizeOf(ParentHeader)) return error.CorruptMetadata;
    const header = std.mem.bytesToValue(ParentHeader, data[0..@sizeOf(ParentHeader)]);
    if (header.length == 0) return .{ .parent = null, .size = data.len };
    if (header.length <= @sizeOf(ParentHeader) or header.length > data.len or
        header.length % 8 != 0 or header.handle.length != 14) return error.CorruptMetadata;
    const names = data[@sizeOf(ParentHeader)..header.length];
    const end = std.mem.indexOfScalar(u8, names, 0) orelse return error.CorruptMetadata;
    if (!linux.validName(names[0..end])) return error.CorruptMetadata;
    return .{ .parent = .{ .handle = header.handle, .name = names[0..end] }, .size = header.length };
}

const Parents = struct {
    fd: i32,
    args: ParentsByHandle,
    buffer: [4096]u8 align(8) = undefined,
    index: usize = 4096,
    loaded: bool = false,

    fn init(fd: i32, handle: Handle) Parents {
        return .{ .fd = fd, .args = .{ .handle = handle } };
    }

    fn next(self: *Parents) !?Parent {
        while (true) {
            if (self.index == self.buffer.len) {
                if (self.loaded and self.args.request.output_flags & 2 != 0) return null;
                const old_cursor = self.args.request.cursor;
                // The kernel copies no record bytes when an inode has no parents.
                @memset(&self.buffer, 0);
                self.args.request.buffer = @intFromPtr(&self.buffer);
                linux.ioctl(self.fd, getparents, &self.args) catch |err| switch (err) {
                    error.FilesystemChanged => return null,
                    else => return err,
                };
                if (self.args.request.output_flags & ~@as(u16, 3) != 0 or
                    (self.args.request.output_flags & 2 == 0 and
                        std.mem.eql(u32, &old_cursor, &self.args.request.cursor))) return error.CorruptMetadata;
                self.loaded = true;
                self.index = 0;
            }
            const parsed = try parseParent(self.buffer[self.index..]);
            self.index += parsed.size;
            if (parsed.parent) |parent| return parent;
            if (self.args.request.output_flags & 2 == 0) return error.CorruptMetadata;
            return null;
        }
    }
};

pub fn probe(_: std.Io, dir: std.Io.Dir) !void {
    var parents = Parents.init(dir.handle, try rootHandle(dir));
    _ = try parents.next();
    var args: BulkArgs = .{ .header = .{ .count = 1 }, .records = undefined };
    try linux.ioctl(dir.handle, bulkstat, &args);
}

const Identity = struct { inode: u64, generation: u32 };
fn identity(handle: Handle) Identity {
    return .{ .inode = handle.inode, .generation = handle.generation };
}
fn join(gpa: Allocator, parent: []const u8, child: []const u8) ![]const u8 {
    return std.mem.concat(gpa, u8, &.{ parent, if (std.mem.endsWith(u8, parent, "/")) "" else "/", child });
}

const Paths = struct {
    gpa: Allocator,
    fd: i32,
    cache: std.AutoHashMap(Identity, ?[]const u8),

    fn deinit(self: *Paths) void {
        var values = self.cache.valueIterator();
        while (values.next()) |value| if (value.*) |path| self.gpa.free(path);
        self.cache.deinit();
    }

    fn resolve(self: *Paths, handle: Handle) !?[]const u8 {
        const Step = struct { id: Identity, name: []const u8 };
        var steps: std.ArrayList(Step) = .empty;
        defer {
            for (steps.items) |step| self.gpa.free(step.name);
            steps.deinit(self.gpa);
        }
        var current = handle;
        while (!self.cache.contains(identity(current))) {
            const id = identity(current);
            for (steps.items) |step| if (std.meta.eql(step.id, id)) return error.MetadataCycle;
            var parents = Parents.init(self.fd, current);
            const parent = (try parents.next()) orelse {
                try self.cache.put(id, null);
                break;
            };
            if (parent.handle.fsid != handle.fsid) return error.CorruptMetadata;
            const owned_name = try self.gpa.dupe(u8, parent.name);
            steps.append(self.gpa, .{ .id = id, .name = owned_name }) catch |err| {
                self.gpa.free(owned_name);
                return err;
            };
            current = parent.handle;
        }
        var base = self.cache.get(identity(current)).?;
        var i = steps.items.len;
        while (i > 0) {
            i -= 1;
            const path = if (base) |parent| try join(self.gpa, parent, steps.items[i].name) else null;
            self.cache.put(steps.items[i].id, path) catch |err| {
                if (path) |owned| self.gpa.free(owned);
                return err;
            };
            base = path;
        }
        return base;
    }
};

pub fn search(io: std.Io, gpa: Allocator, opts: common.Options, root: []const u8, dir: std.Io.Dir, collector: *common.Collector) !u8 {
    const root_handle = try rootHandle(dir);
    var paths: Paths = .{ .gpa = gpa, .fd = dir.handle, .cache = std.AutoHashMap(Identity, ?[]const u8).init(gpa) };
    defer paths.deinit();
    const owned_root = try gpa.dupe(u8, root);
    paths.cache.put(identity(root_handle), owned_root) catch |err| {
        gpa.free(owned_root);
        return err;
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var found = false;
    var args: BulkArgs = .{ .header = .{}, .records = undefined };
    // shortcut: XFS parent queries run serially, parallelize if profiling shows a bottleneck.
    scan: while (true) {
        const start_inode = args.header.inode;
        try linux.ioctl(dir.handle, bulkstat, &args);
        if (args.header.returned == 0) break;
        if (args.header.returned > args.records.len or args.header.inode <= start_inode) return error.CorruptMetadata;
        for (args.records[0..args.header.returned]) |record| {
            if (record.links == 0 or record.inode == root_handle.inode) continue;
            const handle: Handle = .{ .fsid = root_handle.fsid, .inode = record.inode, .generation = record.generation };
            var parents = Parents.init(dir.handle, handle);
            while (try parents.next()) |parent| {
                if (parent.handle.fsid != root_handle.fsid) return error.CorruptMetadata;
                const parent_path = (try paths.resolve(parent.handle)) orelse continue;
                const path = try join(gpa, parent_path, parent.name);
                defer gpa.free(path);
                if (opts.matches(path)) {
                    found = true;
                    const decision = try collector.consider(path);
                    switch (decision) {
                        .skip => {},
                        .done => break :scan,
                        .emit, .last => {
                            if (!collector.json) {
                                try output.appendSlice(gpa, path);
                                try output.append(gpa, opts.separator);
                                if (output.items.len >= 64 * 1024) {
                                    try std.Io.File.stdout().writeStreamingAll(io, output.items);
                                    output.clearRetainingCapacity();
                                }
                            }
                            if (decision == .last) break :scan;
                        },
                    }
                }
            }
        }
    }
    try std.Io.File.stdout().writeStreamingAll(io, output.items);
    return if (found) 0 else 1;
}

test "XFS ioctl ABI" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 192), @sizeOf(BulkStat));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(BulkHeader));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(HandleRequest));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ParentsByHandle));
    try std.testing.expectEqual(@as(usize, 132), @offsetOf(BulkStat, "mode"));
    try std.testing.expectEqual(@as(u32, 4), (BulkHeader{}).flags);
    if (@import("builtin").cpu.arch == .x86_64) {
        try std.testing.expectEqual(@as(u32, 0x8040587f), bulkstat);
        try std.testing.expectEqual(@as(u32, 0xc040583f), getparents);
    }
}

test "XFS stale handles are skipped" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .linux or
        (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) return error.SkipZigTest;
    const io = std.testing.io;
    var cwd = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer cwd.close(io);
    if (!supports((try linux.statFs(cwd.handle)).kind)) return error.SkipZigTest;
    probe(io, cwd) catch |err| switch (err) {
        error.NativeUnsupported, error.NativePermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "victim", .{});
    defer file.close(io);
    var handle = try rootHandle(.{ .handle = file.handle });
    handle.generation +%= 1;
    var parents = Parents.init(temporary.dir.handle, handle);
    parents.args.request.buffer = @intFromPtr(&parents.buffer);
    try std.testing.expectError(error.FilesystemChanged, linux.ioctl(parents.fd, getparents, &parents.args));
    try std.testing.expect((try parents.next()) == null);
}

test "XFS parent records reject invalid lengths and names" {
    // Gaps: length==0 terminator, length%8!=0, handle.length!=14, missing NUL, empty name, short buffer.
    var data: [40]u8 = @splat(0);
    const header: ParentHeader = .{ .handle = .{ .fsid = 1, .inode = 42, .generation = 1 }, .length = 40, .reserved = 0 };
    @memcpy(data[0..32], std.mem.asBytes(&header));
    @memcpy(data[32..36], "test");
    const parsed = try parseParent(&data);
    try std.testing.expectEqualStrings("test", parsed.parent.?.name);
    try std.testing.expectEqual(@as(usize, 40), parsed.size);
    try std.testing.expectError(error.CorruptMetadata, parseParent(data[0..39]));
    data[33] = '/';
    try std.testing.expectError(error.CorruptMetadata, parseParent(&data));
    // length==0 terminator yields null parent
    var term: [32]u8 = @splat(0);
    @memcpy(term[0..32], std.mem.asBytes(&header));
    var term_header = header;
    term_header.length = 0;
    @memcpy(term[0..32], std.mem.asBytes(&term_header));
    const term_parsed = try parseParent(&term);
    try std.testing.expect(term_parsed.parent == null);
    try std.testing.expectEqual(@as(usize, 32), term_parsed.size);
    // length % 8 != 0
    var bad_len: [40]u8 = @splat(0);
    var bad_header = header;
    bad_header.length = 39;
    @memcpy(bad_len[0..32], std.mem.asBytes(&bad_header));
    @memcpy(bad_len[32..36], "test");
    try std.testing.expectError(error.CorruptMetadata, parseParent(&bad_len));
    // handle.length != 14
    var bad_handle: [40]u8 = @splat(0);
    var bad_h = header;
    bad_h.handle.length = 13;
    bad_h.length = 40;
    @memcpy(bad_handle[0..32], std.mem.asBytes(&bad_h));
    @memcpy(bad_handle[32..36], "test");
    try std.testing.expectError(error.CorruptMetadata, parseParent(&bad_handle));
    // missing NUL terminator (non-zero tail)
    var no_nul: [40]u8 = @splat('x');
    @memcpy(no_nul[0..32], std.mem.asBytes(&header));
    try std.testing.expectError(error.CorruptMetadata, parseParent(&no_nul));
    // invalid name "." rejected by validName
    var dot: [40]u8 = @splat(0);
    @memcpy(dot[0..32], std.mem.asBytes(&header));
    dot[32] = '.';
    try std.testing.expectError(error.CorruptMetadata, parseParent(&dot));
}

test "fuzzable: parseParent rejects corrupt metadata and never panics" {
    try std.testing.fuzz({}, fuzzParseParent, .{ .corpus = &.{
        "\x30\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00test\x00\x00\x00\x00",
        "\x00",
        "",
    } });
}

fn fuzzParseParent(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    if (parseParent(input)) |parsed| {
        try std.testing.expect(parsed.size <= input.len);
        if (parsed.parent) |parent| {
            try std.testing.expect(linux.validName(parent.name));
            try std.testing.expectEqual(@as(usize, 14), parent.handle.length);
        }
    } else |err| {
        try std.testing.expectEqual(error.CorruptMetadata, err);
    }
}
