#!/usr/bin/env python3
"""Pin updater seam: release/update-pins.py against recorded upstream responses.

    python3 tests/update-pins.py

Runs the script's main() on copies of the pin files in tests/update-pins/before/,
with the HTTP fetch and the `docker buildx imagetools` runner replaced by the
recordings in tests/update-pins/, so it needs no network and no Docker.

The recordings are real responses from the VS Code update API, the Marketplace,
the GitHub release API and `imagetools inspect`, trimmed to the fields and
versions the script reads. One version is made up: exiasr.hadolint 1.3.0, whose
engine range (^1.148.0) accepts the recorded VS Code but not the pinned one.
"""
import importlib.util
import io
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REC = ROOT / "tests/update-pins"
PINS = {"vscode.env": "image/packages/vscode.env",
        "vscode-extensions.txt": "image/packages/vscode-extensions.txt",
        "Dockerfile": "image/Dockerfile"}

sys.dont_write_bytecode = True   # no release/__pycache__ left in the checkout
spec = importlib.util.spec_from_file_location("update_pins", ROOT / "release/update-pins.py")
update_pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update_pins)


class Upstream:
    """The recorded upstream: answers each request from tests/update-pins/."""

    def __init__(self, failing=()):
        self.failing = failing
        self.requests = []

    def fetch(self, url, body=None):
        self.requests.append(url)
        if any(f in url or (body and f in body.decode()) for f in self.failing):
            raise OSError("HTTP Error 403: rate limit exceeded")
        if m := re.search(r"update\.code\.visualstudio\.com/api/update/server-linux-x64/stable/latest$", url):
            return self.recording("vscode/server-linux-x64.json")
        if m := re.search(r"update\.code\.visualstudio\.com/api/versions/commit:\w+/([\w-]+)/stable$", url):
            return self.recording(f"vscode/{m[1]}.json")
        if "marketplace.visualstudio.com/_apis/public/gallery/extensionquery" in url:
            name = json.loads(body)["filters"][0]["criteria"][0]["value"]
            return self.recording(f"marketplace/{name}.json")
        if m := re.search(r"api\.github\.com/repos/[^/]+/([^/]+)/releases\?per_page=\d+&page=(\d+)$", url):
            return self.recording(f"github/{m[1]}.json") if m[2] == "1" else []
        raise AssertionError(f"no recording for {url}")

    def imagetools(self, ref):
        self.requests.append(ref)
        if any(f in ref for f in self.failing):
            raise RuntimeError(f"ERROR: {ref}: not found")
        p = REC / "imagetools" / (ref.rsplit("/", 1)[-1].replace(":", "_") + ".txt")
        if not p.exists():
            raise RuntimeError(f"ERROR: {ref}: not found")
        return p.read_text(encoding="utf-8")

    @staticmethod
    def recording(rel):
        return json.loads((REC / rel).read_text(encoding="utf-8"))


