const std = @import("std");

pub fn reportSearchError(gpa: std.mem.Allocator, json: bool, path: []const u8, err: anyerror) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    formatSearchError(&out, gpa, json, path, err) catch {
        if (json)
            std.debug.print("{{\"error\":{{\"kind\":\"failure\",\"message\":\"{s}\",\"hint\":\"see --help\"}}}}\n", .{@errorName(err)})
        else
            std.debug.print("fslocate: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("{s}", .{out.items});
}

fn formatSearchError(out: *std.ArrayList(u8), gpa: std.mem.Allocator, json: bool, path: []const u8, err: anyerror) !void {
    if (!json) {
        try out.appendSlice(gpa, "fslocate: ");
        try appendJsonString(out, gpa, path);
        try out.appendSlice(gpa, ": ");
        try out.appendSlice(gpa, @errorName(err));
        try out.append(gpa, '\n');
        return;
    }
    try out.appendSlice(gpa, "{\"error\":{\"kind\":\"failure\",\"message\":");
    try appendJsonString(out, gpa, @errorName(err));
    try out.append(gpa, ',');
    try appendPathFields(out, gpa, path, .{});
    try out.appendSlice(gpa, ",\"hint\":\"see --help\"}}\n");
}

pub const Options = struct {
    backend: Backend = .auto,
    pattern: []const u8,
    root: []const u8 = ".",
    ignore_case: bool = false,
    separator: u8 = '\n',
    threads: usize,
    /// Stream matches as one JSON document instead of text.
    json: bool = false,
    fields: Fields = .{},
    /// Skip this many matches before emitting. Arrival order, which is unsorted.
    offset: usize = 0,
    /// Cap emitted matches. JSON checks one extra match to establish `truncated`.
    limit: ?usize = null,
    /// KMP prefix table, prepared once before workers start.
    prefix: []const usize = &.{},

    pub fn preparePattern(self: *Options, gpa: std.mem.Allocator) !void {
        if (!self.ignore_case or self.pattern.len <= 4) return;
        const prefix = try gpa.alloc(usize, self.pattern.len);
        prefix[0] = 0;
        var matched: usize = 0;
        for (self.pattern[1..], 1..) |byte, i| {
            while (matched > 0 and std.ascii.toLower(byte) != std.ascii.toLower(self.pattern[matched]))
                matched = prefix[matched - 1];
            if (std.ascii.toLower(byte) == std.ascii.toLower(self.pattern[matched])) matched += 1;
            prefix[i] = matched;
        }
        self.prefix = prefix;
    }

    pub inline fn matches(self: Options, path: []const u8) bool {
        // Short paths favor the simple scan; KMP bounds work on long repetitive paths.
        if (self.prefix.len == 0 or path.len < 256)
            return matchesFree(path, self.pattern, self.ignore_case);
        if (self.pattern.len > path.len) return false;
        var matched: usize = 0;
        for (path) |byte| {
            while (matched > 0 and std.ascii.toLower(byte) != std.ascii.toLower(self.pattern[matched]))
                matched = self.prefix[matched - 1];
            if (std.ascii.toLower(byte) == std.ascii.toLower(self.pattern[matched])) matched += 1;
            if (matched == self.pattern.len) return true;
        }
        return false;
    }
};

pub const Fields = struct { path: bool = true, path_bytes_base64: bool = false };

pub const Decision = enum { skip, emit, last, done };

/// Shared match counter. Walk workers and the XFS scan call `consider` under its mutex.
pub const Collector = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    offset: usize,
    limit: ?usize,
    json: bool,
    pretty: bool,
    fields: Fields = .{},
    mutex: std.Io.Mutex = .init,
    seen: usize = 0,
    kept: usize = 0,
    truncated: bool = false,
    output: std.ArrayList(u8) = .empty,
    started: bool = false,
    output_error: ?anyerror = null,

    pub fn deinit(self: *Collector) void {
        self.output.deinit(self.gpa);
    }

    pub fn consider(self: *Collector, path: []const u8) !Decision {
        if (!self.json and self.offset == 0 and self.limit == null) return .emit;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.output_error != null) return .done;
        return self.considerLocked(path) catch |err| {
            self.output_error = err;
            return err;
        };
    }

    fn considerLocked(self: *Collector, path: []const u8) !Decision {
        const index = self.seen;
        self.seen += 1;
        if (index < self.offset) return .skip;
        if (self.limit) |limit| {
            if (self.kept >= limit) {
                self.truncated = true;
                return .done;
            }
        }
        if (self.json) {
            try self.begin();
            const start = self.output.items.len;
            errdefer self.output.shrinkRetainingCapacity(start);
            if (self.kept != 0) try self.output.append(self.gpa, ',');
            if (self.pretty) try self.output.appendSlice(self.gpa, "\n  ");
            try self.output.append(self.gpa, '{');
            try appendPathFields(&self.output, self.gpa, path, self.fields);
            try self.output.append(self.gpa, '}');
        }
        self.kept += 1;
        if (self.output.items.len >= 64 * 1024) try self.flush();
        if (!self.json) if (self.limit) |limit| {
            if (self.kept == limit) return .last;
        };
        return .emit;
    }

    fn begin(self: *Collector) !void {
        if (self.started) return;
        try self.output.appendSlice(self.gpa, "{\"items\":[");
        self.started = true;
    }

    fn flush(self: *Collector) !void {
        std.Io.File.stdout().writeStreamingAll(self.io, self.output.items) catch |err| {
            self.output_error = err;
            return err;
        };
        self.output.clearRetainingCapacity();
    }

    pub fn finish(self: *Collector, incomplete: bool) !void {
        if (!self.json) return;
        if (self.output_error) |err| return err;
        try self.begin();
        if (self.pretty and self.kept > 0) try self.output.append(self.gpa, '\n');
        try self.output.append(self.gpa, ']');
        if (incomplete) {
            try self.output.appendSlice(self.gpa, ",\"incomplete\":true");
        } else if (self.truncated) {
            try self.output.appendSlice(self.gpa, ",\"truncated\":true");
        } else {
            try self.output.appendSlice(self.gpa, ",\"total\":");
            try appendUsize(&self.output, self.gpa, self.seen);
        }
        try self.output.appendSlice(self.gpa, "}\n");
        try self.flush();
    }
};

