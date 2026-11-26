#!/usr/bin/env python3
"""Repo seam: contracts between files that no single seam sees whole.

    python3 tests/repo.py

Reads files only, so it needs no Docker, cluster or network. Checks:
  1. every Pod-side path the image uses is one the Pod provides (a mount, under
     a mount, or a parent of one) or one the image ships itself;
  2. every base image in image/Dockerfile is pinned by digest, and every stage
     but the hadolint and brew builders is on the DHI base, and every build
     arg (each downloaded tool's version and SHA-256) is given its value once;
  3. no GLOSSARY.md _Avoid_ term in code comments;
  4. no resolved ticket has an acceptance item left open without `[unverified]`.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = "/home/dev"
failed = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failed.append(name)


def files(*globs):
    for g in globs:
        for p in sorted(ROOT.glob(g)):
            if p.is_file():
                yield p


def text(p):
    return p.read_text(encoding="utf-8", errors="replace")


# 1. Pod-side paths. The bug this catches: the image reading a path no mount
# provides (99-personal.sh once read /etc/devcontainer/personal/bashrc while
# the Pod mounted Personal Config at ~/.devc/personal).
resourceset = text(ROOT / "manifests/devcontainer/resourceset.yaml")
mounts = sorted(set(re.findall(r"mountPath:\s*([^\s,}]+)", resourceset)))
dockerfile = text(ROOT / "image/Dockerfile")
POD_PATH = re.compile(r"(?:/etc/devcontainer|/etc/devc|/var/lib/devc|\$HOME/\.devc|~/\.devc|/home/dev/\.devc)/[\w./-]*")


def provided(path):
    if path in dockerfile or (ROOT / "image/rootfs" / path.lstrip("/")).exists():
        return True
    for m in mounts:
        if path == m or path.startswith(m + "/") or m.startswith(path + "/"):
            return True
    return False


unprovided = set()
for p in files("image/rootfs/**/*", "image/Dockerfile"):
    for raw in POD_PATH.findall(text(p)):
        path = re.sub(r"^(\$HOME|~)", HOME, raw).rstrip("./")
        if not provided(path):
            unprovided.add(f"{path} ({p.relative_to(ROOT).as_posix()})")
check(f"every Pod-side path the image uses is provided ({len(mounts)} mounts)", not unprovided,
      "; ".join(sorted(unprovided)))

# 2. Base images.
args = dict(re.findall(r"^ARG (\w+)=(\S+)", dockerfile, re.M))
bases = re.findall(r"^FROM\s+\$\{(\w+)\}(?:\s+AS\s+(\S+))?", dockerfile, re.M | re.I)
all_from = re.findall(r"^FROM\s+(\S+)", dockerfile, re.M | re.I)
check("every FROM names a base by ARG", len(bases) == len(all_from), f"{len(all_from) - len(bases)} literal FROM")
unpinned = [f"{a}={args.get(a)}" for a, _ in bases if "@sha256:" not in args.get(a, "")]
check("every base image is pinned by digest", not unpinned, ", ".join(unpinned))
# buildah in CI has no search registries, so a short name (homebrew/brew) fails
# there with "short-name resolution enforced" even though docker build passes.
short = [f"{a}={args.get(a)}" for a, _ in bases if "." not in args.get(a, "").split("/")[0]]
check("every base image names its registry (no short names)", not short, ", ".join(short))
check("DHI_BASE is the DHI debian-base", args.get("DHI_BASE", "").startswith("dhi.io/debian-base:"),
      args.get("DHI_BASE", "missing"))
BUILDERS = {"HADOLINT_IMAGE": "hadolint", "BREW_IMAGE": "brew"}
off_dhi = [f"{stage or 'final'} on {a}" for a, stage in bases if a != "DHI_BASE" and BUILDERS.get(a) != stage]
check("every stage but the hadolint and brew builders is on DHI_BASE", not off_dhi, ", ".join(off_dhi))
# A pin given a value in two stages lets a bump change one: the downloads stage
# then fetched one Codex while the final stage's MANIFEST named another.
valued = re.findall(r"^ARG (\w+)=", dockerfile, re.M)
twice = sorted({a for a in valued if valued.count(a) > 1})
check("every build arg in image/Dockerfile is given its value once", not twice, ", ".join(twice))

# 3. Glossary terms in code comments. A term counts only standing alone, so tool
# and file names that embed it (ansible-vault, devc-vault-pass, ~/.secrets/vault)
# are left alone. Exempt: "devcontainer", in every path and name here, and
# "home" and "profile", which code means literally (home directory, shell
# profile), not as Personal Config.
EVERYDAY = {"devcontainer", "home", "profile"}
avoid = []
for line in text(ROOT / "GLOSSARY.md").splitlines():
    if line.startswith("_Avoid_:"):
        avoid += [t.strip() for t in re.sub(r"\(.*?\)", "", line[8:]).split(",") if t.strip()]
avoid = [t for t in avoid if t not in EVERYDAY]
term = re.compile(r"(?<![\w./~-])(" + "|".join(map(re.escape, avoid)) + r")(?![\w/-])", re.I)
comment = re.compile(r"^\s*(?:#|//|<#)\s?(.*)")
hits = []
for p in files("image/**/*", "manifests/**/*", "tests/**/*", "release/**/*", "workstation/**/*", ".gitlab-ci.yml"):
    if p.suffix in {".md", ".zip", ".png"}:
        continue
    for n, line in enumerate(text(p).splitlines(), 1):
        m = comment.match(line)
        if m and line.lstrip()[:2] != "#!":
            body = re.sub(r"`[^`]*`|'[^']*'|\"[^\"]*\"", "", m.group(1))
            for t in term.findall(body):
                hits.append(f"{p.relative_to(ROOT).as_posix()}:{n} '{t}'")
check(f"no GLOSSARY _Avoid_ term in code comments ({', '.join(avoid)})", not hits, "; ".join(hits))

# 3b. Runtime facts: the Flux variables the manifests use are exactly the
# contract in tests/site/facts.env, which the Gitops repository's bootstrap
# writes into flux-runtime-info. With strict substitution, a variable missing
# there fails the sync; one listed but unused is a stale contract.
contract = set(subprocess.run([sys.executable, "-I", str(ROOT / "tests/site/subst.py"), "--names"],
                              capture_output=True, text=True, check=True).stdout.split())
used = set()
for p in files("manifests/**/*.yaml"):
    used |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)", text(p)))
check("every Flux variable in manifests/ is a runtime fact in tests/site/facts.env", used <= contract,
      ", ".join(sorted(used - contract)))
check("every runtime fact in tests/site/facts.env is used in manifests/", contract <= used,
      ", ".join(sorted(contract - used)))

# 4. Ticket hygiene.
open_items = []
for p in files(".scratch/*/issues/*.md"):
    body = text(p)
    if re.search(r"^\**Status:?\**:?\s*resolved", body, re.M | re.I):
        for line in body.splitlines():
            if line.lstrip().startswith("- [ ]") and "[unverified]" not in line:
                open_items.append(f"{p.relative_to(ROOT).as_posix()}: {line.strip()[:60]}")
check("resolved tickets have every acceptance item ticked or marked [unverified]", not open_items,
      "; ".join(open_items))

if failed:
    print(f"{len(failed)} case(s) failed")
    sys.exit(1)
print("all cases passed")
