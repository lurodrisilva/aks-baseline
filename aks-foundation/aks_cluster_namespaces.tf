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
    resources     = "resources-system"
  }

  # Labels applied per namespace. Held as a map rather than a conditional so a
  # second labelled namespace does not turn into a nested ternary.
  namespace_labels = {
    resources = {
      "azure.workload.identity/use" = "true"
    }

    # ADMITS ROUTES ON THE PUBLIC ORIGIN. The `platform-origin` Gateway only
    # accepts an HTTPRoute whose namespace carries this label, so the label is
    # the platform's route-admission control for an internet-facing hostname
    # (portal public-endpoint spec, slice P5). Before it, `allowedRoutes` was
    # `from: All` and any namespace on the cluster — including every tenant
    # application namespace — could attach a route claiming a path on that
    # hostname. Gateway API resolves a MORE SPECIFIC path in favour of the newer
    # route regardless of age, so `/api/v1/deployments` would have beaten the
    # governance API's own `/api/v1`.
    #
    # THIS ONE IS LOAD-BEARING FOR CERTIFICATE RENEWAL, not just for the portal.
    # The ACME HTTP-01 solver creates its challenge HTTPRoute in the
    # Certificate's namespace, and `platform-origin-tls` lives here. Remove this
    # label and renewal fails silently around 2026-09-24 — the certificate is in
    # the sign-in path, so recovery is waiting rather than acting. The
    # platform-origin-cert-unhealthy alert (slice P1b) is what would catch it.
    control_plane = {
      "platform-origin/publish" = "true"
    }
  }
}

# Create Namespaces using foreach local.namespaces values
resource "kubernetes_namespace" "namespaces" {
  for_each = local.namespaces

  metadata {
    name   = each.value
    labels = lookup(local.namespace_labels, each.key, null)
    # annotations = {
    #   "downscaler/uptime" = "Mon-Fri 9:00-18:00 America/Sao_Paulo"
    # }
  }

  depends_on = [azurerm_kubernetes_cluster.main]

  # lifecycle {
  #   ignore_changes = [
  #     metadata[0].annotations["downscaler/force-uptime"],
  #     metadata[0].annotations["downscaler/force-downtime"],
  #     metadata[0].labels["downscaler/manual"]
  #   ]
  # }
}
