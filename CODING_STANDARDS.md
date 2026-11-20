# Coding standards

Judgement calls for the reviewer. Anything mechanical is a check in `tests/all.sh --files` instead; this file holds only what no check can decide.

## Decisions

- **ADR citations.** A comment that cites an ADR names a decision that ADR records. Read the ADR before citing it. A decision with no ADR gets no citation, or a new ADR.
- **Departures.** A change that departs from the spec, an ADR, or a pin carried over from the old image (the DHI base, VS Code commit, tool versions) is recorded in its ticket as a decision, with the reason. A departure written up only as a "deviation" note is a finding.

## Domain language

- **Glossary terms in code.** Identifiers, user-facing messages and comments name domain concepts by their `GLOSSARY.md` term (Secrets File, Devcontainer Pod, Release Owner). The literal names of outside tools and of on-disk files that existing data depends on stay as they are (`ansible-vault`, `~/.secrets/vault`). `tests/repo.py` checks comments; identifiers and messages are yours to judge.
- **Current environment.** Text describes the Devcontainer Pod reached over Remote-SSH. Instructions for the retired Docker Host ("Rebuild Container", `docker exec`) are findings.

## Shared values

- **One source for a value two sides depend on.** A path, port or name that both the image and the manifests use (the Pod-side mount paths, the sshd port 2222, `devc-<name>`) is defined once and read from there, or covered by a check in `tests/repo.py`. A new hand-typed copy is a finding.
- **Path prefixes.** New paths use the `devc` prefix (`/etc/devc`, `/var/lib/devc`, `~/.devc`). `/etc/devcontainer` holds only what already lives there (`site`, `release`).
- **Docs facts.** A line in `docs/check.sh` that ties a doc to the code parses the value it checks where it can, so reformatting a manifest does not break it, and its failure message names the doc fact.

## Unverified work

- **Say what was not proven.** Behaviour a ticket could not run (a real cluster, smartcard, Gateway) is marked `[unverified]` in the ticket and has an item in `docs/e2e-checklist.md`. A claim of done with no test or checklist item behind it is a finding.
