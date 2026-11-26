#!/usr/bin/env bash
# Live cluster seam: what tests/cluster.sh can only render, run on the kind
# cluster from tests/kind/up.sh (with GIT_URL set), set up as the Management
# Cluster is: no Kyverno, the pull secret on the default ServiceAccount.
#
#   tests/cluster-live.sh
#
# Checks, in order: the admin's Pod runs under Pod Security restricted and
# answers SSH with the Roster's key, directly and through the Istio gateway on
# the admin's Roster port; a restart keeps the State Directory and
# host key and nothing else; a new Release tag reaches the StatefulSet through
# the image automation but the Pod only on restart (OnDelete); removing the
# admin from the Roster removes the Pod and keeps the volume, and adding them
# back finds their state.
#
# Pushes a new tag to REGISTRY (through DOCKER_NETWORK), lets the automation
# commit to its push branch, and merges that into the synced branch as merging
# the update would. Needs kubectl, ssh and docker.
set -uo pipefail
ctx=${KUBE_CONTEXT:-kind-devc}
state=${STATE_DIR:-$HOME/.cache/devc-kind}
registry=${REGISTRY:-registry.local:5000}
network=${DOCKER_NETWORK:-gitlab-local_default}
repo_path=${HARBOR_PROJECT:-harbor}/devcontainer/standard
ns=devcontainer
failed=0
export MSYS_NO_PATHCONV=1
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failed=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
k() { kubectl --context "$ctx" "$@"; }
crane() { docker run --rm --network "$network" gcr.io/go-containerregistry/crane:v0.22.1 "$@" --insecure; }

reconcile() {  # ask Flux to act now rather than at its next interval
    local at; at=$(date +%s)
    k -n flux-system annotate gitrepository/k8scontainer kustomization/devcontainer \
        reconcile.fluxcd.io/requestedAt="$at" --overwrite >/dev/null
    k -n $ns annotate imagerepository/devcontainer-standard imageupdateautomation/devcontainer \
        gitrepository/k8scontainer-push resourcesetinputprovider/roster resourceset/devcontainer reconcile.fluxcd.io/requestedAt="$at" --overwrite >/dev/null 2>&1
}
until_true() {  # until_true SECONDS COMMAND: retries, reconciling Flux each time
    local end=$((SECONDS + $1)); shift
    until eval "$*"; do ((SECONDS < end)) || return 1; reconcile; sleep 5; done
}
# Merge the automation's push branch into the synced branch once it carries
# TAG, as merging the update's merge request would. A real merge, not a
# fast-forward: the synced branch may have moved since the push branch was cut.
# The credentials go from the cluster's secret to the container's environment,
# never onto a command line.
merge_updates() {  # merge_updates TAG
    local url branch push
    url=$(k -n flux-system get gitrepository k8scontainer -o jsonpath='{.spec.url}')
    branch=$(k -n flux-system get gitrepository k8scontainer -o jsonpath='{.spec.ref.branch}')
    push=$(k -n $ns get imageupdateautomation devcontainer -o jsonpath='{.spec.git.push.branch}')
    GIT_USER=$(k -n $ns get secret devc-git-push -o jsonpath='{.data.username}' | base64 -d) \
    GIT_PASS=$(k -n $ns get secret devc-git-push -o jsonpath='{.data.password}' | base64 -d) \
    docker run --rm --network "$network" --entrypoint sh -e GIT_USER -e GIT_PASS \
        -e URL="$url" -e BRANCH="$branch" -e PUSH="$push" -e TAG="$1" alpine/git:v2.49.1 -c '
        cred="!f() { echo username=\$GIT_USER; echo password=\$GIT_PASS; }; f"
        git init -q /r && cd /r &&
        git -c credential.helper="$cred" fetch -q "$URL" "$BRANCH:synced" "$PUSH:update" &&
        git show update:manifests/devcontainer/roster.yaml | grep -qE "imageTag: $TAG( |\$)" &&
        git checkout -q synced &&
        git -c user.name=reviewer -c user.email=reviewer@lab.local merge -q --no-edit \
            -m "Merge $PUSH into $BRANCH [skip ci]" update &&
        git -c credential.helper="$cred" push -q "$URL" "HEAD:refs/heads/$BRANCH"' >/dev/null 2>&1
}
pod_image() { k -n $ns get pod devc-admin-0 -o jsonpath='{.spec.containers[0].image}' 2>/dev/null; }
sts_image() { k -n $ns get sts devc-admin -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null; }
pod_ready() { k -n $ns wait pod/devc-admin-0 --for=condition=Ready --timeout "${1:-600}s" >/dev/null 2>&1; }
restart() { k -n $ns delete pod devc-admin-0 --wait=true >/dev/null; sleep 2; pod_ready; }

