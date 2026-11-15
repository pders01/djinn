#!/usr/bin/env bash
# macOS-only release installer. Requires curl, Python 3 (safe ZIP preflight),
# and macOS plist/signature/architecture tools. Never launches/quits the app,
# removes quarantine, registers hotkeys/login items, or changes permissions.
# DJINN_TAG defaults to pre-release; version tags use vMAJOR.MINOR.PATCH[-suffix].
# Ad-hoc signatures verify integrity, NOT publisher identity or notarization.
# Gatekeeper may require explicit approval; this script does not bypass it.
# Run --self-test for temporary-fixture archive and replacement tests only.
# --verify-archive ZIP CHECKSUM ARCH validates a local candidate in tmp, without
# installation, app execution, or network access (used by release CI).
set -euo pipefail

fail() { printf 'djinn installer: %s\n' "$*" >&2; return 1; }

archive_tool() {
    python3 - "$@" <<'PY'
import hashlib
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile

MAX_BYTES = 2 * 1024**3
MAX_ENTRIES = 100000


def extract(archive, checksum, expected_name, destination):
    # Never trust checksum-supplied filenames or run a downloaded command.
    if Path(checksum).stat().st_size > 1024:
        raise ValueError("oversized checksum file")
    text = Path(checksum).read_text(encoding="ascii")
    match = re.fullmatch(r"([a-fA-F0-9]{64})[ \t]+\*?" + re.escape(expected_name) + r"\n?", text)
    if not match:
        raise ValueError("malformed checksum or unexpected checksum filename")
    digest = hashlib.sha256()
    with open(archive, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != match[1].lower():
        raise ValueError("archive checksum mismatch")
    root = Path(destination)
    if root.exists():
        raise ValueError("extraction destination must not exist")
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if not entries or len(entries) > MAX_ENTRIES or sum(e.file_size for e in entries) > MAX_BYTES:
            raise ValueError("empty or oversized archive")
        members = {}
        aliases = set()
        spellings = {}
        links = {}
        for entry in entries:
            name = entry.filename
            path = name[:-1] if name.endswith("/") else name
            parts = path.split("/")
            if (not path or parts[0] != "Djinn.app" or
                    any(p in ("", ".", "..") for p in parts) or
                    any(ord(c) < 32 or ord(c) == 127 for c in name) or
                    "\\" in name or ":" in name or entry.flag_bits & 1):
                raise ValueError("unsafe archive path or encrypted entry")
            alias = unicodedata.normalize("NFD", path).casefold()
            if alias in aliases:
                raise ValueError("duplicate/case-colliding archive path")
            aliases.add(alias)
            # APFS/HFS may be case-insensitive and normalize Unicode. Reject
            # ambiguous ancestor spellings too, not just duplicate leaves.
            for count in range(1, len(parts) + 1):
                prefix = "/".join(parts[:count])
                key = unicodedata.normalize("NFD", prefix).casefold()
                if key in spellings and spellings[key] != prefix:
                    raise ValueError("case/Unicode-colliding archive ancestor")
                spellings[key] = prefix
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise ValueError("unsupported archive entry type")
            if entry.is_dir() != (kind == stat.S_IFDIR) and kind not in (0, stat.S_IFREG):
                raise ValueError("inconsistent archive entry type")
            if path == "Djinn.app" and not entry.is_dir():
                raise ValueError("bundle root must be a directory")
            members[path] = entry
            if kind == stat.S_IFLNK:
                if entry.file_size > 4096:
                    raise ValueError("oversized symlink")
                target = bundle.read(entry).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
                if (not target or target.startswith("/") or "\\" in target or ":" in target or
                        any(ord(c) < 32 or ord(c) == 127 for c in target) or
                        not resolved.startswith("Djinn.app/")):
                    raise ValueError("symlink escapes bundle")
                links[path] = target
        for path in members:
            for parent in PurePosixPath(path).parents:
                key = str(parent)
                if key in members and not members[key].is_dir():
                    raise ValueError("file/symlink used as extraction parent")
        # Extract ourselves: no unzip traversal, special files, or symlink
        # following. Only validated relative symlinks are created, LAST.
        root.mkdir(mode=0o700)
        for path, entry in members.items():
            if path in links:
                continue
            output = root / path
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(entry) as source, output.open("xb") as target:
                    shutil.copyfileobj(source, target, 1024 * 1024)
                # Retain executable bits, never setuid/setgid or writable-to-all.
                output.chmod(0o755 if (entry.external_attr >> 16) & 0o111 else 0o644)
        for path, target in links.items():
            output = root / path
            output.parent.mkdir(parents=True, exist_ok=True)
            output.symlink_to(target)
        app = (root / "Djinn.app").resolve(strict=True)
        for path in links:
            resolved = (root / path).resolve(strict=True)
            if app not in resolved.parents:
                raise ValueError("dangling/cyclic/escaping symlink")
        # Manual safe extraction must not discard download provenance when
        # the input archive carries quarantine. Never remove that attribute.
        if sys.platform == "darwin":
            attributes = subprocess.check_output(["/usr/bin/xattr", str(archive)], text=True).splitlines()
            if "com.apple.quarantine" in attributes:
                quarantine = subprocess.check_output(
                    ["/usr/bin/xattr", "-px", "com.apple.quarantine", str(archive)], text=True).strip()
                subprocess.check_call(["/usr/bin/xattr", "-wx", "com.apple.quarantine", quarantine, str(app)])


def self_test():
    cases = 0
    with tempfile.TemporaryDirectory(prefix="djinn-archive-test.") as temporary:
        root = Path(temporary)
        archive = root / "fixture.zip"
        checksum = root / "fixture.zip.sha256"
        stage = root / "stage"

        def run(entries, valid=False, corrupt=False, checksum_text=None):
            nonlocal cases
            shutil.rmtree(stage, ignore_errors=True)
            with zipfile.ZipFile(archive, "w") as bundle:
                for name, data, mode in entries:
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = mode << 16
                    bundle.writestr(entry, data)
            value = hashlib.sha256(archive.read_bytes()).hexdigest()
            checksum.write_text(checksum_text or f"{value}  fixture.zip\n")
            if corrupt:
                archive.write_bytes(archive.read_bytes() + b"changed")
            try:
                extract(archive, checksum, "fixture.zip", stage)
            except (ValueError, OSError, RuntimeError, zipfile.BadZipFile):
                if valid:
                    raise
            else:
                if not valid:
                    raise AssertionError("unsafe fixture accepted")
            cases += 1

        regular = stat.S_IFREG | 0o755
        symlink = stat.S_IFLNK | 0o777
        good = [("Djinn.app/Contents/MacOS/djinn", b"fixture", regular)]
        run(good, valid=True)
        assert (stage / good[0][0]).read_bytes() == b"fixture"
        run(good + [("Djinn.app/alias", b"Contents/MacOS/djinn", symlink)], valid=True)
        run(good, corrupt=True)
        run(good, checksum_text="not a checksum\n")
        run(good, checksum_text="0" * 64 + "  other.zip\n")
        for path in ("../escape", "/Djinn.app/escape", "Other.app/file", "Djinn.app/../escape",
                     "Djinn.app//file", "Djinn.app/./file", "Djinn.app/evil\\file", "Djinn.app/evil\nfile"):
            run([(path, b"bad", regular)])
        for target in ("../../escape", "/tmp/escape", "missing", "alias"):
            run(good + [("Djinn.app/alias", target.encode(), symlink)])
        run(good + [("Djinn.app/link", b"Contents", symlink), ("Djinn.app/link/file", b"bad", regular)])
        run(good + [("Djinn.app/link", b"Contents", symlink), ("Djinn.app/LINK/file", b"bad", regular)])
        run(good + [("djinn.app/Contents/MacOS/DJINN", b"bad", regular)])
        run(good + [("Djinn.app/fifo", b"", stat.S_IFIFO | 0o600)])
        run([("Djinn.app", b"not a directory", regular)])
        run([])
        global MAX_BYTES
        MAX_BYTES = 1
        run(good)
    print(f"Archive fixtures: {cases} passed (checksum, layout, traversal, links, types, limits)")


try:
    if sys.argv[1:] == ["self-test"]:
        self_test()
    elif len(sys.argv) == 6 and sys.argv[1] == "extract":
        extract(*sys.argv[2:])
    else:
        raise ValueError("invalid archive-tool arguments")
except (ValueError, OSError, RuntimeError, UnicodeError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
    print(f"djinn installer: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

# All three paths are siblings on the destination filesystem. Never copy over
# the installed bundle or delete it before validating the complete candidate.
replace_bundle() {
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -d "$target" && ! -L "$target" ]] || { fail 'destination is not a real app directory'; return 1; }
        mv "$target" "$work/previous.app" || return 1
    fi
    mv "$work/stage/Djinn.app" "$target" || return 1
    committed=1
}

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ -n "$work" && -d "$work" ]]; then
        if [[ "$committed" != 1 && -d "$work/previous.app" ]]; then
            if [[ -e "$target" || -L "$target" ]]; then
                mv "$target" "$work/rejected.app" || status=1
            fi
            if [[ ! -e "$target" && ! -L "$target" ]] && mv "$work/previous.app" "$target"; then
                printf 'Previous installation restored.\n' >&2
            else
                # Never delete the only backup if rollback itself fails.
                printf 'Rollback requires manual recovery from %s/previous.app\n' "$work" >&2
                work=""
                status=1
            fi
        fi
        if [[ -n "$work" ]]; then rm -rf "$work" || status=1; fi
    fi
    if [[ -n "$lock" ]]; then rmdir "$lock" || status=1; fi
    exit "$status"
}

