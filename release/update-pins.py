#!/usr/bin/env python3
"""Refresh the Standard Image's exact pins from upstream.

    python3 release/update-pins.py [group...]

Name groups (listed at the end of --help) to refresh only those; none means
all. The Release Owner runs it at the start of a Release on the Connected
Side's Linux Docker host, in a clone at the Release branch. It looks up the
newest version of each selected pin, then rewrites image/packages/vscode.env,
image/packages/vscode-extensions.txt, image/Dockerfile and the images of the
pipeline's linter jobs in .gitlab-ci.yml, leaving the change in the working
tree as a diff to review. It builds, commits and pushes nothing.

Every checksum comes from its publisher: the VS Code update API, and the
`digest` the GitHub release API gives each release asset. Image digests come
from `docker buildx imagetools inspect`, which uses the host's `docker login`;
only the dhi, brew, hadolint and shellcheck groups need it, and dhi needs a login to dhi.io,
checked before any lookup. Every lookup happens before any write, so a failed
one writes nothing. `GITHUB_TOKEN` is sent to the GitHub API when set.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent
VSCODE_ENV = "image/packages/vscode.env"
EXTENSIONS = "image/packages/vscode-extensions.txt"
DOCKERFILE = "image/Dockerfile"
PIPELINE = ".gitlab-ci.yml"


class Image(NamedTuple):
    arg: str | None    # its `ARG <arg>=` in the Dockerfile; None for an image only the pipeline runs
    repo: str | None   # the GitHub project whose newest release names the tag; None keeps the tag
    job: str | None    # the pipeline job that runs the same image (tests/ci.py checks they match)


# Image pins. DHI_BASE keeps its tag and takes the tag's current digest.
IMAGES = {"dhi": Image("DHI_BASE", None, None), "brew": Image("BREW_IMAGE", "Homebrew/brew", None),
          "hadolint": Image("HADOLINT_IMAGE", "hadolint/hadolint", "hadolint"),
          "shellcheck": Image(None, "koalaman/shellcheck", "shellcheck")}
# Downloaded tools: where each comes from is read from the Dockerfile's
# `ADD --checksum=sha256:${<GROUP>_SHA256} <release asset URL>`.
TOOLS = ("codex", "tflint", "pwsh")
GROUPS = ("vscode", "extensions", *IMAGES, *TOOLS)
DHI_REGISTRY = "dhi.io"

UPDATE_API = "https://update.code.visualstudio.com/api"
MARKETPLACE = "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"
GITHUB_API = "https://api.github.com/repos"
REMOTE_SSH = "ms-vscode-remote.remote-ssh"
REMOTE_SSH_PIN = "VSCODE_REMOTE_SSH_VERSION"
# The platforms a VSIX may target and still install where it goes: the extensions on
# the image's VS Code server, Remote-SSH on the Workstation's portable VS Code.
SERVER_TARGETS = (None, "universal", "linux-x64")
WORKSTATION_TARGETS = (None, "universal", "win32-x64")
PAGE = 30   # a Codex release has ~200 assets; bigger pages time out
PAGES = 5
IMAGE_REF = re.compile(r"(.+):([^:@/]+)@sha256:[0-9a-f]{64}")


class LookupFailed(Exception):
    def __init__(self, pin, reason):
        super().__init__(f"{pin}: {reason}")


class PinFileError(Exception):
    """A pin file is not in the form the script rewrites."""


class Change(NamedTuple):
    file: str   # VSCODE_ENV, EXTENSIONS, DOCKERFILE or PIPELINE
    pin: str    # in PIPELINE, the job
    old: str | None
    new: str

    @property
    def changed(self):
        return self.old != self.new


@contextmanager
def naming(pin):
    """Name `pin` in any failure of its lookup: a network error, a rate limit, an unexpected response."""
    try:
        yield
    except LookupFailed:
        raise
    except Exception as e:
        raise LookupFailed(pin, f"{type(e).__name__}: {e}") from None


# ------------------------------------------------------------------ upstream
def http_json(url, body=None):
    """GET (or POST `body`) a URL and parse its JSON."""
    headers = {"User-Agent": "devc-update-pins"}
    if url.startswith(MARKETPLACE):
        headers |= {"Content-Type": "application/json", "Accept": "application/json;api-version=3.0-preview.1"}
    if url.startswith(GITHUB_API):
        headers["Accept"] = "application/vnd.github+json"
        if os.environ.get("GITHUB_TOKEN"):
            headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=60) as r:
        return json.load(r)


def docker_imagetools(ref):
    """`docker buildx imagetools inspect` output for an image reference."""
    r = subprocess.run(["docker", "buildx", "imagetools", "inspect", ref], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError((r.stderr or r.stdout).strip() or f"exit {r.returncode}")
    return r.stdout


def has_buildx():
    if not shutil.which("docker"):
        return False
    return subprocess.run(["docker", "buildx", "version"], capture_output=True).returncode == 0


def docker_config_path():
    return Path(os.environ.get("DOCKER_CONFIG") or Path.home() / ".docker") / "config.json"


def logged_in(config, registry):
    """Whether the Docker config holds credentials for `registry`: an `auths` entry (which
    `docker login` writes even when a `credsStore` keeps the secret) or a `credHelpers` one."""
    try:
        conf = json.loads(Path(config).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    hosts = [*conf.get("auths", {}), *conf.get("credHelpers", {})]
    return any(re.sub(r"^\w+://|/.*$", "", h) == registry for h in hosts)


# ------------------------------------------------------------------ versions
def version_key(v):
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", v)
    return tuple(map(int, m.groups())) if m else (-1,)


def engine_accepts(engine, vscode):
    """Whether a Marketplace `engines.vscode` range admits a VS Code version, by VS Code's own
    rule (src/vs/platform/extensions/common/extensionValidator.ts): `*`, or an optional `^` or
    `>=` before major.minor.patch, each part a number or `x`. A bare version is exact; `^`
    frees the parts after the major (after the minor for 0.x), and 0.x ranges admit 1.x.
    VS Code refuses any other form, or none, so such a version is never taken. A `-<date>`
    suffix, which VS Code checks against its build date, is ignored."""
    engine = (engine or "").strip()
    if engine == "*":
        return True
    m = re.fullmatch(r"(\^|>=)?(\d+|x)\.(\d+|x)\.(\d+|x)(?:-.*)?", engine)
    if not m:
        return False
    parts = m.groups()[1:]
    want = [0 if p == "x" else int(p) for p in parts]
    exact = [p != "x" for p in parts]   # whether a higher VS Code part is refused
    have = version_key(vscode)
    if m[1] == ">=":
        return have >= tuple(want)
    if m[1] == "^":
        exact[1:] = [exact[1] and want[0] == 0, False]
    if have[0] == 1 and want[0] == 0 and not all(exact):
        want, exact = [1, 0, 0], [True, False, False]
    for h, w, e in zip(have, want, exact):
        if h != w:
            return h > w and not e
    return True


def pin_version(value):
    """A pin's version: an image pin's tag, without a leading `v`; any other pin's value."""
    m = IMAGE_REF.fullmatch(value)
    return (m[2] if m else value).removeprefix("v")


