const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const proto_only = b.option(
        bool,
        "proto-only",
        "Only provide the protocol module.  Saves on dependencies.",
    ) orelse false;

    const proto_mod = b.addModule("mzterwm-proto", .{
        .root_source_file = b.path("src/proto.zig"),
        .target = target,
    });

    if (proto_only) return;

    const ziggy_dep = b.lazyDependency("ziggy", .{ .target = target, .optimize = optimize }) orelse return;

    const mzterwm_mod = b.addModule("mzterwm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "ziggy", .module = ziggy_dep.module("ziggy") },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mzterwm-proto", .module = proto_mod },
            .{ .name = "mzterwm", .module = mzterwm_mod },
        },
    });

    { // Wayland
        var scanner = Scanner.create(b, .{});
        for ([_][]const u8{
            "river-input-management-v1.xml",
            "river-layer-shell-v1.xml",
            "river-libinput-config-v1.xml",
            "river-window-management-v1.xml",
            "river-xkb-bindings-v1.xml",
            "river-xkb-config-v1.xml",
        }) |proto_xml| {
            const path = b.pathJoin(&.{ "vendor-protocols", proto_xml });
            scanner.addCustomProtocol(b.path(path));
        }

        // Wayland core protocols
        scanner.generate("wl_output", 2);

        // River protocols
        scanner.generate("river_input_manager_v1", 1);
        scanner.generate("river_layer_shell_v1", 1);
        scanner.generate("river_libinput_config_v1", 1);
        scanner.generate("river_window_manager_v1", 4);
        scanner.generate("river_xkb_bindings_v1", 2);
        scanner.generate("river_xkb_config_v1", 1);

        const wayland_mod = b.createModule(.{
            .root_source_file = scanner.result,
            .target = target,
            .link_libc = true,
        });
        wayland_mod.linkSystemLibrary("wayland-client", .{});

        mzterwm_mod.addImport("wayland", wayland_mod);
        exe_mod.addImport("wayland", wayland_mod);
    }

    const exe = b.addExecutable(.{
        .name = "mzterwm",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // tests
    const test_step = b.step("test", "Run tests");

    for ([_]*std.Build.Module{ proto_mod, mzterwm_mod, exe_mod }) |mod| {
        const tests = b.addTest(.{ .root_module = mod });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
