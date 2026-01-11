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
    kubectl_manifest.argocd_repo_gitops,
    kubectl_manifest.argocd_repo_gitops
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
# Kubernetes Manifest - Provider Family Azure (Direct)
################################################################################

resource "kubectl_manifest" "provider_family_azure" {
  yaml_body = <<-YAML
    apiVersion: pkg.crossplane.io/v1
    kind: Provider
    metadata:
      name: upbound-provider-family-azure
      namespace: ${local.namespaces.resources}
    spec:
      package: xpkg.upbound.io/upbound/provider-family-azure:${var.crossplane_provider_family_azure_version}
      packagePullPolicy: Always
  YAML

  depends_on = [
    kubectl_manifest.argocd_app_crossplane,
    kubernetes_secret.crossplane_azure_credentials,
    time_sleep.interval_before_crossplane_installation
  ]
}

################################################################################
# Kubernetes Manifest - Provider Azure Cache (Direct)
################################################################################

resource "kubectl_manifest" "provider_azure_cache" {
  yaml_body = <<-YAML
    apiVersion: pkg.crossplane.io/v1
    kind: Provider
    metadata:
      name: provider-redis-azure
      namespace: ${local.namespaces.resources}
    spec:
      package: xpkg.upbound.io/upbound/provider-azure-cache:${var.crossplane_provider_azure_cache_version}
      packagePullPolicy: Always
  YAML

  depends_on = [
    kubectl_manifest.argocd_app_crossplane,
    kubernetes_secret.crossplane_azure_credentials,
    time_sleep.interval_before_crossplane_installation
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
apiVersion: azure.m.upbound.io/v1beta1
kind: ClusterProviderConfig
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
    kubectl_manifest.provider_family_azure,
    kubectl_manifest.provider_azure_cache,
    azurerm_role_assignment.crossplane_contributor,
    kubernetes_secret.crossplane_azure_credentials,
    time_sleep.interval_before_crossplane_installation
  ]
}
