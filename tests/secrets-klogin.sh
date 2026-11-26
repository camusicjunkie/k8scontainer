#!/usr/bin/env bash
# Secrets File and klogin seam: runs the Standard Image's sshd the way the Pod
# does (state on volumes at the Pod's paths, Site Config mounted read-only) and
# drives the helpers over ssh, from a client holding software keys in a local
# ssh-agent. The agent stands in for the smartcard agent Remote-SSH forwards;
# kubectl is a stub (kubectl-vsphere is not in the image).
#
#   tests/secrets-klogin.sh            build, then run every case
#   IMAGE=tag tests/secrets-klogin.sh  skip the build and test an existing image
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
source "$repo/tests/lib.sh"
image=${IMAGE:-}


if [[ -z $image ]]; then
    image=devc-standard:secrets-test
    docker build --tag "$image" "$repo/image" || { echo "secrets-klogin.sh: the build failed" >&2; exit 1; }
fi

export MSYS_NO_PATHCONV=1
tmp=$(mktemp -d)
hosttmp=$(cygpath -m "$tmp" 2>/dev/null || echo "$tmp")
tag=$$
vols=(devc-sk-hostkeys-$tag devc-sk-secrets-$tag devc-sk-kube-$tag devc-sk-personal-$tag)
cid=
cleanup() {
    [[ -n $cid ]] && docker rm -f "$cid" >/dev/null 2>&1
    docker volume rm -f "${vols[@]}" >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT

# --------------------------------------------------------------------- fixtures
# Key pairs made inside the image: "good" logs in over ssh; "card" is the RSA
# stand-in for the card's PIV Authentication key; "ed" is a non-RSA key.
docker run --rm --network none --entrypoint bash "$image" -c '
    d=$(mktemp -d)
    ssh-keygen -q -t ed25519 -N "" -f "$d/good"
    ssh-keygen -q -t rsa -b 2048 -N "" -f "$d/card"
    ssh-keygen -q -t ed25519 -N "" -f "$d/ed"
    tar -C "$d" -cf - good good.pub card card.pub ed ed.pub' | tar -C "$tmp" -xf -

# Site Config, as Flux would render it for a network.
cat >"$tmp/site.env" <<'EOF'
KLOGIN_SERVERS=sup.example.invalid
KLOGIN_NAMESPACES=team-a,team-b
KLOGIN_CLUSTERS=gc-1,gc-2
KLOGIN_INSECURE=1
EOF

# Stand-in for kubectl: `vsphere login` records its arguments, checks the
# password arrived only in KUBECTL_VSPHERE_PASSWORD, and writes a login to
# ~/.kube; `config` reads it back.
cat >"$tmp/kubectl" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "vsphere login")
        echo "$*" >>"$HOME/.kube/calls"
        [ "$KUBECTL_VSPHERE_PASSWORD" = "s3cret pass" ] || { echo "stub kubectl: wrong password" >&2; exit 1; }
        [ -z "$VSPHERE_PASSWORD" ] || { echo "stub kubectl: VSPHERE_PASSWORD leaked" >&2; exit 1; }
        case "$*" in
            *--tanzu-kubernetes-cluster-name\ *) ctx=$(echo "$*" | sed 's/.*--tanzu-kubernetes-cluster-name \([^ ]*\).*/\1/') ;;
            *) ctx=supervisor ;;
        esac
        echo "$ctx" >"$HOME/.kube/current-context"
        echo "Logged in to $ctx" ;;
    "config current-context") cat "$HOME/.kube/current-context" ;;
    "config use-context") echo "$3" >"$HOME/.kube/current-context" ;;
    *) echo "stub kubectl: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/kubectl"

# The Pod's mounts: state volumes at their paths, the Roster key list, Site Config.
start_pod() { # prints the container id once sshd answers
    local id i
    id=$(docker create --network none \
        -v "${vols[0]}:/var/lib/devc/hostkeys" \
        -v "${vols[1]}:/home/dev/.secrets" \
        -v "${vols[2]}:/home/dev/.kube" \
        -v "${vols[3]}:/home/dev/.devc/personal" \
        -v "$hosttmp/site.env:/etc/devcontainer/site/site.env:ro" \
        -v "$hosttmp/kubectl:/home/dev/.local/bin/kubectl:ro" \
        "$image") || return 1
    docker cp "$hosttmp/good.pub" "$id:/etc/devc/authorized_keys" >/dev/null || return 1
    docker start "$id" >/dev/null || return 1
    for i in $(seq 40); do
        docker exec "$id" bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222' 2>/dev/null && { echo "$id"; return 0; }
        sleep 0.5
    done
    docker logs "$id" >&2
    docker rm -f "$id" >/dev/null 2>&1
    return 1
}

