# Spec: Updating the Standard Image's pins

**Status:** ready-for-agent

## Problem Statement

The Release Owner guide asks for the pins to be refreshed every Release ("Refresh the DHI base digest", "Check the other pins"), but nothing does it. Each exact pin is found, looked up upstream and edited by hand, along with its checksum:

- `image/packages/vscode.env`: the VS Code version, commit, and the server, CLI and Windows portable SHA-256s;
- `image/packages/vscode-extensions.txt`: every extension as `publisher.name@version`;
- `image/Dockerfile`: `DHI_BASE`, `BREW_IMAGE` and `HADOLINT_IMAGE` by digest, and Codex, tflint and pwsh by version and SHA-256.

The Remote-SSH VSIX the Workstation pack carries is not pinned at all: the guide says to "choose one that works with that VS Code".

A stale DHI digest makes apt installs fail, and an old VS Code commit holds back every extension. Worse, the downloaded tools' versions were written twice in the Dockerfile (the `downloads` stage and the final stage), so a bump that changed one copy built one version while the MANIFEST reported the other, and no check noticed (fixed by ticket 01).

Everything else floats within a range at build time (brew, Python, pwsh modules, Terraform providers, Packer plugins, Ansible collections, apt) and the MANIFEST records what was resolved, so it is out of scope.

## Solution

One script, `release/update-pins.py`, that the Release Owner runs at the start of a Release on the Connected Side's Linux Docker host, in a clone at the Release branch. It looks up the newest version of every exact pin upstream, rewrites the pin files with the new versions, digests and checksums, and leaves the change in the working tree for review as an ordinary diff, committed and pushed from that host. The Release's own build and self-test are what prove the new pins work. Before that, each downloaded tool's version is defined once in the Dockerfile, and `tests/repo.py` keeps it that way.

## User Stories

1. As the Release Owner, I want one command that refreshes every exact pin, so that a Release starts from current upstream versions without a manual lookup per pin.
2. As the Release Owner, I want each new checksum taken from the upstream publisher, so that I never compute one from a download I can't vouch for.
3. As the Release Owner, I want the result as a diff in the working tree, so that I review and commit it like any other change.
4. As the Release Owner, I want to bump one pin and leave the rest, so that a fix for one tool doesn't drag in every other update.
5. As the Release Owner, I want each tool's version written once, so that the image and its MANIFEST can't disagree.
6. As the Release Owner, I want the Remote-SSH version pinned beside the VS Code commit, so that I don't pick one by hand for each Workstation pack.

## Implementation Decisions

- **Language:** Python 3, standard library only, run as `python3 release/update-pins.py [group...]`. The script is mostly JSON lookups and file rewrites, and the repo's file checks already need Python. Bash (`cut.sh`) and PowerShell were considered: bash would need curl, jq and sed and is hard to test against recorded responses, and PowerShell would be the only PowerShell on the Connected Side.
- **Where it runs:** on the Connected Side's Linux Docker host, in a clone of this repository at the Release branch. It needs the Internet, as the build does.
- **Groups:** `vscode`, `extensions`, `dhi`, `brew`, `hadolint`, `codex`, `tflint`, `pwsh`. No argument means all of them. `vscode` refreshes the version, the commit, the three SHA-256s and the Remote-SSH version together. `extensions` refreshes every extension; there is no per-extension selection.
- **VS Code:** the VS Code update API gives the newest stable version, its commit, and the server (`server-linux-x64`), CLI (`cli-alpine-x64`) and Windows portable (`win32-x64-archive`) SHA-256s.
- **Extensions:** each takes its newest stable Marketplace version, for the image's server (a `linux-x64` or universal VSIX), whose engine range (`engines.vscode`) accepts the VS Code being written, read as VS Code itself reads it (a form VS Code refuses is never taken): the new `VSCODE_VERSION` when `vscode` is refreshed in the same run, the pinned one otherwise. Pre-release versions are skipped. A new major version is taken, since the engine range is what protects the pinned VS Code, and is flagged in the output.
- **Remote-SSH:** pinned in `vscode.env` as `VSCODE_REMOTE_SSH_VERSION`, chosen by the same rule as the extensions but for the Workstation's platform (a `win32-x64` or universal VSIX), since it installs on the Workstation's portable VS Code. It is a version only: the Marketplace publishes no SHA-256 for a VSIX, so the VSIX stays checked by the Workstation pack's `SHA256SUMS`. Making the installer refuse a different version is ticket 03.
- **Image digests:** `DHI_BASE` keeps its `trixie-dev` tag and takes the tag's current digest. `BREW_IMAGE` and `HADOLINT_IMAGE` move to their project's newest non-prerelease GitHub release (`Homebrew/brew` as tag `<version>`, `hadolint/hadolint` as tag `v<version>-debian`) and that tag's digest; re-resolving a fixed release tag would almost never change anything. Digests come from `docker buildx imagetools inspect`, which reads the registry with the host's `docker login` (`dhi.io` needs one) and needs no daemon. The script reads no credentials of its own.
- **Downloaded tools:** Codex, tflint and pwsh take their newest non-prerelease GitHub release (a stable `rust-v*` tag for Codex), and each SHA-256 is the `digest` the GitHub release API gives the asset the Dockerfile downloads. Codex publishes no checksum file, so this is the one source all three share.
- **GitHub API:** a full run makes a handful of calls, within the anonymous limit; `GITHUB_TOKEN` is sent when set, never required.
- **Prerequisites:** `docker buildx` is needed only for the `dhi`, `brew` and `hadolint` groups, and a `dhi.io` login (an `auths` or `credHelpers` entry in the Docker config) only for `dhi`. When one of those is selected and it is missing, the script stops before any lookup, naming the group and the fix. The other groups need only Python and the Internet.
- **All or nothing:** every lookup happens before any write. One failed lookup (a rate limit, a release whose image is not pushed yet, a platform missing its SHA-256) writes nothing and names the pin; the Release Owner reruns with the other groups.
- **Output:** one line per changed pin, `old -> new`, major version jumps flagged, then what is still by hand: the Workstation pack's portable VS Code zip and Remote-SSH VSIX for the new pins, and the Release build and self-test. It exits 0 when nothing changed.
- It writes only the pin files; it builds nothing, commits nothing and pushes nothing.
- Renovate was considered: it can bump digests and versions, but not the SHA-256s `vscode.env` and the downloaded tools need, and it needs a bot running against the GitLab repository.

## Release Owner guide

The "Refresh the DHI base digest" and "Check the other pins" steps become one: on the Docker host, in a clone at the Release branch, `docker login dhi.io`, run `python3 release/update-pins.py`, review `git diff`, commit and push, then `docker logout dhi.io`, unless the host keeps credentials in a credential helper (`credsStore` in `~/.docker/config.json`). Without a helper, `docker login` stores the token base64-encoded, in effect plain text, in `~/.docker/config.json`.

## Testing Decisions

- `tests/repo.py` fails when a build arg in `image/Dockerfile` is given a value more than once (ticket 01).
- `tests/update-pins.py` tests the script against recorded upstream responses in `tests/update-pins/`, with the HTTP fetch and the `imagetools` runner replaced, so it needs no network or Docker and runs in `tests/all.sh --files`. Cases: given the recordings, each pin file is rewritten exactly; when nothing upstream changed, every file is left byte-for-byte; one group changes only its own pins; a failed lookup writes nothing; pre-releases and extensions whose engine range rejects the VS Code are skipped; Remote-SSH is chosen for the Workstation's platform; a missing `docker buildx` or `dhi.io` login stops before any lookup; a higher release on a later GitHub page is found.
