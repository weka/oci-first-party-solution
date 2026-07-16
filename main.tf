# OKE cluster for running WEKA, provisioned with the upstream terraform-oci-oke
# module: a converged OKE node pool on OCI that the WEKA operator + WEKA CRs get
# layered onto afterwards.
#
# The WEKA layer (operator install, image pull secret, WekaPolicy/WekaCluster/
# WekaClient manifests) is intentionally NOT managed here — apply it after the
# cluster is up (see README), keeping cluster infra separate from the WEKA stack.

locals {
  # WEKA node prep injected as OKE cloud-init: register the node via the OKE
  # init script, grow the root fs, then configure hugepages + kubelet static CPU
  # policy — WEKA drive/compute containers request hugepages-2Mi and won't
  # schedule without them. We fully own the node bring-up
  # (disable_default_cloud_init), so this script must also run the stock OKE init.
  worker_cloud_init = <<-EOT
    #!/bin/bash
    curl -fH "Authorization: Bearer Oracle" -L0 169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 -d > /var/run/oke-init.sh
    bash /var/run/oke-init.sh

    # extend root disk
    bash /usr/libexec/oci-growfs -y

    # wait for kubelet before touching its config
    for i in $(seq 1 60); do
      systemctl is-active kubelet && break
      sleep 5
    done
    systemctl is-active kubelet && systemctl stop kubelet

    # hugepages (WEKA requirement)
    echo ${var.node_hugepages} > /proc/sys/vm/nr_hugepages
    sysctl -w vm.nr_hugepages=${var.node_hugepages}
    grep -q hugetlbfs /proc/mounts || { mkdir -p /mnt/huge && mount -t hugetlbfs none /mnt/huge; }

    # kubelet static CPU manager policy
    CONFIG_PATH="/etc/kubernetes/kubelet/kubelet-config.json"
    cat <<< $(jq '.systemReserved.cpu = "1"' "$CONFIG_PATH") > "$CONFIG_PATH"
    cat <<< $(jq '.cpuManagerPolicy = "static"' "$CONFIG_PATH") > "$CONFIG_PATH"
    systemctl start kubelet
  EOT

  # The module's own default subnet/NSG maps. We pass these when building a
  # fresh VCN so that a null `subnets`/`nsgs` var keeps the module defaults,
  # while still letting callers override for existing-network reuse.
  default_subnets = {
    bastion  = { newbits = 13 }
    operator = { newbits = 13 }
    cp       = { newbits = 13 }
    int_lb   = { newbits = 11 }
    pub_lb   = { newbits = 11 }
    workers  = { newbits = 4 }
    pods     = { newbits = 2 }
  }

  default_nsgs = {
    bastion  = {}
    operator = {}
    cp       = {}
    int_lb   = {}
    pub_lb   = {}
    workers  = {}
    pods     = {}
  }

  # Single converged node pool (WEKA backends + clients).
  worker_pools = {
    (var.node_pool_name) = {
      description      = "WEKA converged node pool"
      mode             = "node-pool"
      size             = var.node_count
      shape            = var.node_shape
      ocpus            = var.node_ocpus
      memory           = var.node_memory_gb
      boot_volume_size = var.node_boot_volume_gb
      # WEKA converged node labels (backends + clients).
      node_labels = {
        "weka.io/tool"              = "terraform-oci-oke"
        "weka.io/supports-backends" = "true"
        "weka.io/supports-clients"  = "true"
      }
      # Own the node bring-up so we can add the WEKA hugepages/kubelet prep.
      disable_default_cloud_init = true
      cloud_init = [{
        content      = local.worker_cloud_init
        content_type = "text/x-shellscript"
      }]
    }
  }
}

module "oke" {
  source  = "oracle-terraform-modules/oke/oci"
  version = "5.5.0"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  # Tenancy / region
  tenancy_id     = var.tenancy_id
  compartment_id = var.compartment_id
  region         = var.region
  home_region    = coalesce(var.home_region, var.region)

  # SSH access to nodes
  ssh_public_key_path = var.ssh_public_key_path

  # Networking — fresh VCN by default; reuse existing when create_vcn = false.
  create_vcn = var.create_vcn
  vcn_id     = var.vcn_id
  vcn_cidrs  = var.vcn_cidrs
  subnets    = coalesce(var.subnets, local.default_subnets)
  nsgs       = coalesce(var.nsgs, local.default_nsgs)

  # Cluster
  create_cluster              = true
  cluster_name                = var.cluster_name
  cluster_type                = var.cluster_type
  kubernetes_version          = var.kubernetes_version
  cni_type                    = var.cni_type
  control_plane_is_public     = var.control_plane_is_public
  control_plane_allowed_cidrs = var.control_plane_allowed_cidrs
  # v5.x splits "public endpoint" (subnet placement) from "assign a public IP to
  # the API endpoint"; we need both true so kubectl reaches the cluster directly.
  assign_public_ip_to_control_plane = var.control_plane_is_public

  # We drive kubectl/wekakube from the laptop against the public API endpoint,
  # so the private bastion + operator hosts aren't needed. Skipping the IAM
  # dynamic groups/policies keeps this a minimal, low-permission dev cluster.
  create_bastion       = false
  create_operator      = false
  create_iam_resources = false

  # Workers — managed OKE node pool, OKE (Oracle Linux) image.
  worker_pool_mode        = "node-pool"
  worker_image_type       = "oke"
  worker_image_os         = "Oracle Linux"
  worker_image_os_version = var.worker_image_os_version
  worker_pools            = local.worker_pools

  # Emit cluster_kubeconfig in outputs as a fallback (we normally generate the
  # kubeconfig with `oci ce cluster create-kubeconfig` in the skill).
  output_detail = true
}