def major_jump(old, new):
    """Whether a pin moves up a major version."""
    return version_key(pin_version(new))[0] > version_key(pin_version(old))[0] >= 0


# ------------------------------------------------------------------ lookups
def newest_vscode(fetch):
    """The VSCODE_* pins of vscode.env but Remote-SSH's, as {pin: value}."""
    with naming("VSCODE_VERSION"):
        latest = fetch(f"{UPDATE_API}/update/server-linux-x64/stable/latest")
        version, commit = latest["productVersion"], latest["version"]
    found = {"VSCODE_VERSION": version, "VSCODE_COMMIT": commit,
             "VSCODE_SERVER_SHA256": latest.get("sha256hash")}
    for platform, pin in (("cli-alpine-x64", "VSCODE_CLI_SHA256"), ("win32-x64-archive", "VSCODE_WIN_SHA256")):
        with naming(pin):
            build = fetch(f"{UPDATE_API}/versions/commit:{commit}/{platform}/stable")
        if build.get("version") != commit:
            raise LookupFailed(pin, f"the update API gave commit {build.get('version')} for {platform}, not {commit}")
        found[pin] = build.get("sha256hash")
    for pin, sha in found.items():
        if pin.endswith("SHA256") and not re.fullmatch(r"[0-9a-f]{64}", sha or ""):
            raise LookupFailed(pin, f"the update API gives no SHA-256 for VS Code {version}")
    return found


