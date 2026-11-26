# 05: One Devcontainer Pod on the Management Cluster

**What to build:** A single admin's Devcontainer Pod running the Standard Image in the Devcontainer Namespace, with its State Directory volume and Site Config. An operator can open a shell in it and see the expected tools, trust store and persisted paths. The admin's details are hard-coded; the Roster comes later.

**Blocked by:** 03, 04

**Status:** resolved

- [ ] The Devcontainer Namespace enforces Pod Security `restricted` and the Pod runs under it **[unverified]** (e2e section 2: real admission and Pod startup)
- [x] The Pod is a one-replica StatefulSet with the `OnDelete` update strategy, pulling the image from the Registry
- [x] The volume is mounted only at the specific paths the spec lists, and content written there survives a Pod restart
- [x] Site Config is a read-only ConfigMap and its certificate authorities are trusted in the Pod
- [ ] The manifests pass the cluster seam's schema and policy checks, including the existing Kyverno policies **[unverified]** (e2e section 2: Kyverno policies)

## Answer

Manifests for one hard-coded admin live in `manifests/devcontainer/` (Namespace, Site Config ConfigMap, headless Service, one-replica `OnDelete` StatefulSet with a 20Gi `standard` claim). The cluster seam is `tests/cluster.sh` (+ `tests/cluster_policy.py`): kustomize render, kubeconform against the Kubernetes 1.31 schemas, a Pod Security `restricted` and layout assertion, then the Standard Image started with the Pod security context to check persistence at the six volume paths and Site Config CA trust. All pass.

Not verified without the real Management Cluster: the existing Kyverno policies (the Gitops repo is not available; the static restricted check stands in), the Istio ambient label, StorageClass `standard`, real Pod startup under restricted PSS, the Registry host/tag (placeholder `harbor.example/devcontainer/standard:0.1.0`).

Image finding: `devc-ca-refresh` rejects symlinks, and a ConfigMap directory mount is all symlinks, so Site Config CAs are mounted as single `subPath` files (regular files). They do not update live; a restart picks up changes, which fits `OnDelete`. If live updates or a directory mount are wanted, the image should follow symlinks that resolve inside the mount.
