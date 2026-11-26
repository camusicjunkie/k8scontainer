# End-to-end checklist: the Disconnected Side

The manual gate for a Release. Run it on the Disconnected Side before a Release is declared good, and again whenever the VS Code commit, the Roster/ResourceSet manifests or the image automation change. `devc-selftest`, `tests/image.sh`, `tests/cluster.sh`, `tests/release.sh`, `tests/secrets-klogin.sh` and the installer's Pester tests cover the parts that need no real cluster, card or Gateway; `tests/cluster-live.sh` runs sections 2, 7, 8 and 9's cluster side on a kind cluster, but not under Istio, real Harbor or the real Management Cluster. This checklist covers what they could not: the Workstation, the Gateway, the smartcard, the Management Cluster and the Devcontainer Pod together, with no Internet. Each item names what it settles; items marked **[unverified]** are the ones the tickets recorded as never having run against the real thing.

Sections 10 and 11 are the exceptions: they run on the Connected Side, section 10 at the start of the Release.

Record the date, the Release version, who ran it, the result of every step and anything odd. A failure blocks the Release until it is fixed.

## Setup

- **Management Cluster** on the Disconnected Side with Flux (including the image controllers and an ImageUpdateAutomation for this repository in the `devcontainer` namespace, pushing to `image-updates` with its own write credential; see the Release Owner guide), no Kyverno, Istio (a gateway only; no mesh is needed) and the Gateway API CRDs, standard channel v1.7.0, and Istio 1.31 or later, as the Gitops repository's `clusters/management/istio.yaml` installs them.
- **Two test admins** on the Roster, with real smartcards, different ports. Call them A and B.
- **A Workstation** with the Windows OpenSSH agent holding the card's keys, and the Release's Workstation pack.
- **Two Releases** already imported (the one under test and the one before it), for sections 7 and 9. Have kubectl access to the Management Cluster for the checks that say so.
- A real Supervisor with a Guest Cluster reachable from the Pod, and a Secrets File credential for it.

## 1. Release arrived intact

