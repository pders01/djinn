# Third-party notices

djinn is MIT-licensed (see `LICENSE`). It links and / or redistributes
the libraries below; their copyright + license terms apply to the
linked artifacts.

## Direct Zig dependencies

### ghostty — `git+https://github.com/ghostty-org/ghostty`

License: **MIT** (Copyright (c) 2024 Mitchell Hashimoto, Ghostty
contributors).

djinn links the full `libghostty.dylib`. The visible terminal area, the terminal
config grammar, the per-action key encoder, the surface search API,
and the bundled libghostty are all ghostty's work. Several djinn
config conventions (the `key = value` file format, `keybind =
<action>=<trigger>` syntax, the `theme = light:X,dark:Y`
appearance-aware split) are lifted from ghostty so users with a
ghostty config can drop in.

The redistributed `libghostty.dylib` carries its own transitive
dependencies (libxev, vaxis, z2d, zig-js, uucode, simdutf, utfcpp,
highway, sentry, harfbuzz, freetype, libpng, oniguruma, wuffs, zlib,
glslang, spirv-cross). Their licenses ship inside the ghostty source
tree under `pkg/<dep>/LICENSE`. djinn does not extract or restate
them here — when distributing the bundled `Djinn.app`, ship the
`libghostty.dylib` license file alongside or point downstream users
at the upstream ghostty repository.

A small darwin-only patch (`patches/ghostty-001-darwin-install.patch`)
is applied to ghostty's `build.zig` to remove an upstream install
guard that hides `dep.artifact("ghostty")` on macOS. The patch is
~10 lines and removes a guard rather than adding logic.

### zig-objc — `git+https://github.com/mitchellh/zig-objc`

License: **MIT** (Copyright (c) 2023 Mitchell Hashimoto).

Provides the `objc.Class` / `objc.Object` / `msgSend` primitives djinn
uses everywhere a Cocoa class is touched (NSPanel, NSStatusItem,
NSTextField, NSCursor, the registered `DjinnTerminalView` /
`DjinnChipCell` / `DjinnDivider` subclasses, …).

## Toolchain

### Zig — <https://ziglang.org>

License: **MIT**. djinn pins `0.15.2` as `minimum_zig_version` and
ships a `flake.nix` exposing `pkgs.zig_0_15` for users without a
compatible host toolchain.

### Apple platform frameworks

`AppKit`, `CoreGraphics`, `CoreFoundation`, `CoreText`, `CoreServices`,
`Carbon`, `Metal`, `QuartzCore`, `ServiceManagement`. Used under
Apple's macOS SDK / Xcode license. Not redistributed; resolved against
the host system at build + run time.

### Apple SF Symbols

The menubar non-idle states (`arrow.triangle.2.circlepath`,
`exclamationmark.triangle.fill`, `checkmark.circle.fill`,
`xmark.octagon.fill`) render Apple's SF Symbols glyphs. Use is
permitted within an app's UI under the SF Symbols license. The
glyphs are not redistributed in the repo or the `.icns`; macOS
resolves them at runtime from the system font.

## Specifications

### Model Context Protocol (MCP) — Anthropic

djinn implements an MCP HTTP server. The protocol is open; no formal
attribution is required, but credit goes to Anthropic for publishing
the spec.

### Quake-drop terminal idiom

The hotkey-driven drop-down terminal pattern is older than this
project (Quake's tilde console, then ports to xterm, Tilda, Yakuake,
Visor, iTerm2's hotkey window, ghostty's own `quick-terminal`,
and dozens of forks). djinn is not the first; the design is shared
prior art.
