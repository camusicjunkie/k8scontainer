# 03: Bake in the VS Code server and extensions, with no runtime root

**What to build:** Remote-SSH connects to a fresh Pod without downloading anything, because the VS Code server and extensions pinned to the Workstation's VS Code commit are already in the image. Anything a normal day needs works without root.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] The server and extensions match the commit pinned for the portable VS Code on the Workstation
- [ ] Connecting with that VS Code on a network with no Internet needs no download
- [ ] A tool installed by the admin into the user-owned tools area is on the `PATH` in new shells
- [ ] The self-test proves the server, the extensions and a user-installed tool work with no root
