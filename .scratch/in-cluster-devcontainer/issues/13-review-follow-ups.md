# 13: Review follow-ups before merging the integration branch

**What to build:** The fixes from the review of the integration branch and of camusicjunkie/Gitops#3: a CI race, site values committed to Git, a test cluster that didn't match the Management Cluster, and the hardening and docs the review asked for.

**Blocked by:** 10, 12

**Status:** resolved

- [x] A branch pipeline and a tag pipeline on the same commit never share a `candidate` image, so `publish` copies the image its own self-test passed
- [x] No CI job passes a password on a command line
- [x] The image carries OCI version and revision labels, so the Review Packet's "Image labels" section is filled
- [x] The image automation commits only a tag; no Registry host is committed
- [x] The kind cluster matches the Management Cluster: no Kyverno, `harbor-pull` on the default ServiceAccount, the Roster naming the Registry directly
- [x] Docs no longer say Kyverno rewrites the Pods' images on the Management Cluster
- [x] A NetworkPolicy admits SSH only from the shared Gateway and keeps Pods from reaching other Pods
- [ ] **[unverified]** The NetworkPolicy holds on the real Management Cluster's CNI: e2e section 2
- [x] The Roster can pin the Gateway's address (`gatewayAddress`)
- [x] Every network-specific value is a Flux variable from the runtime-facts contract (`tests/site/facts.env`), so the Gitops repository needs no patches
- [ ] **[unverified]** Flux's strict `postBuild` substitution of the runtime facts on the real Management Cluster: e2e section 2
- [ ] **[unverified]** Istio gives the Gateway the pinned address on the real load balancer: e2e section 2
- [x] The readiness probe no longer connects to sshd
- [ ] **[unverified]** The probe, pid file and trust-store ownership in a built image (`tests/image.sh`, `devc-selftest`): e2e section 2
- [x] The StorageClass and size are documented as set once
- [x] Settings outside this repository, and carrying it to another network, are documented
- [ ] **[unverified]** Harbor's tag immutability rule and the Review Packet labels on the real Disconnected Side: e2e section 1

## Answer

Status: resolved (cluster and image behaviour unverified, see below)

**CI.** `CANDIDATE` is `candidate:$CI_COMMIT_SHA-$CI_PIPELINE_ID`. Before, merging and then tagging ran two pipelines on one commit that both pushed `candidate:<sha>`, so `publish` could copy the branch build (MANIFEST version `0.0.0-<sha>`, and with unpinned brew CLIs, not necessarily the image the tag pipeline tested) to the Release tag. Logins read passwords from stdin (`buildah login --password-stdin`, `skopeo login --password-stdin`). `tests/ci.py` checks both.

**Labels.** The final stage sets `org.opencontainers.image.version` and `.revision` from `DEVC_VERSION` and `DEVC_GIT_SHA`, last, so they don't invalidate cached layers. `release/cut.sh` already copied them into the Review Packet, but the image never had them. `tests/release.sh` now builds its source image with the labels and checks the packet lists them.

**Image split.** See ticket 10's comment.

**No Kyverno on kind.** camusicjunkie/Gitops#3 runs no Kyverno on the Management Cluster, so the live seam had been passing under a different admission setup. `tests/kind/up.sh` now installs the Gateway API CRDs and Istio from the Gitops repository's `clusters/management/`, puts `harbor-pull` in `istio-system` and the Devcontainer Namespace (on the default ServiceAccount, as the Gitops ResourceSet does), removes Kyverno left over from an earlier setup, and the Roster names REGISTRY through `tests/kind/flux.yaml`. `tests/cluster-live.sh` checks the Pod's image is the StatefulSet's, unrewritten.

**Decision: NetworkPolicy in this repository, Pod CIDR a runtime fact.** The isolation rules are about the Pods this repository defines, so the policy lives here and `tests/cluster_policy.py` checks it. The one site value, the Pod CIDR excluded from egress, is `${DEVCONTAINER_POD_CIDR:=192.168.0.0/16}` (VKS's default); `tests/kind/flux.yaml` sets kind's `10.244.0.0/16`. Ingress is only from the Pod labelled `gateway.networking.k8s.io/gateway-name: devcontainer`, which Istio puts on the gateway Deployment it generates.

**Gateway address.** The Roster's `gatewayAddress`, `${DEVCONTAINER_GATEWAY_ADDRESS:=none}`, renders `spec.addresses` (type `IPAddress`) unless it is `none`. Without it, a recreated Gateway (an empty Roster renders none) can come back on another IP and break every Workstation's SSH config. The default is `none`, not empty: Flux substitutes after kustomize has dropped the quotes, so an empty value reached the ResourceSet as null and crashed `flux-operator build` (found by rendering the committed Roster from the substituted build, as `tests/cluster.sh` now does).

**Decision: network values are Flux variables, not patches.** The first version had the Gitops Kustomization JSON-patch the Roster, ImageRepository and NetworkPolicy, and replace a placeholder Site Config, which tied the Gitops repository to this one's object paths. Instead, every network-specific value here is a Flux variable named after a runtime fact (`HARBOR_REGISTRY`, `HARBOR_PROJECT`, `DEVCONTAINER_*`), and the Gitops Kustomization only adds `postBuild.substituteFrom: flux-runtime-info`, the same way the rest of the Gitops repository is configured. The contract is the variable names: `tests/site/facts.env` lists them with test values, `tests/repo.py` fails on a variable not listed there (or a listed one not used), `docs/check.sh` on one the README doesn't name, and `tests/site/subst.py` substitutes them strictly in `tests/cluster.sh`. Site Config is `binaryData` from base64 facts, so multi-line values survive substitution. The ImageRepository references `harbor-ca` and `harbor-pull` itself. The Devcontainer Namespace left this directory (now `tests/kind/namespace.yaml`): the Gitops repository owns it, so no delete patch is needed either.

**Readiness.** An exec probe that checks the pid file `devc-sshd` now writes (`/tmp/devc-sshd-<port>.pid`, after sshd listens), not a TCP connection, which sshd logged as a pre-auth disconnect every 10 seconds. The pid file is per port so a `devc-selftest` run inside a live Pod (its throwaway sshd uses another port) can't overwrite it.

**Smaller fixes.** `/var/lib/devc/trust` is owned by `dev`, mode 0755, not 0777. `install.ps1` follows the PoshCode style (parameter descriptions as comments in the param block, a space after the type, no redundant lowercasing of hashtable keys, which are already case-insensitive). The StorageClass and 20Gi size are documented as set once. The Release Owner guide gains "Settings outside this repository" and "Carrying this repository to another network".

**Tests run:** `tests/all.sh --files`, and `tests/cluster.sh` render, kubeconform and policy checks for every sample Roster, all passing. **Not run** (this environment has no image registry access): `tests/image.sh`, `tests/release.sh`, `tests/secrets-klogin.sh`, `tests/kind/up.sh` with `tests/cluster-live.sh`, and the installer's Pester tests (`install.ps1` was parse-checked; its changes are style only). Run those before merging.
