# 12: Docs and end-to-end checklist

**What to build:** Guides for admins and the Release Owner, and the manual end-to-end checklist that gates a Release on the Disconnected Side.

**Blocked by:** 08, 09, 10, 11

**Status:** resolved

- [x] The admin guide covers first connection, Personal Config, the Secrets File, `klogin`, installing a tool into the user area and restarting for a new Release
- [x] The Release Owner guide covers cutting, reviewing, carrying across and importing a Release
- [x] The end-to-end checklist covers connecting through the Gateway with the smartcard, unlocking secrets, `klogin` and a restart with state intact
- [x] Every statement in the docs uses the terms in `GLOSSARY.md`

## Answer

Added `docs/admin-guide.md`, `docs/release-owner-guide.md` and `docs/e2e-checklist.md`, and `docs/check.sh`, which fails on any GLOSSARY.md _Avoid_ term in prose (and a bare "devcontainer"), on any cited repo path that does not exist, and on cited facts (CI variable names, ImagePolicy range, marker, OnDelete) that drift from the code. Seen red on a probe line, then green.

The docs state the gaps rather than hide them: no script builds the Workstation pack (layout documented from `workstation/install.ps1`); the Review Packet lacks Trivy, SBOM and changes-since-last; `kubectl-vsphere` is not in the image; the DHI digest is refreshed per Release; ImageUpdateAutomation lives in the Gitops repository; rollback narrows the ImagePolicy range; removing a Roster entry leaves the PVC; the Secrets File needs the RSA PIV Authentication key (unverified on cards); CA changes apply on restart; CI runner needs user namespaces and `/dev/fuse`; CI variables and protected tag pattern; `candidate` images need a cleanup policy. The e2e checklist marks as `[unverified]` everything tickets 05 to 11 could not prove: the Gateway and Remote-SSH, the smartcard, `klogin` to a real Supervisor and Guest Cluster, OnDelete restart with the PVC intact, the automation rewriting the marker, Kyverno and Pod Security admission, and the Istio ambient path.

Code issues noticed (not changed here): `image/rootfs/etc/bash.bashrc.d/99-personal.sh` reads `/etc/devcontainer/personal/bashrc`, but the Pod mounts Personal Config at `~/.devc/personal`, so the admin's `bashrc` is never loaded; `secrets.bash` messages still say "Rebuild Container" and "docker exec"; `.gitlab-ci.yml` has no login for the `dhi.io` base; nothing grants an admin permission to delete their own Pod, and the docs say so.
