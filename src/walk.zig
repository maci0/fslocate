const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const common = @import("common.zig");
const linux = @import("linux.zig");
const Options = common.Options;

fn Search(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const has_state = @hasDecl(Reader, "State");
        io: Io,
        gpa: Allocator,
        opts: Options,
        root: []const u8,
        root_dir: Io.Dir,
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
        output_failed: bool = false,

        fn report(self: *Self, path: []const u8, err: anyerror) void {
            self.failed.store(true, .monotonic);
            common.reportSearchError(self.gpa, self.opts.json, path, err);
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
            if (self.output_failed) return;
            Io.File.stdout().writeStreamingAll(self.io, output.items) catch |err| {
                self.output_failed = true;
                if (err != error.BrokenPipe) self.report("stdout", err);
                self.stop();
            };
        }

        fn openDirectory(self: *Self, directory: []const u8) !Io.Dir {
            if (directory.len == self.root.len)
                return self.root_dir.openDir(self.io, ".", .{ .iterate = true });
            const start = self.root.len + @intFromBool(self.root[self.root.len - 1] != '/');
            if (std.mem.indexOfScalar(u8, directory[start..], '/') == null)
                return self.root_dir.openDir(self.io, directory[start..], .{ .iterate = true, .follow_symlinks = false });
            if (comptime builtin.os.tag == .linux) {
                if (linux.openDirNoSymlinks(self.root_dir.handle, directory[start..])) |dir|
                    return dir;
            }
            var components = std.mem.splitScalar(u8, directory[start..], '/');
            var dir = self.root_dir;
            var owned = false;
            errdefer if (owned) dir.close(self.io);
            // Open each component from its parent: no intermediate symlinks or PATH_MAX limit.
            while (components.next()) |component| {
                const next = try dir.openDir(self.io, component, .{ .iterate = true, .follow_symlinks = false });
                if (owned) dir.close(self.io);
                dir = next;
                owned = true;
            }
            return dir;
        }

        fn scan(self: *Self, directory: []const u8, path: *std.ArrayList(u8), output: *std.ArrayList(u8)) !std.ArrayList([]const u8) {
            errdefer self.write(output);
            var children: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (children.items) |child| self.gpa.free(child);
                children.deinit(self.gpa);
            }
            var dir = self.openDirectory(directory) catch |err| {
                self.report(directory, err);
                return children;
            };
            defer dir.close(self.io);
            var reader = (if (comptime has_state)
                Reader.init(self.io, dir, self.opts.backend, &self.reader_state)
            else
                Reader.init(self.io, dir, self.opts.backend)) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.report(directory, err);
                return children;
            };
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
                if (self.opts.matches(path.items)) {
                    self.found.store(true, .monotonic);
                    const decision = self.collector.consider(path.items) catch |err| {
                        if (err != error.BrokenPipe) {
                            // JSON mode: main reports stdout once via collector.output_error; avoid duplicate.
                            // Text mode: no later reporter exists, so report here.
                            if (self.collector.json) self.failed.store(true, .monotonic) else self.report("stdout", err);
                        }
                        self.stop();
                        break;
                    };
                    switch (decision) {
                        .skip => {},
                        .done => {
                            self.stop();
                            break;
                        },
                        .emit, .last => {
                            if (!self.collector.json) {
                                try output.ensureUnusedCapacity(self.gpa, path.items.len + 1);
                                output.appendSliceAssumeCapacity(path.items);
                                output.appendAssumeCapacity(self.opts.separator);
                                if (output.items.len >= 64 * 1024) self.write(output);
                            }
                            if (decision == .last) {
                                self.stop();
                                break;
                            }
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
                if (self.stopped.load(.monotonic)) {
                    for (children.items) |child| self.gpa.free(child);
                } else self.directories.appendSlice(self.gpa, children.items) catch |err| {
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

pub fn run(comptime Reader: type, io: Io, gpa: Allocator, opts: Options, root: []const u8, root_dir: Io.Dir, collector: *common.Collector) !u8 {
    var search: Search(Reader) = .{
        .io = io,
        .gpa = gpa,
        .opts = opts,
        .root = root,
        .root_dir = root_dir,
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
    spawn: while (started + 1 < opts.threads) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, Search(Reader).worker, .{&search}) catch {
            search.report(root, error.ThreadSpawnFailed);
            if (started == 0) return error.ThreadSpawnFailed;
            break :spawn;
        };
    }
    search.worker();
    for (threads[0..started]) |thread| thread.join();
    return if (search.failed.load(.monotonic)) 2 else if (search.found.load(.monotonic)) 0 else 1;
}
