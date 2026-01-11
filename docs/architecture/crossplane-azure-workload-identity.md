# Configuring Crossplane with Azure Workload Identity on AKS

This guide provides step-by-step instructions for setting up Crossplane on Azure Kubernetes Service (AKS) with Workload Identity authentication.

## Prerequisites

- AKS cluster with OIDC Issuer enabled
- Azure CLI (`az`) installed and authenticated
- `kubectl` configured to access your AKS cluster
- Appropriate Azure permissions to create managed identities and role assignments

## Architecture Overview

Crossplane uses Azure Workload Identity to authenticate with Azure services. This involves:
1. A user-assigned managed identity in Azure
2. Federated identity credentials linking the managed identity to Kubernetes service accounts
3. Provider pods configured with workload identity labels and annotations
4. A ProviderConfig that uses OIDC token file authentication

## Step 1: Install Crossplane

Install Crossplane using Helm:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane \
  crossplane-stable/crossplane \
  --namespace default \
  --create-namespace
```

Wait for Crossplane to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=crossplane -n default --timeout=300s
```

## Step 2: Create Azure Managed Identity

Create a user-assigned managed identity that Crossplane will use:

```bash
az identity create \
  --name crossplane-identity \
  --resource-group <RESOURCE_GROUP> \
  --location <LOCATION>
```

Save the output values:
- `clientId` - This is your managed identity client ID
- `principalId` - This is used for role assignments

Example output:
```json
{
  "clientId": "52311a89-3b62-4f21-98cc-3d5dd055e7b0",
  "principalId": "a5c0f71e-1fa7-4d36-9a54-fbf2fecfb3a8",
  ...
}
```

## Step 3: Grant Azure Permissions

Grant the managed identity appropriate permissions. For full resource management, use Contributor role:

```bash
# For resource group scope
az role assignment create \
  --assignee <CLIENT_ID> \
  --role "Contributor" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>"

# For subscription scope (if needed)
az role assignment create \
  --assignee <CLIENT_ID> \
  --role "Contributor" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>"
```

## Step 4: Get AKS OIDC Issuer URL

Retrieve your AKS cluster's OIDC issuer URL:

```bash
export AKS_OIDC_ISSUER=$(az aks show \
  --name <CLUSTER_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --query "oidcIssuerProfile.issuerUrl" \
  -o tsv)

echo $AKS_OIDC_ISSUER
```

## Step 5: Install Azure Providers

Install the Crossplane Azure provider:

```bash
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-family-azure
spec:
  package: xpkg.upbound.io/upbound/provider-family-azure:v2.3.0
  packagePullPolicy: Always
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-redis-azure
spec:
  package: xpkg.upbound.io/upbound/provider-azure-cache:v2.3.0
  packagePullPolicy: Always
EOF
```

Wait for providers to become healthy:

```bash
kubectl wait --for=condition=healthy provider.pkg.crossplane.io/upbound-provider-family-azure --timeout=300s
kubectl wait --for=condition=healthy provider.pkg.crossplane.io/provider-redis-azure --timeout=300s
```

## Step 6: Get Provider Service Account Names

After providers are installed, get the service account names:

```bash
# List provider service accounts
kubectl get serviceaccount -n default | grep provider

# Example output:
# provider-redis-azure-29656e619a6b
# upbound-provider-family-azure-8dac93bc012b
```

The service account name will be in the format: `provider-<name>-<revision-hash>`

## Step 7: Create Federated Identity Credentials

Create a federated identity credential for each provider service account:

```bash
# For the main Azure provider
az identity federated-credential create \
  --name crossplane-provider-family-azure \
  --identity-name crossplane-identity \
  --resource-group <RESOURCE_GROUP> \
  --issuer "${AKS_OIDC_ISSUER}" \
  --subject "system:serviceaccount:default:upbound-provider-family-azure-<REVISION_HASH>"

# For the Redis provider (example)
az identity federated-credential create \
  --name crossplane-provider-redis-azure \
  --identity-name crossplane-identity \
  --resource-group <RESOURCE_GROUP> \
  --issuer "${AKS_OIDC_ISSUER}" \
  --subject "system:serviceaccount:default:provider-redis-azure-<REVISION_HASH>"
```

**Important**: Replace `<REVISION_HASH>` with the actual service account names from Step 6.

## Step 8: Configure DeploymentRuntimeConfig

Create a DeploymentRuntimeConfig that enables workload identity for provider pods:

```bash
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: default
spec:
  serviceAccountTemplate:
    metadata:
      annotations:
        azure.workload.identity/client-id: "<CLIENT_ID>"
EOF
```

**Note**: This configures the service accounts with the workload identity annotation.

## Step 9: Patch Provider Deployments

The provider deployments need the workload identity label on their pod templates. Patch each provider deployment:

```bash
# Patch the Azure family provider
kubectl patch deployment upbound-provider-family-azure-<REVISION_HASH> \
  -n default \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/metadata/labels/azure.workload.identity~1use","value":"true"}]'

# Patch the Redis provider
kubectl patch deployment provider-redis-azure-<REVISION_HASH> \
  -n default \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/metadata/labels/azure.workload.identity~1use","value":"true"}]'
```

**Alternative**: Update providers to reference the DeploymentRuntimeConfig:

```bash
kubectl patch provider upbound-provider-family-azure \
  --type='merge' \
  -p '{"spec":{"runtimeConfigRef":{"name":"default"}}}'

kubectl patch provider provider-redis-azure \
  --type='merge' \
  -p '{"spec":{"runtimeConfigRef":{"name":"default"}}}'
```

## Step 10: Annotate Service Accounts

Ensure all provider service accounts have the workload identity annotation:

```bash
kubectl annotate serviceaccount upbound-provider-family-azure-<REVISION_HASH> \
  -n default \
  azure.workload.identity/client-id=<CLIENT_ID> \
  --overwrite

kubectl annotate serviceaccount provider-redis-azure-<REVISION_HASH> \
  -n default \
  azure.workload.identity/client-id=<CLIENT_ID> \
  --overwrite
```

## Step 11: Create ProviderConfig

Create a ProviderConfig that uses OIDC token file authentication:

```bash
kubectl apply -f - <<EOF
apiVersion: azure.m.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
  namespace: default
spec:
  clientID: "<CLIENT_ID>"
  credentials:
    source: OIDCTokenFile
  subscriptionID: "<SUBSCRIPTION_ID>"
  tenantID: "<TENANT_ID>"
EOF
```

**Important**: 
- `clientID`: The managed identity client ID from Step 2
- `source: OIDCTokenFile`: Required for workload identity
- Do NOT use `SystemAssignedManagedIdentity` - it doesn't work with workload identity

## Step 12: Restart Provider Pods

Restart the provider pods to apply all configurations:

```bash
kubectl delete pod -n default -l pkg.crossplane.io/provider=provider-azure-cache
kubectl delete pod -n default -l pkg.crossplane.io/provider=provider-azure
```

Wait for pods to restart and become ready:

```bash
kubectl wait --for=condition=ready pod -l pkg.crossplane.io/provider=provider-azure-cache -n default --timeout=120s
```

## Step 13: Verify Configuration

### Check Pod Labels and Annotations

Verify the provider pods have the workload identity label:

```bash
kubectl get pod -n default -l pkg.crossplane.io/provider=provider-azure-cache \
  -o jsonpath='{.items[0].metadata.labels.azure\.workload\.identity/use}'
# Should output: true
```

### Check Environment Variables

Verify workload identity environment variables are injected:

```bash
kubectl get pod -n default -l pkg.crossplane.io/provider=provider-azure-cache \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}' | grep AZURE
# Should show: AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_FEDERATED_TOKEN_FILE AZURE_AUTHORITY_HOST
```

### Check Service Account Annotations

```bash
kubectl get serviceaccount provider-redis-azure-<REVISION_HASH> \
  -n default \
  -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'
# Should output your client ID
```

## Step 14: Test with a Managed Resource

Create a test resource to verify everything works:

```bash
kubectl apply -f - <<EOF
apiVersion: cache.azure.m.upbound.io/v1beta1
kind: ManagedRedis
metadata:
  name: example-mr-n
  namespace: default
spec:
  forProvider:
    location: East US
    resourceGroupName: <RESOURCE_GROUP>
    skuName: Balanced_B3
  providerConfigRef:
    kind: ProviderConfig
    name: default
EOF
```

Check the resource status:

```bash
kubectl get managedredis example-mr-n -n default
# Should show: SYNCED=True, READY=True
```

View detailed status:

```bash
kubectl describe managedredis example-mr-n -n default
```

## Troubleshooting

### Identity Not Found Error

**Error**: `Identity not found` or `ManagedIdentityAuthorizer: failed to request token`

**Solution**: 
- Verify the ProviderConfig uses `OIDCTokenFile` as the credentials source
- Check that service accounts have the correct client ID annotation
- Ensure provider pods have the `azure.workload.identity/use: "true"` label

### Application Not Found in Directory

**Error**: `Application with identifier 'xxx' was not found in the directory`

**Solution**:
- Verify the client ID in the ProviderConfig matches the managed identity client ID
- Ensure federated credentials are created with the correct service account subject
- Check that the OIDC issuer URL matches your AKS cluster's issuer

### Provider Pods Not Getting Workload Identity Environment Variables

**Solution**:
- Verify the AKS workload identity webhook is running: `kubectl get pods -n kube-system | grep azure-wi-webhook`
- Check that pods have the label: `azure.workload.identity/use: "true"`
- Ensure service accounts have the annotation: `azure.workload.identity/client-id`
- Delete and recreate pods to trigger webhook injection

### Permission Denied Errors

**Solution**:
- Verify role assignments: `az role assignment list --assignee <CLIENT_ID> -o table`
- Ensure the managed identity has Contributor role on the appropriate scope
- Wait a few minutes for role assignments to propagate

