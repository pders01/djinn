# Render architecture assessment

State of the render pipeline as of this session, with the friction
points that made the last several debugging passes feel like
whack-a-mole. Goal: name the structural issues so the next round of
fixes targets them instead of symptoms.

## Modules

```
main.zig
 ├── window/panel.zig        NSPanel quake-drop chrome
 ├── terminal/view.zig       NSView class. drawRect, tick, all input
 │   │                       handlers, IME, font + CGGlyph caches.
 │   │                       2670 lines — overgrown.
 │   ├── terminal/terminal.zig  libghostty wrapper
 │   ├── terminal/pty.zig       forkpty
 │   └── terminal/tis.zig       IME fast-path layout cache
 ├── render/atlas.zig        Glyph atlas. BGRA8Unorm, 3× horizontal
 │                           oversample → [1,2,1]/4 LCD downsample.
 ├── render/metal.zig        MTLDevice + pipeline state from inline MSL.
 │                           Per-frame indexed draw + present.
 ├── render/scene.zig        Owns Atlas + Renderer. buildFrame walker.
 ├── hotkey/darwin.zig       CGEventTap
 ├── notify/{menubar,darwin}.zig
 ├── system/loginitem.zig
 ├── theme/, mcp/, agent/, io/, state/
 └── app.zig                 AppState — single global `g` for objc
                             C-callbacks that can't capture.
```

## Lifecycle

### Boot (CG mode)

```
main()
  ├ Config.load
  ├ TerminalView.init           ─ buildFont, prewarmGlyphs, NSTrackingArea,
  │                               find-overlay NSTextField subview, register
  │                               class methods (drawRect, tick, mouseMoved...)
  ├ tis.install
  ├ LogView.init
  ├ buildContainer + setContentView
  ├ Pty.spawn                   ─ forkpty + exec shell
  ├ Terminal.initWithScrollback ─ libghostty
  ├ view.attach(term, pty)      ─ startTickTimer (60Hz), watchPtyRead
  ├ Hotkey.init                 ─ CGEventTap install
  ├ McpServer.init + thread.spawn
  ├ dispatch_async_f            ─ deferred login-item + FSEvent setup
  └ NSApp.run                   ─ AppKit run loop
```

### Boot (Metal mode, after view.attach)

```
  if config.render.backend == "metal":
    Scene.init                    ─ Atlas.init, Renderer.init,
    Renderer.attach(view, 1.0)    ─ setLayer:CAMetalLayer
    app.g.scene = @ptrCast(&scene)
```

### Tick

```
NSTimer 60Hz → tickImpl
  ├ checkResize           if grid cols/rows changed
  ├ if app.g.scene && app.g.scene_dirty:
  │    renderMetalFrame   query view bounds + scale
  │      → scene.render   walk grid + push quads
  │          → Atlas.getOrRasterizeOpaque (per glyph cache miss)
  │          → Renderer.uploadAtlasIfDirty
  │          → Renderer.render  encode + present
  ├ cursor blink
  ├ bell flash expiry
  └ agent state poll
```

## State stores

| Where | What | Triggered by |
|---|---|---|
| `app.g.scene_dirty` | bool, scene-wide | every `setNeedsDisplay:` site (29× via awk insertion) + invalidateDirtyRows + toggleCursorBlink |
| `term` (libghostty internal) | per-row dirty flags | `feedOutput`, `scrollViewport` |
| AppKit's `setNeedsDisplay` | rect union per view | mouse, keyboard, scroll, theme reload, bell, etc. |
| `app.g.viewport_pinned_to_bottom` | bool | scroll wheel, keyboard, font resize, view resize, Cmd+K |
| Atlas dirty rect | `(x, y, w, h)` rect | every `Atlas.rasterize` |

## Threading

- Main thread: AppKit run loop, all view rendering, all input, PTY drain (kqueue dispatch_source_t on main queue), scene render.
- MCP HTTP worker thread: writes to `agent_state` + posts `Notifier`. Notifier dispatches to main via `dispatch_async_f`.
- Background dispatch_async (post-launch): login-item sync + FSEventStream setup.

## Friction / structural smells

### 1. Two parallel render trigger surfaces, awk-glued together

The CG path uses AppKit's `setNeedsDisplay:` to schedule a drawRect.
The Metal path uses `app.g.scene_dirty` polled by tick.

