const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const common = @import("common.zig");
const Options = common.Options;
const matches = common.matches;

fn Search(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const has_state = @hasDecl(Reader, "State");
        io: Io,
        gpa: Allocator,
        opts: Options,
        reader_state: if (has_state) Reader.State else void,
        directories: std.ArrayList([]const u8) = .empty,
        active: usize = 0,
        mutex: Io.Mutex = .init,
        ready: Io.Condition = .init,
        output_mutex: Io.Mutex = .init,
        collector: *common.Collector,
        found: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),
        stopped: std.atomic.Value(bool) = .init(false),

        fn report(self: *Self, path: []const u8, err: anyerror) void {
            self.failed.store(true, .monotonic);
            std.debug.print("fslocate: {s}: {s}\n", .{ path, @errorName(err) });
            if (self.opts.json) {
                std.debug.print("{{\"error\":{{\"kind\":\"failure\",\"message\":\"search failed\",\"hint\":\"see --help\"}}}}\n", .{});
            }
        }

        fn stop(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.stopped.store(true, .monotonic);
            self.ready.broadcast(self.io);
        }

        fn write(self: *Self, output: *std.ArrayList(u8)) void {
            if (output.items.len == 0) return;
            defer output.clearRetainingCapacity();
            self.output_mutex.lockUncancelable(self.io);
            defer self.output_mutex.unlock(self.io);
            if (self.stopped.load(.monotonic)) return;
            Io.File.stdout().writeStreamingAll(self.io, output.items) catch |err| {
                if (err != error.BrokenPipe) self.report("stdout", err);
                self.stop();
            };
        }

        fn scan(self: *Self, directory: []const u8, path: *std.ArrayList(u8), output: *std.ArrayList(u8)) !std.ArrayList([]const u8) {
            var children: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (children.items) |child| self.gpa.free(child);
                children.deinit(self.gpa);
            }
            var dir = Io.Dir.openDirAbsolute(self.io, directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                self.report(directory, err);
                return children;
            };
            defer dir.close(self.io);
            var reader = if (comptime has_state)
                try Reader.init(self.io, dir, self.opts.backend, &self.reader_state)
            else
                try Reader.init(self.io, dir, self.opts.backend);
            path.clearRetainingCapacity();
            try path.appendSlice(self.gpa, directory);
            if (directory[directory.len - 1] != '/') try path.append(self.gpa, '/');
            const prefix_len = path.items.len;
            while (!self.stopped.load(.monotonic)) {
                const entry = (reader.next(self.io) catch |err| {
                    self.report(directory, err);
                    break;
                }) orelse break;
                path.shrinkRetainingCapacity(prefix_len);
                try path.appendSlice(self.gpa, entry.name);
                if (matches(path.items, self.opts.pattern, self.opts.ignore_case)) {
                    self.found.store(true, .monotonic);
                    const decision = self.collector.consider(path.items) catch |err| {
                        self.report("stdout", err);
                        self.stop();
                        break;
                    };
                    switch (decision) {
                        .skip => {},
                        .done => self.stop(),
                        .emit => if (!self.collector.json) {
                            try output.appendSlice(self.gpa, path.items);
                            try output.append(self.gpa, self.opts.separator);
                            if (output.items.len >= 64 * 1024) self.write(output);
                        },
                    }
                }
                const kind = if (entry.kind == .unknown) blk: {
                    const stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                        self.report(path.items, err);
                        continue;
                    };
                    break :blk stat.kind;
                } else entry.kind;
                if (kind == .directory) {
                    const child = try self.gpa.dupe(u8, path.items);
                    errdefer self.gpa.free(child);
                    try children.append(self.gpa, child);
                }
            }
            self.write(output);
            return children;
        }

        fn worker(self: *Self) void {
            var path: std.ArrayList(u8) = .empty;
            defer path.deinit(self.gpa);
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.gpa);
            while (true) {
                self.mutex.lockUncancelable(self.io);
                while (self.directories.items.len == 0 and self.active != 0 and !self.stopped.load(.monotonic)) {
                    self.ready.waitUncancelable(self.io, &self.mutex);
                }
                if (self.stopped.load(.monotonic) or self.directories.items.len == 0) {
                    self.mutex.unlock(self.io);
                    return;
                }
                const directory = self.directories.pop().?;
                self.active += 1;
                self.mutex.unlock(self.io);
                defer self.gpa.free(directory);

                var children = self.scan(directory, &path, &output) catch |err| blk: {
                    self.report(directory, err);
                    self.stop();
                    break :blk std.ArrayList([]const u8).empty;
                };
                defer children.deinit(self.gpa);
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.directories.appendSlice(self.gpa, children.items) catch |err| {
                    for (children.items) |child| self.gpa.free(child);
                    self.report(directory, err);
                    self.stopped.store(true, .monotonic);
                };
                self.active -= 1;
                self.ready.broadcast(self.io);
            }
        }
    };
}

pub fn run(comptime Reader: type, io: Io, gpa: Allocator, opts: Options, root: []const u8, collector: *common.Collector) !u8 {
    var search: Search(Reader) = .{
        .io = io,
        .gpa = gpa,
        .opts = opts,
        .collector = collector,
        .reader_state = if (@hasDecl(Reader, "State")) Reader.State.init(gpa) else {},
    };
    defer if (@hasDecl(Reader, "State")) search.reader_state.deinit();
    defer {
        for (search.directories.items) |directory| gpa.free(directory);
        search.directories.deinit(gpa);
    }
    const first = try gpa.dupe(u8, root);
    search.directories.append(gpa, first) catch |err| {
        gpa.free(first);
        return err;
    };
    var threads: [255]std.Thread = undefined;
    var started: usize = 0;
    while (started + 1 < opts.threads) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, Search(Reader).worker, .{&search}) catch |err| {
            search.report("worker", err);
            break;
        };
    }
    search.worker();
    for (threads[0..started]) |thread| thread.join();
    return if (search.failed.load(.monotonic)) 2 else if (search.found.load(.monotonic)) 0 else 1;
}
