// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module. Consumers do:
    //   const font = @import("fluxion_font");
    //
    // No dependencies. See build.zig.zon.
    const mod = b.addModule("fluxion_font", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-font-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-font",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // -------------------------------------------------------------------
    // Examples
    // -------------------------------------------------------------------

    // Nothing here opens a window, so nothing is lazy and nothing is skipped
    // when cross-compiling: an example that prints a glyph as text runs
    // wherever the tests do.
    const examples = [_]struct {
        name: []const u8,
        step: []const u8,
        about: []const u8,
    }{
        .{
            .name = "inspect",
            .step = "example",
            .about = "Open a font, say what is in it, and draw a line of text as characters",
        },
    };

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_font", .module = mod }},
        });

        const exe = b.addExecutable(.{
            .name = b.fmt("fluxion-font-{s}", .{example.name}),
            .root_module = example_mod,
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.about).dependOn(&run.step);

        // The examples carry their own tests, and they run with the
        // library's: these are the ones that open a font somebody else made
        // and check the pixels come out where a letter's pixels should be.
        const example_tests = b.addTest(.{
            .name = b.fmt("fluxion-font-{s}-tests", .{example.name}),
            .root_module = example_mod,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
}
