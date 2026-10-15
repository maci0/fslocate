const std = @import("std");

pub const Options = struct {
    backend: Backend = .auto,
    pattern: []const u8,
    root: []const u8 = ".",
    ignore_case: bool = false,
    separator: u8 = '\n',
    threads: usize,
    /// When set, matches are kept for one JSON document instead of streamed as text.
    json: bool = false,
    /// Skip this many matches before emitting. Arrival order, which is unsorted.
    offset: usize = 0,
    /// Cap emitted matches. Null means no cap. One match past the cap sets `truncated`.
    limit: ?usize = null,
};

pub const Decision = enum { skip, emit, done };

/// Shared match counter. Walk workers and the XFS scan call `consider` under its mutex.
pub const Collector = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    offset: usize,
    limit: ?usize,
    json: bool,
    pretty: bool,
    mutex: std.Io.Mutex = .init,
    seen: usize = 0,
    kept: usize = 0,
    truncated: bool = false,
    paths: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Collector) void {
        for (self.paths.items) |path| self.gpa.free(path);
        self.paths.deinit(self.gpa);
    }

    pub fn consider(self: *Collector, path: []const u8) !Decision {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.seen;
        self.seen += 1;
        if (index < self.offset) return .skip;
        if (self.limit) |limit| {
            if (self.kept >= limit) {
                self.truncated = true;
                return .done;
            }
        }
        self.kept += 1;
        if (self.json) {
            try self.paths.append(self.gpa, try self.gpa.dupe(u8, path));
        }
        return .emit;
    }

    pub fn finish(self: *Collector) !void {
        if (!self.json) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "{\"items\":[");
        if (self.pretty and self.paths.items.len > 0) try out.append(self.gpa, '\n');
        for (self.paths.items, 0..) |path, i| {
            if (self.pretty) try out.appendSlice(self.gpa, "  ");
            try out.appendSlice(self.gpa, "{\"path\":");
            try appendJsonString(&out, self.gpa, path);
            try out.append(self.gpa, '}');
            if (i + 1 != self.paths.items.len) try out.append(self.gpa, ',');
            if (self.pretty) try out.append(self.gpa, '\n');
        }
        try out.append(self.gpa, ']');
        if (self.truncated) {
            try out.appendSlice(self.gpa, ",\"truncated\":true");
        } else {
            try out.appendSlice(self.gpa, ",\"total\":");
            try appendUsize(&out, self.gpa, self.seen);
        }
        try out.appendSlice(self.gpa, "}\n");
        try std.Io.File.stdout().writeStreamingAll(self.io, out.items);
    }
};

fn appendUsize(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
    try out.appendSlice(gpa, text);
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
        if (b < 0x20 or b >= 0x80) {
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

pub fn matches(path: []const u8, pattern: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, path, pattern) != null;
    if (pattern.len > path.len) return false;
    for (0..path.len - pattern.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(path[i..][0..pattern.len], pattern)) return true;
    }
    return false;
}
