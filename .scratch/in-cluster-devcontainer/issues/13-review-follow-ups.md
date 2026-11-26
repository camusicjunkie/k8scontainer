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
- [x] The pid file's path is built in one place in the image (`devc-ready`), not typed into the manifest
- [x] `tests/cluster_policy.py` fails on a Roster whose keys aren't the ones the ResourceSet reads (a Roster kept from another network in an older format)
- [x] The spec matches the Management Cluster: no Kyverno, no Istio mesh (Story 27, the cluster seam), and Story 16 says what "no access to the Kubernetes API" means
- [x] The merge order with camusicjunkie/Gitops#4 is recorded
- [x] `devc-ready`, the pid file, the trust store's ownership and the OCI labels in a built image (`tests/image.sh`, `devc-selftest`)
- [ ] **[unverified]** The readiness probe on the real Management Cluster: e2e section 2
- [x] The StorageClass and size are documented as set once
- [x] Settings outside this repository, and carrying it to another network, are documented
- [ ] **[unverified]** Harbor's tag immutability rule and the Review Packet labels on the real Disconnected Side: e2e section 1

## Answer

Status: resolved (cluster and image behaviour unverified, see below)

**CI.** `CANDIDATE` is `candidate:$CI_COMMIT_SHA-$CI_PIPELINE_ID`. Before, merging and then tagging ran two pipelines on one commit that both pushed `candidate:<sha>`, so `publish` could copy the branch build (MANIFEST version `0.0.0-<sha>`, and with unpinned brew CLIs, not necessarily the image the tag pipeline tested) to the Release tag. Logins read passwords from stdin (`buildah login --password-stdin`, `skopeo login --password-stdin`). `tests/ci.py` checks both.

**Labels.** The final stage sets `org.opencontainers.image.version` and `.revision` from `DEVC_VERSION` and `DEVC_GIT_SHA`. `release/cut.sh` already copied them into the Review Packet, but the image never had them. `tests/release.sh` now builds its source image with the labels and checks the packet lists them.

**Image split.** See ticket 10's comment.

**No Kyverno on kind.** camusicjunkie/Gitops#3 runs no Kyverno on the Management Cluster, so the live seam had been passing under a different admission setup. `tests/kind/up.sh` now installs the Gateway API CRDs and Istio from the Gitops repository's `clusters/management/`, puts `harbor-pull` in `istio-system` and the Devcontainer Namespace (on the default ServiceAccount, as the Gitops ResourceSet does), removes Kyverno left over from an earlier setup, and the Roster names REGISTRY through `tests/kind/flux.yaml`. `tests/cluster-live.sh` checks the Pod's image is the StatefulSet's, unrewritten. **Decision: the spec follows.** Story 27 and the cluster seam in `spec.md` named the Kyverno policies and Istio ambient labelling; they now name the Management Cluster's admission setup (Pod Security `restricted`, no Kyverno, no mesh). No ADR: it is easy to reverse, and this ticket records why.

