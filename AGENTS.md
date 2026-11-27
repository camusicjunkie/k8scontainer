## Checks

`tests/all.sh` runs every check this machine can run and names the seams it skipped; `tests/all.sh --files` is the fast subset CI gates on. On GitHub, `.github/workflows/checks.yml` runs the same pipeline jobs on each PR until the repository moves to GitLab. Review against `CODING_STANDARDS.md`.

## Prior art

"The old repository" in specs and tickets is the Docker Host devcontainer, checked out at `D:\Docker\devcontainer` (`github.com/camusicjunkie/devcontainer`). Read it; it stays read-only.

"The Gitops repository" is checked out at `D:\Docker\Gitops` (`github.com/camusicjunkie/Gitops`): the clusters' Flux setup and image automation. `tests/kind/up.sh` builds a kind cluster that mirrors its Management Cluster setup (`clusters/management`) for `tests/cluster-live.sh`. Change the checkout only when the task is a Gitops change, on its own branch with its own PR; otherwise read it.

## Agent skills

### Issue tracker

Issues and specs are local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a `Status:` line in each issue file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
