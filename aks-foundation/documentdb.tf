################################################################################
# Azure DocumentDB (Microsoft.DocumentDB/mongoClusters) — platform store (ADR-0017)
#
# MongoDB wire-compatible managed service backing the platform orchestrator's
# Mongo persistence adapter (binds unchanged via a mongodb+srv connection
# string). Private-only by construction:
#   - public_network_access = "Disabled"
#   - an azurerm_private_endpoint (subresource "MongoCluster") in the
#     private-endpoints subnet, resolved via the
#     privatelink.mongocluster.cosmos.azure.com zone (a DNS zone group writes
#     the A records; the zone itself is created from private_dns_zone_names).
# The mongodb+srv connection string is seeded into the ESO demo Key Vault so
# External Secrets syncs it into the cluster — no secret in git.
#
# v1 posture (per the grill + ADR-0010 lineage): Free tier, HA off, admin auth
# (admin-as-app-user, dev/non-production; least-privilege is a fast-follow).
# compute_tier is a variable so prod can bump it. NSG note: the DocumentDB
# engine listens on port 10260 — the private-endpoints subnet has no NSG today,
# so nothing to open; add an allow rule if an NSG is introduced later.
################################################################################

variable "documentdb_enabled" {
  type        = bool
  default     = true
  description = "Provision Azure DocumentDB (mongoCluster) as the platform orchestrator's private persistence store (ADR-0017). Requires the privatelink.mongocluster.cosmos.azure.com zone in private_dns_zone_names (default includes it)."
}

variable "documentdb_name" {
  type        = string
  default     = ""
  description = "Globally-unique DocumentDB (mongoCluster) name (3-40 chars, lowercase alphanumeric + hyphens). Empty → derived as docdb-<workspace>-<hash>."
}

variable "documentdb_compute_tier" {
  type        = string
  default     = "Free"
  description = "DocumentDB compute tier: Free | M10 | M20 | M25 | M30 | M40 | M50 | M60 | M80 | M200. v1 default Free (32GB, single-node, one free cluster per subscription/region). Bump for prod."
}

variable "documentdb_storage_size_gb" {
  type        = number
  default     = 32
  description = "DocumentDB storage size in GB. Free tier is fixed at 32."
}

variable "documentdb_high_availability_mode" {
  type        = string
  default     = "Disabled"
  description = "DocumentDB HA mode: Disabled | SameZone | ZoneRedundantPreferred. Free tier supports Disabled only."
}

variable "documentdb_version" {
  type        = string
  default     = "8.0"
  description = "DocumentDB (MongoDB) server version."
}

variable "documentdb_admin_username" {
  type        = string
  default     = "docdbadmin"
  description = "DocumentDB administrator username. Dev posture (admin-as-app-user, per ADR-0010 lineage); least-privilege roles are a fast-follow."
}

locals {
  documentdb_name = var.documentdb_enabled ? substr(
    coalesce(
      var.documentdb_name,
      "docdb-${terraform.workspace}-${substr(sha1("${data.azurerm_client_config.current.tenant_id}-${var.resource_group_name}-docdb"), 0, 6)}"
    ),
    0, 40
  ) : ""

  documentdb_zone_name = "privatelink.mongocluster.cosmos.azure.com"

  documentdb_host = var.documentdb_enabled ? "${local.documentdb_name}.mongocluster.cosmos.azure.com" : null

  # mongodb+srv connection string with real admin creds injected. The host
  # resolves to the private-endpoint IP via the privatelink zone.
  # retrywrites=false is required by the vCore engine.
  documentdb_connection_string = var.documentdb_enabled ? format(
    "mongodb+srv://%s:%s@%s/?tls=true&authMechanism=SCRAM-SHA-256&retrywrites=false&maxIdleTimeMS=120000",
    var.documentdb_admin_username,
    random_password.documentdb_admin[0].result,
    local.documentdb_host
  ) : null

  # The connection string can only be seeded when the ESO demo Key Vault exists.
  documentdb_seed_secret = var.documentdb_enabled && local.external_secrets_seed_demo_resources
}

# Admin password. special=false keeps it URL-safe inside the mongodb+srv string.
resource "random_password" "documentdb_admin" {
  count       = var.documentdb_enabled ? 1 : 0
  length      = 24
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "azurerm_mongo_cluster" "platform" {
  count = var.documentdb_enabled ? 1 : 0

  name                   = local.documentdb_name
  resource_group_name    = var.resource_group_name
  location               = var.location
  administrator_username = var.documentdb_admin_username
  administrator_password = random_password.documentdb_admin[0].result
  compute_tier           = var.documentdb_compute_tier
  high_availability_mode = var.documentdb_high_availability_mode
  shard_count            = 1
  storage_size_in_gb     = var.documentdb_storage_size_gb
  version                = var.documentdb_version

  public_network_access = "Disabled"

  tags = merge(var.tags, {
    component  = "platform-store"
    managed-by = "terraform"
  })
}

################################################################################
# Private endpoint (subresource MongoCluster) + private DNS zone group
################################################################################

resource "azurerm_private_endpoint" "documentdb" {
  count = var.documentdb_enabled ? 1 : 0

  name                = "pe-${local.documentdb_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-${local.documentdb_name}"
    private_connection_resource_id = azurerm_mongo_cluster.platform[0].id
    subresource_names              = ["MongoCluster"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "documentdb-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones[local.documentdb_zone_name].id]
  }

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.links]
}

################################################################################
# Connection string → ESO demo Key Vault (External Secrets syncs it in-cluster)
################################################################################

resource "azurerm_key_vault_secret" "documentdb_connection" {
  count        = local.documentdb_seed_secret ? 1 : 0
  name         = "orchestrator-documentdb-connection-string"
  value        = local.documentdb_connection_string
  key_vault_id = azurerm_key_vault.eso_demo[0].id

  depends_on = [time_sleep.wait_for_kv_rbac]
}
