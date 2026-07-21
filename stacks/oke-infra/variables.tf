# Inputs for the OKE cluster. Sizing/topology have sensible defaults; the
# account-specific values (compartment_id, tenancy_id) are required — set them
# in terraform.tfvars (see terraform.tfvars.example) or via -var / TF_VAR_*.

# ---------------------------------------------------------------------------
# Auth / tenancy
# ---------------------------------------------------------------------------
variable "config_file_profile" {
  description = <<-EOT
    Profile in ~/.oci/config to authenticate with for LOCAL / Cloud Shell runs
    (e.g. "DEFAULT"). Leave null when running in OCI Resource Manager: ORM injects
    resource-principal credentials automatically, and a null profile also switches
    the weka-data security-list attach (weka_data_network.tf) to
    `--auth resource_principal` instead of `--profile`.
  EOT
  type        = string
  default     = null
}

variable "oci_cli_auth" {
  description = <<-EOT
    Auth mode for the out-of-band `oci` CLI call (the worker-subnet security-list
    attach in weka_data_network.tf), passed as `--auth <mode>`. Only used when
    config_file_profile is null:
      - ""  (empty, default) — no --auth flag; the environment is pre-authenticated.
        Correct for BOTH the OCI Resource Manager runner (delegation/OBO token) and
        OCI Cloud Shell (session token) — verified: the ORM runner has the oci CLI
        and works with no flag, but NOT with --auth resource_principal.
      - "instance_principal"  — an operator/compute host in a dynamic group.
      - "resource_principal"  — only where OCI_RESOURCE_PRINCIPAL_* is set (NOT the ORM runner).
    Ignored when config_file_profile is set (local runs use --profile).
  EOT
  type        = string
  default     = ""
}

variable "region" {
  description = "OCI region for the OKE cluster (e.g. us-phoenix-1, us-ashburn-1, eu-frankfurt-1)."
  type        = string
  default     = "us-phoenix-1"
}

variable "home_region" {
  description = "Tenancy home region (identity ops). Defaults to var.region when null."
  type        = string
  default     = null
}

variable "tenancy_id" {
  description = "Tenancy OCID. Required."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID where OKE resources are created. Required."
  type        = string
}

# ---------------------------------------------------------------------------
# SSH — provide the key as CONTENT (ssh_public_key) or as a file PATH
# (ssh_public_key_path). The module prefers content when set and only reads the
# path otherwise, so use ssh_public_key in the ORM runner (no local files there)
# and ssh_public_key_path for local convenience.
# ---------------------------------------------------------------------------
variable "ssh_public_key" {
  description = "SSH public key CONTENT injected into worker nodes (use in the ORM runner). Takes precedence over ssh_public_key_path when set."
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file injected into worker nodes (local/Cloud Shell). Used only when ssh_public_key is null. Leave null in the ORM runner (no local files there); set a path for local runs, e.g. \"~/.ssh/id_rsa.pub\"."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Name of the OKE cluster."
  type        = string
  default     = "weka-oke"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the OKE control plane and node pool."
  type        = string
  default     = "v1.34.2"
}

variable "cluster_type" {
  description = "OKE cluster type: basic or enhanced."
  type        = string
  default     = "basic"
}

variable "cni_type" {
  description = "Pod networking CNI: flannel or npn."
  type        = string
  default     = "flannel"
}

variable "control_plane_is_public" {
  description = "Give the Kubernetes API endpoint a public IP so kubectl works directly from your laptop."
  type        = bool
  default     = true
}

variable "control_plane_allowed_cidrs" {
  description = "CIDRs allowed to reach the public control plane. The default is open; tighten to your IP for anything real."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# Worker node pool (converged WEKA nodes).
#
# WEKA needs local drives to sign. A managed OKE node pool can't attach data
# block volumes via Terraform, so we default to a DenseIO shape
# (VM.DenseIO.E5.Flex), whose local NVMe the WEKA operator's sign-drives policy
# discovers as `weka.io/drives`. That shape only accepts fixed OCPU:memory:NVMe
# combos (12 GB/OCPU, 1 NVMe per 8 OCPU): 8/96->1nvme, 16/192->2, 24/288->3, ...
# We default to the smallest tier, 8 OCPU / 96 GB (1 NVMe per node): enough for
# WEKA and the smallest DenseIO footprint, which also places most easily against
# DenseIO host-capacity limits. Bump node_ocpus/node_memory_gb together (same
# 12 GB/OCPU, +1 NVMe per +8 OCPU) for more per-node drives/cores.
# ---------------------------------------------------------------------------
variable "node_pool_name" {
  description = "Name of the worker node pool."
  type        = string
  default     = "converged"
}

variable "node_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 6
}

variable "worker_placement_ads" {
  description = <<-EOT
    Comma-separated availability-domain NUMBERS to place worker nodes in (e.g. "1,2").
    Empty (default) uses all ADs. Use it to steer the DenseIO node pool away from ADs
    that are out of host capacity (check with `oci compute compute-capacity-report`).
  EOT
  type        = string
  default     = ""
}

variable "node_shape" {
  description = "Worker node shape. DenseIO gives local NVMe for WEKA drives."
  type        = string
  default     = "VM.DenseIO.E5.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per worker node. VM.DenseIO.E5.Flex accepts 8/16/24/32/40/48 (1 NVMe per 8 OCPU). Default 8 = 1 NVMe (smallest DenseIO tier)."
  type        = number
  default     = 8
}

variable "node_memory_gb" {
  description = "Memory (GB) per worker node. VM.DenseIO.E5.Flex requires 12 GB/OCPU, so 8 OCPU => 96 GB."
  type        = number
  default     = 96
}

variable "node_boot_volume_gb" {
  description = "Boot volume size (GB) per worker node."
  type        = number
  default     = 200
}

variable "node_hugepages" {
  description = "Number of 2Mi hugepages to reserve per worker node (WEKA requirement). 8000 x 2Mi ~= 15.6 GB."
  type        = number
  default     = 8000
}

variable "worker_image_os_version" {
  description = "OKE worker image OS version. Oracle Linux 8 avoids the broken Ubuntu-OKE python3-venv that blocks the node init."
  type        = string
  default     = "8"
}

# ---------------------------------------------------------------------------
# Networking
#   Default: module builds a fresh VCN (create_vcn = true).
#   To reuse an existing VCN instead, set create_vcn = false and provide
#   vcn_id + subnets + nsgs (see terraform.tfvars.example).
# ---------------------------------------------------------------------------
variable "create_vcn" {
  description = "Create a fresh VCN (true) or reuse an existing one via vcn_id/subnets/nsgs (false)."
  type        = bool
  default     = true
}

variable "vcn_cidrs" {
  description = "IPv4 CIDR blocks for a freshly created VCN."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "vcn_id" {
  description = "Existing VCN OCID to reuse. Only used when create_vcn = false."
  type        = string
  default     = null
}

variable "subnets" {
  description = "Override the module subnets map. null => module defaults (fresh subnets). When reusing existing network, set { cp = { id = ... }, workers = { id = ... }, pub_lb = { id = ... } }."
  type        = any
  default     = null
}

variable "nsgs" {
  description = "Override the module NSG map. null => module defaults. When reusing existing network, set e.g. { cp = { id = ... }, workers = { id = ... } }."
  type        = any
  default     = null
}
