const std = @import("std");

/// Mirrors `src/version.zig` — kept here so the Info.plist template can
/// interpolate at build time without `@import`. Bump together when
/// cutting a release.
const djinn_version = "0.1.0-alpha.2";

pub fn build(b: *std.Build) void {
    // Follow the host on Linux; only macOS gets the deployment floor.
    // An explicit -Dtarget=x86_64-linux-gnu must never acquire Apple settings.
    const target = b.standardTargetOptions(.{
        .default_target = if (b.graph.host.result.os.tag == .macos) .{
            // Use an explicit baseline architecture, not a native CPU model.
            .cpu_arch = b.graph.host.result.cpu.arch,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
            .cpu_model = .baseline,
        } else .{ .cpu_model = .baseline },
    });
    if (target.result.os.tag == .macos and target.result.cpu.arch != .aarch64)
        @panic("macOS builds require Apple Silicon (aarch64); Intel Macs are no longer supported");
    const optimize = b.standardOptimizeOption(.{});
    const shared_tests = buildSharedTests(b, target, optimize);

    // Linux uses VTE, not libghostty. Return before instantiating either
    // Apple dependency, translating headers, or constructing Metal tools.
    if (target.result.os.tag == .linux) {
        buildLinux(b, target, optimize);
        return;
    }
    if (target.result.os.tag != .macos) @panic("djinn supports macOS and Linux only");
    const darwin_libc = buildDarwinLibC(b, target);
    shared_tests.setLibCFile(darwin_libc);

    // zig-objc: native AppKit views, panel, and menubar
    const objc_dep = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });
    const objc_mod = objc_dep.module("objc");

    // Full libghostty (shared) owns terminal state, input, and rendering via
    // ghostty_init / ghostty_app_new / ghostty_surface_new. Requires
    // patches/ghostty-001-darwin-install.patch applied via
    // scripts/apply-ghostty-patch.sh. The Nix environment uses its pinned
    // SDK for Zig discovery but system Xcode for Metal tools. Build via:
    //   nix develop --command ./scripts/build.sh
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"app-runtime" = .none,
        .@"emit-lib-vt" = false,
        .@"emit-exe" = false,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });

    const exe_mod = buildModule(b, .{
        .target = target,
        .optimize = optimize,
        .objc_mod = objc_mod,
        .ghostty_dep = ghostty_dep,
        .link_ghostty_full = true,
    });

    const exe = b.addExecutable(.{
        .name = "djinn",
        .root_module = exe_mod,
    });

    exe.setLibCFile(darwin_libc);
    b.installArtifact(exe);

    // Keep the raw executable usable without Ghostty.app too. Ghostty walks
    // selfExePath looking for share/terminfo, then uses share/ghostty.
    // Only install/bundle depend on these resources; unit tests never run
    // the generator or tic (and don't link either Ghostty library).
    const runtime_resources = buildRuntimeResources(b, ghostty_dep);
    const resources_step = b.step("resources", "Install Ghostty runtime resources only (no product build)");
    if (runtime_resources) |resources| {
        const dev_resources = installRuntimeResources(b, resources, "share");
        b.getInstallStep().dependOn(dev_resources);
        resources_step.dependOn(dev_resources);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run djinn");
    run_step.dependOn(&run_cmd.step);

    // ─── Djinn.app bundle ────────────────────────────────────────────
    //
    // `zig build bundle` produces zig-out/Djinn.app with the standard
    // macOS layout. Bundle path unblocks UNUserNotificationCenter
    // (entitlements-aware notifications), SMAppService login items,
    // proper code signing, and dock-less behavior via LSUIElement.
    //
    // Layout:
    //   Djinn.app/
    //     Contents/
    //       Info.plist
    //       MacOS/djinn
    //       Resources/Djinn.icns
    //       Resources/terminfo/78/xterm-ghostty (+ aliases)
    //       Resources/ghostty/{shell-integration,themes}
    //
    // Ad-hoc signing (`codesign --sign -`) is sufficient for local
    // dev; CI/release would swap in a Developer ID identity.
    //
    // Bundle build always uses ReleaseFast — Debug runs libghostty's
    // verifyIntegrity sweep on every page-grow, which dominates parse
    // time. Pinning the bundle to ReleaseFast keeps `zig build install-app`
    // honest regardless of the user's -Doptimize choice for the raw exe.
    const ghostty_dep_release = b.dependency("ghostty", .{
        .target = target,
        .optimize = .ReleaseFast,
        .@"app-runtime" = .none,
        .@"emit-lib-vt" = false,
        .@"emit-exe" = false,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });

    const bundle_exe_mod = buildModule(b, .{
        .target = target,
        .optimize = .ReleaseFast,
        .objc_mod = objc_mod,
        .ghostty_dep = ghostty_dep_release,
        .link_ghostty_full = true,
        .bundled_library = true,
    });

    const bundle_built_exe = b.addExecutable(.{
        .name = "djinn",
        .root_module = bundle_exe_mod,
    });
    bundle_built_exe.setLibCFile(darwin_libc);
    // A distributable bundle must never prefer build-cache or Nix paths.
    // Resolve the shared library beside the executable at link time.
    bundle_built_exe.each_lib_rpath = false;
    bundle_exe_mod.addRPathSpecial("@loader_path");

    const bundle_exe = b.addInstallArtifact(bundle_built_exe, .{
        .dest_dir = .{ .override = .{ .custom = "Djinn.app/Contents/MacOS" } },
    });

    // Binary references `@rpath/libghostty.dylib`; @loader_path resolves
    // the copy bundled beside it, independent of the checkout or Nix.
    const ghostty_full_release = ghostty_dep_release.artifact("ghostty");
    const bundle_dylib = b.addInstallFileWithDir(
        ghostty_full_release.getEmittedBin(),
        .{ .custom = "Djinn.app/Contents/MacOS" },
        "libghostty.dylib",
    );

    const wf = b.addWriteFiles();
    // Interpolate djinn_version into the bundle's CFBundleVersion +
    // CFBundleShortVersionString slots so the .app's metadata matches
    // src/version.zig without a hand-edit on every release.
    const plist_rendered = std.fmt.allocPrint(b.allocator, info_plist, .{ djinn_version, djinn_version }) catch @panic("OOM rendering Info.plist");
    const plist_path = wf.add("Info.plist", plist_rendered);
    const bundle_plist = b.addInstallFile(plist_path, "Djinn.app/Contents/Info.plist");
    bundle_plist.step.dependOn(&wf.step);

    // Bundle the app icon. assets/Djinn.icns is generated by
    // scripts/generate-icon.sh (swift renderer → sips → iconutil) and
    // committed to the repo so CI doesn't have to regenerate it.
    // Info.plist's CFBundleIconFile = "Djinn" picks it up.
    const bundle_icon = b.addInstallFile(
        b.path("assets/Djinn.icns"),
        "Djinn.app/Contents/Resources/Djinn.icns",
    );

    const bundle_step = b.step("bundle", "Build Djinn.app bundle");
    bundle_step.dependOn(&bundle_exe.step);
    bundle_step.dependOn(&bundle_dylib.step);
    bundle_step.dependOn(&bundle_plist.step);
    bundle_step.dependOn(&bundle_icon.step);
    if (runtime_resources) |resources| {
        bundle_step.dependOn(installRuntimeResources(
            b,
            resources,
            "Djinn.app/Contents/Resources",
        ));
    }

    // codesign-bundle.sh probes login.keychain for a stable
    // self-signed identity (`DjinnLocalDev`, created by
    // `scripts/dev-cert-create.sh`) and uses it if present, else falls
    // back to ad-hoc. The stable identity keeps the bundle's
    // designated requirement constant across rebuilds. Global hotkey
    // registration does not need that identity or privacy grants. Runs after all bundle
    // installation steps so the signature covers all code and resources.
    const sign_cmd = b.addSystemCommand(&.{"scripts/codesign-bundle.sh"});
    sign_cmd.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "Djinn.app" } }, .{});
    sign_cmd.step.dependOn(bundle_step);

    const bundle_sign_step = b.step("bundle-sign", "Build and sign Djinn.app");
    bundle_sign_step.dependOn(&sign_cmd.step);

    // ─── Install to ~/Applications ────────────────────────────────────
    //
    // `zig build install-app` copies the signed bundle into
    // `~/Applications` so the user can launch djinn from Spotlight /
    // Finder without sudo. /Applications would need elevated privileges
    // and isn't the right home for a single-user dev install anyway.
    //
    // SMAppService login-items + UN notifications both require a real
    // Application directory home (not just any path), and AppKit treats
    // ~/Applications as a first-class Application directory on macOS 12+.
    //
    // The script `scripts/install-app.sh` does the actual `rsync --delete`
    // so we get clean replaces (no stale Resources/ or signature drift)
    // and so the install step works from any CWD.
    const install_app_cmd = b.addSystemCommand(&.{"scripts/install-app.sh"});
    install_app_cmd.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "Djinn.app" } }, .{});
    install_app_cmd.step.dependOn(&sign_cmd.step);

    const install_app_step = b.step("install-app", "Install Djinn.app to ~/Applications");
    install_app_step.dependOn(&install_app_cmd.step);

    // Analyze the complete native host without linking libghostty or invoking
    // Metal. Unit tests don't otherwise reach all AppKit callback paths.
    const check_mod = buildModule(b, .{
        .target = target,
        .optimize = optimize,
        .objc_mod = objc_mod,
        .ghostty_dep = ghostty_dep,
        .link_ghostty_full = false,
    });
    const check = b.addExecutable(.{ .name = "djinn-check", .root_module = check_mod });
    check.setLibCFile(darwin_libc);
    const check_step = b.step("check", "Compile-check the complete host without linking or Metal");
    check_step.dependOn(&check.step);

    // Tests
    const test_mod = buildModule(b, .{
        .target = target,
        .optimize = optimize,
        .objc_mod = objc_mod,
        .ghostty_dep = ghostty_dep,
        .link_ghostty_full = false,
    });

    const exe_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    exe_unit_tests.setLibCFile(darwin_libc);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);
}

