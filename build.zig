const std = @import("std");

/// Mirrors `src/version.zig` — kept here so the Info.plist template can
/// interpolate at build time without `@import`. Bump together when
/// cutting a release.
const djinn_version = "0.1.0-alpha.1";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tag = target.result.os.tag;
    const is_darwin = tag.isDarwin();
    const is_linux = tag == .linux;

    // zig-objc: hotkey CGEventTap + menubar. Darwin-only — the
    // dependency itself compiles only on darwin and isn't imported by
    // any non-darwin source file.
    const objc_mod: ?*std.Build.Module = if (is_darwin) blk: {
        const objc_dep = b.dependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk objc_dep.module("objc");
    } else null;

    // libghostty-vt: VT parser, screen model, render-state iterators, key encoder.
    // Tier-5 spike additionally links the full libghostty (shared) for
    // ghostty_init / ghostty_app_new / ghostty_surface_new. Requires
    // patches/ghostty-001-darwin-install.patch applied via
    // scripts/apply-ghostty-patch.sh AND (darwin) `DEVELOPER_DIR` +
    // `SDKROOT` unset (nix shell defaults steer xcrun at the wrong SDK).
    // Build via:
    //   nix develop --command bash -c \
    //     'unset DEVELOPER_DIR SDKROOT; PATH=/usr/bin:$PATH zig build'
    //
    // Linux: ghostty's GTK apprt is the eventual surface host. For the
    // Phase 0 smoke target we still pull the dep but only link
    // ghostty-vt-static; the full libghostty link comes in once the
    // GTK4 host shell starts driving surfaces. The `emit-*` options are
    // darwin-specific bundling toggles in ghostty's build.zig; passing
    // them on linux errors out as unknown options.
    const ghostty_dep = if (is_darwin)
        b.dependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .@"emit-xcframework" = false,
            .@"emit-macos-app" = false,
        })
    else
        b.dependency("ghostty", .{
            .target = target,
            .optimize = optimize,
        });

    const exe_mod = buildModule(b, .{
        .target = target,
        .optimize = optimize,
        .objc_mod = objc_mod,
        .ghostty_dep = ghostty_dep,
        .link_ghostty_full = is_darwin,
        .is_darwin = is_darwin,
        .is_linux = is_linux,
    });

    const exe = b.addExecutable(.{
        .name = "djinn",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Linux: ship the canonical .desktop alongside the binary so
    // packaging recipes that just do `zig build --prefix /usr` install
    // a system-menu entry too. Pinning to $prefix/share/applications/
    // (the system path the portal hotkey approval persists against)
    // is what makes KDE's GlobalShortcuts dialog stop re-prompting on
    // every upgrade — the autostart entry in ~/.config/autostart/ has
    // a different scope and identity. Skipped on darwin (no equivalent).
    if (is_linux) {
        b.installFile(
            "contrib/packaging/djinn.desktop",
            "share/applications/djinn.desktop",
        );
        // systemd user unit — distro-agnostic. The packagers'
        // --prefix /usr lands this at /usr/lib/systemd/user/djinn.service,
        // the canonical search path for system-installed user units
        // (systemd loads from /etc/systemd/user, $XDG_CONFIG_HOME/
        // systemd/user, /usr/lib/systemd/user, /usr/share/systemd/user
        // — the lib/ path is the one distro packages use).
        // `systemctl --user enable djinn.service` opts in; we don't
        // auto-enable on install.
        b.installFile(
            "contrib/packaging/djinn.service",
            "lib/systemd/user/djinn.service",
        );
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run djinn");
    run_step.dependOn(&run_cmd.step);

    // ─── Tests ──────────────────────────────────────────────────────
    //
    // Defined early so both platforms reach this branch before the
    // darwin-only bundle steps short-circuit a non-darwin build.
    const test_mod = buildModule(b, .{
        .target = target,
        .optimize = optimize,
        .objc_mod = objc_mod,
        .ghostty_dep = ghostty_dep,
        .link_ghostty_full = false,
        .is_darwin = is_darwin,
        .is_linux = is_linux,
    });

    const exe_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);

    // Bundle / install-app are darwin .app concepts; bail out before
    // we touch install_name_tool / codesign on linux.
    if (!is_darwin) return;

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
        .is_darwin = true,
        .is_linux = false,
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
    bundle_step.dependOn(&fix_rpath.step);
    bundle_step.dependOn(&bundle_plist.step);
    bundle_step.dependOn(&bundle_icon.step);

    // codesign-bundle.sh probes login.keychain for a stable
    // self-signed identity (`DjinnLocalDev`, created by
    // `scripts/dev-cert-create.sh`) and uses it if present, else falls
    // back to ad-hoc. The stable identity keeps the bundle's
    // designated requirement constant across rebuilds, so TCC's
    // Accessibility + Input Monitoring grants persist instead of
    // burning on every install-app. Runs after install_name_tool so
    // the signature covers the rpath fix.
    const sign_cmd = b.addSystemCommand(&.{"scripts/codesign-bundle.sh"});
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
}

const ModuleOpts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Null on linux — zig-objc is darwin-only and isn't pulled into the
    /// dependency graph on non-darwin targets.
    objc_mod: ?*std.Build.Module,
    ghostty_dep: *std.Build.Dependency,
    /// Link the full libghostty (ghostty_init, ghostty_surface_new …) on
    /// top of the vt-static parser. Tests skip this — surface symbols
    /// aren't reached from the unit tests today and the full lib link
    /// triples test build time. Linux Phase 0 also skips: ghostty's GTK
    /// apprt host shell isn't wired yet.
    link_ghostty_full: bool,
    is_darwin: bool,
    is_linux: bool,
};

