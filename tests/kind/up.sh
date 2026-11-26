#!/usr/bin/env bash
# A one-node kind cluster shaped like the Management Cluster, for the live
# cluster seam (tests/cluster-live.sh). Idempotent: rerun to repair.
#
#   tests/kind/up.sh          # create or repair
#   tests/kind/up.sh --down   # delete the cluster
#
# Run from Linux (WSL2) against any Docker engine. Installs:
# - Flux with the image controllers (Flux Operator + FluxInstance),
# - the Gateway API CRDs the Gitops repository vendors for the Management
#   Cluster (GITOPS_DIR/clusters/management/gatewayapi, standard channel),
# - Istio gateway-only, at the version GITOPS_DIR/clusters/management/istio.yaml
#   pins, as that file installs it: istio-base and istiod with no mesh, pulling
#   from a Harbor-style mirror path (global.hub) with harbor-pull, so the
#   Devcontainer Namespace's Gateway is programmed. Its LoadBalancer stays
#   pending; tests reach its Service by port-forward.
# - No Kyverno: the Management Cluster runs none. As the Gitops repository's
#   clusters/management/devcontainer.yaml does, harbor-pull is put in
#   istio-system and in the Devcontainer Namespace, on its default
#   ServiceAccount, and the Roster names REGISTRY directly (tests/kind/flux.yaml
#   substitutes it as a runtime fact), so nothing rewrites images.
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
mgmt=$gitops/clusters/management
[[ -f $mgmt/istio.yaml && -f $mgmt/gatewayapi/crds.yaml ]] \
    || { echo "GITOPS_DIR has no clusters/management/istio.yaml and gatewayapi/crds.yaml (camusicjunkie/Gitops#3): $gitops"; exit 1; }
istio=$(sed -n 's/^ *tag: "\([^"]*\)".*/\1/p' "$mgmt/istio.yaml" | sort -u)
[[ $istio != *$'\n'* ]] || { echo "GITOPS_DIR's istio.yaml pins more than one Istio version: $istio"; exit 1; }
[[ $istio =~ ^1\.([0-9]+)\. ]] && ((BASH_REMATCH[1] >= 31)) \
    || { echo "GITOPS_DIR pins Istio $istio; TCPRoute v1 needs 1.31 or later: $gitops"; exit 1; }

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

echo "== Gateway API CRDs ($mgmt/gatewayapi)"
# The v1.7+ bundle's safe-upgrades policy refuses changing channel; a cluster on
# the other channel drops it first, and the vendored bundle brings it back.
want=$(sed -n 's/^ *gateway\.networking\.k8s\.io\/channel: //p' "$mgmt/gatewayapi/crds.yaml" | head -1)
have=$(k get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}' 2>/dev/null)
if [[ -n $have && $have != "$want" ]]; then
    k delete validatingadmissionpolicybinding,validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null
fi
k apply --server-side --force-conflicts -f "$mgmt/gatewayapi/crds.yaml" >/dev/null

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

echo "== harbor-pull"
# The Management Cluster's bootstrap keeps harbor-pull in flux-system, and the
# Gitops repository's ResourceSets copy it into istio-system and the
# Devcontainer Namespace (copyFrom). REGISTRY needs no login; the Secret is
# here so the Pods reference it exactly as they do there.
pull_secret() {  # pull_secret NAMESPACE
    k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n "$1" create secret docker-registry harbor-pull --docker-server "$registry" \
        --docker-username kind --docker-password kind --dry-run=client -o yaml | k apply -f - >/dev/null
}
pull_secret flux-system
pull_secret istio-system
# A cluster set up before the Management Cluster dropped Kyverno still has it;
# its image rewrite would hide a Roster that doesn't name REGISTRY.
if k get namespace kyverno >/dev/null 2>&1; then
    echo "removing Kyverno left over from an earlier setup"
    k delete mutatingpolicy,validatingpolicy,generatingpolicy --all --ignore-not-found >/dev/null 2>&1 || true
    k delete clusterpolicy --all --ignore-not-found >/dev/null 2>&1 || true
    k delete -f https://github.com/kyverno/kyverno/releases/download/v1.19.0/install.yaml --ignore-not-found >/dev/null 2>&1 || true
fi

echo "== Istio $istio, gateway only"
# The images go where the Harbor mirror keeps them (<project>/istio/pilot,
# .../proxyv2) and istiod points global.hub there, as on the Management
# Cluster. Istio 1.31+ publishes images on Docker Hub and charts on ghcr.io.
crane() { docker run --rm --network "$network" gcr.io/go-containerregistry/crane:v0.22.1 "$@" --insecure; }
crane copy "docker.io/istio/pilot:$istio" "$registry/$harbor_project/istio/pilot:$istio" >/dev/null
crane copy "docker.io/istio/proxyv2:$istio" "$registry/$harbor_project/istio/proxyv2:$istio" >/dev/null
charts=$(mktemp -d); chmod 777 "$charts"
docker run --rm -v "$charts:/o" --entrypoint sh alpine/helm:3.16.4 -c "
    helm template istio-base oci://ghcr.io/istio/release/charts/base --version $istio -n istio-system --include-crds \
        --set defaultRevision=default >/o/base.yaml &&
    helm template istiod oci://ghcr.io/istio/release/charts/istiod --version $istio -n istio-system --set defaultRevision=default \
        --set global.hub=$registry/$harbor_project/istio --set 'global.imagePullSecrets[0]=harbor-pull' >/o/istiod.yaml"
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
    # As the Gitops repository's devcontainer.yaml does: it owns the
    # Devcontainer Namespace (the manifests don't), puts harbor-pull on its
    # default ServiceAccount (the Pods use it) with no API token, and gives the
    # ImageRepository harbor-ca (here the test site CA; the registry is HTTP).
    k apply -f "$here/namespace.yaml" >/dev/null
    pull_secret devcontainer
    k -n devcontainer create secret generic harbor-ca --from-file=ca.crt="$here/../site/site-ca.crt" \
        --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n devcontainer patch serviceaccount default --type merge \
        -p '{"automountServiceAccountToken":false,"imagePullSecrets":[{"name":"harbor-pull"}]}' >/dev/null
    k -n devcontainer create secret generic devc-git-push --from-literal=username="$GIT_USER" \
        --from-literal=password="${GIT_PUSH_TOKEN:-$GIT_TOKEN}" --dry-run=client -o yaml | k apply -f - >/dev/null
    export GIT_URL GIT_BRANCH GIT_PUSH_BRANCH=${GIT_PUSH_BRANCH:-$GIT_BRANCH-image-updates} \
        REGISTRY=$registry HARBOR_PROJECT=$harbor_project TEST_PUBKEY=$(cat "$state/id_rsa.pub") \
        SITE_ENV_B64=$(base64 -w0 "$here/../site/site.env") SITE_CA_B64=$(base64 -w0 "$here/../site/site-ca.crt")
    envsubst '$GIT_URL $GIT_BRANCH $GIT_PUSH_BRANCH $REGISTRY $HARBOR_PROJECT $TEST_PUBKEY $SITE_ENV_B64 $SITE_CA_B64' \
        <"$here/flux.yaml" | k apply -f -
    k -n flux-system wait kustomization/devcontainer --for=condition=Ready --timeout 300s
fi

echo "cluster $ctx ready"
