################################################################################
# HashiCorp Vault - ArgoCD Integration
################################################################################
resource "helm_release" "vault" {
  name       = "vault"
  namespace  = local.namespaces.devops
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.31.0"

  values = [
    <<-EOT
# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

# Available parameters and their default values for the Vault chart.

global:
  # enabled is the master enabled switch. Setting this to true or false
  # will enable or disable all the components within this chart by default.
  enabled: true

server:
  # If true, or "-" with global.enabled true, Vault server will be installed.
  # See vault.mode in _helpers.tpl for implementation details.
  enabled: "-"
  resources:
    requests:
      memory: 256Mi
      cpu: 250m
    limits:
      memory: 512Mi
      cpu: 500m
  ha:
    enabled: true
    replicas: 2
    raft:
      enabled: true

ui:
  enabled: true

injector:
  enabled: true
  replicas: 2

    EOT
  ]

  depends_on = [
    azurerm_kubernetes_cluster.main
  ]
}
