# 01: Lint the shell scripts and the Dockerfile in the checks

**What to build:** shellcheck and hadolint run as checks, locally through `tests/all.sh` and in the pipeline, so a lint finding fails a change instead of waiting for someone to run them by hand. Today nothing runs either: the PR #2 review ran shellcheck by hand, and the Dockerfile's `# hadolint ignore=` comments are read by no check.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] shellcheck runs at warning severity on every shell script in the repository, including the extensionless scripts in the image's root filesystem (found by their shebang, not their name)
- [x] hadolint runs on the Standard Image's Dockerfile, at the same version the Dockerfile's `HADOLINT_IMAGE` pins (older versions reject `ADD --checksum`); the version is read from that pin, not typed again
- [x] In `tests/all.sh`, each linter is a seam that runs when its tool is present and reports SKIP otherwise, as the other seams do
- [x] The pipeline runs both linters in its `checks` stage from pinned images, so CI never skips them
- [x] Every current finding is fixed, or ignored inline with its reason. On 2026-11-26 shellcheck 0.10.0 reported 15 warnings (SC2034, SC2120, SC2154, SC2155, SC2206) and hadolint 2.15.1 reported DL3066
- [x] `tests/all.sh --files` passes

## Comments

**Sizing (2026-11-26):** shellcheck at its default severity also reported about 70 notes, most of them SC2317 "unreachable command" for functions that are called indirectly. That is why the gate is at warning severity.

**Built (2026-11-26):**

- `tests/lint.sh shellcheck|hadolint` is the seam. It is POSIX sh so the pipeline runs it straight from the linters' own images (alpine and debian, no bash). A shell script is a `*.sh` file or a file whose first line is an `sh`/`bash` shebang: 38 scripts today, including the ten in `image/rootfs/usr/local/bin`.
- shellcheck runs with `--external-sources --source-path=SCRIPTDIR`, so the scripts' existing `# shellcheck source=` directives resolve. That alone cleared the three SC2154 (`failed` is assigned in the sourced `tests/lib.sh`).
- hadolint: `tests/lint.sh` reads the release from `HADOLINT_IMAGE`'s tag and fails if the installed hadolint is another release. The pipeline's `hadolint` job uses the same image reference; GitLab cannot read a Dockerfile ARG, so `tests/ci.py` checks the job's image equals the `HADOLINT_IMAGE` pin instead of a second hand-typed copy going unchecked.
- `tests/all.sh` runs both linters (outside `--files`) when installed, SKIP otherwise. The pipeline has `shellcheck` and `hadolint` jobs in the `test` stage beside `checks` (`needs: []`), and `publish` now needs both. `tests/ci.py` checks the jobs exist on every ref, run `tests/lint.sh`, share the checks' stage, gate `publish`, and that the shellcheck image is pinned by digest.
- **Decision (Dockerfile):** DL3066 is fixed, not ignored: the final stage is `USER 1000:1000` instead of `USER dev`, so a kubelet can verify `runAsNonRoot` from the image alone. Same user (dev is 1000:1000), and the ResourceSet already sets `runAsUser: 1000`.
- Fixes: unused loop counters renamed `_` (SC2034); `pod_ready` lost the timeout parameter no caller passed (SC2120); `local`/`export` with a command substitution split into declare then assign (SC2155); the volume names in `tests/secrets-klogin.sh` quoted (SC2206).
- Run here: shellcheck 0.10.0 (`koalaman/shellcheck-alpine:v0.10.0`, the release the image's apt ships) and hadolint 2.15.1 (the `HADOLINT_IMAGE` digest) both clean, run in Docker with the tree piped in by tar. `tests/all.sh --files` passes. The new jobs have not run on a GitLab runner.
