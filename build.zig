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

    const s2s_dep = b.dependency("s2s", .{ .target = target, .optimize = optimize });

    const proto_mod = b.addModule("mzterwm-proto", .{
        .root_source_file = b.path("src/proto.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "s2s", .module = s2s_dep.module("s2s") },
        },
    });

    if (proto_only) return;

    const ziggy_maybe_dep = b.lazyDependency("ziggy", .{ .target = target, .optimize = optimize });
    const args_maybe_dep = b.lazyDependency("args", .{ .target = target, .optimize = optimize });
    const xkbcommon_maybe_dep = b.lazyDependency("xkbcommon", .{});

    const ziggy_dep = ziggy_maybe_dep orelse return;
    const args_dep = args_maybe_dep orelse return;
    const xkbcommon_dep = xkbcommon_maybe_dep orelse return;

    const xkbcommon_mod = xkbcommon_dep.module("xkbcommon");
    xkbcommon_mod.resolved_target = target;
    xkbcommon_mod.linkSystemLibrary("xkbcommon", .{});

    const args_mod = args_dep.module("args");

    const mzterwm_mod = b.addModule("mzterwm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "mzterwm-proto", .module = proto_mod },
            .{ .name = "ziggy", .module = ziggy_dep.module("ziggy") },
            .{ .name = "xkbcommon", .module = xkbcommon_mod },
            .{ .name = "args", .module = args_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mzterwm-proto", .module = proto_mod },
            .{ .name = "mzterwm", .module = mzterwm_mod },
            .{ .name = "args", .module = args_mod },
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
        scanner.generate("wl_output", 4);

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

    const ctl_mod = b.createModule(.{
        .root_source_file = b.path("src/ctl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mzterwm-proto", .module = proto_mod },
            .{ .name = "args", .module = args_mod },
        },
    });

    const ctl = b.addExecutable(.{
        .name = "mzterwmctl",
        .root_module = ctl_mod,
    });

    b.installArtifact(ctl);

    { // run mzterwm
        const run_step = b.step("run", "Run mzterwm");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args|
            run_cmd.addArgs(args);
    }

    { // run mzterwmctl
        const run_step = b.step("run-ctl", "Run mzterwmctl");
        const run_cmd = b.addRunArtifact(ctl);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args|
            run_cmd.addArgs(args);
    }

    // tests
    const test_step = b.step("test", "Run tests");

    for ([_]*std.Build.Module{ proto_mod, mzterwm_mod, exe_mod, ctl_mod }) |mod| {
        const tests = b.addTest(.{ .root_module = mod });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
