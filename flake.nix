{
  description = "djinn — Quake-drop terminal + MCP agent surface (macOS + Linux/Wayland)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # Two host families:
    #   - darwin (aarch64 + x86_64): NSPanel + AppKit + Metal, ghostty's
    #     `.metal` shader compile demands the system Metal Toolchain
    #     (mounted via Apple's cryptex mechanism, unreachable from the
    #     nix sandbox), so darwin builds happen on the host against the
    #     user's checkout. Apps below delegate to build.sh.
    #   - linux (x86_64 + aarch64): GTK4 borderless window + gtk4-layer-shell
    #     for Quake-drop on KDE/Hyprland/sway/wlroots-likes. GNOME falls
    #     back to a plain toplevel (layer-shell unsupported). Linux dev
    #     shell pulls gtk4 + gtk4-layer-shell + wayland + xkbcommon via
    #     pkg-config; ghostty's GTK apprt provides the terminal surface.
    flake-utils.lib.eachSystem [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = pkgs.zig_0_15;
        isDarwin = pkgs.stdenv.isDarwin;
        isLinux = pkgs.stdenv.isLinux;

        # Strip the nix CFLAGS that zig 0.15's clang frontend warns on +
        # (darwin) unset the apple-sdk env vars that steer xcrun at the
        # wrong SDK. Both are required for ghostty's `.metal` shader
        # compile to find the system Metal Toolchain. On linux the SDK
        # unsetting is a no-op but harmless; we keep one helper so the
        # shellHook + apps below stay platform-agnostic.
        envFixups = ''
          # `:-` keeps the helper safe under `set -u` when invoked
          # outside the nix-build / dev-shell envelope (e.g. from
          # `nix run .#test` against a host shell).
          export NIX_CFLAGS_COMPILE=$(echo "''${NIX_CFLAGS_COMPILE:-}" \
            | tr ' ' '\n' \
            | grep -v '^-fmacro-prefix-map=' \
            | tr '\n' ' ')
        '' + (if isDarwin then ''
          unset DEVELOPER_DIR SDKROOT
          export PATH="/usr/bin:$PATH"
        '' else "");

        # Linux runtime + build deps. gtk4 / gtk4-layer-shell are
        # discovered via pkg-config; wayland + libxkbcommon ride along
        # because the host shell talks to them directly (text-input,
        # cursor-shape, layer-shell client negotiation). VTE is the
        # terminal widget — see the comment in build.zig for why we
        # chose VTE over rolling our own renderer on Linux.
        linuxDeps = with pkgs; [
          gtk4
          gtk4-layer-shell
          vte-gtk4
          wayland
          wayland-protocols
          libxkbcommon
          libnotify
          glib
          # Typography stack that gtk4 / vte pull transitively. Listing
          # them explicitly keeps the dep graph readable and ensures
          # they're present in LD_LIBRARY_PATH for runtime dlopen.
          pango
          gdk-pixbuf
          cairo
          harfbuzz
          freetype
          fontconfig
        ];

        # Wrap a `zig build <step>` invocation with the right env so it
        # works the same whether invoked from the dev shell or from
        # `nix run`. Builds happen on the HOST (cwd = the user's
        # checkout), not in the nix store — Metal Toolchain access
        # demands it. On linux the runner also exports
        # LD_LIBRARY_PATH against linuxDeps so the freshly-built
        # binary dlopens libgtk-4.so.1 + libgtk4-layer-shell.so.0 from
        # the nix store (the dev shell sets the same export; without
        # it `nix run .#` would link fine then fail at first dlopen
        # because NixOS doesn't seed system libs into the default
        # loader path).
        runner = name: step: pkgs.writeShellScriptBin name ''
          set -euo pipefail
          ${envFixups}
          ${if isLinux then ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath linuxDeps}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '' else ""}
          # Pre-fetch ghostty + apply the darwin install patch (idempotent).
          ${zig}/bin/zig build --fetch >/dev/null 2>&1 || true
          ./scripts/apply-ghostty-patch.sh
          exec ${zig}/bin/zig build ${step} "$@"
        '';
      in
      {
        # `nix run .#` -> build + launch djinn (non-bundle dev exe).
        # `nix run .#bundle` -> build the signed Djinn.app under zig-out.
        # `nix run .#install` -> build + sign + rsync to ~/Applications.
        # `nix run .#test` -> run the unit suite.
        # All run on the host, against the user's checkout. Use the
        # devShell (`nix develop`) for ad-hoc work.
        # On linux only `default` and `test` are wired today — bundle /
        # install are darwin .app concepts and don't translate.
        apps = if isDarwin then {
          default = {
            type = "app";
            program = "${runner "djinn-run" "run"}/bin/djinn-run";
          };
          bundle = {
            type = "app";
            program = "${runner "djinn-bundle" "bundle-sign"}/bin/djinn-bundle";
          };
          install = {
            type = "app";
            program = "${runner "djinn-install" "install-app"}/bin/djinn-install";
          };
          test = {
            type = "app";
            program = "${runner "djinn-test" "test"}/bin/djinn-test";
          };
        } else {
          default = {
            type = "app";
            program = "${runner "djinn-run" "run"}/bin/djinn-run";
          };
          test = {
            type = "app";
            program = "${runner "djinn-test" "test"}/bin/djinn-test";
          };
        };

        devShells.default = pkgs.mkShell {
          # buildInputs vs nativeBuildInputs: keep buildInputs so
          # pkg-config sets PKG_CONFIG_PATH for the gtk4 / layer-shell
          # discovery in build.zig. zig's clang frontend reads
          # PKG_CONFIG_PATH transparently.
          nativeBuildInputs = with pkgs; [
            pkg-config
            zig_0_15
          ];
          buildInputs = if isLinux then linuxDeps else [ ];

          shellHook = ''
            ${envFixups}
            echo "djinn dev shell — zig $(zig version) on ${system}"
            ${if isDarwin then ''
              echo "build with: ./scripts/build.sh   (applies ghostty patch + zig build)"
              echo "or:         just build / just test / just install-app"
            '' else ''
              # nix mkShell sets PKG_CONFIG_PATH (link-time discovery) but
              # doesn't set LD_LIBRARY_PATH. The host shell dlopens
              # libgtk-4.so.1 + libgtk4-layer-shell.so.0 at runtime, so
              # without this export djinn would link fine and fail at
              # first dlopen with ENOENT. Use lib.makeLibraryPath so the
              # path tracks our linuxDeps set instead of being hand-listed.
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath linuxDeps}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              echo "build with: zig build           (linux WIP)"
              echo "ghostty patch will apply on first build via scripts/apply-ghostty-patch.sh"
            ''}
          '';
        };

        # `nix build .#default` on linux produces a fully-installable
        # djinn package: binary at $out/bin/djinn + .desktop entry at
        # $out/share/applications/djinn.desktop. wrapGAppsHook4 wraps
        # the binary with the GTK runtime env (XDG_DATA_DIRS,
        # GSETTINGS_SCHEMA_DIR, GDK_PIXBUF_MODULE_FILE) so GTK can
        # find its icon themes / settings schemas / pixbuf loaders
        # from the nix store rather than relying on host directories.
        # `__noChroot = true` because zig fetches ghostty + other
        # build.zig.zon deps from the network on first build — same
        # constraint the darwin checks branch sits under. That makes
        # the derivation non-cacheable on Hydra but fine for personal
        # `nix build` / `nix profile install` flows. Gotcha: nix
        # silently ignores `__noChroot` unless the invoking user is
        # in `trusted-users` (see `/etc/nix/nix.conf`) — without that
        # the build aborts on "has '__noChroot' set, but that's not
        # allowed when 'sandbox' is 'true'".
        packages = if isLinux then {
          default = pkgs.stdenv.mkDerivation {
            pname = "djinn";
            version = "0.1.0-alpha.1";
            src = ./.;

            nativeBuildInputs = with pkgs; [
              zig_0_15
              pkg-config
              wrapGAppsHook4
            ];
            # glib is a runtime library (GLib main loop, GIO, GObject)
            # that djinn dlopens via gtk4 + gdbus paths — it belongs in
            # buildInputs alongside the rest of linuxDeps, not in
            # nativeBuildInputs (which is for tools that run during the
            # build itself).
            buildInputs = linuxDeps;

            __noChroot = true;
            dontPatchShebangs = true;
            # wrapGAppsHook4 default behavior wraps $out/bin/djinn to
            # seed XDG_DATA_DIRS, GSETTINGS_SCHEMA_DIR, and
            # GDK_PIXBUF_MODULE_FILE from the nix store before the
            # binary runs. djinn isn't a GApplication subclass but
            # GTK itself still consults those envs at init for icon
            # themes + gsettings backends, so the wrap stays on (no
            # `dontWrapGApps = true;` here).

            buildPhase = ''
              runHook preBuild
              ${envFixups}
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              zig build --fetch >/dev/null 2>&1 || true
              ./scripts/apply-ghostty-patch.sh
              # -Dsystem-install lands .desktop + systemd user unit +
              # LICENSE + README under $out/share/. wrapGAppsHook4
              # rewrites $out/bin/djinn at fixup so the wrapped binary
              # picks up the GTK runtime env from the nix store.
              zig build -Doptimize=ReleaseSafe -Dsystem-install=true \
                --prefix "$out"
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              # zig build's --prefix already populates $out/bin and
              # $out/share/applications via the install steps in
              # build.zig. Nothing left to do but let wrapGAppsHook4
              # rewrite $out/bin/djinn with the GTK env at fixup.
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Drop-down terminal panel + MCP agent surface (Wayland)";
              homepage = "https://github.com/derscheid/djinn";
              license = licenses.mit;
              platforms = platforms.linux;
              mainProgram = "djinn";
            };
          };
        } else { };

        # `nix flake check` runs the unit suite. Tests link only
        # `ghostty-vt-static` (no full libghostty, no Metal compile),
        # so this DOES build hermetically inside the nix sandbox.
        # Linux is gated off until the build.zig refactor lands (test
        # build path still has AppKit framework links right now).
        checks = if isDarwin then {
          tests = pkgs.stdenv.mkDerivation {
            name = "djinn-tests";
            src = ./.;
            nativeBuildInputs = [ zig ];
            # ghostty's zig deps fetch over the network on first build —
            # __noChroot grants the sandboxed builder network access.
            # The Metal Toolchain isn't needed for the test path.
            __noChroot = true;
            dontPatchShebangs = true;

            buildPhase = ''
              ${envFixups}
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              zig build --fetch >/dev/null 2>&1 || true
              ./scripts/apply-ghostty-patch.sh
              zig build test --color off
              touch $out
            '';

            dontInstall = true;
            dontFixup = true;
          };
        } else { };
      });
}
