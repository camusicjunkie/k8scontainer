# 03: The Workstation installer checks the Remote-SSH pin

**What to build:** `workstation/install.ps1` refuses a Workstation pack whose `release.json` Remote-SSH version is not `VSCODE_REMOTE_SSH_VERSION` in `vscode.env`, as it already refuses a VS Code commit or version that differs. Today it checks only that the one extension is Remote-SSH, and the Release Owner guide says to choose a version by hand.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] `install.ps1` refuses, before any write, a `release.json` whose `ms-vscode-remote.remote-ssh` version differs from `VSCODE_REMOTE_SSH_VERSION`, naming both versions
- [ ] A Pester case in `workstation/tests` covers the refusal, and the existing cases pass with the pin
- [ ] The Release Owner guide's Workstation pack table says the Remote-SSH VSIX is the version pinned in `vscode.env`
