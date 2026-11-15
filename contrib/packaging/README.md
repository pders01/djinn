# Linux packaging

Linux uses **GTK4 + VTE**, with gtk4-layer-shell for supported Wayland
compositors and GLib/GObject/GIO for the event loop and desktop integration.
It does **not** link libghostty or ghostty-vt-static. Ghostty compatibility on
Linux means configuration and themes, not the macOS Metal renderer.

## Build and validate

Use exactly **Zig 0.17.1**, as supplied by the locked Nix dev shell:

```sh
nix develop
./scripts/build.sh check
./scripts/build.sh test
./scripts/build.sh -Doptimize=ReleaseSafe
./zig-out/bin/djinn --version
```

`check` analyzes the complete Linux entry point without linking or consulting
pkg-config. On macOS it can be cross-checked without installing Linux libraries:

```sh
nix develop --command ./scripts/build.sh check -Dtarget=x86_64-linux-gnu
```

Actual Linux builds and tests require pkg-config metadata for
`gtk4-layer-shell-0`, `gtk4`, `vte-2.91-gtk4`, `gobject-2.0`, `glib-2.0`, and
`gio-2.0`. Keep layer-shell before GTK in the link order. Tests do not require a
graphical session; building/testing is not a validation of Wayland interactions.
Ubuntu 24.04 does not supply gtk4-layer-shell: the workflows build tag `v1.3.0`
from source. Debian packaging needs a corresponding local development package.

## Package layouts

- `zig build install -Dsystem-install=true --prefix STAGING/usr` stages the
  executable, desktop entry, optional systemd **user** unit, license, README,
  third-party notices, and these packaging notes. Without that flag, a dev
  install only installs the executable.
- `nix build .#default` on Linux creates a GTK-wrapped package, substituting
  the exact output executable path in the optional user unit. The current
  upstream-style Nix derivation needs a trusted local builder/network access
  for a cold Zig dependency cache; it is not an offline/Hydra recipe.
- `arch/PKGBUILD` requires a package providing `zig=0.17.1`. If unavailable in
  the distribution, provide that compiler package locally; do not substitute
  an incompatible Zig version. Build with `makepkg`, including its check phase.
  Source uses `pders01/djinn`; versions derive only from `v*` version tags,
  excluding the moving `pre-release` tag. A checkout without a usable version
  tag falls back to its total commit count and short hash.
- For local Debian builds, copy `debian/` into the checkout's top level and run
  `ZIG=/path/to/zig-0.17.1/zig dpkg-buildpackage -us -uc`. The recipe fetches
  pinned dependency archives and is not intended for offline Debian buildds.
- Release tarballs retain the `djinn-<tag>-x86_64-linux/` directory, checksum,
  and license/notices files. They depend on the host's GTK4/VTE/layer-shell
  runtime libraries; they are not statically linked or universal bundles.

## Optional launch integration

No package enables a service or starts djinn automatically. Launch it from the
desktop entry or CLI first. To opt into the packaged graphical-session user
unit on a system with a suitable session manager:

```sh
systemctl --user daemon-reload
systemctl --user enable --now djinn.service
# Opt out later:
systemctl --user disable --now djinn.service
```

The unit needs the graphical session's Wayland/D-Bus environment. Do not enable
it alongside another desktop-autostart entry for djinn. Manual `/usr/local`
installs and relocated tarballs must adjust `ExecStart` to their actual binary
path before installing a user-local unit. Nix substitutes its store path at
build time. No additional background application service is required.

The unit deliberately adds no process sandbox: restrictions also apply to PTY
children. For example, `NoNewPrivileges` prevents sudo/setuid elevation and
`MemoryDenyWriteExecute` can break JIT programs. Scope any desired workload
confinement to that workload's explicit launcher rather than the terminal.
User/system-wide policies still apply. Native service and package acceptance
(including ordinary privileged/JIT commands) remains required.

macOS builds/releases are Apple Silicon (arm64) only; Intel Macs are no longer
supported. They still use the full Ghostty 1.4.0 Metal renderer, macOS 13
deployment minimum, SDK 26.5, and a bundle-local `@loader_path` library. Linux
x86_64 releases and x86_64/aarch64 compile checks are unchanged. The macOS bundle,
explicit signing/install targets, runtime resources, and bundle verifier are
separate from Linux packaging.
