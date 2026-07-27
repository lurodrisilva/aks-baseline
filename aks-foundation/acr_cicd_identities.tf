################################################################################
# ACR access identities — ADR-0021 §3 gates 1 & 2 (secretless, federated)
#
# ADR-0014 provisioned the platform ACR (acr.tf) and gave the AKS kubelet
# AcrPull. It did NOT name the two identities that let the *supply chain* use
# the registry, so ADR-0021 published Phase D to GHCR and deferred ACR behind
# three named gates. This file lands the two IDENTITY gates so the registry is
# usable by both actors. It deliberately does NOT:
#
#   * re-point CI or ArgoCD off GHCR — that is a later, separate migration; the
#     umbrella is still built and served from GHCR (net-hexagonal release.yml is
#     untouched), so nothing here changes what deploys today; and
#   * add the private endpoint (gate 3) — ACR stays Standard + public with
#     managed-identity auth (acr.tf). privatelink.azurecr.io remains ADR-0014's
#     recorded hardening fast-follow.
#
#   Gate 1  GitHub Actions -> AcrPush, via a UAMI + one GitHub OIDC federated
#           credential per permitted subject. No repo secret, no service
#           principal. Two subjects today: net-hexagonal (which still publishes
#           to GHCR — the credential only makes ACR pushable) and
#           plat-eng-developer-portal, which DOES push here (slice P4) and is
#           the first real consumer of this gate.
#   Gate 2  ArgoCD repo-server -> AcrPull, via a UAMI + a federated credential
#           bound to the argocd-repo-server ServiceAccount (AKS OIDC issuer),
#           consumed with useAzureWorkloadIdentity on the repo Secret
#           (aks_addons_argocd.tf). Dormant until an ArgoCD Application sources a
#           chart from ACR (Phase E).
#
# Both are gated on var.acr_enabled AND their own enable flags. Secretless
# throughout: the control plane never holds a credential (ADR-0020 §3). The
# UAMIs, federated credentials and role assignments cost nothing; only the
# repo-server workload-identity wiring in aks_addons_argocd.tf rolls a pod.
################################################################################

locals {
  acr_cicd_push_active   = var.acr_enabled && var.acr_cicd_push_enabled
  acr_argocd_pull_active = var.acr_enabled && var.acr_argocd_pull_enabled
}

################################################################################
# Gate 1 — CI push identity: GitHub Actions (net-hexagonal) -> AcrPush
################################################################################

variable "acr_cicd_push_enabled" {
  type        = bool
  default     = true
  description = "Provision a UAMI + GitHub OIDC federated credential + AcrPush so the application CI (net-hexagonal release.yml) can push image + umbrella to the platform ACR with no stored secret (ADR-0021 gate 1). release.yml still publishes to GHCR until it is re-pointed; this only makes ACR pushable. Requires acr_enabled."
}

variable "acr_cicd_github_subjects" {
  type = set(string)
  default = [
    # IMMUTABLE-FORM subjects — these are the ones that actually work. The
    # numeric ids are GitHub's owner id and repository id; `lurodrisilva` is
    # 168383842, `plat-eng-developer-portal` is 1301756039 and `net-hexagonal`
    # is 1208160267. See the note below before editing either list.
    "repo:lurodrisilva@168383842/plat-eng-developer-portal@1301756039:ref:refs/heads/main",
    "repo:lurodrisilva@168383842/net-hexagonal@1208160267:ref:refs/heads/master",

    # Documented-form subjects, kept as a fallback in case the issuer emits the
    # classic claim again. Neither of these matches what GitHub presents today.
    "repo:lurodrisilva/net-hexagonal:ref:refs/heads/master",
    "repo:lurodrisilva/plat-eng-developer-portal:ref:refs/heads/main",
  ]

  description = <<-EOT
    GitHub OIDC federated-credential subjects permitted to push to the platform
    ACR — one federated credential per subject, exact match (classic FICs do not
    support wildcards). A tagged release mints a `:ref:refs/tags/<tag>` subject;
    add that, or a GitHub `environment:` subject, when a release path needs one.

    THE SUBJECT GITHUB PRESENTS IS NOT THE ONE THE DOCUMENTATION DESCRIBES.
    Every guide, including Microsoft's, gives the form
    `repo:<owner>/<repo>:ref:refs/heads/<branch>`. What the issuer actually
    sends is the IMMUTABLE form, with GitHub's numeric owner and repository ids
    embedded:

      repo:lurodrisilva@168383842/plat-eng-developer-portal@1301756039:ref:refs/heads/main

    The ids are the point of that form — it survives a rename, where the name
    form does not. Read them from `gh api repos/<owner>/<repo>` (`.owner.id`,
    `.id`), or simply from the failing run: azure/login prints `subject claim -
    ...` immediately before the error, which is the fastest way to get the exact
    string.

    There is no way to opt back into the classic form. The repository already
    reports `use_immutable_subject: false` from
    `/repos/{owner}/{repo}/actions/oidc/customization/sub` while its
    `sub_claim_prefix` is the immutable one, so the flag does not describe what
    is emitted.

    This was latent from the day gate 1 landed and could not have been noticed
    until something used it: net-hexagonal publishes to GHCR, so its credential
    was never exercised. The portal (slice P4) is the first real consumer and
    the first to fail — with AADSTS700213 "No matching federated identity record
    found for presented assertion subject", which names the presented subject
    and nothing about why it differs.

    net-hexagonal's immutable subject is included here as the same one-line fix,
    but it is UNEXERCISED — nothing pushes to ACR from that repository yet.

    The branch also matters and is equally silent: the portal is `main`, the
    application is `master`. A wrong branch produces the same AADSTS700213.

    THE BLAST RADIUS IS THE REGISTRY, NOT THE REPOSITORY. AcrPush is assigned at
    registry scope below, so every subject listed here can push over every
    repository in the registry — a portal workflow can overwrite the application
    image and vice versa. A separate identity per repo would NOT change that; it
    would only make the pusher distinguishable in registry audit logs. Adding a
    subject here is therefore a trust decision about the whole registry, and the
    reason the list is short and explicit rather than a wildcard.
  EOT
}

