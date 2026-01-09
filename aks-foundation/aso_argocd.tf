################################################################################
# Azure Service Operator (v2) deployment via ArgoCD
# Reuses the existing service principal (azure-operators-sp)
################################################################################

# Ensure ASO namespace exists before creating credentials Secret
resource "kubernetes_namespace" "aso_namespace" {
  metadata {
    name = "azureserviceoperator-system"
  }

  depends_on = [
    azurerm_kubernetes_cluster.main
  ]
}

# Controller credential Secret consumed by ASO
# Keys as per ASO docs: AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET
resource "kubernetes_secret" "aso_controller_settings" {
  metadata {
    name      = "aso-controller-settings"
    namespace = kubernetes_namespace.aso_namespace.metadata[0].name
  }

  data = {
    AZURE_SUBSCRIPTION_ID   = data.azurerm_subscription.current.subscription_id
    AZURE_TENANT_ID         = data.azurerm_client_config.current.tenant_id
    AZURE_CLIENT_ID         = azuread_application.crossplane.client_id
    USE_WORKLOAD_IDENTITY_AUTH = "true"
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.aso_namespace
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
  namespace: ${local.namespaces.devops}
spec:
  project: addons-project
  source:
    repoURL: https://raw.githubusercontent.com/Azure/azure-service-operator/main/v2/charts
    chart: azure-service-operator
    targetRevision: v2.17.0
    helm:
      values: |
        useWorkloadIdentityAuth: true
        azureSubscriptionID: "${data.azurerm_subscription.current.subscription_id}"
        azureTenantID: "${data.azurerm_client_config.current.tenant_id}"
        azureClientID: "${azuread_application.crossplane.client_id}"
        crdPattern: "resources.azure.com/*;keyvault.azure.com/*;managedidentity.azure.com/*;containerservice.azure.com/*"
        serviceAccount:
          create: true
          name: azureserviceoperator-default
          annotations:
            azure.workload.identity/client-id: "${azuread_application.crossplane.client_id}"
        podLabels:
          azure.workload.identity/use: "true"
  destination:
    server: https://kubernetes.default.svc
    namespace: azureserviceoperator-system
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
    kubernetes_namespace.aso_namespace,
    kubernetes_secret.aso_controller_settings,
    azuread_application_federated_identity_credential.aso_controller,
    helm_release.argocd,
    kubectl_manifest.argocd_project_addons,
    kubectl_manifest.argocd_repo_gitops
  ]
}
