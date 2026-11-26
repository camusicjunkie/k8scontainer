# shellcheck shell=bash
# Tab completion for klogin: vSphere Namespaces, then Guest Clusters, from Site
# Config's KLOGIN_NAMESPACES and KLOGIN_CLUSTERS (comma- or space-separated).
# It works before the first login; the login itself decides who has access.

_klogin() {
    local cur=${COMP_WORDS[COMP_CWORD]} list
    case $COMP_CWORD in
        1) list=${KLOGIN_NAMESPACES:-} ;;
        2) list=${KLOGIN_CLUSTERS:-} ;;
        *) return 0 ;;
    esac
    mapfile -t COMPREPLY < <(compgen -W "${list//,/ }" -- "$cur")
}
complete -F _klogin klogin
