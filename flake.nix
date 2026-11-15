{
  description = "djinn — Quake-drop terminal for macOS and Linux/Wayland";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      # macOS builds/releases require Apple Silicon; Linux keeps both targets.
      "aarch64-darwin" "x86_64-linux" "aarch64-linux"
    ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        isLinux = pkgs.stdenv.hostPlatform.isLinux;
        zig = pkgs.zig_0_17;
        # Keep the locked Zig 0.17.1 / SDK 26.5 migration. Only Darwin
        # evaluates SDK/tool definitions; Linux uses handwritten C externs.
        sdk = pkgs.apple-sdk_26;
        xcrun = pkgs.writeShellScriptBin "xcrun" ''
          case "$*" in
            "--sdk macosx --show-sdk-path"|"-sdk macosx --show-sdk-path"|"--show-sdk-path")
              printf '%s\n' '${sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
              ;;
            *)
              unset DEVELOPER_DIR SDKROOT
              exec /usr/bin/xcrun "$@"
              ;;
          esac
        '';

        envFixups = ''
          export NIX_CFLAGS_COMPILE=$(echo "''${NIX_CFLAGS_COMPILE:-}" \
            | tr ' ' '\n' | grep -v '^-fmacro-prefix-map=' | tr '\n' ' ')
        '' + lib.optionalString isDarwin ''
          # Do not leak Nix library rpaths into the distributable Mac bundle.
          unset NIX_LDFLAGS DEVELOPER_DIR SDKROOT
          export DJINN_XCRUN_BIN="${xcrun}/bin"
          export PATH="$DJINN_XCRUN_BIN:/usr/bin:$PATH"
        '';

        # Linux's terminal engine is VTE, not libghostty. Ghostty contributes
        # user configuration/theme compatibility only; no Apple tools needed.
        linuxDeps = with pkgs; [
          gtk4 gtk4-layer-shell vte-gtk4 glib
          wayland wayland-protocols libxkbcommon
          pango gdk-pixbuf cairo harfbuzz freetype fontconfig
        ];
        runtimeEnv = lib.optionalString isLinux ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath linuxDeps}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          export XDG_DATA_DIRS="${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
        '';
        runner = name: step: pkgs.writeShellScriptBin name ''
          set -euo pipefail
          export PATH="${lib.makeBinPath [ zig pkgs.pkg-config ]}:$PATH"
          ${envFixups}
          ${runtimeEnv}
          exec ./scripts/build.sh ${step} "$@"
        '';
        app = name: step: {
          type = "app";
          program = "${runner name step}/bin/${name}";
        };
      in {
        # Darwin builds run on the host: Metal compilation needs system Xcode.
        # Signing/installation remain explicit opt-ins, never part of `check`.
        apps = {
          default = app "djinn-run" "run";
          test = app "djinn-test" "test";
          check = app "djinn-check" "check";
        } // lib.optionalAttrs isDarwin {
          bundle = app "djinn-bundle" "bundle-sign";
          install = app "djinn-install" "install-app";
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ zig pkgs.pkg-config pkgs.just ];
          buildInputs = if isLinux then linuxDeps ++ [ pkgs.gsettings-desktop-schemas ] else [ sdk ];
          shellHook = ''
            ${envFixups}
            ${runtimeEnv}
            echo "djinn dev shell — zig $(zig version) on ${system}"
            echo "build: ./scripts/build.sh; validate: just check"
          '';
        };

        # Linux packaging follows the upstream prefix layout. The GTK wrapper
        # supplies runtime schemas, icons and pixbuf loaders. The installed
        # user unit is NOT enabled/started; users may opt in themselves.
        # As upstream, dependency fetching needs network access on a cold Zig
        # cache: this is a local/trusted-user recipe, not a hermetic build.
        packages = lib.optionalAttrs isLinux {
          default = pkgs.stdenv.mkDerivation {
            pname = "djinn";
            version = "0.1.0-alpha.2";
            src = ./.;
            nativeBuildInputs = [ zig pkgs.pkg-config pkgs.wrapGAppsHook4 ];
            buildInputs = linuxDeps ++ [ pkgs.gsettings-desktop-schemas ];
            __noChroot = true;
            dontPatchShebangs = true;
            buildPhase = ''
              runHook preBuild
              ${envFixups}
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              ./scripts/build.sh -Doptimize=ReleaseSafe -Dsystem-install=true --prefix "$out"
              runHook postBuild
            '';
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              ./scripts/build.sh test --color off
              runHook postCheck
            '';
            installPhase = ''
              runHook preInstall
              # systemd does not resolve a profile's PATH. Point the optional
              # unit at the wrapped executable in this exact store output.
              substituteInPlace "$out/lib/systemd/user/djinn.service" \
                --replace-fail 'ExecStart=/usr/bin/djinn' "ExecStart=$out/bin/djinn"
              runHook postInstall
            '';
            meta = {
              description = "Quake-style drop-down terminal (GTK4/VTE, Wayland)";
              homepage = "https://github.com/pders01/djinn";
              license = lib.licenses.mit;
              platforms = lib.platforms.linux;
              mainProgram = "djinn";
            };
          };
        };

        # No Metal or full libghostty linkage in tests. Linux tests link the
        # native GTK/VTE stack but do not launch a GUI. A cold cache still
        # requires fetching the pinned Zig graph, as in the upstream recipe.
        checks.tests = pkgs.stdenv.mkDerivation {
          name = "djinn-tests";
          src = ./.;
          nativeBuildInputs = [ zig pkgs.pkg-config ] ++ lib.optionals isDarwin [ sdk ];
          buildInputs = lib.optionals isLinux linuxDeps;
          __noChroot = true;
          dontPatchShebangs = true;
          buildPhase = ''
            ${envFixups}
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            ./scripts/build.sh check test --color off
            ${lib.optionalString isDarwin "./scripts/build.sh resources --color off"}
            touch $out
          '';
          dontInstall = true;
          dontFixup = true;
        };
      });
}