# State volumes are root-owned when new; in the Pod fsGroup makes them the admin's.
for v in "${vols[@]}"; do docker volume create "$v" >/dev/null; done
docker run --rm --user 0 --entrypoint bash \
    -v "${vols[1]}:/v1" -v "${vols[2]}:/v2" -v "${vols[3]}:/v3" "$image" -c 'chown dev /v1 /v2 /v3' 2>/dev/null ||
    docker run --rm --user 0 --entrypoint chown \
        -v "${vols[1]}:/v1" -v "${vols[2]}:/v2" -v "${vols[3]}:/v3" "$image" 1000 /v1 /v2 /v3

if ! cid=$(start_pod); then
    fail "the Pod's sshd starts with the state volumes and Site Config mounted"
    printf '%d case(s) failed\n' "${#failed[@]}"
    exit 1
fi

sshopts='-i /tmp/good -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 2222'
install_keys() {
    local k
    for k in good card ed card.pub ed.pub; do
        docker exec -i "$cid" bash -c "cat >/tmp/$k && chmod 600 /tmp/$k" <"$tmp/$k" || return 1
    done
}
install_keys

# drive FORWARD KEYS... : runs the script on stdin in a login shell in the Pod,
# over ssh from a client whose local agent holds KEYS (card, ed). FORWARD is
# yes (ssh -A, as Remote-SSH does with the smartcard agent) or no.
drive() {
    local fwd=-a
    [[ $1 == yes ]] && fwd=-A
    shift
    docker exec -i "$cid" bash -c '
        fwd=$1; shift
        eval "$(ssh-agent -s)" >/dev/null
        for k in "$@"; do ssh-add "/tmp/$k" 2>/dev/null; done
        ssh $fwd '"$sshopts"' dev@127.0.0.1 bash -l -s' drive "$fwd" "$@" 2>&1
}

fp=$(docker exec "$cid" ssh-keygen -lf /tmp/card.pub | awk '{print $2}')
edfp=$(docker exec "$cid" ssh-keygen -lf /tmp/ed.pub | awk '{print $2}')

# personal.env on the Personal Config volume names the unlock key.
drive no <<<"printf 'DEVC_UNLOCK_KEY=%s\n' '$fp' >~/.devc/personal/personal.env" >/dev/null

# ------------------------------------------------------------ Site Config in shells
out=$(drive no <<<'echo "ns=$KLOGIN_NAMESPACES srv=$KLOGIN_SERVERS"')
check "Site Config's site.env reaches a login shell's environment" [ "$out" = "ns=team-a,team-b srv=sup.example.invalid" ]

# Personal Config's bashrc, on its volume at ~/.devc/personal, runs in interactive shells.
drive no <<<"echo 'export DEVC_PERSONAL_PROBE=loaded' >~/.devc/personal/bashrc" >/dev/null
out=$(drive no <<<"bash -ic 'echo \$DEVC_PERSONAL_PROBE'")
check "Personal Config's bashrc is loaded from ~/.devc/personal" grep -qx loaded <<<"$out"

# ------------------------------------------------------- creating the Secrets File
out=$(drive yes ed <<<"secrets init; echo rc=\$?; test -e ~/.secrets/vault && echo exists")
check "init refuses when the card's key isn't in the agent" grep -q "isn't in the forwarded agent" <<<"$out"

out=$(drive yes ed <<<"DEVC_UNLOCK_KEY='$edfp' secrets init; test -e ~/.secrets/vault && echo CREATED")
check "init refuses a non-RSA (ed25519) key" grep -q "not RSA" <<<"$out"
check "a refused init leaves no Secrets File" bash -c '! grep -q CREATED <<<"$1"' _ "$out"