def newest_extension(fetch, ext, vscode, targets=SERVER_TARGETS, pin=None):
    """The newest stable version of a Marketplace extension, for one of `targets`, whose
    engine range accepts VS Code `vscode`. A failure names `pin` (the extension by default)."""
    pin = pin or ext
    body = json.dumps({"filters": [{"criteria": [{"filterType": 7, "value": ext}], "pageSize": 1}],
                       "flags": 0x1 | 0x10}).encode()   # versions, with their properties
    with naming(pin):
        found = fetch(MARKETPLACE, body)["results"][0]["extensions"]
        if not found:
            raise LookupFailed(pin, f"{ext} is not on the Marketplace")
        best = None
        for v in found[0]["versions"]:
            props = {p["key"]: p["value"] for p in v.get("properties", [])}
            if v.get("targetPlatform") not in targets \
                    or props.get("Microsoft.VisualStudio.Code.PreRelease") == "true" \
                    or not engine_accepts(props.get("Microsoft.VisualStudio.Code.Engine"), vscode):
                continue
            if best is None or version_key(v["version"]) > version_key(best):
                best = v["version"]
    if best is None:
        raise LookupFailed(pin, f"no stable version of {ext} accepts VS Code {vscode}")
    return best


def newest_release(fetch, repo, tag_pattern, pin):
    """The highest non-prerelease release whose tag fits `tag_pattern` (one group: the version),
    as (version, release). GitHub lists releases newest first, and a servicing release of an
    older line can be listed above a higher version, so pages are read until one brings no
    higher version than those before it (or the list ends, or PAGES are read)."""
    best = None
    for page in range(1, PAGES + 1):
        with naming(pin):
            releases = fetch(f"{GITHUB_API}/{repo}/releases?per_page={PAGE}&page={page}")
            stable = [(m[1], r) for r in releases if not r["draft"] and not r["prerelease"]
                      and (m := re.fullmatch(tag_pattern, r["tag_name"]))]
        top = max(stable, key=lambda s: version_key(s[0]), default=None)
        if top and (not best or version_key(top[0]) > version_key(best[0])):
            best = top
        elif best:
            break
        if len(releases) < PAGE:
            break
    if not best:
        raise LookupFailed(pin, f"no stable release of {repo} with a tag like {tag_pattern}")
    return best


def image_digest(imagetools, ref, pin):
    try:
        out = imagetools(ref)
    except Exception as e:
        hint = f" (is this host logged in to {DHI_REGISTRY}?)" if ref.startswith(f"{DHI_REGISTRY}/") else ""
        raise LookupFailed(pin, f"imagetools inspect {ref}: {e}{hint}") from None
    m = re.search(r"^Digest:\s*(sha256:[0-9a-f]{64})\s*$", out, re.M)
    if not m:
        raise LookupFailed(pin, f"imagetools inspect {ref} printed no digest")
    return m[1]


def newest_image(fetch, imagetools, group, args, pipeline):
    """The image pin's Changes, in the Dockerfile and the pipeline job that run it: its project's
    newest release tag (if it has a project) and that tag's digest."""
    image = IMAGES[group]
    pin = image.arg or image.job
    in_job = job_image(pipeline, image.job) if image.job else None
    if image.job and not IMAGE_REF.fullmatch(in_job[1] if in_job else ""):
        raise LookupFailed(image.job, f"no `<image>:<tag>@sha256:<digest>` image in the {image.job} job of {PIPELINE}")
    current = args.get(image.arg) if image.arg else in_job[1]
    m = IMAGE_REF.fullmatch(current or "")
    if not m:
        raise LookupFailed(pin, f"no `ARG {pin}=<image>:<tag>@sha256:<digest>` in {DOCKERFILE}")
    name, tag = m.groups()
    if image.repo:
        old = re.search(r"\d+(?:\.\d+)+", tag)
        if not old:
            raise LookupFailed(pin, f"{current} has no version in its tag to move")
        version, _ = newest_release(fetch, image.repo, r"v?(\d+\.\d+\.\d+)", pin)
        tag = tag.replace(old[0], version, 1)
    new = f"{name}:{tag}@{image_digest(imagetools, f'{name}:{tag}', pin)}"
    changes = [Change(DOCKERFILE, image.arg, current, new)] if image.arg else []
    if image.job:
        changes.append(Change(PIPELINE, image.job, in_job[1], new))
    return changes


