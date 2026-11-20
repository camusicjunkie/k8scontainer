#!/usr/bin/env bash
# Image seam: builds the Standard Image and runs its self-test against it from
# outside, with no network, as the image's own user.
#
#   tests/image.sh            build, then run every case
#   IMAGE=tag tests/image.sh  skip the build and test an existing image
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
source "$repo/tests/lib.sh"
image=${IMAGE:-}


if [[ -z $image ]]; then
    image=devc-standard:test
    docker build --tag "$image" "$repo/image" || { echo "image.sh: the build failed" >&2; exit 1; }
fi

offline() { docker run --rm --network none "$@"; }

# The image's configured user is not root.
user=$(docker inspect --format '{{.Config.User}}' "$image")
if [[ -n $user && $user != 0 && $user != root && $user != 0:* && $user != root:* ]]; then
    pass "the image's user is $user, not root"
else
    fail "the image's user is not root (got '${user:-unset}')"
fi

# The self-test passes offline as that user.
if out=$(offline "$image" devc-selftest 2>&1); then
    pass "the self-test passes with no network"
else
    fail "the self-test passes with no network"
    printf '%s\n' "$out" | tail -n 40
fi

# The self-test fails, naming the problem, when started as root.
if out=$(offline --user 0 --entrypoint devc-selftest "$image" 2>&1); then
    fail "the self-test fails when run as root"
elif grep -q 'FAIL .*not root' <<<"$out"; then
    pass "the self-test fails when run as root"
else
    fail "the self-test fails for the wrong reason as root: $(tail -n 3 <<<"$out")"
fi

# The entrypoint refuses to start anything as root.
if out=$(offline --user 0 "$image" true 2>&1); then
    fail "the entrypoint refuses to start as root"
elif grep -q 'root' <<<"$out"; then
    pass "the entrypoint refuses to start as root"
else
    fail "the entrypoint failed without naming root: $out"
fi

# No sudo.
if offline --entrypoint bash "$image" -c '! command -v sudo' >/dev/null 2>&1; then
    pass "sudo is not installed"
else
    fail "sudo is not installed"
fi

# The Docker CLI is gone.
if offline --entrypoint bash "$image" -c '! command -v docker' >/dev/null 2>&1; then
    pass "the Docker CLI is not installed"
else
    fail "the Docker CLI is not installed"
fi

# ----------------------------------------------------- user-owned tools area
# ~/.local is a volume in the Pod. A tool the admin installed there in an earlier
# session is on PATH in a new login shell, with no network and no root.
toolvol=devc-tools-$$
docker volume create "$toolvol" >/dev/null
docker run --rm --network none --entrypoint bash -v "$toolvol:/home/dev/.local" "$image" -c \
    'install -d ~/.local/bin && printf "#!/bin/sh\necho from-volume\n" >~/.local/bin/mytool && chmod +x ~/.local/bin/mytool' >/dev/null 2>&1
if [[ $(docker run --rm --network none --entrypoint bash -v "$toolvol:/home/dev/.local" "$image" -lc mytool 2>/dev/null) == from-volume ]]; then
    pass "a tool on the ~/.local volume is on PATH in a new login shell"
else
    fail "a tool on the ~/.local volume is on PATH in a new login shell"
fi
docker volume rm -f "$toolvol" >/dev/null 2>&1

