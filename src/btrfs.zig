const std = @import("std");
const common = @import("common.zig");
const linux = @import("linux.zig");
const directory = @import("directory.zig");
const walk = @import("walk.zig");

pub const name = "btrfs";
pub const native = true;
pub fn supports(magic: usize) bool {
    return magic == 0x9123683e;
}

const Key = extern struct {
    tree_id: u64 = 0,
    min_objectid: u64,
    max_objectid: u64,
    min_offset: u64 = 0,
    max_offset: u64 = std.math.maxInt(u64),
    min_transid: u64 = 0,
    max_transid: u64 = std.math.maxInt(u64),
    min_type: u32 = 96,
    max_type: u32 = 96,
    nr_items: u32 = 2048,
    unused: u32 = 0,
    reserved: [4]u64 = @splat(0),
};
const Request = extern struct { key: Key, buffer_size: u64 };
const SearchArgs = extern struct { key: Key, buffer_size: u64, buffer: [64 * 1024]u8 };
const Header = extern struct { transid: u64, objectid: u64, offset: u64, kind: u32, length: u32 };
const tree_search = linux.ioc.IOWR(0x94, 17, Request);

const ParsedEntry = struct { entry: std.Io.Dir.Entry, size: usize };

fn parseEntry(data: []const u8) !ParsedEntry {
    if (data.len < 30) return error.CorruptMetadata;
    const data_len = std.mem.readInt(u16, data[25..27], .little);
    const name_len = std.mem.readInt(u16, data[27..29], .little);
    const size = @as(usize, 30) + data_len + name_len;
    if (size > data.len) return error.CorruptMetadata;
    const filename = data[30..][0..name_len];
    if (!linux.validName(filename)) return error.CorruptMetadata;
    const kind: std.Io.File.Kind = switch (data[29] & 0x7f) {
        1 => .file,
        2 => .directory,
        3 => .character_device,
        4 => .block_device,
        5 => .named_pipe,
        6 => .unix_domain_socket,
        7 => .sym_link,
        0 => .unknown,
        else => return error.CorruptMetadata,
    };
    return .{ .size = size, .entry = .{
        .name = filename,
        .kind = kind,
        .inode = std.mem.readInt(u64, data[0..8], .little),
    } };
}

const TreeReader = struct {
    dir: std.Io.Dir,
    args: SearchArgs,
    index: usize = 0,
    items: u32 = 0,
    payload_end: usize = 0,
    finished: bool = false,

    fn init(io: std.Io, dir: std.Io.Dir) !TreeReader {
        var flags: usize = 0;
        try linux.ioctl(dir.handle, linux.ioc.IOR('f', 1, usize), &flags);
        // Encrypted names need the VFS's key-aware decoding rather than raw tree records.
        if (flags & 0x800 != 0) return error.NativeUnsupported;
        const stat = try dir.stat(io);
        return .{ .dir = dir, .args = .{
            .key = .{ .min_objectid = stat.inode, .max_objectid = stat.inode },
            .buffer_size = 64 * 1024,
            .buffer = undefined,
        } };
    }

    fn fetch(self: *TreeReader) !void {
        self.args.key.nr_items = 2048;
        self.args.buffer_size = self.args.buffer.len;
        try linux.ioctl(self.dir.handle, tree_search, &self.args);
        self.items = self.args.key.nr_items;
        if (self.items > self.args.buffer.len / @sizeOf(Header)) return error.CorruptMetadata;
        self.index = 0;
        self.payload_end = 0;
        if (self.items == 0) self.finished = true;
    }

    fn next(self: *TreeReader) !?std.Io.Dir.Entry {
        while (true) {
            if (self.index < self.payload_end) {
                const parsed = try parseEntry(self.args.buffer[self.index..self.payload_end]);
                self.index += parsed.size;
                return parsed.entry;
            }
            if (self.items == 0) {
                if (self.finished) return null;
                try self.fetch();
                if (self.finished) return null;
            }
            if (self.args.buffer.len - self.index < @sizeOf(Header)) return error.CorruptMetadata;
            const header = std.mem.bytesToValue(Header, self.args.buffer[self.index..][0..@sizeOf(Header)]);
            if (header.objectid != self.args.key.min_objectid or header.kind != 96 or
                header.offset < self.args.key.min_offset) return error.CorruptMetadata;
            self.index += @sizeOf(Header);
            if (header.length > self.args.buffer.len - self.index or header.length == 0)
                return error.CorruptMetadata;
            self.payload_end = self.index + header.length;
            self.items -= 1;
            if (header.offset == std.math.maxInt(u64)) self.finished = true else self.args.key.min_offset = header.offset + 1;
        }
    }
};

