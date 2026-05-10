################################################################################
# External Secrets Operator (ESO) — Azure Key Vault via Workload Identity
#
# This file provisions ONLY the Azure-side glue that the ESO Helm chart in the
# 00-baseline-addons GitOps repo needs:
#
#   1. User-Assigned Managed Identity (UAMI) for the ESO ServiceAccount
#   2. Federated Identity Credential bound to AKS OIDC issuer
#      (subject: system:serviceaccount:<ns>:<sa-name>)
#   3. A demo Key Vault (RBAC mode) + a demo secret for smoke-testing
#   4. RBAC: UAMI -> "Key Vault Secrets User"
#           current TF principal -> "Key Vault Secrets Officer" (seed demo secret)
#
# The ESO operator chart, ServiceAccount annotations, ClusterSecretStore and
# demo ExternalSecret live in the sibling repo 00-baseline-addons under
# addon_charts/external-secrets/. Wire them by setting the helm values:
#
#     external_secrets.azure.tenant_id                  = <output: external_secrets_tenant_id>
#     external_secrets.azure.workload_identity_client_id = <output: external_secrets_uami_client_id>
#     external_secrets.azure.keyvault_uri               = <output: external_secrets_keyvault_uri>
#
# AKS OIDC issuer + workload identity must be enabled (see var.oidc_issuer_enabled
# / var.workload_identity_enabled — both default true in this module).
################################################################################

locals {
  external_secrets_kv_name = substr(
    coalesce(
      var.external_secrets_keyvault_name,
      "eso-${terraform.workspace}-${substr(sha1("${data.azurerm_client_config.current.tenant_id}-${var.resource_group_name}"), 0, 6)}"
    ),
    0,
    24
  )

  external_secrets_federated_subject = "system:serviceaccount:${var.external_secrets_namespace}:${var.external_secrets_sa_name}"

  external_secrets_seed_demo_resources = var.external_secrets_enabled && var.external_secrets_seed_demo_secret
}

################################################################################
# User-Assigned Managed Identity for ESO
################################################################################

resource "azurerm_user_assigned_identity" "eso" {
  count               = var.external_secrets_enabled ? 1 : 0
  name                = "uami-external-secrets-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_federated_identity_credential" "eso" {
  count               = var.external_secrets_enabled ? 1 : 0
  name                = "fic-external-secrets-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.eso[0].id
  subject             = local.external_secrets_federated_subject
}

################################################################################
# Demo Key Vault (RBAC mode) + sample secret
################################################################################

resource "azurerm_key_vault" "eso_demo" {
  count                         = local.external_secrets_seed_demo_resources ? 1 : 0
  name                          = local.external_secrets_kv_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = true

  tags = {
    component  = "external-secrets"
    managed-by = "terraform"
    workspace  = terraform.workspace
    purpose    = "eso-demo"
  }
}

# UAMI can read secrets from the demo Key Vault.
resource "azurerm_role_assignment" "eso_kv_secrets_user" {
  count                = local.external_secrets_seed_demo_resources ? 1 : 0
  scope                = azurerm_key_vault.eso_demo[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso[0].principal_id
}

# Current Terraform principal can write secrets (so we can seed the demo).
# Persistent — re-applies will keep the role bound. For prd, set
# var.external_secrets_seed_demo_secret = false and have ops seed real
# secrets out-of-band with their own least-privilege identity.
resource "azurerm_role_assignment" "eso_kv_secrets_officer_self" {
  count                = local.external_secrets_seed_demo_resources ? 1 : 0
  scope                = azurerm_key_vault.eso_demo[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC propagation is eventually consistent — wait before writing.
resource "time_sleep" "wait_for_kv_rbac" {
  count           = local.external_secrets_seed_demo_resources ? 1 : 0
  depends_on      = [azurerm_role_assignment.eso_kv_secrets_officer_self]
  create_duration = "60s"
}

resource "azurerm_key_vault_secret" "eso_demo" {
  count        = local.external_secrets_seed_demo_resources ? 1 : 0
  name         = "eso-demo-secret"
  value        = "hello-from-keyvault"
  key_vault_id = azurerm_key_vault.eso_demo[0].id

  depends_on = [time_sleep.wait_for_kv_rbac]
}
