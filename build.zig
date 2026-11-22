const std = @import("std");

pub fn build(b: *std.Build) void {
    
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});


    const exe = b.addExecutable(.{
        .name = "image_decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.addRunArtifact(exe);
    
    const step = b.step("run", "run the app");

    step.dependOn(&run_step.step);

    run_step.step.dependOn(b.getInstallStep());
}
