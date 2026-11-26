# shellcheck shell=bash
# Shared by secrets, with-secrets and devc-vault-pass (ADR 0001): the Secrets
# File is an ansible-vault file whose password is a hash of the forwarded
# agent's signature over a fixed challenge, made with the key whose fingerprint
# is DEVC_UNLOCK_KEY.

DEVC_SECRETS_FILE=${DEVC_SECRETS_FILE:-$HOME/.secrets/vault}
SECRETS_NAMESPACE=devc-secrets
SECRETS_CHALLENGE="devc Secrets File unlock, v1"

die() { echo "${0##*/}: $*" >&2; exit 1; }

# require_agent: stops unless a forwarded agent answers.
require_agent() {
    local rc=2
    if [[ -n ${SSH_AUTH_SOCK:-} ]]; then
        rc=0
        ssh-add -l >/dev/null 2>&1 || rc=$?
    fi
    ((rc != 2)) ||
        die "no forwarded SSH agent in this shell (SSH_AUTH_SOCK is unset or dead). Connect with Remote-SSH and forward the smartcard agent; shells without it (kubectl exec) can't unlock the Secrets File."
}

# unlock_pubkey FILE: writes the agent's public key for DEVC_UNLOCK_KEY to FILE
# and prints its type (RSA, ECDSA, ED25519, ...).
unlock_pubkey() {
    local out=$1 line fp type
    [[ -n ${DEVC_UNLOCK_KEY:-} ]] ||
        die "DEVC_UNLOCK_KEY isn't set. Put the fingerprint of your card's PIV Authentication key (ssh-add -l shows it) in ~/.devc/personal/personal.env, then reconnect so a new login shell loads it."
    while IFS= read -r line; do
        read -r _ fp _ < <(ssh-keygen -lf - <<<"$line")
        [[ $fp == "$DEVC_UNLOCK_KEY" ]] || continue
        printf '%s\n' "$line" >"$out"
        type=$(ssh-keygen -lf - <<<"$line")
        type=${type##*(}
        echo "${type%)}"
        return 0
    done < <(ssh-add -L 2>/dev/null)
    die "the key $DEVC_UNLOCK_KEY isn't in the forwarded agent (ssh-add -l lists what is)"
}

# unlock_signature PUBFILE: the agent's signature of the challenge.
unlock_signature() {
    printf '%s' "$SECRETS_CHALLENGE" | ssh-keygen -Y sign -f "$1" -n "$SECRETS_NAMESPACE" 2>/dev/null
}

require_secrets_file() {
    [[ -f $DEVC_SECRETS_FILE ]] || die "no Secrets File at $DEVC_SECRETS_FILE; create it with: secrets init"
}
