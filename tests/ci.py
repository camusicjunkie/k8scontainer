#!/usr/bin/env python3
"""CI seam: what the GitLab pipeline does per ref, read from .gitlab-ci.yml.

    python3 tests/ci.py

Evaluates each job's `rules:` for simulated pushes, tags and merge requests,
and checks the pipeline needs no privileged runner or Docker daemon. The rule
evaluator understands only the GitLab expression subset this repo uses and
fails loudly on anything else, so a new construct cannot be silently ignored.
"""
import re
import sys
from pathlib import Path

import yaml

CI = Path(__file__).resolve().parent.parent / ".gitlab-ci.yml"
DOCKERFILE = CI.parent / "image/Dockerfile"
# tests/lint.sh's LINTERS line, so a linter added there needs its job here.
LINTERS = tuple(re.search(r'^LINTERS="([^"]*)"', (CI.parent / "tests/lint.sh").read_text(), re.M).group(1).split())
TOKEN = re.compile(r'\s*(&&|\|\||==|!=|=~|!~|\$\w+|"[^"]*"|/(?:\\/|[^/])*/|\(|\)|null)')


def evaluate(expr, env):
    toks, pos = [], 0
    expr = expr.strip()
    while pos < len(expr):
        m = TOKEN.match(expr, pos)
        if not m:
            raise ValueError(f"unsupported rule syntax at {expr[pos:]!r} in {expr!r}")
        toks.append(m.group(1))
        pos = m.end()
    it = iter(toks + [None])
    cur = [next(it)]

    def adv():
        t = cur[0]
        cur[0] = next(it)
        return t

    def operand():
        t = adv()
        if t == "(":
            v = disj()
            if adv() != ")":
                raise ValueError(f"unbalanced parens in {expr!r}")
            return v
        if t is None:
            raise ValueError(f"truncated rule {expr!r}")
        if t.startswith("$"):
            return env.get(t[1:])
        if t == "null":
            return None
        if t.startswith('"'):
            return t[1:-1]
        return ("re", t[1:-1].replace("\\/", "/"))

    def comparison():
        left = operand()
        if cur[0] in ("==", "!=", "=~", "!~"):
            op, right = adv(), operand()
            if op == "==":
                return left == right
            if op == "!=":
                return left != right
            hit = left is not None and re.search(right[1], left) is not None
            return hit if op == "=~" else not hit
        return bool(left)

    def conj():
        v = comparison()
        while cur[0] == "&&":
            adv()
            r = comparison()
            v = v and r
        return v

    def disj():
        v = conj()
        while cur[0] == "||":
            adv()
            r = conj()
            v = v or r
        return v

    out = disj()
    if cur[0] is not None:
        raise ValueError(f"trailing tokens in {expr!r}")
    return out


def jobs_for(cfg, env):
    """Names of jobs that run, or None if the workflow rejects the pipeline."""
    for rule in cfg["workflow"]["rules"]:
        if "if" not in rule or evaluate(rule["if"], env):
            if rule.get("when") == "never":
                return None
            break
    else:
        return None
    ran = set()
    for name, job in cfg.items():
        if not isinstance(job, dict) or "script" not in job:
            continue
        for rule in job.get("rules", [{}]):
            if "if" not in rule or evaluate(rule["if"], env):
                if rule.get("when") != "never":
                    ran.add(name)
                break
    return ran


# The jobs every ref runs; a Release tag adds publish.
EVERY_REF = {"build", "selftest", "checks", *LINTERS}
REFS = {
    "push to main": ({"CI_COMMIT_BRANCH": "main", "CI_PIPELINE_SOURCE": "push"}, EVERY_REF),
    "push to a feature branch": ({"CI_COMMIT_BRANCH": "feat/x", "CI_PIPELINE_SOURCE": "push"}, EVERY_REF),
    "merge request": ({"CI_PIPELINE_SOURCE": "merge_request_event", "CI_MERGE_REQUEST_IID": "3"}, EVERY_REF),
    "Release tag v1.2.3": ({"CI_COMMIT_TAG": "v1.2.3", "CI_PIPELINE_SOURCE": "push"}, EVERY_REF | {"publish"}),
    "Release tag 2026.11.2": ({"CI_COMMIT_TAG": "2026.11.2", "CI_PIPELINE_SOURCE": "push"}, EVERY_REF | {"publish"}),
    "non-Release tag 'wip'": ({"CI_COMMIT_TAG": "wip", "CI_PIPELINE_SOURCE": "push"}, EVERY_REF),
    "tag 'v1.2.3-oops'": ({"CI_COMMIT_TAG": "v1.2.3-oops", "CI_PIPELINE_SOURCE": "push"}, EVERY_REF),
}


def image_of(cfg, name):
    """The image reference job `name` runs in, from `image:` or `image: name:`."""
    job = cfg.get(name)
    ref = job.get("image") if isinstance(job, dict) else None
    if isinstance(ref, dict):
        ref = ref.get("name")
    if not ref:
        raise SystemExit(f"tests/ci.py: job {name!r} has no image in .gitlab-ci.yml")
    return str(ref)