/// Linux's handwritten C externs need no headers. The check module deliberately
/// has no system-library entries: even pkg-config discovery would prevent a
/// compile-only Linux check on a Mac without GTK installed.
fn linuxModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link_system: bool,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main_linux.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;
    if (link_system) {
        // Keep layer-shell first: its Wayland symbol interposition requires
        // loading it before GTK's transitive libwayland dependency.
        // Zig 0.17's .force also rejects unknown pkg-config flags, including
        // GTK's transitive -mfpmath=sse/-msse/-msse2 C compiler options on x86.
        // .yes retains pkg-config discovery and supported flags without that
        // strict parsing; do not use .no (the pkg-config/library names differ).
        mod.linkSystemLibrary("gtk4-layer-shell-0", .{ .use_pkg_config = .yes });
        mod.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
        mod.linkSystemLibrary("vte-2.91-gtk4", .{ .use_pkg_config = .yes });
        mod.linkSystemLibrary("gobject-2.0", .{ .use_pkg_config = .yes });
        mod.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .yes });
        mod.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .yes });
    }
    return mod;
}

fn buildSharedTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests_shared.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run = b.addRunArtifact(tests);
    b.step("test-shared", "Run shared config/session/persistence tests without native UI libraries").dependOn(&run.step);
    const models = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests_linux_models.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = &.{
            "scrollback",      "placement",         "font and cursor",
            "removed colors",  "CSS replacement",   "appearance replacement",
            "autostart",       "desktopPath",       "stripDeletedAnnotation",
            "Status.label",    "owned image",       "file list",
            "formatPayload",   "percentDecode",     "drops reject",
            "tray login view", "buildThemeOptions",
        },
    });
    if (target.result.os.tag == .macos) models.setLibCFile(buildDarwinLibC(b, target));
    b.step("test-linux-models", "Run Linux pure policy/model/fixture tests on the host without GTK").dependOn(&b.addRunArtifact(models).step);
    return tests;
}