- [ ] On a machine with `skopeo`, `sha256sum -c devcontainer-<version>.oci.tar.sha256` passes.
- [ ] `release/import.sh` into the Disconnected Registry succeeds, prints the digest, and the digest equals the one in the Review Packet.
- [ ] Running `release/import.sh` again for the same version refuses with "already exists".
- [ ] **[unverified]** The import works against the real Harbor, with `DEST_CREDS` (authentication and TLS).
- [ ] A corrupted copy of the archive is refused before anything is imported.
- [ ] **[unverified]** Harbor refuses to overwrite a Release tag (the tag immutability rule in the Release Owner guide's "Settings outside this repository"); for example, a `skopeo copy` of any image to an existing Release tag fails.
- [ ] **[unverified]** The Review Packet's "Image labels" section shows this Release's version and commit.

## 2. Admission and provisioning

- [ ] **[unverified]** The Flux Operator reports the ResourceSet `devcontainer` Ready, and the inventory holds, per admin, a StatefulSet, a key list, two Services and a TCPRoute, plus one Gateway.
- [ ] **[unverified]** The Devcontainer Namespace enforces Pod Security `restricted` (label `pod-security.kubernetes.io/enforce=restricted`) and the Pods start under it: `kubectl -n devcontainer get pods` shows `devc-<name>-0` Running with no admission warnings.
- [ ] **[unverified]** The Pods pull the Standard Image from the Registry with no image rewrite (the Management Cluster runs no Kyverno): `kubectl -n devcontainer get pod devc-<name>-0 -o jsonpath='{.spec.containers[0].image}'` is `<Registry>/<project>/devcontainer/standard:<tag>`, and the default ServiceAccount carries `harbor-pull`. If Kyverno is ever added there, its CEL policies apply: the image rewrite mutates only Pods (`MutatingPolicy`, autogen off), and `require-ambient-dataplane` flags the Devcontainer Namespace, which joins no mesh, so exclude it there before that policy moves to `Deny`.
- [ ] **[unverified]** The Roster's `storageClass`, or the cluster's default class when it has none, binds each admin's claim `state-devc-<name>-0`.
- [ ] **[unverified]** The cluster's Gateway API CRDs serve `TCPRoute` at `v1` (what the ResourceSet renders) and istiod is 1.31 or later (`istioctl version`), so the Gateway's listeners accept the TCPRoutes. The gateway Pod `devcontainer-istio` runs in the Devcontainer Namespace under Pod Security `restricted`.
- [ ] **[unverified]** The Gateway is Programmed with one external IP, one listener per admin, and each TCPRoute is Accepted and has resolved refs.
- [ ] **[unverified]** The Kustomization `devcontainer` is Ready with strict substitution: every runtime fact in the README's "Runtime facts" is in `flux-runtime-info`, and no object in the namespace holds a literal `${`.
- [ ] **[unverified]** With `gatewayAddress` set for this network, the Gateway's address is that IP, and its DNS name resolves to it from a Workstation.
- [ ] **[unverified]** The NetworkPolicy holds: from A's Pod, `bash -c ': </dev/tcp/<B's Pod IP>/2222'` fails (no Pod-to-Pod SSH), and so does a connection to any other Pod IP in the cluster; `getent hosts kubernetes.default` still resolves, and a Supervisor, GitLab and Harbor are reachable. The policy's Pod CIDR is this cluster's (`kubectl -n devcontainer get networkpolicy devcontainer-pods -o yaml`).
- [ ] **[unverified]** The readiness probe reads sshd's pid file: `kubectl -n devcontainer describe pod devc-<name>-0` shows the exec probe, the Pod is Ready, and the Pod's log has no pre-auth disconnects every 10 seconds.
- [ ] The Pod has no Kubernetes API credentials: inside the Pod there is no ServiceAccount token under `/var/run/secrets/kubernetes.io`.
- [ ] Adding a Roster entry for a third test admin by merge creates their Pod and listener without a manual step. Removing the entry prunes their Pod, Services, TCPRoute and listener, and leaves their PVC. Delete the PVC by hand afterwards.

## 3. Connect through the Gateway with the smartcard

- [ ] On the Workstation, with no network beyond the Gateway, run `install.ps1 -GatewayHost <gateway> -Port <A's port>` from the pack. It checks the files, installs only Remote-SSH and writes the `Host devcontainer` block. A second run is a no-op.
- [ ] **[unverified]** The portable VS Code is the pack's commit, Remote-SSH installed from the VSIX offline, and the Remote-SSH output shows no version-mismatch complaint.
- [ ] **[unverified]** Remote-SSH: Connect to Host `devcontainer` through the Gateway signs in with A's smartcard (PIN prompt as expected), opens a shell as `dev`, and the log shows no download of a server (the baked-in server is used) and no "select platform" prompt.
- [ ] A's key logs in only to A's port: connecting A's card to B's port is refused.
- [ ] A password login attempt is refused.
- [ ] The Workstation needed no Kubernetes API access to do any of this.
- [ ] **[unverified]** The gateway's TCP path holds a long-lived session (check its idle timeout): leave the session idle for 10 minutes, then use it again, and run a port-forward (`ssh -L`) through it. Record any dropped connection.
- [ ] The Extensions view in the remote window lists the baked-in extensions, and `devc-selftest` passes in the Pod.

## 4. Host key stability

- [ ] Note the host key fingerprint on first connect. After a Pod restart (section 7) the same fingerprint is presented and the Workstation shows no changed-host-key warning.

## 5. Agent forwarding and the Secrets File

- [ ] In a VS Code terminal, `ssh-add -l` lists A's card keys (the agent was forwarded).
- [ ] **[unverified]** Set `DEVC_UNLOCK_KEY` to the fingerprint of the card's PIV Authentication key in `~/.devc/personal/personal.env` and open a new login shell. `secrets init` succeeds with the real card, and its two signatures match (RSA PIV Authentication key). Record the card model and the key used. If it refuses, record the message: that settles whether the design holds on real cards.
- [ ] `secrets edit`, then `secrets view` shows the saved values. `with-secrets -k GITLAB_TOKEN env` shows the value only in that command's output.
- [ ] Removing the card (or disabling the agent forward) makes `secrets view` fail with the "no forwarded SSH agent" or "key isn't in the forwarded agent" message, not a hang or a crash.
- [ ] A's Secrets File cannot be opened with B's card.

## 6. Site Config, Personal Config and klogin

- [ ] **[unverified]** Site Config is the network's, not this repository's placeholder: `kubectl -n devcontainer get configmap site-config -o yaml` shows the values bootstrap wrote (the Gitops repository's `devcontainer_site_env` and `devcontainer_site_ca`, in `binaryData`), and no placeholder CA.
- [ ] Site Config: with the network's CAs in the Site Config ConfigMap, `cat /var/lib/devc/trust/report` lists them as added, and a TLS request to an internal host signed by that CA succeeds.
- [ ] Site Config values (`KLOGIN_SERVERS`, `KLOGIN_NAMESPACES`, `KLOGIN_CLUSTERS`) are visible in a login shell and in `ssh host command`, and a value in `personal.env` overrides one from Site Config.
- [ ] Write an alias into `~/.devc/personal/bashrc` and open a new terminal: the alias works, and still works after a Pod restart.
- [ ] Tab completion of `klogin <Tab>` offers the vSphere Namespaces and `klogin <ns> <Tab>` the Guest Clusters.
- [ ] **[unverified]** `kubectl-vsphere` is present: the Release was built with `SUPERVISOR_HOST`, and `/etc/devcontainer/release` names its version, not `absent`. If it says `absent`, expect `klogin` to fail and record that.
- [ ] **[unverified]** Once the plugin is available, `klogin <vSphere Namespace>` logs in to the real Supervisor and sets the context, and `klogin <vSphere Namespace> <Guest Cluster>` logs in to the real Guest Cluster, using the credentials from the Secrets File. `kubectl get ns` works afterwards, and with the agent not forwarded `klogin` refuses with a clear message.
- [ ] Installing a tool: `mkdir -p ~/.local/bin`, copy in a binary, and it is on `PATH` in a new terminal.

## 7. Restart with state intact (OnDelete)

- [ ] Before restarting, leave markers: a file in `~/workspace`, a login in `~/.kube`, the Secrets File, a line in `personal.env` and the tool from section 6. Note the Pod's image (`kubectl -n devcontainer get pod devc-<name>-0 -o jsonpath='{.spec.containers[0].image}'`).
- [ ] `kubectl -n devcontainer delete pod devc-<name>-0`. The StatefulSet recreates it, and it reuses the same PVC (`kubectl -n devcontainer get pvc`).
- [ ] After reconnecting every marker is intact: workspace file, cluster login, Secrets File (still unlocks), Personal Config, the installed tool, and the same host key fingerprint.
- [ ] Anything written outside the six volume paths (for example a file in `/tmp` or `~/note`) is gone. This is expected.
- [ ] B's Pod was not restarted by A's restart.

## 8. Update to a new Release, then rollback

- [ ] **[unverified]** With Release N running, push Release N+1's tag to the Connected Harbor and import it on the Disconnected Side. Within the scan interval, the ImageRepository lists the new tag and the ImagePolicy selects it.
- [ ] **[unverified]** The ImageUpdateAutomation rewrites only the marked `imageTag` in `roster.yaml` on the `image-updates` branch (no Registry host appears in the commit), and the StatefulSet is unchanged until that merge request is merged. After the merge Flux applies it and the StatefulSet's Pod template shows the new image.
- [ ] **[unverified]** Running Pods were **not** restarted by the change (`kubectl -n devcontainer get pods` shows unchanged ages and the old image on A's Pod).
- [ ] After A restarts the Pod, it runs the new image and the section 7 markers are intact. B, who did not restart, still runs the old image.
- [ ] If the new Release carries a new VS Code commit: the old Workstation pack's VS Code gets a mismatch, and the new pack's `install.ps1 -From <old folder>` fixes it and carries settings forward.
- [ ] **Rollback:** narrow the ImagePolicy `range` to the exact earlier version, merge, and confirm the automation rewrites the Roster to it on `image-updates`; merge that. After A restarts, the Pod runs the earlier image with state intact. Restore `">=0.1.0"` and confirm it moves forward again.
- [ ] Changing a certificate authority in Site Config does not change running Pods; after a restart the Pod trusts the new CA.

## 9. Limits and failure checks

- [ ] A Pod exceeding its memory limit is OOM-killed and restarts without losing the volume (try with a deliberately heavy command), and a Roster `resources` override for one admin shows in their Pod only.
- [ ] A Roster entry with a duplicate port is rejected or fails the ResourceSet visibly (record exactly what happens, since one bad entry affects all admins), then is reverted.
- [ ] The Pod cannot reach the Kubernetes API with credentials (none are mounted), and A's session cannot read B's volume paths.
- [ ] No Internet is needed anywhere above: the VS Code server, extensions and Release came from the image and the Registry.

## 10. Connected Side: refreshing the pins

Run at the start of the Release, on the Connected Side, before the build the sections above test.

- [ ] **[unverified]** On the Connected Side's Linux Docker host, in a clone at the Release branch, `python3 release/update-pins.py` after `docker login dhi.io` refreshes every group, including `dhi`'s digest through `docker buildx imagetools inspect`, and leaves only the pin files changed in `git diff`. It has run only on a Windows development machine.
- [ ] **[unverified]** The `dhi.io` login check matches that host: after `docker login dhi.io` (with a credential helper, if the host has one) the `dhi` group passes the check; after `docker logout dhi.io`, `python3 release/update-pins.py dhi` stops before any lookup and names `docker login dhi.io`. The check reads `auths` and `credHelpers` in `~/.docker/config.json` (or `$DOCKER_CONFIG`), on the understanding that `docker login` writes an `auths` entry even when `credsStore` keeps the secret.
- [ ] **[unverified]** The pipeline's `build` job pulls `BREW_IMAGE` from `ghcr.io` (buildah, no login for `ghcr.io`), now that the pin has moved there from Docker Hub.

## 11. The pipeline's linter jobs

On the Connected Side's GitLab, not the Disconnected Side: `tests/ci.py` checks the `shellcheck` and `hadolint` jobs in `.gitlab-ci.yml`, but they have only run in local Docker, never on the real runner. Run this once, and again when either job's image or `tests/lint.sh` changes.

- [ ] **[unverified]** A pipeline on any branch runs `shellcheck` and `hadolint` in stage `test`, both green. The `shellcheck` log shows `apk add` installing git, the `ok` line from `tests/lint-scripts.sh`, and `shellcheck 0.10.0 on <n> scripts`, where `<n>` equals `sh tests/lint.sh scripts | wc -l` on that commit. The `hadolint` log shows `hadolint 2.15.1 on image/Dockerfile`, the release `image/Dockerfile`'s `HADOLINT_IMAGE` pins.
- [ ] **[unverified]** Each job fails its pipeline on a finding: on a scratch branch, add `local x=$(false)` inside a function of any bash script (shellcheck SC2155, a warning) and `RUN cd /tmp` to `image/Dockerfile` (hadolint DL3003). Both jobs go red. Delete the branch afterwards.

## Done

Record the results with the Release. Any failure blocks the Release until it is fixed (as the next version if the fix changes the Release). Items that stayed unverified because the capability does not exist yet (the `kubectl-vsphere` plugin) are recorded as known gaps, not passes.