def newest_tool(fetch, group, args, dockerfile):
    """The tool's version and SHA-256 Changes, from its newest release's asset digest."""
    sha_pin, version_pin = f"{group.upper()}_SHA256", f"{group.upper()}_VERSION"
    m = re.search(r"^ADD --checksum=sha256:\$\{" + sha_pin + r"\}\s*\\\s*"
                  r"https://github\.com/([^/]+/[^/]+)/releases/download/([^/\s]+)/(\S+)", dockerfile, re.M)
    if not m:
        raise LookupFailed(sha_pin, f"no `ADD --checksum=sha256:${{{sha_pin}}}` release download in {DOCKERFILE}")
    repo, tag_template, asset_template = m.groups()
    var = "${" + version_pin + "}"
    tag_pattern = re.escape(tag_template).replace(re.escape(var), r"(\d+\.\d+\.\d+)")
    version, release = newest_release(fetch, repo, tag_pattern, version_pin)
    asset = asset_template.replace(var, version)
    with naming(sha_pin):
        digest = next((a.get("digest") for a in release["assets"] if a["name"] == asset), None)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest or ""):
        raise LookupFailed(sha_pin, f"{repo} {release['tag_name']} gives no SHA-256 digest for {asset}")
    return [Change(DOCKERFILE, version_pin, args.get(version_pin), version),
            Change(DOCKERFILE, sha_pin, args.get(sha_pin), digest.removeprefix("sha256:"))]


def look_up(groups, before, fetch, imagetools):
    """Every selected pin's Change, current or not. Raises LookupFailed naming the pin."""
    env = dict(re.findall(r"^([A-Z0-9_]+)=([^\r\n]*)", before[VSCODE_ENV], re.M))
    args = dict(re.findall(r"^ARG (\w+)=([^\r\n]*)", before[DOCKERFILE], re.M))
    changes = []
    vscode = env.get("VSCODE_VERSION", "")
    if "vscode" in groups:
        new = newest_vscode(fetch)
        vscode = new["VSCODE_VERSION"]
        new[REMOTE_SSH_PIN] = newest_extension(fetch, REMOTE_SSH, vscode, WORKSTATION_TARGETS, REMOTE_SSH_PIN)
        changes += [Change(VSCODE_ENV, pin, env.get(pin), value) for pin, value in new.items()]
    if "extensions" in groups:
        changes += [Change(EXTENSIONS, ext, old, newest_extension(fetch, ext, vscode))
                    for ext, old in re.findall(r"^([\w.-]+)@([^\s#]+)", before[EXTENSIONS], re.M)]
    for g in (g for g in groups if g in IMAGES):
        changes += newest_image(fetch, imagetools, g, args, before[PIPELINE])
    for g in (g for g in groups if g in TOOLS):
        changes += newest_tool(fetch, g, args, before[DOCKERFILE])
    return changes


# ------------------------------------------------------------------ pin files
def set_line(text, key, change):
    """`text` with its one `<key>=` line set to the change's new value."""
    new, n = re.subn(rf"^{re.escape(key)}=[^\r\n]*", f"{key}={change.new}", text, flags=re.M)
    if n != 1:
        raise PinFileError(f"{change.pin}: not exactly one {key}= line in {change.file}")
    return new


def set_extension(text, change):
    return re.sub(rf"^{re.escape(change.pin)}@{re.escape(change.old)}(?=\s|$)",
                  f"{change.pin}@{change.new}", text, flags=re.M)


