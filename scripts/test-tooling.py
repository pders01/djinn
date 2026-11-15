#!/usr/bin/env python3
"""Offline developer-tooling regressions; Python 3 and Bash only.

Uses temporary HOME/bundles and mocked Git/rsync. Never clones, builds packages,
installs an app, launches processes from a bundle, or accesses credentials.
"""
import configparser
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/pders01/djinn"


def contents(path):
    return (ROOT / path).read_text()


def capture(pattern, text):
    match = re.search(pattern, text)
    if not match:
        raise AssertionError(f"Expected metadata pattern: {pattern}")
    return match[1]


def fixture_env(directory, **extra):
    return {
        "PATH": f"{directory / 'bin'}:{os.environ['PATH']}",
        "HOME": str(directory / "home"), "TMPDIR": str(directory), **extra,
    }


class ToolingTests(unittest.TestCase):
    def test_repository_urls(self):
        fields = {
            "contrib/packaging/arch/PKGBUILD": r'^url="([^"]+)"',
            "contrib/packaging/debian/control": r"^Homepage: (.+)",
            "contrib/packaging/debian/copyright": r"^Source: (.+)",
            "contrib/packaging/djinn.service": r"^Documentation=(.+)",
            "flake.nix": r'homepage = "([^"]+)"',
        }
        for path, pattern in fields.items():
            with self.subTest(path=path):
                self.assertEqual(capture("(?m)" + pattern, contents(path)), REPOSITORY)
        self.assertIn('source=("$_pkgname::git+${url}.git")',
                      contents("contrib/packaging/arch/PKGBUILD"))
        self.assertIn(f"[Releases]({REPOSITORY}/releases)", contents("README.md"))
        self.assertIn(f'URL="{REPOSITORY}/releases/download/',
                      contents("scripts/install-from-release.sh"))

    def test_version_metadata(self):
        version = capture(r'pub const string = "([^"]+)"', contents("src/version.zig"))
        for path, pattern in (
            ("build.zig", r'const djinn_version = "([^"]+)"'),
            ("build.zig.zon", r'\.version = "([^"]+)"'),
            ("flake.nix", r'version = "([^"]+)"'),
        ):
            with self.subTest(path=path):
                self.assertEqual(capture(pattern, contents(path)), version)
        arch = capture(r"(?m)^pkgver=(.+)", contents("contrib/packaging/arch/PKGBUILD"))
        self.assertEqual(arch, version.replace("-", "_") + ".r0.0000000")
        debian = capture(r"^djinn \(([^)]+)\)", contents("contrib/packaging/debian/changelog"))
        self.assertEqual(debian, version.replace("-", "~", 1) + "-1")

    def test_terminal_service_policy(self):
        unit = configparser.ConfigParser(interpolation=None)
        unit.read_string(contents("contrib/packaging/djinn.service"))
        # Any new service setting needs an explicit review of its effect on
        # PTY children, not just on the Zig parent. Keep this list narrow.
        allowed = {"type", "execstart", "restart", "restartsec", "killsignal", "timeoutstopsec"}
        self.assertEqual(set(unit["Service"]) - allowed, set())
        self.assertEqual(unit["Service"]["ExecStart"], "/usr/bin/djinn")
        self.assertEqual(unit["Service"]["KillSignal"], "SIGTERM")
        self.assertEqual(unit["Install"]["WantedBy"], "graphical-session.target")
        self.assertIn("dh_installsystemduser --no-enable --no-start",
                      contents("contrib/packaging/debian/rules"))

    def test_debian_install_manifest(self):
        linux = contents("build.zig").split("fn buildLinux(", 1)[1].split("const ModuleOpts", 1)[0]
        files = {"usr/" + destination for destination in
                 re.findall(r'b\.installFile\("[^"]+", "([^"]+)"\)', linux)}
        files.add("usr/bin/djinn")
        self.assertEqual(set(contents("contrib/packaging/debian/djinn.install").splitlines()), files)

    def test_arch_pkgver(self):
        script = r'''
source "$RECIPE"
git() {
    printf '%s\n' "$*" >> "$GIT_LOG"
    case "$1" in
        describe) printf '%s' "$DESCRIPTION"; return "$DESCRIBE_STATUS" ;;
        rev-list) printf '12\n'; return "$COUNT_STATUS" ;;
        rev-parse) printf 'abcdef0\n'; return "$HASH_STATUS" ;;
        *) return 99 ;;
    esac
}
if [[ "$PIPEFAIL" == on ]]; then set -o pipefail; fi
pkgver
'''
        cases = (
            ("stable", "v1.2.3-0-gabcdef0\n", "0", "0", "0", "1.2.3.r0.abcdef0\n"),
            ("alpha", "v0.1.0-alpha.2-0-ge84134a\n", "0", "0", "0", "0.1.0_alpha.2.r0.e84134a\n"),
            ("after-tag", "v1.2.3-beta.1-12-gabcdef0\n", "0", "0", "0", "1.2.3_beta.1.r12.abcdef0\n"),
            ("no-version-tags", "", "128", "0", "0", "r12.abcdef0\n"),
            ("invalid-description", "pre-release-12-gabcdef0\n", "0", "0", "0", "r12.abcdef0\n"),
            ("invalid-version", "vnot-a-version-12-gabcdef0\n", "0", "0", "0", "r12.abcdef0\n"),
            ("count-failure", "", "128", "1", "0", None),
            ("hash-failure", "", "128", "0", "1", None),
        )
        for pipefail in ("off", "on"):
            for name, description, describe_status, count_status, hash_status, expected in cases:
                with self.subTest(case=name, pipefail=pipefail), tempfile.TemporaryDirectory(prefix="djinn-pkgver-test.") as tmp:
                    directory = Path(tmp)
                    (directory / "djinn").mkdir()
                    log = directory / "git-calls"
                    env = fixture_env(directory, RECIPE=str(ROOT / "contrib/packaging/arch/PKGBUILD"),
                                      GIT_LOG=str(log), DESCRIPTION=description, DESCRIBE_STATUS=describe_status,
                                      COUNT_STATUS=count_status, HASH_STATUS=hash_status, PIPEFAIL=pipefail)
                    result = subprocess.run(["bash", "-c", script], cwd=directory, env=env,
                                            capture_output=True, text=True)
                    if expected is None:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, "")
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, expected)
                    self.assertIn("--match v[0-9]*", log.read_text().splitlines()[0])

    def test_local_installer_message(self):
        with tempfile.TemporaryDirectory(prefix="djinn-install-message-test.") as tmp:
            directory = Path(tmp)
            (directory / "bin").mkdir()
            source = directory / "signed candidate.app"
            (source / "Contents").mkdir(parents=True)
            (source / "Contents/Info.plist").write_text("fixture only; never executed")
            log = directory / "rsync-args"
            rsync = directory / "bin/rsync"
            rsync.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RSYNC_LOG"\n')
            rsync.chmod(0o755)
            result = subprocess.run(["bash", str(ROOT / "scripts/install-app.sh"), str(source)],
                                    cwd=directory, env=fixture_env(directory, RSYNC_LOG=str(log)),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("no Accessibility/Input Monitoring grants", result.stdout)
            self.assertNotIn("first launch needs Accessibility", result.stdout)
            self.assertEqual(log.read_text().splitlines(),
                             ["-a", "--delete", f"{source}/", f"{directory / 'home/Applications/Djinn.app'}/"])

    def test_documented_action_availability(self):
        def actions(path, declaration):
            table = contents(path).split(declaration, 1)[1].split("\n};", 1)[0]
            return set(re.findall(r'\.name = "([^"]+)"', table))

        macos = actions("src/terminal/view.zig", "const default_actions =")
        linux = actions("src/platform/linux/keymap.zig", "const actions =")
        documented = contents("README.md").split("### Host action names", 1)[1].split("## Manual acceptance", 1)[0]
        common_text, platform_text = documented.split("macOS-only:", 1)
        macos_text, linux_text = platform_text.split("Linux-only:", 1)
        common = set(re.findall(r"`([a-z_0-9]+)`", common_text))
        if {"tab_1", "tab_9"} <= common:
            common.update(f"tab_{i}" for i in range(1, 10))
        self.assertEqual(common, macos & linux)
        self.assertEqual(set(re.findall(r"`([a-z_0-9]+)`", macos_text)), macos - linux)
        # The final paragraph discusses platform reload behavior, not actions.
        linux_text = linux_text.split("\n\n", 1)[0]
        self.assertEqual(set(re.findall(r"`([a-z_0-9]+)`", linux_text)), linux - macos)


if __name__ == "__main__":
    unittest.main(verbosity=2)
