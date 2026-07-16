output "cluster_id" {
  description = "OCID of the created OKE cluster. Feed this to `oci ce cluster create-kubeconfig`."
  value       = module.oke.cluster_id
}

output "cluster_endpoints" {
  description = "OKE control-plane endpoints (public/private API server addresses)."
  value       = module.oke.cluster_endpoints
}

output "region" {
  description = "Region the cluster lives in (for create-kubeconfig)."
  value       = var.region
}

output "create_kubeconfig_command" {
  description = "Ready-to-run command to write a kubeconfig for this cluster."
  value = format(
    "oci ce cluster create-kubeconfig --cluster-id %s --file ~/%s.yaml --region %s --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT --profile %s",
    module.oke.cluster_id, var.cluster_name, var.region, var.config_file_profile,
  )
}