fn appendUsize(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
    try out.appendSlice(gpa, text);
}

fn appendPathFields(out: *std.ArrayList(u8), gpa: std.mem.Allocator, path: []const u8, fields: Fields) !void {
    if (fields.path) {
        try out.appendSlice(gpa, "\"path\":");
        try appendJsonString(out, gpa, path);
    }
    if (fields.path_bytes_base64 or !std.unicode.utf8ValidateSlice(path)) {
        if (fields.path) try out.append(gpa, ',');
        try out.appendSlice(gpa, "\"path_bytes_base64\":\"");
        const start = out.items.len;
        try out.resize(gpa, start + std.base64.standard.Encoder.calcSize(path.len));
        _ = std.base64.standard.Encoder.encode(out.items[start..], path);
        try out.append(gpa, '"');
    }
}

fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == '"' or b == '\\') {
            try out.append(gpa, '\\');
            try out.append(gpa, b);
            i += 1;
            continue;
        }
        if (b < 0x20 or b >= 0x7f) {
            const width = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (b >= 0x80 and i + width <= bytes.len) {
                const seq = bytes[i..][0..width];
                if (std.unicode.utf8ValidateSlice(seq)) {
                    try out.appendSlice(gpa, seq);
                    i += width;
                    continue;
                }
            }
            var hex: [6]u8 = undefined;
            const esc = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{b}) catch return error.OutOfMemory;
            try out.appendSlice(gpa, esc);
            i += 1;
            continue;
        }
        try out.append(gpa, b);
        i += 1;
    }
    try out.append(gpa, '"');
}

pub const Backend = enum { auto, native, walk };

pub fn matchesFree(path: []const u8, pattern: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, path, pattern) != null;
    return std.ascii.findIgnoreCase(path, pattern) != null;
}

fn collectWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var collector: Collector = .{ .io = std.testing.io, .gpa = gpa, .offset = 0, .limit = null, .json = true, .pretty = false };
    defer collector.deinit();
    _ = try collector.consider("/path-\xff");
}

test "JSON collector paging and truncation" {
    // offset/limit/truncated/total are critical paging contract; exercise every Decision.
    var collector: Collector = .{ .io = std.testing.io, .gpa = std.testing.allocator, .offset = 2, .limit = 2, .json = true, .pretty = false };
    defer collector.deinit();
    // seen: 0,1 skipped by offset; 2,3 emitted (kept==limit -> last handled next); 4 triggers done+truncated.
    try std.testing.expectEqual(.skip, try collector.consider("/a"));
    try std.testing.expectEqual(.skip, try collector.consider("/b"));
    try std.testing.expectEqual(.emit, try collector.consider("/c"));
    try std.testing.expectEqual(.emit, try collector.consider("/d"));
    try std.testing.expectEqual(.done, try collector.consider("/e"));
    try std.testing.expect(collector.truncated);
    try std.testing.expectEqual(@as(usize, 5), collector.seen);
    try std.testing.expectEqual(@as(usize, 2), collector.kept);
    try collector.finish(false);
    // JSON document must contain exactly emitted items and truncated flag, no total.
    const out = collector.output.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"total\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/c") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/d") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/e") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/a") == null);
}

test "JSON collector frees allocations when encoding fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, collectWithAllocationFailures, .{});
}

test "prepared case-insensitive patterns handle overlaps and raw bytes" {
    // preparePattern only builds KMP table for pattern.len > 4; verify both branches agree.
    const long: [512]u8 = @splat('a');
    const long_hit = long ++ "B/\xffAbCd/MiXeD/AAABAAAB";
    for ([_][]const u8{ "aAaAaB", "aaaab", "AAABAAAB", "mixed", "\xffAbCd", "", "ab" }) |pattern| {
        var opts: Options = .{ .pattern = pattern, .ignore_case = true, .threads = 1 };
        try opts.preparePattern(std.testing.allocator);
        defer std.testing.allocator.free(opts.prefix);
        // Short patterns (<=4) must skip allocation; long patterns must not.
        try std.testing.expectEqual(pattern.len <= 4, opts.prefix.len == 0);
        for ([_][]const u8{ "", "a", "aaaaaaaaab", "aaabaaabaaab", "/MiXeD/path", "\xffaBcD", "other", &long, long_hit }) |path| {
            try std.testing.expectEqual(std.ascii.findIgnoreCase(path, pattern) != null, opts.matches(path));
        }
    }
    // Options.matches must exercise KMP branch for long paths (>=256): verify long_hit hit/miss.
    var kmp: Options = .{ .pattern = "AAABAAAB", .ignore_case = true, .threads = 1 };
    try kmp.preparePattern(std.testing.allocator);
    defer std.testing.allocator.free(kmp.prefix);
    try std.testing.expect(kmp.matches(long_hit));
    const long_miss = long ++ "B/\xffAbCd/MiXeD/AAABAAAA"; // truncated final char
    try std.testing.expect(!kmp.matches(long_miss));
}
