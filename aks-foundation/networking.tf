################################################################################
# Virtual Network
################################################################################

resource "azurerm_virtual_network" "aks" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.vnet_address_space

  tags = var.tags
}

################################################################################
# Subnets
################################################################################

resource "azurerm_subnet" "aks_nodes" {
  name                 = var.aks_nodes_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = var.aks_nodes_subnet_prefix
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = var.private_endpoints_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = var.private_endpoints_subnet_prefix

  # Required for private endpoint deployment in this subnet
  private_endpoint_network_policies = "Disabled"
}

# Delegated subnet for VNet-integrated (private access) Azure PostgreSQL
# Flexible Server — the SQL building block's azure-flexibleserver engine
# (ADR-0010). Must be dedicated: a subnet with a flexibleServers delegation
# cannot host anything else. The Crossplane PostgresInstance Composition
# consumes this subnet's ID (via the EnvironmentConfig) as
# spec.forProvider.delegatedSubnetId.
resource "azurerm_subnet" "postgres" {
  count = var.postgres_flexibleserver_enabled ? 1 : 0

  name                 = var.postgres_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = var.postgres_subnet_prefix

  # Declared because Azure adds it, not because we want it here.
  #
  # "The Microsoft.Storage service endpoint is automatically configured on the
  # delegated subnet when the first server is provisioned in that subnet. This
  # configuration ensures reliable routing of traffic to the Azure Storage
  # accounts used for uploading Write-Ahead Log (WAL) files. Removing this
  # endpoint may disrupt connectivity and can lead to unintended consequences
  # for core service operations."
  #   -- https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private
  #
  # Leaving it out of the config does not keep it off the subnet — it only makes
  # Terraform plan to REMOVE what the service added. That plan is not cosmetic:
  # applying it strips WAL archival routing from a live Flexible Server. Observed
  # on aks-test 2026-07-16 as a permanent `~ update in-place` that reappeared on
  # every plan once orders-db existed.
  #
  # Declaring it makes Terraform and Azure agree, and is idempotent on a fresh
  # apply: the subnet is created with the endpoint the service would add anyway.
  # Deliberately NOT `lifecycle { ignore_changes = [service_endpoints] }` — that
  # would also mask a real, unintended endpoint change here.
  service_endpoints = ["Microsoft.Storage"]

  delegation {
    name = "flexibleServers"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

################################################################################
# Role Assignment - Network Contributor on aks-nodes subnet
#
# Grants the AKS cluster identity Network Contributor on the local aks-nodes
# subnet so AKS can attach NICs for nodes/pods. This is necessary because
# `var.create_role_assignment_network_contributor` defaults to `false` (so the
# generic loop in role_assignments.tf is a no-op), but the cluster is now
# wired to the locally-managed subnet via local.aks_default_subnet_id.
#
# Skipped when the caller supplies their own subnet via `var.vnet_subnet` —
# in that case they are responsible for granting the role themselves (or
# enabling `var.create_role_assignment_network_contributor`).
################################################################################
resource "azurerm_role_assignment" "aks_nodes_subnet_network_contributor" {
  count = var.vnet_subnet == null ? 1 : 0

  scope                = azurerm_subnet.aks_nodes.id
  role_definition_name = "Network Contributor"
  principal_id = coalesce(
    try(data.azurerm_user_assigned_identity.cluster_identity[0].principal_id, null),
    try(azurerm_kubernetes_cluster.main.identity[0].principal_id, null),
    var.client_id
  )
}