fn buildLinux(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const system_install = b.option(bool, "system-install", "Install optional desktop/user-unit packaging and documentation (Linux)") orelse false;
    const exe = b.addExecutable(.{
        .name = "djinn",
        .root_module = linuxModule(b, target, optimize, true),
    });
    b.installArtifact(exe);
    if (system_install) {
        b.installFile("contrib/packaging/djinn.desktop", "share/applications/djinn.desktop");
        // Installing this file does not enable or start the user service.
        b.installFile("contrib/packaging/djinn.service", "lib/systemd/user/djinn.service");
        b.installFile("LICENSE", "share/licenses/djinn/LICENSE");
        b.installFile("README.md", "share/doc/djinn/README.md");
        b.installFile("NOTICES.md", "share/doc/djinn/NOTICES.md");
        b.installFile("contrib/packaging/README.md", "share/doc/djinn/packaging.md");
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run djinn").dependOn(&run.step);

    const check = b.addExecutable(.{
        .name = "djinn-check",
        .root_module = linuxModule(b, target, optimize, false),
    });
    // No emitted binary is requested: Zig performs semantic analysis only.
    b.step("check", "Compile-check the Linux host without GTK linkage or pkg-config").dependOn(&check.step);

    const tests = b.addTest(.{ .root_module = linuxModule(b, target, optimize, true) });
    b.step("test", "Run Linux unit tests (no display required)").dependOn(&b.addRunArtifact(tests).step);
    // Semantic analysis of all tests without discovering/linking GTK/VTE.
    // This is intentionally not test execution or a native Linux link check.
    const compile_tests = b.addTest(.{ .root_module = linuxModule(b, target, optimize, false) });
    b.step("test-compile", "Compile-check Linux tests without native linkage or execution").dependOn(&compile_tests.step);
}

const ModuleOpts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    objc_mod: *std.Build.Module,
    ghostty_dep: *std.Build.Dependency,
    /// Link libghostty (ghostty_init, ghostty_surface_new …). Tests skip
    /// this: their pure code paths don't reference Ghostty symbols.
    link_ghostty_full: bool,
    /// Avoid linkLibrary's unconditional build-directory rpath in bundles.
    bundled_library: bool = false,
};