resource "azurerm_user_assigned_identity" "acr_cicd_push" {
  count               = local.acr_cicd_push_active ? 1 : 0
  name                = "uami-acr-cicd-push-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(var.tags, {
    component  = "platform-registry"
    managed-by = "terraform"
    purpose    = "ci-acr-push"
  })
}

# One federated credential per GitHub subject. The subject string is the whole
# key, so its short hash keeps the FIC name stable and unique per identity.
resource "azurerm_federated_identity_credential" "acr_cicd_push" {
  for_each = local.acr_cicd_push_active ? var.acr_cicd_github_subjects : toset([])

  name                = "fic-acr-push-${substr(sha1(each.value), 0, 8)}"
  resource_group_name = var.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  parent_id           = azurerm_user_assigned_identity.acr_cicd_push[0].id
  subject             = each.value
}

resource "azurerm_role_assignment" "acr_cicd_push" {
  count = local.acr_cicd_push_active ? 1 : 0

  scope                            = azurerm_container_registry.platform[0].id
  role_definition_name             = "AcrPush"
  principal_id                     = azurerm_user_assigned_identity.acr_cicd_push[0].principal_id
  skip_service_principal_aad_check = true
}

################################################################################
# Gate 2 — ArgoCD pull identity: argocd-repo-server -> AcrPull
################################################################################

variable "acr_argocd_pull_enabled" {
  type        = bool
  default     = true
  description = "Provision a UAMI + a federated credential bound to the argocd-repo-server ServiceAccount + AcrPull so ArgoCD's repo-server can pull OCI Helm charts (the ADR-0008 umbrella) from the platform ACR with useAzureWorkloadIdentity — no stored registry credential (ADR-0021 gate 2). Wires the repo-server for workload identity in aks_addons_argocd.tf. Dormant until an ArgoCD Application sources a chart from ACR (Phase E); the umbrella is served from GHCR until then. Requires acr_enabled."
}

variable "argocd_repo_server_sa_name" {
  type        = string
  default     = "argocd-repo-server"
  description = "ServiceAccount name of the ArgoCD repo-server (argo-helm default). Used as the federated-credential subject for the ACR pull identity and annotated for workload identity in aks_addons_argocd.tf."
}

resource "azurerm_user_assigned_identity" "acr_argocd_pull" {
  count               = local.acr_argocd_pull_active ? 1 : 0
  name                = "uami-acr-argocd-pull-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(var.tags, {
    component  = "platform-registry"
    managed-by = "terraform"
    purpose    = "argocd-acr-pull"
  })
}

resource "azurerm_federated_identity_credential" "acr_argocd_pull" {
  count = local.acr_argocd_pull_active ? 1 : 0

  name                = "fic-argocd-repo-server-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.acr_argocd_pull[0].id
  subject             = "system:serviceaccount:${local.namespaces.devops}:${var.argocd_repo_server_sa_name}"
}

resource "azurerm_role_assignment" "acr_argocd_pull" {
  count = local.acr_argocd_pull_active ? 1 : 0

  scope                            = azurerm_container_registry.platform[0].id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.acr_argocd_pull[0].principal_id
  skip_service_principal_aad_check = true
}

################################################################################
# Outputs — wiring hooks for the eventual re-point (kept null when disabled)
################################################################################

output "acr_cicd_push_client_id" {
  description = "Client ID of the CI push UAMI (ADR-0021 gate 1). Feed to a workflow's azure/login (client-id) — plat-eng-developer-portal's release.yml already does, and net-hexagonal release.yml will when it is re-pointed off GHCR. Null when acr_cicd_push_enabled = false or acr_enabled = false."
  value       = try(azurerm_user_assigned_identity.acr_cicd_push[0].client_id, null)
}

output "acr_argocd_pull_client_id" {
  description = "Client ID of the ArgoCD repo-server pull UAMI (ADR-0021 gate 2). Annotated onto the repo-server ServiceAccount for useAzureWorkloadIdentity (aks_addons_argocd.tf). Null when acr_argocd_pull_enabled = false or acr_enabled = false."
  value       = try(azurerm_user_assigned_identity.acr_argocd_pull[0].client_id, null)
}
