const std = @import("std");
const builtin = @import("builtin");
const reflect = @import("zevy_reflect");
const buildtools = @import("zevy_buildtools");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const reflect_dep = b.dependency("zevy_reflect", .{
        .target = target,
        .optimize = optimize,
    });
    const reflect_mod = reflect_dep.module("zevy_reflect");

    const mod = b.addModule("zevy_mem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zevy_reflect", .module = reflect_mod },
        },
        .link_libc = builtin.os.tag == .windows,
    });

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    try buildtools.fmt.addFmtStep(b, false);

    try buildtools.fetch.addFetchStep(b, b.path("build.zig.zon"));
}
