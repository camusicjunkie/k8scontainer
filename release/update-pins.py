#!/usr/bin/env python3
"""Refresh the Standard Image's exact pins from upstream.

    python3 release/update-pins.py [group...]

Groups: vscode, extensions, dhi, brew, hadolint, codex, tflint, pwsh; none
means all. The Release Owner runs it at the start of a Release on the Connected
Side's Linux Docker host, in a clone at the Release branch. It looks up the
newest version of each selected pin, then rewrites image/packages/vscode.env,
image/packages/vscode-extensions.txt and image/Dockerfile, leaving the change
in the working tree as a diff to review. It builds, commits and pushes nothing.

Every checksum comes from its publisher: the VS Code update API, and the
`digest` the GitHub release API gives each release asset. Image digests come
from `docker buildx imagetools inspect`, which uses the host's `docker login`
(dhi.io needs one); only the dhi, brew and hadolint groups need it. Every
lookup happens before any write, so a failed one writes nothing.
`GITHUB_TOKEN` is sent to the GitHub API when set.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VSCODE_ENV = "image/packages/vscode.env"
EXTENSIONS = "image/packages/vscode-extensions.txt"
DOCKERFILE = "image/Dockerfile"

GROUPS = ("vscode", "extensions", "dhi", "brew", "hadolint", "codex", "tflint", "pwsh")
# Image pins, and the GitHub project whose newest release names the tag.
# DHI_BASE keeps its tag and takes the tag's current digest.
IMAGES = {"dhi": ("DHI_BASE", None), "brew": ("BREW_IMAGE", "Homebrew/brew"),
          "hadolint": ("HADOLINT_IMAGE", "hadolint/hadolint")}
# Downloaded tools: where each comes from is read from the Dockerfile's
# `ADD --checksum=sha256:${<GROUP>_SHA256} <release asset URL>`.
TOOLS = ("codex", "tflint", "pwsh")

UPDATE_API = "https://update.code.visualstudio.com/api"
MARKETPLACE = "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"
GITHUB_API = "https://api.github.com/repos"
REMOTE_SSH = "ms-vscode-remote.remote-ssh"
# The platforms a VSIX may target and still install where it goes: the extensions on
# the image's VS Code server, Remote-SSH on the Workstation's portable VS Code.
SERVER_TARGETS = (None, "universal", "linux-x64")
WORKSTATION_TARGETS = (None, "universal", "win32-x64")
PAGE = 30   # a Codex release has ~200 assets; bigger pages time out
PAGES = 5


class LookupFailed(Exception):
    def __init__(self, pin, reason):
        super().__init__(f"{pin}: {reason}")


# ------------------------------------------------------------------ upstream
def fetch(url, body=None):
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


def imagetools(ref):
    """`docker buildx imagetools inspect` output for an image reference."""
    r = subprocess.run(["docker", "buildx", "imagetools", "inspect", ref], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError((r.stderr or r.stdout).strip() or f"exit {r.returncode}")
    return r.stdout


def buildx():
    if not shutil.which("docker"):
        return False
    return subprocess.run(["docker", "buildx", "version"], capture_output=True).returncode == 0


def docker_config():
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


def major_jump(old, new):
    """Whether a pin's version (an image pin's tag) moves up a major version."""
    old, new = (re.sub(r"^.*:v?([^:@]+)@sha256:.*$", r"\1", v) for v in (old, new))
    return version_key(new)[0] > version_key(old)[0] >= 0


# ------------------------------------------------------------------ lookups
def newest_vscode(fetch):
    latest = fetch(f"{UPDATE_API}/update/server-linux-x64/stable/latest")
    version, commit = latest["productVersion"], latest["version"]
    found = {"VSCODE_VERSION": version, "VSCODE_COMMIT": commit,
             "VSCODE_SERVER_SHA256": latest.get("sha256hash")}
    for platform, pin in (("cli-alpine-x64", "VSCODE_CLI_SHA256"), ("win32-x64-archive", "VSCODE_WIN_SHA256")):
        build = fetch(f"{UPDATE_API}/versions/commit:{commit}/{platform}/stable")
        if build.get("version") != commit:
            raise LookupFailed(pin, f"the update API gave commit {build.get('version')} for {platform}, not {commit}")
        found[pin] = build.get("sha256hash")
    for pin, sha in found.items():
        if pin.endswith("SHA256") and not re.fullmatch(r"[0-9a-f]{64}", sha or ""):
            raise LookupFailed(pin, f"the update API gives no SHA-256 for VS Code {version}")
    return found


def newest_extension(fetch, ext, vscode, targets=SERVER_TARGETS):
    body = json.dumps({"filters": [{"criteria": [{"filterType": 7, "value": ext}], "pageSize": 1}],
                       "flags": 0x1 | 0x10}).encode()   # versions, with their properties
    found = fetch(MARKETPLACE, body)["results"][0]["extensions"]
    if not found:
        raise LookupFailed(ext, "not on the Marketplace")
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
        raise LookupFailed(ext, f"no stable version accepts VS Code {vscode}")
    return best


def newest_release(fetch, repo, tag_pattern, pin):
    """The highest non-prerelease release whose tag fits `tag_pattern` (one group: the version),
    as (version, release). GitHub lists releases newest first, and a servicing release of an
    older line can be listed above a higher version, so pages are read until one brings no
    higher version than those before it (or the list ends, or PAGES are read)."""
    best = None
    for page in range(1, PAGES + 1):
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
        hint = " (is this host logged in to dhi.io?)" if ref.startswith("dhi.io/") else ""
        raise LookupFailed(pin, f"imagetools inspect {ref}: {e}{hint}") from None
    m = re.search(r"^Digest:\s*(sha256:[0-9a-f]{64})\s*$", out, re.M)
    if not m:
        raise LookupFailed(pin, f"imagetools inspect {ref} printed no digest")
    return m[1]


def newest_image(fetch, imagetools, group, current):
    pin, repo = IMAGES[group]
    name, tag = re.fullmatch(r"(.+):([^:@/]+)@sha256:[0-9a-f]{64}", current).groups()
    if repo:
        old = re.search(r"\d+(?:\.\d+)+", tag)[0]
        version, _ = newest_release(fetch, repo, r"v?(\d+\.\d+\.\d+)", pin)
        tag = tag.replace(old, version, 1)
    return f"{name}:{tag}@{image_digest(imagetools, f'{name}:{tag}', pin)}"


def newest_tool(fetch, group, dockerfile):
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
    digest = next((a.get("digest") for a in release["assets"] if a["name"] == asset), None)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest or ""):
        raise LookupFailed(sha_pin, f"{repo} {release['tag_name']} gives no SHA-256 digest for {asset}")
    return {version_pin: version, sha_pin: digest.removeprefix("sha256:")}


# ------------------------------------------------------------------ pin files
def read_env(text):
    return dict(re.findall(r"^([A-Z0-9_]+)=([^\r\n]*)", text, re.M))


def set_env(text, key, value, where):
    new, n = re.subn(rf"^{key}=[^\r\n]*", f"{key}={value}", text, flags=re.M)
    if n != 1:
        raise LookupFailed(key, f"not exactly one {key}= line in {where}")
    return new


def read_extensions(text):
    return re.findall(r"^([\w.-]+)@([^\s#]+)", text, re.M)


def main(argv=None, root=ROOT, fetch=fetch, imagetools=imagetools, buildx=buildx, docker_config=None,
         out=sys.stdout, err=sys.stderr):
    argv = sys.argv[1:] if argv is None else argv
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip(), file=out)
        return 0
    unknown = [a for a in argv if a not in GROUPS]
    if unknown:
        print(f"unknown group {', '.join(unknown)}; the groups are {', '.join(GROUPS)}", file=err)
        return 2
    groups = [g for g in GROUPS if not argv or g in argv]
    needs_docker = [g for g in groups if g in IMAGES]
    if needs_docker and not buildx():
        print(f"the {', '.join(needs_docker)} group(s) need `docker buildx` (logged in to dhi.io for dhi): "
              f"install Docker's buildx plugin, or run only the other groups", file=err)
        return 1
    if "dhi" in groups and not logged_in(docker_config or globals()["docker_config"](), "dhi.io"):
        print("the dhi group needs this host's `docker login dhi.io`: log in, or run only the other groups", file=err)
        return 1

    paths = {f: Path(root) / f for f in (VSCODE_ENV, EXTENSIONS, DOCKERFILE)}
    before = {f: p.read_bytes().decode("utf-8") for f, p in paths.items()}
    env, dockerfile = read_env(before[VSCODE_ENV]), before[DOCKERFILE]
    args = dict(re.findall(r"^ARG (\w+)=([^\r\n]*)", dockerfile, re.M))
    changes = []   # (file, pin, old, new)
    pin = None     # the pin being looked up, named if the lookup fails

    try:
        vscode = env.get("VSCODE_VERSION", "")
        if "vscode" in groups:
            pin = "VSCODE_VERSION"
            new = newest_vscode(fetch)
            vscode = new["VSCODE_VERSION"]
            pin = "VSCODE_REMOTE_SSH_VERSION"
            new[pin] = newest_extension(fetch, REMOTE_SSH, vscode, WORKSTATION_TARGETS)
            changes += [(VSCODE_ENV, k, env.get(k), v) for k, v in new.items()]
        if "extensions" in groups:
            for pin, old in read_extensions(before[EXTENSIONS]):
                changes.append((EXTENSIONS, pin, old, newest_extension(fetch, pin, vscode)))
        for g in groups:
            if g in IMAGES:
                pin = IMAGES[g][0]
                if pin not in args:
                    raise LookupFailed(pin, f"no `ARG {pin}=` in {DOCKERFILE}")
                changes.append((DOCKERFILE, pin, args[pin], newest_image(fetch, imagetools, g, args[pin])))
            elif g in TOOLS:
                pin = f"{g.upper()}_VERSION"
                changes += [(DOCKERFILE, k, args.get(k), v) for k, v in newest_tool(fetch, g, dockerfile).items()]
    except LookupFailed as e:
        print(f"lookup failed, nothing written: {e}", file=err)
        return 1
    except Exception as e:   # a network error, a rate limit, an unexpected response
        print(f"lookup failed, nothing written: {pin}: {type(e).__name__}: {e}", file=err)
        return 1

    after = dict(before)
    try:
        for f, pin, old, new in changes:
            if old == new:
                continue
            if f == VSCODE_ENV:
                after[f] = set_env(after[f], pin, new, f)
            elif f == DOCKERFILE:
                after[f] = set_env(after[f], "ARG " + pin, new, f)
            else:
                after[f] = re.sub(rf"^{re.escape(pin)}@{re.escape(old)}(?=\s|$)", f"{pin}@{new}", after[f], flags=re.M)
    except LookupFailed as e:
        print(f"nothing written: {e}", file=err)
        return 1
    for f, p in paths.items():
        if after[f] != before[f]:
            p.write_bytes(after[f].encode("utf-8"))

    changed = [c for c in changes if c[2] != c[3]]
    if not changed:
        print("Every selected pin is current; nothing changed.", file=out)
        return 0
    for f, pin, old, new in changed:
        flag = "  [major version]" if old and major_jump(old, new) else ""
        print(f"{pin} {old} -> {new}{flag}", file=out)
    print("\nStill by hand: review `git diff`, then commit and push.", file=out)
    if any(f == VSCODE_ENV for f, *_ in changed):
        print("The Workstation pack needs the portable VS Code zip and the Remote-SSH VSIX for the new pins "
              "(VSCODE_VERSION, VSCODE_REMOTE_SSH_VERSION).", file=out)
    print("The Release build and its self-test prove the new pins.", file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
