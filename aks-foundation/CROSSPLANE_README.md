# Crossplane Configuration for AKS

This Terraform configuration deploys Crossplane on Azure Kubernetes Service (AKS) with Azure Workload Identity authentication.

## Architecture Overview

The implementation consists of:

1. **Azure Infrastructure** (`crossplane_infrastructure.tf`):
   - Resource Group: `aks-control-plane` with specific tags
   - User-Assigned Managed Identity: `crossplane-identity`
   - Federated Identity Credential with wildcard pattern for all provider service accounts
   - Subscription-level Contributor role assignment

2. **Kubernetes Resources** (`crossplane_argocd.tf`):
   - ArgoCD Application for Crossplane installation
   - Provider installations (provider-family-azure, provider-azure-cache)
   - DeploymentRuntimeConfig for workload identity
   - ProviderConfig for Azure authentication
   - Kubernetes Secret with credentials backup

## Resources Created

### Azure Resources

- **Resource Group**: `aks-control-plane`
  - Tags: Owner, xp-cost-allocation, AMBIENTE, BASELINE, managed-by
  
- **Managed Identity**: `crossplane-identity`
  - Permissions: Contributor role at subscription level
  
- **Federated Identity Credential**: `crossplane-all-providers`
  - Subject: `system:serviceaccount:resources-system:*`
  - Audience: `api://AzureADTokenExchange`

### Kubernetes Resources

All resources are deployed in the `resources-system` namespace:

- **ArgoCD Application**: `crossplane`
  - Helm chart from Crossplane stable repository
  - Version controlled via `var.crossplane_version`
  
- **Providers**:
  - `upbound-provider-family-azure` (version from `var.crossplane_provider_family_azure_version`)
  - `provider-redis-azure` (version from `var.crossplane_provider_azure_cache_version`)
  
- **DeploymentRuntimeConfig**: `crossplane-runtime-config`
  - Configures service accounts with workload identity annotations
  - Adds pod labels for workload identity webhook
  
- **ProviderConfig**: `default`
  - Uses OIDCTokenFile authentication
  - Configured with managed identity client ID
  
- **Secret**: `azure-crossplane-credentials`
  - Stores CLIENT_ID, SUBSCRIPTION_ID, TENANT_ID

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `crossplane_version` | Version of Crossplane to install | `1.18.4` |
| `crossplane_provider_family_azure_version` | Version of provider-family-azure | `v2.3.0` |
| `crossplane_provider_azure_cache_version` | Version of provider-azure-cache | `v2.3.0` |

## Outputs

| Output | Description |
|--------|-------------|
| `crossplane_identity_client_id` | The Client ID of the Crossplane managed identity |
| `crossplane_identity_principal_id` | The Principal ID of the Crossplane managed identity |
| `crossplane_subscription_id` | The Azure Subscription ID used by Crossplane |
| `crossplane_tenant_id` | The Azure Tenant ID used by Crossplane |
| `crossplane_resource_group_name` | The name of the resource group containing Crossplane infrastructure |

## Prerequisites

1. AKS cluster with:
   - OIDC Issuer enabled (`oidc_issuer_enabled = true`)
   - Workload Identity enabled (`workload_identity_enabled = true`)
   
2. ArgoCD installed and configured

3. Environment variables:
   - `ARM_SUBSCRIPTION_ID`: Azure subscription ID

## Deployment Order

The Terraform configuration ensures proper dependency ordering:

1. Azure infrastructure (Resource Group, Managed Identity, Federated Credential, Role Assignment)
2. AKS cluster and namespaces
3. ArgoCD installation and configuration
4. Crossplane ArgoCD Application
5. Provider installations
6. DeploymentRuntimeConfig
7. ProviderConfig

## Workload Identity Configuration

The implementation uses Azure Workload Identity with a wildcard federated credential pattern:

- **Subject Pattern**: `system:serviceaccount:resources-system:*`
- **Benefit**: Single credential works for all Crossplane provider service accounts
- **Automatic Injection**: Azure Workload Identity webhook automatically injects required environment variables and volume mounts

### How It Works

1. Provider pods are created with label `azure.workload.identity/use: "true"`
2. Service accounts are annotated with `azure.workload.identity/client-id`
3. Azure Workload Identity webhook injects:
   - Environment variables: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_AUTHORITY_HOST`
   - Volume mounts for OIDC token
4. Providers authenticate using the OIDC token file

## Verifying the Installation

### Check Crossplane Installation

```bash
kubectl get pods -n resources-system
kubectl get providers -n resources-system
```

### Verify Workload Identity Configuration

```bash
# Check provider pod has workload identity label
kubectl get pod -n resources-system -l pkg.crossplane.io/provider=provider-azure-cache \
  -o jsonpath='{.items[0].metadata.labels.azure\.workload\.identity/use}'

# Check environment variables are injected
kubectl get pod -n resources-system -l pkg.crossplane.io/provider=provider-azure-cache \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}' | grep AZURE
```

### Test with a Managed Resource

```bash
kubectl apply -f - <<EOF
apiVersion: cache.azure.m.upbound.io/v1beta1
kind: ManagedRedis
metadata:
  name: example-redis
  namespace: resources-system
spec:
  forProvider:
    location: East US
    resourceGroupName: aks-control-plane
    skuName: Balanced_B3
  providerConfigRef:
    kind: ProviderConfig
    name: default
EOF

# Check status
kubectl get managedredis example-redis -n resources-system
```

## Troubleshooting

### Provider Not Healthy

```bash
kubectl describe provider upbound-provider-family-azure -n resources-system
kubectl logs -n resources-system -l pkg.crossplane.io/provider=provider-azure
```

### Authentication Issues

1. Verify managed identity exists and has proper permissions:
   ```bash
   az identity show --name crossplane-identity --resource-group aks-control-plane
   az role assignment list --assignee <principal-id>
   ```

2. Check federated credential:
   ```bash
   az identity federated-credential list \
     --identity-name crossplane-identity \
     --resource-group aks-control-plane
   ```

3. Verify OIDC issuer URL matches:
   ```bash
   az aks show --name <cluster-name> --resource-group <rg-name> \
     --query "oidcIssuerProfile.issuerUrl"
   ```

### ProviderConfig Not Working

```bash
kubectl get providerconfig default -n resources-system -o yaml
kubectl describe providerconfig default -n resources-system
```

## Cleanup

To remove Crossplane and all related resources:

```bash
# Delete managed resources first
kubectl delete managedredis --all -n resources-system

# Terraform will handle the rest
terraform destroy
```

## References

- [Crossplane Documentation](https://docs.crossplane.io/)
- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/)
- [Upbound Azure Provider](https://marketplace.upbound.io/providers/upbound/provider-family-azure/)
- [Crossplane Azure Workload Identity Guide](../CROSSPLANE_AZURE_WORKLOAD_IDENTITY.md)
