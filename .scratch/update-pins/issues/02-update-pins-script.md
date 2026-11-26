# 02: A script that refreshes every exact pin

**What to build:** The script in the spec. Run on the Connected Side, it looks up the newest upstream version of every exact pin and rewrites the pin files, with each checksum taken from the publisher, leaving a diff to review.

**Blocked by:** 01

**Status:** needs-triage (the spec's open questions decide the extension and Remote-SSH items)

- [ ] `vscode.env` is rewritten from the VS Code update API: version, commit, and the server, CLI and Windows portable SHA-256s
- [ ] `vscode-extensions.txt` takes each extension's newest version that supports the pinned VS Code
- [ ] `DHI_BASE`, `BREW_IMAGE` and `HADOLINT_IMAGE` take their tags' current digests
- [ ] Codex, tflint and pwsh take their newest release, with the SHA-256 from that release's published checksums
- [ ] One pin can be refreshed on its own, leaving the others as they are
- [ ] It writes only the pin files: no build, commit or push
- [ ] Tested against recorded upstream responses, with no network
- [ ] The Release Owner guide's "Refresh the DHI base digest" and "Check the other pins" steps say to run it