verify_bundle() {
    local app="$1" arch="$2" plist executable library actual
    plist="$app/Contents/Info.plist"
    executable="$app/Contents/MacOS/djinn"
    library="$app/Contents/MacOS/libghostty.dylib"
    for actual in "$app" "$app/Contents" "$app/Contents/MacOS" "$app/Contents/Resources"; do
        [[ -d "$actual" && ! -L "$actual" ]] || { fail 'unsafe bundle directory layout'; return 1; }
    done
    [[ -f "$plist" && ! -L "$plist" && -f "$executable" && ! -L "$executable" && -x "$executable" && -f "$library" && ! -L "$library" ]] || {
        fail 'missing or unsafe bundle metadata/executable/library'; return 1;
    }
    /usr/bin/plutil -lint "$plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == com.pders01.djinn ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" == djinn ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist")" == APPL ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 13.0 ]]
    [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" ]]
    [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" ]]
    for actual in "$executable" "$library"; do
        [[ "$(/usr/bin/lipo -archs "$actual")" == "$arch" ]] || {
            fail "unexpected Mach-O architecture in $actual (expected $arch)"; return 1;
        }
    done
    [[ -d "$app/Contents/Resources/terminfo" ]]
    for actual in bash zsh fish; do
        [[ -d "$app/Contents/Resources/ghostty/shell-integration/$actual" ]]
    done
    [[ -d "$app/Contents/Resources/ghostty/themes" ]]
    /usr/bin/codesign --verify --deep --strict "$app"
}

if [[ "${1:-}" == --self-test ]]; then
    [[ $# -eq 1 ]] || { fail 'unexpected test arguments'; exit 1; }
    archive_tool self-test
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/djinn-replacement-test.XXXXXX")
    trap 'rm -rf "$fixture"' EXIT
    # Real temporary-directory renames; injected command failures never rely
    # on filesystem permissions or touch an installed application.
    for outcome in success failure backup-failure rollback-failure new-install validation-failure interrupted symlink-target; do
        base="$fixture/$outcome"
        mkdir -p "$base/installed.app" "$base/work/stage/Djinn.app"
        printf old > "$base/installed.app/marker"
        printf new > "$base/work/stage/Djinn.app/marker"
        if [[ "$outcome" == new-install ]]; then rm -rf "$base/installed.app"; fi
        if [[ "$outcome" == symlink-target ]]; then
            mv "$base/installed.app" "$base/untouched.app"
            ln -s untouched.app "$base/installed.app"
        fi
        if (
            target="$base/installed.app"
            work="$base/work"
            lock=""
            committed=0
            trap cleanup EXIT
            mv() {
                case "$outcome:$1" in
                    "failure:$work/stage/Djinn.app"|"rollback-failure:$work/stage/Djinn.app"|\
                    "rollback-failure:$work/previous.app"|"backup-failure:$target") return 1 ;;
                esac
                command mv "$@"
            }
            if [[ "$outcome" == validation-failure ]]; then exit 1; fi
            if [[ "$outcome" == interrupted ]]; then mv "$target" "$work/previous.app"; exit 143; fi
            replace_bundle || exit 1
        ); then
            [[ "$outcome" == success || "$outcome" == new-install ]]
        else
            [[ "$outcome" != success && "$outcome" != new-install ]]
        fi
        if [[ "$outcome" == rollback-failure ]]; then
            # Recovery must retain the only backup, even though ordinary
            # success/failure paths clean every staging artifact.
            [[ ! -e "$base/installed.app" ]]
            [[ "$(<"$base/work/previous.app/marker")" == old ]]
            continue
        fi
        expected=old
        if [[ "$outcome" == success || "$outcome" == new-install ]]; then expected=new; fi
        [[ "$(<"$base/installed.app/marker")" == "$expected" ]]
        [[ ! -e "$base/work" ]]
        if [[ "$outcome" == symlink-target ]]; then [[ -L "$base/installed.app" ]]; fi
    done
    printf 'Replacement fixtures: 8 passed (replace, new install, validation/rename failures, interruption, symlink refusal, rollback/recovery cleanup)\n'
    exit 0
fi

if [[ "${1:-}" == --verify-archive ]]; then
    [[ $# -eq 4 && ( "$4" == arm64 || "$4" == x86_64 ) ]] || {
        fail 'usage: --verify-archive ZIP CHECKSUM arm64|x86_64'; exit 1;
    }
    [[ "$(uname -s)" == Darwin ]] || { fail 'bundle verification requires macOS'; exit 1; }
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/djinn-candidate-verify.XXXXXX")
    trap 'rm -rf "$temporary"' EXIT
    archive_tool extract "$2" "$3" "$(basename "$2")" "$temporary/stage"
    verify_bundle "$temporary/stage/Djinn.app" "$4"
    printf 'Verified staged archive, metadata, architecture and signature: %s\n' "$2"
    exit 0
fi

[[ $# -eq 0 ]] || { fail 'usage: install-from-release.sh [--self-test | --verify-archive ZIP CHECKSUM ARCH]'; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { fail 'installer supports macOS only (Djinn also supports Linux)'; exit 1; }
command -v python3 >/dev/null || { fail 'Python 3 is required for safe archive validation'; exit 1; }
TAG="${DJINN_TAG-pre-release}"
[[ "$TAG" == pre-release || "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] || {
    fail 'invalid or empty DJINN_TAG'; exit 1;
}
ARCH=$(uname -m)
case "$ARCH" in arm64|x86_64) ;; *) fail "unsupported architecture: $ARCH"; exit 1 ;; esac
ZIP_NAME="Djinn-${TAG}-${ARCH}.zip"
URL="https://github.com/pders01/djinn/releases/download/${TAG}/${ZIP_NAME}"
DEST="$HOME/Applications"
target="$DEST/Djinn.app"
work=""
lock=""
committed=0
umask 077
mkdir -p "$DEST"
[[ -d "$DEST" && ! -L "$DEST" ]] || { fail 'Applications must be a real directory'; exit 1; }
# Cooperative installer lock; never inspect/terminate sessions or steal a lock.
if ! mkdir "$DEST/.djinn-install.lock"; then
    fail 'another installation or stale lock exists; inspect it manually'; exit 1
fi
lock="$DEST/.djinn-install.lock"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "$DEST/.djinn-install.XXXXXX")
printf 'Downloading %s\n' "$URL"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 30 --max-time 600 --max-filesize 2147483648 --show-error --output "$work/$ZIP_NAME" "$URL"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 30 --max-time 60 --max-filesize 1024 --show-error --output "$work/$ZIP_NAME.sha256" "$URL.sha256"
archive_tool extract "$work/$ZIP_NAME" "$work/$ZIP_NAME.sha256" "$ZIP_NAME" "$work/stage"
verify_bundle "$work/stage/Djinn.app" "$ARCH"
replace_bundle
printf '\nInstalled at %s\nNo app was launched, quit, or signalled. Relaunch manually when ready.\nAd-hoc signing is not Developer ID/notarization; Gatekeeper approval may be required.\nQuarantine is never removed. Global hotkeys need no Accessibility/Input Monitoring grants.\n' "$target"
