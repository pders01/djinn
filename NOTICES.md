# Third-party notices

djinn is MIT-licensed (see `LICENSE`). It links and / or redistributes
the libraries below; their copyright + license terms apply to the
linked artifacts.

## Direct Zig dependencies

### ghostty — `git+https://github.com/ghostty-org/ghostty`

Pinned release: **1.4.0**; see `build.zig.zon` for the exact revision/hash.
License: **MIT** (Copyright (c) 2024 Mitchell Hashimoto, Ghostty
contributors).

On macOS, djinn links the full `libghostty.dylib`. The visible terminal area, the terminal
config grammar, the per-action key encoder, the surface search API,
and the bundled libghostty are all ghostty's work. Several djinn
config conventions (the `key = value` file format, `keybind =
<action>=<trigger>` syntax, the `theme = light:X,dark:Y`
appearance-aware split) are lifted from ghostty so users with a
ghostty config can drop in.

The redistributed `libghostty.dylib` includes transitive dependencies.
The pinned Ghostty manifest, build graph, source tree, and extracted dependency
packages identify their versions and license texts. This document is not a
complete transitive-license inventory. Before public distribution, audit the
actual linked code and bundled resources and include all required copyright
and license notices; repository links alone do not replace those obligations.

A small Darwin-only patch (`patches/ghostty-001-darwin-install.patch`)
registers the full shared renderer artifact in Ghostty's `build.zig`, making
`dep.artifact("ghostty")` available on macOS. It is applied only to this
checkout's extracted dependency, not a shared source cache.

### zig-objc — `git+https://github.com/mitchellh/zig-objc`

License: **MIT** (Copyright (c) 2023 Mitchell Hashimoto).

Provides the `objc.Class` / `objc.Object` / `msgSend` primitives djinn
uses everywhere a Cocoa class is touched (NSPanel, NSStatusItem,
NSTextField, NSCursor, the registered `DjinnTerminalView` /
`DjinnTabStrip` subclasses, …).

## Toolchain

### Zig — <https://ziglang.org>

License: **MIT**. djinn pins `0.17.1` as `minimum_zig_version` and
ships a `flake.nix` exposing `pkgs.zig_0_17` for users without a
compatible host toolchain.

### Apple platform frameworks

`AppKit`, `CoreGraphics`, `CoreFoundation`, `CoreText`, `CoreServices`,
`Carbon`, `Metal`, `QuartzCore`, `ServiceManagement`. Used under
Apple's macOS SDK / Xcode license. Not redistributed; resolved against
the host system at build + run time.

### Linux platform libraries

The Linux backend uses **GTK4**, **VTE (GTK4)**, **gtk4-layer-shell**, and
**GLib/GObject/GIO**, with their native dependencies such as Pango/Cairo.
These are system-linked libraries under their respective upstream licenses,
not the Ghostty renderer or Apple frameworks. Consult the exact versions'
license texts and distribution metadata when packaging. The transitive
notice/license audit remains required before public distribution.

## Specifications

### Quake-drop terminal idiom

The hotkey-driven drop-down terminal pattern is older than this
project (Quake's tilde console, then ports to xterm, Tilda, Yakuake,
Visor, iTerm2's hotkey window, ghostty's own `quick-terminal`,
and dozens of forks). djinn is not the first; the design is shared
prior art.
