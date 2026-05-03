{
  description = "djinn — Quake-drop terminal + MCP agent surface for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # macOS only. djinn links AppKit + Metal + ghostty's libghostty.dylib;
    # ghostty's renderer compiles `.metal` shaders via xcrun → metal at
    # build time. The Metal Toolchain ships through Apple's cryptex
    # mechanism (mounted under `/var/run/com.apple.security.cryptexd/...`
    # at runtime by `cryptexd`), which the nix sandbox can't reach even
    # with `__noChroot = true`. So djinn's release artifact (the signed
    # Djinn.app bundle) HAS to be built on the host with system Xcode +
    # the Metal Toolchain installed; the flake exposes runners that
    # delegate to the existing build.sh script.
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = pkgs.zig_0_15;

        # Strip the nix CFLAGS that zig 0.15's clang frontend warns on +
        # unset the apple-sdk env vars that steer xcrun at the wrong
        # SDK. Both are required for ghostty's `.metal` shader compile
        # to find the system Metal Toolchain. Re-used by devShell + the
        # test check below.
        envFixups = ''
          # `:-` keeps the helper safe under `set -u` when invoked
          # outside the nix-build / dev-shell envelope (e.g. from
          # `nix run .#test` against a host shell).
          export NIX_CFLAGS_COMPILE=$(echo "''${NIX_CFLAGS_COMPILE:-}" \
            | tr ' ' '\n' \
            | grep -v '^-fmacro-prefix-map=' \
            | tr '\n' ' ')
          unset DEVELOPER_DIR SDKROOT
          export PATH="/usr/bin:$PATH"
        '';

        # Wrap a `zig build <step>` invocation with the right env so it
        # works the same whether invoked from the dev shell or from
        # `nix run`. Builds happen on the HOST (cwd = the user's
        # checkout), not in the nix store — Metal Toolchain access
        # demands it.
        runner = name: step: pkgs.writeShellScriptBin name ''
          set -euo pipefail
          ${envFixups}
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
        apps = {
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
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig_0_15
            pkg-config
          ];

          shellHook = ''
            ${envFixups}
            echo "djinn dev shell — zig $(zig version)"
            echo "build with: ./scripts/build.sh   (applies ghostty patch + zig build)"
            echo "or:         just build / just test / just install-app"
          '';
        };

        # `nix flake check` runs the unit suite. Tests link only
        # `ghostty-vt-static` (no full libghostty, no Metal compile),
        # so this DOES build hermetically inside the nix sandbox.
        checks.tests = pkgs.stdenv.mkDerivation {
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
      });
}
