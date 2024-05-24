//   Copyright 2024 Ryan "rj45" Sanche
//   Copyright 2024 Ben Crist
//
//   Licensed under the Apache License, Version 2.0 (the "License");
//   you may not use this file except in compliance with the License.
//   You may obtain a copy of the License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the License is distributed on an "AS IS" BASIS,
//   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   See the License for the specific language governing permissions and
//   limitations under the License.

/////////////////////////////////////////////////////////////////////////
// NOTE: This zib build script is experimental! If you want to use it,
// please contribute any fixes it needs! It's very appreciated!
// - rj45
/////////////////////////////////////////////////////////////////////////

const std = @import("std");
const zcc = @import("compile_commands");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = switch (b.host.result.os.tag) {
            .windows => switch (b.host.result.cpu.arch) {
                .x86_64 => std.Target.Query.parse(.{ .arch_os_abi = "x86_64-windows-msvc" }) catch @panic("invalid default target"),
                else => b.host.query,
            },
            else => b.host.query,
        },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const digilogic = b.addExecutable(.{
        .name = "digilogic",
        .target = target,
        .optimize = optimize,
    });

    var cflags = std.ArrayList([]const u8).init(b.allocator);
    cflags.append("-std=gnu11") catch @panic("OOM");

    if (optimize == .Debug and target.result.abi != .msvc) {
        digilogic.root_module.addCMacro("DEBUG", "1");
        cflags.append("-g") catch @panic("OOM");
        cflags.append("-O1") catch @panic("OOM");
        cflags.append("-fno-omit-frame-pointer") catch @panic("OOM");
        cflags.append("-Wall") catch @panic("OOM");
        cflags.append("-Werror") catch @panic("OOM");
        if (target.result.os.tag.isDarwin()) {
            // turn on address and undefined behaviour sanitizers
            cflags.append("-fsanitize=address,undefined") catch @panic("OOM");
            const brew_cellar = (std.ChildProcess.run(.{
                .allocator = b.allocator,
                .argv = &.{
                    "brew",
                    "--cellar",
                },
                .cwd = b.pathFromRoot("."),
                .expand_arg0 = .expand,
            }) catch @panic("Could not find homebrew cellar")).stdout;
            // todo: figure out how to search for the version so it's not hard-coded
            //       major version needs to match zig's version, minor/patch don't matter
            // todo: not sure how to make a lazypath for an absolute path
            digilogic.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/llvm@17/17.0.6/lib/clang/17/lib/darwin/", .{brew_cellar[0 .. brew_cellar.len - 1]}) });
            digilogic.linkSystemLibrary("clang_rt.asan_osx_dynamic");
        } else {
            // todo: turn on address sanitizer for linux?
        }
    }

    digilogic.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "main.c",
            "core/circuit.c",
            "core/smap.c",
            "core/save.c",
            "core/load.c",
            "core/bvh.c",
            "ux/ux.c",
            "ux/input.c",
            "ux/snap.c",
            "ux/undo.c",
            "ui/ui.c",
            "view/view.c",
            "import/digital.c",
            "autoroute/autoroute.c",
            "render/fons_sgp.c",
            "render/sokol_nuklear.c",
            "render/fons_nuklear.c",
            "render/polyline.c",
            "render/draw.c",
        },
        .flags = cflags.items,
    });

    // create an assets.zip from the contents of res/assets
    var asset_zip: std.Build.LazyPath = undefined;
    if (b.host.result.os.tag == .windows) {
        const asset_zip_cmd = b.addSystemCommand(&.{
            "powershell",
            "Compress-Archive",
            "-Path",
            "assets",
            "-DestinationPath",
        });
        asset_zip_cmd.setCwd(b.path("res"));
        asset_zip = asset_zip_cmd.addOutputFileArg("assets.zip");
    } else {
        const asset_zip_cmd = b.addSystemCommand(&.{ "zip", "-r", "-9" });
        asset_zip_cmd.setCwd(b.path("res"));
        asset_zip = asset_zip_cmd.addOutputFileArg("assets.zip");
        asset_zip_cmd.addArg("assets");
    }

    // complile src/gen.c to generate C code
    const asset_gen = b.addExecutable(.{
        .name = "gen",
        .target = b.host,
    });
    asset_gen.addCSourceFile(.{
        .file = b.path("src/gen.c"),
        .flags = &.{"-std=gnu11"},
    });

    // generate assets.c from assets.zip
    const asset_gen_step = b.addRunArtifact(asset_gen);
    asset_gen_step.addFileArg(asset_zip);
    const assets_c = asset_gen_step.addOutputFileArg("assets.c");
    digilogic.addCSourceFile(.{
        .file = assets_c,
        .flags = cflags.items,
    });

    digilogic.addCSourceFile(.{
        .file = b.path("thirdparty/yyjson.c"),
        .flags = cflags.items,
    });

    digilogic.addIncludePath(b.path("src"));
    digilogic.addIncludePath(b.path("thirdparty"));

    digilogic.linkLibC();

    if (optimize == .Debug and target.result.abi != .msvc) {}

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
    }).artifact("freetype");
    digilogic.linkLibrary(freetype);

    digilogic.root_module.addCMacro("NVD_STATIC_LINKAGE", "");
    digilogic.linkLibrary(build_nvdialog(b, target, optimize));

    const Renderer = enum {
        metal,
        opengl,
        opengles,
        d3d11,
    };
    const renderer = b.option(Renderer, "renderer", "Specify which rendering API to use (not all renderers work on all platforms");

    var rust_target: []const u8 = target.result.linuxTriple(b.allocator) catch @panic("OOM");

    const msaa_sample_count = b.option(u32, "msaa_sample_count", "Number of MSAA samples to use (1 for no MSAA, default 4)") orelse 4;
    digilogic.root_module.addCMacro("MSAA_SAMPLE_COUNT", b.fmt("{d}", .{msaa_sample_count}));

    if (target.result.os.tag.isDarwin()) {
        if (target.result.cpu.arch.isAARCH64()) {
            rust_target = "aarch64-apple-darwin";
        } else if (target.result.cpu.arch.isX86()) {
            rust_target = "x86_64-apple-darwin";
        } else {
            @panic("Unsupported CPU architecture for macOS");
        }

        // add apple.m (a copy of nonapple.c) to the build
        // this is required in order for the file to be compiled as Objective-C
        var mflags2 = std.ArrayList([]const u8).init(b.allocator);
        mflags2.append("-ObjC") catch @panic("OOM");
        mflags2.append("-fobjc-arc") catch @panic("OOM");
        mflags2.appendSlice(cflags.items) catch @panic("OOM");
        digilogic.addCSourceFile(.{
            .file = b.addWriteFiles().addCopyFile(b.path("src/nonapple.c"), "apple.m"),
            .flags = mflags2.items,
        });

        if (.metal != (renderer orelse .metal)) {
            @panic("This target supports only -Drenderer=metal");
        }

        digilogic.root_module.addCMacro("SOKOL_METAL", "");

        digilogic.linkFramework("Metal");
        digilogic.linkFramework("MetalKit");
        digilogic.linkFramework("Quartz");
        digilogic.linkFramework("Cocoa");
        digilogic.linkFramework("UniformTypeIdentifiers");
    } else if (target.result.os.tag == .windows) {
        // TODO this is just for testing; need a more robust way to map zig->rust targets if this ever works
        if (target.result.abi == .msvc) {
            // `zig build -Dtarget=x86_64-windows-msvc`
            rust_target = "x86_64-pc-windows-msvc";
        } else if (target.result.abi == .gnu) {
            // `zig build -Dtarget=x86_64-windows-gnu`
            rust_target = "x86_64-pc-windows-gnu";
        }

        digilogic.addWin32ResourceFile(.{
            .file = b.path("res/app.rc"),
        });

        digilogic.addCSourceFiles(.{
            .root = b.path("src"),
            .files = &.{
                "nonapple.c",
            },
            .flags = cflags.items,
        });

        switch (renderer orelse .d3d11) {
            .opengl => {
                digilogic.root_module.addCMacro("SOKOL_GLCORE33", "");
                digilogic.linkSystemLibrary("opengl32");
            },
            .d3d11 => {
                digilogic.root_module.addCMacro("SOKOL_D3D11", "");
                digilogic.linkSystemLibrary("d3d11");
                digilogic.linkSystemLibrary("dxgi");
            },
            else => @panic("This target supports only -Drenderer=d3d11 or -Drenderer=opengl"),
        }

        digilogic.linkSystemLibrary("kernel32");
        digilogic.linkSystemLibrary("user32");
        digilogic.linkSystemLibrary("gdi32");
        digilogic.linkSystemLibrary("ole32");
        digilogic.linkSystemLibrary("bcrypt"); // required by rust
        digilogic.linkSystemLibrary("ws2_32"); // required by rust
        digilogic.linkSystemLibrary("userenv"); // required by rust
        digilogic.linkSystemLibrary("advapi32"); // required by rust
    } else {
        // assuming linux
        rust_target = "x86_64-unknown-linux-gnu";

        digilogic.addCSourceFiles(.{
            .root = b.path("src"),
            .files = &.{
                "nonapple.c",
            },
            .flags = cflags.items,
        });

        const use_wayland = b.option(bool, "wayland", "Compile for Wayland instead of X11") orelse false;

        switch (renderer orelse .opengl) {
            .opengl => digilogic.root_module.addCMacro("SOKOL_GLCORE33", ""),
            .opengles => digilogic.root_module.addCMacro("SOKOL_GLES3", ""),
            else => @panic("This target supports only -Drenderer=opengl or -Drenderer=opengles"),
        }

        digilogic.linkSystemLibrary("GL");

        digilogic.linkSystemLibrary("unwind"); // required by rust

        const use_egl = b.option(bool, "egl", "Force Sokol to use EGL instead of GLX for OpenGL context creation") orelse use_wayland;
        if (use_egl) {
            digilogic.root_module.addCMacro("SOKOL_FORCE_EGL", "");
            digilogic.linkSystemLibrary("EGL");
        }

        if (use_wayland) {
            digilogic.root_module.addCMacro("SOKOL_DISABLE_X11", "");
            digilogic.root_module.addCMacro("SOKOL_LINUX_CUSTOM", "");

            // TODO not sure if this is normally on the path; may need a better autodetection?
            const wayland_scanner_path = b.option([]const u8, "wayland-scanner-path", "Path to the system's wayland-scanner binary, if not on the path") orelse "wayland-scanner";

            const WaylandSource = struct {
                xml_path: []const u8,
                basename: []const u8,
            };

            inline for ([_]WaylandSource{
                .{ .xml_path = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml", .basename = "xdg-shell-protocol" },
                .{ .xml_path = "/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml", .basename = "pointer-constraints-unstable-v1-protocol" },
                .{ .xml_path = "/usr/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml", .basename = "relative-pointer-unstable-v1-protocol" },
            }) |source| {
                const generate_header = b.addSystemCommand(&.{ wayland_scanner_path, "client-header" });
                generate_header.setStdIn(.{ .lazy_path = b.path(source.xml_path) });
                const header_file = generate_header.captureStdOut();
                // This is pretty fragile; really captureStdOut() should take an options struct so that the basename
                // can be specified directly...  maybe I'll submit a PR to zig
                const header_output: *std.Build.Step.Run.Output = @fieldParentPtr("generated_file", @constCast(header_file.generated));
                header_output.basename = source.basename ++ ".h";

                const generate_source = b.addSystemCommand(&.{ wayland_scanner_path, "private-code" });
                generate_source.setStdIn(.{ .lazy_path = b.path(source.xml_path) });
                const source_file = generate_source.captureStdOut();
                const source_output: *std.Build.Step.Run.Output = @fieldParentPtr("generated_file", @constCast(source_file.generated));
                source_output.basename = source.basename ++ ".c";

                digilogic.addCSourceFile(.{
                    .file = source_file,
                    .flags = cflags.items,
                });
                digilogic.addIncludePath(.{ .generated_dirname = .{
                    .generated = header_file.generated,
                    .up = 0,
                } });
            }

            digilogic.linkSystemLibrary("wayland-client");
            digilogic.linkSystemLibrary("wayland-cursor");
            digilogic.linkSystemLibrary("wayland-egl");
            digilogic.linkSystemLibrary("xkbcommon");
        } else {
            // X11
            digilogic.root_module.addCMacro("SOKOL_DISABLE_WAYLAND", "1");

            digilogic.linkSystemLibrary("X11");
            digilogic.linkSystemLibrary("Xi");
            digilogic.linkSystemLibrary("Xcursor");
        }
    }

    const cargo_build = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--target",
        rust_target,
        "--profile",
        if (optimize == .Debug) "dev" else "release",
    });
    cargo_build.stdio = .inherit;
    cargo_build.setCwd(b.path("thirdparty/routing"));
    digilogic.step.dependOn(&cargo_build.step);

    const rust_profile = if (optimize == .Debug) "debug" else "release";
    const library_path = b.fmt("thirdparty/routing/target/{s}/{s}", .{ rust_target, rust_profile });
    digilogic.addLibraryPath(b.path(library_path));
    digilogic.linkSystemLibrary("digilogic_routing");

    if (target.result.os.tag.isDarwin()) {
        // apple has their own way of doing things
        // we need to create an app bundle folder with the right structure
        const install_bin = b.addInstallArtifact(digilogic, .{ .dest_dir = .{ .override = .{ .custom = "digilogic.app/Contents/MacOS" } } });
        const install_plist = b.addInstallFile(b.path("res/Info.plist"), "digilogic.app/Contents/Info.plist");
        const install_icns = b.addInstallFile(b.path("res/logo.icns"), "digilogic.app/Contents/Resources/logo.icns");
        install_bin.step.dependOn(&install_plist.step);
        install_bin.step.dependOn(&install_icns.step);
        b.getInstallStep().dependOn(&install_bin.step);
    } else {
        b.installArtifact(digilogic);
    }

    zcc.createStep(b, "cdb", .{ .target = digilogic });
}

