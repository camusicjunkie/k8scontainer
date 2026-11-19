# 09: Workstation installer

**What to build:** The Workstation installer sets up the portable VS Code with only Remote-SSH, writes the Gateway host and the admin's port into the SSH config, and keeps the offline settings, so an admin can connect after one run.

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] The installer checks every file against the Release's checksums before writing anything
- [ ] Only the Remote-SSH extension is installed; the Dev Containers extension and `kubectl` are not needed
- [ ] The SSH config gets the Gateway host and the admin's port
- [ ] The portable VS Code matches the commit baked into the image, so Remote-SSH reports no version mismatch
- [ ] It works offline on Windows PowerShell 5.1 and PowerShell 7
