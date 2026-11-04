const std = @import("std");
const Io = std.Io;

const common = @import("common.zig");
const Options = common.Options;
const matches = common.matchesFree;
const backends = @import("backends.zig");


pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| blk: {
        if (err == error.BrokenPipe) break :blk 0;
        if (err != error.InvalidArguments) {
            _ = report(init.io, false, "failure", "search failed", "see --help") catch {};
        }
        break :blk @as(u8, 2);
    };
    if (code != 0) std.process.exit(code);
}

const version = "0.3.0";

const help =
    \\fslocate: search live filesystem metadata; no database
    \\
    \\Usage: fslocate [OPTIONS] PATTERN [ROOT]
    \\       fslocate schema [search]
    \\
    \\Find entries whose full absolute path contains the literal PATTERN.
    \\ROOT defaults to the current directory. Hidden entries are included.
    \\Directory symlinks inside ROOT are not followed. Results are unsorted.
    \\
    \\  -i, --ignore-case    Ignore ASCII case (text and JSON)
    \\  -0, --null           Separate text paths with NUL (text only)
    \\  -r, --root ROOT      Search under ROOT (default: current directory)
    \\  -b, --backend MODE   auto (default), native (privileged), or walk
    \\  -j, --threads N      Up to N workers (1-256; default: up to 8 CPUs)
    \\  -o, --output FORMAT  auto (default), text, or json
    \\      --limit N        Emit at most N matches (json adds "truncated": true)
    \\      --offset N       Skip the first N matches (arrival order)
    \\      --fields LIST    Item fields: path, path_bytes_base64 (JSON only)
    \\  schema               Print the clispec 0.3 document and exit
    \\  -h, --help           Show this help
    \\  -V, --version        Show version
    \\  --                   End options (for patterns beginning with '-')
    \\
    \\Command names as shorthand patterns need `--`: fslocate -- schema
    \\`search` may also be written as a command word: fslocate search PATTERN
    \\
    \\Output: text on a terminal and when piped. -o json selects one JSON
    \\document, {"items":[{"path":...}], ...}. -o text stays text when piped.
    \\auto is text in both cases. No color codes are used.
    \\
    \\Exit status: 0 = matches, 1 = no matches (not an error), 2 = error.
    \\
    \\Examples:
    \\  fslocate --root ~/Documents invoice
    \\  fslocate -i -r ~/Projects readme
    \\  fslocate -0 -r . '.zig' | xargs -0 -r ls -l
    \\  fslocate -o json --limit 10 -r . config
    \\  fslocate --root / --backend walk invoice
    \\
;

const schema_command =
    \\{"name":"schema","description":"Print this clispec 0.3 document and exit. A command path keeps commands with that name.","effects":"read_only","cardinality":"single","output_fields":[{"name":"clispec","type":"string"},{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"description","type":"string"},{"name":"output","type":"object"},{"name":"global_args","type":"array","items":{"type":"object"}},{"name":"commands","type":"array","items":{"type":"object"}},{"name":"errors","type":"array","items":{"type":"object"}},{"name":"outcomes","type":"array","items":{"type":"object"}}],"errors":["usage"],"args":[{"name":"COMMAND","type":"string","enum":["schema","search"],"description":"Optional command to describe."}]}
;

