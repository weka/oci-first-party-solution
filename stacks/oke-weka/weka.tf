# WEKA layer, installed in the same apply as the cluster (module.oke).
#
# depends_on = [module.oke] on the first k8s resource + the Helm release makes the
# whole WEKA layer wait until the cluster AND its worker node pool AND the
# data-plane security-list fix are done — otherwise the operator pods would have no
# nodes to schedule on. gavinbunney/kubectl resolves the CR kinds at apply time, so
# the CRs tolerate the CRDs having just been installed by the Helm chart.
#
# NOTE: the CR manifests are BUNDLED in this stack's own crds/ dir (not the repo
# root) so the stack is self-contained — a standalone zip (ORM upload / publish /
# Deploy-to-Oracle-Cloud) includes them. Keep stacks/oke-weka/crds in sync with
# the repo-root crds/ (they are copies).

locals {
  operator_namespace     = "weka-operator-system"
  pull_secret_namespaces = toset([local.operator_namespace, "default"])

  dockerconfigjson = jsonencode({
    auths = {
      "quay.io" = {
        username = var.quay_username
        password = var.quay_password
        email    = var.quay_username
        auth     = base64encode("${var.quay_username}:${var.quay_password}")
      }
    }
  })
}

resource "kubernetes_namespace_v1" "operator" {
  metadata {
    name = local.operator_namespace
  }

  # Wait for the full cluster (control plane + node pool + network fix).
  depends_on = [module.oke]
}

resource "kubernetes_secret_v1" "quay" {
  for_each = local.pull_secret_namespaces

  metadata {
    name      = "quay-io-robot-secret"
    namespace = each.value
  }

  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = local.dockerconfigjson
  }

  depends_on = [kubernetes_namespace_v1.operator]
}

resource "helm_release" "weka_operator" {
  name       = "weka-operator"
  repository = "oci://quay.io/weka.io/helm"
  chart      = "weka-operator"
  version    = var.operator_version
  namespace  = kubernetes_namespace_v1.operator.metadata[0].name

  # Chart-bundled CRDs install automatically; wait=true blocks until the release
  # is ready before the CRs apply.
  depends_on = [kubernetes_secret_v1.quay, module.oke]

  # Fail loudly (on this always-present resource) if the bundled CR manifests are
  # missing, instead of silently applying zero custom resources via an empty
  # fileset on kubectl_manifest.weka_cr.
  lifecycle {
    precondition {
      condition     = length(fileset("${path.module}/crds", "*.yaml")) > 0
      error_message = "No CR manifests in ${path.module}/crds — the stack zip must bundle crds/*.yaml."
    }
  }
}

resource "kubectl_manifest" "weka_cr" {
  for_each = fileset("${path.module}/crds", "*.yaml")

  yaml_body = file("${path.module}/crds/${each.value}")

  depends_on = [helm_release.weka_operator, kubernetes_secret_v1.quay]
}
