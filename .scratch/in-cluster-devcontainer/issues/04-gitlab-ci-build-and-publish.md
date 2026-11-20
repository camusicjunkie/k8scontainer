# 04: GitLab CI build and publish

**What to build:** A GitLab CI pipeline on the Connected Side that builds the Standard Image with a rootless builder, runs the offline self-test as a gate, and pushes the image to the Connected Harbor when the Release Owner tags a Release.

**Blocked by:** 01

**Status:** resolved

- [x] A push builds the image and runs the self-test; a failing self-test fails the pipeline
- [x] Pushing a Release tag publishes the image to the Connected Harbor under that tag
- [x] No privileged runner or Docker daemon is required
- [x] An untagged push never publishes

## Answer

`.gitlab-ci.yml` has three jobs: `build` (buildah, rootless: vfs storage, chroot isolation) pushes the image to the project's Container Registry as `candidate:<sha>`; `selftest` runs `devc-selftest` inside that exact image as its non-root user and fails the pipeline if it fails; `publish` uses skopeo to copy the same tested image to `$HARBOR_IMAGE:<tag>`. `publish` runs only when the tag matches `^v?\d+\.\d+\.\d+$` and `needs` `selftest`, so an untagged push or a non-Release tag builds and tests but never publishes. Branches with an open MR do not run twice. buildah is used instead of kaniko because the Dockerfile relies on `RUN --mount=type=bind`. There is no dind, no daemon and no `privileged`.

Set `HARBOR_IMAGE`, `HARBOR_USER` and `HARBOR_PASSWORD` (masked, protected) and protect the Release tag pattern so only the Release Owner can create it.

Verified locally: `python3 tests/ci.py` evaluates the rules for a main push, feature branch, MR, Release tags (`v1.2.3`, `2026.11.2`), non-Release tags and branch-with-open-MR, and checks the no-daemon/no-privileged, pinned-image and Harbor-credentials-only-in-publish properties (written red first, then green). GitLab's own CI lint API (gitlab.com) reports the file valid. A small `RUN --mount=type=bind` build succeeded under buildah v1.46.1 in Docker with vfs/chroot.

Not verified (needs a real GitLab runner and Harbor): the full image build under buildah, the registry push/pull of `candidate`, the skopeo copy to Harbor and its credentials, and `devc-selftest` running as the job container (the job has network, unlike `tests/image.sh`'s `--network none`; `tests/image.sh` itself needs Docker and stays a local check). Runner requirement found: buildah failed under Docker's default seccomp profile (unshare denied) and without `/dev/fuse` (it overlays the build context for the bind mounts), so the runner must allow user namespaces and expose `/dev/fuse`. `candidate` images accumulate; add a registry cleanup policy.
