# shellcheck shell=bash
# Shared by devc-sshd, which writes sshd's pid file, and devc-ready, which the
# Pod's readiness probe runs to read it. The path is per port, so a
# devc-selftest run inside a live Pod (its throwaway sshd uses another port)
# can't overwrite the Pod's own.

devc_sshd_pidfile() { # devc_sshd_pidfile PORT
    printf '/tmp/devc-sshd-%s.pid\n' "$1"
}
