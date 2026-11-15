#!/usr/bin/env bash
# Verify a signed bundle without launching the GUI or reading user config.
set -euo pipefail

bundle="${1:-zig-out/Djinn.app}"
bundle="$(cd "$bundle" && pwd -P)"
binary="$bundle/Contents/MacOS/djinn"
library="$bundle/Contents/MacOS/libghostty.dylib"
resources="$bundle/Contents/Resources"

/usr/bin/codesign --verify --deep --strict "$bundle"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$bundle/Contents/Info.plist")

for artifact in "$binary" "$library"; do
    if [[ "$(/usr/bin/lipo -archs "$artifact")" != arm64 ]]; then
        printf 'error: macOS bundles require Apple Silicon (arm64): %s\n' "$artifact" >&2
        exit 1
    fi
    commands=$(/usr/bin/otool -l "$artifact")
    rpaths=$(printf '%s\n' "$commands" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')
    expected=""
    if [[ "$artifact" == "$binary" ]]; then expected='@loader_path'; fi
    if [[ "$rpaths" != "$expected" ]]; then
        printf 'error: unexpected runtime search paths in %s:\n%s\n' "$artifact" "$rpaths" >&2
        exit 1
    fi
    actual_minimum=$(printf '%s\n' "$commands" | awk '$1 == "minos" { print $2 }')
    if [[ "$actual_minimum" != "$minimum" ]]; then
        printf 'error: deployment minimum %s does not match Info.plist %s in %s\n' "$actual_minimum" "$minimum" "$artifact" >&2
        exit 1
    fi
    # The sole non-system shared library must be the copy inside the bundle.
    /usr/bin/otool -L "$artifact" | awk 'NR > 1 { print $1 }' | while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*|@rpath/libghostty.dylib) ;;
            *) printf 'error: external dependency %s in %s\n' "$dependency" "$artifact" >&2; exit 1 ;;
        esac
    done
done
/usr/bin/otool -L "$binary" | grep -q '@rpath/libghostty.dylib'
/usr/bin/infocmp -A "$resources/terminfo" xterm-ghostty >/dev/null
for directory in ghostty/shell-integration/bash ghostty/shell-integration/zsh ghostty/shell-integration/fish ghostty/themes; do
    test -d "$resources/$directory"
done

# Relocate the entire sealed bundle. Use a clean environment and unrelated
# working directory so inherited dyld/resource settings cannot hide mistakes.
temporary=$(mktemp -d "${TMPDIR:-/tmp}/djinn-verify.XXXXXX")
temporary=$(cd "$temporary" && pwd -P)
trap 'rm -rf "$temporary"' EXIT
/usr/bin/ditto "$bundle" "$temporary/Djinn.app"
/usr/bin/codesign --verify --deep --strict "$temporary/Djinn.app"
cd "$temporary"
/usr/bin/env -i PATH=/usr/bin:/bin DYLD_PRINT_LIBRARIES=1 \
    "$temporary/Djinn.app/Contents/MacOS/djinn" --version >version.log 2>&1
if ! grep -F "$temporary/Djinn.app/Contents/MacOS/libghostty.dylib" version.log >/dev/null; then
    printf 'error: relocated executable did not load its own Ghostty library\n' >&2
    exit 1
fi
/usr/bin/env -i PATH=/usr/bin:/bin "$temporary/Djinn.app/Contents/MacOS/djinn" --help >/dev/null 2>&1
printf 'Verified signature, linkage, deployment minimum, resources, and relocated CLI: %s\n' "$bundle"