fn buildModule(b: *std.Build, opts: ModuleOpts) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    // SDK paths are module-local; objc's translated-header module does not
    // supply paths to the host module for our explicit deployment target.
    @import("zig_objc").addAppleSDK(b, mod) catch @panic("Apple SDK not found");
    mod.addImport("objc", opts.objc_mod);
    mod.addImport("darwin-c", buildDarwinC(b, opts));
    mod.link_libc = true; // Native host and test helpers call libSystem directly.

    if (opts.link_ghostty_full) {
        // GhosttyLib.initShared doesn't add framework links for darwin —
        // its production path goes through xcframework wrapper which
        // handles frameworks at packaging time. For plain `dep.artifact`
        // consumption we have to add Metal to the library's root module.
        const full = opts.ghostty_dep.artifact("ghostty");
        full.root_module.linkFramework("Metal", .{});
        if (opts.bundled_library) {
            mod.addObjectFile(full.getEmittedBin());
        } else {
            mod.linkLibrary(full);
        }
    }
    mod.addIncludePath(opts.ghostty_dep.path("include"));

    // macOS frameworks
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("CoreGraphics", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("Carbon", .{});
    // SMAppService for login-item registration (requires .app bundle).
    mod.linkFramework("ServiceManagement", .{});
    // FSEventStream for live config reload.
    mod.linkFramework("CoreServices", .{});
    // Metal + QuartzCore for the GPU glyph atlas renderer.
    mod.linkFramework("Metal", .{});
    mod.linkFramework("QuartzCore", .{});

    return mod;
}

