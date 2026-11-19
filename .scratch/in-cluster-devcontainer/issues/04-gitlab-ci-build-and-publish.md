# 04: GitLab CI build and publish

**What to build:** A GitLab CI pipeline on the Connected Side that builds the Standard Image with a rootless builder, runs the offline self-test as a gate, and pushes the image to the Connected Harbor when the Release Owner tags a Release.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] A push builds the image and runs the self-test; a failing self-test fails the pipeline
- [ ] Pushing a Release tag publishes the image to the Connected Harbor under that tag
- [ ] No privileged runner or Docker daemon is required
- [ ] An untagged push never publishes
