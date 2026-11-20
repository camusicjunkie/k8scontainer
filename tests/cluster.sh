#!/usr/bin/env bash
# Cluster seam: validates the manifests under manifests/devcontainer.
#
#   tests/cluster.sh
#
# Needs kubectl (for `kustomize`), Docker and python3 with PyYAML. First run
# needs network (pulls kubeconform, which fetches the Kubernetes schemas).
# Steps: render with kustomize; validate against the Kubernetes schemas with
# kubeconform; check the Pod Security `restricted` fields and the ticket's
# behaviours (tests/cluster_policy.py); then, if the Standard Image is present
# locally (DEVC_IMAGE, default devc-standard:test), start it the way the Pod
# does and check persistence and the trust store.
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
kube_version=${KUBE_VERSION:-1.31.0}
image=${DEVC_IMAGE:-devc-standard:test}
failed=0
py=python3; python3 -c "" >/dev/null 2>&1 || py=python
export MSYS_NO_PATHCONV=1
native() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failed=1; }

work=$(mktemp -d)
vol=devc-cluster-test-$$
trap 'rm -rf "$work"; docker volume rm "$vol" >/dev/null 2>&1' EXIT
rendered=$work/rendered.yaml

if ! kubectl kustomize "$(native "$repo/manifests/devcontainer")" >"$rendered" 2>"$work/err"; then
    bad "kustomize renders manifests/devcontainer"; cat "$work/err"; exit 1
fi
ok "kustomize renders manifests/devcontainer"

if docker run --rm -i ghcr.io/yannh/kubeconform:latest-alpine -strict -summary \
        -kubernetes-version "$kube_version" - <"$rendered"; then
    ok "kubeconform: manifests match the Kubernetes $kube_version schemas"
else
    bad "kubeconform"
fi

"$py" -I "$(native "$repo/tests/cluster_policy.py")" <"$rendered" || failed=1

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "skip image behaviour: $image not present locally"
    exit $failed
fi

# Behaviour of the image under the Pod's security context. Site Config files
# come from the rendered ConfigMap.
mkdir "$work/site"
"$py" -I - "$(native "$rendered")" "$(native "$work/site")" <<'PY'
import sys, pathlib, yaml
out = pathlib.Path(sys.argv[2])
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "ConfigMap" and "site" in d["metadata"]["name"]:
        for k, v in d["data"].items():
            (out / k).write_text(v, newline="")
PY
docker volume create "$vol" >/dev/null
paths=(workspace:/home/dev/workspace .kube:/home/dev/.kube .secrets:/home/dev/.secrets
       .devc/personal:/home/dev/.devc/personal hostkeys:/var/lib/devc/hostkeys .local:/home/dev/.local)
# What the kubelet does for fsGroup and subPath: directories owned by gid 1000.
docker run --rm --user 0 -v "$vol:/state" --entrypoint sh "$image" -c \
    'cd /state && mkdir -p workspace .kube .secrets .devc/personal hostkeys .local && chown -R 1000:1000 .'
mounts=()
for p in "${paths[@]}"; do
    mounts+=(--mount "type=volume,src=$vol,dst=${p#*:},volume-subpath=${p%%:*}")
done
for f in "$work"/site/*.crt; do
    mounts+=(-v "$(native "$f"):/etc/devcontainer/site/ca/$(basename "$f"):ro")
done
# The Pod: non-root, no capabilities, no new privileges, default seccomp.
pod() {
    docker run --rm --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges \
        "${mounts[@]}" --entrypoint devc-entrypoint "$image" "$@"
}

pod bash -c 'echo kept >~/workspace/note; echo tool >~/.local/tool; echo off >~/stray' 2>&1 | tail -3
if [[ $(pod bash -c 'cat ~/workspace/note ~/.local/tool' 2>/dev/null | tail -n 2) == $'kept\ntool' ]]; then
    ok "content written at the volume paths survives a restart"
else bad "content written at the volume paths survives a restart"; fi
if pod bash -c 'test ! -e ~/stray' >/dev/null 2>&1; then
    ok "the rest of the home directory is not kept"
else bad "the rest of the home directory is not kept"; fi

if pod bash -c 'want=$(openssl x509 -in /etc/devcontainer/site/ca/site-ca.crt -noout -subject)
    openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt | openssl pkcs7 -print_certs -noout | grep -qF "${want#subject=}"' >/dev/null 2>&1; then
    ok "Site Config certificate authorities are trusted in the Pod"
else bad "Site Config certificate authorities are trusted in the Pod"; fi

exit $failed
