const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17)
        @compileError("fslocate requires Zig 0.17.x");
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    // Non-debug builds are the shipped artifacts: strip debug symbols (which
    // embed absolute build-host paths) and produce position-independent,
    // stack-protected code. Stack protection requires libc; fslocate is
    // freestanding (direct syscalls, no libc), so enable the protector only
    // when linking libc and rely on strip/PIC/PIE otherwise.
    const hardened = optimize != .debug;
    const want_libc = b.option(bool, "libc", "Link libc (enables stack protector)") orelse false;
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
        .strip = hardened,
        .stack_protector = hardened and want_libc,
        .pic = hardened,
        .link_libc = want_libc,
    });
    const exe = b.addExecutable(.{ .name = "fslocate", .root_module = module });
    // Zig 0.17's ExecutableOptions has no pie field; pie lives on the Compile
    // step itself. Set it directly for hardened (non-debug) builds.
    exe.pie = hardened;
    b.installArtifact(exe);

    const check = b.step("check", "Run static analysis (blocking)");
    check.dependOn(&exe.step);
    const fmt_check = b.addRunFile(std.Build.LazyPath.zig_exe);
    fmt_check.addArgs(&.{ "fmt", "--check", "build.zig", "src" });
    fmt_check.setCwd(b.path("."));
    fmt_check.has_side_effects = true;
    check.dependOn(&fmt_check.step);
    const ruff_check = b.addSystemCommand(&.{ "ruff", "check", "tests/" });
    ruff_check.setCwd(b.path("."));
    ruff_check.has_side_effects = true;
    check.dependOn(&ruff_check.step);
    const ruff_fmt = b.addSystemCommand(&.{ "ruff", "format", "--check", "tests/" });
    ruff_fmt.setCwd(b.path("."));
    ruff_fmt.has_side_effects = true;
    check.dependOn(&ruff_fmt.step);
    const clang_fmt = b.addSystemCommand(&.{ "clang-format", "--dry-run", "--Werror", "tests/zfs_native_api.c" });
    clang_fmt.setCwd(b.path("."));
    clang_fmt.has_side_effects = true;
    check.dependOn(&clang_fmt.step);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run fslocate").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
