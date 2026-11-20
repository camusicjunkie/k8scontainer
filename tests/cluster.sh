#!/usr/bin/env bash
# Cluster seam: validates the manifests under manifests/devcontainer and what
# the ResourceSet generates from sample Rosters (tests/rosters: 1 admin, 2
# admins with a resource override, and 2 minus one).
#
#   tests/cluster.sh
#
# Needs kubectl (for `kustomize`), the flux-operator CLI (renders the
# ResourceSet with the real templating engine), Docker and python3 with PyYAML. First run
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

if ! command -v flux-operator >/dev/null; then
    bad "flux-operator CLI is on PATH (renders the ResourceSet; see https://fluxoperator.dev/docs/cli/)"; exit 1
fi

# render ROSTER OUT: the Namespace and Site Config (kustomize; the Roster and
# ResourceSet objects are what the cluster applies, so they are dropped from
# the output) followed by what the ResourceSet generates from that Roster,
# evaluated by the real flux-operator templating engine.
render() {
    kubectl kustomize "$(native "$repo/manifests/devcontainer")" 2>"$work/err" | "$py" -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] not in ("ResourceSet", "ResourceSetInputProvider")]
sys.stdout.write(yaml.safe_dump_all(docs))' >"$2" || { cat "$work/err"; return 1; }
    echo --- >>"$2"
    # The CLI fails on an empty result; for an empty Roster that is the answer.
    flux-operator build resourceset -f "$(native "$repo/manifests/devcontainer/resourceset.yaml")" \
        --inputs-from-provider "$(native "$1")" >>"$2" 2>"$work/err" \
        || grep -q 'no objects were generated' "$work/err" || { cat "$work/err"; return 1; }
}

# The committed Roster is a sample too.
for roster in "$repo/tests/rosters/one.yaml" "$repo/tests/rosters/two.yaml" \
              "$repo/tests/rosters/two-minus-alice.yaml" "$repo/tests/rosters/none.yaml" \
              "$repo/manifests/devcontainer/roster.yaml"; do
    label=${roster#"$repo/"}
    out=$work/$(basename "$roster")
    echo "== $label"
    if render "$roster" "$out"; then ok "$label: kustomize and the ResourceSet render"
    else bad "$label: kustomize and the ResourceSet render"; continue; fi

    # Gateway API kinds come from the CRDs catalog (also fetched over the network).
    if docker run --rm -i ghcr.io/yannh/kubeconform:latest-alpine -strict -summary \
            -kubernetes-version "$kube_version" -schema-location default \
            -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
            - <"$out"; then
        ok "$label: kubeconform: output matches the Kubernetes $kube_version and Gateway API schemas"
    else
        bad "$label: kubeconform"
    fi
    "$py" -I "$(native "$repo/tests/cluster_policy.py")" "$(native "$roster")" <"$out" || failed=1
done

# Removing an entry removes that admin's Pod, route and everything else named for them.
if grep -q 'alice' "$work/two-minus-alice.yaml" || ! grep -q 'alice' "$work/two.yaml"; then
    bad "removing alice from the Roster drops every object and listener generated for her"
else ok "removing alice from the Roster drops every object and listener generated for her"; fi

# Image update flow: the marker and policy, and that a new tag (or a pinned
# earlier one) changes only the Pod template image.
if render "$repo/tests/rosters/one-older-tag.yaml" "$work/one-older-tag.yaml"; then
    "$py" -I "$(native "$repo/tests/cluster_update.py")" "$(native "$repo/manifests/devcontainer/roster.yaml")" \
        "$(native "$work/one-older-tag.yaml")" "$(native "$work/one.yaml")" || failed=1
else bad "one-older-tag.yaml renders"; fi
rendered=$work/one.yaml
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

# Reaching the Pod over sshd (the Gateway forwards plain TCP to port 2222, so
# a client on the Pod's network namespace stands in for the Workstation). The
# key list is mounted the way the Pod mounts it, holding the test's own RSA key
# (like a PIV card's) in place of the placeholder, whose private half is gone.
mkdir "$work/ssh"
docker run --rm --user 1000:1000 -v "$(native "$work/ssh"):/k" --entrypoint ssh-keygen "$image" \
    -q -t rsa -b 2048 -N '' -C test-smartcard -f /k/id_rsa >/dev/null 2>&1
cp "$work/ssh/id_rsa.pub" "$work/ssh/authorized_keys"
sshpod=devc-cluster-ssh-$$
trap 'rm -rf "$work"; docker rm -f "$sshpod" >/dev/null 2>&1; docker volume rm "$vol" >/dev/null 2>&1' EXIT
sshopts=(-p 2222 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
         -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
client() {  # ssh as the Workstation would, from the Pod's network namespace
    docker run --rm --user 1000:1000 --network "container:$sshpod" -v "$(native "$work/ssh"):/k:ro" \
        --entrypoint ssh "$image" -i "${keyfile:-/k/id_rsa}" "${sshopts[@]}" dev@127.0.0.1 "$@"
}
start_sshd() {
    docker rm -f "$sshpod" >/dev/null 2>&1
    docker run -d --name "$sshpod" --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges \
        "${mounts[@]}" -v "$(native "$work/ssh/authorized_keys"):/etc/devc/authorized_keys:ro" \
        --entrypoint devc-entrypoint "$image" devc-sshd >/dev/null
    for _ in $(seq 30); do client true >/dev/null 2>&1 && return 0; sleep 1; done
    return 1
}
hostkey() {
    docker run --rm --user 1000:1000 --network "container:$sshpod" --entrypoint sh "$image" -c \
        'ssh-keyscan -p 2222 127.0.0.1 2>/dev/null | ssh-keygen -lf - | cut -d" " -f2'
}
if start_sshd; then
    ok "the Pod's sshd starts under the Pod's security context with the mounted key list"
    if [[ $(client 'echo hello' 2>/dev/null) == hello ]]; then ok "an RSA smartcard-style key logs in and opens a shell"
    else bad "an RSA smartcard-style key logs in and opens a shell"; fi
    docker run --rm --user 1000:1000 --network "container:$sshpod" --entrypoint sh "$image" -c \
        'ssh-keygen -q -t rsa -b 2048 -N "" -f /tmp/other && ssh -i /tmp/other -p 2222 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null dev@127.0.0.1 true' >/dev/null 2>&1 \
        && bad "a key not on the list is refused" || ok "a key not on the list is refused"
    before=$(hostkey)
    start_sshd
    after=$(hostkey)
    if [[ -n $before && $before == "$after" ]]; then ok "the host key is the same after a Pod restart ($before)"
    else bad "the host key is the same after a Pod restart (before=$before after=$after)"; fi
else
    bad "the Pod's sshd starts under the Pod's security context with the mounted key list"
    docker logs "$sshpod" 2>&1 | tail -5
fi

exit $failed
