#!/usr/bin/env python3
"""Offline workflow regressions. Requires Ruby's YAML/JSON stdlib and jq.

Runs only extracted validation/architecture shell blocks with a mocked GitHub
API and temporary fixtures. Never invokes Git, workflows, publication, or apps.
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
assert len(release["jobs"]["build-bundle"]["strategy"]["matrix"]["runner"]) == 2

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
        for runner, arch in (("ARM64", "arm64"), ("X64", "x86_64"), ("unknown", None)):
            output.unlink(missing_ok=True)
            result = run(script, directory, RUNNER_ARCH=runner)
            assert (result.returncode == 0) == (arch is not None)
            if arch:
                assert f"name={arch}\n" in output.read_text()
                installer = (ROOT / "scripts/install-from-release.sh").read_text()
                assert 'ZIP_NAME="Djinn-${TAG}-${ARCH}.zip"' in installer
                assert 'arm64|x86_64)' in installer
            architecture_cases += 1

    # Candidate gate rejects missing/corrupt sets and tags moved during builds.
    assets = directory / "release-assets"
    assets.mkdir()
    (directory / "scripts").mkdir()
    # The fixture gate uses the real, fixture-only installer self-test.
    (directory / "scripts/install-from-release.sh").write_bytes((ROOT / "scripts/install-from-release.sh").read_bytes())
    gate = block("publish", "Verify complete candidate set before any release mutation")
    publisher_cases = 0
    for outcome in ("valid", "missing", "corrupt", "moved"):
        for file in assets.iterdir():
            file.unlink()
        for name in ("Djinn-pre-release-arm64.zip", "Djinn-pre-release-x86_64.zip", "djinn-pre-release-x86_64-linux.tar.gz"):
            data = b"fixture candidate"
            (assets / name).write_bytes(data)
            (assets / (name + ".sha256")).write_text(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
        if outcome == "missing":
            (assets / "Djinn-pre-release-arm64.zip").unlink()
        if outcome == "corrupt":
            (assets / "Djinn-pre-release-arm64.zip").write_bytes(b"wrong")
        result = run(gate, directory, LABEL="pre-release", TAG="v1.2.3", SHA="a" * 40,
                     MOCK_SHA=("b" if outcome == "moved" else "a") * 40)
        assert (result.returncode == 0) == (outcome == "valid"), result.stderr
        publisher_cases += 1

print(f"Workflow checks passed: {shell_blocks} shell blocks, {cases} tag cases, "
      f"{architecture_cases} architecture cases, {publisher_cases} candidate-gate fixtures")
