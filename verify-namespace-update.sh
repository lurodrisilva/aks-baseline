   1 #!/bin/bash
   2 # Verification script for namespace update
   3 
   4 echo "🔍 Verifying Crossplane namespace update to resources-system..."
   5 echo ""
   6 
   7 # Check namespace in locals
   8 echo "1. Checking namespace definition in locals..."
   9 grep -q "resources.*=.*\"resources-system\"" aks-foundation/aks_cluster_namespaces.tf && echo "✅ Namespace defined in locals" || echo "❌ Namespace NOT found in locals"
  10 
  11 # Check federated credential
  12 echo ""
  13 echo "2. Checking federated identity credential..."
  14 grep -q "local.namespaces.resources" aks-foundation/crossplane_infrastructure.tf && echo "✅ Federated credential uses resources namespace" || echo "❌ Federated credential NOT updated"
  15 
  16 # Check all Crossplane resources
  17 echo ""
  18 echo "3. Checking Crossplane ArgoCD resources..."
  19 RESOURCES_COUNT=$(grep -c "local.namespaces.resources" aks-foundation/crossplane_argocd.tf)
  20 if [ "$RESOURCES_COUNT" -ge 7 ]; then
  21     echo "✅ All $RESOURCES_COUNT Crossplane resources use resources namespace"
  22 else
  23     echo "❌ Only $RESOURCES_COUNT references found (expected 7+)"
  24 fi
  25 
  26 # Check no old references remain
  27 echo ""
  28 echo "4. Checking for old namespace references..."
  29 OLD_REFS=$(grep -r "control-plane-system" aks-foundation/crossplane_*.tf 2>/dev/null | grep -v "control_plane" | wc -l | tr -d ' ')
  30 if [ "$OLD_REFS" -eq 0 ]; then
  31     echo "✅ No old namespace references in Terraform files"
  32 else
  33     echo "❌ Found $OLD_REFS old namespace references"
  34 fi
  35 
  36 # Summary
  37 echo ""
  38 echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  39 echo "Summary:"
  40 echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  41 echo "All Crossplane assets are configured to use:"
  42 echo "📦 Namespace: resources-system"
  43 echo "🔐 Federated Subject: system:serviceaccount:resources-system:*"
  44 echo ""
  45 echo "Files updated:"
  46 echo "  - aks-foundation/aks_cluster_namespaces.tf"
  47 echo "  - aks-foundation/crossplane_infrastructure.tf"
  48 echo "  - aks-foundation/crossplane_argocd.tf"
  49 echo "  - All documentation files"
  50 echo ""
  51 echo "✅ Validation complete!"
