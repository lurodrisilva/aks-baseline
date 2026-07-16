# # ################################################################################
# # # ArgoCD Application - Workload Identity Installation
# # ################################################################################

# resource "kubectl_manifest" "workload_identity_app" {
#   yaml_body = <<-YAML
# apiVersion: argoproj.io/v1alpha1
# kind: Application
# metadata:
#   name: azure-workload-identity
#   namespace: ${local.namespaces.devops}
# spec:
#   project: addons-project
#   source:
#     chart: workload-identity-webhook
#     repoURL: https://azure.github.io/azure-workload-identity/charts
#     targetRevision: 1.5.1
#     helm:
#       parameters:
#         - name: azureTenantID
#           value: "${data.azurerm_client_config.current.tenant_id}"
#   destination:
#     server: https://kubernetes.default.svc
#     namespace: ${local.namespaces.resources}
#   syncPolicy:
#     automated:
#       prune: true
#       selfHeal: true
#     syncOptions:
#       - CreateNamespace=true
#       - ServerSideApply=true
#     retry:
#       limit: 5
#       backoff:
#         duration: 5s
#         factor: 2
#         maxDuration: 3m
#   YAML

#   depends_on = [
#     kubernetes_namespace.namespaces,
#     helm_release.argocd,
#     kubectl_manifest.argocd_project_addons,
#     kubectl_manifest.argocd_repo_gitops,
#     kubectl_manifest.argocd_repo_gitops
#   ]
# }

# Federated identity credential removed: using Service Principal auth

# ################################################################################
# # ArgoCD Application - Crossplane Installation
# ################################################################################

resource "kubectl_manifest" "argocd_app_crossplane" {
  yaml_body = <<-YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane
  namespace: ${local.namespaces.control_plane}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: addons-project
  source:
    repoURL: https://charts.crossplane.io/stable
    targetRevision: 2.1.3
    chart: crossplane
    helm:
      releaseName: crossplane
      # Safe Start. The chart defaults provider.defaultActivations to ["*"], which makes the
      # init container run `crossplane core init --activation "*"` and create a `default`
      # ManagedResourceActivationPolicy activating every managed resource a provider ships.
      #
      # That is not survivable here. Installing provider-azure-network under the wildcard
      # activated ~238 resource definitions at once and took this cluster's API server offline
      # for roughly 15 minutes (SKU is Free, so the control plane is capped and has no SLA):
      # discovery returned ServiceUnavailable and every provider flapped Installed=False.
      #
      # Emptying it drops the flag entirely, so no wildcard policy is created and MRDs keep
      # their Inactive default. plat-eng-control-plane then activates only the handful of
      # resources its Compositions actually compose. Activation policies are additive, so this
      # must be empty for that narrow policy to mean anything.
      #
      # Use values, not parameters: `--set provider.defaultActivations={}` renders
      # `--activation ""` (an empty-string activation) rather than removing the flag.
      values: |
        provider:
          defaultActivations: []
  destination:
    server: https://kubernetes.default.svc
    namespace: ${local.namespaces.resources}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m

  YAML

  depends_on = [
    kubernetes_namespace.namespaces,
    helm_release.argocd,
    kubectl_manifest.argocd_project_addons,
    kubectl_manifest.argocd_repo_addons,
  ]
}

# Terraform-native wait (no shell): pause after ArgoCD app creation to allow sync
resource "time_sleep" "wait_for_crossplane_argocd_sync" {
  create_duration = "${var.argocd_app_wait_timeout_seconds}s"

  depends_on = [
    kubectl_manifest.argocd_app_crossplane
  ]
}

resource "time_sleep" "interval_before_crossplane_installation" {

  create_duration = var.interval_before_cluster_update

  depends_on = [
    azurerm_kubernetes_cluster.main,
    kubectl_manifest.argocd_app_crossplane,
    time_sleep.wait_for_crossplane_argocd_sync
  ]
}

# ################################################################################
# # ArgoCD Application - Provider Family Azure - REMOVE
# ################################################################################

# resource "kubectl_manifest" "argocd_crossplane_provider_plugin" {
#   yaml_body = <<-YAML
# apiVersion: v1
# kind: ConfigMap
# metadata:
#   name: crossplane-provider-plugin
#   namespace: ${local.namespaces.devops}
# data:
#   plugin.yaml: |
#     apiVersion: argoproj.io/v1alpha1
#     kind: ConfigManagementPlugin
#     metadata:
#       name: crossplane-provider
#     spec:
#       generate:
#         command: ["/bin/sh", "-c"]
#         args:
#           - |
#             cat <<EOF
#             apiVersion: pkg.crossplane.io/v1
#             kind: Provider
#             metadata:
#               name: $${PROVIDER_NAME}
#               namespace: resources-system
#             spec:
#               package: $${PROVIDER_PACKAGE}
#               revisionActivationPolicy: Automatic
#               revisionHistoryLimit: 1
#             EOF
#   YAML

