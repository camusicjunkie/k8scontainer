# Terraform providers mirrored into /usr/local/share/terraform/plugins, a
# directory Terraform searches on its own, so `terraform init` finds them
# offline. Each is held to its current major version; MANIFEST records the
# versions resolved at build.
terraform {
  required_providers {
    vsphere    = { source = "vmware/vsphere", version = "~> 2.0" }
    vault      = { source = "hashicorp/vault", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    local      = { source = "hashicorp/local", version = "~> 2.0" }
    null       = { source = "hashicorp/null", version = "~> 3.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}
