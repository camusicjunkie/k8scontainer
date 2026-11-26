# Spec: Updating the Standard Image's pins

**Status:** needs-triage

## Problem Statement

The Release Owner guide asks for the pins to be refreshed every Release ("Refresh the DHI base digest", "Check the other pins"), but nothing does it. Each exact pin is found, looked up upstream and edited by hand, along with its checksum:

- `image/packages/vscode.env`: the VS Code version, commit, and the server, CLI and Windows portable SHA-256s;
- `image/packages/vscode-extensions.txt`: every extension as `publisher.name@version`;
- `image/Dockerfile`: `DHI_BASE`, `BREW_IMAGE` and `HADOLINT_IMAGE` by digest, and Codex, tflint and pwsh by version and SHA-256.

A stale DHI digest makes apt installs fail, and an old VS Code commit holds back every extension. Worse, the downloaded tools' versions are written twice in the Dockerfile (the `downloads` stage and the final stage), so a bump that changes one copy builds one version while the MANIFEST reports the other, and no check notices.

Everything else floats within a range at build time (brew, Python, pwsh modules, Terraform providers, Packer plugins, Ansible collections, apt) and the MANIFEST records what was resolved, so it is out of scope.

## Solution

One script the Release Owner runs on the Connected Side at the start of a Release. It looks up the newest version of every exact pin upstream, rewrites the pin files with the new versions, digests and checksums, and leaves the change in the working tree for review as an ordinary diff. The Release's own build and self-test are what prove the new pins work. Before that, each downloaded tool's version is defined once in the Dockerfile, and `tests/repo.py` keeps it that way.

## User Stories

1. As the Release Owner, I want one command that refreshes every exact pin, so that a Release starts from current upstream versions without a manual lookup per pin.
2. As the Release Owner, I want each new checksum taken from the upstream publisher, so that I never compute one from a download I can't vouch for.
3. As the Release Owner, I want the result as a diff in the working tree, so that I review and commit it like any other change.
4. As the Release Owner, I want to bump one pin and leave the rest, so that a fix for one tool doesn't drag in every other update.
5. As a maintainer, I want each tool's version written once, so that the image and its MANIFEST can't disagree.

## Implementation Decisions

- The script runs on the Connected Side only: it needs the Internet, as the build does.
- Upstream sources: the VS Code update API (version, commit and SHA-256 per platform), the Visual Studio Marketplace (extension versions), the registries (image digests, for example with `crane digest`), and each tool's GitHub release with its published checksums (Codex, tflint, pwsh).
- It writes only the pin files; it builds nothing, commits nothing and pushes nothing.
- Renovate was considered: it can bump digests and versions, but not the SHA-256s `vscode.env` and the downloaded tools need, and it needs a bot running against the GitLab repository.

## Open Questions

- Does an extension's update stay within its major version, or take the newest? (A major version can drop support for the pinned VS Code.)
- Is the Remote-SSH VSIX, which the Release Owner guide says "is not pinned anywhere in this repository", pinned in `vscode.env` as part of this?
- Bash or PowerShell? The other Connected Side tooling (`release/cut.sh`) is bash.

## Testing Decisions

- `tests/repo.py` fails when a downloaded tool's version is defined more than once in `image/Dockerfile`.
- The script is tested against recorded upstream responses, so the test needs no network: given them, it rewrites the pin files exactly, and it leaves a file untouched when nothing upstream changed.