## Complete Example Script

Here's a complete script to automate the setup:

```bash
#!/bin/bash
set -e

# Configuration
RESOURCE_GROUP="aks-test-rg"
CLUSTER_NAME="aks-test"
LOCATION="eastus"
IDENTITY_NAME="crossplane-identity"
NAMESPACE="default"

# Get Azure info
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
AKS_OIDC_ISSUER=$(az aks show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Create managed identity
echo "Creating managed identity..."
IDENTITY_JSON=$(az identity create --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --location $LOCATION)
CLIENT_ID=$(echo $IDENTITY_JSON | jq -r '.clientId')

echo "Client ID: $CLIENT_ID"

# Grant permissions
echo "Granting permissions..."
az role assignment create \
  --assignee $CLIENT_ID \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

# Install Crossplane
echo "Installing Crossplane..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane --namespace $NAMESPACE --create-namespace

# Wait for Crossplane
kubectl wait --for=condition=ready pod -l app=crossplane -n $NAMESPACE --timeout=300s

# Install providers
echo "Installing Azure providers..."
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-family-azure
spec:
  package: xpkg.upbound.io/upbound/provider-family-azure:v2.3.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-redis-azure
spec:
  package: xpkg.upbound.io/upbound/provider-azure-cache:v2.3.0
EOF

# Wait for providers
kubectl wait --for=condition=healthy provider.pkg.crossplane.io/upbound-provider-family-azure --timeout=300s
kubectl wait --for=condition=healthy provider.pkg.crossplane.io/provider-redis-azure --timeout=300s

# Get service account names
SA_FAMILY=$(kubectl get sa -n $NAMESPACE | grep upbound-provider-family-azure | awk '{print $1}')
SA_REDIS=$(kubectl get sa -n $NAMESPACE | grep provider-redis-azure | awk '{print $1}')

echo "Service accounts: $SA_FAMILY, $SA_REDIS"

# Create federated credentials
echo "Creating federated credentials..."
az identity federated-credential create \
  --name crossplane-provider-family-azure \
  --identity-name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:$NAMESPACE:$SA_FAMILY"

az identity federated-credential create \
  --name crossplane-provider-redis-azure \
  --identity-name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:$NAMESPACE:$SA_REDIS"

# Configure DeploymentRuntimeConfig
echo "Creating DeploymentRuntimeConfig..."
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: default
spec:
  serviceAccountTemplate:
    metadata:
      annotations:
        azure.workload.identity/client-id: "$CLIENT_ID"
EOF

# Patch deployments
echo "Patching deployments..."
DEPLOY_FAMILY=$(kubectl get deployment -n $NAMESPACE | grep upbound-provider-family-azure | awk '{print $1}')
DEPLOY_REDIS=$(kubectl get deployment -n $NAMESPACE | grep provider-redis-azure | awk '{print $1}')

kubectl patch deployment $DEPLOY_FAMILY -n $NAMESPACE --type='json' \
  -p='[{"op":"add","path":"/spec/template/metadata/labels/azure.workload.identity~1use","value":"true"}]'

kubectl patch deployment $DEPLOY_REDIS -n $NAMESPACE --type='json' \
  -p='[{"op":"add","path":"/spec/template/metadata/labels/azure.workload.identity~1use","value":"true"}]'

# Annotate service accounts
echo "Annotating service accounts..."
kubectl annotate serviceaccount $SA_FAMILY -n $NAMESPACE azure.workload.identity/client-id=$CLIENT_ID --overwrite
kubectl annotate serviceaccount $SA_REDIS -n $NAMESPACE azure.workload.identity/client-id=$CLIENT_ID --overwrite

# Create ProviderConfig
echo "Creating ProviderConfig..."
kubectl apply -f - <<EOF
apiVersion: azure.m.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  clientID: "$CLIENT_ID"
  credentials:
    source: OIDCTokenFile
  subscriptionID: "$SUBSCRIPTION_ID"
  tenantID: "$TENANT_ID"
EOF

echo "Setup complete! Waiting for pods to be ready..."
sleep 20

kubectl get pods -n $NAMESPACE | grep provider

echo "Configuration finished successfully!"
```

## Key Takeaways

1. **Always use `OIDCTokenFile`** as the credentials source in ProviderConfig for workload identity
2. **Service account names include revision hashes** - retrieve them dynamically after provider installation
3. **Federated credentials must match** the exact service account name including the namespace
4. **Pod template labels are required** - the `azure.workload.identity/use: "true"` label triggers webhook injection
5. **Provider pods must be restarted** after configuration changes to pick up new settings
6. **DeploymentRuntimeConfig applies to future revisions** - existing deployments need manual patching

## References

- [Crossplane Documentation](https://docs.crossplane.io/)
- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/)
- [Upbound Azure Provider](https://marketplace.upbound.io/providers/upbound/provider-family-azure/)