**Decision: NetworkPolicy in this repository, Pod CIDR a runtime fact.** The isolation rules are about the Pods this repository defines, so the policy lives here and `tests/cluster_policy.py` checks it. The one site value, the Pod CIDR excluded from egress, is `${DEVCONTAINER_POD_CIDR:=192.168.0.0/16}` (VKS's default); `tests/kind/flux.yaml` sets kind's `10.244.0.0/16`. Ingress is only from the Pod labelled `gateway.networking.k8s.io/gateway-name: devcontainer`, which Istio puts on the gateway Deployment it generates. **Decision: Pods are isolated from Pods, not from the cluster.** Egress still reaches the nodes, the kubelet and the API server, which are outside the Pod network. Story 16's "no access to the Kubernetes API" means the Pod's own identity grants nothing (no ServiceAccount token is mounted), not that the network blocks the API: admins administer clusters, the Management Cluster among them, with their own credentials. Story 16 and the policy's comment now say so.

**Gateway address.** The Roster's `gatewayAddress`, `${DEVCONTAINER_GATEWAY_ADDRESS:=none}`, renders `spec.addresses` (type `IPAddress`) unless it is `none`. Without it, a recreated Gateway (an empty Roster renders none) can come back on another IP and break every Workstation's SSH config. The default is `none`, not empty: Flux substitutes after kustomize has dropped the quotes, so an empty value reached the ResourceSet as null and crashed `flux-operator build` (found by rendering the committed Roster from the substituted build, as `tests/cluster.sh` now does).

**Decision: network values are Flux variables, not patches.** The first version had the Gitops Kustomization JSON-patch the Roster, ImageRepository and NetworkPolicy, and replace a placeholder Site Config, which tied the Gitops repository to this one's object paths. Instead, every network-specific value here is a Flux variable named after a runtime fact (`HARBOR_REGISTRY`, `HARBOR_PROJECT`, `DEVCONTAINER_*`), and the Gitops Kustomization only adds `postBuild.substituteFrom: flux-runtime-info`, the same way the rest of the Gitops repository is configured. The contract is the variable names: `tests/site/facts.env` lists them with test values, `tests/repo.py` fails on a variable not listed there (or a listed one not used), `docs/check.sh` on one the README doesn't name, and `tests/site/subst.py` substitutes them strictly in `tests/cluster.sh`. `subst.py` is the one parser of `facts.env`: the other two read the names through `subst.py --names`. Site Config is `binaryData` from base64 facts, so multi-line values survive substitution. The ImageRepository references `harbor-ca` and `harbor-pull` itself. The Devcontainer Namespace left this directory (now `tests/kind/namespace.yaml`): the Gitops repository owns it, so no delete patch is needed either.

**Readiness.** An exec probe, `devc-ready 2222`, which checks the pid file `devc-sshd` now writes once sshd listens, not a TCP connection, which sshd logged as a pre-auth disconnect every 10 seconds. The pid file is per port so a `devc-selftest` run inside a live Pod (its throwaway sshd uses another port) can't overwrite it. Its path is built only in `usr/local/lib/devc/sshd.bash`, which both `devc-sshd` and `devc-ready` source, so the manifest holds only the port it already owns; the selftest runs `devc-ready` against its own sshd with no override, so the image test exercises the real path.

**Roster keys.** The Roster is kept per network with `merge=ours` (Release Owner guide), so a change to its format, like the `image` split above, is carried over by hand. A Roster left in the old format fails `tests/cluster_policy.py`, which reads the keys the ResourceSet template uses (`inputs.x` and `$a.x` required, `get inputs "x"` and `dig "x"` optional) and checks every Roster against them.

**Decision: merge order, this branch first, then camusicjunkie/Gitops#4.** Merged the other way round, the admins' volumes are deleted. Gitops#3's Kustomization patches out the Namespace this directory used to ship, and Gitops#4 drops that patch. If #4 lands while this directory still ships the Namespace, the Kustomization applies it and records it in its inventory, and merging this branch then prunes it, with every admin's volume. The Gitops ResourceSet that owns the Namespace marks it `fluxcd.controlplane.io/prune: disabled`, which the kustomize-controller doesn't honour; it only skips `kustomize.toolkit.fluxcd.io/prune: disabled`. Merged first, this branch leaves the Gitops#3 Kustomization with `${DEVCONTAINER_SITE_ENV_B64}` unsubstituted in Site Config's `binaryData`, which the API server rejects at the dry run, so nothing is applied and the running Pods stay up until #4 lands. Gitops#4 should also add `kustomize.toolkit.fluxcd.io/prune: disabled` to the Namespace, so no merge order can prune it.

**Smaller fixes.** `/var/lib/devc/trust` is owned by `dev`, mode 0755, not 0777. `install.ps1` follows the PoshCode style (parameter descriptions as comments in the param block, a space after the type, no redundant lowercasing of hashtable keys, which are already case-insensitive). The StorageClass and 20Gi size are documented as set once. The Release Owner guide gains "Settings outside this repository" and "Carrying this repository to another network".

**Tests run:** `tests/all.sh --files`; `tests/cluster.sh` render, kubeconform and policy checks for every sample Roster (270 checks); `tests/image.sh` (16 checks, with `devc-selftest` including `devc-ready`), plus the trust store (`dev`, 0755) and the OCI labels inspected on the built image; the installer's Pester tests (23, so `install.ps1`'s changes are style only). All passing. **Not run:** `tests/release.sh`, `tests/secrets-klogin.sh`, and `tests/kind/up.sh` with `tests/cluster-live.sh`. Run those before merging.