#   depends_on = [
#     kubectl_manifest.argocd_app_crossplane
#     # kubectl_manifest.argocd_project_addons
#   ]
# }

# ################################################################################
# # ArgoCD Application - Provider Family Azure - REMOVE
# ################################################################################

# resource "kubectl_manifest" "argocd_app_provider_family_azure" {
#   yaml_body = <<-YAML
# apiVersion: argoproj.io/v1alpha1
# kind: Application
# metadata:
#   name: provider-family-azure
#   namespace: ${local.namespaces.devops}
#   finalizers:
#     - resources-finalizer.argocd.argoproj.io
# spec:
#   project: addons-project
#   source:
#     repoURL: https://github.com/crossplane/crossplane
#     targetRevision: HEAD
#     path: .
#     plugin:
#       name: crossplane-provider
#       env:
#         - name: PROVIDER_PACKAGE
#           value: xpkg.upbound.io/upbound/provider-family-azure:${var.crossplane_provider_family_azure_version}
#         - name: PROVIDER_NAME
#           value: upbound-provider-family-azure
#   destination:
#     server: https://kubernetes.default.svc
#     namespace: ${local.namespaces.resources}
#   syncPolicy:
#     automated:
#       prune: true
#       selfHeal: true
#     syncOptions:
#       - CreateNamespace=true
#     retry:
#       limit: 5
#       backoff:
#         duration: 5s
#         factor: 2
#         maxDuration: 3m
# YAML

#   depends_on = [
#     kubectl_manifest.argocd_app_crossplane,
#     kubectl_manifest.argocd_crossplane_provider_plugin
#     # kubectl_manifest.argocd_project_addons
#   ]
# }

################################################################################
# Crossplane Providers
################################################################################
# NOTE: Provider CRs (upbound-provider-family-azure, upbound-provider-azure-cache,
# upbound-provider-azure-network) are managed declaratively by the ArgoCD
# `providers` application defined in 00-aks-baseline/addon_charts/providers.
#
# They were previously also created directly here via `kubectl_manifest`, which
# duplicated the `xpkg.upbound.io/upbound/provider-azure-cache` package in the
# Crossplane dependency graph (one from `provider-redis-azure` v2.3.0 here, one
# from `upbound-provider-azure-cache` v2.5.2 in the chart) and produced:
#   "cannot initialize dependency graph from the packages in the lock:
#    node xpkg.upbound.io/upbound/provider-azure-cache already exists"
# degrading every provider in the family. Ownership is now solely ArgoCD's.

# Wait for Crossplane providers to register their CRDs with the API server.
# Provider packages need time to download, start pods, and establish CRDs.
# See: https://github.com/crossplane/crossplane/issues/5828
resource "time_sleep" "wait_for_crossplane_provider_crds" {
  create_duration = var.interval_before_crossplane_installation

  depends_on = [
    kubectl_manifest.argocd_app_crossplane,
    time_sleep.interval_before_crossplane_installation,
  ]
}

# ################################################################################
# # Kubernetes Secret - Azure Credentials
# ################################################################################

resource "kubernetes_secret" "crossplane_azure_credentials" {
  metadata {
    name      = "azure-crossplane-credentials"
    namespace = local.namespaces.resources
  }

  data = {
    credentials = jsonencode({
      clientId       = azuread_application.crossplane.client_id
      clientSecret   = azuread_application_password.crossplane.value
      subscriptionId = data.azurerm_subscription.current.subscription_id
      tenantId       = data.azurerm_client_config.current.tenant_id
    })
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.namespaces,
    azuread_application_password.crossplane
  ]
}

# Workload Identity runtime config removed: using Service Principal auth



################################################################################
# ProviderConfig
################################################################################

resource "kubectl_manifest" "crossplane_provider_config" {
  yaml_body = <<-YAML
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      name: azure-crossplane-credentials
      namespace: ${local.namespaces.resources}
      key: credentials
  YAML

  depends_on = [
    time_sleep.wait_for_crossplane_provider_crds,
    azurerm_role_assignment.crossplane_contributor,
    kubernetes_secret.crossplane_azure_credentials,
  ]
}
