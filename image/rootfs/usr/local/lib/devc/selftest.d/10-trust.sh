# shellcheck shell=bash
# Trust store: the system bundle is the generated store, and the refresh works
# as the container user (devc-selftest runs under the container's hardening).

store_has_public_cas() {
    (($(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt) > 100))
}

check "the system CA bundle is the generated store" \
    test "$(readlink -f /etc/ssl/certs/ca-certificates.crt)" = /var/lib/devc/trust/ca-certificates.crt
check "the CA refresh runs as the container user" devc-ca-refresh
check "the trust store holds the public CAs" store_has_public_cas
