# Crossplane on AKS - Quick Start Guide

## Prerequisites

- Azure CLI installed and authenticated
- kubectl installed
- Terraform >= 1.0
- Environment variable: `ARM_SUBSCRIPTION_ID`

## Deploy Everything

```bash
# Navigate to the project
cd 01-aks-tf/aks-foundation

# Set required environment variable
export ARM_SUBSCRIPTION_ID="<your-subscription-id>"

# Initialize Terraform
terraform init

# Review what will be created
terraform plan

# Deploy (this creates AKS, ArgoCD, and Crossplane)
terraform apply -auto-approve
```

## Get AKS Credentials

```bash
az aks get-credentials --name aks-test --resource-group aks-test-rg
```

## Verify Installation

```bash
# Check all pods are running
kubectl get pods -n resources-system
kubectl get pods -n devops-system

# Check Crossplane installation
kubectl get providers -n resources-system

# Should show:
# - upbound-provider-family-azure (HEALTHY: True, INSTALLED: True)
# - provider-redis-azure (HEALTHY: True, INSTALLED: True)
```

## Get Credentials

```bash
# View Crossplane credentials
terraform output crossplane_identity_client_id
terraform output crossplane_subscription_id
terraform output crossplane_tenant_id

# Or get from Kubernetes secret
kubectl get secret azure-crossplane-credentials -n resources-system -o yaml
```

## Test Crossplane

Create a test Redis instance:

```bash
kubectl apply -f - <<EOF
apiVersion: cache.azure.m.upbound.io/v1beta1
kind: ManagedRedis
metadata:
  name: test-redis
  namespace: resources-system
spec:
  forProvider:
    location: eastus
    resourceGroupName: aks-control-plane
    skuName: Balanced_B3
  providerConfigRef:
    name: default
EOF
```

Monitor provisioning:

```bash
# Watch status
kubectl get managedredis test-redis -n resources-system -w

# Check detailed status
kubectl describe managedredis test-redis -n resources-system
```

## Troubleshooting

### Check Provider Logs

```bash
kubectl logs -n resources-system -l pkg.crossplane.io/provider=provider-azure-cache
```

### Verify Workload Identity

```bash
# Check pod has workload identity enabled
kubectl get pod -n resources-system -l pkg.crossplane.io/provider=provider-azure-cache \
  -o jsonpath='{.items[0].metadata.labels.azure\.workload\.identity/use}'

# Should output: true
```

### Check Environment Variables

```bash
kubectl get pod -n resources-system -l pkg.crossplane.io/provider=provider-azure-cache \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}'

# Should include: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE
```

## Cleanup Test Resources

```bash
# Delete the test Redis instance
kubectl delete managedredis test-redis -n resources-system

# Wait for it to be deleted from Azure
kubectl get managedredis -n resources-system -w
```

## Teardown

```bash
# Delete all managed resources first
kubectl delete managedredis --all -n resources-system

# Destroy infrastructure
terraform destroy
```

## What Gets Created

### Azure Resources
- Resource Group: `aks-control-plane`
- Managed Identity: `crossplane-identity`
- Role Assignment: Contributor at subscription level
- Federated Identity Credential for workload identity
- AKS Cluster: `aks-test`
- Resource Group: `aks-test-rg`

### Kubernetes Resources
- Namespace: `resources-system`
- Namespace: `devops-system`
- ArgoCD: Full installation
- Crossplane: Core installation
- Providers: provider-family-azure, provider-azure-cache
- DeploymentRuntimeConfig: Workload identity configuration
- ProviderConfig: Azure authentication config
- Secret: Credential backup

## Configuration Variables

Customize in `terraform.tfvars`:

```hcl
# Crossplane versions
crossplane_version                       = "1.18.4"
crossplane_provider_family_azure_version = "v2.3.0"
crossplane_provider_azure_cache_version  = "v2.3.0"

# AKS configuration
location         = "eastus"
kubernetes_version = "1.34"

# Other settings...
```

## Next Steps

1. Review the full documentation: [CROSSPLANE_IMPLEMENTATION_SUMMARY.md](CROSSPLANE_IMPLEMENTATION_SUMMARY.md)
2. Read troubleshooting guide: [aks-foundation/CROSSPLANE_README.md](aks-foundation/CROSSPLANE_README.md)
3. Learn about Crossplane: [CROSSPLANE_AZURE_WORKLOAD_IDENTITY.md](CROSSPLANE_AZURE_WORKLOAD_IDENTITY.md)
4. Create your first Composition
5. Explore more Azure providers

## Support

For issues:
1. Check provider logs
2. Verify workload identity configuration
3. Review Azure managed identity permissions
4. Consult the troubleshooting guides

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                         Azure                                │
│                                                              │
│  ┌──────────────────────┐  ┌─────────────────────────────┐ │
│  │  aks-control-plane   │  │  Subscription               │ │
│  │                      │  │                             │ │
│  │  - Managed Identity  │  │  - Contributor Role         │ │
│  │  - Fed. Credential   │  │    Assignment               │ │
│  └──────────────────────┘  └─────────────────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                           ↕ OIDC Token Exchange
┌─────────────────────────────────────────────────────────────┐
│                    AKS Cluster (aks-test)                    │
│                                                              │
│  ┌────────────────────────┐  ┌───────────────────────────┐ │
│  │  devops-system         │  │  resources-system     │ │
│  │                        │  │                           │ │
│  │  - ArgoCD              │  │  - Crossplane             │ │
│  │  - ArgoCD Projects     │  │  - Azure Providers        │ │
│  │  - ArgoCD Apps         │  │  - ProviderConfig         │ │
│  └────────────────────────┘  │  - Managed Resources      │ │
│                               └───────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```
