# 03: The Workstation installer checks the Remote-SSH pin

**What to build:** `workstation/install.ps1` refuses a Workstation pack whose `release.json` Remote-SSH version is not `VSCODE_REMOTE_SSH_VERSION` in `vscode.env`, as it already refuses a VS Code commit or version that differs. Today it checks only that the one extension is Remote-SSH, and the Release Owner guide says to choose a version by hand.

**Blocked by:** 02

**Status:** resolved

- [x] `install.ps1` refuses, before any write, a `release.json` whose `ms-vscode-remote.remote-ssh` version differs from `VSCODE_REMOTE_SSH_VERSION`, naming both versions
- [x] A Pester case in `workstation/tests` covers the refusal, and the existing cases pass with the pin
- [x] The Release Owner guide's Workstation pack table says the Remote-SSH VSIX is the version pinned in `vscode.env`

## Comments

**Done (2026-11-26):** `install.ps1` compares the one extension's `version` with `VSCODE_REMOTE_SSH_VERSION` right after the Remote-SSH id check, before the SSH config or any folder is touched, and the message names both versions. The Pester fixture pack now pins `VSCODE_REMOTE_SSH_VERSION=1.2.3`; the new case pins 1.2.4 and checks the refusal and that nothing was written. 24 cases pass under pwsh 7 and Windows PowerShell 5.1. The guide's table line was already done in ticket 02; this ticket added the new refusal to the guide's list of what the installer refuses.
