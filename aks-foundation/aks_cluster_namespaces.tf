locals {
  namespaces = {
    jarvix        = "jarvix-system"
    devops        = "devops-system"
    gateway       = "gateway-system"
    observability = "observability-system"
    pipeline      = "pipeline-system"
    security      = "security-system"
    test          = "test-system"
    storage       = "storage-system"
    ai            = "ai-system"
    control_plane = "control-plane-system"
  }
}

# Create Namespaces using foreach local.namespaces values
resource "kubernetes_namespace" "namespaces" {
  for_each = local.namespaces

  metadata {
    name = each.value
    # annotations = {
    #   "downscaler/uptime" = "Mon-Fri 9:00-18:00 America/Sao_Paulo"
    # }
  }

  depends_on = [ azurerm_kubernetes_cluster.main ]

  # lifecycle {
  #   ignore_changes = [
  #     metadata[0].annotations["downscaler/force-uptime"],
  #     metadata[0].annotations["downscaler/force-downtime"],
  #     metadata[0].labels["downscaler/manual"]
  #   ]
  # }
}