const schema_document =
    \\{"clispec":"0.3","name":"fslocate","version":"0.3.0","description":"Search live filesystem metadata with no database.","output":{"tty":"text","piped":"text"},"global_args":[{"name":"--output","short":"-o","type":"string","enum":["auto","text","json"],"default":"auto","description":"Output format. auto and text print one path per line (NUL with -0). json prints one document."}],"commands":[
++ schema_command ++
    \\,{"name":"search","description":"Print absolute paths that contain PATTERN. Invoked as `fslocate [options] PATTERN [ROOT]`. The word search is optional. A retry is safe: the command only reads directory metadata. Results are unsorted, so --offset follows arrival order and is not stable across runs.","effects":"read_only","cardinality":"unbounded","pagination":{"style":"offset","offset_arg":"--offset","limit_arg":"--limit"},"fields_arg":"--fields","args":[{"name":"PATTERN","type":"string","required":true,"description":"Literal substring of the absolute path."},{"name":"ROOT","type":"path","description":"Directory to search. Defaults to the current directory."},{"name":"--ignore-case","short":"-i","type":"boolean","description":"Ignore ASCII case."},{"name":"--null","short":"-0","type":"boolean","description":"Separate text-mode paths with NUL."},{"name":"--root","short":"-r","type":"path","description":"Directory to search, instead of the positional ROOT."},{"name":"--backend","short":"-b","type":"string","enum":["auto","native","walk"],"default":"auto"},{"name":"--threads","short":"-j","type":"integer","description":"Worker threads, 1 to 256."},{"name":"--limit","type":"integer","description":"Maximum matches to emit. JSON sets truncated when more exist."},{"name":"--offset","type":"integer","default":0,"description":"Matches to skip before emitting."},{"name":"--fields","type":"string","description":"Comma-separated item fields: path, path_bytes_base64 (JSON only). Raw-byte identity accompanies non-UTF-8 paths even when only path is selected."}],"output_fields":[{"name":"path","type":"string","description":"Absolute UTF-8 path, or display text when path_bytes_base64 is present."},{"name":"path_bytes_base64","type":"string","description":"Lossless absolute path bytes in standard base64. Present when requested or when path is not valid UTF-8, including with --fields path."}],"outcomes":["no_match"],"errors":["usage","failure"]}],"errors":[{"kind":"usage","exit_code":2,"retryable":false,"description":"Unknown option, missing PATTERN, or a rejected flag value."},{"kind":"failure","exit_code":2,"retryable":true,"description":"The search could not be completed, or native metadata access was denied."}],"outcomes":[{"code":1,"name":"no_match","description":"No path contained PATTERN. Stdout is empty in text mode and an empty items array in JSON. Not an error."}]}
;

const schema_schema =
    \\{"clispec":"0.3","name":"fslocate","version":"0.3.0","description":"Search live filesystem metadata with no database.","output":{"tty":"text","piped":"text"},"global_args":[{"name":"--output","short":"-o","type":"string","enum":["auto","text","json"],"default":"auto","description":"Output format. auto and text print one path per line (NUL with -0). json prints one document."}],"commands":[
++ schema_command ++
    \\],"errors":[{"kind":"usage","exit_code":2,"retryable":false,"description":"Unknown option, missing PATTERN, or a rejected flag value."},{"kind":"failure","exit_code":2,"retryable":true,"description":"The search could not be completed, or native metadata access was denied."}],"outcomes":[{"code":1,"name":"no_match","description":"No path contained PATTERN. Stdout is empty in text mode and an empty items array in JSON. Not an error."}]}
;

