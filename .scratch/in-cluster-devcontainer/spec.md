# Spec: In-cluster devcontainer

**Status:** ready-for-agent

## Problem Statement

Admins do Kubernetes and infrastructure work from a devcontainer that runs on a shared Linux Docker Host reached with Remote-SSH. That makes the Docker Host a machine to patch, give root and `docker` group access on, and keep in step with every Release by hand. Its design also assumes a Docker daemon, a Docker group and per-user home directories on the host. The platform already runs Kubernetes with Flux, Harbor and Istio, so the devcontainer should live there, without giving teammates who are not cluster admins any access to the Kubernetes API.

## Solution

Each admin gets their own long-lived Devcontainer Pod in the Devcontainer Namespace on the Management Cluster, running the Standard Image from the Registry. The admin connects from the Workstation with Remote-SSH to the Pod's non-root `sshd`, exposed through one shared Gateway IP with a TCP port per admin. Only the smartcard public key recorded for them in the Roster is accepted, and the forwarded smartcard agent still unlocks their Secrets File. The Roster in Git drives a Flux `ResourceSet` that provisions each admin's Pod and State Directory volume. A new Release reaches the Pod spec through the existing image automation, and each admin restarts their own Pod when ready. Nothing in the Pod needs root at runtime.

## User Stories

1. As an admin, I want my own Devcontainer Pod that keeps running between sessions, so that my work and shell state are still there when I come back.
2. As an admin, I want to connect with Remote-SSH from my Workstation, so that I use the same workflow I use today.
3. As an admin, I want to sign in with my smartcard key, so that I never manage a password for the Pod.
4. As an admin, I want the smartcard agent forwarded into the Pod, so that my Secrets File unlocks only when my card is present.
5. As an admin, I want my Secrets File, cluster logins, workspace and Personal Config to survive a Pod restart, so that a Release update never costs me my setup.
6. As an admin, I want to restart my Pod on my own schedule after a new Release arrives, so that an update never interrupts me mid-task.
7. As an admin, I want to install a missing tool into my own user area without root, so that I can keep working while the Release Owner adds it to the image.
8. As an admin, I want tools I installed myself to persist across restarts, so that I do not reinstall them every Release.
9. As an admin, I want `klogin` to log me in to a Supervisor or Guest Cluster from inside the Pod, so that my daily work is unchanged.
10. As an admin, I want shell tab completion for configured vSphere Namespaces and Guest Clusters, so that I log in quickly.
11. As an admin, I want the VS Code server and extensions already in the image, so that attaching downloads nothing on the Disconnected Side.
12. As an admin, I want the same Standard Image on both networks, so that what works on the Connected Side works on the Disconnected Side.
13. As an admin, I want my site's certificate authorities trusted automatically, so that internal TLS works without manual steps.
14. As an admin, I want to raise my own CPU or memory limit through the Roster, so that a heavy task is not throttled.
15. As an admin, I want a clear message when my agent is not forwarded, so that I know why my secrets will not unlock.
16. As a teammate who is not a cluster admin, I want to use my devcontainer with no access to the Kubernetes API, so that the team need not widen cluster access for tooling.
17. As a Release Owner, I want to decide when a Release is cut, so that admins only receive reviewed changes.
18. As a Release Owner, I want a Release to be an image archive plus a checksum, so that it crosses the air gap as a small, verifiable set of files.
19. As a Release Owner, I want a Review Packet generated with each Release, so that the transfer process has the evidence it needs.
20. As a Release Owner, I want pushing a Release tag to the Connected Harbor to be the gate, so that nothing reaches Pods until I choose.
21. As a Release Owner, I want the image built in CI with its self-test as a gate, so that a broken image never reaches a Registry.
22. As a Release Owner, I want to import a Release into the Disconnected Harbor with a checksum check, so that I know the image is intact.
23. As a platform maintainer, I want to add an admin by merging a Roster entry, so that provisioning needs no manual cluster work.
24. As a platform maintainer, I want to remove an admin by removing their Roster entry, so that their access ends with the merge.
25. As a platform maintainer, I want each admin's Pod, volume, key list and port generated from the Roster, so that no per-admin manifest is hand-written.
26. As a platform maintainer, I want the Devcontainer Namespace to enforce Pod Security `restricted`, so that no Pod can gain privileges.
27. As a platform maintainer, I want the Pods to work with the existing Kyverno policies and the Istio ambient label, so that they follow platform rules.
28. As a platform maintainer, I want Site Config rendered per network from the existing runtime facts, so that no organization-specific value is committed to Git.
29. As a platform maintainer, I want one Gateway IP with a port per admin, so that I do not need an IP address for every admin.
30. As a platform maintainer, I want each Pod's `sshd` host key kept on the admin's volume, so that Remote-SSH does not warn about a changed host key after a restart.
31. As a Workstation owner, I want the installer to need only Remote-SSH, so that I no longer need `kubectl`, the vSphere plugin or the Dev Containers extension.
32. As a Workstation owner, I want the installer to write the Gateway host and the admin's port into the SSH config, so that connecting needs no manual editing.
33. As a Workstation owner, I want the portable VS Code to match the server baked into the image, so that Remote-SSH never refuses a version mismatch.
34. As a security reviewer, I want the Pod to run as a non-root user with all capabilities dropped, so that a compromised session cannot escalate.
35. As a security reviewer, I want `sshd` to accept only the Roster's keys and no passwords, so that the Pod has no weaker login path.
36. As a security reviewer, I want one admin's Pod, volume and Secrets File unreachable to another admin's session, so that admins stay separate.

