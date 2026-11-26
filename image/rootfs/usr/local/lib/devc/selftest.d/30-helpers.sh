# shellcheck shell=bash
# The in-container helpers are on PATH, and interactive shells load their completion.

for helper in secrets with-secrets devc-vault-pass devc-ca-refresh devc-entrypoint klogin; do
    check "$helper is on PATH" command -v "$helper"
done
check "interactive shells complete klogin" bash -ic 'complete -p klogin'
