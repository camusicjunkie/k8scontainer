# 02: A script that refreshes every exact pin

**What to build:** `release/update-pins.py`, the script in the spec. Run on the Connected Side's Linux Docker host, it looks up the newest upstream version of every exact pin and rewrites the pin files, with each checksum taken from the publisher, leaving a diff to review.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] `vscode.env` is rewritten from the VS Code update API: version, commit, and the server, CLI and Windows portable SHA-256s
- [ ] `vscode.env` pins Remote-SSH as `VSCODE_REMOTE_SSH_VERSION`, chosen like the extensions
- [ ] `vscode-extensions.txt` takes each extension's newest stable version whose engine range accepts the VS Code being written; pre-releases are skipped and a major version jump is flagged
- [ ] `DHI_BASE` takes its tag's current digest; `BREW_IMAGE` and `HADOLINT_IMAGE` take their newest non-prerelease GitHub release's tag and its digest, all through `docker buildx imagetools inspect`
- [ ] Codex, tflint and pwsh take their newest non-prerelease release, with the SHA-256 from the GitHub release API's asset `digest`
- [ ] One group (`vscode`, `extensions`, `dhi`, `brew`, `hadolint`, `codex`, `tflint`, `pwsh`) can be refreshed on its own, leaving the others as they are
- [ ] A failed lookup writes nothing and names the pin; a missing `docker buildx` stops an image group before any lookup
- [ ] It writes only the pin files: no build, commit or push
- [ ] `tests/update-pins.py` tests it against recorded upstream responses, with no network or Docker, and runs in `tests/all.sh --files`
- [ ] The Release Owner guide's "Refresh the DHI base digest" and "Check the other pins" steps say to run it on the Docker host, with `docker login dhi.io` and `docker logout dhi.io` around it unless the host has a credential helper
