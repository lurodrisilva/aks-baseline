################################################################################
# Azure Container Registry — platform image + umbrella registry (ADR-0014)
#
# The single registry for the platform: CI (release.yml) pushes the application
# image AND the ADR-0008 umbrella chart here. The AKS kubelet managed identity
# pulls via an AcrPull role assignment — secretless, no imagePullSecret in the
# cluster. v1 uses the public registry endpoint with managed-identity auth; an
# ACR private endpoint (Premium SKU + privatelink.azurecr.io) is a recorded
# hardening fast-follow (ADR-0014) and is intentionally out of scope here.
#
# This is distinct from the pre-existing BYO path in role_assignments.tf
# (var.attached_acr_id_map), which grants AcrPull over caller-supplied ACR ids.
################################################################################

variable "acr_enabled" {
  type        = bool
  default     = true
  description = "Provision an Azure Container Registry as the platform image + umbrella registry (ADR-0014); grants AcrPull to the AKS kubelet identity. Set false to rely solely on var.attached_acr_id_map (BYO)."
}

variable "acr_name" {
  type        = string
  default     = ""
  description = "Globally-unique ACR name (alphanumeric only, 5-50 chars, lowercase). Empty → derived as acr<workspace><hash>."
}

variable "acr_sku" {
  type        = string
  default     = "Standard"
  description = "ACR SKU: Basic | Standard | Premium. Premium is required for an ACR private endpoint (hardening fast-follow); v1 default Standard with the public endpoint + managed-identity pull."

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be one of Basic, Standard, Premium."
  }
}

locals {
  # ACR names are alphanumeric-only and globally unique. Derive a stable name
  # from workspace + a hash of tenant/RG when the caller does not pin one.
  acr_name = var.acr_enabled ? substr(
    coalesce(
      var.acr_name,
      "acr${terraform.workspace}${substr(sha1("${data.azurerm_client_config.current.tenant_id}-${var.resource_group_name}-acr"), 0, 8)}"
    ),
    0, 50
  ) : ""
}

resource "azurerm_container_registry" "platform" {
  count = var.acr_enabled ? 1 : 0

  name                          = local.acr_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = var.acr_sku
  admin_enabled                 = false
  public_network_access_enabled = true

  tags = merge(var.tags, {
    component  = "platform-registry"
    managed-by = "terraform"
  })
}

# Secretless pull: the AKS kubelet identity gets AcrPull on the platform registry.
resource "azurerm_role_assignment" "acr_platform_pull" {
  count = var.acr_enabled ? 1 : 0

  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  scope                            = azurerm_container_registry.platform[0].id
  role_definition_name             = "AcrPull"
  skip_service_principal_aad_check = true
}