const schema_search =
    \\{"clispec":"0.3","name":"fslocate","version":"0.3.0","description":"Search live filesystem metadata with no database.","output":{"tty":"text","piped":"text"},"global_args":[{"name":"--output","short":"-o","type":"string","enum":["auto","text","json"],"default":"auto","description":"Output format. auto and text print one path per line (NUL with -0). json prints one document."}],"commands":[{"name":"search","description":"Print absolute paths that contain PATTERN. Invoked as `fslocate [options] PATTERN [ROOT]`. The word search is optional. A retry is safe: the command only reads directory metadata. Results are unsorted, so --offset follows arrival order and is not stable across runs.","effects":"read_only","cardinality":"unbounded","pagination":{"style":"offset","offset_arg":"--offset","limit_arg":"--limit"},"fields_arg":"--fields","args":[{"name":"PATTERN","type":"string","required":true,"description":"Literal substring of the absolute path."},{"name":"ROOT","type":"path","description":"Directory to search. Defaults to the current directory."},{"name":"--ignore-case","short":"-i","type":"boolean","description":"Ignore ASCII case."},{"name":"--null","short":"-0","type":"boolean","description":"Separate text-mode paths with NUL."},{"name":"--root","short":"-r","type":"path","description":"Directory to search, instead of the positional ROOT."},{"name":"--backend","short":"-b","type":"string","enum":["auto","native","walk"],"default":"auto"},{"name":"--threads","short":"-j","type":"integer","description":"Worker threads, 1 to 256."},{"name":"--limit","type":"integer","description":"Maximum matches to emit. JSON sets truncated when more exist."},{"name":"--offset","type":"integer","default":0,"description":"Matches to skip before emitting."},{"name":"--fields","type":"string","description":"Comma-separated item fields: path, path_bytes_base64 (JSON only). Raw-byte identity accompanies non-UTF-8 paths even when only path is selected."}],"output_fields":[{"name":"path","type":"string","description":"Absolute UTF-8 path, or display text when path_bytes_base64 is present."},{"name":"path_bytes_base64","type":"string","description":"Lossless absolute path bytes in standard base64. Present when requested or when path is not valid UTF-8, including with --fields path."}],"outcomes":["no_match"],"errors":["usage","failure"]}],"errors":[{"kind":"usage","exit_code":2,"retryable":false,"description":"Unknown option, missing PATTERN, or a rejected flag value."},{"kind":"failure","exit_code":2,"retryable":true,"description":"The search could not be completed, or native metadata access was denied."}],"outcomes":[{"code":1,"name":"no_match","description":"No path contained PATTERN. Stdout is empty in text mode and an empty items array in JSON. Not an error."}]}
;

const Format = enum { auto, text, json };

const Option = struct { name: []const u8, value: ?[]const u8 = null };

fn splitOption(arg: []const u8) Option {
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.indexOfScalar(u8, arg, '=')) |equal|
            return .{ .name = arg[0..equal], .value = arg[equal + 1 ..] };
    }
    return .{ .name = arg };
}

fn takesValue(flag: []const u8) bool {
    inline for (.{ "-r", "--root", "-b", "--backend", "-j", "--threads", "-o", "--output", "--limit", "--offset", "--fields" }) |name| {
        if (std.mem.eql(u8, flag, name)) return true;
    }
    return false;
}

fn takeValue(args: []const []const u8, i: *usize, attached: ?[]const u8) ?[]const u8 {
    if (attached) |value| return value;
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

fn parseFormat(value: []const u8) ?Format {
    return std.meta.stringToEnum(Format, value);
}

fn explicitJson(args: []const []const u8) bool {
    var i: usize = 1;
    var format: Format = .auto;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) break;
        const option = splitOption(args[i]);
        if (std.mem.eql(u8, option.name, "-o") or std.mem.eql(u8, option.name, "--output")) {
            const value = takeValue(args, &i, option.value) orelse break;
            format = parseFormat(value) orelse format;
        } else if (takesValue(option.name) and option.value == null) {
            i += 1;
        }
    }
    return format == .json;
}

fn writeStderr(io: std.Io, bytes: []const u8) void {
    Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

fn report(io: std.Io, json_mode: bool, kind: []const u8, message: []const u8, hint: []const u8) error{InvalidArguments} {
    if (json_mode) {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"error\":{{\"kind\":\"{s}\",\"message\":\"{s}\",\"hint\":\"{s}\"}}}}\n", .{ kind, message, hint }) catch message;
        writeStderr(io, line);
    } else {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "fslocate: {s}\n", .{message}) catch "fslocate: error\n";
        writeStderr(io, line);
    }
    return error.InvalidArguments;
}

