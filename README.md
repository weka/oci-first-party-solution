# oci-first-party-solution — OKE cluster for WEKA

Terraform for a managed **OKE** (Oracle Kubernetes Engine) cluster on OCI, built on the
upstream [`terraform-oci-oke`](https://github.com/oracle-terraform-modules/terraform-oci-oke)
module (v5.5.0). It stands up a converged OKE node pool that the WEKA operator and WEKA
custom resources get layered onto afterwards.

Sizing/topology have working defaults; the account-specific values (`tenancy_id`,
`compartment_id`) are required inputs. By default the module builds a **fresh VCN**.

## Files

| File | Purpose |
|---|---|
| `providers.tf` | Terraform + the two required `oci` providers (default + `oci.home` alias); auth via a `~/.oci/config` profile |
| `variables.tf` | All inputs (required: `tenancy_id`, `compartment_id`) |
| `main.tf` | The `terraform-oci-oke` module block (VCN, cluster, converged node pool + WEKA node prep) |
| `outputs.tf` | `cluster_id`, `cluster_endpoints`, and a ready-to-run `create_kubeconfig` command |
| `terraform.tfvars.example` | Copy to `terraform.tfvars`; shows required vars + how to reuse an existing VCN |

## Prerequisites

- `terraform` >= 1.3, the `oci` CLI, and a working `~/.oci/config` (see `config_file_profile`).
- An SSH public key (default `~/.ssh/id_rsa.pub`; override `ssh_public_key_path`).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in tenancy_id + compartment_id
terraform init
terraform plan
terraform apply

# Write a kubeconfig (the exact command is also emitted as an output):
terraform output -raw create_kubeconfig_command | bash
export KUBECONFIG=~/weka-oke.yaml
export OCI_CLI_PROFILE=DEFAULT        # OKE kubeconfig auth shells out to the oci CLI
kubectl get nodes
```

Expect **~13–16 min** for the cluster (the control plane is the long pole). The control-plane
endpoint is public by default (`control_plane_allowed_cidrs = ["0.0.0.0/0"]`, tighten for real
use) so `kubectl` works directly — no bastion/operator host.

### WEKA node prep (built in)

WEKA has three requirements the stock module doesn't provide, all handled here:

- **hugepages** — configured via the worker pool's cloud-init (`node_hugepages`, default 8000 × 2Mi).
- **drives** — a managed OKE node pool can't attach data block volumes via Terraform, so the
  default shape is `VM.DenseIO.E5.Flex` (local NVMe), which the WEKA operator's sign-drives policy
  discovers as `weka.io/drives`. That shape only accepts fixed OCPU:memory:NVMe combos
  (1 NVMe per 8 OCPU); the default 16 OCPU / 192 GB yields 2 NVMe and enough cores for WEKA.
- **data-plane security** (`weka_data_network.tf`) — WEKA's ensure-nics attaches a secondary
  "data" VNIC per IO node with **no NSG**, but the OKE module puts all intra-cluster allow rules
  on the worker NSG (scoped to NSG membership) and leaves the worker subnet on an empty,
  locked-down default security list. Without a fix the DPDK data plane gets no allow coverage, so
  backends never join (`WAIT_IO_NODES` / "Network port inactivity") and the cluster hangs in
  `Init`. `weka_data_network.tf` attaches a security list allowing all intra-VCN traffic to the
  worker subnet — a subnet security list covers every VNIC regardless of NSG membership. Because
  the module marks the subnet's `security_list_ids` `ignore_changes`, the attach is done via the
  `oci` CLI in a `null_resource` (so `terraform apply`/`destroy` needs the `oci` CLI + the same
  `config_file_profile` on PATH, which the kubeconfig step already requires).

## Layering WEKA on top

This Terraform provisions the **cluster only**. Once the OKE cluster is up and `kubectl get nodes`
works (see [Usage](#usage)), layer WEKA on top.

### 1. Install the operator + image pull secrets

`scripts/install-weka-operator.sh` installs the WEKA operator (v1.14.1) and creates the
`quay.io-robot-secret` image pull secret in both `weka-operator-system` (the operator's own
namespace) and `default` (where the WEKA custom resources below live). It requires the quay.io
robot credentials as env vars — fetch them from [get.weka.io](https://get.weka.io); the script
exits early if they're not set:

```bash
export QUAY_USERNAME=... QUAY_PASSWORD=...
./scripts/install-weka-operator.sh
```

### 2. Apply the WEKA custom resources

With the operator running, `kubectl apply` the manifests in `crds/` (WekaPolicy sign-drives +
ensure-nics, WekaCluster, WekaClient):

```bash
kubectl apply -f crds/
```

## Teardown

```bash
terraform destroy
```

OKE clusters do **not** auto-expire — destroy explicitly to free quota. A DenseIO node pool can
occasionally have a slow/stuck node termination; re-run `terraform destroy` if it errors out.