## Implementation Decisions

- The design is recorded in two ADRs: admins reach the Pod over `sshd` (not `kubectl exec`), and one long-lived Pod per admin on the Management Cluster with no runtime root.
- **Standard Image:** ported from the old devcontainer repo, minus the Docker CLI and the Docker-outside-of-Docker opt-in. It runs as a non-root user, includes a non-root `sshd` on a high port, and bakes in the VS Code server and extensions pinned to the portable VS Code commit used on the Workstation.
- **`sshd`:** accepts only the public keys mounted from the Roster, as the image's one user. It allows agent forwarding and TCP forwarding (Remote-SSH needs both), disables passwords, and reads its host key from a path on the admin's volume. The host key is created once, on first start.
- **Volume layout:** one volume per admin, default 20Gi on the `standard` StorageClass, mounted only at specific paths: workspace, cluster logins, Secrets File, Personal Config, host keys and a user-owned tools area. The rest of the home directory comes from the image, so every Release refreshes the baked-in server, extensions and dotfiles.
- **Pod shape:** a StatefulSet of one replica per admin with the `OnDelete` update strategy. Requests are modest (about 250m CPU, 512Mi memory) and limits generous (about 2 CPU, 4Gi), overridable per admin in the Roster.
- **Namespace:** one Devcontainer Namespace on the Management Cluster enforcing Pod Security `restricted`. Pods run non-root, with all capabilities dropped, no privilege escalation and the default seccomp profile, compatible with the existing Kyverno policies and Istio ambient labelling.
- **Exposure:** one shared Gateway IP on the Management Cluster with one TCP listener port per admin, taken from the Roster. This assumes a small team (roughly 20 admins or fewer).
- **Roster:** a list in Git with, per admin, a name, a smartcard PIV Authentication public key, a port and optional resource overrides. A Flux `ResourceSet` generates each admin's StatefulSet, volume, key list, Service and Gateway route.
- **Site Config:** a read-only ConfigMap per network, rendered by Flux from the network's runtime facts (for example certificate authorities and the Supervisor addresses used by `klogin`). Personal Config, Secrets File, cluster logins and workspace live on the admin's volume.
- **Secrets:** unchanged from the old design. The Secrets File is an `ansible-vault` file unlocked by an SSH agent signature from the card's RSA PIV Authentication key.
- **Updates:** the existing image automation on the Management Cluster watches the Standard Image's tags in the Registry. A new tag changes the Pod spec; each admin restarts their own Pod when ready.
- **Releases:** the Release Owner builds an image in GitLab CI on the Connected Side with a rootless builder, gated by the offline self-test, and tags it. A Release is an OCI archive plus a checksum. On the Disconnected Side it is loaded into that side's Harbor with `skopeo`. The Review Packet accompanies it.
- **Workstation:** the installer needs only the Remote-SSH extension. It writes the Gateway host and the admin's port into the SSH config and keeps the offline VS Code settings. `kubectl`, the vSphere plugin and the Dev Containers extension are no longer needed.
- **Repository:** the image sources and the manifests both live in this repository for now. Moving the manifests into the Gitops repository can follow later.

## Testing Decisions

- A good test checks external behaviour only: what an admin or operator can observe from outside the image or cluster, never how a script or manifest is written.
- **Image seam:** the Standard Image's self-test run against the built image with no network, as a non-root user. It covers the baked-in tools, trust store handling, the VS Code server and extensions, `sshd` behaviour (key-only login, agent and TCP forwarding enabled), the user-owned tools area, and the absence of any need for root. Prior art: the self-test scripts in the old devcontainer repository.
- **Cluster seam:** the manifests rendered for a sample Roster are validated against the Kubernetes and Flux schemas and the repository's Kyverno policies, and checked for Pod Security `restricted` compliance. Prior art: the Gitops repository's validation scripts.
- **End-to-end checklist:** a manual gate run on the Disconnected Side. An admin Remote-SSHes through the Gateway with the smartcard, unlocks their Secrets File, runs `klogin` to a Guest Cluster, restarts their Pod and finds their state intact. Prior art: the old repository's e2e checklist.
- No separate unit tests for individual scripts beyond what the two seams already exercise.

## Out of Scope

- Moving the manifests into the Gitops repository.
- Backups of admin volumes. Workspaces live in Git and the Secrets File can be re-issued.
- Any support for IDEs other than VS Code.
- Giving admins cluster-level access to the Management Cluster.
- Docker-outside-of-Docker and building container images inside the Pod; image builds belong in CI.
- A migration or cutover plan for admins currently on the Docker Host.
- Teams larger than roughly 20 admins, which would need an IP per admin or a different exposure design.

## Further Notes

- Vocabulary follows `GLOSSARY.md`, and the decisions are in `docs/adr/`.
- The smartcard key must be RSA and the PIV Authentication key, as ADR 0002 of the old repository established. That is still unverified on real cards.
- The Management Cluster now hosts admin tooling alongside platform automation, so an outage there takes both down.