fn parseOptions(init: std.process.Init) !?Options {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const json_errors = explicitJson(args);
    var opts: Options = .{ .pattern = "", .threads = @min(std.Thread.getCpuCount() catch 1, 8) };
    var positional: usize = 0;
    var root_option = false;
    var end_options = false;
    var schema = false;
    var search_command = false;
    var search_options = false;
    var schema_arg: ?[]const u8 = null;
    var format: Format = .auto;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const option = splitOption(arg);
        const flag = option.name;
        if (!end_options and option.value != null and !takesValue(flag))
            return report(init.io, json_errors, "usage", "option does not accept a value", "see --help");
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
        } else if (!end_options and (std.mem.eql(u8, flag, "-h") or std.mem.eql(u8, flag, "--help"))) {
            try Io.File.stdout().writeStreamingAll(init.io, help);
            return null;
        } else if (!end_options and (std.mem.eql(u8, flag, "-V") or std.mem.eql(u8, flag, "--version"))) {
            try Io.File.stdout().writeStreamingAll(init.io, "fslocate " ++ version ++ "\n");
            return null;
        } else if (!end_options and (std.mem.eql(u8, flag, "-i") or std.mem.eql(u8, flag, "--ignore-case"))) {
            opts.ignore_case = true;
            search_options = true;
        } else if (!end_options and (std.mem.eql(u8, flag, "-0") or std.mem.eql(u8, flag, "--null"))) {
            opts.separator = 0;
            search_options = true;
        } else if (!end_options and (std.mem.eql(u8, flag, "-r") or std.mem.eql(u8, flag, "--root"))) {
            const value = takeValue(args, &i, option.value) orelse return report(init.io, json_errors, "usage", "--root requires a directory", "see --help");
            if (positional > 1) return report(init.io, json_errors, "usage", "use either --root or positional ROOT", "see --help");
            opts.root = value;
            search_options = true;
            root_option = true;
        } else if (!end_options and (std.mem.eql(u8, flag, "-b") or std.mem.eql(u8, flag, "--backend"))) {
            const value = takeValue(args, &i, option.value) orelse return report(init.io, json_errors, "usage", "--backend requires auto, native, or walk", "see --help");
            search_options = true;
            opts.backend = std.meta.stringToEnum(common.Backend, value) orelse
                return report(init.io, json_errors, "usage", "--backend requires auto, native, or walk", "see --help");
        } else if (!end_options and (std.mem.eql(u8, flag, "-j") or std.mem.eql(u8, flag, "--threads"))) {
            const value = takeValue(args, &i, option.value) orelse return report(init.io, json_errors, "usage", "--threads requires an integer from 1 to 256", "see --help");
            search_options = true;
            opts.threads = std.fmt.parseInt(usize, value, 10) catch
                return report(init.io, json_errors, "usage", "--threads requires an integer from 1 to 256", "see --help");
            if (opts.threads == 0 or opts.threads > 256)
                return report(init.io, json_errors, "usage", "--threads requires an integer from 1 to 256", "see --help");
        } else if (!end_options and (std.mem.eql(u8, flag, "-o") or std.mem.eql(u8, flag, "--output"))) {
            const value = takeValue(args, &i, option.value) orelse
                return report(init.io, json_errors, "usage", "--output requires auto, text, or json", "see --help");
            format = parseFormat(value) orelse return report(init.io, json_errors, "usage", "--output requires auto, text, or json", "see --help");
        } else if (!end_options and std.mem.eql(u8, flag, "--limit")) {
            const value = takeValue(args, &i, option.value) orelse return report(init.io, json_errors, "usage", "--limit requires a non-negative integer", "see --help");
            search_options = true;
            opts.limit = std.fmt.parseInt(usize, value, 10) catch
                return report(init.io, json_errors, "usage", "--limit requires a non-negative integer", "see --help");
        } else if (!end_options and std.mem.eql(u8, flag, "--offset")) {
            const value = takeValue(args, &i, option.value) orelse return report(init.io, json_errors, "usage", "--offset requires a non-negative integer", "see --help");
            search_options = true;
            opts.offset = std.fmt.parseInt(usize, value, 10) catch
                return report(init.io, json_errors, "usage", "--offset requires a non-negative integer", "see --help");
        } else if (!end_options and std.mem.eql(u8, flag, "--fields")) {
            const value = takeValue(args, &i, option.value) orelse
                return report(init.io, json_errors, "usage", "--fields requires a comma-separated list", "use path or path_bytes_base64");
            var it = std.mem.splitScalar(u8, value, ',');
            search_options = true;
            var any = false;
            opts.fields = .{ .path = false };
            while (it.next()) |field| {
                if (field.len == 0) continue;
                any = true;
                if (std.mem.eql(u8, field, "path")) {
                    opts.fields.path = true;
                } else if (std.mem.eql(u8, field, "path_bytes_base64")) {
                    opts.fields.path_bytes_base64 = true;
                } else return report(init.io, json_errors, "usage", "unknown item field", "use path or path_bytes_base64");
            }
            if (!any) return report(init.io, json_errors, "usage", "--fields requires an item field", "use path or path_bytes_base64");
        } else if (!end_options and std.mem.startsWith(u8, flag, "-")) {
            return report(init.io, json_errors, "usage", "unknown option", "see --help");
        } else if (schema) {
            if (schema_arg != null) return report(init.io, json_errors, "usage", "schema accepts one command path", "try: fslocate schema search");
            schema_arg = arg;
        } else if (positional == 0 and !search_command and !end_options and std.mem.eql(u8, arg, "schema")) {
            schema = true;
        } else if (positional == 0 and !search_command and !end_options and std.mem.eql(u8, arg, "search")) {
            search_command = true;
        } else {
            switch (positional) {
                0 => opts.pattern = arg,
                1 => {
                    if (root_option) return report(init.io, json_errors, "usage", "use either --root or positional ROOT", "see --help");
                    opts.root = arg;
                },
                else => return report(init.io, json_errors, "usage", "expected PATTERN and optionally ROOT", "see --help"),
            }
            positional += 1;
        }
    }
    if (schema) {
        if (search_options) return report(init.io, json_errors, "usage", "search options cannot be used with schema", "try: fslocate schema search");
        if (schema_arg) |name| {
            if (std.mem.eql(u8, name, "search")) {
                try Io.File.stdout().writeStreamingAll(init.io, schema_search);
            } else if (std.mem.eql(u8, name, "schema")) {
                try Io.File.stdout().writeStreamingAll(init.io, schema_schema);
            } else return report(init.io, json_errors, "usage", "unknown command", "try: fslocate schema search");
        } else {
            try Io.File.stdout().writeStreamingAll(init.io, schema_document);
        }
        try Io.File.stdout().writeStreamingAll(init.io, "\n");
        return null;
    }
    if (positional == 0) return report(init.io, json_errors, "usage", "expected PATTERN and optionally ROOT", "see --help");
    opts.json = format == .json;
    return opts;
}

