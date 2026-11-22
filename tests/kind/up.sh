#!/usr/bin/env bash
# A one-node kind cluster shaped like the Management Cluster, for the live
# cluster seam (tests/cluster-live.sh). Idempotent: rerun to repair.
#
#   tests/kind/up.sh          # create or repair
#   tests/kind/up.sh --down   # delete the cluster
#
# Run from Linux (WSL2) against any Docker engine. Installs:
# - Flux with the image controllers (Flux Operator + FluxInstance),
# - Kyverno with the Gitops repository's own policies (GITOPS_DIR), with
#   HARBOR_REGISTRY/HARBOR_PROJECT pointing at REGISTRY so its image rewrite
#   lands on a registry the node can pull from,
# - the Gateway API CRDs the Gitops repository vendors (experimental channel:
#   Istio reads TCPRoute only at v1alpha2, which standard no longer serves),
# - Istio gateway-only, at the Gitops repository's istiod version, as its
#   clusters/management/istio.yaml installs it: istio-base and istiod with no
#   mesh and PILOT_ENABLE_ALPHA_GATEWAY_API, so the devcontainer Gateway is
#   programmed. Its LoadBalancer stays pending; tests reach its Service by
#   port-forward.
#
# REGISTRY is a plain-HTTP registry on DOCKER_NETWORK; the node joins that
# network, so it can also reach a Git server there (the local GitLab).
#
# With GIT_URL (plus GIT_BRANCH, GIT_USER, GIT_TOKEN) it also applies
# tests/kind/flux.yaml: Flux syncs manifests/devcontainer from GIT_BRANCH and
# the image automation pushes to GIT_PUSH_BRANCH (default
# GIT_BRANCH-image-updates), which tests/cluster-live.sh merges back, so use
# throwaway branches. GIT_PUSH_TOKEN, if set, is the push credential; it
# defaults to GIT_TOKEN, which a lab may give both. The test's SSH key is kept
# in STATE_DIR.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
name=${KIND_CLUSTER:-devc}
network=${DOCKER_NETWORK:-gitlab-local_default}
registry=${REGISTRY:-registry.local:5000}
harbor_project=${HARBOR_PROJECT:-harbor}
gitops=${GITOPS_DIR:-$here/../../../Gitops}
state=${STATE_DIR:-$HOME/.cache/devc-kind}
ctx=kind-$name

if [[ ${1:-} == --down ]]; then kind delete cluster --name "$name"; exit; fi
for t in kind kubectl flux-operator docker envsubst; do
    command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }
done
[[ -d $gitops/apps/kyverno/configs ]] || { echo "GITOPS_DIR has no apps/kyverno/configs: $gitops"; exit 1; }
! grep -rq 'request\.object\.metadata\.namespace' "$gitops/apps/kyverno/configs" \
    || { echo "GITOPS_DIR's image rewrite policy predates the request.namespace fix: $gitops"; exit 1; }
grep -q 'gateway.networking.k8s.io/channel: experimental' "$gitops/apps/istio/controllers/gatewayapi/crds.yaml" \
    || { echo "GITOPS_DIR vendors standard-channel Gateway API CRDs, which Istio cannot route TCP with: $gitops"; exit 1; }

if ! kind get clusters 2>/dev/null | grep -qx "$name"; then
    kind create cluster --name "$name" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
fi
node=$name-control-plane
docker network inspect "$network" -f '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "$node" \
    || docker network connect "$network" "$node"
docker exec -i "$node" sh -c "mkdir -p /etc/containerd/certs.d/$registry && cat >/etc/containerd/certs.d/$registry/hosts.toml" <<EOF
server = "http://$registry"
[host."http://$registry"]
  capabilities = ["pull", "resolve"]
EOF
k() { kubectl --context "$ctx" "$@"; }

