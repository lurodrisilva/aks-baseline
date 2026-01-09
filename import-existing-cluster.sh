#!/bin/bash
# Script to import existing AKS cluster and related resources into Terraform state

set -e

echo "🔍 Importing existing AKS resources into Terraform state..."
echo ""

# Configuration
SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID}"
RESOURCE_GROUP="aks-test-rg"
CLUSTER_NAME="aks-test"
WORKSPACE_NAME="aks-test-workspace"

if [ -z "$SUBSCRIPTION_ID" ]; then
    echo "❌ ARM_SUBSCRIPTION_ID environment variable is not set"
    exit 1
fi

cd aks-foundation

# Export subscription ID for Terraform
export TF_VAR_subscription_id=$SUBSCRIPTION_ID

echo "1. Checking if AKS cluster exists..."
if az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "   ✅ AKS cluster found: $CLUSTER_NAME"
    
    # Check if already in state
    if terraform state show azurerm_kubernetes_cluster.main >/dev/null 2>&1; then
        echo "   ℹ️  AKS cluster already in Terraform state"
    else
        echo "   📥 Importing AKS cluster into Terraform state..."
        CLUSTER_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME"
        terraform import azurerm_kubernetes_cluster.main "$CLUSTER_ID"
        echo "   ✅ AKS cluster imported"
    fi
else
    echo "   ⚠️  AKS cluster not found - will be created on apply"
fi

echo ""
echo "2. Checking if Log Analytics Solution exists..."
SOLUTION_NAME="ContainerInsights($WORKSPACE_NAME)"
if az monitor log-analytics solution show --resource-group "$RESOURCE_GROUP" --solution-name "$SOLUTION_NAME" >/dev/null 2>&1; then
    echo "   ✅ Log Analytics Solution found"
    
    # Check if already in state
    if terraform state show 'azurerm_log_analytics_solution.main[0]' >/dev/null 2>&1; then
        echo "   ℹ️  Log Analytics Solution already in Terraform state"
    else
        echo "   📥 Importing Log Analytics Solution into Terraform state..."
        SOLUTION_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationsManagement/solutions/$SOLUTION_NAME"
        terraform import 'azurerm_log_analytics_solution.main[0]' "$SOLUTION_ID"
        echo "   ✅ Log Analytics Solution imported"
    fi
else
    echo "   ⚠️  Log Analytics Solution not found - will be created on apply"
fi

echo ""
echo "3. Verifying Crossplane infrastructure in state..."
if terraform state show azurerm_resource_group.aks_control_plane >/dev/null 2>&1; then
    echo "   ✅ Crossplane resource group in state"
else
    echo "   ⚠️  Crossplane resource group not in state"
fi

if terraform state show azurerm_user_assigned_identity.crossplane >/dev/null 2>&1; then
    echo "   ✅ Crossplane managed identity in state"
else
    echo "   ⚠️  Crossplane managed identity not in state"
fi

if terraform state show azurerm_role_assignment.crossplane_contributor >/dev/null 2>&1; then
    echo "   ✅ Crossplane role assignment in state"
else
    echo "   ⚠️  Crossplane role assignment not in state"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Import process complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "1. Run: TF_VAR_subscription_id=\$ARM_SUBSCRIPTION_ID terraform plan"
echo "2. Verify the plan shows no changes for imported resources"
echo "3. Run: TF_VAR_subscription_id=\$ARM_SUBSCRIPTION_ID make apply ENV=dev"
echo ""