fn searchOnce(init: std.process.Init, options: Options) !u8 {
    var opts = options;
    try opts.preparePattern(init.gpa);
    defer init.gpa.free(opts.prefix);
    const pretty = opts.json and (Io.File.stdout().isTty(init.io) catch false);
    var collector = common.Collector{
        .io = init.io,
        .gpa = init.gpa,
        .offset = opts.offset,
        .limit = opts.limit,
        .json = opts.json,
        .pretty = pretty,
        .fields = opts.fields,
    };
    defer collector.deinit();
    const root = try Io.Dir.cwd().realPathFileAlloc(init.io, opts.root, init.gpa);
    defer init.gpa.free(root);
    var dir = try Io.Dir.openDirAbsolute(init.io, root, .{ .iterate = true });
    defer dir.close(init.io);
    // Empty collector output means failure happened before JSON document started;
    // run() reports it with root context.
    const code = backends.search(init.io, init.gpa, opts, root, dir, &collector) catch |err| {
        if (collector.output_error != null) {
            if (err == error.BrokenPipe) return 0;
            common.reportSearchError(init.gpa, opts.json, "stdout", err);
            return 2;
        }
        if (opts.json and collector.started and err != error.BrokenPipe) collector.finish(true) catch |finish_err| {
            common.reportSearchError(init.gpa, true, "stdout", finish_err);
        };
        return err;
    };
    if (opts.json) collector.finish(code == 2) catch |err| {
        if (err == error.BrokenPipe) return 0;
        common.reportSearchError(init.gpa, true, "stdout", err);
        return 2;
    };
    return code;
}

