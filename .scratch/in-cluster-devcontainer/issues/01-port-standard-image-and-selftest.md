# 01: Port the Standard Image and its self-test

**What to build:** A Standard Image built locally from this repository that runs as a non-root user, carries the old image's tools without the Docker CLI, and passes the offline self-test. The self-test is the image seam every later ticket extends.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [ ] The image builds from the ported package lists and root filesystem files, with the Docker CLI and the Docker-outside-of-Docker opt-in removed
- [ ] The image runs as a non-root user with no `sudo` installed
- [ ] The self-test runs with no network and passes
- [ ] The self-test fails if the image tries to run anything as root at start

## Answer

The Standard Image is ported under `image/` (package lists, rootfs, build scripts, Dockerfile) without the Docker CLI, `lazydocker`, the compose plugin or the Docker-outside-of-Docker opt-in. It runs as the non-root user `dev` (1000), has no sudo and no setuid or setgid binaries. `devc-entrypoint` refuses to start as root, and the self-test gained "the container user is not root" and "no process-level capabilities are held" checks. `tests/image.sh` builds the image and drives the self-test from outside with `--network none`. It also checks that the self-test and the entrypoint both fail as root. Verified locally with Docker Desktop: the build succeeds and all 6 cases pass, with the self-test reporting 92 of 92 checks.

Deferred to later tickets: `sshd` (02), the VS Code server and extensions (03), and `kubectl-vsphere` (needs a Supervisor's plugin zip, so it is not in the image yet). The base is `debian:trixie-slim` rather than the old DHI base.

Commits: see `git log` on the branch, "Port the Standard Image and its offline self-test, running as non-root" and the follow-up that records this answer.