/// Pin libc as well as header/framework paths to the discovered SDK. Without
/// --libc, Zig can reuse native-host libc discovery (and newer SDK metadata)
/// even when the module's explicit include/library paths use the Nix SDK.
fn buildDarwinLibC(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    var libc = std.zig.LibCInstallation.findNative(b.allocator, b.graph.io, .{
        .environ_map = &b.graph.environ_map,
        .target = &target.result,
        .verbose = false,
    }) catch @panic("Apple libc SDK not found");
    var stream: std.Io.Writer.Allocating = .init(b.allocator);
    defer stream.deinit();
    libc.render(&stream.writer) catch @panic("OOM rendering Apple libc paths");
    return b.addWriteFiles().add("darwin-libc.txt", stream.written());
}

/// Translate native headers once per target/optimization graph. Zig 0.17
/// no longer supports in-source @cImport.
fn buildDarwinC(b: *std.Build, opts: ModuleOpts) *std.Build.Module {
    const source = b.addWriteFiles().add("darwin.h",
        \\#include <Carbon/Carbon.h>
        \\#include <CoreFoundation/CoreFoundation.h>
        \\#include <CoreGraphics/CoreGraphics.h>
        \\#include <CoreText/CoreText.h>
        \\#include <CoreServices/CoreServices.h>
        \\#include <dispatch/dispatch.h>
        \\#include "ghostty.h"
        \\
    );
    const translate = b.addTranslateC(.{
        .root_source_file = source,
        .target = opts.target,
        .optimize = opts.optimize,
    });
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &opts.target.result) orelse
        @panic("Apple SDK not found");
    translate.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    translate.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    translate.addIncludePath(opts.ghostty_dep.path("include"));
    return translate.createModule();
}

const RuntimeResources = struct {
    terminfo: std.Build.LazyPath,
    shell_integration: std.Build.LazyPath,
    themes: std.Build.LazyPath,
};