fn run(init: std.process.Init) !u8 {
    const opts = (try parseOptions(init)) orelse return 0;
    return searchOnce(init, opts) catch |err| {
        if (err == error.BrokenPipe) return 0;
        if (err == error.InvalidArguments) return error.InvalidArguments;
        var buf: [160]u8 = undefined;
        const message = if (err == error.NativePermissionDenied)
            "native metadata access requires CAP_SYS_ADMIN"
        else if (err == error.FileNotFound or err == error.AccessDenied or err == error.NotDir)
            "root does not exist or is not accessible"
        else
            std.fmt.bufPrint(&buf, "{s}", .{@errorName(err)}) catch "search failed";
        const hint = if (err == error.NativePermissionDenied)
            "run with sudo or use --backend walk"
        else if (err == error.FileNotFound or err == error.AccessDenied or err == error.NotDir)
            "check the root path and permissions"
        else
            "see --help";
        return report(init.io, opts.json, "failure", message, hint);
    };
}

test "literal byte matching" {
    const expect = std.testing.expect;
    try expect(matches("/a/README.md", "README", false));
    try expect(!matches("/a/README.md", "readme", false));
    try expect(matches("/a/README.md", "readme", true));
    try expect(matches("/a/[x]*.md", "[x]*", false));
    try expect(matches("\xff", "\xff", false));
    try expect(matches("", "", false));
    try expect(matches("", "", true));
    try expect(!matches("a", "longer", false));
    try expect(!matches("a", "longer", true));
    // Gaps: ignore-case with pattern longer than path, empty pattern vs non-empty path, raw-byte non-match.
    try expect(!matches("Ab", "aBcd", true));
    try expect(!matches("Ab", "abcd", true));
    try expect(matches("anything", "", false));
    try expect(matches("anything", "", true));
    try expect(!matches("\xff", "\xfe", false));
    try expect(!matches("\xff", "\xfe", true));
    try expect(matches("AbC", "aBc", true));
    try expect(matches("/a/b", "/a/b", false)); // exact equality
    try expect(!matches("/a/b", "/a/c", false));
    try expect(matches("a", "a", true));
}

test "option parsing helpers" {
    // splitOption / takesValue / parseFormat are public CLI contract; pin behavior.
    const opt = splitOption("--root=/tmp");
    try std.testing.expectEqualStrings("--root", opt.name);
    try std.testing.expectEqualStrings("/tmp", opt.value.?);
    const no_eq = splitOption("--root");
    try std.testing.expect(no_eq.value == null);
    try std.testing.expect(takesValue("--root"));
    try std.testing.expect(takesValue("-j"));
    try std.testing.expect(!takesValue("--help"));
    try std.testing.expect(!takesValue("-i"));
    try std.testing.expectEqual(.json, parseFormat("json").?);
    try std.testing.expectEqual(.text, parseFormat("text").?);
    try std.testing.expectEqual(.auto, parseFormat("auto").?);
    try std.testing.expect(parseFormat("bogus") == null);
    try std.testing.expect(parseFormat("") == null);
    try std.testing.expect(parseFormat("JSON") == null);
}

test {
    _ = @import("btrfs.zig");
    _ = @import("xfs.zig");
    _ = @import("linux.zig");
}
