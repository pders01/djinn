//! Shared GTK / GLib opaque types and convenience aliases.
//!
//! Each `opaque {}` declaration in Zig produces a distinct type, even
//! when two files use the same name. Without a shared declaration,
//! `*GtkWidget` from panel.zig wouldn't be assignable to `*GtkWidget`
//! from terminal.zig — the compiler reports them as different opaque
//! types with the same spelling. This module is the single canonical
//! home so cross-module widget passing just works.
//!
//! Function externs (gtk_window_new, vte_terminal_new, …) stay in
//! their consumer modules — they're per-feature surface and adding
//! everything here would make this file a kitchen sink. Types only.

pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GMainLoop = opaque {};
pub const GMainContext = opaque {};
pub const GObject = opaque {};
pub const VteTerminal = opaque {};
pub const GCancellable = opaque {};

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;