fn build_nvdialog(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const nvdialog = b.addStaticLibrary(.{
        .name = "nvdialog",
        .target = target,
        .optimize = optimize,
    });

    const cflags = &.{
        "-std=gnu11",
        "-Wno-unused-parameter",
        "-Wconversion",
        "-Werror=format",
        "-Werror=format-security",
        "-Winline",
        "-Wall",
        "-Wextra",
        "-fstack-protector-all",
        "--param",
        "ssp-buffer-size=4",
    };

    nvdialog.addIncludePath(b.path("thirdparty/nvdialog/include"));
    nvdialog.addIncludePath(b.path("thirdparty/nvdialog/src"));
    nvdialog.addIncludePath(b.path("thirdparty/nvdialog/src/impl"));

    nvdialog.linkLibC();

    nvdialog.root_module.addCMacro("NVDIALOG_MAXBUF", "4096");
    nvdialog.root_module.addCMacro("NVD_EXPORT_SYMBOLS", "");
    nvdialog.root_module.addCMacro("NVD_STATIC_LINKAGE", "");

    const platform_ext = if (target.result.os.tag.isDarwin()) ".m" else ".c";

    const platform_files = &.{
        "nvdialog_dialog_box" ++ platform_ext,
        "nvdialog_file_dialog" ++ platform_ext,
        "nvdialog_question_dialog" ++ platform_ext,
        "nvdialog_notification" ++ platform_ext,
        "nvdialog_about_dialog" ++ platform_ext,
    };

    if (target.result.os.tag.isDarwin()) {
        nvdialog.root_module.addCMacro("NVD_USE_COCOA", "1");

        nvdialog.addCSourceFiles(.{
            .root = b.path("thirdparty/nvdialog/src/backend/cocoa"),
            .files = platform_files,
            .flags = cflags,
        });

        nvdialog.linkFramework("AppKit");
        nvdialog.linkFramework("Cocoa");
        nvdialog.linkFramework("Foundation");
        nvdialog.linkFramework("UserNotifications");
    } else if (target.result.os.tag == .windows) {
        nvdialog.addCSourceFiles(.{
            .root = b.path("thirdparty/nvdialog/src/backend/win32"),
            .files = platform_files,
            .flags = cflags,
        });

        nvdialog.linkSystemLibrary("comdlg32");
        nvdialog.linkSystemLibrary("shell32");
        nvdialog.linkSystemLibrary("user32");
    } else {
        nvdialog.root_module.addCMacro("NVD_SANDBOX_SUPPORT", "0");
        nvdialog.addCSourceFiles(.{
            .root = b.path("thirdparty/nvdialog/src/backend/gtk"),
            .files = platform_files,
            .flags = cflags,
        });

        nvdialog.addCSourceFiles(.{
            .root = b.path("thirdparty/nvdialog/src/backend/sandbox"),
            .files = platform_files,
            .flags = cflags,
        });

        nvdialog.linkSystemLibrary("gtk+-3.0");
    }

    nvdialog.addCSourceFiles(.{
        .root = b.path("thirdparty/nvdialog/src"),
        .files = &.{
            "nvdialog_error.c",
            "nvdialog_capab.c",
            "nvdialog_version.c",
            "nvdialog_main.c",
            "nvdialog_util.c",
        },
        .flags = cflags,
    });

    nvdialog.installHeadersDirectory(b.path("thirdparty/nvdialog/include"), "", .{});

    return nvdialog;
}
