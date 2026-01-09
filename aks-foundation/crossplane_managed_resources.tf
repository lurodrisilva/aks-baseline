# ################################################################################
# # Crossplane Managed Resources
# ################################################################################

# # ManagedRedis example resource
# # This resource demonstrates a managed Azure Cache for Redis instance
# # created and managed by Crossplane provider-azure-cache
# resource "kubectl_manifest" "managed_redis_example" {
#   yaml_body = <<-YAML
# apiVersion: cache.azure.m.upbound.io/v1beta1
# kind: ManagedRedis
# metadata:
#   name: example-mr-n
#   namespace: ${local.namespaces.resources}
#   labels:
#     testing.upbound.io/redis-example: aks-test-rg
#   annotations:
#     crossplane.io/external-name: example-mr-n
#     meta.upbound.io/managed-redis-1: cache/v1beta1/managedredis
# spec:
#   forProvider:
#     location: East Us
#     resourceGroupName: aks-test-rg
#     skuName: Balanced_B3
#   providerConfigRef:
#     kind: ClusterProviderConfig
#     name: default
#   YAML

#   depends_on = [
#     kubectl_manifest.crossplane_provider_config,
#     kubernetes_namespace.namespaces,
#     time_sleep.interval_before_crossplane_installation
#   ]
# }
