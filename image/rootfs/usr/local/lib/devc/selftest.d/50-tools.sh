# shellcheck shell=bash
# Every tool on the list runs, offline, under the container's hardening.

tool() {
    local name=$1
    shift
    check "$name runs" timeout 30 "$@"
}

# Kubernetes
tool kubectl kubectl version --client
tool helm helm version --short
tool kustomize kustomize version
tool flux flux version --client
tool flux-operator flux-operator --version
tool flux-operator-mcp flux-operator-mcp --version
tool k9s k9s version --short
tool kubectx kubectx --help
tool kubens kubens --help
tool kubeconform kubeconform -v
tool kubeseal kubeseal --version
tool istioctl istioctl version --remote=false

# kubectl-vsphere is baked only when the build named a Supervisor; MANIFEST
# says which, and the image must agree with it.
vsphere_plugin_matches_manifest() {
    local want
    want=$(manifest_section tools | sed -n 's/^kubectl-vsphere //p')
    [[ -n $want ]] || { echo "MANIFEST has no kubectl-vsphere line"; return 1; }
    if [[ $want == absent ]]; then
        ! command -v kubectl-vsphere >/dev/null || { echo "kubectl-vsphere is present but MANIFEST says absent"; return 1; }
    else
        timeout 30 kubectl-vsphere --help >/dev/null || { echo "kubectl-vsphere ($want) does not run"; return 1; }
    fi
}
check "kubectl-vsphere is present exactly when MANIFEST says so" vsphere_plugin_matches_manifest
tool yq yq --version
tool jq jq --version

# VMware and IaC
tool govc govc version
tool terraform terraform version
tool packer packer version
tool vault vault version
tool tflint tflint --version

# tflint runs with its bundled terraform ruleset only. No plugin ruleset is
# baked: none exists for the baked providers (vsphere, kubernetes, helm, ...),
# and `terraform validate` already checks them against their schemas offline.
# Linting an unused variable proves the bundled rules run with no network.
tflint_lints() {
    local dir out
    dir=$(mktemp -d)
    printf 'variable "unused" {}\n' >"$dir/main.tf"
    out=$(tflint --chdir="$dir" --enable-rule=terraform_unused_declarations 2>&1) && {
        echo "tflint found nothing in a file with an unused variable"
        return 1
    }
    grep -q 'terraform_unused_declarations' <<<"$out" || { echo "$out"; return 1; }
}
check "tflint lints with its bundled ruleset" tflint_lints

# Supply chain, lint, secrets and forge
tool cosign cosign version
tool skopeo skopeo --version
tool shellcheck shellcheck --version
tool hadolint hadolint --version
tool sops sops --version --disable-version-check
tool age age --version
tool glab glab version


# Base and shell
tool git git --version
tool ssh ssh -V
tool curl curl --version
tool openssl openssl version
tool tmux tmux -V
tool fzf fzf --version
tool ripgrep rg --version
tool fd fd --version
tool bat bat --version
tool zoxide zoxide --version
tool neovim nvim --version
tool vim vim --version
tool nano nano --version
tool starship starship --version
tool lazygit lazygit --version
tool htop htop --version
tool tree tree --version
tool dig dig -v
tool traceroute traceroute --version
tool sshpass sshpass -V
tool xorriso xorriso -version
tool genisoimage genisoimage --version
tool qemu-img qemu-img --version
tool zip zip -v
tool unzip unzip -v
tool xz xz --version
tool file file --version
tool less less --version
tool procps ps --version
tool iproute2 ip -V
tool ping ping -V
tool netcat nc -h
check "bash-completion is installed" test -r /usr/share/bash-completion/bash_completion

# brew's tree never reaches the image.
check "brew is not in the image" bash -c '! command -v brew && ! command -v ruby && [[ ! -e /home/linuxbrew ]]'
check "interactive shells complete kubectl" bash -ic 'complete -p kubectl'
