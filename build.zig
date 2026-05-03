const std = @import("std");

/// Mirrors `src/version.zig` — kept here so the Info.plist template can
/// interpolate at build time without `@import`. Bump together when
/// cutting a release.
const djinn_version = "0.1.0-alpha.1";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-objc: hotkey CGEventTap + menubar
    const objc_dep = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });
    const objc_mod = objc_dep.module("objc");

    // libghostty-vt: VT parser, screen model, render-state iterators, key encoder.
    // Tier-5 spike additionally links the full libghostty (shared) for
    // ghostty_init / ghostty_app_new / ghostty_surface_new. Requires
    // patches/ghostty-001-darwin-install.patch applied via
    // scripts/apply-ghostty-patch.sh AND `DEVELOPER_DIR` + `SDKROOT` unset
    // (nix shell defaults steer xcrun at the wrong SDK). Build via:
    //   nix develop --command bash -c \
    //     'unset DEVELOPER_DIR SDKROOT; PATH=/usr/bin:$PATH zig build'
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
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

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
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
    //       Resources/   (icon goes here once we have one)
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
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });

    const bundle_exe_mod = buildModule(b, .{
        .target = target,
        .optimize = .ReleaseFast,
        .objc_mod = objc_mod,
        .ghostty_dep = ghostty_dep_release,
        .link_ghostty_full = true,
    });

    const bundle_built_exe = b.addExecutable(.{
        .name = "djinn",
        .root_module = bundle_exe_mod,
    });
    // Reserve room in the Mach-O header so install_name_tool can rewrite
    // load commands later (we add `@loader_path` to the rpath list so the
    // bundled binary resolves `@rpath/libghostty.dylib` against the dylib
    // we copy next to it). Without headerpad, install_name_tool fails:
    // "larger updated load commands do not fit".
    bundle_built_exe.headerpad_max_install_names = true;

    const bundle_exe = b.addInstallArtifact(bundle_built_exe, .{
        .dest_dir = .{ .override = .{ .custom = "Djinn.app/Contents/MacOS" } },
    });

    // libghostty.dylib bundling. Binary references `@rpath/libghostty.dylib`;
    // the dev cache rpath baked in by the linker only resolves while the
    // bare exe runs from the project dir. For the bundle we copy the dylib
    // next to the binary and add `@loader_path` to the rpath list.
    const ghostty_full_release = ghostty_dep_release.artifact("ghostty");
    const bundle_dylib = b.addInstallFileWithDir(
        ghostty_full_release.getEmittedBin(),
        .{ .custom = "Djinn.app/Contents/MacOS" },
        "libghostty.dylib",
    );

    // install_name_tool runs before codesign — modifying the binary
    // invalidates the signature, so we have to re-sign after, which is
    // exactly what the existing sign_cmd does.
    const bundle_bin_path = b.pathJoin(&.{ b.install_path, "Djinn.app/Contents/MacOS/djinn" });
    const fix_rpath = b.addSystemCommand(&.{
        "install_name_tool", "-add_rpath", "@loader_path", bundle_bin_path,
    });
    fix_rpath.step.dependOn(&bundle_exe.step);
    fix_rpath.step.dependOn(&bundle_dylib.step);

    const wf = b.addWriteFiles();
    // Interpolate djinn_version into the bundle's CFBundleVersion +
    // CFBundleShortVersionString slots so the .app's metadata matches
    // src/version.zig without a hand-edit on every release.
    const plist_rendered = std.fmt.allocPrint(b.allocator, info_plist, .{ djinn_version, djinn_version }) catch @panic("OOM rendering Info.plist");
    const plist_path = wf.add("Info.plist", plist_rendered);
    const bundle_plist = b.addInstallFile(plist_path, "Djinn.app/Contents/Info.plist");
    bundle_plist.step.dependOn(&wf.step);

    const bundle_step = b.step("bundle", "Build Djinn.app bundle");
    bundle_step.dependOn(&bundle_exe.step);
    bundle_step.dependOn(&bundle_dylib.step);
    bundle_step.dependOn(&fix_rpath.step);
    bundle_step.dependOn(&bundle_plist.step);

    // Ad-hoc codesign so Gatekeeper accepts launches from the bundle.
    // Runs after install_name_tool so the signature covers the rpath fix.
    const sign_cmd = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--deep" });
    sign_cmd.addArg(b.pathJoin(&.{ b.install_path, "Djinn.app" }));
    sign_cmd.step.dependOn(bundle_step);

    const bundle_sign_step = b.step("bundle-sign", "Build + ad-hoc sign Djinn.app");
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
    install_app_cmd.addArg(b.pathJoin(&.{ b.install_path, "Djinn.app" }));
    install_app_cmd.step.dependOn(&sign_cmd.step);

    const install_app_step = b.step("install-app", "Install Djinn.app to ~/Applications");
    install_app_step.dependOn(&install_app_cmd.step);

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
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);
}

const ModuleOpts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    objc_mod: *std.Build.Module,
    ghostty_dep: *std.Build.Dependency,
    /// Link the full libghostty (ghostty_init, ghostty_surface_new …) on
    /// top of the vt-static parser. Tests skip this — surface symbols
    /// aren't reached from the unit tests today and the full lib link
    /// triples test build time.
    link_ghostty_full: bool,
};

fn buildModule(b: *std.Build, opts: ModuleOpts) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    mod.addImport("objc", opts.objc_mod);

    mod.linkLibrary(opts.ghostty_dep.artifact("ghostty-vt-static"));
    if (opts.link_ghostty_full) {
        // GhosttyLib.initShared doesn't add framework links for darwin —
        // its production path goes through xcframework wrapper which
        // handles frameworks at packaging time. For plain `dep.artifact`
        // consumption we have to add Metal here on the Compile step.
        const full = opts.ghostty_dep.artifact("ghostty");
        full.linkFramework("Metal");
        mod.linkLibrary(full);
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
