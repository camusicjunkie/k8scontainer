# shellcheck shell=bash
# The non-root sshd: key-only login as the image's user, with agent and TCP
# forwarding. A throwaway sshd runs on loopback with its own keys and host key.

ssh_tmp=$(mktemp -d)
ssh_port=${DEVC_SELFTEST_SSH_PORT:-22222}
ssh_user=$(id -un)
ssh_agent_pid=
trap 'kill $(jobs -p) $ssh_agent_pid 2>/dev/null; rm -rf "$ssh_tmp"' EXIT

ssh_client() { # ssh_client KEY [SSH_ARGS...]
    local key=$1; shift
    ssh -i "$ssh_tmp/$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$ssh_port" "$@"
}

ssh-keygen -q -t ed25519 -N '' -f "$ssh_tmp/good"
ssh-keygen -q -t ed25519 -N '' -f "$ssh_tmp/bad"
cp "$ssh_tmp/good.pub" "$ssh_tmp/authorized_keys"
DEVC_SSHD_PORT=$ssh_port DEVC_SSHD_LISTEN=127.0.0.1 DEVC_AUTHORIZED_KEYS=$ssh_tmp/authorized_keys \
    DEVC_HOSTKEY_DIR=$ssh_tmp/hostkeys devc-sshd >"$ssh_tmp/sshd.log" 2>&1 &
for _ in $(seq 40); do
    (exec 3<>"/dev/tcp/127.0.0.1/$ssh_port") 2>/dev/null && break
    sleep 0.25
done

sshd_login_ok() { [[ $(ssh_client good "$ssh_user@127.0.0.1" 'echo hello') == hello ]]; }
sshd_unlisted_key_refused() { ! ssh_client bad "$ssh_user@127.0.0.1" true; }
sshd_other_user_refused() { ! ssh_client good root@127.0.0.1 true; }
sshd_password_refused() {
    local out
    out=$(ssh_client good -o PreferredAuthentications=none "$ssh_user@127.0.0.1" 2>&1)
    [[ $out == *'Permission denied (publickey)'* ]]
}
sshd_agent_forwarded() {
    local out rc
    out=$(ssh-agent -s) && eval "$out" >/dev/null || return 1
    ssh-add "$ssh_tmp/good" 2>/dev/null
    ssh_client good -A "$ssh_user@127.0.0.1" 'ssh-add -l' | grep -q ED25519
    rc=$?
    kill "$SSH_AGENT_PID"
    return $rc
}
sshd_tcp_forwarded() {
    ssh_client good -f -N -L 9000:127.0.0.1:"$ssh_port" "$ssh_user@127.0.0.1" || return 1
    local l
    exec 3<>/dev/tcp/127.0.0.1/9000 && read -r -t 5 -u 3 l && [[ $l == SSH-2.0* ]]
}

check "sshd accepts a listed key as the image's user" sshd_login_ok
check "sshd refuses a key that is not on the list" sshd_unlisted_key_refused
check "sshd refuses every other user" sshd_other_user_refused
check "sshd offers no password login" sshd_password_refused
check "sshd forwards the client's agent" sshd_agent_forwarded
check "sshd forwards TCP connections" sshd_tcp_forwarded
check "sshd created its host key at the mounted path" test -s "$ssh_tmp/hostkeys/ssh_host_ed25519_key"
