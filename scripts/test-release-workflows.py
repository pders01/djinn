#!/usr/bin/env python3
"""Offline workflow regressions. Requires Ruby's YAML/JSON stdlib and jq.

Runs extracted validation/architecture/asset-retirement shell blocks with a
mocked GitHub CLI and temporary fixtures, plus installer architecture refusals.
Never invokes Git, workflows, real publication, installation, or apps.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FILES = [ROOT / ".github/workflows" / f"{name}.yml" for name in ("ci", "pre-release", "release")]
workflows = json.loads(subprocess.check_output([
    "ruby", "-e", 'require "yaml"; require "json"; puts JSON.generate(ARGV.map { |f| YAML.load_file(f) })',
    *map(str, FILES),
], text=True))
ci, rolling, release = workflows


def block(job, name):
    return next(s["run"] for s in release["jobs"][job]["steps"] if s["name"] == name)


def run(script, directory, **overrides):
    env = {
        "PATH": f"{directory / 'bin'}:{os.environ['PATH']}",
        "HOME": str(directory), "TMPDIR": str(directory),
        "GITHUB_OUTPUT": str(directory / "output"),
        "GITHUB_REPOSITORY": "fixture/djinn", "GH_REPO": "fixture/djinn",
        "GITHUB_EVENT_NAME": "workflow_dispatch", "REQUESTED_TAG": "v1.2.3",
        "ROLLING": "false", "MOCK_KIND": "lightweight", "MOCK_SHA": "a" * 40,
    }
    env.update(overrides)
    return subprocess.run(["bash", "-euo", "pipefail", "-c", script], cwd=directory,
                          env=env, capture_output=True, text=True)


# YAML shape, dependency gates and architecture spelling are part of the contract.
assert "push" not in rolling.get("on", rolling.get("true", {}))
assert rolling["jobs"]["release"]["with"]["rolling"] is True
assert release["jobs"]["publish"]["needs"] == ["resolve", "build-bundle", "build-linux"]
assert release["jobs"]["publish"]["concurrency"] == {
    "group": "djinn-release-publisher", "cancel-in-progress": False,
}
for job in ("build-bundle", "build-linux"):
    checkout = release["jobs"][job]["steps"][0]
    assert checkout["with"]["ref"] == "${{ needs.resolve.outputs.sha }}"
assert "gh release delete" not in block("publish", "Publish complete validated set")
for workflow, job in ((ci, "bundle"), (release, "build-bundle")):
    assert workflow["jobs"][job]["runs-on"] == "macos-15"
    assert "strategy" not in workflow["jobs"][job]
    steps = workflow["jobs"][job]["steps"]
    architecture_index = next(i for i, s in enumerate(steps) if s.get("id") == "architecture")
    nix_index = next(i for i, s in enumerate(steps) if s.get("name") == "Install Nix")
    assert architecture_index < nix_index
assert ci["jobs"]["test"]["runs-on"] == "macos-15"
assert ci["jobs"]["linux"]["runs-on"] == "ubuntu-24.04"
assert release["jobs"]["build-linux"]["runs-on"] == "ubuntu-24.04"
publisher_steps = release["jobs"]["publish"]["steps"]
publish_index = next(i for i, s in enumerate(publisher_steps) if s["name"] == "Publish complete validated set")
retire_index = next(i for i, s in enumerate(publisher_steps) if s["name"] == "Retire legacy Intel rolling assets after successful publication")
assert retire_index > publish_index
assert publisher_steps[retire_index].get("if", "success()") == "success()"

shell_blocks = 0
for workflow in workflows:
    for job in workflow["jobs"].values():
        for step in job.get("steps", []):
            if "run" in step:
                subprocess.run(["bash", "-n"], input=step["run"], text=True, check=True)
                shell_blocks += 1

with tempfile.TemporaryDirectory(prefix="djinn-workflow-test.") as tmp:
    directory = Path(tmp)
    (directory / "bin").mkdir()
    gh = directory / "bin/gh"
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open("api-calls", "a") as log: log.write(" ".join(sys.argv[1:]) + "\\n")
kind = os.environ["MOCK_KIND"]
sha = os.environ["MOCK_SHA"]
endpoint = sys.argv[2] if len(sys.argv) > 2 else ""
if kind.startswith("retire"):
    if sys.argv[1:4] == ["release", "view", "pre-release"]:
        if kind == "retire-view-failure": raise SystemExit(1)
        print(os.environ["MOCK_ASSETS"])
    elif sys.argv[1:4] == ["release", "delete-asset", "pre-release"]:
        allowed = [f"Djinn-pre-release-{arch}{suffix}" for arch in ("x86_64", "X64") for suffix in (".zip", ".zip.sha256")]
        if sys.argv[4] not in allowed or sys.argv[5:] != ["--yes"]: raise SystemExit("unexpected deletion")
        if kind == "retire-delete-failure": raise SystemExit(1)
    else: raise SystemExit("unexpected retirement command")
    raise SystemExit(0)
if sys.argv[1] != "api": raise SystemExit("mutation forbidden")
if kind == "missing": raise SystemExit(1)
if "/git/ref/tags/" in endpoint:
    obj = {"type": "tag" if kind in ("annotated", "cycle") else "tree" if kind == "tree" else "commit", "sha": "b" * 40 if kind in ("annotated", "cycle") else sha}
    print(json.dumps({"object": obj}))
elif "/git/tags/" in endpoint:
    print(json.dumps({"object": {"type": "tag" if kind == "cycle" else "commit", "sha": sha}}))
elif "/commits/" in endpoint and "--jq" in sys.argv:
    print(sha)
elif "/git/commits/" in endpoint:
    print("{}")
else: raise SystemExit("unexpected endpoint")
''')
    gh.chmod(0o755)
    resolve = block("resolve", "Validate and resolve existing version tag")
    cases = 0
    for tag in ("v0.1.0-alpha.1", "v1.2.3"):
        for kind in ("lightweight", "annotated"):
            output = directory / "output"
            output.unlink(missing_ok=True)
            result = run(resolve, directory, REQUESTED_TAG=tag, MOCK_KIND=kind)
            assert result.returncode == 0, result.stderr
            assert f"sha={'a' * 40}\n" in output.read_text()
            assert f"tag={tag}\n" in output.read_text()
            cases += 1
    for tag in ("", "main", "a" * 40, "v1", "v1.2.3/evil", "v1.2.3;echo bad", "pre-release"):
        assert run(resolve, directory, REQUESTED_TAG=tag).returncode != 0
        cases += 1
    for kind in ("missing", "tree", "cycle"):
        assert run(resolve, directory, MOCK_KIND=kind).returncode != 0
        cases += 1
    assert run(resolve, directory, MOCK_SHA="invalid").returncode != 0
    cases += 1
    output = directory / "output"
    output.unlink(missing_ok=True)
    assert run(resolve, directory, ROLLING="true").returncode == 0
    assert "label=pre-release\n" in output.read_text()
    cases += 1
    assert run(resolve, directory, GITHUB_EVENT_NAME="push", GITHUB_REF="refs/tags/v2.3.4").returncode == 0
    cases += 1
    output.unlink(missing_ok=True)
    assert run(resolve, directory, GITHUB_SHA="d" * 40, GITHUB_REF="refs/heads/main").returncode == 0
    assert f"sha={'a' * 40}\n" in output.read_text()  # old tag, not dispatch branch tip
    cases += 1

    architecture_cases = 0
    for workflow in (ci, release):
        name = "bundle" if workflow is ci else "build-bundle"
        script = next(s["run"] for s in workflow["jobs"][name]["steps"] if s.get("id") == "architecture")
        for runner, arch in (("ARM64", "arm64"), ("X64", None), ("unknown", None)):
            output.unlink(missing_ok=True)
            result = run(script, directory, RUNNER_ARCH=runner)
            assert (result.returncode == 0) == (arch is not None)
            if arch:
                assert f"name={arch}\n" in output.read_text()
                installer = (ROOT / "scripts/install-from-release.sh").read_text()
                assert 'ZIP_NAME="Djinn-${TAG}-${ARCH}.zip"' in installer
                assert 'require_arm64 "$ARCH"' in installer
            else:
                assert not output.exists()
            architecture_cases += 1

    # Mock only OS/architecture probes; no download, staging or installed app
    # may be touched on an unsupported host or for an unsupported archive.
    uname = directory / "bin/uname"
    uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo "$MOCK_ARCH" ;; *) exit 1 ;; esac\n')
    uname.chmod(0o755)
    curl = directory / "bin/curl"
    curl.write_text('#!/bin/sh\ntouch unexpected-network\nexit 1\n')
    curl.chmod(0o755)
    installer_architecture_cases = 0
    for host, args, message in (
        ("x86_64", "", "Intel/x86_64 macOS is no longer supported"),
        ("unknown", "", "unsupported macOS architecture"),
        ("arm64", "--verify-archive fixture.zip fixture.sha256 x86_64", "Intel/x86_64 macOS is no longer supported"),
        ("x86_64", "--verify-archive fixture.zip fixture.sha256 arm64", "Intel/x86_64 macOS is no longer supported"),
    ):
        result = run(f'bash "$INSTALLER" {args}', directory, MOCK_ARCH=host,
                     INSTALLER=str(ROOT / "scripts/install-from-release.sh"))
        assert result.returncode != 0 and message in result.stderr, result.stderr
        assert not (directory / "Applications").exists()
        assert not (directory / "unexpected-network").exists()
        assert not list(directory.glob("djinn-candidate-verify.*"))
        installer_architecture_cases += 1
    uname.unlink()
    curl.unlink()

    # Candidate gate rejects missing/corrupt/extra sets and moved tags.
    assets = directory / "release-assets"
    assets.mkdir()
    (directory / "scripts").mkdir()
    # The fixture gate uses the real, fixture-only installer self-test.
    (directory / "scripts/install-from-release.sh").write_bytes((ROOT / "scripts/install-from-release.sh").read_bytes())
    gate = block("publish", "Verify complete candidate set before any release mutation")
    publisher_cases = 0
    for outcome in ("valid", "missing-macos", "missing-linux", "missing-checksum", "corrupt", "moved", "extra-intel"):
        for file in assets.iterdir():
            file.unlink()
        for name in ("Djinn-pre-release-arm64.zip", "djinn-pre-release-x86_64-linux.tar.gz"):
            data = b"fixture candidate"
            (assets / name).write_bytes(data)
            (assets / (name + ".sha256")).write_text(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
        if outcome == "missing-macos":
            (assets / "Djinn-pre-release-arm64.zip").unlink()
        if outcome == "missing-linux":
            (assets / "djinn-pre-release-x86_64-linux.tar.gz").unlink()
        if outcome == "missing-checksum":
            (assets / "Djinn-pre-release-arm64.zip.sha256").unlink()
        if outcome == "extra-intel":
            (assets / "Djinn-pre-release-x86_64.zip").write_bytes(b"unexpected Intel candidate")
        if outcome == "corrupt":
            (assets / "Djinn-pre-release-arm64.zip").write_bytes(b"wrong")
        result = run(gate, directory, LABEL="pre-release", TAG="v1.2.3", SHA="a" * 40,
                     MOCK_SHA=("b" if outcome == "moved" else "a") * 40)
        assert (result.returncode == 0) == (outcome == "valid"), result.stderr
        publisher_cases += 1

    # Retirement is deliberately narrow and only runs after successful publish.
    # Versioned releases do not even query assets. All commands use the mock gh.
    retire = block("publish", "Retire legacy Intel rolling assets after successful publication")
    retirement_cases = 0
    preserved = ["Djinn-pre-release-arm64.zip", "Djinn-pre-release-arm64.zip.sha256",
                 "djinn-pre-release-x86_64-linux.tar.gz", "install.sh", "unrelated.zip"]
    normalized = [f"Djinn-pre-release-x86_64{suffix}" for suffix in (".zip", ".zip.sha256")]
    legacy = [f"Djinn-pre-release-X64{suffix}" for suffix in (".zip", ".zip.sha256")]
    for outcome, intel, expected in (
        ("none", [], []), ("normalized", normalized, normalized),
        ("legacy", normalized + legacy, normalized + legacy),
        ("versioned", normalized, []), ("wrong-label", normalized, []),
        ("view-failure", normalized, []), ("delete-failure", normalized, normalized[:1]),
    ):
        (directory / "api-calls").unlink(missing_ok=True)
        result = run(retire, directory, MOCK_KIND=(f"retire-{outcome}"),
                     MOCK_ASSETS="\n".join(preserved + intel),
                     ROLLING="false" if outcome == "versioned" else "true",
                     LABEL="v1.2.3" if outcome in ("versioned", "wrong-label") else "pre-release")
        assert (result.returncode == 0) == (outcome not in ("wrong-label", "view-failure", "delete-failure")), result.stderr
        calls = (directory / "api-calls").read_text().splitlines() if (directory / "api-calls").exists() else []
        if outcome in ("versioned", "wrong-label"):
            assert calls == []
        deletions = [line.split()[3] for line in calls if line.startswith("release delete-asset ")]
        assert deletions == expected, calls
        retirement_cases += 1

print(f"Workflow checks passed: {shell_blocks} shell blocks, {cases} tag cases, "
      f"{architecture_cases} architecture cases, {installer_architecture_cases} installer refusals, "
      f"{publisher_cases} candidate-gate fixtures, {retirement_cases} rolling-retirement fixtures")
