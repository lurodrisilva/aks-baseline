# ArgoCD Public Endpoint Configuration

This document describes the Terraform configuration for exposing ArgoCD through a public endpoint with an Azure Public IP address.

## Overview

The configuration creates:
1. An Azure Public IP address with a DNS label
2. A Kubernetes LoadBalancer Service that exposes ArgoCD publicly
3. Outputs for easy access to the ArgoCD endpoint

## Resources Created

### Azure Public IP (`argocd_public_ingress.tf`)

- **Resource Name**: `azurerm_public_ip.argocd`
- **Public IP Name**: `argocd-public-ip`
- **DNS Label**: `luciano-argocd`
- **FQDN**: `luciano-argocd.eastus.cloudapp.azure.com`
- **Allocation**: Static
- **SKU**: Standard
- **Resource Group**: AKS node resource group (auto-generated)

### Kubernetes Service

- **Service Name**: `argocd-server-public`
- **Namespace**: `devops-system`
- **Type**: LoadBalancer
- **Ports**: 
  - HTTP: 80 → 8080 (ArgoCD server)
  - HTTPS: 443 → 8080 (ArgoCD server)
- **Selector**: `app.kubernetes.io/name: argocd-server`

## Accessing ArgoCD

After applying the Terraform configuration:

1. **Get the FQDN**:
   ```bash
   terraform output argocd_public_fqdn
   ```

2. **Access ArgoCD**:
   - URL: `http://luciano-argocd.eastus.cloudapp.azure.com`
   - Or use the output: `terraform output argocd_url`

3. **Get the admin password**:
   ```bash
   kubectl -n devops-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   ```

4. **Login**:
   - Username: `admin`
   - Password: (from step 3)

## Outputs

The following outputs are available after applying the configuration:

- `argocd_public_ip`: The static public IP address
- `argocd_public_fqdn`: The fully qualified domain name
- `argocd_url`: The complete HTTP URL to access ArgoCD

## Important Notes

1. **Security Considerations**:
   - ArgoCD is configured with `server.insecure: true` in the Helm values
   - The service exposes HTTP on port 80 and port 443 (both forwarding to 8080)
   - For production use, consider:
     - Implementing TLS/SSL certificates
     - Adding network security groups
     - Restricting access via Azure Firewall or NSG rules
     - Using Azure Application Gateway with WAF

2. **DNS Propagation**:
   - DNS changes may take a few minutes to propagate
   - The FQDN format is: `{domain_name_label}.{location}.cloudapp.azure.com`

3. **Resource Dependencies**:
   - The Public IP is created in the AKS node resource group
   - The service depends on both the ArgoCD Helm release and the Public IP
   - The Public IP must be static and Standard SKU to work with Standard Load Balancer

## Troubleshooting

### Service not getting external IP

```bash
kubectl -n devops-system get svc argocd-server-public
kubectl -n devops-system describe svc argocd-server-public
```

Check events for any issues with the LoadBalancer provisioning.

### DNS not resolving

Verify the Public IP has the correct DNS label:
```bash
az network public-ip show --resource-group <node-resource-group> --name argocd-public-ip --query dnsSettings
```

### ArgoCD not accessible

1. Check if ArgoCD pods are running:
   ```bash
   kubectl -n devops-system get pods -l app.kubernetes.io/name=argocd-server
   ```

2. Verify the service endpoints:
   ```bash
   kubectl -n devops-system get endpoints argocd-server-public
   ```

## Cleanup

To remove the public endpoint:

```bash
terraform destroy -target=kubectl_manifest.argocd_public_service
terraform destroy -target=azurerm_public_ip.argocd
```

Or simply run `terraform destroy` to remove all resources.
