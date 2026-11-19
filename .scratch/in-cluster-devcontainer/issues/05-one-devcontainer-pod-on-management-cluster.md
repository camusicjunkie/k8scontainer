# 05: One Devcontainer Pod on the Management Cluster

**What to build:** A single admin's Devcontainer Pod running the Standard Image in the Devcontainer Namespace, with its State Directory volume and Site Config. An operator can open a shell in it and see the expected tools, trust store and persisted paths. The admin's details are hard-coded; the Roster comes later.

**Blocked by:** 03, 04

**Status:** ready-for-agent

- [ ] The Devcontainer Namespace enforces Pod Security `restricted` and the Pod runs under it
- [ ] The Pod is a one-replica StatefulSet with the `OnDelete` update strategy, pulling the image from the Registry
- [ ] The volume is mounted only at the specific paths the spec lists, and content written there survives a Pod restart
- [ ] Site Config is a read-only ConfigMap and its certificate authorities are trusted in the Pod
- [ ] The manifests pass the cluster seam's schema and policy checks, including the existing Kyverno policies
