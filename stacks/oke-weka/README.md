# oke-weka — all-in-one (cluster + WEKA operator) one-click stack

<!-- Works once the repo is public and a vX.Y.Z release is tagged. -->
[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/weka/oci-first-party-solution/releases/latest/download/oke-weka.zip)

A **single** OCI Resource Manager stack that does the whole thing in **one apply**:

1. OKE cluster + converged DenseIO node pool (hugepages, local NVMe, WEKA node prep)
2. the intra-VCN data-plane security-list fix (`weka_data_network.tf`)
3. the WEKA operator (Helm), quay.io image pull secrets, and the
   WekaPolicy / WekaCluster / WekaClient custom resources (`weka.tf`)

This is the one-click alternative to running the separate [`../oke-infra`](../oke-infra)
then [`../weka-layer`](../weka-layer) stacks. Same building blocks, one deploy.

## How the single apply works

- The `oci` (+ `oci.home`) providers build the cluster via the `terraform-oci-oke` module.
- The `kubernetes`/`helm`/`kubectl` providers connect to the cluster **created in this same apply**:
  their endpoint/CA come from `data.oci_containerengine_cluster_kube_config` keyed on
  `module.oke.cluster_id` (unknown at plan → resolved during apply, after the control plane exists),
  and the API token is minted by the `oci ce cluster generate-token` exec plugin.
- The WEKA resources `depends_on = [module.oke]`, so the operator install waits until the cluster,
  the worker node pool, and the network fix are all done.

## One-click in Resource Manager

The `oci` CLI is used for two calls (the subnet attach and the OKE token). **Verified: the ORM
runner ships `oci`/`kubectl`/`helm` and is pre-authenticated**, so with the defaults
(`oci_cli_auth = ""`, no `--auth` flag) this stack runs start-to-finish in the **ORM Console**:

1. **Resource Manager → Stacks → Create stack** from a zip of this folder (or a source-control
   config provider with working dir `stacks/oke-weka`).
2. Fill the form (`schema.yaml`): compartment, **quay.io creds**, SSH key (paste content), and
   sizing — pick a **flavor**. *production* (DenseIO + local NVMe) is sized by a **target usable
   capacity (TB)**: the stack derives the worker count, using WEKA protection that adapts to size —
   `x+2+1` below 21 nodes (`~6.12 TB` usable per data drive) and `16+4+1` at 21+ nodes (double
   protection needs 16+4+1 = 21 servers), scaling past 21 at `~4.9 TB`/node. Reference points:
   ~18 TB at the 6-node minimum (3+2+1), ~43 TB at 10 nodes (7+2+1), ~98 TB at 19-21 nodes. The
   derived scheme + capacity is printed as the `weka_sizing` output. *non-production* (Standard +
   block volume) instead takes an instance count (min 6) and a per-node data-volume size.
3. **Plan**, then **Apply**. When it finishes, the cluster is up *and* WEKA is installed.

> The `kubernetes`/`helm`/`kubectl` **providers** are self-contained (no `kubectl`/`helm` binaries).
> The one external tool is `oci`, which the runner already has. Cloud Shell / local work too — see
> the auth table below.

| Where you apply | Set | `oci` CLI auth |
|---|---|---|
| **ORM runner** (Console) | nothing (defaults) | none — runner's delegation/OBO token |
| **OCI Cloud Shell** | nothing (defaults) | none — session token |
| **Local** | `config_file_profile = "<profile>"` | `--profile <profile>` |

## Local / Cloud Shell

```bash
cd stacks/oke-weka
cp terraform.tfvars.example terraform.tfvars   # tenancy_id, compartment_id, quay creds (+ profile for local)
terraform init && terraform apply              # ~15–20 min: cluster + WEKA
terraform output -raw create_kubeconfig_command | bash
export KUBECONFIG=~/weka-cluster.yaml
kubectl get pods -n weka-operator-system       # operator Running
kubectl get wekacluster dev -n default -w      # forms → healthy
```

## Security posture (accepted)

The OKE API endpoint is **public and reachable from `0.0.0.0/0`** — not for laptop `kubectl`, but
because this stack installs WEKA over the Kubernetes API **from the ORM / Marketplace runner, which
is outside your VCN**, so the endpoint must be reachable for the install to succeed. The endpoint is
still **token-authenticated** (short-lived OCI/OKE tokens). This is an accepted, documented default
(see [`SECURITY.md`](../../SECURITY.md)).

**Hardening (optional, not implemented here):** for a fully private control plane, install WEKA from
**inside the VCN** — enable the module's operator host (`create_operator = true`) and run the Helm
install + `kubectl apply` from it via cloud-init, then set `control_plane_is_public = false`. That
removes the public endpoint entirely at the cost of an always-on operator VM and dropping the
in-stack helm/kubectl providers for the WEKA layer.

## Caveats

- **Same-apply provider auth** (k8s providers targeting a cluster built in the same run) is the
  standard OKE/EKS/GKE one-click pattern and works, but it's more fragile than two stacks on
  *replacement* — if you ever recreate the cluster, prefer `terraform apply` in two phases or use
  the separate `../oke-infra` + `../weka-layer` stacks.
- **DenseIO capacity:** `VM.DenseIO.E5.Flex` (production flavor) is frequently *out-of-host-capacity*.
  If the node pool fails to launch, retry, lower `target_usable_tb` (fewer workers), pin ADs via
  `worker_placement_ads`, or try another region/AD. (This is an OCI availability constraint, not a
  config issue.)
- The WEKA CRs are **bundled** in this stack's own [`crds/`](crds) (copies of the repo-root
  `crds/`) so the stack is self-contained — a standalone zip (ORM upload / publish) includes them.
  Keep the two in sync if you edit the manifests.

## Teardown

```bash
terraform destroy
```
(or an ORM **Destroy** job). DenseIO nodes burn quota — destroy when done.
