#!/usr/bin/env python3
"""Run one .gitlab-ci.yml job's script in the job's image, with Docker.

    python3 .github/run-gitlab-job.py checks|shellcheck|hadolint

For .github/workflows/checks.yml. Only jobs that need no CI variables or
services: it mounts the checkout at /w and runs the script with sh -e, as a
GitLab Docker runner would.
"""
import subprocess
import sys
from pathlib import Path

import yaml

repo = Path(__file__).resolve().parent.parent
name = sys.argv[1]
job = yaml.safe_load((repo / ".gitlab-ci.yml").read_text()).get(name)
if not isinstance(job, dict) or "script" not in job:
    raise SystemExit(f"run-gitlab-job.py: no job {name!r} with a script in .gitlab-ci.yml")
image = job["image"]["name"] if isinstance(job["image"], dict) else job["image"]

# The container runs as root over a checkout the runner's user owns, which git
# refuses (dubious ownership) unless the directory is marked safe.
git_safe = ["-e", "GIT_CONFIG_COUNT=1", "-e", "GIT_CONFIG_KEY_0=safe.directory", "-e", "GIT_CONFIG_VALUE_0=*"]
sys.exit(subprocess.run(["docker", "run", "--rm", "--entrypoint", "", "-v", f"{repo}:/w", "-w", "/w", *git_safe,
                         image, "sh", "-ec", "\n".join(job["script"])]).returncode)
