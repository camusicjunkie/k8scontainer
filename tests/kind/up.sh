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
# - the Gateway API CRDs (experimental channel, for TCPRoute).
# Istio is not installed: the Gateway stays unprogrammed and SSH is reached
# by port-forward.
#
# REGISTRY is a plain-HTTP registry on DOCKER_NETWORK; the node joins that
# network, so it can also reach a Git server there (the local GitLab).
#
# With GIT_URL (plus GIT_BRANCH, GIT_USER, GIT_TOKEN) it also applies
# tests/kind/flux.yaml: Flux syncs manifests/devcontainer from that branch and
# the image automation pushes to it, so use a throwaway branch. The test's SSH
# key is kept in STATE_DIR.
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

echo "== Gateway API CRDs"
k apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/experimental-install.yaml >/dev/null

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
# v1.19.0: what the Gitops repository's chart pin (3.9.0) installs. v1.20
# refuses kyverno.io/v1 ClusterPolicy, which all of its policies are.
k apply --server-side -f https://github.com/kyverno/kyverno/releases/download/v1.19.0/install.yaml >/dev/null
k -n kyverno rollout status deploy/kyverno-admission-controller --timeout 300s
k -n kyverno rollout status deploy/kyverno-background-controller --timeout 300s
# What the policies read: the cluster settings the laptop cluster uses, with
# the registry swapped for this one, and the pull secret the Gitops repository
# keeps in flux-system for Kyverno to copy into each namespace.
export KYVERNO_VALIDATION_ACTION=Audit HARBOR_REGISTRY=$registry HARBOR_PROJECT=$harbor_project
k -n flux-system create secret docker-registry harbor-pull --docker-server "$registry" \
    --docker-username kind --docker-password kind --dry-run=client -o yaml | k apply -f - >/dev/null
# Two local changes, both printed:
# - request.namespace for request.object.metadata.namespace: Kyverno's autogen
#   turns the latter into spec.template.metadata.namespace on StatefulSets and
#   Deployments, which no Pod template has, so the image rewrite rejects them.
# - kind's local-path-storage joins the exclusions: its PVC helper image is
#   not mirrored to the registry.
k kustomize "$gitops/apps/kyverno/configs" \
    | envsubst '$KYVERNO_VALIDATION_ACTION $HARBOR_REGISTRY $HARBOR_PROJECT' \
    | sed -e 's/request\.object\.metadata\.namespace/request.namespace/g' \
          -e 's/^\( *\)- kube-node-lease$/&\n\1- local-path-storage/' \
    | tee "${TMPDIR:-/tmp}/devc-kind-policies.yaml" | k apply -f -
echo "local changes to the Gitops policies:"
k kustomize "$gitops/apps/kyverno/configs" \
    | envsubst '$KYVERNO_VALIDATION_ACTION $HARBOR_REGISTRY $HARBOR_PROJECT' \
    | diff - "${TMPDIR:-/tmp}/devc-kind-policies.yaml" | grep '^[<>]' || true
k wait clusterpolicy --all --for=condition=Ready --timeout 120s

if [[ -n ${GIT_URL:-} ]]; then
    echo "== Flux sync from $GIT_URL ${GIT_BRANCH:?}"
    mkdir -p "$state"
    [[ -f $state/id_rsa ]] || ssh-keygen -q -t rsa -b 2048 -N '' -C test-smartcard -f "$state/id_rsa"
    k -n flux-system create secret generic devc-git --from-literal=username="${GIT_USER:?}" \
        --from-literal=password="${GIT_TOKEN:?}" --dry-run=client -o yaml | k apply -f - >/dev/null
    # The automation lives in the namespace the Kustomization creates.
    k create namespace devcontainer --dry-run=client -o yaml | k apply -f - >/dev/null
    export GIT_URL GIT_BRANCH REGISTRY=$registry TEST_PUBKEY=$(cat "$state/id_rsa.pub")
    envsubst '$GIT_URL $GIT_BRANCH $REGISTRY $HARBOR_PROJECT $TEST_PUBKEY' <"$here/flux.yaml" | k apply -f -
    k -n flux-system wait kustomization/devcontainer --for=condition=Ready --timeout 300s
fi

echo "cluster $ctx ready"
