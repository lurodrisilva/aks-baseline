################################################################################
# ACR access identity — ADR-0021 §3 gate 3: orchestrator -> AcrPush (Phase G)
#
# ADR-0021 named three gates. acr_cicd_identities.tf landed gates 1 (CI push) and
# 2 (ArgoCD pull). This file lands gate 3: the platform orchestrator, running IN
# the cluster, pushes each per-deployment composed umbrella chart to the platform
# ACR (ADR-0016 in-process executor: resolve → compose → PUBLISH → ArgoCD). It
# authenticates with the same secretless pattern as gate 2 — a UAMI + a federated
# credential bound to the orchestrator's ServiceAccount via the AKS OIDC issuer,
# consumed by azidentity workload identity in the orchestrator process — so the
# control plane never holds a registry credential (ADR-0020 §3).
#
# gate 3 is AcrPush (push includes pull); ArgoCD then pulls the pushed chart with
# gate 2's AcrPull identity. Gated on var.acr_enabled AND its own flag. The UAMI,
# federated credential and role assignment cost nothing; the orchestrator's
# workload-identity wiring rolls its own pod, not anything here.
################################################################################

locals {
  acr_orchestrator_push_active = var.acr_enabled && var.acr_orchestrator_push_enabled
}

variable "acr_orchestrator_push_enabled" {
  type        = bool
  default     = true
  description = "Provision a UAMI + a federated credential bound to the platform orchestrator's ServiceAccount + AcrPush so the in-cluster orchestrator can push composed umbrella charts to the platform ACR with azidentity workload identity — no stored registry credential (ADR-0021 gate 3, Phase G). Requires acr_enabled."
}

variable "orchestrator_namespace" {
  type        = string
  default     = "platform-orchestrator"
  description = "Namespace the platform orchestrator runs in. Used as the federated-credential subject for the ACR push identity (gate 3) and annotated for workload identity on the orchestrator ServiceAccount (orchestrator deploy manifests)."
}

variable "orchestrator_sa_name" {
  type        = string
  default     = "platform-orchestrator"
  description = "ServiceAccount name of the platform orchestrator. Federated-credential subject for the ACR push identity (gate 3)."
}

resource "azurerm_user_assigned_identity" "acr_orchestrator_push" {
  count               = local.acr_orchestrator_push_active ? 1 : 0
  name                = "uami-acr-orchestrator-push-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(var.tags, {
    component  = "platform-registry"
    managed-by = "terraform"
    purpose    = "orchestrator-acr-push"
  })
}

resource "azurerm_federated_identity_credential" "acr_orchestrator_push" {
  count = local.acr_orchestrator_push_active ? 1 : 0

  name                = "fic-orchestrator-acr-push-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.acr_orchestrator_push[0].id
  subject             = "system:serviceaccount:${var.orchestrator_namespace}:${var.orchestrator_sa_name}"
}

resource "azurerm_role_assignment" "acr_orchestrator_push" {
  count = local.acr_orchestrator_push_active ? 1 : 0

  scope                            = azurerm_container_registry.platform[0].id
  role_definition_name             = "AcrPush"
  principal_id                     = azurerm_user_assigned_identity.acr_orchestrator_push[0].principal_id
  skip_service_principal_aad_check = true
}

output "acr_orchestrator_push_client_id" {
  description = "Client ID of the orchestrator ACR push UAMI (ADR-0021 gate 3). Annotate onto the orchestrator ServiceAccount as azure.workload.identity/client-id. Null when acr_orchestrator_push_enabled = false or acr_enabled = false."
  value       = try(azurerm_user_assigned_identity.acr_orchestrator_push[0].client_id, null)
}
