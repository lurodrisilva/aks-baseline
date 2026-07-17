
################################################################################
# ArgoCD
################################################################################
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  namespace  = local.namespaces.devops
  chart      = "argo-cd"
  version    = "8.1.0"
  wait       = true

  values = [
    <<-EOT
      
    redis-ha:
      enabled: ${terraform.workspace == "prd" ? true : false}

    controller:
      replicas: 2

    server:
      autoscaling:
        enabled: true
        minReplicas: 2

    repoServer:
      autoscaling:
        enabled: true
        minReplicas: 2

    applicationSet:
      replicas: 0

    configs:
      repositories: {}

      params:
        server.insecure: true

      cm:
        accounts.admin: apiKey, login
        accounts.github: apiKey, login
        resource.compareoptions: |
          ignoreResourceStatusField: all
          ignoreDifferencesOnResourceUpdates: true
        # Health assessment for the platform's Crossplane composite resources.
        #
        # WHY THIS EXISTS: ArgoCD ships no health check for a custom group, and
        # it defaults unassessable kinds to Healthy. Without this, a
        # PostgresInstance that has not begun provisioning reports Healthy the
        # instant it is created, the infra sync-wave clears immediately, and the
        # app's migration wave runs against an Azure Flexible Server that will
        # not exist for another 5-10 minutes. The wave gate looks like it works
        # and does nothing.
        #
        # The wildcard covers PostgresInstance and RedisInstance both — every
        # Crossplane XR carries the same Ready/Synced condition contract, so one
        # script serves the whole group. Wildcards only work under the
        # `resource.customizations` key; the resource.customizations.health.
        # <group>_<kind> form does NOT support them.
        resource.customizations: |
          platform.myorg.io/*:
            health.lua: |
              local hs = {}
              hs.status = "Progressing"
              hs.message = "Waiting for the control plane to report status"

              if obj.status == nil or obj.status.conditions == nil then
                -- Freshly created: Crossplane has not written conditions yet.
                return hs
              end

              -- Synced=False means the Composition itself failed to reconcile
              -- (bad ProviderConfig, invalid spec, provider not installed).
              -- That is a real failure, not slow provisioning, so surface it
              -- rather than letting the wave hang until it times out.
              for _, c in ipairs(obj.status.conditions) do
                if c.type == "Synced" and c.status == "False" then
                  hs.status = "Degraded"
                  hs.message = c.reason or "ReconcileError"
                  if c.message ~= nil then
                    hs.message = hs.message .. ": " .. c.message
                  end
                  return hs
                end
              end

              -- Ready=True is Crossplane's statement that every composed
              -- resource is ready. For PostgresInstance that includes the
              -- composed connection Secret, which is patched from status.fqdn
              -- with policy Required — so it only exists once the server has a
              -- private FQDN. Ready therefore implies the host is knowable.
              for _, c in ipairs(obj.status.conditions) do
                if c.type == "Ready" then
                  if c.status == "True" then
                    hs.status = "Healthy"
                    hs.message = "Composed resources are ready"
                  else
                    hs.status = "Progressing"
                    hs.message = c.reason or "Creating"
                  end
                  return hs
                end
              end

              return hs
      params:
        application.namespaces: "*"  # Adding namespaces to be managed by ArgoCD

    EOT
  ]

  depends_on = [
    azurerm_kubernetes_cluster.main,
    helm_release.vault
  ]
}

resource "kubectl_manifest" "argocd_project_addons" {
  yaml_body  = <<-EOF
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: addons-project
    namespace: ${local.namespaces.devops}
    # finalizers:
    #   - resources-finalizer.argocd.argoproj.io
  spec:
    description: Platform Project for AKS Addons
    clusterResourceWhitelist:
      - group: '*'
        kind: '*'
    destinations:
      - name: in-cluster
        server: https://kubernetes.default.svc
        namespace: '*'
    sourceRepos:
      - '*'
    sourceNamespaces:
      - '*'
    namespaceResourceWhitelist:
      - group: '*'
        kind: '*'
  EOF
  depends_on = [helm_release.argocd]
}

# resource "kubectl_manifest" "argocd_project_jarvix" {
#   yaml_body = <<EOF
#   apiVersion: argoproj.io/v1alpha1
#   kind: AppProject
#   metadata:
#     name: jarvix-project
#     namespace: ${local.namespaces.devops}
#   spec:
#     clusterResourceWhitelist:
#       - group: '*'
#         kind: '*'
#     destinations:
#       - namespace: '${local.namespaces.jarvix}'
#         server: '*'
#     sourceRepos:
#       - '*'
#   EOF
#   depends_on = [ helm_release.argocd ]
# }

################################################################################
# ArgoCD Repository - addons
################################################################################
resource "kubectl_manifest" "argocd_repo_addons" {
  yaml_body  = <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: repo-addons
      namespace: ${local.namespaces.devops}
      labels:
        argocd.argoproj.io/secret-type: repository
      annotations:
        managed-by: argocd.argoproj.io
    type: Opaque
    stringData:
      type: git
      url: https://github.com/lurodrisilva/plat-eng-baseline-addons.git
  EOF
  depends_on = [helm_release.argocd]
}

################################################################################
# ArgoCD Application - addons
################################################################################
resource "kubectl_manifest" "argocd_app_addons" {
  yaml_body  = <<-EOF
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: baseline-addons
      namespace: ${local.namespaces.control_plane}
    spec:
      project: addons-project
      source:
        repoURL: https://github.com/lurodrisilva/plat-eng-baseline-addons.git
        targetRevision: HEAD
        path: base_chart
      destination:
        server: https://kubernetes.default.svc
        namespace: ${local.namespaces.control_plane}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true       # only apply out-of-sync resources
  EOF
  depends_on = [kubectl_manifest.argocd_repo_addons, kubectl_manifest.argocd_project_addons]
}

# resource "kubectl_manifest" "argocd_repo_helm_charts" {
#   yaml_body = <<EOF
#   apiVersion: v1
#   kind: Secret
#   metadata:
#     name: repo-aks-foundation
#     namespace: ${local.namespaces.devops}
#     labels:
#       argocd.argoproj.io/secret-type: repository
#     annotations:
#       managed-by: argocd.argoproj.io
#   type: Opaque
#   data:
#     githubAppID: OTcyNjQ2
#     githubAppInstallationID: NTM4NzEyNjM=
#     githubAppPrivateKey: >-
#       LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb2dJQkFBS0NBUUVBOEhTVG1uZTBORTRhNlNOMVlzRndsZm1MSzRBR3pwdTVKTFU5Y2VVMDh0dithcGU3Cm1PY2xLaXlPSEltYTFmM0hCOVhxcDNnVWJKaTQvUXI2UldoVS82SFpiMUFkTFhrMGh3S0FrRm44NXh5enZBV2QKVWlXMmJVYnBuZFcxMHE5bUU0bXp2ZG1taW9tSmZwK1JiczVvL0lqNWt3Sk5lM2wrVy9YNXE0aC9uYTBqdGJ3dwpsckF0RnJSNWRtazhQOUpDNWY1L2Ywc0xMTWVXYUY4SWovTXFxSzh5N2kzZzhnWWNWNHQvT0hnRmtwSnRGYU4wCkJBTUxtbzY0OGR3ai8ycW90UnMwSFM3Q0lyUTQwUkNsV0lVaUxBTXM2QUNmbXVSdVhtazRkSW9YMW9Edlp6alUKSk5Gdk9KM2kvRm5wckRqZXpEem5PTXd0N1hOQnV1ZldqZGxYWndJREFRQUJBb0lCQUUxSm16djJKK1Q4Q2VoUAo3bVlzdVF4cnBsRDRHTGdHRTY5NTFlTXJBaWJoa1ZnZnB6dlJaLyt6VElaZHNIZ0IxeHhzcEx6cGV0OGhBNnpKCi80R1p0R0JxWEdKTUJPVGQ1WVZUeDVFZWE0eTVqQWZ1WWcvS2NXV1Vlbml4L1h4WHhsNlhUei9CbXFkQzUvL2MKT0RtK2ZMNVhKS2tjLzF5bHczaTVpbU9aUHpPbG1KbG1WMjVZcXVFbFgrWVRrYnhwWjJlTnRBWllTVkNLMkw3ego4WHJhYkFTOGdZamowYThOSldCMy9vZXpXUkZWWktmK2k3WHlJckFGdnV3NTNHbC9COFQxNkRjQlE4NnVKZEY3Ci82UENCMTM5MW9mR01ZT1VKNVhMaGlFaVc0ZDAvWjNKR09OUzZ4Y2xUNlZLaHh3dGdiZ3FPSWxDNTNvcm8vMlIKZ1MyTDFua0NnWUVBLzN0RklvdUcvc1FHRmIwc1JjRGk4UkM1akJQUmM2WTFBdnR1MlUrcE9JOXNZMFFqQi9teQpHRkpJcXZCamdjcSsyN1duOVFZc0h6LzBqQzRyenlkSGRRRCs2VTlQSGlDNGZZSDg4TkhGYnNOa0M3Rk90ejdVCllrcG5TNktwYTdsVDNMZUZXZnVnTElXS2RFZmc3UE9TRnJKUVIyL1dRSUp6bXI2bXhrS3dzSE1DZ1lFQThQR0EKQUZ6L1BScGw4aUFWQk1tdmRXZXZpVng1ZkpXNXArNEt0WUdaZWI4NTZYamEvcWhhTHlUQnVycFJpWDhNckozdgphM0djREE4T0IxdTJLRFBXYmRyb0NHUFBUQjV5SktGTEZaSGxvL2xyb2JrRGNBeVFEUis0dDVndW5Ob3J5SzJhCkpIZEovNno3Z1lqYW1CWklJdXh2MTV3QWVyR3RvWFFKOUJrc2hEMENnWUEzODdaYmIzVmNQSEFjdUxhR2ZFejMKZ0xNeVEzRGV4Q3JlQVZUd2tPcTlzV09LaGZTcUhYeHNxVEN6Qnp5encwUnpkK0JWNEVrdmV1RkRCaVdnRTdrcApuZE0ySTZGdk5ybFErM1A3QmVZWWNRQnJNeVRMS3g1MmZGY05FSTNNUXVWajlHbG5JSjJld294bEZRemt1QjlwCml4bmIyMWx2L1dIMkpRVC9iTUdua3dLQmdCTXFVcEUwMUlTcXZlTTFsQlp1YUl1Qk5PQkxQOHFlS2tkbVV1bS8KSmxNZDErQnZZWlFTRmlKYjNTRWFRdlFaN0FzckFPbGQveGlpZGU0MTZGWm9VUzBwMVgwZFcxYmxzUlNpMDlNaQphTTdUUHpGOUF2MzlzZE9wYTBzSFN1WGxJTWgwcnFjcDZmUHhjWXdMTThBWFBhT3hoTy8wazhFdXN1Mzl5ZkRsCnM3bk5Bb0dBVEw5bndTZFc4WlY0Z1dNMzdjQnNISERVZ2Q5Zk5DQnpsbzFvM29HQjA2TmdLZGU0R0R2TC8rRU8KRG12bWNvNWQrNjdBZE1qUU9IRUM3ZFMwVWRwRHgyb2lJUTFaSGtjRlJnQ214eENZYWpPK1E1YmN1NmhZYUU4awp5bklwcTlTaE1QbCs4Q1BubHhIUlYxR2RJTm5QRXgrdkZ6aHNtaDEySzh4U210MkliVXM9Ci0tLS0tRU5EIFJTQSBQUklWQVRFIEtFWS0tLS0tCg==
#     project: YWRkb25z
#     type: Z2l0
#     url: aHR0cHM6Ly9naXRodWIuY29tL2JlYmV0LW9yZ2FuaXphdGlvbi9hd3MtZm91bmRhdGlvbi5naXQ=
#   EOF
# }

# resource "kubectl_manifest" "argocd_repo_aws_foundation" {
#   yaml_body = <<EOF
#   apiVersion: v1
#   kind: Secret
#   metadata:
#     name: repo-helm-charts
#     namespace: ${local.namespaces.devops}
#     labels:
#       argocd.argoproj.io/secret-type: repository
#     annotations:
#       managed-by: argocd.argoproj.io
#   type: Opaque
#   data:
#     githubAppID: OTcyNjQ2
#     githubAppInstallationID: NTM4NzEyNjM=
#     githubAppPrivateKey: >-
#       LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb2dJQkFBS0NBUUVBOEhTVG1uZTBORTRhNlNOMVlzRndsZm1MSzRBR3pwdTVKTFU5Y2VVMDh0dithcGU3Cm1PY2xLaXlPSEltYTFmM0hCOVhxcDNnVWJKaTQvUXI2UldoVS82SFpiMUFkTFhrMGh3S0FrRm44NXh5enZBV2QKVWlXMmJVYnBuZFcxMHE5bUU0bXp2ZG1taW9tSmZwK1JiczVvL0lqNWt3Sk5lM2wrVy9YNXE0aC9uYTBqdGJ3dwpsckF0RnJSNWRtazhQOUpDNWY1L2Ywc0xMTWVXYUY4SWovTXFxSzh5N2kzZzhnWWNWNHQvT0hnRmtwSnRGYU4wCkJBTUxtbzY0OGR3ai8ycW90UnMwSFM3Q0lyUTQwUkNsV0lVaUxBTXM2QUNmbXVSdVhtazRkSW9YMW9Edlp6alUKSk5Gdk9KM2kvRm5wckRqZXpEem5PTXd0N1hOQnV1ZldqZGxYWndJREFRQUJBb0lCQUUxSm16djJKK1Q4Q2VoUAo3bVlzdVF4cnBsRDRHTGdHRTY5NTFlTXJBaWJoa1ZnZnB6dlJaLyt6VElaZHNIZ0IxeHhzcEx6cGV0OGhBNnpKCi80R1p0R0JxWEdKTUJPVGQ1WVZUeDVFZWE0eTVqQWZ1WWcvS2NXV1Vlbml4L1h4WHhsNlhUei9CbXFkQzUvL2MKT0RtK2ZMNVhKS2tjLzF5bHczaTVpbU9aUHpPbG1KbG1WMjVZcXVFbFgrWVRrYnhwWjJlTnRBWllTVkNLMkw3ego4WHJhYkFTOGdZamowYThOSldCMy9vZXpXUkZWWktmK2k3WHlJckFGdnV3NTNHbC9COFQxNkRjQlE4NnVKZEY3Ci82UENCMTM5MW9mR01ZT1VKNVhMaGlFaVc0ZDAvWjNKR09OUzZ4Y2xUNlZLaHh3dGdiZ3FPSWxDNTNvcm8vMlIKZ1MyTDFua0NnWUVBLzN0RklvdUcvc1FHRmIwc1JjRGk4UkM1akJQUmM2WTFBdnR1MlUrcE9JOXNZMFFqQi9teQpHRkpJcXZCamdjcSsyN1duOVFZc0h6LzBqQzRyenlkSGRRRCs2VTlQSGlDNGZZSDg4TkhGYnNOa0M3Rk90ejdVCllrcG5TNktwYTdsVDNMZUZXZnVnTElXS2RFZmc3UE9TRnJKUVIyL1dRSUp6bXI2bXhrS3dzSE1DZ1lFQThQR0EKQUZ6L1BScGw4aUFWQk1tdmRXZXZpVng1ZkpXNXArNEt0WUdaZWI4NTZYamEvcWhhTHlUQnVycFJpWDhNckozdgphM0djREE4T0IxdTJLRFBXYmRyb0NHUFBUQjV5SktGTEZaSGxvL2xyb2JrRGNBeVFEUis0dDVndW5Ob3J5SzJhCkpIZEovNno3Z1lqYW1CWklJdXh2MTV3QWVyR3RvWFFKOUJrc2hEMENnWUEzODdaYmIzVmNQSEFjdUxhR2ZFejMKZ0xNeVEzRGV4Q3JlQVZUd2tPcTlzV09LaGZTcUhYeHNxVEN6Qnp5encwUnpkK0JWNEVrdmV1RkRCaVdnRTdrcApuZE0ySTZGdk5ybFErM1A3QmVZWWNRQnJNeVRMS3g1MmZGY05FSTNNUXVWajlHbG5JSjJld294bEZRemt1QjlwCml4bmIyMWx2L1dIMkpRVC9iTUdua3dLQmdCTXFVcEUwMUlTcXZlTTFsQlp1YUl1Qk5PQkxQOHFlS2tkbVV1bS8KSmxNZDErQnZZWlFTRmlKYjNTRWFRdlFaN0FzckFPbGQveGlpZGU0MTZGWm9VUzBwMVgwZFcxYmxzUlNpMDlNaQphTTdUUHpGOUF2MzlzZE9wYTBzSFN1WGxJTWgwcnFjcDZmUHhjWXdMTThBWFBhT3hoTy8wazhFdXN1Mzl5ZkRsCnM3bk5Bb0dBVEw5bndTZFc4WlY0Z1dNMzdjQnNISERVZ2Q5Zk5DQnpsbzFvM29HQjA2TmdLZGU0R0R2TC8rRU8KRG12bWNvNWQrNjdBZE1qUU9IRUM3ZFMwVWRwRHgyb2lJUTFaSGtjRlJnQ214eENZYWpPK1E1YmN1NmhZYUU4awp5bklwcTlTaE1QbCs4Q1BubHhIUlYxR2RJTm5QRXgrdkZ6aHNtaDEySzh4U210MkliVXM9Ci0tLS0tRU5EIFJTQSBQUklWQVRFIEtFWS0tLS0tCg==
#     project: 
#     type: Z2l0
#     url: aHR0cHM6Ly9naXRodWIuY29tL2JlYmV0LW9yZ2FuaXphdGlvbi9oZWxtLWNoYXJ0cy5naXQ=
#   EOF
# }

# aeIfoAMuR27sdLLE