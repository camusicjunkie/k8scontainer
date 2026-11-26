# 03: Gate GitHub PRs on the file checks

**What to build:** A GitHub Actions workflow runs `tests/all.sh --files`, including the linters from ticket 01, on every PR, so nothing merges on GitHub without the checks. PRs #1 and #2 merged on GitHub with no check: the pipeline is GitLab's, and it ran only on the local lab.

**Blocked by:** 01

**Status:** needs-info

**Question for the Release Owner:** is the GitHub repository a gate for changes, or only a mirror, with the Connected Side's GitLab as the one gate? If it is only a mirror, mark this ticket `wontfix`.

- [ ] A workflow on pull requests runs `tests/all.sh --files` with bash, python3 and PyYAML, and the linters
- [ ] The workflow's actions and images are pinned by version
- [ ] A PR that breaks a file check shows a failed check