class PinUpdater(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.place(REC / "before")

    def place(self, src):
        for name, rel in PINS.items():
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src / name, self.root / rel)

    def pin(self, name):
        return (self.root / PINS[name]).read_bytes()

    def run_script(self, *groups, upstream=None, buildx=True):
        self.upstream = upstream or Upstream()
        out, err = io.StringIO(), io.StringIO()
        code = update_pins.main(list(groups), root=self.root, fetch=self.upstream.fetch,
                                imagetools=self.upstream.imagetools, buildx=lambda: buildx, out=out, err=err)
        return code, out.getvalue(), err.getvalue()

    def test_every_pin_file_is_rewritten_from_the_recordings(self):
        code, out, err = self.run_script()
        self.assertEqual(code, 0, err)
        for name in PINS:
            self.assertEqual(self.pin(name).decode(), (REC / "after" / name).read_text(encoding="utf-8"), name)

    def test_a_major_version_jump_is_flagged(self):
        code, out, err = self.run_script()
        self.assertEqual(code, 0, err)
        lines = {line.split()[0]: line for line in out.splitlines() if " -> " in line}
        self.assertIn("[major version]", lines["redhat.vscode-yaml"])
        self.assertIn("[major version]", lines["BREW_IMAGE"])
        self.assertNotIn("[major version]", lines["gitlab.gitlab-workflow"])
        self.assertNotIn("[major version]", lines["DHI_BASE"])
        self.assertNotIn("HADOLINT_IMAGE", lines, "an unchanged pin is not listed")

    def test_when_nothing_upstream_changed_every_file_is_left_byte_for_byte(self):
        self.place(REC / "after")
        for rel in PINS.values():   # CRLF and no final newline must survive too
            p = self.root / rel
            p.write_bytes(p.read_bytes().replace(b"\n", b"\r\n").rstrip(b"\r\n"))
        before = {name: self.pin(name) for name in PINS}
        code, out, err = self.run_script()
        self.assertEqual(code, 0, err)
        self.assertEqual({name: self.pin(name) for name in PINS}, before)
        self.assertIn("nothing changed", out)

    def test_one_group_changes_only_its_own_pins(self):
        before = {name: self.pin(name) for name in PINS}
        code, out, err = self.run_script("tflint")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.pin("vscode.env"), before["vscode.env"])
        self.assertEqual(self.pin("vscode-extensions.txt"), before["vscode-extensions.txt"])
        want = before["Dockerfile"].decode() \
            .replace("ARG TFLINT_VERSION=0.64.0", "ARG TFLINT_VERSION=0.66.0") \
            .replace("ARG TFLINT_SHA256=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537",
                     "ARG TFLINT_SHA256=22be11cadc25cd02401e94c0ccc91aa63467debb8485c2a755d98f4c0a9d1e2e")
        self.assertEqual(self.pin("Dockerfile").decode(), want)
        self.assertEqual([r for r in self.upstream.requests if "tflint" not in r], [], "looked up another group")

    def test_extensions_alone_are_chosen_for_the_pinned_vs_code(self):
        code, out, err = self.run_script("extensions")
        self.assertEqual(code, 0, err)
        pins = self.pin("vscode-extensions.txt").decode()
        # 1.3.0 needs VS Code ^1.148.0; the pinned VS Code is 1.147.0.
        self.assertIn("exiasr.hadolint@1.2.0\n", pins)
        self.assertIn("gitlab.gitlab-workflow@7.7.1\n", pins)
        self.assertEqual(self.pin("vscode.env"), (REC / "before/vscode.env").read_bytes())

    def test_pre_releases_are_skipped(self):
        code, out, err = self.run_script("vscode", "extensions")
        self.assertEqual(code, 0, err)
        self.assertIn("VSCODE_REMOTE_SSH_VERSION=0.128.0\n", self.pin("vscode.env").decode())   # not 0.129.x
        pins = self.pin("vscode-extensions.txt").decode()
        self.assertIn("ms-vscode.powershell@2025.4.0\n", pins)   # not 2026.1.2
        self.assertIn("redhat.vscode-yaml@2.0.0\n", pins)       # not 2.1.x

    def test_a_failed_lookup_writes_nothing_and_names_the_pin(self):
        for failing, pin in (("PowerShell", "PWSH_VERSION"), ("redhat.ansible", "redhat.ansible"),
                             ("dhi.io", "DHI_BASE")):
            with self.subTest(pin=pin):
                before = {name: self.pin(name) for name in PINS}
                code, out, err = self.run_script(upstream=Upstream(failing=[failing]))
                self.assertEqual(code, 1)
                self.assertIn(pin, err)
                self.assertEqual({name: self.pin(name) for name in PINS}, before)

    def test_a_release_without_an_asset_digest_writes_nothing(self):
        class NoDigest(Upstream):
            def fetch(self, url, body=None):
                got = super().fetch(url, body)
                if "/codex/" in url:
                    for release in got:
                        for asset in release["assets"]:
                            asset["digest"] = None
                return got
        code, out, err = self.run_script("codex", "tflint", upstream=NoDigest())
        self.assertEqual(code, 1)
        self.assertIn("CODEX_SHA256", err)
        self.assertEqual(self.pin("Dockerfile"), (REC / "before/Dockerfile").read_bytes())

    def test_missing_buildx_stops_an_image_group_before_any_lookup(self):
        code, out, err = self.run_script("codex", "brew", buildx=False)
        self.assertEqual(code, 1)
        self.assertIn("brew", err)
        self.assertIn("docker buildx", err)
        self.assertEqual(self.upstream.requests, [])
        code, out, err = self.run_script("codex", buildx=False)
        self.assertEqual(code, 0, err)

    def test_the_repository_pin_files_are_in_the_form_the_script_rewrites(self):
        # Every group but extensions, whose recordings cover only the fixture's list.
        for rel in PINS.values():
            shutil.copyfile(ROOT / rel, self.root / rel)
        code, out, err = self.run_script(*[g for g in update_pins.GROUPS if g != "extensions"])
        self.assertEqual(code, 0, err)
        env = self.pin("vscode.env").decode()
        self.assertIn("VSCODE_COMMIT=661626d0e72f97806550790a98fb87116c9db825\n", env)
        self.assertIn("VSCODE_REMOTE_SSH_VERSION=0.128.0\n", env)
        self.assertIn("ARG CODEX_VERSION=0.172.0\n", self.pin("Dockerfile").decode())


if __name__ == "__main__":
    sys.exit(not unittest.main(verbosity=2, exit=False).result.wasSuccessful())
