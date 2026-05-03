/// Single source of truth for djinn's version string. Mirrored into
/// the bundle's `Info.plist` (CFBundleVersion + CFBundleShortVersionString)
/// at build time and reported by the MCP server's `initialize`
/// response. Bump on release; CI tags drive the release pipeline.
///
/// Pre-1.0 follows semver pre-release tags: `0.1.0-alpha.N` while the
/// surface migration cools, then `0.1.0-beta.N` once the design
/// language stops moving.
pub const string = "0.1.0-alpha.1";
