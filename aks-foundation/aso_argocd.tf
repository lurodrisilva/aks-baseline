################################################################################
# Azure Service Operator (v2) deployment via ArgoCD
# Reuses the existing service principal (azure-operators-sp)
################################################################################

# Ensure ASO namespace exists before creating credentials Secret
# resource "kubernetes_namespace" "aso_namespace" {
#   metadata {
#     name = "azureserviceoperator-system"
#   }

#   depends_on = [
#     azurerm_kubernetes_cluster.main
#   ]
# }

# Controller credential Secret consumed by ASO
# Keys as per ASO docs: AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET
resource "kubernetes_secret" "aso_controller_settings" {
  metadata {
    name      = "aso-controller-settings"
    # namespace = kubernetes_namespace.aso_namespace.metadata[0].name
    namespace = local.namespaces.resources
  }

  data = {
    AZURE_SUBSCRIPTION_ID = data.azurerm_subscription.current.subscription_id
    AZURE_TENANT_ID       = data.azurerm_client_config.current.tenant_id
    AZURE_CLIENT_ID       = azuread_application.crossplane.client_id
    AZURE_CLIENT_SECRET   = azuread_application_password.crossplane.value
  }

  type = "Opaque"

  depends_on = [
    local.namespaces,
    azuread_application_password.crossplane
  ]
}

# ArgoCD Application for Azure Service Operator v2
# Chart repo: https://raw.githubusercontent.com/Azure/azure-service-operator/main/v2/charts
# Chart name: azure-service-operator
resource "kubectl_manifest" "argocd_app_aso" {
  yaml_body = <<-YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: azure-service-operator
  namespace: ${local.namespaces.control_plane}
spec:
  project: addons-project
  source:
    repoURL: https://raw.githubusercontent.com/Azure/azure-service-operator/main/v2/charts
    chart: azure-service-operator
    targetRevision: v2.17.0
    helm:
      parameters:
        - name: crdPattern
          value: "resources.azure.com/*;keyvault.azure.com/*;managedidentity.azure.com/*;containerservice.azure.com/*"
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
    local.namespaces,
    kubernetes_secret.aso_controller_settings,
    helm_release.argocd,
    kubectl_manifest.argocd_project_addons,
    kubectl_manifest.argocd_repo_gitops
  ]
}
