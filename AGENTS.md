## Checks

`tests/all.sh` runs every check this machine can run and names the seams it skipped; `tests/all.sh --files` is the fast subset CI gates on. Review against `CODING_STANDARDS.md`.

## Prior art

"The old repository" in specs and tickets is the Docker Host devcontainer, checked out read-only at `D:\Docker\devcontainer` (`github.com/camusicjunkie/devcontainer`).

## Agent skills

### Issue tracker

Issues and specs are local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a `Status:` line in each issue file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
