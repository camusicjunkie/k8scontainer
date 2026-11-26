# Packer plugins installed into PACKER_PLUGIN_PATH (/usr/local/share/packer/plugins)
# so `packer init` finds them offline. Each is held to its current major
# version; MANIFEST records the versions resolved at build.
packer {
  required_plugins {
    vsphere = { source = "github.com/vmware/vsphere", version = "~> 2" }
    ansible = { source = "github.com/hashicorp/ansible", version = "~> 1" }
    git     = { source = "github.com/ethanmdavidson/git", version = "~> 0.6" }
  }
}