# ---------------------------------------------------------------- sshd service
# The image's default command is the non-root sshd, with the Roster's key list
# mounted at /etc/devc/authorized_keys and the host key dir on a volume. The
# container has no network; the client runs inside it, against loopback.
export MSYS_NO_PATHCONV=1
tmp=$(mktemp -d)
hosttmp=$(cygpath -m "$tmp" 2>/dev/null || echo "$tmp")
vol=devc-hostkeys-$$
cid=
cleanup() { [[ -n $cid ]] && docker rm -f "$cid" >/dev/null 2>&1; docker volume rm -f "$vol" >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT

# Two client key pairs made inside the image: "good" is on the list, "bad" is not.
docker run --rm --network none --entrypoint bash "$image" -c '
    d=$(mktemp -d)
    ssh-keygen -q -t ed25519 -N "" -f "$d/good"; ssh-keygen -q -t ed25519 -N "" -f "$d/bad"
    tar -C "$d" -cf - good good.pub bad' | tar -C "$tmp" -xf -

start_sshd() { # prints the container id once sshd answers
    local id
    id=$(docker create --network none -v "$vol:/var/lib/devc/hostkeys" "$image") || return 1
    docker cp "$hosttmp/good.pub" "$id:/etc/devc/authorized_keys" >/dev/null || return 1
    docker start "$id" >/dev/null || return 1
    local i
    for i in $(seq 40); do
        docker exec "$id" bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222' 2>/dev/null && { echo "$id"; return 0; }
        sleep 0.5
    done
    docker logs "$id" >&2
    docker rm -f "$id" >/dev/null 2>&1
    return 1
}

if cid=$(start_sshd); then
    pass "the default command starts sshd, listening on port 2222"
    user=$(docker exec "$cid" ps -o user= -C sshd | head -n1 | tr -d ' ')
    if [[ -n $user && $user != root ]]; then pass "sshd runs as $user, not root"; else fail "sshd runs as a non-root user (got '$user')"; fi

    # Run a client command inside the container with one of the key pairs.
    client() { # client KEYNAME SSH_ARGS...
        local k=$1; shift
        docker exec -i "$cid" bash -c 'cat >/tmp/k && chmod 600 /tmp/k' <"$tmp/$k" || return 1
        docker exec "$cid" ssh -i /tmp/k -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no             -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 2222 "$@"
    }
    if [[ $(client good dev@127.0.0.1 'echo hello') == hello ]]; then pass "a listed key logs in"; else fail "a listed key logs in"; fi
    if client bad dev@127.0.0.1 true >/dev/null 2>&1; then fail "an unlisted key is refused"; else pass "an unlisted key is refused"; fi
    if client good root@127.0.0.1 true >/dev/null 2>&1; then fail "other users are refused"; else pass "other users are refused"; fi
    methods=$(docker exec "$cid" ssh -o PreferredAuthentications=none -o BatchMode=yes -o StrictHostKeyChecking=no         -o UserKnownHostsFile=/dev/null -p 2222 dev@127.0.0.1 2>&1 || true)
    if grep -q 'Permission denied (publickey)' <<<"$methods"; then pass "passwords are refused (publickey only)"; else fail "passwords are refused: $methods"; fi
    sshopts='-i /tmp/k -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 2222'
    if docker exec "$cid" bash -c "eval \$(ssh-agent -s) >/dev/null; ssh-add /tmp/k 2>/dev/null; ssh -A $sshopts dev@127.0.0.1 'ssh-add -l'" 2>&1 | grep -q ED25519; then
        pass "agent forwarding reaches the session"
    else fail "agent forwarding reaches the session"; fi
    if docker exec "$cid" bash -c "ssh -f -N -L 9000:127.0.0.1:2222 $sshopts dev@127.0.0.1 && exec 3<>/dev/tcp/127.0.0.1/9000 && read -t 5 -u 3 l && [[ \$l == SSH-2.0* ]]" >/dev/null 2>&1; then
        pass "TCP forwarding carries a connection"
    else fail "TCP forwarding carries a connection"; fi
    fp_before=$(docker exec "$cid" ssh-keyscan -p 2222 127.0.0.1 2>/dev/null | docker exec -i "$cid" ssh-keygen -lf -)
    docker rm -f "$cid" >/dev/null 2>&1
    if cid=$(start_sshd); then
        fp_after=$(docker exec "$cid" ssh-keyscan -p 2222 127.0.0.1 2>/dev/null | docker exec -i "$cid" ssh-keygen -lf -)
        if [[ -n $fp_before && $fp_before == "$fp_after" ]]; then pass "the host key survives a restart on its volume"; else fail "the host key changed across a restart"; fi
    else fail "sshd restarts on the same volume"; fi
else
    fail "the default command starts sshd, listening on port 2222"
    cid=
fi

if ((${#failed[@]})); then
    printf '%d case(s) failed\n' "${#failed[@]}"
    exit 1
fi
echo "all cases passed"