stub='mkdir -p /tmp/stub; printf "%s\n" "#!/bin/sh" "case \" \$* \" in *\" -Y sign \"*) head -c 32 /dev/urandom | base64 ;; *) exec /usr/bin/ssh-keygen \"\$@\" ;; esac" >/tmp/stub/ssh-keygen; chmod +x /tmp/stub/ssh-keygen'
out=$(drive yes card <<<"$stub; PATH=/tmp/stub:\$PATH secrets init; test -e ~/.secrets/vault && echo CREATED")
check "init refuses signatures that do not repeat" grep -q "signatures of the same challenge differ" <<<"$out"
check "a refused init leaves no Secrets File (non-repeating)" bash -c '! grep -q CREATED <<<"$1"' _ "$out"

out=$(drive no <<<"secrets init")
check "init says plainly when no agent is forwarded" grep -q "no forwarded SSH agent" <<<"$out"

out=$(drive yes card <<<"secrets init; head -n1 ~/.secrets/vault")
check "init succeeds with the RSA key and writes an ansible-vault file" grep -q '^\$ANSIBLE_VAULT' <<<"$out"

out=$(drive yes card <<<"secrets init")
check "init refuses to overwrite an existing Secrets File" grep -q "already exists" <<<"$out"

# Fill in the vCenter credentials with a scripted editor.
drive yes card >/dev/null <<'EOF'
printf '%s\n' '#!/bin/sh' "printf 'VSPHERE_USER: admin@vsphere.local\nVSPHERE_PASSWORD: s3cret pass\n' >\"\$1\"" >/tmp/ed.sh
chmod +x /tmp/ed.sh
EDITOR=/tmp/ed.sh secrets edit
EOF

# --------------------------------------------------------- unlocking the Secrets File
out=$(drive yes card <<<"with-secrets -k VSPHERE_USER printenv VSPHERE_USER")
check "the Secrets File unlocks with the agent forwarded" [ "$out" = "admin@vsphere.local" ]

out=$(drive no <<<"with-secrets -k VSPHERE_USER printenv VSPHERE_USER")
check "the Secrets File refuses without the agent, with a clear message" grep -q "no forwarded SSH agent" <<<"$out"
check "...and prints no secret" bash -c '! grep -q admin@ <<<"$1"' _ "$out"

out=$(drive yes ed <<<"with-secrets -k VSPHERE_USER printenv VSPHERE_USER")
check "the Secrets File refuses when the agent lacks the card's key" grep -q "isn't in the forwarded agent" <<<"$out"

# ---------------------------------------------------------------------- klogin
out=$(drive yes card <<<"klogin; kubectl config current-context")
check "klogin logs in to the Supervisor from Site Config's address" grep -qx supervisor <<<"$out"
calls=$(docker exec "$cid" cat /home/dev/.kube/calls)
check "...passing the Site Config server and its insecure setting" grep -q -- "vsphere login --server sup.example.invalid --vsphere-username admin@vsphere.local --insecure-skip-tls-verify" <<<"$calls"

out=$(drive yes card <<<"klogin team-a gc-1; kubectl config current-context")
check "klogin logs in to a Guest Cluster" grep -qx gc-1 <<<"$out"
calls=$(docker exec "$cid" cat /home/dev/.kube/calls)
check "...with its vSphere Namespace and cluster name" grep -q -- "--tanzu-kubernetes-cluster-namespace team-a --tanzu-kubernetes-cluster-name gc-1" <<<"$calls"

before=$(docker exec "$cid" bash -c 'wc -l </home/dev/.kube/calls')
out=$(drive no <<<"klogin team-a gc-1")
check "klogin without the agent says so" grep -q "no forwarded SSH agent" <<<"$out"
check "...and does not call kubectl" [ "$(docker exec "$cid" bash -c 'wc -l </home/dev/.kube/calls')" = "$before" ]

# --------------------------------------------------------------------- Pod restart
docker rm -f "$cid" >/dev/null 2>&1
if cid=$(start_pod); then
    install_keys
    out=$(drive no <<<"kubectl config current-context")
    check "the cluster login survives a Pod restart" [ "$out" = gc-1 ]
    out=$(drive yes card <<<"with-secrets -k VSPHERE_USER printenv VSPHERE_USER")
    check "the Secrets File unlocks after a Pod restart" [ "$out" = "admin@vsphere.local" ]
else
    fail "the Pod restarts on the same volumes"
    cid=
fi

if ((${#failed[@]})); then
    printf '%d case(s) failed\n' "${#failed[@]}"
    exit 1
fi
echo "all cases passed"
