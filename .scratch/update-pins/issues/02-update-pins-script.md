# 02: A script that refreshes every exact pin

**What to build:** `release/update-pins.py`, the script in the spec. Run on the Connected Side's Linux Docker host, it looks up the newest upstream version of every exact pin and rewrites the pin files, with each checksum taken from the publisher, leaving a diff to review.

**Blocked by:** 01

**Status:** resolved

- [x] `vscode.env` is rewritten from the VS Code update API: version, commit, and the server, CLI and Windows portable SHA-256s
- [x] `vscode.env` pins Remote-SSH as `VSCODE_REMOTE_SSH_VERSION`, chosen like the extensions
- [x] `vscode-extensions.txt` takes each extension's newest stable version whose engine range accepts the VS Code being written; pre-releases are skipped and a major version jump is flagged
- [x] `DHI_BASE` takes its tag's current digest; `BREW_IMAGE` and `HADOLINT_IMAGE` take their newest non-prerelease GitHub release's tag and its digest, all through `docker buildx imagetools inspect`
- [x] Codex, tflint and pwsh take their newest non-prerelease release, with the SHA-256 from the GitHub release API's asset `digest`
- [x] One group (`vscode`, `extensions`, `dhi`, `brew`, `hadolint`, `codex`, `tflint`, `pwsh`) can be refreshed on its own, leaving the others as they are
- [x] A failed lookup writes nothing and names the pin; a missing `docker buildx` stops an image group before any lookup
- [x] It writes only the pin files: no build, commit or push
- [x] `tests/update-pins.py` tests it against recorded upstream responses, with no network or Docker, and runs in `tests/all.sh --files`
- [x] The Release Owner guide's "Refresh the DHI base digest" and "Check the other pins" steps say to run it on the Docker host, with `docker login dhi.io` and `docker logout dhi.io` around it unless the host has a credential helper

## Comments

**Done (2026-11-26):** `release/update-pins.py` refreshes all eight groups; `tests/update-pins.py` (10 cases, in `tests/all.sh --files`) runs it on fixture pin files (`tests/update-pins/before/`, expected `after/`) against trimmed real recordings from the VS Code update API, the Marketplace, the GitHub release API and `imagetools inspect`. One recorded version is made up (exiasr.hadolint 1.3.0, engine `^1.148.0`) so the engine rule shows: taken with the new VS Code, skipped with the pinned one. A live run on this machine against a copy of the pin files took every pin to the recorded values. The repo's own pins were not bumped; that is the next Release's run.

Decisions beyond the spec:

- **`BREW_IMAGE` moves from `docker.io/homebrew/brew` to `ghcr.io/homebrew/brew`, same tag and digest.** Homebrew stopped pushing to Docker Hub after 4.6.20; its newer releases (7.0.x) are only on ghcr.io, so the `brew` group would always fail against the Docker Hub name. The script keeps each image's repository and moves only its tag and digest. The image is byte-identical (`sha256:b0072bfd…` on both registries).
- **Where each tool comes from is read from the Dockerfile**, not a second table: the release repo, tag form and asset name come from the `ADD --checksum=sha256:${<TOOL>_SHA256} https://github.com/…/releases/download/…` line, and an image's new tag is its old tag with the version replaced (`v2.15.1-debian`).
- **"Newest" is the highest version**, not the first listed: PowerShell lists 7.6.10 after 7.7.0, and Codex lists alphas above stable. GitHub is read 30 releases a page (a page of 100 Codex releases times out), up to five pages until one holds a stable tag.
- **An extension's VSIX must target Linux x64 or no platform** (hashicorp.terraform and timonwong.shellcheck publish one per platform). A version with no `engines.vscode` is skipped.
- `VSCODE_REMOTE_SSH_VERSION=0.128.0` is the newest stable Remote-SSH the pinned VS Code 1.147.0 accepts. The Release Owner guide's Workstation pack table now says the VSIX is that version (ticket 03's guide item); the installer check itself is still ticket 03.
