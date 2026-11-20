# 09: Workstation installer

**What to build:** The Workstation installer sets up the portable VS Code with only Remote-SSH, writes the Gateway host and the admin's port into the SSH config, and keeps the offline settings, so an admin can connect after one run.

**Blocked by:** 06

**Status:** resolved

- [x] The installer checks every file against the Release's checksums before writing anything
- [x] Only the Remote-SSH extension is installed; the Dev Containers extension and `kubectl` are not needed
- [x] The SSH config gets the Gateway host and the admin's port
- [x] The portable VS Code matches the commit baked into the image, so Remote-SSH reports no version mismatch (the installer refuses any commit that differs from `vscode.env`; the real Remote-SSH check is unverified)
- [x] It works offline on Windows PowerShell 5.1 and PowerShell 7

## Answer

Added `workstation/install.ps1`, `workstation/settings.json` and Pester 5 tests in `workstation/tests/install.Tests.ps1` (23 tests, passing under PowerShell 7.6 and Windows PowerShell 5.1).

- **Payload ("pack"):** a folder holding `install.ps1`, `settings.json`, `release.json` (Release version, VS Code version/commit/zip, the one extension), `vscode.env` (a copy of `image/packages/vscode.env`), the portable VS Code zip, the Remote-SSH VSIX and `SHA256SUMS` (sha256sum format, relative paths). No tool builds this pack yet; that is outside this ticket.
- **Verification before any write:** every `SHA256SUMS` line is checked (a missing file, a mismatch or a path leaving the folder aborts), every file the installer uses must be covered by it, the commit and version in `release.json` must equal `vscode.env`, and the zip's hash must equal `VSCODE_WIN_SHA256`. A Release carrying any extension other than Remote-SSH is refused. The SSH config conflict check and the `-From` check also run before the first write.
- **Install:** per-Release portable folder with `data\tmp`, `code.cmd --install-extension` for Remote-SSH only, offline settings merged over carried-forward user data. The old server tarball, Dev Containers settings, `kubectl` and the vSphere plugin are gone. A failed install removes its folder; a rerun for the same Release keeps it.
- **SSH config:** `-GatewayHost` and `-Port` (required) go into a marked `Host <alias>` block (`-HostAlias` default `devcontainer`, `-User` default `dev`, `ForwardAgent yes`), written last, without a BOM. Reruns are byte-identical, a changed port replaces only the block, and a hand-written Host of the same name aborts before anything is written.

Not verified: a real portable VS Code download and a real `code.cmd` (tests use a fake zip and `code.cmd`); that the real Remote-SSH VSIX installs offline without Remote-SSH: Edit and Remote Explorer (not carried, per the ticket); the real Remote-SSH version-mismatch check; a connection through a real Gateway. The generated block was parsed with Windows OpenSSH `ssh -G` by hand.