echo "== Gateway API CRDs ($gitops)"
# A cluster first given the standard v1.7+ bundle has its safe-upgrades policy,
# which refuses moving to experimental; the vendored bundle brings it back.
if [[ $(k get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}' 2>/dev/null) == standard ]]; then
    k delete validatingadmissionpolicybinding,validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null
fi
k apply --server-side --force-conflicts -f "$gitops/apps/istio/controllers/gatewayapi/crds.yaml" >/dev/null

echo "== Flux"
k apply --server-side -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v0.63.0/install.yaml >/dev/null
k -n flux-system rollout status deploy/flux-operator --timeout 180s
k apply -f - <<'EOF'
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.10.x"
    registry: ghcr.io/fluxcd
  components:
    - source-controller
    - kustomize-controller
    - image-reflector-controller
    - image-automation-controller
  cluster:
    type: kubernetes
    size: small
    networkPolicy: false
EOF
k -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout 300s

echo "== Kyverno and the Gitops repository's policies ($gitops)"
# v1.19.0: what the Gitops repository's chart pin (3.9.0) installs; it serves
# the policies.kyverno.io/v1 CEL policies the Gitops repository now uses.
k apply --server-side -f https://github.com/kyverno/kyverno/releases/download/v1.19.0/install.yaml >/dev/null
k -n kyverno rollout status deploy/kyverno-admission-controller --timeout 300s
k -n kyverno rollout status deploy/kyverno-background-controller --timeout 300s
# What the policies read: the cluster settings the laptop cluster uses, with
# the registry swapped for this one, and the pull secret the Gitops repository
# keeps in flux-system for Kyverno to copy into each namespace.
export KYVERNO_VALIDATION_ACTION=Audit HARBOR_REGISTRY=$registry HARBOR_PROJECT=$harbor_project
k -n flux-system create secret docker-registry harbor-pull --docker-server "$registry" \
    --docker-username kind --docker-password kind --dry-run=client -o yaml | k apply -f - >/dev/null
# One local change, printed: local-path-storage, flux-system and kyverno join
# the exclusions. Here their images come from public registries and are not
# mirrored to REGISTRY; on the Management Cluster they already come from Harbor.
# The policies are CEL (policies.kyverno.io/v1); a cluster set up before they
# were still has the ClusterPolicies they replaced, which would keep rewriting.
k delete clusterpolicy --all --ignore-not-found >/dev/null 2>&1 || true
k kustomize "$gitops/apps/kyverno/configs" \
    | envsubst '$KYVERNO_VALIDATION_ACTION $HARBOR_REGISTRY $HARBOR_PROJECT' \
    | sed -E "s/kube-node-lease('+)\]\)/kube-node-lease\1, \1local-path-storage\1, \1flux-system\1, \1kyverno\1])/" \
    | tee "${TMPDIR:-/tmp}/devc-kind-policies.yaml" | k apply -f -
echo "local changes to the Gitops policies:"
k kustomize "$gitops/apps/kyverno/configs" \
    | envsubst '$KYVERNO_VALIDATION_ACTION $HARBOR_REGISTRY $HARBOR_PROJECT' \
    | diff - "${TMPDIR:-/tmp}/devc-kind-policies.yaml" | grep '^[<>]' || true
k wait mutatingpolicy,validatingpolicy,generatingpolicy --all --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout 120s

istio=$(sed -n 's/^ *tag: "\([^"]*\)".*/\1/p' "$gitops/apps/istio/controllers/istiod/ocirepository.yaml")
echo "== Istio $istio, gateway only"
# The image rewrite sends istiod (istio-system) and the devcontainer gateway to
# REGISTRY's per-namespace paths, so the images are mirrored there first, as
# Harbor holds them on the Management Cluster.
crane() { docker run --rm --network "$network" gcr.io/go-containerregistry/crane:v0.22.1 "$@" --insecure; }
crane copy "registry.istio.io/release/pilot:$istio" "$registry/$harbor_project/istio-system/pilot:$istio" >/dev/null
crane copy "registry.istio.io/release/proxyv2:$istio" "$registry/$harbor_project/devcontainer/proxyv2:$istio" >/dev/null
charts=$(mktemp -d); chmod 777 "$charts"
docker run --rm -v "$charts:/o" --entrypoint sh alpine/helm:3.16.4 -c "
    helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null &&
    helm template istio-base istio/base --version $istio -n istio-system --include-crds --set defaultRevision=default >/o/base.yaml &&
    helm template istiod istio/istiod --version $istio -n istio-system --set defaultRevision=default \
        --set pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true >/o/istiod.yaml"
k create namespace istio-system --dry-run=client -o yaml | k apply -f - >/dev/null
k apply --server-side --force-conflicts -f "$charts/base.yaml" >/dev/null
k apply --server-side --force-conflicts -f "$charts/istiod.yaml" >/dev/null
rm -rf "$charts"
k -n istio-system rollout status deploy/istiod --timeout 300s

if [[ -n ${GIT_URL:-} ]]; then
    echo "== Flux sync from $GIT_URL ${GIT_BRANCH:?}"
    mkdir -p "$state"
    [[ -f $state/id_rsa ]] || ssh-keygen -q -t rsa -b 2048 -N '' -C test-smartcard -f "$state/id_rsa"
    k -n flux-system create secret generic devc-git-read --from-literal=username="${GIT_USER:?}" \
        --from-literal=password="${GIT_TOKEN:?}" --dry-run=client -o yaml | k apply -f - >/dev/null
    # The automation lives in the namespace the Kustomization creates.
    k create namespace devcontainer --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n devcontainer create secret generic devc-git-push --from-literal=username="$GIT_USER" \
        --from-literal=password="${GIT_PUSH_TOKEN:-$GIT_TOKEN}" --dry-run=client -o yaml | k apply -f - >/dev/null
    export GIT_URL GIT_BRANCH GIT_PUSH_BRANCH=${GIT_PUSH_BRANCH:-$GIT_BRANCH-image-updates} \
        REGISTRY=$registry TEST_PUBKEY=$(cat "$state/id_rsa.pub")
    envsubst '$GIT_URL $GIT_BRANCH $GIT_PUSH_BRANCH $REGISTRY $HARBOR_PROJECT $TEST_PUBKEY' <"$here/flux.yaml" | k apply -f -
    k -n flux-system wait kustomization/devcontainer --for=condition=Ready --timeout 300s
fi

echo "cluster $ctx ready"
