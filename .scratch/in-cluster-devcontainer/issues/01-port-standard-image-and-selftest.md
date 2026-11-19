# 01: Port the Standard Image and its self-test

**What to build:** A Standard Image built locally from this repository that runs as a non-root user, carries the old image's tools without the Docker CLI, and passes the offline self-test. The self-test is the image seam every later ticket extends.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] The image builds from the ported package lists and root filesystem files, with the Docker CLI and the Docker-outside-of-Docker opt-in removed
- [ ] The image runs as a non-root user with no `sudo` installed
- [ ] The self-test runs with no network and passes
- [ ] The self-test fails if the image tries to run anything as root at start
