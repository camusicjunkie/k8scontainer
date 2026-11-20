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


REFS = {
    "push to main": ({"CI_COMMIT_BRANCH": "main", "CI_PIPELINE_SOURCE": "push"}, {"build", "selftest", "checks"}),
    "push to a feature branch": ({"CI_COMMIT_BRANCH": "feat/x", "CI_PIPELINE_SOURCE": "push"}, {"build", "selftest", "checks"}),
    "merge request": ({"CI_PIPELINE_SOURCE": "merge_request_event", "CI_MERGE_REQUEST_IID": "3"}, {"build", "selftest", "checks"}),
    "Release tag v1.2.3": ({"CI_COMMIT_TAG": "v1.2.3", "CI_PIPELINE_SOURCE": "push"}, {"build", "selftest", "checks", "publish"}),
    "Release tag 2026.11.2": ({"CI_COMMIT_TAG": "2026.11.2", "CI_PIPELINE_SOURCE": "push"}, {"build", "selftest", "checks", "publish"}),
    "non-Release tag 'wip'": ({"CI_COMMIT_TAG": "wip", "CI_PIPELINE_SOURCE": "push"}, {"build", "selftest", "checks"}),
    "tag 'v1.2.3-oops'": ({"CI_COMMIT_TAG": "v1.2.3-oops", "CI_PIPELINE_SOURCE": "push"}, {"build", "selftest", "checks"}),
}

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
    check("Harbor credentials appear only in the publish job", all(
        "HARBOR" not in yaml.dump(j) for n, j in cfg.items() if isinstance(j, dict) and n != "publish"))
    check("every literal image is pinned to a version", all(
        ":" in str(j["image"] if isinstance(j["image"], str) else j["image"]["name"]) and "latest" not in str(j["image"])
        for j in cfg.values() if isinstance(j, dict) and "image" in j and "$" not in str(j["image"])))

if failed:
    print(f"{len(failed)} case(s) failed")
    sys.exit(1)
print("all cases passed")