fn buildModule(b: *std.Build, opts: ModuleOpts) *std.Build.Module {
    // Per-OS root source file. Darwin keeps the historical main.zig as
    // its entry; linux uses main_linux.zig — a stub that grows into the
    // GTK4 host shell over the next phases. Splitting roots (rather
    // than gating every `@import("objc")` with `if (builtin.os.tag)`)
    // keeps the darwin side untouched and confines linux-specific code
    // to a single subtree.
    const root_path = if (opts.is_linux) "src/main_linux.zig" else "src/main.zig";

    const mod = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    if (opts.objc_mod) |m| mod.addImport("objc", m);

    mod.linkLibrary(opts.ghostty_dep.artifact("ghostty-vt-static"));
    if (opts.link_ghostty_full) {
        // GhosttyLib.initShared doesn't add framework links for darwin —
        // its production path goes through xcframework wrapper which
        // handles frameworks at packaging time. For plain `dep.artifact`
        // consumption we have to add Metal here on the Compile step.
        const full = opts.ghostty_dep.artifact("ghostty");
        if (opts.is_darwin) full.linkFramework("Metal");
        mod.linkLibrary(full);
    }
    mod.addIncludePath(opts.ghostty_dep.path("include"));

    if (opts.is_darwin) {
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
    } else if (opts.is_linux) {
        // libc is the floor for everything that talks D-Bus, dlopen, or
        // pkg-config-discovered libraries. linkSystemLibrary pulls
        // pkg-config metadata (cflags + libs) for the named module.
        mod.link_libc = true;
        // ORDER MATTERS — see linkLayerShellThenGtk's contract. Doing
        // this via a helper instead of two adjacent linkSystemLibrary
        // calls prevents a future refactor from quietly swapping the
        // order: the helper owns both calls + the rationale, and an
        // out-of-helper `linkSystemLibrary("gtk4", ...)` is greppable
        // as a smell.
        linkLayerShellThenGtk(mod);
        // VTE: the terminal widget. djinn's macOS path uses ghostty's
        // embeddable surface API; on Linux that API doesn't exist
        // (ghostty's libghostty exports the surface API only for
        // darwin/iOS — its Linux frontend is a full GtkApplication, not
        // a library). VTE is the standard embeddable terminal on
        // Linux — GNOME Terminal, xfce4-terminal, Tilix all use it.
        // pkg-config name on GTK4 is "vte-2.91-gtk4".
        mod.linkSystemLibrary("vte-2.91-gtk4", .{});
        // glib pieces ride along (g_signal_connect, GMainLoop). gtk4's
        // pkg-config already pulls these via Requires, but listing
        // them explicitly keeps the dep graph readable when something
        // doesn't link.
        mod.linkSystemLibrary("gobject-2.0", .{});
        mod.linkSystemLibrary("glib-2.0", .{});
        // gio-2.0 carries GDBus (g_bus_get_sync, g_dbus_connection_call,
        // signal subscribe). gtk4's pkg-config Requires pulls it in
        // transitively today, but the portal-based hotkey module is the
        // heavy gio consumer and the dependency is load-bearing for it
        // — making the link explicit keeps the dep graph honest if the
        // upstream gtk4 .pc ever drops the transitive Require.
        mod.linkSystemLibrary("gio-2.0", .{});
        // xkbcommon / libnotify / wayland-client get linked once the
        // notifier / wayland-bound modules call into them.
    }

    return mod;
}

/// Link gtk4-layer-shell BEFORE gtk4 — this is a HARD requirement,
/// not an optimization. Layer-shell works by interposing a symbol in
/// libwayland-client; the interposition only takes effect when ld.so
/// loads gtk4-layer-shell BEFORE libwayland (which gtk4 transitively
/// pulls). The linker preserves command-line order in DT_NEEDED, so
/// the `linkSystemLibrary` call order in this function IS the
/// DT_NEEDED order in the final binary.
///
/// Encapsulating both calls in one helper makes the ordering
/// inseparable: a refactor that touches the gtk4 link site (e.g.
/// adding cflags, splitting into nativeBuildInputs) can't reorder
/// the pair, because there is no second call site to reorder relative
/// to. Verified empirically on KDE Wayland — flipping the order
/// reproduces the "Failed to initialize layer surface" warning and
/// the window opens as a plain toplevel.
///
/// libgtk4-layer-shell.so.0 is a hard runtime dep as a consequence.
/// Package availability: Arch `gtk4-layer-shell`, Debian/Ubuntu
/// `libgtk4-layer-shell-0`, nix `gtk4-layer-shell`. On compositors
/// that don't advertise wlr-layer-shell (GNOME), the lib is still
/// installable and `gtk_layer_is_supported()` returns false — the
/// runtime falls through to a plain toplevel.
fn linkLayerShellThenGtk(mod: *std.Build.Module) void {
    mod.linkSystemLibrary("gtk4-layer-shell-0", .{});
    mod.linkSystemLibrary("gtk4", .{});
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
