# 03: Gate GitHub PRs on the file checks

**What to build:** A GitHub Actions workflow runs `tests/all.sh --files`, including the linters from ticket 01, on every PR, so nothing merges on GitHub without the checks. PRs #1 and #2 merged on GitHub with no check: the pipeline is GitLab's, and it ran only on the local lab.

**Blocked by:** 01

**Status:** resolved

**Question for the Release Owner:** is the GitHub repository a gate for changes, or only a mirror, with the Connected Side's GitLab as the one gate? If it is only a mirror, mark this ticket `wontfix`.

- [x] A workflow on pull requests runs `tests/all.sh --files` with bash, python3 and PyYAML, and the linters
- [x] The workflow's actions and images are pinned by version
- [x] A PR that breaks a file check shows a failed check

## Comments

**Answer (2026-11-27):** GitHub is the holdover while the work is built at home, until it moves to GitLab at work. PRs merge there in the meantime, so a cheap gate until then.

**Built (2026-11-27):**

- **Decision:** the workflow does not pin its own images. `.github/run-gitlab-job.py JOB` runs a `.gitlab-ci.yml` job's script in that job's image (`docker run`, checkout mounted at `/w`), and `.github/workflows/checks.yml` runs it for `checks`, `shellcheck` and `hadolint`. The images stay pinned once, in `.gitlab-ci.yml`, and `release/update-pins.py` keeps moving them. The only new pin is `actions/checkout` by commit (v7.0.1); PyYAML on the runner is `==6.0.2`, as the checks job.
- The containers run as root over a checkout the runner's user owns, so the helper marks it a git safe directory (`GIT_CONFIG_*`); without it `git ls-files` in `tests/lint.sh` refuses.
- `tests/ci.py` checks, while `.github/workflows/checks.yml` exists, that it runs on pull requests, covers the checks job and every linter in `tests/lint.sh linters`, and pins every action by commit. Seen red with `hadolint` dropped from the matrix.
- Run here (Docker Desktop, from a clone on `C:` because `D:` bind mounts come up empty on this machine): all three jobs pass; with `hadolint` dropped from the matrix the `checks` job exits 1 on `tests/ci.py`. On GitHub (PR #5): all three jobs passed on the first push; a commit dropping `hadolint` from the matrix failed `gitlab-job (checks)` on `tests/ci.py` (run 45915717565), and its revert passed.
- `docs/release-owner-guide.md` "Moving this repository off GitHub" lists what to remove and repoint when the repository moves.