def job_image(text, job):
    """The match of a pipeline job's image (group 1): its `image:` value, or the `name:`
    under it. Only the job's own indented lines are read."""
    return re.search(rf"^{re.escape(job)}:[ \t]*\r?\n(?:[ \t]*\r?\n|[ \t]+[^\r\n]*\r?\n)*?"
                     r"[ \t]+(?:image|name):[ \t]*([^\s#]+)", text, re.M)


def set_job_image(text, change):
    m = job_image(text, change.pin)
    if not m or m[1] != change.old:
        raise PinFileError(f"{change.pin}: no {change.pin} job running {change.old} in {change.file}")
    return text[:m.start(1)] + change.new + text[m.end(1):]


REWRITE = {VSCODE_ENV: lambda text, c: set_line(text, c.pin, c),
           DOCKERFILE: lambda text, c: set_line(text, f"ARG {c.pin}", c),
           EXTENSIONS: set_extension,
           PIPELINE: set_job_image}


def rewrite(before, changes):
    """The pin files' new text. Raises PinFileError."""
    after = dict(before)
    for c in changes:
        if c.changed:
            after[c.file] = REWRITE[c.file](after[c.file], c)
    return after


# ------------------------------------------------------------------ main
def preflight(groups, buildx, docker_config):
    """Why the selected groups cannot run on this host, or None."""
    needs_docker = [g for g in groups if g in IMAGES]
    if needs_docker and not buildx():
        return (f"the {', '.join(needs_docker)} group(s) need `docker buildx`: "
                f"install Docker's buildx plugin, or run only the other groups")
    if "dhi" in groups and not logged_in(docker_config, DHI_REGISTRY):
        return f"the dhi group needs this host's `docker login {DHI_REGISTRY}`: log in, or run only the other groups"
    return None


def report(changes, out):
    changed = [c for c in changes if c.changed]
    if not changed:
        print("Every selected pin is current; nothing changed.", file=out)
        return
    for c in changed:
        flag = "  [major version]" if c.old and major_jump(c.old, c.new) else ""
        label = f"{c.pin} job" if c.file == PIPELINE else c.pin
        print(f"{label} {c.old} -> {c.new}{flag}", file=out)
    print("\nStill by hand: review `git diff`, then commit and push.", file=out)
    if any(c.file == VSCODE_ENV for c in changed):
        print("The Workstation pack needs the portable VS Code zip and the Remote-SSH VSIX for the new pins "
              f"(VSCODE_VERSION, {REMOTE_SSH_PIN}).", file=out)
    print("The Release build and its self-test prove the new pins.", file=out)


def main(argv=None, root=ROOT, fetch=http_json, imagetools=docker_imagetools, buildx=has_buildx,
         docker_config=None, out=sys.stdout, err=sys.stderr):
    argv = sys.argv[1:] if argv is None else argv
    if any(a in ("-h", "--help") for a in argv):
        print(f"{__doc__.strip()}\n\nGroups: {', '.join(GROUPS)}", file=out)
        return 0
    unknown = [a for a in argv if a not in GROUPS]
    if unknown:
        print(f"unknown group {', '.join(unknown)}; the groups are {', '.join(GROUPS)}", file=err)
        return 2
    groups = [g for g in GROUPS if not argv or g in argv]
    if why := preflight(groups, buildx, docker_config or docker_config_path()):
        print(why, file=err)
        return 1

    paths = {f: Path(root) / f for f in (VSCODE_ENV, EXTENSIONS, DOCKERFILE, PIPELINE)}
    before = {f: p.read_bytes().decode("utf-8") for f, p in paths.items()}
    try:
        changes = look_up(groups, before, fetch, imagetools)
    except LookupFailed as e:
        print(f"lookup failed, nothing written: {e}", file=err)
        return 1
    try:
        after = rewrite(before, changes)
    except PinFileError as e:
        print(f"nothing written: {e}", file=err)
        return 1
    for f, p in paths.items():
        if after[f] != before[f]:
            p.write_bytes(after[f].encode("utf-8"))
    report(changes, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
