# 02: Make AGENTS.md true again

**What to build:** Every agent reads `AGENTS.md`, and two of its lines no longer hold. It says the kind cluster runs the Gitops repository's Kyverno policies, but kind has run without Kyverno since the Management Cluster dropped it: it now mirrors the Gitops repository's Management Cluster setup. It also says the Gitops checkout is read-only, yet agents have rightly changed it for Gitops work (camusicjunkie/Gitops#3 and #4).

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] The Gitops repository line names the Management Cluster setup that the kind cluster mirrors, and no longer mentions Kyverno policies
- [x] The checkout rule says the Gitops checkout is changed only when the task is a Gitops change, on its own branch with its own PR, and the old repository's checkout stays read-only
- [x] (Optional: drop it if the Release Owner declines) `docs/check.sh` fails when `AGENTS.md` names a path in this repository or a Gitops repository path that does not exist, so the pointer can't go stale again without a check failing
- [x] `tests/all.sh --files` passes

## Comments

- `AGENTS.md`'s Gitops line now names the Management Cluster setup (`clusters/management`) that `tests/kind/up.sh` mirrors, drops Kyverno, and says the Gitops checkout is changed only for a Gitops change, on its own branch with its own PR. The old repository's line says it stays read-only.
- `docs/check.sh` gained check (4): every backticked relative path in `AGENTS.md` must exist. A path whose first segment exists in this repository is checked here; any other is a Gitops repository path, checked in `GITOPS_DIR` or, by default, `Gitops` beside the main checkout (found through `git rev-parse --git-common-dir`, so it works from a worktree). With no checkout (CI) those paths print as SKIP rather than fail. Red first: a probe line citing `tests/kind/nope.sh` and `clusters/nowhere` passed the old check and fails the new one.
- Decision: a Gitops path that shares a first segment with this repository (`docs/`) is checked here, not in Gitops. `AGENTS.md` cites none today.
- Found, not changed: the local Gitops checkout (branch `feat/management-devcontainer`) has no `clusters/management/gatewayapi` or `clusters/management/devcontainer.yaml`, which `tests/kind/up.sh` reads and cites; camusicjunkie/Gitops#3 and #4 are not in it. Pull it before running `tests/kind/up.sh`.