/// Generate only the runtime data, not Ghostty's app, docs, completions, or
/// build-data CLI (which would pull in unrelated build-time dependencies).
fn buildRuntimeResources(b: *std.Build, ghostty_dep: *std.Build.Dependency) ?RuntimeResources {
    // Reuse Ghostty's existing theme pin. A null result requests its lazy
    // dependency; Zig fetches it and reruns graph construction before building.
    const themes = ghostty_dep.builder.lazyDependency("iterm2_themes", .{}) orelse return null;

    const generator = b.addExecutable(.{
        .name = "djinn-terminfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/terminfo.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    generator.root_module.link_libc = true;
    generator.root_module.addImport("ghostty_terminfo", b.createModule(.{
        .root_source_file = ghostty_dep.path("src/terminfo/ghostty.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }));
    const generate = b.addRunArtifact(generator);
    // Give tic a named input file; it is generated from the same pinned
    // Ghostty source as the library, never copied from an installed app.
    const source_files = b.addWriteFiles();
    const source = source_files.addCopyFile(generate.captureStdOut(.{}), "ghostty.terminfo");

    // Use Apple's tic deliberately: its hexadecimal directory layout is
    // required by Ghostty's macOS sentinel (terminfo/78/xterm-ghostty).
    // An arbitrary ncurses tic from PATH can instead produce x/xterm-ghostty.
    const tic = b.addSystemCommand(&.{ "/usr/bin/tic", "-x", "-o" });
    const terminfo = tic.addOutputDirectoryArg("terminfo");
    tic.addFileArg(source);

    return .{
        .terminfo = terminfo,
        .shell_integration = ghostty_dep.path("src/shell-integration"),
        .themes = themes.path(""),
    };
}

/// Install the same minimal runtime tree into either share/ or the bundle.
fn installRuntimeResources(
    b: *std.Build,
    resources: RuntimeResources,
    subdir: []const u8,
) *std.Build.Step {
    const group = b.allocator.create(std.Build.Step.TopLevel) catch @panic("OOM");
    group.* = .{
        .step = .init(.{
            .tag = .top_level,
            .name = b.fmt("install runtime resources to {s}", .{subdir}),
            .owner = b,
        }),
        .description = "Install runtime resources",
    };
    const step = &group.step;

    const shell = b.addInstallDirectory(.{
        .source_dir = resources.shell_integration,
        .install_dir = .prefix,
        .install_subdir = b.pathJoin(&.{ subdir, "ghostty/shell-integration" }),
        .exclude_extensions = &.{".md"},
    });
    step.dependOn(&shell.step);
    const themes = b.addInstallDirectory(.{
        .source_dir = resources.themes,
        .install_dir = .prefix,
        .install_subdir = b.pathJoin(&.{ subdir, "ghostty/themes" }),
        .exclude_extensions = &.{".md"},
    });
    step.dependOn(&themes.step);

    // InstallDir doesn't preserve symlinks reliably. Keep tic's aliases,
    // just as upstream GhosttyResources does. Precreate the directory so repeated
    // installs merge into terminfo rather than changing the copy layout.
    const destination: std.Build.LazyPath = .{ .relative = .{ .base = .install_prefix, .sub_path = subdir } };
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p" });
    mkdir.addDirectoryArg2(destination.path(b, "terminfo"), .{});
    const copy = b.addSystemCommand(&.{ "cp", "-R", "-P" });
    copy.addDirectoryArg(resources.terminfo);
    copy.addDirectoryArg2(destination, .{});
    copy.step.dependOn(&mkdir.step);
    step.dependOn(&copy.step);
    return step;
}

/// Minimal Info.plist for djinn.
///
/// LSUIElement = true: app has no dock icon and no app-level menu bar
///   (djinn already hosts its own status item in the system menu bar).
/// NSHighResolutionCapable: enables Retina-aware drawing — without it
///   AppKit treats the app as 1x and bilinear-upscales.
/// LSMinimumSystemVersion: macOS 13 covers the AppKit + libdispatch
///   APIs djinn uses; bump if we adopt newer SDK features.
const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\    <key>CFBundleName</key>
    \\    <string>Djinn</string>
    \\    <key>CFBundleDisplayName</key>
    \\    <string>Djinn</string>
    \\    <key>CFBundleIdentifier</key>
    \\    <string>com.pders01.djinn</string>
    \\    <key>CFBundleVersion</key>
    \\    <string>{s}</string>
    \\    <key>CFBundleShortVersionString</key>
    \\    <string>{s}</string>
    \\    <key>CFBundleExecutable</key>
    \\    <string>djinn</string>
    \\    <key>CFBundlePackageType</key>
    \\    <string>APPL</string>
    \\    <key>CFBundleSignature</key>
    \\    <string>????</string>
    \\    <key>CFBundleInfoDictionaryVersion</key>
    \\    <string>6.0</string>
    \\    <key>CFBundleIconFile</key>
    \\    <string>Djinn</string>
    \\    <key>CFBundleIconName</key>
    \\    <string>Djinn</string>
    \\    <key>LSUIElement</key>
    \\    <true/>
    \\    <key>NSHighResolutionCapable</key>
    \\    <true/>
    \\    <key>LSMinimumSystemVersion</key>
    \\    <string>13.0</string>
    \\    <key>NSPrincipalClass</key>
    \\    <string>NSApplication</string>
    \\    <key>NSAppleEventsUsageDescription</key>
    \\    <string>Djinn uses AppleScript to display notifications without bundle entitlements.</string>
    \\</dict>
    \\</plist>
    \\
;
