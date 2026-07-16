################################################################################
# Private DNS Zones
#
# One zone per Azure service type. Each zone name must exactly match Azure's
# required format for the CNAME chain to resolve correctly:
#   e.g. privatelink.redis.azure.net
#        privatelink.vaultcore.azure.net
#        privatelink.blob.core.windows.net
#
#   The name is per-service and unforgiving. Azure Managed Redis
#   (Microsoft.Cache/redisEnterprise) uses privatelink.redis.azure.net; the
#   similar-looking privatelink.redis.cache.windows.net belongs to Azure Cache
#   for Redis, a different and now-retired service. A zone group pointed at the
#   wrong zone still applies cleanly and still resolves to nothing.
#
# HOW DNS RECORDS ARE CREATED:
#   DNS records for private endpoints are NOT created by auto-registration.
#   They are created by the `private_dns_zone_group` block on each
#   `azurerm_private_endpoint` resource. That is why `registration_enabled`
#   is set to `false` here.
#   Auto-registration (registration_enabled = true) is only for VM A-records
#   and Azure enforces a hard limit of 1 auto-registration zone per VNet.
#
# HOW TO ADD MORE ZONES:
#   Add the zone name to the `private_dns_zone_names` variable. No Terraform
#   resource changes are needed.
################################################################################

resource "azurerm_private_dns_zone" "zones" {
  for_each = var.private_dns_zone_names

  name                = each.value
  resource_group_name = var.resource_group_name

  tags = var.tags
}

################################################################################
# VNet Links
#
# Links each Private DNS Zone to the AKS VNet so that pods running inside
# the cluster can resolve private endpoint DNS names.
#
# registration_enabled = false:
#   Correct for all privatelink.* zones. Private endpoint DNS records
#   are registered via private_dns_zone_group on azurerm_private_endpoint,
#   not via auto-registration.
################################################################################

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each = azurerm_private_dns_zone.zones

  name                  = "${each.key}-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.aks.id
  registration_enabled  = false

  tags = var.tags
}
