# Providers for the ALL-IN-ONE stack: OKE infra + WEKA layer in a single apply.
#
# The two oci providers (default + oci.home alias) drive the OKE module. The
# kubernetes/helm/kubectl providers talk to the cluster THIS stack creates — their
# endpoint/CA come from the kube-config data source (keyed on the in-stack
# module.oke.cluster_id, so it's resolved during apply after the cluster exists),
# and the bearer token is minted per-call by the `oci ce cluster generate-token`
# exec plugin. Verified: the OCI Resource Manager runner ships the oci CLI and
# authenticates with no --auth flag (oci_cli_auth = ""), so this whole stack runs
# one-click in the ORM Console.

terraform {
  required_version = ">= 1.4.0" # terraform_data (capacity preflight gate)

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.14.0"
    }
    helm = {
      # >= 3.0.1 to satisfy the terraform-oci-oke module (which requires helm v3).
      source  = "hashicorp/helm"
      version = ">= 3.0.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.config_file_profile
}

provider "oci" {
  alias               = "home"
  region              = coalesce(var.home_region, var.region)
  config_file_profile = var.config_file_profile
}

# Connection to the cluster created in this same apply. cluster_id is unknown at
# plan time, so this data source (and the provider configs below) resolve during
# apply, after module.oke has created the control plane.
data "oci_containerengine_cluster_kube_config" "this" {
  cluster_id = module.oke.cluster_id
}

locals {
  kubeconfig   = yamldecode(data.oci_containerengine_cluster_kube_config.this.content)
  cluster_ca   = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  cluster_host = local.kubeconfig.clusters[0].cluster.server

  # OKE token exec-plugin auth (named distinctly from weka_data_network.tf's
  # oci_auth_args). Same 3-way logic: --profile (local) > --auth (host) > none
  # (ORM runner / Cloud Shell, which are pre-authenticated).
  k8s_oci_auth_args = (
    var.config_file_profile != null ? ["--profile", var.config_file_profile] :
    trimspace(var.oci_cli_auth == null ? "" : var.oci_cli_auth) != "" ? ["--auth", var.oci_cli_auth] :
    []
  )
  exec_args = concat(
    ["ce", "cluster", "generate-token", "--cluster-id", module.oke.cluster_id, "--region", var.region],
    local.k8s_oci_auth_args,
  )
}

provider "kubernetes" {
  host                   = local.cluster_host
  cluster_ca_certificate = local.cluster_ca

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = local.exec_args
  }
}

provider "kubectl" {
  host                   = local.cluster_host
  cluster_ca_certificate = local.cluster_ca
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = local.exec_args
  }
}

provider "helm" {
  # helm provider v3: `kubernetes` is an attribute (= {…}), and `exec` within it is
  # a nested attribute object — not the v2 nested blocks.
  kubernetes = {
    host                   = local.cluster_host
    cluster_ca_certificate = local.cluster_ca

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args        = local.exec_args
    }
  }
}
