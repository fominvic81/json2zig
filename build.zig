const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const lib = b.addLibrary(.{ .name = "json2zig", .root_module = lib_mod });
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addImport("json2zig", lib_mod);
    const exe = b.addExecutable(.{ .name = "json2zig", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const lib_unit_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);

    const wasm_target = b.resolveTargetQuery(.{ .os_tag = .freestanding, .cpu_arch = .wasm32 });
    const wasm_mod = b.createModule(.{ .root_source_file = b.path("dist/main.zig"), .target = wasm_target, .optimize = optimize });
    wasm_mod.addImport("json2zig", lib_mod);
    const wasm = b.addExecutable(.{ .name = "json2zig", .root_module = wasm_mod });
    wasm.rdynamic = true;
    wasm.entry = .disabled;

    const wasm_step = b.step("wasm", "Build wasm library");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
}