Currently every `setNeedsDisplay:` call is paired with an
`app.g.scene_dirty = true` insertion done by `awk`. 29 sites.
`setNeedsDisplayInRect:` was missed by the original regex; got
patched manually. Future invalidation site without this dual flip
will silently fail in Metal mode.

**Better shape**: one `requestRedraw(view)` helper. CG mode → calls
setNeedsDisplay. Metal mode → flips scene_dirty. Both modes →
both. All 29 sites flow through it. No more awk maintenance.

### 2. `app.g.scene` as `?*anyopaque`

Three call sites cast through `@ptrCast(@alignCast(...))` to
`*Scene`. Workaround for an import cycle:
`Scene → app.zig` (reads terminal/font/etc), `app.zig → Scene`
(would need to type the field).

**Better shape**: keep the opaque pointer in `app.g` but expose a
`scene_mod.fromAppState() ?*Scene` helper that does the cast
once. Or drop `app.g.scene` entirely — the view has a `scene`
field, callbacks reach the view, view exposes a getter.

### 3. View module is the universal glue

`src/terminal/view.zig` is 2670 lines and does:
- NSView class registration (drawRect, mouseMoved, mouseDragged,
  scrollWheel, keyDown, etc.)
- Font resolution + CGGlyph cache + atlas-cache-invalidation cross-call
- NSTextInputClient (IME) — 11 methods
- Find-overlay NSTextField + delegate
- drawRect with all overlays
- Tick timer + scene render trigger
- Selection + hyperlink hover + scroll viewport

Every Metal change touches this file. Every CG change touches this
file. They share state via `app.g`. Single editor for two
backends + an input subsystem + a font subsystem.

**Better shape**: extract input handling, IME, font/cache, find
overlay, scrollback into siblings. View becomes the NSView class
+ the dispatch table for messages. Each subsystem owns its state
without `app.g` indirection where possible.

### 4. Pixel-grid invariants implicit, not enforced

