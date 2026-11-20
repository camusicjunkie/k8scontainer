# 10: Image update flow

**What to build:** When the Release Owner publishes a new Standard Image tag, the Management Cluster's existing image automation updates the Pod spec, and each admin gets the new image only when they restart their own Pod.

**Blocked by:** 07

**Status:** resolved

- [x] A new tag in the Registry updates the Pod spec through the existing image automation
- [x] A running Pod is not restarted by the update
- [x] After an admin restarts their Pod it runs the new image and their volume content is intact
- [x] Rolling back is possible by pinning an earlier tag

## Answer

Status: resolved (cluster restart behaviour unverified, see below)

**Decision: Git-based image automation with a setter marker; this repo ships ImageRepository + ImagePolicy, the existing ImageUpdateAutomation (Gitops repo) does the rewrite.** Decided from the gitops-knowledge skill's image-automation references and the flux-schema-catalog ImagePolicy schema (v1: `spec.policy.semver.range`, `imageRepositoryRef`). The alternative, gitless automation (a `ResourceSetInputProvider` of type `OCIArtifactTag` feeding the ResourceSet), was rejected: the ticket and spec say the Management Cluster's *existing* automation does the update, which is the Git-based kind, and Git then records which tag each side runs, which matters for rollback and the Review Packet trail.

- **Where the marker goes:** the setter cannot sit inside the ResourceSet template (it is a block scalar, not YAML the automation can walk). So the image is one plain `image:` value in the Roster (`manifests/devcontainer/roster.yaml`) carrying `# {"$imagepolicy": "devcontainer:devcontainer-standard"}`, and the template renders `<< inputs.image >>` into every admin's StatefulSet. One image for all admins, one line to rewrite.
- **Policy:** `manifests/devcontainer/image-automation.yaml` has an ImageRepository (Harbor repo, 5m) and an ImagePolicy with `semver: ">=0.1.0"`, which never selects pre-release tags, so only Release tags win. The ImageUpdateAutomation is not added here: it holds the Git credentials and branch, lives in the Gitops repo, and its `update.path` must cover `manifests/devcontainer`. If the registry needs a pull credential, add `secretRef` to the ImageRepository (Secret supplied outside Git).
- **No restart:** the StatefulSet keeps `updateStrategy: OnDelete`; a changed template image reaches a Pod only when its admin deletes/restarts it. Volume claim templates do not change, so the PVC is reused by the recreated Pod.
- **Rollback:** pin an earlier tag by narrowing the policy `range` to that exact version (for example `"0.1.0"`); the automation rewrites the Roster to it. Editing the Roster image alone does not stick, since the automation would move it forward again. Restoring `">=0.1.0"` resumes following Releases. Admins pick the rollback up the same way as an update, by restarting their Pod.

**Tests (cluster seam, `tests/cluster.sh` + `tests/cluster_update.py`, all passing):** marker present and a whole-image `$imagepolicy` setter naming a rendered ImagePolicy; policy is semver, excludes pre-releases, over the same Registry repository as the image; rendering Rosters at `0.2.0` and `0.1.0` (`tests/rosters/one.yaml`, `one-older-tag.yaml`) differs only in the Pod template image, both stay OnDelete, claim templates and all other objects are identical; image CRs pass kubeconform.

**Not verified:** a real restart (new image after an admin deletes their Pod, volume content intact) and the automation actually rewriting the marker. Both need a cluster running the Flux image controllers; no kind/k3d is installed here and the local `docker-desktop` kube context was left alone. OnDelete and PVC survival rest on documented StatefulSet semantics plus the rendered-manifest checks. Covered by the manual end-to-end checklist.
