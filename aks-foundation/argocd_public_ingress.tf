################################################################################
# ArgoCD Public IP Address
################################################################################

resource "azurerm_public_ip" "argocd" {
  name                = "argocd-public-ip"
  resource_group_name = azurerm_kubernetes_cluster.main.node_resource_group
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "luciano-argocd"

  tags = merge(
    var.tags,
    {
      "component" = "argocd"
      "managed-by" = "terraform"
    }
  )

  depends_on = [
    azurerm_kubernetes_cluster.main
  ]
}

################################################################################
# ArgoCD LoadBalancer Service
################################################################################

resource "kubectl_manifest" "argocd_public_service" {
  yaml_body = <<-EOF
    apiVersion: v1
    kind: Service
    metadata:
      name: argocd-server-public
      namespace: ${local.namespaces.devops}
      annotations:
        service.beta.kubernetes.io/azure-load-balancer-resource-group: ${azurerm_kubernetes_cluster.main.node_resource_group}
        service.beta.kubernetes.io/azure-pip-name: ${azurerm_public_ip.argocd.name}
    spec:
      type: LoadBalancer
      loadBalancerIP: ${azurerm_public_ip.argocd.ip_address}
      ports:
        - name: http
          port: 80
          targetPort: 8080
          protocol: TCP
        - name: https
          port: 443
          targetPort: 8080
          protocol: TCP
      selector:
        app.kubernetes.io/name: argocd-server
  EOF

  depends_on = [
    helm_release.argocd,
    azurerm_public_ip.argocd
  ]
}