Atlas math, scene quad placement, vertex shader NDC mapping, and
CAMetalLayer drawableSize all hold pixel-grid invariants in
parallel. Each fix this session ("floor origin", "integer
bearings", "drawableSize sync") was a different layer of the same
invariant: **integer pixels everywhere from atlas slot to viewport
fragment**.

When one layer drifts, the rest break visually:
- atlas raster at fractional → glyph 0.5px misaligned
- bearing fractional → quad position 0.5px off
- baseline_y fractional → row misaligned
- drawableSize ≠ bounds × scale → viewport scaling wrong
- contentsScale wrong → drawable mismatched

**Better shape**: single function `pixelGrid(view) -> { bounds, scale,
drawable, viewport_uniform }` returns all derived sizes. Atlas
unit tests + scene tests assert integer outputs. One source of
truth.

### 5. resize paths cross-cut three modules

Resize originates from AppKit's bounds change. Goes through:
- `view.checkResize` → `term.resize`, `pty.resize`,
  `scene.resize` (drawableSize), `scene_dirty`
- `view.viewDidChangeBackingProperties` → `syncLayerScale`
  (separate path, also touches contentsScale)
- font resize (Cmd+/-) → `applyFontSize` → BMP cache wipe + atlas
  invalidate + grid resize

Three different "size changed" entry points. Metal mode adds a
fourth (post-attach drawableSize sync). One can fire while another
is mid-flight (mouse-drag during font resize).

**Better shape**: `view.notifyResize(reason)` single funnel.
Reason discriminates which sub-fixups to run. Fewer accidental
"forgot to update X on Y resize" bugs.

### 6. CGContext path still loaded even when Metal active

drawRect still registered as a class method even when Metal is the
active backend. CAMetalLayer skips drawRect, but every
`setNeedsDisplay:` call still does the AppKit invalidation
walk + queues a useless drawRect that never fires. Wasted CPU per
invalidation event.

**Better shape**: `setHidden:YES` on the view's CG-side rendering,
or drop drawRect from the class entirely once Metal is up. Or:
the awk-inserted scene_dirty path replaces setNeedsDisplay
entirely in Metal mode (option 1's helper).

### 7. No render diagnostic for Metal path

CG path has the `render: layer.contentsScale=...` one-shot diag at
first drawRect. Metal path has no such hook. When something looks
wrong (black screen, garbled, wrong size), there's no automated
log to consult — every debug pass adds + removes scaffolding.

**Better shape**: `--debug-render` flag that emits one structured
log line per rendered frame for the first N frames, capturing
view bounds, drawable size, contentsScale, viewport uniform sent
to GPU, atlas cache size, dirty rect, quad count. Cheap to keep
in always; gated behind flag avoids prod log spam.

### 8. Atlas + CGGlyph caches both invalidated, only one is used

`applyFontSize` wipes:
- `g_ascii_glyph_cache_built = false` (CG path's CGGlyph IDs)
- `g_bmp_glyph_cache` (CG path's BMP cache)
- `Scene.invalidateGlyphCache` (atlas)

CG mode never uses the atlas. Metal mode never uses the BMP
cache. Both wiped regardless. Wasteful but harmless.

**Better shape**: gate on active backend. Or: drop the unused
side once Metal stabilizes.

### 9. Scene.render walks entire grid every frame regardless of dirty rows

`scene_dirty` is binary — set by ANY invalidation event. When set,
scene walks all 117×46 cells, pushes ~50-5000 quads, uploads atlas
delta, encodes draw. Per cursor blink (every 530ms), per
keystroke, per mouse drag step.

CG path has per-row dirty-rect skip in drawRect — only re-paints
changed rows. Metal path doesn't. Equivalent feature would
require: per-row quad caching + invalidation only on dirty rows.

**Better shape**: defer. Current 5000-cell walk is sub-ms in
ReleaseFast on Apple Silicon. Optimization candidate, not a
correctness issue.

### 10. Build artifacts double when bundle pinned

`zig build install-app` builds against ReleaseFast modules; raw
`zig build` against -Doptimize. Both share most module compilation
graph but the `bundle_exe_mod` is a separate `b.createModule` call
with a separate ghostty dep at ReleaseFast. Build cache holds two
copies of every dep's artifact.

Cost: ~30 MB extra disk + first-install longer. Acceptable.

**Better shape**: factor module setup into a build helper fn that
takes optimize as param. Removes duplicated framework links + dep
import lines.

## Where the current "garbled black" bug maps

The visible output: mostly black, top-left has tiny text fragments
(~1/8th of the canvas).

Symptom shape suggests `viewport_size` in vertex shader < drawable
size. Glyphs at correct point coords + small viewport_size = NDC
[-1, 1] maps to small fraction of drawable → glyphs render to top-
left quadrant only.

Most likely cause: `Renderer.attach` set drawableSize to
`bounds × scale` once at boot. View bounds at that moment may
have been pre-layout (the panel hadn't been shown yet → small
bounds), so drawable was set to a small size. Subsequent layout
grew the view but drawableSize stayed at first-pass value. Each
render writes vertex_buffer at current bounds ≠ drawable.

**Test**: launch djinn, hotkey, screenshot. If garbled stays at
the SAME size regardless of panel size → drawableSize stuck.

**Fix**: set drawableSize on every `viewDidEndLiveResize` AND
once on first show (after panel slides in). Don't put it in
attach (called when view bounds may not be final yet).

This maps directly to friction #5 — multiple resize entry points,
none of them know about the post-attach panel-show event that
finalizes view bounds.

## Recommended next moves

In priority order:

1. **Stand up the "render trigger" abstraction** (#1). One
   `requestRedraw` helper, replace 29 awk sites + the missed
   ones. Removes the entire class of "forgot to flip the flag"
   bugs.
2. **Hook view's frame-changed notification** (#5). One funnel
   for resize that covers panel-show, drag-resize, theme reload,
   font resize. Fixes the "garbled black" bug above.
3. **Add `--debug-render` instrumented frame log** (#7). Stops
   the next debug pass from re-scaffolding diag code.
4. **Extract IME and find-overlay from view.zig** (#3). View
   shrinks ~600 lines, easier to reason about.
5. **Type `app.g.scene`** via a getter helper (#2). Three sites
   stop casting; future Scene API additions don't ripple.
6. **Defer #4, #6, #8, #9, #10** until the above three lower the
   debugging cost of touching this code.

The first three together turn "another visual bug → 3 hours of
trial-and-error" into "another visual bug → diff the debug log,
fix the funnel that's wrong." That's the cost-of-change reduction
the symptoms have been telling us we need.
