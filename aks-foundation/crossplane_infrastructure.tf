################################################################################
# Data Sources
################################################################################

data "azurerm_subscription" "current" {}

data "azurerm_client_config" "current" {}

################################################################################
# Control Plane Resource Group
################################################################################

resource "azurerm_resource_group" "aks_control_plane" {
  name     = "aks-control-plane-rg"
  location = var.location

  tags = {
    "Owner"                 = "Luciano Silva"
    "xp-cost-allocation"    = "XPCA00001759"
    "AMBIENTE"              = "DEVLABTEST"
    "BASELINE"              = "2026"
    "managed-by"            = "terraform"
  }
}

################################################################################
# Crossplane Service Principal (App Registration)
################################################################################

resource "azuread_application" "crossplane" {
  # Generic name (SP will be used by Crossplane and ASO)
  display_name = "azure-operators-sp"
}

resource "azuread_service_principal" "crossplane" {
client_id = azuread_application.crossplane.client_id
}

# Client secret for the service principal
resource "azuread_application_password" "crossplane" {
  # application_id must be the application resource ID ("/applications/{objectId}"), use azuread_application.id
  application_id    = azuread_application.crossplane.id
  display_name      = "crossplane-sp-secret"
}

################################################################################
# Role Assignment - Subscription Contributor (Service Principal)
################################################################################

resource "azurerm_role_assignment" "crossplane_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.crossplane.object_id

  depends_on = [
    azuread_service_principal.crossplane,
    azurerm_resource_group.aks_control_plane
  ]
}

################################################################################
# ASO Workload Identity - Federated Credential on App Registration
################################################################################

resource "azuread_application_federated_identity_credential" "aso_controller" {
  display_name      = "aso-controller"
  application_id    = azuread_application.crossplane.id
  audiences         = ["api://AzureADTokenExchange"]
  issuer            = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject           = "system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default"

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azuread_application.crossplane
  ]
}