# ssh to the admin's Pod through a port-forward to a Service: by default the
# one the TCPRoute targets; with SSH_VIA=gateway, the Istio gateway's own
# Service on the admin's Roster port, the path a Workstation takes (kind has no
# LoadBalancer for the Gateway's address).
pod_ssh() {
    local port=$((20000 + RANDOM % 10000)) pf out rc svc=devc-admin-ssh target=2222
    if [[ ${SSH_VIA:-} == gateway ]]; then
        svc=devcontainer-istio
        target=$(k -n $ns get gateway devcontainer -o jsonpath='{.spec.listeners[?(@.name=="ssh-admin")].port}')
    fi
    k -n $ns port-forward "svc/$svc" "$port:$target" >/dev/null 2>&1 & pf=$!
    for _ in $(seq 20); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.5; done
    out=$(ssh -i "$state/id_rsa" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR dev@127.0.0.1 "$@"); rc=$?
    kill $pf 2>/dev/null; wait $pf 2>/dev/null
    printf '%s' "$out"; return $rc
}
hostkey() { pod_ssh 'ssh-keygen -lf /var/lib/devc/hostkeys/ssh_host_ed25519_key.pub | cut -d" " -f2'; }

echo "== the admin's Pod"
check "the ResourceSet is Ready" "k -n $ns wait resourceset/devcontainer --for=condition=Ready --timeout 300s >/dev/null"
check "the Pod is Ready" "pod_ready"
check "the namespace enforces Pod Security restricted" \
    "[[ \$(k get ns $ns -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}') == restricted ]]"
check "the Pod runs the image from $registry" "[[ \$(pod_image) == $registry/* ]]"
check "the image is the Roster's own, not rewritten (no Kyverno)" "[[ \$(pod_image) == \$(sts_image) ]]"
check "the Roster's key opens a shell" "[[ \$(pod_ssh 'echo hello') == hello ]]"
listener() { k -n $ns get gateway devcontainer -o jsonpath='{.status.listeners[?(@.name=="ssh-admin")].attachedRoutes}' 2>/dev/null; }
check "Istio accepts the Gateway's ssh-admin listener with its TCPRoute attached" "until_true 180 '[[ \$(listener) == 1 ]]'"
check "the gateway Pod runs under Pod Security restricted" "k -n $ns rollout status deploy/devcontainer-istio --timeout 180s >/dev/null"
check "the Roster's key opens a shell through the gateway, on the admin's port" "[[ \$(SSH_VIA=gateway pod_ssh 'echo hello') == hello ]]"

echo "== restart"
pod_ssh 'echo kept >~/workspace/note; echo off >~/stray' >/dev/null
before=$(hostkey)
check "the Pod comes back after a restart" "restart"
check "the State Directory survives a restart" "[[ \$(pod_ssh 'cat ~/workspace/note') == kept ]]"
check "the rest of the home directory does not" "pod_ssh 'test ! -e ~/stray'"
after=$(hostkey)
check "the host key is the same after a restart ($before)" "[[ -n '$before' && '$before' == '$after' ]]"

echo "== a new Release"
old=$(pod_image); old_tag=${old##*:}
new_tag=0.1.$(date +%s)
crane copy "$registry/$repo_path:$old_tag" "$registry/$repo_path:$new_tag" >/dev/null 2>&1
check "the automation commits $new_tag to its push branch, and it merges" "until_true 300 'merge_updates $new_tag'"
check "the StatefulSet template follows the merge to $new_tag" "until_true 180 '[[ \$(sts_image) == *:$new_tag ]]'"
check "the running Pod keeps $old_tag until its admin restarts it (OnDelete)" "[[ \$(pod_image) == '$old' ]]"
check "after a restart the Pod runs $new_tag" "restart && [[ \$(pod_image) == *:$new_tag ]]"
check "and its State Directory is still there" "[[ \$(pod_ssh 'cat ~/workspace/note') == kept ]]"

echo "== leaving and rejoining the Roster"
patches=$(k -n flux-system get kustomization devcontainer -o jsonpath='{.spec.patches}')
k -n flux-system patch kustomization devcontainer --type json \
    -p '[{"op":"add","path":"/spec/patches/-","value":{"target":{"kind":"ResourceSetInputProvider","name":"roster"},"patch":"- {op: remove, path: /spec/defaultValues/admins/0}"}}]' >/dev/null
check "removing the entry removes the StatefulSet and Pod" \
    "until_true 180 '! k -n $ns get sts devc-admin >/dev/null 2>&1 && ! k -n $ns get pod devc-admin-0 >/dev/null 2>&1'"
check "and keeps the volume" "k -n $ns get pvc state-devc-admin-0 >/dev/null 2>&1"
k -n flux-system patch kustomization devcontainer --type merge -p "{\"spec\":{\"patches\":$patches}}" >/dev/null
check "adding the entry back brings the Pod back" "until_true 180 'k -n $ns get pod devc-admin-0 >/dev/null 2>&1' && pod_ready"
check "on the same volume" "[[ \$(pod_ssh 'cat ~/workspace/note') == kept ]]"

exit $failed