failed = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failed.append(name)


cfg = yaml.safe_load(CI.read_text()) if CI.exists() else None
if cfg is None:
    check(".gitlab-ci.yml exists", False)
else:
    for label, (env, want) in REFS.items():
        got = jobs_for(cfg, env)
        check(f"{label} runs {sorted(want)}", got == want, f"got {got}")
    # A branch with an open MR must not run twice.
    dup = jobs_for(cfg, {"CI_COMMIT_BRANCH": "feat/x", "CI_OPEN_MERGE_REQUESTS": "g/p!3", "CI_PIPELINE_SOURCE": "push"})
    check("a branch push with an open merge request runs no duplicate pipeline", dup is None, f"got {dup}")

    text = re.sub(r"(?m)^\s*#.*$", "", CI.read_text())
    check("no Docker-in-Docker service", "dind" not in text and not any(
        isinstance(j, dict) and "services" in j for j in cfg.values()) and "services" not in cfg)
    check("no privileged mode or docker daemon use",
          not re.search(r"privileged|docker\s+(build|run|push|login)|/var/run/docker\.sock", text))
    selftest = "\n".join(cfg.get("selftest", {}).get("script", []))
    check("the self-test job runs devc-selftest", "devc-selftest" in selftest)
    check("the self-test runs with no network",
          re.search(r"--network[ =]none\b[^\n]*devc-selftest", selftest) is not None)
    # chroot isolation keeps the job's network whatever --network says.
    check("the self-test uses rootless isolation, which honours --network none",
          cfg.get("selftest", {}).get("variables", {}).get("BUILDAH_ISOLATION") == "rootless"
          and "--isolation chroot" not in selftest)
    build = "\n".join(cfg.get("build", {}).get("script", []))
    check("the build logs in to dhi.io for the base when DHI_USER is set",
          re.search(r"DHI_USER[\s\S]*--password-stdin dhi\.io", build) is not None)
    check("DHI credentials appear only in the build job", all(
        "DHI_" not in yaml.dump(j) for n, j in cfg.items() if isinstance(j, dict) and n != "build"))
    publish_needs = [n if isinstance(n, str) else n.get("job") for n in cfg.get("publish", {}).get("needs", [])]
    check("publish waits on the self-test", "selftest" in publish_needs)
    check("publish waits on the repo checks", "checks" in publish_needs)
    check("the checks job runs tests/all.sh --files",
          "tests/all.sh --files" in "\n".join(cfg.get("checks", {}).get("script", [])))
    # The linters run beside the file checks, from pinned images, so CI never
    # skips them as tests/all.sh does on a machine without them.
    for lint in LINTERS:
        job = cfg.get(lint, {})
        check(f"the {lint} job runs tests/lint.sh {lint} in the checks' stage",
              job.get("stage") == cfg.get("checks", {}).get("stage")
              and f"tests/lint.sh {lint}" in "\n".join(job.get("script", [])))
        check(f"publish waits on {lint}", lint in publish_needs)
    pin = re.search(r"^ARG HADOLINT_IMAGE=(\S+)", DOCKERFILE.read_text(), re.M)
    check("the hadolint job uses the image the Dockerfile's HADOLINT_IMAGE pins",
          pin is not None and image_of(cfg, "hadolint") == pin.group(1),
          f"{image_of(cfg, 'hadolint')} vs {pin and pin.group(1)}")
    check("the shellcheck job's image is pinned by digest", "@sha256:" in image_of(cfg, "shellcheck"))
    # tests/lint.sh lists scripts with git ls-files; the shellcheck image has no git.
    shellcheck = "\n".join(cfg.get("shellcheck", {}).get("script", []))
    check("the shellcheck job installs git and runs tests/lint-scripts.sh before the lint",
          re.search(r"apk add [^\n]*\bgit\b[\s\S]*tests/lint-scripts\.sh[\s\S]*tests/lint\.sh shellcheck", shellcheck)
          is not None)
    check("Harbor credentials appear only in the publish job", all(
        "HARBOR" not in yaml.dump(j) for n, j in cfg.items() if isinstance(j, dict) and n != "publish"))
    candidate = str(cfg.get("variables", {}).get("CANDIDATE", ""))
    check("each pipeline has its own candidate tag (a branch and a tag pipeline on one commit never share it)",
          "$CI_PIPELINE_ID" in candidate)
    check("no password is passed on a command line (logins read it from stdin)",
          not re.search(r"--password[ =]\"|--(src|dest)-creds|--creds", text))
    check("every literal image is pinned to a version", all(
        ":" in str(j["image"] if isinstance(j["image"], str) else j["image"]["name"]) and "latest" not in str(j["image"])
        for j in cfg.values() if isinstance(j, dict) and "image" in j and "$" not in str(j["image"])))

if failed:
    print(f"{len(failed)} case(s) failed")
    sys.exit(1)
print("all cases passed")
