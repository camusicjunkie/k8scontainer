# 03: Bake in the VS Code server and extensions, with no runtime root

**What to build:** Remote-SSH connects to a fresh Pod without downloading anything, because the VS Code server and extensions pinned to the Workstation's VS Code commit are already in the image. Anything a normal day needs works without root.

**Blocked by:** 02

**Status:** resolved

- [x] The server and extensions match the commit pinned for the portable VS Code on the Workstation
- [x] Connecting with that VS Code on a network with no Internet needs no download
- [x] A tool installed by the admin into the user-owned tools area is on the `PATH` in new shells
- [x] The self-test proves the server, the extensions and a user-installed tool work with no root

## Answer

The pin lives in `image/packages/vscode.env` (VSCODE_COMMIT, server and CLI SHA-256s, Windows zip SHA-256) and `image/packages/vscode-extensions.txt`. Both are plain text, also shipped in the image under `/usr/local/share/devc/packages/`, and are what the Workstation installer (ticket 09) should read. A new `vscode` Dockerfile stage downloads the server for that commit at build time, checks its SHA-256, extracts it to `~/.vscode-server/bin/<commit>` (where Remote-SSH looks, so attaching downloads nothing) and installs the extensions with it. The tree is owned by `dev`. The MANIFEST gains a `vscode_commit:` header and an `## extensions` section (pins plus resolved dependencies).

The user-owned tools area is `~/.local`, an empty `dev`-owned directory in the image so a volume can be mounted over it. `~/.local/bin` is put on `PATH` by `/etc/profile` (login shells) and `bash.bashrc.d/05-user-tools.sh` (interactive shells).

Self-test drop-ins `22-vscode.sh` and `24-user-tools.sh` check: the server reports the pinned commit and MANIFEST agrees; every pinned extension is installed, listed by the server and on disk; the installed set equals MANIFEST; the server starts (`--start-server`, as Remote-SSH does) with no network; the tree is owned by the user; a tool in `~/.local/bin` is on `PATH` in login and interactive shells. `tests/image.sh` adds a case with `~/.local` as a volume. Red was seen first (8 failing checks on the image without the change).

Verified on Docker Desktop: the build succeeds, `devc-selftest` passes 108 of 108 with `--network none` as `dev`, and every `tests/image.sh` case passes.

Not verified: a real Remote-SSH attach from the portable VS Code on Windows (including that it skips the download for this layout), and the extensions running in a live VS Code session. The server and extensions are fetched at build time, so building needs Marketplace access (the Connected Side). Non-interactive `ssh host cmd` does not read profiles, so the tools area is on `PATH` only in shells. The base image is unchanged.
