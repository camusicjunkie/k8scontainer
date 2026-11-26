# 01: Lint the shell scripts and the Dockerfile in the checks

**What to build:** shellcheck and hadolint run as checks, locally through `tests/all.sh` and in the pipeline, so a lint finding fails a change instead of waiting for someone to run them by hand. Today nothing runs either: the PR #2 review ran shellcheck by hand, and the Dockerfile's `# hadolint ignore=` comments are read by no check.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] shellcheck runs at warning severity on every shell script in the repository, including the extensionless scripts in the image's root filesystem (found by their shebang, not their name)
- [ ] hadolint runs on the Standard Image's Dockerfile, at the same version the Dockerfile's `HADOLINT_IMAGE` pins (older versions reject `ADD --checksum`); the version is read from that pin, not typed again
- [ ] In `tests/all.sh`, each linter is a seam that runs when its tool is present and reports SKIP otherwise, as the other seams do
- [ ] The pipeline runs both linters in its `checks` stage from pinned images, so CI never skips them
- [ ] Every current finding is fixed, or ignored inline with its reason. On 2026-11-26 shellcheck 0.10.0 reported 15 warnings (SC2034, SC2120, SC2154, SC2155, SC2206) and hadolint 2.15.1 reported DL3066
- [ ] `tests/all.sh --files` passes

## Comments

**Sizing (2026-11-26):** shellcheck at its default severity also reported about 70 notes, most of them SC2317 "unreachable command" for functions that are called indirectly. That is why the gate is at warning severity.