pub const Reader = union(enum) {
    tree: TreeReader,
    directory: directory.Reader,

    pub const State = struct {
        mutex: std.Io.Mutex = .init,
        synced: std.AutoHashMap([2]i32, void),

        pub fn init(gpa: std.mem.Allocator) State {
            return .{ .synced = std.AutoHashMap([2]i32, void).init(gpa) };
        }
        pub fn deinit(self: *State) void {
            self.synced.deinit();
        }

        fn prepare(self: *State, io: std.Io, dir: std.Io.Dir, fsid: [2]i32) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.synced.contains(fsid)) return;
            // Tree search omits delayed directory updates until they are flushed.
            try linux.syncFs(dir.handle);
            try self.synced.put(fsid, {});
        }
    };

    fn initTree(io: std.Io, dir: std.Io.Dir, state: *State) !TreeReader {
        const fs = try linux.statFs(dir.handle);
        if (!supports(fs.kind)) return error.NativeUnsupported;
        var reader = try TreeReader.init(io, dir);
        try state.prepare(io, dir, fs.fsid);
        try reader.fetch();
        return reader;
    }

    pub fn init(io: std.Io, dir: std.Io.Dir, mode: common.Backend, state: *State) !Reader {
        const reader = initTree(io, dir, state) catch |err| switch (err) {
            error.NativeUnsupported, error.NativePermissionDenied => {
                if (mode == .native) return err;
                return .{ .directory = try directory.Reader.init(io, dir, mode) };
            },
            else => return err,
        };
        return .{ .tree = reader };
    }

    pub fn next(self: *Reader, io: std.Io) !?std.Io.Dir.Entry {
        return switch (self.*) {
            .tree => |*reader| reader.next(),
            .directory => |*reader| reader.next(io),
        };
    }
};

pub fn probe(io: std.Io, dir: std.Io.Dir) !void {
    var reader = try TreeReader.init(io, dir);
    try reader.fetch();
}

pub fn search(io: std.Io, gpa: std.mem.Allocator, opts: common.Options, root: []const u8, dir: std.Io.Dir, collector: *common.Collector) !u8 {
    return walk.run(Reader, io, gpa, opts, root, dir, collector);
}

test "Btrfs ioctl ABI" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(Key));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(SearchArgs, "buffer"));
    if (@import("builtin").cpu.arch == .x86_64)
        try std.testing.expectEqual(@as(u32, 0xc0709411), tree_search);
}

test "Btrfs directory item bounds and filename validation" {
    var data: [34]u8 = @splat(0);
    data[0] = 42;
    data[27] = 4;
    data[29] = 1;
    @memcpy(data[30..], "test");
    const parsed = try parseEntry(&data);
    try std.testing.expectEqualStrings("test", parsed.entry.name);
    try std.testing.expectEqual(@as(u64, 42), parsed.entry.inode);
    try std.testing.expectEqual(.file, parsed.entry.kind);
    try std.testing.expectError(error.CorruptMetadata, parseEntry(data[0..33]));
    data[31] = '/';
    try std.testing.expectError(error.CorruptMetadata, parseEntry(&data));
    var kind_data = data;
    kind_data[31] = 'e';
    kind_data[29] = 8;
    try std.testing.expectError(error.CorruptMetadata, parseEntry(&kind_data));
    var kind0 = data;
    kind0[31] = 'e';
    kind0[29] = 0;
    try std.testing.expectEqual(.unknown, (try parseEntry(&kind0)).entry.kind);
    var kind_mask = data;
    kind_mask[31] = 'e';
    kind_mask[29] = 0x81;
    try std.testing.expectEqual(.file, (try parseEntry(&kind_mask)).entry.kind);
    var empty_name = data;
    empty_name[31] = 'e';
    empty_name[27] = 0;
    try std.testing.expectError(error.CorruptMetadata, parseEntry(&empty_name));
    var dot = data;
    dot[27] = 1;
    dot[30] = '.';
    try std.testing.expectError(error.CorruptMetadata, parseEntry(&dot));
    var oversize = data;
    oversize[31] = 'e';
    oversize[25] = 100;
    try std.testing.expectError(error.CorruptMetadata, parseEntry(&oversize));
}

test "fuzzable: parseEntry rejects corrupt metadata and never panics" {
    try std.testing.fuzz({}, fuzzParseEntry, .{ .corpus = &.{
        "\x2a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x01test",
        "\x00",
        "",
    } });
}

fn fuzzParseEntry(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    if (parseEntry(input)) |parsed| {
        // Invariants: size within bounds, name valid, inode round-trips.
        try std.testing.expect(parsed.size <= input.len);
        try std.testing.expect(linux.validName(parsed.entry.name));
        try std.testing.expectEqual(parsed.entry.inode, std.mem.readInt(u64, input[0..8], .little));
    } else |err| {
        try std.testing.expectEqual(error.CorruptMetadata, err);
    }
}
