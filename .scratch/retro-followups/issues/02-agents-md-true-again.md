# 02: Make AGENTS.md true again

**What to build:** Every agent reads `AGENTS.md`, and two of its lines no longer hold. It says the kind cluster runs the Gitops repository's Kyverno policies, but kind has run without Kyverno since the Management Cluster dropped it: it now mirrors the Gitops repository's Management Cluster setup. It also says the Gitops checkout is read-only, yet agents have rightly changed it for Gitops work (camusicjunkie/Gitops#3 and #4).

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] The Gitops repository line names the Management Cluster setup that the kind cluster mirrors, and no longer mentions Kyverno policies
- [ ] The checkout rule says the Gitops checkout is changed only when the task is a Gitops change, on its own branch with its own PR, and the old repository's checkout stays read-only
- [ ] (Optional: drop it if the Release Owner declines) `docs/check.sh` fails when `AGENTS.md` names a path in this repository or a Gitops repository path that does not exist, so the pointer can't go stale again without a check failing
- [ ] `tests/all.sh --files` passes
