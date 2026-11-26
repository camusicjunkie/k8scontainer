# shellcheck shell=bash
# The offline caches work with no network: Terraform providers, Packer plugins,
# Ansible collections, PowerShell modules and the Python wheelhouse.

packages=/usr/local/share/devc/packages

terraform_init() {
    local dir
    dir=$(mktemp -d)
    cp "$packages/terraform-providers.tf" "$dir/"
    terraform -chdir="$dir" init -backend=false -input=false -no-color
}

packer_init() {
    packer init "$packages/packer-plugins.pkr.hcl"
}

collections_listed() {
    local list name
    list=$(ansible-galaxy collection list 2>/dev/null)
    while IFS= read -r name; do
        grep -q "^$name " <<<"$list" || { echo "missing collection: $name"; return 1; }
    done < <(sed -n 's/^ *- *{name: \([^,]*\),.*/\1/p' "$packages/ansible-collections.yml")
}

pwsh_modules_import() {
    pwsh -NoProfile -NonInteractive -Command \
        'Import-Module VMware.VimAutomation.Core, VMware.vSphere.SsoAdmin, Pester -ErrorAction Stop'
}

pip_no_index() {
    local dir
    dir=$(mktemp -d)
    /opt/venv/bin/pip install --quiet --no-index --find-links /opt/python-wheels \
        --target "$dir" -r "$packages/python.txt"
}

check "terraform init from the provider cache" terraform_init
check "packer init from the plugin cache" packer_init
check "ansible-galaxy lists every collection" collections_listed
check "pwsh imports PowerCLI, SsoAdmin and Pester" pwsh_modules_import
check "pip install --no-index resolves every package in python.txt" pip_no_index
for tool in ansible ansible-playbook ansible-vault ansible-galaxy ansible-lint molecule pwsh; do
    check "$tool runs" timeout 60 "$tool" --version
done
